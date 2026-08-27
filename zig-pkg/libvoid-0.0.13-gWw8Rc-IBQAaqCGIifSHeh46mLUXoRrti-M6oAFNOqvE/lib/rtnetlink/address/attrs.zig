const std = @import("std");
const nalign = @import("../utils.zig").nalign;
const linux = std.os.linux;
const c = @cImport(@cInclude("linux/rtnetlink.h"));

const IFA_ADDRESS: linux.IFA = @enumFromInt(1);
const IFA_LOCAL: linux.IFA = @enumFromInt(2);
const IFA_LABEL: linux.IFA = @enumFromInt(3);
const IFA_BROADCAST: linux.IFA = @enumFromInt(4);
const IFA_ANYCAST: linux.IFA = @enumFromInt(5);
const IFA_CACHEINFO: linux.IFA = @enumFromInt(6);
const IFA_MULTICAST: linux.IFA = @enumFromInt(7);
const IFA_FLAGS: linux.IFA = @enumFromInt(8);

// IPv4-only address attributes. IPv6 address plumbing is not implemented yet.
pub const AddressAttr = union(enum) {
    address: [4]u8,
    local: [4]u8,
    broadcast: [4]u8,

    fn getAttr(self: AddressAttr) linux.rtattr {
        var attr: linux.rtattr = switch (self) {
            .address => |val| .{ .len = @intCast(val.len), .type = .{ .addr = IFA_ADDRESS } },
            .local => |val| .{ .len = @intCast(val.len), .type = .{ .addr = IFA_LOCAL } },
            .broadcast => |val| .{ .len = @intCast(val.len), .type = .{ .addr = IFA_BROADCAST } },
        };

        attr.len = @intCast(nalign(attr.len + @sizeOf(linux.rtattr)));
        return attr;
    }

    pub fn size(self: AddressAttr) usize {
        const len = switch (self) {
            inline else => |val| val.len,
        };
        return nalign(len + @sizeOf(linux.rtattr));
    }

    pub fn encode(self: AddressAttr, buff: []u8) !usize {
        const header = self.getAttr();
        @memcpy(buff[0..@sizeOf(linux.rtattr)], std.mem.asBytes(&header));
        _ = try self.encodeVal(buff[@sizeOf(linux.rtattr)..]) + @sizeOf(linux.rtattr);
        return nalign(header.len);
    }

    inline fn encodeVal(self: AddressAttr, buff: []u8) !usize {
        return switch (self) {
            inline else => |val| {
                @memcpy(buff[0..val.len], &val);
                return val.len;
            },
        };
    }
};
