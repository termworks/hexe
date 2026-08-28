# Streaming a pane

A pane's bytes are readable by any program you point at it. That is what a
recorder, a session-sharing gateway or a browser viewer is made of, and it needs
nothing from hexe beyond a socket.

```
your program ──► hexe api           control: what panes exist, and what changed
             └─► pod-<uuid>.sock    bytes:   scrollback, then the live stream
             └─► anything you like  HTTP, a WebSocket, a .cast file
```

The two channels are deliberately separate. The control socket
([api.md](api.md)) answers questions and performs actions; the pod socket
carries **bytes and nothing else**. If you find yourself wanting "split this
pane" on the pod socket, it belongs on the control socket — a second session
protocol growing here is the thing that would make this unpickable later.

## Finding a pane

`hexe api panes` lists them, and every pane carries `pod_socket`:

```console
$ hexe api panes
{"ok":true,"result":[{"uuid":"2c88beab…","name":"victor",
                      "pod_socket":"/run/user/1000/hexe/pod-2c88beab….sock", …}]}
```

Reported rather than left to be derived: building that path yourself means
knowing hexe's runtime layout, which is not something a plugin should have to
know. Subscribe for `pane_exited` and the rest to follow the session as it
changes rather than polling.

## Reading it

Connect to `pod_socket` and send a two-byte handshake — the channel, then the
protocol version:

| channel | byte | direction |
| --- | --- | --- |
| observer | `0x04` | pod → you |
| input | `0x03` | you → pod |

`PROTOCOL_VERSION` is `4` (`src/core/wire.zig`). A mismatched version is
refused rather than half-understood.

What comes back is **framed, not raw VT**:

```
┌────────┬──────────────┬──────────────┐
│ type   │ length       │ payload      │
│ u8     │ u32 big-end. │ length bytes │
└────────┴──────────────┴──────────────┘
```

| type | | |
| --- | --- | --- |
| `1` | `output` | what the program wrote. This is the one a viewer draws. |
| `2` | `input` | what was typed, when the pod is capturing it |
| `3` | `resize` | the pane's new size |
| `4` | `backlog_end` | the replay is over; everything after this is live |
| `5` | `password_mode` | one byte: `1` broadcasting has stopped, `0` it has resumed |
| `6` | `refused` | one byte: `1` blocked, `2` at capacity. Sent just before the pod hangs up. |

An observer receives the **scrollback first**, then `backlog_end`, then the live
stream. A viewer that wants only current output can discard everything before
`backlog_end`; one that wants the pane as it looks now should feed the whole
thing to its terminal emulator, which is what the replay is for.

```python
sock.sendall(bytes([0x04, 4]))          # observer, protocol 4
buf = bytearray()
while True:
    buf.extend(sock.recv(65536))
    while len(buf) >= 5:
        ftype, ln = buf[0], int.from_bytes(buf[1:5], "big")
        if len(buf) < 5 + ln:
            break
        payload, buf = bytes(buf[5:5 + ln]), buf[5 + ln:]
        if ftype == 1:
            screen.feed(payload)        # e.g. straight into xterm.js
```

## Writing back

Input goes on its own connection, handshake `0x03`, same framing. `hexe pod
attach` opens a **short-lived** input connection per burst rather than holding
one open, and a viewer that only watches never opens one at all — which is what
makes read-only sharing the default rather than a mode you have to ask for.

## What the pod will not send you

Four limits, and each exists because of the failure it prevents:

- **A blocked pane refuses you outright.** Someone said "stop sharing" (see
  below) and the pane stays shut until they say otherwise. Reconnecting does not
  get you back in; that is the whole point of it. You get a `refused` frame
  saying which it was first: without it every refusal looks like a pod that
  died, and a client that reconnects on loss — which it should — turns "stop
  sharing" into a reconnect loop that quietly defeats it. `blocked` means stop;
  `at_capacity` means waiting might help.
- **Password prompts are not broadcast.** The pod detects one the only way a
  terminal can — the child put its tty into canonical mode with echo off — and
  then sends observers nothing at all: `broadcastToObservers` drops **output and
  input alike** while it is on, and the backlog stops recording. It emits a
  `password_mode` frame carrying `1`, and `0` when the prompt is gone; those two
  are written directly rather than through the broadcast path, which is
  suppressed, otherwise the edge that turns it on would be swallowed by the mode
  it turns on.

  **If you keep your own scrollback, clear it on `1` — do not merely stop
  appending.** Detection cannot precede the prompt: the bytes that drew
  `Password:` were broadcast before the tty flags changed, so they are already
  in your buffer. The pod handles this by wiping its own backlog on entry
  (`applyPasswordMode` calls `backlog.clear()`), and a downstream ring that does
  not do the same becomes the leak the pod just prevented — replaying the prompt
  to whoever joins next.

  What no one can close is the window itself: bytes emitted before the child
  flipped the tty are already gone. That is inherent, not a bug to fix.
- **Observers are capped**, at 8 per pod. Past that a connection is refused *before*
  the scrollback replay, not after — otherwise a caller could pay for a full
  history dump per rejected attempt.
- **A slow observer is dropped, never waited for.** Observer fds are
  non-blocking with a bounded write budget. A viewer that stops draining gets
  disconnected rather than stalling the PTY, because everything behind that fd
  is somebody's live shell. Reconnecting replays the backlog, so being dropped
  costs latency, not history.

## Letting hexe push it to you

Everything above has your program reading hexe's own protocol. That is right for
a recorder that wants exact bytes, and wrong for anything general: it means the
program knows what hexe is.

The other direction inverts that. hexe pushes the pane to a plugin as
**[asciicast v2](https://docs.asciinema.org/manual/asciicast/v2/)** — the format
`asciinema play` reads and a `.cast` file contains — so the plugin is an ordinary
cast consumer that happens to be fed by a pipe:

```lua
hexe.plugin("drop", { command = "drop cast", access = { "stream", "popup" } })
```

```console
$ hexe api stream '"drop"'          # hand it the focused pane
$ hexe api stream '"drop"' false    # stop
```

Its **stdin** gets a header line, then the pane as it looks now, then
`[t, "o", data]` events. If it also holds `typing`, whatever it writes on
**stdout** as `[t, "i", data]` is typed into the pane.

**View-only versus read-write is the access it declared**, not a flag on the
request: `stream` watches, `stream` + `typing` can also type. Two grants, not
two modes — handing someone your keyboard is a different decision from showing
them your screen, so it is a different word in your config.

hexe does not know what happens next. Publishing, a QR code, a link, another
hexe on the far end — none of that is hexe's vocabulary. A plugin that wants to
show the user a link has `popup` access and says so itself.

Password mode arrives as an asciicast marker:

```json
[1.5, "m", "password-on"]
[4.2, "m", "password-off"]
```

**A plugin keeping its own scrollback must clear it on `password-on`, not merely
stop appending** — the bytes that drew the prompt went out before the terminal's
echo flag changed, so they are already in its buffer. hexe wipes its own backlog
for that exact reason. A plugin that ignores markers is no worse off than one
that never saw them; it just cannot offer that protection.

`contrib/share-echo.py` is a working plugin in ~40 lines.

## Having hexe start it

```lua
hexe.plugin("share", { command = "my-streamer --port 8080", access = { "stream", "popup" } })
```

Started once when the session comes up, through `/bin/sh -c`, detached and with
stdio closed. `access` is what it may ask hexe to do — without `stream` it is
not even shown `pod_socket`. See [access.md](access.md). Its environment carries:

| | |
| --- | --- |
| `HEXE_API_SOCKET` | its own scoped control socket, so it never has to guess the path |
| `HEXE_ACCESS` | what it holds, e.g. `read,stream,popup` |
| `HEXE_SESSION` | the session it belongs to |

hexe does **not** supervise it. Restarting a helper that exited deliberately is
a fork loop with a delay, and one that wants to survive its own crashes knows
how to better than hexe does. Declare as many as you like; each is started once,
in the order declared.

## Knowing you are shared

A pane being watched is a privacy state, so hexe reports it rather than leaving
it to the program doing the watching. The pod owns the observer sockets and is
the only process that can see them; it pushes the count up through SES, and from
there it is readable everywhere something might want to draw it:

```console
$ hexe api panes
{"uuid":"2c88beab…","observers":2,"shared":true,"share_blocked":false, …}
```

| where | what you get |
| --- | --- |
| the pane record | `observers`, `shared`, `share_blocked` |
| the `pane_observers_changed` event | fires on connect and disconnect, so a painter repaints instead of polling |
| a decor slot's context | the same three, plus `pane_uuid` |
| `hexe pod share` | the same answer with no frontend in the path |

### The pane keeps rendering

Deliberately. You are typing into something other people are reading, and the
way that goes wrong is showing them too much — which you cannot catch if hexe
has blanked the pane to tell you it is shared. Blanking would also save nothing:
the pod broadcasts to the frontend and to observers independently.

So the content stays and the frame changes. `contrib/painter.py` ships a `share`
view that draws `● LIVE 2` on the pane's border and nothing at all when nobody
is watching — an indicator that is always there is one nobody reads:

```lua
hexe.status.exec = "pixy serve --stdio"
hexe.decor.top = { right = "share" }
```

(`right` rather than `end` because `end` is a Lua keyword and cannot be written
as a key; both spellings mean the same slot.)

The one thing hexe does hide is the opposite direction: during a password prompt
the pod stops broadcasting entirely, so viewers see nothing while you still do.

### Stopping

```console
$ hexe pod share -u 2c88beab… --off      # drop everyone, refuse new ones
$ hexe pod share -u 2c88beab… --on       # allow again
$ hexe api share '"2c88beab…"' false     # the same, from Lua or a keybind
```

Two properties this depends on, both load-bearing:

- **It goes to the pod, not to the streamer.** A kill switch routed through the
  process it is killing stops working exactly when you need it — when that
  process is wedged. `hexe pod share` needs no frontend either, so a detached
  session can still be cut.
- **Blocking outlasts the drop.** Disconnecting observers alone loses the race
  against a reconnect: whatever opened them opens them again while you are
  reading the notification, and "stop sharing" silently did not. The pane stays
  closed until someone says `--on`.

The `share` view in the reference painter wires the click through, so the badge
is also the button: left-click stops, right-click resumes.

## Recording, without writing anything

`hexe pod attach` is an observer already, and `--record` writes
[asciicast](recording.md):

```console
$ hexe pod attach --name victor --record /tmp/session.cast
```

Useful on its own, and useful as a reference implementation: it is the same
handshake, the same frames and the same password-mode rule a streaming plugin
needs.

## The whole thing, put together

A streamer, a badge that says it is on, a button that stops it, and a QR code to
join from a phone — the pieces above, assembled:

```lua
hexe.status.exec = "pixy serve --stdio"
hexe.decor.top = { right = "share" }              -- ● LIVE, click to stop
hexe.plugin("drop", { command = "drop cast", access = { "stream", "popup" } })
```

Press a key, `hexe api stream '"drop"'` hands it the pane as asciicast, and the
plugin does the rest — it publishes, gets back whatever address it publishes to,
and shows it through its own `popup` access. hexe never learns what the address
is. To show a join link the plugin runs

```sh
hexe mux float -c "qrencode -t UTF8 http://$(hostname):8080/; read" --title "scan to join"
```

which is a transient float — a QR code is cells like anything else. Everything
after that is the streamer's own business: hexe's side is the bytes, the count,
and the switch.

Four things hexe guarantees it, so it does not have to arrange them itself:
the stream keeps flowing while you work, the badge is true because it comes from
the pod rather than from the plugin, the stop works even if the plugin is
wedged, and a password prompt is never broadcast — and is announced as a marker
so the plugin can scrub what it already had.

What hexe deliberately does not know: what the stream is for. A recorder, a web
gateway, another hexe on the far end — same pane, same bytes, same format, and
no hexe-specific flag on either side.
