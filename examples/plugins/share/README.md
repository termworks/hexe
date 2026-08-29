# share — hand a pane to a stream backend

```sh
cp -r examples/plugins/share ~/.local/share/hexe/site/pack/mine/start/
```

`ctrl+alt+s` starts sharing the focused pane and shows where it went.
`ctrl+alt+x` stops.

hexe never learns what the address is. It hands the backend the pane as
**asciicast v2** — a header line, then `[t,"o",data]` events, the same thing
`asciinema play` reads — and draws whatever block of text the backend reports
back. A URL, an id, a QR already rendered into block characters: all the same to
hexe, which is the point. The moment hexe knows what a QR is, it owns a QR
library and a set of opinions about them.

## Swapping the backend

`backend.sh` writes a `.cast` file and reports a `file://` address, which is
enough to see the whole path working. Replace it with anything that reads
asciicast on stdin:

```sh
HEXE_SHARE_BACKEND="drop cast" hexe ...
```

Nothing in a backend is hexe-specific. It is an asciicast consumer.

## View-only is the absence of a word

The manifest asks for `stream` and `popup`, and **not** `typing`. That is what
makes this view-only: with `typing` added, the backend could send
`[t,"i",data]` back on its stdout and hexe would type it into the pane.

Two grants, not two modes — handing someone your keyboard is a different
decision from showing them your screen, so it is a different word.

## The rule a backend must not skip

A password prompt arrives as an asciicast marker:

```json
[1.5, "m", "password-on"]
```

**A backend keeping its own scrollback must CLEAR it there, not merely stop
appending.** Detection cannot precede the prompt: the bytes that drew
`Password:` went out before the terminal's echo flag changed, so they are
already in the buffer. hexe wipes its own backlog for exactly this reason, and a
downstream buffer that does not becomes the leak the wipe prevented.

`backend.sh` shows the whole of it — one `case` line.
