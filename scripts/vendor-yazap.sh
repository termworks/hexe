#!/usr/bin/env bash
# Fetch the pinned yazap and apply hexe's patch into vendor/yazap.
#
# yazap's `examplesStep` opens `./examples/` through the process cwd, which for
# a dependency is the DEPENDENT's root -- so hexe having an `examples/`
# directory made yazap iterate hexe's, and its `assert(kind == .file)` panicked
# the build on any subdirectory there. The fix is two lines and lives in
# patches/ as a file, so following yazap is: bump YAZAP_REV, re-run this, fix
# the patch if it drifted.
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
patch="$root/patches/yazap-examples-cwd.patch"

test -f "$patch" || { echo "missing $patch" >&2; exit 1; }

rm -rf "$dir"
mkdir -p "$dir"

# Its own repository, for the same reason ghostty's is: a vendored tree inside
# hexe's repo otherwise resolves git state by walking up into ours.
git -C "$dir" init -q .
git -C "$dir" remote add origin "$YAZAP_URL"
git -C "$dir" fetch -q --depth 1 origin "$YAZAP_REV"
git -C "$dir" checkout -q FETCH_HEAD
git -C "$dir" apply --whitespace=nowarn "$patch"

echo "yazap $YAZAP_REV + patches/$(basename "$patch") -> vendor/yazap"
