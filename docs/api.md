# The control socket

Everything hexe knows about its panes, floats, tabs and session has one
definition — the live query API. It used to exist only inside the frontend
process, so any other program had to scrape human-formatted CLI output for facts
hexe held exactly. The control socket hands the same API to anything that can
open a unix socket.

```console
$ hexe api session
{"ok":true,"result":{"connected":true,"name":"work","root":"/home/me/src","active_tab":1,"tab_count":3}}

$ hexe api count '"panes"'
{"ok":true,"result":4}

$ hexe api act '{"type":"split.v"}'
{"ok":true,"result":true}
```

`hexe api` is a thin client; the socket is the interface. Exit status follows
the call, so a script can branch without parsing the body.

## Wire format

One socket per attached session, at `$XDG_RUNTIME_DIR/hexe/<profile>/api@<session>.sock`,
mode `0600`. Frames are a 4-byte big-endian length followed by JSON — the same
framing the painter protocol uses.

```
-> {"call":"panes","arg":{"visible":true}}
<- {"ok":true,"result":[ ... ]}
<- {"ok":false,"error":"no such call: pane_list"}
```

`call` names any function on `hexe.live`. `arg` is optional and may be any JSON
value, not only an object. For a call that takes more than one argument, use
`args` with the positional list — `geometry` and `ratio` take `(selector,
value)`, which a single `arg` cannot express:

```
-> {"call":"geometry","args":["904dd85…",{"x":30,"y":20}]}
-> {"call":"ratio","args":["904dd85…",0.25]}
```

From the shell those are the second and third words:

```console
$ hexe api geometry '"904dd85…"' '{"x":30,"y":20}'
$ hexe api ratio '"904dd85…"' 0.25
```

One request per connection.

## What you can call

Every accessor and verb the Lua API has, because the socket calls those exact
functions and encodes what they return. There is no second list of fields to
drift out of step with the first.

| | |
| --- | --- |
| read | `pane`, `panes`, `floats`, `splits`, `tabs`, `session`, `ui`, `count`, `env`, `config` |
| screen | `line`, `cursor_line`, `screen_text`, `find`, `selection`, `selection_range` |
| act | `act`, `send`, `focus`, `close`, `scroll`, `tab_select`, `rename_tab`, `rename`, `notify` |
| place | `geometry`, `ratio` |

A pane record carries what you would expect to have to ask several commands
for: `uuid`, `name`, geometry, `cwd`, `process`, `alive`, `alt_screen`, cursor
position and shape, `scrolled`, `last_command`, `jobs`, plus float attributes
(`per_cwd`, `sticky`, `visible`, `visible_tabs`, size percentages).

See [keybindings.md](keybindings.md) for the same API as it appears to Lua, and
for what `act` accepts.

## Placing things

`float.nudge` steps a float in a direction and `split.resize` steps a divider by
cells. Neither can say "the user dropped it *here*", so a pointer has to guess
how many steps that is. These two state a destination instead.

`geometry([selector] [, spec])` reads a pane's geometry, and sets it when given
a spec. For a float the spec is percentages — `width`, `height`, `x`, `y`,
`pad_x`, `pad_y` — and any field left out keeps its current value, so dragging
does not reset the size. Values outside 0..100 are clamped, and the returned
record is what actually took effect, not what was asked for:

```console
$ hexe api geometry '"904dd85…"' '{"x":30,"width":60}'
{"ok":true,"result":{"width":60,"height":50,"x":30,"y":20,"pad_x":1,"pad_y":0,
                     "cell_x":36,"cell_y":5,"cell_width":72,"cell_height":17,"float":true}}
```

`cell_*` is where it landed on screen, which is what a UI needs to draw a
handle. A tiled pane has no percentage geometry of its own, so `geometry`
reports its cell rect and the `ratio` of the divider above it instead.

`ratio([selector] [, value])` reads that divider and sets it when given a number
in 0..1, clamped to 0.05..0.95 — a divider at either end leaves a pane with no
width to grab it back by. The selector always comes first and the value only
ever second, so `ratio(2)` selects pane 2 rather than setting a ratio of 2.

`rename(selector, name)` names a pane. Names reach socket paths and CLI
arguments, so the same `[a-z0-9][a-z0-9._-]*` rule the name pool uses applies
here; an invalid name is refused and the old one is kept.

## Events

Instead of polling, keep a connection open and be told:

```
-> {"subscribe":true}                        # everything
-> {"subscribe":["tab_created","pane_exited"]}
<- {"ok":true,"result":"subscribed"}
<- {"event":"tab_created","payload":{"event":"tab_created","now_ms":1787…,"index":2}}
<- {"event":"pane_focus_changed","payload":{ … }}
```

The connection then streams frames until you close it. Events carry the same
payload a Lua `hexe.events.on` handler receives, because the fan-out happens at
the one place every event already passes through — so this list grows with that
one rather than beside it.

Currently emitted: `pane_focus_changed`, `pane_cwd_changed`, `pane_process_changed`,
`pane_shell_running_changed`, `pane_exited`, `command_finished`, `tab_created`,
`tab_changed`, `tab_closed`, `statusbar_redraw`.

A subscriber that stops reading is disconnected once its undelivered backlog
passes 1 MiB. A phone on a bad link must not be able to grow the mux's memory,
and a client that far behind is no longer showing anything current anyway.

## It cannot stall the mux

The frontend loop drives every pane in the session, so a control socket that
waited on a client would freeze every program running under hexe. Accepts,
reads and writes are all non-blocking; a request that has not finished arriving
is left for the next iteration rather than waited on; connections are capped at
8 and dropped after 5 seconds; a client that never reads its reply is dropped
rather than served.

`scripts/smoke_api_socket.py` holds the mux to that: it throws malformed frames,
impossible lengths, clients that vanish mid-request, clients that ask and never
read, and more connections than there are slots, then requires the session to
still answer. Liveness is not enough there — a stalled loop leaves a live
process — so it asserts the mux still *responds*.

## Using it from a web gateway

This is the piece a browser UI was missing. A gateway is now a small program
with no knowledge of hexe's internals:

- **control** — proxy JSON between a WebSocket and this socket. Layout, pane
  list, focus, splits, floats and names all come from calls you can already make
  from the shell.
- **screen content** — not served here, on purpose. A pane's output is a byte
  stream, and it has its own channel: connect to the pane's `pod_socket` as an
  observer and forward what comes back. See [streaming.md](streaming.md).
  `screen_text` and `line` are for reading text, not for driving a display.
- **input** — `send` puts keystrokes into a pane by uuid.

The transport for a remote *terminal* frontend already exists (liblink, an
SSH-like protocol hexe speaks in `hexe syslink`). A browser cannot speak it,
which is why the gateway terminates the browser's WebSocket and talks to hexe
locally.

Two things to know before building on this:

- **Requests are request/response, not a stream.** There is no subscription yet,
  so a gateway polls. For layout changes that is fine at human timescales; for
  pane output it is the wrong shape, which is why output should come from the
  VT stream instead.
- **The socket is full control of the session, authenticated only by file
  permissions.** It is `0600` and belongs on a machine boundary, not a network
  one. A gateway that exposes it to a phone is the thing that must authenticate;
  do not bind hexe's socket to anything routable.
