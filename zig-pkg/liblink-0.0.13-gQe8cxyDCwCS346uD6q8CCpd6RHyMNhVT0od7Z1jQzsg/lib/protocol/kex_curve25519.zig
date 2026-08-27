const std = @import("std");
const Allocator = std.mem.Allocator;
const libfast = @import("libfast");
const wire = @import("wire.zig");
const constants = @import("../common/constants.zig");

/// curve25519-sha256 key exchange method (RFC 8731)
///
/// This implements the required key exchange method for SSH/QUIC.
/// Client ephemeral key pair
pub const ClientEphemeralKey = struct {
    public_key: [32]u8,
    private_key: [32]u8,

    /// Generate a new client ephemeral key pair
    pub fn generate(random: std.Random) !ClientEphemeralKey {
        const kp = try libfast.ssh_ecdh.KeyPair.generate(random);
        return ClientEphemeralKey{
            .public_key = kp.public_key,
            .private_key = kp.private_key,
        };
    }

    /// Encode client-kex-alg-data for SSH_QUIC_INIT
    ///
    /// Format: byte(30) || string(Q_C)
    pub fn encodeClientData(self: *const ClientEphemeralKey, allocator: Allocator) ![]u8 {
        // Calculate size: 1 (msg type) + 4 (string length) + 32 (public key)
        const size = 1 + 4 + 32;
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };
        try writer.writeByte(constants.SSH_MSG.KEX_ECDH_INIT);
        try writer.writeString(&self.public_key);

        return buffer;
    }

    /// Decode client-kex-alg-data from SSH_QUIC_INIT
    pub fn decodeClientData(allocator: Allocator, data: []const u8) !ClientEphemeralKey {
        var reader = wire.Reader{ .buffer = data };

        const msg_type = try reader.readByte();
        if (msg_type != constants.SSH_MSG.KEX_ECDH_INIT) {
            return error.InvalidMessageType;
        }

        const q_c = try reader.readString(allocator);
        defer allocator.free(q_c);

        if (q_c.len != 32) {
            return error.InvalidPublicKeySize;
        }

        var public_key: [32]u8 = undefined;
        @memcpy(&public_key, q_c);

        // Private key is not available when decoding client data
        return ClientEphemeralKey{
            .public_key = public_key,
            .private_key = [_]u8{0} ** 32,
        };
    }
};

/// Server ephemeral key and signature
pub const ServerEphemeralKey = struct {
    public_key: [32]u8,
    private_key: [32]u8,

    /// Generate a new server ephemeral key pair
    pub fn generate(random: std.Random) !ServerEphemeralKey {
        const kp = try libfast.ssh_ecdh.KeyPair.generate(random);
        return ServerEphemeralKey{
            .public_key = kp.public_key,
            .private_key = kp.private_key,
        };
    }

    /// Encode server-kex-alg-data for SSH_QUIC_REPLY
    ///
    /// Format: byte(31) || string(K_S) || string(Q_S) || string(signature)
    pub fn encodeServerData(
        self: *const ServerEphemeralKey,
        allocator: Allocator,
        host_key: []const u8,
        signature: []const u8,
    ) ![]u8 {
        // Calculate size
        const size = 1 + 4 + host_key.len + 4 + 32 + 4 + signature.len;
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };
        try writer.writeByte(constants.SSH_MSG.KEX_ECDH_REPLY);
        try writer.writeString(host_key);
        try writer.writeString(&self.public_key);
        try writer.writeString(signature);

        return buffer;
    }

    /// Decode server-kex-alg-data from SSH_QUIC_REPLY
    pub fn decodeServerData(allocator: Allocator, data: []const u8) !struct {
        public_key: [32]u8,
        host_key: []const u8,
        signature: []const u8,
    } {
        var reader = wire.Reader{ .buffer = data };

        const msg_type = try reader.readByte();
        if (msg_type != constants.SSH_MSG.KEX_ECDH_REPLY) {
            return error.InvalidMessageType;
        }

        const host_key = try reader.readString(allocator);
        errdefer allocator.free(host_key);

        const q_s = try reader.readString(allocator);
        defer allocator.free(q_s);

        if (q_s.len != 32) {
            allocator.free(host_key);
            return error.InvalidPublicKeySize;
        }

        var public_key: [32]u8 = undefined;
        @memcpy(&public_key, q_s);

        const signature = try reader.readString(allocator);
        errdefer allocator.free(signature);

        return .{
            .public_key = public_key,
            .host_key = host_key,
            .signature = signature,
        };
    }
};

/// Calculate shared secret K using X25519
///
/// K = X25519(private_key, peer_public_key)
pub fn calculateSharedSecret(
    private_key: *const [32]u8,
    peer_public_key: *const [32]u8,
) ![32]u8 {
    return libfast.ssh_ecdh.exchange(private_key, peer_public_key);
}

/// Calculate exchange hash H for curve25519-sha256
///
/// Per draft-bider-ssh-quic-09 Section 3.2, Figure 9:
/// H = SHA-256(
///   byte[8]  "SSH/QUIC"
///   string   SSH_QUIC_INIT content
///   string   SSH_QUIC_REPLY content without server-kex-alg-data
///   byte(31)
///   string   K_S
///   string   Q_C
///   string   Q_S
///   mpint    K
/// )
pub fn calculateExchangeHash(
    allocator: Allocator,
    init_content: []const u8,
    reply_content_without_kex: []const u8,
    host_key: []const u8,
    client_public_key: *const [32]u8,
    server_public_key: *const [32]u8,
    shared_secret: *const [32]u8,
) ![]u8 {
    var total_size: usize = 0;
    total_size += 8; // byte[8] "SSH/QUIC"
    total_size += 4 + init_content.len; // string(init)
    total_size += 4 + reply_content_without_kex.len; // string(reply without kex)
    total_size += 1; // byte(31)
    total_size += 4 + host_key.len; // string(K_S)
    total_size += 4 + 32; // string(Q_C)
    total_size += 4 + 32; // string(Q_S)

    // mpint encoding: 4 bytes length + data (+ possible leading 0x00)
    const k_mpint_size = 4 + 1 + 32;
    total_size += k_mpint_size;

    const hash_input = try allocator.alloc(u8, total_size);
    defer allocator.free(hash_input);

    var writer = wire.Writer{ .buffer = hash_input };

    // "SSH/QUIC" prefix (raw bytes, not a string)
    @memcpy(hash_input[0..8], "SSH/QUIC");
    writer.offset = 8;

    try writer.writeString(init_content);
    try writer.writeString(reply_content_without_kex);
    try writer.writeByte(constants.SSH_MSG.KEX_ECDH_REPLY);
    try writer.writeString(host_key);
    try writer.writeString(client_public_key);
    try writer.writeString(server_public_key);

    // Write K as mpint (positive, add leading 0x00 byte if high bit is set)
    var k_mpint_buf: [33]u8 = undefined;
    if (shared_secret[0] & 0x80 != 0) {
        k_mpint_buf[0] = 0x00;
        @memcpy(k_mpint_buf[1..33], shared_secret);
        try writer.writeMpint(&k_mpint_buf);
    } else {
        try writer.writeMpint(shared_secret);
    }

    const hash = try allocator.alloc(u8, 32);
    std.crypto.hash.sha2.Sha256.hash(hash_input, hash[0..32], .{});

    return hash;
}

// ============================================================================
// Tests
// ============================================================================

test "ClientEphemeralKey - generate and encode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    const client_key = try ClientEphemeralKey.generate(random);

    // Encode
    const encoded = try client_key.encodeClientData(allocator);
    defer allocator.free(encoded);

    // Should start with message type 30
    try testing.expectEqual(@as(u8, 30), encoded[0]);

    // Should contain public key
    try testing.expect(encoded.len > 32);
}

test "ClientEphemeralKey - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(54321);
    const random = prng.random();

    const client_key = try ClientEphemeralKey.generate(random);

    // Encode
    const encoded = try client_key.encodeClientData(allocator);
    defer allocator.free(encoded);

    // Decode
    const decoded = try ClientEphemeralKey.decodeClientData(allocator, encoded);

    // Public keys should match
    try testing.expectEqualSlices(u8, &client_key.public_key, &decoded.public_key);
}

test "ServerEphemeralKey - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(99999);
    const random = prng.random();

    const server_key = try ServerEphemeralKey.generate(random);
    const host_key = "ssh-ed25519 AAAA...";
    const signature = "signature_data_here";

    // Encode
    const encoded = try server_key.encodeServerData(allocator, host_key, signature);
    defer allocator.free(encoded);

    // Decode
    const decoded = try ServerEphemeralKey.decodeServerData(allocator, encoded);
    defer allocator.free(decoded.host_key);
    defer allocator.free(decoded.signature);

    // Verify fields
    try testing.expectEqualSlices(u8, &server_key.public_key, &decoded.public_key);
    try testing.expectEqualStrings(host_key, decoded.host_key);
    try testing.expectEqualStrings(signature, decoded.signature);
}

test "calculateSharedSecret - basic functionality" {
    const testing = std.testing;

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Generate two key pairs
    const alice = try ClientEphemeralKey.generate(random);
    const bob = try ServerEphemeralKey.generate(random);

    // Calculate shared secrets
    const alice_secret = try calculateSharedSecret(&alice.private_key, &bob.public_key);
    const bob_secret = try calculateSharedSecret(&bob.private_key, &alice.public_key);

    // Shared secrets should match
    try testing.expectEqualSlices(u8, &alice_secret, &bob_secret);
}

test "calculateExchangeHash - basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const init_content = "init_payload";
    const reply_content = "reply_payload_without_kex";
    const host_key = "host_key_data";
    const client_pub: [32]u8 = [_]u8{3} ** 32;
    const server_pub: [32]u8 = [_]u8{1} ** 32;
    const shared_secret: [32]u8 = [_]u8{2} ** 32;

    const hash = try calculateExchangeHash(
        allocator,
        init_content,
        reply_content,
        host_key,
        &client_pub,
        &server_pub,
        &shared_secret,
    );
    defer allocator.free(hash);

    // Hash should be 32 bytes (SHA-256)
    try testing.expectEqual(@as(usize, 32), hash.len);

    // Hash should not be all zeros
    var all_zero = true;
    for (hash) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try testing.expect(!all_zero);
}

test "calculateExchangeHash - deterministic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const init_content = "test_init";
    const reply_content = "test_reply";
    const host_key = "test_host_key";
    const client_pub: [32]u8 = [_]u8{0x11} ** 32;
    const server_pub: [32]u8 = [_]u8{0x42} ** 32;
    const shared_secret: [32]u8 = [_]u8{0x99} ** 32;

    // Calculate hash twice
    const hash1 = try calculateExchangeHash(
        allocator,
        init_content,
        reply_content,
        host_key,
        &client_pub,
        &server_pub,
        &shared_secret,
    );
    defer allocator.free(hash1);

    const hash2 = try calculateExchangeHash(
        allocator,
        init_content,
        reply_content,
        host_key,
        &client_pub,
        &server_pub,
        &shared_secret,
    );
    defer allocator.free(hash2);

    // Hashes should be identical
    try testing.expectEqualSlices(u8, hash1, hash2);
}
