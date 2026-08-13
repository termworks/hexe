# Configuration

One Lua file, one entry point, and a validator that will tell you before you start anything. The
config describes six things — theme, keys, frontend behaviour, status bar, prompt, popups — plus
the layouts a session starts with, and every one of them is a table passed to `hexe.setup`.

```lua
local hexe = require("hexe")

return hexe.setup({
  theme  = hexe.theme({ styles = { ["git.branch"] = "bg:5 fg:0" } }),
  keys   = { hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.q }, hexe.action.quit()) },
  mux    = { confirm = { exit = true, detach = true } },
  status = { left = {}, center = {}, right = {} },
  prompt = { left = {}, right = {} },
  pop    = { notify = {} },
  ses    = { layouts = { dofile(os.getenv("HOME") .. "/.config/hexe/layout.lua") } },
})
```

```sh
hexe config check     # validate and summarise
hexe config paths     # where hexe looks
hexe config dump      # the normalised result
```

<!-- demo:begin -->
[![config demo](https://asciinema.org/a/1262978.svg)](https://asciinema.org/a/1262978)
<!-- demo:end -->

## How it works

```
~/.config/hexe/init.lua      ── the config
        │  (hexe.setup)
        ▼
   config builder             each section validated as it is set;
        │                     an unknown top-level section is an ERROR
        ▼
   normalised config ──> frontend · status bar · prompt · SES layouts
        ▲
./.hexe.lua ────────────┘     project overlay, run with capabilities revoked
```

`hexe.setup` is not a convention, it is the schema. Sections are validated as they are read, raw
segment tables are refused in favour of `hexe.segment(...)`, legacy layout spellings are refused
rather than migrated, and an unknown top-level key is an error rather than a silently ignored
typo — which is the difference between a config that does not do what you meant and one that says
so.

### Reloading

`hexe.action.config.reload()` re-reads the file and hot-swaps it into the running frontend: new
keys, new segments, new theme, without losing a single pane. A config that fails to parse is
reported and the running one is kept.

### The Lua runtime

The config runs in a real Lua interpreter, and by default an unrestricted one: `io`, `os`,
`package`, `dofile` and `hexe.exec` are all there, which is why a config can read
`/etc/os-release`, `dofile` a second file, or shell out for a git branch.

Setting `HEXE_UNRESTRICTED_CONFIG` to anything other than `1` revokes that: `io`, `package`,
`dofile`, `loadfile`, `load`, `debug` and `hexe.exec` are removed, `os` keeps only `time`, `date`,
`clock` and `difftime`, and `require` accepts nothing but `"hexe"`. The same revocation is applied
unconditionally to a project-local `.hexe.lua`, whatever your setting — a file that arrives with a
git clone does not get your capabilities.

Note what that does *not* stop: a layout's `command =` strings and `on_start`/`on_stop` hooks are
shell commands by definition. Those are gated separately, by the trust ledger — see
[project sessions](session-manager.md).

### Shelling out, when you must

```lua
local r = hexe.exec("git branch --show-current", { timeout_ms = 80, cache_ms = 1000 })
-- r.ok, r.code, r.stdout, r.stderr, r.timeout, r.cached, r.elapsed_ms
```

The timeout and the cache are the interesting fields: a prompt runs this on every command, and a
status segment several times a second.

### Where it looks

```
config_dir:  $XDG_CONFIG_HOME/hexe            (or ~/.config/hexe)
config_file: $XDG_CONFIG_HOME/hexe/init.lua
modules:     $XDG_CONFIG_HOME/hexe/lua/?.lua
             $XDG_CONFIG_HOME/hexe/lua/?/init.lua
             ./.hexe/lua/?.lua
             ./.hexe/lua/?/init.lua
```

## What makes it different

tmux configures with `set-option` commands in its own language; zellij with KDL; wezterm — the
closest relative — with Lua.

- **One language for everything.** Keys, prompt, status bar, layouts and popup styling are the same
  Lua, so a helper you write for one is usable in the others. The shipped config defines
  `git_branch(opts)` once and uses it in both the prompt and the bar.
- **The prompt is in it.** No separate starship configuration to keep in sync.
- **Errors are refusals.** Unknown sections, raw segment tables and old spellings are rejected with
  a message rather than ignored.
- **Reload is in-place**, not a restart, and not a re-source of a command language that has already
  half-applied itself.

## Configuration

The sections `hexe.setup` accepts:

| | |
|---|---|
| `theme` | `hexe.theme({ colors = …, styles = …, chars = … })`; `hexe.style("name")` resolves one |
| `keys` | a list of `hexe.key(...)` — see [keybindings](keybindings.md) |
| `mux` | frontend behaviour: `confirm`, `mouse`, `floats`, `splits`, `selection_color` |
| `status` | `left` / `center` / `right` lists — see [the status bar](statusbar.md) |
| `prompt` | `left` / `right` lists — see [the shell prompt](prompt.md) |
| `pop` | notification, confirm and chooser styling, and the overlay widgets |
| `ses` | `layouts`, the shape a session starts with — see [sessions](sessions.md) |

Themes are named styles, and a style is a string:

```lua
theme = hexe.theme({
  colors = { bg = 237, fg = 250, accent = 1 },
  styles = { ["status.directory"] = "bg:237 fg:15", ["git.branch"] = "bg:5 fg:0" },
  chars  = { split_vertical = "│", split_horizontal = "─" },
}),
```

Tooling:

| | |
|---|---|
| `hexe config check` | validate, and print what was loaded |
| `hexe config validate` | validate only |
| `hexe config dump` | the normalised configuration |
| `hexe config paths` | config dir, config file, module search paths |
| `HEXE_LUA_TRACE=1` / `=slow` | trace callback evaluation; `HEXE_LUA_TRACE_SLOW_MS` sets the threshold (8 ms) |
| `HEXE_UNRESTRICTED_CONFIG` | anything but `1` revokes filesystem, environment and shell access |
| `HEXE_SKIP_LOCAL_CONFIG=1` | do not read `./.hexe.lua` at all |

## What it cannot do

- **There is no configuration DSL for layouts beyond the constructors.** `hexe.layout`,
  `hexe.tab`, `hexe.split`, `hexe.pane`, `hexe.float` — and old field names are errors.
- **A config error at startup is a config error.** The frontend starts with defaults and tells you;
  it does not guess what you meant.
- **Reload does not restructure a running session.** New layouts apply to new sessions; the panes
  you have keep their shape.
- **The sandbox does not sandbox commands.** Revoking Lua capabilities does not make a
  `command = "curl … | sh"` in a layout safe; that is what the trust ledger is for.
- **No per-pane configuration.** Config is per frontend, plus the project overlay.
- **No JSON, TOML or YAML.** Config is Lua, and a project config is Lua too.

## Where it lives

| | |
|---|---|
| `src/core/lua_runtime.zig` | the interpreter, the sandbox, `require("hexe")`, the `hexe.*` bootstrap |
| `src/core/config.zig`, `config_v2.zig`, `config_builder.zig` | the schema, the builder, the validators |
| `src/core/api_bridge*.zig` | Lua ↔ Zig for floats, layouts, recording, segments |
| `src/core/lua_api_exec.zig`, `cmd.zig`, `async_cmd.zig` | `hexe.exec` and its cache |
| `src/core/style.zig` | the style string language |
| `src/cli/commands/config_validate.zig` | `config check` / `validate` |
| `src/frontends/terminal/keybinds_actions.zig` | `performConfigReload` |
| `config/init.lua`, `config/layout.lua` | the author's own config, which is the repo's live example |
| `docs/config.md` | the reference page |
