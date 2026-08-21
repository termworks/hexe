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

`call` names any function on `hexe.live`; `arg` is optional and may be any JSON
value, not only an object. One request per connection.

## What you can call

Every accessor and verb the Lua API has, because the socket calls those exact
functions and encodes what they return. There is no second list of fields to
drift out of step with the first.

| | |
| --- | --- |
| read | `pane`, `panes`, `floats`, `splits`, `tabs`, `session`, `ui`, `count`, `env`, `config` |
| screen | `line`, `cursor_line`, `screen_text`, `find`, `selection`, `selection_range` |
| act | `act`, `send`, `focus`, `close`, `scroll`, `tab_select`, `rename_tab`, `notify` |

A pane record carries what you would expect to have to ask several commands
for: `uuid`, `name`, geometry, `cwd`, `process`, `alive`, `alt_screen`, cursor
position and shape, `scrolled`, `last_command`, `jobs`, plus float attributes
(`per_cwd`, `sticky`, `visible`, `visible_tabs`, size percentages).

See [keybindings.md](keybindings.md) for the same API as it appears to Lua, and
for what `act` accepts.

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
- **screen content** — not served here. A pane's output is a byte stream, and
  the natural path is the one the terminal frontend already uses: attach to the
  session and forward each pane's VT bytes to `xterm.js`. `screen_text` and
  `line` are for reading text, not for driving a display.
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
