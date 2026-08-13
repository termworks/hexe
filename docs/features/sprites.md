# Sprites

Every pane in hexe is named after a pokemon, because a session needs names and pokemon are easier
to say than uuids. This feature takes that one step further: press a key and the pane draws the
pokemon it is named after, in colour, in the middle of your work.

```lua
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.p }, hexe.action.overlay.sprite_toggle()),
```

It is the least serious thing in the codebase and the one with the most interesting build step.

<!-- demo:begin -->
[![sprites demo](https://asciinema.org/a/1262991.svg)](https://asciinema.org/a/1262991)
<!-- demo:end -->

## How it works

The sprites are ANSI art — 24-bit colour escape sequences over Unicode half-block characters
(`▀`, `▄`), one file per pokemon, from [krabby](https://github.com/yannjor/krabby), which took them
from PokéSprite. Regular and shiny, 1152 each.

Shipping 2304 text files with a static binary is not an option, and embedding them raw costs about
9 MB. So they are packed at build time:

```
src/core/sprites/{regular,shiny}/*.txt
        │  sprite-pack (build step)
        ▼
  HXSP archive:  header · index · concatenated per-sprite gzip streams
        │  @embedFile
        ▼
  ~1.6 MB inside the binary
```

Each sprite is its own gzip stream and the index carries its name, kind, raw length and compressed
length. Toggling a sprite scans the index, inflates *that one stream*, and hands back the ANSI text
— so the memory cost of showing a pokemon is one sprite, not an archive.

The compression happens by shelling out to `gzip -9` at build time, because Zig 0.15's standard
library ships a complete flate *decompressor* but not a compressor. The binary inflates in pure
Zig; `gzip` is only needed by whoever builds it.

Drawing is per pane: the renderer parses the SGR sequences into cells, centres the result in the
pane's viewport, and paints it above the pane's content but below the overlays. Each pane keeps its
own sprite state, so a split can show two different pokemon at once, and each pane shows the one it
is named after — the sprite is not random, it is the pane's identity made visible.

There is a 1-in-100 chance of a shiny.

## What makes it different

No other multiplexer draws pokemon in your panes. That is the whole comparison.

What is worth stealing, if you ever ship art in a static binary: the per-item gzip stream with an
index is the difference between 9 MB and 1.6 MB, and between inflating everything and inflating
one. And the naming trick underneath — pokemon names for panes and sessions — is genuinely useful:
`hexe terminal attach nido` is a thing you can type, and `a3f2` is not.

## Configuration

```lua
pop = {
  widgets = {
    pokemon = { enabled = false, position = "topright", shiny_chance = 0.01 },
  },
},
```

| | |
|---|---|
| `enabled` | whether the widget is on without a key being pressed |
| `position` | `topleft`, `topright`, `bottomleft`, `bottomright`, `center` |
| `shiny_chance` | probability of the shiny variant, `0.01` by default |

The action works on the focused pane, tiled or float:

```lua
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.p }, hexe.action.overlay.sprite_toggle()),
```

Sprite coverage is generations 1 through 9 with the variants: mega evolutions
(`charizard-mega-x`), gigantamax forms (`pikachu-gmax`), regional forms (`vulpix-alola`,
`meowth-galar`) and gendered ones (`nidoran-f`, `nidoran-m`).

## Measurements

- **2304 sprites** — 1152 regular, 1152 shiny.
- **~9 MB raw, ~1.6 MB packed**, embedded in the binary.
- **One inflate per toggle**, of one sprite, cached in the pane's state until the pane is destroyed.
- **Shiny chance: 1%.**

## What it cannot do

- **You cannot choose the pokemon.** It is the pane's name; there is no "show me a gengar".
- **No animation**, no sprite picker, no custom sprite directory.
- **It is frontend state.** Detach and the sprite is gone; it is not in the session snapshot.
- **It needs 24-bit colour and half-block glyphs.** A terminal without them draws something, and it
  is not a pokemon.
- **A sprite that fails to load falls back to Pikachu** rather than reporting anything.

## Where it lives

| | |
|---|---|
| `src/tools/sprite_pack.zig` | the build-time packer and the `HXSP` archive layout |
| `src/core/sprites_embedded.zig` | the reader: index scan, single-stream inflate |
| `src/modules/popup/widgets/pokemon.zig` | per-pane sprite state |
| `src/frontends/terminal/render_sprite.zig` | parsing the ANSI art into cells and centring it |
| `src/frontends/terminal/keybinds_actions.zig` | `sprite_toggle`, for tiled panes and floats |
| `src/core/ipc.zig` | `generatePaneName` — where the names come from in the first place |
| `docs/sprite.md` | the original feature note |

Sprites from [krabby](https://github.com/yannjor/krabby), originally
[PokéSprite](https://msikma.github.io/pokesprite/), converted to Unicode by
[pokemon-generator-scripts](https://gitlab.com/phoneybadger/pokemon-generator-scripts), data from
[PokéAPI](https://github.com/PokeAPI/pokeapi).
