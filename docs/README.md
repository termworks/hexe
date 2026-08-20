# Documentation

One document per feature: what it is, how it works, what it cannot do, and where it lives in the
tree. Each says how the thing is built and why it is built that way, and carries the settings that
belong to it, so there is one page per subject rather than a shallow one and a deep one.

Every claim in here was checked against the source or against a running build. Where a design was
forced by a measurement or by a bug, the document says so, because those are the sentences worth
reading twice.

## The shape of the thing

| | |
|---|---|
| [Four processes](architecture.md) | frontend, runtime, SES, pod — and why only one of them is disposable |
| [Sessions](sessions.md) | detach, reattach, replay, adoption, and what is written down |
| [Pods](pods.md) | one daemon per pane: the PTY, the backlog ring, exactly-once input |
| [Instances](instances.md) | two whole stacks on one machine that cannot see each other |

## Using it

| | |
|---|---|
| [Panes and tabs](panes-and-tabs.md) | the split tree, geometric focus, zoom, broadcast, select-and-swap |
| [Floats](floats.md) | overlay panes with lifetimes: per-directory, sticky, exclusive, sandboxed |
| [Keybindings](keybindings.md) | no prefix: chords, conditions, and what happens to the key afterwards |
| [Reading what already happened](copy-and-search.md) | scrollback search, copy-mode, OSC 133 prompt marks |
| [Overlays and popups](overlays.md) | notifications, questions, pickers, keycast, pane labels |

## Appearance

| | |
|---|---|
| [Painting](regions.md) | the bar, titles, sprites and popups are drawn by an external painter |
| [Shell integration](prompt.md) | what a shell reports to the mux, and how the prompt is drawn |
| [Palette protocol](palette.md) | a program claims its own 256-colour table for the output it writes |

## Configuring it

| | |
|---|---|
| [Configuration](config.md) | one Lua file, a schema that refuses typos, reload without losing panes |
| [Project sessions](session-manager.md) | `.hexe.lua`, freezing a session, and the trust ledger |
| [Isolation](isolation.md) | namespaces and cgroups per pane — and what it needs from the kernel |

## From outside

| | |
|---|---|
| [The command line](cli.md) | addressing sessions, panes and pods from a script |
| [Recording](recording.md) | hexe writes asciicasts of itself; every film below was made that way |

## The recordings

Each document opens with a recording of the feature actually running. They are not screencasts
somebody performed: every one is a script in [`scripts/demo`](../scripts/demo/), driven into a
real frontend by [`record.py`](../scripts/demo/record.py), so any of them can be made again
after the code changes — and a film that stops matching hexe is a bug in one or the other.

```sh
make demo-fixture                      # build the deterministic world under /tmp
make demo-record DEMO=floats           # re-record one
make demo-record                       # all of them
make demo-publish                      # upload, remember the ids in casts.tsv
make demo-embed                        # put the players back in the documents
```

They are filmed **with the author's own configuration and the author's own shell**: `fixture.sh`
copies `~/.config/hexe` and `~/.config/oslo` in as they are, so the prompt, the status bar, the
float borders and every key a film presses are the ones in daily use. Two things are changed on the
way in and both are marked in the fixture: the four agent floats get local, offline commands — a
recording must not open a paid agent or touch a network — and a small block of extra bindings is
appended for the actions the config does not bind but the documents describe.

The recorder is not tmux driving hexe, the way a shell's demos are usually made: hexe *is* the
thing under the recorder, and the chords these demos press are exactly the ones an outer
multiplexer would want for itself. Instead `record.py` opens a pty, starts a real frontend on it,
answers the terminal queries a TUI asks at startup — including the kitty keyboard one, without
which `Ctrl+Alt+.` cannot be sent at all — types, and writes what comes back as an asciicast.
Nothing in a film is synthesised: if a feature fails on the machine doing the recording, the film
shows it failing, which is what [isolation](isolation.md) is a recording of.

Every demo runs at 240×60 under its own instance, its own copy of the configuration, its own `HOME`
and its own state directories, so a recording can neither see nor disturb a real session or a real
history.

## Reading these

Each document has the same shape:

```
How it works          the mechanism, with a diagram
What makes it         the contrast with tmux, screen or zellij — stated only where it
  different             could be checked
Configuration         spellings verified against the code that reads them
Measurements          real numbers only; the section is absent when there are none
What it cannot do     required, and never empty
Where it lives        paths, and the types or functions that matter
Reference             the older reference material for that subject, where it still
                        holds — profiles, schemas, tables; absent from most pages
```

The **What it cannot do** section is the one to read first if you are deciding whether to rely on
something. It is required in every document precisely because a feature list that only lists wins
is not documentation.
