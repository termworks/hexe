const std = @import("std");
const posix = std.posix;
const core = @import("core");

const CopyDirection = struct {
    src_fd: posix.fd_t,
    dst_fd: posix.fd_t,
    shutdown_send_on_eof: bool,
};

pub fn run(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    var owned_socket_path: ?[]const u8 = null;
    defer if (owned_socket_path) |path| allocator.free(path);

    const resolved_socket = if (socket_path.len > 0)
        socket_path
    else blk: {
        owned_socket_path = try core.ipc.getSesSocketPath(allocator);
        break :blk owned_socket_path.?;
    };

    var client = core.ipc.Client.connect(resolved_socket) catch {
        std.debug.print("Error: Could not connect to ses daemon socket: {s}\n", .{resolved_socket});
        return error.SesNotRunning;
    };
    defer client.close();

    const stdin_fd: posix.fd_t = posix.STDIN_FILENO;
    const stdout_fd: posix.fd_t = posix.STDOUT_FILENO;
    const ses_fd = client.fd;

    const upstream = try std.Thread.spawn(.{}, copyThreadMain, .{CopyDirection{
        .src_fd = stdin_fd,
        .dst_fd = ses_fd,
        .shutdown_send_on_eof = true,
    }});

    copyThreadMain(.{
        .src_fd = ses_fd,
        .dst_fd = stdout_fd,
        .shutdown_send_on_eof = false,
    });

    upstream.join();
}

fn copyThreadMain(direction: CopyDirection) void {
    copyFd(direction) catch {};
}

fn copyFd(direction: CopyDirection) !void {
    var buf: [8192]u8 = undefined;
    while (true) {
        const len = posix.read(direction.src_fd, &buf) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (len == 0) {
            if (direction.shutdown_send_on_eof) {
                posix.shutdown(direction.dst_fd, .send) catch {};
            }
            return;
        }
        try writeAll(direction.dst_fd, buf[0..len]);
    }
}

fn writeAll(fd: posix.fd_t, data: []const u8) !void {
    var offset: usize = 0;
    while (offset < data.len) {
        const wrote = posix.write(fd, data[offset..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            error.BrokenPipe, error.ConnectionResetByPeer => return,
            else => return err,
        };
        offset += wrote;
    }
}
