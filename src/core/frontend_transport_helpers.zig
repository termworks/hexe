const std = @import("std");
const ipc = @import("ipc.zig");
const wire = @import("wire.zig");
const frontend_client = @import("frontend_client.zig");

pub const ConnectOptions = struct {
    socket_path: ?[]const u8 = null,
    autostart_ses: bool = true,
};

pub fn localIpcTransport(socket_path: ?[]const u8, autostart_ses: bool) frontend_client.Transport {
    return .{ .local_ipc = .{
        .autostart_ses = autostart_ses,
        .socket_path = socket_path,
    } };
}

pub fn resolveTransport(options: ConnectOptions) frontend_client.Transport {
    return localIpcTransport(options.socket_path, options.autostart_ses);
}

pub fn preconnectedTransport(ctl_fd: std.posix.fd_t, vt_fd: std.posix.fd_t) frontend_client.Transport {
    return .{ .preconnected = .{
        .ctl_fd = ctl_fd,
        .vt_fd = vt_fd,
    } };
}

pub fn liblinkTransport(config: frontend_client.LiblinkTransport) frontend_client.Transport {
    return .{ .liblink = config };
}

pub fn sendNotify(
    allocator: std.mem.Allocator,
    transport: frontend_client.Transport,
    message: []const u8,
) !void {
    switch (transport) {
        .local_ipc => |cfg| {
            var owned_socket_path: ?[]const u8 = null;
            defer if (owned_socket_path) |path| allocator.free(path);

            const socket_path = if (cfg.socket_path) |path|
                path
            else blk: {
                owned_socket_path = try ipc.getSesSocketPath(allocator);
                break :blk owned_socket_path.?;
            };

            var client = try ipc.Client.connect(socket_path);
            defer client.close();

            try wire.sendHandshake(client.fd, wire.SES_HANDSHAKE_CLI);
            const notify = wire.Notify{ .msg_len = @intCast(message.len) };
            try wire.writeControlWithTrail(client.fd, .notify, std.mem.asBytes(&notify), message);
        },
        .liblink => return error.UnsupportedTransport,
        .preconnected => return error.UnsupportedTransport,
    }
}

pub fn sendNotifyWithConnectOptions(
    allocator: std.mem.Allocator,
    options: ConnectOptions,
    message: []const u8,
) !void {
    try sendNotify(allocator, resolveTransport(options), message);
}
