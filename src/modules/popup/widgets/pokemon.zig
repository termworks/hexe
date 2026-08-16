const std = @import("std");

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

/// Which sprite a pane shows. The artwork itself lives in the painter; hexe
/// only tracks the name and whether it is visible.
pub const PokemonState = struct {
    show_sprite: bool = false,
    sprite_name: ?[]const u8 = null,
    manually_toggled: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PokemonState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PokemonState) void {
        self.* = .{ .allocator = self.allocator };
    }

    pub fn loadSprite(self: *PokemonState, name: []const u8, shiny: bool) !void {
        _ = shiny;
        self.sprite_name = name;
        self.show_sprite = true;
    }

    pub fn toggle(self: *PokemonState) void {
        self.show_sprite = !self.show_sprite;
        self.manually_toggled = true;
    }

    pub fn hide(self: *PokemonState) void {
        self.show_sprite = false;
        self.manually_toggled = true;
    }
};
