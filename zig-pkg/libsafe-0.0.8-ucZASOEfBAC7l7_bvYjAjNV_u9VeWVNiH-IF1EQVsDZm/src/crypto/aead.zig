const std = @import("std");
const crypto = std.crypto;

pub const AeadError = error{
    InvalidKeyLength,
    InvalidNonceLength,
    InvalidTagLength,
    EncryptionFailed,
    DecryptionFailed,
    AuthenticationFailed,
};

pub const AeadAlgorithm = enum {
    aes_128_gcm,
    aes_256_gcm,
    chacha20_poly1305,

    pub fn keyLength(self: AeadAlgorithm) usize {
        return switch (self) {
            .aes_128_gcm => 16,
            .aes_256_gcm => 32,
            .chacha20_poly1305 => 32,
        };
    }

    pub fn nonceLength(self: AeadAlgorithm) usize {
        _ = self;
        return 12;
    }

    pub fn tagLength(self: AeadAlgorithm) usize {
        _ = self;
        return 16;
    }
};

pub const AeadCipher = struct {
    algorithm: AeadAlgorithm,
    key: []const u8,

    pub fn init(algorithm: AeadAlgorithm, key: []const u8) AeadError!AeadCipher {
        if (key.len != algorithm.keyLength()) return error.InvalidKeyLength;
        return .{ .algorithm = algorithm, .key = key };
    }

    pub fn encrypt(
        self: AeadCipher,
        nonce: []const u8,
        plaintext: []const u8,
        associated_data: []const u8,
        output: []u8,
    ) AeadError!usize {
        if (nonce.len != self.algorithm.nonceLength()) return error.InvalidNonceLength;
        const tag_len = self.algorithm.tagLength();
        if (output.len < plaintext.len + tag_len) return error.EncryptionFailed;

        const ciphertext = output[0..plaintext.len];
        var tag_buf: [16]u8 = undefined;

        switch (self.algorithm) {
            .aes_128_gcm => {
                const Aes128Gcm = crypto.aead.aes_gcm.Aes128Gcm;
                const key: [16]u8 = self.key[0..16].*;
                const nonce_arr: [12]u8 = nonce[0..12].*;
                Aes128Gcm.encrypt(ciphertext, &tag_buf, plaintext, associated_data, nonce_arr, key);
            },
            .aes_256_gcm => {
                const Aes256Gcm = crypto.aead.aes_gcm.Aes256Gcm;
                const key: [32]u8 = self.key[0..32].*;
                const nonce_arr: [12]u8 = nonce[0..12].*;
                Aes256Gcm.encrypt(ciphertext, &tag_buf, plaintext, associated_data, nonce_arr, key);
            },
            .chacha20_poly1305 => {
                const ChaCha20Poly1305 = crypto.aead.chacha_poly.ChaCha20Poly1305;
                const key: [32]u8 = self.key[0..32].*;
                const nonce_arr: [12]u8 = nonce[0..12].*;
                ChaCha20Poly1305.encrypt(ciphertext, &tag_buf, plaintext, associated_data, nonce_arr, key);
            },
        }

        @memcpy(output[plaintext.len..][0..tag_len], tag_buf[0..tag_len]);
        return plaintext.len + tag_len;
    }

    pub fn decrypt(
        self: AeadCipher,
        nonce: []const u8,
        ciphertext_and_tag: []const u8,
        associated_data: []const u8,
        output: []u8,
    ) AeadError!usize {
        if (nonce.len != self.algorithm.nonceLength()) return error.InvalidNonceLength;
        const tag_len = self.algorithm.tagLength();
        if (ciphertext_and_tag.len < tag_len) return error.DecryptionFailed;

        const ciphertext_len = ciphertext_and_tag.len - tag_len;
        if (output.len < ciphertext_len) return error.DecryptionFailed;

        const ciphertext = ciphertext_and_tag[0..ciphertext_len];
        const tag = ciphertext_and_tag[ciphertext_len..][0..tag_len];

        switch (self.algorithm) {
            .aes_128_gcm => {
                const Aes128Gcm = crypto.aead.aes_gcm.Aes128Gcm;
                const key: [16]u8 = self.key[0..16].*;
                const nonce_arr: [12]u8 = nonce[0..12].*;
                const tag_arr: [16]u8 = tag[0..16].*;
                Aes128Gcm.decrypt(output[0..ciphertext_len], ciphertext, tag_arr, associated_data, nonce_arr, key) catch return error.AuthenticationFailed;
            },
            .aes_256_gcm => {
                const Aes256Gcm = crypto.aead.aes_gcm.Aes256Gcm;
                const key: [32]u8 = self.key[0..32].*;
                const nonce_arr: [12]u8 = nonce[0..12].*;
                const tag_arr: [16]u8 = tag[0..16].*;
                Aes256Gcm.decrypt(output[0..ciphertext_len], ciphertext, tag_arr, associated_data, nonce_arr, key) catch return error.AuthenticationFailed;
            },
            .chacha20_poly1305 => {
                const ChaCha20Poly1305 = crypto.aead.chacha_poly.ChaCha20Poly1305;
                const key: [32]u8 = self.key[0..32].*;
                const nonce_arr: [12]u8 = nonce[0..12].*;
                const tag_arr: [16]u8 = tag[0..16].*;
                ChaCha20Poly1305.decrypt(output[0..ciphertext_len], ciphertext, tag_arr, associated_data, nonce_arr, key) catch return error.AuthenticationFailed;
            },
        }

        return ciphertext_len;
    }
};

test "aead encrypt and decrypt" {
    const key = "0123456789abcdef".*;
    const nonce = "unique nonce".*;
    const plaintext = "Hello, libsafe!";
    const aad = "header";

    const cipher = try AeadCipher.init(.aes_128_gcm, &key);
    var encrypted: [128]u8 = undefined;
    const enc_len = try cipher.encrypt(&nonce, plaintext, aad, &encrypted);

    var out: [128]u8 = undefined;
    const dec_len = try cipher.decrypt(&nonce, encrypted[0..enc_len], aad, &out);
    try std.testing.expectEqualStrings(plaintext, out[0..dec_len]);
}
