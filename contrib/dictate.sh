#!/bin/sh
# A dictation tool for hexe, in the shape hexe expects.
#
#   hexe.dictate = { command = "~/.config/hexe/dictate.sh" }
#
# The whole contract:
#
#   1. record until stdin closes  -- hexe closes it when you stop dictating;
#   2. print the text to stdout   -- hexe types it into the pane you started in;
#   3. exit.
#
# Nothing here is hexe-specific except that. Anything obeying it works: a
# whisper.cpp wrapper, a cloud API, a local server, or `echo` while testing.
# Diagnostics go to stderr, which hexe ignores -- only stdout is the transcript.
set -eu

: "${HEXE_DICTATE_MODEL:=$HOME/.local/share/whisper/ggml-base.en.bin}"
WAV=$(mktemp -t hexe-dictate-XXXXXX.wav)
trap 'rm -f "$WAV"' EXIT INT TERM

# Whisper wants 16 kHz mono. pw-record for PipeWire, arecord as the fallback --
# picked at run time so one script works on both.
if command -v pw-record >/dev/null 2>&1; then
    pw-record --rate 16000 --channels 1 --format s16 "$WAV" &
elif command -v arecord >/dev/null 2>&1; then
    arecord -q -f S16_LE -r 16000 -c 1 "$WAV" &
else
    echo "dictate: neither pw-record nor arecord is installed" >&2
    exit 1
fi
RECORDER=$!

# Block until hexe closes stdin. `read` returning EOF is the stop signal, which
# is why this needs no signal handler: releasing the key ends the recording.
read -r _ignored || true

kill "$RECORDER" 2>/dev/null || true
wait "$RECORDER" 2>/dev/null || true

if [ ! -s "$WAV" ]; then
    echo "dictate: nothing was recorded" >&2
    exit 1
fi

# Transcribe. Swap this block for whatever engine you prefer; everything above
# it is just "record until told to stop".
if ! command -v whisper-cli >/dev/null 2>&1; then
    echo "dictate: whisper-cli not found; printing nothing" >&2
    exit 1
fi

# --no-timestamps so the output is the sentence and nothing else: every byte on
# stdout is typed into the user's shell.
whisper-cli -m "$HEXE_DICTATE_MODEL" -f "$WAV" --no-timestamps --no-prints 2>/dev/null |
    tr '\n' ' ' |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
