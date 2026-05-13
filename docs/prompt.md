# Shell Prompt (`shp`) Infrastructure

This document covers how Hexe prompt rendering works end-to-end, including Lua execution, conditions, config layering, and module behavior.

## Quick Start

Enable prompt hooks in your shell:

```sh
# bash
eval "$(hexe shp init bash)"

# zsh
eval "$(hexe shp init zsh)"

# fish
hexe shp init fish | source
```

Define segments in `~/.config/hexe/init.lua`:

```lua
local hexe = require("hexe")

return hexe.setup({
  prompt = {
    left = {
      hexe.segment({
        name = "ssh",
        priority = 50,
        render = function(ctx)
          if not ctx.env.SSH_CONNECTION then
            return nil
          end
          return { { text = " //", style = "bg:237 fg:15" } }
        end,
      }),
    },
  },
})
```

## Config Sources and Precedence

Prompt loading order:

1. Global config: `~/.config/hexe/init.lua`
2. Optional local override: `./.hexe.lua`

For SHP, local `./.hexe.lua` can override prompt arrays with the same canonical setup form:

```lua
local hexe = require("hexe")

return hexe.setup({
  prompt = {
    left = { ... },
    right = { ... },
  },
})
```

## Segment Model (Lua-first)

Each prompt side is an array of segment definitions.

```lua
{
  name     = "directory",       -- built-in segment name
  priority = 50,                 -- lower = kept longer when width is tight

  -- render segment
  render = function(ctx)
    return { { text = " hello ", style = "bg:1 fg:0" } }
  end,

  -- or builtin segment descriptor
  builtin = function(ctx)
    return {
      name = "directory",
      style = "bg:237 fg:15",
      prefix = { output = " ", style = "bg:0 fg:8" },
      suffix = { output = " ", style = "bg:0 fg:8" },
    }
  end,
}
```

Notes:

- Kind is inferred from fields (`render`, `builtin`, `button`, `progress`); no `kind` field is required.
- `outputs` is not used in the Lua-first prompt model.
- Affix object form is supported: `prefix = { output = "...", style = "..." }`, `suffix = { output = "...", style = "..." }`.

## Prompt Restrictions

Prompt intentionally supports a limited segment subset:

- Allowed kinds: `render`, `builtin`
- Not allowed in prompt: `button`, `progress`

Builtin allowlist for prompt:

- `directory`
- `git_branch`
- `git_status`
- `status`
- `sudo`
- `jobs`
- `duration`
- `pod_name`
- `hostname`
- `username`
- `character`

Examples of builtins not allowed in prompt: `spinner`, `randomdo`, `running_anim`.

## Output Execution Paths

### `render = ...` (in-process)

`render` runs inside Hexe and must return a value.

Return behavior:

- `string` -> used as output
- `number` -> converted to text
- `boolean true` -> rendered as `"true"`
- `nil` / `false` / other types -> treated as empty (segment hidden)

### `builtin = ...` (descriptor)

`builtin` returns a descriptor table:

- `name` (required): builtin segment name (for example `git_branch`, `git_status`, `directory`)
- `style`: descriptor style override
- `prefix` / `suffix`: wrapper text around builtin output
  - string form: `prefix = " "`
  - object form: `prefix = { output = " ", style = "bg:0 fg:8" }`
  - same schema for `suffix`

You can build descriptors with helpers:

```lua
builtin = function(_)
  return hexe.segment.builtin.directory({
    style = "bg:237 fg:15",
    suffix = " ",
  })
end
```

Style behavior:

- If descriptor `style` is provided, it is authoritative for rendered builtin text.
- This is useful when you want fixed colors (for example black-on-red git segments).

## Conditions (`when`)

The Lua-first prompt model usually encodes visibility directly in `render`/`builtin` callbacks (return `nil` to hide). `when` is callback-only.

Prompt condition form:

```lua
when = function(ctx)
  return (ctx.exit_status or 0) ~= 0
end
```

Legacy forms like `when = { lua = ... }`, token tables, and bash/env conditions are no longer supported in prompt.

## Lua Context (`ctx`)

Prompt Lua callbacks (`render`, `builtin`, and `when`) receive `ctx`:

- `ctx.cwd`
- `ctx.home`
- `ctx.exit_status`
- `ctx.cmd_duration_ms`
- `ctx.jobs`
- `ctx.terminal_width`
- `ctx.now_ms`
- `ctx.env` (environment map: `ctx.env.NAME`)
- `ctx.pane(0)` / `ctx.pane(nil)` (returns current prompt context table)
- `ctx.pane(1)` and `ctx.pane("focused")` / `ctx.pane("current")` also return current prompt context table
- prompt mode has no cross-pane lookup (`ctx.pane(<other>)` returns `nil`)
- `ctx.cache.get(key)` / `ctx.cache.set(key, value, ttl_ms)` / `ctx.cache.del(key)` for callback-local caching

Example:

```lua
render = function(ctx)
  if (ctx.exit_status or 0) ~= 0 then
    return "ERR"
  end
  return nil
end
```

## Lua Safety Modes

Hexe Lua runtime has two modes:

- Safe mode (default): no `io`, no `os`, restricted `require`
- Unsafe mode: enable with `HEXE_UNRESTRICTED_CONFIG=1`

Unsafe mode enables `io`, `os`, and package loading from config paths.

### `require()` behavior

Safe mode:

- only `require("hexe")` is allowed

Unsafe mode package search paths:

- `${XDG_CONFIG_HOME}/hexe/lua/?.lua`
- `${XDG_CONFIG_HOME}/hexe/lua/?/init.lua`
- `./.hexe/lua/?.lua`
- `./.hexe/lua/?/init.lua`

If `XDG_CONFIG_HOME` is unset, `~/.config/hexe` is used.

Native C modules are disabled (`package.cpath = ""`).

### Lua Trace

- Set `HEXE_LUA_TRACE=1` to trace all callback evaluations.
- Set `HEXE_LUA_TRACE=slow` to trace only slow evaluations.
- Optional threshold: `HEXE_LUA_TRACE_SLOW_MS` (default `8`).

## Width and Priority Behavior

Prompt rendering uses width budgeting per side:

- left prompt budget: half terminal width
- right prompt budget: half terminal width

If segments exceed budget, higher priority numbers are hidden first. Lower numbers stay visible longer.

## Built-in Prompt Segments

Prompt builtin allowlist:

- `directory`
- `git_branch`
- `git_status`
- `status`
- `sudo`
- `jobs`
- `duration`
- `pod_name`
- `hostname`
- `username`
- `character`

## Practical Patterns

Pure Lua segment:

```lua
{
  name = "virt",
  priority = 40,
  render = function(_)
    local p = io.popen("systemd-detect-virt 2>/dev/null")
    if not p then return nil end
    local v = (p:read("*a") or ""):match("^%s*(.-)%s*$")
    p:close()
    if v == "" or v == "none" then return nil end
    if v == "lxc" then
      return { { text = " >> ", style = "bg:5 fg:0" } }
    end
    return { { text = " :: ", style = "bg:5 fg:0" } }
  end,
}
```

Builtin descriptor segment:

```lua
{
  name = "git_status",
  priority = 5,
  builtin = function(_)
    return { name = "git_status", style = "bg:1 fg:0", suffix = " " }
  end,
}
```

## Troubleshooting

- Lua segment not rendering:
  - check return value (must resolve to supported output type)
  - check for runtime errors in config
- if using `io`/`os`, ensure `HEXE_UNRESTRICTED_CONFIG=1`
- `require("my_module")` fails:
  - verify module exists under `~/.config/hexe/lua/...`
  - verify unsafe mode is enabled
- Segment disappears unexpectedly:
  - check `priority` and terminal width budget
  - check `when` conditions
