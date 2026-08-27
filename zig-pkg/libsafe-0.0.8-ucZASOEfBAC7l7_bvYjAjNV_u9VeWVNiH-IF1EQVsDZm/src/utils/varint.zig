const std = @import("std");

/// QUIC variable-length integer encoding (RFC 9000, Section 16)
/// Encodes integers in 1, 2, 4, or 8 bytes based on value.
pub const MAX_VARINT: u64 = 4611686018427387903;

pub const VarintError = error{
    ValueTooLarge,
    BufferTooSmall,
    InvalidEncoding,
    UnexpectedEof,
};

pub fn encodedLen(value: u64) u8 {
    if (value <= 63) return 1;
    if (value <= 16383) return 2;
    if (value <= 1073741823) return 4;
    if (value <= MAX_VARINT) return 8;
    return 0;
}

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
            std.mem.writeInt(u64, buf[0..8], value | 0xC000000000000000, .big);
            return 8;
        },
        else => unreachable,
    }
}

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

pub fn peek(buf: []const u8) VarintError!struct { value: u64, len: u8 } {
    return decode(buf);
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
}
