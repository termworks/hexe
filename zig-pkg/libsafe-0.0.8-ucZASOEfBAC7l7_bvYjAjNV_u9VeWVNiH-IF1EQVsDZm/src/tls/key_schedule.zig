const std = @import("std");
const crypto = std.crypto;
const keys_mod = @import("../crypto/keys.zig");

pub const KeyScheduleError = error{
    InvalidSecret,
    InvalidSecretLength,
    DerivationFailed,
    OutOfMemory,
};

pub const HashAlgorithm = keys_mod.HashAlgorithm;

pub const KeySchedule = struct {
    hash_alg: HashAlgorithm,
    transcript_hash: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, hash_alg: HashAlgorithm) !KeySchedule {
        const hash_len = hash_alg.digestLength();
        const transcript = try allocator.alloc(u8, hash_len);
        @memset(transcript, 0);

        return .{
            .hash_alg = hash_alg,
            .transcript_hash = transcript,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *KeySchedule) void {
        @memset(self.transcript_hash, 0);
        self.allocator.free(self.transcript_hash);
    }

    pub fn updateTranscript(self: *KeySchedule, message: []const u8) void {
        switch (self.hash_alg) {
            .sha256 => {
                var hasher = crypto.hash.sha2.Sha256.init(.{});
                hasher.update(self.transcript_hash);
                hasher.update(message);
                hasher.final(self.transcript_hash[0..32]);
            },
            .sha384 => {
                var hasher = crypto.hash.sha2.Sha384.init(.{});
                hasher.update(self.transcript_hash);
                hasher.update(message);
                hasher.final(self.transcript_hash[0..48]);
            },
            .sha512 => {
                var hasher = crypto.hash.sha2.Sha512.init(.{});
                hasher.update(self.transcript_hash);
                hasher.update(message);
                hasher.final(self.transcript_hash[0..64]);
            },
        }
    }

    pub fn deriveEarlySecret(self: *KeySchedule, psk: ?[]const u8) KeyScheduleError![]u8 {
        const hash_len = self.hash_alg.digestLength();
        const salt = try self.allocator.alloc(u8, hash_len);
        defer self.allocator.free(salt);
        @memset(salt, 0);

        const ikm = if (psk) |p| p else blk: {
            const zeros = try self.allocator.alloc(u8, hash_len);
            @memset(zeros, 0);
            break :blk zeros;
        };
        defer if (psk == null) self.allocator.free(ikm);

        return try self.hkdfExtract(salt, ikm);
    }

    pub fn deriveHandshakeSecret(self: *KeySchedule, early_secret: []const u8, ecdhe: []const u8) KeyScheduleError![]u8 {
        const derived = try self.deriveSecret(early_secret, "derived", &[_]u8{});
        defer self.allocator.free(derived);
        return try self.hkdfExtract(derived, ecdhe);
    }

    pub fn deriveMasterSecret(self: *KeySchedule, handshake_secret: []const u8) KeyScheduleError![]u8 {
        const derived = try self.deriveSecret(handshake_secret, "derived", &[_]u8{});
        defer self.allocator.free(derived);

        const hash_len = self.hash_alg.digestLength();
        const zeros = try self.allocator.alloc(u8, hash_len);
        defer self.allocator.free(zeros);
        @memset(zeros, 0);
        return try self.hkdfExtract(derived, zeros);
    }

    pub fn deriveHandshakeTrafficSecrets(self: *KeySchedule, handshake_secret: []const u8) KeyScheduleError!struct { client: []u8, server: []u8 } {
        const client = try self.deriveSecret(handshake_secret, "c hs traffic", self.transcript_hash);
        errdefer self.allocator.free(client);
        const server = try self.deriveSecret(handshake_secret, "s hs traffic", self.transcript_hash);
        return .{ .client = client, .server = server };
    }

    pub fn deriveApplicationTrafficSecrets(self: *KeySchedule, master_secret: []const u8) KeyScheduleError!struct { client: []u8, server: []u8 } {
        const client = try self.deriveSecret(master_secret, "c ap traffic", self.transcript_hash);
        errdefer self.allocator.free(client);
        const server = try self.deriveSecret(master_secret, "s ap traffic", self.transcript_hash);
        return .{ .client = client, .server = server };
    }

    fn deriveSecret(self: *KeySchedule, secret: []const u8, label: []const u8, context: []const u8) KeyScheduleError![]u8 {
        const hash_len = self.hash_alg.digestLength();
        const output = try self.allocator.alloc(u8, hash_len);
        errdefer self.allocator.free(output);
        try keys_mod.hkdfExpandLabel(secret, label, context, hash_len, self.hash_alg, output);
        return output;
    }

    fn hkdfExtract(self: *KeySchedule, salt: []const u8, ikm: []const u8) KeyScheduleError![]u8 {
        const hash_len = self.hash_alg.digestLength();
        const prk = try self.allocator.alloc(u8, hash_len);

        switch (self.hash_alg) {
            .sha256 => {
                var hmac = crypto.auth.hmac.sha2.HmacSha256.init(salt);
                hmac.update(ikm);
                hmac.final(prk[0..32]);
            },
            .sha384 => {
                var hmac = crypto.auth.hmac.sha2.HmacSha384.init(salt);
                hmac.update(ikm);
                hmac.final(prk[0..48]);
            },
            .sha512 => {
                var hmac = crypto.auth.hmac.sha2.HmacSha512.init(salt);
                hmac.update(ikm);
                hmac.final(prk[0..64]);
            },
        }

        return prk;
    }
};

test "key schedule basic derivation" {
    const allocator = std.testing.allocator;
    var ks = try KeySchedule.init(allocator, .sha256);
    defer ks.deinit();

    const early = try ks.deriveEarlySecret(null);
    defer allocator.free(early);
    const hs = try ks.deriveHandshakeSecret(early, "shared");
    defer allocator.free(hs);
    const ms = try ks.deriveMasterSecret(hs);
    defer allocator.free(ms);

    try std.testing.expectEqual(@as(usize, 32), ms.len);
}

test "key schedule transcript update is deterministic" {
    const allocator = std.testing.allocator;

    var a = try KeySchedule.init(allocator, .sha256);
    defer a.deinit();
    var b = try KeySchedule.init(allocator, .sha256);
    defer b.deinit();

    a.updateTranscript("client-hello");
    a.updateTranscript("server-hello");

    b.updateTranscript("client-hello");
    b.updateTranscript("server-hello");

    try std.testing.expectEqualSlices(u8, a.transcript_hash, b.transcript_hash);
}

test "key schedule derives expected secret lengths for hash variants" {
    const allocator = std.testing.allocator;

    const variants = [_]HashAlgorithm{ .sha256, .sha384, .sha512 };
    for (variants) |hash_alg| {
        var ks = try KeySchedule.init(allocator, hash_alg);
        defer ks.deinit();

        const early = try ks.deriveEarlySecret(null);
        defer allocator.free(early);
        const hs = try ks.deriveHandshakeSecret(early, "shared");
        defer allocator.free(hs);
        const ms = try ks.deriveMasterSecret(hs);
        defer allocator.free(ms);

        const expected_len = hash_alg.digestLength();
        try std.testing.expectEqual(expected_len, early.len);
        try std.testing.expectEqual(expected_len, hs.len);
        try std.testing.expectEqual(expected_len, ms.len);
    }
}

test "key schedule traffic secrets depend on transcript" {
    const allocator = std.testing.allocator;

    var a = try KeySchedule.init(allocator, .sha256);
    defer a.deinit();
    var b = try KeySchedule.init(allocator, .sha256);
    defer b.deinit();

    const early_a = try a.deriveEarlySecret(null);
    defer allocator.free(early_a);
    const hs_a = try a.deriveHandshakeSecret(early_a, "shared");
    defer allocator.free(hs_a);

    const early_b = try b.deriveEarlySecret(null);
    defer allocator.free(early_b);
    const hs_b = try b.deriveHandshakeSecret(early_b, "shared");
    defer allocator.free(hs_b);

    a.updateTranscript("transcript-a");
    b.updateTranscript("transcript-b");

    const a_secrets = try a.deriveHandshakeTrafficSecrets(hs_a);
    defer {
        @memset(a_secrets.client, 0);
        allocator.free(a_secrets.client);
        @memset(a_secrets.server, 0);
        allocator.free(a_secrets.server);
    }

    const b_secrets = try b.deriveHandshakeTrafficSecrets(hs_b);
    defer {
        @memset(b_secrets.client, 0);
        allocator.free(b_secrets.client);
        @memset(b_secrets.server, 0);
        allocator.free(b_secrets.server);
    }

    try std.testing.expect(!std.mem.eql(u8, a_secrets.client, b_secrets.client));
    try std.testing.expect(!std.mem.eql(u8, a_secrets.server, b_secrets.server));
}

test "key schedule early secret changes with psk" {
    const allocator = std.testing.allocator;

    var ks = try KeySchedule.init(allocator, .sha256);
    defer ks.deinit();

    const no_psk = try ks.deriveEarlySecret(null);
    defer allocator.free(no_psk);

    const with_psk = try ks.deriveEarlySecret("psk-material");
    defer allocator.free(with_psk);

    try std.testing.expect(!std.mem.eql(u8, no_psk, with_psk));
}

test "key schedule traffic secret derivation is deterministic" {
    const allocator = std.testing.allocator;

    var a = try KeySchedule.init(allocator, .sha256);
    defer a.deinit();
    var b = try KeySchedule.init(allocator, .sha256);
    defer b.deinit();

    const early_a = try a.deriveEarlySecret("psk");
    defer allocator.free(early_a);
    const hs_a = try a.deriveHandshakeSecret(early_a, "shared");
    defer allocator.free(hs_a);
    const ms_a = try a.deriveMasterSecret(hs_a);
    defer allocator.free(ms_a);

    const early_b = try b.deriveEarlySecret("psk");
    defer allocator.free(early_b);
    const hs_b = try b.deriveHandshakeSecret(early_b, "shared");
    defer allocator.free(hs_b);
    const ms_b = try b.deriveMasterSecret(hs_b);
    defer allocator.free(ms_b);

    a.updateTranscript("same-transcript");
    b.updateTranscript("same-transcript");

    const hs_secrets_a = try a.deriveHandshakeTrafficSecrets(hs_a);
    defer {
        @memset(hs_secrets_a.client, 0);
        allocator.free(hs_secrets_a.client);
        @memset(hs_secrets_a.server, 0);
        allocator.free(hs_secrets_a.server);
    }
    const hs_secrets_b = try b.deriveHandshakeTrafficSecrets(hs_b);
    defer {
        @memset(hs_secrets_b.client, 0);
        allocator.free(hs_secrets_b.client);
        @memset(hs_secrets_b.server, 0);
        allocator.free(hs_secrets_b.server);
    }

    const app_secrets_a = try a.deriveApplicationTrafficSecrets(ms_a);
    defer {
        @memset(app_secrets_a.client, 0);
        allocator.free(app_secrets_a.client);
        @memset(app_secrets_a.server, 0);
        allocator.free(app_secrets_a.server);
    }
    const app_secrets_b = try b.deriveApplicationTrafficSecrets(ms_b);
    defer {
        @memset(app_secrets_b.client, 0);
        allocator.free(app_secrets_b.client);
        @memset(app_secrets_b.server, 0);
        allocator.free(app_secrets_b.server);
    }

    try std.testing.expectEqualSlices(u8, hs_secrets_a.client, hs_secrets_b.client);
    try std.testing.expectEqualSlices(u8, hs_secrets_a.server, hs_secrets_b.server);
    try std.testing.expectEqualSlices(u8, app_secrets_a.client, app_secrets_b.client);
    try std.testing.expectEqualSlices(u8, app_secrets_a.server, app_secrets_b.server);
}
