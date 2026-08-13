#!/usr/bin/env bash
# Build the world the demos are recorded in.
#
# Everything a recording can see is built here: the project directory the panes
# start in, the HOME whose .bashrc fixes the prompt, and the hexe config whose
# keys, floats and status bar the films are demonstrating. Fixed content, so a
# recording made today and one made after a refactor differ only by what hexe
# did.
#
# Everything lives under /tmp: a demo must never touch the repository it
# documents, and must never touch the real ~/.config/hexe or a real session.
set -euo pipefail

WORK="${DEMO_WORK:-/tmp/hexe-demo-work}"
rm -rf "$WORK"
mkdir -p "$WORK"/{home,config/hexe,state,run,proj/src,proj/docs,cast}

# ── the shell ────────────────────────────────────────────────────────────────
# HOME is the fixture's, so the prompt in every recording is this one rather
# than whatever the person recording keeps, and so no demo can read or write a
# real history file.
cat > "$WORK/home/.bashrc" <<'EOF'
# The build under test goes in front of whatever else is on $PATH, and it has
# to happen here rather than in the recorder's environment: the pane's shell is
# started as a login shell, so the system profile has already put ~/.local/bin
# ahead of anything the recorder exported. Without this a demo types `hexe` and
# gets the *installed* hexe, which then refuses to talk to the daemon this
# build started -- a version handshake failure, on camera.
[ -n "${HEXE_DEMO_BIN:-}" ] && export PATH="$HEXE_DEMO_BIN:$PATH"

# Not exported, and with no `\[ \]` in it. Both are on camera: an exported PS1
# is inherited by shells that never read this file, and bash prints `\[` and
# `\]` literally in a shell that is interactive without readline -- which is
# exactly what a float running `sh -c '…; exec bash'` is.
PS1='\033]133;A\007\e[38;5;5mdemo\e[0m \e[38;5;250m\W\e[0m $ \033]133;B\007'
export HISTFILE=
export LANG=C.UTF-8
alias ls='ls --color=never'

# Two things a shell tells its terminal, and hexe reads both.
#
# OSC 7 is the working directory. Without it hexe cannot tell that a pane has
# moved, and every `per_cwd` float in the session collapses onto one instance.
# hexe's own `hexe shell init bash` emits exactly this line.
#
# OSC 133 marks where a prompt begins and ends and where a command's output is.
# It is what `hexe.action.prompt.previous/next/copy_output` navigate by, and
# **hexe's bash/zsh/fish integrations do not emit it** -- only oslo does. A
# shell that wants those keys has to mark its own prompts, so the fixture does.
__demo_precmd() {
    local status=$?
    printf '\033]133;D;%s\007' "$status"
    printf '\033]7;file://%s%s\007' "${HOSTNAME:-localhost}" "$PWD"
}
__demo_preexec() { printf '\033]133;C\007'; }
PROMPT_COMMAND=__demo_precmd
trap '__demo_preexec' DEBUG
# The prompt demo asks for hexe's own prompt instead of the flat one above.
if [ -n "${HEXE_DEMO_SHP:-}" ] && command -v hexe >/dev/null; then
    eval "$(hexe shp init bash)"
fi
EOF
cat > "$WORK/home/.inputrc" <<'EOF'
set enable-bracketed-paste off
EOF

# Two scripts the demos run rather than type. Quoting a nested `bash -c` through
# a line that is typed one character at a time is a way to record a shell
# escaping bug instead of the feature.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/pick" <<'EOF'
#!/usr/bin/env bash
# A picker, for the float that captures a result: whatever it writes to the
# path hexe passed as --result-file is what the calling command gets back.
ls src
read -r -p "pick: " choice
echo "$choice" > /tmp/hexe-demo-work/pick.txt
EOF
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
chmod +x "$WORK/bin/pick" "$WORK/bin/report" "$WORK/bin/progress"

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
            key = "9",
            title = "log",
            command = "git log --oneline --graph --decorate; exec bash",
            size = { width = 70, height = 50 },
          }),
        },
      }),
    },
  },
})
EOF

# ── the config the demos run under ───────────────────────────────────────────
# Deliberately not the author's own: every key a film presses is spelled out
# here, so a reader can put the same lines in their config and get the same
# recording. Keys are all Ctrl+Alt+<letter> or Alt+<digit>, which is what a
# terminal without the kitty keyboard protocol can carry, so the demos work the
# same in the recorder as in a terminal that has neither.
cat > "$WORK/config/hexe/layout.lua" <<'EOF'
local hexe = require("hexe")

return hexe.layout("default", {
  enabled = true,
  tabs = {
    hexe.tab("main", { root = hexe.pane({ cwd = "." }) }),
  },
  floats = {
    -- `exec bash` on the end of a float command on purpose: a float whose
    -- command exits *closes*, so a one-shot like `git log` would flash and be
    -- gone. The shell keeps the pane -- and its scrollback -- standing.
    hexe.float("git", {
      key     = "1",
      title   = "git",
      command = "git -c color.ui=always log --oneline --graph --decorate --all; exec bash",
      attrs   = { per_cwd = true, sticky = true, global = true, exclusive = true },
      size    = { width = 80, height = 60 },
    }),
    hexe.float("files", {
      key     = "2",
      title   = "files",
      command = "ls --color=never; exec bash",
      attrs   = { per_cwd = true, sticky = true, global = true },
      size    = { width = 45, height = 80 },
      position = { x = 100, y = 50 },
    }),
    hexe.float("scratch", {
      key   = "3",
      title = "scratch",
      attrs = { global = false, destroy = true },
      size  = { width = 50, height = 40 },
      position = { x = 0, y = 0 },
    }),
    hexe.float("sandbox", {
      key       = "0",
      title     = "sandbox",
      isolation = { profile = "sandbox", memory = "512M", pids = 100 },
      size      = { width = 70, height = 55 },
    }),
  },
})
EOF

cat > "$WORK/config/hexe/init.lua" <<'EOF'
local hexe = require("hexe")

local config_home = os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")
local layout = dofile(config_home .. "/hexe/layout.lua")

local function segments(list)
  for i, seg in ipairs(list) do list[i] = hexe.segment(seg) end
  return list
end

local function focused_split(ctx)
  local p = ctx.pane(0)
  return p and p.focus_split
end

return hexe.setup({
  theme = hexe.theme({
    styles = {
      ["status.directory"] = "bg:237 fg:15",
      ["git.branch"] = "bg:5 fg:0",
    },
  }),

  keys = {
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.q }, hexe.action.quit()),
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.d }, hexe.action.detach()),

    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.h }, hexe.action.split.horizontal(), { when = focused_split }),
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.v }, hexe.action.split.vertical(), { when = focused_split }),
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.w }, hexe.action.pane.close()),
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.o }, hexe.action.pane.select()),
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.z }, hexe.action.pane.disown()),
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.a }, hexe.action.pane.adopt()),

    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.m }, hexe.action.pane.zoom()),
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.s }, hexe.action.pane.sync_toggle()),

    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.t }, hexe.action.tab.new()),
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.n }, hexe.action.tab.next()),
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.b }, hexe.action.tab.prev()),
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.x }, hexe.action.tab.close()),
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

    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.up }, hexe.action.focus.move("up")),
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.down }, hexe.action.focus.move("down")),
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.left }, hexe.action.focus.move("left")),
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.right }, hexe.action.focus.move("right")),

    hexe.key({ hexe.key.alt, hexe.key["1"] }, hexe.action.float.toggle("1")),
    hexe.key({ hexe.key.alt, hexe.key["2"] }, hexe.action.float.toggle("2")),
    hexe.key({ hexe.key.alt, hexe.key["3"] }, hexe.action.float.toggle("3")),
    hexe.key({ hexe.key.alt, hexe.key["0"] }, hexe.action.float.toggle("0")),

    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.f }, hexe.action.search.enter()),
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.y }, hexe.action.copy.enter()),
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.c }, hexe.action.clipboard.copy()),
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.g }, hexe.action.prompt.previous()),
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.j }, hexe.action.prompt.next()),
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.u }, hexe.action.prompt.copy_output()),

    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.p }, hexe.action.overlay.sprite_toggle()),
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.k }, hexe.action.overlay.keycast_toggle()),
    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.e }, hexe.action.system.notify()),
  },

  mux = {
    confirm = { exit = true, detach = false, disown = false, close = false },
    floats = {
      defaults = {
        size  = { width = 80, height = 65 },
        color = { active = 5, passive = 237 },
      },
      adhoc = {
        size  = { width = 70, height = 55 },
        color = { active = 4, passive = 237 },
      },
    },
    splits = { color = { active = 5, passive = 237 } },
  },

  status = {
    enabled = true,
    left = segments({
      hexe.segment.session({ priority = 10, style = "bg:5 fg:0", prefix = " ", suffix = " " }),
      hexe.segment.pod_name({ priority = 20, style = "bg:237 fg:250", prefix = " ", suffix = " " }),
    }),
    center = segments({
      {
        name = "tabs",
        priority = 1,
        render = function(ctx) return hexe.segment.tabs(ctx) end,
        tab_title = "name",
        active_style = "bg:5 fg:0 bold",
        inactive_style = "bg:237 fg:250",
        separator = " ",
      },
    }),
    right = segments({
      hexe.segment.git_branch({ priority = 30, style = "bg:5 fg:0", prefix = " ", suffix = " " }),
      hexe.segment.directory({ priority = 40, style = "bg:237 fg:15", prefix = " ", suffix = " " }),
    }),
  },

  prompt = {
    left = segments({
      hexe.segment.username({ priority = 10, style = "bg:5 fg:0", prefix = " ", suffix = " " }),
      hexe.segment.status({ priority = 20, style = "bg:0 fg:9", prefix = " ", suffix = " " }),
    }),
    right = segments({
      hexe.segment.directory({ priority = 10, style = "bg:237 fg:15", prefix = " ", suffix = " " }),
      hexe.segment.git_branch({ priority = 20, style = "bg:5 fg:0", prefix = " ", suffix = " " }),
    }),
  },

  pop = {
    notify = {
      mux = { fg = 232, bg = 5, bold = true, padding_x = 2, alignment = "center", duration_ms = 2500 },
    },
    widgets = {
      keycast = { enabled = false, position = "bottomright", duration_ms = 2000 },
      pokemon = { enabled = false, position = "topright" },
    },
  },

  ses = { layouts = { layout } },
})
EOF

echo "$WORK"
