const std = @import("std");
const core = @import("core");
const terminal_main = @import("main.zig");
const session_model = core.session_model;

const state_types = @import("state_types.zig");
const TabView = state_types.TabView;

const layout_mod = @import("layout.zig");
const LayoutNode = layout_mod.LayoutNode;

const Pane = @import("pane.zig").Pane;
const OrphanedPaneInfo = core.FrontendOrphanedPaneInfo;

const SessionSnapshot = session_model.SessionSnapshot;
const SessionLayoutNode = session_model.SessionLayoutNode;
const SessionFloat = session_model.SessionFloat;
const AdoptInfo = struct { pane_id: u16 };
const ExistingPaneViews = std.AutoHashMap([32]u8, *Pane);

fn applyDeferredPaneExits(self: anytype) void {
    var pending: std.ArrayList([32]u8) = .empty;
    defer pending.deinit(self.allocator);
    self.runtime.drainPendingPaneExits(&pending);

    for (pending.items) |uuid| {
        var marked = false;

        for (self.view.tab_views.items) |*tab| {
            var it = tab.layout.splits.valueIterator();
            while (it.next()) |pane_ptr| {
                if (std.mem.eql(u8, &pane_ptr.*.uuid, &uuid)) {
                    pane_ptr.*.backend.pod.dead = true;
                    marked = true;
                }
            }
        }

        for (self.view.float_views.items) |pane| {
            if (std.mem.eql(u8, &pane.uuid, &uuid)) {
                pane.backend.pod.dead = true;
                marked = true;
            }
        }

        if (marked) {
            terminal_main.debugLog("reattachSession: applied deferred pane_exited uuid={s}", .{uuid[0..8]});
        }
    }
}

fn normalizeRestoredSessionName(name: []const u8) []const u8 {
    if (name.len >= 3) {
        const last_char = name[name.len - 1];
        if (last_char >= '1' and last_char <= '9' and name[name.len - 2] == '-') {
            return name[0 .. name.len - 2];
        }
    }
    return name;
}

fn clearStateForRestore(self: anytype) void {
    while (self.view.tab_views.items.len > 0) {
        const tab_opt = self.view.tab_views.pop();
        if (tab_opt) |tab_const| {
            var tab = tab_const;
            var split_it = tab.layout.splits.valueIterator();
            while (split_it.next()) |pane_ptr| {
                self.clearTransientPaneState(pane_ptr.*);
            }
            tab.deinit();
        }
    }

    while (self.view.float_views.items.len > 0) {
        const p_opt = self.view.float_views.pop();
        if (p_opt) |p| {
            self.clearTransientPaneState(p);
            self.clearFloatUi(p.uuid);
            p.deinit();
            self.allocator.destroy(p);
        }
    }

    self.setActiveTabIndex(0);
    self.setActiveFloatingIndex(null);
    self.runtime.setFocusedPaneUuid(null);
    self.runtime.clearTabFocusMemory();
}

fn deinitTabPreservingPanes(tab: *TabView) void {
    tab.layout.splits.deinit();
    if (tab.layout.root) |root| {
        tab.layout.freeNode(root);
        tab.layout.root = null;
    }
    tab.notifications.deinit();
    tab.popups.deinit();
}

fn captureExistingPaneViews(self: anytype, out: *ExistingPaneViews) void {
    for (self.view.tab_views.items) |*tab| {
        var it = tab.layout.splits.valueIterator();
        while (it.next()) |pane_ptr| {
            out.put(pane_ptr.*.uuid, pane_ptr.*) catch {};
        }
    }
    for (self.view.float_views.items) |pane| {
        out.put(pane.uuid, pane) catch {};
    }
}

fn clearStatePreservingPanes(self: anytype) void {
    while (self.view.tab_views.items.len > 0) {
        const tab_opt = self.view.tab_views.pop();
        if (tab_opt) |tab_const| {
            var tab = tab_const;
            deinitTabPreservingPanes(&tab);
        }
    }

    self.view.float_views.clearRetainingCapacity();
    // Keep runtime projection state intact while rebuilding from the current
    // authoritative snapshot. applySessionSnapshot() reads that snapshot after
    // this call, so clearing active/focus fields here corrupts the data we are
    // in the middle of restoring.
}

fn clearPaneAuxCaches(self: anytype, uuid: [32]u8) void {
    self.removePaneProcMetadata(uuid);
    self.removePaneName(uuid);
    self.clearFloatUi(uuid);
    if (self.float_rename_uuid) |rename_uuid| {
        if (std.mem.eql(u8, &rename_uuid, &uuid)) {
            self.float_rename_uuid = null;
            self.float_rename_buf.clearRetainingCapacity();
        }
    }
}

fn destroyUnusedPaneViews(self: anytype, existing_views: *ExistingPaneViews) void {
    var it = existing_views.iterator();
    while (it.next()) |entry| {
        self.clearTransientPaneState(entry.value_ptr.*);
        clearPaneAuxCaches(self, entry.key_ptr.*);
        entry.value_ptr.*.deinit();
        self.allocator.destroy(entry.value_ptr.*);
    }
}

fn recyclePaneForSplit(self: anytype, tab: *TabView, pane: *Pane, pane_id: u16, pane_uuid: [32]u8, actual_focus_uuid: ?[32]u8) void {
    self.clearFloatUi(pane.uuid);
    pane.id = pane_id;
    pane.uuid = pane_uuid;
    pane.focused = if (actual_focus_uuid) |focused_uuid| std.mem.eql(u8, &focused_uuid, &pane_uuid) else false;
    pane.backend.pod.dead = false;
    tab.layout.configurePaneNotifications(pane);
}

fn recyclePaneForFloat(self: anytype, pane: *Pane, float_state: SessionFloat, actual_focus_uuid: ?[32]u8) void {
    self.clearFloatUi(pane.uuid);
    pane.uuid = float_state.pane_uuid;
    pane.focused = if (actual_focus_uuid) |focused_uuid| std.mem.eql(u8, &focused_uuid, &float_state.pane_uuid) else false;
    _ = self.setPaneFloatUi(float_state.pane_uuid, .{
        .width_pct = float_state.width_pct,
        .height_pct = float_state.height_pct,
        .pos_x_pct = float_state.pos_x_pct,
        .pos_y_pct = float_state.pos_y_pct,
        .pad_x = float_state.pad_x,
        .pad_y = float_state.pad_y,
    });
    pane.backend.pod.dead = false;
}

fn hydratePaneMetadata(self: anytype, _: *Pane, uuid: [32]u8) void {
    if (self.runtime.getPaneInfoSnapshot(uuid)) |snap| {
        defer if (snap.cwd) |cwd| self.allocator.free(cwd);
        defer if (snap.fg_name) |s| self.allocator.free(s);
        if (snap.name) |name| {
            self.setPaneNameOwned(uuid, name);
        }
        if (snap.cwd) |cwd| {
            self.setPaneShell(uuid, null, cwd, null, null, null);
        }
        self.setPaneProc(uuid, snap.fg_name, snap.fg_pid);
    } else {
        self.runtime.requestPaneProcess(uuid);
        self.runtime.requestPaneCwd(uuid);
    }
}

fn ensureAdoptInfo(
    self: anytype,
    uuid: [32]u8,
    uuid_pane_map: *std.AutoHashMap([32]u8, AdoptInfo),
    existing_views: ?*ExistingPaneViews,
    attached_snapshot: bool,
) ?AdoptInfo {
    if (uuid_pane_map.get(uuid)) |info| return info;
    if (existing_views) |views| {
        if (views.get(uuid)) |pane| {
            if (pane.getPaneId()) |pane_id| {
                return .{ .pane_id = pane_id };
            }
        }
    }
    if (attached_snapshot) {
        if (self.runtime.getPaneInfoSnapshot(uuid)) |snap| {
            defer if (snap.name) |s| self.allocator.free(s);
            defer if (snap.cwd) |s| self.allocator.free(s);
            defer if (snap.fg_name) |s| self.allocator.free(s);
            if (snap.pane_id) |pane_id| {
                const info = AdoptInfo{ .pane_id = pane_id };
                uuid_pane_map.put(uuid, info) catch {};
                return info;
            }
        }
    }
    if (self.runtime.adoptPane(uuid)) |adopt_res| {
        const info = AdoptInfo{ .pane_id = adopt_res.pane_id };
        uuid_pane_map.put(uuid, info) catch {};
        return info;
    } else |_| {
        return null;
    }
}

fn ensureSplitPaneView(
    self: anytype,
    tab: *TabView,
    pane_uuid: [32]u8,
    uuid_pane_map: *std.AutoHashMap([32]u8, AdoptInfo),
    existing_views: ?*ExistingPaneViews,
    attached_snapshot: bool,
    used_uuids: *std.AutoHashMap([32]u8, void),
    remembered_focus_uuid: ?[32]u8,
    actual_focus_uuid: ?[32]u8,
) bool {
    if (tab.layout.splits.contains(pane_uuid)) return true;
    if (used_uuids.contains(pane_uuid)) return false;

    const info = ensureAdoptInfo(self, pane_uuid, uuid_pane_map, existing_views, attached_snapshot) orelse return false;
    const vt_fd = self.runtime.getVtFd() orelse return false;

    const view_id = tab.layout.next_pane_view_id;
    tab.layout.next_pane_view_id +%= 1;

    const pane = blk: {
        if (existing_views) |views| {
            if (views.fetchRemove(pane_uuid)) |entry| {
                const pane = entry.value;
                if (pane.getPaneId() != info.pane_id or !std.mem.eql(u8, &pane.uuid, &pane_uuid)) {
                    pane.replaceWithPod(info.pane_id, vt_fd, pane_uuid) catch {
                        pane.deinit();
                        self.allocator.destroy(pane);
                        return false;
                    };
                }
                recyclePaneForSplit(self, tab, pane, view_id, pane_uuid, actual_focus_uuid);
                break :blk pane;
            }
        }

        const pane = self.allocator.create(Pane) catch return false;
        errdefer self.allocator.destroy(pane);

        pane.initWithPod(self.allocator, view_id, 0, 0, self.layout_width, self.layout_height, info.pane_id, vt_fd, pane_uuid) catch return false;
        recyclePaneForSplit(self, tab, pane, view_id, pane_uuid, actual_focus_uuid);
        pane.configureNotificationsFromPop(&self.pop_config.pane.notification);
        break :blk pane;
    };

    hydratePaneMetadata(self, pane, pane_uuid);

    tab.layout.splits.put(pane_uuid, pane) catch {
        pane.deinit();
        self.allocator.destroy(pane);
        return false;
    };
    used_uuids.put(pane_uuid, {}) catch {};

    if (remembered_focus_uuid) |focus_uuid| {
        if (std.mem.eql(u8, &focus_uuid, &pane_uuid)) {
            tab.layout.focused_pane_uuid = pane_uuid;
        }
    }

    return true;
}

fn freeRestoredLayoutNode(allocator: std.mem.Allocator, node: *LayoutNode) void {
    switch (node.*) {
        .pane => {},
        .split => |split| {
            freeRestoredLayoutNode(allocator, split.first);
            freeRestoredLayoutNode(allocator, split.second);
        },
    }
    allocator.destroy(node);
}

fn restoreLayoutNode(
    self: anytype,
    tab: *TabView,
    node: *const SessionLayoutNode,
    uuid_pane_map: *std.AutoHashMap([32]u8, AdoptInfo),
    existing_views: ?*ExistingPaneViews,
    attached_snapshot: bool,
    used_uuids: *std.AutoHashMap([32]u8, void),
    remembered_focus_uuid: ?[32]u8,
    actual_focus_uuid: ?[32]u8,
) ?*LayoutNode {
    switch (node.*) {
        .pane => |pane_uuid| {
            const ok = ensureSplitPaneView(
                self,
                tab,
                pane_uuid,
                uuid_pane_map,
                existing_views,
                attached_snapshot,
                used_uuids,
                remembered_focus_uuid,
                actual_focus_uuid,
            );
            if (!ok) return null;
            const restored = self.allocator.create(LayoutNode) catch return null;
            restored.* = .{ .pane = pane_uuid };
            return restored;
        },
        .split => |split| {
            const first = restoreLayoutNode(self, tab, split.first, uuid_pane_map, existing_views, attached_snapshot, used_uuids, remembered_focus_uuid, actual_focus_uuid);
            const second = restoreLayoutNode(self, tab, split.second, uuid_pane_map, existing_views, attached_snapshot, used_uuids, remembered_focus_uuid, actual_focus_uuid);

            if (first == null and second == null) return null;
            if (first == null) return second;
            if (second == null) return first;

            const restored = self.allocator.create(LayoutNode) catch {
                if (first) |f| {
                    freeRestoredLayoutNode(self.allocator, f);
                }
                if (second) |s| {
                    freeRestoredLayoutNode(self.allocator, s);
                }
                return null;
            };
            restored.* = .{
                .split = .{
                    .dir = if (split.dir == .horizontal) .horizontal else .vertical,
                    .ratio = split.ratio,
                    .first = first.?,
                    .second = second.?,
                },
            };
            return restored;
        },
    }
}

fn restoreFloatPane(
    self: anytype,
    float_state: SessionFloat,
    uuid_pane_map: *std.AutoHashMap([32]u8, AdoptInfo),
    existing_views: ?*ExistingPaneViews,
    attached_snapshot: bool,
    used_uuids: *std.AutoHashMap([32]u8, void),
    actual_focus_uuid: ?[32]u8,
) ?*Pane {
    if (used_uuids.contains(float_state.pane_uuid)) return null;
    const info = ensureAdoptInfo(self, float_state.pane_uuid, uuid_pane_map, existing_views, attached_snapshot) orelse return null;
    const vt_fd = self.runtime.getVtFd() orelse return null;
    const preserved_title = blk: {
        if (existing_views) |views| {
            if (views.get(float_state.pane_uuid)) |existing_pane| {
                if (self.paneFloatTitle(existing_pane)) |title| {
                    break :blk self.allocator.dupe(u8, title) catch null;
                }
            }
        }
        break :blk null;
    };
    defer if (preserved_title) |title| self.allocator.free(title);

    const pane = blk: {
        if (existing_views) |views| {
            if (views.fetchRemove(float_state.pane_uuid)) |entry| {
                const pane = entry.value;
                if (pane.getPaneId() != info.pane_id or !std.mem.eql(u8, &pane.uuid, &float_state.pane_uuid)) {
                    pane.replaceWithPod(info.pane_id, vt_fd, float_state.pane_uuid) catch {
                        pane.deinit();
                        self.allocator.destroy(pane);
                        return null;
                    };
                }
                break :blk pane;
            }
        }

        const pane = self.allocator.create(Pane) catch return null;
        errdefer self.allocator.destroy(pane);

        const local_id: u16 = @intCast(100 + self.view.float_views.items.len);
        pane.initWithPod(self.allocator, local_id, 0, 0, self.layout_width, self.layout_height, info.pane_id, vt_fd, float_state.pane_uuid) catch return null;
        pane.configureNotificationsFromPop(&self.pop_config.pane.notification);
        break :blk pane;
    };
    pane.id = @intCast(100 + self.view.float_views.items.len);
    pane.uuid = float_state.pane_uuid;
    recyclePaneForFloat(self, pane, float_state, actual_focus_uuid);
    hydratePaneMetadata(self, pane, float_state.pane_uuid);

    const restored_title = blk: {
        if (float_state.float_key != 0) {
            if (self.getLayoutFloatByKey(float_state.float_key)) |float_def| {
                if (float_def.title) |title| break :blk title;
            }
        }
        if (preserved_title) |title| break :blk title;
        break :blk null;
    };
    const visuals = self.resolveFloatVisuals(if (float_state.float_key != 0) .named else .adhoc, restored_title);
    self.setPaneBorderFrame(
        pane.uuid,
        self.paneBorderX(pane),
        self.paneBorderY(pane),
        self.paneBorderW(pane),
        self.paneBorderH(pane),
        visuals.border_color,
    );
    if (self.floatUi(pane)) |ui| {
        ui.float_style = visuals.float_style;
    }
    _ = self.setPaneFloatTitle(pane.uuid, restored_title);

    used_uuids.put(float_state.pane_uuid, {}) catch {};
    return pane;
}

fn countSessionLayoutPanes(node: ?*const SessionLayoutNode) usize {
    const root = node orelse return 0;
    return switch (root.*) {
        .pane => 1,
        .split => |split| countSessionLayoutPanes(split.first) + countSessionLayoutPanes(split.second),
    };
}

fn layoutMatchesSnapshot(layout: *const layout_mod.Layout, node: ?*const LayoutNode, snapshot_node: ?*const SessionLayoutNode) bool {
    const live = node orelse return snapshot_node == null;
    const expected = snapshot_node orelse return false;

    return switch (live.*) {
        .pane => |pane_uuid| switch (expected.*) {
            .pane => |expected_uuid| std.mem.eql(u8, &pane_uuid, &expected_uuid),
            .split => false,
        },
        .split => |split| switch (expected.*) {
            .pane => false,
            .split => |expected_split| split.dir == @as(layout_mod.SplitDir, if (expected_split.dir == .horizontal) .horizontal else .vertical) and
                std.math.approxEqAbs(f32, split.ratio, expected_split.ratio, 0.0001) and
                layoutMatchesSnapshot(layout, split.first, expected_split.first) and
                layoutMatchesSnapshot(layout, split.second, expected_split.second),
        },
    };
}

fn canApplySnapshotIncrementally(self: anytype, snapshot: *const SessionSnapshot) bool {
    if (self.view.tab_views.items.len != snapshot.tabs.items.len) return false;
    if (self.view.float_views.items.len != snapshot.floats.items.len) return false;

    // The incremental path is safe only when float visibility/focus stays in a
    // simple "one active visible float" shape. Hidden/background/per-tab floats
    // have been the crashy case during toggle-hide, so force the conservative
    // rebuild path there.
    if (snapshot.floats.items.len > 0) {
        if (snapshot.active_float_uuid == null) return false;
        for (snapshot.floats.items) |float_state| {
            if (float_state.parent_tab != null) {
                if (!float_state.visible) return false;
            } else {
                if (float_state.tab_visible != std.math.maxInt(u64)) return false;
            }
        }
    }

    for (snapshot.tabs.items, 0..) |snapshot_tab, idx| {
        if (!std.mem.eql(u8, &snapshot_tab.uuid, &(self.runtime.tabUuid(idx) orelse return false))) return false;
        if (!std.mem.eql(u8, snapshot_tab.name, self.runtime.tabName(idx) orelse "tab")) return false;

        const live_tab = &self.view.tab_views.items[idx];
        if (live_tab.layout.splits.count() != countSessionLayoutPanes(snapshot_tab.root)) return false;
        if (!layoutMatchesSnapshot(&live_tab.layout, live_tab.layout.root, snapshot_tab.root)) return false;
    }

    for (snapshot.floats.items, 0..) |float_state, idx| {
        if (!std.mem.eql(u8, &self.view.float_views.items[idx].uuid, &float_state.pane_uuid)) return false;
    }

    return true;
}

fn applyTabSnapshotFocus(tab: *TabView, remembered_focus_uuid: ?[32]u8, actual_focus_uuid: ?[32]u8) void {
    const target_focus_uuid = remembered_focus_uuid orelse actual_focus_uuid;

    var found_focus = false;
    var it = tab.layout.splits.iterator();
    while (it.next()) |entry| {
        const pane = entry.value_ptr.*;
        const matches_actual = if (actual_focus_uuid) |focused_uuid|
            std.mem.eql(u8, &pane.uuid, &focused_uuid)
        else
            false;
        pane.focused = matches_actual;

        if (target_focus_uuid) |focused_uuid| {
            if (std.mem.eql(u8, &pane.uuid, &focused_uuid)) {
                tab.layout.focused_pane_uuid = entry.key_ptr.*;
                found_focus = true;
            }
        }
    }

    if (!found_focus) {
        var first = tab.layout.splits.iterator();
        if (first.next()) |entry| {
            tab.layout.focused_pane_uuid = entry.key_ptr.*;
        }
    }
}

fn updateFloatPresentation(self: anytype, pane: *Pane, float_state: SessionFloat, actual_focus_uuid: ?[32]u8) void {
    pane.focused = if (actual_focus_uuid) |focused_uuid|
        std.mem.eql(u8, &focused_uuid, &float_state.pane_uuid)
    else
        false;
    self.setPaneFloatGeometryUi(
        pane.uuid,
        float_state.width_pct,
        float_state.height_pct,
        float_state.pos_x_pct,
        float_state.pos_y_pct,
        float_state.pad_x,
        float_state.pad_y,
    );

    if (self.floatUi(pane)) |ui| {
        if (!float_state.is_pwd and ui.pwd_dir != null) {
            self.allocator.free(ui.pwd_dir.?);
            ui.pwd_dir = null;
        }
    }
    var title = self.paneFloatTitle(pane);
    if (title == null and float_state.float_key != 0) {
        if (self.getLayoutFloatByKey(float_state.float_key)) |float_def| {
            title = float_def.title;
        }
    }
    const visuals = self.resolveFloatVisuals(if (float_state.float_key != 0) .named else .adhoc, title);
    if (self.floatUi(pane)) |ui| {
        ui.float_style = visuals.float_style;
    }
    self.setPaneBorderFrame(
        pane.uuid,
        self.paneBorderX(pane),
        self.paneBorderY(pane),
        self.paneBorderW(pane),
        self.paneBorderH(pane),
        visuals.border_color,
    );
}

fn applySnapshotIncrementally(self: anytype, snapshot: *const SessionSnapshot) bool {
    if (!canApplySnapshotIncrementally(self, snapshot)) return false;

    for (snapshot.tabs.items, 0..) |snapshot_tab, idx| {
        applyTabSnapshotFocus(&self.view.tab_views.items[idx], snapshot_tab.focused_pane_uuid, snapshot.focused_pane_uuid);
    }

    for (snapshot.floats.items, 0..) |float_state, idx| {
        updateFloatPresentation(self, self.view.float_views.items[idx], float_state, snapshot.focused_pane_uuid);
    }

    self.resizeFloatingPanes();

    if (self.view.tab_views.items.len > 0) {
        self.setActiveTabIndex(@min(snapshot.active_tab, self.view.tab_views.items.len - 1));
    } else {
        self.setActiveTabIndex(0);
    }
    self.setActiveFloatingUuid(snapshot.active_float_uuid);
    self.runtime.setFocusedPaneUuid(snapshot.focused_pane_uuid);

    if (self.activeFloatingIndex()) |idx| {
        self.rememberFloatingFocus(self.view.float_views.items[idx]);
    } else if (self.view.tab_views.items.len > 0) {
        self.rememberSplitFocus();
    }

    self.renderer.invalidate();
    self.force_full_render = true;
    self.needs_render = true;
    return true;
}

/// Reattach to a detached session, restoring full state.
pub fn reattachSession(self: anytype, session_id_prefix: []const u8) bool {
    terminal_main.debugLog("reattachSession: starting with prefix={s}", .{session_id_prefix});

    // Set flag to prevent SIGHUP from interrupting reattach
    self.runtime.beginReattach();
    defer self.runtime.endReattach();

    // Track reattach start time for timeout detection
    const reattach_start = std.time.milliTimestamp();

    if (!self.runtime.isConnected()) {
        terminal_main.debugLog("reattachSession: runtime not connected, aborting", .{});
        return false;
    }

    // Try to reattach session (server supports prefix matching).
    terminal_main.debugLog("reattachSession: calling runtime.reattachSessionProjection", .{});
    const result = self.runtime.reattachSessionProjection(session_id_prefix) catch |e| {
        terminal_main.debugLog("reattachSession: runtime.reattachSessionProjection failed: {s}", .{@errorName(e)});
        return false;
    };
    if (result == null) {
        terminal_main.debugLog("reattachSession: runtime.reattachSessionProjection returned null (session not found)", .{});
        return false;
    }

    var reattach_result = result.?;
    defer reattach_result.deinit();
    terminal_main.debugLog("reattachSession: got parsed result with {d} panes", .{reattach_result.pane_uuids.len});
    const snapshot = self.runtime.attachedSnapshot() orelse return false;

    // Check timeout after JSON parsing
    {
        const elapsed = std.time.milliTimestamp() - reattach_start;
        if (elapsed > 30000) {
            terminal_main.debugLog("reattachSession: timeout after JSON parse ({d}ms > 30s), aborting", .{elapsed});
            self.notifications.showFor("Reattach timeout: JSON parsing took too long", 5000);
            return false;
        } else if (elapsed > 10000) {
            const msg = std.fmt.allocPrint(
                self.allocator,
                "Warning: reattach slow ({d}s elapsed)",
                .{@divTrunc(elapsed, 1000)},
            ) catch "Warning: reattach taking longer than expected";
            defer if (!std.mem.eql(u8, msg, "Warning: reattach taking longer than expected")) self.allocator.free(msg);
            self.notifications.showFor(msg, 3000);
            terminal_main.debugLog("reattachSession: slow progress warning after JSON parse ({d}ms)", .{elapsed});
        }
    }

    clearStateForRestore(self);
    const restored_name = normalizeRestoredSessionName(snapshot.session_name);
    const wanted_active_tab = snapshot.active_tab;

    var uuid_pane_map = std.AutoHashMap([32]u8, AdoptInfo).init(self.allocator);
    defer uuid_pane_map.deinit();

    var used_uuids = std.AutoHashMap([32]u8, void).init(self.allocator);
    defer used_uuids.deinit();

    terminal_main.debugLog("reattachSession: adopting {d} panes", .{reattach_result.pane_uuids.len});
    var failed_adoptions: usize = 0;
    const total_panes = reattach_result.pane_uuids.len;

    for (reattach_result.pane_uuids, 0..) |uuid, i| {
        terminal_main.debugLog("reattachSession: adopting pane {d}/{d} uuid={s}", .{ i + 1, total_panes, uuid[0..8] });

        // Check for duplicate UUID in the list
        if (uuid_pane_map.contains(uuid)) {
            terminal_main.debugLog("reattachSession: DUPLICATE UUID detected: {s}, skipping", .{uuid[0..8]});
            failed_adoptions += 1;
            continue;
        }

        const adopt_result = self.runtime.adoptPane(uuid) catch |e| {
            terminal_main.debugLog("reattachSession: adoptPane failed for uuid={s}: {s}", .{ uuid[0..8], @errorName(e) });
            failed_adoptions += 1;
            continue;
        };
        terminal_main.debugLogUuid(&uuid, "reattachSession: adoptPane ok pane_id={d} vt_fd={?d}", .{ adopt_result.pane_id, self.runtime.currentVtFd() });
        uuid_pane_map.put(uuid, .{ .pane_id = adopt_result.pane_id }) catch {};
    }
    terminal_main.debugLog("reattachSession: adopted {d} panes into uuid_pane_map", .{uuid_pane_map.count()});

    // Notify user if some panes failed to reattach
    if (failed_adoptions > 0) {
        const msg = std.fmt.allocPrint(
            self.allocator,
            "Warning: {d}/{d} panes failed to reattach",
            .{ failed_adoptions, total_panes },
        ) catch "Warning: Some panes failed to reattach";
        defer if (!std.mem.eql(u8, msg, "Warning: Some panes failed to reattach")) self.allocator.free(msg);
        self.notifications.showFor(msg, 5000);
        terminal_main.debugLog("reattachSession: notified user about {d} failed adoptions", .{failed_adoptions});
    }

    // Check timeout after pane adoption
    {
        const elapsed = std.time.milliTimestamp() - reattach_start;
        if (elapsed > 30000) {
            terminal_main.debugLog("reattachSession: timeout after pane adoption ({d}ms > 30s), aborting", .{elapsed});
            self.notifications.showFor("Reattach timeout: pane adoption took too long", 5000);
            return false;
        } else if (elapsed > 10000) {
            const msg = std.fmt.allocPrint(
                self.allocator,
                "Warning: reattach slow ({d}s elapsed, {d} panes adopted)",
                .{ @divTrunc(elapsed, 1000), uuid_pane_map.count() },
            ) catch "Warning: reattach taking longer than expected";
            defer if (!std.mem.eql(u8, msg, "Warning: reattach taking longer than expected")) self.allocator.free(msg);
            self.notifications.showFor(msg, 3000);
            terminal_main.debugLog("reattachSession: slow progress warning after adoption ({d}ms)", .{elapsed});
        }
    }

    for (snapshot.tabs.items) |snapshot_tab| {
        var tab = TabView.init(self.allocator, self.layout_width, self.layout_height, self.pop_config.carrier.notification);

        if (self.runtime.isConnected()) {
            tab.layout.setFrontendRuntime(self.runtime);
        }
        tab.layout.setPanePopConfig(&self.pop_config.pane.notification);

        if (snapshot_tab.root) |root| {
            tab.layout.root = restoreLayoutNode(
                self,
                &tab,
                root,
                &uuid_pane_map,
                null,
                false,
                &used_uuids,
                snapshot_tab.focused_pane_uuid,
                snapshot.focused_pane_uuid,
            );
        }

        if (tab.layout.focused_pane_uuid == null or !tab.layout.splits.contains(tab.layout.focused_pane_uuid.?)) {
            var split_it = tab.layout.splits.iterator();
            if (split_it.next()) |entry| {
                tab.layout.focused_pane_uuid = entry.key_ptr.*;
            }
        }

        if (tab.layout.root == null and tab.layout.splits.count() > 0) {
            const node = self.allocator.create(LayoutNode) catch {
                tab.deinit();
                continue;
            };
            node.* = .{ .pane = tab.layout.focused_pane_uuid.? };
            tab.layout.root = node;
        }

        self.view.tab_views.append(self.allocator, tab) catch {
            tab.deinit();
            continue;
        };
    }

    for (snapshot.floats.items) |float_state| {
        const pane = restoreFloatPane(self, float_state, &uuid_pane_map, null, false, &used_uuids, snapshot.focused_pane_uuid) orelse continue;
        self.view.float_views.append(self.allocator, pane) catch {
            pane.deinit();
            self.allocator.destroy(pane);
            continue;
        };
    }

    // Prune dead pane nodes from layout trees. Pods that died during detach
    // (e.g., from SIGPIPE) leave orphan nodes in the tree that would corrupt
    // the layout by allocating space for non-existent panes.
    for (self.view.tab_views.items) |*tab| {
        tab.layout.pruneDeadNodes();
    }

    // Remove tabs that have no live panes (all pods died).
    {
        var i: usize = 0;
        var removed_tabs: usize = 0;
        while (i < self.view.tab_views.items.len) {
            if (self.view.tab_views.items[i].layout.splits.count() == 0) {
                // Don't remove the LAST tab - keep at least one tab always.
                if (self.view.tab_views.items.len > 1) {
                    terminal_main.debugLog("reattachSession: removing empty tab at index {d}", .{i});
                    var dead_tab = self.view.tab_views.orderedRemove(i);
                    dead_tab.deinit();
                    removed_tabs += 1;
                    // Don't increment i, next tab shifted into this position
                } else {
                    terminal_main.debugLog("reattachSession: keeping last empty tab to prevent zero tabs", .{});
                    i += 1;
                }
            } else {
                i += 1;
            }
        }

        // Notify user if tabs were removed
        if (removed_tabs > 0) {
            const msg = std.fmt.allocPrint(
                self.allocator,
                "Warning: {d} empty tab(s) removed (all panes died)",
                .{removed_tabs},
            ) catch "Warning: Empty tabs were removed";
            defer if (!std.mem.eql(u8, msg, "Warning: Empty tabs were removed")) self.allocator.free(msg);
            self.notifications.showFor(msg, 4000);
            terminal_main.debugLog("reattachSession: removed {d} empty tabs", .{removed_tabs});
        }
    }

    // Safety check: ensure we have at least one tab.
    // If all tabs were empty and removed, create a new one.
    if (self.view.tab_views.items.len == 0) {
        terminal_main.debugLog("reattachSession: CRITICAL - all tabs removed, creating new tab", .{});
        self.createTab() catch {
            terminal_main.debugLog("reattachSession: FAILED to create recovery tab", .{});
            return false;
        };
        self.notifications.showFor("Warning: All tabs were empty, created new tab", 5000);
    }

    // Recalculate all layouts for current terminal size.
    for (self.view.tab_views.items) |*tab| {
        tab.layout.resize(self.layout_width, self.layout_height);
    }

    // Validate and fix parent_tab indices for floating panes
    const invalid_parent_tabs = self.normalizeFloatParentTabs(self.view.tab_views.items.len);
    // Notify user if any parent_tab links were broken
    if (invalid_parent_tabs > 0) {
        const msg = std.fmt.allocPrint(
            self.allocator,
            "Warning: {d} float(s) had invalid parent tab, reset to global",
            .{invalid_parent_tabs},
        ) catch "Warning: Some floats had invalid parent tab references";
        defer if (!std.mem.eql(u8, msg, "Warning: Some floats had invalid parent tab references")) self.allocator.free(msg);
        self.notifications.showFor(msg, 4000);
        terminal_main.debugLog("reattachSession: corrected {d} invalid parent_tab references", .{invalid_parent_tabs});
    }

    // Recalculate floating pane positions.
    self.resizeFloatingPanes();

    // Apply restored active indices now that all state is present.
    if (self.view.tab_views.items.len > 0) {
        self.setActiveTabIndex(@min(wanted_active_tab, self.view.tab_views.items.len - 1));
    } else {
        self.setActiveTabIndex(0);
    }
    self.setActiveFloatingIndex(null);
    if (snapshot.active_float_uuid) |active_float_uuid| {
        for (self.view.float_views.items, 0..) |pane, idx| {
            if (std.mem.eql(u8, &pane.uuid, &active_float_uuid)) {
                self.setActiveFloatingIndex(idx);
                break;
            }
        }
    }
    if (self.activeFloatingIndex()) |idx| {
        self.rememberFloatingFocus(self.view.float_views.items[idx]);
    }

    if (!self.runtime.setSessionIdentity(snapshot.uuid, restored_name)) return false;

    self.renderer.invalidate();
    self.force_full_render = true;

    terminal_main.debugLog("reattachSession: tabs restored={d}, floats restored={d}", .{ self.view.tab_views.items.len, self.view.float_views.items.len });

    // Check timeout after layout restoration
    {
        const elapsed = std.time.milliTimestamp() - reattach_start;
        if (elapsed > 30000) {
            terminal_main.debugLog("reattachSession: timeout after layout restore ({d}ms > 30s), aborting", .{elapsed});
            self.notifications.showFor("Reattach timeout: layout restoration took too long", 5000);
            return false;
        } else if (elapsed > 10000) {
            const msg = std.fmt.allocPrint(
                self.allocator,
                "Warning: reattach slow ({d}s total, {d} tabs restored)",
                .{ @divTrunc(elapsed, 1000), self.view.tab_views.items.len },
            ) catch "Warning: reattach taking longer than expected";
            defer if (!std.mem.eql(u8, msg, "Warning: reattach taking longer than expected")) self.allocator.free(msg);
            self.notifications.showFor(msg, 3000);
            terminal_main.debugLog("reattachSession: slow progress warning after layout restore ({d}ms)", .{elapsed});
        }
    }

    if (self.view.tab_views.items.len == 0) {
        terminal_main.debugLog("reattachSession: no tabs restored, returning false", .{});
        return false;
    }

    // Re-register with restored UUID/name before requesting backlog replay.
    // This releases the attach session lock and stabilizes client identity first.
    const session_uuid = self.runtime.sessionUuid();
    terminal_main.debugLog("reattachSession: finalizing attach uuid={s} name={s}", .{ session_uuid[0..8], self.runtime.sessionName() });
    if (self.runtime.completeReattach()) |change_opt| {
        if (change_opt) |change| {
            var owned_change = change;
            defer owned_change.deinit(self.allocator);
            terminal_main.debugLog("reattachSession: resolved session name from '{s}' to '{s}'", .{ owned_change.previous_name, owned_change.resolved_name });
        }
        terminal_main.debugLog("reattachSession: requestBacklogReplay done", .{});
    } else |e| {
        core.logging.logError("terminal", "completeReattach failed in restoreLayout", e);
        terminal_main.debugLog("reattachSession: completeReattach FAILED: {s}", .{@errorName(e)});
    }

    // Sync-phase reads can consume async pane_exited messages before the IPC
    // loop starts. Apply those exits now so dead panes/floats are not kept
    // around in a frozen state.
    applyDeferredPaneExits(self);

    // Final timeout check after backlog replay
    {
        const elapsed = std.time.milliTimestamp() - reattach_start;
        terminal_main.debugLog("reattachSession: total elapsed time: {d}ms", .{elapsed});
        if (elapsed > 30000) {
            terminal_main.debugLog("reattachSession: timeout after backlog replay ({d}ms > 30s), aborting", .{elapsed});
            self.notifications.showFor("Reattach timeout: session restored but backlog replay incomplete", 5000);
            // Don't return false here - the session is already restored, just warn user
        }
    }

    terminal_main.debugLog("reattachSession: returning true, tabs={d} floats={d}", .{ self.view.tab_views.items.len, self.view.float_views.items.len });
    return true;
}

pub fn applySessionSnapshot(self: anytype) bool {
    const snapshot = self.runtime.attachedSnapshot() orelse return false;

    if (applySnapshotIncrementally(self, snapshot)) {
        terminal_main.debugLog("applySessionSnapshot: incrementally applied tabs={d} floats={d}", .{ self.view.tab_views.items.len, self.view.float_views.items.len });
        return true;
    }
    if (snapshot.floats.items.len > 0) {
        terminal_main.debugLog("applySessionSnapshot: falling back to full rebuild tabs={d} floats={d} active_float={}", .{
            snapshot.tabs.items.len,
            snapshot.floats.items.len,
            snapshot.active_float_uuid != null,
        });
    }

    var existing_views = ExistingPaneViews.init(self.allocator);
    defer {
        destroyUnusedPaneViews(self, &existing_views);
        existing_views.deinit();
    }
    captureExistingPaneViews(self, &existing_views);
    clearStatePreservingPanes(self);

    const wanted_active_tab = snapshot.active_tab;

    var uuid_pane_map = std.AutoHashMap([32]u8, AdoptInfo).init(self.allocator);
    defer uuid_pane_map.deinit();

    var used_uuids = std.AutoHashMap([32]u8, void).init(self.allocator);
    defer used_uuids.deinit();

    for (snapshot.tabs.items) |snapshot_tab| {
        var tab = TabView.init(self.allocator, self.layout_width, self.layout_height, self.pop_config.carrier.notification);

        if (self.runtime.isConnected()) {
            tab.layout.setFrontendRuntime(self.runtime);
        }
        tab.layout.setPanePopConfig(&self.pop_config.pane.notification);

        if (snapshot_tab.root) |root| {
            tab.layout.root = restoreLayoutNode(
                self,
                &tab,
                root,
                &uuid_pane_map,
                &existing_views,
                true,
                &used_uuids,
                snapshot_tab.focused_pane_uuid,
                snapshot.focused_pane_uuid,
            );
        }

        if (tab.layout.focused_pane_uuid == null or !tab.layout.splits.contains(tab.layout.focused_pane_uuid.?)) {
            var split_it = tab.layout.splits.iterator();
            if (split_it.next()) |entry| {
                tab.layout.focused_pane_uuid = entry.key_ptr.*;
            }
        }

        if (tab.layout.root == null and tab.layout.splits.count() > 0) {
            const node = self.allocator.create(LayoutNode) catch {
                tab.deinit();
                continue;
            };
            node.* = .{ .pane = tab.layout.focused_pane_uuid.? };
            tab.layout.root = node;
        }

        self.view.tab_views.append(self.allocator, tab) catch {
            tab.deinit();
            continue;
        };
    }

    for (snapshot.floats.items) |float_state| {
        const pane = restoreFloatPane(self, float_state, &uuid_pane_map, &existing_views, true, &used_uuids, snapshot.focused_pane_uuid) orelse continue;
        self.view.float_views.append(self.allocator, pane) catch {
            pane.deinit();
            self.allocator.destroy(pane);
            continue;
        };
    }

    for (self.view.tab_views.items) |*tab| {
        tab.layout.pruneDeadNodes();
        tab.layout.resize(self.layout_width, self.layout_height);
    }

    _ = self.normalizeFloatParentTabs(self.view.tab_views.items.len);
    self.resizeFloatingPanes();

    if (self.view.tab_views.items.len > 0) {
        self.setActiveTabIndex(@min(wanted_active_tab, self.view.tab_views.items.len - 1));
    } else {
        self.setActiveTabIndex(0);
    }
    self.setActiveFloatingIndex(null);
    if (snapshot.active_float_uuid) |active_float_uuid| {
        for (self.view.float_views.items, 0..) |pane, idx| {
            if (std.mem.eql(u8, &pane.uuid, &active_float_uuid)) {
                self.setActiveFloatingIndex(idx);
                break;
            }
        }
    }
    if (self.activeFloatingIndex()) |idx| {
        self.rememberFloatingFocus(self.view.float_views.items[idx]);
    }

    self.renderer.invalidate();
    self.force_full_render = true;
    self.needs_render = true;
    terminal_main.debugLog("applySessionSnapshot: tabs={d} floats={d}", .{ self.view.tab_views.items.len, self.view.float_views.items.len });
    return true;
}

fn intFieldCast(comptime T: type, obj: std.json.ObjectMap, key: []const u8) ?T {
    const value = obj.get(key) orelse return null;
    if (value != .integer) return null;
    if (value.integer < 0) return null;
    return std.math.cast(T, value.integer);
}

/// Attach to orphaned pane by UUID prefix (for --attach CLI).
pub fn attachOrphanedPane(self: anytype, uuid_prefix: []const u8) bool {
    if (!self.runtime.isConnected()) return false;

    // Get list of orphaned panes and find matching UUID.
    var tabs: [32]OrphanedPaneInfo = undefined;
    const count = self.runtime.listOrphanedPanes(&tabs) catch return false;

    for (tabs[0..count]) |p| {
        if (std.mem.startsWith(u8, &p.uuid, uuid_prefix)) {
            // Found matching pane, adopt it.
            const result = self.runtime.adoptPane(p.uuid) catch return false;

            // Create a new tab with this pane.
            const tab_uuid = core.ipc.generateUuid();
            var tab = TabView.init(self.allocator, self.layout_width, self.layout_height, self.pop_config.carrier.notification);
            var tab_needs_cleanup = true;
            defer if (tab_needs_cleanup) tab.deinit();

            if (self.runtime.isConnected()) {
                tab.layout.setFrontendRuntime(self.runtime);
            }
            tab.layout.setPanePopConfig(&self.pop_config.pane.notification);

            const vt_fd = self.runtime.getVtFd() orelse return false;

            const pane = self.allocator.create(Pane) catch return false;
            var pane_needs_cleanup = true;
            defer if (pane_needs_cleanup) self.allocator.destroy(pane);

            pane.initWithPod(self.allocator, 0, 0, 0, self.layout_width, self.layout_height, result.pane_id, vt_fd, result.uuid) catch {
                return false;
            };

            if (self.runtime.getPaneInfoSnapshot(result.uuid)) |snap| {
                defer if (snap.cwd) |cwd| self.allocator.free(cwd);
                defer if (snap.fg_name) |s| self.allocator.free(s);
                if (snap.name) |name| {
                    self.setPaneNameOwned(result.uuid, name);
                }
                if (snap.cwd) |cwd| {
                    self.setPaneShell(result.uuid, null, cwd, null, null, null);
                }
                self.setPaneProc(result.uuid, snap.fg_name, snap.fg_pid);
            } else {
                self.runtime.requestPaneProcess(result.uuid);
                self.runtime.requestPaneCwd(result.uuid);
            }

            pane.focused = true;
            pane.configureNotificationsFromPop(&self.pop_config.pane.notification);

            // Add pane to layout manually.
            tab.layout.splits.put(pane.uuid, pane) catch {
                pane.deinit();
                return false;
            };
            // Pane is now owned by tab, no longer needs separate cleanup
            pane_needs_cleanup = false;

            const node = self.allocator.create(LayoutNode) catch return false;
            node.* = .{ .pane = pane.uuid };
            tab.layout.root = node;
            tab.layout.focused_pane_uuid = pane.uuid;
            tab.layout.next_pane_view_id = 1;

            self.view.tab_views.append(self.allocator, tab) catch return false;
            // Tab is now owned by tabs array, no longer needs cleanup
            tab_needs_cleanup = false;
            if (!self.runtime.appendTabMeta(tab_uuid, "attached")) {
                var failed_tab = self.view.tab_views.pop().?;
                failed_tab.deinit();
                return false;
            }
            if (!self.runtime.appendTabFocusMemory()) {
                self.runtime.removeTabMeta(self.view.tab_views.items.len - 1);
                var failed_tab = self.view.tab_views.pop().?;
                failed_tab.deinit();
                return false;
            }
            self.setActiveTabIndex(self.view.tab_views.items.len - 1);
            self.syncSessionTabAdded(tab_uuid, self.runtime.tabName(self.activeTabIndex()) orelse "tab", pane.uuid);
            self.renderer.invalidate();
            self.force_full_render = true;
            return true;
        }
    }
    return false;
}
