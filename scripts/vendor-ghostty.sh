#!/usr/bin/env bash
# Fetch the pinned ghostty and apply hexe's patch into vendor/ghostty.
#
# hexe needs two things ghostty's exported Zig module does not give it:
#
#   - ghostty-vt-ns:    an opaque per-cell tag recording which palette namespace
#                       wrote each cell.
#   - ghostty-vt-kitty: the Kitty graphics protocol. Upstream synthesises its
#                       `kitty_graphics` build option from `oniguruma`, and the
#                       Zig module force-disables oniguruma, so images compile
#                       out entirely; and the readonly stream drops APC, which
#                       is what the protocol travels in.
#
# Rather than maintain a fork, the upstream revision is pinned here and the
# diffs live in patches/ as files, so following ghostty is: bump GHOSTTY_REV,
# re-run this, fix the patches if they drifted.
#
# `vendor/` is generated and not committed, so a fresh clone runs this once
# before building. It lives in a script rather than in the build runner because
# CI has no oslo and therefore cannot call `.make.lua`; the recipe there runs
# this same file, so there is one definition of the pin.
set -euo pipefail

GHOSTTY_REV="${GHOSTTY_REV:-4e17eee5dea3d67aa9b0fec56be7f461c496ffe4}"
GHOSTTY_URL="${GHOSTTY_URL:-https://github.com/ghostty-org/ghostty}"

root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/vendor/ghostty"
patches=(
  "$root/patches/ghostty-vt-ns.patch"
  "$root/patches/ghostty-vt-kitty.patch"
)

for patch in "${patches[@]}"; do
  test -f "$patch" || { echo "missing $patch" >&2; exit 1; }
done

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
for patch in "${patches[@]}"; do
  git -C "$dir" apply --whitespace=nowarn "$patch"
done

names=""
for patch in "${patches[@]}"; do
  names="${names:+$names, }patches/$(basename "$patch")"
done
echo "ghostty $GHOSTTY_REV + $names -> vendor/ghostty"
