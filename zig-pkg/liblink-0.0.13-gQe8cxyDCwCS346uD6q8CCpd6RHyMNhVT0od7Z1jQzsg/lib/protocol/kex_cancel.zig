const std = @import("std");
const Allocator = std.mem.Allocator;
const wire = @import("wire.zig");
const constants = @import("../common/constants.zig");
const kex_init = @import("kex_init.zig");

/// Extension pair (reuse from kex_init)
pub const ExtensionPair = kex_init.ExtensionPair;

/// Well-known extension pair names for error reporting
pub const ext_disc_reason = "disc-reason";
pub const ext_err_desc = "err-desc";

/// SSH_QUIC_CANCEL message structure (Section 2.10)
pub const SshQuicCancel = struct {
    // Connection ID
    server_connection_id: []const u8, // Must match server's reply

    // Extensions (MUST include disc-reason)
    ext_pairs: []const ExtensionPair,

    /// Free all allocated memory
    pub fn deinit(self: *SshQuicCancel, allocator: Allocator) void {
        allocator.free(self.server_connection_id);

        for (self.ext_pairs) |*ext| {
            allocator.free(ext.name);
            allocator.free(ext.data);
        }
        allocator.free(self.ext_pairs);
    }

    /// Get disconnect reason from extension pairs
    pub fn getDiscReason(self: *const SshQuicCancel) ?u32 {
        for (self.ext_pairs) |ext| {
            if (std.mem.eql(u8, ext.name, ext_disc_reason)) {
                if (ext.data.len >= 4) {
                    return std.mem.readInt(u32, ext.data[0..4], .big);
                }
            }
        }
        return null;
    }

    /// Get error description from extension pairs
    pub fn getErrorDesc(self: *const SshQuicCancel) ?[]const u8 {
        for (self.ext_pairs) |ext| {
            if (std.mem.eql(u8, ext.name, ext_err_desc)) {
                return ext.data;
            }
        }
        return null;
    }

    /// Encode SSH_QUIC_CANCEL to wire format
    pub fn encode(self: *const SshQuicCancel, allocator: Allocator) ![]u8 {
        // Calculate required size
        var size: usize = 0;
        size += 1; // packet type
        size += 1 + self.server_connection_id.len; // short-str
        size += 1; // nr-ext-pairs
        for (self.ext_pairs) |ext| {
            size += 1 + ext.name.len; // short-str
            size += 4 + ext.data.len; // string
        }

        // Allocate buffer
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        // Write to buffer
        var writer = wire.Writer{ .buffer = buffer };

        // Packet type
        try writer.writeByte(@intFromEnum(constants.PacketType.ssh_quic_cancel));

        // Connection ID
        try writer.writeShortStr(self.server_connection_id);

        // Extension pairs
        try writer.writeByte(@intCast(self.ext_pairs.len));
        for (self.ext_pairs) |ext| {
            try writer.writeShortStr(ext.name);
            try writer.writeString(ext.data);
        }

        return buffer;
    }

    /// Decode SSH_QUIC_CANCEL from wire format
    pub fn decode(allocator: Allocator, data: []const u8) !SshQuicCancel {
        var reader = wire.Reader{ .buffer = data };

        // Read packet type
        const packet_type = try reader.readByte();
        if (packet_type != @intFromEnum(constants.PacketType.ssh_quic_cancel)) {
            return error.InvalidPacketType;
        }

        // Connection ID
        const server_connection_id = try reader.readShortStr(allocator);
        errdefer allocator.free(server_connection_id);

        // Extension pairs
        const nr_ext_pairs = try reader.readByte();
        const ext_pairs = try allocator.alloc(ExtensionPair, nr_ext_pairs);
        errdefer {
            for (ext_pairs[0..nr_ext_pairs]) |*ext| {
                allocator.free(ext.name);
                allocator.free(ext.data);
            }
            allocator.free(ext_pairs);
        }

        for (ext_pairs) |*ext| {
            ext.name = try reader.readShortStr(allocator);
            if (ext.name.len == 0) {
                return error.EmptyExtensionName;
            }
            ext.data = try reader.readString(allocator);
        }

        return SshQuicCancel{
            .server_connection_id = server_connection_id,
            .ext_pairs = ext_pairs,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SshQuicCancel - encode and decode with disconnect reason" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create disconnect reason data (uint32)
    var disc_reason_data: [4]u8 = undefined;
    std.mem.writeInt(u32, &disc_reason_data, constants.SSH_DISCONNECT.BY_APPLICATION, .big);

    var cancel = SshQuicCancel{
        .server_connection_id = "server789",
        .ext_pairs = &[_]ExtensionPair{
            .{ .name = ext_disc_reason, .data = &disc_reason_data },
            .{ .name = ext_err_desc, .data = "User cancelled connection" },
        },
    };

    // Encode
    const encoded = try cancel.encode(allocator);
    defer allocator.free(encoded);

    // Decode
    var decoded = try SshQuicCancel.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    // Verify fields
    try testing.expectEqualStrings("server789", decoded.server_connection_id);
    try testing.expectEqual(@as(usize, 2), decoded.ext_pairs.len);

    // Check disconnect reason
    const disc = decoded.getDiscReason();
    try testing.expect(disc != null);
    try testing.expectEqual(constants.SSH_DISCONNECT.BY_APPLICATION, disc.?);

    // Check error description
    const err_desc = decoded.getErrorDesc();
    try testing.expect(err_desc != null);
    try testing.expectEqualStrings("User cancelled connection", err_desc.?);
}

test "SshQuicCancel - encode and decode minimal" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var disc_reason_data: [4]u8 = undefined;
    std.mem.writeInt(u32, &disc_reason_data, constants.SSH_DISCONNECT.KEY_EXCHANGE_FAILED, .big);

    var cancel = SshQuicCancel{
        .server_connection_id = "srv",
        .ext_pairs = &[_]ExtensionPair{
            .{ .name = ext_disc_reason, .data = &disc_reason_data },
        },
    };

    const encoded = try cancel.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try SshQuicCancel.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqualStrings("srv", decoded.server_connection_id);
    try testing.expectEqual(@as(usize, 1), decoded.ext_pairs.len);
}

test "SshQuicCancel - getDiscReason with missing extension" {
    const testing = std.testing;

    var cancel = SshQuicCancel{
        .server_connection_id = "srv",
        .ext_pairs = &[_]ExtensionPair{
            .{ .name = "other-ext", .data = "data" },
        },
    };

    const disc = cancel.getDiscReason();
    try testing.expect(disc == null);
}

test "SshQuicCancel - getErrorDesc with missing extension" {
    const testing = std.testing;

    var cancel = SshQuicCancel{
        .server_connection_id = "srv",
        .ext_pairs = &[_]ExtensionPair{},
    };

    const err_desc = cancel.getErrorDesc();
    try testing.expect(err_desc == null);
}

test "SshQuicCancel - empty server connection ID" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var disc_reason_data: [4]u8 = undefined;
    std.mem.writeInt(u32, &disc_reason_data, constants.SSH_DISCONNECT.PROTOCOL_ERROR, .big);

    var cancel = SshQuicCancel{
        .server_connection_id = "",
        .ext_pairs = &[_]ExtensionPair{
            .{ .name = ext_disc_reason, .data = &disc_reason_data },
        },
    };

    const encoded = try cancel.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try SshQuicCancel.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqualStrings("", decoded.server_connection_id);
}
