// Widget modules
pub const digits = @import("digits.zig");
pub const pokemon = @import("pokemon.zig");

// Re-export main types
pub const PokemonState = pokemon.PokemonState;
pub const PokemonConfig = pokemon.PokemonConfig;
pub const DigitsConfig = digits.DigitsConfig;
pub const Position = pokemon.Position;

/// Widgets configuration
pub const WidgetsConfig = struct {
    pokemon: pokemon.PokemonConfig = .{},
    digits: digits.DigitsConfig = .{},
};
