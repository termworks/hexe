const std = @import("std");
const SessionChannel = @import("session.zig").SessionChannel;
const channel_protocol = @import("../protocol/channel.zig");

const PacketAction = enum {
    keep_reading,
    stop,
};

pub const ExecResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_status: ?u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ExecResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

/// Collect exec output from a session channel until EOF/CLOSE.
/// Returns aggregated stdout, stderr, and optional exit-status.
pub fn collectExecResult(
    allocator: std.mem.Allocator,
    session: *SessionChannel,
    poll_timeout_ms: u32,
) !ExecResult {
    var stdout_buf: std.ArrayList(u8) = .empty;
    errdefer stdout_buf.deinit(allocator);

    var stderr_buf: std.ArrayList(u8) = .empty;
    errdefer stderr_buf.deinit(allocator);

    var exit_status: ?u32 = null;
    var buffer: [65536]u8 = undefined;

    while (true) {
        session.manager.transport.poll(poll_timeout_ms) catch {};

        const len = session.manager.transport.receiveFromStream(session.stream_id, &buffer) catch |err| {
            if (err == error.NoData) continue;
            if (err == error.EndOfStream) break;
            return err;
        };
        if (len == 0) continue;

        const packet = buffer[0..len];
        if (packet.len == 0) continue;

        const action = try consumePacket(
            allocator,
            packet,
            &stdout_buf,
            &stderr_buf,
            &exit_status,
        );
        if (action == .stop) {
            break;
        }
    }

    return .{
        .stdout = try stdout_buf.toOwnedSlice(allocator),
        .stderr = try stderr_buf.toOwnedSlice(allocator),
        .exit_status = exit_status,
        .allocator = allocator,
    };
}

fn consumePacket(
    allocator: std.mem.Allocator,
    packet: []const u8,
    stdout_buf: *std.ArrayList(u8),
    stderr_buf: *std.ArrayList(u8),
    exit_status: *?u32,
) !PacketAction {
    switch (packet[0]) {
        94 => {
            var msg = try channel_protocol.ChannelData.decode(allocator, packet);
            defer msg.deinit(allocator);
            try stdout_buf.appendSlice(allocator, msg.data);
        },
        95 => {
            var msg = try channel_protocol.ChannelExtendedData.decode(allocator, packet);
            defer msg.deinit(allocator);
            if (msg.data_type_code == 1) {
                try stderr_buf.appendSlice(allocator, msg.data);
            } else {
                try stdout_buf.appendSlice(allocator, msg.data);
            }
        },
        98 => {
            var req = try channel_protocol.ChannelRequest.decode(allocator, packet);
            defer req.deinit(allocator);
            if (std.mem.eql(u8, req.request_type, "exit-status") and req.type_specific_data.len >= 4) {
                exit_status.* = std.mem.readInt(u32, req.type_specific_data[0..4], .big);
            }
        },
        96, 97 => return .stop,
        else => {},
    }

    return .keep_reading;
}

test "consumePacket aggregates stdout and stderr" {
    const allocator = std.testing.allocator;

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    var exit_status: ?u32 = null;

    const data_packet = try (channel_protocol.ChannelData{ .data = "hello " }).encode(allocator);
    defer allocator.free(data_packet);
    _ = try consumePacket(allocator, data_packet, &stdout_buf, &stderr_buf, &exit_status);

    const stderr_packet = try (channel_protocol.ChannelExtendedData{ .data_type_code = 1, .data = "oops" }).encode(allocator);
    defer allocator.free(stderr_packet);
    _ = try consumePacket(allocator, stderr_packet, &stdout_buf, &stderr_buf, &exit_status);

    const stdout_ext_packet = try (channel_protocol.ChannelExtendedData{ .data_type_code = 42, .data = "world" }).encode(allocator);
    defer allocator.free(stdout_ext_packet);
    _ = try consumePacket(allocator, stdout_ext_packet, &stdout_buf, &stderr_buf, &exit_status);

    try std.testing.expectEqualStrings("hello world", stdout_buf.items);
    try std.testing.expectEqualStrings("oops", stderr_buf.items);
    try std.testing.expectEqual(@as(?u32, null), exit_status);
}

test "consumePacket reads exit-status and stop markers" {
    const allocator = std.testing.allocator;

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    var exit_status: ?u32 = null;

    var status_data: [4]u8 = undefined;
    std.mem.writeInt(u32, &status_data, 17, .big);
    const status_packet = try (channel_protocol.ChannelRequest{
        .request_type = "exit-status",
        .want_reply = false,
        .type_specific_data = &status_data,
    }).encode(allocator);
    defer allocator.free(status_packet);

    const keep_action = try consumePacket(allocator, status_packet, &stdout_buf, &stderr_buf, &exit_status);
    try std.testing.expectEqual(PacketAction.keep_reading, keep_action);
    try std.testing.expectEqual(@as(?u32, 17), exit_status);

    const eof_action = try consumePacket(allocator, &[_]u8{96}, &stdout_buf, &stderr_buf, &exit_status);
    try std.testing.expectEqual(PacketAction.stop, eof_action);

    const close_action = try consumePacket(allocator, &[_]u8{97}, &stdout_buf, &stderr_buf, &exit_status);
    try std.testing.expectEqual(PacketAction.stop, close_action);
}
