//! Bounded per-fd outbound buffer for CTL replies (PLAN.md 1.5).
//!
//! SES replies used to go out through `wire.write*Timeout`, which polls until
//! the socket accepts the bytes. A client that stops reading its CTL socket —
//! SIGSTOPped, swapping, or just slow — fills the buffer, and every reply to
//! *any* session then costs the daemon a stall up to the handler timeout. That
//! is the last blocking write on the event loop after 1.2 removed the reads.
//!
//! Replies now go here instead: write inline while the socket accepts, buffer
//! whatever is left, and drain it from the periodic tick alongside the VT
//! queues. Nothing on the loop waits for a peer.
//!
//! Two invariants matter more than the buffering itself:
//!
//! 1. **Strict ordering.** Once anything is queued for an fd, every later reply
//!    for that fd must queue too, even if the socket would accept it now.
//!    Writing it inline would put it AHEAD of the queued bytes and corrupt the
//!    peer's control stream. `Server.writeCtlBytes` enforces this by checking
//!    `pending()` before taking the inline path.
//!
//! 2. **All-or-nothing frames.** A CTL frame must never be half-written and
//!    then abandoned — the peer would read the remainder as the next frame's
//!    header. Callers therefore hand a whole serialized frame to a single
//!    `writeCtlBytes` call, and the residue is queued rather than dropped.

const std = @import("std");

pub const CtlOutQueue = struct {
    /// Bytes still owed to the peer, from `head` onward. `head` is a read
    /// cursor rather than a rotating buffer because a queue is normally empty
    /// or drained in one or two writes.
    buf: std.ArrayListUnmanaged(u8) = .empty,
    head: usize = 0,

    /// Reclaim the consumed prefix once it is worth the move. Without this a
    /// long-lived connection's buffer grows without bound even though only a
    /// few bytes are ever outstanding.
    const COMPACT_THRESHOLD: usize = 16 * 1024;

    pub fn pending(self: *const CtlOutQueue) usize {
        return self.buf.items.len - self.head;
    }

    pub fn append(self: *CtlOutQueue, allocator: std.mem.Allocator, bytes: []const u8) !void {
        try self.buf.appendSlice(allocator, bytes);
    }

    /// Mark `n` bytes as delivered.
    pub fn consume(self: *CtlOutQueue, n: usize) void {
        self.head += n;
        std.debug.assert(self.head <= self.buf.items.len);
    }

    pub fn unsent(self: *const CtlOutQueue) []const u8 {
        return self.buf.items[self.head..];
    }

    pub fn compact(self: *CtlOutQueue) void {
        if (self.head == 0) return;
        if (self.pending() == 0) {
            self.buf.clearRetainingCapacity();
            self.head = 0;
            return;
        }
        if (self.head < COMPACT_THRESHOLD) return;
        std.mem.copyForwards(u8, self.buf.items[0..self.pending()], self.unsent());
        self.buf.shrinkRetainingCapacity(self.pending());
        self.head = 0;
    }

    pub fn deinit(self: *CtlOutQueue, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
        self.head = 0;
    }
};

test "CtlOutQueue tracks pending bytes across partial consumption" {
    const testing = std.testing;
    var q = CtlOutQueue{};
    defer q.deinit(testing.allocator);

    try q.append(testing.allocator, "hello world");
    try testing.expectEqual(@as(usize, 11), q.pending());

    q.consume(6);
    try testing.expectEqual(@as(usize, 5), q.pending());
    try testing.expectEqualStrings("world", q.unsent());
}

test "CtlOutQueue reclaims the buffer once fully drained" {
    const testing = std.testing;
    var q = CtlOutQueue{};
    defer q.deinit(testing.allocator);

    try q.append(testing.allocator, "abc");
    q.consume(3);
    q.compact();
    try testing.expectEqual(@as(usize, 0), q.pending());
    try testing.expectEqual(@as(usize, 0), q.head);
    try testing.expectEqual(@as(usize, 0), q.buf.items.len);

    // Reusable after compaction.
    try q.append(testing.allocator, "xyz");
    try testing.expectEqualStrings("xyz", q.unsent());
}

test "CtlOutQueue keeps unsent bytes intact when it compacts a large prefix" {
    const testing = std.testing;
    var q = CtlOutQueue{};
    defer q.deinit(testing.allocator);

    const big = try testing.allocator.alloc(u8, CtlOutQueue.COMPACT_THRESHOLD + 8);
    defer testing.allocator.free(big);
    @memset(big, 'A');
    try q.append(testing.allocator, big);
    try q.append(testing.allocator, "TAIL");

    // Consume past the threshold so compaction triggers, leaving a partial
    // frame plus the trail still owed.
    q.consume(CtlOutQueue.COMPACT_THRESHOLD + 4);
    const before = q.pending();
    q.compact();
    try testing.expectEqual(@as(usize, 0), q.head);
    try testing.expectEqual(before, q.pending());
    try testing.expectEqualStrings("AAAATAIL", q.unsent());
}

test "CtlOutQueue does not compact below the threshold" {
    const testing = std.testing;
    var q = CtlOutQueue{};
    defer q.deinit(testing.allocator);

    try q.append(testing.allocator, "abcdef");
    q.consume(2);
    q.compact();
    // Still cheap to leave in place; the cursor must survive untouched.
    try testing.expectEqual(@as(usize, 2), q.head);
    try testing.expectEqualStrings("cdef", q.unsent());
}
