const std = @import("std");

/// Congestion control for QUIC (RFC 9002)
///
/// Implements NewReno congestion control algorithm with slow start
/// and congestion avoidance.
pub const CongestionError = error{
    InvalidCongestionWindow,
    InvalidSlowStartThreshold,
};

/// Congestion control state
pub const CongestionState = enum {
    /// Slow start phase
    slow_start,

    /// Congestion avoidance phase
    congestion_avoidance,

    /// Recovery phase (after packet loss)
    recovery,

    pub fn toString(self: CongestionState) []const u8 {
        return switch (self) {
            .slow_start => "SlowStart",
            .congestion_avoidance => "CongestionAvoidance",
            .recovery => "Recovery",
        };
    }
};

/// Congestion controller
pub const CongestionController = struct {
    /// Current congestion window (bytes)
    congestion_window: u64,

    /// Bytes in flight
    bytes_in_flight: u64,

    /// Slow start threshold (bytes)
    ssthresh: u64,

    /// Maximum datagram size (bytes)
    max_datagram_size: u64,

    /// Current state
    state: CongestionState,

    /// Number of ACKed bytes in current window (for congestion avoidance)
    acked_bytes_in_window: u64,

    /// End of recovery period (packet number)
    recovery_end_packet: ?u64,

    /// Initialize congestion controller
    pub fn init(max_datagram_size: u64) CongestionController {
        // RFC 9002: Initial window is 10 * max_datagram_size
        const initial_window = 10 * max_datagram_size;

        return CongestionController{
            .congestion_window = initial_window,
            .bytes_in_flight = 0,
            .ssthresh = std.math.maxInt(u64),
            .max_datagram_size = max_datagram_size,
            .state = .slow_start,
            .acked_bytes_in_window = 0,
            .recovery_end_packet = null,
        };
    }

    /// Check if we can send more data
    pub fn canSend(self: *CongestionController) bool {
        return self.bytes_in_flight < self.congestion_window;
    }

    /// Get available congestion window
    pub fn availableWindow(self: *CongestionController) u64 {
        if (self.bytes_in_flight >= self.congestion_window) {
            return 0;
        }
        return self.congestion_window - self.bytes_in_flight;
    }

    /// Record packet sent
    pub fn onPacketSent(self: *CongestionController, bytes: u64) void {
        self.bytes_in_flight += bytes;
    }

    /// Process ACK for packets
    pub fn onPacketAcked(
        self: *CongestionController,
        bytes_acked: u64,
        packet_number: u64,
    ) void {
        // Reduce bytes in flight
        self.bytes_in_flight -|= bytes_acked;

        // Don't increase window if we're in recovery and this ACK is for
        // packets sent before entering recovery
        if (self.recovery_end_packet) |end_pn| {
            if (packet_number <= end_pn) {
                return;
            }
            // We've exited recovery
            self.recovery_end_packet = null;
            self.state = if (self.congestion_window < self.ssthresh)
                .slow_start
            else
                .congestion_avoidance;
        }

        switch (self.state) {
            .slow_start => {
                // In slow start, increase cwnd by bytes_acked
                self.congestion_window += bytes_acked;

                // Check if we've exceeded ssthresh
                if (self.congestion_window >= self.ssthresh) {
                    self.state = .congestion_avoidance;
                    self.acked_bytes_in_window = 0;
                }
            },
            .congestion_avoidance => {
                // In congestion avoidance, increase cwnd by max_datagram_size
                // per RTT (approximated by tracking acked bytes)
                self.acked_bytes_in_window += bytes_acked;

                if (self.acked_bytes_in_window >= self.congestion_window) {
                    self.congestion_window += self.max_datagram_size;
                    self.acked_bytes_in_window = 0;
                }
            },
            .recovery => {
                // Window is not increased in recovery
            },
        }
    }

    /// Handle packet loss
    pub fn onPacketsLost(
        self: *CongestionController,
        bytes_lost: u64,
        largest_lost_packet: u64,
    ) void {
        // Reduce bytes in flight
        self.bytes_in_flight -|= bytes_lost;

        // Don't react to losses during recovery
        if (self.recovery_end_packet) |end_pn| {
            if (largest_lost_packet <= end_pn) {
                return;
            }
        }

        // Enter recovery
        self.state = .recovery;
        self.recovery_end_packet = largest_lost_packet;

        // Reduce ssthresh to half of current window (RFC 9002)
        self.ssthresh = self.congestion_window / 2;

        // Ensure ssthresh is at least 2 * max_datagram_size
        const min_ssthresh = 2 * self.max_datagram_size;
        if (self.ssthresh < min_ssthresh) {
            self.ssthresh = min_ssthresh;
        }

        // Reduce congestion window
        self.congestion_window = self.ssthresh;
        self.acked_bytes_in_window = 0;
    }

    /// Handle persistent congestion (multiple RTOs)
    pub fn onPersistentCongestion(self: *CongestionController) void {
        // Reset to minimal window
        self.congestion_window = 2 * self.max_datagram_size;
        self.ssthresh = std.math.maxInt(u64);
        self.state = .slow_start;
        self.acked_bytes_in_window = 0;
        self.recovery_end_packet = null;
    }

    /// Get current state
    pub fn getState(self: *CongestionController) CongestionState {
        return self.state;
    }

    /// Get congestion window
    pub fn getCongestionWindow(self: *CongestionController) u64 {
        return self.congestion_window;
    }

    /// Get bytes in flight
    pub fn getBytesInFlight(self: *CongestionController) u64 {
        return self.bytes_in_flight;
    }
};

// Tests

test "Congestion controller initialization" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    // Initial window should be 10 * MTU
    try std.testing.expectEqual(@as(u64, 10 * mtu), cc.congestion_window);
    try std.testing.expectEqual(@as(u64, 0), cc.bytes_in_flight);
    try std.testing.expectEqual(CongestionState.slow_start, cc.state);
    try std.testing.expect(cc.canSend());
}

test "Packet sent updates bytes in flight" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    cc.onPacketSent(1000);
    try std.testing.expectEqual(@as(u64, 1000), cc.bytes_in_flight);

    cc.onPacketSent(500);
    try std.testing.expectEqual(@as(u64, 1500), cc.bytes_in_flight);
}

test "Available window calculation" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    // Initial window is 12000
    try std.testing.expectEqual(@as(u64, 12000), cc.availableWindow());

    cc.onPacketSent(5000);
    try std.testing.expectEqual(@as(u64, 7000), cc.availableWindow());

    cc.onPacketSent(7000);
    try std.testing.expectEqual(@as(u64, 0), cc.availableWindow());
    try std.testing.expect(!cc.canSend());
}

test "Slow start window growth" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    const initial_window = cc.congestion_window;

    // ACK 1000 bytes
    cc.onPacketAcked(1000, 1);

    // In slow start, window increases by bytes_acked
    try std.testing.expectEqual(initial_window + 1000, cc.congestion_window);
    try std.testing.expectEqual(CongestionState.slow_start, cc.state);
}

test "Transition to congestion avoidance" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    // Set ssthresh below current window
    cc.ssthresh = 15000;

    // ACK enough to reach ssthresh
    cc.onPacketAcked(5000, 1);

    // Should transition to congestion avoidance
    try std.testing.expectEqual(CongestionState.congestion_avoidance, cc.state);
}

test "Congestion avoidance window growth" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    // Put into congestion avoidance
    cc.state = .congestion_avoidance;
    cc.ssthresh = cc.congestion_window;
    const window_before = cc.congestion_window;

    // ACK entire window worth of bytes
    cc.onPacketAcked(cc.congestion_window, 1);

    // Window should grow by 1 MTU
    try std.testing.expectEqual(window_before + mtu, cc.congestion_window);
}

test "Packet loss triggers recovery" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    const window_before = cc.congestion_window;

    // Lose some packets
    cc.onPacketsLost(1000, 5);

    // Should enter recovery
    try std.testing.expectEqual(CongestionState.recovery, cc.state);

    // Window should be halved
    try std.testing.expectEqual(window_before / 2, cc.congestion_window);

    // ssthresh should be set
    try std.testing.expectEqual(window_before / 2, cc.ssthresh);
}

test "Recovery prevents window growth" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    // Trigger loss
    cc.onPacketsLost(1000, 5);
    const window_during_recovery = cc.congestion_window;

    // ACK packets sent before entering recovery
    cc.onPacketAcked(1000, 3);

    // Window should not grow
    try std.testing.expectEqual(window_during_recovery, cc.congestion_window);
}

test "Exit from recovery" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    // Trigger loss at packet 5
    cc.onPacketsLost(1000, 5);
    try std.testing.expectEqual(CongestionState.recovery, cc.state);

    // ACK packet sent after entering recovery
    cc.onPacketAcked(1000, 10);

    // Should exit recovery
    try std.testing.expect(cc.state != .recovery);
    try std.testing.expect(cc.recovery_end_packet == null);
}

test "Persistent congestion reset" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    // Grow the window
    cc.onPacketAcked(10000, 1);

    // Trigger persistent congestion
    cc.onPersistentCongestion();

    // Should reset to minimal window
    try std.testing.expectEqual(@as(u64, 2 * mtu), cc.congestion_window);
    try std.testing.expectEqual(CongestionState.slow_start, cc.state);
}

test "Minimum ssthresh enforcement" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    // Set very small window
    cc.congestion_window = 1000;

    // Trigger loss
    cc.onPacketsLost(500, 1);

    // ssthresh should be at least 2 * MTU
    try std.testing.expect(cc.ssthresh >= 2 * mtu);
}

test "Congestion lifecycle remains stable across recovery and reset" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    // Start with inflight data and grow in slow start.
    cc.onPacketSent(6000);
    cc.onPacketSent(3000);
    try std.testing.expectEqual(@as(u64, 9000), cc.bytes_in_flight);

    cc.onPacketAcked(3000, 10);
    try std.testing.expectEqual(@as(u64, 6000), cc.bytes_in_flight);
    try std.testing.expectEqual(@as(u64, 15000), cc.congestion_window);
    try std.testing.expectEqual(CongestionState.slow_start, cc.state);

    // Enter recovery from loss.
    cc.onPacketsLost(2000, 12);
    try std.testing.expectEqual(@as(u64, 4000), cc.bytes_in_flight);
    try std.testing.expectEqual(CongestionState.recovery, cc.state);
    try std.testing.expectEqual(@as(?u64, 12), cc.recovery_end_packet);
    try std.testing.expectEqual(@as(u64, 7500), cc.ssthresh);
    try std.testing.expectEqual(@as(u64, 7500), cc.congestion_window);

    // Loss with packet number inside current recovery does not re-enter recovery.
    cc.onPacketsLost(500, 11);
    try std.testing.expectEqual(CongestionState.recovery, cc.state);
    try std.testing.expectEqual(@as(?u64, 12), cc.recovery_end_packet);
    try std.testing.expectEqual(@as(u64, 3500), cc.bytes_in_flight);

    // ACK up to recovery end does not grow cwnd.
    cc.onPacketAcked(1000, 12);
    try std.testing.expectEqual(@as(u64, 2500), cc.bytes_in_flight);
    try std.testing.expectEqual(CongestionState.recovery, cc.state);
    try std.testing.expectEqual(@as(u64, 7500), cc.congestion_window);

    // ACK after recovery end exits to congestion avoidance.
    cc.onPacketAcked(1000, 13);
    try std.testing.expectEqual(@as(u64, 1500), cc.bytes_in_flight);
    try std.testing.expectEqual(CongestionState.congestion_avoidance, cc.state);
    try std.testing.expectEqual(@as(?u64, null), cc.recovery_end_packet);

    // In congestion avoidance, enough ACKed bytes grow cwnd by one MTU.
    cc.onPacketAcked(7000, 14);
    try std.testing.expectEqual(@as(u64, 0), cc.bytes_in_flight);
    try std.testing.expectEqual(@as(u64, 8700), cc.congestion_window);

    // Persistent congestion resets controller to minimal safe state.
    cc.onPersistentCongestion();
    try std.testing.expectEqual(@as(u64, 2 * mtu), cc.congestion_window);
    try std.testing.expectEqual(CongestionState.slow_start, cc.state);
    try std.testing.expectEqual(@as(?u64, null), cc.recovery_end_packet);

    // After reset, send budget reflects minimal cwnd.
    cc.onPacketSent(2000);
    try std.testing.expect(cc.canSend());
    try std.testing.expectEqual(@as(u64, 400), cc.availableWindow());
    cc.onPacketSent(500);
    try std.testing.expect(!cc.canSend());
    try std.testing.expectEqual(@as(u64, 0), cc.availableWindow());
}

test "Congestion avoidance growth is single-step per ACK event" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    cc.state = .congestion_avoidance;
    cc.ssthresh = cc.congestion_window;
    cc.acked_bytes_in_window = 0;

    const cwnd0 = cc.congestion_window;

    cc.onPacketAcked(4000, 1);
    try std.testing.expectEqual(cwnd0, cc.congestion_window);
    try std.testing.expectEqual(@as(u64, 4000), cc.acked_bytes_in_window);

    cc.onPacketAcked(7000, 2);
    try std.testing.expectEqual(cwnd0, cc.congestion_window);
    try std.testing.expectEqual(@as(u64, 11000), cc.acked_bytes_in_window);

    cc.onPacketAcked(1000, 3);
    try std.testing.expectEqual(cwnd0 + mtu, cc.congestion_window);
    try std.testing.expectEqual(@as(u64, 0), cc.acked_bytes_in_window);

    const cwnd1 = cc.congestion_window;
    cc.onPacketAcked(24000, 4);
    try std.testing.expectEqual(cwnd1 + mtu, cc.congestion_window);
    try std.testing.expectEqual(@as(u64, 0), cc.acked_bytes_in_window);
}

test "Newer loss packet starts new recovery epoch" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    // Grow cwnd before losses so halving effects are visible.
    cc.onPacketAcked(12000, 1);
    try std.testing.expectEqual(@as(u64, 24000), cc.congestion_window);

    // First recovery epoch at packet 20.
    cc.onPacketsLost(0, 20);
    try std.testing.expectEqual(CongestionState.recovery, cc.state);
    try std.testing.expectEqual(@as(?u64, 20), cc.recovery_end_packet);
    try std.testing.expectEqual(@as(u64, 12000), cc.congestion_window);

    // Same/older losses are ignored during recovery.
    cc.onPacketsLost(0, 20);
    try std.testing.expectEqual(@as(?u64, 20), cc.recovery_end_packet);
    try std.testing.expectEqual(@as(u64, 12000), cc.congestion_window);

    // Newer loss packet starts a new recovery epoch and halves again.
    cc.onPacketsLost(0, 25);
    try std.testing.expectEqual(CongestionState.recovery, cc.state);
    try std.testing.expectEqual(@as(?u64, 25), cc.recovery_end_packet);
    try std.testing.expectEqual(@as(u64, 6000), cc.congestion_window);
    try std.testing.expectEqual(@as(u64, 6000), cc.ssthresh);
}

test "Congestion accounting saturates bytes_in_flight on over-ack and over-loss" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    cc.onPacketSent(1500);
    try std.testing.expectEqual(@as(u64, 1500), cc.bytes_in_flight);

    // ACK more than in-flight should saturate at zero.
    cc.onPacketAcked(5000, 1);
    try std.testing.expectEqual(@as(u64, 0), cc.bytes_in_flight);

    cc.onPacketSent(1000);
    try std.testing.expectEqual(@as(u64, 1000), cc.bytes_in_flight);

    // Loss accounting also saturates at zero.
    cc.onPacketsLost(9000, 2);
    try std.testing.expectEqual(@as(u64, 0), cc.bytes_in_flight);

    // Minimum threshold enforcement still holds after saturation path.
    try std.testing.expect(cc.ssthresh >= 2 * mtu);
}

test "Recovery exit state selects slow start when cwnd below ssthresh" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    // Enter recovery and then make cwnd smaller than ssthresh before exit.
    cc.onPacketsLost(0, 10);
    try std.testing.expectEqual(CongestionState.recovery, cc.state);

    cc.congestion_window = 4000;
    cc.ssthresh = 6000;

    // ACK after recovery_end_packet exits recovery.
    cc.onPacketAcked(0, 11);
    try std.testing.expectEqual(CongestionState.slow_start, cc.state);
    try std.testing.expectEqual(@as(?u64, null), cc.recovery_end_packet);
}

test "Recovery exit state selects congestion avoidance when cwnd reaches ssthresh" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    cc.onPacketsLost(0, 20);
    try std.testing.expectEqual(CongestionState.recovery, cc.state);

    cc.congestion_window = 7000;
    cc.ssthresh = 7000;

    cc.onPacketAcked(0, 21);
    try std.testing.expectEqual(CongestionState.congestion_avoidance, cc.state);
    try std.testing.expectEqual(@as(?u64, null), cc.recovery_end_packet);
}

test "Available window saturates correctly around boundary" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    const cwnd = cc.congestion_window;
    cc.onPacketSent(cwnd - 1);
    try std.testing.expect(cc.canSend());
    try std.testing.expectEqual(@as(u64, 1), cc.availableWindow());

    cc.onPacketSent(1);
    try std.testing.expect(!cc.canSend());
    try std.testing.expectEqual(@as(u64, 0), cc.availableWindow());

    // Over-send still reports zero available window.
    cc.onPacketSent(100);
    try std.testing.expect(!cc.canSend());
    try std.testing.expectEqual(@as(u64, 0), cc.availableWindow());
}

test "Congestion avoidance carries residual acked bytes across ACK events" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    cc.state = .congestion_avoidance;
    cc.ssthresh = cc.congestion_window;
    cc.acked_bytes_in_window = 0;

    const cwnd0 = cc.congestion_window;

    // First partial ACK does not grow cwnd yet.
    cc.onPacketAcked(3000, 1);
    try std.testing.expectEqual(cwnd0, cc.congestion_window);
    try std.testing.expectEqual(@as(u64, 3000), cc.acked_bytes_in_window);

    // Second partial ACK still below cwnd.
    cc.onPacketAcked(4000, 2);
    try std.testing.expectEqual(cwnd0, cc.congestion_window);
    try std.testing.expectEqual(@as(u64, 7000), cc.acked_bytes_in_window);

    // Crossing cwnd threshold increases by one MTU and resets accumulator.
    cc.onPacketAcked(cwnd0 - 7000, 3);
    try std.testing.expectEqual(cwnd0 + mtu, cc.congestion_window);
    try std.testing.expectEqual(@as(u64, 0), cc.acked_bytes_in_window);
}

test "Persistent congestion clears recovery and ack accounting state" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    cc.onPacketSent(5000);
    cc.onPacketsLost(1000, 9);
    try std.testing.expectEqual(CongestionState.recovery, cc.state);
    try std.testing.expect(cc.recovery_end_packet != null);

    cc.state = .congestion_avoidance;
    cc.acked_bytes_in_window = 9999;

    cc.onPersistentCongestion();

    try std.testing.expectEqual(CongestionState.slow_start, cc.state);
    try std.testing.expectEqual(@as(?u64, null), cc.recovery_end_packet);
    try std.testing.expectEqual(@as(u64, 0), cc.acked_bytes_in_window);
    try std.testing.expectEqual(@as(u64, 2 * mtu), cc.congestion_window);
}

test "Congestion window floor is maintained across repeated loss epochs" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    // Drive cwnd down through repeated recovery epochs.
    var pn: u64 = 1;
    while (pn <= 20) : (pn += 1) {
        cc.onPacketsLost(0, pn);
    }

    try std.testing.expect(cc.congestion_window >= 2 * mtu);
    try std.testing.expect(cc.ssthresh >= 2 * mtu);
}

test "ACK after persistent congestion re-enters slow start growth" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    cc.onPersistentCongestion();
    try std.testing.expectEqual(CongestionState.slow_start, cc.state);
    const cwnd0 = cc.congestion_window;

    // Slow start should add bytes_acked directly.
    cc.onPacketAcked(1500, 1);
    try std.testing.expectEqual(cwnd0 + 1500, cc.congestion_window);
    try std.testing.expectEqual(CongestionState.slow_start, cc.state);
}

test "Recovery ACK gate blocks growth until packet number passes recovery end" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    // Enter recovery with end packet set to 30.
    cc.onPacketAcked(6000, 1);
    cc.onPacketsLost(1000, 30);
    try std.testing.expectEqual(CongestionState.recovery, cc.state);
    const cwnd_recovery = cc.congestion_window;

    // ACK at/under recovery end should not grow cwnd.
    cc.onPacketAcked(2000, 29);
    try std.testing.expectEqual(cwnd_recovery, cc.congestion_window);
    try std.testing.expectEqual(CongestionState.recovery, cc.state);

    cc.onPacketAcked(2000, 30);
    try std.testing.expectEqual(cwnd_recovery, cc.congestion_window);
    try std.testing.expectEqual(CongestionState.recovery, cc.state);

    // First ACK above recovery end exits recovery and can grow again.
    cc.onPacketAcked(2000, 31);
    try std.testing.expect(cc.state != .recovery);
    try std.testing.expect(cc.congestion_window >= cwnd_recovery);
}

test "Persistent congestion reset is idempotent" {
    const mtu = 1200;
    var cc = CongestionController.init(mtu);

    cc.onPacketAcked(20000, 1);
    cc.onPacketsLost(1000, 10);

    cc.onPersistentCongestion();
    const cwnd_after_first = cc.congestion_window;
    const state_after_first = cc.state;
    const ssthresh_after_first = cc.ssthresh;

    cc.onPersistentCongestion();
    try std.testing.expectEqual(cwnd_after_first, cc.congestion_window);
    try std.testing.expectEqual(state_after_first, cc.state);
    try std.testing.expectEqual(ssthresh_after_first, cc.ssthresh);
    try std.testing.expectEqual(@as(u64, 2 * mtu), cc.congestion_window);
}
