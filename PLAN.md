# PLAN: exactly-once input delivery across VT reconnect

> STATUS: IMPLEMENTED (commits 3a101e6 proto/v4, bb6af7e feature). All four
> phases landed and verified: 375/385 unit tests, a live exactly-once smoke
> (6 rounds racing a daemon SIGKILL against a keystroke — never lost, never
> duplicated), and the daemon-crash-keystroke minimal repro 5/5. One real
> refinement found during Phase 3 verification: the ring must be replayed on
> `backlog_end` (pod reconnected → routing ready), NOT on VT-arm — replaying
> earlier raced SES's pod re-adoption and hit "unknown pane" drops. See the
> loop_watchers `.backlog_end` arm.


## Goal / invariant
Input typed around a VT-channel reconnect — frontend slow/SIGSTOP, VT-overflow
channel drop, or daemon crash+restart — is delivered to the shell **exactly once**:
never lost, never duplicated, never reordered.

## Why the shipped fixes don't fully get there
Input flows `frontend → SES → pod → shell` over sockets with no delivery
confirmation. Two gaps remain that no local fix can close:

1. **Write-into-a-doomed-buffer**: a `write()` to a socket whose peer just died but
   isn't yet *detected* dead succeeds into a kernel buffer that is then discarded.
   The frame is marked sent and dropped from the queue — lost, unknowably.
2. **No dedup**: naively replaying un-confirmed input on reconnect duplicates
   anything that *was* delivered — worse than loss for a command like `rm`.

The only correct fix is sequence numbers + replay + dedup at the destination.

## Chosen design: per-frame `(epoch, seq)` + frontend replay ring + pod dedup
Every mux→pod input frame self-describes with `(epoch, seq)`. The **pod** is the
dedup authority (the only process that survives all three triggers). SES is a pure
conduit — the epoch travels in each frame, so SES needs no epoch-relay logic.

- **epoch**: random `u64` generated ONCE at frontend process start; stable across
  that frontend's own reconnects. A new frontend process (reattach) → new epoch.
- **seq**: monotonic `u64` per frontend, assigned when a frame is first created;
  a replayed frame keeps its ORIGINAL seq.

**Pod dedup** on an input frame `(e, s)`:
- `e != my_epoch`   → new input stream (reattach): `my_epoch=e; my_last_seq=s`, APPLY.
- `s <= my_last_seq` → duplicate (already applied): DROP.
- else              → APPLY, `my_last_seq=s`.

Resize/password frames carry the fields but the pod APPLIES them always (a stale
resize is self-correcting; simpler than dedup).

### Why this is exactly-once in each case
- **frontend slow / VT overflow drop**: SES + pod alive; frontend reconnects, replays
  ring; pod dedups by seq. ✓
- **daemon crash+restart**: frontend (epoch+seq) and pod (epoch+last_seq) both survive;
  SES restarts stateless; replay deduped by pod. ✓
- **reattach (new frontend)**: new epoch → pod resets → fresh stream. ✓

## Wire change (commitment point)
`src/core/wire.zig`:
- `MuxVtHeader` gains `epoch: u64` + `seq: u64` (7 → 23 bytes, `align(1)`). Input
  direction only (pod→mux output uses a different header — untouched).
- `writeMuxVt` / header writers gain epoch+seq.
- POD input frame (SES→pod, `pod_protocol`): input frames carry epoch+seq
  (header field preferred over a payload prefix).
- Bump `PROTOCOL_VERSION` 3 → 4 so a format mismatch is rejected cleanly rather than
  silently corrupting. (`MIN_PROTOCOL_VERSION` stays == current, matching existing
  policy: pods from an older binary become unreachable after upgrade until restarted.)

## Phases (each independently verified before the next)

### Phase 1 — plumbing, dedup as NO-OP (behavior-preserving)
Thread epoch+seq end-to-end; the pod parses and DISCARDS them.
- wire.zig: extend `MuxVtHeader` + writers (default epoch=0, seq=0); bump version.
- frontend `vt_write_queue.enqueueFrame`: accept + stamp epoch/seq (callers pass 0).
- SES `routeMuxToPod`: read extended header, forward epoch+seq into the pod input frame.
- pod: parse epoch+seq off input frames, discard.
- VERIFY: build + full unit suite + smoke_reconnect/detach/dot_attach + heavy. No
  behavior change.

### Phase 2 — frontend sequencing + replay ring
`src/frontends/terminal/state.zig` (+ small fields/module):
- `input_epoch: u64` (`std.crypto.random.int(u64)` once at State init).
- `input_seq: u64` counter.
- `writePaneInput` / `sendResizeToPod` / password: assign `seq=++input_seq`, pass epoch.
- Replay ring: bounded (~64 KB) byte log of recent input frames WITH headers;
  `enqueueFrame` also appends to the ring; ring drops oldest over cap (LOG the drop —
  no silent truncation).
- On reconnect (replaces the `resetForReconnect` call in `ensureSesVtWatcherArmed`
  and `handleMuxVtWriteFailure`): CLEAR the live write queue, then re-enqueue the ring
  in order so complete frames re-flush to the new socket with original seqs. The ring
  subsumes `resetForReconnect` — it re-sends FULL frames, so the partial-frame-desync
  case is handled too (old partial bytes died with the old socket), and the pod dedups
  any that were actually delivered.
- VERIFY: reconnect smokes still green (dedup is still a no-op here, so exactly-once is
  NOT yet asserted — that lands in Phase 3).

### Phase 3 — pod dedup + epoch reset (the correctness logic)
`src/modules/pod/main.zig`:
- Pod state: `input_epoch: u64`, `input_last_seq: u64`, `input_epoch_set: bool`.
- `handleFrame(.input)` + the `handleAuxInput` fast-path: apply the dedup rule before
  `queuePtyWrite`. Resize/password: apply always.

### Phase 4 — tests
- pod dedup unit test (fresh epoch resets; `seq<=last` drops; `seq>last` applies).
- `vt_write_queue` ring test (bounds, replay order, original-seq preserved).
- NEW live smoke `smoke_input_exactly_once.py`: type a UNIQUE marker command, kill the
  daemon at the same instant (race the keystroke), let it reconnect, assert the marker
  ran EXACTLY ONCE (grep a sink/history for exactly one occurrence). Many seeds/timings;
  plus a SIGSTOP-frontend variant.

## What this costs (honest accounting)

### Negligible
- **Bandwidth**: +16 B per input frame. Input is low-volume vs output. Nothing.
- **Memory**: ~64 KB replay ring per frontend + ~24 B pod state. Nothing.
- **Latency/CPU**: dedup is one integer compare. Nothing.

### Real costs
- **Complexity on the hottest path.** Today the keystroke path is enqueue → flush.
  This adds sequencing state in the frontend AND a dedup table in the pod, on the path
  every keystroke takes — adding moving parts to the COMMON path to fix a RARE edge
  (typing in the ~2 s window of a reconnect).
- **The scary failure mode flips.** Today a bug loses a keystroke. With replay, a
  dedup bug could RE-RUN a command (replay `rm -rf` that already executed). Exactly-once
  is only as good as dedup correctness — hence Phase 1 no-op + Phase 4 exactly-once smoke.
  This is a higher-stakes bug class than today's.
- **Protocol bump v3→v4.** Pods started by the old binary become unreachable after an
  upgrade until restarted. Already true for any past wire change (MIN==CURRENT), so
  status-quo, not a new loss — but named for the record.

### Minor
- Replayed **resize** could momentarily set a stale size before a newer one corrects it
  (self-correcting, sub-frame blip). Password-mode similar.
- `sync_input` broadcast mode (same input fanned to multiple panes, each pod deduping
  its own) is an extra interaction to verify.

### Verdict
Resource costs are zero. The real trade is permanent complexity + a higher-stakes
failure class on the common keystroke path, to fix a rare edge. The phased no-op-first
approach keeps the risk containable and every phase is independently verifiable. This is
the one change in the hardening effort that adds risk to the COMMON path rather than
removing it — worth doing only if the reconnect-window input loss actually bites in
practice. The already-shipped `resetForReconnect` fix (commit a209e09) covers the
clean-failure cases and leaves the common path simple.

## Out of scope (documented, not fixable this way)
- **SIGSTOP-single-keystroke pty artifact**: the keystroke never leaves the kernel pty
  into the frontend, so there is nothing to sequence. Only occurs if the hexe UI process
  itself is SIGSTOPped — Ctrl-Z stops the pane's shell, not hexe.
