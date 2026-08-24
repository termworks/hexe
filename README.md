# hexe

A session-based terminal workspace where the frontend is disposable and your
shells are not.

Crash the terminal frontend, restart it, reattach, and your terminals keep
running exactly where you left them.

---

## How it works

hexe splits into four layers:

- **`hexe terminal`** — the terminal UI frontend (aliases: `hexe mux`, `hexe multiplexer`).
- **shared frontend runtime** — attach lifecycle, transport, and the frontend-side session projection.
- **`hexe session` / `hexe ses`** — the session authority that owns canonical session state.
- **`hexe pod`** — one per pane. Owns the PTY, holds the shell, buffers output even while detached.

See [architecture](docs/architecture.md) for the full picture.

---

## Palette namespaces

A program can claim its own 256-colour table — one of 32 numbered slots — for
the output it writes.
Recolour that table and only its cells change — the rest of the pane stays
exactly as it was, on screen and in scrollback, with no redraw from the
application.

```sh
hexe palette set --ns 4 33=#ff00aa bg=#1a1020
hexe palette get                                    # what is actually set
```

An application drives it directly, with nothing to negotiate first — claim a
slot, print, release it:

```sh
printf '\033]1330;set;4;33=#ff00aa\033\\'
printf '\033]1330;use;4\033\\'
printf 'this line resolves colour 33 through slot 4\n'
printf '\033]1330;end\033\\'
```

Slot 0 is what unclaimed output resolves against, slot 1 is hexe's own chrome —
borders, status bar, float titles — and slots 2–31 are yours.

hexe holds the colours and resolves the indexes; it never decides which cells
belong to which slot. Every cell records the slot that was current when it was
written — the number itself, so there is no mapping to lose — and two slots are
correct on screen at once, with a repaint reaching scrollback. Setting slot 0 recolours the ordinary
palette; setting slot 1 recolours hexe's own furniture. Anything hexe does not recognise — an unknown name, a program that
claims nothing, another terminal entirely — falls back to your own palette, so a
default install looks exactly as it did before.

See [the palette protocol](docs/palette.md) for the sequences to emit.

---

## Anything can drive it

Everything hexe knows about its panes, floats, tabs and session has one definition — the live Lua
API — and a socket hands that same API to any program that can open one. There is no second list of
fields to drift out of step with the first, and nothing has to scrape formatted output for facts
hexe holds exactly.

```sh
hexe api panes                      # every pane, as JSON
hexe api count '"panes"'
hexe api act '{"type":"split.v"}'
hexe api send '"904dd85…"' '"make test\n"'
```

`hexe api` is a thin client; the socket is the interface. Frames are a 4-byte big-endian length and
a JSON body, so a gateway, a phone client behind one, or a shell script are all the same amount of
work. Instead of polling, a client can subscribe and be told.

**Three doors, each with its own authority**, because a grant a caller can decline is not a grant:

| socket | who holds it | may do |
|---|---|---|
| `api@<session>.sock` | you | everything |
| `plug@<session>.<name>.sock` | one plugin | only what it declared |
| `pane@<uuid>.sock` | whatever runs in that pane | read and type into *that pane* |

A plugin is a package that declares what it needs — `stream`, `typing`, `keyboard`, `popup` — and is
handed a socket carrying exactly that; a verb it did not ask for is refused by name. A pane's socket
is exported to its shell as `$HEXE_PANE_API_SOCKET`, so a program in a pane finally has something it
can safely be given: a session-wide call is refused, and a selector naming another pane resolves to
nothing rather than to the caller's own.

For another Lua — a shell, an editor, a sibling tool — `hexe lua-api` prints a plain-Lua client, and
the `client` verb returns the same source over the socket for a host that cannot shell out:

```lua
local mux = hexe.connect()            -- or connect_pane(), inside a pane
for _, pane in ipairs(mux.panes()) do print(pane.name, pane.cwd) end
```

See [the control socket](docs/api.md), [access](docs/access.md) and [plugins](docs/plugins.md).

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
| [Painting](docs/regions.md) | the bar, titles, sprites and popups are drawn by an external painter |
| [Shell integration](docs/prompt.md) | what a shell reports to the mux, and how the prompt is drawn |
| [Palette protocol](docs/palette.md) | a program claims its own 256-colour table for the output it writes |
| [Configuration](docs/config.md) | one Lua file, a schema that refuses typos, reload without losing panes |
| [Project sessions](docs/session-manager.md) | `.hexe.lua`, freezing a session, and the trust ledger |
| [Isolation](docs/isolation.md) | namespaces and cgroups per pane — and what it needs from the kernel |
| [The command line](docs/cli.md) | addressing sessions, panes and pods from a script |
| [The control socket](docs/api.md) | the live API over a socket: what any program can ask and do |
| [Access](docs/access.md) | what a helper may do — stream, typing, keyboard, popup — declared and enforced |
| [Plugins](docs/plugins.md) | install, declare, approve, remove — a package, not a command string |
| [Streaming a pane](docs/streaming.md) | a pane's bytes, who is watching, and how to cut them off |
| [Dictation](docs/dictation.md) | speech to text as a tool hexe drives, and the sign that a mic is open |
| [Names](docs/names.md) | how panes and sessions get names, and what a name is allowed to be |
| [Decorations](docs/decor.md) | borders, titles and what a pane is allowed to draw around itself |
| [Recording](docs/recording.md) | hexe writes asciicasts of itself; every film in the docs was made that way |

---

## Quick start

**Build.** Needs Zig 0.15.2. A static musl binary:

```sh
scripts/vendor-ghostty.sh                                  # once: fetch + patch ghostty-vt
scripts/vendor-yazap.sh                                    # once: fetch + patch yazap
zig build -Doptimize=ReleaseFast -Dstrip=true -Dtarget=x86_64-linux-musl
```

That is the whole build, and it is what CI runs — CI has no oslo, so the pins live in the
scripts rather than in a recipe. With [oslo](https://github.com/bresilla/oslo) the recipes in
`.make.lua` wrap them. There is no `Makefile`; the targets come from oslo:

```sh
oslo make vendor    # fetch the pinned dependencies and apply hexe's patches
oslo make build     # the build above, then size and which hexe is on $PATH
oslo make install   # …and copy it everywhere hexe already is
oslo make test      # the Zig unit tests
oslo make smoke     # the live end-to-end suite
oslo make           # every target, with a line each
```

Build with `oslo make build` rather than a bare `zig build`: the default is a Debug binary, which
is slow enough to look like a bug.

**Run:**

```sh
hexe terminal new             # a new session, named after a pokemon
hexe terminal new --name work # or named by you
hexe                          # bare: attach to a session rooted here, or load ./.hexe.lua
```

**Detach and come back.** Detach is a keybinding, so it is whatever your config says — there is no
built-in chord:

```lua
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.d }, hexe.action.detach())
```

```sh
hexe session list                    # what is running, attached or not
hexe terminal attach work            # by name, or by uuid prefix
```

**Config** lives at `~/.config/hexe/init.lua` and is Lua. See [configuration](docs/config.md), and
[keybindings](docs/keybindings.md) for the binding language.

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
- [ziglua](https://github.com/natecraddock/ziglua) — the Lua binding the config and live API run on
- [yazap](https://github.com/PrajwalCH/yazap) — CLI argument parser
- [libvoid](https://github.com/bresilla/libvoid) — process isolation
- [liblink](https://github.com/libzig/liblink) — the remote-frontend transport behind `hexe syslink`
- [logly](https://github.com/muhammad-fiaz/logly.zig) — logging
- [krabby](https://github.com/yannjor/krabby) — Pokemon sprites
