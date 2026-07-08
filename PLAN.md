# Hexe — Roadmap & Hardening Plan

Assessment and prioritized roadmap for hexe (SES session authority + per-pane POD
PTY hosts + terminal/web/syslink frontends). Written against `25d84d1`.

## Verdict

The architecture is sound. The SES / frontend / POD authority split is real
(no upward imports, no cycles), documented in `docs/architecture.md`, and is the
reason shells survive a frontend crash. The work ahead is not redesign; it is
closing three gaps:

1. **The test safety net is largely fake** — `zig build test` reports 110/110
   green while 126 of 236 authored tests never execute, and CI runs no tests.
2. **A few cross-process robustness holes remain** — no single-instance daemon
   lock, blocking I/O that moved from SES into POD, and small security issues.
3. **The host-adapter refactor is half-landed** — it added carrying cost (a
   second copy of session state that nothing reads) without yet delivering its
   payoff (a working second frontend).

Fix the test wiring first. Almost everything else becomes safer to do once the
safety net is real.

---

## Phase 0 — Make the safety net real (prerequisite, days) — ✅ DONE

Do this before anything risky below.

**Status:** both items landed. `zig build test` now compiles and runs 229 tests
(was 110) — the entire `core/` Lua-config layer, `api_bridge`, and
`frontends/core/` now execute. 218 pass, 11 bit-rotted tests are marked
`dormantSkip()` with a reason + TODO (grep `dormantSkip`) pending the
frontend_view decision (2.2), a Lua-DSL refresh, and a stubbed exec backend.
CI (`.github/workflows/ci.yml`) now gates every push/PR to main/develop on
`zig fmt --check` + `zig build test`.

### 0.1 — Half the tests never run · S · HIGH · ✅ DONE
- 236 `test` blocks exist; only 110 execute. All of `core/` (Lua config,
  `api_bridge`, `session_config`, `config_v2`), the entire `frontends/core/`
  layer, and the web/syslink hosts are dormant.
- Cause: `core/mod.zig` is only a dependency module (`build.zig:54`), never an
  `addTest` root; the `frontend_core`/`web`/`syslink` test targets root at
  aggregator `mod.zig` files that only `pub const`-re-export, and Zig collects
  no `test` blocks from those without a `refAllDeclsRecursive` shim.
- Fix: add `test { std.testing.refAllDeclsRecursive(@This()); }` to the three
  aggregator `mod.zig` roots, and add a new `addTest` target rooted at
  `src/core/mod.zig` (with the same shim) wired into the `test` step.
- Expect the newly-live tests to surface real failures — that is the point;
  treat the first failing run as the true baseline.

### 0.2 — No CI gate · S · HIGH · ✅ DONE
- `.github/workflows/release.yml` triggers only on version tags and verifies
  only `hexe --help`. Nothing checks a commit before it lands on `develop`/`main`.
- Fix: add a push/PR workflow (`ci.yml`) running `zig build test` and
  `zig fmt --check src build.zig`, reusing `mlugg/setup-zig@v2` pinned to the
  toolchain version. Make it required on PRs. It will initially fail on any
  unformatted files and on the tests re-enabled by 0.1 — surface, then fix.

---

## Phase 1 — Close the robustness holes (1–2 weeks) — mostly ✅

**Status:** 1.1, 1.3, 1.4, 1.5, 1.6, 1.7 done; 1.8/1.2 partial (safe slices
landed, hot-path/e2e remainder deferred); 1.9 documented + opt-out. Test count
rose to 247 (from 110 at the start) with new POD buffering + pod_protocol
framing coverage. Remaining hot-path work (main-client write queue) is tracked
as a follow-up pending a SES+POD e2e harness.

Before touching POD or the reattach path, write characterization tests for them
(1.8) — they are the highest-churn untested code and the home of the recent
bug class.

### 1.1 — Single-instance daemon lock · S–M · HIGH · ✅ DONE
- Two `ses daemon`s can bind the same runtime dir and split session state, so
  reattach-by-name fails (reproduced live). No `flock`/pidfile exists; the
  `ipc.zig` connect-probe is a TOCTOU race.
- Fix: acquire an exclusive `flock` (or `O_CREAT|O_EXCL` pidfile) on a
  per-instance lock path in the runtime dir before binding the socket; if held
  by a live pid, connect to it instead of starting a second daemon.

### 1.2 — POD blocking I/O freezes the shell · M · HIGH · ◑ PARTIAL (observer path done; main-client queue deferred)
- The POD makes the PTY master non-blocking, then leaves observer and client
  fds in blocking mode and writes to them from the hot PTY path
  (`pod/main.zig:1069,1101,1174`; `ipc.zig:253` is an unbounded blocking
  `send`). A stuck `hexe pod observe` client fills its socket buffer and the
  next `writeFrame` blocks the whole pane's event loop.
- Fix: keep observer/client fds non-blocking; on `EAGAIN` buffer into a bounded
  per-connection queue drained by a write-readiness watcher (mirror the
  existing `pty_wbuf` drain); drop/disconnect a connection whose queue overflows
  rather than blocking. This mirrors the SES-side blocking-read hardening.

### 1.3 — Isolation error log is an unsafe /tmp path · S · HIGH · ✅ DONE
- On isolation failure the child does
  `createFileAbsolute("/tmp/hexe-isolation-error.log", …)` — a fixed,
  world-shared path opened create-truncate with symlink following (CWE-59/377).
  A pre-planted symlink there is clobbered when a victim pod fails
  (`pty.zig:124`).
- Fix: write diagnostics to the per-user runtime dir with a pid/uuid-scoped
  name opened `O_CREAT|O_EXCL|O_NOFOLLOW`, or emit to the pod's existing log
  channel.

### 1.4 — voidbox cgroup limits applied after joining the cgroup · S · MED · ✅ DONE
- `isolation_voidbox.zig:91-114` writes `cgroup.procs` (moving the child in)
  *before* `memory.max`/`pids.max`/`cpu.max`, leaving a startup window with no
  caps. `isolation.zig:362-391` does it in the correct order — the two backends
  disagree.
- Fix: reorder to create the cgroup, write all `*.max` limits, then write
  `cgroup.procs` last — matching `isolation.zig`.

### 1.5 — OSC7 cwd can be a dangling slice · S · HIGH · ✅ DONE
- `extractPath` returns a slice into the scan buffer; a second OSC7 in the same
  `feed()` overwrites that buffer before the caller reads it, so the pane's
  cached cwd (written to the `.meta` sidecar and the SES uplink) becomes garbage
  (`pod/buffering.zig:126-155`, read in `pod/main.zig:1320`).
- Fix: have `feed` copy the extracted path into owned scratch (or return
  offset+len the caller dupes immediately) rather than a live slice into the
  reused buffer.

### 1.6 — `.meta` sidecar rewritten non-atomically · S · MED · ✅ DONE
- `writePodMetaSidecar` truncates then does two `writeAll`s
  (`pod/main.zig:242-245`). A discovery scan reading in that window sees an
  empty/partial file and a live pane flaps out of listings.
- Fix: write to `path + ".tmp"` then `rename` into place (same pattern already
  used for `ses_state.json`).

### 1.7 — Attached sessions are not persisted · M · HIGH · ✅ DONE
- `persist.zig` writes only `detached_sessions` + panes. A daemon crash while a
  session is attached loses the session layout; only sticky floats recover via
  pwd+key.
- Fix: persist attached sessions' canonical snapshot too (or periodically
  snapshot each attached client's session state), so recovery reconstructs the
  layout, not just loose panes.

### 1.8 — Characterization tests for POD + reattach · M · HIGH (do before 1.2/1.7) · ◑ PARTIAL (POD buffering + framing done; reattach/e2e deferred)
- The POD process (`pod/main.zig`, 1383 lines, highest churn) has 0 running
  tests; the frontend reattach machinery (`state_reattach.zig`, 1409 lines) has
  0 tests; there is no end-to-end test spanning SES+POD+frontend. The one smoke
  tool (`src/tools/session_protocol_smoke.zig`) needs a pre-running daemon and
  is not in `test_step`.
- Fix: add a `pod` test target and characterize `buffering.zig` (ring wrap,
  password-mode clear, the OSC7 case in 1.5) and `uplink.zig` framing against
  malformed input; extract the reattach snapshot→view reconciliation into a pure
  function and characterize it against the scenarios `state_test.zig` already
  covers server-side; promote the smoke tool into a self-bootstrapping e2e that
  spawns its own SES+POD on a throwaway `HEXE_INSTANCE`.

### 1.9 — Project `.hexe.lua` command trust gate · M · MED · ✅ LEDGER DONE
- Session `on_start`/`on_stop` strings from an in-repo `.hexe.lua` were shelled
  out on session open (the direnv auto-trust problem). Pure config was already
  mitigated (Lua sandboxed, no `io`/`os`), but the shell-hook path was not.
- **Fix (landed):** a content-hash trust ledger (`core/trust.zig`): a project
  `.hexe.lua`'s `on_start` hooks only run once its SHA-256 is recorded via
  `hexe allow [path]`. Editing the file invalidates trust (hash changes → TOFU),
  so a repo can't swap in new commands after being allowed. The gate lives in
  `applySessionConfig` keyed by the config's `source_path`; `HEXE_NO_PROJECT_COMMANDS`
  is a hard opt-out, `HEXE_TRUST_ALL_PROJECTS` a CI/dev escape hatch. Ledger at
  `$XDG_STATE_HOME/hexe/trust` (overridable via `$HEXE_TRUST_LEDGER`). Unit-tested
  (allow → trusted → edit → untrusted) and driven end-to-end through the real
  `hexe allow` CLI. Remaining (documented follow-up): per-pane `command=` fields
  are a separate, more disruptive gate — not yet covered; on_stop execution is
  not wired in the frontend so it inherits the same gate when it is.

---

## Phase 2 — Pay down the architecture that taxes everything (2–4 weeks) — started

**Status:** the safe reuse/consolidation wins landed — the 5 divergent
split-direction parsers are now one `session_model.isVerticalSplitDir` (fixing
the real bug where `dir="h"` decoded as vertical in snapshot JSON), and the
duplicated `setNonBlocking`/`O_NONBLOCK` copies collapsed to `ipc.setNonBlocking`.
The larger items below (wire registry, god-object splits, watcher unify) are
substantial refactors of concurrency-critical code, and **2.2 is a decision, not
a mechanical change** — those are the remaining bulk of Phase 2.

### 2.1 — Wire-message registry (do first — unblocks the rest) · M · HIGH · ◑ ENFORCEMENT DONE
- Adding one wire message is a ~9-file lockstep edit with no compiler
  enforcement the sites agree; a half-wired message fails at runtime
  (`else =>` error-reply), not build time. 75 message types, 22 files reference
  `msg_type`.
- **Core value delivered:** both SES dispatch switches (`handleBinaryCtlMessage`,
  `handleCliRequest`) are now **exhaustive over named MsgTypes** — the `else =>`
  arms were replaced with an explicit enumeration of every message-not-on-that-
  channel plus a `_ =>` for genuinely-unknown wire values (`MsgType` is
  non-exhaustive). A new MsgType is now a **compile error** in both switches
  until it's categorized, which is exactly the "half-wired message fails at build
  time not runtime" guarantee. Behavior-preserving (grouped arms replicate the
  former `else`); build + tests + daemon smoke green.
- **Remaining (larger rewrite):** driving *encode/decode + client send* from a
  single comptime table (so framing lives in one place) is the bigger additive
  refactor on top of this enforcement — deferred, no incremental payoff until
  fully wired.

### 2.2 — Decide the `frontend_view` fork · M · HIGH (strategic) · ✅ DECIDED: PARK

Resolved in favor of **park**: `refreshFrontendView` is now a documented no-op, so
the `SessionView` mirror is never populated. Every mutation site was already
null-guarded (inert now), the two readers fall back to `state.view`, and the
per-refresh rebuild cost is gone. The `SessionView` type stays in the tree
dormant — when a real second frontend lands, this becomes populate + a renderer
that reads it (the "commit" path). Verified no behavioral change (suite green).
- `state.frontend_view` (a `frontend_core.SessionView`) is mutated in ~23
  lockstep sites but has zero reads in any render/statusbar file. `frontend_core/`
  (3600 lines) is built and unit-tested, but its only consumers — the web and
  syslink hosts — are ~110-line stubs with no renderer or transport. It is
  currently pure carrying cost: every state mutation must update two projections
  or silently diverge.
- Decision (pick one):
  - **Commit** — make the terminal renderer read from `frontend_view` and retire
    `state.view`, completing the host-adapter refactor so the duplication becomes
    a real seam; gate the switch on the CWD-float regression tests.
  - **Park** — stop mutating the mirror in 23 sites until the first host that
    actually renders from it exists.

### 2.3 — Split the god objects along their clean seams · L · HIGH · ✅ HANDLER LAYER COMPLETE

`server.zig` reduced **5080 → 2421 lines (−52%)** across 9 extraction rounds.
**Every** CTL message handler is now in a focused sibling file; what remains in
server.zig is the dispatch table, event loop, watcher lifecycle, VT routing, and
connection/helper machinery — the genuine server core. Handler files:
`server_session_handlers` · `server_pod_event_handlers` · `server_pane_meta_handlers`
· `server_pane_lifecycle_handlers` · `server_reattach_handlers` ·
`server_cli_layout_handlers` · `server_reporting_handlers` ·
`server_listing_handlers` · `server_register_handler`. Each extraction was a pure
move verified by the full suite + daemon smoke; new characterization tests
(renameClientSessionTab state + handler paths) were added along the way.
Cohesive CTL-handler groups moved into sibling files, each a pure move verified
by the full suite + daemon smoke:
- `server_session_handlers.zig` — 8 session-mutation handlers
- `server_pod_event_handlers.zig` — 3 channel-④ POD event handlers
- `server_pane_meta_handlers.zig` — 3 MUX→SES pane-metadata syncs
- `server_pane_lifecycle_handlers.zig` — 7 create/kill/sticky/orphan/adopt handlers
- `server_reattach_handlers.zig` — detach/reattach/disconnect (+ completeReattach)
- `server_cli_layout_handlers.zig` — kill/clear/get-layout/apply-layout/get-state

Method: promote the shared helpers each group calls to `pub`, move the handlers
as free functions taking `*Server` (circular import via `@import("server.zig")`),
rewrite dispatch + in-file test call-sites. Gotchas encountered and handled:
helpers that physically fell inside an extracted range (completeReattach — kept
with its group; pushClientSessionSnapshot — a shared helper, moved back to
server.zig). What remains in server.zig is largely the core event loop, watcher
lifecycle, and dispatch — which belong there. Further handler extraction
(Status, PaneInfo, FloatResult, Exited) follows the identical proven procedure.
- `server.zig` (5036 lines): watcher lifecycle + VT byte-splicing + 30-case CTL
  dispatch + reattach/detach + 900 lines of status-JSON in one struct. Split into
  `ctl_handlers.zig`, `vt_routing.zig` (see 2.4), `watchers.zig`,
  `status_export.zig`; `Server` becomes a thin owner of maps + loop wiring.
- `frontend_client.zig` (2631 → 1550 lines, −41%): ✅ SPLIT DONE. Four mixin
  siblings, all free functions taking `*SesClient` re-exported via `pub const`
  aliases (call sites unchanged, compiler-enforced; green build + full suite +
  fmt + ReleaseSafe). `ses_client_queries.zig` (pane_info read-queries: aux/
  name/existence-probe/snapshot) joined the three below. What remains in
  `frontend_client` is connection/transport lifecycle, register, reattach/detach/
  listSessions, adopt/sticky, and the result types — a coherent connection core.
  - `ses_client_responses.zig` — the pending sync/async response store (queue
    helpers). Zero helper promotions (Zig struct fields are cross-file
    accessible).
  - `ses_client_commands.zig` — session-mutation + pane-metadata fire-and-ack
    CTL senders. Promoted the shared request/ack helpers to `pub`.
  - `ses_client_reads.zig` — the ~570-line synchronous-response reader cluster
    (the interleaved-push-tolerant machinery that is the home of the float-loss
    bug class), moved VERBATIM (script-cut, `zig fmt`-normalized) so behavior is
    provably unchanged. Promoted the reader helpers + `PaneInfoRead`/`PaneCwdRead`
    (+ their methods) + the two timeout consts to `pub`.
  Remaining in `frontend_client`: connection/transport lifecycle, register, the
  query/reader *consumers* (getPaneInfoSnapshot, adoptPane, reattach/detach/
  listSessions, etc.), and the result types — a coherent remaining core.
- `statusbar.zig` (2717 → 2654 lines): ◑ the frontend-neutral Lua-eval
  primitives (`beginLuaEval`/`endLuaEval`/`callbackIdFromCode` + `HEXE_LUA_TRACE`)
  moved to `statusbar_eval.zig`. The when/command eval ENGINE + per-frame caches
  stay: they are anchored to `populateLuaContext` (deeply `State`/`Pane`-coupled),
  so extracting them needs a design change (inject context-population as a
  callback), not a mechanical move.
- Extended the split to two more god objects along the module's own patterns:
  `com.zig` (1944 → 1476) — layout save/load/list → `com_layout.zig` (the
  command-per-file re-export pattern com.zig already uses); `api_bridge.zig`
  (2666 → 1964, −26%) — three sibling modules carved off via a shared recipe
  (new module imports api_bridge for shared bridge helpers, which are promoted to
  `pub`; the group's external entry point is re-exported so callers are
  unchanged; circular import is fine in Zig): `api_bridge_record.zig` (record
  C-API glue), `api_bridge_layout.zig` (layout-tree parsers), `api_bridge_float.zig`
  (float visual-options parsers). What remains is the entangled segment-parser
  core (`parseSegmentAtPath`/`parseSegment`/`parseSegmentDef`) that shares a wide
  helper surface — a heavier extraction, not yet done.

### 2.4 — `vt_routing.zig` decoy + mux→pod backpressure · M · HIGH · ✅ BACKPRESSURE LANDED (move deferred)
- **Fix (landed):** the real gap — **mux→pod wrote synchronously with no
  backpressure** (`wire.writeAll` + `spliceData` both blocked the whole SES
  event loop on `waitWritableTimeout` when a wedged POD stopped draining its VT
  input) — is closed. `routeMuxToPod` now reads the full frame from the mux, then
  hands it to a bounded per-POD write queue (`store.PodVtQueue`, keyed by
  pod_vt_fd) drained by non-blocking writes on the periodic tick, symmetric with
  the existing pod→mux `MuxVtQueue`. Input is lossless: a frame is always
  accepted onto an empty queue (a single large paste is never undeliverable) and
  overflow drops the whole POD connection (reconnected via backlog-replay if the
  pod is alive) rather than dropping keystrokes or blocking. The queue is
  **store-owned** so it is freed at every fd-close site through `noteClosedFd`
  (plus an explicit free on the routing-drop path), preventing a reused fd number
  from inheriting stale input bytes. `spliceData` (now dead) removed. New
  characterization tests: in-order delivery + backlog-only backpressure + close
  frees the queue. Green in Debug + ReleaseSafe + fmt.
- **Remaining (deferred, presentation only):** physically relocating
  `routePodToMux`/`routeMuxToPod`/`MuxVtQueue` out of `server.zig` into
  `vt_routing.zig` would require promoting ~10 private helpers + the queue type
  to `pub` and moving the hottest concurrency code for zero behavioral payoff —
  the same "presentation only" tail deferred in 2.5. The backpressure asymmetry
  the move was meant to surface is already fixed.

### 2.5 — Unify CTL/VT watcher lifecycle · M · HIGH · ✅ DESTRUCTION STRATEGY UNIFIED (+ latent UAF fixed)
- Original state: `disarmCtlWatcher` defers destruction to `deferred_destroy_ctl`
  (flushed at a safe loop point) because "xev still holds refs after disarm —
  freeing immediately is a UAF in ReleaseFast"; but the VT path
  (`processPendingVtCloses`) freed watchers **immediately**, and the parallel
  `deferred_destroy_vt` list existed but was never populated (dead scaffolding).
  That immediate free is the *same* ReleaseFast UAF the CTL path was written to
  avoid — a latent bug, not a safe divergence.
- **Fix (landed):** routed VT watcher destruction through the **identical**
  deferred mechanism CTL uses — a new `deferDestroyVtWatcher` appends to
  `deferred_destroy_vt`, freed by the same `flushDeferredDestroys` at the same
  safe point. VT inherits CTL's proven-safe completion-lifetime timing rather
  than inventing new timing, so it's *strictly safer* than the old immediate
  free (fixes the UAF; the code's existing "callback already returned .disarm →
  no CQE pending" invariant is preserved, so no new double-free vs the
  stale-CQE orphan path in `vtWatcherCallback`). Both channels now share one
  destruction strategy — 2.5's core goal.
- The close-*enqueue* path was already unified (`queuePendingClose`). Verified in
  Debug **and ReleaseSafe** (where the UAF manifests) + tests + daemon smoke.
- Remaining (cosmetic, optional): collapsing `CtlWatcher`/`VtWatcher` into one
  generic `Watcher(kind)` type — the destruction *strategy* (the actual hazard)
  is now unified; the struct merge is presentation only. The per-channel *drain*
  bodies stay separate by design (they do genuinely different teardown).

### 2.6 — Config schema consolidation · M · MED · ◑ INVESTIGATED (decision resolved; remaining merge is cross-abstraction, deferred)
- **Decision resolved:** `config_v2.zig` is a *deliberate target schema*, not
  accidental duplication — its own header says "This is the target AST for
  `hexe.setup`… new parsing work should land here." It's the migration
  destination (validation model + `LuaShapeSummary`, consumed by
  `hexe config validate`). So it stays; do not collapse it away.
- **The "triplication" is narrower than it looked.** `api_bridge.parseSegment`
  is already a one-line delegate to `parseSegmentAtPath` (no dup there). The
  genuine remaining overlap is between `config.zig`'s parser (written against the
  `LuaRuntime` wrapper — `runtime.fieldType`/`pushTable`/`getString`) and
  api_bridge's (raw zlua `lua.getField(idx,…)`). They target the same
  `config.Segment` but through different Lua-access layers, and may have subtly
  diverged (the plan's original worry). `parseSegmentDef` is a third shape but
  produces a *different* type (`ShpConfigBuilder.SegmentDef`), so it doesn't fold
  in trivially.
- **Why deferred:** merging the two would mean unifying the Lua-access layer (or
  bridging relative-index `runtime` calls to explicit-idx `lua` calls) on the
  core, well-tested config path — a behavior-sensitive refactor, not a mechanical
  win. Right move is a dedicated pass with characterization tests pinning the
  current field-by-field behavior first, not a blind collapse.

---

## Phase 3 — Features (ongoing, independent increments)

### 3.1 — Remote attach · S–M · HIGH · ✅ ATTACH WIRED end-to-end (needs a live host to prove the handshake)
- The full path is present and building: `terminal new`/`attach` expose
  `--remote host:port`, `--user/-u`, `--identity/-i` (`app.zig:497-510`), parsed
  into `RemoteConnectArgs` at dispatch and threaded through
  `buildTerminalConnectOptions` → `FrontendConnectOptions` (host/port split, user
  from flag-or-`$USER`, identity from flag-or-`~/.ssh/id_ed25519`) →
  `resolveTransport` (now builds a `.liblink` transport when `remote_host` is set,
  no longer a stub) → `SesClient.connect` (`.liblink => connectLiblink`, which does
  the liblink connect + `authenticateClient` + preconnected ctl/vt wiring). The
  hard part (transport + auth) was already done; the CLI/threading is now done
  too. What's left is a **live-host spike** to prove one round-trip — not
  codeable headlessly.
- Remaining minor gap: `sendNotify`'s `.liblink` branch (remote `hexe notify`)
  still returns `error.UnsupportedTransport` (fails cleanly). It needs a
  lightweight CLI-channel-over-liblink (the existing `connect()` sets up the
  heavier frontend ctl/vt channels + register); deferred as niche + unverifiable.

### 3.2 — Web/syslink: build or be honest · S (honesty) / L (build)
- The web/syslink hosts advertise `pixel_render`/`clipboard`/`remote_transport`
  capabilities with nothing behind them; the `serve` commands only print snapshot
  summaries. Either build the web gateway (the `SessionView` diff model is set up
  for exactly this — a WS server streaming diffs to a canvas renderer) or
  right-size the capability flags and rename `serve`→`inspect`.

### 3.3 — Copy-mode + scrollback search · M · ✅ COPY-MODE DONE (search = follow-up)
- **Copy-mode** ✅ — `copy.enter` action enters a modal keyboard cursor over the
  focused pane (hjkl/arrows move, `v` select, `y`/Enter yank to clipboard,
  Esc/`q` exit). It drives the shared `mouse_selection` begin/update/finish with
  local pane coords — the exact scroll-aware machinery the mouse path uses — and
  yanks via `renderer.vx.copyToSystemClipboard`, so text extraction is the same
  correct code. A reverse-video cell renders the cursor. Input is captured in
  `loop_input` like the tab-rename editor. Config validates; action-mapping test.
- **Scrollback text search** ✅ DONE. `search.enter` action opens a modal query
  over the focused pane's full scrollback via ghostty's `search.Screen`
  (ScreenSearch): type the needle (a vim-style `/query` bar renders on the bottom
  row), `Enter` runs `searchAll` and jumps to the first match, `n`/`N` navigate
  (each scrolls the viewport to the match's tracked pin, showing `[i/N]`), `Esc`
  exits. Implemented as a self-contained `pane_search.zig` state machine so its
  lifetime surface (it holds a `*Screen` + tracked pins while in the results
  phase) is isolated; it is torn down before any pane-screen free (pane_exited
  and reattach guards, plus `State.deinit` ordered before `view.deinit`), and
  local closes can't fire because search captures all input. The search CORE is
  unit-tested headlessly against a real constructed `core.VT` screen (match
  count + navigation + utf8 query editing). Config validates; a HostSurfaceAction
  mapping test was added; exposed as `hexe.action.search.enter()`.
  Every on-screen match is highlighted (yellow tint) with the current one drawn
  reverse-video on top; the visible-match ranges are cached (recomputed only on
  navigation via `ScreenSearch.matches` + `pages.pointFromPin(.viewport, …)`, not
  per render frame) and unit-tested (both matches counted visible). The `/query`
  prompt bar renders one codepoint per cell so multibyte queries show their
  glyph. No follow-ups outstanding.

### 3.4 — Table-stakes mux actions (each independent) · M each
- **Pane zoom/maximize** — ✅ DONE. `pane.zoom` toggles the focused tiled pane
  to full tab bounds (reusing `pane.resize` → VT + POD reflow), renders only that
  pane (borders suppressed), and auto-clears on tab switch (black-screen guard),
  focus move, split, and pane close. Local view state — resets on reattach.
  Config validates; action-mapping test added.
- **Interactive pane-sync/broadcast** — ✅ DONE. `pane.sync_toggle` action
  broadcasts keystrokes to every split pane in the active tab (with an ON/OFF
  notification). Config validates; action-mapping unit test added.
- **Session/tab rename** — ✅ DONE (tab rename). `tab.rename` action opens an
  inline editor; keystrokes update the tab bar live via the projection, Enter
  persists through a new `session_rename_tab` wire op (SES updates the canonical
  snapshot + markDirty, so it survives reattach), Esc restores the original.
  Config validates; action-mapping test added. (`hexe session rename` CLI for
  detached sessions is the remaining sibling.)
- **Config hot-reload** — ✅ DONE. `config.reload` action re-reads the Lua config
  and hot-swaps `state.config` (keybinds/segments/borders all read it live). The
  "dangling Lua-runtime pointer" hazard is handled by calling the existing
  `statusbar.deinitThreadlocals()` — which clears every cache holding a runtime
  ref — before freeing the old config; an audit confirmed no pane/float caches a
  `config`/`FloatDef` pointer. Parse errors keep the current config (no clobber
  with defaults). Config validates; action-mapping test added.

---

## Dependency notes

- Phase 0 gates everything: don't refactor (Phase 2) or touch POD/reattach
  (1.2/1.7) without the tests running.
- 1.8 (characterization tests) precedes 1.2/1.7 (the changes they protect).
- 2.1 (wire registry) precedes 2.3/2.4 (they touch the same dispatch surface)
  and lowers the cost of 3.1/3.2.
- 2.2 (the `frontend_view` decision) is the fork in the road for the whole
  multi-frontend vision (3.2) — decide before investing further in either.

## Not audited deeply

ghostty VT-integration internals, rendering micro-performance, and the liblink
wire protocol details got a lighter pass than the subsystems above.
