const std = @import("std");
const crypto = std.crypto;
const aead = @import("aead.zig");

pub const KeyError = error{
    InvalidSecretLength,
    DerivationFailed,
    OutOfMemory,
};

pub const HashAlgorithm = enum {
    sha256,
    sha384,
    sha512,

    pub fn digestLength(self: HashAlgorithm) usize {
        return switch (self) {
            .sha256 => 32,
            .sha384 => 48,
            .sha512 => 64,
        };
    }
};

pub const KeyMaterial = struct {
    key: []u8,
    iv: []u8,
    hp_key: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *KeyMaterial) void {
        @memset(self.key, 0);
        @memset(self.iv, 0);
        @memset(self.hp_key, 0);

        self.allocator.free(self.key);
        self.allocator.free(self.iv);
        self.allocator.free(self.hp_key);
    }
};

pub fn deriveKeyMaterial(
    allocator: std.mem.Allocator,
    secret: []const u8,
    algorithm: aead.AeadAlgorithm,
    hash_alg: HashAlgorithm,
) KeyError!KeyMaterial {
    const key_len = algorithm.keyLength();
    const iv_len = algorithm.nonceLength();
    const hp_len = key_len;

    var material = KeyMaterial{
        .key = try allocator.alloc(u8, key_len),
        .iv = try allocator.alloc(u8, iv_len),
        .hp_key = try allocator.alloc(u8, hp_len),
        .allocator = allocator,
    };
    errdefer material.deinit();

    try hkdfExpandLabel(secret, "quic key", "", key_len, hash_alg, material.key);
    try hkdfExpandLabel(secret, "quic iv", "", iv_len, hash_alg, material.iv);
    try hkdfExpandLabel(secret, "quic hp", "", hp_len, hash_alg, material.hp_key);

    return material;
}

pub fn hkdfExpandLabel(
    secret: []const u8,
    label: []const u8,
    context: []const u8,
    length: usize,
    hash_alg: HashAlgorithm,
    output: []u8,
) KeyError!void {
    if (output.len < length) return error.DerivationFailed;

    var hkdf_label: std.ArrayList(u8) = .{};
    defer hkdf_label.deinit(std.heap.page_allocator);

    try hkdf_label.append(std.heap.page_allocator, @intCast((length >> 8) & 0xFF));
    try hkdf_label.append(std.heap.page_allocator, @intCast(length & 0xFF));

    const prefix = "tls13 ";
    const full_label_len: u8 = @intCast(prefix.len + label.len);
    try hkdf_label.append(std.heap.page_allocator, full_label_len);
    try hkdf_label.appendSlice(std.heap.page_allocator, prefix);
    try hkdf_label.appendSlice(std.heap.page_allocator, label);

    const context_len: u8 = @intCast(context.len);
    try hkdf_label.append(std.heap.page_allocator, context_len);
    if (context.len > 0) {
        try hkdf_label.appendSlice(std.heap.page_allocator, context);
    }

    try hkdfExpand(secret, hkdf_label.items, length, hash_alg, output);
}

fn hkdfExpand(
    prk: []const u8,
    info: []const u8,
    length: usize,
    hash_alg: HashAlgorithm,
    output: []u8,
) KeyError!void {
    if (output.len < length) return error.DerivationFailed;

    const hash_len = hash_alg.digestLength();
    const n = (length + hash_len - 1) / hash_len;
    if (n > 255) return error.DerivationFailed;

    var pos: usize = 0;
    var t_prev: [64]u8 = undefined;
    var t_prev_len: usize = 0;

    var i: u8 = 1;
    while (i <= n) : (i += 1) {
        var t: [64]u8 = undefined;

        switch (hash_alg) {
            .sha256 => {
                var hmac = crypto.auth.hmac.sha2.HmacSha256.init(prk);
                if (t_prev_len > 0) hmac.update(t_prev[0..t_prev_len]);
                hmac.update(info);
                hmac.update(&[_]u8{i});
                hmac.final(t[0..32]);
                t_prev_len = 32;
            },
            .sha384 => {
                var hmac = crypto.auth.hmac.sha2.HmacSha384.init(prk);
                if (t_prev_len > 0) hmac.update(t_prev[0..t_prev_len]);
                hmac.update(info);
                hmac.update(&[_]u8{i});
                hmac.final(t[0..48]);
                t_prev_len = 48;
            },
            .sha512 => {
                var hmac = crypto.auth.hmac.sha2.HmacSha512.init(prk);
                if (t_prev_len > 0) hmac.update(t_prev[0..t_prev_len]);
                hmac.update(info);
                hmac.update(&[_]u8{i});
                hmac.final(t[0..64]);
                t_prev_len = 64;
            },
        }

        const copy_len = @min(t_prev_len, length - pos);
        @memcpy(output[pos..][0..copy_len], t[0..copy_len]);
        pos += copy_len;
        @memcpy(t_prev[0..t_prev_len], t[0..t_prev_len]);
        if (pos >= length) break;
    }
}

pub fn updateSecret(
    allocator: std.mem.Allocator,
    old_secret: []const u8,
    hash_alg: HashAlgorithm,
) KeyError![]u8 {
    const secret_len = hash_alg.digestLength();
    const new_secret = try allocator.alloc(u8, secret_len);
    errdefer allocator.free(new_secret);
    try hkdfExpandLabel(old_secret, "quic ku", "", secret_len, hash_alg, new_secret);
    return new_secret;
}

test "derive key material for aes 128" {
    const allocator = std.testing.allocator;
    const secret = "test-secret-for-aes-128-gcm-key".*;

    var material = try deriveKeyMaterial(allocator, &secret, .aes_128_gcm, .sha256);
    defer material.deinit();

    try std.testing.expectEqual(@as(usize, 16), material.key.len);
    try std.testing.expectEqual(@as(usize, 12), material.iv.len);
    try std.testing.expectEqual(@as(usize, 16), material.hp_key.len);
}
