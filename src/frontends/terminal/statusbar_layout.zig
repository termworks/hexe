//! Placement for the three status bar zones.
//!
//! Pure arithmetic: takes the bar width and the measured width of each zone's
//! painter response, returns where to draw each one. No renderer, no registry.

const std = @import("std");

pub const Zone = enum(u2) { left = 0, center = 1, right = 2 };

/// Order in which zones give up their width when the bar is too narrow. The
/// last entry is the one kept longest.
pub const DEFAULT_SHRINK = [3]Zone{ .center, .right, .left };

pub const Slot = struct {
    x: u16 = 0,
    width: u16 = 0,
    drawn: bool = false,
};

pub const Placement = struct {
    slots: [3]Slot = .{Slot{}} ** 3,

    pub fn get(self: Placement, zone: Zone) Slot {
        return self.slots[@intFromEnum(zone)];
    }
};

/// Parse a zone name from config. Null for anything else.
pub fn zoneFromName(name: []const u8) ?Zone {
    if (std.mem.eql(u8, name, "left")) return .left;
    if (std.mem.eql(u8, name, "center")) return .center;
    if (std.mem.eql(u8, name, "right")) return .right;
    return null;
}

/// Left at 0, right flush to the far edge, center on the bar's own midpoint.
///
/// The centre's position depends on the bar and on its own width, and on
/// nothing else -- a neighbour changing width must never move it. When the
/// three do not fit, zones are dropped in `shrink` order; the last survivor is
/// clipped rather than dropped.
pub fn place(bar_width: u16, widths: [3]u16, shrink: [3]Zone) Placement {
    var keep = [3]bool{ widths[0] > 0, widths[1] > 0, widths[2] > 0 };
    var w = widths;

    for (shrink) |zone| {
        if (total(w, keep) <= bar_width) break;
        if (keptCount(keep) <= 1) break;
        keep[@intFromEnum(zone)] = false;
    }

    // One zone left and still too wide: clip it to the bar.
    if (total(w, keep) > bar_width) {
        for (0..3) |i| {
            if (keep[i]) w[i] = bar_width;
        }
    }

    const l: u16 = if (keep[0]) w[0] else 0;
    const c: u16 = if (keep[1]) w[1] else 0;
    const r: u16 = if (keep[2]) w[2] else 0;

    var out: Placement = .{};
    if (keep[0]) out.slots[0] = .{ .x = 0, .width = l, .drawn = true };
    if (keep[2]) out.slots[2] = .{ .x = bar_width -| r, .width = r, .drawn = true };
    if (keep[1]) {
        // Anchored to the BAR, never to its neighbours.
        //
        // This used to be clamped to the left zone's width, so a left zone wider
        // than the midpoint shoved the centre right by exactly that width -- and
        // since a clock, a spinner and a name all change width as they run, the
        // centre slid a column back and forth on almost every frame. The centre
        // is where the pane list lives, and a pane list that moves whenever
        // something else redraws is the flicker you actually see.
        const cx: u16 = (bar_width -| c) / 2;
        out.slots[1] = .{ .x = cx, .width = c, .drawn = true };

        // Whoever would overlap gives up columns instead. The centre holds its
        // ground because it is the one thing here worth reading continuously.
        if (keep[0] and l > cx) {
            out.slots[0] = .{ .x = 0, .width = cx, .drawn = cx > 0 };
        }
        if (keep[2]) {
            const room: u16 = bar_width -| (cx + c);
            if (r > room) {
                // Still flush right: it loses its head, not its tail.
                out.slots[2] = .{ .x = cx + c, .width = room, .drawn = room > 0 };
            }
        }
    }
    return out;
}

fn total(w: [3]u16, keep: [3]bool) u32 {
    var sum: u32 = 0;
    for (0..3) |i| {
        if (keep[i]) sum += w[i];
    }
    return sum;
}

fn keptCount(keep: [3]bool) usize {
    var n: usize = 0;
    for (keep) |k| {
        if (k) n += 1;
    }
    return n;
}

test "all three fit: left flush, right flush, center centered" {
    const p = place(100, .{ 10, 20, 15 }, DEFAULT_SHRINK);

    try std.testing.expect(p.get(.left).drawn);
    try std.testing.expectEqual(@as(u16, 0), p.get(.left).x);
    try std.testing.expectEqual(@as(u16, 10), p.get(.left).width);

    try std.testing.expect(p.get(.right).drawn);
    try std.testing.expectEqual(@as(u16, 85), p.get(.right).x);
    try std.testing.expectEqual(@as(u16, 100), p.get(.right).x + p.get(.right).width);

    try std.testing.expect(p.get(.center).drawn);
    try std.testing.expectEqual(@as(u16, 40), p.get(.center).x);
}

test "the centre does not move when a neighbour changes width" {
    // The invariant, stated directly: a clock, a spinner and a name all change
    // width as they run, and none of them may shift the pane list. Anything
    // else here is negotiable; this is not.
    const bar: u16 = 100;
    const c: u16 = 20;
    var expected: ?u16 = null;
    for ([_]u16{ 0, 1, 5, 10, 30, 39, 40, 41, 50, 70, 95 }) |left| {
        for ([_]u16{ 0, 3, 15, 40 }) |right| {
            const p = place(bar, .{ left, c, right }, DEFAULT_SHRINK);
            if (!p.get(.center).drawn) continue;
            if (expected) |want| {
                try std.testing.expectEqual(want, p.get(.center).x);
            } else {
                expected = p.get(.center).x;
            }
        }
    }
    try std.testing.expectEqual(@as(u16, 40), expected.?);
}

test "a wide left loses columns rather than pushing the centre" {
    const p = place(50, .{ 30, 10, 5 }, DEFAULT_SHRINK);
    try std.testing.expectEqual(@as(u16, 20), p.get(.center).x); // (50 - 10) / 2
    try std.testing.expectEqual(@as(u16, 0), p.get(.left).x);
    try std.testing.expectEqual(@as(u16, 20), p.get(.left).width); // clipped, not shifted
    try std.testing.expect(p.get(.left).width <= p.get(.center).x);
}

test "a wide right stays flush and loses its head" {
    const p = place(50, .{ 5, 10, 30 }, DEFAULT_SHRINK);
    try std.testing.expectEqual(@as(u16, 20), p.get(.center).x);
    try std.testing.expect(p.get(.center).x + p.get(.center).width <= p.get(.right).x);
    try std.testing.expectEqual(@as(u16, 50), p.get(.right).x + p.get(.right).width);
}

test "overflow drops zones in shrink order" {
    // 40 + 40 + 40 into 100: centre goes first under the default order.
    const p = place(100, .{ 40, 40, 40 }, DEFAULT_SHRINK);
    try std.testing.expect(p.get(.left).drawn);
    try std.testing.expect(!p.get(.center).drawn);
    try std.testing.expect(p.get(.right).drawn);
    try std.testing.expectEqual(@as(u16, 60), p.get(.right).x);
}

test "shrink order is configurable" {
    // Same widths, but left is now the first to go.
    const p = place(100, .{ 40, 40, 40 }, .{ .left, .center, .right });
    try std.testing.expect(!p.get(.left).drawn);
    try std.testing.expect(p.get(.center).drawn);
    try std.testing.expect(p.get(.right).drawn);
}

test "two must go when one is not enough" {
    const p = place(50, .{ 40, 40, 40 }, DEFAULT_SHRINK);
    try std.testing.expectEqual(@as(usize, 1), countDrawn(p));
    try std.testing.expect(p.get(.left).drawn);
}

test "the last survivor is clipped, never dropped" {
    const p = place(30, .{ 80, 0, 0 }, DEFAULT_SHRINK);
    try std.testing.expect(p.get(.left).drawn);
    try std.testing.expectEqual(@as(u16, 0), p.get(.left).x);
    try std.testing.expectEqual(@as(u16, 30), p.get(.left).width);
}

test "a zone that answered nothing takes no space and is not drawn" {
    const p = place(100, .{ 0, 20, 0 }, DEFAULT_SHRINK);
    try std.testing.expect(!p.get(.left).drawn);
    try std.testing.expect(!p.get(.right).drawn);
    try std.testing.expect(p.get(.center).drawn);
    // Free to sit at true centre with nothing beside it.
    try std.testing.expectEqual(@as(u16, 40), p.get(.center).x);
}

test "an empty bar places nothing" {
    const p = place(80, .{ 0, 0, 0 }, DEFAULT_SHRINK);
    try std.testing.expectEqual(@as(usize, 0), countDrawn(p));
}

test "a zero-width bar draws nothing and does not underflow" {
    const p = place(0, .{ 10, 10, 10 }, DEFAULT_SHRINK);
    for (p.slots) |s| {
        try std.testing.expect(s.x == 0);
        try std.testing.expect(s.width <= 0);
    }
}

test "an exact fit keeps all three" {
    const p = place(30, .{ 10, 10, 10 }, DEFAULT_SHRINK);
    try std.testing.expectEqual(@as(usize, 3), countDrawn(p));
    try std.testing.expectEqual(@as(u16, 0), p.get(.left).x);
    try std.testing.expectEqual(@as(u16, 10), p.get(.center).x);
    try std.testing.expectEqual(@as(u16, 20), p.get(.right).x);
}

test "zone names parse, and anything else is rejected" {
    try std.testing.expectEqual(Zone.left, zoneFromName("left").?);
    try std.testing.expectEqual(Zone.center, zoneFromName("center").?);
    try std.testing.expectEqual(Zone.right, zoneFromName("right").?);
    try std.testing.expect(zoneFromName("centre") == null);
    try std.testing.expect(zoneFromName("") == null);
}

fn countDrawn(p: Placement) usize {
    var n: usize = 0;
    for (p.slots) |s| {
        if (s.drawn) n += 1;
    }
    return n;
}
