# Images

A program draws an image on a terminal by writing an escape sequence full of pixels. There are three
such sequences in circulation and no agreement on which one to use: the **Kitty graphics protocol**,
**sixel**, and **iTerm2 inline images**. Which one a program speaks depends on when it was written;
which one a terminal understands depends on which terminal it is.

hexe sits in the middle of that, which is the useful place to stand. It **accepts all three from a
pane and emits Kitty to the host terminal**, so what a program speaks and what your terminal speaks
stop being the same question. On a terminal that draws no images at all, it draws them out of text
rather than showing nothing.

## What works

| From the program | How |
|---|---|
| Kitty graphics | Parsed by ghostty's VT into the pane's image storage |
| Sixel | Decoded by hexe (`src/core/sixel.zig`) and handed to the same storage |
| iTerm2 `OSC 1337 File=` | Base64 decoded by hexe, PNG payloads handed to the same storage |

Everything ends up in one place — ghostty's per-screen Kitty image storage — and the renderer
re-transmits from there to whatever terminal you are actually attached to. That is why a sixel drawn
by `img2sixel` inside a pane arrives at your terminal as a Kitty image.

## What does not

- **Animation.** Kitty animation frames are accepted and discarded, upstream and here.
- **iTerm2 payloads that are not PNG.** JPEG and GIF would need a decoder hexe does not carry.
- **Cell size inside a pane.** A pane's pty reports `ws_xpixel = 0`, so a program that works out its
  cell size from `TIOCGWINSZ` gets nothing and falls back to its own default. hexe knows the real
  figure from the host and uses it for placement; it does not yet pass it down to the pane.

## Images hexe puts there itself

Everything above is a program inside a pane drawing something. The other
direction is hexe placing an image because a caller asked, through the same
`draw` verb that takes bytes:

```console
$ hexe api draw '"logo"' '{"image":"/tmp/logo.png","corner":"topright","width":20,"height":8}'
```

```lua
hexe.draw("logo", { image = "/tmp/logo.png", corner = "topright", width = 20, height = 8 })
```

`image` is a path to a PNG. hexe reads it and encodes it as a Kitty placement
scaled to the rectangle, and that becomes the drawing's bytes — so it is not a
second way of drawing, it is the existing one with the bytes supplied. It then
travels the path every other image takes, which is why it works on a terminal
with no graphics without another line of code.

A drawing gets a stable image id derived from its name, so one redrawn every
second occupies a single slot instead of accumulating an image per update. The
file is capped at 16MB, and anything that is not a PNG is refused rather than
drawn as garbage: `src/core/image_encode.zig`.

## When the terminal cannot draw images

hexe asks at startup whether the host speaks the Kitty protocol. If it does not, the image is drawn
as text: one upper half block per cell, its foreground painting the top half of the pixels and its
background the bottom, so a row of cells carries two rows of pixels. It is the trick `chafa` and
`viu` use on a plain terminal, done here so it applies to any program's image rather than only to
programs that thought to implement it.

It is not a photograph. A chart is readable, a logo is recognisable, and a preview tells you what it
was going to tell you — which is the point, because the alternative was a blank hole with no
indication that anything had been there.

Two details worth knowing. Pixels are averaged over the region each half cell covers rather than
point-sampled, because a downscaled photograph sampled at single points is noisy in a way a small box
average is not; the cost is bounded by the number of cells, not the size of the image. And a half
cell that is mostly transparent is left alone rather than painted, so an image with an alpha channel
does not punch a rectangle through the text behind it.

Nothing is transmitted to a terminal that never claimed to support the protocol, which
`scripts/smoke_image_fallback.py` asserts directly.

## How it is built

The Kitty path is ghostty's, with two changes carried in `patches/ghostty-vt-kitty.patch`. Upstream
synthesises its `kitty_graphics` build option from `oniguruma`, and the exported `ghostty-vt` module
force-disables oniguruma — so images compiled out entirely, and every image path in hexe sat behind a
comptime check that was false. Nothing in the graphics code uses regex; it needs wuffs, for decoding
PNG. The patch separates the two options and adds the dependency. The second change teaches ghostty's
readonly stream to handle APC, which is what the Kitty protocol travels in and which that stream had
always dropped.

Sixel and iTerm2 are hexe's own, in `src/core/image_import.zig`. It watches the pane's byte stream,
lifts out the sequences carrying an image, decodes them, and injects the pixels as though the program
had sent Kitty all along. Output carrying no image reaches the VT as the same slices it arrived in,
and the scan for a sequence start is a vector search for `ESC` rather than a walk — this is the VT's
hot path, and a per-byte loop there would tax every pane to catch the rare image.

Placements are measured in cell pixels: `core.vt.cell_px`, read from the host's `TIOCGWINSZ` at
startup and refreshed on every resize, because a font size change moves the pixels without moving the
rows and columns. A terminal that reports nothing leaves a default 8×16 standing — without some
figure the arithmetic divides by zero, the placement collapses to zero cells, and an image transmits
but is never drawn.

Image storage is capped at 64MB per pane. ghostty's own default is 320MB **per screen**, which is
reasonable for a terminal that is one window and not for a mux with twenty panes.

## Checking it

Four smokes drive a real frontend over a pty, playing the part of the terminal:

- `scripts/smoke_kitty_graphics.py` — a pane draws a Kitty image; assert hexe transmits **and places**
  it.
- `scripts/smoke_image_protocols.py` — a pane draws a sixel and an iTerm2 PNG; assert Kitty comes out
  of the other side, and that the raw payloads never reach the screen as text.
- `scripts/smoke_image_fallback.py` — the deliberate opposite: never answer the capability query, so
  the frontend believes it is on a plain terminal, then assert half blocks appear carrying the
  image's colour and that nothing was transmitted.
- `scripts/smoke_draw_image.py` — `hexe api draw` with an `image` path, run twice against two
  separate stacks: one whose terminal answers the capability query and one whose does not, asserting
  the same call produces a Kitty image for the first and half blocks for the second.

A fifth covers a failure that images made possible elsewhere:
`scripts/smoke_reattach_image_intact.py` reattaches to a pane that displayed a megabyte-scale image.
Backlog replay resynchronises on a newline, and an image payload is base64 with no newline in it, so
the replay used to start inside the payload and print it as a wall of text.
