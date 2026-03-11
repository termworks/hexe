const std = @import("std");
const core = @import("core");
const shp = @import("shp");
const vaxis = @import("vaxis");
const Renderer = @import("render_core.zig").Renderer;
const Color = core.style.Color;
const statusbar = @import("statusbar.zig");
const text_width = @import("text_width.zig");
const Pane = @import("pane.zig").Pane;
const Layout = @import("layout.zig").Layout;

pub const TitlePlacement = struct {
    x: u16,
    y: u16,
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

fn toShpStyle(seg: statusbar.RenderedSegment) shp.Style {
    return .{
        .fg = switch (seg.fg) {
            .none => .none,
            .palette => |idx| .{ .palette = idx },
            .rgb => |rgb| .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
        },
        .bg = switch (seg.bg) {
            .none => .none,
            .palette => |idx| .{ .palette = idx },
            .rgb => |rgb| .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
        },
        .bold = seg.bold,
        .italic = seg.italic,
    };
}

fn applyFloatTitleStyleDefaults(style: shp.Style, border_palette: u8) shp.Style {
    var out = style;
    if (out.bg == .none) out.bg = .{ .palette = border_palette };
    if (out.fg == .none) out.fg = .{ .palette = 0 };
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
        for (0..content_height) |row| {
            const y: u16 = @intCast(row);

            // Check if this row actually has a vertical boundary at this x
            // A vertical line should only be drawn where a pane ends (right_edge == x)
            // and that row is within that pane's y range
            var should_draw = false;
            var pane_check = layout.splitIterator();
            while (pane_check.next()) |pane| {
                const right_edge = pane.*.x + pane.*.width;
                if (right_edge == x) {
                    // Check if y is within this pane's vertical range
                    if (y >= pane.*.y and y < pane.*.y + pane.*.height) {
                        should_draw = true;
                        break;
                    }
                }
            }

            if (!should_draw) continue;

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

    // Draw horizontal lines - but only where there's actually a split boundary
    for (h_lines[0..h_line_count]) |y| {
        for (0..term_width) |col| {
            const x: u16 = @intCast(col);

            // Skip if already drawn by vertical line (junction)
            var is_junction = false;
            for (v_lines[0..v_line_count]) |vx| {
                if (x == vx) {
                    is_junction = true;
                    break;
                }
            }
            if (is_junction) continue;

            // Check if this column actually has a horizontal boundary at this y
            // A horizontal line should only be drawn where a pane ends (bottom_edge == y)
            // and that column is within that pane's x range
            var should_draw = false;
            var pane_check = layout.splitIterator();
            while (pane_check.next()) |pane| {
                const bottom_edge = pane.*.y + pane.*.height;
                if (bottom_edge == y) {
                    // Check if x is within this pane's horizontal range
                    if (x >= pane.*.x and x < pane.*.x + pane.*.width) {
                        should_draw = true;
                        break;
                    }
                }
            }

            if (!should_draw) continue;

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
    border_color: core.BorderColor,
    style: ?*const core.FloatStyle,
    ctx: ?*shp.Context,
    query: ?*const core.PaneQuery,
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

    // Render module/segments in border if present.
    if (style) |s| {
        if (s.position) |pos| {
            if (s.title_segments.len > 0 and ctx != null and query != null) {
                const tctx = ctx.?;
                const tq = query.?;

                var total_width: u16 = 0;
                for (s.title_segments) |*seg| {
                    total_width +|= statusbar.calcModuleWidth(tctx, tq, seg);
                }

                const inner_w = floatTitleInnerWidth(w);
                if (inner_w == 0 or total_width == 0) return;
                const place = floatTitlePlacement(x, y, w, h, pos, @min(total_width, inner_w));

                var cur_x = place.x;
                const max_x = x + w -| 2;
                for (s.title_segments) |*seg| {
                    if (cur_x >= max_x) break;
                    cur_x = statusbar.drawModule(renderer, tctx, tq, seg, cur_x, place.y, false);
                }
                return;
            }
        }

        if (s.module) |*module| {
            if (s.position) |pos| {
                // Run the module to get output
                var output_buf: [256]u8 = undefined;
                // If a title is provided, treat the module area as the title widget.
                const output = if (name.len > 0)
                    name
                else
                    statusbar.runSegment(module, &output_buf) catch "";
                if (output.len == 0) return;

                // Render styled output
                const segments = statusbar.renderSegmentOutput(module, output);
                const inner_w = floatTitleInnerWidth(w);
                if (inner_w == 0) return;

                // If module formatting produced no visible text, fallback to raw name.
                if (segments.total_len == 0 and name.len > 0) {
                    const base_style = if (module.outputs.len > 0)
                        shp.Style.parse(module.outputs[0].style)
                    else
                        shp.Style{};
                    const fallback_style = applyFloatTitleStyleDefaults(base_style, color);

                    const fallback_len = @min(inner_w, statusbar.measureText(name));
                    const fallback_place = floatTitlePlacement(x, y, w, h, pos, fallback_len);
                    const clipped_name = text_width.clipTextToWidth(name, inner_w);
                    _ = statusbar.drawStyledText(renderer, fallback_place.x, fallback_place.y, clipped_name, fallback_style);
                    return;
                }

                // Calculate position based on style position
                const unclamped_len: u16 = @intCast(@min(segments.total_len, @as(usize, std.math.maxInt(u16))));
                const total_len: u16 = @min(unclamped_len, inner_w);
                const place = floatTitlePlacement(x, y, w, h, pos, total_len);

                // Draw each segment with its style
                var cur_x = place.x;
                const max_x = x + w -| 2;
                for (segments.items[0..segments.count]) |seg| {
                    if (cur_x >= max_x) break;
                    const remain = max_x - cur_x;
                    const clipped = text_width.clipTextToWidth(seg.text, remain);
                    if (clipped.len == 0) continue;
                    const seg_style = applyFloatTitleStyleDefaults(toShpStyle(seg), color);
                    cur_x = statusbar.drawStyledText(renderer, cur_x, place.y, clipped, seg_style);
                }
            }
        }
    }
}
