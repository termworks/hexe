const layout_mod = @import("layout.zig");
const focus_nav = @import("focus_nav.zig");
const State = @import("state.zig").State;
const actions = @import("loop_actions.zig");

/// Move focus across splits in the given direction.
///
/// This is shared by both keybindings and IPC/CLI requests to avoid
/// dependency cycles between modules.
///
/// Behavior depends on current focus:
/// - Float: left/right switches tabs directly (up/down ignored).
///   Floats have dedicated toggle keys so directional nav skips them.
/// - Split: directional navigation among splits, tab switch at edge.
pub fn perform(state: *State, dir: layout_mod.Layout.Direction) bool {
    // Floats have dedicated toggle keys — directional navigation skips them.
    // Left/right switches tabs, up/down ignored.
    if (state.activeFloatingIndex()) |idx| {
        if (idx < state.view.floats.items.len) {
            state.cursor_needs_restore = true;
            switch (dir) {
                .left => actions.switchToPrevTab(state),
                .right => actions.switchToNextTab(state),
                .up, .down => {},
            }
            state.needs_render = true;
            return true;
        }
    }

    // Split navigation
    const old_uuid = state.getCurrentFocusedUuid();
    const cursor = blk: {
        if (state.currentLayout().getFocusedPane()) |pane| {
            const pos = pane.getCursorPos();
            break :blk @as(?layout_mod.CursorPos, .{ .x = pos.x, .y = pos.y });
        }
        break :blk @as(?layout_mod.CursorPos, null);
    };

    if (focus_nav.focusDirectionAny(state, dir, cursor)) |target| {
        state.setActiveFloatingIndex(null);
        state.syncPaneFocus(target.pane, old_uuid);
        state.renderer.invalidate();
        state.force_full_render = true;
    } else {
        // No split found in that direction — switch tabs at the edge.
        switch (dir) {
            .left => actions.switchToPrevTab(state),
            .right => actions.switchToNextTab(state),
            else => {},
        }
    }
    state.needs_render = true;
    return true;
}
