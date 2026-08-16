const std = @import("std");
const posix = std.posix;
const core = @import("core");
const frontend_core = @import("frontend_core");

const FrontendRuntime = core.FrontendRuntime;
const Pane = @import("pane.zig").Pane;
const helpers = @import("helpers.zig");
const layout_mod = @import("layout.zig");
const lua_events = @import("lua_events.zig");

fn setLayoutFocusedPaneUuid(self: anytype, pane: *Pane) void {
    if (self.paneIsFloating(pane)) return;

    // Find which tab/layout owns this pane pointer and set its focused pane UUID
    // to match. This keeps per-tab focus stable when switching tabs.
    for (self.view.tab_views.items) |*tab| {
        var it = tab.layout.splits.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == pane) {
                tab.layout.focused_pane_uuid = entry.key_ptr.*;
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

fn getLayoutPathForSync(self: anytype, pane: *Pane, comptime context: []const u8) ?[]const u8 {
    return helpers.getLayoutPath(self, pane) catch |err| {
        core.logging.logError("terminal", context ++ ": failed to resolve layout path", err);
        return null;
    };
}

pub fn syncSessionSplitRatio(
    self: anytype,
    first_anchor_uuid: [32]u8,
    second_anchor_uuid: [32]u8,
    ratio: f32,
) void {
    if (!self.runtime.isConnected()) {
        self.applyFrontendSplitRatio(first_anchor_uuid, second_anchor_uuid, ratio);
        return;
    }
    const tab_uuid = self.runtime.tabUuid(self.activeTabIndex()) orelse {
        core.logging.warn("terminal", "session split ratio sync skipped: active tab has no session UUID", .{});
        return;
    };
    self.runtime.sessionSetSplitRatio(
        tab_uuid,
        self.activeTabIndex(),
        first_anchor_uuid,
        second_anchor_uuid,
        ratio,
    ) catch |err| {
        core.logging.logError("terminal", "failed sessionSetSplitRatio IPC", err);
        return;
    };
    self.applyFrontendSplitRatio(first_anchor_uuid, second_anchor_uuid, ratio);
}

pub fn getCurrentFocusedUuid(self: anytype) ?[32]u8 {
    if (self.runtime.focusedPaneUuid()) |uuid| {
        if (self.findPaneByUuid(uuid) != null) return uuid;
    }
    if (self.activeFloatingIndex()) |idx| {
        if (idx < self.view.float_views.items.len) {
            return self.view.float_views.items[idx].uuid;
        }
    }
    if (self.view.tab_views.items.len == 0) return null;
    if (self.currentLayout().getFocusedPane()) |pane| {
        return pane.uuid;
    }
    return null;
}

pub fn syncPaneAux(self: anytype, pane: *Pane, created_from: ?[32]u8) void {
    if (!self.runtime.isConnected()) return;
    if (pane.uuid[0] == 0) return;

    if (pane.focused) {
        setLayoutFocusedPaneUuid(self, pane);
        if (self.paneIsFloating(pane)) {
            rememberFloatingFocus(self, pane);
            self.setActiveFloatingUuid(pane.uuid);
        } else {
            rememberSplitFocus(self, pane);
            self.setActiveFloatingIndex(null);
        }
        self.runtime.setFocusedPaneUuid(pane.uuid);
        self.unfocusAllPanes();
        pane.focused = true;
    }

    const pane_type: FrontendRuntime.PaneType = if (self.paneIsFloating(pane)) .float else .split;
    const cursor = pane.getCursorPos();
    const cursor_style = pane.vt.getCursorStyle();
    const cursor_visible = pane.vt.isCursorVisible();
    const alt_screen = pane.vt.inAltScreen();
    const layout_path = getLayoutPathForSync(self, pane, "syncPaneAux");
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

    for (self.view.tab_views.items) |*tab| {
        var pane_it = tab.layout.splitIterator();
        while (pane_it.next()) |p| {
            if (p.*.uuid[0] != 0) {
                p.*.focused = false;
                const pane_type: FrontendRuntime.PaneType = if (self.paneIsFloating(p.*)) .float else .split;
                const cursor = p.*.getCursorPos();
                const cursor_style = p.*.vt.getCursorStyle();
                const cursor_visible = p.*.vt.isCursorVisible();
                const alt_screen = p.*.vt.inAltScreen();
                const layout_path = getLayoutPathForSync(self, p.*, "unfocusAllPanes split");
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

    for (self.view.float_views.items) |fp| {
        if (fp.uuid[0] != 0) {
            fp.focused = false;
            const cursor = fp.getCursorPos();
            const cursor_style = fp.vt.getCursorStyle();
            const cursor_visible = fp.vt.isCursorVisible();
            const alt_screen = fp.vt.inAltScreen();
            const layout_path = getLayoutPathForSync(self, fp, "unfocusAllPanes float");
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
    setLayoutFocusedPaneUuid(self, pane);
    if (self.paneIsFloating(pane)) {
        rememberFloatingFocus(self, pane);
        self.setActiveFloatingUuid(pane.uuid);
    } else {
        rememberSplitFocus(self, pane);
        self.setActiveFloatingIndex(null);
    }
    self.runtime.setFocusedPaneUuid(pane.uuid);
    if (self.frontend_view) |*view| {
        _ = frontend_core.applyViewActionWithContext(view, .focus_set, .{
            .focus_target_uuid = pane.uuid,
        }) catch |err| {
            core.logging.logError("terminal", "failed to mirror focused pane into shared frontend view", err);
        };
        if (!self.paneIsFloating(pane)) {
            _ = frontend_core.applyViewActionWithContext(view, .tab_focus_set, .{
                .focus_tab_idx = self.activeTabIndex(),
                .focus_target_uuid = pane.uuid,
            }) catch |err| {
                core.logging.logError("terminal", "failed to mirror tab focused pane into shared frontend view", err);
            };
        }
    }

    if (!self.runtime.isConnected()) return;
    if (pane.uuid[0] == 0) return;

    self.unfocusAllPanes();

    pane.focused = true;
    const pane_type: FrontendRuntime.PaneType = if (self.paneIsFloating(pane)) .float else .split;
    const cursor = pane.getCursorPos();
    const cursor_style = pane.vt.getCursorStyle();
    const cursor_visible = pane.vt.isCursorVisible();
    const alt_screen = pane.vt.inAltScreen();
    const layout_path = getLayoutPathForSync(self, pane, "syncPaneFocus");
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

    if (focused_from) |prev| self.prev_focused_pane_uuid = prev;

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
        lua_events.emitWithState(self, rt, "pane_focus_changed");
    }
}

pub fn syncPaneUnfocus(self: anytype, pane: *Pane) void {
    if (self.runtime.focusedPaneUuid()) |uuid| {
        if (std.mem.eql(u8, &uuid, &pane.uuid)) {
            self.runtime.setFocusedPaneUuid(null);
            if (self.frontend_view) |*view| {
                _ = frontend_core.applyViewActionWithContext(view, .focus_set, .{
                    .clear_focus = true,
                }) catch |err| {
                    core.logging.logError("terminal", "failed to clear shared frontend focused pane", err);
                };
            }
        }
    }
    if (self.paneIsFloating(pane)) {
        if (self.activeFloatingIndex()) |idx| {
            if (idx < self.view.float_views.items.len and self.view.float_views.items[idx] == pane) {
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
    const layout_path = getLayoutPathForSync(self, pane, "syncPaneUnfocus");
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

    const pane = if (getCurrentFocusedUuid(self)) |uuid|
        self.findPaneByUuid(uuid)
    else
        null;

    if (pane == null) return;
    const p = pane.?;
    if (self.paneIsFloating(p)) {
        self.setActiveFloatingUuid(p.uuid);
    }
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
    const layout_path = getLayoutPathForSync(self, p, "syncFocusedPaneInfo");
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
    for (self.view.float_views.items) |pane| {
        const frame = self.floatFrameForPane(pane);
        pane.resize(frame.content_x, frame.content_y, frame.content_w, frame.content_h) catch |err| {
            core.logging.logError("terminal", "failed to resize synced float pane", err);
        };

        self.setPaneBorderFrame(pane.uuid, frame.outer_x, frame.outer_y, frame.outer_w, frame.outer_h, self.paneBorderColor(pane));
    }
}
