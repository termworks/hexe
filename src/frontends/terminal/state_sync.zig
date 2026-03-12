const std = @import("std");
const posix = std.posix;
const core = @import("core");

const FrontendRuntime = core.FrontendRuntime;
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

fn setLayoutFocusedSplitId(self: anytype, pane: *Pane) void {
    if (self.paneIsFloating(pane)) return;

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
    if (!self.paneIsFloating(pane)) return;
    self.rememberFloatingFocus(pane);
}

fn rememberSplitFocus(self: anytype, pane: *Pane) void {
    if (self.paneIsFloating(pane)) return;
    self.rememberSplitFocus();
}

pub fn syncSessionTabAdded(self: anytype, tab_uuid: [32]u8, name: []const u8, pane_uuid: [32]u8) void {
    if (!self.runtime.isConnected()) return;
    self.runtime.sessionAddTab(tab_uuid, pane_uuid, self.activeTabIndex(), name) catch |err| {
        core.logging.logError("terminal", "failed sessionAddTab IPC", err);
    };
}

pub fn syncSessionTabRemoved(self: anytype, tab_uuid: [32]u8) void {
    if (!self.runtime.isConnected()) return;
    const active_tab: ?usize = if (self.view.tabs.items.len > 0) self.activeTabIndex() else null;
    self.runtime.sessionRemoveTab(tab_uuid, active_tab) catch |err| {
        core.logging.logError("terminal", "failed sessionRemoveTab IPC", err);
    };
}

pub fn syncSessionFloat(self: anytype, pane: *Pane, active: bool) void {
    if (!self.runtime.isConnected()) return;
    if (pane.uuid[0] == 0) return;

    self.runtime.sessionSyncFloat(
        pane.uuid,
        self.activeTabIndex(),
        self.paneParentTab(pane),
        if (self.paneFloatState(pane)) |float_state| float_state.visible else true,
        if (self.paneFloatState(pane)) |float_state| float_state.tab_visible else 0,
        self.paneSticky(pane),
        self.paneIsPwd(pane),
        self.paneFloatKey(pane),
        self.paneFloatWidthPct(pane),
        self.paneFloatHeightPct(pane),
        self.paneFloatPosXPct(pane),
        self.paneFloatPosYPct(pane),
        self.paneFloatPadX(pane),
        self.paneFloatPadY(pane),
        active,
    ) catch |err| {
        core.logging.logError("terminal", "failed sessionSyncFloat IPC", err);
    };
}

pub fn syncSessionFloatRemoved(self: anytype, pane_uuid: [32]u8) void {
    if (!self.runtime.isConnected()) return;
    if (pane_uuid[0] == 0) return;
    self.runtime.sessionRemoveFloat(pane_uuid) catch |err| {
        core.logging.logError("terminal", "failed sessionRemoveFloat IPC", err);
    };
}

pub fn syncActiveTabLayout(self: anytype) void {
    if (!self.runtime.isConnected()) return;
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

    self.runtime.sessionSyncTabLayout(
        tab_uuid,
        self.activeTabIndex(),
        if (tab.layout.getFocusedPane()) |pane| pane.uuid else null,
        root_json,
    ) catch |err| {
        core.logging.logError("terminal", "failed sessionSyncTabLayout IPC", err);
    };
}

pub fn syncSessionSplitPane(
    self: anytype,
    source_pane_uuid: [32]u8,
    new_pane_uuid: [32]u8,
    dir: layout_mod.SplitDir,
    focused_pane_uuid: ?[32]u8,
) void {
    if (!self.runtime.isConnected()) return;
    const tab_uuid = self.tabUuid(self.activeTabIndex()) orelse return;
    self.runtime.sessionSplitPane(
        tab_uuid,
        source_pane_uuid,
        new_pane_uuid,
        self.activeTabIndex(),
        focused_pane_uuid,
        switch (dir) {
            .horizontal => .horizontal,
            .vertical => .vertical,
        },
    ) catch |err| {
        core.logging.logError("terminal", "failed sessionSplitPane IPC", err);
    };
}

pub fn syncSessionCloseSplitPane(
    self: anytype,
    pane_uuid: [32]u8,
    focused_pane_uuid: ?[32]u8,
) void {
    if (!self.runtime.isConnected()) return;
    const tab_uuid = self.tabUuid(self.activeTabIndex()) orelse return;
    self.runtime.sessionCloseSplitPane(
        tab_uuid,
        pane_uuid,
        self.activeTabIndex(),
        focused_pane_uuid,
    ) catch |err| {
        core.logging.logError("terminal", "failed sessionCloseSplitPane IPC", err);
    };
}

pub fn syncSessionReplaceSplitPane(
    self: anytype,
    old_pane_uuid: [32]u8,
    new_pane_uuid: [32]u8,
    focused_pane_uuid: ?[32]u8,
) void {
    if (!self.runtime.isConnected()) return;
    const tab_uuid = self.tabUuid(self.activeTabIndex()) orelse return;
    self.runtime.sessionReplaceSplitPane(
        tab_uuid,
        old_pane_uuid,
        new_pane_uuid,
        self.activeTabIndex(),
        focused_pane_uuid,
    ) catch |err| {
        core.logging.logError("terminal", "failed sessionReplaceSplitPane IPC", err);
    };
}

pub fn syncSessionSplitRatio(
    self: anytype,
    first_anchor_uuid: [32]u8,
    second_anchor_uuid: [32]u8,
    ratio: f32,
) void {
    if (!self.runtime.isConnected()) return;
    const tab_uuid = self.tabUuid(self.activeTabIndex()) orelse return;
    self.runtime.sessionSetSplitRatio(
        tab_uuid,
        self.activeTabIndex(),
        first_anchor_uuid,
        second_anchor_uuid,
        ratio,
    ) catch |err| {
        core.logging.logError("terminal", "failed sessionSetSplitRatio IPC", err);
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
    if (!self.runtime.isConnected()) return;
    if (pane.uuid[0] == 0) return;

    if (pane.focused) {
        setLayoutFocusedSplitId(self, pane);
        if (self.paneIsFloating(pane)) {
            rememberFloatingFocus(self, pane);
            self.setActiveFloatingUuid(pane.uuid);
        } else {
            rememberSplitFocus(self, pane);
            self.setActiveFloatingIndex(null);
        }
        self.setFocusedPaneUuid(pane.uuid);
        self.unfocusAllPanes();
        pane.focused = true;
    }

    const pane_type: FrontendRuntime.PaneType = if (self.paneIsFloating(pane)) .float else .split;
    const cursor = pane.getCursorPos();
    const cursor_style = pane.vt.getCursorStyle();
    const cursor_visible = pane.vt.isCursorVisible();
    const alt_screen = pane.vt.inAltScreen();
    const layout_path = helpers.getLayoutPath(self, pane) catch null;
    defer if (layout_path) |path| self.allocator.free(path);
    const focused_from = if (pane.focused) created_from else null;
    self.runtime.updatePaneAux(
        pane.uuid,
        self.activeTabIndex(),
        self.paneIsFloating(pane),
        self.paneIsFocused(pane),
        pane_type,
        created_from,
        focused_from,
        .{ .x = cursor.x, .y = cursor.y },
        cursor_style,
        cursor_visible,
        alt_screen,
        .{ .cols = pane.width, .rows = pane.height },
        self.paneRealCwd(pane),
        pane.getFgProcess(),
        pane.getFgPid(),
        layout_path,
    ) catch |err| {
        core.logging.logError("terminal", "failed IPC operation in state_sync", err);
    };
}

pub fn unfocusAllPanes(self: anytype) void {
    if (!self.runtime.isConnected()) return;

    for (self.view.tabs.items) |*tab| {
        var pane_it = tab.layout.splitIterator();
        while (pane_it.next()) |p| {
            if (p.*.uuid[0] != 0) {
                p.*.focused = false;
                const pane_type: FrontendRuntime.PaneType = if (self.paneIsFloating(p.*)) .float else .split;
                const cursor = p.*.getCursorPos();
                const cursor_style = p.*.vt.getCursorStyle();
                const cursor_visible = p.*.vt.isCursorVisible();
                const alt_screen = p.*.vt.inAltScreen();
                const layout_path = helpers.getLayoutPath(self, p.*) catch null;
                defer if (layout_path) |path| self.allocator.free(path);
                self.runtime.updatePaneAux(
                    p.*.uuid,
                    self.activeTabIndex(),
                    self.paneIsFloating(p.*),
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
                    core.logging.logError("terminal", "failed IPC operation in state_sync", err);
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
            self.runtime.updatePaneAux(
                fp.uuid,
                self.activeTabIndex(),
                self.paneIsFloating(fp),
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
                core.logging.logError("terminal", "failed IPC operation in state_sync", err);
            };
        }
    }
}

pub fn syncPaneFocus(self: anytype, pane: *Pane, focused_from: ?[32]u8) void {
    setLayoutFocusedSplitId(self, pane);
    if (self.paneIsFloating(pane)) {
        rememberFloatingFocus(self, pane);
        self.setActiveFloatingUuid(pane.uuid);
    } else {
        rememberSplitFocus(self, pane);
        self.setActiveFloatingIndex(null);
    }
    self.setFocusedPaneUuid(pane.uuid);

    if (!self.runtime.isConnected()) return;
    if (pane.uuid[0] == 0) return;

    self.unfocusAllPanes();

    pane.focused = true;
    const pane_type: FrontendRuntime.PaneType = if (self.paneIsFloating(pane)) .float else .split;
    const cursor = pane.getCursorPos();
    const cursor_style = pane.vt.getCursorStyle();
    const cursor_visible = pane.vt.isCursorVisible();
    const alt_screen = pane.vt.inAltScreen();
    const layout_path = helpers.getLayoutPath(self, pane) catch null;
    defer if (layout_path) |path| self.allocator.free(path);
    self.runtime.updatePaneAux(
        pane.uuid,
        self.activeTabIndex(),
        self.paneIsFloating(pane),
        true,
        pane_type,
        null,
        focused_from,
        .{ .x = cursor.x, .y = cursor.y },
        cursor_style,
        cursor_visible,
        alt_screen,
        .{ .cols = pane.width, .rows = pane.height },
        self.paneRealCwd(pane),
        pane.getFgProcess(),
        pane.getFgPid(),
        layout_path,
    ) catch |err| {
        core.logging.logError("terminal", "failed IPC operation in state_sync", err);
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
        _ = rt.lua.pushString(if (self.paneIsFloating(pane)) "float" else "split");
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
    if (self.paneIsFloating(pane)) {
        if (self.activeFloatingIndex()) |idx| {
            if (idx < self.view.floats.items.len and self.view.floats.items[idx] == pane) {
                self.setActiveFloatingIndex(null);
            }
        }
    }

    if (!self.runtime.isConnected()) return;
    if (pane.uuid[0] == 0) return;

    const pane_type: FrontendRuntime.PaneType = if (self.paneIsFloating(pane)) .float else .split;
    const cursor = pane.getCursorPos();
    const cursor_style = pane.vt.getCursorStyle();
    const cursor_visible = pane.vt.isCursorVisible();
    const alt_screen = pane.vt.inAltScreen();
    const layout_path = helpers.getLayoutPath(self, pane) catch null;
    defer if (layout_path) |path| self.allocator.free(path);
    self.runtime.updatePaneAux(
        pane.uuid,
        self.activeTabIndex(),
        self.paneIsFloating(pane),
        false,
        pane_type,
        null,
        null,
        .{ .x = cursor.x, .y = cursor.y },
        cursor_style,
        cursor_visible,
        alt_screen,
        .{ .cols = pane.width, .rows = pane.height },
        self.paneRealCwd(pane),
        pane.getFgProcess(),
        pane.getFgPid(),
        layout_path,
    ) catch |err| {
        core.logging.logError("terminal", "failed IPC operation in state_sync", err);
    };
}

pub fn refreshPaneCwd(self: anytype, pane: *Pane) ?[]const u8 {
    // Fire-and-forget: response updates projection CWD metadata via handleSesMessage.
    self.runtime.requestPaneCwd(pane.uuid);
    return self.paneRealCwd(pane);
}

pub fn getSpawnCwd(self: anytype, pane: *Pane) ?[]const u8 {
    // Use cached CWD (async requests keep it updated).
    return self.paneRealCwd(pane);
}

/// Get CWD for spawning a new pane, trying multiple sources.
/// This is more robust than refreshPaneCwd alone since it tries fallbacks.
/// Returns null only if ALL sources fail.
pub fn getReliableCwd(self: anytype, pane: *Pane) ?[]const u8 {
    // 1. Try synchronous CWD fetch from SES (authoritative /proc read).
    if (self.runtime.getPaneCwdSync(pane.uuid)) |cwd| {
        return cwd;
    }

    // 2. Try refreshPaneCwd (VT OSC7 / /proc / projection shell cwd cache)
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
    if (!self.runtime.isConnected()) return;

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
        self.runtime.requestPaneProcess(p.uuid);
    }
    if (self.paneRealCwd(p) == null) {
        self.runtime.requestPaneCwd(p.uuid);
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
        self.runtime.requestPaneProcess(p.uuid);
    }

    const pane_type: FrontendRuntime.PaneType = if (self.paneIsFloating(p)) .float else .split;
    const cursor = p.getCursorPos();
    const cursor_style = p.vt.getCursorStyle();
    const cursor_visible = p.vt.isCursorVisible();
    const alt_screen = p.vt.inAltScreen();
    const layout_path = helpers.getLayoutPath(self, p) catch null;
    defer if (layout_path) |path| self.allocator.free(path);
    self.runtime.updatePaneAux(
        p.uuid,
        self.activeTabIndex(),
        self.paneIsFloating(p),
        true,
        pane_type,
        null,
        null,
        .{ .x = cursor.x, .y = cursor.y },
        cursor_style,
        cursor_visible,
        alt_screen,
        .{ .cols = p.width, .rows = p.height },
        self.paneRealCwd(p),
        fg_proc_local,
        if (p.getFgPid()) |pid| pid else null,
        layout_path,
    ) catch |err| {
        core.logging.logError("terminal", "failed IPC operation in state_sync", err);
    };
}

pub fn resizeFloatingPanes(self: anytype) void {
    const avail_h = self.term_height - self.status_height;

    for (self.view.floats.items) |pane| {
        const shadow_enabled = if (pane.float_style) |s| s.shadow_color != null else false;
        const usable_w: u16 = if (shadow_enabled) (self.term_width -| 1) else self.term_width;
        const usable_h: u16 = if (shadow_enabled and self.status_height == 0) (avail_h -| 1) else avail_h;

        const outer_w: u16 = usable_w * self.paneFloatWidthPct(pane) / 100;
        const outer_h: u16 = usable_h * self.paneFloatHeightPct(pane) / 100;

        const max_x = usable_w -| outer_w;
        const max_y = usable_h -| outer_h;
        const outer_x: u16 = max_x * self.paneFloatPosXPct(pane) / 100;
        const outer_y: u16 = max_y * self.paneFloatPosYPct(pane) / 100;

        const pad_x: u16 = 1 + self.paneFloatPadX(pane);
        const pad_y: u16 = 1 + self.paneFloatPadY(pane);
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
