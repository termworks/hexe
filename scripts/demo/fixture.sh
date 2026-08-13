#!/usr/bin/env bash
# Build the world the demos are recorded in.
#
# The films are made with **the author's own configuration and the author's own
# shell**: `~/.config/hexe/{init.lua,layout.lua}` and `~/.config/oslo/*` are
# copied in as they are, so what a recording shows is what hexe looks like in
# daily use rather than a stripped-down rig invented for the camera.
#
# Two things are changed on the way in, and both are marked below:
#
#   * the four agent floats (`pi`, `claude`, `codex`, `antigravity`) get local,
#     offline commands. A recording must not open a paid agent, must not touch
#     a network, and must be the same film tomorrow.
#   * a small block of extra keybindings is appended, for the actions the
#     author's config does not bind but the documents describe (search,
#     copy-mode, zoom, broadcast, rename, reload, resize, nudge).
#
# Everything lives under /tmp: a demo must never touch the repository it
# documents, never the real ~/.config, and never a real session or history.
set -euo pipefail

WORK="${DEMO_WORK:-/tmp/hexe-demo-work}"
HEXE_CONFIG_SRC="${HEXE_CONFIG_SRC:-$HOME/.config/hexe}"
OSLO_CONFIG_SRC="${OSLO_CONFIG_SRC:-$HOME/.config/oslo}"

rm -rf "$WORK"
mkdir -p "$WORK"/{home/.config,state,data,run,bin,proj/src,proj/docs}

# ── the shell: oslo, the author's ────────────────────────────────────────────
[ -d "$OSLO_CONFIG_SRC" ] || { echo "no oslo config at $OSLO_CONFIG_SRC" >&2; exit 1; }
cp -r "$OSLO_CONFIG_SRC" "$WORK/home/.config/oslo"

# Helpers the copied configuration reaches for by absolute path under `$HOME`.
# The prompt's distro segment runs `~/.local/sbin/distrologo`, and with the
# fixture's HOME that path does not exist -- which puts `sh: … not found` in
# the pane on every prompt, on camera. Linked rather than copied: it is the
# author's script, and a film should run the same one.
mkdir -p "$WORK/home/.local/sbin" "$WORK/home/.local/bin"
for helper in "$HOME"/.local/sbin/*; do
    [ -x "$helper" ] && ln -sf "$helper" "$WORK/home/.local/sbin/$(basename "$helper")"
done

# ── the multiplexer: the author's config, with the agents swapped out ────────
[ -d "$HEXE_CONFIG_SRC" ] || { echo "no hexe config at $HEXE_CONFIG_SRC" >&2; exit 1; }
mkdir -p "$WORK/home/.config/hexe"
cp "$HEXE_CONFIG_SRC/init.lua" "$WORK/home/.config/hexe/init.lua"
cp "$HEXE_CONFIG_SRC/layout.lua" "$WORK/home/.config/hexe/layout.lua"

# The agent floats, replaced by offline commands with the same keys, the same
# attributes and the same visual policy. `exec oslo` on the end of a one-shot
# command on purpose: a float whose command exits *closes*, so `git log` would
# flash and be gone; the shell keeps the pane and its scrollback standing.
python3 - "$WORK/home/.config/hexe/layout.lua" <<'PATCH'
import re, sys
path = sys.argv[1]
src = open(path).read()

swaps = [
    ('"pi"',          '"git"',     'git -c color.ui=always log --oneline --graph --decorate --all; exec oslo'),
    ('"claude"',      '"files"',   'eza -la --color=always --group-directories-first; exec oslo'),
    ('"codex"',       '"monitor"', 'btop'),
    ('"antigravity"', '"editor"',  'nvim README.md'),
]

for old_name, new_name, command in swaps:
    # hexe.float("pi", { … command = "…" … })  →  same block, new title/command
    start = src.index('hexe.float(%s' % old_name)
    end = src.index('hexe.float(', start + 10)
    block = src[start:end]
    block = block.replace('hexe.float(%s' % old_name, 'hexe.float(%s' % new_name, 1)
    block = re.sub(r'title\s*=\s*"[^"]*"', 'title = %s' % new_name, block, count=1)
    block = re.sub(r'command\s*=\s*"[^"]*"', 'command = "%s"' % command, block, count=1)
    src = src[:start] + block + src[end:]

open(path, 'w').write(src)
PATCH

# The keys the documents describe that the author's config does not bind. Kept
# in a separate file so the copied config above stays byte-for-byte theirs, and
# so a reader can see exactly which keys are the demos' own.
cat > "$WORK/home/.config/hexe/demo-keys.lua" <<'EOF'
-- Extra bindings for the recordings, on keys the author's config leaves free.
local hexe = require("hexe")

return {
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.f }, hexe.action.search.enter()),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.y }, hexe.action.copy.enter()),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.g }, hexe.action.prompt.previous()),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.j }, hexe.action.prompt.next()),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.u }, hexe.action.prompt.copy_output()),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.m }, hexe.action.pane.zoom()),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.b }, hexe.action.pane.sync_toggle()),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.w }, hexe.action.pane.close()),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.e }, hexe.action.split.vertical()),
  hexe.key({ hexe.key.alt, hexe.key.r }, hexe.action.tab.rename()),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.r }, hexe.action.config.reload()),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.shift, hexe.key.up }, hexe.action.split.resize("up")),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.shift, hexe.key.down }, hexe.action.split.resize("down")),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.shift, hexe.key.left }, hexe.action.split.resize("left")),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.shift, hexe.key.right }, hexe.action.split.resize("right")),
  hexe.key({ hexe.key.alt, hexe.key.shift, hexe.key.up }, hexe.action.float.nudge("up")),
  hexe.key({ hexe.key.alt, hexe.key.shift, hexe.key.down }, hexe.action.float.nudge("down")),
  hexe.key({ hexe.key.alt, hexe.key.shift, hexe.key.left }, hexe.action.float.nudge("left")),
  hexe.key({ hexe.key.alt, hexe.key.shift, hexe.key.right }, hexe.action.float.nudge("right")),
}
EOF

# Merge them into the copied config's `keys` list, at the end, so the author's
# own bindings still win any collision — first match wins, and theirs are
# first.
python3 - "$WORK/home/.config/hexe/init.lua" <<'PATCH'
import sys
path = sys.argv[1]
src = open(path).read()

# Appended as the LAST argument to concat(), so every one of the author's own
# bindings is earlier in the list than every demo binding — binds are resolved
# first-match-wins, so theirs still win any collision.
close = "  }),\n\n  mux = {"
assert close in src, "the config's keys list is not where the fixture expects it"
src = src.replace(
    close,
    '  }, dofile(os.getenv("HOME") .. "/.config/hexe/demo-keys.lua")),\n\n  mux = {',
    1,
)
open(path, "w").write(src)
PATCH

# ── the project the panes start in ───────────────────────────────────────────
cat > "$WORK/proj/README.md" <<'EOF'
# demo
A project with enough in it to be worth looking at.
EOF
cat > "$WORK/proj/Makefile" <<'EOF'
build:
	@echo building
test:
	@echo ok
EOF
for n in main parser render config; do
    printf 'pub fn %s() void {\n    // …\n}\n' "$n" > "$WORK/proj/src/$n.zig"
done
printf 'notes\n' > "$WORK/proj/docs/notes.md"

if command -v git >/dev/null; then
    git -C "$WORK/proj" init -q -b main
    git -C "$WORK/proj" add -A 2>/dev/null || true
    git -C "$WORK/proj" -c user.email=demo@example.com -c user.name=demo \
        commit -qm "the demo tree" 2>/dev/null || true
    printf 'one more line\n' >> "$WORK/proj/README.md"
fi

# A second directory, for the demos about per-directory behaviour: floats that
# keep one instance per working directory need two directories to show it.
mkdir -p "$WORK/other/src"
printf '# other\n' > "$WORK/other/README.md"
printf 'pub fn other() void {}\n' > "$WORK/other/src/other.zig"
if command -v git >/dev/null; then
    git -C "$WORK/other" init -q -b main
    git -C "$WORK/other" add -A 2>/dev/null || true
    git -C "$WORK/other" -c user.email=demo@example.com -c user.name=demo \
        commit -qm "the other tree" 2>/dev/null || true
fi

# ── scripts the demos run rather than type ───────────────────────────────────
# Quoting a nested `sh -c` through a line typed one character at a time is a
# way to record a shell escaping bug instead of a feature.
cat > "$WORK/bin/report" <<'EOF'
#!/usr/bin/env bash
# A float that answers a question and leaves the answer behind: whatever it
# writes to the --result-file path is what the calling command gets back.
echo "counting the tree…"
sleep 1
find . -name '*.zig' | wc -l > /tmp/hexe-demo-work/pick.txt
echo "zig files: $(cat /tmp/hexe-demo-work/pick.txt)"
sleep 3
EOF
cat > "$WORK/bin/progress" <<'EOF'
#!/usr/bin/env bash
# OSC 9;4: a pane telling its terminal how far along it is. State 1 is a
# percentage, state 0 clears it.
for pct in 20 45 70 95; do
    printf '\033]9;4;1;%s\007' "$pct"
    sleep 1.2
done
printf '\033]9;4;0\007'
EOF
chmod +x "$WORK/bin/report" "$WORK/bin/progress"

# ── the project session config, for the session-manager demo ─────────────────
cat > "$WORK/proj/.hexe.lua" <<'EOF'
local hexe = require("hexe")

return hexe.setup({
  ses = {
    layouts = {
      hexe.layout("demoproj", {
        root = ".",
        tabs = {
          hexe.tab("code", {
            root = hexe.split("horizontal", {
              hexe.pane({ cwd = "src" }),
              hexe.split("vertical", {
                hexe.pane({ command = "make build" }),
                hexe.pane({ cwd = "docs" }),
              }),
            }, { ratio = 0.55 }),
          }),
          hexe.tab("notes", {
            root = hexe.pane({ cwd = "docs" }),
          }),
        },
        floats = {
          hexe.float("log", {
            key = "8",
            title = "log",
            command = "git log --oneline --graph --decorate; exec oslo",
            size = { width = 70, height = 50 },
          }),
        },
      }),
    },
  },
})
EOF

echo "$WORK"
