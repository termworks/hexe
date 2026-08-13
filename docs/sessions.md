# Sessions

A session is the thing that survives. It owns the tabs, the splits, the floats and — through the
pods — the shells, and none of that belongs to the terminal window you happen to be looking at.
Close the window, kill the frontend, lose the ssh connection: the session is a set of processes on
the machine, and it keeps running.

```sh
hexe terminal new                 # a new session, named after a pokemon
hexe terminal new --name work     # or named by you
hexe terminal attach work         # by name
hexe terminal attach a3f2         # or by uuid prefix
hexe ses list                     # what is running, attached or not
```

<!-- demo:begin -->
[![sessions demo](https://asciinema.org/a/1263013.svg)](https://asciinema.org/a/1263013)
<!-- demo:end -->

## How it works

Detach is not a save. There is nothing to restore, because nothing stopped:

```
  attached                     detached                     attached again
┌──────────────┐             ┌──────────────┐             ┌──────────────┐
│ frontend     │  detach     │              │  attach     │ frontend     │
│ renders      │ ─────────>  │   (nothing)  │ ─────────>  │ renders      │
└──────┬───────┘  exits      └──────────────┘             └──────┬───────┘
       │                                                         │
┌──────┴───────┐             ┌──────────────┐             ┌──────┴───────┐
│ SES          │  keeps      │ SES          │  serves     │ SES          │
│ session graph│ ─────────>  │ session graph│ ─────────>  │ same graph   │
└──────┬───────┘  running    └──────┬───────┘  snapshot   └──────┬───────┘
       │                            │                            │
┌──────┴───────┐             ┌──────┴───────┐             ┌──────┴───────┐
│ POD  · shell │  keeps      │ POD  · shell │  replays    │ POD  · shell │
│ backlog ring │ ─────────>  │ still fills  │ ─────────>  │ backlog      │
└──────────────┘  running    └──────────────┘  backlog    └──────────────┘
```

The frontend asks SES to detach, SES writes the session down, and the frontend process exits. The
pods never hear about it. Their shells keep running, their output keeps arriving, and each pod
keeps appending it to a ring buffer that exists for exactly this moment. When a new frontend
attaches, SES hands it the authoritative session snapshot and each pane replays its pod's backlog
into a fresh Ghostty VT — so the screen you get is not a screenshot that was saved, it is the
terminal state rebuilt from the bytes the shell actually wrote while you were gone.

That replay is bounded and it is not naive. The ring holds four megabytes per pane and replay
takes at most the last one of them, because pushing a megabyte of history into a full-screen
application would be both slow and wrong: `nvim` does not
want its last hour of redraws, it wants its current screen. So the pod tracks alternate-screen
enter/leave in the stream, and when the pane is on the alt screen with the enter sequence still in
the ring, replay starts *at that sequence* — which is immediately followed by the application's own
full repaint. On the normal screen it replays the tail, aligned forward to a line boundary so the
first thing the VT sees is not the middle of an escape sequence.

### What a session is made of

```
session ──┬── tab ──┬── split tree ──┬── pane ── pod ── shell
          │         │                └── pane ── pod ── shell
          │         └── floats (tab-bound)
          ├── tab ...
          └── floats (global)
```

SES owns that tree, and it is the only thing that may change its shape. The frontend sends
*intentions* — split this, close that, focus there — and re-reads the tree that comes back. This is
why two frontends attached to one session cannot disagree about it, and why a frontend crash cannot
corrupt it: there is no frontend-authored copy to lose.

### Names

A session with no `--name` gets a pokemon; so does every pane. They exist to be typed: `attach
work`, `attach a3f2` and `attach nido` all resolve by prefix, over both names and uuids.

Three behaviours follow from that, and none of them were written down before:

- **Names are made unique automatically.** Ask for a name that is taken and you get a suffixed one
  rather than a collision.
- **An ambiguous prefix lists the candidates** instead of picking one for you.
- **Attaching to a session that is already attached steals it.** The other frontend is detached;
  the session is single, and the newcomer wins.

A frontend that simply vanishes — the terminal closed, the ssh link dropped — is noticed and the
session auto-detaches rather than being held open by a client that is gone.

### The environment a session runs in

A session's environment is the environment of the shell that opened it, captured from that
process at register time — not the daemon's. Every pane spawned later inherits it, which is what
makes a session opened from a project directory get that project's `PATH`, its direnv or nix
profile, and its variables.

It is re-captured on every attach, including reattach: attaching from a shell whose environment has
changed gives *newly created* panes the new environment. Panes already running keep what they were
spawned with, because a running process's environment cannot be rewritten from outside.

Two things are always set per pane rather than inherited — `PWD`, restated from the directory the
pane actually starts in, and `HEXE_SESSION`, naming the session. `OLDPWD` is deliberately not set:
a fresh shell has no previous directory.

### Adoption

A pane can be taken out of its session without being killed:

| | |
|---|---|
| `hexe.action.pane.disown()` | the pane leaves the session; the pod and its shell keep running, orphaned |
| `hexe.action.pane.adopt()` | pick an orphaned pane up into this session |

Adopting offers what to do with the slot you are standing in: swap with it, or destroy the current
pane and take its place. This is the mechanism behind moving work between sessions without losing
it, and it is also what a crashed frontend leaves behind if a pane's session record is gone but its
pod is not.

## What makes it different

tmux and screen have the same headline — the shells outlive the terminal — and get there by a
different route: their server owns the terminal state, and the client is a thin renderer of a
server-side screen. Hexe splits that in two. SES owns the session *structure* and never parses VT;
each pod owns one PTY and its raw byte stream; the VT parsing and rendering happen in the frontend.

The visible consequence is what a reattach costs. There is no server-side screen to serialize and
no per-pane terminal emulation in the daemon: reattach is a snapshot plus a byte replay, and the
pane comes back with real scrollback rather than a saved screen.

The other consequence is a failure mode neither tmux nor hexe can fully avoid but which they place
differently: in hexe a pod that dies takes one pane with it, and a SES that dies takes the session
structure — which is why SES writes it down and reads it back on restart.

## Configuration

Sessions get their initial shape from a layout, which is ordinary config:

```lua
local hexe = require("hexe")

return hexe.setup({
  ses = {
    layouts = {
      hexe.layout("default", {
        enabled = true,
        tabs = {
          hexe.tab("main", { root = hexe.pane({ cwd = "." }) }),
          hexe.tab("logs", { root = hexe.pane({ command = "journalctl -f" }) }),
        },
        floats = {
          hexe.float("git", { key = "1", command = "lazygit", attrs = { per_cwd = true } }),
        },
      }),
    },
  },
})
```

A per-project `.hexe.lua` uses the same constructors and is opened with `hexe layout open .` — see
[project sessions](session-manager.md). Floats have their own document: [floats](floats.md).

The detach key is a binding like any other, so it is whatever you say it is:

```lua
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.d }, hexe.action.detach()),
```

### Where the state lives

| | |
|---|---|
| `$XDG_RUNTIME_DIR/hexe/[<instance>/]` | the sockets: one for SES, one per pod |
| `$XDG_STATE_HOME/hexe/[<instance>/]ses_state.json` | the session graph, rewritten atomically |
| `$XDG_STATE_HOME/hexe/<instance>/` | the debug log, when one is asked for |

The state file is why `hexe ses list` still knows about your sessions after SES itself has been
restarted, and the runtime directory is why two instances can run side by side without meeting —
see [instances](instances.md).

## Measurements

- **Backlog ring: 4 MiB per pane** (the wire's maximum payload), of which **at most 1 MiB is
  replayed** on reattach — "the visible screen plus generous recent scrollback, small enough that a
  reattach never feels stuck".
- **Replay alignment scan: 64 KiB.** How far the pod will look forward for a line boundary before
  giving up and replaying from the raw offset — generous enough to clear any escape sequence or
  long line, small enough that real history is never discarded chasing a newline that is not
  coming.
- **Pane-creation handshake budget: 500 ms.** A blocking wait on the single-threaded SES loop, so
  it is also the worst-case stall every other session pays for one pane being created. Measured
  over ten spawns on a loaded box: minimum 15 ms, median 22 ms, maximum 31 ms — about 16× headroom.
- **Connection ceiling: 512.** SES holds two connections per pane plus two per frontend, so the
  limit is roughly 250 panes; the older 64 limit started refusing at about 32.

## What it cannot do

- **A session does not survive a reboot.** Everything here is process lifetime: the pods are
  processes, the shells inside them are processes. `ses_state.json` recovers the session *map*
  after SES restarts, not the shells.
- **It does not move between machines.** A remote frontend can attach across a link to a SES
  running elsewhere, but the session stays where its pods are.
- **A pane cannot outlive its pod.** Kill the pod and the pane is gone with its scrollback; there
  is no second copy of the stream anywhere.
- **Replay is bounded twice.** The ring drops everything past four megabytes, and replay reads at
  most the last megabyte of what is left. Detach for long enough and the pane comes back correct,
  not complete.
- **Two frontends attached at once share one focus.** The session graph — including which pane is
  focused — is single and authoritative, so a second attach is a second view of the same session,
  not an independent one.
- **`hexe ses stats` prints nothing** in this build and exits non-zero. The other listing commands
  (`ses list`, `ses list --details`, `pod list`) are the ones to use.

## Where it lives

| | |
|---|---|
| `src/modules/session/` | SES: the session authority. `state.zig` is the graph, `server*.zig` the request handlers |
| `src/modules/session/detach_lifecycle.zig`, `detached_sessions.zig` | detach and the detached-session registry |
| `src/modules/session/persist.zig`, `persistence.zig`, `txlog.zig` | writing the graph down, reading it back, and the transaction log that makes a half-finished detach recoverable |
| `src/modules/session/sticky_panes.zig` | panes and floats that are kept alive across a frontend's absence |
| `src/modules/pod/buffering.zig` | the backlog ring, the alt-screen tracker, `replaySkipBytes` |
| `src/frontends/terminal/state_reattach.zig`, `reattach_reconcile.zig` | rebuilding the view from a snapshot |
| `src/core/frontend_attach.zig`, `frontend_runtime.zig` | the attach lifecycle shared by every frontend |
| `src/cli/app.zig` | `terminal new`, `terminal attach`, `session list/kill/clear/export` |
