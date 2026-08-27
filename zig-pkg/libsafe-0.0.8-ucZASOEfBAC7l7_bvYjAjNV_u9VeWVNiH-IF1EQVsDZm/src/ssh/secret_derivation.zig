const std = @import("std");
const crypto = std.crypto;
const kex_methods = @import("kex_methods.zig");

pub const DerivationError = error{
    InvalidHashAlgorithm,
    DerivationFailed,
    InputTooLarge,
    OutOfMemory,
};

pub const MAX_SSH_MPINT_LENGTH: usize = 1024 * 1024;
pub const MAX_SSH_STRING_LENGTH: usize = 1024 * 1024;

pub const QuicSecrets = struct {
    client_initial_secret: [32]u8,
    server_initial_secret: [32]u8,
    hash_algorithm: kex_methods.HashAlgorithm,

    pub fn zeroize(self: *QuicSecrets) void {
        @memset(&self.client_initial_secret, 0);
        @memset(&self.server_initial_secret, 0);
    }
};

pub fn deriveQuicSecrets(
    shared_secret: []const u8,
    exchange_hash: []const u8,
    hash_algorithm: kex_methods.HashAlgorithm,
) DerivationError!QuicSecrets {
    var secrets = QuicSecrets{
        .client_initial_secret = undefined,
        .server_initial_secret = undefined,
        .hash_algorithm = hash_algorithm,
    };

    const client_label = "client";
    switch (hash_algorithm) {
        .sha256 => {
            var client_hmac = crypto.auth.hmac.sha2.HmacSha256.init(shared_secret);
            client_hmac.update(client_label);
            client_hmac.update(exchange_hash);
            client_hmac.final(&secrets.client_initial_secret);
        },
        .sha384 => {
            var client_hmac = crypto.auth.hmac.sha2.HmacSha384.init(shared_secret);
            client_hmac.update(client_label);
            client_hmac.update(exchange_hash);
            var client_digest: [48]u8 = undefined;
            defer @memset(&client_digest, 0);
            client_hmac.final(&client_digest);
            @memcpy(&secrets.client_initial_secret, client_digest[0..32]);
        },
        .sha512 => {
            var client_hmac = crypto.auth.hmac.sha2.HmacSha512.init(shared_secret);
            client_hmac.update(client_label);
            client_hmac.update(exchange_hash);
            var client_digest: [64]u8 = undefined;
            defer @memset(&client_digest, 0);
            client_hmac.final(&client_digest);
            @memcpy(&secrets.client_initial_secret, client_digest[0..32]);
        },
    }

    const server_label = "server";
    switch (hash_algorithm) {
        .sha256 => {
            var server_hmac = crypto.auth.hmac.sha2.HmacSha256.init(shared_secret);
            server_hmac.update(server_label);
            server_hmac.update(exchange_hash);
            server_hmac.final(&secrets.server_initial_secret);
        },
        .sha384 => {
            var server_hmac = crypto.auth.hmac.sha2.HmacSha384.init(shared_secret);
            server_hmac.update(server_label);
            server_hmac.update(exchange_hash);
            var server_digest: [48]u8 = undefined;
            defer @memset(&server_digest, 0);
            server_hmac.final(&server_digest);
            @memcpy(&secrets.server_initial_secret, server_digest[0..32]);
        },
        .sha512 => {
            var server_hmac = crypto.auth.hmac.sha2.HmacSha512.init(shared_secret);
            server_hmac.update(server_label);
            server_hmac.update(exchange_hash);
            var server_digest: [64]u8 = undefined;
            defer @memset(&server_digest, 0);
            server_hmac.final(&server_digest);
            @memcpy(&secrets.server_initial_secret, server_digest[0..32]);
        },
    }

    return secrets;
}

/// Derive SSH/QUIC client and server secrets using the wire-compatible
/// secret_data construction used by liblink.
///
/// secret_data = mpint(K) || string(H)
/// client = HMAC-SHA256(secret_data, "ssh/quic client")
/// server = HMAC-SHA256(secret_data, "ssh/quic server")
pub fn deriveSshQuicSecrets(
    allocator: std.mem.Allocator,
    shared_secret_k: []const u8,
    exchange_hash_h: []const u8,
) DerivationError!QuicSecrets {
    const secret_data = try encodeSshSecretData(allocator, shared_secret_k, exchange_hash_h);
    defer {
        @memset(secret_data, 0);
        allocator.free(secret_data);
    }

    var secrets = QuicSecrets{
        .client_initial_secret = undefined,
        .server_initial_secret = undefined,
        .hash_algorithm = .sha256,
    };

    const client_label = "ssh/quic client";
    var client_hmac = crypto.auth.hmac.sha2.HmacSha256.init(secret_data);
    client_hmac.update(client_label);
    client_hmac.final(&secrets.client_initial_secret);

    const server_label = "ssh/quic server";
    var server_hmac = crypto.auth.hmac.sha2.HmacSha256.init(secret_data);
    server_hmac.update(server_label);
    server_hmac.final(&secrets.server_initial_secret);

    return secrets;
}

/// Derive a deterministic exporter secret for SSH-over-QUIC subprotocol keying.
///
/// The output is fixed at 32 bytes:
/// exporter = HMAC-SHA256(secret_data, "ssh/quic exporter" || string(label) || string(context))
/// where secret_data = mpint(K) || string(H).
pub fn deriveSshQuicExporterSecret(
    allocator: std.mem.Allocator,
    shared_secret_k: []const u8,
    exchange_hash_h: []const u8,
    label: []const u8,
    context: []const u8,
) DerivationError![32]u8 {
    const secret_data = try encodeSshSecretData(allocator, shared_secret_k, exchange_hash_h);
    defer {
        @memset(secret_data, 0);
        allocator.free(secret_data);
    }

    const message = try encodeExporterMessage(allocator, label, context);
    defer {
        @memset(message, 0);
        allocator.free(message);
    }

    var out: [32]u8 = undefined;
    var hmac = crypto.auth.hmac.sha2.HmacSha256.init(secret_data);
    hmac.update(message);
    hmac.final(&out);
    return out;
}

fn encodeSshSecretData(
    allocator: std.mem.Allocator,
    shared_secret_k: []const u8,
    exchange_hash_h: []const u8,
) DerivationError![]u8 {
    if (exchange_hash_h.len > MAX_SSH_STRING_LENGTH) return error.InputTooLarge;

    const encoded_k = try encodeCanonicalPositiveMpint(allocator, shared_secret_k);
    defer {
        @memset(encoded_k, 0);
        allocator.free(encoded_k);
    }

    const k_len = encoded_k.len;
    const h_len = exchange_hash_h.len;
    const total_len = 4 + k_len + 4 + h_len;

    const out = try allocator.alloc(u8, total_len);
    errdefer allocator.free(out);

    std.mem.writeInt(u32, out[0..4], @intCast(k_len), .big);
    @memcpy(out[4 .. 4 + encoded_k.len], encoded_k);

    const h_offset = 4 + k_len;
    std.mem.writeInt(u32, out[h_offset..][0..4], @intCast(h_len), .big);
    @memcpy(out[h_offset + 4 .. h_offset + 4 + h_len], exchange_hash_h);

    return out;
}

fn encodeCanonicalPositiveMpint(
    allocator: std.mem.Allocator,
    raw: []const u8,
) DerivationError![]u8 {
    if (raw.len > MAX_SSH_MPINT_LENGTH) return error.InputTooLarge;

    var first_non_zero: usize = 0;
    while (first_non_zero < raw.len and raw[first_non_zero] == 0) {
        first_non_zero += 1;
    }

    if (first_non_zero == raw.len) {
        return allocator.alloc(u8, 0);
    }

    const magnitude = raw[first_non_zero..];
    const needs_padding = (magnitude[0] & 0x80) != 0;
    const encoded_len = magnitude.len + @as(usize, if (needs_padding) 1 else 0);
    if (encoded_len > MAX_SSH_MPINT_LENGTH) return error.InputTooLarge;

    const out = try allocator.alloc(u8, encoded_len);
    errdefer allocator.free(out);

    if (needs_padding) {
        out[0] = 0;
        @memcpy(out[1..], magnitude);
    } else {
        @memcpy(out, magnitude);
    }

    return out;
}

fn encodeExporterMessage(
    allocator: std.mem.Allocator,
    label: []const u8,
    context: []const u8,
) DerivationError![]u8 {
    if (label.len > std.math.maxInt(u32)) return error.DerivationFailed;
    if (context.len > std.math.maxInt(u32)) return error.DerivationFailed;

    const prefix = "ssh/quic exporter";
    const total_len = prefix.len + 4 + label.len + 4 + context.len;
    const out = try allocator.alloc(u8, total_len);
    errdefer allocator.free(out);

    var offset: usize = 0;
    @memcpy(out[offset .. offset + prefix.len], prefix);
    offset += prefix.len;

    std.mem.writeInt(u32, out[offset..][0..4], @intCast(label.len), .big);
    offset += 4;
    @memcpy(out[offset .. offset + label.len], label);
    offset += label.len;

    std.mem.writeInt(u32, out[offset..][0..4], @intCast(context.len), .big);
    offset += 4;
    @memcpy(out[offset .. offset + context.len], context);

    return out;
}

pub fn expandLabel(
    secret: []const u8,
    label: []const u8,
    context: []const u8,
    length: usize,
    hash_algorithm: kex_methods.HashAlgorithm,
    output: []u8,
) DerivationError!void {
    if (output.len < length) return error.DerivationFailed;
    if (length > 0xFFFF) return error.DerivationFailed;

    const length_be = [2]u8{ @intCast((length >> 8) & 0xFF), @intCast(length & 0xFF) };
    const prefix = "tls13 ";
    if (prefix.len + label.len > 255) return error.DerivationFailed;
    if (context.len > 255) return error.DerivationFailed;

    const full_label_len: u8 = @intCast(prefix.len + label.len);
    const context_len: u8 = @intCast(context.len);
    const counter = [_]u8{0x01};

    switch (hash_algorithm) {
        .sha256 => {
            var hmac = crypto.auth.hmac.sha2.HmacSha256.init(secret);
            hmac.update(&length_be);
            hmac.update(&[_]u8{full_label_len});
            hmac.update(prefix);
            hmac.update(label);
            hmac.update(&[_]u8{context_len});
            if (context.len > 0) hmac.update(context);
            hmac.update(&counter);
            var digest: [32]u8 = undefined;
            defer @memset(&digest, 0);
            hmac.final(&digest);
            @memcpy(output[0..@min(length, 32)], digest[0..@min(length, 32)]);
        },
        .sha384 => {
            var hmac = crypto.auth.hmac.sha2.HmacSha384.init(secret);
            hmac.update(&length_be);
            hmac.update(&[_]u8{full_label_len});
            hmac.update(prefix);
            hmac.update(label);
            hmac.update(&[_]u8{context_len});
            if (context.len > 0) hmac.update(context);
            hmac.update(&counter);
            var digest: [48]u8 = undefined;
            defer @memset(&digest, 0);
            hmac.final(&digest);
            @memcpy(output[0..@min(length, 48)], digest[0..@min(length, 48)]);
        },
        .sha512 => {
            var hmac = crypto.auth.hmac.sha2.HmacSha512.init(secret);
            hmac.update(&length_be);
            hmac.update(&[_]u8{full_label_len});
            hmac.update(prefix);
            hmac.update(label);
            hmac.update(&[_]u8{context_len});
            if (context.len > 0) hmac.update(context);
            hmac.update(&counter);
            var digest: [64]u8 = undefined;
            defer @memset(&digest, 0);
            hmac.final(&digest);
            @memcpy(output[0..@min(length, 64)], digest[0..@min(length, 64)]);
        },
    }
}

test "derive QUIC secrets from SSH key exchange" {
    const shared_secret = "test-shared-secret-from-curve25519-key-exchange";
    const exchange_hash = "test-exchange-hash-from-sha256";

    var secrets = try deriveQuicSecrets(shared_secret, exchange_hash, .sha256);
    defer secrets.zeroize();
    try std.testing.expect(!std.mem.eql(u8, &secrets.client_initial_secret, &secrets.server_initial_secret));
}

test "derive SSH QUIC secrets wire compatible" {
    const allocator = std.testing.allocator;
    const shared_secret = "test_shared_secret_32_bytes_value!";
    const exchange_hash = "test_exchange_hash_value_32_bytes!";

    var secrets = try deriveSshQuicSecrets(allocator, shared_secret, exchange_hash);
    defer secrets.zeroize();

    try std.testing.expect(!std.mem.eql(u8, &secrets.client_initial_secret, &secrets.server_initial_secret));

    var repeat = try deriveSshQuicSecrets(allocator, shared_secret, exchange_hash);
    defer repeat.zeroize();

    try std.testing.expectEqualSlices(u8, &secrets.client_initial_secret, &repeat.client_initial_secret);
    try std.testing.expectEqualSlices(u8, &secrets.server_initial_secret, &repeat.server_initial_secret);
}

test "derive SSH QUIC exporter secret deterministic vector" {
    const allocator = std.testing.allocator;
    const shared_secret = "test_shared_secret_32_bytes_value!";
    const exchange_hash = "test_exchange_hash_value_32_bytes!";

    const exporter = try deriveSshQuicExporterSecret(
        allocator,
        shared_secret,
        exchange_hash,
        "agent@v1",
        "channel/open",
    );

    const expected = [_]u8{
        0xf7, 0x83, 0x24, 0x56, 0x8b, 0xf8, 0x6d, 0x67,
        0xc2, 0xbc, 0xc4, 0xbd, 0x18, 0xe4, 0x92, 0x63,
        0x44, 0x94, 0xe1, 0x4c, 0x8f, 0xa5, 0xa5, 0xcb,
        0x14, 0x79, 0x9a, 0x5a, 0xeb, 0x26, 0xd6, 0x37,
    };

    try std.testing.expectEqualSlices(u8, &expected, &exporter);
}

test "derive SSH QUIC exporter secret varies by label and context" {
    const allocator = std.testing.allocator;
    const shared_secret = "test_shared_secret_32_bytes_value!";
    const exchange_hash = "test_exchange_hash_value_32_bytes!";

    const a = try deriveSshQuicExporterSecret(allocator, shared_secret, exchange_hash, "auth@v1", "ctx-a");
    const b = try deriveSshQuicExporterSecret(allocator, shared_secret, exchange_hash, "auth@v2", "ctx-a");
    const c = try deriveSshQuicExporterSecret(allocator, shared_secret, exchange_hash, "auth@v1", "ctx-b");

    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
}

test "encode ssh secret data canonicalizes positive mpint" {
    const allocator = std.testing.allocator;
    const k = [_]u8{ 0x00, 0x00, 0x7F };
    const h = "abc";

    const encoded = try encodeSshSecretData(allocator, &k, h);
    defer {
        @memset(encoded, 0);
        allocator.free(encoded);
    }

    const expected = [_]u8{
        0x00, 0x00, 0x00, 0x01,
        0x7F, 0x00, 0x00, 0x00,
        0x03, 'a',  'b',  'c',
    };
    try std.testing.expectEqualSlices(u8, &expected, encoded);
}

test "encode ssh secret data pads high-bit positive mpint" {
    const allocator = std.testing.allocator;
    const k = [_]u8{0x80};
    const h = "h";

    const encoded = try encodeSshSecretData(allocator, &k, h);
    defer {
        @memset(encoded, 0);
        allocator.free(encoded);
    }

    const expected = [_]u8{
        0x00, 0x00, 0x00, 0x02,
        0x00, 0x80, 0x00, 0x00,
        0x00, 0x01, 'h',
    };
    try std.testing.expectEqualSlices(u8, &expected, encoded);
}

test "derive SSH QUIC secrets treat equivalent positive mpints the same" {
    const allocator = std.testing.allocator;
    const k_with_leading_zeros = [_]u8{ 0x00, 0x00, 0x11, 0x22, 0x33 };
    const k_canonical = [_]u8{ 0x11, 0x22, 0x33 };
    const h = "same-hash";

    var a = try deriveSshQuicSecrets(allocator, &k_with_leading_zeros, h);
    defer a.zeroize();
    var b = try deriveSshQuicSecrets(allocator, &k_canonical, h);
    defer b.zeroize();

    try std.testing.expectEqualSlices(u8, &a.client_initial_secret, &b.client_initial_secret);
    try std.testing.expectEqualSlices(u8, &a.server_initial_secret, &b.server_initial_secret);
}

test "encode canonical positive mpint rejects oversized input" {
    const allocator = std.testing.allocator;
    const oversized = try allocator.alloc(u8, MAX_SSH_MPINT_LENGTH + 1);
    defer allocator.free(oversized);
    @memset(oversized, 0x01);

    try std.testing.expectError(error.InputTooLarge, encodeCanonicalPositiveMpint(allocator, oversized));
}

test "quic secrets zeroize clears both directions" {
    var secrets = QuicSecrets{
        .client_initial_secret = [_]u8{0xAA} ** 32,
        .server_initial_secret = [_]u8{0x55} ** 32,
        .hash_algorithm = .sha256,
    };

    secrets.zeroize();

    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 32, &secrets.client_initial_secret);
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 32, &secrets.server_initial_secret);
}

test "expand label is deterministic across invocations" {
    const secret = "test-secret-material";
    const label = "traffic";
    const context = "ctx";

    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    try expandLabel(secret, label, context, 32, .sha256, &a);
    try expandLabel(secret, label, context, 32, .sha256, &b);

    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "expand label output changes with hash algorithm" {
    const secret = "test-secret-material";
    const label = "traffic";
    const context = "ctx";

    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    try expandLabel(secret, label, context, 32, .sha256, &a);
    try expandLabel(secret, label, context, 32, .sha384, &b);

    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "expand label rejects oversized length and short output" {
    const secret = "test-secret-material";

    var out: [16]u8 = undefined;
    try std.testing.expectError(
        error.DerivationFailed,
        expandLabel(secret, "label", "ctx", 17, .sha256, &out),
    );

    var big_out: [32]u8 = undefined;
    try std.testing.expectError(
        error.DerivationFailed,
        expandLabel(secret, "label", "ctx", 0x1_0000, .sha256, &big_out),
    );
}

test "expand label rejects oversized label and context encodings" {
    const allocator = std.testing.allocator;
    const secret = "test-secret-material";

    const huge_label = try allocator.alloc(u8, 300);
    defer allocator.free(huge_label);
    @memset(huge_label, 'l');

    const huge_context = try allocator.alloc(u8, 256);
    defer allocator.free(huge_context);
    @memset(huge_context, 'c');

    var out: [32]u8 = undefined;
    try std.testing.expectError(
        error.DerivationFailed,
        expandLabel(secret, huge_label, "", 32, .sha256, &out),
    );
    try std.testing.expectError(
        error.DerivationFailed,
        expandLabel(secret, "label", huge_context, 32, .sha256, &out),
    );
}
