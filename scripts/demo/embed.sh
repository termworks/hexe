#!/usr/bin/env bash
# Put the published recording into the document it belongs to.
#
#   ./scripts/demo/embed.sh
#
# Idempotent: the block is delimited, so running this again after a re-record
# replaces the old player rather than stacking a second one under the heading.
# A document with no recording is left exactly as it is.
set -euo pipefail

cd "$(dirname "$0")/../.."
MAP="scripts/demo/casts.tsv"
[ -s "$MAP" ] || { echo "nothing published yet -- run scripts/demo/publish.sh" >&2; exit 1; }

BEGIN='<!-- demo:begin -->'
END='<!-- demo:end -->'

while IFS=$'\t' read -r slug id; do
    [ -n "$slug" ] || continue
    doc="docs/features/$slug.md"
    [ -f "$doc" ] || { echo "no document for $slug" >&2; continue; }

    block=$(printf '%s\n[![%s](https://asciinema.org/a/%s.svg)](https://asciinema.org/a/%s)\n%s' \
        "$BEGIN" "$slug demo" "$id" "$id" "$END")

    if grep -qF "$BEGIN" "$doc"; then
        awk -v begin="$BEGIN" -v end="$END" -v block="$block" '
            $0 == begin { print block; skip = 1; next }
            $0 == end   { skip = 0; next }
            !skip
        ' "$doc" > "$doc.tmp" && mv "$doc.tmp" "$doc"
        echo "$doc updated"
    else
        # First time: under the opening paragraph, before the first "## "
        # heading, so a reader sees what the feature looks like before reading
        # how it is built.
        awk -v block="$block" '
            !done && /^## / { print block; print ""; done = 1 }
            { print }
        ' "$doc" > "$doc.tmp" && mv "$doc.tmp" "$doc"
        echo "$doc embedded"
    fi
done < "$MAP"
