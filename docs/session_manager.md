# Session Manager

Drop a `.hexe.lua` file in a project root to define tabs, splits, floats, and startup commands. Launch it with `hexe ses open .`.

## Quick Start

Create `.hexe.lua` in your project directory:

```lua
local hexe = require("hexe")

return hexe.setup({
  ses = {
    layouts = {
      hexe.layout("myproject", {
        root = ".",

        tabs = {
          hexe.tab("editor", {
            root = hexe.split("horizontal", {
              hexe.pane({ command = "nvim", cwd = "." }),
              hexe.pane({ cwd = "." }),
            }, { ratio = 0.70 }),
          }),

          hexe.tab("server", {
            root = hexe.pane({ command = "npm run dev" }),
          }),

          hexe.tab("shell", {
            root = hexe.pane(),
          }),
        },

        floats = {
          hexe.float("git", {
            key = "g",
            command = "lazygit",
            size = { width = 90, height = 90 },
            attrs = { global = true },
          }),
        },
      }),
    },
  },
})
```

Then open it:

```sh
hexe ses open .
```

## Config Resolution

`hexe ses open <target>` finds the config based on the target argument:

| Target | Resolution |
|---|---|
| `.` | `.hexe.lua` in current directory |
| `/path/to/dir` | `.hexe.lua` inside that directory |
| `/path/to/file.lua` | Use the file directly |
| `myproject` | `~/.local/share/hexe/sessions/myproject.lua` |

Named configs live in:

```text
~/.local/share/hexe/sessions/
```

## Selective Tab Launch

Append `:<tab>` to only open a specific tab from the config:

```sh
hexe ses open myproject:server
hexe ses open .:editor
```

If the tab name does not match, a default tab is created instead.

## Config Reference

Local project configs use the same canonical entrypoint as the global config:

```lua
local hexe = require("hexe")

return hexe.setup({
  ses = {
    layouts = {
      hexe.layout("name", {
        root = ".",
        tabs = {},
        floats = {},
      }),
    },
  },
})
```

### Layout

| Field | Default | Description |
|---|---|---|
| `name` | required | Layout/session name |
| `root` | config directory | Working directory for all panes |
| `tabs` | `{}` | Tab definitions |
| `floats` | `{}` | Layout-level float definitions |

### Tab

| Field | Default | Description |
|---|---|---|
| `name` | required | Tab label |
| `root` | required | Pane or split tree |
| `floats` | `{}` | Per-tab float definitions |

### Pane

```lua
hexe.pane({ command = "nvim", cwd = "src" })
```

| Field | Default | Description |
|---|---|---|
| `command` | default shell | Command to run |
| `cwd` | layout root | Working directory, relative to `root` |
| `keybindings` | `{}` | Pane-local keybindings |

### Split

```lua
hexe.split("horizontal", {
  hexe.pane({ command = "nvim" }),
  hexe.pane(),
}, { ratio = 0.70 })
```

| Field | Default | Description |
|---|---|---|
| direction | required | `"horizontal"` or `"vertical"` |
| children | required | Array of panes or nested splits |
| `ratio` | equal split | First-child ratio, `0.0` to `1.0` |

### Float

```lua
hexe.float("git", {
  key = "g",
  title = "git",
  command = "lazygit",
  size = { width = 90, height = 90 },
  attrs = { global = true, per_cwd = false },
})
```

| Field | Default | Description |
|---|---|---|
| `key` | required | Toggle key character |
| `title` | float name | Border title |
| `command` | default shell | Command to run |
| `cwd` | layout root | Working directory |
| `size.width` | `80` | Width as percentage of terminal |
| `size.height` | `80` | Height as percentage of terminal |
| `position.x` | `50` | Horizontal position, center percent |
| `position.y` | `50` | Vertical position, center percent |
| `attrs.global` | `false` | Available across all tabs |
| `attrs.sticky` | `false` | Reuse by key and directory policy |
| `attrs.per_cwd` | `false` | Separate instance per directory |
| `attrs.inherit_env` | `false` | Inherit environment from parent pane |

## Nested Splits

Splits can nest arbitrarily:

```lua
hexe.split("horizontal", {
  hexe.pane({ command = "nvim" }),
  hexe.split("vertical", {
    hexe.pane({ command = "npm run dev" }),
    hexe.pane({ command = "npm test" }),
  }, { ratio = 0.50 }),
}, { ratio = 0.50 })
```

Three-way equal split:

```lua
hexe.split("horizontal", {
  hexe.pane({ command = "nvim" }),
  hexe.pane(),
  hexe.pane(),
})
```

## Freezing A Session

Snapshot a live session as a `.hexe.lua` config:

```sh
hexe ses freeze > .hexe.lua
```

Run this from inside a hexe pane. It captures the current tab layout, split structure, and pane working directories, then outputs canonical Lua that can be reopened:

```sh
hexe ses open .
```

## CLI Reference

```sh
hexe ses open <target>[:<tab>] [--debug] [--logfile <path>]
```

Open a session from a `.hexe.lua` config.

```sh
hexe ses freeze
```

Snapshot current session as `.hexe.lua` to stdout.

## Examples

### Full-Stack Project

```lua
local hexe = require("hexe")

return hexe.setup({
  ses = {
    layouts = {
      hexe.layout("webapp", {
        root = "~/projects/webapp",

        tabs = {
          hexe.tab("code", {
            root = hexe.split("horizontal", {
              hexe.pane({ command = "nvim" }),
              hexe.split("vertical", {
                hexe.pane({ command = "npm run dev" }),
                hexe.pane(),
              }, { ratio = 0.50 }),
            }, { ratio = 0.65 }),
          }),

          hexe.tab("db", {
            root = hexe.pane({ command = "pgcli" }),
          }),

          hexe.tab("shell", {
            root = hexe.pane(),
          }),
        },

        floats = {
          hexe.float("git", {
            key = "g",
            command = "lazygit",
            size = { width = 90, height = 90 },
            attrs = { global = true },
          }),
          hexe.float("docker", {
            key = "d",
            command = "lazydocker",
            size = { width = 80, height = 80 },
            attrs = { global = true },
          }),
        },
      }),
    },
  },
})
```

### Simple Note-Taking

```lua
local hexe = require("hexe")

return hexe.setup({
  ses = {
    layouts = {
      hexe.layout("notes", {
        root = "~/notes",
        tabs = {
          hexe.tab("edit", { root = hexe.pane({ command = "nvim ." }) }),
          hexe.tab("shell", { root = hexe.pane() }),
        },
      }),
    },
  },
})
```
