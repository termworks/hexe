#!/bin/sh
# Push a colour scheme into the terminal you are in (PLAN.md M7).
#
# Hook this to whatever changes your theme — a wallpaper timer, pywal, a
# lule/$LULE_S hook. The same script works inside hexe and outside it.
#
#   palette_hook.sh [FILE]
#
# FILE defaults to ~/.cache/wal/colors, one `#rrggbb` per line.
#
# Two layers, and it matters which is which:
#
#   OSC 4        the base palette, index 0..255. hexe forwards it to the real
#                terminal untouched, so this is what recolours ordinary cells,
#                in hexe or out of it. Always send it.
#   OSC 1330     hexe's palette namespaces: per-zone overrides on top of the
#                base. Only meaningful inside hexe, and only for the zones you
#                name. Skipped entirely elsewhere.
set -eu

COLORS="${1:-$HOME/.cache/wal/colors}"
[ -r "$COLORS" ] || exit 0

# The base palette, for every terminal including hexe's host.
i=0
while IFS= read -r line; do
    case "$line" in
        '#'??????)
            printf '\033]4;%d;%s\007' "$i" "$line" > /dev/tty 2>/dev/null || true
            i=$((i + 1))
            ;;
    esac
done < "$COLORS"

# `palette list` exits non-zero outside a live hexe session, which is the
# capability probe: no negotiation, no version check, nothing to time out on.
hexe palette list >/dev/null 2>&1 || exit 0

# Inside hexe. Give the prompt and full-screen apps their own treatment on top
# of the base palette just set. Edit to taste — these are examples, not defaults.
#
#   --ns prompt   the prompt line and what you type on it
#   --ns output   command output
#   --ns alt      full-screen apps
#
# Set an index and it moves only in that zone; leave it alone and it keeps
# falling through to the base palette above.
hexe palette set --ns prompt bg=#1a1020 || true
hexe palette set --ns alt bg=#000000 || true

# Or drive a whole zone from the same file:
#
#   hexe palette set --ns output --from "$COLORS"
