const std = @import("std");
const libfast = @import("libfast");

fn apply_peer_transport_params_with_limits(
    conn: *libfast.QuicConnection,
    allocator: std.mem.Allocator,
    max_bidi: u64,
    max_uni: u64,
) !void {
    var params = libfast.transport_params.TransportParams.defaultServer();
    params.initial_max_streams_bidi = max_bidi;
    params.initial_max_streams_uni = max_uni;

    const encoded = try params.encode(allocator);
    defer allocator.free(encoded);
    try conn.applyPeerTransportParams(encoded);
}

fn build_tls_server_hello_for_tests(
    allocator: std.mem.Allocator,
    alpn: []const u8,
    tp_payload: []const u8,
) ![]u8 {
    var alpn_wire: [8]u8 = undefined;
    if (alpn.len == 0 or alpn.len > 5) return error.InvalidInput;

    alpn_wire[0] = 0x00;
    alpn_wire[1] = @intCast(alpn.len + 1);
    alpn_wire[2] = @intCast(alpn.len);
    @memcpy(alpn_wire[3 .. 3 + alpn.len], alpn);

    const ext = [_]libfast.tls_handshake.Extension{
        .{
            .extension_type = @intFromEnum(libfast.tls_handshake.ExtensionType.application_layer_protocol_negotiation),
            .extension_data = alpn_wire[0 .. 3 + alpn.len],
        },
        .{
            .extension_type = @intFromEnum(libfast.tls_handshake.ExtensionType.quic_transport_parameters),
            .extension_data = tp_payload,
        },
    };

    const random: [32]u8 = [_]u8{61} ** 32;
    const server_hello = libfast.tls_handshake.ServerHello{
        .random = random,
        .cipher_suite = libfast.tls_handshake.TLS_AES_128_GCM_SHA256,
        .extensions = &ext,
    };

    return server_hello.encode(allocator);
}

test "dual-mode regression stream policy tls vs ssh" {
    const allocator = std.testing.allocator;

    var tls_cfg = libfast.QuicConfig.tlsClient("example.com");
    tls_cfg.tls_config.?.alpn_protocols = &[_][]const u8{"h3"};
    var tls_conn = try libfast.QuicConnection.init(allocator, tls_cfg);
    defer tls_conn.deinit();
    try tls_conn.connect("127.0.0.1", 4433);

    var tls_tp = libfast.transport_params.TransportParams.defaultServer();
    tls_tp.initial_max_streams_bidi = 2;
    tls_tp.initial_max_streams_uni = 1;
    const tls_tp_encoded = try tls_tp.encode(allocator);
    defer allocator.free(tls_tp_encoded);

    const server_hello = try build_tls_server_hello_for_tests(allocator, "h3", tls_tp_encoded);
    defer allocator.free(server_hello);
    try tls_conn.processTlsServerHello(server_hello, "test-shared-secret-from-ecdhe");
    tls_conn.internal_conn.?.markEstablished();
    tls_conn.state = .established;

    _ = try tls_conn.openStream(false);

    const ssh_cfg = libfast.QuicConfig.sshClient("example.com", "secret");
    var ssh_conn = try libfast.QuicConnection.init(allocator, ssh_cfg);
    defer ssh_conn.deinit();
    try ssh_conn.connect("127.0.0.1", 4433);
    ssh_conn.internal_conn.?.markEstablished();
    ssh_conn.state = .established;
    try apply_peer_transport_params_with_limits(&ssh_conn, allocator, 2, 1);

    try std.testing.expectError(libfast.QuicError.StreamError, ssh_conn.openStream(false));
}

test "dual-mode regression negotiated stream limits enforced" {
    const allocator = std.testing.allocator;

    var tls_cfg = libfast.QuicConfig.tlsClient("example.com");
    tls_cfg.tls_config.?.alpn_protocols = &[_][]const u8{"h3"};
    var tls_conn = try libfast.QuicConnection.init(allocator, tls_cfg);
    defer tls_conn.deinit();
    try tls_conn.connect("127.0.0.1", 4433);

    var tls_tp = libfast.transport_params.TransportParams.defaultServer();
    tls_tp.initial_max_streams_bidi = 1;
    const tls_tp_encoded = try tls_tp.encode(allocator);
    defer allocator.free(tls_tp_encoded);

    const server_hello = try build_tls_server_hello_for_tests(allocator, "h3", tls_tp_encoded);
    defer allocator.free(server_hello);
    try tls_conn.processTlsServerHello(server_hello, "test-shared-secret-from-ecdhe");
    tls_conn.internal_conn.?.markEstablished();
    tls_conn.state = .established;

    _ = try tls_conn.openStream(true);
    try std.testing.expectError(libfast.QuicError.StreamLimitReached, tls_conn.openStream(true));

    const ssh_cfg = libfast.QuicConfig.sshClient("example.com", "secret");
    var ssh_conn = try libfast.QuicConnection.init(allocator, ssh_cfg);
    defer ssh_conn.deinit();
    try ssh_conn.connect("127.0.0.1", 4433);
    ssh_conn.internal_conn.?.markEstablished();
    ssh_conn.state = .established;
    try apply_peer_transport_params_with_limits(&ssh_conn, allocator, 1, 0);

    _ = try ssh_conn.openStream(true);
    try std.testing.expectError(libfast.QuicError.StreamLimitReached, ssh_conn.openStream(true));
}
