const std = @import("std");
const constants = @import("../common/constants.zig");

/// QUIC stream management for SSH/QUIC per SPEC.md Section 6.2 and 6.8
///
/// SSH/QUIC uses QUIC streams to replace SSH channels:
/// - Stream 0: Global SSH packets (auth, service requests, etc.)
/// - Bidirectional streams: SSH channels (one stream = one channel)
/// - No SSH-level flow control (QUIC handles it)

/// Global stream ID (always 0)
pub const global_stream: u64 = 0;

/// Check if a stream ID is bidirectional
///
/// Bidirectional streams have least significant bits 00 (client) or 01 (server)
/// Unidirectional streams have least significant bits 10 or 11 (MUST NOT use in SSH/QUIC)
pub fn isBidirectional(stream_id: u64) bool {
    return (stream_id & 0b10) == 0;
}

/// Check if a stream was opened by the client
pub fn isClientInitiated(stream_id: u64) bool {
    return (stream_id & 0b01) == 0;
}

/// Check if a stream was opened by the server
pub fn isServerInitiated(stream_id: u64) bool {
    return (stream_id & 0b01) == 1;
}

/// Validate stream ID for SSH/QUIC usage
pub fn validateStreamId(stream_id: u64) !void {
    // Stream 0 is always valid (global stream)
    if (stream_id == 0) {
        return;
    }

    // Must be bidirectional
    if (!isBidirectional(stream_id)) {
        return error.UnidirectionalStreamNotAllowed;
    }
}

/// Check if a packet type is allowed on global stream (stream 0)
pub fn isGlobalPacket(packet_type: u8) bool {
    return switch (packet_type) {
        // Transport layer generic
        constants.SSH_MSG.IGNORE,
        constants.SSH_MSG.UNIMPLEMENTED,
        constants.SSH_MSG.DEBUG,
        constants.SSH_MSG.SERVICE_REQUEST,
        constants.SSH_MSG.SERVICE_ACCEPT,
        constants.SSH_MSG.EXT_INFO,
        // User authentication
        constants.SSH_MSG.USERAUTH_REQUEST,
        constants.SSH_MSG.USERAUTH_FAILURE,
        constants.SSH_MSG.USERAUTH_SUCCESS,
        constants.SSH_MSG.USERAUTH_BANNER,
        constants.SSH_MSG.USERAUTH_INFO_REQUEST,
        constants.SSH_MSG.USERAUTH_INFO_RESPONSE,
        // Global requests
        constants.SSH_MSG.GLOBAL_REQUEST,
        constants.SSH_MSG.REQUEST_SUCCESS,
        constants.SSH_MSG.REQUEST_FAILURE,
        => true,
        else => false,
    };
}

/// Check if a packet type is allowed on channel streams (non-zero streams)
pub fn isChannelPacket(packet_type: u8) bool {
    return switch (packet_type) {
        constants.SSH_MSG.CHANNEL_OPEN,
        constants.SSH_MSG.CHANNEL_OPEN_CONFIRMATION,
        constants.SSH_MSG.CHANNEL_OPEN_FAILURE,
        constants.SSH_MSG.CHANNEL_DATA,
        constants.SSH_MSG.CHANNEL_EXTENDED_DATA,
        constants.SSH_MSG.CHANNEL_EOF,
        constants.SSH_MSG.CHANNEL_REQUEST,
        constants.SSH_MSG.CHANNEL_SUCCESS,
        constants.SSH_MSG.CHANNEL_FAILURE,
        => true,
        else => false,
    };
}

/// Check if a packet type is prohibited in SSH/QUIC
pub fn isProhibited(packet_type: u8) bool {
    return switch (packet_type) {
        // Replaced by QUIC CONNECTION_CLOSE
        constants.SSH_MSG.DISCONNECT,
        // Not used (compression flag in packet length instead)
        8, // SSH_MSG_NEWCOMPRESS
        // Replaced by SSH/QUIC key exchange
        constants.SSH_MSG.KEXINIT,
        constants.SSH_MSG.NEWKEYS,
        // Key exchange messages (30-49) prohibited
        30, 31, 32, 33, 34, 35, 36, 37, 38, 39,
        40, 41, 42, 43, 44, 45, 46, 47, 48, 49,
        // Flow control handled by QUIC
        constants.SSH_MSG.CHANNEL_WINDOW_ADJUST,
        // Channel close handled by QUIC stream close
        constants.SSH_MSG.CHANNEL_CLOSE,
        => true,
        else => false,
    };
}

/// Validate packet type for a given stream
pub fn validatePacketForStream(stream_id: u64, packet_type: u8) !void {
    // Check if packet is prohibited
    if (isProhibited(packet_type)) {
        return error.ProhibitedPacketType;
    }

    if (stream_id == global_stream) {
        // Global stream: only global packets allowed
        if (!isGlobalPacket(packet_type)) {
            return error.InvalidPacketForGlobalStream;
        }
    } else {
        // Channel stream: only channel packets allowed
        if (!isChannelPacket(packet_type)) {
            return error.InvalidPacketForChannelStream;
        }
    }
}

/// Stream state tracking
pub const StreamState = enum {
    opening, // SSH_MSG_CHANNEL_OPEN sent, waiting for response
    open, // SSH_MSG_CHANNEL_OPEN_CONFIRMATION received
    failed, // SSH_MSG_CHANNEL_OPEN_FAILURE received
    closing, // EOF sent/received
    closed, // QUIC stream closed
};

// ============================================================================
// Tests
// ============================================================================

test "isBidirectional - client streams" {
    const testing = std.testing;

    // Client-initiated bidirectional: LSBs = 00
    try testing.expect(isBidirectional(0)); // 0b0000
    try testing.expect(isBidirectional(4)); // 0b0100
    try testing.expect(isBidirectional(8)); // 0b1000
}

test "isBidirectional - server streams" {
    const testing = std.testing;

    // Server-initiated bidirectional: LSBs = 01
    try testing.expect(isBidirectional(1)); // 0b0001
    try testing.expect(isBidirectional(5)); // 0b0101
    try testing.expect(isBidirectional(9)); // 0b1001
}

test "isBidirectional - unidirectional streams" {
    const testing = std.testing;

    // Unidirectional streams: LSBs = 10 or 11
    try testing.expect(!isBidirectional(2)); // 0b0010
    try testing.expect(!isBidirectional(3)); // 0b0011
    try testing.expect(!isBidirectional(6)); // 0b0110
    try testing.expect(!isBidirectional(7)); // 0b0111
}

test "isClientInitiated and isServerInitiated" {
    const testing = std.testing;

    // Client-initiated (LSB = 0)
    try testing.expect(isClientInitiated(0));
    try testing.expect(isClientInitiated(4));
    try testing.expect(!isServerInitiated(0));

    // Server-initiated (LSB = 1)
    try testing.expect(isServerInitiated(1));
    try testing.expect(isServerInitiated(5));
    try testing.expect(!isClientInitiated(1));
}

test "validateStreamId - global stream" {
    try validateStreamId(global_stream);
}

test "validateStreamId - bidirectional streams" {
    try validateStreamId(4); // Client bidirectional
    try validateStreamId(5); // Server bidirectional
}

test "validateStreamId - unidirectional rejected" {
    const testing = std.testing;

    try testing.expectError(error.UnidirectionalStreamNotAllowed, validateStreamId(2));
    try testing.expectError(error.UnidirectionalStreamNotAllowed, validateStreamId(3));
}

test "isGlobalPacket - transport packets" {
    const testing = std.testing;

    try testing.expect(isGlobalPacket(constants.SSH_MSG.IGNORE));
    try testing.expect(isGlobalPacket(constants.SSH_MSG.DEBUG));
    try testing.expect(isGlobalPacket(constants.SSH_MSG.SERVICE_REQUEST));
}

test "isGlobalPacket - auth packets" {
    const testing = std.testing;

    try testing.expect(isGlobalPacket(constants.SSH_MSG.USERAUTH_REQUEST));
    try testing.expect(isGlobalPacket(constants.SSH_MSG.USERAUTH_SUCCESS));
    try testing.expect(isGlobalPacket(constants.SSH_MSG.USERAUTH_FAILURE));
}

test "isGlobalPacket - not global" {
    try std.testing.expect(!isGlobalPacket(constants.SSH_MSG.CHANNEL_OPEN));
    try std.testing.expect(!isGlobalPacket(constants.SSH_MSG.CHANNEL_DATA));
}

test "isChannelPacket - channel packets" {
    const testing = std.testing;

    try testing.expect(isChannelPacket(constants.SSH_MSG.CHANNEL_OPEN));
    try testing.expect(isChannelPacket(constants.SSH_MSG.CHANNEL_DATA));
    try testing.expect(isChannelPacket(constants.SSH_MSG.CHANNEL_EOF));
}

test "isChannelPacket - not channel" {
    try std.testing.expect(!isChannelPacket(constants.SSH_MSG.USERAUTH_REQUEST));
    try std.testing.expect(!isChannelPacket(constants.SSH_MSG.GLOBAL_REQUEST));
}

test "isProhibited - prohibited packets" {
    const testing = std.testing;

    try testing.expect(isProhibited(constants.SSH_MSG.DISCONNECT));
    try testing.expect(isProhibited(constants.SSH_MSG.KEXINIT));
    try testing.expect(isProhibited(constants.SSH_MSG.NEWKEYS));
    try testing.expect(isProhibited(constants.SSH_MSG.CHANNEL_WINDOW_ADJUST));
    try testing.expect(isProhibited(constants.SSH_MSG.CHANNEL_CLOSE));
    try testing.expect(isProhibited(30)); // KEX_ECDH_INIT
    try testing.expect(isProhibited(8)); // NEWCOMPRESS
}

test "isProhibited - allowed packets" {
    try std.testing.expect(!isProhibited(constants.SSH_MSG.CHANNEL_OPEN));
    try std.testing.expect(!isProhibited(constants.SSH_MSG.USERAUTH_REQUEST));
}

test "validatePacketForStream - global stream valid" {
    try validatePacketForStream(0, constants.SSH_MSG.USERAUTH_REQUEST);
    try validatePacketForStream(0, constants.SSH_MSG.SERVICE_REQUEST);
}

test "validatePacketForStream - global stream invalid" {
    const testing = std.testing;

    try testing.expectError(
        error.InvalidPacketForGlobalStream,
        validatePacketForStream(0, constants.SSH_MSG.CHANNEL_DATA),
    );
}

test "validatePacketForStream - channel stream valid" {
    try validatePacketForStream(4, constants.SSH_MSG.CHANNEL_OPEN);
    try validatePacketForStream(4, constants.SSH_MSG.CHANNEL_DATA);
}

test "validatePacketForStream - channel stream invalid" {
    const testing = std.testing;

    try testing.expectError(
        error.InvalidPacketForChannelStream,
        validatePacketForStream(4, constants.SSH_MSG.USERAUTH_REQUEST),
    );
}

test "validatePacketForStream - prohibited packet" {
    try std.testing.expectError(
        error.ProhibitedPacketType,
        validatePacketForStream(0, constants.SSH_MSG.DISCONNECT),
    );
    try std.testing.expectError(
        error.ProhibitedPacketType,
        validatePacketForStream(4, constants.SSH_MSG.CHANNEL_CLOSE),
    );
}
