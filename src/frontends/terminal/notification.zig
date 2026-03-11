const std = @import("std");
const pop = @import("pop");
const core = @import("core");
const vaxis = @import("vaxis");
const Renderer = @import("render_core.zig").Renderer;
const Color = core.style.Color;
const text_width = @import("text_width.zig");

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

pub fn renderFull(self: *pop.notification.NotificationManager, renderer: *Renderer, screen_width: u16, screen_height: u16) void {
    renderInBounds(self, renderer, 0, 0, screen_width, screen_height, true);
}

pub fn renderInBounds(
    self: *pop.notification.NotificationManager,
    renderer: *Renderer,
    bounds_x: u16,
    bounds_y: u16,
    bounds_width: u16,
    bounds_height: u16,
    is_mux_realm: bool,
) void {
    const notif = self.current orelse return;
    const style = notif.style;

    const max_msg_width = bounds_width -| style.padding_x * 2;
    if (max_msg_width == 0) return;

    const clipped = text_width.clipTextToWidth(notif.message, max_msg_width);
    const msg_width = vaxis.gwidth.gwidth(clipped, .unicode);
    if (msg_width == 0) return;

    const box_width = msg_width + style.padding_x * 2;
    const box_height: u16 = 1 + style.padding_y * 2;

    const x: u16 = switch (style.alignment) {
        .left => bounds_x,
        .center => bounds_x + (bounds_width -| box_width) / 2,
        .right => bounds_x + bounds_width -| box_width,
    };

    const y: u16 = if (is_mux_realm)
        bounds_y + style.offset
    else
        bounds_y + bounds_height -| box_height -| style.offset;

    var yi: u16 = 0;
    while (yi < box_height) : (yi += 1) {
        var xi: u16 = 0;
        while (xi < box_width) : (xi += 1) {
            putChar(renderer, x + xi, y + yi, ' ', toRenderColor(style.fg), toRenderColor(style.bg), false);
        }
    }

    const text_y = y + style.padding_y;
    const text_x = x + style.padding_x;
    renderTextWithVaxis(renderer, text_x, text_y, clipped, style);
}

fn toVaxisStyle(style: pop.notification.Style) vaxis.Style {
    return .{
        .fg = switch (style.fg) {
            .none => .default,
            .palette => |idx| .{ .index = idx },
            .rgb => |rgb| .{ .rgb = .{ rgb.r, rgb.g, rgb.b } },
        },
        .bg = switch (style.bg) {
            .none => .default,
            .palette => |idx| .{ .index = idx },
            .rgb => |rgb| .{ .rgb = .{ rgb.r, rgb.g, rgb.b } },
        },
        .bold = style.bold,
    };
}

fn renderTextWithVaxis(renderer: *Renderer, start_x: u16, y: u16, text: []const u8, style: pop.notification.Style) void {
    const width = vaxis.gwidth.gwidth(text, .unicode);
    if (width == 0) return;

    const screen_w = renderer.screenWidth();
    if (start_x >= screen_w) return;
    const row = renderer.vx.window().child(.{
        .x_off = @intCast(start_x),
        .y_off = @intCast(y),
        .width = screen_w - start_x,
        .height = 1,
    });
    const seg = vaxis.Segment{ .text = text, .style = toVaxisStyle(style) };
    _ = row.print(&.{seg}, .{ .row_offset = 0, .col_offset = 0, .wrap = .none, .commit = true });
}

fn toRenderColor(c: pop.notification.Color) Color {
    return switch (c) {
        .none => .none,
        .palette => |idx| .{ .palette = idx },
        .rgb => |rgb| .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
    };
}
