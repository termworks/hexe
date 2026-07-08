const std = @import("std");
const posix = std.posix;
const ipc = @import("ipc.zig");
const wire = @import("wire.zig");

pub const MAX_FRAME_LEN: usize = wire.MAX_PAYLOAD_LEN;

pub const FrameType = enum(u8) {
    output = 1,
    input = 2,
    resize = 3,
    backlog_end = 4,
    password_mode = 5,
};

pub fn writeFrame(conn: *ipc.Connection, frame_type: FrameType, payload: []const u8) !void {
    if (payload.len > MAX_FRAME_LEN) return error.FrameTooLarge;
    if (payload.len > std.math.maxInt(u32)) return error.FrameTooLarge;

    var header: [5]u8 = undefined;
    header[0] = @intFromEnum(frame_type);
    std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .big);

    try conn.send(&header);
    if (payload.len > 0) {
        try conn.send(payload);
    }
}

/// writeFrame for a NON-BLOCKING fd with a bounded stall budget. A peer that
/// stops draining makes the plain writeFrame block the pod's event loop
/// forever (frozen shell); this variant fails with error.Timeout instead so
/// the caller can drop the connection and heal via backlog replay. A partial
/// frame may have been written on failure — the connection must be dropped,
/// never reused.
pub fn writeFrameBounded(conn: *ipc.Connection, frame_type: FrameType, payload: []const u8, timeout_ms: i32) !void {
    if (payload.len > MAX_FRAME_LEN) return error.FrameTooLarge;
    if (payload.len > std.math.maxInt(u32)) return error.FrameTooLarge;

    var header: [5]u8 = undefined;
    header[0] = @intFromEnum(frame_type);
    std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .big);

    try wire.writeAllTimeout(conn.fd, &header, timeout_ms);
    if (payload.len > 0) {
        try wire.writeAllTimeout(conn.fd, payload, timeout_ms);
    }
}

pub const Frame = struct {
    frame_type: FrameType,
    payload: []const u8,
};

/// Incremental framed stream reader.
///
/// Call `feed()` with newly received bytes; it invokes the callback once
/// per complete frame.
pub const Reader = struct {
    header: [5]u8 = .{ 0, 0, 0, 0, 0 },
    header_len: usize = 0,

    frame_type: FrameType = .output,
    frame_len: usize = 0,
    payload_buf: []u8 = &[_]u8{},
    payload_len: usize = 0,
    skipping: bool = false,
    skip_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, max_len: usize) !Reader {
        return .{ .payload_buf = try allocator.alloc(u8, max_len) };
    }

    pub fn deinit(self: *Reader, allocator: std.mem.Allocator) void {
        allocator.free(self.payload_buf);
        self.* = undefined;
    }

    pub fn reset(self: *Reader) void {
        self.header_len = 0;
        self.frame_len = 0;
        self.payload_len = 0;
        self.skipping = false;
        self.skip_len = 0;
    }

    pub fn feed(self: *Reader, data: []const u8, ctx: *anyopaque, on_frame: *const fn (*anyopaque, Frame) void) void {
        var i: usize = 0;
        while (i < data.len) {
            if (self.skipping) {
                const take = @min(self.skip_len, data.len - i);
                self.skip_len -= take;
                i += take;
                if (self.skip_len == 0) {
                    self.skipping = false;
                    self.header_len = 0;
                }
                continue;
            }
            if (self.header_len < self.header.len) {
                const take = @min(self.header.len - self.header_len, data.len - i);
                @memcpy(self.header[self.header_len .. self.header_len + take], data[i .. i + take]);
                self.header_len += take;
                i += take;

                if (self.header_len == self.header.len) {
                    self.frame_type = std.meta.intToEnum(FrameType, self.header[0]) catch {
                        // Unknown frame type: skip its declared payload rather
                        // than desyncing the stream by reparsing the payload
                        // bytes as the next header (the length is already in
                        // the header we just read).
                        const unknown_len = std.mem.readInt(u32, self.header[1..5], .big);
                        self.payload_len = 0;
                        self.frame_len = 0;
                        if (unknown_len > 0) {
                            self.skipping = true;
                            self.skip_len = unknown_len;
                        } else {
                            self.header_len = 0;
                        }
                        continue;
                    };
                    self.frame_len = std.mem.readInt(u32, self.header[1..5], .big);
                    self.payload_len = 0;

                    if (self.frame_len > self.payload_buf.len) {
                        self.skipping = true;
                        self.skip_len = self.frame_len;
                        continue;
                    }

                    if (self.frame_len == 0) {
                        on_frame(ctx, .{ .frame_type = self.frame_type, .payload = &[_]u8{} });
                        self.header_len = 0;
                    }
                }
                continue;
            }

            const take = @min(self.frame_len - self.payload_len, data.len - i);
            if (take > 0) {
                @memcpy(self.payload_buf[self.payload_len .. self.payload_len + take], data[i .. i + take]);
                self.payload_len += take;
                i += take;
            }

            if (self.payload_len == self.frame_len) {
                on_frame(ctx, .{ .frame_type = self.frame_type, .payload = self.payload_buf[0..self.payload_len] });
                self.header_len = 0;
            }
        }
    }
};

pub fn readExact(fd: posix.fd_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try posix.read(fd, buf[off..]);
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }
}

const testing = std.testing;

const FrameCollector = struct {
    types: [16]FrameType = undefined,
    payloads: [16][64]u8 = undefined,
    payload_lens: [16]usize = undefined,
    count: usize = 0,

    fn onFrame(ctx: *anyopaque, frame: Frame) void {
        const self: *FrameCollector = @ptrCast(@alignCast(ctx));
        if (self.count >= self.types.len) return;
        self.types[self.count] = frame.frame_type;
        const n = @min(frame.payload.len, self.payloads[self.count].len);
        @memcpy(self.payloads[self.count][0..n], frame.payload[0..n]);
        self.payload_lens[self.count] = n;
        self.count += 1;
    }

    fn payload(self: *const FrameCollector, idx: usize) []const u8 {
        return self.payloads[idx][0..self.payload_lens[idx]];
    }
};

/// Encode a raw frame (type byte + u32 big-endian length + payload) for tests.
fn encodeFrame(buf: []u8, type_byte: u8, payload: []const u8) usize {
    buf[0] = type_byte;
    std.mem.writeInt(u32, buf[1..5], @intCast(payload.len), .big);
    @memcpy(buf[5 .. 5 + payload.len], payload);
    return 5 + payload.len;
}

test "pod_protocol.Reader: parses a single frame" {
    var reader = try Reader.init(testing.allocator, 1024);
    defer reader.deinit(testing.allocator);

    var raw: [64]u8 = undefined;
    const n = encodeFrame(&raw, @intFromEnum(FrameType.output), "hello");

    var col = FrameCollector{};
    reader.feed(raw[0..n], &col, FrameCollector.onFrame);

    try testing.expectEqual(@as(usize, 1), col.count);
    try testing.expectEqual(FrameType.output, col.types[0]);
    try testing.expectEqualStrings("hello", col.payload(0));
}

test "pod_protocol.Reader: reassembles a frame split across feeds" {
    var reader = try Reader.init(testing.allocator, 1024);
    defer reader.deinit(testing.allocator);

    var raw: [64]u8 = undefined;
    const n = encodeFrame(&raw, @intFromEnum(FrameType.input), "abcdef");

    var col = FrameCollector{};
    // Split mid-header and mid-payload.
    reader.feed(raw[0..3], &col, FrameCollector.onFrame);
    reader.feed(raw[3..7], &col, FrameCollector.onFrame);
    reader.feed(raw[7..n], &col, FrameCollector.onFrame);

    try testing.expectEqual(@as(usize, 1), col.count);
    try testing.expectEqual(FrameType.input, col.types[0]);
    try testing.expectEqualStrings("abcdef", col.payload(0));
}

test "pod_protocol.Reader: parses multiple frames in one feed" {
    var reader = try Reader.init(testing.allocator, 1024);
    defer reader.deinit(testing.allocator);

    var raw: [128]u8 = undefined;
    var off: usize = 0;
    off += encodeFrame(raw[off..], @intFromEnum(FrameType.output), "one");
    off += encodeFrame(raw[off..], @intFromEnum(FrameType.backlog_end), "");
    off += encodeFrame(raw[off..], @intFromEnum(FrameType.output), "two");

    var col = FrameCollector{};
    reader.feed(raw[0..off], &col, FrameCollector.onFrame);

    try testing.expectEqual(@as(usize, 3), col.count);
    try testing.expectEqualStrings("one", col.payload(0));
    try testing.expectEqual(FrameType.backlog_end, col.types[1]);
    try testing.expectEqualStrings("two", col.payload(2));
}

test "pod_protocol.Reader: skips an unknown frame type without desyncing (regression)" {
    var reader = try Reader.init(testing.allocator, 1024);
    defer reader.deinit(testing.allocator);

    var raw: [128]u8 = undefined;
    var off: usize = 0;
    // Unknown type 99 with a 4-byte payload, then a valid frame. Before the
    // fix the unknown payload was reparsed as a header and the valid frame was
    // lost / mis-decoded.
    off += encodeFrame(raw[off..], 99, "XXXX");
    off += encodeFrame(raw[off..], @intFromEnum(FrameType.output), "ok");

    var col = FrameCollector{};
    reader.feed(raw[0..off], &col, FrameCollector.onFrame);

    try testing.expectEqual(@as(usize, 1), col.count);
    try testing.expectEqual(FrameType.output, col.types[0]);
    try testing.expectEqualStrings("ok", col.payload(0));
}

test "pod_protocol.Reader: skips an over-capacity frame and resumes" {
    var reader = try Reader.init(testing.allocator, 8);
    defer reader.deinit(testing.allocator);

    var raw: [128]u8 = undefined;
    var off: usize = 0;
    off += encodeFrame(raw[off..], @intFromEnum(FrameType.output), "way too long payload"); // > 8
    off += encodeFrame(raw[off..], @intFromEnum(FrameType.output), "fits");

    var col = FrameCollector{};
    reader.feed(raw[0..off], &col, FrameCollector.onFrame);

    try testing.expectEqual(@as(usize, 1), col.count);
    try testing.expectEqualStrings("fits", col.payload(0));
}

test "writeFrameBounded: wedged peer yields Timeout, not a hang" {
    var fds: [2]posix.fd_t = undefined;
    const rc = std.os.linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    try std.testing.expect(rc == 0);
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    // Simulate a wedged SES: tiny send buffer, nobody reading the peer end.
    const sndbuf: c_int = 4096;
    try posix.setsockopt(fds[0], posix.SOL.SOCKET, posix.SO.SNDBUF, std.mem.asBytes(&sndbuf));
    try ipc.setNonBlocking(fds[0]);

    var conn = ipc.Connection{ .fd = fds[0] };
    var big: [256 * 1024]u8 = undefined;
    @memset(&big, 'x');

    const started = std.time.milliTimestamp();
    // Must fail with Timeout within roughly the budget — never block forever.
    try std.testing.expectError(
        error.Timeout,
        writeFrameBounded(&conn, .output, &big, 100),
    );
    const elapsed = std.time.milliTimestamp() - started;
    try std.testing.expect(elapsed < 5_000);
}
