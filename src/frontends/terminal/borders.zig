const std = @import("std");
const core = @import("core");
const vaxis = @import("vaxis");
const Renderer = @import("render_core.zig").Renderer;
const Color = core.style.Color;
const statusbar = @import("statusbar.zig");
const text_width = @import("text_width.zig");
const Pane = @import("pane.zig").Pane;
const Layout = @import("layout.zig").Layout;
const State = @import("state.zig").State;

pub const TitlePlacement = struct {
    x: u16,
    y: u16,
};

/// Ordered chip indices for a float family (parent = 0, children = 1..9) and
/// which chip is currently displayed. `len < 2` means a lone float (no chips).
pub const FloatFamilyChips = struct {
    indices: [16]u8 = undefined,
    len: usize = 0,
    active_index: u8 = 0,

    pub fn slice(self: *const FloatFamilyChips) []const u8 {
        return self.indices[0..self.len];
    }
};

pub fn floatTitleInnerWidth(w: u16) u16 {
    return w -| 4;
}

pub fn floatTitlePlacement(x: u16, y: u16, w: u16, h: u16, pos: core.FloatStylePosition, total_len: u16) TitlePlacement {
    return switch (pos) {
        .topleft => .{ .x = x + 2, .y = y },
        .topcenter => .{ .x = x + (w -| total_len) / 2, .y = y },
        .topright => .{ .x = x + w -| 2 -| total_len, .y = y },
        .bottomleft => .{ .x = x + 2, .y = y + h - 1 },
        .bottomcenter => .{ .x = x + (w -| total_len) / 2, .y = y + h - 1 },
        .bottomright => .{ .x = x + w -| 2 -| total_len, .y = y + h - 1 },
    };
}

fn contrastFgForBg(bg_palette: u8) u8 {
    return if (bg_palette == 0 or (bg_palette >= 232 and bg_palette <= 241)) 250 else 0;
}

fn applyFloatTitleStyleDefaults(style: core.style.Style, border_palette: u8) core.style.Style {
    var out = style;
    if (out.bg == .none) out.bg = .{ .palette = border_palette };
    if (out.fg == .none) out.fg = .{ .palette = contrastFgForBg(border_palette) };
    return out;
}

fn encodeCodepointUtf8(cp: u21, out: *[4]u8) []const u8 {
    const n = std.unicode.utf8Encode(cp, out) catch {
        out[0] = '?';
        return out[0..1];
    };
    return out[0..n];
}

fn putChar(renderer: *Renderer, x: u16, y: u16, cp: u21, fg: ?Color, bg: ?Color, bold: bool) void {
    var cp_buf: [4]u8 = undefined;
    const cp_bytes = encodeCodepointUtf8(cp, &cp_buf);

    var style: vaxis.Style = .{ .bold = bold };
    if (fg) |c| style.fg = c.toVaxis();
    if (bg) |c| style.bg = c.toVaxis();

    renderer.setVaxisCell(x, y, .{
        .char = .{ .grapheme = cp_bytes, .width = 1 },
        .style = style,
    });
}

fn drawBorderFrame(renderer: *Renderer, x: u16, y: u16, w: u16, h: u16, fg: Color, bg: Color, glyph_chars: [6]u21) void {
    if (w == 0 or h == 0) return;

    // Fill background.
    var yy: u16 = 0;
    while (yy < h) : (yy += 1) {
        var xx: u16 = 0;
        while (xx < w) : (xx += 1) {
            putChar(renderer, x + xx, y + yy, ' ', null, bg, false);
        }
    }

    if (w == 1 and h == 1) {
        putChar(renderer, x, y, glyph_chars[0], fg, bg, false);
        return;
    }

    const top_left = glyph_chars[0];
    const horizontal = glyph_chars[1];
    const top_right = glyph_chars[2];
    const vertical = glyph_chars[3];
    const bottom_right = glyph_chars[4];
    const bottom_left = glyph_chars[5];

    // Corners.
    putChar(renderer, x, y, top_left, fg, bg, false);
    if (w > 1) putChar(renderer, x + w - 1, y, top_right, fg, bg, false);
    if (h > 1) {
        putChar(renderer, x, y + h - 1, bottom_left, fg, bg, false);
        if (w > 1) putChar(renderer, x + w - 1, y + h - 1, bottom_right, fg, bg, false);
    }

    // Horizontal edges.
    if (w > 2) {
        var tx: u16 = 1;
        while (tx < w - 1) : (tx += 1) {
            putChar(renderer, x + tx, y, horizontal, fg, bg, false);
            if (h > 1) putChar(renderer, x + tx, y + h - 1, horizontal, fg, bg, false);
        }
    }

    // Vertical edges.
    if (h > 2) {
        var ty: u16 = 1;
        while (ty < h - 1) : (ty += 1) {
            putChar(renderer, x, y + ty, vertical, fg, bg, false);
            if (w > 1) putChar(renderer, x + w - 1, y + ty, vertical, fg, bg, false);
        }
    }
}

/// Draw split borders between panes
/// A contiguous run of rows (or columns) that a border line covers.
const Span = struct { start: u16, end: u16 };

pub fn drawSplitBorders(
    renderer: *Renderer,
    layout: *Layout,
    splits_cfg: *const core.config.SplitsConfig,
    term_width: u16,
    content_height: u16,
) void {
    const write_split_cell = struct {
        fn go(
            renderer_in: *Renderer,
            x: u16,
            y: u16,
            cp: u21,
            color: u8,
        ) void {
            var cp_buf: [4]u8 = undefined;
            const cp_bytes = encodeCodepointUtf8(cp, &cp_buf);
            renderer_in.setVaxisCell(x, y, .{
                .char = .{ .grapheme = cp_bytes, .width = 1 },
                .style = .{ .fg = .{ .index = color } },
            });
        }
    }.go;
    // Get characters and color from config
    const v_char: u21 = if (splits_cfg.style) |s| s.vertical else splits_cfg.separator_v;
    const h_char: u21 = if (splits_cfg.style) |s| s.horizontal else splits_cfg.separator_h;
    const color: u8 = splits_cfg.color.passive; // splits use passive color

    // Junction characters (only used if style is set)
    const cross_char: u21 = if (splits_cfg.style) |s| s.cross else v_char;
    const top_t: u21 = if (splits_cfg.style) |s| s.top_t else v_char;
    const bottom_t: u21 = if (splits_cfg.style) |s| s.bottom_t else v_char;
    const left_t: u21 = if (splits_cfg.style) |s| s.left_t else h_char;
    const right_t: u21 = if (splits_cfg.style) |s| s.right_t else h_char;

    // Collect vertical and horizontal line positions
    var v_lines: [64]u16 = undefined;
    var v_line_count: usize = 0;
    var h_lines: [64]u16 = undefined;
    var h_line_count: usize = 0;

    var pane_it = layout.splitIterator();
    while (pane_it.next()) |pane| {
        const right_edge = pane.*.x + pane.*.width;
        const bottom_edge = pane.*.y + pane.*.height;

        // Record vertical line position
        if (right_edge < term_width and v_line_count < v_lines.len) {
            // Check if already recorded
            var found = false;
            for (v_lines[0..v_line_count]) |x| {
                if (x == right_edge) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                v_lines[v_line_count] = right_edge;
                v_line_count += 1;
            }
        }

        // Record horizontal line position
        if (bottom_edge < content_height and h_line_count < h_lines.len) {
            var found = false;
            for (h_lines[0..h_line_count]) |y| {
                if (y == bottom_edge) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                h_lines[h_line_count] = bottom_edge;
                h_line_count += 1;
            }
        }
    }

    // Draw vertical lines - but only where there's actually a split boundary
    for (v_lines[0..v_line_count]) |x| {
        // Collect the row spans this line covers in ONE pass over the panes.
        //
        // This used to re-run splitIterator() for every (line, row) pair, i.e.
        // O(lines x rows x panes): with 20 splits on a 200x50 terminal that is
        // ~100k hashmap iterations per frame, and the render is not
        // region-limited so it happened on any frame at all.
        var spans: [64]Span = undefined;
        var span_count: usize = 0;
        var pane_check = layout.splitIterator();
        while (pane_check.next()) |pane| {
            if (pane.*.x + pane.*.width != x) continue;
            if (span_count >= spans.len) break;
            spans[span_count] = .{
                .start = pane.*.y,
                .end = @min(pane.*.y + pane.*.height, @as(u16, @intCast(content_height))),
            };
            span_count += 1;
        }

        for (spans[0..span_count]) |span| {
            var y = span.start;
            while (y < span.end) : (y += 1) {
                var char = v_char;

                // Check for junctions with horizontal lines
                if (splits_cfg.style != null) {
                    for (h_lines[0..h_line_count]) |hy| {
                        if (y == hy) {
                            // Check if this is a cross, top_t, or bottom_t
                            const at_top = (y == 0);
                            const at_bottom = (y == content_height - 1);
                            if (at_top) {
                                char = top_t;
                            } else if (at_bottom) {
                                char = bottom_t;
                            } else {
                                char = cross_char;
                            }
                            break;
                        }
                    }
                }

                write_split_cell(renderer, x, y, char, color);
            }
        }
    }

    // Draw horizontal lines - but only where there's actually a split boundary
    for (h_lines[0..h_line_count]) |y| {
        // Same one-pass span collection as the vertical case above.
        var spans: [64]Span = undefined;
        var span_count: usize = 0;
        var pane_check = layout.splitIterator();
        while (pane_check.next()) |pane| {
            if (pane.*.y + pane.*.height != y) continue;
            if (span_count >= spans.len) break;
            spans[span_count] = .{
                .start = pane.*.x,
                .end = @min(pane.*.x + pane.*.width, term_width),
            };
            span_count += 1;
        }

        for (spans[0..span_count]) |span| {
            var x = span.start;
            while (x < span.end) : (x += 1) {
                // Skip if already drawn by a vertical line (junction).
                var is_junction = false;
                for (v_lines[0..v_line_count]) |vx| {
                    if (x == vx) {
                        is_junction = true;
                        break;
                    }
                }
                if (is_junction) continue;

                var char = h_char;

                // Check for edge junctions
                if (splits_cfg.style != null) {
                    const at_left = (x == 0);
                    const at_right = (x == term_width - 1);
                    if (at_left) {
                        char = left_t;
                    } else if (at_right) {
                        char = right_t;
                    }
                }

                write_split_cell(renderer, x, y, char, color);
            }
        }
    }
}

/// Draw scroll indicator at top of pane when scrolled
pub fn drawScrollIndicator(renderer: *Renderer, pane_x: u16, pane_y: u16, pane_width: u16) void {
    // Display a scroll indicator at top-right of pane
    const indicator_chars = [_]u21{ ' ', 0x25b2, 0x25b2, 0x25b2, ' ' };

    // Position at top-right corner (inside pane bounds)
    const indicator_len: u16 = 5;
    const x_pos = pane_x + pane_width -| indicator_len;

    // Yellow background (palette 3), black text (palette 0)
    for (indicator_chars, 0..) |char, i| {
        putChar(renderer, x_pos + @as(u16, @intCast(i)), pane_y, char, .{ .palette = 0 }, .{ .palette = 3 }, false);
    }
}

/// Draw border around a floating pane
pub fn drawFloatingBorder(
    renderer: *Renderer,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    active: bool,
    name: []const u8,
    family: FloatFamilyChips,
    border_color: core.BorderColor,
    style: ?*const core.FloatStyle,
    state: *const State,
) void {
    // Optional shadow (draw first so border overlays it)
    if (style) |s| {
        if (s.shadow_color) |sc| {
            const shadow_bg: Color = .{ .palette = sc };
            const shadow_fg: Color = .{ .palette = sc };
            const sx: u16 = x + w;
            const sy: u16 = y + h;

            // Right shadow: start 1 row below the top border, and stop 1 row
            // above the bottom border so the corner is "owned" by the bottom
            // shadow.
            if (h > 2) {
                var row: u16 = 1;
                while (row < h - 1) : (row += 1) {
                    putChar(renderer, sx, y + row, ' ', null, shadow_bg, false);
                }
            }

            // Add a small "cap" next to the bottom border so there is no
            // visible gap between the side shadow and the bottom shadow.
            if (h > 1) {
                putChar(renderer, sx, y + h - 1, ' ', null, shadow_bg, false);
            }

            // Bottom shadow: start 1 col after left border, and include the
            // corner cell (so it extends one further than the right shadow).
            var col: u16 = 1;
            while (col <= w) : (col += 1) {
                // Use upper-half block for bottom shadow so it feels visually
                // closer in "weight" to the 1-col side shadow.
                putChar(renderer, x + col, sy, 0x2580, shadow_fg, null, false);
            }
            // Corner is already drawn by the bottom shadow (col == w).
        }
    }

    const color = if (active) border_color.active else border_color.passive;
    const fg: Color = .{ .palette = color };
    // Do not rely on SGR bold for active borders.
    // Many terminals render bold + low palette indices as the "bright" variant
    // (e.g. palette 1 looks like palette 9). We want the configured palette
    // index to be respected.
    const bold = false;

    // Get border characters from style or use defaults
    const top_left: u21 = if (style) |s| s.top_left else 0x256D;
    const top_right: u21 = if (style) |s| s.top_right else 0x256E;
    const bottom_left: u21 = if (style) |s| s.bottom_left else 0x2570;
    const bottom_right: u21 = if (style) |s| s.bottom_right else 0x256F;
    const horizontal: u21 = if (style) |s| s.horizontal else 0x2500;
    const vertical: u21 = if (style) |s| s.vertical else 0x2502;

    _ = bold;
    drawBorderFrame(renderer, x, y, w, h, fg, .none, .{ top_left, horizontal, top_right, vertical, bottom_right, bottom_left });

    // The title is painted externally; hexe only places and clips it.
    if (style) |s| {
        const pos = s.position orelse return;
        const inner_w = floatTitleInnerWidth(w);
        if (inner_w == 0) return;

        var horiz_buf: [4]u8 = undefined;
        const horiz_bytes = encodeCodepointUtf8(horizontal, &horiz_buf);

        const runs = statusbar.titleRunsWithFamily(state, name, inner_w, true, active, family, horiz_bytes);
        const runs_len = @min(statusbar.runsWidth(runs), inner_w);
        if (runs_len > 0) {
            const place = floatTitlePlacement(x, y, w, h, pos, runs_len);
            _ = statusbar.drawRuns(renderer, place.x, place.y, runs, runs_len);
            return;
        }

        // Nothing from the painter yet: draw the raw title (and family chip
        // pills when the float has sub-floats) so a float is never nameless.
        if (name.len == 0 and family.len < 2) return;
        const has_chips = family.len >= 2;
        const title_w: u16 = if (name.len > 0) statusbar.measureText(name) + 2 else 0;
        var chips_w: u16 = 0;
        if (has_chips) {
            // `══` bridge (2 cells) + ` <d> ` (3 cells each) + `|` separators (1 cell each)
            if (title_w > 0) chips_w += 2;
            for (family.slice(), 0..) |idx, i| {
                if (i > 0) chips_w += 1;
                chips_w += if (idx >= 10) 4 else 3;
            }
        }
        const total_w = @min(inner_w, title_w +| chips_w);
        if (total_w == 0) return;

        const place = floatTitlePlacement(x, y, w, h, pos, total_w);
        const limit_x = place.x +| inner_w;
        var cx = place.x;

        const title_style = applyFloatTitleStyleDefaults(.{}, color);
        if (name.len > 0 and cx < limit_x) {
            var padded_buf: [160]u8 = undefined;
            const padded = std.fmt.bufPrint(&padded_buf, " {s} ", .{name}) catch name;
            const clipped = text_width.clipTextToWidth(padded, limit_x -| cx);
            cx = statusbar.drawStyledText(renderer, cx, place.y, clipped, title_style);
        }

        if (has_chips and cx < limit_x) {
            const border_style = core.style.Style{ .fg = .{ .palette = color }, .bg = .none };
            const chip_selected_style = core.style.Style{
                .fg = .{ .palette = contrastFgForBg(color) },
                .bg = .{ .palette = color },
                .bold = true,
            };
            const chip_inactive_style = core.style.Style{
                .fg = .{ .palette = 250 },
                .bg = .{ .palette = 237 },
            };

            if (title_w > 0) {
                var bridge_i: usize = 0;
                while (bridge_i < 2 and cx < limit_x) : (bridge_i += 1) {
                    putChar(renderer, cx, place.y, horizontal, .{ .palette = color }, null, false);
                    cx += 1;
                }
            }

            for (family.slice(), 0..) |idx, i| {
                if (cx >= limit_x) break;
                if (i > 0) {
                    cx = statusbar.drawStyledText(renderer, cx, place.y, "|", border_style);
                    if (cx >= limit_x) break;
                }
                var chip_buf: [8]u8 = undefined;
                const chip_text = std.fmt.bufPrint(&chip_buf, " {d} ", .{idx}) catch continue;
                const clipped = text_width.clipTextToWidth(chip_text, limit_x -| cx);
                const chip_st = if (idx == family.active_index) chip_selected_style else chip_inactive_style;
                cx = statusbar.drawStyledText(renderer, cx, place.y, clipped, chip_st);
            }
        }
    }
}
