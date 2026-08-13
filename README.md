# Hexa

A session-based terminal workspace where the frontend is disposable and your
shells are not.

Crash the terminal frontend, restart it, reattach, and your terminals keep
running exactly where you left them.

---

## How it works

Hexa splits into four layers:

- **`hexe terminal`** — the terminal UI frontend (aliases: `hexe mux`, `hexe multiplexer`).
- **shared frontend runtime** — attach lifecycle, transport, and the frontend-side session projection.
- **`hexe session` / `hexe ses`** — the session authority that owns canonical session state.
- **`hexe pod`** — one per pane. Owns the PTY, holds the shell, buffers output even while detached.

See [architecture](docs/architecture.md) for the full picture.

---

## Docs

One document per feature in [`docs/`](docs/README.md), each opening with a recording of it running:
how it works, how it differs from tmux, what it cannot do, and where it lives in the tree. Every
claim in them was checked against the source or a running build, and the recordings are made by
hexe itself — see [recording](docs/recording.md).

| | |
|---|---|
| [Four processes](docs/architecture.md) | frontend, runtime, SES, pod — and why only one is disposable |
| [Sessions](docs/sessions.md) | detach, reattach, replay, adoption, and what is written down |
| [Pods](docs/pods.md) | one daemon per pane: the PTY, the backlog ring, exactly-once input |
| [Instances](docs/instances.md) | two whole stacks on one machine that cannot see each other |
| [Panes and tabs](docs/panes-and-tabs.md) | the split tree, geometric focus, zoom, broadcast, select-and-swap |
| [Floats](docs/floats.md) | overlay panes with lifetimes: per-directory, sticky, exclusive, sandboxed |
| [Keybindings](docs/keybindings.md) | no prefix: chords, conditions, and what happens to the key afterwards |
| [Reading what happened](docs/copy-and-search.md) | scrollback search, copy-mode, OSC 133 prompt marks |
| [Overlays and popups](docs/overlays.md) | notifications, questions, pickers, keycast, pane labels |
| [The status bar](docs/statusbar.md) | three zones, priority budgets, buttons, progress from panes |
| [The shell prompt](docs/prompt.md) | the same segments, rendered into oslo, bash, zsh or fish |
| [Sprites](docs/sprites.md) | 2304 pokemon in 1.6 MB, and why a pane is named after one |
| [Configuration](docs/config.md) | one Lua file, a schema that refuses typos, reload without losing panes |
| [Project sessions](docs/session-manager.md) | `.hexe.lua`, freezing a session, and the trust ledger |
| [Isolation](docs/isolation.md) | namespaces and cgroups per pane — and what it needs from the kernel |
| [The command line](docs/cli.md) | addressing sessions, panes and pods from a script |
| [Recording](docs/recording.md) | hexe writes asciicasts of itself; every film in the docs was made that way |

---|---|
| [Architecture](docs/architecture.md) | How terminal, runtime, ses, and pod fit together |
| [Sessions](docs/sessions.md) | Detach, reattach, layouts, pane adoption |
| [Floats](docs/floats.md) | Overlay panes — per-directory, persistent, isolated |
| [Keybindings](docs/keybindings.md) | Binding system, actions, conditions, gestures |
| [Status bar & prompt](docs/statusbar.md) | Segments, animations, conditions |
| [Isolation](docs/isolation.md) | Linux namespace + cgroup sandboxing for panes |
| [Instances](docs/instances.md) | Running multiple independent stacks side by side |
| [Config](docs/config.md) | Full config reference |
| [CLI](docs/cli.md) | All commands and flags |

---

## Quick start

**Build** (requires Zig):

```sh
zig build -Doptimize=ReleaseFast
```

**Run:**

```sh
hexe terminal new
```

**Detach** (default: `Alt+Shift+D` release), then reattach:

```sh
hexe terminal attach <session-name-or-prefix>
hexe session list   # to find sessions
```

**Config** lives at `~/.config/hexe/init.lua`. See [config](docs/config.md).

---

## History

Started as bash and Python hacks wrapped around tmux. Absolutely cursed code. Shell scripts spawning tmux sessions, Python daemons talking to tmux through send-keys, config files that were basically more shell scripts. It was wild. But it worked, and it was the workflow I wanted.

Rewrote it properly in Rust on top of tmux-rs, got far, learned a lot about terminal internals. But that crate is mostly unsafe and you're still building on top of tmux's architecture rather than escaping it.

Then Ghostty came out. Saw what Mitchell was doing with Zig and decided to start from scratch. Zero regrets. Zig is a joy, Ghostty's VT implementation is solid, and the architecture finally matches what I actually wanted to build.

---

## Credits

- [Zig](https://ziglang.org)
- [ghostty-vt](https://github.com/ghostty-org/ghostty) — terminal emulation
- [libvaxis](https://github.com/rockorager/libvaxis) — TUI rendering
- [libxev](https://github.com/mitchellh/libxev) — event loop
- [yazap](https://github.com/PrajwalCH/yazap) — CLI argument parser
- [libvoid](https://github.com/bresilla/libvoid) — process isolation
- [krabby](https://github.com/yannjor/krabby) — Pokemon sprites
