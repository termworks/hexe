const std = @import("std");
const posix = std.posix;
const core = @import("core");

const FrontendClient = core.FrontendClient;
const Pane = @import("pane.zig").Pane;
const helpers = @import("helpers.zig");
const layout_mod = @import("layout.zig");
const lua_events = @import("lua_events.zig");

fn buildSessionLayoutNode(
    allocator: std.mem.Allocator,
    layout: *layout_mod.Layout,
    node: *layout_mod.LayoutNode,
) !*core.session_model.SessionLayoutNode {
    const out = try allocator.create(core.session_model.SessionLayoutNode);
    errdefer allocator.destroy(out);

    switch (node.*) {
        .pane => |id| {
            const pane = layout.splits.get(id) orelse return error.InvalidLayout;
            out.* = .{ .pane = pane.uuid };
        },
        .split => |split| {
            const first = try buildSessionLayoutNode(allocator, layout, split.first);
            errdefer {
                first.deinit(allocator);
                allocator.destroy(first);
            }
            const second = try buildSessionLayoutNode(allocator, layout, split.second);
            errdefer {
                second.deinit(allocator);
                allocator.destroy(second);
            }
            out.* = .{
                .split = .{
                    .dir = if (split.dir == .horizontal) .horizontal else .vertical,
                    .ratio = split.ratio,
                    .first = first,
                    .second = second,
                },
            };
        },
    }

    return out;
}

pub fn buildSessionSnapshot(self: anytype) !core.session_model.SessionSnapshot {
    var snapshot = try core.session_model.SessionSnapshot.initMinimal(self.allocator, self.sessionUuid(), self.sessionName());
    errdefer snapshot.deinit();

    snapshot.tab_counter = self.sessionTabCounter();
    if (self.view.tabs.items.len > 0) {
        snapshot.active_tab = self.activeTabIndex();
    } else {
        snapshot.active_tab = 0;
    }
    snapshot.active_float_uuid = if (self.activeFloatingIndex()) |idx| self.view.floats.items[idx].uuid else null;
    snapshot.focused_pane_uuid = self.focusedPaneUuid() orelse getCurrentFocusedUuid(self);

    for (self.view.tabs.items, 0..) |*tab, tab_idx| {
        const tab_uuid = self.tabUuid(tab_idx) orelse continue;
        var session_tab = core.session_model.SessionTab{
            .uuid = tab_uuid,
            .name = try self.allocator.dupe(u8, self.tabName(tab_idx)),
            .root = if (tab.layout.root) |root| try buildSessionLayoutNode(self.allocator, &tab.layout, root) else null,
            .focused_pane_uuid = if (tab.layout.getFocusedPane()) |pane| pane.uuid else null,
            .allocator = self.allocator,
        };
        errdefer session_tab.deinit();
        try snapshot.tabs.append(self.allocator, session_tab);

        var pane_it = tab.layout.splits.valueIterator();
        while (pane_it.next()) |pane_ptr| {
            try snapshot.panes.put(pane_ptr.*.uuid, .{
                .uuid = pane_ptr.*.uuid,
                .kind = .split,
                .parent_tab = tab_idx,
            });
        }
    }

    for (self.view.floats.items) |pane| {
        try snapshot.floats.append(self.allocator, .{
            .pane_uuid = pane.uuid,
            .parent_tab = pane.parent_tab,
            .visible = pane.visible,
            .tab_visible = pane.tab_visible,
            .sticky = pane.sticky,
            .is_pwd = pane.is_pwd,
            .float_key = pane.float_key,
            .width_pct = pane.float_width_pct,
            .height_pct = pane.float_height_pct,
            .pos_x_pct = pane.float_pos_x_pct,
            .pos_y_pct = pane.float_pos_y_pct,
            .pad_x = pane.float_pad_x,
            .pad_y = pane.float_pad_y,
        });
        try snapshot.panes.put(pane.uuid, .{
            .uuid = pane.uuid,
            .kind = .float,
            .parent_tab = pane.parent_tab,
            .sticky = pane.sticky,
            .is_pwd = pane.is_pwd,
            .float_key = pane.float_key,
        });
    }

    return snapshot;
}

fn setLayoutFocusedSplitId(self: anytype, pane: *Pane) void {
    if (pane.floating) return;

    // Find which tab/layout owns this pane pointer and set its focused_split_id
    // to match. This keeps per-tab focus stable when switching tabs.
    for (self.view.tabs.items) |*tab| {
        var it = tab.layout.splits.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == pane) {
                tab.layout.focused_split_id = entry.key_ptr.*;
                return;
            }
        }
    }
}

fn rememberFloatingFocus(self: anytype, pane: *Pane) void {
    if (!pane.floating) return;
    self.rememberFloatingFocus(pane);
}

fn rememberSplitFocus(self: anytype, pane: *Pane) void {
    if (pane.floating) return;
    self.rememberSplitFocus();
}

pub fn syncStateToSes(self: anytype) void {
    if (!self.frontend_client.isConnected()) return;

    var snapshot = buildSessionSnapshot(self) catch return;
    defer snapshot.deinit();
    const session_state_json = snapshot.toJson(self.allocator) catch return;
    defer self.allocator.free(session_state_json);

    // Increment version before syncing.
    const version = self.nextStateVersion();

    self.frontend_client.syncState(session_state_json, version) catch |e| {
        core.logging.logError("mux", "syncState failed", e);
    };
}

pub fn syncSessionTabAdded(self: anytype, tab_uuid: [32]u8, name: []const u8, pane_uuid: [32]u8) void {
    if (!self.frontend_client.isConnected()) return;
    self.frontend_client.sessionAddTab(tab_uuid, pane_uuid, self.activeTabIndex(), name) catch |err| {
        core.logging.logError("mux", "failed sessionAddTab IPC", err);
    };
}

pub fn syncSessionTabRemoved(self: anytype, tab_uuid: [32]u8) void {
    if (!self.frontend_client.isConnected()) return;
    const active_tab: ?usize = if (self.view.tabs.items.len > 0) self.activeTabIndex() else null;
    self.frontend_client.sessionRemoveTab(tab_uuid, active_tab) catch |err| {
        core.logging.logError("mux", "failed sessionRemoveTab IPC", err);
    };
}

pub fn syncSessionFloat(self: anytype, pane: *Pane, active: bool) void {
    if (!self.frontend_client.isConnected()) return;
    if (pane.uuid[0] == 0) return;

    self.frontend_client.sessionSyncFloat(
        pane.uuid,
        self.activeTabIndex(),
        pane.parent_tab,
        pane.visible,
        pane.tab_visible,
        pane.sticky,
        pane.is_pwd,
        pane.float_key,
        pane.float_width_pct,
        pane.float_height_pct,
        pane.float_pos_x_pct,
        pane.float_pos_y_pct,
        pane.float_pad_x,
        pane.float_pad_y,
        active,
    ) catch |err| {
        core.logging.logError("mux", "failed sessionSyncFloat IPC", err);
    };
}

pub fn syncSessionFloatRemoved(self: anytype, pane_uuid: [32]u8) void {
    if (!self.frontend_client.isConnected()) return;
    if (pane_uuid[0] == 0) return;
    self.frontend_client.sessionRemoveFloat(pane_uuid) catch |err| {
        core.logging.logError("mux", "failed sessionRemoveFloat IPC", err);
    };
}

pub fn syncActiveTabLayout(self: anytype) void {
    if (!self.frontend_client.isConnected()) return;
    if (self.view.tabs.items.len == 0 or self.activeTabIndex() >= self.view.tabs.items.len) return;

    const tab = &self.view.tabs.items[self.activeTabIndex()];
    const tab_uuid = self.tabUuid(self.activeTabIndex()) orelse return;
    const session_root = if (tab.layout.root) |root|
        buildSessionLayoutNode(self.allocator, &tab.layout, root) catch return
    else
        null;
    defer if (session_root) |root| {
        root.deinit(self.allocator);
        self.allocator.destroy(root);
    };

    const root_json = core.session_model.layoutNodeToJson(self.allocator, session_root) catch return;
    defer self.allocator.free(root_json);

    self.frontend_client.sessionSyncTabLayout(
        tab_uuid,
        self.activeTabIndex(),
        if (tab.layout.getFocusedPane()) |pane| pane.uuid else null,
        root_json,
    ) catch |err| {
        core.logging.logError("mux", "failed sessionSyncTabLayout IPC", err);
    };
}

pub fn getCurrentFocusedUuid(self: anytype) ?[32]u8 {
    if (self.focusedPaneUuid()) |uuid| {
        if (self.findPaneByUuid(uuid) != null) return uuid;
    }
    if (self.activeFloatingIndex()) |idx| {
        if (idx < self.view.floats.items.len) {
            return self.view.floats.items[idx].uuid;
        }
    }
    if (self.view.tabs.items.len == 0) return null;
    if (self.currentLayout().getFocusedPane()) |pane| {
        return pane.uuid;
    }
    return null;
}

pub fn syncPaneAux(self: anytype, pane: *Pane, created_from: ?[32]u8) void {
    if (!self.frontend_client.isConnected()) return;
    if (pane.uuid[0] == 0) return;

    if (pane.focused) {
        self.unfocusAllPanes();
        pane.focused = true;
    }

    const pane_type: FrontendClient.PaneType = if (pane.floating) .float else .split;
    const cursor = pane.getCursorPos();
    const cursor_style = pane.vt.getCursorStyle();
    const cursor_visible = pane.vt.isCursorVisible();
    const alt_screen = pane.vt.inAltScreen();
    const layout_path = helpers.getLayoutPath(self, pane) catch null;
    defer if (layout_path) |path| self.allocator.free(path);
    const focused_from = if (pane.focused) created_from else null;
    self.frontend_client.updatePaneAux(
        pane.uuid,
        self.activeTabIndex(),
        pane.floating,
        pane.focused,
        pane_type,
        created_from,
        focused_from,
        .{ .x = cursor.x, .y = cursor.y },
        cursor_style,
        cursor_visible,
        alt_screen,
        .{ .cols = pane.width, .rows = pane.height },
        pane.getRealCwd(),
        pane.getFgProcess(),
        pane.getFgPid(),
        layout_path,
    ) catch |err| {
        core.logging.logError("mux", "failed IPC operation in state_sync", err);
    };
}

pub fn unfocusAllPanes(self: anytype) void {
    if (!self.frontend_client.isConnected()) return;

    for (self.view.tabs.items) |*tab| {
        var pane_it = tab.layout.splitIterator();
        while (pane_it.next()) |p| {
            if (p.*.uuid[0] != 0) {
                p.*.focused = false;
                const pane_type: FrontendClient.PaneType = if (p.*.floating) .float else .split;
                const cursor = p.*.getCursorPos();
                const cursor_style = p.*.vt.getCursorStyle();
                const cursor_visible = p.*.vt.isCursorVisible();
                const alt_screen = p.*.vt.inAltScreen();
                const layout_path = helpers.getLayoutPath(self, p.*) catch null;
                defer if (layout_path) |path| self.allocator.free(path);
                self.frontend_client.updatePaneAux(
                    p.*.uuid,
                    self.activeTabIndex(),
                    p.*.floating,
                    false,
                    pane_type,
                    null,
                    null,
                    .{ .x = cursor.x, .y = cursor.y },
                    cursor_style,
                    cursor_visible,
                    alt_screen,
                    .{ .cols = p.*.width, .rows = p.*.height },
                    null,
                    null,
                    null,
                    layout_path,
                ) catch |err| {
                    core.logging.logError("mux", "failed IPC operation in state_sync", err);
                };
            }
        }
    }

    for (self.view.floats.items) |fp| {
        if (fp.uuid[0] != 0) {
            fp.focused = false;
            const cursor = fp.getCursorPos();
            const cursor_style = fp.vt.getCursorStyle();
            const cursor_visible = fp.vt.isCursorVisible();
            const alt_screen = fp.vt.inAltScreen();
            const layout_path = helpers.getLayoutPath(self, fp) catch null;
            defer if (layout_path) |path| self.allocator.free(path);
            self.frontend_client.updatePaneAux(
                fp.uuid,
                self.activeTabIndex(),
                fp.floating,
                false,
                .float,
                null,
                null,
                .{ .x = cursor.x, .y = cursor.y },
                cursor_style,
                cursor_visible,
                alt_screen,
                .{ .cols = fp.width, .rows = fp.height },
                null,
                null,
                null,
                layout_path,
            ) catch |err| {
                core.logging.logError("mux", "failed IPC operation in state_sync", err);
            };
        }
    }
}

pub fn syncPaneFocus(self: anytype, pane: *Pane, focused_from: ?[32]u8) void {
    setLayoutFocusedSplitId(self, pane);
    if (pane.floating) {
        rememberFloatingFocus(self, pane);
        self.setActiveFloatingUuid(pane.uuid);
    } else {
        rememberSplitFocus(self, pane);
        self.setActiveFloatingIndex(null);
    }
    self.setFocusedPaneUuid(pane.uuid);

    if (!self.frontend_client.isConnected()) return;
    if (pane.uuid[0] == 0) return;

    self.unfocusAllPanes();

    pane.focused = true;
    const pane_type: FrontendClient.PaneType = if (pane.floating) .float else .split;
    const cursor = pane.getCursorPos();
    const cursor_style = pane.vt.getCursorStyle();
    const cursor_visible = pane.vt.isCursorVisible();
    const alt_screen = pane.vt.inAltScreen();
    const layout_path = helpers.getLayoutPath(self, pane) catch null;
    defer if (layout_path) |path| self.allocator.free(path);
    self.frontend_client.updatePaneAux(
        pane.uuid,
        self.activeTabIndex(),
        pane.floating,
        true,
        pane_type,
        null,
        focused_from,
        .{ .x = cursor.x, .y = cursor.y },
        cursor_style,
        cursor_visible,
        alt_screen,
        .{ .cols = pane.width, .rows = pane.height },
        pane.getRealCwd(),
        pane.getFgProcess(),
        pane.getFgPid(),
        layout_path,
    ) catch |err| {
        core.logging.logError("mux", "failed IPC operation in state_sync", err);
    };

    if (self.config._lua_runtime) |rt| {
        rt.lua.createTable(0, 8);
        _ = rt.lua.pushString("pane_focus_changed");
        rt.lua.setField(-2, "event");
        _ = rt.lua.pushString(pane.uuid[0..]);
        rt.lua.setField(-2, "pane_uuid");
        if (focused_from) |prev| {
            _ = rt.lua.pushString(prev[0..]);
            rt.lua.setField(-2, "previous_pane_uuid");
        }
        _ = rt.lua.pushString(if (pane.floating) "float" else "split");
        rt.lua.setField(-2, "pane_type");
        rt.lua.pushInteger(@intCast(self.activeTabIndex() + 1));
        rt.lua.setField(-2, "active_tab");
        rt.lua.pushInteger(@intCast(std.time.milliTimestamp()));
        rt.lua.setField(-2, "now_ms");
        lua_events.emitAutocmdWithPayloadOnStack(rt, "pane_focus_changed");
    }
}

pub fn syncPaneUnfocus(self: anytype, pane: *Pane) void {
    if (self.focusedPaneUuid()) |uuid| {
        if (std.mem.eql(u8, &uuid, &pane.uuid)) {
            self.setFocusedPaneUuid(null);
        }
    }
    if (pane.floating) {
        if (self.activeFloatingIndex()) |idx| {
            if (idx < self.view.floats.items.len and self.view.floats.items[idx] == pane) {
                self.setActiveFloatingIndex(null);
            }
        }
    }

    if (!self.frontend_client.isConnected()) return;
    if (pane.uuid[0] == 0) return;

    const pane_type: FrontendClient.PaneType = if (pane.floating) .float else .split;
    const cursor = pane.getCursorPos();
    const cursor_style = pane.vt.getCursorStyle();
    const cursor_visible = pane.vt.isCursorVisible();
    const alt_screen = pane.vt.inAltScreen();
    const layout_path = helpers.getLayoutPath(self, pane) catch null;
    defer if (layout_path) |path| self.allocator.free(path);
    self.frontend_client.updatePaneAux(
        pane.uuid,
        self.activeTabIndex(),
        pane.floating,
        false,
        pane_type,
        null,
        null,
        .{ .x = cursor.x, .y = cursor.y },
        cursor_style,
        cursor_visible,
        alt_screen,
        .{ .cols = pane.width, .rows = pane.height },
        pane.getRealCwd(),
        pane.getFgProcess(),
        pane.getFgPid(),
        layout_path,
    ) catch |err| {
        core.logging.logError("mux", "failed IPC operation in state_sync", err);
    };
}

pub fn refreshPaneCwd(self: anytype, pane: *Pane) ?[]const u8 {
    // Fire-and-forget: response updates pane CWD via handleSesMessage.
    self.frontend_client.requestPaneCwd(pane.uuid);
    return pane.getRealCwd();
}

pub fn getSpawnCwd(_: anytype, pane: *Pane) ?[]const u8 {
    // Use cached CWD (async requests keep it updated).
    return pane.getRealCwd();
}

/// Get CWD for spawning a new pane, trying multiple sources.
/// This is more robust than refreshPaneCwd alone since it tries fallbacks.
/// Returns null only if ALL sources fail.
pub fn getReliableCwd(self: anytype, pane: *Pane) ?[]const u8 {
    // 1. Try synchronous CWD fetch from SES (authoritative /proc read).
    if (self.frontend_client.getPaneCwdSync(pane.uuid)) |cwd| {
        return cwd;
    }

    // 2. Try refreshPaneCwd (VT OSC7 / /proc / ses_cwd cache)
    if (self.refreshPaneCwd(pane)) |cwd| {
        return cwd;
    }

    // 3. Try shell integration CWD (updated by shell hooks)
    if (self.getPaneShell(pane.uuid)) |shell_info| {
        if (shell_info.cwd) |cwd| {
            return cwd;
        }
    }

    // 4. All sources failed - return null, let caller provide fallback
    return null;
}

pub fn syncFocusedPaneInfo(self: anytype) void {
    if (!self.frontend_client.isConnected()) return;

    const pane = if (self.activeFloatingIndex()) |idx| blk: {
        if (idx < self.view.floats.items.len) break :blk self.view.floats.items[idx];
        break :blk @as(?*Pane, null);
    } else self.currentLayout().getFocusedPane();

    if (pane == null) return;
    const p = pane.?;
    if (p.uuid[0] == 0) return;

    // Ensure pane metadata eventually converges even if an async response was
    // missed during reconnect/startup races.
    if (!self.hasPaneName(p.uuid)) {
        self.frontend_client.requestPaneProcess(p.uuid);
    }
    if (p.getRealCwd() == null) {
        self.frontend_client.requestPaneCwd(p.uuid);
    }

    _ = self.refreshPaneCwd(p);

    // Best-effort process detection.
    // SES owns process inspection; request a refresh and use any cached value we
    // already have for immediate consumers.
    const fg_proc_local = p.getFgProcess();
    const fg_pid_local: ?i32 = if (p.getFgPid()) |pid| @intCast(pid) else null;
    if (fg_proc_local) |proc_name| {
        self.setPaneProc(p.uuid, proc_name, fg_pid_local);
    } else {
        self.frontend_client.requestPaneProcess(p.uuid);
    }

    const pane_type: FrontendClient.PaneType = if (p.floating) .float else .split;
    const cursor = p.getCursorPos();
    const cursor_style = p.vt.getCursorStyle();
    const cursor_visible = p.vt.isCursorVisible();
    const alt_screen = p.vt.inAltScreen();
    const layout_path = helpers.getLayoutPath(self, p) catch null;
    defer if (layout_path) |path| self.allocator.free(path);
    self.frontend_client.updatePaneAux(
        p.uuid,
        self.activeTabIndex(),
        p.floating,
        true,
        pane_type,
        null,
        null,
        .{ .x = cursor.x, .y = cursor.y },
        cursor_style,
        cursor_visible,
        alt_screen,
        .{ .cols = p.width, .rows = p.height },
        p.getRealCwd(),
        fg_proc_local,
        if (p.getFgPid()) |pid| pid else null,
        layout_path,
    ) catch |err| {
        core.logging.logError("mux", "failed IPC operation in state_sync", err);
    };
}

pub fn resizeFloatingPanes(self: anytype) void {
    const avail_h = self.term_height - self.status_height;

    for (self.view.floats.items) |pane| {
        const shadow_enabled = if (pane.float_style) |s| s.shadow_color != null else false;
        const usable_w: u16 = if (shadow_enabled) (self.term_width -| 1) else self.term_width;
        const usable_h: u16 = if (shadow_enabled and self.status_height == 0) (avail_h -| 1) else avail_h;

        const outer_w: u16 = usable_w * pane.float_width_pct / 100;
        const outer_h: u16 = usable_h * pane.float_height_pct / 100;

        const max_x = usable_w -| outer_w;
        const max_y = usable_h -| outer_h;
        const outer_x: u16 = max_x * pane.float_pos_x_pct / 100;
        const outer_y: u16 = max_y * pane.float_pos_y_pct / 100;

        const pad_x: u16 = 1 + pane.float_pad_x;
        const pad_y: u16 = 1 + pane.float_pad_y;
        const content_x = outer_x + pad_x;
        const content_y = outer_y + pad_y;
        const content_w = outer_w -| (pad_x * 2);
        const content_h = outer_h -| (pad_y * 2);

        pane.resize(content_x, content_y, content_w, content_h) catch {};

        pane.border_x = outer_x;
        pane.border_y = outer_y;
        pane.border_w = outer_w;
        pane.border_h = outer_h;
    }
}
