# Reading what already happened

Four ways to get at output that has scrolled past: search the pane's scrollback, walk it with a
keyboard cursor, select it with the mouse, and — if your shell marks its prompts — jump between
commands and copy one command's output whole.

```lua
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.f }, hexe.action.search.enter()),
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.y }, hexe.action.copy.enter()),
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.c }, hexe.action.clipboard.copy()),
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.g }, hexe.action.prompt.previous()),
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.u }, hexe.action.prompt.copy_output()),
```

<!-- demo:begin -->
[![copy-and-search demo](https://asciinema.org/a/1263027.svg)](https://asciinema.org/a/1263027)
<!-- demo:end -->

## How it works

### Search

```
Ctrl+Alt+F ──> typing phase ──Enter──> results phase ──> n / Enter  next
                    │                        │            N / p     previous
                   Esc                      Esc / q       Esc / q   leave
```

Search runs over the pane's **whole scrollback**, not the visible screen: it builds a Ghostty
screen search, jumps the viewport to the first hit, and keeps a list of the matches currently on
screen so the renderer can highlight them without re-scanning every frame. Queries are capped at
256 characters and highlighting at 256 visible matches per screen, which is a dense-page limit
rather than a match limit.

The state machine is deliberately explicit: it holds a screen pointer and tracked pins into the
pagelist while it is active, so it is torn down on every pane-lifecycle change rather than left to
be tidied later.

### Copy-mode

A keyboard cursor over the focused pane, with the keys you expect:

| | |
|---|---|
| `h` `j` `k` `l` or the arrows | move |
| `v` or `Space` | start / stop selecting |
| `y` or `Enter` | yank the selection and leave |
| `q` or `Escape` | leave |

While copy-mode is active it swallows every key, which is what makes it a mode rather than a set of
bindings. The yank goes to the system clipboard through OSC 52 — so it works over ssh, where a
local clipboard tool would not.

### Mouse

Dragging selects, and the selection is pane-local. In a pane running a mouse-aware application (SGR
1006 tracking) the mouse belongs to the application instead — hold the override chord, Ctrl+Alt by
default, to take it back for a selection.

```lua
mux = { mouse = { selection_override = { "ctrl", "alt" } }, selection_color = 238 },
```

### Prompt marks

If the shell emits OSC 133 — marking where a prompt starts, where the command begins, and where its
output ends — then hexe can navigate by *command* rather than by line:

| | |
|---|---|
| `prompt.previous()` / `prompt.next()` | scroll to the previous or next prompt mark |
| `prompt.copy_output()` | copy the last marked command's output to the clipboard |

`copy_output` walks the rows backwards through the semantic-prompt states — input, command,
output — finds the boundary of the last command's output, selects it, and copies it. No mouse, no
scrolling, no accidentally including the prompt line.

## What makes it different

tmux's copy-mode is the ancestor of the keyboard half here, and hexe's is deliberately smaller:
one cursor, one selection, `v`/`y`, no vi/emacs key tables, no copy-buffer stack. What hexe adds is
around the edges:

- **Search is over the pagelist, not the visible screen**, and highlights every match in view.
- **The clipboard is OSC 52**, so a yank in a session on a remote machine lands in your local
  clipboard with nothing installed on either end.
- **Prompt marks are first-class**: jumping by command and copying a command's output are actions
  you can bind, where tmux would need a script over `capture-pane`.
- **There is no paste buffer.** `clipboard.request()` asks the terminal for the system clipboard;
  hexe does not keep its own registers.

## Configuration

| | |
|---|---|
| `hexe.action.search.enter()` | scrollback search |
| `hexe.action.copy.enter()` | keyboard copy-mode |
| `hexe.action.clipboard.copy()` | copy the current selection (mouse or copy-mode) |
| `hexe.action.clipboard.request()` | ask the terminal for the clipboard, i.e. paste |
| `hexe.action.prompt.previous()` / `.next()` | jump between OSC 133 prompt marks |
| `hexe.action.prompt.copy_output()` | copy the last command's output |
| `mux.selection_color` | the selection highlight |
| `mux.mouse.selection_override` | the chord that takes the mouse back from an application |

oslo emits OSC 133 on every prompt on its own, which is why the recording above can jump between
commands with nothing configured. To get the same in bash, the shell has to emit the marks itself —
hexe's bash integration does not:

```sh
PS1='\[\033]133;A\007\]…your prompt…\[\033]133;B\007\]'
__mark_precmd() { printf '\033]133;D;%s\007' "$?"; }
PROMPT_COMMAND=__mark_precmd
trap 'printf "\033]133;C\007"' DEBUG
```

## Measurements

- **Query length: 256 characters.**
- **Highlighted matches per screen: 256.** Beyond that the matches exist and are navigable; they
  are not all painted.
- **Clipboard payload: 128 KiB**, which is the OSC 52 ceiling hexe will emit (about 171 KiB once
  base64-encoded).

## What it cannot do

- **No OSC 133 from hexe's bash, zsh or fish integrations.** They emit OSC 7 only, so the three
  prompt actions do nothing until the shell marks its own prompts — oslo does it natively.
- **Copy-mode has no vi or emacs key table**, no word motions, no line jumps, no search *inside*
  copy-mode.
- **Search does not do regular expressions** and does not persist a query between sessions.
- **One selection at a time**, and it is per pane.
- **Clipboard depends on the outer terminal.** OSC 52 has to be permitted by it; a terminal that
  refuses clipboard writes silently drops the yank.
- **`clipboard.request()` is a request.** If the terminal will not answer, nothing is pasted.
- **Nothing is copied to a hexe-side buffer**, so there is no history of past yanks.

## Where it lives

| | |
|---|---|
| `src/frontends/terminal/pane_search.zig` | the search state machine over `ghostty.search.Screen` |
| `src/frontends/terminal/state.zig` | copy-mode: `enterCopyMode`, `copyMove`, `copyToggleSelect`, `copyYank` |
| `src/frontends/terminal/loop_input.zig` | the modal key routing for search and copy-mode |
| `src/frontends/terminal/mouse_selection.zig`, `loop_mouse.zig` | mouse selection and the override chord |
| `src/frontends/terminal/prompt_navigation.zig` | OSC 133 jumping and `lastOutputAlloc` |
| `src/frontends/terminal/mouse_protocol.zig` | forwarding mouse events to applications that want them |
| `src/core/constants.zig` | `max_clipboard_bytes`, `max_clipboard_osc_bytes` |
