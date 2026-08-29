# dictate — speech to text, as a plugin

```sh
cp -r examples/plugins/dictate ~/.local/share/hexe/site/pack/mine/start/
```

Hold `ctrl+alt+d`, speak, release. The text is typed into the pane you started
in. `ctrl+alt+c` abandons a recording without typing anything.

There is **no dictation feature in hexe** — no `hexe.dictate`, no speech code,
no audio stack. This package is assembled from two general things:

| | |
| --- | --- |
| `typing` access | hexe types the transcript into a pane |
| `capture` | the pane shows three bars while a microphone is open |

Neither knows what the other is for. `typing` is equally a snippet expander or a
translator; `capture` is equally a screen recorder.

## What it needs installed

`pw-record` (PipeWire) or `arecord` (ALSA), and `whisper-cli` with a model:

```sh
export HEXE_DICTATE_MODEL=~/.local/share/whisper/ggml-base.en.bin
```

`whisper-cli` is a target of whisper.cpp, not something most package managers
ship on its own:

```sh
cmake -S whisper.cpp -B build -DCMAKE_BUILD_TYPE=Release -DWHISPER_BUILD_EXAMPLES=ON
cmake --build build --target whisper-cli
```

Any GGML Whisper model works, including one another tool already downloaded —
asryx keeps its under `~/.local/share/asryx/models/`.

Swap `whisper-cli` in `record.sh` for any other engine — a cloud API, a local
server, `asryx` — and nothing else changes. That file is the half hexe has no
opinion about.

## The two details worth copying

**It captures the pane uuid on press, not on release.** Transcription takes a
second and it is easy to change panes in that second; typing into whatever is
focused when the tool finishes puts a sentence into the wrong shell.

**It renews the capture claim while recording.** The claim lapses after a few
seconds on its own, so a crashed recorder cannot leave the "microphone open"
indicator lit — an indicator stuck on teaches people to ignore it, which is
worse than not having one.

## Where its files are

`init.lua` receives the package's own directory as the chunk's `...`, which is
how it finds `record.sh`:

```lua
local here = ...
local recorder = here .. "/record.sh"
```
