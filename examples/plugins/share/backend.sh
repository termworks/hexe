#!/bin/sh
# A stream backend, in the shape hexe hands one over.
#
# stdin is asciicast v2 -- a header line, then `[t,"o",data]` events -- which is
# what `asciinema play` reads and what a `.cast` file contains. Nothing here is
# hexe-specific.
#
# This one writes a file and reports a `file://` address, which is enough to see
# the whole path working. Point it at a real publisher and it becomes sharing.
set -eu

OUT="${HEXE_SHARE_CAST:-${XDG_RUNTIME_DIR:-/tmp}/hexe-share.cast}"
ADDRESS="${XDG_RUNTIME_DIR:-/tmp}/hexe-share-address"

: > "$OUT"
printf 'file://%s' "$OUT" > "$ADDRESS"

while IFS= read -r line; do
    printf '%s\n' "$line" >> "$OUT"

    # The one rule that is not optional. A password prompt means the scrollback
    # you kept is already tainted: the bytes that drew it went out BEFORE hexe
    # could know. Clearing is the point -- pausing is not enough.
    case "$line" in
        *'"m"'*password-on*) : > "$OUT" ;;
    esac
done

rm -f "$ADDRESS"
