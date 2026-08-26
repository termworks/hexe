const std = @import("std");

/// Public API types for QUIC connections and streams
/// Connection state
pub const ConnectionState = enum {
    idle, // Initial state
    connecting, // Handshake in progress
    established, // Ready for data transfer
    draining, // Connection closing
    closed, // Connection closed

    pub fn toString(self: ConnectionState) []const u8 {
        return switch (self) {
            .idle => "Idle",
            .connecting => "Connecting",
            .established => "Established",
            .draining => "Draining",
            .closed => "Closed",
        };
    }

    pub fn isActive(self: ConnectionState) bool {
        return self == .connecting or self == .established;
    }

    pub fn canSendData(self: ConnectionState) bool {
        return self == .established;
    }
};

/// Stream state
pub const StreamState = enum {
    open, // Stream open, can send/receive
    send_closed, // Local side closed
    recv_closed, // Remote side closed
    closed, // Both sides closed

    pub fn toString(self: StreamState) []const u8 {
        return switch (self) {
            .open => "Open",
            .send_closed => "SendClosed",
            .recv_closed => "RecvClosed",
            .closed => "Closed",
        };
    }

    pub fn canSend(self: StreamState) bool {
        return self == .open;
    }

    pub fn canReceive(self: StreamState) bool {
        return self == .open or self == .send_closed;
    }
};

/// Stream ID (u64)
pub const StreamId = u64;

/// Connection ID (opaque bytes)
pub const ConnectionId = []const u8;

/// Error codes
pub const QuicError = error{
    // Configuration errors
    InvalidConfig,
    MissingSshConfig,
    MissingTlsConfig,
    MissingServerCredentials,
    MissingServerName,
    InvalidTlsVerificationConfig,

    // Connection errors
    ConnectionNotEstablished,
    ConnectionClosed,
    ConnectionTimedOut,
    HandshakeFailed,
    InvalidState,

    // Stream errors
    StreamNotFound,
    StreamClosed,
    StreamLimitReached,
    FlowControlError,
    StreamError,

    // Transport errors
    NetworkError,
    InvalidPacket,
    ProtocolViolation,
    InvalidAddress,
    SocketError,

    // Crypto errors
    CryptoError,
    KeyExchangeFailed,
    AuthenticationFailed,

    // Resource errors
    OutOfMemory,
    BufferTooSmall,
};

/// Connection statistics
pub const ConnectionStats = struct {
    /// Total packets sent
    packets_sent: u64 = 0,

    /// Total packets received
    packets_received: u64 = 0,

    /// Total packets rejected as invalid/malformed
    packets_invalid: u64 = 0,

    /// Total bytes sent
    bytes_sent: u64 = 0,

    /// Total bytes received
    bytes_received: u64 = 0,

    /// Number of active streams
    active_streams: u32 = 0,

    /// Round-trip time (microseconds)
    rtt: u64 = 0,

    /// Connection duration (milliseconds)
    duration_ms: u64 = 0,
};

/// Stream information
pub const StreamInfo = struct {
    /// Stream ID
    id: StreamId,

    /// Stream state
    state: StreamState,

    /// Is bidirectional
    is_bidirectional: bool,

    /// Bytes sent
    bytes_sent: u64,

    /// Bytes received
    bytes_received: u64,

    /// Send buffer available space
    send_buffer_available: usize,

    /// Receive buffer data available
    recv_buffer_available: usize,
};

/// Connection event
pub const ConnectionEvent = union(enum) {
    /// Connection established
    connected: struct {
        /// Negotiated ALPN protocol, when available (TLS mode)
        alpn: ?[]const u8 = null,
    },

    /// Stream opened (by remote peer)
    stream_opened: StreamId,

    /// Stream data available for reading
    stream_readable: StreamId,

    /// Stream ready for writing
    stream_writable: StreamId,

    /// Stream closed
    stream_closed: struct {
        id: StreamId,
        error_code: ?u64,
    },

    /// Connection closing
    closing: struct {
        error_code: u64,
        reason: []const u8,
    },

    /// Connection closed
    closed: void,
};

/// Stream finish flag
pub const StreamFinish = enum {
    /// Don't finish stream
    no_finish,

    /// Finish stream after this write
    finish,
};

/// Peer-advertised connection ID metadata.
pub const PeerConnectionIdInfo = struct {
    sequence_number: u64,
    connection_id: [20]u8,
    connection_id_len: u8,
    stateless_reset_token: [16]u8,
};

/// Negotiation mode used by the connection.
pub const NegotiationMode = enum {
    tls,
    ssh,
};

/// Explicit connection capability matrix by mode.
pub const ModeCapabilities = struct {
    supports_unidirectional_streams: bool,
    supports_alpn: bool,
    requires_integrated_tls_server_hello: bool,
    requires_peer_transport_params: bool,

    pub fn forMode(mode: NegotiationMode) ModeCapabilities {
        return switch (mode) {
            .tls => .{
                .supports_unidirectional_streams = true,
                .supports_alpn = true,
                .requires_integrated_tls_server_hello = true,
                .requires_peer_transport_params = true,
            },
            .ssh => .{
                .supports_unidirectional_streams = false,
                .supports_alpn = false,
                .requires_integrated_tls_server_hello = false,
                .requires_peer_transport_params = true,
            },
        };
    }
};

/// Normalized negotiation result used by shared runtime logic.
pub const NegotiationResult = struct {
    mode: NegotiationMode,
    has_peer_transport_params: bool,
    tls_server_hello_applied: bool,
    tls_handshake_complete: bool,
    selected_alpn: ?[]const u8,
    ready_for_establish: bool,
};

/// Snapshot of negotiated connection metadata.
pub const NegotiationSnapshot = struct {
    mode: NegotiationMode,
    is_established: bool,
    alpn: ?[]const u8,
    peer_max_idle_timeout: u64,
    peer_max_udp_payload_size: u64,
    peer_initial_max_data: u64,
    peer_initial_max_streams_bidi: u64,
    peer_initial_max_streams_uni: u64,
};

// Tests

test "ConnectionState methods" {
    try std.testing.expect(ConnectionState.established.isActive());
    try std.testing.expect(ConnectionState.connecting.isActive());
    try std.testing.expect(!ConnectionState.closed.isActive());

    try std.testing.expect(ConnectionState.established.canSendData());
    try std.testing.expect(!ConnectionState.connecting.canSendData());
}

test "StreamState methods" {
    try std.testing.expect(StreamState.open.canSend());
    try std.testing.expect(!StreamState.send_closed.canSend());

    try std.testing.expect(StreamState.open.canReceive());
    try std.testing.expect(StreamState.send_closed.canReceive());
    try std.testing.expect(!StreamState.recv_closed.canReceive());
}

test "ConnectionStats initialization" {
    const stats = ConnectionStats{};

    try std.testing.expectEqual(@as(u64, 0), stats.packets_sent);
    try std.testing.expectEqual(@as(u64, 0), stats.packets_invalid);
    try std.testing.expectEqual(@as(u64, 0), stats.bytes_sent);
}

test "StreamInfo creation" {
    const info = StreamInfo{
        .id = 4,
        .state = .open,
        .is_bidirectional = true,
        .bytes_sent = 100,
        .bytes_received = 200,
        .send_buffer_available = 1024,
        .recv_buffer_available = 512,
    };

    try std.testing.expectEqual(@as(StreamId, 4), info.id);
    try std.testing.expectEqual(StreamState.open, info.state);
    try std.testing.expect(info.is_bidirectional);
}

test "ConnectionEvent variants" {
    const event1 = ConnectionEvent{ .connected = .{} };
    const event2 = ConnectionEvent{ .stream_opened = 4 };
    const event3 = ConnectionEvent{ .stream_readable = 8 };
    const event4 = ConnectionEvent{ .closing = .{ .error_code = 0, .reason = "No error" } };

    _ = event1;
    _ = event2;
    _ = event3;
    _ = event4;
}

test "ModeCapabilities matrix" {
    const tls_caps = ModeCapabilities.forMode(.tls);
    try std.testing.expect(tls_caps.supports_unidirectional_streams);
    try std.testing.expect(tls_caps.supports_alpn);
    try std.testing.expect(tls_caps.requires_integrated_tls_server_hello);
    try std.testing.expect(tls_caps.requires_peer_transport_params);

    const ssh_caps = ModeCapabilities.forMode(.ssh);
    try std.testing.expect(!ssh_caps.supports_unidirectional_streams);
    try std.testing.expect(!ssh_caps.supports_alpn);
    try std.testing.expect(!ssh_caps.requires_integrated_tls_server_hello);
    try std.testing.expect(ssh_caps.requires_peer_transport_params);
}
