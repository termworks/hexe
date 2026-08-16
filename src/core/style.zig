const std = @import("std");
const vaxis = @import("vaxis");
const log = std.log.scoped(.style);

/// Color representation - compatible with mux/render_types.zig Color
pub const Color = union(enum) {
    none,
    palette: u8, // 0-255
    rgb: RGB,

    pub const RGB = struct {
        r: u8,
        g: u8,
        b: u8,
    };

    /// Parse a color from string
    /// Supports: "red", "1", "237", "#ff5500", "rgb(255,85,0)"
    pub fn parse(str: []const u8) ?Color {
        const trimmed = std.mem.trim(u8, str, " \t");
        if (trimmed.len == 0) return null;

        // Named colors
        if (fromName(trimmed)) |c| return c;

        // Hex color: #RRGGBB or #RGB
        if (trimmed[0] == '#') {
            return parseHex(trimmed[1..]);
        }

        // Numeric palette: just a number
        const num = std.fmt.parseInt(u8, trimmed, 10) catch |err| {
            log.debug("failed to parse palette color '{s}': {}", .{ trimmed, err });
            return null;
        };
        return .{ .palette = num };
    }

    fn parseHex(hex: []const u8) ?Color {
        if (hex.len == 6) {
            const r = std.fmt.parseInt(u8, hex[0..2], 16) catch |err| {
                log.debug("failed to parse red hex color component '{s}': {}", .{ hex[0..2], err });
                return null;
            };
            const g = std.fmt.parseInt(u8, hex[2..4], 16) catch |err| {
                log.debug("failed to parse green hex color component '{s}': {}", .{ hex[2..4], err });
                return null;
            };
            const b = std.fmt.parseInt(u8, hex[4..6], 16) catch |err| {
                log.debug("failed to parse blue hex color component '{s}': {}", .{ hex[4..6], err });
                return null;
            };
            return .{ .rgb = .{ .r = r, .g = g, .b = b } };
        } else if (hex.len == 3) {
            const r = std.fmt.parseInt(u8, hex[0..1], 16) catch |err| {
                log.debug("failed to parse short red hex color component '{s}': {}", .{ hex[0..1], err });
                return null;
            };
            const g = std.fmt.parseInt(u8, hex[1..2], 16) catch |err| {
                log.debug("failed to parse short green hex color component '{s}': {}", .{ hex[1..2], err });
                return null;
            };
            const b = std.fmt.parseInt(u8, hex[2..3], 16) catch |err| {
                log.debug("failed to parse short blue hex color component '{s}': {}", .{ hex[2..3], err });
                return null;
            };
            return .{ .rgb = .{ .r = r * 17, .g = g * 17, .b = b * 17 } };
        }
        return null;
    }

    /// Named color lookup
    pub fn fromName(name: []const u8) ?Color {
        const names = std.StaticStringMap(u8).initComptime(.{
            .{ "black", 0 },
            .{ "red", 1 },
            .{ "green", 2 },
            .{ "yellow", 3 },
            .{ "blue", 4 },
            .{ "magenta", 5 },
            .{ "purple", 5 },
            .{ "cyan", 6 },
            .{ "white", 7 },
            .{ "bright_black", 8 },
            .{ "bright_red", 9 },
            .{ "bright_green", 10 },
            .{ "bright_yellow", 11 },
            .{ "bright_blue", 12 },
            .{ "bright_magenta", 13 },
            .{ "bright_cyan", 14 },
            .{ "bright_white", 15 },
        });

        if (names.get(name)) |idx| {
            return .{ .palette = idx };
        }
        return null;
    }

    /// Convert to libvaxis color representation.
    pub fn toVaxis(self: Color) vaxis.Color {
        return switch (self) {
            .none => .default,
            .palette => |idx| .{ .index = idx },
            .rgb => |rgb| .{ .rgb = .{ rgb.r, rgb.g, rgb.b } },
        };
    }
};

/// Style with foreground, background, and attributes
pub const Style = struct {
    fg: Color = .none,
    bg: Color = .none,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    dim: bool = false,

    /// Parse a style string like "bold bg:237 fg:15" or "bg:1 fg:0"
    pub fn parse(str: []const u8) Style {
        var result = Style{};
        var iter = std.mem.tokenizeAny(u8, str, " \t");

        while (iter.next()) |token| {
            // Check for fg:COLOR or bg:COLOR
            if (std.mem.startsWith(u8, token, "fg:")) {
                if (Color.parse(token[3..])) |c| {
                    result.fg = c;
                }
            } else if (std.mem.startsWith(u8, token, "bg:")) {
                if (Color.parse(token[3..])) |c| {
                    result.bg = c;
                }
            } else if (std.mem.eql(u8, token, "bold")) {
                result.bold = true;
            } else if (std.mem.eql(u8, token, "italic")) {
                result.italic = true;
            } else if (std.mem.eql(u8, token, "underline")) {
                result.underline = true;
            } else if (std.mem.eql(u8, token, "dim")) {
                result.dim = true;
            } else {
                // Try as a color name or number (defaults to foreground)
                if (Color.parse(token)) |c| {
                    result.fg = c;
                }
            }
        }

        return result;
    }

    /// Check if style has any attributes set
    pub fn isEmpty(self: Style) bool {
        return self.fg == .none and self.bg == .none and
            !self.bold and !self.italic and !self.underline and !self.dim;
    }

    /// Convert to libvaxis style representation.
    pub fn toVaxis(self: Style) vaxis.Style {
        return .{
            .fg = self.fg.toVaxis(),
            .bg = self.bg.toVaxis(),
            .bold = self.bold,
            .italic = self.italic,
            .dim = self.dim,
            .ul_style = if (self.underline) .single else .off,
        };
    }
};
