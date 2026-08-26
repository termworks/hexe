const std = @import("std");
const Allocator = std.mem.Allocator;

/// Wire encoding errors
pub const WireError = error{
    BufferTooSmall,
    EndOfBuffer,
    InvalidEncoding,
    InvalidString,
    InvalidMpint,
    OutOfRange,
};

/// Reader for decoding SSH wire format from a buffer
pub const Reader = struct {
    buffer: []const u8,
    offset: usize = 0,

    pub fn init(buffer: []const u8) Reader {
        return .{ .buffer = buffer };
    }

    /// Get remaining bytes in buffer
    pub fn remaining(self: Reader) usize {
        return self.buffer.len - self.offset;
    }

    /// Check if at end of buffer
    pub fn isAtEnd(self: Reader) bool {
        return self.offset >= self.buffer.len;
    }

    /// Peek at next byte without consuming
    pub fn peek(self: Reader) ?u8 {
        if (self.offset >= self.buffer.len) return null;
        return self.buffer[self.offset];
    }

    /// Read raw bytes into destination
    pub fn readBytes(self: *Reader, dest: []u8) WireError!void {
        if (self.remaining() < dest.len) return error.EndOfBuffer;
        @memcpy(dest, self.buffer[self.offset..][0..dest.len]);
        self.offset += dest.len;
    }

    /// Read a single byte
    pub fn readByte(self: *Reader) WireError!u8 {
        if (self.offset >= self.buffer.len) return error.EndOfBuffer;
        const value = self.buffer[self.offset];
        self.offset += 1;
        return value;
    }

    /// Read a boolean (encoded as byte: 0 = false, 1 = true)
    pub fn readBoolean(self: *Reader) WireError!bool {
        const value = try self.readByte();
        return value != 0;
    }

    /// Alias for readBoolean
    pub const readBool = readBoolean;

    /// Read uint32 in big-endian format
    pub fn readUint32(self: *Reader) WireError!u32 {
        if (self.remaining() < 4) return error.EndOfBuffer;
        const value = std.mem.readInt(u32, self.buffer[self.offset..][0..4], .big);
        self.offset += 4;
        return value;
    }

    /// Read uint64 in big-endian format
    pub fn readUint64(self: *Reader) WireError!u64 {
        if (self.remaining() < 8) return error.EndOfBuffer;
        const value = std.mem.readInt(u64, self.buffer[self.offset..][0..8], .big);
        self.offset += 8;
        return value;
    }

    /// Read string (uint32 length prefix + data)
    /// Caller owns the returned slice, allocated with provided allocator
    pub fn readString(self: *Reader, allocator: Allocator) (WireError || Allocator.Error)![]u8 {
        const len = try self.readUint32();
        if (self.remaining() < len) return error.EndOfBuffer;

        const data = try allocator.alloc(u8, len);
        errdefer allocator.free(data);

        try self.readBytes(data);
        return data;
    }

    /// Read string without allocation (returns slice into buffer)
    pub fn readStringBorrowed(self: *Reader) WireError![]const u8 {
        const len = try self.readUint32();
        if (self.remaining() < len) return error.EndOfBuffer;

        const data = self.buffer[self.offset..][0..len];
        self.offset += len;
        return data;
    }

    /// Read short-str (byte length prefix + data, max 255 bytes)
    /// Caller owns the returned slice
    pub fn readShortString(self: *Reader, allocator: Allocator) (WireError || Allocator.Error)![]u8 {
        const len = try self.readByte();
        if (self.remaining() < len) return error.EndOfBuffer;

        const data = try allocator.alloc(u8, len);
        errdefer allocator.free(data);

        try self.readBytes(data);
        return data;
    }

    /// Read short-str without allocation (returns slice into buffer)
    pub fn readShortStringBorrowed(self: *Reader) WireError![]const u8 {
        const len = try self.readByte();
        if (self.remaining() < len) return error.EndOfBuffer;

        const data = self.buffer[self.offset..][0..len];
        self.offset += len;
        return data;
    }

    /// Alias for readShortString
    pub const readShortStr = readShortString;

    /// Read mpint (multi-precision integer) as a signed big integer
    /// Returns the bytes representing the mpint in big-endian format
    /// Caller owns the returned slice
    pub fn readMpint(self: *Reader, allocator: Allocator) (WireError || Allocator.Error)![]u8 {
        const len = try self.readUint32();
        if (len == 0) {
            // Zero is represented as empty
            return try allocator.alloc(u8, 0);
        }

        if (self.remaining() < len) return error.EndOfBuffer;

        const data = try allocator.alloc(u8, len);
        errdefer allocator.free(data);

        try self.readBytes(data);

        // Validate mpint format
        if (data.len > 0) {
            // Check for unnecessary leading bytes
            if (data.len > 1) {
                if ((data[0] == 0x00 and (data[1] & 0x80) == 0) or
                    (data[0] == 0xFF and (data[1] & 0x80) != 0))
                {
                    allocator.free(data);
                    return error.InvalidMpint;
                }
            }
        }

        return data;
    }
};

/// Writer for encoding SSH wire format to a buffer
pub const Writer = struct {
    buffer: []u8,
    offset: usize = 0,

    pub fn init(buffer: []u8) Writer {
        return .{ .buffer = buffer };
    }

    /// Get remaining space in buffer
    pub fn remaining(self: Writer) usize {
        return self.buffer.len - self.offset;
    }

    /// Get bytes written so far
    pub fn written(self: Writer) []const u8 {
        return self.buffer[0..self.offset];
    }

    /// Write raw bytes from source
    pub fn writeBytes(self: *Writer, src: []const u8) WireError!void {
        if (self.remaining() < src.len) return error.BufferTooSmall;
        @memcpy(self.buffer[self.offset..][0..src.len], src);
        self.offset += src.len;
    }

    /// Write a single byte
    pub fn writeByte(self: *Writer, value: u8) WireError!void {
        if (self.offset >= self.buffer.len) return error.BufferTooSmall;
        self.buffer[self.offset] = value;
        self.offset += 1;
    }

    /// Write a boolean (encoded as byte: 0 = false, 1 = true)
    pub fn writeBoolean(self: *Writer, value: bool) WireError!void {
        try self.writeByte(if (value) 1 else 0);
    }

    /// Alias for writeBoolean
    pub const writeBool = writeBoolean;

    /// Write uint32 in big-endian format
    pub fn writeUint32(self: *Writer, value: u32) WireError!void {
        if (self.remaining() < 4) return error.BufferTooSmall;
        std.mem.writeInt(u32, self.buffer[self.offset..][0..4], value, .big);
        self.offset += 4;
    }

    /// Write uint64 in big-endian format
    pub fn writeUint64(self: *Writer, value: u64) WireError!void {
        if (self.remaining() < 8) return error.BufferTooSmall;
        std.mem.writeInt(u64, self.buffer[self.offset..][0..8], value, .big);
        self.offset += 8;
    }

    /// Write string (uint32 length prefix + data)
    pub fn writeString(self: *Writer, data: []const u8) WireError!void {
        if (data.len > std.math.maxInt(u32)) return error.OutOfRange;
        try self.writeUint32(@intCast(data.len));
        try self.writeBytes(data);
    }

    /// Write short-str (byte length prefix + data, max 255 bytes)
    pub fn writeShortString(self: *Writer, data: []const u8) WireError!void {
        if (data.len > 255) return error.OutOfRange;
        try self.writeByte(@intCast(data.len));
        try self.writeBytes(data);
    }

    /// Alias for writeShortString
    pub const writeShortStr = writeShortString;

    /// Write mpint (multi-precision integer) from bytes in big-endian format
    /// The input should be in two's complement representation
    pub fn writeMpint(self: *Writer, data: []const u8) WireError!void {
        // Handle zero
        if (data.len == 0) {
            try self.writeUint32(0);
            return;
        }

        // Determine if we need padding
        var need_padding = false;
        if (data[0] & 0x80 != 0) {
            // High bit set in positive number - need 0x00 padding
            need_padding = true;
        }

        // Remove unnecessary leading zeros (but keep one if needed for sign)
        var start: usize = 0;
        while (start < data.len - 1) {
            if (data[start] == 0 and (data[start + 1] & 0x80) == 0) {
                start += 1;
            } else {
                break;
            }
        }

        const trimmed = data[start..];
        const len = if (need_padding) trimmed.len + 1 else trimmed.len;

        if (len > std.math.maxInt(u32)) return error.OutOfRange;
        try self.writeUint32(@intCast(len));
        if (need_padding) {
            try self.writeByte(0x00);
        }
        try self.writeBytes(trimmed);
    }

    /// Write mpint from unsigned integer
    pub fn writeMpintFromUint(self: *Writer, value: anytype) WireError!void {
        const T = @TypeOf(value);
        const type_info = @typeInfo(T);

        if (type_info != .int or type_info.int.signedness != .unsigned) {
            @compileError("writeMpintFromUint requires unsigned integer type");
        }

        if (value == 0) {
            try self.writeUint32(0);
            return;
        }

        // Convert to big-endian bytes
        var bytes: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .big);

        // Find first non-zero byte
        var start: usize = 0;
        while (start < bytes.len and bytes[start] == 0) : (start += 1) {}

        try self.writeMpint(bytes[start..]);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Reader and Writer - byte" {
    const testing = std.testing;

    var buf: [16]u8 = undefined;
    var writer = Writer.init(&buf);

    // Write bytes
    try writer.writeByte(42);
    try writer.writeByte(0);
    try writer.writeByte(255);

    // Read them back
    var reader = Reader.init(writer.written());
    try testing.expectEqual(@as(u8, 42), try reader.readByte());
    try testing.expectEqual(@as(u8, 0), try reader.readByte());
    try testing.expectEqual(@as(u8, 255), try reader.readByte());
    try testing.expect(reader.isAtEnd());
}

test "Reader and Writer - boolean" {
    const testing = std.testing;

    var buf: [16]u8 = undefined;
    var writer = Writer.init(&buf);

    // Write booleans
    try writer.writeBoolean(true);
    try writer.writeBoolean(false);
    try writer.writeBoolean(true);

    // Read them back
    var reader = Reader.init(writer.written());
    try testing.expectEqual(true, try reader.readBoolean());
    try testing.expectEqual(false, try reader.readBoolean());
    try testing.expectEqual(true, try reader.readBoolean());
}

test "Reader and Writer - uint32" {
    const testing = std.testing;

    var buf: [32]u8 = undefined;
    var writer = Writer.init(&buf);

    // Write uint32 values
    try writer.writeUint32(0);
    try writer.writeUint32(1);
    try writer.writeUint32(0x12345678);
    try writer.writeUint32(0xFFFFFFFF);

    // Read them back
    var reader = Reader.init(writer.written());
    try testing.expectEqual(@as(u32, 0), try reader.readUint32());
    try testing.expectEqual(@as(u32, 1), try reader.readUint32());
    try testing.expectEqual(@as(u32, 0x12345678), try reader.readUint32());
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), try reader.readUint32());
}

test "Reader and Writer - uint64" {
    const testing = std.testing;

    var buf: [64]u8 = undefined;
    var writer = Writer.init(&buf);

    // Write uint64 values
    try writer.writeUint64(0);
    try writer.writeUint64(1);
    try writer.writeUint64(0x123456789ABCDEF0);
    try writer.writeUint64(0xFFFFFFFFFFFFFFFF);

    // Read them back
    var reader = Reader.init(writer.written());
    try testing.expectEqual(@as(u64, 0), try reader.readUint64());
    try testing.expectEqual(@as(u64, 1), try reader.readUint64());
    try testing.expectEqual(@as(u64, 0x123456789ABCDEF0), try reader.readUint64());
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), try reader.readUint64());
}

test "Reader - EndOfBuffer error" {
    const testing = std.testing;

    const buf = [_]u8{ 1, 2, 3 };
    var reader = Reader.init(&buf);

    // Read all bytes
    _ = try reader.readByte();
    _ = try reader.readByte();
    _ = try reader.readByte();

    // Should fail on next read
    try testing.expectError(error.EndOfBuffer, reader.readByte());
    try testing.expectError(error.EndOfBuffer, reader.readUint32());
    try testing.expectError(error.EndOfBuffer, reader.readUint64());
}

test "Writer - BufferTooSmall error" {
    const testing = std.testing;

    var buf: [2]u8 = undefined;
    var writer = Writer.init(&buf);

    // Write 2 bytes (should succeed)
    try writer.writeByte(1);
    try writer.writeByte(2);

    // Next write should fail
    try testing.expectError(error.BufferTooSmall, writer.writeByte(3));
}

test "Reader - peek and remaining" {
    const testing = std.testing;

    const buf = [_]u8{ 1, 2, 3, 4 };
    var reader = Reader.init(&buf);

    try testing.expectEqual(@as(usize, 4), reader.remaining());
    try testing.expectEqual(@as(?u8, 1), reader.peek());
    try testing.expectEqual(@as(?u8, 1), reader.peek()); // Peek doesn't advance

    _ = try reader.readByte();
    try testing.expectEqual(@as(usize, 3), reader.remaining());
    try testing.expectEqual(@as(?u8, 2), reader.peek());

    _ = try reader.readByte();
    _ = try reader.readByte();
    _ = try reader.readByte();
    try testing.expectEqual(@as(usize, 0), reader.remaining());
    try testing.expectEqual(@as(?u8, null), reader.peek());
    try testing.expect(reader.isAtEnd());
}

test "Writer - written and remaining" {
    const testing = std.testing;

    var buf: [10]u8 = undefined;
    var writer = Writer.init(&buf);

    try testing.expectEqual(@as(usize, 10), writer.remaining());
    try testing.expectEqual(@as(usize, 0), writer.written().len);

    try writer.writeByte(42);
    try testing.expectEqual(@as(usize, 9), writer.remaining());
    try testing.expectEqual(@as(usize, 1), writer.written().len);
    try testing.expectEqual(@as(u8, 42), writer.written()[0]);

    try writer.writeUint32(0x12345678);
    try testing.expectEqual(@as(usize, 5), writer.remaining());
    try testing.expectEqual(@as(usize, 5), writer.written().len);
}

test "Round-trip encoding - mixed types" {
    const testing = std.testing;

    var buf: [100]u8 = undefined;
    var writer = Writer.init(&buf);

    // Write mixed data
    try writer.writeByte(123);
    try writer.writeBoolean(true);
    try writer.writeUint32(0xDEADBEEF);
    try writer.writeBoolean(false);
    try writer.writeUint64(0x0123456789ABCDEF);
    try writer.writeByte(255);

    // Read it all back
    var reader = Reader.init(writer.written());
    try testing.expectEqual(@as(u8, 123), try reader.readByte());
    try testing.expectEqual(true, try reader.readBoolean());
    try testing.expectEqual(@as(u32, 0xDEADBEEF), try reader.readUint32());
    try testing.expectEqual(false, try reader.readBoolean());
    try testing.expectEqual(@as(u64, 0x0123456789ABCDEF), try reader.readUint64());
    try testing.expectEqual(@as(u8, 255), try reader.readByte());
    try testing.expect(reader.isAtEnd());
}

test "Big-endian encoding verification" {
    const testing = std.testing;

    var buf: [8]u8 = undefined;
    var writer = Writer.init(&buf);

    // Write uint32 in big-endian
    try writer.writeUint32(0x12345678);

    // Verify byte order (big-endian = most significant byte first)
    try testing.expectEqual(@as(u8, 0x12), buf[0]);
    try testing.expectEqual(@as(u8, 0x34), buf[1]);
    try testing.expectEqual(@as(u8, 0x56), buf[2]);
    try testing.expectEqual(@as(u8, 0x78), buf[3]);

    // Write uint64 in big-endian
    writer.offset = 0; // Reset
    try writer.writeUint64(0x123456789ABCDEF0);

    try testing.expectEqual(@as(u8, 0x12), buf[0]);
    try testing.expectEqual(@as(u8, 0x34), buf[1]);
    try testing.expectEqual(@as(u8, 0x56), buf[2]);
    try testing.expectEqual(@as(u8, 0x78), buf[3]);
    try testing.expectEqual(@as(u8, 0x9A), buf[4]);
    try testing.expectEqual(@as(u8, 0xBC), buf[5]);
    try testing.expectEqual(@as(u8, 0xDE), buf[6]);
    try testing.expectEqual(@as(u8, 0xF0), buf[7]);
}

test "Reader and Writer - string" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var buf: [100]u8 = undefined;
    var writer = Writer.init(&buf);

    // Write strings
    try writer.writeString("hello");
    try writer.writeString("");
    try writer.writeString("test string with spaces");

    // Read them back
    var reader = Reader.init(writer.written());

    const s1 = try reader.readString(allocator);
    defer allocator.free(s1);
    try testing.expectEqualStrings("hello", s1);

    const s2 = try reader.readString(allocator);
    defer allocator.free(s2);
    try testing.expectEqualStrings("", s2);

    const s3 = try reader.readString(allocator);
    defer allocator.free(s3);
    try testing.expectEqualStrings("test string with spaces", s3);
}

test "Reader and Writer - string borrowed" {
    const testing = std.testing;

    var buf: [100]u8 = undefined;
    var writer = Writer.init(&buf);

    try writer.writeString("borrowed");
    try writer.writeString("data");

    var reader = Reader.init(writer.written());

    const s1 = try reader.readStringBorrowed();
    try testing.expectEqualStrings("borrowed", s1);

    const s2 = try reader.readStringBorrowed();
    try testing.expectEqualStrings("data", s2);
}

test "Reader and Writer - short-str" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var buf: [300]u8 = undefined;
    var writer = Writer.init(&buf);

    // Write short strings
    try writer.writeShortString("short");
    try writer.writeShortString("");

    // Max length short string (255 bytes)
    var max_str: [255]u8 = undefined;
    @memset(&max_str, 'A');
    try writer.writeShortString(&max_str);

    // Read them back
    var reader = Reader.init(writer.written());

    const s1 = try reader.readShortString(allocator);
    defer allocator.free(s1);
    try testing.expectEqualStrings("short", s1);

    const s2 = try reader.readShortString(allocator);
    defer allocator.free(s2);
    try testing.expectEqualStrings("", s2);

    const s3 = try reader.readShortString(allocator);
    defer allocator.free(s3);
    try testing.expectEqual(@as(usize, 255), s3.len);
    try testing.expectEqual(@as(u8, 'A'), s3[0]);
    try testing.expectEqual(@as(u8, 'A'), s3[254]);
}

test "Writer - short-str too long" {
    const testing = std.testing;

    var buf: [300]u8 = undefined;
    var writer = Writer.init(&buf);

    // Try to write 256-byte short string (should fail)
    var too_long: [256]u8 = undefined;
    try testing.expectError(error.OutOfRange, writer.writeShortString(&too_long));
}

test "Reader and Writer - mpint zero" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var buf: [100]u8 = undefined;
    var writer = Writer.init(&buf);

    // Zero is encoded as length 0
    try writer.writeMpintFromUint(@as(u32, 0));

    var reader = Reader.init(writer.written());
    const data = try reader.readMpint(allocator);
    defer allocator.free(data);

    try testing.expectEqual(@as(usize, 0), data.len);
}

test "Reader and Writer - mpint positive" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var buf: [100]u8 = undefined;
    var writer = Writer.init(&buf);

    // Write various positive integers
    try writer.writeMpintFromUint(@as(u32, 1));
    try writer.writeMpintFromUint(@as(u32, 127));
    try writer.writeMpintFromUint(@as(u32, 128)); // Needs padding
    try writer.writeMpintFromUint(@as(u32, 0x12345678));

    var reader = Reader.init(writer.written());

    // Read 1
    const d1 = try reader.readMpint(allocator);
    defer allocator.free(d1);
    try testing.expectEqual(@as(usize, 1), d1.len);
    try testing.expectEqual(@as(u8, 0x01), d1[0]);

    // Read 127 (0x7F - no padding needed)
    const d2 = try reader.readMpint(allocator);
    defer allocator.free(d2);
    try testing.expectEqual(@as(usize, 1), d2.len);
    try testing.expectEqual(@as(u8, 0x7F), d2[0]);

    // Read 128 (0x80 - needs 0x00 padding)
    const d3 = try reader.readMpint(allocator);
    defer allocator.free(d3);
    try testing.expectEqual(@as(usize, 2), d3.len);
    try testing.expectEqual(@as(u8, 0x00), d3[0]);
    try testing.expectEqual(@as(u8, 0x80), d3[1]);

    // Read 0x12345678
    const d4 = try reader.readMpint(allocator);
    defer allocator.free(d4);
    try testing.expectEqual(@as(usize, 4), d4.len);
    try testing.expectEqual(@as(u8, 0x12), d4[0]);
    try testing.expectEqual(@as(u8, 0x34), d4[1]);
    try testing.expectEqual(@as(u8, 0x56), d4[2]);
    try testing.expectEqual(@as(u8, 0x78), d4[3]);
}

test "Reader and Writer - mpint raw bytes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var buf: [100]u8 = undefined;
    var writer = Writer.init(&buf);

    // Write mpint from raw bytes
    const raw1 = [_]u8{ 0x12, 0x34 };
    try writer.writeMpint(&raw1);

    const raw2 = [_]u8{ 0xFF }; // High bit set, needs 0x00 padding
    try writer.writeMpint(&raw2);

    var reader = Reader.init(writer.written());

    const d1 = try reader.readMpint(allocator);
    defer allocator.free(d1);
    try testing.expectEqualSlices(u8, &raw1, d1);

    const d2 = try reader.readMpint(allocator);
    defer allocator.free(d2);
    // 0xFF gets padded to 0x00 0xFF to avoid sign confusion
    try testing.expectEqual(@as(usize, 2), d2.len);
    try testing.expectEqual(@as(u8, 0x00), d2[0]);
    try testing.expectEqual(@as(u8, 0xFF), d2[1]);
}

test "Round-trip - complete message" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var buf: [1000]u8 = undefined;
    var writer = Writer.init(&buf);

    // Simulate an SSH packet with various field types
    try writer.writeByte(42); // Packet type
    try writer.writeString("test-algorithm");
    try writer.writeBoolean(true);
    try writer.writeUint32(0xDEADBEEF);
    try writer.writeShortString("short");
    try writer.writeMpintFromUint(@as(u64, 0x123456789ABCDEF0));
    try writer.writeUint64(9876543210);

    // Read it all back
    var reader = Reader.init(writer.written());

    try testing.expectEqual(@as(u8, 42), try reader.readByte());

    const str = try reader.readString(allocator);
    defer allocator.free(str);
    try testing.expectEqualStrings("test-algorithm", str);

    try testing.expectEqual(true, try reader.readBoolean());
    try testing.expectEqual(@as(u32, 0xDEADBEEF), try reader.readUint32());

    const short = try reader.readShortString(allocator);
    defer allocator.free(short);
    try testing.expectEqualStrings("short", short);

    const mpint = try reader.readMpint(allocator);
    defer allocator.free(mpint);
    // 0x123456789ABCDEF0 - first byte 0x12 has high bit clear, no padding needed
    try testing.expectEqual(@as(usize, 8), mpint.len);
    try testing.expectEqual(@as(u8, 0x12), mpint[0]);

    try testing.expectEqual(@as(u64, 9876543210), try reader.readUint64());
    try testing.expect(reader.isAtEnd());
}
