# Dictation

hexe records no audio and transcribes nothing. It starts a tool you configure,
shows the pane is listening, and types back whatever the tool prints.

```lua
hexe.dictate = { command = "~/.config/hexe/dictate.sh" }

hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.d }, hexe.action.dictate.start(), { on = hexe.when.press })
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.d }, hexe.action.dictate.stop(),  { on = hexe.when.release })
```

That is push-to-talk: hold the chord, speak, release. Bind `hexe.action.dictate.toggle()` to a
single press instead if you would rather not hold a key.

## The contract

Two lines, and nothing in them is hexe-specific:

1. **record until stdin closes** — hexe closes it when you stop dictating;
2. **print the text to stdout and exit** — hexe types it into the pane.

stdin-as-the-stop-signal rather than a signal, so a shell script can implement
it without trapping anything:

```sh
pw-record --rate 16000 --channels 1 "$WAV" &
read -r _ || true          # blocks until hexe stops the dictation
kill $!
whisper-cli -m "$MODEL" -f "$WAV" --no-timestamps
```

`contrib/dictate.sh` is that script, filled in. Because the contract is this
small, the tool runs and debugs on its own — `echo hello | your-tool` tells you
whether it works without hexe in the way.

**stdout is the transcript, stderr is not.** Everything the tool prints on
stdout gets typed into a live shell, so diagnostics belong on stderr, which
hexe ignores.

## Why it is not built in

An earlier attempt linked whisper.cpp and GGML into the hexe binary. It worked,
and it was the wrong shape: the choice of engine, model, language and
punctuation is exactly what people want to change, and none of it should mean
rebuilding a terminal multiplexer. Every one of those is now a line in a shell
script.

hexe keeps only the parts that need to be inside: knowing which pane you started
in, showing that a microphone is open, and typing the result somewhere sensible.

## The indicator

While the tool is listening, three half-block bars rise and fall at the bottom
centre of the pane:

```
       ▃▆▂
```

They are **not** a real level meter — hexe never sees the audio. They exist to
answer one question at a glance: is something listening right now? A recording
you did not know about is the failure worth designing against, so it is drawn
over the pane's own output rather than tucked into chrome, and it stops the
instant dictation does.

The bars stop moving and dim when you release the key: the tool is transcribing,
and "still listening" has to look different from "stopped listening".

## Where the text goes

Into the pane dictation **started** in, not whichever is focused when the tool
finishes. Transcription takes a moment, and it is easy to change panes in that
moment; retargeting would put a sentence into an unrelated shell.

If that pane is gone by then, the text is dropped and hexe says so. The same
reasoning: there is no safe second choice.

## Driving it without a keyboard

```console
$ hexe api dictate           -> {"active":false,"phase":"idle"}
$ hexe api dictate true      -> {"active":true,"phase":"listening","pane_uuid":"2c88…"}
$ hexe api dictate false
```

`phase` is `idle`, `listening` or `thinking`. Useful from a phone UI, a foot
pedal, or a plugin that wants to start dictation on some other cue.

## When a tool misbehaves

- **Prints nothing** — hexe says so and types nothing.
- **Never exits** after being told to stop — abandoned after
  `dictate.timeout_ms` (30s by default) so the indicator cannot stick on screen
  and block the next attempt.
- **Never starts** — the keybinding reports why rather than doing nothing
  silently, which is indistinguishable from a broken key.

## Using asryx

[asryx](https://github.com/rccyx/asryx) fits, through an adapter. It disagrees
with the contract above in two ways, and `contrib/dictate-asryx.sh` is the whole
of the disagreement:

| | asryx | hexe wants |
|---|---|---|
| lifetime | a **toggle**: one call starts, the next stops, each exits at once | one process that lives for the dictation |
| delivery | the **clipboard** (plus an optional `--pipe-to`) | stdout |

So the adapter *is* the long-lived process: it calls `asryx` to start, blocks on
stdin, calls `asryx` again to stop, waits for `asryx status` to go back to
`idle`, and prints what landed on the clipboard.

```lua
hexe.dictate = { command = "~/.config/hexe/dictate-asryx.sh" }
```

Three things to know before you rely on it:

- **Dictating replaces your clipboard.** That is asryx's design, not the
  adapter's: `--pipe-to` still copies first, so there is no path that avoids it.
  Set `HEXE_ASRYX_RESTORE_CLIPBOARD=1` to put the old contents back afterwards.
- **It needs a graphical session.** The transcript travels through the X11 or
  Wayland clipboard, so asryx cannot deliver anything to a hexe running over SSH
  or on a bare TTY. A tool that prints to stdout — like `contrib/dictate.sh` —
  has no such limit.
- **Do not also bind asryx to a compositor hotkey.** Two toggles driving one
  state machine will fight, and you get a recording nobody stops.

The adapter waits for `idle` before reading the clipboard. As of writing that
loop exits immediately — asryx's stop path transcribes inline — but it costs
one status call and protects against the race that would otherwise type the
*previous* dictation.

### Getting asryx installed

Three things caught me, none of them obvious from the error you get:

- **It needs a C++23 compiler with `<expected>`** — GCC 13+ or Clang 16+. The
  installer prefers `clang++`, then bare `g++`, so a machine whose
  `/usr/bin/g++` is older than the one it actually uses stops at
  `error.hpp:5: fatal error: expected: No such file or directory`. Setting
  **both** `CC` and `CXX` overrides the choice.
- **`--model install` does not fetch the VAD model.** asryx also wants
  `ggml-silero-v6.2.0.bin`, which `./package/install` downloads in a later step
  — so a build that failed leaves you with a Whisper model, no VAD model, and
  the runtime failing at `VAD model is not installed`. That message goes to
  `$XDG_RUNTIME_DIR/asryx/error.log`, and is announced by `notify-send`: with
  no notification daemon you see a DBus error instead and the real cause is in
  that log.
- **The clipboard needs the session's own `XDG_RUNTIME_DIR`.** `wl-copy` finds
  the Wayland socket through it, so a hexe started with a custom one cannot
  receive anything from asryx. Nothing fails loudly; the transcript is simply
  never delivered.

Timing, for reference: `base.en` transcribing 11 seconds of speech takes about
5.5s here, comfortably inside the 30s `dictate.timeout_ms`. A slower model or a
long dictation may want that raised.
