# Palette namespaces

Every region of a pane can have its own 256-colour table. Cells remember which
table they were drawn under, so repainting one touches those cells and nothing
else — the prompt can change colour while the command output above it does not.

All 256 indices stay available in every namespace. Nothing is reserved, and no
application has to change to benefit.

```lua
palette = {
  namespaces = true,   -- default; false restores pre-namespace behaviour
  osc = 1330,          -- the OSC number applications speak
},
```

`osc` refuses numbers hexe already forwards or consumes — 0–2, 4, 5, 7, 9,
10–19, 50–59, 99, 104, 105, 110–119, 133 and 777. Claiming one would make the
palette dispatch swallow it: `osc = 4` in particular would stop the base
palette reaching your terminal at all.

## What is namespaced, automatically

hexe assigns namespaces from signals it already parses. Nothing opts in:

| Where | Namespace |
|---|---|
| the prompt, and the line you type on it (OSC 133 `A`–`C`) | `prompt` |
| command output (OSC 133 `C`–`D`) | `output` |
| a full-screen app (alt-screen) | `alt` |
| anything else | `default` |

`default` is slot 0 — the pane's ordinary palette. Cells resolved against it are
emitted with their index intact, so your terminal's own theme decides what they
look like, exactly as before namespaces existed.

The zones come from the row, which is why a repaint reaches scrollback as well
as the screen, and survives a resize.

## Setting colours

```
hexe palette list                                   # panes, and what each has set
hexe palette get                                    # every colour, every pane
hexe palette get --ns prompt                        # one namespace
hexe palette get --ns prompt 33                     # one index
hexe palette set --ns prompt 33=#331111 bg=#0a0a0a
hexe palette set --ns prompt --from ~/.cache/wal/colors
hexe palette set --from ~/.cache/wal/colors         # every namespace
hexe palette use --ns nvim                          # select, until `end`
hexe palette end
hexe palette drop --ns nvim                         # release the binding
hexe palette reset --ns prompt                      # forget its colours
hexe palette reset                                  # forget all of them
```

`--ns` takes a name matching `[a-z0-9_.-]{1,32}`, case-insensitive, or `*` for
every live namespace; `--all` is a synonym for `*`, and omitting `--ns`
means the same. Without `--pane`, the change goes to every live pane — which is
what a theme hook wants.

Two kinds of key:

| Key | Affects |
|---|---|
| `0`–`255` | cells that name that palette index |
| `fg`, `bg` | cells that name **no** colour of their own — the zone's default |
| `cursor` | the terminal's cursor, while it is in that zone |

So `set --ns output 1=#ff5555` recolours only what asked for colour 1, while
`set --ns output bg=#101018` tints the whole output zone, blank cells included.

`cursor` colours the terminal's own cursor while it sits in that zone. hexe
cannot paint the cursor as a cell, so it tells the host terminal with `OSC 12`
and restores the terminal's colour when the cursor leaves — or when hexe exits.
That sequence is global to the terminal, so it is sent only when the colour
actually changes, not per frame.

Because it follows the cursor's own row, a `cursor` colour only shows up in
zones your shell actually marks. Without OSC 133 integration every row is
`default`, and `default` is slot 0, which holds no colours.

`set` is a **patch**. An index you never name keeps passing through to your
terminal's theme, so a namespace with one entry set does not blacken the other
255. `reset` is the undo: it forgets a namespace's colours so its cells fall
back to your terminal's theme again. `drop` is *not* undo — it releases the
name binding and leaves the colours where they are.

Colours survive a detach: they are parked in the session daemon, not carried in
the pane's scrollback, so a `clear` or a busy pane cannot lose them.

`hexe palette list` exits non-zero outside a hexe session, which makes it the
capability probe: see `contrib/palette_hook.sh` for a theme hook that uses it
and falls back to an OSC 4 broadcast elsewhere.

## Speaking it from an application

The CLI is a front door onto one sequence, `OSC 1330`, with the verb as the
first parameter. An application can emit it directly:

| Sequence | Meaning |
|---|---|
| `OSC 1330 ; use ; <name> ST` | push `<name>` as current, creating it if new |
| `OSC 1330 ; end ST` | pop; an empty stack is a no-op, not an error |
| `OSC 1330 ; set ; <name> ; <i>=#rrggbb [; …] ST` | patch entries; creates, does not select |
| `OSC 1330 ; drop ; <name> ST` | release the binding, keeping the colours |
| `OSC 1330 ; reset ; <name> ST` | forget the colours, keeping the namespace |
| `OSC 1330 ; ask ST` | capability query |
| `OSC 1330 ; have ; <osc> ; <free> ST` | the only reply hexe sends |

```sh
printf '\033]1330;set;prompt;bg=#331111\033\\'
```

Colours accept `#rrggbb`, `rrggbb`, or the `rgb:rr/gg/bb` form OSC 4 uses. Chunk
a `set` at 32 entries per sequence; they accumulate, so a 256-colour scheme is
simply eight sequences.

**A client may skip the capability query entirely.** Every failure lands on slot
0, which behaves exactly as before:

| Situation | What happens |
|---|---|
| not hexe (kitty, ghostty, alacritty) | the sequence is unrecognised and discarded |
| tmux in between without passthrough | swallowed; same as above |
| the scrollback ring truncated past a `set` | the namespace resolves against slot 0 |
| all 256 slots in use | `use` silently maps to slot 0 |
| the wrong OSC number | unrecognised, discarded |

`SGR 0` does **not** reset the namespace — programs emit `\e[0m` constantly, and
the namespace is sticky state, not an attribute. Entering alt-screen saves the
whole stack and leaving restores it, so an app that dies full-screen cannot leak
its colours into the shell underneath.

Truecolor cells are never namespaced. A cell holding `38;2;r;g;b` has its RGB
baked in; an application that hardcodes hex has already opted out of theming.

## Limits

`use` and `end` currently rebind the namespace of the zone the application's own
rows fall into — the whole grid in alt-screen, the output zone otherwise —
rather than tracking individual cells. Cell-level precision needs the namespace
stored on the interned style inside the VT library, which hexe consumes as a
read-only dependency. For a full-screen application, which is what the verb is
for, the two are the same thing.

`hexe palette get` and `list` read from the session daemon's parked copy, which
the frontend syncs about once a second. A colour set in the last moment before
you ask may not be listed yet, and a pane whose frontend has never run since the
colour was set reports nothing.
