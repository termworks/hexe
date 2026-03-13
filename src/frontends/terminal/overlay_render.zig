const std = @import("std");
const shp = @import("shp");
const core = @import("core");
const vaxis = @import("vaxis");
const Renderer = @import("render_core.zig").Renderer;
const statusbar = @import("statusbar.zig");
const text_width = @import("text_width.zig");

const pop = @import("pop");
const overlay = pop.overlay;
const OverlayManager = overlay.OverlayManager;

const Pos = struct { x: u16, y: u16 };

fn putChar(renderer: *Renderer, x: u16, y: u16, cp: u21, fg: core.style.Color, bg: core.style.Color, bold: bool) void {
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

    const style: vaxis.Style = .{ .bold = bold, .fg = fg.toVaxis(), .bg = bg.toVaxis() };
    renderer.setVaxisCell(x, y, .{
        .char = .{ .grapheme = grapheme, .width = 1 },
        .style = style,
    });
}

/// Bounds of a rectangular area to exclude from dimming
pub const Bounds = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,

    pub fn contains(self: Bounds, px: u16, py: u16) bool {
        return px >= self.x and px < self.x + self.w and
            py >= self.y and py < self.y + self.h;
    }
};

/// Apply dimming effect to the entire screen, except the focused pane.
/// Preserve existing colors and reduce contrast instead of forcing fixed palette colors.
pub fn applyDimEffect(renderer: *Renderer, width: u16, height: u16, exclude: ?Bounds) void {
    for (0..height) |yi| {
        for (0..width) |xi| {
            const x: u16 = @intCast(xi);
            const y: u16 = @intCast(yi);

            // Skip the focused pane area
            if (exclude) |bounds| {
                if (bounds.contains(x, y)) continue;
            }

            var cell = renderer.getVaxisCell(x, y) orelse continue;
            cell.style.dim = true;

            // Dim background while preserving its original color model.
            switch (cell.style.bg) {
                .default => {},
                .index => |p| {
                    if (p != 0 and p != 236 and p != 238) {
                        cell.style.bg = .{ .index = if (p >= 8) 238 else 236 };
                    }
                },
                .rgb => |rgb| {
                    cell.style.bg = .{ .rgb = .{
                        @intCast((@as(u16, rgb[0]) * 70) / 100),
                        @intCast((@as(u16, rgb[1]) * 70) / 100),
                        @intCast((@as(u16, rgb[2]) * 70) / 100),
                    } };
                },
            }
            renderer.setVaxisCell(x, y, cell);
        }
    }
}

/// Render all overlays to the screen.
pub fn renderOverlays(
    renderer: *Renderer,
    overlays: *OverlayManager,
    screen_width: u16,
    screen_height: u16,
    status_height: u16,
    focused_pane_bounds: ?Bounds,
) void {
    const content_height = screen_height - status_height;

    // Apply dimming if modal overlay is active (dims entire screen including status bar)
    if (overlays.shouldDim()) {
        applyDimEffect(renderer, screen_width, screen_height, focused_pane_bounds);
    }

    // Render pane select labels
    if (overlays.isPaneSelectActive()) {
        renderPaneSelectLabels(renderer, overlays);
    }

    // Render resize info
    if (overlays.isResizeInfoActive()) {
        renderResizeInfo(renderer, overlays);
    }

    // Render keycast
    if (overlays.keycast.hasContent()) {
        renderKeycast(renderer, overlays, screen_width, content_height);
    }

    // Render generic overlays
    for (overlays.getOverlays()) |ov| {
        renderOverlay(renderer, ov, screen_width, content_height);
    }
}

/// Render pane select mode labels (big ASCII art numbers centered on each pane)
fn renderPaneSelectLabels(renderer: *Renderer, overlays: *OverlayManager) void {
    for (overlays.pane_select.getLabels()) |pl| {
        // Get the big digit pattern
        const digit = overlay.digits.getDigit(pl.label) orelse continue;

        const digit_w = overlay.digits.WIDTH;
        const digit_h = overlay.digits.HEIGHT;
        const padding: u16 = 1;
        const box_w = digit_w + padding * 2;
        const box_h = digit_h + padding * 2;

        // Check if pane is big enough for the digit
        if (pl.width < box_w or pl.height < box_h) {
            // Fall back to single character for small panes
            const cx = pl.x + pl.width / 2;
            const cy = pl.y + pl.height / 2;
            putChar(renderer, cx, cy, pl.label, .{ .palette = 0 }, .{ .palette = 1 }, true);
            continue;
        }

        // Center the box in the pane
        const box_x = pl.x + (pl.width -| box_w) / 2;
        const box_y = pl.y + (pl.height -| box_h) / 2;

        // Draw background box
        for (0..box_h) |dy| {
            for (0..box_w) |dx| {
                const x = box_x + @as(u16, @intCast(dx));
                const y = box_y + @as(u16, @intCast(dy));
                putChar(renderer, x, y, ' ', .{ .palette = 0 }, .{ .palette = 1 }, false);
            }
        }

        // Draw the digit pattern using full block characters
        const digit_x = box_x + padding;
        const digit_y = box_y + padding;
        for (0..digit_h) |dy| {
            for (0..digit_w) |dx| {
                const ch = digit[dy][dx];
                if (ch != ' ') {
                    const x = digit_x + @as(u16, @intCast(dx));
                    const y = digit_y + @as(u16, @intCast(dy));
                    putChar(renderer, x, y, ch, .{ .palette = 0 }, .{ .palette = 1 }, false);
                }
            }
        }
    }
}

/// Render resize info overlay
fn renderResizeInfo(renderer: *Renderer, overlays: *OverlayManager) void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}x{d} @ {d},{d}", .{
        overlays.resize_info_width,
        overlays.resize_info_height,
        overlays.resize_info_x,
        overlays.resize_info_y,
    }) catch return;

    const text_len: u16 = statusbar.measureText(text);
    const padding: u16 = 1;
    const box_width = text_len + padding * 2;
    const box_height: u16 = 1;

    const cx = overlays.resize_info_x + overlays.resize_info_width / 2;
    const cy = overlays.resize_info_y + overlays.resize_info_height / 2;

    const box_x = cx -| (box_width / 2);
    const box_y = cy -| (box_height / 2);

    // Draw background
    for (0..box_width) |dx| {
        const x = box_x + @as(u16, @intCast(dx));
        putChar(renderer, x, box_y, ' ', .{ .palette = 0 }, .{ .palette = 1 }, false);
    }

    // Draw text
    _ = statusbar.drawStyledText(renderer, box_x + padding, box_y, text, textStyle(.{ .palette = 0 }, .{ .palette = 1 }, false));
}

/// Render keycast history in bottom-right corner
fn renderKeycast(renderer: *Renderer, overlays: *const OverlayManager, screen_width: u16, content_height: u16) void {
    const keycast_state = &overlays.keycast;
    const entries = keycast_state.getEntries();
    if (entries.len == 0) return;

    const margin: u16 = 2;
    var y: u16 = switch (overlays.keycast_position) {
        .topleft, .topright => margin,
        .center => content_height / 2 -| @as(u16, @intCast(entries.len / 2)),
        .bottomleft, .bottomright => content_height -| margin -| @as(u16, @intCast(entries.len)),
    };

    for (entries) |entry| {
        const text = entry.getText();
        const text_len: u16 = statusbar.measureText(text);
        const padding: u16 = 1;
        const box_width = text_len + padding * 2;

        const box_x: u16 = switch (overlays.keycast_position) {
            .topleft, .bottomleft => margin,
            .center => screen_width / 2 -| box_width / 2,
            .topright, .bottomright => screen_width -| margin -| box_width,
        };

        // Draw background
        for (0..box_width) |dx| {
            const x = box_x + @as(u16, @intCast(dx));
            putChar(renderer, x, y, ' ', .{ .palette = 15 }, .{ .palette = 238 }, false);
        }

        // Draw text
        _ = statusbar.drawStyledText(renderer, box_x + padding, y, text, textStyle(.{ .palette = 15 }, .{ .palette = 238 }, true));

        y += 1;
    }
}

/// Render a generic overlay
fn renderOverlay(renderer: *Renderer, ov: overlay.Overlay, screen_width: u16, screen_height: u16) void {
    const clipped = text_width.clipTextToWidth(ov.text, 80);
    const text_len: u16 = statusbar.measureText(clipped);
    if (text_len == 0) return;

    const box_width = text_len + @as(u16, ov.padding_x) * 2;
    const box_height: u16 = 1 + @as(u16, ov.padding_y) * 2;

    const pos: Pos = switch (ov.position) {
        .corner => |c| calculateCornerPosition(c.anchor, c.offset_x, c.offset_y, box_width, box_height, screen_width, screen_height),
        .absolute => |a| .{ .x = a.x, .y = a.y },
        .pane_center => .{ .x = screen_width / 2 -| box_width / 2, .y = screen_height / 2 -| box_height / 2 },
    };

    // Draw background
    for (0..box_height) |dy| {
        for (0..box_width) |dx| {
            const x = pos.x + @as(u16, @intCast(dx));
            const y = pos.y + @as(u16, @intCast(dy));
            putChar(renderer, x, y, ' ', .{ .palette = ov.fg }, .{ .palette = ov.bg }, false);
        }
    }

    // Draw text
    const text_x = pos.x + ov.padding_x;
    const text_y = pos.y + ov.padding_y;
    _ = statusbar.drawStyledText(renderer, text_x, text_y, clipped, textStyle(.{ .palette = ov.fg }, .{ .palette = ov.bg }, ov.bold));
}

fn calculateCornerPosition(
    anchor: overlay.Corner,
    offset_x: u16,
    offset_y: u16,
    box_width: u16,
    box_height: u16,
    screen_width: u16,
    screen_height: u16,
) Pos {
    return switch (anchor) {
        .top_left => .{ .x = offset_x, .y = offset_y },
        .top_right => .{ .x = screen_width -| box_width -| offset_x, .y = offset_y },
        .bottom_left => .{ .x = offset_x, .y = screen_height -| box_height -| offset_y },
        .bottom_right => .{ .x = screen_width -| box_width -| offset_x, .y = screen_height -| box_height -| offset_y },
        .center => .{ .x = screen_width / 2 -| box_width / 2, .y = screen_height / 2 -| box_height / 2 },
    };
}
fn textStyle(fg: core.style.Color, bg: core.style.Color, bold: bool) shp.Style {
    return .{
        .fg = switch (fg) {
            .none => .none,
            .palette => |idx| .{ .palette = idx },
            .rgb => |rgb| .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
        },
        .bg = switch (bg) {
            .none => .none,
            .palette => |idx| .{ .palette = idx },
            .rgb => |rgb| .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
        },
        .bold = bold,
    };
}
