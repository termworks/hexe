const std = @import("std");
const linux = std.os.linux;
const log = std.log;
const NetLink = @import("../rtnetlink.zig");
const RouteMessage = @import("route.zig");
const Attr = @import("attrs.zig").RtAttr;
const nalign = @import("../utils.zig").nalign;
const MAX_ROUTE_MESSAGES = 4096;
const MAX_ROUTE_ATTRS = 1024;
const MAX_ROUTE_PACKETS = 256;

const Get = @This();

msg: RouteMessage,
nl: *NetLink,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, nl: *NetLink) Get {
    var msg = RouteMessage.init(allocator, .get);
    msg.msg.hdr.scope = .Universe;
    msg.msg.hdr.type = .Unspec;
    msg.msg.hdr.table = .Unspec;
    msg.msg.hdr.protocol = .Unspec;

    msg.hdr.flags |= linux.NLM_F_DUMP;

    return .{
        .nl = nl,
        .msg = msg,
        .allocator = allocator,
    };
}

pub fn exec(self: *Get) ![]RouteMessage {
    const msg = try self.msg.compose();
    defer self.allocator.free(msg);

    try self.nl.send(msg);
    return try self.recv();
}

fn recv(self: *Get) ![]RouteMessage {
    var buff: [4096]u8 = undefined;

    var n = try self.nl.recv(&buff);
    var packet_count: usize = 0;

    var response = std.ArrayList(RouteMessage).empty;
    errdefer {
        for (response.items) |*msg| {
            msg.deinit();
        }
        response.deinit(self.allocator);
    }
    outer: while (n != 0) {
        if (routePacketCountExceeded(packet_count)) return error.TooManyRoutePackets;
        var d: usize = 0;
        while (d < n) {
            const msg = (try self.parseMessage(buff[d..n])) orelse break :outer;
            if (routeCountExceeded(response.items.len)) return error.TooManyRoutes;
            try response.append(self.allocator, msg);
            if (msg.hdr.len == 0) return error.InvalidResponse;
            const frame_len = nalign(msg.hdr.len);
            if (d + frame_len > n) return error.InvalidResponse;
            d += frame_len;
        }
        packet_count += 1;
        n = try self.nl.recv(&buff);
    }
    return response.toOwnedSlice(self.allocator);
}

fn parseMessage(self: *Get, buff: []u8) !?RouteMessage {
    if (buff.len < @sizeOf(linux.nlmsghdr)) return error.InvalidResponse;

    const header = std.mem.bytesAsValue(linux.nlmsghdr, buff[0..@sizeOf(linux.nlmsghdr)]);
    if (header.len < @sizeOf(linux.nlmsghdr) or header.len > buff.len) return error.InvalidResponse;
    const frame = buff[0..header.len];
    if (header.type == .ERROR) {
        const err_code = try NetLink.parseNetlinkErrorCode(frame);
        try NetLink.handle_ack_code(err_code);
        return null;
    } else if (header.type == .DONE) {
        return null;
    } else if (header.type != .RTM_NEWROUTE) {
        return error.InvalidResponse;
    }

    if (header.len < @sizeOf(linux.nlmsghdr) + @sizeOf(RouteMessage.RouteHeader)) {
        return error.InvalidResponse;
    }

    var msg = RouteMessage.init(self.allocator, .create);
    errdefer msg.deinit();

    const len = header.len;
    msg.hdr = header.*;

    const hdr = std.mem.bytesAsValue(RouteMessage.RouteHeader, frame[@sizeOf(linux.nlmsghdr)..]);
    msg.msg.hdr = hdr.*;

    var start: usize = @sizeOf(RouteMessage.RouteHeader) + @sizeOf(linux.nlmsghdr);
    var attr_count: usize = 0;
    while (start + @sizeOf(Attr) <= len) {
        if (routeAttrCountExceeded(attr_count)) return error.TooManyRouteAttrs;
        const attr = std.mem.bytesAsValue(Attr, frame[start .. start + @sizeOf(Attr)]);
        if (attr.len < @sizeOf(Attr)) return error.InvalidResponse;
        if (start + attr.len > len) return error.InvalidResponse;
        const payload_len = attr.len - @sizeOf(Attr);
        switch (attr.type) {
            .Dst => {
                if (msg.msg.hdr.family != linux.AF.INET) return error.UnsupportedAddressFamily;
                if (payload_len != 4) return error.InvalidResponse;
                try msg.addAttr(.{ .destination = frame[start + @sizeOf(Attr) .. start + @sizeOf(Attr) + 4][0..4].* });
            },
            .Gateway => {
                if (msg.msg.hdr.family != linux.AF.INET) return error.UnsupportedAddressFamily;
                if (payload_len != 4) return error.InvalidResponse;
                try msg.addAttr(.{ .gateway = frame[start + @sizeOf(Attr) .. start + @sizeOf(Attr) + 4][0..4].* });
            },
            .Prefsrc => {
                if (msg.msg.hdr.family != linux.AF.INET) return error.UnsupportedAddressFamily;
                if (payload_len != 4) return error.InvalidResponse;
                try msg.addAttr(.{ .preferred_source = frame[start + @sizeOf(Attr) .. start + @sizeOf(Attr) + 4][0..4].* });
            },
            .Oif => {
                if (payload_len != @sizeOf(u32)) return error.InvalidResponse;
                const value = std.mem.bytesAsValue(u32, frame[start + @sizeOf(Attr) .. start + @sizeOf(Attr) + @sizeOf(u32)]);
                try msg.addAttr(.{ .output_if = value.* });
            },
            else => {},
        }

        attr_count += 1;
        start += nalign(attr.len);
    }

    if (!hasOnlyZeroPadding(frame[start..len])) return error.InvalidResponse;

    return msg;
}

fn hasOnlyZeroPadding(bytes: []const u8) bool {
    for (bytes) |b| {
        if (b != 0) return false;
    }
    return true;
}

fn routeCountExceeded(current_count: usize) bool {
    return current_count >= MAX_ROUTE_MESSAGES;
}

fn routeAttrCountExceeded(current_count: usize) bool {
    return current_count >= MAX_ROUTE_ATTRS;
}

fn routePacketCountExceeded(current_count: usize) bool {
    return current_count >= MAX_ROUTE_PACKETS;
}

test "parseMessage returns null for DONE frame" {
    var get = Get{ .msg = undefined, .nl = undefined, .allocator = std.testing.allocator };
    var buff: [@sizeOf(linux.nlmsghdr)]u8 = [_]u8{0} ** @sizeOf(linux.nlmsghdr);
    const hdr = linux.nlmsghdr{
        .len = @intCast(@sizeOf(linux.nlmsghdr)),
        .type = .DONE,
        .flags = 0,
        .seq = 0,
        .pid = 0,
    };
    @memcpy(buff[0..@sizeOf(linux.nlmsghdr)], std.mem.asBytes(&hdr));
    try std.testing.expect((try get.parseMessage(&buff)) == null);
}

test "parseMessage rejects zero-length header" {
    var get = Get{ .msg = undefined, .nl = undefined, .allocator = std.testing.allocator };
    var buff: [@sizeOf(linux.nlmsghdr)]u8 = [_]u8{0} ** @sizeOf(linux.nlmsghdr);
    const hdr = linux.nlmsghdr{
        .len = 0,
        .type = .RTM_NEWROUTE,
        .flags = 0,
        .seq = 0,
        .pid = 0,
    };
    @memcpy(buff[0..@sizeOf(linux.nlmsghdr)], std.mem.asBytes(&hdr));
    try std.testing.expectError(error.InvalidResponse, get.parseMessage(&buff));
}

test "parseMessage rejects malformed route attribute length" {
    var get = Get{ .msg = undefined, .nl = undefined, .allocator = std.testing.allocator };
    const total_len = @sizeOf(linux.nlmsghdr) + @sizeOf(RouteMessage.RouteHeader) + @sizeOf(Attr);
    var buff: [total_len]u8 = [_]u8{0} ** total_len;

    const hdr = linux.nlmsghdr{
        .len = @intCast(total_len),
        .type = .RTM_NEWROUTE,
        .flags = 0,
        .seq = 0,
        .pid = 0,
    };
    @memcpy(buff[0..@sizeOf(linux.nlmsghdr)], std.mem.asBytes(&hdr));

    const route_hdr = RouteMessage.RouteHeader{};
    const route_off = @sizeOf(linux.nlmsghdr);
    @memcpy(buff[route_off .. route_off + @sizeOf(RouteMessage.RouteHeader)], std.mem.asBytes(&route_hdr));

    const bad_attr = Attr{ .len = @intCast(@sizeOf(Attr) - 1), .type = .Gateway };
    const attr_off = route_off + @sizeOf(RouteMessage.RouteHeader);
    @memcpy(buff[attr_off .. attr_off + @sizeOf(Attr)], std.mem.asBytes(&bad_attr));

    try std.testing.expectError(error.InvalidResponse, get.parseMessage(&buff));
}

test "parseMessage rejects route attribute overrunning frame" {
    var get = Get{ .msg = undefined, .nl = undefined, .allocator = std.testing.allocator };
    const total_len = @sizeOf(linux.nlmsghdr) + @sizeOf(RouteMessage.RouteHeader) + @sizeOf(Attr);
    var buff: [total_len]u8 = [_]u8{0} ** total_len;

    const hdr = linux.nlmsghdr{
        .len = @intCast(total_len),
        .type = .RTM_NEWROUTE,
        .flags = 0,
        .seq = 0,
        .pid = 0,
    };
    @memcpy(buff[0..@sizeOf(linux.nlmsghdr)], std.mem.asBytes(&hdr));

    const route_hdr = RouteMessage.RouteHeader{};
    const route_off = @sizeOf(linux.nlmsghdr);
    @memcpy(buff[route_off .. route_off + @sizeOf(RouteMessage.RouteHeader)], std.mem.asBytes(&route_hdr));

    const bad_attr = Attr{ .len = @intCast(@sizeOf(Attr) + 8), .type = .Gateway };
    const attr_off = route_off + @sizeOf(RouteMessage.RouteHeader);
    @memcpy(buff[attr_off .. attr_off + @sizeOf(Attr)], std.mem.asBytes(&bad_attr));

    try std.testing.expectError(error.InvalidResponse, get.parseMessage(&buff));
}

test "parseMessage repeated parse/deinit does not leak" {
    var get = Get{ .msg = undefined, .nl = undefined, .allocator = std.testing.allocator };
    const total_len = @sizeOf(linux.nlmsghdr) + @sizeOf(RouteMessage.RouteHeader);
    var buff: [total_len]u8 = [_]u8{0} ** total_len;

    const hdr = linux.nlmsghdr{
        .len = @intCast(total_len),
        .type = .RTM_NEWROUTE,
        .flags = 0,
        .seq = 0,
        .pid = 0,
    };
    @memcpy(buff[0..@sizeOf(linux.nlmsghdr)], std.mem.asBytes(&hdr));

    const route_hdr = RouteMessage.RouteHeader{};
    const route_off = @sizeOf(linux.nlmsghdr);
    @memcpy(buff[route_off .. route_off + @sizeOf(RouteMessage.RouteHeader)], std.mem.asBytes(&route_hdr));

    var i: usize = 0;
    while (i < 128) : (i += 1) {
        var parsed = (try get.parseMessage(&buff)).?;
        parsed.deinit();
    }
}

test "parseMessage rejects IPv6 gateway payload for unsupported family" {
    var get = Get{ .msg = undefined, .nl = undefined, .allocator = std.testing.allocator };
    const payload_len = 16;
    const total_len = @sizeOf(linux.nlmsghdr) + @sizeOf(RouteMessage.RouteHeader) + @sizeOf(Attr) + payload_len;
    var buff: [total_len]u8 = [_]u8{0} ** total_len;

    const hdr = linux.nlmsghdr{
        .len = @intCast(total_len),
        .type = .RTM_NEWROUTE,
        .flags = 0,
        .seq = 0,
        .pid = 0,
    };
    @memcpy(buff[0..@sizeOf(linux.nlmsghdr)], std.mem.asBytes(&hdr));

    const route_hdr = RouteMessage.RouteHeader{ .family = linux.AF.INET6 };
    const route_off = @sizeOf(linux.nlmsghdr);
    @memcpy(buff[route_off .. route_off + @sizeOf(RouteMessage.RouteHeader)], std.mem.asBytes(&route_hdr));

    const gateway_attr = Attr{ .len = @intCast(@sizeOf(Attr) + payload_len), .type = .Gateway };
    const attr_off = route_off + @sizeOf(RouteMessage.RouteHeader);
    @memcpy(buff[attr_off .. attr_off + @sizeOf(Attr)], std.mem.asBytes(&gateway_attr));

    try std.testing.expectError(error.UnsupportedAddressFamily, get.parseMessage(&buff));
}

test "parseMessage rejects non-zero trailing padding bytes" {
    var get = Get{ .msg = undefined, .nl = undefined, .allocator = std.testing.allocator };
    const total_len = @sizeOf(linux.nlmsghdr) + @sizeOf(RouteMessage.RouteHeader) + 1;
    var buff: [total_len]u8 = [_]u8{0} ** total_len;

    const hdr = linux.nlmsghdr{
        .len = @intCast(total_len),
        .type = .RTM_NEWROUTE,
        .flags = 0,
        .seq = 0,
        .pid = 0,
    };
    @memcpy(buff[0..@sizeOf(linux.nlmsghdr)], std.mem.asBytes(&hdr));
    const route_hdr = RouteMessage.RouteHeader{};
    const route_off = @sizeOf(linux.nlmsghdr);
    @memcpy(buff[route_off .. route_off + @sizeOf(RouteMessage.RouteHeader)], std.mem.asBytes(&route_hdr));
    buff[total_len - 1] = 1;

    try std.testing.expectError(error.InvalidResponse, get.parseMessage(&buff));
}

test "parseMessage rejects unexpected netlink message type" {
    var get = Get{ .msg = undefined, .nl = undefined, .allocator = std.testing.allocator };
    const total_len = @sizeOf(linux.nlmsghdr) + @sizeOf(RouteMessage.RouteHeader);
    var buff: [total_len]u8 = [_]u8{0} ** total_len;

    const hdr = linux.nlmsghdr{
        .len = @intCast(total_len),
        .type = .RTM_NEWLINK,
        .flags = 0,
        .seq = 0,
        .pid = 0,
    };
    @memcpy(buff[0..@sizeOf(linux.nlmsghdr)], std.mem.asBytes(&hdr));
    const route_hdr = RouteMessage.RouteHeader{};
    const route_off = @sizeOf(linux.nlmsghdr);
    @memcpy(buff[route_off .. route_off + @sizeOf(RouteMessage.RouteHeader)], std.mem.asBytes(&route_hdr));

    try std.testing.expectError(error.InvalidResponse, get.parseMessage(&buff));
}

test "parseMessage treats successful ERROR ack as terminator" {
    var get = Get{ .msg = undefined, .nl = undefined, .allocator = std.testing.allocator };
    const total_len = @sizeOf(linux.nlmsghdr) + @sizeOf(i32);
    var buff: [total_len]u8 = [_]u8{0} ** total_len;

    const hdr = linux.nlmsghdr{
        .len = @intCast(total_len),
        .type = .ERROR,
        .flags = 0,
        .seq = 0,
        .pid = 0,
    };
    const err_code: i32 = 0;
    @memcpy(buff[0..@sizeOf(linux.nlmsghdr)], std.mem.asBytes(&hdr));
    @memcpy(buff[@sizeOf(linux.nlmsghdr) .. @sizeOf(linux.nlmsghdr) + @sizeOf(i32)], std.mem.asBytes(&err_code));

    try std.testing.expect((try get.parseMessage(&buff)) == null);
}

test "parseMessage parses destination and preferred source attrs" {
    var get = Get{ .msg = undefined, .nl = undefined, .allocator = std.testing.allocator };
    const attr_size = @sizeOf(Attr) + 4;
    const total_len = @sizeOf(linux.nlmsghdr) + @sizeOf(RouteMessage.RouteHeader) + attr_size + attr_size;
    var buff: [total_len]u8 = [_]u8{0} ** total_len;

    const hdr = linux.nlmsghdr{
        .len = @intCast(total_len),
        .type = .RTM_NEWROUTE,
        .flags = 0,
        .seq = 0,
        .pid = 0,
    };
    @memcpy(buff[0..@sizeOf(linux.nlmsghdr)], std.mem.asBytes(&hdr));

    const route_hdr = RouteMessage.RouteHeader{ .family = linux.AF.INET };
    const route_off = @sizeOf(linux.nlmsghdr);
    @memcpy(buff[route_off .. route_off + @sizeOf(RouteMessage.RouteHeader)], std.mem.asBytes(&route_hdr));

    const dst_attr = Attr{ .len = @intCast(attr_size), .type = .Dst };
    const dst_off = route_off + @sizeOf(RouteMessage.RouteHeader);
    @memcpy(buff[dst_off .. dst_off + @sizeOf(Attr)], std.mem.asBytes(&dst_attr));
    buff[dst_off + @sizeOf(Attr) + 0] = 10;
    buff[dst_off + @sizeOf(Attr) + 1] = 0;
    buff[dst_off + @sizeOf(Attr) + 2] = 0;
    buff[dst_off + @sizeOf(Attr) + 3] = 0;

    const src_attr = Attr{ .len = @intCast(attr_size), .type = .Prefsrc };
    const src_off = dst_off + attr_size;
    @memcpy(buff[src_off .. src_off + @sizeOf(Attr)], std.mem.asBytes(&src_attr));
    buff[src_off + @sizeOf(Attr) + 0] = 10;
    buff[src_off + @sizeOf(Attr) + 1] = 0;
    buff[src_off + @sizeOf(Attr) + 2] = 0;
    buff[src_off + @sizeOf(Attr) + 3] = 2;

    var parsed = (try get.parseMessage(&buff)).?;
    defer parsed.deinit();

    var saw_dst = false;
    var saw_prefsrc = false;
    for (parsed.msg.attrs.items) |route_attr| {
        switch (route_attr) {
            .destination => saw_dst = true,
            .preferred_source => saw_prefsrc = true,
            else => {},
        }
    }
    try std.testing.expect(saw_dst);
    try std.testing.expect(saw_prefsrc);
}

test "routeCountExceeded enforces hard cap" {
    try std.testing.expect(!routeCountExceeded(MAX_ROUTE_MESSAGES - 1));
    try std.testing.expect(routeCountExceeded(MAX_ROUTE_MESSAGES));
}

test "routeAttrCountExceeded enforces attr cap" {
    try std.testing.expect(!routeAttrCountExceeded(MAX_ROUTE_ATTRS - 1));
    try std.testing.expect(routeAttrCountExceeded(MAX_ROUTE_ATTRS));
}

test "routePacketCountExceeded enforces packet cap" {
    try std.testing.expect(!routePacketCountExceeded(MAX_ROUTE_PACKETS - 1));
    try std.testing.expect(routePacketCountExceeded(MAX_ROUTE_PACKETS));
}
