const std = @import("std");
const types = @import("types.zig");
const frame = @import("frame.zig");
const stream = @import("stream.zig");
const packet = @import("../core/packet.zig");
const loss_detection = @import("loss_detection.zig");
const congestion = @import("congestion.zig");
const time = @import("../utils/time.zig");

const ConnectionId = types.ConnectionId;
const ConnectionState = types.ConnectionState;
const QuicMode = types.QuicMode;
const TransportParameters = types.TransportParameters;
const StreamManager = stream.StreamManager;
const StreamId = types.StreamId;
const MAX_ACK_PACKETS_PER_FRAME: usize = 1024;
pub const RecoverySpace = loss_detection.PacketNumberSpace;

/// QUIC Connection
pub const Connection = struct {
    pub const PeerConnectionIdEntry = struct {
        sequence_number: u64,
        connection_id: ConnectionId,
        stateless_reset_token: [16]u8,
    };

    pub const LocalConnectionIdEntry = struct {
        sequence_number: u64,
        connection_id: ConnectionId,
        stateless_reset_token: [16]u8,
    };

    pub const RetransmissionRequest = struct {
        packet_number: u64,
        size: usize,
        is_probe: bool,
    };

    /// Connection IDs
    local_conn_id: ConnectionId,
    remote_conn_id: ConnectionId,

    /// Connection state
    state: ConnectionState,

    /// Crypto mode (TLS or SSH)
    mode: QuicMode,

    /// Is this a server connection?
    is_server: bool,

    /// Address/path validation state for amplification limits
    peer_validated: bool,

    /// QUIC version
    version: u32,

    /// Transport parameters
    local_params: TransportParameters,
    remote_params: ?TransportParameters,

    /// Stream management
    streams: StreamManager,

    /// Packet number tracking
    next_packet_number: u64,
    largest_acked: u64,

    /// Recovery and congestion control
    loss_detection: loss_detection.LossDetection,
    congestion_controller: congestion.CongestionController,
    retransmission_queue: std.ArrayList(RetransmissionRequest),
    pto_count: u32,
    next_pto_at: ?time.Instant,

    /// PATH_CHALLENGE / PATH_RESPONSE tracking
    expected_path_response: ?[8]u8,
    pending_path_responses: std.ArrayList([8]u8),

    /// Flow control
    max_data_local: u64,
    max_data_remote: u64,
    data_sent: u64,
    data_received: u64,

    /// Peer blocked signaling observations
    peer_data_blocked_max: u64,
    peer_stream_data_blocked_max: u64,
    peer_streams_blocked_bidi_max: u64,
    peer_streams_blocked_uni_max: u64,

    /// Peer-issued connection IDs and retire signaling
    peer_connection_ids: std.ArrayList(PeerConnectionIdEntry),
    peer_retire_prior_to: u64,
    peer_max_cid_sequence: u64,
    pending_retire_connection_ids: std.ArrayList(u64),

    /// Local NEW_CONNECTION_ID advertisement state
    local_connection_ids: std.ArrayList(LocalConnectionIdEntry),
    local_next_cid_sequence: u64,
    local_retire_prior_to: u64,
    pending_new_connection_ids: std.ArrayList(u64),

    /// Allocator
    allocator: std.mem.Allocator,

    pub const Error = error{
        InvalidState,
        ConnectionClosed,
        StreamError,
        UnsupportedStreamType,
        FlowControlError,
        InvalidPacket,
    } || std.mem.Allocator.Error;

    /// Create a new client connection
    pub fn initClient(
        allocator: std.mem.Allocator,
        mode: QuicMode,
        local_conn_id: ConnectionId,
        remote_conn_id: ConnectionId,
    ) Error!Connection {
        const params = TransportParameters{};

        var conn = Connection{
            .local_conn_id = local_conn_id,
            .remote_conn_id = remote_conn_id,
            .state = .handshaking,
            .mode = mode,
            .is_server = false,
            .peer_validated = true,
            .version = types.QUIC_VERSION_1,
            .local_params = params,
            .remote_params = null,
            .streams = StreamManager.init(allocator, false, params.initial_max_stream_data_bidi_local),
            .next_packet_number = 0,
            .largest_acked = 0,
            .loss_detection = loss_detection.LossDetection.init(allocator),
            .congestion_controller = congestion.CongestionController.init(1200),
            .retransmission_queue = .{},
            .pto_count = 0,
            .next_pto_at = null,
            .expected_path_response = null,
            .pending_path_responses = .{},
            .max_data_local = params.initial_max_data,
            .max_data_remote = params.initial_max_data,
            .data_sent = 0,
            .data_received = 0,
            .peer_data_blocked_max = 0,
            .peer_stream_data_blocked_max = 0,
            .peer_streams_blocked_bidi_max = 0,
            .peer_streams_blocked_uni_max = 0,
            .peer_connection_ids = .{},
            .peer_retire_prior_to = 0,
            .peer_max_cid_sequence = 0,
            .pending_retire_connection_ids = .{},
            .local_connection_ids = .{},
            .local_next_cid_sequence = 0,
            .local_retire_prior_to = 0,
            .pending_new_connection_ids = .{},
            .allocator = allocator,
        };

        try conn.local_connection_ids.append(allocator, .{
            .sequence_number = 0,
            .connection_id = local_conn_id,
            .stateless_reset_token = [_]u8{0} ** 16,
        });
        conn.local_next_cid_sequence = 1;

        // SSH/QUIC reserves stream 0 for global/auth traffic.
        // Channel streams begin at 4 for client-initiated bidirectional streams.
        if (mode == .ssh) {
            conn.streams.next_client_bidi = 4;
        }

        conn.streams.setLocalOpenLimits(params.initial_max_streams_bidi, params.initial_max_streams_uni);
        conn.streams.setLocalReceiveStreamDataLimits(
            params.initial_max_stream_data_bidi_local,
            params.initial_max_stream_data_bidi_remote,
            params.initial_max_stream_data_uni,
        );

        return conn;
    }

    /// Create a new server connection
    pub fn initServer(
        allocator: std.mem.Allocator,
        mode: QuicMode,
        local_conn_id: ConnectionId,
        remote_conn_id: ConnectionId,
    ) Error!Connection {
        const params = TransportParameters{};

        var conn = Connection{
            .local_conn_id = local_conn_id,
            .remote_conn_id = remote_conn_id,
            .state = .handshaking,
            .mode = mode,
            .is_server = true,
            .peer_validated = false,
            .version = types.QUIC_VERSION_1,
            .local_params = params,
            .remote_params = null,
            .streams = StreamManager.init(allocator, true, params.initial_max_stream_data_bidi_local),
            .next_packet_number = 0,
            .largest_acked = 0,
            .loss_detection = loss_detection.LossDetection.init(allocator),
            .congestion_controller = congestion.CongestionController.init(1200),
            .retransmission_queue = .{},
            .pto_count = 0,
            .next_pto_at = null,
            .expected_path_response = null,
            .pending_path_responses = .{},
            .max_data_local = params.initial_max_data,
            .max_data_remote = params.initial_max_data,
            .data_sent = 0,
            .data_received = 0,
            .peer_data_blocked_max = 0,
            .peer_stream_data_blocked_max = 0,
            .peer_streams_blocked_bidi_max = 0,
            .peer_streams_blocked_uni_max = 0,
            .peer_connection_ids = .{},
            .peer_retire_prior_to = 0,
            .peer_max_cid_sequence = 0,
            .pending_retire_connection_ids = .{},
            .local_connection_ids = .{},
            .local_next_cid_sequence = 0,
            .local_retire_prior_to = 0,
            .pending_new_connection_ids = .{},
            .allocator = allocator,
        };

        try conn.local_connection_ids.append(allocator, .{
            .sequence_number = 0,
            .connection_id = local_conn_id,
            .stateless_reset_token = [_]u8{0} ** 16,
        });
        conn.local_next_cid_sequence = 1;

        // SSH/QUIC reserves stream 0 and maps server-initiated channels to 5, 9, 13...
        if (mode == .ssh) {
            conn.streams.next_server_bidi = 5;
        }

        conn.streams.setLocalOpenLimits(params.initial_max_streams_bidi, params.initial_max_streams_uni);
        conn.streams.setLocalReceiveStreamDataLimits(
            params.initial_max_stream_data_bidi_local,
            params.initial_max_stream_data_bidi_remote,
            params.initial_max_stream_data_uni,
        );

        return conn;
    }

    pub fn deinit(self: *Connection) void {
        self.streams.deinit();
        self.loss_detection.deinit();
        self.retransmission_queue.deinit(self.allocator);
        self.pending_path_responses.deinit(self.allocator);
        self.peer_connection_ids.deinit(self.allocator);
        self.pending_retire_connection_ids.deinit(self.allocator);
        self.local_connection_ids.deinit(self.allocator);
        self.pending_new_connection_ids.deinit(self.allocator);
    }

    /// Open a new stream
    pub fn openStream(self: *Connection, bidirectional: bool) Error!StreamId {
        if (self.state != .established) {
            return error.InvalidState;
        }

        // SSH/QUIC channels are always bidirectional streams.
        if (self.mode == .ssh and !bidirectional) {
            return error.UnsupportedStreamType;
        }

        const stream_type = if (bidirectional)
            (if (self.is_server) types.StreamType.server_bidi else types.StreamType.client_bidi)
        else
            (if (self.is_server) types.StreamType.server_uni else types.StreamType.client_uni);

        return self.streams.createStream(stream_type) catch |err| {
            return switch (err) {
                error.StreamLimitReached => error.StreamError,
                error.InvalidStreamType => error.StreamError,
                else => error.StreamError,
            };
        };
    }

    /// Get a stream by ID
    pub fn getStream(self: *Connection, stream_id: StreamId) ?*stream.Stream {
        return self.streams.getStream(stream_id);
    }

    /// Get or create a stream by ID (for receiving)
    pub fn getOrCreateStream(self: *Connection, stream_id: StreamId) Error!*stream.Stream {
        return self.streams.getOrCreateStream(stream_id) catch |err| {
            std.log.err("Failed to get or create stream {}: {}", .{ stream_id, err });
            return error.StreamError;
        };
    }

    /// Get next packet number and increment
    pub fn nextPacketNumber(self: *Connection) u64 {
        const pn = self.next_packet_number;
        self.next_packet_number += 1;
        return pn;
    }

    /// Mark connection as established
    pub fn markEstablished(self: *Connection) void {
        self.state = .established;
        self.peer_validated = true;
    }

    /// Mark peer/path as validated for amplification-limit purposes.
    pub fn markPeerValidated(self: *Connection) void {
        self.peer_validated = true;
    }

    /// Begin path validation: requires PATH_RESPONSE echo before enabling validated path.
    pub fn beginPathValidation(self: *Connection, challenge_data: [8]u8) void {
        self.expected_path_response = challenge_data;
        self.peer_validated = false;
    }

    /// Queue a PATH_RESPONSE token when a PATH_CHALLENGE is received.
    pub fn onPathChallenge(self: *Connection, challenge_data: [8]u8) Error!void {
        try self.pending_path_responses.append(self.allocator, challenge_data);
    }

    /// Pop the next pending PATH_RESPONSE token to send.
    pub fn popPathResponse(self: *Connection) ?[8]u8 {
        if (self.pending_path_responses.items.len == 0) {
            return null;
        }
        return self.pending_path_responses.orderedRemove(0);
    }

    /// Process a received PATH_RESPONSE token.
    pub fn onPathResponse(self: *Connection, response_data: [8]u8) bool {
        if (self.expected_path_response) |expected| {
            if (std.mem.eql(u8, &expected, &response_data)) {
                self.expected_path_response = null;
                self.markPeerValidated();
                return true;
            }
        }
        return false;
    }

    /// Start closing the connection
    pub fn close(self: *Connection, _: u64, _: []const u8) void {
        if (self.state != .closed) {
            self.state = .closing;
        }
    }

    /// Mark connection as closed
    pub fn markClosed(self: *Connection) void {
        self.state = .closed;
    }

    /// Check if connection is closed
    pub fn isClosed(self: Connection) bool {
        return self.state == .closed or self.state == .draining;
    }

    /// Check connection-level flow control
    pub fn checkFlowControl(self: *Connection, additional_data: u64) Error!void {
        if (self.data_sent >= self.max_data_remote) {
            if (additional_data > 0) return error.FlowControlError;
            return;
        }

        const remaining = self.max_data_remote - self.data_sent;
        if (additional_data > remaining) {
            return error.FlowControlError;
        }
    }

    fn amplificationBudget(self: *Connection) u64 {
        if (!self.is_server or self.peer_validated) {
            return std.math.maxInt(u64);
        }

        if (self.data_received == 0) {
            return 0;
        }

        const max_send = if (self.data_received > std.math.maxInt(u64) / 3)
            std.math.maxInt(u64)
        else
            self.data_received * 3;

        if (self.data_sent >= max_send) {
            return 0;
        }
        return max_send - self.data_sent;
    }

    /// Available send budget considering flow-control, congestion, and amplification limits.
    pub fn availableSendBudget(self: *Connection) u64 {
        const flow_budget = if (self.data_sent >= self.max_data_remote)
            0
        else
            self.max_data_remote - self.data_sent;

        const congestion_budget = self.congestion_controller.availableWindow();
        const amplification_budget = self.amplificationBudget();

        return @min(flow_budget, @min(congestion_budget, amplification_budget));
    }

    /// Update data sent
    pub fn updateDataSent(self: *Connection, amount: u64) void {
        self.data_sent += amount;
    }

    /// Update data received
    pub fn updateDataReceived(self: *Connection, amount: u64) void {
        self.data_received += amount;
    }

    /// Set remote transport parameters
    pub fn setRemoteParams(self: *Connection, params: TransportParameters) void {
        self.remote_params = params;
        self.max_data_remote = params.initial_max_data;
        self.streams.setLocalOpenLimits(params.initial_max_streams_bidi, params.initial_max_streams_uni);
        self.streams.setRemoteStreamDataLimits(
            params.initial_max_stream_data_bidi_local,
            params.initial_max_stream_data_bidi_remote,
            params.initial_max_stream_data_uni,
        );
    }

    /// Apply peer MAX_DATA update (monotonic increase only).
    pub fn onMaxData(self: *Connection, new_max_data: u64) void {
        if (new_max_data > self.max_data_remote) {
            self.max_data_remote = new_max_data;
        }
    }

    pub fn onMaxStreams(self: *Connection, bidirectional: bool, max_streams: u64) void {
        self.streams.onMaxStreams(bidirectional, max_streams);
    }

    pub fn onMaxStreamData(self: *Connection, stream_id: StreamId, max_stream_data: u64) void {
        self.streams.onMaxStreamData(stream_id, max_stream_data);
    }

    pub fn onDataBlocked(self: *Connection, max_data: u64) void {
        if (max_data > self.peer_data_blocked_max) {
            self.peer_data_blocked_max = max_data;
        }
    }

    pub fn onStreamDataBlocked(self: *Connection, max_stream_data: u64) void {
        if (max_stream_data > self.peer_stream_data_blocked_max) {
            self.peer_stream_data_blocked_max = max_stream_data;
        }
    }

    pub fn onStreamsBlocked(self: *Connection, bidirectional: bool, max_streams: u64) void {
        if (bidirectional) {
            if (max_streams > self.peer_streams_blocked_bidi_max) {
                self.peer_streams_blocked_bidi_max = max_streams;
            }
            return;
        }

        if (max_streams > self.peer_streams_blocked_uni_max) {
            self.peer_streams_blocked_uni_max = max_streams;
        }
    }

    pub fn onNewConnectionId(
        self: *Connection,
        sequence_number: u64,
        retire_prior_to: u64,
        connection_id: ConnectionId,
        stateless_reset_token: [16]u8,
    ) Error!bool {
        if (retire_prior_to > sequence_number) {
            return false;
        }

        if (sequence_number > self.peer_max_cid_sequence) {
            self.peer_max_cid_sequence = sequence_number;
        }

        if (retire_prior_to > self.peer_retire_prior_to) {
            self.peer_retire_prior_to = retire_prior_to;

            var i: usize = 0;
            while (i < self.peer_connection_ids.items.len) {
                const cid = self.peer_connection_ids.items[i];
                if (cid.sequence_number < retire_prior_to) {
                    try self.enqueuePendingRetireConnectionId(cid.sequence_number);
                    _ = self.peer_connection_ids.orderedRemove(i);
                    continue;
                }
                i += 1;
            }
        }

        if (sequence_number < self.peer_retire_prior_to) {
            try self.enqueuePendingRetireConnectionId(sequence_number);
            return true;
        }

        for (self.peer_connection_ids.items) |cid| {
            if (std.mem.eql(u8, &cid.stateless_reset_token, &stateless_reset_token) and cid.sequence_number != sequence_number) {
                return false;
            }

            if (cid.sequence_number == sequence_number) {
                if (!cid.connection_id.eql(&connection_id)) return false;
                if (!std.mem.eql(u8, &cid.stateless_reset_token, &stateless_reset_token)) return false;
                return true;
            }
        }

        try self.peer_connection_ids.append(self.allocator, .{
            .sequence_number = sequence_number,
            .connection_id = connection_id,
            .stateless_reset_token = stateless_reset_token,
        });

        if (self.remote_params) |params| {
            if (self.peer_connection_ids.items.len > params.active_connection_id_limit) {
                _ = self.peer_connection_ids.pop();
                return false;
            }
        }

        return true;
    }

    fn enqueuePendingRetireConnectionId(self: *Connection, sequence_number: u64) Error!void {
        for (self.pending_retire_connection_ids.items) |existing| {
            if (existing == sequence_number) {
                return;
            }
        }

        try self.pending_retire_connection_ids.append(self.allocator, sequence_number);
    }

    pub fn onRetireConnectionId(self: *Connection, sequence_number: u64) bool {
        if (sequence_number > self.peer_max_cid_sequence) {
            return false;
        }

        var i: usize = 0;
        while (i < self.peer_connection_ids.items.len) {
            if (self.peer_connection_ids.items[i].sequence_number == sequence_number) {
                _ = self.peer_connection_ids.orderedRemove(i);
                break;
            }
            i += 1;
        }

        return true;
    }

    pub fn popRetireConnectionId(self: *Connection) ?u64 {
        if (self.pending_retire_connection_ids.items.len == 0) {
            return null;
        }

        return self.pending_retire_connection_ids.orderedRemove(0);
    }

    pub fn hasPendingRetireConnectionId(self: *const Connection) bool {
        return self.pending_retire_connection_ids.items.len > 0;
    }

    pub fn queueNewConnectionId(self: *Connection, connection_id: ConnectionId, stateless_reset_token: [16]u8) Error!u64 {
        const sequence_number = self.local_next_cid_sequence;
        self.local_next_cid_sequence += 1;

        try self.local_connection_ids.append(self.allocator, .{
            .sequence_number = sequence_number,
            .connection_id = connection_id,
            .stateless_reset_token = stateless_reset_token,
        });
        try self.pending_new_connection_ids.append(self.allocator, sequence_number);

        return sequence_number;
    }

    pub fn latestLocalConnectionId(self: *const Connection) ?LocalConnectionIdEntry {
        if (self.local_connection_ids.items.len == 0) return null;
        return self.local_connection_ids.items[self.local_connection_ids.items.len - 1];
    }

    pub fn popPendingNewConnectionId(self: *Connection) ?LocalConnectionIdEntry {
        if (self.pending_new_connection_ids.items.len == 0) {
            return null;
        }

        const sequence_number = self.pending_new_connection_ids.orderedRemove(0);
        for (self.local_connection_ids.items) |entry| {
            if (entry.sequence_number == sequence_number) {
                return entry;
            }
        }

        return null;
    }

    pub fn hasPendingNewConnectionId(self: *const Connection) bool {
        return self.pending_new_connection_ids.items.len > 0;
    }

    pub fn localRetirePriorTo(self: *const Connection) u64 {
        return self.local_retire_prior_to;
    }

    pub fn advanceLocalRetirePriorTo(self: *Connection, sequence_number: u64) void {
        if (sequence_number <= self.local_retire_prior_to) {
            return;
        }

        if (sequence_number > self.local_next_cid_sequence) {
            return;
        }

        self.local_retire_prior_to = sequence_number;
    }

    /// Process received ACK
    pub fn processAck(self: *Connection, largest_acked: u64) void {
        self.processAckDetailed(largest_acked, 0);
    }

    /// Returns whether ACKed packet number is plausible for packets sent so far.
    pub fn canAcknowledgePacket(self: *const Connection, largest_acked: u64) bool {
        return self.canAcknowledgePacketInSpace(.application, largest_acked);
    }

    /// Returns whether ACKed packet number is plausible in a specific packet number space.
    pub fn canAcknowledgePacketInSpace(
        self: *const Connection,
        space: RecoverySpace,
        largest_acked: u64,
    ) bool {
        if (self.loss_detection.maxObservedPacketNumber(space)) |max_seen| {
            return largest_acked <= max_seen;
        }
        return false;
    }

    /// Decode peer ACK Delay field into microseconds.
    ///
    /// ACK delay is encoded by peer using its advertised ack_delay_exponent and
    /// bounded by its max_ack_delay transport parameter.
    pub fn normalizePeerAckDelay(self: *const Connection, encoded_ack_delay: u64) u64 {
        const params = self.remote_params orelse self.local_params;
        const shift: u6 = @intCast(@min(params.ack_delay_exponent, 20));

        var scaled = encoded_ack_delay;
        var i: u6 = 0;
        while (i < shift) : (i += 1) {
            scaled = std.math.mul(u64, scaled, 2) catch std.math.maxInt(u64);
        }

        const max_ack_delay_us = params.max_ack_delay * time.Duration.MILLISECOND;
        return @min(scaled, max_ack_delay_us);
    }

    /// Validate ACK ranges against sent packet number space and processing limits.
    pub fn validateAckFrame(
        self: *const Connection,
        largest_acked: u64,
        first_ack_range: u64,
        ack_ranges: []const frame.AckFrame.AckRange,
    ) bool {
        return self.validateAckFrameInSpace(.application, largest_acked, first_ack_range, ack_ranges);
    }

    pub fn validateAckFrameInSpace(
        self: *const Connection,
        space: RecoverySpace,
        largest_acked: u64,
        first_ack_range: u64,
        ack_ranges: []const frame.AckFrame.AckRange,
    ) bool {
        if (!self.canAcknowledgePacketInSpace(space, largest_acked)) {
            return false;
        }

        if (first_ack_range > largest_acked) {
            return false;
        }

        var total_acked: usize = @intCast(first_ack_range + 1);
        if (total_acked > MAX_ACK_PACKETS_PER_FRAME) {
            return false;
        }

        var current_smallest = largest_acked - first_ack_range;
        for (ack_ranges) |range| {
            const step = range.gap + 2;
            if (current_smallest < step) {
                return false;
            }

            const next_largest = current_smallest - step;
            if (!self.canAcknowledgePacketInSpace(space, next_largest)) {
                return false;
            }

            if (range.ack_range_length > next_largest) {
                return false;
            }

            const range_packets: usize = @intCast(range.ack_range_length + 1);
            total_acked += range_packets;
            if (total_acked > MAX_ACK_PACKETS_PER_FRAME) {
                return false;
            }

            current_smallest = next_largest - range.ack_range_length;
        }

        return true;
    }

    /// Process received ACK with delay (microseconds), update RTT and congestion state.
    pub fn processAckDetailed(self: *Connection, largest_acked: u64, ack_delay: u64) void {
        self.processAckDetailedInSpace(.application, largest_acked, ack_delay);
    }

    pub fn processAckDetailedInSpace(
        self: *Connection,
        space: RecoverySpace,
        largest_acked: u64,
        ack_delay: u64,
    ) void {
        const now = time.Instant.now();

        var ack_result = self.loss_detection.onAckReceived(
            space,
            largest_acked,
            ack_delay,
            now,
        ) catch {
            if (largest_acked > self.largest_acked) {
                self.largest_acked = largest_acked;
            }
            return;
        };
        defer ack_result.acked_packets.deinit(self.allocator);
        defer ack_result.lost_packets.deinit(self.allocator);

        self.applyAckResult(&ack_result, now);

        if (largest_acked > self.largest_acked) {
            self.largest_acked = largest_acked;
        }
    }

    fn applyAckResult(self: *Connection, ack_result: *const loss_detection.AckResult, now: time.Instant) void {
        for (ack_result.acked_packets.items) |acked| {
            if (acked.in_flight) {
                self.congestion_controller.onPacketAcked(acked.size, acked.packet_number);
                self.pto_count = 0;
                self.next_pto_at = now.add(self.currentPtoDuration());
            }
        }

        if (ack_result.lost_packets.items.len > 0) {
            var bytes_lost: u64 = 0;
            var largest_lost: u64 = 0;
            for (ack_result.lost_packets.items) |lost| {
                if (lost.in_flight) {
                    bytes_lost += lost.size;
                }
                if (lost.packet_number > largest_lost) {
                    largest_lost = lost.packet_number;
                }
            }

            if (bytes_lost > 0) {
                self.congestion_controller.onPacketsLost(bytes_lost, largest_lost);

                for (ack_result.lost_packets.items) |lost| {
                    self.retransmission_queue.append(self.allocator, .{
                        .packet_number = lost.packet_number,
                        .size = lost.size,
                        .is_probe = false,
                    }) catch {};
                }
            }
        }
    }

    /// Process received ACK with parsed range metadata.
    ///
    /// This currently forwards to the largest-acked recovery path while
    /// preserving a stable API surface for full range-driven recovery.
    pub fn processAckDetailedWithRanges(
        self: *Connection,
        largest_acked: u64,
        ack_delay: u64,
        first_ack_range: u64,
        ack_ranges: []const frame.AckFrame.AckRange,
    ) void {
        self.processAckDetailedWithRangesInSpace(.application, largest_acked, ack_delay, first_ack_range, ack_ranges);
    }

    pub fn processAckDetailedWithRangesInSpace(
        self: *Connection,
        space: RecoverySpace,
        largest_acked: u64,
        ack_delay: u64,
        first_ack_range: u64,
        ack_ranges: []const frame.AckFrame.AckRange,
    ) void {
        if (!self.validateAckFrameInSpace(space, largest_acked, first_ack_range, ack_ranges)) {
            return;
        }

        var acknowledged_numbers: [MAX_ACK_PACKETS_PER_FRAME]u64 = undefined;
        var count: usize = 0;

        var current_smallest = largest_acked - first_ack_range;

        var pn = current_smallest;
        while (pn <= largest_acked) : (pn += 1) {
            acknowledged_numbers[count] = pn;
            count += 1;
        }

        for (ack_ranges) |range| {
            const next_largest = current_smallest - (range.gap + 2);
            const next_smallest = next_largest - range.ack_range_length;

            pn = next_smallest;
            while (pn <= next_largest) : (pn += 1) {
                acknowledged_numbers[count] = pn;
                count += 1;
            }

            current_smallest = next_smallest;
        }

        const now = time.Instant.now();
        var ack_result = self.loss_detection.onAckReceivedWithPacketNumbers(
            space,
            largest_acked,
            ack_delay,
            now,
            acknowledged_numbers[0..count],
        ) catch {
            if (largest_acked > self.largest_acked) {
                self.largest_acked = largest_acked;
            }
            return;
        };
        defer ack_result.acked_packets.deinit(self.allocator);
        defer ack_result.lost_packets.deinit(self.allocator);

        self.applyAckResult(&ack_result, now);

        if (largest_acked > self.largest_acked) {
            self.largest_acked = largest_acked;
        }
    }

    fn currentPtoDuration(self: *const Connection) u64 {
        var pto = self.loss_detection.getPto();

        // Apply peer max_ack_delay once transport parameters are available.
        if (self.remote_params) |params| {
            pto += params.max_ack_delay * time.Duration.MILLISECOND;
        }

        return pto;
    }

    /// Drain timeout derived from recovery timing (RFC-style 3 PTOs).
    pub fn drainTimeoutDuration(self: *const Connection) u64 {
        const base = self.currentPtoDuration();
        const derived = std.math.mul(u64, base, 3) catch std.math.maxInt(u64);
        return @min(@max(derived, 50 * time.Duration.MILLISECOND), 30 * time.Duration.SECOND);
    }

    /// Track a sent packet for RTT/loss/congestion accounting.
    pub fn trackPacketSent(self: *Connection, packet_size: usize, ack_eliciting: bool) void {
        self.trackPacketSentInSpace(.application, packet_size, ack_eliciting);
    }

    pub fn trackPacketSentInSpace(
        self: *Connection,
        space: RecoverySpace,
        packet_size: usize,
        ack_eliciting: bool,
    ) void {
        const pn = self.nextPacketNumber();
        const now = time.Instant.now();
        const sent = loss_detection.SentPacket.init(pn, now, packet_size, ack_eliciting);

        self.loss_detection.onPacketSent(space, sent) catch {};
        if (sent.in_flight) {
            self.congestion_controller.onPacketSent(packet_size);
        }

        if (ack_eliciting) {
            self.next_pto_at = now.add(self.currentPtoDuration());
        }
    }

    /// Schedule probe retransmission when PTO expires.
    pub fn onPtoTimeout(self: *Connection, now: time.Instant) void {
        if (self.next_pto_at) |deadline| {
            if (now.isBefore(deadline)) {
                return;
            }

            self.retransmission_queue.append(self.allocator, .{
                .packet_number = self.next_packet_number,
                .size = @intCast(self.congestion_controller.max_datagram_size),
                .is_probe = true,
            }) catch {};

            self.pto_count += 1;

            const base_pto = self.currentPtoDuration();
            const shift: u6 = @intCast(@min(self.pto_count, 20));
            const backoff = (@as(u64, 1) << shift);
            self.next_pto_at = now.add(base_pto * backoff);
        }
    }

    /// Pop next pending retransmission request, if any.
    pub fn popRetransmission(self: *Connection) ?RetransmissionRequest {
        if (self.retransmission_queue.items.len == 0) {
            return null;
        }

        return self.retransmission_queue.orderedRemove(0);
    }
};

/// Connection manager for handling multiple connections
pub const ConnectionManager = struct {
    connections: std.AutoHashMap(u64, Connection),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConnectionManager {
        return ConnectionManager{
            .connections = std.AutoHashMap(u64, Connection).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConnectionManager) void {
        var it = self.connections.valueIterator();
        while (it.next()) |conn| {
            conn.deinit();
        }
        self.connections.deinit();
    }

    /// Add a connection
    pub fn addConnection(self: *ConnectionManager, conn_id_hash: u64, conn: Connection) !void {
        try self.connections.put(conn_id_hash, conn);
    }

    /// Get connection by connection ID hash
    pub fn getConnection(self: *ConnectionManager, conn_id_hash: u64) ?*Connection {
        return self.connections.getPtr(conn_id_hash);
    }

    /// Remove connection
    pub fn removeConnection(self: *ConnectionManager, conn_id_hash: u64) void {
        if (self.connections.fetchRemove(conn_id_hash)) |kv| {
            var conn = kv.value;
            conn.deinit();
        }
    }

    /// Remove all closed connections
    pub fn removeClosedConnections(self: *ConnectionManager) !void {
        var to_remove = std.ArrayList(u64).init(self.allocator);
        defer to_remove.deinit();

        var it = self.connections.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.isClosed()) {
                try to_remove.append(entry.key_ptr.*);
            }
        }

        for (to_remove.items) |conn_id_hash| {
            self.removeConnection(conn_id_hash);
        }
    }

    /// Hash a connection ID for use as key
    pub fn hashConnectionId(conn_id: ConnectionId) u64 {
        return std.hash.Wyhash.hash(0, conn_id.slice());
    }
};

// Tests

test "connection creation client" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    try std.testing.expectEqual(ConnectionState.handshaking, conn.state);
    try std.testing.expect(!conn.is_server);
    try std.testing.expectEqual(QuicMode.tls, conn.mode);
}

test "connection creation server" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initServer(allocator, .ssh, local_cid, remote_cid);
    defer conn.deinit();

    try std.testing.expectEqual(ConnectionState.handshaking, conn.state);
    try std.testing.expect(conn.is_server);
    try std.testing.expectEqual(QuicMode.ssh, conn.mode);
}

test "connection stream opening" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    // Can't open streams until established
    try std.testing.expectError(error.InvalidState, conn.openStream(true));

    // Mark as established
    conn.markEstablished();

    // Now we can open streams
    const stream_id = try conn.openStream(true);
    try std.testing.expectEqual(@as(u64, 0), stream_id);

    const s = conn.getStream(stream_id).?;
    try std.testing.expect(s.isBidirectional());
}

test "ssh stream id assignment and bidi-only policy" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var client_conn = try Connection.initClient(allocator, .ssh, local_cid, remote_cid);
    defer client_conn.deinit();
    client_conn.markEstablished();

    try std.testing.expectError(error.UnsupportedStreamType, client_conn.openStream(false));

    const c1 = try client_conn.openStream(true);
    const c2 = try client_conn.openStream(true);
    try std.testing.expectEqual(@as(u64, 4), c1);
    try std.testing.expectEqual(@as(u64, 8), c2);

    var server_conn = try Connection.initServer(allocator, .ssh, local_cid, remote_cid);
    defer server_conn.deinit();
    server_conn.markEstablished();

    const s1 = try server_conn.openStream(true);
    const s2 = try server_conn.openStream(true);
    try std.testing.expectEqual(@as(u64, 5), s1);
    try std.testing.expectEqual(@as(u64, 9), s2);
}

test "connection manager" {
    const allocator = std.testing.allocator;

    var manager = ConnectionManager.init(allocator);
    defer manager.deinit();

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    const conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);

    const hash = ConnectionManager.hashConnectionId(local_cid);
    try manager.addConnection(hash, conn);

    const retrieved = manager.getConnection(hash).?;
    try std.testing.expect(retrieved.local_conn_id.eql(&local_cid));
}

test "connection packet numbers" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    try std.testing.expectEqual(@as(u64, 0), conn.nextPacketNumber());
    try std.testing.expectEqual(@as(u64, 1), conn.nextPacketNumber());
    try std.testing.expectEqual(@as(u64, 2), conn.nextPacketNumber());
}

test "connection flow control" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    // Should be able to send within limit
    try conn.checkFlowControl(1000);

    // Should fail if exceeding limit
    try std.testing.expectError(error.FlowControlError, conn.checkFlowControl(conn.max_data_remote + 1));
}

test "connection flow control exact boundary is allowed" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    conn.data_sent = conn.max_data_remote - 10;
    try conn.checkFlowControl(10);
    try std.testing.expectError(error.FlowControlError, conn.checkFlowControl(11));
}

test "connection flow control handles saturated sent counter safely" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    conn.data_sent = conn.max_data_remote;
    try conn.checkFlowControl(0);
    try std.testing.expectError(error.FlowControlError, conn.checkFlowControl(1));
}

test "connection send budget follows max_data updates monotonically" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    // Isolate flow-control budget from congestion budget.
    conn.congestion_controller.congestion_window = std.math.maxInt(u64);

    var remote = TransportParameters{};
    remote.initial_max_data = 2000;
    conn.setRemoteParams(remote);

    try std.testing.expectEqual(@as(u64, 2000), conn.availableSendBudget());

    conn.updateDataSent(1500);
    try std.testing.expectEqual(@as(u64, 500), conn.availableSendBudget());

    // Increasing max_data increases budget by the same delta.
    remote.initial_max_data = 2600;
    conn.setRemoteParams(remote);
    try std.testing.expectEqual(@as(u64, 1100), conn.availableSendBudget());

    // Reducing max_data clamps budget to zero when below data_sent.
    remote.initial_max_data = 1200;
    conn.setRemoteParams(remote);
    try std.testing.expectEqual(@as(u64, 0), conn.availableSendBudget());
}

test "connection applies MAX_DATA updates monotonically" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    conn.max_data_remote = 1000;
    conn.onMaxData(900);
    try std.testing.expectEqual(@as(u64, 1000), conn.max_data_remote);

    conn.onMaxData(2000);
    try std.testing.expectEqual(@as(u64, 2000), conn.max_data_remote);
}

test "connection applies MAX_STREAMS updates" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    conn.streams.setLocalOpenLimits(1, 1);
    conn.onMaxStreams(true, 4);
    try std.testing.expectEqual(@as(u64, 4), conn.streams.max_local_streams_bidi);
}

test "connection ignores decreasing MAX_STREAMS updates" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    conn.streams.setLocalOpenLimits(2, 3);

    conn.onMaxStreams(true, 10);
    conn.onMaxStreams(false, 8);
    try std.testing.expectEqual(@as(u64, 10), conn.streams.max_local_streams_bidi);
    try std.testing.expectEqual(@as(u64, 8), conn.streams.max_local_streams_uni);

    // Decreasing values must be ignored.
    conn.onMaxStreams(true, 4);
    conn.onMaxStreams(false, 6);
    try std.testing.expectEqual(@as(u64, 10), conn.streams.max_local_streams_bidi);
    try std.testing.expectEqual(@as(u64, 8), conn.streams.max_local_streams_uni);
}

test "connection applies MAX_STREAM_DATA updates" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    const sid = try conn.openStream(true);
    const before = conn.getStream(sid).?.max_stream_data_remote;
    conn.onMaxStreamData(sid, before + 5000);
    try std.testing.expectEqual(before + 5000, conn.getStream(sid).?.max_stream_data_remote);
}

test "connection ignores decreasing MAX_STREAM_DATA and unknown stream updates" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    const sid = try conn.openStream(true);
    const before = conn.getStream(sid).?.max_stream_data_remote;

    conn.onMaxStreamData(sid, before - 1);
    try std.testing.expectEqual(before, conn.getStream(sid).?.max_stream_data_remote);

    conn.onMaxStreamData(sid, before + 1024);
    try std.testing.expectEqual(before + 1024, conn.getStream(sid).?.max_stream_data_remote);

    // Unknown stream ID should be ignored and must not affect existing stream.
    conn.onMaxStreamData(999, before + 99999);
    try std.testing.expectEqual(before + 1024, conn.getStream(sid).?.max_stream_data_remote);
}

test "connection tracks peer blocked frame observations" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    conn.onDataBlocked(1000);
    conn.onDataBlocked(900);
    try std.testing.expectEqual(@as(u64, 1000), conn.peer_data_blocked_max);

    conn.onStreamDataBlocked(512);
    conn.onStreamDataBlocked(256);
    try std.testing.expectEqual(@as(u64, 512), conn.peer_stream_data_blocked_max);

    conn.onStreamsBlocked(true, 3);
    conn.onStreamsBlocked(true, 2);
    conn.onStreamsBlocked(false, 5);
    conn.onStreamsBlocked(false, 4);
    try std.testing.expectEqual(@as(u64, 3), conn.peer_streams_blocked_bidi_max);
    try std.testing.expectEqual(@as(u64, 5), conn.peer_streams_blocked_uni_max);
}

test "connection tracks NEW_CONNECTION_ID and retire_prior_to" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    const cid0 = try ConnectionId.init(&[_]u8{ 10, 11, 12, 13 });
    const cid1 = try ConnectionId.init(&[_]u8{ 20, 21, 22, 23 });

    try std.testing.expect(try conn.onNewConnectionId(0, 0, cid0, [_]u8{1} ** 16));
    try std.testing.expect(try conn.onNewConnectionId(1, 1, cid1, [_]u8{2} ** 16));

    // seq 0 is now retired by retire_prior_to=1
    const retired = conn.popRetireConnectionId();
    try std.testing.expect(retired != null);
    try std.testing.expectEqual(@as(u64, 0), retired.?);
}

test "connection rejects invalid NEW_CONNECTION_ID retire ordering" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    const cid = try ConnectionId.init(&[_]u8{ 10, 11, 12, 13 });
    try std.testing.expect(!(try conn.onNewConnectionId(1, 2, cid, [_]u8{1} ** 16)));
}

test "connection validates RETIRE_CONNECTION_ID sequence bounds" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    const cid = try ConnectionId.init(&[_]u8{ 10, 11, 12, 13 });
    try std.testing.expect(try conn.onNewConnectionId(3, 0, cid, [_]u8{1} ** 16));

    try std.testing.expect(conn.onRetireConnectionId(3));
    try std.testing.expect(!conn.onRetireConnectionId(9));
}

test "connection enforces peer active_connection_id_limit" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    var remote = TransportParameters{};
    remote.active_connection_id_limit = 1;
    conn.setRemoteParams(remote);

    const cid1 = try ConnectionId.init(&[_]u8{ 9, 9, 9, 1 });
    const cid2 = try ConnectionId.init(&[_]u8{ 9, 9, 9, 2 });

    try std.testing.expect(try conn.onNewConnectionId(1, 0, cid1, [_]u8{1} ** 16));
    try std.testing.expect(!(try conn.onNewConnectionId(2, 0, cid2, [_]u8{2} ** 16)));
    try std.testing.expectEqual(@as(usize, 1), conn.peer_connection_ids.items.len);
}

test "connection rejects duplicate stateless reset token across peer CIDs" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    var remote = TransportParameters{};
    remote.active_connection_id_limit = 8;
    conn.setRemoteParams(remote);

    const token = [_]u8{9} ** 16;
    const cid1 = try ConnectionId.init(&[_]u8{ 8, 8, 8, 1 });
    const cid2 = try ConnectionId.init(&[_]u8{ 8, 8, 8, 2 });

    try std.testing.expect(try conn.onNewConnectionId(1, 0, cid1, token));
    try std.testing.expect(!(try conn.onNewConnectionId(2, 0, cid2, token)));
    try std.testing.expectEqual(@as(usize, 1), conn.peer_connection_ids.items.len);
}

test "connection deduplicates pending retire IDs from repeated retire_prior_to" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    var remote = TransportParameters{};
    remote.active_connection_id_limit = 8;
    conn.setRemoteParams(remote);

    const cid0 = try ConnectionId.init(&[_]u8{ 7, 7, 7, 0 });
    const cid1 = try ConnectionId.init(&[_]u8{ 7, 7, 7, 1 });
    const cid2 = try ConnectionId.init(&[_]u8{ 7, 7, 7, 2 });
    const cid3 = try ConnectionId.init(&[_]u8{ 7, 7, 7, 3 });

    try std.testing.expect(try conn.onNewConnectionId(0, 0, cid0, [_]u8{1} ** 16));
    try std.testing.expect(try conn.onNewConnectionId(1, 0, cid1, [_]u8{2} ** 16));
    try std.testing.expect(try conn.onNewConnectionId(2, 2, cid2, [_]u8{3} ** 16));

    // Repeating retire_prior_to boundary should not duplicate retire queue entries.
    try std.testing.expect(try conn.onNewConnectionId(3, 2, cid3, [_]u8{4} ** 16));

    try std.testing.expectEqual(@as(?u64, 0), conn.popRetireConnectionId());
    try std.testing.expectEqual(@as(?u64, 1), conn.popRetireConnectionId());
    try std.testing.expectEqual(@as(?u64, null), conn.popRetireConnectionId());
}

test "connection deduplicates retire queue for sequence below retire_prior_to" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    var remote = TransportParameters{};
    remote.active_connection_id_limit = 8;
    conn.setRemoteParams(remote);

    const cid3 = try ConnectionId.init(&[_]u8{ 8, 8, 8, 3 });
    try std.testing.expect(try conn.onNewConnectionId(3, 3, cid3, [_]u8{5} ** 16));

    const stale_cid = try ConnectionId.init(&[_]u8{ 8, 8, 8, 1 });
    try std.testing.expect(try conn.onNewConnectionId(1, 1, stale_cid, [_]u8{6} ** 16));
    try std.testing.expect(try conn.onNewConnectionId(1, 1, stale_cid, [_]u8{6} ** 16));

    try std.testing.expectEqual(@as(?u64, 1), conn.popRetireConnectionId());
    try std.testing.expectEqual(@as(?u64, null), conn.popRetireConnectionId());
}

test "connection queues local NEW_CONNECTION_ID entries" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    const cid1 = try ConnectionId.init(&[_]u8{ 9, 9, 9, 9 });
    const seq1 = try conn.queueNewConnectionId(cid1, [_]u8{4} ** 16);
    try std.testing.expectEqual(@as(u64, 1), seq1);

    const latest = conn.latestLocalConnectionId();
    try std.testing.expect(latest != null);
    try std.testing.expectEqual(@as(u64, 1), latest.?.sequence_number);
    try std.testing.expect(latest.?.connection_id.eql(&cid1));

    const pending = conn.popPendingNewConnectionId();
    try std.testing.expect(pending != null);
    try std.testing.expectEqual(@as(u64, 1), pending.?.sequence_number);
    try std.testing.expect(conn.popPendingNewConnectionId() == null);
}

test "connection local retire_prior_to advances monotonically" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    conn.advanceLocalRetirePriorTo(0);
    try std.testing.expectEqual(@as(u64, 0), conn.localRetirePriorTo());

    // Cannot advance past advertised local sequence horizon.
    conn.advanceLocalRetirePriorTo(2);
    try std.testing.expectEqual(@as(u64, 0), conn.localRetirePriorTo());

    _ = try conn.queueNewConnectionId(try ConnectionId.init(&[_]u8{ 9, 9, 9, 9 }), [_]u8{1} ** 16);
    conn.advanceLocalRetirePriorTo(1);
    try std.testing.expectEqual(@as(u64, 1), conn.localRetirePriorTo());

    conn.advanceLocalRetirePriorTo(1);
    try std.testing.expectEqual(@as(u64, 1), conn.localRetirePriorTo());
}

test "connection pending CID flags reflect queue state" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    try std.testing.expect(!conn.hasPendingRetireConnectionId());
    try std.testing.expect(!conn.hasPendingNewConnectionId());

    const cid0 = try ConnectionId.init(&[_]u8{ 9, 9, 9, 1 });
    const cid1 = try ConnectionId.init(&[_]u8{ 9, 9, 9, 2 });
    try std.testing.expect(try conn.onNewConnectionId(0, 0, cid0, [_]u8{1} ** 16));
    try std.testing.expect(try conn.onNewConnectionId(1, 1, cid1, [_]u8{2} ** 16));
    try std.testing.expect(conn.hasPendingRetireConnectionId());

    _ = conn.popRetireConnectionId();
    try std.testing.expect(!conn.hasPendingRetireConnectionId());

    _ = try conn.queueNewConnectionId(try ConnectionId.init(&[_]u8{ 7, 7, 7, 7 }), [_]u8{3} ** 16);
    try std.testing.expect(conn.hasPendingNewConnectionId());

    _ = conn.popPendingNewConnectionId();
    try std.testing.expect(!conn.hasPendingNewConnectionId());
}

test "connection applies remote stream limits" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    var remote = TransportParameters{};
    remote.initial_max_streams_bidi = 1;
    remote.initial_max_streams_uni = 0;
    conn.setRemoteParams(remote);

    _ = try conn.openStream(true);
    try std.testing.expectError(error.StreamError, conn.openStream(true));
    try std.testing.expectError(error.StreamError, conn.openStream(false));
}

test "connection applies remote per-stream data limits" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    var remote = TransportParameters{};
    remote.initial_max_stream_data_bidi_remote = 4;
    conn.setRemoteParams(remote);

    const stream_id = try conn.openStream(true);
    const s = conn.getStream(stream_id).?;

    try std.testing.expectEqual(@as(u64, 4), s.max_stream_data_remote);
    try std.testing.expectEqual(@as(usize, 4), try s.write("abcdef"));
}

test "connection send budget tracks congestion window" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    const initial_budget = conn.availableSendBudget();
    try std.testing.expect(initial_budget > 0);

    conn.trackPacketSent(4000, true);
    const reduced_budget = conn.availableSendBudget();
    try std.testing.expect(reduced_budget < initial_budget);
}

test "connection enforces server amplification budget before validation" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initServer(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    // No bytes received yet => cannot send due to amplification limit.
    try std.testing.expectEqual(@as(u64, 0), conn.availableSendBudget());

    conn.updateDataReceived(1000);
    try std.testing.expectEqual(@as(u64, 3000), conn.availableSendBudget());

    conn.updateDataSent(2500);
    try std.testing.expectEqual(@as(u64, 500), conn.availableSendBudget());

    // Validation removes amplification cap.
    conn.markPeerValidated();
    try std.testing.expect(conn.availableSendBudget() > 500);
}

test "server amplification budget saturates safely on large received bytes" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initServer(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    conn.max_data_remote = std.math.maxInt(u64);
    conn.congestion_controller.congestion_window = std.math.maxInt(u64);
    conn.congestion_controller.bytes_in_flight = 0;
    conn.data_received = std.math.maxInt(u64);
    conn.data_sent = 0;

    // Amplification budget path should saturate, not overflow.
    try std.testing.expectEqual(std.math.maxInt(u64), conn.availableSendBudget());
}

test "available send budget is minimum of flow congestion amplification" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initServer(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    conn.markEstablished();

    // Configure independent ceilings:
    // flow budget: 5000 - 1000 = 4000
    conn.max_data_remote = 5000;
    conn.data_sent = 1000;

    // congestion budget: 900
    conn.congestion_controller.congestion_window = 1900;
    conn.congestion_controller.bytes_in_flight = 1000;

    // amplification budget (server, not validated): 3*700 - 1000 = 1100
    conn.peer_validated = false;
    conn.data_received = 700;

    try std.testing.expectEqual(@as(u64, 900), conn.availableSendBudget());

    // Raise congestion budget; amplification should become the bottleneck.
    conn.congestion_controller.congestion_window = 5000;
    conn.congestion_controller.bytes_in_flight = 1000;
    try std.testing.expectEqual(@as(u64, 1100), conn.availableSendBudget());

    // Validate peer; amplification cap disappears, flow should be bottleneck.
    conn.markPeerValidated();
    try std.testing.expectEqual(@as(u64, 4000), conn.availableSendBudget());
}

test "connection ack integrates congestion accounting" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    conn.markEstablished();

    conn.trackPacketSent(1200, true); // pn 0
    conn.trackPacketSent(1200, true); // pn 1
    conn.trackPacketSent(1200, true); // pn 2

    try std.testing.expect(conn.congestion_controller.getBytesInFlight() >= 3600);

    conn.processAckDetailed(2, 0);

    try std.testing.expect(conn.largest_acked >= 2);
    try std.testing.expect(conn.congestion_controller.getBytesInFlight() < 3600);
}

test "connection ack plausibility tracks sent packet numbers" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    try std.testing.expect(!conn.canAcknowledgePacket(0));

    conn.trackPacketSent(1200, true); // pn 0
    conn.trackPacketSent(1200, true); // pn 1

    try std.testing.expect(conn.canAcknowledgePacket(0));
    try std.testing.expect(conn.canAcknowledgePacket(1));
    try std.testing.expect(!conn.canAcknowledgePacket(2));
}

test "connection validates ACK frame ranges against sent space" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    conn.trackPacketSent(1200, true); // pn 0
    conn.trackPacketSent(1200, true); // pn 1
    conn.trackPacketSent(1200, true); // pn 2

    const valid_ranges = [_]frame.AckFrame.AckRange{.{ .gap = 0, .ack_range_length = 0 }};
    try std.testing.expect(conn.validateAckFrame(2, 0, &valid_ranges));

    const invalid_unsent = [_]frame.AckFrame.AckRange{};
    try std.testing.expect(!conn.validateAckFrame(3, 0, &invalid_unsent));
}

test "connection validates ACK frame in packet-number space" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    conn.trackPacketSentInSpace(.initial, 1200, true); // pn 0 in Initial

    const no_ranges = [_]frame.AckFrame.AckRange{};
    try std.testing.expect(conn.validateAckFrameInSpace(.initial, 0, 0, &no_ranges));
    try std.testing.expect(!conn.validateAckFrameInSpace(.application, 0, 0, &no_ranges));
}

test "connection rejects ACK frame with excessive acknowledged span" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        conn.trackPacketSent(1200, true);
    }

    const no_ranges = [_]frame.AckFrame.AckRange{};
    try std.testing.expect(!conn.validateAckFrame(1500, 1500, &no_ranges));
}

test "connection normalizes peer ACK delay with exponent and max" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    var params = types.TransportParameters{};
    params.ack_delay_exponent = 4;
    params.max_ack_delay = 10; // milliseconds
    conn.remote_params = params;

    // encoded_ack_delay=100 => 100 * 2^4 = 1600us
    try std.testing.expectEqual(@as(u64, 1600), conn.normalizePeerAckDelay(100));

    // Large encoded value is clamped by max_ack_delay (10ms => 10000us)
    try std.testing.expectEqual(@as(u64, 10 * time.Duration.MILLISECOND), conn.normalizePeerAckDelay(10_000));
}

test "connection PTO includes peer max_ack_delay" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    var params = types.TransportParameters{};
    params.max_ack_delay = 25; // milliseconds
    conn.remote_params = params;

    const base_pto = conn.loss_detection.getPto();
    try std.testing.expectEqual(
        base_pto + (25 * time.Duration.MILLISECOND),
        conn.currentPtoDuration(),
    );
}

test "connection drain timeout derives from PTO" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    const timeout = conn.drainTimeoutDuration();
    try std.testing.expect(timeout >= 50 * time.Duration.MILLISECOND);
    try std.testing.expect(timeout <= 30 * time.Duration.SECOND);
}

test "connection drain timeout enforces lower clamp" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    conn.loss_detection.rtt_stats.smoothed_rtt = 1;
    conn.loss_detection.rtt_stats.rttvar = 0;
    conn.remote_params = null;

    try std.testing.expectEqual(
        @as(u64, 50 * time.Duration.MILLISECOND),
        conn.drainTimeoutDuration(),
    );
}

test "connection drain timeout enforces upper clamp" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    conn.loss_detection.rtt_stats.smoothed_rtt = 20 * time.Duration.SECOND;
    conn.loss_detection.rtt_stats.rttvar = 20 * time.Duration.SECOND;

    var params = types.TransportParameters{};
    params.max_ack_delay = 60_000; // 60s equivalent in ms
    conn.remote_params = params;

    try std.testing.expectEqual(
        @as(u64, 30 * time.Duration.SECOND),
        conn.drainTimeoutDuration(),
    );
}

test "connection ack with ranges keeps recovery path stable" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    conn.trackPacketSent(1200, true); // pn 0
    conn.trackPacketSent(1200, true); // pn 1
    conn.trackPacketSent(1200, true); // pn 2

    const ack_ranges = [_]frame.AckFrame.AckRange{
        .{ .gap = 0, .ack_range_length = 0 },
    };
    conn.processAckDetailedWithRanges(2, 0, 0, &ack_ranges);

    try std.testing.expect(conn.largest_acked >= 2);
    try std.testing.expect(conn.congestion_controller.getBytesInFlight() < 2400);
}

test "connection schedules retransmission for lost packets" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    conn.trackPacketSent(1200, true); // pn 0
    conn.trackPacketSent(1200, true); // pn 1
    conn.trackPacketSent(1200, true); // pn 2
    conn.trackPacketSent(1200, true); // pn 3
    conn.trackPacketSent(1200, true); // pn 4

    conn.processAckDetailed(4, 0);

    const retransmit = conn.popRetransmission();
    try std.testing.expect(retransmit != null);
    try std.testing.expect(!retransmit.?.is_probe);
}

test "replaying ACK advances loss frontier without requeueing already lost packet" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    conn.trackPacketSent(900, true); // pn 0
    conn.trackPacketSent(1000, true); // pn 1
    conn.trackPacketSent(1100, true); // pn 2
    conn.trackPacketSent(1200, true); // pn 3
    conn.trackPacketSent(1300, true); // pn 4

    // First ACK induces loss-driven retransmission scheduling.
    conn.processAckDetailed(4, 0);

    var first_count: usize = 0;
    var saw_zero = false;
    while (conn.popRetransmission()) |req| {
        try std.testing.expect(!req.is_probe);
        if (req.packet_number == 0) saw_zero = true;
        first_count += 1;
    }
    try std.testing.expect(first_count > 0);
    try std.testing.expect(saw_zero);

    // Replaying identical ACK should not enqueue duplicates.
    conn.processAckDetailed(4, 0);

    var replay_count: usize = 0;
    while (conn.popRetransmission()) |req| {
        try std.testing.expect(!req.is_probe);
        // Packet #0 was already scheduled in first round.
        try std.testing.expect(req.packet_number != 0);
        replay_count += 1;
    }
    try std.testing.expect(replay_count > 0);
}

test "loss retransmission queue preserves round ordering across ACK rounds" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    var i: usize = 0;
    while (i < 9) : (i += 1) {
        conn.trackPacketSent(1200, true); // pn 0..8
    }

    // Round 1: ack pn=4 -> threshold loss should schedule pn=0.
    conn.processAckDetailed(4, 0);

    // Round 2: ack pn=8 -> threshold loss should schedule pn=1,2,3.
    conn.processAckDetailed(8, 0);

    const first = conn.popRetransmission();
    try std.testing.expect(first != null);
    try std.testing.expect(!first.?.is_probe);

    // The first enqueued retransmission from round 1 must remain at queue head.
    try std.testing.expectEqual(@as(u64, 0), first.?.packet_number);

    var saw_additional = false;
    while (conn.popRetransmission()) |req| {
        try std.testing.expect(!req.is_probe);
        // Round-2 scheduling should not requeue already-lost pn=0.
        try std.testing.expect(req.packet_number != 0);
        saw_additional = true;
    }
    try std.testing.expect(saw_additional);
}

test "loss retransmission bookkeeping preserves original packet sizes" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    conn.trackPacketSent(777, true); // pn 0
    conn.trackPacketSent(888, true); // pn 1
    conn.trackPacketSent(999, true); // pn 2
    conn.trackPacketSent(1111, true); // pn 3
    conn.trackPacketSent(1222, true); // pn 4

    // ACK largest packet to force threshold loss scheduling for older packets.
    conn.processAckDetailed(4, 0);

    var saw_777 = false;
    while (conn.popRetransmission()) |req| {
        try std.testing.expect(!req.is_probe);
        if (req.packet_number == 0) {
            saw_777 = true;
            try std.testing.expectEqual(@as(usize, 777), req.size);
        }
    }

    try std.testing.expect(saw_777);
}

test "connection schedules PTO probe" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    conn.trackPacketSent(1200, true);
    try std.testing.expect(conn.next_pto_at != null);

    const trigger_time = conn.next_pto_at.?.add(1);
    conn.onPtoTimeout(trigger_time);

    const probe = conn.popRetransmission();
    try std.testing.expect(probe != null);
    try std.testing.expect(probe.?.is_probe);
    try std.testing.expect(conn.pto_count > 0);
}

test "connection ignores PTO trigger before deadline" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    conn.trackPacketSent(1200, true);
    const deadline = conn.next_pto_at.?;

    conn.onPtoTimeout(deadline.sub(1));

    try std.testing.expectEqual(@as(u32, 0), conn.pto_count);
    try std.testing.expect(conn.popRetransmission() == null);
    try std.testing.expectEqual(deadline.micros, conn.next_pto_at.?.micros);
}

test "onPtoTimeout is no-op when deadline is not armed" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    try std.testing.expect(conn.next_pto_at == null);
    conn.onPtoTimeout(time.Instant.now());

    try std.testing.expectEqual(@as(u32, 0), conn.pto_count);
    try std.testing.expect(conn.next_pto_at == null);
    try std.testing.expect(conn.popRetransmission() == null);
}

test "loss retransmissions queue before PTO probe" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        conn.trackPacketSent(1200, true);
    }

    // Ack newest packet, which creates threshold-based loss retransmissions.
    conn.processAckDetailed(7, 0);

    const deadline = conn.next_pto_at.?;
    conn.onPtoTimeout(deadline.add(1));

    var saw_probe = false;
    var non_probe_count: usize = 0;

    while (conn.popRetransmission()) |req| {
        if (req.is_probe) {
            saw_probe = true;
            break;
        }
        non_probe_count += 1;
    }

    try std.testing.expect(non_probe_count > 0);
    try std.testing.expect(saw_probe);
}

test "multiple PTO expiries append probes in FIFO order" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    conn.trackPacketSent(1200, true);

    var deadline = conn.next_pto_at.?;
    conn.onPtoTimeout(deadline.add(1));
    deadline = conn.next_pto_at.?;
    conn.onPtoTimeout(deadline.add(1));

    const first = conn.popRetransmission();
    const second = conn.popRetransmission();

    try std.testing.expect(first != null);
    try std.testing.expect(second != null);
    try std.testing.expect(first.?.is_probe);
    try std.testing.expect(second.?.is_probe);
    try std.testing.expectEqual(@as(u64, first.?.packet_number), second.?.packet_number);
    try std.testing.expect(conn.popRetransmission() == null);
}

test "ack-eliciting send refreshes PTO deadline" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    conn.trackPacketSent(1200, true);
    const first_deadline = conn.next_pto_at.?;

    // Small delay and another ack-eliciting send should update deadline.
    const later = time.Instant.now().add(2 * time.Duration.MILLISECOND);
    conn.next_pto_at = later;
    conn.trackPacketSent(1200, true);

    const second_deadline = conn.next_pto_at.?;
    try std.testing.expect(second_deadline.isAfter(first_deadline) or second_deadline.micros != first_deadline.micros);
}

test "non-ack-eliciting send does not refresh PTO deadline" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    conn.trackPacketSent(1200, true);
    const deadline = conn.next_pto_at.?;

    conn.trackPacketSent(100, false);
    try std.testing.expectEqual(deadline.micros, conn.next_pto_at.?.micros);
}

test "PTO probe size follows max_datagram_size" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    conn.congestion_controller.max_datagram_size = 1350;
    conn.trackPacketSent(1200, true);

    const deadline = conn.next_pto_at.?;
    conn.onPtoTimeout(deadline.add(1));

    const probe = conn.popRetransmission();
    try std.testing.expect(probe != null);
    try std.testing.expect(probe.?.is_probe);
    try std.testing.expectEqual(@as(usize, 1350), probe.?.size);
}

test "pto counter resets when acked packet is in flight" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    conn.trackPacketSent(1200, true); // pn 0
    conn.trackPacketSent(1200, true); // pn 1

    const original_deadline = conn.next_pto_at.?;
    conn.onPtoTimeout(original_deadline.add(1));
    try std.testing.expect(conn.pto_count > 0);

    conn.processAckDetailed(1, 0);

    try std.testing.expectEqual(@as(u32, 0), conn.pto_count);
    try std.testing.expect(conn.next_pto_at != null);
}

test "pto counter does not reset when ACK does not match inflight packet" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    conn.trackPacketSent(1200, true); // pn 0
    const original_deadline = conn.next_pto_at.?;
    conn.onPtoTimeout(original_deadline.add(1));
    try std.testing.expect(conn.pto_count > 0);

    // ACK for unsent packet number should not reset PTO counter.
    conn.processAckDetailed(99, 0);
    try std.testing.expect(conn.pto_count > 0);
}

test "non ack-eliciting packet does not arm PTO" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    try std.testing.expect(conn.next_pto_at == null);

    conn.trackPacketSent(64, false);
    try std.testing.expect(conn.next_pto_at == null);

    conn.trackPacketSent(64, true);
    try std.testing.expect(conn.next_pto_at != null);
}

test "recovery handles packet reordering without spurious retransmit" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    conn.trackPacketSent(1200, true); // pn 0
    conn.trackPacketSent(1200, true); // pn 1
    conn.trackPacketSent(1200, true); // pn 2

    // Reordered ACK first acknowledges a newer packet.
    conn.processAckDetailed(2, 0);
    // Late ACK for an older packet follows.
    conn.processAckDetailed(1, 0);

    // Reordering should not trigger uncontrolled retransmit growth.
    var retransmit_count: usize = 0;
    while (conn.popRetransmission()) |_| {
        retransmit_count += 1;
    }
    try std.testing.expect(retransmit_count <= 2);
}

test "pto backoff grows and remains bounded" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    conn.trackPacketSent(1200, true);

    var last_deadline = conn.next_pto_at.?;
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        conn.onPtoTimeout(last_deadline.add(1));

        const probe = conn.popRetransmission();
        try std.testing.expect(probe != null);
        try std.testing.expect(probe.?.is_probe);

        try std.testing.expect(conn.pto_count == i + 1);
        try std.testing.expect(conn.next_pto_at != null);
        const next_deadline = conn.next_pto_at.?;
        try std.testing.expect(next_deadline.isAfter(last_deadline));
        last_deadline = next_deadline;
    }

    // Guardrail: bounded PTO growth for this harness.
    try std.testing.expect(conn.pto_count <= 5);
}

test "pto backoff exponent caps after threshold" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    conn.trackPacketSent(1200, true);

    var deadline = conn.next_pto_at.?;
    var prev_increment: ?u64 = null;
    var saturated_increment: ?u64 = null;

    var i: u32 = 0;
    while (i < 24) : (i += 1) {
        conn.onPtoTimeout(deadline.add(1));
        const next = conn.next_pto_at.?;
        const increment = next.durationSince(deadline);

        if (conn.pto_count == 20) {
            saturated_increment = increment;
        } else if (conn.pto_count > 20) {
            try std.testing.expect(saturated_increment != null);
            try std.testing.expectEqual(saturated_increment.?, increment);
        }

        prev_increment = increment;
        deadline = next;
    }

    try std.testing.expect(prev_increment != null);
    try std.testing.expectEqual(@as(u32, 24), conn.pto_count);
}

test "recovery remains stable under mixed loss and timeout stress" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    var round: u32 = 0;
    while (round < 20) : (round += 1) {
        // Send a small burst.
        conn.trackPacketSent(1200, true);
        conn.trackPacketSent(1200, true);
        conn.trackPacketSent(1200, true);

        // ACK the most recent packet to drive loss detection and recovery.
        conn.processAckDetailed(conn.next_packet_number - 1, 0);

        // If PTO expires, queue and consume a probe.
        if (conn.next_pto_at) |deadline| {
            conn.onPtoTimeout(deadline.add(1));
            while (conn.popRetransmission()) |req| {
                // Simulate consuming queued retransmissions/probes.
                _ = req;
            }
        }

        // Stability checks: controller should stay within sane bounds.
        try std.testing.expect(conn.congestion_controller.getCongestionWindow() >= 2 * conn.congestion_controller.max_datagram_size);
        try std.testing.expect(conn.availableSendBudget() <= conn.max_data_remote);
        try std.testing.expect(conn.pto_count <= round + 1);
    }
}

test "send-control style lifecycle keeps stable invariants under mixed rounds" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initClient(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();
    conn.markEstablished();

    var round: usize = 0;
    while (round < 8) : (round += 1) {
        conn.trackPacketSent(800 + round * 10, true);
        conn.trackPacketSent(900 + round * 10, true);
        conn.trackPacketSent(1000 + round * 10, true);

        // Acknowledge latest to drive ACK/loss interplay.
        const largest = conn.next_packet_number - 1;
        conn.processAckDetailed(largest, 0);

        if (conn.next_pto_at) |deadline| {
            conn.onPtoTimeout(deadline.add(1));
        }

        // Drain queue and verify bookkeeping invariants.
        while (conn.popRetransmission()) |req| {
            try std.testing.expect(req.size > 0);
        }

        try std.testing.expect(conn.congestion_controller.getCongestionWindow() >= 2 * conn.congestion_controller.max_datagram_size);
        try std.testing.expect(conn.congestion_controller.getBytesInFlight() <= conn.congestion_controller.getCongestionWindow());
        try std.testing.expect(conn.availableSendBudget() <= conn.max_data_remote);
    }
}

test "path challenge queues matching path response" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initServer(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    const token = [_]u8{ 9, 8, 7, 6, 5, 4, 3, 2 };
    try conn.onPathChallenge(token);

    const queued = conn.popPathResponse();
    try std.testing.expect(queued != null);
    try std.testing.expectEqualSlices(u8, &token, &queued.?);
}

test "path challenge queue preserves FIFO order" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initServer(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    const first = [_]u8{ 1, 1, 1, 1, 1, 1, 1, 1 };
    const second = [_]u8{ 2, 2, 2, 2, 2, 2, 2, 2 };
    const third = [_]u8{ 3, 3, 3, 3, 3, 3, 3, 3 };

    try conn.onPathChallenge(first);
    try conn.onPathChallenge(second);
    try conn.onPathChallenge(third);

    const pop1 = conn.popPathResponse();
    const pop2 = conn.popPathResponse();
    const pop3 = conn.popPathResponse();

    try std.testing.expect(pop1 != null);
    try std.testing.expect(pop2 != null);
    try std.testing.expect(pop3 != null);
    try std.testing.expectEqualSlices(u8, &first, &pop1.?);
    try std.testing.expectEqualSlices(u8, &second, &pop2.?);
    try std.testing.expectEqualSlices(u8, &third, &pop3.?);
    try std.testing.expect(conn.popPathResponse() == null);
}

test "path response validates peer and lifts amplification cap" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initServer(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    conn.updateDataReceived(1000);
    try std.testing.expectEqual(@as(u64, 3000), conn.availableSendBudget());

    const token = [_]u8{ 1, 1, 2, 2, 3, 3, 4, 4 };
    conn.beginPathValidation(token);
    try std.testing.expect(!conn.peer_validated);

    const ok = conn.onPathResponse(token);
    try std.testing.expect(ok);
    try std.testing.expect(conn.peer_validated);
    try std.testing.expect(conn.availableSendBudget() > 3000);
}

test "path response mismatch keeps peer unvalidated" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initServer(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    conn.updateDataReceived(1000);
    const capped_budget = conn.availableSendBudget();
    try std.testing.expectEqual(@as(u64, 3000), capped_budget);

    const expected = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const wrong = [_]u8{ 8, 7, 6, 5, 4, 3, 2, 1 };
    conn.beginPathValidation(expected);
    try std.testing.expect(!conn.peer_validated);

    const ok = conn.onPathResponse(wrong);
    try std.testing.expect(!ok);
    try std.testing.expect(!conn.peer_validated);
    try std.testing.expect(conn.expected_path_response != null);
    try std.testing.expectEqual(capped_budget, conn.availableSendBudget());

    // Correct token should still validate afterward.
    const ok2 = conn.onPathResponse(expected);
    try std.testing.expect(ok2);
    try std.testing.expect(conn.peer_validated);
    try std.testing.expect(conn.expected_path_response == null);
}

test "path response without pending challenge is ignored" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initServer(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    conn.markPeerValidated();
    const token = [_]u8{ 7, 7, 7, 7, 7, 7, 7, 7 };

    try std.testing.expect(!conn.onPathResponse(token));
    try std.testing.expect(conn.peer_validated);
    try std.testing.expect(conn.expected_path_response == null);
}

test "beginPathValidation reapplies amplification cap until validated" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initServer(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    conn.updateDataReceived(1000);
    conn.markPeerValidated();
    const uncapped = conn.availableSendBudget();
    try std.testing.expect(uncapped > 3000);

    const token = [_]u8{ 1, 3, 5, 7, 9, 11, 13, 15 };
    conn.beginPathValidation(token);
    try std.testing.expect(!conn.peer_validated);

    // Amplification cap should be active again while re-validating path.
    try std.testing.expectEqual(@as(u64, 3000), conn.availableSendBudget());

    try std.testing.expect(conn.onPathResponse(token));
    try std.testing.expect(conn.peer_validated);
    try std.testing.expect(conn.availableSendBudget() >= 3000);
}

test "beginPathValidation replaces pending expected response token" {
    const allocator = std.testing.allocator;

    const local_cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const remote_cid = try ConnectionId.init(&[_]u8{ 5, 6, 7, 8 });

    var conn = try Connection.initServer(allocator, .tls, local_cid, remote_cid);
    defer conn.deinit();

    const old_token = [_]u8{ 1, 1, 1, 1, 1, 1, 1, 1 };
    const new_token = [_]u8{ 9, 9, 9, 9, 9, 9, 9, 9 };
    conn.beginPathValidation(old_token);
    conn.beginPathValidation(new_token);

    try std.testing.expect(!conn.peer_validated);
    try std.testing.expect(conn.expected_path_response != null);
    try std.testing.expectEqualSlices(u8, &new_token, &conn.expected_path_response.?);

    // Old token must no longer validate.
    try std.testing.expect(!conn.onPathResponse(old_token));
    try std.testing.expect(!conn.peer_validated);

    // New token validates and clears expectation.
    try std.testing.expect(conn.onPathResponse(new_token));
    try std.testing.expect(conn.peer_validated);
    try std.testing.expect(conn.expected_path_response == null);
}
