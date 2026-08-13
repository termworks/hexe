# Keybindings

There is no prefix key. A binding is a chord, an action, a condition and a disposal rule, and a key
that matches nothing at all reaches the pane unchanged — which is the default state of every key on
your keyboard.

```lua
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.t }, hexe.action.tab.new()),

hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.up }, nil, {
  mode = hexe.mode.passthrough_only,
  when = function(ctx)
    local p = ctx.pane(0)
    return p and (p.process_name == "nvim" or p.process_name == "vim")
  end,
}),
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.up }, hexe.action.focus.move("up")),
```

<!-- demo:begin -->
[![keybindings demo](https://asciinema.org/a/1263006.svg)](https://asciinema.org/a/1263006)
<!-- demo:end -->

## How it works

```
key event
   │
   ├─ a modal surface is up? (search · copy-mode · rename · popup)  ─> it takes the key
   │
   ├─ walk the bind list in order
   │     ├─ chord matches?          mods bitmask + key
   │     ├─ `on` matches?           press · release · repeat · hold
   │     └─ `when` returns true?    a Lua callback over the focused pane
   │        └─ first match wins
   │
   └─ no match ─> the key is translated and written to the focused pane's pod
```

**Order is the resolution rule.** The two bindings in the example above are the same chord: the
first one, conditional on `nvim` being in the foreground, passes the key through and stops there;
the second is reached only when the first did not match. This is how a chord can belong to the
editor in one pane and to the multiplexer in the next, with no modes and no prefix.

It cuts the other way too, and quietly. A chord bound earlier with **no** `when` matches
everything, so a later binding of the same chord is dead code:

```lua
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.v }, hexe.action.clipboard.request()),
-- …
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.v }, hexe.action.split.vertical(), { when = focused_split }),
```

The second line never fires: the first has already matched. Nothing warns about it, and the symptom
is a key that "does not work" while its binding is plainly there in the file.

### What happens to the key afterwards

| | |
|---|---|
| `hexe.mode.act_and_consume` | run the action, swallow the key (default) |
| `hexe.mode.act_and_passthrough` | run the action *and* send the key to the pane |
| `hexe.mode.passthrough_only` | send the key to the pane, run nothing |

### Keys the frontend keeps for itself

Two sets of keys never reach the bind list at all:

| | |
|---|---|
| `Ctrl+Q` | quits, always, and cannot be rebound or shadowed (`loop_input.zig:948`) |
| `PageUp`, `PageDown`, `Home`, `End`, `Shift+Up`, `Shift+Down` | scroll the frontend's own scrollback, with acceleration; the pane never sees them |

Anything the decoder understands but no bind claims is forwarded to the pane **as its original
bytes**, not as a re-encoding — and any forwarded input snaps the pane back to the bottom of its
scrollback, which is what you want after reading history.

### When a chord fires

`on` distinguishes four moments — `press`, `release`, `repeat`, `hold` — with two thresholds
turning a held key into three outcomes: under `tap_ms` it is a repeat and fires nothing, between
`tap_ms` and `hold_ms` it is a tap, and beyond `hold_ms` it is a hold. This is what makes
"hold Alt+Shift+D to detach" possible without that chord being unusable for anything else. A single
bind can override the threshold with its own `hold_ms`.

Three details of that machine are worth knowing, because they are what stop it misfiring: a tap is
decided on key *release*, auto-repeat is suppressed by a repeat lock rather than fired repeatedly,
and an **unmodified** chord skips the tap/hold machinery altogether — a bare letter cannot be
delayed waiting to see whether you are holding it.

### Conditions

`when` is a callback, and it receives a context that can look at any pane, not just the focused
one:

```lua
when = function(ctx)
  local p = ctx.pane(0)                 -- 0 or nil: the focused pane
  return p and p.focus_split and not p.alt_screen
end
```

| | |
|---|---|
| `ctx.pane(0)` / `ctx.pane("focused")` | the focused pane |
| `ctx.pane(n)` | by index into `ctx.panes`, 1-based |
| `ctx.pane("<uuid>")` | by uuid |
| `ctx.pane("last")` | the previously focused pane |
| `ctx.pane("tab:2/focus")` | the focused pane of tab 2 |
| `ctx.cache.get/set/del` | memoise anything expensive, with a TTL |

Useful pane fields: `focus_split`, `focus_float`, `float_key`, `process_name`, `process_running`,
`alt_screen`, `tab_count`, `active_tab`. Callbacks are evaluated on the input path, so they are
cached briefly, and `HEXE_LUA_TRACE=slow` with `HEXE_LUA_TRACE_SLOW_MS` will tell you which one is
costing you.

### Events

Bindings react to keys; `hexe.events` reacts to the session:

```lua
hexe.events.on("command_finished", function(ev)
  -- ev.command, ev.cwd, ev.status, ev.duration_ms, ev.jobs, ev.pane_uuid
end)

hexe.events.on("statusbar_redraw", hexe.events.debounce(250, function(ev) … end))
hexe.events.once("pane_focus_changed", function(ev) … end)
```

Available: `pane_focus_changed`, `tab_changed`, `command_finished`,
`pane_shell_running_changed`, `statusbar_redraw` (throttled, 120 ms by default).

### Getting the chord to hexe at all

Hexe asks for the kitty keyboard protocol on startup. Where the terminal supports it, modifiers
arrive intact on every key, including the ones legacy encodings cannot express. Where it does not,
hexe falls back to the traditional encodings, and the fallback is lossy in the ways it has always
been: `Ctrl+Alt+letter` becomes `ESC` plus a control character, `Alt+digit` becomes `ESC` plus the
digit, and chords like `Ctrl+.` cannot be represented at all.

Passthrough runs the same translation in reverse when writing to a pane: arrows with modifiers
become `ESC [ 1 ; <mod> A`, `Ctrl+letter` becomes a control character, `Alt+key` gains an `ESC`
prefix, `Shift+Tab` becomes `ESC [ Z`.

## What makes it different

- **No prefix.** tmux routes every binding through `C-b`; hexe routes through the bind list and a
  condition. The cost is that hexe occupies real chords, so a binding can collide with an
  application's — and `when` plus ordering is the answer to that.
- **Conditions are code, not a mode.** `when` is a Lua function with access to the pane's
  foreground process, alt-screen state, tab and float identity. There is no equivalent to consult
  in tmux's key tables.
- **A key can do both things.** `act_and_passthrough` has no analogue in a prefix design, where the
  prefix has already swallowed the key by the time the binding runs.
- **Mouse-aware panes keep their mouse.** Applications that enable SGR mouse tracking (1006) get
  their events; hold the selection-override chord (Ctrl+Alt by default) to select text over the top
  of one anyway.

## Configuration

Keys and modifiers are spelled with `hexe.key.*`:

```lua
key = { hexe.key.ctrl, hexe.key.alt, hexe.key.q }
key = { hexe.key.alt, hexe.key["1"] }        -- digits are string keys
key = { hexe.key.ctrl, hexe.key.alt, hexe.key.left }
key = { hexe.key.alt, hexe.key.shift, hexe.key.up }
```

Modifiers: `ctrl`, `alt`, `shift`, `super`. Keys: `a`–`z`, `["0"]`–`["9"]`, `up`/`down`/`left`/
`right`, `dot`, `comma`, `space`, and the rest of the punctuation names.

The full action set, as of this build:

| | |
|---|---|
| session | `quit`, `detach` |
| panes | `pane.close`, `pane.select`, `pane.zoom`, `pane.sync_toggle`, `pane.disown`, `pane.adopt` |
| splits | `split.horizontal`, `split.vertical`, `split.resize(dir)` |
| tabs | `tab.new`, `tab.next`, `tab.prev`, `tab.close`, `tab.rename` |
| floats | `float.toggle(key)`, `float.nudge(dir)` |
| focus | `focus.move(dir)` |
| layout | `layout.save`, `layout.load` |
| config | `config.reload` |
| reading | `copy.enter`, `search.enter`, `prompt.previous`, `prompt.next`, `prompt.copy_output` |
| clipboard | `clipboard.copy`, `clipboard.request` |
| overlays | `overlay.sprite_toggle`, `overlay.keycast_toggle` |
| system | `system.notify` |

Two thresholds and one mouse setting round it out:

```lua
mux = {
  mouse = { selection_override = { "ctrl", "alt" } },
  confirm = { exit = true, detach = true, disown = true, close = true },
},
```

## What it cannot do

- **A chord hexe takes is a chord the pane never sees**, unless the bind says otherwise. There is
  no prefix to hide behind, so collisions are real and are resolved by you.
- **Legacy terminals cannot deliver every chord.** Without the kitty protocol, `Ctrl+Alt+1`,
  `Ctrl+.` and friends do not arrive; that is the terminal, not hexe.
- **`when` runs on the input path.** An expensive callback is felt as input latency — cache it.
- **Bindings are global to the frontend.** There are no per-pane key tables, and no modes beyond
  the modal surfaces (search, copy-mode, rename, popups) that take keys while they are up.
- **`hexe.key(...)` is the only accepted spelling.** Raw bind tables from older configs are
  rejected rather than migrated.

## Where it lives

| | |
|---|---|
| `src/core/config.zig` | `Bind`, `BindAction`, `BindWhen`, `BindMode`, and the action-name parser |
| `src/frontends/terminal/keybinds.zig` | matching: chord, timing, condition, order |
| `src/frontends/terminal/keybinds_actions.zig` | what each action does |
| `src/frontends/terminal/key_translate.zig` | writing keys back out to a pane |
| `src/frontends/terminal/input.zig`, `loop_input*.zig` | the input path and the modal surfaces |
| `src/frontends/terminal/lua_events.zig` | `hexe.events` |
| `src/core/lua_runtime.zig` | the `hexe.action.*` constructors |

## Reference: conditions and events

### The `when` callback

Optional condition that must be true for the bind to fire.

`when` is callback-only:

```lua
when = function(ctx)
  return ctx.focus_split and ctx.process_name == "nvim"
end
```

`ctx` exposes the current focused pane state.

Pane lookup:
- `ctx.pane(0)` (or `ctx.pane(nil)`) → current focused pane
- `ctx.pane(<number>)` → pane by runtime index in `ctx.panes` (1-based)
- `ctx.pane(<uuid_string>)` → pane by UUID
- `ctx.pane("focused")` / `ctx.pane("current")` → current focused pane
- `ctx.pane("last")` → previously focused pane (if available)
- `ctx.pane("tab:<n>/focus")` → focused split pane for tab `n` (1-based)
- `ctx.cache.get(key)` / `ctx.cache.set(key, value, ttl_ms)` / `ctx.cache.del(key)` for callback caching

```lua
local p = ctx.pane(0)
if p and p.focus_float then
  return true
end
return false
```

Prefer `ctx.pane(0)` (or `hexe.ctx.pane(0)` when outside callback-local `ctx`).

Common pane fields:

| Field | Meaning |
|---|---|
| `focus_split` | Focused pane is a split |
| `focus_float` | Focused pane is a float |
| `process_name` | Foreground process name (for example `nvim`) |
| `process_running` | Whether a foreground process is present |
| `alt_screen` | Terminal is in alt-screen mode |
| `tab_count` | Number of open tabs |
| `active_tab` | Active tab index |
| `float_key` | Float key for focused float pane |

### Lua Trace

- Set `HEXE_LUA_TRACE=1` to trace all callback evaluations.
- Set `HEXE_LUA_TRACE=slow` to trace only slow evaluations.
- Optional threshold: `HEXE_LUA_TRACE_SLOW_MS` (default `8`).

### Lua Events

You can register runtime event callbacks through `hexe.events`.

Supported events:
- `pane_focus_changed`
- `tab_changed`
- `command_finished`
- `pane_shell_running_changed`
- `statusbar_redraw` (throttled, default 120ms)

Use the canonical helper API (`hexe.events.*`):

```lua
hexe.events.on("command_finished", function(ev)
  -- ev.command, ev.cwd, ev.status, ev.duration_ms, ev.jobs, ev.pane_uuid
end)

hexe.events.on("pane_shell_running_changed", function(ev)
  -- ev.pane_uuid, ev.previous_running, ev.running, ev.phase, ev.command, ev.now_ms
end)

hexe.events.on("statusbar_redraw", function(ev)
  -- ev.now_ms, ev.term_width, ev.term_height, ev.active_tab, ev.tab_count, ev.interval_ms
end)

-- debounce helper (returns wrapped handler)
hexe.events.on("statusbar_redraw", hexe.events.debounce(250, function(ev)
  -- runs at most every 250ms
end))

-- convenience helper
hexe.events.once("pane_focus_changed", function(ev)
  -- runs only once
end)
```

---
