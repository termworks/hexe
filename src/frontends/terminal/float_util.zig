const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;

/// Check if a floating pane should be rendered on a given tab.
/// A float is renderable if:
/// 1. It's visible on the tab (visibility flags)
/// 2. Its parent_tab matches (if set), OR it has no parent_tab restriction
pub fn isFloatRenderableOnTab(state: *State, pane: *Pane, tab_idx: usize) bool {
    if (!state.paneVisibleOnTab(pane, tab_idx)) return false;
    if (state.paneParentTab(pane)) |parent| {
        return parent == tab_idx;
    }
    return true;
}
