const LinkMessage = @import("link.zig");
const RtNetLink = @import("../rtnetlink.zig");
const std = @import("std");
const log = std.log;
const nalign = @import("../utils.zig").nalign;
const linux = std.os.linux;
const MAX_LINK_FRAMES = 2048;
const MAX_LINK_ATTRS = 1024;
const MAX_LINK_PACKETS = 128;

const LinkGet = @This();
pub const Options = struct {
    name: ?[]const u8 = null,
    index: ?u32 = null,
};

fn hasActiveLinkFilters(opts: Options) bool {
    return opts.name != null or opts.index != null;
}

fn shouldReturnParsedAfterPacket(stop_on_first_link: bool, parsed_present: bool) bool {
    return stop_on_first_link and parsed_present;
}

msg: LinkMessage,
nl: *RtNetLink,
opts: Options,
allocator: std.mem.Allocator,
pub fn init(allocator: std.mem.Allocator, nl: *RtNetLink, options: Options) LinkGet {
    const msg = LinkMessage.init(allocator, .get);
    return .{
        .msg = msg,
        .nl = nl,
        .opts = options,
        .allocator = allocator,
    };
}

fn name(self: *LinkGet, value: []const u8) !void {
    try self.msg.addAttr(.{ .name = value });
}

fn applyOptions(self: *LinkGet) !void {
    if (self.opts.name) |val| {
        try self.name(val);
    }
    if (self.opts.index) |val| {
        self.msg.msg.header.index = @intCast(val);
    }
}

pub fn exec(self: *LinkGet) !LinkMessage {
    try self.applyOptions();

    const data = try self.msg.compose();
    defer self.msg.allocator.free(data);

    try self.nl.send(data);
    return self.recv(hasActiveLinkFilters(self.opts));
}

fn recv(self: *LinkGet, stop_on_first_link: bool) !LinkMessage {
    var buff: [4096]u8 = undefined;
    var parsed: ?LinkMessage = null;
    var frame_count: usize = 0;
    var packet_count: usize = 0;
    errdefer if (parsed) |*msg| msg.deinit();

    while (true) {
        if (linkPacketCountExceeded(packet_count)) return error.TooManyLinkPackets;
        const n = try self.nl.recv(&buff);
        if (n < @sizeOf(linux.nlmsghdr)) return error.InvalidResponse;

        var start: usize = 0;
        while (start + @sizeOf(linux.nlmsghdr) <= n) {
            if (linkFrameCountExceeded(frame_count)) return error.TooManyLinkMessages;
            const header = std.mem.bytesAsValue(linux.nlmsghdr, buff[start .. start + @sizeOf(linux.nlmsghdr)]);
            if (header.len < @sizeOf(linux.nlmsghdr)) return error.InvalidResponse;

            const frame_len = nalign(header.len);
            if (start + frame_len > n) return error.InvalidResponse;
            const frame = buff[start .. start + header.len];

            switch (header.type) {
                .DONE => {
                    if (parsed) |msg| return msg;
                    return error.InvalidResponse;
                },
                .ERROR => {
                    const err_code = try RtNetLink.parseNetlinkErrorCode(frame);
                    try RtNetLink.handle_ack_code(err_code);
                    if (parsed) |msg| return msg;
                },
                .RTM_NEWLINK => {
                    var msg = try parseLinkMessage(self.allocator, frame, header.*);
                    if (parsed == null) {
                        if (stop_on_first_link) return msg;
                        parsed = msg;
                    } else {
                        msg.deinit();
                    }
                },
                else => {
                    if (!isAllowedFrameType(header.type)) return error.InvalidResponse;
                },
            }

            frame_count += 1;
            start += frame_len;
        }

        packet_count += 1;

        if (shouldReturnParsedAfterPacket(stop_on_first_link, parsed != null)) {
            return parsed.?;
        }
    }
}

fn isAllowedFrameType(msg_type: linux.NetlinkMessageType) bool {
    return msg_type == .NOOP;
}

fn linkFrameCountExceeded(current_count: usize) bool {
    return current_count >= MAX_LINK_FRAMES;
}

fn linkAttrCountExceeded(current_count: usize) bool {
    return current_count >= MAX_LINK_ATTRS;
}

fn linkPacketCountExceeded(current_count: usize) bool {
    return current_count >= MAX_LINK_PACKETS;
}

fn parseLinkMessage(allocator: std.mem.Allocator, frame: []const u8, header: linux.nlmsghdr) !LinkMessage {
    if (header.len < @sizeOf(linux.nlmsghdr) + @sizeOf(linux.ifinfomsg) or header.len > frame.len) {
        return error.InvalidResponse;
    }

    var start: usize = @sizeOf(linux.nlmsghdr);
    var link_info = LinkMessage.init(allocator, .create);
    errdefer link_info.deinit();
    link_info.hdr = header;

    const ifinfo = std.mem.bytesAsValue(linux.ifinfomsg, frame[start .. start + @sizeOf(linux.ifinfomsg)]);
    start += @sizeOf(linux.ifinfomsg);
    link_info.msg.header = ifinfo.*;

    log.info("header: {}", .{header});
    log.info("ifinfo: {}", .{ifinfo});

    var attr_count: usize = 0;
    while (start + @sizeOf(linux.rtattr) <= header.len) {
        if (linkAttrCountExceeded(attr_count)) return error.TooManyLinkAttrs;
        const rtattr = std.mem.bytesAsValue(linux.rtattr, frame[start .. start + @sizeOf(linux.rtattr)]);
        if (rtattr.len < @sizeOf(linux.rtattr)) return error.InvalidResponse;
        if (start + rtattr.len > header.len) return error.InvalidResponse;

        switch (rtattr.type.link) {
            .IFNAME => {
                if (rtattr.len == @sizeOf(linux.rtattr)) {
                    start += nalign(rtattr.len);
                    continue;
                }
                if (frame[start + rtattr.len - 1] != 0) return error.InvalidResponse;
                const value = frame[start + @sizeOf(linux.rtattr) .. start + rtattr.len - 1];
                const ifname = try allocator.alloc(u8, value.len);
                @memcpy(ifname, value);
                log.info("name: {s}", .{ifname});
                try link_info.addAttr(.{ .name_owned = ifname });
            },
            else => {},
        }

        attr_count += 1;
        start += nalign(rtattr.len);
    }

    if (!hasOnlyZeroPadding(frame[start..header.len])) return error.InvalidResponse;

    return link_info;
}

fn hasOnlyZeroPadding(bytes: []const u8) bool {
    for (bytes) |b| {
        if (b != 0) return false;
    }
    return true;
}

test "parseLinkMessage rejects truncated header" {
    var buff: [@sizeOf(linux.nlmsghdr)]u8 = [_]u8{0} ** @sizeOf(linux.nlmsghdr);
    const hdr = linux.nlmsghdr{
        .len = @intCast(@sizeOf(linux.nlmsghdr) - 1),
        .type = .RTM_NEWLINK,
        .flags = 0,
        .seq = 0,
        .pid = 0,
    };
    @memcpy(buff[0..@sizeOf(linux.nlmsghdr)], std.mem.asBytes(&hdr));
    try std.testing.expectError(error.InvalidResponse, parseLinkMessage(std.testing.allocator, &buff, hdr));
}

test "parseLinkMessage rejects malformed attribute length" {
    const total_len = @sizeOf(linux.nlmsghdr) + @sizeOf(linux.ifinfomsg) + @sizeOf(linux.rtattr);
    var buff: [total_len]u8 = [_]u8{0} ** total_len;

    const hdr = linux.nlmsghdr{
        .len = @intCast(total_len),
        .type = .RTM_NEWLINK,
        .flags = 0,
        .seq = 0,
        .pid = 0,
    };
    @memcpy(buff[0..@sizeOf(linux.nlmsghdr)], std.mem.asBytes(&hdr));

    const ifi = linux.ifinfomsg{
        .family = linux.AF.UNSPEC,
        .type = 0,
        .index = 1,
        .flags = 0,
        .change = 0,
    };
    const ifi_off = @sizeOf(linux.nlmsghdr);
    @memcpy(buff[ifi_off .. ifi_off + @sizeOf(linux.ifinfomsg)], std.mem.asBytes(&ifi));

    const attr = linux.rtattr{ .len = @intCast(@sizeOf(linux.rtattr) - 1), .type = .{ .link = .IFNAME } };
    const attr_off = ifi_off + @sizeOf(linux.ifinfomsg);
    @memcpy(buff[attr_off .. attr_off + @sizeOf(linux.rtattr)], std.mem.asBytes(&attr));

    try std.testing.expectError(error.InvalidResponse, parseLinkMessage(std.testing.allocator, &buff, hdr));
}

test "parseLinkMessage rejects attribute overrunning frame" {
    const total_len = @sizeOf(linux.nlmsghdr) + @sizeOf(linux.ifinfomsg) + @sizeOf(linux.rtattr);
    var buff: [total_len]u8 = [_]u8{0} ** total_len;

    const hdr = linux.nlmsghdr{
        .len = @intCast(total_len),
        .type = .RTM_NEWLINK,
        .flags = 0,
        .seq = 0,
        .pid = 0,
    };
    @memcpy(buff[0..@sizeOf(linux.nlmsghdr)], std.mem.asBytes(&hdr));

    const ifi = linux.ifinfomsg{
        .family = linux.AF.UNSPEC,
        .type = 0,
        .index = 1,
        .flags = 0,
        .change = 0,
    };
    const ifi_off = @sizeOf(linux.nlmsghdr);
    @memcpy(buff[ifi_off .. ifi_off + @sizeOf(linux.ifinfomsg)], std.mem.asBytes(&ifi));

    const attr = linux.rtattr{ .len = @intCast(@sizeOf(linux.rtattr) + 8), .type = .{ .link = .IFNAME } };
    const attr_off = ifi_off + @sizeOf(linux.ifinfomsg);
    @memcpy(buff[attr_off .. attr_off + @sizeOf(linux.rtattr)], std.mem.asBytes(&attr));

    try std.testing.expectError(error.InvalidResponse, parseLinkMessage(std.testing.allocator, &buff, hdr));
}

test "parseLinkMessage repeated parse/deinit does not leak" {
    const total_len = @sizeOf(linux.nlmsghdr) + @sizeOf(linux.ifinfomsg);
    var buff: [total_len]u8 = [_]u8{0} ** total_len;

    const hdr = linux.nlmsghdr{
        .len = @intCast(total_len),
        .type = .RTM_NEWLINK,
        .flags = 0,
        .seq = 0,
        .pid = 0,
    };
    @memcpy(buff[0..@sizeOf(linux.nlmsghdr)], std.mem.asBytes(&hdr));

    const ifi = linux.ifinfomsg{
        .family = linux.AF.UNSPEC,
        .type = 0,
        .index = 7,
        .flags = 0,
        .change = 0,
    };
    const ifi_off = @sizeOf(linux.nlmsghdr);
    @memcpy(buff[ifi_off .. ifi_off + @sizeOf(linux.ifinfomsg)], std.mem.asBytes(&ifi));

    var i: usize = 0;
    while (i < 128) : (i += 1) {
        var parsed = try parseLinkMessage(std.testing.allocator, &buff, hdr);
        parsed.deinit();
    }
}

test "parseLinkMessage rejects non-null-terminated IFNAME payload" {
    const payload_len = 4;
    const total_len = @sizeOf(linux.nlmsghdr) + @sizeOf(linux.ifinfomsg) + @sizeOf(linux.rtattr) + payload_len;
    var buff: [total_len]u8 = [_]u8{0} ** total_len;

    const hdr = linux.nlmsghdr{
        .len = @intCast(total_len),
        .type = .RTM_NEWLINK,
        .flags = 0,
        .seq = 0,
        .pid = 0,
    };
    @memcpy(buff[0..@sizeOf(linux.nlmsghdr)], std.mem.asBytes(&hdr));

    const ifi = linux.ifinfomsg{
        .family = linux.AF.UNSPEC,
        .type = 0,
        .index = 1,
        .flags = 0,
        .change = 0,
    };
    const ifi_off = @sizeOf(linux.nlmsghdr);
    @memcpy(buff[ifi_off .. ifi_off + @sizeOf(linux.ifinfomsg)], std.mem.asBytes(&ifi));

    const attr = linux.rtattr{ .len = @intCast(@sizeOf(linux.rtattr) + payload_len), .type = .{ .link = .IFNAME } };
    const attr_off = ifi_off + @sizeOf(linux.ifinfomsg);
    @memcpy(buff[attr_off .. attr_off + @sizeOf(linux.rtattr)], std.mem.asBytes(&attr));
    buff[attr_off + @sizeOf(linux.rtattr) + 0] = 'e';
    buff[attr_off + @sizeOf(linux.rtattr) + 1] = 't';
    buff[attr_off + @sizeOf(linux.rtattr) + 2] = 'h';
    buff[attr_off + @sizeOf(linux.rtattr) + 3] = '0';

    try std.testing.expectError(error.InvalidResponse, parseLinkMessage(std.testing.allocator, &buff, hdr));
}

test "parseLinkMessage rejects non-zero trailing padding bytes" {
    const total_len = @sizeOf(linux.nlmsghdr) + @sizeOf(linux.ifinfomsg) + 1;
    var buff: [total_len]u8 = [_]u8{0} ** total_len;

    const hdr = linux.nlmsghdr{
        .len = @intCast(total_len),
        .type = .RTM_NEWLINK,
        .flags = 0,
        .seq = 0,
        .pid = 0,
    };
    @memcpy(buff[0..@sizeOf(linux.nlmsghdr)], std.mem.asBytes(&hdr));

    const ifi = linux.ifinfomsg{
        .family = linux.AF.UNSPEC,
        .type = 0,
        .index = 1,
        .flags = 0,
        .change = 0,
    };
    const ifi_off = @sizeOf(linux.nlmsghdr);
    @memcpy(buff[ifi_off .. ifi_off + @sizeOf(linux.ifinfomsg)], std.mem.asBytes(&ifi));
    buff[total_len - 1] = 1;

    try std.testing.expectError(error.InvalidResponse, parseLinkMessage(std.testing.allocator, &buff, hdr));
}

test "isAllowedFrameType only allows NOOP" {
    try std.testing.expect(isAllowedFrameType(.NOOP));
    try std.testing.expect(!isAllowedFrameType(.RTM_NEWROUTE));
    try std.testing.expect(!isAllowedFrameType(.RTM_NEWLINK));
}

test "hasActiveLinkFilters detects active selector options" {
    try std.testing.expect(!hasActiveLinkFilters(.{}));
    try std.testing.expect(hasActiveLinkFilters(.{ .name = "eth0" }));
    try std.testing.expect(hasActiveLinkFilters(.{ .index = 2 }));
}

test "shouldReturnParsedAfterPacket requires filter and parsed value" {
    try std.testing.expect(!shouldReturnParsedAfterPacket(false, false));
    try std.testing.expect(!shouldReturnParsedAfterPacket(false, true));
    try std.testing.expect(!shouldReturnParsedAfterPacket(true, false));
    try std.testing.expect(shouldReturnParsedAfterPacket(true, true));
}

test "linkFrameCountExceeded enforces frame cap" {
    try std.testing.expect(!linkFrameCountExceeded(MAX_LINK_FRAMES - 1));
    try std.testing.expect(linkFrameCountExceeded(MAX_LINK_FRAMES));
}

test "linkAttrCountExceeded enforces attr cap" {
    try std.testing.expect(!linkAttrCountExceeded(MAX_LINK_ATTRS - 1));
    try std.testing.expect(linkAttrCountExceeded(MAX_LINK_ATTRS));
}

test "linkPacketCountExceeded enforces packet cap" {
    try std.testing.expect(!linkPacketCountExceeded(MAX_LINK_PACKETS - 1));
    try std.testing.expect(linkPacketCountExceeded(MAX_LINK_PACKETS));
}
