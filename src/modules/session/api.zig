const std = @import("std");
const posix = std.posix;
const core = @import("core");
const session_model = core.session_model;

const cleanup_mod = @import("cleanup.zig");
const client_lifecycle = @import("client_lifecycle.zig");
const client_session_snapshot = @import("client_session_snapshot.zig");
const detach_lifecycle = @import("detach_lifecycle.zig");
const detached_sessions = @import("detached_sessions.zig");
const layout_apply = @import("layout_apply.zig");
const locks_mod = @import("locks.zig");
const pane_creation = @import("pane_creation.zig");
const pane_lifecycle = @import("pane_lifecycle.zig");
const snapshot_mod = @import("snapshot.zig");
const sticky_panes = @import("sticky_panes.zig");
const store_mod = @import("store.zig");
const vt_routing = @import("vt_routing.zig");
const session_names = @import("session_names.zig");

pub const removePaneFromSessionSnapshot = snapshot_mod.removePaneFromSessionSnapshot;
pub const ReattachResult = detach_lifecycle.ReattachResult;

pub fn allocPaneId(self: anytype) u16 {
    return self.store.allocPaneId();
}

pub fn updateClientSessionFocus(self: anytype, client_id: usize, pane_uuid: [32]u8, active_tab_hint: ?u16, is_focused: bool) void {
    client_session_snapshot.updateFocus(self, client_id, pane_uuid, active_tab_hint, is_focused);
}

pub fn addClientSessionTab(self: anytype, client_id: usize, tab_uuid: [32]u8, pane_uuid: [32]u8, tab_index: usize, name: []const u8) !void {
    return client_session_snapshot.addTab(self, client_id, tab_uuid, pane_uuid, tab_index, name);
}

pub fn removeClientSessionTab(self: anytype, client_id: usize, tab_uuid: [32]u8, active_tab_hint: ?u16) void {
    client_session_snapshot.removeTab(self, client_id, tab_uuid, active_tab_hint);
}

pub fn splitClientSessionPane(self: anytype, client_id: usize, tab_uuid: [32]u8, source_pane_uuid: [32]u8, new_pane_uuid: [32]u8, active_tab: u16, focused_pane_uuid: ?[32]u8, dir: session_model.SessionSplitDir) !void {
    return client_session_snapshot.splitPane(self, client_id, tab_uuid, source_pane_uuid, new_pane_uuid, active_tab, focused_pane_uuid, dir);
}

pub fn replaceClientSessionSplitPane(self: anytype, client_id: usize, tab_uuid: [32]u8, old_pane_uuid: [32]u8, new_pane_uuid: [32]u8, active_tab: u16, focused_pane_uuid: ?[32]u8) !void {
    return client_session_snapshot.replaceSplitPane(self, client_id, tab_uuid, old_pane_uuid, new_pane_uuid, active_tab, focused_pane_uuid);
}

pub fn setClientSessionSplitRatio(self: anytype, client_id: usize, tab_uuid: [32]u8, active_tab: u16, first_anchor_uuid: [32]u8, second_anchor_uuid: [32]u8, ratio: f32) !void {
    return client_session_snapshot.setSplitRatio(self, client_id, tab_uuid, active_tab, first_anchor_uuid, second_anchor_uuid, ratio);
}

pub fn syncClientSessionFloat(self: anytype, client_id: usize, pane_uuid: [32]u8, active_tab_hint: ?u16, parent_tab_hint: ?u16, visible: bool, tab_visible: u64, sticky: bool, is_pwd: bool, float_key: u8, width_pct: u8, height_pct: u8, pos_x_pct: u8, pos_y_pct: u8, pad_x: u8, pad_y: u8, active: bool) !void {
    return client_session_snapshot.syncFloat(self, client_id, pane_uuid, active_tab_hint, parent_tab_hint, visible, tab_visible, sticky, is_pwd, float_key, width_pct, height_pct, pos_x_pct, pos_y_pct, pad_x, pad_y, active);
}

pub fn removeClientSessionFloat(self: anytype, client_id: usize, pane_uuid: [32]u8) void {
    client_session_snapshot.removeFloat(self, client_id, pane_uuid);
}

pub fn applyClientSessionLayoutTemplate(self: anytype, client_id: usize, source_uuid: [32]u8, tree_json: []const u8) !void {
    return layout_apply.applyClientSessionLayoutTemplate(self, client_id, source_uuid, tree_json);
}

pub fn resolveSessionName(self: anytype, requested_name: []const u8, exclude_client_id: ?usize, exclude_session_id: ?[16]u8) ![]u8 {
    return try session_names.resolveSessionName(self.allocator, &self.store, requested_name, exclude_client_id, exclude_session_id);
}

pub fn connectPodVt(self: anytype, uuid: [32]u8, pod_socket_path: []const u8, pane_id: u16) bool {
    return vt_routing.connectPodVt(self.allocator, &self.store, &self.polling, uuid, pod_socket_path, pane_id);
}

pub fn markDirty(self: anytype) void {
    self.store.markDirty();
}

pub fn acquireSessionLock(self: anytype, session_id: [16]u8, client_id: usize, state: locks_mod.SessionLockState) !void {
    return self.locks.acquire(session_id, client_id, state);
}

pub fn releaseSessionLock(self: anytype, session_id: [16]u8) void {
    self.locks.release(session_id);
}

pub fn releaseClientLocks(self: anytype, client_id: usize) void {
    self.locks.releaseClient(self.allocator, client_id);
}

pub fn isSessionLocked(self: anytype, session_id: [16]u8) bool {
    return self.locks.isLocked(session_id);
}

pub fn cancelPendingReattach(self: anytype, session_id: [16]u8, client_id: usize) bool {
    return detach_lifecycle.cancelPendingReattach(self, session_id, client_id);
}

pub fn deinit(self: anytype) void {
    self.store.deinit();
    self.persistence.deinit();
    self.polling.deinit(self.allocator);
    self.locks.deinit();
}

pub fn addClient(self: anytype, fd: posix.fd_t) !usize {
    return client_lifecycle.addClient(self, fd);
}

pub fn removeClient(self: anytype, client_id: usize) void {
    client_lifecycle.removeClient(self, client_id);
}

pub fn removeClientGraceful(self: anytype, client_id: usize) void {
    client_lifecycle.removeClientGraceful(self, client_id);
}

pub fn shutdownClient(self: anytype, client_id: usize, preserve_sticky: bool) void {
    client_lifecycle.shutdownClient(self, client_id, preserve_sticky);
}

pub fn detachSession(self: anytype, client_id: usize, session_id: [16]u8, session_name: []const u8) bool {
    _ = session_name;
    return detach_lifecycle.detachSession(self, client_id, session_id);
}

pub fn reattachSession(self: anytype, session_id: [16]u8, client_id: usize) !?ReattachResult {
    return detach_lifecycle.reattachSession(self, session_id, client_id);
}

pub fn forceDetachAttachedSession(self: anytype, session_id: [16]u8) bool {
    return detach_lifecycle.forceDetachAttachedSession(self, session_id);
}

pub fn removeDetachedSession(self: anytype, session_id: [16]u8) void {
    detached_sessions.removeDetachedSession(&self.store, session_id);
}

pub fn listDetachedSessions(self: anytype, allocator: std.mem.Allocator) ![]store_mod.DetachedSession {
    return detached_sessions.listDetachedSessions(allocator, &self.store);
}

pub fn getClient(self: anytype, client_id: usize) ?*store_mod.Client {
    return client_lifecycle.getClient(self, client_id);
}

pub fn paneAttachedToClient(self: anytype, uuid: [32]u8, client_id: usize) bool {
    return pane_lifecycle.paneAttachedToClient(&self.store, uuid, client_id);
}

pub fn createPane(self: anytype, client_id: usize, shell: []const u8, cwd: ?[]const u8, sticky_pwd: ?[]const u8, sticky_key: ?u8, env: ?[]const []const u8, isolation_profile: ?[]const u8) !*store_mod.Pane {
    return pane_creation.createPane(self, client_id, shell, cwd, sticky_pwd, sticky_key, env, isolation_profile);
}

pub fn findStickyPane(self: anytype, pwd: []const u8, key: u8) ?*store_mod.Pane {
    return sticky_panes.findStickyPane(&self.store, pwd, key);
}

pub fn findStickyPaneWithAffinity(self: anytype, pwd: []const u8, key: u8, preferred_session_name: ?[]const u8) ?*store_mod.Pane {
    return sticky_panes.findStickyPaneWithAffinity(&self.store, pwd, key, preferred_session_name);
}

pub fn stealAttachedPane(self: anytype, uuid: [32]u8, new_client_id: usize) bool {
    return pane_lifecycle.stealAttachedPane(self, uuid, new_client_id);
}

pub fn attachPane(self: anytype, uuid: [32]u8, client_id: usize) !*store_mod.Pane {
    return pane_lifecycle.attachPane(self, uuid, client_id);
}

pub fn processBacklogReplays(self: anytype) void {
    pane_lifecycle.processBacklogReplays(self);
}

pub fn suspendPane(self: anytype, uuid: [32]u8) !void {
    return pane_lifecycle.suspendPane(self, uuid);
}

pub fn killPane(self: anytype, uuid: [32]u8) !void {
    return pane_lifecycle.killPane(self, uuid);
}

pub fn getOrphanedPanes(self: anytype, allocator: std.mem.Allocator) ![]store_mod.Pane {
    return cleanup_mod.getOrphanedPanes(&self.store, allocator);
}

pub fn cleanupOrphanedPanes(self: anytype) void {
    cleanup_mod.cleanupOrphanedPanes(self);
}

pub fn cleanupExpiredDetachedSessions(self: anytype) void {
    cleanup_mod.cleanupExpiredDetachedSessions(self);
}

pub fn cleanupDetachedSessions(self: anytype) void {
    cleanup_mod.cleanupDetachedSessions(self);
}

pub fn checkPaneAlive(self: anytype, uuid: [32]u8) bool {
    return cleanup_mod.checkPaneAlive(&self.store, uuid);
}

pub fn getPane(self: anytype, uuid: [32]u8) ?*store_mod.Pane {
    return self.store.panes.getPtr(uuid);
}

pub fn killDetachedSession(self: anytype, session_id: [16]u8) ?usize {
    return cleanup_mod.killDetachedSession(self, session_id);
}

pub fn killAllDetachedSessions(self: anytype) cleanup_mod.KillAllDetachedSessionsResult {
    return cleanup_mod.killAllDetachedSessions(self);
}

pub fn killAllOrphanedPanes(self: anytype) usize {
    return cleanup_mod.killAllOrphanedPanes(self);
}

pub fn findDetachedSessionByNameOrPrefix(self: anytype, id: []const u8) ?[16]u8 {
    return detached_sessions.findByNameOrPrefix(&self.store, id);
}
