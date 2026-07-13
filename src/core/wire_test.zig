// Round-trip tests for the wire protocol. Each test writes one control
// message on one end of a socket pair and reads it back on the other end,
// asserting byte-for-byte equality. This catches layout drift in extern
// structs and regressions in writeControl / readControlHeader / readStruct.

const std = @import("std");
const posix = std.posix;
const testing = std.testing;
const core = @import("core");
const wire = core.wire;

/// Create a connected blocking SOCK_STREAM pair. Caller closes both fds.
fn socketPair() !struct { a: posix.fd_t, b: posix.fd_t } {
    var fds: [2]posix.fd_t = undefined;
    const rc = std.os.linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return error.SocketpairFailed;
    return .{ .a = fds[0], .b = fds[1] };
}

const setNonBlocking = core.ipc.setNonBlocking;

test "wire round-trip: empty payload (ping)" {
    const pair = try socketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);

    try wire.writeControl(pair.a, .ping, &.{});

    const hdr = try wire.readControlHeader(pair.b);
    try testing.expectEqual(@as(u16, @intFromEnum(wire.MsgType.ping)), hdr.msg_type);
    try testing.expectEqual(@as(u32, 0), hdr.request_id);
    try testing.expectEqual(@as(u32, 0), hdr.payload_len);
}

test "wire round-trip: explicit request id" {
    const pair = try socketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);

    try wire.writeControlWithRequestId(pair.a, .ping, 42, &.{});

    const hdr = try wire.readControlHeader(pair.b);
    try testing.expectEqual(@as(u16, @intFromEnum(wire.MsgType.ping)), hdr.msg_type);
    try testing.expectEqual(@as(u32, 42), hdr.request_id);
    try testing.expectEqual(@as(u32, 0), hdr.payload_len);
}

test "wire: server hello validates runtime epoch" {
    const pair = try socketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);

    try wire.sendServerHello(pair.a);
    try wire.readAndValidateServerHello(pair.b);
}

test "wire round-trip: fixed-size struct (PaneUuid)" {
    const pair = try socketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);

    var sent: wire.PaneUuid = .{ .uuid = undefined };
    // Deterministic pattern so we can catch endianness or alignment drift.
    for (&sent.uuid, 0..) |*b, i| b.* = @intCast(i);

    try wire.writeControl(pair.a, .kill_pane, std.mem.asBytes(&sent));

    const hdr = try wire.readControlHeader(pair.b);
    try testing.expectEqual(@as(u16, @intFromEnum(wire.MsgType.kill_pane)), hdr.msg_type);
    try testing.expectEqual(@as(u32, @sizeOf(wire.PaneUuid)), hdr.payload_len);

    const got = try wire.readStruct(wire.PaneUuid, pair.b);
    try testing.expectEqualSlices(u8, &sent.uuid, &got.uuid);
}

test "wire round-trip: structured Disconnect reason" {
    const pair = try socketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);

    var sent: wire.Disconnect = .{
        .mode = @intFromEnum(wire.DisconnectMode.shutdown),
        .preserve_sticky = 1,
        .reason = @intFromEnum(wire.DisconnectReason.user_exit),
    };

    try wire.writeControl(pair.a, .disconnect, std.mem.asBytes(&sent));

    const hdr = try wire.readControlHeader(pair.b);
    try testing.expectEqual(@as(u16, @intFromEnum(wire.MsgType.disconnect)), hdr.msg_type);
    try testing.expectEqual(@as(u32, @sizeOf(wire.Disconnect)), hdr.payload_len);

    const got = try wire.readStruct(wire.Disconnect, pair.b);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&sent), std.mem.asBytes(&got));
    try testing.expectEqual(wire.DisconnectReason.user_exit, try std.meta.intToEnum(wire.DisconnectReason, got.reason));
}

test "wire round-trip: Register carries frontend capability flags" {
    const pair = try socketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);

    const name = "web";
    const root = "/tmp/hexe";
    const trail = "web/tmp/hexe";
    var sent: wire.FrontendRegister = .{
        .session_id = [_]u8{'s'} ** 32,
        .keepalive = 1,
        .frontend_kind = @intFromEnum(wire.FrontendKind.web),
        .transport_kind = @intFromEnum(wire.FrontendTransportKind.local_ipc),
        .capability_flags = wire.FrontendCapabilityFlag.interactive_input |
            wire.FrontendCapabilityFlag.cell_render |
            wire.FrontendCapabilityFlag.pixel_render |
            wire.FrontendCapabilityFlag.reconnect,
        .name_len = @intCast(name.len),
        .base_root_len = @intCast(root.len),
    };

    try wire.writeControlWithTrail(pair.a, .register, std.mem.asBytes(&sent), trail);

    const hdr = try wire.readControlHeader(pair.b);
    try testing.expectEqual(@as(u16, @intFromEnum(wire.MsgType.register)), hdr.msg_type);
    try testing.expectEqual(
        @as(u32, @intCast(@sizeOf(wire.FrontendRegister) + name.len + root.len)),
        hdr.payload_len,
    );

    const got = try wire.readStruct(wire.FrontendRegister, pair.b);
    try testing.expectEqual(@as(u8, @intFromEnum(wire.FrontendKind.web)), got.frontend_kind);
    try testing.expect((got.capability_flags & wire.FrontendCapabilityFlag.pixel_render) != 0);
    try testing.expect((got.capability_flags & wire.FrontendCapabilityFlag.reconnect) != 0);
}

test "wire round-trip: struct + trailing bytes (notify)" {
    const pair = try socketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);

    const message = "hello from ses";
    var sent: wire.Notify = .{ .msg_len = @intCast(message.len) };

    try wire.writeControlWithTrail(pair.a, .notify, std.mem.asBytes(&sent), message);

    const hdr = try wire.readControlHeader(pair.b);
    try testing.expectEqual(@as(u16, @intFromEnum(wire.MsgType.notify)), hdr.msg_type);
    try testing.expectEqual(
        @as(u32, @intCast(@sizeOf(wire.Notify) + message.len)),
        hdr.payload_len,
    );

    const got = try wire.readStruct(wire.Notify, pair.b);
    try testing.expectEqual(sent.msg_len, got.msg_len);

    var buf: [64]u8 = undefined;
    try wire.readExact(pair.b, buf[0..message.len]);
    try testing.expectEqualStrings(message, buf[0..message.len]);
}

test "wire round-trip: struct with interior fields (SessionSyncFloat)" {
    const pair = try socketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);

    var sent: wire.SessionSyncFloat = .{
        .pane_uuid = [_]u8{'a'} ** 32,
        .active_tab = 3,
        .parent_tab = 1,
        .tab_visible = 0xdeadbeefcafebabe,
        .has_active_tab = 1,
        .has_parent_tab = 1,
        .visible = 1,
        .sticky = 0,
        .is_pwd = 1,
        .float_key = 7,
        .width_pct = 80,
        .height_pct = 60,
        .pos_x_pct = 10,
        .pos_y_pct = 20,
        .pad_x = 2,
        .pad_y = 1,
        .active = 1,
    };

    try wire.writeControl(pair.a, .session_sync_float, std.mem.asBytes(&sent));

    const hdr = try wire.readControlHeader(pair.b);
    try testing.expectEqual(@as(u32, @sizeOf(wire.SessionSyncFloat)), hdr.payload_len);

    const got = try wire.readStruct(wire.SessionSyncFloat, pair.b);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&sent), std.mem.asBytes(&got));
}

test "wire: oversize payload header trips MAX_PAYLOAD_LEN check" {
    // Craft a header whose declared length exceeds the cap. The receiver is
    // expected to close the connection without reading the body; this test
    // just confirms the constant is wired up and a handler could observe the
    // overflow without integer tricks.
    const pair = try socketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);

    var forged: wire.ControlHeader = .{
        .msg_type = @intFromEnum(wire.MsgType.ping),
        .request_id = 0,
        .payload_len = @intCast(wire.MAX_PAYLOAD_LEN + 1),
    };
    try wire.writeAll(pair.a, std.mem.asBytes(&forged));

    const hdr = try wire.readControlHeader(pair.b);
    try testing.expect(hdr.payload_len > wire.MAX_PAYLOAD_LEN);
}

test "wire: timeout-bounded header read rejects partial nonblocking frame" {
    const pair = try socketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);
    try setNonBlocking(pair.b);

    try wire.writeAll(pair.a, &[_]u8{0x01});
    try testing.expectError(error.Timeout, wire.readControlHeaderTimeout(pair.b, 10));
}

test "wire: protocol version 3 is minimum supported" {
    try testing.expect(!wire.isProtocolVersionSupported(2));
    try testing.expect(wire.isProtocolVersionSupported(3));
    try testing.expect(!wire.isProtocolVersionDeprecated(2));
}

test "wire round-trip: Error payload + trail" {
    const pair = try socketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);

    const msg = "something went wrong";
    var err_payload: wire.Error = .{ .msg_len = @intCast(msg.len) };
    try wire.writeControlWithTrail(pair.a, .@"error", std.mem.asBytes(&err_payload), msg);

    const hdr = try wire.readControlHeader(pair.b);
    try testing.expectEqual(@as(u16, @intFromEnum(wire.MsgType.@"error")), hdr.msg_type);
    try testing.expectEqual(@as(u32, 0), hdr.request_id);

    const got = try wire.readStruct(wire.Error, pair.b);
    try testing.expectEqual(@as(u16, msg.len), got.msg_len);

    var buf: [64]u8 = undefined;
    try wire.readExact(pair.b, buf[0..msg.len]);
    try testing.expectEqualStrings(msg, buf[0..msg.len]);
}

test "wire round-trip: Detach carries the session id" {
    const pair = try socketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);

    var sent: wire.Detach = .{ .session_id = undefined };
    for (&sent.session_id, 0..) |*b, i| b.* = @intCast(i);

    try wire.writeControl(pair.a, .detach, std.mem.asBytes(&sent));

    const hdr = try wire.readControlHeader(pair.b);
    try testing.expectEqual(@as(u16, @intFromEnum(wire.MsgType.detach)), hdr.msg_type);
    try testing.expectEqual(@as(u32, @sizeOf(wire.Detach)), hdr.payload_len);
    const got = try wire.readStruct(wire.Detach, pair.b);
    try testing.expectEqualSlices(u8, &sent.session_id, &got.session_id);
}

test "wire round-trip: Reattach prefix (id_len + trailing session id)" {
    const pair = try socketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);

    const sid = "pikachu-3";
    var sent: wire.Reattach = .{ .id_len = @intCast(sid.len) };

    try wire.writeControlWithTrail(pair.a, .reattach, std.mem.asBytes(&sent), sid);

    const hdr = try wire.readControlHeader(pair.b);
    try testing.expectEqual(@as(u16, @intFromEnum(wire.MsgType.reattach)), hdr.msg_type);
    try testing.expectEqual(@as(u32, @intCast(@sizeOf(wire.Reattach) + sid.len)), hdr.payload_len);
    const got = try wire.readStruct(wire.Reattach, pair.b);
    try testing.expectEqual(sent.id_len, got.id_len);
    var buf: [32]u8 = undefined;
    try wire.readExact(pair.b, buf[0..sid.len]);
    try testing.expectEqualStrings(sid, buf[0..sid.len]);
}

test "wire round-trip: SessionReattached (snapshot + pane uuids trail)" {
    const pair = try socketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);

    const snapshot = "{\"uuid\":\"snap\"}";
    const pane_count: u16 = 2;
    var uuids: [2][32]u8 = undefined;
    for (&uuids, 0..) |*u, i| {
        for (u, 0..) |*b, j| b.* = @intCast((i * 32 + j) & 0xff);
    }

    var sent: wire.SessionReattached = .{ .state_len = @intCast(snapshot.len), .pane_count = pane_count };

    var trail: [256]u8 = undefined;
    @memcpy(trail[0..snapshot.len], snapshot);
    const uuid_bytes = std.mem.sliceAsBytes(uuids[0..]);
    @memcpy(trail[snapshot.len .. snapshot.len + uuid_bytes.len], uuid_bytes);
    const trail_len = snapshot.len + uuid_bytes.len;

    try wire.writeControlWithTrail(pair.a, .session_reattached, std.mem.asBytes(&sent), trail[0..trail_len]);

    const hdr = try wire.readControlHeader(pair.b);
    try testing.expectEqual(@as(u16, @intFromEnum(wire.MsgType.session_reattached)), hdr.msg_type);
    try testing.expectEqual(@as(u32, @intCast(@sizeOf(wire.SessionReattached) + trail_len)), hdr.payload_len);

    const got = try wire.readStruct(wire.SessionReattached, pair.b);
    try testing.expectEqual(sent.state_len, got.state_len);
    try testing.expectEqual(sent.pane_count, got.pane_count);

    var snap_buf: [64]u8 = undefined;
    try wire.readExact(pair.b, snap_buf[0..snapshot.len]);
    try testing.expectEqualStrings(snapshot, snap_buf[0..snapshot.len]);

    var got_uuids: [64]u8 = undefined;
    try wire.readExact(pair.b, got_uuids[0..uuid_bytes.len]);
    try testing.expectEqualSlices(u8, uuid_bytes, got_uuids[0..uuid_bytes.len]);
}

test "wire round-trip: SessionEntry carries the attached flag" {
    const pair = try socketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);

    var sent: wire.SessionEntry = .{
        .session_id = [_]u8{'e'} ** 32,
        .pane_count = 3,
        .name_len = 5,
        .base_root_len = 4,
        .attached = 1,
    };
    try wire.writeControl(pair.a, .sessions_list, std.mem.asBytes(&sent));

    const hdr = try wire.readControlHeader(pair.b);
    try testing.expectEqual(@as(u32, @sizeOf(wire.SessionEntry)), hdr.payload_len);
    const got = try wire.readStruct(wire.SessionEntry, pair.b);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&sent), std.mem.asBytes(&got));
    try testing.expectEqual(@as(u8, 1), got.attached);
}
