# Overlays and popups

Everything hexe draws that is not a pane: a notification that times out, a yes/no question, a
picker, the letters that appear over panes when you are choosing one, and two teaching aids — a
keycast of what you just pressed and the big digits used for pane labels.

```sh
hexe terminal notify "build finished"
hexe terminal notify --broadcast "deploying"
hexe popup confirm "Delete the branch?"
hexe popup choose --items "staging,production,abort" "Where to?"
```

<!-- demo:begin -->
[![overlays demo](https://asciinema.org/a/1263007.svg)](https://asciinema.org/a/1263007)
<!-- demo:end -->

## How it works

An overlay has a **scope**, and the scope decides where it is drawn and who it blocks:

```
mux scope   ── over the whole frontend, above every pane
tab scope   ── over the active tab; blocks that tab's input while it waits
pane scope  ── inside one pane, anchored to it
```

A notification is fire-and-forget: it is drawn, it times out, it disappears, and nothing is
blocked. A confirm or a chooser is a *question*: while it is up it takes the keys, and the answer
goes back to whoever asked — the CLI call blocks until then, which is what makes `hexe popup
choose` usable inside a shell script.

```sh
target=$(hexe popup choose --items "staging,production" "Deploy where?")
```

The same machinery is used by hexe itself: the confirmations for quitting, detaching, disowning and
closing are the same confirm popup, turned on per action:

```lua
mux = { confirm = { exit = true, detach = true, disown = true, close = true } },
```

And the startup chooser — the questions bare `hexe` asks about attaching to a session rooted here
or loading a `.hexe.lua` — is the same popup UI rather than a line-mode prompt, deliberately: the
session has no tab at all while the question is on screen, because creating one would spawn a shell
and a pod that answering "attach" immediately throws away.

### Notifications from panes

Panes can raise them too, over OSC 9, 99 and 777. Hexe consumes those rather than forwarding them
blindly to the host terminal, so the message names the pane it came from, and only sends a desktop
notification when the frontend advertises that capability. OSC 9;4 progress goes to the status bar
instead — see [the status bar](statusbar.md).

### Widgets

Three overlays that are not questions:

| | |
|---|---|
| **keycast** | the last few keys you pressed, grouped by time, fading out — for teaching, screencasts, and pairing |
| **pane select** | a letter over every pane; press one to focus it, or to swap it with the pane you are in |
| **digits** | sub-cell block digits (3×5, 5×7 or 7×9 cells) used to draw those labels large enough to read at a glance |

Keycast groups keys pressed within a short window into one entry, keeps a handful of them, and
expires them on a timer, so a burst of typing reads as a chord rather than a stream.

## What makes it different

tmux has `display-message`, `confirm-before` and `display-menu`, and the shapes are similar. The
differences are in scope and in who can ask:

- **Scope is explicit.** A notification can belong to a pane, a tab or the whole frontend, and it
  is drawn there rather than always on the status line.
- **Any process can ask a question.** `hexe popup choose` blocks and prints the answer, so a shell
  script inside a pane can put a picker on the screen and read the result — no server command
  language, no `run-shell` indirection.
- **Panes' own notifications are attributed.** An OSC 9 from a pane arrives labelled with the pane
  it came from instead of being passed to the host terminal unattributed.
- **The styling is config, not a format string**, and it is per scope.

## Configuration

```lua
pop = {
  notify = {
    mux  = { fg = 232, bg = 5, bold = true, padding_x = 2, padding_y = 0,
             offset = 1, alignment = "center", duration_ms = 2500 },
    pane = { fg = 232, bg = 1, offset = 0, duration_ms = 3000 },
  },
  confirm = {
    mux = { fg = 232, bg = 4, bold = true, padding_x = 2, padding_y = 1 },
  },
  choose = {
    mux = { fg = 7, bg = 0, highlight_fg = 0, highlight_bg = 7, visible_count = 10 },
  },
  widgets = {
    keycast = { enabled = false, position = "bottomright", duration_ms = 2000,
                max_entries = 8, grouping_timeout_ms = 700 },
    pokemon = { enabled = false, position = "topright", shiny_chance = 0.01 },
    digits  = { enabled = false, position = "topleft", size = "small" },
  },
},
```

Actions:

| | |
|---|---|
| `hexe.action.overlay.keycast_toggle()` | show or hide the keycast |
| `hexe.action.pane.select()` | the letters, and focus-or-swap |
| `hexe.action.system.notify()` | a desktop notification through the host terminal |

CLI:

| | |
|---|---|
| `hexe terminal notify <msg> [--uuid <pane>\|--last\|--broadcast]` | a hexe notification |
| `hexe popup notify <msg> [--uuid <pane>] [--timeout <ms>]` | the popup form |
| `hexe popup confirm <msg>` | yes/no, exit status carries the answer |
| `hexe popup choose --items "a,b,c" <msg>` | prints the choice |

## Measurements

- **Keycast: 8 entries**, grouped within **700 ms**, each visible for **2000 ms** by default.
- **Chooser: 10 visible rows** by default, scrolling beyond that.
- **Notifications: 3000 ms** by default, 2500 in the configuration these recordings use.
- **Digits: 3×5, 5×7 or 7×9 cells**, drawn with quadrant blocks — two sub-pixels per cell in each
  direction.

## What it cannot do

- **A blocking popup blocks its scope.** A tab-scope question takes that tab's keys until it is
  answered; only tab switching is allowed through.
- **Notifications do not stack into a history.** They are drawn, they expire, and they are gone;
  there is no log to scroll back through.
- **The chooser is a flat list.** No filtering as you type, no multi-select, no nesting.
- **Desktop notifications depend on the host terminal.** Without the capability, the notification
  stays inside hexe.
- **Widgets are frontend state.** Keycast, sprites and digits are not in the session snapshot and
  do not survive a detach.
- **Positions are corners.** `topleft`, `topright`, `bottomleft`, `bottomright`, `topcenter`,
  `bottomcenter` — not coordinates.

## Where it lives

| | |
|---|---|
| `src/modules/popup/` | the popup module: `notification.zig`, `confirm.zig`, `picker.zig`, `style.zig` |
| `src/modules/popup/overlay/` | `manager.zig`, `keycast.zig`, `pane_select.zig`, `digits.zig` |
| `src/modules/popup/widgets/` | the widget state: keycast, pokemon, digits |
| `src/frontends/terminal/popup_render.zig`, `overlay_render.zig` | drawing them |
| `src/frontends/terminal/notification.zig` | the frontend's notification queue |
| `src/frontends/terminal/pane_osc.zig` | OSC 9 / 99 / 777 from panes |
| `src/frontends/terminal/startup_chooser.zig` | the questions bare `hexe` asks |
| `src/cli/pop_handlers.zig`, `src/cli/app.zig` | `hexe popup notify/confirm/choose` |
