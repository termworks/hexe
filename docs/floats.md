# Floats

Floats are overlay panes that appear on top of your splits. They are toggled with a keybinding and can be configured with rich behavior around persistence, scope, and lifecycle.

`layout.lua` owns float structure and behavior: key, command, title, size, position, and attributes.
`init.lua` owns float visuals: default borders, ad-hoc float visuals, and title-based visual matches.

---

## Defining floats

Floats are defined under `floats` in your session layout:

```lua
hx.ses.layout.define({
  name = "default",
  floats = {
    {
      key     = "g",
      command = "lazygit",
      title   = "git",
      attributes = { per_cwd = true, sticky = true, global = true },
      size = { width = 90, height = 90 },
    },
    {
      key     = "f",
      command = "fzf",
      attributes = { per_cwd = true, sticky = true, global = true },
    },
    {
      key        = "t",
      attributes = { global = false, destroy = true },
      size = { width = 40, height = 30 },
      position = { x = 100, y = 0 },
    },
  },
})
```

And toggled via keybindings:

```lua
{ on = "press", mods = { hx.mod.alt }, key = "g",
  when = "focus:any",
  action = { type = hx.action.float_toggle, float = "g" } },
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

Attributes control behavior. They are set under `attributes = { ... }`:

### `per_cwd`

One float instance per working directory.

- Toggle `Alt+g` in `/repo/a` → opens the `/repo/a` lazygit
- Toggle `Alt+g` in `/repo/b` → opens the `/repo/b` lazygit (separate instance)
- Go back to `/repo/a` → shows the `/repo/a` instance again

Useful for project-scoped tools: `lazygit`, `nvim`, REPLs, file browsers.

### `sticky`

The float survives mux restarts.

- Pod is kept alive in a half-attached state when mux detaches or exits
- New mux automatically reclaims it on reattach
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

Float visuals are configured in `init.lua`, not inside `layout.lua`.

Named floats use `set_defaults(...)` as their base.
Ad-hoc CLI floats use `set_adhoc(...)` as their base.
Then every `set_match(pattern, ...)` rule whose regex pattern matches the float title is applied in declaration order. Later matches win.

```lua
hx.mux.float.set_defaults({
  size = { width = 65, height = 65 },
  color = { active = 2, passive = 237 },
  attributes = { global = true },
})

hx.mux.float.set_adhoc({
  size = { width = 80, height = 70 },
  color = { active = 4, passive = 237 },
})

hx.mux.float.set_match("^explorer$", {
  padding = { x = 2, y = 1 },
  color = { active = 6, passive = 238 },
  style = {
    shadow = { color = 236 },
    border = {
      chars = {
        top_left = "╔",
        top_right = "╗",
        bottom_left = "╚",
        bottom_right = "╝",
        horizontal = "═",
        vertical = "║",
      },
    },
  },
})
```

`set_match(...)` uses the float title, not the Pokemon pane name.

### Border style

Border characters and colors live in `set_defaults`, `set_adhoc`, or `set_match`:

```lua
hx.mux.float.set_match("^git$", {
  style = {
    border = {
      chars = {
        top_left     = "╭",
        top_right    = "╮",
        bottom_left  = "╰",
        bottom_right = "╯",
        horizontal   = "─",
        vertical     = "│",
      },
    },
  },
})
```

```lua
hx.mux.float.set_match("^git$", {
  color = {
    active  = 2,
    passive = 8,
  },
})
```

### Border title

Embed a title or status module in the border:

```lua
hx.mux.float.set_match("^git$", {
  style = {
    title = {
      name = "title",
      position = "topcenter",
      segments = {
        {
          name = "title",
          value = function(ctx)
            local t = hx.segment.title(ctx)
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
})
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
| `--focus` | Focus the float on open |
| `--isolation <profile>` | Isolation profile |
| `--key <key>` | Exit key (sent on dismiss) |
| `--result-file <path>` | Write float output here on close |
| `--pass-env` | Pass current env to float |
| `--extra-env K=V` | Add extra env vars |

---

## Moving floats

You can nudge a float's position with a keybinding:

```lua
{ on = "press", mods = { hx.mod.alt, hx.mod.shift }, key = "up",
  action = { type = hx.action.float_nudge, dir = "up" } },
```

---

## Full attribute reference

See [float_attributes.md](float_attributes.md) for detailed notes on each attribute and edge cases.
