# Configuration

Hexe config is Lua. The canonical entrypoint is:

```lua
local hexe = require("hexe")

return hexe.setup({
  theme = hexe.theme({
    styles = {
      ["git.branch"] = "bg:1 fg:0",
    },
  }),

  keys = {
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.q }, hexe.action.quit()),
  },

  mux = {
    confirm = { exit = true, detach = true },
  },

  ses = {
    layouts = {
      dofile(os.getenv("HOME") .. "/.config/hexe/layout.lua"),
    },
  },
})
```

The repo `config/` directory is linked to `~/.config/hexe`, so the live config
is intentionally just two files:

- `config/init.lua` for settings
- `config/layout.lua` for the global layout

Project config can provide its own `.hexe.lua` layout with the same layout
constructors.

## Module Paths

Hexe loads modules from:

- `~/.config/hexe/lua/?.lua`
- `~/.config/hexe/lua/?/init.lua`
- `./.hexe/lua/?.lua`
- `./.hexe/lua/?/init.lua`

Use `hexe config paths` to print the effective paths.

## Sections

Top-level sections accepted by `hexe.setup`:

- `theme = hexe.theme({...})`
- `keys = { hexe.key(...), ... }`
- `mux = { ... }`
- `status = { left = { hexe.segment(...) }, center = {...}, right = {...} }`
- `prompt = { left = { hexe.segment(...) }, right = {...} }`
- `pop = { ... }`
- `ses = { layouts = { hexe.layout(...) } }`

Unknown top-level sections are errors.

## Layouts

Layouts use constructors:

```lua
local hexe = require("hexe")

return hexe.layout("default", {
  root = ".",
  tabs = {
    hexe.tab("main", {
      root = hexe.split("horizontal", {
        hexe.pane({ cwd = "." }),
        hexe.pane({ command = "nvim" }),
      }),
    }),
  },
  floats = {
    hexe.float("codex", {
      key = "3",
      title = "codex",
      command = "codex",
      attrs = { per_cwd = true, inherit_env = true },
    }),
  },
})
```

Use `root`, `command`, `attrs`, `size`, and `position`. Removed legacy schema
names are rejected.

## Segments

Prompt and statusbar segment lists use the same wrapper:

```lua
hexe.segment({
  name = "directory",
  priority = 50,
  render = function(ctx)
    return {
      { text = ctx.cwd or "", style = "status.directory" },
    }
  end,
})
```

Raw segment tables are rejected; wrap each segment with `hexe.segment(...)`.

## Theme Styles

Theme styles are named strings:

```lua
return hexe.theme({
  styles = {
    ["git.branch"] = "bg:1 fg:0",
  },
})
```

Use `hexe.style("git.branch")` inside segment callbacks or builtin options to
resolve the current theme value. Missing names return the input unchanged.

## Exec

Use the callable exec API:

```lua
local r = hexe.exec("git branch --show-current", {
  timeout_ms = 80,
  cache_ms = 1000,
})

if r.ok then
  return r.stdout
end
```

The result includes `ok`, `code`, `stdout`, `stderr`, `timeout`, `cached`, and
`elapsed_ms`.

## Tooling

- `hexe config check`
- `hexe config dump`
- `hexe config paths`

Build/test gates:

```sh
make test
make build
```

## Security: project config trust

Hexe auto-loads a `./.hexe.lua` from the current directory. The general config
is parsed in a sandboxed Lua runtime (no `io`/`os`/`package`), so pure config
cannot shell out. However, a session config can define pane/float `command=`
strings and `on_start` / `on_stop` hooks that **are** executed as shell
commands. Opening a session from a directory that ships a malicious `.hexe.lua`
therefore runs its commands — the same auto-trust exposure as `direnv`.

Controls:

- `HEXE_SKIP_LOCAL_CONFIG=1` — do not load `./.hexe.lua` at all.
- `HEXE_NO_PROJECT_COMMANDS=1` — load the layout but skip project-sourced
  `on_start` / `on_stop` command execution.

A per-directory trust ledger (approve a config's hash once, prompt on change)
is the intended long-term fix.
