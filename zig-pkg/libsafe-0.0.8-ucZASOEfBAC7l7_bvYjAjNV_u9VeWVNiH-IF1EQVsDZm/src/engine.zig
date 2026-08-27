const std = @import("std");

pub const EngineError = error{
    InvalidState,
    HandshakeFailed,
    AlpnMismatch,
    UnsupportedCipherSuite,
    OutOfMemory,
    NotImplemented,
};

pub const Role = enum {
    client,
    server,
};

pub const HandshakeState = enum {
    idle,
    client_hello_sent,
    server_hello_received,
    handshake_complete,
    failed,
};

pub const EngineVTable = struct {
    deinit: *const fn (ctx: *anyopaque) void,
    begin_client_handshake: *const fn (
        ctx: *anyopaque,
        server_name: []const u8,
        alpn_protocols: []const []const u8,
        local_transport_params: []const u8,
    ) EngineError![]u8,
    build_server_hello: *const fn (
        ctx: *anyopaque,
        client_hello_data: []const u8,
        server_supported_alpn: []const []const u8,
        local_transport_params: []const u8,
    ) EngineError![]u8,
    process_server_hello: *const fn (ctx: *anyopaque, server_hello_data: []const u8) EngineError!void,
    complete_handshake: *const fn (ctx: *anyopaque, shared_secret: []const u8) EngineError!void,
    get_selected_alpn: *const fn (ctx: *const anyopaque) ?[]const u8,
    get_peer_transport_params: *const fn (ctx: *const anyopaque) ?[]const u8,
    state: *const fn (ctx: *const anyopaque) HandshakeState,
    free_buffer: *const fn (ctx: *anyopaque, bytes: []u8) void,
};

pub const Engine = struct {
    ctx: *anyopaque,
    vtable: *const EngineVTable,

    pub fn deinit(self: *Engine) void {
        self.vtable.deinit(self.ctx);
    }

    pub fn beginClientHandshake(
        self: *Engine,
        server_name: []const u8,
        alpn_protocols: []const []const u8,
        local_transport_params: []const u8,
    ) EngineError![]u8 {
        return self.vtable.begin_client_handshake(
            self.ctx,
            server_name,
            alpn_protocols,
            local_transport_params,
        );
    }

    pub fn buildServerHello(
        self: *Engine,
        client_hello_data: []const u8,
        server_supported_alpn: []const []const u8,
        local_transport_params: []const u8,
    ) EngineError![]u8 {
        return self.vtable.build_server_hello(
            self.ctx,
            client_hello_data,
            server_supported_alpn,
            local_transport_params,
        );
    }

    pub fn processServerHello(self: *Engine, server_hello_data: []const u8) EngineError!void {
        return self.vtable.process_server_hello(self.ctx, server_hello_data);
    }

    pub fn completeHandshake(self: *Engine, shared_secret: []const u8) EngineError!void {
        return self.vtable.complete_handshake(self.ctx, shared_secret);
    }

    pub fn getSelectedAlpn(self: *const Engine) ?[]const u8 {
        return self.vtable.get_selected_alpn(self.ctx);
    }

    pub fn getPeerTransportParams(self: *const Engine) ?[]const u8 {
        return self.vtable.get_peer_transport_params(self.ctx);
    }

    pub fn state(self: *const Engine) HandshakeState {
        return self.vtable.state(self.ctx);
    }

    pub fn isComplete(self: *const Engine) bool {
        return self.state() == .handshake_complete;
    }

    pub fn freeBuffer(self: *Engine, bytes: []u8) void {
        self.vtable.free_buffer(self.ctx, bytes);
    }
};

test "engine state helper" {
    const Stub = struct {
        const Self = @This();

        fn noopDeinit(_: *anyopaque) void {}
        fn failBegin(_: *anyopaque, _: []const u8, _: []const []const u8, _: []const u8) EngineError![]u8 {
            return error.NotImplemented;
        }
        fn failBuild(_: *anyopaque, _: []const u8, _: []const []const u8, _: []const u8) EngineError![]u8 {
            return error.NotImplemented;
        }
        fn failProc(_: *anyopaque, _: []const u8) EngineError!void {
            return error.NotImplemented;
        }
        fn failComplete(_: *anyopaque, _: []const u8) EngineError!void {
            return error.NotImplemented;
        }
        fn noneAlpn(_: *const anyopaque) ?[]const u8 {
            return null;
        }
        fn noneTp(_: *const anyopaque) ?[]const u8 {
            return null;
        }
        fn getState(_: *const anyopaque) HandshakeState {
            return .handshake_complete;
        }
        fn noopFree(_: *anyopaque, _: []u8) void {}

        const vtable: EngineVTable = .{
            .deinit = noopDeinit,
            .begin_client_handshake = failBegin,
            .build_server_hello = failBuild,
            .process_server_hello = failProc,
            .complete_handshake = failComplete,
            .get_selected_alpn = noneAlpn,
            .get_peer_transport_params = noneTp,
            .state = getState,
            .free_buffer = noopFree,
        };
    };

    var sentinel: usize = 0;
    var eng = Engine{ .ctx = &sentinel, .vtable = &Stub.vtable };
    try std.testing.expect(eng.isComplete());
}

test "engine forwards selected alpn and transport params" {
    const Stub = struct {
        const alpn = "h3";
        const tp = "tp-bytes";

        fn noopDeinit(_: *anyopaque) void {}
        fn failBegin(_: *anyopaque, _: []const u8, _: []const []const u8, _: []const u8) EngineError![]u8 {
            return error.NotImplemented;
        }
        fn failBuild(_: *anyopaque, _: []const u8, _: []const []const u8, _: []const u8) EngineError![]u8 {
            return error.NotImplemented;
        }
        fn failProc(_: *anyopaque, _: []const u8) EngineError!void {
            return error.NotImplemented;
        }
        fn failComplete(_: *anyopaque, _: []const u8) EngineError!void {
            return error.NotImplemented;
        }
        fn getAlpn(_: *const anyopaque) ?[]const u8 {
            return alpn;
        }
        fn getTp(_: *const anyopaque) ?[]const u8 {
            return tp;
        }
        fn getState(_: *const anyopaque) HandshakeState {
            return .server_hello_received;
        }
        fn noopFree(_: *anyopaque, _: []u8) void {}

        const vtable: EngineVTable = .{
            .deinit = noopDeinit,
            .begin_client_handshake = failBegin,
            .build_server_hello = failBuild,
            .process_server_hello = failProc,
            .complete_handshake = failComplete,
            .get_selected_alpn = getAlpn,
            .get_peer_transport_params = getTp,
            .state = getState,
            .free_buffer = noopFree,
        };
    };

    var sentinel: usize = 0;
    const eng = Engine{ .ctx = &sentinel, .vtable = &Stub.vtable };
    try std.testing.expectEqualStrings("h3", eng.getSelectedAlpn().?);
    try std.testing.expectEqualStrings("tp-bytes", eng.getPeerTransportParams().?);
    try std.testing.expectEqual(HandshakeState.server_hello_received, eng.state());
    try std.testing.expect(!eng.isComplete());
}

test "engine forwards begin/build/process/complete/free" {
    const Stub = struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        deinit_calls: usize = 0,
        begin_calls: usize = 0,
        build_calls: usize = 0,
        process_calls: usize = 0,
        complete_calls: usize = 0,
        free_calls: usize = 0,

        fn deinitFn(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.deinit_calls += 1;
        }
        fn beginFn(
            ctx: *anyopaque,
            _: []const u8,
            _: []const []const u8,
            _: []const u8,
        ) EngineError![]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.begin_calls += 1;
            const out = try self.allocator.alloc(u8, 3);
            @memcpy(out, "CH!");
            return out;
        }
        fn buildFn(
            ctx: *anyopaque,
            _: []const u8,
            _: []const []const u8,
            _: []const u8,
        ) EngineError![]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.build_calls += 1;
            const out = try self.allocator.alloc(u8, 3);
            @memcpy(out, "SH!");
            return out;
        }
        fn processFn(ctx: *anyopaque, _: []const u8) EngineError!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.process_calls += 1;
        }
        fn completeFn(ctx: *anyopaque, _: []const u8) EngineError!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.complete_calls += 1;
        }
        fn noneAlpn(_: *const anyopaque) ?[]const u8 {
            return null;
        }
        fn noneTp(_: *const anyopaque) ?[]const u8 {
            return null;
        }
        fn doneState(_: *const anyopaque) HandshakeState {
            return .handshake_complete;
        }
        fn freeFn(ctx: *anyopaque, bytes: []u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.free_calls += 1;
            self.allocator.free(bytes);
        }

        const vtable: EngineVTable = .{
            .deinit = deinitFn,
            .begin_client_handshake = beginFn,
            .build_server_hello = buildFn,
            .process_server_hello = processFn,
            .complete_handshake = completeFn,
            .get_selected_alpn = noneAlpn,
            .get_peer_transport_params = noneTp,
            .state = doneState,
            .free_buffer = freeFn,
        };
    };

    var stub = Stub{ .allocator = std.testing.allocator };
    var eng = Engine{ .ctx = &stub, .vtable = &Stub.vtable };

    const offered = [_][]const u8{"h3"};
    const ch = try eng.beginClientHandshake("example.com", &offered, &[_]u8{});
    const sh = try eng.buildServerHello(ch, &offered, &[_]u8{});
    try eng.processServerHello(sh);
    try eng.completeHandshake("shared");
    eng.freeBuffer(ch);
    eng.freeBuffer(sh);
    eng.deinit();

    try std.testing.expectEqual(@as(usize, 1), stub.begin_calls);
    try std.testing.expectEqual(@as(usize, 1), stub.build_calls);
    try std.testing.expectEqual(@as(usize, 1), stub.process_calls);
    try std.testing.expectEqual(@as(usize, 1), stub.complete_calls);
    try std.testing.expectEqual(@as(usize, 1), stub.deinit_calls);
    try std.testing.expectEqual(@as(usize, 2), stub.free_calls);
}
