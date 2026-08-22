const std = @import("std");
const core = @import("core");

const posix = std.posix;
const wire = core.wire;

/// Frontend-neutral meaning of SES control-channel messages.
///
/// The concrete host still decides how to present notifications or prompts,
/// but the CTL dispatch table should not live only as terminal-loop knowledge.
pub const CtlEventKind = enum {
    notify,
    targeted_notify,
    pop_confirm,
    pop_choose,
    shell_event,
    cwd_changed,
    fg_changed,
    observers_changed,
    send_keys,
    focus_move,
    exit_intent,
    float_request,
    pane_exited,
    session_state,
    session_stolen,
    ignorable_response,
    cwd_response,
    pane_info_response,
    palette_response,
    error_response,
    unknown,
};

pub const CtlFrameEvent = struct {
    raw_msg_type: u16,
    request_id: u32,
    msg_type: wire.MsgType,
    kind: CtlEventKind,
    payload_len: u32,
};

pub const CtlFrameReadResult = union(enum) {
    frame: CtlFrameEvent,
    would_block,
};

pub fn ctlEventKindFromMsgType(msg_type: wire.MsgType) CtlEventKind {
    return switch (msg_type) {
        .notify => .notify,
        .targeted_notify => .targeted_notify,
        .pop_confirm => .pop_confirm,
        .pop_choose => .pop_choose,
        .shell_event => .shell_event,
        .cwd_changed => .cwd_changed,
        .fg_changed => .fg_changed,
        .observers_changed => .observers_changed,
        .send_keys => .send_keys,
        .focus_move => .focus_move,
        .exit_intent => .exit_intent,
        .float_request => .float_request,
        .pane_exited => .pane_exited,
        .session_state => .session_state,
        .session_stolen => .session_stolen,
        .ok, .pong => .ignorable_response,
        .get_pane_cwd => .cwd_response,
        .pane_info => .pane_info_response,
        .get_pane_palette => .palette_response,
        .pane_not_found, .@"error" => .error_response,
        else => .unknown,
    };
}

pub fn ctlFrameEventFromHeader(header: wire.ControlHeader) CtlFrameEvent {
    const msg_type: wire.MsgType = @enumFromInt(header.msg_type);
    return .{
        .raw_msg_type = header.msg_type,
        .request_id = header.request_id,
        .msg_type = msg_type,
        .kind = ctlEventKindFromMsgType(msg_type),
        .payload_len = header.payload_len,
    };
}

/// Read one SES control-channel header and classify its frontend-neutral
/// meaning. Hosts still read and interpret the typed payloads they own.
pub fn readCtlFrameHeader(fd: posix.fd_t) !CtlFrameReadResult {
    const header = wire.tryReadControlHeader(fd) catch |err| switch (err) {
        error.WouldBlock => return .would_block,
        else => return err,
    };
    return .{ .frame = ctlFrameEventFromHeader(header) };
}

/// Drain available SES control-channel frame headers and dispatch their
/// frontend-neutral classification to `on_frame`.
///
/// Payload ownership intentionally stays with the caller: the core can classify
/// message envelopes, while concrete hosts/session-view code still decides how
/// to parse and present each payload.
pub fn drainCtlFrameHeaders(
    fd: posix.fd_t,
    max_frames: usize,
    context: anytype,
    comptime on_frame: fn (@TypeOf(context), CtlFrameEvent) bool,
) !void {
    var msgs: usize = 0;
    while (msgs < max_frames) : (msgs += 1) {
        const event = switch (try readCtlFrameHeader(fd)) {
            .would_block => break,
            .frame => |value| value,
        };
        if (!on_frame(context, event)) break;
    }
}

fn testCtlDrainNoop(_: void, _: CtlFrameEvent) bool {
    return true;
}

test "ctlEventKindFromMsgType classifies interactive events" {
    try std.testing.expectEqual(CtlEventKind.notify, ctlEventKindFromMsgType(.notify));
    try std.testing.expectEqual(CtlEventKind.pop_confirm, ctlEventKindFromMsgType(.pop_confirm));
    try std.testing.expectEqual(CtlEventKind.float_request, ctlEventKindFromMsgType(.float_request));
    try std.testing.expectEqual(CtlEventKind.session_stolen, ctlEventKindFromMsgType(.session_stolen));
}

test "ctlEventKindFromMsgType classifies async responses" {
    try std.testing.expectEqual(CtlEventKind.ignorable_response, ctlEventKindFromMsgType(.ok));
    try std.testing.expectEqual(CtlEventKind.ignorable_response, ctlEventKindFromMsgType(.pong));
    try std.testing.expectEqual(CtlEventKind.cwd_response, ctlEventKindFromMsgType(.get_pane_cwd));
    try std.testing.expectEqual(CtlEventKind.pane_info_response, ctlEventKindFromMsgType(.pane_info));
}

test "ctlEventKindFromMsgType classifies failures separately" {
    try std.testing.expectEqual(CtlEventKind.error_response, ctlEventKindFromMsgType(.pane_not_found));
    try std.testing.expectEqual(CtlEventKind.error_response, ctlEventKindFromMsgType(.@"error"));
}

test "ctlFrameEventFromHeader preserves raw type and length" {
    const event = ctlFrameEventFromHeader(.{
        .msg_type = @intFromEnum(wire.MsgType.notify),
        .request_id = 123,
        .payload_len = 55,
    });

    try std.testing.expectEqual(@as(u16, @intFromEnum(wire.MsgType.notify)), event.raw_msg_type);
    try std.testing.expectEqual(@as(u32, 123), event.request_id);
    try std.testing.expectEqual(wire.MsgType.notify, event.msg_type);
    try std.testing.expectEqual(CtlEventKind.notify, event.kind);
    try std.testing.expectEqual(@as(u32, 55), event.payload_len);
}

test "drainCtlFrameHeaders accepts an empty drain without touching fd" {
    const invalid_fd: posix.fd_t = -1;
    try drainCtlFrameHeaders(invalid_fd, 0, {}, testCtlDrainNoop);
}
