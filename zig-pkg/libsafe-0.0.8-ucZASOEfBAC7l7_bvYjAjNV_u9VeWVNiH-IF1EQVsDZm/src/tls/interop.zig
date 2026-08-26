const std = @import("std");
const handshake_mod = @import("handshake.zig");
const tls_context_mod = @import("tls_context.zig");
const transport_params_mod = @import("../core/transport_params.zig");

pub const CaseOutcome = enum {
    success,
    handshake_failed,
    alpn_mismatch,
    unsupported_cipher_suite,
    invalid_state,
    out_of_memory,
};

pub const ClientServerHelloCase = struct {
    server_name: []const u8 = "example.com",
    offered_alpn: []const []const u8 = &[_][]const u8{"h3"},
    server_hello_data: []const u8,
};

pub const FullHandshakeCase = struct {
    server_name: []const u8 = "example.com",
    offered_alpn: []const []const u8 = &[_][]const u8{"h3"},
    shared_secret: []const u8 = "shared-secret",
    client_transport_params: ?[]const u8 = null,
    server_transport_params: ?[]const u8 = null,
    server_supported_alpn: ?[]const []const u8 = null,
};

pub fn run_client_server_hello_case(
    allocator: std.mem.Allocator,
    case: ClientServerHelloCase,
) !CaseOutcome {
    var client = tls_context_mod.TlsContext.init(allocator, true);
    defer client.deinit();

    var client_tp = transport_params_mod.TransportParams.defaultClient();
    const client_tp_encoded = try client_tp.encode(allocator);
    defer allocator.free(client_tp_encoded);

    const ch = try client.startClientHandshakeWithParams(case.server_name, case.offered_alpn, client_tp_encoded);
    defer allocator.free(ch);

    client.processServerHello(case.server_hello_data) catch |err| {
        return map_tls_error(err);
    };
    return .success;
}

pub fn run_full_handshake_case(
    allocator: std.mem.Allocator,
    case: FullHandshakeCase,
) !CaseOutcome {
    var client = tls_context_mod.TlsContext.init(allocator, true);
    defer client.deinit();
    var server = tls_context_mod.TlsContext.init(allocator, false);
    defer server.deinit();

    var default_client_tp = transport_params_mod.TransportParams.defaultClient();
    const default_client_tp_encoded = try default_client_tp.encode(allocator);
    defer allocator.free(default_client_tp_encoded);

    var default_server_tp = transport_params_mod.TransportParams.defaultServer();
    const default_server_tp_encoded = try default_server_tp.encode(allocator);
    defer allocator.free(default_server_tp_encoded);

    const client_tp = case.client_transport_params orelse default_client_tp_encoded;
    const server_tp = case.server_transport_params orelse default_server_tp_encoded;
    const server_alpn = case.server_supported_alpn orelse case.offered_alpn;

    const ch = client.startClientHandshakeWithParams(case.server_name, case.offered_alpn, client_tp) catch |err| {
        return map_tls_error(err);
    };
    defer allocator.free(ch);

    const sh = server.buildServerHelloFromClientHello(ch, server_alpn, server_tp) catch |err| {
        return map_tls_error(err);
    };
    defer allocator.free(sh);

    client.processServerHello(sh) catch |err| {
        return map_tls_error(err);
    };

    client.completeHandshake(case.shared_secret) catch |err| {
        return map_tls_error(err);
    };
    server.completeHandshake(case.shared_secret) catch |err| {
        return map_tls_error(err);
    };

    return .success;
}

pub fn map_tls_error(err: anyerror) CaseOutcome {
    return switch (err) {
        error.HandshakeFailed => .handshake_failed,
        error.AlpnMismatch => .alpn_mismatch,
        error.UnsupportedCipherSuite => .unsupported_cipher_suite,
        error.InvalidState => .invalid_state,
        error.OutOfMemory => .out_of_memory,
        else => .handshake_failed,
    };
}

test "interop hook reports success for valid server hello" {
    const allocator = std.testing.allocator;

    var server_tp = transport_params_mod.TransportParams.defaultServer();
    const server_tp_encoded = try server_tp.encode(allocator);
    defer allocator.free(server_tp_encoded);

    const ext = [_]handshake_mod.Extension{
        .{
            .extension_type = @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation),
            .extension_data = &[_]u8{ 0x00, 0x03, 0x02, 'h', '3' },
        },
        .{
            .extension_type = @intFromEnum(handshake_mod.ExtensionType.quic_transport_parameters),
            .extension_data = server_tp_encoded,
        },
    };
    const sh = handshake_mod.ServerHello{
        .random = [_]u8{0x61} ** 32,
        .cipher_suite = handshake_mod.TLS_AES_128_GCM_SHA256,
        .extensions = &ext,
    };
    const sh_bytes = try sh.encode(allocator);
    defer allocator.free(sh_bytes);

    const outcome = try run_client_server_hello_case(allocator, .{ .server_hello_data = sh_bytes });
    try std.testing.expectEqual(CaseOutcome.success, outcome);
}

test "interop hook reports alpn mismatch" {
    const allocator = std.testing.allocator;

    var server_tp = transport_params_mod.TransportParams.defaultServer();
    const server_tp_encoded = try server_tp.encode(allocator);
    defer allocator.free(server_tp_encoded);

    const ext = [_]handshake_mod.Extension{
        .{
            .extension_type = @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation),
            .extension_data = &[_]u8{ 0x00, 0x03, 0x02, 'h', '2' },
        },
        .{
            .extension_type = @intFromEnum(handshake_mod.ExtensionType.quic_transport_parameters),
            .extension_data = server_tp_encoded,
        },
    };
    const sh = handshake_mod.ServerHello{
        .random = [_]u8{0x62} ** 32,
        .cipher_suite = handshake_mod.TLS_AES_128_GCM_SHA256,
        .extensions = &ext,
    };
    const sh_bytes = try sh.encode(allocator);
    defer allocator.free(sh_bytes);

    const outcome = try run_client_server_hello_case(allocator, .{ .server_hello_data = sh_bytes });
    try std.testing.expectEqual(CaseOutcome.alpn_mismatch, outcome);
}

test "interop hook reports unsupported cipher and malformed payload" {
    const allocator = std.testing.allocator;

    const bad_cipher_sh = handshake_mod.ServerHello{
        .random = [_]u8{0x63} ** 32,
        .cipher_suite = 0xDEAD,
        .extensions = &[_]handshake_mod.Extension{},
    };
    const bad_cipher_bytes = try bad_cipher_sh.encode(allocator);
    defer allocator.free(bad_cipher_bytes);

    const bad_cipher_outcome = try run_client_server_hello_case(allocator, .{ .server_hello_data = bad_cipher_bytes });
    try std.testing.expectEqual(CaseOutcome.unsupported_cipher_suite, bad_cipher_outcome);

    const malformed = [_]u8{ 0x02, 0x00, 0x01, 0x00 };
    const malformed_outcome = try run_client_server_hello_case(allocator, .{ .server_hello_data = &malformed });
    try std.testing.expectEqual(CaseOutcome.handshake_failed, malformed_outcome);
}

test "full interop hook reports success for complete handshake" {
    const allocator = std.testing.allocator;
    const outcome = try run_full_handshake_case(allocator, .{});
    try std.testing.expectEqual(CaseOutcome.success, outcome);
}

test "full interop hook reports alpn mismatch" {
    const allocator = std.testing.allocator;
    const mismatch = [_][]const u8{"h2"};
    const outcome = try run_full_handshake_case(allocator, .{ .server_supported_alpn = &mismatch });
    try std.testing.expectEqual(CaseOutcome.alpn_mismatch, outcome);
}

test "full interop hook reports malformed transport parameters" {
    const allocator = std.testing.allocator;
    const bad_tp = [_]u8{ 0x03, 0x02, 0x44, 0xAF };
    const outcome = try run_full_handshake_case(allocator, .{ .server_transport_params = &bad_tp });
    try std.testing.expectEqual(CaseOutcome.handshake_failed, outcome);
}
