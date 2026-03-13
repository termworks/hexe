# Instances (Dev/Test Isolation)

Hexe supports running multiple independent mux/ses/pod stacks on the same machine.
This is intended for development and feature testing without touching your "working" Hexe.

The feature is implemented by **namespacing all IPC sockets** under an instance name.

## Concepts

Hexe has three cooperating processes:

- `mux` (UI + input)
- `ses` (session registry + spawns pods)
- `pod` (one per pane; owns the PTY)

Normally these talk over Unix sockets under:

- `$XDG_RUNTIME_DIR/hexe/` (or `/tmp/hexe/`)

With instances enabled, sockets are placed under:

- `$XDG_RUNTIME_DIR/hexe/<instance>/`

So different instances do not see each other.

## Selecting an Instance

There are two ways to pick an instance:

1) Environment (default)

If `HEXE_INSTANCE` is set, all `hexe ...` commands use it.

2) CLI flags (override)

Most commands accept:

- `-I <NAME>` / `--instance <NAME>`

This overrides `HEXE_INSTANCE` for that invocation (and any processes it spawns).

Examples:

```sh
hexe terminal new -I dev
hexe ses list -I dev
hexe terminal attach -I dev nidoking
```

## Test-Only Sessions

`hexe terminal new` supports:

- `-T` / `--test-only`

This starts an isolated stack by generating a unique instance name like:

- `test-<8chars>`

The command prints the chosen instance so you can target it later:

```sh
hexe terminal new -T
# prints: test instance: test-acde1234
```

Internally this sets:

- `HEXE_INSTANCE=test-acde1234`
- `HEXE_TEST_ONLY=1`

## Listing Sessions

`hexe ses list` always talks to the ses daemon of the current instance.
It prints which instance it is using.

Examples:

```sh
hexe ses list -I dev
hexe ses list -I prod
```

If you never start a "default" instance, then:

```sh
env -u HEXE_INSTANCE -u HEXE_TEST_ONLY hexe ses list
```

may correctly report `ses daemon is not running`.

## Killing Only One Instance

Because Hexe now spawns `ses` and `pod` with explicit `--instance <name>` argv,
you can kill a single instance with a single short command.

Kill only dev:

```sh
pkill -TERM -f "hexe .*instance dev"
```

If it does not exit (last resort):

```sh
pkill -KILL -f "hexe .*instance dev"
```

Notes:

- This matches both `-I dev` and `--instance dev` because the regex looks for the substring `instance dev`.
- Killing pods will make mux show a "Shell exited" popup for panes; kill the mux for a hard stop of the UI.

## Recommended Workflow

To make "working" vs "dev" unambiguous, use explicit instances:

```sh
# your daily session
hexe terminal new -I prod

# your development stack
hexe terminal new -I dev

# quick experiments
hexe terminal new -T
```
