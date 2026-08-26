const std = @import("std");
const Allocator = std.mem.Allocator;

/// QUIC Stream State
pub const StreamState = enum {
    open,
    half_closed_local, // We sent FIN
    half_closed_remote, // Peer sent FIN
    closed,
};

/// Bidirectional QUIC Stream
///
/// Manages send and receive buffers for a single stream.
/// Handles flow control and data reassembly by offset.
pub const Stream = struct {
    allocator: Allocator,
    stream_id: u64,
    state: StreamState,

    // Send side
    send_buffer: std.ArrayListAligned(u8, null),
    send_offset: u64, // Next byte to send
    send_max: u64, // MAX_STREAM_DATA from peer (flow control limit)

    // Receive side
    recv_buffer: std.ArrayListAligned(u8, null),
    recv_offset: u64, // Next byte expected
    recv_max: u64, // Our MAX_STREAM_DATA to advertise

    // Out-of-order received data (offset -> data)
    recv_chunks: std.AutoHashMap(u64, []u8),

    pub const initial_window: u64 = 2 * 1024 * 1024; // 2MB, matches OpenSSH

    const Self = @This();

    /// Initialize a new stream
    pub fn init(allocator: Allocator, stream_id: u64) !Self {
        return Self{
            .allocator = allocator,
            .stream_id = stream_id,
            .state = .open,
            .send_buffer = .{},
            .send_offset = 0,
            .send_max = initial_window,
            .recv_buffer = .{},
            .recv_offset = 0,
            .recv_max = initial_window,
            .recv_chunks = std.AutoHashMap(u64, []u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.send_buffer.deinit(self.allocator);
        self.recv_buffer.deinit(self.allocator);

        // Free out-of-order chunks
        var it = self.recv_chunks.valueIterator();
        while (it.next()) |chunk| {
            self.allocator.free(chunk.*);
        }
        self.recv_chunks.deinit();
    }

    /// Write data to send buffer
    ///
    /// Returns error if would exceed flow control limit
    pub fn write(self: *Self, data: []const u8) !void {
        if (self.state != .open and self.state != .half_closed_remote) {
            return error.StreamClosed;
        }

        // Check flow control
        const future_offset = self.send_offset + self.send_buffer.items.len + data.len;
        if (future_offset > self.send_max) {
            return error.FlowControlViolation;
        }

        try self.send_buffer.appendSlice(self.allocator, data);
    }

    /// Read available data from receive buffer
    ///
    /// Returns number of bytes read (may be less than buffer.len)
    /// Returns error.StreamClosed if stream is closed and no data available
    pub fn read(self: *Self, buffer: []u8) !usize {
        const available = self.recv_buffer.items.len;
        if (available == 0) {
            // If stream is closed/half-closed from remote and no data, signal EOF
            if (self.state == .closed or self.state == .half_closed_remote) {
                return error.StreamClosed;
            }
            return 0; // No data available yet, but stream still open
        }

        const to_read = @min(buffer.len, available);
        @memcpy(buffer[0..to_read], self.recv_buffer.items[0..to_read]);

        // Remove read data from buffer
        std.mem.copyForwards(u8, self.recv_buffer.items, self.recv_buffer.items[to_read..]);
        try self.recv_buffer.resize(self.allocator, available - to_read);

        return to_read;
    }

    /// Get data to send (up to max_len bytes)
    ///
    /// Returns slice of send buffer and the offset for this data.
    /// Call markSent() after successfully sending.
    pub fn dataToSend(self: *Self, max_len: usize) ?struct { offset: u64, data: []const u8 } {
        if (self.send_buffer.items.len == 0) return null;

        const to_send = @min(max_len, self.send_buffer.items.len);
        return .{
            .offset = self.send_offset,
            .data = self.send_buffer.items[0..to_send],
        };
    }

    /// Mark data as successfully sent and remove from send buffer
    pub fn markSent(self: *Self, bytes: usize) !void {
        if (bytes > self.send_buffer.items.len) {
            return error.InvalidSentLength;
        }

        self.send_offset += bytes;

        // Remove sent data from buffer
        const remaining = self.send_buffer.items.len - bytes;
        std.mem.copyForwards(u8, self.send_buffer.items, self.send_buffer.items[bytes..]);
        try self.send_buffer.resize(self.allocator, remaining);
    }

    /// Receive stream data at given offset
    ///
    /// Handles out-of-order delivery by buffering chunks.
    pub fn receiveData(self: *Self, offset: u64, data: []const u8) !void {
        if (self.state != .open and self.state != .half_closed_local) {
            return error.StreamClosed;
        }

        // Check if data is in order
        if (offset == self.recv_offset) {
            // In-order data - append directly
            try self.recv_buffer.appendSlice(self.allocator, data);
            self.recv_offset += data.len;

            // Check if we can now deliver any buffered chunks
            try self.deliverBufferedChunks();
        } else if (offset > self.recv_offset) {
            // Out-of-order data - buffer it
            const chunk = try self.allocator.dupe(u8, data);
            try self.recv_chunks.put(offset, chunk);
        }
        // else: duplicate or old data, ignore
    }

    /// Try to deliver buffered out-of-order chunks
    fn deliverBufferedChunks(self: *Self) !void {
        while (self.recv_chunks.get(self.recv_offset)) |chunk| {
            try self.recv_buffer.appendSlice(self.allocator, chunk);
            self.recv_offset += chunk.len;

            _ = self.recv_chunks.remove(self.recv_offset - chunk.len);
            self.allocator.free(chunk);
        }
    }

    /// Mark stream as half-closed (we sent FIN)
    pub fn closeLocal(self: *Self) void {
        self.state = switch (self.state) {
            .open => .half_closed_local,
            .half_closed_remote => .closed,
            else => self.state,
        };
    }

    /// Mark stream as half-closed (peer sent FIN)
    pub fn closeRemote(self: *Self) void {
        self.state = switch (self.state) {
            .open => .half_closed_remote,
            .half_closed_local => .closed,
            else => self.state,
        };
    }

    /// Update flow control limit (from MAX_STREAM_DATA frame)
    pub fn updateSendMax(self: *Self, new_max: u64) void {
        if (new_max > self.send_max) {
            self.send_max = new_max;
        }
    }

    /// Check if stream has data to send
    pub fn hasDataToSend(self: *const Self) bool {
        return self.send_buffer.items.len > 0;
    }

    /// Check if we should send FIN (stream is closing and all data sent)
    pub fn shouldSendFin(self: *const Self) bool {
        return (self.state == .half_closed_local or self.state == .closed) and
               self.send_buffer.items.len == 0;
    }

    /// Check if stream has data available to read
    pub fn hasDataToRead(self: *const Self) bool {
        return self.recv_buffer.items.len > 0;
    }

    /// Check if stream needs to send MAX_STREAM_DATA update
    pub fn needsMaxStreamDataUpdate(self: *const Self) bool {
        const remaining = if (self.recv_max > self.recv_offset) self.recv_max - self.recv_offset else 0;
        return remaining < initial_window / 2;
    }

    /// Slide the receive window forward and return the new max offset.
    pub fn slideRecvWindow(self: *Self) u64 {
        self.recv_max = self.recv_offset + initial_window;
        return self.recv_max;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Stream - basic write and read" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stream = try Stream.init(allocator, 4);
    defer stream.deinit();

    // Write data
    try stream.write("Hello, ");
    try stream.write("QUIC!");

    // Get data to send
    const to_send = stream.dataToSend(100).?;
    try testing.expectEqual(@as(u64, 0), to_send.offset);
    try testing.expectEqualSlices(u8, "Hello, QUIC!", to_send.data);

    // Simulate receiving the same data on peer
    try stream.receiveData(0, "Hello, QUIC!");

    // Read data
    var buffer: [100]u8 = undefined;
    const read_len = try stream.read(&buffer);
    try testing.expectEqual(@as(usize, 12), read_len);
    try testing.expectEqualSlices(u8, "Hello, QUIC!", buffer[0..read_len]);
}

test "Stream - out of order delivery" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stream = try Stream.init(allocator, 0);
    defer stream.deinit();

    // Receive data out of order
    // "World" starts at offset 6 (after "Hello ")
    try stream.receiveData(6, "World");
    try stream.receiveData(0, "Hello ");

    // Should now have all data in order
    var buffer: [100]u8 = undefined;
    const read_len = try stream.read(&buffer);
    try testing.expectEqual(@as(usize, 11), read_len);
    try testing.expectEqualSlices(u8, "Hello World", buffer[0..read_len]);
}

test "Stream - flow control" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stream = try Stream.init(allocator, 0);
    defer stream.deinit();

    // Set low flow control limit
    stream.send_max = 10;

    // Write within limit
    try stream.write("12345");
    try stream.write("67890");

    // Try to exceed limit
    const result = stream.write("X");
    try testing.expectError(error.FlowControlViolation, result);
}

test "Stream - state transitions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stream = try Stream.init(allocator, 0);
    defer stream.deinit();

    try testing.expectEqual(StreamState.open, stream.state);

    // Local close (we send FIN)
    stream.closeLocal();
    try testing.expectEqual(StreamState.half_closed_local, stream.state);

    // Remote close (peer sends FIN)
    stream.closeRemote();
    try testing.expectEqual(StreamState.closed, stream.state);
}
