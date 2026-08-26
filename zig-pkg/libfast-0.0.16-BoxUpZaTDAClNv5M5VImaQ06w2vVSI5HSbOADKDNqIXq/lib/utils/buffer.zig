const std = @import("std");

/// Ring buffer for QUIC data
pub const RingBuffer = struct {
    data: []u8,
    read_pos: usize,
    write_pos: usize,
    size: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !RingBuffer {
        const data = try allocator.alloc(u8, capacity);
        return RingBuffer{
            .data = data,
            .read_pos = 0,
            .write_pos = 0,
            .size = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RingBuffer) void {
        self.allocator.free(self.data);
    }

    /// Get available space for writing
    pub fn availableWrite(self: RingBuffer) usize {
        return self.data.len - self.size;
    }

    /// Get available data for reading
    pub fn availableRead(self: RingBuffer) usize {
        return self.size;
    }

    /// Write data to buffer
    pub fn write(self: *RingBuffer, data: []const u8) usize {
        const available = self.availableWrite();
        const to_write = @min(data.len, available);

        if (to_write == 0) return 0;

        const capacity = self.data.len;
        const first_chunk = @min(to_write, capacity - self.write_pos);
        @memcpy(self.data[self.write_pos..][0..first_chunk], data[0..first_chunk]);

        if (first_chunk < to_write) {
            const second_chunk = to_write - first_chunk;
            @memcpy(self.data[0..second_chunk], data[first_chunk..to_write]);
        }

        self.write_pos = (self.write_pos + to_write) % capacity;
        self.size += to_write;

        return to_write;
    }

    /// Read data from buffer
    pub fn read(self: *RingBuffer, buf: []u8) usize {
        const available = self.availableRead();
        const to_read = @min(buf.len, available);

        if (to_read == 0) return 0;

        const capacity = self.data.len;
        const first_chunk = @min(to_read, capacity - self.read_pos);
        @memcpy(buf[0..first_chunk], self.data[self.read_pos..][0..first_chunk]);

        if (first_chunk < to_read) {
            const second_chunk = to_read - first_chunk;
            @memcpy(buf[first_chunk..to_read], self.data[0..second_chunk]);
        }

        self.read_pos = (self.read_pos + to_read) % capacity;
        self.size -= to_read;

        return to_read;
    }

    /// Peek at data without consuming
    pub fn peek(self: RingBuffer, buf: []u8) usize {
        const available = self.availableRead();
        const to_peek = @min(buf.len, available);

        if (to_peek == 0) return 0;

        const capacity = self.data.len;
        const first_chunk = @min(to_peek, capacity - self.read_pos);
        @memcpy(buf[0..first_chunk], self.data[self.read_pos..][0..first_chunk]);

        if (first_chunk < to_peek) {
            const second_chunk = to_peek - first_chunk;
            @memcpy(buf[first_chunk..to_peek], self.data[0..second_chunk]);
        }

        return to_peek;
    }

    /// Clear the buffer
    pub fn clear(self: *RingBuffer) void {
        self.read_pos = 0;
        self.write_pos = 0;
        self.size = 0;
    }

    /// Check if buffer is empty
    pub fn isEmpty(self: RingBuffer) bool {
        return self.size == 0;
    }

    /// Check if buffer is full
    pub fn isFull(self: RingBuffer) bool {
        return self.size == self.data.len;
    }
};

// Tests

test "ring buffer basic operations" {
    const allocator = std.testing.allocator;

    var buf = try RingBuffer.init(allocator, 10);
    defer buf.deinit();

    try std.testing.expect(buf.isEmpty());
    try std.testing.expectEqual(@as(usize, 10), buf.availableWrite());
    try std.testing.expectEqual(@as(usize, 0), buf.availableRead());
}

test "ring buffer write and read" {
    const allocator = std.testing.allocator;

    var buf = try RingBuffer.init(allocator, 10);
    defer buf.deinit();

    const test_data = "Hello";
    const written = buf.write(test_data);
    try std.testing.expectEqual(@as(usize, 5), written);
    try std.testing.expectEqual(@as(usize, 5), buf.availableRead());

    var read_buf: [10]u8 = undefined;
    const read = buf.read(&read_buf);
    try std.testing.expectEqual(@as(usize, 5), read);
    try std.testing.expectEqualStrings(test_data, read_buf[0..read]);
    try std.testing.expect(buf.isEmpty());
}

test "ring buffer wrap around" {
    const allocator = std.testing.allocator;

    var buf = try RingBuffer.init(allocator, 10);
    defer buf.deinit();

    // Write 8 bytes
    _ = buf.write("12345678");
    try std.testing.expectEqual(@as(usize, 8), buf.availableRead());

    // Read 5 bytes
    var read_buf: [10]u8 = undefined;
    _ = buf.read(read_buf[0..5]);
    try std.testing.expectEqual(@as(usize, 3), buf.availableRead());

    // Write 7 more bytes (will wrap around)
    const written = buf.write("abcdefg");
    try std.testing.expectEqual(@as(usize, 7), written);
    try std.testing.expectEqual(@as(usize, 10), buf.availableRead());

    // Read all
    const read = buf.read(&read_buf);
    try std.testing.expectEqual(@as(usize, 10), read);
    try std.testing.expectEqualStrings("678abcdefg", read_buf[0..read]);
}

test "ring buffer overflow" {
    const allocator = std.testing.allocator;

    var buf = try RingBuffer.init(allocator, 5);
    defer buf.deinit();

    const written = buf.write("1234567890");
    try std.testing.expectEqual(@as(usize, 5), written); // Only 5 bytes fit
    try std.testing.expect(buf.isFull());
}

test "ring buffer peek" {
    const allocator = std.testing.allocator;

    var buf = try RingBuffer.init(allocator, 10);
    defer buf.deinit();

    _ = buf.write("Hello");

    var peek_buf: [10]u8 = undefined;
    const peeked = buf.peek(&peek_buf);
    try std.testing.expectEqual(@as(usize, 5), peeked);
    try std.testing.expectEqualStrings("Hello", peek_buf[0..peeked]);

    // Data should still be in buffer
    try std.testing.expectEqual(@as(usize, 5), buf.availableRead());
}
