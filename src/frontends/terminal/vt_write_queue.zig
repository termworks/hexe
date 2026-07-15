const std = @import("std");
const posix = std.posix;
const core = @import("core");

const wire = core.wire;
const pod_protocol = core.pod_protocol;

/// mux→pod INPUT frames carry a 16-byte `[epoch:u64][seq:u64]` prefix at the
/// front of their payload, so the pod can dedup replays after a VT reconnect
/// (exactly-once input). SES forwards the payload opaquely; only the frontend
/// writes this prefix and only the pod strips it. Keyed on frame_type == input,
/// so resize/password framing is unchanged.
pub const INPUT_SEQ_PREFIX_LEN: usize = 16;
const INPUT_FRAME_TYPE: u8 = @intFromEnum(pod_protocol.FrameType.input);

pub const Queue = struct {
    bytes: std.ArrayList(u8) = .empty,
    read_off: usize = 0,
    /// Per-frontend-process input identity (0 until set by the owner). A frame's
    /// (epoch, seq) is stamped when it is first enqueued; a replay reuses it.
    epoch: u64 = 0,
    next_seq: u64 = 0,

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

        // Only INPUT frames carry the (epoch, seq) prefix; resize/password are
        // unchanged. A fresh seq is stamped here, at first enqueue.
        const is_input = frame_type == INPUT_FRAME_TYPE;
        const prefix_len: usize = if (is_input) INPUT_SEQ_PREFIX_LEN else 0;
        const wire_payload_len = prefix_len + payload.len;

        const needed = @sizeOf(wire.MuxVtHeader) + wire_payload_len;
        if (self.queuedBytes() + needed > max_pending_bytes) return false;

        var hdr = wire.MuxVtHeader{
            .pane_id = pane_id,
            .frame_type = frame_type,
            .len = @intCast(wire_payload_len),
        };
        try self.bytes.appendSlice(allocator, std.mem.asBytes(&hdr));
        if (is_input) {
            self.next_seq += 1;
            var prefix: [INPUT_SEQ_PREFIX_LEN]u8 = undefined;
            std.mem.writeInt(u64, prefix[0..8], self.epoch, .little);
            std.mem.writeInt(u64, prefix[8..16], self.next_seq, .little);
            try self.bytes.appendSlice(allocator, &prefix);
        }
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

test "enqueueFrame stamps an (epoch, seq) prefix on INPUT frames" {
    const testing = std.testing;
    const H = @sizeOf(wire.MuxVtHeader);

    var queue: Queue = .{};
    defer queue.deinit(testing.allocator);
    queue.epoch = 0xABCD;

    // frame_type 2 == input → header.len covers the 16-byte prefix + payload.
    try testing.expect(try queue.enqueueFrame(testing.allocator, 42, INPUT_FRAME_TYPE, "abc", 1024));
    try testing.expectEqual(@as(usize, H + INPUT_SEQ_PREFIX_LEN + 3), queue.queuedBytes());

    const hdr = std.mem.bytesToValue(wire.MuxVtHeader, queue.bytes.items[0..H]);
    try testing.expectEqual(@as(u16, 42), hdr.pane_id);
    try testing.expectEqual(INPUT_FRAME_TYPE, hdr.frame_type);
    try testing.expectEqual(@as(u32, INPUT_SEQ_PREFIX_LEN + 3), hdr.len);

    const epoch = std.mem.readInt(u64, queue.bytes.items[H..][0..8], .little);
    const seq = std.mem.readInt(u64, queue.bytes.items[H + 8 ..][0..8], .little);
    try testing.expectEqual(@as(u64, 0xABCD), epoch);
    try testing.expectEqual(@as(u64, 1), seq); // first frame → seq 1
    try testing.expectEqualStrings("abc", queue.bytes.items[H + INPUT_SEQ_PREFIX_LEN ..]);

    // A second input frame advances the seq.
    try testing.expect(try queue.enqueueFrame(testing.allocator, 42, INPUT_FRAME_TYPE, "d", 1024));
    try testing.expectEqual(@as(u64, 2), queue.next_seq);
}

test "enqueueFrame does NOT prefix non-input frames (resize/password)" {
    const testing = std.testing;
    const H = @sizeOf(wire.MuxVtHeader);

    var queue: Queue = .{};
    defer queue.deinit(testing.allocator);

    // frame_type 3 == resize → no prefix, framing unchanged.
    try testing.expect(try queue.enqueueFrame(testing.allocator, 7, 3, "\x00\x50\x00\x18", 1024));
    try testing.expectEqual(@as(usize, H + 4), queue.queuedBytes());
    const hdr = std.mem.bytesToValue(wire.MuxVtHeader, queue.bytes.items[0..H]);
    try testing.expectEqual(@as(u32, 4), hdr.len);
    try testing.expectEqual(@as(u64, 0), queue.next_seq); // seq untouched by non-input
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
