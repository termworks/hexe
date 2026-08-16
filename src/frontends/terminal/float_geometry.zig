//! Float position arithmetic, split out so it can be tested without a State.
//!
//! A float's position is STORED as a percentage (so it survives a resize) but
//! MOVED in cells. Both conversions truncate, and the frame is recomputed from
//! the percentage every frame — so the obvious `pct = cells * 100 / max` round
//! trips straight back to the original cell for most terminal widths, which is
//! why nudging right or down did nothing at all.

const std = @import("std");

/// Cell offset the renderer derives from a stored percentage.
/// Widened to u32: `max * pct` overflows u16 above 655 cells.
pub fn cellForPct(max: u16, pct: u16) u16 {
    const p = @min(pct, 100);
    return @intCast(@as(u32, max) * @as(u32, p) / 100);
}

/// Smallest percentage whose `cellForPct` is `want` — the inverse of the above.
///
/// `bias` is the direction of travel: when no percentage lands exactly on
/// `want`, prefer one that still moves that way rather than standing still.
pub fn pctForCell(want: u16, max: u16, bias: i32) u8 {
    if (max == 0) return 0;
    // Round up so the truncating inverse cannot fall short of `want`.
    var pct: u32 = (@as(u32, want) * 100 + @as(u32, max) - 1) / @as(u32, max);
    if (pct > 100) pct = 100;
    if (cellForPct(max, @intCast(pct)) == want) return @intCast(pct);

    var tries: u8 = 0;
    while (tries < 4) : (tries += 1) {
        if (bias > 0 and pct < 100) {
            pct += 1;
        } else if (bias < 0 and pct > 0) {
            pct -= 1;
        } else break;
        if (cellForPct(max, @intCast(pct)) == want) break;
    }
    return @intCast(@min(pct, 100));
}

test "nudging one cell actually moves the float" {
    // Every terminal width a person plausibly uses, against a 60%-wide float.
    for ([_]u16{ 80, 100, 120, 160, 200, 240, 400 }) |cols| {
        const max: u16 = cols - (cols * 60 / 100); // travel range
        var cell: u16 = 0;
        while (cell + 1 <= max) : (cell += 1) {
            const pct = pctForCell(cell + 1, max, 1);
            try std.testing.expect(cellForPct(max, pct) > cell);
        }
    }
}

test "nudging back lands where it started" {
    for ([_]u16{ 80, 120, 200 }) |cols| {
        const max: u16 = cols - (cols * 60 / 100);
        var cell: u16 = 1;
        while (cell < max) : (cell += 1) {
            const back = pctForCell(cell - 1, max, -1);
            try std.testing.expect(cellForPct(max, back) < cell);
        }
    }
}

test "cellForPct does not overflow on wide terminals" {
    // 700 * 100 = 70000, which wraps a u16 to 4464.
    try std.testing.expectEqual(@as(u16, 700), cellForPct(700, 100));
    try std.testing.expectEqual(@as(u16, 574), cellForPct(700, 82));
    try std.testing.expectEqual(@as(u16, 1000), cellForPct(1000, 100));
    try std.testing.expectEqual(@as(u16, 0), cellForPct(0, 100));
    try std.testing.expectEqual(@as(u16, 0), cellForPct(500, 0));
}

test "pctForCell is clamped and total" {
    try std.testing.expectEqual(@as(u8, 0), pctForCell(5, 0, 1));
    try std.testing.expect(pctForCell(9999, 100, 1) <= 100);
}
