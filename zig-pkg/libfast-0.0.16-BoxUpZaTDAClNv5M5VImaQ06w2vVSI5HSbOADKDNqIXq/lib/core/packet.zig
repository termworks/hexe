const std = @import("std");
const types = @import("types.zig");
const varint = @import("../utils/varint.zig");

const ConnectionId = types.ConnectionId;
const PacketType = types.PacketType;
const PacketHeader = types.PacketHeader;
const PacketNumber = types.PacketNumber;

pub const PacketError = error{
    InvalidPacketType,
    InvalidVersion,
    FixedBitNotSet,
    ReservedBitsNotZero,
    BufferTooSmall,
    UnexpectedEof,
    InvalidPacketNumber,
    ConnectionIdTooLong,
} || varint.VarintError;

/// Packet number encoding/decoding
pub const PacketNumberUtil = struct {
    pub fn encodedLengthForPacketNumber(pn: PacketNumber) u8 {
        return if (pn <= 0xFF)
            1
        else if (pn <= 0xFFFF)
            2
        else if (pn <= 0xFFFFFF)
            3
        else
            4;
    }

    /// Encode packet number with truncation
    /// Only encodes the least significant bytes needed
    pub fn encode(pn: PacketNumber, largest_acked: PacketNumber, buf: []u8) PacketError!u8 {
        const pn_range = if (pn > largest_acked) pn - largest_acked else 0;

        // Determine number of bytes needed
        const num_bytes: u8 = if (pn_range < 0x80)
            1
        else if (pn_range < 0x8000)
            2
        else if (pn_range < 0x800000)
            3
        else
            4;

        if (buf.len < num_bytes) return error.BufferTooSmall;

        switch (num_bytes) {
            1 => {
                buf[0] = @intCast(pn & 0xFF);
                return 1;
            },
            2 => {
                std.mem.writeInt(u16, buf[0..2], @intCast(pn & 0xFFFF), .big);
                return 2;
            },
            3 => {
                buf[0] = @intCast((pn >> 16) & 0xFF);
                std.mem.writeInt(u16, buf[1..3], @intCast(pn & 0xFFFF), .big);
                return 3;
            },
            4 => {
                std.mem.writeInt(u32, buf[0..4], @intCast(pn & 0xFFFFFFFF), .big);
                return 4;
            },
            else => unreachable,
        }
    }

    /// Decode truncated packet number
    pub fn decode(truncated: []const u8, largest_acked: PacketNumber) PacketError!PacketNumber {
        if (truncated.len == 0 or truncated.len > 4) return error.InvalidPacketNumber;

        const truncated_pn: u64 = switch (truncated.len) {
            1 => truncated[0],
            2 => std.mem.readInt(u16, truncated[0..2], .big),
            3 => blk: {
                const high: u64 = truncated[0];
                const low = std.mem.readInt(u16, truncated[1..3], .big);
                break :blk (high << 16) | low;
            },
            4 => std.mem.readInt(u32, truncated[0..4], .big),
            else => unreachable,
        };

        // Reconstruct full packet number
        const pn_nbits: u6 = @intCast(truncated.len * 8);
        const pn_win: u64 = @as(u64, 1) << pn_nbits;
        const pn_hwin = pn_win / 2;
        const pn_mask = pn_win - 1;

        const expected_pn = largest_acked + 1;
        const candidate = (expected_pn & ~pn_mask) | truncated_pn;

        if (candidate + pn_hwin <= expected_pn) {
            return candidate + pn_win;
        } else if (candidate > expected_pn + pn_hwin and candidate >= pn_win) {
            return candidate - pn_win;
        }
        return candidate;
    }
};

fn writePacketNumberBytes(pn: PacketNumber, pn_len: u8, out: []u8) PacketError!void {
    if (pn_len < 1 or pn_len > 4) return error.InvalidPacketNumber;
    if (out.len < pn_len) return error.BufferTooSmall;

    var i: usize = 0;
    while (i < pn_len) : (i += 1) {
        const shift: u6 = @intCast((pn_len - 1 - i) * 8);
        out[i] = @intCast((pn >> shift) & 0xFF);
    }
}

fn readPacketNumberBytes(input: []const u8) PacketError!PacketNumber {
    if (input.len == 0 or input.len > 4) return error.InvalidPacketNumber;

    var pn: u64 = 0;
    for (input) |byte| {
        pn = (pn << 8) | byte;
    }
    return pn;
}

/// Long Header packet format (RFC 9000, Section 17.2)
pub const LongHeader = struct {
    packet_type: PacketType,
    version: u32,
    dest_conn_id: ConnectionId,
    src_conn_id: ConnectionId,
    token: []const u8, // For Initial packets
    payload_len: u64, // Length of packet number + payload
    packet_number: PacketNumber,

    /// Encode Long Header packet
    pub fn encode(self: LongHeader, buf: []u8) PacketError!usize {
        var pos: usize = 0;

        if (buf.len < 7) return error.BufferTooSmall; // Minimum size

        // First byte: packet type and fixed bit
        const type_bits: u8 = switch (self.packet_type) {
            .initial => 0b00,
            .zero_rtt => 0b01,
            .handshake => 0b10,
            .retry => 0b11,
            else => return error.InvalidPacketType,
        };

        // Long Header: 1xxx xxxx (first bit = 1, fixed bit = 1)
        // Format: 11TT xxPP where TT = type, PP = packet number length - 1
        const pn_len = PacketNumberUtil.encodedLengthForPacketNumber(self.packet_number);
        const first_byte = 0b11000000 | (type_bits << 4) | ((pn_len - 1) & 0x03);
        buf[pos] = first_byte; // We'll update packet number length later
        pos += 1;

        // Version (4 bytes)
        if (pos + 4 > buf.len) return error.BufferTooSmall;
        std.mem.writeInt(u32, buf[pos..][0..4], self.version, .big);
        pos += 4;

        // Destination Connection ID
        if (pos + 1 + self.dest_conn_id.len > buf.len) return error.BufferTooSmall;
        buf[pos] = self.dest_conn_id.len;
        pos += 1;
        @memcpy(buf[pos..][0..self.dest_conn_id.len], self.dest_conn_id.slice());
        pos += self.dest_conn_id.len;

        // Source Connection ID
        if (pos + 1 + self.src_conn_id.len > buf.len) return error.BufferTooSmall;
        buf[pos] = self.src_conn_id.len;
        pos += 1;
        @memcpy(buf[pos..][0..self.src_conn_id.len], self.src_conn_id.slice());
        pos += self.src_conn_id.len;

        // Token (for Initial and Retry packets)
        if (self.packet_type == .initial or self.packet_type == .retry) {
            const token_len = try varint.encode(self.token.len, buf[pos..]);
            pos += token_len;
            if (pos + self.token.len > buf.len) return error.BufferTooSmall;
            @memcpy(buf[pos..][0..self.token.len], self.token);
            pos += self.token.len;
        }

        // Payload length (includes packet number + payload)
        const payload_len_size = try varint.encode(self.payload_len, buf[pos..]);
        pos += payload_len_size;

        // Packet number (variable 1-4 bytes)
        if (pos + pn_len > buf.len) return error.BufferTooSmall;
        try writePacketNumberBytes(self.packet_number, pn_len, buf[pos..][0..pn_len]);
        pos += pn_len;

        return pos;
    }

    /// Decode Long Header packet
    pub fn decode(buf: []const u8) PacketError!struct { header: LongHeader, consumed: usize } {
        var pos: usize = 0;

        if (buf.len < 7) return error.UnexpectedEof;

        // First byte
        const first_byte = buf[pos];
        pos += 1;

        // Check long header bit
        if ((first_byte & 0x80) == 0) return error.InvalidPacketType;

        // Fixed bit MUST be set.
        if ((first_byte & 0x40) == 0) return error.FixedBitNotSet;

        // Extract packet type and packet number length
        const type_bits = (first_byte >> 4) & 0x03;
        const pn_len: u8 = @intCast((first_byte & 0x03) + 1);
        const packet_type: PacketType = switch (type_bits) {
            0b00 => .initial,
            0b01 => .zero_rtt,
            0b10 => .handshake,
            0b11 => .retry,
            else => unreachable,
        };

        // Reserved bits MUST be zero for non-Retry long header packets.
        if (packet_type != .retry and (first_byte & 0x0C) != 0) {
            return error.ReservedBitsNotZero;
        }

        // Version
        if (pos + 4 > buf.len) return error.UnexpectedEof;
        const version = std.mem.readInt(u32, buf[pos..][0..4], .big);
        pos += 4;

        // Destination Connection ID
        if (pos + 1 > buf.len) return error.UnexpectedEof;
        const dcid_len = buf[pos];
        pos += 1;
        if (pos + dcid_len > buf.len) return error.UnexpectedEof;
        const dest_conn_id = try ConnectionId.init(buf[pos..][0..dcid_len]);
        pos += dcid_len;

        // Source Connection ID
        if (pos + 1 > buf.len) return error.UnexpectedEof;
        const scid_len = buf[pos];
        pos += 1;
        if (pos + scid_len > buf.len) return error.UnexpectedEof;
        const src_conn_id = try ConnectionId.init(buf[pos..][0..scid_len]);
        pos += scid_len;

        // Token (for Initial and Retry packets)
        var token: []const u8 = &.{};
        if (packet_type == .initial or packet_type == .retry) {
            const token_len_result = try varint.decode(buf[pos..]);
            pos += token_len_result.len;
            const token_len = token_len_result.value;
            if (pos + token_len > buf.len) return error.UnexpectedEof;
            token = buf[pos..][0..token_len];
            pos += token_len;
        }

        // Payload length
        const payload_len_result = try varint.decode(buf[pos..]);
        pos += payload_len_result.len;
        const payload_len = payload_len_result.value;

        // Packet number (variable 1-4 bytes)
        if (pos + pn_len > buf.len) return error.UnexpectedEof;
        const packet_number = try readPacketNumberBytes(buf[pos..][0..pn_len]);
        pos += pn_len;

        const header = LongHeader{
            .packet_type = packet_type,
            .version = version,
            .dest_conn_id = dest_conn_id,
            .src_conn_id = src_conn_id,
            .token = token,
            .payload_len = payload_len,
            .packet_number = packet_number,
        };

        return .{ .header = header, .consumed = pos };
    }
};

/// Short Header packet format (RFC 9000, Section 17.3)
pub const ShortHeader = struct {
    dest_conn_id: ConnectionId,
    packet_number: PacketNumber,
    key_phase: bool,

    /// Encode Short Header packet
    pub fn encode(self: ShortHeader, buf: []u8) PacketError!usize {
        var pos: usize = 0;

        if (buf.len < 1 + self.dest_conn_id.len) return error.BufferTooSmall;

        // First byte: 0 (short header) | 1 (fixed bit) | S (spin bit) | R R (reserved) | K (key phase) | PP (pn length)
        const pn_len = PacketNumberUtil.encodedLengthForPacketNumber(self.packet_number);

        // 01000000 (fixed bit set) + packet number length bits
        var first_byte: u8 = 0b01000000;
        if (self.key_phase) {
            first_byte |= 0b00000100; // Set key phase bit
        }
        first_byte |= (pn_len - 1) & 0x03;
        buf[pos] = first_byte;
        pos += 1;

        // Destination Connection ID
        @memcpy(buf[pos..][0..self.dest_conn_id.len], self.dest_conn_id.slice());
        pos += self.dest_conn_id.len;

        // Packet number (variable 1-4 bytes)
        if (pos + pn_len > buf.len) return error.BufferTooSmall;
        try writePacketNumberBytes(self.packet_number, pn_len, buf[pos..][0..pn_len]);
        pos += pn_len;

        return pos;
    }

    /// Decode Short Header packet
    pub fn decode(buf: []const u8, dcid_len: u8) PacketError!struct { header: ShortHeader, consumed: usize } {
        var pos: usize = 0;

        if (buf.len < 1 + dcid_len) return error.UnexpectedEof;

        // First byte
        const first_byte = buf[pos];
        pos += 1;

        // Check short header bit
        if ((first_byte & 0x80) != 0) return error.InvalidPacketType;

        // Fixed bit MUST be set.
        if ((first_byte & 0x40) == 0) return error.FixedBitNotSet;

        // Reserved bits MUST be zero.
        if ((first_byte & 0x18) != 0) return error.ReservedBitsNotZero;

        // Extract key phase and packet number length bits
        const key_phase = (first_byte & 0x04) != 0;
        const pn_len: u8 = @intCast((first_byte & 0x03) + 1);

        // Destination Connection ID
        if (pos + dcid_len > buf.len) return error.UnexpectedEof;
        const dest_conn_id = try ConnectionId.init(buf[pos..][0..dcid_len]);
        pos += dcid_len;

        // Packet number (variable 1-4 bytes)
        if (pos + pn_len > buf.len) return error.UnexpectedEof;
        const packet_number = try readPacketNumberBytes(buf[pos..][0..pn_len]);
        pos += pn_len;

        const header = ShortHeader{
            .dest_conn_id = dest_conn_id,
            .packet_number = packet_number,
            .key_phase = key_phase,
        };

        return .{ .header = header, .consumed = pos };
    }
};

/// Version Negotiation packet format (RFC 9000, Section 17.2.1)
pub const VersionNegotiationPacket = struct {
    dest_conn_id: ConnectionId,
    src_conn_id: ConnectionId,
    supported_versions: []const u32,

    pub fn encode(self: VersionNegotiationPacket, buf: []u8) PacketError!usize {
        var pos: usize = 0;

        if (buf.len < 7) return error.BufferTooSmall;
        if (self.supported_versions.len == 0) return error.InvalidVersion;

        // Long header + fixed bit set, rest randomizable; keep deterministic for tests.
        buf[pos] = 0xC0;
        pos += 1;

        // Version Negotiation packets carry version 0.
        std.mem.writeInt(u32, buf[pos..][0..4], 0, .big);
        pos += 4;

        if (pos + 1 + self.dest_conn_id.len > buf.len) return error.BufferTooSmall;
        buf[pos] = self.dest_conn_id.len;
        pos += 1;
        @memcpy(buf[pos..][0..self.dest_conn_id.len], self.dest_conn_id.slice());
        pos += self.dest_conn_id.len;

        if (pos + 1 + self.src_conn_id.len > buf.len) return error.BufferTooSmall;
        buf[pos] = self.src_conn_id.len;
        pos += 1;
        @memcpy(buf[pos..][0..self.src_conn_id.len], self.src_conn_id.slice());
        pos += self.src_conn_id.len;

        if (pos + (self.supported_versions.len * 4) > buf.len) return error.BufferTooSmall;
        for (self.supported_versions) |version| {
            std.mem.writeInt(u32, buf[pos..][0..4], version, .big);
            pos += 4;
        }

        return pos;
    }

    pub fn decode(
        buf: []const u8,
        versions_out: []u32,
    ) PacketError!struct { packet: VersionNegotiationPacket, consumed: usize } {
        var pos: usize = 0;
        if (buf.len < 7) return error.UnexpectedEof;

        const first_byte = buf[pos];
        pos += 1;

        if ((first_byte & 0x80) == 0) return error.InvalidPacketType;
        if ((first_byte & 0x40) == 0) return error.FixedBitNotSet;

        const version = std.mem.readInt(u32, buf[pos..][0..4], .big);
        pos += 4;
        if (version != 0) return error.InvalidVersion;

        if (pos + 1 > buf.len) return error.UnexpectedEof;
        const dcid_len = buf[pos];
        pos += 1;
        if (pos + dcid_len > buf.len) return error.UnexpectedEof;
        const dest_conn_id = try ConnectionId.init(buf[pos..][0..dcid_len]);
        pos += dcid_len;

        if (pos + 1 > buf.len) return error.UnexpectedEof;
        const scid_len = buf[pos];
        pos += 1;
        if (pos + scid_len > buf.len) return error.UnexpectedEof;
        const src_conn_id = try ConnectionId.init(buf[pos..][0..scid_len]);
        pos += scid_len;

        const versions_bytes = buf[pos..];
        if (versions_bytes.len == 0 or (versions_bytes.len % 4) != 0) {
            return error.InvalidVersion;
        }

        const version_count = versions_bytes.len / 4;
        if (version_count > versions_out.len) return error.BufferTooSmall;

        var i: usize = 0;
        while (i < version_count) : (i += 1) {
            const off = i * 4;
            versions_out[i] = (@as(u32, versions_bytes[off]) << 24) |
                (@as(u32, versions_bytes[off + 1]) << 16) |
                (@as(u32, versions_bytes[off + 2]) << 8) |
                @as(u32, versions_bytes[off + 3]);
        }

        return .{
            .packet = .{
                .dest_conn_id = dest_conn_id,
                .src_conn_id = src_conn_id,
                .supported_versions = versions_out[0..version_count],
            },
            .consumed = buf.len,
        };
    }
};

// Tests

test "packet number encode/decode" {
    var buf: [4]u8 = undefined;

    // Test 1-byte encoding
    const len1 = try PacketNumberUtil.encode(100, 50, &buf);
    try std.testing.expectEqual(@as(u8, 1), len1);
    const decoded1 = try PacketNumberUtil.decode(buf[0..len1], 50);
    try std.testing.expectEqual(@as(u64, 100), decoded1);

    // Test 2-byte encoding
    const len2 = try PacketNumberUtil.encode(1000, 800, &buf);
    try std.testing.expectEqual(@as(u8, 2), len2);
    const decoded2 = try PacketNumberUtil.decode(buf[0..len2], 800);
    try std.testing.expectEqual(@as(u64, 1000), decoded2);

    try std.testing.expectEqual(@as(u8, 1), PacketNumberUtil.encodedLengthForPacketNumber(0x12));
    try std.testing.expectEqual(@as(u8, 2), PacketNumberUtil.encodedLengthForPacketNumber(0x1234));
    try std.testing.expectEqual(@as(u8, 3), PacketNumberUtil.encodedLengthForPacketNumber(0x123456));
    try std.testing.expectEqual(@as(u8, 4), PacketNumberUtil.encodedLengthForPacketNumber(0x12345678));
}

test "long header initial packet encode/decode" {
    const allocator = std.testing.allocator;
    var buf = try allocator.alloc(u8, 1024);
    defer allocator.free(buf);

    const dcid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const scid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    const header = LongHeader{
        .packet_type = .initial,
        .version = types.QUIC_VERSION_1,
        .dest_conn_id = dcid,
        .src_conn_id = scid,
        .token = &.{},
        .payload_len = 100,
        .packet_number = 42,
    };

    const encoded_len = try header.encode(buf);
    try std.testing.expect(encoded_len > 0);

    const result = try LongHeader.decode(buf[0..encoded_len]);
    try std.testing.expectEqual(PacketType.initial, result.header.packet_type);
    try std.testing.expectEqual(types.QUIC_VERSION_1, result.header.version);
    try std.testing.expect(result.header.dest_conn_id.eql(&dcid));
    try std.testing.expect(result.header.src_conn_id.eql(&scid));
    try std.testing.expectEqual(@as(u64, 42), result.header.packet_number);
}

test "long header retry packet encodes and decodes token" {
    var buf: [256]u8 = undefined;

    const dcid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const scid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    const header = LongHeader{
        .packet_type = .retry,
        .version = types.QUIC_VERSION_1,
        .dest_conn_id = dcid,
        .src_conn_id = scid,
        .token = "retry-token",
        .payload_len = 1,
        .packet_number = 7,
    };

    const encoded_len = try header.encode(&buf);
    const result = try LongHeader.decode(buf[0..encoded_len]);

    try std.testing.expectEqual(PacketType.retry, result.header.packet_type);
    try std.testing.expectEqualStrings("retry-token", result.header.token);
}

test "short header packet encode/decode" {
    var buf: [100]u8 = undefined;

    const dcid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });

    const header = ShortHeader{
        .dest_conn_id = dcid,
        .packet_number = 0x123456,
        .key_phase = true,
    };

    const encoded_len = try header.encode(&buf);
    try std.testing.expect(encoded_len > 0);

    const result = try ShortHeader.decode(buf[0..encoded_len], dcid.len);
    try std.testing.expect(result.header.dest_conn_id.eql(&dcid));
    try std.testing.expectEqual(@as(u64, 0x123456), result.header.packet_number);
    try std.testing.expectEqual(true, result.header.key_phase);

    // short header first byte encodes packet number length in low bits
    try std.testing.expectEqual(@as(u8, 0b00000010), buf[0] & 0x03);
}

test "long header packet number length bits" {
    var buf: [128]u8 = undefined;

    const dcid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const scid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    const header = LongHeader{
        .packet_type = .initial,
        .version = types.QUIC_VERSION_1,
        .dest_conn_id = dcid,
        .src_conn_id = scid,
        .token = &.{},
        .payload_len = 10,
        .packet_number = 0xAB,
    };

    const encoded_len = try header.encode(&buf);
    try std.testing.expect(encoded_len > 0);

    // low bits hold packet number length minus 1, so for 1-byte PN => 0
    try std.testing.expectEqual(@as(u8, 0), buf[0] & 0x03);

    const result = try LongHeader.decode(buf[0..encoded_len]);
    try std.testing.expectEqual(@as(u64, 0xAB), result.header.packet_number);
}

test "packet decode malformed corpus" {
    try std.testing.expectError(error.UnexpectedEof, LongHeader.decode(&[_]u8{}));
    try std.testing.expectError(error.UnexpectedEof, LongHeader.decode(&[_]u8{ 0xC0, 0x00, 0x00 }));
    try std.testing.expectError(error.InvalidPacketType, LongHeader.decode(&[_]u8{ 0x40, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00 }));

    try std.testing.expectError(error.UnexpectedEof, ShortHeader.decode(&[_]u8{0x40}, 8));
    try std.testing.expectError(error.UnexpectedEof, ShortHeader.decode(&[_]u8{ 0x41, 0xAA }, 8));
}

test "long header decode rejects unset fixed bit" {
    const dcid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const scid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var buf: [128]u8 = undefined;
    const header = LongHeader{
        .packet_type = .initial,
        .version = types.QUIC_VERSION_1,
        .dest_conn_id = dcid,
        .src_conn_id = scid,
        .token = &.{},
        .payload_len = 1,
        .packet_number = 1,
    };
    const len = try header.encode(&buf);
    buf[0] &= 0xBF; // clear fixed bit

    try std.testing.expectError(error.FixedBitNotSet, LongHeader.decode(buf[0..len]));
}

test "short header decode rejects reserved bits" {
    const dcid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });

    var buf: [64]u8 = undefined;
    const header = ShortHeader{
        .dest_conn_id = dcid,
        .packet_number = 1,
        .key_phase = false,
    };
    const len = try header.encode(&buf);
    buf[0] |= 0x18; // set reserved bits

    try std.testing.expectError(error.ReservedBitsNotZero, ShortHeader.decode(buf[0..len], dcid.len));
}

test "version negotiation packet encode/decode" {
    var buf: [128]u8 = undefined;

    const dcid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const scid = try ConnectionId.init(&[_]u8{ 9, 8, 7, 6 });

    const packet = VersionNegotiationPacket{
        .dest_conn_id = dcid,
        .src_conn_id = scid,
        .supported_versions = &[_]u32{ 0x00000002, types.QUIC_VERSION_1 },
    };

    const len = try packet.encode(&buf);
    var versions: [4]u32 = undefined;
    const decoded = try VersionNegotiationPacket.decode(buf[0..len], &versions);

    try std.testing.expect(decoded.packet.dest_conn_id.eql(&dcid));
    try std.testing.expect(decoded.packet.src_conn_id.eql(&scid));
    try std.testing.expectEqual(@as(usize, 2), decoded.packet.supported_versions.len);
    try std.testing.expectEqual(@as(u32, 0x00000002), decoded.packet.supported_versions[0]);
    try std.testing.expectEqual(@as(u32, types.QUIC_VERSION_1), decoded.packet.supported_versions[1]);
}

test "packet number decode reconstruction window edges" {
    // 1-byte truncated decode: candidate is too low, so decoder lifts to next window.
    const lifted = try PacketNumberUtil.decode(&[_]u8{0x00}, 0x2FE);
    try std.testing.expectEqual(@as(u64, 0x300), lifted);

    // 1-byte truncated decode: candidate is too high, so decoder drops to previous window.
    const lowered = try PacketNumberUtil.decode(&[_]u8{0xFF}, 0x200);
    try std.testing.expectEqual(@as(u64, 0x1FF), lowered);

    // Mid-window candidate should remain unchanged.
    const stable = try PacketNumberUtil.decode(&[_]u8{0x21}, 0x200);
    try std.testing.expectEqual(@as(u64, 0x221), stable);
}

test "packet number decode lsquic compatibility vectors" {
    const vectors = [_]struct {
        truncated: []const u8,
        largest_acked: u64,
        expected: u64,
    }{
        // Derived from LSQUIC test_packno_len restore vectors (least_unacked=2).
        .{ .truncated = &[_]u8{0x41}, .largest_acked = 1, .expected = 65 },
        .{ .truncated = &[_]u8{0x02}, .largest_acked = 0, .expected = 2 },
        .{ .truncated = &[_]u8{ 0x3F, 0xFF }, .largest_acked = 1, .expected = 64 * 256 - 1 },
        .{ .truncated = &[_]u8{ 0x00, 0x3F, 0xFF, 0xFF }, .largest_acked = 1, .expected = 64 * 256 * 256 - 1 },
        .{ .truncated = &[_]u8{ 0x00, 0x01 }, .largest_acked = (1 << 16) - 1, .expected = (1 << 16) + 1 },
        .{ .truncated = &[_]u8{ 0x00, 0x00, 0x00, 0x01 }, .largest_acked = (1 << 33) - 1, .expected = (1 << 33) + 1 },

        // Additional restore case where high bits come from the expected window.
        .{ .truncated = &[_]u8{ 0x27, 0x11 }, .largest_acked = 9_999, .expected = 10_001 },
    };

    for (vectors) |vector| {
        const decoded = try PacketNumberUtil.decode(vector.truncated, vector.largest_acked);
        try std.testing.expectEqual(vector.expected, decoded);
    }
}

test "long header decode rejects reserved bits for non-retry" {
    const dcid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const scid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var buf: [128]u8 = undefined;
    const header = LongHeader{
        .packet_type = .initial,
        .version = types.QUIC_VERSION_1,
        .dest_conn_id = dcid,
        .src_conn_id = scid,
        .token = &.{},
        .payload_len = 1,
        .packet_number = 1,
    };
    const len = try header.encode(&buf);
    buf[0] |= 0x0C; // set reserved bits

    try std.testing.expectError(error.ReservedBitsNotZero, LongHeader.decode(buf[0..len]));
}

test "long header retry decode tolerates reserved bits" {
    const dcid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const scid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var buf: [128]u8 = undefined;
    const header = LongHeader{
        .packet_type = .retry,
        .version = types.QUIC_VERSION_1,
        .dest_conn_id = dcid,
        .src_conn_id = scid,
        .token = "r",
        .payload_len = 1,
        .packet_number = 1,
    };
    const len = try header.encode(&buf);
    buf[0] |= 0x0C; // reserved bits set

    const decoded = try LongHeader.decode(buf[0..len]);
    try std.testing.expectEqual(PacketType.retry, decoded.header.packet_type);
}

test "short header decode rejects unset fixed bit" {
    const dcid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });

    var buf: [64]u8 = undefined;
    const header = ShortHeader{
        .dest_conn_id = dcid,
        .packet_number = 7,
        .key_phase = false,
    };
    const len = try header.encode(&buf);
    buf[0] &= 0xBF; // clear fixed bit

    try std.testing.expectError(error.FixedBitNotSet, ShortHeader.decode(buf[0..len], dcid.len));
}

test "version negotiation decode rejects invalid wire forms" {
    const dcid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const scid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var buf: [128]u8 = undefined;
    const vn = VersionNegotiationPacket{
        .dest_conn_id = dcid,
        .src_conn_id = scid,
        .supported_versions = &[_]u32{ 0x00000002, 0x00000003 },
    };

    const len = try vn.encode(&buf);

    // Fixed bit cleared.
    var fixed_off = buf;
    fixed_off[0] &= 0xBF;
    var versions: [4]u32 = undefined;
    try std.testing.expectError(error.FixedBitNotSet, VersionNegotiationPacket.decode(fixed_off[0..len], &versions));

    // Non-zero version field.
    var wrong_version = buf;
    std.mem.writeInt(u32, wrong_version[1..5], types.QUIC_VERSION_1, .big);
    try std.testing.expectError(error.InvalidVersion, VersionNegotiationPacket.decode(wrong_version[0..len], &versions));

    // Output buffer too small for advertised version list.
    var small_versions: [1]u32 = undefined;
    try std.testing.expectError(error.BufferTooSmall, VersionNegotiationPacket.decode(buf[0..len], &small_versions));
}

test "long header decode rejects oversized CID lengths" {
    const dcid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const scid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var buf: [256]u8 = undefined;
    const header = LongHeader{
        .packet_type = .initial,
        .version = types.QUIC_VERSION_1,
        .dest_conn_id = dcid,
        .src_conn_id = scid,
        .token = &.{},
        .payload_len = 1,
        .packet_number = 7,
    };
    const len = try header.encode(&buf);

    // Oversized DCID length (> 20).
    var bad_dcid = [_]u8{0} ** 256;
    @memcpy(bad_dcid[0..len], buf[0..len]);
    bad_dcid[5] = 21;
    try std.testing.expectError(error.ConnectionIdTooLong, LongHeader.decode(bad_dcid[0..64]));

    // Oversized SCID length (> 20). Keep DCID valid.
    var bad_scid = [_]u8{0} ** 256;
    @memcpy(bad_scid[0..len], buf[0..len]);
    bad_scid[5] = 4;
    bad_scid[10] = 21;
    try std.testing.expectError(error.ConnectionIdTooLong, LongHeader.decode(bad_scid[0..64]));
}

test "long header decode lsquic-style truncation corpus" {
    const dcid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    const scid = try ConnectionId.init(&[_]u8{ 9, 10, 11, 12 });

    var buf: [256]u8 = undefined;
    const header = LongHeader{
        .packet_type = .initial,
        .version = types.QUIC_VERSION_1,
        .dest_conn_id = dcid,
        .src_conn_id = scid,
        .token = "retry-token",
        .payload_len = 4,
        .packet_number = 0x1234,
    };
    const len = try header.encode(&buf);

    var cut: usize = 0;
    while (cut < len) : (cut += 1) {
        try std.testing.expectError(error.UnexpectedEof, LongHeader.decode(buf[0..cut]));
    }

    const decoded = try LongHeader.decode(buf[0..len]);
    try std.testing.expectEqual(PacketType.initial, decoded.header.packet_type);
    try std.testing.expectEqual(@as(u32, types.QUIC_VERSION_1), decoded.header.version);
    try std.testing.expect(decoded.header.dest_conn_id.eql(&dcid));
    try std.testing.expect(decoded.header.src_conn_id.eql(&scid));
    try std.testing.expectEqualStrings("retry-token", decoded.header.token);
    try std.testing.expectEqual(@as(u64, 4), decoded.header.payload_len);
    try std.testing.expectEqual(@as(u64, 0x1234), decoded.header.packet_number);
}

test "short header decode rejects oversized CID length hint" {
    var buf: [64]u8 = [_]u8{0} ** 64;
    buf[0] = 0x40; // short header + fixed bit + pn_len=1
    buf[22] = 0x01; // packet number byte after 21-byte DCID

    // Provide a decode DCID length greater than QUIC maximum with enough bytes.
    try std.testing.expectError(error.ConnectionIdTooLong, ShortHeader.decode(buf[0..23], 21));
}

test "short header decode lsquic-style truncation corpus" {
    const dcid = try ConnectionId.init(&[_]u8{ 1, 3, 5, 7, 9, 11, 13, 15 });

    var buf: [128]u8 = undefined;
    const header = ShortHeader{
        .dest_conn_id = dcid,
        .packet_number = 0x123456,
        .key_phase = true,
    };
    const len = try header.encode(&buf);

    var cut: usize = 0;
    while (cut < len) : (cut += 1) {
        try std.testing.expectError(error.UnexpectedEof, ShortHeader.decode(buf[0..cut], dcid.len));
    }

    const decoded = try ShortHeader.decode(buf[0..len], dcid.len);
    try std.testing.expect(decoded.header.dest_conn_id.eql(&dcid));
    try std.testing.expect(decoded.header.key_phase);
    try std.testing.expectEqual(@as(u64, 0x123456), decoded.header.packet_number);
}

test "version negotiation decode rejects oversized CID lengths" {
    var buf: [128]u8 = undefined;

    // VN header: long + fixed, version=0.
    buf[0] = 0xC0;
    std.mem.writeInt(u32, buf[1..5], 0, .big);

    // Oversized DCID length triggers ConnectionIdTooLong from ConnectionId.init.
    buf[5] = 21;
    @memset(buf[6..27], 0xAA);
    buf[27] = 4;
    @memcpy(buf[28..32], &[_]u8{ 1, 2, 3, 4 });
    std.mem.writeInt(u32, buf[32..36], 0x00000001, .big);

    var versions: [4]u32 = undefined;
    try std.testing.expectError(error.ConnectionIdTooLong, VersionNegotiationPacket.decode(buf[0..36], &versions));

    // Keep DCID valid and make SCID oversized.
    buf[5] = 4;
    @memcpy(buf[6..10], &[_]u8{ 5, 6, 7, 8 });
    buf[10] = 21;
    @memset(buf[11..32], 0xBB);
    std.mem.writeInt(u32, buf[32..36], 0x00000001, .big);
    try std.testing.expectError(error.ConnectionIdTooLong, VersionNegotiationPacket.decode(buf[0..36], &versions));
}

test "version negotiation decode accepts randomized low header bits" {
    const dcid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const scid = try ConnectionId.init(&[_]u8{ 9, 8, 7, 6 });

    var buf: [128]u8 = undefined;
    const vn = VersionNegotiationPacket{
        .dest_conn_id = dcid,
        .src_conn_id = scid,
        .supported_versions = &[_]u32{ 0x00000002, 0x00000003, types.QUIC_VERSION_1 },
    };

    const len = try vn.encode(&buf);
    // LSQUIC-style VN tests randomize the low header bits. RFC requires only
    // long-header and fixed-bit for VN packets.
    buf[0] = 0xFF;

    var versions: [8]u32 = undefined;
    const decoded = try VersionNegotiationPacket.decode(buf[0..len], &versions);
    try std.testing.expect(decoded.packet.dest_conn_id.eql(&dcid));
    try std.testing.expect(decoded.packet.src_conn_id.eql(&scid));
    try std.testing.expectEqual(@as(usize, 3), decoded.packet.supported_versions.len);
    try std.testing.expectEqual(@as(u32, 0x00000002), decoded.packet.supported_versions[0]);
    try std.testing.expectEqual(@as(u32, 0x00000003), decoded.packet.supported_versions[1]);
    try std.testing.expectEqual(types.QUIC_VERSION_1, decoded.packet.supported_versions[2]);
}

test "packet decode fuzz smoke" {
    var prng = std.Random.DefaultPrng.init(0xBAD5EED);
    const rand = prng.random();

    var buf: [96]u8 = undefined;
    var i: usize = 0;
    while (i < 1500) : (i += 1) {
        rand.bytes(&buf);
        const len: usize = rand.intRangeAtMost(usize, 1, buf.len);
        const sample = buf[0..len];

        if ((sample[0] & 0x80) != 0) {
            _ = LongHeader.decode(sample) catch continue;
        } else {
            _ = ShortHeader.decode(sample, 8) catch continue;
        }
    }
}
