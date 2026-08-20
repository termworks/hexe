# Names

hexe keeps two small built-in alphabets and takes anything richer from outside.

| Surface | Built-in pool |
|---|---|
| session | Greek — `alpha`, `beta`, `gamma`, … (24) |
| pane, and the pod behind it | NATO — `alfa`, `bravo`, `charlie`, … (26) |
| tab | derived, `<session>-<n>` — not a vocabulary, and not configurable |

A name is not decoration. A pod is addressed by `--name`, and its socket file is
`pod@<name>.sock`, so the vocabulary is also a namespace of filenames and CLI
arguments. That is why entries are constrained rather than free text.

## Bringing your own

```lua
names = {
  -- Absent means the built-in pool for that surface.
  session = { "alpha", "beta", "gamma" },
  pane    = hexe.command("pixy names pokemon"),

  order  = "random",   -- or "sequential", taking the first free entry
  suffix = "-%d",      -- appended once every entry is taken
}
```

A surface is either a literal list or a command. hexe runs the command once
while loading the config, splits the output on newlines, and caches the result
for the life of the process — the same rule every other config value follows, so
a pack that changes under a running hexe is not noticed until a reload.

**A failing command is not an error.** A command that is missing, exits
non-zero, times out (2s), or prints nothing usable leaves that surface on its
built-in pool and logs the reason once. A painter that is not installed must
never stop panes from being created.

**A malformed entry in a literal list *is* an error**, named at config load like
any other, rather than becoming a pod socket that cannot be opened later.
Entries from a *command* are skipped individually with a warning, because one
bad id in a pack should not cost you every other name in it.

### Entry rules

| Rule | Value |
|---|---|
| Shape | `[a-z0-9][a-z0-9._-]*` |
| Length | 1–32 |
| Entries per dictionary | 4096 |

Lowercase only: the name becomes a filename, and a case-insensitive filesystem
would let two entries that do not look alike collide.

## Uniqueness

Names are taken, not rolled:

1. The first entry no live pane is using, walked in `order`. `random` only
   changes where the walk starts — it still takes a free entry, so two panes can
   never collide on one pod socket.
2. Once every entry is taken, `suffix` is appended with the lowest free number:
   `nidorina-2`, then `nidorina-3`. A suffix without `%d` still gets the number
   appended, or exhaustion would never terminate.
3. Sessions and panes draw from different dictionaries and are checked
   separately.

The pane dictionary is sent to the session daemon when the frontend attaches,
before the first pane exists. The daemon creates panes and never reads the
config, so without that it would name the opening pane from its built-in pool.

## Names and sprites

The sprite a pane shows is **the name it was created with**, recorded at
creation and never changed:

```
create:  name = nidorina    sprite = nidorina
rename:  name = notes       sprite = nidorina     <- untouched
```

This is what makes the pairing hold: **whoever supplies names must be able to
draw them.** If `pixy names pokemon` produced the list, then the recorded sprite
id resolves inside that same pack, because it came from there. A painter that
hands out names for art it does not have is the one broken case, and it is the
painter's bug.

Leave `names.pane` unset and panes are called `alfa`, `bravo`, `charlie` — and
the painter, asked for an `alfa` sprite, falls back to whatever it falls back to.
That is the correct outcome: no dictionary, no matching art.
