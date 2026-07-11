const std = @import("std");
const core = @import("core");

const posix = std.posix;
const pod_protocol = core.pod_protocol;
const wire = core.wire;

/// Frontend-neutral meaning of a multiplexed VT frame.
///
/// Keep this separate from terminal rendering so non-terminal hosts can process
/// the same SES/POD stream without importing terminal loop code.
pub const VtFrameKind = enum {
    output,
    backlog_end,
    ignored,
};

pub const VtFrameEvent = struct {
    pane_id: u16,
    raw_frame_type: u8,
    kind: VtFrameKind,
    payload_len: u32,
};

pub const VtFrameReadResult = union(enum) {
    frame: VtFrameEvent,
    drained_oversized: VtFrameEvent,
    would_block,
};

pub fn vtFrameKindFromRaw(frame_type: u8) VtFrameKind {
    if (frame_type == @intFromEnum(pod_protocol.FrameType.output)) return .output;
    if (frame_type == @intFromEnum(pod_protocol.FrameType.backlog_end)) return .backlog_end;
    return .ignored;
}

pub fn vtFrameEventFromHeader(header: wire.MuxVtHeader) VtFrameEvent {
    return .{
        .pane_id = header.pane_id,
        .raw_frame_type = header.frame_type,
        .kind = vtFrameKindFromRaw(header.frame_type),
        .payload_len = header.len,
    };
}

/// Read one multiplexed VT frame into `buffer`.
///
/// This keeps frame IO mechanics out of concrete hosts. Hosts still decide how
/// to apply output/backlog events to their view models.
pub fn readMuxVtFrame(fd: posix.fd_t, buffer: []u8) !VtFrameReadResult {
    const header = wire.tryReadMuxVtHeader(fd) catch |err| switch (err) {
        error.WouldBlock => return .would_block,
        else => return err,
    };
    const event = vtFrameEventFromHeader(header);

    if (header.len > buffer.len) {
        var remaining: usize = header.len;
        while (remaining > 0) {
            const chunk = @min(remaining, buffer.len);
            try wire.readExact(fd, buffer[0..chunk]);
            remaining -= chunk;
        }
        return .{ .drained_oversized = event };
    }

    if (header.len > 0) {
        try wire.readExact(fd, buffer[0..header.len]);
    }

    return .{ .frame = event };
}

/// Drain available multiplexed VT frames and dispatch their frontend-neutral
/// meaning to callbacks.
///
/// For normal frames, `payload` aliases `buffer` and is valid only until the
/// next drain iteration. Oversized frames are drained and reported without a
/// payload because their bytes do not fit the caller-provided buffer.
pub fn drainMuxVtFrames(
    fd: posix.fd_t,
    buffer: []u8,
    max_frames: usize,
    context: anytype,
    comptime on_frame: fn (@TypeOf(context), VtFrameEvent, []const u8) bool,
    comptime on_oversized: fn (@TypeOf(context), VtFrameEvent) bool,
) !void {
    var frames: usize = 0;
    while (frames < max_frames) : (frames += 1) {
        switch (try readMuxVtFrame(fd, buffer)) {
            .would_block => break,
            .drained_oversized => |event| {
                if (!on_oversized(context, event)) break;
            },
            .frame => |event| {
                const payload_len: usize = @intCast(event.payload_len);
                if (!on_frame(context, event, buffer[0..payload_len])) break;
            },
        }
    }
}

fn testVtDrainNoopFrame(_: void, _: VtFrameEvent, _: []const u8) bool {
    return true;
}

fn testVtDrainNoopOversized(_: void, _: VtFrameEvent) bool {
    return true;
}

test "vtFrameKindFromRaw classifies frontend-relevant frames" {
    try std.testing.expectEqual(
        VtFrameKind.output,
        vtFrameKindFromRaw(@intFromEnum(pod_protocol.FrameType.output)),
    );
    try std.testing.expectEqual(
        VtFrameKind.backlog_end,
        vtFrameKindFromRaw(@intFromEnum(pod_protocol.FrameType.backlog_end)),
    );
}

test "vtFrameKindFromRaw ignores pod-only frames" {
    try std.testing.expectEqual(
        VtFrameKind.ignored,
        vtFrameKindFromRaw(@intFromEnum(pod_protocol.FrameType.input)),
    );
    try std.testing.expectEqual(
        VtFrameKind.ignored,
        vtFrameKindFromRaw(@intFromEnum(pod_protocol.FrameType.resize)),
    );
}

test "vtFrameEventFromHeader preserves pane id and payload length" {
    const event = vtFrameEventFromHeader(.{
        .pane_id = 42,
        .frame_type = @intFromEnum(pod_protocol.FrameType.output),
        .len = 1234,
    });

    try std.testing.expectEqual(@as(u16, 42), event.pane_id);
    try std.testing.expectEqual(@as(u8, @intFromEnum(pod_protocol.FrameType.output)), event.raw_frame_type);
    try std.testing.expectEqual(VtFrameKind.output, event.kind);
    try std.testing.expectEqual(@as(u32, 1234), event.payload_len);
}

test "drainMuxVtFrames accepts an empty drain without touching fd" {
    const invalid_fd: posix.fd_t = -1;
    var buffer: [1]u8 = undefined;
    try drainMuxVtFrames(invalid_fd, &buffer, 0, {}, testVtDrainNoopFrame, testVtDrainNoopOversized);
}

/// Resumable, fully non-blocking multiplexed-VT frame reader.
///
/// The sender (SES) flushes its queue with non-blocking writes and may leave
/// a PARTIAL frame in the socket under backpressure. The old drain treated a
/// started header as "block until the whole frame arrives" (10s wire default
/// per read) — inside the event-loop poll callback, which wedged the entire
/// frontend for the duration of a large backlog replay. This reader never
/// blocks: it consumes whatever bytes are available, remembers exactly where
/// it stopped (mid-header, mid-payload, or mid-oversized-drain), and resumes
/// on the next call. One instance per VT connection; reset() when the
/// connection is replaced.
pub const MuxVtReader = struct {
    hdr_buf: [@sizeOf(wire.MuxVtHeader)]u8 = undefined,
    hdr_got: usize = 0,
    event: ?VtFrameEvent = null,
    payload_got: usize = 0,
    oversized_remaining: usize = 0,

    pub fn reset(self: *MuxVtReader) void {
        self.* = .{};
    }

    fn readSome(fd: posix.fd_t, out: []u8) !usize {
        const n = posix.read(fd, out) catch |err| switch (err) {
            error.WouldBlock => return 0,
            else => return err,
        };
        if (n == 0) return error.ConnectionClosed;
        return n;
    }

    /// Pump up to `max_frames` COMPLETE frames; returns without blocking when
    /// the socket runs dry (partial progress is kept for the next call).
    pub fn drain(
        self: *MuxVtReader,
        fd: posix.fd_t,
        buffer: []u8,
        max_frames: usize,
        context: anytype,
        comptime on_frame: fn (@TypeOf(context), VtFrameEvent, []const u8) bool,
        comptime on_oversized: fn (@TypeOf(context), VtFrameEvent) bool,
    ) !void {
        var frames: usize = 0;
        while (frames < max_frames) {
            if (self.event == null) {
                // Header phase.
                while (self.hdr_got < self.hdr_buf.len) {
                    const n = try readSome(fd, self.hdr_buf[self.hdr_got..]);
                    if (n == 0) return; // dry mid-header; resume later
                    self.hdr_got += n;
                }
                const header = std.mem.bytesToValue(wire.MuxVtHeader, &self.hdr_buf);
                self.hdr_got = 0;
                self.event = vtFrameEventFromHeader(header);
                self.payload_got = 0;
                self.oversized_remaining = if (header.len > buffer.len) header.len else 0;
            }
            const event = self.event.?;

            if (self.oversized_remaining > 0) {
                // Oversized frame: consume and discard in buffer-sized gulps.
                while (self.oversized_remaining > 0) {
                    const want = @min(self.oversized_remaining, buffer.len);
                    const n = try readSome(fd, buffer[0..want]);
                    if (n == 0) return;
                    self.oversized_remaining -= n;
                }
                self.event = null;
                frames += 1;
                if (!on_oversized(context, event)) return;
                continue;
            }

            const payload_len: usize = @intCast(event.payload_len);
            while (self.payload_got < payload_len) {
                const n = try readSome(fd, buffer[self.payload_got..payload_len]);
                if (n == 0) return; // dry mid-payload; resume later
                self.payload_got += n;
            }
            self.event = null;
            frames += 1;
            if (!on_frame(context, event, buffer[0..payload_len])) return;
        }
    }
};

test "MuxVtReader: resumes a frame split across arbitrary boundaries" {
    var fds: [2]posix.fd_t = undefined;
    const rc = std.os.linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0, &fds);
    try std.testing.expect(rc == 0);
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const Collect = struct {
        var frames: usize = 0;
        var last_len: usize = 0;
        fn onFrame(_: void, event: VtFrameEvent, payload: []const u8) bool {
            frames += 1;
            last_len = payload.len;
            _ = event;
            return true;
        }
        fn onOversized(_: void, _: VtFrameEvent) bool {
            return true;
        }
    };
    Collect.frames = 0;

    var reader = MuxVtReader{};
    var buffer: [64]u8 = undefined;

    // Frame: header (7B) + 10B payload, delivered in 3 fragments.
    var hdr: wire.MuxVtHeader = .{ .pane_id = 1, .frame_type = 1, .len = 10 };
    const hdr_bytes = std.mem.asBytes(&hdr);
    _ = try posix.write(fds[1], hdr_bytes[0..3]); // partial header
    try reader.drain(fds[0], &buffer, 16, {}, Collect.onFrame, Collect.onOversized);
    try std.testing.expectEqual(@as(usize, 0), Collect.frames);

    _ = try posix.write(fds[1], hdr_bytes[3..]); // rest of header
    _ = try posix.write(fds[1], "abcd"); // partial payload
    try reader.drain(fds[0], &buffer, 16, {}, Collect.onFrame, Collect.onOversized);
    try std.testing.expectEqual(@as(usize, 0), Collect.frames);

    _ = try posix.write(fds[1], "efghij"); // rest of payload
    try reader.drain(fds[0], &buffer, 16, {}, Collect.onFrame, Collect.onOversized);
    try std.testing.expectEqual(@as(usize, 1), Collect.frames);
    try std.testing.expectEqual(@as(usize, 10), Collect.last_len);
}
