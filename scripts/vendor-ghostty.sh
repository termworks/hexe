#!/usr/bin/env bash
# Fetch the pinned ghostty and apply hexe's patch into vendor/ghostty.
#
# hexe needs one field ghostty does not have: an opaque per-cell tag recording
# which palette namespace wrote each cell. Rather than maintain a fork, the
# upstream revision is pinned here and the diff lives in patches/ as a file, so
# following ghostty is: bump GHOSTTY_REV, re-run this, fix the patch if it
# drifted.
#
# `vendor/` is generated and not committed, so a fresh clone runs this once
# before building. It lives in a script rather than in the build runner because
# CI has no oslo and therefore cannot call `.make.lua`; the recipe there runs
# this same file, so there is one definition of the pin.
set -euo pipefail

GHOSTTY_REV="${GHOSTTY_REV:-4e17eee5dea3d67aa9b0fec56be7f461c496ffe4}"
GHOSTTY_URL="${GHOSTTY_URL:-https://github.com/ghostty-org/ghostty}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dir="$root/vendor/ghostty"
patch="$root/patches/ghostty-vt-ns.patch"

test -f "$patch" || { echo "missing $patch" >&2; exit 1; }

rm -rf "$dir"
mkdir -p "$dir"

# Its own repository, and that is not cosmetic: ghostty's build derives its
# version from git, and this directory lives inside hexe's repo. Without a .git
# of its own, git walks up and finds OUR tags -- fine until hexe is tagged, and
# then ghostty's build panics with "tagged releases must be in vX.Y.Z format",
# forty lines deep in a build runner and nowhere near the cause.
git -C "$dir" init -q .
git -C "$dir" remote add origin "$GHOSTTY_URL"
git -C "$dir" fetch -q --depth 1 origin "$GHOSTTY_REV"
git -C "$dir" checkout -q FETCH_HEAD
git -C "$dir" apply --whitespace=nowarn "$patch"

echo "ghostty $GHOSTTY_REV + patches/$(basename "$patch") -> vendor/ghostty"
