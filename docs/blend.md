# Foreground colour mixing

OSC 1331 lets a program keep using ordinary ANSI colours while asking hexe to
mix each glyph's foreground with its cell background. The percentage is stored
with the cell, so repainting, resizing and scrollback retain the result.

```sh
printf '\033]1331;use;fg=30\033\\'
printf '\033[31msoft red\033[0m normal styles still work\n'
printf '\033]1331;end\033\\'
```

This is per-cell colour compositing. It does not change terminal-window
opacity, reveal a desktop background, or add an alpha channel to ANSI.

## Protocol

OSC 1331 is a Hexe-private protocol. Both ST (`ESC \\`) and BEL terminate a
request. Hexe emits ST in replies.

| Sequence | Meaning |
|---|---|
| `OSC 1331;use;fg=P ST` | push the current percentage and select `P` |
| `OSC 1331;end ST` | restore the previous percentage |
| `OSC 1331;reset ST` | clear every scope and restore 100% |
| `OSC 1331;refresh ST` | refresh host colours used by visible mixed cells |
| `OSC 1331;ask ST` | ask whether version 1 is supported |
| `OSC 1331;have;1;fg ST` | Hexe's capability reply |

`P` is a decimal integer from 0 through 100. It is the foreground's
contribution:

- 100 is the ordinary foreground;
- 30 is 30% foreground and 70% background;
- 0 is the effective background, leaving the glyph present but invisible.

For each encoded eight-bit sRGB component, Hexe calculates:

```text
(foreground * P + background * (100 - P) + 50) / 100
```

Division is integer division. The added 50 gives deterministic
round-to-nearest. Version 1 does not use linear-light or perceptual mixing.

Verbs and field names are ASCII case-insensitive. Leading zeroes are accepted.
Signs, fractions, exponent notation, spaces, empty percentages and values over
100 are rejected without changing state. Unknown fields are ignored; an
unknown verb is ignored.

Scopes nest to a depth of 16. A seventeenth `use` is ignored. `end` on an empty
stack leaves the percentage at 100.

## ANSI and OSC 1330

The percentage is independent of SGR. `SGR 0`, foreground resets, DEC cursor
save/restore, RIS and primary/alternate-screen switches do not end the scope.
Only OSC 1331 `end` or `reset` changes it.

For indexed colours, Hexe resolves values in this order:

1. an OSC 1330 namespace override carried by the cell;
2. the outer terminal's OSC 4 palette;
3. opaque indexed output when the RGB value is unavailable.

Default foreground and background values come from the outer terminal's OSC 10
and OSC 11 reports. Truecolour values need no palette lookup. Reverse video is
resolved before mixing and is not applied again by the outer terminal.

An outer terminal that does not answer a colour query does not block startup.
Until both source and background are known, Hexe emits the original opaque
style. It never guesses black or substitutes a built-in ANSI palette.

### Out-of-band palette changes

Programs such as pywal can write colour sequences directly to terminal PTYs.
Those bytes bypass Hexe, so Hexe cannot observe the change itself. Hexe polls
only the host colours used by visible mixed cells at a bounded 100 ms cadence
and repaints when their RGB values change. No polling occurs without a visible
mixed cell that depends on the host palette.

`OSC 1331;refresh ST` provides an immediate event when the palette tool runs
inside a Hexe pane:

```bash
printf '\033]1331;refresh\033\\'
```

OSC output is directional. A local pywal hook writing to the outer terminal of
an SSH connection cannot deliver this private request to the remote Hexe
frontend; the outer terminal receives and ignores it. The bounded polling path
handles that topology. A refresh emitted through Hexe is consumed without
altering the active mixing scope.

OSC 1331 is reserved. A configuration cannot use `palette.osc = 1331`; choose
another unreserved number such as 1332 when moving OSC 1330.

## Capability probing

Support-aware programs may send:

```sh
printf '\033]1331;ask\033\\'
```

Hexe replies with `OSC 1331;have;1;fg ST`. Silence means unsupported, so a
program must use a timeout rather than wait indefinitely. Programs that can
accept ordinary opaque fallback may skip the query and emit `use`
optimistically.

## Prompt delimiters

Readline and zsh need non-printing markers around OSC bytes in a prompt.

```sh
# bash
PS1='\[\e]1331;use;fg=45\e\\\]dim \[\e]1331;end\e\\\]$ '

# zsh
PROMPT='%{\e]1331;use;fg=45\e\\%}dim %{\e]1331;end\e\\%}%# '
```

## What it cannot do

- Version 1 cannot mix backgrounds, underline colours, cursor colours, images,
  selections or Hexe chrome.
- It cannot recover the true RGB value when the outer terminal does not answer
  OSC 4, 10 or 11.
- It does not persist a live scope as session metadata. Reattach reconstruction
  depends on the replay backlog still containing the controlling sequences.
- Other terminals are not expected to implement OSC 1331.

## Measurements

Measured on 2026-09-04 with a ReleaseFast GNU build and 30 runs of the same
8.45 MiB indexed-colour workload:

| build and mode | median | per row |
|---|---:|---:|
| clean `2744d6c`, opaque | 3.917 s | 0.979 ms |
| OSC 1331 build, opaque | 3.891 s | 0.973 ms |
| OSC 1331 build, every cell at 30% | 3.805 s | 0.951 ms |

The ordinary path changed by -0.66%, inside the 3% regression budget. Ghostty
`Style` remained 28 bytes before and after because the new byte occupies
existing trailing padding. Its packed hash representation remains 16 bytes,
`Cell` remains 8 bytes, and `Page` remains 376 bytes.

`oslo make bench-blend` measures the added colour-resolution and mixing work
for a fully mixed 50x200 viewport. Its 30-run ReleaseFast median was 0.055 ms
(range 0.055..0.058 ms), below the 16 ms frame budget without per-cell or
per-frame allocation.

## Where it lives

- `src/core/blend.zig` parses scopes and calculates RGB components.
- `src/core/vt.zig` applies the active percentage to both screen cursors.
- `patches/ghostty-vt-ns.patch` stores the percentage in interned cell styles.
- `src/frontends/terminal/pane_output.zig` consumes OSC 1331.
- `src/frontends/terminal/host_colors.zig` owns colour-query state and caching.
- `src/frontends/terminal/vt_bridge.zig` resolves and mixes displayed colours.

## References

- [Ghostty colour model](https://ghostty.org/docs/vt/concepts/colors)
- [Ghostty OSC 4](https://ghostty.org/docs/vt/osc/4)
- [xterm control sequences](https://www.invisible-island.net/xterm/ctlseqs/ctlseqs.html)
