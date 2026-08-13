# Panes and tabs

A tab is a tree of splits with panes at the leaves, and the frontend's job is to turn keys into
changes to that tree — which it does by asking SES, because the tree is not the frontend's to edit.
What the frontend owns is everything about *looking* at it: which pane is focused, which one is
zoomed, where the divider is drawn, and whether your keystrokes go to one pane or all of them.

```lua
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.h }, hexe.action.split.horizontal()),
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.v }, hexe.action.split.vertical()),
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.left }, hexe.action.focus.move("left")),
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.m }, hexe.action.pane.zoom()),
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.b }, hexe.action.pane.sync_toggle()),
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.t }, hexe.action.tab.new()),
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.dot }, hexe.action.tab.next()),
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.comma }, hexe.action.tab.prev()),
hexe.key({ hexe.key.alt, hexe.key.r }, hexe.action.tab.rename()),
```

<!-- demo:begin -->
[![panes-and-tabs demo](https://asciinema.org/a/1263008.svg)](https://asciinema.org/a/1263008)
<!-- demo:end -->

## How it works

```
tab "code"
└── split horizontal (ratio 0.55)
    ├── pane  src/          ← focused
    └── split vertical
        ├── pane  make build
        └── pane  docs/
```

Splitting takes the focused leaf and replaces it with a split node holding the old pane and a new
one. Closing does the inverse: the surviving sibling takes the parent's place, so a tree never
keeps an empty node. Both are semantic commands to SES — the frontend sends "split here", SES
mutates the graph, spawns the pod, and publishes a new snapshot that the frontend reconciles
against. Nothing about that changes when a second frontend is watching.

### Focus is geometric

`focus.move("left")` is not "previous pane in the tree". The frontend knows the rectangle every
pane occupies, so moving focus left means finding the pane whose rectangle is adjacent in that
direction — which is what your eyes expect and what a tree walk gets wrong the moment a split is
nested inside another.

### Zoom

Zoom is a view state, not a layout change: the focused pane is drawn over the whole tab and the
others are not drawn at all. The tree is untouched, SES is not involved, and the pane is resized —
so a full-screen application inside it repaints at the new size and back again when you unzoom.

### Sync

`pane.sync_toggle()` broadcasts your input to every pane in the tab instead of just the focused
one. It is a frontend-side fan-out — each pane's pod receives the same bytes through its own
channel — and the status of it is announced, because typing into four shells at once without a
reminder is a way to lose an afternoon.

### Pane select

`pane.select()` labels every pane with a letter and waits for one. Pressing it either focuses that
pane or swaps it with the one you were standing in, which is how a pane is moved without dragging
anything.

### Dead panes

A pane's process exits, and the pane goes away — but *how* it goes away depends on where it was.
A focused pane closing is expected; a background float that exits non-zero raises a notification
naming the exit code, because a silent disappearance of something you were not looking at is a bug
report waiting to be filed against the wrong component.

### Tabs

Tabs are a list, not a tree: new, next, previous, close, and rename in place. The tab row lives in
the status bar's centre zone (see [the status bar](statusbar.md)), and the tab title is either the
name you gave it or the basename of the focused pane's directory — a per-segment setting, not a
global one.

## What makes it different

The obvious comparison is tmux, and the differences are small but consistent:

- **No prefix key.** Bindings are ordinary chords evaluated against a `when` callback; there is no
  modal prefix, and a bind that does not match falls through to the pane untouched. See
  [keybindings](keybindings.md).
- **Focus is directional by geometry**, as it is in a tiling window manager, rather than by tree
  order.
- **Zoom does not restructure anything.** In tmux zoom is also a view flag; the difference here is
  that the pane is genuinely resized, so the application inside sees a resize rather than a clipped
  window.
- **Splits are not "windows".** A tab holds a split tree and its own floats; floats are a separate
  concept rather than a pane that happens to be positioned oddly.

## Configuration

Every action above is bound the same way, and each takes its parameter as a string:

| | |
|---|---|
| `hexe.action.split.horizontal()` / `.vertical()` | split the focused pane |
| `hexe.action.split.resize("up"\|"down"\|"left"\|"right")` | move the divider |
| `hexe.action.focus.move("up"\|"down"\|"left"\|"right")` | move focus geometrically |
| `hexe.action.pane.close()` | close the focused float or split pane — never the tab |
| `hexe.action.pane.zoom()` | maximise the focused tiled pane |
| `hexe.action.pane.select()` | label panes and pick one |
| `hexe.action.pane.sync_toggle()` | broadcast input to every pane in the tab |
| `hexe.action.pane.disown()` / `.adopt()` | move a pane between sessions ([sessions](sessions.md)) |
| `hexe.action.tab.new()` / `.next()` / `.prev()` / `.close()` / `.rename()` | tabs |
| `hexe.action.layout.save()` / `.load()` | store and restore the current arrangement |

The initial arrangement is a layout, and layouts nest:

```lua
hexe.tab("code", {
  root = hexe.split("horizontal", {
    hexe.pane({ cwd = "src" }),
    hexe.split("vertical", {
      hexe.pane({ command = "make build" }),
      hexe.pane({ cwd = "docs" }),
    }),
  }, { ratio = 0.55 }),
})
```

Dividers are theme, not layout:

```lua
mux = {
  splits = {
    color = { active = 5, passive = 237 },
    chars = { vertical = "│", horizontal = "─" },
  },
},
```

A bind can be made conditional on what is focused, which is how the same key can split when a tiled
pane is focused and do nothing inside a float:

```lua
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.h }, hexe.action.split.horizontal(), {
  when = function(ctx) local p = ctx.pane(0); return p and p.focus_split end,
}),
```

## What it cannot do

- **A pane cannot be moved between tabs.** Select-and-swap works within a tab; crossing tabs means
  disowning the pane and adopting it on the other side.
- **Ratios are set at creation and by resize keys.** There is no "even out this tree" command and
  no layout presets like tmux's `select-layout`.
- **Zoom is per tab and forgotten on detach.** It is view state, and view state is not in the
  session snapshot.
- **Sync is per tab and never crosses floats.** It broadcasts to the tab's tiled panes.
- **There is no pane numbering.** Panes are addressed by uuid, by name, or by pointing at them with
  select mode; there is no `%3` to type.
- **Closing the last pane in a tab closes the tab**, and closing the last tab ends the session.

## Where it lives

| | |
|---|---|
| `src/frontends/terminal/layout.zig` | turning the split tree into rectangles |
| `src/frontends/terminal/focus_move.zig`, `focus_nav.zig`, `directions.zig` | geometric focus |
| `src/frontends/terminal/state_tabs.zig`, `tab_switch.zig` | the tab list and switching |
| `src/frontends/terminal/pane.zig` | a pane's view object: VT, selection, notifications, sprites |
| `src/frontends/terminal/dead_panes.zig` | what happens when a pane's process exits |
| `src/frontends/terminal/borders.zig` | dividers and their characters |
| `src/modules/popup/overlay/pane_select.zig` | the letter labels for select mode |
| `src/modules/session/layout_apply.zig`, `layout_template.zig` | applying a layout to a session |
| `src/modules/session/pane_creation.zig`, `pane_lifecycle.zig` | SES's side of split, close, adopt |
