const std = @import("std");
const pop = @import("pop");
const core = @import("core");
const shp = @import("shp");
const vaxis = @import("vaxis");
const Renderer = @import("render_core.zig").Renderer;
const Color = core.style.Color;
const statusbar = @import("statusbar.zig");
const text_width = @import("text_width.zig");

fn putChar(renderer: *Renderer, x: u16, y: u16, cp: u21, fg: Color, bg: Color, bold: bool) void {
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

fn textStyle(fg: Color, bg: Color, bold: bool) shp.Style {
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

fn drawPopupFrame(renderer: *Renderer, x: u16, y: u16, w: u16, h: u16, fg: Color, bg: Color, title: ?[]const u8) void {
    if (w == 0 or h == 0) return;

    const root = renderer.vx.window().child(.{
        .x_off = @intCast(x),
        .y_off = @intCast(y),
        .width = w,
        .height = h,
    });

    const base_style: vaxis.Style = .{ .fg = fg.toVaxis(), .bg = bg.toVaxis() };
    root.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = base_style });
    _ = root.child(.{
        .width = w,
        .height = h,
        .border = .{
            .where = .all,
            .glyphs = .single_square,
            .style = base_style,
        },
    });

    if (title) |t| {
        if (h > 0 and w > 4) {
            const clipped = text_width.clipTextToWidth(t, w - 4);
            const title_segments = &[_]vaxis.Segment{
                .{ .text = " ", .style = base_style },
                .{ .text = clipped, .style = .{ .fg = fg.toVaxis(), .bg = bg.toVaxis(), .bold = true } },
                .{ .text = " ", .style = base_style },
            };
            _ = root.print(title_segments, .{ .row_offset = 0, .col_offset = 2, .wrap = .none, .commit = true });
        }
    }
}

fn textWidth(text: []const u8) u16 {
    return statusbar.measureText(text);
}

/// Draw a blocking popup (confirm or picker) centered in bounds
pub fn drawInBounds(renderer: *Renderer, popup: pop.Popup, cfg: anytype, bounds_x: u16, bounds_y: u16, bounds_w: u16, bounds_h: u16) void {
    switch (popup) {
        .confirm => |confirm| drawConfirmInBounds(renderer, confirm, cfg.confirm, bounds_x, bounds_y, bounds_w, bounds_h),
        .picker => |picker| drawPickerInBounds(renderer, picker, cfg.choose, bounds_x, bounds_y, bounds_w, bounds_h),
    }
}

/// Draw a blocking popup centered on full screen
pub fn draw(renderer: *Renderer, popup: pop.Popup, cfg: anytype, term_width: u16, term_height: u16) void {
    drawInBounds(renderer, popup, cfg, 0, 0, term_width, term_height);
}

fn confirmBoxDimensions(confirm: *pop.Confirm, cfg: pop.ConfirmStyle) struct { width: u16, height: u16 } {
    const msg_width: u16 = textWidth(confirm.message);
    const buttons_width: u16 = textWidth(confirm.yes_label) + textWidth(confirm.no_label) + 14;
    const content_width = @max(msg_width, buttons_width);
    const box_width = content_width + cfg.padding_x * 2 + 2;
    const box_height: u16 = 3 + cfg.padding_y * 2 + 2;
    return .{ .width = box_width, .height = box_height };
}

fn pickerBoxDimensions(picker: *pop.Picker, cfg: pop.ChooseStyle) struct { width: u16, height: u16 } {
    var max_item_width: usize = 0;
    for (picker.items) |item| {
        max_item_width = @max(max_item_width, textWidth(item));
    }

    var title_width: usize = 0;
    if (picker.title) |t| {
        title_width = textWidth(t) + 4;
    }

    const content_width = @max(max_item_width + 2, title_width);
    const box_width: u16 = @intCast(content_width + cfg.padding_x * 2);

    var box_height: u16 = @intCast(picker.visible_count + cfg.padding_y * 2);
    if (picker.title != null) {
        box_height += 1;
    }
    return .{ .width = box_width, .height = box_height };
}

pub fn drawConfirmInBounds(renderer: *Renderer, confirm: *pop.Confirm, cfg: pop.ConfirmStyle, bounds_x: u16, bounds_y: u16, bounds_w: u16, bounds_h: u16) void {
    const dims = confirmBoxDimensions(confirm, cfg);

    const min_width: u16 = 30;
    const box_width = @max(dims.width, min_width);
    const box_height = dims.height;

    const center_x = bounds_x + bounds_w / 2;
    const center_y = bounds_y + bounds_h / 2;
    const box_x = center_x -| (box_width / 2);
    const box_y = center_y -| (box_height / 2);

    const fg: Color = .{ .palette = cfg.fg };
    const bg: Color = .{ .palette = cfg.bg };
    const padding_x = cfg.padding_x;
    const padding_y = cfg.padding_y;

    const inner_width = box_width - 2;
    const inner_x = box_x + 1;

    drawPopupFrame(renderer, box_x, box_y, box_width, box_height, fg, bg, null);

    // Draw message
    const msg_y = box_y + 1 + padding_y;
    const max_msg_width = inner_width -| padding_x * 2;
    const msg = text_width.clipTextToWidth(confirm.message, max_msg_width);
    const msg_len: u16 = textWidth(msg);
    const msg_x = inner_x + padding_x + (max_msg_width -| msg_len) / 2;
    _ = statusbar.drawStyledText(renderer, msg_x, msg_y, msg, textStyle(fg, bg, cfg.bold));

    // Draw buttons
    const buttons_y = msg_y + 2;
    const yes_label = confirm.yes_label;
    const no_label = confirm.no_label;

    const yes_text_len: u16 = textWidth(yes_label) + 4;
    const no_text_len: u16 = textWidth(no_label) + 4;
    const total_buttons_width = yes_text_len + 4 + no_text_len;
    const buttons_start_x = inner_x + (inner_width -| total_buttons_width) / 2;

    // Yes button
    const yes_selected = confirm.selected == .yes;
    const yes_fg: Color = if (yes_selected) bg else fg;
    const yes_bg: Color = if (yes_selected) fg else bg;
    var bx = buttons_start_x;
    const yes_style = textStyle(yes_fg, yes_bg, yes_selected);
    bx = statusbar.drawStyledText(renderer, bx, buttons_y, "[ ", yes_style);
    bx = statusbar.drawStyledText(renderer, bx, buttons_y, yes_label, yes_style);
    bx = statusbar.drawStyledText(renderer, bx, buttons_y, " ]", yes_style);

    bx += 4; // spacing

    // No button
    const no_selected = confirm.selected == .no;
    const no_fg: Color = if (no_selected) bg else fg;
    const no_bg: Color = if (no_selected) fg else bg;
    const no_style = textStyle(no_fg, no_bg, no_selected);
    bx = statusbar.drawStyledText(renderer, bx, buttons_y, "[ ", no_style);
    bx = statusbar.drawStyledText(renderer, bx, buttons_y, no_label, no_style);
    _ = statusbar.drawStyledText(renderer, bx, buttons_y, " ]", no_style);
}

pub fn drawPickerInBounds(renderer: *Renderer, picker: *pop.Picker, cfg: pop.ChooseStyle, bounds_x: u16, bounds_y: u16, bounds_w: u16, bounds_h: u16) void {
    const dims = pickerBoxDimensions(picker, cfg);

    const min_width: u16 = 20;
    const box_width = @max(dims.width, min_width);
    const box_height = dims.height + 2;

    const center_x = bounds_x + bounds_w / 2;
    const center_y = bounds_y + bounds_h / 2;
    const box_x = center_x -| (box_width / 2);
    const box_y = center_y -| (box_height / 2);

    const fg: Color = .{ .palette = cfg.fg };
    const bg: Color = .{ .palette = cfg.bg };
    const highlight_fg: Color = .{ .palette = cfg.highlight_fg };
    const highlight_bg: Color = .{ .palette = cfg.highlight_bg };

    drawPopupFrame(renderer, box_x, box_y, box_width, box_height, fg, bg, picker.title);

    // Draw items
    const content_x = box_x + 2;
    var content_y = box_y + 1;
    const visible_end = @min(picker.scroll_offset + picker.visible_count, picker.items.len);

    var i = picker.scroll_offset;
    while (i < visible_end) : (i += 1) {
        const item = picker.items[i];
        const is_selected = i == picker.selected;
        const item_fg: Color = if (is_selected) highlight_fg else fg;
        const item_bg: Color = if (is_selected) highlight_bg else bg;

        putChar(renderer, content_x, content_y, if (is_selected) '>' else ' ', item_fg, item_bg, false);
        putChar(renderer, content_x + 1, content_y, ' ', item_fg, item_bg, false);

        var ix: u16 = content_x + 2;
        const item_width_max = (box_x + box_width - 2) -| ix;
        const clipped_item = text_width.clipTextToWidth(item, item_width_max);
        ix = statusbar.drawStyledText(renderer, ix, content_y, clipped_item, textStyle(item_fg, item_bg, is_selected));
        while (ix < box_x + box_width - 1) : (ix += 1) {
            putChar(renderer, ix, content_y, ' ', item_fg, item_bg, false);
        }

        content_y += 1;
    }
}
