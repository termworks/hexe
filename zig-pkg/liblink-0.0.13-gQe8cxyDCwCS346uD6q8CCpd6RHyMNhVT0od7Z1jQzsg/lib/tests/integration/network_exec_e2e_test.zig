const std = @import("std");
const testing = std.testing;
const liblink = @import("../../liblink.zig");
const network_test_utils = @import("network_test_utils.zig");

const SERVER_PRNG_SEED: u64 = 0x2468_1357;
const CLIENT_PRNG_SEED: u64 = 0xdead_babe;
const TEST_PORT_BASE: u16 = 42_000;

const EXPECTED_COMMAND = "printf deterministic-exec";
const EXPECTED_STDOUT = "stdout-part-1 stdout-part-2\n";
const EXPECTED_STDERR = "stderr-part\n";
const EXPECTED_EXIT_STATUS: ?u32 = 23;

const ServerThreadCtx = network_test_utils.CommonServerThreadCtx;

fn serverThreadMain(ctx: *ServerThreadCtx) void {
    var accepted = network_test_utils.startAndAcceptAuthenticatedServer(ctx, SERVER_PRNG_SEED) catch {
        network_test_utils.markFailed(&ctx.failed);
        return;
    };
    defer accepted.deinit();

    tryHandleExecSession(accepted.conn) catch {
        network_test_utils.markFailed(&ctx.failed);
        return;
    };
}

fn tryHandleExecSession(server_conn: *liblink.connection.ServerConnection) !void {
    const stream_id = try network_test_utils.waitForSessionChannel(server_conn, network_test_utils.SESSION_CHANNEL_TIMEOUT_MS);
    const command = try network_test_utils.waitForChannelRequestString(
        server_conn,
        stream_id,
        "exec",
        network_test_utils.SESSION_CHANNEL_TIMEOUT_MS,
    );
    defer server_conn.allocator.free(command);
    if (!std.mem.eql(u8, command, EXPECTED_COMMAND)) {
        return error.UnexpectedCommand;
    }

    try server_conn.channel_manager.sendData(stream_id, "stdout-part-1 ");
    try server_conn.channel_manager.sendData(stream_id, "stdout-part-2\n");
    try server_conn.channel_manager.sendExtendedData(stream_id, 1, "stderr-part\n");

    var status_data: [4]u8 = undefined;
    std.mem.writeInt(u32, &status_data, @as(u32, @intCast(EXPECTED_EXIT_STATUS.?)), .big);
    try server_conn.channel_manager.sendRequest(stream_id, "exit-status", false, &status_data);

    try server_conn.channel_manager.sendEof(stream_id);
    try server_conn.channel_manager.closeChannel(stream_id);
}

test "Integration: network exec e2e returns stdout stderr and exit-status" {
    const allocator = testing.allocator;

    try network_test_utils.requireEnvEnabled(allocator, "LIBLINK_NETWORK_EXEC_E2E");

    var server_ctx = ServerThreadCtx{
        .allocator = allocator,
        .port = network_test_utils.chooseTestPort(TEST_PORT_BASE),
    };

    const server_thread = try std.Thread.spawn(.{}, serverThreadMain, .{&server_ctx});

    try network_test_utils.waitForServerReady(&server_ctx);

    var client = try network_test_utils.connectAuthenticatedClient(allocator, server_ctx.port, CLIENT_PRNG_SEED);
    defer client.deinit();

    var session = try client.requestExec(EXPECTED_COMMAND);
    defer session.close() catch {};

    var result = try liblink.channels.collectExecResult(allocator, &session, 5000);
    defer result.deinit();

    try testing.expectEqualStrings(EXPECTED_STDOUT, result.stdout);
    try testing.expectEqualStrings(EXPECTED_STDERR, result.stderr);
    try testing.expectEqual(EXPECTED_EXIT_STATUS, result.exit_status);

    server_thread.join();
    try testing.expect(!server_ctx.failed.load(.acquire));
}
