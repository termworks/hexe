const std = @import("std");

const QuicConnection = @import("connection.zig").QuicConnection;
const config_mod = @import("config.zig");
const types_mod = @import("types.zig");
const core_types = @import("../core/types.zig");
const conn_internal = @import("../core/connection.zig");
const packet_mod = @import("../core/packet.zig");
const frame_mod = @import("../core/frame.zig");
const transport_params_mod = @import("../core/transport_params.zig");
const udp_mod = @import("../transport/udp.zig");

fn applyDefaultPeerTransportParams(conn: *QuicConnection, allocator: std.mem.Allocator) !void {
    const encoded = try transport_params_mod.TransportParams.defaultServer().encode(allocator);
    defer allocator.free(encoded);
    try conn.applyPeerTransportParams(encoded);
}

fn expectProtocolViolationFromLongHeaderPayload(
    conn: *QuicConnection,
    allocator: std.mem.Allocator,
    packet_type: core_types.PacketType,
    payload: []const u8,
    packet_number: u64,
) !void {
    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = packet_type,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = @as(u64, payload.len + 4),
        .packet_number = packet_number,
    };

    var packet_len = try header.encode(&packet_buf);
    if (packet_len + payload.len > packet_buf.len) return error.BufferTooSmall;
    @memcpy(packet_buf[packet_len .. packet_len + payload.len], payload);
    packet_len += payload.len;

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    var closing: ?types_mod.ConnectionEvent = null;
    while (conn.nextEvent()) |event| {
        if (event == .closing) {
            closing = event;
            break;
        }
    }

    try std.testing.expect(closing != null);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        closing.?.closing.error_code,
    );
}

test "poll rejects HANDSHAKE_DONE frame in Initial packet space" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    try expectProtocolViolationFromLongHeaderPayload(
        &conn,
        allocator,
        .initial,
        &[_]u8{0x1e},
        25,
    );
}

test "poll rejects HANDSHAKE_DONE frame in Handshake packet space" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    try expectProtocolViolationFromLongHeaderPayload(
        &conn,
        allocator,
        .handshake,
        &[_]u8{0x1e},
        26,
    );
}

test "poll allows HANDSHAKE_DONE frame in application packet space" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 27,
        .key_phase = false,
    };
    var packet_len = try header.encode(&packet_buf);
    packet_buf[packet_len] = 0x1e;
    packet_len += 1;

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    try std.testing.expect(conn.nextEvent() == null);
    try std.testing.expectEqual(types_mod.ConnectionState.established, conn.getState());
}

test "poll rejects HANDSHAKE_DONE frame in application packet space for server" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshServer("secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.accept("127.0.0.1", 0);

    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 4, 4, 4, 4 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 6, 6, 6, 6 });
    const internal_conn = try allocator.create(conn_internal.Connection);
    internal_conn.* = try conn_internal.Connection.initServer(allocator, .ssh, local_cid, remote_cid);
    internal_conn.markEstablished();

    if (conn.internal_conn) |old| {
        old.deinit();
        allocator.destroy(old);
    }
    conn.internal_conn = internal_conn;
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = local_cid,
        .packet_number = 28,
        .key_phase = false,
    };
    var packet_len = try header.encode(&packet_buf);
    packet_buf[packet_len] = 0x1e;
    packet_len += 1;

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        event.?.closing.error_code,
    );
}
