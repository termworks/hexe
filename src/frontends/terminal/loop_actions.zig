const std = @import("std");
const posix = std.posix;
const core = @import("core");
const vaxis = @import("vaxis");
const wire = core.wire;
const terminal_main = @import("main.zig");

const layout_mod = @import("layout.zig");
const SplitDir = layout_mod.SplitDir;

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;
const FrontendRuntime = core.FrontendRuntime;

const helpers = @import("helpers.zig");
const float_completion = @import("float_completion.zig");
const loop_actions_focus = @import("loop_actions_focus.zig");
const loop_watchers = @import("loop_watchers.zig");

const FLOAT_REVEAL_VT_CATCHUP_FRAMES: usize = 8192;

fn writeControlLogged(fd: posix.fd_t, msg_type: wire.MsgType, payload: []const u8, comptime context: []const u8) void {
    wire.writeControl(fd, msg_type, payload) catch |err| {
        core.logging.logError("terminal", context, err);
    };
}

/// Hide or destroy a float. If it's a CLI-blocking float (capture_output=true),
/// destroy it and send result back to CLI instead of just hiding.
pub fn hideOrDestroyFloat(state: *State, pane: *Pane, tab: usize) void {
    if (state.paneCaptureOutput(pane)) {
        // CLI is waiting - destroy the float and send cancellation result.
        destroyBlockingFloat(state, pane);
    } else {
        // Normal float - just hide it.
        const was_visible = state.paneVisibleOnTab(pane, tab);
        state.setPaneVisibleOnTab(pane, tab, false);
        if (!state.syncSessionFloatChecked(pane, false)) {
            // Sticky/per-CWD floats may be visible in more than one mux/session,
            // but SES only allows the current live owner to update the canonical
            // snapshot. A non-owner hide is still a valid local UI action, so do
            // not undo it or warn the user with a scary false failure.
            if (state.paneSticky(pane) or state.paneIsPwd(pane)) {
                terminal_main.debugLogUuid(
                    &pane.uuid,
                    "hideOrDestroyFloat: session sync rejected for shared sticky/per-CWD float; kept local hide",
                    .{},
                );
                return;
            }
            state.setPaneVisibleOnTab(pane, tab, was_visible);
            state.notifications.show("Hide float failed: session sync rejected update");
        }
    }
}

/// Destroy a blocking float and send result back to CLI.
fn destroyBlockingFloat(state: *State, pane: *Pane) void {
    // Send completion with exit code 130 (like Ctrl+C cancellation).
    if (state.pending_float_requests.fetchRemove(pane.uuid)) |entry| {
        if (entry.value.result_path) |path| {
            std.fs.cwd().deleteFile(path) catch |err| {
                if (err != error.FileNotFound) {
                    terminal_main.debugLog("destroyBlockingFloat: failed to delete result file '{s}': {s}", .{ path, @errorName(err) });
                }
            };
            state.allocator.free(path);
        }
        // Send cancellation result to CLI.
        const ctl_fd = state.runtime.getCtlFd() orelse {
            core.logging.warn("terminal", "destroyBlockingFloat: cannot send cancellation result because SES CTL channel is unavailable", .{});
            return;
        };
        const result = wire.FloatResult{
            .uuid = pane.uuid,
            .exit_code = 130, // Cancelled (like SIGINT)
            .output_len = 0,
        };
        writeControlLogged(ctl_fd, .float_result, std.mem.asBytes(&result), "failed to send cancelled float result");
    }

    // Find and remove the float from state.view.float_views.
    for (state.view.float_views.items, 0..) |p, i| {
        if (p == pane) {
            if (state.runtime.isConnected()) {
                state.runtime.killPane(pane.uuid) catch |e| {
                    terminal_main.debugLogUuid(&pane.uuid, "destroyBlockingFloat: killPane failed: {s}", .{@errorName(e)});
                    state.notifications.show("Close float failed: session rejected pane kill");
                    return;
                };
            }
            const closing_uuid = pane.uuid;
            _ = state.view.float_views.orderedRemove(i);
            state.clearLocalFloatState(pane.uuid);
            state.clearTransientPaneState(pane);
            state.clearFloatUi(pane.uuid);
            pane.deinit();
            state.allocator.destroy(pane);
            // Active-float tracking is uuid-based and self-adjusts across
            // removals; only clear it when the removed float was the active
            // one. Index-shifting here re-pointed it at the wrong float.
            if (state.runtime.activeFloatUuid()) |active_uuid| {
                if (std.mem.eql(u8, &active_uuid, &closing_uuid)) {
                    state.setActiveFloatingUuid(null);
                }
            }
            state.applyFrontendPaneRemoved(closing_uuid, null);
            // Ensure proper re-render with cursor restoration.
            state.needs_render = true;
            state.force_full_render = true;
            state.renderer.invalidate();
            break;
        }
    }
}

fn escapeForShell(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.append(allocator, '\'');
    for (value) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, ch);
        }
    }
    try out.append(allocator, '\'');

    return out.toOwnedSlice(allocator);
}

fn mergeEnvLines(allocator: std.mem.Allocator, env: ?[]const []const u8, extra: ?[]const []const u8) !?[]const []const u8 {
    const env_len = if (env) |v| v.len else 0;
    const extra_len = if (extra) |v| v.len else 0;
    if (env_len + extra_len == 0) return null;
    const out = try allocator.alloc([]const u8, env_len + extra_len);
    var i: usize = 0;
    if (env) |v| {
        for (v) |item| {
            out[i] = item;
            i += 1;
        }
    }
    if (extra) |v| {
        for (v) |item| {
            out[i] = item;
            i += 1;
        }
    }
    return out;
}

fn appendEnvExport(list: *std.ArrayList(u8), allocator: std.mem.Allocator, line: []const u8) !void {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return;
    if (eq == 0) return;
    const key = line[0..eq];
    if (!isValidEnvKey(key)) return;
    const value = line[eq + 1 ..];

    const escaped = try escapeForShell(allocator, value);
    defer allocator.free(escaped);

    try list.appendSlice(allocator, "export ");
    try list.appendSlice(allocator, key);
    try list.appendSlice(allocator, "=");
    try list.appendSlice(allocator, escaped);
    try list.appendSlice(allocator, "; ");
}

fn shouldSkipEnvSyncKey(key: []const u8) bool {
    if (std.mem.eql(u8, key, "PWD")) return true;
    if (std.mem.eql(u8, key, "OLDPWD")) return true;
    if (std.mem.eql(u8, key, "SHLVL")) return true;
    if (std.mem.eql(u8, key, "_")) return true;
    if (std.mem.eql(u8, key, "HEXE_PANE_UUID")) return true;
    if (std.mem.eql(u8, key, "HEXE_POD_SOCKET")) return true;
    if (std.mem.eql(u8, key, "HEXE_POD_NAME")) return true;
    if (std.mem.eql(u8, key, "HEXE_MUX_SOCKET")) return true;
    if (std.mem.eql(u8, key, "TERM")) return true;
    if (std.mem.eql(u8, key, "BOX")) return true;
    return false;
}

fn freeEnvLines(allocator: std.mem.Allocator, lines: []const []const u8) void {
    for (lines) |line| allocator.free(line);
    allocator.free(lines);
}

fn parseNulSeparatedEnv(allocator: std.mem.Allocator, data: []const u8) !?[]const []const u8 {
    if (data.len == 0) return null;

    var count: usize = 0;
    for (data) |b| {
        if (b == 0) count += 1;
    }
    if (data[data.len - 1] != 0) count += 1;

    var entries = try allocator.alloc([]const u8, count);
    errdefer allocator.free(entries);

    var idx: usize = 0;
    errdefer {
        for (entries[0..idx]) |line| allocator.free(line);
    }
    var start: usize = 0;
    for (data, 0..) |b, i| {
        if (b != 0) continue;
        if (i > start) {
            entries[idx] = try allocator.dupe(u8, data[start..i]);
            idx += 1;
        }
        start = i + 1;
    }

    if (start < data.len) {
        entries[idx] = try allocator.dupe(u8, data[start..]);
        idx += 1;
    }

    if (idx == 0) {
        allocator.free(entries);
        return null;
    }

    if (idx < count) {
        entries = try allocator.realloc(entries, idx);
    }
    return entries;
}

fn readPaneEnvSnapshot(allocator: std.mem.Allocator, uuid: [32]u8) !?[]const []const u8 {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/hexe-env-{s}", .{&uuid});
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        if (err != error.FileNotFound) {
            core.logging.logError("terminal", "failed to open pane env snapshot", err);
        }
        return null;
    };
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 256 * 1024);
    defer allocator.free(data);

    return parseNulSeparatedEnv(allocator, data);
}

fn readProcEnvironByPid(allocator: std.mem.Allocator, pid: i32) !?[]const []const u8 {
    if (pid <= 0) return null;

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/environ", .{pid});
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        if (err != error.FileNotFound) {
            core.logging.logError("terminal", "failed to open process environ", err);
        }
        return null;
    };
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 256 * 1024);
    defer allocator.free(data);

    return parseNulSeparatedEnv(allocator, data);
}

fn syncEnvIntoExistingFloat(state: *State, pane: *Pane, parent_uuid: [32]u8) void {
    var parent_env: ?[]const []const u8 = null;
    if (state.runtime.getPaneInfoSnapshot(parent_uuid)) |info| {
        defer {
            if (info.name) |s| state.allocator.free(s);
            if (info.cwd) |s| state.allocator.free(s);
            if (info.sticky_pwd) |s| state.allocator.free(s);
            if (info.fg_name) |s| state.allocator.free(s);
        }
        if (info.fg_pid) |pid| {
            parent_env = readProcEnvironByPid(state.allocator, pid) catch |err| blk: {
                core.logging.logError("terminal", "failed to read parent process environment for float sync", err);
                break :blk null;
            };
        }
    }

    if (parent_env == null) {
        parent_env = readPaneEnvSnapshot(state.allocator, parent_uuid) catch |err| blk: {
            core.logging.logError("terminal", "failed to read pane environment snapshot for float sync", err);
            break :blk null;
        };
    }
    if (parent_env == null) return;
    defer freeEnvLines(state.allocator, parent_env.?);

    var cmd: std.ArrayList(u8) = .empty;
    defer cmd.deinit(state.allocator);

    for (parent_env.?) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (eq == 0) continue;
        const key = line[0..eq];
        if (shouldSkipEnvSyncKey(key)) continue;
        appendEnvExport(&cmd, state.allocator, line) catch |err| {
            core.logging.logError("terminal", "failed to build pane environment sync command", err);
            state.notifications.show("Environment sync failed");
            state.needs_render = true;
            return;
        };
    }

    if (cmd.items.len == 0) return;
    cmd.append(state.allocator, '\n') catch |err| {
        core.logging.logError("terminal", "failed to finish pane environment sync command", err);
        state.notifications.show("Environment sync failed");
        state.needs_render = true;
        return;
    };
    pane.write(cmd.items) catch |err| {
        terminal_main.debugLogUuid(&pane.uuid, "syncPaneEnvFromParent write failed: {s}", .{@errorName(err)});
    };
}

fn paneExistsInSes(state: *State, uuid: [32]u8) bool {
    if (!state.runtime.isConnected()) return true;
    const probe = state.runtime.probePaneExistence(uuid);
    switch (probe.outcome) {
        // Only a definitive pane_not_found reply from SES may report false:
        // callers destroy the local float view and spawn a replacement on
        // false, so a transient IPC failure must never be read as "gone".
        .missing => return false,
        .unknown => return true,
        .exists => {},
    }
    if (probe.pid) |pid| {
        if (!isProcessAlive(pid)) return false;
    }
    return true;
}

fn isProcessAlive(pid: i32) bool {
    if (pid <= 0) return false;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch |err| {
        core.logging.logError("terminal", "failed to format process stat path", err);
        return false;
    };
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        if (err != error.FileNotFound) {
            core.logging.logError("terminal", "failed to open process stat", err);
        }
        return false;
    };
    defer file.close();

    // A zombie keeps its /proc entry but the process is gone (same rule as
    // SES's sticky-pane liveness check): reading it as alive makes a float
    // toggle reuse a dying pane instead of respawning. The state char is the
    // first non-space byte after the last ')' in the stat line.
    var buf: [512]u8 = undefined;
    const n = file.read(&buf) catch return true;
    const data = buf[0..n];
    const close_paren = std.mem.lastIndexOfScalar(u8, data, ')') orelse return true;
    var i = close_paren + 1;
    while (i < data.len and data[i] == ' ') i += 1;
    if (i < data.len and (data[i] == 'Z' or data[i] == 'X')) return false;
    return true;
}

fn isValidEnvKey(key: []const u8) bool {
    if (key.len == 0) return false;
    const first = key[0];
    if (!((first >= 'A' and first <= 'Z') or (first >= 'a' and first <= 'z') or first == '_')) return false;
    for (key[1..]) |ch| {
        if (!((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '_')) return false;
    }
    return true;
}

fn getCurrentFocusedPane(state: *State) ?*Pane {
    if (state.activeFloatingIndex()) |idx| {
        if (idx < state.view.float_views.items.len) return state.view.float_views.items[idx];
    }
    return state.currentLayout().getFocusedPane();
}

/// Perform the actual detach action.
pub fn performDetach(state: *State) void {
    const session_uuid = state.runtime.sessionUuid();
    state.runtime.detachCurrentSession() catch {
        std.debug.print("\nDetach failed - panes orphaned\n", .{});
        state.running = false;
        return;
    };
    state.runtime.requestExplicitDetachStop();
    // Print session_id (our UUID) so user can reattach.
    std.debug.print("\nSession detached: {s}\nReattach with: hexe terminal attach {s}\n", .{ session_uuid, session_uuid[0..8] });
}

/// Perform the actual disown action - orphan pane in ses and spawn new shell in same place.
pub fn performDisown(state: *State) void {
    const pane: ?*Pane = if (state.activeFloatingIndex()) |idx|
        state.view.float_views.items[idx]
    else
        state.currentLayout().getFocusedPane();

    if (pane) |p| {
        const old_uuid = p.uuid;

        // Get current working directory from the process before orphaning.
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        var cwd = state.getReliableCwd(p);
        if (cwd == null) {
            cwd = std.posix.getcwd(&cwd_buf) catch |err| blk: {
                core.logging.logError("terminal", "performDisown: failed to get fallback cwd", err);
                break :blk null;
            };
        }

        // Get the old pane's auxiliary info (created_from, focused_from) to inherit.
        const old_aux = state.runtime.getPaneAux(p.uuid) catch FrontendRuntime.PaneAuxInfo{
            .created_from = null,
            .focused_from = null,
        };

        // Create a new shell via ses in the same directory and replace the pane's backend.
        if (state.runtime.createPane(null, cwd, null, null, null, null, null)) |result| {
            const vt_fd = state.runtime.getVtFd() orelse {
                state.runtime.killPane(result.uuid) catch |e| {
                    terminal_main.debugLogUuid(&result.uuid, "performDisown: rollback killPane failed after missing VT fd: {s}", .{@errorName(e)});
                };
                state.notifications.show("Disown failed: no VT channel");
                state.needs_render = true;
                return;
            };
            const active_float = state.paneIsFloating(p);
            if (!state.replacePaneWithPodSynced(
                old_uuid,
                result.uuid,
                result.pane_id,
                vt_fd,
                p,
                active_float,
                .kill_new_pane,
                "performDisown: rollback killPane failed after replacement error",
            )) {
                state.notifications.show("Disown failed: couldn't replace pane");
                state.needs_render = true;
                return;
            }

            state.runtime.orphanPane(old_uuid) catch |e| {
                terminal_main.debugLogUuid(&old_uuid, "performDisown: orphanPane failed after replacement: {s}", .{@errorName(e)});
            };

            // Sync inherited auxiliary info to the new pane.
            const pane_type: FrontendRuntime.PaneType = if (state.paneIsFloating(p)) .float else .split;
            const cursor = p.getCursorPos();
            const cursor_style = p.vt.getCursorStyle();
            const cursor_visible = p.vt.isCursorVisible();
            const alt_screen = p.vt.inAltScreen();
            const layout_path = helpers.getLayoutPath(state, p) catch |err| blk: {
                core.logging.logError("terminal", "performDisown: failed to resolve layout path", err);
                break :blk null;
            };
            defer if (layout_path) |path| state.allocator.free(path);
            state.runtime.updatePaneAux(
                p.uuid,
                state.activeTabIndex(),
                state.paneIsFloating(p),
                state.paneIsFocused(p),
                pane_type,
                old_aux.created_from, // Inherit creator.
                old_aux.focused_from, // Inherit last focus.
                .{ .x = cursor.x, .y = cursor.y },
                cursor_style,
                cursor_visible,
                alt_screen,
                .{ .cols = p.width, .rows = p.height },
                cwd,
                null,
                null,
                layout_path,
            ) catch |err| {
                core.logging.logError("terminal", "disown replacement metadata sync failed", err);
                state.notifications.show("Disown metadata sync failed");
            };

            state.notifications.show("Pane disowned (adopt with Alt+a)");
        } else |_| {
            state.notifications.show("Disown failed: couldn't create new pane");
        }
    }
    state.needs_render = true;
}

/// Perform the actual close action - close current float or tab.
pub fn performClose(state: *State) void {
    if (state.activeFloatingIndex()) |idx| {
        const old_uuid = state.getCurrentFocusedUuid();
        const pane = state.view.float_views.items[idx];
        const closing_uuid = pane.uuid;
        terminal_main.debugLogUuid(&pane.uuid, "performClose: float pane_id={?d} vt_fd={?d}", .{
            pane.getPaneId(),
            state.runtime.currentVtFd(),
        });
        if (state.runtime.isConnected()) {
            terminal_main.debugLogUuid(&pane.uuid, "performClose: sending killPane to SES", .{});
            state.runtime.killPane(pane.uuid) catch |e| {
                terminal_main.debugLogUuid(&pane.uuid, "performClose: killPane error: {s}", .{@errorName(e)});
                // Two expected refusal shapes, both resolved by local-only
                // cleanup: the pane is already gone in SES (pod teardown won
                // the race), or SES refused because another live client owns
                // it now (this view is stale after a float steal). Aborting
                // here would leave a permanently unclosable dead float.
                if (paneExistsInSes(state, pane.uuid)) {
                    terminal_main.debugLogUuid(&pane.uuid, "performClose: SES refused kill (owned elsewhere), dropping local view", .{});
                    state.notifications.show("Float is owned by another session; closed locally");
                } else {
                    terminal_main.debugLogUuid(&pane.uuid, "performClose: pane already gone in SES, cleaning up locally", .{});
                }
            };
            terminal_main.debugLogUuid(&pane.uuid, "performClose: killPane done", .{});
        }
        _ = state.view.float_views.orderedRemove(idx);
        state.syncPaneUnfocus(pane);
        float_completion.handleBlockingFloatCompletion(state, pane);
        state.clearLocalFloatState(pane.uuid);
        state.clearTransientPaneState(pane);
        state.clearFloatUi(pane.uuid);
        pane.deinit();
        state.allocator.destroy(pane);
        // Focus another float or fall back to tiled pane.
        var next_focus_uuid: ?[32]u8 = null;
        if (state.view.float_views.items.len > 0) {
            state.setActiveFloatingIndex(0);
            const next_pane = state.view.float_views.items[0];
            next_focus_uuid = next_pane.uuid;
            state.syncPaneFocus(next_pane, old_uuid);
        } else {
            state.setActiveFloatingIndex(null);
            if (state.currentLayout().getFocusedPane()) |tiled| {
                next_focus_uuid = tiled.uuid;
                state.syncPaneFocus(tiled, old_uuid);
            }
        }
        state.applyFrontendPaneRemoved(closing_uuid, next_focus_uuid);
        // Force full render to restore cursor state properly.
        state.force_full_render = true;
        state.renderer.invalidate();
    } else {
        // Close current tab, or quit if it's the last one.
        if (!state.closeCurrentTab()) {
            state.running = false;
        }
    }
    state.needs_render = true;
}

/// Start the adopt orphaned pane flow.
pub fn startAdoptFlow(state: *State) void {
    if (!state.runtime.isConnected()) {
        state.notifications.show("Not connected to ses");
        return;
    }

    // Get list of orphaned panes.
    const count = state.runtime.refreshOrphanedPanes() catch {
        state.notifications.show("Failed to list orphaned panes");
        return;
    };

    if (count == 0) {
        state.notifications.show("No orphaned panes");
        return;
    }

    if (count == 1) {
        // Only one orphan - skip picker, go directly to confirm.
        const orphan = state.runtime.orphanedPaneInfo(0) orelse {
            state.notifications.show("Failed to read orphaned pane");
            return;
        };
        state.runtime.setSelectedOrphanedPaneUuid(orphan.uuid);
        if (!state.showConfirmOrNotify(.adopt_confirm, "Destroy current pane?")) {
            state.runtime.setSelectedOrphanedPaneUuid(null);
        }
    } else {
        // Multiple orphans - show picker.
        // Build items list for picker (owned by popup).
        var items_list: std.ArrayList([]const u8) = .empty;
        defer items_list.deinit(state.allocator);
        for (0..count) |i| {
            const orphan = state.runtime.orphanedPaneInfo(i) orelse {
                state.notifications.show("Failed to read orphaned pane");
                return;
            };
            const item = if (orphan.name_len > 0)
                std.fmt.allocPrint(state.allocator, "{s} [{s}]", .{ orphan.nameSlice(), orphan.uuid[0..8] }) catch {
                    state.notifications.show("Failed to show picker");
                    return;
                }
            else
                std.fmt.allocPrint(state.allocator, "{s}", .{orphan.uuid[0..8]}) catch {
                    state.notifications.show("Failed to show picker");
                    return;
                };
            errdefer state.allocator.free(item);
            items_list.append(state.allocator, item) catch {
                state.allocator.free(item);
                state.notifications.show("Failed to show picker");
                return;
            };
        }
        _ = state.showPickerOrNotify(.adopt_choose, items_list.items, "Select pane to adopt");
        for (items_list.items) |item| state.allocator.free(item);
    }
    state.needs_render = true;
}

/// Perform the actual adopt action.
/// If destroy_current is true, kills the current pane; otherwise orphans it (swap).
pub fn performAdopt(state: *State, orphan_uuid: [32]u8, destroy_current: bool) void {
    // Resolve all local prerequisites before asking SES to attach the orphan.
    // Once adopted, the pane is no longer listed as orphaned, so failing after
    // that point can otherwise leave it attached to this client without a view.
    const pane: *Pane = if (state.activeFloatingIndex()) |idx|
        state.view.float_views.items[idx]
    else
        state.currentLayout().getFocusedPane() orelse {
            state.notifications.show("No focused pane");
            return;
        };

    const vt_fd = state.runtime.getVtFd() orelse {
        state.notifications.show("Failed to replace pane: no VT channel");
        return;
    };

    const result = state.runtime.adoptPane(orphan_uuid) catch {
        state.notifications.show("Failed to adopt pane");
        return;
    };

    const old_uuid = pane.uuid;
    const active_float = state.paneIsFloating(pane);
    if (!state.replacePaneWithPodSynced(
        old_uuid,
        result.uuid,
        result.pane_id,
        vt_fd,
        pane,
        active_float,
        .orphan_new_pane,
        "performAdopt: rollback orphanPane failed after replacement error",
    )) {
        state.notifications.show("Failed to replace pane");
        return;
    }

    state.syncPaneAux(pane, null);

    if (destroy_current) {
        state.runtime.killPane(old_uuid) catch |e| {
            terminal_main.debugLogUuid(&old_uuid, "performAdopt: killPane failed after replace: {s}", .{@errorName(e)});
        };
        state.notifications.show("Adopted pane (old destroyed)");
    } else {
        state.runtime.orphanPane(old_uuid) catch |e| {
            terminal_main.debugLogUuid(&old_uuid, "performAdopt: orphanPane failed after replace: {s}", .{@errorName(e)});
        };
        state.notifications.show("Swapped panes (old pane orphaned)");
    }

    state.renderer.invalidate();
    state.force_full_render = true;
    state.needs_render = true;
}

/// Apply the `exclusive` attribute: hide every float whose key differs from the
/// just-shown float's key. Must be called on *every* path that shows an
/// exclusive float — including the per-CWD/sticky handoff paths that go through
/// createNamedFloat — otherwise re-showing a hidden exclusive float leaves the
/// other floats visible.
fn applyFloatExclusivity(state: *State, float_def: *const core.LayoutFloatDef) void {
    if (!float_def.attributes.exclusive) return;

    var to_hide: std.ArrayList([32]u8) = .empty;
    defer to_hide.deinit(state.allocator);

    for (state.view.float_views.items) |other| {
        if (state.paneFloatKey(other) != float_def.key) {
            to_hide.append(state.allocator, other.uuid) catch |err| {
                terminal_main.debugLogUuid(&other.uuid, "applyFloatExclusivity: failed to queue exclusive float hide: {s}", .{@errorName(err)});
                state.notifications.show("Float exclusivity incomplete: couldn't queue hide");
            };
        }
    }

    for (to_hide.items) |target_uuid| {
        for (state.view.float_views.items) |candidate| {
            if (std.mem.eql(u8, &candidate.uuid, &target_uuid)) {
                hideOrDestroyFloat(state, candidate, state.activeTabIndex());
                break;
            }
        }
    }
}

fn catchUpVtBeforeFloatReveal(state: *State) void {
    loop_watchers.drainSesVtAvailable(
        state,
        FLOAT_REVEAL_VT_CATCHUP_FRAMES,
        "float reveal VT catch-up",
    );
}

fn revealExistingFloatLocally(state: *State, pane: *Pane, existing_idx: usize, float_def: *const core.LayoutFloatDef, old_uuid: ?[32]u8) bool {
    state.setPaneVisibleOnTab(pane, state.activeTabIndex(), true);

    if (state.activeFloatingIndex()) |afi| {
        if (afi < state.view.float_views.items.len and afi != existing_idx) {
            state.syncPaneUnfocus(state.view.float_views.items[afi]);
        }
    } else if (state.currentLayout().getFocusedPane()) |tiled| {
        state.syncPaneUnfocus(tiled);
    }

    state.setActiveFloatingIndex(existing_idx);
    state.syncPaneFocus(pane, old_uuid);

    if (!state.syncSessionFloatChecked(pane, true)) {
        // The local pane is no longer owned by this mux. Leave the UI repair to
        // the caller's ownership-handoff path; importantly, do not keep trying
        // to reveal through session sync because SES will reject it.
        state.setPaneVisibleOnTab(pane, state.activeTabIndex(), false);
        state.setActiveFloatingIndex(null);
        return false;
    }

    catchUpVtBeforeFloatReveal(state);
    applyFloatExclusivity(state, float_def);
    state.renderer.invalidate();
    state.force_full_render = true;
    state.needs_render = true;
    return true;
}

pub fn toggleNamedFloat(state: *State, float_def: *const core.LayoutFloatDef) void {
    // Float/workspace toggles change the visible/focused pane surface just like
    // tab switches do. Any in-mux mouse selection is tied to the old pane
    // geometry/viewport and can render as a bogus long highlight after the
    // float is opened/hidden, so drop transient interaction state first.
    state.mouse_selection.clear();
    state.clearFloatRename();
    state.mouse_drag = .none;

    // Get current directory from ACTUALLY focused pane (float or split).
    // For per-CWD floats, an already-focused float carries the *origin* CWD
    // in its float UI state. Use that before asking the shell/process for CWD:
    // the float's shell may have cd'd elsewhere, but its sticky identity must
    // remain the directory that created/restored it.
    var current_dir: ?[]const u8 = null;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (getCurrentFocusedPane(state)) |focused| {
        // A per-CWD float's identity is the SES sticky_pwd captured when it was
        // created — not its shell's live cwd. Resolve it authoritatively first.
        // getReliableCwd is only correct as the *origin* cwd when launching a
        // fresh per-CWD float from a non per-CWD pane.
        if (float_def.attributes.per_cwd and state.paneIsPwd(focused)) {
            current_dir = state.stickyFloatDir(focused);
        }
        if (current_dir == null) {
            current_dir = state.getReliableCwd(focused);
        }
    }
    // Fallback to the terminal process CWD if pane CWD is unavailable.
    if (current_dir == null) {
        current_dir = std.posix.getcwd(&cwd_buf) catch |err| blk: {
            core.logging.logError("terminal", "toggleNamedFloat: failed to get fallback cwd", err);
            break :blk null;
        };
    }

    // per_cwd floats are unique per *split cwd*, not per tab.
    // So when toggling we only match an existing float if its stored cwd matches
    // the cwd of the currently focused split pane.

    // Find existing float by key (and directory if per_cwd).
    var existing_idx: usize = 0;
    while (existing_idx < state.view.float_views.items.len) {
        const pane = state.view.float_views.items[existing_idx];
        if (state.paneFloatKey(pane) == float_def.key) {
            // Only tab-bound floats use parent_tab filtering.
            // per_cwd/global floats are shared across tabs.
            if (!float_def.attributes.per_cwd and !float_def.attributes.global) {
                if (state.paneParentTab(pane)) |parent| {
                    if (parent != state.activeTabIndex()) {
                        existing_idx += 1;
                        continue;
                    }
                }
            }

            // For per_cwd floats, also check directory match.
            if (float_def.attributes.per_cwd and state.paneIsPwd(pane)) {
                // Both dirs must exist and match, or both be null. Identity is
                // the SES sticky_pwd, never the float shell's live cwd.
                const pane_dir_opt = state.stickyFloatDir(pane);
                const dirs_match = if (pane_dir_opt) |pane_dir| blk: {
                    if (current_dir) |curr| {
                        break :blk std.mem.eql(u8, pane_dir, curr);
                    }
                    break :blk false;
                } else current_dir == null;

                if (!dirs_match) {
                    existing_idx += 1;
                    continue;
                }
            }

            const was_visible_on_tab = state.paneVisibleOnTab(pane, state.activeTabIndex());
            const was_active = if (state.activeFloatingIndex()) |af| af == existing_idx else false;

            if ((state.paneSticky(pane) or state.paneIsPwd(pane)) and !was_visible_on_tab and !was_active) {
                // First try the cheap/local reveal. If this mux still owns the
                // pane, SES accepts session_sync_float and there is no need to
                // reconnect POD VT or replay the POD backlog.
                //
                // This matters for redraw-heavy TUIs (Codex is one): replaying
                // backlog into an already-live local VT duplicates the visible
                // scrollback. If SES rejects the sync, another mux owns the
                // shared pane and we fall through to the explicit handoff path.
                const old_uuid = state.getCurrentFocusedUuid();
                if (revealExistingFloatLocally(state, pane, existing_idx, float_def, old_uuid)) return;

                if (createNamedFloat(state, float_def, current_dir, old_uuid)) |_| {
                    catchUpVtBeforeFloatReveal(state);
                    applyFloatExclusivity(state, float_def);
                } else |err| {
                    terminal_main.debugLogUuid(
                        &pane.uuid,
                        "toggleNamedFloat: hidden shared float handoff failed: {s}",
                        .{@errorName(err)},
                    );
                    state.notifications.show("Float handoff failed");
                    state.needs_render = true;
                }
                return;
            }

            const missing_in_ses = !paneExistsInSes(state, pane.uuid);
            if (!pane.isAlive() or missing_in_ses) {
                const old_uuid = state.getCurrentFocusedUuid();
                if (was_active) {
                    state.syncPaneUnfocus(pane);
                }

                const stale = state.view.float_views.orderedRemove(existing_idx);
                const stale_uuid = stale.uuid;
                state.clearLocalFloatState(stale.uuid);
                state.clearTransientPaneState(stale);
                state.clearFloatUi(stale.uuid);
                stale.deinit();
                state.allocator.destroy(stale);

                // Active-float tracking is uuid-based; only clear it when the
                // stale float was active. Index-shifting re-pointed it at the
                // wrong float.
                if (state.runtime.activeFloatUuid()) |active_uuid| {
                    if (std.mem.eql(u8, &active_uuid, &stale_uuid)) {
                        state.setActiveFloatingUuid(null);
                    }
                }

                if (was_active) {
                    state.setActiveFloatingIndex(null);
                    state.cursor_needs_restore = true;
                    if (state.currentLayout().getFocusedPane()) |tiled| {
                        state.syncPaneFocus(tiled, old_uuid);
                    }
                }

                state.needs_render = true;
                state.force_full_render = true;
                state.renderer.invalidate();

                // The toggle key means "give me this tool": after clearing a
                // stale instance — visible or hidden — fall through so a fresh
                // float is created in the same keypress. Returning here made
                // "close app, toggle key, nothing happens" a routine
                // reliability complaint.
                continue;
            }

            // Toggle visibility (per-tab for global/per_cwd floats).
            const old_uuid = state.getCurrentFocusedUuid();
            state.togglePaneVisibleOnTab(pane, state.activeTabIndex());
            if (state.paneVisibleOnTab(pane, state.activeTabIndex())) {
                // Unfocus current pane (tiled or another float).
                if (state.activeFloatingIndex()) |afi| {
                    if (afi < state.view.float_views.items.len) {
                        state.syncPaneUnfocus(state.view.float_views.items[afi]);
                    }
                } else if (state.currentLayout().getFocusedPane()) |tiled| {
                    state.syncPaneUnfocus(tiled);
                }
                state.setActiveFloatingIndex(existing_idx);
                state.syncPaneFocus(pane, old_uuid);
                // If alone mode, hide all other floats on this tab.
                applyFloatExclusivity(state, float_def);
                catchUpVtBeforeFloatReveal(state);
            } else {
                // Float was hidden. If it had focus, return focus to tiled pane.
                if (state.activeFloatingIndex()) |afi| {
                    if (afi == existing_idx) {
                        state.syncPaneUnfocus(pane);
                        state.setActiveFloatingIndex(null);
                        if (state.currentLayout().getFocusedPane()) |tiled| {
                            state.syncPaneFocus(tiled, old_uuid);
                        }
                    }
                }
            }

            if (!state.syncSessionFloatChecked(pane, state.activeFloatingIndex() == existing_idx and state.paneVisibleOnTab(pane, state.activeTabIndex()))) {
                if (state.paneSticky(pane) or state.paneIsPwd(pane)) {
                    terminal_main.debugLogUuid(
                        &pane.uuid,
                        "toggleNamedFloat: shared sticky/per-CWD float sync rejected; attempting ownership handoff",
                        .{},
                    );
                    if (current_dir != null) {
                        if (createNamedFloat(state, float_def, current_dir, old_uuid)) |_| {
                            catchUpVtBeforeFloatReveal(state);
                            applyFloatExclusivity(state, float_def);
                        } else |err| {
                            terminal_main.debugLogUuid(
                                &pane.uuid,
                                "toggleNamedFloat: ownership handoff failed after sync rejection: {s}",
                                .{@errorName(err)},
                            );
                            state.notifications.show("Float handoff failed");
                            state.renderer.invalidate();
                            state.force_full_render = true;
                            state.needs_render = true;
                            return;
                        }
                        return;
                    }
                    state.renderer.invalidate();
                    state.force_full_render = true;
                    state.needs_render = true;
                    return;
                }
                state.notifications.show("Toggle float failed: session sync rejected update");
            }

            state.renderer.invalidate();
            state.force_full_render = true;
            state.needs_render = true;
            return;
        }
        existing_idx += 1;
    }

    // No existing float - create new.
    const old_uuid = state.getCurrentFocusedUuid();
    if (state.activeFloatingIndex()) |afi| {
        if (afi < state.view.float_views.items.len) {
            state.syncPaneUnfocus(state.view.float_views.items[afi]);
        }
    } else if (state.currentLayout().getFocusedPane()) |tiled| {
        state.syncPaneUnfocus(tiled);
    }

    createNamedFloat(state, float_def, current_dir, old_uuid) catch {
        state.notifications.show("Failed to create float");
        state.needs_render = true;
        return;
    };
    catchUpVtBeforeFloatReveal(state);

    // If alone mode, hide all other floats on this tab.
    applyFloatExclusivity(state, float_def);

    // For pwd floats, hide other instances of same float (different dirs) on this tab.
    if (float_def.attributes.per_cwd) {
        const new_idx = state.view.float_views.items.len - 1;
        var to_hide: std.ArrayList([32]u8) = .empty;
        defer to_hide.deinit(state.allocator);

        for (state.view.float_views.items, 0..) |pane, i| {
            if (i != new_idx and state.paneFloatKey(pane) == float_def.key) {
                to_hide.append(state.allocator, pane.uuid) catch |err| {
                    terminal_main.debugLogUuid(&pane.uuid, "toggleNamedFloat: failed to queue per-cwd float hide: {s}", .{@errorName(err)});
                    state.notifications.show("Per-directory float cleanup incomplete");
                };
            }
        }

        for (to_hide.items) |target_uuid| {
            for (state.view.float_views.items) |candidate| {
                if (std.mem.eql(u8, &candidate.uuid, &target_uuid)) {
                    hideOrDestroyFloat(state, candidate, state.activeTabIndex());
                    break;
                }
            }
        }
    }
}

pub const FloatSize = struct {
    width: u16 = 0, // 0 = use config default
    height: u16 = 0, // 0 = use config default
    shift_x: i16 = 0, // shift from center (-50 to 50)
    shift_y: i16 = 0, // shift from center (-50 to 50)
    exit_key: ?[]const u8 = null, // key that closes the float (e.g., "Esc")
};

fn rollbackCreatedFloat(state: *State, pane: *Pane) void {
    var idx: ?usize = null;
    for (state.view.float_views.items, 0..) |candidate, i| {
        if (candidate == pane) {
            idx = i;
            break;
        }
    }
    if (idx) |i| {
        _ = state.view.float_views.orderedRemove(i);
        // Active-float tracking is uuid-based; only clear it when the removed
        // float was the active one (index-shifting re-pointed it wrongly).
        if (state.runtime.activeFloatUuid()) |active_uuid| {
            if (std.mem.eql(u8, &active_uuid, &pane.uuid)) {
                state.setActiveFloatingUuid(null);
            }
        }
    }
    state.clearTransientPaneState(pane);
    state.clearFloatUi(pane.uuid);
    state.clearLocalFloatState(pane.uuid);
    pane.deinit();
}

pub fn createAdhocFloat(
    state: *State,
    command: []const u8,
    title: ?[]const u8,
    cwd: ?[]const u8,
    env: ?[]const []const u8,
    extra_env: ?[]const []const u8,
    use_pod: bool,
) ![32]u8 {
    return createAdhocFloatWithSize(state, command, title, cwd, env, extra_env, use_pod, .{});
}

pub fn createAdhocFloatWithSize(
    state: *State,
    command: []const u8,
    title: ?[]const u8,
    cwd: ?[]const u8,
    env: ?[]const []const u8,
    extra_env: ?[]const []const u8,
    use_pod: bool,
    size: FloatSize,
    isolation_profile: ?[]const u8,
) ![32]u8 {
    _ = use_pod;
    const pane = try state.allocator.create(Pane);
    errdefer state.allocator.destroy(pane);

    const visuals = state.resolveFloatVisuals(.adhoc, title);
    const style = visuals.float_style;
    const shadow_enabled = if (style) |s| s.shadow_color != null else false;
    const width_pct: u16 = if (size.width > 0) size.width else visuals.width_pct;
    const height_pct: u16 = if (size.height > 0) size.height else visuals.height_pct;
    // Base position at center (50%), then apply shift
    const pos_x_pct: u16 = @intCast(std.math.clamp(@as(i32, 50) + @as(i32, size.shift_x), 0, 100));
    const pos_y_pct: u16 = @intCast(std.math.clamp(@as(i32, 50) + @as(i32, size.shift_y), 0, 100));
    const pad_x_cfg: u16 = visuals.pad_x;
    const pad_y_cfg: u16 = visuals.pad_y;
    const border_color = visuals.border_color;

    const frame = state.floatFrameFromValues(width_pct, height_pct, pos_x_pct, pos_y_pct, pad_x_cfg, pad_y_cfg, shadow_enabled);
    const width_pct_u8: u8 = @intCast(@min(width_pct, 100));
    const height_pct_u8: u8 = @intCast(@min(height_pct, 100));
    const pos_x_pct_u8: u8 = @intCast(@min(pos_x_pct, 100));
    const pos_y_pct_u8: u8 = @intCast(@min(pos_y_pct, 100));

    const id: u16 = @intCast(100 + state.view.float_views.items.len);
    if (!state.runtime.isConnected()) return error.SesUnavailable;
    const merged_env = mergeEnvLines(state.allocator, env, extra_env) catch |err| {
        core.logging.logError("terminal", "failed to merge adhoc float environment", err);
        return err;
    };
    defer if (merged_env) |slice| state.allocator.free(slice);
    const result = try state.runtime.createPane(command, cwd, null, null, merged_env, isolation_profile, null);
    var pane_registered = false;
    errdefer if (!pane_registered) state.runtime.killPane(result.uuid) catch |e| {
        terminal_main.debugLogUuid(&result.uuid, "createAdhocFloat rollback killPane failed: {s}", .{@errorName(e)});
    };
    const vt_fd = state.runtime.getVtFd() orelse return error.SesUnavailable;
    try pane.initWithPod(state.allocator, id, frame.content_x, frame.content_y, frame.content_w, frame.content_h, result.pane_id, vt_fd, result.uuid);

    pane.focused = true;
    if (!state.setPaneFloatUi(result.uuid, .{
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
        .capture_output = false,
        .exit_key = size.exit_key,
        .float_style = style,
        .float_title = title,
    })) return error.OutOfMemory;

    pane.configureNotificationsFromPop(&state.pop_config.pane.notification);

    try state.view.float_views.append(state.allocator, pane);
    state.setActiveFloatingIndex(state.view.float_views.items.len - 1);
    state.setLocalFloatState(
        pane.uuid,
        state.activeTabIndex(),
        true,
        0,
        false,
        false,
        0,
        width_pct_u8,
        height_pct_u8,
        pos_x_pct_u8,
        pos_y_pct_u8,
        @intCast(pad_x_cfg),
        @intCast(pad_y_cfg),
        true,
    );
    state.syncPaneAux(pane, null);
    if (!state.syncSessionFloatChecked(pane, true)) {
        rollbackCreatedFloat(state, pane);
        return error.SesUnavailable;
    }
    pane_registered = true;

    return pane.uuid;
}

pub fn createNamedFloat(state: *State, float_def: *const core.LayoutFloatDef, current_dir: ?[]const u8, parent_uuid: ?[32]u8) !void {
    const pane = try state.allocator.create(Pane);
    errdefer state.allocator.destroy(pane);

    const visuals = state.resolveFloatVisuals(.named, float_def.title);
    const style = visuals.float_style;
    const shadow_enabled = if (style) |s| s.shadow_color != null else false;

    // Use per-float settings or fall back to defaults.
    const width_pct: u16 = float_def.width_percent orelse visuals.width_pct;
    const height_pct: u16 = float_def.height_percent orelse visuals.height_pct;
    const pos_x_pct: u16 = float_def.pos_x orelse 50; // default center
    const pos_y_pct: u16 = float_def.pos_y orelse 50; // default center
    const pad_x_cfg: u16 = visuals.pad_x;
    const pad_y_cfg: u16 = visuals.pad_y;
    const border_color = visuals.border_color;

    const frame = state.floatFrameFromValues(width_pct, height_pct, pos_x_pct, pos_y_pct, pad_x_cfg, pad_y_cfg, shadow_enabled);
    const width_pct_u8: u8 = @intCast(@min(width_pct, 100));
    const height_pct_u8: u8 = @intCast(@min(height_pct, 100));
    const pos_x_pct_u8: u8 = @intCast(@min(pos_x_pct, 100));
    const pos_y_pct_u8: u8 = @intCast(@min(pos_y_pct, 100));

    const id: u16 = @intCast(100 + state.view.float_views.items.len);

    // Extract isolation profile from float_def
    const isolation_profile: ?[]const u8 = if (float_def.isolation) |iso|
        if (iso.profile.len > 0) iso.profile else null
    else if (float_def.attributes.isolated)
        "default" // Use default profile when isolated=true and no profile is set
    else
        null;

    // Sticky metadata is what SES uses to decide sticky vs orphaned on disown.
    // For sticky/per_cwd floats, carry cwd+key into SES on creation. The two
    // fields must be set together: every SES park path and sticky lookup
    // requires both, so a key without a pwd (cwd resolution failed) would
    // create a float that is never parked and never findable — set neither.
    const sticky_pwd: ?[]const u8 = if ((float_def.attributes.sticky or float_def.attributes.per_cwd) and current_dir != null)
        current_dir.?
    else
        null;
    const sticky_key: ?u8 = if (sticky_pwd != null)
        float_def.key
    else
        null;
    // For global/per-CWD floats, visibility is per tab. Tab-bound floats use
    // their parent_tab and simple visible flag.
    const parent_tab: ?usize = if (!float_def.attributes.global and !float_def.attributes.per_cwd)
        state.activeTabIndex()
    else
        null;
    const active_tab_bit: u64 = if (state.activeTabIndex() < 64)
        (@as(u64, 1) << @intCast(state.activeTabIndex()))
    else
        0;
    const tab_visible: u64 = if (parent_tab == null) active_tab_bit else 0;

    if (!state.runtime.isConnected()) return error.SesUnavailable;
    const env_parent = if (float_def.attributes.inherit_env) parent_uuid else null;
    const NamedFloatPaneResult = struct {
        uuid: [32]u8,
        pane_id: u16,
        pid: posix.pid_t,
        reused: bool,
    };
    const result: NamedFloatPaneResult = blk: {
        if (sticky_pwd) |pwd| {
            if (sticky_key) |key| {
                // Explicit user-driven toggle: full claim semantics (steal from
                // a live owner / unpark from a detached session) are intended.
                if (state.runtime.findStickyPane(pwd, key, false)) |found_opt| {
                    if (found_opt) |found| {
                        terminal_main.debugLogUuid(&found.uuid, "createNamedFloat: reusing sticky/per-CWD pane before spawn", .{});
                        break :blk .{
                            .uuid = found.uuid,
                            .pane_id = found.pane_id,
                            .pid = found.pid,
                            .reused = true,
                        };
                    }
                } else |err| {
                    terminal_main.debugLog("createNamedFloat: sticky lookup failed before spawn: {s}", .{@errorName(err)});
                }
            }
        }
        const created = try state.runtime.createPane(float_def.command, current_dir, sticky_pwd, sticky_key, null, isolation_profile, env_parent);
        break :blk .{
            .uuid = created.uuid,
            .pane_id = created.pane_id,
            .pid = created.pid,
            .reused = false,
        };
    };
    var pane_registered = false;
    errdefer if (!pane_registered and !result.reused) state.runtime.killPane(result.uuid) catch |e| {
        terminal_main.debugLogUuid(&result.uuid, "createNamedFloat rollback killPane failed: {s}", .{@errorName(e)});
    };

    if (state.findPaneByUuid(result.uuid)) |existing| {
        // SES can return an already-attached sticky/per-CWD pane when the
        // frontend lost enough local pwd_dir metadata after reattach that the
        // normal pre-create lookup missed it, or when a shared float handoff
        // returns a pane this frontend still has locally.
        //
        // Reused sticky/per-CWD results cause SES/POD to replay backlog. Reset
        // the local VT before those replay frames are drained; otherwise the
        // replay is appended to the old VT and scrollback visibly duplicates.
        const vt_fd = state.runtime.getVtFd() orelse return error.SesUnavailable;
        existing.replaceWithPod(result.pane_id, vt_fd, result.uuid) catch |err| {
            terminal_main.debugLogUuid(&result.uuid, "createNamedFloat: failed to reset reused local pane for backlog replay: {s}", .{@errorName(err)});
            return error.SesUnavailable;
        };

        // Do not append a second Pane with the same UUID; repair the local
        // float state and focus the existing one.
        pane_registered = true;
        state.allocator.destroy(pane);

        const old_uuid = state.getCurrentFocusedUuid();
        if (state.activeFloatingIndex()) |afi| {
            if (afi < state.view.float_views.items.len and state.view.float_views.items[afi] != existing) {
                state.syncPaneUnfocus(state.view.float_views.items[afi]);
            }
        } else if (state.currentLayout().getFocusedPane()) |tiled| {
            if (tiled != existing) state.syncPaneUnfocus(tiled);
        }

        const next_tab_visible = if (parent_tab == null) blk: {
            const old_mask = if (state.paneFloatState(existing)) |float_state| float_state.tab_visible else 0;
            break :blk old_mask | active_tab_bit;
        } else 0;

        if (!state.setPaneFloatUi(result.uuid, .{
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
            .pwd_dir = if (float_def.attributes.per_cwd) current_dir else null,
            .navigatable = float_def.attributes.navigatable,
            .float_style = style,
            .float_title = float_def.title,
        })) return error.OutOfMemory;
        state.setLocalFloatState(
            result.uuid,
            parent_tab,
            true,
            next_tab_visible,
            float_def.attributes.sticky,
            float_def.attributes.per_cwd,
            float_def.key,
            width_pct_u8,
            height_pct_u8,
            pos_x_pct_u8,
            pos_y_pct_u8,
            @intCast(pad_x_cfg),
            @intCast(pad_y_cfg),
            true,
        );

        for (state.view.float_views.items, 0..) |candidate, idx| {
            if (candidate == existing or std.mem.eql(u8, &candidate.uuid, &result.uuid)) {
                state.setActiveFloatingIndex(idx);
                break;
            }
        }
        state.syncPaneFocus(existing, old_uuid);
        state.syncPaneAux(existing, parent_uuid);
        if (!state.syncSessionFloatChecked(existing, true)) {
            terminal_main.debugLogUuid(&result.uuid, "createNamedFloat reused sticky/per-CWD pane but session sync was rejected", .{});
        }
        state.renderer.invalidate();
        state.force_full_render = true;
        state.needs_render = true;
        return;
    }

    const vt_fd = state.runtime.getVtFd() orelse return error.SesUnavailable;
    try pane.initWithPod(state.allocator, id, frame.content_x, frame.content_y, frame.content_w, frame.content_h, result.pane_id, vt_fd, result.uuid);

    // Persist sticky affinity metadata for better reclaim preference.
    if (!result.reused) {
        if (sticky_pwd) |pwd| {
            if (sticky_key) |key| {
                state.runtime.setSticky(result.uuid, pwd, key) catch |err| {
                    terminal_main.debugLogUuid(&result.uuid, "createNamedFloat setSticky failed: {s}", .{@errorName(err)});
                    state.notifications.show("Sticky float sync failed");
                };
            }
        }
    }

    pane.focused = true;

    if (!state.setPaneFloatUi(result.uuid, .{
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
        .pwd_dir = if (float_def.attributes.per_cwd) current_dir else null,
        .navigatable = float_def.attributes.navigatable,
        .float_style = style,
        .float_title = float_def.title,
    })) return error.OutOfMemory;

    // Configure pane notifications.
    pane.configureNotificationsFromPop(&state.pop_config.pane.notification);

    try state.view.float_views.append(state.allocator, pane);
    state.setActiveFloatingIndex(state.view.float_views.items.len - 1);
    state.setLocalFloatState(
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
        true,
    );
    state.syncPaneAux(pane, parent_uuid);
    if (!state.syncSessionFloatChecked(pane, true)) {
        rollbackCreatedFloat(state, pane);
        return error.SesUnavailable;
    }
    pane_registered = true;
}

pub fn enterPaneSelectMode(state: *State, swap: bool) void {
    return loop_actions_focus.enterPaneSelectMode(state, swap);
}

pub fn focusPaneByUuid(state: *State, uuid: [32]u8) void {
    return loop_actions_focus.focusPaneByUuid(state, uuid);
}

pub fn handlePaneSelectEvent(state: *State, parsed_event: ?vaxis.Event) bool {
    return loop_actions_focus.handlePaneSelectEvent(state, parsed_event);
}

pub fn switchToNextTab(state: *State) void {
    return loop_actions_focus.switchToNextTab(state);
}

pub fn switchToPrevTab(state: *State) void {
    return loop_actions_focus.switchToPrevTab(state);
}
