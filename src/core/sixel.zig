//! A sixel decoder.
//!
//! Sixel is the other way a program puts an image on a terminal, and the older
//! one: `img2sixel`, `timg`, `chafa -f sixel`, matplotlib's sixel backend, and
//! every tool written before the Kitty protocol existed. ghostty's VT does not
//! implement it, so without this a pane running any of them shows nothing.
//!
//! hexe decodes sixel to pixels and hands the pixels to ghostty's Kitty image
//! storage, which means the mux accepts one protocol and emits whichever one
//! the host terminal actually speaks. The decoder is deliberately standalone --
//! bytes in, RGBA out -- so it can be tested without a terminal.
//!
//! The format: after `ESC P <P1>;<P2>;<P3> q` comes a stream where each
//! printable character from `?` to `~` carries SIX vertical pixels (hence the
//! name), one bit each, in the current colour. `$` returns to the left margin,
//! `-` moves down a band of six, `#` selects or defines a palette entry, `!`
//! repeats the next character, and `"` declares the raster size.

const std = @import("std");

pub const Error = error{
    InvalidData,
    ImageTooLarge,
    OutOfMemory,
};

pub const Limits = struct {
    /// Largest side, in pixels. Sixel carries no length prefix, so a stream
    /// that never terminates would otherwise grow the canvas forever.
    max_dimension: u32 = 8192,
    /// Largest decoded image, in bytes of RGBA.
    max_bytes: usize = 64 * 1024 * 1024,
};

pub const Image = struct {
    width: u32,
    height: u32,
    /// Row-major RGBA. Owned by the caller.
    rgba: []u8,

    pub fn deinit(self: *Image, alloc: std.mem.Allocator) void {
        alloc.free(self.rgba);
        self.* = undefined;
    }
};

const Rgb = struct { r: u8, g: u8, b: u8 };

/// The VT340's sixteen colours, in the 0-100 scale the protocol uses. Entries
/// past these start black, which is what a terminal that has never been told
/// about a colour shows.
const default_palette = [16]Rgb{
    pct(0, 0, 0),    pct(20, 20, 80), pct(80, 13, 13), pct(20, 80, 20),
    pct(80, 20, 80), pct(20, 80, 80), pct(80, 80, 20), pct(53, 53, 53),
    pct(26, 26, 26), pct(33, 33, 60), pct(60, 26, 26), pct(33, 60, 33),
    pct(60, 33, 60), pct(33, 60, 60), pct(60, 60, 33), pct(80, 80, 80),
};

fn pct(r: u32, g: u32, b: u32) Rgb {
    return .{ .r = scale(r), .g = scale(g), .b = scale(b) };
}

fn scale(v: u32) u8 {
    return @intCast(@min(255, (v * 255 + 50) / 100));
}

/// Decode a sixel payload: everything between the `ESC P` introducer and the
/// terminating ST, introducer parameters included.
pub fn decode(alloc: std.mem.Allocator, payload: []const u8, limits: Limits) Error!Image {
    var d: Decoder = .{ .alloc = alloc, .limits = limits };
    errdefer d.canvas.deinit(alloc);
    try d.run(payload);
    return d.finish(alloc);
}

const Decoder = struct {
    alloc: std.mem.Allocator,
    limits: Limits,

    canvas: std.ArrayListUnmanaged(u8) = .empty,
    /// Allocated canvas size, which may exceed the used size.
    cap_w: u32 = 0,
    cap_h: u32 = 0,
    /// Used size: the furthest any pixel was actually written, plus one.
    used_w: u32 = 0,
    used_h: u32 = 0,

    palette: [256]Rgb = undefined,
    color: u8 = 0,
    /// Left-to-right position within the current band.
    x: u32 = 0,
    /// Top pixel row of the current band of six.
    band_y: u32 = 0,

    fn run(self: *Decoder, payload: []const u8) Error!void {
        self.palette = @splat(.{ .r = 0, .g = 0, .b = 0 });
        @memcpy(self.palette[0..default_palette.len], &default_palette);

        var i: usize = 0;
        // Introducer parameters, up to and including the `q`. Nothing in them
        // changes the pixels: P1 is an aspect ratio hexe does not honour, and
        // P2 selects whether unset pixels are background or transparent --
        // transparent is the only honest answer for a mux, which does not know
        // what is behind the image.
        while (i < payload.len and payload[i] != 'q') : (i += 1) {
            switch (payload[i]) {
                '0'...'9', ';', ':' => {},
                else => return error.InvalidData,
            }
        }
        if (i >= payload.len) return error.InvalidData;
        i += 1;

        while (i < payload.len) {
            const c = payload[i];
            switch (c) {
                '"' => i = try self.raster(payload, i + 1),
                '#' => i = try self.colorCommand(payload, i + 1),
                '!' => i = try self.repeat(payload, i + 1),
                '$' => {
                    self.x = 0;
                    i += 1;
                },
                '-' => {
                    self.x = 0;
                    self.band_y += 6;
                    i += 1;
                },
                '?'...'~' => {
                    try self.put(c, 1);
                    i += 1;
                },
                // Whitespace between commands is not part of the format, but
                // encoders emit newlines to keep lines short and every real
                // terminal ignores them.
                '\r', '\n', ' ', '\t' => i += 1,
                else => return error.InvalidData,
            }
        }
    }

    /// `"Pan;Pad;Ph;Pv` -- the last two are the image size, which lets the
    /// canvas be allocated once instead of grown band by band.
    fn raster(self: *Decoder, payload: []const u8, start: usize) Error!usize {
        var params: [4]u32 = @splat(0);
        const next = parseParams(payload, start, &params);
        const w = params[2];
        const h = params[3];
        if (w > 0 and h > 0) try self.reserve(w, h);
        return next;
    }

    /// `#Pc` selects a colour; `#Pc;Pu;Px;Py;Pz` defines one.
    fn colorCommand(self: *Decoder, payload: []const u8, start: usize) Error!usize {
        var params: [5]u32 = @splat(0);
        const next = parseParams(payload, start, &params);
        const idx: u8 = @intCast(params[0] % 256);
        self.color = idx;

        // A bare selector leaves the palette alone.
        if (next - start <= digitsOf(params[0])) return next;

        self.palette[idx] = switch (params[1]) {
            2 => pct(@min(100, params[2]), @min(100, params[3]), @min(100, params[4])),
            1 => hlsToRgb(params[2], params[3], params[4]),
            // An unknown colour space is not worth failing the whole image
            // over; the entry keeps whatever it had.
            else => self.palette[idx],
        };
        return next;
    }

    /// `!Pn<char>` -- the character that follows is repeated Pn times.
    fn repeat(self: *Decoder, payload: []const u8, start: usize) Error!usize {
        var params: [1]u32 = @splat(0);
        const next = parseParams(payload, start, &params);
        if (next >= payload.len) return error.InvalidData;
        const c = payload[next];
        if (c < '?' or c > '~') return error.InvalidData;
        try self.put(c, params[0]);
        return next + 1;
    }

    /// Write one sixel character `count` times: six stacked pixels per column,
    /// one bit each, in the current colour.
    fn put(self: *Decoder, c: u8, count: u32) Error!void {
        const bits: u8 = c - '?';
        if (count == 0) return;

        const end_x = self.x + count;
        if (end_x > self.limits.max_dimension) return error.ImageTooLarge;

        // A zero bit means "leave this pixel alone" -- sixel composites, so a
        // later pass can draw over an earlier one in a different colour.
        if (bits != 0) {
            try self.reserve(end_x, self.band_y + 6);
            const rgb = self.palette[self.color];
            for (0..6) |bit| {
                if (bits & (@as(u8, 1) << @intCast(bit)) == 0) continue;
                const y = self.band_y + @as(u32, @intCast(bit));
                var x = self.x;
                while (x < end_x) : (x += 1) self.set(x, y, rgb);
            }
            if (end_x > self.used_w) self.used_w = end_x;
            const bottom = self.band_y + highestBit(bits) + 1;
            if (bottom > self.used_h) self.used_h = bottom;
        }

        self.x = end_x;
    }

    fn set(self: *Decoder, x: u32, y: u32, rgb: Rgb) void {
        const o = (@as(usize, y) * self.cap_w + x) * 4;
        self.canvas.items[o] = rgb.r;
        self.canvas.items[o + 1] = rgb.g;
        self.canvas.items[o + 2] = rgb.b;
        self.canvas.items[o + 3] = 255;
    }

    /// Grow the canvas to hold at least `w` x `h`, preserving what is drawn.
    fn reserve(self: *Decoder, w: u32, h: u32) Error!void {
        if (w <= self.cap_w and h <= self.cap_h) return;
        if (w > self.limits.max_dimension or h > self.limits.max_dimension) {
            return error.ImageTooLarge;
        }

        // Grow in steps rather than to the exact size: a canvas with no raster
        // attributes gains six rows per band, and reallocating per band on a
        // tall image is quadratic.
        const new_w = @max(self.cap_w, roundUp(w, 256));
        const new_h = @max(self.cap_h, roundUp(h, 96));
        const bytes = @as(usize, new_w) * @as(usize, new_h) * 4;
        if (bytes > self.limits.max_bytes) return error.ImageTooLarge;

        var next: std.ArrayListUnmanaged(u8) = .empty;
        try next.appendNTimes(self.alloc, 0, bytes);
        // Transparent, not black: hexe does not know what is behind the image,
        // and a black rectangle around a logo on a light theme is a bug report.
        for (0..self.used_h) |y| {
            const src = y * @as(usize, self.cap_w) * 4;
            const dst = y * @as(usize, new_w) * 4;
            const row = @as(usize, self.used_w) * 4;
            @memcpy(next.items[dst .. dst + row], self.canvas.items[src .. src + row]);
        }
        self.canvas.deinit(self.alloc);
        self.canvas = next;
        self.cap_w = new_w;
        self.cap_h = new_h;
    }

    /// On error the canvas is left alone for `decode`'s errdefer to release,
    /// which is the only path that owns it.
    fn finish(self: *Decoder, alloc: std.mem.Allocator) Error!Image {
        if (self.used_w == 0 or self.used_h == 0) return error.InvalidData;

        // Trim the growth padding off each row so the image is exactly the
        // size that was drawn.
        const w = self.used_w;
        const h = self.used_h;
        const out = try alloc.alloc(u8, @as(usize, w) * @as(usize, h) * 4);
        for (0..h) |y| {
            const src = y * @as(usize, self.cap_w) * 4;
            const dst = y * @as(usize, w) * 4;
            @memcpy(out[dst .. dst + @as(usize, w) * 4], self.canvas.items[src .. src + @as(usize, w) * 4]);
        }
        self.canvas.deinit(alloc);
        self.canvas = .empty;
        return .{ .width = w, .height = h, .rgba = out };
    }
};

fn roundUp(v: u32, step: u32) u32 {
    return ((v + step - 1) / step) * step;
}

fn highestBit(bits: u8) u32 {
    var i: u32 = 5;
    while (true) : (i -= 1) {
        if (bits & (@as(u8, 1) << @intCast(i)) != 0) return i;
        if (i == 0) return 0;
    }
}

fn digitsOf(v: u32) usize {
    var n: usize = 1;
    var x = v;
    while (x >= 10) : (x /= 10) n += 1;
    return n;
}

/// Read `;`-separated decimal parameters, stopping at the first byte that is
/// neither a digit nor a separator.
fn parseParams(payload: []const u8, start: usize, out: []u32) usize {
    var i = start;
    var slot: usize = 0;
    var seen = false;
    var acc: u32 = 0;
    while (i < payload.len) : (i += 1) {
        switch (payload[i]) {
            '0'...'9' => {
                seen = true;
                acc = acc *| 10 +| (payload[i] - '0');
            },
            ';' => {
                if (slot < out.len) out[slot] = acc;
                slot += 1;
                acc = 0;
                seen = false;
            },
            else => break,
        }
    }
    if (seen and slot < out.len) out[slot] = acc;
    return i;
}

/// Sixel's HLS, which is not the usual one: hue is measured from blue, and
/// lightness and saturation are percentages.
fn hlsToRgb(h: u32, l: u32, s: u32) Rgb {
    const hue = @as(f32, @floatFromInt(h % 360));
    const lig = @as(f32, @floatFromInt(@min(100, l))) / 100.0;
    const sat = @as(f32, @floatFromInt(@min(100, s))) / 100.0;

    if (sat == 0) {
        const v: u8 = @intFromFloat(@round(lig * 255.0));
        return .{ .r = v, .g = v, .b = v };
    }

    const c = (1.0 - @abs(2.0 * lig - 1.0)) * sat;
    // DEC measures hue from blue rather than red.
    const hp = @mod(hue + 240.0, 360.0) / 60.0;
    const x = c * (1.0 - @abs(@mod(hp, 2.0) - 1.0));
    const m = lig - c / 2.0;

    const rgb: [3]f32 = switch (@as(u32, @intFromFloat(hp))) {
        0 => .{ c, x, 0 },
        1 => .{ x, c, 0 },
        2 => .{ 0, c, x },
        3 => .{ 0, x, c },
        4 => .{ x, 0, c },
        else => .{ c, 0, x },
    };
    return .{
        .r = @intFromFloat(@round(std.math.clamp(rgb[0] + m, 0, 1) * 255.0)),
        .g = @intFromFloat(@round(std.math.clamp(rgb[1] + m, 0, 1) * 255.0)),
        .b = @intFromFloat(@round(std.math.clamp(rgb[2] + m, 0, 1) * 255.0)),
    };
}

const testing = std.testing;

fn pixel(img: Image, x: u32, y: u32) [4]u8 {
    const o = (@as(usize, y) * img.width + x) * 4;
    return .{ img.rgba[o], img.rgba[o + 1], img.rgba[o + 2], img.rgba[o + 3] };
}

test "sixel: one column of six pixels in a defined colour" {
    // Colour 1 as pure red, then `~` = 0x7E - 0x3F = 0x3F: all six bits set.
    var img = try decode(testing.allocator, "0;1;0q#1;2;100;0;0#1~", .{});
    defer img.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), img.width);
    try testing.expectEqual(@as(u32, 6), img.height);
    for (0..6) |y| {
        try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(img, 0, @intCast(y)));
    }
}

test "sixel: repeat, bands and partial columns" {
    // `!4~` fills four columns, `-` drops a band, `@` (0x40) sets only bit 0.
    var img = try decode(testing.allocator, "q#0;2;0;100;0!4~-#0@", .{});
    defer img.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 4), img.width);
    // Six rows from the first band plus one from the second.
    try testing.expectEqual(@as(u32, 7), img.height);
    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, pixel(img, 3, 5));
    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, pixel(img, 0, 6));
    // Column 1 of the second band was never drawn, so it stays transparent.
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, pixel(img, 1, 6));
}

test "sixel: carriage return overdraws in a second colour" {
    // Draw red, return to the left margin, draw blue over the top half.
    var img = try decode(
        testing.allocator,
        "q#1;2;100;0;0!2~$#2;2;0;0;100!2A",
        .{},
    );
    defer img.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 2), img.width);
    // `A` = 0x41 - 0x3F = 2, i.e. bit 1 only: row 1 becomes blue.
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, pixel(img, 0, 1));
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(img, 0, 0));
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(img, 1, 5));
}

test "sixel: raster attributes size the canvas up front" {
    var img = try decode(testing.allocator, "q\"1;1;4;12#1;2;100;100;100~", .{});
    defer img.deinit(testing.allocator);

    // The raster size is a hint for allocation; the image is still trimmed to
    // what was actually drawn, which is one column of six.
    try testing.expectEqual(@as(u32, 1), img.width);
    try testing.expectEqual(@as(u32, 6), img.height);
}

test "sixel: refuses runaway and malformed input" {
    try testing.expectError(error.ImageTooLarge, decode(
        testing.allocator,
        "q!9999999~",
        .{ .max_dimension = 64 },
    ));
    // No `q`, so it never reaches the data.
    try testing.expectError(error.InvalidData, decode(testing.allocator, "0;1;0", .{}));
    // Nothing drawn at all.
    try testing.expectError(error.InvalidData, decode(testing.allocator, "q", .{}));
}

test "sixel: default palette applies without a colour definition" {
    var img = try decode(testing.allocator, "q#1~", .{});
    defer img.deinit(testing.allocator);

    // Palette entry 1 is the VT340's blue: 20/20/80 percent.
    try testing.expectEqual([4]u8{ 51, 51, 204, 255 }, pixel(img, 0, 0));
}
