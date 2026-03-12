const std = @import("std");

const layout_mod = @import("layout.zig");
const directions = @import("directions.zig");
const float_util = @import("float_util.zig");

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;

pub const FocusTargetKind = enum { split, float };

pub const FocusTarget = struct {
    kind: FocusTargetKind,
    pane: *Pane,
    float_index: ?usize,
};

const isFloatRenderableOnTab = float_util.isFloatRenderableOnTab;

pub fn focusDirectionAny(state: *State, dir: layout_mod.Layout.Direction, cursor: ?layout_mod.CursorPos) ?FocusTarget {
    // Universal focus navigation across splits and floats.
    // We pick the best candidate in the requested direction based on distance
    // and alignment. No type priority: floats and splits compete equally.

    const current: *Pane = if (state.activeFloatingIndex()) |idx| blk: {
        if (idx < state.view.floats.items.len) {
            const fp = state.view.floats.items[idx];
            if (isFloatRenderableOnTab(state, fp, state.activeTabIndex())) break :blk fp;
        }
        break :blk state.currentLayout().getFocusedPane() orelse return null;
    } else state.currentLayout().getFocusedPane() orelse return null;

    const origin = cursor orelse blk: {
        const p = current.getCursorPos();
        break :blk layout_mod.CursorPos{ .x = p.x, .y = p.y };
    };

    var best: ?FocusTarget = null;
    var best_score: i64 = std.math.maxInt(i64);

    const weights = struct {
        // Two-tier heuristic:
        // 1) Prefer candidates that overlap the cursor "beam" on the perpendicular axis.
        // 2) Then choose the nearest candidate in the requested direction.
        const BEAM_PENALTY: i64 = 1024 * 1024;

        // Distances.
        const PRIMARY: i64 = 1024;
        const SECONDARY: i64 = 32;
        const CURSOR_L1: i64 = 1;
    };

    const nav = struct {
        fn pane_rect(p: *Pane) directions.Rect {
            // For floats, prefer the border rect if present (matches what user sees).
            if (p.floating and p.border_w > 0 and p.border_h > 0) {
                return .{ .x0 = p.border_x, .y0 = p.border_y, .x1 = p.border_x + p.border_w, .y1 = p.border_y + p.border_h };
            }
            return .{ .x0 = p.x, .y0 = p.y, .x1 = p.x + p.width, .y1 = p.y + p.height };
        }

        fn score(dir_: layout_mod.Layout.Direction, ox: u16, oy: u16, cur: directions.Rect, cand: directions.Rect) ?i64 {
            if (!directions.is_in_direction(dir_, cur, cand)) return null;

            const beam = if (directions.beam_overlaps(dir_, ox, oy, cand)) @as(i64, 0) else 1;

            // Primary distance is from the cursor to the candidate in that direction.
            // This makes "nearest down" work, but without breaking directionality.
            const primary = directions.primary_distance_from_point(dir_, ox, oy, cand) orelse return null;
            const secondary = directions.secondary_distance_from_point(dir_, ox, oy, cand);
            const cursor_l1 = directions.cursor_l1_to_rect(ox, oy, cand);

            return beam * weights.BEAM_PENALTY + primary * weights.PRIMARY + secondary * weights.SECONDARY + cursor_l1 * weights.CURSOR_L1;
        }
    };

    const cur_rect = nav.pane_rect(current);

    // Splits only — floats have dedicated toggle keys so directional
    // navigation skips them.
    var it = state.currentLayout().splitIterator();
    while (it.next()) |sp| {
        const p = sp.*;
        if (p == current) continue;
        const r = nav.pane_rect(p);
        const s = nav.score(dir, origin.x, origin.y, cur_rect, r) orelse continue;
        if (s < best_score) {
            best_score = s;
            best = .{ .kind = .split, .pane = p, .float_index = null };
        }
    }

    return best;
}
