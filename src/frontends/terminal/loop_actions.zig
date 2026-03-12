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

/// Hide or destroy a float. If it's a CLI-blocking float (capture_output=true),
/// destroy it and send result back to CLI instead of just hiding.
pub fn hideOrDestroyFloat(state: *State, pane: *Pane, tab: usize) void {
    if (pane.capture_output) {
        // CLI is waiting - destroy the float and send cancellation result.
        destroyBlockingFloat(state, pane);
    } else {
        // Normal float - just hide it.
        pane.setVisibleOnTab(tab, false);
        state.syncSessionFloat(pane, false);
    }
}

/// Destroy a blocking float and send result back to CLI.
fn destroyBlockingFloat(state: *State, pane: *Pane) void {
    // Send completion with exit code 130 (like Ctrl+C cancellation).
    if (state.pending_float_requests.fetchRemove(pane.uuid)) |entry| {
        if (entry.value.result_path) |path| {
            std.fs.cwd().deleteFile(path) catch {};
            state.allocator.free(path);
        }
        // Send cancellation result to CLI.
        const ctl_fd = state.runtime.getCtlFd() orelse return;
        const result = wire.FloatResult{
            .uuid = pane.uuid,
            .exit_code = 130, // Cancelled (like SIGINT)
            .output_len = 0,
        };
        wire.writeControl(ctl_fd, .float_result, std.mem.asBytes(&result)) catch {};
    }

    // Find and remove the float from state.view.floats.
    for (state.view.floats.items, 0..) |p, i| {
        if (p == pane) {
            _ = state.view.floats.orderedRemove(i);
            if (state.runtime.isConnected()) {
                state.runtime.killPane(pane.uuid) catch {};
            }
            state.syncSessionFloatRemoved(pane.uuid);
            pane.deinit();
            state.allocator.destroy(pane);
            // Fix active_floating index.
            if (state.activeFloatingIndex()) |afi| {
                if (afi == i) {
                    state.setActiveFloatingIndex(null);
                } else if (afi > i) {
                    state.setActiveFloatingIndex(afi - 1);
                }
            }
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
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 256 * 1024);
    defer allocator.free(data);

    return parseNulSeparatedEnv(allocator, data);
}

fn readProcEnvironByPid(allocator: std.mem.Allocator, pid: i32) !?[]const []const u8 {
    if (pid <= 0) return null;

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/environ", .{pid});
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
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
            if (info.fg_name) |s| state.allocator.free(s);
        }
        if (info.fg_pid) |pid| {
            parent_env = readProcEnvironByPid(state.allocator, pid) catch null;
        }
    }

    if (parent_env == null) {
        parent_env = readPaneEnvSnapshot(state.allocator, parent_uuid) catch null;
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
        appendEnvExport(&cmd, state.allocator, line) catch return;
    }

    if (cmd.items.len == 0) return;
    cmd.append(state.allocator, '\n') catch return;
    pane.write(cmd.items) catch {};
}

fn paneExistsInSes(state: *State, uuid: [32]u8) bool {
    if (!state.runtime.isConnected()) return true;
    if (state.runtime.getPaneInfoSnapshot(uuid)) |info| {
        defer {
            if (info.name) |s| state.allocator.free(s);
            if (info.cwd) |s| state.allocator.free(s);
            if (info.fg_name) |s| state.allocator.free(s);
        }
        if (info.pid) |pid| {
            if (!isProcessAlive(pid)) return false;
        }
        return true;
    }
    return false;
}

fn isProcessAlive(pid: i32) bool {
    if (pid <= 0) return false;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return false;
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
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
        if (idx < state.view.floats.items.len) return state.view.floats.items[idx];
    }
    return state.currentLayout().getFocusedPane();
}

/// Perform the actual detach action.
pub fn performDetach(state: *State) void {
    const session_uuid = state.sessionUuid();
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
        state.view.floats.items[idx]
    else
        state.currentLayout().getFocusedPane();

    if (pane) |p| {
        // Get current working directory from the process before orphaning.
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        var cwd = state.getReliableCwd(p);
        if (cwd == null) {
            cwd = std.posix.getcwd(&cwd_buf) catch null;
        }

        // Get the old pane's auxiliary info (created_from, focused_from) to inherit.
        const old_aux = state.runtime.getPaneAux(p.uuid) catch FrontendRuntime.PaneAuxInfo{
            .created_from = null,
            .focused_from = null,
        };

        // Orphan the current pane in ses (keeps process alive).
        state.runtime.orphanPane(p.uuid) catch {};

        // Create a new shell via ses in the same directory and replace the pane's backend.
        if (state.runtime.createPane(null, cwd, null, null, null, null, null)) |result| {
            const vt_fd = state.runtime.getVtFd() orelse {
                state.notifications.show("Disown failed: no VT channel");
                state.needs_render = true;
                return;
            };
            p.replaceWithPod(result.pane_id, vt_fd, result.uuid) catch {
                state.notifications.show("Disown failed: couldn't replace pane");
                state.needs_render = true;
                return;
            };

            // Sync inherited auxiliary info to the new pane.
            const pane_type: FrontendRuntime.PaneType = if (state.paneIsFloating(p)) .float else .split;
            const cursor = p.getCursorPos();
            const cursor_style = p.vt.getCursorStyle();
            const cursor_visible = p.vt.isCursorVisible();
            const alt_screen = p.vt.inAltScreen();
            const layout_path = helpers.getLayoutPath(state, p) catch null;
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
            ) catch {};

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
        const pane = state.view.floats.orderedRemove(idx);
        terminal_main.debugLogUuid(&pane.uuid, "performClose: float pane_id={?d} vt_fd={?d}", .{
            pane.getPaneId(),
            state.runtime.currentVtFd(),
        });
        state.syncPaneUnfocus(pane);
        float_completion.handleBlockingFloatCompletion(state, pane);
        // Kill in ses.
        if (state.runtime.isConnected()) {
            terminal_main.debugLogUuid(&pane.uuid, "performClose: sending killPane to SES", .{});
            state.runtime.killPane(pane.uuid) catch |e| {
                terminal_main.debugLogUuid(&pane.uuid, "performClose: killPane error: {s}", .{@errorName(e)});
            };
            terminal_main.debugLogUuid(&pane.uuid, "performClose: killPane done", .{});
        }
        state.syncSessionFloatRemoved(pane.uuid);
        pane.deinit();
        state.allocator.destroy(pane);
        // Focus another float or fall back to tiled pane.
        if (state.view.floats.items.len > 0) {
            state.setActiveFloatingIndex(0);
            state.syncPaneFocus(state.view.floats.items[0], old_uuid);
        } else {
            state.setActiveFloatingIndex(null);
            if (state.currentLayout().getFocusedPane()) |tiled| {
                state.syncPaneFocus(tiled, old_uuid);
            }
        }
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
        state.pending_action = .adopt_confirm;
        state.popups.showConfirm("Destroy current pane?", .{}) catch {};
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
            items_list.append(state.allocator, orphan.uuid[0..]) catch {
                state.notifications.show("Failed to show picker");
                return;
            };
        }
        state.pending_action = .adopt_choose;
        state.popups.showPickerOwned(items_list.items, .{ .title = "Select pane to adopt" }) catch {
            state.notifications.show("Failed to show picker");
            state.pending_action = null;
        };
    }
    state.needs_render = true;
}

/// Perform the actual adopt action.
/// If destroy_current is true, kills the current pane; otherwise orphans it (swap).
pub fn performAdopt(state: *State, orphan_uuid: [32]u8, destroy_current: bool) void {
    // Adopt the selected orphan from ses.
    const result = state.runtime.adoptPane(orphan_uuid) catch {
        state.notifications.show("Failed to adopt pane");
        return;
    };

    // Get the current focused pane.
    const current_pane: ?*Pane = if (state.activeFloatingIndex()) |idx|
        state.view.floats.items[idx]
    else
        state.currentLayout().getFocusedPane();

    if (current_pane) |pane| {
        const old_uuid = pane.uuid;
        if (destroy_current) {
            // Kill current pane in ses, then replace with adopted.
            state.runtime.killPane(pane.uuid) catch {};
        } else {
            // Orphan current pane (swap mode).
            state.runtime.orphanPane(pane.uuid) catch {};
            state.notifications.show("Swapped panes (old pane orphaned)");
        }

        const vt_fd = state.runtime.getVtFd() orelse {
            state.notifications.show("Failed to replace pane: no VT channel");
            return;
        };

        pane.replaceWithPod(result.pane_id, vt_fd, result.uuid) catch {
            state.notifications.show("Failed to replace pane");
            return;
        };

        if (state.paneIsFloating(pane)) {
            // Sync the new pane info.
            state.syncPaneAux(pane, null);
            state.syncSessionFloat(pane, state.activeFloatingIndex() != null);
        } else {
            state.syncSessionReplaceSplitPane(old_uuid, pane.uuid, if (pane.focused) pane.uuid else null);
            state.syncPaneAux(pane, null);
        }

        if (destroy_current) {
            state.notifications.show("Adopted pane (old destroyed)");
        }
    } else {
        state.notifications.show("No focused pane");
    }

    state.renderer.invalidate();
    state.force_full_render = true;
    state.needs_render = true;
}

pub fn toggleNamedFloat(state: *State, float_def: *const core.LayoutFloatDef) void {
    // Get current directory from ACTUALLY focused pane (float or split).
    // IMPORTANT: Use getCurrentFocusedPane() which checks active_floating first -
    // if user is focused on a float, we want THAT float's CWD for per_cwd floats.
    // Uses getReliableCwd which tries multiple sources, then falls back to the terminal process CWD.
    var current_dir: ?[]const u8 = null;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (getCurrentFocusedPane(state)) |focused| {
        current_dir = state.getReliableCwd(focused);
    }
    // Fallback to the terminal process CWD if pane CWD is unavailable.
    if (current_dir == null) {
        current_dir = std.posix.getcwd(&cwd_buf) catch null;
    }

    // per_cwd floats are unique per *split cwd*, not per tab.
    // So when toggling we only match an existing float if its stored cwd matches
    // the cwd of the currently focused split pane.

    // Find existing float by key (and directory if per_cwd).
    var existing_idx: usize = 0;
    while (existing_idx < state.view.floats.items.len) {
        const pane = state.view.floats.items[existing_idx];
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
                // Both dirs must exist and match, or both be null.
                const dirs_match = if (pane.pwd_dir) |pane_dir| blk: {
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

            const missing_in_ses = !paneExistsInSes(state, pane.uuid);
            if (!pane.isAlive() or missing_in_ses) {
                const was_visible_on_tab = state.paneVisibleOnTab(pane, state.activeTabIndex());
                const was_active = if (state.activeFloatingIndex()) |af| af == existing_idx else false;
                const old_uuid = state.getCurrentFocusedUuid();
                if (was_active) {
                    state.syncPaneUnfocus(pane);
                }

                const stale = state.view.floats.orderedRemove(existing_idx);
                state.syncSessionFloatRemoved(stale.uuid);
                stale.deinit();
                state.allocator.destroy(stale);

                if (state.activeFloatingIndex()) |af| {
                    if (af == existing_idx) {
                        state.setActiveFloatingIndex(null);
                    } else if (af > existing_idx) {
                        state.setActiveFloatingIndex(af - 1);
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

                // A visible stale float should clear on toggle; only hidden stale
                // instances fall through to immediate recreation.
                if (was_active or was_visible_on_tab) {
                    return;
                }
                continue;
            }

            // Toggle visibility (per-tab for global/per_cwd floats).
            const old_uuid = state.getCurrentFocusedUuid();
            pane.toggleVisibleOnTab(state.activeTabIndex());
            if (state.paneVisibleOnTab(pane, state.activeTabIndex())) {
                // Unfocus current pane (tiled or another float).
                if (state.activeFloatingIndex()) |afi| {
                    if (afi < state.view.floats.items.len) {
                        state.syncPaneUnfocus(state.view.floats.items[afi]);
                    }
                } else if (state.currentLayout().getFocusedPane()) |tiled| {
                    state.syncPaneUnfocus(tiled);
                }
                state.setActiveFloatingIndex(existing_idx);
                state.syncPaneFocus(pane, old_uuid);
                // If alone mode, hide all other floats on this tab.
                if (float_def.attributes.exclusive) {
                    var to_hide: std.ArrayList([32]u8) = .empty;
                    defer to_hide.deinit(state.allocator);

                    for (state.view.floats.items) |other| {
                        if (state.paneFloatKey(other) != float_def.key) {
                            to_hide.append(state.allocator, other.uuid) catch {};
                        }
                    }

                    for (to_hide.items) |target_uuid| {
                        for (state.view.floats.items) |candidate| {
                            if (std.mem.eql(u8, &candidate.uuid, &target_uuid)) {
                                hideOrDestroyFloat(state, candidate, state.activeTabIndex());
                                break;
                            }
                        }
                    }
                }
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

            state.syncSessionFloat(pane, state.activeFloatingIndex() == existing_idx and state.paneVisibleOnTab(pane, state.activeTabIndex()));

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
        if (afi < state.view.floats.items.len) {
            state.syncPaneUnfocus(state.view.floats.items[afi]);
        }
    } else if (state.currentLayout().getFocusedPane()) |tiled| {
        state.syncPaneUnfocus(tiled);
    }

    createNamedFloat(state, float_def, current_dir, old_uuid) catch {
        state.notifications.show("Failed to create float");
        state.needs_render = true;
        return;
    };

    // If alone mode, hide all other floats on this tab.
    if (float_def.attributes.exclusive) {
        var to_hide: std.ArrayList([32]u8) = .empty;
        defer to_hide.deinit(state.allocator);

        for (state.view.floats.items) |pane| {
            if (state.paneFloatKey(pane) != float_def.key) {
                to_hide.append(state.allocator, pane.uuid) catch {};
            }
        }

        for (to_hide.items) |target_uuid| {
            for (state.view.floats.items) |candidate| {
                if (std.mem.eql(u8, &candidate.uuid, &target_uuid)) {
                    hideOrDestroyFloat(state, candidate, state.activeTabIndex());
                    break;
                }
            }
        }
    }
    // For pwd floats, hide other instances of same float (different dirs) on this tab.
    if (float_def.attributes.per_cwd) {
        const new_idx = state.view.floats.items.len - 1;
        var to_hide: std.ArrayList([32]u8) = .empty;
        defer to_hide.deinit(state.allocator);

        for (state.view.floats.items, 0..) |pane, i| {
            if (i != new_idx and state.paneFloatKey(pane) == float_def.key) {
                to_hide.append(state.allocator, pane.uuid) catch {};
            }
        }

        for (to_hide.items) |target_uuid| {
            for (state.view.floats.items) |candidate| {
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
    dim_background: bool = false, // dim the background when this float is visible
    exit_key: ?[]const u8 = null, // key that closes the float (e.g., "Esc")
};

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

    const cfg = &state.config;
    const style = if (cfg.float_style_default) |*s| s else null;
    const shadow_enabled = if (style) |s| s.shadow_color != null else false;
    const width_pct: u16 = if (size.width > 0) size.width else cfg.float_width_percent;
    const height_pct: u16 = if (size.height > 0) size.height else cfg.float_height_percent;
    // Base position at center (50%), then apply shift
    const pos_x_pct: u16 = @intCast(@as(i32, 50) + @as(i32, size.shift_x));
    const pos_y_pct: u16 = @intCast(@as(i32, 50) + @as(i32, size.shift_y));
    const pad_x_cfg: u16 = cfg.float_padding_x;
    const pad_y_cfg: u16 = cfg.float_padding_y;
    const border_color = cfg.float_color;

    const avail_h = state.term_height - state.status_height;
    const usable_w: u16 = if (shadow_enabled) (state.term_width -| 1) else state.term_width;
    const usable_h: u16 = if (shadow_enabled and state.status_height == 0) (avail_h -| 1) else avail_h;
    const outer_w = usable_w * width_pct / 100;
    const outer_h = usable_h * height_pct / 100;
    const max_x = usable_w -| outer_w;
    const max_y = usable_h -| outer_h;
    const outer_x = max_x * pos_x_pct / 100;
    const outer_y = max_y * pos_y_pct / 100;

    const pad_x: u16 = 1 + pad_x_cfg;
    const pad_y: u16 = 1 + pad_y_cfg;
    const content_x = outer_x + pad_x;
    const content_y = outer_y + pad_y;
    const content_w = outer_w -| (pad_x * 2);
    const content_h = outer_h -| (pad_y * 2);

    const id: u16 = @intCast(100 + state.view.floats.items.len);
    if (!state.runtime.isConnected()) return error.SesUnavailable;
    const merged_env = mergeEnvLines(state.allocator, env, extra_env) catch null;
    defer if (merged_env) |slice| state.allocator.free(slice);
    const result = try state.runtime.createPane(command, cwd, null, null, merged_env, isolation_profile, null);
    const vt_fd = state.runtime.getVtFd() orelse return error.SesUnavailable;
    try pane.initWithPod(state.allocator, id, content_x, content_y, content_w, content_h, result.pane_id, vt_fd, result.uuid);

    pane.floating = true;
    pane.focused = true;
    pane.float_key = 0;
    pane.visible = true;

    if (title) |t| {
        if (t.len > 0) {
            pane.float_title = try state.allocator.dupe(u8, t);
        }
    }

    // Keep the pod's pane name separate from the float title.

    pane.border_x = outer_x;
    pane.border_y = outer_y;
    pane.border_w = outer_w;
    pane.border_h = outer_h;
    pane.border_color = border_color;

    pane.float_width_pct = @intCast(width_pct);
    pane.float_height_pct = @intCast(height_pct);
    pane.float_pos_x_pct = @intCast(pos_x_pct);
    pane.float_pos_y_pct = @intCast(pos_y_pct);
    pane.float_pad_x = @intCast(pad_x_cfg);
    pane.float_pad_y = @intCast(pad_y_cfg);

    pane.parent_tab = state.activeTabIndex();
    pane.sticky = false;
    pane.dim_background = size.dim_background;
    if (size.exit_key) |ek| {
        pane.exit_key = state.allocator.dupe(u8, ek) catch null;
    }

    if (style) |s| {
        pane.float_style = s;
    }

    pane.configureNotificationsFromPop(&state.pop_config.pane.notification);

    try state.view.floats.append(state.allocator, pane);
    state.setActiveFloatingIndex(state.view.floats.items.len - 1);
    state.syncPaneAux(pane, null);
    state.syncSessionFloat(pane, true);

    return pane.uuid;
}

pub fn createNamedFloat(state: *State, float_def: *const core.LayoutFloatDef, current_dir: ?[]const u8, parent_uuid: ?[32]u8) !void {
    const pane = try state.allocator.create(Pane);
    errdefer state.allocator.destroy(pane);

    const cfg = &state.config;

    const style = if (float_def.style) |*s| s else if (cfg.float_style_default) |*s| s else null;
    const shadow_enabled = if (style) |s| s.shadow_color != null else false;

    // Use per-float settings or fall back to defaults.
    const width_pct: u16 = float_def.width_percent orelse cfg.float_width_percent;
    const height_pct: u16 = float_def.height_percent orelse cfg.float_height_percent;
    const pos_x_pct: u16 = float_def.pos_x orelse 50; // default center
    const pos_y_pct: u16 = float_def.pos_y orelse 50; // default center
    const pad_x_cfg: u16 = float_def.padding_x orelse cfg.float_padding_x;
    const pad_y_cfg: u16 = float_def.padding_y orelse cfg.float_padding_y;
    const border_color = float_def.color orelse cfg.float_color;

    // Calculate outer frame size.
    const avail_h = state.term_height - state.status_height;
    const usable_w: u16 = if (shadow_enabled) (state.term_width -| 1) else state.term_width;
    const usable_h: u16 = if (shadow_enabled and state.status_height == 0) (avail_h -| 1) else avail_h;
    const outer_w = usable_w * width_pct / 100;
    const outer_h = usable_h * height_pct / 100;

    // Calculate position based on pos_x/pos_y percentages.
    const max_x = usable_w -| outer_w;
    const max_y = usable_h -| outer_h;
    const outer_x = max_x * pos_x_pct / 100;
    const outer_y = max_y * pos_y_pct / 100;

    // Content area: 1 cell border + configurable padding.
    const pad_x: u16 = 1 + pad_x_cfg;
    const pad_y: u16 = 1 + pad_y_cfg;
    const content_x = outer_x + pad_x;
    const content_y = outer_y + pad_y;
    const content_w = outer_w -| (pad_x * 2);
    const content_h = outer_h -| (pad_y * 2);

    const id: u16 = @intCast(100 + state.view.floats.items.len);

    // Extract isolation profile from float_def
    const isolation_profile: ?[]const u8 = if (float_def.isolation) |iso|
        if (iso.profile.len > 0) iso.profile else null
    else if (float_def.attributes.isolated)
        "default" // Use default profile when isolated=true and no profile is set
    else
        null;

    // Sticky metadata is what SES uses to decide sticky vs orphaned on disown.
    // For sticky/per_cwd floats, carry cwd+key into SES on creation.
    const sticky_pwd: ?[]const u8 = if ((float_def.attributes.sticky or float_def.attributes.per_cwd) and current_dir != null)
        current_dir.?
    else
        null;
    const sticky_key: ?u8 = if (float_def.attributes.sticky or float_def.attributes.per_cwd)
        float_def.key
    else
        null;

    if (!state.runtime.isConnected()) return error.SesUnavailable;
    const env_parent = if (float_def.attributes.inherit_env) parent_uuid else null;
    const result = try state.runtime.createPane(float_def.command, current_dir, sticky_pwd, sticky_key, null, isolation_profile, env_parent);
    const vt_fd = state.runtime.getVtFd() orelse return error.SesUnavailable;
    try pane.initWithPod(state.allocator, id, content_x, content_y, content_w, content_h, result.pane_id, vt_fd, result.uuid);

    // Persist sticky affinity metadata for better reclaim preference.
    if (sticky_pwd) |pwd| {
        if (sticky_key) |key| {
            state.runtime.setSticky(result.uuid, pwd, key) catch {};
        }
    }

    pane.floating = true;
    pane.focused = true;
    pane.float_key = float_def.key;

    // Title text is a pane property (outside style). Style only controls
    // positioning/formatting of the title widget.
    if (float_def.title) |t| {
        if (t.len > 0) {
            pane.float_title = state.allocator.dupe(u8, t) catch null;
        }
    }

    // Keep the pod's pane name separate from the float title.
    // For global floats (special or pwd), set per-tab visibility.
    // For tab-bound floats, use simple visible field.
    if (float_def.attributes.global or float_def.attributes.per_cwd) {
        pane.setVisibleOnTab(state.activeTabIndex(), true);
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

    // For pwd floats, store the directory and duplicate it.
    if (float_def.attributes.per_cwd) {
        pane.is_pwd = true;
        if (current_dir) |dir| {
            pane.pwd_dir = state.allocator.dupe(u8, dir) catch null;
        }
    }

    // For tab-bound floats, set parent tab.
    if (!float_def.attributes.global and !float_def.attributes.per_cwd) {
        pane.parent_tab = state.activeTabIndex();
    }

    // For sticky floats, set sticky.
    pane.sticky = float_def.attributes.sticky;

    // For navigatable floats, set navigatable.
    pane.navigatable = float_def.attributes.navigatable;

    // Store style reference.
    if (style) |s| {
        pane.float_style = s;
    }

    // Configure pane notifications.
    pane.configureNotificationsFromPop(&state.pop_config.pane.notification);

    try state.view.floats.append(state.allocator, pane);
    state.setActiveFloatingIndex(state.view.floats.items.len - 1);
    state.syncPaneAux(pane, parent_uuid);
    state.syncSessionFloat(pane, true);
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
