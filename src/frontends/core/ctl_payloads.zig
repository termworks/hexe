const std = @import("std");
const core = @import("core");

const posix = std.posix;
const wire = core.wire;

pub const PaneCwdPayload = struct {
    uuid: [32]u8,
    cwd: []u8,

    pub fn deinit(self: *PaneCwdPayload, allocator: std.mem.Allocator) void {
        allocator.free(self.cwd);
        self.* = undefined;
    }
};

pub const PaneInfoPayload = struct {
    uuid: [32]u8,
    name: ?[]u8 = null,
    fg_name: ?[]u8 = null,
    fg_pid: ?i32 = null,

    pub fn deinit(self: *PaneInfoPayload, allocator: std.mem.Allocator) void {
        if (self.name) |value| allocator.free(value);
        if (self.fg_name) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const PaneUuidPayload = struct {
    uuid: [32]u8,
};

pub const ShellEventPayload = struct {
    uuid: [32]u8,
    phase_start: bool,
    status: ?i32,
    duration_ms: ?u64,
    started_at_ms: ?u64,
    jobs: ?u16,
    running: bool,
    cmd: ?[]u8 = null,
    cwd: ?[]u8 = null,

    pub fn deinit(self: *ShellEventPayload, allocator: std.mem.Allocator) void {
        if (self.cmd) |value| allocator.free(value);
        if (self.cwd) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const SendKeysPayload = struct {
    uuid: [32]u8,
    data: []u8,

    pub fn deinit(self: *SendKeysPayload, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};

pub const NotifyPayload = struct {
    message: []u8,

    pub fn deinit(self: *NotifyPayload, allocator: std.mem.Allocator) void {
        if (self.message.len > 0) allocator.free(self.message);
        self.* = undefined;
    }
};

pub const TargetedNotifyPayload = struct {
    uuid: [32]u8,
    timeout_ms: ?i64,
    message: []u8,

    pub fn deinit(self: *TargetedNotifyPayload, allocator: std.mem.Allocator) void {
        if (self.message.len > 0) allocator.free(self.message);
        self.* = undefined;
    }
};

pub const FocusMovePayload = struct {
    uuid: [32]u8,
    direction: ?@import("actions.zig").Direction,
};

pub const ExitIntentPayload = struct {
    uuid: [32]u8,
};

pub const PopConfirmPayload = struct {
    uuid: [32]u8,
    timeout_ms: ?i64,
    message: []u8,

    pub fn deinit(self: *PopConfirmPayload, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const PopChoosePayload = struct {
    uuid: [32]u8,
    timeout_ms: ?i64,
    title: ?[]u8 = null,
    items: []const []const u8 = &.{},

    pub fn deinit(self: *PopChoosePayload, allocator: std.mem.Allocator) void {
        if (self.title) |value| allocator.free(value);
        for (self.items) |item| allocator.free(item);
        if (self.items.len > 0) allocator.free(self.items);
        self.* = undefined;
    }
};

fn skipPayload(fd: posix.fd_t, len: usize, scratch: []u8) !void {
    var remaining = len;
    while (remaining > 0) {
        const chunk = @min(remaining, scratch.len);
        try wire.readExact(fd, scratch[0..chunk]);
        remaining -= chunk;
    }
}

/// Read a `get_pane_cwd` response payload from a CTL fd.
///
/// The returned cwd is owned by `allocator`. Malformed but fully drained
/// payloads return `null` so hosts can continue processing later frames.
pub fn readPaneCwdPayload(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    payload_len: u32,
    scratch: []u8,
) !?PaneCwdPayload {
    if (payload_len < @sizeOf(wire.PaneCwd)) {
        try skipPayload(fd, payload_len, scratch);
        return null;
    }

    const resp = try wire.readStruct(wire.PaneCwd, fd);
    const remaining = payload_len - @sizeOf(wire.PaneCwd);
    if (resp.cwd_len == 0) {
        if (remaining > 0) try skipPayload(fd, remaining, scratch);
        return null;
    }
    if (resp.cwd_len != remaining or resp.cwd_len > wire.MAX_PAYLOAD_LEN) {
        try skipPayload(fd, remaining, scratch);
        return null;
    }

    const cwd = try allocator.alloc(u8, resp.cwd_len);
    errdefer allocator.free(cwd);
    try wire.readExact(fd, cwd);
    return .{ .uuid = resp.uuid, .cwd = cwd };
}

/// Read the frontend-relevant parts of a `pane_info` response payload.
///
/// This intentionally extracts the shared metadata that non-terminal hosts also
/// need (pane name and foreground process) while draining terminal-specific or
/// currently-unused trailing fields.
pub fn readPaneInfoPayload(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    payload_len: u32,
    scratch: []u8,
) !?PaneInfoPayload {
    if (payload_len < @sizeOf(wire.PaneInfoResp)) {
        try skipPayload(fd, payload_len, scratch);
        return null;
    }

    const resp = try wire.readStruct(wire.PaneInfoResp, fd);
    const remaining_payload = payload_len - @sizeOf(wire.PaneInfoResp);
    const trail_total: usize = @as(usize, resp.name_len) + @as(usize, resp.fg_len) +
        @as(usize, resp.cwd_len) + @as(usize, resp.tty_len) +
        @as(usize, resp.socket_path_len) + @as(usize, resp.session_name_len) +
        @as(usize, resp.layout_path_len) + @as(usize, resp.last_cmd_len) +
        @as(usize, resp.base_process_len) + @as(usize, resp.sticky_pwd_len);
    if (trail_total != remaining_payload) {
        try skipPayload(fd, remaining_payload, scratch);
        return null;
    }

    var payload = PaneInfoPayload{
        .uuid = resp.uuid,
        .fg_pid = if (resp.fg_pid != 0) resp.fg_pid else null,
    };
    errdefer payload.deinit(allocator);

    if (resp.name_len > 0) {
        if (resp.name_len <= wire.MAX_PAYLOAD_LEN) {
            payload.name = try allocator.alloc(u8, resp.name_len);
            try wire.readExact(fd, payload.name.?);
        } else {
            try skipPayload(fd, resp.name_len, scratch);
        }
    }

    if (resp.fg_len > 0) {
        if (resp.fg_len <= wire.MAX_PAYLOAD_LEN) {
            payload.fg_name = try allocator.alloc(u8, resp.fg_len);
            try wire.readExact(fd, payload.fg_name.?);
        } else {
            try skipPayload(fd, resp.fg_len, scratch);
        }
    }

    const skipped_len: usize = @as(usize, resp.name_len) + @as(usize, resp.fg_len);
    const remaining = trail_total -| skipped_len;
    if (remaining > 0) try skipPayload(fd, remaining, scratch);
    return payload;
}

pub fn readPaneUuidPayload(fd: posix.fd_t, payload_len: u32, scratch: []u8) !?PaneUuidPayload {
    if (payload_len < @sizeOf(wire.PaneUuid)) {
        try skipPayload(fd, payload_len, scratch);
        return null;
    }

    const payload = try wire.readStruct(wire.PaneUuid, fd);
    const remaining = payload_len - @sizeOf(wire.PaneUuid);
    if (remaining > 0) try skipPayload(fd, remaining, scratch);
    return .{ .uuid = payload.uuid };
}

/// Read a forwarded shell-event payload from a CTL fd.
///
/// This extracts the frontend-neutral command lifecycle metadata. Hosts still
/// own presentation/application policy (notifications, Lua autocmds, rendering).
pub fn readShellEventPayload(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    payload_len: u32,
    scratch: []u8,
) !?ShellEventPayload {
    if (payload_len < @sizeOf(wire.ForwardedShellEvent)) {
        try skipPayload(fd, payload_len, scratch);
        return null;
    }

    const ev = try wire.readStruct(wire.ForwardedShellEvent, fd);
    const remaining = payload_len - @sizeOf(wire.ForwardedShellEvent);
    const trail_len: usize = @as(usize, ev.cmd_len) + @as(usize, ev.cwd_len);
    if (trail_len != remaining) {
        try skipPayload(fd, remaining, scratch);
        return null;
    }

    var payload = ShellEventPayload{
        .uuid = ev.uuid,
        .phase_start = ev.phase == 1,
        .status = if (ev.status != 0 or ev.phase != 1) ev.status else null,
        .duration_ms = if (ev.duration_ms > 0) @intCast(ev.duration_ms) else null,
        .started_at_ms = if (ev.started_at > 0) @intCast(ev.started_at) else null,
        .jobs = if (ev.jobs > 0 or ev.phase == 0) ev.jobs else null,
        .running = ev.running != 0,
    };
    errdefer payload.deinit(allocator);

    if (ev.cmd_len > 0) {
        payload.cmd = try allocator.alloc(u8, ev.cmd_len);
        try wire.readExact(fd, payload.cmd.?);
    }
    if (ev.cwd_len > 0) {
        payload.cwd = try allocator.alloc(u8, ev.cwd_len);
        try wire.readExact(fd, payload.cwd.?);
    }

    return payload;
}

pub fn readSendKeysPayload(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    payload_len: u32,
    scratch: []u8,
) !?SendKeysPayload {
    if (payload_len < @sizeOf(wire.SendKeys)) {
        try skipPayload(fd, payload_len, scratch);
        return null;
    }

    const sk = try wire.readStruct(wire.SendKeys, fd);
    const remaining = payload_len - @sizeOf(wire.SendKeys);
    if (sk.data_len == 0 or sk.data_len != remaining or sk.data_len > wire.MAX_PAYLOAD_LEN) {
        try skipPayload(fd, remaining, scratch);
        return null;
    }

    const data = try allocator.alloc(u8, sk.data_len);
    errdefer allocator.free(data);
    try wire.readExact(fd, data);
    return .{ .uuid = sk.uuid, .data = data };
}

pub fn readNotifyPayload(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    payload_len: u32,
    scratch: []u8,
) !?NotifyPayload {
    if (payload_len < @sizeOf(wire.Notify)) {
        try skipPayload(fd, payload_len, scratch);
        return null;
    }

    const notify = try wire.readStruct(wire.Notify, fd);
    const remaining = payload_len - @sizeOf(wire.Notify);
    if (notify.msg_len == 0 or notify.msg_len != remaining or notify.msg_len > wire.MAX_PAYLOAD_LEN) {
        try skipPayload(fd, remaining, scratch);
        return null;
    }

    const message = try allocator.alloc(u8, notify.msg_len);
    errdefer allocator.free(message);
    try wire.readExact(fd, message);
    return .{ .message = message };
}

pub fn readTargetedNotifyPayload(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    payload_len: u32,
    scratch: []u8,
) !?TargetedNotifyPayload {
    if (payload_len < @sizeOf(wire.TargetedNotify)) {
        try skipPayload(fd, payload_len, scratch);
        return null;
    }

    const notify = try wire.readStruct(wire.TargetedNotify, fd);
    const remaining = payload_len - @sizeOf(wire.TargetedNotify);
    if (notify.msg_len == 0 or notify.msg_len != remaining or notify.msg_len > wire.MAX_PAYLOAD_LEN) {
        try skipPayload(fd, remaining, scratch);
        return null;
    }

    const message = try allocator.alloc(u8, notify.msg_len);
    errdefer allocator.free(message);
    try wire.readExact(fd, message);
    return .{
        .uuid = notify.uuid,
        .timeout_ms = if (notify.timeout_ms > 0) @as(i64, notify.timeout_ms) else null,
        .message = message,
    };
}

pub fn readFocusMovePayload(fd: posix.fd_t, payload_len: u32, scratch: []u8) !?FocusMovePayload {
    if (payload_len < @sizeOf(wire.FocusMove)) {
        try skipPayload(fd, payload_len, scratch);
        return null;
    }

    const fm = try wire.readStruct(wire.FocusMove, fd);
    const remaining = payload_len - @sizeOf(wire.FocusMove);
    if (remaining > 0) try skipPayload(fd, remaining, scratch);

    const Direction = @import("actions.zig").Direction;
    const direction: ?Direction = switch (fm.dir) {
        0 => .left,
        1 => .right,
        2 => .up,
        3 => .down,
        else => null,
    };
    return .{ .uuid = fm.uuid, .direction = direction };
}

pub fn readExitIntentPayload(fd: posix.fd_t, payload_len: u32, scratch: []u8) !?ExitIntentPayload {
    if (payload_len < @sizeOf(wire.ExitIntent)) {
        try skipPayload(fd, payload_len, scratch);
        return null;
    }

    const payload = try wire.readStruct(wire.ExitIntent, fd);
    const remaining = payload_len - @sizeOf(wire.ExitIntent);
    if (remaining > 0) try skipPayload(fd, remaining, scratch);
    return .{ .uuid = payload.uuid };
}

pub fn readPopConfirmPayload(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    payload_len: u32,
    scratch: []u8,
) !?PopConfirmPayload {
    if (payload_len < @sizeOf(wire.PopConfirm)) {
        try skipPayload(fd, payload_len, scratch);
        return null;
    }

    const pc = try wire.readStruct(wire.PopConfirm, fd);
    const remaining = payload_len - @sizeOf(wire.PopConfirm);
    if (pc.msg_len == 0 or pc.msg_len != remaining or pc.msg_len > wire.MAX_PAYLOAD_LEN) {
        try skipPayload(fd, remaining, scratch);
        return null;
    }

    const message = try allocator.alloc(u8, pc.msg_len);
    errdefer allocator.free(message);
    try wire.readExact(fd, message);

    return .{
        .uuid = pc.uuid,
        .timeout_ms = if (pc.timeout_ms > 0) @as(i64, pc.timeout_ms) else null,
        .message = message,
    };
}

pub fn readPopChoosePayload(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    payload_len: u32,
    scratch: []u8,
) !?PopChoosePayload {
    if (payload_len < @sizeOf(wire.PopChoose)) {
        try skipPayload(fd, payload_len, scratch);
        return null;
    }

    const pc = try wire.readStruct(wire.PopChoose, fd);
    const remaining_payload: usize = payload_len - @sizeOf(wire.PopChoose);
    var consumed: usize = 0;

    var payload = PopChoosePayload{
        .uuid = pc.uuid,
        .timeout_ms = if (pc.timeout_ms > 0) @as(i64, pc.timeout_ms) else null,
    };
    errdefer payload.deinit(allocator);

    if (pc.title_len > remaining_payload or pc.title_len > wire.MAX_PAYLOAD_LEN) {
        try skipPayload(fd, remaining_payload, scratch);
        return null;
    }
    if (pc.title_len > 0) {
        payload.title = try allocator.alloc(u8, pc.title_len);
        try wire.readExact(fd, payload.title.?);
        consumed += pc.title_len;
    }

    var items_list: std.ArrayList([]const u8) = .empty;
    defer items_list.deinit(allocator);
    errdefer {
        for (items_list.items) |item| allocator.free(item);
    }

    const ItemHeader = extern struct { len: u16 align(1) };
    for (0..pc.item_count) |_| {
        if (remaining_payload - consumed < @sizeOf(ItemHeader)) {
            try skipPayload(fd, remaining_payload - consumed, scratch);
            return null;
        }

        const item_header = try wire.readStruct(ItemHeader, fd);
        consumed += @sizeOf(ItemHeader);
        const item_len: usize = item_header.len;
        if (item_len == 0 or item_len > wire.MAX_PAYLOAD_LEN or item_len > remaining_payload - consumed) {
            try skipPayload(fd, remaining_payload - consumed, scratch);
            return null;
        }

        const item = try allocator.alloc(u8, item_len);
        errdefer allocator.free(item);
        try wire.readExact(fd, item);
        consumed += item_len;
        try items_list.append(allocator, item);
    }

    if (consumed != remaining_payload) {
        try skipPayload(fd, remaining_payload - consumed, scratch);
        return null;
    }

    payload.items = try items_list.toOwnedSlice(allocator);
    return payload;
}

test "PaneInfoPayload deinit clears optional owned strings" {
    var payload = PaneInfoPayload{
        .uuid = [_]u8{'p'} ** 32,
        .name = try std.testing.allocator.dupe(u8, "name"),
        .fg_name = try std.testing.allocator.dupe(u8, "shell"),
        .fg_pid = 42,
    };
    payload.deinit(std.testing.allocator);
}

test "readPaneCwdPayload reads shared cwd response body" {
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    const uuid = [_]u8{'c'} ** 32;
    const cwd = "/tmp/hexe";
    const body = wire.PaneCwd{
        .uuid = uuid,
        .cwd_len = @intCast(cwd.len),
    };
    try wire.writeAll(pipe_fds[1], std.mem.asBytes(&body));
    try wire.writeAll(pipe_fds[1], cwd);

    var scratch: [128]u8 = undefined;
    var payload = (try readPaneCwdPayload(
        std.testing.allocator,
        pipe_fds[0],
        @sizeOf(wire.PaneCwd) + cwd.len,
        &scratch,
    )).?;
    defer payload.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &uuid, &payload.uuid);
    try std.testing.expectEqualStrings(cwd, payload.cwd);
}

test "readPaneInfoPayload extracts shared pane name and foreground process" {
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    const uuid = [_]u8{'i'} ** 32;
    const name = "pikachu";
    const fg = "zsh";
    const body = wire.PaneInfoResp{
        .uuid = uuid,
        .pid = 11,
        .fg_pid = 22,
        .base_pid = 0,
        .pane_id = 3,
        .cols = 80,
        .rows = 24,
        .cursor_x = 0,
        .cursor_y = 0,
        .cursor_style = 0,
        .cursor_visible = 1,
        .alt_screen = 0,
        .is_focused = 1,
        .pane_type = 0,
        .state = 0,
        .last_status = 0,
        .has_last_status = 0,
        .last_duration_ms = 0,
        .has_last_duration = 0,
        .last_jobs = 0,
        .has_last_jobs = 0,
        .created_at = 0,
        .sticky_key = 0,
        .has_sticky_key = 0,
        .created_from = .{0} ** 32,
        .focused_from = .{0} ** 32,
        .has_created_from = 0,
        .has_focused_from = 0,
        .name_len = @intCast(name.len),
        .fg_len = @intCast(fg.len),
        .cwd_len = 0,
        .tty_len = 0,
        .socket_path_len = 0,
        .session_name_len = 0,
        .layout_path_len = 0,
        .last_cmd_len = 0,
        .base_process_len = 0,
        .sticky_pwd_len = 0,
    };
    try wire.writeAll(pipe_fds[1], std.mem.asBytes(&body));
    try wire.writeAll(pipe_fds[1], name);
    try wire.writeAll(pipe_fds[1], fg);

    var scratch: [128]u8 = undefined;
    var payload = (try readPaneInfoPayload(
        std.testing.allocator,
        pipe_fds[0],
        @sizeOf(wire.PaneInfoResp) + name.len + fg.len,
        &scratch,
    )).?;
    defer payload.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &uuid, &payload.uuid);
    try std.testing.expectEqualStrings(name, payload.name.?);
    try std.testing.expectEqualStrings(fg, payload.fg_name.?);
    try std.testing.expectEqual(@as(?i32, 22), payload.fg_pid);
}

test "readPaneUuidPayload extracts pane uuid and drains trailing bytes" {
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    const uuid = [_]u8{'u'} ** 32;
    const body = wire.PaneUuid{ .uuid = uuid };
    try wire.writeAll(pipe_fds[1], std.mem.asBytes(&body));
    try wire.writeAll(pipe_fds[1], "xx");

    var scratch: [128]u8 = undefined;
    const payload = (try readPaneUuidPayload(
        pipe_fds[0],
        @sizeOf(wire.PaneUuid) + 2,
        &scratch,
    )).?;

    try std.testing.expectEqualSlices(u8, &uuid, &payload.uuid);
}

test "readShellEventPayload extracts command lifecycle metadata" {
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    const uuid = [_]u8{'h'} ** 32;
    const cmd = "make test";
    const cwd = "/tmp/hexe";
    const body = wire.ForwardedShellEvent{
        .uuid = uuid,
        .phase = 0,
        .status = 7,
        .duration_ms = 123,
        .started_at = 99,
        .jobs = 2,
        .running = 0,
        .cmd_len = @intCast(cmd.len),
        .cwd_len = @intCast(cwd.len),
    };
    try wire.writeAll(pipe_fds[1], std.mem.asBytes(&body));
    try wire.writeAll(pipe_fds[1], cmd);
    try wire.writeAll(pipe_fds[1], cwd);

    var scratch: [128]u8 = undefined;
    var payload = (try readShellEventPayload(
        std.testing.allocator,
        pipe_fds[0],
        @sizeOf(wire.ForwardedShellEvent) + cmd.len + cwd.len,
        &scratch,
    )).?;
    defer payload.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &uuid, &payload.uuid);
    try std.testing.expect(!payload.phase_start);
    try std.testing.expectEqual(@as(?i32, 7), payload.status);
    try std.testing.expectEqual(@as(?u64, 123), payload.duration_ms);
    try std.testing.expectEqual(@as(?u64, 99), payload.started_at_ms);
    try std.testing.expectEqual(@as(?u16, 2), payload.jobs);
    try std.testing.expect(!payload.running);
    try std.testing.expectEqualStrings(cmd, payload.cmd.?);
    try std.testing.expectEqualStrings(cwd, payload.cwd.?);
}

test "readSendKeysPayload extracts target uuid and bytes" {
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    const uuid = [_]u8{'k'} ** 32;
    const bytes = "hello";
    const body = wire.SendKeys{
        .uuid = uuid,
        .data_len = @intCast(bytes.len),
    };
    try wire.writeAll(pipe_fds[1], std.mem.asBytes(&body));
    try wire.writeAll(pipe_fds[1], bytes);

    var scratch: [128]u8 = undefined;
    var payload = (try readSendKeysPayload(
        std.testing.allocator,
        pipe_fds[0],
        @sizeOf(wire.SendKeys) + bytes.len,
        &scratch,
    )).?;
    defer payload.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &uuid, &payload.uuid);
    try std.testing.expectEqualStrings(bytes, payload.data);
}

test "readNotifyPayload extracts owned notification message" {
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    const message = "hello mux";
    const body = wire.Notify{ .msg_len = @intCast(message.len) };
    try wire.writeAll(pipe_fds[1], std.mem.asBytes(&body));
    try wire.writeAll(pipe_fds[1], message);

    var scratch: [128]u8 = undefined;
    var payload = (try readNotifyPayload(
        std.testing.allocator,
        pipe_fds[0],
        @sizeOf(wire.Notify) + message.len,
        &scratch,
    )).?;
    defer payload.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(message, payload.message);
}

test "readTargetedNotifyPayload extracts target, duration, and message" {
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    const uuid = [_]u8{'n'} ** 32;
    const message = "hello pane";
    const body = wire.TargetedNotify{
        .uuid = uuid,
        .timeout_ms = 1500,
        .msg_len = @intCast(message.len),
    };
    try wire.writeAll(pipe_fds[1], std.mem.asBytes(&body));
    try wire.writeAll(pipe_fds[1], message);

    var scratch: [128]u8 = undefined;
    var payload = (try readTargetedNotifyPayload(
        std.testing.allocator,
        pipe_fds[0],
        @sizeOf(wire.TargetedNotify) + message.len,
        &scratch,
    )).?;
    defer payload.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &uuid, &payload.uuid);
    try std.testing.expectEqual(@as(?i64, 1500), payload.timeout_ms);
    try std.testing.expectEqualStrings(message, payload.message);
}

test "readFocusMovePayload maps wire direction to frontend direction" {
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    const uuid = [_]u8{'f'} ** 32;
    const body = wire.FocusMove{
        .uuid = uuid,
        .dir = 2,
    };
    try wire.writeAll(pipe_fds[1], std.mem.asBytes(&body));

    var scratch: [128]u8 = undefined;
    const payload = (try readFocusMovePayload(
        pipe_fds[0],
        @sizeOf(wire.FocusMove),
        &scratch,
    )).?;

    try std.testing.expectEqualSlices(u8, &uuid, &payload.uuid);
    try std.testing.expectEqual(@import("actions.zig").Direction.up, payload.direction.?);
}

test "readExitIntentPayload extracts target uuid" {
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    const uuid = [_]u8{'x'} ** 32;
    const body = wire.ExitIntent{ .uuid = uuid };
    try wire.writeAll(pipe_fds[1], std.mem.asBytes(&body));

    var scratch: [128]u8 = undefined;
    const payload = (try readExitIntentPayload(
        pipe_fds[0],
        @sizeOf(wire.ExitIntent),
        &scratch,
    )).?;

    try std.testing.expectEqualSlices(u8, &uuid, &payload.uuid);
}

test "readPopConfirmPayload extracts popup target and message" {
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    const uuid = [_]u8{'p'} ** 32;
    const message = "continue?";
    const body = wire.PopConfirm{
        .uuid = uuid,
        .timeout_ms = 2500,
        .msg_len = @intCast(message.len),
    };
    try wire.writeAll(pipe_fds[1], std.mem.asBytes(&body));
    try wire.writeAll(pipe_fds[1], message);

    var scratch: [128]u8 = undefined;
    var payload = (try readPopConfirmPayload(
        std.testing.allocator,
        pipe_fds[0],
        @sizeOf(wire.PopConfirm) + message.len,
        &scratch,
    )).?;
    defer payload.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &uuid, &payload.uuid);
    try std.testing.expectEqual(@as(?i64, 2500), payload.timeout_ms);
    try std.testing.expectEqualStrings(message, payload.message);
}

test "readPopChoosePayload extracts title and owned item list" {
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    const uuid = [_]u8{'o'} ** 32;
    const title = "choose one";
    const first = "alpha";
    const second = "beta";
    const first_len: u16 = @intCast(first.len);
    const second_len: u16 = @intCast(second.len);
    const body = wire.PopChoose{
        .uuid = uuid,
        .timeout_ms = 5000,
        .title_len = @intCast(title.len),
        .item_count = 2,
    };
    try wire.writeAll(pipe_fds[1], std.mem.asBytes(&body));
    try wire.writeAll(pipe_fds[1], title);
    try wire.writeAll(pipe_fds[1], std.mem.asBytes(&first_len));
    try wire.writeAll(pipe_fds[1], first);
    try wire.writeAll(pipe_fds[1], std.mem.asBytes(&second_len));
    try wire.writeAll(pipe_fds[1], second);

    var scratch: [128]u8 = undefined;
    var payload = (try readPopChoosePayload(
        std.testing.allocator,
        pipe_fds[0],
        @sizeOf(wire.PopChoose) + title.len + 2 + first.len + 2 + second.len,
        &scratch,
    )).?;
    defer payload.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &uuid, &payload.uuid);
    try std.testing.expectEqual(@as(?i64, 5000), payload.timeout_ms);
    try std.testing.expectEqualStrings(title, payload.title.?);
    try std.testing.expectEqual(@as(usize, 2), payload.items.len);
    try std.testing.expectEqualStrings(first, payload.items[0]);
    try std.testing.expectEqualStrings(second, payload.items[1]);
}
