const std = @import("std");
const tls_extensions = @import("extensions.zig");
const tls_finished = @import("finished.zig");
const tls_policy = @import("policy.zig");
const handshake_mod = @import("handshake.zig");
const key_schedule_mod = @import("key_schedule.zig");
const tls_diag = @import("diagnostics.zig");
const keys_mod = @import("../crypto/keys.zig");
const transport_params_mod = @import("../core/transport_params.zig");

pub const TlsError = error{
    HandshakeFailed,
    AlpnMismatch,
    InvalidState,
    UnsupportedCipherSuite,
    OutOfMemory,
} || handshake_mod.HandshakeError || key_schedule_mod.KeyScheduleError;

pub const HandshakeState = enum {
    idle,
    client_hello_sent,
    server_hello_received,
    handshake_complete,
    failed,

    pub fn isComplete(self: HandshakeState) bool {
        return self == .handshake_complete;
    }
};

pub const TlsContext = struct {
    allocator: std.mem.Allocator,
    is_client: bool,
    state: HandshakeState,
    cipher_suite: ?u16 = null,
    key_schedule: ?*key_schedule_mod.KeySchedule = null,
    transcript: std.ArrayList(u8),
    handshake_client_secret: ?[]u8 = null,
    handshake_server_secret: ?[]u8 = null,
    application_client_secret: ?[]u8 = null,
    application_server_secret: ?[]u8 = null,
    selected_alpn: ?[]u8 = null,
    offered_alpn: ?[]u8 = null,
    peer_transport_params: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, is_client: bool) TlsContext {
        return .{
            .allocator = allocator,
            .is_client = is_client,
            .state = .idle,
            .transcript = .{},
        };
    }

    pub fn startClientHandshake(self: *TlsContext, server_name: []const u8) TlsError![]u8 {
        return self.startClientHandshakeWithParams(server_name, &[_][]const u8{}, &[_]u8{});
    }

    pub fn startClientHandshakeWithParams(
        self: *TlsContext,
        server_name: []const u8,
        alpn_protocols: []const []const u8,
        quic_transport_params: []const u8,
    ) TlsError![]u8 {
        if (!self.is_client or self.state != .idle) return error.InvalidState;
        _ = server_name;

        _ = transport_params_mod.TransportParams.decode(self.allocator, quic_transport_params) catch {
            return error.HandshakeFailed;
        };

        if (self.selected_alpn) |alpn| {
            self.allocator.free(alpn);
            self.selected_alpn = null;
        }
        if (self.offered_alpn) |offered| {
            self.allocator.free(offered);
            self.offered_alpn = null;
        }
        if (self.peer_transport_params) |tp| {
            self.allocator.free(tp);
            self.peer_transport_params = null;
        }

        var random: [32]u8 = undefined;
        std.crypto.random.bytes(&random);

        const cipher_suites = [_]u16{
            handshake_mod.TLS_AES_128_GCM_SHA256,
            handshake_mod.TLS_AES_256_GCM_SHA384,
            handshake_mod.TLS_CHACHA20_POLY1305_SHA256,
        };

        var ext_list: [2]handshake_mod.Extension = undefined;
        var ext_count: usize = 0;

        if (alpn_protocols.len > 0) {
            const alpn_data = try encodeAlpnExtensionData(self.allocator, alpn_protocols);
            errdefer self.allocator.free(alpn_data);
            self.offered_alpn = try self.allocator.dupe(u8, alpn_data);
            ext_list[ext_count] = .{
                .extension_type = @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation),
                .extension_data = alpn_data,
            };
            ext_count += 1;
        }

        if (quic_transport_params.len > 0) {
            ext_list[ext_count] = .{
                .extension_type = @intFromEnum(handshake_mod.ExtensionType.quic_transport_parameters),
                .extension_data = quic_transport_params,
            };
            ext_count += 1;
        }

        const client_hello = handshake_mod.ClientHello{
            .random = random,
            .cipher_suites = &cipher_suites,
            .extensions = ext_list[0..ext_count],
        };

        const encoded = try client_hello.encode(self.allocator);
        if (ext_count > 0 and alpn_protocols.len > 0) self.allocator.free(ext_list[0].extension_data);

        self.transcript.clearRetainingCapacity();
        try self.transcript.appendSlice(self.allocator, encoded);
        self.state = .client_hello_sent;
        return encoded;
    }

    pub fn buildServerHelloFromClientHello(
        self: *TlsContext,
        client_hello_data: []const u8,
        server_supported_alpn: []const []const u8,
        quic_transport_params: []const u8,
    ) TlsError![]u8 {
        if (self.is_client or self.state != .idle) return error.InvalidState;

        _ = transport_params_mod.TransportParams.decode(self.allocator, quic_transport_params) catch {
            return error.HandshakeFailed;
        };

        const parsed_client_hello = handshake_mod.parseClientHello(client_hello_data) catch return error.HandshakeFailed;
        const selected_cipher = tls_policy.select_server_cipher_suite(parsed_client_hello.cipher_suites) orelse return error.UnsupportedCipherSuite;

        const selected_alpn = try selectServerAlpnFromClientHello(client_hello_data, server_supported_alpn);
        const selected_alpn_wire = try encodeSelectedAlpnExtensionData(self.allocator, selected_alpn);
        errdefer self.allocator.free(selected_alpn_wire);

        const client_tp = handshake_mod.findUniqueExtension(parsed_client_hello.extensions, @intFromEnum(handshake_mod.ExtensionType.quic_transport_parameters)) catch return error.HandshakeFailed;
        const client_tp_payload = client_tp orelse return error.HandshakeFailed;
        _ = transport_params_mod.TransportParams.decode(self.allocator, client_tp_payload) catch return error.HandshakeFailed;

        const copied_client_tp = try self.allocator.dupe(u8, client_tp_payload);
        errdefer self.allocator.free(copied_client_tp);
        if (self.peer_transport_params) |old_tp| self.allocator.free(old_tp);
        self.peer_transport_params = copied_client_tp;

        if (self.selected_alpn) |old_alpn| self.allocator.free(old_alpn);
        self.selected_alpn = try self.allocator.dupe(u8, selected_alpn);

        var random: [32]u8 = undefined;
        std.crypto.random.bytes(&random);

        const ext = [_]handshake_mod.Extension{
            .{ .extension_type = @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation), .extension_data = selected_alpn_wire },
            .{ .extension_type = @intFromEnum(handshake_mod.ExtensionType.quic_transport_parameters), .extension_data = quic_transport_params },
        };

        const server_hello = handshake_mod.ServerHello{ .random = random, .cipher_suite = selected_cipher, .extensions = &ext };
        const encoded = try server_hello.encode(self.allocator);
        self.allocator.free(selected_alpn_wire);

        self.transcript.clearRetainingCapacity();
        try self.transcript.appendSlice(self.allocator, client_hello_data);
        try self.transcript.appendSlice(self.allocator, encoded);

        self.cipher_suite = selected_cipher;
        self.state = .server_hello_received;
        return encoded;
    }

    pub fn processServerHello(self: *TlsContext, server_hello_data: []const u8) TlsError!void {
        if (!self.is_client or self.state != .client_hello_sent) return error.InvalidState;

        const parsed = handshake_mod.parseServerHello(server_hello_data) catch return error.HandshakeFailed;
        self.cipher_suite = try requireSupportedCipherSuite(parsed.cipher_suite);
        try self.applyServerHelloExtensions(parsed.extensions);
        try self.transcript.appendSlice(self.allocator, server_hello_data);
        self.state = .server_hello_received;
    }

    pub fn completeHandshake(self: *TlsContext, shared_secret: []const u8) TlsError!void {
        if (self.state != .server_hello_received) return error.InvalidState;

        const hash_alg = tls_policy.hash_algorithm_for_cipher_suite(self.cipher_suite orelse handshake_mod.TLS_AES_128_GCM_SHA256) catch return error.UnsupportedCipherSuite;

        try self.deriveAndInstallTrafficSecrets(hash_alg, shared_secret);
        self.state = .handshake_complete;
    }

    fn deriveAndInstallTrafficSecrets(
        self: *TlsContext,
        hash_alg: key_schedule_mod.HashAlgorithm,
        shared_secret: []const u8,
    ) TlsError!void {
        var ks = try key_schedule_mod.KeySchedule.init(self.allocator, hash_alg);
        errdefer ks.deinit();

        const early_secret = try ks.deriveEarlySecret(null);
        defer self.allocator.free(early_secret);
        const handshake_secret = try ks.deriveHandshakeSecret(early_secret, shared_secret);
        defer self.allocator.free(handshake_secret);

        ks.updateTranscript(self.transcript.items);

        const hs_secrets = try ks.deriveHandshakeTrafficSecrets(handshake_secret);
        errdefer {
            @memset(hs_secrets.client, 0);
            self.allocator.free(hs_secrets.client);
            @memset(hs_secrets.server, 0);
            self.allocator.free(hs_secrets.server);
        }

        const master_secret = try ks.deriveMasterSecret(handshake_secret);
        defer self.allocator.free(master_secret);

        const app_secrets = try ks.deriveApplicationTrafficSecrets(master_secret);
        errdefer {
            @memset(app_secrets.client, 0);
            self.allocator.free(app_secrets.client);
            @memset(app_secrets.server, 0);
            self.allocator.free(app_secrets.server);
        }

        self.handshake_client_secret = hs_secrets.client;
        self.handshake_server_secret = hs_secrets.server;
        self.application_client_secret = app_secrets.client;
        self.application_server_secret = app_secrets.server;

        const ks_ptr = try self.allocator.create(key_schedule_mod.KeySchedule);
        ks_ptr.* = ks;
        self.key_schedule = ks_ptr;
    }

    fn applyServerHelloExtensions(self: *TlsContext, extensions: []const u8) TlsError!void {
        try self.maybeStoreSelectedAlpn(extensions);
        try self.verifySelectedAlpnAgainstOffer();
        try self.maybeStorePeerTransportParams(extensions);
    }

    fn requireSupportedCipherSuite(cipher_suite: u16) TlsError!u16 {
        return switch (cipher_suite) {
            handshake_mod.TLS_AES_128_GCM_SHA256,
            handshake_mod.TLS_AES_256_GCM_SHA384,
            handshake_mod.TLS_CHACHA20_POLY1305_SHA256,
            => cipher_suite,
            else => error.UnsupportedCipherSuite,
        };
    }

    pub fn getSelectedAlpn(self: *const TlsContext) ?[]const u8 {
        return self.selected_alpn;
    }

    pub fn getPeerTransportParams(self: *const TlsContext) ?[]const u8 {
        return self.peer_transport_params;
    }

    pub fn diagnosticsSnapshot(self: *const TlsContext, last_error: ?[]const u8) tls_diag.HandshakeDiagnostics {
        return tls_diag.build_handshake_diagnostics(
            self.state,
            self.cipher_suite,
            self.selected_alpn,
            self.peer_transport_params,
            last_error,
            self.handshake_client_secret,
            self.application_client_secret,
        );
    }

    pub fn selectServerAlpn(offered_alpn_wire: []const u8, server_supported: []const []const u8) TlsError![]const u8 {
        tls_extensions.validate_alpn_list_wire(offered_alpn_wire) catch return error.HandshakeFailed;

        for (server_supported) |candidate| {
            if (candidate.len == 0) continue;
            if (tls_extensions.offered_alpn_contains(offered_alpn_wire, candidate)) return candidate;
        }
        return error.AlpnMismatch;
    }

    pub fn selectServerAlpnFromClientHello(client_hello_data: []const u8, server_supported: []const []const u8) TlsError![]const u8 {
        const parsed = handshake_mod.parseClientHello(client_hello_data) catch return error.HandshakeFailed;
        const offered_alpn = handshake_mod.findUniqueExtension(parsed.extensions, @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation)) catch return error.HandshakeFailed;
        const offered_alpn_wire = offered_alpn orelse return error.HandshakeFailed;
        return selectServerAlpn(offered_alpn_wire, server_supported);
    }

    pub fn encodeSelectedAlpnExtensionData(allocator: std.mem.Allocator, selected: []const u8) TlsError![]u8 {
        if (selected.len == 0 or selected.len > 255) return error.HandshakeFailed;
        const out = try allocator.alloc(u8, selected.len + 3);
        out[0] = @intCast(((selected.len + 1) >> 8) & 0xFF);
        out[1] = @intCast((selected.len + 1) & 0xFF);
        out[2] = @intCast(selected.len);
        @memcpy(out[3 .. 3 + selected.len], selected);
        return out;
    }

    fn encodeAlpnExtensionData(allocator: std.mem.Allocator, protocols: []const []const u8) TlsError![]u8 {
        var list_len: usize = 0;
        for (protocols) |protocol| {
            if (protocol.len == 0 or protocol.len > 255) return error.HandshakeFailed;
            list_len += 1 + protocol.len;
        }
        if (list_len > std.math.maxInt(u16)) return error.HandshakeFailed;

        var out = try allocator.alloc(u8, list_len + 2);
        var pos: usize = 0;
        out[pos] = @intCast((list_len >> 8) & 0xFF);
        pos += 1;
        out[pos] = @intCast(list_len & 0xFF);
        pos += 1;

        for (protocols) |protocol| {
            out[pos] = @intCast(protocol.len);
            pos += 1;
            @memcpy(out[pos..][0..protocol.len], protocol);
            pos += protocol.len;
        }

        return out;
    }

    fn verifyFinishedData(
        self: *TlsContext,
        ks: *key_schedule_mod.KeySchedule,
        server_handshake_secret: []const u8,
        peer_verify_data: []const u8,
    ) TlsError!void {
        tls_finished.verify_finished_data(self.allocator, ks, server_handshake_secret, peer_verify_data) catch return error.HandshakeFailed;
    }

    fn maybeStoreSelectedAlpn(self: *TlsContext, extensions: []const u8) TlsError!void {
        const alpn_data_opt = handshake_mod.findUniqueExtension(extensions, @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation)) catch return error.HandshakeFailed;
        const alpn_data = alpn_data_opt orelse return;
        const selected_slice = tls_extensions.parse_selected_alpn(alpn_data) catch return error.HandshakeFailed;
        const selected = try self.allocator.dupe(u8, selected_slice);
        if (self.selected_alpn) |old| self.allocator.free(old);
        self.selected_alpn = selected;
    }

    fn verifySelectedAlpnAgainstOffer(self: *TlsContext) TlsError!void {
        const offered = self.offered_alpn orelse return;
        const selected = self.selected_alpn orelse return error.HandshakeFailed;
        if (!tls_extensions.offered_alpn_contains(offered, selected)) return error.AlpnMismatch;
    }

    fn maybeStorePeerTransportParams(self: *TlsContext, extensions: []const u8) TlsError!void {
        const tp_data_opt = handshake_mod.findUniqueExtension(extensions, @intFromEnum(handshake_mod.ExtensionType.quic_transport_parameters)) catch return error.HandshakeFailed;
        const tp_data = tp_data_opt orelse return;

        _ = transport_params_mod.TransportParams.decode(self.allocator, tp_data) catch return error.HandshakeFailed;
        const copied = try self.allocator.dupe(u8, tp_data);
        if (self.peer_transport_params) |old| self.allocator.free(old);
        self.peer_transport_params = copied;
    }

    pub fn deinit(self: *TlsContext) void {
        if (self.handshake_client_secret) |secret| {
            @memset(secret, 0);
            self.allocator.free(secret);
        }
        if (self.handshake_server_secret) |secret| {
            @memset(secret, 0);
            self.allocator.free(secret);
        }
        if (self.application_client_secret) |secret| {
            @memset(secret, 0);
            self.allocator.free(secret);
        }
        if (self.application_server_secret) |secret| {
            @memset(secret, 0);
            self.allocator.free(secret);
        }
        if (self.selected_alpn) |alpn| self.allocator.free(alpn);
        if (self.offered_alpn) |offered| self.allocator.free(offered);
        if (self.peer_transport_params) |tp| self.allocator.free(tp);

        if (self.key_schedule) |ks| {
            ks.deinit();
            self.allocator.destroy(ks);
        }
        self.transcript.deinit(self.allocator);
    }
};

test "tls context client server flow" {
    const allocator = std.testing.allocator;

    var client = TlsContext.init(allocator, true);
    defer client.deinit();
    var server = TlsContext.init(allocator, false);
    defer server.deinit();

    const offered = [_][]const u8{"h3"};
    var ctp = transport_params_mod.TransportParams.defaultClient();
    const ctp_bytes = try ctp.encode(allocator);
    defer allocator.free(ctp_bytes);

    var stp = transport_params_mod.TransportParams.defaultServer();
    const stp_bytes = try stp.encode(allocator);
    defer allocator.free(stp_bytes);

    const ch = try client.startClientHandshakeWithParams("example.com", &offered, ctp_bytes);
    defer allocator.free(ch);

    const sh = try server.buildServerHelloFromClientHello(ch, &offered, stp_bytes);
    defer allocator.free(sh);

    try client.processServerHello(sh);
    try client.completeHandshake("shared-secret");
    try server.completeHandshake("shared-secret");

    try std.testing.expect(client.state.isComplete());
    try std.testing.expect(server.state.isComplete());
}

fn makeServerHelloWithExtensions(
    allocator: std.mem.Allocator,
    extensions: []const handshake_mod.Extension,
) ![]u8 {
    const random: [32]u8 = [_]u8{77} ** 32;
    const msg = handshake_mod.ServerHello{
        .random = random,
        .cipher_suite = handshake_mod.TLS_AES_128_GCM_SHA256,
        .extensions = extensions,
    };
    return msg.encode(allocator);
}

test "process server hello rejects malformed ALPN extension payload" {
    const allocator = std.testing.allocator;

    var ctx = TlsContext.init(allocator, true);
    defer ctx.deinit();

    const offered = [_][]const u8{"h3"};
    const params = transport_params_mod.TransportParams.defaultClient();
    const encoded_params = try params.encode(allocator);
    defer allocator.free(encoded_params);

    const ch = try ctx.startClientHandshakeWithParams("example.com", &offered, encoded_params);
    defer allocator.free(ch);

    const bad_alpn = [_]u8{ 0x00, 0x04, 0x02, 'h', '3' };
    const ext = [_]handshake_mod.Extension{.{
        .extension_type = @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation),
        .extension_data = &bad_alpn,
    }};
    const sh = try makeServerHelloWithExtensions(allocator, &ext);
    defer allocator.free(sh);

    try std.testing.expectError(error.HandshakeFailed, ctx.processServerHello(sh));
}

test "process server hello rejects zero-length selected ALPN" {
    const allocator = std.testing.allocator;

    var ctx = TlsContext.init(allocator, true);
    defer ctx.deinit();

    const offered = [_][]const u8{"h3"};
    const params = transport_params_mod.TransportParams.defaultClient();
    const encoded_params = try params.encode(allocator);
    defer allocator.free(encoded_params);

    const ch = try ctx.startClientHandshakeWithParams("example.com", &offered, encoded_params);
    defer allocator.free(ch);

    const bad_alpn = [_]u8{ 0x00, 0x01, 0x00 };
    const ext = [_]handshake_mod.Extension{.{
        .extension_type = @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation),
        .extension_data = &bad_alpn,
    }};
    const sh = try makeServerHelloWithExtensions(allocator, &ext);
    defer allocator.free(sh);

    try std.testing.expectError(error.HandshakeFailed, ctx.processServerHello(sh));
}

test "process server hello rejects invalid transport parameters extension payload" {
    const allocator = std.testing.allocator;

    var ctx = TlsContext.init(allocator, true);
    defer ctx.deinit();

    const offered = [_][]const u8{"h3"};
    const params = transport_params_mod.TransportParams.defaultClient();
    const encoded_params = try params.encode(allocator);
    defer allocator.free(encoded_params);

    const ch = try ctx.startClientHandshakeWithParams("example.com", &offered, encoded_params);
    defer allocator.free(ch);

    const bad_tp = [_]u8{ 0x03, 0x02, 0x44, 0xAF };
    const ext = [_]handshake_mod.Extension{.{
        .extension_type = @intFromEnum(handshake_mod.ExtensionType.quic_transport_parameters),
        .extension_data = &bad_tp,
    }};
    const sh = try makeServerHelloWithExtensions(allocator, &ext);
    defer allocator.free(sh);

    try std.testing.expectError(error.HandshakeFailed, ctx.processServerHello(sh));
}

test "process server hello returns ALPN mismatch when server selects non-offered protocol" {
    const allocator = std.testing.allocator;

    var ctx = TlsContext.init(allocator, true);
    defer ctx.deinit();

    const offered = [_][]const u8{"h3"};
    const params = transport_params_mod.TransportParams.defaultClient();
    const encoded_params = try params.encode(allocator);
    defer allocator.free(encoded_params);

    const ch = try ctx.startClientHandshakeWithParams("example.com", &offered, encoded_params);
    defer allocator.free(ch);

    const alpn_h2 = [_]u8{ 0x00, 0x03, 0x02, 'h', '2' };
    const ext = [_]handshake_mod.Extension{.{
        .extension_type = @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation),
        .extension_data = &alpn_h2,
    }};
    const sh = try makeServerHelloWithExtensions(allocator, &ext);
    defer allocator.free(sh);

    try std.testing.expectError(error.AlpnMismatch, ctx.processServerHello(sh));
}

test "process server hello rejects duplicate ALPN extensions" {
    const allocator = std.testing.allocator;

    var ctx = TlsContext.init(allocator, true);
    defer ctx.deinit();

    const offered = [_][]const u8{"h3"};
    const params = transport_params_mod.TransportParams.defaultClient();
    const encoded_params = try params.encode(allocator);
    defer allocator.free(encoded_params);

    const ch = try ctx.startClientHandshakeWithParams("example.com", &offered, encoded_params);
    defer allocator.free(ch);

    const alpn_h3 = [_]u8{ 0x00, 0x03, 0x02, 'h', '3' };
    const ext = [_]handshake_mod.Extension{
        .{ .extension_type = @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation), .extension_data = &alpn_h3 },
        .{ .extension_type = @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation), .extension_data = &alpn_h3 },
    };
    const sh = try makeServerHelloWithExtensions(allocator, &ext);
    defer allocator.free(sh);

    try std.testing.expectError(error.HandshakeFailed, ctx.processServerHello(sh));
}

test "process server hello rejects duplicate transport parameter extensions" {
    const allocator = std.testing.allocator;

    var ctx = TlsContext.init(allocator, true);
    defer ctx.deinit();

    const offered = [_][]const u8{"h3"};
    const params = transport_params_mod.TransportParams.defaultClient();
    const encoded_params = try params.encode(allocator);
    defer allocator.free(encoded_params);

    const ch = try ctx.startClientHandshakeWithParams("example.com", &offered, encoded_params);
    defer allocator.free(ch);

    var server_tp = transport_params_mod.TransportParams.defaultServer();
    const server_tp_encoded = try server_tp.encode(allocator);
    defer allocator.free(server_tp_encoded);

    const ext = [_]handshake_mod.Extension{
        .{ .extension_type = @intFromEnum(handshake_mod.ExtensionType.quic_transport_parameters), .extension_data = server_tp_encoded },
        .{ .extension_type = @intFromEnum(handshake_mod.ExtensionType.quic_transport_parameters), .extension_data = server_tp_encoded },
    };
    const sh = try makeServerHelloWithExtensions(allocator, &ext);
    defer allocator.free(sh);

    try std.testing.expectError(error.HandshakeFailed, ctx.processServerHello(sh));
}

test "process server hello failure preserves client state and extracted fields" {
    const allocator = std.testing.allocator;

    var ctx = TlsContext.init(allocator, true);
    defer ctx.deinit();

    const offered = [_][]const u8{"h3"};
    const params = transport_params_mod.TransportParams.defaultClient();
    const encoded_params = try params.encode(allocator);
    defer allocator.free(encoded_params);

    const ch = try ctx.startClientHandshakeWithParams("example.com", &offered, encoded_params);
    defer allocator.free(ch);

    const bad_tp = [_]u8{ 0x03, 0x02, 0x44, 0xAF };
    const ext = [_]handshake_mod.Extension{.{
        .extension_type = @intFromEnum(handshake_mod.ExtensionType.quic_transport_parameters),
        .extension_data = &bad_tp,
    }};
    const sh = try makeServerHelloWithExtensions(allocator, &ext);
    defer allocator.free(sh);

    try std.testing.expectError(error.HandshakeFailed, ctx.processServerHello(sh));
    try std.testing.expectEqual(HandshakeState.client_hello_sent, ctx.state);
    try std.testing.expect(ctx.getSelectedAlpn() == null);
    try std.testing.expect(ctx.getPeerTransportParams() == null);
}

test "select server alpn rejects malformed offered wire" {
    const server_supported = [_][]const u8{"h3"};
    const malformed = [_]u8{ 0x00, 0x05, 0x02, 'h', '3' };
    try std.testing.expectError(error.HandshakeFailed, TlsContext.selectServerAlpn(&malformed, &server_supported));
}

test "select server alpn from client hello requires ALPN extension" {
    const allocator = std.testing.allocator;

    const suites = [_]u16{handshake_mod.TLS_AES_128_GCM_SHA256};
    const random: [32]u8 = [_]u8{0x99} ** 32;
    const tp_payload = [_]u8{0x00};
    const extensions = [_]handshake_mod.Extension{.{
        .extension_type = @intFromEnum(handshake_mod.ExtensionType.quic_transport_parameters),
        .extension_data = &tp_payload,
    }};

    const ch = handshake_mod.ClientHello{
        .random = random,
        .cipher_suites = &suites,
        .extensions = &extensions,
    };
    const encoded = try ch.encode(allocator);
    defer allocator.free(encoded);

    const server_supported = [_][]const u8{"h3"};
    try std.testing.expectError(
        error.HandshakeFailed,
        TlsContext.selectServerAlpnFromClientHello(encoded, &server_supported),
    );
}

test "build server hello rejects client hello without transport parameters" {
    const allocator = std.testing.allocator;

    var server = TlsContext.init(allocator, false);
    defer server.deinit();

    const suites = [_]u16{handshake_mod.TLS_AES_128_GCM_SHA256};
    const random: [32]u8 = [_]u8{0x42} ** 32;
    const alpn_offer = [_]u8{ 0x00, 0x03, 0x02, 'h', '3' };
    const client_ext = [_]handshake_mod.Extension{.{
        .extension_type = @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation),
        .extension_data = &alpn_offer,
    }};
    const ch = handshake_mod.ClientHello{
        .random = random,
        .cipher_suites = &suites,
        .extensions = &client_ext,
    };
    const ch_bytes = try ch.encode(allocator);
    defer allocator.free(ch_bytes);

    var server_tp = transport_params_mod.TransportParams.defaultServer();
    const server_tp_encoded = try server_tp.encode(allocator);
    defer allocator.free(server_tp_encoded);

    const supported = [_][]const u8{"h3"};
    try std.testing.expectError(
        error.HandshakeFailed,
        server.buildServerHelloFromClientHello(ch_bytes, &supported, server_tp_encoded),
    );

    try std.testing.expectEqual(HandshakeState.idle, server.state);
    try std.testing.expect(server.getSelectedAlpn() == null);
    try std.testing.expect(server.getPeerTransportParams() == null);
}

test "build server hello rejects duplicate client transport parameters" {
    const allocator = std.testing.allocator;

    var server = TlsContext.init(allocator, false);
    defer server.deinit();

    var client_tp = transport_params_mod.TransportParams.defaultClient();
    const client_tp_encoded = try client_tp.encode(allocator);
    defer allocator.free(client_tp_encoded);

    const suites = [_]u16{handshake_mod.TLS_AES_128_GCM_SHA256};
    const random: [32]u8 = [_]u8{0x43} ** 32;
    const alpn_offer = [_]u8{ 0x00, 0x03, 0x02, 'h', '3' };
    const client_ext = [_]handshake_mod.Extension{
        .{ .extension_type = @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation), .extension_data = &alpn_offer },
        .{ .extension_type = @intFromEnum(handshake_mod.ExtensionType.quic_transport_parameters), .extension_data = client_tp_encoded },
        .{ .extension_type = @intFromEnum(handshake_mod.ExtensionType.quic_transport_parameters), .extension_data = client_tp_encoded },
    };
    const ch = handshake_mod.ClientHello{
        .random = random,
        .cipher_suites = &suites,
        .extensions = &client_ext,
    };
    const ch_bytes = try ch.encode(allocator);
    defer allocator.free(ch_bytes);

    var server_tp = transport_params_mod.TransportParams.defaultServer();
    const server_tp_encoded = try server_tp.encode(allocator);
    defer allocator.free(server_tp_encoded);

    const supported = [_][]const u8{"h3"};
    try std.testing.expectError(
        error.HandshakeFailed,
        server.buildServerHelloFromClientHello(ch_bytes, &supported, server_tp_encoded),
    );

    try std.testing.expectEqual(HandshakeState.idle, server.state);
    try std.testing.expect(server.getPeerTransportParams() == null);
}

test "build server hello stores selected alpn and client transport params" {
    const allocator = std.testing.allocator;

    var client = TlsContext.init(allocator, true);
    defer client.deinit();
    var server = TlsContext.init(allocator, false);
    defer server.deinit();

    const offered = [_][]const u8{"h3"};
    var client_tp = transport_params_mod.TransportParams.defaultClient();
    const client_tp_encoded = try client_tp.encode(allocator);
    defer allocator.free(client_tp_encoded);

    var server_tp = transport_params_mod.TransportParams.defaultServer();
    const server_tp_encoded = try server_tp.encode(allocator);
    defer allocator.free(server_tp_encoded);

    const ch = try client.startClientHandshakeWithParams("example.com", &offered, client_tp_encoded);
    defer allocator.free(ch);

    const sh = try server.buildServerHelloFromClientHello(ch, &offered, server_tp_encoded);
    defer allocator.free(sh);

    try std.testing.expectEqual(HandshakeState.server_hello_received, server.state);
    const selected_alpn = server.getSelectedAlpn() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("h3", selected_alpn);
    const peer_tp = server.getPeerTransportParams() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, client_tp_encoded, peer_tp);
}

test "build server hello ALPN mismatch does not mutate server state" {
    const allocator = std.testing.allocator;

    var client = TlsContext.init(allocator, true);
    defer client.deinit();
    var server = TlsContext.init(allocator, false);
    defer server.deinit();

    const offered = [_][]const u8{"h3"};
    const unsupported = [_][]const u8{"h2"};

    var client_tp = transport_params_mod.TransportParams.defaultClient();
    const client_tp_encoded = try client_tp.encode(allocator);
    defer allocator.free(client_tp_encoded);

    var server_tp = transport_params_mod.TransportParams.defaultServer();
    const server_tp_encoded = try server_tp.encode(allocator);
    defer allocator.free(server_tp_encoded);

    const ch = try client.startClientHandshakeWithParams("example.com", &offered, client_tp_encoded);
    defer allocator.free(ch);

    try std.testing.expectError(
        error.AlpnMismatch,
        server.buildServerHelloFromClientHello(ch, &unsupported, server_tp_encoded),
    );

    try std.testing.expectEqual(HandshakeState.idle, server.state);
    try std.testing.expect(server.getSelectedAlpn() == null);
    try std.testing.expect(server.getPeerTransportParams() == null);
}

test "build server hello unsupported cipher offer leaves server idle" {
    const allocator = std.testing.allocator;

    var server = TlsContext.init(allocator, false);
    defer server.deinit();

    const suites = [_]u16{0x00FF};
    const random: [32]u8 = [_]u8{0x11} ** 32;
    const alpn_offer = [_]u8{ 0x00, 0x03, 0x02, 'h', '3' };

    var client_tp = transport_params_mod.TransportParams.defaultClient();
    const client_tp_encoded = try client_tp.encode(allocator);
    defer allocator.free(client_tp_encoded);

    const ext = [_]handshake_mod.Extension{
        .{ .extension_type = @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation), .extension_data = &alpn_offer },
        .{ .extension_type = @intFromEnum(handshake_mod.ExtensionType.quic_transport_parameters), .extension_data = client_tp_encoded },
    };
    const ch = handshake_mod.ClientHello{
        .random = random,
        .cipher_suites = &suites,
        .extensions = &ext,
    };
    const ch_bytes = try ch.encode(allocator);
    defer allocator.free(ch_bytes);

    var server_tp = transport_params_mod.TransportParams.defaultServer();
    const server_tp_encoded = try server_tp.encode(allocator);
    defer allocator.free(server_tp_encoded);

    const supported = [_][]const u8{"h3"};
    try std.testing.expectError(
        error.UnsupportedCipherSuite,
        server.buildServerHelloFromClientHello(ch_bytes, &supported, server_tp_encoded),
    );
    try std.testing.expectEqual(HandshakeState.idle, server.state);
    try std.testing.expect(server.getSelectedAlpn() == null);
    try std.testing.expect(server.getPeerTransportParams() == null);
}

test "build server hello rejects client hello without ALPN extension" {
    const allocator = std.testing.allocator;

    var server = TlsContext.init(allocator, false);
    defer server.deinit();

    var client_tp = transport_params_mod.TransportParams.defaultClient();
    const client_tp_encoded = try client_tp.encode(allocator);
    defer allocator.free(client_tp_encoded);

    const suites = [_]u16{handshake_mod.TLS_AES_128_GCM_SHA256};
    const ext = [_]handshake_mod.Extension{.{
        .extension_type = @intFromEnum(handshake_mod.ExtensionType.quic_transport_parameters),
        .extension_data = client_tp_encoded,
    }};
    const ch = handshake_mod.ClientHello{
        .random = [_]u8{0x21} ** 32,
        .cipher_suites = &suites,
        .extensions = &ext,
    };
    const ch_bytes = try ch.encode(allocator);
    defer allocator.free(ch_bytes);

    var server_tp = transport_params_mod.TransportParams.defaultServer();
    const server_tp_encoded = try server_tp.encode(allocator);
    defer allocator.free(server_tp_encoded);

    const supported = [_][]const u8{"h3"};
    try std.testing.expectError(
        error.HandshakeFailed,
        server.buildServerHelloFromClientHello(ch_bytes, &supported, server_tp_encoded),
    );
    try std.testing.expectEqual(HandshakeState.idle, server.state);
    try std.testing.expect(server.getSelectedAlpn() == null);
    try std.testing.expect(server.getPeerTransportParams() == null);
}

test "build server hello rejects malformed client ALPN extension payload" {
    const allocator = std.testing.allocator;

    var server = TlsContext.init(allocator, false);
    defer server.deinit();

    var client_tp = transport_params_mod.TransportParams.defaultClient();
    const client_tp_encoded = try client_tp.encode(allocator);
    defer allocator.free(client_tp_encoded);

    const bad_alpn = [_]u8{ 0x00, 0x04, 0x02, 'h', '3' };
    const suites = [_]u16{handshake_mod.TLS_AES_128_GCM_SHA256};
    const ext = [_]handshake_mod.Extension{
        .{ .extension_type = @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation), .extension_data = &bad_alpn },
        .{ .extension_type = @intFromEnum(handshake_mod.ExtensionType.quic_transport_parameters), .extension_data = client_tp_encoded },
    };
    const ch = handshake_mod.ClientHello{
        .random = [_]u8{0x31} ** 32,
        .cipher_suites = &suites,
        .extensions = &ext,
    };
    const ch_bytes = try ch.encode(allocator);
    defer allocator.free(ch_bytes);

    var server_tp = transport_params_mod.TransportParams.defaultServer();
    const server_tp_encoded = try server_tp.encode(allocator);
    defer allocator.free(server_tp_encoded);

    const supported = [_][]const u8{"h3"};
    try std.testing.expectError(
        error.HandshakeFailed,
        server.buildServerHelloFromClientHello(ch_bytes, &supported, server_tp_encoded),
    );
    try std.testing.expectEqual(HandshakeState.idle, server.state);
}

test "process server hello rejects unsupported cipher without mutating client state" {
    const allocator = std.testing.allocator;

    var client = TlsContext.init(allocator, true);
    defer client.deinit();

    const offered = [_][]const u8{"h3"};
    var client_tp = transport_params_mod.TransportParams.defaultClient();
    const client_tp_encoded = try client_tp.encode(allocator);
    defer allocator.free(client_tp_encoded);

    const ch = try client.startClientHandshakeWithParams("example.com", &offered, client_tp_encoded);
    defer allocator.free(ch);

    const sh = handshake_mod.ServerHello{
        .random = [_]u8{0x41} ** 32,
        .cipher_suite = 0xDEAD,
        .extensions = &[_]handshake_mod.Extension{},
    };
    const sh_bytes = try sh.encode(allocator);
    defer allocator.free(sh_bytes);

    try std.testing.expectError(error.UnsupportedCipherSuite, client.processServerHello(sh_bytes));
    try std.testing.expectEqual(HandshakeState.client_hello_sent, client.state);
    try std.testing.expect(client.cipher_suite == null);
    try std.testing.expect(client.getSelectedAlpn() == null);
    try std.testing.expect(client.getPeerTransportParams() == null);
}

test "process server hello rejects malformed payload without mutating client state" {
    const allocator = std.testing.allocator;

    var client = TlsContext.init(allocator, true);
    defer client.deinit();

    const offered = [_][]const u8{"h3"};
    var client_tp = transport_params_mod.TransportParams.defaultClient();
    const client_tp_encoded = try client_tp.encode(allocator);
    defer allocator.free(client_tp_encoded);

    const ch = try client.startClientHandshakeWithParams("example.com", &offered, client_tp_encoded);
    defer allocator.free(ch);

    const malformed = [_]u8{ 0x02, 0x00, 0x01, 0x00 };
    try std.testing.expectError(error.HandshakeFailed, client.processServerHello(&malformed));
    try std.testing.expectEqual(HandshakeState.client_hello_sent, client.state);
    try std.testing.expect(client.cipher_suite == null);
    try std.testing.expect(client.getSelectedAlpn() == null);
    try std.testing.expect(client.getPeerTransportParams() == null);
}

test "complete handshake unsupported cipher returns error without state change" {
    const allocator = std.testing.allocator;

    var ctx = TlsContext.init(allocator, true);
    defer ctx.deinit();

    ctx.state = .server_hello_received;
    ctx.cipher_suite = 0x9999;

    try std.testing.expectError(error.UnsupportedCipherSuite, ctx.completeHandshake("shared-secret"));
    try std.testing.expectEqual(HandshakeState.server_hello_received, ctx.state);
}

test "complete handshake derives sha256 secrets and marks complete" {
    const allocator = std.testing.allocator;

    var ctx = TlsContext.init(allocator, true);
    defer ctx.deinit();

    const offered = [_][]const u8{"h3"};
    var client_tp = transport_params_mod.TransportParams.defaultClient();
    const client_tp_encoded = try client_tp.encode(allocator);
    defer allocator.free(client_tp_encoded);

    var server_tp = transport_params_mod.TransportParams.defaultServer();
    const server_tp_encoded = try server_tp.encode(allocator);
    defer allocator.free(server_tp_encoded);

    const ch = try ctx.startClientHandshakeWithParams("example.com", &offered, client_tp_encoded);
    defer allocator.free(ch);

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
    const sh = try makeServerHelloWithExtensions(allocator, &ext);
    defer allocator.free(sh);

    try ctx.processServerHello(sh);
    try ctx.completeHandshake("shared-secret");

    try std.testing.expectEqual(HandshakeState.handshake_complete, ctx.state);
    try std.testing.expect(ctx.key_schedule != null);
    try std.testing.expectEqual(key_schedule_mod.HashAlgorithm.sha256, ctx.key_schedule.?.hash_alg);
    try std.testing.expectEqual(@as(usize, 32), ctx.handshake_client_secret.?.len);
    try std.testing.expectEqual(@as(usize, 32), ctx.handshake_server_secret.?.len);
    try std.testing.expectEqual(@as(usize, 32), ctx.application_client_secret.?.len);
    try std.testing.expectEqual(@as(usize, 32), ctx.application_server_secret.?.len);
}

test "complete handshake uses sha384 schedule for aes256 suite" {
    const allocator = std.testing.allocator;

    var ctx = TlsContext.init(allocator, true);
    defer ctx.deinit();

    ctx.state = .server_hello_received;
    ctx.cipher_suite = handshake_mod.TLS_AES_256_GCM_SHA384;
    try ctx.transcript.appendSlice(allocator, "transcript");

    try ctx.completeHandshake("shared-secret");

    try std.testing.expectEqual(HandshakeState.handshake_complete, ctx.state);
    try std.testing.expect(ctx.key_schedule != null);
    try std.testing.expectEqual(key_schedule_mod.HashAlgorithm.sha384, ctx.key_schedule.?.hash_alg);
    try std.testing.expectEqual(@as(usize, 48), ctx.handshake_client_secret.?.len);
    try std.testing.expectEqual(@as(usize, 48), ctx.handshake_server_secret.?.len);
    try std.testing.expectEqual(@as(usize, 48), ctx.application_client_secret.?.len);
    try std.testing.expectEqual(@as(usize, 48), ctx.application_server_secret.?.len);
}

test "tls hash algorithm mapping follows cipher suite" {
    try std.testing.expectEqual(
        key_schedule_mod.HashAlgorithm.sha256,
        try tls_policy.hash_algorithm_for_cipher_suite(handshake_mod.TLS_AES_128_GCM_SHA256),
    );
    try std.testing.expectEqual(
        key_schedule_mod.HashAlgorithm.sha256,
        try tls_policy.hash_algorithm_for_cipher_suite(handshake_mod.TLS_CHACHA20_POLY1305_SHA256),
    );
    try std.testing.expectEqual(
        key_schedule_mod.HashAlgorithm.sha384,
        try tls_policy.hash_algorithm_for_cipher_suite(handshake_mod.TLS_AES_256_GCM_SHA384),
    );
    try std.testing.expectError(error.UnsupportedCipherSuite, tls_policy.hash_algorithm_for_cipher_suite(0xDEAD));
}

test "validate ALPN list wire guards malformed lengths" {
    try std.testing.expectError(error.InvalidAlpnWire, tls_extensions.validate_alpn_list_wire(&[_]u8{0x00}));
    try std.testing.expectError(error.InvalidAlpnWire, tls_extensions.validate_alpn_list_wire(&[_]u8{ 0x00, 0x02, 0x01 }));
    try tls_extensions.validate_alpn_list_wire(&[_]u8{ 0x00, 0x02, 0x01, 'h' });
}

test "encode selected ALPN extension validates length bounds" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.HandshakeFailed, TlsContext.encodeSelectedAlpnExtensionData(allocator, ""));

    const oversized = try allocator.alloc(u8, 256);
    defer allocator.free(oversized);
    @memset(oversized, 'a');
    try std.testing.expectError(
        error.HandshakeFailed,
        TlsContext.encodeSelectedAlpnExtensionData(allocator, oversized),
    );
}

test "select server ALPN follows server preference order" {
    const offered_wire = [_]u8{ 0x00, 0x06, 0x02, 'h', '2', 0x02, 'h', '3' };
    const server_prefers_h3 = [_][]const u8{ "h3", "h2" };
    const selected = try TlsContext.selectServerAlpn(&offered_wire, &server_prefers_h3);
    try std.testing.expectEqualStrings("h3", selected);
}

test "process server hello succeeds without ALPN when none offered" {
    const allocator = std.testing.allocator;

    var ctx = TlsContext.init(allocator, true);
    defer ctx.deinit();

    var client_tp = transport_params_mod.TransportParams.defaultClient();
    const client_tp_encoded = try client_tp.encode(allocator);
    defer allocator.free(client_tp_encoded);

    var server_tp = transport_params_mod.TransportParams.defaultServer();
    const server_tp_encoded = try server_tp.encode(allocator);
    defer allocator.free(server_tp_encoded);

    const ch = try ctx.startClientHandshakeWithParams("example.com", &[_][]const u8{}, client_tp_encoded);
    defer allocator.free(ch);

    const ext = [_]handshake_mod.Extension{.{
        .extension_type = @intFromEnum(handshake_mod.ExtensionType.quic_transport_parameters),
        .extension_data = server_tp_encoded,
    }};
    const sh = try makeServerHelloWithExtensions(allocator, &ext);
    defer allocator.free(sh);

    try ctx.processServerHello(sh);
    try std.testing.expectEqual(HandshakeState.server_hello_received, ctx.state);
    try std.testing.expect(ctx.getSelectedAlpn() == null);

    const peer_tp = ctx.getPeerTransportParams() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, server_tp_encoded, peer_tp);
}

test "process server hello accepts out of order ALPN and transport extensions" {
    const allocator = std.testing.allocator;

    var client = TlsContext.init(allocator, true);
    defer client.deinit();

    const offered = [_][]const u8{"h3"};
    var client_tp = transport_params_mod.TransportParams.defaultClient();
    const client_tp_encoded = try client_tp.encode(allocator);
    defer allocator.free(client_tp_encoded);

    var server_tp = transport_params_mod.TransportParams.defaultServer();
    const server_tp_encoded = try server_tp.encode(allocator);
    defer allocator.free(server_tp_encoded);

    const ch = try client.startClientHandshakeWithParams("example.com", &offered, client_tp_encoded);
    defer allocator.free(ch);

    const ext = [_]handshake_mod.Extension{
        .{
            .extension_type = @intFromEnum(handshake_mod.ExtensionType.quic_transport_parameters),
            .extension_data = server_tp_encoded,
        },
        .{
            .extension_type = @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation),
            .extension_data = &[_]u8{ 0x00, 0x03, 0x02, 'h', '3' },
        },
    };
    const sh = try makeServerHelloWithExtensions(allocator, &ext);
    defer allocator.free(sh);

    try client.processServerHello(sh);
    try std.testing.expectEqual(HandshakeState.server_hello_received, client.state);
    try std.testing.expectEqualStrings("h3", client.getSelectedAlpn().?);
    try std.testing.expectEqualSlices(u8, server_tp_encoded, client.getPeerTransportParams().?);
}

test "tls context diagnostics snapshot redacts secrets and reports state" {
    const allocator = std.testing.allocator;
    var ctx = TlsContext.init(allocator, true);
    defer ctx.deinit();

    ctx.state = .server_hello_received;
    ctx.cipher_suite = handshake_mod.TLS_AES_128_GCM_SHA256;
    ctx.selected_alpn = try allocator.dupe(u8, "h3");
    ctx.peer_transport_params = try allocator.dupe(u8, "tp");
    ctx.handshake_client_secret = try allocator.dupe(u8, "hs-secret");
    ctx.application_client_secret = try allocator.dupe(u8, "app-secret");

    const snap = ctx.diagnosticsSnapshot("alert");
    try std.testing.expectEqual(HandshakeState.server_hello_received, snap.state);
    try std.testing.expectEqual(@as(u16, handshake_mod.TLS_AES_128_GCM_SHA256), snap.cipher_suite.?);
    try std.testing.expectEqualStrings("h3", snap.selected_alpn.?);
    try std.testing.expectEqual(@as(usize, 2), snap.peer_transport_params_len.?);
    try std.testing.expectEqualStrings("alert", snap.last_error.?);
    try std.testing.expect(snap.handshake_secret_fingerprint != null);
    try std.testing.expect(snap.application_secret_fingerprint != null);
}

test "verify finished data accepts matching verify_data" {
    const allocator = std.testing.allocator;

    var ctx = TlsContext.init(allocator, true);
    defer ctx.deinit();

    var ks = try key_schedule_mod.KeySchedule.init(allocator, .sha256);
    defer ks.deinit();
    ks.updateTranscript("transcript-bytes");

    const server_handshake_secret = [_]u8{0x5A} ** 32;

    var finished_key: [32]u8 = undefined;
    defer @memset(&finished_key, 0);
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

    try ctx.verifyFinishedData(&ks, &server_handshake_secret, &verify_data);
}

test "verify finished data rejects wrong length" {
    const allocator = std.testing.allocator;

    var ctx = TlsContext.init(allocator, true);
    defer ctx.deinit();

    var ks = try key_schedule_mod.KeySchedule.init(allocator, .sha256);
    defer ks.deinit();
    ks.updateTranscript("transcript-bytes");

    const server_handshake_secret = [_]u8{0x7B} ** 32;
    const short_verify = [_]u8{0x01} ** 31;
    try std.testing.expectError(
        error.HandshakeFailed,
        ctx.verifyFinishedData(&ks, &server_handshake_secret, &short_verify),
    );
}

test "verify finished data rejects mismatched payload" {
    const allocator = std.testing.allocator;

    var ctx = TlsContext.init(allocator, true);
    defer ctx.deinit();

    var ks = try key_schedule_mod.KeySchedule.init(allocator, .sha256);
    defer ks.deinit();
    ks.updateTranscript("transcript-bytes");

    const server_handshake_secret = [_]u8{0x11} ** 32;
    const wrong_verify = [_]u8{0x22} ** 32;
    try std.testing.expectError(
        error.HandshakeFailed,
        ctx.verifyFinishedData(&ks, &server_handshake_secret, &wrong_verify),
    );
}

test "start client handshake rejects invalid local transport params" {
    const allocator = std.testing.allocator;

    var ctx = TlsContext.init(allocator, true);
    defer ctx.deinit();

    const offered = [_][]const u8{"h3"};
    const bad_tp = [_]u8{ 0x03, 0x02, 0x44, 0xAF };

    try std.testing.expectError(
        error.HandshakeFailed,
        ctx.startClientHandshakeWithParams("example.com", &offered, &bad_tp),
    );
    try std.testing.expectEqual(HandshakeState.idle, ctx.state);
    try std.testing.expect(ctx.getSelectedAlpn() == null);
    try std.testing.expect(ctx.getPeerTransportParams() == null);
}

test "build server hello rejects invalid local transport params" {
    const allocator = std.testing.allocator;

    var client = TlsContext.init(allocator, true);
    defer client.deinit();
    var server = TlsContext.init(allocator, false);
    defer server.deinit();

    const offered = [_][]const u8{"h3"};
    var client_tp = transport_params_mod.TransportParams.defaultClient();
    const client_tp_encoded = try client_tp.encode(allocator);
    defer allocator.free(client_tp_encoded);

    const ch = try client.startClientHandshakeWithParams("example.com", &offered, client_tp_encoded);
    defer allocator.free(ch);

    const bad_server_tp = [_]u8{ 0x03, 0x02, 0x44, 0xAF };
    try std.testing.expectError(
        error.HandshakeFailed,
        server.buildServerHelloFromClientHello(ch, &offered, &bad_server_tp),
    );
    try std.testing.expectEqual(HandshakeState.idle, server.state);
    try std.testing.expect(server.getSelectedAlpn() == null);
    try std.testing.expect(server.getPeerTransportParams() == null);
}

test "tls context invalid state matrix is stable" {
    const allocator = std.testing.allocator;

    var client = TlsContext.init(allocator, true);
    defer client.deinit();
    var server = TlsContext.init(allocator, false);
    defer server.deinit();

    const offered = [_][]const u8{"h3"};
    var client_tp = transport_params_mod.TransportParams.defaultClient();
    const client_tp_encoded = try client_tp.encode(allocator);
    defer allocator.free(client_tp_encoded);

    var server_tp = transport_params_mod.TransportParams.defaultServer();
    const server_tp_encoded = try server_tp.encode(allocator);
    defer allocator.free(server_tp_encoded);

    try std.testing.expectError(
        error.InvalidState,
        server.startClientHandshakeWithParams("example.com", &offered, client_tp_encoded),
    );
    try std.testing.expectEqual(HandshakeState.idle, server.state);

    try std.testing.expectError(error.InvalidState, client.completeHandshake("shared-secret"));
    try std.testing.expectEqual(HandshakeState.idle, client.state);

    try std.testing.expectError(
        error.InvalidState,
        client.buildServerHelloFromClientHello("bad", &offered, server_tp_encoded),
    );
    try std.testing.expectEqual(HandshakeState.idle, client.state);

    try std.testing.expectError(error.InvalidState, server.processServerHello("bad"));
    try std.testing.expectEqual(HandshakeState.idle, server.state);

    const ch = try client.startClientHandshakeWithParams("example.com", &offered, client_tp_encoded);
    defer allocator.free(ch);
    try std.testing.expectEqual(HandshakeState.client_hello_sent, client.state);

    try std.testing.expectError(
        error.InvalidState,
        client.startClientHandshakeWithParams("example.com", &offered, client_tp_encoded),
    );
    try std.testing.expectEqual(HandshakeState.client_hello_sent, client.state);
}

test "build server hello chooses preferred cipher over client order" {
    const allocator = std.testing.allocator;

    var server = TlsContext.init(allocator, false);
    defer server.deinit();

    var client_tp = transport_params_mod.TransportParams.defaultClient();
    const client_tp_encoded = try client_tp.encode(allocator);
    defer allocator.free(client_tp_encoded);

    const alpn_offer = [_]u8{ 0x00, 0x03, 0x02, 'h', '3' };
    const suites = [_]u16{
        handshake_mod.TLS_CHACHA20_POLY1305_SHA256,
        handshake_mod.TLS_AES_128_GCM_SHA256,
    };
    const ext = [_]handshake_mod.Extension{
        .{ .extension_type = @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation), .extension_data = &alpn_offer },
        .{ .extension_type = @intFromEnum(handshake_mod.ExtensionType.quic_transport_parameters), .extension_data = client_tp_encoded },
    };
    const ch = handshake_mod.ClientHello{
        .random = [_]u8{0xA1} ** 32,
        .cipher_suites = &suites,
        .extensions = &ext,
    };
    const ch_bytes = try ch.encode(allocator);
    defer allocator.free(ch_bytes);

    var server_tp = transport_params_mod.TransportParams.defaultServer();
    const server_tp_encoded = try server_tp.encode(allocator);
    defer allocator.free(server_tp_encoded);

    const supported = [_][]const u8{"h3"};
    const sh_bytes = try server.buildServerHelloFromClientHello(ch_bytes, &supported, server_tp_encoded);
    defer allocator.free(sh_bytes);

    const parsed = try handshake_mod.parseServerHello(sh_bytes);
    try std.testing.expectEqual(handshake_mod.TLS_AES_128_GCM_SHA256, parsed.cipher_suite);
    try std.testing.expectEqual(HandshakeState.server_hello_received, server.state);
}

test "process server hello stores selected ALPN and transport params atomically" {
    const allocator = std.testing.allocator;

    var client = TlsContext.init(allocator, true);
    defer client.deinit();

    const offered = [_][]const u8{"h3"};
    var client_tp = transport_params_mod.TransportParams.defaultClient();
    const client_tp_encoded = try client_tp.encode(allocator);
    defer allocator.free(client_tp_encoded);

    var server_tp = transport_params_mod.TransportParams.defaultServer();
    const server_tp_encoded = try server_tp.encode(allocator);
    defer allocator.free(server_tp_encoded);

    const ch = try client.startClientHandshakeWithParams("example.com", &offered, client_tp_encoded);
    defer allocator.free(ch);

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
    const sh = try makeServerHelloWithExtensions(allocator, &ext);
    defer allocator.free(sh);

    try client.processServerHello(sh);

    const selected = client.getSelectedAlpn() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("h3", selected);
    const peer_tp = client.getPeerTransportParams() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, server_tp_encoded, peer_tp);
    try std.testing.expectEqual(HandshakeState.server_hello_received, client.state);
}

test "process server hello preserves previously stored fields on parse failure" {
    const allocator = std.testing.allocator;

    var client = TlsContext.init(allocator, true);
    defer client.deinit();

    const offered = [_][]const u8{"h3"};
    var client_tp = transport_params_mod.TransportParams.defaultClient();
    const client_tp_encoded = try client_tp.encode(allocator);
    defer allocator.free(client_tp_encoded);

    var server_tp = transport_params_mod.TransportParams.defaultServer();
    const server_tp_encoded = try server_tp.encode(allocator);
    defer allocator.free(server_tp_encoded);

    const ch = try client.startClientHandshakeWithParams("example.com", &offered, client_tp_encoded);
    defer allocator.free(ch);

    client.selected_alpn = try allocator.dupe(u8, "h3");
    client.peer_transport_params = try allocator.dupe(u8, server_tp_encoded);

    const bad_tp = [_]u8{ 0x03, 0x02, 0x44, 0xAF };
    const bad_ext = [_]handshake_mod.Extension{
        .{
            .extension_type = @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation),
            .extension_data = &[_]u8{ 0x00, 0x03, 0x02, 'h', '3' },
        },
        .{
            .extension_type = @intFromEnum(handshake_mod.ExtensionType.quic_transport_parameters),
            .extension_data = &bad_tp,
        },
    };
    const bad_sh = try makeServerHelloWithExtensions(allocator, &bad_ext);
    defer allocator.free(bad_sh);

    try std.testing.expectError(error.HandshakeFailed, client.processServerHello(bad_sh));
    const retained_alpn = client.getSelectedAlpn() orelse return error.TestUnexpectedResult;
    const retained_tp = client.getPeerTransportParams() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("h3", retained_alpn);
    try std.testing.expectEqualSlices(u8, server_tp_encoded, retained_tp);
    try std.testing.expectEqual(HandshakeState.client_hello_sent, client.state);
}
