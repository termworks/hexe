# Architecture

Hexe is organized around a strict authority split:

```text
frontend UI
    ->
shared frontend runtime
    ->
SES session authority
    ->
POD PTY daemons
```

Today the shipped frontend is the terminal frontend, exposed as
`hexe terminal`. `hexe mux` and `hexe multiplexer` remain compatibility
aliases.

## High-level picture

```text
                         local transport
┌──────────────────┐     (unix sockets)      ┌─────────────────────┐
│ terminal frontend│ ──────────────────────> │ shared runtime      │
│                  │                         │ + frontend client   │
│ - input          │ <────────────────────── │ + session projection│
│ - rendering      │    session snapshots    │ + attach lifecycle  │
│ - popups         │       + VT stream       └──────────┬──────────┘
│ - view state     │                                    │
└──────────────────┘                                    │
                                                        v
                                              ┌─────────────────────┐
                                              │ SES                 │
                                              │ session authority   │
                                              │                     │
                                              │ - canonical session │
                                              │   graph             │
                                              │ - detach/reattach   │
                                              │ - pane ownership    │
                                              │ - command handling  │
                                              │ - VT routing        │
                                              └──────────┬──────────┘
                                                         │
                                      ┌──────────────────┴──────────────────┐
                                      v                                     v
                              ┌─────────────────┐                   ┌─────────────────┐
                              │ POD             │                   │ POD             │
                              │ per-pane PTY    │                   │ per-pane PTY    │
                              │ backlog         │                   │ backlog         │
                              │ shell metadata  │                   │ shell metadata  │
                              └────────┬────────┘                   └────────┬────────┘
                                       │                                     │
                                       v                                     v
                                     SHELL                                 SHELL
```

Remote frontend attachment uses the same runtime and protocol shape:

```text
frontend UI
    ->
shared frontend runtime
    ->
liblink transport
    ->
remote `hexe session pipe`
    ->
remote SES
    ->
remote PODs
```

Remote is transport, not a second architecture.

## Ownership

| Layer | Owns | Does not own |
|---|---|---|
| Frontend UI | rendering, keybindings, mouse handling, popups, status bar, terminal-specific view objects | session truth, pane ownership, detach semantics |
| Shared frontend runtime | attach lifecycle, session projection, transport wiring, command API, backlog coordination | canonical session graph |
| SES | canonical session graph, session IDs/names, pane/tab/float structure, focus authority, detach/reattach, pane ownership, VT routing | terminal-specific rendering state |
| POD | PTY fd, shell process, backlog buffer, cwd/process/title metadata | session structure, multi-pane layout |

## What "frontend-only" means

The terminal frontend is not a shell owner and not a session authority.
It is a UI over shared runtime state.

It still has real local state, but that state is visual:

- split/tree widgets
- float widgets
- Ghostty VT render state
- focus ring and selection state
- status bar and popup state
- mouse drag / resize interaction state

That state is a projection of SES-owned session truth, not the canonical
session model itself.

## Canonical session flow

### 1. Attach

```text
terminal frontend
    ->
FrontendRuntime.attachFrontend()
    ->
FrontendClient.connect()
    ->
SES register / attach
    ->
SES returns authoritative session snapshot + backlog info
    ->
runtime builds SessionProjection
    ->
frontend builds view objects
```

### 2. Live mutation

The frontend does not send whole-session truth anymore.

```text
user action
    ->
terminal frontend
    ->
runtime command helper
    ->
FrontendClient semantic command
    ->
SES mutates canonical session graph
    ->
SES publishes authoritative session_state
    ->
runtime updates SessionProjection
    ->
frontend reconciles view state
```

Examples of semantic commands:

- add/remove tab
- split/create/close/replace
- create/remove/sync float
- focus/tab navigation updates
- pane create/adopt/kill/orphan

### 3. VT flow

```text
keyboard input
    ->
frontend
    ->
runtime/client VT channel
    ->
SES
    ->
target POD
    ->
shell

PTY output
    ->
POD
    ->
SES
    ->
runtime/client VT channel
    ->
frontend VT widget
```

SES stays in the middle because it owns pane routing and session lifecycle.
Frontends do not connect directly to PODs.

### 4. Detach / reattach

```text
frontend detach
    ->
runtime detach request
    ->
SES persists canonical session state
    ->
frontend exits

later:

new frontend
    ->
runtime attach
    ->
SES authoritative snapshot
    ->
runtime projection rebuild
    ->
frontend views rebuilt
```

No frontend-authored snapshot is the source of truth here. SES is.

## Remote model

Remote support should not fork the architecture:

```text
local terminal/web/desktop frontend
    ->
same FrontendRuntime
    ->
transport:
  - local_ipc
  - preconnected
  - liblink
    ->
SES
```

For `liblink`, the runtime tunnels the same CTL/VT frontend protocol to a
remote SES endpoint using the internal `hexe session pipe` bridge command.

That means:

- remote is transport, not a separate session model
- SES remains the authority whether local or remote
- a future web or desktop frontend should reuse the same runtime contract

## Design rules

1. SES is the only author of session structure.
2. Frontends never send whole-session truth as the normal mutation path.
3. Frontends reconcile from authoritative SES snapshots.
4. POD owns the PTY and shell lifetime.
5. Remote frontend support must reuse the same runtime and wire protocol.
6. Terminal-specific view state must stay out of SES.

## Terminology

- `terminal frontend`: the current terminal UI process, invoked as
  `hexe terminal`
- `runtime`: the shared frontend-side layer that owns attach lifecycle,
  transport, and session projection
- `projection`: the frontend-side mirror of authoritative SES session state
- `SES`: session authority and VT router
- `POD`: per-pane PTY daemon

Compatibility note:

- `hexe mux` and `hexe multiplexer` still exist as aliases
- older docs or configs may still say "mux"
- the current architecture should be read as `terminal frontend + runtime`
  talking to `SES`, not as "mux owns the session"
