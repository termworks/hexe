const std = @import("std");

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;
const float_util = @import("float_util.zig");

const isFloatRenderableOnTab = float_util.isFloatRenderableOnTab;

fn restoreTabFocus(state: *State, old_uuid: ?[32]u8) void {
    // Restore float only if last focus kind was float.
    const active_tab = state.activeTabIndex();
    if (state.lastFocusKindForTab(active_tab) == .float) {
        if (state.lastFloatingUuidForTab(active_tab)) |uuid| {
            for (state.view.floats.items, 0..) |pane, fi| {
                if (!std.mem.eql(u8, &pane.uuid, &uuid)) continue;
                if (!isFloatRenderableOnTab(pane, active_tab)) continue;
                state.setActiveFloatingIndex(fi);
                state.syncPaneFocus(pane, old_uuid);
                return;
            }
        }
    }

    state.setActiveFloatingIndex(null);
    if (state.currentLayout().getFocusedPane()) |new_pane| {
        state.syncPaneFocus(new_pane, old_uuid);
    }
}

pub fn switchToTab(state: *State, new_tab: usize) void {
    if (new_tab >= state.view.tabs.items.len) return;
    const old_uuid = state.getCurrentFocusedUuid();

    // Clear any pending/active selection on tab change.
    state.mouse_selection.clear();
    state.clearFloatRename();
    state.mouse_drag = .none;

    if (state.activeFloatingIndex()) |idx| {
        if (idx < state.view.floats.items.len) {
            state.syncPaneUnfocus(state.view.floats.items[idx]);
        }
        state.setActiveFloatingIndex(null);
    } else if (state.currentLayout().getFocusedPane()) |old_pane| {
        state.syncPaneUnfocus(old_pane);
    }

    state.setActiveTabIndex(new_tab);
    state.renderer.invalidate();
    state.force_full_render = true;

    restoreTabFocus(state, old_uuid);
    state.needs_render = true;
}
