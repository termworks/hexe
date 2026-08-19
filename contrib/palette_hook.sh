#!/bin/sh
# Push a colour scheme into the pane you are in (PLAN.md M7).
#
# Hook this to whatever changes your theme — a wallpaper timer, pywal, a
# lule/$LULE_S hook. Inside hexe it repaints the panes; outside it falls back to
# the old broadcast, so the same script works either way.
#
#   palette_hook.sh [FILE]
#
# FILE defaults to ~/.cache/wal/colors. Accepted line forms:
#
#   #rrggbb                bare colour, taking the next index in order
#   <index>=#rrggbb        an explicit palette index
#   bg #0a0a0a             fg / bg / cursor address the defaults
#
# Namespaces let you go further than one scheme per pane:
#
#   hexe palette set --ns prompt bg=#1a1020    # only the prompt zones
#   hexe palette set --ns output 1=#ff5555     # only command output
#   hexe palette set --ns alt    bg=#000000    # only full-screen apps
#
set -eu

COLORS="${1:-$HOME/.cache/wal/colors}"

# `palette list` exits non-zero outside a live hexe session, which is the
# capability probe: no negotiation, no version check.
if hexe palette list >/dev/null 2>&1; then
    # No --ns: '*' addresses every namespace, so the whole pane moves at once.
    hexe palette set --from "$COLORS"
    exit 0
fi

# Not in hexe. Broadcast OSC 4 to every tty the way a bare terminal expects.
[ -r "$COLORS" ] || exit 0
i=0
while IFS= read -r line; do
    case "$line" in
        '#'??????)
            printf '\033]4;%d;%s\007' "$i" "$line" > /dev/tty 2>/dev/null || true
            i=$((i + 1))
            ;;
    esac
done < "$COLORS"
