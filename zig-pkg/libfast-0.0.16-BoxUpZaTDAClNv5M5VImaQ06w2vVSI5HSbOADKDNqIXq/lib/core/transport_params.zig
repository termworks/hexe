const std = @import("std");
const varint = @import("../utils/varint.zig");

/// QUIC Transport Parameters (RFC 9000 Section 18)
///
/// Transport parameters are exchanged during connection establishment
/// to configure connection behavior.
pub const TransportParamsError = error{
    InvalidParameter,
    InvalidLength,
    DuplicateParameter,
    MissingRequiredParameter,
    BufferTooSmall,
    OutOfMemory,
    ValueTooLarge,
    UnexpectedEof,
    InvalidEncoding,
    ProtocolViolation,
};

/// Transport parameter ID
pub const TransportParamId = enum(u64) {
    original_destination_connection_id = 0x00,
    max_idle_timeout = 0x01,
    stateless_reset_token = 0x02,
    max_udp_payload_size = 0x03,
    initial_max_data = 0x04,
    initial_max_stream_data_bidi_local = 0x05,
    initial_max_stream_data_bidi_remote = 0x06,
    initial_max_stream_data_uni = 0x07,
    initial_max_streams_bidi = 0x08,
    initial_max_streams_uni = 0x09,
    ack_delay_exponent = 0x0a,
    max_ack_delay = 0x0b,
    disable_active_migration = 0x0c,
    preferred_address = 0x0d,
    active_connection_id_limit = 0x0e,
    initial_source_connection_id = 0x0f,
    retry_source_connection_id = 0x10,

    _,
};

/// Transport parameters
pub const TransportParams = struct {
    /// Maximum idle timeout (milliseconds)
    max_idle_timeout: u64 = 0,

    /// Maximum UDP payload size
    max_udp_payload_size: u64 = 65527,

    /// Initial maximum data (connection-level flow control)
    initial_max_data: u64 = 0,

    /// Initial max stream data (bidirectional, locally-initiated)
    initial_max_stream_data_bidi_local: u64 = 0,

    /// Initial max stream data (bidirectional, remotely-initiated)
    initial_max_stream_data_bidi_remote: u64 = 0,

    /// Initial max stream data (unidirectional)
    initial_max_stream_data_uni: u64 = 0,

    /// Initial max bidirectional streams
    initial_max_streams_bidi: u64 = 0,

    /// Initial max unidirectional streams
    initial_max_streams_uni: u64 = 0,

    /// ACK delay exponent
    ack_delay_exponent: u64 = 3,

    /// Maximum ACK delay (milliseconds)
    max_ack_delay: u64 = 25,

    /// Disable active migration
    disable_active_migration: bool = false,

    /// Active connection ID limit
    active_connection_id_limit: u64 = 2,

    /// Original destination connection ID
    original_destination_connection_id: ?[]const u8 = null,

    /// Initial source connection ID
    initial_source_connection_id: ?[]const u8 = null,

    /// Stateless reset token
    stateless_reset_token: ?[16]u8 = null,

    /// Initialize with default values
    pub fn init() TransportParams {
        return TransportParams{};
    }

    /// Create default client parameters
    pub fn defaultClient() TransportParams {
        return TransportParams{
            .max_idle_timeout = 30000, // 30 seconds
            .initial_max_data = 1024 * 1024, // 1 MB
            .initial_max_stream_data_bidi_local = 256 * 1024, // 256 KB
            .initial_max_stream_data_bidi_remote = 256 * 1024, // 256 KB
            .initial_max_stream_data_uni = 256 * 1024, // 256 KB
            .initial_max_streams_bidi = 100,
            .initial_max_streams_uni = 100,
        };
    }

    /// Create default server parameters
    pub fn defaultServer() TransportParams {
        return TransportParams{
            .max_idle_timeout = 30000, // 30 seconds
            .initial_max_data = 1024 * 1024, // 1 MB
            .initial_max_stream_data_bidi_local = 256 * 1024, // 256 KB
            .initial_max_stream_data_bidi_remote = 256 * 1024, // 256 KB
            .initial_max_stream_data_uni = 256 * 1024, // 256 KB
            .initial_max_streams_bidi = 100,
            .initial_max_streams_uni = 100,
        };
    }

    /// Encode transport parameters
    pub fn encode(self: TransportParams, allocator: std.mem.Allocator) TransportParamsError![]u8 {
        var buf: std.ArrayList(u8) = .{};
        errdefer buf.deinit(allocator);

        // Helper to encode a u64 parameter
        const encodeU64Param = struct {
            fn call(list: *std.ArrayList(u8), alloc: std.mem.Allocator, id: u64, value: u64) !void {
                // Parameter ID
                var id_buf: [8]u8 = undefined;
                const id_len = try varint.encode(id, &id_buf);
                try list.appendSlice(alloc, id_buf[0..id_len]);

                // Value length (varint-encoded value)
                var value_buf: [8]u8 = undefined;
                const value_len = try varint.encode(value, &value_buf);

                // Length of value
                var len_buf: [8]u8 = undefined;
                const len_len = try varint.encode(value_len, &len_buf);
                try list.appendSlice(alloc, len_buf[0..len_len]);

                // Value
                try list.appendSlice(alloc, value_buf[0..value_len]);
            }
        }.call;

        // Encode non-zero u64 parameters
        if (self.max_idle_timeout != 0) {
            try encodeU64Param(&buf, allocator, @intFromEnum(TransportParamId.max_idle_timeout), self.max_idle_timeout);
        }

        if (self.max_udp_payload_size != 65527) {
            try encodeU64Param(&buf, allocator, @intFromEnum(TransportParamId.max_udp_payload_size), self.max_udp_payload_size);
        }

        if (self.initial_max_data != 0) {
            try encodeU64Param(&buf, allocator, @intFromEnum(TransportParamId.initial_max_data), self.initial_max_data);
        }

        if (self.initial_max_stream_data_bidi_local != 0) {
            try encodeU64Param(&buf, allocator, @intFromEnum(TransportParamId.initial_max_stream_data_bidi_local), self.initial_max_stream_data_bidi_local);
        }

        if (self.initial_max_stream_data_bidi_remote != 0) {
            try encodeU64Param(&buf, allocator, @intFromEnum(TransportParamId.initial_max_stream_data_bidi_remote), self.initial_max_stream_data_bidi_remote);
        }

        if (self.initial_max_stream_data_uni != 0) {
            try encodeU64Param(&buf, allocator, @intFromEnum(TransportParamId.initial_max_stream_data_uni), self.initial_max_stream_data_uni);
        }

        if (self.initial_max_streams_bidi != 0) {
            try encodeU64Param(&buf, allocator, @intFromEnum(TransportParamId.initial_max_streams_bidi), self.initial_max_streams_bidi);
        }

        if (self.initial_max_streams_uni != 0) {
            try encodeU64Param(&buf, allocator, @intFromEnum(TransportParamId.initial_max_streams_uni), self.initial_max_streams_uni);
        }

        if (self.ack_delay_exponent != 3) {
            try encodeU64Param(&buf, allocator, @intFromEnum(TransportParamId.ack_delay_exponent), self.ack_delay_exponent);
        }

        if (self.max_ack_delay != 25) {
            try encodeU64Param(&buf, allocator, @intFromEnum(TransportParamId.max_ack_delay), self.max_ack_delay);
        }

        if (self.active_connection_id_limit != 2) {
            try encodeU64Param(&buf, allocator, @intFromEnum(TransportParamId.active_connection_id_limit), self.active_connection_id_limit);
        }

        // Disable active migration (zero-length parameter)
        if (self.disable_active_migration) {
            var id_buf: [8]u8 = undefined;
            const id_len = try varint.encode(@intFromEnum(TransportParamId.disable_active_migration), &id_buf);
            try buf.appendSlice(allocator, id_buf[0..id_len]);

            var len_buf: [8]u8 = undefined;
            const len_len = try varint.encode(0, &len_buf);
            try buf.appendSlice(allocator, len_buf[0..len_len]);
        }

        return buf.toOwnedSlice(allocator);
    }

    /// Decode transport parameters
    pub fn decode(allocator: std.mem.Allocator, data: []const u8) TransportParamsError!TransportParams {
        _ = allocator;
        var params = TransportParams.init();
        var offset: usize = 0;

        var seen_max_idle_timeout = false;
        var seen_max_udp_payload_size = false;
        var seen_initial_max_data = false;
        var seen_initial_max_stream_data_bidi_local = false;
        var seen_initial_max_stream_data_bidi_remote = false;
        var seen_initial_max_stream_data_uni = false;
        var seen_initial_max_streams_bidi = false;
        var seen_initial_max_streams_uni = false;
        var seen_ack_delay_exponent = false;
        var seen_max_ack_delay = false;
        var seen_disable_active_migration = false;
        var seen_active_connection_id_limit = false;

        while (offset < data.len) {
            // Read parameter ID
            const id_result = varint.decode(data[offset..]) catch {
                return error.InvalidParameter;
            };
            const param_id = id_result.value;
            offset += id_result.len;

            // Read parameter length
            const len_result = varint.decode(data[offset..]) catch {
                return error.InvalidParameter;
            };
            const param_len: usize = @intCast(len_result.value);
            offset += len_result.len;

            // Check bounds
            if (offset + param_len > data.len) {
                return error.InvalidLength;
            }

            const param_data = data[offset .. offset + param_len];
            offset += param_len;

            // Parse parameter value
            switch (@as(TransportParamId, @enumFromInt(param_id))) {
                .max_idle_timeout => {
                    if (seen_max_idle_timeout) return error.DuplicateParameter;
                    seen_max_idle_timeout = true;
                    params.max_idle_timeout = try decodeSingleVarInt(param_data);
                },
                .max_udp_payload_size => {
                    if (seen_max_udp_payload_size) return error.DuplicateParameter;
                    seen_max_udp_payload_size = true;
                    params.max_udp_payload_size = try decodeSingleVarInt(param_data);
                    if (params.max_udp_payload_size < 1200) return error.ProtocolViolation;
                },
                .initial_max_data => {
                    if (seen_initial_max_data) return error.DuplicateParameter;
                    seen_initial_max_data = true;
                    params.initial_max_data = try decodeSingleVarInt(param_data);
                },
                .initial_max_stream_data_bidi_local => {
                    if (seen_initial_max_stream_data_bidi_local) return error.DuplicateParameter;
                    seen_initial_max_stream_data_bidi_local = true;
                    params.initial_max_stream_data_bidi_local = try decodeSingleVarInt(param_data);
                },
                .initial_max_stream_data_bidi_remote => {
                    if (seen_initial_max_stream_data_bidi_remote) return error.DuplicateParameter;
                    seen_initial_max_stream_data_bidi_remote = true;
                    params.initial_max_stream_data_bidi_remote = try decodeSingleVarInt(param_data);
                },
                .initial_max_stream_data_uni => {
                    if (seen_initial_max_stream_data_uni) return error.DuplicateParameter;
                    seen_initial_max_stream_data_uni = true;
                    params.initial_max_stream_data_uni = try decodeSingleVarInt(param_data);
                },
                .initial_max_streams_bidi => {
                    if (seen_initial_max_streams_bidi) return error.DuplicateParameter;
                    seen_initial_max_streams_bidi = true;
                    params.initial_max_streams_bidi = try decodeSingleVarInt(param_data);
                },
                .initial_max_streams_uni => {
                    if (seen_initial_max_streams_uni) return error.DuplicateParameter;
                    seen_initial_max_streams_uni = true;
                    params.initial_max_streams_uni = try decodeSingleVarInt(param_data);
                },
                .ack_delay_exponent => {
                    if (seen_ack_delay_exponent) return error.DuplicateParameter;
                    seen_ack_delay_exponent = true;
                    params.ack_delay_exponent = try decodeSingleVarInt(param_data);
                    if (params.ack_delay_exponent > 20) return error.ProtocolViolation;
                },
                .max_ack_delay => {
                    if (seen_max_ack_delay) return error.DuplicateParameter;
                    seen_max_ack_delay = true;
                    params.max_ack_delay = try decodeSingleVarInt(param_data);
                    if (params.max_ack_delay >= 16384) return error.ProtocolViolation;
                },
                .active_connection_id_limit => {
                    if (seen_active_connection_id_limit) return error.DuplicateParameter;
                    seen_active_connection_id_limit = true;
                    params.active_connection_id_limit = try decodeSingleVarInt(param_data);
                    if (params.active_connection_id_limit < 2) return error.ProtocolViolation;
                },
                .disable_active_migration => {
                    if (seen_disable_active_migration) return error.DuplicateParameter;
                    seen_disable_active_migration = true;
                    if (param_len != 0) return error.InvalidLength;
                    params.disable_active_migration = true;
                },
                else => {
                    // Unknown parameter - ignore per RFC 9000
                },
            }
        }

        return params;
    }

    fn decodeSingleVarInt(param_data: []const u8) TransportParamsError!u64 {
        if (param_data.len == 0) return error.InvalidLength;
        const result = varint.decode(param_data) catch return error.InvalidParameter;
        if (result.len != param_data.len) return error.InvalidLength;
        return result.value;
    }
};

// Tests

test "Transport params initialization" {
    const params = TransportParams.init();

    try std.testing.expectEqual(@as(u64, 0), params.max_idle_timeout);
    try std.testing.expectEqual(@as(u64, 65527), params.max_udp_payload_size);
}

test "Transport params default client" {
    const params = TransportParams.defaultClient();

    try std.testing.expectEqual(@as(u64, 30000), params.max_idle_timeout);
    try std.testing.expectEqual(@as(u64, 1024 * 1024), params.initial_max_data);
    try std.testing.expectEqual(@as(u64, 100), params.initial_max_streams_bidi);
}

test "Transport params default server" {
    const params = TransportParams.defaultServer();

    try std.testing.expectEqual(@as(u64, 30000), params.max_idle_timeout);
    try std.testing.expectEqual(@as(u64, 1024 * 1024), params.initial_max_data);
}

test "Transport params encode and decode" {
    const allocator = std.testing.allocator;

    var params = TransportParams.init();
    params.max_idle_timeout = 30000;
    params.initial_max_data = 1048576;
    params.initial_max_streams_bidi = 100;

    const encoded = try params.encode(allocator);
    defer allocator.free(encoded);

    try std.testing.expect(encoded.len > 0);

    const decoded = try TransportParams.decode(allocator, encoded);

    try std.testing.expectEqual(params.max_idle_timeout, decoded.max_idle_timeout);
    try std.testing.expectEqual(params.initial_max_data, decoded.initial_max_data);
    try std.testing.expectEqual(params.initial_max_streams_bidi, decoded.initial_max_streams_bidi);
}

test "Transport params encode disable migration" {
    const allocator = std.testing.allocator;

    var params = TransportParams.init();
    params.disable_active_migration = true;

    const encoded = try params.encode(allocator);
    defer allocator.free(encoded);

    const decoded = try TransportParams.decode(allocator, encoded);

    try std.testing.expect(decoded.disable_active_migration);
}

test "Transport params round trip" {
    const allocator = std.testing.allocator;

    const original = TransportParams.defaultClient();

    const encoded = try original.encode(allocator);
    defer allocator.free(encoded);

    const decoded = try TransportParams.decode(allocator, encoded);

    try std.testing.expectEqual(original.max_idle_timeout, decoded.max_idle_timeout);
    try std.testing.expectEqual(original.initial_max_data, decoded.initial_max_data);
    try std.testing.expectEqual(original.initial_max_stream_data_bidi_local, decoded.initial_max_stream_data_bidi_local);
    try std.testing.expectEqual(original.initial_max_streams_bidi, decoded.initial_max_streams_bidi);
}

test "Transport params empty decode" {
    const allocator = std.testing.allocator;

    const data: []const u8 = &[_]u8{};
    const params = try TransportParams.decode(allocator, data);

    // Should get default values
    try std.testing.expectEqual(@as(u64, 0), params.max_idle_timeout);
}

test "Transport params unknown parameter ignored" {
    const allocator = std.testing.allocator;

    // Encode parameter with unknown ID (0xFF)
    var data: [10]u8 = undefined;
    var offset: usize = 0;

    // ID = 0xFF
    var id_buf: [8]u8 = undefined;
    const id_len = try varint.encode(0xFF, &id_buf);
    @memcpy(data[offset..][0..id_len], id_buf[0..id_len]);
    offset += id_len;

    // Length = 2
    var len_buf: [8]u8 = undefined;
    const len_len = try varint.encode(2, &len_buf);
    @memcpy(data[offset..][0..len_len], len_buf[0..len_len]);
    offset += len_len;

    // Value = arbitrary bytes
    data[offset] = 0x12;
    data[offset + 1] = 0x34;
    offset += 2;

    // Should decode without error (unknown params ignored)
    const params = try TransportParams.decode(allocator, data[0..offset]);
    _ = params;
}

test "Transport params multiple parameters" {
    const allocator = std.testing.allocator;

    var params = TransportParams.init();
    params.max_idle_timeout = 10000;
    params.initial_max_data = 500000;
    params.initial_max_streams_bidi = 50;
    params.initial_max_streams_uni = 25;
    params.ack_delay_exponent = 5;

    const encoded = try params.encode(allocator);
    defer allocator.free(encoded);

    const decoded = try TransportParams.decode(allocator, encoded);

    try std.testing.expectEqual(params.max_idle_timeout, decoded.max_idle_timeout);
    try std.testing.expectEqual(params.initial_max_data, decoded.initial_max_data);
    try std.testing.expectEqual(params.initial_max_streams_bidi, decoded.initial_max_streams_bidi);
    try std.testing.expectEqual(params.initial_max_streams_uni, decoded.initial_max_streams_uni);
    try std.testing.expectEqual(params.ack_delay_exponent, decoded.ack_delay_exponent);
}

test "Transport params duplicate parameter rejected" {
    const allocator = std.testing.allocator;

    var data: [32]u8 = undefined;
    var offset: usize = 0;

    var id_buf: [8]u8 = undefined;
    var len_buf: [8]u8 = undefined;
    var value_buf: [8]u8 = undefined;

    const id_len = try varint.encode(@intFromEnum(TransportParamId.max_idle_timeout), &id_buf);
    const value_len = try varint.encode(100, &value_buf);
    const plen_len = try varint.encode(value_len, &len_buf);

    @memcpy(data[offset..][0..id_len], id_buf[0..id_len]);
    offset += id_len;
    @memcpy(data[offset..][0..plen_len], len_buf[0..plen_len]);
    offset += plen_len;
    @memcpy(data[offset..][0..value_len], value_buf[0..value_len]);
    offset += value_len;

    @memcpy(data[offset..][0..id_len], id_buf[0..id_len]);
    offset += id_len;
    @memcpy(data[offset..][0..plen_len], len_buf[0..plen_len]);
    offset += plen_len;
    @memcpy(data[offset..][0..value_len], value_buf[0..value_len]);
    offset += value_len;

    try std.testing.expectError(error.DuplicateParameter, TransportParams.decode(allocator, data[0..offset]));
}

test "Transport params reject max_udp_payload_size below minimum" {
    const allocator = std.testing.allocator;

    var data: [32]u8 = undefined;
    var offset: usize = 0;

    var id_buf: [8]u8 = undefined;
    var len_buf: [8]u8 = undefined;
    var value_buf: [8]u8 = undefined;

    const id_len = try varint.encode(@intFromEnum(TransportParamId.max_udp_payload_size), &id_buf);
    const value_len = try varint.encode(1199, &value_buf);
    const plen_len = try varint.encode(value_len, &len_buf);

    @memcpy(data[offset..][0..id_len], id_buf[0..id_len]);
    offset += id_len;
    @memcpy(data[offset..][0..plen_len], len_buf[0..plen_len]);
    offset += plen_len;
    @memcpy(data[offset..][0..value_len], value_buf[0..value_len]);
    offset += value_len;

    try std.testing.expectError(error.ProtocolViolation, TransportParams.decode(allocator, data[0..offset]));
}

test "Transport params reject active_connection_id_limit below two" {
    const allocator = std.testing.allocator;

    var data: [32]u8 = undefined;
    var offset: usize = 0;

    var id_buf: [8]u8 = undefined;
    var len_buf: [8]u8 = undefined;
    var value_buf: [8]u8 = undefined;

    const id_len = try varint.encode(@intFromEnum(TransportParamId.active_connection_id_limit), &id_buf);
    const value_len = try varint.encode(1, &value_buf);
    const plen_len = try varint.encode(value_len, &len_buf);

    @memcpy(data[offset..][0..id_len], id_buf[0..id_len]);
    offset += id_len;
    @memcpy(data[offset..][0..plen_len], len_buf[0..plen_len]);
    offset += plen_len;
    @memcpy(data[offset..][0..value_len], value_buf[0..value_len]);
    offset += value_len;

    try std.testing.expectError(error.ProtocolViolation, TransportParams.decode(allocator, data[0..offset]));
}
