const std = @import("std");

/// Horizontal alignment
pub const Align = enum {
    left,
    center,
    right,

    pub fn fromString(s: []const u8) Align {
        if (std.mem.eql(u8, s, "left")) return .left;
        if (std.mem.eql(u8, s, "right")) return .right;
        return .center;
    }
};

/// Vertical position
pub const Position = enum {
    top,
    center,
    bottom,
};

/// Color representation (matches mux/render_types.zig)
pub const Color = union(enum) {
    none,
    palette: u8,
    rgb: RGB,

    pub const RGB = struct {
        r: u8,
        g: u8,
        b: u8,

        pub fn eql(self: RGB, other: RGB) bool {
            return self.r == other.r and self.g == other.g and self.b == other.b;
        }
    };

    pub fn eql(self: Color, other: Color) bool {
        return switch (self) {
            .none => other == .none,
            .palette => |p| other == .palette and other.palette == p,
            .rgb => |rgb| other == .rgb and rgb.eql(other.rgb),
        };
    }
};

/// Style configuration for popups
pub const Style = struct {
    fg: Color = .{ .palette = 0 }, // black text
    bg: Color = .{ .palette = 1 }, // red background (default)
    bold: bool = true,
    padding_x: u16 = 1, // horizontal padding inside box
    padding_y: u16 = 0, // vertical padding inside box
    offset: u16 = 1, // cells from edge
    alignment: Align = .center,

    /// Create style from config
    pub fn fromConfig(cfg: anytype) Style {
        return .{
            .fg = .{ .palette = cfg.fg },
            .bg = .{ .palette = cfg.bg },
            .bold = cfg.bold,
            .padding_x = cfg.padding_x,
            .padding_y = cfg.padding_y,
            .offset = cfg.offset,
            .alignment = Align.fromString(cfg.alignment),
        };
    }

    /// Create a default style with given colors
    pub fn withColors(fg_palette: u8, bg_palette: u8) Style {
        return .{
            .fg = .{ .palette = fg_palette },
            .bg = .{ .palette = bg_palette },
        };
    }
};

/// Bounds for rendering popups
pub const Bounds = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn init(x: u16, y: u16, width: u16, height: u16) Bounds {
        return .{ .x = x, .y = y, .width = width, .height = height };
    }

    /// Create bounds for full screen
    pub fn fullScreen(width: u16, height: u16) Bounds {
        return .{ .x = 0, .y = 0, .width = width, .height = height };
    }

    /// Calculate centered position for a box of given size within these bounds
    pub fn centerBox(self: Bounds, box_width: u16, box_height: u16) struct { x: u16, y: u16 } {
        return .{
            .x = self.x + (self.width -| box_width) / 2,
            .y = self.y + (self.height -| box_height) / 2,
        };
    }

    /// Calculate position for a box with given alignment
    pub fn alignBox(self: Bounds, box_width: u16, box_height: u16, h_align: Align, v_pos: Position, offset: u16) struct { x: u16, y: u16 } {
        const x: u16 = switch (h_align) {
            .left => self.x + offset,
            .center => self.x + (self.width -| box_width) / 2,
            .right => self.x + self.width -| box_width -| offset,
        };
        const y: u16 = switch (v_pos) {
            .top => self.y + offset,
            .center => self.y + (self.height -| box_height) / 2,
            .bottom => self.y + self.height -| box_height -| offset,
        };
        return .{ .x = x, .y = y };
    }
};

/// Input handling result
pub const InputResult = enum {
    consumed, // Input handled, popup still active
    dismissed, // Popup done, remove it
    pass_through, // Input not handled, let caller process
};

/// Structured popup key event.
///
/// Keeping arrows and control keys distinct from printable ASCII letters lets
/// filterable pickers navigate with arrows while typing `j`/`k`/`h`/`l` into
/// the search query.
pub const PopupKey = union(enum) {
    up,
    down,
    left,
    right,
    page_up,
    page_down,
    home,
    end,
    enter,
    tab,
    shift_tab,
    backspace,
    escape,
    ctrl_c,
    ctrl_u,
    char: u8,

    pub fn fromByte(key: u8) PopupKey {
        return switch (key) {
            '\r', '\n' => .enter,
            '\t' => .tab,
            0x08, 0x7f => .backspace,
            27 => .escape,
            0x03 => .ctrl_c,
            0x15 => .ctrl_u,
            else => .{ .char = key },
        };
    }
};
