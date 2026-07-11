# Keybindings

Keybindings are defined in the top-level `keys` array passed to `hexe.setup`.

---

## Basic structure

```lua
local hexe = require("hexe")

return hexe.setup({
  keys = {
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.q }, hexe.action.quit()),
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.t }, hexe.action.tab.new()),
  },
})
```

---

## `key`

The `key` field is a single array containing modifiers and the key, all using `hexe.key.*`:

```lua
key = { hexe.key.ctrl, hexe.key.alt, hexe.key.q }
key = { hexe.key.ctrl, hexe.key.alt, hexe.key.shift, hexe.key.p }
key = { hexe.key.ctrl, hexe.key.alt, hexe.key.up }
key = { hexe.key.ctrl, hexe.key.alt, hexe.key["1"] }   -- number keys
key = { hexe.key.ctrl, hexe.key.alt, hexe.key.dot }
key = { hexe.key.ctrl, hexe.key.alt, hexe.key.comma }
```

**Modifiers:**
- `hexe.key.ctrl`
- `hexe.key.alt`
- `hexe.key.shift`
- `hexe.key.super`

**Named keys:**
- Letters: `hexe.key.a` … `hexe.key.z`
- Numbers: `hexe.key["0"]` … `hexe.key["9"]`
- Arrows: `hexe.key.up`, `hexe.key.down`, `hexe.key.left`, `hexe.key.right`
- Punctuation: `hexe.key.dot`, `hexe.key.comma`, `hexe.key.space`, etc.

---

## `action`

Actions trigger terminal frontend operations. Session-structure mutations are applied by SES after command handling. Available action constructors:

| Action | Description |
|---|---|
| `hexe.action.quit()` | Exit the terminal frontend |
| `hexe.action.detach()` | Detach from session |
| `hexe.action.pane.disown()` | Orphan current pane |
| `hexe.action.pane.adopt()` | Adopt an orphaned pane |
| `hexe.action.pane.close()` | Close current float or split pane |
| `hexe.action.pane.select()` | Enter pane select/swap mode |
| `hexe.action.split.horizontal()` | Split horizontally |
| `hexe.action.split.vertical()` | Split vertically |
| `hexe.action.split.resize(dir)` | Resize split |
| `hexe.action.tab.new()` | New tab |
| `hexe.action.tab.next()` | Next tab |
| `hexe.action.tab.prev()` | Previous tab |
| `hexe.action.tab.close()` | Close current tab |
| `hexe.action.float.toggle(key)` | Toggle named float |
| `hexe.action.float.nudge(dir)` | Move float |
| `hexe.action.focus.move(dir)` | Move focus |
| `hexe.action.clipboard.copy()` | Copy selection to clipboard |
| `hexe.action.clipboard.request()` | Paste from clipboard |
| `hexe.action.system.notify()` | Send a system notification |
| `hexe.action.overlay.sprite_toggle()` | Toggle sprite overlay |
| `hexe.action.copy.enter()` | Enter keyboard copy-mode |
| `hexe.action.search.enter()` | Search the focused pane's scrollback (type · `Enter` · `n`/`N` · `Esc`) |

**Actions that take parameters:**

```lua
hexe.key({ ... }, hexe.action.float.toggle("1"))
hexe.key({ ... }, hexe.action.focus.move("left"))
hexe.key({ ... }, hexe.action.split.resize("up"))
hexe.key({ ... }, hexe.action.float.nudge("down"))
```

---

## `mode`

Controls what happens to the key after the bind fires:

| Mode | Description |
|---|---|
| `hexe.mode.act_and_consume` | Run action, swallow the key (default) |
| `hexe.mode.act_and_passthrough` | Run action AND forward key to pane |
| `hexe.mode.passthrough_only` | Forward key to pane, no action |

```lua
-- default: key is consumed
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.t }, hexe.action.tab.new())

-- passthrough: forward to pane, no action
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.up }, nil, {
  mode = hexe.mode.passthrough_only,
  when = function(ctx)
    local p = ctx.pane(0)
    return p and (p.process_name == "nvim" or p.process_name == "vim")
  end,
})

-- both: run action and also send key into pane
hexe.key({ ... }, hexe.action.overlay.sprite_toggle(), { mode = hexe.mode.act_and_passthrough })
```

Keys without any binding always pass through unchanged.

---

## `when`

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

## Lua Events

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

## Common patterns

### Nvim passthrough

Pass `Ctrl+Alt+Arrow` through to nvim/vim, otherwise move focus:

```lua
-- passthrough first (evaluated before the fallback)
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.up },    nil, { when = function(ctx) return ctx.process_name == "nvim" or ctx.process_name == "vim" end, mode = hexe.mode.passthrough_only }),
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.down },  nil, { when = function(ctx) return ctx.process_name == "nvim" or ctx.process_name == "vim" end, mode = hexe.mode.passthrough_only }),
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.left },  nil, { when = function(ctx) return ctx.process_name == "nvim" or ctx.process_name == "vim" end, mode = hexe.mode.passthrough_only }),
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.right }, nil, { when = function(ctx) return ctx.process_name == "nvim" or ctx.process_name == "vim" end, mode = hexe.mode.passthrough_only }),

-- fallback: move frontend focus
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.up },    hexe.action.focus.move("up")),
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.down },  hexe.action.focus.move("down")),
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.left },  hexe.action.focus.move("left")),
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.right }, hexe.action.focus.move("right")),
```

Binds are evaluated in order — first match wins.

### Context-sensitive split/float

```lua
-- split only when a split is focused
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.h }, hexe.action.split.horizontal(), { when = function(ctx) return ctx.focus_split end }),
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.v }, hexe.action.split.vertical(), { when = function(ctx) return ctx.focus_split end }),
```

### Float toggles

```lua
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key["1"] }, hexe.action.float.toggle("1")),
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key["2"] }, hexe.action.float.toggle("2")),
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key["0"] }, hexe.action.float.toggle("p")),
```

The `float` value must match the `key` field of a float defined in your layout.

---

## Terminal support

Hexa enables the kitty keyboard protocol on startup. Terminals that support it send structured key events (including modifiers on arrows, etc.). Terminals that don't fall back to legacy escape sequences — most binds still work.

**Key forwarding for passthrough modes** translates to legacy sequences:
- Arrow keys with mods → `ESC [ 1 ; <mod> A/B/C/D`
- Ctrl+letter → control character (0x01–0x1A)
- Alt+key → ESC prefix
- Shift+Tab → `ESC [ Z`

---

## Conditions in status bar and prompt

`when` is also used in status bar segments and shell prompt segments. See [statusbar](statusbar.md) for the full token list available in those contexts.
