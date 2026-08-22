# The oslo Lua config style

One config style across oslo, hexe, lule and pixy. oslo already reads this way; lule was converted
to it; this describes the style so hexe can match.

The whole of it: **assign the settings, register the behaviour, return nothing.** A description —
a plugin, preset or theme — stays a table; it is just handed to something instead of returned.

```lua
local hexe = require("hexe")

hexe.vi.enabled = true
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.q }, hexe.action.quit())
hexe.on.attach(function(s) ... end)
```

## The five rules

### 1. Settings are assigned, not declared in a table

```lua
tool.theme = "dark"                  -- yes
tool.suggest.sources = { "history" } -- yes, when there is more than one subsystem

return tool.setup({ settings = { theme = "dark" } })   -- no
```

A setting the config never mentions is left alone — the environment or a flag decides it. There is
no "defaults table" to keep in sync, and no way to blank a setting by forgetting to list it.

**Nested data stays nested.** The rule is about how a setting is *delivered*, not about flattening
its value. A structured setting is a table on the right-hand side:

```lua
hexe.ui.widgets.keycast = { enabled = false, position = "bottomright", duration_ms = 2000 }
```

This matters more for hexe than for any of the others. hexe's config is mostly a large tree of pure
data — border glyphs, widget positions, `visible_count = 10` — and turning that into a hundred
assignment statements would be **worse** than the table it already is. Assign the tree. The rule
never asked for it to be flattened, and hexe is the tool most at risk of over-applying it.

Namespace only where there is genuinely more than one subsystem. oslo has `oslo.vi`, `oslo.suggest`,
`oslo.builtin`; lule has one subject and so keeps its settings flat. A namespace with one member is
a directory with one file in it.

### 2. Behaviour is registered, and registration repeats

```lua
tool.on.event(handler)      -- as often as you like
```

This is the rule the others follow from. If a hook is one field in a returned table there is
exactly one place to put anything, so everything a config does piles into one function. If it is a
call, the config is as many small named functions as it wants:

```lua
local function write_cache(c) ... end
local function recolour_terminals(c) ... end
local function reload_desktop(c) ... end

lule.on.colors(write_cache)
lule.on.colors(recolour_terminals)
lule.on.colors(reload_desktop)
```

Handlers run in the order they were registered. **One that raises is reported and the rest still
run** — a mistake in the third handler is not a reason to skip the fourth, which has nothing to do
with it.

The same goes for anything else that is a list: `hexe.key(...)`, `lule.template(...)`,
`make.recipe{...}` are all calls that append, not entries in a table someone has to assemble.
hexe's 101 `hexe.key(...)` calls are already registrations in all but name — they just have to stop
being collected into a `keys = concat(...)` list and hand themselves in.

**Keyed registration is the second form.** Where a registration is identified by something — a key
name, a zone name — assigning into a map beats appending to a list, because it is idempotent:
registering `f4` twice replaces rather than fires twice.

```lua
oslo.keys["f4"] = function(line) ... end
```

Use a list where entries genuinely accumulate (handlers for one event), a map where each entry has
an identity that can be replaced.

### 3. The file returns nothing

No `return tool.setup({...})`, no `return M`. The config is a list of statements, so it can compute
freely between them:

```lua
for _, app in ipairs({ "kitty", "waybar", "rofi" }) do
  lule.template(app, { input = shared, output = "~/.config/" .. app .. "/colors.ini" })
end

if oslo.term.kitty_keyboard() then
  oslo.lua.enter = "newline"
end
```

The host reads its settings off the module table after the chunk has run, so there is nothing to
hand back.

This is about the **config** file. A plugin, preset or theme is a different kind of file — rule 4.

### 4. A table is an argument, never a fragment somebody has to merge

Registration is for behaviour. A plugin, preset or theme is a *description* — a pile of values —
and a table is the right shape for one. The two coexist perfectly well, as long as the table is
handed **to** something:

```lua
hexe.plugin({ "author/thing", opts = { ... } })     -- the table is an argument
```

What goes wrong is the table that is only returned, leaving the caller to assemble it. hexe pays
this today:

```lua
-- layout.lua
return { keys = {...}, ses = { layouts = {...} } }

-- init.lua
local layout_config = dofile(os.getenv("HOME") .. "/.config/hexe/layout.lua")
local layout_keys = layout_config.keys or {}
if layout_config.__hexe_type == "layout" then
  layouts = { layout_config }
elseif layout_config.ses and layout_config.ses.layouts then
  layouts = layout_config.ses.layouts
end
```

The merge, the `or {}` defaults and the shape sniffing all live in the config, and every new
fragment file re-implements them. Two ways to keep it an argument instead:

- **registered** — the fragment calls `hexe.plugin{...}` itself and returns nothing; the config
  just requires it.
- **discovered** — the host scans a directory and merges the returned tables itself, the way
  lazy.nvim does. Then `return {...}` is fine: the merge exists once, in the host.

nvim splits along exactly this line — `vim.o.background = "dark"` and sixty-odd `vim.keymap.set(...)`
in the config, `return { "author/plugin", opts = {...} }` in a plugin spec that lazy discovers and
merges.

### 5. A handler's return value means something, or nothing

Where a handler can influence what happens next, `nil` means "not mine, carry on" and a table means
"here is what to do instead":

```lua
oslo.on.on_key(function(k)
  if k.language ~= "sh" then return end          -- not mine
  if k.name == "enter" and k.text == "" then
    return { text = "la --git-ignore", submit = true }
  end
end)
```

Where a handler is purely a side effect — lule's `on.colors` — the return value is ignored and the
handler returns nothing.

## What the host implements

Small enough to be worth stating exactly:

- The module table is created, the host's functions are added to it, and it is parked before the
  config chunk runs. `package.loaded['<tool>'] = tool` so `require` never touches the filesystem.
- Registrars append to a plain Lua list on that table (`tool.templates`, `tool.handlers.colors`).
  Keeping them in Lua rather than in the host means the list can also be assigned outright, and
  can be read back by the config.
- After the chunk runs, the host reads its settings off the module table. Missing key means unset,
  not zero.
- A syntax error or a raise **at load time** stops the run and names file and line — carrying on
  with defaults silently applies something the user did not ask for. A raise **inside a handler**
  is reported and the run stands.
- Handlers are called one at a time under `pcall`, in registration order.

## Naming

- `tool.on.<noun>` for events — the thing that happened, not when. `on.colors`, `on.attach`,
  `on.key`. Not `after`, `post`, `hook`: those say when, and a config full of `after` tells you
  nothing about what any of it does.
- Settings take the same name as the equivalent command-line flag.
- A registrar that takes a name (`lule.template("kitty", ...)`, `hexe.key(...)`) uses the name only
  so a warning can say *which* one is wrong.
