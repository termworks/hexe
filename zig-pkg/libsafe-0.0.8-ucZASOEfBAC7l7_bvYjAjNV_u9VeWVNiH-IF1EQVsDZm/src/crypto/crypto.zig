const std = @import("std");
const aead_mod = @import("aead.zig");
const keys_mod = @import("keys.zig");
const header_protection = @import("header_protection.zig");

pub const CryptoError = error{
    InvalidMode,
    InvalidAlgorithm,
    KeyDerivationFailed,
    EncryptionFailed,
    DecryptionFailed,
    OutOfMemory,
} || aead_mod.AeadError || keys_mod.KeyError || header_protection.HeaderProtectionError;

pub const CryptoMode = enum {
    tls,
    ssh,

    pub fn toString(self: CryptoMode) []const u8 {
        return switch (self) {
            .tls => "TLS",
            .ssh => "SSH",
        };
    }
};

pub const EncryptionLevel = enum {
    initial,
    handshake,
    application,

    pub fn toString(self: EncryptionLevel) []const u8 {
        return switch (self) {
            .initial => "Initial",
            .handshake => "Handshake",
            .application => "Application",
        };
    }
};

pub const CipherSuite = struct {
    aead: aead_mod.AeadAlgorithm,
    hash: keys_mod.HashAlgorithm,

    pub const TLS_AES_128_GCM_SHA256 = CipherSuite{ .aead = .aes_128_gcm, .hash = .sha256 };
    pub const TLS_AES_256_GCM_SHA384 = CipherSuite{ .aead = .aes_256_gcm, .hash = .sha384 };
    pub const TLS_CHACHA20_POLY1305_SHA256 = CipherSuite{ .aead = .chacha20_poly1305, .hash = .sha256 };

    pub fn fromName(suite_name: []const u8) ?CipherSuite {
        if (std.mem.eql(u8, suite_name, "TLS_AES_128_GCM_SHA256")) {
            return TLS_AES_128_GCM_SHA256;
        } else if (std.mem.eql(u8, suite_name, "TLS_AES_256_GCM_SHA384")) {
            return TLS_AES_256_GCM_SHA384;
        } else if (std.mem.eql(u8, suite_name, "TLS_CHACHA20_POLY1305_SHA256")) {
            return TLS_CHACHA20_POLY1305_SHA256;
        }
        return null;
    }

    pub fn name(self: CipherSuite) []const u8 {
        if (self.aead == .aes_128_gcm and self.hash == .sha256) {
            return "TLS_AES_128_GCM_SHA256";
        } else if (self.aead == .aes_256_gcm and self.hash == .sha384) {
            return "TLS_AES_256_GCM_SHA384";
        } else if (self.aead == .chacha20_poly1305 and self.hash == .sha256) {
            return "TLS_CHACHA20_POLY1305_SHA256";
        }
        return "Unknown";
    }
};

pub const CryptoContext = struct {
    mode: CryptoMode,
    cipher_suite: CipherSuite,
    allocator: std.mem.Allocator,

    client_keys: ?keys_mod.KeyMaterial = null,
    server_keys: ?keys_mod.KeyMaterial = null,

    client_cipher: ?aead_mod.AeadCipher = null,
    server_cipher: ?aead_mod.AeadCipher = null,

    client_hp: ?header_protection.HeaderProtection = null,
    server_hp: ?header_protection.HeaderProtection = null,

    pub fn init(allocator: std.mem.Allocator, mode: CryptoMode, cipher_suite: CipherSuite) CryptoContext {
        return .{ .mode = mode, .cipher_suite = cipher_suite, .allocator = allocator };
    }

    pub fn installSecrets(self: *CryptoContext, client_secret: []const u8, server_secret: []const u8) CryptoError!void {
        var client_keys = try keys_mod.deriveKeyMaterial(
            self.allocator,
            client_secret,
            self.cipher_suite.aead,
            self.cipher_suite.hash,
        );
        errdefer client_keys.deinit();

        var server_keys = try keys_mod.deriveKeyMaterial(
            self.allocator,
            server_secret,
            self.cipher_suite.aead,
            self.cipher_suite.hash,
        );
        errdefer server_keys.deinit();

        const client_cipher = try aead_mod.AeadCipher.init(self.cipher_suite.aead, client_keys.key);
        const server_cipher = try aead_mod.AeadCipher.init(self.cipher_suite.aead, server_keys.key);

        const client_hp = try header_protection.HeaderProtection.init(self.cipher_suite.aead, client_keys.hp_key);
        const server_hp = try header_protection.HeaderProtection.init(self.cipher_suite.aead, server_keys.hp_key);

        if (self.client_keys) |*old| old.deinit();
        if (self.server_keys) |*old| old.deinit();

        self.client_keys = client_keys;
        self.server_keys = server_keys;
        self.client_cipher = client_cipher;
        self.server_cipher = server_cipher;
        self.client_hp = client_hp;
        self.server_hp = server_hp;
    }

    pub fn encryptClient(self: *CryptoContext, nonce: []const u8, plaintext: []const u8, associated_data: []const u8, output: []u8) CryptoError!usize {
        if (self.client_cipher == null) return error.EncryptionFailed;
        return self.client_cipher.?.encrypt(nonce, plaintext, associated_data, output) catch error.EncryptionFailed;
    }

    pub fn decryptClient(self: *CryptoContext, nonce: []const u8, ciphertext_and_tag: []const u8, associated_data: []const u8, output: []u8) CryptoError!usize {
        if (self.server_cipher == null) return error.DecryptionFailed;
        return self.server_cipher.?.decrypt(nonce, ciphertext_and_tag, associated_data, output) catch error.DecryptionFailed;
    }

    pub fn encryptServer(self: *CryptoContext, nonce: []const u8, plaintext: []const u8, associated_data: []const u8, output: []u8) CryptoError!usize {
        if (self.server_cipher == null) return error.EncryptionFailed;
        return self.server_cipher.?.encrypt(nonce, plaintext, associated_data, output) catch error.EncryptionFailed;
    }

    pub fn decryptServer(self: *CryptoContext, nonce: []const u8, ciphertext_and_tag: []const u8, associated_data: []const u8, output: []u8) CryptoError!usize {
        if (self.client_cipher == null) return error.DecryptionFailed;
        return self.client_cipher.?.decrypt(nonce, ciphertext_and_tag, associated_data, output) catch error.DecryptionFailed;
    }

    pub fn protectHeaderClient(self: *CryptoContext, first_byte: *u8, pn_bytes: []u8, sample: []const u8) CryptoError!void {
        if (self.client_hp == null) return error.EncryptionFailed;
        try self.client_hp.?.protect(first_byte, pn_bytes, sample);
    }

    pub fn unprotectHeaderClient(self: *CryptoContext, first_byte: *u8, pn_bytes: []u8, sample: []const u8) CryptoError!void {
        if (self.server_hp == null) return error.DecryptionFailed;
        try self.server_hp.?.unprotect(first_byte, pn_bytes, sample);
    }

    pub fn protectHeaderServer(self: *CryptoContext, first_byte: *u8, pn_bytes: []u8, sample: []const u8) CryptoError!void {
        if (self.server_hp == null) return error.EncryptionFailed;
        try self.server_hp.?.protect(first_byte, pn_bytes, sample);
    }

    pub fn unprotectHeaderServer(self: *CryptoContext, first_byte: *u8, pn_bytes: []u8, sample: []const u8) CryptoError!void {
        if (self.client_hp == null) return error.DecryptionFailed;
        try self.client_hp.?.unprotect(first_byte, pn_bytes, sample);
    }

    pub fn deinit(self: *CryptoContext) void {
        if (self.client_keys) |*keys| keys.deinit();
        if (self.server_keys) |*keys| keys.deinit();
    }
};

test "install secrets and derive keys" {
    const allocator = std.testing.allocator;
    var ctx = CryptoContext.init(allocator, .tls, CipherSuite.TLS_AES_128_GCM_SHA256);
    defer ctx.deinit();

    const client_secret = "client-initial-secret-32-bytes!!".*;
    const server_secret = "server-initial-secret-32-bytes!!".*;

    try ctx.installSecrets(&client_secret, &server_secret);
    try std.testing.expect(ctx.client_keys != null);
    try std.testing.expect(ctx.server_keys != null);
}
