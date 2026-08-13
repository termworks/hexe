# Recording

Hexe writes asciicasts of itself. Not a screen capture and not a wrapper around another tool — the
bytes are already flowing through a pod, so recording is a matter of writing a second copy of them
with timestamps. Every recording in this documentation was made this way.

```sh
hexe record start --scope pod --out /tmp/pane.cast
hexe record status --scope pod
hexe record stop  --scope pod
```

<!-- demo:begin -->
[![recording demo](https://asciinema.org/a/1263011.svg)](https://asciinema.org/a/1263011)
<!-- demo:end -->

## How it works

There are two scopes and three doors.

```
--scope pod        one pane's PTY stream          the shell, its output, its resizes
--scope mux        a whole frontend attach        every pane, the status bar, the floats
```

| | |
|---|---|
| `hexe record start/stop/status/toggle` | background recording; a state file remembers the pid |
| `hexe pod record --out f.cast` | observe one pod and write a cast — *without* replacing its VT client |
| `hexe terminal record --out f.cast` | attach to the frontend through a recorder and write what it draws |

`pod record` is the interesting one: it connects as an observer, so the pane keeps its normal
attachment and you get a recording of what it is doing while you keep using it.

The output is asciicast v2 — a JSON header, then one `[time, "o", data]` line per chunk of output.
With `--capture-input`, keystrokes are written as `"i"` events beside them, which is what makes a
recording replayable as a transcript of what was *typed*, not only what appeared.

Background recordings keep a small state file, `/tmp/hexe/<instance>/record-<scope>.state`, holding
the pid, target, output path and start time. That is what `record status` reads, what stops a
duplicate `start` from launching a second recorder, and what a status-bar button queries.

### A button in the status bar

Because the state is queryable, recording can live in the bar (see [the status bar](statusbar.md)):

```lua
{
  name = "rec",
  render = function(_)
    local st = hexe.status.recording("pod")
    return { { text = st and st.active and " REC " or " rec ", style = "bg:1 fg:15 bold" } }
  end,
  button = {
    on_left_click  = function(ctx)
      local rec = hexe.record.active(ctx, { scope = "pod", out = "/tmp/hexe-active-pod.cast" })
      return rec and rec.switch() or nil
    end,
    on_right_click = function(_) return hexe.record.stop({ scope = "pod" }) end,
    active_when    = function(_) local st = hexe.status.recording("pod"); return st and st.active end,
  },
}
```

`hexe.record.target(target, defaults)` and `hexe.record.active(ctx, defaults)` return
`{ start, stop, toggle, status, switch }`; `switch()` is start-or-move-to-this-pane, which is what
you want from a single button.

### Finding the pane

With no explicit target, `--scope pod` resolves the active pod: `HEXE_PANE_UUID` from the
environment first, then `hexe terminal info --last`. Inside a pane that means "record me" needs no
arguments at all.

## What makes it different

`asciinema rec` records a *terminal*: it puts a pty between you and your shell and writes what
passes through. That is exactly right for one shell and awkward for a multiplexer — the recorder
has to be started before the thing being recorded, and it cannot see inside panes.

Hexe records from where the bytes already are:

- **A pane can be recorded after the fact**, from another window, without restarting anything.
- **A pane can be recorded while attached**, because `pod record` observes rather than attaches.
- **Whole-frontend recording captures the multiplexer**: floats, the status bar, tab switches.
- **It is scriptable and stateful**: `start`, `status`, `stop`, and a state file a status bar can
  read.
- What asciinema gives you instead: the upload half, the player, and a format hexe is only writing.
  `asciinema upload` is still how a cast ends up on a page.

## Configuration

| | |
|---|---|
| `--scope pod \| mux` | one pane, or a whole frontend attach (`mux` is the legacy name for the frontend scope) |
| `--uuid <u>` / `--name <n>` / `--socket <path>` | which pod, when it is not the active one |
| `--out <file.cast>` | defaults: `/tmp/hexe-pod.cast`, `/tmp/hexe-mux.cast` |
| `--capture-input` | also record keystrokes as `"i"` events |

The documentation's own recordings are made by a harness in [`scripts/demo`](../scripts/demo/):
a fixture builds a deterministic world, `record.py` starts a real frontend on a pty and types into
it, `publish.sh` uploads, `embed.sh` puts the player in the document.

```sh
make demo-fixture                       # build /tmp/hexe-demo-work
make demo-record DEMO=floats            # one film
make demo-record                        # all of them
scripts/demo/frame.py /tmp/hexe-demos/floats.cast 12.5   # what the screen looked like at 12.5s
```

## Measurements

- **Asciicast v2**, with millisecond timestamps: `[1.234, "o", "…"]`.
- **State file per instance and scope**: `/tmp/hexe/<instance>/record-<scope>.state`.
- **A `pod record` observer costs one more socket connection** and a copy of the byte stream; it
  does not touch the pane's own VT client.

## What it cannot do

- **Nothing is recorded retroactively.** The pod's backlog ring is not written into a cast; a
  recording starts when you start it.
- **`terminal record` starts its own attach.** It spawns `hexe terminal attach` inside a pty and
  records that, so it is a second view of the session rather than a tap on the one you are using.
- **No trimming, no editing, no upload.** Hexe writes the file; `asciinema upload` publishes it.
- **A recording holds an output stream, not a screen.** Replaying it needs a terminal or a player,
  which is the same trade the pod's backlog makes.
- **`--capture-input` records everything you type**, including anything you type into a password
  prompt. The pod's password mode protects the *backlog*, not a cast you asked for.
- **One background recording per scope per instance.** A second `start` reports the running pid
  rather than opening a second file.

## Where it lives

| | |
|---|---|
| `src/core/recording/asciicast.zig` | the v2 writer: header, `o`/`i` events, timestamps |
| `src/cli/commands/record_ctl.zig` | `start`, `stop`, `status`, `toggle`, and the state file |
| `src/cli/commands/pod_record.zig` | the observer that does not displace the VT client |
| `src/cli/commands/mux_record.zig` | `hexe terminal record` |
| `src/core/api_bridge_record.zig` | `hexe.record.*` and `hexe.status.recording` for config |
| `scripts/demo/` | the harness that made every film in these documents |
