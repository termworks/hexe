const std = @import("std");
const Pane = @import("pane.zig").Pane;

pub fn getLayoutPath(state: anytype, pane: *Pane) !?[]const u8 {
    if (state.paneIsFloating(pane)) {
        if (state.paneParentTab(pane)) |tab_idx| {
            return try std.fmt.allocPrint(state.allocator, "tab:{d}/float:{d}", .{ tab_idx, pane.id });
        }
        return try std.fmt.allocPrint(state.allocator, "float:{d}", .{pane.id});
    }

    for (state.view.tabs.items, 0..) |*tab, ti| {
        var pane_it = tab.layout.splitIterator();
        while (pane_it.next()) |p| {
            if (p.* == pane) {
                return try std.fmt.allocPrint(state.allocator, "tab:{d}/split:{d}", .{ ti, pane.id });
            }
        }
    }

    return null;
}
