const std = @import("std");
const vaxis = @import("vaxis");
const CursorInfo = @import("render_core.zig").CursorInfo;

fn mapCursorShape(style: u8) vaxis.Cell.CursorShape {
    return switch (style) {
        1 => .block_blink,
        2 => .block,
        3 => .underline_blink,
        4 => .underline,
        5 => .beam_blink,
        6 => .beam,
        else => .default,
    };
}

pub fn initVaxisForSize(allocator: std.mem.Allocator, vx: *vaxis.Vaxis, width: u16, height: u16) !void {
    if (width == 0 or height == 0) return;
    vx.screen = try vaxis.Screen.init(allocator, .{
        .rows = height,
        .cols = width,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    vx.screen_last.deinit(allocator);
    vx.screen_last = try vaxis.AllocatingScreen.init(allocator, width, height);
}

pub fn resizeVaxisForSize(allocator: std.mem.Allocator, vx: *vaxis.Vaxis, width: u16, height: u16) !void {
    // Screen.init resets width_method to its .wcwidth default, and capability
    // detection is one-shot at startup (host.zig / loop_input.zig) with nothing
    // to re-apply it. Replacing the screen therefore silently downgraded
    // grapheme measurement for the rest of the session, so every emoji and wide
    // character misaligned by a column after the first resize. Carry the
    // detected settings across.
    const width_method = vx.screen.width_method;
    const cursor_shape = vx.screen.cursor_shape;
    const mouse_shape = vx.screen.mouse_shape;

    vx.screen.deinit(allocator);
    vx.screen = try vaxis.Screen.init(allocator, .{
        .rows = height,
        .cols = width,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    vx.screen.width_method = width_method;
    vx.screen.cursor_shape = cursor_shape;
    vx.screen.mouse_shape = mouse_shape;

    vx.screen_last.deinit(allocator);
    vx.screen_last = try vaxis.AllocatingScreen.init(allocator, width, height);
}

pub fn renderFrame(vx: *vaxis.Vaxis, stdout: std.fs.File, cursor: CursorInfo, force_full: bool) !void {
    vx.screen.cursor_vis = cursor.visible;
    if (cursor.visible) {
        vx.screen.cursor = .{ .col = cursor.x, .row = cursor.y };
        vx.screen.cursor_shape = mapCursorShape(cursor.style);
    }

    if (force_full) {
        vx.refresh = true;
    }

    var write_buf: [8192]u8 = undefined;
    var writer = stdout.writer(&write_buf);
    try vx.render(&writer.interface);
    try writer.interface.flush();

    vx.refresh = false;
}
