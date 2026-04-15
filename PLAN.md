# Hexe Hardening Plan

Replaces the prior UI/SES separation plan (which is complete).

This plan consolidates findings from a five-agent audit (dead code, stubs,
implementation bugs, architecture, security) into a prioritized, sequenced work
list. Each phase is independently shippable — don't merge later phases before
earlier ones land.

Completion is not claimed until every checkbox in a phase is done AND the
phase's exit criteria hold.

---

## Phase 1 — Memory-safety fixes (mechanical, shippable as one PR)

Small, isolated fixes for confirmed memory-safety bugs. No design work, no
refactors.

- [x] **P1.1** — `src/core/ipc.zig:147` — `Client.connect()` now clamps the
      socket path copy via `@min(path.len, addr.path.len - 1)`, matching the
      pattern at `:40` and `:77`.
- [~] **P1.2** — `src/modules/pod/buffering.zig:40-47` — **false positive**.
      Line 32 early-returns when `data.len >= self.buf.len`, so the remaining
      path is reached only with `data.len < cap`. That invariant makes
      `drop = self.len + data.len - cap < self.len`, so the `self.len -= drop`
      at line 47 cannot underflow. Skipped.
- [x] **P1.3** — `src/frontends/terminal/state.zig:272` — `stdin_tail_len`
      widened from `u8` to `u16`. The `@intCast(tail.len)` at
      `loop_input.zig:130` is bounded by `stdin_tail.len == 256`, which fits.
- [x] **P1.4** — `src/core/pty.zig:272` — `closeExtraFds` fallback now walks
      up to `getrlimit(RLIMIT_NOFILE).cur` instead of 1024. `close_range` is
      still the primary path.

**Exit criteria:** `zig build` clean. ✅

---

## Phase 2 — Silent-failure cleanup (one-shot refactor)

Retire the ~250 `catch {}` patterns on wire writes by routing them through a
single helper that logs and marks the client connection broken.

- [x] **P2.1** — Added `Server.replyOrClose` and `Server.replyOrCloseWithTrail`
      helpers in `src/modules/session/server.zig`. Both log at warn level and
      queue the fd for close via the existing `queueCtlClose` pending path,
      which triggers `removeClientWithWatcherCleanup` on the next poll tick.
- [~] **P2.2** — No separate "broken" flag needed. `queueCtlClose` already
      feeds into the unified cleanup path used by EPIPE/ECONNRESET handling,
      so we reuse it directly. Rejected as redundant.
- [x] **P2.3** — All 50 `wire.writeControl(...) catch {}` sites in
      `server.zig` migrated to `self.replyOrClose(...)`.
- [x] **P2.4** — All 18 `wire.writeControlWithTrail(...) catch {}` sites in
      `server.zig` migrated to `self.replyOrCloseWithTrail(...)`. Also
      migrated the one `writeControlMsg(...) catch {}` at `:2283` inline
      (no helper added for a single call site).
- [x] **P2.5** — `src/core/frontend_client.zig` had two swallows: the
      shutdown `disconnect` notify (now logs at debug level — there's
      nothing else to do mid-shutdown) and `update_pane_aux` (now logs and
      nulls `self.ctl_fd` so subsequent ops fail fast).
      `frontend_liblink_transport.zig` has no `wire.writeControl.*catch {}`
      patterns.

**Exit criteria:** `grep -rn "wire\.writeControl.*catch {}" src/` returns
zero. ✅ Build clean. ✅

---

## Phase 3 — Protocol input validation (payload caps)

Every control-message read path must enforce `wire.MAX_PAYLOAD_LEN` before
allocating.

- [ ] **P3.1** — Add `wire.readControlFrame(fd, allocator, max_payload)`
      that: reads the header, validates `payload_len <= max_payload`, reads
      the payload into a bounded allocation, returns
      `{ header, payload: []u8 }`. All call sites in SES and frontend go
      through this.
- [ ] **P3.2** — Replace ad-hoc reads in `src/modules/session/server.zig`
      (the binary control loop) and `src/core/frontend_client.zig` with
      `readControlFrame`.
- [ ] **P3.3** — Add a read timeout at the frame level (not just
      `VT_ROUTE_IO_TIMEOUT_MS`) so a client can't stall SES by advertising a
      payload then never sending it. Reuse the existing timeout constant or
      add `CONTROL_READ_TIMEOUT_MS`.
- [ ] **P3.4** — Persistence hardening (same "validate before allocate"
      principle):
      - `src/modules/session/persist.zig:94-200` — cap each string field
        (`sticky_pwd`, `pod_socket_path`, names) at 4KB; skip the session
        entry on overflow with a log warning.
      - `src/modules/session/txlog.zig:115-120` — cap total replay at 10MB;
        truncate the log and warn on overflow.
      - Add parent-directory `fsync` after `renameAbsolute` in `persist.zig`.

**Exit criteria:** a fuzz test (or hand-crafted malicious JSON session file)
can't OOM SES on startup. A stalled client can't hang the poll loop.

---

## Phase 4 — Privacy fixes (file perms + password mode)

- [ ] **P4.1** — `src/modules/pod/main.zig:238` — pod metadata sidecar
      created with `0o600`.
- [ ] **P4.2** — `src/core/recording/asciicast.zig:21` — recording files
      created with `0o600`.
- [ ] **P4.3** — `src/modules/pod/buffering.zig` — gate ring-buffer appends
      on `pane.flags.password_input`. When set, don't capture the input (or
      the echo back from the shell) into the backlog. Same guard in
      `src/core/recording/asciicast.zig` for recording.
- [ ] **P4.4** — Audit `state.overlays.recordKeypress` call sites
      (`src/frontends/terminal/loop_input_keys.zig:26` already checks it for
      keycast — verify the same guard is applied everywhere user input could
      be observed).

**Exit criteria:** typing `sudo <password>` into a recorded pane leaves no
trace in the asciicast or session backlog. New asciicast and pod metadata
files are `-rw-------`.

---

## Phase 5 — Peer authentication for frontends

- [ ] **P5.1** — Extract `verifyPeerCredentials` from
      `src/modules/pod/main.zig:23-37` into `src/core/ipc.zig` as a reusable
      helper.
- [ ] **P5.2** — Call it from every `accept()` in
      `src/modules/session/server.zig` (`dispatchNewConnection`, etc.). Reject
      connections whose peer UID differs from the SES process UID.
- [ ] **P5.3** — Add an env override `HEXE_ALLOW_CROSS_UID=1` for test setups
      that legitimately need it (don't document it prominently).

**Exit criteria:** a sibling process running as a different UID cannot
`register` or `reattach` against our SES socket.

---

## Phase 6 — Clean up stubs, dead code, and half-wired features

Small individually but they add up to significant clarity improvements.

- [ ] **P6.1** — Delete or wire up:
      - `src/modules/session/main.zig:589` — stub `printLayoutTree()` with no
        callers. Delete.
      - `src/frontends/terminal/mouse_selection.zig:29` — `EdgeScroll.up/down`
        are set but never consumed. Either finish edge scrolling or drop the
        enum variants.
      - `src/frontends/terminal/keybinds.zig:694` — `.hold => unreachable`.
        Replace with an explicit no-op + comment, or implement hold handling.
      - `src/modules/session/state.zig:2016` — comment references a deleted
        function. Remove the stale reference.
- [ ] **P6.2** — Allocator parameter cleanup. Four functions take an
      `Allocator` they never use (inline page_allocator because of fork
      issues). Either:
      - delete the parameter from all four signatures, OR
      - honor the passed allocator and document the fork invariant.
      Files: `src/modules/session/main.zig:378`, `persist.zig:94`,
      `server.zig:74`, `state.zig:500`. Also remove `listStatus(full_mode)`
      parameter — it's always treated as `true`.
- [ ] **P6.3** — Unhandled `MsgType` variants in `src/core/wire.zig`:
      `query_state`, `title_changed`, `pod_register`, `shp_prompt_req/resp`.
      Audit each:
      - if a handler is planned, add a TODO with a tracking reference;
      - if not, delete the enum variant and corresponding constants.
      Don't leave half-defined protocol surface.
- [ ] **P6.4** — TODO resolution in `src/core/api_bridge.zig`:
      - `:1169` — `hexe_mux_float_define` drops size/position/padding/
        attributes/color/style. Wire each field from the Lua table into
        `FloatDef`.
      - `:1317` — `hexe_mux_splits_setup` skips split junction styling.
        Parse the style subtable into `SplitStyle`.
- [ ] **P6.5** — `src/core/config_builder.zig:45` — `ConfigBuilder.build()`
      returns an empty `Config`. Primary config still works via `parseConfig`,
      but `ses`/`shp`/`pop` section builders are orphaned. Either:
      - delete the `ses`/`shp`/`pop` builder scaffolding entirely, OR
      - implement `build()` so their accumulated state becomes runtime
        config and `applyBuilderConfig` invokes it.
      I recommend deleting for now; bring back when those config surfaces
      are actually needed.

**Exit criteria:** `grep -rn "TODO\|FIXME\|XXX" src/ | wc -l` is materially
lower (track the before/after numbers in the PR description). No public
symbols with zero call sites.

---

## Phase 7 — Test coverage (blocking for Phase 8)

Before touching architecture, lay down a safety net so refactors don't break
silently.

- [ ] **P7.1** — Wire protocol round-trip test.
      `src/core/wire_test.zig` — for every `MsgType` enum variant, encode a
      representative payload and decode it; assert equality. This catches
      encoding regressions and forces every new `MsgType` to have a test.
- [ ] **P7.2** — Input encoding matrix test.
      `src/frontends/terminal/keybinds_test.zig` — for each `BindKeyKind`
      (`.char`, `.space`, `.up`/`.down`/`.left`/`.right`, and a few special
      keys) × each mod combination (none, shift, ctrl, alt, ctrl+alt), assert
      the exact bytes that `forwardKeyToPaneWithText` would produce against
      a VT in legacy mode AND in kitty-mode-with-report-all. This is the
      test that would have caught the space bug we just fixed.
- [ ] **P7.3** — Snapshot mutation tests.
      `src/modules/session/state_test.zig` — expand with test cases for
      `removePaneFromSessionSnapshot` covering: last pane in a tab, last pane
      in session, pane inside a split tree, pane that is a float, orphan
      adoption on reattach. Every code path through that 100-line function
      needs an assertion.
- [ ] **P7.4** — TxLog corruption / recovery test.
      Write a valid log, truncate mid-entry, assert `readAll` returns the
      prefix that was complete and skips the trailing partial entry without
      crashing or OOMing.

**Exit criteria:** `zig build test` runs all four suites and they pass. The
input encoding test includes an explicit case for bare space (regression
test for the space-key bug).

---

## Phase 8 — Architectural fixes (requires Phase 7 safety net)

These are the cross-cutting fixes that need tests in place first.

- [ ] **P8.1** — Kill state duplication in `SessionProjection`.
      `src/core/session_projection.zig` — remove the shadow maps
      (`local_floats`, `pane_shell`, `pane_proc`, `pane_names`,
      `active_float_uuid`, `focused_pane_uuid`, `active_tab`). Make every
      getter compute derived state from `attached_snapshot` on demand. Adjust
      `syncFloatState` to be a single write into the snapshot rather than 2–3
      parallel writes.
- [ ] **P8.2** — Enforce pane ownership in `session_*` handlers.
      `src/modules/session/server.zig` — every handler that takes a
      `pane_uuid` or `tab_uuid` must look it up via
      `client.session_panes.contains(uuid)` (or equivalent) before mutating.
      Reject with `error` reply on mismatch. Include test coverage for the
      rejection path.
- [ ] **P8.3** — Split `SesState`.
      `src/modules/session/state.zig` — extract:
      - `SessionStore` (panes, clients, detached_sessions, session ownership)
      - `Persistence` (txlog + session file I/O)
      - `PollingState` (pending_poll_fds, pending_remove_poll_fds)
      - `SessionLocks` (mutation serialization)
      Keep `SesState` as a thin composition struct that owns the four
      substructs. Don't change external APIs in this phase; only internal
      structure.

**Exit criteria:** `SessionProjection` has no fields that shadow
`attached_snapshot`. Every `session_*` handler has a test proving it rejects
a pane_uuid the client doesn't own. `SesState` is < 150 LOC after the split.

---

## Out of scope (for now)

These showed up in the audit but aren't on the plan. Revisit after Phase 8:

- **Liblink transport polishing** — the remote transport is untested; either
  drop it or write an integration test harness. Not urgent until a user
  actually needs remote attach.
- **Config hot reload** — nice-to-have but requires runtime config diffing
  and keybind rebuild. Too big for this pass.
- **`MuxConfigBuilder` TODO items** (`:802` empty `hx.shp.segment` table) —
  belongs to a separate "Lua API completeness" pass once `shp` is actually
  consumed anywhere.
- **Orphan PTY reaping on SES crash** — needs a supervisor model. Deferrable.
- **Landlock isolation rules** — the constants are defined but unused.
  They're load-bearing for future work; leave them.

---

## Working order

1. Phase 1 (memory safety) — can ship today, no dependencies.
2. Phase 2 (silent failure cleanup) — ship after Phase 1 so broken-client
   handling doesn't collide with the ipc fix.
3. Phase 3 (input validation) — independent of Phase 2; can be parallel if
   someone else is on P2.
4. Phase 4 (privacy) — independent; small PR on its own.
5. Phase 5 (peer auth) — small, independent.
6. Phase 6 (dead code / stubs) — independent; fine to interleave as cleanup
   commits alongside earlier phases.
7. Phase 7 (tests) — must be done before Phase 8.
8. Phase 8 (architecture) — final, after the safety net is in place.

Phases 1–6 are shippable as individual PRs. Phase 7 unblocks Phase 8.
