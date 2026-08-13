# The status bar

Three zones, a list of segments in each, and a width budget that decides who survives when the
terminal is narrow. A segment is either a Lua function returning styled text, a descriptor naming
one of hexe's built-ins, a clickable button, or a progress reporter — and the kind is inferred from
which of those fields you wrote.

```lua
status = {
  enabled = true,
  left   = { hexe.segment.session({ style = "bg:5 fg:0", prefix = " ", suffix = " " }) },
  center = { hexe.segment({ name = "tabs", render = function(ctx) return hexe.segment.tabs(ctx) end }) },
  right  = { hexe.segment.git_branch({ style = "bg:5 fg:0" }),
             hexe.segment.directory({ style = "bg:237 fg:15" }) },
},
```

<!-- demo:begin -->
[![statusbar demo](https://asciinema.org/a/1262992.svg)](https://asciinema.org/a/1262992)
<!-- demo:end -->

## How it works

```
┌ left ─────────────┬──────── center ────────┬───────────── right ┐
│ session  pod  ⣾   │      main  build       │   branch    ~/proj │
└───────────────────┴────────────────────────┴────────────────────┘
  width-budgeted        rendered last,           width-budgeted
  by priority           truly centred            by priority
```

The bar is redrawn on a timer — 250 ms normally, 75 ms while something is animating — and each
redraw asks every segment for its current output. Left and right are laid out against a budget:
when there is not enough room, the segment with the **highest** `priority` number is dropped first,
so a low number means "keep me longest". The centre zone is rendered after both sides and can
visually win an overlap, which is why the tab list belongs there.

### The four kinds of segment

```lua
render   = function(ctx) return { { text = "…", style = "bg:237 fg:250" } } end
builtin  = function(ctx) return hexe.segment.builtin.git_status({ style = "bg:1 fg:0" }) end
button   = { on_left_click = "…", active_when = function(ctx) … end }
progress = { every_ms = 1000, show_when = function(ctx) … end, render = function(ctx) … end }
```

`render` runs in-process and returns text, a number, or a list of `{ text, style }` blocks;
returning `nil` or `false` hides the segment, which is how conditional segments are written.
`builtin` returns a *descriptor* — a name plus style, prefix and suffix — and the descriptor's
style is authoritative rather than merged.

### Buttons

A segment with a `button` table is clickable, and hexe treats it as one: it renders reversed while
hovered, keeps a clicked state you can style per mouse button, and un-clicks when clicked again.
Handlers are shell commands or callbacks returning one, and the focused pane's uuid is exported to
them (`HEXE_FOCUSED_PANE_UUID`), so a button can act on the pane you are looking at.

That is enough to build a recording toggle in the bar:

```lua
{
  name = "rec",
  render = function(_)
    local st = hexe.status.recording("pod")
    return { { text = st and st.active and " REC " or " rec ", style = "bg:1 fg:15 bold" } }
  end,
  button = {
    on_left_click = function(ctx)
      local rec = hexe.record.active(ctx, { scope = "pod", out = "/tmp/pane.cast" })
      return rec and rec.switch() or nil
    end,
    on_right_click = function(_) return hexe.record.stop({ scope = "pod" }) end,
    active_when = function(_) local st = hexe.status.recording("pod"); return st and st.active end,
    inverse_on_hover = true,
  },
}
```

### What the panes tell it

Two things arrive from the panes themselves rather than from config. **Progress**: a pane that
emits OSC 9;4 gets a progress indicator at the right edge — running, error, indeterminate or
paused, with percentages capped at 100, cleared by state 0. **Notifications**: OSC 9, 99 and 777
are consumed by hexe rather than forwarded blindly to the host terminal, and the message names the
pane it came from. Desktop delivery only happens when the frontend advertises that capability.

Notifications are not segments. They are drawn over the bar and time out:

```sh
hexe terminal notify "build finished"
hexe terminal notify --broadcast "deploying"
```

### Built-ins

`tabs`, `session`, `directory`, `git_branch`, `git_status`, `jobs`, `duration`, `status`, `sudo`,
`pod_name`, `hostname`, `username`, `time`, `cpu`, `memory`, `netspeed`, `battery`, `uptime`,
`last_command`, `running_anim`, `randomdo`, `spinner`, `character`.

Anything expensive should not be a shell-out on every redraw. `hexe.exec` exists for when it must
be, with a timeout and a cache:

```lua
local r = hexe.exec("git branch --show-current", { timeout_ms = 80, cache_ms = 1000 })
if r.ok then return r.stdout end
```

## What makes it different

tmux's status line is a format string with interpolations (`#{pane_current_path}`), evaluated by
the server. Hexe's is a list of Lua callbacks evaluated in the frontend, and the difference shows
up in three places:

- **A segment is a function**, so anything Lua can compute is a segment — no `#()` shelling out per
  redraw, and a cache with a TTL when you do shell out.
- **Segments are click targets** with hover and click state, because the frontend that draws them
  also owns the mouse.
- **Priority is a budget, not an order.** Narrow the terminal and segments drop out by declared
  importance rather than being truncated left to right.
- What tmux gives you instead: a status line that survives client restarts because the server owns
  it. Hexe's bar is frontend state, redrawn from scratch by whatever attaches.

## Configuration

```lua
{
  name     = "tabs",
  priority = 1,
  render   = function(ctx) return hexe.segment.tabs(ctx) end,
  -- tabs-only
  active_style = "bg:5 fg:0 bold", inactive_style = "bg:237 fg:250",
  separator = " │ ", separator_style = "fg:7",
  tab_title = "basename",           -- or "name"
  left_arrow = "", right_arrow = "",
  -- any segment
  when = function(ctx) local p = ctx.pane(0); return p and p.process_running end,
  spinner = { kind = "knight_rider", width = 8, step_ms = 75, colors = { 1, 3, 5 } },
}
```

`ctx` carries `shell_running`, `alt_screen`, `jobs`, `last_status`, `exit_status`, `last_command`,
`cwd`, `home`, `cmd_duration_ms`, `terminal_width`, `now_ms`, `env`, plus `ctx.pane(...)` lookups
across every pane and `ctx.cache` for memoising.

Notification styling lives under `pop.notify`, separately from the segment lists:

```lua
pop = { notify = { mux = { fg = 232, bg = 5, bold = true, padding_x = 2,
                           alignment = "center", duration_ms = 2500 } } },
```

## Measurements

- **Redraw cadence: 250 ms**, dropping to **75 ms** while an animated segment is running.
- **Pane metadata sync: 1 s** — the cadence at which cwd and foreground process are refreshed, and
  therefore the resolution of any segment built on them.
- **`statusbar_redraw` events are throttled to 120 ms** by default, with a `debounce` helper for
  handlers that need less.
- **Condition results are cached** with a short TTL; `HEXE_LUA_TRACE=slow` reports callbacks over
  `HEXE_LUA_TRACE_SLOW_MS` (default 8 ms).

## What it cannot do

- **A slow segment is a slow bar.** `render` runs in the frontend's loop; use `hexe.exec` with
  `cache_ms`, or compute in an event handler and read the cached value.
- **The bar is not persisted.** It is frontend state, rebuilt on every attach.
- **Only one bar.** No per-tab or per-pane status lines; a float can carry a title module in its
  border, which is the nearest thing.
- **Percentages, not pixels.** Layout is three zones and a priority budget — there is no absolute
  positioning and no per-cell control.
- **Legacy condition forms are gone.** Token tables, `when = { lua = … }`, bash and env conditions
  are rejected; `when` is a callback.
- **`segment.buildin` is not a name.** The old typo alias was removed rather than kept.

## Where it lives

| | |
|---|---|
| `src/frontends/terminal/statusbar.zig`, `statusbar_eval.zig` | layout, budgeting, evaluation |
| `src/core/segments/` | every built-in, one file each |
| `src/core/segments/animations/` | `knight_rider`, palette ramps |
| `src/core/segment_render.zig` | the render/builtin output model |
| `src/frontends/terminal/notification.zig`, `src/modules/popup/notification.zig` | the notification layer |
| `src/frontends/terminal/pane_osc.zig` | OSC 9;4 progress and pane notifications |
| `src/core/api_bridge.zig` | `hexe.segment`, `hexe.status`, `hexe.record` helpers |
| `docs/statusbar.md` | the reference page |
