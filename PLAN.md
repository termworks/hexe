# UI / SES Separation Plan

This plan resets the architecture around one hard rule:

```text
MUX is a frontend.
SES is the session authority.
PODS are the execution/runtime endpoints.
```

The terminal mux stops being the owner of session truth. It becomes one UI
client among others. Later frontends such as a Web UI or desktop app should be
able to talk to SES through the same session protocol, locally or remotely.

This is a breaking rewrite plan. Backward compatibility is not a goal.

## End Goal

The target architecture is:

```text
             local transport                      remote transport
        (unix socket / local IPC)                  (liblink stream)

 terminal UI  -----\
 web UI gateway ----+--> frontend client protocol --> SES --> PODS
 desktop UI  ------/                                  |
                                                     backlog
                                                     metadata
                                                     session graph
```

More explicitly:

```text
frontend:
  - rendering
  - keybindings
  - mouse
  - local VT cache
  - local ephemeral view state

SES:
  - session graph
  - tab/focus/float/session truth
  - pane lifecycle
  - pod creation/destruction
  - backlog retention + replay
  - attach/detach
  - metadata routing
  - local or remote transport endpoint

POD:
  - PTY
  - shell/process
  - raw VT byte source/sink
```

## Why This Rewrite Exists

The current code is not frontend-neutral.

Today, the terminal mux still owns the attached session model and SES mostly
stores a mux snapshot:

- `src/frontends/terminal/state.zig`
  - owns `tabs`, `active_tab`, `floats`, `active_floating`, renderer state,
    overlays, popups, mouse state, timers, selection state, etc.
- `src/frontends/terminal/state_serialize.zig`
  - serializes the mux's full attached state to JSON, including terminal-view
    geometry such as pane `x/y/width/height`.
- `src/frontends/terminal/state_sync.zig`
  - pushes that serialized mux state into SES with `syncStateToSes()`.
- `src/modules/session/state.zig`
  - stores that JSON as `Client.last_mux_state`.
  - stores detached sessions as `DetachedMuxState { mux_state_json, pane_uuids }`.
- `src/modules/session/server.zig`
  - detach/reattach returns mux JSON back to the frontend.
  - VT routing is already centralized in SES (`routePodToMux`, `routeMuxToPod`).
- `src/frontends/terminal/state_reattach.zig`
  - rebuilds the live UI by parsing mux JSON and adopting panes one by one.
- `src/frontends/terminal/layout.zig`
  - can still create panes locally or through SES.
- `src/frontends/terminal/pane.zig`
  - still supports both local PTY panes and SES/pod-backed panes.

That split is why adding another UI is awkward. The terminal frontend is not
just a renderer; it is also the attached-session controller.

## Core Architectural Decision

We are not moving "everything" into SES.

We are moving session authority into SES.
We are keeping frontend-local rendering state in the frontend.

That distinction matters.

### SES must own

- session identity
- session name
- tab list and tab order
- split tree structure
- float list and float ownership
- active tab
- focused pane
- visible/hidden float state
- pane membership in tabs/floats
- pane lifecycle
- pod lifecycle
- pane metadata
- backlog retention and replay
- attach/detach/reattach
- resize authority for the real PTY

### Frontends must own

- renderer caches
- terminal emulator instances
- viewport geometry in local screen coordinates
- selection state
- mouse drag state
- hover state
- inline rename buffers
- popups/overlays/tooltips
- theme
- local notification presentation
- scroll position if it is purely view-local

### Important nuance: SES does not need to own VT rendering

SES should manage VT bytes and backlog, but not become a renderer.

Reason:

- terminal rendering is frontend-specific
- web rendering is frontend-specific
- desktop rendering is frontend-specific
- renderer caches and selection state are inherently local

So the clean model is:

```text
SES owns:
  pod size
  raw VT stream
  backlog
  session graph

frontend owns:
  VT parser instance
  render cache
  viewport math
```

A frontend attaches, receives the session snapshot, then reconstructs each pane
from backlog replay plus live VT frames.

## Simplifying Assumption For V1

One session has one controlling attached frontend at a time.

That matches the current behavior closely enough and avoids inventing multi-view
focus semantics during the rewrite.

So in V1:

- `active_tab` is session-global
- `focused_pane` is session-global
- float visibility is session-global
- the controlling frontend sets PTY size

Later, if we want true multi-view:

- session-global state stays in SES
- per-view state gets introduced explicitly as `ViewState`
- observers become separate attachment modes

But that is not the first target.

## Target Model

The target data model is:

```text
Session
  id
  name
  active_tab_id
  focused_pane_uuid
  active_float_uuid?
  tabs[]
  panes{}
  floats[]
  attached_frontend?

Tab
  id
  name
  root_layout_node_id
  ordered children via split tree

LayoutNode
  pane(uuid)
  split(dir, ratio, first_node_id, second_node_id)

PaneRecord
  uuid
  pane_id
  kind(split|float)
  parent_tab_id?
  sticky metadata
  cwd
  fg_process
  fg_pid
  title
  exit status
  cols
  rows
  dead/alive

FloatRecord
  pane_uuid
  scope(global|tab)
  owner_tab_id?
  visible
  float_key
  width_pct
  height_pct
  pos_x_pct
  pos_y_pct
  pad_x
  pad_y
  border/style metadata
```

What is intentionally not in the canonical session model:

- pane `x`
- pane `y`
- border draw coordinates
- local popup state
- local mouse selection state
- local render objects

Those are frontend concerns.

## Ownership Matrix

```text
+--------------------------------------+-------------------+----------------------+
| Concern                              | SES               | Frontend             |
+--------------------------------------+-------------------+----------------------+
| Session id/name                      | authoritative     | cached               |
| Tab list/order                       | authoritative     | cached               |
| Split tree ratios                    | authoritative     | cached               |
| Float definitions/visibility         | authoritative     | cached               |
| Focused pane / active tab            | authoritative     | cached               |
| Pane creation/destruction            | authoritative     | command only         |
| Pod runtime                          | authoritative     | no ownership         |
| VT byte stream / backlog             | authoritative     | consumes             |
| PTY cols/rows                        | authoritative     | requests changes     |
| Renderer cache                       | none              | authoritative        |
| Pixel/cell placement in viewport     | none              | authoritative        |
| Mouse drag / selection / overlays    | none              | authoritative        |
| Notifications as events              | emits             | renders              |
| Attach/detach state                  | authoritative     | reflected            |
+--------------------------------------+-------------------+----------------------+
```

## Local And Remote Must Use The Same Model

Remote is not a second session architecture.

Remote must be the same attachment model over a different transport.

Correct model:

```text
local terminal frontend
  -> frontend protocol over unix socket
  -> local SES
  -> local pods
```

```text
local terminal frontend
  -> frontend protocol over liblink
  -> remote SES
  -> remote pods
```

That means:

- no remote-specific session model
- no remote-specific "layout export/import" architecture as the main path
- no direct frontend-to-pod remote bypass
- remote access is still SES-authoritative

If we need a helper on the remote side, it should only bridge transport:

```text
frontend <-> liblink <-> remote SES bridge <-> remote SES internals
```

But the session protocol itself must stay the same.

## Frontend Protocol

The current binary wire protocol is too mux-specific in the wrong places:

- `.sync_state` pushes frontend-owned JSON to SES
- `.detach` stores mux JSON
- `.reattach` returns mux JSON

That needs to be inverted.

### New protocol shape

Keep the idea of:

- one control channel
- one VT/event stream channel

But change the meaning.

#### Frontend -> SES commands

- `frontend_register`
- `attach_session`
- `create_session`
- `detach_session`
- `close_session`
- `create_split`
- `create_tab`
- `close_pane`
- `close_tab`
- `focus_pane`
- `focus_direction`
- `set_active_tab`
- `toggle_float`
- `move_float`
- `resize_float`
- `send_input`
- `resize_pane`
- `set_pane_name`
- `set_sticky`
- `request_snapshot`
- `request_backlog`

#### SES -> frontend events

- `session_snapshot`
- `session_patch`
- `pane_created`
- `pane_closed`
- `pane_meta_changed`
- `focus_changed`
- `active_tab_changed`
- `float_visibility_changed`
- `vt_frame`
- `backlog_begin`
- `backlog_end`
- `pane_exited`
- `session_stolen`
- `notify`
- `error`

### Snapshot + patch model

Attach should work like this:

```text
frontend                     SES
   |                          |
   | attach_session --------> |
   |                          |
   | <----- session_snapshot  |
   | <----- backlog_begin     |
   | <----- vt_frame...       |
   | <----- backlog_end       |
   | <----- live events...    |
```

The frontend never sends "here is my whole layout JSON".
SES sends the canonical session snapshot instead.

## Terminal Frontend Runtime Model

The terminal frontend should become:

```text
terminal UI
  - input bindings
  - renderer
  - local VT instances
  - local cache of SES snapshot
  - command dispatch to SES
```

In practice that means:

- `src/frontends/terminal/state.zig` gets split
- session-authoritative fields leave the frontend
- frontend-local fields stay

### Session data to remove from frontend ownership

- `tabs`
- `active_tab`
- `floats`
- `active_floating`
- focus truth
- pane existence truth
- attach/detach truth
- session layout truth

### Frontend data to keep

- renderer
- notifications/popups
- overlays
- mouse selection
- timers
- bracketed paste handling
- VT write queue if it remains an output/input scheduling concern
- local pane VT objects

## Hard Cuts We Should Make

Because backward compatibility is not required, the rewrite should delete the
old architecture aggressively instead of carrying both paths.

### Remove

- `Client.last_mux_state` as the source of truth
- detached session storage as raw mux JSON
- frontend-owned `syncStateToSes()` model
- current JSON `state_serialize.zig` detach/reattach path
- local PTY fallback in frontend pane creation
- `Pane.backend.local`

### Replace with

- canonical SES `Session` model
- SES snapshot + patch protocol
- SES-owned attach/detach state
- pod-backed panes only
- frontend-local VT/view reconstruction from SES replay

## File-Level Rewrite Plan

### SES side

#### `src/modules/session/state.zig`

Rewrite from:

- `Client`
- `DetachedMuxState`
- pane maps + detached session JSON

Into:

- `Session`
- `TabRecord`
- `LayoutNodeRecord`
- `PaneRecord`
- `FloatRecord`
- `FrontendAttachment`
- detached session storage as canonical session snapshot, not mux JSON

Keep:

- pane lifecycle
- pod ownership
- orphan/sticky logic if still desired

#### `src/modules/session/server.zig`

Rewrite responsibilities to:

- accept frontend commands
- mutate SES session model
- emit session snapshot and patch events
- continue VT routing
- serve attach/detach directly from canonical model

Delete or replace:

- old `.sync_state`
- old `.detach` payload semantics
- old `.reattach` payload semantics
- old `get_session_state` mux JSON export path as the primary architecture

#### `src/core/wire.zig`

This file needs a protocol reset.

Likely keep:

- handshake structure
- frame size limits
- VT frame container idea

Replace:

- mux-specific control messages with frontend/session messages

### Frontend side

#### `src/frontends/terminal/ses_client.zig`

Turn this into a generic frontend session client.

It should:

- connect to SES
- register frontend kind
- send session commands
- receive snapshot/patch events
- receive VT frames

It should not:

- pretend the frontend owns canonical session layout

#### `src/frontends/terminal/layout.zig`

This should stop being a session creator.

New role:

- frontend-local layout materialization from SES snapshot
- viewport geometry calculation
- render traversal helpers

Delete:

- local PTY spawn path
- SES pane creation fallback logic as a hidden implementation detail

#### `src/frontends/terminal/pane.zig`

This should become a view object for a session pane.

Keep:

- VT instance
- render helpers
- local ephemeral flags

Remove:

- local backend
- PTY spawning
- local respawn semantics

Panes become:

```text
PaneView
  uuid
  local VT
  geometry in current viewport
  float visual state
  local UI-only state
```

#### `src/frontends/terminal/state_serialize.zig`

Delete or reduce drastically.

The frontend should no longer serialize the canonical session model to SES.

#### `src/frontends/terminal/state_sync.zig`

Rewrite entirely.

Instead of "sync whole mux state to SES", it becomes:

- command dispatch
- local cache update from SES events
- maybe optimistic UI if desired later

#### `src/frontends/terminal/state_reattach.zig`

Rewrite entirely.

Reattach becomes:

- request `session_snapshot`
- build local view objects
- request/consume backlog replay
- enter live event loop

No mux JSON parsing.

### Naming cleanup

After the separation lands, `multiplexer` is a misleading name.

Longer term:

```text
src/frontends/terminal -> src/frontends/terminal
```

Do not block the rewrite on this rename. The architectural separation matters
more than the directory name.

## Rewrite Phases

The rewrite is now split into two bounded phases:

- Phase 1: establish SES authority and a shared frontend protocol/client
- Phase 2: finish the terminal frontend cut until mux is UI-only

Phase 1 is already mostly done in the current branch history.
Phase 2 is still required for full separation.

### Phase 1: Foundational Cut

This was the first bounded rewrite pass. It established:

- canonical SES session snapshots
- SES-owned tab/float/layout/focus mutations
- SES-only pane/pod ownership
- terminal restore from SES snapshots
- shared frontend client in `src/core/frontend_client.zig`

That was necessary, but it is not the end state.

### Phase 2: Full Frontend Separation

This is the remaining work required to make the terminal mux a frontend only.

Important:

- `src/frontends/terminal/state.zig` still owns `tabs`, `active_tab`,
  `floats`, and `active_floating`
- the terminal frontend still rebuilds and materializes session structure in
  `state_reattach.zig`
- the frontend still mixes session cache, viewport/layout materialization, and
  UI state inside one `State`

So the current state is:

```text
SES = canonical session authority
terminal mux = frontend + local session cache/view-model
```

The target state is:

```text
SES = session authority
frontend session client/cache = transport + snapshot/event cache
terminal mux = UI only
```

The implementation should continue in multiple large slices, but it now needs a
second bounded phase rather than pretending the work already fits inside the
original five-commit sketch.

### Commit 1: Introduce canonical SES session model

Goal:

- SES becomes able to represent a full session without mux JSON.

Work:

- add canonical session structs in `session/state.zig`
- move tab/split/float/focus ownership into SES
- change detach storage from raw mux JSON to canonical session snapshot
- keep old frontend compiling temporarily only if needed to bridge the next cut

Success criteria:

- SES can create, store, mutate, and detach a session without `last_mux_state`

### Commit 2: Replace sync/detach/reattach with snapshot+command protocol

Goal:

- frontend stops sending the whole session state up

Work:

- reset `wire.zig` control messages
- rewrite `ses_client.zig` around attach/snapshot/command/event flow
- rewrite `session/server.zig` handlers
- remove `.sync_state` as canonical behavior

Success criteria:

- frontend attaches and receives a canonical session snapshot from SES
- session mutations happen through commands, not JSON uploads

### Commit 3: Remove local PTY ownership from frontend

Goal:

- SES owns all panes and all pods

Work:

- delete `Pane.backend.local`
- delete local spawn/fallback from `layout.zig` and `pane.zig`
- make pane creation/destruction SES-only
- simplify frontend pane model to VT/view only

Success criteria:

- no frontend code spawns PTYs
- all running panes are SES/pod-backed

### Commit 4: Split terminal frontend state into session cache vs UI-only state

Goal:

- terminal mux becomes a real frontend

Work:

- shrink `multiplexer/state.zig`
- move session truth out of frontend ownership
- keep local renderer/input/view state only
- rebuild layout/float rendering from SES snapshots and events
- rewrite reattach path around snapshot + backlog replay

Success criteria:

- terminal frontend can die and reattach without being the source of session truth
- there is a clear boundary between session cache and UI-only state

This is not sufficient for the final goal by itself.

After this point, the terminal frontend may still hold a local session
cache/view-model. Full conversion requires moving even that layer out of the
terminal-specific runtime.

### Commit 5: Transport abstraction and remote liblink attach

Goal:

- the same frontend can attach locally or remotely

Work:

- define transport abstraction under the frontend client
- implement local IPC transport
- implement liblink transport
- attach to remote SES using the same session protocol
- if necessary, add a minimal remote SES bridge helper, but keep the session
  protocol identical

Success criteria:

- terminal frontend can attach to local SES
- terminal frontend can attach to remote SES over liblink
- remote does not require a separate session model

## Remaining Work For Full Separation

The following phase is now explicit and should be completed in up to 10 more
commits.

### Phase 2 Commit 1: Extract frontend session cache from terminal state

Goal:

- stop storing session cache directly inside terminal `State`

Work:

- introduce a dedicated frontend session cache module under `src/core/`
- move tab/float/focus/session snapshot data there
- make terminal `State` reference that cache instead of owning it structurally

Success criteria:

- terminal `State` no longer defines the canonical attached session cache shape

### Phase 2 Commit 2: Split UI layout objects from session layout objects

Goal:

- stop treating terminal layout objects as the same thing as attached session state

Work:

- define a frontend-neutral attached layout cache
- keep terminal `Layout` as a render/input object only
- map session cache nodes to terminal layout objects during presentation

Success criteria:

- terminal `Layout` is no longer the attached session model

### Phase 2 Commit 3: Move tab/focus/float navigation onto cache APIs

Goal:

- remove direct terminal ownership of current tab/float/focus semantics

Work:

- replace direct `tabs.items[...]`, `active_tab`, and `active_floating`
  authority flows with frontend cache queries/commands
- make terminal navigation consume cache state and send commands, not define truth

Success criteria:

- tab/focus/float behavior is driven by cache + SES, not terminal `State` fields

### Phase 2 Commit 4: Make snapshot apply incremental

Goal:

- stop rebuilding large parts of the terminal session presentation on every
  structural update

Work:

- add frontend snapshot delta / patch application
- keep stable pane view reuse, but apply mutations through cache updates first
- limit terminal rebuilds to presentation materialization

Success criteria:

- the frontend consumes snapshot/patch updates without treating itself as the
  structural owner

### Phase 2 Commit 5: Move pane/session metadata caches out of terminal state

Goal:

- remove non-UI metadata ownership from the terminal runtime

Work:

- move pane names, cwd/process snapshots, session identity mirrors, and similar
  attached-session caches into the shared frontend cache/client layer

Success criteria:

- terminal `State` only keeps data that is needed for rendering or interaction

### Phase 2 Commit 6: Reduce terminal state to UI concerns only

Goal:

- make the terminal state object visibly frontend-only

Work:

- keep renderer, VT instances, overlays, notifications, mouse/input state,
  selection state, popups, timers, and keybinding runtime
- remove session-graph ownership fields from terminal `State`

Success criteria:

- `src/frontends/terminal/state.zig` reads like a UI runtime, not a session model

### Phase 2 Commit 7: Formalize frontend attach lifecycle

Goal:

- make attach/detach/reattach belong to the shared frontend layer, not to the
  terminal-specific runtime

Work:

- move attach session flow, backlog replay coordination, and stolen-session
  handling into the shared frontend client/cache layer

Success criteria:

- another frontend could reuse attach logic without depending on terminal code

### Phase 2 Commit 8: Add remote transport to shared frontend client

Goal:

- make local and remote attach use the same frontend layer

Work:

- add `liblink` transport under `src/core/frontend_client.zig`
- keep session protocol identical
- do not reintroduce remote-specific session modeling

Success criteria:

- the same frontend client can attach over local IPC or liblink

### Phase 2 Commit 9: Make terminal frontend transport-agnostic

Goal:

- remove local-only assumptions from terminal startup/attach code

Work:

- make terminal frontend choose a frontend-client transport instead of assuming
  local SES
- keep terminal runtime unaware of local-vs-remote session semantics

Success criteria:

- terminal UI can target either local or remote SES without architectural forks

### Phase 2 Commit 10: Final cleanup and naming cut

Goal:

- finish the separation visibly and remove transitional language

Work:

- delete remaining mux-specific protocol naming where inappropriate
- remove leftover transition shims/aliases
- if the tree is stable enough, rename `src/frontends/terminal` to
  `src/frontends/terminal`

Success criteria:

- the terminal frontend is obviously one frontend among several possible clients
- there is no ambiguity about SES vs frontend ownership

## What To Defer Until After The Separation

These should not block the rewrite:

- full Web UI
- desktop app
- true multi-view collaborative attachments
- observer mode
- remote registry UX
- remote project/layout sync
- HTTP API design

First make the core model right.

## Web UI / Desktop UI Implication

Once the rewrite is done, new frontends should look like this:

```text
terminal frontend
  -> frontend client
  -> local ipc or liblink
  -> SES

desktop frontend
  -> frontend client
  -> local ipc or liblink
  -> SES

web UI
  -> websocket/http bridge
  -> frontend client or protocol adapter
  -> local ipc or liblink
  -> SES
```

Important:

- SES should not become an HTTP app just to support a browser
- browser-specific transport should be a thin adapter over the session protocol

## Rules During The Rewrite

These rules should be enforced while refactoring:

1. No frontend module may become the canonical owner of tabs/floats/focus again.
2. No frontend module may spawn a PTY directly.
3. SES must never depend on terminal-screen coordinates as canonical truth.
4. Remote support must reuse the same session protocol as local support.
5. New feature work on the old mux JSON sync path should stop.
6. The rewrite must be delivered in multiple slices, not one huge dump.
7. Phase 1 stays as delivered; the remaining full separation is allowed one
   additional bounded phase of up to 10 more commits.
8. Each slice must be committed before starting the next slice.
9. Each commit message must be one line, title only.

## Acceptance Criteria

We are done when all of this is true:

- terminal mux can only act as a frontend
- terminal mux does not own attached session cache structure
- SES owns session structure and lifecycle
- SES owns all pane/pod creation
- attach uses SES snapshot + replay, not mux JSON restore
- local and remote attach use the same session protocol
- adding a second frontend does not require inventing a second session model

## Immediate Next Step

Do not start with Web UI or remote UX.

Start with the local architecture cut:

```text
SES canonical session model
  ->
frontend snapshot/command protocol
  ->
frontend no longer spawns PTYs
  ->
remote transport
```

That ordering gives us one solid core instead of repeating the old mux-centric
design over more transports.
