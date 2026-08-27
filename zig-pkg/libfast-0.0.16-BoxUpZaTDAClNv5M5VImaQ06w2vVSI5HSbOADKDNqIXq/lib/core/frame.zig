const std = @import("std");
const types = @import("types.zig");
const varint = @import("../utils/varint.zig");

const FrameType = types.FrameType;
const StreamId = types.StreamId;
const ErrorCode = types.ErrorCode;
const ConnectionId = types.ConnectionId;

pub const FrameError = error{
    InvalidFrameType,
    UnexpectedEof,
    BufferTooSmall,
    InvalidStreamId,
    InvalidData,
} || varint.VarintError;

/// QUIC Frame - tagged union of all frame types
pub const Frame = union(enum) {
    padding: PaddingFrame,
    ping: PingFrame,
    ack: AckFrame,
    reset_stream: ResetStreamFrame,
    stop_sending: StopSendingFrame,
    crypto: CryptoFrame,
    new_token: NewTokenFrame,
    stream: StreamFrame,
    max_data: MaxDataFrame,
    max_stream_data: MaxStreamDataFrame,
    max_streams: MaxStreamsFrame,
    data_blocked: DataBlockedFrame,
    stream_data_blocked: StreamDataBlockedFrame,
    streams_blocked: StreamsBlockedFrame,
    new_connection_id: NewConnectionIdFrame,
    retire_connection_id: RetireConnectionIdFrame,
    path_challenge: PathChallengeFrame,
    path_response: PathResponseFrame,
    connection_close: ConnectionCloseFrame,
    handshake_done: HandshakeDoneFrame,
};

/// PADDING frame (0x00)
pub const PaddingFrame = struct {
    pub fn decode(buf: []const u8) FrameError!struct { frame: PaddingFrame, consumed: usize } {
        const type_result = try varint.decode(buf);
        if (type_result.value != 0x00) return error.InvalidFrameType;
        return .{ .frame = PaddingFrame{}, .consumed = type_result.len };
    }
};

/// PING frame (0x01)
pub const PingFrame = struct {
    pub fn decode(buf: []const u8) FrameError!struct { frame: PingFrame, consumed: usize } {
        const type_result = try varint.decode(buf);
        if (type_result.value != 0x01) return error.InvalidFrameType;
        return .{ .frame = PingFrame{}, .consumed = type_result.len };
    }
};

/// ACK frame (0x02-0x03)
pub const AckFrame = struct {
    largest_acked: u64,
    ack_delay: u64,
    first_ack_range: u64,
    ack_ranges: []const AckRange,
    ecn_counts: ?EcnCounts = null,

    pub const AckRange = struct {
        gap: u64,
        ack_range_length: u64,
    };

    pub const EcnCounts = struct {
        ect0_count: u64,
        ect1_count: u64,
        ecn_ce_count: u64,
    };

    pub const DecodeResult = struct {
        frame: AckFrame,
        consumed: usize,
    };

    pub fn encode(self: AckFrame, buf: []u8) FrameError!usize {
        var pos: usize = 0;

        // Frame type
        const frame_type: u64 = if (self.ecn_counts != null) 0x03 else 0x02;
        pos += try varint.encode(frame_type, buf[pos..]);

        // Largest Acknowledged
        pos += try varint.encode(self.largest_acked, buf[pos..]);

        // ACK Delay
        pos += try varint.encode(self.ack_delay, buf[pos..]);

        // ACK Range Count
        pos += try varint.encode(self.ack_ranges.len, buf[pos..]);

        // First ACK Range
        pos += try varint.encode(self.first_ack_range, buf[pos..]);

        // ACK Ranges
        for (self.ack_ranges) |range| {
            pos += try varint.encode(range.gap, buf[pos..]);
            pos += try varint.encode(range.ack_range_length, buf[pos..]);
        }

        // ECN Counts (if present)
        if (self.ecn_counts) |ecn| {
            pos += try varint.encode(ecn.ect0_count, buf[pos..]);
            pos += try varint.encode(ecn.ect1_count, buf[pos..]);
            pos += try varint.encode(ecn.ecn_ce_count, buf[pos..]);
        }

        return pos;
    }

    pub fn decode(buf: []const u8) FrameError!DecodeResult {
        return decodeWithAckRanges(buf, &.{});
    }

    pub fn decodeWithAckRanges(
        buf: []const u8,
        ack_ranges_out: []AckRange,
    ) FrameError!DecodeResult {
        var pos: usize = 0;

        const type_result = try varint.decode(buf[pos..]);
        pos += type_result.len;

        const has_ecn = switch (type_result.value) {
            0x02 => false,
            0x03 => true,
            else => return error.InvalidFrameType,
        };

        const largest_acked_result = try varint.decode(buf[pos..]);
        pos += largest_acked_result.len;

        const ack_delay_result = try varint.decode(buf[pos..]);
        pos += ack_delay_result.len;

        const ack_range_count_result = try varint.decode(buf[pos..]);
        pos += ack_range_count_result.len;

        const first_ack_range_result = try varint.decode(buf[pos..]);
        pos += first_ack_range_result.len;

        if (first_ack_range_result.value > largest_acked_result.value) {
            return error.InvalidData;
        }

        var current_smallest: u64 = largest_acked_result.value - first_ack_range_result.value;

        if (ack_range_count_result.value > ack_ranges_out.len) {
            return error.BufferTooSmall;
        }

        var parsed_ranges: usize = 0;
        var i: u64 = 0;
        while (i < ack_range_count_result.value) : (i += 1) {
            const gap_result = try varint.decode(buf[pos..]);
            pos += gap_result.len;
            const range_len_result = try varint.decode(buf[pos..]);
            pos += range_len_result.len;

            ack_ranges_out[parsed_ranges] = .{
                .gap = gap_result.value,
                .ack_range_length = range_len_result.value,
            };
            parsed_ranges += 1;

            const step = gap_result.value + 2;
            if (current_smallest < step) {
                return error.InvalidData;
            }

            const next_largest = current_smallest - step;
            if (range_len_result.value > next_largest) {
                return error.InvalidData;
            }

            current_smallest = next_largest - range_len_result.value;
        }

        var ecn_counts: ?EcnCounts = null;
        if (has_ecn) {
            const ect0_result = try varint.decode(buf[pos..]);
            pos += ect0_result.len;
            const ect1_result = try varint.decode(buf[pos..]);
            pos += ect1_result.len;
            const ce_result = try varint.decode(buf[pos..]);
            pos += ce_result.len;

            ecn_counts = EcnCounts{
                .ect0_count = ect0_result.value,
                .ect1_count = ect1_result.value,
                .ecn_ce_count = ce_result.value,
            };
        }

        return .{
            .frame = AckFrame{
                .largest_acked = largest_acked_result.value,
                .ack_delay = ack_delay_result.value,
                .first_ack_range = first_ack_range_result.value,
                .ack_ranges = ack_ranges_out[0..parsed_ranges],
                .ecn_counts = ecn_counts,
            },
            .consumed = pos,
        };
    }
};

/// RESET_STREAM frame (0x04)
pub const ResetStreamFrame = struct {
    stream_id: StreamId,
    error_code: u64,
    final_size: u64,

    pub fn encode(self: ResetStreamFrame, buf: []u8) FrameError!usize {
        var pos: usize = 0;
        pos += try varint.encode(0x04, buf[pos..]);
        pos += try varint.encode(self.stream_id, buf[pos..]);
        pos += try varint.encode(self.error_code, buf[pos..]);
        pos += try varint.encode(self.final_size, buf[pos..]);
        return pos;
    }

    pub fn decode(buf: []const u8) FrameError!struct { frame: ResetStreamFrame, consumed: usize } {
        var pos: usize = 0;

        const type_result = try varint.decode(buf[pos..]);
        pos += type_result.len;
        if (type_result.value != 0x04) return error.InvalidFrameType;

        const stream_id_result = try varint.decode(buf[pos..]);
        pos += stream_id_result.len;

        const error_code_result = try varint.decode(buf[pos..]);
        pos += error_code_result.len;

        const final_size_result = try varint.decode(buf[pos..]);
        pos += final_size_result.len;

        return .{
            .frame = ResetStreamFrame{
                .stream_id = stream_id_result.value,
                .error_code = error_code_result.value,
                .final_size = final_size_result.value,
            },
            .consumed = pos,
        };
    }
};

/// STOP_SENDING frame (0x05)
pub const StopSendingFrame = struct {
    stream_id: StreamId,
    error_code: u64,

    pub fn encode(self: StopSendingFrame, buf: []u8) FrameError!usize {
        var pos: usize = 0;
        pos += try varint.encode(0x05, buf[pos..]);
        pos += try varint.encode(self.stream_id, buf[pos..]);
        pos += try varint.encode(self.error_code, buf[pos..]);
        return pos;
    }

    pub fn decode(buf: []const u8) FrameError!struct { frame: StopSendingFrame, consumed: usize } {
        var pos: usize = 0;

        const type_result = try varint.decode(buf[pos..]);
        pos += type_result.len;
        if (type_result.value != 0x05) return error.InvalidFrameType;

        const stream_id_result = try varint.decode(buf[pos..]);
        pos += stream_id_result.len;

        const error_code_result = try varint.decode(buf[pos..]);
        pos += error_code_result.len;

        return .{
            .frame = StopSendingFrame{
                .stream_id = stream_id_result.value,
                .error_code = error_code_result.value,
            },
            .consumed = pos,
        };
    }
};

/// CRYPTO frame (0x06)
pub const CryptoFrame = struct {
    offset: u64,
    data: []const u8,

    pub fn encode(self: CryptoFrame, buf: []u8) FrameError!usize {
        var pos: usize = 0;
        pos += try varint.encode(0x06, buf[pos..]);
        pos += try varint.encode(self.offset, buf[pos..]);
        pos += try varint.encode(self.data.len, buf[pos..]);
        if (pos + self.data.len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[pos..][0..self.data.len], self.data);
        pos += self.data.len;
        return pos;
    }

    pub fn decode(buf: []const u8) FrameError!struct { frame: CryptoFrame, consumed: usize } {
        var pos: usize = 0;

        const type_result = try varint.decode(buf[pos..]);
        pos += type_result.len;
        if (type_result.value != 0x06) return error.InvalidFrameType;

        const offset_result = try varint.decode(buf[pos..]);
        pos += offset_result.len;

        const len_result = try varint.decode(buf[pos..]);
        pos += len_result.len;

        if (pos + len_result.value > buf.len) return error.UnexpectedEof;
        const data = buf[pos .. pos + len_result.value];
        pos += len_result.value;

        return .{
            .frame = .{ .offset = offset_result.value, .data = data },
            .consumed = pos,
        };
    }
};

/// NEW_TOKEN frame (0x07)
pub const NewTokenFrame = struct {
    token: []const u8,

    pub fn encode(self: NewTokenFrame, buf: []u8) FrameError!usize {
        var pos: usize = 0;
        pos += try varint.encode(0x07, buf[pos..]);
        pos += try varint.encode(self.token.len, buf[pos..]);
        if (pos + self.token.len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[pos..][0..self.token.len], self.token);
        pos += self.token.len;
        return pos;
    }

    pub fn decode(buf: []const u8) FrameError!struct { frame: NewTokenFrame, consumed: usize } {
        var pos: usize = 0;

        const type_result = try varint.decode(buf[pos..]);
        pos += type_result.len;
        if (type_result.value != 0x07) return error.InvalidFrameType;

        const token_len_result = try varint.decode(buf[pos..]);
        pos += token_len_result.len;
        const token_len = token_len_result.value;

        if (pos + token_len > buf.len) return error.UnexpectedEof;
        const token = buf[pos..][0..token_len];
        pos += token_len;

        return .{
            .frame = .{ .token = token },
            .consumed = pos,
        };
    }
};

/// STREAM frame (0x08-0x0f)
pub const StreamFrame = struct {
    stream_id: StreamId,
    offset: u64 = 0,
    data: []const u8,
    fin: bool = false,

    pub fn encode(self: StreamFrame, buf: []u8) FrameError!usize {
        var pos: usize = 0;

        // Frame type with flags
        // Bit 0: FIN
        // Bit 1: LEN (always set)
        // Bit 2: OFF (set if offset > 0)
        var frame_type: u64 = 0x08;
        if (self.fin) frame_type |= 0x01;
        frame_type |= 0x02; // Always include length
        if (self.offset > 0) frame_type |= 0x04;

        pos += try varint.encode(frame_type, buf[pos..]);
        pos += try varint.encode(self.stream_id, buf[pos..]);

        if (self.offset > 0) {
            pos += try varint.encode(self.offset, buf[pos..]);
        }

        pos += try varint.encode(self.data.len, buf[pos..]);
        if (pos + self.data.len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[pos..][0..self.data.len], self.data);
        pos += self.data.len;

        return pos;
    }

    pub fn decode(buf: []const u8) FrameError!struct { frame: StreamFrame, consumed: usize } {
        var pos: usize = 0;

        // Frame type
        const frame_type_result = try varint.decode(buf[pos..]);
        pos += frame_type_result.len;
        const frame_type = frame_type_result.value;

        if (!FrameType.isStreamFrame(frame_type)) return error.InvalidFrameType;

        const fin = (frame_type & 0x01) != 0;
        const has_len = (frame_type & 0x02) != 0;
        const has_off = (frame_type & 0x04) != 0;

        // Stream ID
        const stream_id_result = try varint.decode(buf[pos..]);
        pos += stream_id_result.len;
        const stream_id = stream_id_result.value;

        // Offset (if present)
        var offset: u64 = 0;
        if (has_off) {
            const offset_result = try varint.decode(buf[pos..]);
            pos += offset_result.len;
            offset = offset_result.value;
        }

        // Length and data
        var data: []const u8 = undefined;
        if (has_len) {
            const len_result = try varint.decode(buf[pos..]);
            pos += len_result.len;
            const data_len = len_result.value;
            if (pos + data_len > buf.len) return error.UnexpectedEof;
            data = buf[pos..][0..data_len];
            pos += data_len;
        } else {
            // Data extends to end of packet
            data = buf[pos..];
            pos = buf.len;
        }

        return .{
            .frame = StreamFrame{
                .stream_id = stream_id,
                .offset = offset,
                .data = data,
                .fin = fin,
            },
            .consumed = pos,
        };
    }
};

/// MAX_DATA frame (0x10)
pub const MaxDataFrame = struct {
    max_data: u64,

    pub fn encode(self: MaxDataFrame, buf: []u8) FrameError!usize {
        var pos: usize = 0;
        pos += try varint.encode(0x10, buf[pos..]);
        pos += try varint.encode(self.max_data, buf[pos..]);
        return pos;
    }

    pub fn decode(buf: []const u8) FrameError!struct { frame: MaxDataFrame, consumed: usize } {
        var pos: usize = 0;

        const type_result = try varint.decode(buf[pos..]);
        pos += type_result.len;
        if (type_result.value != 0x10) return error.InvalidFrameType;

        const max_data_result = try varint.decode(buf[pos..]);
        pos += max_data_result.len;

        return .{
            .frame = .{ .max_data = max_data_result.value },
            .consumed = pos,
        };
    }
};

/// MAX_STREAM_DATA frame (0x11)
pub const MaxStreamDataFrame = struct {
    stream_id: StreamId,
    max_stream_data: u64,

    pub fn encode(self: MaxStreamDataFrame, buf: []u8) FrameError!usize {
        var pos: usize = 0;
        pos += try varint.encode(0x11, buf[pos..]);
        pos += try varint.encode(self.stream_id, buf[pos..]);
        pos += try varint.encode(self.max_stream_data, buf[pos..]);
        return pos;
    }

    pub fn decode(buf: []const u8) FrameError!struct { frame: MaxStreamDataFrame, consumed: usize } {
        var pos: usize = 0;

        const type_result = try varint.decode(buf[pos..]);
        pos += type_result.len;
        if (type_result.value != 0x11) return error.InvalidFrameType;

        const stream_id_result = try varint.decode(buf[pos..]);
        pos += stream_id_result.len;

        const max_stream_data_result = try varint.decode(buf[pos..]);
        pos += max_stream_data_result.len;

        return .{
            .frame = .{
                .stream_id = stream_id_result.value,
                .max_stream_data = max_stream_data_result.value,
            },
            .consumed = pos,
        };
    }
};

/// MAX_STREAMS frame (0x12-0x13)
pub const MaxStreamsFrame = struct {
    max_streams: u64,
    bidirectional: bool,

    pub fn encode(self: MaxStreamsFrame, buf: []u8) FrameError!usize {
        var pos: usize = 0;
        const frame_type: u64 = if (self.bidirectional) 0x12 else 0x13;
        pos += try varint.encode(frame_type, buf[pos..]);
        pos += try varint.encode(self.max_streams, buf[pos..]);
        return pos;
    }

    pub fn decode(buf: []const u8) FrameError!struct { frame: MaxStreamsFrame, consumed: usize } {
        var pos: usize = 0;

        const type_result = try varint.decode(buf[pos..]);
        pos += type_result.len;

        const bidirectional = switch (type_result.value) {
            0x12 => true,
            0x13 => false,
            else => return error.InvalidFrameType,
        };

        const max_streams_result = try varint.decode(buf[pos..]);
        pos += max_streams_result.len;

        return .{
            .frame = .{
                .max_streams = max_streams_result.value,
                .bidirectional = bidirectional,
            },
            .consumed = pos,
        };
    }
};

/// DATA_BLOCKED frame (0x14)
pub const DataBlockedFrame = struct {
    max_data: u64,

    pub fn encode(self: DataBlockedFrame, buf: []u8) FrameError!usize {
        var pos: usize = 0;
        pos += try varint.encode(0x14, buf[pos..]);
        pos += try varint.encode(self.max_data, buf[pos..]);
        return pos;
    }

    pub fn decode(buf: []const u8) FrameError!struct { frame: DataBlockedFrame, consumed: usize } {
        var pos: usize = 0;

        const type_result = try varint.decode(buf[pos..]);
        pos += type_result.len;
        if (type_result.value != 0x14) return error.InvalidFrameType;

        const max_data_result = try varint.decode(buf[pos..]);
        pos += max_data_result.len;

        return .{
            .frame = .{ .max_data = max_data_result.value },
            .consumed = pos,
        };
    }
};

/// STREAM_DATA_BLOCKED frame (0x15)
pub const StreamDataBlockedFrame = struct {
    stream_id: StreamId,
    max_stream_data: u64,

    pub fn encode(self: StreamDataBlockedFrame, buf: []u8) FrameError!usize {
        var pos: usize = 0;
        pos += try varint.encode(0x15, buf[pos..]);
        pos += try varint.encode(self.stream_id, buf[pos..]);
        pos += try varint.encode(self.max_stream_data, buf[pos..]);
        return pos;
    }

    pub fn decode(buf: []const u8) FrameError!struct { frame: StreamDataBlockedFrame, consumed: usize } {
        var pos: usize = 0;

        const type_result = try varint.decode(buf[pos..]);
        pos += type_result.len;
        if (type_result.value != 0x15) return error.InvalidFrameType;

        const stream_id_result = try varint.decode(buf[pos..]);
        pos += stream_id_result.len;

        const max_stream_data_result = try varint.decode(buf[pos..]);
        pos += max_stream_data_result.len;

        return .{
            .frame = .{
                .stream_id = stream_id_result.value,
                .max_stream_data = max_stream_data_result.value,
            },
            .consumed = pos,
        };
    }
};

/// STREAMS_BLOCKED frame (0x16-0x17)
pub const StreamsBlockedFrame = struct {
    max_streams: u64,
    bidirectional: bool,

    pub fn encode(self: StreamsBlockedFrame, buf: []u8) FrameError!usize {
        var pos: usize = 0;
        const frame_type: u64 = if (self.bidirectional) 0x16 else 0x17;
        pos += try varint.encode(frame_type, buf[pos..]);
        pos += try varint.encode(self.max_streams, buf[pos..]);
        return pos;
    }

    pub fn decode(buf: []const u8) FrameError!struct { frame: StreamsBlockedFrame, consumed: usize } {
        var pos: usize = 0;

        const type_result = try varint.decode(buf[pos..]);
        pos += type_result.len;

        const bidirectional = switch (type_result.value) {
            0x16 => true,
            0x17 => false,
            else => return error.InvalidFrameType,
        };

        const max_streams_result = try varint.decode(buf[pos..]);
        pos += max_streams_result.len;

        return .{
            .frame = .{
                .max_streams = max_streams_result.value,
                .bidirectional = bidirectional,
            },
            .consumed = pos,
        };
    }
};

/// NEW_CONNECTION_ID frame (0x18)
pub const NewConnectionIdFrame = struct {
    sequence_number: u64,
    retire_prior_to: u64,
    connection_id: ConnectionId,
    stateless_reset_token: [16]u8,

    pub fn encode(self: NewConnectionIdFrame, buf: []u8) FrameError!usize {
        var pos: usize = 0;
        pos += try varint.encode(0x18, buf[pos..]);
        pos += try varint.encode(self.sequence_number, buf[pos..]);
        pos += try varint.encode(self.retire_prior_to, buf[pos..]);

        if (pos + 1 + self.connection_id.len + 16 > buf.len) return error.BufferTooSmall;
        buf[pos] = self.connection_id.len;
        pos += 1;
        @memcpy(buf[pos..][0..self.connection_id.len], self.connection_id.slice());
        pos += self.connection_id.len;
        @memcpy(buf[pos..][0..16], &self.stateless_reset_token);
        pos += 16;

        return pos;
    }

    pub fn decode(buf: []const u8) FrameError!struct { frame: NewConnectionIdFrame, consumed: usize } {
        var pos: usize = 0;

        const type_result = try varint.decode(buf[pos..]);
        pos += type_result.len;
        if (type_result.value != 0x18) return error.InvalidFrameType;

        const sequence_result = try varint.decode(buf[pos..]);
        pos += sequence_result.len;

        const retire_prior_to_result = try varint.decode(buf[pos..]);
        pos += retire_prior_to_result.len;

        if (pos + 1 > buf.len) return error.UnexpectedEof;
        const cid_len = buf[pos];
        pos += 1;
        if (cid_len == 0 or cid_len > 20) return error.InvalidData;

        if (pos + cid_len + 16 > buf.len) return error.UnexpectedEof;
        const connection_id = ConnectionId.init(buf[pos .. pos + cid_len]) catch {
            return error.InvalidData;
        };
        pos += cid_len;

        var stateless_reset_token: [16]u8 = undefined;
        @memcpy(&stateless_reset_token, buf[pos..][0..16]);
        pos += 16;

        return .{
            .frame = .{
                .sequence_number = sequence_result.value,
                .retire_prior_to = retire_prior_to_result.value,
                .connection_id = connection_id,
                .stateless_reset_token = stateless_reset_token,
            },
            .consumed = pos,
        };
    }
};

/// RETIRE_CONNECTION_ID frame (0x19)
pub const RetireConnectionIdFrame = struct {
    sequence_number: u64,

    pub fn encode(self: RetireConnectionIdFrame, buf: []u8) FrameError!usize {
        var pos: usize = 0;
        pos += try varint.encode(0x19, buf[pos..]);
        pos += try varint.encode(self.sequence_number, buf[pos..]);
        return pos;
    }

    pub fn decode(buf: []const u8) FrameError!struct { frame: RetireConnectionIdFrame, consumed: usize } {
        var pos: usize = 0;

        const type_result = try varint.decode(buf[pos..]);
        pos += type_result.len;
        if (type_result.value != 0x19) return error.InvalidFrameType;

        const sequence_result = try varint.decode(buf[pos..]);
        pos += sequence_result.len;

        return .{
            .frame = .{ .sequence_number = sequence_result.value },
            .consumed = pos,
        };
    }
};

/// PATH_CHALLENGE frame (0x1a)
pub const PathChallengeFrame = struct {
    data: [8]u8,

    pub fn encode(self: PathChallengeFrame, buf: []u8) FrameError!usize {
        if (buf.len < 9) return error.BufferTooSmall;
        var pos: usize = 0;
        pos += try varint.encode(0x1a, buf[pos..]);
        @memcpy(buf[pos..][0..8], &self.data);
        pos += 8;
        return pos;
    }

    pub fn decode(buf: []const u8) FrameError!struct { frame: PathChallengeFrame, consumed: usize } {
        var pos: usize = 0;
        const type_result = try varint.decode(buf[pos..]);
        pos += type_result.len;
        if (type_result.value != 0x1a) return error.InvalidFrameType;

        if (pos + 8 > buf.len) return error.UnexpectedEof;
        var data: [8]u8 = undefined;
        @memcpy(&data, buf[pos..][0..8]);
        pos += 8;

        return .{ .frame = .{ .data = data }, .consumed = pos };
    }
};

/// PATH_RESPONSE frame (0x1b)
pub const PathResponseFrame = struct {
    data: [8]u8,

    pub fn encode(self: PathResponseFrame, buf: []u8) FrameError!usize {
        if (buf.len < 9) return error.BufferTooSmall;
        var pos: usize = 0;
        pos += try varint.encode(0x1b, buf[pos..]);
        @memcpy(buf[pos..][0..8], &self.data);
        pos += 8;
        return pos;
    }

    pub fn decode(buf: []const u8) FrameError!struct { frame: PathResponseFrame, consumed: usize } {
        var pos: usize = 0;
        const type_result = try varint.decode(buf[pos..]);
        pos += type_result.len;
        if (type_result.value != 0x1b) return error.InvalidFrameType;

        if (pos + 8 > buf.len) return error.UnexpectedEof;
        var data: [8]u8 = undefined;
        @memcpy(&data, buf[pos..][0..8]);
        pos += 8;

        return .{ .frame = .{ .data = data }, .consumed = pos };
    }
};

/// CONNECTION_CLOSE frame (0x1c-0x1d)
pub const ConnectionCloseFrame = struct {
    error_code: u64,
    frame_type: ?u64 = null, // Only for 0x1c (transport error)
    reason: []const u8,

    pub fn encode(self: ConnectionCloseFrame, buf: []u8) FrameError!usize {
        var pos: usize = 0;
        const type_byte: u64 = if (self.frame_type != null) 0x1c else 0x1d;
        pos += try varint.encode(type_byte, buf[pos..]);
        pos += try varint.encode(self.error_code, buf[pos..]);

        if (self.frame_type) |ft| {
            pos += try varint.encode(ft, buf[pos..]);
        }

        pos += try varint.encode(self.reason.len, buf[pos..]);
        if (pos + self.reason.len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[pos..][0..self.reason.len], self.reason);
        pos += self.reason.len;

        return pos;
    }

    pub fn decode(buf: []const u8) FrameError!struct { frame: ConnectionCloseFrame, consumed: usize } {
        var pos: usize = 0;

        const type_result = try varint.decode(buf[pos..]);
        pos += type_result.len;

        const is_transport_close = switch (type_result.value) {
            0x1c => true,
            0x1d => false,
            else => return error.InvalidFrameType,
        };

        const error_code_result = try varint.decode(buf[pos..]);
        pos += error_code_result.len;

        var frame_type: ?u64 = null;
        if (is_transport_close) {
            const frame_type_result = try varint.decode(buf[pos..]);
            pos += frame_type_result.len;
            frame_type = frame_type_result.value;
        }

        const reason_len_result = try varint.decode(buf[pos..]);
        pos += reason_len_result.len;

        const reason_len = reason_len_result.value;
        if (pos + reason_len > buf.len) return error.UnexpectedEof;

        const reason = buf[pos..][0..reason_len];
        pos += reason_len;

        return .{
            .frame = ConnectionCloseFrame{
                .error_code = error_code_result.value,
                .frame_type = frame_type,
                .reason = reason,
            },
            .consumed = pos,
        };
    }
};

/// HANDSHAKE_DONE frame (0x1e)
pub const HandshakeDoneFrame = struct {
    pub fn encode(_: HandshakeDoneFrame, buf: []u8) FrameError!usize {
        return try varint.encode(0x1e, buf);
    }

    pub fn decode(buf: []const u8) FrameError!struct { frame: HandshakeDoneFrame, consumed: usize } {
        const type_result = try varint.decode(buf);
        if (type_result.value != 0x1e) return error.InvalidFrameType;
        return .{ .frame = HandshakeDoneFrame{}, .consumed = type_result.len };
    }
};

// Tests

test "stream frame encode/decode" {
    const allocator = std.testing.allocator;
    const buf = try allocator.alloc(u8, 1024);
    defer allocator.free(buf);

    const test_data = "Hello, QUIC!";
    const frame = StreamFrame{
        .stream_id = 4,
        .offset = 100,
        .data = test_data,
        .fin = true,
    };

    const encoded_len = try frame.encode(buf);
    try std.testing.expect(encoded_len > 0);

    const result = try StreamFrame.decode(buf[0..encoded_len]);
    try std.testing.expectEqual(@as(u64, 4), result.frame.stream_id);
    try std.testing.expectEqual(@as(u64, 100), result.frame.offset);
    try std.testing.expect(result.frame.fin);
    try std.testing.expectEqualStrings(test_data, result.frame.data);
}

test "crypto frame encode" {
    var buf: [100]u8 = undefined;
    const test_data = "crypto data";
    const frame = CryptoFrame{
        .offset = 0,
        .data = test_data,
    };

    const encoded_len = try frame.encode(&buf);
    try std.testing.expect(encoded_len > 0);

    const decoded = try CryptoFrame.decode(buf[0..encoded_len]);
    try std.testing.expectEqual(frame.offset, decoded.frame.offset);
    try std.testing.expectEqualStrings(frame.data, decoded.frame.data);
    try std.testing.expectEqual(encoded_len, decoded.consumed);
}

test "padding frame decode" {
    const decoded = try PaddingFrame.decode(&[_]u8{0x00});
    try std.testing.expectEqual(@as(usize, 1), decoded.consumed);
}

test "ack frame encode" {
    const allocator = std.testing.allocator;
    const buf = try allocator.alloc(u8, 1024);
    defer allocator.free(buf);

    const frame = AckFrame{
        .largest_acked = 100,
        .ack_delay = 5,
        .first_ack_range = 10,
        .ack_ranges = &.{},
        .ecn_counts = null,
    };

    const encoded_len = try frame.encode(buf);
    try std.testing.expect(encoded_len > 0);

    const decoded = try AckFrame.decode(buf[0..encoded_len]);
    try std.testing.expectEqual(frame.largest_acked, decoded.frame.largest_acked);
}

test "ack frame decode preserves ranges" {
    var buf: [128]u8 = undefined;

    const frame = AckFrame{
        .largest_acked = 100,
        .ack_delay = 5,
        .first_ack_range = 10,
        .ack_ranges = &[_]AckFrame.AckRange{
            .{ .gap = 1, .ack_range_length = 2 },
            .{ .gap = 3, .ack_range_length = 4 },
        },
        .ecn_counts = null,
    };

    const encoded_len = try frame.encode(&buf);
    var ranges: [4]AckFrame.AckRange = undefined;
    const decoded = try AckFrame.decodeWithAckRanges(buf[0..encoded_len], &ranges);

    try std.testing.expectEqual(@as(usize, 2), decoded.frame.ack_ranges.len);
    try std.testing.expectEqual(@as(u64, 1), decoded.frame.ack_ranges[0].gap);
    try std.testing.expectEqual(@as(u64, 2), decoded.frame.ack_ranges[0].ack_range_length);
    try std.testing.expectEqual(@as(u64, 3), decoded.frame.ack_ranges[1].gap);
    try std.testing.expectEqual(@as(u64, 4), decoded.frame.ack_ranges[1].ack_range_length);
}

test "ack frame decode rejects first range larger than largest acked" {
    var buf: [64]u8 = undefined;

    const frame = AckFrame{
        .largest_acked = 3,
        .ack_delay = 0,
        .first_ack_range = 4,
        .ack_ranges = &.{},
        .ecn_counts = null,
    };

    const encoded_len = try frame.encode(&buf);
    try std.testing.expectError(error.InvalidData, AckFrame.decode(buf[0..encoded_len]));
}

test "ack frame decode rejects range underflow" {
    var buf: [64]u8 = undefined;

    const frame = AckFrame{
        .largest_acked = 10,
        .ack_delay = 0,
        .first_ack_range = 0,
        .ack_ranges = &[_]AckFrame.AckRange{
            .{ .gap = 15, .ack_range_length = 0 },
        },
        .ecn_counts = null,
    };

    const encoded_len = try frame.encode(&buf);
    var ranges: [2]AckFrame.AckRange = undefined;
    try std.testing.expectError(error.InvalidData, AckFrame.decodeWithAckRanges(buf[0..encoded_len], &ranges));
}

test "connection close frame encode" {
    var buf: [100]u8 = undefined;
    const frame = ConnectionCloseFrame{
        .error_code = 0,
        .frame_type = null,
        .reason = "goodbye",
    };

    const encoded_len = try frame.encode(&buf);
    try std.testing.expect(encoded_len > 0);

    const decoded = try ConnectionCloseFrame.decode(buf[0..encoded_len]);
    try std.testing.expectEqual(frame.error_code, decoded.frame.error_code);
    try std.testing.expectEqualStrings(frame.reason, decoded.frame.reason);
}

test "reset stream frame encode/decode" {
    var buf: [100]u8 = undefined;
    const frame = ResetStreamFrame{
        .stream_id = 8,
        .error_code = 42,
        .final_size = 12,
    };

    const encoded_len = try frame.encode(&buf);
    const decoded = try ResetStreamFrame.decode(buf[0..encoded_len]);
    try std.testing.expectEqual(frame.stream_id, decoded.frame.stream_id);
    try std.testing.expectEqual(frame.error_code, decoded.frame.error_code);
    try std.testing.expectEqual(frame.final_size, decoded.frame.final_size);
}

test "stop sending frame encode/decode" {
    var buf: [100]u8 = undefined;
    const frame = StopSendingFrame{
        .stream_id = 9,
        .error_code = 7,
    };

    const encoded_len = try frame.encode(&buf);
    const decoded = try StopSendingFrame.decode(buf[0..encoded_len]);
    try std.testing.expectEqual(frame.stream_id, decoded.frame.stream_id);
    try std.testing.expectEqual(frame.error_code, decoded.frame.error_code);
}

test "ping frame decode" {
    var buf: [8]u8 = undefined;
    const len = try varint.encode(0x01, &buf);

    const decoded = try PingFrame.decode(buf[0..len]);
    _ = decoded.frame;
    try std.testing.expectEqual(len, decoded.consumed);
}

test "path challenge frame encode/decode" {
    var buf: [32]u8 = undefined;
    const frame = PathChallengeFrame{ .data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 } };
    const len = try frame.encode(&buf);

    const decoded = try PathChallengeFrame.decode(buf[0..len]);
    try std.testing.expectEqualSlices(u8, &frame.data, &decoded.frame.data);
}

test "path response frame encode/decode" {
    var buf: [32]u8 = undefined;
    const frame = PathResponseFrame{ .data = [_]u8{ 8, 7, 6, 5, 4, 3, 2, 1 } };
    const len = try frame.encode(&buf);

    const decoded = try PathResponseFrame.decode(buf[0..len]);
    try std.testing.expectEqualSlices(u8, &frame.data, &decoded.frame.data);
}

test "max data frame encode/decode" {
    var buf: [32]u8 = undefined;
    const frame = MaxDataFrame{ .max_data = 4096 };
    const len = try frame.encode(&buf);

    const decoded = try MaxDataFrame.decode(buf[0..len]);
    try std.testing.expectEqual(frame.max_data, decoded.frame.max_data);
    try std.testing.expectEqual(len, decoded.consumed);
}

test "max stream data frame encode/decode" {
    var buf: [32]u8 = undefined;
    const frame = MaxStreamDataFrame{ .stream_id = 4, .max_stream_data = 8192 };
    const len = try frame.encode(&buf);

    const decoded = try MaxStreamDataFrame.decode(buf[0..len]);
    try std.testing.expectEqual(frame.stream_id, decoded.frame.stream_id);
    try std.testing.expectEqual(frame.max_stream_data, decoded.frame.max_stream_data);
    try std.testing.expectEqual(len, decoded.consumed);
}

test "max streams frame encode/decode bidi" {
    var buf: [32]u8 = undefined;
    const frame = MaxStreamsFrame{ .max_streams = 12, .bidirectional = true };
    const len = try frame.encode(&buf);

    const decoded = try MaxStreamsFrame.decode(buf[0..len]);
    try std.testing.expect(decoded.frame.bidirectional);
    try std.testing.expectEqual(frame.max_streams, decoded.frame.max_streams);
    try std.testing.expectEqual(len, decoded.consumed);
}

test "max streams frame encode/decode uni" {
    var buf: [32]u8 = undefined;
    const frame = MaxStreamsFrame{ .max_streams = 7, .bidirectional = false };
    const len = try frame.encode(&buf);

    const decoded = try MaxStreamsFrame.decode(buf[0..len]);
    try std.testing.expect(!decoded.frame.bidirectional);
    try std.testing.expectEqual(frame.max_streams, decoded.frame.max_streams);
    try std.testing.expectEqual(len, decoded.consumed);
}

test "data blocked frame encode/decode" {
    var buf: [32]u8 = undefined;
    const frame = DataBlockedFrame{ .max_data = 2048 };
    const len = try frame.encode(&buf);

    const decoded = try DataBlockedFrame.decode(buf[0..len]);
    try std.testing.expectEqual(frame.max_data, decoded.frame.max_data);
    try std.testing.expectEqual(len, decoded.consumed);
}

test "stream data blocked frame encode/decode" {
    var buf: [32]u8 = undefined;
    const frame = StreamDataBlockedFrame{ .stream_id = 6, .max_stream_data = 1024 };
    const len = try frame.encode(&buf);

    const decoded = try StreamDataBlockedFrame.decode(buf[0..len]);
    try std.testing.expectEqual(frame.stream_id, decoded.frame.stream_id);
    try std.testing.expectEqual(frame.max_stream_data, decoded.frame.max_stream_data);
    try std.testing.expectEqual(len, decoded.consumed);
}

test "streams blocked frame encode/decode bidi" {
    var buf: [32]u8 = undefined;
    const frame = StreamsBlockedFrame{ .max_streams = 11, .bidirectional = true };
    const len = try frame.encode(&buf);

    const decoded = try StreamsBlockedFrame.decode(buf[0..len]);
    try std.testing.expect(decoded.frame.bidirectional);
    try std.testing.expectEqual(frame.max_streams, decoded.frame.max_streams);
    try std.testing.expectEqual(len, decoded.consumed);
}

test "streams blocked frame encode/decode uni" {
    var buf: [32]u8 = undefined;
    const frame = StreamsBlockedFrame{ .max_streams = 5, .bidirectional = false };
    const len = try frame.encode(&buf);

    const decoded = try StreamsBlockedFrame.decode(buf[0..len]);
    try std.testing.expect(!decoded.frame.bidirectional);
    try std.testing.expectEqual(frame.max_streams, decoded.frame.max_streams);
    try std.testing.expectEqual(len, decoded.consumed);
}

test "new connection id frame encode/decode" {
    var buf: [128]u8 = undefined;
    const cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    const frame = NewConnectionIdFrame{
        .sequence_number = 3,
        .retire_prior_to = 2,
        .connection_id = cid,
        .stateless_reset_token = [_]u8{9} ** 16,
    };
    const len = try frame.encode(&buf);

    const decoded = try NewConnectionIdFrame.decode(buf[0..len]);
    try std.testing.expectEqual(frame.sequence_number, decoded.frame.sequence_number);
    try std.testing.expectEqual(frame.retire_prior_to, decoded.frame.retire_prior_to);
    try std.testing.expect(frame.connection_id.eql(&decoded.frame.connection_id));
    try std.testing.expectEqualSlices(u8, &frame.stateless_reset_token, &decoded.frame.stateless_reset_token);
    try std.testing.expectEqual(len, decoded.consumed);
}

test "retire connection id frame encode/decode" {
    var buf: [32]u8 = undefined;
    const frame = RetireConnectionIdFrame{ .sequence_number = 7 };
    const len = try frame.encode(&buf);

    const decoded = try RetireConnectionIdFrame.decode(buf[0..len]);
    try std.testing.expectEqual(frame.sequence_number, decoded.frame.sequence_number);
    try std.testing.expectEqual(len, decoded.consumed);
}

test "new token frame encode/decode" {
    var buf: [64]u8 = undefined;
    const frame = NewTokenFrame{ .token = "retry-token" };
    const len = try frame.encode(&buf);

    const decoded = try NewTokenFrame.decode(buf[0..len]);
    try std.testing.expectEqualStrings(frame.token, decoded.frame.token);
    try std.testing.expectEqual(len, decoded.consumed);
}

test "handshake done frame encode/decode" {
    var buf: [16]u8 = undefined;
    const frame = HandshakeDoneFrame{};
    const len = try frame.encode(&buf);

    const decoded = try HandshakeDoneFrame.decode(buf[0..len]);
    _ = decoded.frame;
    try std.testing.expectEqual(len, decoded.consumed);
}

test "stream frame decode without LEN consumes remaining payload" {
    var buf: [32]u8 = undefined;
    var pos: usize = 0;

    // STREAM frame type with FIN=0, LEN=0, OFF=0 -> 0x08
    pos += try varint.encode(0x08, buf[pos..]);
    pos += try varint.encode(7, buf[pos..]); // stream id
    @memcpy(buf[pos..][0..5], "hello");
    pos += 5;

    const decoded = try StreamFrame.decode(buf[0..pos]);
    try std.testing.expectEqual(@as(u64, 7), decoded.frame.stream_id);
    try std.testing.expectEqual(@as(u64, 0), decoded.frame.offset);
    try std.testing.expectEqualStrings("hello", decoded.frame.data);
    try std.testing.expectEqual(pos, decoded.consumed);
}

test "stream frame decode rejects oversized length claim" {
    var buf: [32]u8 = undefined;
    var pos: usize = 0;

    // STREAM with LEN flag set
    pos += try varint.encode(0x0a, buf[pos..]);
    pos += try varint.encode(1, buf[pos..]); // stream id
    pos += try varint.encode(5, buf[pos..]); // claimed data len
    @memcpy(buf[pos..][0..2], "ab");
    pos += 2;

    try std.testing.expectError(error.UnexpectedEof, StreamFrame.decode(buf[0..pos]));
}

test "ack frame decode rejects truncated ECN counts" {
    var buf: [64]u8 = undefined;
    const frame = AckFrame{
        .largest_acked = 10,
        .ack_delay = 0,
        .first_ack_range = 0,
        .ack_ranges = &.{},
        .ecn_counts = AckFrame.EcnCounts{
            .ect0_count = 1,
            .ect1_count = 2,
            .ecn_ce_count = 3,
        },
    };

    const len = try frame.encode(&buf);
    // Drop trailing CE count varint.
    try std.testing.expectError(error.UnexpectedEof, AckFrame.decode(buf[0 .. len - 1]));
}

test "ack frame decode rejects truncation across ACK range section" {
    var buf: [256]u8 = undefined;
    const frame = AckFrame{
        .largest_acked = 600,
        .ack_delay = 3,
        .first_ack_range = 5,
        .ack_ranges = &[_]AckFrame.AckRange{
            .{ .gap = 1, .ack_range_length = 2 },
            .{ .gap = 3, .ack_range_length = 4 },
            .{ .gap = 5, .ack_range_length = 6 },
        },
        .ecn_counts = null,
    };

    const len = try frame.encode(&buf);
    var ranges: [8]AckFrame.AckRange = undefined;

    var cut: usize = 1;
    while (cut < len) : (cut += 1) {
        try std.testing.expectError(error.UnexpectedEof, AckFrame.decodeWithAckRanges(buf[0..cut], &ranges));
    }

    const decoded = try AckFrame.decodeWithAckRanges(buf[0..len], &ranges);
    try std.testing.expectEqual(@as(usize, 3), decoded.frame.ack_ranges.len);
}

test "ack frame decode rejects all ECN tail truncation variants" {
    var with_ecn_buf: [128]u8 = undefined;
    const with_ecn = AckFrame{
        .largest_acked = 9,
        .ack_delay = 1,
        .first_ack_range = 0,
        .ack_ranges = &.{},
        .ecn_counts = AckFrame.EcnCounts{
            .ect0_count = 1,
            .ect1_count = 2,
            .ecn_ce_count = 3,
        },
    };
    const with_ecn_len = try with_ecn.encode(&with_ecn_buf);

    var no_ecn_buf: [128]u8 = undefined;
    const no_ecn = AckFrame{
        .largest_acked = 9,
        .ack_delay = 1,
        .first_ack_range = 0,
        .ack_ranges = &.{},
        .ecn_counts = null,
    };
    const no_ecn_len = try no_ecn.encode(&no_ecn_buf);

    // Every prefix that includes ACK fields but not full ECN tail must fail.
    var cut: usize = no_ecn_len;
    while (cut < with_ecn_len) : (cut += 1) {
        try std.testing.expectError(error.UnexpectedEof, AckFrame.decode(with_ecn_buf[0..cut]));
    }

    const decoded = try AckFrame.decode(with_ecn_buf[0..with_ecn_len]);
    try std.testing.expect(decoded.frame.ecn_counts != null);
}

test "ack frame decode reports ack range output overflow" {
    var buf: [128]u8 = undefined;
    const frame = AckFrame{
        .largest_acked = 50,
        .ack_delay = 0,
        .first_ack_range = 0,
        .ack_ranges = &[_]AckFrame.AckRange{
            .{ .gap = 0, .ack_range_length = 0 },
            .{ .gap = 0, .ack_range_length = 0 },
        },
        .ecn_counts = null,
    };

    const len = try frame.encode(&buf);
    var ranges: [1]AckFrame.AckRange = undefined;
    try std.testing.expectError(error.BufferTooSmall, AckFrame.decodeWithAckRanges(buf[0..len], &ranges));
}

test "ack frame decode supports lsquic-scale range vectors" {
    var ranges_in: [256]AckFrame.AckRange = undefined;
    for (ranges_in[0..], 0..) |*range, i| {
        range.* = .{
            .gap = @as(u64, @intCast(i % 2)),
            .ack_range_length = @as(u64, @intCast(i % 3)),
        };
    }

    // Ensure the full range chain remains valid under decode invariants.
    var current_smallest: u64 = 5_000;
    const first_ack_range: u64 = 200;
    current_smallest -= first_ack_range;
    for (ranges_in) |range| {
        const step = range.gap + 2;
        current_smallest -= step;
        current_smallest -= range.ack_range_length;
    }

    const frame = AckFrame{
        .largest_acked = 5_000,
        .ack_delay = 0,
        .first_ack_range = first_ack_range,
        .ack_ranges = ranges_in[0..],
        .ecn_counts = null,
    };

    var buf: [4096]u8 = undefined;
    const len = try frame.encode(&buf);

    var decoded_ranges: [256]AckFrame.AckRange = undefined;
    const decoded = try AckFrame.decodeWithAckRanges(buf[0..len], &decoded_ranges);
    try std.testing.expectEqual(@as(usize, 256), decoded.frame.ack_ranges.len);

    var small_out: [255]AckFrame.AckRange = undefined;
    try std.testing.expectError(error.BufferTooSmall, AckFrame.decodeWithAckRanges(buf[0..len], &small_out));
}

test "ack frame decode supports lsquic sparse history pattern" {
    var ranges_in: [256]AckFrame.AckRange = undefined;
    for (&ranges_in) |*range| {
        range.* = .{
            .gap = 8,
            .ack_range_length = 0,
        };
    }

    const frame = AckFrame{
        .largest_acked = 3_000,
        .ack_delay = 0,
        .first_ack_range = 0,
        .ack_ranges = ranges_in[0..],
        .ecn_counts = null,
    };

    var buf: [4096]u8 = undefined;
    const len = try frame.encode(&buf);

    var decoded_ranges: [256]AckFrame.AckRange = undefined;
    const decoded = try AckFrame.decodeWithAckRanges(buf[0..len], &decoded_ranges);
    try std.testing.expectEqual(@as(usize, 256), decoded.frame.ack_ranges.len);

    for (decoded.frame.ack_ranges) |range| {
        try std.testing.expectEqual(@as(u64, 8), range.gap);
        try std.testing.expectEqual(@as(u64, 0), range.ack_range_length);
    }
}

test "new connection id decode rejects invalid cid lengths" {
    var buf: [128]u8 = undefined;
    const cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const frame = NewConnectionIdFrame{
        .sequence_number = 1,
        .retire_prior_to = 0,
        .connection_id = cid,
        .stateless_reset_token = [_]u8{0xaa} ** 16,
    };
    const len = try frame.encode(&buf);

    // Zero CID length
    var zero_len = buf;
    const cid_len_index = len - (cid.len + 16) - 1;
    zero_len[cid_len_index] = 0;
    try std.testing.expectError(error.InvalidData, NewConnectionIdFrame.decode(zero_len[0..len]));

    // CID length > 20
    var oversized_len = buf;
    oversized_len[cid_len_index] = 21;
    try std.testing.expectError(error.InvalidData, NewConnectionIdFrame.decode(oversized_len[0..len]));
}

test "new connection id decode rejects truncated reset token" {
    var buf: [128]u8 = undefined;
    const cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4 });
    const frame = NewConnectionIdFrame{
        .sequence_number = 2,
        .retire_prior_to = 0,
        .connection_id = cid,
        .stateless_reset_token = [_]u8{0xbb} ** 16,
    };

    const len = try frame.encode(&buf);
    try std.testing.expectError(error.UnexpectedEof, NewConnectionIdFrame.decode(buf[0 .. len - 3]));
}

test "new connection id decode rejects lsquic-style prefix truncation matrix" {
    var buf: [256]u8 = undefined;
    const cid = try ConnectionId.init(&[_]u8{ 1, 2, 3, 4, 5, 6 });
    const frame = NewConnectionIdFrame{
        .sequence_number = 9,
        .retire_prior_to = 3,
        .connection_id = cid,
        .stateless_reset_token = [_]u8{0xCC} ** 16,
    };

    const len = try frame.encode(&buf);

    var cut: usize = 0;
    while (cut < len) : (cut += 1) {
        try std.testing.expectError(error.UnexpectedEof, NewConnectionIdFrame.decode(buf[0..cut]));
    }

    const decoded = try NewConnectionIdFrame.decode(buf[0..len]);
    try std.testing.expectEqual(@as(u64, 9), decoded.frame.sequence_number);
    try std.testing.expectEqual(@as(u64, 3), decoded.frame.retire_prior_to);
    try std.testing.expect(decoded.frame.connection_id.eql(&cid));
}

test "new token decode rejects lsquic-style prefix truncation matrix" {
    var buf: [128]u8 = undefined;
    const frame = NewTokenFrame{ .token = "token-material-123" };
    const len = try frame.encode(&buf);

    var cut: usize = 0;
    while (cut < len) : (cut += 1) {
        try std.testing.expectError(error.UnexpectedEof, NewTokenFrame.decode(buf[0..cut]));
    }

    const decoded = try NewTokenFrame.decode(buf[0..len]);
    try std.testing.expectEqualStrings("token-material-123", decoded.frame.token);
}

test "connection close decode rejects truncated reason length varint" {
    // 0x1d, error_code=0, reason_len starts with 2-byte varint prefix but truncated.
    try std.testing.expectError(
        error.UnexpectedEof,
        ConnectionCloseFrame.decode(&[_]u8{ 0x1d, 0x00, 0x40 }),
    );
}

test "connection close decode rejects truncated reason bytes" {
    // 0x1d, error_code=0, reason_len=3, but only 1 reason byte.
    try std.testing.expectError(
        error.UnexpectedEof,
        ConnectionCloseFrame.decode(&[_]u8{ 0x1d, 0x00, 0x03, 'x' }),
    );
}

test "connection close decode rejects lsquic-style prefix truncation matrix" {
    var transport_buf: [128]u8 = undefined;
    const transport_close = ConnectionCloseFrame{
        .error_code = 42,
        .frame_type = 0x10,
        .reason = "transport-close",
    };
    const transport_len = try transport_close.encode(&transport_buf);

    var app_buf: [128]u8 = undefined;
    const app_close = ConnectionCloseFrame{
        .error_code = 7,
        .frame_type = null,
        .reason = "app-close",
    };
    const app_len = try app_close.encode(&app_buf);

    var cut: usize = 0;
    while (cut < transport_len) : (cut += 1) {
        try std.testing.expectError(error.UnexpectedEof, ConnectionCloseFrame.decode(transport_buf[0..cut]));
    }

    cut = 0;
    while (cut < app_len) : (cut += 1) {
        try std.testing.expectError(error.UnexpectedEof, ConnectionCloseFrame.decode(app_buf[0..cut]));
    }

    const transport_decoded = try ConnectionCloseFrame.decode(transport_buf[0..transport_len]);
    try std.testing.expectEqual(@as(u64, 42), transport_decoded.frame.error_code);
    try std.testing.expectEqual(@as(?u64, 0x10), transport_decoded.frame.frame_type);
    try std.testing.expectEqualStrings("transport-close", transport_decoded.frame.reason);

    const app_decoded = try ConnectionCloseFrame.decode(app_buf[0..app_len]);
    try std.testing.expectEqual(@as(u64, 7), app_decoded.frame.error_code);
    try std.testing.expectEqual(@as(?u64, null), app_decoded.frame.frame_type);
    try std.testing.expectEqualStrings("app-close", app_decoded.frame.reason);
}

test "frame decode malformed corpus" {
    try std.testing.expectError(error.InvalidFrameType, HandshakeDoneFrame.decode(&[_]u8{0x01}));
    try std.testing.expectError(error.UnexpectedEof, CryptoFrame.decode(&[_]u8{ 0x06, 0x00, 0x40 }));
    try std.testing.expectError(error.UnexpectedEof, StreamFrame.decode(&[_]u8{0x0f}));
    try std.testing.expectError(error.InvalidFrameType, AckFrame.decode(&[_]u8{0x01}));
    try std.testing.expectError(error.UnexpectedEof, ConnectionCloseFrame.decode(&[_]u8{0x1c}));
    try std.testing.expectError(error.UnexpectedEof, PathChallengeFrame.decode(&[_]u8{0x1a}));
    try std.testing.expectError(error.UnexpectedEof, PathResponseFrame.decode(&[_]u8{0x1b}));
}

test "frame decode fuzz smoke" {
    var prng = std.Random.DefaultPrng.init(0xF00D1234);
    const rand = prng.random();

    var buf: [128]u8 = undefined;
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        rand.bytes(&buf);
        const len: usize = rand.intRangeAtMost(usize, 1, buf.len);
        const sample = buf[0..len];

        const type_result = varint.decode(sample) catch continue;
        const frame_type = type_result.value;

        if (types.FrameType.isStreamFrame(frame_type)) {
            _ = StreamFrame.decode(sample) catch continue;
            continue;
        }

        switch (frame_type) {
            0x00 => _ = PaddingFrame.decode(sample) catch continue,
            0x01 => _ = PingFrame.decode(sample) catch continue,
            0x02, 0x03 => _ = AckFrame.decode(sample) catch continue,
            0x04 => _ = ResetStreamFrame.decode(sample) catch continue,
            0x05 => _ = StopSendingFrame.decode(sample) catch continue,
            0x06 => _ = CryptoFrame.decode(sample) catch continue,
            0x10 => _ = MaxDataFrame.decode(sample) catch continue,
            0x11 => _ = MaxStreamDataFrame.decode(sample) catch continue,
            0x12, 0x13 => _ = MaxStreamsFrame.decode(sample) catch continue,
            0x14 => _ = DataBlockedFrame.decode(sample) catch continue,
            0x15 => _ = StreamDataBlockedFrame.decode(sample) catch continue,
            0x16, 0x17 => _ = StreamsBlockedFrame.decode(sample) catch continue,
            0x18 => _ = NewConnectionIdFrame.decode(sample) catch continue,
            0x19 => _ = RetireConnectionIdFrame.decode(sample) catch continue,
            0x1a => _ = PathChallengeFrame.decode(sample) catch continue,
            0x1b => _ = PathResponseFrame.decode(sample) catch continue,
            0x1c, 0x1d => _ = ConnectionCloseFrame.decode(sample) catch continue,
            0x1e => _ = HandshakeDoneFrame.decode(sample) catch continue,
            else => {},
        }
    }
}
