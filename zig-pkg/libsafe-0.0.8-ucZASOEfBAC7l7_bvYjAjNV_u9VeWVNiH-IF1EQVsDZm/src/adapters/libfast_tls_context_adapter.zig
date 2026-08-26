const std = @import("std");
const engine = @import("../engine.zig");
const handshake_mod = @import("../tls/handshake.zig");
const tls_context_mod = @import("../tls/tls_context.zig");
const transport_params_mod = @import("../core/transport_params.zig");

pub const LibfastTlsContextAdapter = struct {
    allocator: std.mem.Allocator,
    inner: tls_context_mod.TlsContext,

    pub fn init(allocator: std.mem.Allocator, role: engine.Role) LibfastTlsContextAdapter {
        return .{
            .allocator = allocator,
            .inner = tls_context_mod.TlsContext.init(allocator, role == .client),
        };
    }

    pub fn deinit(self: *LibfastTlsContextAdapter) void {
        self.inner.deinit();
    }

    pub fn asEngine(self: *LibfastTlsContextAdapter) engine.Engine {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    fn cast(ctx: *anyopaque) *LibfastTlsContextAdapter {
        return @ptrCast(@alignCast(ctx));
    }

    fn castConst(ctx: *const anyopaque) *const LibfastTlsContextAdapter {
        return @ptrCast(@alignCast(ctx));
    }

    fn deinitErased(ctx: *anyopaque) void {
        const self = cast(ctx);
        self.deinit();
    }

    fn beginClientHandshakeErased(
        ctx: *anyopaque,
        server_name: []const u8,
        alpn_protocols: []const []const u8,
        local_transport_params: []const u8,
    ) engine.EngineError![]u8 {
        const self = cast(ctx);
        return self.inner.startClientHandshakeWithParams(
            server_name,
            alpn_protocols,
            local_transport_params,
        ) catch |err| {
            return mapError(err);
        };
    }

    fn buildServerHelloErased(
        ctx: *anyopaque,
        client_hello_data: []const u8,
        server_supported_alpn: []const []const u8,
        local_transport_params: []const u8,
    ) engine.EngineError![]u8 {
        const self = cast(ctx);
        return self.inner.buildServerHelloFromClientHello(
            client_hello_data,
            server_supported_alpn,
            local_transport_params,
        ) catch |err| {
            return mapError(err);
        };
    }

    fn processServerHelloErased(ctx: *anyopaque, server_hello_data: []const u8) engine.EngineError!void {
        const self = cast(ctx);
        self.inner.processServerHello(server_hello_data) catch |err| {
            return mapError(err);
        };
    }

    fn completeHandshakeErased(ctx: *anyopaque, shared_secret: []const u8) engine.EngineError!void {
        const self = cast(ctx);
        self.inner.completeHandshake(shared_secret) catch |err| {
            return mapError(err);
        };
    }

    fn getSelectedAlpnErased(ctx: *const anyopaque) ?[]const u8 {
        const self = castConst(ctx);
        return self.inner.getSelectedAlpn();
    }

    fn getPeerTransportParamsErased(ctx: *const anyopaque) ?[]const u8 {
        const self = castConst(ctx);
        return self.inner.getPeerTransportParams();
    }

    fn stateErased(ctx: *const anyopaque) engine.HandshakeState {
        const self = castConst(ctx);
        return switch (self.inner.state) {
            .idle => .idle,
            .client_hello_sent => .client_hello_sent,
            .server_hello_received => .server_hello_received,
            .handshake_complete => .handshake_complete,
            .failed => .failed,
        };
    }

    fn freeBufferErased(ctx: *anyopaque, bytes: []u8) void {
        const self = cast(ctx);
        self.allocator.free(bytes);
    }

    const vtable: engine.EngineVTable = .{
        .deinit = deinitErased,
        .begin_client_handshake = beginClientHandshakeErased,
        .build_server_hello = buildServerHelloErased,
        .process_server_hello = processServerHelloErased,
        .complete_handshake = completeHandshakeErased,
        .get_selected_alpn = getSelectedAlpnErased,
        .get_peer_transport_params = getPeerTransportParamsErased,
        .state = stateErased,
        .free_buffer = freeBufferErased,
    };

    fn mapError(err: anyerror) engine.EngineError {
        return switch (err) {
            tls_context_mod.TlsError.InvalidState => error.InvalidState,
            tls_context_mod.TlsError.AlpnMismatch => error.AlpnMismatch,
            tls_context_mod.TlsError.UnsupportedCipherSuite => error.UnsupportedCipherSuite,
            tls_context_mod.TlsError.OutOfMemory => error.OutOfMemory,
            else => error.HandshakeFailed,
        };
    }
};

fn makeServerHelloWithExtensions(
    allocator: std.mem.Allocator,
    extensions: []const handshake_mod.Extension,
) ![]u8 {
    const random: [32]u8 = [_]u8{0x33} ** 32;
    const msg = handshake_mod.ServerHello{
        .random = random,
        .cipher_suite = handshake_mod.TLS_AES_128_GCM_SHA256,
        .extensions = extensions,
    };
    return msg.encode(allocator);
}

test "adapter begins client handshake" {
    const allocator = std.testing.allocator;

    var adapter = LibfastTlsContextAdapter.init(allocator, .client);
    defer adapter.deinit();

    var tls_engine = adapter.asEngine();

    const offered = [_][]const u8{"h3"};
    const client_hello = try tls_engine.beginClientHandshake(
        "example.com",
        &offered,
        &[_]u8{},
    );
    defer tls_engine.freeBuffer(client_hello);

    try std.testing.expect(client_hello.len > 0);
    try std.testing.expectEqual(engine.HandshakeState.client_hello_sent, tls_engine.state());
}

test "adapter maps invalid state from processServerHello" {
    const allocator = std.testing.allocator;

    var adapter = LibfastTlsContextAdapter.init(allocator, .client);
    defer adapter.deinit();
    var tls_engine = adapter.asEngine();

    try std.testing.expectError(error.InvalidState, tls_engine.processServerHello("not-started"));
}

test "adapter maps malformed server hello to handshake failed" {
    const allocator = std.testing.allocator;

    var adapter = LibfastTlsContextAdapter.init(allocator, .client);
    defer adapter.deinit();
    var tls_engine = adapter.asEngine();

    const offered = [_][]const u8{"h3"};
    const client_hello = try tls_engine.beginClientHandshake("example.com", &offered, &[_]u8{});
    defer tls_engine.freeBuffer(client_hello);

    try std.testing.expectError(error.HandshakeFailed, tls_engine.processServerHello("bad-server-hello"));
}

test "adapter maps unsupported cipher suite from server hello" {
    const allocator = std.testing.allocator;

    var adapter = LibfastTlsContextAdapter.init(allocator, .client);
    defer adapter.deinit();
    var tls_engine = adapter.asEngine();

    const offered = [_][]const u8{"h3"};
    const client_hello = try tls_engine.beginClientHandshake("example.com", &offered, &[_]u8{});
    defer tls_engine.freeBuffer(client_hello);

    const random: [32]u8 = [_]u8{0x44} ** 32;
    const sh = handshake_mod.ServerHello{
        .random = random,
        .cipher_suite = 0xFFFF,
        .extensions = &[_]handshake_mod.Extension{},
    };
    const encoded_sh = try sh.encode(allocator);
    defer allocator.free(encoded_sh);

    try std.testing.expectError(error.UnsupportedCipherSuite, tls_engine.processServerHello(encoded_sh));
}

test "adapter maps ALPN mismatch during server hello build" {
    const allocator = std.testing.allocator;

    var client_adapter = LibfastTlsContextAdapter.init(allocator, .client);
    defer client_adapter.deinit();
    var server_adapter = LibfastTlsContextAdapter.init(allocator, .server);
    defer server_adapter.deinit();

    var client_engine = client_adapter.asEngine();
    var server_engine = server_adapter.asEngine();

    const offered = [_][]const u8{"h3"};
    const unsupported_on_server = [_][]const u8{"h2"};

    const client_hello = try client_engine.beginClientHandshake("example.com", &offered, &[_]u8{});
    defer client_engine.freeBuffer(client_hello);

    try std.testing.expectError(
        error.AlpnMismatch,
        server_engine.buildServerHello(client_hello, &unsupported_on_server, &[_]u8{}),
    );
}

test "adapter state transition matrix happy path" {
    const allocator = std.testing.allocator;

    var client_adapter = LibfastTlsContextAdapter.init(allocator, .client);
    defer client_adapter.deinit();
    var server_adapter = LibfastTlsContextAdapter.init(allocator, .server);
    defer server_adapter.deinit();

    var client_engine = client_adapter.asEngine();
    var server_engine = server_adapter.asEngine();

    try std.testing.expectEqual(engine.HandshakeState.idle, client_engine.state());
    try std.testing.expectEqual(engine.HandshakeState.idle, server_engine.state());

    const offered = [_][]const u8{"h3"};
    var client_tp = transport_params_mod.TransportParams.defaultClient();
    const client_tp_encoded = try client_tp.encode(allocator);
    defer allocator.free(client_tp_encoded);

    var server_tp = transport_params_mod.TransportParams.defaultServer();
    const server_tp_encoded = try server_tp.encode(allocator);
    defer allocator.free(server_tp_encoded);

    const client_hello = try client_engine.beginClientHandshake("example.com", &offered, client_tp_encoded);
    defer client_engine.freeBuffer(client_hello);
    try std.testing.expectEqual(engine.HandshakeState.client_hello_sent, client_engine.state());

    const server_hello = try server_engine.buildServerHello(client_hello, &offered, server_tp_encoded);
    defer server_engine.freeBuffer(server_hello);
    try std.testing.expectEqual(engine.HandshakeState.server_hello_received, server_engine.state());

    try client_engine.processServerHello(server_hello);
    try std.testing.expectEqual(engine.HandshakeState.server_hello_received, client_engine.state());

    try client_engine.completeHandshake("shared-secret");
    try server_engine.completeHandshake("shared-secret");
    try std.testing.expectEqual(engine.HandshakeState.handshake_complete, client_engine.state());
    try std.testing.expectEqual(engine.HandshakeState.handshake_complete, server_engine.state());
}

test "adapter rejects invalid operation order" {
    const allocator = std.testing.allocator;

    var client_adapter = LibfastTlsContextAdapter.init(allocator, .client);
    defer client_adapter.deinit();
    var server_adapter = LibfastTlsContextAdapter.init(allocator, .server);
    defer server_adapter.deinit();

    var client_engine = client_adapter.asEngine();
    var server_engine = server_adapter.asEngine();

    try std.testing.expectError(error.InvalidState, client_engine.completeHandshake("shared-secret"));
    try std.testing.expectError(error.InvalidState, client_engine.buildServerHello("bad", &[_][]const u8{"h3"}, &[_]u8{}));
    try std.testing.expectError(error.InvalidState, server_engine.beginClientHandshake("example.com", &[_][]const u8{"h3"}, &[_]u8{}));
    try std.testing.expectError(error.InvalidState, server_engine.processServerHello("bad"));
}

test "adapter exposes selected ALPN and peer transport params after server hello" {
    const allocator = std.testing.allocator;

    var client_adapter = LibfastTlsContextAdapter.init(allocator, .client);
    defer client_adapter.deinit();
    var server_adapter = LibfastTlsContextAdapter.init(allocator, .server);
    defer server_adapter.deinit();

    var client_engine = client_adapter.asEngine();
    var server_engine = server_adapter.asEngine();

    const offered = [_][]const u8{"h3"};
    var client_tp = transport_params_mod.TransportParams.defaultClient();
    const client_tp_encoded = try client_tp.encode(allocator);
    defer allocator.free(client_tp_encoded);

    var server_tp = transport_params_mod.TransportParams.defaultServer();
    const server_tp_encoded = try server_tp.encode(allocator);
    defer allocator.free(server_tp_encoded);

    const client_hello = try client_engine.beginClientHandshake("example.com", &offered, client_tp_encoded);
    defer client_engine.freeBuffer(client_hello);

    const server_hello = try server_engine.buildServerHello(client_hello, &offered, server_tp_encoded);
    defer server_engine.freeBuffer(server_hello);

    try client_engine.processServerHello(server_hello);

    const selected_alpn = client_engine.getSelectedAlpn() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("h3", selected_alpn);

    const peer_tp = client_engine.getPeerTransportParams() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, server_tp_encoded, peer_tp);
}

test "adapter selected ALPN and peer transport params are null before processing" {
    const allocator = std.testing.allocator;

    var adapter = LibfastTlsContextAdapter.init(allocator, .client);
    defer adapter.deinit();
    var tls_engine = adapter.asEngine();

    try std.testing.expect(tls_engine.getSelectedAlpn() == null);
    try std.testing.expect(tls_engine.getPeerTransportParams() == null);
}

test "adapter maps ALPN mismatch during process server hello" {
    const allocator = std.testing.allocator;

    var adapter = LibfastTlsContextAdapter.init(allocator, .client);
    defer adapter.deinit();
    var tls_engine = adapter.asEngine();

    const offered = [_][]const u8{"h3"};
    const ch = try tls_engine.beginClientHandshake("example.com", &offered, &[_]u8{});
    defer tls_engine.freeBuffer(ch);

    const alpn_h2 = [_]u8{ 0x00, 0x03, 0x02, 'h', '2' };
    const ext = [_]handshake_mod.Extension{.{
        .extension_type = @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation),
        .extension_data = &alpn_h2,
    }};
    const sh = try makeServerHelloWithExtensions(allocator, &ext);
    defer allocator.free(sh);

    try std.testing.expectError(error.AlpnMismatch, tls_engine.processServerHello(sh));
}

test "adapter maps invalid transport parameters during process server hello" {
    const allocator = std.testing.allocator;

    var adapter = LibfastTlsContextAdapter.init(allocator, .client);
    defer adapter.deinit();
    var tls_engine = adapter.asEngine();

    const offered = [_][]const u8{"h3"};
    const ch = try tls_engine.beginClientHandshake("example.com", &offered, &[_]u8{});
    defer tls_engine.freeBuffer(ch);

    const bad_tp = [_]u8{ 0x03, 0x02, 0x44, 0xAF };
    const ext = [_]handshake_mod.Extension{.{
        .extension_type = @intFromEnum(handshake_mod.ExtensionType.quic_transport_parameters),
        .extension_data = &bad_tp,
    }};
    const sh = try makeServerHelloWithExtensions(allocator, &ext);
    defer allocator.free(sh);

    try std.testing.expectError(error.HandshakeFailed, tls_engine.processServerHello(sh));
    try std.testing.expectEqual(engine.HandshakeState.client_hello_sent, tls_engine.state());
    try std.testing.expect(tls_engine.getSelectedAlpn() == null);
    try std.testing.expect(tls_engine.getPeerTransportParams() == null);
}

test "adapter maps duplicate ALPN extensions during process server hello" {
    const allocator = std.testing.allocator;

    var adapter = LibfastTlsContextAdapter.init(allocator, .client);
    defer adapter.deinit();
    var tls_engine = adapter.asEngine();

    const offered = [_][]const u8{"h3"};
    const ch = try tls_engine.beginClientHandshake("example.com", &offered, &[_]u8{});
    defer tls_engine.freeBuffer(ch);

    const alpn_h3 = [_]u8{ 0x00, 0x03, 0x02, 'h', '3' };
    const ext = [_]handshake_mod.Extension{
        .{ .extension_type = @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation), .extension_data = &alpn_h3 },
        .{ .extension_type = @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation), .extension_data = &alpn_h3 },
    };
    const sh = try makeServerHelloWithExtensions(allocator, &ext);
    defer allocator.free(sh);

    try std.testing.expectError(error.HandshakeFailed, tls_engine.processServerHello(sh));
    try std.testing.expectEqual(engine.HandshakeState.client_hello_sent, tls_engine.state());
}

test "adapter maps duplicate transport parameter extensions during process server hello" {
    const allocator = std.testing.allocator;

    var adapter = LibfastTlsContextAdapter.init(allocator, .client);
    defer adapter.deinit();
    var tls_engine = adapter.asEngine();

    const offered = [_][]const u8{"h3"};
    const ch = try tls_engine.beginClientHandshake("example.com", &offered, &[_]u8{});
    defer tls_engine.freeBuffer(ch);

    var server_tp = transport_params_mod.TransportParams.defaultServer();
    const server_tp_encoded = try server_tp.encode(allocator);
    defer allocator.free(server_tp_encoded);

    const ext = [_]handshake_mod.Extension{
        .{ .extension_type = @intFromEnum(handshake_mod.ExtensionType.quic_transport_parameters), .extension_data = server_tp_encoded },
        .{ .extension_type = @intFromEnum(handshake_mod.ExtensionType.quic_transport_parameters), .extension_data = server_tp_encoded },
    };
    const sh = try makeServerHelloWithExtensions(allocator, &ext);
    defer allocator.free(sh);

    try std.testing.expectError(error.HandshakeFailed, tls_engine.processServerHello(sh));
    try std.testing.expectEqual(engine.HandshakeState.client_hello_sent, tls_engine.state());
    try std.testing.expect(tls_engine.getPeerTransportParams() == null);
}

test "adapter enforces single-use handshake transitions" {
    const allocator = std.testing.allocator;

    var client_adapter = LibfastTlsContextAdapter.init(allocator, .client);
    defer client_adapter.deinit();
    var server_adapter = LibfastTlsContextAdapter.init(allocator, .server);
    defer server_adapter.deinit();

    var client_engine = client_adapter.asEngine();
    var server_engine = server_adapter.asEngine();

    const offered = [_][]const u8{"h3"};
    var client_tp = transport_params_mod.TransportParams.defaultClient();
    const client_tp_encoded = try client_tp.encode(allocator);
    defer allocator.free(client_tp_encoded);

    var server_tp = transport_params_mod.TransportParams.defaultServer();
    const server_tp_encoded = try server_tp.encode(allocator);
    defer allocator.free(server_tp_encoded);

    const client_hello = try client_engine.beginClientHandshake("example.com", &offered, client_tp_encoded);
    defer client_engine.freeBuffer(client_hello);

    try std.testing.expectError(
        error.InvalidState,
        client_engine.beginClientHandshake("example.com", &offered, client_tp_encoded),
    );

    const server_hello = try server_engine.buildServerHello(client_hello, &offered, server_tp_encoded);
    defer server_engine.freeBuffer(server_hello);

    try std.testing.expectError(
        error.InvalidState,
        server_engine.buildServerHello(client_hello, &offered, server_tp_encoded),
    );

    try client_engine.processServerHello(server_hello);
    try std.testing.expectError(error.InvalidState, client_engine.processServerHello(server_hello));

    try client_engine.completeHandshake("shared-secret");
    try server_engine.completeHandshake("shared-secret");
    try std.testing.expectError(error.InvalidState, client_engine.completeHandshake("shared-secret"));
}

test "adapter maps malformed ALPN extension payload during process server hello" {
    const allocator = std.testing.allocator;

    var adapter = LibfastTlsContextAdapter.init(allocator, .client);
    defer adapter.deinit();
    var tls_engine = adapter.asEngine();

    const offered = [_][]const u8{"h3"};
    const ch = try tls_engine.beginClientHandshake("example.com", &offered, &[_]u8{});
    defer tls_engine.freeBuffer(ch);

    const bad_alpn = [_]u8{ 0x00, 0x04, 0x02, 'h', '3' };
    const ext = [_]handshake_mod.Extension{.{
        .extension_type = @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation),
        .extension_data = &bad_alpn,
    }};
    const sh = try makeServerHelloWithExtensions(allocator, &ext);
    defer allocator.free(sh);

    try std.testing.expectError(error.HandshakeFailed, tls_engine.processServerHello(sh));
    try std.testing.expectEqual(engine.HandshakeState.client_hello_sent, tls_engine.state());
    try std.testing.expect(tls_engine.getSelectedAlpn() == null);
    try std.testing.expect(tls_engine.getPeerTransportParams() == null);
}

test "adapter maps zero length ALPN selection during process server hello" {
    const allocator = std.testing.allocator;

    var adapter = LibfastTlsContextAdapter.init(allocator, .client);
    defer adapter.deinit();
    var tls_engine = adapter.asEngine();

    const offered = [_][]const u8{"h3"};
    const ch = try tls_engine.beginClientHandshake("example.com", &offered, &[_]u8{});
    defer tls_engine.freeBuffer(ch);

    const bad_alpn = [_]u8{ 0x00, 0x01, 0x00 };
    const ext = [_]handshake_mod.Extension{.{
        .extension_type = @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation),
        .extension_data = &bad_alpn,
    }};
    const sh = try makeServerHelloWithExtensions(allocator, &ext);
    defer allocator.free(sh);

    try std.testing.expectError(error.HandshakeFailed, tls_engine.processServerHello(sh));
    try std.testing.expectEqual(engine.HandshakeState.client_hello_sent, tls_engine.state());
}

test "adapter unsupported cipher does not mutate client hello state" {
    const allocator = std.testing.allocator;

    var adapter = LibfastTlsContextAdapter.init(allocator, .client);
    defer adapter.deinit();
    var tls_engine = adapter.asEngine();

    const offered = [_][]const u8{"h3"};
    const ch = try tls_engine.beginClientHandshake("example.com", &offered, &[_]u8{});
    defer tls_engine.freeBuffer(ch);

    const random: [32]u8 = [_]u8{0x22} ** 32;
    const sh = handshake_mod.ServerHello{
        .random = random,
        .cipher_suite = 0xDEAD,
        .extensions = &[_]handshake_mod.Extension{},
    };
    const encoded_sh = try sh.encode(allocator);
    defer allocator.free(encoded_sh);

    try std.testing.expectError(error.UnsupportedCipherSuite, tls_engine.processServerHello(encoded_sh));
    try std.testing.expectEqual(engine.HandshakeState.client_hello_sent, tls_engine.state());
    try std.testing.expect(tls_engine.getSelectedAlpn() == null);
    try std.testing.expect(tls_engine.getPeerTransportParams() == null);
}

test "adapter malformed server hello failure is deterministic" {
    const allocator = std.testing.allocator;

    var adapter = LibfastTlsContextAdapter.init(allocator, .client);
    defer adapter.deinit();
    var tls_engine = adapter.asEngine();

    const offered = [_][]const u8{"h3"};
    const ch = try tls_engine.beginClientHandshake("example.com", &offered, &[_]u8{});
    defer tls_engine.freeBuffer(ch);

    try std.testing.expectError(error.HandshakeFailed, tls_engine.processServerHello("bad-server-hello"));
    try std.testing.expectEqual(engine.HandshakeState.client_hello_sent, tls_engine.state());
    try std.testing.expectError(error.HandshakeFailed, tls_engine.processServerHello("bad-server-hello"));
    try std.testing.expectEqual(engine.HandshakeState.client_hello_sent, tls_engine.state());
}

test "adapter malformed client hello build failure is deterministic" {
    const allocator = std.testing.allocator;

    var adapter = LibfastTlsContextAdapter.init(allocator, .server);
    defer adapter.deinit();
    var tls_engine = adapter.asEngine();

    const supported = [_][]const u8{"h3"};

    try std.testing.expectError(
        error.HandshakeFailed,
        tls_engine.buildServerHello("bad-client-hello", &supported, &[_]u8{}),
    );
    try std.testing.expectEqual(engine.HandshakeState.idle, tls_engine.state());

    try std.testing.expectError(
        error.HandshakeFailed,
        tls_engine.buildServerHello("bad-client-hello", &supported, &[_]u8{}),
    );
    try std.testing.expectEqual(engine.HandshakeState.idle, tls_engine.state());
}
