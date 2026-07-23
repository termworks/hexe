const std = @import("std");
const core = @import("core");

const State = @import("state.zig").State;
const loop_ipc = @import("loop_ipc.zig");
const keybinds = @import("keybinds.zig");

fn wantsFastStatusRefresh(state: *State) bool {
    const uuid = state.getCurrentFocusedUuid() orelse return false;

    // If a float is focused, allow fast refresh (spinners in statusbar).
    if (state.activeFloatingIndex() != null) return true;

    // Suppress while alt-screen is active (for split-focused panes).
    const alt = if (state.currentLayout().getFocusedPane()) |pane| pane.vt.inAltScreen() else false;
    if (alt) return false;

    // Prefer direct fg_process; fallback to cached process name.
    const fg = if (state.activeFloatingIndex()) |idx| blk: {
        if (idx < state.view.float_views.items.len) {
            if (state.view.float_views.items[idx].getFgProcess()) |p| break :blk p;
        }
        break :blk @as(?[]const u8, null);
    } else if (state.currentLayout().getFocusedPane()) |pane| pane.getFgProcess() else null;

    const proc_name = fg orelse blk: {
        if (state.getPaneProc(uuid)) |pi| {
            if (pi.name) |n| break :blk n;
        }
        break :blk @as(?[]const u8, null);
    };
    if (proc_name == null) return false;

    const shells = [_][]const u8{ "bash", "zsh", "fish", "sh", "dash", "nu", "xonsh", "pwsh", "cmd", "elvish" };
    for (shells) |s| {
        if (std.mem.eql(u8, proc_name.?, s)) return false;
    }
    return true;
}

fn statusUpdateInterval(state: *State) i64 {
    return if (wantsFastStatusRefresh(state))
        core.constants.Timing.status_update_interval_anim
    else
        core.constants.Timing.status_update_interval_base;
}

/// Update UI concerns that must run before dead split cleanup, because mouse
/// selection can mutate pane scrollback/selection state on the currently
/// focused pane.
pub fn updateSelectionAndStatus(state: *State, now_ms: i64, last_status_update: *i64) void {
    // Auto-scroll while selecting when the mouse is near the top/bottom.
    // This allows selecting hidden content by holding the mouse at the edge.
    if (state.mouse_selection.active and state.mouse_selection.edge_scroll != .none) {
        const interval_ms: i64 = core.constants.Timing.key_timer_interval;
        if (now_ms - state.mouse_selection_last_autoscroll_ms >= interval_ms) {
            state.mouse_selection_last_autoscroll_ms = now_ms;
            if (state.mouse_selection.pane_uuid) |uuid| {
                if (state.findPaneByUuid(uuid)) |p| {
                    switch (state.mouse_selection.edge_scroll) {
                        .up => p.scrollUp(1),
                        .down => p.scrollDown(1),
                        .none => {},
                    }
                    // Recompute cursor in buffer coordinates for the current
                    // viewport after the scroll.
                    state.mouse_selection.update(p, state.mouse_selection.last_local.x, state.mouse_selection.last_local.y);
                    state.needs_render = true;
                }
            }
        }
    }

    // The periodic refresh keeps time-driven UI current: statusbar content
    // (clock, spinners, process info) and float border title segments, which
    // run through the same segment machinery. With neither present, renders
    // can be purely event-driven.
    const has_time_driven_ui = state.config.tabs.status.enabled or state.view.float_views.items.len > 0;
    if (has_time_driven_ui and now_ms - last_status_update.* >= statusUpdateInterval(state)) {
        state.needs_render = true;
        last_status_update.* = now_ms;
    }
}

pub fn updateOverlaysPopupsAndKeyTimers(state: *State, now_ms: i64) void {
    // Update MUX realm notifications.
    if (state.notifications.update()) {
        state.needs_render = true;
    }

    // Update overlays (expire info overlays, keycast entries).
    if (state.overlays.update()) {
        state.needs_render = true;
    }

    // Update MUX realm popups (check for timeout).
    const mux_popup_changed = state.popups.update();
    if (mux_popup_changed) {
        state.needs_render = true;
        // Check if a popup timed out and we need to send response.
        if (state.pending_pop_response and state.pending_pop_scope == .mux and !state.popups.isBlocked()) {
            loop_ipc.sendPopResponse(state);
        }
    }

    // TAB realm (current tab only) — skipped while the session has no tab,
    // which is the startup chooser's normal state.
    if (state.view.tab_views.items.len > 0) {
        const tab = &state.view.tab_views.items[state.activeTabIndex()];

        // Update TAB realm notifications.
        if (tab.notifications.update()) {
            state.needs_render = true;
        }

        // Update TAB realm popups (check for timeout).
        if (tab.popups.update()) {
            state.needs_render = true;
            // Check if a popup timed out and we need to send response.
            if (state.pending_pop_response and state.pending_pop_scope == .tab and !tab.popups.isBlocked()) {
                loop_ipc.sendPopResponse(state);
            }
        }
    }

    // Update PANE realm notifications (splits).
    var notif_pane_it = state.currentLayout().splitIterator();
    while (notif_pane_it.next()) |pane| {
        if (pane.*.updateNotifications()) {
            state.needs_render = true;
        }
        // Update PANE realm popups (check for timeout).
        if (pane.*.updatePopups()) {
            state.needs_render = true;
            // Check if a popup timed out and we need to send response.
            if (state.pending_pop_response and state.pending_pop_scope == .pane) {
                if (state.pending_pop_pane) |pending_pane| {
                    if (pending_pane == pane.* and !pane.*.popups.isBlocked()) {
                        loop_ipc.sendPopResponse(state);
                    }
                }
            }
        }
    }

    // Update PANE realm notifications (floats).
    for (state.view.float_views.items) |pane| {
        if (pane.updateNotifications()) {
            state.needs_render = true;
        }
        // Update PANE realm popups (check for timeout).
        if (pane.updatePopups()) {
            state.needs_render = true;
            // Check if a popup timed out and we need to send response.
            if (state.pending_pop_response and state.pending_pop_scope == .pane) {
                if (state.pending_pop_pane) |pending_pane| {
                    if (pending_pane == pane and !pane.popups.isBlocked()) {
                        loop_ipc.sendPopResponse(state);
                    }
                }
            }
        }
    }

    // Process keybinding timers (hold / double-tap delayed press).
    keybinds.processKeyTimers(state, now_ms);
}
