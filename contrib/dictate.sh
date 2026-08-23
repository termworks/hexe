#!/bin/sh
# Dictation for hexe, as an ordinary plugin.
#
#   hexe.plugin("dictate", { command = "~/.config/hexe/dictate.sh",
#                            access = { "typing" } })
#
# hexe has no dictation feature and no `hexe.dictate` setting. It has `typing`
# access and a capture indicator, and this script is what makes those into
# dictation. Swap whisper for anything else and hexe does not change.
#
# Push-to-talk: hold the key, speak, release.
#
#   hexe.key(chord, function() ctx.exec("~/.config/hexe/dictate.sh start") end,
#            { on = hexe.when.press })
#   hexe.key(chord, function() ctx.exec("~/.config/hexe/dictate.sh stop") end,
#            { on = hexe.when.release })
set -eu

: "${HEXE_DICTATE_MODEL:=$HOME/.local/share/whisper/ggml-base.en.bin}"
STATE="${XDG_RUNTIME_DIR:-/tmp}/hexe-dictate"
mkdir -p "$STATE"
WAV="$STATE/rec.wav"
PIDFILE="$STATE/recorder.pid"
PANEFILE="$STATE/pane"

# Talking to hexe is one socket and one JSON line. `hexe api` does it for us,
# and reads HEXE_API_SOCKET itself.
hexe_api() { hexe api "$@" >/dev/null 2>&1 || true; }

start() {
    [ -f "$PIDFILE" ] && stop_recorder
    # Remember which pane asked, so the text lands where it was started even if
    # focus moves while whisper is thinking.
    hexe api pane 2>/dev/null | sed -n 's/.*"uuid":"\([0-9a-f]*\)".*/\1/p' > "$PANEFILE" || true

    if command -v pw-record >/dev/null 2>&1; then
        pw-record --rate 16000 --channels 1 --format s16 "$WAV" &
    elif command -v arecord >/dev/null 2>&1; then
        arecord -q -f S16_LE -r 16000 -c 1 "$WAV" &
    else
        echo "dictate: neither pw-record nor arecord is installed" >&2
        exit 1
    fi
    echo $! > "$PIDFILE"

    # Light the indicator. hexe draws it, so it cannot be styled away or
    # forgotten -- and it lapses on its own if this script dies, which is why
    # the loop below keeps renewing it.
    hexe_api capture true
    while [ -f "$PIDFILE" ]; do
        sleep 2
        [ -f "$PIDFILE" ] || break
        hexe_api capture true
    done &
}

stop_recorder() {
    [ -f "$PIDFILE" ] || return 0
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    wait "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
}

stop() {
    stop_recorder
    hexe_api capture false

    [ -s "$WAV" ] || { echo "dictate: nothing was recorded" >&2; exit 1; }
    command -v whisper-cli >/dev/null 2>&1 || {
        echo "dictate: whisper-cli not found" >&2; exit 1; }

    # --no-timestamps so the output is the sentence and nothing else: every byte
    # of this is about to be typed into a shell.
    text=$(whisper-cli -m "$HEXE_DICTATE_MODEL" -f "$WAV" --no-timestamps --no-prints 2>/dev/null |
        tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$text" ] || exit 0

    pane=$(cat "$PANEFILE" 2>/dev/null || true)
    if [ -n "$pane" ]; then
        hexe api send "\"$pane\"" "$(printf '%s' "$text" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')"
    else
        hexe api send "$(printf '%s' "$text" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')"
    fi
    rm -f "$WAV"
}

case "${1:-}" in
    start) start ;;
    stop) stop ;;
    cancel) stop_recorder; hexe_api capture false; rm -f "$WAV" ;;
    *) echo "usage: dictate.sh start|stop|cancel" >&2; exit 2 ;;
esac
