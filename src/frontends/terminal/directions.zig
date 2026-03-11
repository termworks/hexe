const layout_mod = @import("layout.zig");

pub const Rect = struct {
    // Half-open rectangle: [x0, x1) x [y0, y1)
    x0: u16,
    y0: u16,
    x1: u16,
    y1: u16,

    pub fn center_x(self: Rect) u16 {
        return self.x0 + (self.x1 - self.x0) / 2;
    }

    pub fn center_y(self: Rect) u16 {
        return self.y0 + (self.y1 - self.y0) / 2;
    }
};

fn range_gap(a0: u16, a1: u16, b0: u16, b1: u16) i64 {
    // Returns 0 if ranges overlap, otherwise the minimum distance between them.
    if (a1 <= b0) return @as(i64, @intCast(b0 - a1));
    if (b1 <= a0) return @as(i64, @intCast(a0 - b1));
    return 0;
}

pub fn point_gap_to_range(p: u16, a0: u16, a1: u16) i64 {
    // Distance from a point to a half-open range [a0, a1).
    if (p < a0) return @as(i64, @intCast(a0 - p));
    if (p >= a1) return @as(i64, @intCast(p - (a1 -| 1)));
    return 0;
}

pub fn cursor_l1_to_rect(x: u16, y: u16, r: Rect) i64 {
    const dx = point_gap_to_range(x, r.x0, r.x1);
    const dy = point_gap_to_range(y, r.y0, r.y1);
    return dx + dy;
}

pub fn primary_distance_from_point(dir: layout_mod.Layout.Direction, x: u16, y: u16, r: Rect) ?i64 {
    // Returns the distance from (x,y) to the rectangle along the primary axis.
    // If the rectangle has no part in that direction (relative to the point),
    // returns null.
    return switch (dir) {
        .down => if (r.y1 <= y) null else @as(i64, @intCast(r.y0 -| y)),
        .up => if (r.y0 >= y) null else @as(i64, @intCast(y -| r.y1)),
        .right => if (r.x1 <= x) null else @as(i64, @intCast(r.x0 -| x)),
        .left => if (r.x0 >= x) null else @as(i64, @intCast(x -| r.x1)),
    };
}

pub fn secondary_distance_from_point(dir: layout_mod.Layout.Direction, x: u16, y: u16, r: Rect) i64 {
    // Perpendicular axis distance from point to the rectangle.
    return switch (dir) {
        .down, .up => point_gap_to_range(x, r.x0, r.x1),
        .left, .right => point_gap_to_range(y, r.y0, r.y1),
    };
}

pub fn beam_overlaps(dir: layout_mod.Layout.Direction, x: u16, y: u16, r: Rect) bool {
    // A "beam" is a line cast from the cursor along the movement direction.
    // If the candidate overlaps this line on the perpendicular axis, navigation
    // tends to feel much more predictable (common WM heuristic).
    return switch (dir) {
        .down, .up => x >= r.x0 and x < r.x1,
        .left, .right => y >= r.y0 and y < r.y1,
    };
}

pub fn is_in_direction(dir: layout_mod.Layout.Direction, cur: Rect, cand: Rect) bool {
    // Use center-to-center direction, like common tiling WMs.
    const cx = cur.center_x();
    const cy = cur.center_y();
    const tx = cand.center_x();
    const ty = cand.center_y();
    return switch (dir) {
        .left => tx < cx,
        .right => tx > cx,
        .up => ty < cy,
        .down => ty > cy,
    };
}

pub fn primary_separation(dir: layout_mod.Layout.Direction, cur: Rect, cand: Rect) i64 {
    // Separation between rectangles along primary axis. Overlap => 0.
    return switch (dir) {
        .down => if (cand.y0 > cur.y1) @as(i64, @intCast(cand.y0 - cur.y1)) else 0,
        .up => if (cur.y0 > cand.y1) @as(i64, @intCast(cur.y0 - cand.y1)) else 0,
        .right => if (cand.x0 > cur.x1) @as(i64, @intCast(cand.x0 - cur.x1)) else 0,
        .left => if (cur.x0 > cand.x1) @as(i64, @intCast(cur.x0 - cand.x1)) else 0,
    };
}

pub fn secondary_separation(dir: layout_mod.Layout.Direction, cur: Rect, cand: Rect) i64 {
    // Separation along the perpendicular axis (alignment penalty).
    return switch (dir) {
        .down, .up => range_gap(cur.x0, cur.x1, cand.x0, cand.x1),
        .left, .right => range_gap(cur.y0, cur.y1, cand.y0, cand.y1),
    };
}
