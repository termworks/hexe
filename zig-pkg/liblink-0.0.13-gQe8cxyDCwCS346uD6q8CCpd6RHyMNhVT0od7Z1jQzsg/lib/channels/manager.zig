const std = @import("std");
const Allocator = std.mem.Allocator;
const quic_transport = @import("../network/quic_transport.zig");
const channel_protocol = @import("../protocol/channel.zig");

/// Channel Manager
///
/// Manages SSH channels mapped to QUIC streams.
/// Handles channel lifecycle, type dispatch, and request routing.
pub const ChannelManager = struct {
    allocator: Allocator,
    transport: *quic_transport.QuicTransport,
    channels: std.AutoHashMap(u64, *ChannelInfo),
    recv_pending: std.AutoHashMap(u64, std.ArrayListUnmanaged(u8)),
    next_client_stream_id: u64, // For client-initiated streams (4, 8, 12, ...)

    const Self = @This();

    /// Channel information
    pub const ChannelInfo = struct {
        stream_id: u64,
        channel_type: []const u8,
        state: channel_protocol.ChannelState,
        allocator: Allocator,

        pub fn deinit(self: *ChannelInfo) void {
            self.allocator.free(self.channel_type);
        }
    };

    pub fn init(allocator: Allocator, transport: *quic_transport.QuicTransport, is_server: bool) Self {
        return Self{
            .allocator = allocator,
            .transport = transport,
            .channels = std.AutoHashMap(u64, *ChannelInfo).init(allocator),
            .recv_pending = std.AutoHashMap(u64, std.ArrayListUnmanaged(u8)).init(allocator),
            .next_client_stream_id = if (is_server) 5 else 4, // Server uses 5, 9, 13..., client uses 4, 8, 12...
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.channels.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.channels.deinit();

        var pending_iter = self.recv_pending.valueIterator();
        while (pending_iter.next()) |pending| {
            pending.*.deinit(self.allocator);
        }
        self.recv_pending.deinit();
    }

    /// Open a new channel (client-side)
    ///
    /// Opens a bidirectional QUIC stream and sends CHANNEL_OPEN message.
    /// Returns the stream ID (channel ID).
    pub fn openChannel(
        self: *Self,
        channel_type: []const u8,
        type_specific_data: []const u8,
    ) !u64 {
        const stream_id = try self.transport.openStream();
        self.next_client_stream_id = stream_id + 4;

        const info = try self.allocator.create(ChannelInfo);
        errdefer self.allocator.destroy(info);

        info.* = ChannelInfo{
            .stream_id = stream_id,
            .channel_type = try self.allocator.dupe(u8, channel_type),
            .state = .opening,
            .allocator = self.allocator,
        };
        errdefer info.deinit();

        try self.channels.put(stream_id, info);

        const open_msg = channel_protocol.ChannelOpen{
            .channel_type = channel_type,
            .type_specific_data = type_specific_data,
        };

        const encoded = try open_msg.encode(self.allocator);
        defer self.allocator.free(encoded);

        try self.transport.sendOnStream(stream_id, encoded);

        std.log.info("Opened channel type='{s}' on stream {}", .{ channel_type, stream_id });

        return stream_id;
    }

    /// Accept incoming channel open (server-side)
    ///
    /// Reads CHANNEL_OPEN from a stream and confirms or rejects it.
    pub fn acceptChannel(self: *Self, stream_id: u64) !void {
        // Receive CHANNEL_OPEN message
        var buffer: [4096]u8 = undefined;
        const len = try self.transport.receiveFromStream(stream_id, &buffer);
        const data = buffer[0..len];

        var open_msg = try channel_protocol.ChannelOpen.decode(self.allocator, data);
        defer open_msg.deinit(self.allocator);

        std.log.info("Received CHANNEL_OPEN type='{s}' on stream {}", .{
            open_msg.channel_type,
            stream_id,
        });

        std.log.debug("DEBUG: About to create ChannelInfo", .{});
        // Create channel info
        const info = try self.allocator.create(ChannelInfo);
        errdefer self.allocator.destroy(info);

        std.log.debug("DEBUG: About to dupe channel_type: {s}", .{open_msg.channel_type});
        const channel_type_copy = try self.allocator.dupe(u8, open_msg.channel_type);
        errdefer self.allocator.free(channel_type_copy);

        std.log.debug("DEBUG: Setting ChannelInfo fields", .{});
        info.* = ChannelInfo{
            .stream_id = stream_id,
            .channel_type = channel_type_copy,
            .state = .open, // Accepting means it's open
            .allocator = self.allocator,
        };
        errdefer info.deinit();

        std.log.debug("DEBUG: About to put in channels map", .{});
        try self.channels.put(stream_id, info);

        std.log.debug("DEBUG: Creating CHANNEL_OPEN_CONFIRMATION", .{});
        // Send CHANNEL_OPEN_CONFIRMATION
        const confirm_msg = channel_protocol.ChannelOpenConfirmation{
            .type_specific_data = "",
        };

        std.log.debug("DEBUG: Encoding confirmation message", .{});
        const encoded = try confirm_msg.encode(self.allocator);
        defer self.allocator.free(encoded);

        std.log.debug("DEBUG: Sending confirmation on stream {}", .{stream_id});
        try self.transport.sendOnStream(stream_id, encoded);

        std.log.debug("DEBUG: acceptChannel completed successfully", .{});
    }

    /// Process CHANNEL_OPEN_CONFIRMATION (client-side)
    pub fn handleOpenConfirmation(self: *Self, stream_id: u64, data: []const u8) !void {
        var confirm_msg = try channel_protocol.ChannelOpenConfirmation.decode(self.allocator, data);
        defer confirm_msg.deinit(self.allocator);

        if (self.channels.get(stream_id)) |info| {
            info.state = .open;
            std.log.info("Channel {} confirmed and open", .{stream_id});
        } else {
            return error.UnknownChannel;
        }
    }

    /// Process CHANNEL_OPEN_FAILURE (client-side)
    pub fn handleOpenFailure(self: *Self, stream_id: u64, data: []const u8) !void {
        var failure_msg = try channel_protocol.ChannelOpenFailure.decode(self.allocator, data);
        defer failure_msg.deinit(self.allocator);

        std.log.err("Channel {} open failed: code={}, desc={s}", .{
            stream_id,
            failure_msg.reason_code,
            failure_msg.description,
        });

        if (self.channels.get(stream_id)) |info| {
            info.state = .failed;
        }
    }

    /// Send channel request (shell, exec, subsystem, etc.)
    pub fn sendRequest(
        self: *Self,
        stream_id: u64,
        request_type: []const u8,
        want_reply: bool,
        type_specific_data: []const u8,
    ) !void {
        const request_msg = channel_protocol.ChannelRequest{
            .request_type = request_type,
            .want_reply = want_reply,
            .type_specific_data = type_specific_data,
        };

        const encoded = try request_msg.encode(self.allocator);
        defer self.allocator.free(encoded);

        try self.transport.sendOnStream(stream_id, encoded);

        std.log.info("Sent CHANNEL_REQUEST type='{s}' on stream {}", .{
            request_type,
            stream_id,
        });
    }

    /// Handle incoming channel request (server-side)
    pub fn handleRequest(self: *Self, stream_id: u64, data: []const u8) !ChannelRequestInfo {
        const request_msg = try channel_protocol.ChannelRequest.decode(self.allocator, data);
        // Caller is responsible for calling deinit on returned ChannelRequestInfo

        return ChannelRequestInfo{
            .stream_id = stream_id,
            .request = request_msg,
        };
    }

    /// Send channel request success
    pub fn sendSuccess(self: *Self, stream_id: u64) !void {
        const encoded = try channel_protocol.ChannelSuccess.encode(self.allocator);
        defer self.allocator.free(encoded);

        try self.transport.sendOnStream(stream_id, encoded);
    }

    /// Send channel request failure
    pub fn sendFailure(self: *Self, stream_id: u64) !void {
        const encoded = try channel_protocol.ChannelFailure.encode(self.allocator);
        defer self.allocator.free(encoded);

        try self.transport.sendOnStream(stream_id, encoded);
    }

    /// Send data on channel
    pub fn sendData(self: *Self, stream_id: u64, data: []const u8) !void {
        const data_msg = channel_protocol.ChannelData{
            .data = data,
        };

        const encoded = try data_msg.encode(self.allocator);
        defer self.allocator.free(encoded);

        try self.transport.sendOnStream(stream_id, encoded);
    }

    /// Send extended data (such as stderr) on channel
    pub fn sendExtendedData(self: *Self, stream_id: u64, data_type_code: u32, data: []const u8) !void {
        const ext_msg = channel_protocol.ChannelExtendedData{
            .data_type_code = data_type_code,
            .data = data,
        };

        const encoded = try ext_msg.encode(self.allocator);
        defer self.allocator.free(encoded);

        try self.transport.sendOnStream(stream_id, encoded);
    }

    /// Receive data from channel
    ///
    /// Reads and decodes CHANNEL_DATA message from stream.
    /// Returns the payload data. Caller owns the memory.
    pub fn receiveData(self: *Self, stream_id: u64) ![]u8 {
        while (true) {
            const msg = try self.receiveMessage(stream_id);
            defer self.allocator.free(msg);

            switch (msg[0]) {
                94 => {
                    const data_msg = try channel_protocol.ChannelData.decode(self.allocator, msg);
                    return @constCast(data_msg.data);
                },
                95 => {
                    const ext_msg = try channel_protocol.ChannelExtendedData.decode(self.allocator, msg);
                    return @constCast(ext_msg.data);
                },
                96, 97 => return error.StreamClosed,
                99, 100 => continue,
                else => continue,
            }
        }
    }

    /// Receive the next complete channel message from a stream.
    ///
    /// The returned message is the full SSH/QUIC channel packet and must be freed
    /// by the caller with this manager's allocator.
    pub fn receiveMessage(self: *Self, stream_id: u64) ![]u8 {
        const pending = try self.getPendingBuffer(stream_id);
        var read_buffer: [8192]u8 = undefined;
        var reads: u8 = 0;
        var stream_closed = false;

        while (reads < 8) : (reads += 1) {
            const len = self.transport.receiveFromStream(stream_id, &read_buffer) catch |err| {
                if (err == error.NoData) break;
                if (err == error.StreamClosed or err == error.StreamNotFound) {
                    stream_closed = true;
                    break;
                }
                return err;
            };
            if (len == 0) break;
            try pending.appendSlice(self.allocator, read_buffer[0..len]);
        }

        const msg_len = (try nextChannelMessageLen(pending.items)) orelse {
            if (pending.items.len > 0) return error.EndOfBuffer;
            if (stream_closed) return error.StreamClosed;
            return error.NoData;
        };
        const msg = pending.items[0..msg_len];
        const owned = try self.allocator.dupe(u8, msg);

        const remaining = pending.items.len - msg_len;
        if (remaining > 0) {
            std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[msg_len..]);
        }
        pending.items.len = remaining;

        return owned;
    }

    /// Send EOF on channel
    pub fn sendEof(self: *Self, stream_id: u64) !void {
        const encoded = try channel_protocol.ChannelEof.encode(self.allocator);
        defer self.allocator.free(encoded);

        try self.transport.sendOnStream(stream_id, encoded);

        if (self.channels.get(stream_id)) |info| {
            info.state = .eof_sent;
        }
    }

    /// Close a channel
    ///
    /// In SSH/QUIC, this closes the underlying QUIC stream with FIN.
    pub fn closeChannel(self: *Self, stream_id: u64) !void {
        try self.transport.closeStream(stream_id);

        if (self.channels.getPtr(stream_id)) |info| {
            info.*.state = .closed;
        }

        if (self.recv_pending.fetchRemove(stream_id)) |entry| {
            var pending = entry.value;
            pending.deinit(self.allocator);
        }

        std.log.info("Closed channel {}", .{stream_id});
    }

    /// Get channel state
    pub fn getChannelState(self: *Self, stream_id: u64) ?channel_protocol.ChannelState {
        if (self.channels.get(stream_id)) |info| {
            return info.state;
        }
        return null;
    }

    /// Check if channel is open
    pub fn isChannelOpen(self: *Self, stream_id: u64) bool {
        if (self.channels.get(stream_id)) |info| {
            return info.state == .open;
        }
        return false;
    }

    /// Get the next expected client stream ID (server-side)
    ///
    /// For servers accepting connections from clients, client streams
    /// are bidirectional streams with IDs 4, 8, 12, 16, etc.
    pub fn getNextClientStream(self: *const Self) u64 {
        // Find the highest client stream ID and return next one
        // Client streams: 4, 8, 12, 16, ...
        var max_client_stream: u64 = 0;
        var iter = self.channels.iterator();
        while (iter.next()) |entry| {
            const stream_id = entry.key_ptr.*;
            // Client bidirectional streams have IDs 0x00, 0x04, 0x08, ... (client-initiated)
            if (stream_id % 4 == 0 and stream_id > 0) {
                if (stream_id > max_client_stream) {
                    max_client_stream = stream_id;
                }
            }
        }
        return if (max_client_stream == 0) 4 else max_client_stream + 4;
    }

    /// Register a channel with a given type (for manual channel setup)
    pub fn registerChannel(self: *Self, stream_id: u64, channel_type: []const u8) !void {
        const info = try self.allocator.create(ChannelInfo);
        errdefer self.allocator.destroy(info);

        info.* = ChannelInfo{
            .stream_id = stream_id,
            .channel_type = try self.allocator.dupe(u8, channel_type),
            .state = .open,
            .allocator = self.allocator,
        };
        errdefer info.deinit();

        try self.channels.put(stream_id, info);
    }

    fn getPendingBuffer(self: *Self, stream_id: u64) !*std.ArrayListUnmanaged(u8) {
        if (!self.recv_pending.contains(stream_id)) {
            try self.recv_pending.put(stream_id, .{});
        }
        return self.recv_pending.getPtr(stream_id).?;
    }

    fn nextChannelMessageLen(buffer: []const u8) !?usize {
        if (buffer.len < 1) return null;

        return switch (buffer[0]) {
            94 => blk: {
                if (buffer.len < 5) break :blk null;
                const payload_len = std.mem.readInt(u32, buffer[1..5], .big);
                const total = 5 + @as(usize, @intCast(payload_len));
                if (buffer.len < total) break :blk null;
                break :blk total;
            },
            95 => blk: {
                if (buffer.len < 9) break :blk null;
                const payload_len = std.mem.readInt(u32, buffer[5..9], .big);
                const total = 9 + @as(usize, @intCast(payload_len));
                if (buffer.len < total) break :blk null;
                break :blk total;
            },
            98 => blk: {
                // CHANNEL_REQUEST:
                // byte msg_type
                // string request_type
                // boolean want_reply
                // type_specific_data (format depends on request_type)
                const req_type_end = parseWireStringEnd(buffer, 1) orelse break :blk null;
                if (buffer.len < req_type_end + 1) break :blk null;

                const req_type = buffer[5..req_type_end];
                var idx = req_type_end + 1;

                if (std.mem.eql(u8, req_type, "window-change")) {
                    if (buffer.len < idx + 16) break :blk null;
                    break :blk idx + 16;
                }

                if (std.mem.eql(u8, req_type, "shell")) {
                    break :blk idx;
                }

                if (std.mem.eql(u8, req_type, "exec") or std.mem.eql(u8, req_type, "subsystem") or std.mem.eql(u8, req_type, "signal")) {
                    const field_end = parseWireStringEnd(buffer, idx) orelse break :blk null;
                    break :blk field_end;
                }

                if (std.mem.eql(u8, req_type, "env")) {
                    const name_end = parseWireStringEnd(buffer, idx) orelse break :blk null;
                    const value_end = parseWireStringEnd(buffer, name_end) orelse break :blk null;
                    break :blk value_end;
                }

                if (std.mem.eql(u8, req_type, "pty-req")) {
                    const term_end = parseWireStringEnd(buffer, idx) orelse break :blk null;
                    if (buffer.len < term_end + 16) break :blk null;
                    idx = term_end + 16;
                    const modes_end = parseWireStringEnd(buffer, idx) orelse break :blk null;
                    break :blk modes_end;
                }

                // Unknown request type: don't desync stream parsing.
                // Wait for more data and let higher-level code handle it via specific paths.
                break :blk null;
            },
            96, 97, 99, 100 => 1,
            else => 1,
        };
    }

    fn parseWireStringEnd(buffer: []const u8, start: usize) ?usize {
        if (buffer.len < start + 4) return null;
        const field_len = (@as(u32, buffer[start]) << 24) |
            (@as(u32, buffer[start + 1]) << 16) |
            (@as(u32, buffer[start + 2]) << 8) |
            @as(u32, buffer[start + 3]);
        const end = start + 4 + @as(usize, @intCast(field_len));
        if (buffer.len < end) return null;
        return end;
    }
};

/// Information about a received channel request
pub const ChannelRequestInfo = struct {
    stream_id: u64,
    request: channel_protocol.ChannelRequest,

    pub fn deinit(self: *ChannelRequestInfo, allocator: Allocator) void {
        self.request.deinit(allocator);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ChannelManager - init and deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a mock transport (we can't actually initialize it without full stack)
    // This test just verifies the manager structure
    var manager = ChannelManager.init(allocator, undefined, false);
    defer manager.deinit();

    try testing.expectEqual(@as(u64, 4), manager.next_client_stream_id);
}

test "ChannelManager - server stream IDs" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = ChannelManager.init(allocator, undefined, true);
    defer manager.deinit();

    try testing.expectEqual(@as(u64, 5), manager.next_client_stream_id);
}
