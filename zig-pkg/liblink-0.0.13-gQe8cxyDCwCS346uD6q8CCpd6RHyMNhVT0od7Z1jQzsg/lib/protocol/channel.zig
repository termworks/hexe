const std = @import("std");
const Allocator = std.mem.Allocator;
const wire = @import("wire.zig");
const constants = @import("../common/constants.zig");
const quic_streams = @import("quic_streams.zig");

/// SSH channel management per SPEC.md Section 6.8
///
/// In SSH/QUIC, channels are mapped to QUIC streams:
/// - Each bidirectional stream represents one SSH channel
/// - Stream ID replaces recipient channel ID in packets
/// - No SSH-level flow control (QUIC handles it)
/// - No CHANNEL_WINDOW_ADJUST or CHANNEL_CLOSE messages

/// Channel state
pub const ChannelState = enum {
    opening, // CHANNEL_OPEN sent, waiting for confirmation
    open, // CHANNEL_OPEN_CONFIRMATION received
    failed, // CHANNEL_OPEN_FAILURE received
    eof_sent, // EOF sent on this channel
    eof_received, // EOF received from peer
    closing, // FIN sent on QUIC stream
    closed, // Stream fully closed
};

/// SSH channel over QUIC stream
pub const Channel = struct {
    stream_id: u64,
    channel_type: []const u8,
    state: ChannelState,
    allocator: Allocator,

    /// Create a new channel for a given stream
    pub fn init(allocator: Allocator, stream_id: u64, channel_type: []const u8) !Channel {
        try quic_streams.validateStreamId(stream_id);

        const type_copy = try allocator.dupe(u8, channel_type);

        return Channel{
            .stream_id = stream_id,
            .channel_type = type_copy,
            .state = .opening,
            .allocator = allocator,
        };
    }

    /// Free channel resources
    pub fn deinit(self: *Channel) void {
        self.allocator.free(self.channel_type);
    }

    /// Check if channel is open and ready for data
    pub fn isOpen(self: *const Channel) bool {
        return self.state == .open;
    }

    /// Check if channel has received EOF
    pub fn isEof(self: *const Channel) bool {
        return self.state == .eof_received or self.state == .closed;
    }
};

/// SSH_MSG_CHANNEL_OPEN (SSH/QUIC format per draft-bider-ssh-quic-09 Section 6.8)
///
/// No sender channel or flow control fields — QUIC stream ID is the channel
/// identifier and QUIC handles flow control.
///
/// Format:
///   byte      SSH_MSG_CHANNEL_OPEN
///   string    channel type
///   ....      channel type specific data follows
pub const ChannelOpen = struct {
    channel_type: []const u8,
    type_specific_data: []const u8,

    /// Encode SSH_MSG_CHANNEL_OPEN
    pub fn encode(self: *const ChannelOpen, allocator: Allocator) ![]u8 {
        const size = 1 + 4 + self.channel_type.len + self.type_specific_data.len;
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };
        try writer.writeByte(constants.SSH_MSG.CHANNEL_OPEN);
        try writer.writeString(self.channel_type);
        @memcpy(buffer[buffer.len - self.type_specific_data.len ..], self.type_specific_data);

        return buffer;
    }

    /// Decode SSH_MSG_CHANNEL_OPEN
    pub fn decode(allocator: Allocator, data: []const u8) !ChannelOpen {
        var reader = wire.Reader{ .buffer = data };

        const msg_type = try reader.readByte();
        if (msg_type != constants.SSH_MSG.CHANNEL_OPEN) {
            return error.InvalidMessageType;
        }

        const channel_type = try reader.readString(allocator);
        errdefer allocator.free(channel_type);

        const remaining = data[reader.offset..];
        const type_specific_data = try allocator.dupe(u8, remaining);

        return ChannelOpen{
            .channel_type = channel_type,
            .type_specific_data = type_specific_data,
        };
    }

    /// Free allocated memory
    pub fn deinit(self: *ChannelOpen, allocator: Allocator) void {
        allocator.free(self.channel_type);
        allocator.free(self.type_specific_data);
    }
};

/// SSH_MSG_CHANNEL_OPEN_CONFIRMATION (SSH/QUIC format per draft-bider-ssh-quic-09 Section 6.8)
///
/// No channel ID or flow control fields — QUIC handles both.
///
/// Format:
///   byte      SSH_MSG_CHANNEL_OPEN_CONFIRMATION
///   ....      channel type specific data
pub const ChannelOpenConfirmation = struct {
    type_specific_data: []const u8,

    /// Encode SSH_MSG_CHANNEL_OPEN_CONFIRMATION
    pub fn encode(self: *const ChannelOpenConfirmation, allocator: Allocator) ![]u8 {
        const size = 1 + self.type_specific_data.len;
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        buffer[0] = constants.SSH_MSG.CHANNEL_OPEN_CONFIRMATION;
        @memcpy(buffer[1..], self.type_specific_data);

        return buffer;
    }

    /// Decode SSH_MSG_CHANNEL_OPEN_CONFIRMATION
    pub fn decode(allocator: Allocator, data: []const u8) !ChannelOpenConfirmation {
        if (data.len < 1) return error.InsufficientData;
        if (data[0] != constants.SSH_MSG.CHANNEL_OPEN_CONFIRMATION) {
            return error.InvalidMessageType;
        }

        const type_specific_data = try allocator.dupe(u8, data[1..]);

        return ChannelOpenConfirmation{
            .type_specific_data = type_specific_data,
        };
    }

    /// Free allocated memory
    pub fn deinit(self: *ChannelOpenConfirmation, allocator: Allocator) void {
        allocator.free(self.type_specific_data);
    }
};

/// SSH_MSG_CHANNEL_OPEN_FAILURE
///
/// Format:
///   byte      SSH_MSG_CHANNEL_OPEN_FAILURE
///   uint32    reason code
///   string    description (ISO-10646 UTF-8)
///   string    language tag
pub const ChannelOpenFailure = struct {
    reason_code: u32,
    description: []const u8,
    language_tag: []const u8,

    /// Encode SSH_MSG_CHANNEL_OPEN_FAILURE
    pub fn encode(self: *const ChannelOpenFailure, allocator: Allocator) ![]u8 {
        const size = 1 + 4 + 4 + self.description.len + 4 + self.language_tag.len;
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };
        try writer.writeByte(constants.SSH_MSG.CHANNEL_OPEN_FAILURE);
        try writer.writeUint32(self.reason_code);
        try writer.writeString(self.description);
        try writer.writeString(self.language_tag);

        return buffer;
    }

    /// Decode SSH_MSG_CHANNEL_OPEN_FAILURE
    pub fn decode(allocator: Allocator, data: []const u8) !ChannelOpenFailure {
        var reader = wire.Reader{ .buffer = data };

        const msg_type = try reader.readByte();
        if (msg_type != constants.SSH_MSG.CHANNEL_OPEN_FAILURE) {
            return error.InvalidMessageType;
        }

        const reason_code = try reader.readUint32();

        const description = try reader.readString(allocator);
        errdefer allocator.free(description);

        const language_tag = try reader.readString(allocator);

        return ChannelOpenFailure{
            .reason_code = reason_code,
            .description = description,
            .language_tag = language_tag,
        };
    }

    /// Free allocated memory
    pub fn deinit(self: *ChannelOpenFailure, allocator: Allocator) void {
        allocator.free(self.description);
        allocator.free(self.language_tag);
    }
};

/// SSH_MSG_CHANNEL_DATA (modified format - no recipient channel)
///
/// Format:
///   byte      SSH_MSG_CHANNEL_DATA
///   string    data
pub const ChannelData = struct {
    data: []const u8,

    /// Encode SSH_MSG_CHANNEL_DATA
    pub fn encode(self: *const ChannelData, allocator: Allocator) ![]u8 {
        const size = 1 + 4 + self.data.len;
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };
        try writer.writeByte(constants.SSH_MSG.CHANNEL_DATA);
        try writer.writeString(self.data);

        return buffer;
    }

    /// Decode SSH_MSG_CHANNEL_DATA
    pub fn decode(allocator: Allocator, data: []const u8) !ChannelData {
        var reader = wire.Reader{ .buffer = data };

        const msg_type = try reader.readByte();
        if (msg_type != constants.SSH_MSG.CHANNEL_DATA) {
            return error.InvalidMessageType;
        }

        const payload = try reader.readString(allocator);

        return ChannelData{
            .data = payload,
        };
    }

    /// Free allocated memory
    pub fn deinit(self: *ChannelData, allocator: Allocator) void {
        allocator.free(self.data);
    }
};

/// SSH_MSG_CHANNEL_EXTENDED_DATA (modified format - no recipient channel)
///
/// Format:
///   byte      SSH_MSG_CHANNEL_EXTENDED_DATA
///   uint32    data_type_code
///   string    data
pub const ChannelExtendedData = struct {
    data_type_code: u32,
    data: []const u8,

    /// Encode SSH_MSG_CHANNEL_EXTENDED_DATA
    pub fn encode(self: *const ChannelExtendedData, allocator: Allocator) ![]u8 {
        const size = 1 + 4 + 4 + self.data.len;
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };
        try writer.writeByte(constants.SSH_MSG.CHANNEL_EXTENDED_DATA);
        try writer.writeUint32(self.data_type_code);
        try writer.writeString(self.data);

        return buffer;
    }

    /// Decode SSH_MSG_CHANNEL_EXTENDED_DATA
    pub fn decode(allocator: Allocator, data: []const u8) !ChannelExtendedData {
        var reader = wire.Reader{ .buffer = data };

        const msg_type = try reader.readByte();
        if (msg_type != constants.SSH_MSG.CHANNEL_EXTENDED_DATA) {
            return error.InvalidMessageType;
        }

        const data_type_code = try reader.readUint32();
        const payload = try reader.readString(allocator);

        return ChannelExtendedData{
            .data_type_code = data_type_code,
            .data = payload,
        };
    }

    /// Free allocated memory
    pub fn deinit(self: *ChannelExtendedData, allocator: Allocator) void {
        allocator.free(self.data);
    }
};

/// SSH_MSG_CHANNEL_EOF (modified format - no recipient channel)
///
/// Format:
///   byte      SSH_MSG_CHANNEL_EOF
pub const ChannelEof = struct {
    /// Encode SSH_MSG_CHANNEL_EOF
    pub fn encode(allocator: Allocator) ![]u8 {
        const buffer = try allocator.alloc(u8, 1);
        buffer[0] = constants.SSH_MSG.CHANNEL_EOF;
        return buffer;
    }

    /// Decode SSH_MSG_CHANNEL_EOF
    pub fn decode(data: []const u8) !ChannelEof {
        if (data.len < 1) {
            return error.InsufficientData;
        }

        if (data[0] != constants.SSH_MSG.CHANNEL_EOF) {
            return error.InvalidMessageType;
        }

        return ChannelEof{};
    }
};

/// SSH_MSG_CHANNEL_REQUEST (modified format - no recipient channel)
///
/// Format:
///   byte      SSH_MSG_CHANNEL_REQUEST
///   string    request type
///   boolean   want reply
///   ....      type-specific data follows
pub const ChannelRequest = struct {
    request_type: []const u8,
    want_reply: bool,
    type_specific_data: []const u8,

    /// Encode SSH_MSG_CHANNEL_REQUEST
    pub fn encode(self: *const ChannelRequest, allocator: Allocator) ![]u8 {
        const size = 1 + 4 + self.request_type.len + 1 + self.type_specific_data.len;
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };
        try writer.writeByte(constants.SSH_MSG.CHANNEL_REQUEST);
        try writer.writeString(self.request_type);
        try writer.writeByte(if (self.want_reply) 1 else 0);
        @memcpy(buffer[buffer.len - self.type_specific_data.len ..], self.type_specific_data);

        return buffer;
    }

    /// Decode SSH_MSG_CHANNEL_REQUEST
    pub fn decode(allocator: Allocator, data: []const u8) !ChannelRequest {
        var reader = wire.Reader{ .buffer = data };

        const msg_type = try reader.readByte();
        if (msg_type != constants.SSH_MSG.CHANNEL_REQUEST) {
            return error.InvalidMessageType;
        }

        const request_type = try reader.readString(allocator);
        errdefer allocator.free(request_type);

        const want_reply_byte = try reader.readByte();
        const want_reply = want_reply_byte != 0;

        const remaining = data[reader.offset..];
        const type_specific_data = try allocator.dupe(u8, remaining);

        return ChannelRequest{
            .request_type = request_type,
            .want_reply = want_reply,
            .type_specific_data = type_specific_data,
        };
    }

    /// Free allocated memory
    pub fn deinit(self: *ChannelRequest, allocator: Allocator) void {
        allocator.free(self.request_type);
        allocator.free(self.type_specific_data);
    }
};

/// SSH_MSG_CHANNEL_SUCCESS (modified format - no recipient channel)
///
/// Format:
///   byte      SSH_MSG_CHANNEL_SUCCESS
pub const ChannelSuccess = struct {
    /// Encode SSH_MSG_CHANNEL_SUCCESS
    pub fn encode(allocator: Allocator) ![]u8 {
        const buffer = try allocator.alloc(u8, 1);
        buffer[0] = constants.SSH_MSG.CHANNEL_SUCCESS;
        return buffer;
    }

    /// Decode SSH_MSG_CHANNEL_SUCCESS
    pub fn decode(data: []const u8) !ChannelSuccess {
        if (data.len < 1) {
            return error.InsufficientData;
        }

        if (data[0] != constants.SSH_MSG.CHANNEL_SUCCESS) {
            return error.InvalidMessageType;
        }

        return ChannelSuccess{};
    }
};

/// SSH_MSG_CHANNEL_FAILURE (modified format - no recipient channel)
///
/// Format:
///   byte      SSH_MSG_CHANNEL_FAILURE
pub const ChannelFailure = struct {
    /// Encode SSH_MSG_CHANNEL_FAILURE
    pub fn encode(allocator: Allocator) ![]u8 {
        const buffer = try allocator.alloc(u8, 1);
        buffer[0] = constants.SSH_MSG.CHANNEL_FAILURE;
        return buffer;
    }

    /// Decode SSH_MSG_CHANNEL_FAILURE
    pub fn decode(data: []const u8) !ChannelFailure {
        if (data.len < 1) {
            return error.InsufficientData;
        }

        if (data[0] != constants.SSH_MSG.CHANNEL_FAILURE) {
            return error.InvalidMessageType;
        }

        return ChannelFailure{};
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Channel - init and validation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var channel = try Channel.init(allocator, 4, "session");
    defer channel.deinit();

    try testing.expectEqual(@as(u64, 4), channel.stream_id);
    try testing.expectEqualStrings("session", channel.channel_type);
    try testing.expectEqual(ChannelState.opening, channel.state);
}

test "Channel - init rejects unidirectional stream" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const result = Channel.init(allocator, 2, "session");
    try testing.expectError(error.UnidirectionalStreamNotAllowed, result);
}

test "Channel - state checks" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var channel = try Channel.init(allocator, 4, "session");
    defer channel.deinit();

    try testing.expect(!channel.isOpen());
    try testing.expect(!channel.isEof());

    channel.state = .open;
    try testing.expect(channel.isOpen());
    try testing.expect(!channel.isEof());

    channel.state = .eof_received;
    try testing.expect(!channel.isOpen());
    try testing.expect(channel.isEof());
}

test "ChannelOpen - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const msg = ChannelOpen{
        .channel_type = "session",
        .type_specific_data = "",
    };

    const encoded = try msg.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try ChannelOpen.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqualStrings(msg.channel_type, decoded.channel_type);
    try testing.expectEqualStrings(msg.type_specific_data, decoded.type_specific_data);
}

test "ChannelOpenConfirmation - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const msg = ChannelOpenConfirmation{
        .type_specific_data = "",
    };

    const encoded = try msg.encode(allocator);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 1), encoded.len);

    var decoded = try ChannelOpenConfirmation.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqualStrings(msg.type_specific_data, decoded.type_specific_data);
}

test "ChannelOpenFailure - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const msg = ChannelOpenFailure{
        .reason_code = 1, // SSH_OPEN_ADMINISTRATIVELY_PROHIBITED
        .description = "Channel type not supported",
        .language_tag = "en",
    };

    const encoded = try msg.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try ChannelOpenFailure.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqual(msg.reason_code, decoded.reason_code);
    try testing.expectEqualStrings(msg.description, decoded.description);
    try testing.expectEqualStrings(msg.language_tag, decoded.language_tag);
}

test "ChannelData - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const msg = ChannelData{
        .data = "Hello, SSH/QUIC!",
    };

    const encoded = try msg.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try ChannelData.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqualStrings(msg.data, decoded.data);
}

test "ChannelExtendedData - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const msg = ChannelExtendedData{
        .data_type_code = 1, // SSH_EXTENDED_DATA_STDERR
        .data = "Error message",
    };

    const encoded = try msg.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try ChannelExtendedData.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqual(msg.data_type_code, decoded.data_type_code);
    try testing.expectEqualStrings(msg.data, decoded.data);
}

test "ChannelEof - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const encoded = try ChannelEof.encode(allocator);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 1), encoded.len);
    try testing.expectEqual(constants.SSH_MSG.CHANNEL_EOF, encoded[0]);

    const decoded = try ChannelEof.decode(encoded);
    _ = decoded;
}

test "ChannelRequest - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const msg = ChannelRequest{
        .request_type = "pty-req",
        .want_reply = true,
        .type_specific_data = "pty_data_here",
    };

    const encoded = try msg.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try ChannelRequest.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqualStrings(msg.request_type, decoded.request_type);
    try testing.expectEqual(msg.want_reply, decoded.want_reply);
    try testing.expectEqualStrings(msg.type_specific_data, decoded.type_specific_data);
}

test "ChannelSuccess - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const encoded = try ChannelSuccess.encode(allocator);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 1), encoded.len);

    const decoded = try ChannelSuccess.decode(encoded);
    _ = decoded;
}

test "ChannelFailure - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const encoded = try ChannelFailure.encode(allocator);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 1), encoded.len);

    const decoded = try ChannelFailure.decode(encoded);
    _ = decoded;
}
