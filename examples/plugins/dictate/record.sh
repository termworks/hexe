#!/bin/sh
# The half hexe has no opinion about: record audio, turn it into text.
#
# Talks to hexe only through `hexe api`, using the `typing` access the manifest
# declared. Replace whisper-cli with any other engine and nothing else changes.
set -eu

: "${HEXE_DICTATE_MODEL:=$HOME/.local/share/whisper/ggml-base.en.bin}"
STATE="${XDG_RUNTIME_DIR:-/tmp}/hexe-dictate"
mkdir -p "$STATE"
WAV="$STATE/rec.wav"
PIDFILE="$STATE/recorder.pid"
PANEFILE="$STATE/pane"

json_string() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/'; }

stop_recorder() {
    [ -f "$PIDFILE" ] || return 0
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    wait "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
}

case "${1:-}" in
start)
    stop_recorder
    printf '%s' "${2:-}" > "$PANEFILE"

    # stdout and stderr closed on every background job: `start` must return at
    # once, and a caller reading its output must not be left waiting on a pipe
    # the recorder is still holding open.
    if command -v pw-record >/dev/null 2>&1; then
        pw-record --rate 16000 --channels 1 --format s16 "$WAV" >/dev/null 2>&1 &
    elif command -v arecord >/dev/null 2>&1; then
        arecord -q -f S16_LE -r 16000 -c 1 "$WAV" >/dev/null 2>&1 &
    else
        echo "dictate: neither pw-record nor arecord is installed" >&2
        exit 1
    fi
    echo $! > "$PIDFILE"

    # hexe draws the bars, so they cannot be styled away or forgotten. The claim
    # lapses on its own after a few seconds, which is why this renews it: a
    # crash here must not leave the light on.
    ( while [ -f "$PIDFILE" ]; do
        hexe api capture true >/dev/null 2>&1 || true
        sleep 2
      done ) >/dev/null 2>&1 &
    ;;

stop)
    stop_recorder
    hexe api capture false >/dev/null 2>&1 || true

    [ -s "$WAV" ] || { echo "dictate: nothing was recorded" >&2; exit 1; }
    command -v whisper-cli >/dev/null 2>&1 || {
        echo "dictate: whisper-cli not found" >&2; exit 1; }

    # --no-timestamps so the output is the sentence and nothing else: every byte
    # of this is about to be typed into a live shell.
    text=$(whisper-cli -m "$HEXE_DICTATE_MODEL" -f "$WAV" --no-timestamps --no-prints 2>/dev/null |
        tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$text" ] || exit 0

    pane=$(cat "$PANEFILE" 2>/dev/null || true)
    if [ -n "$pane" ]; then
        hexe api send "$(json_string "$pane")" "$(json_string "$text")" >/dev/null
    else
        hexe api send "$(json_string "$text")" >/dev/null
    fi
    rm -f "$WAV"
    ;;

cancel)
    stop_recorder
    hexe api capture false >/dev/null 2>&1 || true
    rm -f "$WAV"
    ;;

*)
    echo "usage: record.sh start [pane-uuid] | stop | cancel" >&2
    exit 2
    ;;
esac
