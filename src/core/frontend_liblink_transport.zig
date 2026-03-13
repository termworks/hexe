const std = @import("std");
const posix = std.posix;
const c = std.c;
const liblink = @import("liblink");

pub const default_port: u16 = 2222;

pub const TrustMode = enum {
    strict,
    accept_new,
    insecure_temporary,
};

pub const Config = struct {
    host: []const u8,
    user: []const u8,
    identity_path: []const u8,
    port: u16 = default_port,
    trust: TrustMode = .accept_new,
    remote_hexe_path: []const u8 = "hexe",
    remote_ses_socket: ?[]const u8 = null,
};

pub const ConnectResult = struct {
    bridge: *Bridge,
    ctl_fd: posix.fd_t,
    vt_fd: posix.fd_t,
};

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    host: []u8,
    user: []u8,
    identity_path: []u8,
    remote_hexe_path: []u8,
    remote_ses_socket: ?[]u8,
    port: u16,
    trust: TrustMode,
    ctl_bridge_fd: posix.fd_t,
    vt_bridge_fd: posix.fd_t,
    ctl_thread: ?std.Thread = null,
    vt_thread: ?std.Thread = null,

    pub fn deinit(self: *Bridge) void {
        if (self.ctl_thread) |thread| thread.join();
        if (self.vt_thread) |thread| thread.join();
        if (self.ctl_bridge_fd >= 0) posix.close(self.ctl_bridge_fd);
        if (self.vt_bridge_fd >= 0) posix.close(self.vt_bridge_fd);
        self.allocator.free(self.host);
        self.allocator.free(self.user);
        self.allocator.free(self.identity_path);
        self.allocator.free(self.remote_hexe_path);
        if (self.remote_ses_socket) |value| self.allocator.free(value);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }
};

const ChannelKind = enum { ctl, vt };

const WorkerArgs = struct {
    bridge: *Bridge,
    kind: ChannelKind,
};

pub fn connect(allocator: std.mem.Allocator, config: Config) !ConnectResult {
    const bridge = try allocator.create(Bridge);
    errdefer allocator.destroy(bridge);

    bridge.* = .{
        .allocator = allocator,
        .host = try allocator.dupe(u8, config.host),
        .user = try allocator.dupe(u8, config.user),
        .identity_path = try allocator.dupe(u8, config.identity_path),
        .remote_hexe_path = try allocator.dupe(u8, if (config.remote_hexe_path.len > 0) config.remote_hexe_path else "hexe"),
        .remote_ses_socket = if (config.remote_ses_socket) |value| try allocator.dupe(u8, value) else null,
        .port = config.port,
        .trust = config.trust,
        .ctl_bridge_fd = -1,
        .vt_bridge_fd = -1,
    };
    errdefer {
        allocator.free(bridge.host);
        allocator.free(bridge.user);
        allocator.free(bridge.identity_path);
        allocator.free(bridge.remote_hexe_path);
        if (bridge.remote_ses_socket) |value| allocator.free(value);
    }

    const ctl_pair = try makeSocketPair();
    errdefer {
        posix.close(ctl_pair[0]);
        posix.close(ctl_pair[1]);
    }
    const vt_pair = try makeSocketPair();
    errdefer {
        posix.close(vt_pair[0]);
        posix.close(vt_pair[1]);
    }

    bridge.ctl_bridge_fd = ctl_pair[1];
    bridge.vt_bridge_fd = vt_pair[1];

    bridge.ctl_thread = try std.Thread.spawn(.{}, workerMain, .{WorkerArgs{
        .bridge = bridge,
        .kind = .ctl,
    }});
    errdefer {
        posix.close(ctl_pair[0]);
        if (bridge.ctl_thread) |thread| thread.join();
    }

    bridge.vt_thread = try std.Thread.spawn(.{}, workerMain, .{WorkerArgs{
        .bridge = bridge,
        .kind = .vt,
    }});
    errdefer {
        posix.close(vt_pair[0]);
        if (bridge.vt_thread) |thread| thread.join();
    }

    return .{
        .bridge = bridge,
        .ctl_fd = ctl_pair[0],
        .vt_fd = vt_pair[0],
    };
}

fn workerMain(args: WorkerArgs) void {
    bridgeSession(args.bridge, args.kind) catch {};
}

fn bridgeSession(bridge: *Bridge, kind: ChannelKind) !void {
    const local_fd_ptr = switch (kind) {
        .ctl => &bridge.ctl_bridge_fd,
        .vt => &bridge.vt_bridge_fd,
    };
    const local_fd = local_fd_ptr.*;
    if (local_fd < 0) return;
    defer {
        posix.close(local_fd);
        local_fd_ptr.* = -1;
    }

    try setNonBlocking(local_fd);

    var conn = try connectRemoteRaw(bridge);
    defer conn.deinit();

    const auth_ok = try liblink.auth.workflow.authenticateClient(bridge.allocator, &conn, bridge.user, .{
        .identity_path = bridge.identity_path,
    });
    if (!auth_ok) return error.AuthenticationFailed;

    const command = try buildPipeCommand(bridge.allocator, bridge.remote_hexe_path, bridge.remote_ses_socket);
    defer bridge.allocator.free(command);

    var session = try conn.requestExec(command);
    defer session.close() catch {};

    var local_eof = false;
    while (true) {
        session.manager.transport.poll(10) catch {};

        var made_progress = false;
        var remote_closed = false;

        while (true) {
            const message = session.manager.receiveMessage(session.stream_id) catch |err| switch (err) {
                error.NoData, error.EndOfBuffer => break,
                error.StreamClosed, error.StreamNotFound => {
                    remote_closed = true;
                    break;
                },
                else => return err,
            };
            defer session.allocator.free(message);
            made_progress = true;
            if (!try forwardRemoteMessage(local_fd, message)) {
                remote_closed = true;
                break;
            }
        }

        if (!local_eof) {
            var buf: [8192]u8 = undefined;
            const len = posix.read(local_fd, &buf) catch |err| switch (err) {
                error.WouldBlock => 0,
                error.ConnectionResetByPeer, error.BrokenPipe => return,
                else => return err,
            };
            if (len > 0) {
                try session.sendData(buf[0..len]);
                made_progress = true;
            } else {
                local_eof = true;
                session.sendEof() catch {};
            }
        }

        if (remote_closed) return;
        if (!made_progress) std.Thread.sleep(2 * std.time.ns_per_ms);
    }
}

fn forwardRemoteMessage(local_fd: posix.fd_t, message: []const u8) !bool {
    if (message.len == 0) return true;

    switch (message[0]) {
        94 => {
            var data = try liblink.protocol.channel.ChannelData.decode(std.heap.page_allocator, message);
            defer data.deinit(std.heap.page_allocator);
            try writeAllNonBlocking(local_fd, data.data);
            return true;
        },
        95 => {
            var ext = try liblink.protocol.channel.ChannelExtendedData.decode(std.heap.page_allocator, message);
            defer ext.deinit(std.heap.page_allocator);
            return true;
        },
        96, 97 => return false,
        98 => {
            var req = try liblink.protocol.channel.ChannelRequest.decode(std.heap.page_allocator, message);
            defer req.deinit(std.heap.page_allocator);
            return true;
        },
        else => return true,
    }
}

fn makeSocketPair() ![2]posix.fd_t {
    var fds: [2]c.fd_t = undefined;
    const rc = c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds);
    if (rc != 0) return posix.unexpectedErrno(posix.errno(rc));
    return .{ fds[0], fds[1] };
}

fn setNonBlocking(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(fd, posix.F.SETFL, flags | @as(usize, 0o4000));
}

fn writeAllNonBlocking(fd: posix.fd_t, data: []const u8) !void {
    var offset: usize = 0;
    while (offset < data.len) {
        const wrote = posix.write(fd, data[offset..]) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            },
            error.BrokenPipe, error.ConnectionResetByPeer => return error.ConnectionResetByPeer,
            else => return err,
        };
        offset += wrote;
    }
}

fn connectRemoteRaw(bridge: *const Bridge) !liblink.connection.ClientConnection {
    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.nanoTimestamp())));
    const random = prng.random();

    return switch (bridge.trust) {
        .strict => liblink.connection.connectClientTrusted(bridge.allocator, bridge.host, bridge.port, random, .strict),
        .accept_new => liblink.connection.connectClientTrusted(bridge.allocator, bridge.host, bridge.port, random, .accept_new),
        .insecure_temporary => liblink.connection.connectClient(bridge.allocator, bridge.host, bridge.port, random),
    };
}

fn buildPipeCommand(
    allocator: std.mem.Allocator,
    remote_hexe_path: []const u8,
    remote_ses_socket: ?[]const u8,
) ![]u8 {
    const quoted_hexe = try shellQuoteOwned(allocator, remote_hexe_path);
    defer allocator.free(quoted_hexe);

    if (remote_ses_socket) |socket_path| {
        const quoted_socket = try shellQuoteOwned(allocator, socket_path);
        defer allocator.free(quoted_socket);
        return std.fmt.allocPrint(allocator, "{s} session pipe --ses-socket {s}", .{
            quoted_hexe,
            quoted_socket,
        });
    }

    return std.fmt.allocPrint(allocator, "{s} session pipe", .{quoted_hexe});
}

fn shellQuoteOwned(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    try buffer.append(allocator, '\'');
    for (value) |ch| {
        if (ch == '\'') {
            try buffer.appendSlice(allocator, "'\\''");
        } else {
            try buffer.append(allocator, ch);
        }
    }
    try buffer.append(allocator, '\'');

    return buffer.toOwnedSlice(allocator);
}

test "buildPipeCommand quotes arguments" {
    const allocator = std.testing.allocator;

    const command = try buildPipeCommand(allocator, "/tmp/hexe path", "/tmp/ses socket");
    defer allocator.free(command);

    try std.testing.expectEqualStrings("'/tmp/hexe path' session pipe --ses-socket '/tmp/ses socket'", command);
}
