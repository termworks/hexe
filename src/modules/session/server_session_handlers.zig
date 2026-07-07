//! SES session-mutation CTL handlers, extracted from server.zig (PLAN.md 2.3
//! god-object split). Pure move — these are Server methods relocated to a
//! sibling file; they take `*Server` and call back into its (now pub) helpers.
//! server.zig dispatches to them by name.
const std = @import("std");
const posix = std.posix;
const core = @import("core");
const wire = core.wire;
const server = @import("server.zig");
const Server = server.Server;

pub fn handleBinarySessionAddTab(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.SessionAddTab)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "session_add_tab: payload too small");
        return;
    }
    const msg = wire.readStruct(wire.SessionAddTab, fd) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "session_add_tab request read failed", err);
        self.sendBinaryError(fd, "session_add_tab: read failed");
        return;
    };
    if (msg.name_len > wire.MAX_PAYLOAD_LEN or msg.name_len > buf.len) {
        self.skipBinaryPayload(fd, msg.name_len, buf);
        self.sendBinaryError(fd, "session_add_tab: name too large");
        return;
    }
    if (msg.name_len > 0) {
        wire.readExact(fd, buf[0..msg.name_len]) catch |err| {
            self.ctlStreamDesynced(fd, "mid-message read failed");
            core.logging.logError("ses", "session_add_tab name read failed", err);
            self.sendBinaryError(fd, "session_add_tab: name read failed");
            return;
        };
    }

    const client_id = self.findClientForCtlFd(fd) orelse {
        core.logging.warn("ses", "session_add_tab from unregistered fd={d}", .{fd});
        self.sendBinaryError(fd, "session_add_tab: client not registered");
        return;
    };
    self.ses_state.addClientSessionTab(
        client_id,
        msg.tab_uuid,
        msg.pane_uuid,
        msg.tab_index,
        buf[0..msg.name_len],
    ) catch |err| {
        core.logging.logError("ses", "session_add_tab snapshot update failed", err);
        self.sendBinaryError(fd, "session_add_tab_failed");
        return;
    };
    self.pushClientSessionSnapshot(client_id);
    self.replyOrClose(fd, .ok, &.{});
}

pub fn handleBinarySessionRemoveTab(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.SessionRemoveTab)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "session_remove_tab: payload too small");
        return;
    }
    const msg = wire.readStruct(wire.SessionRemoveTab, fd) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "session_remove_tab request read failed", err);
        self.sendBinaryError(fd, "session_remove_tab: read failed");
        return;
    };
    const client_id = self.findClientForCtlFd(fd) orelse {
        core.logging.warn("ses", "session_remove_tab from unregistered fd={d}", .{fd});
        self.sendBinaryError(fd, "session_remove_tab: client not registered");
        return;
    };
    const client = self.ses_state.getClient(client_id) orelse {
        core.logging.warn("ses", "session_remove_tab missing client id={d}", .{client_id});
        self.sendBinaryError(fd, "session_remove_tab: client not found");
        return;
    };
    if (!self.requireSnapshotTab(fd, client, msg.tab_uuid, "session_remove_tab")) return;
    self.ses_state.removeClientSessionTab(
        client_id,
        msg.tab_uuid,
        if (msg.has_active_tab != 0) msg.active_tab else null,
    );
    self.pushClientSessionSnapshot(client_id);
    self.replyOrClose(fd, .ok, &.{});
}

pub fn handleBinarySessionRenameTab(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.SessionRenameTab)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "session_rename_tab: payload too small");
        return;
    }
    const msg = wire.readStruct(wire.SessionRenameTab, fd) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "session_rename_tab request read failed", err);
        self.sendBinaryError(fd, "session_rename_tab: read failed");
        return;
    };
    if (msg.name_len > wire.MAX_PAYLOAD_LEN or msg.name_len > buf.len) {
        self.skipBinaryPayload(fd, msg.name_len, buf);
        self.sendBinaryError(fd, "session_rename_tab: name too large");
        return;
    }
    if (msg.name_len > 0) {
        wire.readExact(fd, buf[0..msg.name_len]) catch |err| {
            self.ctlStreamDesynced(fd, "mid-message read failed");
            core.logging.logError("ses", "session_rename_tab name read failed", err);
            self.sendBinaryError(fd, "session_rename_tab: name read failed");
            return;
        };
    }
    const client_id = self.findClientForCtlFd(fd) orelse {
        core.logging.warn("ses", "session_rename_tab from unregistered fd={d}", .{fd});
        self.sendBinaryError(fd, "session_rename_tab: client not registered");
        return;
    };
    const client = self.ses_state.getClient(client_id) orelse {
        core.logging.warn("ses", "session_rename_tab missing client id={d}", .{client_id});
        self.sendBinaryError(fd, "session_rename_tab: client not found");
        return;
    };
    if (!self.requireSnapshotTab(fd, client, msg.tab_uuid, "session_rename_tab")) return;
    self.ses_state.renameClientSessionTab(client_id, msg.tab_uuid, buf[0..msg.name_len]);
    self.ses_state.markDirty();
    self.replyOrClose(fd, .ok, &.{});
}

pub fn handleBinarySessionSyncFloat(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.SessionSyncFloat)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "session_sync_float: payload too small");
        return;
    }
    const msg = wire.readStruct(wire.SessionSyncFloat, fd) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "session_sync_float request read failed", err);
        self.sendBinaryError(fd, "session_sync_float: read failed");
        return;
    };
    const client_id = self.findClientForCtlFd(fd) orelse {
        core.logging.warn("ses", "session_sync_float from unregistered fd={d}", .{fd});
        self.sendBinaryError(fd, "session_sync_float: client not registered");
        return;
    };
    if (!self.requireLiveAttachedPane(fd, client_id, msg.pane_uuid, "session_sync_float")) return;
    self.ses_state.syncClientSessionFloat(
        client_id,
        msg.pane_uuid,
        if (msg.has_active_tab != 0) msg.active_tab else null,
        if (msg.has_parent_tab != 0) msg.parent_tab else null,
        msg.visible != 0,
        msg.tab_visible,
        msg.sticky != 0,
        msg.is_pwd != 0,
        msg.float_key,
        msg.width_pct,
        msg.height_pct,
        msg.pos_x_pct,
        msg.pos_y_pct,
        msg.pad_x,
        msg.pad_y,
        msg.active != 0,
    ) catch |err| {
        core.logging.logError("ses", "session_sync_float snapshot update failed", err);
        self.sendBinaryError(fd, "session_sync_float_failed");
        return;
    };
    self.pushClientSessionSnapshot(client_id);
    self.replyOrClose(fd, .ok, &.{});
}

pub fn handleBinarySessionRemoveFloat(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.SessionRemoveFloat)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "session_remove_float: payload too small");
        return;
    }
    const msg = wire.readStruct(wire.SessionRemoveFloat, fd) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "session_remove_float request read failed", err);
        self.sendBinaryError(fd, "session_remove_float: read failed");
        return;
    };
    const client_id = self.findClientForCtlFd(fd) orelse {
        core.logging.warn("ses", "session_remove_float from unregistered fd={d}", .{fd});
        self.sendBinaryError(fd, "session_remove_float: client not registered");
        return;
    };
    const client = self.ses_state.getClient(client_id) orelse {
        core.logging.warn("ses", "session_remove_float missing client id={d}", .{client_id});
        self.sendBinaryError(fd, "session_remove_float: client not found");
        return;
    };
    if (!self.requireSnapshotPane(fd, client, msg.pane_uuid, "session_remove_float")) return;
    self.ses_state.removeClientSessionFloat(client_id, msg.pane_uuid);
    self.pushClientSessionSnapshot(client_id);
    self.replyOrClose(fd, .ok, &.{});
}

pub fn handleBinarySessionSplitPane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.SessionSplitPane)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "session_split_pane: payload too small");
        return;
    }
    const msg = wire.readStruct(wire.SessionSplitPane, fd) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "session_split_pane request read failed", err);
        self.sendBinaryError(fd, "session_split_pane: read failed");
        return;
    };
    const dir: core.session_model.SessionSplitDir = switch (msg.dir) {
        0 => .horizontal,
        1 => .vertical,
        else => {
            self.sendBinaryError(fd, "session_split_pane: invalid dir");
            return;
        },
    };
    const client_id = self.findClientForCtlFd(fd) orelse {
        core.logging.warn("ses", "session_split_pane from unregistered fd={d}", .{fd});
        self.sendBinaryError(fd, "session_split_pane: client not registered");
        return;
    };
    const client = self.ses_state.getClient(client_id) orelse {
        core.logging.warn("ses", "session_split_pane missing client id={d}", .{client_id});
        self.sendBinaryError(fd, "session_split_pane: client not found");
        return;
    };
    if (!self.requireSnapshotTab(fd, client, msg.tab_uuid, "session_split_pane")) return;
    if (!self.requireSnapshotPane(fd, client, msg.source_pane_uuid, "session_split_pane")) return;
    if (!self.requireLiveAttachedPane(fd, client_id, msg.new_pane_uuid, "session_split_pane")) return;
    self.ses_state.splitClientSessionPane(
        client_id,
        msg.tab_uuid,
        msg.source_pane_uuid,
        msg.new_pane_uuid,
        msg.active_tab,
        if (msg.has_focused_pane != 0) msg.focused_pane_uuid else null,
        dir,
    ) catch |err| {
        core.logging.logError("ses", "session_split_pane snapshot update failed", err);
        self.sendBinaryError(fd, "session_split_pane_failed");
        return;
    };
    self.pushClientSessionSnapshot(client_id);
    self.replyOrClose(fd, .ok, &.{});
}

pub fn handleBinarySessionReplaceSplitPane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.SessionReplaceSplitPane)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "session_replace_split_pane: payload too small");
        return;
    }
    const msg = wire.readStruct(wire.SessionReplaceSplitPane, fd) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "session_replace_split_pane request read failed", err);
        self.sendBinaryError(fd, "session_replace_split_pane: read failed");
        return;
    };
    const client_id = self.findClientForCtlFd(fd) orelse {
        core.logging.warn("ses", "session_replace_split_pane from unregistered fd={d}", .{fd});
        self.sendBinaryError(fd, "session_replace_split_pane: client not registered");
        return;
    };
    const client = self.ses_state.getClient(client_id) orelse {
        core.logging.warn("ses", "session_replace_split_pane missing client id={d}", .{client_id});
        self.sendBinaryError(fd, "session_replace_split_pane: client not found");
        return;
    };
    if (!self.requireSnapshotTab(fd, client, msg.tab_uuid, "session_replace_split_pane")) return;
    if (!self.requireSnapshotPane(fd, client, msg.old_pane_uuid, "session_replace_split_pane")) return;
    if (!self.requireLiveAttachedPane(fd, client_id, msg.new_pane_uuid, "session_replace_split_pane")) return;
    self.ses_state.replaceClientSessionSplitPane(
        client_id,
        msg.tab_uuid,
        msg.old_pane_uuid,
        msg.new_pane_uuid,
        msg.active_tab,
        if (msg.has_focused_pane != 0) msg.focused_pane_uuid else null,
    ) catch |err| {
        core.logging.logError("ses", "session_replace_split_pane snapshot update failed", err);
        self.sendBinaryError(fd, "session_replace_split_pane_failed");
        return;
    };
    self.pushClientSessionSnapshot(client_id);
    self.replyOrClose(fd, .ok, &.{});
}

pub fn handleBinarySessionSetSplitRatio(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.SessionSetSplitRatio)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "session_set_split_ratio: payload too small");
        return;
    }
    const msg = wire.readStruct(wire.SessionSetSplitRatio, fd) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "session_set_split_ratio request read failed", err);
        self.sendBinaryError(fd, "session_set_split_ratio: read failed");
        return;
    };
    const client_id = self.findClientForCtlFd(fd) orelse {
        core.logging.warn("ses", "session_set_split_ratio from unregistered fd={d}", .{fd});
        self.sendBinaryError(fd, "session_set_split_ratio: client not registered");
        return;
    };
    const client = self.ses_state.getClient(client_id) orelse {
        core.logging.warn("ses", "session_set_split_ratio missing client id={d}", .{client_id});
        self.sendBinaryError(fd, "session_set_split_ratio: client not found");
        return;
    };
    if (!self.requireSnapshotTab(fd, client, msg.tab_uuid, "session_set_split_ratio")) return;
    if (!self.requireSnapshotPane(fd, client, msg.first_anchor_uuid, "session_set_split_ratio")) return;
    if (!self.requireSnapshotPane(fd, client, msg.second_anchor_uuid, "session_set_split_ratio")) return;
    self.ses_state.setClientSessionSplitRatio(
        client_id,
        msg.tab_uuid,
        msg.active_tab,
        msg.first_anchor_uuid,
        msg.second_anchor_uuid,
        msg.ratio,
    ) catch |err| {
        core.logging.logError("ses", "session_set_split_ratio snapshot update failed", err);
        self.sendBinaryError(fd, "session_set_split_ratio_failed");
        return;
    };
    self.pushClientSessionSnapshot(client_id);
    self.replyOrClose(fd, .ok, &.{});
}
