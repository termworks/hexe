const std = @import("std");
const Allocator = std.mem.Allocator;
const libfast = @import("libfast");
const wire = @import("wire.zig");

/// SSH/QUIC key derivation per SPEC.md Section 5.1
///
/// Derives QUIC client and server secrets from SSH key exchange outputs.

/// Derive QUIC client and server secrets from SSH key exchange
///
/// Parameters:
/// - shared_secret_k: Shared secret K from key exchange (32 bytes for X25519)
/// - exchange_hash_h: Exchange hash H from key exchange
/// - client_secret: Output buffer for client secret (32 bytes for SHA-256)
/// - server_secret: Output buffer for server secret (32 bytes for SHA-256)
///
/// The secrets are derived as:
///   client_secret = HMAC-SHA256("ssh/quic client", secret_data)
///   server_secret = HMAC-SHA256("ssh/quic server", secret_data)
///
/// Where secret_data = mpint(K) || string(H)
pub fn deriveQuicSecrets(
    allocator: Allocator,
    shared_secret_k: []const u8,
    exchange_hash_h: []const u8,
    client_secret: *[32]u8,
    server_secret: *[32]u8,
) !void {
    var derived = try libfast.ssh_secrets.deriveSshQuicSecrets(allocator, shared_secret_k, exchange_hash_h);
    defer derived.zeroize();
    client_secret.* = derived.client_initial_secret;
    server_secret.* = derived.server_initial_secret;
}

/// Encode secret_data = mpint(K) || string(H)
fn encodeSecretData(
    allocator: Allocator,
    shared_secret_k: []const u8,
    exchange_hash_h: []const u8,
) ![]u8 {
    // Calculate size: mpint(K) + string(H)
    // mpint: 4 bytes length + data (possibly +1 for sign byte)
    // string: 4 bytes length + data
    var size: usize = 0;

    // mpint(K) size
    const k_needs_padding = shared_secret_k.len > 0 and (shared_secret_k[0] & 0x80) != 0;
    size += 4; // length field
    if (k_needs_padding) {
        size += 1; // padding byte
    }
    size += shared_secret_k.len;

    // string(H) size
    size += 4 + exchange_hash_h.len;

    // Allocate buffer
    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    var writer = wire.Writer{ .buffer = buffer };

    // Write mpint(K)
    try writer.writeMpint(shared_secret_k);

    // Write string(H)
    try writer.writeString(exchange_hash_h);

    return buffer;
}

/// Session ID is the exchange hash H from the first key exchange
pub const SessionId = []const u8;

/// Derive session ID (first exchange hash H)
pub fn deriveSessionId(allocator: Allocator, first_exchange_hash: []const u8) !SessionId {
    const session_id = try allocator.alloc(u8, first_exchange_hash.len);
    @memcpy(session_id, first_exchange_hash);
    return session_id;
}

// ============================================================================
// Tests
// ============================================================================

test "deriveQuicSecrets - basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test vectors
    const shared_secret_k: [32]u8 = [_]u8{0x42} ** 32;
    const exchange_hash_h: [32]u8 = [_]u8{0x99} ** 32;

    var client_secret: [32]u8 = undefined;
    var server_secret: [32]u8 = undefined;

    try deriveQuicSecrets(
        allocator,
        &shared_secret_k,
        &exchange_hash_h,
        &client_secret,
        &server_secret,
    );

    // Secrets should not be all zeros
    var client_all_zero = true;
    for (client_secret) |b| {
        if (b != 0) {
            client_all_zero = false;
            break;
        }
    }
    try testing.expect(!client_all_zero);

    var server_all_zero = true;
    for (server_secret) |b| {
        if (b != 0) {
            server_all_zero = false;
            break;
        }
    }
    try testing.expect(!server_all_zero);

    // Client and server secrets should be different
    try testing.expect(!std.mem.eql(u8, &client_secret, &server_secret));
}

test "deriveQuicSecrets - deterministic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const shared_secret_k: [32]u8 = [_]u8{0x12} ** 32;
    const exchange_hash_h: [32]u8 = [_]u8{0x34} ** 32;

    // Derive twice
    var client_secret1: [32]u8 = undefined;
    var server_secret1: [32]u8 = undefined;
    try deriveQuicSecrets(
        allocator,
        &shared_secret_k,
        &exchange_hash_h,
        &client_secret1,
        &server_secret1,
    );

    var client_secret2: [32]u8 = undefined;
    var server_secret2: [32]u8 = undefined;
    try deriveQuicSecrets(
        allocator,
        &shared_secret_k,
        &exchange_hash_h,
        &client_secret2,
        &server_secret2,
    );

    // Results should be identical
    try testing.expectEqualSlices(u8, &client_secret1, &client_secret2);
    try testing.expectEqualSlices(u8, &server_secret1, &server_secret2);
}

test "deriveQuicSecrets - different inputs produce different outputs" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const shared_secret_k1: [32]u8 = [_]u8{0x11} ** 32;
    const shared_secret_k2: [32]u8 = [_]u8{0x22} ** 32;
    const exchange_hash_h: [32]u8 = [_]u8{0x99} ** 32;

    var client_secret1: [32]u8 = undefined;
    var server_secret1: [32]u8 = undefined;
    try deriveQuicSecrets(
        allocator,
        &shared_secret_k1,
        &exchange_hash_h,
        &client_secret1,
        &server_secret1,
    );

    var client_secret2: [32]u8 = undefined;
    var server_secret2: [32]u8 = undefined;
    try deriveQuicSecrets(
        allocator,
        &shared_secret_k2,
        &exchange_hash_h,
        &client_secret2,
        &server_secret2,
    );

    // Different K should produce different secrets
    try testing.expect(!std.mem.eql(u8, &client_secret1, &client_secret2));
    try testing.expect(!std.mem.eql(u8, &server_secret1, &server_secret2));
}

test "encodeSecretData - basic encoding" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const k: [8]u8 = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    const h: [4]u8 = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };

    const secret_data = try encodeSecretData(allocator, &k, &h);
    defer allocator.free(secret_data);

    // Should contain both mpint(K) and string(H)
    try testing.expect(secret_data.len > k.len + h.len);

    // Verify we can decode it
    var reader = wire.Reader{ .buffer = secret_data };
    const decoded_k = try reader.readMpint(allocator);
    defer allocator.free(decoded_k);
    const decoded_h = try reader.readString(allocator);
    defer allocator.free(decoded_h);

    try testing.expectEqualSlices(u8, &k, decoded_k);
    try testing.expectEqualSlices(u8, &h, decoded_h);
}

test "encodeSecretData - K with high bit set" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // K with high bit set (needs padding for positive mpint)
    const k: [4]u8 = [_]u8{ 0xFF, 0xFE, 0xFD, 0xFC };
    const h: [4]u8 = [_]u8{ 0x11, 0x22, 0x33, 0x44 };

    const secret_data = try encodeSecretData(allocator, &k, &h);
    defer allocator.free(secret_data);

    // Decode and verify
    var reader = wire.Reader{ .buffer = secret_data };
    const decoded_k = try reader.readMpint(allocator);
    defer allocator.free(decoded_k);

    // mpint should have added padding byte
    try testing.expectEqual(@as(usize, 5), decoded_k.len);
    try testing.expectEqual(@as(u8, 0x00), decoded_k[0]);
    try testing.expectEqualSlices(u8, &k, decoded_k[1..]);
}

test "deriveSessionId - basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const exchange_hash: [32]u8 = [_]u8{0xAB} ** 32;

    const session_id = try deriveSessionId(allocator, &exchange_hash);
    defer allocator.free(session_id);

    // Session ID should equal first exchange hash
    try testing.expectEqualSlices(u8, &exchange_hash, session_id);
}
