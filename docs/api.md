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
<- {"ok":true,"n":1,"result":[ ... ]}
<- {"ok":false,"error":"no such call: pane_list"}
```

**`result` is a list of return values and `n` says how many** — the same shape
oslo's server answers with. One convention across the family means one client
library reads either tool. hexe used to answer with the value itself, and a
sibling's client, which unpacks, silently lost every record, string and number
it was handed: `session()` came back empty rather than wrong, which is the worst
way for a protocol to disagree.

Every hexe verb returns exactly one value, so `n` is always 1 today. `hexe api`
is a client like any other and unwraps, so what it prints is unchanged:

```console
$ hexe api count '"panes"'
{"ok":true,"result":1}            # the CLI unwraps
                                  # the wire carried {"ok":true,"n":1,"result":[1]}
```

**A connection serves more than one request.** It used to close after replying,
which made a client that holds one connection — oslo's does — fail its second
call with a broken pipe. Connections are still capped at 8 and a quiet one is
reaped after five seconds, so a client that wants one-shot just closes.

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

## What you can call

Every accessor and verb the Lua API has, because the socket calls those exact
functions and encodes what they return. There is no second list of fields to
drift out of step with the first.

The rows are the [access kinds](access.md), so this table is also what each
plugin declaration buys. The dispatcher reads the same pairing off one
`ENTRIES` list in `lua_api.zig` — that list is authoritative and this is a copy
of it.

| access | verbs |
| --- | --- |
| `read` | `pane`, `panes`, `floats`, `splits`, `tabs`, `session`, `ui`, `count`, `config`, `capture`, `client`, `verbs` |
| `screen` | `env`, `line`, `cursor_line`, `screen_text`, `find`, `selection`, `selection_range` |
| `typing` | `send` |
| `keyboard` | `keys` |
| `popup` | `notify`, `popup` |
| `stream` | `stream` |
| `control` | `act`, `focus`, `close`, `scroll`, `tab_select`, `rename_tab`, `rename`, `share`, `geometry`, `ratio` |

`control` is the default: a verb that changes the session's shape needs the
whole session, and there is no smaller honest name for that.

**`verbs()` answers this table for the door you asked on**, so a peer need not
have read this page — and, on a plugin's or a pane's socket, lists only what
that door may actually call:

```console
$ hexe api verbs
{"ok":true,"result":[{"name":"verbs","about":"this list","access":"read"}, ...]}
```

Listing a verb the gate would refuse is worse than listing nothing, because a
client believes it and acts on it. What is missing stays discoverable — a
refusal names the access it wanted — it is simply not promised. `name` and
`about` are the family's shape; `access` is hexe's own, added rather than
substituted so a sibling's client reads it unchanged.

The four newer ones are each a general power rather than a named feature:

```console
$ hexe api capture true              # something is recording this pane
$ hexe api popup '"scan this"'       # show a block until dismissed; popup() clears
$ hexe api stream '"drop"'           # hand the focused pane's bytes to that plugin
$ hexe api client                    # the client library, as source
```

`capture` draws three bars and hexe never learns whether it is a microphone, a
camera or the screen. A claim lapses after a few seconds unless renewed, so a
plugin that dies mid-capture cannot leave the light on — and any plugin may
claim it, because *claiming* to be recording is harmless and the harm runs the
other way.

`popup` does not interpret its text. A link is a string; a QR code is a grid of
block characters the caller already rendered. The moment hexe knows what a QR
is, it owns a QR library and a set of opinions about them.

`stream` says who gets the bytes, not what they are for — publishing them,
recording them, feeding another hexe are all the plugin's business. Whether the
far end may *type back* is that plugin's `typing` access rather than an argument
here: view-only and read-write are different grants, not different calls.

`client` is the library's own source, so a sibling that can already frame a
request fetches the right vocabulary using the wrong one — rather than shelling
out to `hexe lua-api`, which a sandboxed host cannot do.

`keys(chord [, phase])` presses a chord **at hexe** — `"ctrl+alt+d"`,
`"super+left"`, `"space"` — so it fires whatever you bound rather than reaching
the program in the pane. It returns whether a binding consumed it.

`phase` is `press` (the default), `release`, `repeat` or `hold`. Both halves
matter: a chord bound on press *and* release is the push-to-talk shape, and a
bridge that can only press can never let go of it.

```console
$ hexe api keys '"ctrl+alt+d"'               # hold it down
$ hexe api keys '"ctrl+alt+d"' '"release"'   # let go
```

That is the opposite of `send`, which writes bytes into the pane and which hexe
never interprets; see [access.md](access.md) for why they are separate powers.

A pane record carries what you would expect to have to ask several commands
for: `uuid`, `name`, geometry, `cwd`, `process`, `alive`, `alt_screen`, cursor
position and shape, `scrolled`, `last_command`, `jobs`, plus float attributes
(`per_cwd`, `sticky`, `visible`, `visible_tabs`, size percentages), and who is
watching it (`observers`, `shared`, `share_blocked`).

`share([selector] [, enable])` reads whether a pane is being watched, and cuts
it off when given `false`:

```console
$ hexe api share '"904dd85…"'          -> {"observers":2,"shared":true,"blocked":false}
$ hexe api share '"904dd85…"' false    -> {"observers":0,"shared":false,"blocked":true}
```

It talks to the pod rather than to whatever opened those observers, so it still
works when that program is hung — which is the situation a stop button is for.
See [streaming.md](streaming.md).

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

`close([selector] [, {kill=false}])` closes a pane — and a **float** goes through
the same path a keybinding uses, so closing one from the socket does what
closing it by hand does. That matters for a float a CLI is waiting on
(`hexe terminal float`): it is destroyed *and its caller is answered*, rather
than left hanging for ever. `kill = false` respects what the float declared —
a sticky one hides, a transient one is still destroyed, because leaving it
alive strands the process waiting on it.

`rename(selector, name)` names a pane. Names reach socket paths and CLI
arguments, so the same `[a-z0-9][a-z0-9._-]*` rule the name pool uses applies
here; an invalid name is refused and the old one is kept.

## Calling it from another Lua

hexe ships a plain-Lua client library, and there are three ways to get it. None
of them has to be a file you maintain:

**With a sibling's client.** Both tools now frame and reply the same way, so
oslo's own stub connects to a hexe socket unmodified — it scans for either
tool's sockets and reads either tool's replies. Nothing to fetch:

```lua
local client = load(oslo.live.client())(oslo.stream)
local mux    = client.connect("work")        -- a hexe session
print(#mux.panes())
```

**In code, over the wire.** For hexe's own vocabulary, the `client` verb returns
the source — a peer that can already frame a request fetches the library by
asking for it:

```lua
local lib = load(mux.client())(oslo.stream)  -- stream: what plain Lua cannot do
```

**As a file, if you want one.** `hexe lua-api` prints it; the redirect is yours
to write and hexe does not offer to place it for you:

```sh
hexe lua-api > ~/.config/oslo/hexe.lua
```

Either way the use is the same:

```lua
local mux = lib.connect()
for _, pane in ipairs(mux.panes()) do print(pane.name, pane.cwd) end
```

Discovery needs to list a directory, which plain Lua cannot and which
`io.popen` does only where a host permits it — hexe's safe mode removes `io`
entirely. So hexe lends `hexe.fs.ls`, and a client library asks whichever
sibling it is running inside before falling back to shelling out.

The library is copied between siblings rather than ported — it is oslo's
`client.lua` with hexe's vocabulary — so a fix to the framing reaches both.
Inside hexe itself it is `require("hexe.client")`; plain `require("hexe")` there
is the *config* module, which is a different thing with the same name.

`connect()` takes nothing (`$HEXE_API_SOCKET`, else the newest socket), a
session name, or `{ path = "…", timeout_ms = 5000 }`. `connect_pane()` takes
nothing at all and opens the socket of the pane the caller is running in — see
[A pane's own socket](#a-panes-own-socket).

### One question, nothing held

`connect()` is a channel with a lifetime: it can drop, it can subscribe, you
close it. When all you want is an answer, `fetch` skips the handle entirely:

```lua
local panes = hexe.fetch("work", "panes")          -- a socket, asked and released
local hosts = hexe.fetch({ tool = "wing" }, "machines")   -- a tool with no daemon
```

`fetch(where, verb, ...)` is `Session:call` without the session. It tries a
socket first, and failing that the tool's own one-shot mode — request in argv,
the same `{"ok":…,"n":…,"result":[…]}` on stdout — found through a descriptor
the tool leaves beside the sockets:

```
$XDG_RUNTIME_DIR/<tool>/<tool>.tool
{"exec": "/absolute/path/to/tool", "args": ["api"], "stateless": true}
```

**The verb says what the caller wanted, not what the tool is.** A tool that
later grows a daemon breaks no call site, and `fetch` uses its socket once one
exists. The spawn half needs a *synchronous* runner from the host, and **hexe
lends none on purpose** — a spawn inside the frontend loop suspends every pane
in the session — so from inside hexe `fetch` works over sockets and says so
plainly otherwise. Elsewhere it does both.

Which half a tool can serve is decided by where its state lives: on disk, and a
fresh process answers the same as a live one; *in the process*, and spawning
gets you something that knows about none of it. hexe is the second kind, which
is why it has a daemon and never writes a descriptor.

**A name is matched against what a session calls itself, not only against the
file.** The socket is named when it binds, so a session renamed or reattached
afterwards keeps the old file: `api@pi.sock` can be session `upsilon`. Passing
`"upsilon"` scans and asks each candidate its own name. `session()` reports its
`socket` for the same reason.

Connecting to your **own** session from inside its event loop is refused: the
frontend cannot answer while it is busy running the caller, so it would hang
until the socket timed out. In there, `ctx.*` already reaches everything.

## A pane's own socket

The session's socket is full control of the session, authenticated only by file
permissions. Handing that to whatever runs inside a pane would give a shell
script the whole mux — so a program in a pane had nothing it could safely be
given, and scraped its own terminal instead.

Every pane on screen gets its own socket, and the pane's shell is told where:

```console
$ echo $HEXE_PANE_API_SOCKET
/run/user/1000/hexe/bcf1011708/pane@904dd85….sock
```

```lua
local me = hexe.connect_pane()
print(me.pane().cwd)              -- this pane, whatever has focus
me.send("make test\n")            -- into this pane
me.panes()                        -- refused: that is about the session
```

**The narrowing belongs to the listener, not the caller.** hexe decides it when
it binds the socket, so a client cannot ask for more — the same reason a plugin
gets its own socket rather than a token on the shared one. Three consequences
worth knowing:

- A **selector naming another pane resolves to nothing**, rather than quietly to
  your own pane. Silently retargeting a `send` would put keystrokes somewhere
  the caller did not ask for.
- **"Current" means you.** With another pane focused, a no-selector call still
  answers for the socket's own pane; it can see no other, so the session's focus
  is not its business.
- A session-wide verb is **refused by name** — `panes`, `tabs`, `session`, `ui`,
  `floats` — instead of returning one pane's worth of a session-wide answer,
  which would read as hexe having lost the other panes.

It carries `read`, `screen` and `typing`, on that pane only. That grants nothing
to whoever is already running there — it *is* the process in that pane and can
read its own screen and type into itself by definition. What it adds is asking
hexe precisely rather than guessing; what it withholds is everything else.

The path is named from the pane uuid with no session in it, because a pane
outlives the name of the session showing it and a shell that read the variable
at spawn must not end up holding a stale path after a rename. The **frontend**
binds it, so while nothing is attached nothing is listening — that is the truth
about a live API rather than a fault worth hiding.

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
- **Plugins get a narrower socket.** The session's own socket is full control;
  a plugin declares what it needs and is handed a socket carrying only that.
  See [access.md](access.md).
- **The socket is full control of the session, authenticated only by file
  permissions.** It is `0600` and belongs on a machine boundary, not a network
  one. A gateway that exposes it to a phone is the thing that must authenticate;
  do not bind hexe's socket to anything routable.
