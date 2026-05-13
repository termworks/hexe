# Hexe Lua Config Redesign Plan

## Goal

Make Hexe configuration a coherent Lua API instead of a collection of unrelated
builder calls, section parsers, and special cases. The end state is:

- one public namespace: `hexe`
- one canonical entrypoint: `return hexe.setup({...})`
- normal Lua composition through `require`
- prompt and statusbar sharing one segment model
- global and project layouts sharing one layout schema
- strict validation with useful error paths
- no backwards compatibility burden

The repo `./config` directory is the live user config source. It is linked to
`/home/bresilla/.config/hexe`, so implementation work must keep `./config`
updated as runtime behavior changes.

## Non-Goals

- Do not preserve old config shapes.
- Do not keep compatibility wrappers for removed APIs.
- Do not support shorthand public namespaces; the public API is always `hexe`.
- Do not keep both `cmd` and `command`; use `command`.
- Do not keep misspelled keybinding fields; use `keybindings`.
- Do not keep both `split` and `root` as tab roots; use `root`.
- Do not keep hidden builder state as the main config mechanism.

## Target Shape

```lua
local hexe = require("hexe")

return hexe.setup({
  theme = require("themes.default"),
  keys = require("keys.default"),
  mux = require("mux.default"),
  status = require("status.default"),
  prompt = require("prompt.default"),
  pop = require("pop.default"),
  ses = {
    layouts = {
      require("layouts.default"),
    },
  },
})
```

Modules under `./config/lua` should be normal Lua modules. Project config can
use the same API from `.hexe.lua` and `.hexe/lua`.

## Public Lua API

### Config

- `hexe.setup(spec) -> normalized_config`
- `hexe.validate(spec) -> normalized_config`

`hexe.setup` validates the whole config and returns the normalized table that
Zig consumes. It must not depend on hidden global builder mutation.

### Keymaps

- `hexe.key(keys, action, opts?)`
- `hexe.keymap.set(keys, action, opts?)`
- `hexe.action.quit()`
- `hexe.action.detach()`
- `hexe.action.pane.disown()`
- `hexe.action.pane.adopt()`
- `hexe.action.pane.close()`
- `hexe.action.pane.select()`
- `hexe.action.tab.new()`
- `hexe.action.tab.close()`
- `hexe.action.tab.next()`
- `hexe.action.tab.prev()`
- `hexe.action.float.toggle(key)`
- `hexe.action.float.nudge(direction)`
- `hexe.action.focus.move(direction)`
- `hexe.action.split.horizontal()`
- `hexe.action.split.vertical()`
- `hexe.action.split.resize(direction)`
- `hexe.action.clipboard.copy()`
- `hexe.action.clipboard.request()`
- `hexe.action.overlay.keycast_toggle()`
- `hexe.action.overlay.sprite_toggle()`
- `hexe.action.system.notify()`

Canonical config uses:

```lua
return {
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.q }, hexe.action.quit()),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.up }, nil, {
    when = function(ctx)
      local pane = ctx:pane("focused")
      return pane and pane.process_name == "nvim"
    end,
    mode = hexe.mode.passthrough_only,
  }),
}
```

### Segments

- `hexe.segment(spec)`
- `hexe.segment.time(opts?)`
- `hexe.segment.session(opts?)`
- `hexe.segment.tabs(opts?)`
- `hexe.segment.directory(opts?)`
- `hexe.segment.git_branch(opts?)`
- `hexe.segment.battery(opts?)`
- `hexe.segment.duration(opts?)`
- `hexe.segment.spinner(opts?)`
- `hexe.segment.title(ctx_or_opts?)`

One segment object should work in both prompt and statusbar unless a field is
explicitly unsupported by the renderer.

Canonical segment:

```lua
hexe.segment({
  id = "git.branch",
  priority = 40,
  render = function(ctx)
    return {
      { text = " main ", style = "git.branch" },
    }
  end,
  when = function(ctx)
    return ctx.cwd ~= nil
  end,
  update = {
    interval_ms = 500,
    cache_ms = 1000,
  },
  actions = {
    left_click = function(ctx)
      return hexe.command("lazygit", { cwd = ctx.cwd })
    end,
  },
})
```

### Layouts

- `hexe.layout(name, spec)`
- `hexe.tab(name, spec)`
- `hexe.split(direction, children, opts?)`
- `hexe.pane(spec?)`
- `hexe.float(name, spec)`

Use only these canonical fields:

- `root`
- `command`
- `keybindings`
- `attrs`
- `cwd`
- `env`
- `isolation`
- `position`
- `size`
- `padding`
- `style`

Example:

```lua
return hexe.layout("default", {
  enabled = true,
  root = ".",
  tabs = {
    hexe.tab("main", {
      root = hexe.split("horizontal", {
        hexe.pane({ cwd = "." }),
        hexe.pane({ command = "nvim" }),
      }, { ratio = 0.5 }),
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

### Theme

- `hexe.theme(spec)`

Styles should be symbolic and reusable:

```lua
return hexe.theme({
  colors = {
    bg = 237,
    fg = 250,
    accent = 1,
    good = 2,
    warn = 3,
  },
  styles = {
    ["status.active"] = "bg:1 fg:0 bold",
    ["git.branch"] = "bg:2 fg:0",
  },
  chars = {
    split_vertical = "│",
    split_horizontal = "─",
  },
})
```

### Execution

Expose one command execution helper:

```lua
local result = hexe.exec("git branch --show-current", {
  cwd = ctx.cwd,
  timeout_ms = 80,
  cache_ms = 1000,
})
```

Return shape:

```lua
{
  ok = true,
  code = 0,
  stdout = "...",
  stderr = "...",
  timeout = false,
  cached = true,
  elapsed_ms = 12,
}
```

Expose one command action descriptor for click handlers and key actions that
need to launch a command instead of running it synchronously during config
evaluation:

```lua
return hexe.command("lazygit", { cwd = ctx.cwd })
```

## Module Loading

Add these paths to `package.path`:

- `~/.config/hexe/lua/?.lua`
- `~/.config/hexe/lua/?/init.lua`
- `./.hexe/lua/?.lua`
- `./.hexe/lua/?/init.lua`

Do not invent a custom module system. Use normal Lua `require` so more complex
configs can be split into reusable external modules.

Target live config structure:

```text
config/
  init.lua
  lua/
    keys/default.lua
    layouts/default.lua
    mux/default.lua
    pop/default.lua
    prompt/default.lua
    segments/git.lua
    segments/system.lua
    status/default.lua
    themes/default.lua
```

## Unified Context

Every callback should receive the same `ctx` model:

```lua
ctx = {
  cwd = "...",
  session = { name = "...", uuid = "..." },
  tab = { name = "...", index = 1, count = 3 },
  pane = {
    uuid = "...",
    kind = "split",
    title = "...",
    process_name = "nvim",
    cwd = "...",
    alt_screen = false,
    shell_running = false,
  },
  float = {
    active = false,
    key = nil,
    sticky = false,
  },
  host = {
    hostname = "...",
    os = "linux",
  },
}
```

Helper methods should be consistent:

- `ctx:pane("focused")`
- `ctx:pane(0)`
- `ctx:tab("active")`
- `ctx:float("active")`

Use this context for:

- segment render callbacks
- segment `when`
- keymap `when`
- click actions
- autocmds and events

## Validation

Validation must be strict:

- unknown top-level sections are errors
- unknown fields inside known sections are errors unless explicitly allowed
- wrong field types are errors
- unsupported segment fields in a target are errors
- missing required fields are errors
- malformed actions are errors
- malformed key specs are errors
- malformed layouts are errors
- no silent fallback for bad config

Error messages must include paths:

```text
config error: status.right[3].render must be function
config error: ses.layouts[1].tabs[2].root must be pane or split
config error: keys[5].action is required unless mode is passthrough_only
```

## Config CLI

Keep these commands as the main verification surface:

- `hexe config check`
- `hexe config dump`
- `hexe config paths`

`dump` should print the normalized config after Lua evaluation, not the raw Lua
source.

## Implementation Phases

### Phase 1: New Config AST

Create one normalized config model in Zig.

Files likely involved:

- `src/core/config.zig`
- `src/core/config_v2.zig`
- `src/core/session_config.zig`
- `src/core/lua_runtime.zig`
- `src/core/api_bridge.zig`

Deliverables:

- root `HexeConfigV2` model or equivalent
- typed sections for theme, keys, mux, floats, status, prompt, pop, and ses
- path-aware validation helpers
- test coverage for minimal and full config shapes
- no user-visible behavior change required yet

### Phase 2: New Public Lua Surface

Expose the canonical API through `require("hexe")`.

Deliverables:

- `hexe.setup`
- `hexe.validate`
- key/action constructors
- segment constructors
- layout constructors
- theme constructor
- module search paths for user and project modules
- public table contains only intended public names

Old builder functions may exist internally during the transition, but live
config must stop calling them.

### Phase 3: Migrate Live Config Modules

Edit `./config` in lockstep with the runtime.

Deliverables:

- small `config/init.lua`
- normal modules under `config/lua`
- `config/layout.lua` removed
- `.hexe.lua` migrated to the same shape as global config
- no shorthand namespace usage
- no removed spellings or fields

This phase should happen continuously, not as a final cleanup.

### Phase 4: Apply Mux, Pop, And Session Scalars From AST

Move data-only sections out of Lua bridge calls and into Zig-side AST
application.

Deliverables:

- mux confirmations from `mux.confirm`
- mouse selection override from `mux.mouse`
- split styles from `mux.splits`
- pop notify/confirm/choose/widgets from `pop`
- session isolation from `ses.isolation`
- tests proving config loads without public bridge calls

### Phase 5: Port Keymaps

Make `keys = { ... }` the only keymap source.

Deliverables:

- Zig consumes normalized key objects from returned config
- callback `when` functions are retained safely
- passthrough-only bindings can omit action
- malformed keys/actions fail with path-aware errors
- hidden `mux.keymap.set` bridge removed

Implementation warning:

- Do not call Lua `raiseError` from unprotected Zig config application paths.
- Prefer parser functions that return Zig errors and attach config paths.
- Avoid loop-scoped `defer` stack cleanup in key parsers; pop explicitly per
  iteration.

### Phase 6: Port Floats

Make `mux.floats` and layout floats consume the same normalized float style and
attribute model.

Deliverables:

- defaults, adhoc config, and match rules parsed from returned config
- border, title, padding, size, color, and attributes preserved
- float title render callbacks supported through unified segments/context
- hidden float config bridge removed

### Phase 7: Unified Segments

Make prompt and statusbar consume the same segment object.

Files likely involved:

- `src/frontends/terminal/statusbar.zig`
- prompt rendering paths
- `src/core/lua_runtime.zig`
- `src/core/api_bridge.zig`

Deliverables:

- `status.left`, `status.center`, `status.right` use segment arrays
- `prompt.left`, `prompt.right` use segment arrays
- builtins exposed through `hexe.segment.*`
- render callbacks use unified `ctx`
- update/cache metadata shared where possible
- unsupported target features rejected clearly
- old prompt/status builder calls removed

### Phase 8: Unified Layout Parser

Replace separate session layout parsing with `ses.layouts` from `hexe.setup`.

Files likely involved:

- `src/core/session_config.zig`
- `src/frontends/terminal/state_session.zig`
- `src/cli/commands/ses_open.zig`
- `src/cli/commands/ses_freeze.zig`
- `src/cli/commands/com.zig`

Deliverables:

- one layout schema everywhere
- tabs use `root`
- panes and floats use `command`
- pane-local bindings use `keybindings`
- `hexe ses open <target>` reads the same config shape
- project `.hexe.lua` reads the same config shape
- freeze writes the new shape
- old layout definition bridge removed

### Phase 9: Remove Old APIs And Parsers

Delete the obsolete public and hidden config mechanisms once each section has
moved.

Remove:

- old statusbar builder calls
- old prompt builder calls
- old session layout builder calls
- old section-gated builder behavior
- old returned-table project parser shape
- old keybinding spellings
- old command spellings
- old tab root schema
- old direct mux input binding parser if superseded

### Phase 10: Tests And Verification

Add focused tests for:

- module search paths
- minimal config
- full modular live config
- public API shape
- hidden old APIs unavailable publicly
- keymap validation
- segment validation
- float validation
- layout validation
- theme style resolution
- `hexe config check`
- `hexe config dump`
- `hexe config paths`
- `hexe ses open` with new layout schema
- local `.hexe.lua` project config

Use project commands:

- `make test`
- `make build`
- `./zig-out/bin/hexe config check`
- `./zig-out/bin/hexe config dump`

Do not use raw compiler commands when the Makefile target exists.

## Migration Order

1. Add the normalized AST and validation scaffolding.
2. Add `hexe.setup`, `hexe.validate`, and constructors.
3. Add normal Lua module search paths.
4. Rewrite `./config/init.lua` and split modules under `./config/lua`.
5. Rewrite `.hexe.lua` project config to the same schema.
6. Move data-only mux config to Zig-side AST application.
7. Move pop config to Zig-side AST application.
8. Move session isolation to Zig-side AST application.
9. Port keymaps.
10. Port floats.
11. Port statusbar segments.
12. Port prompt segments.
13. Port session layouts.
14. Delete old public and hidden builder APIs.
15. Update docs.
16. Run `make test`, `make build`, `hexe config check`, and `hexe config dump`.

## Acceptance Criteria

- Public Lua API is consistently under `hexe`.
- `./config` is the live config source and remains usable during migration.
- `config/init.lua` uses `local hexe = require("hexe")`.
- External modules load through normal Lua `require`.
- Prompt and statusbar share one segment schema.
- Keymaps use one schema everywhere.
- Layouts use one schema everywhere.
- Floats use one config shape for defaults, match rules, and layout floats.
- Removed field spellings are absent from config and docs.
- Config validation fails loudly with path-aware errors.
- `hexe config check` passes for repo config.
- `hexe config dump` shows the normalized config.
- `make test` passes.
- `make build` passes.
