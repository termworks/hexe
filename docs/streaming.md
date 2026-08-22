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

Three limits, and each exists because of the failure it prevents:

- **Password prompts are not broadcast.** When the pod detects one it stops
  sending output entirely and emits a `password_mode` frame carrying `1`, then
  another carrying `0` when the prompt is gone. Those two are written directly
  rather than through the broadcast path, which is suppressed — otherwise the
  edge that turns it on would be swallowed by the mode it turns on. A recorder
  must stop writing to its file between them.
- **Observers are capped**, at 8 per pod. Past that a connection is refused *before*
  the scrollback replay, not after — otherwise a caller could pay for a full
  history dump per rejected attempt.
- **A slow observer is dropped, never waited for.** Observer fds are
  non-blocking with a bounded write budget. A viewer that stops draining gets
  disconnected rather than stalling the PTY, because everything behind that fd
  is somebody's live shell. Reconnecting replays the backlog, so being dropped
  costs latency, not history.

## Having hexe start it

```lua
hexe.plugin("share", { command = "my-streamer --port 8080" })
```

Started once when the session comes up, through `/bin/sh -c`, detached and with
stdio closed. Its environment carries:

| | |
| --- | --- |
| `HEXE_API_SOCKET` | the control socket, so it never has to guess the path |
| `HEXE_SESSION` | the session it belongs to |

hexe does **not** supervise it. Restarting a helper that exited deliberately is
a fork loop with a delay, and one that wants to survive its own crashes knows
how to better than hexe does. Declare as many as you like; each is started once,
in the order declared.

## Recording, without writing anything

`hexe pod attach` is an observer already, and `--record` writes
[asciicast](recording.md):

```console
$ hexe pod attach --name victor --record /tmp/session.cast
```

Useful on its own, and useful as a reference implementation: it is the same
handshake, the same frames and the same password-mode rule a streaming plugin
needs.
