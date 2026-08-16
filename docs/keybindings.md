# Keybindings

There is no prefix key. A binding is a chord, an action, a condition and a disposal rule, and a key
that matches nothing at all reaches the pane unchanged — which is the default state of every key on
your keyboard.

```lua
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.t }, hexe.action.tab.new()),

hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.up }, nil, {
  mode = hexe.mode.passthrough_only,
  when = function()
    local p = ctx.pane()
    return p and (p.process == "nvim" or p.process == "vim")
  end,
}),
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.up }, hexe.action.focus.move("up")),
```

<!-- demo:begin -->
[![keybindings demo](https://asciinema.org/a/1263031.svg)](https://asciinema.org/a/1263031)
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

`when` is a Lua function, evaluated when the key is pressed. It can look at any
pane, not just the focused one:

```lua
when = function()
  local p = ctx.pane()                 -- omitted / 0 / "focused": focused pane
  return p and p.is_split and not p.alt_screen
end
```

| | |
|---|---|
| `ctx.pane()` / `ctx.pane(0)` / `ctx.pane("focused")` | the focused pane |
| `ctx.pane(n)` | by index into `ctx.panes()`, 1-based |
| `ctx.pane("<uuid>")` | by uuid, or a prefix of one |
| `ctx.pane("last")` | the previously focused pane |
| `ctx.pane("tab:2/focus")` | the focused pane of tab 2 |
| `ctx.count("visible_floats")` | how many floats are on screen |
| `ctx.floats{ visible = true }` | those floats, as a list |

There is no fixed vocabulary of conditions to learn or extend — a condition is
whatever Lua you can write over the query API. The full surface is in
[Reference: conditions and events](#the-query-api).

Conditions run on the input path, so keep them cheap: prefer `ctx.count(...)`
to materialising `ctx.panes()`, and memoise with an upvalue if you need to.
`HEXE_LUA_TRACE=slow` with `HEXE_LUA_TRACE_SLOW_MS` reports which callback is
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

Optional condition that must be true for the bind to fire. It is a Lua function,
and it runs at the moment the key is pressed:

```lua
when = function()
  local p = ctx.pane()
  return p and p.is_split and p.process == "nvim"
end
```

There is no condition language. Anything the query API can answer is a
condition, and the answer is computed against live state on every press:

```lua
-- what is running here
when = function() return ctx.pane().process == "nvim" end

-- how many floats are on screen right now
when = function() return ctx.count("visible_floats") == 0 end
when = function() return #ctx.floats{ visible = true } > 2 end

-- anything you can write in Lua
when = function()
  local p = ctx.pane()
  return p and (p.exit_status or 0) ~= 0 and not p.alt_screen
end
```

The callback also receives the API as its argument, so `function(ctx)
... ctx.pane() ... end` is the same thing — `ctx` and `hexe` are one table.

A condition is truthy in the Lua sense: anything but `nil`/`false` fires the
bind. An error inside the callback is caught and treated as false.

### Lua actions

The action can be a function too, so a binding is not limited to the built-in
action list:

```lua
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.b }, function(ctx)
  local p = ctx.pane()
  hexe.exec("notify-send " .. ("%q"):format(p.cwd or "?"))
end),
```

It receives the same query API as a condition, and runs on the input path with
the same rules — keep it quick, and use `hexe.exec` (asynchronous) rather than
blocking work. An error inside the callback is caught and logged; the key still
counts as handled.

### The query API

Available as the callback's argument (`ctx`) and, outside a callback, as
`hexe.live` — in keybinding conditions, keybinding actions, and event handlers
alike. It is a namespace of its own because the config API already owns
`hexe.pane`, `hexe.float`, `hexe.split` and `hexe.tab` as *constructors* —
`hexe.pane{...}` builds a layout pane, `ctx.pane()` reads a running one.

Every accessor reads live state; nothing is computed until you ask for it.

| Call | Returns |
|---|---|
| `ctx.pane([sel])` | one pane, or nil |
| `ctx.panes([filter])` | array of panes |
| `ctx.floats([filter])` | array of float panes |
| `ctx.splits([filter])` | array of tiled panes |
| `ctx.tabs()` | array of `{index, name, active, pane_count, focused_uuid}` |
| `ctx.session()` | `{name, uuid, root, connected, tab_count, active_tab}` |
| `ctx.ui()` | `{width, height, status_height, zoomed, sync_input, copy_mode, copy_x, copy_y, copy_selecting, search_mode, search_query, search_matches, tab_rename, pane_select, float_focused}` |
| `ctx.count(what)` | `"tabs"`, `"panes"`, `"splits"`, `"floats"`, `"visible_floats"` |
| `ctx.env(name)` | one environment variable, or nil |
| `ctx.selection()` | the selected text, or nil |
| `ctx.config()` | what the config *declares* — `floats` (key, command, geometry, attributes), `keybind_count`, `status_enabled`, `confirm_on_exit` |

`sel` selects a pane: omitted / `0` / `"focused"` / `"current"` for the focused
one, a number for its index in `ctx.panes()`, or a uuid (a prefix is enough).

`filter` is `{ visible = true }` and/or `{ tab = n }` (1-based).

**Pane fields**

| Group | Fields |
|---|---|
| identity | `uuid` `id` `pane_id` `index` `name` `tab` `focused` |
| kind | `is_float` `is_split` `adhoc` `title` |
| liveness | `alive` `replaying` |
| geometry | `x` `y` `width` `height` `zoomed` |
| terminal | `alt_screen` `scrolled` `cursor_x` `cursor_y` `cursor_style` `cursor_visible` `sync_input` |
| input modes | `bracketed_paste` `app_cursor` `synchronized_output` `kitty_keyboard` `mouse_tracking` |
| process | `process` `process_pid` `process_running` |
| shell | `cwd` `osc7_cwd` `last_command` `exit_status` `duration_ms` `jobs` `shell_running` `started_at_ms` |
| progress | `progress_state` `progress_pct` |
| float | `float_key` `visible` `sticky` `per_cwd` `global` `exclusive` `isolated` `destroyable` `command` `exit_key` `pwd_dir` |
| float geometry | `width_pct` `height_pct` `pos_x_pct` `pos_y_pct` `pad_x` `pad_y` (nil on splits) |

`alive` and `replaying` matter more than they look: handlers run before dead
panes are reaped, and during a reattach the VT is still being rebuilt from the
pod backlog, so cursor and screen state are transient. The input-mode flags are
what you check before binding over a key an application wants — `app_cursor`
tells you vim owns the arrows, `bracketed_paste` that it wants the paste.

**Cost.** Each accessor builds only what it is asked for, so a predicate reading
one field is one small table. Materialising every pane (`ctx.panes()`) in a
condition that runs on every keystroke is the expensive shape — prefer
`ctx.count(...)` when you only need a number. To memoise, close over an
upvalue; conditions are ordinary closures.

```lua
local memo = {}
local function expensive()
  local key = ctx.session().active_tab
  if memo[key] == nil then memo[key] = compute() end
  return memo[key]
end
```

### Doing things

The query API is symmetric: everything you can look at, you can also act on.

| Call | Effect |
|---|---|
| `ctx.act(spec)` | perform any bind action now — `spec` is what `hexe.action.*` returns, or the string form |
| `ctx.exec(cmd [, opts])` | run a shell command asynchronously |
| `ctx.notify(msg [, ms])` | show a mux notification |
| `ctx.send([sel,] text)` | write to a pane's pty as if typed |
| `ctx.focus(sel)` | focus any pane, switching tab if needed |
| `ctx.close(sel)` | close any pane |
| `ctx.scroll([sel,] lines)` | scroll back (positive), forward (negative), or to bottom (`0`) |
| `ctx.tab_select(n)` | switch to tab n (1-based) |
| `ctx.rename_tab([n,] name)` | set a tab's name directly |

`ctx.act` is the general one: it takes the same value the `hexe.action.*`
constructors already produce, so the whole action set — and anything added to it
later — is reachable without a second list of names.

```lua
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.n }, function(ctx)
  -- close every float that is on screen, then report
  local closed = 0
  for _, f in ipairs(ctx.floats{ visible = true }) do
    ctx.close(f.uuid)
    closed = closed + 1
  end
  if closed == 0 then
    ctx.act(hexe.action.float.toggle(1))
  else
    ctx.notify(("closed %d floats"):format(closed))
  end
end),
```

Mutations are visible to the next call in the same callback — `ctx.act(...)`
followed by `ctx.count("tabs")` sees the new tab.

`ctx.act` refuses to nest more than 8 deep, so an action that dispatches itself
fails rather than taking the stack with it.

### Breaking changes

This release replaces the keybinding condition surface outright. Nothing from
the old context is aliased — a config written against it will fail loudly at
load, or read `nil`, rather than half-working.

Pane fields were renamed to drop redundant prefixes:

| Gone | Now |
|---|---|
| `process_name` | `process` |
| `focus_split` / `focus_float` / `floating` | `is_split` / `is_float` |
| `float_sticky` / `float_per_cwd` / `float_global` | `sticky` / `per_cwd` / `global` |
| `float_exclusive` / `float_isolated` / `float_destroyable` | `exclusive` / `isolated` / `destroyable` |
| `tab_index` (0-based) | `tab` (1-based) |
| `pane_index` | `index` |

Context-level things moved to where they belong:

| Gone | Now |
|---|---|
| `ctx.focus_split`, `ctx.process_name`, `ctx.alt_screen`, … | `ctx.pane().is_split`, `.process`, `.alt_screen` |
| `ctx.tab_count`, `ctx.active_tab` | `ctx.count("tabs")`, `ctx.session().active_tab` (1-based) |
| `ctx.now_ms` | `os.time() * 1000` |
| `ctx.env.FOO` | `ctx.env("FOO")` |
| `ctx.panes` (array) | `ctx.panes()` |
| `ctx.cache.get/set/del` | a `local memo = {}` upvalue — conditions are closures |

The token forms are gone and are now rejected at load with `InvalidKeyBinding`
rather than silently ignored:

```lua
when = "focus_split"                                  -- gone
when = function(ctx) return ctx.pane().is_split end

when = { all = { "focus_float", "float_sticky" } }    -- gone
when = function(ctx) local p = ctx.pane() return p.is_float and p.sticky end

when = { env = "SSH_TTY" }                            -- gone
when = function(ctx) return ctx.env("SSH_TTY") ~= nil end

when = { bash = "..." }                               -- gone, no replacement
```

`ctx.pane(0)`, `ctx.pane("focused")`, `ctx.pane("last")` and
`ctx.pane("tab:2/focus")` still select the way they always did.

### Lua Trace

- Set `HEXE_LUA_TRACE=1` to trace all callback evaluations.
- Set `HEXE_LUA_TRACE=slow` to trace only slow evaluations.
- Optional threshold: `HEXE_LUA_TRACE_SLOW_MS` (default `8`).

### Lua Events

You can register runtime event callbacks through `hexe.events`.

Supported events:
- `pane_focus_changed`
- `pane_exited` — `ev.pane_uuid`, `ev.exit_status`, `ev.was_focused`, `ev.is_float`, `ev.closes_tab`
- `tab_changed` — `ev.previous_tab`, `ev.active_tab`, `ev.tab_count`
- `tab_created` — `ev.tab`, `ev.tab_count`, `ev.pane_uuid`
- `tab_closed` — `ev.tab`, `ev.tab_count`
- `command_finished`
- `pane_shell_running_changed`
- `statusbar_redraw` (throttled, default 120ms)

Every payload carries `event` and `now_ms`. Handlers get the live API too, so a
handler can query and act:

```lua
hexe.events.on("pane_exited", function(ev)
  if ev.exit_status ~= 0 then
    hexe.live.notify(("pane died: %d"):format(ev.exit_status))
  end
end)
```

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
