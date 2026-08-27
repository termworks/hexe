const std = @import("std");
const log = std.log;
const linux = std.os.linux;
const link = @import("link.zig");
const addr = @import("address.zig");
const route = @import("route.zig");

const Self = @This();
const MAX_ACK_FRAMES = 64;

fd: std.posix.socket_t,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) !Self {
    const fd = try std.posix.socket(linux.AF.NETLINK, linux.SOCK.RAW, linux.NETLINK.ROUTE);
    const kernel_addr = linux.sockaddr.nl{ .pid = 0, .groups = 0 };
    std.posix.bind(fd, @ptrCast(&kernel_addr), @sizeOf(@TypeOf(kernel_addr))) catch {
        std.posix.close(fd);
        return error.BindFailed;
    };

    return .{ .allocator = allocator, .fd = fd };
}

pub fn deinit(self: *Self) void {
    std.posix.close(self.fd);
}

pub fn send(self: *Self, msg: []const u8) !void {
    const sent = try std.posix.send(self.fd, msg, 0);
    if (sent != msg.len) return error.ShortWrite;
}

pub fn recv(self: *Self, buff: []u8) !usize {
    const n = try std.posix.recv(self.fd, buff, 0);
    if (n == 0) {
        return error.InvalidResponse;
    }
    return n;
}

pub fn recv_ack(self: *Self) !void {
    var buff: [512]u8 = std.mem.zeroes([512]u8);
    const n = try std.posix.recv(self.fd, &buff, 0);
    if (n < @sizeOf(linux.nlmsghdr)) {
        return error.InvalidResponse;
    }

    var start: usize = 0;
    var frame_count: usize = 0;
    while (start + @sizeOf(linux.nlmsghdr) <= n) {
        if (ackFrameCountExceeded(frame_count)) return error.TooManyAckFrames;
        const header = std.mem.bytesAsValue(linux.nlmsghdr, buff[start .. start + @sizeOf(linux.nlmsghdr)]);
        if (header.len < @sizeOf(linux.nlmsghdr)) return error.InvalidResponse;
        const frame_len = align4(header.len);
        if (start + frame_len > n) return error.InvalidResponse;
        const frame = buff[start .. start + header.len];

        switch (header.type) {
            .DONE => return,
            .ERROR => {
                const err_code = try parseNetlinkErrorCode(frame);
                return handle_ack_code(err_code);
            },
            .NOOP => {},
            else => return error.InvalidResponse,
        }

        frame_count += 1;
        start += frame_len;
    }

    return error.InvalidResponse;
}

pub fn handle_ack_code(err_code: i32) !void {
    if (err_code > 0) return error.InvalidResponse;
    if (err_code == std.math.minInt(i32)) return error.InvalidResponse;

    const errno_num: u16 = @intCast(-err_code);
    const code: linux.E = @enumFromInt(errno_num);
    if (code != .SUCCESS) {
        log.info("err: {}", .{code});
        return switch (code) {
            .EXIST => error.Exists,
            else => error.Error,
        };
    }
}

pub fn parseNetlinkErrorCode(frame: []const u8) !i32 {
    if (frame.len < @sizeOf(linux.nlmsghdr) + @sizeOf(i32)) return error.InvalidResponse;
    const header = std.mem.bytesAsValue(linux.nlmsghdr, frame[0..@sizeOf(linux.nlmsghdr)]);
    if (header.type != .ERROR) return error.InvalidResponse;
    const err_ptr = std.mem.bytesAsValue(i32, frame[@sizeOf(linux.nlmsghdr) .. @sizeOf(linux.nlmsghdr) + @sizeOf(i32)]);
    return err_ptr.*;
}

fn align4(v: usize) usize {
    return std.mem.alignForward(usize, v, 4);
}

fn ackFrameCountExceeded(current_count: usize) bool {
    return current_count >= MAX_ACK_FRAMES;
}

fn countOpenFds() !usize {
    var dir = try std.fs.openDirAbsolute("/proc/self/fd", .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    var count: usize = 0;
    while (try iter.next()) |_| {
        count += 1;
    }
    return count;
}

pub fn linkAdd(self: *Self, options: link.LinkAdd.Options) !void {
    var la = link.LinkAdd.init(self.allocator, self, options);
    defer la.msg.deinit();
    return la.exec();
}

pub fn linkGet(self: *Self, options: link.LinkGet.Options) !link.LinkMessage {
    var lg = link.LinkGet.init(self.allocator, self, options);
    defer lg.msg.deinit();
    return lg.exec();
}

pub fn linkSet(self: *Self, options: link.LinkSet.Options) !void {
    var ls = link.LinkSet.init(self.allocator, self, options);
    defer ls.msg.deinit();
    try ls.exec();
}

pub fn linkDel(self: *Self, index: c_int) !void {
    var ls = link.LinkDelete.init(self.allocator, self, index);
    defer ls.msg.deinit();
    try ls.exec();
}

pub fn addrAdd(self: *Self, options: addr.AddrAdd.Options) !void {
    var a = addr.AddrAdd.init(self.allocator, self, options);
    defer a.msg.deinit();
    return a.exec();
}

pub fn routeAdd(self: *Self, options: route.RouteAdd.Options) !void {
    var ls = route.RouteAdd.init(self.allocator, self, options);
    defer ls.msg.deinit();
    try ls.exec();
}

/// get all ipv4 routes
pub fn routeGet(self: *Self) ![]route.RouteMessage {
    var ls = route.RouteGet.init(self.allocator, self);
    defer ls.msg.deinit();
    return ls.exec();
}

test "parseNetlinkErrorCode extracts errno field" {
    const len = @sizeOf(linux.nlmsghdr) + @sizeOf(i32);
    var buff: [len]u8 = [_]u8{0} ** len;

    const hdr = linux.nlmsghdr{
        .len = @intCast(len),
        .type = .ERROR,
        .flags = 0,
        .seq = 0,
        .pid = 0,
    };
    const errno_value: i32 = -@as(i32, @intFromEnum(linux.E.EXIST));

    @memcpy(buff[0..@sizeOf(linux.nlmsghdr)], std.mem.asBytes(&hdr));
    @memcpy(buff[@sizeOf(linux.nlmsghdr) .. @sizeOf(linux.nlmsghdr) + @sizeOf(i32)], std.mem.asBytes(&errno_value));

    try std.testing.expectEqual(errno_value, try parseNetlinkErrorCode(&buff));
}

test "parseNetlinkErrorCode rejects truncated frame" {
    var buff: [@sizeOf(linux.nlmsghdr)]u8 = [_]u8{0} ** @sizeOf(linux.nlmsghdr);
    try std.testing.expectError(error.InvalidResponse, parseNetlinkErrorCode(&buff));
}

test "parseNetlinkErrorCode rejects non-error header type" {
    const len = @sizeOf(linux.nlmsghdr) + @sizeOf(i32);
    var buff: [len]u8 = [_]u8{0} ** len;
    const hdr = linux.nlmsghdr{
        .len = @intCast(len),
        .type = .DONE,
        .flags = 0,
        .seq = 0,
        .pid = 0,
    };
    @memcpy(buff[0..@sizeOf(linux.nlmsghdr)], std.mem.asBytes(&hdr));
    try std.testing.expectError(error.InvalidResponse, parseNetlinkErrorCode(&buff));
}

test "align4 rounds values to 4-byte boundary" {
    try std.testing.expectEqual(@as(usize, 4), align4(1));
    try std.testing.expectEqual(@as(usize, 4), align4(4));
    try std.testing.expectEqual(@as(usize, 8), align4(5));
}

test "ackFrameCountExceeded enforces ack frame cap" {
    try std.testing.expect(!ackFrameCountExceeded(MAX_ACK_FRAMES - 1));
    try std.testing.expect(ackFrameCountExceeded(MAX_ACK_FRAMES));
}

test "repeated rtnetlink init/deinit keeps fd count stable" {
    const before = try countOpenFds();

    var i: usize = 0;
    while (i < 64) : (i += 1) {
        var nl = try Self.init(std.testing.allocator);
        nl.deinit();
    }

    const after = try countOpenFds();
    try std.testing.expectEqual(before, after);
}

test "handle_ack_code treats zero as success" {
    try handle_ack_code(0);
}

test "handle_ack_code maps EEXIST to Exists" {
    const err_code: i32 = -@as(i32, @intFromEnum(linux.E.EXIST));
    try std.testing.expectError(error.Exists, handle_ack_code(err_code));
}

test "handle_ack_code maps unknown errors to generic Error" {
    const err_code: i32 = -@as(i32, @intFromEnum(linux.E.PERM));
    try std.testing.expectError(error.Error, handle_ack_code(err_code));
}

test "handle_ack_code rejects positive error values" {
    try std.testing.expectError(error.InvalidResponse, handle_ack_code(1));
}

test "handle_ack_code rejects min int overflow case" {
    try std.testing.expectError(error.InvalidResponse, handle_ack_code(std.math.minInt(i32)));
}
