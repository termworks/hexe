# Project sessions

A `.hexe.lua` in a repository describes the session that repository wants: its tabs, its splits,
what each pane runs, and the floats that belong to it. Opening it is one command, and the session
that comes up is the same one every time — for you, and for anyone else who clones the project.

```sh
hexe layout open .              # the .hexe.lua here
hexe layout open .:server       # only that tab
hexe layout open myproject      # a name registered in the layout index
hexe layout save --scope local  # freeze the running session into .hexe.lua
hexe layout list
hexe allow .                    # trust this file's hooks
```

<!-- demo:begin -->
[![session-manager demo](https://asciinema.org/a/1263037.svg)](https://asciinema.org/a/1263037)
<!-- demo:end -->

## How it works

```
hexe layout open <target>
        │
        ├─ resolve the target
        │     .            → ./.hexe.lua
        │     /path/dir    → /path/dir/.hexe.lua
        │     /path/f.lua  → that file
        │     name         → the entry named in ~/.local/share/hexe/sessions.json
        │     …:<tab>      → open only that tab
        │
        ├─ parse it with `hexe.setup`, capabilities revoked
        ├─ resolve `root` and every pane's cwd relative to it
        └─ ask SES to build the session, then attach
```

The file is the same Lua as your global config, with the same constructors, which is why a project
config can be read by a person who has never seen one:

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
          hexe.tab("server", { root = hexe.pane({ command = "npm run dev" }) }),
        },
        floats = {
          hexe.float("git", { key = "g", command = "lazygit", attrs = { global = true } }),
        },
      }),
    },
  },
})
```

### Freezing what you built

The other direction is `hexe layout save`, run from inside a session. It walks the live session —
tabs, split structure, ratios, pane working directories — and writes canonical Lua, prompting for
the layout name:

| | |
|---|---|
| `--scope local` | write `./.hexe.lua` |
| `--scope global` | register the name in the layout index, pointing at this directory |
| `--scope both` | do both |

`hexe layout list` shows the registry, and `hexe layout open <name>` opens by it. This is the loop
that makes project sessions worth having: arrange the session by hand once, freeze it, and it is
reproducible.

### Trust

A project config can carry `command =` strings and `on_start` / `on_stop` hooks, and those are
shell commands. A `.hexe.lua` that arrives with a `git clone` is therefore code that would run when
you open the project — the same hazard direnv has, and hexe handles it the same way, with a ledger:

```
hexe allow .
    │
    ├─ SHA-256 the file
    └─ append "<hash>\t<realpath>" to $XDG_STATE_HOME/hexe/trust
```

Until that line exists, the layout is still loaded but its `on_start`/`on_stop` hooks are not run.
Editing the file changes its hash, so trust lapses and has to be given again — a repository cannot
be allowed once and then quietly swapped for something else.

The hash is bound to a **path**, deliberately. A bare-hash ledger trusts *content* anywhere:
allowing one repository's `.hexe.lua` would silently bless a byte-identical file in every other
checkout you ever open. Legacy bare-hash lines are not honoured, but they are recognised, so the
answer is "run `hexe allow` again" rather than "your hooks stopped working".

Two environment variables cover the rest:

| | |
|---|---|
| `HEXE_SKIP_LOCAL_CONFIG=1` | do not read `./.hexe.lua` at all |
| `HEXE_NO_PROJECT_COMMANDS=1` | read the layout, skip project-sourced `on_start` / `on_stop` |

Beyond the hooks, the Lua itself runs with `io`, `package`, `dofile`, `load`, `debug`,
`os.getenv`/`os.execute` and `hexe.exec` all revoked — the config file cannot read your filesystem
or shell out while it is being parsed, whatever your own `HEXE_UNRESTRICTED_CONFIG` setting is.

### Bare `hexe`

Running `hexe` with no arguments in a directory asks two questions in a popup, in order: are there
sessions already rooted here (attach to one?), and is there a `.hexe.lua` (load it?). Declining
both gives a plain new session. While a question is on screen the session deliberately has **no
tab** — creating one would spawn a shell, a pod and a SES pane record that answering "attach"
immediately throws away, which is exactly how stray adoptable panes get made.

## What makes it different

The comparison here is tmuxinator, teamocil and zellij's layouts.

- **The same language as the rest of the config.** A project layout is `hexe.setup` with a `ses`
  section — not a separate YAML dialect with its own vocabulary for panes and splits.
- **It round-trips.** `layout save` writes a file that `layout open` reads; there is no "describe
  your session in YAML by hand" step.
- **Trust is enforced, not advised.** tmuxinator project files are YAML that runs shell commands
  when you start them, and nothing checks whether you have seen the file before. Hexe hashes it and
  refuses hooks until you say so.
- **Opening is attaching.** There is no separate "start the session then attach" dance, and
  `target:tab` opens a slice of a large layout.

## Configuration

| | |
|---|---|
| layout | `name` (required), `root` (default: the config's directory), `tabs`, `floats` |
| tab | `name`, `root` (a pane or split), `floats`, `enabled` |
| pane | `command` (default: your shell), `cwd` (relative to `root`), `keybindings` |
| split | direction `"horizontal"` / `"vertical"`, children, `{ ratio = 0.0–1.0 }` |
| float | `key`, `title`, `command`, `cwd`, `size`, `position`, `attrs`, `add_env`, `add_path` |

Registered layouts live in `~/.local/share/hexe/sessions.json` (or `$XDG_DATA_HOME/hexe/`).

## What it cannot do

- **A layout applies at creation.** Editing `.hexe.lua` does not restructure a running session;
  reopen it.
- **`layout save` captures structure, not content.** Tabs, splits, ratios and working directories —
  not what is running in each pane, not scrollback, not float instances.
- **Trust covers hooks, not commands.** A pane's `command =` still runs when the layout is opened;
  the ledger gates `on_start`/`on_stop`. Read a project's `.hexe.lua` before opening it, exactly as
  you would read its `Makefile`.
- **The registry is a name-to-directory index**, not a store: `layout open <name>` opens the
  `.hexe.lua` in that directory, so moving the directory breaks the entry.
- **`hexe ses open` and `hexe ses freeze` are gone.** They are `hexe layout open` and
  `hexe layout save` in this build, and the older documentation still says otherwise.
- **A missing tab name falls back.** `open .:nope` creates a default tab rather than failing.

## Where it lives

| | |
|---|---|
| `src/core/session_config.zig` | target resolution, parsing, the layout registry |
| `src/cli/commands/ses_open.zig` | `hexe layout open` |
| `src/cli/commands/ses_freeze.zig` | `hexe layout save`, and the Lua it writes |
| `src/core/trust.zig` | the ledger: hashing, path binding, `isTrusted`, `allow` |
| `src/cli/app.zig` | `hexe allow`, and the `layout` subcommands |
| `src/frontends/terminal/startup_chooser.zig` | what bare `hexe` asks |
| `src/modules/session/layout_apply.zig`, `layout_template.zig` | building the session from a layout |

## Reference: the config schema


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
| `add_env` | `{}` | Extra env vars for this float, overriding inherited ones |
| `add_path` | `{}` | Directories prepended to this float's `PATH` |

### Nested Splits

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
