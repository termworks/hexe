const std = @import("std");
const testing = std.testing;
const liblink = @import("../../liblink.zig");
const network_test_utils = @import("network_test_utils.zig");

const SERVER_PRNG_SEED: u64 = 0x9abc_def0;
const CLIENT_PRNG_SEED: u64 = 0x1357_2468;
const TEST_PORT_BASE: u16 = 40_000;

const ServerThreadCtx = struct {
    base: network_test_utils.CommonServerThreadCtx,
    remote_root: []const u8,
};

fn serverThreadMain(ctx: *ServerThreadCtx) void {
    var accepted = network_test_utils.startAndAcceptAuthenticatedServer(&ctx.base, SERVER_PRNG_SEED) catch {
        network_test_utils.markFailed(&ctx.base.failed);
        return;
    };
    defer accepted.deinit();

    tryHandleSftpSession(accepted.conn, ctx.remote_root) catch {
        network_test_utils.markFailed(&ctx.base.failed);
        return;
    };
}

fn tryHandleSftpSession(server_conn: *liblink.connection.ServerConnection, remote_root: []const u8) !void {
    const stream_id = try network_test_utils.waitForSessionChannel(server_conn, network_test_utils.SESSION_CHANNEL_TIMEOUT_MS);
    const subsystem_name = try network_test_utils.waitForChannelRequestString(
        server_conn,
        stream_id,
        "subsystem",
        network_test_utils.SESSION_CHANNEL_TIMEOUT_MS,
    );
    defer server_conn.allocator.free(subsystem_name);

    if (!std.mem.eql(u8, subsystem_name, "sftp")) {
        return error.UnsupportedSubsystem;
    }

    const session_channel = liblink.channels.SessionChannel{
        .manager = &server_conn.channel_manager,
        .stream_id = stream_id,
        .allocator = server_conn.allocator,
    };
    const sftp_channel = liblink.sftp.SftpChannel.init(server_conn.allocator, session_channel);
    var sftp_server = try liblink.sftp.SftpServer.initWithOptions(server_conn.allocator, sftp_channel, .{
        .remote_root = remote_root,
    });
    defer sftp_server.deinit();

    sftp_server.run() catch |err| {
        if (err != error.EndOfStream and err != error.ConnectionClosed) return err;
    };
}

test "Integration: network SFTP subsystem e2e" {
    const allocator = testing.allocator;

    try network_test_utils.requireEnvEnabled(allocator, "LIBLINK_NETWORK_SFTP_E2E");

    const tmp_root = try std.fmt.allocPrint(allocator, "/tmp/liblink-net-sftp-e2e-{}", .{std.time.nanoTimestamp()});
    defer allocator.free(tmp_root);
    defer std.fs.cwd().deleteTree(tmp_root) catch {};
    try std.fs.cwd().makePath(tmp_root);

    var server_ctx = ServerThreadCtx{
        .base = .{
            .allocator = allocator,
            .port = network_test_utils.chooseTestPort(TEST_PORT_BASE),
        },
        .remote_root = tmp_root,
    };

    const server_thread = try std.Thread.spawn(.{}, serverThreadMain, .{&server_ctx});

    try network_test_utils.waitForServerReady(&server_ctx.base);

    var client = try network_test_utils.connectAuthenticatedClient(allocator, server_ctx.base.port, CLIENT_PRNG_SEED);
    defer client.deinit();

    var sftp_channel = try client.openSftp();
    defer sftp_channel.getSession().close() catch {};

    var sftp_client = try liblink.sftp.SftpClient.init(allocator, sftp_channel);
    defer sftp_client.deinit();

    try sftp_client.mkdir("/docs", liblink.sftp.attributes.FileAttributes.init());

    const open_flags = liblink.sftp.protocol.OpenFlags{ .read = true, .write = true, .creat = true, .trunc = true };
    var handle = try sftp_client.open("/docs/hello.txt", open_flags, liblink.sftp.attributes.FileAttributes.init());
    defer handle.deinit(allocator);

    try sftp_client.write(handle, 0, "hello-net-sftp");
    const data = try sftp_client.read(handle, 0, 14);
    defer allocator.free(data);
    try testing.expectEqualStrings("hello-net-sftp", data);

    try sftp_client.close(handle);
    try sftp_client.rename("/docs/hello.txt", "/docs/renamed.txt");
    try sftp_client.remove("/docs/renamed.txt");
    try sftp_client.rmdir("/docs");

    server_thread.join();
    try testing.expect(!server_ctx.base.failed.load(.acquire));
}
