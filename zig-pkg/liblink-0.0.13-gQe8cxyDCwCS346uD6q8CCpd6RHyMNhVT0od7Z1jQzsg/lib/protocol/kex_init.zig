const std = @import("std");
const Allocator = std.mem.Allocator;
const wire = @import("wire.zig");
const constants = @import("../common/constants.zig");

/// Minimum unencrypted obfs-payload size for SSH_QUIC_INIT (DDoS protection)
pub const min_payload_size = 1200;

/// Padding byte value (0xFF)
pub const padding_byte: u8 = 0xFF;

/// Key exchange algorithm entry
pub const KexAlgorithm = struct {
    name: []const u8,
    data: []const u8,

    pub fn deinit(self: *KexAlgorithm, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.data);
    }
};

/// Extension pair
pub const ExtensionPair = struct {
    name: []const u8,
    data: []const u8,

    pub fn deinit(self: *ExtensionPair, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.data);
    }
};

/// SSH_QUIC_INIT message structure (Section 2.8)
pub const SshQuicInit = struct {
    // Connection IDs
    client_connection_id: []const u8, // MAY be empty
    server_name_indication: []const u8, // MAY be empty

    // QUIC parameters
    client_quic_versions: []const u32, // MUST NOT be empty
    client_quic_trnsp_params: []const u8,

    // Signature algorithms
    client_sig_algs: []const u8, // MUST NOT be empty

    // Trusted fingerprints
    trusted_fingerprints: []const []const u8, // MAY be empty

    // Key exchange algorithms
    client_kex_algs: []const KexAlgorithm, // MUST NOT be empty

    // Cipher suites
    quic_tls_cipher_suites: []const []const u8, // MUST NOT be empty

    // Extensions
    ext_pairs: []const ExtensionPair,

    /// Free all allocated memory
    pub fn deinit(self: *SshQuicInit, allocator: Allocator) void {
        allocator.free(self.client_connection_id);
        allocator.free(self.server_name_indication);
        allocator.free(self.client_quic_versions);
        allocator.free(self.client_quic_trnsp_params);
        allocator.free(self.client_sig_algs);

        for (self.trusted_fingerprints) |fp| {
            allocator.free(fp);
        }
        allocator.free(self.trusted_fingerprints);

        for (self.client_kex_algs) |*kex| {
            allocator.free(kex.name);
            allocator.free(kex.data);
        }
        allocator.free(self.client_kex_algs);

        for (self.quic_tls_cipher_suites) |suite| {
            allocator.free(suite);
        }
        allocator.free(self.quic_tls_cipher_suites);

        for (self.ext_pairs) |*ext| {
            allocator.free(ext.name);
            allocator.free(ext.data);
        }
        allocator.free(self.ext_pairs);
    }

    /// Encode SSH_QUIC_INIT to wire format
    ///
    /// Returns allocated buffer containing the encoded message
    pub fn encode(self: *const SshQuicInit, allocator: Allocator) ![]u8 {
        // Calculate required size
        var size: usize = 0;
        size += 1; // packet type
        size += 1 + self.client_connection_id.len; // short-str
        size += 1 + self.server_name_indication.len; // short-str
        size += 1; // nr-quic-versions
        size += self.client_quic_versions.len * 4; // uint32 array
        size += 4 + self.client_quic_trnsp_params.len; // string
        size += 4 + self.client_sig_algs.len; // string
        size += 1; // nr-trusted-fingerprints
        for (self.trusted_fingerprints) |fp| {
            size += 1 + fp.len; // short-str
        }
        size += 1; // nr-client-kex-algs
        for (self.client_kex_algs) |kex| {
            size += 1 + kex.name.len; // short-str
            size += 4 + kex.data.len; // string
        }
        size += 1; // nr-cipher-suites
        for (self.quic_tls_cipher_suites) |suite| {
            size += 1 + suite.len; // short-str
        }
        size += 1; // nr-ext-pairs
        for (self.ext_pairs) |ext| {
            size += 1 + ext.name.len; // short-str
            size += 4 + ext.data.len; // string
        }

        // Add padding to reach minimum 1200 bytes
        const padding_size = if (size >= min_payload_size) 0 else min_payload_size - size;
        size += padding_size;

        // Allocate buffer
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        // Write to buffer
        var writer = wire.Writer{ .buffer = buffer };

        // Packet type
        try writer.writeByte(@intFromEnum(constants.PacketType.ssh_quic_init));

        // Connection IDs
        try writer.writeShortStr(self.client_connection_id);
        try writer.writeShortStr(self.server_name_indication);

        // QUIC versions
        try writer.writeByte(@intCast(self.client_quic_versions.len));
        for (self.client_quic_versions) |version| {
            try writer.writeUint32(version);
        }
        try writer.writeString(self.client_quic_trnsp_params);

        // Signature algorithms
        try writer.writeString(self.client_sig_algs);

        // Trusted fingerprints
        try writer.writeByte(@intCast(self.trusted_fingerprints.len));
        for (self.trusted_fingerprints) |fp| {
            try writer.writeShortStr(fp);
        }

        // Key exchange algorithms
        try writer.writeByte(@intCast(self.client_kex_algs.len));
        for (self.client_kex_algs) |kex| {
            try writer.writeShortStr(kex.name);
            try writer.writeString(kex.data);
        }

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

        // Padding (0xFF bytes)
        for (0..padding_size) |_| {
            try writer.writeByte(padding_byte);
        }

        return buffer;
    }

    /// Decode SSH_QUIC_INIT from wire format
    ///
    /// Returns decoded message structure
    pub fn decode(allocator: Allocator, data: []const u8) !SshQuicInit {
        var reader = wire.Reader{ .buffer = data };

        // Check minimum size
        if (data.len < min_payload_size) {
            return error.PacketTooSmall;
        }

        // Read packet type
        const packet_type = try reader.readByte();
        if (packet_type != @intFromEnum(constants.PacketType.ssh_quic_init)) {
            return error.InvalidPacketType;
        }

        // Connection IDs
        const client_connection_id = try reader.readShortStr(allocator);
        errdefer allocator.free(client_connection_id);

        const server_name_indication = try reader.readShortStr(allocator);
        errdefer allocator.free(server_name_indication);

        // QUIC versions
        const nr_quic_versions = try reader.readByte();
        if (nr_quic_versions == 0) {
            return error.NoQuicVersions;
        }

        const client_quic_versions = try allocator.alloc(u32, nr_quic_versions);
        errdefer allocator.free(client_quic_versions);

        for (client_quic_versions) |*version| {
            version.* = try reader.readUint32();
        }

        const client_quic_trnsp_params = try reader.readString(allocator);
        errdefer allocator.free(client_quic_trnsp_params);

        // Signature algorithms
        const client_sig_algs = try reader.readString(allocator);
        errdefer allocator.free(client_sig_algs);

        if (client_sig_algs.len == 0) {
            return error.NoSignatureAlgorithms;
        }

        // Trusted fingerprints
        const nr_trusted_fingerprints = try reader.readByte();
        const trusted_fingerprints = try allocator.alloc([]const u8, nr_trusted_fingerprints);
        errdefer {
            for (trusted_fingerprints[0..nr_trusted_fingerprints]) |fp| {
                allocator.free(fp);
            }
            allocator.free(trusted_fingerprints);
        }

        for (trusted_fingerprints) |*fp| {
            fp.* = try reader.readShortStr(allocator);
            if (fp.len == 0) {
                return error.EmptyFingerprint;
            }
        }

        // Key exchange algorithms
        const nr_client_kex_algs = try reader.readByte();
        if (nr_client_kex_algs == 0) {
            return error.NoKexAlgorithms;
        }

        const client_kex_algs = try allocator.alloc(KexAlgorithm, nr_client_kex_algs);
        errdefer {
            for (client_kex_algs[0..nr_client_kex_algs]) |*kex| {
                allocator.free(kex.name);
                allocator.free(kex.data);
            }
            allocator.free(client_kex_algs);
        }

        for (client_kex_algs) |*kex| {
            kex.name = try reader.readShortStr(allocator);
            if (kex.name.len == 0) {
                return error.EmptyKexAlgorithmName;
            }
            kex.data = try reader.readString(allocator);
            if (kex.data.len == 0) {
                return error.EmptyKexAlgorithmData;
            }
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

        // Rest is padding - we can ignore it

        return SshQuicInit{
            .client_connection_id = client_connection_id,
            .server_name_indication = server_name_indication,
            .client_quic_versions = client_quic_versions,
            .client_quic_trnsp_params = client_quic_trnsp_params,
            .client_sig_algs = client_sig_algs,
            .trusted_fingerprints = trusted_fingerprints,
            .client_kex_algs = client_kex_algs,
            .quic_tls_cipher_suites = quic_tls_cipher_suites,
            .ext_pairs = ext_pairs,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SshQuicInit - encode and decode empty optional fields" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create minimal SSH_QUIC_INIT
    var init = SshQuicInit{
        .client_connection_id = "",
        .server_name_indication = "",
        .client_quic_versions = &[_]u32{1},
        .client_quic_trnsp_params = "",
        .client_sig_algs = "ssh-ed25519",
        .trusted_fingerprints = &[_][]const u8{},
        .client_kex_algs = &[_]KexAlgorithm{
            .{ .name = "curve25519-sha256", .data = "keydata" },
        },
        .quic_tls_cipher_suites = &[_][]const u8{"TLS_AES_256_GCM_SHA384"},
        .ext_pairs = &[_]ExtensionPair{},
    };

    // Encode
    const encoded = try init.encode(allocator);
    defer allocator.free(encoded);

    // Should be at least 1200 bytes
    try testing.expect(encoded.len >= min_payload_size);

    // Decode
    var decoded = try SshQuicInit.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    // Verify fields
    try testing.expectEqualStrings("", decoded.client_connection_id);
    try testing.expectEqualStrings("", decoded.server_name_indication);
    try testing.expectEqual(@as(usize, 1), decoded.client_quic_versions.len);
    try testing.expectEqual(@as(u32, 1), decoded.client_quic_versions[0]);
    try testing.expectEqualStrings("ssh-ed25519", decoded.client_sig_algs);
    try testing.expectEqual(@as(usize, 0), decoded.trusted_fingerprints.len);
    try testing.expectEqual(@as(usize, 1), decoded.client_kex_algs.len);
    try testing.expectEqualStrings("curve25519-sha256", decoded.client_kex_algs[0].name);
}

test "SshQuicInit - minimum size enforcement" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create minimal init
    var init = SshQuicInit{
        .client_connection_id = "",
        .server_name_indication = "",
        .client_quic_versions = &[_]u32{1},
        .client_quic_trnsp_params = "",
        .client_sig_algs = "ssh-ed25519",
        .trusted_fingerprints = &[_][]const u8{},
        .client_kex_algs = &[_]KexAlgorithm{
            .{ .name = "curve25519-sha256", .data = "x" },
        },
        .quic_tls_cipher_suites = &[_][]const u8{"TLS_AES_256_GCM_SHA384"},
        .ext_pairs = &[_]ExtensionPair{},
    };

    const encoded = try init.encode(allocator);
    defer allocator.free(encoded);

    // Must be exactly 1200 bytes (minimal message + padding)
    try testing.expectEqual(@as(usize, min_payload_size), encoded.len);
}

test "SshQuicInit - decode too small packet" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const small_data = [_]u8{1} ** 100; // Only 100 bytes
    const result = SshQuicInit.decode(allocator, &small_data);

    try testing.expectError(error.PacketTooSmall, result);
}
