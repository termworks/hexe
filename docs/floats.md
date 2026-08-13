# Floats

A float is a pane that is not in the split tree. It has a border, a title, a size in percent, an
anchor, and — this is the part that matters — a set of attributes describing what it is *for*: one
per project directory, kept alive when the terminal restarts, killed the moment it is hidden,
sandboxed, or carrying an environment of its own.

```lua
hexe.float("git", {
  key     = "1",
  title   = "git",
  command = "lazygit",
  attrs   = { per_cwd = true, sticky = true, global = true, exclusive = true },
  size    = { width = 80, height = 60 },
}),
```

```lua
hexe.key({ hexe.key.alt, hexe.key["1"] }, hexe.action.float.toggle("1")),
```

<!-- demo:begin -->
[![floats demo](https://asciinema.org/a/1263028.svg)](https://asciinema.org/a/1263028)
<!-- demo:end -->

## How it works

A float is toggled by the `key` string it declares — the binding names it, so one key per float and
the two halves stay together. What toggling does depends on the attributes, and there are three
questions being answered:

```
                     ┌ which instance is this?          per_cwd
toggle key ────────> ├ is it allowed on this tab?       global
                     └ what happens when it hides?      destroy · sticky · exclusive
```

**Which instance.** A plain float has one process. A `per_cwd` float has one process *per working
directory*: toggling the key in `~/work/a` opens that directory's instance, toggling it in
`~/work/b` opens another, and coming back to `a` finds the first exactly as you left it, scrollback
and all. This is the attribute that makes a `lazygit` or a REPL key useful — it is bound once and
means "the one for here". It depends on the pane's cwd being known, which is OSC 7, which is what
`hexe shell init <shell>` emits.

**Which tab.** A `global` float belongs to no tab; its visibility is tracked per tab with a
bitmask, so the same instance can be shown on one tab and hidden on another. A tab-bound float
(the default) dies with its tab, and pressing its key on a *different* tab creates a second
instance rather than moving the first — there is no way to move a tab-bound float between tabs.
`per_cwd` implies global regardless of what you wrote.

That bitmask is a `u64` (`state.zig:2539`), so a global float's visibility can only be tracked for
the first 64 tabs: on tab 65 and beyond it can never be shown.

**What hiding means.** Hiding is just hiding: the process keeps running, and toggling back is
instant. (`destroy` is *supposed* to kill it instead and does not — see below.) `sticky` goes the
other way —
ses keeps the pod alive in a half-attached state when the frontend detaches or exits, and a new
frontend reclaims it on reattach, so a float survives the terminal that opened it. `exclusive`
hides every other float on the tab when this one is shown, which is what you want for something
you look *at* rather than beside.

### Environment

A float can depart from the session's environment in three ways, and they compose:

```lua
hexe.float("claude", {
  key      = "2",
  command  = "claude",
  attrs    = { per_cwd = true, inherit_env = true },
  add_env  = { ANTHROPIC_MODEL = "opus", NO_COLOR = "1" },
  add_path = { "/opt/toolchain/bin" },
})
```

`inherit_env` imports the *currently focused pane's* environment at creation, which is how a float
picks up a direnv or nix profile you activated in the pane you launched it from. `add_env` sets
variables for this float only, and wins over anything inherited. `add_path` prepends directories:
an entry already on `PATH` is *moved* to the front rather than duplicated, because asking for a
path you already have is a request to raise its priority.

All three apply when the process is **spawned**. Toggling an existing float back reuses its
process, so a change takes effect on the next creation — a new `per_cwd` directory, a fresh
session, or after a `destroy`.

### Visuals

Structure and behaviour come from the layout; appearance comes from `mux.floats`, in three layers:

```
defaults ──> (named floats)          size, colours, border, title, padding, shadow
adhoc    ──> (CLI floats)
match["^git$"] ──> applied on top, in declaration order, by TITLE
```

Later matches win. The border can carry a title module built from the same segment machinery the
status bar uses, so a float's border can show anything a status segment can.

### Ad-hoc floats

A float does not have to be declared. This is a one-off, and it is how hexe is used as a picker
from inside a script:

```sh
dir=$(hexe terminal float --title picker --size 60,40 \
        --result-file /tmp/pick --command 'bash -c "ls | fzf > /tmp/pick"')
```

| | |
|---|---|
| `--command` | what to run (required) |
| `--title` | border title, and the key `match[…]` rules are tested against |
| `--cwd` | working directory |
| `--size w,h,x,y` | percentages: width, height, and an optional shift on each axis |
| `--isolation <profile>` \| `--isolated` | run it sandboxed ([isolation](isolation.md)) |
| `--key <key>` | key sent to the pane when the float is dismissed |
| `--result-file <path>` | where the float's result is written |
| `--pass-env` \| `--extra-env K=V` | environment for this float |

The command blocks until the float closes, then prints what the float wrote to `--result-file` on
stdout and exits with the float's exit code — which is what makes the command substitution above
work. The wait is deliberately unbounded: it was once capped at the ten-second wire default, so any
interactive float open longer than that returned nothing.

## What makes it different

tmux popups (`display-popup`) are the nearest thing, and they are transient by design: a popup is a
window that exists while its command runs. Everything in this document is about the opposite —
floats that *persist*, and persist with a scope you choose:

- **Per-directory instances** have no tmux equivalent; you would keep separate sessions or windows
  per project and switch between them.
- **`sticky` outlives the frontend**, which a popup cannot: a popup dies with the client that
  opened it.
- **Floats have a lifecycle of their own** — shown, hidden, destroyed — rather than being tied to a
  command's exit.
- What tmux popups do better: they are one command with no declaration, which is why hexe also has
  `hexe terminal float`.

## Configuration

### Attributes

| | |
|---|---|
| `per_cwd` | one instance per working directory; implies `global` |
| `sticky` | ses keeps the pod alive across frontend exits; reclaimed on reattach |
| `global` | not owned by a tab; visibility tracked per tab |
| `exclusive` | hides the other floats on the tab when shown (one-way: they are not restored) |
| `destroy` | **accepted and inert.** Parsed and merged into the float's attributes, then never read: nothing kills a float's process on hide, in the frontend or in SES |
| `isolated` | run the command in a sandboxed pod |
| `navigatable` | **accepted and inert.** Stored on the float's view state and never consulted by focus movement; with a float focused, left/right still switch tabs and up/down still do nothing |
| `inherit_env` | import the focused pane's environment at creation |

The first float entry with no `key` supplies defaults for the rest. Defaults are additive: they can
turn an attribute on, not force it off for a float that asked for it.

### Size, position, movement

```lua
size     = { width = 80, height = 60 },   -- percent of the terminal, 10–100
position = { x = 100, y = 50 },           -- 0 = left/top, 50 = centre, 100 = right/bottom
```

```lua
hexe.key({ hexe.key.alt, hexe.key.shift, hexe.key.left }, hexe.action.float.nudge("left")),
```

### Visual rules

```lua
mux = {
  floats = {
    defaults = { size = { width = 80, height = 65 }, color = { active = 5, passive = 237 } },
    adhoc    = { size = { width = 70, height = 55 }, color = { active = 4, passive = 237 } },
    match = {
      ["^git$"] = {
        padding = { x = 2, y = 1 },
        style = { border = { chars = { top_left = "╭", top_right = "╮" } } },
      },
    },
  },
},
```

## What it cannot do

- **`exclusive` is one-way.** The floats it hides stay hidden; nothing restores them when it is
  dismissed.
- **`destroy` does nothing at all.** It is accepted by the config, merged into the float's
  attributes at `state.zig:443`, and then never read by any code path: hiding a `destroy` float
  leaves its process running exactly like any other. The same is true of `navigatable`. Both are
  config that parses and lies.
- **A float whose command exits closes.** `git log` flashes and is gone unless the command keeps a
  process alive — `…; exec $SHELL` is the usual fix.
- **`add_path` does not expand `~`.** Use an absolute path, or set the whole `PATH` via `add_env`.
- **Environment changes need a new process.** Editing `add_env` and toggling an existing float
  changes nothing.
- **`per_cwd` needs OSC 7.** With a shell that does not report its directory, every instance
  collapses into one.
- **Floats do not tile.** They overlap in focus order — the focused one is drawn last — and there
  is no arrangement to configure beyond size, anchor and nudging.
- **A global float cannot be shown past tab 64.** Its per-tab visibility lives in a `u64`.
- **A tab-bound float cannot move tabs.** Its key on another tab makes another instance.

## Where it lives

| | |
|---|---|
| `src/core/config.zig` | `FloatAttributes`, `FloatDef` — the authoritative attribute list |
| `src/frontends/terminal/loop_actions.zig` | toggle, create, per-cwd resolution, exclusivity |
| `src/frontends/terminal/float_util.zig`, `float_title.zig`, `float_completion.zig` | geometry, border titles, result files |
| `src/frontends/terminal/overlay_render.zig`, `borders.zig` | drawing floats and their borders |
| `src/core/api_bridge_float.zig` | the Lua side of a float definition |
| `src/modules/session/sticky_panes.zig` | keeping sticky floats alive between frontends |
| `src/cli/commands/mux_float.zig` | `hexe terminal float` |
