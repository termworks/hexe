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

/// SSH_QUIC_REPLY message structure (Section 2.9)
pub const SshQuicReply = struct {
    // Connection IDs
    client_connection_id: []const u8,
    server_connection_id: []const u8, // Non-empty except on error

    // QUIC parameters
    server_quic_versions: []const u32, // MUST NOT be empty
    server_quic_trnsp_params: []const u8,

    // Algorithm lists
    server_sig_algs: []const u8, // MUST NOT be empty
    server_kex_algs: []const u8, // MUST NOT be empty

    // Cipher suites
    quic_tls_cipher_suites: []const []const u8, // MUST NOT be empty

    // Extensions
    ext_pairs: []const ExtensionPair,

    // Key exchange data
    server_kex_alg_data: []const u8, // Non-empty except on error

    /// Free all allocated memory
    pub fn deinit(self: *SshQuicReply, allocator: Allocator) void {
        allocator.free(self.client_connection_id);
        allocator.free(self.server_connection_id);
        allocator.free(self.server_quic_versions);
        allocator.free(self.server_quic_trnsp_params);
        allocator.free(self.server_sig_algs);
        allocator.free(self.server_kex_algs);

        for (self.quic_tls_cipher_suites) |suite| {
            allocator.free(suite);
        }
        allocator.free(self.quic_tls_cipher_suites);

        for (self.ext_pairs) |*ext| {
            allocator.free(ext.name);
            allocator.free(ext.data);
        }
        allocator.free(self.ext_pairs);

        allocator.free(self.server_kex_alg_data);
    }

    /// Check if this is an error reply
    pub fn isErrorReply(self: *const SshQuicReply) bool {
        return self.server_connection_id.len == 0 and self.server_kex_alg_data.len == 0;
    }

    /// Get disconnect reason from extension pairs (for error replies)
    pub fn getDiscReason(self: *const SshQuicReply) ?u32 {
        for (self.ext_pairs) |ext| {
            if (std.mem.eql(u8, ext.name, ext_disc_reason)) {
                if (ext.data.len >= 4) {
                    return std.mem.readInt(u32, ext.data[0..4], .big);
                }
            }
        }
        return null;
    }

    /// Get error description from extension pairs (for error replies)
    pub fn getErrorDesc(self: *const SshQuicReply) ?[]const u8 {
        for (self.ext_pairs) |ext| {
            if (std.mem.eql(u8, ext.name, ext_err_desc)) {
                return ext.data;
            }
        }
        return null;
    }

    /// Encode SSH_QUIC_REPLY to wire format
    pub fn encode(self: *const SshQuicReply, allocator: Allocator) ![]u8 {
        // Calculate required size
        var size: usize = 0;
        size += 1; // packet type
        size += 1 + self.client_connection_id.len; // short-str
        size += 1 + self.server_connection_id.len; // short-str
        size += 1; // nr-quic-versions
        size += self.server_quic_versions.len * 4; // uint32 array
        size += 4 + self.server_quic_trnsp_params.len; // string
        size += 4 + self.server_sig_algs.len; // string
        size += 4 + self.server_kex_algs.len; // string
        size += 1; // nr-cipher-suites
        for (self.quic_tls_cipher_suites) |suite| {
            size += 1 + suite.len; // short-str
        }
        size += 1; // nr-ext-pairs
        for (self.ext_pairs) |ext| {
            size += 1 + ext.name.len; // short-str
            size += 4 + ext.data.len; // string
        }
        size += 4 + self.server_kex_alg_data.len; // string

        // Allocate buffer
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        // Write to buffer
        var writer = wire.Writer{ .buffer = buffer };

        // Packet type
        try writer.writeByte(@intFromEnum(constants.PacketType.ssh_quic_reply));

        // Connection IDs
        try writer.writeShortStr(self.client_connection_id);
        try writer.writeShortStr(self.server_connection_id);

        // QUIC versions
        try writer.writeByte(@intCast(self.server_quic_versions.len));
        for (self.server_quic_versions) |version| {
            try writer.writeUint32(version);
        }
        try writer.writeString(self.server_quic_trnsp_params);

        // Algorithms
        try writer.writeString(self.server_sig_algs);
        try writer.writeString(self.server_kex_algs);

        // Cipher suites
        try writer.writeByte(@intCast(self.quic_tls_cipher_suites.len));
        for (self.quic_tls_cipher_suites) |suite| {
            try writer.writeShortStr(suite);
        }

        // Extension pairs
        try writer.writeByte(@intCast(self.ext_pairs.len));
        for (self.ext_pairs) |ext| {
            try writer.writeShortStr(ext.name);
            try writer.writeString(ext.data);
        }

        // Key exchange data
        try writer.writeString(self.server_kex_alg_data);

        return buffer;
    }

    /// Decode SSH_QUIC_REPLY from wire format
    pub fn decode(allocator: Allocator, data: []const u8) !SshQuicReply {
        var reader = wire.Reader{ .buffer = data };

        // Read packet type
        const packet_type = try reader.readByte();
        if (packet_type != @intFromEnum(constants.PacketType.ssh_quic_reply)) {
            return error.InvalidPacketType;
        }

        // Connection IDs
        const client_connection_id = try reader.readShortStr(allocator);
        errdefer allocator.free(client_connection_id);

        const server_connection_id = try reader.readShortStr(allocator);
        errdefer allocator.free(server_connection_id);

        // QUIC versions
        const nr_quic_versions = try reader.readByte();
        if (nr_quic_versions == 0) {
            return error.NoQuicVersions;
        }

        const server_quic_versions = try allocator.alloc(u32, nr_quic_versions);
        errdefer allocator.free(server_quic_versions);

        for (server_quic_versions) |*version| {
            version.* = try reader.readUint32();
        }

        const server_quic_trnsp_params = try reader.readString(allocator);
        errdefer allocator.free(server_quic_trnsp_params);

        // Algorithms
        const server_sig_algs = try reader.readString(allocator);
        errdefer allocator.free(server_sig_algs);

        if (server_sig_algs.len == 0) {
            return error.NoSignatureAlgorithms;
        }

        const server_kex_algs = try reader.readString(allocator);
        errdefer allocator.free(server_kex_algs);

        if (server_kex_algs.len == 0) {
            return error.NoKexAlgorithms;
        }

        // Cipher suites
        const nr_cipher_suites = try reader.readByte();
        if (nr_cipher_suites == 0) {
            return error.NoCipherSuites;
        }

        const quic_tls_cipher_suites = try allocator.alloc([]const u8, nr_cipher_suites);
        errdefer {
            for (quic_tls_cipher_suites[0..nr_cipher_suites]) |suite| {
                allocator.free(suite);
            }
            allocator.free(quic_tls_cipher_suites);
        }

        for (quic_tls_cipher_suites) |*suite| {
            suite.* = try reader.readShortStr(allocator);
        }

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

        // Key exchange data
        const server_kex_alg_data = try reader.readString(allocator);
        errdefer allocator.free(server_kex_alg_data);

        return SshQuicReply{
            .client_connection_id = client_connection_id,
            .server_connection_id = server_connection_id,
            .server_quic_versions = server_quic_versions,
            .server_quic_trnsp_params = server_quic_trnsp_params,
            .server_sig_algs = server_sig_algs,
            .server_kex_algs = server_kex_algs,
            .quic_tls_cipher_suites = quic_tls_cipher_suites,
            .ext_pairs = ext_pairs,
            .server_kex_alg_data = server_kex_alg_data,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SshQuicReply - encode and decode successful reply" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var reply = SshQuicReply{
        .client_connection_id = "client123",
        .server_connection_id = "server456",
        .server_quic_versions = &[_]u32{ 1, 2 },
        .server_quic_trnsp_params = "",
        .server_sig_algs = "ssh-ed25519,rsa-sha2-256",
        .server_kex_algs = "curve25519-sha256",
        .quic_tls_cipher_suites = &[_][]const u8{"TLS_AES_256_GCM_SHA384"},
        .ext_pairs = &[_]ExtensionPair{},
        .server_kex_alg_data = "keyexchangedata",
    };

    // Encode
    const encoded = try reply.encode(allocator);
    defer allocator.free(encoded);

    // Decode
    var decoded = try SshQuicReply.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    // Verify fields
    try testing.expectEqualStrings("client123", decoded.client_connection_id);
    try testing.expectEqualStrings("server456", decoded.server_connection_id);
    try testing.expectEqual(@as(usize, 2), decoded.server_quic_versions.len);
    try testing.expectEqual(@as(u32, 1), decoded.server_quic_versions[0]);
    try testing.expectEqual(@as(u32, 2), decoded.server_quic_versions[1]);
    try testing.expectEqualStrings("ssh-ed25519,rsa-sha2-256", decoded.server_sig_algs);
    try testing.expectEqual(@as(usize, 1), decoded.quic_tls_cipher_suites.len);
    try testing.expectEqualStrings("keyexchangedata", decoded.server_kex_alg_data);

    // Not an error reply
    try testing.expect(!decoded.isErrorReply());
}

test "SshQuicReply - encode and decode error reply" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create disconnect reason data (uint32)
    var disc_reason_data: [4]u8 = undefined;
    std.mem.writeInt(u32, &disc_reason_data, constants.SSH_DISCONNECT.KEY_EXCHANGE_FAILED, .big);

    var reply = SshQuicReply{
        .client_connection_id = "client123",
        .server_connection_id = "", // Empty on error
        .server_quic_versions = &[_]u32{1},
        .server_quic_trnsp_params = "",
        .server_sig_algs = "ssh-ed25519",
        .server_kex_algs = "curve25519-sha256",
        .quic_tls_cipher_suites = &[_][]const u8{"TLS_AES_256_GCM_SHA384"},
        .ext_pairs = &[_]ExtensionPair{
            .{ .name = ext_disc_reason, .data = &disc_reason_data },
            .{ .name = ext_err_desc, .data = "Key exchange failed" },
        },
        .server_kex_alg_data = "", // Empty on error
    };

    // Encode
    const encoded = try reply.encode(allocator);
    defer allocator.free(encoded);

    // Decode
    var decoded = try SshQuicReply.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    // Verify it's an error reply
    try testing.expect(decoded.isErrorReply());

    // Check disconnect reason
    const disc = decoded.getDiscReason();
    try testing.expect(disc != null);
    try testing.expectEqual(constants.SSH_DISCONNECT.KEY_EXCHANGE_FAILED, disc.?);

    // Check error description
    const err_desc = decoded.getErrorDesc();
    try testing.expect(err_desc != null);
    try testing.expectEqualStrings("Key exchange failed", err_desc.?);
}

test "SshQuicReply - isErrorReply detection" {
    const testing = std.testing;

    // Successful reply
    var success_reply = SshQuicReply{
        .client_connection_id = "",
        .server_connection_id = "server",
        .server_quic_versions = &[_]u32{1},
        .server_quic_trnsp_params = "",
        .server_sig_algs = "ssh-ed25519",
        .server_kex_algs = "curve25519-sha256",
        .quic_tls_cipher_suites = &[_][]const u8{"TLS_AES_256_GCM_SHA384"},
        .ext_pairs = &[_]ExtensionPair{},
        .server_kex_alg_data = "data",
    };
    try testing.expect(!success_reply.isErrorReply());

    // Error reply
    var error_reply = SshQuicReply{
        .client_connection_id = "",
        .server_connection_id = "",
        .server_quic_versions = &[_]u32{1},
        .server_quic_trnsp_params = "",
        .server_sig_algs = "ssh-ed25519",
        .server_kex_algs = "curve25519-sha256",
        .quic_tls_cipher_suites = &[_][]const u8{"TLS_AES_256_GCM_SHA384"},
        .ext_pairs = &[_]ExtensionPair{},
        .server_kex_alg_data = "",
    };
    try testing.expect(error_reply.isErrorReply());
}
