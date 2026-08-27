const frontend_core = @import("frontend_core");
const layout_mod = @import("layout.zig");
const focus_nav = @import("focus_nav.zig");
const State = @import("state.zig").State;
const actions = @import("loop_actions.zig");

fn coreDirectionFromLayout(dir: layout_mod.Layout.Direction) frontend_core.Direction {
    return switch (dir) {
        .up => .up,
        .down => .down,
        .left => .left,
        .right => .right,
    };
}

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
    // Floats have dedicated toggle keys, so directional navigation skips them by
    // default: left/right switches tabs, up/down does nothing.
    //
    // Unless the float asked to be navigable. `focus_nav.focusDirectionAny`
    // below already treats a focused float as the origin and lets floats and
    // splits compete equally -- this early return was the only thing standing
    // between the `navigatable` attribute and the behaviour it names.
    var origin_is_navigable_float = false;
    if (state.activeFloatingIndex()) |idx| {
        if (idx < state.view.float_views.items.len) {
            const fp = state.view.float_views.items[idx];
            const navigable = if (state.floatUiConst(fp)) |ui| ui.navigatable else false;
            if (navigable) {
                origin_is_navigable_float = true;
            } else {
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
    }

    // Split navigation
    const old_uuid = state.getCurrentFocusedUuid();
    const cursor = blk: {
        // Navigating FROM a float: let `focusDirectionAny` take the origin from
        // the float itself. The layout's focused pane is a tiled one, and
        // steering by its cursor would measure the move from the wrong place.
        if (origin_is_navigable_float) break :blk @as(?layout_mod.CursorPos, null);
        if (state.currentLayout().getFocusedPane()) |pane| {
            const pos = pane.getCursorPos();
            break :blk @as(?layout_mod.CursorPos, .{ .x = pos.x, .y = pos.y });
        }
        break :blk @as(?layout_mod.CursorPos, null);
    };

    if (focus_nav.focusDirectionAny(state, dir, cursor)) |target| {
        state.setActiveFloatingIndex(null);
        state.applyFrontendFocusMove(coreDirectionFromLayout(dir), target.pane.uuid);
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
