const std = @import("std");
const vaxis = @import("vaxis");

const render_vx = @import("render_vx.zig");
const core = @import("core");

pub const CursorInfo = struct {
    x: u16 = 0,
    y: u16 = 0,
    style: u8 = 0,
    visible: bool = true,
};

/// Differential renderer that tracks state and only emits changed cells.
/// Static ASCII lookup table — `ascii_lut[c..][0..1]` is a valid single-byte
/// slice with static lifetime, so ASCII cells need no arena allocation at all.
/// Mirrors the same table in vt_bridge.zig.
const ascii_lut: [128]u8 = initAsciiLut();

fn initAsciiLut() [128]u8 {
    var table: [128]u8 = undefined;
    for (0..128) |i| table[i] = @intCast(i);
    return table;
}

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    vx: vaxis.Vaxis,
    frame_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Renderer {
        var vx = try vaxis.Vaxis.init(allocator, .{
            .kitty_keyboard_flags = .{
                .disambiguate = true,
                .report_events = true,
                .report_alternate_keys = true,
                .report_all_as_ctl_seqs = true,
                .report_text = true,
            },
            .system_clipboard_allocator = allocator,
        });
        try render_vx.initVaxisForSize(allocator, &vx, width, height);

        return .{
            .allocator = allocator,
            .vx = vx,
            .frame_arena = .init(allocator),
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.frame_arena.deinit();
        self.vx.screen.deinit(self.allocator);
        self.vx.screen_last.deinit(self.allocator);
    }

    pub fn resize(self: *Renderer, width: u16, height: u16) !void {
        try render_vx.resizeVaxisForSize(self.allocator, &self.vx, width, height);
    }

    pub fn setVaxisCell(self: *Renderer, x: u16, y: u16, cell: vaxis.Cell) void {
        if (x >= self.vx.screen.width or y >= self.vx.screen.height) return;

        var stable = cell;
        const grapheme = cell.char.grapheme;
        if (grapheme.len == 1 and grapheme[0] < ascii_lut.len) {
            // Single-byte ASCII — the vast majority of cells, and every cell of
            // a background fill — points at static storage instead of the frame
            // arena. Duping unconditionally made the arena grow ~200KB/s with
            // one medium float on screen (drawBorderFrame alone fills a float's
            // whole rect one putChar at a time), so every ~30s it crossed the
            // 8MB reset threshold and forced an invalidate + full repaint that
            // the user sees as a periodic flash.
            stable.char.grapheme = ascii_lut[grapheme[0]..][0..1];
        } else if (grapheme.len > 0) {
            // The screen stores this slice across frames; a transient caller
            // buffer must never leak into it (grapheme iteration over a dead
            // pointer is a segfault). On OOM, drop the glyph rather than
            // store the caller's pointer.
            stable.char.grapheme = self.frame_arena.allocator().dupe(u8, grapheme) catch " ";
        }
        // Everything hexe draws itself lands here -- borders, the status bar,
        // float titles, popups, overlays, notifications, selection -- and
        // nothing else does: pane content goes through the window writer in
        // vt_bridge. So this is the one place that resolves chrome through
        // hexe's reserved namespace.
        stable.style.fg = hexeColor(stable.style.fg);
        stable.style.bg = hexeColor(stable.style.bg);
        stable.style.ul = hexeColor(stable.style.ul);
        self.vx.screen.writeCell(x, y, stable);
    }

    /// An indexed chrome colour, resolved through hexe's own palette.
    ///
    /// Untouched entries pass the index straight through, so a default install
    /// emits exactly the bytes it always did.
    inline fn hexeColor(c: vaxis.Color) vaxis.Color {
        return switch (c) {
            .index => |i| switch (core.palette.resolveHexeIndex(i)) {
                .passthrough => c,
                .rgb => |v| .{ .rgb = .{ v.r, v.g, v.b } },
            },
            else => c,
        };
    }

    pub fn getVaxisCell(self: *const Renderer, x: u16, y: u16) ?vaxis.Cell {
        if (x >= self.vx.screen.width or y >= self.vx.screen.height) return null;
        return self.vx.screen.readCell(x, y);
    }

    pub fn screenWidth(self: *const Renderer) u16 {
        return self.vx.screen.width;
    }

    pub fn invalidate(self: *Renderer) void {
        self.vx.screen.clear();
        self.vx.refresh = true;
    }
};
