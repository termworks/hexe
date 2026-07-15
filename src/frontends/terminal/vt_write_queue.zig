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

/// How many bytes of recently-sent frames to retain for replay-on-reconnect.
/// This is the exactly-once safety window: frames sent within the last ~64 KB
/// of pane→pod traffic can be re-delivered after a reconnect (the pod dedups the
/// ones it already applied). 64 KB is thousands of keystrokes — far more than
/// anyone types during the sub-second reconnect window.
pub const REPLAY_CAP_BYTES: usize = 64 * 1024;

pub const Queue = struct {
    bytes: std.ArrayList(u8) = .empty,
    read_off: usize = 0,
    /// Per-frontend-process input identity (0 until set by the owner). A frame's
    /// (epoch, seq) is stamped when it is first enqueued; a replay reuses it.
    epoch: u64 = 0,
    next_seq: u64 = 0,

    /// Replay ring: the full wire bytes of recently-enqueued frames, retained
    /// AFTER they leave the live queue. On a VT reconnect the whole ring is
    /// re-sent so nothing typed around the disconnect is lost; the pod dedups
    /// (by the input prefix's seq) anything it already applied. Bounded by
    /// REPLAY_CAP_BYTES, oldest whole frames pruned first.
    replay: std.ArrayList(u8) = .empty,
    replay_head: usize = 0,

    pub fn deinit(self: *Queue, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.replay.deinit(allocator);
        self.* = .{};
    }

    pub fn clear(self: *Queue) void {
        self.bytes.clearRetainingCapacity();
        self.read_off = 0;
    }

    /// Rebuild the live queue for a brand-new SES VT connection from the replay
    /// ring, so input typed around the disconnect survives.
    ///
    /// The live queue is dropped (a partially-written head frame's first bytes
    /// already went to the OLD socket; replaying its remainder would desync the
    /// new multiplexed stream). The ring holds the FULL, intact frames, so we
    /// re-send those instead — the old partial bytes die with the old socket,
    /// and the pod deduplicates any frame it already applied via the (epoch,seq)
    /// prefix. Replayed frames go out BEFORE any new input (the loop enqueues
    /// new keystrokes after this), preserving order.
    pub fn rebuildForReconnect(self: *Queue, allocator: std.mem.Allocator) void {
        self.clear();
        const pending = self.replay.items[self.replay_head..];
        if (pending.len == 0) return;
        self.bytes.appendSlice(allocator, pending) catch {
            // OOM: fall back to dropping — worse than a replay, but never a crash.
            self.clear();
        };
    }

    pub fn queuedBytes(self: *const Queue) usize {
        if (self.read_off >= self.bytes.items.len) return 0;
        return self.bytes.items.len - self.read_off;
    }

    /// Append a just-built frame (its full wire bytes) to the replay ring and
    /// prune whole oldest frames until under the cap.
    fn retainForReplay(self: *Queue, allocator: std.mem.Allocator, frame: []const u8) void {
        // A single frame larger than the whole window can never be retained (a
        // multi-MB paste chunk); note it rather than silently pretend it's safe.
        if (frame.len > REPLAY_CAP_BYTES) {
            core.logging.warn("terminal", "input frame ({d} B) exceeds replay window; not retained for reconnect", .{frame.len});
            return;
        }
        self.replay.appendSlice(allocator, frame) catch return; // OOM: skip retain
        // Prune whole frames from the front while over the cap.
        while (self.replay.items.len - self.replay_head > REPLAY_CAP_BYTES) {
            const total = frameTotalLen(self.replay.items[self.replay_head..]) orelse break;
            self.replay_head += total;
        }
        // Compact the front offset occasionally so it can't grow unbounded.
        if (self.replay_head > REPLAY_CAP_BYTES) {
            const remaining = self.replay.items.len - self.replay_head;
            std.mem.copyForwards(u8, self.replay.items[0..remaining], self.replay.items[self.replay_head..]);
            self.replay.items.len = remaining;
            self.replay_head = 0;
        }
    }

    /// Byte length of the frame at the front of `buf` (MuxVtHeader + payload),
    /// or null if the buffer is too short to hold even a header.
    fn frameTotalLen(buf: []const u8) ?usize {
        const H = @sizeOf(wire.MuxVtHeader);
        if (buf.len < H) return null;
        const hdr = std.mem.bytesToValue(wire.MuxVtHeader, buf[0..H]);
        return H + hdr.len;
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

        const frame_start = self.bytes.items.len;
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

        // Retain the exact wire bytes for replay-on-reconnect (all frame types;
        // the pod dedups input by seq and re-applies resize/password harmlessly).
        self.retainForReplay(allocator, self.bytes.items[frame_start..]);
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

test "rebuildForReconnect re-sends the replay ring as whole frames" {
    const testing = std.testing;

    // A keystroke sent (fully flushed → dropped from the live queue) is still in
    // the replay ring. On reconnect it must be re-queued whole for the new socket
    // so it is not lost — even though the live queue was empty.
    var q: Queue = .{};
    defer q.deinit(testing.allocator);
    q.epoch = 7;
    try testing.expect(try q.enqueueFrame(testing.allocator, 1, INPUT_FRAME_TYPE, "hi", 1024));
    // Simulate a full flush: the live queue drains, but the ring retains it.
    q.read_off = q.bytes.items.len;
    q.compact();
    try testing.expectEqual(@as(usize, 0), q.queuedBytes()); // live queue empty

    q.rebuildForReconnect(testing.allocator);
    // The frame is back in the live queue, header + prefix + "hi".
    const H = @sizeOf(wire.MuxVtHeader);
    try testing.expectEqual(@as(usize, H + INPUT_SEQ_PREFIX_LEN + 2), q.queuedBytes());
    const hdr = std.mem.bytesToValue(wire.MuxVtHeader, q.bytes.items[0..H]);
    try testing.expectEqual(INPUT_FRAME_TYPE, hdr.frame_type);
    // The replayed frame keeps its ORIGINAL seq (1) — essential for dedup.
    const seq = std.mem.readInt(u64, q.bytes.items[H + 8 ..][0..8], .little);
    try testing.expectEqual(@as(u64, 1), seq);
}

test "replay ring prunes oldest whole frames past the cap" {
    const testing = std.testing;

    var q: Queue = .{};
    defer q.deinit(testing.allocator);
    // Enqueue far more than the cap; the ring must stay bounded and never split
    // a frame across the prune boundary.
    var i: usize = 0;
    while (i < 20000) : (i += 1) {
        _ = try q.enqueueFrame(testing.allocator, 1, INPUT_FRAME_TYPE, "x", 64 * 1024 * 1024);
        // Keep the live queue from growing unbounded (irrelevant to the ring).
        q.clear();
    }
    const retained = q.replay.items.len - q.replay_head;
    try testing.expect(retained <= REPLAY_CAP_BYTES);
    // The retained region must start on a frame boundary (parse cleanly to end).
    var off: usize = q.replay_head;
    var frames: usize = 0;
    while (off < q.replay.items.len) {
        const total = Queue.frameTotalLen(q.replay.items[off..]) orelse break;
        off += total;
        frames += 1;
    }
    try testing.expectEqual(q.replay.items.len, off); // no trailing partial frame
    try testing.expect(frames > 0);
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
