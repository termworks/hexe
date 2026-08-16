const std = @import("std");
const core = @import("core");
const session_model = core.session_model;

pub const shiftTabVisibleForInsert = session_model.shiftTabVisibleForInsert;
pub const shiftTabVisibleForRemove = session_model.shiftTabVisibleForRemove;

/// Remove `idx` from an owned uuid slice, returning a correctly-sized slice.
///
/// The previous idiom was fromOwnedSlice -> orderedRemove -> toOwnedSlice, and
/// on toOwnedSlice failure it assigned `list.items` -- a slice ONE ELEMENT
/// SHORTER than its backing allocation. `pane_uuids` is later released with
/// `allocator.free(self.pane_uuids)`, i.e. by that wrong length: an
/// allocation-size mismatch under the testing allocator, and an under-unmap
/// under page_allocator.
///
/// Shrinking realloc is effectively infallible (it can return the same
/// pointer), but if it ever fails the ORIGINAL length is kept so the eventual
/// free still matches the allocation. That leaves the tail entry duplicated,
/// which is harmless: a second lookup finds the same pane and the next prune
/// removes it.
pub fn removeUuidFromOwnedSlice(
    allocator: std.mem.Allocator,
    uuids: [][32]u8,
    idx: usize,
) [][32]u8 {
    if (idx >= uuids.len) return uuids;
    std.mem.copyForwards([32]u8, uuids[idx .. uuids.len - 1], uuids[idx + 1 ..]);
    return allocator.realloc(uuids, uuids.len - 1) catch |err| {
        core.logging.logError("ses", "failed to shrink pane uuid list; keeping full allocation", err);
        return uuids;
    };
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

                // active_tab is an INDEX too, and every index above the removed
                // tab just shifted down. Leaving it alone silently moved focus
                // to a different tab: with tabs [0,1,2] and active_tab = 1,
                // collapsing tab 0 makes old tab 1 index 0, but active_tab
                // stayed 1 -- now pointing at what used to be tab 2.
                // normalizeAfterPaneRemoval only CLAMPS an out-of-range value,
                // so it never caught this, and it then rewrote the focused pane
                // of the wrong tab.
                if (snapshot.active_tab > tab_idx) {
                    snapshot.active_tab -= 1;
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

test "removing a collapsed tab shifts active_tab with it" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Three tabs, each a single pane; focus on tab 1.
    var snap = try session_model.SessionSnapshot.initMinimal(allocator, [_]u8{'s'} ** 32, "shifty");
    defer snap.deinit();

    var uuids: [3][32]u8 = undefined;
    for (0..3) |i| {
        uuids[i] = [_]u8{@intCast('a' + i)} ** 32;
        const root = try allocator.create(session_model.SessionLayoutNode);
        root.* = .{ .pane = uuids[i] };
        try snap.tabs.append(allocator, .{
            .uuid = [_]u8{@intCast('T')} ** 32,
            .name = try allocator.dupe(u8, "t"),
            .root = root,
            .focused_pane_uuid = uuids[i],
            .allocator = allocator,
        });
        try snap.panes.put(uuids[i], .{
            .uuid = uuids[i],
            .kind = .split,
            .parent_tab = i,
        });
    }
    snap.active_tab = 1;

    // Collapse tab 0 by removing its only pane. Old tab 1 becomes index 0, so
    // focus must follow it to 0 -- not stay at 1, which is now old tab 2.
    removePaneFromSessionSnapshot(allocator, &snap, uuids[0]);

    try testing.expectEqual(@as(usize, 2), snap.tabs.items.len);
    try testing.expectEqual(@as(usize, 0), snap.active_tab);
    try testing.expectEqualSlices(u8, &uuids[1], &snap.tabs.items[0].focused_pane_uuid.?);
}

test "removing a tab below active_tab leaves it alone" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var snap = try session_model.SessionSnapshot.initMinimal(allocator, [_]u8{'s'} ** 32, "steady");
    defer snap.deinit();

    var uuids: [3][32]u8 = undefined;
    for (0..3) |i| {
        uuids[i] = [_]u8{@intCast('a' + i)} ** 32;
        const root = try allocator.create(session_model.SessionLayoutNode);
        root.* = .{ .pane = uuids[i] };
        try snap.tabs.append(allocator, .{
            .uuid = [_]u8{@intCast('T')} ** 32,
            .name = try allocator.dupe(u8, "t"),
            .root = root,
            .focused_pane_uuid = uuids[i],
            .allocator = allocator,
        });
        try snap.panes.put(uuids[i], .{
            .uuid = uuids[i],
            .kind = .split,
            .parent_tab = i,
        });
    }
    snap.active_tab = 0;

    // Removing a LATER tab must not move focus.
    removePaneFromSessionSnapshot(allocator, &snap, uuids[2]);
    try testing.expectEqual(@as(usize, 2), snap.tabs.items.len);
    try testing.expectEqual(@as(usize, 0), snap.active_tab);
}

test "removeUuidFromOwnedSlice returns an exactly-sized slice" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // The testing allocator fails the whole test on an allocation-size
    // mismatch, so a slice whose length disagrees with its allocation would be
    // caught right here on free -- which is exactly the bug the old
    // toOwnedSlice-failure path introduced.
    var uuids = try allocator.alloc([32]u8, 3);
    uuids[0] = [_]u8{'a'} ** 32;
    uuids[1] = [_]u8{'b'} ** 32;
    uuids[2] = [_]u8{'c'} ** 32;

    uuids = removeUuidFromOwnedSlice(allocator, uuids, 1);
    defer allocator.free(uuids);

    try testing.expectEqual(@as(usize, 2), uuids.len);
    try testing.expectEqualSlices(u8, &[_]u8{'a'} ** 32, &uuids[0]);
    try testing.expectEqualSlices(u8, &[_]u8{'c'} ** 32, &uuids[1]);
}

test "removeUuidFromOwnedSlice handles first, last and out-of-range" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var first = try allocator.alloc([32]u8, 2);
    first[0] = [_]u8{'x'} ** 32;
    first[1] = [_]u8{'y'} ** 32;
    first = removeUuidFromOwnedSlice(allocator, first, 0);
    defer allocator.free(first);
    try testing.expectEqual(@as(usize, 1), first.len);
    try testing.expectEqualSlices(u8, &[_]u8{'y'} ** 32, &first[0]);

    var last = try allocator.alloc([32]u8, 2);
    last[0] = [_]u8{'x'} ** 32;
    last[1] = [_]u8{'y'} ** 32;
    last = removeUuidFromOwnedSlice(allocator, last, 1);
    defer allocator.free(last);
    try testing.expectEqual(@as(usize, 1), last.len);
    try testing.expectEqualSlices(u8, &[_]u8{'x'} ** 32, &last[0]);

    var untouched = try allocator.alloc([32]u8, 1);
    untouched[0] = [_]u8{'z'} ** 32;
    untouched = removeUuidFromOwnedSlice(allocator, untouched, 5);
    defer allocator.free(untouched);
    try testing.expectEqual(@as(usize, 1), untouched.len);
}
