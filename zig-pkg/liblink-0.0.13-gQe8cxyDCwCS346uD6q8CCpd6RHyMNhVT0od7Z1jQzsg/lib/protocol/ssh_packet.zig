const std = @import("std");
const Allocator = std.mem.Allocator;
const wire = @import("wire.zig");

/// SSH/QUIC packet format per SPEC.md Section 6.1
///
/// Format: uint32(payload-len) || byte[](payload)
/// - High bit of payload-len indicates compression
/// - No MAC or random padding (QUIC-TLS provides security)

/// Compression flag in payload-len high bit
pub const compression_flag: u32 = 0x80000000;

/// SSH/QUIC packet structure
pub const SshPacket = struct {
    payload: []const u8,
    compressed: bool,

    /// Free the payload memory
    pub fn deinit(self: *SshPacket, allocator: Allocator) void {
        allocator.free(self.payload);
    }

    /// Encode SSH packet to wire format
    ///
    /// Format: uint32(len | compression_flag) || payload
    pub fn encode(self: *const SshPacket, allocator: Allocator) ![]u8 {
        const size = 4 + self.payload.len;
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };

        // Write payload length with compression flag if needed
        if (self.payload.len > std.math.maxInt(u32)) return error.PayloadTooLarge;
        var payload_len: u32 = @intCast(self.payload.len);
        if (self.compressed) {
            payload_len |= compression_flag;
        }
        try writer.writeUint32(payload_len);

        // Write payload
        @memcpy(buffer[4..], self.payload);

        return buffer;
    }

    /// Decode SSH packet from wire format
    pub fn decode(allocator: Allocator, data: []const u8) !SshPacket {
        if (data.len < 4) {
            return error.PacketTooSmall;
        }

        var reader = wire.Reader{ .buffer = data };

        // Read payload length and compression flag
        const payload_len_with_flag = try reader.readUint32();
        const compressed = (payload_len_with_flag & compression_flag) != 0;
        const payload_len = payload_len_with_flag & ~compression_flag;

        // Verify we have enough data
        if (data.len < 4 + payload_len) {
            return error.InsufficientData;
        }

        // Copy payload
        const payload = try allocator.alloc(u8, payload_len);
        errdefer allocator.free(payload);
        @memcpy(payload, data[4..][0..payload_len]);

        return SshPacket{
            .payload = payload,
            .compressed = compressed,
        };
    }
};

/// Packet sequence number per stream (Section 6.3)
pub const PacketSequence = struct {
    stream_id: u64,
    sequence_number: u32,

    /// Initialize sequence for a stream
    pub fn init(stream_id: u64) PacketSequence {
        return .{
            .stream_id = stream_id,
            .sequence_number = 0,
        };
    }

    /// Get next sequence number
    pub fn next(self: *PacketSequence) u32 {
        const current = self.sequence_number;
        self.sequence_number += 1;
        return current;
    }
};

/// SSH_MSG_UNIMPLEMENTED for SSH/QUIC (modified format per Section 6.3)
pub const UnimplementedMsg = struct {
    stream_id: u64,
    packet_sequence: u32,

    /// Encode SSH_MSG_UNIMPLEMENTED
    pub fn encode(self: *const UnimplementedMsg, allocator: Allocator) ![]u8 {
        const size = 1 + 8 + 4; // msg_type + stream_id + sequence
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };
        try writer.writeByte(3); // SSH_MSG_UNIMPLEMENTED
        try writer.writeUint64(self.stream_id);
        try writer.writeUint32(self.packet_sequence);

        return buffer;
    }

    /// Decode SSH_MSG_UNIMPLEMENTED
    pub fn decode(data: []const u8) !UnimplementedMsg {
        var reader = wire.Reader{ .buffer = data };

        const msg_type = try reader.readByte();
        if (msg_type != 3) {
            return error.InvalidMessageType;
        }

        const stream_id = try reader.readUint64();
        const packet_sequence = try reader.readUint32();

        return UnimplementedMsg{
            .stream_id = stream_id,
            .packet_sequence = packet_sequence,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SshPacket - encode uncompressed" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const payload = "test payload data";
    const packet = SshPacket{
        .payload = payload,
        .compressed = false,
    };

    const encoded = try packet.encode(allocator);
    defer allocator.free(encoded);

    // Should be 4 bytes length + payload
    try testing.expectEqual(@as(usize, 4 + payload.len), encoded.len);

    // Check payload length (first 4 bytes, no compression flag)
    const len = std.mem.readInt(u32, encoded[0..4], .big);
    try testing.expectEqual(@as(u32, payload.len), len);
    try testing.expectEqual(@as(u32, 0), len & compression_flag);
}

test "SshPacket - encode compressed" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const payload = "compressed payload";
    const packet = SshPacket{
        .payload = payload,
        .compressed = true,
    };

    const encoded = try packet.encode(allocator);
    defer allocator.free(encoded);

    // Check compression flag is set
    const len_with_flag = std.mem.readInt(u32, encoded[0..4], .big);
    try testing.expect((len_with_flag & compression_flag) != 0);

    // Check actual length
    const len = len_with_flag & ~compression_flag;
    try testing.expectEqual(@as(u32, payload.len), len);
}

test "SshPacket - encode and decode uncompressed" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const payload = "test message";
    const packet = SshPacket{
        .payload = payload,
        .compressed = false,
    };

    // Encode
    const encoded = try packet.encode(allocator);
    defer allocator.free(encoded);

    // Decode
    var decoded = try SshPacket.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    // Verify
    try testing.expectEqualStrings(payload, decoded.payload);
    try testing.expectEqual(false, decoded.compressed);
}

test "SshPacket - encode and decode compressed" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const payload = "compressed data here";
    const packet = SshPacket{
        .payload = payload,
        .compressed = true,
    };

    // Encode
    const encoded = try packet.encode(allocator);
    defer allocator.free(encoded);

    // Decode
    var decoded = try SshPacket.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    // Verify
    try testing.expectEqualStrings(payload, decoded.payload);
    try testing.expectEqual(true, decoded.compressed);
}

test "SshPacket - decode too small" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const small_data = [_]u8{ 0, 0, 0 }; // Only 3 bytes
    const result = SshPacket.decode(allocator, &small_data);

    try testing.expectError(error.PacketTooSmall, result);
}

test "SshPacket - decode insufficient data" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Says it has 100 bytes but only provides 10
    var data: [14]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 100, .big);
    @memset(data[4..], 0);

    const result = SshPacket.decode(allocator, &data);
    try testing.expectError(error.InsufficientData, result);
}

test "SshPacket - empty payload" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const packet = SshPacket{
        .payload = "",
        .compressed = false,
    };

    const encoded = try packet.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try SshPacket.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), decoded.payload.len);
}

test "PacketSequence - initialization" {
    const testing = std.testing;

    const seq = PacketSequence.init(42);
    try testing.expectEqual(@as(u64, 42), seq.stream_id);
    try testing.expectEqual(@as(u32, 0), seq.sequence_number);
}

test "PacketSequence - increment" {
    const testing = std.testing;

    var seq = PacketSequence.init(0);

    try testing.expectEqual(@as(u32, 0), seq.next());
    try testing.expectEqual(@as(u32, 1), seq.next());
    try testing.expectEqual(@as(u32, 2), seq.next());
}

test "UnimplementedMsg - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const msg = UnimplementedMsg{
        .stream_id = 12345,
        .packet_sequence = 67,
    };

    const encoded = try msg.encode(allocator);
    defer allocator.free(encoded);

    const decoded = try UnimplementedMsg.decode(encoded);

    try testing.expectEqual(msg.stream_id, decoded.stream_id);
    try testing.expectEqual(msg.packet_sequence, decoded.packet_sequence);
}

test "UnimplementedMsg - structure" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const msg = UnimplementedMsg{
        .stream_id = 999,
        .packet_sequence = 42,
    };

    const encoded = try msg.encode(allocator);
    defer allocator.free(encoded);

    // Should be 13 bytes: 1 (msg type) + 8 (stream id) + 4 (sequence)
    try testing.expectEqual(@as(usize, 13), encoded.len);

    // First byte should be 3 (SSH_MSG_UNIMPLEMENTED)
    try testing.expectEqual(@as(u8, 3), encoded[0]);
}
