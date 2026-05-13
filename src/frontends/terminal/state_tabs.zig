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
    var tab = TabView.init(self.allocator, self.layout_width, self.layout_height, self.pop_config.carrier.notification);
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
                // Clear active_floating if it was this float.
                if (self.activeFloatingIndex()) |afi| {
                    if (afi == i) {
                        self.setActiveFloatingIndex(null);
                    } else if (afi > i) {
                        self.setActiveFloatingIndex(afi - 1);
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
    return true;
}

/// Adopt sticky panes from ses on startup.
/// Finds sticky panes matching current directory and configured sticky floats.
pub fn adoptStickyPanes(self: anytype) void {
    if (!self.runtime.isConnected()) return;

    // Get current working directory.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch |err| {
        core.logging.logError("terminal", "failed to get cwd for sticky pane adoption", err);
        return;
    };

    // Check each float definition for sticky floats.
    for (self.active_layout_floats) |*float_def| {
        if (!float_def.attributes.sticky) continue;

        // Try to find a sticky pane in ses matching this directory + key.
        const result = self.runtime.findStickyPane(cwd, float_def.key) catch |err| {
            core.logging.logError("terminal", "failed to query sticky pane for layout float", err);
            continue;
        };
        if (result) |r| {
            // Found a sticky pane - adopt it as a float.
            self.adoptAsFloat(r.uuid, r.pane_id, float_def, cwd) catch |err| {
                core.logging.logError("terminal", "failed to adopt sticky pane as float", err);
                continue;
            };
            self.notifications.showFor("Sticky float restored", 2000);
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
    const parent_tab: ?usize = if (!float_def.attributes.global and !float_def.attributes.per_cwd)
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
        .pwd_dir = if (float_def.attributes.per_cwd) cwd else null,
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
        float_def.attributes.per_cwd,
        float_def.key,
        width_pct_u8,
        height_pct_u8,
        pos_x_pct_u8,
        pos_y_pct_u8,
        @intCast(pad_x_cfg),
        @intCast(pad_y_cfg),
        false,
    );
    // Don't set active_floating here - let user toggle it manually.
    pane_registered = true;
}

/// Switch to next tab.
pub fn nextTab(self: anytype) void {
    if (self.view.tab_views.items.len > 1) {
        const prev_tab = self.activeTabIndex();
        tab_switch.switchToTab(self, (self.activeTabIndex() + 1) % self.view.tab_views.items.len);

        if (self.config._lua_runtime) |rt| {
            rt.lua.createTable(0, 6);
            _ = rt.lua.pushString("tab_changed");
            rt.lua.setField(-2, "event");
            rt.lua.pushInteger(@intCast(prev_tab + 1));
            rt.lua.setField(-2, "previous_tab");
            rt.lua.pushInteger(@intCast(self.activeTabIndex() + 1));
            rt.lua.setField(-2, "active_tab");
            rt.lua.pushInteger(@intCast(self.view.tab_views.items.len));
            rt.lua.setField(-2, "tab_count");
            rt.lua.pushInteger(@intCast(std.time.milliTimestamp()));
            rt.lua.setField(-2, "now_ms");
            lua_events.emitAutocmdWithPayloadOnStack(rt, "tab_changed");
        }
    }
}

/// Switch to previous tab.
pub fn prevTab(self: anytype) void {
    if (self.view.tab_views.items.len > 1) {
        const prev_tab = self.activeTabIndex();
        tab_switch.switchToTab(self, if (self.activeTabIndex() == 0) self.view.tab_views.items.len - 1 else self.activeTabIndex() - 1);

        if (self.config._lua_runtime) |rt| {
            rt.lua.createTable(0, 6);
            _ = rt.lua.pushString("tab_changed");
            rt.lua.setField(-2, "event");
            rt.lua.pushInteger(@intCast(prev_tab + 1));
            rt.lua.setField(-2, "previous_tab");
            rt.lua.pushInteger(@intCast(self.activeTabIndex() + 1));
            rt.lua.setField(-2, "active_tab");
            rt.lua.pushInteger(@intCast(self.view.tab_views.items.len));
            rt.lua.setField(-2, "tab_count");
            rt.lua.pushInteger(@intCast(std.time.milliTimestamp()));
            rt.lua.setField(-2, "now_ms");
            lua_events.emitAutocmdWithPayloadOnStack(rt, "tab_changed");
        }
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
