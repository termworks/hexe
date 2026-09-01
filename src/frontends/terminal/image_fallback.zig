//! Drawing an image on a terminal that cannot draw images.
//!
//! hexe re-transmits images to the host terminal using the Kitty protocol, and
//! a terminal that does not speak it gets nothing at all -- the image is simply
//! absent, with a blank hole where it should be. That is the worst of the
//! options: worse than a rough picture, and worse than saying so.
//!
//! So when the host has no graphics, hexe draws the image out of text. Every
//! cell becomes an upper half block, whose foreground paints the top half and
//! whose background paints the bottom, which buys two rows of pixels per row of
//! cells. It is not a photograph, but a chart is readable, a logo is
//! recognisable, and a progress preview tells you what it was going to tell you.
//!
//! This is the same trick `chafa` and `viu` use when they detect a plain
//! terminal, done here so that it applies to any program's image rather than
//! only to programs that thought to implement it.

const std = @import("std");
const vaxis = @import("vaxis");
const ghostty = @import("ghostty-vt");
const core = @import("core");

/// Foreground is the top half, background the bottom.
const upper_half = "▀";
/// Used when only the bottom half is opaque, so the foreground can carry it.
const lower_half = "▄";

/// Below this, a pixel counts as see-through and the cell keeps whatever is
/// behind it. Images with a soft alpha edge otherwise draw a dark fringe.
const alpha_threshold: u8 = 128;

/// How many source pixels to average per half cell, per axis. A downscaled
/// photograph sampled at a single point is noisy in a way a small box average
/// is not, and the cost is bounded by the number of CELLS -- a handful of
/// thousand reads a frame -- not by the size of the image.
const taps: u32 = 4;

const Rgba = struct { r: u8, g: u8, b: u8, a: u8 };

/// A decoded image in the pane's Kitty storage, read as pixels.
pub const Source = struct {
    data: []const u8,
    width: u32,
    height: u32,
    bpp: u32,

    pub fn from(image: ghostty.kitty.graphics.Image) ?Source {
        const bpp: u32 = switch (image.format) {
            .gray => 1,
            .gray_alpha => 2,
            .rgb => 3,
            .rgba => 4,
            // Still encoded. ghostty decodes PNG on load, so this is only
            // reachable if a future format arrives undecoded.
            else => return null,
        };
        if (image.width == 0 or image.height == 0) return null;
        if (image.data.len < @as(usize, image.width) * @as(usize, image.height) * bpp) return null;
        return .{ .data = image.data, .width = image.width, .height = image.height, .bpp = bpp };
    }

    fn at(self: Source, x: u32, y: u32) Rgba {
        const px = @min(x, self.width - 1);
        const py = @min(y, self.height - 1);
        const o = (@as(usize, py) * self.width + px) * self.bpp;
        return switch (self.bpp) {
            1 => .{ .r = self.data[o], .g = self.data[o], .b = self.data[o], .a = 255 },
            2 => .{ .r = self.data[o], .g = self.data[o], .b = self.data[o], .a = self.data[o + 1] },
            3 => .{ .r = self.data[o], .g = self.data[o + 1], .b = self.data[o + 2], .a = 255 },
            else => .{ .r = self.data[o], .g = self.data[o + 1], .b = self.data[o + 2], .a = self.data[o + 3] },
        };
    }
};

/// The region of the source to draw, and the cells to draw it into.
pub const Placement = struct {
    /// Destination, in cells, within `win`.
    col: u16,
    row: u16,
    cols: u16,
    rows: u16,
    /// Source rectangle in pixels. A zero width or height means the whole image.
    src_x: u32 = 0,
    src_y: u32 = 0,
    src_w: u32 = 0,
    src_h: u32 = 0,
};

/// Paint an image into a window as half blocks.
///
/// Cells whose two halves are both transparent are left completely alone, so an
/// image with an alpha channel does not punch a rectangle through the text it
/// is drawn over.
pub fn paint(win: vaxis.Window, src: Source, p: Placement) void {
    if (p.cols == 0 or p.rows == 0) return;

    const sx = @min(p.src_x, src.width -| 1);
    const sy = @min(p.src_y, src.height -| 1);
    const sw = if (p.src_w == 0) src.width - sx else @min(p.src_w, src.width - sx);
    const sh = if (p.src_h == 0) src.height - sy else @min(p.src_h, src.height - sy);
    if (sw == 0 or sh == 0) return;

    // Two half-rows of pixels per row of cells.
    const half_rows: u32 = @as(u32, p.rows) * 2;

    var cy: u16 = 0;
    while (cy < p.rows) : (cy += 1) {
        const y = p.row + cy;
        if (y >= win.height) break;

        var cx: u16 = 0;
        while (cx < p.cols) : (cx += 1) {
            const x = p.col + cx;
            if (x >= win.width) break;

            const top = sample(src, sx, sy, sw, sh, cx, p.cols, @as(u32, cy) * 2, half_rows);
            const bottom = sample(src, sx, sy, sw, sh, cx, p.cols, @as(u32, cy) * 2 + 1, half_rows);

            const top_on = top.a >= alpha_threshold;
            const bottom_on = bottom.a >= alpha_threshold;
            if (!top_on and !bottom_on) continue;

            var cell: vaxis.Cell = .{};
            if (top_on and bottom_on) {
                cell.char = .{ .grapheme = upper_half, .width = 1 };
                cell.style.fg = .{ .rgb = .{ top.r, top.g, top.b } };
                cell.style.bg = .{ .rgb = .{ bottom.r, bottom.g, bottom.b } };
            } else if (top_on) {
                // Only the foreground is painted, so whatever the terminal has
                // as its background shows through the bottom half.
                cell.char = .{ .grapheme = upper_half, .width = 1 };
                cell.style.fg = .{ .rgb = .{ top.r, top.g, top.b } };
            } else {
                cell.char = .{ .grapheme = lower_half, .width = 1 };
                cell.style.fg = .{ .rgb = .{ bottom.r, bottom.g, bottom.b } };
            }
            win.writeCell(x, y, cell);
        }
    }
}

/// Average the source pixels covered by one half cell.
///
/// Alpha is averaged with the colour, and the colour is weighted by it, so a
/// half cell that is mostly transparent does not take the colour of the few
/// opaque pixels in it at full strength.
fn sample(
    src: Source,
    sx: u32,
    sy: u32,
    sw: u32,
    sh: u32,
    cx: u16,
    cols: u16,
    half_y: u32,
    half_rows: u32,
) Rgba {
    const x0 = sx + (@as(u64, cx) * sw) / cols;
    const x1 = sx + (@as(u64, cx + 1) * sw) / cols;
    const y0 = sy + (@as(u64, half_y) * sh) / half_rows;
    const y1 = sy + (@as(u64, half_y + 1) * sh) / half_rows;

    const w = @max(1, x1 - x0);
    const h = @max(1, y1 - y0);
    const nx = @min(taps, @as(u32, @intCast(w)));
    const ny = @min(taps, @as(u32, @intCast(h)));

    var r: u64 = 0;
    var g: u64 = 0;
    var b: u64 = 0;
    var a: u64 = 0;
    var n: u64 = 0;

    var j: u32 = 0;
    while (j < ny) : (j += 1) {
        // Sample at tap centres so an edge pixel is not counted twice.
        const py = @as(u32, @intCast(y0)) + @as(u32, @intCast((@as(u64, j) * 2 + 1) * h / (@as(u64, ny) * 2)));
        var i: u32 = 0;
        while (i < nx) : (i += 1) {
            const px = @as(u32, @intCast(x0)) + @as(u32, @intCast((@as(u64, i) * 2 + 1) * w / (@as(u64, nx) * 2)));
            const c = src.at(px, py);
            r += @as(u64, c.r) * c.a;
            g += @as(u64, c.g) * c.a;
            b += @as(u64, c.b) * c.a;
            a += c.a;
            n += 1;
        }
    }

    if (n == 0 or a == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    return .{
        .r = @intCast(r / a),
        .g = @intCast(g / a),
        .b = @intCast(b / a),
        .a = @intCast(a / n),
    };
}

const testing = std.testing;

test "half blocks carry two rows of pixels per row of cells" {
    // Two pixels tall, one wide: red over blue. That is one cell.
    const pixels = [_]u8{ 255, 0, 0, 255, 0, 0, 255, 255 };
    const src: Source = .{ .data = &pixels, .width = 1, .height = 2, .bpp = 4 };

    try testing.expectEqual(Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 }, src.at(0, 0));
    try testing.expectEqual(Rgba{ .r = 0, .g = 0, .b = 255, .a = 255 }, src.at(0, 1));

    const top = sample(src, 0, 0, 1, 2, 0, 1, 0, 2);
    const bottom = sample(src, 0, 0, 1, 2, 0, 1, 1, 2);
    try testing.expectEqual(@as(u8, 255), top.r);
    try testing.expectEqual(@as(u8, 255), bottom.b);
}

test "sampling averages a downscaled region rather than picking one pixel" {
    // Four pixels across: two black, two white. Scaled into one cell column,
    // the average is mid grey rather than whichever pixel a point landed on.
    const pixels = [_]u8{
        0,   0,   0,   255,
        0,   0,   0,   255,
        255, 255, 255, 255,
        255, 255, 255, 255,
    };
    const src: Source = .{ .data = &pixels, .width = 4, .height = 1, .bpp = 4 };
    const c = sample(src, 0, 0, 4, 1, 0, 1, 0, 1);
    try testing.expect(c.r > 100 and c.r < 155);
}

test "a transparent half leaves the background alone" {
    const pixels = [_]u8{ 255, 0, 0, 255, 0, 0, 0, 0 };
    const src: Source = .{ .data = &pixels, .width = 1, .height = 2, .bpp = 4 };
    const bottom = sample(src, 0, 0, 1, 2, 0, 1, 1, 2);
    try testing.expect(bottom.a < alpha_threshold);
}

test "Source rejects an image whose data is short" {
    // Mirrors ghostty's format enum, `png` included: an image still encoded
    // has no pixels to sample and must be refused, not misread as raw bytes.
    const Fake = struct {
        format: enum { gray, gray_alpha, rgb, rgba, png },
        width: u32,
        height: u32,
        data: []const u8,
    };
    const short: Fake = .{ .format = .rgba, .width = 4, .height = 4, .data = &[_]u8{0} ** 8 };
    try testing.expect(Source.from(short) == null);

    const ok: Fake = .{ .format = .rgb, .width = 2, .height = 1, .data = &[_]u8{0} ** 6 };
    try testing.expect(Source.from(ok) != null);

    const encoded: Fake = .{ .format = .png, .width = 2, .height = 1, .data = &[_]u8{0} ** 64 };
    try testing.expect(Source.from(encoded) == null);
}
