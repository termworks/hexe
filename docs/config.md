# Configuration

Hexe is configured in Lua.

---

## File locations

Hexe reads config from (in order):

1. `$XDG_CONFIG_HOME/hexe/init.lua`
2. `~/.config/hexe/init.lua` (default if XDG not set)
3. `./.hexe.lua` (optional local override in current directory, or session config — see [session_manager](session_manager.md))

State is stored under:

- `~/.local/state/hexe/` (or `$XDG_STATE_HOME/hexe/`)

---

## Basic structure

```lua
local hx = require("hexe")

-- session layouts (tabs, splits, floats)
hx.ses.layout.define({ ... })

-- mux config (tabs, status bar, floats, keybinds, etc.)
hx.mux.config.setup({ ... })

-- prompt segments
hx.shp.prompt.left({ ... })
hx.shp.prompt.right({ ... })
```

---

## Mux config reference

```lua
hx.mux.config.setup({
  -- Confirmation dialogs
  confirm_on_exit   = false,
  confirm_on_detach = false,
  confirm_on_disown = false,
  confirm_on_close  = false,

  -- Selection
  selection_color          = 240,  -- palette index
  selection_override_mods  = { hx.mod.alt, hx.mod.ctrl },

  -- Splits
  splits = {
    color = { active = 1, passive = 237 },
    style = {
      vertical   = "│",
      horizontal = "─",
      cross      = "┼",
      top_t      = "┬",
      bottom_t   = "┴",
      left_t     = "├",
      right_t    = "┤",
    },
  },

  -- Tabs
  tabs = {
    key_new    = "t",
    key_next   = "n",
    key_prev   = "p",
    key_close  = "x",
    key_detach = "d",
    status = {
      enabled = true,
      left    = { ... },  -- segment arrays
      center  = { ... },
      right   = { ... },
    },
  },

  -- Notifications
  notifications = {
    mux  = { fg = 0, bg = 3, bold = true, padding_x = 1, padding_y = 0,
              offset = 1, alignment = "center", duration_ms = 3000 },
    pane = { fg = 0, bg = 3, bold = true, padding_x = 1, padding_y = 0,
              offset = 1, alignment = "center", duration_ms = 3000 },
  },

  -- Input
  input = {
    timing = {
      tap_ms  = 200,
      hold_ms = 600,
    },
    binds = { ... },  -- see keybindings.md
  },
})
```

---

Float visuals are configured through the Lua API, not inside `layout.lua`:

```lua
hx.mux.float.set_defaults({
  size = { width = 60, height = 60 },
  color = { active = 1, passive = 237 },
  attributes = { sticky = true, global = true },
})

hx.mux.float.set_adhoc({
  size = { width = 80, height = 70 },
  color = { active = 4, passive = 237 },
})

hx.mux.float.set_match("^explorer$", {
  padding = { x = 2, y = 1 },
  style = {
    shadow = { color = 236 },
  },
})
```

`set_match(...)` uses the float title with full libc regex matching.

---

## Session layout reference

```lua
hx.ses.layout.define({
  name    = "default",
  enabled = true,

  tabs = {
    {
      name    = "main",
      enabled = true,
      root    = {
        -- single pane:
        cwd     = "~/projects",
        command = nil,           -- nil = default shell

        -- OR a split:
        dir    = "h",            -- "h" or "v"
        ratio  = 0.65,           -- 0.0 – 1.0
        first  = { cwd = "~" },
        second = { cwd = "~" },
      },
    },
  },

  floats = {
    {
      key            = "g",
      enabled        = true,
      command        = "lazygit",
      title          = "git",
      size           = { width = 90, height = 90 },
      position       = { x = 50, y = 50 },
      attributes     = {
        per_cwd   = true,
        sticky    = true,
        global    = true,
        exclusive = false,
        destroy   = false,
        isolated  = false,
      },
      isolation = {
        profile = "sandbox",
        memory  = "512M",
        cpu     = "50000 100000",
        pids    = 100,
      },
    },
  },
})
```

---

## Shell prompt reference

```lua
hx.shp.prompt.left({ ... })
hx.shp.prompt.right({ ... })
```

Prompt and statusbar use a Lua-first callback model. Segment kind is inferred from fields:

- `value` (callback)
- `builtin` (callback descriptor)
- `button` (click actions)
- `progress` (cadence + visibility)

`when` is callback-only everywhere:

- `when = function(ctx) ... end`

Legacy forms (for example string chunks, token tables, `when = { lua = ... }`, `bash`, `env`) are not supported.

Quick examples:

```lua
value = function(ctx)
  local p = ctx.pane(0)
  if p and p.process_running then
    return "RUN"
  end
  return nil
end

builtin = function(_)
  return {
    name = "directory",
    style = "bg:237 fg:15",
    prefix = { output = " ", style = "bg:0 fg:8" },
    suffix = { output = " ", style = "bg:0 fg:8" },
  }
end

when = function(ctx)
  local p = ctx.pane("focused")
  return p and p.focus_split
end

local r = hx.exec.run("git rev-parse --abbrev-ref HEAD", { timeout = 80, cache = 500 })
if r.status == 0 and r.output ~= "" then
  -- r.output, r.cached, r.timeout, r.elapsed_ms
end
```

`hx.exec.run(cmd, opts?)` runs a shell command (`/bin/bash -lc`) and returns:

- `output` (stdout fallback to stderr)
- `status` (exit code)
- `cached` (whether value came from cache)
- `timeout` (`true` if timeout was hit)
- `elapsed_ms` (execution time)

Options:

- `timeout` / `timeout_ms` (default `80`)
- `cache` / `cache_ms` (default `500`)

Option values must be numbers (invalid types raise a Lua config/runtime error).

Scope rules:

- Prompt supports `value` and an allowlisted subset of `builtin` segments.
- Prompt does not accept `button` or `progress` segments.
- Statusbar accepts full segment kinds (`value`, `builtin`, `button`, `progress`) and full statusbar builtins.

See `docs/prompt.md` and `docs/statusbar.md` for the full schema and examples.

---

## Environment variables

| Variable | Description |
|---|---|
| `HEXE_INSTANCE` | Named instance (see [instances](instances.md)) |
| `HEXE_TEST_ONLY` | Set by `--test-only`; signals test isolation |
| `HEXE_LUA_TRACE` | Lua callback trace mode: `1`/`all` or `slow` |
| `HEXE_LUA_TRACE_SLOW_MS` | Slow-trace threshold (ms, default `8`) |
| `HEXE_STATUSBAR_REDRAW_EVENT_MS` | Throttle interval for `statusbar_redraw` event (ms, default `120`) |

---

## Validate config

```sh
hexe cfg validate
```

Parses and validates your config without starting any daemon.
