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

fn expectProtocolViolationFromShortHeaderPayload(
    conn: *QuicConnection,
    allocator: std.mem.Allocator,
    payload: []const u8,
    packet_number: u64,
) !void {
    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [512]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = packet_number,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    if (packet_len + payload.len > packet_buf.len) {
        return error.BufferTooSmall;
    }
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

test "poll detects stateless reset pattern on short header failure" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    const peer_cid = try core_types.ConnectionId.init(&[_]u8{ 7, 7, 7, 7 });
    try std.testing.expect(
        try conn.internal_conn.?.onNewConnectionId(1, 0, peer_cid, [_]u8{ 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19 }),
    );

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 49,
        .key_phase = false,
    };
    var packet_len = try header.encode(&packet_buf);

    packet_buf[packet_len] = 0x1f;
    packet_len += 1;

    const reset_token = [_]u8{ 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19 };
    @memcpy(packet_buf[packet_len .. packet_len + reset_token.len], &reset_token);
    packet_len += reset_token.len;

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.no_error)),
        event.?.closing.error_code,
    );
    try std.testing.expectEqualStrings("stateless reset", event.?.closing.reason);
}

test "poll detects stateless reset before header decode succeeds" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    const local_cid = try core_types.ConnectionId.init(&[_]u8{
        1,  2,  3,  4,  5,  6,  7,  8,  9,  10,
        11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
    });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 9, 9, 9, 9 });
    const replacement_conn = try allocator.create(conn_internal.Connection);
    replacement_conn.* = try conn_internal.Connection.initClient(allocator, .ssh, local_cid, remote_cid);
    replacement_conn.markEstablished();

    if (conn.internal_conn) |old| {
        old.deinit();
        allocator.destroy(old);
    }
    conn.internal_conn = replacement_conn;
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    const peer_cid = try core_types.ConnectionId.init(&[_]u8{ 7, 7, 7, 7 });
    try std.testing.expect(
        try conn.internal_conn.?.onNewConnectionId(1, 0, peer_cid, [_]u8{ 0xde, 0xad, 0xbe, 0xef, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }),
    );

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [32]u8 = [_]u8{0} ** 32;
    packet_buf[0] = 0x43;

    const reset_token = [_]u8{ 0xde, 0xad, 0xbe, 0xef, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    @memcpy(packet_buf[1..16], &[_]u8{0} ** 15);
    @memcpy(packet_buf[16..32], &reset_token);

    _ = try sender.sendTo(packet_buf[0..32], local_addr);
    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.no_error)),
        event.?.closing.error_code,
    );
    try std.testing.expectEqualStrings("stateless reset", event.?.closing.reason);
}

test "poll rejects RETIRE_CONNECTION_ID frame in zero_rtt packet space" {
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
    const header = packet_mod.LongHeader{
        .packet_type = .zero_rtt,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 4,
        .packet_number = 34,
    };
    var packet_len = try header.encode(&packet_buf);
    packet_buf[packet_len] = 0x19;
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

test "poll routes NEW_CONNECTION_ID frame and tracks peer CID" {
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
        .packet_number = 35,
        .key_phase = false,
    };
    var packet_len = try header.encode(&packet_buf);
    const new_cid = try core_types.ConnectionId.init(&[_]u8{ 9, 8, 7, 6 });
    const frame = frame_mod.NewConnectionIdFrame{
        .sequence_number = 1,
        .retire_prior_to = 0,
        .connection_id = new_cid,
        .stateless_reset_token = [_]u8{7} ** 16,
    };
    packet_len += try frame.encode(packet_buf[packet_len..]);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    try std.testing.expect(conn.nextEvent() == null);
    try std.testing.expectEqual(types_mod.ConnectionState.established, conn.getState());
    try std.testing.expectEqual(@as(usize, 1), conn.getPeerConnectionIdCount());

    const info = conn.getPeerConnectionIdInfo(0);
    try std.testing.expect(info != null);
    try std.testing.expectEqual(@as(u64, 1), info.?.sequence_number);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 9, 8, 7, 6 }, info.?.connection_id[0..info.?.connection_id_len]);
}

test "poll rejects invalid NEW_CONNECTION_ID retire_prior_to ordering" {
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
        .packet_number = 41,
        .key_phase = false,
    };
    var packet_len = try header.encode(&packet_buf);
    const cid = try core_types.ConnectionId.init(&[_]u8{ 4, 4, 4, 4 });
    const frame = frame_mod.NewConnectionIdFrame{
        .sequence_number = 1,
        .retire_prior_to = 2,
        .connection_id = cid,
        .stateless_reset_token = [_]u8{1} ** 16,
    };
    packet_len += try frame.encode(packet_buf[packet_len..]);

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

test "poll rejects NEW_CONNECTION_ID frames exceeding active_connection_id_limit" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var remote = conn.internal_conn.?.remote_params orelse core_types.TransportParameters{};
    remote.active_connection_id_limit = 1;
    conn.internal_conn.?.setRemoteParams(remote);

    const cid1 = try core_types.ConnectionId.init(&[_]u8{ 7, 7, 7, 1 });
    const cid2 = try core_types.ConnectionId.init(&[_]u8{ 7, 7, 7, 2 });

    var payload: [192]u8 = undefined;
    var payload_len: usize = 0;
    const frame1 = frame_mod.NewConnectionIdFrame{
        .sequence_number = 1,
        .retire_prior_to = 0,
        .connection_id = cid1,
        .stateless_reset_token = [_]u8{1} ** 16,
    };
    payload_len += try frame1.encode(payload[payload_len..]);

    const frame2 = frame_mod.NewConnectionIdFrame{
        .sequence_number = 2,
        .retire_prior_to = 0,
        .connection_id = cid2,
        .stateless_reset_token = [_]u8{2} ** 16,
    };
    payload_len += try frame2.encode(payload[payload_len..]);

    try expectProtocolViolationFromShortHeaderPayload(&conn, allocator, payload[0..payload_len], 52);
}

test "poll rejects NEW_CONNECTION_ID with duplicate stateless reset token" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var remote = conn.internal_conn.?.remote_params orelse core_types.TransportParameters{};
    remote.active_connection_id_limit = 8;
    conn.internal_conn.?.setRemoteParams(remote);

    const token = [_]u8{9} ** 16;
    const cid1 = try core_types.ConnectionId.init(&[_]u8{ 8, 8, 8, 1 });
    const cid2 = try core_types.ConnectionId.init(&[_]u8{ 8, 8, 8, 2 });

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 53,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    const frame1 = frame_mod.NewConnectionIdFrame{
        .sequence_number = 1,
        .retire_prior_to = 0,
        .connection_id = cid1,
        .stateless_reset_token = token,
    };
    packet_len += try frame1.encode(packet_buf[packet_len..]);
    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();
    while (conn.nextEvent()) |_| {}

    var payload: [192]u8 = undefined;
    var payload_len: usize = 0;
    const frame2 = frame_mod.NewConnectionIdFrame{
        .sequence_number = 2,
        .retire_prior_to = 0,
        .connection_id = cid2,
        .stateless_reset_token = token,
    };
    payload_len += try frame2.encode(payload[payload_len..]);
    payload[payload_len] = 0x00;
    payload_len += 1;

    try expectProtocolViolationFromShortHeaderPayload(&conn, allocator, payload[0..payload_len], 53);
}

test "poll rejects RETIRE_CONNECTION_ID sequence beyond observed range" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    var payload: [32]u8 = undefined;
    const frame = frame_mod.RetireConnectionIdFrame{ .sequence_number = 42 };
    const payload_len = try frame.encode(&payload);

    try expectProtocolViolationFromShortHeaderPayload(&conn, allocator, payload[0..payload_len], 54);
}

test "poll deduplicates retire queue for repeated stale NEW_CONNECTION_ID" {
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
        .packet_number = 55,
        .key_phase = false,
    };

    var packet_len = try header.encode(&packet_buf);
    const fresh_cid = try core_types.ConnectionId.init(&[_]u8{ 6, 6, 6, 3 });
    const fresh = frame_mod.NewConnectionIdFrame{
        .sequence_number = 3,
        .retire_prior_to = 3,
        .connection_id = fresh_cid,
        .stateless_reset_token = [_]u8{3} ** 16,
    };
    packet_len += try fresh.encode(packet_buf[packet_len..]);
    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();
    while (conn.nextEvent()) |_| {}

    packet_len = try header.encode(&packet_buf);
    const stale_cid = try core_types.ConnectionId.init(&[_]u8{ 6, 6, 6, 1 });
    const stale = frame_mod.NewConnectionIdFrame{
        .sequence_number = 1,
        .retire_prior_to = 1,
        .connection_id = stale_cid,
        .stateless_reset_token = [_]u8{4} ** 16,
    };
    packet_len += try stale.encode(packet_buf[packet_len..]);
    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();
    while (conn.nextEvent()) |_| {}

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();
    while (conn.nextEvent()) |_| {}

    try std.testing.expectEqual(@as(?u64, 1), conn.popRetireConnectionId());
    try std.testing.expectEqual(@as(?u64, null), conn.popRetireConnectionId());
}

test "getPeerConnectionIdInfo returns null for out-of-range index" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    try std.testing.expectEqual(@as(usize, 0), conn.getPeerConnectionIdCount());
    try std.testing.expect(conn.getPeerConnectionIdInfo(0) == null);
}

test "poll queues RETIRE_CONNECTION_ID sequence and API can pop it" {
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

    var packet_buf_a: [256]u8 = undefined;
    const header_a = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 42,
        .key_phase = false,
    };
    var packet_len_a = try header_a.encode(&packet_buf_a);
    const cid0 = try core_types.ConnectionId.init(&[_]u8{ 1, 1, 1, 1 });
    const frame0 = frame_mod.NewConnectionIdFrame{
        .sequence_number = 0,
        .retire_prior_to = 0,
        .connection_id = cid0,
        .stateless_reset_token = [_]u8{2} ** 16,
    };
    packet_len_a += try frame0.encode(packet_buf_a[packet_len_a..]);
    _ = try sender.sendTo(packet_buf_a[0..packet_len_a], local_addr);
    try conn.poll();
    while (conn.nextEvent()) |_| {}

    var packet_buf_b: [256]u8 = undefined;
    const header_b = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 43,
        .key_phase = false,
    };
    var packet_len_b = try header_b.encode(&packet_buf_b);
    const cid1 = try core_types.ConnectionId.init(&[_]u8{ 2, 2, 2, 2 });
    const frame1 = frame_mod.NewConnectionIdFrame{
        .sequence_number = 1,
        .retire_prior_to = 1,
        .connection_id = cid1,
        .stateless_reset_token = [_]u8{3} ** 16,
    };
    packet_len_b += try frame1.encode(packet_buf_b[packet_len_b..]);
    _ = try sender.sendTo(packet_buf_b[0..packet_len_b], local_addr);
    try conn.poll();
    while (conn.nextEvent()) |_| {}

    const retire_seq = conn.popRetireConnectionId();
    try std.testing.expect(retire_seq != null);
    try std.testing.expectEqual(@as(u64, 0), retire_seq.?);
    try std.testing.expect(conn.popRetireConnectionId() == null);
}

test "popRetireConnectionIdFrame encodes pending retire request" {
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

    var packet_buf_a: [256]u8 = undefined;
    const header_a = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 44,
        .key_phase = false,
    };
    var packet_len_a = try header_a.encode(&packet_buf_a);

    const cid0 = try core_types.ConnectionId.init(&[_]u8{ 3, 3, 3, 3 });
    const frame0 = frame_mod.NewConnectionIdFrame{
        .sequence_number = 0,
        .retire_prior_to = 0,
        .connection_id = cid0,
        .stateless_reset_token = [_]u8{5} ** 16,
    };
    packet_len_a += try frame0.encode(packet_buf_a[packet_len_a..]);
    _ = try sender.sendTo(packet_buf_a[0..packet_len_a], local_addr);
    try conn.poll();
    while (conn.nextEvent()) |_| {}

    var packet_buf_b: [256]u8 = undefined;
    const header_b = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 45,
        .key_phase = false,
    };
    var packet_len_b = try header_b.encode(&packet_buf_b);

    const cid1 = try core_types.ConnectionId.init(&[_]u8{ 4, 4, 4, 4 });
    const frame1 = frame_mod.NewConnectionIdFrame{
        .sequence_number = 1,
        .retire_prior_to = 1,
        .connection_id = cid1,
        .stateless_reset_token = [_]u8{6} ** 16,
    };
    packet_len_b += try frame1.encode(packet_buf_b[packet_len_b..]);

    _ = try sender.sendTo(packet_buf_b[0..packet_len_b], local_addr);
    try conn.poll();
    while (conn.nextEvent()) |_| {}

    var out: [32]u8 = undefined;
    const encoded_len = try conn.popRetireConnectionIdFrame(&out);
    try std.testing.expect(encoded_len != null);

    const decoded = try frame_mod.RetireConnectionIdFrame.decode(out[0..encoded_len.?]);
    try std.testing.expectEqual(@as(u64, 0), decoded.frame.sequence_number);
    try std.testing.expect((try conn.popRetireConnectionIdFrame(&out)) == null);
}

test "queueNewConnectionId and encodeLatestNewConnectionIdFrame" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;

    const seq = try conn.queueNewConnectionId(&[_]u8{ 9, 9, 9, 9 }, [_]u8{8} ** 16);
    try std.testing.expectEqual(@as(u64, 1), seq);
    try conn.advanceLocalRetirePriorTo(1);

    var out: [128]u8 = undefined;
    const encoded_len = try conn.encodeLatestNewConnectionIdFrame(&out);
    try std.testing.expect(encoded_len != null);

    const decoded = try frame_mod.NewConnectionIdFrame.decode(out[0..encoded_len.?]);
    try std.testing.expectEqual(@as(u64, 1), decoded.frame.sequence_number);
    try std.testing.expectEqual(@as(u64, 1), decoded.frame.retire_prior_to);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 9, 9, 9, 9 }, decoded.frame.connection_id.slice());
    try std.testing.expectEqualSlices(u8, &([_]u8{8} ** 16), &decoded.frame.stateless_reset_token);
}

test "popNewConnectionIdFrame drains pending NEW_CONNECTION_ID adverts in order" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;

    const seq1 = try conn.queueNewConnectionId(&[_]u8{ 7, 7, 7, 1 }, [_]u8{1} ** 16);
    const seq2 = try conn.queueNewConnectionId(&[_]u8{ 7, 7, 7, 2 }, [_]u8{2} ** 16);
    try std.testing.expectEqual(@as(u64, 1), seq1);
    try std.testing.expectEqual(@as(u64, 2), seq2);

    var out: [128]u8 = undefined;

    const len1 = try conn.popNewConnectionIdFrame(&out);
    try std.testing.expect(len1 != null);
    const decoded1 = try frame_mod.NewConnectionIdFrame.decode(out[0..len1.?]);
    try std.testing.expectEqual(@as(u64, 1), decoded1.frame.sequence_number);

    const len2 = try conn.popNewConnectionIdFrame(&out);
    try std.testing.expect(len2 != null);
    const decoded2 = try frame_mod.NewConnectionIdFrame.decode(out[0..len2.?]);
    try std.testing.expectEqual(@as(u64, 2), decoded2.frame.sequence_number);

    try std.testing.expect((try conn.popNewConnectionIdFrame(&out)) == null);
}

test "popCidControlFrames coalesces RETIRE and NEW_CONNECTION_ID" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    const peer_cid0 = try core_types.ConnectionId.init(&[_]u8{ 1, 1, 1, 1 });
    const peer_cid1 = try core_types.ConnectionId.init(&[_]u8{ 2, 2, 2, 2 });
    try std.testing.expect(try conn.internal_conn.?.onNewConnectionId(0, 0, peer_cid0, [_]u8{3} ** 16));
    try std.testing.expect(try conn.internal_conn.?.onNewConnectionId(1, 1, peer_cid1, [_]u8{4} ** 16));

    _ = try conn.queueNewConnectionId(&[_]u8{ 9, 9, 9, 9 }, [_]u8{8} ** 16);

    var out: [256]u8 = undefined;
    const total_len = try conn.popCidControlFrames(&out);
    try std.testing.expect(total_len != null);

    const retire = try frame_mod.RetireConnectionIdFrame.decode(out[0..total_len.?]);
    try std.testing.expectEqual(@as(u64, 0), retire.frame.sequence_number);

    const new_cid = try frame_mod.NewConnectionIdFrame.decode(out[retire.consumed..total_len.?]);
    try std.testing.expectEqual(@as(u64, 1), new_cid.frame.sequence_number);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 9, 9, 9, 9 }, new_cid.frame.connection_id.slice());

    try std.testing.expect((try conn.popCidControlFrames(&out)) == null);
}

test "popAllCidControlFrames drains pending CID payloads into array" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);
    conn.internal_conn.?.markEstablished();
    conn.state = .established;
    try applyDefaultPeerTransportParams(&conn, allocator);

    const peer_cid0 = try core_types.ConnectionId.init(&[_]u8{ 1, 1, 1, 1 });
    const peer_cid1 = try core_types.ConnectionId.init(&[_]u8{ 2, 2, 2, 2 });
    try std.testing.expect(try conn.internal_conn.?.onNewConnectionId(0, 0, peer_cid0, [_]u8{3} ** 16));
    try std.testing.expect(try conn.internal_conn.?.onNewConnectionId(1, 1, peer_cid1, [_]u8{4} ** 16));

    _ = try conn.queueNewConnectionId(&[_]u8{ 9, 9, 9, 1 }, [_]u8{7} ** 16);
    _ = try conn.queueNewConnectionId(&[_]u8{ 9, 9, 9, 2 }, [_]u8{8} ** 16);

    var buf1: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    var out_frames = [_][]u8{ buf1[0..], buf2[0..] };

    const filled = try conn.popAllCidControlFrames(out_frames[0..]);
    try std.testing.expectEqual(@as(usize, 2), filled);

    const first_retire = try frame_mod.RetireConnectionIdFrame.decode(out_frames[0]);
    try std.testing.expectEqual(@as(u64, 0), first_retire.frame.sequence_number);
    const first_new = try frame_mod.NewConnectionIdFrame.decode(out_frames[0][first_retire.consumed..]);
    try std.testing.expectEqual(@as(u64, 1), first_new.frame.sequence_number);

    const second_new = try frame_mod.NewConnectionIdFrame.decode(out_frames[1]);
    try std.testing.expectEqual(@as(u64, 2), second_new.frame.sequence_number);
}
