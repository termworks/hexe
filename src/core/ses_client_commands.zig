//! SesClient session-mutation commands: the fire-and-ack CTL senders that
//! mutate canonical session structure (tabs, floats, splits). Each drains any
//! queued control responses, writes the request, and awaits its ack — the
//! client-side mirror of `server_session_handlers`.
//!
//! Extracted from `frontend_client.zig` as free functions taking `*SesClient`
//! and re-exported there via `pub const` aliases, so call sites are unchanged
//! (PLAN.md 2.3). They rely only on the client's `ctl_fd` plus its (now `pub`)
//! request/ack helpers: `drainQueuedControlResponses`, `writeControlRequest`,
//! `writeControlTrailRequest`, `readCommandAckForRequest`.

const std = @import("std");
const session_model = @import("session_model.zig");
const wire = @import("wire.zig");
const frontend_client = @import("frontend_client.zig");

const SesClient = frontend_client.SesClient;

pub fn sessionAddTab(
    self: *SesClient,
    tab_uuid: [32]u8,
    pane_uuid: [32]u8,
    tab_index: usize,
    name: []const u8,
) !void {
    const fd = self.ctl_fd orelse return error.NotConnected;
    var msg: wire.SessionAddTab = .{
        .tab_uuid = tab_uuid,
        .pane_uuid = pane_uuid,
        .tab_index = @intCast(tab_index),
        .name_len = @intCast(name.len),
    };
    self.drainQueuedControlResponses(fd);
    const request_id = try self.writeControlTrailRequest(fd, .session_add_tab, std.mem.asBytes(&msg), name);
    try self.readCommandAckForRequest(fd, request_id);
}

pub fn sessionRemoveTab(self: *SesClient, tab_uuid: [32]u8, active_tab: ?usize) !void {
    const fd = self.ctl_fd orelse return error.NotConnected;
    var msg: wire.SessionRemoveTab = .{
        .tab_uuid = tab_uuid,
        .active_tab = @intCast(active_tab orelse 0),
        .has_active_tab = if (active_tab != null) 1 else 0,
    };
    self.drainQueuedControlResponses(fd);
    const request_id = try self.writeControlRequest(fd, .session_remove_tab, std.mem.asBytes(&msg));
    try self.readCommandAckForRequest(fd, request_id);
}

pub fn sessionSyncFloat(
    self: *SesClient,
    pane_uuid: [32]u8,
    active_tab: ?usize,
    parent_tab: ?usize,
    visible: bool,
    tab_visible: u64,
    sticky: bool,
    is_pwd: bool,
    float_key: u8,
    width_pct: u8,
    height_pct: u8,
    pos_x_pct: u8,
    pos_y_pct: u8,
    pad_x: u8,
    pad_y: u8,
    active: bool,
) !void {
    const fd = self.ctl_fd orelse return error.NotConnected;
    var msg: wire.SessionSyncFloat = .{
        .pane_uuid = pane_uuid,
        .active_tab = @intCast(active_tab orelse 0),
        .parent_tab = @intCast(parent_tab orelse 0),
        .tab_visible = tab_visible,
        .has_active_tab = if (active_tab != null) 1 else 0,
        .has_parent_tab = if (parent_tab != null) 1 else 0,
        .visible = @intFromBool(visible),
        .sticky = @intFromBool(sticky),
        .is_pwd = @intFromBool(is_pwd),
        .float_key = float_key,
        .width_pct = width_pct,
        .height_pct = height_pct,
        .pos_x_pct = pos_x_pct,
        .pos_y_pct = pos_y_pct,
        .pad_x = pad_x,
        .pad_y = pad_y,
        .active = @intFromBool(active),
    };
    self.drainQueuedControlResponses(fd);
    const request_id = try self.writeControlRequest(fd, .session_sync_float, std.mem.asBytes(&msg));
    try self.readCommandAckForRequest(fd, request_id);
}

pub fn sessionRemoveFloat(self: *SesClient, pane_uuid: [32]u8) !void {
    const fd = self.ctl_fd orelse return error.NotConnected;
    var msg: wire.SessionRemoveFloat = .{ .pane_uuid = pane_uuid };
    self.drainQueuedControlResponses(fd);
    const request_id = try self.writeControlRequest(fd, .session_remove_float, std.mem.asBytes(&msg));
    try self.readCommandAckForRequest(fd, request_id);
}

pub fn sessionSplitPane(
    self: *SesClient,
    tab_uuid: [32]u8,
    source_pane_uuid: [32]u8,
    new_pane_uuid: [32]u8,
    active_tab: usize,
    focused_pane_uuid: ?[32]u8,
    dir: session_model.SessionSplitDir,
) !void {
    const fd = self.ctl_fd orelse return error.NotConnected;
    var msg: wire.SessionSplitPane = .{
        .tab_uuid = tab_uuid,
        .source_pane_uuid = source_pane_uuid,
        .new_pane_uuid = new_pane_uuid,
        .focused_pane_uuid = if (focused_pane_uuid) |uuid| uuid else .{0} ** 32,
        .active_tab = @intCast(active_tab),
        .dir = switch (dir) {
            .horizontal => 0,
            .vertical => 1,
        },
        .has_focused_pane = if (focused_pane_uuid != null) 1 else 0,
    };
    self.drainQueuedControlResponses(fd);
    const request_id = try self.writeControlRequest(fd, .session_split_pane, std.mem.asBytes(&msg));
    try self.readCommandAckForRequest(fd, request_id);
}

pub fn sessionReplaceSplitPane(
    self: *SesClient,
    tab_uuid: [32]u8,
    old_pane_uuid: [32]u8,
    new_pane_uuid: [32]u8,
    active_tab: usize,
    focused_pane_uuid: ?[32]u8,
) !void {
    const fd = self.ctl_fd orelse return error.NotConnected;
    var msg: wire.SessionReplaceSplitPane = .{
        .tab_uuid = tab_uuid,
        .old_pane_uuid = old_pane_uuid,
        .new_pane_uuid = new_pane_uuid,
        .focused_pane_uuid = if (focused_pane_uuid) |uuid| uuid else .{0} ** 32,
        .active_tab = @intCast(active_tab),
        .has_focused_pane = if (focused_pane_uuid != null) 1 else 0,
    };
    self.drainQueuedControlResponses(fd);
    const request_id = try self.writeControlRequest(fd, .session_replace_split_pane, std.mem.asBytes(&msg));
    try self.readCommandAckForRequest(fd, request_id);
}

pub fn sessionSetSplitRatio(
    self: *SesClient,
    tab_uuid: [32]u8,
    active_tab: usize,
    first_anchor_uuid: [32]u8,
    second_anchor_uuid: [32]u8,
    ratio: f32,
) !void {
    const fd = self.ctl_fd orelse return error.NotConnected;
    var msg: wire.SessionSetSplitRatio = .{
        .tab_uuid = tab_uuid,
        .first_anchor_uuid = first_anchor_uuid,
        .second_anchor_uuid = second_anchor_uuid,
        .active_tab = @intCast(active_tab),
        .ratio = ratio,
    };
    self.drainQueuedControlResponses(fd);
    const request_id = try self.writeControlRequest(fd, .session_set_split_ratio, std.mem.asBytes(&msg));
    try self.readCommandAckForRequest(fd, request_id);
}

pub fn sessionRenameTab(self: *SesClient, tab_uuid: [32]u8, name: []const u8) !void {
    const fd = self.ctl_fd orelse return error.NotConnected;
    var msg: wire.SessionRenameTab = .{
        .tab_uuid = tab_uuid,
        .name_len = @intCast(name.len),
    };
    self.drainQueuedControlResponses(fd);
    const request_id = try self.writeControlTrailRequest(fd, .session_rename_tab, std.mem.asBytes(&msg), name);
    try self.readCommandAckForRequest(fd, request_id);
}
