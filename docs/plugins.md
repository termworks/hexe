# Plugins

A plugin is a fragment of config that arrived on its own. It runs in hexe's own
Lua, against the same API your `init.lua` uses, and it registers rather than
returns.

hexe follows **neovim's model**, because most people arriving here have already
learned it and deviating from it buys nothing.

## Installing one

Put it on the path. That is the whole procedure — there is no install command,
no manifest and no approval step:

```
~/.local/share/hexe/site/pack/mine/start/thing/
    plugin/thing.lua
```

```console
$ hexe plugin list
```

`plugin list` prints the path and every file that would run, in the order it
would run them. A `-` marks a root that does not exist yet.

## The path

An ordered list of roots. Each root has the same layout inside, so hexe's own
Lua is shipped exactly the way yours is:

```
~/.config/hexe                    yours
/etc/xdg/hexe                     the system's
~/.local/share/hexe/site          where packages install
  + site/pack/*/start/*           each package, as its own root
~/.local/share/hexe/runtime       hexe's own
…/after                           the same list, reversed
```

The `after` half is the first half reversed, so your own config directory is
both first and last.

## Inside a root

```
<root>/
    plugin/**/*.lua   run at startup, alphabetically, subdirectories included
    lua/              modules for `require`, never run on their own
    after/plugin/     run after everything else
```

**`plugin/` runs, `lua/` is required.** A file under `plugin/` is a statement
hexe executes for you. A file under `lua/` does nothing until something requires
it — which is where a plugin's helpers go. Every root's `lua/` is on
`package.path`, so a plugin's own module is `require("thing.util")` wherever the
plugin lives.

**`after/` is the override seam.** To undo something a plugin did, put a file in
`~/.config/hexe/after/plugin/`. It runs last, and "edit the plugin" is not a
thing anyone should have to do.

**Order is path order between roots and alphabetical within a directory.**
Alphabetical because directory order is filesystem order: it differs between
machines and changes after a reinstall.

A plugin gets its root as the chunk's `...`, so it can read a file it ships:

```lua
local root = ...
local f = io.open(root .. "/data.txt", "r")
```

## What a plugin may assume

The API the config gets. It is a fragment of config, so the registrars are
simply there, and it returns nothing:

```lua
-- ~/.config/hexe/plugin/keys.lua
local on = false
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.k }, function() on = not on end)

hexe.on.key_pressed(function(ev)
  if not on then return end
  hexe.draw("keys", { content = ev.chord, width = 20, height = 1, corner = "bottomright" })
end)
```

A plugin that needs a helper process declares it the same way a config does,
with `dir` for where it runs:

```lua
local root = ...
hexe.plugin("backend", { command = "./backend.sh", dir = root, access = { "stream" } })
```

## Packages

```
site/pack/<any>/start/<plugin>/     loaded at startup
site/pack/<any>/opt/<plugin>/       there, but not loaded
```

The `<any>` level lets you group what you installed — by source, by purpose —
without hexe caring. A package is laid out **exactly like a config root**, which
is why you can develop one as `~/.config/hexe/plugin/thing.lua` and move it into
a package later without editing it.

## Trust

There is none, and that is deliberate. What is on the path runs, because you put
it there — a prompt would only ask you to confirm a decision you already made by
copying the directory in.

hexe used to gate plugins on a content hash. Any edit revoked the approval,
including the author's own, so installing hexe disabled the plugins hexe itself
ships, and a plugin under development went silently off after every save. It
also decided nothing: anyone who can alter a first-party plugin can already
alter the binary next to it.

Review a plugin before you install it, the way you would any other code you run.

## When something misbehaves

```console
$ hexe --noplugin mux new
```

Starts with none of them, which is how you answer "is it me or a plugin?"
`HEXE_NOPLUGIN=1` does the same for a whole shell. Then narrow it down with
`hexe plugin list`, which gives you the order they load in.

A plugin that raises is reported and the rest still load — deliberately unlike
`init.lua`, where a raise is fatal because carrying on would silently apply
settings you did not ask for. Look for `plugin '<path>' raised while loading` in
the log.

## What hexe ships

`share/runtime/plugin/` in the repository, installed by `make install` to
`~/.local/share/hexe/runtime/plugin/`. It is hexe's own root, on the same path
as yours and under the same rules — so `after/plugin/keycast.lua` in your config
overrides it, and `--noplugin` turns it off with everything else.

| plugin | what it does |
|---|---|
| `keycast.lua` | shows the keys you press, in a corner. `ctrl+alt+k` toggles it |
