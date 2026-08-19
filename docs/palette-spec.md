# Palette namespaces — implementation spec

How the feature works underneath, for someone reimplementing it elsewhere or
writing a client against the protocol. [palette.md](palette.md) is the user
documentation; this is the mechanism, the wire format, and the traps.

---

## 1. The idea

A terminal has one 256-colour palette. Every cell that says "colour 4" gets the
same blue, whether it is part of your prompt, the output of a command, or a
full-screen editor.

Palette namespaces make the palette a function of *where* a cell is, not just
what index it names. A cell in the prompt resolves index 4 against the prompt's
table; a cell in command output resolves the same index against a different
table. Repaint one table and only that region changes — on screen and in
scrollback, with no redraw from the application.

Nothing is reserved. All 256 indices stay available in every namespace, and no
application has to change to benefit.

**The invariant everything rests on:** namespace 0 is the terminal's ordinary
palette, and cells resolved against it are emitted byte-for-byte as they are
today. Every failure — unknown name, exhausted table, truncated replay, feature
disabled, a shell with no integration — lands on namespace 0. That is why the
feature ships enabled by default: when nothing is configured, nothing changes.

---

## 2. Why the obvious design is wrong

The natural plan is to find where the terminal converts an indexed colour to RGB
and route that lookup through a per-namespace table.

**In a multiplexer that lookup does not exist.** hexe renders into another
terminal and never resolves indices: it passes the index through
(`ESC[38;5;33m`) and the *host* terminal resolves it against the user's own
theme. There is nothing to intercept.

Three consequences define the implementation:

- **You are introducing resolution, not redirecting it.** A namespaced cell must
  be emitted as truecolor `ESC[38;2;r;g;b`, because the host cannot know hexe's
  tables.
- **Namespace 0 must never be resolved.** Resolving it would override the user's
  terminal theme for every indexed cell in every pane, the moment the code
  compiled in.
- **Degradation is therefore free.** "Falls back to slot 0" and "looks exactly
  as before" become the same sentence.

Implementing this inside an emulator that *does* own the index→RGB step is
easier: swap the palette pointer and skip the truecolor emission. Everything
else below still applies.

---

## 3. Data model

One table per pane. Slots are a `u8`, so 256 of them, with 0 reserved.

```zig
const MAX_NS      = 256;   // slot fits a u8; 0 is the ordinary palette
const STACK_DEPTH = 16;    // spec floor is 8
const MAX_NAME    = 32;

Palette {
    entries: [256]RGB,        // the colours
    patched: [256]bool,       // which ones were actually set  <- critical
    fg:      ?RGB,            // zone default for cells naming no colour
    bg:      ?RGB,
    cursor:  ?RGB,
}

NamespaceTable {
    palettes:     [256]?*Palette,     // lazily allocated, ~1 KB each
    names:        Map(string -> u8),

    // what an app selected, and how to undo it
    stack:        [16]StackEntry,
    stack_len:    u8,
    current:      u8,
    overrides:    [4]u8,              // per auto-namespace
    override_set: [4]bool,            // <- slot 0 cannot mean "unset"

    // alt-screen parking
    saved_stack:  [16]StackEntry,
    saved_len:    u8,
    saved_cur:    u8,
    saved_over:   [4]u8,
    saved_oset:   [4]bool,
    saved:        bool,

    auto_slots:   [4]u8,              // default/prompt/output/alt
    enabled:      bool,
    osc:          u32,                // configurable sequence number
}
```

Memory is trivial: a populated namespace is 256x3 bytes of colour plus a
256-byte mask, about 1 KB. A realistic pane holds four to six.

### The `patched` mask is not optional

It records which indices a `set` actually named. Without it a freshly created
namespace resolves all 256 indices against a zero-initialised table and **paints
its entire region black the moment the feature turns on**. With it, an index
nobody named passes through to the terminal's own theme — which is what makes
"set is a patch" a safety property rather than a convenience.

Use a flat `[256]bool`, not `[256]?RGB`: it keeps the hot path one indexed load
and a branch instead of an optional unwrap.

---

## 4. Resolution

Runs per cell, per frame. It must stay a compare and a flat array index — no
hashing, no allocation, no map lookup.

```zig
Resolved = union { passthrough: u8, rgb: RGB }

inline fn resolveIndex(t, ns: u8, idx: u8) Resolved {
    if (ns == 0)              return .{ .passthrough = idx };   // 1
    const p = t.palettes[ns] orelse
                              return .{ .passthrough = idx };   // 2
    if (!p.patched[idx])      return .{ .passthrough = idx };   // 3
    return .{ .rgb = p.entries[idx] };
}
```

Each branch is a distinct failure mode collapsing to the same safe answer:

1. The common case. Most cells are in namespace 0 and return before touching the
   table at all.
2. The name was never defined — a truncated replay, or a client that skipped the
   capability query and guessed.
3. The namespace exists but never claimed this index.

The namespace is looked up **once per row**, not per cell, and passed down:

```
for each row:
    ns       = namespaceForRow(row)          // one lookup
    defaults = t.defaultsFor(ns)             // fg/bg for this zone
    for each cell in row:
        style.fg = switch (cell.fg) {
            .none    => defaults.fg,                 // zone default
            .palette => resolveIndex(t, ns, idx),
            .rgb     => passthrough,                 // truecolor: never namespaced
        }
```

Truecolor cells are deliberately excluded. A cell holding `38;2;r;g;b` has its
RGB baked in; an application that hardcodes hex has already opted out of
theming.

---

## 5. Zone detection

The feature would be useless if every application had to opt in. It doesn't,
because terminals already track semantic zones: **OSC 133** shell integration
marks where the prompt starts, where input begins, and where output runs. Most
emulators store that per row (ghostty: `Row.semantic_prompt`).

| Signal | Namespace | Why |
|---|---|---|
| OSC 133 `A`→`C` | `prompt` | The prompt line and the command typed on it |
| OSC 133 `C`→`D` | `output` | What the command printed |
| Alt-screen active | `alt` | A full-screen app owns the whole grid |
| anything else | `default` | Slot 0 — the terminal's own palette |

Two rulings worth copying:

- **The input zone joins `prompt`,** not its own namespace. The line you type on
  is visually part of the prompt line; colouring one half and not the other
  splits a single visual line.
- **Alt-screen beats the row's zone.** A full-screen app owns the grid, and any
  OSC 133 marks underneath belong to the shell it covered.

### Why rows, not cells

Reading the zone off the row means the terminal's existing row metadata does all
the work: it already survives scrollback, reflow and resize. A repaint therefore
reaches history as well as the visible screen, for free, with zero per-cell
storage.

The alternative — a namespace byte on each cell, or on the interned style —
costs memory across the whole scrollback and, in a mux consuming an upstream VT
library, requires forking that dependency. Start with rows; you may never need
cells.

The cost of that choice: `use`/`end` can only rebind a whole zone, not a run of
cells inside a row. For a full-screen application — the case the verb exists for
— the two are identical.

---

## 6. Defaults and cursor

### `fg` and `bg` — cells that name no colour

Most cells specify no colour at all. Indexed entries never touch them, so a
namespace also carries a default foreground and background, applied on the
`.none` arm of the colour switch.

One non-obvious consequence: renderers normally **skip blank, unstyled cells**
as an optimisation. Keep that skip and a background paints behind glyphs while
leaving the spaces between them at the terminal's colour — a striped mess.
Bypass the skip for rows whose namespace defines a background, gated so every
other pane keeps the fast path:

```zig
if (cell_is_blank_and_unstyled and row_defaults.bg == null) {
    continue;   // normal fast path, unchanged for everyone else
}
```

### `cursor` — the one thing you cannot paint

hexe positions the *host terminal's real cursor*; it is not a cell it draws. So
a per-zone cursor colour cannot go through the resolution path — it is pushed to
the host with `OSC 12` and taken back with `OSC 112`.

Three rules make that safe:

- **Follow the cursor's own row,** using the same zone lookup as the renderer.
- **Emit only on change.** OSC 12 is global to the terminal; re-sending per frame
  is a firehose. Moving within one zone emits nothing.
- **Restore on exit — but only if you ever set it.** A bare reset on teardown
  would clobber a colour the user's own terminal config chose.

A cursor colour only appears in zones the shell actually marks. Without OSC 133
integration every row is `default` = slot 0, which holds no colours by design.

---

## 7. Wire protocol

One OSC number, verb as the first parameter. Default **1330**, adjacent to
OSC 133 whose zones it builds on.

| Sequence | Direction | Meaning |
|---|---|---|
| `OSC 1330 ; use ; <name> ST` | app→term | Push `<name>` as current, creating it if new |
| `OSC 1330 ; end ST` | app→term | Pop. An empty stack is a no-op, not an error |
| `OSC 1330 ; set ; <name> ; <k>=<colour> [; …] ST` | app→term | Patch entries. Creates if new; does not select |
| `OSC 1330 ; drop ; <name> ST` | app→term | Release the binding, keeping the colours |
| `OSC 1330 ; reset ; <name> ST` | app→term | Forget the colours, keeping the namespace |
| `OSC 1330 ; ask ST` | app→term | Capability query |
| `OSC 1330 ; have ; <osc> ; <free> ST` | term→app | The only reply. Silence means unsupported |

### Grammar

- **Names** match `[a-z0-9_.-]{1,32}`, case-insensitive. `default` is reserved
  for slot 0. `*` in a `set` or `reset` addresses every live namespace.
- **Keys** are a decimal index `0`–`255`, or `fg`, `bg`, `cursor`.
- **Colours** accept `#rrggbb`, `rrggbb`, or the `rgb:rr/gg/bb` form OSC 4 uses
  (1–4 hex digits per component, scaled to 8 bits).
- **Terminator** is `ST` (`ESC \`) or `BEL`.

### Rules that are easy to get wrong

- **`SGR 0` must not reset the namespace.** Programs emit `\e[0m` constantly.
  Namespace is sticky state, not an SGR attribute.
- **Alt-screen saves and restores the whole selection,** so an app that dies
  full-screen cannot leak its namespace into the shell underneath.
- **A full stack drops the push** rather than selecting without a restore point.
  Otherwise an app that overflows leaves its colours behind permanently.
- **Chunk `set` at 32 entries per sequence** — but that is advice to *senders*,
  whose other terminals may cap an OSC payload. A receiver accepts however many
  arrive; refusing the 33rd entry of a sequence that already arrived intact
  silently loses colours.
- **Every verb is idempotent.** Replaying `use nvim` twice yields one namespace.
  Slot numbers may differ between replays; nothing outside the terminal sees
  them.

Because every failure is benign, **a client may skip the capability query
entirely** and emit `use` optimistically. Correct behaviour requires no
negotiation. That is the difference between a protocol people adopt and one they
don't — preserve it in review.

---

## 8. Degradation

Write a test for each row. All of them reduce to slot 0.

| Situation | Result |
|---|---|
| Not hexe (any other emulator) | OSC unrecognised, discarded. Zero breakage |
| A multiplexer in between without passthrough | Sequence swallowed. Same as above |
| Pane detached when the app sends `ask` | No reply; the app times out and uses defaults |
| Scrollback ring truncated past a definition | Unknown slot resolves against slot 0 |
| All 256 slots in use | `use` silently maps to slot 0 |
| Client emits the wrong OSC number | Unrecognised, discarded |
| Shell without OSC 133 integration | Every row is `default`; nothing changes |
| Feature disabled in config | Namespace forced to 0; indirection still compiled in |

---

## 9. Persistence

If your terminal has no session persistence, skip this — the table lives and
dies with the pane.

If it does, there is a tempting shortcut: the palette sequences are already in
the pane's byte stream, so a reattach replays them and the colours come back for
free.

**That shortcut does not hold.** A scrollback ring is not a store. Two things
destroy it:

- A **clear-screen** empties the ring, taking every palette definition with it.
- **Truncation**: enough output and the definition scrolls out.

Park the state as structured session metadata instead. The daemon stores and
returns an opaque blob and never parses a byte of it, which keeps the "SES must
not learn what VT bytes mean" boundary intact.

```
  app: printf ─────┐
                   ├──► pod ──► frontend ──────────► host terminal
  hexe palette set ┘   (ring)      │
                          ▲        │  parse OSC 1330 -> NamespaceTable
                          │        │
       cleared by `clear` │        └── park (structured) ──► SES
    truncated by volume   │                                   │
                          └──────── restore on attach ────────┘
```

Both the application and the CLI enter through the same byte path, so there is
one parser and one code path. Persistence is the side channel: the frontend
parks a structured copy and restores from it, because the ring in the middle is
destroyed by a clear-screen.

### Blob format

Versioned, length-prefixed, bounded. **One parser for both directions** —
`palette.BlobReader` serves `applySerialized` and the CLI, because two
hand-rolled readers of the same layout is how a format grows divergent bugs.

```
u8   version                       // reject unknown: restore nothing
u8   namespace_count
  per namespace:
    u8    name_len                 // 1..32
    ...   name
    u16   entry_count  (big endian, <= 256)
      per entry: u8 index, u8 r, u8 g, u8 b
    4B    fg      (present:u8, r, g, b)
    4B    bg
    4B    cursor
```

Carry **colours only**. The stack, the current selection and the overrides
describe what a *running program* selected and must not outlive it — restoring
them would reinstate a dead app's namespace under the shell that replaced it.

Bound the writer at the transport's payload cap. The receiver refuses an
oversized blob wholesale, so an unbounded writer means a pane with many
populated namespaces persists *nothing* — losing every colour instead of the
excess.

---

## 10. Traps

Each of these was a real defect. Most produced no error — just wrong colours, a
frozen UI, or silence.

**Unpatched entries must pass through.**
*Symptom: every prompt row turns black the moment the feature is enabled.* A new
namespace is zero-initialised; resolve unset indices and you paint the region
black. Test it explicitly: *enabling with no palette set changes nothing on
screen*.

**Slot 0 cannot double as "unset".**
*Symptom: `use default` silently selects the wrong table.* If the per-zone
override array uses 0 for "no override", selecting `default` — a legitimate
choice meaning "the ordinary palette" — is indistinguishable from selecting
nothing. Carry an explicit `override_set` flag.

**Reserved OSC numbers.**
*Symptom: the user's base palette stops working after a config change.* The
dispatch checks the configured number *before* the ordinary families, so
`palette.osc = 4` hijacks OSC 4 — the sequence that sets the base palette this
feature layers on. Refuse anything the terminal already forwards or consumes:
`0–2, 4, 5, 7, 9, 10–19, 50–59, 99, 104, 105, 110–119, 133, 777`.

**Never read the control socket synchronously from the event loop.**
*Symptom: the entire UI stops rendering.* Fetching persisted state inline from a
timer tick raced the event loop's own reader on the same fd, desynchronised it
and froze rendering — from a feature that is supposed to be cosmetic. Make it
fire-and-forget with the answer arriving as an ordinary control event.

**Answer a fire-and-forget request with an unstamped push.**
*Symptom: the reply is sent, and never arrives.* Replies are tagged with the id
of the request being serviced; one that matches no in-flight synchronous request
gets parked in the by-request-id queue and never claimed. Use `notifyOrClose`,
not `replyOrClose` — and add the message type to the replayable-push list so a
synchronous reader preserves it instead of dropping it.

**The blank-cell skip defeats background colours.**
*Symptom: a background colours the glyphs and stripes the gaps.* See §6.

**Reset on identity change — and only on identity change.**
*Symptom: a recycled pane wears the previous pane's colours.* Reattach recycles
Pane structs, so rebinding one to a different pane must clear its table. But the
same call fires on the common reattach path with an *unchanged* uuid, where
clearing throws away live state. Compare first, then reset.

**The byte ring is not a store.**
*Symptom: colours vanish after a clear-screen and a reattach.* See §9. Invisible
until someone detaches, which is the wrong time to find out.

**A `u8` counter cannot be bounded by 256.**
*Symptom: an infinite loop in the OSC path, release builds only.*
`while (slot < 256)` with a `u8` slot is always true; the real bound becomes an
interior guard and the increment at 255 wraps. Use a wider counter.

**Use the bounded read helpers.**
*Symptom: a ten-second UI stall per frame under a stalled peer.* Raw wire
helpers carry the 10-second default. In a frame path that is a freeze. Use the
timed variants the file already established — check the neighbouring handlers
before writing a new one.

**Fail fast on the sweep, not per item.**
*Symptom: a "capability probe" that hangs for minutes.* A listing that opens one
connection per pane at a 3-second timeout takes minutes on a large session with
a wedged daemon. Latch the first failure and stop asking; this command runs from
a theme hook on every change.

---

## 11. Implementation order

Genuinely sequential — each step is independently shippable, and each exit
criterion protects the next.

| # | Step | Exit criterion |
|---|---|---|
| 1 | Answer where indexed colour becomes RGB; measure a frame-time baseline | A written answer and a number to compare against |
| 2 | Add the table and route resolution through it, namespace hardcoded to 0 | **Nothing looks different.** Frame time within noise. If this regresses, abandon here |
| 3 | Assign namespaces from OSC 133 zones and alt-screen | Poke a palette in a test and watch one zone change — in screen *and* scrollback |
| 4 | CLI: `set`, then `list`/`get` | Recolours a live pane and survives detach/reattach |
| 5 | Wire protocol: `set` first, then `use`/`end`, then `drop`/`reset`/`ask` | A `printf` from inside the pane does what the CLI does |
| 6 | Make the CLI a front door — synthesise the sequence and inject it | One code path; replay and recording capture CLI changes for free |
| 7 | Lifetime, config, defaults on | Re-measure with the feature *enabled*, not just compiled in |

Step 6 is the one people skip. Making the CLI emit the same sequence an
application would — rather than mutating state directly — collapses two
implementations into one. Every bug fixed in the parser is fixed for both, and
anything that records or replays the byte stream picks up CLI-driven changes
with no extra work.

---

## 12. Client cookbook

Emit it directly:

```sh
# patch one index in the prompt zone
printf '\033]1330;set;prompt;33=#ff00aa\033\\'

# several at once, plus the zone defaults
printf '\033]1330;set;output;1=#ff5555;2=#50fa7b;bg=#0a0a0a\033\\'

# every live namespace
printf '\033]1330;set;*;33=#ff00aa\033\\'

# claim one, then release it
printf '\033]1330;use;nvim\033\\'
printf '\033]1330;end\033\\'

# is anyone listening?  (optional — you may skip this entirely)
printf '\033]1330;ask\033\\'
```

A theme hook that works in and out of hexe — see
[`contrib/palette_hook.sh`](../contrib/palette_hook.sh):

```sh
COLORS="$HOME/.cache/wal/colors"

# The base palette, for every terminal. OSC 4 is forwarded by the mux, so this
# is what recolours ordinary cells in or out of it.
i=0
while IFS= read -r line; do
    case "$line" in
        '#'??????)
            printf '\033]4;%d;%s\007' "$i" "$line" > /dev/tty
            i=$((i + 1)) ;;
    esac
done < "$COLORS"

# Capability probe: non-zero outside a session. No negotiation, nothing to
# time out on.
hexe palette list >/dev/null 2>&1 || exit 0

# Inside: zone overrides on top of the base palette.
hexe palette set --ns prompt bg=#1a1020
hexe palette set --ns alt    bg=#000000
```

**Two layers, and it matters which is which.** `OSC 4` sets the base palette for
*all* cells and is forwarded to the real terminal. `OSC 1330` adds per-zone
overrides on top. A hook that only does the second changes nothing on a shell
without OSC 133 integration.

Broadcasting to every pane, for experiments:

```sh
for tt in /dev/pts/*; do
    printf '\033]1330;set;prompt;33=#ff00aa\033\\' > "$tt" 2>/dev/null
done
```

Writing to a pty *slave* makes the bytes appear as if the program had written
them, so they flow through the ordinary output path. The CLI is the supported
route.

---

## 13. Performance

Measured end to end by `scripts/bench_render.py` — absorb plus render of 4000
rows x 100 indexed-colour cells (8.45 MiB of SGR), ReleaseFast, through a real
pty:

| Configuration | Throughput | Per row |
|---|---|---|
| Baseline, before the feature existed | 2.09 – 2.20 MiB/s | 0.96 – 1.01 ms |
| Compiled in, namespace pinned to 0 | 2.14 – 2.31 MiB/s | 0.91 – 0.99 ms |
| Fully enabled, zones live | 2.13 – 2.32 MiB/s | 0.91 – 0.99 ms |

Inside noise on both sides. That is the payoff for the two structural choices:
the namespace is looked up once per row rather than per cell, and the per-cell
addition is a compare plus a flat array index whose common case returns before
touching the table.

Measure *before* you enable, not after. Step 2 exists so a regression kills the
feature while it is still three files, not after the protocol has shipped.

---

## What it cannot do

- **No cell-level selection.** `use`/`end` rebind a whole zone, not a run of
  cells inside a row. Cell precision needs the namespace on the interned style
  inside ghostty, which hexe consumes as a read-only dependency (§5).
- **Truecolor cells are never namespaced,** deliberately. `38;2;r;g;b` has its
  RGB baked in.
- **Nothing but `alt` works without OSC 133.** A shell with no integration puts
  every row in `default` = slot 0, which holds no colours.
- **`reset` is whole-namespace.** There is no way to un-set a single index; the
  protocol has no per-entry delete.
- **The cursor colour is one colour at a time,** because OSC 12 is global to the
  terminal, and it only appears in marked zones.
- **`get` and `list` are about a second stale,** and report nothing for a pane
  whose frontend has not run since the colour was set — they read the daemon's
  parked copy, not the live table.
- **Palettes do not survive the daemon being replaced.** They are parked in SES
  but not written to its state file, and a full frontend recovery builds a new
  session anyway.
- **Nothing works outside hexe.** By design: the sequences are unrecognised
  elsewhere and discarded.

## Where it lives

| Path | What |
|---|---|
| `src/core/palette.zig` | Table, resolution, OSC parsing, blob format |
| `src/frontends/terminal/vt_bridge.zig` | Per-row zone lookup, cell resolution, defaults |
| `src/frontends/terminal/pane_output.zig` | OSC dispatch, alt-screen save/restore |
| `src/frontends/terminal/loop_render.zig` | Cursor colour (OSC 12) |
| `src/frontends/terminal/state_sync.zig` | Parking and restoring via SES |
| `src/modules/session/server_pane_meta_handlers.zig` | Daemon-side store and fetch |
| `src/cli/commands/palette.zig` | `hexe palette` |
| `scripts/smoke_palette.py`, `scripts/smoke_palette_persist.py` | Live coverage |
