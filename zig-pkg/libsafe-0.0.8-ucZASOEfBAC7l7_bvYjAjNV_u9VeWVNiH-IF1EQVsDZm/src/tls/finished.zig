const std = @import("std");
const key_schedule_mod = @import("key_schedule.zig");
const keys_mod = @import("../crypto/keys.zig");

pub const FinishedError = error{
    VerificationFailed,
    OutOfMemory,
};

pub fn verify_finished_data(
    allocator: std.mem.Allocator,
    ks: *const key_schedule_mod.KeySchedule,
    server_handshake_secret: []const u8,
    peer_verify_data: []const u8,
) FinishedError!void {
    const hash_len = ks.hash_alg.digestLength();
    if (peer_verify_data.len != hash_len) return error.VerificationFailed;

    const finished_key = try allocator.alloc(u8, hash_len);
    defer {
        @memset(finished_key, 0);
        allocator.free(finished_key);
    }

    keys_mod.hkdfExpandLabel(server_handshake_secret, "finished", "", hash_len, ks.hash_alg, finished_key) catch return error.VerificationFailed;

    const expected = try allocator.alloc(u8, hash_len);
    defer {
        @memset(expected, 0);
        allocator.free(expected);
    }

    switch (ks.hash_alg) {
        .sha256 => {
            var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(finished_key);
            hmac.update(ks.transcript_hash);
            hmac.final(expected[0..32]);
        },
        .sha384 => {
            var hmac = std.crypto.auth.hmac.sha2.HmacSha384.init(finished_key);
            hmac.update(ks.transcript_hash);
            hmac.final(expected[0..48]);
        },
        .sha512 => {
            var hmac = std.crypto.auth.hmac.sha2.HmacSha512.init(finished_key);
            hmac.update(ks.transcript_hash);
            hmac.final(expected[0..64]);
        },
    }

    if (!std.mem.eql(u8, peer_verify_data, expected)) return error.VerificationFailed;
}

test "verify finished data accepts matching payload" {
    const allocator = std.testing.allocator;
    var ks = try key_schedule_mod.KeySchedule.init(allocator, .sha256);
    defer ks.deinit();
    ks.updateTranscript("transcript");

    const server_handshake_secret = [_]u8{0x33} ** 32;

    var finished_key: [32]u8 = undefined;
    try keys_mod.hkdfExpandLabel(
        &server_handshake_secret,
        "finished",
        "",
        finished_key.len,
        .sha256,
        &finished_key,
    );

    var verify_data: [32]u8 = undefined;
    var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(&finished_key);
    hmac.update(ks.transcript_hash);
    hmac.final(&verify_data);

    try verify_finished_data(allocator, &ks, &server_handshake_secret, &verify_data);
}

test "verify finished data rejects mismatched payload" {
    const allocator = std.testing.allocator;
    var ks = try key_schedule_mod.KeySchedule.init(allocator, .sha256);
    defer ks.deinit();
    ks.updateTranscript("transcript");

    const server_handshake_secret = [_]u8{0x44} ** 32;
    const wrong = [_]u8{0xAA} ** 32;

    try std.testing.expectError(error.VerificationFailed, verify_finished_data(allocator, &ks, &server_handshake_secret, &wrong));
}
