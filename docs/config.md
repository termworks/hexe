# Configuration

One Lua file, one entry point, and a validator that will tell you before you start anything. The
config describes five things — theme, keys, frontend behaviour, where the status bar comes from,
popups — plus the layouts a session starts with.

**Assign the settings, register the behaviour, return nothing.** The same style oslo, lule and pixy
use, so one habit covers all of them.

```lua
local hexe = require("hexe")

hexe.theme = hexe.theme({ styles = { ["git.branch"] = "bg:5 fg:0" } })
hexe.mux.confirm = { exit = true, detach = true }
hexe.status.enabled = true
hexe.status.view = "status"

hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.q }, hexe.action.quit())

hexe.layout("work", { tabs = { hexe.tab("main", { root = hexe.pane() }) } })
```

A setting the config never mentions is left alone, so there is no defaults table to keep in sync and
no way to blank something by forgetting to list it. `hexe.key` and `hexe.layout` are registrars:
calling one adds it, and calling it again adds another. Handlers and binds are tried in the order
they were registered.

**Nested data stays nested.** What changed is how a setting is *delivered*, not the shape of its
value — a structured setting is still a table on the right-hand side:

```lua
hexe.pop.widgets.keycast = { enabled = false, position = "bottomright", duration_ms = 2000 }
hexe.mux.floats.defaults = {
  size  = { width = 80, height = 70 },
  attrs = { sticky = true, global = true },
}
```

Most of a hexe config is a tree of plain data — border glyphs, widget positions, colour numbers —
and spelling that out as a hundred separate assignments would be worse than the table it already is.
Assign the tree.

A namespace that does not exist stays nil, so `hexe.mxu.confirm = {}` raises at load time instead of
quietly collecting settings nothing will read. A typo *inside* a namespace is caught by the
validator, with its path: `config error: mux.confirm.exti`.

## Plugins

Installed, not configured: `hexe plugin install ./thing`. A plugin brings its
own keybindings and its own declaration of what it needs, so your config never
mentions it. See [plugins.md](plugins.md).

## Helper programs

`hexe.plugin` starts something alongside the session — a recorder, a gateway
streaming panes to a browser, anything that wants the session's data and has to
be running for it to be there:

```lua
hexe.plugin("share", { command = "my-streamer --port 8080" })
```

```lua
hexe.plugin("share", { command = "my-streamer --port 8080", access = { "stream", "popup" } })
```

`access` says what it may do — `read`, `screen`, `typing`, `keyboard`, `stream`,
`popup`, `control`. Declaring nothing means read-only. See
[access.md](access.md).

It gets `HEXE_API_SOCKET` (its own scoped socket), `HEXE_ACCESS` and
`HEXE_SESSION` in its environment, so it never has to guess where hexe is.
Started once, detached, and **not supervised** — see
[streaming.md](streaming.md) for what it can then read.

## Splitting the config up

A file you split out **registers what it declares and returns nothing**, and the config loads it for
that effect:

```lua
-- ~/.config/hexe/layout.lua
local hexe = require("hexe")

hexe.layout("default", { tabs = { hexe.tab("main", { root = hexe.pane() }) } })
hexe.key({ hexe.key.alt, hexe.key["1"] }, hexe.action.float.toggle("1"))
```

```lua
-- ~/.config/hexe/init.lua
require("layout")
```

The config directory is on the module path, so a file beside `init.lua` is `require("layout")` — no
absolute path, and no `os.getenv("HOME")`.

**`require`, not `dofile`.** A required file is loaded once however many times it is named; `dofile`
runs it again, and running a fragment twice registers every key and layout in it twice.

The shape to avoid is a fragment that *returns* a table for the config to merge — `local cfg =
dofile(...)`, then `cfg.keys or {}`, then a check of what shape it turned out to be. That merge
lives in the config and every new fragment re-implements it. A table is fine as an **argument**
(`hexe.layout("name", {...})` is one); what does not work is a table handed back for somebody else
to take apart.

<details>
<summary>The older <code>hexe.setup{}</code> form still loads</summary>

```lua
return hexe.setup({
  mux  = { confirm = { exit = true } },
  keys = { hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.q }, hexe.action.quit()) },
})
```

Both spellings build the same config. A file that calls `setup` uses what it passed and ignores
anything assigned to the module, so the two do not mix within one file.

</details>

```sh
hexe config check     # validate and summarise
hexe config paths     # where hexe looks
hexe config dump      # the normalised result
```

<!-- demo:begin -->
[![config demo](https://asciinema.org/a/1263026.svg)](https://asciinema.org/a/1263026)
<!-- demo:end -->

## Which files hexe reads

Exactly one, by name:

| path | who opens it |
|---|---|
| `~/.config/hexe/init.lua` | **hexe**. The config. The only file it looks for. |
| `~/.config/hexe/layout.lua` | **your init.lua**, if it chooses to `require("layout")`. hexe never looks for this name — split your layouts out or inline them, as you like. |
| `~/.config/hexe/lua/…` | **you**, via `require()`. A search path for modules you write; empty by default and needed by nobody. |
| `./.hexe.lua` | **hexe**, per directory, sandboxed unless trusted. |

So there is one config file. `layout.lua` is a convention this repo's example follows, not a
second config format, and `lua/` is optional.

## How it works

```
~/.config/hexe/init.lua      ── the config
        │  (hexe.setup)
        ▼
   config builder             each section validated as it is set;
        │                     an unknown top-level section is an ERROR
        ▼
   normalised config ──> frontend · status bar · SES layouts
        ▲
./.hexe.lua ────────────┘     project overlay, run with capabilities revoked
```

`hexe.setup` is not a convention, it is the schema. Sections are validated as they are read, raw
legacy layout spellings are refused
rather than migrated, and an unknown top-level key is an error rather than a silently ignored
typo — which is the difference between a config that does not do what you meant and one that says
so.

### Reloading

`hexe.action.config.reload()` re-reads the file and hot-swaps it into the running frontend: new
keys, new theme, without losing a single pane. A config that fails to parse is
reported and the running one is kept.

The blast radius of a broken config is worth knowing, and the recording above shows it: the
frontend keeps its running configuration and every pane stays exactly where it was, while the
painter is a separate process and is unaffected by a bad hexe config: the bar keeps drawing
whatever it drew last.

### The Lua runtime

The config runs in a real Lua interpreter, and by default an unrestricted one: `io`, `os`,
`package`, `dofile` and `hexe.exec` are all there, which is why a config can read
`/etc/os-release`, `dofile` a second file, or shell out for a git branch.

Setting `HEXE_UNRESTRICTED_CONFIG` to anything other than `1` revokes that: `io`, `package`,
`dofile`, `loadfile`, `load`, `debug` and `hexe.exec` are removed, `os` keeps only `time`, `date`,
`clock` and `difftime`, and `require` accepts nothing but `"hexe"`. The same revocation is applied
unconditionally to a project-local `.hexe.lua`, whatever your setting — a file that arrives with a
git clone does not get your capabilities.

`hexe.fs` and `hexe.stream` go with them, natives included. They exist so the *client library* can
find a peer's socket and open it, and the client library cannot run in there anyway — `load` is gone
and `require` resolves only `"hexe"`. Left reachable they would undo the rest of the list: `fs.read`
reads any file despite `io = nil`, `fs.ls` enumerates the runtime directory, and `stream.connect`
takes **any** unix socket path — an ssh-agent, a container daemon, or the session's own control
socket, which is full authority over the mux. Confining them to hexe's own runtime directory would
not fix that last one, so an untrusted file gets none of it.

Note what that does *not* stop: a layout's `command =` strings and `on_start`/`on_stop` hooks are
shell commands by definition. Those are gated separately, by the trust ledger — see
[project sessions](session-manager.md).

### Shelling out, when you must

```lua
local r = hexe.exec("git branch --show-current", { timeout_ms = 80, cache_ms = 1000 })
-- r.ok, r.code, r.stdout, r.stderr, r.timeout, r.cached, r.elapsed_ms
```

The timeout and the cache are the interesting fields: a keybind condition can run this on every
matching keypress, so it is asynchronous and cached rather than blocking the loop.

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

- **One language for everything.** Keys, layouts and popup styling are the same
  Lua, so a helper you write for one is usable in the others. The shipped config defines
  helper once and uses it in several places.
- **Errors are refusals.** Wrong types, out-of-range values and old spellings are rejected with
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
| `names` | `session` / `pane` dictionaries, `order`, `suffix` — see [names](names.md) |
| `status` | `view` or `zones` / `shrink` / `socket` / `refresh_ms` — see [painting](regions.md) |
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

### The rest of the `hexe` table

Beyond `setup`, `key`, `layout`, `tab`, `split`, `pane`, `float`, `theme`, `style` and
`exec`, the runtime exposes a handful of helpers nothing documented:

| | |
|---|---|
| `hexe.validate(cfg)` | check a config table without applying it |
| `hexe.keymap` / `hexe.keymap.set{…}` | an alternative spelling for a bind list; callable as well as a table |
| `hexe.when.press \| release \| repeat \| hold` | the names for a bind's `on` field |
| `hexe.command("lazygit")` | asserts its argument is a string and returns it — a typo guard for `command =` fields |
| `hexe.status.recording(scope)`, `hexe.record.*` | recording state, for scripts and keybinds |
| `hexe.live.*` | the live API, handed to every callback as its argument (`ctx`). Read: `pane`, `panes`, `floats`, `splits`, `tabs`, `session`, `ui`, `count`, `env`. Act: `act`, `exec`, `notify`, `send`, `focus`, `close`, `scroll`, `tab_select`, `rename_tab`. See [keybindings](keybindings.md#the-query-api) |

A split's children can carry their own `size`, so `hexe.split("h", { hexe.pane({ size = 70 }),
hexe.pane() })` is a 70/30 split without a `ratio`.

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
| `src/core/api_bridge*.zig` | Lua ↔ Zig for floats, layouts, recording |
| `src/core/lua_api_exec.zig`, `cmd.zig`, `async_cmd.zig` | `hexe.exec` and its cache |
| `src/core/style.zig` | the style string language |
| `src/cli/commands/config_validate.zig` | `config check` / `validate` |
| `src/frontends/terminal/keybinds_actions.zig` | `performConfigReload` |
| `config/init.lua`, `config/layout.lua` | the author's own config, which is the repo's live example |

