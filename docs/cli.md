# The command line

Everything hexe does from the outside: start and attach sessions, list what is running, type into a
pane, open a float, render a prompt, record a cast. A session is not a black box — it is a set of
processes with names, and the CLI is how a script talks to them.

```sh
hexe                        # bare: attach here, or pick interactively, or start fresh
hexe new -n work            # start a new session
hexe attach                 # interactive session picker (or `hexe attach work`, `hexe attach .`)
hexe detach                 # cleanly detach current/selected session
hexe ls --details           # list running sessions and pane trees (stdout)
hexe terminal send --last --enter "make test"
```

<!-- demo:begin -->
[![cli demo](https://asciinema.org/a/1263025.svg)](https://asciinema.org/a/1263025)
<!-- demo:end -->

## How it works

Five ergonomic top-level shortcuts for everyday session management (`attach`/`a`, `detach`/`d`, `new`, `list`/`ls`, `kill`), plus the full layered command groups:

| command | alias | what it is |
|---|---|---|
| `attach` | `a` | attach to a session (interactive picker when omitted, `.` for current directory) |
| `detach` | `d` | cleanly detach an attached session (defaults to `$HEXE_SESSION` or interactive picker) |
| `new` | | create a new session |
| `list` | `ls` | list sessions, panes, and roots |
| `kill` | | kill a session, pane, or float |
| `terminal` | `mux`, `multiplexer` | the frontend and everything it owns |
| `session` | `ses` | the session daemon |
| `layout` | `lay` | project session configs |
| `pod` | | per-pane PTY daemons |
| `shell` | `shp` | the prompt renderer and shell hooks |
| `popup` | `pop` | notifications, confirms, choosers |
| `config` | `cfg` | validate, dump, paths |
| `record` | | recording lifecycle |
| `allow` | | trust a project config's hooks |
| `web`, `syslink` | | frontend adapters (probes and serving loops) |

```sh
hexe new [-n <name>] [-P <profile>] [-T] [--log <lvl>] [--logfile <path>]
hexe attach [<name-or-uuid-prefix|.>]   # omit target on a TTY to open the interactive picker
hexe detach [<name-or-uuid-prefix>]     # cleanly detach current ($HEXE_SESSION) or target session
hexe ls [--details] [--json] [<dir>]    # alias for `hexe session list` / `hexe terminal list`
hexe kill <id>                          # a session, a pane, or a float

hexe terminal new [-n <name>] [-I <instance>] [-T] [--log <lvl>] [--logfile <path>]
hexe terminal attach [<name-or-uuid-prefix|.>]
hexe terminal detach [<name-or-uuid-prefix>]
hexe terminal list [--details] [--json] [<dir>]
hexe terminal kill <id>            # a session, a pane, or a float
hexe terminal float --command <cmd> [--title …] [--size w,h,x,y] [--isolation …] [--result-file …]
hexe terminal float --sub --command <cmd>            # a sub-float of the calling float
hexe terminal send <text> [--pane <n>|--uuid <u>|--last|--creator|--broadcast] [--enter] [--ctrl <key>]
hexe terminal read [--pane <n>|--uuid <u>] [-n <lines>|-c <commands>]
hexe terminal status [<idle|working|blocked|done>] [--pane <n>|--uuid <u>|--chip <n>] [--note <text>] [--clear] [--attention] [--json]
hexe terminal wait [--pane <n>|--uuid <u>|--chip <n>] [--until exit|idle|done|blocked|attention|status:<s>|pattern:<t>] [--pattern <t>] [--idle-ms <ms>] [--timeout <ms>] [--print] [--json]
hexe terminal notify <msg> [--uuid <u>|--last|--broadcast]
hexe terminal info [--uuid <u>|--last|--creator]
hexe terminal focus left|right|up|down
hexe terminal layout save|load|list [<name>]
hexe terminal record --out <file.cast> [--capture-input]

hexe session list [--details] [--json] [<dir>]  hexe session status
hexe session detach [<target>]                  hexe session kill <uuid>
hexe session clear [--orphans] [--force]        hexe session export <uuid>
hexe session daemon [--foreground]

hexe layout open <target>[:<tab>]           hexe layout save [--name <name>] --scope local|global|both
hexe layout list [--json]

hexe pod list [--where <lua>] [--probe] [--alive] [--json]
hexe pod new [-n <name>] [--shell …] [--cwd …] [--labels a,b] [--alias] [--json]
hexe pod send <text> [--uuid|--name] [--enter] [--ctrl <letter>]
hexe pod attach [--uuid|--name] [--detach <key>] [--record <f.cast>] [--capture-input]
hexe pod record --out <file.cast>                     hexe pod kill [--uuid <u>|--name <n>] [--signal <n|NAME>] [--force]
hexe pod gc [--dry-run]                               hexe pod daemon --uuid <32hex> --socket <path> […]

hexe shell init bash|zsh|fish               hexe shell prompt [--status …] [--right]
hexe popup notify|confirm|choose            hexe config check|validate|dump|paths
hexe record start|stop|status|toggle --scope pod|mux
```

### Addressing things

The address is a hierarchy — **session → pane** — and a pane name is unique
*within its session*, so two sessions may each have a `romeo`.

| | |
|---|---|
| `--uuid <hex>` | absolute: a full pane uuid or a unique prefix of one. Needs nothing else |
| `--pane <name>` | by name, unique within its session |
| `--session <s>` | which session `--pane` is in: its name, or a uuid prefix |
| `--chip <n>` | a member of **this float's family**, by the number the title row shows: `0` is the parent, children count up |
| `--last` | the pane this one came from |
| `--creator` | the pane the command was launched from |
| `--broadcast` | every pane in the session |

Split or float is **not** part of the address: both are panes, drawn from one
name pool, so the name alone is enough. Nor is the tab.

```
hexe terminal send --pane romeo --enter "make test"        # inside hexe
hexe terminal send --session work --pane romeo --enter …   # another session
hexe terminal send --uuid b717c471 --enter …               # from anywhere
hexe terminal send --chip 1 --enter "make test"            # a sub-float of mine
hexe terminal read --chip 1 -c 1                           # and what it printed
```

`--chip` is how a float drives its own sub-floats: the family is the one holding
the calling pane, so an agent that opened helpers beside itself addresses them by
the number on screen instead of carrying uuids. `--uuid` beside it names *which*
family rather than which pane. It is answered by the frontend, so unlike the rest
it needs the session attached — a chip is a thing on screen, so that is the same
condition as there being chips to address.

Inside a pane, `HEXE_PANE_UUID` and `HEXE_SESSION` are already set, so a script
usually needs no target at all.

**Nothing is ever guessed.** A selector matching two panes is refused and lists
them, rather than picking the first or the newest. That is why `--session`
exists: without it, a name two sessions share is ambiguous.

A **profile** (`-P`/`--profile`) is a level above all of this: a separate daemon
with its own socket directory, so nothing in one can see the other. If you are
not using the default profile you must say which — it cannot be discovered.

The targeting commands exit with the reason, so a script can branch without
reading the message:

| | |
|---|---|
| `0` | done |
| `1` | no target given |
| `2` | the daemon or the pane's pod could not be reached |
| `3` | no such session, or no such pane |
| `4` | ambiguous: say which |

Typing (`terminal send`) and reading (`terminal read`) are both served by the
pane's **pod**, which owns the pty and outlives the frontend — so both reach a
pane in a **detached** session. Anything that genuinely needs a frontend (keys
through the keybinding machinery, focus) does not.

### Reading a pane back

```
hexe terminal read --pane romeo              # the last command's output
hexe terminal read --pane romeo -c 3         # the last three commands
hexe terminal read --pane romeo -n 40        # the last 40 lines
hexe terminal read --uuid b717c471 | grep FAIL
```

| | |
|---|---|
| `-n <lines>` | the last N rows that have anything on them |
| `-c <commands>` | the output of the last N commands |
| neither | the last command's output |

The command-based modes need **OSC 133 prompt marks**, which come from your
prompt, not from `hexe shell init` — that installs hexe's own IPC hooks. A
prompt renderer that emits `133;A`/`B`/`C` gives hexe the row marks it needs; in
plain bash, `PS1` and `PS0` are enough:

```sh
PS1=$'\033]133;A\007$ \033]133;B\007'
PS0=$'\033]133;C\007'
```

Without marks, `-n` still works and the other two exit `3` telling you so,
rather than handing back a screenful dressed up as a command's output.

Output goes to **stdout** so it can be piped. `-c 1` and a bare read give the
output alone; `-c 2` and above keep the prompt line *between* commands, because
that is what separates one command's output from the next.

The pod answers from a bounded **4 MiB** ring, so very old history is gone. When
the ring has already wrapped, a note on **stderr** says the answer may begin
mid-history — stdout stays clean for the pipe.

Sessions additionally resolve by **prefix**, over both names and uuids, which is why
`hexe terminal attach nido` and `hexe terminal attach a3f2` both work.

### Flags the reference page never mentioned

| | |
|---|---|
| `pod list --where '<lua>'` | a Lua predicate *body*, not a path or a glob: `--where 'return pod.name == "notes"'`. `pod` is the row |
| `pod list --probe` | ask each pod whether it actually answers, rather than trusting its metadata file |
| `pod new --labels a,b,c` / `--alias` | tag a pod, and give it a `pod@<name>.sock` symlink beside its uuid socket |
| `pod send --ctrl <letter>` | send a control character; combines with `--enter`, which appends the newline after it |
| `pod kill --signal <n\|NAME>` / `--force` | a specific signal, or signal-then-`SIGKILL` after 50 ms |
| `pod attach --record <f> [--capture-input]` | attach and record in one go |
| `session list <dir>` | positional directory filter: `hexe ses list .` |
| `terminal new/attach --remote host[:port] [-u user] [-i identity]` | attach across a link; identity defaults to `~/.ssh/id_ed25519` |
| `terminal new/attach --ses-socket <path>` / `--no-autostart-ses` | point at a specific daemon, or refuse to start one |
| `terminal float --key <k>` | the key that dismisses the float; a dismissed float exits 130 and its output is discarded |
| `terminal float --sub` | open a sub-float of the calling float: shares its key and rectangle, dies with it, does not block. See [floats](floats.md) |
| `shell init <shell> --no-comms` | the prompt hooks without the shell→mux reporting |
| `--log trace\|debug\|info` and `--logfile` / `-L` | on every daemon; the level name is the only accepted spelling |
| `--help` / `-h` | on every command and subcommand, generated from the flag list |

### Output, color, and interactive pickers

- **Listings and status output go to stdout** (`hexe --help`, `hexe --version`, `hexe ls`, `hexe ses list`, `hexe pod list|new|gc|share`, `hexe profile list`, `hexe layout list|save`, `hexe terminal info|layout list|save|load`, `hexe palette list|get`, `hexe record start|stop|status`, `hexe config validate|dump|paths`, `hexe plugin list`, `hexe allow`), while errors and warnings go to stderr (`✗ Error:` / `! Warning:` on color TTYs, plain `Error:` / `Warning:` when piped).
- **ANSI 16-color styling** (plus 24-bit color swatches in `hexe palette get`) is enabled automatically on TTYs and disabled when piped, when `NO_COLOR` is set, or when `TERM=dumb` (use `CLICOLOR_FORCE=1` to force color). Machine-readable pipe contracts are preserved when stdout is not a TTY (`pod list` emits `HEXE_POD uuid=...`, `pod new` emits JSON, `palette list` emits `pane uuid=...`, `palette get` emits `uuid slot idx=#rrggbb`, `record status` emits `0`/`1`).
- **Grouped `--help` screens**: `hexe --help` groups commands into `Session Shortcuts`, `Core Subsystems`, `Tools & Integration`, and `Adapters` with alias badges and aligned descriptions; every subsystem (`hexe ses`, `hexe pod`, `hexe terminal`, etc.) renders colored subcommand help on empty args or `--help`.
- **Interactive pickers on a TTY**: omitting a target in `hexe attach`, `hexe pod attach`, `hexe pod kill`, `hexe terminal layout load`, or `hexe detach` (outside a session with multiple attached sessions), or passing an ambiguous prefix to `hexe attach <prefix>`, opens the interactive `vaxis` picker with `/` live filtering, arrow/`j`/`k` navigation, `1-9` quick select, and inline session actions (`a` all/here, `n` new, `x` kill, `r` refresh, `q`/`Esc` cancel). On non-TTY stdin/stdout, commands fail fast with actionable error messages and exit codes.
- **Profile flags work both at root and on subcommands**: `hexe -P dev ls` and `hexe ls -P dev` both target the `dev` profile.

## What makes it different

tmux's CLI is a command language for a server: `send-keys`, `split-window`, `list-panes`, all
speaking to one socket, with a format language for output. Hexe's is smaller and shaped by the
process split:

- **The layers are separately addressable.** `session` talks to SES, `pod` talks to one PTY daemon
  directly, `terminal` talks to a frontend. A wedged frontend does not stop you listing or killing
  anything.
- **`hexe terminal float` is a UI primitive for scripts.** It blocks until the float closes and can
  write its result to a file, which is how a shell function turns a picker into a value.
- **No format language.** `--json` where it exists, plain lines otherwise; there is no `#{…}`.
- **The prompt renderer is a command.** `hexe shell prompt` works with no session at all.

## Configuration

Nothing here is configured, but three environment variables change what a command talks to:

| | |
|---|---|
| `HEXE_INSTANCE` | which stack — see [instances](instances.md) |
| `HEXE_PANE_UUID` | set in every pane; the default target for `record`, `shp`, `layout save` |
| `HEXE_SESSION` | set in every pane; the session's **uuid**, not its name. Commands that take `--session` accept either |

A float as a picker, which is the pattern worth copying. The float's command writes the answer to
the `--result-file` path; hexe reads that file, prints its contents on **stdout**, and exits with
the float's exit code — so the whole thing is one command substitution:

```sh
dir=$(hexe terminal float --title picker --size 60,40 \
        --result-file /tmp/pick --command 'bash -c "ls | fzf > /tmp/pick"')
```

## What it cannot do

- **No `capture-pane`.** Nothing outside a frontend knows what a pane displays; SES routes bytes
  and never parses them. Recording a pane is the closest equivalent.
- **`hexe com` does not exist** in this build, and neither do `hexe ses open` or
  `hexe ses freeze` — they are `hexe layout open` and `hexe layout save`. Older documentation and
  older muscle memory both say otherwise.
- **`hexe session stats` prints nothing** and exits non-zero.
- **`--json` is not everywhere.** `session list`, `pod list` and `layout list` have it; most others
  print for humans.
- **`terminal send` is not `expect`.** It writes bytes to a pane; use `hexe terminal wait` to block event-driven on `exit`, output `idle`, rendered `--pattern`, or lifecycle status (`done`, `blocked`, `attention`, exit `124` on timeout).
- **The web and syslink adapters are not user interfaces.** They are probes and serving loops
  against the same runtime.

## Where it lives

| | |
|---|---|
| `src/cli/app.zig` | every command, its flags, the alias table, and dispatch |
| `src/cli/help.zig` | grouped, ANSI-styled `--help` renderer over the yazap command tree |
| `src/cli/commands/` | one file per command family: `pod_*`, `mux_*`, `ses_*`, `record_ctl`, `com*`, `palette` |
| `src/cli/main.zig` | the entry point |
| `src/cli/pop_handlers.zig` | `hexe popup …` |
