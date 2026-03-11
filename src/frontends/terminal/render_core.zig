const std = @import("std");
const vaxis = @import("vaxis");

const render_vx = @import("render_vx.zig");

pub const CursorInfo = struct {
    x: u16 = 0,
    y: u16 = 0,
    style: u8 = 0,
    visible: bool = true,
};

/// Differential renderer that tracks state and only emits changed cells.
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
        if (cell.char.grapheme.len > 0) {
            stable.char.grapheme = self.frame_arena.allocator().dupe(u8, cell.char.grapheme) catch cell.char.grapheme;
        }
        self.vx.screen.writeCell(x, y, stable);
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
