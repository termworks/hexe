const std = @import("std");
const types_mod = @import("types.zig");
const connection_mod = @import("connection.zig");

/// Public QUIC stream handle
///
/// Provides a convenient interface for working with streams.
/// Wraps a connection and stream ID.
pub const QuicStream = struct {
    connection: *connection_mod.QuicConnection,
    stream_id: types_mod.StreamId,
    is_bidirectional: bool,

    /// Create stream handle from connection and stream ID
    pub fn init(
        connection: *connection_mod.QuicConnection,
        stream_id: types_mod.StreamId,
        is_bidirectional: bool,
    ) QuicStream {
        return QuicStream{
            .connection = connection,
            .stream_id = stream_id,
            .is_bidirectional = is_bidirectional,
        };
    }

    /// Write data to the stream
    pub fn write(self: *QuicStream, data: []const u8) types_mod.QuicError!usize {
        return self.connection.streamWrite(self.stream_id, data, .no_finish);
    }

    /// Write data and finish the stream
    pub fn writeAndFinish(self: *QuicStream, data: []const u8) types_mod.QuicError!usize {
        return self.connection.streamWrite(self.stream_id, data, .finish);
    }

    /// Finish the stream (close send side)
    pub fn finish(self: *QuicStream) types_mod.QuicError!void {
        _ = try self.connection.streamWrite(self.stream_id, &[_]u8{}, .finish);
    }

    /// Read data from the stream
    pub fn read(self: *QuicStream, buffer: []u8) types_mod.QuicError!usize {
        return self.connection.streamRead(self.stream_id, buffer);
    }

    /// Read all available data
    pub fn readAll(
        self: *QuicStream,
        allocator: std.mem.Allocator,
        max_size: usize,
    ) types_mod.QuicError![]u8 {
        var data: std.ArrayList(u8) = .{};
        errdefer data.deinit(allocator);

        var buffer: [4096]u8 = undefined;
        while (data.items.len < max_size) {
            const read_size = @min(buffer.len, max_size - data.items.len);
            const n = try self.read(buffer[0..read_size]);
            if (n == 0) break;

            try data.appendSlice(allocator, buffer[0..n]);
        }

        return data.toOwnedSlice(allocator);
    }

    /// Write string (convenience)
    pub fn writeString(self: *QuicStream, s: []const u8) types_mod.QuicError!usize {
        return self.write(s);
    }

    /// Write formatted string
    pub fn writeFormat(
        self: *QuicStream,
        allocator: std.mem.Allocator,
        comptime fmt: []const u8,
        args: anytype,
    ) types_mod.QuicError!usize {
        const s = std.fmt.allocPrint(allocator, fmt, args) catch {
            return types_mod.QuicError.OutOfMemory;
        };
        defer allocator.free(s);

        return self.write(s);
    }

    /// Close the stream
    pub fn close(self: *QuicStream, error_code: u64) types_mod.QuicError!void {
        try self.connection.closeStream(self.stream_id, error_code);
    }

    /// Get stream information
    pub fn getInfo(self: *QuicStream) types_mod.QuicError!types_mod.StreamInfo {
        return self.connection.getStreamInfo(self.stream_id);
    }

    /// Check if stream can send data
    pub fn canSend(self: *QuicStream) types_mod.QuicError!bool {
        const info = try self.getInfo();
        return info.state.canSend();
    }

    /// Check if stream can receive data
    pub fn canReceive(self: *QuicStream) types_mod.QuicError!bool {
        const info = try self.getInfo();
        return info.state.canReceive();
    }

    /// Get stream ID
    pub fn getId(self: QuicStream) types_mod.StreamId {
        return self.stream_id;
    }

    /// Check if stream is bidirectional
    pub fn isBidirectional(self: QuicStream) bool {
        return self.is_bidirectional;
    }
};

/// Stream builder for fluent API
pub const StreamBuilder = struct {
    connection: *connection_mod.QuicConnection,
    bidirectional: bool = true,

    pub fn init(connection: *connection_mod.QuicConnection) StreamBuilder {
        return StreamBuilder{
            .connection = connection,
        };
    }

    pub fn setBidirectional(self: *StreamBuilder, value: bool) *StreamBuilder {
        self.bidirectional = value;
        return self;
    }

    pub fn open(self: StreamBuilder) types_mod.QuicError!QuicStream {
        const stream_id = try self.connection.openStream(self.bidirectional);
        return QuicStream.init(self.connection, stream_id, self.bidirectional);
    }
};

// Tests

test "Stream builder" {
    const allocator = std.testing.allocator;
    const config_mod = @import("config.zig");

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try connection_mod.QuicConnection.init(allocator, config);
    defer conn.deinit();

    var builder = StreamBuilder.init(&conn);
    _ = builder.setBidirectional(true);

    // Can't actually open stream without established connection
    // Just test the builder API
    try std.testing.expect(builder.bidirectional);
}

test "Stream ID and type" {
    const allocator = std.testing.allocator;
    const config_mod = @import("config.zig");

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try connection_mod.QuicConnection.init(allocator, config);
    defer conn.deinit();

    const stream = QuicStream.init(&conn, 4, true);

    try std.testing.expectEqual(@as(types_mod.StreamId, 4), stream.getId());
    try std.testing.expect(stream.isBidirectional());
}

test "Unidirectional stream" {
    const allocator = std.testing.allocator;
    const config_mod = @import("config.zig");

    const config = config_mod.QuicConfig.sshClient("example.com", "secret");
    var conn = try connection_mod.QuicConnection.init(allocator, config);
    defer conn.deinit();

    const stream = QuicStream.init(&conn, 2, false);

    try std.testing.expect(!stream.isBidirectional());
}
