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

| Topic | Description |
|---|---|
| [Architecture](docs/architecture.md) | How terminal, runtime, ses, and pod fit together |
| [Sessions](docs/sessions.md) | Detach, reattach, layouts, pane adoption |
| [Floats](docs/floats.md) | Overlay panes — per-directory, persistent, isolated |
| [Float attributes](docs/float_attributes.md) | Detailed flag reference for float behavior |
| [Keybindings](docs/keybindings.md) | Binding system, actions, conditions, gestures |
| [Status bar & prompt](docs/statusbar.md) | Segments, animations, conditions |
| [Isolation](docs/isolation.md) | Linux namespace + cgroup sandboxing for panes |
| [Instances](docs/instances.md) | Running multiple independent stacks side by side |
| [Config](docs/config.md) | Full config reference |
| [CLI](docs/cli.md) | All commands and flags |
| [Sprites](docs/sprite.md) | Pokemon sprite overlays |

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
