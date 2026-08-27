const std = @import("std");

/// QUIC protocol version 1 (RFC 9000)
pub const QUIC_VERSION_1: u32 = 0x00000001;

/// Connection ID - variable length (0-20 bytes)
pub const ConnectionId = struct {
    data: [20]u8 = undefined,
    len: u8 = 0,

    pub fn init(bytes: []const u8) !ConnectionId {
        if (bytes.len > 20) return error.ConnectionIdTooLong;
        var cid = ConnectionId{ .data = [_]u8{0} ** 20, .len = @intCast(bytes.len) };
        @memcpy(cid.data[0..bytes.len], bytes);
        return cid;
    }

    pub fn empty() ConnectionId {
        return ConnectionId{};
    }

    pub fn slice(self: *const ConnectionId) []const u8 {
        return self.data[0..self.len];
    }

    pub fn eql(self: *const ConnectionId, other: *const ConnectionId) bool {
        if (self.len != other.len) return false;
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

/// Packet number - variable length encoding (1-4 bytes)
pub const PacketNumber = u64;

/// QUIC packet types
pub const PacketType = enum(u8) {
    /// Initial packet (Long Header)
    initial = 0x00,
    /// 0-RTT packet (Long Header)
    zero_rtt = 0x01,
    /// Handshake packet (Long Header)
    handshake = 0x02,
    /// Retry packet (Long Header)
    retry = 0x03,
    /// Short Header packet (1-RTT)
    short_header = 0x40,

    pub fn isLongHeader(self: PacketType) bool {
        return @intFromEnum(self) < 0x40;
    }
};

/// Packet header - common fields
pub const PacketHeader = struct {
    packet_type: PacketType,
    version: u32,
    dest_conn_id: ConnectionId,
    src_conn_id: ConnectionId,
    packet_number: PacketNumber,
    /// Payload length (for Long Header packets)
    payload_len: ?u64 = null,
    /// Token (for Initial and Retry packets)
    token: []const u8 = &.{},
};

/// QUIC frame types (RFC 9000, Section 12.4)
pub const FrameType = enum(u64) {
    padding = 0x00,
    ping = 0x01,
    ack = 0x02,
    ack_ecn = 0x03,
    reset_stream = 0x04,
    stop_sending = 0x05,
    crypto = 0x06,
    new_token = 0x07,
    stream = 0x08, // 0x08-0x0f (with flags)
    max_data = 0x10,
    max_stream_data = 0x11,
    max_streams_bidi = 0x12,
    max_streams_uni = 0x13,
    data_blocked = 0x14,
    stream_data_blocked = 0x15,
    streams_blocked_bidi = 0x16,
    streams_blocked_uni = 0x17,
    new_connection_id = 0x18,
    retire_connection_id = 0x19,
    path_challenge = 0x1a,
    path_response = 0x1b,
    connection_close = 0x1c,
    connection_close_app = 0x1d,
    handshake_done = 0x1e,
    _,

    pub fn isStreamFrame(frame_type: u64) bool {
        return (frame_type >= 0x08 and frame_type <= 0x0f);
    }
};

/// Stream ID - 62-bit identifier
pub const StreamId = u64;

/// Stream type determined by least significant bits
pub const StreamType = enum(u2) {
    client_bidi = 0b00,
    server_bidi = 0b01,
    client_uni = 0b10,
    server_uni = 0b11,

    pub fn fromStreamId(stream_id: StreamId) StreamType {
        return @enumFromInt(@as(u2, @intCast(stream_id & 0x03)));
    }

    pub fn isBidirectional(self: StreamType) bool {
        return self == .client_bidi or self == .server_bidi;
    }

    pub fn isUnidirectional(self: StreamType) bool {
        return self == .client_uni or self == .server_uni;
    }

    pub fn isClientInitiated(self: StreamType) bool {
        return self == .client_bidi or self == .client_uni;
    }

    pub fn isServerInitiated(self: StreamType) bool {
        return self == .server_bidi or self == .server_uni;
    }
};

/// Error codes (RFC 9000, Section 20)
pub const ErrorCode = enum(u64) {
    no_error = 0x00,
    internal_error = 0x01,
    connection_refused = 0x02,
    flow_control_error = 0x03,
    stream_limit_error = 0x04,
    stream_state_error = 0x05,
    final_size_error = 0x06,
    frame_encoding_error = 0x07,
    transport_parameter_error = 0x08,
    connection_id_limit_error = 0x09,
    protocol_violation = 0x0a,
    invalid_token = 0x0b,
    application_error = 0x0c,
    crypto_buffer_exceeded = 0x0d,
    key_update_error = 0x0e,
    aead_limit_reached = 0x0f,
    no_viable_path = 0x10,
    _,
};

/// Crypto mode selection
pub const QuicMode = enum {
    /// Standard TLS 1.3 handshake (RFC 9001)
    tls,
    /// SSH/QUIC key exchange (ssh_quic_spec.md)
    ssh,
};

/// Connection state
pub const ConnectionState = enum {
    idle,
    handshaking,
    established,
    closing,
    draining,
    closed,
};

/// Stream state (send side)
pub const StreamSendState = enum {
    ready,
    send,
    data_sent,
    reset_sent,
    reset_recvd,
};

/// Stream state (receive side)
pub const StreamRecvState = enum {
    recv,
    size_known,
    data_recvd,
    data_read,
    reset_recvd,
    reset_read,
};

/// Transport parameters (RFC 9000, Section 18)
pub const TransportParameters = struct {
    /// Maximum idle timeout in milliseconds
    max_idle_timeout: u64 = 30000,
    /// Maximum UDP payload size
    max_udp_payload_size: u64 = 65527,
    /// Initial maximum data
    initial_max_data: u64 = 1048576, // 1 MB
    /// Initial maximum stream data (bidirectional, local)
    initial_max_stream_data_bidi_local: u64 = 524288, // 512 KB
    /// Initial maximum stream data (bidirectional, remote)
    initial_max_stream_data_bidi_remote: u64 = 524288,
    /// Initial maximum stream data (unidirectional)
    initial_max_stream_data_uni: u64 = 524288,
    /// Initial maximum bidirectional streams
    initial_max_streams_bidi: u64 = 100,
    /// Initial maximum unidirectional streams
    initial_max_streams_uni: u64 = 100,
    /// ACK delay exponent
    ack_delay_exponent: u64 = 3,
    /// Maximum ACK delay in milliseconds
    max_ack_delay: u64 = 25,
    /// Disable active migration
    disable_active_migration: bool = false,
    /// Preferred address (optional)
    preferred_address: ?[]const u8 = null,
    /// Active connection ID limit
    active_connection_id_limit: u64 = 2,
    /// Initial source connection ID
    initial_source_connection_id: ?ConnectionId = null,
    /// Retry source connection ID
    retry_source_connection_id: ?ConnectionId = null,
};

test "ConnectionId creation" {
    const cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    try std.testing.expectEqual(@as(u8, 4), cid.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, cid.slice());
}

test "ConnectionId empty" {
    const cid = ConnectionId.empty();
    try std.testing.expectEqual(@as(u8, 0), cid.len);
}

test "ConnectionId equality" {
    const cid1 = try ConnectionId.init(&[_]u8{ 1, 2, 3 });
    const cid2 = try ConnectionId.init(&[_]u8{ 1, 2, 3 });
    const cid3 = try ConnectionId.init(&[_]u8{ 1, 2, 4 });
    try std.testing.expect(cid1.eql(&cid2));
    try std.testing.expect(!cid1.eql(&cid3));
}

test "StreamType from StreamId" {
    try std.testing.expectEqual(StreamType.client_bidi, StreamType.fromStreamId(0));
    try std.testing.expectEqual(StreamType.server_bidi, StreamType.fromStreamId(1));
    try std.testing.expectEqual(StreamType.client_uni, StreamType.fromStreamId(2));
    try std.testing.expectEqual(StreamType.server_uni, StreamType.fromStreamId(3));
    try std.testing.expectEqual(StreamType.client_bidi, StreamType.fromStreamId(4));
}

test "StreamType properties" {
    try std.testing.expect(StreamType.client_bidi.isBidirectional());
    try std.testing.expect(StreamType.server_bidi.isBidirectional());
    try std.testing.expect(StreamType.client_uni.isUnidirectional());
    try std.testing.expect(StreamType.server_uni.isUnidirectional());
    try std.testing.expect(StreamType.client_bidi.isClientInitiated());
    try std.testing.expect(StreamType.server_uni.isServerInitiated());
}

test "PacketType long header check" {
    try std.testing.expect(PacketType.initial.isLongHeader());
    try std.testing.expect(PacketType.handshake.isLongHeader());
    try std.testing.expect(!PacketType.short_header.isLongHeader());
}

test "FrameType stream frame check" {
    try std.testing.expect(FrameType.isStreamFrame(0x08));
    try std.testing.expect(FrameType.isStreamFrame(0x0f));
    try std.testing.expect(!FrameType.isStreamFrame(0x00));
    try std.testing.expect(!FrameType.isStreamFrame(0x10));
}
