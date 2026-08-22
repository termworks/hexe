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
