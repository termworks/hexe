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

const RetryIntegrityExpectation = struct {
    token: []const u8,
    retry_scid: []const u8,
};

fn retryIntegrityValidator(
    ctx: ?*anyopaque,
    token: []const u8,
    retry_source_conn_id: core_types.ConnectionId,
) bool {
    const expectation_ptr = ctx orelse return false;
    const expectation: *const RetryIntegrityExpectation = @ptrCast(@alignCast(expectation_ptr));

    return std.mem.eql(u8, expectation.token, token) and
        std.mem.eql(u8, expectation.retry_scid, retry_source_conn_id.slice());
}

test "poll handles version negotiation packet with no mutual version" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const vn = packet_mod.VersionNegotiationPacket{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .supported_versions = &[_]u32{ 0x00000002, 0x00000003 },
    };
    const packet_len = try vn.encode(&packet_buf);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        event.?.closing.error_code,
    );
    try std.testing.expectEqualStrings("no mutual QUIC version", event.?.closing.reason);

    const stats = conn.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.packets_invalid);
}

test "server ignores version negotiation packets" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshServer("secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.accept("127.0.0.1", 0);

    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 1, 9, 1, 9 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 2, 8, 2, 8 });
    const internal_conn = try allocator.create(conn_internal.Connection);
    internal_conn.* = try conn_internal.Connection.initServer(allocator, .ssh, local_cid, remote_cid);
    internal_conn.markEstablished();

    if (conn.internal_conn) |old| {
        old.deinit();
        allocator.destroy(old);
    }
    conn.internal_conn = internal_conn;
    conn.state = .established;

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const vn = packet_mod.VersionNegotiationPacket{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .supported_versions = &[_]u32{ 0x00000002, 0x00000003 },
    };
    const packet_len = try vn.encode(&packet_buf);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    try std.testing.expect(conn.nextEvent() == null);
    try std.testing.expect(conn.getState() != .draining);

    const stats = conn.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.packets_invalid);
}

test "client ignores version negotiation packet after establishment" {
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
    const vn = packet_mod.VersionNegotiationPacket{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .supported_versions = &[_]u32{ 0x00000002, 0x00000003 },
    };
    const packet_len = try vn.encode(&packet_buf);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    var saw_closing = false;
    while (conn.nextEvent()) |event| {
        if (event == .closing) {
            saw_closing = true;
            break;
        }
    }
    try std.testing.expect(!saw_closing);
    try std.testing.expectEqual(types_mod.ConnectionState.established, conn.getState());

    const stats = conn.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.packets_invalid);
}

test "poll rejects spoofed version negotiation including current version" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const vn = packet_mod.VersionNegotiationPacket{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .supported_versions = &[_]u32{ core_types.QUIC_VERSION_1, 0x00000002 },
    };
    const packet_len = try vn.encode(&packet_buf);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        event.?.closing.error_code,
    );
    try std.testing.expectEqualStrings("invalid version negotiation", event.?.closing.reason);

    const stats = conn.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.packets_invalid);
}

test "poll rejects malformed version negotiation packet" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [32]u8 = undefined;
    packet_buf[0] = 0xC0;
    std.mem.writeInt(u32, packet_buf[1..5], 0, .big);
    packet_buf[5] = 4;
    @memcpy(packet_buf[6..10], &[_]u8{ 1, 2, 3, 4 });
    packet_buf[10] = 4;
    @memcpy(packet_buf[11..15], &[_]u8{ 5, 6, 7, 8 });

    _ = try sender.sendTo(packet_buf[0..15], local_addr);
    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        event.?.closing.error_code,
    );
    try std.testing.expectEqualStrings("invalid version negotiation packet", event.?.closing.reason);
}

test "poll rejects unsupported long header version" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .initial,
        .version = 0x00000002,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 4,
        .packet_number = 73,
    };
    var packet_len = try header.encode(&packet_buf);
    packet_buf[packet_len] = 0x01;
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
    try std.testing.expectEqualStrings("unsupported version", event.?.closing.reason);
}

test "poll rejects unsupported long header version in server role" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshServer("secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.accept("127.0.0.1", 0);

    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 1, 3, 5, 7 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 2, 4, 6, 8 });
    const internal_conn = try allocator.create(conn_internal.Connection);
    internal_conn.* = try conn_internal.Connection.initServer(allocator, .ssh, local_cid, remote_cid);

    if (conn.internal_conn) |old| {
        old.deinit();
        allocator.destroy(old);
    }
    conn.internal_conn = internal_conn;

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .initial,
        .version = 0x00000002,
        .dest_conn_id = local_cid,
        .src_conn_id = remote_cid,
        .token = &.{},
        .payload_len = 4,
        .packet_number = 93,
    };
    var packet_len = try header.encode(&packet_buf);
    packet_buf[packet_len] = 0x01;
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
    try std.testing.expectEqualStrings("unsupported version", event.?.closing.reason);
}

test "poll rejects malformed version negotiation with fixed bit cleared" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const vn = packet_mod.VersionNegotiationPacket{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .supported_versions = &[_]u32{0x00000002},
    };
    const packet_len = try vn.encode(&packet_buf);
    packet_buf[0] &= 0xBF;

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        event.?.closing.error_code,
    );
    try std.testing.expectEqualStrings("invalid version negotiation packet", event.?.closing.reason);
}

test "unsupported version in later packet preserves earlier side effects" {
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

    var short_buf: [256]u8 = undefined;
    const short_header = packet_mod.ShortHeader{
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .packet_number = 94,
        .key_phase = false,
    };
    var short_len = try short_header.encode(&short_buf);
    const stream = frame_mod.StreamFrame{
        .stream_id = 31,
        .offset = 0,
        .data = "ok",
        .fin = false,
    };
    short_len += try stream.encode(short_buf[short_len..]);

    _ = try sender.sendTo(short_buf[0..short_len], local_addr);

    var long_buf: [256]u8 = undefined;
    const bad_header = packet_mod.LongHeader{
        .packet_type = .initial,
        .version = 0x00000002,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = conn.internal_conn.?.remote_conn_id,
        .token = &.{},
        .payload_len = 4,
        .packet_number = 95,
    };
    var long_len = try bad_header.encode(&long_buf);
    long_buf[long_len] = 0x01;
    long_len += 1;

    _ = try sender.sendTo(long_buf[0..long_len], local_addr);

    try conn.poll();
    try conn.poll();

    var saw_stream = false;
    var saw_closing = false;
    while (conn.nextEvent()) |event| {
        if (event == .stream_readable and event.stream_readable == 31) saw_stream = true;
        if (event == .closing) saw_closing = true;
    }

    try std.testing.expect(saw_stream);
    try std.testing.expect(saw_closing);
}

test "poll rejects malformed version negotiation with non-4-byte version list" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [32]u8 = undefined;
    packet_buf[0] = 0xC0;
    std.mem.writeInt(u32, packet_buf[1..5], 0, .big);
    packet_buf[5] = 4;
    @memcpy(packet_buf[6..10], &[_]u8{ 1, 2, 3, 4 });
    packet_buf[10] = 4;
    @memcpy(packet_buf[11..15], &[_]u8{ 5, 6, 7, 8 });
    packet_buf[15] = 0x00;
    packet_buf[16] = 0x00;
    packet_buf[17] = 0x02;

    _ = try sender.sendTo(packet_buf[0..18], local_addr);
    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.protocol_violation)),
        event.?.closing.error_code,
    );
    try std.testing.expectEqualStrings("invalid version negotiation packet", event.?.closing.reason);
}

test "client processes Retry packet and updates retry state" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const retry_scid = try core_types.ConnectionId.init(&[_]u8{ 9, 9, 9, 9 });
    const expectation = RetryIntegrityExpectation{
        .token = "retry-token-from-server",
        .retry_scid = retry_scid.slice(),
    };
    conn.setRetryIntegrityValidator(@ptrCast(@constCast(&expectation)), retryIntegrityValidator);

    const header = packet_mod.LongHeader{
        .packet_type = .retry,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = retry_scid,
        .token = "retry-token-from-server",
        .payload_len = 1,
        .packet_number = 50,
    };
    const packet_len = try header.encode(&packet_buf);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    try std.testing.expectEqual(types_mod.ConnectionState.connecting, conn.getState());
    const retry_token = conn.getRetryToken();
    try std.testing.expect(retry_token != null);
    try std.testing.expectEqualStrings("retry-token-from-server", retry_token.?);
    try std.testing.expect(conn.internal_conn.?.remote_conn_id.eql(&retry_scid));

    const retry_scid_slice = conn.getRetrySourceConnectionId();
    try std.testing.expect(retry_scid_slice != null);
    try std.testing.expectEqualSlices(u8, retry_scid.slice(), retry_scid_slice.?);
}

test "client rejects second Retry packet" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    const retry_scid = try core_types.ConnectionId.init(&[_]u8{ 4, 4, 4, 4 });
    const expectation = RetryIntegrityExpectation{
        .token = "retry-token",
        .retry_scid = retry_scid.slice(),
    };
    conn.setRetryIntegrityValidator(@ptrCast(@constCast(&expectation)), retryIntegrityValidator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .retry,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = retry_scid,
        .token = "retry-token",
        .payload_len = 1,
        .packet_number = 54,
    };
    const packet_len = try header.encode(&packet_buf);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();
    try std.testing.expectEqual(types_mod.ConnectionState.connecting, conn.getState());

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

test "client rejects Retry packet when integrity validator fails" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    const retry_scid = try core_types.ConnectionId.init(&[_]u8{ 9, 9, 9, 9 });
    const expectation = RetryIntegrityExpectation{
        .token = "some-other-token",
        .retry_scid = retry_scid.slice(),
    };
    conn.setRetryIntegrityValidator(@ptrCast(@constCast(&expectation)), retryIntegrityValidator);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .retry,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = retry_scid,
        .token = "retry-token-from-server",
        .payload_len = 1,
        .packet_number = 53,
    };
    const packet_len = try header.encode(&packet_buf);

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

test "client rejects Retry packet with empty token" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshClient("127.0.0.1", "secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.connect("127.0.0.1", 4433);

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const retry_scid = try core_types.ConnectionId.init(&[_]u8{ 8, 8, 8, 8 });
    const header = packet_mod.LongHeader{
        .packet_type = .retry,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = conn.internal_conn.?.local_conn_id,
        .src_conn_id = retry_scid,
        .token = &.{},
        .payload_len = 1,
        .packet_number = 51,
    };
    const packet_len = try header.encode(&packet_buf);

    _ = try sender.sendTo(packet_buf[0..packet_len], local_addr);
    try conn.poll();

    const event = conn.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .closing);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(core_types.ErrorCode.invalid_token)),
        event.?.closing.error_code,
    );
}

test "server rejects Retry packet" {
    const allocator = std.testing.allocator;

    const config = config_mod.QuicConfig.sshServer("secret");
    var conn = try QuicConnection.init(allocator, config);
    defer conn.deinit();

    try conn.accept("127.0.0.1", 0);

    const local_cid = try core_types.ConnectionId.init(&[_]u8{ 1, 1, 2, 2 });
    const remote_cid = try core_types.ConnectionId.init(&[_]u8{ 3, 3, 4, 4 });
    const internal_conn = try allocator.create(conn_internal.Connection);
    internal_conn.* = try conn_internal.Connection.initServer(allocator, .ssh, local_cid, remote_cid);

    if (conn.internal_conn) |old| {
        old.deinit();
        allocator.destroy(old);
    }
    conn.internal_conn = internal_conn;

    var sender = try udp_mod.UdpSocket.bindAny(allocator, 0);
    defer sender.close();
    const local_addr = try conn.socket.?.getLocalAddress();

    var packet_buf: [256]u8 = undefined;
    const header = packet_mod.LongHeader{
        .packet_type = .retry,
        .version = core_types.QUIC_VERSION_1,
        .dest_conn_id = local_cid,
        .src_conn_id = remote_cid,
        .token = "retry-token",
        .payload_len = 1,
        .packet_number = 52,
    };
    const packet_len = try header.encode(&packet_buf);

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
