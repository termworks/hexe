# Plugins

A plugin is a directory you install, not a command string you paste into your
config.

```console
$ hexe plugin install ./share
installed share 0.1.0
  Hand a pane to a stream backend and show the link it gives back
  it asks for: read,stream,popup

Nothing of it has run. When you are happy with what it asks for:
  hexe plugin allow share

$ hexe plugin allow share
$ hexe plugin list
share            0.1.0      read,stream,popup            ok
```

Your `init.lua` never mentions it. That is the point: installing a plugin should
not mean pasting somebody's glue into your own file, and removing one should not
mean hunting for the lines to delete.

## What a package is

```
~/.local/share/hexe/plugins/<name>/
    plugin.lua    what it is and what it needs
    init.lua      what it does, in Lua, against hexe's API
```

**`plugin.lua`** is the manifest, and it is read in an interpreter with **no
`hexe` in it**:

```lua
return {
  name        = "share",
  version     = "0.1.0",
  description = "Hand a pane to a stream backend and show the link it gives back",
  entry       = "init.lua",
  access      = { "stream", "popup" },
  -- command  = "drop cast",   -- optional helper process
}
```

Splitting it from the body is what makes "see what it asks for before running
any of it" possible. Reading the manifest cannot itself be the thing that runs
the plugin.

**`init.lua`** is ordinary hexe config Lua, run inside the same runtime as your
own, before the config is finished — so its bindings and handlers join the same
registry yours do:

```lua
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.s }, function(ctx)
  local st = ctx.stream("share")
  if not st.attached then return ctx.popup("could not start: " .. (st.error or "?")) end
  ctx.popup("sharing this pane\n\npress any key to hide")
end)
```

`access` in the manifest is what that plugin may ask hexe to do — see
[access.md](access.md). A plugin declaring `command` also gets a helper process
started for it, on its own scoped socket, exactly as an inline `hexe.plugin{}`
would.

## Installing does not approve

They are separate steps, and deliberately so. Install copies the directory in
and prints what it asks for. Nothing of it has run yet. `hexe plugin allow`
records the package's contents as approved, and only then does hexe run it.

Approval covers **the manifest and the entry together**. A manifest that quietly
widens `access` is exactly as much a change as a rewritten `init.lua`, so
changing either revokes it:

```console
$ hexe plugin list
share            0.1.0      read,stream,popup            CHANGED — run `hexe plugin allow`
```

An unapproved plugin does not run at all — hexe says so in the log and carries
on. This is the same ledger `.hexe.lua` already lives under; `hexe plugin allow`
is `hexe allow` for a package.

The directory is **copied**, not linked, so what hexe runs is what you approved.
A link would let the source change under an approval given once.

## The commands

| | |
| --- | --- |
| `hexe plugin list [--json]` | what is installed, what it may do, whether it still matches |
| `hexe plugin install <dir> [--yes]` | copy it in and report what it asks for; `--yes` also approves |
| `hexe plugin allow <name>` | record its current contents as approved |
| `hexe plugin remove <name>` | delete it, and its bindings with it |

## Writing one

The smallest useful plugin is two files and no process at all:

```lua
-- plugin.lua
return { name = "notes", version = "0.1.0", entry = "init.lua", access = { "popup" } }
```

```lua
-- init.lua
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.n }, function(ctx)
  ctx.popup("pane: " .. (ctx.pane().name or "?"))
end)
```

`contrib/plugins/share` is a worked example that hands a pane to a stream
backend. Everything a plugin can reach is in [api.md](api.md); what it is
allowed to reach is in [access.md](access.md).

## What hexe does not do

**It does not supervise a plugin's helper process.** Restarting something that
exited on purpose is a fork loop with a delay, and a helper that wants to
survive its own crashes knows better than hexe how to.

**It does not sandbox.** A plugin runs as you, with your filesystem. `access`
is a declaration boundary — least privilege by default and a list you can read
— not a jail. If you need a real one, run the helper under
[isolation](isolation.md).

**There is no registry.** `install` takes a directory. Where you got that
directory, and whether you read it first, is yours to decide — which is why
`install` prints what it asks for and stops.
