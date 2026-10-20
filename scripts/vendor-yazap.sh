#!/usr/bin/env bash
# Fetch the pinned yazap and apply hexe's patches into vendor/yazap.
#
# yazap's `examplesStep` opens `./examples/` through the process cwd, which for
# a dependency is the DEPENDENT's root -- so hexe having an `examples/`
# directory made yazap iterate hexe's, and its `assert(kind == .file)` panicked
# the build on any subdirectory there. Its help writer targets stderr, which
# makes `hexe --help | less` print nothing. Both fixes are a couple of lines and
# live in patches/ as files, so following yazap is: bump YAZAP_REV, re-run this,
# fix whichever patch drifted.
#
# `vendor/` is generated and not committed, so a fresh clone runs this once
# before building. It lives in a script rather than in the build runner because
# CI has no oslo and therefore cannot call `.make.lua`; the recipe there runs
# this same file, so there is one definition of the pin.
set -euo pipefail

YAZAP_REV="${YAZAP_REV:-a85c65beefe911db5fc17bc90e756738d742dc63}"
YAZAP_URL="${YAZAP_URL:-https://github.com/PrajwalCH/yazap}"

root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/vendor/yazap"

# Every patches/yazap-*.patch, in name order, so adding one is adding a file.
patches=()
while IFS= read -r p; do patches+=("$p"); done < <(ls "$root"/patches/yazap-*.patch)
test "${#patches[@]}" -gt 0 || { echo "no patches/yazap-*.patch found" >&2; exit 1; }

rm -rf "$dir"
mkdir -p "$dir"

# Its own repository, for the same reason ghostty's is: a vendored tree inside
# hexe's repo otherwise resolves git state by walking up into ours.
git -C "$dir" init -q .
git -C "$dir" remote add origin "$YAZAP_URL"
git -C "$dir" fetch -q --depth 1 origin "$YAZAP_REV"
git -C "$dir" checkout -q FETCH_HEAD
names=()
for p in "${patches[@]}"; do
  git -C "$dir" apply --whitespace=nowarn "$p"
  names+=("$(basename "$p")")
done

echo "yazap $YAZAP_REV + ${names[*]} -> vendor/yazap"
