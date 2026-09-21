#!/usr/bin/env bash
# Try OSC 1332 stretch lines in a throwaway hexe, without touching your sessions.
#
#   scripts/try_stretch.sh              build, then open a test hexe on the demo
#   scripts/try_stretch.sh --no-build   use the binary already in zig-out/
#
# It runs this checkout's zig-out/bin/hexe on its own profile (default
# `stretchtry`, override with HEXE_TRY_PROFILE), so your running hexe, its
# daemon and its sessions are left alone. The first pane shows the demo and
# then drops into your shell. Things to try in there:
#
#   - resize the terminal window: every stretch line follows the new width
#   - split the pane or open a float: lines re-lay out to the new pane width
#   - scroll back: lines in history follow the width too
#   - run scripts/demo_stretch.py again to draw them afresh
#
# Exit the shell (or Ctrl-C) to leave; only the test profile is stopped.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
profile="${HEXE_TRY_PROFILE:-stretchtry}"
hexe="$root/zig-out/bin/hexe"
real_shell="${SHELL:-/bin/sh}"

if [[ "${1:-}" != "--no-build" ]]; then
  echo "building hexe (ReleaseFast)..."
  (cd "$root" && zig build -Doptimize=ReleaseFast -Dstrip=true)
fi
[[ -x "$hexe" ]] || { echo "no $hexe; build first" >&2; exit 1; }

# The pane's shell: show the demo, then hand over to your normal shell. A pane
# started with arguments (`-c …`) is passed straight through.
wrap="$(mktemp -t hexe-stretch-shell.XXXXXX)"
cat > "$wrap" <<EOF
#!/bin/sh
[ \$# -gt 0 ] && exec "$real_shell" "\$@"
python3 "$root/scripts/demo_stretch.py"
echo
echo "Resize the window, split the pane, or scroll back: the lines above stay full width."
echo "Draw them again with:  $root/scripts/demo_stretch.py"
exec "$real_shell"
EOF
chmod +x "$wrap"

cleanup() {
  rm -f "$wrap"
  pkill -f "instance $profile" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

SHELL="$wrap" "$hexe" --profile "$profile" terminal new -n stretch
