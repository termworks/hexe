# Push-to-talk speech

Hexe includes a direct Zig binding to the `whisper.cpp` C API. Whisper and
GGML are compiled into the static Hexe binary; no speech service or asryx
installation is required.

The flow is intentionally manual and has no VAD:

1. key press starts a 16 kHz mono recording;
2. key release stops the recorder;
3. `tiny.en` transcribes the complete recording;
4. Hexe writes the text to the pane focused at key press.

## Model

Download the 75 MiB English model once:

```sh
hexe speech setup
```

The default path is `~/.local/share/hexe/models/ggml-tiny.en.bin`. Set
`HEXE_WHISPER_MODEL` to use another GGML Whisper model file.

## Keybinding

Bind press and release of the same chord:

```lua
hexe.key(
  { hexe.key.ctrl, hexe.key.alt, hexe.key.s },
  hexe.action.speech.start(),
  { on = hexe.when.press }
),
hexe.key(
  { hexe.key.ctrl, hexe.key.alt, hexe.key.s },
  hexe.action.speech.stop(),
  { on = hexe.when.release }
),
```

PipeWire's `pw-record` is preferred for capture. ALSA's `arecord` is the
fallback. Inference runs in the detached speech helper, not in the terminal
render loop.

Hexe serializes speech helpers per instance, records the owning process identity,
and clears abandoned recording or transcription state after a crash. A release
that arrives while the start helper is still launching waits for that launch
instead of losing the recording. Errors and successful insertion are reported
in the target pane.

## CLI

```sh
hexe speech start --uuid <pane-uuid>
hexe speech stop
hexe speech cancel
hexe speech status
hexe speech transcribe recording.wav
```

`status` prints `idle`, `recording`, or `transcribing`. `cancel` kills an active
recorder or asks an in-progress Whisper inference to abort.

`transcribe` accepts 16 kHz mono signed 16-bit PCM WAV files and is useful for
testing a model without recording from a microphone.

Run `make speech-smoke` to exercise start, immediate stop, cancellation, and
stale-recorder recovery with an isolated fake recorder and no microphone access.
