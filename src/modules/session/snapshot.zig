const std = @import("std");
const core = @import("core");
const session_model = core.session_model;

/// Shift a per-tab-index visibility bitmask when a tab is inserted at `index`.
/// Bits at or above `index` move up one; the new tab starts hidden.
pub fn shiftTabVisibleForInsert(mask: u64, index: usize) u64 {
    if (index >= 64) return mask;
    const shift: u6 = @intCast(index);
    const low_mask: u64 = (@as(u64, 1) << shift) - 1;
    const low = mask & low_mask;
    const high = (mask & ~low_mask) << 1;
    return low | high;
}

/// Shift a per-tab-index visibility bitmask when the tab at `index` is removed.
/// Its bit is dropped and everything above it moves down one.
pub fn shiftTabVisibleForRemove(mask: u64, index: usize) u64 {
    if (index >= 64) return mask;
    const shift: u6 = @intCast(index);
    const low_mask: u64 = (@as(u64, 1) << shift) - 1;
    const low = mask & low_mask;
    const high = (mask >> shift) >> 1 << shift;
    return low | high;
}

pub fn paneUuidInList(list: []const [32]u8, uuid: [32]u8) bool {
    for (list) |candidate| {
        if (std.mem.eql(u8, &candidate, &uuid)) return true;
    }
    return false;
}

pub fn firstLayoutPaneUuid(node: ?*const session_model.SessionLayoutNode) ?[32]u8 {
    const root = node orelse return null;
    return switch (root.*) {
        .pane => |uuid| uuid,
        .split => |split| firstLayoutPaneUuid(split.first) orelse firstLayoutPaneUuid(split.second),
    };
}

pub fn normalizeAfterPaneRemoval(snapshot: *session_model.SessionSnapshot) void {
    if (snapshot.tabs.items.len == 0) {
        snapshot.active_tab = 0;
        if (snapshot.active_float_uuid) |active_float_uuid| {
            if (!snapshot.panes.contains(active_float_uuid)) {
                snapshot.active_float_uuid = null;
            }
        }
        snapshot.focused_pane_uuid = snapshot.active_float_uuid;
        return;
    }

    if (snapshot.active_tab >= snapshot.tabs.items.len) {
        snapshot.active_tab = snapshot.tabs.items.len - 1;
    }

    if (snapshot.tabs.items[snapshot.active_tab].focused_pane_uuid == null) {
        snapshot.tabs.items[snapshot.active_tab].focused_pane_uuid =
            firstLayoutPaneUuid(snapshot.tabs.items[snapshot.active_tab].root);
    }

    if (snapshot.active_float_uuid) |active_float_uuid| {
        if (!snapshot.panes.contains(active_float_uuid)) {
            snapshot.active_float_uuid = null;
        }
    }

    if (snapshot.active_float_uuid) |active_float_uuid| {
        snapshot.focused_pane_uuid = active_float_uuid;
    } else {
        snapshot.focused_pane_uuid = snapshot.tabs.items[snapshot.active_tab].focused_pane_uuid;
    }
}

pub fn removePaneFromSessionSnapshot(
    allocator: std.mem.Allocator,
    snapshot: *session_model.SessionSnapshot,
    pane_uuid: [32]u8,
) void {
    const pane_state = snapshot.panes.get(pane_uuid) orelse {
        var float_idx: ?usize = null;
        for (snapshot.floats.items, 0..) |float_state, idx| {
            if (std.mem.eql(u8, &float_state.pane_uuid, &pane_uuid)) {
                float_idx = idx;
                break;
            }
        }
        if (float_idx) |idx| {
            _ = snapshot.floats.orderedRemove(idx);
        }
        if (snapshot.active_float_uuid) |active_float_uuid| {
            if (std.mem.eql(u8, &active_float_uuid, &pane_uuid)) {
                snapshot.active_float_uuid = null;
            }
        }
        if (snapshot.focused_pane_uuid) |focused_pane_uuid| {
            if (std.mem.eql(u8, &focused_pane_uuid, &pane_uuid)) {
                snapshot.focused_pane_uuid = null;
            }
        }
        normalizeAfterPaneRemoval(snapshot);
        return;
    };

    switch (pane_state.kind) {
        .float => {
            var float_idx: ?usize = null;
            for (snapshot.floats.items, 0..) |float_state, idx| {
                if (std.mem.eql(u8, &float_state.pane_uuid, &pane_uuid)) {
                    float_idx = idx;
                    break;
                }
            }
            if (float_idx) |idx| {
                _ = snapshot.floats.orderedRemove(idx);
            }
            _ = snapshot.panes.remove(pane_uuid);
        },
        .split => {
            var removed_tab_idx: ?usize = null;
            if (pane_state.parent_tab) |tab_idx| {
                if (tab_idx < snapshot.tabs.items.len) {
                    const removed_from_layout = session_model.removePaneFromLayout(snapshot.allocator, &snapshot.tabs.items[tab_idx].root, pane_uuid) catch |err| {
                        core.logging.logError("ses", "failed to remove split pane from session snapshot layout", err);
                        return;
                    };
                    if (!removed_from_layout) {
                        core.logging.warn("ses", "split pane {s} missing from parent layout during snapshot removal", .{pane_uuid[0..8]});
                    }
                    if (snapshot.tabs.items[tab_idx].focused_pane_uuid) |focused_pane_uuid| {
                        if (std.mem.eql(u8, &focused_pane_uuid, &pane_uuid)) {
                            snapshot.tabs.items[tab_idx].focused_pane_uuid =
                                firstLayoutPaneUuid(snapshot.tabs.items[tab_idx].root);
                        }
                    }
                    if (snapshot.tabs.items[tab_idx].root == null) {
                        var removed_tab = snapshot.tabs.orderedRemove(tab_idx);
                        removed_tab.deinit();
                        removed_tab_idx = tab_idx;
                    }
                }
            }

            _ = snapshot.panes.remove(pane_uuid);

            if (removed_tab_idx) |tab_idx| {
                var remove_split_uuids: std.ArrayList([32]u8) = .empty;
                defer remove_split_uuids.deinit(allocator);

                var pane_iter = snapshot.panes.iterator();
                while (pane_iter.next()) |entry| {
                    const parent = entry.value_ptr.parent_tab orelse continue;
                    switch (entry.value_ptr.kind) {
                        .split => {
                            if (parent == tab_idx) {
                                remove_split_uuids.append(allocator, entry.key_ptr.*) catch |err| {
                                    core.logging.logError("ses", "failed to collect split pane for tab removal", err);
                                };
                            } else if (parent > tab_idx) {
                                entry.value_ptr.parent_tab = parent - 1;
                            }
                        },
                        .float => {
                            if (parent == tab_idx) {
                                entry.value_ptr.parent_tab = null;
                            } else if (parent > tab_idx) {
                                entry.value_ptr.parent_tab = parent - 1;
                            }
                        },
                    }
                }
                for (remove_split_uuids.items) |split_uuid| {
                    _ = snapshot.panes.remove(split_uuid);
                }

                for (snapshot.floats.items) |*float_state| {
                    if (float_state.parent_tab) |parent| {
                        if (parent == tab_idx) {
                            float_state.parent_tab = null;
                        } else if (parent > tab_idx) {
                            float_state.parent_tab = parent - 1;
                        }
                    }
                    // tab_visible is indexed BY TAB INDEX
                    // (session_projection.paneVisibleOnTab tests
                    // `tab_visible & (1 << tab)`), so it has to move with
                    // parent_tab. Leaving it alone made a float pinned to a
                    // later tab appear on the wrong one after a tab closed —
                    // and it round-trips through JSON, so the corruption
                    // survived detach/reattach and daemon restarts.
                    float_state.tab_visible = shiftTabVisibleForRemove(float_state.tab_visible, tab_idx);
                }
            }
        },
    }

    if (snapshot.active_float_uuid) |active_float_uuid| {
        if (std.mem.eql(u8, &active_float_uuid, &pane_uuid)) {
            snapshot.active_float_uuid = null;
        }
    }
    if (snapshot.focused_pane_uuid) |focused_pane_uuid| {
        if (std.mem.eql(u8, &focused_pane_uuid, &pane_uuid)) {
            snapshot.focused_pane_uuid = null;
        }
    }

    normalizeAfterPaneRemoval(snapshot);
}

test "tab_visible shifts with tab insertion" {
    const testing = std.testing;
    // Tabs [0,1,2]; float visible on 0 and 2 => 0b101.
    const mask: u64 = 0b101;
    // Insert at 0: everything moves up, new tab starts hidden.
    try testing.expectEqual(@as(u64, 0b1010), shiftTabVisibleForInsert(mask, 0));
    // Insert at 1: bit 0 stays, bits 1.. move up.
    try testing.expectEqual(@as(u64, 0b1001), shiftTabVisibleForInsert(mask, 1));
    // Insert beyond the set bits changes nothing meaningful.
    try testing.expectEqual(@as(u64, 0b101), shiftTabVisibleForInsert(mask, 3));
    // Out-of-range index is a no-op rather than UB.
    try testing.expectEqual(mask, shiftTabVisibleForInsert(mask, 64));
}

test "tab_visible shifts with tab removal" {
    const testing = std.testing;
    // Tabs [0,1,2]; float visible only on tab 2 => 0b100.
    const only_last: u64 = 0b100;
    // Remove tab 0: old tab 2 becomes index 1, so the bit must follow it.
    // Leaving the mask alone was the bug: the float vanished from the tab it
    // was pinned to and reappeared on a tab index that no longer existed.
    try testing.expectEqual(@as(u64, 0b010), shiftTabVisibleForRemove(only_last, 0));

    // Removing the very tab a float was visible on drops that bit.
    try testing.expectEqual(@as(u64, 0b000), shiftTabVisibleForRemove(only_last, 2));

    // Mixed: visible on 0 and 2, remove 1 => visible on 0 and 1.
    try testing.expectEqual(@as(u64, 0b011), shiftTabVisibleForRemove(0b101, 1));

    // Removing above every set bit leaves them alone.
    try testing.expectEqual(@as(u64, 0b101), shiftTabVisibleForRemove(0b101, 5));

    try testing.expectEqual(only_last, shiftTabVisibleForRemove(only_last, 64));
}

test "tab_visible insert then remove at the same index round-trips" {
    const testing = std.testing;
    const cases = [_]u64{ 0, 0b1, 0b101, 0b1111, 0xDEAD_BEEF };
    for (cases) |mask| {
        for ([_]usize{ 0, 1, 3, 7 }) |idx| {
            const shifted = shiftTabVisibleForInsert(mask, idx);
            try testing.expectEqual(mask, shiftTabVisibleForRemove(shifted, idx));
        }
    }
}
