# Painting

hexe draws no chrome of its own. The status bar, tab strip, float and pane
titles and pane sprites are produced by an external program — a *painter*. hexe collects the state, asks for a named view, and composites what
comes back.

hexe has no opinion about what that program is. It speaks one small protocol
over a Unix socket; anything that can bind a socket and emit JSON qualifies.
The example at the bottom of this page is a painter in twenty lines of Python.

```lua
status = {
  enabled = true,
  view = "status",           -- which view to ask for
  socket = nil,              -- nil = the default path, below
  command = nil,             -- optional: how to start the painter
  refresh_ms = 250,
},
```

## Zones

The bar can be one region or three, addressed independently:

```lua
status = {
  enabled = true,
  zones = {
    left   = { view = "status.left" },
    center = { view = "status.center" },
    right  = { view = "status.right" },
  },
  shrink = { "center", "right", "left" },  -- who gives up width first
},
```

`view` and `zones` are mutually exclusive — `view` keeps meaning one region
spanning the whole bar. Every zone is optional: name only `left` and `right` and
nothing is asked for the middle.

Nothing about the protocol changes. Each zone is an ordinary request for its own
selector, tagged with the zone name so the three never share a cache entry. A
painter needs no new capability — only three selectors instead of one.

Each zone is asked at the **full bar width** and composes freely; hexe places
what comes back. Left sits flush at column 0, right flush against the far edge,
center as near the middle as it can get without overlapping either. When the
three do not fit, zones are dropped in `shrink` order — the last name in the
list is the one kept longest — and a single zone still too wide is clipped
rather than dropped.

That costs a little painter work at narrow widths, in exchange for one round of
requests per frame. The alternative — measure, then re-request with real
budgets — would let a painter prune itself to fit, at the price of a stale
frame; hexe does not do this.

What zones buy over one flat response:

- **No padding arithmetic.** Alignment stops being something the painter fakes
  with spacers it computed from the bar width.
- **Independent pruning.** `shrink` says which cluster loses first, instead of
  the painter guessing blind from a single flat list.
- **Independent staleness.** A zone whose painter goes quiet dims on its own
  while the others stay live. With one region, one silence dimmed the whole bar.

Interaction is unchanged, including the coordinates: a zone reports its
rectangles relative to **its own** left edge, starting at x=0, and hexe offsets
them by where it drew that zone. `hover_region`, `press_region` and
`press_button` go to all three zones as they are — ids belong to the painter, so
a painter that reuses one across zones is describing two things by one name.

A zone answering `ok:false` contributes nothing and takes no width; that is how
a painter opts out of a view it does not implement. If *no* zone answers, the
bar is blank and hexe logs the three selectors it asked for — the config that
introduces zones is the same one that has to point them at names the painter
actually serves.

## Finding the painter

In order:

1. `socket` in the config, if set
2. `$HEXE_PAINTER_SOCKET`
3. `$XDG_RUNTIME_DIR/hexe/painter.sock`
4. `/tmp/hexe-$UID/painter.sock`

If nothing is listening and `command` is set, hexe runs it detached through
`/bin/sh -c` and keeps retrying. It never waits on it, and never restarts it
more than once every five seconds — a command that exits immediately must not
become a fork loop. If `command` is unset, starting the painter is your job:
a service unit, a shell rc line, whatever you like.

## Views

| View | Mode | Drawn as |
|---|---|---|
| `status` | run | the whole bar, including tabs |
| `status.left` / `.center` / `.right` | run | one zone each, when `zones` is set |
| `float.title` | run | float border titles |
| `container.title` | run | pane border titles |
| `overlay.sprite` | surface | per-pane overlay art |

Rename any of them with `view`, `float_title_view`, `container_title_view`,
`sprite_view`, or per zone with `zones.<zone>.view`. The names above are only
defaults — hexe asks for whatever the config says.

Dialogs are deliberately **not** on this list. Confirmations, choosers and
notifications block the UI and take keyboard input, so hexe draws them itself.
A terminal that cannot ask "really quit?" without a helper running is a broken
terminal. A painter that does not implement a view simply returns an error
for it, and hexe draws nothing there.

## Modes

**run** — `[{text, style}, …]`. Measurable, so hexe can place and clip it.

**surface** — raw ANSI. The bytes are fed into a terminal sized to the region's
rectangle, so the painter cannot address a cell outside it no matter what it
emits.

## The protocol

A Unix `SOCK_STREAM` socket. Each message is a four-byte big-endian length
followed by one UTF-8 JSON value, 1 MiB maximum. hexe connects, sends one
request, reads one response, closes. Connections are not reused.

**Request**

```json
{"version":1,"select":["status"],"mode":"run","width":120,"height":1,
 "now_ms":1755271083000,
 "context":{"cwd":"/home/you","home":"/home/you","jobs":0,
            "exit_status":0,"duration_ms":12,
            "values":{"schema":1,"session":"main","tabs":["main"],
                      "active_tab":0,"shell_running":false,
                      "alt_screen":false,"adhoc_float":false,"active":true,
                      "progress_state":"inactive","progress_pct":null}}}
```

Shell state sits at the top of `context`; mux state sits in `context.values`
under `"schema":1`. Ignore anything you do not use.

`progress_state` and `progress_pct` carry the focused pane's OSC `9;4` progress.
The state is one of `inactive`, `in_progress`, `error`, `indeterminate`,
`paused`; `progress_pct` is `0`–`100` or `null`. hexe parses the sequence and
reports it — whether a progress indicator is drawn, and how, is the painter's
call. `contrib/painter.py` renders it on the right.

**Response**

```json
{"version":1,"ok":true,"output":{"mode":"run",
 "runs":[{"text":" 12:34 ","style":"fg:250 bg:237 bold"}],
 "width":7,"next_frame_ms":null,
 "regions":[{"id":"tab.1","x":10,"y":0,"width":6,"height":1,
             "actions":{"left":"tab.select.1"}}]}}
```

For `mode":"surface"`, replace `runs` with `"ansi":"…"`.

Anything malformed, or `"ok":false`, is discarded and the previous frame stays
on screen. A painter cannot blank the bar by crashing mid-thought.

### Styles

A space-separated list: `fg:<color>`, `bg:<color>`, `bold`, `dim`, `italic`,
`underline`. `<color>` is a palette index `0`–`255`, a name (`red`,
`bright_blue`), or `#rrggbb`. There is no `reverse` — swap the two colors.

Unknown tokens are ignored, so a painter may emit extras for other consumers.

### Interaction

`regions` is optional: clickable rectangles in region-local coordinates, each
with an `id` and per-button `actions`. hexe hit-tests them and runs the action
name. `tab.select.<n>` (one-based) switches tabs; any other name is run as a
statusbar action.

Which region is hovered or held comes back on the next request as
`hover_region`, `press_region` and `press_button`, so the painter styles its own
pressed and hovered states. hexe never restyles a painter's output.

### Cadence

`next_frame_ms` in a response asks to be polled sooner than `refresh_ms` — an
animating view returns `75` and gets asked again in 75ms. It can only shorten
the interval, never lengthen it.

## Guarantees

**The render loop never waits on a painter.** Connect, write and read are all
non-blocking and advance one step per event-loop iteration. Slow, wedged or
dead costs a stale frame, never a dropped one.
`scripts/smoke_region_painter.py` asserts this against a painter that accepts
the connection and then answers nothing.

**Last value wins.** A frame stays until a newer one replaces it.

**Failures back off.** Consecutive failures double the retry delay from 500ms to
30s, so a painter that is not running costs one connect attempt every 30 seconds
rather than one per frame.

**Painter output is untrusted.** Run text is stripped of escape sequences and
control characters; every region is clipped to its own rectangle.

## Without a painter

The bar is empty, titles fall back to the raw pane name, and sprites do not
appear. Panes, layout, input, keybindings, dialogs and shell integration are
unaffected — nothing hexe needs to function is painted externally.

## A painter, complete

```python
import json, os, socket, struct, time

sock = os.environ.get("HEXE_PAINTER_SOCKET", "/tmp/painter.sock")
try: os.unlink(sock)
except FileNotFoundError: pass

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock); srv.listen(8)

while True:
    conn, _ = srv.accept()
    hdr = conn.recv(4)
    req = json.loads(conn.recv(struct.unpack(">I", hdr)[0]))
    text = " %s " % time.strftime("%H:%M:%S")
    body = json.dumps({"version": 1, "ok": True, "output": {
        "mode": "run",
        "runs": [{"text": text, "style": "fg:250 bg:237 bold"}],
        "width": len(text), "next_frame_ms": 1000}}).encode()
    conn.sendall(struct.pack(">I", len(body)) + body)
    conn.close()
```

```lua
status = { enabled = true, socket = "/tmp/painter.sock" }
```

That is a working status bar. Grow it from there, in whatever language you like.

`contrib/painter.py` is a fuller one in the same spirit: clock, session, tabs,
knight-rider spinner, battery, truncated cwd, and clickable regions. Run it with
`python3 contrib/painter.py &` and start hexe.

Note what it does with the gaps between segments: it leaves them **unstyled**.
Styling the padding paints one continuous strip across the row; leaving it bare
makes the segments islands on the terminal's own background.

## What hexe still owns

Placement, size, clipping, hit-testing, the frame clock, and all pane and
session state. Shell integration (`hexe shell init`, `shell-event`,
`exit-intent`) stays in hexe: it is how hexe learns each pane's cwd, exit
status, job count and running command — the state it then hands to the painter.
