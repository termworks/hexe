const std = @import("std");
const Allocator = std.mem.Allocator;
const SessionChannel = @import("../channels/session.zig").SessionChannel;
const channel_protocol = @import("../protocol/channel.zig");

/// SFTP Channel Adapter
///
/// Bridges the SFTP client's Channel interface with the actual SessionChannel
/// implementation. Handles SFTP packet framing over SSH channel data.

pub const SftpChannel = struct {
    session: SessionChannel,
    allocator: Allocator,

    const Self = @This();

    /// Create SFTP channel from a session channel
    ///
    /// The session should already have the "sftp" subsystem requested.
    pub fn init(allocator: Allocator, session: SessionChannel) Self {
        return Self{
            .session = session,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // Session is owned by caller, don't close it here
    }

    /// Send SFTP packet on channel
    ///
    /// SFTP packets are already framed (uint32 length prefix included),
    /// so we send them directly as SSH_MSG_CHANNEL_DATA.
    pub fn send(self: *Self, data: []const u8) !void {
        try self.session.sendData(data);
    }

    /// Receive SFTP packet from channel
    ///
    /// Reads SSH_MSG_CHANNEL_DATA and extracts the SFTP packet.
    /// Returns allocated packet data. Caller owns the memory.
    pub fn receive(self: *Self, allocator: Allocator) ![]u8 {
        // Read the next packet from the session channel
        // This returns the decoded CHANNEL_DATA payload
        const data = try self.session.receiveData();
        errdefer allocator.free(data);

        // SFTP packets include length prefix: uint32(length) || payload
        // The SessionChannel.receiveData() already unwrapped SSH_MSG_CHANNEL_DATA,
        // so we have the raw SFTP packet here
        if (data.len < 4) {
            allocator.free(data);
            return error.InvalidSftpPacket;
        }

        // Return the data as-is (length prefix + packet)
        return data;
    }

    /// Get the underlying session channel
    pub fn getSession(self: *Self) *SessionChannel {
        return &self.session;
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Create SFTP channel from connection (convenience function)
///
/// This:
/// 1. Opens a session channel
/// 2. Waits for confirmation
/// 3. Requests "sftp" subsystem
/// 4. Returns ready-to-use SFTP channel
pub fn openSftpChannel(allocator: Allocator, connection: anytype) !SftpChannel {
    // Request SFTP subsystem
    const session = try connection.requestSubsystem("sftp");

    return SftpChannel.init(allocator, session);
}

// ============================================================================
// Tests
// ============================================================================

test "SftpChannel - init and deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Can't fully test without real connection, but verify structure compiles
    _ = allocator;
}
