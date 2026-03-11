const Pane = @import("pane.zig").Pane;

/// Check if a floating pane should be rendered on a given tab.
/// A float is renderable if:
/// 1. It's visible on the tab (visibility flags)
/// 2. Its parent_tab matches (if set), OR it has no parent_tab restriction
pub fn isFloatRenderableOnTab(pane: *Pane, tab_idx: usize) bool {
    if (!pane.isVisibleOnTab(tab_idx)) return false;
    if (pane.parent_tab) |parent| {
        return parent == tab_idx;
    }
    return true;
}
