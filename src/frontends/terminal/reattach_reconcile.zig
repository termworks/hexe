//! Pure reattach reconciliation helpers (PLAN.md 1.8).
//!
//! Extracted from `state_reattach.zig` so the snapshot→view structural
//! comparison — the decision that gates the fast incremental reattach path
//! versus a full rebuild — can be characterized in isolation, without standing
//! up a full `State`. The frontend reattach machinery is high-churn and was
//! previously untested; this pins the comparison's behavior.

const std = @import("std");
const core = @import("core");
const layout_mod = @import("layout.zig");

const LayoutNode = layout_mod.LayoutNode;
const SessionLayoutNode = core.session_model.SessionLayoutNode;

/// Whether a live layout subtree structurally matches a session snapshot
/// subtree: same shape (pane vs split), same pane UUIDs, same split direction
/// and ratio (within tolerance). A structural match means the incremental
/// reattach path can update in place instead of rebuilding.
pub fn layoutMatchesSnapshot(node: ?*const LayoutNode, snapshot_node: ?*const SessionLayoutNode) bool {
    const live = node orelse return snapshot_node == null;
    const expected = snapshot_node orelse {
        core.logging.warn("terminal", "reattach incremental snapshot check failed: live layout has extra node", .{});
        return false;
    };

    return switch (live.*) {
        .pane => |pane_uuid| switch (expected.*) {
            .pane => |expected_uuid| std.mem.eql(u8, &pane_uuid, &expected_uuid),
            .split => false,
        },
        .split => |split| switch (expected.*) {
            .pane => false,
            .split => |expected_split| split.dir == @as(layout_mod.SplitDir, if (expected_split.dir == .horizontal) .horizontal else .vertical) and
                std.math.approxEqAbs(f32, split.ratio, expected_split.ratio, 0.0001) and
                layoutMatchesSnapshot(split.first, expected_split.first) and
                layoutMatchesSnapshot(split.second, expected_split.second),
        },
    };
}

const testing = std.testing;
const ua = [_]u8{'a'} ** 32;
const ub = [_]u8{'b'} ** 32;

test "layoutMatchesSnapshot: matching and mismatching panes" {
    var live_a = LayoutNode{ .pane = ua };
    var snap_a = SessionLayoutNode{ .pane = ua };
    var snap_b = SessionLayoutNode{ .pane = ub };
    try testing.expect(layoutMatchesSnapshot(&live_a, &snap_a));
    try testing.expect(!layoutMatchesSnapshot(&live_a, &snap_b));
}

test "layoutMatchesSnapshot: pane vs split shape mismatch" {
    var live_pane = LayoutNode{ .pane = ua };
    var s1 = SessionLayoutNode{ .pane = ua };
    var s2 = SessionLayoutNode{ .pane = ub };
    var snap_split = SessionLayoutNode{ .split = .{ .dir = .horizontal, .ratio = 0.5, .first = &s1, .second = &s2 } };
    try testing.expect(!layoutMatchesSnapshot(&live_pane, &snap_split));
}

test "layoutMatchesSnapshot: matching split tree; ratio/dir mismatch rebuilds" {
    var lp1 = LayoutNode{ .pane = ua };
    var lp2 = LayoutNode{ .pane = ub };
    var live = LayoutNode{ .split = .{ .dir = .horizontal, .ratio = 0.5, .first = &lp1, .second = &lp2 } };

    var sp1 = SessionLayoutNode{ .pane = ua };
    var sp2 = SessionLayoutNode{ .pane = ub };
    var snap = SessionLayoutNode{ .split = .{ .dir = .horizontal, .ratio = 0.5, .first = &sp1, .second = &sp2 } };
    try testing.expect(layoutMatchesSnapshot(&live, &snap));

    // Ratio drift beyond tolerance → not a match.
    var snap_ratio = SessionLayoutNode{ .split = .{ .dir = .horizontal, .ratio = 0.7, .first = &sp1, .second = &sp2 } };
    try testing.expect(!layoutMatchesSnapshot(&live, &snap_ratio));

    // Direction mismatch → not a match.
    var snap_dir = SessionLayoutNode{ .split = .{ .dir = .vertical, .ratio = 0.5, .first = &sp1, .second = &sp2 } };
    try testing.expect(!layoutMatchesSnapshot(&live, &snap_dir));

    // Child UUID mismatch propagates up.
    var sp2b = SessionLayoutNode{ .pane = ua };
    var snap_child = SessionLayoutNode{ .split = .{ .dir = .horizontal, .ratio = 0.5, .first = &sp1, .second = &sp2b } };
    try testing.expect(!layoutMatchesSnapshot(&live, &snap_child));
}

test "layoutMatchesSnapshot: null-node handling" {
    try testing.expect(layoutMatchesSnapshot(null, null));
    var live = LayoutNode{ .pane = ua };
    var snap = SessionLayoutNode{ .pane = ua };
    try testing.expect(!layoutMatchesSnapshot(&live, null));
    try testing.expect(!layoutMatchesSnapshot(null, &snap));
}
