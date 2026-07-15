const std = @import("std");
const posix = std.posix;
const core = @import("core");

const wire = core.wire;

pub const Queue = struct {
    bytes: std.ArrayList(u8) = .empty,
    read_off: usize = 0,

    pub fn deinit(self: *Queue, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.* = .{};
    }

    pub fn clear(self: *Queue) void {
        self.bytes.clearRetainingCapacity();
        self.read_off = 0;
    }

    /// Prepare the queue for a brand-new SES VT connection.
    ///
    /// The hazard a reconnect must avoid is replaying a PARTIALLY WRITTEN frame:
    /// if `read_off > 0`, the head frame's first bytes already went to the OLD
    /// socket, so its remainder would start the new multiplexed stream mid-frame
    /// and desync every pane's input — those bytes must be dropped.
    ///
    /// But when `read_off == 0` NOTHING was partially sent: every queued frame is
    /// complete and was never written anywhere (the common case is a keystroke
    /// enqueued while the channel was down, since flushPendingMuxVtWrites returns
    /// early with no vt_fd and never advances read_off). Those frames are safe to
    /// KEEP — they flush intact, in order, to the new socket. Clearing them here
    /// was silently dropping keystrokes typed during the reconnect window.
    pub fn resetForReconnect(self: *Queue) void {
        if (self.read_off > 0) self.clear();
    }

    pub fn queuedBytes(self: *const Queue) usize {
        if (self.read_off >= self.bytes.items.len) return 0;
        return self.bytes.items.len - self.read_off;
    }

    pub fn enqueueFrame(
        self: *Queue,
        allocator: std.mem.Allocator,
        pane_id: u16,
        frame_type: u8,
        payload: []const u8,
        max_pending_bytes: usize,
    ) !bool {
        if (payload.len == 0) {
            return self.enqueueFrameChunk(allocator, pane_id, frame_type, "", max_pending_bytes);
        }

        var off: usize = 0;
        while (off < payload.len) {
            const chunk_len = @min(payload.len - off, wire.MAX_PAYLOAD_LEN);
            const ok = try self.enqueueFrameChunk(
                allocator,
                pane_id,
                frame_type,
                payload[off..][0..chunk_len],
                max_pending_bytes,
            );
            if (!ok) return false;
            off += chunk_len;
        }

        return true;
    }

    fn enqueueFrameChunk(
        self: *Queue,
        allocator: std.mem.Allocator,
        pane_id: u16,
        frame_type: u8,
        payload: []const u8,
        max_pending_bytes: usize,
    ) !bool {
        self.compact();

        const needed = @sizeOf(wire.MuxVtHeader) + payload.len;
        if (self.queuedBytes() + needed > max_pending_bytes) return false;

        var hdr = wire.MuxVtHeader{
            .pane_id = pane_id,
            .frame_type = frame_type,
            .len = @intCast(payload.len),
        };
        try self.bytes.appendSlice(allocator, std.mem.asBytes(&hdr));
        try self.bytes.appendSlice(allocator, payload);
        return true;
    }

    pub fn flushToFd(self: *Queue, fd: posix.fd_t) !void {
        while (self.read_off < self.bytes.items.len) {
            const n = posix.write(fd, self.bytes.items[self.read_off..]) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (n == 0) return error.ConnectionClosed;
            self.read_off += n;
        }

        self.compact();
    }

    fn compact(self: *Queue) void {
        if (self.read_off == 0) return;
        if (self.read_off >= self.bytes.items.len) {
            self.clear();
            return;
        }

        const remaining = self.bytes.items.len - self.read_off;
        std.mem.copyForwards(u8, self.bytes.items[0..remaining], self.bytes.items[self.read_off..]);
        self.bytes.items.len = remaining;
        self.read_off = 0;
    }
};

test "enqueueFrame encodes mux vt header and payload" {
    const testing = std.testing;

    var queue: Queue = .{};
    defer queue.deinit(testing.allocator);

    try testing.expect(try queue.enqueueFrame(testing.allocator, 42, 2, "abc", 1024));
    try testing.expectEqual(@as(usize, @sizeOf(wire.MuxVtHeader) + 3), queue.queuedBytes());

    const hdr = std.mem.bytesToValue(wire.MuxVtHeader, queue.bytes.items[0..@sizeOf(wire.MuxVtHeader)]);
    try testing.expectEqual(@as(u16, 42), hdr.pane_id);
    try testing.expectEqual(@as(u8, 2), hdr.frame_type);
    try testing.expectEqual(@as(u32, 3), hdr.len);
    try testing.expectEqualStrings("abc", queue.bytes.items[@sizeOf(wire.MuxVtHeader)..]);
}

test "resetForReconnect keeps complete unsent frames, drops a partial one" {
    const testing = std.testing;

    // Case 1: a keystroke enqueued while the channel was down — nothing was ever
    // flushed (read_off == 0), so the frame must SURVIVE the reconnect and go to
    // the new socket. Dropping it here was the lost-keystroke-on-reconnect bug.
    var q1: Queue = .{};
    defer q1.deinit(testing.allocator);
    try testing.expect(try q1.enqueueFrame(testing.allocator, 1, 2, "hi", 1024));
    const before = q1.queuedBytes();
    try testing.expect(before > 0);
    q1.resetForReconnect();
    try testing.expectEqual(before, q1.queuedBytes()); // preserved

    // Case 2: a frame was PARTIALLY written to the old socket (read_off > 0). Its
    // remainder would desync the new multiplexed stream, so the queue is dropped.
    var q2: Queue = .{};
    defer q2.deinit(testing.allocator);
    try testing.expect(try q2.enqueueFrame(testing.allocator, 1, 2, "abcdef", 1024));
    q2.read_off = 3; // simulate a backpressured mid-frame flush
    q2.resetForReconnect();
    try testing.expectEqual(@as(usize, 0), q2.queuedBytes()); // dropped
    try testing.expectEqual(@as(usize, 0), q2.read_off);
}

test "flushToFd drains queued bytes" {
    const testing = std.testing;

    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    var queue: Queue = .{};
    defer queue.deinit(testing.allocator);

    try testing.expect(try queue.enqueueFrame(testing.allocator, 7, 9, "payload", 1024));
    try queue.flushToFd(pipe_fds[1]);

    var buf: [128]u8 = undefined;
    const n = try posix.read(pipe_fds[0], &buf);
    try testing.expectEqual(@as(usize, @sizeOf(wire.MuxVtHeader) + 7), n);

    const hdr = std.mem.bytesToValue(wire.MuxVtHeader, buf[0..@sizeOf(wire.MuxVtHeader)]);
    try testing.expectEqual(@as(u16, 7), hdr.pane_id);
    try testing.expectEqual(@as(u8, 9), hdr.frame_type);
    try testing.expectEqual(@as(u32, 7), hdr.len);
    try testing.expectEqualStrings("payload", buf[@sizeOf(wire.MuxVtHeader)..n]);
    try testing.expectEqual(@as(usize, 0), queue.queuedBytes());
}
