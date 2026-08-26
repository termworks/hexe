const std = @import("std");
const handshake_mod = @import("handshake.zig");
const key_schedule_mod = @import("key_schedule.zig");

pub const PolicyError = error{
    UnsupportedCipherSuite,
};

pub fn hash_algorithm_for_cipher_suite(cipher_suite: u16) PolicyError!key_schedule_mod.HashAlgorithm {
    return switch (cipher_suite) {
        handshake_mod.TLS_AES_128_GCM_SHA256,
        handshake_mod.TLS_CHACHA20_POLY1305_SHA256,
        => .sha256,
        handshake_mod.TLS_AES_256_GCM_SHA384 => .sha384,
        else => error.UnsupportedCipherSuite,
    };
}

pub fn select_server_cipher_suite(offered_cipher_suites: []const u8) ?u16 {
    if ((offered_cipher_suites.len & 1) != 0) return null;

    const preferred = [_]u16{
        handshake_mod.TLS_AES_128_GCM_SHA256,
        handshake_mod.TLS_AES_256_GCM_SHA384,
        handshake_mod.TLS_CHACHA20_POLY1305_SHA256,
    };

    for (preferred) |candidate| {
        var i: usize = 0;
        while (i + 1 < offered_cipher_suites.len) : (i += 2) {
            const offered: u16 = (@as(u16, offered_cipher_suites[i]) << 8) | offered_cipher_suites[i + 1];
            if (offered == candidate) return candidate;
        }
    }
    return null;
}

test "hash algorithm mapping follows cipher suite" {
    try std.testing.expectEqual(
        key_schedule_mod.HashAlgorithm.sha256,
        try hash_algorithm_for_cipher_suite(handshake_mod.TLS_AES_128_GCM_SHA256),
    );
    try std.testing.expectEqual(
        key_schedule_mod.HashAlgorithm.sha256,
        try hash_algorithm_for_cipher_suite(handshake_mod.TLS_CHACHA20_POLY1305_SHA256),
    );
    try std.testing.expectEqual(
        key_schedule_mod.HashAlgorithm.sha384,
        try hash_algorithm_for_cipher_suite(handshake_mod.TLS_AES_256_GCM_SHA384),
    );
    try std.testing.expectError(error.UnsupportedCipherSuite, hash_algorithm_for_cipher_suite(0xDEAD));
}

test "server cipher suite selection follows preferred order" {
    const offered = [_]u8{
        @intCast((handshake_mod.TLS_CHACHA20_POLY1305_SHA256 >> 8) & 0xFF),
        @intCast(handshake_mod.TLS_CHACHA20_POLY1305_SHA256 & 0xFF),
        @intCast((handshake_mod.TLS_AES_128_GCM_SHA256 >> 8) & 0xFF),
        @intCast(handshake_mod.TLS_AES_128_GCM_SHA256 & 0xFF),
    };
    try std.testing.expectEqual(handshake_mod.TLS_AES_128_GCM_SHA256, select_server_cipher_suite(&offered).?);
}
