const std = @import("std");
const core = @import("core");
const terminal_main = @import("main.zig");

const state_types = @import("state_types.zig");
const TabView = state_types.TabView;

const layout_mod = @import("layout.zig");
const Layout = layout_mod.Layout;
const LayoutNode = layout_mod.LayoutNode;

const Pane = @import("pane.zig").Pane;
const OrphanedPaneInfo = core.FrontendOrphanedPaneInfo;
const state_reattach = @import("state_reattach.zig");
const tab_switch = @import("tab_switch.zig");
const lua_events = @import("lua_events.zig");

fn killTabPanes(self: anytype, tab: *TabView) void {
    var it = tab.layout.splits.valueIterator();
    while (it.next()) |pane_ptr| {
        self.runtime.killPane(pane_ptr.*.uuid) catch |e| {
            terminal_main.debugLogUuid(&pane_ptr.*.uuid, "killTabPanes: killPane failed during tab rollback: {s}", .{@errorName(e)});
        };
    }
}

fn attachedSnapshotOwnsTab(self: anytype, tab_uuid: [32]u8) bool {
    const snapshot = self.runtime.attachedSnapshot() orelse return true;
    for (snapshot.tabs.items) |*tab| {
        if (std.mem.eql(u8, &tab.uuid, &tab_uuid)) return true;
    }
    return false;
}

/// Get the current tab's layout.
pub fn currentLayout(self: anytype) *Layout {
    return &self.view.tab_views.items[self.activeTabIndex()].layout;
}

pub fn findPaneByUuid(self: anytype, uuid: [32]u8) ?*Pane {
    for (self.view.float_views.items) |pane| {
        if (std.mem.eql(u8, &pane.uuid, &uuid)) return pane;
    }

    for (self.view.tab_views.items) |*tab| {
        var it = tab.layout.splits.valueIterator();
        while (it.next()) |p| {
            if (std.mem.eql(u8, &p.*.uuid, &uuid)) return p.*;
        }
    }

    return null;
}

/// Find a pane by its SES-assigned pane_id (pod panes only).
pub fn findPaneByPaneId(self: anytype, pane_id: u16) ?*Pane {
    for (self.view.float_views.items) |pane| {
        if (pane.getPaneId()) |id| {
            if (id == pane_id) return pane;
        }
    }

    for (self.view.tab_views.items) |*tab| {
        var it = tab.layout.splits.valueIterator();
        while (it.next()) |p| {
            if (p.*.getPaneId()) |id| {
                if (id == pane_id) return p.*;
            }
        }
    }

    return null;
}

/// Create a new tab with one pane.
pub fn createTab(self: anytype) !void {
    const parent_uuid = self.getCurrentFocusedUuid();

    // Get cwd from currently focused pane (float or split), with fallback to the terminal process cwd.
    var cwd: ?[]const u8 = null;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (self.view.tab_views.items.len > 0) {
        // Check active float first, then split pane
        const focused_pane: ?*Pane = if (self.activeFloatingIndex()) |idx| blk: {
            if (idx < self.view.float_views.items.len) break :blk self.view.float_views.items[idx];
            break :blk null;
        } else self.currentLayout().getFocusedPane();

        if (focused_pane) |focused| {
            // Use getReliableCwd which tries multiple sources
            cwd = self.getReliableCwd(focused);
        }
        // If pane CWD is null, fall back to the terminal process current directory.
        if (cwd == null) {
            cwd = std.posix.getcwd(&cwd_buf) catch |err| blk: {
                core.logging.logError("terminal", "createNewTab: failed to get focused fallback cwd", err);
                break :blk null;
            };
        }
    } else {
        // First tab - use the terminal process current directory.
        cwd = std.posix.getcwd(&cwd_buf) catch |err| blk: {
            core.logging.logError("terminal", "createNewTab: failed to get first-tab cwd", err);
            break :blk null;
        };
    }

    // Generate tab name in format "session-N" (e.g., "alpha-1", "beta-2")
    const tab_counter = self.runtime.takeNextTabCounter();
    if (tab_counter == 999) {
        terminal_main.debugLog("VALIDATION: tab_counter reached limit, wrapping to 0", .{});
    }
    const name_owned = try core.ipc.generateTabName(self.allocator, self.runtime.sessionName(), tab_counter);
    const tab_uuid = core.ipc.generateUuid();
    var tab = self.newTabView();
    // Set ses client if connected (for new tabs after startup).
    if (self.runtime.isConnected()) {
        tab.layout.setFrontendRuntime(self.runtime);
    }
    // Set pane notification config.
    tab.layout.setPanePopConfig(&self.pop_config.pane.notification);
    const first_pane = try tab.layout.createFirstPane(cwd);
    try self.view.tab_views.append(self.allocator, tab);
    errdefer {
        var failed_tab = self.view.tab_views.pop().?;
        failed_tab.deinit();
    }
    if (!self.runtime.appendTabMeta(tab_uuid, name_owned)) return error.OutOfMemory;
    errdefer self.runtime.removeTabMeta(self.view.tab_views.items.len - 1);
    self.allocator.free(name_owned);
    if (!self.runtime.appendTabFocusMemory()) return error.OutOfMemory;
    errdefer self.runtime.removeTabFocusMemory(self.view.tab_views.items.len - 1);
    self.setActiveTabIndex(self.view.tab_views.items.len - 1);
    self.syncPaneAux(first_pane, parent_uuid);
    if (!self.syncSessionTabAddedChecked(tab_uuid, self.runtime.tabName(self.activeTabIndex()) orelse "tab", first_pane.uuid)) {
        killTabPanes(self, &self.view.tab_views.items[self.view.tab_views.items.len - 1]);
        return error.SesUnavailable;
    }
    self.renderer.invalidate();
    self.force_full_render = true;

    if (self.config._lua_runtime) |rt| {
        lua_events.emit(self, rt, "tab_created", &.{
            .{ .name = "tab", .value = .{ .int = @intCast(self.activeTabIndex() + 1) } },
            .{ .name = "tab_count", .value = .{ .int = @intCast(self.view.tab_views.items.len) } },
            .{ .name = "pane_uuid", .value = .{ .uuid = first_pane.uuid } },
        });
    }
}

/// Close the current tab.
pub fn closeCurrentTab(self: anytype) bool {
    if (self.runtime.applyPendingSessionSnapshot()) {
        _ = self.applySessionSnapshot();
    }
    if (self.view.tab_views.items.len <= 1) return false;
    const closing_tab = self.activeTabIndex();
    const closing_uuid = self.runtime.tabUuid(closing_tab) orelse {
        core.logging.warn("terminal", "closeCurrentTab skipped: active tab has no session UUID", .{});
        return false;
    };
    const next_active_tab: ?usize = if (self.view.tab_views.items.len > 1)
        if (closing_tab >= self.view.tab_views.items.len - 1) self.view.tab_views.items.len - 2 else closing_tab
    else
        null;

    if (attachedSnapshotOwnsTab(self, closing_uuid)) {
        if (!self.syncSessionTabRemovedChecked(closing_uuid, next_active_tab)) {
            core.logging.warn(
                "terminal",
                "closeCurrentTab: session rejected tab removal for {s}; closing local tab anyway",
                .{closing_uuid[0..8]},
            );
        }
    } else {
        core.logging.warn(
            "terminal",
            "closeCurrentTab: local tab {s} is absent from attached session snapshot; closing local stale tab only",
            .{closing_uuid[0..8]},
        );
    }

    // Handle tab-bound floats belonging to this tab.
    var i: usize = 0;
    while (i < self.view.float_views.items.len) {
        const fp = self.view.float_views.items[i];
        if (self.paneParentTab(fp)) |parent| {
            if (parent == closing_tab) {
                const fp_uuid = fp.uuid;
                // Kill this tab-bound float.
                self.runtime.killPane(fp_uuid) catch |e| {
                    core.logging.logError("terminal", "killPane failed in closeTab", e);
                };
                self.clearTransientPaneState(fp);
                self.clearFloatUi(fp_uuid);
                fp.deinit();
                self.allocator.destroy(fp);
                _ = self.view.float_views.orderedRemove(i);
                // Active-float tracking is uuid-based and self-adjusts across
                // removals; only clear it when the removed float was active.
                // Index-shifting here re-pointed it at the wrong float.
                if (self.runtime.activeFloatUuid()) |active_uuid| {
                    if (std.mem.eql(u8, &active_uuid, &fp_uuid)) {
                        self.setActiveFloatingUuid(null);
                    }
                }
                self.clearLocalFloatState(fp_uuid);
                continue;
            }
        }
        i += 1;
    }
    self.reindexFloatParentTabsAfterRemovedTab(closing_tab);

    var tab = self.view.tab_views.orderedRemove(closing_tab);
    {
        var split_it = tab.layout.splits.valueIterator();
        while (split_it.next()) |pane_ptr| {
            self.clearTransientPaneState(pane_ptr.*);
        }
    }
    tab.deinit();
    self.runtime.removeTabMeta(closing_tab);
    self.runtime.removeTabFocusMemory(closing_tab);
    self.applyFrontendTabRemoved(closing_tab, next_active_tab);
    if (self.activeTabIndex() >= self.view.tab_views.items.len) {
        self.setActiveTabIndex(self.view.tab_views.items.len - 1);
    } else {
        self.setActiveTabIndex(self.activeTabIndex());
    }
    if (self.activeFloatingIndex()) |afi| {
        if (afi < self.view.float_views.items.len) {
            self.syncPaneFocus(self.view.float_views.items[afi], null);
        } else if (self.currentLayout().getFocusedPane()) |pane| {
            self.setActiveFloatingIndex(null);
            self.syncPaneFocus(pane, null);
        }
    } else if (self.currentLayout().getFocusedPane()) |pane| {
        self.syncPaneFocus(pane, null);
    }
    self.renderer.invalidate();
    self.force_full_render = true;

    if (self.config._lua_runtime) |rt| {
        lua_events.emit(self, rt, "tab_closed", &.{
            .{ .name = "tab", .value = .{ .int = @intCast(closing_tab + 1) } },
            .{ .name = "tab_count", .value = .{ .int = @intCast(self.view.tab_views.items.len) } },
        });
    }
    return true;
}

/// Adopt sticky/per-CWD panes from ses on startup.
/// Finds reusable panes matching current directory and configured sticky or per-CWD floats.
fn addCwdCandidate(self: anytype, cwd_set: *std.StringHashMap(void), cwd: ?[]const u8) void {
    const value = cwd orelse return;
    if (value.len == 0) return;
    if (cwd_set.contains(value)) return;

    const owned = self.allocator.dupe(u8, value) catch |err| {
        core.logging.logError("terminal", "failed to store cwd candidate for sticky adoption", err);
        return;
    };
    cwd_set.put(owned, {}) catch |err| {
        self.allocator.free(owned);
        core.logging.logError("terminal", "failed to insert cwd candidate for sticky adoption", err);
    };
}

fn deinitCwdCandidates(self: anytype, cwd_set: *std.StringHashMap(void)) void {
    var it = cwd_set.keyIterator();
    while (it.next()) |key| {
        self.allocator.free(key.*);
    }
    cwd_set.deinit();
}

fn collectStickyAdoptionCwds(self: anytype, cwd_set: *std.StringHashMap(void)) void {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    addCwdCandidate(self, cwd_set, std.posix.getcwd(&cwd_buf) catch |err| blk: {
        core.logging.logError("terminal", "failed to get process cwd for sticky pane adoption", err);
        break :blk null;
    });

    // The session base root is an authoritative directory for this session even
    // when no live pane currently reports it: a per-CWD float created in the
    // base dir whose shell later cd'd away would otherwise be undiscoverable.
    if (self.runtime.attachedSnapshot()) |snapshot| {
        addCwdCandidate(self, cwd_set, snapshot.base_root);

        // Sticky/per-CWD floats this session remembers but does not currently
        // own keep their entry in the snapshot. Their SES sticky identity dir
        // is a first-class candidate so reconciliation can reclaim them the
        // moment they are free, even when no live pane sits in that dir.
        for (snapshot.floats.items) |float_state| {
            if (!float_state.sticky and !float_state.is_pwd) continue;
            if (self.findPaneByUuid(float_state.pane_uuid) != null) continue;
            if (self.runtime.getPaneInfoSnapshot(float_state.pane_uuid)) |info| {
                defer {
                    if (info.name) |s| self.allocator.free(s);
                    if (info.cwd) |s| self.allocator.free(s);
                    if (info.sticky_pwd) |s| self.allocator.free(s);
                    if (info.fg_name) |s| self.allocator.free(s);
                }
                addCwdCandidate(self, cwd_set, info.sticky_pwd);
            }
        }
    }

    for (self.view.tab_views.items) |*tab| {
        var it = tab.layout.splits.valueIterator();
        while (it.next()) |pane_ptr| {
            addCwdCandidate(self, cwd_set, self.paneRealCwd(pane_ptr.*));
        }
    }

    for (self.view.float_views.items) |pane| {
        // For per-CWD floats use the SES-derived sticky identity; for other
        // floats their live cwd is fine here — this is directory *discovery*,
        // not identity matching.
        if (self.paneIsPwd(pane)) {
            addCwdCandidate(self, cwd_set, ensureStickyFloatDir(self, pane));
            continue;
        }
        addCwdCandidate(self, cwd_set, self.paneRealCwd(pane));
    }
}

/// Resolve a sticky/per-CWD float's identity directory.
///
/// Identity is the `sticky_pwd` SES captured when the float was created — never
/// the float shell's live cwd, which may have `cd`'d away. The local `pwd_dir`
/// slot is only ever a cache of that SES value; when it is empty we re-fetch it
/// authoritatively from SES. Returns null only when SES has no sticky identity
/// for the pane (e.g. a plain adhoc float).
pub fn ensureStickyFloatDir(self: anytype, pane: *Pane) ?[]const u8 {
    if (self.panePwdDir(pane)) |dir| return dir;

    if (self.runtime.getPaneInfoSnapshot(pane.uuid)) |info| {
        defer {
            if (info.name) |s| self.allocator.free(s);
            if (info.cwd) |s| self.allocator.free(s);
            if (info.sticky_pwd) |s| self.allocator.free(s);
            if (info.fg_name) |s| self.allocator.free(s);
        }
        if (info.sticky_pwd) |sticky_pwd| {
            if (self.setPanePwdDir(pane.uuid, sticky_pwd)) {
                return self.panePwdDir(pane);
            }
        }
    }

    return null;
}

fn hasLocalCwdFloat(self: anytype, key: u8, cwd: []const u8) bool {
    for (self.view.float_views.items) |pane| {
        if (self.paneFloatKey(pane) != key) continue;
        // Match strictly on the SES-derived sticky identity, never on the
        // float shell's live cwd: that is what makes a key reuse its pane.
        if (ensureStickyFloatDir(self, pane)) |dir| {
            if (std.mem.eql(u8, dir, cwd)) return true;
        }
    }
    return false;
}

pub fn adoptStickyPanes(self: anytype) void {
    if (!self.runtime.isConnected()) return;

    var cwd_set = std.StringHashMap(void).init(self.allocator);
    defer deinitCwdCandidates(self, &cwd_set);
    collectStickyAdoptionCwds(self, &cwd_set);

    // Check each float definition for sticky/per-CWD floats. Per-CWD floats
    // are backed by the same SES sticky lookup metadata (pwd + key), even when
    // the config attr is `per_cwd` rather than explicit `sticky`.
    var cwd_it = cwd_set.keyIterator();
    while (cwd_it.next()) |cwd_ptr| {
        const cwd = cwd_ptr.*;
        for (self.active_layout_floats) |*float_def| {
            if (!float_def.attributes.sticky and !float_def.attributes.keyedByDir()) continue;
            if (hasLocalCwdFloat(self, float_def.key, cwd)) continue;

            // Try to claim a FREE sticky pane in ses matching this directory +
            // key. claim_free=true: speculative reconciliation must never
            // steal a float from a live mux or rip it out of another detached
            // session — that is how sessions lose floats across reattach.
            const result = self.runtime.findStickyPane(cwd, float_def.key, true) catch |err| {
                core.logging.logError("terminal", "failed to query sticky pane for layout float", err);
                continue;
            };
            if (result) |r| {
                if (self.findPaneByUuid(r.uuid)) |existing| {
                    if (float_def.attributes.keyedByDir() and self.panePwdDir(existing) == null) {
                        _ = self.setPanePwdDir(r.uuid, cwd);
                    }
                    continue;
                }

                // Found a sticky pane - adopt it as a float.
                self.adoptAsFloat(r.uuid, r.pane_id, float_def, cwd) catch |err| {
                    core.logging.logError("terminal", "failed to adopt sticky pane as float", err);
                    continue;
                };
                if (float_def.attributes.keyedByDir()) {
                    self.notifications.showFor("CWD float restored", 2000);
                } else {
                    self.notifications.showFor("Sticky float restored", 2000);
                }
            }
        }
    }
}

/// Adopt a pane from ses as a float with given float definition.
pub fn adoptAsFloat(self: anytype, uuid: [32]u8, pane_id: u16, float_def: *const core.LayoutFloatDef, cwd: []const u8) !void {
    const pane = try self.allocator.create(Pane);
    errdefer self.allocator.destroy(pane);
    var pane_registered = false;
    errdefer if (!pane_registered) self.runtime.orphanPane(uuid) catch |e| {
        terminal_main.debugLogUuid(&uuid, "adoptAsFloat rollback orphanPane failed: {s}", .{@errorName(e)});
    };

    // Use per-float settings or fall back to defaults.
    const visuals = self.resolveFloatVisuals(.named, float_def.title);
    const width_pct: u16 = float_def.width_percent orelse visuals.width_pct;
    const height_pct: u16 = float_def.height_percent orelse visuals.height_pct;
    const pos_x_pct: u16 = float_def.pos_x orelse 50;
    const pos_y_pct: u16 = float_def.pos_y orelse 50;
    const pad_x_cfg: u16 = visuals.pad_x;
    const pad_y_cfg: u16 = visuals.pad_y;
    const border_color = visuals.border_color;
    const shadow_enabled = if (visuals.float_style) |style| style.shadow_color != null else false;
    const frame = self.floatFrameFromValues(width_pct, height_pct, pos_x_pct, pos_y_pct, pad_x_cfg, pad_y_cfg, shadow_enabled);
    const width_pct_u8: u8 = @intCast(@min(width_pct, 100));
    const height_pct_u8: u8 = @intCast(@min(height_pct, 100));
    const pos_x_pct_u8: u8 = @intCast(@min(pos_x_pct, 100));
    const pos_y_pct_u8: u8 = @intCast(@min(pos_y_pct, 100));

    // Generate pane ID (floats use 100+ offset).
    const id: u16 = @intCast(100 + self.view.float_views.items.len);

    // Initialize pane with the adopted pod — VT routed through SES.
    const vt_fd = self.runtime.getVtFd() orelse return error.NoVtChannel;
    try pane.initWithPod(self.allocator, id, frame.content_x, frame.content_y, frame.content_w, frame.content_h, pane_id, vt_fd, uuid);

    if (self.runtime.getPaneInfoSnapshot(uuid)) |snap| {
        defer if (snap.cwd) |snap_cwd| self.allocator.free(snap_cwd);
        defer if (snap.sticky_pwd) |pwd| self.allocator.free(pwd);
        defer if (snap.fg_name) |s| self.allocator.free(s);
        if (snap.name) |name| {
            self.setPaneNameOwned(uuid, name);
        }
        if (snap.cwd) |snap_cwd| {
            self.setPaneShell(uuid, null, snap_cwd, null, null, null);
        }
        self.setPaneProc(uuid, snap.fg_name, snap.fg_pid);
    } else {
        self.runtime.requestPaneProcess(uuid);
        self.runtime.requestPaneCwd(uuid);
    }

    pane.focused = true;

    // For global floats (special or pwd), set per-tab visibility.
    const parent_tab: ?usize = if (!float_def.attributes.global and !float_def.attributes.keyedByDir())
        self.activeTabIndex()
    else
        null;
    const tab_visible: u64 = if (parent_tab == null and self.activeTabIndex() < 64)
        (@as(u64, 1) << @intCast(self.activeTabIndex()))
    else
        0;

    if (!self.setPaneFloatUi(uuid, .{
        .border_x = frame.outer_x,
        .border_y = frame.outer_y,
        .border_w = frame.outer_w,
        .border_h = frame.outer_h,
        .border_color = border_color,
        .width_pct = width_pct_u8,
        .height_pct = height_pct_u8,
        .pos_x_pct = pos_x_pct_u8,
        .pos_y_pct = pos_y_pct_u8,
        .pad_x = @intCast(pad_x_cfg),
        .pad_y = @intCast(pad_y_cfg),
        .pwd_dir = if (float_def.attributes.keyedByDir()) cwd else null,
        .float_style = visuals.float_style,
        .float_title = float_def.title,
    })) return error.OutOfMemory;

    // Configure pane notifications.
    pane.configureNotificationsFromPop(&self.pop_config.pane.notification);

    try self.view.float_views.append(self.allocator, pane);
    self.setLocalFloatState(
        pane.uuid,
        parent_tab,
        true,
        tab_visible,
        float_def.attributes.sticky,
        float_def.attributes.keyedByDir(),
        float_def.key,
        width_pct_u8,
        height_pct_u8,
        pos_x_pct_u8,
        pos_y_pct_u8,
        @intCast(pad_x_cfg),
        @intCast(pad_y_cfg),
        false,
    );
    if (!self.syncSessionFloatChecked(pane, false)) {
        self.notifications.show("Sticky float session sync failed");
    }
    // Don't set active_floating here - let user toggle it manually.
    pane_registered = true;
}

/// Switch to next tab.
pub fn nextTab(self: anytype) void {
    if (self.view.tab_views.items.len > 1) {
        tab_switch.switchToTab(self, (self.activeTabIndex() + 1) % self.view.tab_views.items.len);
    }
}

/// Switch to previous tab.
pub fn prevTab(self: anytype) void {
    if (self.view.tab_views.items.len > 1) {
        tab_switch.switchToTab(self, if (self.activeTabIndex() == 0) self.view.tab_views.items.len - 1 else self.activeTabIndex() - 1);
    }
}

/// Adopt first orphaned pane, replacing current focused pane.
pub fn adoptOrphanedPane(self: anytype) bool {
    if (!self.runtime.isConnected()) return false;

    // Get list of orphaned panes.
    var panes: [32]OrphanedPaneInfo = undefined;
    const count = self.runtime.listOrphanedPanes(&panes) catch |err| {
        core.logging.logError("terminal", "adoptOrphanedPane failed to list orphaned panes", err);
        return false;
    };
    if (count == 0) return false;

    const vt_fd = self.runtime.getVtFd() orelse {
        core.logging.warn("terminal", "adoptOrphanedPane skipped: SES VT channel is unavailable", .{});
        return false;
    };

    const pane = if (self.activeFloatingIndex()) |idx|
        self.view.float_views.items[idx]
    else
        self.currentLayout().getFocusedPane() orelse {
            core.logging.warn("terminal", "adoptOrphanedPane skipped: no focused pane to replace", .{});
            return false;
        };

    const active_float = self.paneIsFloating(pane);
    const old_uuid = pane.uuid;
    const result = self.runtime.adoptPane(panes[0].uuid) catch |err| {
        terminal_main.debugLogUuid(&panes[0].uuid, "adoptOrphanedPane adoptPane failed: {s}", .{@errorName(err)});
        return false;
    };
    if (!self.replacePaneWithPodSynced(
        old_uuid,
        result.uuid,
        result.pane_id,
        vt_fd,
        pane,
        active_float,
        .orphan_new_pane,
        "adoptOrphanedPane: rollback orphanPane failed after replacement error",
    )) {
        return false;
    }
    self.runtime.killPane(old_uuid) catch |e| {
        terminal_main.debugLogUuid(&old_uuid, "adoptOrphanedPane: killPane failed after replace: {s}", .{@errorName(e)});
    };

    self.renderer.invalidate();
    self.force_full_render = true;
    return true;
}

/// Reattach to a detached session, restoring full state.
pub fn reattachSession(self: anytype, session_id_prefix: []const u8) bool {
    return state_reattach.reattachSession(self, session_id_prefix);
}

pub fn applySessionSnapshot(self: anytype) bool {
    return state_reattach.applySessionSnapshot(self);
}

/// Attach to orphaned pane by UUID prefix (for --attach CLI).
pub fn attachOrphanedPane(self: anytype, uuid_prefix: []const u8) bool {
    return state_reattach.attachOrphanedPane(self, uuid_prefix);
}
