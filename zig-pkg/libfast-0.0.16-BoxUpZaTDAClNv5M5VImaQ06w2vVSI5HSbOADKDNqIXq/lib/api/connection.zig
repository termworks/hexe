const std = @import("std");
const config_mod = @import("config.zig");
const types_mod = @import("types.zig");
const conn_internal = @import("../core/connection.zig");
const stream_internal = @import("../core/stream.zig");
const udp_mod = @import("../transport/udp.zig");
const crypto_mod = @import("libsafe").crypto;
const packet_mod = @import("../core/packet.zig");
const frame_mod = @import("../core/frame.zig");
const core_types = @import("../core/types.zig");
const transport_params_mod = @import("../core/transport_params.zig");
const tls_context_mod = @import("libsafe").tls_context;
const tls_handshake_mod = @import("libsafe").tls_handshake;
const varint = @import("../utils/varint.zig");
const time_mod = @import("../utils/time.zig");

const DEFAULT_SHORT_HEADER_DCID_LEN: u8 = 8;
const CLOSE_REASON_MAX_LEN: usize = 256;
const MAX_VN_VERSIONS: usize = 16;
const LOCAL_SUPPORTED_VERSIONS = [_]u32{core_types.QUIC_VERSION_1};
const FALLBACK_DRAIN_TIMEOUT_US: u64 = 3 * time_mod.Duration.SECOND;

const PacketSpace = enum {
    initial,
    handshake,
    zero_rtt,
    retry,
    application,
};

const ParsedHeader = struct {
    consumed: usize,
    packet_space: PacketSpace,
    is_short_header: bool,
    initial_token: []const u8,
    src_conn_id: ?core_types.ConnectionId,
};

const TlsFailureStage = enum {
    server_hello,
    client_hello,
    complete,
};

/// Public QUIC connection handle
pub const QuicConnection = struct {
    allocator: std.mem.Allocator,
    config: config_mod.QuicConfig,
    state: types_mod.ConnectionState,

    // Internal connection
    internal_conn: ?*conn_internal.Connection,

    // UDP socket
    socket: ?*udp_mod.UdpSocket,

    // Crypto context
    crypto_ctx: ?*crypto_mod.CryptoContext,

    // TLS handshake context (TLS mode)
    tls_ctx: ?*tls_context_mod.TlsContext,

    // Event queue
    events: std.ArrayList(types_mod.ConnectionEvent),

    // Remote address (for client)
    remote_addr: ?std.net.Address,

    // Basic packet visibility counters
    packets_received: u64,
    packets_invalid: u64,
    created_at: time_mod.Instant,

    // Negotiated protocol metadata
    negotiated_alpn: ?[]const u8,

    // TLS integrated handshake progression marker
    tls_server_hello_applied: bool,

    // Connection close state tracking
    close_reason_buf: [CLOSE_REASON_MAX_LEN]u8,
    close_reason_len: usize,
    close_error_code: u64,
    drain_pending: bool,
    drain_deadline: ?time_mod.Instant,
    closed_event_emitted: bool,

    // Token lifecycle state
    latest_new_token: ?[]u8,
    token_validator_ctx: ?*anyopaque,
    token_validator: ?*const fn (ctx: ?*anyopaque, token: []const u8) bool,
    retry_validator_ctx: ?*anyopaque,
    retry_validator: ?*const fn (ctx: ?*anyopaque, token: []const u8, retry_source_conn_id: core_types.ConnectionId) bool,

    // Retry handling state (client)
    retry_token: ?[]u8,
    retry_source_conn_id: ?core_types.ConnectionId,
    retry_seen: bool,

    /// Initialize a new QUIC connection
    pub fn init(
        allocator: std.mem.Allocator,
        config: config_mod.QuicConfig,
    ) types_mod.QuicError!QuicConnection {
        config.validate() catch |err| {
            return switch (err) {
                error.MissingSshConfig => types_mod.QuicError.MissingSshConfig,
                error.MissingTlsConfig => types_mod.QuicError.MissingTlsConfig,
                error.MissingServerCredentials => types_mod.QuicError.MissingServerCredentials,
                error.MissingServerName => types_mod.QuicError.MissingServerName,
                error.InvalidTlsVerificationConfig => types_mod.QuicError.InvalidTlsVerificationConfig,
            };
        };

        return QuicConnection{
            .allocator = allocator,
            .config = config,
            .state = .idle,
            .internal_conn = null,
            .socket = null,
            .crypto_ctx = null,
            .tls_ctx = null,
            .events = .{},
            .remote_addr = null,
            .packets_received = 0,
            .packets_invalid = 0,
            .created_at = time_mod.Instant.now(),
            .negotiated_alpn = null,
            .tls_server_hello_applied = false,
            .close_reason_buf = [_]u8{0} ** CLOSE_REASON_MAX_LEN,
            .close_reason_len = 0,
            .close_error_code = 0,
            .drain_pending = false,
            .drain_deadline = null,
            .closed_event_emitted = false,
            .latest_new_token = null,
            .token_validator_ctx = null,
            .token_validator = null,
            .retry_validator_ctx = null,
            .retry_validator = null,
            .retry_token = null,
            .retry_source_conn_id = null,
            .retry_seen = false,
        };
    }

    fn setCloseReason(self: *QuicConnection, reason: []const u8) void {
        const len = @min(reason.len, CLOSE_REASON_MAX_LEN);
        @memcpy(self.close_reason_buf[0..len], reason[0..len]);
        self.close_reason_len = len;
    }

    fn closeReason(self: *QuicConnection) []const u8 {
        return self.close_reason_buf[0..self.close_reason_len];
    }

    fn drain_deadline_expired(now: time_mod.Instant, deadline: time_mod.Instant) bool {
        // Strict alarm semantics: deadline must be strictly earlier than now.
        return deadline.isBefore(now);
    }

    fn enterDraining(
        self: *QuicConnection,
        error_code: u64,
        reason: []const u8,
    ) types_mod.QuicError!void {
        if (self.state == .closed or self.state == .draining) {
            return;
        }

        const drain_timeout = if (self.internal_conn) |conn|
            conn.drainTimeoutDuration()
        else
            FALLBACK_DRAIN_TIMEOUT_US;

        self.setCloseReason(reason);
        self.close_error_code = error_code;
        self.drain_pending = true;
        self.drain_deadline = time_mod.Instant.now().add(drain_timeout);
        self.state = .draining;

        try self.events.append(self.allocator, .{
            .closing = .{
                .error_code = error_code,
                .reason = self.closeReason(),
            },
        });
    }

    fn shortHeaderDcidLen(self: *QuicConnection) u8 {
        if (self.internal_conn) |conn| {
            return conn.local_conn_id.len;
        }
        return DEFAULT_SHORT_HEADER_DCID_LEN;
    }

    fn decodePacketHeader(self: *QuicConnection, packet: []const u8) types_mod.QuicError!ParsedHeader {
        if (packet.len == 0) {
            return types_mod.QuicError.InvalidPacket;
        }

        const is_long_header = (packet[0] & 0x80) != 0;

        if (is_long_header) {
            const result = packet_mod.LongHeader.decode(packet) catch {
                return types_mod.QuicError.InvalidPacket;
            };

            if (result.header.version != core_types.QUIC_VERSION_1) {
                return types_mod.QuicError.ProtocolViolation;
            }

            const space: PacketSpace = switch (result.header.packet_type) {
                .initial => .initial,
                .handshake => .handshake,
                .zero_rtt => .zero_rtt,
                .retry => .retry,
                else => .application,
            };

            return .{
                .consumed = result.consumed,
                .packet_space = space,
                .is_short_header = false,
                .initial_token = if (space == .initial or space == .retry) result.header.token else &.{},
                .src_conn_id = result.header.src_conn_id,
            };
        }

        const dcid_len = self.shortHeaderDcidLen();
        const result = packet_mod.ShortHeader.decode(packet, dcid_len) catch {
            return types_mod.QuicError.InvalidPacket;
        };
        return .{
            .consumed = result.consumed,
            .packet_space = .application,
            .is_short_header = true,
            .initial_token = &.{},
            .src_conn_id = null,
        };
    }

    fn queueProtocolViolation(self: *QuicConnection, reason: []const u8) types_mod.QuicError!void {
        if (self.state == .closed) {
            return;
        }

        try self.enterDraining(@intFromEnum(core_types.ErrorCode.protocol_violation), reason);
    }

    fn queueTransportParameterError(self: *QuicConnection, reason: []const u8) types_mod.QuicError!void {
        if (self.state == .closed) {
            return;
        }

        try self.enterDraining(@intFromEnum(core_types.ErrorCode.transport_parameter_error), reason);
    }

    fn queueFlowControlError(self: *QuicConnection, reason: []const u8) types_mod.QuicError!void {
        if (self.state == .closed) {
            return;
        }

        try self.enterDraining(@intFromEnum(core_types.ErrorCode.flow_control_error), reason);
    }

    fn queueInvalidToken(self: *QuicConnection, reason: []const u8) types_mod.QuicError!void {
        if (self.state == .closed) {
            return;
        }

        try self.enterDraining(@intFromEnum(core_types.ErrorCode.invalid_token), reason);
    }

    fn storeNewToken(self: *QuicConnection, token: []const u8) types_mod.QuicError!void {
        if (self.latest_new_token) |existing| {
            self.allocator.free(existing);
            self.latest_new_token = null;
        }

        const copy = self.allocator.alloc(u8, token.len) catch {
            return types_mod.QuicError.OutOfMemory;
        };
        @memcpy(copy, token);
        self.latest_new_token = copy;
    }

    fn storeRetryToken(self: *QuicConnection, token: []const u8) types_mod.QuicError!void {
        if (self.retry_token) |existing| {
            self.allocator.free(existing);
            self.retry_token = null;
        }

        const copy = self.allocator.alloc(u8, token.len) catch {
            return types_mod.QuicError.OutOfMemory;
        };
        @memcpy(copy, token);
        self.retry_token = copy;
    }

    fn handleRetryPacket(self: *QuicConnection, header: ParsedHeader) types_mod.QuicError!void {
        if (self.config.role != .client or self.state != .connecting) {
            self.packets_invalid += 1;
            try self.queueProtocolViolation("unexpected retry packet");
            return;
        }

        if (self.retry_seen) {
            self.packets_invalid += 1;
            try self.queueProtocolViolation("multiple retry packets");
            return;
        }

        if (header.initial_token.len == 0) {
            self.packets_invalid += 1;
            try self.queueInvalidToken("retry token missing");
            return;
        }

        const retry_scid = header.src_conn_id orelse {
            self.packets_invalid += 1;
            try self.queueProtocolViolation("retry source connection id missing");
            return;
        };

        if (!self.validateRetryIntegrity(header.initial_token, retry_scid)) {
            self.packets_invalid += 1;
            try self.queueProtocolViolation("retry integrity check failed");
            return;
        }

        try self.storeRetryToken(header.initial_token);
        self.retry_source_conn_id = retry_scid;
        self.retry_seen = true;

        if (self.internal_conn) |conn| {
            conn.remote_conn_id = retry_scid;
        }
    }

    fn validateToken(self: *QuicConnection, token: []const u8) bool {
        if (self.token_validator) |validator| {
            return validator(self.token_validator_ctx, token);
        }

        // Default policy accepts token-bearing Initial packets when no explicit
        // validator is configured by the application.
        return true;
    }

    fn validateRetryIntegrity(self: *QuicConnection, token: []const u8, retry_source_conn_id: core_types.ConnectionId) bool {
        if (self.retry_validator) |validator| {
            return validator(self.retry_validator_ctx, token, retry_source_conn_id);
        }

        // Default policy accepts Retry packets when no explicit integrity
        // validator is configured by the application.
        return true;
    }

    fn detectStatelessReset(self: *QuicConnection, packet: []const u8, header: ParsedHeader) bool {
        if (!header.is_short_header or packet.len < 17) {
            return false;
        }

        const conn = self.internal_conn orelse return false;
        const token = packet[packet.len - 16 .. packet.len];
        for (conn.peer_connection_ids.items) |entry| {
            if (std.mem.eql(u8, token, &entry.stateless_reset_token)) {
                return true;
            }
        }

        return false;
    }

    fn detectStatelessResetRaw(self: *QuicConnection, packet: []const u8) bool {
        if (packet.len < 17) {
            return false;
        }

        // Stateless reset is carried in a packet that appears as a short header.
        if ((packet[0] & 0x80) != 0) {
            return false;
        }

        const conn = self.internal_conn orelse return false;
        const token = packet[packet.len - 16 .. packet.len];
        for (conn.peer_connection_ids.items) |entry| {
            if (std.mem.eql(u8, token, &entry.stateless_reset_token)) {
                return true;
            }
        }

        return false;
    }

    fn selectMutualVersion(peer_versions: []const u32) ?u32 {
        for (LOCAL_SUPPORTED_VERSIONS) |local| {
            for (peer_versions) |peer| {
                if (peer == local) return local;
            }
        }
        return null;
    }

    fn handleVersionNegotiationPacket(self: *QuicConnection, packet: []const u8) types_mod.QuicError!bool {
        if (packet.len < 5) return false;
        if ((packet[0] & 0x80) == 0) return false;

        const version = std.mem.readInt(u32, packet[1..5], .big);
        if (version != 0) return false;

        var versions: [MAX_VN_VERSIONS]u32 = undefined;
        const decoded = packet_mod.VersionNegotiationPacket.decode(packet, &versions) catch {
            return types_mod.QuicError.InvalidPacket;
        };

        // Policy: only client in connecting state reacts to VN packets.
        if (self.config.role != .client or self.state != .connecting) {
            return true;
        }

        const mutual = selectMutualVersion(decoded.packet.supported_versions);
        if (mutual == null) {
            self.packets_invalid += 1;
            try self.enterDraining(@intFromEnum(core_types.ErrorCode.protocol_violation), "no mutual QUIC version");
            return true;
        }

        // VN packets advertising the currently attempted version are invalid.
        if (mutual.? == core_types.QUIC_VERSION_1) {
            self.packets_invalid += 1;
            try self.enterDraining(@intFromEnum(core_types.ErrorCode.protocol_violation), "invalid version negotiation");
            return true;
        }

        return true;
    }

    fn recoverySpaceForPacketSpace(packet_space: PacketSpace) ?conn_internal.RecoverySpace {
        return switch (packet_space) {
            .initial => .initial,
            .handshake => .handshake,
            .application => .application,
            .zero_rtt, .retry => null,
        };
    }

    fn queueTlsFailure(self: *QuicConnection, stage: TlsFailureStage, err: anyerror) types_mod.QuicError!void {
        if (self.state == .closed) {
            return;
        }

        switch (err) {
            tls_context_mod.TlsError.AlpnMismatch => {
                try self.enterDraining(@intFromEnum(core_types.ErrorCode.connection_refused), "alpn mismatch");
            },
            tls_context_mod.TlsError.UnsupportedCipherSuite => {
                try self.enterDraining(@intFromEnum(core_types.ErrorCode.connection_refused), "tls unsupported cipher suite");
            },
            tls_context_mod.TlsError.OutOfMemory => {
                try self.enterDraining(@intFromEnum(core_types.ErrorCode.internal_error), "tls internal allocation failure");
            },
            else => {
                const reason = switch (stage) {
                    .server_hello => "tls server hello rejected",
                    .client_hello => "tls client hello rejected",
                    .complete => "tls handshake completion failed",
                };
                try self.enterDraining(@intFromEnum(core_types.ErrorCode.protocol_violation), reason);
            },
        }
    }

    fn transitionToEstablished(self: *QuicConnection) types_mod.QuicError!void {
        if (self.state != .connecting) {
            return;
        }

        const negotiation = self.buildNegotiationResult();
        if (negotiation.mode == .tls and !negotiation.ready_for_establish) {
            return;
        }

        const conn = self.internal_conn orelse return;
        conn.markEstablished();

        if (self.tls_ctx) |tls_ctx| {
            self.negotiated_alpn = tls_ctx.getSelectedAlpn();
        }

        self.state = .established;
        try self.events.append(self.allocator, .{ .connected = .{ .alpn = self.negotiated_alpn } });
    }

    fn isTlsNegotiatedForEstablish(self: *const QuicConnection) bool {
        const negotiation = self.buildNegotiationResult();
        return negotiation.mode == .tls and negotiation.ready_for_establish;
    }

    fn negotiationMode(self: *const QuicConnection) types_mod.NegotiationMode {
        return switch (self.config.mode) {
            .tls => .tls,
            .ssh => .ssh,
        };
    }

    fn buildNegotiationResult(self: *const QuicConnection) types_mod.NegotiationResult {
        const mode = self.negotiationMode();

        const has_peer_transport_params = blk: {
            const conn = self.internal_conn orelse break :blk false;
            break :blk conn.remote_params != null;
        };

        const tls_handshake_complete = blk: {
            if (mode != .tls) break :blk false;
            const tls_ctx = self.tls_ctx orelse break :blk false;
            break :blk tls_ctx.state.isComplete();
        };

        const ready_for_establish = switch (mode) {
            .tls => has_peer_transport_params and self.tls_server_hello_applied and tls_handshake_complete,
            .ssh => has_peer_transport_params,
        };

        return .{
            .mode = mode,
            .has_peer_transport_params = has_peer_transport_params,
            .tls_server_hello_applied = self.tls_server_hello_applied,
            .tls_handshake_complete = tls_handshake_complete,
            .selected_alpn = self.negotiated_alpn,
            .ready_for_establish = ready_for_establish,
        };
    }

    fn validateFrameAllowedInState(self: *QuicConnection, frame_type: u64) types_mod.QuicError!void {
        if (self.state != .connecting) {
            return;
        }

        if (core_types.FrameType.isStreamFrame(frame_type)) {
            return types_mod.QuicError.ProtocolViolation;
        }

        switch (frame_type) {
            0x04, 0x05, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17 => {
                return types_mod.QuicError.ProtocolViolation;
            },
            else => {},
        }
    }

    fn validateFrameAllowedInPacketSpace(self: *QuicConnection, frame_type: u64, packet_space: PacketSpace) types_mod.QuicError!void {
        _ = self;

        if (isReservedFrameType(frame_type)) {
            return types_mod.QuicError.ProtocolViolation;
        }

        if (packet_space == .retry) {
            return types_mod.QuicError.ProtocolViolation;
        }

        if (packet_space == .application) {
            if (frame_type == 0x06) {
                return types_mod.QuicError.ProtocolViolation;
            }
            return;
        }

        if (packet_space == .initial or packet_space == .handshake) {
            if (frame_type == 0x00 or frame_type == 0x01 or frame_type == 0x06 or frame_type == 0x1c or frame_type == 0x1d) {
                return;
            }
            if (frame_type == 0x02 or frame_type == 0x03) {
                return;
            }
            return types_mod.QuicError.ProtocolViolation;
        }

        if (packet_space == .zero_rtt) {
            if (frame_type == 0x00 or frame_type == 0x01 or frame_type == 0x1c or frame_type == 0x1d) {
                return;
            }

            if (core_types.FrameType.isStreamFrame(frame_type)) {
                return;
            }

            return switch (frame_type) {
                0x04,
                0x05, // RESET_STREAM, STOP_SENDING
                0x10,
                0x11, // MAX_DATA, MAX_STREAM_DATA
                0x12,
                0x13, // MAX_STREAMS
                0x14,
                0x15, // DATA_BLOCKED, STREAM_DATA_BLOCKED
                0x16,
                0x17, // STREAMS_BLOCKED
                => {},
                else => types_mod.QuicError.ProtocolViolation,
            };
        }

        if (frame_type == 0x01 or frame_type == 0x1c or frame_type == 0x1d) {
            return;
        }

        if (frame_type == 0x02 or frame_type == 0x03) {
            if (packet_space == .zero_rtt) return types_mod.QuicError.ProtocolViolation;
            return;
        }

        if (packet_space == .zero_rtt and frame_type == 0x06) {
            return types_mod.QuicError.ProtocolViolation;
        }

        if (packet_space != .application and (frame_type == 0x07 or frame_type == 0x18 or frame_type == 0x19 or frame_type == 0x1e)) {
            return types_mod.QuicError.ProtocolViolation;
        }

        if (!isKnownFrameType(frame_type) and packet_space != .application) {
            return types_mod.QuicError.ProtocolViolation;
        }

        if (core_types.FrameType.isStreamFrame(frame_type)) {
            return types_mod.QuicError.ProtocolViolation;
        }

        switch (frame_type) {
            0x04, 0x05, 0x1a, 0x1b => return types_mod.QuicError.ProtocolViolation,
            else => {},
        }
    }

    fn isKnownFrameType(frame_type: u64) bool {
        if (core_types.FrameType.isStreamFrame(frame_type)) {
            return true;
        }

        return switch (frame_type) {
            0x00, // PADDING
            0x01, // PING
            0x02,
            0x03, // ACK
            0x04, // RESET_STREAM
            0x05, // STOP_SENDING
            0x06, // CRYPTO
            0x07, // NEW_TOKEN
            0x10, // MAX_DATA
            0x11, // MAX_STREAM_DATA
            0x12,
            0x13, // MAX_STREAMS
            0x14, // DATA_BLOCKED
            0x15, // STREAM_DATA_BLOCKED
            0x16,
            0x17, // STREAMS_BLOCKED
            0x18, // NEW_CONNECTION_ID
            0x19, // RETIRE_CONNECTION_ID
            0x1a, // PATH_CHALLENGE
            0x1b, // PATH_RESPONSE
            0x1c,
            0x1d, // CONNECTION_CLOSE
            0x1e, // HANDSHAKE_DONE
            => true,
            else => false,
        };
    }

    fn isReservedFrameType(frame_type: u64) bool {
        if (frame_type < 0x1f) {
            return false;
        }

        return (frame_type & 0x1f) == 0x1f;
    }

    fn routeFrame(self: *QuicConnection, payload: []const u8, packet_space: PacketSpace) types_mod.QuicError!usize {
        if (payload.len == 0) return 0;

        const frame_type_result = varint.decode(payload) catch {
            return types_mod.QuicError.InvalidPacket;
        };

        const frame_type = frame_type_result.value;

        try self.validateFrameAllowedInState(frame_type);
        try self.validateFrameAllowedInPacketSpace(frame_type, packet_space);

        if (core_types.FrameType.isStreamFrame(frame_type)) {
            const decoded = frame_mod.StreamFrame.decode(payload) catch {
                return types_mod.QuicError.InvalidPacket;
            };
            const conn = self.internal_conn orelse return types_mod.QuicError.InvalidState;
            const stream = conn.getOrCreateStream(decoded.frame.stream_id) catch {
                return types_mod.QuicError.StreamError;
            };

            stream.appendRecvData(decoded.frame.data, decoded.frame.offset, decoded.frame.fin) catch |err| {
                return switch (err) {
                    error.FlowControlError => types_mod.QuicError.FlowControlError,
                    error.FinalSizeError => types_mod.QuicError.ProtocolViolation,
                    error.OutOfOrderData, error.StreamClosed => types_mod.QuicError.ProtocolViolation,
                    else => types_mod.QuicError.InvalidPacket,
                };
            };

            try self.events.append(self.allocator, .{ .stream_readable = decoded.frame.stream_id });
            return decoded.consumed;
        }

        switch (frame_type) {
            0x00 => {
                const decoded = frame_mod.PaddingFrame.decode(payload) catch {
                    return types_mod.QuicError.InvalidPacket;
                };
                return decoded.consumed;
            },
            0x01 => {
                const decoded = frame_mod.PingFrame.decode(payload) catch {
                    return types_mod.QuicError.InvalidPacket;
                };
                return decoded.consumed;
            },
            0x06 => {
                const decoded = frame_mod.CryptoFrame.decode(payload) catch {
                    return types_mod.QuicError.InvalidPacket;
                };
                return decoded.consumed;
            },
            0x02, 0x03 => {
                var ack_ranges: [32]frame_mod.AckFrame.AckRange = undefined;
                const decoded = frame_mod.AckFrame.decodeWithAckRanges(payload, &ack_ranges) catch {
                    return types_mod.QuicError.InvalidPacket;
                };
                if (self.internal_conn) |conn| {
                    const recovery_space = recoverySpaceForPacketSpace(packet_space) orelse {
                        return types_mod.QuicError.ProtocolViolation;
                    };

                    if (!conn.validateAckFrameInSpace(
                        recovery_space,
                        decoded.frame.largest_acked,
                        decoded.frame.first_ack_range,
                        decoded.frame.ack_ranges,
                    )) {
                        return types_mod.QuicError.ProtocolViolation;
                    }

                    const ack_delay_us = conn.normalizePeerAckDelay(decoded.frame.ack_delay);

                    conn.processAckDetailedWithRangesInSpace(
                        recovery_space,
                        decoded.frame.largest_acked,
                        ack_delay_us,
                        decoded.frame.first_ack_range,
                        decoded.frame.ack_ranges,
                    );
                }
                return decoded.consumed;
            },
            0x1c, 0x1d => {
                const decoded = frame_mod.ConnectionCloseFrame.decode(payload) catch {
                    return types_mod.QuicError.InvalidPacket;
                };

                try self.enterDraining(decoded.frame.error_code, decoded.frame.reason);
                return decoded.consumed;
            },
            0x10 => {
                const decoded = frame_mod.MaxDataFrame.decode(payload) catch {
                    return types_mod.QuicError.InvalidPacket;
                };

                const conn = self.internal_conn orelse return types_mod.QuicError.InvalidState;
                conn.onMaxData(decoded.frame.max_data);
                return decoded.consumed;
            },
            0x11 => {
                const decoded = frame_mod.MaxStreamDataFrame.decode(payload) catch {
                    return types_mod.QuicError.InvalidPacket;
                };

                const conn = self.internal_conn orelse return types_mod.QuicError.InvalidState;
                conn.onMaxStreamData(decoded.frame.stream_id, decoded.frame.max_stream_data);
                return decoded.consumed;
            },
            0x12, 0x13 => {
                const decoded = frame_mod.MaxStreamsFrame.decode(payload) catch {
                    return types_mod.QuicError.InvalidPacket;
                };

                const conn = self.internal_conn orelse return types_mod.QuicError.InvalidState;
                conn.onMaxStreams(decoded.frame.bidirectional, decoded.frame.max_streams);
                return decoded.consumed;
            },
            0x14 => {
                const decoded = frame_mod.DataBlockedFrame.decode(payload) catch {
                    return types_mod.QuicError.InvalidPacket;
                };

                const conn = self.internal_conn orelse return types_mod.QuicError.InvalidState;
                conn.onDataBlocked(decoded.frame.max_data);
                return decoded.consumed;
            },
            0x15 => {
                const decoded = frame_mod.StreamDataBlockedFrame.decode(payload) catch {
                    return types_mod.QuicError.InvalidPacket;
                };

                const conn = self.internal_conn orelse return types_mod.QuicError.InvalidState;
                conn.onStreamDataBlocked(decoded.frame.max_stream_data);
                return decoded.consumed;
            },
            0x16, 0x17 => {
                const decoded = frame_mod.StreamsBlockedFrame.decode(payload) catch {
                    return types_mod.QuicError.InvalidPacket;
                };

                const conn = self.internal_conn orelse return types_mod.QuicError.InvalidState;
                conn.onStreamsBlocked(decoded.frame.bidirectional, decoded.frame.max_streams);
                return decoded.consumed;
            },
            0x18 => {
                const decoded = frame_mod.NewConnectionIdFrame.decode(payload) catch {
                    return types_mod.QuicError.InvalidPacket;
                };

                const conn = self.internal_conn orelse return types_mod.QuicError.InvalidState;
                const ok = conn.onNewConnectionId(
                    decoded.frame.sequence_number,
                    decoded.frame.retire_prior_to,
                    decoded.frame.connection_id,
                    decoded.frame.stateless_reset_token,
                ) catch {
                    return types_mod.QuicError.OutOfMemory;
                };

                if (!ok) {
                    return types_mod.QuicError.ProtocolViolation;
                }

                return decoded.consumed;
            },
            0x19 => {
                const decoded = frame_mod.RetireConnectionIdFrame.decode(payload) catch {
                    return types_mod.QuicError.InvalidPacket;
                };

                const conn = self.internal_conn orelse return types_mod.QuicError.InvalidState;
                if (!conn.onRetireConnectionId(decoded.frame.sequence_number)) {
                    return types_mod.QuicError.ProtocolViolation;
                }

                return decoded.consumed;
            },
            0x04 => {
                const decoded = frame_mod.ResetStreamFrame.decode(payload) catch {
                    return types_mod.QuicError.InvalidPacket;
                };

                const conn = self.internal_conn orelse return types_mod.QuicError.InvalidState;
                const stream = conn.getOrCreateStream(decoded.frame.stream_id) catch {
                    return types_mod.QuicError.StreamError;
                };

                stream.onResetReceived(decoded.frame.final_size) catch {
                    return types_mod.QuicError.ProtocolViolation;
                };

                try self.events.append(self.allocator, .{
                    .stream_closed = .{
                        .id = decoded.frame.stream_id,
                        .error_code = decoded.frame.error_code,
                    },
                });
                return decoded.consumed;
            },
            0x05 => {
                const decoded = frame_mod.StopSendingFrame.decode(payload) catch {
                    return types_mod.QuicError.InvalidPacket;
                };

                const conn = self.internal_conn orelse return types_mod.QuicError.InvalidState;
                const stream = conn.getOrCreateStream(decoded.frame.stream_id) catch {
                    return types_mod.QuicError.StreamError;
                };
                stream.reset(decoded.frame.error_code);
                return decoded.consumed;
            },
            0x1a => {
                const decoded = frame_mod.PathChallengeFrame.decode(payload) catch {
                    return types_mod.QuicError.InvalidPacket;
                };

                const conn = self.internal_conn orelse return types_mod.QuicError.InvalidState;
                conn.onPathChallenge(decoded.frame.data) catch {
                    return types_mod.QuicError.OutOfMemory;
                };
                return decoded.consumed;
            },
            0x1b => {
                const decoded = frame_mod.PathResponseFrame.decode(payload) catch {
                    return types_mod.QuicError.InvalidPacket;
                };

                const conn = self.internal_conn orelse return types_mod.QuicError.InvalidState;
                _ = conn.onPathResponse(decoded.frame.data);
                return decoded.consumed;
            },
            0x07 => {
                const decoded = frame_mod.NewTokenFrame.decode(payload) catch {
                    return types_mod.QuicError.InvalidPacket;
                };

                if (self.config.role == .server) {
                    return types_mod.QuicError.ProtocolViolation;
                }

                try self.storeNewToken(decoded.frame.token);
                return decoded.consumed;
            },
            0x1e => {
                const decoded = frame_mod.HandshakeDoneFrame.decode(payload) catch {
                    return types_mod.QuicError.InvalidPacket;
                };

                if (self.config.role == .server) {
                    return types_mod.QuicError.ProtocolViolation;
                }

                return decoded.consumed;
            },
            else => {
                // Unknown/unhandled frame type in this slice: ignore.
                return payload.len;
            },
        }
    }

    fn encodeLocalTransportParams(self: *QuicConnection) types_mod.QuicError![]u8 {
        var params = transport_params_mod.TransportParams.init();
        params.max_idle_timeout = self.config.max_idle_timeout;
        params.initial_max_data = self.config.initial_max_data;
        params.initial_max_stream_data_bidi_local = self.config.initial_max_stream_data_bidi_local;
        params.initial_max_stream_data_bidi_remote = self.config.initial_max_stream_data_bidi_remote;
        params.initial_max_stream_data_uni = self.config.initial_max_stream_data_uni;
        params.initial_max_streams_bidi = self.config.max_bidi_streams;
        params.initial_max_streams_uni = self.config.max_uni_streams;

        return params.encode(self.allocator) catch {
            return types_mod.QuicError.InvalidConfig;
        };
    }

    /// Start connecting (client only)
    pub fn connect(
        self: *QuicConnection,
        remote_address: []const u8,
        remote_port: u16,
    ) types_mod.QuicError!void {
        if (self.config.role != .client) {
            return types_mod.QuicError.InvalidState;
        }

        if (self.state != .idle) {
            return types_mod.QuicError.InvalidState;
        }

        // Parse address
        const addr = std.net.Address.parseIp(remote_address, remote_port) catch {
            return types_mod.QuicError.InvalidAddress;
        };
        self.remote_addr = addr;

        // Create UDP socket
        const socket = try self.allocator.create(udp_mod.UdpSocket);
        errdefer self.allocator.destroy(socket);

        socket.* = udp_mod.UdpSocket.bindAny(self.allocator, 0) catch {
            return types_mod.QuicError.SocketError;
        };
        self.socket = socket;

        // Create crypto context
        const crypto_ctx = try self.allocator.create(crypto_mod.CryptoContext);
        errdefer self.allocator.destroy(crypto_ctx);

        const crypto_mode: crypto_mod.CryptoMode = switch (self.config.mode) {
            .ssh => .ssh,
            .tls => .tls,
        };

        crypto_ctx.* = crypto_mod.CryptoContext.init(
            self.allocator,
            crypto_mode,
            crypto_mod.CipherSuite.TLS_AES_128_GCM_SHA256,
        );
        self.crypto_ctx = crypto_ctx;

        // Create internal connection
        const internal_conn = try self.allocator.create(conn_internal.Connection);
        errdefer self.allocator.destroy(internal_conn);

        // Generate connection IDs
        var local_cid_bytes: [8]u8 = undefined;
        std.crypto.random.bytes(&local_cid_bytes);
        const local_cid = core_types.ConnectionId.init(&local_cid_bytes) catch {
            return types_mod.QuicError.InvalidConfig;
        };

        var remote_cid_bytes: [8]u8 = undefined;
        std.crypto.random.bytes(&remote_cid_bytes);
        const remote_cid = core_types.ConnectionId.init(&remote_cid_bytes) catch {
            return types_mod.QuicError.InvalidConfig;
        };

        const quic_mode: core_types.QuicMode = switch (self.config.mode) {
            .ssh => .ssh,
            .tls => .tls,
        };

        internal_conn.* = conn_internal.Connection.initClient(
            self.allocator,
            quic_mode,
            local_cid,
            remote_cid,
        ) catch {
            return types_mod.QuicError.InvalidConfig;
        };
        self.internal_conn = internal_conn;

        if (self.config.mode == .tls) {
            const tls_cfg = self.config.tls_config orelse return types_mod.QuicError.MissingTlsConfig;

            const encoded_tp = try self.encodeLocalTransportParams();
            defer self.allocator.free(encoded_tp);

            const tls_ctx = try self.allocator.create(tls_context_mod.TlsContext);
            errdefer self.allocator.destroy(tls_ctx);
            tls_ctx.* = tls_context_mod.TlsContext.init(self.allocator, true);

            const client_hello = tls_ctx.startClientHandshakeWithParams(
                tls_cfg.server_name,
                tls_cfg.alpn_protocols,
                encoded_tp,
            ) catch {
                tls_ctx.deinit();
                return types_mod.QuicError.HandshakeFailed;
            };
            defer self.allocator.free(client_hello);

            self.tls_ctx = tls_ctx;
            self.tls_server_hello_applied = false;
        }

        self.state = .connecting;
    }

    /// Accept incoming connection (server only)
    pub fn accept(
        self: *QuicConnection,
        bind_address: []const u8,
        bind_port: u16,
    ) types_mod.QuicError!void {
        if (self.config.role != .server) {
            return types_mod.QuicError.InvalidState;
        }

        if (self.state != .idle) {
            return types_mod.QuicError.InvalidState;
        }

        // Parse bind address
        const addr = std.net.Address.parseIp(bind_address, bind_port) catch {
            return types_mod.QuicError.InvalidAddress;
        };

        // Create and bind UDP socket
        const socket = try self.allocator.create(udp_mod.UdpSocket);
        errdefer self.allocator.destroy(socket);

        socket.* = udp_mod.UdpSocket.bind(self.allocator, addr) catch {
            return types_mod.QuicError.SocketError;
        };
        self.socket = socket;

        // Create crypto context
        const crypto_ctx = try self.allocator.create(crypto_mod.CryptoContext);
        errdefer self.allocator.destroy(crypto_ctx);

        const crypto_mode: crypto_mod.CryptoMode = switch (self.config.mode) {
            .ssh => .ssh,
            .tls => .tls,
        };

        crypto_ctx.* = crypto_mod.CryptoContext.init(
            self.allocator,
            crypto_mode,
            crypto_mod.CipherSuite.TLS_AES_128_GCM_SHA256,
        );
        self.crypto_ctx = crypto_ctx;

        self.state = .connecting;
    }

    /// Open a new stream
    pub fn openStream(
        self: *QuicConnection,
        bidirectional: bool,
    ) types_mod.QuicError!types_mod.StreamId {
        if (!self.isHandshakeNegotiated()) {
            return types_mod.QuicError.ConnectionNotEstablished;
        }

        const caps = self.getModeCapabilities();
        if (!bidirectional and !caps.supports_unidirectional_streams) {
            return types_mod.QuicError.StreamError;
        }

        if (self.internal_conn == null) {
            return types_mod.QuicError.InvalidState;
        }

        const conn = self.internal_conn.?;

        const stream_id = conn.openStream(bidirectional) catch |err| {
            return switch (err) {
                error.UnsupportedStreamType => types_mod.QuicError.StreamError,
                error.StreamError => types_mod.QuicError.StreamLimitReached,
                else => types_mod.QuicError.StreamError,
            };
        };

        // Add event
        try self.events.append(self.allocator, .{ .stream_opened = stream_id });

        return stream_id;
    }

    /// Write data to stream
    pub fn streamWrite(
        self: *QuicConnection,
        stream_id: types_mod.StreamId,
        data: []const u8,
        finish: types_mod.StreamFinish,
    ) types_mod.QuicError!usize {
        if (!self.isHandshakeNegotiated()) {
            return types_mod.QuicError.ConnectionNotEstablished;
        }

        const conn = self.internal_conn orelse return types_mod.QuicError.InvalidState;

        // Get stream
        const stream = conn.getStream(stream_id) orelse return types_mod.QuicError.StreamNotFound;

        const budget = conn.availableSendBudget();
        if (budget == 0) {
            return types_mod.QuicError.FlowControlError;
        }

        const write_len: usize = @intCast(@min(@as(u64, data.len), budget));
        const write_data = data[0..write_len];

        // Write data to stream
        const written = stream.write(write_data) catch {
            return types_mod.QuicError.StreamError;
        };

        conn.updateDataSent(written);
        conn.trackPacketSent(written, true);

        // Handle finish flag
        if (finish == .finish) {
            stream.finish();
        }

        return written;
    }

    /// Read data from stream
    pub fn streamRead(
        self: *QuicConnection,
        stream_id: types_mod.StreamId,
        buffer: []u8,
    ) types_mod.QuicError!usize {
        if (!self.isHandshakeNegotiated()) {
            return types_mod.QuicError.ConnectionNotEstablished;
        }

        const conn = self.internal_conn orelse return types_mod.QuicError.InvalidState;

        // Get stream
        const stream = conn.getStream(stream_id) orelse return types_mod.QuicError.StreamNotFound;

        // Read data from stream
        const read_count = stream.read(buffer) catch |err| {
            return switch (err) {
                error.StreamNotReadable => types_mod.QuicError.StreamClosed,
                error.WouldBlock => types_mod.QuicError.StreamError,
                else => types_mod.QuicError.StreamError,
            };
        };

        return read_count;
    }

    /// Close a stream
    pub fn closeStream(
        self: *QuicConnection,
        stream_id: types_mod.StreamId,
        error_code: u64,
    ) types_mod.QuicError!void {
        if (!self.isHandshakeNegotiated()) {
            return types_mod.QuicError.ConnectionNotEstablished;
        }

        const conn = self.internal_conn orelse return types_mod.QuicError.InvalidState;

        // Get stream
        const stream = conn.getStream(stream_id) orelse return types_mod.QuicError.StreamNotFound;

        _ = error_code;

        // Graceful close: send FIN (half-close), keep receive side open.
        stream.finish();

        if (stream.isClosed()) {
            try self.events.append(self.allocator, .{ .stream_closed = .{ .id = stream_id, .error_code = null } });
        }
    }

    /// Get stream information
    pub fn getStreamInfo(
        self: *QuicConnection,
        stream_id: types_mod.StreamId,
    ) types_mod.QuicError!types_mod.StreamInfo {
        const conn = self.internal_conn orelse return types_mod.QuicError.InvalidState;

        const stream = conn.getStream(stream_id) orelse return types_mod.QuicError.StreamNotFound;

        const is_bidi = stream.isBidirectional();

        const send_closed = switch (stream.send_state) {
            .data_sent, .reset_sent, .reset_recvd => true,
            else => false,
        };
        const recv_closed = switch (stream.recv_state) {
            .data_recvd, .data_read, .reset_recvd, .reset_read => true,
            else => false,
        };

        const state: types_mod.StreamState = if (send_closed and recv_closed)
            .closed
        else if (send_closed)
            .send_closed
        else if (recv_closed)
            .recv_closed
        else
            .open;

        return types_mod.StreamInfo{
            .id = stream_id,
            .state = state,
            .is_bidirectional = is_bidi,
            .bytes_sent = stream.send_offset,
            .bytes_received = stream.recv_offset,
            .send_buffer_available = 0,
            .recv_buffer_available = 0,
        };
    }

    /// Process I/O and internal state
    pub fn poll(self: *QuicConnection) types_mod.QuicError!void {
        if (self.state == .closed) {
            return types_mod.QuicError.ConnectionClosed;
        }

        if (self.state == .draining) {
            const now = time_mod.Instant.now();
            const deadline = self.drain_deadline orelse now;

            if (!drain_deadline_expired(now, deadline)) {
                self.drain_pending = false;
                return;
            }

            self.state = .closed;
            self.drain_deadline = null;
            if (self.internal_conn) |conn| {
                conn.markClosed();
            }

            if (!self.closed_event_emitted) {
                self.closed_event_emitted = true;
                try self.events.append(self.allocator, .{ .closed = {} });
            }
            return;
        }

        if (self.internal_conn) |conn| {
            conn.onPtoTimeout(time_mod.Instant.now());
        }

        // Process at most one received datagram
        if (self.socket) |socket| {
            var recv_buffer: [4096]u8 = undefined;
            const recv_result = socket.recvFrom(&recv_buffer) catch |err| {
                if (err == error.WouldBlock) {
                    return;
                }
                return types_mod.QuicError.NetworkError;
            };

            const packet = recv_buffer[0..recv_result.bytes];
            self.packets_received += 1;

            if (self.internal_conn) |conn| {
                conn.updateDataReceived(packet.len);
            }

            const vn_handled = self.handleVersionNegotiationPacket(packet) catch {
                self.packets_invalid += 1;
                try self.queueProtocolViolation("invalid version negotiation packet");
                return;
            };

            if (vn_handled) {
                return;
            }

            const header = self.decodePacketHeader(packet) catch |err| {
                self.packets_invalid += 1;

                if (self.detectStatelessResetRaw(packet)) {
                    try self.enterDraining(@intFromEnum(core_types.ErrorCode.no_error), "stateless reset");
                    return;
                }

                if (err == types_mod.QuicError.ProtocolViolation) {
                    try self.queueProtocolViolation("unsupported version");
                    return;
                }

                try self.queueProtocolViolation("invalid packet header");
                return;
            };

            if (self.config.role == .server and header.packet_space == .initial and header.initial_token.len > 0) {
                if (!self.validateToken(header.initial_token)) {
                    self.packets_invalid += 1;
                    try self.queueInvalidToken("initial token rejected");
                    return;
                }
            }

            if (header.packet_space == .retry) {
                try self.handleRetryPacket(header);
                return;
            }

            if (header.consumed >= packet.len) return;

            try self.transitionToEstablished();

            var frame_offset = header.consumed;
            while (frame_offset < packet.len) {
                const consumed = self.routeFrame(packet[frame_offset..], header.packet_space) catch |err| {
                    self.packets_invalid += 1;
                    if (self.detectStatelessReset(packet, header)) {
                        try self.enterDraining(@intFromEnum(core_types.ErrorCode.no_error), "stateless reset");
                        return;
                    }

                    if (err == types_mod.QuicError.ProtocolViolation) {
                        try self.queueProtocolViolation("frame not allowed in current context");
                        return;
                    }

                    if (err == types_mod.QuicError.FlowControlError) {
                        try self.queueFlowControlError("stream flow control exceeded");
                        return;
                    }

                    try self.queueProtocolViolation("invalid frame payload");
                    return;
                };

                if (consumed == 0 or consumed > (packet.len - frame_offset)) {
                    self.packets_invalid += 1;
                    try self.queueProtocolViolation("invalid frame length");
                    return;
                }

                frame_offset += consumed;

                if (self.state == .draining or self.state == .closed) {
                    return;
                }
            }
        }
    }

    /// Decode and apply peer transport parameters.
    ///
    /// Both TLS and SSH-like handshake code paths can call this once peer
    /// transport parameters are available. Invalid transport parameters
    /// transition the connection into draining with transport_parameter_error.
    pub fn applyPeerTransportParams(self: *QuicConnection, encoded_params: []const u8) types_mod.QuicError!void {
        const decoded = transport_params_mod.TransportParams.decode(self.allocator, encoded_params) catch {
            try self.queueTransportParameterError("invalid peer transport params");
            return types_mod.QuicError.ProtocolViolation;
        };

        const conn = self.internal_conn orelse return types_mod.QuicError.InvalidState;

        conn.setRemoteParams(.{
            .max_idle_timeout = decoded.max_idle_timeout,
            .max_udp_payload_size = decoded.max_udp_payload_size,
            .initial_max_data = decoded.initial_max_data,
            .initial_max_stream_data_bidi_local = decoded.initial_max_stream_data_bidi_local,
            .initial_max_stream_data_bidi_remote = decoded.initial_max_stream_data_bidi_remote,
            .initial_max_stream_data_uni = decoded.initial_max_stream_data_uni,
            .initial_max_streams_bidi = decoded.initial_max_streams_bidi,
            .initial_max_streams_uni = decoded.initial_max_streams_uni,
            .ack_delay_exponent = decoded.ack_delay_exponent,
            .max_ack_delay = decoded.max_ack_delay,
            .disable_active_migration = decoded.disable_active_migration,
            .active_connection_id_limit = decoded.active_connection_id_limit,
        });
    }

    /// Processes TLS ServerHello, completes TLS handshake, and applies peer
    /// QUIC transport parameters carried in TLS extensions.
    pub fn processTlsServerHello(self: *QuicConnection, server_hello_data: []const u8, shared_secret: []const u8) types_mod.QuicError!void {
        if (self.config.mode != .tls) {
            return types_mod.QuicError.InvalidState;
        }

        const tls_ctx = self.tls_ctx orelse return types_mod.QuicError.InvalidState;

        tls_ctx.processServerHello(server_hello_data) catch |err| {
            try self.queueTlsFailure(.server_hello, err);
            return types_mod.QuicError.HandshakeFailed;
        };

        tls_ctx.completeHandshake(shared_secret) catch |err| {
            try self.queueTlsFailure(.complete, err);
            return types_mod.QuicError.HandshakeFailed;
        };

        const peer_tp = tls_ctx.getPeerTransportParams() orelse {
            try self.queueTransportParameterError("missing peer transport params in tls extensions");
            return types_mod.QuicError.HandshakeFailed;
        };

        try self.applyPeerTransportParams(peer_tp);
        self.tls_server_hello_applied = true;
    }

    /// Processes a TLS ClientHello in server mode and returns an encoded
    /// ServerHello response generated from server policy.
    pub fn processTlsClientHello(
        self: *QuicConnection,
        client_hello_data: []const u8,
        server_supported_alpn: []const []const u8,
    ) types_mod.QuicError![]u8 {
        if (self.config.mode != .tls) {
            return types_mod.QuicError.InvalidState;
        }

        if (self.config.role != .server) {
            return types_mod.QuicError.InvalidState;
        }

        const tls_cfg = self.config.tls_config orelse return types_mod.QuicError.MissingTlsConfig;

        const tls_ctx = if (self.tls_ctx) |ctx|
            ctx
        else blk: {
            const created = try self.allocator.create(tls_context_mod.TlsContext);
            created.* = tls_context_mod.TlsContext.init(self.allocator, false);
            self.tls_ctx = created;
            break :blk created;
        };

        const server_tp = try self.encodeLocalTransportParams();
        defer self.allocator.free(server_tp);

        const server_hello = tls_ctx.buildServerHelloFromClientHello(
            client_hello_data,
            if (server_supported_alpn.len > 0) server_supported_alpn else tls_cfg.alpn_protocols,
            server_tp,
        ) catch |err| {
            try self.queueTlsFailure(.client_hello, err);
            return types_mod.QuicError.HandshakeFailed;
        };

        const peer_tp = tls_ctx.getPeerTransportParams() orelse {
            try self.queueTransportParameterError("missing peer transport params in tls client hello");
            self.allocator.free(server_hello);
            return types_mod.QuicError.HandshakeFailed;
        };

        try self.applyPeerTransportParams(peer_tp);
        self.tls_server_hello_applied = true;

        return server_hello;
    }

    /// Completes TLS key schedule on either client or server side after
    /// ServerHello processing is done.
    pub fn completeTlsHandshake(self: *QuicConnection, shared_secret: []const u8) types_mod.QuicError!void {
        if (self.config.mode != .tls) {
            return types_mod.QuicError.InvalidState;
        }

        const tls_ctx = self.tls_ctx orelse return types_mod.QuicError.InvalidState;
        tls_ctx.completeHandshake(shared_secret) catch |err| {
            try self.queueTlsFailure(.complete, err);
            return types_mod.QuicError.HandshakeFailed;
        };
    }

    /// Get next connection event
    pub fn nextEvent(self: *QuicConnection) ?types_mod.ConnectionEvent {
        if (self.events.items.len == 0) {
            return null;
        }

        return self.events.orderedRemove(0);
    }

    /// Get connection statistics
    pub fn getStats(self: *QuicConnection) types_mod.ConnectionStats {
        var stats = types_mod.ConnectionStats{};
        stats.packets_received = self.packets_received;
        stats.packets_invalid = self.packets_invalid;
        const elapsed_us = time_mod.Instant.now().durationSince(self.created_at);
        stats.duration_ms = @divFloor(elapsed_us, time_mod.Duration.MILLISECOND);

        if (self.internal_conn) |conn| {
            stats.packets_sent = conn.next_packet_number;
            stats.bytes_sent = conn.data_sent;
            stats.bytes_received = conn.data_received;
            stats.active_streams = @intCast(conn.streams.streams.count());
            stats.rtt = conn.loss_detection.getSmoothedRtt();
        }

        return stats;
    }

    /// Get connection state
    pub fn getState(self: *QuicConnection) types_mod.ConnectionState {
        return self.state;
    }

    /// Returns negotiated ALPN protocol when available.
    pub fn getNegotiatedAlpn(self: *const QuicConnection) ?[]const u8 {
        return self.negotiated_alpn;
    }

    /// Returns the latest token received in a NEW_TOKEN frame.
    pub fn getLatestNewToken(self: *const QuicConnection) ?[]const u8 {
        return self.latest_new_token;
    }

    /// Returns the latest token received from a Retry packet.
    pub fn getRetryToken(self: *const QuicConnection) ?[]const u8 {
        return self.retry_token;
    }

    /// Returns the latest Retry source connection ID advertised by peer.
    pub fn getRetrySourceConnectionId(self: *const QuicConnection) ?[]const u8 {
        if (self.retry_source_conn_id) |*cid| {
            return cid.slice();
        }
        return null;
    }

    /// Clears the currently cached NEW_TOKEN value.
    pub fn clearLatestNewToken(self: *QuicConnection) void {
        if (self.latest_new_token) |token| {
            self.allocator.free(token);
            self.latest_new_token = null;
        }
    }

    /// Clears the currently cached Retry token value.
    pub fn clearRetryToken(self: *QuicConnection) void {
        if (self.retry_token) |token| {
            self.allocator.free(token);
            self.retry_token = null;
        }
    }

    /// Configures application token validation for Initial packets.
    ///
    /// The validator is called only when a server receives an Initial packet
    /// that carries a non-empty token.
    pub fn setTokenValidator(
        self: *QuicConnection,
        ctx: ?*anyopaque,
        validator: *const fn (ctx: ?*anyopaque, token: []const u8) bool,
    ) void {
        self.token_validator_ctx = ctx;
        self.token_validator = validator;
    }

    /// Configures client-side Retry integrity validation callback.
    ///
    /// The callback is invoked when a Retry packet is received while connecting.
    /// Returning false triggers deterministic protocol violation close behavior.
    pub fn setRetryIntegrityValidator(
        self: *QuicConnection,
        ctx: ?*anyopaque,
        validator: *const fn (ctx: ?*anyopaque, token: []const u8, retry_source_conn_id: core_types.ConnectionId) bool,
    ) void {
        self.retry_validator_ctx = ctx;
        self.retry_validator = validator;
    }

    /// Returns true when handshake negotiation is complete enough to gate app traffic.
    ///
    /// For TLS mode this requires:
    /// - connection established state
    /// - TLS handshake complete
    /// - peer transport parameters applied
    ///
    /// For SSH mode this requires:
    /// - connection established state
    /// - peer transport parameters applied
    pub fn isHandshakeNegotiated(self: *const QuicConnection) bool {
        if (self.state != .established) {
            return false;
        }

        const caps = self.getModeCapabilities();
        const negotiation = self.buildNegotiationResult();
        if (!negotiation.has_peer_transport_params and caps.requires_peer_transport_params) {
            return false;
        }

        if (negotiation.mode == .tls and caps.requires_integrated_tls_server_hello and !negotiation.tls_server_hello_applied) {
            return false;
        }

        return negotiation.ready_for_establish;
    }

    pub fn getModeCapabilities(self: *const QuicConnection) types_mod.ModeCapabilities {
        return types_mod.ModeCapabilities.forMode(self.negotiationMode());
    }

    pub fn getNegotiationResult(self: *const QuicConnection) types_mod.NegotiationResult {
        return self.buildNegotiationResult();
    }

    /// Returns number of currently tracked peer-issued connection IDs.
    pub fn getPeerConnectionIdCount(self: *const QuicConnection) usize {
        const conn = self.internal_conn orelse return 0;
        return conn.peer_connection_ids.items.len;
    }

    /// Returns peer connection ID metadata by index.
    pub fn getPeerConnectionIdInfo(self: *const QuicConnection, index: usize) ?types_mod.PeerConnectionIdInfo {
        const conn = self.internal_conn orelse return null;
        if (index >= conn.peer_connection_ids.items.len) return null;

        const entry = conn.peer_connection_ids.items[index];
        return .{
            .sequence_number = entry.sequence_number,
            .connection_id = entry.connection_id.data,
            .connection_id_len = entry.connection_id.len,
            .stateless_reset_token = entry.stateless_reset_token,
        };
    }

    /// Pop next pending RETIRE_CONNECTION_ID sequence requested by peer CID updates.
    pub fn popRetireConnectionId(self: *QuicConnection) ?u64 {
        const conn = self.internal_conn orelse return null;
        return conn.popRetireConnectionId();
    }

    /// Pop and encode next pending RETIRE_CONNECTION_ID frame.
    ///
    /// Returns the encoded frame length, or null if no pending retire request
    /// exists.
    pub fn popRetireConnectionIdFrame(self: *QuicConnection, out: []u8) types_mod.QuicError!?usize {
        const seq = self.popRetireConnectionId() orelse return null;
        const frame = frame_mod.RetireConnectionIdFrame{ .sequence_number = seq };
        const len = frame.encode(out) catch {
            return types_mod.QuicError.InvalidPacket;
        };
        return len;
    }

    /// Queue a local connection ID for NEW_CONNECTION_ID advertisement.
    pub fn queueNewConnectionId(
        self: *QuicConnection,
        connection_id_bytes: []const u8,
        stateless_reset_token: [16]u8,
    ) types_mod.QuicError!u64 {
        const conn = self.internal_conn orelse return types_mod.QuicError.InvalidState;
        const connection_id = core_types.ConnectionId.init(connection_id_bytes) catch {
            return types_mod.QuicError.InvalidPacket;
        };

        return conn.queueNewConnectionId(connection_id, stateless_reset_token) catch {
            return types_mod.QuicError.OutOfMemory;
        };
    }

    /// Encode latest queued NEW_CONNECTION_ID advertisement frame.
    pub fn encodeLatestNewConnectionIdFrame(self: *QuicConnection, out: []u8) types_mod.QuicError!?usize {
        const conn = self.internal_conn orelse return types_mod.QuicError.InvalidState;
        const latest = conn.latestLocalConnectionId() orelse return null;

        const frame = frame_mod.NewConnectionIdFrame{
            .sequence_number = latest.sequence_number,
            .retire_prior_to = conn.localRetirePriorTo(),
            .connection_id = latest.connection_id,
            .stateless_reset_token = latest.stateless_reset_token,
        };

        const len = frame.encode(out) catch {
            return types_mod.QuicError.InvalidPacket;
        };
        return len;
    }

    /// Pop and encode next pending NEW_CONNECTION_ID advertisement frame.
    pub fn popNewConnectionIdFrame(self: *QuicConnection, out: []u8) types_mod.QuicError!?usize {
        const conn = self.internal_conn orelse return types_mod.QuicError.InvalidState;
        const next = conn.popPendingNewConnectionId() orelse return null;

        const frame = frame_mod.NewConnectionIdFrame{
            .sequence_number = next.sequence_number,
            .retire_prior_to = conn.localRetirePriorTo(),
            .connection_id = next.connection_id,
            .stateless_reset_token = next.stateless_reset_token,
        };

        const len = frame.encode(out) catch {
            return types_mod.QuicError.InvalidPacket;
        };
        return len;
    }

    /// Encodes pending CID-control frames into a single payload buffer.
    ///
    /// At most one RETIRE_CONNECTION_ID and one NEW_CONNECTION_ID are encoded,
    /// in that order. Returns null when nothing is pending.
    pub fn popCidControlFrames(self: *QuicConnection, out: []u8) types_mod.QuicError!?usize {
        var pos: usize = 0;

        if (try self.popRetireConnectionIdFrame(out[pos..])) |retire_len| {
            pos += retire_len;
        }

        if (try self.popNewConnectionIdFrame(out[pos..])) |new_cid_len| {
            pos += new_cid_len;
        }

        if (pos == 0) return null;
        return pos;
    }

    /// Drain pending CID-control frames into a fixed output array.
    ///
    /// Each entry in `out_frames` receives one coalesced payload as produced by
    /// `popCidControlFrames`. Returns how many entries were filled.
    pub fn popAllCidControlFrames(
        self: *QuicConnection,
        out_frames: [][]u8,
    ) types_mod.QuicError!usize {
        var filled: usize = 0;
        while (filled < out_frames.len) : (filled += 1) {
            const out = out_frames[filled];
            const len = try self.popCidControlFrames(out) orelse break;
            out_frames[filled] = out[0..len];
        }
        return filled;
    }

    /// Advance local retire_prior_to used for NEW_CONNECTION_ID advertisements.
    pub fn advanceLocalRetirePriorTo(self: *QuicConnection, sequence_number: u64) types_mod.QuicError!void {
        const conn = self.internal_conn orelse return types_mod.QuicError.InvalidState;
        conn.advanceLocalRetirePriorTo(sequence_number);
    }

    /// Returns a point-in-time negotiation snapshot.
    pub fn getNegotiationSnapshot(self: *const QuicConnection) ?types_mod.NegotiationSnapshot {
        const conn = self.internal_conn orelse return null;
        const remote_params = conn.remote_params orelse core_types.TransportParameters{};

        const mode = self.negotiationMode();

        return .{
            .mode = mode,
            .is_established = self.state == .established,
            .alpn = self.negotiated_alpn,
            .peer_max_idle_timeout = remote_params.max_idle_timeout,
            .peer_max_udp_payload_size = remote_params.max_udp_payload_size,
            .peer_initial_max_data = remote_params.initial_max_data,
            .peer_initial_max_streams_bidi = remote_params.initial_max_streams_bidi,
            .peer_initial_max_streams_uni = remote_params.initial_max_streams_uni,
        };
    }

    /// Close the connection gracefully
    pub fn close(
        self: *QuicConnection,
        error_code: u64,
        reason: []const u8,
    ) types_mod.QuicError!void {
        if (self.state == .closed) {
            return;
        }

        if (self.internal_conn) |conn| {
            conn.close(error_code, reason);
        }

        self.enterDraining(error_code, reason) catch {};
    }

    /// Clean up resources
    pub fn deinit(self: *QuicConnection) void {
        if (self.state != .closed) {
            self.close(0, "Connection closed") catch {};
        }

        self.clearLatestNewToken();
        self.clearRetryToken();

        if (self.internal_conn) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }

        if (self.socket) |socket| {
            socket.close();
            self.allocator.destroy(socket);
        }

        if (self.crypto_ctx) |ctx| {
            ctx.deinit();
            self.allocator.destroy(ctx);
        }

        if (self.tls_ctx) |ctx| {
            ctx.deinit();
            self.allocator.destroy(ctx);
        }

        self.events.deinit(self.allocator);
        self.state = .closed;
    }
};

// Tests

fn applyDefaultPeerTransportParams(conn: *QuicConnection, allocator: std.mem.Allocator) !void {
    const encoded = try transport_params_mod.TransportParams.defaultServer().encode(allocator);
    defer allocator.free(encoded);
    try conn.applyPeerTransportParams(encoded);
}

fn applyPeerTransportParamsWithLimits(conn: *QuicConnection, allocator: std.mem.Allocator, max_bidi: u64, max_uni: u64) !void {
    var params = transport_params_mod.TransportParams.defaultServer();
    params.initial_max_streams_bidi = max_bidi;
    params.initial_max_streams_uni = max_uni;

    const encoded = try params.encode(allocator);
    defer allocator.free(encoded);
    try conn.applyPeerTransportParams(encoded);
}

fn expectTransportParamProtocolViolation(conn: *QuicConnection, encoded_params: []const u8) !void {
    try std.testing.expectError(types_mod.QuicError.ProtocolViolation, conn.applyPeerTransportParams(encoded_params));
    try std.testing.expectEqual(types_mod.ConnectionState.draining, conn.getState());

    var closing: ?types_mod.ConnectionEvent = null;
    while (conn.nextEvent()) |event| {
        if (event == .closing) {
            closing = event;
            break;
        }
    }

    try std.testing.expect(closing != null);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.transport_parameter_error)),
        closing.?.closing.error_code,
    );
}

fn buildTlsServerHelloForTests(
    allocator: std.mem.Allocator,
    alpn: []const u8,
    tp_payload: []const u8,
) ![]u8 {
    var alpn_wire: [8]u8 = undefined;
    if (alpn.len == 0 or alpn.len > 5) return error.InvalidInput;

    alpn_wire[0] = 0x00;
    alpn_wire[1] = @intCast(alpn.len + 1);
    alpn_wire[2] = @intCast(alpn.len);
    @memcpy(alpn_wire[3 .. 3 + alpn.len], alpn);

    const ext = [_]tls_handshake_mod.Extension{
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.application_layer_protocol_negotiation),
            .extension_data = alpn_wire[0 .. 3 + alpn.len],
        },
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.quic_transport_parameters),
            .extension_data = tp_payload,
        },
    };

    const random: [32]u8 = [_]u8{61} ** 32;
    const server_hello = tls_handshake_mod.ServerHello{
        .random = random,
        .cipher_suite = tls_handshake_mod.TLS_AES_128_GCM_SHA256,
        .extensions = &ext,
    };

    return server_hello.encode(allocator);
}

fn tokenEqualsValidator(ctx: ?*anyopaque, token: []const u8) bool {
    const expected_ptr = ctx orelse return false;
    const expected: *const []const u8 = @ptrCast(@alignCast(expected_ptr));
    return std.mem.eql(u8, expected.*, token);
}

fn expectProtocolViolationFromShortHeaderPayload(
    conn: *QuicConnection,
    allocator: std.mem.Allocator,
    payload: []const u8,
    packet_number: u64,
) !void {
    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = packet_number,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    if (packet_len + payload.len > packet_buf.len) {
        return error.BufferTooSmall;
    }
    @memcpy(packet_buf[packet_len .. packet_len + payload.len], payload);
    packet_len += payload.len;

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    var closing: ?types_mod.ConnectionEvent = null;
    while (conn.nextEvent()) |event| {
        if (event == .closing) {
            closing = event;
            break;
        }
    }

    try std.testing.expect(closing != null);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        closing.?.closing.error_code,
    );
}

fn expectProtocolViolationFromLongHeaderPayload(
    conn: *QuicConnection,
    allocator: std.mem.Allocator,
    packet_type: core_types.PacketType,
    payload: []const u8,
    packet_number: u64,
) !void {
    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = packet_type,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = if (packet_type == .initial) &.{} else &.{},
        .payload_len = @as(u64, payload.len + 4),
        .packet_number = packet_number,
    };

    var packet_len = try header.encode(&packet_buf);
    if (packet_len + payload.len > packet_buf.len) {
        return error.BufferTooSmall;
    }
    @memcpy(packet_buf[packet_len .. packet_len + payload.len], payload);
    packet_len += payload.len;

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    var closing: ?types_mod.ConnectionEvent = null;
    while (conn.nextEvent()) |event| {
        if (event == .closing) {
            closing = event;
            break;
        }
    }

    try std.testing.expect(closing != null);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        closing.?.closing.error_code,
    );
}

test "Create SSH client connection" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "my-secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try std.testing.expectEqual(types_mod.ConnectionState.idle, conn.state);
    try std.testing.expectEqual(config_mod.QuicMode.ssh, conn.config.mode);
}

test "Create TLS client connection" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.tlsClient("example.com");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try std.testing.expectEqual(types_mod.ConnectionState.idle, conn.state);
    try std.testing.expectEqual(config_mod.QuicMode.tls, conn.config.mode);
}

test "TLS connect wires config ALPN into ClientHello" {
    const allocator = std.testing.allocator;

    var config = config_mod.QuicConfig.tlsClient("example.com");
    var tls_cfg = config.tls_config.?;
    tls_cfg.alpn_protocols = &[_][]const u8{"h3"};
    config.tls_config = tls_cfg;

    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);
    try std.testing.expect(conn.tls_ctx != null);
    try std.testing.expect(conn.tls_ctx.?.state == .client_hello_sent);
    try std.testing.expect(std.mem.indexOf(u8, conn.tls_ctx.?.transcript.items, "h3") != null);
}

test "connected event carries negotiated ALPN metadata" {
    const allocator = std.testing.allocator;

    var config = config_mod.QuicConfig.tlsClient("example.com");
    var tls_cfg = config.tls_config.?;
    tls_cfg.alpn_protocols = &[_][]const u8{"h3"};
    config.tls_config = tls_cfg;

    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var server_params = transport_params_mod.TransportParams.defaultServer();
    server_params.initial_max_data = 4096;
    const encoded_server_params = try server_params.encode(allocator);
    defer allocator.free(encoded_server_params);

    var alpn_payload: [5]u8 = .{ 0x00, 0x03, 0x02, 'h', '3' };
    const ext = [_]tls_handshake_mod.Extension{
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.application_layer_protocol_negotiation),
            .extension_data = &alpn_payload,
        },
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.quic_transport_parameters),
            .extension_data = encoded_server_params,
        },
    };
    const random: [32]u8 = [_]u8{7} ** 32;
    const server_hello = tls_handshake_mod.ServerHello{
        .random = random,
        .cipher_suite = tls_handshake_mod.TLS_AES_128_GCM_SHA256,
        .extensions = &ext,
    };
    const server_hello_bytes = try server_hello.encode(allocator);
    defer allocator.free(server_hello_bytes);
    try conn.processTlsServerHello(server_hello_bytes, "test-shared-secret-from-ecdhe");

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .initial,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 4,
        .packet_number = 9,
    };
    var packet_len = try header.encode(&packet_buf);
    packet_buf[packet_len] = 0x01;
    packet_len += 1;
    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);

    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .connected);
    try std.testing.expect(event.?.connected.alpn != null);
    try std.testing.expectEqualStrings("h3", event.?.connected.alpn.?);
    try std.testing.expect(conn.getNegotiatedAlpn() != null);
    try std.testing.expectEqualStrings("h3", conn.getNegotiatedAlpn().?);
}

test "TLS connect remains connecting until TLS and transport params negotiated" {
    const allocator = std.testing.allocator;

    var config = config_mod.QuicConfig.tlsClient("example.com");
    var tls_cfg = config.tls_config.?;
    tls_cfg.alpn_protocols = &[_][]const u8{"h3"};
    config.tls_config = tls_cfg;

    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .initial,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 4,
        .packet_number = 10,
    };
    var packet_len = try header.encode(&packet_buf);
    packet_buf[packet_len] = 0x01;
    packet_len += 1;
    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);

    try conn.poll();
    try std.testing.expectEqual(types_mod.ConnectionState.connecting, conn.getState());
    try std.testing.expect(conn.nextEvent() == null);
}

test "processTlsServerHello applies peer transport params from tls extension" {
    const allocator = std.testing.allocator;

    var config = config_mod.QuicConfig.tlsClient("example.com");
    var tls_cfg = config.tls_config.?;
    tls_cfg.alpn_protocols = &[_][]const u8{"h3"};
    config.tls_config = tls_cfg;

    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();
    try conn.connect("127.0.0.1", 4433);

    var server_params = transport_params_mod.TransportParams.defaultServer();
    server_params.initial_max_streams_bidi = 1;
    const encoded_server_params = try server_params.encode(allocator);
    defer allocator.free(encoded_server_params);

    var alpn_payload: [5]u8 = .{ 0x00, 0x03, 0x02, 'h', '3' };
    const ext = [_]tls_handshake_mod.Extension{
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.application_layer_protocol_negotiation),
            .extension_data = &alpn_payload,
        },
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.quic_transport_parameters),
            .extension_data = encoded_server_params,
        },
    };
    const random: [32]u8 = [_]u8{31} ** 32;
    const server_hello = tls_handshake_mod.ServerHello{
        .random = random,
        .cipher_suite = tls_handshake_mod.TLS_AES_128_GCM_SHA256,
        .extensions = &ext,
    };
    const server_hello_bytes = try server_hello.encode(allocator);
    defer allocator.free(server_hello_bytes);

    try conn.processTlsServerHello(server_hello_bytes, "test-shared-secret-from-ecdhe");
    try std.testing.expect(conn.internal_conn.?.remote_params != null);
    try std.testing.expectEqual(@as(u64, 1), conn.internal_conn.?.remote_params.?.initial_max_streams_bidi);
}

test "processTlsServerHello rejects missing peer transport params extension" {
    const allocator = std.testing.allocator;

    var config = config_mod.QuicConfig.tlsClient("example.com");
    var tls_cfg = config.tls_config.?;
    tls_cfg.alpn_protocols = &[_][]const u8{"h3"};
    config.tls_config = tls_cfg;

    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();
    try conn.connect("127.0.0.1", 4433);

    var alpn_payload: [5]u8 = .{ 0x00, 0x03, 0x02, 'h', '3' };
    const ext = [_]tls_handshake_mod.Extension{
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.application_layer_protocol_negotiation),
            .extension_data = &alpn_payload,
        },
    };
    const random: [32]u8 = [_]u8{32} ** 32;
    const server_hello = tls_handshake_mod.ServerHello{
        .random = random,
        .cipher_suite = tls_handshake_mod.TLS_AES_128_GCM_SHA256,
        .extensions = &ext,
    };
    const server_hello_bytes = try server_hello.encode(allocator);
    defer allocator.free(server_hello_bytes);

    try std.testing.expectError(
        types_mod.QuicError.HandshakeFailed,
        conn.processTlsServerHello(server_hello_bytes, "test-shared-secret-from-ecdhe"),
    );
    try std.testing.expectEqual(types_mod.ConnectionState.draining, conn.getState());
}

test "processTlsClientHello builds server hello and applies peer params" {
    const allocator = std.testing.allocator;

    var server_cfg = config_mod.QuicConfig.tlsServer("cert", "key");
    var tls_server_cfg = server_cfg.tls_config.?;
    tls_server_cfg.alpn_protocols = &[_][]const u8{"h3"};
    server_cfg.tls_config = tls_server_cfg;

    var server_conn = try QuicConnection.init(allocator, server_cfg);
    defer server_conn.deinit();

    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 9, 9, 9, 9 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 1, 1, 1, 1 });
    const server_internal = try allocator.create(conn_internal.Connection);
    server_internal.* = try conn_internal.Connection.initServer(allocator, .tls, local_cid, remote_cid);
    server_conn.internal_conn = server_internal;
    server_conn.state = .connecting;

    var client_ctx = tls_context_mod.TlsContext.init(allocator, true);
    defer client_ctx.deinit();
    var client_tp = transport_params_mod.TransportParams.defaultClient();
    client_tp.initial_max_data = 7777;
    const client_tp_encoded = try client_tp.encode(allocator);
    defer allocator.free(client_tp_encoded);

    const offered = [_][]const u8{ "h2", "h3" };
    const client_hello = try client_ctx.startClientHandshakeWithParams("example.com", &offered, client_tp_encoded);
    defer allocator.free(client_hello);

    const server_hello = try server_conn.processTlsClientHello(client_hello, &[_][]const u8{});
    defer allocator.free(server_hello);

    try std.testing.expect(server_conn.tls_ctx != null);
    try std.testing.expect(server_conn.tls_ctx.?.getSelectedAlpn() != null);
    try std.testing.expectEqualStrings("h3", server_conn.tls_ctx.?.getSelectedAlpn().?);
    try std.testing.expect(server_conn.internal_conn.?.remote_params != null);
    try std.testing.expectEqual(@as(u64, 7777), server_conn.internal_conn.?.remote_params.?.initial_max_data);
}

test "processTlsClientHello rejects ALPN no-overlap" {
    const allocator = std.testing.allocator;

    var server_cfg = config_mod.QuicConfig.tlsServer("cert", "key");
    var tls_server_cfg = server_cfg.tls_config.?;
    tls_server_cfg.alpn_protocols = &[_][]const u8{"h3"};
    server_cfg.tls_config = tls_server_cfg;

    var server_conn = try QuicConnection.init(allocator, server_cfg);
    defer server_conn.deinit();

    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 2, 2, 2, 2 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 3, 3, 3, 3 });
    const server_internal = try allocator.create(conn_internal.Connection);
    server_internal.* = try conn_internal.Connection.initServer(allocator, .tls, local_cid, remote_cid);
    server_conn.internal_conn = server_internal;
    server_conn.state = .connecting;

    var client_ctx = tls_context_mod.TlsContext.init(allocator, true);
    defer client_ctx.deinit();
    const client_tp_encoded = try transport_params_mod.TransportParams.defaultClient().encode(allocator);
    defer allocator.free(client_tp_encoded);

    const offered = [_][]const u8{"h2"};
    const client_hello = try client_ctx.startClientHandshakeWithParams("example.com", &offered, client_tp_encoded);
    defer allocator.free(client_hello);

    try std.testing.expectError(
        types_mod.QuicError.HandshakeFailed,
        server_conn.processTlsClientHello(client_hello, &[_][]const u8{}),
    );
    try std.testing.expectEqual(types_mod.ConnectionState.draining, server_conn.getState());

    const event = server_conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.connection_refused)),
        event.?.closing.error_code,
    );
    try std.testing.expectEqualStrings("alpn mismatch", event.?.closing.reason);
}

test "server-side completeTlsHandshake enables negotiated readiness" {
    const allocator = std.testing.allocator;

    var server_cfg = config_mod.QuicConfig.tlsServer("cert", "key");
    var tls_server_cfg = server_cfg.tls_config.?;
    tls_server_cfg.alpn_protocols = &[_][]const u8{"h3"};
    server_cfg.tls_config = tls_server_cfg;

    var server_conn = try QuicConnection.init(allocator, server_cfg);
    defer server_conn.deinit();

    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 4, 4, 4, 4 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 5, 5, 5, 5 });
    const server_internal = try allocator.create(conn_internal.Connection);
    server_internal.* = try conn_internal.Connection.initServer(allocator, .tls, local_cid, remote_cid);
    server_conn.internal_conn = server_internal;
    server_conn.state = .connecting;

    var client_ctx = tls_context_mod.TlsContext.init(allocator, true);
    defer client_ctx.deinit();
    const client_tp_encoded = try transport_params_mod.TransportParams.defaultClient().encode(allocator);
    defer allocator.free(client_tp_encoded);

    const offered = [_][]const u8{"h3"};
    const client_hello = try client_ctx.startClientHandshakeWithParams("example.com", &offered, client_tp_encoded);
    defer allocator.free(client_hello);

    const server_hello = try server_conn.processTlsClientHello(client_hello, &[_][]const u8{});
    defer allocator.free(server_hello);

    try std.testing.expect(!server_conn.isHandshakeNegotiated());
    try server_conn.completeTlsHandshake("test-shared-secret-from-ecdhe");

    server_conn.internal_conn.?.markEstablished();
    server_conn.state = .established;
    try std.testing.expect(server_conn.isHandshakeNegotiated());
}

test "processTlsServerHello maps unsupported cipher to connection refused" {
    const allocator = std.testing.allocator;

    var config = config_mod.QuicConfig.tlsClient("example.com");
    var tls_cfg = config.tls_config.?;
    tls_cfg.alpn_protocols = &[_][]const u8{"h3"};
    config.tls_config = tls_cfg;

    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();
    try conn.connect("127.0.0.1", 4433);

    var alpn_payload: [5]u8 = .{ 0x00, 0x03, 0x02, 'h', '3' };
    const tp = try transport_params_mod.TransportParams.defaultServer().encode(allocator);
    defer allocator.free(tp);

    const ext = [_]tls_handshake_mod.Extension{
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.application_layer_protocol_negotiation),
            .extension_data = &alpn_payload,
        },
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.quic_transport_parameters),
            .extension_data = tp,
        },
    };

    const random: [32]u8 = [_]u8{91} ** 32;
    const server_hello = tls_handshake_mod.ServerHello{
        .random = random,
        .cipher_suite = 0x9999,
        .extensions = &ext,
    };
    const payload = try server_hello.encode(allocator);
    defer allocator.free(payload);

    try std.testing.expectError(types_mod.QuicError.HandshakeFailed, conn.processTlsServerHello(payload, "test-shared-secret-from-ecdhe"));
    try std.testing.expectEqual(types_mod.ConnectionState.draining, conn.getState());

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.connection_refused)),
        event.?.closing.error_code,
    );
    try std.testing.expectEqualStrings("tls unsupported cipher suite", event.?.closing.reason);
}

test "processTlsServerHello rejects malformed ALPN extension payload" {
    const allocator = std.testing.allocator;

    var config = config_mod.QuicConfig.tlsClient("example.com");
    var tls_cfg = config.tls_config.?;
    tls_cfg.alpn_protocols = &[_][]const u8{"h3"};
    config.tls_config = tls_cfg;

    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();
    try conn.connect("127.0.0.1", 4433);

    var server_params = transport_params_mod.TransportParams.defaultServer();
    const encoded_server_params = try server_params.encode(allocator);
    defer allocator.free(encoded_server_params);

    // Malformed ALPN: list length says 3, but payload has only 2 bytes after header.
    var malformed_alpn: [4]u8 = .{ 0x00, 0x03, 0x02, 'h' };
    const ext = [_]tls_handshake_mod.Extension{
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.application_layer_protocol_negotiation),
            .extension_data = &malformed_alpn,
        },
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.quic_transport_parameters),
            .extension_data = encoded_server_params,
        },
    };
    const random: [32]u8 = [_]u8{33} ** 32;
    const server_hello = tls_handshake_mod.ServerHello{
        .random = random,
        .cipher_suite = tls_handshake_mod.TLS_AES_128_GCM_SHA256,
        .extensions = &ext,
    };
    const server_hello_bytes = try server_hello.encode(allocator);
    defer allocator.free(server_hello_bytes);

    try std.testing.expectError(
        types_mod.QuicError.HandshakeFailed,
        conn.processTlsServerHello(server_hello_bytes, "test-shared-secret-from-ecdhe"),
    );
}

test "processTlsServerHello rejects zero-length selected ALPN protocol" {
    const allocator = std.testing.allocator;

    var config = config_mod.QuicConfig.tlsClient("example.com");
    var tls_cfg = config.tls_config.?;
    tls_cfg.alpn_protocols = &[_][]const u8{"h3"};
    config.tls_config = tls_cfg;

    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();
    try conn.connect("127.0.0.1", 4433);

    const tp = try transport_params_mod.TransportParams.defaultServer().encode(allocator);
    defer allocator.free(tp);

    // ALPN list length 1 with a zero-length protocol id.
    var alpn_zero: [3]u8 = .{ 0x00, 0x01, 0x00 };
    const ext = [_]tls_handshake_mod.Extension{
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.application_layer_protocol_negotiation),
            .extension_data = &alpn_zero,
        },
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.quic_transport_parameters),
            .extension_data = tp,
        },
    };
    const random: [32]u8 = [_]u8{36} ** 32;
    const server_hello = tls_handshake_mod.ServerHello{
        .random = random,
        .cipher_suite = tls_handshake_mod.TLS_AES_128_GCM_SHA256,
        .extensions = &ext,
    };
    const server_hello_bytes = try server_hello.encode(allocator);
    defer allocator.free(server_hello_bytes);

    try std.testing.expectError(
        types_mod.QuicError.HandshakeFailed,
        conn.processTlsServerHello(server_hello_bytes, "test-shared-secret-from-ecdhe"),
    );
    try std.testing.expectEqual(types_mod.ConnectionState.draining, conn.getState());
}

test "processTlsServerHello rejects invalid transport params extension payload" {
    const allocator = std.testing.allocator;

    var config = config_mod.QuicConfig.tlsClient("example.com");
    var tls_cfg = config.tls_config.?;
    tls_cfg.alpn_protocols = &[_][]const u8{"h3"};
    config.tls_config = tls_cfg;

    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();
    try conn.connect("127.0.0.1", 4433);

    var alpn_payload: [5]u8 = .{ 0x00, 0x03, 0x02, 'h', '3' };
    // Invalid transport params payload (truncated varint parameter).
    const invalid_tp = [_]u8{ 0x03, 0x02, 0x44 };

    const ext = [_]tls_handshake_mod.Extension{
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.application_layer_protocol_negotiation),
            .extension_data = &alpn_payload,
        },
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.quic_transport_parameters),
            .extension_data = &invalid_tp,
        },
    };
    const random: [32]u8 = [_]u8{34} ** 32;
    const server_hello = tls_handshake_mod.ServerHello{
        .random = random,
        .cipher_suite = tls_handshake_mod.TLS_AES_128_GCM_SHA256,
        .extensions = &ext,
    };
    const server_hello_bytes = try server_hello.encode(allocator);
    defer allocator.free(server_hello_bytes);

    try std.testing.expectError(
        types_mod.QuicError.HandshakeFailed,
        conn.processTlsServerHello(server_hello_bytes, "test-shared-secret-from-ecdhe"),
    );
}

test "processTlsServerHello rejects transport params protocol violation values" {
    const allocator = std.testing.allocator;

    var config = config_mod.QuicConfig.tlsClient("example.com");
    var tls_cfg = config.tls_config.?;
    tls_cfg.alpn_protocols = &[_][]const u8{"h3"};
    config.tls_config = tls_cfg;

    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();
    try conn.connect("127.0.0.1", 4433);

    var server_params = transport_params_mod.TransportParams.defaultServer();
    server_params.ack_delay_exponent = 21; // Protocol violation per RFC bounds.
    const encoded_server_params = try server_params.encode(allocator);
    defer allocator.free(encoded_server_params);

    const server_hello_bytes = try buildTlsServerHelloForTests(allocator, "h3", encoded_server_params);
    defer allocator.free(server_hello_bytes);

    try std.testing.expectError(
        types_mod.QuicError.HandshakeFailed,
        conn.processTlsServerHello(server_hello_bytes, "test-shared-secret-from-ecdhe"),
    );
    try std.testing.expectEqual(types_mod.ConnectionState.draining, conn.getState());

    var closing: ?types_mod.ConnectionEvent = null;
    while (conn.nextEvent()) |event| {
        if (event == .closing) {
            closing = event;
            break;
        }
    }

    try std.testing.expect(closing != null);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        closing.?.closing.error_code,
    );
}

test "processTlsServerHello surfaces ALPN mismatch reason" {
    const allocator = std.testing.allocator;

    var config = config_mod.QuicConfig.tlsClient("example.com");
    var tls_cfg = config.tls_config.?;
    tls_cfg.alpn_protocols = &[_][]const u8{"h3"};
    config.tls_config = tls_cfg;

    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();
    try conn.connect("127.0.0.1", 4433);

    var server_params = transport_params_mod.TransportParams.defaultServer();
    const encoded_server_params = try server_params.encode(allocator);
    defer allocator.free(encoded_server_params);

    // Server selects h2 although client only offered h3.
    var alpn_payload: [5]u8 = .{ 0x00, 0x03, 0x02, 'h', '2' };
    const ext = [_]tls_handshake_mod.Extension{
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.application_layer_protocol_negotiation),
            .extension_data = &alpn_payload,
        },
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.quic_transport_parameters),
            .extension_data = encoded_server_params,
        },
    };
    const random: [32]u8 = [_]u8{35} ** 32;
    const server_hello = tls_handshake_mod.ServerHello{
        .random = random,
        .cipher_suite = tls_handshake_mod.TLS_AES_128_GCM_SHA256,
        .extensions = &ext,
    };
    const server_hello_bytes = try server_hello.encode(allocator);
    defer allocator.free(server_hello_bytes);

    try std.testing.expectError(
        types_mod.QuicError.HandshakeFailed,
        conn.processTlsServerHello(server_hello_bytes, "test-shared-secret-from-ecdhe"),
    );

    try std.testing.expectEqual(types_mod.ConnectionState.draining, conn.getState());
    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.connection_refused)),
        event.?.closing.error_code,
    );
    try std.testing.expectEqualStrings("alpn mismatch", event.?.closing.reason);
}

test "processTlsServerHello rejects duplicate ALPN extensions" {
    const allocator = std.testing.allocator;

    var config = config_mod.QuicConfig.tlsClient("example.com");
    var tls_cfg = config.tls_config.?;
    tls_cfg.alpn_protocols = &[_][]const u8{"h3"};
    config.tls_config = tls_cfg;

    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();
    try conn.connect("127.0.0.1", 4433);

    const tp = try transport_params_mod.TransportParams.defaultServer().encode(allocator);
    defer allocator.free(tp);

    var alpn_h3: [5]u8 = .{ 0x00, 0x03, 0x02, 'h', '3' };
    var alpn_h2: [5]u8 = .{ 0x00, 0x03, 0x02, 'h', '2' };
    const ext = [_]tls_handshake_mod.Extension{
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.application_layer_protocol_negotiation),
            .extension_data = &alpn_h3,
        },
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.application_layer_protocol_negotiation),
            .extension_data = &alpn_h2,
        },
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.quic_transport_parameters),
            .extension_data = tp,
        },
    };

    const random: [32]u8 = [_]u8{41} ** 32;
    const server_hello = tls_handshake_mod.ServerHello{
        .random = random,
        .cipher_suite = tls_handshake_mod.TLS_AES_128_GCM_SHA256,
        .extensions = &ext,
    };
    const payload = try server_hello.encode(allocator);
    defer allocator.free(payload);

    try std.testing.expectError(types_mod.QuicError.HandshakeFailed, conn.processTlsServerHello(payload, "test-shared-secret-from-ecdhe"));
    try std.testing.expectEqual(types_mod.ConnectionState.draining, conn.getState());
}

test "processTlsServerHello rejects duplicate transport parameter extensions" {
    const allocator = std.testing.allocator;

    var config = config_mod.QuicConfig.tlsClient("example.com");
    var tls_cfg = config.tls_config.?;
    tls_cfg.alpn_protocols = &[_][]const u8{"h3"};
    config.tls_config = tls_cfg;

    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();
    try conn.connect("127.0.0.1", 4433);

    const tp1 = try transport_params_mod.TransportParams.defaultServer().encode(allocator);
    defer allocator.free(tp1);
    var tp_params2 = transport_params_mod.TransportParams.defaultServer();
    tp_params2.initial_max_data = 12345;
    const tp2 = try tp_params2.encode(allocator);
    defer allocator.free(tp2);

    var alpn_h3: [5]u8 = .{ 0x00, 0x03, 0x02, 'h', '3' };
    const ext = [_]tls_handshake_mod.Extension{
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.application_layer_protocol_negotiation),
            .extension_data = &alpn_h3,
        },
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.quic_transport_parameters),
            .extension_data = tp1,
        },
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.quic_transport_parameters),
            .extension_data = tp2,
        },
    };

    const random: [32]u8 = [_]u8{42} ** 32;
    const server_hello = tls_handshake_mod.ServerHello{
        .random = random,
        .cipher_suite = tls_handshake_mod.TLS_AES_128_GCM_SHA256,
        .extensions = &ext,
    };
    const payload = try server_hello.encode(allocator);
    defer allocator.free(payload);

    try std.testing.expectError(types_mod.QuicError.HandshakeFailed, conn.processTlsServerHello(payload, "test-shared-secret-from-ecdhe"));
    try std.testing.expectEqual(types_mod.ConnectionState.draining, conn.getState());
}

test "negotiation snapshot exposes mode ALPN and peer params" {
    const allocator = std.testing.allocator;

    var config = config_mod.QuicConfig.tlsClient("example.com");
    var tls_cfg = config.tls_config.?;
    tls_cfg.alpn_protocols = &[_][]const u8{"h3"};
    config.tls_config = tls_cfg;

    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    const internal_conn = try allocator.create(conn_internal.Connection);
    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });
    internal_conn.* = try conn_internal.Connection.initClient(allocator, .tls, local_cid, remote_cid);
    internal_conn.markEstablished();
    conn.internal_conn = internal_conn;
    conn.state = .established;

    var encoded = transport_params_mod.TransportParams.init();
    encoded.max_idle_timeout = 12345;
    encoded.initial_max_data = 45678;
    encoded.initial_max_streams_bidi = 7;
    encoded.initial_max_streams_uni = 3;
    const payload = try encoded.encode(allocator);
    defer allocator.free(payload);
    try conn.applyPeerTransportParams(payload);

    conn.negotiated_alpn = "h3";

    const snapshot = conn.getNegotiationSnapshot();
    try std.testing.expect(snapshot != null);
    try std.testing.expectEqual(types_mod.NegotiationMode.tls, snapshot.?.mode);
    try std.testing.expect(snapshot.?.is_established);
    try std.testing.expect(snapshot.?.alpn != null);
    try std.testing.expectEqualStrings("h3", snapshot.?.alpn.?);
    try std.testing.expectEqual(@as(u64, 12345), snapshot.?.peer_max_idle_timeout);
    try std.testing.expectEqual(@as(u64, 45678), snapshot.?.peer_initial_max_data);
    try std.testing.expectEqual(@as(u64, 7), snapshot.?.peer_initial_max_streams_bidi);
    try std.testing.expectEqual(@as(u64, 3), snapshot.?.peer_initial_max_streams_uni);
}

test "isHandshakeNegotiated requires integrated TLS server hello processing" {
    const allocator = std.testing.allocator;

    var config = config_mod.QuicConfig.tlsClient("example.com");
    var tls_cfg = config.tls_config.?;
    tls_cfg.alpn_protocols = &[_][]const u8{"h3"};
    config.tls_config = tls_cfg;

    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;

    try std.testing.expect(!conn.isHandshakeNegotiated());

    const tls_ctx = conn.tls_ctx.?;
    const random: [32]u8 = [_]u8{11} ** 32;
    var alpn_payload: [5]u8 = .{ 0x00, 0x03, 0x02, 'h', '3' };
    const ext = [_]tls_handshake_mod.Extension{
        .{
            .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.application_layer_protocol_negotiation),
            .extension_data = &alpn_payload,
        },
    };
    const server_hello = tls_handshake_mod.ServerHello{
        .random = random,
        .cipher_suite = tls_handshake_mod.TLS_AES_128_GCM_SHA256,
        .extensions = &ext,
    };
    const server_hello_bytes = try server_hello.encode(allocator);
    defer allocator.free(server_hello_bytes);

    try tls_ctx.processServerHello(server_hello_bytes);
    try tls_ctx.completeHandshake("test-shared-secret-from-ecdhe");
    const encoded = try transport_params_mod.TransportParams.defaultServer().encode(allocator);
    defer allocator.free(encoded);
    try conn.applyPeerTransportParams(encoded);

    // Manual steps are not enough; integrated processing marks completion.
    try std.testing.expect(!conn.isHandshakeNegotiated());

    var conn2 = try QuicConnection.init(allocator, config);
    defer conn2.deinit();
    try conn2.connect("127.0.0.1", 4433);
    conn2.internal_conn.?.markEstablished();
    conn2.state = .established;

    var tp_ext = transport_params_mod.TransportParams.defaultServer();
    const encoded_tp_ext = try tp_ext.encode(allocator);
    defer allocator.free(encoded_tp_ext);
    const ext_with_tp = [_]tls_handshake_mod.Extension{
        .{ .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.application_layer_protocol_negotiation), .extension_data = &alpn_payload },
        .{ .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.quic_transport_parameters), .extension_data = encoded_tp_ext },
    };
    const integrated_server_hello = tls_handshake_mod.ServerHello{ .random = random, .cipher_suite = tls_handshake_mod.TLS_AES_128_GCM_SHA256, .extensions = &ext_with_tp };
    const integrated_server_hello_bytes = try integrated_server_hello.encode(allocator);
    defer allocator.free(integrated_server_hello_bytes);

    try conn2.processTlsServerHello(integrated_server_hello_bytes, "test-shared-secret-from-ecdhe");
    try std.testing.expect(conn2.isHandshakeNegotiated());
}

test "isHandshakeNegotiated requires peer transport params in SSH mode" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    const internal_conn = try allocator.create(conn_internal.Connection);
    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });
    internal_conn.* = try conn_internal.Connection.initClient(allocator, .ssh, local_cid, remote_cid);
    internal_conn.markEstablished();
    conn.internal_conn = internal_conn;
    conn.state = .established;

    try std.testing.expect(!conn.isHandshakeNegotiated());

    const encoded = try transport_params_mod.TransportParams.defaultServer().encode(allocator);
    defer allocator.free(encoded);
    try conn.applyPeerTransportParams(encoded);

    try std.testing.expect(conn.isHandshakeNegotiated());
}

test "mode capabilities reflect tls and ssh modes" {
    const allocator = std.testing.allocator;

    var tls_conn = try QuicConnection.init(allocator, config_mod.QuicConfig.tlsClient("example.com"));
    defer tls_conn.deinit();

    const tls_caps = tls_conn.getModeCapabilities();
    try std.testing.expect(tls_caps.supports_unidirectional_streams);
    try std.testing.expect(tls_caps.supports_alpn);
    try std.testing.expect(tls_caps.requires_integrated_tls_server_hello);

    var ssh_conn = try QuicConnection.init(allocator, config_mod.QuicConfig.sshClient("example.com", "secret"));
    defer ssh_conn.deinit();

    const ssh_caps = ssh_conn.getModeCapabilities();
    try std.testing.expect(!ssh_caps.supports_unidirectional_streams);
    try std.testing.expect(!ssh_caps.supports_alpn);
    try std.testing.expect(!ssh_caps.requires_integrated_tls_server_hello);
}

test "dual-mode regression stream policy tls vs ssh" {
    const allocator = std.testing.allocator;

    var tls_cfg = config_mod.QuicConfig.tlsClient("example.com");
    tls_cfg.tls_config.?.alpn_protocols = &[_][]const u8{"h3"};
    var tls_conn = try QuicConnection.init(allocator, tls_cfg);
    defer tls_conn.deinit();
    try tls_conn.connect("127.0.0.1", 4433);

    var tls_tp = transport_params_mod.TransportParams.defaultServer();
    tls_tp.initial_max_streams_bidi = 2;
    tls_tp.initial_max_streams_uni = 1;
    const tls_tp_encoded = try tls_tp.encode(allocator);
    defer allocator.free(tls_tp_encoded);

    const server_hello = try buildTlsServerHelloForTests(allocator, "h3", tls_tp_encoded);
    defer allocator.free(server_hello);
    try tls_conn.processTlsServerHello(server_hello, "test-shared-secret-from-ecdhe");
    tls_conn.internal_conn.?.markEstablished();
    tls_conn.state = .established;

    _ = try tls_conn.openStream(false);

    const ssh_cfg = config_mod.QuicConfig.sshClient("example.com", "secret");
    var ssh_conn = try QuicConnection.init(allocator, ssh_cfg);
    defer ssh_conn.deinit();
    try ssh_conn.connect("127.0.0.1", 4433);
    ssh_conn.internal_conn.?.markEstablished();
    ssh_conn.state = .established;
    try applyPeerTransportParamsWithLimits(&ssh_conn, allocator, 2, 1);

    try std.testing.expectError(types_mod.QuicError.StreamError, ssh_conn.openStream(false));
}

test "dual-mode regression negotiated stream limits enforced" {
    const allocator = std.testing.allocator;

    var tls_cfg = config_mod.QuicConfig.tlsClient("example.com");
    tls_cfg.tls_config.?.alpn_protocols = &[_][]const u8{"h3"};
    var tls_conn = try QuicConnection.init(allocator, tls_cfg);
    defer tls_conn.deinit();
    try tls_conn.connect("127.0.0.1", 4433);

    var tls_tp = transport_params_mod.TransportParams.defaultServer();
    tls_tp.initial_max_streams_bidi = 1;
    const tls_tp_encoded = try tls_tp.encode(allocator);
    defer allocator.free(tls_tp_encoded);

    const server_hello = try buildTlsServerHelloForTests(allocator, "h3", tls_tp_encoded);
    defer allocator.free(server_hello);
    try tls_conn.processTlsServerHello(server_hello, "test-shared-secret-from-ecdhe");
    tls_conn.internal_conn.?.markEstablished();
    tls_conn.state = .established;

    _ = try tls_conn.openStream(true);
    try std.testing.expectError(types_mod.QuicError.StreamLimitReached, tls_conn.openStream(true));

    const ssh_cfg = config_mod.QuicConfig.sshClient("example.com", "secret");
    var ssh_conn = try QuicConnection.init(allocator, ssh_cfg);
    defer ssh_conn.deinit();
    try ssh_conn.connect("127.0.0.1", 4433);
    ssh_conn.internal_conn.?.markEstablished();
    ssh_conn.state = .established;
    try applyPeerTransportParamsWithLimits(&ssh_conn, allocator, 1, 0);

    _ = try ssh_conn.openStream(true);
    try std.testing.expectError(types_mod.QuicError.StreamLimitReached, ssh_conn.openStream(true));
}

test "negotiation result is normalized across modes" {
    const allocator = std.testing.allocator;

    var tls_config = config_mod.QuicConfig.tlsClient("example.com");
    tls_config.tls_config.?.alpn_protocols = &[_][]const u8{"h3"};

    var tls_conn = try QuicConnection.init(allocator, tls_config);
    defer tls_conn.deinit();
    try tls_conn.connect("127.0.0.1", 4433);

    var server_params = transport_params_mod.TransportParams.defaultServer();
    const encoded_server_params = try server_params.encode(allocator);
    defer allocator.free(encoded_server_params);

    var alpn_payload: [5]u8 = .{ 0x00, 0x03, 0x02, 'h', '3' };
    const tls_ext = [_]tls_handshake_mod.Extension{
        .{ .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.application_layer_protocol_negotiation), .extension_data = &alpn_payload },
        .{ .extension_type = @intFromEnum(tls_handshake_mod.ExtensionType.quic_transport_parameters), .extension_data = encoded_server_params },
    };
    const random: [32]u8 = [_]u8{51} ** 32;
    const tls_server_hello = tls_handshake_mod.ServerHello{
        .random = random,
        .cipher_suite = tls_handshake_mod.TLS_AES_128_GCM_SHA256,
        .extensions = &tls_ext,
    };
    const tls_server_hello_bytes = try tls_server_hello.encode(allocator);
    defer allocator.free(tls_server_hello_bytes);
    try tls_conn.processTlsServerHello(tls_server_hello_bytes, "test-shared-secret-from-ecdhe");

    const tls_result = tls_conn.getNegotiationResult();
    try std.testing.expectEqual(types_mod.NegotiationMode.tls, tls_result.mode);
    try std.testing.expect(tls_result.has_peer_transport_params);
    try std.testing.expect(tls_result.tls_server_hello_applied);
    try std.testing.expect(tls_result.tls_handshake_complete);
    try std.testing.expect(tls_result.ready_for_establish);

    const ssh_config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var ssh_conn = try QuicConnection.init(allocator, ssh_config);
    defer ssh_conn.deinit();
    try ssh_conn.connect("127.0.0.1", 4433);
    try applyDefaultPeerTransportParams(&ssh_conn, allocator);

    const ssh_result = ssh_conn.getNegotiationResult();
    try std.testing.expectEqual(types_mod.NegotiationMode.ssh, ssh_result.mode);
    try std.testing.expect(ssh_result.has_peer_transport_params);
    try std.testing.expect(!ssh_result.tls_server_hello_applied);
    try std.testing.expect(!ssh_result.tls_handshake_complete);
    try std.testing.expect(ssh_result.ready_for_establish);
}

test "Connection state transitions" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try std.testing.expectEqual(types_mod.ConnectionState.idle, conn.getState());

    conn.state = .connecting;
    try std.testing.expectEqual(types_mod.ConnectionState.connecting, conn.getState());

    conn.state = .established;
    try std.testing.expectEqual(types_mod.ConnectionState.established, conn.getState());
}

test "Get connection stats" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    const stats = conn.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.packets_sent);
    try std.testing.expectEqual(@as(u64, 0), stats.bytes_received);
    try std.testing.expect(stats.duration_ms <= 1000);
}

test "Get connection stats duration reflects elapsed runtime" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    conn.created_at = time_mod.Instant.now().sub(2500); // 2.5ms ago
    const stats = conn.getStats();
    try std.testing.expect(stats.duration_ms >= 2);
}

test "Get connection stats reflects active connection counters" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    // Populate send/recovery counters.
    conn.internal_conn.?.trackPacketSent(1200, true);
    conn.internal_conn.?.trackPacketSent(800, true);
    conn.internal_conn.?.data_sent = 2000;
    conn.internal_conn.?.data_received = 1500;
    conn.packets_received = 3;
    conn.packets_invalid = 1;

    _ = try conn.openStream(true);
    _ = conn.nextEvent();

    const stats = conn.getStats();
    try std.testing.expectEqual(@as(u64, 2), stats.packets_sent);
    try std.testing.expectEqual(@as(u64, 3), stats.packets_received);
    try std.testing.expectEqual(@as(u64, 1), stats.packets_invalid);
    try std.testing.expectEqual(@as(u64, 2000), stats.bytes_sent);
    try std.testing.expectEqual(@as(u64, 1500), stats.bytes_received);
    try std.testing.expect(stats.active_streams >= 1);
    try std.testing.expect(stats.rtt > 0);
}

test "Event queue" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.events.append(allocator, .{ .connected = .{} });

    const event = conn.nextEvent();
    try std.testing.expect(event != null);

    const event2 = conn.nextEvent();
    try std.testing.expect(event2 == null);
}

test "connect stays connecting without handshake progress" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    try std.testing.expectEqual(types_mod.ConnectionState.connecting, conn.getState());
    try std.testing.expect(conn.nextEvent() == null);

    try conn.poll();
    try std.testing.expectEqual(types_mod.ConnectionState.connecting, conn.getState());
    try std.testing.expect(conn.nextEvent() == null);
}

test "connect emits connected event when first packet is processed" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();

    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .initial,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 4,
        .packet_number = 1,
    };

    var packet_len = try header.encode(&packet_buf);
    packet_buf[packet_len] = 0x01;
    packet_len += 1;

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .connected);
    try std.testing.expect(conn.nextEvent() == null);
}

test "closeStream is FIN-based half close" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    const internal_conn = try allocator.create(conn_internal.Connection);
    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });
    internal_conn.* = try conn_internal.Connection.initClient(allocator, .ssh, local_cid, remote_cid);
    internal_conn.markEstablished();

    conn.internal_conn = internal_conn;
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    const stream_id = try conn.openStream(true);
    _ = conn.nextEvent(); // drain stream_opened

    try conn.closeStream(stream_id, 42);

    // FIN-based close should not emit stream_closed immediately (half-close)
    try std.testing.expect(conn.nextEvent() == null);

    const info_after_close = try conn.getStreamInfo(stream_id);
    try std.testing.expectEqual(types_mod.StreamState.send_closed, info_after_close.state);

    // Local write after FIN should fail
    try std.testing.expectError(
        types_mod.QuicError.StreamError,
        conn.streamWrite(stream_id, "after-fin", .no_finish),
    );

    // Peer can still send while our send side is closed
    const stream = conn.internal_conn.?.getStream(stream_id).?;
    try stream.appendRecvData("peer-data", 0, false);

    var read_buf: [64]u8 = undefined;
    const read_len = try conn.streamRead(stream_id, &read_buf);
    try std.testing.expectEqual(@as(usize, 9), read_len);
    try std.testing.expectEqualStrings("peer-data", read_buf[0..read_len]);

    // Peer FIN => EOF visible to application
    try stream.appendRecvData(&[_]u8{}, stream.recv_offset, true);
    const eof_len = try conn.streamRead(stream_id, &read_buf);
    try std.testing.expectEqual(@as(usize, 0), eof_len);

    try std.testing.expectError(types_mod.QuicError.StreamClosed, conn.streamRead(stream_id, &read_buf));
    const closed_info = try conn.getStreamInfo(stream_id);
    try std.testing.expectEqual(types_mod.StreamState.closed, closed_info.state);
}

test "streamWrite respects congestion send budget" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    const internal_conn = try allocator.create(conn_internal.Connection);
    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });
    internal_conn.* = try conn_internal.Connection.initClient(allocator, .ssh, local_cid, remote_cid);
    internal_conn.markEstablished();

    conn.internal_conn = internal_conn;
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    const stream_id = try conn.openStream(true);
    _ = conn.nextEvent();

    // Limit send budget to 5 bytes.
    internal_conn.congestion_controller.congestion_window = 5;
    internal_conn.congestion_controller.bytes_in_flight = 0;

    const written = try conn.streamWrite(stream_id, "abcdefghij", .no_finish);
    try std.testing.expectEqual(@as(usize, 5), written);

    // Exhaust budget and ensure write is blocked.
    internal_conn.congestion_controller.bytes_in_flight = 5;
    try std.testing.expectError(
        types_mod.QuicError.FlowControlError,
        conn.streamWrite(stream_id, "x", .no_finish),
    );
}

test "poll parses received long-header packet and updates visibility stats" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();

    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .initial,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 4,
        .packet_number = 1,
    };

    var packet_len = try header.encode(&packet_buf);
    packet_buf[packet_len] = 0x01; // payload byte (PING frame type)
    packet_len += 1;

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);

    try conn.poll();

    const connected_event = conn.nextEvent();
    try std.testing.expect(connected_event != null);
    try std.testing.expect(connected_event.? == .connected);

    const stats = conn.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.packets_received);
    try std.testing.expectEqual(@as(u64, packet_len), stats.bytes_received);
    try std.testing.expectEqual(types_mod.ConnectionState.established, conn.getState());
}

test "poll maps invalid packet header to closing event" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();

    const local_addr = try conn.socket.?.getLocalAddress();

    const invalid_packet = [_]u8{0x40};
    _ = try sender.sendTo(&invalid_packet, local_addr);

    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        event.?.closing.error_code,
    );
    try std.testing.expectEqual(types_mod.ConnectionState.draining, conn.getState());

    const stats = conn.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.packets_received);
    try std.testing.expectEqual(@as(u64, 1), stats.packets_invalid);
}

test "poll malformed version negotiation increments invalid packet stats" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [32]u8 = undefined;
    packet_buf[0] = 0xC0;
    std.mem.writeInt(u32, packet_buf[1..5], 0, .big);
    packet_buf[5] = 4;
    @memcpy(packet_buf[6..10], &[_]u8{ 1, 2, 3, 4 });
    packet_buf[10] = 4;
    @memcpy(packet_buf[11..15], &[_]u8{ 5, 6, 7, 8 });
    // Missing versions list bytes.

    _ = try sender.sendTo(packet_buf[0..15], local_addr);
    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);

    const stats = conn.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.packets_received);
    try std.testing.expectEqual(@as(u64, 1), stats.packets_invalid);
}

test "poll while draining does not consume new packets" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    try conn.close(1, "enter-drain");
    _ = conn.nextEvent();

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();
    _ = try sender.sendTo(&[_]u8{0x40}, local_addr);

    const before = conn.getStats();
    try conn.poll();
    const after = conn.getStats();

    try std.testing.expectEqual(before.packets_received, after.packets_received);
    try std.testing.expectEqual(before.packets_invalid, after.packets_invalid);
}

test "poll routes ACK frame into connection ack tracking" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    var sent_count: usize = 0;
    while (sent_count < 8) : (sent_count += 1) {
        conn.internal_conn.?.trackPacketSentInSpace(.initial, 1200, true);
    }

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();

    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .initial,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 8,
        .packet_number = 2,
    };

    var packet_len = try header.encode(&packet_buf);
    const ack = frame_mod.AckFrame{
        .largest_acked = 7,
        .ack_delay = 0,
        .first_ack_range = 0,
        .ack_ranges = &.{},
        .ecn_counts = null,
    };
    packet_len += try ack.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const connected_event = conn.nextEvent();
    try std.testing.expect(connected_event != null);
    try std.testing.expect(connected_event.? == .connected);

    try std.testing.expectEqual(@as(u64, 7), conn.internal_conn.?.largest_acked);
}

test "poll rejects Initial ACK for unsent Initial packet numbers" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    // Send only application-space packets in local bookkeeping.
    conn.internal_conn.?.trackPacketSent(1200, true);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();

    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .initial,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 8,
        .packet_number = 6,
    };

    var packet_len = try header.encode(&packet_buf);
    const ack = frame_mod.AckFrame{
        .largest_acked = 0,
        .ack_delay = 0,
        .first_ack_range = 0,
        .ack_ranges = &.{},
        .ecn_counts = null,
    };
    packet_len += try ack.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const first = conn.nextEvent();
    try std.testing.expect(first != null);
    const event = if (first.? == .closing) first else conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        event.?.closing.error_code,
    );
}

test "poll routes connection close frame to closing event" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();

    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .initial,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 16,
        .packet_number = 3,
    };

    var packet_len = try header.encode(&packet_buf);
    const close_frame = frame_mod.ConnectionCloseFrame{
        .error_code = 0x0a,
        .frame_type = null,
        .reason = "bye",
    };
    packet_len += try close_frame.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const first = conn.nextEvent();
    try std.testing.expect(first != null);
    const event = if (first.? == .connected) conn.nextEvent() else first;
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(@as(u64, 0x0a), event.?.closing.error_code);
    try std.testing.expectEqualStrings("bye", event.?.closing.reason);
    try std.testing.expectEqual(types_mod.ConnectionState.draining, conn.getState());
}

test "draining transitions to closed and emits closed event" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    const internal_conn = try allocator.create(conn_internal.Connection);
    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });
    internal_conn.* = try conn_internal.Connection.initClient(allocator, .ssh, local_cid, remote_cid);
    internal_conn.markEstablished();

    conn.internal_conn = internal_conn;
    conn.state = .established;

    try conn.close(55, "closing-now");
    const closing_event = conn.nextEvent();
    try std.testing.expect(closing_event != null);
    try std.testing.expect(closing_event.? == .closing);
    try std.testing.expectEqual(@as(u64, 55), closing_event.?.closing.error_code);
    try std.testing.expectEqualStrings("closing-now", closing_event.?.closing.reason);

    // First poll in draining acts as grace period
    try conn.poll();
    try std.testing.expectEqual(types_mod.ConnectionState.draining, conn.getState());

    // Force drain timer expiry for deterministic test progression.
    conn.drain_deadline = time_mod.Instant.now().sub(1);

    // Second poll transitions to closed and emits closed event
    try conn.poll();
    try std.testing.expectEqual(types_mod.ConnectionState.closed, conn.getState());

    const closed_event = conn.nextEvent();
    try std.testing.expect(closed_event != null);
    try std.testing.expect(closed_event.? == .closed);
}

test "close is idempotent while draining" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    const internal_conn = try allocator.create(conn_internal.Connection);
    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });
    internal_conn.* = try conn_internal.Connection.initClient(allocator, .ssh, local_cid, remote_cid);
    internal_conn.markEstablished();

    conn.internal_conn = internal_conn;
    conn.state = .established;

    try conn.close(77, "first-close");
    try conn.close(88, "second-close");

    const closing = conn.nextEvent();
    try std.testing.expect(closing != null);
    try std.testing.expect(closing.? == .closing);
    try std.testing.expectEqual(@as(u64, 77), closing.?.closing.error_code);
    try std.testing.expectEqualStrings("first-close", closing.?.closing.reason);
    try std.testing.expect(conn.nextEvent() == null);
}

test "closed event emits once after drain deadline" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    const internal_conn = try allocator.create(conn_internal.Connection);
    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });
    internal_conn.* = try conn_internal.Connection.initClient(allocator, .ssh, local_cid, remote_cid);
    internal_conn.markEstablished();

    conn.internal_conn = internal_conn;
    conn.state = .established;

    try conn.close(99, "close-once");
    _ = conn.nextEvent(); // closing

    conn.drain_deadline = time_mod.Instant.now().sub(1);
    try conn.poll();

    const closed = conn.nextEvent();
    try std.testing.expect(closed != null);
    try std.testing.expect(closed.? == .closed);
    try std.testing.expect(conn.nextEvent() == null);

    try std.testing.expectError(types_mod.QuicError.ConnectionClosed, conn.poll());
    try std.testing.expect(conn.nextEvent() == null);
}

test "repeated malformed packets emit single closing event while draining" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [64]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 74,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    packet_buf[packet_len] = 0x02; // ACK frame type only => malformed/truncated payload
    packet_len += 1;

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();
    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    var closing_count: usize = 0;
    while (conn.nextEvent()) |event| {
        if (event == .closing) {
            closing_count += 1;
        }
    }

    try std.testing.expectEqual(@as(usize, 1), closing_count);
    try std.testing.expectEqual(types_mod.ConnectionState.draining, conn.getState());
}

test "draining ignores version negotiation stimuli" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    try conn.close(321, "enter-drain");
    const first = conn.nextEvent();
    try std.testing.expect(first != null);
    try std.testing.expect(first.? == .closing);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const vn = packet_mod.VersionNegotiationPacket{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .supported_versions = &[_]u32{ 0x00000002, 0x00000003 },
    };
    const packet_len = try vn.encode(&packet_buf);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    try std.testing.expect(conn.nextEvent() == null);
    try std.testing.expectEqual(types_mod.ConnectionState.draining, conn.getState());
}

test "drain timeout closes even with queued inbound packets" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    try conn.close(222, "local-close");
    _ = conn.nextEvent(); // consume closing

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [32]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 75,
        .key_phase = false,
    };
    var packet_len = try header.encode(&packet_buf);
    packet_buf[packet_len] = 0x01; // PING
    packet_len += 1;
    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);

    conn.drain_deadline = time_mod.Instant.now().sub(1);
    try conn.poll();

    try std.testing.expectEqual(types_mod.ConnectionState.closed, conn.getState());
    const closed = conn.nextEvent();
    try std.testing.expect(closed != null);
    try std.testing.expect(closed.? == .closed);
    try std.testing.expect(conn.nextEvent() == null);
}

test "drain deadline expiry uses strict less-than" {
    const now = time_mod.Instant{ .micros = 1000 };
    const before = time_mod.Instant{ .micros = 999 };
    const equal = time_mod.Instant{ .micros = 1000 };
    const after = time_mod.Instant{ .micros = 1001 };

    try std.testing.expect(QuicConnection.drain_deadline_expired(now, before));
    try std.testing.expect(!QuicConnection.drain_deadline_expired(now, equal));
    try std.testing.expect(!QuicConnection.drain_deadline_expired(now, after));
}

test "poll routes STREAM frame into stream data and readable event" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();

    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 4,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    const stream_frame = frame_mod.StreamFrame{
        .stream_id = 4,
        .offset = 0,
        .data = "hello-stream",
        .fin = false,
    };
    packet_len += try stream_frame.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .stream_readable);
    try std.testing.expectEqual(@as(u64, 4), event.?.stream_readable);

    try applyDefaultPeerTransportParams(&conn, allocator);

    var read_buf: [64]u8 = undefined;
    const n = try conn.streamRead(4, &read_buf);
    try std.testing.expectEqual(@as(usize, 12), n);
    try std.testing.expectEqualStrings("hello-stream", read_buf[0..n]);
}

test "poll routes MAX_DATA frame and raises send budget" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);
    conn.internal_conn.?.trackPacketSent(1200, true); // pn 0
    conn.internal_conn.?.trackPacketSent(1200, true); // pn 1
    conn.internal_conn.?.trackPacketSent(1200, true); // pn 2
    conn.internal_conn.?.trackPacketSent(1200, true); // pn 0
    conn.internal_conn.?.trackPacketSent(1200, true); // pn 1
    conn.internal_conn.?.trackPacketSent(1200, true); // pn 2
    conn.internal_conn.?.trackPacketSent(1200, true); // pn 0
    conn.internal_conn.?.trackPacketSent(1200, true); // pn 1
    conn.internal_conn.?.trackPacketSent(1200, true); // pn 2

    const before_max_data = conn.internal_conn.?.max_data_remote;

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();

    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 37,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    const max_data = frame_mod.MaxDataFrame{ .max_data = conn.internal_conn.?.max_data_remote + 2048 };
    packet_len += try max_data.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    try std.testing.expect(conn.nextEvent() == null);
    const after_max_data = conn.internal_conn.?.max_data_remote;
    try std.testing.expect(after_max_data > before_max_data);
}

test "poll routes MAX_STREAMS frame and increases open-stream limit" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    conn.internal_conn.?.streams.setLocalOpenLimits(1, 0);
    _ = try conn.openStream(true);
    try std.testing.expectError(types_mod.QuicError.StreamLimitReached, conn.openStream(true));

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 38,
        .key_phase = false,
    };
    var packet_len = try header.encode(&packet_buf);
    const max_streams = frame_mod.MaxStreamsFrame{ .max_streams = 3, .bidirectional = true };
    packet_len += try max_streams.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    while (conn.nextEvent()) |ev| {
        try std.testing.expect(ev != .closing);
        try std.testing.expect(ev != .closed);
    }
    try std.testing.expectEqual(types_mod.ConnectionState.established, conn.getState());

    _ = try conn.openStream(true);
}

test "poll routes MAX_STREAM_DATA frame and increases stream send credit" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    const sid = try conn.openStream(true);
    const stream = conn.internal_conn.?.getStream(sid).?;
    stream.max_stream_data_remote = 4;

    try std.testing.expectEqual(@as(usize, 4), try conn.streamWrite(sid, "abcdefgh", .no_finish));

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 39,
        .key_phase = false,
    };
    var packet_len = try header.encode(&packet_buf);
    const max_stream_data = frame_mod.MaxStreamDataFrame{ .stream_id = sid, .max_stream_data = 16 };
    packet_len += try max_stream_data.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    while (conn.nextEvent()) |ev| {
        try std.testing.expect(ev != .closing);
        try std.testing.expect(ev != .closed);
    }
    try std.testing.expectEqual(types_mod.ConnectionState.established, conn.getState());

    try std.testing.expectEqual(@as(usize, 8), try conn.streamWrite(sid, "abcdefgh", .no_finish));
}

test "poll routes BLOCKED frames and updates peer blocked observations" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 40,
        .key_phase = false,
    };
    var packet_len = try header.encode(&packet_buf);

    const data_blocked = frame_mod.DataBlockedFrame{ .max_data = 3000 };
    packet_len += try data_blocked.encode(packet_buf[packet_len..]);

    const stream_data_blocked = frame_mod.StreamDataBlockedFrame{ .stream_id = 4, .max_stream_data = 1200 };
    packet_len += try stream_data_blocked.encode(packet_buf[packet_len..]);

    const streams_blocked = frame_mod.StreamsBlockedFrame{ .max_streams = 9, .bidirectional = true };
    packet_len += try streams_blocked.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    while (conn.nextEvent()) |ev| {
        try std.testing.expect(ev != .closing);
        try std.testing.expect(ev != .closed);
    }

    try std.testing.expectEqual(@as(u64, 3000), conn.internal_conn.?.peer_data_blocked_max);
    try std.testing.expectEqual(@as(u64, 1200), conn.internal_conn.?.peer_stream_data_blocked_max);
    try std.testing.expectEqual(@as(u64, 9), conn.internal_conn.?.peer_streams_blocked_bidi_max);
}

test "poll processes multiple frames in a single packet payload" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();

    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 36,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    packet_buf[packet_len] = 0x01; // PING
    packet_len += 1;

    const stream_frame = frame_mod.StreamFrame{
        .stream_id = 4,
        .offset = 0,
        .data = "multi-frame",
        .fin = false,
    };
    packet_len += try stream_frame.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .stream_readable);
    try std.testing.expectEqual(@as(u64, 4), event.?.stream_readable);
    try std.testing.expect(conn.nextEvent() == null);

    var read_buf: [64]u8 = undefined;
    const n = try conn.streamRead(4, &read_buf);
    try std.testing.expectEqual(@as(usize, 11), n);
    try std.testing.expectEqualStrings("multi-frame", read_buf[0..n]);
}

test "poll preserves earlier frame effects before later malformed frame" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 66,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    const stream_frame = frame_mod.StreamFrame{
        .stream_id = 13,
        .offset = 0,
        .data = "ok",
        .fin = false,
    };
    packet_len += try stream_frame.encode(packet_buf[packet_len..]);

    // Malformed ACK tail (truncated after type byte).
    packet_buf[packet_len] = 0x02;
    packet_len += 1;

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    var saw_stream_readable = false;
    var saw_closing = false;
    while (conn.nextEvent()) |event| {
        if (event == .stream_readable and event.stream_readable == 13) {
            saw_stream_readable = true;
        }
        if (event == .closing) {
            saw_closing = true;
        }
    }

    try std.testing.expect(saw_stream_readable);
    try std.testing.expect(saw_closing);

    const info = try conn.getStreamInfo(13);
    try std.testing.expectEqual(@as(types_mod.StreamId, 13), info.id);
}

test "poll stops frame loop on first malformed frame" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 67,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    // Malformed ACK first (truncated), should abort frame loop.
    packet_buf[packet_len] = 0x02;
    packet_len += 1;

    const stream_frame = frame_mod.StreamFrame{
        .stream_id = 14,
        .offset = 0,
        .data = "late",
        .fin = false,
    };
    packet_len += try stream_frame.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    var saw_stream_readable = false;
    var saw_closing = false;
    while (conn.nextEvent()) |event| {
        if (event == .stream_readable and event.stream_readable == 14) {
            saw_stream_readable = true;
        }
        if (event == .closing) {
            saw_closing = true;
        }
    }

    try std.testing.expect(!saw_stream_readable);
    try std.testing.expect(saw_closing);
    try std.testing.expectError(types_mod.QuicError.StreamNotFound, conn.getStreamInfo(14));
}

test "poll keeps path response side effect before malformed trailing frame" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 68,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    const challenge = frame_mod.PathChallengeFrame{ .data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 } };
    packet_len += try challenge.encode(packet_buf[packet_len..]);

    // Malformed CONNECTION_CLOSE tail.
    packet_buf[packet_len] = 0x1c;
    packet_len += 1;

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const pending = conn.internal_conn.?.popPathResponse();
    try std.testing.expect(pending != null);
    try std.testing.expectEqualSlices(u8, &challenge.data, &pending.?);

    var saw_closing = false;
    while (conn.nextEvent()) |event| {
        if (event == .closing) {
            saw_closing = true;
            break;
        }
    }
    try std.testing.expect(saw_closing);
}

test "poll reassembles out-of-order stream frames" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();

    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 37,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    const tail = frame_mod.StreamFrame{
        .stream_id = 5,
        .offset = 5,
        .data = "world",
        .fin = false,
    };
    packet_len += try tail.encode(packet_buf[packet_len..]);

    const head = frame_mod.StreamFrame{
        .stream_id = 5,
        .offset = 0,
        .data = "hello",
        .fin = false,
    };
    packet_len += try head.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    // Drain non-stream events and verify stream becomes readable.
    var saw_stream_readable = false;
    while (conn.nextEvent()) |event| {
        if (event == .stream_readable and event.stream_readable == 5) {
            saw_stream_readable = true;
        }
    }
    try std.testing.expect(saw_stream_readable);

    var read_buf: [32]u8 = undefined;
    const n = try conn.streamRead(5, &read_buf);
    try std.testing.expectEqual(@as(usize, 10), n);
    try std.testing.expectEqualStrings("helloworld", read_buf[0..n]);
}

test "poll rejects stream data beyond known final size" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();

    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 41,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    const fin_frame = frame_mod.StreamFrame{
        .stream_id = 7,
        .offset = 0,
        .data = "abc",
        .fin = true,
    };
    packet_len += try fin_frame.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    packet_len = try header.encode(&packet_buf);
    const overflow_frame = frame_mod.StreamFrame{
        .stream_id = 7,
        .offset = 3,
        .data = "x",
        .fin = false,
    };
    packet_len += try overflow_frame.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    var closing_event: ?types_mod.ConnectionEvent = null;
    while (conn.nextEvent()) |event| {
        if (event == .closing) {
            closing_event = event;
            break;
        }
    }

    try std.testing.expect(closing_event != null);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        closing_event.?.closing.error_code,
    );
}

test "poll rejects RESET_STREAM with inconsistent final size" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();

    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 42,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    const data_frame = frame_mod.StreamFrame{
        .stream_id = 9,
        .offset = 0,
        .data = "abcd",
        .fin = false,
    };
    packet_len += try data_frame.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    packet_len = try header.encode(&packet_buf);
    const reset_frame = frame_mod.ResetStreamFrame{
        .stream_id = 9,
        .error_code = 0,
        .final_size = 2,
    };
    packet_len += try reset_frame.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    var closing_event: ?types_mod.ConnectionEvent = null;
    while (conn.nextEvent()) |event| {
        if (event == .closing) {
            closing_event = event;
            break;
        }
    }

    try std.testing.expect(closing_event != null);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        closing_event.?.closing.error_code,
    );
}

test "poll rejects overlapping out-of-order stream frames" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 43,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    const frame_a = frame_mod.StreamFrame{
        .stream_id = 11,
        .offset = 5,
        .data = "world",
        .fin = false,
    };
    packet_len += try frame_a.encode(packet_buf[packet_len..]);

    const frame_b = frame_mod.StreamFrame{
        .stream_id = 11,
        .offset = 7,
        .data = "rld!",
        .fin = false,
    };
    packet_len += try frame_b.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    var closing_event: ?types_mod.ConnectionEvent = null;
    while (conn.nextEvent()) |event| {
        if (event == .closing) {
            closing_event = event;
            break;
        }
    }

    try std.testing.expect(closing_event != null);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        closing_event.?.closing.error_code,
    );
}

test "poll processes ACK frame carrying ranges" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);
    conn.internal_conn.?.trackPacketSent(1200, true); // pn 0
    conn.internal_conn.?.trackPacketSent(1200, true); // pn 1
    conn.internal_conn.?.trackPacketSent(1200, true); // pn 2

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();

    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 38,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    const ack = frame_mod.AckFrame{
        .largest_acked = 2,
        .ack_delay = 1,
        .first_ack_range = 0,
        .ack_ranges = &[_]frame_mod.AckFrame.AckRange{
            .{ .gap = 0, .ack_range_length = 0 },
        },
    };
    packet_len += try ack.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    try std.testing.expect(conn.nextEvent() == null);
    try std.testing.expectEqual(types_mod.ConnectionState.established, conn.getState());
}

test "poll rejects ACK for unsent packet number" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();

    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 39,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    const ack = frame_mod.AckFrame{
        .largest_acked = 5,
        .ack_delay = 0,
        .first_ack_range = 0,
        .ack_ranges = &.{},
    };
    packet_len += try ack.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        event.?.closing.error_code,
    );
}

test "poll rejects malformed ACK range encoding" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();

    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 40,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    const malformed_ack = frame_mod.AckFrame{
        .largest_acked = 3,
        .ack_delay = 0,
        .first_ack_range = 4,
        .ack_ranges = &.{},
        .ecn_counts = null,
    };
    packet_len += try malformed_ack.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        event.?.closing.error_code,
    );
}

test "poll rejects ACK frame with excessive acknowledged packet count" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    // Track enough sent packets so largest_acked itself is plausible.
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        conn.internal_conn.?.trackPacketSent(1200, true);
    }

    var payload: [128]u8 = undefined;
    const ack = frame_mod.AckFrame{
        .largest_acked = 1500,
        .ack_delay = 0,
        .first_ack_range = 1500, // implies 1501 acked packets, above limit
        .ack_ranges = &.{},
        .ecn_counts = null,
    };
    const payload_len = try ack.encode(&payload);

    try expectProtocolViolationFromShortHeaderPayload(&conn, allocator, payload[0..payload_len], 58);
}

test "poll accepts ACK in handshake space when handshake packets were sent" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    conn.internal_conn.?.trackPacketSentInSpace(.handshake, 1200, true); // pn 0
    conn.internal_conn.?.trackPacketSentInSpace(.handshake, 1200, true); // pn 1

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .handshake,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 4,
        .packet_number = 59,
    };

    var packet_len = try header.encode(&packet_buf);
    const ack = frame_mod.AckFrame{
        .largest_acked = 1,
        .ack_delay = 0,
        .first_ack_range = 0,
        .ack_ranges = &.{},
        .ecn_counts = null,
    };
    packet_len += try ack.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    var saw_closing = false;
    while (conn.nextEvent()) |event| {
        if (event == .closing) {
            saw_closing = true;
            break;
        }
    }
    try std.testing.expect(!saw_closing);
}

test "poll rejects ACK in handshake space for unsent handshake packet" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var payload: [64]u8 = undefined;
    const ack = frame_mod.AckFrame{
        .largest_acked = 5,
        .ack_delay = 0,
        .first_ack_range = 0,
        .ack_ranges = &.{},
        .ecn_counts = null,
    };
    const payload_len = try ack.encode(&payload);

    try expectProtocolViolationFromLongHeaderPayload(&conn, allocator, .handshake, payload[0..payload_len], 60);
}

test "poll routes RESET_STREAM frame to stream_closed event" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();

    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 5,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    const reset_frame = frame_mod.ResetStreamFrame{
        .stream_id = 4,
        .error_code = 99,
        .final_size = 0,
    };
    packet_len += try reset_frame.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    var stream_closed_event: ?types_mod.ConnectionEvent = null;
    while (conn.nextEvent()) |event| {
        if (event == .stream_closed) {
            stream_closed_event = event;
            break;
        }
    }
    try std.testing.expect(stream_closed_event != null);
    try std.testing.expectEqual(@as(u64, 4), stream_closed_event.?.stream_closed.id);
    try std.testing.expectEqual(@as(?u64, 99), stream_closed_event.?.stream_closed.error_code);

    var read_buf: [8]u8 = undefined;
    try std.testing.expectError(types_mod.QuicError.StreamClosed, conn.streamRead(4, &read_buf));

    const info = try conn.getStreamInfo(4);
    try std.testing.expectEqual(types_mod.StreamState.recv_closed, info.state);
}

test "poll routes PATH_CHALLENGE frame and queues response token" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();

    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 6,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    const challenge = frame_mod.PathChallengeFrame{ .data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 } };
    packet_len += try challenge.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    _ = conn.nextEvent(); // connected

    const pending = conn.internal_conn.?.popPathResponse();
    try std.testing.expect(pending != null);
    try std.testing.expectEqualSlices(u8, &challenge.data, &pending.?);
}

test "poll routes PATH_RESPONSE frame and validates peer path" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    const token = [_]u8{ 9, 8, 7, 6, 5, 4, 3, 2 };
    conn.internal_conn.?.beginPathValidation(token);
    try std.testing.expect(!conn.internal_conn.?.peer_validated);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();

    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 7,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    const response = frame_mod.PathResponseFrame{ .data = token };
    packet_len += try response.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    _ = conn.nextEvent(); // connected

    try std.testing.expect(conn.internal_conn.?.peer_validated);
}

test "ssh mode rejects unidirectional stream open" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    const internal_conn = try allocator.create(conn_internal.Connection);
    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });
    internal_conn.* = try conn_internal.Connection.initClient(allocator, .ssh, local_cid, remote_cid);
    internal_conn.markEstablished();

    conn.internal_conn = internal_conn;
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    try std.testing.expectError(types_mod.QuicError.StreamError, conn.openStream(false));
}

test "openStream requires negotiated handshake readiness" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    const internal_conn = try allocator.create(conn_internal.Connection);
    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });
    internal_conn.* = try conn_internal.Connection.initClient(allocator, .ssh, local_cid, remote_cid);
    internal_conn.markEstablished();

    conn.internal_conn = internal_conn;
    conn.state = .established;

    try std.testing.expectError(types_mod.QuicError.ConnectionNotEstablished, conn.openStream(true));

    try applyDefaultPeerTransportParams(&conn, allocator);
    _ = try conn.openStream(true);
}

test "closeStream requires negotiated handshake readiness" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    const internal_conn = try allocator.create(conn_internal.Connection);
    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });
    internal_conn.* = try conn_internal.Connection.initClient(allocator, .ssh, local_cid, remote_cid);
    internal_conn.markEstablished();

    conn.internal_conn = internal_conn;
    conn.state = .established;

    const stream_id = try conn.internal_conn.?.openStream(true);
    try std.testing.expectError(
        types_mod.QuicError.ConnectionNotEstablished,
        conn.closeStream(stream_id, 0),
    );

    try applyDefaultPeerTransportParams(&conn, allocator);
    try conn.closeStream(stream_id, 0);
}

test "applyPeerTransportParams rejects invalid peer parameters" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    const internal_conn = try allocator.create(conn_internal.Connection);
    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });
    internal_conn.* = try conn_internal.Connection.initClient(allocator, .ssh, local_cid, remote_cid);
    internal_conn.markEstablished();

    conn.internal_conn = internal_conn;
    conn.state = .established;

    var encoded = transport_params_mod.TransportParams.init();
    encoded.max_udp_payload_size = 1199;
    const payload = try encoded.encode(allocator);
    defer allocator.free(payload);

    try std.testing.expectError(types_mod.QuicError.ProtocolViolation, conn.applyPeerTransportParams(payload));
    try std.testing.expectEqual(types_mod.ConnectionState.draining, conn.getState());

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.transport_parameter_error)),
        event.?.closing.error_code,
    );
}

test "applyPeerTransportParams rejects ack_delay_exponent above limit" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    const internal_conn = try allocator.create(conn_internal.Connection);
    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });
    internal_conn.* = try conn_internal.Connection.initClient(allocator, .ssh, local_cid, remote_cid);
    internal_conn.markEstablished();

    conn.internal_conn = internal_conn;
    conn.state = .established;

    var encoded = transport_params_mod.TransportParams.init();
    encoded.ack_delay_exponent = 21;
    const payload = try encoded.encode(allocator);
    defer allocator.free(payload);

    try expectTransportParamProtocolViolation(&conn, payload);
}

test "applyPeerTransportParams rejects max_ack_delay out of range" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    const internal_conn = try allocator.create(conn_internal.Connection);
    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });
    internal_conn.* = try conn_internal.Connection.initClient(allocator, .ssh, local_cid, remote_cid);
    internal_conn.markEstablished();

    conn.internal_conn = internal_conn;
    conn.state = .established;

    var encoded = transport_params_mod.TransportParams.init();
    encoded.max_ack_delay = 16384;
    const payload = try encoded.encode(allocator);
    defer allocator.free(payload);

    try expectTransportParamProtocolViolation(&conn, payload);
}

test "applyPeerTransportParams rejects active_connection_id_limit below two" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    const internal_conn = try allocator.create(conn_internal.Connection);
    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });
    internal_conn.* = try conn_internal.Connection.initClient(allocator, .ssh, local_cid, remote_cid);
    internal_conn.markEstablished();

    conn.internal_conn = internal_conn;
    conn.state = .established;

    var encoded = transport_params_mod.TransportParams.init();
    encoded.active_connection_id_limit = 1;
    const payload = try encoded.encode(allocator);
    defer allocator.free(payload);

    try expectTransportParamProtocolViolation(&conn, payload);
}

test "applyPeerTransportParams rejects duplicate transport parameter IDs" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    const internal_conn = try allocator.create(conn_internal.Connection);
    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });
    internal_conn.* = try conn_internal.Connection.initClient(allocator, .ssh, local_cid, remote_cid);
    internal_conn.markEstablished();

    conn.internal_conn = internal_conn;
    conn.state = .established;

    // Duplicate max_idle_timeout parameter encoding.
    var payload = std.ArrayList(u8){};
    defer payload.deinit(allocator);

    var id_buf: [8]u8 = undefined;
    var len_buf: [8]u8 = undefined;
    var value_buf: [8]u8 = undefined;
    const id_len = try varint.encode(@intFromEnum(transport_params_mod.TransportParamId.max_idle_timeout), &id_buf);
    const value_len = try varint.encode(10, &value_buf);
    const plen_len = try varint.encode(value_len, &len_buf);

    try payload.appendSlice(allocator, id_buf[0..id_len]);
    try payload.appendSlice(allocator, len_buf[0..plen_len]);
    try payload.appendSlice(allocator, value_buf[0..value_len]);
    try payload.appendSlice(allocator, id_buf[0..id_len]);
    try payload.appendSlice(allocator, len_buf[0..plen_len]);
    try payload.appendSlice(allocator, value_buf[0..value_len]);

    try expectTransportParamProtocolViolation(&conn, payload.items);
}

test "applyPeerTransportParams updates stream open limits" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    const internal_conn = try allocator.create(conn_internal.Connection);
    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });
    internal_conn.* = try conn_internal.Connection.initClient(allocator, .ssh, local_cid, remote_cid);
    internal_conn.markEstablished();

    conn.internal_conn = internal_conn;
    conn.state = .established;

    var encoded = transport_params_mod.TransportParams.init();
    encoded.initial_max_streams_bidi = 1;
    encoded.initial_max_streams_uni = 0;
    const payload = try encoded.encode(allocator);
    defer allocator.free(payload);

    try conn.applyPeerTransportParams(payload);

    _ = try conn.openStream(true);
    try std.testing.expectError(types_mod.QuicError.StreamLimitReached, conn.openStream(true));
    try std.testing.expectError(types_mod.QuicError.StreamError, conn.openStream(false));
}

test "poll maps stream receive flow control violation to closing event" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.streams.setLocalReceiveStreamDataLimits(4, 4, 4);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();

    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 21,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    const stream_frame = frame_mod.StreamFrame{
        .stream_id = 1,
        .offset = 0,
        .data = "12345",
        .fin = false,
    };
    packet_len += try stream_frame.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    _ = conn.nextEvent(); // connected
    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.flow_control_error)),
        event.?.closing.error_code,
    );
    try std.testing.expectEqual(types_mod.ConnectionState.draining, conn.getState());
}

test "poll rejects stream frame in Initial packet space even when established" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();

    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .initial,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 24,
        .packet_number = 22,
    };

    var packet_len = try header.encode(&packet_buf);
    const stream_frame = frame_mod.StreamFrame{
        .stream_id = 1,
        .offset = 0,
        .data = "abc",
        .fin = false,
    };
    packet_len += try stream_frame.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const first = conn.nextEvent();
    try std.testing.expect(first != null);
    const event = if (first.? == .connected) conn.nextEvent() else first;
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        event.?.closing.error_code,
    );
    try std.testing.expectEqual(types_mod.ConnectionState.draining, conn.getState());
}

test "poll rejects reserved frame type in Initial packet space" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .initial,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 4,
        .packet_number = 23,
    };
    var packet_len = try header.encode(&packet_buf);
    packet_buf[packet_len] = 0x1f; // reserved frame type
    packet_len += 1;

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const first = conn.nextEvent();
    const second = conn.nextEvent();
    const first_is_closing = first != null and first.? == .closing;
    const second_is_closing = second != null and second.? == .closing;
    try std.testing.expect(first_is_closing or second_is_closing);

    const event = if (first_is_closing) first.? else second.?;
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        event.closing.error_code,
    );
}

test "poll ignores unknown frame type in application packet space" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 24,
        .key_phase = false,
    };
    var packet_len = try header.encode(&packet_buf);
    packet_buf[packet_len] = 0x2b; // unknown frame type
    packet_len += 1;

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    try std.testing.expect(conn.nextEvent() == null);
    try std.testing.expectEqual(types_mod.ConnectionState.established, conn.getState());
}

test "poll rejects truncated PATH_CHALLENGE frame payload" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    // PATH_CHALLENGE requires 8 bytes of payload; 3 should fail decode.
    try expectProtocolViolationFromShortHeaderPayload(&conn, allocator, &[_]u8{ 0x1a, 1, 2, 3 }, 61);
}

test "poll rejects truncated PATH_RESPONSE frame payload" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    // PATH_RESPONSE requires 8 bytes of payload; 2 should fail decode.
    try expectProtocolViolationFromShortHeaderPayload(&conn, allocator, &[_]u8{ 0x1b, 9, 9 }, 62);
}

test "poll rejects malformed CONNECTION_CLOSE payload" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    // CONNECTION_CLOSE transport format:
    // type, error_code varint, frame_type varint, reason_len varint, reason bytes
    // reason_len=2 but only one reason byte follows.
    try expectProtocolViolationFromShortHeaderPayload(&conn, allocator, &[_]u8{ 0x1c, 0x00, 0x00, 0x02, 'x' }, 63);
}

test "repeated CONNECTION_CLOSE frames emit single closing event while draining" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 64,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    const close_frame = frame_mod.ConnectionCloseFrame{
        .error_code = 0x0a,
        .frame_type = null,
        .reason = "peer-close",
    };
    packet_len += try close_frame.encode(packet_buf[packet_len..]);

    // First close frame transitions to draining and emits closing.
    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    // Repeated close stimulus while draining must not enqueue another closing event.
    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    var closing_count: usize = 0;
    while (conn.nextEvent()) |event| {
        if (event == .closing) {
            closing_count += 1;
        }
    }

    try std.testing.expectEqual(@as(usize, 1), closing_count);
    try std.testing.expectEqual(types_mod.ConnectionState.draining, conn.getState());
}

test "draining ignores subsequent frame stimuli until close deadline" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    try conn.close(100, "local-close");
    _ = conn.nextEvent(); // closing

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 65,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    packet_buf[packet_len] = 0x01; // PING
    packet_len += 1;

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    // Still draining; no new events emitted from incoming packet.
    try std.testing.expect(conn.nextEvent() == null);
    try std.testing.expectEqual(types_mod.ConnectionState.draining, conn.getState());
}

test "poll rejects reserved frame type in application packet space" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 32,
        .key_phase = false,
    };
    var packet_len = try header.encode(&packet_buf);
    packet_buf[packet_len] = 0x1f; // reserved frame type
    packet_len += 1;

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        event.?.closing.error_code,
    );
}

test "poll rejects short header with fixed bit cleared" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 33,
        .key_phase = false,
    };
    var packet_len = try header.encode(&packet_buf);
    packet_buf[0] &= 0xBF; // clear fixed bit
    packet_buf[packet_len] = 0x01; // PING
    packet_len += 1;

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        event.?.closing.error_code,
    );
}

test "poll rejects truncated ACK frame payload" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    try expectProtocolViolationFromShortHeaderPayload(&conn, allocator, &[_]u8{0x02}, 34);
}

test "poll rejects truncated RESET_STREAM frame payload" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    // RESET_STREAM frame type + partial stream id varint only.
    try expectProtocolViolationFromShortHeaderPayload(&conn, allocator, &[_]u8{ 0x04, 0x00 }, 35);
}

test "poll rejects truncated NEW_CONNECTION_ID frame payload" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    // NEW_CONNECTION_ID frame type + sequence number only.
    try expectProtocolViolationFromShortHeaderPayload(&conn, allocator, &[_]u8{ 0x18, 0x00 }, 36);
}

test "poll rejects truncated MAX_DATA varint payload" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    try expectProtocolViolationFromShortHeaderPayload(&conn, allocator, &[_]u8{ 0x10, 0x40 }, 69);
}

test "poll rejects truncated RETIRE_CONNECTION_ID varint payload" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    try expectProtocolViolationFromShortHeaderPayload(&conn, allocator, &[_]u8{ 0x19, 0x40 }, 70);
}

test "poll rejects STREAM frame with oversized length claim" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    // STREAM frame: type=0x0e (OFF+LEN), stream=0, offset=0, len=5, data="ab".
    try expectProtocolViolationFromShortHeaderPayload(
        &conn,
        allocator,
        &[_]u8{ 0x0e, 0x00, 0x00, 0x05, 'a', 'b' },
        71,
    );
}

test "poll rejects long header with fixed bit cleared" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .initial,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 4,
        .packet_number = 37,
    };
    var packet_len = try header.encode(&packet_buf);
    packet_buf[0] &= 0xBF; // clear fixed bit
    packet_buf[packet_len] = 0x01; // PING
    packet_len += 1;

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        event.?.closing.error_code,
    );

    const stats = conn.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.packets_invalid);
}

test "poll rejects STREAM frame in Handshake packet space" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var payload: [64]u8 = undefined;
    const stream_frame = frame_mod.StreamFrame{
        .stream_id = 2,
        .offset = 0,
        .data = "hs-data",
        .fin = false,
    };
    const payload_len = try stream_frame.encode(&payload);

    try expectProtocolViolationFromLongHeaderPayload(
        &conn,
        allocator,
        .handshake,
        payload[0..payload_len],
        77,
    );
}

test "poll accepts ACK in Initial packet space for tracked Initial packets" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.trackPacketSentInSpace(.initial, 1200, true); // pn 0
    conn.internal_conn.?.trackPacketSentInSpace(.initial, 1200, true); // pn 1

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .initial,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 8,
        .packet_number = 78,
    };

    var packet_len = try header.encode(&packet_buf);
    const ack = frame_mod.AckFrame{
        .largest_acked = 1,
        .ack_delay = 0,
        .first_ack_range = 0,
        .ack_ranges = &.{},
        .ecn_counts = null,
    };
    packet_len += try ack.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    var saw_closing = false;
    while (conn.nextEvent()) |event| {
        if (event == .closing) {
            saw_closing = true;
            break;
        }
    }
    try std.testing.expect(!saw_closing);
}

test "poll accepts CRYPTO frame in Handshake packet space" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .handshake,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 8,
        .packet_number = 79,
    };

    var packet_len = try header.encode(&packet_buf);
    const crypto_frame = frame_mod.CryptoFrame{ .offset = 0, .data = "hs" };
    packet_len += try crypto_frame.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    var saw_closing = false;
    while (conn.nextEvent()) |event| {
        if (event == .closing) {
            saw_closing = true;
            break;
        }
    }
    try std.testing.expect(!saw_closing);
}

test "poll accepts legal handshake ACK then rejects illegal HANDSHAKE_DONE" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.trackPacketSentInSpace(.handshake, 1200, true); // pn 0

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .handshake,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 8,
        .packet_number = 80,
    };

    var packet_len = try header.encode(&packet_buf);
    const ack = frame_mod.AckFrame{
        .largest_acked = 0,
        .ack_delay = 0,
        .first_ack_range = 0,
        .ack_ranges = &.{},
        .ecn_counts = null,
    };
    packet_len += try ack.encode(packet_buf[packet_len..]);
    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    var saw_closing_first = false;
    while (conn.nextEvent()) |event| {
        if (event == .closing) {
            saw_closing_first = true;
            break;
        }
    }
    try std.testing.expect(!saw_closing_first);

    packet_len = try header.encode(&packet_buf);
    packet_buf[packet_len] = 0x1e; // HANDSHAKE_DONE (illegal in handshake space)
    packet_len += 1;
    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    var closing: ?types_mod.ConnectionEvent = null;
    while (conn.nextEvent()) |event| {
        if (event == .closing) {
            closing = event;
            break;
        }
    }
    try std.testing.expect(closing != null);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        closing.?.closing.error_code,
    );
}

test "poll preserves handshake ACK effect before illegal HANDSHAKE_DONE in same packet" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.trackPacketSentInSpace(.handshake, 1200, true); // pn 0
    conn.internal_conn.?.trackPacketSentInSpace(.handshake, 1200, true); // pn 1

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .handshake,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 20,
        .packet_number = 87,
    };

    var packet_len = try header.encode(&packet_buf);
    const ack = frame_mod.AckFrame{
        .largest_acked = 1,
        .ack_delay = 0,
        .first_ack_range = 0,
        .ack_ranges = &.{},
        .ecn_counts = null,
    };
    packet_len += try ack.encode(packet_buf[packet_len..]);
    packet_buf[packet_len] = 0x1e; // illegal in handshake space
    packet_len += 1;

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    try std.testing.expect(conn.internal_conn.?.largest_acked >= 1);

    var closing: ?types_mod.ConnectionEvent = null;
    while (conn.nextEvent()) |event| {
        if (event == .closing) {
            closing = event;
            break;
        }
    }
    try std.testing.expect(closing != null);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        closing.?.closing.error_code,
    );
}

test "poll ignores trailing handshake ACK after first illegal frame" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.trackPacketSentInSpace(.handshake, 1200, true); // pn 0
    conn.internal_conn.?.trackPacketSentInSpace(.handshake, 1200, true); // pn 1

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .handshake,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 20,
        .packet_number = 88,
    };

    var packet_len = try header.encode(&packet_buf);
    packet_buf[packet_len] = 0x1e; // illegal in handshake space
    packet_len += 1;

    const ack = frame_mod.AckFrame{
        .largest_acked = 1,
        .ack_delay = 0,
        .first_ack_range = 0,
        .ack_ranges = &.{},
        .ecn_counts = null,
    };
    packet_len += try ack.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    try std.testing.expectEqual(@as(u64, 0), conn.internal_conn.?.largest_acked);

    var closing: ?types_mod.ConnectionEvent = null;
    while (conn.nextEvent()) |event| {
        if (event == .closing) {
            closing = event;
            break;
        }
    }
    try std.testing.expect(closing != null);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        closing.?.closing.error_code,
    );
}

test "poll processes HANDSHAKE_DONE then STREAM in application packet" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 99,
        .key_phase = false,
    };
    var packet_len = try header.encode(&packet_buf);

    packet_buf[packet_len] = 0x1e; // HANDSHAKE_DONE
    packet_len += 1;

    const stream_frame = frame_mod.StreamFrame{
        .stream_id = 33,
        .offset = 0,
        .data = "hs-done-stream",
        .fin = false,
    };
    packet_len += try stream_frame.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    var saw_stream = false;
    var saw_closing = false;
    while (conn.nextEvent()) |event| {
        if (event == .stream_readable and event.stream_readable == 33) saw_stream = true;
        if (event == .closing) saw_closing = true;
    }

    try std.testing.expect(saw_stream);
    try std.testing.expect(!saw_closing);
}

test "poll rejects CRYPTO frame in application packet space" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 27,
        .key_phase = false,
    };
    var packet_len = try header.encode(&packet_buf);
    const crypto_frame = frame_mod.CryptoFrame{ .offset = 0, .data = "abc" };
    packet_len += try crypto_frame.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        event.?.closing.error_code,
    );

    const stats = conn.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.packets_invalid);
}

test "poll allows CRYPTO frame in Initial packet space" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .initial,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 8,
        .packet_number = 28,
    };
    var packet_len = try header.encode(&packet_buf);
    const crypto_frame = frame_mod.CryptoFrame{ .offset = 0, .data = "abc" };
    packet_len += try crypto_frame.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const first = conn.nextEvent();
    try std.testing.expect(first != null);
    try std.testing.expect(first.? == .connected);
    try std.testing.expect(conn.nextEvent() == null);

    try std.testing.expectEqual(types_mod.ConnectionState.established, conn.getState());
}

test "poll rejects malformed CRYPTO frame payload in initial space" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    // CRYPTO frame with truncated length varint.
    try expectProtocolViolationFromLongHeaderPayload(
        &conn,
        allocator,
        .initial,
        &[_]u8{ 0x06, 0x00, 0x40 },
        96,
    );
}

test "poll processes padding before stream frame" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 97,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    packet_buf[packet_len] = 0x00; // PADDING
    packet_len += 1;

    const stream_frame = frame_mod.StreamFrame{
        .stream_id = 32,
        .offset = 0,
        .data = "pad-stream",
        .fin = false,
    };
    packet_len += try stream_frame.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    var saw_stream = false;
    while (conn.nextEvent()) |event| {
        if (event == .stream_readable and event.stream_readable == 32) {
            saw_stream = true;
            break;
        }
    }
    try std.testing.expect(saw_stream);
}

test "poll rejects MAX_DATA frame in Initial packet space" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .initial,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 6,
        .packet_number = 29,
    };
    var packet_len = try header.encode(&packet_buf);
    packet_buf[packet_len] = 0x10; // MAX_DATA
    packet_len += 1;
    packet_buf[packet_len] = 0x00; // max_data = 0
    packet_len += 1;

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const first = conn.nextEvent();
    const second = conn.nextEvent();
    const closing = if (first != null and first.? == .closing)
        first
    else if (second != null and second.? == .closing)
        second
    else
        null;
    try std.testing.expect(closing != null);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        closing.?.closing.error_code,
    );
}

test "poll preserves initial ACK effect before later illegal frame" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.trackPacketSentInSpace(.initial, 1200, true); // pn 0
    conn.internal_conn.?.trackPacketSentInSpace(.initial, 1200, true); // pn 1

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .initial,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 24,
        .packet_number = 85,
    };
    var packet_len = try header.encode(&packet_buf);

    const ack = frame_mod.AckFrame{
        .largest_acked = 1,
        .ack_delay = 0,
        .first_ack_range = 0,
        .ack_ranges = &.{},
        .ecn_counts = null,
    };
    packet_len += try ack.encode(packet_buf[packet_len..]);

    const illegal = frame_mod.MaxDataFrame{ .max_data = 0 };
    packet_len += try illegal.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    try std.testing.expect(conn.internal_conn.?.largest_acked >= 1);

    var closing: ?types_mod.ConnectionEvent = null;
    while (conn.nextEvent()) |event| {
        if (event == .closing) {
            closing = event;
            break;
        }
    }
    try std.testing.expect(closing != null);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        closing.?.closing.error_code,
    );
}

test "poll ignores trailing initial ACK after first illegal frame" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.trackPacketSentInSpace(.initial, 1200, true); // pn 0
    conn.internal_conn.?.trackPacketSentInSpace(.initial, 1200, true); // pn 1

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .initial,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 24,
        .packet_number = 86,
    };
    var packet_len = try header.encode(&packet_buf);

    const illegal = frame_mod.MaxDataFrame{ .max_data = 0 };
    packet_len += try illegal.encode(packet_buf[packet_len..]);

    const ack = frame_mod.AckFrame{
        .largest_acked = 1,
        .ack_delay = 0,
        .first_ack_range = 0,
        .ack_ranges = &.{},
        .ecn_counts = null,
    };
    packet_len += try ack.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    try std.testing.expectEqual(@as(u64, 0), conn.internal_conn.?.largest_acked);

    var closing: ?types_mod.ConnectionEvent = null;
    while (conn.nextEvent()) |event| {
        if (event == .closing) {
            closing = event;
            break;
        }
    }
    try std.testing.expect(closing != null);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        closing.?.closing.error_code,
    );
}

test "poll rejects PATH_CHALLENGE frame in zero_rtt packet space" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .zero_rtt,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 16,
        .packet_number = 30,
    };
    var packet_len = try header.encode(&packet_buf);
    const challenge = frame_mod.PathChallengeFrame{ .data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 } };
    packet_len += try challenge.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        event.?.closing.error_code,
    );
}

test "poll allows STREAM frame in zero_rtt packet space" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .zero_rtt,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 24,
        .packet_number = 31,
    };

    var packet_len = try header.encode(&packet_buf);
    const stream_frame = frame_mod.StreamFrame{
        .stream_id = 4,
        .offset = 0,
        .data = "zrtt-stream",
        .fin = false,
    };
    packet_len += try stream_frame.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .stream_readable);
    try std.testing.expectEqual(@as(u64, 4), event.?.stream_readable);
}

test "poll allows mixed legal frames in zero_rtt packet space" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .zero_rtt,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 32,
        .packet_number = 81,
    };

    var packet_len = try header.encode(&packet_buf);
    packet_buf[packet_len] = 0x01; // PING
    packet_len += 1;

    const max_data = frame_mod.MaxDataFrame{ .max_data = 4096 };
    packet_len += try max_data.encode(packet_buf[packet_len..]);

    const stream_frame = frame_mod.StreamFrame{
        .stream_id = 15,
        .offset = 0,
        .data = "zmix",
        .fin = false,
    };
    packet_len += try stream_frame.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    var saw_stream = false;
    var saw_closing = false;
    while (conn.nextEvent()) |event| {
        if (event == .stream_readable and event.stream_readable == 15) saw_stream = true;
        if (event == .closing) saw_closing = true;
    }

    try std.testing.expect(saw_stream);
    try std.testing.expect(!saw_closing);
}

test "poll preserves zero_rtt stream side effect before later illegal frame" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .zero_rtt,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 48,
        .packet_number = 82,
    };

    var packet_len = try header.encode(&packet_buf);
    const stream_frame = frame_mod.StreamFrame{
        .stream_id = 16,
        .offset = 0,
        .data = "ok-first",
        .fin = false,
    };
    packet_len += try stream_frame.encode(packet_buf[packet_len..]);

    const illegal = frame_mod.PathChallengeFrame{ .data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 } };
    packet_len += try illegal.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    var saw_stream = false;
    var saw_closing = false;
    while (conn.nextEvent()) |event| {
        if (event == .stream_readable and event.stream_readable == 16) saw_stream = true;
        if (event == .closing) saw_closing = true;
    }

    try std.testing.expect(saw_stream);
    try std.testing.expect(saw_closing);

    const info = try conn.getStreamInfo(16);
    try std.testing.expectEqual(@as(types_mod.StreamId, 16), info.id);
}

test "poll ignores trailing legal zero_rtt frame after first illegal frame" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .zero_rtt,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 48,
        .packet_number = 83,
    };

    var packet_len = try header.encode(&packet_buf);
    const illegal = frame_mod.PathChallengeFrame{ .data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 } };
    packet_len += try illegal.encode(packet_buf[packet_len..]);

    const stream_frame = frame_mod.StreamFrame{
        .stream_id = 17,
        .offset = 0,
        .data = "late",
        .fin = false,
    };
    packet_len += try stream_frame.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    var saw_stream = false;
    var saw_closing = false;
    while (conn.nextEvent()) |event| {
        if (event == .stream_readable and event.stream_readable == 17) saw_stream = true;
        if (event == .closing) saw_closing = true;
    }

    try std.testing.expect(!saw_stream);
    try std.testing.expect(saw_closing);
    try std.testing.expectError(types_mod.QuicError.StreamNotFound, conn.getStreamInfo(17));
}

test "poll rejects ACK frame in zero_rtt packet space" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var payload: [64]u8 = undefined;
    const ack = frame_mod.AckFrame{
        .largest_acked = 0,
        .ack_delay = 0,
        .first_ack_range = 0,
        .ack_ranges = &.{},
        .ecn_counts = null,
    };
    const payload_len = try ack.encode(&payload);

    try expectProtocolViolationFromLongHeaderPayload(
        &conn,
        allocator,
        .zero_rtt,
        payload[0..payload_len],
        84,
    );
}

test "poll rejects NEW_TOKEN frame in Initial packet space" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .initial,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 4,
        .packet_number = 33,
    };
    var packet_len = try header.encode(&packet_buf);
    packet_buf[packet_len] = 0x07; // NEW_TOKEN
    packet_len += 1;

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const first = conn.nextEvent();
    const second = conn.nextEvent();
    const closing = if (first != null and first.? == .closing)
        first
    else if (second != null and second.? == .closing)
        second
    else
        null;
    try std.testing.expect(closing != null);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        closing.?.closing.error_code,
    );
}

test "poll accepts NEW_TOKEN frame in application packet space for client" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 46,
        .key_phase = false,
    };
    var packet_len = try header.encode(&packet_buf);

    const new_token = frame_mod.NewTokenFrame{ .token = "retry-ticket-123" };
    packet_len += try new_token.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    try std.testing.expect(conn.nextEvent() == null);
    const token = conn.getLatestNewToken();
    try std.testing.expect(token != null);
    try std.testing.expectEqualStrings("retry-ticket-123", token.?);

    conn.clearLatestNewToken();
    try std.testing.expect(conn.getLatestNewToken() == null);
}

test "multiple NEW_TOKEN frames keep latest token" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 86,
        .key_phase = false,
    };
    var packet_len = try header.encode(&packet_buf);

    const first_token = frame_mod.NewTokenFrame{ .token = "token-first" };
    packet_len += try first_token.encode(packet_buf[packet_len..]);
    const second_token = frame_mod.NewTokenFrame{ .token = "token-second" };
    packet_len += try second_token.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const token = conn.getLatestNewToken();
    try std.testing.expect(token != null);
    try std.testing.expectEqualStrings("token-second", token.?);
}

test "poll rejects NEW_TOKEN frame in application packet space for server" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshServer("secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.accept("127.0.0.1", 0);

    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });
    const internal_conn = try allocator.create(conn_internal.Connection);
    internal_conn.* = try conn_internal.Connection.initServer(allocator, .ssh, local_cid, remote_cid);
    internal_conn.markEstablished();

    if (conn.internal_conn) |old| {
        old.deinit();
        allocator.destroy(old);
    }
    conn.internal_conn = internal_conn;
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = local_cid,
        .packet_number = 47,
        .key_phase = false,
    };
    var packet_len = try header.encode(&packet_buf);

    const new_token = frame_mod.NewTokenFrame{ .token = "client-must-not-send" };
    packet_len += try new_token.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        event.?.closing.error_code,
    );
}

test "server token validator rejects invalid Initial token" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshServer("secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.accept("127.0.0.1", 0);

    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 1, 3, 3, 7 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 5, 7, 7, 5 });
    const internal_conn = try allocator.create(conn_internal.Connection);
    internal_conn.* = try conn_internal.Connection.initServer(allocator, .ssh, local_cid, remote_cid);

    if (conn.internal_conn) |old| {
        old.deinit();
        allocator.destroy(old);
    }
    conn.internal_conn = internal_conn;

    const expected_token: []const u8 = "valid-token";
    conn.setTokenValidator(@ptrCast(@constCast(&expected_token)), tokenEqualsValidator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .initial,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = local_cid,
        .src_conn_id = remote_cid,
        .token = "invalid-token",
        .payload_len = 4,
        .packet_number = 48,
    };
    var packet_len = try header.encode(&packet_buf);
    packet_buf[packet_len] = 0x01; // PING
    packet_len += 1;

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.invalid_token)),
        event.?.closing.error_code,
    );

    const stats = conn.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.packets_invalid);
}

test "packet-space frame legality matrix baseline" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    const initial_allowed = [_]u64{ 0x00, 0x01, 0x02, 0x03, 0x06, 0x1c, 0x1d };
    for (initial_allowed) |ft| {
        try conn.validateFrameAllowedInPacketSpace(ft, .initial);
        try conn.validateFrameAllowedInPacketSpace(ft, .handshake);
    }

    const initial_disallowed = [_]u64{ 0x04, 0x07, 0x10, 0x18, 0x1e, 0x08 };
    for (initial_disallowed) |ft| {
        try std.testing.expectError(types_mod.QuicError.ProtocolViolation, conn.validateFrameAllowedInPacketSpace(ft, .initial));
    }

    const zero_rtt_allowed = [_]u64{ 0x00, 0x01, 0x04, 0x05, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x1c, 0x1d, 0x08 };
    for (zero_rtt_allowed) |ft| {
        try conn.validateFrameAllowedInPacketSpace(ft, .zero_rtt);
    }

    const zero_rtt_disallowed = [_]u64{ 0x02, 0x03, 0x06, 0x07, 0x18, 0x19, 0x1a, 0x1b, 0x1e };
    for (zero_rtt_disallowed) |ft| {
        try std.testing.expectError(types_mod.QuicError.ProtocolViolation, conn.validateFrameAllowedInPacketSpace(ft, .zero_rtt));
    }

    try conn.validateFrameAllowedInPacketSpace(0x2b, .application); // unknown, non-reserved
    try std.testing.expectError(types_mod.QuicError.ProtocolViolation, conn.validateFrameAllowedInPacketSpace(0x06, .application));
    try std.testing.expectError(types_mod.QuicError.ProtocolViolation, conn.validateFrameAllowedInPacketSpace(0x1f, .application));
}

test "connecting-state frame legality matrix baseline" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    conn.state = .connecting;

    const connecting_allowed = [_]u64{ 0x00, 0x01, 0x02, 0x03, 0x06, 0x1c, 0x1d };
    for (connecting_allowed) |ft| {
        try conn.validateFrameAllowedInState(ft);
    }

    const connecting_disallowed = [_]u64{ 0x04, 0x05, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x08, 0x0f };
    for (connecting_disallowed) |ft| {
        try std.testing.expectError(types_mod.QuicError.ProtocolViolation, conn.validateFrameAllowedInState(ft));
    }
}

test "connecting-state legality composes with packet-space rules" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    conn.state = .connecting;

    // STREAM is legal in application space, but connecting-state policy rejects it.
    try conn.validateFrameAllowedInPacketSpace(0x08, .application);
    try std.testing.expectError(types_mod.QuicError.ProtocolViolation, conn.validateFrameAllowedInState(0x08));

    // MAX_DATA is legal in application space, but connecting-state policy rejects it.
    try conn.validateFrameAllowedInPacketSpace(0x10, .application);
    try std.testing.expectError(types_mod.QuicError.ProtocolViolation, conn.validateFrameAllowedInState(0x10));

    // PING and CONNECTION_CLOSE remain legal while connecting.
    try conn.validateFrameAllowedInPacketSpace(0x01, .application);
    try conn.validateFrameAllowedInState(0x01);
    try conn.validateFrameAllowedInPacketSpace(0x1d, .application);
    try conn.validateFrameAllowedInState(0x1d);
}
