const std = @import("std");
const Allocator = std.mem.Allocator;

/// QUIC Packet Protection using SSH-derived secrets
///
/// Uses AES-256-GCM for packet encryption and authentication.
/// Secrets come from SSH key exchange (not TLS).
pub const PacketProtection = struct {
    client_key: [32]u8,
    client_iv: [12]u8,
    server_key: [32]u8,
    server_iv: [12]u8,
    is_server: bool,

    const Self = @This();

    /// Initialize packet protection with SSH-derived secrets
    ///
    /// client_secret and server_secret are derived from SSH key exchange:
    /// - client_secret = HMAC-SHA256("ssh/quic client", K || H)
    /// - server_secret = HMAC-SHA256("ssh/quic server", K || H)
    pub fn init(client_secret: [32]u8, server_secret: [32]u8, is_server: bool) Self {
        // Use secrets directly as keys (simplified - real QUIC derives keys via HKDF)
        var client_iv: [12]u8 = undefined;
        var server_iv: [12]u8 = undefined;

        // Derive IVs from secrets (XOR with constant)
        for (0..12) |i| {
            client_iv[i] = client_secret[i] ^ 0xAA;
            server_iv[i] = server_secret[i] ^ 0xBB;
        }

        return Self{
            .client_key = client_secret,
            .client_iv = client_iv,
            .server_key = server_secret,
            .server_iv = server_iv,
            .is_server = is_server,
        };
    }

    /// Encrypt outgoing packet payload
    ///
    /// Returns encrypted payload with authentication tag appended
    pub fn encryptPacket(
        self: *const Self,
        packet_number: u32,
        header: []const u8,
        payload: []const u8,
        allocator: Allocator,
    ) ![]u8 {
        // Select key/IV based on role
        const key = if (self.is_server) self.server_key else self.client_key;
        const base_iv = if (self.is_server) self.server_iv else self.client_iv;

        // XOR packet number into IV
        var nonce: [12]u8 = base_iv;
        const pn_bytes = std.mem.asBytes(&packet_number);
        for (0..4) |i| {
            nonce[8 + i] ^= pn_bytes[i];
        }

        // Allocate buffer for ciphertext + tag
        const output = try allocator.alloc(u8, payload.len + 16); // 16-byte auth tag
        errdefer allocator.free(output);

        // Encrypt using AES-256-GCM
        const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

        const tag_ptr: *[16]u8 = @ptrCast(output[payload.len .. payload.len + 16]);
        Aes256Gcm.encrypt(
            output[0..payload.len],
            tag_ptr,
            payload,
            header, // Additional authenticated data
            nonce,
            key,
        );

        return output;
    }

    /// Decrypt incoming packet payload
    ///
    /// Verifies authentication tag and returns plaintext
    pub fn decryptPacket(
        self: *const Self,
        packet_number: u32,
        header: []const u8,
        ciphertext_with_tag: []const u8,
        allocator: Allocator,
    ) ![]u8 {
        if (ciphertext_with_tag.len < 16) return error.PacketTooSmall;

        // Select key/IV based on role (opposite of encrypt)
        const key = if (self.is_server) self.client_key else self.server_key;
        const base_iv = if (self.is_server) self.client_iv else self.server_iv;

        // XOR packet number into IV
        var nonce: [12]u8 = base_iv;
        const pn_bytes = std.mem.asBytes(&packet_number);
        for (0..4) |i| {
            nonce[8 + i] ^= pn_bytes[i];
        }

        const ciphertext_len = ciphertext_with_tag.len - 16;
        const ciphertext = ciphertext_with_tag[0..ciphertext_len];
        const tag = ciphertext_with_tag[ciphertext_len..][0..16];

        // Allocate buffer for plaintext
        const plaintext = try allocator.alloc(u8, ciphertext_len);

        // Decrypt using AES-256-GCM
        const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

        Aes256Gcm.decrypt(
            plaintext,
            ciphertext,
            tag.*,
            header, // Additional authenticated data
            nonce,
            key,
        ) catch |err| {
            allocator.free(plaintext);
            return err;
        };

        return plaintext;
    }

    /// Protect packet header (mask packet number)
    ///
    /// This prevents passive observers from correlating packets.
    /// Real QUIC uses ChaCha20 for header protection, simplified here.
    pub fn protectHeader(
        self: *const Self,
        header: []u8,
        sample: []const u8,
    ) !void {
        _ = self;

        // Simplified: Just XOR the packet number bytes with sample
        // Real implementation would use ChaCha20
        if (header.len < 2 or sample.len < 16) return error.InvalidInput;

        // Find packet number location (after connection ID)
        // For now, assume it starts at header.len - 4 (last 4 bytes)
        const pn_offset = if (header.len >= 4) header.len - 4 else return;

        for (0..4) |i| {
            if (pn_offset + i < header.len) {
                header[pn_offset + i] ^= sample[i];
            }
        }
    }

    /// Unprotect packet header (unmask packet number)
    pub fn unprotectHeader(
        self: *const Self,
        header: []u8,
        sample: []const u8,
    ) !void {
        // XOR is symmetric, so same operation as protect
        return self.protectHeader(header, sample);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "PacketProtection - encrypt and decrypt" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // SSH-derived secrets (simulated)
    const client_secret = [_]u8{0xAA} ** 32;
    const server_secret = [_]u8{0xBB} ** 32;

    // Client encrypts, server decrypts
    const client_crypto = PacketProtection.init(client_secret, server_secret, false);
    const server_crypto = PacketProtection.init(client_secret, server_secret, true);

    const packet_number: u32 = 42;
    const header = "QUIC_HEADER";
    const plaintext = "Hello, QUIC!";

    // Client encrypts
    const ciphertext = try client_crypto.encryptPacket(
        packet_number,
        header,
        plaintext,
        allocator,
    );
    defer allocator.free(ciphertext);

    // Verify ciphertext is different from plaintext
    try testing.expect(ciphertext.len == plaintext.len + 16); // +16 for auth tag

    // Server decrypts
    const decrypted = try server_crypto.decryptPacket(
        packet_number,
        header,
        ciphertext,
        allocator,
    );
    defer allocator.free(decrypted);

    // Verify plaintext recovered
    try testing.expectEqualSlices(u8, plaintext, decrypted);
}

test "PacketProtection - authentication failure" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const client_secret = [_]u8{0xCC} ** 32;
    const server_secret = [_]u8{0xDD} ** 32;

    const client_crypto = PacketProtection.init(client_secret, server_secret, false);
    const server_crypto = PacketProtection.init(client_secret, server_secret, true);

    const packet_number: u32 = 10;
    const header = "HEADER";
    const plaintext = "Data";

    // Encrypt
    const ciphertext = try client_crypto.encryptPacket(
        packet_number,
        header,
        plaintext,
        allocator,
    );
    defer allocator.free(ciphertext);

    // Tamper with ciphertext
    var tampered = try allocator.dupe(u8, ciphertext);
    defer allocator.free(tampered);
    tampered[0] ^= 0xFF;

    // Decryption should fail
    const result = server_crypto.decryptPacket(
        packet_number,
        header,
        tampered,
        allocator,
    );
    try testing.expectError(error.AuthenticationFailed, result);
}

test "PacketProtection - different packet numbers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const client_secret = [_]u8{0x11} ** 32;
    const server_secret = [_]u8{0x22} ** 32;

    const client_crypto = PacketProtection.init(client_secret, server_secret, false);
    const server_crypto = PacketProtection.init(client_secret, server_secret, true);

    const header = "H";
    const plaintext = "Test";

    // Encrypt same data with different packet numbers
    const ct1 = try client_crypto.encryptPacket(1, header, plaintext, allocator);
    defer allocator.free(ct1);

    const ct2 = try client_crypto.encryptPacket(2, header, plaintext, allocator);
    defer allocator.free(ct2);

    // Ciphertexts should be different (due to different nonces)
    try testing.expect(!std.mem.eql(u8, ct1, ct2));

    // Both should decrypt correctly with their respective packet numbers
    const pt1 = try server_crypto.decryptPacket(1, header, ct1, allocator);
    defer allocator.free(pt1);
    try testing.expectEqualSlices(u8, plaintext, pt1);

    const pt2 = try server_crypto.decryptPacket(2, header, ct2, allocator);
    defer allocator.free(pt2);
    try testing.expectEqualSlices(u8, plaintext, pt2);

    // Decrypting with wrong packet number should fail
    const result = server_crypto.decryptPacket(999, header, ct1, allocator);
    try testing.expectError(error.AuthenticationFailed, result);
}
