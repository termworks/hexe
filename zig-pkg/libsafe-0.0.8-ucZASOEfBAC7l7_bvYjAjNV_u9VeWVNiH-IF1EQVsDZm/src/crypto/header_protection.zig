const std = @import("std");
const crypto = std.crypto;
const aead = @import("aead.zig");

pub const HeaderProtectionError = error{
    InvalidKeyLength,
    InvalidSampleLength,
    ProtectionFailed,
};

const SAMPLE_LENGTH = 16;

pub const HeaderProtection = struct {
    algorithm: aead.AeadAlgorithm,
    hp_key: []const u8,

    pub fn init(algorithm: aead.AeadAlgorithm, hp_key: []const u8) HeaderProtectionError!HeaderProtection {
        const expected_len = algorithm.keyLength();
        if (hp_key.len != expected_len) return error.InvalidKeyLength;

        return .{
            .algorithm = algorithm,
            .hp_key = hp_key,
        };
    }

    pub fn generateMask(self: HeaderProtection, sample: []const u8) HeaderProtectionError![]const u8 {
        if (sample.len != SAMPLE_LENGTH) return error.InvalidSampleLength;

        return switch (self.algorithm) {
            .aes_128_gcm, .aes_256_gcm => self.generateMaskAes(sample),
            .chacha20_poly1305 => self.generateMaskChaCha(sample),
        };
    }

    fn generateMaskAes(self: HeaderProtection, sample: []const u8) HeaderProtectionError![]const u8 {
        var mask: [16]u8 = undefined;

        switch (self.algorithm) {
            .aes_128_gcm => {
                const key: [16]u8 = self.hp_key[0..16].*;
                const block_cipher = crypto.core.aes.Aes128.initEnc(key);
                block_cipher.encrypt(&mask, sample[0..16]);
            },
            .aes_256_gcm => {
                const key: [32]u8 = self.hp_key[0..32].*;
                const block_cipher = crypto.core.aes.Aes256.initEnc(key);
                block_cipher.encrypt(&mask, sample[0..16]);
            },
            else => unreachable,
        }

        const result = std.heap.page_allocator.alloc(u8, 16) catch return error.ProtectionFailed;
        @memcpy(result, &mask);
        return result;
    }

    fn generateMaskChaCha(self: HeaderProtection, sample: []const u8) HeaderProtectionError![]const u8 {
        const key: [32]u8 = self.hp_key[0..32].*;
        const nonce: [12]u8 = sample[0..12].*;

        var mask: [16]u8 = undefined;
        const zeros: [16]u8 = [_]u8{0} ** 16;
        const ChaCha20 = crypto.stream.chacha.ChaCha20IETF;
        ChaCha20.xor(&mask, &zeros, 0, key, nonce);

        const result = std.heap.page_allocator.alloc(u8, 16) catch return error.ProtectionFailed;
        @memcpy(result, &mask);
        return result;
    }

    pub fn protect(self: HeaderProtection, first_byte: *u8, pn_bytes: []u8, sample: []const u8) HeaderProtectionError!void {
        const mask = try self.generateMask(sample);
        defer std.heap.page_allocator.free(mask);

        const is_long_header = (first_byte.* & 0x80) != 0;
        if (is_long_header) {
            first_byte.* ^= mask[0] & 0x0F;
        } else {
            first_byte.* ^= mask[0] & 0x1F;
        }

        const pn_len = @min(pn_bytes.len, 4);
        for (0..pn_len) |i| {
            pn_bytes[i] ^= mask[1 + i];
        }
    }

    pub fn unprotect(self: HeaderProtection, first_byte: *u8, pn_bytes: []u8, sample: []const u8) HeaderProtectionError!void {
        try self.protect(first_byte, pn_bytes, sample);
    }

    pub fn sampleLength() usize {
        return SAMPLE_LENGTH;
    }
};

test "protect and unprotect short header" {
    const hp_key = "0123456789abcdef".*;
    const sample = "sample_data_here".*;

    const hp = try HeaderProtection.init(.aes_128_gcm, &hp_key);
    var first_byte: u8 = 0x40;
    var pn_bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78 };

    const orig_first = first_byte;
    const orig_pn = pn_bytes;

    try hp.protect(&first_byte, &pn_bytes, &sample);
    try hp.unprotect(&first_byte, &pn_bytes, &sample);

    try std.testing.expectEqual(orig_first, first_byte);
    try std.testing.expectEqualSlices(u8, &orig_pn, &pn_bytes);
}
