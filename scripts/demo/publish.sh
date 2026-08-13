#!/usr/bin/env bash
# Upload recorded casts to asciinema.org and remember which id belongs to which demo.
#
#   ./scripts/demo/publish.sh [slug …]        # default: every cast in /tmp/hexe-demos
#
# The mapping lands in scripts/demo/casts.tsv so that re-embedding does not mean
# re-uploading, and so a later re-record can replace one recording without
# disturbing the others.
#
# **Uploads made by an unauthenticated CLI are deleted after seven days.**
# Running `asciinema auth` once and opening the URL it prints claims this
# machine's uploads -- including the ones already made -- into an account, and
# they then stay. Nothing here can do that step for you.
set -euo pipefail

cd "$(dirname "$0")/../.."
MAP="scripts/demo/casts.tsv"
CASTS="${CAST_DIR:-/tmp/hexe-demos}"
touch "$MAP"

targets=()
if [ $# -gt 0 ]; then
    for slug in "$@"; do targets+=("$CASTS/$slug.cast"); done
else
    while IFS= read -r c; do targets+=("$c"); done < <(find "$CASTS" -name '*.cast' | sort)
fi

for cast in "${targets[@]}"; do
    slug=$(basename "${cast%.cast}")
    [ -f "$cast" ] || { echo "no cast for $slug" >&2; continue; }

    # Already published, and the recording has not been made again since. The
    # second half of that is a real check: skipping on the name alone means a
    # re-recorded demo can never be uploaded again and the document keeps
    # pointing at the old film, silently.
    existing=$(awk -v s="$slug" '$1 == s {print $2}' "$MAP")
    if [ -n "$existing" ] && [ ! "$cast" -nt "$MAP" ]; then
        echo "$slug already at https://asciinema.org/a/$existing"
        continue
    fi

    url=$(asciinema upload "$cast" 2>&1 | grep -oE 'https://asciinema\.org/a/[A-Za-z0-9]+' | head -1)
    if [ -z "$url" ]; then
        echo "FAILED to upload $slug" >&2
        continue
    fi
    id="${url##*/}"
    # The old row goes first, or `sort -u` below keeps both and the next read
    # takes whichever sorted first -- which is the old one as often as not.
    if [ -n "$existing" ]; then
        awk -v s="$slug" '$1 != s' "$MAP" > "$MAP.new" && mv "$MAP.new" "$MAP"
    fi
    printf '%s\t%s\n' "$slug" "$id" >> "$MAP"
    echo "$slug -> $url"
    # asciinema.org is somebody else's server; a burst of uploads is rude.
    sleep 2
done

sort -o "$MAP" -u "$MAP"
echo "--- $(wc -l < "$MAP") recordings in $MAP"
