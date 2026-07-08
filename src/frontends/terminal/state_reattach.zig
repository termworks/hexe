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

fn syncRestoredPaneBackendSizes(self: anytype, comptime context: []const u8) void {
    var split_count: usize = 0;
    for (self.view.tab_views.items) |*tab| {
        var it = tab.layout.splits.valueIterator();
        while (it.next()) |pane_ptr| {
            const pane = pane_ptr.*;
            if (!pane.isAlive()) continue;
            pane.syncBackendSize();
            split_count += 1;
        }
    }

    var float_count: usize = 0;
    for (self.view.float_views.items) |pane| {
        if (!pane.isAlive()) continue;
        pane.syncBackendSize();
        float_count += 1;
    }

    terminal_main.debugLog(
        "{s}: synced backend sizes for restored panes splits={d} floats={d} layout={d}x{d}",
        .{ context, split_count, float_count, self.layout_width, self.layout_height },
    );
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

    // Do not write through runtime setters here. Reattach has already loaded
    // the authoritative snapshot into the projection, and those setters mutate
    // active tab/float/focus fields on that snapshot.
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

fn captureExistingPaneViews(self: anytype, out: *ExistingPaneViews) bool {
    for (self.view.tab_views.items) |*tab| {
        var it = tab.layout.splits.valueIterator();
        while (it.next()) |pane_ptr| {
            out.put(pane_ptr.*.uuid, pane_ptr.*) catch |err| {
                terminal_main.debugLog("captureExistingPaneViews: failed to record split pane: {s}", .{@errorName(err)});
                return false;
            };
        }
    }
    for (self.view.float_views.items) |pane| {
        out.put(pane.uuid, pane) catch |err| {
            terminal_main.debugLog("captureExistingPaneViews: failed to record float pane: {s}", .{@errorName(err)});
            return false;
        };
    }
    return true;
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

fn hydratePaneMetadata(self: anytype, _: *Pane, uuid: [32]u8) ?[]u8 {
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
        return snap.sticky_pwd;
    } else {
        self.runtime.requestPaneProcess(uuid);
        self.runtime.requestPaneCwd(uuid);
        return null;
    }
}

fn orphanRestoredTabPanes(self: anytype, tab: *TabView, comptime context: []const u8) void {
    var it = tab.layout.splits.valueIterator();
    while (it.next()) |pane_ptr| {
        const uuid = pane_ptr.*.uuid;
        self.runtime.orphanPane(uuid) catch |err| {
            terminal_main.debugLogUuid(&uuid, context ++ ": orphanPane rollback failed: {s}", .{@errorName(err)});
        };
    }
}

fn orphanRestoredPane(self: anytype, uuid: [32]u8, comptime context: []const u8) void {
    self.runtime.orphanPane(uuid) catch |err| {
        terminal_main.debugLogUuid(&uuid, context ++ ": orphanPane rollback failed: {s}", .{@errorName(err)});
    };
}

fn orphanAdoptedPaneMap(self: anytype, uuid_pane_map: *std.AutoHashMap([32]u8, AdoptInfo), comptime context: []const u8) void {
    var it = uuid_pane_map.keyIterator();
    while (it.next()) |uuid_ptr| {
        orphanRestoredPane(self, uuid_ptr.*, context);
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
            defer if (snap.sticky_pwd) |s| self.allocator.free(s);
            defer if (snap.fg_name) |s| self.allocator.free(s);
            if (snap.pane_id) |pane_id| {
                const info = AdoptInfo{ .pane_id = pane_id };
                uuid_pane_map.put(uuid, info) catch |err| {
                    terminal_main.debugLog("ensureAdoptInfo: failed to cache snapshot pane uuid={s}: {s}", .{ uuid[0..8], @errorName(err) });
                    return null;
                };
                return info;
            }
        }
    }
    if (self.runtime.adoptPane(uuid)) |adopt_res| {
        const info = AdoptInfo{ .pane_id = adopt_res.pane_id };
        uuid_pane_map.put(uuid, info) catch |err| {
            terminal_main.debugLog("ensureAdoptInfo: failed to cache adopted pane uuid={s}: {s}", .{ uuid[0..8], @errorName(err) });
            self.runtime.orphanPane(adopt_res.uuid) catch |orphan_err| {
                terminal_main.debugLogUuid(&adopt_res.uuid, "ensureAdoptInfo: rollback orphanPane failed after cache error: {s}", .{@errorName(orphan_err)});
            };
            return null;
        };
        return info;
    } else |err| {
        terminal_main.debugLogUuid(&uuid, "ensureAdoptInfo: adoptPane failed: {s}", .{@errorName(err)});
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

    const info = ensureAdoptInfo(self, pane_uuid, uuid_pane_map, existing_views, attached_snapshot) orelse {
        terminal_main.debugLogUuid(&pane_uuid, "ensureSplitPaneView: missing adopt info", .{});
        return false;
    };
    const vt_fd = self.runtime.getVtFd() orelse {
        terminal_main.debugLogUuid(&pane_uuid, "ensureSplitPaneView: missing VT fd", .{});
        return false;
    };

    const view_id = tab.layout.next_pane_view_id;
    tab.layout.next_pane_view_id +%= 1;

    const pane = blk: {
        if (existing_views) |views| {
            if (views.fetchRemove(pane_uuid)) |entry| {
                const pane = entry.value;
                if (pane.getPaneId() != info.pane_id or !std.mem.eql(u8, &pane.uuid, &pane_uuid)) {
                    pane.replaceWithPod(info.pane_id, vt_fd, pane_uuid) catch |err| {
                        terminal_main.debugLogUuid(&pane_uuid, "ensureSplitPaneView: replaceWithPod failed: {s}", .{@errorName(err)});
                        pane.deinit();
                        self.allocator.destroy(pane);
                        return false;
                    };
                }
                recyclePaneForSplit(self, tab, pane, view_id, pane_uuid, actual_focus_uuid);
                break :blk pane;
            }
        }

        const pane = self.allocator.create(Pane) catch |err| {
            core.logging.logError("terminal", "ensureSplitPaneView failed to allocate pane", err);
            return false;
        };

        pane.initWithPod(self.allocator, view_id, 0, 0, self.layout_width, self.layout_height, info.pane_id, vt_fd, pane_uuid) catch |err| {
            terminal_main.debugLogUuid(&pane_uuid, "ensureSplitPaneView: initWithPod failed: {s}", .{@errorName(err)});
            self.allocator.destroy(pane);
            return false;
        };
        recyclePaneForSplit(self, tab, pane, view_id, pane_uuid, actual_focus_uuid);
        pane.configureNotificationsFromPop(&self.pop_config.pane.notification);
        break :blk pane;
    };

    if (hydratePaneMetadata(self, pane, pane_uuid)) |sticky_pwd| {
        self.allocator.free(sticky_pwd);
    }

    tab.layout.splits.put(pane_uuid, pane) catch {
        terminal_main.debugLogUuid(&pane_uuid, "ensureSplitPaneView: failed to insert split pane", .{});
        pane.deinit();
        self.allocator.destroy(pane);
        return false;
    };
    used_uuids.put(pane_uuid, {}) catch |err| {
        terminal_main.debugLogUuid(&pane_uuid, "ensureSplitPaneView: failed to mark uuid used: {s}", .{@errorName(err)});
        if (tab.layout.splits.fetchRemove(pane_uuid)) |entry| {
            entry.value.deinit();
            self.allocator.destroy(entry.value);
        }
        return false;
    };

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
            const restored = self.allocator.create(LayoutNode) catch |err| {
                core.logging.logError("terminal", "restoreLayoutNode failed to allocate pane node", err);
                return null;
            };
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

    // During an attached-snapshot rebuild, a sticky/per-CWD float entry with
    // no local view and no adoption record is parked: another client owns the
    // pod right now. Skip it without touching SES — the info-snapshot path in
    // ensureAdoptInfo would otherwise build a ghost view around a pane whose
    // VT is routed to a different frontend. Reconciliation (adoptStickyPanes)
    // or an explicit toggle claims it back when it is free.
    if (attached_snapshot and (float_state.sticky or float_state.is_pwd)) {
        const locally_known = uuid_pane_map.contains(float_state.pane_uuid) or
            (existing_views != null and existing_views.?.contains(float_state.pane_uuid));
        if (!locally_known) {
            terminal_main.debugLogUuid(&float_state.pane_uuid, "restoreFloatPane: skipping parked sticky float", .{});
            return null;
        }
    }

    const info = ensureAdoptInfo(self, float_state.pane_uuid, uuid_pane_map, existing_views, attached_snapshot) orelse {
        terminal_main.debugLogUuid(&float_state.pane_uuid, "restoreFloatPane: missing adopt info", .{});
        return null;
    };
    const vt_fd = self.runtime.getVtFd() orelse {
        terminal_main.debugLogUuid(&float_state.pane_uuid, "restoreFloatPane: missing VT fd", .{});
        return null;
    };
    const preserved_title = blk: {
        if (existing_views) |views| {
            if (views.get(float_state.pane_uuid)) |existing_pane| {
                if (self.paneFloatTitle(existing_pane)) |title| {
                    break :blk self.allocator.dupe(u8, title) catch |err| {
                        core.logging.logError("terminal", "restoreFloatPane: failed to preserve float title", err);
                        break :blk null;
                    };
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
                    pane.replaceWithPod(info.pane_id, vt_fd, float_state.pane_uuid) catch |err| {
                        terminal_main.debugLogUuid(&float_state.pane_uuid, "restoreFloatPane: replaceWithPod failed: {s}", .{@errorName(err)});
                        pane.deinit();
                        self.allocator.destroy(pane);
                        return null;
                    };
                }
                break :blk pane;
            }
        }

        const pane = self.allocator.create(Pane) catch |err| {
            core.logging.logError("terminal", "restoreFloatPane failed to allocate pane", err);
            return null;
        };

        const local_id: u16 = @intCast(100 + self.view.float_views.items.len);
        pane.initWithPod(self.allocator, local_id, 0, 0, self.layout_width, self.layout_height, info.pane_id, vt_fd, float_state.pane_uuid) catch |err| {
            terminal_main.debugLogUuid(&float_state.pane_uuid, "restoreFloatPane: initWithPod failed: {s}", .{@errorName(err)});
            self.allocator.destroy(pane);
            return null;
        };
        pane.configureNotificationsFromPop(&self.pop_config.pane.notification);
        break :blk pane;
    };
    pane.id = @intCast(100 + self.view.float_views.items.len);
    pane.uuid = float_state.pane_uuid;
    recyclePaneForFloat(self, pane, float_state, actual_focus_uuid);
    const restored_sticky_pwd = hydratePaneMetadata(self, pane, float_state.pane_uuid);
    defer if (restored_sticky_pwd) |pwd| self.allocator.free(pwd);
    if (float_state.is_pwd) {
        if (restored_sticky_pwd) |pwd| {
            _ = self.setPanePwdDir(float_state.pane_uuid, pwd);
        }
        // No live-cwd fallback: a per-CWD float's identity is the SES
        // sticky_pwd. If SES has not reported it during this hydration pass,
        // leave pwd_dir empty so it is re-resolved authoritatively on the next
        // toggle/adoption instead of being silently pinned to the float
        // shell's (possibly cd'd) working directory.
    }

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

    used_uuids.put(float_state.pane_uuid, {}) catch |err| {
        terminal_main.debugLogUuid(&float_state.pane_uuid, "restoreFloatPane: failed to mark uuid used: {s}", .{@errorName(err)});
        pane.deinit();
        self.allocator.destroy(pane);
        return null;
    };
    return pane;
}

const countSessionLayoutPanes = @import("reattach_reconcile.zig").countSessionLayoutPanes;

// Pure snapshot→view structural comparison lives in `reattach_reconcile` so it
// can be characterized in isolation (PLAN 1.8).
const layoutMatchesSnapshot = @import("reattach_reconcile.zig").layoutMatchesSnapshot;

fn hasLocalFloatView(self: anytype, pane_uuid: [32]u8) bool {
    for (self.view.float_views.items) |pane| {
        if (std.mem.eql(u8, &pane.uuid, &pane_uuid)) return true;
    }
    return false;
}

fn canApplySnapshotIncrementally(self: anytype, snapshot: *const SessionSnapshot) bool {
    if (self.view.tab_views.items.len != snapshot.tabs.items.len) return false;

    // Parked sticky/per-CWD floats stay in the snapshot while another client
    // owns their pod; they have no local view and do not block the
    // incremental path. Any other float mismatch forces a rebuild.
    var matched_floats: usize = 0;
    var live_floats: usize = 0;
    for (snapshot.floats.items) |float_state| {
        if (hasLocalFloatView(self, float_state.pane_uuid)) {
            matched_floats += 1;
            live_floats += 1;
        } else if (!float_state.sticky and !float_state.is_pwd) {
            return false;
        }
    }
    if (matched_floats != self.view.float_views.items.len) return false;

    // The incremental path is safe only when float visibility/focus stays in a
    // simple "one active visible float" shape. Hidden/background/per-tab floats
    // have been the crashy case during toggle-hide, so force the conservative
    // rebuild path there. Parked floats are exempt: they have no view to
    // update, so their hidden state cannot desync anything locally.
    if (live_floats > 0) {
        if (snapshot.active_float_uuid == null) return false;
        for (snapshot.floats.items) |float_state| {
            if (!hasLocalFloatView(self, float_state.pane_uuid)) continue;
            if (float_state.parent_tab != null) {
                if (!float_state.visible) return false;
            } else {
                if (float_state.tab_visible != std.math.maxInt(u64)) return false;
            }
        }
    }

    for (snapshot.tabs.items, 0..) |snapshot_tab, idx| {
        const live_tab_uuid = self.runtime.tabUuid(idx) orelse {
            core.logging.warn("terminal", "reattach incremental snapshot check failed: live tab {d} has no session UUID", .{idx});
            return false;
        };
        if (!std.mem.eql(u8, &snapshot_tab.uuid, &live_tab_uuid)) return false;
        if (!std.mem.eql(u8, snapshot_tab.name, self.runtime.tabName(idx) orelse "tab")) return false;

        const live_tab = &self.view.tab_views.items[idx];
        if (live_tab.layout.splits.count() != countSessionLayoutPanes(snapshot_tab.root)) return false;
        if (!layoutMatchesSnapshot(live_tab.layout.root, snapshot_tab.root)) return false;
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

    for (snapshot.floats.items) |float_state| {
        for (self.view.float_views.items) |pane| {
            if (std.mem.eql(u8, &pane.uuid, &float_state.pane_uuid)) {
                updateFloatPresentation(self, pane, float_state, snapshot.focused_pane_uuid);
                break;
            }
        }
    }

    for (self.view.tab_views.items) |*tab| {
        tab.layout.resize(self.layout_width, self.layout_height);
    }
    self.resizeFloatingPanes();
    syncRestoredPaneBackendSizes(self, "applySessionSnapshot");

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

    // Reattach rebuilds panes (freeing their screens); tear down any active
    // scrollback search first so it can't hold a dangling screen (PLAN 3.3).
    if (self.isSearchActive()) self.exitSearchMode();

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
    const snapshot = self.runtime.attachedSnapshot() orelse {
        core.logging.warn("terminal", "reattachSession failed: daemon returned no attached snapshot", .{});
        return false;
    };

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

    const restored_name = normalizeRestoredSessionName(snapshot.session_name);
    const wanted_active_tab = snapshot.active_tab;
    if (!self.runtime.setSessionIdentity(snapshot.uuid, restored_name)) {
        terminal_main.debugLog("reattachSession: failed to set restored session identity before adoption", .{});
        return false;
    }

    clearStateForRestore(self);

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
        uuid_pane_map.put(uuid, .{ .pane_id = adopt_result.pane_id }) catch |err| {
            terminal_main.debugLog("reattachSession: failed to cache adopted pane uuid={s}: {s}", .{ uuid[0..8], @errorName(err) });
            self.runtime.orphanPane(adopt_result.uuid) catch |orphan_err| {
                terminal_main.debugLogUuid(&adopt_result.uuid, "reattachSession: rollback orphanPane failed after cache error: {s}", .{@errorName(orphan_err)});
            };
            failed_adoptions += 1;
            continue;
        };
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
            orphanAdoptedPaneMap(self, &uuid_pane_map, "reattachSession adoption timeout");
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
            const node = self.allocator.create(LayoutNode) catch |err| {
                core.logging.logError("terminal", "reattachSession failed to allocate fallback tab root", err);
                orphanRestoredTabPanes(self, &tab, "reattachSession fallback root allocation");
                tab.deinit();
                continue;
            };
            node.* = .{ .pane = tab.layout.focused_pane_uuid.? };
            tab.layout.root = node;
        }

        self.view.tab_views.append(self.allocator, tab) catch |err| {
            core.logging.logError("terminal", "reattachSession failed to append restored tab", err);
            orphanRestoredTabPanes(self, &tab, "reattachSession restored tab append");
            tab.deinit();
            continue;
        };
    }

    for (snapshot.floats.items) |float_state| {
        const pane = restoreFloatPane(self, float_state, &uuid_pane_map, null, false, &used_uuids, snapshot.focused_pane_uuid) orelse continue;
        self.view.float_views.append(self.allocator, pane) catch |err| {
            core.logging.logError("terminal", "reattachSession failed to append restored float", err);
            orphanRestoredPane(self, pane.uuid, "reattachSession restored float append");
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
            orphanAdoptedPaneMap(self, &uuid_pane_map, "reattachSession recovery tab creation");
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
    syncRestoredPaneBackendSizes(self, "reattachSession");

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

    self.renderer.invalidate();
    self.force_full_render = true;

    terminal_main.debugLog("reattachSession: tabs restored={d}, floats restored={d}", .{ self.view.tab_views.items.len, self.view.float_views.items.len });

    // Check timeout after layout restoration
    {
        const elapsed = std.time.milliTimestamp() - reattach_start;
        if (elapsed > 30000) {
            terminal_main.debugLog("reattachSession: timeout after layout restore ({d}ms > 30s), continuing to finalize restored session", .{elapsed});
            self.notifications.showFor("Reattach slow: finalizing restored session", 5000);
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
        orphanAdoptedPaneMap(self, &uuid_pane_map, "reattachSession no restored tabs");
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

    // Do not run broad sticky reconciliation during explicit reattach. Attach
    // must restore exactly the detached session snapshot: every remembered
    // sticky/per-CWD float is restored above by UUID, while unrelated free
    // sticky panes in the same CWD must not be pulled into this session.

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
    const snapshot = self.runtime.attachedSnapshot() orelse {
        core.logging.warn("terminal", "applySessionSnapshot skipped: no attached snapshot", .{});
        return false;
    };

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
    if (!captureExistingPaneViews(self, &existing_views)) {
        terminal_main.debugLog("applySessionSnapshot: failed to capture existing pane views", .{});
        return false;
    }
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
            const node = self.allocator.create(LayoutNode) catch |err| {
                core.logging.logError("terminal", "applySessionSnapshot failed to allocate fallback tab root", err);
                tab.deinit();
                continue;
            };
            node.* = .{ .pane = tab.layout.focused_pane_uuid.? };
            tab.layout.root = node;
        }

        self.view.tab_views.append(self.allocator, tab) catch |err| {
            core.logging.logError("terminal", "applySessionSnapshot failed to append restored tab", err);
            tab.deinit();
            continue;
        };
    }

    for (snapshot.floats.items) |float_state| {
        const pane = restoreFloatPane(self, float_state, &uuid_pane_map, &existing_views, true, &used_uuids, snapshot.focused_pane_uuid) orelse continue;
        self.view.float_views.append(self.allocator, pane) catch |err| {
            core.logging.logError("terminal", "applySessionSnapshot failed to append restored float", err);
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
    syncRestoredPaneBackendSizes(self, "applySessionSnapshot");

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
    const count = self.runtime.listOrphanedPanes(&tabs) catch |err| {
        core.logging.logError("terminal", "attachOrphanedPane failed to list orphaned panes", err);
        return false;
    };

    for (tabs[0..count]) |p| {
        if (std.mem.startsWith(u8, &p.uuid, uuid_prefix)) {
            const vt_fd = self.runtime.getVtFd() orelse {
                terminal_main.debugLogUuid(&p.uuid, "attachOrphanedPane: missing VT fd", .{});
                return false;
            };

            // Create a new tab with this pane.
            const tab_uuid = core.ipc.generateUuid();
            var tab = TabView.init(self.allocator, self.layout_width, self.layout_height, self.pop_config.carrier.notification);
            var tab_needs_cleanup = true;
            defer if (tab_needs_cleanup) tab.deinit();

            if (self.runtime.isConnected()) {
                tab.layout.setFrontendRuntime(self.runtime);
            }
            tab.layout.setPanePopConfig(&self.pop_config.pane.notification);

            const pane = self.allocator.create(Pane) catch |err| {
                core.logging.logError("terminal", "attachOrphanedPane failed to allocate pane", err);
                return false;
            };
            var pane_needs_cleanup = true;
            defer if (pane_needs_cleanup) self.allocator.destroy(pane);

            const node = self.allocator.create(LayoutNode) catch |err| {
                core.logging.logError("terminal", "attachOrphanedPane failed to allocate layout node", err);
                return false;
            };
            var node_needs_cleanup = true;
            defer if (node_needs_cleanup) self.allocator.destroy(node);

            // Found matching pane, adopt it only after local prerequisites are ready.
            const result = self.runtime.adoptPane(p.uuid) catch |err| {
                terminal_main.debugLogUuid(&p.uuid, "attachOrphanedPane adoptPane failed: {s}", .{@errorName(err)});
                return false;
            };

            pane.initWithPod(self.allocator, 0, 0, 0, self.layout_width, self.layout_height, result.pane_id, vt_fd, result.uuid) catch |err| {
                terminal_main.debugLogUuid(&result.uuid, "attachOrphanedPane initWithPod failed: {s}", .{@errorName(err)});
                self.runtime.orphanPane(result.uuid) catch |e| {
                    terminal_main.debugLogUuid(&result.uuid, "attachOrphanedPaneAsTab rollback orphanPane failed: {s}", .{@errorName(e)});
                };
                return false;
            };

            if (self.runtime.getPaneInfoSnapshot(result.uuid)) |snap| {
                defer if (snap.cwd) |cwd| self.allocator.free(cwd);
                defer if (snap.sticky_pwd) |pwd| self.allocator.free(pwd);
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
            tab.layout.splits.put(pane.uuid, pane) catch |err| {
                terminal_main.debugLogUuid(&pane.uuid, "attachOrphanedPane failed to insert split pane: {s}", .{@errorName(err)});
                self.runtime.orphanPane(result.uuid) catch |e| {
                    terminal_main.debugLogUuid(&result.uuid, "attachOrphanedPaneAsTab rollback orphanPane failed: {s}", .{@errorName(e)});
                };
                pane.deinit();
                return false;
            };
            // Pane is now owned by tab, no longer needs separate cleanup
            pane_needs_cleanup = false;

            node.* = .{ .pane = pane.uuid };
            node_needs_cleanup = false;
            tab.layout.root = node;
            tab.layout.focused_pane_uuid = pane.uuid;
            tab.layout.next_pane_view_id = 1;

            self.view.tab_views.append(self.allocator, tab) catch |err| {
                core.logging.logError("terminal", "attachOrphanedPane failed to append tab", err);
                self.runtime.orphanPane(result.uuid) catch |e| {
                    terminal_main.debugLogUuid(&result.uuid, "attachOrphanedPaneAsTab rollback orphanPane failed: {s}", .{@errorName(e)});
                };
                return false;
            };
            // Tab is now owned by tabs array, no longer needs cleanup
            tab_needs_cleanup = false;
            if (!self.runtime.appendTabMeta(tab_uuid, "attached")) {
                self.runtime.orphanPane(result.uuid) catch |e| {
                    terminal_main.debugLogUuid(&result.uuid, "attachOrphanedPaneAsTab rollback orphanPane failed: {s}", .{@errorName(e)});
                };
                var failed_tab = self.view.tab_views.pop().?;
                failed_tab.deinit();
                return false;
            }
            if (!self.runtime.appendTabFocusMemory()) {
                self.runtime.orphanPane(result.uuid) catch |e| {
                    terminal_main.debugLogUuid(&result.uuid, "attachOrphanedPaneAsTab rollback orphanPane failed: {s}", .{@errorName(e)});
                };
                self.runtime.removeTabMeta(self.view.tab_views.items.len - 1);
                var failed_tab = self.view.tab_views.pop().?;
                failed_tab.deinit();
                return false;
            }
            self.setActiveTabIndex(self.view.tab_views.items.len - 1);
            if (!self.syncSessionTabAddedChecked(tab_uuid, self.runtime.tabName(self.activeTabIndex()) orelse "tab", pane.uuid)) {
                self.runtime.orphanPane(result.uuid) catch |e| {
                    terminal_main.debugLogUuid(&result.uuid, "attachOrphanedPaneAsTab rollback orphanPane failed: {s}", .{@errorName(e)});
                };
                self.runtime.removeTabFocusMemory(self.view.tab_views.items.len - 1);
                self.runtime.removeTabMeta(self.view.tab_views.items.len - 1);
                var failed_tab = self.view.tab_views.pop().?;
                failed_tab.deinit();
                return false;
            }
            self.renderer.invalidate();
            self.force_full_render = true;
            return true;
        }
    }
    return false;
}
