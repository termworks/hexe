const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const attributes = @import("attributes.zig");
const wire = @import("../protocol/wire.zig");
const c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("sys/statvfs.h");
    @cInclude("unistd.h");
    @cInclude("utime.h");
});

/// SFTP Server for handling file transfer operations
///
/// The server manages:
/// - SFTP protocol version negotiation
/// - File and directory handle management
/// - File operations (open, read, write, close)
/// - Directory operations (opendir, readdir, mkdir, rmdir)
/// - File metadata operations (stat, setstat)
pub const SftpServer = struct {
    pub const SendFn = *const fn (ctx: *anyopaque, data: []const u8) anyerror!void;
    pub const ReceiveFn = *const fn (ctx: *anyopaque, allocator: Allocator) anyerror![]u8;
    pub const DeinitFn = *const fn (ctx: *anyopaque) void;

    const ChannelRef = struct {
        channel: ?Channel = null,
        ctx: ?*anyopaque = null,
        send_fn: ?SendFn = null,
        receive_fn: ?ReceiveFn = null,
        deinit_fn: ?DeinitFn = null,

        fn fromChannel(channel: Channel) ChannelRef {
            return .{ .channel = channel };
        }

        fn fromHooks(ctx: *anyopaque, send_fn: SendFn, receive_fn: ReceiveFn, deinit_fn: ?DeinitFn) ChannelRef {
            return .{
                .ctx = ctx,
                .send_fn = send_fn,
                .receive_fn = receive_fn,
                .deinit_fn = deinit_fn,
            };
        }

        fn send(self: *ChannelRef, data: []const u8) !void {
            if (self.send_fn) |f| return f(self.ctx.?, data);
            return self.channel.?.send(data);
        }

        fn receive(self: *ChannelRef, allocator: Allocator) ![]u8 {
            if (self.receive_fn) |f| return f(self.ctx.?, allocator);
            return self.channel.?.receive(allocator);
        }

        fn deinit(self: *ChannelRef) void {
            if (self.deinit_fn) |f| {
                f(self.ctx.?);
                return;
            }
            if (self.channel) |*channel| {
                channel.deinit();
            }
        }
    };

    allocator: Allocator,
    channel: ChannelRef,
    remote_root: []const u8,
    version: u32,
    next_handle_id: u64,
    open_handles: std.AutoHashMap(u64, OpenHandle),

    /// SSH channel for SFTP communication
    pub const Channel = @import("channel_adapter.zig").SftpChannel;

    pub const Options = struct {
        remote_root: []const u8 = ".",
    };

    /// Initialize SFTP server and perform version negotiation
    pub fn init(allocator: Allocator, channel: Channel) !SftpServer {
        return initWithOptions(allocator, channel, .{});
    }

    pub fn initWithOptions(allocator: Allocator, channel: Channel, options: Options) !SftpServer {
        const normalized_root = try normalizeRootPath(allocator, options.remote_root);
        errdefer allocator.free(normalized_root);

        var server = SftpServer{
            .allocator = allocator,
            .channel = ChannelRef.fromChannel(channel),
            .remote_root = normalized_root,
            .version = 0,
            .next_handle_id = 1,
            .open_handles = std.AutoHashMap(u64, OpenHandle).init(allocator),
        };

        // Receive INIT from client
        const init_data = try server.channel.receive(allocator);
        defer allocator.free(init_data);

        const init_msg = try protocol.Init.decode(init_data);

        // Negotiate version (use minimum of client and server)
        server.version = @min(init_msg.version, protocol.SFTP_VERSION);

        // Send VERSION response
        const extensions: []const []const u8 = &.{};
        const version_msg = protocol.Version{
            .version = server.version,
            .extensions = extensions,
        };
        const version_packet = try version_msg.encode(allocator);
        defer allocator.free(version_packet);
        try server.channel.send(version_packet);

        std.log.info("SFTP server initialized, version {}", .{server.version});

        return server;
    }

    pub fn initWithHooks(
        allocator: Allocator,
        ctx: *anyopaque,
        send_fn: SendFn,
        receive_fn: ReceiveFn,
        deinit_fn: ?DeinitFn,
        options: Options,
    ) !SftpServer {
        const normalized_root = try normalizeRootPath(allocator, options.remote_root);
        errdefer allocator.free(normalized_root);

        return SftpServer{
            .allocator = allocator,
            .channel = ChannelRef.fromHooks(ctx, send_fn, receive_fn, deinit_fn),
            .remote_root = normalized_root,
            .version = 0,
            .next_handle_id = 1,
            .open_handles = std.AutoHashMap(u64, OpenHandle).init(allocator),
        };
    }

    /// Clean up server resources
    pub fn deinit(self: *SftpServer) void {
        // Close all open handles
        var it = self.open_handles.valueIterator();
        while (it.next()) |handle| {
            handle.close();
        }
        self.open_handles.deinit();
        self.allocator.free(self.remote_root);
        self.channel.deinit();
    }

    /// Process incoming SFTP requests in a loop
    pub fn run(self: *SftpServer) !void {
        while (true) {
            const request_data = self.channel.receive(self.allocator) catch |err| {
                if (err == error.EndOfStream or err == error.ConnectionClosed) {
                    std.log.info("SFTP session ended", .{});
                    return;
                }
                return err;
            };
            defer self.allocator.free(request_data);

            self.handleRequest(request_data) catch |err| {
                std.log.err("Error handling SFTP request: {}", .{err});
                // Continue processing other requests
            };
        }
    }

    /// Handle a single SFTP request
    pub fn handleRequest(self: *SftpServer, request_data: []const u8) !void {
        if (request_data.len < 5) return error.InvalidRequest;

        const packet_type_byte = request_data[4];
        const packet_type: protocol.PacketType = @enumFromInt(packet_type_byte);

        switch (packet_type) {
            .SSH_FXP_INIT => try self.handleInit(request_data),
            .SSH_FXP_OPEN => try self.handleOpen(request_data),
            .SSH_FXP_CLOSE => try self.handleClose(request_data),
            .SSH_FXP_READ => try self.handleRead(request_data),
            .SSH_FXP_WRITE => try self.handleWrite(request_data),
            .SSH_FXP_OPENDIR => try self.handleOpendir(request_data),
            .SSH_FXP_READDIR => try self.handleReaddir(request_data),
            .SSH_FXP_STAT => try self.handleStat(request_data),
            .SSH_FXP_LSTAT => try self.handleLstat(request_data),
            .SSH_FXP_FSTAT => try self.handleFstat(request_data),
            .SSH_FXP_MKDIR => try self.handleMkdir(request_data),
            .SSH_FXP_RMDIR => try self.handleRmdir(request_data),
            .SSH_FXP_REMOVE => try self.handleRemove(request_data),
            .SSH_FXP_REALPATH => try self.handleRealpath(request_data),
            .SSH_FXP_RENAME => try self.handleRename(request_data),
            .SSH_FXP_SETSTAT => try self.handleSetstat(request_data),
            .SSH_FXP_FSETSTAT => try self.handleFsetstat(request_data),
            .SSH_FXP_READLINK => try self.handleReadlink(request_data),
            .SSH_FXP_SYMLINK => try self.handleSymlink(request_data),
            .SSH_FXP_EXTENDED => try self.handleExtended(request_data),
            else => {
                std.log.warn("Unsupported SFTP operation: {}", .{packet_type});
                if (request_data.len < 9) return;
                // Send unsupported operation status
                const request_id = std.mem.readInt(u32, request_data[5..9], .big);
                try self.sendStatus(request_id, .SSH_FX_OP_UNSUPPORTED, "Operation not supported", "");
            },
        }
    }

    fn handleExtended(self: *SftpServer, request_data: []const u8) !void {
        var reader = wire.Reader{ .buffer = request_data };
        _ = try reader.readUint32(); // length
        _ = try reader.readByte(); // packet type
        const request_id = try reader.readUint32();
        const extension = try reader.readString(self.allocator);
        defer self.allocator.free(extension);

        if (std.mem.eql(u8, extension, "posix-rename@openssh.com")) {
            const oldpath = try reader.readString(self.allocator);
            defer self.allocator.free(oldpath);
            const newpath = try reader.readString(self.allocator);
            defer self.allocator.free(newpath);

            try self.performRename(request_id, oldpath, newpath, "SFTP EXTENDED posix-rename");
            return;
        }

        if (std.mem.eql(u8, extension, "statvfs@openssh.com")) {
            const path = try reader.readString(self.allocator);
            defer self.allocator.free(path);

            const resolved_path = self.resolveClientPath(path) catch |err| {
                const status_code = statusFromError(err);
                try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
                return;
            };
            defer self.allocator.free(resolved_path);

            var vfs: c.struct_statvfs = undefined;
            const path_z = try self.allocator.dupeZ(u8, resolved_path);
            defer self.allocator.free(path_z);
            if (c.statvfs(path_z.ptr, &vfs) != 0) {
                try self.sendStatus(request_id, .SSH_FX_FAILURE, "statvfs failed", "");
                return;
            }

            try self.sendStatvfsReply(request_id, vfs);
            return;
        }

        if (std.mem.eql(u8, extension, "fsync@openssh.com")) {
            const handle = try reader.readString(self.allocator);
            defer self.allocator.free(handle);
            const handle_id = self.handleStringToId(handle) catch {
                try self.sendStatus(request_id, .SSH_FX_BAD_MESSAGE, "Invalid handle", "");
                return;
            };

            const open_handle = self.open_handles.getPtr(handle_id) orelse {
                try self.sendStatus(request_id, .SSH_FX_BAD_MESSAGE, "Invalid handle", "");
                return;
            };

            switch (open_handle.*) {
                .file => |*f| {
                    f.file.sync() catch |err| {
                        const status_code = statusFromError(err);
                        try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
                        return;
                    };
                },
                .directory => {
                    try self.sendStatus(request_id, .SSH_FX_OP_UNSUPPORTED, "Handle is not a file", "");
                    return;
                },
            }

            try self.sendStatus(request_id, .SSH_FX_OK, "Success", "");
            return;
        }

        std.log.warn("Unsupported SFTP extension: {s}", .{extension});
        try self.sendStatus(request_id, .SSH_FX_OP_UNSUPPORTED, "Unsupported extension", "");
    }

    fn sendStatvfsReply(self: *SftpServer, request_id: u32, vfs: c.struct_statvfs) !void {
        const payload_len: u32 = 8 * 11;
        const packet_len: u32 = 1 + 4 + payload_len;
        const total_len: usize = 4 + packet_len;

        const packet = try self.allocator.alloc(u8, total_len);
        defer self.allocator.free(packet);

        var writer = wire.Writer{ .buffer = packet };
        try writer.writeUint32(packet_len);
        try writer.writeByte(@intFromEnum(protocol.PacketType.SSH_FXP_EXTENDED_REPLY));
        try writer.writeUint32(request_id);

        try writer.writeUint64(@intCast(vfs.f_bsize));
        try writer.writeUint64(@intCast(vfs.f_frsize));
        try writer.writeUint64(@intCast(vfs.f_blocks));
        try writer.writeUint64(@intCast(vfs.f_bfree));
        try writer.writeUint64(@intCast(vfs.f_bavail));
        try writer.writeUint64(@intCast(vfs.f_files));
        try writer.writeUint64(@intCast(vfs.f_ffree));
        try writer.writeUint64(@intCast(vfs.f_favail));
        try writer.writeUint64(@intCast(vfs.f_fsid));
        try writer.writeUint64(@intCast(vfs.f_flag));
        try writer.writeUint64(@intCast(vfs.f_namemax));

        try self.channel.send(packet);
    }

    fn handleInit(self: *SftpServer, request_data: []const u8) !void {
        const init_msg = protocol.Init.decode(request_data) catch return error.InvalidRequest;
        self.version = @min(init_msg.version, protocol.SFTP_VERSION);

        const version = protocol.Version{
            .version = self.version,
            .extensions = &[_][]const u8{},
        };
        const packet = try version.encode(self.allocator);
        defer self.allocator.free(packet);
        try self.channel.send(packet);
    }

    // ========================================================================
    // Request Handlers
    // ========================================================================

    fn handleOpen(self: *SftpServer, request_data: []const u8) !void {
        var reader = wire.Reader{ .buffer = request_data };
        _ = try reader.readUint32(); // length
        _ = try reader.readByte(); // packet type
        const request_id = try reader.readUint32();
        const filename = try reader.readString(self.allocator);
        defer self.allocator.free(filename);
        const pflags = try reader.readUint32();
        const flags = protocol.OpenFlags.fromU32(pflags);

        // Read attributes supplied by client
        _ = try attributes.FileAttributes.decode(reader.buffer[reader.offset..]);

        std.log.info("SFTP OPEN: path={s}, flags={}", .{ filename, pflags });

        const resolved_path = self.resolveClientPath(filename) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };
        defer self.allocator.free(resolved_path);

        // Open the file
        const handle_id = self.openFile(resolved_path, flags) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };

        // Send handle response
        const handle_str = try self.handleIdToString(handle_id);
        defer self.allocator.free(handle_str);

        const handle_msg = protocol.Handle{
            .request_id = request_id,
            .handle = handle_str,
        };
        const response = try handle_msg.encode(self.allocator);
        defer self.allocator.free(response);
        try self.channel.send(response);
    }

    fn handleClose(self: *SftpServer, request_data: []const u8) !void {
        var reader = wire.Reader{ .buffer = request_data };
        _ = try reader.readUint32(); // length
        _ = try reader.readByte(); // packet type
        const request_id = try reader.readUint32();
        const handle_str = try reader.readString(self.allocator);
        defer self.allocator.free(handle_str);

        const handle_id = try self.handleStringToId(handle_str);

        std.log.info("SFTP CLOSE: handle={}", .{handle_id});

        if (self.open_handles.fetchRemove(handle_id)) |entry| {
            var removed_handle = entry.value;
            removed_handle.close();
            try self.sendStatus(request_id, .SSH_FX_OK, "Success", "");
        } else {
            try self.sendStatus(request_id, .SSH_FX_FAILURE, "Invalid handle", "");
        }
    }

    fn handleRead(self: *SftpServer, request_data: []const u8) !void {
        var reader = wire.Reader{ .buffer = request_data };
        _ = try reader.readUint32(); // length
        _ = try reader.readByte(); // packet type
        const request_id = try reader.readUint32();
        const handle_str = try reader.readString(self.allocator);
        defer self.allocator.free(handle_str);
        const offset = try reader.readUint64();
        const raw_len = try reader.readUint32();
        const len: u32 = @min(raw_len, 64 * 1024); // Cap at 64KB per read

        const handle_id = try self.handleStringToId(handle_str);

        std.log.debug("SFTP READ: handle={}, offset={}, len={}", .{ handle_id, offset, len });

        const handle = self.open_handles.getPtr(handle_id) orelse {
            try self.sendStatus(request_id, .SSH_FX_FAILURE, "Invalid handle", "");
            return;
        };

        if (handle.* != .file) {
            try self.sendStatus(request_id, .SSH_FX_FAILURE, "Handle is not a file", "");
            return;
        }

        // Read from file
        const data = handle.file.readAt(self.allocator, offset, len) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };
        defer self.allocator.free(data);

        // Send data response
        const data_msg = protocol.Data{
            .request_id = request_id,
            .data = data,
        };
        const response = try data_msg.encode(self.allocator);
        defer self.allocator.free(response);
        try self.channel.send(response);
    }

    fn handleWrite(self: *SftpServer, request_data: []const u8) !void {
        var reader = wire.Reader{ .buffer = request_data };
        _ = try reader.readUint32(); // length
        _ = try reader.readByte(); // packet type
        const request_id = try reader.readUint32();
        const handle_str = try reader.readString(self.allocator);
        defer self.allocator.free(handle_str);
        const offset = try reader.readUint64();
        const data = try reader.readString(self.allocator);
        defer self.allocator.free(data);

        const handle_id = try self.handleStringToId(handle_str);

        std.log.debug("SFTP WRITE: handle={}, offset={}, len={}", .{ handle_id, offset, data.len });

        const handle = self.open_handles.getPtr(handle_id) orelse {
            try self.sendStatus(request_id, .SSH_FX_FAILURE, "Invalid handle", "");
            return;
        };

        if (handle.* != .file) {
            try self.sendStatus(request_id, .SSH_FX_FAILURE, "Handle is not a file", "");
            return;
        }

        // Write to file
        handle.file.writeAt(offset, data) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };

        try self.sendStatus(request_id, .SSH_FX_OK, "Success", "");
    }

    fn handleOpendir(self: *SftpServer, request_data: []const u8) !void {
        var reader = wire.Reader{ .buffer = request_data };
        _ = try reader.readUint32(); // length
        _ = try reader.readByte(); // packet type
        const request_id = try reader.readUint32();
        const path = try reader.readString(self.allocator);
        defer self.allocator.free(path);

        std.log.info("SFTP OPENDIR: path={s}", .{path});

        const resolved_path = self.resolveClientPath(path) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };
        defer self.allocator.free(resolved_path);

        // Open directory
        const handle_id = self.openDirectory(resolved_path) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };

        // Send handle response
        const handle_str = try self.handleIdToString(handle_id);
        defer self.allocator.free(handle_str);

        const handle_msg = protocol.Handle{
            .request_id = request_id,
            .handle = handle_str,
        };
        const response = try handle_msg.encode(self.allocator);
        defer self.allocator.free(response);
        try self.channel.send(response);
    }

    fn handleReaddir(self: *SftpServer, request_data: []const u8) !void {
        var reader = wire.Reader{ .buffer = request_data };
        _ = try reader.readUint32(); // length
        _ = try reader.readByte(); // packet type
        const request_id = try reader.readUint32();
        const handle_str = try reader.readString(self.allocator);
        defer self.allocator.free(handle_str);

        const handle_id = try self.handleStringToId(handle_str);

        std.log.debug("SFTP READDIR: handle={}", .{handle_id});

        const handle = self.open_handles.getPtr(handle_id) orelse {
            try self.sendStatus(request_id, .SSH_FX_FAILURE, "Invalid handle", "");
            return;
        };

        if (handle.* != .directory) {
            try self.sendStatus(request_id, .SSH_FX_FAILURE, "Handle is not a directory", "");
            return;
        }

        // Read directory entries
        const entries = handle.directory.readEntries(self.allocator) catch |err| {
            // EOF indicates no more entries
            if (err == error.EndOfStream) {
                try self.sendStatus(request_id, .SSH_FX_EOF, "End of directory", "");
                return;
            }
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };
        defer {
            for (entries) |entry| {
                self.allocator.free(entry.filename);
                self.allocator.free(entry.longname);
            }
            self.allocator.free(entries);
        }

        // Send NAME response
        try self.sendNameResponse(request_id, entries);
    }

    fn handleStat(self: *SftpServer, request_data: []const u8) !void {
        var reader = wire.Reader{ .buffer = request_data };
        _ = try reader.readUint32(); // length
        _ = try reader.readByte(); // packet type
        const request_id = try reader.readUint32();
        const path = try reader.readString(self.allocator);
        defer self.allocator.free(path);

        std.log.debug("SFTP STAT: path={s}", .{path});

        const resolved_path = self.resolveClientPath(path) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };
        defer self.allocator.free(resolved_path);

        const attrs = self.getFileAttributes(resolved_path, true) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };

        try self.sendAttrsResponse(request_id, attrs);
    }

    fn handleLstat(self: *SftpServer, request_data: []const u8) !void {
        var reader = wire.Reader{ .buffer = request_data };
        _ = try reader.readUint32(); // length
        _ = try reader.readByte(); // packet type
        const request_id = try reader.readUint32();
        const path = try reader.readString(self.allocator);
        defer self.allocator.free(path);

        std.log.debug("SFTP LSTAT: path={s}", .{path});

        const resolved_path = self.resolveClientPath(path) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };
        defer self.allocator.free(resolved_path);

        // LSTAT doesn't follow symlinks
        const attrs = self.getFileAttributes(resolved_path, false) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };

        try self.sendAttrsResponse(request_id, attrs);
    }

    fn handleFstat(self: *SftpServer, request_data: []const u8) !void {
        var reader = wire.Reader{ .buffer = request_data };
        _ = try reader.readUint32(); // length
        _ = try reader.readByte(); // packet type
        const request_id = try reader.readUint32();
        const handle_str = try reader.readString(self.allocator);
        defer self.allocator.free(handle_str);

        const handle_id = try self.handleStringToId(handle_str);

        std.log.debug("SFTP FSTAT: handle={}", .{handle_id});

        const handle = self.open_handles.getPtr(handle_id) orelse {
            try self.sendStatus(request_id, .SSH_FX_FAILURE, "Invalid handle", "");
            return;
        };

        const attrs = switch (handle.*) {
            .file => |*f| try f.getAttributes(),
            .directory => |*d| try d.getAttributes(),
        };

        try self.sendAttrsResponse(request_id, attrs);
    }

    fn handleMkdir(self: *SftpServer, request_data: []const u8) !void {
        var reader = wire.Reader{ .buffer = request_data };
        _ = try reader.readUint32(); // length
        _ = try reader.readByte(); // packet type
        const request_id = try reader.readUint32();
        const path = try reader.readString(self.allocator);
        defer self.allocator.free(path);

        std.log.info("SFTP MKDIR: path={s}", .{path});

        const resolved_path = self.resolveClientPath(path) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };
        defer self.allocator.free(resolved_path);

        std.fs.cwd().makeDir(resolved_path) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };

        try self.sendStatus(request_id, .SSH_FX_OK, "Success", "");
    }

    fn handleRmdir(self: *SftpServer, request_data: []const u8) !void {
        var reader = wire.Reader{ .buffer = request_data };
        _ = try reader.readUint32(); // length
        _ = try reader.readByte(); // packet type
        const request_id = try reader.readUint32();
        const path = try reader.readString(self.allocator);
        defer self.allocator.free(path);

        std.log.info("SFTP RMDIR: path={s}", .{path});

        const resolved_path = self.resolveClientPath(path) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };
        defer self.allocator.free(resolved_path);

        std.fs.cwd().deleteDir(resolved_path) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };

        try self.sendStatus(request_id, .SSH_FX_OK, "Success", "");
    }

    fn handleRemove(self: *SftpServer, request_data: []const u8) !void {
        var reader = wire.Reader{ .buffer = request_data };
        _ = try reader.readUint32(); // length
        _ = try reader.readByte(); // packet type
        const request_id = try reader.readUint32();
        const filename = try reader.readString(self.allocator);
        defer self.allocator.free(filename);

        std.log.info("SFTP REMOVE: path={s}", .{filename});

        const resolved_path = self.resolveClientPathNoFollow(filename) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };
        defer self.allocator.free(resolved_path);

        std.fs.cwd().deleteFile(resolved_path) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };

        try self.sendStatus(request_id, .SSH_FX_OK, "Success", "");
    }

    fn handleRealpath(self: *SftpServer, request_data: []const u8) !void {
        var reader = wire.Reader{ .buffer = request_data };
        _ = try reader.readUint32(); // length
        _ = try reader.readByte(); // packet type
        const request_id = try reader.readUint32();
        const path = try reader.readString(self.allocator);
        defer self.allocator.free(path);

        std.log.debug("SFTP REALPATH: path={s}", .{path});

        const resolved_path = self.resolveClientPath(path) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };
        defer self.allocator.free(resolved_path);

        const virtual_path = try self.toVirtualPath(resolved_path);
        defer self.allocator.free(virtual_path);

        const entries = try self.allocator.alloc(DirEntry, 1);
        defer self.allocator.free(entries);

        entries[0] = DirEntry{
            .filename = virtual_path,
            .longname = virtual_path,
            .attrs = attributes.FileAttributes.init(),
        };

        try self.sendNameResponse(request_id, entries);
    }

    fn handleRename(self: *SftpServer, request_data: []const u8) !void {
        var reader = wire.Reader{ .buffer = request_data };
        _ = try reader.readUint32(); // length
        _ = try reader.readByte(); // packet type
        const request_id = try reader.readUint32();
        const oldpath = try reader.readString(self.allocator);
        defer self.allocator.free(oldpath);
        const newpath = try reader.readString(self.allocator);
        defer self.allocator.free(newpath);

        try self.performRename(request_id, oldpath, newpath, "SFTP RENAME");
    }

    fn performRename(
        self: *SftpServer,
        request_id: u32,
        oldpath: []const u8,
        newpath: []const u8,
        log_prefix: []const u8,
    ) !void {
        std.log.info("{s}: {s} -> {s}", .{ log_prefix, oldpath, newpath });

        const resolved_old = self.resolveClientPath(oldpath) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };
        defer self.allocator.free(resolved_old);

        const resolved_new = self.resolveClientPath(newpath) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };
        defer self.allocator.free(resolved_new);

        std.fs.cwd().rename(resolved_old, resolved_new) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };

        try self.sendStatus(request_id, .SSH_FX_OK, "Success", "");
    }

    fn handleSetstat(self: *SftpServer, request_data: []const u8) !void {
        var reader = wire.Reader{ .buffer = request_data };
        _ = try reader.readUint32(); // length
        _ = try reader.readByte(); // packet type
        const request_id = try reader.readUint32();
        const path = try reader.readString(self.allocator);
        defer self.allocator.free(path);

        std.log.debug("SFTP SETSTAT: path={s}", .{path});

        const resolved_path = self.resolveClientPath(path) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };
        defer self.allocator.free(resolved_path);

        const attrs = attributes.FileAttributes.decode(reader.buffer[reader.offset..]) catch {
            try self.sendStatus(request_id, .SSH_FX_BAD_MESSAGE, statusMessage(.SSH_FX_BAD_MESSAGE), "");
            return;
        };

        self.applyPathAttributes(resolved_path, attrs) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };

        try self.sendStatus(request_id, .SSH_FX_OK, "Success", "");
    }

    fn handleReadlink(self: *SftpServer, request_data: []const u8) !void {
        var reader = wire.Reader{ .buffer = request_data };
        _ = try reader.readUint32();
        _ = try reader.readByte();
        const request_id = try reader.readUint32();
        const path = try reader.readString(self.allocator);
        defer self.allocator.free(path);

        const resolved_path = self.resolveClientPathNoFollow(path) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };
        defer self.allocator.free(resolved_path);

        const path_z = try self.allocator.dupeZ(u8, resolved_path);
        defer self.allocator.free(path_z);

        var link_buf: [4096]u8 = undefined;
        const target_len = c.readlink(path_z.ptr, @ptrCast(&link_buf), link_buf.len);
        if (target_len < 0) {
            try self.sendStatus(request_id, .SSH_FX_NO_SUCH_FILE, "FileNotFound", "");
            return;
        }

        const raw_target = link_buf[0..@intCast(target_len)];
        const target_path = if (std.fs.path.isAbsolute(raw_target)) blk: {
            const maybe_virtual = self.toVirtualPath(raw_target) catch {
                try self.sendStatus(request_id, .SSH_FX_PERMISSION_DENIED, "AccessDenied", "");
                return;
            };
            break :blk maybe_virtual;
        } else try self.allocator.dupe(u8, raw_target);
        defer self.allocator.free(target_path);

        const entries = try self.allocator.alloc(DirEntry, 1);
        defer self.allocator.free(entries);
        entries[0] = .{
            .filename = target_path,
            .longname = target_path,
            .attrs = attributes.FileAttributes.init(),
        };
        try self.sendNameResponse(request_id, entries);
    }

    fn handleSymlink(self: *SftpServer, request_data: []const u8) !void {
        var reader = wire.Reader{ .buffer = request_data };
        _ = try reader.readUint32();
        _ = try reader.readByte();
        const request_id = try reader.readUint32();
        const linkpath = try reader.readString(self.allocator);
        defer self.allocator.free(linkpath);
        const targetpath = try reader.readString(self.allocator);
        defer self.allocator.free(targetpath);

        const resolved_link = self.resolveClientPath(linkpath) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };
        defer self.allocator.free(resolved_link);

        const resolved_target = self.resolveClientPath(targetpath) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };
        defer self.allocator.free(resolved_target);

        const link_z = try self.allocator.dupeZ(u8, resolved_link);
        defer self.allocator.free(link_z);
        const target_z = try self.allocator.dupeZ(u8, resolved_target);
        defer self.allocator.free(target_z);

        if (c.symlink(target_z.ptr, link_z.ptr) != 0) {
            try self.sendStatus(request_id, .SSH_FX_FAILURE, "SymlinkFailed", "");
            return;
        }

        try self.sendStatus(request_id, .SSH_FX_OK, "Success", "");
    }

    fn handleFsetstat(self: *SftpServer, request_data: []const u8) !void {
        var reader = wire.Reader{ .buffer = request_data };
        _ = try reader.readUint32(); // length
        _ = try reader.readByte(); // packet type
        const request_id = try reader.readUint32();
        const handle_str = try reader.readString(self.allocator);
        defer self.allocator.free(handle_str);

        const handle_id = try self.handleStringToId(handle_str);

        std.log.debug("SFTP FSETSTAT: handle={}", .{handle_id});

        if (!self.open_handles.contains(handle_id)) {
            try self.sendStatus(request_id, .SSH_FX_FAILURE, "Invalid handle", "");
            return;
        }

        const attrs = attributes.FileAttributes.decode(reader.buffer[reader.offset..]) catch {
            try self.sendStatus(request_id, .SSH_FX_BAD_MESSAGE, statusMessage(.SSH_FX_BAD_MESSAGE), "");
            return;
        };

        const handle = self.open_handles.getPtr(handle_id) orelse {
            try self.sendStatus(request_id, .SSH_FX_FAILURE, "Invalid handle", "");
            return;
        };

        self.applyHandleAttributes(handle, attrs) catch |err| {
            const status_code = statusFromError(err);
            try self.sendStatus(request_id, status_code, statusMessage(status_code), "");
            return;
        };

        try self.sendStatus(request_id, .SSH_FX_OK, "Success", "");
    }

    // ========================================================================
    // Helper Functions
    // ========================================================================

    fn normalizeRootPath(allocator: Allocator, root: []const u8) ![]u8 {
        const resolved = try std.fs.cwd().realpathAlloc(allocator, root);
        if (resolved.len <= 1) return resolved;

        var end = resolved.len;
        while (end > 1 and resolved[end - 1] == '/') : (end -= 1) {}
        if (end == resolved.len) return resolved;

        const trimmed = try allocator.dupe(u8, resolved[0..end]);
        allocator.free(resolved);
        return trimmed;
    }

    const max_path_depth = 256;

    fn resolveClientPath(self: *SftpServer, client_path: []const u8) ![]u8 {
        var parts = std.ArrayListUnmanaged([]const u8){};
        defer parts.deinit(self.allocator);

        var it = std.mem.splitScalar(u8, client_path, '/');
        while (it.next()) |segment| {
            if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
            if (std.mem.eql(u8, segment, "..")) {
                if (parts.items.len == 0) return error.AccessDenied;
                _ = parts.pop();
                continue;
            }
            try parts.append(self.allocator, segment);
            if (parts.items.len > max_path_depth) return error.AccessDenied;
        }

        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(self.allocator);

        try out.appendSlice(self.allocator, self.remote_root);
        for (parts.items) |part| {
            if (out.items.len == 0 or out.items[out.items.len - 1] != '/') {
                try out.append(self.allocator, '/');
            }
            try out.appendSlice(self.allocator, part);
        }

        if (out.items.len == 0) {
            try out.append(self.allocator, '/');
        }

        const candidate = out.items;
        const canonical = std.fs.cwd().realpathAlloc(self.allocator, candidate) catch |err| blk: {
            if (err != error.FileNotFound) return err;

            const parent = std.fs.path.dirname(candidate) orelse self.remote_root;
            const parent_real = try std.fs.cwd().realpathAlloc(self.allocator, parent);
            defer self.allocator.free(parent_real);

            const v = try self.toVirtualPath(parent_real);
            self.allocator.free(v);
            break :blk null;
        };

        if (canonical) |resolved| {
            const v = try self.toVirtualPath(resolved);
            self.allocator.free(v);
            // Return the canonical (resolved) path to prevent TOCTOU races
            out.deinit(self.allocator);
            return resolved;
        }

        return out.toOwnedSlice(self.allocator);
    }

    /// Like resolveClientPath but validates the parent directory instead of
    /// following symlinks on the final component.  Used by remove/unlink so
    /// that deleting a symlink removes the link itself rather than its target.
    fn resolveClientPathNoFollow(self: *SftpServer, client_path: []const u8) ![]u8 {
        var parts = std.ArrayListUnmanaged([]const u8){};
        defer parts.deinit(self.allocator);

        var it = std.mem.splitScalar(u8, client_path, '/');
        while (it.next()) |segment| {
            if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
            if (std.mem.eql(u8, segment, "..")) {
                if (parts.items.len == 0) return error.AccessDenied;
                _ = parts.pop();
                continue;
            }
            try parts.append(self.allocator, segment);
            if (parts.items.len > max_path_depth) return error.AccessDenied;
        }

        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(self.allocator);

        try out.appendSlice(self.allocator, self.remote_root);
        for (parts.items) |part| {
            if (out.items.len == 0 or out.items[out.items.len - 1] != '/') {
                try out.append(self.allocator, '/');
            }
            try out.appendSlice(self.allocator, part);
        }

        if (out.items.len == 0) {
            try out.append(self.allocator, '/');
        }

        // Validate parent directory is within root
        const candidate = out.items;
        const parent = std.fs.path.dirname(candidate) orelse self.remote_root;
        const parent_real = try std.fs.cwd().realpathAlloc(self.allocator, parent);
        defer self.allocator.free(parent_real);

        const v = try self.toVirtualPath(parent_real);
        self.allocator.free(v);

        return out.toOwnedSlice(self.allocator);
    }

    fn toVirtualPath(self: *SftpServer, resolved_path: []const u8) ![]u8 {
        if (std.mem.eql(u8, resolved_path, self.remote_root)) {
            return self.allocator.dupe(u8, "/");
        }

        if (!std.mem.startsWith(u8, resolved_path, self.remote_root)) {
            return error.AccessDenied;
        }

        if (self.remote_root.len > 1 and resolved_path.len > self.remote_root.len and resolved_path[self.remote_root.len] != '/') {
            return error.AccessDenied;
        }

        const suffix = resolved_path[self.remote_root.len..];
        if (suffix.len == 0) {
            return self.allocator.dupe(u8, "/");
        }
        if (suffix[0] == '/') {
            return self.allocator.dupe(u8, suffix);
        }

        return std.fmt.allocPrint(self.allocator, "/{s}", .{suffix});
    }

    const max_open_handles = 256;

    fn openFile(self: *SftpServer, path: []const u8, flags: protocol.OpenFlags) !u64 {
        if (self.open_handles.count() >= max_open_handles) return error.ProcessFdQuotaExceeded;
        const handle_id = self.next_handle_id;
        self.next_handle_id += 1;

        const file_handle = try FileHandle.open(path, flags);
        try self.open_handles.put(handle_id, .{ .file = file_handle });

        return handle_id;
    }

    fn openDirectory(self: *SftpServer, path: []const u8) !u64 {
        if (self.open_handles.count() >= max_open_handles) return error.ProcessFdQuotaExceeded;
        const handle_id = self.next_handle_id;
        self.next_handle_id += 1;

        const dir_handle = try DirectoryHandle.open(self.allocator, path);
        try self.open_handles.put(handle_id, .{ .directory = dir_handle });

        return handle_id;
    }

    fn getFileAttributes(self: *SftpServer, path: []const u8, follow_symlinks: bool) !attributes.FileAttributes {
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        var st: c.struct_stat = undefined;
        const rc = if (follow_symlinks)
            c.stat(path_z.ptr, &st)
        else
            c.lstat(path_z.ptr, &st);
        if (rc != 0) return error.FileNotFound;

        var attrs = attributes.FileAttributes.init();
        _ = attrs.withSize(@intCast(st.st_size));
        _ = attrs.withUidGid(@intCast(st.st_uid), @intCast(st.st_gid));
        _ = attrs.withPermissions(@intCast(st.st_mode));
        _ = attrs.withTimes(@intCast(st.st_atim.tv_sec), @intCast(st.st_mtim.tv_sec));
        return attrs;
    }

    fn applyPathAttributes(self: *SftpServer, path: []const u8, attrs: attributes.FileAttributes) !void {
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        if (attrs.flags.size and attrs.size != null) {
            var file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
            defer file.close();
            try file.setEndPos(attrs.size.?);
        }

        if (attrs.flags.permissions and attrs.permissions != null) {
            const mode_bits: c.mode_t = @intCast(attrs.permissions.? & 0o7777);
            if (c.chmod(path_z.ptr, mode_bits) != 0) {
                return error.AccessDenied;
            }
        }

        if (attrs.flags.uidgid and attrs.uid != null and attrs.gid != null) {
            if (c.chown(path_z.ptr, @intCast(attrs.uid.?), @intCast(attrs.gid.?)) != 0) {
                return error.AccessDenied;
            }
        }

        if (attrs.flags.acmodtime and attrs.atime != null and attrs.mtime != null) {
            var utb = c.struct_utimbuf{
                .actime = @intCast(attrs.atime.?),
                .modtime = @intCast(attrs.mtime.?),
            };
            if (c.utime(path_z.ptr, &utb) != 0) {
                return error.AccessDenied;
            }
        }
    }

    fn applyHandleAttributes(_: *SftpServer, handle: *OpenHandle, attrs: attributes.FileAttributes) !void {
        switch (handle.*) {
            .file => |*f| {
                if (attrs.flags.size and attrs.size != null) {
                    try f.file.setEndPos(attrs.size.?);
                }

                if (attrs.flags.permissions and attrs.permissions != null) {
                    const mode_bits: c.mode_t = @intCast(attrs.permissions.? & 0o7777);
                    if (c.fchmod(f.file.handle, mode_bits) != 0) {
                        return error.AccessDenied;
                    }
                }

                if (attrs.flags.uidgid and attrs.uid != null and attrs.gid != null) {
                    if (c.fchown(f.file.handle, @intCast(attrs.uid.?), @intCast(attrs.gid.?)) != 0) {
                        return error.AccessDenied;
                    }
                }

                if (attrs.flags.acmodtime and attrs.atime != null and attrs.mtime != null) {
                    var times = [_]c.struct_timespec{
                        .{ .tv_sec = @intCast(attrs.atime.?), .tv_nsec = 0 },
                        .{ .tv_sec = @intCast(attrs.mtime.?), .tv_nsec = 0 },
                    };
                    if (c.futimens(f.file.handle, &times) != 0) {
                        return error.AccessDenied;
                    }
                }
            },
            .directory => return error.OperationUnsupported,
        }
    }

    fn handleIdToString(self: *SftpServer, id: u64) ![]u8 {
        const str = try std.fmt.allocPrint(self.allocator, "{x:0>16}", .{id});
        return str;
    }

    fn handleStringToId(self: *SftpServer, str: []const u8) !u64 {
        _ = self;
        return std.fmt.parseInt(u64, str, 16);
    }

    fn sendStatus(
        self: *SftpServer,
        request_id: u32,
        status_code: protocol.StatusCode,
        message: []const u8,
        lang: []const u8,
    ) !void {
        const status = protocol.Status{
            .request_id = request_id,
            .status_code = status_code,
            .error_message = message,
            .language_tag = lang,
        };
        const response = try status.encode(self.allocator);
        defer self.allocator.free(response);
        try self.channel.send(response);
    }

    fn sendAttrsResponse(self: *SftpServer, request_id: u32, attrs: attributes.FileAttributes) !void {
        const attrs_data = try attrs.encode(self.allocator);
        defer self.allocator.free(attrs_data);

        const packet_size = 4 + 1 + 4 + attrs_data.len;
        const packet = try self.allocator.alloc(u8, packet_size);
        defer self.allocator.free(packet);

        var writer = wire.Writer{ .buffer = packet };
        try writer.writeUint32(@intCast(packet_size - 4));
        try writer.writeByte(@intFromEnum(protocol.PacketType.SSH_FXP_ATTRS));
        try writer.writeUint32(request_id);
        @memcpy(packet[writer.offset..][0..attrs_data.len], attrs_data);

        try self.channel.send(packet);
    }

    fn sendNameResponse(self: *SftpServer, request_id: u32, entries: []const DirEntry) !void {
        // Calculate packet size
        var packet_size: usize = 4 + 1 + 4 + 4; // length + type + request_id + count
        for (entries) |entry| {
            packet_size += 4 + entry.filename.len; // filename
            packet_size += 4 + entry.longname.len; // longname
            const attrs_data = try entry.attrs.encode(self.allocator);
            defer self.allocator.free(attrs_data);
            packet_size += attrs_data.len;
        }

        const packet = try self.allocator.alloc(u8, packet_size);
        defer self.allocator.free(packet);

        var writer = wire.Writer{ .buffer = packet };
        try writer.writeUint32(@intCast(packet_size - 4));
        try writer.writeByte(@intFromEnum(protocol.PacketType.SSH_FXP_NAME));
        try writer.writeUint32(request_id);
        try writer.writeUint32(@intCast(entries.len));

        for (entries) |entry| {
            try writer.writeString(entry.filename);
            try writer.writeString(entry.longname);
            const attrs_data = try entry.attrs.encode(self.allocator);
            defer self.allocator.free(attrs_data);
            @memcpy(packet[writer.offset..][0..attrs_data.len], attrs_data);
            writer.offset += attrs_data.len;
        }

        try self.channel.send(packet);
    }
};

// ============================================================================
// Handle Management
// ============================================================================

const OpenHandle = union(enum) {
    file: FileHandle,
    directory: DirectoryHandle,

    fn close(self: *OpenHandle) void {
        switch (self.*) {
            .file => |*f| f.close(),
            .directory => |*d| d.close(),
        }
    }
};

const FileHandle = struct {
    file: std.fs.File,
    append_mode: bool,

    fn open(path: []const u8, flags: protocol.OpenFlags) !FileHandle {
        const open_flags: std.fs.File.OpenFlags = .{
            .mode = if (flags.read and !flags.write) .read_only else if (flags.write) .read_write else .read_only,
        };

        const file = if (flags.creat) blk: {
            const create_flags: std.fs.File.CreateFlags = .{
                .read = flags.read,
                .truncate = flags.trunc,
                .exclusive = flags.excl,
            };
            break :blk try std.fs.cwd().createFile(path, create_flags);
        } else blk: {
            break :blk try std.fs.cwd().openFile(path, open_flags);
        };

        return FileHandle{ .file = file, .append_mode = flags.append };
    }

    fn close(self: *FileHandle) void {
        self.file.close();
    }

    fn readAt(self: *FileHandle, allocator: Allocator, offset: u64, len: u32) ![]u8 {
        const buffer = try allocator.alloc(u8, len);
        errdefer allocator.free(buffer);

        const bytes_read = try self.file.preadAll(buffer, offset);

        // Return only the bytes actually read
        if (bytes_read < len) {
            if (bytes_read == 0) {
                allocator.free(buffer);
                return error.EndOfStream;
            }
            const trimmed = try allocator.realloc(buffer, bytes_read);
            return trimmed;
        }

        return buffer;
    }

    fn writeAt(self: *FileHandle, offset: u64, data: []const u8) !void {
        if (self.append_mode) {
            const end_pos = try self.file.getEndPos();
            try self.file.pwriteAll(data, end_pos);
            return;
        }

        try self.file.pwriteAll(data, offset);
    }

    fn getAttributes(self: *FileHandle) !attributes.FileAttributes {
        const stat = try self.file.stat();
        var attrs = attributes.FileAttributes.init();
        _ = attrs.withSize(@intCast(stat.size));
        _ = attrs.withPermissions(@intCast(stat.mode));
        _ = attrs.withTimes(@intCast(@divFloor(stat.atime, 1_000_000_000)), @intCast(@divFloor(stat.mtime, 1_000_000_000)));
        return attrs;
    }
};

const DirectoryHandle = struct {
    allocator: Allocator,
    dir: std.fs.Dir,
    iterator: ?std.fs.Dir.Iterator,

    fn open(allocator: Allocator, path: []const u8) !DirectoryHandle {
        const dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
        return DirectoryHandle{
            .allocator = allocator,
            .dir = dir,
            .iterator = null,
        };
    }

    fn close(self: *DirectoryHandle) void {
        self.dir.close();
    }

    fn readEntries(self: *DirectoryHandle, allocator: Allocator) ![]DirEntry {
        // Initialize iterator if not already done
        if (self.iterator == null) {
            self.iterator = self.dir.iterate();
        }

        // Read up to 64 entries per request (typical batch size)
        var entries = std.ArrayListUnmanaged(DirEntry){};
        errdefer {
            for (entries.items) |entry| {
                allocator.free(entry.filename);
                allocator.free(entry.longname);
            }
            entries.deinit(allocator);
        }

        var count: usize = 0;
        while (count < 64) : (count += 1) {
            const entry = try self.iterator.?.next() orelse {
                if (count == 0) return error.EndOfStream;
                break;
            };

            const filename = try allocator.dupe(u8, entry.name);
            errdefer allocator.free(filename);

            // Create longname (ls -l style)
            const kind_char: u8 = switch (entry.kind) {
                .directory => 'd',
                .file => '-',
                .sym_link => 'l',
                else => '?',
            };
            const longname = try std.fmt.allocPrint(allocator, "{c}rw-r--r-- 1 user group 0 Jan  1 00:00 {s}", .{ kind_char, entry.name });

            var attrs = attributes.FileAttributes.init();
            if (self.dir.statFile(entry.name)) |stat| {
                _ = attrs.withSize(@intCast(stat.size));
                _ = attrs.withPermissions(@intCast(stat.mode));
                _ = attrs.withTimes(@intCast(@divFloor(stat.atime, 1_000_000_000)), @intCast(@divFloor(stat.mtime, 1_000_000_000)));
            } else |_| {
                _ = attrs.withSize(0);
                const fallback_mode: u32 = switch (entry.kind) {
                    .directory => 0o040755,
                    .sym_link => 0o120777,
                    else => 0o100644,
                };
                _ = attrs.withPermissions(fallback_mode);
                _ = attrs.withTimes(0, 0);
            }

            try entries.append(allocator, DirEntry{
                .filename = filename,
                .longname = longname,
                .attrs = attrs,
            });
        }

        return try entries.toOwnedSlice(allocator);
    }

    fn getAttributes(self: *DirectoryHandle) !attributes.FileAttributes {
        const stat = try self.dir.stat();
        var attrs = attributes.FileAttributes.init();
        _ = attrs.withSize(@intCast(stat.size));
        _ = attrs.withPermissions(@intCast(stat.mode));
        _ = attrs.withTimes(@intCast(@divFloor(stat.atime, 1_000_000_000)), @intCast(@divFloor(stat.mtime, 1_000_000_000)));
        return attrs;
    }
};

const DirEntry = struct {
    filename: []const u8,
    longname: []const u8,
    attrs: attributes.FileAttributes,
};

// ============================================================================
// Error Mapping
// ============================================================================

fn statusMessage(status_code: protocol.StatusCode) []const u8 {
    return switch (status_code) {
        .SSH_FX_OK => "Success",
        .SSH_FX_EOF => "End of file",
        .SSH_FX_NO_SUCH_FILE => "No such file or directory",
        .SSH_FX_PERMISSION_DENIED => "Permission denied",
        .SSH_FX_BAD_MESSAGE => "Bad message",
        .SSH_FX_OP_UNSUPPORTED => "Operation not supported",
        .SSH_FX_FAILURE => "Failure",
        else => "Failure",
    };
}

fn statusFromError(err: anyerror) protocol.StatusCode {
    return switch (err) {
        error.FileNotFound,
        error.NotDir,
        error.IsDir,
        error.SymLinkLoop,
        error.BadPathName,
        => .SSH_FX_NO_SUCH_FILE,
        error.AccessDenied,
        error.PermissionDenied,
        error.ReadOnlyFileSystem,
        => .SSH_FX_PERMISSION_DENIED,
        error.OperationUnsupported => .SSH_FX_OP_UNSUPPORTED,
        error.InvalidUtf8,
        error.InvalidHandle,
        error.UnexpectedPacketType,
        error.EndOfBuffer,
        => .SSH_FX_BAD_MESSAGE,
        error.PathAlreadyExists,
        error.NameTooLong,
        error.NoSpaceLeft,
        error.FileBusy,
        => .SSH_FX_FAILURE,
        error.EndOfStream => .SSH_FX_EOF,
        else => .SSH_FX_FAILURE,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "SftpServer - statusFromError mapping" {
    const testing = std.testing;

    try testing.expectEqual(protocol.StatusCode.SSH_FX_NO_SUCH_FILE, statusFromError(error.FileNotFound));
    try testing.expectEqual(protocol.StatusCode.SSH_FX_NO_SUCH_FILE, statusFromError(error.NotDir));
    try testing.expectEqual(protocol.StatusCode.SSH_FX_PERMISSION_DENIED, statusFromError(error.AccessDenied));
    try testing.expectEqual(protocol.StatusCode.SSH_FX_PERMISSION_DENIED, statusFromError(error.ReadOnlyFileSystem));
    try testing.expectEqual(protocol.StatusCode.SSH_FX_BAD_MESSAGE, statusFromError(error.EndOfBuffer));
    try testing.expectEqual(protocol.StatusCode.SSH_FX_EOF, statusFromError(error.EndOfStream));
    try testing.expectEqual(protocol.StatusCode.SSH_FX_FAILURE, statusFromError(error.OutOfMemory));
}

test "SftpServer - resolveClientPath blocks traversal" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var server = SftpServer{
        .allocator = allocator,
        .channel = .{},
        .remote_root = try std.fs.cwd().realpathAlloc(allocator, "."),
        .version = 3,
        .next_handle_id = 1,
        .open_handles = std.AutoHashMap(u64, OpenHandle).init(allocator),
    };
    defer allocator.free(server.remote_root);
    defer server.open_handles.deinit();

    const blocked = server.resolveClientPath("../../etc/passwd");
    try testing.expectError(error.AccessDenied, blocked);
}

test "SftpServer - toVirtualPath maps root-relative paths" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const root = try std.fs.cwd().realpathAlloc(allocator, ".");
    var server = SftpServer{
        .allocator = allocator,
        .channel = .{},
        .remote_root = root,
        .version = 3,
        .next_handle_id = 1,
        .open_handles = std.AutoHashMap(u64, OpenHandle).init(allocator),
    };
    defer allocator.free(server.remote_root);
    defer server.open_handles.deinit();

    const child = try std.fmt.allocPrint(allocator, "{s}/tmp", .{server.remote_root});
    defer allocator.free(child);

    const virtual = try server.toVirtualPath(child);
    defer allocator.free(virtual);

    try testing.expectEqualStrings("/tmp", virtual);
}

test "SftpServer - applyPathAttributes updates file size" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const tmp_base = try std.fmt.allocPrint(allocator, "/tmp/liblink-sftp-{}", .{std.time.nanoTimestamp()});
    defer allocator.free(tmp_base);
    defer std.fs.cwd().deleteTree(tmp_base) catch {};

    try std.fs.cwd().makePath(tmp_base);

    const file_path = try std.fmt.allocPrint(allocator, "{s}/file.bin", .{tmp_base});
    defer allocator.free(file_path);

    {
        var file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll("hello");
    }

    var server = SftpServer{
        .allocator = allocator,
        .channel = .{},
        .remote_root = try allocator.dupe(u8, "/"),
        .version = 3,
        .next_handle_id = 1,
        .open_handles = std.AutoHashMap(u64, OpenHandle).init(allocator),
    };
    defer allocator.free(server.remote_root);
    defer server.open_handles.deinit();

    var attrs = attributes.FileAttributes.init();
    _ = attrs.withSize(2);

    try server.applyPathAttributes(file_path, attrs);

    const stat = try std.fs.cwd().statFile(file_path);
    try testing.expectEqual(@as(u64, 2), stat.size);
}

test "SftpServer - resolveClientPath joins against remote root" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(root);

    var server = SftpServer{
        .allocator = allocator,
        .channel = .{},
        .remote_root = try allocator.dupe(u8, root),
        .version = 3,
        .next_handle_id = 1,
        .open_handles = std.AutoHashMap(u64, OpenHandle).init(allocator),
    };
    defer allocator.free(server.remote_root);
    defer server.open_handles.deinit();

    const resolved = try server.resolveClientPath("/lib");
    defer allocator.free(resolved);

    const expected = try std.fmt.allocPrint(allocator, "{s}/lib", .{root});
    defer allocator.free(expected);

    try testing.expectEqualStrings(expected, resolved);
}

test "SftpServer - open/write/read flow" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const tmp_base = try std.fmt.allocPrint(allocator, "/tmp/liblink-sftp-flow-{}", .{std.time.nanoTimestamp()});
    defer allocator.free(tmp_base);
    defer std.fs.cwd().deleteTree(tmp_base) catch {};

    try std.fs.cwd().makePath(tmp_base);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/flow.txt", .{tmp_base});
    defer allocator.free(file_path);

    var server = SftpServer{
        .allocator = allocator,
        .channel = .{},
        .remote_root = try allocator.dupe(u8, "/"),
        .version = 3,
        .next_handle_id = 1,
        .open_handles = std.AutoHashMap(u64, OpenHandle).init(allocator),
    };
    defer allocator.free(server.remote_root);
    defer server.open_handles.deinit();

    const flags = protocol.OpenFlags{
        .read = true,
        .write = true,
        .creat = true,
        .trunc = true,
    };

    const handle_id = try server.openFile(file_path, flags);
    const handle = server.open_handles.getPtr(handle_id) orelse return error.TestUnexpectedResult;
    if (handle.* != .file) return error.TestUnexpectedResult;

    try handle.file.writeAt(0, "abc123");
    const read_back = try handle.file.readAt(allocator, 0, 6);
    defer allocator.free(read_back);
    try testing.expectEqualStrings("abc123", read_back);

    var removed = server.open_handles.fetchRemove(handle_id).?.value;
    removed.close();
}

test "SftpServer - stat and lstat differ on symlink" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const tmp_base = try std.fmt.allocPrint(allocator, "/tmp/liblink-sftp-link-{}", .{std.time.nanoTimestamp()});
    defer allocator.free(tmp_base);
    defer std.fs.cwd().deleteTree(tmp_base) catch {};

    try std.fs.cwd().makePath(tmp_base);

    const target = try std.fmt.allocPrint(allocator, "{s}/target_long_name.txt", .{tmp_base});
    defer allocator.free(target);
    const link = try std.fmt.allocPrint(allocator, "{s}/lnk", .{tmp_base});
    defer allocator.free(link);

    {
        var file = try std.fs.cwd().createFile(target, .{});
        defer file.close();
        try file.writeAll("xyz");
    }

    const target_z = try allocator.dupeZ(u8, target);
    defer allocator.free(target_z);
    const link_z = try allocator.dupeZ(u8, link);
    defer allocator.free(link_z);
    try testing.expectEqual(@as(c_int, 0), c.symlink(target_z.ptr, link_z.ptr));

    var server = SftpServer{
        .allocator = allocator,
        .channel = .{},
        .remote_root = try allocator.dupe(u8, "/"),
        .version = 3,
        .next_handle_id = 1,
        .open_handles = std.AutoHashMap(u64, OpenHandle).init(allocator),
    };
    defer allocator.free(server.remote_root);
    defer server.open_handles.deinit();

    const stat_attrs = try server.getFileAttributes(link, true);
    const lstat_attrs = try server.getFileAttributes(link, false);

    try testing.expectEqual(@as(u64, 3), stat_attrs.size.?);
    try testing.expect(lstat_attrs.size.? != stat_attrs.size.?);
}

test "SftpServer - handle ID to string conversion" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Mock server for testing
    var server = SftpServer{
        .allocator = allocator,
        .channel = .{},
        .remote_root = try allocator.dupe(u8, "/"),
        .version = 3,
        .next_handle_id = 1,
        .open_handles = std.AutoHashMap(u64, OpenHandle).init(allocator),
    };
    defer allocator.free(server.remote_root);
    defer server.open_handles.deinit();

    const id: u64 = 0x123456789ABCDEF0;
    const str = try server.handleIdToString(id);
    defer allocator.free(str);

    try testing.expectEqualStrings("123456789abcdef0", str);

    const parsed_id = try server.handleStringToId(str);
    try testing.expectEqual(id, parsed_id);
}
