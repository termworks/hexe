# Dictation

There is no dictation feature in hexe. No `hexe.dictate`, no speech code, no
audio stack. Dictation is a plugin, assembled from two general things:

| | |
| --- | --- |
| [`typing` access](access.md) | the tool may put text into a pane |
| `capture` | the tool may say "something is recording you", and hexe draws it |

```console
$ cp -r examples/plugins/dictate ~/.local/share/hexe/site/pack/mine/start/
```

Hold `ctrl+alt+d`, speak, release. The keybindings come with the package — your
config never mentions it. See [plugins.md](plugins.md).

## Why it is not a feature

An earlier attempt linked whisper.cpp into the hexe binary. A later one made it
a `hexe.dictate` config section with its own actions and its own renderer. Both
were the same mistake in different sizes: the engine, the model, the language,
the punctuation are exactly what people want to change, and none of that should
mean touching a terminal multiplexer — or waiting for it to grow a setting.

What is left is smaller and serves more than dictation. `typing` is equally a
snippet expander, a translator, a paste filter. `capture` is equally a screen
recorder or a camera. Neither knows what the other is for.

## Doing the work

The tool owns all of it, and talks to hexe through the ordinary API:

```sh
hexe api capture true                  # something is recording — hexe draws it
# ... record, transcribe, whatever you like ...
hexe api capture false
hexe api send '"<pane-uuid>"' '"the transcribed text"'
```

Capture the pane's uuid when you **start**, and send there. Transcription takes
a moment and it is easy to change panes in that moment; typing into whatever is
focused when the tool finishes puts a sentence in the wrong shell.

## The indicator

While a capture is claimed, three half-block bars sit at the bottom centre of
that pane:

```
       ▃▆▂
```

**hexe draws them, not the painter.** An indicator that disappears when no
painter is running is not an indicator, and this one means "a microphone is open
right now" — so it cannot be styled away or forged by a plugin drawing its own.

They are not a level meter: hexe never sees the audio. They move so that
"capturing" cannot be mistaken for a frozen screen.

**A claim lapses after a few seconds unless renewed.** Call `capture true` on a
timer while you record. A plugin that crashes mid-capture therefore cannot leave
the light on — an indicator stuck on teaches people to ignore it, which is worse
than not having one.

Claiming is deliberately cheap and needs no special access: *claiming* to
capture is harmless, and the harm runs the other way — capturing without
claiming.

```console
$ hexe api capture
{"capturing":true,"pane_uuid":"2c88beab…","by":"dictate"}
```

## Using asryx

[asryx](https://github.com/rccyx/asryx) is a toggle that delivers to the
clipboard, so a small adapter bridges it — `contrib/dictate-asryx.sh`. Three
things caught me setting it up:

- **It needs a C++23 compiler with `<expected>`** (GCC 13+ / Clang 16+). Its
  installer prefers `clang++`, then bare `g++`, so a machine whose
  `/usr/bin/g++` is older than the one it uses stops at
  `error.hpp:5: fatal error: expected: No such file or directory`. Set **both**
  `CC` and `CXX`.
- **`--model install` does not fetch the VAD model.** It also wants
  `ggml-silero-v6.2.0.bin`, downloaded by a later installer step — so a failed
  build leaves a Whisper model, no VAD model, and a runtime failing at
  `VAD model is not installed`. That message goes to
  `$XDG_RUNTIME_DIR/asryx/error.log` and is announced by `notify-send`, so with
  no notification daemon you see a DBus error and the real cause is in the log.
- **The clipboard needs the session's own `XDG_RUNTIME_DIR`** — `wl-copy` finds
  the Wayland socket through it, so a hexe started with a custom one silently
  receives nothing.

Timing, for reference: `base.en` on 11 seconds of speech takes about 5.5s.
