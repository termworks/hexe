const std = @import("std");

pub const ApiRole = enum {
    crypto_primitive,
    handshake_validation,
    diagnostics,
    transport_owned,
};

pub const TlsApiSurface = enum {
    tls_handshake,
    tls_key_schedule,
    tls_context,
    tls_auth,
    tls_diagnostics,
    tls_extensions,
    tls_finished,
    tls_policy,
    tls_interop,
};

pub fn classify_api(surface: TlsApiSurface) ApiRole {
    return switch (surface) {
        .tls_handshake,
        .tls_key_schedule,
        .tls_finished,
        .tls_policy,
        => .crypto_primitive,

        .tls_auth,
        .tls_extensions,
        .tls_context,
        .tls_interop,
        => .handshake_validation,

        .tls_diagnostics => .diagnostics,
    };
}

pub fn is_quic_transport_owned_api_name(api_name: []const u8) bool {
    return std.mem.indexOf(u8, api_name, "packet") != null or
        std.mem.indexOf(u8, api_name, "ack") != null or
        std.mem.indexOf(u8, api_name, "congestion") != null or
        std.mem.indexOf(u8, api_name, "loss") != null or
        std.mem.indexOf(u8, api_name, "stream") != null;
}

test "tls api classification is stable" {
    try std.testing.expectEqual(ApiRole.crypto_primitive, classify_api(.tls_key_schedule));
    try std.testing.expectEqual(ApiRole.handshake_validation, classify_api(.tls_auth));
    try std.testing.expectEqual(ApiRole.handshake_validation, classify_api(.tls_interop));
    try std.testing.expectEqual(ApiRole.diagnostics, classify_api(.tls_diagnostics));
}

test "transport-owned name heuristic rejects quic transport terms" {
    try std.testing.expect(is_quic_transport_owned_api_name("quic_packet_encode"));
    try std.testing.expect(is_quic_transport_owned_api_name("loss_recovery"));
    try std.testing.expect(is_quic_transport_owned_api_name("stream_scheduler"));
    try std.testing.expect(!is_quic_transport_owned_api_name("verify_finished_data"));
    try std.testing.expect(!is_quic_transport_owned_api_name("tls_auth_verify_hostname"));
}
