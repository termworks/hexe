const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const attributes = @import("attributes.zig");

/// SFTP client for file operations over an SSH channel
///
/// The client manages:
/// - SFTP protocol version negotiation
/// - Request ID generation and tracking
/// - File and directory handle management
/// - Synchronous file operations
pub const SftpClient = struct {
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
    version: u32,
    next_request_id: u32,

    /// SSH channel for SFTP communication
    pub const Channel = @import("channel_adapter.zig").SftpChannel;

    /// Initialize SFTP client and perform version negotiation
    pub fn init(allocator: Allocator, channel: Channel) !SftpClient {
        var client = SftpClient{
            .allocator = allocator,
            .channel = ChannelRef.fromChannel(channel),
            .version = 0,
            .next_request_id = 1,
        };

        // Send INIT
        const init_msg = protocol.Init{ .version = protocol.SFTP_VERSION };
        const init_packet = try init_msg.encode(allocator);
        defer allocator.free(init_packet);
        try client.channel.send(init_packet);

        // Receive VERSION
        const version_data = try client.channel.receive(allocator);
        defer allocator.free(version_data);

        var version = try protocol.Version.decode(allocator, version_data);
        defer version.deinit(allocator);

        client.version = version.version;

        return client;
    }

    pub fn initWithHooks(
        allocator: Allocator,
        ctx: *anyopaque,
        send_fn: SendFn,
        receive_fn: ReceiveFn,
        deinit_fn: ?DeinitFn,
    ) !SftpClient {
        var client = SftpClient{
            .allocator = allocator,
            .channel = ChannelRef.fromHooks(ctx, send_fn, receive_fn, deinit_fn),
            .version = 0,
            .next_request_id = 1,
        };

        const init_msg = protocol.Init{ .version = protocol.SFTP_VERSION };
        const init_packet = try init_msg.encode(allocator);
        defer allocator.free(init_packet);
        try client.channel.send(init_packet);

        const version_data = try client.channel.receive(allocator);
        defer allocator.free(version_data);

        var version = try protocol.Version.decode(allocator, version_data);
        defer version.deinit(allocator);
        client.version = version.version;

        return client;
    }

    /// Clean up client resources
    pub fn deinit(self: *SftpClient) void {
        self.channel.deinit();
    }

    /// Get next request ID
    fn getNextRequestId(self: *SftpClient) u32 {
        const id = self.next_request_id;
        self.next_request_id += 1;
        return id;
    }

    /// Open a file
    pub fn open(
        self: *SftpClient,
        path: []const u8,
        flags: protocol.OpenFlags,
        attrs: attributes.FileAttributes,
    ) !Handle {
        const request_id = self.getNextRequestId();

        // Encode OPEN request
        const attrs_data = try attrs.encode(self.allocator);
        defer self.allocator.free(attrs_data);

        // Calculate packet size
        const packet_size = 4 + 1 + 4 + 4 + path.len + 4 + attrs_data.len;
        const packet = try self.allocator.alloc(u8, packet_size);
        errdefer self.allocator.free(packet);

        var offset: usize = 0;

        // Write length (packet_size - 4)
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(packet_size - 4), .big);
        offset += 4;

        // Write packet type
        packet[offset] = @intFromEnum(protocol.PacketType.SSH_FXP_OPEN);
        offset += 1;

        // Write request ID
        std.mem.writeInt(u32, packet[offset..][0..4], request_id, .big);
        offset += 4;

        // Write path (string)
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(path.len), .big);
        offset += 4;
        @memcpy(packet[offset..][0..path.len], path);
        offset += path.len;

        // Write flags
        std.mem.writeInt(u32, packet[offset..][0..4], flags.toU32(), .big);
        offset += 4;

        // Write attributes
        @memcpy(packet[offset..][0..attrs_data.len], attrs_data);

        // Send request
        try self.channel.send(packet);
        self.allocator.free(packet);

        // Receive response (HANDLE or STATUS)
        const response = try self.channel.receive(self.allocator);
        defer self.allocator.free(response);

        // Check packet type
        if (response.len < 5) return error.InvalidResponse;
        const response_type = response[4];

        if (response_type == @intFromEnum(protocol.PacketType.SSH_FXP_HANDLE)) {
            var handle_msg = try protocol.Handle.decode(self.allocator, response);
            defer handle_msg.deinit(self.allocator);

            // Duplicate handle data
            const handle_data = try self.allocator.dupe(u8, handle_msg.handle);
            return Handle{ .data = handle_data };
        } else if (response_type == @intFromEnum(protocol.PacketType.SSH_FXP_STATUS)) {
            var status = try protocol.Status.decode(self.allocator, response);
            defer status.deinit(self.allocator);

            return errorFromStatus(status.status_code);
        }

        return error.InvalidResponse;
    }

    /// Close a file or directory handle
    pub fn close(self: *SftpClient, handle: Handle) !void {
        const request_id = self.getNextRequestId();

        // Encode CLOSE request
        const packet_size = 4 + 1 + 4 + 4 + handle.data.len;
        const packet = try self.allocator.alloc(u8, packet_size);
        defer self.allocator.free(packet);

        var offset: usize = 0;

        // Write length
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(packet_size - 4), .big);
        offset += 4;

        // Write packet type
        packet[offset] = @intFromEnum(protocol.PacketType.SSH_FXP_CLOSE);
        offset += 1;

        // Write request ID
        std.mem.writeInt(u32, packet[offset..][0..4], request_id, .big);
        offset += 4;

        // Write handle (string)
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(handle.data.len), .big);
        offset += 4;
        @memcpy(packet[offset..][0..handle.data.len], handle.data);

        // Send request
        try self.channel.send(packet);

        // Receive STATUS response
        const response = try self.channel.receive(self.allocator);
        defer self.allocator.free(response);

        var status = try protocol.Status.decode(self.allocator, response);
        defer status.deinit(self.allocator);

        if (status.status_code != .SSH_FX_OK) {
            return errorFromStatus(status.status_code);
        }
    }

    /// Read from a file
    pub fn read(
        self: *SftpClient,
        handle: Handle,
        offset: u64,
        len: u32,
    ) ![]u8 {
        const request_id = self.getNextRequestId();

        // Encode READ request
        const packet_size = 4 + 1 + 4 + 4 + handle.data.len + 8 + 4;
        const packet = try self.allocator.alloc(u8, packet_size);
        defer self.allocator.free(packet);

        var pkt_offset: usize = 0;

        // Write length
        std.mem.writeInt(u32, packet[pkt_offset..][0..4], @intCast(packet_size - 4), .big);
        pkt_offset += 4;

        // Write packet type
        packet[pkt_offset] = @intFromEnum(protocol.PacketType.SSH_FXP_READ);
        pkt_offset += 1;

        // Write request ID
        std.mem.writeInt(u32, packet[pkt_offset..][0..4], request_id, .big);
        pkt_offset += 4;

        // Write handle
        std.mem.writeInt(u32, packet[pkt_offset..][0..4], @intCast(handle.data.len), .big);
        pkt_offset += 4;
        @memcpy(packet[pkt_offset..][0..handle.data.len], handle.data);
        pkt_offset += handle.data.len;

        // Write offset
        std.mem.writeInt(u64, packet[pkt_offset..][0..8], offset, .big);
        pkt_offset += 8;

        // Write length
        std.mem.writeInt(u32, packet[pkt_offset..][0..4], len, .big);

        // Send request
        try self.channel.send(packet);

        // Receive response (DATA or STATUS)
        const response = try self.channel.receive(self.allocator);
        defer self.allocator.free(response);

        if (response.len < 5) return error.InvalidResponse;
        const response_type = response[4];

        if (response_type == @intFromEnum(protocol.PacketType.SSH_FXP_DATA)) {
            var data_msg = try protocol.Data.decode(self.allocator, response);
            defer data_msg.deinit(self.allocator);

            // Duplicate data
            return try self.allocator.dupe(u8, data_msg.data);
        } else if (response_type == @intFromEnum(protocol.PacketType.SSH_FXP_STATUS)) {
            var status = try protocol.Status.decode(self.allocator, response);
            defer status.deinit(self.allocator);

            return errorFromStatus(status.status_code);
        }

        return error.InvalidResponse;
    }

    /// Write to a file
    pub fn write(
        self: *SftpClient,
        handle: Handle,
        offset: u64,
        data: []const u8,
    ) !void {
        const request_id = self.getNextRequestId();

        // Encode WRITE request
        const packet_size = 4 + 1 + 4 + 4 + handle.data.len + 8 + 4 + data.len;
        const packet = try self.allocator.alloc(u8, packet_size);
        defer self.allocator.free(packet);

        var pkt_offset: usize = 0;

        // Write length
        std.mem.writeInt(u32, packet[pkt_offset..][0..4], @intCast(packet_size - 4), .big);
        pkt_offset += 4;

        // Write packet type
        packet[pkt_offset] = @intFromEnum(protocol.PacketType.SSH_FXP_WRITE);
        pkt_offset += 1;

        // Write request ID
        std.mem.writeInt(u32, packet[pkt_offset..][0..4], request_id, .big);
        pkt_offset += 4;

        // Write handle
        std.mem.writeInt(u32, packet[pkt_offset..][0..4], @intCast(handle.data.len), .big);
        pkt_offset += 4;
        @memcpy(packet[pkt_offset..][0..handle.data.len], handle.data);
        pkt_offset += handle.data.len;

        // Write offset
        std.mem.writeInt(u64, packet[pkt_offset..][0..8], offset, .big);
        pkt_offset += 8;

        // Write data (string)
        std.mem.writeInt(u32, packet[pkt_offset..][0..4], @intCast(data.len), .big);
        pkt_offset += 4;
        @memcpy(packet[pkt_offset..][0..data.len], data);

        // Send request
        try self.channel.send(packet);

        // Receive STATUS response
        const response = try self.channel.receive(self.allocator);
        defer self.allocator.free(response);

        var status = try protocol.Status.decode(self.allocator, response);
        defer status.deinit(self.allocator);

        if (status.status_code != .SSH_FX_OK) {
            return errorFromStatus(status.status_code);
        }
    }

    /// Get file attributes by path
    pub fn stat(self: *SftpClient, path: []const u8) !attributes.FileAttributes {
        return try self.statInternal(path, .SSH_FXP_STAT);
    }

    /// Get file attributes by path (don't follow symlinks)
    pub fn lstat(self: *SftpClient, path: []const u8) !attributes.FileAttributes {
        return try self.statInternal(path, .SSH_FXP_LSTAT);
    }

    /// Get file attributes by handle
    pub fn fstat(self: *SftpClient, handle: Handle) !attributes.FileAttributes {
        const request_id = self.getNextRequestId();

        // Encode FSTAT request
        const packet_size = 4 + 1 + 4 + 4 + handle.data.len;
        const packet = try self.allocator.alloc(u8, packet_size);
        defer self.allocator.free(packet);

        var offset: usize = 0;

        // Write length
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(packet_size - 4), .big);
        offset += 4;

        // Write packet type
        packet[offset] = @intFromEnum(protocol.PacketType.SSH_FXP_FSTAT);
        offset += 1;

        // Write request ID
        std.mem.writeInt(u32, packet[offset..][0..4], request_id, .big);
        offset += 4;

        // Write handle
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(handle.data.len), .big);
        offset += 4;
        @memcpy(packet[offset..][0..handle.data.len], handle.data);

        // Send request
        try self.channel.send(packet);

        // Receive response (ATTRS or STATUS)
        const response = try self.channel.receive(self.allocator);
        defer self.allocator.free(response);

        if (response.len < 5) return error.InvalidResponse;
        const response_type = response[4];

        if (response_type == @intFromEnum(protocol.PacketType.SSH_FXP_ATTRS)) {
            // Skip length (4) + type (1) + request_id (4) = 9 bytes
            return try attributes.FileAttributes.decode(response[9..]);
        } else if (response_type == @intFromEnum(protocol.PacketType.SSH_FXP_STATUS)) {
            var status = try protocol.Status.decode(self.allocator, response);
            defer status.deinit(self.allocator);

            return errorFromStatus(status.status_code);
        }

        return error.InvalidResponse;
    }

    /// Set file attributes by path
    pub fn setstat(
        self: *SftpClient,
        path: []const u8,
        attrs: attributes.FileAttributes,
    ) !void {
        const request_id = self.getNextRequestId();

        const attrs_data = try attrs.encode(self.allocator);
        defer self.allocator.free(attrs_data);

        // Encode SETSTAT request
        const packet_size = 4 + 1 + 4 + 4 + path.len + attrs_data.len;
        const packet = try self.allocator.alloc(u8, packet_size);
        defer self.allocator.free(packet);

        var offset: usize = 0;

        // Write length
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(packet_size - 4), .big);
        offset += 4;

        // Write packet type
        packet[offset] = @intFromEnum(protocol.PacketType.SSH_FXP_SETSTAT);
        offset += 1;

        // Write request ID
        std.mem.writeInt(u32, packet[offset..][0..4], request_id, .big);
        offset += 4;

        // Write path
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(path.len), .big);
        offset += 4;
        @memcpy(packet[offset..][0..path.len], path);
        offset += path.len;

        // Write attributes
        @memcpy(packet[offset..][0..attrs_data.len], attrs_data);

        // Send request
        try self.channel.send(packet);

        // Receive STATUS response
        const response = try self.channel.receive(self.allocator);
        defer self.allocator.free(response);

        var status = try protocol.Status.decode(self.allocator, response);
        defer status.deinit(self.allocator);

        if (status.status_code != .SSH_FX_OK) {
            return errorFromStatus(status.status_code);
        }
    }

    /// Set file attributes by handle
    pub fn fsetstat(
        self: *SftpClient,
        handle: Handle,
        attrs: attributes.FileAttributes,
    ) !void {
        const request_id = self.getNextRequestId();

        const attrs_data = try attrs.encode(self.allocator);
        defer self.allocator.free(attrs_data);

        // Encode FSETSTAT request
        const packet_size = 4 + 1 + 4 + 4 + handle.data.len + attrs_data.len;
        const packet = try self.allocator.alloc(u8, packet_size);
        defer self.allocator.free(packet);

        var offset: usize = 0;

        // Write length
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(packet_size - 4), .big);
        offset += 4;

        // Write packet type
        packet[offset] = @intFromEnum(protocol.PacketType.SSH_FXP_FSETSTAT);
        offset += 1;

        // Write request ID
        std.mem.writeInt(u32, packet[offset..][0..4], request_id, .big);
        offset += 4;

        // Write handle
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(handle.data.len), .big);
        offset += 4;
        @memcpy(packet[offset..][0..handle.data.len], handle.data);
        offset += handle.data.len;

        // Write attributes
        @memcpy(packet[offset..][0..attrs_data.len], attrs_data);

        // Send request
        try self.channel.send(packet);

        // Receive STATUS response
        const response = try self.channel.receive(self.allocator);
        defer self.allocator.free(response);

        var status = try protocol.Status.decode(self.allocator, response);
        defer status.deinit(self.allocator);

        if (status.status_code != .SSH_FX_OK) {
            return errorFromStatus(status.status_code);
        }
    }

    /// Open a directory
    pub fn opendir(self: *SftpClient, path: []const u8) !Handle {
        const request_id = self.getNextRequestId();

        // Encode OPENDIR request
        const packet_size = 4 + 1 + 4 + 4 + path.len;
        const packet = try self.allocator.alloc(u8, packet_size);
        defer self.allocator.free(packet);

        var offset: usize = 0;

        // Write length
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(packet_size - 4), .big);
        offset += 4;

        // Write packet type
        packet[offset] = @intFromEnum(protocol.PacketType.SSH_FXP_OPENDIR);
        offset += 1;

        // Write request ID
        std.mem.writeInt(u32, packet[offset..][0..4], request_id, .big);
        offset += 4;

        // Write path
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(path.len), .big);
        offset += 4;
        @memcpy(packet[offset..][0..path.len], path);

        // Send request
        try self.channel.send(packet);

        // Receive response (HANDLE or STATUS)
        const response = try self.channel.receive(self.allocator);
        defer self.allocator.free(response);

        if (response.len < 5) return error.InvalidResponse;
        const response_type = response[4];

        if (response_type == @intFromEnum(protocol.PacketType.SSH_FXP_HANDLE)) {
            var handle_msg = try protocol.Handle.decode(self.allocator, response);
            defer handle_msg.deinit(self.allocator);

            const handle_data = try self.allocator.dupe(u8, handle_msg.handle);
            return Handle{ .data = handle_data };
        } else if (response_type == @intFromEnum(protocol.PacketType.SSH_FXP_STATUS)) {
            var status = try protocol.Status.decode(self.allocator, response);
            defer status.deinit(self.allocator);

            return errorFromStatus(status.status_code);
        }

        return error.InvalidResponse;
    }

    /// Read directory entries
    pub fn readdir(self: *SftpClient, handle: Handle) ![]DirEntry {
        const request_id = self.getNextRequestId();

        // Encode READDIR request
        const packet_size = 4 + 1 + 4 + 4 + handle.data.len;
        const packet = try self.allocator.alloc(u8, packet_size);
        defer self.allocator.free(packet);

        var offset: usize = 0;

        // Write length
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(packet_size - 4), .big);
        offset += 4;

        // Write packet type
        packet[offset] = @intFromEnum(protocol.PacketType.SSH_FXP_READDIR);
        offset += 1;

        // Write request ID
        std.mem.writeInt(u32, packet[offset..][0..4], request_id, .big);
        offset += 4;

        // Write handle
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(handle.data.len), .big);
        offset += 4;
        @memcpy(packet[offset..][0..handle.data.len], handle.data);

        // Send request
        try self.channel.send(packet);

        // Receive response (NAME or STATUS)
        const response = try self.channel.receive(self.allocator);
        defer self.allocator.free(response);

        if (response.len < 5) return error.InvalidResponse;
        const response_type = response[4];

        if (response_type == @intFromEnum(protocol.PacketType.SSH_FXP_NAME)) {
            return try self.decodeNamePacket(response);
        } else if (response_type == @intFromEnum(protocol.PacketType.SSH_FXP_STATUS)) {
            var status = try protocol.Status.decode(self.allocator, response);
            defer status.deinit(self.allocator);

            return errorFromStatus(status.status_code);
        }

        return error.InvalidResponse;
    }

    /// Create a directory
    pub fn mkdir(
        self: *SftpClient,
        path: []const u8,
        attrs: attributes.FileAttributes,
    ) !void {
        const request_id = self.getNextRequestId();

        const attrs_data = try attrs.encode(self.allocator);
        defer self.allocator.free(attrs_data);

        // Encode MKDIR request
        const packet_size = 4 + 1 + 4 + 4 + path.len + attrs_data.len;
        const packet = try self.allocator.alloc(u8, packet_size);
        defer self.allocator.free(packet);

        var offset: usize = 0;

        // Write length
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(packet_size - 4), .big);
        offset += 4;

        // Write packet type
        packet[offset] = @intFromEnum(protocol.PacketType.SSH_FXP_MKDIR);
        offset += 1;

        // Write request ID
        std.mem.writeInt(u32, packet[offset..][0..4], request_id, .big);
        offset += 4;

        // Write path
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(path.len), .big);
        offset += 4;
        @memcpy(packet[offset..][0..path.len], path);
        offset += path.len;

        // Write attributes
        @memcpy(packet[offset..][0..attrs_data.len], attrs_data);

        // Send request
        try self.channel.send(packet);

        // Receive STATUS response
        const response = try self.channel.receive(self.allocator);
        defer self.allocator.free(response);

        var status = try protocol.Status.decode(self.allocator, response);
        defer status.deinit(self.allocator);

        if (status.status_code != .SSH_FX_OK) {
            return errorFromStatus(status.status_code);
        }
    }

    /// Remove a directory
    pub fn rmdir(self: *SftpClient, path: []const u8) !void {
        const request_id = self.getNextRequestId();

        // Encode RMDIR request
        const packet_size = 4 + 1 + 4 + 4 + path.len;
        const packet = try self.allocator.alloc(u8, packet_size);
        defer self.allocator.free(packet);

        var offset: usize = 0;

        // Write length
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(packet_size - 4), .big);
        offset += 4;

        // Write packet type
        packet[offset] = @intFromEnum(protocol.PacketType.SSH_FXP_RMDIR);
        offset += 1;

        // Write request ID
        std.mem.writeInt(u32, packet[offset..][0..4], request_id, .big);
        offset += 4;

        // Write path
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(path.len), .big);
        offset += 4;
        @memcpy(packet[offset..][0..path.len], path);

        // Send request
        try self.channel.send(packet);

        // Receive STATUS response
        const response = try self.channel.receive(self.allocator);
        defer self.allocator.free(response);

        var status = try protocol.Status.decode(self.allocator, response);
        defer status.deinit(self.allocator);

        if (status.status_code != .SSH_FX_OK) {
            return errorFromStatus(status.status_code);
        }
    }

    /// Remove a file
    pub fn remove(self: *SftpClient, path: []const u8) !void {
        const request_id = self.getNextRequestId();

        // Encode REMOVE request
        const packet_size = 4 + 1 + 4 + 4 + path.len;
        const packet = try self.allocator.alloc(u8, packet_size);
        defer self.allocator.free(packet);

        var offset: usize = 0;

        // Write length
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(packet_size - 4), .big);
        offset += 4;

        // Write packet type
        packet[offset] = @intFromEnum(protocol.PacketType.SSH_FXP_REMOVE);
        offset += 1;

        // Write request ID
        std.mem.writeInt(u32, packet[offset..][0..4], request_id, .big);
        offset += 4;

        // Write path
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(path.len), .big);
        offset += 4;
        @memcpy(packet[offset..][0..path.len], path);

        // Send request
        try self.channel.send(packet);

        // Receive STATUS response
        const response = try self.channel.receive(self.allocator);
        defer self.allocator.free(response);

        var status = try protocol.Status.decode(self.allocator, response);
        defer status.deinit(self.allocator);

        if (status.status_code != .SSH_FX_OK) {
            return errorFromStatus(status.status_code);
        }
    }

    /// Rename a file or directory
    pub fn rename(self: *SftpClient, old_path: []const u8, new_path: []const u8) !void {
        const request_id = self.getNextRequestId();

        // Encode RENAME request
        const packet_size = 4 + 1 + 4 + 4 + old_path.len + 4 + new_path.len;
        const packet = try self.allocator.alloc(u8, packet_size);
        defer self.allocator.free(packet);

        var offset: usize = 0;

        // Write length
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(packet_size - 4), .big);
        offset += 4;

        // Write packet type
        packet[offset] = @intFromEnum(protocol.PacketType.SSH_FXP_RENAME);
        offset += 1;

        // Write request ID
        std.mem.writeInt(u32, packet[offset..][0..4], request_id, .big);
        offset += 4;

        // Write old path
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(old_path.len), .big);
        offset += 4;
        @memcpy(packet[offset..][0..old_path.len], old_path);
        offset += old_path.len;

        // Write new path
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(new_path.len), .big);
        offset += 4;
        @memcpy(packet[offset..][0..new_path.len], new_path);

        // Send request
        try self.channel.send(packet);

        // Receive STATUS response
        const response = try self.channel.receive(self.allocator);
        defer self.allocator.free(response);

        var status = try protocol.Status.decode(self.allocator, response);
        defer status.deinit(self.allocator);

        if (status.status_code != .SSH_FX_OK) {
            return errorFromStatus(status.status_code);
        }
    }

    /// Canonicalize a path
    pub fn realpath(self: *SftpClient, path: []const u8) ![]u8 {
        const request_id = self.getNextRequestId();

        // Encode REALPATH request
        const packet_size = 4 + 1 + 4 + 4 + path.len;
        const packet = try self.allocator.alloc(u8, packet_size);
        defer self.allocator.free(packet);

        var offset: usize = 0;

        // Write length
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(packet_size - 4), .big);
        offset += 4;

        // Write packet type
        packet[offset] = @intFromEnum(protocol.PacketType.SSH_FXP_REALPATH);
        offset += 1;

        // Write request ID
        std.mem.writeInt(u32, packet[offset..][0..4], request_id, .big);
        offset += 4;

        // Write path
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(path.len), .big);
        offset += 4;
        @memcpy(packet[offset..][0..path.len], path);

        // Send request
        try self.channel.send(packet);

        // Receive response (NAME or STATUS)
        const response = try self.channel.receive(self.allocator);
        defer self.allocator.free(response);

        if (response.len < 5) return error.InvalidResponse;
        const response_type = response[4];

        if (response_type == @intFromEnum(protocol.PacketType.SSH_FXP_NAME)) {
            const entries = try self.decodeNamePacket(response);
            defer {
                for (entries) |*entry| {
                    entry.deinit(self.allocator);
                }
                self.allocator.free(entries);
            }

            if (entries.len == 0) return error.InvalidResponse;
            return try self.allocator.dupe(u8, entries[0].filename);
        } else if (response_type == @intFromEnum(protocol.PacketType.SSH_FXP_STATUS)) {
            var status = try protocol.Status.decode(self.allocator, response);
            defer status.deinit(self.allocator);

            return errorFromStatus(status.status_code);
        }

        return error.InvalidResponse;
    }

    /// Read symbolic link target
    pub fn readlink(self: *SftpClient, path: []const u8) ![]u8 {
        const request_id = self.getNextRequestId();

        const packet_size = 4 + 1 + 4 + 4 + path.len;
        const packet = try self.allocator.alloc(u8, packet_size);
        defer self.allocator.free(packet);

        var offset: usize = 0;
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(packet_size - 4), .big);
        offset += 4;
        packet[offset] = @intFromEnum(protocol.PacketType.SSH_FXP_READLINK);
        offset += 1;
        std.mem.writeInt(u32, packet[offset..][0..4], request_id, .big);
        offset += 4;
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(path.len), .big);
        offset += 4;
        @memcpy(packet[offset..][0..path.len], path);

        try self.channel.send(packet);

        const response = try self.channel.receive(self.allocator);
        defer self.allocator.free(response);

        if (response.len < 5) return error.InvalidResponse;
        const response_type = response[4];

        if (response_type == @intFromEnum(protocol.PacketType.SSH_FXP_NAME)) {
            const entries = try self.decodeNamePacket(response);
            defer {
                for (entries) |*entry| {
                    entry.deinit(self.allocator);
                }
                self.allocator.free(entries);
            }

            if (entries.len == 0) return error.InvalidResponse;
            return try self.allocator.dupe(u8, entries[0].filename);
        }
        if (response_type == @intFromEnum(protocol.PacketType.SSH_FXP_STATUS)) {
            var status = try protocol.Status.decode(self.allocator, response);
            defer status.deinit(self.allocator);
            return errorFromStatus(status.status_code);
        }

        return error.InvalidResponse;
    }

    /// Create symbolic link
    pub fn symlink(self: *SftpClient, linkpath: []const u8, targetpath: []const u8) !void {
        const request_id = self.getNextRequestId();

        const packet_size = 4 + 1 + 4 + 4 + linkpath.len + 4 + targetpath.len;
        const packet = try self.allocator.alloc(u8, packet_size);
        defer self.allocator.free(packet);

        var offset: usize = 0;
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(packet_size - 4), .big);
        offset += 4;
        packet[offset] = @intFromEnum(protocol.PacketType.SSH_FXP_SYMLINK);
        offset += 1;
        std.mem.writeInt(u32, packet[offset..][0..4], request_id, .big);
        offset += 4;

        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(linkpath.len), .big);
        offset += 4;
        @memcpy(packet[offset..][0..linkpath.len], linkpath);
        offset += linkpath.len;

        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(targetpath.len), .big);
        offset += 4;
        @memcpy(packet[offset..][0..targetpath.len], targetpath);

        try self.channel.send(packet);

        const response = try self.channel.receive(self.allocator);
        defer self.allocator.free(response);

        var status = try protocol.Status.decode(self.allocator, response);
        defer status.deinit(self.allocator);
        if (status.status_code != .SSH_FX_OK) {
            return errorFromStatus(status.status_code);
        }
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    fn statInternal(
        self: *SftpClient,
        path: []const u8,
        packet_type: protocol.PacketType,
    ) !attributes.FileAttributes {
        const request_id = self.getNextRequestId();

        // Encode STAT/LSTAT request
        const packet_size = 4 + 1 + 4 + 4 + path.len;
        const packet = try self.allocator.alloc(u8, packet_size);
        defer self.allocator.free(packet);

        var offset: usize = 0;

        // Write length
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(packet_size - 4), .big);
        offset += 4;

        // Write packet type
        packet[offset] = @intFromEnum(packet_type);
        offset += 1;

        // Write request ID
        std.mem.writeInt(u32, packet[offset..][0..4], request_id, .big);
        offset += 4;

        // Write path
        std.mem.writeInt(u32, packet[offset..][0..4], @intCast(path.len), .big);
        offset += 4;
        @memcpy(packet[offset..][0..path.len], path);

        // Send request
        try self.channel.send(packet);

        // Receive response (ATTRS or STATUS)
        const response = try self.channel.receive(self.allocator);
        defer self.allocator.free(response);

        if (response.len < 5) return error.InvalidResponse;
        const response_type = response[4];

        if (response_type == @intFromEnum(protocol.PacketType.SSH_FXP_ATTRS)) {
            // Skip length (4) + type (1) + request_id (4) = 9 bytes
            return try attributes.FileAttributes.decode(response[9..]);
        } else if (response_type == @intFromEnum(protocol.PacketType.SSH_FXP_STATUS)) {
            var status = try protocol.Status.decode(self.allocator, response);
            defer status.deinit(self.allocator);

            return errorFromStatus(status.status_code);
        }

        return error.InvalidResponse;
    }

    fn decodeNamePacket(self: *SftpClient, data: []const u8) ![]DirEntry {
        if (data.len < 13) return error.InvalidResponse;

        var offset: usize = 4; // Skip length
        offset += 1; // Skip type
        offset += 4; // Skip request_id

        // Read count
        const count = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;

        const entries = try self.allocator.alloc(DirEntry, count);
        errdefer self.allocator.free(entries);

        var i: usize = 0;
        errdefer {
            for (entries[0..i]) |*entry| {
                entry.deinit(self.allocator);
            }
        }

        while (i < count) : (i += 1) {
            // Read filename (string)
            if (offset + 4 > data.len) return error.InvalidResponse;
            const filename_len = std.mem.readInt(u32, data[offset..][0..4], .big);
            offset += 4;

            if (offset + filename_len > data.len) return error.InvalidResponse;
            const filename = try self.allocator.dupe(u8, data[offset..][0..filename_len]);
            errdefer self.allocator.free(filename);
            offset += filename_len;

            // Read longname (string) - we'll ignore it
            if (offset + 4 > data.len) return error.InvalidResponse;
            const longname_len = std.mem.readInt(u32, data[offset..][0..4], .big);
            offset += 4;

            if (offset + longname_len > data.len) return error.InvalidResponse;
            offset += longname_len;

            // Read attributes
            const attrs = try attributes.FileAttributes.decode(data[offset..]);

            // Calculate consumed bytes from attributes
            var attrs_size: usize = 4; // flags
            if (attrs.flags.size) attrs_size += 8;
            if (attrs.flags.uidgid) attrs_size += 8;
            if (attrs.flags.permissions) attrs_size += 4;
            if (attrs.flags.acmodtime) attrs_size += 8;
            offset += attrs_size;

            entries[i] = DirEntry{
                .filename = filename,
                .attrs = attrs,
            };
        }

        return entries;
    }

    fn errorFromStatus(status_code: protocol.StatusCode) error{
        EndOfFile,
        NoSuchFile,
        PermissionDenied,
        Failure,
        BadMessage,
        NoConnection,
        ConnectionLost,
        OperationUnsupported,
    } {
        return switch (status_code) {
            .SSH_FX_EOF => error.EndOfFile,
            .SSH_FX_NO_SUCH_FILE => error.NoSuchFile,
            .SSH_FX_PERMISSION_DENIED => error.PermissionDenied,
            .SSH_FX_FAILURE => error.Failure,
            .SSH_FX_BAD_MESSAGE => error.BadMessage,
            .SSH_FX_NO_CONNECTION => error.NoConnection,
            .SSH_FX_CONNECTION_LOST => error.ConnectionLost,
            .SSH_FX_OP_UNSUPPORTED => error.OperationUnsupported,
            else => error.Failure,
        };
    }
};

/// File or directory handle
pub const Handle = struct {
    data: []const u8,

    pub fn deinit(self: *Handle, allocator: Allocator) void {
        allocator.free(self.data);
    }
};

/// Directory entry
pub const DirEntry = struct {
    filename: []const u8,
    attrs: attributes.FileAttributes,

    pub fn deinit(self: *DirEntry, allocator: Allocator) void {
        allocator.free(self.filename);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "SftpClient - request ID generation" {
    const testing = std.testing;

    // Test request ID generation without requiring a channel
    var client = SftpClient{
        .allocator = testing.allocator,
        .channel = .{}, // Not used in this test
        .version = 3,
        .next_request_id = 1,
    };

    try testing.expectEqual(@as(u32, 1), client.getNextRequestId());
    try testing.expectEqual(@as(u32, 2), client.getNextRequestId());
    try testing.expectEqual(@as(u32, 3), client.getNextRequestId());
}

test "Handle - cleanup" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const handle_data = try allocator.dupe(u8, "test_handle");
    var handle = Handle{ .data = handle_data };
    handle.deinit(allocator);
}

test "DirEntry - cleanup" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const filename = try allocator.dupe(u8, "test.txt");
    var entry = DirEntry{
        .filename = filename,
        .attrs = attributes.FileAttributes.init(),
    };
    entry.deinit(allocator);
}
