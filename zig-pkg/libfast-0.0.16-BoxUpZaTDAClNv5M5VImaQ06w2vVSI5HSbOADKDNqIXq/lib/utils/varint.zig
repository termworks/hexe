const std = @import("std");

/// QUIC variable-length integer encoding (RFC 9000, Section 16)
/// Encodes integers in 1, 2, 4, or 8 bytes based on value
///
/// Format:
/// - 00xxxxxx: 1 byte  (6-bit value, max 63)
/// - 01xxxxxx: 2 bytes (14-bit value, max 16383)
/// - 10xxxxxx: 4 bytes (30-bit value, max 1073741823)
/// - 11xxxxxx: 8 bytes (62-bit value, max 4611686018427387903)
/// Maximum value that can be encoded in a varint
pub const MAX_VARINT: u64 = 4611686018427387903;

/// Error types for varint operations
pub const VarintError = error{
    /// Value too large to encode as varint
    ValueTooLarge,
    /// Buffer too small for encoding
    BufferTooSmall,
    /// Invalid varint encoding
    InvalidEncoding,
    /// Not enough bytes to decode
    UnexpectedEof,
};

/// Returns the number of bytes needed to encode a value
pub fn encodedLen(value: u64) u8 {
    if (value <= 63) return 1;
    if (value <= 16383) return 2;
    if (value <= 1073741823) return 4;
    if (value <= MAX_VARINT) return 8;
    return 0; // Value too large
}

/// Encodes a value as a varint into the buffer
/// Returns the number of bytes written
pub fn encode(value: u64, buf: []u8) VarintError!u8 {
    const len = encodedLen(value);
    if (len == 0) return error.ValueTooLarge;
    if (buf.len < len) return error.BufferTooSmall;

    switch (len) {
        1 => {
            buf[0] = @intCast(value);
            return 1;
        },
        2 => {
            const val: u16 = @intCast(value);
            std.mem.writeInt(u16, buf[0..2], val | 0x4000, .big);
            return 2;
        },
        4 => {
            const val: u32 = @intCast(value);
            std.mem.writeInt(u32, buf[0..4], val | 0x80000000, .big);
            return 4;
        },
        8 => {
            const val: u64 = value;
            std.mem.writeInt(u64, buf[0..8], val | 0xC000000000000000, .big);
            return 8;
        },
        else => unreachable,
    }
}

/// Decodes a varint from the buffer
/// Returns the decoded value and the number of bytes consumed
pub fn decode(buf: []const u8) VarintError!struct { value: u64, len: u8 } {
    if (buf.len == 0) return error.UnexpectedEof;

    const first_byte = buf[0];
    const prefix = first_byte >> 6;

    const len: u8 = switch (prefix) {
        0b00 => 1,
        0b01 => 2,
        0b10 => 4,
        0b11 => 8,
        else => unreachable,
    };

    if (buf.len < len) return error.UnexpectedEof;

    const value: u64 = switch (len) {
        1 => first_byte,
        2 => blk: {
            const val = std.mem.readInt(u16, buf[0..2], .big);
            break :blk val & 0x3FFF;
        },
        4 => blk: {
            const val = std.mem.readInt(u32, buf[0..4], .big);
            break :blk val & 0x3FFFFFFF;
        },
        8 => blk: {
            const val = std.mem.readInt(u64, buf[0..8], .big);
            break :blk val & 0x3FFFFFFFFFFFFFFF;
        },
        else => unreachable,
    };

    return .{ .value = value, .len = len };
}

/// Peeks at a varint without consuming it
/// Returns the decoded value and its length
pub fn peek(buf: []const u8) VarintError!struct { value: u64, len: u8 } {
    return decode(buf);
}

// Tests

test "varint encoded length" {
    try std.testing.expectEqual(@as(u8, 1), encodedLen(0));
    try std.testing.expectEqual(@as(u8, 1), encodedLen(63));
    try std.testing.expectEqual(@as(u8, 2), encodedLen(64));
    try std.testing.expectEqual(@as(u8, 2), encodedLen(16383));
    try std.testing.expectEqual(@as(u8, 4), encodedLen(16384));
    try std.testing.expectEqual(@as(u8, 4), encodedLen(1073741823));
    try std.testing.expectEqual(@as(u8, 8), encodedLen(1073741824));
    try std.testing.expectEqual(@as(u8, 8), encodedLen(MAX_VARINT));
    try std.testing.expectEqual(@as(u8, 0), encodedLen(MAX_VARINT + 1));
}

test "varint encode 1 byte" {
    var buf: [8]u8 = undefined;

    const len = try encode(0, &buf);
    try std.testing.expectEqual(@as(u8, 1), len);
    try std.testing.expectEqual(@as(u8, 0x00), buf[0]);

    const len2 = try encode(63, &buf);
    try std.testing.expectEqual(@as(u8, 1), len2);
    try std.testing.expectEqual(@as(u8, 0x3F), buf[0]);
}

test "varint encode 2 bytes" {
    var buf: [8]u8 = undefined;

    const len = try encode(64, &buf);
    try std.testing.expectEqual(@as(u8, 2), len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x40, 0x40 }, buf[0..2]);

    const len2 = try encode(16383, &buf);
    try std.testing.expectEqual(@as(u8, 2), len2);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x7F, 0xFF }, buf[0..2]);
}

test "varint encode 4 bytes" {
    var buf: [8]u8 = undefined;

    const len = try encode(16384, &buf);
    try std.testing.expectEqual(@as(u8, 4), len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0x00, 0x40, 0x00 }, buf[0..4]);

    const len2 = try encode(1073741823, &buf);
    try std.testing.expectEqual(@as(u8, 4), len2);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xBF, 0xFF, 0xFF, 0xFF }, buf[0..4]);
}

test "varint encode 8 bytes" {
    var buf: [8]u8 = undefined;

    const len = try encode(1073741824, &buf);
    try std.testing.expectEqual(@as(u8, 8), len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xC0, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00 }, buf[0..8]);

    const len2 = try encode(MAX_VARINT, &buf);
    try std.testing.expectEqual(@as(u8, 8), len2);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, buf[0..8]);
}

test "varint encode error value too large" {
    var buf: [8]u8 = undefined;
    try std.testing.expectError(error.ValueTooLarge, encode(MAX_VARINT + 1, &buf));
}

test "varint encode error buffer too small" {
    var buf: [1]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, encode(64, &buf));
}

test "varint decode 1 byte" {
    const result = try decode(&[_]u8{0x00});
    try std.testing.expectEqual(@as(u64, 0), result.value);
    try std.testing.expectEqual(@as(u8, 1), result.len);

    const result2 = try decode(&[_]u8{0x3F});
    try std.testing.expectEqual(@as(u64, 63), result2.value);
    try std.testing.expectEqual(@as(u8, 1), result2.len);
}

test "varint decode 2 bytes" {
    const result = try decode(&[_]u8{ 0x40, 0x40 });
    try std.testing.expectEqual(@as(u64, 64), result.value);
    try std.testing.expectEqual(@as(u8, 2), result.len);

    const result2 = try decode(&[_]u8{ 0x7F, 0xFF });
    try std.testing.expectEqual(@as(u64, 16383), result2.value);
    try std.testing.expectEqual(@as(u8, 2), result2.len);
}

test "varint decode 4 bytes" {
    const result = try decode(&[_]u8{ 0x80, 0x00, 0x40, 0x00 });
    try std.testing.expectEqual(@as(u64, 16384), result.value);
    try std.testing.expectEqual(@as(u8, 4), result.len);

    const result2 = try decode(&[_]u8{ 0xBF, 0xFF, 0xFF, 0xFF });
    try std.testing.expectEqual(@as(u64, 1073741823), result2.value);
    try std.testing.expectEqual(@as(u8, 4), result2.len);
}

test "varint decode 8 bytes" {
    const result = try decode(&[_]u8{ 0xC0, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00 });
    try std.testing.expectEqual(@as(u64, 1073741824), result.value);
    try std.testing.expectEqual(@as(u8, 8), result.len);

    const result2 = try decode(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
    try std.testing.expectEqual(@as(u64, MAX_VARINT), result2.value);
    try std.testing.expectEqual(@as(u8, 8), result2.len);
}

test "varint decode error unexpected eof" {
    try std.testing.expectError(error.UnexpectedEof, decode(&[_]u8{}));
    try std.testing.expectError(error.UnexpectedEof, decode(&[_]u8{0x40}));
    try std.testing.expectError(error.UnexpectedEof, decode(&[_]u8{ 0x80, 0x00 }));
}

test "varint round trip" {
    const test_values = [_]u64{ 0, 1, 63, 64, 255, 256, 16383, 16384, 1073741823, 1073741824, MAX_VARINT };

    var buf: [8]u8 = undefined;
    for (test_values) |val| {
        const enc_len = try encode(val, &buf);
        const result = try decode(buf[0..enc_len]);
        try std.testing.expectEqual(val, result.value);
        try std.testing.expectEqual(enc_len, result.len);
    }
}

test "varint decode malformed corpus" {
    const malformed = [_][]const u8{
        &[_]u8{},
        &[_]u8{0x40},
        &[_]u8{ 0x80, 0x00 },
        &[_]u8{ 0xC0, 0x00, 0x00, 0x00 },
    };

    for (malformed) |sample| {
        try std.testing.expectError(error.UnexpectedEof, decode(sample));
    }
}

test "varint lsquic compatibility vectors" {
    const vectors = [_]struct {
        encoded: []const u8,
        value: u64,
        canonical: bool,
    }{
        .{ .encoded = &[_]u8{0x25}, .value = 0x25, .canonical = true },
        .{ .encoded = &[_]u8{ 0x40, 0x25 }, .value = 0x25, .canonical = false },
        .{ .encoded = &[_]u8{ 0x9D, 0x7F, 0x3E, 0x7D }, .value = 494878333, .canonical = true },
        .{ .encoded = &[_]u8{ 0xC2, 0x19, 0x7C, 0x5E, 0xFF, 0x14, 0xE8, 0x8C }, .value = 151288809941952652, .canonical = true },
    };

    for (vectors) |vector| {
        const decoded = try decode(vector.encoded);
        try std.testing.expectEqual(vector.value, decoded.value);
        try std.testing.expectEqual(@as(u8, @intCast(vector.encoded.len)), decoded.len);

        var out: [8]u8 = undefined;
        const encoded_len = try encode(vector.value, &out);
        try std.testing.expectEqual(encodedLen(vector.value), encoded_len);

        const decoded_roundtrip = try decode(out[0..encoded_len]);
        try std.testing.expectEqual(vector.value, decoded_roundtrip.value);

        if (vector.canonical) {
            try std.testing.expectEqual(@as(usize, encoded_len), vector.encoded.len);
            try std.testing.expectEqualSlices(u8, vector.encoded, out[0..encoded_len]);
        }
    }

    try std.testing.expectError(error.UnexpectedEof, decode(&[_]u8{0x40}));
    try std.testing.expectError(error.UnexpectedEof, decode(&[_]u8{ 0x9D, 0x7F }));
    try std.testing.expectError(error.UnexpectedEof, decode(&[_]u8{ 0xC2, 0x19, 0x7C, 0x5E, 0xFF, 0x14, 0xE8 }));
}

test "varint decode fuzz smoke" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();

    var buf: [8]u8 = undefined;
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        rand.bytes(&buf);
        const len: usize = rand.intRangeAtMost(usize, 0, buf.len);
        const sample = buf[0..len];

        const result = decode(sample) catch continue;
        try std.testing.expect(result.len <= sample.len);
    }
}
