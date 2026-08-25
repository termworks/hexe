# Access

A plugin says what it needs; hexe grants that and refuses the rest.

```lua
-- In a plugin's own manifest (see plugins.md), or inline for a one-off:
hexe.plugin("share",   { command = "my-streamer",  access = { "stream", "popup" } })
hexe.plugin("dictate", { command = "dictate.sh",   access = { "typing" } })
hexe.plugin("hypr",    { command = "hexe-hyprland", access = { "keyboard" } })
```

The point is that hexe stops growing a feature per capability. There is no
"streaming subsystem" and no "dictation subsystem" — there are *kinds of
access*, and the tools are yours.

## The kinds

| | |
| --- | --- |
| `read` | the shape of the session: what panes and tabs exist, how big, what they are called. **Always granted** — nothing can address a pane without it. |
| `screen` | what is *on* a pane: text, scrollback, environment. Split from `read` because structure is harmless and contents are not: a password on screen is `screen_text`, not `panes`. |
| `typing` | put text into a pane, as if pasted. All dictation needs. |
| `keyboard` | press keys **at hexe** — a chord goes through the keybinding machinery and fires whatever you bound. |
| `stream` | read a pane's live bytes: `pod_socket`, scrollback, the stream. |
| `popup` | interrupt the user: notifications, a link, a QR to scan. |
| `control` | change the session: split, close, focus, rename, share, quit. The broad one. |

Declaring nothing means `read` — the harmless thing, not everything. A helper
that forgot to say should not thereby be able to type into your shell.

## typing is not keyboard

They look similar and are different powers.

**`typing`** writes bytes into the program in a pane. It is what dictation does:
the shell sees `ls -la` as though you typed it. It cannot detach your session,
because the pane's program receives the bytes and hexe never looks at them.

**`keyboard`** presses a chord *at hexe*. `keys("ctrl+alt+d")` runs whatever
`ctrl+alt+d` is bound to — a split, a detach, a Lua function. The pane may never
see it at all.

Say the consequence out loud: **`keyboard` reaches everything you have bound.**
If a chord runs a shell command, a plugin holding `keyboard` can run it. That is
not remote code execution — the caller supplies no code, only a chord you chose
the meaning of — but it is broader than `typing`, and it is the reason the two
are separate words rather than one.

That is why a compositor bridge wants `keyboard` and nothing else:

```lua
-- Hyprland: bind a key globally, and if the focused window is a hexe terminal,
-- hand the chord to hexe instead of to the app inside it.
hexe.plugin("hypr", { command = "hexe-hyprland", access = { "keyboard" } })
```

```console
$ hexe api keys '"ctrl+alt+d"'
{"ok":true,"result":true}      # true: a binding consumed it
```

The return value is whether a binding took it, so a bridge can fall back to its
own handling instead of swallowing the key.

## How it is enforced

Each plugin gets **its own socket**, and the socket knows its authority:

```
$XDG_RUNTIME_DIR/hexe/<profile>/api@<session>.sock          the owner: everything
$XDG_RUNTIME_DIR/hexe/<profile>/plug@<session>.<name>.sock  one plugin: its grant
$XDG_RUNTIME_DIR/hexe/<profile>/pane@<uuid>.sock            one pane: itself only
```

Its path arrives as `HEXE_API_SOCKET`, and what it holds as `HEXE_ACCESS`
(`read,stream`), so a plugin can fail loudly at startup rather than discovering
a missing grant halfway through something.

A refusal names the kind, so the fix is obvious:

```json
{"ok":false,"error":"call `send` needs `typing` access, which this plugin was not granted"}
```

A separate socket rather than a token on the shared one, because a token the
caller supplies is a token the caller can omit — and then the grant means
nothing. Authority is a property of the door.

**A pane's socket narrows the same way, in a second dimension.** It holds
`read`, `screen` and `typing`, and it answers for one pane: a session-wide verb
is refused by name, and a selector naming another pane resolves to nothing
rather than to the caller's own. Its path is `$HEXE_PANE_API_SOCKET`, exported
into every pane's shell, so a program in a pane finally has something it can be
handed. See [api.md](api.md#a-panes-own-socket).

It grants nothing to whoever is already in that pane — it *is* the process
there. The point is the opposite: it is narrow enough to hand out.

**A project file's `hexe.needs` is a different thing with a similar shape.** The kinds above govern
a *plugin* — a package you installed, holding a socket. `hexe.needs { "tools" }` governs a
`.hexe.lua` that arrived with a `git clone`, and grants Lua capabilities inside hexe's own VM rather
than verbs on a socket. Same principle, different boundary: see
[project sessions](session-manager.md#three-tiers-not-two).

## What this is not

**It is not a sandbox.** A plugin runs as you, with your filesystem, so nothing
here stops a determined program from opening the unscoped socket itself.

What *is* enforced below the grant: the socket is `0600`, and every connection's
uid is checked against the owner's using `SO_PEERCRED` — the kernel's answer,
not anything the peer said. A different user cannot reach it even if the runtime
directory is more permissive than it should be.

What it does buy is real anyway: least privilege by default, a plugin that
cannot type into your shell *by accident*, a refusal that says which power was
missing, and a list in your config of what you actually installed. If you need a
real boundary, run the plugin in [isolation](isolation.md).

## Adding a kind

`src/core/access.zig` holds the list; each verb in `lua_api.zig` names the one
kind it needs. A new verb joins an existing kind — the list is meant to stay
short enough to read in one breath, and describes *what a program wants to do*
rather than mirroring the verb list.

See [api.md](api.md) for the verbs, [streaming.md](streaming.md) for what
`stream` reaches, and [dictation.md](dictation.md) for what `typing` is for.
