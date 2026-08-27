const std = @import("std");
const nalign = @import("../utils.zig").nalign;
const c = @cImport(@cInclude("linux/rtnetlink.h"));

comptime {
    std.debug.assert(@sizeOf(std.os.linux.rtattr) == @sizeOf(RtAttr));
}

pub const RtAttr = packed struct {
    len: u16,
    type: AttrType,
};

pub const AttrType = enum(u16) {
    Unspec = c.RTA_UNSPEC,
    Dst = c.RTA_DST,
    Src = c.RTA_SRC,
    Iif = c.RTA_IIF,
    Oif = c.RTA_OIF,
    Gateway = c.RTA_GATEWAY,
    Priority = c.RTA_PRIORITY,
    Prefsrc = c.RTA_PREFSRC,
    Metrics = c.RTA_METRICS,
    Multipath = c.RTA_MULTIPATH,
    Flow = c.RTA_FLOW,
    CacheInfo = c.RTA_CACHEINFO,
    Table = c.RTA_TABLE,
    Mark = c.RTA_MARK,
    Stats = c.RTA_MFC_STATS,
    Via = c.RTA_VIA,
    NewDst = c.RTA_NEWDST,
    Pref = c.RTA_PREF,
    Type = c.RTA_ENCAP_TYPE,
    Encap = c.RTA_ENCAP,
    Expires = c.RTA_EXPIRES,
    Pad = c.RTA_PAD,
    Uid = c.RTA_UID,
    Propagate = c.RTA_TTL_PROPAGATE,
    Proto = c.RTA_IP_PROTO,
    Sport = c.RTA_SPORT,
    Dport = c.RTA_DPORT,
    Id = c.RTA_NH_ID,
};
/// Route attribute payloads currently model IPv4 fields only.
/// IPv6 route families are rejected by route parser validation.
pub const Attr = union(enum) {
    destination: [4]u8,
    gateway: [4]u8,
    preferred_source: [4]u8,
    output_if: u32,

    fn getAttr(self: Attr) RtAttr {
        var attr: RtAttr = switch (self) {
            .destination => |val| .{ .len = val.len, .type = .Dst },
            .gateway => |val| .{ .len = val.len, .type = .Gateway },
            .preferred_source => |val| .{ .len = val.len, .type = .Prefsrc },
            .output_if => .{ .len = 4, .type = .Oif },
        };

        attr.len = @intCast(nalign(attr.len + @sizeOf(RtAttr)));
        return attr;
    }

    pub fn size(self: Attr) usize {
        const len = switch (self) {
            .destination => |val| val.len,
            .gateway => |val| val.len,
            .preferred_source => |val| val.len,
            .output_if => 4,
        };
        return nalign(len + @sizeOf(RtAttr));
    }

    pub fn encode(self: Attr, buff: []u8) !usize {
        const header = self.getAttr();
        @memcpy(buff[0..@sizeOf(RtAttr)], std.mem.asBytes(&header));
        _ = try self.encodeVal(buff[@sizeOf(RtAttr)..]);
        return nalign(header.len);
    }

    inline fn encodeVal(self: Attr, buff: []u8) !usize {
        return switch (self) {
            .destination => |val| {
                @memcpy(buff[0..val.len], &val);
                return val.len;
            },
            .gateway => |val| {
                @memcpy(buff[0..val.len], &val);
                return val.len;
            },
            .preferred_source => |val| {
                @memcpy(buff[0..val.len], &val);
                return val.len;
            },
            .output_if => |val| {
                @memcpy(buff[0..4], std.mem.asBytes(&val));
                return 4;
            },
        };
    }
};

test "route attr ipv4 fields have expected encoded size" {
    const destination_attr = Attr{ .destination = .{ 10, 0, 0, 0 } };
    const gateway_attr = Attr{ .gateway = .{ 10, 0, 0, 1 } };
    const preferred_source_attr = Attr{ .preferred_source = .{ 10, 0, 0, 2 } };

    try std.testing.expectEqual(@as(usize, 8), destination_attr.size());
    try std.testing.expectEqual(@as(usize, 8), gateway_attr.size());
    try std.testing.expectEqual(@as(usize, 8), preferred_source_attr.size());
}
