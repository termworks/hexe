# Shell integration

hexe does not draw your prompt. It installs hooks so your shell *reports* what
it is doing — cwd, exit status, command duration, job count, the running
command — and that state is what the [painter](regions.md) draws with, both in
your prompt and in hexe's own status bar.

```sh
eval "$(hexe shell init bash)"     # or zsh
hexe shell init fish | source
```

## What the hooks do

```
shell runs a command
   |  preexec / DEBUG trap
   v
hexe shell shell-event --phase=start --running --cmd=... --cwd=... --jobs=N
   |
   +--> pod socket --> SES --> frontend --> pane state
                                             |
                                             v
                                   the painter's next request

shell finishes
   |  precmd / PROMPT_COMMAND
   v
hexe shell shell-event --phase=end --status=$? --cwd=... --jobs=N
```

`hexe shell exit-intent` is the third hook: it asks the mux for permission
before the shell exits, so closing the last pane can be confirmed.

`--no-comms` installs command timing without the mux reporting.

## Drawing the prompt

The prompt itself is drawn by whatever you point your shell at, from the same
state hexe collects. Any program that can print a styled line works — it is your
shell's `PS1`, not hexe's business.

A shell that supports an async prompt command can call one directly:

```lua
-- e.g. oslo's ~/.config/oslo/prompt.lua
oslo.prompt.left = {
  command = "my-painter",
  args = { "prompt.left", "--status=$status", "--duration=$duration_ms" },
  timeout_ms = 10,
  async = true,
}
```

See [painting](regions.md) for the protocol hexe itself uses, if you want one
program to serve both.

## What it cannot do

The hooks report; they do not render. A shell with no painter running gets no
styled prompt from hexe — that is the painter's job, and hexe has no fallback
prompt to fall back to.

Shells other than bash, zsh, fish and oslo are not covered. The reporting is
three CLI calls, so a shell that can run a command in `preexec` and `precmd`
can be wired by hand.

## Where it lives

`src/modules/shell/` — the hook emitters, one per shell.
`src/cli/commands/com.zig` — `runShellEvent`, `runExitIntent`.
