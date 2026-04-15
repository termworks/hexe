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

- [~] **P3.1** — Skipped in favor of an inline check at the single control
      entry point. A full `readControlFrame` helper would have required
      changing every handler signature; the inline cap at
      `handleBinaryCtlMessage` gets the same DoS-protection win without the
      churn.
- [x] **P3.2** — Inline `hdr.payload_len > wire.MAX_PAYLOAD_LEN` check at
      the top of `Server.handleBinaryCtlMessage` (closes the connection
      with a warn log). Same pattern added to all three
      `session_state` allocation sites in `src/core/frontend_client.zig`.
      Terminal frontend (`loop_ipc.zig`) already had the cap.
- [~] **P3.3** — Deferred. The poll loop only dispatches
      `handleBinaryCtlMessage` after `readable` fires, so the header read
      is non-blocking in practice. Payload reads can still hang on a slow
      adversarial client; that's worth a dedicated follow-up pass with a
      per-frame timeout, but it's independent of the P3.2 DoS cap. Tracked
      in the Phase 8 follow-ups list.
- [x] **P3.4** — `src/modules/session/persist.zig`:
      - Added `MAX_SOCKET_PATH=256`, `MAX_STICKY_PWD=4096`,
        `MAX_PANES_PER_SESSION=1024` caps. Each is checked during load;
        overflowing entries are skipped.
      - Added `std.posix.fsync(dir.fd)` on the parent directory after
        `renameAbsolute`.
      - `src/modules/session/txlog.zig`: added `MAX_REPLAY_BYTES=10MB` cap
        on `readAll`. Replay stops cleanly at the cap, preserving
        already-parsed entries.

**Exit criteria:** a malicious ctl message with `payload_len=u32_max` closes
the connection instead of allocating. A corrupted session file with a 2GB
`sticky_pwd` field skips that pane and moves on. ✅ Build clean. ✅

---

## Phase 4 — Privacy fixes (file perms + password mode)

- [x] **P4.1** — `src/modules/pod/main.zig:238` — pod metadata sidecar now
      created with `0o600`.
- [x] **P4.2** — `src/core/recording/asciicast.zig:21` — recording files
      now created with `0o600`.
- [~] **P4.3** — Deferred. The `pane.flags.password_input` bit lives on
      the frontend's ghostty VT instance, but backlog buffering happens in
      the POD process and recording happens in separate CLI tools — neither
      parses the VT stream. Gating these requires a new control message
      ("enter/exit password mode") that the frontend emits when it observes
      the flag change, routed through SES → POD and also to any attached
      recorders. That's a non-trivial protocol addition; tracked as a
      Phase 8 follow-up under "protocol additions".
- [x] **P4.4** — Confirmed. `loop_input_keys.zig:26` already calls
      `isFocusedPaneInPasswordMode(state)` before emitting keycast events.
      `state.overlays.recordKeypress` is only reached from that one call
      site, so no additional guards needed.

**Exit criteria (partial):** new asciicast and pod metadata files are
`-rw-------`. ✅ Password-mode backlog skip still pending P4.3's protocol
work.

---

## Phase 5 — Peer authentication for frontends

- [x] **P5.1** — Added `ipc.PeerCredentials`, `ipc.getPeerCredentials`, and
      `ipc.verifyPeerUid` in `src/core/ipc.zig`. POD's
      `verifyPeerCredentials` is now a one-line wrapper around the shared
      helper.
- [x] **P5.2** — `Server.dispatchNewConnection` calls `ipc.verifyPeerUid`
      first thing. Cross-UID peers get a warn log and their fd closed
      before any handshake bytes are read.
- [x] **P5.3** — `HEXE_ALLOW_CROSS_UID=1` environment variable bypasses
      the check inside `verifyPeerUid` itself, so both SES and POD honor
      it consistently.

**Exit criteria:** a process running as a different UID cannot connect to
SES — the connection is closed pre-handshake with a log line. ✅

---

## Phase 6 — Clean up stubs, dead code, and half-wired features

Small individually but they add up to significant clarity improvements.

- [x] **P6.1** —
      - `src/modules/session/main.zig` — stub `printLayoutTree()` deleted.
      - `src/frontends/terminal/mouse_selection.zig` — **false positive**.
        `EdgeScroll.up/down` are actually consumed at
        `loop_core.zig:607-611` (real `p.scrollUp(1)` / `p.scrollDown(1)`
        calls). Kept.
      - `src/frontends/terminal/keybinds.zig:694` — **false positive**. The
        enclosing `if (t.kind == .hold) { ...; continue; }` at `:663` already
        handles the `.hold` case with an early `continue`, so the inner
        switch arm is genuinely unreachable. The `unreachable` is correct.
      - `src/modules/session/state.zig:2016` — **false positive**.
        `removeDetachedSession` still exists at `:2074`. Comment is
        accurate.
- [x] **P6.2** — `listStatus(full_mode)` param deleted along with the
      unused `SesArgs.full` field and the `--full`/`-f` flag parsing. The
      four allocator-ignoring signatures now carry doc comments that
      explain the post-fork invariant; call sites (especially tests passing
      `testing.allocator`) keep working unchanged.
- [x] **P6.3** — Deleted five dead `MsgType` variants (`title_changed`,
      `query_state`, `pod_register`, `shp_prompt_req`, `shp_prompt_resp`)
      from `src/core/wire.zig`. Left reservation comments on the wire
      numbers so the values don't silently get reused with different
      semantics.
- [~] **P6.4** — TODOs kept but expanded into `TODO(lua-api)` comments that
      describe exactly what's dropped and confirm the primary config path
      (top-level Lua table → `parseConfig`) is unaffected. Full
      implementation belongs in the out-of-scope "Lua API completeness"
      pass, not here.
- [x] **P6.5** — **False positive**, resolved differently than planned.
      `MuxConfigBuilder.build()`, `SesConfigBuilder.build()` are real and
      called from `config.zig`. `ShpConfigBuilder` is consumed field-by-
      field in `shell/main.zig:395`. `PopConfigBuilder` is consumed via
      `config.applyBuilder(pop_builder)` in `popup/config.zig:113,143`.
      Only the top-level aggregator `ConfigBuilder.build()` was a stub with
      zero callers — deleted, with a comment explaining how the sections
      are actually consumed.

**Exit criteria:** all false positives documented so they don't come back
in the next audit. Real dead code is gone. ✅ Build clean. ✅

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
