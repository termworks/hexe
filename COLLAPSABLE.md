# Collapsible command output — the protocol hexe would implement

oslo now emits semantic marks saying where each command's output begins and ends. This document is
what a hexe-side implementation needs: the exact bytes, the state machine, and the things that will
bite.

## Why this lives in hexe and not in the shell

A shell cannot rewrite scrollback. Once bytes are written they belong to whatever owns the grid;
folding a command that has scrolled off means redrawing rows the shell can no longer reach. This was
tried in oslo and removed: it could fold only the most recent command, only while it was still on
screen, and it could not be clicked — because a terminal stops delivering mouse events to the
application the moment the user scrolls back.

**hexe owns the grid and the history, so hexe is the layer that can do this.** Warp works exactly
this way: the shell declares boundaries, the emulator keeps a grid per command and folds it. The
same split applies here, with one advantage — implemented in hexe, folding works for *every* shell
run in a pane, not only oslo.

## What oslo emits

`OSC 133`, the FinalTerm/FTCS shell-integration protocol that kitty, WezTerm, Ghostty, iTerm2,
VS Code and tmux already read. Implementing it means hexe also gains prompt-jumping and
output-selection for fish, zsh and nushell, which emit the same marks.

| Bytes | When | Meaning |
|---|---|---|
| `ESC ] 133 ; A ; aid=<n> ESC \` | before the prompt is drawn | prompt starts; a new block begins |
| `ESC ] 133 ; C ; aid=<n> ESC \` | just before the command runs | output starts here |
| `ESC ] 133 ; D ; <status> ; aid=<n> ESC \` | when it finishes | command ends, with its exit status |

Terminated with ST (`ESC \`), not BEL. A parser should accept both — other shells use BEL.

Verified from a real oslo session:

```
printf 'a\nb\n'     →  C;aid=1   D;0;aid=1   A;aid=2
sh -c 'exit 7'      →  C;aid=2   D;7;aid=2   A;aid=3
```

### `aid=<n>` is oslo's addition

The standard three marks have no identity, so a reader must assume `A`/`C`/`D` arrive in order and
adjacent. `aid` is a monotonic per-session block id carried on all three, so a `D` can be matched to
the `A` that opened it without that assumption. Treat it as optional: a shell that is not oslo will
send `A`, `C` and `D` with no `aid`, and the fold feature should still work by nesting order.

### `B` is deliberately absent

`OSC 133;B` ("the prompt ends, typing starts") would have to be written between the prompt and the
cursor — inside the string handed to the line editor. The editor measures that string to know where
the line begins, and an OSC in it is counted as visible width, so the cursor arithmetic is wrong
from the first keystroke. `A`..`C` already delimits the prompt region, which is all a folding
implementation needs.

Do not require `B`. Other shells do send it; ignore it if present.

## The regions

For one block with id *n*:

```
  ESC]133;A;aid=n           ← prompt row starts here
  ~/project ❯ cargo build   ← prompt + the typed command
  ESC]133;C;aid=n           ← everything after this is OUTPUT
     Compiling oslo v0.1.0
     ... 410 more rows ...
      Finished in 18.2s
  ESC]133;D;0;aid=n         ← output ends here
  ESC]133;A;aid=n+1         ← the next block
```

**The foldable region is `C`..`D`.** The `A`..`C` rows are the prompt and command line, which stay
visible and are what the fold arrow attaches to. Fold = hide the `C`..`D` rows and draw a summary
in their place; unfold = show them again.

A summary worth drawing has the row count, the duration and the status — `▸ 412 lines · 18.2s`,
with a failure spelled out because a non-zero status must never be hidden by the fold.

## What will bite

**Full-screen programs.** `nvim`, `htop` and `less` switch to the alternate screen (`ESC [ ? 1049 h`)
and their output is a picture, not a transcript. Folding it is meaningless. Mark a block unfoldable
if `1049h` appears between its `C` and `D`. This matters more than it looks: the program that takes
the screen is very often not the one that was typed — `git log`, `man ls` and `systemctl status` all
hand over to a pager, so the command name cannot be used to predict it.

**Unclosed blocks.** A shell killed mid-command sends `C` with no `D`. Treat an `A` as implicitly
closing any open block, and never let a missing `D` leave the parser stuck.

**Marks split across reads.** `ESC]133;D;0;aid=17ESC\` can land on any buffer boundary. The OSC
parser must carry state across reads — the same requirement as any other OSC.

**Duplicate or absent `aid`.** Do not key internal state solely on `aid`. It resets when the shell
restarts, and a pane can outlive several shells.

**Resize.** Row counts in a folded summary are computed from the wrapped height at the time of
folding. On resize either recompute from the retained cells or state the count in *lines* rather
than rows — oslo's own summary counted newlines for exactly this reason, so the number does not
change when the window does.

**Scrollback eviction.** A block whose rows have aged out of hexe's scrollback can no longer be
unfolded. Either pin folded blocks' cells, or drop the fold state with the rows and stop offering
the arrow.

**Nothing to fold.** A command that printed nothing has `C` immediately followed by `D`. No arrow.

## Turning it on and off

oslo emits marks only when interactive **and** stdout is a terminal **and** `TERM` is not `dumb`.
A script, a `-c` command and every test binary emit nothing:

```
$ oslo -c 'echo hi'     →  b'hi\n'      (no marks)
```

That guarantee matters because oslo is meant to be a distro's `/bin/sh` — a program reading its
output must never find escape sequences the shell invented. Nothing needs to be configured to get
this; it is the default.

Note that hexe's `buildEnv` (`src/core/pty.zig`) already strips `TERM` per pane, so whatever hexe
sets for a pane decides whether marks appear. Setting it to `dumb` turns them off.

## Suggested order

1. **Parse and record.** Extend the OSC handler to recognise `133;A/C/D`, and store per block:
   start row, output-start row, end row, exit status, `aid`, and an `alt_screen` flag. Draw nothing
   yet. At this point prompt-jumping and "select this command's output" are already possible.
2. **Draw the arrow** next to each block's prompt row, and fold on click. Mouse coordinates are
   hexe's already, including while scrolled back — which is the whole reason this belongs here.
3. **Fold by default over N rows**, configurable, with an unfold-all. Worth doing last, once the
   first two have proven the boundaries are correct in practice.

## Source

The emitter is `src/interactive/marks.rs` in the oslo repo (`develop` branch), about 90 lines, with
the reasoning for each choice in its module docs. `src/startup/repl.rs` has the three call sites.
