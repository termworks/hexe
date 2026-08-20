#!/bin/sh
# Run a program with its own palette slot.
#
#     contrib/palette_run.sh 4 nvim -u NONE somefile
#     contrib/palette_run.sh 5 make
#
# The program needs to know nothing about the protocol. This claims a slot
# before it starts and releases it after it exits, so every cell the program
# writes records that namespace and can be recoloured afterwards:
#
#     hexe palette set --ns 4 4=#89b4fa 2=#50fa7b
#
# Only INDEXED colours are namespaced. A program emitting truecolor
# (38;2;r;g;b) has already chosen its exact colour and is left alone — for nvim
# that means `:set notermguicolors`, or nothing will change.
set -eu

if [ $# -lt 2 ]; then
    echo "usage: $0 <slot 0-31> <command> [args...]" >&2
    exit 2
fi

slot="$1"
shift

osc() { printf '\033]1330;%s\033\\' "$1"; }

# Released even if the program crashes or is killed. hexe deliberately does not
# guess when a region ended, so a namespace left selected would be inherited by
# the shell prompt that follows.
cleanup() { osc "end"; }
trap cleanup EXIT INT TERM

osc "use;$slot"
"$@"
