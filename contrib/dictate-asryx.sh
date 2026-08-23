#!/bin/sh
# asryx (https://github.com/rccyx/asryx) as a hexe dictation tool.
#
#   hexe.dictate = { command = "~/.config/hexe/dictate-asryx.sh" }
#
# asryx and hexe disagree about two things, and this script is the whole of the
# disagreement:
#
#   * asryx is a TOGGLE that exits immediately -- one invocation starts the
#     recording, the next stops it. hexe wants one process that lives for the
#     length of the dictation. So this script is that process, and it calls
#     asryx twice.
#   * asryx delivers to the CLIPBOARD. hexe reads stdout. So this reads the
#     clipboard back once asryx is done.
#
# The clipboard round-trip is the ugly part and it is asryx's design, not a
# workaround for hexe: `--pipe-to` still copies first, so nothing avoids it.
# Note that dictating REPLACES the clipboard -- set HEXE_ASRYX_RESTORE_CLIPBOARD=1
# if you would rather keep what was there.
set -eu

if ! command -v asryx >/dev/null 2>&1; then
    echo "dictate-asryx: asryx is not installed" >&2
    exit 1
fi

# Wayland only when there is actually a Wayland session to talk to. Choosing on
# the binary's presence alone reads an empty clipboard forever on an X11 login
# that happens to have wl-clipboard installed -- and the failure looks exactly
# like "you said nothing", which is a miserable thing to debug.
if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-paste >/dev/null 2>&1; then
    clip_read() { wl-paste --no-newline 2>/dev/null || true; }
    clip_write() { wl-copy 2>/dev/null || true; }
elif command -v xclip >/dev/null 2>&1; then
    clip_read() { xclip -o -selection clipboard 2>/dev/null || true; }
    clip_write() { xclip -i -selection clipboard 2>/dev/null || true; }
else
    echo "dictate-asryx: neither wl-clipboard nor xclip is installed" >&2
    exit 1
fi

BEFORE=$(clip_read)

# If a previous run died mid-recording, asryx is still capturing and our first
# invocation would STOP it instead of starting one. Clear that first.
case "$(asryx status 2>/dev/null || echo idle)" in
    recording | transcribing) asryx cancel >/dev/null 2>&1 || true ;;
esac

asryx >/dev/null 2>&1 || true          # start capture; returns at once
read -r _ignored || true               # hexe closes stdin when you stop
asryx >/dev/null 2>&1 || true          # stop, transcribe, copy

# asryx's stop path (runtime.cpp: stop_and_transcribe) runs inline with no
# fork, so by the time the call above returns the clipboard is already set and
# this loop exits on its first check. Kept because "transcribing" is a state
# asryx can report, and a future async stop would otherwise read the clipboard
# before the transcript lands -- a race that would show up as the PREVIOUS
# dictation being typed.
i=0
while [ "$i" -lt 600 ]; do
    case "$(asryx status 2>/dev/null || echo idle)" in
        idle) break ;;
    esac
    sleep 0.1
    i=$((i + 1))
done

TEXT=$(clip_read)

# Same clipboard as before means asryx delivered nothing -- an empty recording,
# or a failure it reported through notify-send. Better to type nothing than to
# type whatever the user had copied earlier.
if [ "$TEXT" = "$BEFORE" ]; then
    echo "dictate-asryx: no new transcript on the clipboard" >&2
    exit 1
fi

if [ "${HEXE_ASRYX_RESTORE_CLIPBOARD:-0}" = "1" ]; then
    printf '%s' "$BEFORE" | clip_write
fi

printf '%s' "$TEXT"
