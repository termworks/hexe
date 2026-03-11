# Full UI / SES Separation Plan

This replaces the previous plan.

The previous work moved canonical session authority into SES, but it did not
finish the decoupling. The terminal frontend still owns a local attached-session
view/controller layer. This document starts from the code as it exists now and
defines the remaining work required to make the terminal frontend only a UI.

Completion must not be claimed until the exit criteria at the end of this file
are true.

## Current Truth

Right now the architecture is:

```text
terminal frontend
  = UI
  + local attached-session cache
  + local attached-session controller
  + local materialized tab/float/layout objects

SES
  = canonical session authority
  + pod owner
  + VT router
```

That is better than the old mux-owned model, but it is not full separation.

### Concrete blockers in the current tree

- `src/frontends/terminal/state.zig`
  - still owns `session_cache`, `attach_state`, `frontend_client`, and the live
    terminal view graph.
- `src/frontends/terminal/state_types.zig`
  - `TerminalViewState` still owns `tabs` and `floats`.
  - `Tab` still owns `Layout`.
- `src/frontends/terminal/state_sync.zig`
  - still builds canonical `SessionSnapshot` by walking terminal `Layout` and
    float objects.
- `src/frontends/terminal/state_reattach.zig`
  - still parses SES session state and reconstructs terminal session objects.
- `src/core/frontend_session_cache.zig`
  - still owns active tab, active float, focused pane, tab metadata, pane
    metadata, and the attached snapshot mirror.
- `src/core/frontend_attach_state.zig`
  - still owns attach/detach/reattach bookkeeping.
- `src/core/frontend_attach.zig`
  - still owns shared attach flow logic.
- `src/core/frontend_client.zig`
  - transport is abstracted, but only `local_ipc` exists today.
- `src/core/wire.zig`
  - still contains frontend-to-SES state sync and layout-tree sync messages.
- `src/modules/session/server.zig`
  - SES is authoritative, but it still accepts frontend-authored state blobs.

## Target Architecture

The target architecture is:

```text
                 +---------------------------+
                 |         FRONTEND          |
                 | terminal / web / desktop  |
                 |---------------------------|
                 | rendering                 |
                 | input mapping             |
                 | viewport geometry         |
                 | selection / popups        |
                 | local widget state        |
                 +-------------+-------------+
                               |
                               v
                 +---------------------------+
                 |   SHARED FRONTEND RUNTIME |
                 |---------------------------|
                 | attach lifecycle          |
                 | transport client          |
                 | session projection        |
                 | pane stream/backlog cache |
                 | command API               |
                 +-------------+-------------+
                               |
                  local IPC or | or liblink
                               v
                 +---------------------------+
                 |            SES            |
                 |---------------------------|
                 | canonical session graph   |
                 | focus / tabs / floats     |
                 | pane + pod lifecycle      |
                 | PTY size authority        |
                 | backlog retention         |
                 | metadata authority        |
                 +-------------+-------------+
                               |
                               v
                 +---------------------------+
                 |           PODS            |
                 | PTY + shell + processes   |
                 +---------------------------+
```

The important rule is:

```text
frontends do not own session truth
frontends do not describe session truth back to SES
frontends only render and send commands
SES is the only authority
```

## What "Full Separation" Actually Means

Full separation does not mean SES becomes a renderer.

SES must own:

- session identity
- tab list and tab order
- split tree
- float list and float visibility
- focused pane
- active tab
- active float
- pane membership
- pane metadata
- pane lifecycle
- pod lifecycle
- attach/detach
- backlog retention
- PTY size truth

Frontends must own only:

- renderer objects
- VT parser/render caches
- screen-coordinate layout math
- selection state
- hover / drag / popup state
- theme / statusbar widgets
- local notifications
- transient input buffers

Shared frontend runtime may own:

- transport connection state
- current SES session projection
- pane stream caches
- attach lifecycle state
- command helpers

The shared frontend runtime is not the authority. It is a client-side mirror.

## Non-Goals

- Backward compatibility is not a goal.
- Multi-view collaborative control is not part of this rewrite.
- SES should not become a terminal renderer.
- Remote is not a separate architecture. It is the same frontend runtime over a
  different transport.
- Incremental diff events are not required for correctness. Full SES snapshots
  are acceptable if SES is the only author of them.

## Architecture Rules

These rules are mandatory for the rewrite.

### Rule 1: the terminal frontend must stop building `SessionSnapshot`

`src/frontends/terminal/state_sync.zig` must stop walking terminal `Layout`,
tabs, and floats to build canonical session state.

If the terminal frontend still constructs `SessionSnapshot`, then the terminal
frontend still owns session semantics.

### Rule 2: the terminal frontend must stop parsing session JSON directly

`src/frontends/terminal/state_reattach.zig` must stop being the place where SES
session state is parsed and turned into canonical attached-session objects.

That work belongs in a shared frontend runtime layer.

### Rule 3: SES must stop accepting frontend-authored whole-session truth

`sync_state` and terminal-authored layout/tree sync are the wrong model for the
end state.

The frontend may send commands like:

- focus pane
- switch tab
- split pane
- close pane
- close tab
- create float
- move float
- resize float
- hide/show float
- rename tab
- set sticky

SES applies those mutations, then publishes the new authoritative state.

### Rule 4: session structure must move out of terminal `TerminalViewState`

`TerminalViewState` may keep visual widget state, but it must not be the owner
of:

- tab identity
- tab order
- split tree truth
- float identity
- float visibility truth
- active tab truth
- active float truth
- focused pane truth

Those belong in SES and the shared frontend runtime mirror.

### Rule 5: remote must reuse the exact same frontend runtime

There must not be a second remote-specific frontend architecture.

The target is:

```text
terminal frontend
  -> shared frontend runtime
  -> local IPC transport
  -> SES
```

and:

```text
terminal/web/desktop frontend
  -> shared frontend runtime
  -> liblink transport
  -> SES
```

Same protocol. Same projection model. Same attach lifecycle.

## Required New Core Pieces

These are the missing shared layers.

### 1. `FrontendRuntime`

New shared core type, likely in `src/core/frontend_runtime.zig`.

Responsibilities:

- own the transport client
- own attach lifecycle
- own the frontend-side session projection
- own pane stream/backlog state
- expose semantic commands to the frontend
- receive SES snapshots/events
- update the projection

The terminal frontend should depend on this runtime instead of directly owning
session cache and attach state.

### 2. `SessionProjection`

New shared core type, likely in `src/core/session_projection.zig`.

Responsibilities:

- frontend-neutral mirror of SES session state
- tabs, floats, panes, focus, active tab, active float
- no screen coordinates
- no terminal renderer objects
- no popup state

This becomes the frontend-visible session model.

### 3. `PaneStreamState`

New shared core type, likely in `src/core/pane_stream_state.zig`.

Responsibilities:

- backlog buffer or replay state
- live VT byte stream state
- pane-level metadata mirrored from SES
- frontend-neutral mapping by pane UUID

Terminal-specific VT parser/render objects may wrap this, but should not be the
canonical attached-session model anymore.

### 4. Terminal-only view state

Terminal-specific state should remain under `src/frontends/terminal/`.

It should contain:

- widget layout caches
- computed pane rectangles
- z-order for rendering
- selection
- popups
- drag state
- notification display

It should not define session truth.

## Protocol Reset

The wire protocol should be reshaped around this rule:

```text
frontends send commands
SES sends authoritative state
```

### Keep

- register / registered
- reattach / session_reattached
- session_state
- pane_exited
- notify
- VT frames
- pane metadata updates from SES/pods

### Remove or deprecate

- `sync_state`
- frontend-authored whole-session JSON sync
- frontend-authored layout-tree replacement as a normal UI mutation path

### Replace with semantic session commands

At minimum:

- `set_active_tab`
- `focus_pane`
- `split_pane`
- `close_pane`
- `close_tab`
- `create_tab`
- `rename_tab`
- `create_float`
- `close_float`
- `show_float`
- `hide_float`
- `move_float`
- `resize_float`
- `set_active_float`
- `set_sticky`
- `report_viewport_sizes`

Important note:

`report_viewport_sizes` is not a session-ownership leak. The frontend computes
screen-space rectangles; SES still decides and applies PTY size authority.

### Snapshot vs event model

For this rewrite, full SES-authored snapshots are acceptable.

Incremental events can be added later, but they are not required to complete
the separation. The critical thing is that SES is the only author of session
truth, and the frontend runtime is the only place that applies that truth
client-side.

## Execution Plan

This is the actual remaining rewrite, in order.

### Phase 1: build the shared runtime and move session parsing there

1. Introduce `FrontendRuntime` and `SessionProjection`.
2. Move `frontend_session_cache.zig` functionality into the runtime/projection.
3. Move `frontend_attach_state.zig` and `frontend_attach.zig` into the runtime.
4. Move session JSON parsing and snapshot application out of
   `src/frontends/terminal/state_reattach.zig`.
5. Make the terminal frontend consume projection state from the runtime.

Done when:

- terminal no longer owns `session_cache`
- terminal no longer owns `attach_state`
- terminal no longer parses `SessionSnapshot` JSON

### Phase 2: stop frontend-authored state sync

1. Delete `buildSessionSnapshot()` from the terminal frontend.
2. Remove `syncStateToSes()` as a source of truth.
3. Remove terminal-authored normal-path layout/tree sync.
4. Add missing semantic commands for every session mutation the terminal UI can
   trigger.
5. Make SES mutate its session graph from those commands only.
6. After each accepted mutation, SES publishes the new authoritative state.

Done when:

- terminal does not construct `SessionSnapshot`
- SES does not accept terminal-authored whole-session state
- session mutations are command-based

### Phase 3: move session graph ownership out of terminal view structs

1. Remove session identity and session structure ownership from
   `TerminalViewState`.
2. Replace `Tab.layout` as session truth with terminal view objects derived from
   `SessionProjection`.
3. Keep only terminal-specific widget/layout caches in terminal state.
4. Make terminal view reconciliation derive from projection state instead of
   being the owner of tabs/floats/layout truth.

Done when:

- `TerminalViewState` is visual-only
- terminal `Tab` is a view/widget, not a session owner
- split tree truth lives only in SES + shared projection

### Phase 4: split terminal `Pane` into view vs session/runtime pieces

1. Audit `src/frontends/terminal/pane.zig`.
2. Move session-shaped fields out of terminal pane objects into shared runtime
   records.
3. Keep terminal pane widgets responsible only for VT/render/input behavior.
4. Make pane metadata and lifecycle queries go through the runtime/projection.

Done when:

- terminal pane objects are render/input widgets
- session metadata lives in SES/runtime projection

### Phase 5: make attach/detach/reattach fully runtime-driven

1. Terminal startup should just create the runtime and attach.
2. Reattach should rebuild the projection in shared core, not in terminal code.
3. Backlog replay coordination should live in the runtime.
4. Session stolen / reconnect / detach flows should live in the runtime.

Done when:

- terminal main loop does not implement attach semantics itself
- shared runtime owns the attach lifecycle

### Phase 6: make transport truly frontend-neutral

1. Extend `FrontendClient.Transport` beyond `local_ipc`.
2. Add `liblink` transport.
3. Make transport selection a runtime concern, not a terminal concern.
4. Reuse the exact same attach/session/VT path for remote frontends.

Done when:

- local and remote frontend attachment share the same runtime path
- no terminal-specific remote architecture exists

### Phase 7: delete the leftover coupling

1. Delete dead snapshot sync code.
2. Delete dead layout-tree sync code used by normal UI mutations.
3. Delete no-longer-needed terminal-side session caches.
4. Rename leftovers so the code reads honestly.
5. Update docs after the code is actually finished.

Done when:

- the old coupling paths are removed, not just unused

## Test Plan

This rewrite needs tests at the boundary that actually matters now.

### SES tests

- command mutates canonical session graph correctly
- attach/reattach returns correct authoritative state
- pane/pod lifecycle updates session state correctly
- viewport-size reports update PTY sizes correctly

### Shared frontend runtime tests

- snapshot application builds the correct `SessionProjection`
- command helpers send the right wire messages
- attach/detach/session-stolen flows update runtime state correctly
- backlog replay populates pane stream state correctly

### Terminal frontend tests or smoke checks

- startup attach
- open/close tabs
- split/resize/close panes
- show/hide/move/resize floats
- detach/reattach
- statusbar and focus behavior

### Transport tests

- same runtime behavior over `local_ipc`
- same runtime behavior over `liblink`

## Exit Criteria

The rewrite is done only when all of the following are true:

1. The terminal frontend does not build `SessionSnapshot`.
2. The terminal frontend does not parse SES session JSON directly.
3. The terminal frontend does not send whole-session or whole-layout truth to
   SES as the normal UI mutation path.
4. SES is the only author of session structure.
5. A shared frontend runtime owns attach lifecycle and session projection.
6. Terminal state contains only terminal-specific view/render/input state.
7. Local and remote frontends use the same runtime and protocol shape.
8. `PLAN.md` can be removed or marked complete without hand-waving.

Until then, the honest description is:

```text
SES is canonical authority,
but the terminal frontend still contains a local attached-session layer.
```
