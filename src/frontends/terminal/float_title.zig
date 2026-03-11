const std = @import("std");
const shp = @import("shp");
const text_width = @import("text_width.zig");
const vaxis = @import("vaxis");

const core = @import("core");

const Pane = @import("pane.zig").Pane;
const Renderer = @import("render_core.zig").Renderer;
const Color = core.style.Color;
const statusbar = @import("statusbar.zig");
const borders = @import("borders.zig");

fn putChar(renderer: *Renderer, x: u16, y: u16, cp: u21, fg: ?Color, bg: ?Color, bold: bool) void {
    var buf: [4]u8 = undefined;
    const grapheme: []const u8 = if (cp < 128)
        buf[0..blk: {
            buf[0] = @intCast(cp);
            break :blk 1;
        }]
    else blk: {
        const n = std.unicode.utf8Encode(cp, &buf) catch return;
        break :blk buf[0..n];
    };

    var style: vaxis.Style = .{ .bold = bold };
    if (fg) |c| style.fg = c.toVaxis();
    if (bg) |c| style.bg = c.toVaxis();

    renderer.setVaxisCell(x, y, .{
        .char = .{ .grapheme = grapheme, .width = 1 },
        .style = style,
    });
}

pub const TitleRect = struct {
    x: u16,
    y: u16,
    w: u16,
};

pub fn getTitleRect(pane: *const Pane) ?TitleRect {
    const title = pane.float_title orelse return null;
    if (title.len == 0) return null;

    const style = pane.float_style orelse return null;
    const module = style.module orelse return null;
    const pos = style.position orelse return null;

    const outer_x = pane.border_x;
    const outer_y = pane.border_y;
    const outer_w = pane.border_w;
    const outer_h = pane.border_h;
    if (outer_w < 3 or outer_h < 3) return null;

    const inner_w = borders.floatTitleInnerWidth(outer_w);
    if (inner_w == 0) return null;

    const segments = statusbar.renderSegmentOutput(&module, title);
    const total_len: u16 = @intCast(@min(@as(usize, inner_w), segments.total_len));
    if (total_len == 0) return null;

    const place = borders.floatTitlePlacement(outer_x, outer_y, outer_w, outer_h, pos, total_len);

    return .{ .x = place.x, .y = place.y, .w = total_len };
}

pub fn hitTestTitle(pane: *const Pane, x: u16, y: u16) bool {
    const r = getTitleRect(pane) orelse return false;
    if (y != r.y) return false;
    return x >= r.x and x < r.x + r.w;
}

/// Draw an in-place title editor overlay.
///
/// This draws a 1-line highlighted box at the same border position as the float
/// title widget. The box width follows the current buffer length.
pub fn drawTitleEditor(renderer: *Renderer, pane: *const Pane, buf: []const u8) void {
    const style = pane.float_style orelse return;
    const pos = style.position orelse return;

    const outer_x = pane.border_x;
    const outer_y = pane.border_y;
    const outer_w = pane.border_w;
    const outer_h = pane.border_h;
    if (outer_w < 3 or outer_h < 3) return;

    // Cap edit box to fit inside the border.
    const max_w: u16 = borders.floatTitleInnerWidth(outer_w);
    if (max_w == 0) return;

    const want_w: u16 = @min(max_w, @max(@as(u16, 1), statusbar.measureText(buf) + 1));

    const place = borders.floatTitlePlacement(outer_x, outer_y, outer_w, outer_h, pos, want_w);

    const bg: Color = .{ .palette = pane.border_color.active };
    const fg: Color = .{ .palette = 0 };
    const text_style = shp.Style{ .fg = .{ .palette = 0 }, .bg = .{ .palette = pane.border_color.active }, .bold = true };

    // Background box.
    var i: u16 = 0;
    while (i < want_w) : (i += 1) {
        putChar(renderer, place.x + i, place.y, ' ', fg, bg, false);
    }

    // Text + cursor.
    const clipped = text_width.clipTextToWidth(buf, want_w - 1);
    const cursor_x = statusbar.drawStyledText(renderer, place.x, place.y, clipped, text_style);
    // Cursor marker at end (ASCII for portability).
    putChar(renderer, cursor_x, place.y, '|', fg, bg, true);
}
