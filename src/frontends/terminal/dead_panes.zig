const std = @import("std");
const lua_events = @import("lua_events.zig");
const core = @import("core");

const State = @import("state.zig").State;
const terminal_main = @import("main.zig");
const float_completion = @import("float_completion.zig");

pub fn cleanupDeadFloat(state: *State, index: usize) void {
    if (index >= state.view.float_views.items.len) return;

    const pane = state.view.float_views.items[index];
    const was_active = if (state.activeFloatingIndex()) |af| af == index else false;
    const exit_code = state.paneExitCode(pane.uuid);
    const pane_uuid = pane.uuid;

    _ = state.view.float_views.orderedRemove(index);

    terminal_main.debugLog("float pane died: uuid={s} exit_code={d} focused={}", .{ pane_uuid[0..8], exit_code, was_active });

    if (!was_active and exit_code != 0) {
        const msg = std.fmt.allocPrint(
            state.allocator,
            "Background float exited with code {d}",
            .{exit_code},
        ) catch "Background float exited unexpectedly";
        defer if (!std.mem.eql(u8, msg, "Background float exited unexpectedly")) state.allocator.free(msg);
        state.notifications.showFor(msg, 3000);
    }

    float_completion.handleBlockingFloatCompletion(state, pane);

    // Float is already dead (detected via isAlive/pane_exited), so avoid
    // sending another synchronous kill request on the shared control channel.

    state.clearTransientPaneState(pane);
    state.clearFloatUi(pane_uuid);
    pane.deinit();
    state.allocator.destroy(pane);
    state.needs_render = true;
    state.force_full_render = true;
    state.renderer.invalidate();
    state.clearLocalFloatState(pane_uuid);

    if (state.config._lua_runtime) |rt| {
        lua_events.emit(state, rt, "pane_exited", &.{
            .{ .name = "pane_uuid", .value = .{ .uuid = pane_uuid } },
            .{ .name = "exit_status", .value = .{ .int = @intCast(exit_code) } },
            .{ .name = "was_focused", .value = .{ .boolean = was_active } },
            .{ .name = "is_float", .value = .{ .boolean = true } },
            .{ .name = "closes_tab", .value = .{ .boolean = false } },
        });
    }

    if (was_active) {
        state.setActiveFloatingIndex(null);
        state.cursor_needs_restore = true;
        if (state.currentLayout().getFocusedPane()) |tiled| {
            state.syncPaneFocus(tiled, null);
        }
    }
}

pub fn cleanupDeadFloats(state: *State) void {
    if (state.view.float_views.items.len > 0) {
        var fi: usize = state.view.float_views.items.len;
        while (fi > 0) {
            fi -= 1;
            if (!state.view.float_views.items[fi].isAlive()) {
                cleanupDeadFloat(state, fi);
                // When iterating in reverse, removals don't affect unprocessed indices.
            }
        }
    }

    // Ensure active_floating is valid.
    if (state.activeFloatingIndex()) |af| {
        if (af >= state.view.float_views.items.len) {
            state.setActiveFloatingIndex(if (state.view.float_views.items.len > 0)
                state.view.float_views.items.len - 1
            else
                null);
        }
    }
}

pub fn handleDeferredRespawn(state: *State) void {
    if (!state.needs_respawn) return;

    state.needs_respawn = false;
    _ = state.respawnFocusedPaneAfterShellDeath();
}

pub fn cleanupDeadSplits(state: *State, dead_splits: *std.ArrayList([32]u8)) void {
    const allocator = state.allocator;

    dead_splits.clearRetainingCapacity();
    {
        var pane_it = state.currentLayout().splitIterator();
        while (pane_it.next()) |pane| {
            if (!pane.*.isAlive()) {
                dead_splits.append(allocator, pane.*.uuid) catch |err| {
                    terminal_main.debugLogUuid(&pane.*.uuid, "main loop: failed to queue dead split cleanup: {s}", .{@errorName(err)});
                };
            }
        }
    }

    // Ensure active_floating is still valid.
    if (state.activeFloatingIndex()) |af| {
        if (af >= state.view.float_views.items.len) {
            state.setActiveFloatingIndex(null);
        }
    }

    // Remove dead splits (skip if just respawned a shell).
    if (state.skip_dead_check) return;

    var dead_idx: usize = 0;
    while (dead_idx < dead_splits.items.len) : (dead_idx += 1) {
        const dead_uuid = dead_splits.items[dead_idx];
        // Find the dead pane to get exit status and determine if notification is needed.
        const dead_pane = state.currentLayout().splits.get(dead_uuid);
        // Dead-pane snapshots can become stale after tab/layout mutations.
        // Ignore UUIDs that no longer exist in the active layout.
        if (dead_pane == null) continue;
        // Only handle panes that are actually dead.
        if (dead_pane.?.isAlive()) continue;

        const was_focused = if (state.currentLayout().getFocusedPane()) |fp| std.mem.eql(u8, &fp.uuid, &dead_uuid) else false;
        const exit_code = if (dead_pane) |p| state.paneExitCode(p.uuid) else 0;

        if (state.config._lua_runtime) |rt| {
            lua_events.emit(state, rt, "pane_exited", &.{
                .{ .name = "pane_uuid", .value = .{ .uuid = dead_uuid } },
                .{ .name = "exit_status", .value = .{ .int = @intCast(exit_code) } },
                .{ .name = "was_focused", .value = .{ .boolean = was_focused } },
                .{ .name = "is_float", .value = .{ .boolean = false } },
                .{ .name = "closes_tab", .value = .{ .boolean = state.currentLayout().splitCount() <= 1 } },
            });
        }

        if (state.currentLayout().splitCount() > 1) {
            const dead_view_id = dead_pane.?.id;
            state.clearTransientPaneState(dead_pane.?);
            // Multiple splits in tab - close the specific dead pane.
            _ = state.currentLayout().closePane(dead_uuid);
            // If the dead pane was the zoomed one, its uuid now matches nothing
            // and the render loop draws an empty tab.
            state.revalidateZoom();

            // Log pane death.
            terminal_main.debugLog("pane died: view_id={d} exit_code={d} focused={}", .{ dead_view_id, exit_code, was_focused });

            // Show notification if pane died with non-zero exit or was unfocused (unexpected).
            if (!was_focused and exit_code != 0) {
                const msg = std.fmt.allocPrint(
                    allocator,
                    "Background pane exited with code {d}",
                    .{exit_code},
                ) catch "Background pane exited unexpectedly";
                defer if (!std.mem.eql(u8, msg, "Background pane exited unexpectedly")) allocator.free(msg);
                state.notifications.showFor(msg, 3000);
            }

            if (state.currentLayout().getFocusedPane()) |new_pane| {
                state.syncPaneFocus(new_pane, null);
            }
            state.needs_render = true;
        } else if (state.view.tab_views.items.len > 1) {
            _ = state.closeCurrentTab();
            state.needs_render = true;
            // Active tab changed; remaining dead UUIDs were collected from
            // the old tab context and must be discarded this iteration.
            break;
        } else {
            // If the shell asked permission to exit and we confirmed,
            // don't ask again when it actually dies.
            const now_ms = std.time.milliTimestamp();
            if (state.exit_intent_deadline_ms > now_ms) {
                state.exit_intent_deadline_ms = 0;
                state.running = false;
            } else if (state.config.confirm_on_exit and state.pending_action == null) {
                state.exit_from_shell_death = true;
                if (!state.showConfirmOrNotify(.exit, "Shell exited. Close terminal session?")) {
                    state.exit_from_shell_death = false;
                    state.running = false;
                }
            } else if (state.pending_action != .exit or !state.exit_from_shell_death) {
                state.running = false;
            }
        }
    }
}
