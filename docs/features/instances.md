# Instances

An instance is a whole stack — its own SES daemon, its own pods, its own sessions — living under
its own socket directory. Two instances on one machine cannot see each other, which is what makes
it safe to run a development build of hexe next to the hexe you are working in.

```sh
hexe terminal new -I dev        # a stack called dev
hexe ses list -I dev            # its sessions
hexe terminal new -T            # a throwaway stack with a generated name
```

<!-- demo:begin -->
[![instances demo](https://asciinema.org/a/1262981.svg)](https://asciinema.org/a/1262981)
<!-- demo:end -->

## How it works

The whole mechanism is a path:

```
$XDG_RUNTIME_DIR/hexe/                     the default instance
$XDG_RUNTIME_DIR/hexe/<instance>/          everything for a named one
        ├── ses.sock
        └── pod-<uuid>.sock …

$XDG_STATE_HOME/hexe/<instance>/ses_state.json
$XDG_STATE_HOME/hexe/<instance>/…log
```

A command resolves its instance from `HEXE_INSTANCE`, or from `--instance` / `-I` on the
subcommand, and then every socket it opens or creates is namespaced by it. There is nothing else to
it: no registry, no coordination, no shared lock. Two stacks are two directories.

Because SES and every pod are spawned with `--instance <name>` in their argv, an instance is also
visible in `ps` — and killable as a unit:

```sh
pkill -TERM -f "hexe .*instance dev"
```

### Test-only stacks

```sh
hexe terminal new -T
# test instance: test-acde1234
```

`-T` generates a unique instance name, prints it, and sets `HEXE_INSTANCE` and `HEXE_TEST_ONLY=1`
for everything it spawns. This is what the smoke tests use: each one gets a stack nothing else can
reach, and cleaning up means killing one name.

### Where the flag goes

`-I` / `--instance` is an option **of the subcommand**, not of `hexe`:

```sh
hexe ses list -I dev        # correct
hexe -I dev ses list        # error: unrecognized option 'I'
```

`HEXE_INSTANCE=dev hexe ses list` works too, and is what you want in a shell you intend to keep.

## What makes it different

tmux gets here with `-L <socket-name>` (and `-S <path>`), and the mechanism is the same idea: a
different socket is a different server. The differences are in the reach:

- **One name covers the whole stack.** Hexe has three process roles, and the instance name follows
  all of them — SES, every pod, and every CLI call — including the state file and the log.
- **It is in the process list.** Every daemon carries `--instance <name>` in its argv, so both
  `pgrep` and a targeted `pkill` work without knowing socket paths.
- **`-T` is a first-class throwaway.** tmux has no "give me a private server with a fresh name and
  tell me what it was".

## Configuration

| | |
|---|---|
| `HEXE_INSTANCE=<name>` | environment; applies to every `hexe` command in that shell |
| `-I <name>` / `--instance <name>` | per subcommand; overrides the environment for that call and everything it spawns |
| `-T` / `--test-only` | `terminal new` only: generate `test-<8 hex>`, print it, use it |
| `HEXE_TEST_ONLY=1` | set by `-T` |

A useful habit, if you develop hexe:

```sh
hexe terminal new -I prod      # the one you live in
hexe terminal new -I dev       # the one you are breaking
hexe terminal new -T           # the one you are about to throw away
```

## What it cannot do

- **Nothing is shared between instances.** Not sessions, not pods, not layouts in flight — that is
  the point, but it also means you cannot move a pane across.
- **`hexe ses list` with no instance talks to the default stack**, and correctly reports that no
  daemon is running if you have never started one. `env -u HEXE_INSTANCE hexe ses list` is how you
  ask about the default from inside a named stack.
- **Instance names are sanitised and truncated** to fit a socket path; a long name is not an error,
  but it is not the name you typed either.
- **Killing an instance kills its panes.** The frontend will show a "shell exited" popup per pane
  before you kill the frontend itself.
- **Nothing garbage-collects a dead instance's directory.** `hexe pod gc` cleans stale pod
  metadata; the empty runtime directory stays until the next reboot clears `$XDG_RUNTIME_DIR`.

## Where it lives

| | |
|---|---|
| `src/core/ipc.zig` | `getSocketDir`, `getSesStatePath`, `getLogPath`, and the name sanitiser |
| `src/cli/app.zig` | the `--instance` option on every subcommand, and `-T` |
| `scripts/smoke_*.py` | every smoke test sets `HEXE_INSTANCE`; this is the feature that lets them run at all |
| `docs/instances.md` | the reference page |
