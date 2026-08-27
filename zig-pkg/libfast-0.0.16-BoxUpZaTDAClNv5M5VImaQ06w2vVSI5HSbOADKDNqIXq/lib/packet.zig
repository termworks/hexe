const std = @import("std");

/// QUIC Packet Format
///
/// For SSH/QUIC, we primarily use Short Header packets (1-RTT packets).
/// The SSH key exchange happens over UDP before QUIC, so we skip
/// Initial/Handshake packets.

/// QUIC Short Header (1-RTT Packet)
///
/// Format:
/// +-+-+-+-+-+-+-+-+
/// |0|1|S|R|R|K|P P|
/// +-+-+-+-+-+-+-+-+
/// | Dest Conn ID  |
/// +---------------+
/// | Packet Number |
/// +---------------+
/// |   Payload     |
/// +---------------+
///
/// Bits:
/// - 0: Header Form (0 = Short Header)
/// - 1: Fixed Bit (always 1)
/// - S: Spin Bit (for latency measurement)
/// - RR: Reserved (must be 0)
/// - K: Key Phase (for key rotation)
/// - PP: Packet Number Length (00=1, 01=2, 10=3, 11=4 bytes)
pub const ShortHeader = struct {
    /// Destination Connection ID (negotiated during key exchange)
    destination_conn_id: []const u8,

    /// Packet number (monotonically increasing)
    packet_number: u32,

    /// Spin bit (for passive latency measurement)
    spin_bit: bool = false,

    /// Key phase (for key rotation - not used in SSH/QUIC initially)
    key_phase: bool = false,

    /// Encode short header into buffer
    ///
    /// Returns number of bytes written
    pub fn encode(self: ShortHeader, buffer: []u8) !usize {
        if (buffer.len < 1 + self.destination_conn_id.len + 4) {
            return error.BufferTooSmall;
        }

        var offset: usize = 0;

        // Determine packet number length (1-4 bytes)
        const pn_length = packetNumberLength(self.packet_number);

        // First byte: flags
        // 0 (header form) | 1 (fixed) | spin | 00 (reserved) | key_phase | pn_length
        var flags: u8 = 0b01000000; // Header form=0, Fixed=1
        if (self.spin_bit) flags |= 0b00100000;
        if (self.key_phase) flags |= 0b00000100;
        flags |= (pn_length - 1) & 0b00000011; // Encode length as 0-3

        buffer[offset] = flags;
        offset += 1;

        // Destination Connection ID
        @memcpy(buffer[offset .. offset + self.destination_conn_id.len], self.destination_conn_id);
        offset += self.destination_conn_id.len;

        // Packet Number (variable length, big-endian)
        encodePacketNumber(self.packet_number, pn_length, buffer[offset .. offset + pn_length]);
        offset += pn_length;

        return offset;
    }

    /// Decode short header from buffer
    ///
    /// Returns tuple: (header, bytes_consumed)
    pub fn decode(buffer: []const u8, conn_id_len: usize) !struct { header: ShortHeader, consumed: usize } {
        if (buffer.len < 1) return error.BufferTooSmall;

        var offset: usize = 0;

        // Parse flags
        const flags = buffer[offset];
        offset += 1;

        // Verify header form (must be 0 for Short Header)
        if ((flags & 0b10000000) != 0) return error.NotShortHeader;

        // Verify fixed bit (must be 1)
        if ((flags & 0b01000000) == 0) return error.InvalidFixedBit;

        const spin_bit = (flags & 0b00100000) != 0;
        const key_phase = (flags & 0b00000100) != 0;
        const pn_length = ((flags & 0b00000011) + 1);

        // Destination Connection ID
        if (offset + conn_id_len > buffer.len) return error.BufferTooSmall;
        const destination_conn_id = buffer[offset .. offset + conn_id_len];
        offset += conn_id_len;

        // Packet Number
        if (offset + pn_length > buffer.len) return error.BufferTooSmall;
        const packet_number = decodePacketNumber(buffer[offset .. offset + pn_length]);
        offset += pn_length;

        return .{
            .header = ShortHeader{
                .destination_conn_id = destination_conn_id,
                .packet_number = packet_number,
                .spin_bit = spin_bit,
                .key_phase = key_phase,
            },
            .consumed = offset,
        };
    }
};

/// Determine minimum bytes needed to encode packet number
fn packetNumberLength(pn: u32) u8 {
    if (pn <= 0xFF) return 1;
    if (pn <= 0xFFFF) return 2;
    if (pn <= 0xFFFFFF) return 3;
    return 4;
}

/// Encode packet number in big-endian with variable length
fn encodePacketNumber(pn: u32, length: u8, buffer: []u8) void {
    switch (length) {
        1 => buffer[0] = @intCast(pn),
        2 => std.mem.writeInt(u16, buffer[0..2], @intCast(pn), .big),
        3 => {
            buffer[0] = @intCast((pn >> 16) & 0xFF);
            std.mem.writeInt(u16, buffer[1..3], @intCast(pn & 0xFFFF), .big);
        },
        4 => std.mem.writeInt(u32, buffer[0..4], pn, .big),
        else => unreachable,
    }
}

/// Decode packet number from big-endian variable length
fn decodePacketNumber(buffer: []const u8) u32 {
    return switch (buffer.len) {
        1 => buffer[0],
        2 => std.mem.readInt(u16, buffer[0..2], .big),
        3 => (@as(u32, buffer[0]) << 16) | std.mem.readInt(u16, buffer[1..3], .big),
        4 => std.mem.readInt(u32, buffer[0..4], .big),
        else => unreachable,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "ShortHeader - encode and decode" {
    const testing = std.testing;

    const conn_id = "test-conn";
    const header = ShortHeader{
        .destination_conn_id = conn_id,
        .packet_number = 42,
        .spin_bit = true,
        .key_phase = false,
    };

    // Encode
    var buffer: [256]u8 = undefined;
    const encoded_len = try header.encode(&buffer);

    // Decode
    const result = try ShortHeader.decode(buffer[0..encoded_len], conn_id.len);

    // Verify
    try testing.expectEqual(header.packet_number, result.header.packet_number);
    try testing.expectEqual(header.spin_bit, result.header.spin_bit);
    try testing.expectEqual(header.key_phase, result.header.key_phase);
    try testing.expectEqualSlices(u8, conn_id, result.header.destination_conn_id);
    try testing.expectEqual(encoded_len, result.consumed);
}

test "ShortHeader - packet number lengths" {
    const testing = std.testing;
    const conn_id = "test";

    // Test different packet number sizes
    const test_cases = [_]struct { pn: u32, expected_len: u8 }{
        .{ .pn = 0, .expected_len = 1 },
        .{ .pn = 255, .expected_len = 1 },
        .{ .pn = 256, .expected_len = 2 },
        .{ .pn = 65535, .expected_len = 2 },
        .{ .pn = 65536, .expected_len = 3 },
        .{ .pn = 16777215, .expected_len = 3 },
        .{ .pn = 16777216, .expected_len = 4 },
    };

    for (test_cases) |tc| {
        const header = ShortHeader{
            .destination_conn_id = conn_id,
            .packet_number = tc.pn,
        };

        var buffer: [256]u8 = undefined;
        const encoded_len = try header.encode(&buffer);

        // Decode and verify
        const result = try ShortHeader.decode(buffer[0..encoded_len], conn_id.len);
        try testing.expectEqual(tc.pn, result.header.packet_number);
    }
}

test "packetNumberLength" {
    const testing = std.testing;

    try testing.expectEqual(@as(u8, 1), packetNumberLength(0));
    try testing.expectEqual(@as(u8, 1), packetNumberLength(255));
    try testing.expectEqual(@as(u8, 2), packetNumberLength(256));
    try testing.expectEqual(@as(u8, 2), packetNumberLength(65535));
    try testing.expectEqual(@as(u8, 3), packetNumberLength(65536));
    try testing.expectEqual(@as(u8, 3), packetNumberLength(16777215));
    try testing.expectEqual(@as(u8, 4), packetNumberLength(16777216));
}
