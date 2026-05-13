# Sessions

A session is a named collection of tabs, splits, and floats tracked by `hexe ses`.

Sessions survive terminal-frontend restarts. Detach and reattach freely — your shells keep running.

---

## Basic commands

```sh
# Start a new session
hexe terminal new

# Start a named session
hexe terminal new --name work

# List sessions
hexe ses list

# Attach to a session (by name or UUID prefix)
hexe terminal attach work
hexe terminal attach a3f2

# Detach from current session (leaves everything running)
# (default keybind: Alt+Shift+D release)
```

---

## Detach and reattach

Detaching leaves the ses daemon and all pods running. The terminal frontend process exits. On reattach:

- Layout is restored from ses state
- Each pane reconnects to its pod
- Scrollback is replayed so you see the output you missed

Scrollback is buffered in the pod as a ring buffer of raw PTY bytes. Ghostty VT rebuilds terminal history from the replayed stream.

---

## Layouts

Layouts define the initial tab/split/float structure for a session. They are defined in your config and applied when a new session starts.

```lua
local hexe = require("hexe")

return hexe.setup({
  ses = {
    layouts = {
      hexe.layout("default", {
  enabled = true,

  tabs = {
    hexe.tab("code", {
      root = hexe.split("horizontal", {
        hexe.pane({ cwd = "~/projects/myapp" }),
        hexe.split("vertical", {
          hexe.pane({ cwd = "~/projects/myapp", command = "btop" }),
          hexe.pane({ cwd = "~/projects/myapp" }),
        }),
      }),
    }),
    hexe.tab("notes", {
      root = hexe.pane({ cwd = "~/notes", command = "nvim" }),
    }),
  },

  floats = {
    hexe.float("git", {
      key = "g",
      command = "lazygit",
      attrs = { per_cwd = true, sticky = true },
      size = { width = 90, height = 90 },
    }),
    hexe.float("files", {
      key = "f",
      command = "fzf",
      attrs = { per_cwd = true, sticky = true },
    }),
  },
      }),
    },
  },
})
```

### Tab definition

| Field | Default | Description |
|---|---|---|
| `name` | required | Tab label |
| `enabled` | `true` | Include on startup |
| `root` | — | Root split or pane |

### Pane definition

| Field | Description |
|---|---|
| `cwd` | Working directory |
| `command` | Command to run (default: shell) |

### Split definition

| Field | Default | Description |
|---|---|---|
| `dir` | required | `"h"` (horizontal) or `"v"` (vertical) |
| `ratio` | `0.5` | Fraction of space for `first` |
| `first` | required | First child (split or pane) |
| `second` | required | Second child (split or pane) |

### Float definition

See [floats](floats.md) for the full float reference.

---

## Session persistence

Ses writes session state to disk periodically and on clean shutdown:

```
~/.local/state/hexe/sessions/
```

If ses crashes, it reads this on restart and recovers the session map. Pane layout, pod UUIDs, and float associations are all stored.

---

## Pane adoption

You can move orphaned panes between sessions.

- **Disown**: remove a pane from the current session (pod keeps running, pane becomes orphaned)
- **Adopt**: pick up an orphaned pane into the current session

Keybinds:
- `action = hexe.action.pane.disown()`
- `action = hexe.action.pane.adopt()`

On adopt, you can swap the adopted pane with the current one, or destroy the current pane and take its slot.

---

## CLI reference

```sh
hexe ses daemon          # Start daemon (usually automatic)
hexe ses list            # List sessions and panes
hexe ses kill <uuid>     # Kill a detached session
hexe ses clear           # Kill all detached sessions
hexe ses export <uuid>   # Export session state as JSON
hexe ses stats           # Resource usage statistics
hexe ses status          # Daemon info
hexe ses open <target>   # Open session from .hexe.lua config
hexe ses freeze          # Snapshot session as .hexe.lua to stdout
```

For declarative per-project session configs, see [session_manager](session_manager.md).
