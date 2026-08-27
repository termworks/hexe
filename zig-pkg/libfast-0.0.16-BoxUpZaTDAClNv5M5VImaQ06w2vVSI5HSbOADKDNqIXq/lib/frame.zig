const std = @import("std");

/// QUIC Frame Types
///
/// For SSH/QUIC, we need:
/// - STREAM frames (carry SSH data)
/// - MAX_STREAM_DATA frames (flow control)
/// - ACK frames (acknowledge packets)
/// - CONNECTION_CLOSE frames (teardown)

pub const FrameType = enum(u8) {
    ping = 0x01,
    stream = 0x08, // Base type, actual value varies with flags
    max_stream_data = 0x05,
    ack = 0x02,
    connection_close = 0x1c,

    pub fn encode(self: FrameType, buffer: []u8) !usize {
        if (buffer.len < 1) return error.BufferTooSmall;
        buffer[0] = @intFromEnum(self);
        return 1;
    }

    pub fn decode(buffer: []const u8) !FrameType {
        if (buffer.len < 1) return error.BufferTooSmall;
        const type_byte = buffer[0];

        // STREAM frames are 0x08-0x0F (with various flag combinations)
        if (type_byte >= 0x08 and type_byte <= 0x0F) {
            return .stream;
        }

        return std.meta.intToEnum(FrameType, type_byte) catch error.UnknownFrameType;
    }
};

/// STREAM Frame
///
/// Format:
/// - Type (0x08-0x0F based on flags)
/// - Stream ID (variable length integer)
/// - [Offset] (if OFF flag set)
/// - [Length] (if LEN flag set)
/// - Stream Data
///
/// Flags (in type byte):
/// - 0x01: FIN (last frame for stream)
/// - 0x02: LEN (length field present)
/// - 0x04: OFF (offset field present)
pub const StreamFrame = struct {
    stream_id: u64,
    offset: u64 = 0,
    data: []const u8,
    fin: bool = false,

    pub fn encode(self: StreamFrame, allocator: std.mem.Allocator) ![]u8 {
        // Calculate size
        var size: usize = 1; // Type byte
        size += varIntSize(self.stream_id);

        const has_offset = self.offset > 0;
        if (has_offset) {
            size += varIntSize(self.offset);
        }

        size += varIntSize(self.data.len); // Length always present for simplicity
        size += self.data.len;

        // Allocate buffer
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var offset: usize = 0;

        // Type byte with flags
        var type_byte: u8 = 0x08; // Base STREAM type
        if (self.fin) type_byte |= 0x01;
        type_byte |= 0x02; // LEN flag (always include length)
        if (has_offset) type_byte |= 0x04;

        buffer[offset] = type_byte;
        offset += 1;

        // Stream ID
        offset += encodeVarInt(self.stream_id, buffer[offset..]);

        // Offset (if present)
        if (has_offset) {
            offset += encodeVarInt(self.offset, buffer[offset..]);
        }

        // Length
        offset += encodeVarInt(self.data.len, buffer[offset..]);

        // Data
        if (offset + self.data.len > buffer.len) {
            std.log.err("Buffer overflow in StreamFrame.encode: offset={}, data.len={}, buffer.len={}", .{ offset, self.data.len, buffer.len });
            return error.BufferOverflow;
        }

        @memcpy(buffer[offset .. offset + self.data.len], self.data);
        offset += self.data.len;

        return buffer[0..offset];
    }

    pub fn decode(allocator: std.mem.Allocator, buffer: []const u8) !StreamFrame {
        if (buffer.len < 2) return error.BufferTooSmall;

        var offset: usize = 0;

        // Parse type byte
        const type_byte = buffer[offset];
        offset += 1;

        const fin = (type_byte & 0x01) != 0;
        const has_len = (type_byte & 0x02) != 0;
        const has_off = (type_byte & 0x04) != 0;

        // Stream ID
        const stream_id_result = try decodeVarInt(buffer[offset..]);
        const stream_id = stream_id_result.value;
        offset += stream_id_result.bytes;

        // Offset (if present)
        var stream_offset: u64 = 0;
        if (has_off) {
            const offset_result = try decodeVarInt(buffer[offset..]);
            stream_offset = offset_result.value;
            offset += offset_result.bytes;
        }

        // Length
        var data_len: usize = 0;
        if (has_len) {
            const len_result = try decodeVarInt(buffer[offset..]);
            data_len = len_result.value;
            offset += len_result.bytes;
        } else {
            // If no length field, data extends to end of buffer
            data_len = buffer.len - offset;
        }

        // Data
        if (offset + data_len > buffer.len) return error.BufferTooSmall;
        const data = try allocator.dupe(u8, buffer[offset .. offset + data_len]);

        return StreamFrame{
            .stream_id = stream_id,
            .offset = stream_offset,
            .data = data,
            .fin = fin,
        };
    }
};

/// MAX_STREAM_DATA Frame (flow control)
pub const MaxStreamDataFrame = struct {
    stream_id: u64,
    maximum_stream_data: u64,

    pub fn encode(self: MaxStreamDataFrame, buffer: []u8) !usize {
        if (buffer.len < 17) return error.BufferTooSmall; // Max size

        var offset: usize = 0;

        // Type
        buffer[offset] = @intFromEnum(FrameType.max_stream_data);
        offset += 1;

        // Stream ID
        offset += encodeVarInt(self.stream_id, buffer[offset..]);

        // Maximum Data
        offset += encodeVarInt(self.maximum_stream_data, buffer[offset..]);

        return offset;
    }

    pub fn decode(buffer: []const u8) !MaxStreamDataFrame {
        if (buffer.len < 3) return error.BufferTooSmall;

        var offset: usize = 1; // Skip type byte

        // Stream ID
        const stream_id_result = try decodeVarInt(buffer[offset..]);
        offset += stream_id_result.bytes;

        // Maximum Data
        const max_data_result = try decodeVarInt(buffer[offset..]);

        return MaxStreamDataFrame{
            .stream_id = stream_id_result.value,
            .maximum_stream_data = max_data_result.value,
        };
    }
};

/// ACK Frame (simplified - just largest acknowledged)
pub const AckFrame = struct {
    largest_acknowledged: u64,

    pub fn encode(self: AckFrame, buffer: []u8) !usize {
        if (buffer.len < 10) return error.BufferTooSmall;

        var offset: usize = 0;

        // Type
        buffer[offset] = @intFromEnum(FrameType.ack);
        offset += 1;

        // Largest Acknowledged
        offset += encodeVarInt(self.largest_acknowledged, buffer[offset..]);

        // ACK Delay (simplified - set to 0)
        offset += encodeVarInt(0, buffer[offset..]);

        // ACK Range Count (simplified - 0 ranges)
        offset += encodeVarInt(0, buffer[offset..]);

        return offset;
    }

    pub fn decode(buffer: []const u8) !AckFrame {
        if (buffer.len < 2) return error.BufferTooSmall;

        const offset: usize = 1; // Skip type byte

        // Largest Acknowledged
        const largest_ack_result = try decodeVarInt(buffer[offset..]);

        return AckFrame{
            .largest_acknowledged = largest_ack_result.value,
        };
    }
};

// ============================================================================
// Variable Length Integer Encoding (QUIC-specific)
// ============================================================================

/// Encode variable-length integer (QUIC format)
///
/// Returns bytes written
fn encodeVarInt(value: u64, buffer: []u8) usize {
    if (value <= 63) {
        // 1 byte: 00xxxxxx
        buffer[0] = @intCast(value);
        return 1;
    } else if (value <= 16383) {
        // 2 bytes: 01xxxxxx xxxxxxxx
        const val16: u16 = @intCast(value);
        std.mem.writeInt(u16, buffer[0..2], val16 | 0x4000, .big);
        return 2;
    } else if (value <= 1073741823) {
        // 4 bytes: 10xxxxxx ...
        const val32: u32 = @intCast(value);
        std.mem.writeInt(u32, buffer[0..4], val32 | 0x80000000, .big);
        return 4;
    } else {
        // 8 bytes: 11xxxxxx ...
        std.mem.writeInt(u64, buffer[0..8], value | 0xC000000000000000, .big);
        return 8;
    }
}

/// Decode variable-length integer
///
/// Returns (value, bytes_consumed)
fn decodeVarInt(buffer: []const u8) !struct { value: u64, bytes: usize } {
    if (buffer.len < 1) return error.BufferTooSmall;

    const first_byte = buffer[0];
    const prefix = first_byte >> 6;

    return switch (prefix) {
        0b00 => .{ .value = first_byte, .bytes = 1 },
        0b01 => {
            if (buffer.len < 2) return error.BufferTooSmall;
            const val = std.mem.readInt(u16, buffer[0..2], .big) & 0x3FFF;
            return .{ .value = val, .bytes = 2 };
        },
        0b10 => {
            if (buffer.len < 4) return error.BufferTooSmall;
            const val = std.mem.readInt(u32, buffer[0..4], .big) & 0x3FFFFFFF;
            return .{ .value = val, .bytes = 4 };
        },
        0b11 => {
            if (buffer.len < 8) return error.BufferTooSmall;
            const val = std.mem.readInt(u64, buffer[0..8], .big) & 0x3FFFFFFFFFFFFFFF;
            return .{ .value = val, .bytes = 8 };
        },
        else => unreachable, // prefix is only 2 bits, all cases covered
    };
}

/// Calculate bytes needed for variable-length integer
fn varIntSize(value: u64) usize {
    if (value <= 63) return 1;
    if (value <= 16383) return 2;
    if (value <= 1073741823) return 4;
    return 8;
}

// ============================================================================
// Tests
// ============================================================================

test "StreamFrame - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const original = StreamFrame{
        .stream_id = 4,
        .offset = 1024,
        .data = "Hello QUIC!",
        .fin = true,
    };

    // Encode
    const encoded = try original.encode(allocator);
    defer allocator.free(encoded);

    // Decode
    const decoded = try StreamFrame.decode(allocator, encoded);
    defer allocator.free(decoded.data);

    // Verify
    try testing.expectEqual(original.stream_id, decoded.stream_id);
    try testing.expectEqual(original.offset, decoded.offset);
    try testing.expectEqual(original.fin, decoded.fin);
    try testing.expectEqualSlices(u8, original.data, decoded.data);
}

test "varInt encoding" {
    const testing = std.testing;

    var buffer: [8]u8 = undefined;

    // Test 1-byte encoding
    _ = encodeVarInt(42, &buffer);
    const result1 = try decodeVarInt(&buffer);
    try testing.expectEqual(@as(u64, 42), result1.value);
    try testing.expectEqual(@as(usize, 1), result1.bytes);

    // Test 2-byte encoding
    _ = encodeVarInt(1000, &buffer);
    const result2 = try decodeVarInt(&buffer);
    try testing.expectEqual(@as(u64, 1000), result2.value);
    try testing.expectEqual(@as(usize, 2), result2.bytes);

    // Test 4-byte encoding
    _ = encodeVarInt(100000, &buffer);
    const result4 = try decodeVarInt(&buffer);
    try testing.expectEqual(@as(u64, 100000), result4.value);
    try testing.expectEqual(@as(usize, 4), result4.bytes);
}
