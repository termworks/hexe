const std = @import("std");
const time_mod = @import("../utils/time.zig");
const types = @import("types.zig");

/// Loss detection and recovery for QUIC (RFC 9002)
///
/// Implements packet loss detection, RTT estimation, and retransmission logic.
/// All durations are in microseconds.
pub const LossDetectionError = error{
    InvalidPacketNumber,
    InvalidRtt,
    TooManyLostPackets,
};

/// Packet number space
pub const PacketNumberSpace = enum {
    initial,
    handshake,
    application,

    pub fn toString(self: PacketNumberSpace) []const u8 {
        return switch (self) {
            .initial => "Initial",
            .handshake => "Handshake",
            .application => "Application",
        };
    }
};

/// Sent packet information
pub const SentPacket = struct {
    packet_number: types.PacketNumber,
    time_sent: time_mod.Instant,
    size: usize,
    ack_eliciting: bool,
    in_flight: bool,

    pub fn init(
        packet_number: types.PacketNumber,
        time_sent: time_mod.Instant,
        size: usize,
        ack_eliciting: bool,
    ) SentPacket {
        return SentPacket{
            .packet_number = packet_number,
            .time_sent = time_sent,
            .size = size,
            .ack_eliciting = ack_eliciting,
            .in_flight = true,
        };
    }
};

/// RTT statistics (all durations in microseconds)
pub const RttStats = struct {
    /// Smoothed RTT (microseconds)
    smoothed_rtt: u64,

    /// RTT variance (microseconds)
    rttvar: u64,

    /// Minimum RTT observed (microseconds)
    min_rtt: u64,

    /// Latest RTT sample (microseconds)
    latest_rtt: u64,

    /// Initialize RTT stats
    pub fn init() RttStats {
        return RttStats{
            .smoothed_rtt = 333 * time_mod.Duration.MILLISECOND,
            .rttvar = 167 * time_mod.Duration.MILLISECOND,
            .min_rtt = 0,
            .latest_rtt = 0,
        };
    }

    /// Update RTT with new sample (all params in microseconds)
    pub fn updateRtt(self: *RttStats, latest_rtt: u64, ack_delay: u64) void {
        self.latest_rtt = latest_rtt;

        // First RTT sample
        if (self.min_rtt == 0) {
            self.min_rtt = latest_rtt;
            self.smoothed_rtt = latest_rtt;
            self.rttvar = latest_rtt / 2;
            return;
        }

        // Update min_rtt
        if (latest_rtt < self.min_rtt) {
            self.min_rtt = latest_rtt;
        }

        // Adjust for ack delay (capped at max_ack_delay)
        const adjusted_rtt = if (latest_rtt > self.min_rtt + ack_delay)
            latest_rtt - ack_delay
        else
            latest_rtt;

        // RTTVAR = 3/4 * RTTVAR + 1/4 * abs(SRTT - adjusted_rtt)
        const rtt_diff = if (self.smoothed_rtt > adjusted_rtt)
            self.smoothed_rtt - adjusted_rtt
        else
            adjusted_rtt - self.smoothed_rtt;

        const rttvar_sample = rtt_diff / 4;
        const rttvar_decay = (self.rttvar * 3) / 4;
        self.rttvar = rttvar_decay + rttvar_sample;

        // SRTT = 7/8 * SRTT + 1/8 * adjusted_rtt
        const srtt_decay = (self.smoothed_rtt * 7) / 8;
        const srtt_sample = adjusted_rtt / 8;
        self.smoothed_rtt = srtt_decay + srtt_sample;
    }

    /// Get probe timeout (PTO) in microseconds
    pub fn pto(self: *const RttStats) u64 {
        return self.smoothed_rtt + (self.rttvar * 4);
    }
};

/// Loss detection state for a packet number space
pub const SpaceDetectionState = struct {
    /// Largest acknowledged packet number
    largest_acked: ?types.PacketNumber,

    /// Time of last ACK-eliciting packet sent
    time_of_last_ack_eliciting_packet: ?time_mod.Instant,

    /// Loss time for this space
    loss_time: ?time_mod.Instant,

    /// Sent packets awaiting acknowledgment
    sent_packets: std.ArrayList(SentPacket),

    pub fn init(allocator: std.mem.Allocator) SpaceDetectionState {
        _ = allocator;
        return SpaceDetectionState{
            .largest_acked = null,
            .time_of_last_ack_eliciting_packet = null,
            .loss_time = null,
            .sent_packets = .{},
        };
    }

    pub fn deinit(self: *SpaceDetectionState, allocator: std.mem.Allocator) void {
        self.sent_packets.deinit(allocator);
    }

    /// Record sent packet
    pub fn onPacketSent(self: *SpaceDetectionState, allocator: std.mem.Allocator, packet: SentPacket) !void {
        if (packet.ack_eliciting) {
            self.time_of_last_ack_eliciting_packet = packet.time_sent;
        }
        try self.sent_packets.append(allocator, packet);
    }

    /// Process ACK for packet range
    pub fn onAckReceived(
        self: *SpaceDetectionState,
        allocator: std.mem.Allocator,
        packet_number: types.PacketNumber,
    ) !?SentPacket {
        _ = allocator;

        // Update largest acked
        if (self.largest_acked == null or packet_number > self.largest_acked.?) {
            self.largest_acked = packet_number;
        }

        var acked_packet: ?SentPacket = null;

        // Mark packet as acked (remove from sent_packets)
        var i: usize = 0;
        while (i < self.sent_packets.items.len) {
            if (self.sent_packets.items[i].packet_number == packet_number) {
                acked_packet = self.sent_packets.swapRemove(i);
                break;
            }
            i += 1;
        }

        return acked_packet;
    }

    /// Process ACKs for multiple packet numbers.
    pub fn onAckReceivedMany(
        self: *SpaceDetectionState,
        allocator: std.mem.Allocator,
        packet_numbers: []const types.PacketNumber,
    ) !std.ArrayList(SentPacket) {
        var acked_packets: std.ArrayList(SentPacket) = .{};

        for (packet_numbers) |packet_number| {
            if (try self.onAckReceived(allocator, packet_number)) |acked| {
                try acked_packets.append(allocator, acked);
            }
        }

        return acked_packets;
    }

    /// Detect lost packets
    pub fn detectLostPackets(
        self: *SpaceDetectionState,
        allocator: std.mem.Allocator,
        now: time_mod.Instant,
        loss_threshold: u64,
        loss_delay: u64,
    ) !std.ArrayList(SentPacket) {
        var lost_packets: std.ArrayList(SentPacket) = .{};

        if (self.largest_acked == null) {
            return lost_packets;
        }

        const largest_acked = self.largest_acked.?;
        const packet_threshold = largest_acked -| loss_threshold;

        var i: usize = 0;
        while (i < self.sent_packets.items.len) {
            const packet = self.sent_packets.items[i];

            // Packet is lost if:
            // 1. It's below the packet threshold
            // 2. Or it was sent long enough ago
            const lost_by_threshold = packet.packet_number < packet_threshold;
            const time_since_sent = now.durationSince(packet.time_sent);
            const lost_by_time = time_since_sent > loss_delay;

            if (lost_by_threshold or lost_by_time) {
                try lost_packets.append(allocator, packet);
                _ = self.sent_packets.swapRemove(i);
            } else {
                i += 1;
            }
        }

        return lost_packets;
    }

    pub fn maxObservedPacketNumber(self: *const SpaceDetectionState) ?types.PacketNumber {
        var max_seen = self.largest_acked;

        for (self.sent_packets.items) |packet| {
            if (max_seen == null or packet.packet_number > max_seen.?) {
                max_seen = packet.packet_number;
            }
        }

        return max_seen;
    }
};

/// Loss detection manager
pub const LossDetection = struct {
    allocator: std.mem.Allocator,

    /// RTT statistics
    rtt_stats: RttStats,

    /// Detection state per packet number space
    initial: SpaceDetectionState,
    handshake: SpaceDetectionState,
    application: SpaceDetectionState,

    /// Loss detection threshold (packet threshold)
    packet_threshold: u64,

    /// Time threshold multiplier for loss detection
    time_threshold: u64,

    /// Initialize loss detection
    pub fn init(allocator: std.mem.Allocator) LossDetection {
        return LossDetection{
            .allocator = allocator,
            .rtt_stats = RttStats.init(),
            .initial = SpaceDetectionState.init(allocator),
            .handshake = SpaceDetectionState.init(allocator),
            .application = SpaceDetectionState.init(allocator),
            .packet_threshold = 3, // RFC 9002 default
            .time_threshold = 9, // 9/8 of RTT
        };
    }

    pub fn deinit(self: *LossDetection) void {
        self.initial.deinit(self.allocator);
        self.handshake.deinit(self.allocator);
        self.application.deinit(self.allocator);
    }

    /// Get space state
    fn getSpace(self: *LossDetection, space: PacketNumberSpace) *SpaceDetectionState {
        return switch (space) {
            .initial => &self.initial,
            .handshake => &self.handshake,
            .application => &self.application,
        };
    }

    fn getSpaceConst(self: *const LossDetection, space: PacketNumberSpace) *const SpaceDetectionState {
        return switch (space) {
            .initial => &self.initial,
            .handshake => &self.handshake,
            .application => &self.application,
        };
    }

    /// Record sent packet
    pub fn onPacketSent(
        self: *LossDetection,
        space: PacketNumberSpace,
        packet: SentPacket,
    ) !void {
        const space_state = self.getSpace(space);
        try space_state.onPacketSent(self.allocator, packet);
    }

    /// Process ACK frame (ack_delay in microseconds)
    pub fn onAckReceived(
        self: *LossDetection,
        space: PacketNumberSpace,
        largest_acked: types.PacketNumber,
        ack_delay: u64,
        now: time_mod.Instant,
    ) !AckResult {
        return self.onAckReceivedWithPacketNumbers(space, largest_acked, ack_delay, now, &[_]types.PacketNumber{largest_acked});
    }

    /// Process ACK frame with explicit acknowledged packet numbers.
    pub fn onAckReceivedWithPacketNumbers(
        self: *LossDetection,
        space: PacketNumberSpace,
        largest_acked: types.PacketNumber,
        ack_delay: u64,
        now: time_mod.Instant,
        acknowledged_packet_numbers: []const types.PacketNumber,
    ) !AckResult {
        const space_state = self.getSpace(space);

        // Update RTT if this ACKs the largest packet
        if (space_state.largest_acked == null or largest_acked > space_state.largest_acked.?) {
            // Find the packet to get its send time
            for (space_state.sent_packets.items) |packet| {
                if (packet.packet_number == largest_acked) {
                    const latest_rtt = now.durationSince(packet.time_sent);
                    self.rtt_stats.updateRtt(latest_rtt, ack_delay);
                    break;
                }
            }
        }

        // Process all acknowledged packets in this ACK frame.
        var acked_packets = try space_state.onAckReceivedMany(self.allocator, acknowledged_packet_numbers);
        errdefer acked_packets.deinit(self.allocator);

        var acked_packet: ?SentPacket = null;
        for (acked_packets.items) |acked| {
            if (acked.packet_number == largest_acked) {
                acked_packet = acked;
                break;
            }
        }

        // Detect lost packets
        const loss_delay = (self.rtt_stats.smoothed_rtt * self.time_threshold) / 8;
        const lost_packets = try space_state.detectLostPackets(
            self.allocator,
            now,
            self.packet_threshold,
            loss_delay,
        );

        return AckResult{
            .acked_packet = acked_packet,
            .acked_packets = acked_packets,
            .lost_packets = lost_packets,
        };
    }

    /// Get PTO (Probe Timeout) in microseconds
    pub fn getPto(self: *const LossDetection) u64 {
        return self.rtt_stats.pto();
    }

    /// Get smoothed RTT in microseconds
    pub fn getSmoothedRtt(self: *const LossDetection) u64 {
        return self.rtt_stats.smoothed_rtt;
    }

    /// Returns the highest packet number observed in a packet number space.
    pub fn maxObservedPacketNumber(self: *const LossDetection, space: PacketNumberSpace) ?types.PacketNumber {
        const space_state = self.getSpaceConst(space);
        return space_state.maxObservedPacketNumber();
    }
};

// Tests

test "Loss detection initialization" {
    const allocator = std.testing.allocator;

    var ld = LossDetection.init(allocator);
    defer ld.deinit();

    try std.testing.expectEqual(@as(u64, 3), ld.packet_threshold);
    try std.testing.expect(ld.rtt_stats.smoothed_rtt > 0);
}

test "RTT stats initialization" {
    const rtt_stats = RttStats.init();

    // Default values from RFC 9002
    try std.testing.expectEqual(@as(u64, 333 * time_mod.Duration.MILLISECOND), rtt_stats.smoothed_rtt);
    try std.testing.expectEqual(@as(u64, 167 * time_mod.Duration.MILLISECOND), rtt_stats.rttvar);
}

test "RTT stats first sample" {
    var rtt_stats = RttStats.init();

    const sample = 100 * time_mod.Duration.MILLISECOND;
    rtt_stats.updateRtt(sample, 0);

    try std.testing.expectEqual(@as(u64, 100 * time_mod.Duration.MILLISECOND), rtt_stats.smoothed_rtt);
    try std.testing.expectEqual(@as(u64, 50 * time_mod.Duration.MILLISECOND), rtt_stats.rttvar);
    try std.testing.expectEqual(@as(u64, 100 * time_mod.Duration.MILLISECOND), rtt_stats.min_rtt);
}

test "RTT stats multiple samples" {
    var rtt_stats = RttStats.init();

    // First sample
    rtt_stats.updateRtt(100 * time_mod.Duration.MILLISECOND, 0);

    // Second sample (slightly higher)
    rtt_stats.updateRtt(110 * time_mod.Duration.MILLISECOND, 0);

    // SRTT should be between 100 and 110
    const srtt = rtt_stats.smoothed_rtt / time_mod.Duration.MILLISECOND;
    try std.testing.expect(srtt > 100 and srtt < 110);

    // Min RTT should still be 100
    try std.testing.expectEqual(@as(u64, 100 * time_mod.Duration.MILLISECOND), rtt_stats.min_rtt);
}

test "RTT stats matches lsquic reference progression" {
    var rtt_stats = RttStats.init();

    // LSQUIC test_rtt.c vector #1: 1 second sample.
    rtt_stats.updateRtt(1_000_000, 0);
    try std.testing.expectEqual(@as(u64, 1_000_000), rtt_stats.smoothed_rtt);

    // LSQUIC test_rtt.c vector #2: 0.5 second sample -> srtt = 937500.
    rtt_stats.updateRtt(500_000, 0);
    try std.testing.expectEqual(@as(u64, 937_500), rtt_stats.smoothed_rtt);
}

test "RTT ack-delay adjustment uses strict boundary" {
    var rtt_stats = RttStats.init();

    // First sample sets min_rtt.
    rtt_stats.updateRtt(1_000_000, 0);
    try std.testing.expectEqual(@as(u64, 1_000_000), rtt_stats.min_rtt);

    // Exactly min_rtt + ack_delay should not subtract ack_delay.
    rtt_stats.updateRtt(1_100_000, 100_000);
    const srtt_at_boundary = rtt_stats.smoothed_rtt;

    // One microsecond above boundary should subtract ack_delay.
    rtt_stats.updateRtt(1_100_001, 100_000);
    try std.testing.expect(rtt_stats.smoothed_rtt < srtt_at_boundary);
}

test "RTT stats PTO calculation" {
    var rtt_stats = RttStats.init();
    rtt_stats.updateRtt(100 * time_mod.Duration.MILLISECOND, 0);

    const pto = rtt_stats.pto();

    // PTO = SRTT + 4 * RTTVAR
    // SRTT = 100, RTTVAR = 50
    // PTO = 100 + 4 * 50 = 300
    try std.testing.expectEqual(@as(u64, 300 * time_mod.Duration.MILLISECOND), pto);
}

test "Sent packet tracking" {
    const allocator = std.testing.allocator;

    var space = SpaceDetectionState.init(allocator);
    defer space.deinit(allocator);

    const now = time_mod.Instant.now();
    const packet = SentPacket.init(1, now, 1200, true);

    try space.onPacketSent(allocator, packet);

    try std.testing.expectEqual(@as(usize, 1), space.sent_packets.items.len);
    try std.testing.expect(space.time_of_last_ack_eliciting_packet != null);
}

test "ACK processing" {
    const allocator = std.testing.allocator;

    var space = SpaceDetectionState.init(allocator);
    defer space.deinit(allocator);

    const now = time_mod.Instant.now();

    // Send packets 1, 2, 3
    try space.onPacketSent(allocator, SentPacket.init(1, now, 1200, true));
    try space.onPacketSent(allocator, SentPacket.init(2, now, 1200, true));
    try space.onPacketSent(allocator, SentPacket.init(3, now, 1200, true));

    try std.testing.expectEqual(@as(usize, 3), space.sent_packets.items.len);

    // ACK packet 2
    const acked = try space.onAckReceived(allocator, 2);

    try std.testing.expectEqual(@as(u64, 2), space.largest_acked.?);
    try std.testing.expectEqual(@as(usize, 2), space.sent_packets.items.len);
    try std.testing.expect(acked != null);
    try std.testing.expectEqual(@as(u64, 2), acked.?.packet_number);
}

test "Loss detection by packet threshold" {
    const allocator = std.testing.allocator;

    var ld = LossDetection.init(allocator);
    defer ld.deinit();

    const now = time_mod.Instant.now();

    // Send packets 1, 2, 3, 4, 5
    try ld.onPacketSent(.application, SentPacket.init(1, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(2, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(3, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(4, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(5, now, 1200, true));

    // ACK packet 5 (packet threshold is 3, so packet 1 is declared lost)
    var ack_result = try ld.onAckReceived(.application, 5, 0, now);
    defer ack_result.acked_packets.deinit(allocator);
    defer ack_result.lost_packets.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), ack_result.lost_packets.items.len);
    try std.testing.expectEqual(@as(u64, 1), ack_result.lost_packets.items[0].packet_number);
}

test "ACK processing with multiple packet numbers" {
    const allocator = std.testing.allocator;

    var ld = LossDetection.init(allocator);
    defer ld.deinit();

    const now = time_mod.Instant.now();

    try ld.onPacketSent(.application, SentPacket.init(1, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(2, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(3, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(4, now, 1200, true));

    const acked_numbers = [_]types.PacketNumber{ 2, 4 };
    var ack_result = try ld.onAckReceivedWithPacketNumbers(.application, 4, 0, now, &acked_numbers);
    defer ack_result.acked_packets.deinit(allocator);
    defer ack_result.lost_packets.deinit(allocator);

    try std.testing.expectEqual(@as(?types.PacketNumber, 4), if (ack_result.acked_packet) |p| p.packet_number else null);
    try std.testing.expectEqual(@as(usize, 2), ack_result.acked_packets.items.len);
}

test "ACK processing ignores duplicate packet numbers in one ACK set" {
    const allocator = std.testing.allocator;

    var ld = LossDetection.init(allocator);
    defer ld.deinit();

    const now = time_mod.Instant.now();

    try ld.onPacketSent(.application, SentPacket.init(1, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(2, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(3, now, 1200, true));

    // Packet 2 appears twice; it must only be acknowledged once.
    const acked_numbers = [_]types.PacketNumber{ 2, 2, 3 };
    var ack_result = try ld.onAckReceivedWithPacketNumbers(.application, 3, 0, now, &acked_numbers);
    defer ack_result.acked_packets.deinit(allocator);
    defer ack_result.lost_packets.deinit(allocator);

    try std.testing.expectEqual(@as(?types.PacketNumber, 3), if (ack_result.acked_packet) |p| p.packet_number else null);
    try std.testing.expectEqual(@as(usize, 2), ack_result.acked_packets.items.len);

    // Only packet 1 remains outstanding.
    try std.testing.expectEqual(@as(usize, 1), ld.application.sent_packets.items.len);
    try std.testing.expectEqual(@as(u64, 1), ld.application.sent_packets.items[0].packet_number);
}

test "RTT ack delay does not underflow below min_rtt" {
    var rtt_stats = RttStats.init();

    // Establish min RTT.
    rtt_stats.updateRtt(100 * time_mod.Duration.MILLISECOND, 0);

    // Large ACK delay should not push adjusted RTT below min RTT.
    rtt_stats.updateRtt(105 * time_mod.Duration.MILLISECOND, 50 * time_mod.Duration.MILLISECOND);

    try std.testing.expect(rtt_stats.smoothed_rtt >= 100 * time_mod.Duration.MILLISECOND);
    try std.testing.expectEqual(@as(u64, 100 * time_mod.Duration.MILLISECOND), rtt_stats.min_rtt);
}

test "ACK for unsent packet updates largest_acked safely" {
    const allocator = std.testing.allocator;

    var ld = LossDetection.init(allocator);
    defer ld.deinit();

    const now = time_mod.Instant.now();

    // Acking a packet that was never tracked should not fail.
    var ack_result = try ld.onAckReceived(.application, 42, 0, now);
    defer ack_result.acked_packets.deinit(allocator);
    defer ack_result.lost_packets.deinit(allocator);

    try std.testing.expect(ack_result.acked_packet == null);
    try std.testing.expect(ld.application.largest_acked != null);
    try std.testing.expectEqual(@as(u64, 42), ld.application.largest_acked.?);
}

test "Loss detection by time threshold" {
    const allocator = std.testing.allocator;

    var ld = LossDetection.init(allocator);
    defer ld.deinit();

    const now = time_mod.Instant.now();

    // Send packet 1
    try ld.onPacketSent(.application, SentPacket.init(1, now, 1200, true));

    // Wait 1 second
    const later = now.add(time_mod.Duration.SECOND);

    // Send packet 2
    try ld.onPacketSent(.application, SentPacket.init(2, later, 1200, true));

    // ACK packet 2 much later (packet 1 should be lost by time)
    const much_later = later.add(2 * time_mod.Duration.SECOND);
    var ack_result = try ld.onAckReceived(.application, 2, 0, much_later);
    defer ack_result.acked_packets.deinit(allocator);
    defer ack_result.lost_packets.deinit(allocator);

    // Packet 1 should be lost by time
    try std.testing.expect(ack_result.lost_packets.items.len >= 1);
}

test "Loss detection time threshold uses strict greater-than" {
    const allocator = std.testing.allocator;

    var ld = LossDetection.init(allocator);
    defer ld.deinit();

    const base = time_mod.Instant.now();
    try ld.onPacketSent(.application, SentPacket.init(1, base, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(2, base, 1200, true));

    var first_ack = try ld.onAckReceived(.application, 2, 0, base);
    defer first_ack.acked_packets.deinit(allocator);
    defer first_ack.lost_packets.deinit(allocator);

    const loss_delay = (ld.rtt_stats.smoothed_rtt * ld.time_threshold) / 8;

    var at_threshold = try ld.onAckReceived(.application, 2, 0, base.add(loss_delay));
    defer at_threshold.acked_packets.deinit(allocator);
    defer at_threshold.lost_packets.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), at_threshold.lost_packets.items.len);

    var after_threshold = try ld.onAckReceived(.application, 2, 0, base.add(loss_delay + 1));
    defer after_threshold.acked_packets.deinit(allocator);
    defer after_threshold.lost_packets.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), after_threshold.lost_packets.items.len);
    try std.testing.expectEqual(@as(u64, 1), after_threshold.lost_packets.items[0].packet_number);
}

test "Packet number space isolation" {
    const allocator = std.testing.allocator;

    var ld = LossDetection.init(allocator);
    defer ld.deinit();

    const now = time_mod.Instant.now();

    // Send packets in different spaces
    try ld.onPacketSent(.initial, SentPacket.init(1, now, 1200, true));
    try ld.onPacketSent(.handshake, SentPacket.init(1, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(1, now, 1200, true));

    try std.testing.expectEqual(@as(usize, 1), ld.initial.sent_packets.items.len);
    try std.testing.expectEqual(@as(usize, 1), ld.handshake.sent_packets.items.len);
    try std.testing.expectEqual(@as(usize, 1), ld.application.sent_packets.items.len);

    // ACK in one space shouldn't affect others
    var ack_result = try ld.onAckReceived(.application, 1, 0, now);
    defer ack_result.acked_packets.deinit(allocator);
    defer ack_result.lost_packets.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), ld.initial.sent_packets.items.len);
    try std.testing.expectEqual(@as(usize, 1), ld.handshake.sent_packets.items.len);
    try std.testing.expectEqual(@as(usize, 0), ld.application.sent_packets.items.len);
}

test "send control lifecycle stays stable across mixed ACK and loss rounds" {
    const allocator = std.testing.allocator;

    var ld = LossDetection.init(allocator);
    defer ld.deinit();

    const now = time_mod.Instant.now();

    // Initial send burst.
    try ld.onPacketSent(.application, SentPacket.init(1, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(2, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(3, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(4, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(5, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(6, now, 1200, true));

    const acked_round1 = [_]types.PacketNumber{ 2, 4, 6 };
    var round1 = try ld.onAckReceivedWithPacketNumbers(.application, 6, 0, now, &acked_round1);
    defer round1.acked_packets.deinit(allocator);
    defer round1.lost_packets.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), round1.acked_packets.items.len);
    // Packet threshold declares packet 1 lost when largest_acked is 6.
    try std.testing.expectEqual(@as(usize, 1), round1.lost_packets.items.len);
    try std.testing.expectEqual(@as(u64, 1), round1.lost_packets.items[0].packet_number);

    // Remaining outstanding packets should be 3 and 5.
    try std.testing.expectEqual(@as(usize, 2), ld.application.sent_packets.items.len);

    var round2 = try ld.onAckReceived(.application, 5, 0, now);
    defer round2.acked_packets.deinit(allocator);
    defer round2.lost_packets.deinit(allocator);

    try std.testing.expect(round2.acked_packet != null);
    try std.testing.expectEqual(@as(?u64, 5), if (round2.acked_packet) |p| p.packet_number else null);
    try std.testing.expectEqual(@as(usize, 1), ld.application.sent_packets.items.len);
    try std.testing.expectEqual(@as(u64, 3), ld.application.sent_packets.items[0].packet_number);
}

test "ACK range ordering does not change final acknowledged set" {
    const allocator = std.testing.allocator;

    var ld_a = LossDetection.init(allocator);
    defer ld_a.deinit();

    var ld_b = LossDetection.init(allocator);
    defer ld_b.deinit();

    const now = time_mod.Instant.now();

    var pn: u64 = 1;
    while (pn <= 8) : (pn += 1) {
        const packet = SentPacket.init(pn, now, 1200, true);
        try ld_a.onPacketSent(.application, packet);
        try ld_b.onPacketSent(.application, packet);
    }

    const acked_ascending = [_]types.PacketNumber{ 2, 4, 6, 8 };
    const acked_descending = [_]types.PacketNumber{ 8, 6, 4, 2 };

    var res_a = try ld_a.onAckReceivedWithPacketNumbers(.application, 8, 0, now, &acked_ascending);
    defer res_a.acked_packets.deinit(allocator);
    defer res_a.lost_packets.deinit(allocator);

    var res_b = try ld_b.onAckReceivedWithPacketNumbers(.application, 8, 0, now, &acked_descending);
    defer res_b.acked_packets.deinit(allocator);
    defer res_b.lost_packets.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), res_a.acked_packets.items.len);
    try std.testing.expectEqual(@as(usize, 4), res_b.acked_packets.items.len);

    // Both flows should end with the same outstanding packets set: 5 and 7.
    try std.testing.expectEqual(@as(usize, 2), ld_a.application.sent_packets.items.len);
    try std.testing.expectEqual(@as(usize, 2), ld_b.application.sent_packets.items.len);

    var remaining_a = [_]u64{ ld_a.application.sent_packets.items[0].packet_number, ld_a.application.sent_packets.items[1].packet_number };
    var remaining_b = [_]u64{ ld_b.application.sent_packets.items[0].packet_number, ld_b.application.sent_packets.items[1].packet_number };
    std.mem.sort(u64, &remaining_a, {}, std.sort.asc(u64));
    std.mem.sort(u64, &remaining_b, {}, std.sort.asc(u64));

    try std.testing.expectEqualSlices(u64, &remaining_a, &remaining_b);
    try std.testing.expectEqualSlices(u64, &[_]u64{ 5, 7 }, &remaining_a);
}

test "ACK duplicate range list remains idempotent across repeated calls" {
    const allocator = std.testing.allocator;

    var ld = LossDetection.init(allocator);
    defer ld.deinit();

    const now = time_mod.Instant.now();

    try ld.onPacketSent(.application, SentPacket.init(1, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(2, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(3, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(4, now, 1200, true));

    const acked = [_]types.PacketNumber{ 2, 2, 2, 4, 4 };
    var first = try ld.onAckReceivedWithPacketNumbers(.application, 4, 0, now, &acked);
    defer first.acked_packets.deinit(allocator);
    defer first.lost_packets.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), first.acked_packets.items.len);
    try std.testing.expectEqual(@as(usize, 0), first.lost_packets.items.len);
    try std.testing.expectEqual(@as(usize, 2), ld.application.sent_packets.items.len);

    // Replaying the same ACK set should have no further effect.
    var replay = try ld.onAckReceivedWithPacketNumbers(.application, 4, 0, now, &acked);
    defer replay.acked_packets.deinit(allocator);
    defer replay.lost_packets.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), replay.acked_packets.items.len);
    try std.testing.expectEqual(@as(usize, 0), replay.lost_packets.items.len);
    try std.testing.expectEqual(@as(usize, 2), ld.application.sent_packets.items.len);
}

test "Mixed space ACK/loss processing does not bleed across spaces" {
    const allocator = std.testing.allocator;

    var ld = LossDetection.init(allocator);
    defer ld.deinit();

    const now = time_mod.Instant.now();

    // Seed each packet number space with independent packet histories.
    try ld.onPacketSent(.initial, SentPacket.init(0, now, 1200, true));
    try ld.onPacketSent(.initial, SentPacket.init(1, now, 1200, true));
    try ld.onPacketSent(.handshake, SentPacket.init(0, now, 1200, true));
    try ld.onPacketSent(.handshake, SentPacket.init(1, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(0, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(1, now, 1200, true));

    // ACK only Initial packet #1. This should affect only Initial space.
    var initial_ack = try ld.onAckReceived(.initial, 1, 0, now);
    defer initial_ack.acked_packets.deinit(allocator);
    defer initial_ack.lost_packets.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), initial_ack.acked_packets.items.len);
    try std.testing.expectEqual(@as(usize, 1), ld.initial.sent_packets.items.len);
    try std.testing.expectEqual(@as(usize, 2), ld.handshake.sent_packets.items.len);
    try std.testing.expectEqual(@as(usize, 2), ld.application.sent_packets.items.len);

    // ACK handshake packet #1; handshake threshold logic may mark #0 lost.
    var hs_ack = try ld.onAckReceived(.handshake, 1, 0, now);
    defer hs_ack.acked_packets.deinit(allocator);
    defer hs_ack.lost_packets.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), hs_ack.acked_packets.items.len);
    try std.testing.expectEqual(@as(usize, 1), ld.initial.sent_packets.items.len);
    try std.testing.expectEqual(@as(usize, 1), ld.handshake.sent_packets.items.len);
    try std.testing.expectEqual(@as(usize, 2), ld.application.sent_packets.items.len);
}

test "ACKing unsent packet number advances largest_acked and may declare threshold loss" {
    const allocator = std.testing.allocator;

    var ld = LossDetection.init(allocator);
    defer ld.deinit();

    const now = time_mod.Instant.now();
    try ld.onPacketSent(.application, SentPacket.init(1, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(2, now, 1200, true));

    const before_len = ld.application.sent_packets.items.len;

    var ack = try ld.onAckReceived(.application, 99, 0, now);
    defer ack.acked_packets.deinit(allocator);
    defer ack.lost_packets.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), ack.acked_packets.items.len);
    // With a far-future largest_acked, threshold loss will mark both packets lost.
    try std.testing.expectEqual(@as(usize, before_len), ack.lost_packets.items.len);
    try std.testing.expectEqual(@as(usize, 0), ld.application.sent_packets.items.len);
    try std.testing.expectEqual(@as(?u64, 99), ld.application.largest_acked);
}

test "maxObservedPacketNumber combines sent and acknowledged history" {
    const allocator = std.testing.allocator;

    var ld = LossDetection.init(allocator);
    defer ld.deinit();

    const now = time_mod.Instant.now();

    try std.testing.expect(ld.maxObservedPacketNumber(.application) == null);

    try ld.onPacketSent(.application, SentPacket.init(4, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(6, now, 1200, true));
    try std.testing.expectEqual(@as(?u64, 6), ld.maxObservedPacketNumber(.application));

    // ACK beyond sent set updates largest_acked and should become max-observed.
    var ack = try ld.onAckReceived(.application, 9, 0, now);
    defer ack.acked_packets.deinit(allocator);
    defer ack.lost_packets.deinit(allocator);

    try std.testing.expectEqual(@as(?u64, 9), ld.maxObservedPacketNumber(.application));
}

test "sent history drains deterministically under full ACK sweep" {
    const allocator = std.testing.allocator;

    var ld = LossDetection.init(allocator);
    defer ld.deinit();

    const now = time_mod.Instant.now();
    var pn: u64 = 0;
    while (pn < 6) : (pn += 1) {
        try ld.onPacketSent(.application, SentPacket.init(pn, now, 1200, true));
    }

    var acked = [_]types.PacketNumber{ 0, 1, 2, 3, 4, 5 };
    var ack = try ld.onAckReceivedWithPacketNumbers(.application, 5, 0, now, &acked);
    defer ack.acked_packets.deinit(allocator);
    defer ack.lost_packets.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 6), ack.acked_packets.items.len);
    try std.testing.expectEqual(@as(usize, 0), ld.application.sent_packets.items.len);
    try std.testing.expectEqual(@as(?u64, 5), ld.maxObservedPacketNumber(.application));
}

test "explicit ACK list can omit largest_acked packet" {
    const allocator = std.testing.allocator;

    var ld = LossDetection.init(allocator);
    defer ld.deinit();

    const now = time_mod.Instant.now();

    try ld.onPacketSent(.application, SentPacket.init(1, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(2, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(3, now, 1200, true));

    // largest_acked is 3, but explicit set only includes packet 2.
    const acked_set = [_]types.PacketNumber{2};
    var ack = try ld.onAckReceivedWithPacketNumbers(.application, 3, 0, now, &acked_set);
    defer ack.acked_packets.deinit(allocator);
    defer ack.lost_packets.deinit(allocator);

    try std.testing.expect(ack.acked_packet == null);
    try std.testing.expectEqual(@as(usize, 1), ack.acked_packets.items.len);
    try std.testing.expectEqual(@as(u64, 2), ack.acked_packets.items[0].packet_number);
    // Space largest_acked tracks explicitly acknowledged packet numbers.
    try std.testing.expectEqual(@as(?u64, 2), ld.application.largest_acked);
}

test "empty explicit ACK list is a no-op for sent history" {
    const allocator = std.testing.allocator;

    var ld = LossDetection.init(allocator);
    defer ld.deinit();

    const now = time_mod.Instant.now();
    try ld.onPacketSent(.application, SentPacket.init(1, now, 1200, true));
    try ld.onPacketSent(.application, SentPacket.init(2, now, 1200, true));

    var ack = try ld.onAckReceivedWithPacketNumbers(.application, 2, 0, now, &.{});
    defer ack.acked_packets.deinit(allocator);
    defer ack.lost_packets.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), ack.acked_packets.items.len);
    try std.testing.expectEqual(@as(usize, 0), ack.lost_packets.items.len);
    try std.testing.expectEqual(@as(usize, 2), ld.application.sent_packets.items.len);
}
pub const AckResult = struct {
    acked_packet: ?SentPacket,
    acked_packets: std.ArrayList(SentPacket),
    lost_packets: std.ArrayList(SentPacket),
};
