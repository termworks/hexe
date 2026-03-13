# Pokemon Sprite Feature

## Overview
Added a feature to display Pokemon sprites overlaid in the center of panes when a keybinding is held.

## What Was Implemented

### 1. **Downloaded Pokemon Sprites** 🎮
- **Source**: [krabby repository](https://github.com/yannjor/krabby)
- **Location**: `/doc/code/hexa/src/sprites/`
  - `regular/` - 1,152 regular Pokemon sprites
  - `shiny/` - 1,152 shiny Pokemon sprites
- **Format**: ANSI-colored text files (terminal-friendly)
- **Coverage**: All generations with variants (Mega, Gigantamax, regional forms)

### 2. **Sprite System**
- Sprite state is managed per pane via `PokemonState`
- Implementation lives in `src/modules/popup/widgets/pokemon.zig`
- Sprites are loaded via embedded sprite assets and rendered as terminal cells

### 3. **Rendering Pipeline**
- Added `drawSpriteOverlay()` to `Renderer` (`src/frontends/terminal/render.zig`)
- Parses ANSI color codes (24-bit RGB)
- Centers sprite in pane viewport
- Renders on top of pane content but below overlays
- Handles SGR (Select Graphic Rendition) escape sequences

### 4. **Keybinding Action**
- Added `sprite_toggle` to `BindAction` enum (`src/core/config.zig`)
- Handler in `src/frontends/terminal/keybinds.zig`
- Works for both split panes and floating panes
- Automatically loads a random Pokemon sprite

### 5. **Pane Integration**
- Added `sprite_state` field to `Pane` struct
- Initialized/cleaned up with pane lifecycle
- Per-pane sprite state (each pane can have its own sprite)

## How to Use

### Add Keybinding to Config

Edit `~/.config/hexe/init.lua` and add to `mux.input.binds`:

```lua
{ on = "press", mods = { hx.mod.ctrl, hx.mod.alt }, key = "p", action = { type = hx.action.sprite_toggle } },
```

Or use any key combination you prefer:

```lua
{ on = "hold", hold_ms = 400, mods = { hx.mod.ctrl, hx.mod.alt }, key = "s", action = { type = hx.action.sprite_toggle } },
```

### Using the Feature

1. **Press the keybinding** (e.g., `Ctrl+Alt+P`)
2. **A random Pokemon sprite appears** in the center of the focused pane
3. **Press again to toggle it off**

### Examples

**Example keybindings you could use:**

```lua
-- Quick toggle
{ on = "press", mods = { hx.mod.ctrl, hx.mod.alt }, key = "p", action = { type = hx.action.sprite_toggle } },

-- Hold to show (release to hide)
{ on = "hold", hold_ms = 400, mods = { hx.mod.ctrl, hx.mod.alt }, key = "s", action = { type = hx.action.sprite_toggle } },

-- Repeat-friendly toggle
{ on = "repeat", mods = { hx.mod.ctrl, hx.mod.alt }, key = "p", action = { type = hx.action.sprite_toggle } },
```

## Available Sprites

- **Total**: 1,152 regular + 1,152 shiny variants
- **Includes**: All Pokemon from Gen 1-9 plus special forms:
  - Mega Evolutions (e.g., `charizard-mega-x`)
  - Gigantamax forms (e.g., `pikachu-gmax`)
  - Regional variants (e.g., `vulpix-alola`, `meowth-galar`)
  - Gender variants (e.g., `nidoran-f`, `nidoran-m`)

Sample sprites available:
```
pikachu, charizard, mewtwo, bulbasaur, squirtle, gengar, dragonite,
lapras, snorlax, eevee, mew, umbreon, espeon, lucario, garchomp,
rayquaza, kyogre, groudon, dialga, palkia, arceus, and many more!
```

## Technical Details

### Sprite Loading
- Sprites are loaded on-demand when toggled
- Cached in pane's `sprite_state` until pane is destroyed
- Random Pokemon name generated using `core.ipc.generatePaneName()`
- Falls back to Pikachu if loading fails

### Rendering
- Sprites are ANSI-colored text with 24-bit RGB
- Parsed and rendered to cell buffer
- Centered in pane using visual width calculation
- Supports Unicode box-drawing characters (▀, ▄)
- Maintains color codes for authentic Pokemon appearance

### Performance
- Sprites are text-based, very lightweight
- No external image libraries required
- Renders at terminal refresh rate
- Minimal memory overhead per pane

## Future Enhancements (Ideas)

- [ ] Specify which Pokemon to show in keybinding config
- [ ] Shiny variant toggle
- [ ] Sprite tied to pane name (e.g., pane named "pikachu" shows Pikachu)
- [ ] Animation support (sprite cycling)
- [ ] Custom sprite directory support
- [ ] Sprite browser/picker overlay

## Files Modified

1. `src/core/config.zig` - Added `sprite_toggle` action
2. `src/frontends/terminal/pane.zig` - Added sprite state to panes
3. `src/modules/popup/widgets/pokemon.zig` - Sprite state and loading
4. `src/frontends/terminal/loop_render.zig` - Integrated sprite overlay rendering
5. `src/frontends/terminal/keybinds_actions.zig` - Sprite toggle action handler
7. `src/sprites/` - Pokemon sprite assets (1,152 × 2)

## Credits

- Pokemon sprites from [krabby](https://github.com/yannjor/krabby)
- Original sprites from [PokéSprite](https://msikma.github.io/pokesprite/)
- Converted to Unicode using [pokemon-generator-scripts](https://gitlab.com/phoneybadger/pokemon-generator-scripts)
- Pokemon data from [PokéAPI](https://github.com/PokeAPI/pokeapi)

---

**Gotta catch 'em all!** 🎮✨
