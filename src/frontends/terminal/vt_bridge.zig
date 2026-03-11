const std = @import("std");
const vaxis = @import("vaxis");
const ghostty = @import("ghostty-vt");
const core = @import("core");

const pagepkg = ghostty.page;
const Style = ghostty.Style;
const RenderState = ghostty.RenderState;

/// Static ASCII lookup table -- avoids arena allocation for 95%+ of cells.
/// Each byte position i contains the byte value i, so ascii_lut[ch..][0..1]
/// is a valid single-byte slice for any ASCII codepoint.
const ascii_lut: [128]u8 = initAsciiLut();

fn initAsciiLut() [128]u8 {
    var table: [128]u8 = undefined;
    for (0..128) |i| table[i] = @intCast(i);
    return table;
}

/// Blit ghostty RenderState into a vaxis Window.
///
/// Follows prise's server.zig pattern for content_tag dispatch,
/// grapheme encoding, and wide-character spacer handling.
///
/// `arena` is a frame-scoped allocator for temporary grapheme UTF-8 strings.
/// It must remain valid until after `vx.render()` completes for this frame.
pub fn drawRenderState(
    win: vaxis.Window,
    state: *const RenderState,
    width: u16,
    height: u16,
    arena: std.mem.Allocator,
    vt: *core.VT,
    vx: *vaxis.Vaxis,
    stdout: std.fs.File,
) void {
    const MAX_REASONABLE_ROWS: usize = 10_000;
    const MAX_REASONABLE_COLS: usize = 1_000;

    const safe_rows = @min(@as(usize, state.rows), MAX_REASONABLE_ROWS);
    const safe_cols = @min(@as(usize, state.cols), MAX_REASONABLE_COLS);
    const rows = @min(@as(usize, height), safe_rows);
    const cols = @min(@as(usize, width), safe_cols);

    const row_slice = state.row_data.slice();
    const available_rows = @min(rows, row_slice.len);
    if (available_rows == 0) return;

    const row_cells = row_slice.items(.cells);
    const row_pins = row_slice.items(.pin);

    syncKittyImages(vt, vx, stdout, arena);

    for (0..available_rows) |yi| {
        const y: u16 = @intCast(yi);
        if (y >= win.height) break;

        const cells_slice = row_cells[yi].slice();
        const raw_cells = cells_slice.items(.raw);
        const graphemes_arr = cells_slice.items(.grapheme);
        const styles_arr = cells_slice.items(.style);

        var col: usize = 0;
        while (col < cols) {
            const x: u16 = @intCast(col);
            if (x >= win.width) break;

            const raw = raw_cells[col];

            // Skip spacer tails (prise: server.zig:930-933)
            if (raw.wide == .spacer_tail) {
                col += 1;
                continue;
            }

            const cell_width: u8 = if (raw.wide == .wide) 2 else 1;
            const is_direct_color = (raw.content_tag == .bg_color_rgb or
                raw.content_tag == .bg_color_palette);

            const grapheme_tail: []const u21 = if (raw.content_tag == .codepoint_grapheme)
                graphemes_arr[col]
            else
                &.{};

            // Resolve grapheme text
            const text = resolveCellText(arena, raw, grapheme_tail, is_direct_color) catch " ";

            // Resolve style
            const style = if (raw.style_id != 0)
                convertStyle(styles_arr[col], raw, is_direct_color)
            else
                convertDefaultStyle(raw, is_direct_color);

            const link = resolveCellLink(arena, row_pins[yi], @intCast(col), raw);

            win.writeCell(@intCast(col), y, .{
                .char = .{ .grapheme = text, .width = cell_width },
                .style = style,
                .link = link,
            });

            // Write explicit spacer cells for wide characters
            // (prise: Surface.zig:264-270)
            if (cell_width == 2 and col + 1 < cols and x + 1 < win.width) {
                win.writeCell(x + 1, y, .{
                    .char = .{ .grapheme = "", .width = 0 },
                    .style = style,
                    .link = link,
                });
            }

            col += cell_width;
        }
    }

    drawKittyPinPlacements(win, vt);
    drawKittyVirtualPlacements(win, vt, row_pins, available_rows);
}

/// Convert ghostty cell content to a UTF-8 string.
/// Handles single codepoints AND multi-codepoint grapheme clusters.
/// (prise: server.zig:844-871)
fn resolveCellText(
    alloc: std.mem.Allocator,
    raw: pagepkg.Cell,
    grapheme_tail: []const u21,
    is_direct_color: bool,
) ![]const u8 {
    if (is_direct_color) return " ";

    const cp = raw.codepoint();
    if (isKittyGraphicsPlaceholder(cp)) return " ";
    if (cp == 0 or cp < 32 or cp == 127) return " ";

    // Spacer head (end-of-line wide char wrap) -> blank
    if (raw.wide == .spacer_head) return " ";

    // Fast path: single ASCII codepoint (95%+ of terminal content)
    if (cp < 128 and grapheme_tail.len == 0) return ascii_lut[cp..][0..1];

    // Multi-codepoint grapheme cluster (primary codepoint + tail)
    if (grapheme_tail.len > 0) {
        const max_len = (1 + grapheme_tail.len) * 4;
        var out = try alloc.alloc(u8, max_len);
        errdefer alloc.free(out);
        var n: usize = 0;
        n += std.unicode.utf8Encode(cp, out[n..][0..4]) catch return " ";
        for (grapheme_tail) |tail_cp| {
            n += std.unicode.utf8Encode(tail_cp, out[n..][0..4]) catch return " ";
        }
        return out[0..n];
    }

    // Non-ASCII: encode to UTF-8 via arena
    var utf8_buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &utf8_buf) catch return " ";
    return try alloc.dupe(u8, utf8_buf[0..len]);
}

fn isKittyGraphicsPlaceholder(cp: u21) bool {
    if (@hasDecl(ghostty, "kitty") and
        @hasDecl(ghostty.kitty, "graphics") and
        @hasDecl(ghostty.kitty.graphics, "unicode") and
        @hasDecl(ghostty.kitty.graphics.unicode, "placeholder"))
    {
        return cp == ghostty.kitty.graphics.unicode.placeholder;
    }
    return false;
}

fn imageFormatToVaxis(format: anytype) ?vaxis.Image.TransmitFormat {
    return switch (format) {
        .rgb => .rgb,
        .rgba => .rgba,
        .png => .png,
        else => null,
    };
}

fn syncKittyImages(vt: *core.VT, vx: *vaxis.Vaxis, stdout: std.fs.File, arena: std.mem.Allocator) void {
    const Storage = @TypeOf(vt.terminal.screens.active.kitty_images);
    if (comptime !@hasField(Storage, "images")) return;

    if (!vx.caps.kitty_graphics) return;

    const storage = &vt.terminal.screens.active.kitty_images;

    var tty_buf: [4096]u8 = undefined;
    var writer = stdout.writer(&tty_buf);

    var stale: std.ArrayList(u32) = .empty;
    defer stale.deinit(arena);

    var cache_it = vt.kitty_image_cache.iterator();
    while (cache_it.next()) |entry| {
        if (!storage.images.contains(entry.key_ptr.*)) {
            stale.append(arena, entry.key_ptr.*) catch {};
        }
    }

    for (stale.items) |ghost_id| {
        if (vt.kitty_image_cache.get(ghost_id)) |cached| {
            vx.freeImage(&writer.interface, cached.vaxis_id);
        }
        _ = vt.kitty_image_cache.remove(ghost_id);
    }

    var it = storage.images.iterator();
    while (it.next()) |entry| {
        const ghost_id = entry.key_ptr.*;
        const img = entry.value_ptr.*;
        const fmt = imageFormatToVaxis(img.format) orelse continue;
        const data_hash = std.hash.Wyhash.hash(0, img.data);
        const fmt_tag: u8 = switch (fmt) {
            .rgb => 1,
            .rgba => 2,
            .png => 3,
        };

        if (vt.kitty_image_cache.get(ghost_id)) |cached| {
            if (cached.width == img.width and
                cached.height == img.height and
                cached.data_len == img.data.len and
                cached.data_hash == data_hash and
                cached.format_tag == fmt_tag)
            {
                continue;
            }

            vx.freeImage(&writer.interface, cached.vaxis_id);
            _ = vt.kitty_image_cache.remove(ghost_id);
        }

        const w: u16 = @intCast(@min(img.width, std.math.maxInt(u16)));
        const h: u16 = @intCast(@min(img.height, std.math.maxInt(u16)));
        if (w == 0 or h == 0) continue;

        const enc_size = std.base64.standard.Encoder.calcSize(img.data.len);
        const enc_buf = arena.alloc(u8, enc_size) catch continue;
        const b64 = std.base64.standard.Encoder.encode(enc_buf, img.data);

        const vimg = vx.transmitPreEncodedImage(&writer.interface, b64, w, h, fmt) catch continue;
        vt.kitty_image_cache.put(vt.allocator, ghost_id, .{
            .vaxis_id = vimg.id,
            .width = img.width,
            .height = img.height,
            .data_len = img.data.len,
            .data_hash = data_hash,
            .format_tag = fmt_tag,
        }) catch {};
    }
}

fn drawKittyVirtualPlacements(
    win: vaxis.Window,
    vt: *core.VT,
    row_pins: []const ghostty.PageList.Pin,
    available_rows: usize,
) void {
    if (comptime !@hasDecl(ghostty.kitty.graphics, "unicode")) return;
    const Storage = @TypeOf(vt.terminal.screens.active.kitty_images);
    if (comptime !@hasDecl(Storage, "imageById")) return;

    if (available_rows == 0) return;

    const top = row_pins[0];
    const bottom = row_pins[available_rows - 1];
    const storage = &vt.terminal.screens.active.kitty_images;
    const cell_w: u32 = if (vt.terminal.cols == 0) 1 else @max(1, vt.terminal.width_px / vt.terminal.cols);
    const cell_h: u32 = if (vt.terminal.rows == 0) 1 else @max(1, vt.terminal.height_px / vt.terminal.rows);

    var it = ghostty.kitty.graphics.unicode.placementIterator(top, bottom);
    while (it.next()) |placement| {
        const image = storage.imageById(placement.image_id) orelse continue;
        const rp = placement.renderPlacement(storage, &image, cell_w, cell_h) catch continue;

        const cached = vt.kitty_image_cache.get(placement.image_id) orelse continue;
        const p = vt.terminal.screens.active.pages.pointFromPin(.viewport, placement.pin) orelse continue;
        const vp = p.viewport;

        const col: u16 = @intCast(vp.x);
        const row: u16 = @intCast(vp.y);
        if (col >= win.width or row >= win.height) continue;

        const size_rows: u16 = @intCast(@min(placement.height, std.math.maxInt(u16)));
        const size_cols: u16 = @intCast(@min(placement.width, std.math.maxInt(u16)));
        if (size_rows == 0 or size_cols == 0) continue;

        writeImageCellPreserve(win, col, row, .{
            .img_id = cached.vaxis_id,
            .options = .{
                .pixel_offset = .{
                    .x = @intCast(@min(rp.offset_x, std.math.maxInt(u16))),
                    .y = @intCast(@min(rp.offset_y, std.math.maxInt(u16))),
                },
                .size = .{ .rows = size_rows, .cols = size_cols },
                .clip_region = .{
                    .x = @intCast(@min(rp.source_x, std.math.maxInt(u16))),
                    .y = @intCast(@min(rp.source_y, std.math.maxInt(u16))),
                    .width = @intCast(@min(rp.source_width, std.math.maxInt(u16))),
                    .height = @intCast(@min(rp.source_height, std.math.maxInt(u16))),
                },
                .z_index = -1,
            },
        });
    }
}

fn drawKittyPinPlacements(win: vaxis.Window, vt: *core.VT) void {
    const Storage = @TypeOf(vt.terminal.screens.active.kitty_images);
    if (comptime !@hasField(Storage, "placements")) return;
    if (comptime !@hasDecl(Storage, "imageById")) return;

    const storage = &vt.terminal.screens.active.kitty_images;
    var it = storage.placements.iterator();
    while (it.next()) |kv| {
        const p = kv.value_ptr.*;
        switch (p.location) {
            .pin => {},
            .virtual => continue,
        }

        const image = storage.imageById(kv.key_ptr.image_id) orelse continue;
        const cached = vt.kitty_image_cache.get(kv.key_ptr.image_id) orelse continue;
        const rect = p.rect(image, &vt.terminal) orelse continue;

        const top = vt.terminal.screens.active.pages.pointFromPin(.viewport, rect.top_left) orelse continue;
        const vp = top.viewport;
        const col: u16 = @intCast(vp.x);
        const row: u16 = @intCast(vp.y);
        if (col >= win.width or row >= win.height) continue;

        const grid = p.gridSize(image, &vt.terminal);
        const size_rows: u16 = @intCast(@min(grid.rows, std.math.maxInt(u16)));
        const size_cols: u16 = @intCast(@min(grid.cols, std.math.maxInt(u16)));
        if (size_rows == 0 or size_cols == 0) continue;

        const src_w = if (p.source_width == 0) image.width else p.source_width;
        const src_h = if (p.source_height == 0) image.height else p.source_height;

        writeImageCellPreserve(win, col, row, .{
            .img_id = cached.vaxis_id,
            .options = .{
                .pixel_offset = .{
                    .x = @intCast(@min(p.x_offset, std.math.maxInt(u16))),
                    .y = @intCast(@min(p.y_offset, std.math.maxInt(u16))),
                },
                .z_index = p.z,
                .clip_region = .{
                    .x = @intCast(@min(p.source_x, std.math.maxInt(u16))),
                    .y = @intCast(@min(p.source_y, std.math.maxInt(u16))),
                    .width = @intCast(@min(src_w, std.math.maxInt(u16))),
                    .height = @intCast(@min(src_h, std.math.maxInt(u16))),
                },
                .size = .{ .rows = size_rows, .cols = size_cols },
            },
        });
    }
}

fn writeImageCellPreserve(win: vaxis.Window, col: u16, row: u16, placement: vaxis.Image.Placement) void {
    if (win.readCell(col, row)) |existing| {
        var cell = existing;
        cell.image = placement;
        win.writeCell(col, row, cell);
        return;
    }
    win.writeCell(col, row, .{ .image = placement });
}

/// Convert ghostty Style to vaxis Style.
/// (prise: server.zig:686-743)
fn convertStyle(gs: Style, raw: pagepkg.Cell, is_direct_color: bool) vaxis.Style {
    var style = vaxis.Style{};

    // Foreground
    switch (gs.fg_color) {
        .none => {},
        .palette => |idx| style.fg = .{ .index = @intCast(idx) },
        .rgb => |rgb| style.fg = .{ .rgb = .{ rgb.r, rgb.g, rgb.b } },
    }

    // Background
    switch (gs.bg_color) {
        .none => {},
        .palette => |idx| style.bg = .{ .index = @intCast(idx) },
        .rgb => |rgb| style.bg = .{ .rgb = .{ rgb.r, rgb.g, rgb.b } },
    }

    // Direct color cells override bg (prise: server.zig:938-946)
    if (is_direct_color) {
        applyDirectColor(&style, raw);
    }

    // Underline color
    switch (gs.underline_color) {
        .none => {},
        .palette => {},
        .rgb => |rgb| style.ul = .{ .rgb = .{ rgb.r, rgb.g, rgb.b } },
    }

    // Flags (prise: server.zig:725-740)
    style.bold = gs.flags.bold;
    style.dim = gs.flags.faint;
    style.italic = gs.flags.italic;
    style.reverse = gs.flags.inverse;
    style.blink = gs.flags.blink;
    style.strikethrough = gs.flags.strikethrough;

    style.ul_style = switch (gs.flags.underline) {
        .none => .off,
        .single => .single,
        .double => .double,
        .curly => .curly,
        .dotted => .dotted,
        .dashed => .dashed,
    };

    return style;
}

fn convertDefaultStyle(raw: pagepkg.Cell, is_direct_color: bool) vaxis.Style {
    var style = vaxis.Style{};
    if (is_direct_color) applyDirectColor(&style, raw);
    return style;
}

fn applyDirectColor(style: *vaxis.Style, raw: pagepkg.Cell) void {
    if (raw.content_tag == .bg_color_rgb) {
        const c = raw.content.color_rgb;
        style.bg = .{ .rgb = .{ c.r, c.g, c.b } };
    } else if (raw.content_tag == .bg_color_palette) {
        style.bg = .{ .index = raw.content.color_palette };
    }
}

fn resolveCellLink(
    arena: std.mem.Allocator,
    pin: ghostty.PageList.Pin,
    x: u16,
    raw: pagepkg.Cell,
) vaxis.Cell.Hyperlink {
    if (!raw.hyperlink) return .{};

    const rac = pin.node.data.getRowAndCell(x, pin.y);
    if (!rac.cell.hyperlink) return .{};

    const id = pin.node.data.lookupHyperlink(rac.cell) orelse return .{};
    const entry = pin.node.data.hyperlink_set.get(pin.node.data.memory, id);
    const uri_src = entry.uri.slice(pin.node.data.memory);
    if (uri_src.len == 0) return .{};

    const uri = arena.dupe(u8, uri_src) catch return .{};
    var params: []const u8 = "";

    switch (entry.id) {
        .implicit => {},
        .explicit => |id_slice| {
            const id_src = id_slice.slice(pin.node.data.memory);
            if (id_src.len > 0) {
                const out = arena.alloc(u8, 3 + id_src.len) catch return .{ .uri = uri };
                std.mem.copyForwards(u8, out[0..3], "id=");
                std.mem.copyForwards(u8, out[3..], id_src);
                params = out;
            }
        },
    }

    return .{ .uri = uri, .params = params };
}
