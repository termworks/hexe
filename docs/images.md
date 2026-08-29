# Images

A program draws an image on a terminal by writing an escape sequence full of pixels, and there is no
agreement on which sequence: the **Kitty graphics protocol** is the modern one, **sixel** the older
one still in wide use. Which a program speaks depends on when it was written; which a terminal
understands depends on which terminal it is.

hexe sits in the middle of that, which is the useful place to stand. It **accepts both from a pane
and emits Kitty to the host terminal**, so what a program speaks and what your terminal speaks stop
being the same question. On a terminal that draws no images at all, it draws them out of text rather
than showing nothing.

## What works

| From the program | How |
|---|---|
| Kitty graphics | Parsed by ghostty's VT into the pane's image storage |
| Sixel | Decoded by hexe (`src/core/sixel.zig`) and handed to the same storage |

Both end up in one place — ghostty's per-screen Kitty image storage — and the renderer re-transmits
from there to whatever terminal you are actually attached to. That is why a sixel drawn by
`img2sixel` inside a pane arrives at your terminal as a Kitty image.

## What does not

- **Animation.** Kitty animation frames are accepted and discarded, upstream and here.
- **Formats other than PNG and JPEG** for `draw`. GIF, WebP and the rest are refused rather than
  drawn as garbage. hexe decodes through the wuffs already vendored with ghostty, which builds only
  those two.

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

`image` is a path to a PNG or a JPEG. hexe reads it and encodes it as a Kitty placement
scaled to the rectangle, and that becomes the drawing's bytes — so it is not a
second way of drawing, it is the existing one with the bytes supplied. It then
travels the path every other image takes, which is why it works on a terminal
with no graphics without another line of code.

A drawing gets a stable image id derived from its name, so one redrawn every
second occupies a single slot instead of accumulating an image per update. The
file is capped at 16MB, and a format hexe cannot read is refused rather than
drawn as garbage: `src/core/image_encode.zig`.

## Floats over images

A Kitty image is not made of cells, and that is the whole difficulty. hexe writes
**one** placement onto the image's top-left cell, and the terminal draws the
picture from there across as many cells as the placement claims — compositing it
against the text on its own terms, not hexe's.

So the cell grid does not protect a float. A float over the middle of an image
never touches the cell the placement lives on, and the terminal drew the picture
straight over the float; a float over the *top-left* corner removed the placement
and the whole image vanished, however little of it was actually covered. Both are
real: `scripts/smoke_image_occlusion.py` reproduced the first before it was
fixed, with hexe still emitting a full 60×24 placement every frame under a float.

hexe now trims a placement to the largest rectangle its occluders leave, and
scales the source clip to match so the surviving strip shows the piece of the
picture that belongs in it rather than the whole thing squashed. When nothing
survives, no image is drawn at all — a picture painted across a float is worse
than a missing one.

The occluders are the floats, borders included, gathered **before** any pane is
drawn: by the time a float is drawn the pane's placement has already been
written. A float is only trimmed against floats drawn after it, and the active
float, drawn last, is trimmed against nothing.

A rectangle is what this can express. An image with a float over its centre keeps
the biggest of the four surrounding strips rather than an L-shape, so more of it
is hidden than strictly must be. The alternative — a placement per cell — costs
one escape sequence per cell per frame, which is a great deal of bandwidth to
recover a corner. This does not arise in the half-block fallback below, where an
image really is made of cells and a float overwrites it like any other text.

## PNG and JPEG

`draw` is handed a whole encoded image rather than a stream of escapes, and reads PNG and JPEG. It
identifies which by the leading bytes rather than by the extension (`src/core/image_file.zig`).

The two are handled differently on purpose. **PNG travels on untouched**: the Kitty protocol carries
it and ghostty decodes it on arrival, so decoding it early would only swap a compressed image for a
raw one several times the size. **JPEG has no place in the protocol at all**, so hexe decodes it to
pixels and sends those instead. That asymmetry is why a JPEG appears on the wire as `f=32` with
explicit dimensions while a PNG appears as `f=100`.

The decoder is the wuffs already vendored alongside ghostty's VT and already compiled into the binary
for ghostty's own PNG path — hexe depends on it directly because it decodes images the VT never sees.
That build enables PNG and JPEG only, which is exactly the set above; anything else is refused.

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

Sixel is hexe's own, in `src/core/image_import.zig`. It watches the pane's byte stream, lifts out the
sequences carrying an image, decodes them, and injects the pixels as though the program had sent
Kitty all along. Output carrying no image reaches the VT as the same slices it arrived in,
and the scan for a sequence start is a vector search for `ESC` rather than a walk — this is the VT's
hot path, and a per-byte loop there would tax every pane to catch the rare image.

Placements are measured in cell pixels: `core.vt.cell_px`, read from the host's `TIOCGWINSZ` at
startup and refreshed on every resize, because a font size change moves the pixels without moving the
rows and columns. A terminal that reports nothing leaves a default 8×16 standing — without some
figure the arithmetic divides by zero, the placement collapses to zero cells, and an image transmits
but is never drawn.

## What a program in a pane sees

That same cell size goes down to the pane. A program deciding how tall a picture will be divides its
pty's pixel fields by the cell counts, so a pane reporting `ws_xpixel = 0` — which every pane did —
left `icat`, `timg`, `chafa` and anything else asking `TIOCGWINSZ` guessing, and guessing against the
wrong terminal, because the pane is not the window.

The resize frame the frontend sends its pod now carries the host's cell size after the size in cells,
and the pod puts a real pixel geometry on the pty. The two extra fields are an extension: a pod built
before them, or `hexe pod attach` from a terminal that reports no pixel size, sends the four bytes it
always did and the pixel fields stay zero.

**The fallback stops at hexe's edge.** The internal 8×16 default keeps placement arithmetic working,
but it is never sent to a pane — `cell_px.known` separates a measurement from a stand-in. A program
that is told a cell is 8×16 has no way to know it is being guessed at, and a wrong geometry is worse
than an absent one; zero already means "unknown" in that protocol, and unknown is the honest answer.

A font size change moves the cell size without moving any pane's rows and columns, so there is no
cell-dimension change to carry the news. The frontend re-sends every pane's size outright when the
cell size moves.

Image storage is capped at 64MB per pane. ghostty's own default is 320MB **per screen**, which is
reasonable for a terminal that is one window and not for a mux with twenty panes.

## Checking it

Six smokes drive a real frontend over a pty, playing the part of the terminal:

- `scripts/smoke_kitty_graphics.py` — a pane draws a Kitty image; assert hexe transmits **and places**
  it.
- `scripts/smoke_image_protocols.py` — a pane draws a sixel; assert Kitty comes out of the other
  side, and that the raw payload never reaches the screen as text.
- `scripts/smoke_image_fallback.py` — the deliberate opposite: never answer the capability query, so
  the frontend believes it is on a plain terminal, then assert half blocks appear carrying the
  image's colour and that nothing was transmitted.
- `scripts/smoke_draw_image.py` — `hexe api draw` with an `image` path, run twice against two
  separate stacks: one whose terminal answers the capability query and one whose does not, asserting
  the same call produces a Kitty image for the first and half blocks for the second.
- `scripts/smoke_image_occlusion.py` — a pane draws a 60×24 image, a float opens over it, and the
  placements hexe emits are read back: full size unobstructed, trimmed under the float, full size
  again once it closes.
- `scripts/smoke_pane_cell_size.py` — a program *inside* a pane reads its own `TIOCGWINSZ` and writes
  it to a file (scraping it back out of the rendered screen would be testing the renderer, not the
  ioctl). It asserts the pane reports the host's real cell size, that a resize keeps the two
  consistent, and that a host reporting no pixel size leaves the pane at zero rather than inheriting
  the fallback.

A seventh covers a failure that images made possible elsewhere:
`scripts/smoke_reattach_image_intact.py` reattaches to a pane that displayed a megabyte-scale image.
Backlog replay resynchronises on a newline, and an image payload is base64 with no newline in it, so
the replay used to start inside the payload and print it as a wall of text.
