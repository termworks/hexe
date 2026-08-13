# The shell prompt

The same segment machinery that draws the status bar also draws your shell's prompt, in bash, zsh,
fish or oslo. The shell asks hexe for a string once per prompt; hexe evaluates your segments and
answers. Nothing is injected into your shell's own prompt logic beyond one hook.

```sh
eval "$(hexe shell init bash)"     # or zsh
hexe shell init fish | source
```

```lua
prompt = {
  left  = { hexe.segment.username({ style = "bg:5 fg:0" }),
            hexe.segment.status({ style = "bg:0 fg:9" }) },
  right = { hexe.segment.directory({ style = "bg:237 fg:15" }),
            hexe.segment.git_branch({ style = "bg:5 fg:0" }) },
},
```

<!-- demo:begin -->
[![prompt demo](https://asciinema.org/a/1262987.svg)](https://asciinema.org/a/1262987)
<!-- demo:end -->

## How it works

```
shell about to draw a prompt
   │  PROMPT_COMMAND / precmd / fish_prompt
   ▼
hexe shp prompt --status=$? --duration=<ms> --jobs=<n> [--right]
   │
   ├─ read config: ~/.config/hexe/init.lua, then ./.hexe.lua if present
   ├─ evaluate the `prompt.left` (or `prompt.right`) segments against ctx
   └─ print the assembled, styled string
   ▼
shell sets PS1 to it
```

The hook the shell installs does three things: it times commands (a `DEBUG` trap or `preexec`
equivalent), it reports what happened to the pane's session (`hexe shp shell-event`), and it emits
**OSC 7** so the pod learns the working directory. That last one is not cosmetic — it is what makes
`per_cwd` floats, directory-aware status segments and `hexe ses list --details` know where a pane
is.

Every prompt is a separate process, which is the design's real constraint: it must be fast, and it
must not need a running session. `hexe shp prompt` works in a plain terminal with no hexe session
at all, which is the point of having one prompt configuration rather than two.

### What a segment gets

`ctx` is smaller than the status bar's, because a prompt knows about one shell at one moment:
`cwd`, `home`, `exit_status`, `cmd_duration_ms`, `jobs`, `terminal_width`, `now_ms`, `env`, and
`ctx.cache` for memoising. `ctx.pane(0)` returns that same context; there is no cross-pane lookup
in prompt mode, because there is no session to look across.

### What a prompt may use

Prompt deliberately supports a subset:

| | |
|---|---|
| allowed kinds | `render`, `builtin` |
| refused kinds | `button`, `progress` — a prompt is not interactive and does not repaint |
| builtin allowlist | `directory`, `git_branch`, `git_status`, `status`, `sudo`, `jobs`, `duration`, `pod_name`, `hostname`, `username`, `character` |

`spinner`, `randomdo` and `running_anim` are refused for the same reason: they only make sense on a
surface that redraws itself, and a prompt is printed once.

### Width

Each side gets half the terminal. Over budget, the **highest** priority number is dropped first, so
low numbers survive longest — the same rule as the status bar, applied per side.

## What makes it different

Compared with starship, powerlevel10k and their relatives:

- **One configuration, two surfaces.** The segments in your prompt and the segments in your status
  bar are the same objects with the same styling language, so a git segment looks the same in both
  places without being written twice.
- **The prompt knows about the multiplexer.** `pod_name` names the pane you are in; the shell hooks
  report command, status, duration and jobs back to the session, which is what feeds
  `command_finished` events and the status bar's own `last_command` and `duration` segments.
- **Segments are Lua, not TOML.** A conditional is `return nil`, not a template language.
- What the alternatives do better: they are one binary with a large library of ready-made,
  carefully tuned segments; hexe ships the ones it needs and expects you to write the rest.

## Configuration

```lua
prompt = {
  left = {
    hexe.segment({
      name = "ssh", priority = 60,
      render = function(ctx)
        if not ctx.env.SSH_CONNECTION then return nil end
        return { { text = " //", style = "bg:237 fg:15" } }
      end,
    }),
    hexe.segment.status({ style = "bg:0 fg:9", prefix = " ", suffix = " " }),
  },
  right = { hexe.segment.git_branch({ style = "bg:5 fg:0", suffix = " " }) },
},
```

Config is read from `~/.config/hexe/init.lua`, then `./.hexe.lua` if the directory has one, which
may override the prompt arrays for that project.

The renderer can be called by hand, which is how it is debugged:

```sh
hexe shp prompt --status 1 --duration 1200 --jobs 2
hexe shp prompt --right --shell zsh
hexe shp spinner            # the animation frames, for a shell that wants one
```

### The Lua sandbox

The config runtime is **unrestricted by default**: `io`, `os`, `package` and `hexe.exec` are all
available, which is why a real config can read `/etc/os-release` or shell out. Setting
`HEXE_UNRESTRICTED_CONFIG` to anything other than `1` revokes all of it — `io`, `package`,
`dofile`, `loadfile`, `load`, `debug`, `hexe.exec`, and everything on `os` except `time`, `date`,
`clock` and `difftime`. The same revocation is applied unconditionally before an untrusted
project-local `.hexe.lua` runs; see [project sessions](session-manager.md).

## Measurements

- **One process per prompt.** Everything expensive in a prompt is therefore paid on every command:
  the shipped config replaces a `distrologo` shell-out (~15 ms, itself spawning `lsb_release`,
  `cut` and `xargs`) with a memoised read of `/etc/os-release`, and `systemd-detect-virt` (~3 ms)
  with a per-boot cache file.
- **Width budget: half the terminal per side.**
- **`hexe.exec` takes `timeout_ms` and `cache_ms`**, and reports `cached` and `elapsed_ms` back, so
  a slow command in a prompt is measurable rather than mysterious.

## What it cannot do

- **No OSC 133 from bash, zsh or fish.** The shipped integrations emit OSC 7 but not semantic
  prompt marks, so `hexe.action.prompt.previous/next/copy_output` do nothing in those shells unless
  the shell marks its own prompts. oslo emits both on its own.
- **No buttons, no progress, no animation.** A printed prompt cannot repaint itself.
- **No cross-pane context.** A prompt segment cannot ask about another pane.
- **Right prompt is a second invocation.** The shell asks for it separately, and shells that have
  no notion of a right prompt cannot show one.
- **A broken config breaks the prompt, not the shell.** The renderer reports the error and prints
  what it can; the shell keeps working.
- **`hexe shp` is `hexe shell`.** `shp` is an alias, and the underlying command is `shell prompt`.

## Where it lives

| | |
|---|---|
| `src/modules/shell/main.zig` | the `shp prompt` entry point |
| `src/modules/shell/shell/bash.zig`, `zsh.zig`, `fish.zig`, `oslo.zig` | the init scripts, one per shell |
| `src/modules/shell/render_modules.zig`, `format.zig` | assembling and styling the line |
| `src/core/segments/` | the built-ins the allowlist names |
| `src/core/lua_runtime.zig` | the config runtime, the sandbox, `require("hexe")` |
| `src/cli/app.zig` | `shell init`, `shell prompt`, `shell spinner`, `shell shell-event`, `shell exit-intent` |
| `docs/prompt.md` | the reference page |
