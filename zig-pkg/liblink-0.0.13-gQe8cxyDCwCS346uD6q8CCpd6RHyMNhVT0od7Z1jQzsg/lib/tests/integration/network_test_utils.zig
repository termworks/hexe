const std = @import("std");
const liblink = @import("../../liblink.zig");

pub const USERNAME = "e2e-user";
pub const TEST_KEY_SEED: [32]u8 = [_]u8{0x42} ** 32;

pub const READY_WAIT_MAX_ATTEMPTS: usize = 200;
pub const READY_WAIT_SLEEP_MS: u64 = 5;
pub const SESSION_CHANNEL_TIMEOUT_MS: u32 = 30_000;

pub const RunningServer = struct {
    allocator: std.mem.Allocator,
    listener: liblink.connection.ConnectionListener,
    host_key_blob: []u8,

    pub fn deinit(self: *RunningServer) void {
        self.listener.deinit();
        self.allocator.free(self.host_key_blob);
    }
};

pub const AcceptedServer = struct {
    server: RunningServer,
    conn: *liblink.connection.ServerConnection,

    pub fn deinit(self: *AcceptedServer) void {
        self.server.listener.removeConnection(self.conn);
        self.server.deinit();
    }
};

pub const CommonServerThreadCtx = struct {
    allocator: std.mem.Allocator,
    port: u16,
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub fn markFailed(failed: *std.atomic.Value(bool)) void {
    failed.store(true, .release);
}

pub fn validatePublicKey(username: []const u8, algorithm: []const u8, public_key_blob: []const u8) bool {
    _ = public_key_blob;
    return std.mem.eql(u8, username, USERNAME) and std.mem.eql(u8, algorithm, "ssh-ed25519");
}

pub fn encodeHostKeyBlob(allocator: std.mem.Allocator, public_key: *const [32]u8) ![]u8 {
    const alg = "ssh-ed25519";
    const size = 4 + alg.len + 4 + 32;
    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    var writer = liblink.protocol.wire.Writer{ .buffer = buffer };
    try writer.writeString(alg);
    try writer.writeString(public_key);
    return buffer;
}

pub fn chooseTestPort(base: u16) u16 {
    const ts: u64 = @intCast(std.time.nanoTimestamp());
    return base + @as(u16, @intCast(ts % 2000));
}

pub fn startLocalTestServer(
    allocator: std.mem.Allocator,
    port: u16,
    random: std.Random,
) !RunningServer {
    const ed_keypair = std.crypto.sign.Ed25519.KeyPair.generate();
    var host_private_key: [64]u8 = undefined;
    @memcpy(&host_private_key, &ed_keypair.secret_key.bytes);

    const host_key_blob = try encodeHostKeyBlob(allocator, &ed_keypair.public_key.bytes);
    errdefer allocator.free(host_key_blob);

    var listener = try liblink.connection.startServer(
        allocator,
        "127.0.0.1",
        port,
        host_key_blob,
        &host_private_key,
        random,
    );
    errdefer listener.deinit();

    return .{
        .allocator = allocator,
        .listener = listener,
        .host_key_blob = host_key_blob,
    };
}

pub fn startAndAcceptAuthenticatedServer(base: *CommonServerThreadCtx, prng_seed: u64) !AcceptedServer {
    var prng = std.Random.DefaultPrng.init(prng_seed);
    const random = prng.random();

    var server = try startLocalTestServer(base.allocator, base.port, random);
    errdefer server.deinit();

    base.ready.store(true, .release);

    const conn = try acceptAuthenticatedConnection(&server.listener);

    return .{
        .server = server,
        .conn = conn,
    };
}

pub fn acceptAuthenticatedConnection(listener: *liblink.connection.ConnectionListener) !*liblink.connection.ServerConnection {
    const server_conn = try listener.acceptConnection();
    const auth_ok = try server_conn.handleAuthentication(validatePublicKey);
    if (!auth_ok) {
        listener.removeConnection(server_conn);
        return error.AuthenticationFailed;
    }
    return server_conn;
}

pub fn connectAuthenticatedClient(
    allocator: std.mem.Allocator,
    port: u16,
    prng_seed: u64,
) !liblink.connection.ClientConnection {
    var prng = std.Random.DefaultPrng.init(prng_seed);
    const random = prng.random();

    var client = try liblink.connection.connectClient(allocator, "127.0.0.1", port, random);
    errdefer client.deinit();

    const keypair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(TEST_KEY_SEED);
    var private_key: [64]u8 = undefined;
    @memcpy(&private_key, &keypair.secret_key.bytes);

    const alg = "ssh-ed25519";
    const blob_size = 4 + alg.len + 4 + 32;
    const pub_blob = try allocator.alloc(u8, blob_size);
    defer allocator.free(pub_blob);
    var writer = liblink.protocol.wire.Writer{ .buffer = pub_blob };
    try writer.writeString(alg);
    try writer.writeString(&keypair.public_key.bytes);

    const authed = try client.authenticatePublicKey(USERNAME, alg, pub_blob, &private_key);
    if (!authed) {
        return error.AuthenticationFailed;
    }

    return client;
}

pub fn requireEnvEnabled(allocator: std.mem.Allocator, env_var: []const u8) !void {
    const enabled = std.process.getEnvVarOwned(allocator, env_var) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(enabled);

    if (!std.mem.eql(u8, enabled, "1")) return error.SkipZigTest;
}

pub fn waitForReadyFlag(ready: *std.atomic.Value(bool), max_attempts: usize, sleep_ms: u64) bool {
    var wait_count: usize = 0;
    while (!ready.load(.acquire) and wait_count < max_attempts) : (wait_count += 1) {
        std.Thread.sleep(sleep_ms * std.time.ns_per_ms);
    }
    return ready.load(.acquire);
}

pub fn waitForServerReady(base: *CommonServerThreadCtx) !void {
    const ready = waitForReadyFlag(
        &base.ready,
        READY_WAIT_MAX_ATTEMPTS,
        READY_WAIT_SLEEP_MS,
    );
    if (!ready) return error.ServerReadyTimeout;
    if (base.failed.load(.acquire)) return error.ServerStartupFailed;
}

pub fn waitForSessionChannel(server_conn: *liblink.connection.ServerConnection, timeout_ms: u32) !u64 {
    const deadline_ms = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline_ms) {
        server_conn.transport.poll(50) catch {};

        const stream_id = server_conn.acceptChannel() catch {
            std.Thread.sleep(2 * std.time.ns_per_ms);
            continue;
        };
        return stream_id;
    }

    return error.ChannelAcceptTimeout;
}

pub fn waitForChannelRequestType(
    server_conn: *liblink.connection.ServerConnection,
    stream_id: u64,
    expected_request_type: []const u8,
    timeout_ms: u32,
) ![]u8 {
    var request_buf: [4096]u8 = undefined;
    const deadline_ms = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));

    while (std.time.milliTimestamp() < deadline_ms) {
        server_conn.transport.poll(50) catch {};

        const len = server_conn.transport.receiveFromStream(stream_id, &request_buf) catch continue;
        if (len == 0) continue;

        var req = try server_conn.channel_manager.handleRequest(stream_id, request_buf[0..len]);
        defer req.deinit(server_conn.allocator);

        if (!std.mem.eql(u8, req.request.request_type, expected_request_type)) {
            try server_conn.channel_manager.sendFailure(stream_id);
            continue;
        }

        try server_conn.channel_manager.sendSuccess(stream_id);
        return try server_conn.allocator.dupe(u8, req.request.type_specific_data);
    }

    return error.ChannelRequestTimeout;
}

pub fn waitForChannelRequestString(
    server_conn: *liblink.connection.ServerConnection,
    stream_id: u64,
    expected_request_type: []const u8,
    timeout_ms: u32,
) ![]u8 {
    const request_data = try waitForChannelRequestType(
        server_conn,
        stream_id,
        expected_request_type,
        timeout_ms,
    );
    defer server_conn.allocator.free(request_data);

    var reader = liblink.protocol.wire.Reader{ .buffer = request_data };
    return reader.readString(server_conn.allocator);
}
