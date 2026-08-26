const std = @import("std");
const tls_context_mod = @import("tls_context.zig");

pub const KeyLogError = error{
    InvalidClientRandomLength,
    EmptyLabel,
    EmptySecret,
    OutOfMemory,
};

pub const KeyLogCallback = *const fn (line: []const u8) void;

pub const SecretFingerprint = [32]u8;

pub const HandshakeDiagnostics = struct {
    state: tls_context_mod.HandshakeState,
    cipher_suite: ?u16,
    selected_alpn: ?[]const u8,
    peer_transport_params_len: ?usize,
    last_error: ?[]const u8,
    handshake_secret_fingerprint: ?SecretFingerprint = null,
    application_secret_fingerprint: ?SecretFingerprint = null,
};

pub fn build_handshake_diagnostics(
    state: tls_context_mod.HandshakeState,
    cipher_suite: ?u16,
    selected_alpn: ?[]const u8,
    peer_transport_params: ?[]const u8,
    last_error: ?[]const u8,
    handshake_secret: ?[]const u8,
    application_secret: ?[]const u8,
) HandshakeDiagnostics {
    return .{
        .state = state,
        .cipher_suite = cipher_suite,
        .selected_alpn = selected_alpn,
        .peer_transport_params_len = if (peer_transport_params) |tp| tp.len else null,
        .last_error = last_error,
        .handshake_secret_fingerprint = if (handshake_secret) |s| fingerprint_secret(s) else null,
        .application_secret_fingerprint = if (application_secret) |s| fingerprint_secret(s) else null,
    };
}

pub fn fingerprint_secret(secret: []const u8) SecretFingerprint {
    var out: SecretFingerprint = undefined;
    std.crypto.hash.sha2.Sha256.hash(secret, &out, .{});
    return out;
}

pub fn emit_keylog_line(
    allocator: std.mem.Allocator,
    callback: ?KeyLogCallback,
    label: []const u8,
    client_random: []const u8,
    secret: []const u8,
) KeyLogError!void {
    if (callback == null) return;
    if (label.len == 0) return error.EmptyLabel;
    if (secret.len == 0) return error.EmptySecret;
    if (client_random.len != 32) return error.InvalidClientRandomLength;

    const line_len = label.len + 1 + (client_random.len * 2) + 1 + (secret.len * 2) + 1;
    const line = try allocator.alloc(u8, line_len);
    defer allocator.free(line);

    var offset: usize = 0;
    @memcpy(line[offset .. offset + label.len], label);
    offset += label.len;
    line[offset] = ' ';
    offset += 1;

    hex_encode_lower(client_random, line[offset .. offset + (client_random.len * 2)]);
    offset += client_random.len * 2;
    line[offset] = ' ';
    offset += 1;

    hex_encode_lower(secret, line[offset .. offset + (secret.len * 2)]);
    offset += secret.len * 2;
    line[offset] = '\n';

    callback.?(line);
}

fn hex_encode_lower(input: []const u8, output: []u8) void {
    std.debug.assert(output.len == input.len * 2);
    const table = "0123456789abcdef";
    for (input, 0..) |b, i| {
        output[i * 2] = table[b >> 4];
        output[i * 2 + 1] = table[b & 0x0F];
    }
}

test "fingerprint secret deterministic" {
    const a = fingerprint_secret("secret-data");
    const b = fingerprint_secret("secret-data");
    const c = fingerprint_secret("secret-data-v2");
    try std.testing.expectEqualSlices(u8, &a, &b);
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
}

test "build diagnostics includes redacted fingerprints and lengths" {
    const d = build_handshake_diagnostics(
        .server_hello_received,
        0x1301,
        "h3",
        "tp",
        "alert",
        "hs-secret",
        "app-secret",
    );

    try std.testing.expectEqual(tls_context_mod.HandshakeState.server_hello_received, d.state);
    try std.testing.expectEqual(@as(u16, 0x1301), d.cipher_suite.?);
    try std.testing.expectEqualStrings("h3", d.selected_alpn.?);
    try std.testing.expectEqual(@as(usize, 2), d.peer_transport_params_len.?);
    try std.testing.expectEqualStrings("alert", d.last_error.?);
    try std.testing.expect(d.handshake_secret_fingerprint != null);
    try std.testing.expect(d.application_secret_fingerprint != null);
}

test "emit keylog line validates inputs" {
    const allocator = std.testing.allocator;
    const random = [_]u8{0x11} ** 32;

    try std.testing.expectError(error.EmptyLabel, emit_keylog_line(allocator, dummy_callback, "", &random, "secret"));
    try std.testing.expectError(error.EmptySecret, emit_keylog_line(allocator, dummy_callback, "CLIENT_TRAFFIC_SECRET_0", &random, ""));
    try std.testing.expectError(
        error.InvalidClientRandomLength,
        emit_keylog_line(allocator, dummy_callback, "CLIENT_TRAFFIC_SECRET_0", "short", "secret"),
    );
}

test "emit keylog line format" {
    const allocator = std.testing.allocator;
    const random = [_]u8{0xAB} ** 32;
    const secret = [_]u8{ 0x01, 0x02, 0x03, 0x04 };

    captured_len = 0;
    try emit_keylog_line(allocator, capture_callback, "CLIENT_TRAFFIC_SECRET_0", &random, &secret);

    const line = captured_buf[0..captured_len];
    try std.testing.expect(std.mem.startsWith(u8, line, "CLIENT_TRAFFIC_SECRET_0 abababab"));
    try std.testing.expect(std.mem.endsWith(u8, line, " 01020304\n"));
}

var captured_buf: [256]u8 = [_]u8{0} ** 256;
var captured_len: usize = 0;

fn dummy_callback(_: []const u8) void {}

fn capture_callback(line: []const u8) void {
    std.debug.assert(line.len <= captured_buf.len);
    @memcpy(captured_buf[0..line.len], line);
    captured_len = line.len;
}
