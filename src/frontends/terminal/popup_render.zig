const std = @import("std");
const pop = @import("pop");
const core = @import("core");
const vaxis = @import("vaxis");
const Renderer = @import("render_core.zig").Renderer;
const Color = core.style.Color;
const statusbar = @import("statusbar.zig");
const text_width = @import("text_width.zig");

const DEFAULT_CONFIRM_HINT = "←/→/Tab toggle · Enter confirm · y/n · Esc cancel";
const DEFAULT_PICKER_HINT = "↑↓/jk move · / filter · Enter select · Esc cancel";
const FILTER_PICKER_HINT = "Type to filter · ↑↓ move · Enter select · Esc clear";

fn putChar(renderer: *Renderer, x: u16, y: u16, cp: u21, fg: Color, bg: Color, bold: bool, dim: bool) void {
    var buf: [4]u8 = undefined;
    const grapheme: []const u8 = if (cp < 128)
        buf[0..blk: {
            buf[0] = @intCast(cp);
            break :blk 1;
        }]
    else blk: {
        const n = std.unicode.utf8Encode(cp, &buf) catch |err| {
            core.logging.logError("terminal", "popup glyph encode failed", err);
            return;
        };
        break :blk buf[0..n];
    };

    const style: vaxis.Style = .{ .bold = bold, .dim = dim, .fg = fg.toVaxis(), .bg = bg.toVaxis() };
    renderer.setVaxisCell(x, y, .{
        .char = .{ .grapheme = grapheme, .width = 1 },
        .style = style,
    });
}

fn drawText(renderer: *Renderer, start_x: u16, y: u16, max_x: u16, text: []const u8, fg: Color, bg: Color, bold: bool, dim: bool) u16 {
    if (start_x >= max_x or text.len == 0) return start_x;
    const avail = max_x - start_x;
    const clipped = text_width.clipTextToWidth(text, avail);
    const style: vaxis.Style = .{ .bold = bold, .dim = dim, .fg = fg.toVaxis(), .bg = bg.toVaxis() };

    var x = start_x;
    var it = vaxis.unicode.graphemeIterator(clipped);
    while (it.next()) |g| {
        const slice = g.bytes(clipped);
        const w: u16 = @intCast(@max(vaxis.gwidth.gwidth(slice, .unicode), 1));
        if (x + w > max_x) break;
        renderer.setVaxisCell(x, y, .{
            .char = .{ .grapheme = slice, .width = @intCast(w) },
            .style = style,
        });
        x += w;
    }
    return x;
}

fn isDarkColor(color: Color) bool {
    return switch (color) {
        .none => true,
        .palette => |idx| idx == 0 or (idx >= 232 and idx <= 241),
        .rgb => |rgb| (@as(u32, rgb.r) * 299 + @as(u32, rgb.g) * 587 + @as(u32, rgb.b) * 114) < 90_000,
    };
}

/// SGR `dim` softens light text on dark backgrounds nicely, but on dark text
/// over a colored/bright background (e.g. `fg = 232, bg = 1` or `fg = 0, bg = 4`)
/// many terminals shift dark foregrounds to a mismatched muddy/faded shade.
fn canDimText(fg: Color, bg: Color) bool {
    return !(isDarkColor(fg) and !isDarkColor(bg));
}

fn drawHorizontalRule(renderer: *Renderer, box_x: u16, y: u16, box_width: u16, fg: Color, bg: Color) void {
    if (box_width < 2) return;
    // Match the outer border frame style exactly (no `dim`) so the rule and
    // its left/right junctions stay seamless with the box border.
    putChar(renderer, box_x, y, '├', fg, bg, false, false);
    var x = box_x + 1;
    while (x + 1 < box_x + box_width) : (x += 1) {
        putChar(renderer, x, y, '─', fg, bg, false, false);
    }
    putChar(renderer, box_x + box_width - 1, y, '┤', fg, bg, false, false);
}

fn drawPopupFrame(
    renderer: *Renderer,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    fg: Color,
    bg: Color,
    title: ?[]const u8,
    right_badge: ?[]const u8,
) void {
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
            .glyphs = .single_rounded,
            .style = base_style,
        },
    });

    const badge_w: u16 = if (right_badge) |b| (if (b.len > 0) textWidth(b) + 2 else 0) else 0;
    if (right_badge) |b| {
        if (b.len > 0 and w > badge_w + 2) {
            const bx = x + w - 2 - badge_w;
            var cx = drawText(renderer, bx, y, x + w - 1, " ", fg, bg, false, false);
            cx = drawText(renderer, cx, y, x + w - 1, b, fg, bg, false, false);
            _ = drawText(renderer, cx, y, x + w - 1, " ", fg, bg, false, false);
        }
    }

    if (title) |t| {
        const reserve: u16 = if (badge_w > 0) 7 + badge_w else 6;
        if (h > 0 and w > reserve) {
            const max_title = w - reserve;
            const clipped = text_width.clipTextToWidth(t, max_title);
            const title_limit = x + w - 1;
            var tx = drawText(renderer, x + 2, y, title_limit, " ", fg, bg, false, false);
            tx = drawText(renderer, tx, y, title_limit, clipped, fg, bg, true, false);
            _ = drawText(renderer, tx, y, title_limit, " ", fg, bg, false, false);
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
    const sub_width: u16 = if (confirm.subtitle) |sub| textWidth(sub) else 0;
    const hint = confirm.hint orelse DEFAULT_CONFIRM_HINT;
    const hint_width: u16 = textWidth(hint);
    const buttons_width: u16 = textWidth(confirm.yes_label) + textWidth(confirm.no_label) + 14;
    const content_width = @max(@max(msg_width, sub_width), @max(buttons_width, hint_width));
    const box_width = content_width + cfg.padding_x * 2 + 2;
    // border(2) + padding_y*2 + message(1) + optional subtitle(1) + gap(1) + buttons(1) + rule(1) + hint(1)
    var box_height: u16 = 5 + cfg.padding_y * 2 + 2;
    if (confirm.subtitle != null) box_height += 1;
    return .{ .width = box_width, .height = box_height };
}

pub fn drawConfirmInBounds(renderer: *Renderer, confirm: *pop.Confirm, cfg: pop.ConfirmStyle, bounds_x: u16, bounds_y: u16, bounds_w: u16, bounds_h: u16) void {
    if (bounds_w < 10 or bounds_h < 5) return;

    const dims = confirmBoxDimensions(confirm, cfg);
    const max_w = if (bounds_w > 4) bounds_w - 2 else bounds_w;
    const max_h = if (bounds_h > 2) bounds_h - 2 else bounds_h;
    const min_width: u16 = @min(@as(u16, 36), max_w);
    const box_width = @min(@max(dims.width, min_width), max_w);
    const box_height = @min(dims.height, max_h);

    const box_x = bounds_x + (bounds_w -| box_width) / 2;
    const box_y = bounds_y + (bounds_h -| box_height) / 2;

    const fg: Color = .{ .palette = cfg.fg };
    const bg: Color = .{ .palette = cfg.bg };
    const secondary_dim = canDimText(fg, bg);
    const padding_x: u16 = @min(cfg.padding_x, (box_width -| 4) / 2);
    const padding_y: u16 = if (box_height >= dims.height) cfg.padding_y else 0;

    const inner_width = box_width -| 2;
    const inner_x = box_x + 1;
    const inner_right = box_x + box_width -| 1;

    drawPopupFrame(renderer, box_x, box_y, box_width, box_height, fg, bg, null, null);

    var cur_y = box_y + 1 + padding_y;

    // Message
    const max_msg_width = inner_width -| padding_x * 2;
    const msg = text_width.clipTextToWidth(confirm.message, max_msg_width);
    const msg_len: u16 = textWidth(msg);
    const msg_x = inner_x + padding_x + (max_msg_width -| msg_len) / 2;
    _ = drawText(renderer, msg_x, cur_y, inner_right, msg, fg, bg, cfg.bold, false);
    cur_y += 1;

    // Optional subtitle
    if (confirm.subtitle) |sub| {
        if (cur_y + 2 < box_y + box_height) {
            const sub_clipped = text_width.clipTextToWidth(sub, max_msg_width);
            const sub_len = textWidth(sub_clipped);
            const sub_x = inner_x + padding_x + (max_msg_width -| sub_len) / 2;
            _ = drawText(renderer, sub_x, cur_y, inner_right, sub_clipped, fg, bg, false, secondary_dim);
            cur_y += 1;
        }
    }

    // Buttons (with 1 blank line above when height allows)
    if (cur_y + 2 < box_y + box_height) cur_y += 1;
    const buttons_y = @min(cur_y, box_y + box_height -| 2);
    const yes_label = confirm.yes_label;
    const no_label = confirm.no_label;

    const yes_text_len: u16 = textWidth(yes_label) + 4;
    const no_text_len: u16 = textWidth(no_label) + 4;
    const total_buttons_width = yes_text_len + 4 + no_text_len;
    const buttons_start_x = inner_x + (inner_width -| total_buttons_width) / 2;

    const yes_selected = confirm.selected == .yes;
    const yes_fg: Color = if (yes_selected) bg else fg;
    const yes_bg: Color = if (yes_selected) fg else bg;
    var bx = buttons_start_x;
    bx = drawText(renderer, bx, buttons_y, inner_right, "[ ", yes_fg, yes_bg, yes_selected, false);
    bx = drawText(renderer, bx, buttons_y, inner_right, yes_label, yes_fg, yes_bg, yes_selected, false);
    bx = drawText(renderer, bx, buttons_y, inner_right, " ]", yes_fg, yes_bg, yes_selected, false);

    bx += 4;

    const no_selected = confirm.selected == .no;
    const no_fg: Color = if (no_selected) bg else fg;
    const no_bg: Color = if (no_selected) fg else bg;
    bx = drawText(renderer, bx, buttons_y, inner_right, "[ ", no_fg, no_bg, no_selected, false);
    bx = drawText(renderer, bx, buttons_y, inner_right, no_label, no_fg, no_bg, no_selected, false);
    _ = drawText(renderer, bx, buttons_y, inner_right, " ]", no_fg, no_bg, no_selected, false);

    // Hint footer (if room)
    if (box_height >= 6 and buttons_y + 2 < box_y + box_height - 1) {
        const hint_y = box_y + box_height - 2;
        const rule_y = hint_y - 1;
        drawHorizontalRule(renderer, box_x, rule_y, box_width, fg, bg);
        const hint = confirm.hint orelse DEFAULT_CONFIRM_HINT;
        const hint_clipped = text_width.clipTextToWidth(hint, inner_width -| 2);
        const hint_len = textWidth(hint_clipped);
        const hint_x = inner_x + (inner_width -| hint_len) / 2;
        _ = drawText(renderer, hint_x, hint_y, inner_right, hint_clipped, fg, bg, false, secondary_dim);
    }
}

pub fn drawPickerInBounds(renderer: *Renderer, picker: *pop.Picker, cfg: pop.ChooseStyle, bounds_x: u16, bounds_y: u16, bounds_w: u16, bounds_h: u16) void {
    if (bounds_w < 14 or bounds_h < 6) return;

    const has_filter_bar = picker.filter_active or picker.filter_len > 0;
    const has_details = picker.details != null;
    const hint = if (picker.filter_active)
        FILTER_PICKER_HINT
    else
        (picker.hint orelse DEFAULT_PICKER_HINT);

    // Measure desired content width
    var max_row_width: u16 = 0;
    const show_nums = picker.show_numbers and !picker.filter_active and picker.filter_len == 0;
    const prefix_w: u16 = if (show_nums) 4 else 2; // "▸ 1 " vs "▸ "
    for (picker.items, 0..) |item, idx| {
        var rw: u16 = prefix_w + textWidth(item);
        if (picker.badgeAt(idx)) |badge| {
            rw += textWidth(badge) + 3;
        }
        max_row_width = @max(max_row_width, rw);
    }
    if (picker.details) |ds| {
        for (ds) |d| {
            max_row_width = @max(max_row_width, textWidth(d));
        }
    }
    const title_w: u16 = if (picker.title) |t| textWidth(t) + 14 else 14;
    const hint_w: u16 = textWidth(hint);
    const desired_content_w = @max(@max(max_row_width, title_w), hint_w);

    const max_w = if (bounds_w > 4) bounds_w - 4 else bounds_w;
    const max_h = if (bounds_h > 2) bounds_h - 2 else bounds_h;
    const min_width: u16 = @min(@as(u16, 44), max_w);
    const box_width = @min(@max(desired_content_w + 4, min_width), max_w);

    // Chrome rows: top/bottom border (2) + optional filter(2) + optional detail(2) + footer hint(2)
    var chrome_rows: u16 = 2 + 2; // borders + rule/hint
    if (has_filter_bar) chrome_rows += 2; // filter row + separator
    if (has_details) chrome_rows += 2; // separator + detail row

    const max_list_rows: usize = if (max_h > chrome_rows) @as(usize, max_h - chrome_rows) else 1;
    const desired_list_rows = @max(@min(picker.visible_count, if (picker.items.len == 0) 1 else picker.items.len), 1);
    const list_rows: usize = @min(desired_list_rows, max_list_rows);

    // Sync picker viewport size so scrolling tracks actual visible rows.
    if (picker.visible_count != list_rows and list_rows > 0) {
        picker.visible_count = list_rows;
        if (picker.selected >= picker.scroll_offset + list_rows) {
            picker.scroll_offset = picker.selected - list_rows + 1;
        }
    }

    const box_height: u16 = @min(@as(u16, @intCast(list_rows)) + chrome_rows, max_h);
    const box_x = bounds_x + (bounds_w -| box_width) / 2;
    const box_y = bounds_y + (bounds_h -| box_height) / 2;

    const fg: Color = .{ .palette = cfg.fg };
    const bg: Color = .{ .palette = cfg.bg };
    const secondary_dim = canDimText(fg, bg);
    const highlight_fg: Color = .{ .palette = cfg.highlight_fg };
    const highlight_bg: Color = .{ .palette = cfg.highlight_bg };

    // Count badge in top-right border: e.g. "2/5" or "1/3 of 8"
    var count_buf: [32]u8 = undefined;
    const visible_total = picker.visibleLen();
    const count_badge: []const u8 = if (visible_total == 0)
        (std.fmt.bufPrint(&count_buf, "0/{d}", .{picker.items.len}) catch "")
    else if (visible_total != picker.items.len)
        (std.fmt.bufPrint(&count_buf, "{d}/{d} ({d})", .{ picker.selected + 1, visible_total, picker.items.len }) catch "")
    else
        (std.fmt.bufPrint(&count_buf, "{d}/{d}", .{ picker.selected + 1, visible_total }) catch "");

    drawPopupFrame(renderer, box_x, box_y, box_width, box_height, fg, bg, picker.title, count_badge);

    const inner_x = box_x + 2;
    const inner_right = box_x + box_width -| 2;
    var cur_y = box_y + 1;

    // Optional filter input bar
    if (has_filter_bar and cur_y + 2 < box_y + box_height) {
        var qx = drawText(renderer, inner_x, cur_y, inner_right, "/ ", fg, bg, true, false);
        const query = picker.filterQuery();
        if (query.len > 0) {
            qx = drawText(renderer, qx, cur_y, inner_right, query, fg, bg, false, false);
        }
        if (picker.filter_active and qx < inner_right) {
            putChar(renderer, qx, cur_y, ' ', bg, fg, false, false); // block cursor
        }
        cur_y += 1;
        drawHorizontalRule(renderer, box_x, cur_y, box_width, fg, bg);
        cur_y += 1;
    }

    // List rows
    if (visible_total == 0) {
        const empty_msg: []const u8 = if (picker.filter_len > 0) "(no matching items)" else "(empty)";
        _ = drawText(renderer, inner_x + 2, cur_y, inner_right, empty_msg, fg, bg, false, secondary_dim);
        cur_y += @intCast(list_rows);
    } else {
        const visible_end = @min(picker.scroll_offset + list_rows, visible_total);
        const has_above = picker.scroll_offset > 0;
        const has_below = visible_end < visible_total;

        var row_idx: usize = 0;
        var i = picker.scroll_offset;
        while (i < visible_end) : ({
            i += 1;
            row_idx += 1;
        }) {
            const orig_idx = picker.filtered_indices.items[i];
            const item = picker.items[orig_idx];
            const is_selected = i == picker.selected;
            const item_fg: Color = if (is_selected) highlight_fg else fg;
            const item_bg: Color = if (is_selected) highlight_bg else bg;

            // Fill entire row background first
            var fx = box_x + 1;
            while (fx < box_x + box_width - 1) : (fx += 1) {
                putChar(renderer, fx, cur_y, ' ', item_fg, item_bg, false, false);
            }

            // Selection chevron
            putChar(renderer, inner_x, cur_y, if (is_selected) '▸' else ' ', item_fg, item_bg, is_selected, false);
            var ix = inner_x + 2;

            // Optional 1-9 quick-select number
            if (show_nums and row_idx < 9) {
                var num_buf: [2]u8 = .{ @intCast('1' + row_idx), ' ' };
                ix = drawText(renderer, ix, cur_y, inner_right, &num_buf, item_fg, item_bg, false, !is_selected and secondary_dim);
            }

            // Right-aligned badge (reserve space)
            const badge = picker.badgeAt(orig_idx);
            const badge_w: u16 = if (badge) |b| textWidth(b) + 2 else 0;
            const label_max_x = inner_right -| badge_w;

            _ = drawText(renderer, ix, cur_y, label_max_x, item, item_fg, item_bg, is_selected, false);

            if (badge) |b| {
                if (inner_right > textWidth(b)) {
                    const bx = inner_right - textWidth(b);
                    _ = drawText(renderer, bx, cur_y, inner_right, b, item_fg, item_bg, false, !is_selected and secondary_dim);
                }
            }

            // Scroll markers on right frame edge (match border color, no dim)
            if (row_idx == 0 and has_above) {
                putChar(renderer, box_x + box_width - 1, cur_y, '▲', fg, bg, false, false);
            } else if (row_idx + 1 == list_rows and has_below) {
                putChar(renderer, box_x + box_width - 1, cur_y, '▼', fg, bg, false, false);
            }

            cur_y += 1;
        }
        if (row_idx < list_rows) {
            cur_y += @intCast(list_rows - row_idx);
        }
    }

    // Optional detail preview line for the highlighted item
    if (has_details and cur_y + 2 < box_y + box_height) {
        drawHorizontalRule(renderer, box_x, cur_y, box_width, fg, bg);
        cur_y += 1;
        if (picker.selectedDetail()) |detail| {
            _ = drawText(renderer, inner_x, cur_y, inner_right, detail, fg, bg, false, secondary_dim);
        }
        cur_y += 1;
    }

    // Footer hint line
    if (box_height >= 5) {
        const hint_y = box_y + box_height - 2;
        if (hint_y > cur_y) {
            drawHorizontalRule(renderer, box_x, hint_y - 1, box_width, fg, bg);
            _ = drawText(renderer, inner_x, hint_y, inner_right, hint, fg, bg, false, secondary_dim);
        }
    }
}
