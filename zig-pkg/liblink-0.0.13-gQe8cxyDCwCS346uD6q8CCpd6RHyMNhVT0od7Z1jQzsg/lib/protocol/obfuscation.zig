const std = @import("std");
const Allocator = std.mem.Allocator;

/// Obfuscated envelope constants
pub const obfs_nonce_size = 12;
pub const obfs_tag_size = 16;
pub const obfs_key_size = 32; // SHA-256 output

/// High bit marker for obfuscated packets (distinguishes from QUIC)
pub const high_bit_marker: u8 = 0x80;

/// Errors for obfuscation operations
pub const ObfuscationError = error{
    InvalidNonce,
    InvalidPayload,
    DecryptionFailed,
    OutOfMemory,
};

/// Process obfuscation keyword according to SPEC.md Section 2.3.1
///
/// Steps:
/// 1. Process according to OpaqueString profile (RFC 8265) - simplified
/// 2. Remove leading/trailing whitespace (tab, LF, CR, space)
/// 3. Encode as UTF-8 bytes
/// 4. Compute SHA-256 digest for encryption key
///
/// Parameters:
/// - keyword: User-entered obfuscation keyword (Unicode string)
/// - key_out: Output buffer for derived key (32 bytes)
pub fn processKeyword(keyword: []const u8, key_out: *[obfs_key_size]u8) void {
    // Simplified OpaqueString processing:
    // For now, we treat the input as UTF-8 and skip complex Unicode normalization.
    // A full implementation would apply RFC 8265 rules.

    // Step 2: Trim leading and trailing whitespace
    const trimmed = trimWhitespace(keyword);

    // Step 4: Compute SHA-256 digest
    std.crypto.hash.sha2.Sha256.hash(trimmed, key_out, .{});
}

/// Trim leading and trailing whitespace characters
///
/// Removes CHARACTER TABULATION (U+0009), LINE FEED (U+000A),
/// CARRIAGE RETURN (U+000D), and SPACE (U+0020).
fn trimWhitespace(input: []const u8) []const u8 {
    if (input.len == 0) return input;

    var start: usize = 0;
    var end: usize = input.len;

    // Trim leading whitespace
    while (start < end and isWhitespace(input[start])) {
        start += 1;
    }

    // Trim trailing whitespace
    while (end > start and isWhitespace(input[end - 1])) {
        end -= 1;
    }

    return input[start..end];
}

/// Check if character is trimmed whitespace
fn isWhitespace(c: u8) bool {
    return c == 0x09 or // CHARACTER TABULATION
        c == 0x0A or // LINE FEED
        c == 0x0D or // CARRIAGE RETURN
        c == 0x20; // SPACE
}

/// Obfuscated envelope structure
pub const ObfuscatedEnvelope = struct {
    nonce: [obfs_nonce_size]u8,
    payload: []u8,
    tag: [obfs_tag_size]u8,

    /// Free the payload memory
    pub fn deinit(self: *ObfuscatedEnvelope, allocator: Allocator) void {
        allocator.free(self.payload);
    }
};

/// Encrypt a packet into an obfuscated envelope
///
/// Parameters:
/// - allocator: Memory allocator for the encrypted payload
/// - keyword: Obfuscation keyword (will be processed automatically)
/// - plaintext: Unencrypted packet data
/// - random: Random number generator for nonce
///
/// Returns: ObfuscatedEnvelope with encrypted payload
pub fn encryptEnvelope(
    allocator: Allocator,
    keyword: []const u8,
    plaintext: []const u8,
    random: std.Random,
) !ObfuscatedEnvelope {
    // Derive encryption key from keyword
    var key: [obfs_key_size]u8 = undefined;
    processKeyword(keyword, &key);

    // Generate random nonce
    var nonce: [obfs_nonce_size]u8 = undefined;
    random.bytes(&nonce);
    // Ensure high bit is set to distinguish from QUIC datagrams
    nonce[0] |= high_bit_marker;

    // Allocate payload buffer (same size as plaintext)
    const payload = try allocator.alloc(u8, plaintext.len);
    errdefer allocator.free(payload);

    // Prepare tag buffer
    var tag: [obfs_tag_size]u8 = undefined;

    // Encrypt using AES-256-GCM
    std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(
        payload,
        &tag,
        plaintext,
        "",
        nonce,
        key,
    );

    return ObfuscatedEnvelope{
        .nonce = nonce,
        .payload = payload,
        .tag = tag,
    };
}

/// Decrypt an obfuscated envelope
///
/// Parameters:
/// - allocator: Memory allocator for the decrypted data
/// - keyword: Obfuscation keyword (will be processed automatically)
/// - envelope: Obfuscated envelope to decrypt
///
/// Returns: Decrypted plaintext data
pub fn decryptEnvelope(
    allocator: Allocator,
    keyword: []const u8,
    envelope: *const ObfuscatedEnvelope,
) ![]u8 {
    // Verify high bit is set in nonce
    if ((envelope.nonce[0] & high_bit_marker) == 0) {
        return error.InvalidNonce;
    }

    // Derive decryption key from keyword
    var key: [obfs_key_size]u8 = undefined;
    processKeyword(keyword, &key);

    // Allocate plaintext buffer (same size as ciphertext)
    const plaintext = try allocator.alloc(u8, envelope.payload.len);
    errdefer allocator.free(plaintext);

    // Decrypt using AES-256-GCM
    std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(
        plaintext,
        envelope.payload,
        envelope.tag,
        "",
        envelope.nonce,
        key,
    ) catch {
        allocator.free(plaintext);
        return error.DecryptionFailed;
    };

    return plaintext;
}

/// Serialize obfuscated envelope to wire format
///
/// Wire format: nonce || payload || tag
///
/// Parameters:
/// - envelope: Envelope to serialize
/// - out: Output buffer (must be at least nonce_size + payload.len + tag_size)
pub fn serializeEnvelope(envelope: *const ObfuscatedEnvelope, out: []u8) void {
    const total_size = obfs_nonce_size + envelope.payload.len + obfs_tag_size;
    std.debug.assert(out.len >= total_size);

    @memcpy(out[0..obfs_nonce_size], &envelope.nonce);
    @memcpy(out[obfs_nonce_size..][0..envelope.payload.len], envelope.payload);
    @memcpy(out[obfs_nonce_size + envelope.payload.len ..][0..obfs_tag_size], &envelope.tag);
}

/// Deserialize obfuscated envelope from wire format
///
/// Wire format: nonce || payload || tag
///
/// Parameters:
/// - allocator: Memory allocator for payload
/// - data: Wire format data
///
/// Returns: Deserialized envelope
pub fn deserializeEnvelope(allocator: Allocator, data: []const u8) !ObfuscatedEnvelope {
    const min_size = obfs_nonce_size + obfs_tag_size;
    if (data.len < min_size) {
        return error.InvalidPayload;
    }

    // Extract nonce
    var nonce: [obfs_nonce_size]u8 = undefined;
    @memcpy(&nonce, data[0..obfs_nonce_size]);

    // Calculate payload size and extract
    const payload_len = data.len - obfs_nonce_size - obfs_tag_size;
    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    @memcpy(payload, data[obfs_nonce_size..][0..payload_len]);

    // Extract tag
    var tag: [obfs_tag_size]u8 = undefined;
    @memcpy(&tag, data[data.len - obfs_tag_size ..]);

    return ObfuscatedEnvelope{
        .nonce = nonce,
        .payload = payload,
        .tag = tag,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "processKeyword - empty keyword" {
    const testing = std.testing;

    var key: [obfs_key_size]u8 = undefined;
    processKeyword("", &key);

    // SHA-256 of empty string
    const expected = [_]u8{
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
        0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
    };

    try testing.expectEqualSlices(u8, &expected, &key);
}

test "processKeyword - simple keyword" {
    const testing = std.testing;

    var key: [obfs_key_size]u8 = undefined;
    processKeyword("my-secret-keyword", &key);

    // Verify it's not empty (all zeros)
    var all_zero = true;
    for (key) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try testing.expect(!all_zero);
}

test "processKeyword - keyword with leading whitespace" {
    const testing = std.testing;

    var key1: [obfs_key_size]u8 = undefined;
    var key2: [obfs_key_size]u8 = undefined;

    processKeyword("  \t\n\r  secret", &key1);
    processKeyword("secret", &key2);

    // Should produce same key after trimming
    try testing.expectEqualSlices(u8, &key2, &key1);
}

test "processKeyword - keyword with trailing whitespace" {
    const testing = std.testing;

    var key1: [obfs_key_size]u8 = undefined;
    var key2: [obfs_key_size]u8 = undefined;

    processKeyword("secret  \t\n\r  ", &key1);
    processKeyword("secret", &key2);

    // Should produce same key after trimming
    try testing.expectEqualSlices(u8, &key2, &key1);
}

test "processKeyword - keyword with leading and trailing whitespace" {
    const testing = std.testing;

    var key1: [obfs_key_size]u8 = undefined;
    var key2: [obfs_key_size]u8 = undefined;

    processKeyword("  \t  secret  \n\r  ", &key1);
    processKeyword("secret", &key2);

    // Should produce same key after trimming
    try testing.expectEqualSlices(u8, &key2, &key1);
}

test "processKeyword - keyword with internal whitespace" {
    const testing = std.testing;

    var key1: [obfs_key_size]u8 = undefined;
    var key2: [obfs_key_size]u8 = undefined;

    processKeyword("my secret keyword", &key1);
    processKeyword("my secret keyword", &key2);

    // Internal whitespace should be preserved
    try testing.expectEqualSlices(u8, &key2, &key1);
}

test "trimWhitespace - empty string" {
    const testing = std.testing;
    const result = trimWhitespace("");
    try testing.expectEqualStrings("", result);
}

test "trimWhitespace - only whitespace" {
    const testing = std.testing;
    const result = trimWhitespace("  \t\n\r  ");
    try testing.expectEqualStrings("", result);
}

test "trimWhitespace - no whitespace" {
    const testing = std.testing;
    const result = trimWhitespace("hello");
    try testing.expectEqualStrings("hello", result);
}

test "trimWhitespace - leading whitespace" {
    const testing = std.testing;
    const result = trimWhitespace("  \t\n\rhello");
    try testing.expectEqualStrings("hello", result);
}

test "trimWhitespace - trailing whitespace" {
    const testing = std.testing;
    const result = trimWhitespace("hello  \t\n\r");
    try testing.expectEqualStrings("hello", result);
}

test "trimWhitespace - both leading and trailing" {
    const testing = std.testing;
    const result = trimWhitespace("  \t\n\rhello  \t\n\r");
    try testing.expectEqualStrings("hello", result);
}

test "trimWhitespace - internal whitespace preserved" {
    const testing = std.testing;
    const result = trimWhitespace("  hello  world  ");
    try testing.expectEqualStrings("hello  world", result);
}

test "isWhitespace - tab" {
    const testing = std.testing;
    try testing.expect(isWhitespace(0x09));
}

test "isWhitespace - line feed" {
    const testing = std.testing;
    try testing.expect(isWhitespace(0x0A));
}

test "isWhitespace - carriage return" {
    const testing = std.testing;
    try testing.expect(isWhitespace(0x0D));
}

test "isWhitespace - space" {
    const testing = std.testing;
    try testing.expect(isWhitespace(0x20));
}

test "isWhitespace - non-whitespace" {
    const testing = std.testing;
    try testing.expect(!isWhitespace('a'));
    try testing.expect(!isWhitespace('0'));
    try testing.expect(!isWhitespace('_'));
}

test "encryptEnvelope - basic encryption" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const keyword = "test-keyword";
    const plaintext = "Hello, World!";
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    var envelope = try encryptEnvelope(allocator, keyword, plaintext, random);
    defer envelope.deinit(allocator);

    // Verify high bit is set in nonce
    try testing.expect((envelope.nonce[0] & high_bit_marker) != 0);

    // Verify payload length matches plaintext
    try testing.expectEqual(plaintext.len, envelope.payload.len);

    // Verify payload is encrypted (different from plaintext)
    try testing.expect(!std.mem.eql(u8, plaintext, envelope.payload));
}

test "encryptEnvelope and decryptEnvelope - round trip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const keyword = "my-secret";
    const plaintext = "This is a secret message!";
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Encrypt
    var envelope = try encryptEnvelope(allocator, keyword, plaintext, random);
    defer envelope.deinit(allocator);

    // Decrypt
    const decrypted = try decryptEnvelope(allocator, keyword, &envelope);
    defer allocator.free(decrypted);

    // Verify decrypted matches plaintext
    try testing.expectEqualStrings(plaintext, decrypted);
}

test "decryptEnvelope - wrong keyword" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const plaintext = "Secret data";
    var prng = std.Random.DefaultPrng.init(123);
    const random = prng.random();

    // Encrypt with one keyword
    var envelope = try encryptEnvelope(allocator, "correct-keyword", plaintext, random);
    defer envelope.deinit(allocator);

    // Try to decrypt with wrong keyword
    const result = decryptEnvelope(allocator, "wrong-keyword", &envelope);

    try testing.expectError(error.DecryptionFailed, result);
}

test "decryptEnvelope - invalid nonce" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var envelope = ObfuscatedEnvelope{
        .nonce = [_]u8{0x00} ** obfs_nonce_size, // High bit NOT set
        .payload = try allocator.alloc(u8, 16),
        .tag = [_]u8{0x00} ** obfs_tag_size,
    };
    defer allocator.free(envelope.payload);

    const result = decryptEnvelope(allocator, "keyword", &envelope);
    try testing.expectError(error.InvalidNonce, result);
}

test "encryptEnvelope - empty keyword" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const plaintext = "Test message";
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    var envelope = try encryptEnvelope(allocator, "", plaintext, random);
    defer envelope.deinit(allocator);

    const decrypted = try decryptEnvelope(allocator, "", &envelope);
    defer allocator.free(decrypted);

    try testing.expectEqualStrings(plaintext, decrypted);
}

test "encryptEnvelope - keyword with whitespace" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const plaintext = "Message";
    var prng = std.Random.DefaultPrng.init(999);
    const random = prng.random();

    // Encrypt with whitespace-padded keyword
    var envelope = try encryptEnvelope(allocator, "  \t keyword \n ", plaintext, random);
    defer envelope.deinit(allocator);

    // Decrypt with trimmed keyword
    const decrypted = try decryptEnvelope(allocator, "keyword", &envelope);
    defer allocator.free(decrypted);

    try testing.expectEqualStrings(plaintext, decrypted);
}

test "serializeEnvelope and deserializeEnvelope - round trip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const plaintext = "Test data for serialization";
    var prng = std.Random.DefaultPrng.init(555);
    const random = prng.random();

    // Create envelope
    var envelope1 = try encryptEnvelope(allocator, "serialize-key", plaintext, random);
    defer envelope1.deinit(allocator);

    // Serialize
    const wire_size = obfs_nonce_size + envelope1.payload.len + obfs_tag_size;
    const wire_data = try allocator.alloc(u8, wire_size);
    defer allocator.free(wire_data);
    serializeEnvelope(&envelope1, wire_data);

    // Deserialize
    var envelope2 = try deserializeEnvelope(allocator, wire_data);
    defer envelope2.deinit(allocator);

    // Verify nonce matches
    try testing.expectEqualSlices(u8, &envelope1.nonce, &envelope2.nonce);

    // Verify payload matches
    try testing.expectEqualSlices(u8, envelope1.payload, envelope2.payload);

    // Verify tag matches
    try testing.expectEqualSlices(u8, &envelope1.tag, &envelope2.tag);

    // Decrypt to verify integrity
    const decrypted = try decryptEnvelope(allocator, "serialize-key", &envelope2);
    defer allocator.free(decrypted);
    try testing.expectEqualStrings(plaintext, decrypted);
}

test "deserializeEnvelope - too short" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const short_data = [_]u8{0x80} ** 16; // Only 16 bytes, needs at least 32
    const result = deserializeEnvelope(allocator, &short_data);

    try testing.expectError(error.InvalidPayload, result);
}

test "encryptEnvelope - large payload" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a large plaintext (1 KB)
    const plaintext = try allocator.alloc(u8, 1024);
    defer allocator.free(plaintext);
    @memset(plaintext, 'A');

    var prng = std.Random.DefaultPrng.init(777);
    const random = prng.random();

    var envelope = try encryptEnvelope(allocator, "large-key", plaintext, random);
    defer envelope.deinit(allocator);

    const decrypted = try decryptEnvelope(allocator, "large-key", &envelope);
    defer allocator.free(decrypted);

    try testing.expectEqualSlices(u8, plaintext, decrypted);
}

test "obfuscation - deterministic test vector" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Use fixed seed for deterministic test
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    const keyword = "test-vector-keyword";
    const plaintext = "SSH-QUIC test message";

    // Encrypt
    var envelope = try encryptEnvelope(allocator, keyword, plaintext, random);
    defer envelope.deinit(allocator);

    // Verify nonce high bit is set
    try testing.expect((envelope.nonce[0] & high_bit_marker) != 0);

    // Serialize to wire format
    const wire_size = obfs_nonce_size + envelope.payload.len + obfs_tag_size;
    const wire_data = try allocator.alloc(u8, wire_size);
    defer allocator.free(wire_data);
    serializeEnvelope(&envelope, wire_data);

    // Deserialize from wire format
    var envelope2 = try deserializeEnvelope(allocator, wire_data);
    defer envelope2.deinit(allocator);

    // Decrypt
    const decrypted = try decryptEnvelope(allocator, keyword, &envelope2);
    defer allocator.free(decrypted);

    // Verify round-trip
    try testing.expectEqualStrings(plaintext, decrypted);

    // Verify envelope structure
    try testing.expectEqual(@as(usize, obfs_nonce_size), envelope.nonce.len);
    try testing.expectEqual(@as(usize, obfs_tag_size), envelope.tag.len);
    try testing.expectEqual(plaintext.len, envelope.payload.len);
}

test "obfuscation - empty plaintext" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    const plaintext = "";

    var envelope = try encryptEnvelope(allocator, "empty-test", plaintext, random);
    defer envelope.deinit(allocator);

    // Verify payload is empty
    try testing.expectEqual(@as(usize, 0), envelope.payload.len);

    const decrypted = try decryptEnvelope(allocator, "empty-test", &envelope);
    defer allocator.free(decrypted);

    try testing.expectEqualStrings(plaintext, decrypted);
}

test "obfuscation - multiple encryptions with same keyword produce different ciphertexts" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const keyword = "same-keyword";
    const plaintext = "Same plaintext";

    var prng1 = std.Random.DefaultPrng.init(1111);
    var prng2 = std.Random.DefaultPrng.init(2222);

    var envelope1 = try encryptEnvelope(allocator, keyword, plaintext, prng1.random());
    defer envelope1.deinit(allocator);

    var envelope2 = try encryptEnvelope(allocator, keyword, plaintext, prng2.random());
    defer envelope2.deinit(allocator);

    // Nonces should be different (different random seeds)
    try testing.expect(!std.mem.eql(u8, &envelope1.nonce, &envelope2.nonce));

    // Ciphertexts should be different (different nonces)
    try testing.expect(!std.mem.eql(u8, envelope1.payload, envelope2.payload));

    // But both should decrypt to same plaintext
    const decrypted1 = try decryptEnvelope(allocator, keyword, &envelope1);
    defer allocator.free(decrypted1);

    const decrypted2 = try decryptEnvelope(allocator, keyword, &envelope2);
    defer allocator.free(decrypted2);

    try testing.expectEqualStrings(plaintext, decrypted1);
    try testing.expectEqualStrings(plaintext, decrypted2);
}
