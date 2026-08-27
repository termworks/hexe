const std = @import("std");
const crypto = std.crypto;

pub const ObfuscationError = error{
    InvalidNonce,
    InvalidTag,
    BufferTooSmall,
    EncryptionFailed,
    DecryptionFailed,
    AuthenticationFailed,
};

pub const ObfuscationKey = struct {
    key: [32]u8,

    pub fn fromKeyword(keyword: []const u8) ObfuscationKey {
        var key: [32]u8 = undefined;
        crypto.hash.sha2.Sha256.hash(keyword, &key, .{});
        return ObfuscationKey{ .key = key };
    }

    pub fn empty() ObfuscationKey {
        return fromKeyword("");
    }
};

pub const ObfuscatedEnvelope = struct {
    const NONCE_LEN = 16;
    const TAG_LEN = 16;
    const OVERHEAD = NONCE_LEN + TAG_LEN;

    pub fn encrypt(plaintext: []const u8, key: ObfuscationKey, output: []u8) ObfuscationError!usize {
        if (output.len < plaintext.len + OVERHEAD) return error.BufferTooSmall;

        var nonce: [NONCE_LEN]u8 = undefined;
        crypto.random.bytes(&nonce);
        nonce[0] |= 0x80;

        const Aes256Gcm = crypto.aead.aes_gcm.Aes256Gcm;
        const ciphertext = output[NONCE_LEN..][0..plaintext.len];
        const tag = output[NONCE_LEN + plaintext.len ..][0..TAG_LEN];
        const gcm_nonce = nonce[0..12].*;

        Aes256Gcm.encrypt(ciphertext, tag, plaintext, &[_]u8{}, gcm_nonce, key.key);
        @memcpy(output[0..NONCE_LEN], &nonce);

        return NONCE_LEN + plaintext.len + TAG_LEN;
    }

    pub fn decrypt(envelope: []const u8, key: ObfuscationKey, output: []u8) ObfuscationError!usize {
        if (envelope.len < OVERHEAD) return error.BufferTooSmall;

        const nonce = envelope[0..NONCE_LEN];
        const ciphertext_len = envelope.len - OVERHEAD;
        const ciphertext = envelope[NONCE_LEN..][0..ciphertext_len];
        const tag = envelope[NONCE_LEN + ciphertext_len ..][0..TAG_LEN];

        if ((nonce[0] & 0x80) == 0) return error.InvalidNonce;
        if (output.len < ciphertext_len) return error.BufferTooSmall;

        const Aes256Gcm = crypto.aead.aes_gcm.Aes256Gcm;
        const gcm_nonce = nonce[0..12].*;

        Aes256Gcm.decrypt(output[0..ciphertext_len], ciphertext, tag.*, &[_]u8{}, gcm_nonce, key.key) catch {
            return error.AuthenticationFailed;
        };

        return ciphertext_len;
    }

    pub fn overhead() usize {
        return OVERHEAD;
    }
};

test "obfuscated envelope encrypt and decrypt" {
    const key = ObfuscationKey.fromKeyword("secret");
    const plaintext = "Hello, SSH/QUIC!";

    var encrypted: [1024]u8 = undefined;
    const enc_len = try ObfuscatedEnvelope.encrypt(plaintext, key, &encrypted);
    try std.testing.expect((encrypted[0] & 0x80) != 0);

    var decrypted: [1024]u8 = undefined;
    const dec_len = try ObfuscatedEnvelope.decrypt(encrypted[0..enc_len], key, &decrypted);
    try std.testing.expectEqualStrings(plaintext, decrypted[0..dec_len]);
}
