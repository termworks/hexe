# PLAN: OSC 1332 — stretch lines

## Goal

A program marks where a line may stretch, and hexe fills that space to the
pane's width — at print time, after every resize, and for lines already in
scrollback.

```
---[ ls ]--------------------------------------------------------[ 18:50:59 ]---
```

Today a program repeats its rule to `tput cols` and the line is frozen at that
width: widen or shrink the pane and every old rule is wrong. With OSC 1332 the
program says "fill here with `-`" and hexe owns the width.

First user: oslo's transcript rule (`oslo.transcript.rule`, drawn by pixy).

## Protocol

Hexe-private, modelled on OSC 1331: ST (`ESC \`) or BEL terminates a request,
verbs are ASCII case-insensitive, unknown verbs and malformed requests are
ignored without changing state, replies use ST.

| Sequence | Meaning |
|---|---|
| `OSC 1332;ask ST` | ask whether version 1 is supported |
| `OSC 1332;have;1 ST` | hexe's reply |
| `OSC 1332;begin ST` | start a stretch line on the cursor row |
| `OSC 1332;fill;G ST` | a stretch point, filled by repeating the glyphs `G` |
| `OSC 1332;end ST` | end of the stretch line |

Between `begin` and `end` the program prints ordinary text with any SGR. Each
`fill` takes the SGR in effect where it appears. `G` is 1 to 8 cells of
printable glyphs (`-`, `─`, `-=`, `─╌`); anything else rejects the `fill`.

```sh
printf '\033]1332;begin\033\\---[ ls ]\033]1332;fill;-\033\\[ 18:50:59 ]---\033]1332;end\033\\\n'
```

Every shape the user asked for is the same mechanism:

| Shape | Sequence |
|---|---|
| fill, then content | `begin fill;- TEXT end` |
| content, then fill | `begin TEXT fill;- end` |
| content, fill, content | `begin A fill;- B end` |
| content, fill, content, fill, content | `begin A fill;- B fill;= C end` |

### Layout

- Free width = pane width − width of all content on the line.
- Split evenly between the fill points; leftover columns go to the leftmost
  fills, one each.
- A pattern is repeated from its start and cut at the fill's edge.
- Narrower than the content: fills collapse to zero first, then content is cut
  (the same rule oslo applies today — "a long command loses the rule and not
  itself"). A stretch line never wraps.
- Every re-layout (resize, split, float move) applies to every stretch line,
  scrollback included.

### Fallback

A program that gets no `have` within its timeout prints its ordinary fixed
line. A terminal that does not know OSC 1332 ignores the whole sequence, so
content still prints; only the fills are lost.

## As built

- The fill marker is encoded in the placeholder cell's **codepoint**, not in a
  new `Style` field: `U+10F000 + pattern id` (Supplementary Private Use
  Area-B, which neither Nerd Fonts nor ordinary text use). So Phase 2 needed
  no ghostty patch at all: no `vendor/` regeneration, `Style` and `Page` sizes
  unchanged, and the fill still takes the SGR in effect where it is printed.
- `src/core/stretch.zig`: protocol parser, per-pane pattern table (64
  patterns, up to 8 single-cell glyphs each), `fillWidth`, and `expandText`
  for copying a stretch line as drawn.
- `core.VT`: `stretchBegin`/`stretchEnd` (autowrap off for the line, restored
  after), `printStretchFill`. A line feed ends a line the program never ended.
- `pane_output.zig`: OSC 1332 routed next to 1330/1331; `ask` answers
  `have;1`.
- `vt_bridge.zig`: per-cell drawing factored into `drawCell`; rows with fill
  cells are drawn by `drawStretchRow`. Rows are only scanned once a pane has
  used OSC 1332, so ordinary panes pay nothing. `stretchColumn`/`stretchSource`
  map stored ↔ drawn columns.
- Cursor (`loop_render.zig`), search highlights, mouse selection and its
  overlay (`mouse_selection.zig`) and copy all follow the drawn columns.
- 1332 is reserved for `palette.osc`; the config test and the palette fuzz
  smoke moved to 1333.
- `docs/stretch.md`, `scripts/demo_stretch.py`, `scripts/smoke_stretch.py`.
- Phase 8 (oslo) is a follow-up in the oslo repo, as planned.

## Design

The core decision: **store the stretch point in the cell, expand it at draw
time.** No side table, no tracked pins, no rewriting scrollback on resize.

### A fill point is one cell

`fill;G` prints a single placeholder cell at the cursor: codepoint = first glyph
of `G`, style carries a non-zero `fill_id`. The pattern itself lives in a
per-VT `FillTable` (id → glyphs, like `NamespaceTable` for OSC 1330).

Because it is an ordinary cell, everything that already moves cells carries it
for free: scrolling, scrollback, ghostty reflow, alt-screen switches, the pod
backlog replay on reattach (which re-parses the raw bytes).

The line is stored at its **minimum width**: content plus one cell per fill.

### Expansion happens in the renderer

`vt_bridge.drawRenderState` walks each row's cells (`row_cells`, the loop
around `vt_bridge.zig:152-242`). A row containing any cell with `fill_id != 0`
takes a layout pass first:

1. sum the width of its non-fill cells up to the last written cell;
2. compute each fill's width at the current pane width (rules above);
3. draw content cells shifted right, and each fill as its pattern, in the
   fill cell's style.

Resizing changes only the pane width the renderer sees, so every stretch line —
on screen or in scrollback — is re-laid out on the next frame with no VT work.

### begin / end

`begin` records that the cursor row is a stretch line and turns autowrap off
for it (DECAWM saved/restored by hexe, not by the program), so a long line
cannot spill onto the next row while it is being printed. `end` restores
autowrap. A `fill` outside `begin`/`end` is ignored.

### Column mapping

Anything that turns a screen column into a VT column, or back, must go through
the row's layout:

- the cursor, when it sits on a stretch row;
- mouse selection and copy (`mouse_selection.zig`, `loop_mouse.zig`) — copy
  yields the line as drawn;
- search highlights and prompt navigation, which paint over cells;
- image placements anchored on a stretch row (rare; clip, do not shift).

A helper `stretch.Layout` (built once per row per frame) owns both directions.

## Phases

### Phase 1 — protocol core (`src/core/stretch.zig`)

- Parse `ask`/`begin`/`fill;G`/`end`; validate `G` (1–8 cells, printable).
- `FillTable`: intern patterns, id 0 reserved for "not a fill", bounded size.
- `Layout.compute(row cells, pane width)`: fill widths per the rules above.
- Unit tests: every shape, leftover distribution, zero-width collapse, content
  cut, pattern cut, malformed requests leave state unchanged.

### Phase 2 — ghostty patch

- Add `fill_id: u8 = 0` to `Style` in `patches/ghostty-vt-ns.patch`, next to
  `fg_mix_percent`: equality, hashing, packed form.
- Unlike `fg_mix_percent`, it must NOT survive an SGR reset — it is set for one
  cell and cleared immediately.
- Regenerate `vendor/ghostty` with `scripts/vendor-ghostty.sh`.

### Phase 3 — VT integration

- Route `OSC 1332` in `pane_output.zig` next to the 1330/1331 dispatch
  (`pane_output.zig:402-406`), as `consumeStretchOsc`.
- `ask` → reply `have;1` via `writeResponse`, like 1331.
- `begin` / `end` → autowrap handling on the VT.
- `fill;G` → intern `G`, set `cursor.style.fill_id`, `manualStyleUpdate`,
  print the placeholder glyph, clear `fill_id`, `manualStyleUpdate`.
- Unit tests in `vt_test.zig`: fill cells land with the right id; state
  survives split feeds; SGR inside the line is kept.

### Phase 4 — rendering

- Layout pass in `drawRenderState`; draw shifted content and filled patterns.
- Cursor mapping on stretch rows.
- Unit tests against a real `RenderState`: widths 40/80/200, one to three fills.

### Phase 5 — selection, copy, search

- Map columns through `stretch.Layout` in `mouse_selection.zig` and the copy
  path; copy returns the drawn line.
- Search and prompt-navigation highlights follow the same mapping.

### Phase 6 — reserve the number

1332 is currently documented and tested as a *free* number `palette.osc` may
move OSC 1330 to. It must become reserved:

- `src/core/palette.zig` `isReservedOsc`: add 1332; flip the test at `:898`.
- `src/core/lua_runtime.zig`: add `[1332]=true` to the config's reserved list;
  move the test at `:2578`/`:2591` to another free number (e.g. 1333).
- `docs/blend.md:97`: stop suggesting 1332.
- `scripts/smoke_palette_fuzz.py:167`: 1332 is no longer an "unreserved" probe.

### Phase 7 — docs, demo, smoke

- `docs/stretch.md`: the protocol and layout rules above, with examples.
- `scripts/demo_stretch.py`: `ask`, then draw each shape; falls back when no
  `have` arrives.
- `scripts/smoke_stretch.py`, asserting on the reconstructed screen:
  - `ask` gets `have;1`;
  - each shape spans the full width at 80 and at 120 columns;
  - a line printed at 80 is re-laid out after a resize to 120 and to 50;
  - a line in scrollback is re-laid out too;
  - reattach (backlog replay) keeps stretch lines;
  - a narrow pane collapses fills, then cuts content, and never wraps.
- Mutation-check the smoke: disable the layout pass and confirm it fails.

### Phase 8 — oslo (separate repo, after hexe ships)

- When `$TERM_PROGRAM`/`ask` reports OSC 1332, draw the transcript rule as
  `begin [ cmd ] fill;<rule> [ time ] end` instead of repeating `rule` to the
  width; otherwise keep today's behaviour.

## Open questions

1. **Weighted fills** (`fill;-;w=2`)? Not in v1; the parser should ignore
   unknown fields so a later version can add it.
2. **Reflow when shrinking below the stored minimum width.** ghostty reflow
   splits a row longer than the new width. With autowrap off while printing,
   the stored row is content + one cell per fill, so this only happens when the
   content itself no longer fits. v1: accept the split (the content was going
   to be cut anyway); revisit if it looks bad in practice.
3. **Programs that redraw a stretch line in place** (clear line + reprint) work
   as-is. Programs that write at absolute columns on a stretch row see VT
   columns, not drawn columns — document it; do not try to map writes.

## Testing rules

- Build with `zig build -Doptimize=ReleaseFast -Dstrip=true`.
- Live testing on a separate profile:
  `./zig-out/bin/hexe --profile perf_test terminal new -n test`.
- Keep `HEXE_SMOKE_TMP` short (default `/tmp/hexe-smoke`): a deep path pushes
  the daemon socket past the 108-byte limit.
- Tear down only the test profile; never touch the default-profile daemon.
- Before trusting any new test, break the behaviour it guards and see it fail.
