const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const packet = @import("packet.zig");
const frame = @import("frame.zig");
const Stream = @import("stream.zig").Stream;
const Connection = @import("connection.zig").Connection;
const PacketProtection = @import("crypto.zig").PacketProtection;

/// QUIC Transport with UDP Integration
///
/// This is the missing piece! Connects UDP I/O with QUIC state machine.
pub const QuicTransport = struct {
    allocator: Allocator,
    socket: posix.socket_t,
    connection: *Connection,
    crypto: PacketProtection,
    is_server: bool,

    // For server: track client address
    // For client: track server address
    peer_address: ?posix.sockaddr.storage = null,

    const Self = @This();

    /// Initialize QUIC transport with SSH-derived secrets
    ///
    /// socket: UDP socket (from key exchange or newly created)
    /// client_secret/server_secret: From SSH key exchange
    /// peer_addr: Optional peer address (required for clients)
    pub fn init(
        allocator: Allocator,
        socket: posix.socket_t,
        local_conn_id: []const u8,
        remote_conn_id: []const u8,
        client_secret: [32]u8,
        server_secret: [32]u8,
        is_server: bool,
        peer_addr: ?posix.sockaddr.storage,
    ) !Self {
        const connection = try allocator.create(Connection);
        errdefer allocator.destroy(connection);

        connection.* = try Connection.init(
            allocator,
            local_conn_id,
            remote_conn_id,
            is_server,
        );
        errdefer connection.deinit();

        const crypto = PacketProtection.init(client_secret, server_secret, is_server);

        return Self{
            .allocator = allocator,
            .socket = socket,
            .connection = connection,
            .crypto = crypto,
            .is_server = is_server,
            .peer_address = peer_addr,
        };
    }

    pub fn deinit(self: *Self) void {
        self.connection.deinit();
        self.allocator.destroy(self.connection);
        // Note: socket is NOT closed here - caller owns it
    }

    /// Open a new bidirectional stream
    pub fn openStream(self: *Self) !u64 {
        return try self.connection.openStream();
    }

    /// Send data on a stream
    ///
    /// Blocks if the flow control window is full, polling for
    /// MAX_STREAM_DATA from the peer (like SSH WINDOW_ADJUST).
    pub fn sendOnStream(self: *Self, stream_id: u64, data: []const u8) !void {
        const stream = self.connection.getStream(stream_id) orelse return error.StreamNotFound;

        var written: usize = 0;
        var stall_count: u32 = 0;
        while (written < data.len) {
            // How much can we write within the flow control window?
            const total_produced = stream.send_offset + stream.send_buffer.items.len;
            const available = if (stream.send_max > total_produced)
                @as(usize, @intCast(stream.send_max - total_produced))
            else
                0;

            if (available == 0) {
                // Window full — flush pending data, then poll for window updates
                stall_count += 1;
                if (stall_count > 3000) {
                    // ~30 seconds with no window progress — peer is likely dead
                    return error.ConnectionStalled;
                }
                try self.flush();
                self.poll(10) catch |err| {
                    if (err == error.ConnectionRefused or
                        err == error.ConnectionResetByPeer or
                        err == error.NetworkUnreachable)
                        return err;
                };
                continue;
            }

            stall_count = 0;
            const chunk = @min(data.len - written, available);
            try stream.write(data[written .. written + chunk]);
            written += chunk;

            // Flush each chunk so the peer sees data and can send window updates
            try self.flush();
        }
    }

    /// Receive data from a stream
    ///
    /// Non-blocking - returns 0 if no data available.
    /// Call poll() first to receive and process packets.
    pub fn receiveFromStream(self: *Self, stream_id: u64, buffer: []u8) !usize {
        const stream = self.connection.getStream(stream_id) orelse return error.StreamNotFound;
        return try stream.read(buffer);
    }

    /// Close a stream (send FIN)
    pub fn closeStream(self: *Self, stream_id: u64) !void {
        try self.connection.closeStream(stream_id);
        try self.flush(); // Send FIN immediately
    }

    /// Poll for incoming packets and process them
    ///
    /// timeout_ms: milliseconds to wait (0 = non-blocking)
    pub fn poll(self: *Self, timeout_ms: u32) !void {
        // Set socket timeout for the first recv (blocking wait)
        const timeout = posix.timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };

        try posix.setsockopt(
            self.socket,
            posix.SOL.SOCKET,
            posix.SO.RCVTIMEO,
            std.mem.asBytes(&timeout),
        );

        var packet_buffer: [2048]u8 = undefined;
        var src_addr: posix.sockaddr.storage = undefined;
        var src_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        var packets_processed: u32 = 0;

        // First recv: block up to timeout_ms
        const first_len = posix.recvfrom(
            self.socket,
            &packet_buffer,
            0,
            @ptrCast(&src_addr),
            &src_addr_len,
        ) catch |err| {
            if (err == error.WouldBlock) return;
            return err;
        };

        if (first_len == 0) return;

        if (self.peer_address == null) {
            self.peer_address = src_addr;
        }

        self.processPacket(packet_buffer[0..first_len]) catch {};
        packets_processed = 1;

        while (packets_processed < 64) {
            src_addr_len = @sizeOf(posix.sockaddr.storage);
            const recv_len = posix.recvfrom(
                self.socket,
                &packet_buffer,
                posix.MSG.DONTWAIT,
                @ptrCast(&src_addr),
                &src_addr_len,
            ) catch break; // WouldBlock or error — done draining

            if (recv_len == 0) break;

            self.processPacket(packet_buffer[0..recv_len]) catch {};
            packets_processed += 1;
        }

        // Send MAX_STREAM_DATA updates after processing all received data
        self.sendWindowUpdates() catch {};
    }

    /// Process received QUIC packet
    fn processPacket(self: *Self, data: []const u8) !void {
        // std.log.debug("Processing packet: {} bytes, first byte: 0x{x}", .{ data.len, if (data.len > 0) data[0] else 0 });

        // Validate minimum packet size
        const conn_id_len = self.connection.remote_conn_id.len;
        const min_packet_size = 1 + conn_id_len + 1 + 16; // flags + conn_id + pn + min_payload+tag
        if (data.len < min_packet_size) {
            std.log.warn("Ignoring packet that's too small: {} bytes (need at least {})", .{ data.len, min_packet_size });
            return; // Silently ignore malformed packets
        }

        // Parse packet header
        const header_result = packet.ShortHeader.decode(data, conn_id_len) catch |err| {
            std.log.warn("Ignoring malformed packet: {}, size: {}, first bytes: {any}", .{ err, data.len, data[0..@min(16, data.len)] });
            return; // Silently ignore - don't crash on bad packets
        };
        const header = header_result.header;
        const header_len = header_result.consumed;

        // Record packet number
        self.connection.recordReceivedPacket(header.packet_number);

        // Extract ciphertext (everything after header)
        const ciphertext = data[header_len..];

        // Validate ciphertext size (must have at least 16-byte auth tag)
        if (ciphertext.len < 16) {
            std.log.warn("Ignoring packet with invalid ciphertext size: {}", .{ciphertext.len});
            return;
        }

        // Decrypt payload
        const payload = self.crypto.decryptPacket(
            header.packet_number,
            data[0..header_len], // header as AAD
            ciphertext,
            self.allocator,
        ) catch |err| {
            std.log.warn("Failed to decrypt packet {}: {}", .{ header.packet_number, err });
            return; // Ignore packets that fail authentication
        };
        defer self.allocator.free(payload);

        // Parse and process frames
        try self.processFrames(payload);
    }

    /// Process QUIC frames from decrypted payload
    fn processFrames(self: *Self, payload: []const u8) !void {
        if (payload.len == 0) {
            std.log.debug("Empty payload, nothing to process", .{});
            return;
        }

        var offset: usize = 0;

        while (offset < payload.len) {
            const frame_type = frame.FrameType.decode(payload[offset..]) catch |err| {
                std.log.warn("Failed to decode frame type: {}, payload size: {}", .{ err, payload.len });
                return; // Stop processing on malformed frame
            };

            switch (frame_type) {
                .ping => {
                    // PING frame — no payload, just acknowledge receipt
                    offset += 1;
                },

                .stream => {
                    const stream_frame = frame.StreamFrame.decode(
                        self.allocator,
                        payload[offset..],
                    ) catch |err| {
                        std.log.warn("Failed to decode stream frame: {}", .{err});
                        return; // Stop processing on malformed frame
                    };
                    defer self.allocator.free(stream_frame.data);

                    // Get or create stream
                    const stream = self.connection.getOrCreateStream(stream_frame.stream_id) catch |err| {
                        std.log.warn("Failed to get/create stream {}: {}", .{ stream_frame.stream_id, err });
                        return;
                    };

                    // Deliver data
                    stream.receiveData(stream_frame.offset, stream_frame.data) catch |err| {
                        std.log.warn("Failed to deliver data to stream {}: {}", .{ stream_frame.stream_id, err });
                    };
                    // Handle FIN
                    if (stream_frame.fin) {
                        stream.closeRemote();
                    }

                    offset += try streamFrameLength(payload[offset..]);
                },

                .max_stream_data => {
                    const max_data_frame = try frame.MaxStreamDataFrame.decode(payload[offset..]);
                    if (self.connection.getStream(max_data_frame.stream_id)) |stream| {
                        stream.updateSendMax(max_data_frame.maximum_stream_data);
                    }
                    offset += try maxStreamDataFrameLength(payload[offset..]);
                },

                .ack => {
                    const ack_frame = try frame.AckFrame.decode(payload[offset..]);
                    self.connection.recordAckedPacket(@intCast(ack_frame.largest_acknowledged));
                    offset += try ackFrameLength(payload[offset..]);
                },

                .connection_close => {
                    // Connection closed by peer
                    return;
                },
            }
        }
    }

    fn streamFrameLength(buffer: []const u8) !usize {
        if (buffer.len < 2) return error.BufferTooSmall;

        var idx: usize = 1;
        const type_byte = buffer[0];
        const has_len = (type_byte & 0x02) != 0;
        const has_off = (type_byte & 0x04) != 0;

        const stream_id_varint = try decodeVarIntMeta(buffer[idx..]);
        idx += stream_id_varint.bytes;

        if (has_off) {
            const off_varint = try decodeVarIntMeta(buffer[idx..]);
            idx += off_varint.bytes;
        }

        if (has_len) {
            const len_varint = try decodeVarIntMeta(buffer[idx..]);
            idx += len_varint.bytes;
            const data_len: usize = @intCast(len_varint.value);
            if (idx + data_len > buffer.len) return error.BufferTooSmall;
            return idx + data_len;
        }

        return buffer.len;
    }

    fn maxStreamDataFrameLength(buffer: []const u8) !usize {
        if (buffer.len < 1) return error.BufferTooSmall;
        var idx: usize = 1;

        const stream_id_varint = try decodeVarIntMeta(buffer[idx..]);
        idx += stream_id_varint.bytes;

        const max_data_varint = try decodeVarIntMeta(buffer[idx..]);
        idx += max_data_varint.bytes;

        return idx;
    }

    fn ackFrameLength(buffer: []const u8) !usize {
        if (buffer.len < 1) return error.BufferTooSmall;
        var idx: usize = 1;

        const largest_ack = try decodeVarIntMeta(buffer[idx..]);
        idx += largest_ack.bytes;

        const ack_delay = try decodeVarIntMeta(buffer[idx..]);
        idx += ack_delay.bytes;

        const ack_range_count = try decodeVarIntMeta(buffer[idx..]);
        idx += ack_range_count.bytes;

        return idx;
    }

    fn decodeVarIntMeta(buffer: []const u8) !struct { value: u64, bytes: usize } {
        if (buffer.len < 1) return error.BufferTooSmall;

        const prefix = buffer[0] >> 6;
        const size: usize = switch (prefix) {
            0b00 => 1,
            0b01 => 2,
            0b10 => 4,
            0b11 => 8,
            else => unreachable,
        };

        if (buffer.len < size) return error.BufferTooSmall;

        return switch (size) {
            1 => .{ .value = buffer[0] & 0x3F, .bytes = 1 },
            2 => .{ .value = std.mem.readInt(u16, buffer[0..2], .big) & 0x3FFF, .bytes = 2 },
            4 => .{ .value = std.mem.readInt(u32, buffer[0..4], .big) & 0x3FFFFFFF, .bytes = 4 },
            8 => .{ .value = std.mem.readInt(u64, buffer[0..8], .big) & 0x3FFFFFFFFFFFFFFF, .bytes = 8 },
            else => unreachable,
        };
    }

    /// Flush pending data - send all queued frames
    pub fn flush(self: *Self) !void {
        // Get streams with data to send
        const stream_ids = try self.connection.streamsWithDataToSend();
        defer self.allocator.free(stream_ids);

        // Send data from each stream
        for (stream_ids) |stream_id| {
            const stream = self.connection.getStream(stream_id).?;

            while (stream.hasDataToSend()) {
                // Get data to send (up to 1200 bytes to fit in UDP packet)
                const to_send = stream.dataToSend(1200) orelse break;

                // Check if we should send FIN with this frame:
                // - Stream is closing (half_closed_local or closed)
                // - This is the last data in send buffer
                const is_last_data = to_send.data.len == stream.send_buffer.items.len;
                const is_closing = (stream.state == .half_closed_local or stream.state == .closed);
                const fin = is_closing and is_last_data;

                // Create STREAM frame
                const stream_frame = frame.StreamFrame{
                    .stream_id = stream_id,
                    .offset = to_send.offset,
                    .data = to_send.data,
                    .fin = fin,
                };

                // Encode frame
                const frame_data = try stream_frame.encode(self.allocator);
                defer self.allocator.free(frame_data);

                // Send packet
                try self.sendPacket(frame_data);

                // Mark data as sent
                try stream.markSent(to_send.data.len);
            }

            // If stream should send FIN but has no data left, send FIN-only frame
            if (stream.shouldSendFin()) {
                const stream_frame = frame.StreamFrame{
                    .stream_id = stream_id,
                    .offset = stream.send_offset,
                    .data = &[_]u8{}, // Empty data
                    .fin = true,
                };

                const frame_data = try stream_frame.encode(self.allocator);
                defer self.allocator.free(frame_data);

                try self.sendPacket(frame_data);
            }
        }

        // Send ACK if needed
        if (self.connection.needsAck()) {
            try self.sendAck();
        }

        // Send MAX_STREAM_DATA updates (sliding window flow control)
        try self.sendWindowUpdates();
    }

    /// Send MAX_STREAM_DATA frames for streams whose receive window is running low
    fn sendWindowUpdates(self: *Self) !void {
        var stream_it = self.connection.streams.iterator();
        while (stream_it.next()) |entry| {
            const stream = entry.value_ptr.*;
            if (stream.needsMaxStreamDataUpdate()) {
                const new_max = stream.slideRecvWindow();
                const max_data_frame = frame.MaxStreamDataFrame{
                    .stream_id = stream.stream_id,
                    .maximum_stream_data = new_max,
                };
                var max_data_buf: [17]u8 = undefined;
                const encoded_len = try max_data_frame.encode(&max_data_buf);
                try self.sendPacket(max_data_buf[0..encoded_len]);
            }
        }
    }

    /// Send a QUIC packet with given payload
    fn sendPacket(self: *Self, payload: []const u8) !void {
        // std.log.debug("Sending packet with payload: {} bytes", .{payload.len});

        // Allocate packet buffer
        var packet_buffer: [2048]u8 = undefined;

        // Get packet number
        const pn = self.connection.nextPacketNumber();
        // std.log.debug("Packet number: {}, remote_conn_id: {s}", .{ pn, self.connection.remote_conn_id });

        // Create header
        const header = packet.ShortHeader{
            .destination_conn_id = self.connection.remote_conn_id,
            .packet_number = pn,
        };

        // Encode header
        const header_len = try header.encode(&packet_buffer);

        // Encrypt payload
        const ciphertext = try self.crypto.encryptPacket(
            pn,
            packet_buffer[0..header_len],
            payload,
            self.allocator,
        );
        defer self.allocator.free(ciphertext);

        // Copy ciphertext after header
        @memcpy(packet_buffer[header_len .. header_len + ciphertext.len], ciphertext);
        const total_len = header_len + ciphertext.len;

        // Send UDP packet
        if (self.peer_address) |addr| {
            // std.log.debug("Sending {} bytes to peer", .{total_len});
            const sent = try posix.sendto(
                self.socket,
                packet_buffer[0..total_len],
                0,
                @ptrCast(&addr),
                @sizeOf(posix.sockaddr.storage),
            );
            _ = sent;
        } else {
            std.log.err("No peer address set, cannot send packet", .{});
            return error.NoPeerAddress;
        }
    }

    /// Send ACK frame
    fn sendAck(self: *Self) !void {
        const ack_frame = frame.AckFrame{
            .largest_acknowledged = @intCast(self.connection.getAckNumber()),
        };

        var buffer: [64]u8 = undefined;
        const encoded_len = try ack_frame.encode(&buffer);

        try self.sendPacket(buffer[0..encoded_len]);
    }

    /// Send a keepalive probe (QUIC PING frame).
    ///
    /// Sending a UDP packet to a dead peer provokes an ICMP
    /// port-unreachable response.  The next poll() delivers that
    /// as ConnectionRefused so the caller can detect a dead peer.
    pub fn sendKeepalive(self: *Self) !void {
        const ping_payload = [_]u8{0x01}; // PING frame
        try self.sendPacket(&ping_payload);
    }

    /// Check if connection is ready
    pub fn isReady(self: *const Self) bool {
        _ = self;
        return true; // Always ready after SSH key exchange
    }

    /// Check if using SSH mode (always true for SSH/QUIC)
    pub fn isSshMode(self: *const Self) bool {
        _ = self;
        return true; // Always in SSH mode (vs TLS mode in standard QUIC)
    }
};

// ============================================================================
// Tests
// ============================================================================

test "QuicTransport - basic initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a dummy socket (won't actually be used in test)
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(sock);

    const client_secret = [_]u8{0xAA} ** 32;
    const server_secret = [_]u8{0xBB} ** 32;

    var transport = try QuicTransport.init(
        allocator,
        sock,
        "local-conn",
        "remote-conn",
        client_secret,
        server_secret,
        false, // client
        null, // no peer address for test
    );
    defer transport.deinit();

    try testing.expect(transport.isReady());
}

test "QuicTransport - process ACK and STREAM in one payload" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(sock);

    const client_secret = [_]u8{0xAA} ** 32;
    const server_secret = [_]u8{0xBB} ** 32;

    var transport = try QuicTransport.init(
        allocator,
        sock,
        "local-conn",
        "remote-conn",
        client_secret,
        server_secret,
        false,
        null,
    );
    defer transport.deinit();

    var ack_buf: [64]u8 = undefined;
    const ack_len = try (frame.AckFrame{ .largest_acknowledged = 7 }).encode(&ack_buf);

    const stream_encoded = try (frame.StreamFrame{
        .stream_id = 0,
        .offset = 0,
        .data = "hello",
        .fin = false,
    }).encode(allocator);
    defer allocator.free(stream_encoded);

    var payload = std.ArrayList(u8){};
    defer payload.deinit(allocator);
    try payload.appendSlice(allocator, ack_buf[0..ack_len]);
    try payload.appendSlice(allocator, stream_encoded);

    try transport.processFrames(payload.items);

    var read_buf: [16]u8 = undefined;
    const read_len = try transport.receiveFromStream(0, &read_buf);
    try testing.expectEqual(@as(usize, 5), read_len);
    try testing.expectEqualSlices(u8, "hello", read_buf[0..read_len]);
}
