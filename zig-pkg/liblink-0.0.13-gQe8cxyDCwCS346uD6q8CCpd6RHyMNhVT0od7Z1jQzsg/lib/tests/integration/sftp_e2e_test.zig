const std = @import("std");
const testing = std.testing;
const liblink = @import("../../liblink.zig");

const Duplex = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    client_to_server: std.ArrayListUnmanaged([]u8) = .{},
    server_to_client: std.ArrayListUnmanaged([]u8) = .{},
    closed: bool = false,

    fn deinit(self: *Duplex) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.client_to_server.items) |packet| self.allocator.free(packet);
        for (self.server_to_client.items) |packet| self.allocator.free(packet);
        self.client_to_server.deinit(self.allocator);
        self.server_to_client.deinit(self.allocator);
    }

    fn close(self: *Duplex) void {
        self.mutex.lock();
        self.closed = true;
        self.mutex.unlock();
    }

    fn clientSend(self: *Duplex, data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.client_to_server.append(self.allocator, try self.allocator.dupe(u8, data));
    }

    fn clientReceive(self: *Duplex, allocator: std.mem.Allocator) ![]u8 {
        _ = allocator;
        while (true) {
            self.mutex.lock();
            if (self.server_to_client.items.len > 0) {
                const msg = self.server_to_client.orderedRemove(0);
                self.mutex.unlock();
                return msg;
            }
            const done = self.closed;
            self.mutex.unlock();

            if (done) return error.EndOfStream;
            std.Thread.sleep(1_000_000);
        }
    }

    fn serverSend(self: *Duplex, data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.server_to_client.append(self.allocator, try self.allocator.dupe(u8, data));
    }

    fn serverReceive(self: *Duplex, allocator: std.mem.Allocator) ![]u8 {
        _ = allocator;
        while (true) {
            self.mutex.lock();
            if (self.client_to_server.items.len > 0) {
                const msg = self.client_to_server.orderedRemove(0);
                self.mutex.unlock();
                return msg;
            }
            const done = self.closed;
            self.mutex.unlock();

            if (done) return error.EndOfStream;
            std.Thread.sleep(1_000_000);
        }
    }
};

fn clientSendHook(ctx: *anyopaque, data: []const u8) !void {
    const duplex: *Duplex = @ptrCast(@alignCast(ctx));
    try duplex.clientSend(data);
}

fn clientReceiveHook(ctx: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
    const duplex: *Duplex = @ptrCast(@alignCast(ctx));
    return duplex.clientReceive(allocator);
}

fn serverSendHook(ctx: *anyopaque, data: []const u8) !void {
    const duplex: *Duplex = @ptrCast(@alignCast(ctx));
    try duplex.serverSend(data);
}

fn serverReceiveHook(ctx: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
    const duplex: *Duplex = @ptrCast(@alignCast(ctx));
    return duplex.serverReceive(allocator);
}

const ServerThreadCtx = struct {
    allocator: std.mem.Allocator,
    duplex: *Duplex,
    remote_root: []const u8,
};

fn serverThreadMain(ctx: *ServerThreadCtx) void {
    var server = liblink.sftp.SftpServer.initWithHooks(
        ctx.allocator,
        ctx.duplex,
        serverSendHook,
        serverReceiveHook,
        null,
        .{ .remote_root = ctx.remote_root },
    ) catch return;
    defer server.deinit();

    server.run() catch {};
}

test "Integration: in-process SFTP client/server e2e" {
    const allocator = testing.allocator;

    const tmp_root = try std.fmt.allocPrint(allocator, "/tmp/liblink-sftp-e2e-{}", .{std.time.nanoTimestamp()});
    defer allocator.free(tmp_root);
    defer std.fs.cwd().deleteTree(tmp_root) catch {};
    try std.fs.cwd().makePath(tmp_root);

    var duplex = Duplex{ .allocator = allocator };
    defer duplex.deinit();

    var server_ctx = ServerThreadCtx{
        .allocator = allocator,
        .duplex = &duplex,
        .remote_root = tmp_root,
    };

    const server_thread = try std.Thread.spawn(.{}, serverThreadMain, .{&server_ctx});
    defer {
        duplex.close();
        server_thread.join();
    }

    var client = try liblink.sftp.SftpClient.initWithHooks(
        allocator,
        &duplex,
        clientSendHook,
        clientReceiveHook,
        null,
    );
    defer client.deinit();

    try client.mkdir("/docs", liblink.sftp.attributes.FileAttributes.init());

    const open_flags = liblink.sftp.protocol.OpenFlags{
        .read = true,
        .write = true,
        .creat = true,
        .trunc = true,
    };
    var handle = try client.open("/docs/hello.txt", open_flags, liblink.sftp.attributes.FileAttributes.init());
    defer handle.deinit(allocator);

    try client.write(handle, 0, "hello-sftp");
    const bytes = try client.read(handle, 0, 10);
    defer allocator.free(bytes);
    try testing.expectEqualStrings("hello-sftp", bytes);

    try client.close(handle);

    const st = try client.stat("/docs/hello.txt");
    try testing.expectEqual(@as(u64, 10), st.size.?);

    const link_result = client.symlink("/docs/hello.link", "/docs/hello.txt");
    if (link_result) |_| {
        const target = try client.readlink("/docs/hello.link");
        defer allocator.free(target);
        try testing.expectEqualStrings("/docs/hello.txt", target);
        try client.remove("/docs/hello.link");
    } else |_| {}

    try client.rename("/docs/hello.txt", "/docs/renamed.txt");
    try client.remove("/docs/renamed.txt");
    try client.rmdir("/docs");
}
