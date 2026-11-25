const std = @import("std");
const core = @import("core");

const State = @import("state.zig").State;
const loop_ipc = @import("loop_ipc.zig");
const keybinds = @import("keybinds.zig");

/// Update UI concerns that must run before dead split cleanup, because mouse
/// selection can mutate pane scrollback/selection state on the currently
/// focused pane.
pub fn updateSelectionAndStatus(state: *State, now_ms: i64) void {
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

    // Renders follow change. Painter answers that differ ask for one through
    // the region registry; a filmstrip frame or a drawing's expiry falling
    // due asks here.
    if (core.regions.active) |registry| {
        if (registry.msUntilFrame(now_ms)) |delta| {
            if (delta <= 0) state.needs_render = true;
        }
    }
    if (state.drawings.nextExpiry()) |at| {
        if (now_ms >= at) state.needs_render = true;
    }
}

pub fn updateOverlaysPopupsAndKeyTimers(state: *State, now_ms: i64) void {
    if (state.pending_config_reload and !state.in_lua_call) {
        state.pending_config_reload = false;
        @import("keybinds_actions.zig").performConfigReload(state);
    }

    // Update MUX realm notifications.
    if (state.notifications.update()) {
        state.needs_render = true;
    }

    // Update overlays (expire info overlays).
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

    // Update TAB and PANE realm notifications & popup timeouts across ALL tabs
    // so timed popups on background tabs still expire and answer waiting CLIs.
    for (state.view.tab_views.items, 0..) |*tab, tab_idx| {
        if (tab.notifications.update()) {
            state.needs_render = true;
        }
        if (tab.popups.update()) {
            state.needs_render = true;
            if (state.pending_pop_response and state.pending_pop_scope == .tab and state.pending_pop_tab == tab_idx and !tab.popups.isBlocked()) {
                loop_ipc.sendPopResponse(state);
            }
        }

        var notif_pane_it = tab.layout.splitIterator();
        while (notif_pane_it.next()) |pane| {
            if (pane.*.updateNotifications()) {
                state.needs_render = true;
            }
            if (pane.*.updatePopups()) {
                state.needs_render = true;
                if (state.pending_pop_response and state.pending_pop_scope == .pane) {
                    if (state.pending_pop_pane) |pending_pane| {
                        if (pending_pane == pane.* and !pane.*.popups.isBlocked()) {
                            loop_ipc.sendPopResponse(state);
                        }
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
