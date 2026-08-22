# Pane decoration

Every pane has twelve addressable slots around it: three on each of its four
edges, named `start`, `center` and `end`. A slot names a painter view. hexe
asks the painter what goes there and puts it where the slot says; it never
decides the content itself.

```lua
hexe.status.socket = "/run/user/1000/painter.sock"

hexe.decor.left   = { width = 4, top = "dock.apps", center = "dock.tools", bottom = "dock.sys" }
hexe.decor.right  = { width = 2, center = "dock.notify" }
hexe.decor.top    = { left = "pane.name", center = "pane.title", right = "pane.status" }
hexe.decor.bottom = { left = "pane.mode", right = "pane.clock" }
```

Slots are optional. An edge with no slots set costs nothing and reserves
nothing.

## The two axes behave differently

**Left and right are strips.** They reserve columns, and the pane really loses
them: the pty inside is narrower and the program running there is told so. A
panel is not an overlay, so nothing is ever drawn on top of a program's output.
The three slots split the strip's height into thirds, top to bottom.

Because a strip is a rectangle rather than a line, it is asked for a **surface**
— a block of ANSI the painter draws at the size hexe gives it, blitted into the
strip. Icons stack vertically, and the painter never has to encode a layout in a
single line of text. The bytes land in a terminal sized to the strip, so a
painter cannot address a cell outside its own rectangle whatever it emits.

**Top and bottom are border rows.** They are the float title generalised into
three independently addressed pieces, so they appear where a float's title
appears — on the float's border. A split pane has no border row of its own and
gets no top or bottom slots.

Because a border row is one cell tall, it is asked for **runs** — styled text.
hexe measures what comes back and places it: `start` after the left corner,
`center` centred, `end` before the right corner.

Both spellings of the outer slots are accepted, so a config can say what it
means: on a horizontal edge `start`/`end` may be written `left`/`right`, and on
a vertical edge `top`/`bottom`. `center` may be written `middle`.

## Width is yours to choose, not the painter's

`width` on a side panel is config, not something the painter returns. A
painter-chosen width would resize the pane on every frame the painter changed
its mind, and every full-screen program inside would redraw. Set it once and
the geometry is stable.

A side panel is only reserved when that edge has at least one slot: `width`
alone reserves nothing.

## Buttons

A painter can declare clickable rectangles inside the surface it drew, in
coordinates local to that surface:

```json
{"mode": "surface", "ansi": "...", "width": 4, "height": 9,
 "regions": [{"id": "dock.term", "x": 0, "y": 0, "width": 4, "height": 3,
              "actions": {"left": "hexe mux new"}}]}
```

hexe knows where it put the surface, so it does the translating — the painter
never has to know where on screen it ended up. A click runs the named action
the same way a status-bar region action runs, detached, with the focused pane's
identity in the environment.

Panels sit outside their pane, so a click on one is not a click on any pane's
rectangle; that is why they are resolved before the pane search rather than
through it.

## What the painter is told

Alongside the usual context, each request carries the slot's own identity, so
one view can serve several slots and still know which one it is drawing:

| field | value |
| --- | --- |
| `decor_edge` | `top`, `bottom`, `left`, `right` |
| `decor_slot` | `start`, `center`, `end` |
| `pane_name` | the pane's name, if it has one |

Requests are keyed per pane and per slot, so two panes showing the same view do
not share one cached answer.

## Colours

hexe's own chrome resolves through palette slot 1, including everything drawn
in these slots. See [palette.md](palette.md).
