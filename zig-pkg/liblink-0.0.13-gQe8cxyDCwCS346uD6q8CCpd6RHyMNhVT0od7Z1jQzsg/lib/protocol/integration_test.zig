const std = @import("std");
const ssh_packet = @import("ssh_packet.zig");
const quic_streams = @import("quic_streams.zig");
const channel = @import("channel.zig");
const constants = @import("../common/constants.zig");

// Integration tests for SSH/QUIC packet format and streaming.
// These tests verify that the protocol components work together correctly.

test "integration - channel open packet on correct stream" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a channel open message
    const ch_open = channel.ChannelOpen{
        .channel_type = "session",
        .type_specific_data = "",
    };

    // Encode the message
    const payload = try ch_open.encode(allocator);
    defer allocator.free(payload);

    // Wrap in SSH packet
    const packet = ssh_packet.SshPacket{
        .payload = payload,
        .compressed = false,
    };

    // Encode the packet
    const encoded_packet = try packet.encode(allocator);
    defer allocator.free(encoded_packet);

    // Verify this is a channel packet (not global)
    try testing.expect(quic_streams.isChannelPacket(constants.SSH_MSG.CHANNEL_OPEN));
    try testing.expect(!quic_streams.isGlobalPacket(constants.SSH_MSG.CHANNEL_OPEN));

    // Should be sent on a non-zero stream (4, 5, 8, 9, etc.)
    const stream_id: u64 = 4; // Client-initiated bidirectional
    try quic_streams.validateStreamId(stream_id);
    try quic_streams.validatePacketForStream(stream_id, constants.SSH_MSG.CHANNEL_OPEN);
}

test "integration - userauth on global stream" {
    const testing = std.testing;

    // Verify userauth packets are global
    try testing.expect(quic_streams.isGlobalPacket(constants.SSH_MSG.USERAUTH_REQUEST));
    try testing.expect(!quic_streams.isChannelPacket(constants.SSH_MSG.USERAUTH_REQUEST));

    // Should be sent on stream 0
    try quic_streams.validatePacketForStream(0, constants.SSH_MSG.USERAUTH_REQUEST);

    // Should NOT be sent on channel streams
    try testing.expectError(
        error.InvalidPacketForChannelStream,
        quic_streams.validatePacketForStream(4, constants.SSH_MSG.USERAUTH_REQUEST),
    );
}

test "integration - packet sequence per stream" {
    const testing = std.testing;

    // Different streams have independent sequences
    var seq_stream0 = ssh_packet.PacketSequence.init(0);
    var seq_stream4 = ssh_packet.PacketSequence.init(4);

    // Both start at 0
    try testing.expectEqual(@as(u32, 0), seq_stream0.next());
    try testing.expectEqual(@as(u32, 0), seq_stream4.next());

    // Sequences are independent
    try testing.expectEqual(@as(u32, 1), seq_stream0.next());
    try testing.expectEqual(@as(u32, 2), seq_stream0.next());
    try testing.expectEqual(@as(u32, 1), seq_stream4.next());

    // Verify stream 0 is now at 3, stream 4 is at 2
    try testing.expectEqual(@as(u32, 3), seq_stream0.sequence_number);
    try testing.expectEqual(@as(u32, 2), seq_stream4.sequence_number);
}

test "integration - prohibited packets rejected" {
    const testing = std.testing;

    // DISCONNECT is prohibited
    try testing.expect(quic_streams.isProhibited(constants.SSH_MSG.DISCONNECT));
    try testing.expectError(
        error.ProhibitedPacketType,
        quic_streams.validatePacketForStream(0, constants.SSH_MSG.DISCONNECT),
    );

    // KEXINIT is prohibited (SSH/QUIC uses different kex)
    try testing.expect(quic_streams.isProhibited(constants.SSH_MSG.KEXINIT));

    // CHANNEL_CLOSE is prohibited (use QUIC stream FIN)
    try testing.expect(quic_streams.isProhibited(constants.SSH_MSG.CHANNEL_CLOSE));

    // CHANNEL_WINDOW_ADJUST is prohibited (QUIC flow control)
    try testing.expect(quic_streams.isProhibited(constants.SSH_MSG.CHANNEL_WINDOW_ADJUST));
}

test "integration - channel data flow" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const stream_id: u64 = 4;

    // Create channel
    var ch = try channel.Channel.init(allocator, stream_id, "session");
    defer ch.deinit();

    // Initially in opening state
    try testing.expect(!ch.isOpen());

    // Simulate channel opening
    ch.state = .open;
    try testing.expect(ch.isOpen());
    try testing.expect(!ch.isEof());

    // Send data packet
    const data_msg = channel.ChannelData{
        .data = "test data",
    };

    const data_payload = try data_msg.encode(allocator);
    defer allocator.free(data_payload);

    // Validate packet for stream
    try quic_streams.validatePacketForStream(stream_id, constants.SSH_MSG.CHANNEL_DATA);

    // Receive EOF
    ch.state = .eof_received;
    try testing.expect(ch.isEof());
    try testing.expect(!ch.isOpen());
}

test "integration - compressed packet handling" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a compressed packet
    const payload = "compressed_data_here";
    const packet = ssh_packet.SshPacket{
        .payload = payload,
        .compressed = true,
    };

    // Encode
    const encoded = try packet.encode(allocator);
    defer allocator.free(encoded);

    // Verify compression flag is set in wire format
    const payload_len_with_flag = std.mem.readInt(u32, encoded[0..4], .big);
    try testing.expect((payload_len_with_flag & ssh_packet.compression_flag) != 0);

    // Decode
    var decoded = try ssh_packet.SshPacket.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    // Verify compression flag preserved
    try testing.expect(decoded.compressed);
    try testing.expectEqualStrings(payload, decoded.payload);
}

test "integration - bidirectional stream validation" {
    const testing = std.testing;

    // Stream 0 is always valid (global)
    try quic_streams.validateStreamId(0);

    // Client bidirectional: LSB = 00
    try quic_streams.validateStreamId(4); // 0b0100
    try quic_streams.validateStreamId(8); // 0b1000
    try testing.expect(quic_streams.isClientInitiated(4));

    // Server bidirectional: LSB = 01
    try quic_streams.validateStreamId(5); // 0b0101
    try quic_streams.validateStreamId(9); // 0b1001
    try testing.expect(quic_streams.isServerInitiated(5));

    // Unidirectional streams rejected
    try testing.expectError(
        error.UnidirectionalStreamNotAllowed,
        quic_streams.validateStreamId(2), // 0b0010
    );
    try testing.expectError(
        error.UnidirectionalStreamNotAllowed,
        quic_streams.validateStreamId(3), // 0b0011
    );
}

test "integration - channel request and reply flow" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const stream_id: u64 = 4;

    // Create channel
    var ch = try channel.Channel.init(allocator, stream_id, "session");
    defer ch.deinit();
    ch.state = .open;

    // Send channel request
    const request = channel.ChannelRequest{
        .request_type = "shell",
        .want_reply = true,
        .type_specific_data = "",
    };

    const request_payload = try request.encode(allocator);
    defer allocator.free(request_payload);

    // Validate request packet
    try quic_streams.validatePacketForStream(stream_id, constants.SSH_MSG.CHANNEL_REQUEST);

    // Receive success reply
    const success_payload = try channel.ChannelSuccess.encode(allocator);
    defer allocator.free(success_payload);

    // Validate success packet
    try quic_streams.validatePacketForStream(stream_id, constants.SSH_MSG.CHANNEL_SUCCESS);
}

test "integration - unimplemented message with stream context" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const stream_id: u64 = 4;
    const sequence: u32 = 42;

    // Create unimplemented message
    const msg = ssh_packet.UnimplementedMsg{
        .stream_id = stream_id,
        .packet_sequence = sequence,
    };

    // Encode
    const payload = try msg.encode(allocator);
    defer allocator.free(payload);

    // Wrap in SSH packet
    const packet = ssh_packet.SshPacket{
        .payload = payload,
        .compressed = false,
    };

    const encoded = try packet.encode(allocator);
    defer allocator.free(encoded);

    // Decode packet
    var decoded_packet = try ssh_packet.SshPacket.decode(allocator, encoded);
    defer decoded_packet.deinit(allocator);

    // Decode unimplemented message
    const decoded_msg = try ssh_packet.UnimplementedMsg.decode(decoded_packet.payload);

    // Verify stream and sequence preserved
    try testing.expectEqual(stream_id, decoded_msg.stream_id);
    try testing.expectEqual(sequence, decoded_msg.packet_sequence);
}
