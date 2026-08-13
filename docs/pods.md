# Pods

A pod is one process holding one PTY. Not a pane, not a session — a PTY, the shell running on it,
the bytes that shell has written, and a socket to reach all of that. Every pane in every session is
a pod, and a pod does not need a session at all:

```sh
hexe pod list                                  # every pod with a metadata file
hexe pod new --name notes                      # a shell with a socket in front of it
hexe pod send --name notes --enter "make"      # type into it from outside
hexe pod attach --name notes                   # a raw tty attach, like `screen -r` for one PTY
hexe pod kill --name notes
hexe pod gc --dry-run                          # sockets and metadata left by pods that died
```

<!-- demo:begin -->
[![pods demo](https://asciinema.org/a/1263009.svg)](https://asciinema.org/a/1263009)
<!-- demo:end -->

## How it works

```
                    ┌── backlog ring (4 MiB, always written first)
PTY master ─ read ──┤
                    └── SES uplink ─ VT frames ─> frontend

SES ── input frames (epoch, seq) ──> dedup ──> PTY write buffer ──> PTY master
```

The pod is an event loop around three things: the PTY, a listening socket, and a periodic tick. Its
entire design is one rule — **nothing that another process does may stop this pod from draining its
PTY.** A pod that stops reading its PTY fills the kernel buffer, and the shell inside it blocks:
the pane looks frozen, and the freeze survives detaching, reattaching, and killing the frontend.

That rule is why:

- Output is appended to the ring **before** it is written to SES, so a SES that has stopped reading
  costs a bounded stall and then a dropped connection, never a wedged pod. Nothing is lost: the
  bytes are in the ring, and reattaching replays them.
- Every read from a peer is resumable rather than blocking. Both the handshake and one-shot
  requests used to be bounded blocking reads *inside the accept loop*, so any local process could
  connect, send nothing, and freeze the pod — and the user's shell — for the timeout, once per
  queued connection.
- The PTY write buffer grows to 16 MiB rather than dropping input. A torn bracketed paste — one
  lost `ESC[201~` — leaves the shell swallowing every later keystroke, and the pane looks
  permanently frozen for a reason no user could diagnose.

### The backlog

The ring is what makes detaching cheap. It is a plain byte ring — raw PTY output, no parsing, no
screen — four megabytes deep. On attach the pod replays at most the last megabyte of it, and the
frontend's VT rebuilds the terminal from those bytes — screen *and* scrollback, because that is
what the bytes contain.

Two refinements matter:

**Alternate screen.** The pod watches the stream for `?1049h` / `?47h` / `?1047h` and remembers the
offset where the current alt-screen session began. If the pane is inside `nvim` when you reattach,
replay starts at that enter sequence — which the application immediately follows with a full
repaint — instead of pushing a megabyte of dead scrollback through the parser first.

**Line alignment.** On the normal screen the replay is a tail, and a tail starts wherever the ring
happens to wrap. Starting mid-escape-sequence desynchronises the VT: colours smear and the screen
garbles. The pod scans forward up to 64 KiB for a line boundary before giving up and using the raw
offset.

### Passwords

When the terminal signals password input, the frontend tells the pod, and the pod **clears its
backlog and stops buffering** for the duration. A password typed at `sudo` is therefore not sitting
in a ring waiting to be replayed onto the next screen that attaches.

### Exactly-once input

Input frames from a frontend carry a 16-byte `(epoch, seq)` prefix. The pod is the dedup authority
because it is the only process that survives every reconnect trigger — a slow frontend, a dropped
VT channel, a SES restart. First frame of a new epoch: adopt it. A `seq` at or below the last
applied one: drop it, because the frontend is replaying frames it could not confirm. Anything
newer: apply and advance. Without this, a reconnect could type the tail of your last command line
into your shell a second time.

### What a pod knows about itself

Each pod writes a metadata line — uuid, name, its own pid, the child's pid, cwd, shell, isolation,
labels, creation time — which is what `hexe pod list` reads, and it keeps SES informed of the
current working directory and foreground process. The cwd comes from OSC 7, which is why
`hexe shell init <shell>` emits one on every prompt: without it hexe cannot tell that a pane has
moved, and `per_cwd` floats collapse onto a single instance.

## What makes it different

In tmux there is no equivalent object. A pane is a structure inside the server, and it cannot be
addressed, attached to, or kept alive by itself: kill the server and every pane dies with it.

A hexe pod is an independent process with a socket, and that has consequences you can use:

- `hexe pod new` gives you a shell with no session — a detachable process that a script can drive
  with `pod send` and read later.
- A pane can be disowned from one session and adopted by another, because the pod never belonged to
  the session in the first place.
- SES can crash and be restarted, and the pods — and the shells inside them — do not notice.
- The cost is one process per pane, one socket per pane, and a garbage-collection command for the
  metadata that crashed pods leave behind.

## Configuration

Pods are not configured directly; a pane's pod is created from a layout's pane definition. The
pieces that reach a pod are the shell, the working directory, the environment, and isolation:

```lua
hexe.pane({ command = "btop", cwd = "src" })          -- what the pod runs
hexe.float("build", { command = "make", attrs = { isolated = true } })
```

Two environment variables are set inside every pane's shell, and both are meant to be read by
scripts and shell integrations:

| | |
|---|---|
| `HEXE_PANE_UUID` | the pod's uuid — how `hexe shp` and `hexe record` find "this pane" |
| `HEXE_SESSION` | the session the pane belongs to |

## Measurements

- **Backlog ring: 4 MiB per pane**, the wire's maximum payload length.
- **Replay window: the last 1 MiB of it**, minus whatever the alt-screen tracker lets it skip.
- **Replay alignment scan: 64 KiB** before falling back to the raw offset.
- **PTY write buffer: 256 KiB initial, 16 MiB ceiling.** Sized to absorb a clipboard paste without
  dropping a byte.
- **I/O working buffer: 64 KiB** for PTY and client reads.
- **Uplink and client write budget: 2 s.** Then the connection is dropped and healed by replay.
- **Handshake budget: 5 s**, read resumably; a peer that never finishes is reaped on the tick.
- **Socket self-heal: every 5 s.** The pod checks that its socket file and accept watcher are still
  there, and rebuilds them if something removed them underneath it.

## What it cannot do

- **A pod holds bytes, not a screen.** It cannot tell you what is displayed; only a frontend knows,
  because only a frontend parses VT.
- **The ring is finite, and replay reads less of it than it holds.** Four megabytes are kept, one
  is replayed: output older than that is gone from the screen you get back even when it is still in
  the ring.
- **`pod attach` is one client at a time in the VT sense** — it is a raw tty attach for a single
  PTY, not a second view of a session.
- **A pod dies with its shell.** When the child exits the pane goes away; there is a short grace
  period for an attached client to see the last output, and that is all.
- **Metadata can outlive the process.** A pod killed with `SIGKILL` leaves its socket and `.meta`
  file behind — `hexe pod gc` exists precisely because of that.
- **`cwd` is only as good as the shell's OSC 7.** A shell with no integration reports `cwd=-`, and
  every feature keyed on the working directory silently degrades.

## Where it lives

| | |
|---|---|
| `src/modules/pod/main.zig` | the event loop, the PTY, the write buffer, password mode |
| `src/modules/pod/buffering.zig` | `RingBuffer`, `AltScreenTracker`, `replaySkipBytes`, `Osc7Scanner` |
| `src/modules/pod/input_dedup.zig` | the `(epoch, seq)` exactly-once filter |
| `src/modules/pod/uplink.zig` | cwd / foreground-process reporting to SES |
| `src/core/pod_protocol.zig` | frame types, including `password_mode` |
| `src/core/pod_meta.zig` | the metadata file `pod list` and `pod gc` read |
| `src/cli/commands/pod_*.zig` | `list`, `new`, `send`, `attach`, `record`, `kill`, `gc` |
