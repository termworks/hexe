# CLI reference

All commands accept `--instance <name>` (or `-I <name>`) to target a named instance. See [instances](instances.md).

---

## hexe terminal

```sh
hexe terminal new [--name <name>] [--debug] [--logfile <path>] [--test-only]
```
Start a new terminal frontend session. `hexe mux` and `hexe multiplexer` are compatibility aliases. `--test-only` starts an isolated stack with a generated instance name.

```sh
hexe terminal attach <name-or-uuid-prefix>
```
Attach to an existing session.

```sh
hexe terminal float [options]
```
Spawn a one-off floating pane.

| Flag | Description |
|---|---|
| `--command <cmd>` | Command to run |
| `--title <text>` | Border title |
| `--cwd <path>` | Working directory |
| `--size WxH,X,Y` | Size (%) and position (%) |
| `--focus` | Focus the float immediately |
| `--isolation <profile>` | none / minimal / default / sandbox / full |
| `--key <key>` | Key sent to pane on dismiss |
| `--result-file <path>` | Write exit output here |
| `--pass-env` | Pass current environment |
| `--extra-env K=V` | Additional env vars |

```sh
hexe terminal notify <message> [--uuid <pane>] [--broadcast] [--last]
```
Send a notification to a pane or broadcast to all.

```sh
hexe terminal send <text> [--uuid <pane>] [--name <name>] [--target <t>]
```
Send keystrokes to a pane.

```sh
hexe terminal focus left|right|up|down [--uuid <pane>]
```
Move pane focus directionally (useful for editor integration).

---

## hexe session / hexe ses

```sh
hexe session daemon [--debug] [--logfile <path>] [--foreground]
```
Start the session daemon. Usually started automatically by `hexe terminal new`.

```sh
hexe session list [--details] [--json]
```
List all sessions with their panes.

```sh
hexe session status
```
Show daemon version and uptime.

```sh
hexe session kill <uuid>
```
Kill a detached session and its panes.

```sh
hexe session clear [--force]
```
Kill all detached sessions.

```sh
hexe session export <uuid>
```
Export session layout and pane state as JSON.

```sh
hexe session stats
```
Show resource usage for all sessions and pods.

```sh
hexe session open <target>[:<tab>] [--debug] [--logfile <path>]
```
Open a session from a `.hexe.lua` config. Target can be a directory, `.lua` file, or session name. See [session_manager](session_manager.md).

```sh
hexe session freeze
```
Snapshot current session as `.hexe.lua` to stdout.

---

## hexe pod

```sh
hexe pod list [--where <path>] [--alive] [--json]
```
List discoverable pods.

```sh
hexe pod new [--name <name>] [--shell <shell>] [--cwd <path>] [--alias]
```
Create a standalone pod not attached to any session.

```sh
hexe pod attach [--uuid <u>] [--name <n>] [--socket <path>] [--detach <key>] [--record <file.cast>] [--capture-input]
```
Raw TTY attach to a pod (like `screen -r` but for a single PTY).

```sh
hexe pod record [--uuid <u>] [--name <n>] [--socket <path>] --out <file.cast> [--capture-input]
```
Observe a pod and write an asciicast recording without replacing the active VT attach client.

```sh
hexe pod send <text> [--uuid <u>] [--name <n>] [--enter] [--ctrl]
```
Send text or keystrokes to a pod.

```sh
hexe pod kill <uuid-or-name> [--signal <sig>] [--force]
```
Kill a pod.

```sh
hexe pod gc [--dry-run]
```
Remove stale pod socket/metadata files left by crashed pods.

---

## hexe shp

```sh
hexe shp init bash|zsh|fish
```
Print shell initialization code. Eval this in your shell RC file:

```sh
eval "$(hexe shp init bash)"
```

```sh
hexe shp prompt [--status <n>] [--duration <ms>] [--jobs <n>] [--right] [--shell <sh>]
```
Render the prompt for the given context. Called automatically by the shell integration.

---

## hexe record

```sh
hexe record start --scope pod|mux [--uuid <u>|--name <n>|--socket <path>] [--out <file.cast>] [--capture-input]
```
Start background recording for the given scope/target.

`--scope mux` is the legacy scope name for terminal frontend recording.

For `--scope pod`, if no explicit target is provided, hexe tries to resolve the active pod (`HEXE_PANE_UUID`, then `hexe terminal info --last`).

```sh
hexe record stop --scope pod|mux
```
Stop background recording for the given scope.

```sh
hexe record status --scope pod|mux [--json]
```
Print `1` when active and `0` when inactive (or JSON with `--json`).

```sh
hexe record toggle --scope pod|mux [--uuid <u>|--name <n>|--socket <path>] [--out <file.cast>] [--capture-input]
```
Toggle background recording for the given scope/target.

```sh
hexe terminal record --out <file.cast> [--capture-input]
```
Record a terminal attach stream directly into asciicast output.

---

## hexe config

```sh
hexe config validate
```
Parse and validate `~/.config/hexe/init.lua` without starting anything.

---

## hexe com

```sh
hexe com
```
Print a tree of all running terminal sessions, tabs, panes, and pods.

---

## Global flags

| Flag | Description |
|---|---|
| `-I / --instance <name>` | Target named instance |
| `--debug` | Enable debug logging |
| `--logfile <path>` | Write logs to file |
