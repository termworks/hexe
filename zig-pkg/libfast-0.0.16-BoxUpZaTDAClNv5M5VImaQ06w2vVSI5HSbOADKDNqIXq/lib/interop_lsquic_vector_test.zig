const std = @import("std");

const varint = @import("utils/varint.zig");
const packet_mod = @import("core/packet.zig");
const frame_mod = @import("core/frame.zig");
const core_types = @import("core/types.zig");

test "interop lsquic varint vectors" {
    const vectors = [_]struct {
        encoded: []const u8,
        value: u64,
    }{
        .{ .encoded = &[_]u8{0x25}, .value = 0x25 },
        .{ .encoded = &[_]u8{ 0x40, 0x25 }, .value = 0x25 },
        .{ .encoded = &[_]u8{ 0x9D, 0x7F, 0x3E, 0x7D }, .value = 494878333 },
        .{ .encoded = &[_]u8{ 0xC2, 0x19, 0x7C, 0x5E, 0xFF, 0x14, 0xE8, 0x8C }, .value = 151288809941952652 },
    };

    for (vectors) |vector| {
        const decoded = try varint.decode(vector.encoded);
        try std.testing.expectEqual(vector.value, decoded.value);
        try std.testing.expectEqual(@as(u8, @intCast(vector.encoded.len)), decoded.len);
    }
}

test "interop lsquic varint incomplete-read vectors" {
    // Mirrors incomplete input behavior from xtra/lsquic/tests/test_varint.c.
    try std.testing.expectError(error.UnexpectedEof, varint.decode(&[_]u8{}));
    try std.testing.expectError(error.UnexpectedEof, varint.decode(&[_]u8{0x40}));
    try std.testing.expectError(error.UnexpectedEof, varint.decode(&[_]u8{ 0x9D, 0x7F }));
    try std.testing.expectError(error.UnexpectedEof, varint.decode(&[_]u8{ 0xC2, 0x19, 0x7C, 0x5E, 0xFF, 0x14, 0xE8 }));
}

test "interop lsquic version negotiation low-bit tolerance" {
    const dcid = try core_types.ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const scid = try core_types.ConnectionId.init(&[_]u8{ 9, 8, 7, 6 });

    var buf: [128]u8 = undefined;
    const vn = packet_mod.VersionNegotiationPacket{
        .dest_conn_id = dcid,
        .src_conn_id = scid,
        .supported_versions = &[_]u32{ 0x00000002, 0x00000003, core_types.QUIC_VERSION_1 },
    };

    const len = try vn.encode(&buf);
    buf[0] = 0xFF;

    var versions: [8]u32 = undefined;
    const decoded = try packet_mod.VersionNegotiationPacket.decode(buf[0..len], &versions);
    try std.testing.expectEqual(@as(usize, 3), decoded.packet.supported_versions.len);
    try std.testing.expectEqual(@as(u32, 0x00000002), decoded.packet.supported_versions[0]);
    try std.testing.expectEqual(@as(u32, 0x00000003), decoded.packet.supported_versions[1]);
    try std.testing.expectEqual(core_types.QUIC_VERSION_1, decoded.packet.supported_versions[2]);
}

test "interop lsquic version negotiation malformed vectors" {
    const dcid = try core_types.ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const scid = try core_types.ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var buf: [128]u8 = undefined;
    const vn = packet_mod.VersionNegotiationPacket{
        .dest_conn_id = dcid,
        .src_conn_id = scid,
        .supported_versions = &[_]u32{ 0x00000002, 0x00000003 },
    };
    const len = try vn.encode(&buf);

    var versions: [4]u32 = undefined;

    // Fixed bit cleared.
    var fixed_off = buf;
    fixed_off[0] &= 0xBF;
    try std.testing.expectError(error.FixedBitNotSet, packet_mod.VersionNegotiationPacket.decode(fixed_off[0..len], &versions));

    // Non-zero version marker.
    var wrong_version = buf;
    std.mem.writeInt(u32, wrong_version[1..5], core_types.QUIC_VERSION_1, .big);
    try std.testing.expectError(error.InvalidVersion, packet_mod.VersionNegotiationPacket.decode(wrong_version[0..len], &versions));

    // Version list not aligned to 4-byte entries.
    var malformed_list: [36]u8 = undefined;
    malformed_list[0] = 0xC0;
    std.mem.writeInt(u32, malformed_list[1..5], 0, .big);
    malformed_list[5] = 4;
    @memcpy(malformed_list[6..10], &[_]u8{ 1, 2, 3, 4 });
    malformed_list[10] = 4;
    @memcpy(malformed_list[11..15], &[_]u8{ 5, 6, 7, 8 });
    malformed_list[15] = 0;
    malformed_list[16] = 0;
    malformed_list[17] = 2;
    try std.testing.expectError(error.InvalidVersion, packet_mod.VersionNegotiationPacket.decode(malformed_list[0..18], &versions));

    // Oversized DCID length.
    var oversized_cid: [64]u8 = undefined;
    oversized_cid[0] = 0xC0;
    std.mem.writeInt(u32, oversized_cid[1..5], 0, .big);
    oversized_cid[5] = 21;
    @memset(oversized_cid[6..27], 0xAA);
    oversized_cid[27] = 4;
    @memcpy(oversized_cid[28..32], &[_]u8{ 9, 9, 9, 9 });
    std.mem.writeInt(u32, oversized_cid[32..36], 0x00000001, .big);
    try std.testing.expectError(error.ConnectionIdTooLong, packet_mod.VersionNegotiationPacket.decode(oversized_cid[0..36], &versions));
}

test "interop lsquic packet number reconstruction vectors" {
    const vectors = [_]struct {
        truncated: []const u8,
        largest_acked: u64,
        expected: u64,
    }{
        .{ .truncated = &[_]u8{0x41}, .largest_acked = 1, .expected = 65 },
        .{ .truncated = &[_]u8{0x02}, .largest_acked = 0, .expected = 2 },
        .{ .truncated = &[_]u8{ 0x3F, 0xFF }, .largest_acked = 1, .expected = 64 * 256 - 1 },
        .{ .truncated = &[_]u8{ 0x00, 0x3F, 0xFF, 0xFF }, .largest_acked = 1, .expected = 64 * 256 * 256 - 1 },
        .{ .truncated = &[_]u8{ 0x00, 0x01 }, .largest_acked = (1 << 16) - 1, .expected = (1 << 16) + 1 },
    };

    for (vectors) |vector| {
        const decoded = try packet_mod.PacketNumberUtil.decode(vector.truncated, vector.largest_acked);
        try std.testing.expectEqual(vector.expected, decoded);
    }
}

test "interop lsquic ack sparse range vectors" {
    var ranges_in: [256]frame_mod.AckFrame.AckRange = undefined;
    for (&ranges_in) |*range| {
        range.* = .{
            .gap = 8,
            .ack_range_length = 0,
        };
    }

    const frame = frame_mod.AckFrame{
        .largest_acked = 3_000,
        .ack_delay = 0,
        .first_ack_range = 0,
        .ack_ranges = ranges_in[0..],
        .ecn_counts = null,
    };

    var buf: [4096]u8 = undefined;
    const len = try frame.encode(&buf);

    var ranges_out: [256]frame_mod.AckFrame.AckRange = undefined;
    const decoded = try frame_mod.AckFrame.decodeWithAckRanges(buf[0..len], &ranges_out);
    try std.testing.expectEqual(@as(usize, 256), decoded.frame.ack_ranges.len);
}

test "interop lsquic ack 256-range capacity and overflow" {
    var ranges_in: [256]frame_mod.AckFrame.AckRange = undefined;
    for (ranges_in[0..], 0..) |*range, i| {
        range.* = .{
            .gap = @as(u64, @intCast(i % 2)),
            .ack_range_length = @as(u64, @intCast(i % 3)),
        };
    }

    const frame = frame_mod.AckFrame{
        .largest_acked = 5_000,
        .ack_delay = 0,
        .first_ack_range = 200,
        .ack_ranges = ranges_in[0..],
        .ecn_counts = null,
    };

    var buf: [4096]u8 = undefined;
    const len = try frame.encode(&buf);

    var ok_out: [256]frame_mod.AckFrame.AckRange = undefined;
    const decoded = try frame_mod.AckFrame.decodeWithAckRanges(buf[0..len], &ok_out);
    try std.testing.expectEqual(@as(usize, 256), decoded.frame.ack_ranges.len);

    var small_out: [255]frame_mod.AckFrame.AckRange = undefined;
    try std.testing.expectError(error.BufferTooSmall, frame_mod.AckFrame.decodeWithAckRanges(buf[0..len], &small_out));
}

test "interop lsquic ack truncation matrix" {
    var ranges_buf: [256]u8 = undefined;
    const ranges_frame = frame_mod.AckFrame{
        .largest_acked = 600,
        .ack_delay = 3,
        .first_ack_range = 5,
        .ack_ranges = &[_]frame_mod.AckFrame.AckRange{
            .{ .gap = 1, .ack_range_length = 2 },
            .{ .gap = 3, .ack_range_length = 4 },
        },
        .ecn_counts = null,
    };
    const ranges_len = try ranges_frame.encode(&ranges_buf);

    var ack_ranges: [8]frame_mod.AckFrame.AckRange = undefined;
    var cut: usize = 1;
    while (cut < ranges_len) : (cut += 1) {
        try std.testing.expectError(error.UnexpectedEof, frame_mod.AckFrame.decodeWithAckRanges(ranges_buf[0..cut], &ack_ranges));
    }

    var ecn_buf: [128]u8 = undefined;
    const ecn_frame = frame_mod.AckFrame{
        .largest_acked = 9,
        .ack_delay = 1,
        .first_ack_range = 0,
        .ack_ranges = &.{},
        .ecn_counts = frame_mod.AckFrame.EcnCounts{
            .ect0_count = 1,
            .ect1_count = 2,
            .ecn_ce_count = 3,
        },
    };
    const ecn_len = try ecn_frame.encode(&ecn_buf);

    var no_ecn_buf: [128]u8 = undefined;
    const no_ecn_frame = frame_mod.AckFrame{
        .largest_acked = 9,
        .ack_delay = 1,
        .first_ack_range = 0,
        .ack_ranges = &.{},
        .ecn_counts = null,
    };
    const no_ecn_len = try no_ecn_frame.encode(&no_ecn_buf);

    cut = no_ecn_len;
    while (cut < ecn_len) : (cut += 1) {
        try std.testing.expectError(error.UnexpectedEof, frame_mod.AckFrame.decode(ecn_buf[0..cut]));
    }
}

test "interop lsquic long-header truncation matrix" {
    const dcid = try core_types.ConnectionId.init(&[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    const scid = try core_types.ConnectionId.init(&[_]u8{ 9, 10, 11, 12 });

    var buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .initial,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = dcid,
        .src_conn_id = scid,
        .token = "retry-token",
        .payload_len = 4,
        .packet_number = 0x1234,
    };

    const len = try header.encode(&buf);
    var cut: usize = 0;
    while (cut < len) : (cut += 1) {
        try std.testing.expectError(error.UnexpectedEof, packet_mod.LongHeader.decode(buf[0..cut]));
    }
}

test "interop lsquic short-header truncation matrix" {
    const dcid = try core_types.ConnectionId.init(&[_]u8{ 1, 3, 5, 7, 9, 11, 13, 15 });

    var buf: [128]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = dcid,
        .packet_number = 0x123456,
        .key_phase = true,
    };

    const len = try header.encode(&buf);
    var cut: usize = 0;
    while (cut < len) : (cut += 1) {
        try std.testing.expectError(error.UnexpectedEof, packet_mod.ShortHeader.decode(buf[0..cut], dcid.len));
    }
}

test "interop lsquic-style short header generation vectors" {
    const dcid = try core_types.ConnectionId.init(&[_]u8{ 0x08, 0x07, 0x06, 0x05 });

    const vectors = [_]struct {
        packet_number: u64,
        key_phase: bool,
        expected: []const u8,
    }{
        .{
            .packet_number = 0x00,
            .key_phase = false,
            .expected = &[_]u8{ 0x40, 0x08, 0x07, 0x06, 0x05, 0x00 },
        },
        .{
            .packet_number = 0x09,
            .key_phase = true,
            .expected = &[_]u8{ 0x44, 0x08, 0x07, 0x06, 0x05, 0x09 },
        },
        .{
            .packet_number = 0x1234,
            .key_phase = false,
            .expected = &[_]u8{ 0x41, 0x08, 0x07, 0x06, 0x05, 0x12, 0x34 },
        },
        .{
            .packet_number = 0x01020304,
            .key_phase = false,
            .expected = &[_]u8{ 0x43, 0x08, 0x07, 0x06, 0x05, 0x01, 0x02, 0x03, 0x04 },
        },
    };

    for (vectors) |vector| {
        var buf: [64]u8 = undefined;
        const header = packet_mod.ShortHeader{
            .dest_conn_id = dcid,
            .packet_number = vector.packet_number,
            .key_phase = vector.key_phase,
        };
        const len = try header.encode(&buf);
        try std.testing.expectEqual(vector.expected.len, len);
        try std.testing.expectEqualSlices(u8, vector.expected, buf[0..len]);
    }
}

test "interop lsquic-style long header generation vectors" {
    const dcid = try core_types.ConnectionId.init(&[_]u8{ 0x01, 0x02, 0x03, 0x04 });
    const scid = try core_types.ConnectionId.init(&[_]u8{ 0x05, 0x06, 0x07, 0x08 });

    const vectors = [_]struct {
        packet_number: u64,
        expected: []const u8,
    }{
        .{
            .packet_number = 0x09,
            .expected = &[_]u8{
                0xC0,
                0x00,
                0x00,
                0x00,
                0x01,
                0x04,
                0x01,
                0x02,
                0x03,
                0x04,
                0x04,
                0x05,
                0x06,
                0x07,
                0x08,
                0x00,
                0x04,
                0x09,
            },
        },
        .{
            .packet_number = 0x1234,
            .expected = &[_]u8{
                0xC1,
                0x00,
                0x00,
                0x00,
                0x01,
                0x04,
                0x01,
                0x02,
                0x03,
                0x04,
                0x04,
                0x05,
                0x06,
                0x07,
                0x08,
                0x00,
                0x04,
                0x12,
                0x34,
            },
        },
        .{
            .packet_number = 0x01020304,
            .expected = &[_]u8{
                0xC3,
                0x00,
                0x00,
                0x00,
                0x01,
                0x04,
                0x01,
                0x02,
                0x03,
                0x04,
                0x04,
                0x05,
                0x06,
                0x07,
                0x08,
                0x00,
                0x04,
                0x01,
                0x02,
                0x03,
                0x04,
            },
        },
    };

    for (vectors) |vector| {
        var buf: [96]u8 = undefined;
        const header = packet_mod.LongHeader{
            .packet_type = .initial,
            .version = core_types.QUIC_VERSION_1,
            .dest_conn_id = dcid,
            .src_conn_id = scid,
            .token = &.{},
            .payload_len = 4,
            .packet_number = vector.packet_number,
        };
        const len = try header.encode(&buf);
        try std.testing.expectEqual(vector.expected.len, len);
        try std.testing.expectEqualSlices(u8, vector.expected, buf[0..len]);
    }
}

test "interop lsquic control-frame truncation matrix" {
    var token_buf: [128]u8 = undefined;
    const token = frame_mod.NewTokenFrame{ .token = "token-material-123" };
    const token_len = try token.encode(&token_buf);

    var cut: usize = 0;
    while (cut < token_len) : (cut += 1) {
        try std.testing.expectError(error.UnexpectedEof, frame_mod.NewTokenFrame.decode(token_buf[0..cut]));
    }

    var close_buf: [128]u8 = undefined;
    const close = frame_mod.ConnectionCloseFrame{
        .error_code = 42,
        .frame_type = 0x10,
        .reason = "transport-close",
    };
    const close_len = try close.encode(&close_buf);

    cut = 0;
    while (cut < close_len) : (cut += 1) {
        try std.testing.expectError(error.UnexpectedEof, frame_mod.ConnectionCloseFrame.decode(close_buf[0..cut]));
    }
}

test "interop lsquic-style stream frame generation vectors" {
    const vectors = [_]struct {
        frame: frame_mod.StreamFrame,
        expected: []const u8,
    }{
        .{
            .frame = .{ .stream_id = 0, .offset = 0, .data = "A", .fin = false },
            .expected = &[_]u8{ 0x0A, 0x00, 0x01, 0x41 },
        },
        .{
            .frame = .{ .stream_id = 3, .offset = 0, .data = "BC", .fin = true },
            .expected = &[_]u8{ 0x0B, 0x03, 0x02, 0x42, 0x43 },
        },
        .{
            .frame = .{ .stream_id = 1, .offset = 5, .data = "xy", .fin = false },
            .expected = &[_]u8{ 0x0E, 0x01, 0x05, 0x02, 0x78, 0x79 },
        },
        .{
            .frame = .{ .stream_id = 64, .offset = 0, .data = "zz", .fin = true },
            .expected = &[_]u8{ 0x0B, 0x40, 0x40, 0x02, 0x7A, 0x7A },
        },
        .{
            .frame = .{ .stream_id = 2, .offset = 0x1234, .data = "Q", .fin = false },
            .expected = &[_]u8{ 0x0E, 0x02, 0x52, 0x34, 0x01, 0x51 },
        },
    };

    for (vectors) |vector| {
        var buf: [128]u8 = undefined;
        const len = try vector.frame.encode(&buf);
        try std.testing.expectEqual(vector.expected.len, len);
        try std.testing.expectEqualSlices(u8, vector.expected, buf[0..len]);

        const decoded = try frame_mod.StreamFrame.decode(buf[0..len]);
        try std.testing.expectEqual(vector.frame.stream_id, decoded.frame.stream_id);
        try std.testing.expectEqual(vector.frame.offset, decoded.frame.offset);
        try std.testing.expectEqual(vector.frame.fin, decoded.frame.fin);
        try std.testing.expectEqualSlices(u8, vector.frame.data, decoded.frame.data);
    }
}

test "interop lsquic-style packet buffer capacity ladder short header" {
    const dcid = try core_types.ConnectionId.init(&[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    const header = packet_mod.ShortHeader{
        .dest_conn_id = dcid,
        .packet_number = 0x01020304,
        .key_phase = true,
    };

    var full_buf: [128]u8 = undefined;
    const expected_len = try header.encode(&full_buf);

    var cap: usize = 0;
    while (cap < expected_len) : (cap += 1) {
        var small: [128]u8 = undefined;
        try std.testing.expectError(error.BufferTooSmall, header.encode(small[0..cap]));
    }

    var exact: [128]u8 = undefined;
    const exact_len = try header.encode(exact[0..expected_len]);
    try std.testing.expectEqual(expected_len, exact_len);

    const decoded = try packet_mod.ShortHeader.decode(exact[0..exact_len], dcid.len);
    try std.testing.expect(decoded.header.dest_conn_id.eql(&dcid));
    try std.testing.expectEqual(@as(u64, 0x01020304), decoded.header.packet_number);
    try std.testing.expect(decoded.header.key_phase);
}

test "interop lsquic-style packet buffer capacity ladder long header" {
    const dcid = try core_types.ConnectionId.init(&[_]u8{ 1, 3, 5, 7, 9, 11, 13, 15 });
    const scid = try core_types.ConnectionId.init(&[_]u8{ 2, 4, 6, 8 });
    const header = packet_mod.LongHeader{
        .packet_type = .initial,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = dcid,
        .src_conn_id = scid,
        .token = "tok",
        .payload_len = 4,
        .packet_number = 0x1234,
    };

    var full_buf: [256]u8 = undefined;
    const expected_len = try header.encode(&full_buf);

    var cap: usize = 0;
    while (cap < expected_len) : (cap += 1) {
        var small: [256]u8 = undefined;
        try std.testing.expectError(error.BufferTooSmall, header.encode(small[0..cap]));
    }

    var exact: [256]u8 = undefined;
    const exact_len = try header.encode(exact[0..expected_len]);
    try std.testing.expectEqual(expected_len, exact_len);

    const decoded = try packet_mod.LongHeader.decode(exact[0..exact_len]);
    try std.testing.expect(decoded.header.packet_type == .initial);
    try std.testing.expect(decoded.header.dest_conn_id.eql(&dcid));
    try std.testing.expect(decoded.header.src_conn_id.eql(&scid));
    try std.testing.expectEqualStrings("tok", decoded.header.token);
    try std.testing.expectEqual(@as(u64, 0x1234), decoded.header.packet_number);
}

test "interop lsquic-style packet bookkeeping vectors" {
    const dcid = try core_types.ConnectionId.init(&[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    const scid = try core_types.ConnectionId.init(&[_]u8{ 9, 10, 11, 12 });

    const long_vectors = [_]struct {
        payload_len: u64,
        packet_number: u64,
        expected_decoded_packet_number: u64,
        token: []const u8,
    }{
        .{ .payload_len = 1, .packet_number = 0x01, .expected_decoded_packet_number = 0x01, .token = &.{} },
        .{ .payload_len = 63, .packet_number = 0x1234, .expected_decoded_packet_number = 0x1234, .token = "t" },
        .{ .payload_len = 64, .packet_number = 0x01020304, .expected_decoded_packet_number = 0x01020304, .token = "tok" },
        // Long-header packet number wire length is max 4 bytes; high bits are not carried.
        .{ .payload_len = 4096, .packet_number = 0x0102030405060708, .expected_decoded_packet_number = 0x05060708, .token = "retry-token" },
    };

    for (long_vectors) |vector| {
        var buf: [256]u8 = undefined;
        const header = packet_mod.LongHeader{
            .packet_type = .initial,
            .version = core_types.QUIC_VERSION_1,
            .dest_conn_id = dcid,
            .src_conn_id = scid,
            .token = vector.token,
            .payload_len = vector.payload_len,
            .packet_number = vector.packet_number,
        };

        const len = try header.encode(&buf);
        const decoded = try packet_mod.LongHeader.decode(buf[0..len]);
        try std.testing.expectEqual(len, decoded.consumed);
        try std.testing.expect(decoded.header.dest_conn_id.eql(&dcid));
        try std.testing.expect(decoded.header.src_conn_id.eql(&scid));
        try std.testing.expectEqual(vector.payload_len, decoded.header.payload_len);
        try std.testing.expectEqual(vector.expected_decoded_packet_number, decoded.header.packet_number);
        try std.testing.expectEqualSlices(u8, vector.token, decoded.header.token);
    }

    const short_vectors = [_]struct {
        packet_number: u64,
        key_phase: bool,
    }{
        .{ .packet_number = 0x01, .key_phase = false },
        .{ .packet_number = 0x1234, .key_phase = true },
        .{ .packet_number = 0x01020304, .key_phase = false },
    };

    for (short_vectors) |vector| {
        var buf: [128]u8 = undefined;
        const header = packet_mod.ShortHeader{
            .dest_conn_id = dcid,
            .packet_number = vector.packet_number,
            .key_phase = vector.key_phase,
        };

        const len = try header.encode(&buf);
        const decoded = try packet_mod.ShortHeader.decode(buf[0..len], dcid.len);
        try std.testing.expectEqual(len, decoded.consumed);
        try std.testing.expect(decoded.header.dest_conn_id.eql(&dcid));
        try std.testing.expectEqual(vector.packet_number, decoded.header.packet_number);
        try std.testing.expectEqual(vector.key_phase, decoded.header.key_phase);
    }
}
