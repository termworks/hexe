const std = @import("std");
const core = @import("core");
const mux = @import("main.zig");

const state_types = @import("state_types.zig");
const Tab = state_types.Tab;

const layout_mod = @import("layout.zig");
const Layout = layout_mod.Layout;
const LayoutNode = layout_mod.LayoutNode;

const Pane = @import("pane.zig").Pane;
const OrphanedPaneInfo = core.FrontendOrphanedPaneInfo;
const state_reattach = @import("state_reattach.zig");
const tab_switch = @import("tab_switch.zig");
const lua_events = @import("lua_events.zig");

/// Get the current tab's layout.
pub fn currentLayout(self: anytype) *Layout {
    return &self.tabs.items[self.activeTabIndex()].layout;
}

pub fn findPaneByUuid(self: anytype, uuid: [32]u8) ?*Pane {
    for (self.floats.items) |pane| {
        if (std.mem.eql(u8, &pane.uuid, &uuid)) return pane;
    }

    for (self.tabs.items) |*tab| {
        var it = tab.layout.splits.valueIterator();
        while (it.next()) |p| {
            if (std.mem.eql(u8, &p.*.uuid, &uuid)) return p.*;
        }
    }

    return null;
}

/// Find a pane by its SES-assigned pane_id (pod panes only).
pub fn findPaneByPaneId(self: anytype, pane_id: u16) ?*Pane {
    for (self.floats.items) |pane| {
        if (pane.getPaneId()) |id| {
            if (id == pane_id) return pane;
        }
    }

    for (self.tabs.items) |*tab| {
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

    // Get cwd from currently focused pane (float or split), with fallback to mux's cwd.
    var cwd: ?[]const u8 = null;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (self.tabs.items.len > 0) {
        // Check active float first, then split pane
        const focused_pane: ?*Pane = if (self.activeFloatingIndex()) |idx| blk: {
            if (idx < self.floats.items.len) break :blk self.floats.items[idx];
            break :blk null;
        } else self.currentLayout().getFocusedPane();

        if (focused_pane) |focused| {
            // Use getReliableCwd which tries multiple sources
            cwd = self.getReliableCwd(focused);
        }
        // If pane CWD is null, fall back to mux's current directory
        if (cwd == null) {
            cwd = std.posix.getcwd(&cwd_buf) catch null;
        }
    } else {
        // First tab - use mux's current directory.
        cwd = std.posix.getcwd(&cwd_buf) catch null;
    }

    // Generate tab name in format "session-N" (e.g., "alpha-1", "beta-2")
    const tab_counter = self.takeNextTabCounter();
    if (tab_counter == 999) {
        mux.debugLog("VALIDATION: tab_counter reached limit, wrapping to 0", .{});
    }
    const name_owned = try core.ipc.generateTabName(self.allocator, self.sessionName(), tab_counter);
    const tab_uuid = core.ipc.generateUuid();
    var tab = Tab.init(self.allocator, self.layout_width, self.layout_height, self.pop_config.carrier.notification);
    // Set ses client if connected (for new tabs after startup).
    if (self.frontend_client.isConnected()) {
        tab.layout.setFrontendClient(&self.frontend_client);
    }
    // Set pane notification config.
    tab.layout.setPanePopConfig(&self.pop_config.pane.notification);
    const first_pane = try tab.layout.createFirstPane(cwd);
    try self.tabs.append(self.allocator, tab);
    errdefer {
        var failed_tab = self.tabs.pop().?;
        failed_tab.deinit();
    }
    if (!self.appendTabMeta(tab_uuid, name_owned)) return error.OutOfMemory;
    errdefer self.removeTabMeta(self.tabs.items.len - 1);
    self.allocator.free(name_owned);
    if (!self.appendTabFocusMemory()) return error.OutOfMemory;
    errdefer self.removeTabFocusMemory(self.tabs.items.len - 1);
    self.setActiveTabIndex(self.tabs.items.len - 1);
    self.syncPaneAux(first_pane, parent_uuid);
    self.syncSessionTabAdded(tab_uuid, self.tabName(self.activeTabIndex()), first_pane.uuid);
    self.renderer.invalidate();
    self.force_full_render = true;
}

/// Close the current tab.
pub fn closeCurrentTab(self: anytype) bool {
    if (self.tabs.items.len <= 1) return false;
    const closing_tab = self.activeTabIndex();
    const closing_uuid = self.tabUuid(closing_tab) orelse return false;

    // Handle tab-bound floats belonging to this tab.
    var i: usize = 0;
    while (i < self.floats.items.len) {
        const fp = self.floats.items[i];
        if (fp.parent_tab) |parent| {
            if (parent == closing_tab) {
                // Kill this tab-bound float.
                self.frontend_client.killPane(fp.uuid) catch |e| {
                    core.logging.logError("mux", "killPane failed in closeTab", e);
                };
                fp.deinit();
                self.allocator.destroy(fp);
                _ = self.floats.orderedRemove(i);
                // Clear active_floating if it was this float.
                if (self.activeFloatingIndex()) |afi| {
                    if (afi == i) {
                        self.setActiveFloatingIndex(null);
                    } else if (afi > i) {
                        self.setActiveFloatingIndex(afi - 1);
                    }
                }
                self.syncSessionFloatRemoved(fp.uuid);
                continue;
            } else if (parent > closing_tab) {
                // Adjust index for floats on later tabs.
                fp.parent_tab = parent - 1;
                self.syncSessionFloat(fp, false);
            }
        }
        i += 1;
    }

    var tab = self.tabs.orderedRemove(self.activeTabIndex());
    tab.deinit();
    self.removeTabMeta(self.activeTabIndex());
    self.removeTabFocusMemory(self.activeTabIndex());
    if (self.activeTabIndex() >= self.tabs.items.len) {
        self.setActiveTabIndex(self.tabs.items.len - 1);
    } else {
        self.setActiveTabIndex(self.activeTabIndex());
    }
    if (self.activeFloatingIndex()) |afi| {
        if (afi < self.floats.items.len) {
            self.syncPaneFocus(self.floats.items[afi], null);
        } else if (self.currentLayout().getFocusedPane()) |pane| {
            self.setActiveFloatingIndex(null);
            self.syncPaneFocus(pane, null);
        }
    } else if (self.currentLayout().getFocusedPane()) |pane| {
        self.syncPaneFocus(pane, null);
    }
    self.renderer.invalidate();
    self.force_full_render = true;
    self.syncSessionTabRemoved(closing_uuid);
    return true;
}

/// Adopt sticky panes from ses on startup.
/// Finds sticky panes matching current directory and configured sticky floats.
pub fn adoptStickyPanes(self: anytype) void {
    if (!self.frontend_client.isConnected()) return;

    // Get current working directory.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch return;

    // Check each float definition for sticky floats.
    for (self.active_layout_floats) |*float_def| {
        if (!float_def.attributes.sticky) continue;

        // Try to find a sticky pane in ses matching this directory + key.
        const result = self.frontend_client.findStickyPane(cwd, float_def.key) catch continue;
        if (result) |r| {
            // Found a sticky pane - adopt it as a float.
            self.adoptAsFloat(r.uuid, r.pane_id, float_def, cwd) catch continue;
            self.notifications.showFor("Sticky float restored", 2000);
        }
    }
}

/// Adopt a pane from ses as a float with given float definition.
pub fn adoptAsFloat(self: anytype, uuid: [32]u8, pane_id: u16, float_def: *const core.LayoutFloatDef, cwd: []const u8) !void {
    const pane = try self.allocator.create(Pane);
    errdefer self.allocator.destroy(pane);

    const cfg = &self.config;

    // Use per-float settings or fall back to defaults.
    const width_pct: u16 = float_def.width_percent orelse cfg.float_width_percent;
    const height_pct: u16 = float_def.height_percent orelse cfg.float_height_percent;
    const pos_x_pct: u16 = float_def.pos_x orelse 50;
    const pos_y_pct: u16 = float_def.pos_y orelse 50;
    const pad_x_cfg: u16 = float_def.padding_x orelse cfg.float_padding_x;
    const pad_y_cfg: u16 = float_def.padding_y orelse cfg.float_padding_y;
    const border_color = float_def.color orelse cfg.float_color;

    // Calculate outer frame size.
    const avail_h = self.term_height - self.status_height;
    const outer_w = self.term_width * width_pct / 100;
    const outer_h = avail_h * height_pct / 100;

    // Calculate position based on percentage.
    const max_x = if (self.term_width > outer_w) self.term_width - outer_w else 0;
    const max_y = if (avail_h > outer_h) avail_h - outer_h else 0;
    const outer_x = max_x * pos_x_pct / 100;
    const outer_y = max_y * pos_y_pct / 100;

    // Apply padding.
    const pad_x: u16 = @intCast(@min(pad_x_cfg, outer_w / 4));
    const pad_y: u16 = @intCast(@min(pad_y_cfg, outer_h / 4));
    const content_x = outer_x + 1 + pad_x;
    const content_y = outer_y + 1 + pad_y;
    const content_w = if (outer_w > 2 + 2 * pad_x) outer_w - 2 - 2 * pad_x else 1;
    const content_h = if (outer_h > 2 + 2 * pad_y) outer_h - 2 - 2 * pad_y else 1;

    // Generate pane ID (floats use 100+ offset).
    const id: u16 = @intCast(100 + self.floats.items.len);

    // Initialize pane with the adopted pod — VT routed through SES.
    const vt_fd = self.frontend_client.getVtFd() orelse return error.NoVtChannel;
    try pane.initWithPod(self.allocator, id, content_x, content_y, content_w, content_h, pane_id, vt_fd, uuid);

    if (self.frontend_client.getPaneInfoSnapshot(uuid)) |snap| {
        defer if (snap.fg_name) |s| self.allocator.free(s);
        if (snap.name) |name| {
            self.setPaneNameOwned(uuid, name);
        }
        pane.setSesCwd(snap.cwd);
        self.setPaneProc(uuid, snap.fg_name, snap.fg_pid);
    } else {
        self.frontend_client.requestPaneProcess(uuid);
        self.frontend_client.requestPaneCwd(uuid);
    }

    pane.floating = true;
    pane.focused = true;
    pane.float_key = float_def.key;
    pane.sticky = float_def.attributes.sticky;

    // For global floats (special or pwd), set per-tab visibility.
    if (float_def.attributes.global or float_def.attributes.per_cwd) {
        pane.setVisibleOnTab(self.activeTabIndex(), true);
    } else {
        pane.visible = true;
    }

    // Store outer dimensions and style for border rendering.
    pane.border_x = outer_x;
    pane.border_y = outer_y;
    pane.border_w = outer_w;
    pane.border_h = outer_h;
    pane.border_color = border_color;
    // Store percentages for resize recalculation.
    pane.float_width_pct = @intCast(width_pct);
    pane.float_height_pct = @intCast(height_pct);
    pane.float_pos_x_pct = @intCast(pos_x_pct);
    pane.float_pos_y_pct = @intCast(pos_y_pct);
    pane.float_pad_x = @intCast(pad_x_cfg);
    pane.float_pad_y = @intCast(pad_y_cfg);

    // Store pwd for pwd floats.
    if (float_def.attributes.per_cwd) {
        pane.is_pwd = true;
        pane.pwd_dir = self.allocator.dupe(u8, cwd) catch null;
    }

    // For tab-bound floats, set parent tab.
    if (!float_def.attributes.global and !float_def.attributes.per_cwd) {
        pane.parent_tab = self.activeTabIndex();
    }

    // Store style reference.
    if (float_def.style) |*style| {
        pane.float_style = style;
    }

    // Configure pane notifications.
    pane.configureNotificationsFromPop(&self.pop_config.pane.notification);

    try self.floats.append(self.allocator, pane);
    // Don't set active_floating here - let user toggle it manually.
}

/// Switch to next tab.
pub fn nextTab(self: anytype) void {
    if (self.tabs.items.len > 1) {
        const prev_tab = self.activeTabIndex();
        tab_switch.switchToTab(self, (self.activeTabIndex() + 1) % self.tabs.items.len);

        if (self.config._lua_runtime) |rt| {
            rt.lua.createTable(0, 6);
            _ = rt.lua.pushString("tab_changed");
            rt.lua.setField(-2, "event");
            rt.lua.pushInteger(@intCast(prev_tab + 1));
            rt.lua.setField(-2, "previous_tab");
            rt.lua.pushInteger(@intCast(self.activeTabIndex() + 1));
            rt.lua.setField(-2, "active_tab");
            rt.lua.pushInteger(@intCast(self.tabs.items.len));
            rt.lua.setField(-2, "tab_count");
            rt.lua.pushInteger(@intCast(std.time.milliTimestamp()));
            rt.lua.setField(-2, "now_ms");
            lua_events.emitAutocmdWithPayloadOnStack(rt, "tab_changed");
        }
    }
}

/// Switch to previous tab.
pub fn prevTab(self: anytype) void {
    if (self.tabs.items.len > 1) {
        const prev_tab = self.activeTabIndex();
        tab_switch.switchToTab(self, if (self.activeTabIndex() == 0) self.tabs.items.len - 1 else self.activeTabIndex() - 1);

        if (self.config._lua_runtime) |rt| {
            rt.lua.createTable(0, 6);
            _ = rt.lua.pushString("tab_changed");
            rt.lua.setField(-2, "event");
            rt.lua.pushInteger(@intCast(prev_tab + 1));
            rt.lua.setField(-2, "previous_tab");
            rt.lua.pushInteger(@intCast(self.activeTabIndex() + 1));
            rt.lua.setField(-2, "active_tab");
            rt.lua.pushInteger(@intCast(self.tabs.items.len));
            rt.lua.setField(-2, "tab_count");
            rt.lua.pushInteger(@intCast(std.time.milliTimestamp()));
            rt.lua.setField(-2, "now_ms");
            lua_events.emitAutocmdWithPayloadOnStack(rt, "tab_changed");
        }
    }
}

/// Adopt first orphaned pane, replacing current focused pane.
pub fn adoptOrphanedPane(self: anytype) bool {
    if (!self.frontend_client.isConnected()) return false;

    // Get list of orphaned panes.
    var panes: [32]OrphanedPaneInfo = undefined;
    const count = self.frontend_client.listOrphanedPanes(&panes) catch return false;
    if (count == 0) return false;

    // Adopt the first one.
    const result = self.frontend_client.adoptPane(panes[0].uuid) catch return false;
    const vt_fd = self.frontend_client.getVtFd() orelse return false;

    // Get the current focused pane and replace it.
    if (self.activeFloatingIndex()) |idx| {
        const old_pane = self.floats.items[idx];
        old_pane.replaceWithPod(result.pane_id, vt_fd, result.uuid) catch return false;
    } else if (self.currentLayout().getFocusedPane()) |pane| {
        pane.replaceWithPod(result.pane_id, vt_fd, result.uuid) catch return false;
    } else {
        return false;
    }

    self.renderer.invalidate();
    self.force_full_render = true;
    return true;
}

/// Reattach to a detached session, restoring full state.
pub fn reattachSession(self: anytype, session_id_prefix: []const u8) bool {
    return state_reattach.reattachSession(self, session_id_prefix);
}

pub fn applySessionSnapshot(self: anytype, session_state_json: []const u8) bool {
    return state_reattach.applySessionSnapshot(self, session_state_json);
}

/// Attach to orphaned pane by UUID prefix (for --attach CLI).
pub fn attachOrphanedPane(self: anytype, uuid_prefix: []const u8) bool {
    return state_reattach.attachOrphanedPane(self, uuid_prefix);
}
