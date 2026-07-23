const std = @import("std");
const core = @import("core");
const sprites_embedded = core.sprites_embedded;

/// Pokemon widget configuration
pub const PokemonConfig = struct {
    enabled: bool = false,
    position: Position = .topright,
    shiny_chance: f32 = 0.01,
};

/// Widget position options
pub const Position = enum {
    topleft,
    topright,
    bottomleft,
    bottomright,
    center,
};

/// Pokemon sprite display state for a single pane
pub const PokemonState = struct {
    show_sprite: bool = false,
    sprite_name: ?[]const u8 = null,
    sprite_content: ?[]const u8 = null,
    manually_toggled: bool = false, // Track if user has manually toggled
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PokemonState {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PokemonState) void {
        if (self.sprite_content) |content| {
            self.allocator.free(content);
        }
        self.* = .{ .allocator = self.allocator };
    }

    /// Load a sprite by name from embedded sprite data
    pub fn loadSprite(self: *PokemonState, name: []const u8, shiny: bool) !void {
        // Clean up previous sprite
        if (self.sprite_content) |content| {
            self.allocator.free(content);
            self.sprite_content = null;
        }

        // Inflate the sprite out of the embedded compressed archive.
        const content = try sprites_embedded.getSpriteAlloc(self.allocator, name, shiny);

        self.sprite_content = content;
        self.sprite_name = name;
        self.show_sprite = true;
    }

    /// Toggle sprite display
    pub fn toggle(self: *PokemonState) void {
        self.show_sprite = !self.show_sprite;
        self.manually_toggled = true;
    }

    /// Hide sprite
    pub fn hide(self: *PokemonState) void {
        self.show_sprite = false;
        self.manually_toggled = true;
    }
};

/// Calculate sprite position based on widget config
pub fn calculatePosition(
    config: PokemonConfig,
    pane_x: u16,
    pane_y: u16,
    pane_width: u16,
    pane_height: u16,
    sprite_width: u16,
    sprite_height: u16,
) struct { x: u16, y: u16 } {
    return switch (config.position) {
        .topleft => .{
            .x = pane_x + 1,
            .y = pane_y + 1,
        },
        .topright => .{
            .x = if (pane_width > sprite_width + 2)
                pane_x + pane_width - sprite_width - 2
            else
                pane_x,
            .y = pane_y + 1,
        },
        .bottomleft => .{
            .x = pane_x + 1,
            .y = if (pane_height > sprite_height + 2)
                pane_y + pane_height - sprite_height - 2
            else
                pane_y,
        },
        .bottomright => .{
            .x = if (pane_width > sprite_width + 2)
                pane_x + pane_width - sprite_width - 2
            else
                pane_x,
            .y = if (pane_height > sprite_height + 2)
                pane_y + pane_height - sprite_height - 2
            else
                pane_y,
        },
        .center => .{
            .x = if (pane_width > sprite_width)
                pane_x + (pane_width - sprite_width) / 2
            else
                pane_x,
            .y = if (pane_height > sprite_height)
                pane_y + (pane_height - sprite_height) / 2
            else
                pane_y,
        },
    };
}

/// Estimate visual width of a line (ignoring ANSI escape sequences)
pub fn estimateVisualWidth(line: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    var in_escape = false;

    while (i < line.len) {
        if (line[i] == 0x1b) { // ESC
            in_escape = true;
            i += 1;
        } else if (in_escape) {
            if (line[i] == 'm') {
                in_escape = false;
            }
            i += 1;
        } else {
            // Count visible characters - handle UTF-8 properly
            const char_len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
            if (i + char_len <= line.len) {
                // Valid UTF-8 character
                width += 1;
                i += char_len;
            } else {
                // Invalid UTF-8, skip
                i += 1;
            }
        }
    }

    return width;
}
