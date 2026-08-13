# Four processes

Hexe is not one program that draws terminals. It is four layers with one rule between them: **the
layer that owns a thing is the only layer allowed to change it.** The frontend owns pixels, SES
owns the session, a pod owns a PTY. Everything else in this documentation is a consequence of that
split.

```sh
hexe terminal new       # the frontend you look at (aliases: hexe mux, hexe multiplexer)
hexe ses list           # the authority it talks to
hexe pod list           # the daemons holding the actual shells
```

<!-- demo:begin -->
[![architecture demo](https://asciinema.org/a/1262976.svg)](https://asciinema.org/a/1262976)
<!-- demo:end -->

## How it works

```
┌────────────────────────┐   what it owns
│ terminal frontend      │   rendering · input · keybindings · popups · status bar
│ hexe terminal          │   float widgets · selection · VT parsing and screens
└───────────┬────────────┘
            │  semantic commands ("split this", "focus left")
            │  ← authoritative session snapshots + VT stream
┌───────────┴────────────┐
│ shared frontend runtime│   attach lifecycle · transport · session projection
│ (in-process)           │   command API · backlog coordination
└───────────┬────────────┘
            │  unix socket (or a liblink tunnel to a remote SES)
┌───────────┴────────────┐
│ SES                    │   the session graph · names and uuids · focus
│ hexe ses daemon        │   detach/reattach · pane ownership · VT routing
└─────┬────────────┬─────┘
      │            │  one connection pair per pane
┌─────┴─────┐ ┌────┴──────┐
│ POD       │ │ POD       │  the PTY fd · the shell process · the backlog ring
│ pod daemon│ │ pod daemon│  cwd / foreground process / title metadata
└─────┬─────┘ └────┬──────┘
    shell        shell
```

Read it as a chain of things each layer is *not* allowed to know. The frontend does not know how a
pane's shell is started. SES does not know what the bytes flowing through it mean — it never parses
VT. A pod does not know it is in a session; it holds one PTY, buffers what comes out of it, and
answers whoever connects.

### The path of a keystroke

```
key ─> frontend keybinds ─> (no bind matches) ─> runtime VT channel ─> SES ─> POD ─> PTY ─> shell
```

and back:

```
shell ─> PTY ─> POD ─┬─> backlog ring (always, first)
                     └─> SES ─> runtime ─> frontend VT widget ─> screen
```

The backlog append happens **before** the uplink write, and that ordering is the whole detach
story: if SES is slow, wedged or gone, the pod drops the connection after a bounded stall and keeps
running, and the missing bytes are still in the ring for whoever attaches next.

### Why a keystroke is not sent twice

A frontend that reconnects its VT channel may resend frames it is not sure landed. Each input frame
carries a 16-byte `(epoch, seq)` prefix — `epoch` identifies a frontend process, `seq` is monotonic
within it — and the pod is the dedup authority, because the pod is the only process that survives
every reconnect trigger: a slow frontend, a dropped VT channel, a SES crash. A frame whose `seq`
has already been applied is dropped rather than typed into your shell twice.

### Mutating the session

The frontend never sends the session. It sends what it wants:

```
user presses split
    ↓
frontend action           "split horizontal, here"
    ↓
runtime command helper
    ↓
SES                       mutates the canonical graph, assigns uuids, spawns a pod
    ↓
SES publishes session_state
    ↓
runtime rebuilds the projection
    ↓
frontend reconciles its widgets against it
```

The frontend's copy is a *projection*: derived, replaceable, and never authoritative. This is why a
frontend can be killed at any instant without corrupting anything, and why two frontends attached
to one session cannot drift apart.

### Remote is a transport, not a second architecture

```
frontend ─> same runtime ─> liblink transport ─> `hexe session pipe` ─> remote SES ─> remote PODs
```

The same CTL/VT protocol is tunnelled to a remote SES through an internal bridge command. Nothing
above or below the transport layer changes, which is the point: a future web or desktop frontend
reuses the same runtime contract rather than reimplementing session semantics.

## What makes it different

tmux is the useful comparison because it made the opposite choice deliberately. In tmux the server
owns the terminal emulation: it parses VT for every pane, keeps the screen, and clients render what
the server tells them. That is a fine design, and it means the server is on the hot path of every
byte a shell writes and must understand all of it.

In hexe the daemon that owns the session **never parses VT at all**. SES routes opaque frames; the
VT lives in the frontend (Ghostty's implementation) and the raw bytes live in the pod. The costs
land differently:

- A pane's terminal state can be rebuilt from bytes on reattach, so scrollback survives with it.
- Emulation bugs are frontend bugs, not daemon bugs; a wedged VT cannot wedge other sessions.
- The daemon's per-pane memory is a ring buffer, not a screen plus history.
- But the daemon cannot answer questions about screen *content* — `capture-pane` has no equivalent,
  because SES genuinely does not know what is on any screen.

## Configuration

There is nothing to configure about the architecture, but two environment variables decide which
stack a command talks to:

| | |
|---|---|
| `HEXE_INSTANCE` | which stack: sockets live under `$XDG_RUNTIME_DIR/hexe/<instance>/`. See [instances](instances.md) |
| `HEXE_SESSION` | set inside every pane, naming the session it belongs to |

And the layers can be started by hand when something has gone wrong:

```sh
hexe ses daemon --foreground        # usually started automatically by `terminal new`
hexe ses status                     # is it running, and where is its socket
hexe pod list                       # every pod with a metadata file
hexe pod gc --dry-run               # sockets and metadata left by pods that died
```

## Measurements

- **Uplink write budget: 2 s.** A pod writing to a SES that has stopped draining gives up after
  two seconds and drops the connection rather than blocking its own event loop — which would freeze
  the user's shell. Recovery is backlog replay.
- **Pod handshake budget: 5 s** for a peer to deliver its two-byte handshake, read resumably. It
  used to be a blocking read inside the accept loop, so any local process could connect, send
  nothing, and freeze a pod — and the shell in it — for the timeout, once per queued connection.
- **PTY write buffer: 256 KiB, growing to 16 MiB.** Input is never dropped short of that ceiling:
  a torn bracketed paste (a lost `ESC[201~`) leaves the shell swallowing every later keystroke, so
  the pane looks permanently frozen.
- **SES connection ceiling: 512**, against 64 registered frontends. Two connections per pane plus
  two per frontend puts a 30-pane session near 62.

## What it cannot do

- **SES is single-threaded and in the middle.** Frontends never connect straight to pods, so a
  stalled SES is felt by every session on the machine — which is why nearly every wait in it is
  bounded and budgeted.
- **There is no screen in the daemon.** Nothing outside a frontend can read what a pane displays.
- **The frontend is the only shipped one.** `hexe web` and `hexe syslink` exist as adapters against
  the same runtime, but they are probes and serving loops, not a UI you would use.
- **A pod's death is a pane's death.** There is no second copy of the PTY.
- **Remote needs a reachable SES and a bridge process.** It is transport reuse, not synchronisation:
  nothing is mirrored, and there is no offline mode.

## Where it lives

| | |
|---|---|
| `src/frontends/terminal/` | the frontend: `loop_*.zig` is the event loop, `state*.zig` the view state |
| `src/frontends/core/` | what any frontend must implement: actions, events, host protocol |
| `src/core/frontend_runtime.zig`, `frontend_client.zig`, `frontend_attach.zig` | the shared runtime |
| `src/core/session_projection.zig`, `session_model.zig` | the frontend-side mirror of SES truth |
| `src/modules/session/` | SES itself: `server*.zig`, `state.zig`, `vt_routing.zig` |
| `src/modules/pod/` | the pod: `main.zig`, `buffering.zig`, `uplink.zig`, `input_dedup.zig` |
| `src/core/wire.zig`, `pod_protocol.zig` | the two wire formats, and the runtime-epoch handshake |
| `src/cli/commands/ses_pipe.zig` | the remote bridge |
| `docs/architecture.md` | the same picture, as a reference page |
