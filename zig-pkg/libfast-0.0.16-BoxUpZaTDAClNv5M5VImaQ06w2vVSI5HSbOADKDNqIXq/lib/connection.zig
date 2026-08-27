const std = @import("std");
const Allocator = std.mem.Allocator;
const Stream = @import("stream.zig").Stream;

/// QUIC Connection
///
/// Manages multiple streams, packet numbering, and connection state.
pub const Connection = struct {
    allocator: Allocator,
    is_server: bool,

    /// Active streams (stream_id -> Stream)
    streams: std.AutoHashMap(u64, *Stream),

    /// Next stream ID to use (client: 0,4,8... server: 1,5,9...)
    next_stream_id: u64,

    /// Packet number tracking
    next_packet_number: u32,
    largest_received_packet: u32,
    largest_acked_packet: u32,

    /// Connection IDs
    local_conn_id: []const u8,
    remote_conn_id: []const u8,

    const Self = @This();

    /// Initialize connection
    pub fn init(
        allocator: Allocator,
        local_conn_id: []const u8,
        remote_conn_id: []const u8,
        is_server: bool,
    ) !Self {
        // Stream 0 is reserved for authentication (implicitly used)
        // Client channel streams: 4, 8, 12... (bidirectional, client-initiated)
        // Server channel streams: 5, 9, 13... (bidirectional, server-initiated)
        const initial_stream_id: u64 = if (is_server) 5 else 4;

        var streams = std.AutoHashMap(u64, *Stream).init(allocator);
        errdefer streams.deinit();

        // Pre-create stream 0 for authentication (both client and server need it)
        const stream0 = try allocator.create(Stream);
        errdefer allocator.destroy(stream0);

        stream0.* = try Stream.init(allocator, 0);
        errdefer stream0.deinit();

        try streams.put(0, stream0);

        return Self{
            .allocator = allocator,
            .is_server = is_server,
            .streams = streams,
            .next_stream_id = initial_stream_id,
            .next_packet_number = 0,
            .largest_received_packet = 0,
            .largest_acked_packet = 0,
            .local_conn_id = local_conn_id,
            .remote_conn_id = remote_conn_id,
        };
    }

    pub fn deinit(self: *Self) void {
        // Clean up all streams
        var it = self.streams.valueIterator();
        while (it.next()) |stream| {
            stream.*.deinit();
            self.allocator.destroy(stream.*);
        }
        self.streams.deinit();
    }

    /// Open a new bidirectional stream
    ///
    /// Returns stream ID
    pub fn openStream(self: *Self) !u64 {
        const stream_id = self.next_stream_id;

        // Create stream
        const stream = try self.allocator.create(Stream);
        errdefer self.allocator.destroy(stream);

        stream.* = try Stream.init(self.allocator, stream_id);
        errdefer stream.deinit();

        // Add to map
        try self.streams.put(stream_id, stream);

        // Increment stream ID (bidirectional streams increment by 4)
        self.next_stream_id += 4;

        return stream_id;
    }

    /// Get existing stream or create if it doesn't exist
    ///
    /// Used for accepting peer-initiated streams
    pub fn getOrCreateStream(self: *Self, stream_id: u64) !*Stream {
        // Check if stream already exists
        if (self.streams.get(stream_id)) |stream| {
            return stream;
        }

        // Validate stream ID parity
        const is_client_stream = (stream_id % 2) == 0;
        const peer_initiated = if (self.is_server) is_client_stream else !is_client_stream;

        if (!peer_initiated) {
            // Can't create stream that should be initiated by us
            return error.InvalidStreamId;
        }

        // Create new stream
        const stream = try self.allocator.create(Stream);
        errdefer self.allocator.destroy(stream);

        stream.* = try Stream.init(self.allocator, stream_id);
        errdefer stream.deinit();

        try self.streams.put(stream_id, stream);

        return stream;
    }

    /// Get stream by ID
    pub fn getStream(self: *Self, stream_id: u64) ?*Stream {
        return self.streams.get(stream_id);
    }

    /// Close a stream
    pub fn closeStream(self: *Self, stream_id: u64) !void {
        if (self.streams.get(stream_id)) |stream| {
            stream.closeLocal();
        } else {
            return error.StreamNotFound;
        }
    }

    /// Allocate next packet number
    pub fn nextPacketNumber(self: *Self) u32 {
        const pn = self.next_packet_number;
        self.next_packet_number += 1;
        return pn;
    }

    /// Record received packet number
    pub fn recordReceivedPacket(self: *Self, packet_number: u32) void {
        if (packet_number > self.largest_received_packet) {
            self.largest_received_packet = packet_number;
        }
    }

    /// Record ACKed packet
    pub fn recordAckedPacket(self: *Self, packet_number: u32) void {
        if (packet_number > self.largest_acked_packet) {
            self.largest_acked_packet = packet_number;
        }
    }

    /// Get all streams that have data to send or need to send FIN
    pub fn streamsWithDataToSend(self: *Self) ![]u64 {
        var stream_ids = std.ArrayList(u64){};
        errdefer stream_ids.deinit(self.allocator);

        var it = self.streams.iterator();
        while (it.next()) |entry| {
            const stream = entry.value_ptr.*;
            // Include streams with data OR streams that need to send FIN
            if (stream.hasDataToSend() or stream.shouldSendFin()) {
                try stream_ids.append(self.allocator, stream.stream_id);
            }
        }

        return stream_ids.toOwnedSlice(self.allocator);
    }

    /// Check if connection needs to send ACK
    pub fn needsAck(self: *const Self) bool {
        // Send ACK if we've received packets that haven't been acked
        return self.largest_received_packet > self.largest_acked_packet;
    }

    /// Get packet number to acknowledge
    pub fn getAckNumber(self: *const Self) u32 {
        return self.largest_received_packet;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Connection - client stream IDs" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var conn = try Connection.init(
        allocator,
        "client-conn",
        "server-conn",
        false, // client
    );
    defer conn.deinit();

    // Client should get even stream IDs: 4, 8, 12... (0 reserved for auth)
    const stream1 = try conn.openStream();
    const stream2 = try conn.openStream();
    const stream3 = try conn.openStream();

    try testing.expectEqual(@as(u64, 4), stream1);
    try testing.expectEqual(@as(u64, 8), stream2);
    try testing.expectEqual(@as(u64, 12), stream3);
}

test "Connection - server stream IDs" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var conn = try Connection.init(
        allocator,
        "server-conn",
        "client-conn",
        true, // server
    );
    defer conn.deinit();

    // Server should get odd stream IDs: 5, 9, 13... (1 reserved for server auth if needed)
    const stream1 = try conn.openStream();
    const stream2 = try conn.openStream();
    const stream3 = try conn.openStream();

    try testing.expectEqual(@as(u64, 5), stream1);
    try testing.expectEqual(@as(u64, 9), stream2);
    try testing.expectEqual(@as(u64, 13), stream3);
}

test "Connection - packet number tracking" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var conn = try Connection.init(
        allocator,
        "local",
        "remote",
        false,
    );
    defer conn.deinit();

    // Allocate packet numbers
    try testing.expectEqual(@as(u32, 0), conn.nextPacketNumber());
    try testing.expectEqual(@as(u32, 1), conn.nextPacketNumber());
    try testing.expectEqual(@as(u32, 2), conn.nextPacketNumber());

    // Record received packets
    conn.recordReceivedPacket(5);
    conn.recordReceivedPacket(10);
    conn.recordReceivedPacket(7); // Out of order

    try testing.expectEqual(@as(u32, 10), conn.largest_received_packet);
}

test "Connection - getOrCreateStream" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var conn = try Connection.init(
        allocator,
        "server-conn",
        "client-conn",
        true, // server
    );
    defer conn.deinit();

    // Server receives client-initiated stream 0 (authentication)
    const stream0 = try conn.getOrCreateStream(0);
    try testing.expectEqual(@as(u64, 0), stream0.stream_id);

    // Server receives client-initiated stream 4 (first channel)
    const stream4 = try conn.getOrCreateStream(4);
    try testing.expectEqual(@as(u64, 4), stream4.stream_id);

    // Getting stream 0 again should return same stream
    const stream0_again = try conn.getOrCreateStream(0);
    try testing.expect(stream0 == stream0_again);

    // Server can't create odd streams via getOrCreateStream (those are server-initiated)
    const result = conn.getOrCreateStream(5);
    try testing.expectError(error.InvalidStreamId, result);
}
