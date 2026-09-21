# Stretch lines

OSC 1332 lets a program mark where a line may stretch, and hexe fills that
space so the line always spans the pane — when it is printed, after every
resize, and for lines already in scrollback.

```sh
printf '\033]1332;begin\033\\---[ ls ]\033]1332;fill;-\033\\[ 18:50:59 ]---\033]1332;end\033\\\n'
```

```
---[ ls ]--------------------------------------------------------[ 18:50:59 ]---
```

A program that repeats its rule to `tput cols` freezes the line at that width:
widen or shrink the pane and every old rule is wrong. With OSC 1332 the program
says where the fill goes and hexe owns the width.

## Protocol

OSC 1332 is a Hexe-private protocol. Both ST (`ESC \`) and BEL terminate a
request. Hexe emits ST in replies. Verbs are ASCII case-insensitive; a
malformed request or an unknown verb is ignored without changing state.

| Sequence | Meaning |
|---|---|
| `OSC 1332;ask ST` | ask whether version 1 is supported |
| `OSC 1332;have;1 ST` | Hexe's capability reply |
| `OSC 1332;begin ST` | the cursor row is a stretch line |
| `OSC 1332;fill;G ST` | a stretch point, filled by repeating `G` |
| `OSC 1332;end ST` | end of the stretch line |

Between `begin` and `end` the program prints ordinary text with any SGR. Each
`fill` takes the SGR in effect where it appears, so a fill can be coloured
differently from the text around it.

`G` is 1 to 8 single-cell glyphs, repeated from its first glyph: `-`, `─`,
`-=`, `─╌`, or a space to push text to the right. Accepted glyphs are space,
ASCII and Latin-1 printables, general punctuation, arrows, box drawing, block
elements and geometric shapes. Anything else — a wide glyph, a control
character, more than 8 glyphs — rejects the `fill`. Fields after `G` are
ignored, reserved for a later version.

A `fill` outside `begin` … `end` is ignored.

## Shapes

Every shape is the same mechanism: content and fills, in any order.

| Shape | Sequence |
|---|---|
| fill, then content | `begin`, `fill;-`, `TEXT`, `end` |
| content, then fill | `begin`, `TEXT`, `fill;-`, `end` |
| content, fill, content | `begin`, `A`, `fill;-`, `B`, `end` |
| content, fill, content, fill, content | `begin`, `A`, `fill;-`, `B`, `fill;=`, `C`, `end` |

## Layout

- Free width is the pane's width minus the width of all content on the line.
- It is shared evenly between the fills; leftover columns go one each to the
  leftmost fills.
- A pattern is cut at the edge of its fill.
- When the content alone is wider than the pane, the fills collapse to zero
  and the content is cut at the pane's edge. A stretch line never wraps.
- Every re-layout — resize, split, float move — applies to every stretch line,
  scrollback included.

Copying a stretch line copies it as drawn. The cursor, mouse selection and
search highlights follow the drawn columns.

## Autowrap

`begin` turns autowrap off until `end`, so a long line cannot spill onto the
next row while it is printed; `end` restores whatever the program had. A line
that is never ended is ended by the next line feed, so a program that dies
mid-line cannot leave the pane without autowrap.

## Fallback

A program that gets no `have` within its own timeout prints its ordinary
fixed-width line. A terminal that does not know OSC 1332 ignores the whole
sequence: the content still prints, only the fills are lost.

## Programs that cannot ask

A program that cannot write `ask` and read the reply — a prompt renderer run
as a short-lived child, say — can read the environment instead: hexe sets
`HEXE_STRETCH=1332` in every pane it starts, and only a hexe that draws OSC
1332 does. pixy's `--stretch auto` works this way.

## Reserved number

1332 is reserved: `palette.osc` cannot move OSC 1330 onto it.

## Limits

- A program that writes at absolute columns on a stretch row sees stored
  columns, not drawn ones. Redraw a stretch line by clearing the row and
  printing it again.
- A pane remembers up to 64 distinct fill patterns; after that a new pattern
  is ignored and the patterns already used keep working.

See `scripts/demo_stretch.py` for every shape, drawn live.
