# Floats

Floats are overlay panes that appear on top of your splits. They are toggled with a keybinding and can be configured with rich behavior around persistence, scope, and lifecycle.

Layouts own float structure and behavior: key, command, title, size, position, and attrs.
Mux config owns float visuals: default borders, ad-hoc float visuals, and title-based visual matches.

---

## Defining floats

Floats are defined under `floats` in your session layout:

```lua
return hexe.layout("default", {
  floats = {
    hexe.float("git", {
      key     = "g",
      command = "lazygit",
      title   = "git",
      attrs = { per_cwd = true, sticky = true, global = true },
      size = { width = 90, height = 90 },
    }),
    hexe.float("files", {
      key     = "f",
      command = "fzf",
      attrs = { per_cwd = true, sticky = true, global = true },
    }),
    hexe.float("scratch", {
      key        = "t",
      attrs = { global = false, destroy = true },
      size = { width = 40, height = 30 },
      position = { x = 100, y = 0 },
    }),
  },
})
```

And toggled via keybindings:

```lua
{ on = "press", mods = { hexe.mod.alt }, key = "g",
  when = "focus:any",
  action = hexe.action.float.toggle("g") },
```

---

## Sizing and position

| Field | Default | Description |
|---|---|---|
| `size.width` | float default | Width as % of terminal (10–100) |
| `size.height` | float default | Height as % of terminal (10–100) |
| `position.x` | `50` | Horizontal anchor (0=left, 50=center, 100=right) |
| `position.y` | `50` | Vertical anchor (0=top, 50=center, 100=bottom) |

---

## Attributes

Attributes control behavior. They are set under `attrs = { ... }`:

### `per_cwd`

One float instance per working directory.

- Toggle `Alt+g` in `/repo/a` → opens the `/repo/a` lazygit
- Toggle `Alt+g` in `/repo/b` → opens the `/repo/b` lazygit (separate instance)
- Go back to `/repo/a` → shows the `/repo/a` instance again

Useful for project-scoped tools: `lazygit`, `nvim`, REPLs, file browsers.

### `sticky`

The float survives terminal-frontend restarts.

- Pod is kept alive in a half-attached state when the frontend detaches or exits
- A new frontend automatically reclaims it on reattach
- Combine with `per_cwd` for directory-specific persistent floats

### `global`

Controls tab scope.

- `global = true` (recommended with `per_cwd`): Float is visible across all tabs. Visibility is tracked per-tab via a bitmask.
- `global = false` (default): Float is bound to the tab it was created on. Closing that tab destroys it.

### `exclusive`

When shown, this float hides all other floats on the current tab.

Useful for modal-style overlays where you want a single focused tool.

### `destroy`

The float process is killed when the float is hidden.

- Meaningful only for tab-bound, non-`per_cwd` floats
- Useful for fire-and-forget tools or one-shot dialogs

### `isolated`

The float runs inside a sandboxed pod (Linux namespaces + cgroups).

See [isolation](isolation.md) for profiles and resource limits.

## Visual policy

Float visuals are configured in the `mux.floats` section.

Named floats use `defaults` as their base. Ad-hoc CLI floats use `adhoc`.
Then every `match[pattern]` rule whose regex pattern matches the float title is applied in declaration order. Later matches win.

```lua
return {
  floats = {
    defaults = {
      size = { width = 65, height = 65 },
      color = { active = 2, passive = 237 },
      attrs = { global = true },
    },
    adhoc = {
      size = { width = 80, height = 70 },
      color = { active = 4, passive = 237 },
    },
    match = {
      ["^explorer$"] = {
        padding = { x = 2, y = 1 },
        color = { active = 6, passive = 238 },
      },
    },
  },
}
```

`match[...]` uses the float title, not the pane name.

### Border style

Border characters and colors live in `defaults`, `adhoc`, or `match`:

```lua
return {
  floats = {
    match = {
      ["^git$"] = {
        style = {
          border = {
            chars = {
              top_left = "╭",
              top_right = "╮",
              bottom_left = "╰",
              bottom_right = "╯",
              horizontal = "─",
              vertical = "│",
            },
          },
        },
      },
    },
  },
}
```

```lua
return {
  floats = {
    match = {
      ["^git$"] = {
        color = { active = 2, passive = 8 },
      },
    },
  },
}
```

### Border title

Embed a title or status module in the border:

```lua
return {
  floats = {
    match = {
      ["^git$"] = {
        style = {
          title = {
            name = "title",
            position = "topcenter",
            segments = {
              {
                name = "title",
                render = function(ctx)
                  local t = hexe.segment.title(ctx)
                  return {
                    { text = "[", style = "bg:0 fg:1" },
                    { text = " " .. t .. " ", style = "bg:237 fg:250" },
                    { text = "]", style = "bg:0 fg:1" },
                  }
                end,
              },
            },
          },
        },
      },
    },
  },
}
```

---

## Ad-hoc floats (CLI)

Spawn a one-off float from the command line:

```sh
hexe terminal float --command "btop" --title "monitor" --size "80,70,0,0"
hexe terminal float --command "zsh" --isolation sandbox
hexe terminal float --command "bash /tmp/script.sh" --result-file /tmp/result
```

Options:

| Flag | Description |
|---|---|
| `--command` | Command to run |
| `--title` | Border title |
| `--cwd` | Working directory |
| `--size WxH,X,Y` | Size and position |
| `--isolation <profile>` | Isolation profile |
| `--key <key>` | Exit key (sent on dismiss) |
| `--result-file <path>` | Write float output here on close |
| `--pass-env` | Pass current env to float |
| `--extra-env K=V` | Add extra env vars |

---

## Moving floats

You can nudge a float's position with a keybinding:

```lua
{ on = "press", mods = { hexe.mod.alt, hexe.mod.shift }, key = "up",
  action = hexe.action.float.nudge("up") },
```

---

## Full attribute reference

See [float_attributes.md](float_attributes.md) for detailed notes on each attribute and edge cases.
