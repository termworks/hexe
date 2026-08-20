# Palette namespaces — protocol

A private 256-colour table per *region of output*, where the program writing the
output decides what a region is.

A program claims a namespace, prints, and releases it. Every cell it wrote
remembers that namespace for as long as the cell exists. Repaint the namespace
later and exactly those cells change — on screen and in scrollback, with no
redraw from the program.

This document is what you implement against to emit the sequences. Everything
below is the wire contract; the hexe-specific parts are marked as such and are
not required to speak the protocol.

---

## 1. The model

The terminal holds the colours and resolves the indexes. It never decides which
cells belong to which namespace — the program says so, explicitly:

```
ESC ] 1330 ; use ; mine ST      program claims a namespace
...printing...                  every cell written now carries it
ESC ] 1330 ; end ST             program releases it
```

Three consequences worth internalising before you write a client:

- **The terminal does not infer regions.** Not from shell integration, not from
  alt-screen, not from anything on screen. If you do not select, nothing is
  namespaced.
- **The terminal does not release for you.** Select and exit without `end` and
  your namespace stays selected for whatever prints next in that pane. Release
  what you claim, the way you would restore any other terminal state.
- **Namespace `default` (slot 0) is the terminal's ordinary palette.** Every
  failure path lands there and emits your index untouched, so nothing you do can
  make output worse than not using the protocol at all.

Colour indexes are unchanged: all 256 stay available in every namespace, and
nothing is reserved.

---

## 2. Capability negotiation — and why you can skip it

```
ESC ] 1330 ; ask ST                     →  program asks
ESC ] 1330 ; have ; <osc> ; <free> ST   ←  terminal answers
```

`<osc>` is the OSC number in use, `<free>` the number of unclaimed namespaces.
**Silence means unsupported.** There is no negative reply, so a client must time
out rather than block.

Every failure in this protocol is benign, so **you may skip `ask` entirely** and
emit `use` optimistically. On a terminal that does not implement it the sequence
is discarded, and your indexed colours render exactly as they do today. Prefer
this: it needs no round trip and no timeout handling.

Query only when you want to *change behaviour* based on support — for example
choosing between namespaced colours and an `OSC 4` fallback.

> The reply arrives on **stdin**, like any other terminal query response. If you
> ask at a shell prompt without reading it, it lands in the shell's line buffer
> and garbles the next command — the same as `OSC 4` or `DSR`. One more reason
> to skip the query.

---

## 3. Wire protocol

One OSC number, verb first. Default **1330**.

| Sequence | Direction | Meaning |
|---|---|---|
| `OSC 1330 ; set ; <name> ; <k>=<colour> [; …] ST` | app→term | Patch entries. Creates the namespace; does **not** select it |
| `OSC 1330 ; use ; <name> ST` | app→term | Push `<name>` as current, creating it if new |
| `OSC 1330 ; end ST` | app→term | Pop. An empty stack is a no-op, not an error |
| `OSC 1330 ; drop ; <name> ST` | app→term | Stop applying it. Name and colours stay |
| `OSC 1330 ; reset ; <name> ST` | app→term | Forget its colours, keeping the namespace |
| `OSC 1330 ; ask ST` | app→term | Capability query |
| `OSC 1330 ; have ; <osc> ; <free> ST` | term→app | The only reply |

### Grammar

| Element | Rule |
|---|---|
| **Name** | `[a-z0-9_.-]{1,32}`, case-insensitive. `default` is reserved. `*` in `set`/`reset` addresses every live namespace |
| **Key** | decimal `0`–`255`, or `fg`, `bg`, `cursor` |
| **Colour** | `#rrggbb`, `rrggbb`, or `rgb:rr/gg/bb` (1–4 hex digits per component, scaled to 8 bits) |
| **Terminator** | `ST` (`ESC \`) or `BEL` (`\a`) |
| **Separator** | `;` — so a name or colour may never contain one |

### Verb semantics in detail

**`set`** is a *patch*, never a replacement. Indexes you do not name keep
passing through to the terminal's own theme, so a namespace with one entry set
does not blacken the other 255. It creates the namespace if new, and does **not**
select it — `set` then `use` are independent steps, deliberately, so a prompt can
define its colours once at startup and select them cheaply per prompt.

`fg` and `bg` are the namespace's defaults: what a cell that names *no* colour of
its own resolves to. `set --ns mine bg=…` therefore fills the blanks that program
wrote, not the whole screen.

`cursor` colours the terminal's own cursor while that namespace is selected. It
cannot go through cell resolution — the terminal pushes it out of band (hexe uses
`OSC 12`, restoring with `OSC 112`). It is one colour at a time, terminal-global.

**`use`** pushes onto a stack, so nesting works: an app inside an app inside a
prompt each restore correctly on `end`. The stack is at least 8 deep (hexe: 16).
**A full stack drops the push** rather than selecting without a restore point —
otherwise an overflowing app leaves its colours behind permanently.

**`end`** on an empty stack is a no-op, not an error. Send it freely.

**`drop`** stops a namespace applying but keeps the name bound and the colours
intact, because cells already drawn still reference it — releasing the binding
would let a later namespace take the slot and recolour history. `use` on the same
name brings it back unchanged.

**`reset`** is whole-namespace. There is no per-entry delete.

### Rules that are easy to get wrong

- **`SGR 0` does not reset the namespace.** Programs emit `\e[0m` constantly.
  Selection is sticky state, not an SGR attribute.
- **Every verb is idempotent.** Replaying `use mine` twice yields one namespace.
  This is what makes a session replay after reattach safe.
- **Chunk `set` at 32 entries per sequence.** Advice to *senders*: other
  terminals may cap an OSC payload. A receiver should accept however many arrive.
- **Truecolor is never namespaced.** `38;2;r;g;b` has its RGB baked in; a program
  hardcoding hex has already opted out.

---

## 4. Limits

| Limit | Value | Why |
|---|---|---|
| Namespaces per pane | **31** (plus `default`) | hexe stores the tag in spare bits of the cell's style, costing no memory; see [the patch](../patches/ghostty-vt-ns.patch) |
| Name length | 32 | |
| Stack depth | 16 (spec floor 8) | |
| Entries per `set` | 32 recommended | sender-side advice, not a receiver limit |

Exhausting namespaces is not an error: `use` maps to slot 0 and your output
renders with the terminal's own palette.

---

## 5. Degradation

Every row reduces to slot 0, which is "behave as though the protocol did not
exist". Write a test for each.

| Situation | Result |
|---|---|
| Any terminal without support | OSC unrecognised, discarded. Zero breakage |
| A multiplexer in between without passthrough | Sequence swallowed. Same |
| Pane detached when you send `ask` | No reply; time out and use defaults |
| Scrollback truncated past a definition | Unknown namespace resolves against slot 0 |
| All namespaces in use | `use` silently maps to slot 0 |
| Wrong OSC number | Unrecognised, discarded |
| Never selecting a namespace | Everything is `default`; nothing changes |
| Feature disabled | Namespace forced to 0, and `ask` goes unanswered so you see the truth |

---

## 6. Client cookbook

Straight from a shell:

```sh
# define once
printf '\033]1330;set;mine;1=#ff5555;2=#50fa7b;bg=#0a0a0a\033\\'

# claim, print, release
printf '\033]1330;use;mine\033\\'
printf 'index 1 resolves through `mine` \033[38;5;1mhere\033[0m\n'
printf '\033]1330;end\033\\'

# every live namespace at once
printf '\033]1330;set;*;33=#ff00aa\033\\'
```

A prompt (bash/zsh) — define at startup, wrap each prompt:

```sh
printf '\033]1330;set;prompt;1=#89b4fa;bg=#11111b\033\\'   # once, in your rc

PS1='\[\033]1330;use;prompt\033\\\]…your prompt…\[\033]1330;end\033\\\]'
```

Keep the sequences inside `\[ … \]` (bash) or `%{ … %}` (zsh) so the shell does
not count them as printable width.

A full-screen application:

```python
import sys

def osc(*parts):
    sys.stdout.write("\033]1330;" + ";".join(parts) + "\033\\")
    sys.stdout.flush()

osc("set", "myapp", "1=#ff5555", "4=#89b4fa", "bg=#101018", "cursor=#00ff88")
osc("use", "myapp")
try:
    run()
finally:
    osc("end")          # release even on crash
```

Re-theming live — no redraw, the existing cells repaint themselves:

```sh
printf '\033]1330;set;myapp;1=#00ff88\033\\'
```

**Two layers, and it matters which is which.** `OSC 4` sets the base palette for
*all* cells and is forwarded to the real terminal. `OSC 1330` adds per-namespace
overrides on top, applying only to cells written while that namespace was
selected. A hook that sets colours but never sends `use` changes nothing.

---

## 7. hexe specifics

Not part of the protocol — how this particular implementation is configured and
driven.

```lua
palette = {
  namespaces = true,   -- default; false restores pre-namespace behaviour
  osc = 1330,          -- the OSC number applications speak
},
```

`osc` refuses numbers hexe already forwards or consumes — 0–2, 4, 5, 7, 9,
10–19, 50–59, 99, 104, 105, 110–119, 133 and 777 — falling back to 1330 with a
warning. If you move it, hexe exports `HEXE_PALETTE_OSC` into every pane so
anything running there can build sequences on the right number.

The CLI is a front door onto the same sequences, so anything it does an
application can do, and changes made either way replay identically:

```
hexe palette list                                   # panes, and what each has set
hexe palette get                                    # every colour, every pane
hexe palette get --ns mine                          # one namespace
hexe palette get --ns mine 33                       # one index
hexe palette set --ns mine 33=#331111 bg=#0a0a0a
hexe palette set --ns mine --from ~/.cache/wal/colors
hexe palette use --ns mine                          # select, until `end`
hexe palette end
hexe palette drop --ns mine
hexe palette reset --ns mine                        # forget its colours
```

Colours survive a detach: they are parked in the session daemon, so a `clear` or
a busy pane cannot lose them.

### What it cannot do

- **`get` and `list` are about a second stale.** They read the daemon's parked
  copy, not the live table, and report nothing for a pane whose frontend has not
  run since the colour was set.
- **Palettes do not survive the daemon being replaced.** They are parked in SES
  but not written to its state file.
- **Nothing works outside hexe.** By design — elsewhere the sequences are
  discarded.
