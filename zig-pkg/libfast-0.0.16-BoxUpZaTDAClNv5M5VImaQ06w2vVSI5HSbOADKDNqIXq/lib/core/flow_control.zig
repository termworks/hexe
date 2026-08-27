const std = @import("std");

/// Flow control for QUIC streams and connections (RFC 9000 Section 4)
///
/// Implements both stream-level and connection-level flow control using
/// credit-based mechanism with MAX_DATA and MAX_STREAM_DATA frames.

pub const FlowControlError = error{
    FlowControlViolation,
    StreamBlocked,
    ConnectionBlocked,
    InvalidOffset,
};

/// Flow controller for a single entity (stream or connection)
pub const FlowController = struct {
    /// Maximum data we're willing to receive
    max_data: u64,

    /// Data we've actually received
    received_data: u64,

    /// Data we've consumed (application read)
    consumed_data: u64,

    /// Maximum data peer can send
    send_max: u64,

    /// Data we've sent
    sent_data: u64,

    /// Window size for auto-updates
    window_size: u64,

    /// Initialize flow controller
    pub fn init(initial_max_data: u64, initial_send_max: u64) FlowController {
        return FlowController{
            .max_data = initial_max_data,
            .received_data = 0,
            .consumed_data = 0,
            .send_max = initial_send_max,
            .sent_data = 0,
            .window_size = initial_max_data / 2,
        };
    }

    /// Check if we can receive data at the given offset
    pub fn canReceive(self: *FlowController, offset: u64, length: u64) bool {
        const new_offset = offset + length;
        return new_offset <= self.max_data;
    }

    /// Record received data
    pub fn addReceived(self: *FlowController, offset: u64, length: u64) FlowControlError!void {
        const new_offset = offset + length;
        if (new_offset > self.max_data) {
            return error.FlowControlViolation;
        }

        if (new_offset > self.received_data) {
            self.received_data = new_offset;
        }
    }

    /// Record consumed data (application read)
    pub fn addConsumed(self: *FlowController, length: u64) void {
        self.consumed_data += length;
    }

    /// Check if we should send a MAX_DATA/MAX_STREAM_DATA update
    pub fn shouldUpdateMaxData(self: *FlowController) bool {
        const available = self.max_data - self.consumed_data;
        return available < self.window_size;
    }

    /// Get new MAX_DATA value for update
    pub fn getUpdatedMaxData(self: *FlowController) u64 {
        return self.consumed_data + self.window_size * 2;
    }

    /// Update MAX_DATA limit
    pub fn updateMaxData(self: *FlowController, new_max: u64) void {
        if (new_max > self.max_data) {
            self.max_data = new_max;
        }
    }

    /// Check if we can send data
    pub fn canSend(self: *FlowController, length: u64) bool {
        return self.sent_data + length <= self.send_max;
    }

    /// Record sent data
    pub fn addSent(self: *FlowController, length: u64) FlowControlError!void {
        const new_sent = self.sent_data + length;
        if (new_sent > self.send_max) {
            return error.StreamBlocked;
        }
        self.sent_data = new_sent;
    }

    /// Update peer's MAX_DATA (we can send more)
    pub fn updateSendMax(self: *FlowController, new_max: u64) void {
        if (new_max > self.send_max) {
            self.send_max = new_max;
        }
    }

    /// Get available send credit
    pub fn availableSendCredit(self: *FlowController) u64 {
        if (self.sent_data >= self.send_max) {
            return 0;
        }
        return self.send_max - self.sent_data;
    }

    /// Check if blocked
    pub fn isBlocked(self: *FlowController) bool {
        return self.sent_data >= self.send_max;
    }
};

/// Connection-level flow controller
pub const ConnectionFlowControl = struct {
    controller: FlowController,

    pub fn init(initial_max_data: u64, initial_send_max: u64) ConnectionFlowControl {
        return ConnectionFlowControl{
            .controller = FlowController.init(initial_max_data, initial_send_max),
        };
    }

    pub fn canReceive(self: *ConnectionFlowControl, length: u64) bool {
        return self.controller.canReceive(self.controller.received_data, length);
    }

    pub fn addReceived(self: *ConnectionFlowControl, length: u64) FlowControlError!void {
        try self.controller.addReceived(self.controller.received_data, length);
    }

    pub fn addConsumed(self: *ConnectionFlowControl, length: u64) void {
        self.controller.addConsumed(length);
    }

    pub fn canSend(self: *ConnectionFlowControl, length: u64) bool {
        return self.controller.canSend(length);
    }

    pub fn addSent(self: *ConnectionFlowControl, length: u64) FlowControlError!void {
        if (!self.canSend(length)) {
            return error.ConnectionBlocked;
        }
        try self.controller.addSent(length);
    }

    pub fn shouldUpdateMaxData(self: *ConnectionFlowControl) bool {
        return self.controller.shouldUpdateMaxData();
    }

    pub fn getUpdatedMaxData(self: *ConnectionFlowControl) u64 {
        return self.controller.getUpdatedMaxData();
    }

    pub fn updateMaxData(self: *ConnectionFlowControl, new_max: u64) void {
        self.controller.updateMaxData(new_max);
    }

    pub fn updateSendMax(self: *ConnectionFlowControl, new_max: u64) void {
        self.controller.updateSendMax(new_max);
    }

    pub fn availableSendCredit(self: *ConnectionFlowControl) u64 {
        return self.controller.availableSendCredit();
    }
};

/// Stream-level flow controller
pub const StreamFlowControl = struct {
    controller: FlowController,

    pub fn init(initial_max_data: u64, initial_send_max: u64) StreamFlowControl {
        return StreamFlowControl{
            .controller = FlowController.init(initial_max_data, initial_send_max),
        };
    }

    pub fn canReceive(self: *StreamFlowControl, offset: u64, length: u64) bool {
        return self.controller.canReceive(offset, length);
    }

    pub fn addReceived(self: *StreamFlowControl, offset: u64, length: u64) FlowControlError!void {
        try self.controller.addReceived(offset, length);
    }

    pub fn addConsumed(self: *StreamFlowControl, length: u64) void {
        self.controller.addConsumed(length);
    }

    pub fn canSend(self: *StreamFlowControl, length: u64) bool {
        return self.controller.canSend(length);
    }

    pub fn addSent(self: *StreamFlowControl, length: u64) FlowControlError!void {
        if (!self.canSend(length)) {
            return error.StreamBlocked;
        }
        try self.controller.addSent(length);
    }

    pub fn shouldUpdateMaxData(self: *StreamFlowControl) bool {
        return self.controller.shouldUpdateMaxData();
    }

    pub fn getUpdatedMaxData(self: *StreamFlowControl) u64 {
        return self.controller.getUpdatedMaxData();
    }

    pub fn updateMaxStreamData(self: *StreamFlowControl, new_max: u64) void {
        self.controller.updateMaxData(new_max);
    }

    pub fn updateSendMax(self: *StreamFlowControl, new_max: u64) void {
        self.controller.updateSendMax(new_max);
    }

    pub fn availableSendCredit(self: *StreamFlowControl) u64 {
        return self.controller.availableSendCredit();
    }

    pub fn isBlocked(self: *StreamFlowControl) bool {
        return self.controller.isBlocked();
    }
};

// Tests

test "Flow controller initialization" {
    const fc = FlowController.init(1000, 500);

    try std.testing.expectEqual(@as(u64, 1000), fc.max_data);
    try std.testing.expectEqual(@as(u64, 500), fc.send_max);
    try std.testing.expectEqual(@as(u64, 0), fc.received_data);
    try std.testing.expectEqual(@as(u64, 0), fc.sent_data);
}

test "Flow controller receive data" {
    var fc = FlowController.init(1000, 500);

    // Receive 100 bytes at offset 0
    try fc.addReceived(0, 100);
    try std.testing.expectEqual(@as(u64, 100), fc.received_data);

    // Receive 50 bytes at offset 100
    try fc.addReceived(100, 50);
    try std.testing.expectEqual(@as(u64, 150), fc.received_data);

    // Attempt to exceed limit
    const result = fc.addReceived(150, 900);
    try std.testing.expectError(error.FlowControlViolation, result);
}

test "Flow controller send data" {
    var fc = FlowController.init(1000, 500);

    // Send 100 bytes
    try fc.addSent(100);
    try std.testing.expectEqual(@as(u64, 100), fc.sent_data);

    // Can send more
    try std.testing.expect(fc.canSend(200));

    // Send 400 bytes (total 500)
    try fc.addSent(400);
    try std.testing.expectEqual(@as(u64, 500), fc.sent_data);

    // Blocked now
    try std.testing.expect(fc.isBlocked());
    try std.testing.expect(!fc.canSend(1));

    // Attempt to exceed limit
    const result = fc.addSent(1);
    try std.testing.expectError(error.StreamBlocked, result);
}

test "Flow controller MAX_DATA update" {
    var fc = FlowController.init(1000, 500);

    // Receive and consume data
    try fc.addReceived(0, 600);
    fc.addConsumed(600);

    // Should need update (consumed > window)
    try std.testing.expect(fc.shouldUpdateMaxData());

    // Get new MAX_DATA
    const new_max = fc.getUpdatedMaxData();
    try std.testing.expect(new_max > fc.max_data);

    // Update it
    fc.updateMaxData(new_max);
    try std.testing.expectEqual(new_max, fc.max_data);
}

test "Flow controller send MAX update" {
    var fc = FlowController.init(1000, 500);

    // Initially can send 500 bytes
    try std.testing.expectEqual(@as(u64, 500), fc.availableSendCredit());

    // Send 300 bytes
    try fc.addSent(300);
    try std.testing.expectEqual(@as(u64, 200), fc.availableSendCredit());

    // Receive MAX_STREAM_DATA update from peer
    fc.updateSendMax(1000);
    try std.testing.expectEqual(@as(u64, 700), fc.availableSendCredit());
}

test "Connection flow control" {
    var conn_fc = ConnectionFlowControl.init(10000, 5000);

    // Can send
    try std.testing.expect(conn_fc.canSend(1000));

    // Send data
    try conn_fc.addSent(1000);

    // Receive data
    try conn_fc.addReceived(500);

    // Consume data
    conn_fc.addConsumed(500);

    // Available credit
    const credit = conn_fc.availableSendCredit();
    try std.testing.expectEqual(@as(u64, 4000), credit);
}

test "Stream flow control with offset" {
    var stream_fc = StreamFlowControl.init(1000, 500);

    // Receive at offset 0
    try std.testing.expect(stream_fc.canReceive(0, 100));
    try stream_fc.addReceived(0, 100);

    // Receive at offset 100
    try std.testing.expect(stream_fc.canReceive(100, 200));
    try stream_fc.addReceived(100, 200);

    // Out of order receive at offset 50 (should not increase received_data beyond 300)
    try stream_fc.addReceived(50, 50);
    try std.testing.expectEqual(@as(u64, 300), stream_fc.controller.received_data);

    // Cannot receive beyond limit
    try std.testing.expect(!stream_fc.canReceive(900, 200));
}

test "Flow control blocking and unblocking" {
    var fc = FlowController.init(1000, 100);

    // Fill send window
    try fc.addSent(100);
    try std.testing.expect(fc.isBlocked());

    // Update send max
    fc.updateSendMax(200);
    try std.testing.expect(!fc.isBlocked());

    // Can send again
    try std.testing.expect(fc.canSend(100));
}
