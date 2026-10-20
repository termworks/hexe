# The command line

Everything hexe does from the outside: start and attach sessions, list what is running, type into a
pane, open a float, render a prompt, record a cast. A session is not a black box — it is a set of
processes with names, and the CLI is how a script talks to them.

```sh
hexe                        # bare: attach here, or load .hexe.lua, or start fresh
hexe terminal new -n work
hexe ses list --details
hexe terminal send --last --enter "make test"
```

<!-- demo:begin -->
[![cli demo](https://asciinema.org/a/1263025.svg)](https://asciinema.org/a/1263025)
<!-- demo:end -->

## How it works

Eleven top-level commands, each with subcommands, and a short alias for the ones you type often:

| command | alias | what it is |
|---|---|---|
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
hexe terminal new [-n <name>] [-I <instance>] [-T] [--log <lvl>] [--logfile <path>]
hexe terminal attach <name-or-uuid-prefix>
hexe terminal kill <id>            # a session, a pane, or a float
hexe terminal float --command <cmd> [--title …] [--size w,h,x,y] [--isolation …] [--result-file …]
hexe terminal send <text> [--uuid <u>|--last|--creator|--broadcast] [--enter] [--ctrl <key>]
hexe terminal notify <msg> [--uuid <u>|--last|--broadcast]
hexe terminal info [--uuid <u>|--last|--creator]
hexe terminal focus left|right|up|down
hexe terminal layout save|load|list [<name>]
hexe terminal record --out <file.cast> [--capture-input]

hexe session list [--details] [--json]      hexe session status
hexe session kill <uuid>                    hexe session clear [--force]
hexe session export <uuid>                  hexe session daemon [--foreground]

hexe layout open <target>[:<tab>]           hexe layout save --scope local|global|both
hexe layout list [--json]

hexe pod list [--where <lua>] [--probe] [--alive] [--json]
hexe pod new [-n <name>] [--shell …] [--cwd …] [--labels a,b] [--alias]
hexe pod send <text> [--uuid|--name] [--enter] [--ctrl <letter>]
hexe pod attach [--uuid|--name] [--detach <key>] [--record <f.cast>] [--capture-input]
hexe pod record --out <file.cast>                     hexe pod kill --uuid <u>|--name <n> [--signal <n|NAME>] [--force]
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
| `--last` | the pane this one came from |
| `--creator` | the pane the command was launched from |
| `--broadcast` | every pane in the session |

Split or float is **not** part of the address: both are panes, drawn from one
name pool, so the name alone is enough. Nor is the tab.

```
hexe terminal send --pane romeo --enter "make test"        # inside hexe
hexe terminal send --session work --pane romeo --enter …   # another session
hexe terminal send --uuid b717c471 --enter …               # from anywhere
```

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

Typing (`terminal send`) is delivered to the pane's **pod**, which owns the pty
and outlives the frontend — so it reaches a pane in a **detached** session too.
Anything needing a frontend (keys through the keybinding machinery, focus,
reading the screen) does not.

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
| `shell init <shell> --no-comms` | the prompt hooks without the shell→mux reporting |
| `--log trace\|debug\|info` and `--logfile` / `-L` | on every daemon; the level name is the only accepted spelling |
| `--help` / `-h` | on every command and subcommand, generated from the flag list |

### Two gotchas worth knowing

`-I` / `--instance` belongs to the **subcommand**, not to `hexe`: `hexe ses list -I dev` is right,
`hexe -I dev ses list` is an error. And most of these commands print to **stderr**, not stdout, so
`hexe ses list > file` writes an empty file; use `2>&1` when capturing.

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
- **Output goes to stderr.** Piping the human-readable listings needs `2>&1`.
- **`terminal send` is not `expect`.** It writes bytes to a pane; nothing waits for a result.
- **The web and syslink adapters are not user interfaces.** They are probes and serving loops
  against the same runtime.

## Where it lives

| | |
|---|---|
| `src/cli/app.zig` | every command, its flags, the alias table, and dispatch |
| `src/cli/commands/` | one file per command family: `pod_*`, `mux_*`, `ses_*`, `record_ctl`, `com*` |
| `src/cli/main.zig` | the entry point |
| `src/cli/pop_handlers.zig` | `hexe popup …` |
