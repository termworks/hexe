const std = @import("std");

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;
const float_util = @import("float_util.zig");

const isFloatRenderableOnTab = float_util.isFloatRenderableOnTab;

pub fn restoreTabFocus(state: *State, old_uuid: ?[32]u8) void {
    // Restore float only if last focus kind was float.
    const active_tab = state.activeTabIndex();
    if (state.runtime.lastFocusKind(active_tab) == .float) {
        if (state.runtime.lastFloatingUuid(active_tab)) |uuid| {
            for (state.view.float_views.items, 0..) |candidate, idx| {
                if (!std.mem.eql(u8, &candidate.uuid, &uuid)) continue;
                const fi = state.familyCurrentIndex(candidate) orelse idx;
                const pane = state.view.float_views.items[fi];
                if (!isFloatRenderableOnTab(state, pane, active_tab)) continue;
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
    if (new_tab >= state.view.tab_views.items.len) return;
    const old_uuid = state.getCurrentFocusedUuid();

    // Clear any pending/active selection and pane-bound modes on tab change.
    if (state.isSearchActive()) state.exitSearchMode();
    if (state.isCopyModeActive()) state.exitCopyMode();
    state.mouse_selection.clear();
    state.clearFloatRename();
    state.mouse_drag = .none;

    if (state.activeFloatingIndex()) |idx| {
        if (idx < state.view.float_views.items.len) {
            state.syncPaneUnfocus(state.view.float_views.items[idx]);
        }
        state.setActiveFloatingIndex(null);
        state.cursor_needs_restore = true;
    } else if (state.currentLayout().getFocusedPane()) |old_pane| {
        state.syncPaneUnfocus(old_pane);
    }

    state.setActiveTabIndex(new_tab);
    state.renderer.invalidate();
    state.force_full_render = true;

    restoreTabFocus(state, old_uuid);
    state.needs_render = true;
}
