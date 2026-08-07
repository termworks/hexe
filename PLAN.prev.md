# Hexe improvement plan

Status: proposed, not started. Written 2026-07-28 against `develop` @ `088b8cf`.

Covers three reported problems — daemon-wide stalls, attach flapping, general
performance — plus a full-codebase audit that turned up several defects more
severe than the reported symptoms.

**Verification legend:** findings marked **[V]** were confirmed by reading the
code directly. **[R]** are reported from a subsystem audit but not
independently re-checked. **[U]** are flagged unverified by the reporter.

---

# Part I — The three reported problems

## 1. Root cause: SES is a run-to-completion loop that performs blocking work

`hexe session` (SES) is a single xev event loop (`server.zig:710`). Every
session, pane, frontend, and CLI call is serviced by that one thread,
run-to-completion. The design is fine; the problem is that handlers on it do
**synchronous blocking I/O and process spawning**, so one peer's slowness
freezes every other session.

Stall budget of a single event, measured from the code:

| Site | Location | Worst-case freeze of ALL sessions | Trigger | |
|---|---|---|---|---|
| `connectPodVt` connect + ack | `vt_routing.zig:26`, `:43` | **3000 ms per pane, retried every 1 s** | pod VT reconnect | **[V]** |
| Pod spawn handshake | `pane_spawn.zig:168-188` | **2500 ms** | any new pane/split/tab/float | **[V]** |
| `skipBytes` | `server.zig:2028` | **2000 ms** | frame for an unrouted pane | **[V]** |
| VT route header + payload | `server.zig:1771`, `:1808` | 2 × 500 ms | pod stalls mid-frame | **[V]** |
| Connection handshakes | `server.zig:1434`, `:1516`, `:1577` | 500 ms each | any connect | **[V]** |
| CTL reads / replies / CLI requests | `server.zig:988`, `:2056`, `:2261` | 500 ms each | slow peer | **[V]** |
| `persistNow` JSON + 2 fsyncs | `persist.zig:139-169` | disk-bound | ≤1/sec while dirty | **[V]** |

The 500 ms figures are already the result of a hardening pass (they were 2 s and
10 s — see `server.zig:20-39`). Shrinking them further is not the answer; the
loop must not block at all.

Two sites deserve special mention.

**`connectPodVt` is the worst offender and was missed by the earlier hardening.**
It does a blocking `ipc.Client.connect` (`CONNECT_TIMEOUT_MS = 2000`,
`ipc.zig:51`) plus a blocking ack read (`POD_VT_ACK_TIMEOUT_MS = 1000`) on the
event loop. It is called from `processBacklogReplays` (`pane_lifecycle.zig:299`),
which the periodic tick runs **every second** over every pane needing replay. A
pod that is alive but not accepting keeps `needs_backlog_replay = true` and is
retried every tick — a permanent multi-second freeze of the whole daemon, once
per second. On attach with N panes it is up to N×3 s. **[V]**

**`spawnPod` reads the handshake one byte at a time**, with a `poll()` syscall
per byte — up to 512 `poll()` + 512 `read()` — inside `handleBinaryCreatePane`
(`server_pane_lifecycle_handlers.zig:208` → `pane_creation.zig:35`). **[V]**

This compounds on the frontend: frontends issue **synchronous RPCs with a 10 s
timeout** (`SYNC_RESPONSE_TIMEOUT_MS`, `frontend_client.zig:39`, used at
`:715 :858 :900 :968 :1094 :1119 :1170 :1215 :1305`). While SES is blocked on
session A, session B's frontend is blocked in a sync RPC — B's UI freezes too.

## 2. Root cause: the attach flapping loop

A self-sustaining livelock, fully traceable: **[V]**

1. Attach → SES reconnects every pane's pod; each replays up to
   `REPLAY_TAIL_CAP = 1 MiB` (`pod/main.zig:399`, replay at `:1424-1448`).
2. SES fans **all panes of a session** into **one shared per-client queue**
   capped at `MUX_VT_QUEUE_MAX_BYTES = 4 MiB` (`server.zig:40`, `:629`).
3. Overflow → `enqueueMuxVtFrame` returns `error.QueueFull` (`:1643`) →
   `routePodToMux` calls `queueVtClose(mux_vt_fd)` (`:1814-1818`). **SES kills
   the frontend's VT channel.**
4. The frontend does a **full re-register under a fresh UUID + reattach**
   (`loop_core.zig:62-111`) — it fires on VT-only loss by design
   (`if (ctl_ok and vt_ok) return;`).
5. Reattach re-triggers replay for every pane → back to step 2.
6. `RECONNECT_RETRY_MS = 2000` (`loop_core.zig:60`) → flaps every 2 s forever.

**Threshold:** ~≥5 panes each holding ≥1 MiB of scrollback. Exactly "attach to a
session with a lot of scrollback".

The comment at `loop_core.zig:63-67` treats the overflow-drop as normal and
reattach as the cure. It is not: reattach *causes* the overflow.

**Three independent aggravators, each of which can trigger or extend the flap on
its own:**

- **A failed reconnect permanently orphans the session.** `maybeReconnectSes`
  overwrites the runtime identity with a fresh UUID **before** calling
  `attachFrontend()`, and the error path returns with no rollback
  (`loop_core.zig:85-99`). The next attempt captures `old_uuid` = the throwaway
  UUID from the failed attempt, so `reattachSession` asks for an id that never
  existed. The real session and its pods survive but are unreachable. **[V]**
- **`detachSession` skips all fd and lock teardown.** `detach_lifecycle.zig:317-319`
  does a bare `client.deinit()` + `orderedRemove`, while `removeClient`
  (`client_lifecycle.zig:125-126`) and `removeClientGraceful` (`:144-145`) both
  call `closeClientMuxFds` **and** `releaseClientLocks` first. Every explicit
  detach leaks two fds with armed watchers plus queued VT bytes. **[V]**
- **`flushMuxVtQueues` discards fatal write errors.** `server.zig:1696` does
  `_ = self.flushMuxVtQueue(...)`; the pod-direction twin (`:1762`) correctly
  closes on false. A dead frontend socket is never noticed during the periodic
  flush — the queue grows to the 4 MiB cap and the routing path tears it down
  there instead, feeding the flap. **[V]**

Additionally the frontend drains only 64 frames per loop iteration
(`loop_watchers.zig:274`, deliberately, to keep input responsive) with a render
pass each iteration, so its drain rate during replay is well below the pods'
burst rate. And when a client is attached the pod has **no backpressure path**:
it writes with `writeFrameBounded(..., 2000 ms)` and on failure **drops SES
entirely** (`pod/main.zig:1320`); `pty_paused` only engages while *detached*
with a full ring (`:970-1014`). The pod cannot slow down, only give up. **[V]**

**Coverage gap:** `scripts/smoke_bighistory.py` covers **one** pane with big
scrollback. The flap needs **several** panes simultaneously to exceed the shared
4 MiB queue. Untested.

## 3. Secondary throughput issues

- **One frame per event loop wakeup.** `routePodToMux` reads exactly one frame
  and returns `.rearm` (`server.zig:1768-1823`) — a full loop round trip plus
  io_uring submit/complete per 16 KiB frame. **[V]**
- **Full pane-table scan per frame on index miss.** `findMuxVtForPane` (`:1900`)
  and `muxVtFdOwnsPane` (`:1931`) each iterate every pane; the MUX→POD path
  calls both. Made worse by finding B-8 below, which leaks stale index
  entries. **[V]**
- **Linear scans on connection paths:** `isMuxVtFd` (`:1620`),
  `findClientForCtlFd` (`:2047`), `removeMuxVtFd` (`:2009`), the pane loop in
  `processPendingCtlCloses` (`:851`). **[V]**
- **Per-second sweeps over all panes** (`server.zig:1381-1383`) with an
  `open`+`read`+`close` of `/proc/<pid>/stat` per pane (`sticky_panes.zig:8`). **[V]**
- **4 MiB `vt_route_buf` copy-through** (`server.zig:674`) read into with
  blocking `readExactTimeout`. **[V]**

---

# Part II — Findings register

Subsystem audit results. Ordered by severity within each group.

## A. Security

**A-1. The `.hexe.lua` trust ledger is bypassed — project Lua executes with
`io`/`os`/`package` open before any trust check.** **[V]** *(found independently
by two audits)*
`isUnsafeMode()` returns `true` unless `HEXE_UNRESTRICTED_CONFIG` is explicitly
set (`lua_runtime.zig:230-236`), so `LuaRuntime.init` calls `openIO()`,
`openOS()`, `openPackage()` (`:283-297`). `parseSessionLayoutLua` →
`runtime.loadConfig(path)` **executes the file body** (`session_config.zig:485`);
only afterwards does `projectCommandsAllowedForPath` consult `trust.isTrusted`
(`state_session.zig:672-678`), and only for the declarative `on_start`/`on_stop`
strings. A hostile repo ships `.hexe.lua` with `os.execute("curl …|sh")` at file
scope and it runs before the ledger is consulted at all. `hexe layout list`
(`com.zig:426`, `:462`) parses — i.e. executes — the cwd's `.hexe.lua` from a
read-only-sounding command with no prompt.
`docs/isolation.md` claims the opposite: "the Lua runtime is sandboxed (no
`io`/`os`); only the shell-hook path is gated."
*Fix:* require ledger trust (or explicit confirm) **before** `loadConfig` on any
project-local path; load untrusted project files in restricted mode; default
`isUnsafeMode()` to `false`.

**A-2. `hexe.exec()` is registered even in safe mode.** **[R]**
`injectHexeModule` is called unconditionally (`lua_runtime.zig:306`) and always
binds `hexe.exec`, which shells out via `/bin/sh -c` (`cmd.zig:266`). Even after
fixing A-1, `require('hexe').exec("…")` at load time gives arbitrary execution.
*Fix:* gate `hexe.exec` registration on `unsafe_mode` / a trusted-config flag.

**A-3. `--isolated` floats get no isolation whatsoever.** **[V]**
`applyChildIsolation` / `applyChildCgroup` have **zero call sites**;
`isolation.zig` is not exported from `mod.zig` (only `isolation_voidbox` is, at
`:33`). The entire Landlock + userns + cgroup implementation is unreachable.
`HEXE_POD_ISOLATE=1` is set by `loop_ipc.zig:787` and read only by that dead
module. A user asking for an isolated float silently gets a plain shell.
*Fix:* delete `isolation.zig` and map the flag to a voidbox profile (as
`loop_actions.zig:1180-1184` already does), or wire it into the PTY fork path.

**A-4. Per-float `memory`/`cpu`/`pids` limits are parsed and discarded.** **[V]**
`applyParentCgroups` reads limits only from the daemon's own environment
(`isolation_voidbox.zig:92-112`). **Nothing in the tree ever sets `HEXE_CGROUP_*`.**
`IsolationConfig.memory/.cpu/.pids` are parsed from Lua
(`api_bridge.zig:1347-1376`) but only `iso.profile` is forwarded
(`loop_actions.zig:1180`, `pane_spawn.zig:148-152`).
`docs/isolation.md`'s fork-bomb example ("safely contained!") and its 512M
memory-kill example are both false.
*Fix:* plumb the limits through create_pane into the pod env as `HEXE_CGROUP_*`.

**A-5. Clients never verify the server's UID.** **[R]**
`verifyPeerUid` is called only on accept (`server.zig:1407`, `pod/main.zig:1204`);
no connect path calls it (`ipc.zig:243-291`). With the `/tmp` fallback (A-6),
another local user can bind `ses.sock` first — the real daemon then fails with
`AddressInUse` and every frontend/CLI connects to the attacker.
*Fix:* call `verifyPeerUid` in `Client.connectTimeout` before the handshake.

**A-6. Runtime/lock/log paths fall back to world-writable `/tmp` with no
`O_NOFOLLOW` and no ownership check.** **[R]**
`getSocketDir` falls back to `/tmp` when `XDG_RUNTIME_DIR` is unset
(`ipc.zig:510-533`); `getLogPath` **always** returns `/tmp/hexe/<instance>/log`
(`:610-623`), ignoring XDG entirely. `acquireInstanceLock` opens the lock
`O_CREAT|O_RDWR` and immediately `ftruncate`s it (`session/main.zig:722-753`).
A local attacker who pre-creates `/tmp/hexe/` can symlink these at victim files.
The debug log also contains cwds, command lines, and pane metadata.
*Fix:* refuse `/tmp`; create the dir `0700` and `fstat`-verify owner/mode/type;
open with `O_NOFOLLOW`, mode `0600`; move logs under `$XDG_STATE_HOME`.

**A-7. Trust-ledger TOCTOU.** **[R]** *(found independently by two audits)*
`trust.isTrusted` re-opens and re-hashes the path (`trust.zig:43-54`) rather
than hashing the bytes that were parsed and executed. An attacker with write
access to the working tree can present malicious content at parse time and
restore the blessed content before the check. `hashFile` also follows symlinks.
*Fix:* hash the exact bytes read for parsing; never re-read the path.

**A-8. Trust is keyed on content hash alone with no path binding.** **[R]**
`trust.zig:43-54` stores bare SHA-256 lines, so allowing one repo's `.hexe.lua`
trusts a byte-identical file everywhere. Separately `pty.buildEnv`
(`pty.zig:259-305`) forwards the daemon's whole environment into pane shells, so
`HEXE_TRUST_ALL_PROJECTS`, `HEXE_ALLOW_CROSS_UID`, `HEXE_UNRESTRICTED_CONFIG`
are inherited by anything a pane runs.
*Fix:* store `<realpath>\t<hash>` pairs; strip those three vars from pane env.

**A-9. Capability drop is a no-op in `sandbox`/`full`.** **[R/U]**
`buildConfig` sets `.cap_drop = "", .cap_add = ""` (`isolation_voidbox.zig:38-43`);
libvoid's `caps.apply` returns immediately when both are empty. Combined with
`user = true` the child holds a full capability set inside its userns. Docs claim
"Capabilities dropped".
*Fix:* populate `cap_drop`, or correct the docs.

**A-10. Unknown isolation profiles silently downgrade.** **[R]**
`getIsolationOptions` falls through to a default for any unrecognised string
(`isolation_voidbox.zig:60`), and cgroups key off exact `"sandbox"`/`"full"`
equality (`:167-177`). SES forwards the profile as raw trail bytes without
validation. `"Sandbox"` or `"none "` yields silently different isolation.
*Fix:* parse to an enum at the SES boundary; reject unknown values.

**A-11. `HEXE_INSTANCE` permits `.` and `..`.** **[R]**
`strings.sanitize` (`strings.zig:11-14`) lets dots through, so `HEXE_INSTANCE=..`
places sockets/state/logs one directory above their namespace.
*Fix:* reject names consisting only of dots.

**A-12. Resource caps are not enforced.** **[V]**
`allowNewPane` / `allowNewSession` (`resource_limits.zig:174-181`) have **zero
call sites**. Pane creation goes straight to `spawnPod` with no cap. Since all
`create_pane` requests travel over one established connection, the rate limiter
does not apply either — a single same-UID peer can spawn unlimited pods.
*Fix:* call them in `pane_creation.createPane` and the session-create path.

**A-13. Connection cap uses a 5-second-stale count of *registered* clients.** **[R]**
`updateStats` runs ≤1/5 s and passes `clients.items.len` (`server.zig:1360-1370`),
so accepted-but-unregistered connections are invisible to the cap. No idle
timeout exists.
*Fix:* maintain a live accepted-connection counter; add an idle timeout.

**A-14. Rate-limiter livelock starves interactive attach.** **[R]**
`isRateLimited` is global, not per-peer, at 60/min (`resource_limits.zig:44`,
`:151-160`). Every pod reconnects from its ~1 s tick, so a daemon restart with a
dozen panes saturates the window in seconds and SES then rejects the user's
attach and every CLI command.
*Fix:* per-peer buckets, exempt known pods, add backoff to
`PodUplink.ensureConnected`, reserve headroom for attach.

## B. Correctness — SES session model

**B-1. txlog replay cap drops the newest entries, so recovery destroys valid
sessions.** **[R]**
`readAll` reads from offset 0 and stops past `MAX_REPLAY_BYTES` = 10 MB
(`txlog.zig:193`, cap at `:108`); `truncate()` only runs at startup. Once the log
exceeds 10 MB, restart replays only the oldest 10 MB, sees `detach_start`
records whose commits lie past the cutoff, and `main.zig:90-106` removes those
detached sessions and force-orphans their panes.
*Fix:* truncate at commit boundaries; read the tail; treat "cap exceeded" as
"roll nothing back".

**B-2. Float `tab_visible` bitmask is never reindexed on tab insert/remove.** **[V]**
`tab_visible` is a per-tab-*index* mask (`session_projection.zig:310`). All three
tab-mutation sites carefully remap `parent_tab` (`snapshot.zig:155-163`,
`client_session_snapshot.zig:104-110`, `:217-229`) but none shifts the bits.
Close a tab and pinned floats appear on the wrong one — and it survives
detach/reattach because it round-trips through JSON.
*Fix:* shift the mask bits alongside each `parent_tab` remap.

**B-3. `active_tab` is not shifted when a collapsing tab is removed under it.** **[R]**
`removePaneFromSessionSnapshot` (`snapshot.zig:115-119`) reindexes `parent_tab`
but leaves `active_tab`; `normalizeAfterPaneRemoval` only clamps when out of
range. Focus silently jumps to a different tab. The existing test
(`state_test.zig:2351`) uses `active_tab = 0` and never exercises it.

**B-4. Crash-recovered panes are reaped at 24 h while their session lives 168 h.** **[R]**
`persist.load` downgrades recovered attached panes to `.orphaned`
(`persist.zig:383-387`), which `cleanupOrphanedPanes` kills at
`orphan_timeout_hours = 24`, while the session record survives
`detached_session_ttl_hours = 168` (`store.zig:562-563`). Reattaching on day 2
gives a session whose panes were all destroyed.

**B-5. `kill_session <name>` destroys an arbitrary session on name collision.** **[R]**
`findByNameOrPrefix` returns the first hashmap-order match
(`detached_sessions.zig:107-109`). The uuid-prefix branch immediately below is
explicitly hardened against exactly this; the name branch is not. Duplicate
names are deliberately tolerated (`cleanup.zig:156`).

**B-6. `pane_id` wraps with no live-pane check.** **[V]**
`allocPaneId` (`store.zig:655-660`) increments a `u16` and wraps to 1 without
checking `pane_id_to_uuid`. After 65535 pane creations a new pane aliases a live
pane's routing entries.

**B-7. `updateClientSessionFocus` indexes `snapshot.tabs` with an unvalidated
`parent_tab`.** **[R/U]**
`client_session_snapshot.zig:52-65` — the `active_tab_hint` path above and the
fallback below are both bound-checked; the middle branch is not. Panics the
daemon on an out-of-range `parent_tab`. In-process trigger unverified; a corrupt
state file reaches it (`session_model.fromCanonicalRoot:725` does not bound-check).

**B-8. `killPane` leaks the `pane_id_to_uuid` entry when the pod VT fd is already
closed.** **[R]**
`pane_lifecycle.zig:392-395` — the `else` branch removes only
`pane_id_to_pod_vt`. Detach explicitly nulls `pod_vt_fd`, so every pane killed
while detached leaves a stale entry, forcing the per-frame hot path onto its
full-pane-scan fallback (Part I §3).

**B-9. Wrong-length frees from failed `toOwnedSlice`.** **[R]**
`detach_lifecycle.zig:62-68`, `pane_lifecycle.zig:124-130`,
`detached_sessions.zig:51-56` assign `pane_uuids = uuids.items` on failure, one
element shorter than the backing allocation, which `deinit` later frees.

**B-10. A pod is orphaned if any step between `spawnPod` and `panes.put` fails.** **[R]**
`pane_creation.zig:35-66` has no `errdefer` that kills the spawned pod; it keeps
its pty, shell child and socket with no record for any sweep to find.

**B-11. `TxEntry` is written to disk via `asBytes` on an auto-layout struct.** **[R]**
`txlog.zig:88-99` — writes uninitialized padding into a persistent file and makes
the on-disk format depend on compiler field ordering.

## C. Correctness — POD, PTY, transport

**C-1. `hexe pod attach` is broken and destructive.** **[V]**
It handshakes as `POD_HANDSHAKE_SES_VT` (`pod_attach.zig:174`) so the pod treats
it as the authoritative VT client, but writes raw stdin as the `.input` payload
(`:78`) while `applyInputFrame` requires and strips a 16-byte epoch/seq prefix
(`pod/main.zig:1382`). Every keystroke is dropped as "too short"; a ≥16-byte
paste has its first 16 bytes consumed as a bogus epoch/seq that is then latched
into `input_dedup`. Separately, `acceptVtClient` unconditionally closes the
existing client (`:1400`), so running it against a live pane evicts SES, which
re-dials, which evicts the attach client — a flap with a full backlog replay each
cycle.
*Fix:* prepend the epoch/seq prefix; give CLI attach its own handshake class
that does not displace `Pod.client`.

**C-2. A back-pressure-paused PTY is never resumed by an observer.** **[V]**
Resume is gated on `pod.client != null` (`pod/main.zig:837`) and `armPtyWatcher`
early-returns while `pty_paused` (`:946`). `acceptObserver` never sets
`pod.client`, so `hexe pod record` on a paused pane leaves the child shell
blocked on its PTY writes forever.
*Fix:* gate the resume on "any consumer" and clear `pty_paused` before arming.

**C-3. Observer replay uses unbounded `writeFrame` on a non-blocking fd.** **[V]**
`acceptObserver` sets the fd non-blocking then replays with plain `writeFrame`
(`pod/main.zig:1257-1278`), whose `Connection.send` is a bare `posix.write` loop
with no readiness wait (`ipc.zig:315`). The first EAGAIN closes the connection
before `observers.append` runs, so `hexe pod record` deterministically fails on
any pane with real scrollback. `broadcastToObservers` (`:1300`) has the same
shape — one transient EAGAIN permanently evicts a live observer.
*Fix:* use `writeFrameBounded` on the observer path, as the VT client path does.

**C-4. Blocking handshake reads inside the pod's accept callback.** **[R]**
`acceptCallback` drains the whole backlog in a loop and handles each connection
synchronously with `readExactTimeout(..., 2000 ms)` (`pod/main.zig:1212`,
`:1472-1501`, `:1524-1540`). `handleBinaryShpConnection` does three such reads
(~6 s). With a listen backlog of 16, stalled connections wedge the pod — and the
user's shell — for ~96 s.

**C-5. `pod_protocol.Reader` accepts an unvalidated `u32` skip length.** **[R]**
`pod_protocol.zig:112-130` sets `skip_len` straight from the wire with no
ceiling. One desynced or hostile header declaring `0xFFFFFFFF` puts the reader
into `skipping` for 4 GiB — the pane goes permanently deaf to input while output
keeps flowing.

**C-6. Frontend input chunking overflows `MAX_PAYLOAD_LEN` by the 16-byte
prefix.** **[R]**
`vt_write_queue.zig:122`/`:151` chunk at `MAX_PAYLOAD_LEN` then add 16 bytes, so
a ≥4 MiB paste emits `len = 4 MiB + 16`; `routeMuxToPod` (`server.zig:1840`)
rejects it and tears down the mux's **entire** VT channel — every pane in that
frontend.

**C-7. `PodUplink.tick` commits its cache before sending.** **[R]**
`uplink.zig:67-110` updates `last_cwd`/`last_fg_process` before `ensureConnected`,
so a failed connect or write permanently suppresses the update; `forceRefresh`
resets only `last_sent_ms`, so reattach does not heal it.

**C-8. SHP frame lengths are not cross-validated.** **[R]**
`pod/main.zig:1479-1506` checks `hdr.payload_len >= @sizeOf(ShpShellEvent)` but
never compares it against the `cmd_len + cwd_len` taken from the struct body.

**C-9. `armClientWatcher` two-slot completion reuse.** **[R/U]**
`pod/main.zig:857-870` alternates two completions and zeroes them; since
`acceptCallback` drains the whole backlog without an intervening `loop.run`, a
third connection can reuse a slot whose CQE has not been reaped.

**C-10. Each pod eagerly allocates ~12–16 MB of fixed buffers.** **[V]** *(two audits)*
`pod/main.zig:476` (4 MiB ring), `:479`, `:539`, `:541` — several independent
buffers sized from `MAX_PAYLOAD_LEN`, which is the protocol's *max single
message*, not a scrollback budget. 30 panes ≈ 360 MB RSS. No config knob.

**C-11. `RingBuffer.copyOut` returns the OLDEST bytes when the destination is
smaller than the ring.** **[R]**
`buffering.zig:74-85`. Latent today (both buffers are `MAX_PAYLOAD_LEN`); becomes
a live bug the moment C-10 is fixed.

**C-12. EAGAIN-as-EOF in the two pod CLI readers.** **[R]**
`pod_record.zig:71-75`, `pod_attach.zig:107-118` — currently unreachable because
`connectTimeout` hands back a blocking fd, but nothing enforces that.

## D. Correctness — frontend client, CLI, wire

**D-1. `hexe mux float` / `com exit-intent` hang forever when the frontend
dies.** **[V]**
The daemon parks the waiting CLI's fd in `pending_float_cli_fds` /
`pending_exit_intent_cli_fd` (`server.zig:637-639`, put at `:2316`, `:2379`).
Neither `processPendingCtlCloses` (`:802-865`) nor `purgeClientFdState`
(`:877-893`) touches them — both handle only `pending_pop_requests`. So a
frontend crash leaves the CLI blocked in `wire.readControlHeaderBlocking`
(`wire.zig:950`, `poll(&pfd, -1)`, deliberately unbounded) forever, and leaks one
daemon fd permanently. `runExitIntent` is wired into the shell exit hook, so this
presents as **a shell that can never exit**.
*Fix:* drain both on frontend death; add a wall-clock sweep in `periodicCallback`.

**D-2. Busy-spin at 100% CPU on a partial control header.** **[V]**
`tryReadControlHeader` (`wire.zig:979`) has a bare `error.WouldBlock => continue`
— no poll, no yield. The sibling `tryReadMuxVtHeader` (`:1039`) already does
`waitReadableTimeout`, so this one was simply missed. A header split across two
writes — which `writeAllTimeout` produces whenever the daemon's socket buffer is
briefly full under VT load — pins a core.

**D-3. Reconnect runs daemon-kill and daemon-spawn synchronously on the render
loop.** **[R]**
`connectLocalIpc` (`frontend_client.zig:493-556`), `terminateStaleDaemon` /
`waitInstanceLockFree` (`:565-601`, 3 s + 3 s of `Thread.sleep`), `startSes`
(`:1419-1426`, up to 3 s), plus a 10 s blocking `register()`. ≈19 s of frozen UI
per attempt, repeated every 2 s — the exact symptom the reconnect code exists to
fix.

**D-4. Every split/tab/float issues one synchronous RPC per existing pane.** **[R]**
`syncPaneAux` → `unfocusAllPanes` (`state_sync.zig:103`, `:136-207`) calls
`updatePaneAux` per pane, each a blocking write (10 s) + ack read (5 s). N panes
= N sequential round trips before the frame renders. Nothing about the unfocus
needs an ack.

**D-5. `pending_control_responses` grows without bound and is scanned
linearly.** **[R]**
`ses_client_responses.zig:86`, drained only by exact-id match at `:94-101`. Every
sync call that hits its deadline orphans an entry of up to 4 MB. No cap, no TTL —
while the sibling `pending_pushes` queue *was* explicitly bounded (`:121-122`).
`takePendingControlResponse` is an O(n) scan run on every sync call.

**D-6. Fire-and-forget requests allocate request_ids, so their replies park
forever.** **[R]**
`requestPaneCwd` (`frontend_client.zig:930-937`) and `requestPaneProcess`
(`ses_client_queries.zig:50-57`) fire every pane-sync tick through
`writeControlRequest`; nobody ever claims their ids. Feeds D-5 and silently loses
the cwd / fg-process update.

**D-7. `readExpectedPaneCwdResponse` drops an unrelated ack instead of queueing
it.** **[R]**
`ses_client_reads.zig:149-155` returns `error.UnexpectedResponse` where every
sibling queues. A late `updatePaneAux` ack makes `getPaneCwdSync` return `null`,
so a new pane spawns in the wrong directory.

**D-8. A mid-frame body-read failure leaves the CTL stream desynced with the fd
live.** **[R]**
`frontend_client.zig:166-181` — unlike the other read helpers, `ctl_fd` is not
invalidated, so the next header parse reads body bytes as a `ControlHeader`.

**D-9. `skipPayloadChecked` has no total deadline.** **[R]**
`ses_client_reads.zig:575-583` — `len` is the raw `u32`, unclamped at most call
sites, and each 4 KiB chunk gets a fresh 10 s budget. The daemon side already
solved this with `SKIP_TOTAL_TIMEOUT_MS` (`server.zig:2223-2242`); the frontend
never got it.

**D-10. Oversized VT frame drain is unbounded in the frontend.** **[R]**
`vt_events.zig:56-64` — `header.len` is not checked against `MAX_PAYLOAD_LEN`
before draining, so a desynced stream makes the frontend read up to 4 GiB.

**D-11. liblink bridge leaked per reconnect; `Bridge.deinit` can hang.** **[R]**
`resetConnectionState` (`frontend_client.zig:380-403`) never touches
`self.bridge`. The workers cannot exit — closing the local end only sets
`local_eof`, after which they poll-sleep forever — so `deinit` can block on
`thread.join()` at shutdown.

**D-12. Double-close of socketpair fds if the second bridge thread fails to
spawn.** **[R]** `frontend_liblink_transport.zig:94-124`.

**D-13. `hexe session pipe` never exits after the daemon closes.** **[R]**
`ses_pipe.zig:32-45` — the upstream thread parks in `read(stdin)` and nothing
closes stdin, so every remote reconnect leaves a stuck process.

**D-14. Almost every CLI failure path exits 0.** **[R]**
`pop_handlers.zig:61-64`, `com.zig:1394-1397`/`1447-1450`/`1486-1489`,
`mux_float.zig:21-24`, `app.zig:1247-1250`. Worst case: `hexe popup confirm` with
an empty message returns normally → exit 0, and the documented contract is
`0 = yes`. So `hexe popup confirm "$msg" && rm -rf …` with an unset `$msg`
silently confirms.

**D-15. `pod kill` / `record stop` signal PIDs from stale on-disk metadata.** **[R]**
`pod_kill.zig:31`/`:84-96`, `record_ctl.zig:130-134` — no ownership check, while
`frontend_client.zig:69-80` already has the right `/proc/<pid>/cmdline` guard.
After a crash and pid reuse this SIGKILLs an unrelated process.

**D-16. Bare `hexe` in a pane can block forever on the nested-mux confirm.** **[R]**
`app.zig:1270-1312` sends `pop_confirm` with `timeout_ms = 0` then calls
`readControlHeaderBlocking`, which polls forever.

**D-17. Float title-segment parse frees a wrong-length slice.** **[R]**
`api_bridge_float.zig:115-133` assigns `arr[0..count]` from a `seg_len`
allocation; `FloatStyle.deinit` frees that slice. Same shape at `config.zig:1613`.

**D-18. `hexe terminal record` records a session that immediately errors.** **[R]**
`mux_record.zig:29` spawns `hexe terminal attach` with no session name.

**D-19. `layout load` reports success with no ack; layout names are unvalidated
path components.** **[R]** `com_layout.zig:445-450`, `:223-232`.

## E. Performance — Lua, config, statusbar

**E-1. A malformed config value aborts the whole frontend.** **[R]**
`statusbar.zig:1142` (also `:1152`, `:1173`, `:1183`, `:1200`, `:1210`) calls
`rt.lua.raiseError()` from plain Zig with **no `lua_pcall` frame on the stack**,
so `lua_error` hits the default panic function and `abort()`s. A config returning
`prefix = { output = 5 }` kills the terminal and every attached pane's UI.

**E-2. `hexe.exec()` returns hexe's internal cache table instead of the
result.** **[V]**
`lua_api_exec.zig:191-192` — `defer lua.pop(1)` runs *after* the return
expression is evaluated, popping the result `pushExecResult` just pushed and
leaving the cache table on top; the function returns 1, so Lua receives the
cache table. Every sync-path `hexe.exec()` gets `r.ok == nil`, `r.output == nil`,
and a writable handle to hexe's private cache. The test that would have caught it
(`:304`) is `dormantSkip`'d.

**E-3. `Context.cached_segments` hands out slices into a buffer the next segment
clears.** **[R]**
`segments/context.zig:126-138` with `:217-221` — `addSegment` does
`clearRetainingCapacity()` then returns `segment_buffer.items`, and that exact
slice is cached per segment name. Rendering `directory` then `hostname` leaves
the `directory` cache pointing at hostname's text. Since the bar renders each
module twice per frame (E-5), the draw pass reads the poisoned cache.
`allocText` additionally returns slices into a growable `ArrayList`.

**E-4. Every render frame rebuilds the whole Lua context.** **[R]**
`statusbar.zig:559-764` — a full `getEnvMap` copy, a Lua table per pane, plus a
`dupeZ` + `loadString` + `protectedCall` of the ~1.1 KB `pane_api` chunk. The
`instance_id` short-circuit never fires because `statusbar.draw` creates a fresh
`Context` every call (`:1496`) and each visible float builds its own
(`loop_render.zig:373-376`). Renders are triggered by pane output, not just the
ticker — on a busy pane with 3 floats that is ~240 environment copies and ~240
Lua compiles per second.

**E-5. Every module is fully evaluated twice per frame.** **[R]**
`calcModuleWidth` (`statusbar.zig:1633`) and `drawModule` (`:1713`) run
near-identical bodies and the *drawn* value comes from the second. For dynamic
builtins this doubles the syscalls per frame (`/proc/stat`, `/proc/meminfo`,
`/proc/uptime`, `/sys/class/power_supply`, a full `/sys/class/net` walk). For
`netspeed` (`netspeed.zig:25-36`) the second call divides by microseconds of
elapsed time, so the **displayed** value is inflated by ~4 orders of magnitude.

**E-6. Use-after-scope in builtin segment output.** **[R]**
`statusbar.zig:2258-2282` (used at `:2372`) and `:2493-2517` (used at `:2582`) —
`styled`/`text_buf` are declared inside an inner block but consumed after it,
where the compiler may reuse the storage for `styled_for_button`.

**E-7. `hostname` and `battery` return slices into dead stack frames.** **[R]**
`segments/hostname.zig:27-34`, `segments/battery.zig:63-76` — the latter's
comment even says "Copy to a position in buffer that won't be reused", but no
copy happens.

**E-8. `AsyncCmdCache.entries` never expires or evicts, and creation spawns
immediately.** **[R]**
`async_cmd.zig:229-243`, `:353` — keys are user-controllable strings
(`lua_api_exec.zig:174`). A config composing a command dynamically mints a new
entry every frame, each spawning a child on creation and retaining its key,
argv, and output buffer forever. At 60 fps that is 60 forks/second plus unbounded
memory in a process that runs for days.

**E-9. The `shp` prompt rebuilds the Lua context once *per segment*.** **[R]**
`shell/render_modules.zig:90-174` has no instance-id guard at all. An 8-segment
prompt pays 8 environment copies and 8 Lua compiles per Enter.

**E-10. `git_status` walks to the filesystem root before checking its cache.** **[R]**
`segments/git_status.zig:56` — `isGitRepo` runs unconditionally ahead of the TTL
check at `:64`. Both git caches are single-entry keyed by cwd hash, so
alternating focus between two repos misses every render. Also, `checkStash`
stores empty output as `null`, so a repo with no stashes re-spawns forever.

**E-11. `on_start`/`on_stop` hooks fork with no reap.** **[R]** *(two audits)*
`state_session.zig:705-718` — raw `fork` + `execve`, no `waitpid`, and no
`SIGCHLD` disposition anywhere in the frontend (`main.zig:306-323`). Every hook
leaves a permanent zombie; the child also inherits the whole fd table.

**E-12. Config reload leaks all statusbar segments and their strings.** **[R]**
`config.zig:1046-1078` never frees `tabs.status.left/center/right` or the strings
`config_builder.zig:230-260` duplicated into them.

**E-13. Statusbar caches are keyed by raw pointer values and never evicted.** **[R]**
`statusbar.zig:316-318`, `:229-231`, `:285-287`, `:247-249` — a newly allocated
string landing on a freed address with the same length inherits the previous
entry's cached value.

## F. Terminal frontend — loop, input, render

**F-1. The input loop drops the rest of a stdin batch after forwarding one
unmapped key.** **[V]**
`loop_input.zig:1087` — an unconditional `return;` at the bottom of the
`while (i < inp.len)` body. `dispatchParsedEvent` returns `consumed = false` for
any `.key_press` libvaxis decoded but `vaxisKeyToBindKey` could not map — i.e.
any codepoint > 0xFF that is not one of eight specials (`input.zig:155`). The
bytes are forwarded at `:1084` and the function then **returns**, abandoning
`inp[i + res.n ..]`.
Concrete: hold `Delete` in vim. One `read()` returns `\x1b[3~\x1b[3~\x1b[3~`;
only the first reaches the pane. Same for `F5` followed by more typing in one
read, and any burst mixing function keys with normal keys. Silently lost — and
the 64 KB `pumpStdin` buffer makes multi-event reads routine under fast typing.
*Fix:* replace the `return` with `i += res.n; continue;`, and move the
popup-blocked early-out into its own `return` inside that branch.

**F-2. Statusbar `when` clauses are parsed but never evaluated.** **[V]**
`passesWhen` (`statusbar.zig:1315`) has **zero callers** — the only reference is
`passesWhenClause`'s own recursion at `:1332`. Both `drawModule` (`:2153`) and
`calcModuleWidth` (`:2403`) explicitly discard their `PaneQuery` with
`_ = query;`. A segment configured `when = { float = true }` is always visible
and always measured. `config_builder.zig:280` and `config.zig:249` parse the
clause; nothing consumes it.
*Fix:* call `passesWhen` at the top of both — return 0 / `start_x`.

**F-3. Frame arena grows unbounded to 8 MB; float backgrounds dominate.** **[R]**
`render_core.zig:58` unconditionally `frame_arena.dupe`s every drawn cell's
grapheme, and the arena resets only above 8 MB (`loop_render.zig:588-594`).
`drawBorderFrame` (`borders.zig:86`) fills the entire float rect with `putChar`
before the pane blits over it — a 100×30 float is 3000 one-byte arena allocations
per frame. Steady state with one float at 60 fps is ~200 KB/s, so every ~30-40 s
the threshold trips, forcing `invalidate()` + `force_full_render` — a
full-screen repaint the user sees as a periodic flash.

**F-4. Kitty image sync re-hashes every image's full pixel data every frame, per
pane.** **[R]**
`vt_bridge.zig:231` computes a Wyhash over the entire payload *before* the
cache-hit comparison at `:238`. A 2 MB image costs 2 MB of hashing per pane per
frame — 120 MB/s at 60 fps for unchanged content.

**F-5. Float rendering is O(F²) in linear `floatState` scans.** **[R]**
`session_projection.zig:279-288` walks `snapshot.floats.items` comparing 32-byte
uuids and copies the struct out by value; six accessors call it, and the render
loop performs ~8 per float (`loop_render.zig:361-376`, `:242-252`, plus
`state.zig:210`). Repeated on every mouse-motion event and keystroke via
`resolveFocusedPaneForInput`.

**F-6. Terminal resize silently reverts the screen's Unicode width method.** **[R]**
`render_vx.zig:28-38` replaces `vx.screen` wholesale, and `vaxis.Screen` defaults
`width_method` to `.wcwidth`. Capability detection sets `.unicode` at
`host.zig:52` and `loop_input.zig:61`, but nothing re-applies it after a resize —
the probe is one-shot. So after the first window resize, every emoji and wide
grapheme is measured with `wcwidth` for the rest of the session.

**F-7. libvaxis paste allocations leaked in the input pre-scan paths.** **[R]**
`vaxis.Parser.parse` allocates for `.paste` events (up to 128 KB).
`stashIncompleteParserTail` (`loop_input.zig:114`) and `recordKeycastInput`
(`loop_input_keys.zig:31`) parse the whole input and discard every result without
freeing; the rename/copy-mode/search-mode branches (`loop_input.zig:974-992`) and
the forward path (`:1083-1087`) skip `freeParsedEventPayload` where sibling
branches call it.

**F-8. One invalidation granularity: any pane output triggers a full-screen
redraw plus full statusbar evaluation.** **[R]**
`state.needs_render = true` from any VT chunk (`loop_watchers.zig:326-328`) makes
the next frame `screen.clear()` (`loop_render.zig:261`), re-blit every pane,
redraw every float border with F-3's full-rect fill, and run
`calcModuleWidth` **and** `drawModule` for up to 48 modules including Lua
evaluation (E-4). vaxis diffs the tty output, but the CPU cost is proportional to
the whole screen regardless of what changed.

**F-9. `drawSplitBorders` is O(lines × screen dimension × panes) per frame.** **[R]**
`borders.zig:209-254`, `:257-304` — for each border line it walks every row (or
column) and re-runs `layout.splitIterator()` over all panes. 20 splits on a
200×50 terminal is ~100 000 hashmap iterations per frame.

**F-10. `key_timers` can accumulate without bound and is scanned linearly on
every keystroke.** **[R/U]**
`keybinds.zig:667-668` parks a fired hold timer with `deadline_ms = maxInt`,
removed only by a matching key release. If releases never arrive (terminal
ignoring `report_events`, or the capability probe timing out) entries leak
permanently, and the list is walked by four functions on every key event.
Trigger condition unverified; the missing bound is real regardless.

**F-11. `pollResize` issues a `TIOCGWINSZ` ioctl every loop iteration.** **[R]**
`host.zig:123-128` via `loop_core.zig:225` — thousands of syscalls per second
during heavy output for a value that changes only on SIGWINCH. Each detected step
also rebuilds both screens (`render_vx.zig:28-38`), ~24 000 allocations for a
300×80 terminal, once per intermediate size during a window drag.

**F-12. `rebuildForReconnect` runs once per pane on reattach, clearing the live
write queue each time.** **[R/U]**
`loop_watchers.zig:343` — with ten panes the 64 KB replay ring is retransmitted
ten times. The pod dedups by `(epoch, seq)` so it is correct, but `clear()`
discards anything queued-but-unflushed, so keystrokes typed between two
`backlog_end` frames can be dropped. Loss window unverified.

*(F-3's segment-buffer aliasing and F-7's stack-escape were also reported
independently as E-3 and E-6 — same defects, found by two separate audits.)*

## G. Cross-cutting

**G-1. The whole SES daemon runs on `page_allocator`.** **[R]**
`server.zig:651`, `state.zig:44` ignore the passed allocator; the GPA created in
`main.zig:212` is never used for anything that outlives it. Every pane name, cwd,
argv entry, hashmap table, and **every per-frame VT queue frame allocation**
(`server.zig:1652`, `:1720`) costs an `mmap`/`munmap` rounded to 4 KiB. The
stated rationale is "GPA is broken after fork", but `run()` is only reached in
the post-fork daemon, so an allocator created there is safe.

**G-2. The terminal frontend also runs entirely on `page_allocator`.** **[R]**
`frontends/terminal/main.zig:219`, `:596`. The codebase already documents that
this caused crashes: `config.zig:48-64` explains that `page_allocator.free()`
panics on a rodata default, which is why the defensive `freeSlice`/`freeOwnedStr`
pointer-identity hacks exist.

**G-3. fd leaks on every error path of `Pty.spawnInternal`.** **[R]**
`pty.zig:66-67`, `:78`, `:82` — no `errdefer` anywhere. A `fork` failure (EAGAIN
under process pressure — precisely when you would retry) leaks 6 fds per attempt.
`abortIsolatedSpawn` also SIGKILLs without a `waitpid`, leaving a zombie.

**G-4. `noteClosedFd` failure is swallowed, re-enabling the double-close it
exists to prevent.** **[R]** `store.zig:598-600`.

**G-5. `srv.stop()` / `state.running = false` are non-atomic writes from signal
handlers.** **[R]** `server.zig:2770-2772`, `frontends/terminal/main.zig:41-45` —
inconsistent with `FrontendAttachState`, which correctly uses
`std.atomic.Value` (`frontend_attach_state.zig:39-48`).

**G-6. VT watcher freed immediately where CTL defers.** **[V]**
`server.zig:1299` calls `allocator.destroy(watch)` inline for a stale CQE, while
the identical CTL case at `:1266` uses `deferDestroyCtlWatcher`. The code's own
comment at `:915-921` states that immediate free "is a use-after-free in
ReleaseFast" and that both channels must share one destruction strategy.

**G-7. `skipBytes` giving up desyncs the stream.** **[V]**
`server.zig:2033` returns having consumed only part of the payload, and every
caller then returns `true` (`:1789`, `:1803`, `:1850`, `:1860`, `:1870`), so the
next read parses payload bytes as a frame header. Should drop the connection.

---

# Part III — Plan

## Phase 0 — Stop the flapping and the daemon-wide stalls it causes — **DONE**

Highest user-visible value; each item is small.

- **0.1 — done.** `connectPodVt` budgets cut from 2000ms connect + 1000ms ack to
  500ms each (`vt_routing.zig`), plus exponential backoff (0/250ms/1s/2s/5s/10s/30s)
  on `needs_backlog_replay` retries (`pane_lifecycle.zig`). A wedged-but-alive pod
  no longer freezes the daemon every second. `Pane.requestBacklogReplay()` now
  owns setting the flag so a stale backoff can never leak into a fresh attach.
  Full non-blocking dial remains Phase 1.
- **0.2 — done.** Queue overflow no longer drops the VT channel. Pod VT watchers
  are disarmed above `MUX_VT_QUEUE_HIGH_WATER` (75%) and re-armed below
  `MUX_VT_QUEUE_LOW_WATER` (50%) from the periodic tick; unread bytes stay in the
  pod socket and the pod falls back to its ring. The residual `QueueFull` path
  drops a single frame with a warning instead of the client's whole channel.
- **0.3 — done.** `maybeReconnectSes` restores the previous identity on the
  `attachFrontend` error path, so a failed attempt can no longer strand the real
  session behind a throwaway UUID.
- **0.4 — done.** `detachSession` releases all client locks; the detach handler
  captures the mux fds first and calls the new `Server.closeDetachedMuxFds` after
  the ack is written (the CTL fd is the connection the request arrived on).
- **0.5 — done.** `flushMuxVtQueues` now closes on a fatal queued-write error,
  symmetric with `flushPodVtQueues`.
- **0.6 — done.** Replay is paced at `BACKLOG_REPLAY_MAX_PER_PASS` (2) dials per
  pass and moved from the 1s cleanup sweep onto the 100ms tick, so a session
  replays in well under a second without stampeding the shared queue.
- **0.7 — done.** VT-only loss with a live CTL now reopens just the data channel
  (`SesClient.reconnectVtOnly`) instead of re-registering and reattaching, and
  `RECONNECT_RETRY_MS` backs off 2s→30s. Two guards proved necessary: the cheap
  path is gated on a successful `sendPing` (a stale CTL fd otherwise lets the VT
  reconnect "succeed" only for SES to drop it), and capped at
  `MAX_VT_ONLY_ATTEMPTS` before forcing full recovery.
- **0.8 — done.** `tryReadControlHeader` waits with `waitReadableTimeout` instead
  of busy-spinning on `WouldBlock`, matching `tryReadMuxVtHeader`.

**Verification — `scripts/smoke_multi_bighistory.py` (new, in `make smoke-heavy`).**
Six panes each accumulate ~1.3MB of backlog *while detached*, then reattach.
Asserts the VT channel is never torn down, exactly one reattach RPC is served,
and the panes stay responsive.

Validated in both directions, per the pty-smoke lesson:

- against unmodified `develop`: **fails** — `vt_channel_drops=1 queue_full=5`,
  no content ever painted. The daemon log shows the exact chain from Part I §2:
  `completeReattach: begin` → `failed to queue MUX VT frame: QueueFull` ×4 →
  `processPendingVtCloses: removing MUX VT`.
- with Phase 0 applied: **passes** — `reattach_rpcs=1 vt_channel_drops=0
  queue_full=0` in ~16s.

Regression run, all passing: `smoke_heavy`, `smoke_heavy2`, `smoke_input_flood`,
`smoke_wedged`, `smoke_input_exactly_once`, `smoke_float`, `smoke_float_session`,
`smoke_reconnect`, `smoke_detach_reattach`, `smoke_attach_stress`,
`smoke_attach_chaos`, `smoke_dot_attach`, `smoke_kill`, plus `zig build test`.

`smoke_heavy` caught the two 0.7 guards above — it failed on daemon-kill recovery
until the ping gate was added, and passes on baseline, which is what identified
the regression as mine rather than pre-existing.

## Phase 1 — Make the SES loop non-blocking — **PARTIALLY DONE**

This is what delivers "independent sessions" — not threads.

**Shipped (`b83e576`):**

- **1.4 — done.** The accept path no longer blocks. The handshake preamble is
  accumulated without blocking (inline attempt first, so a well-behaved peer
  pays no extra latency; anything incomplete moves to a pending list drained by
  the 100ms tick and reaped after 5s). The version gate runs at the two-byte
  boundary so a rejected peer is never waited on for bytes it will not send.
  `smoke_stalled_peer.py` (new): 8 silent peers cost **4.11s** of round-trip
  latency on `develop` (exactly 8 × 500ms) and **0.10s** here — unchanged from
  the idle baseline.
- **1.1 — partial.** `spawnPod` read the handshake one byte at a time with a
  `poll()` + `read()` per byte (~1024 syscalls worst case, all on the event
  loop); it now reads in chunks. The full async-spawn state machine is **not**
  done — a slow pod still blocks the loop for up to `ses_spawn_timeout`.

- **1.3 — done (`bfece8b`).** Resolved the design blocker below by taking
  option (2). `VtStreamReader` allocates the payload buffer **on demand and only
  when a frame is actually split across reads**: a whole frame in one read is
  routed straight out of the existing shared scratch buffer with no allocation
  and no retained state, so steady-state memory is unchanged, while a stalled
  peer costs memory proportional to its own in-flight frame instead of freezing
  the daemon. Also drains up to 32 frames per wakeup (**4.1**) instead of one,
  and `skipBytes` is gone entirely — the payload is always in hand before
  routing, so an unroutable frame is discarded rather than skipped, removing the
  desync-on-give-up path.

  Readers are keyed by fd rather than held on the watcher node, because
  backpressure pause/resume destroys that node and would discard a half-read
  frame. **The subtle part:** the state layer closes pod VT fds directly
  (`connectPodVt`, `detachSession`, `killPane`) with no handle on the server's
  readers, so cleanup also has to hook `processPendingWatcherUpdates`, the queue
  all three funnel through. I shipped that missing briefly and `smoke_heavy`
  caught it — a fullscreen pane went silent after a detach round because a
  reused fd number inherited the previous connection's partial frame.

### Design blocker found in 1.3 — resolved, kept for the reasoning

The plan says to port the `MuxVtReader` pattern to VT routing. That is right in
shape but **under-specified on memory**: a resumable reader must retain a
partial payload across calls, so it needs a per-fd payload buffer. A pod can
emit a frame up to `MAX_FRAME_LEN` (4 MiB) — `processPtyOutput` forwards a whole
PTY read and `io_buf` is allocated at that size — so a naive per-fd reader costs
4 MiB × N pods, and shrinking the buffer silently *skips* oversized frames
(`pod_protocol.Reader` treats over-capacity as skip), i.e. loses output.

Two viable resolutions, both needing a decision before coding:

1. **Bound the pod's output frame size** (e.g. 64 KiB) so SES can use small
   fixed per-fd buffers. Cleanest, but it is a pod-side change and interacts
   with C-10 (pod buffer sizing).
2. **Grow the per-fd payload buffer on demand**, allocating only when a frame is
   actually split across reads and freeing when it completes. Partial payloads
   are rare, so steady-state cost stays near zero. No protocol change.

(2) is the lower-risk path. Note also that the shared 4 MiB `vt_route_buf`
currently works precisely *because* routing is blocking and non-reentrant —
that invariant disappears the moment the path becomes resumable.

- **1.2 — header half done (`aeb8261`).** CTL headers are read resumably via
  `VtStreamReader` (payload length reported as 0, so it yields the moment the
  header is complete and leaves the payload in the socket). This closes the
  cheapest stall vector in the daemon — one byte then silence, repeatable for
  free. Widening the reader's header buffer 8 -> 16 bytes was required
  (`ControlHeader` is 10) and is now pinned by a test, after the mismatch tripped
  the init assert at runtime and took down every frontend.

- **1.2 — done (`8cd0eac`).** The payload half. `handleBinaryCtlMessage` now
  reads header *and* payload in the same resumable pass, then points a
  `PayloadCursor` at the buffered bytes; handlers pull the payload through
  `readPayloadStruct` / `readPayloadInto` / `skipPayloadRest` instead of
  blocking on the socket. The `fd` they still take is now a **reply sink only**.
  This closes the stall vector one level below the header fix: a client that
  sent a valid header and then dribbled its payload froze every session for the
  handler timeout.

  105 call sites across 10 files. **The trap:** `server_cli_layout_handlers.zig`
  looks like the other eight `server_*_handlers.zig` files and has the same
  handler signature, but it is reached only from `handleCliRequest` — the
  short-lived accept path, which never populates the cursor. Converting it (as a
  blanket sweep does) broke every CLI request; `smoke_kill` and
  `smoke_attach_chaos` caught it. The two groups now have *opposite* I/O
  contracts, documented in that file's header. Four handlers inline in
  `server.zig`'s own switch also had to be converted — a sweep over the sibling
  files misses them, and `pane_info` desynced the stream until it was.

- **1.5 — done (`7de5b22`).** Non-blocking CTL replies. Replies used to go out
  through `wire.write*Timeout`, which polls until the socket accepts them, so a
  client that stopped READING its CTL socket cost the daemon up to 500ms per
  reply — with every other session frozen for it. Replies now serialize into a
  bounded per-fd `CtlOutQueue`: whatever the socket takes is written inline, the
  remainder drains from the periodic tick next to the VT queues, and nothing on
  the loop waits for a peer. The 3 + pane_count separate bounded writes of the
  reattach response collapse into one queued frame.

  Three invariants carry the correctness: **ordering** (once anything is queued
  for an fd, later replies must queue too, or they overtake the pending bytes
  and desync the peer), **whole frames** (a frame is queued entire, never
  half-written and abandoned), and **fd lifetime** — the queue is dropped in
  `dropCtlReader` alongside the read-side reader, because unsent bytes
  outliving a connection would be prepended to whatever new client reuses the
  fd number. `processPendingCtlCloses` flushes once before closing, since
  reply-then-close is common.

  `smoke_wedged_ctl_reader.py` (new): 16 peers that complete the handshake and
  then never read. Round-trip latency in a live pane is **2.35s on the unfixed
  daemon vs 0.03s here** (idle baseline 0.06s). Getting this test honest took
  three attempts — see the note below.

  **Not converted:** `notifyPaneExitedBestEffort` in `pane_lifecycle.zig`. It
  runs in the STATE layer, which has no `*Server` handle, and threading one in
  reaches much wider than the queue is worth. It was already non-blocking
  (`poll` with a 0 timeout), so it is not a stall vector; its actual defect — a
  partial write abandoning half a frame and desyncing the peer — is fixed in
  place with a 50ms completion budget.

### Lesson: a stall test that does not stall proves nothing

The first two versions of `smoke_wedged_ctl_reader.py` PASSED against the
unfixed daemon. Both were wrong for the same reason — they never actually
filled SES's send buffer:

1. Shrinking the peer's `SO_RCVBUF` does nothing, because AF_UNIX charges
   queued bytes to the **sender's** buffer, not the receiver's.
2. Sending a fixed burst until the peer's own send buffer filled produced only
   ~5KB of replies, against a ~208KB default `SO_SNDBUF`.

What works: flood from background threads so the stall **overlaps** the
measurement. On the unfixed daemon each wedged peer costs exactly ONE 500ms
stall — the reply write times out and `replyOrClose` then drops the connection —
so the freeze scales with the number of peers, and measuring after the flood
misses it entirely. The test also now asserts a pong actually comes back before
relying on pings for pressure, and asserts a floor on outstanding reply bytes,
so it fails loudly instead of silently proving nothing.

**Still open:** the rest of 1.1 (the async spawn state machine; the
byte-at-a-time read is fixed but a slow pod still blocks the loop for up to
`ses_spawn_timeout`).

`VtStreamReader` is directly reusable for 1.2: the CTL header is a fixed 10
bytes with the payload length in it, exactly the shape it already handles.

- **1.1** Asynchronous pod spawn — **analysed, NOT implemented; needs a
  decision, see below.** The byte-at-a-time read is already fixed; what remains
  is the inline handshake wait in `pane_spawn.zig`.

### 1.1 design fork — why this one stopped for a decision

Measured cost first, because it reframes the priority: a real spawn takes
**~16ms** end to end (`create_pane` 23.923 -> `spawnPod` 23.925 -> pod started
23.938 -> pane created 23.941), bounded by `ses_spawn_timeout` = **2s** worst
case. That is far smaller than the stalls already removed in 1.2/1.4/1.5 (500ms
per CTL read AND per reply, plus unbounded reattach writes).

Blast radius is small — only two SES-side callers of `createPane`
(`handleBinaryCreatePane` and `layout_apply.zig:69`) — but `layout_apply`
creates panes in a LOOP and consumes each pane immediately to build the tree, so
it cannot simply defer; making spawn async forces layout-apply to become a state
machine too.

The tempting shortcut is to not wait for the handshake at all: the pod already
dials back into SES on its own CTL uplink and reports its shell pid via
`fg_changed` within milliseconds, so `child_pid` could be filled in there. Two
things make that a bigger change than it looks:

1. `paneProcessDead` is `!isPidAlive(child_pid) or !isPidAlive(pod_pid)`, and
   `isPidAlive` returns false for pid 0. An unknown child pid therefore reads as
   *dead* and the fresh pane gets swept. Needs `child_pid` to become explicitly
   optional, plus a spawn-grace guard. (No `kill(0, ...)` process-group hazard —
   `isPidAlive` goes through `/proc` — but the sweep hazard is real.)
2. **The semantic cost is the actual blocker.** The synchronous handshake is
   what makes spawn *failure* reportable: today a pod that never starts fails
   the `create_pane` request. Deferring it means replying `pane_created`
   optimistically and discovering the failure afterwards, when the client has
   already been told the pane exists. That is a user-visible downgrade in error
   reporting, traded for ~16ms of loop time.

Options, cheapest first: (a) leave it — 16ms typical is not the bottleneck;
(b) keep the wait but cut the 2s worst case, bounding the pathological stall
without changing semantics; (c) full async spawn + async layout-apply.

**(b) is done.** `ses_spawn_timeout` 2000ms -> 500ms, chosen from measurement
rather than a round number: over 10 spawns on a box at load ~58/24 cores the
handshake took **min 15ms, median 22ms, max 31ms**, so 500ms keeps ~16x headroom
over the observed maximum while cutting the worst-case freeze 4x. It also lines
up with `HANDLER_IO_TIMEOUT_MS`, the established bounded-stall budget elsewhere
in the daemon. Overshooting now fails ONE `create_pane` with a visible
`create_failed` the user can retry, instead of freezing every session for 2s
invisibly.

### 1.1(c) — DONE (`1920fba` + `d3d6585`)

Landed in two commits so each could be verified on a green base:

1. **`refactor(ses): split pod spawn from its handshake read`** — `startPodSpawn`
   forks and returns; `pollPodHandshake` reads without blocking. The
   synchronous `spawnPod` is kept verbatim on top of the two for
   `layout_apply`, which builds a tree from panes it consumes immediately.
   Behaviour-preserving, verified alone.
2. **`perf(ses): create panes without blocking on pod spawn`** — the deferred
   half: `beginCreatePane` / `finishCreatePane` / `abortCreatePane`, a
   `pending_spawns` list drained from the periodic tick, and `replyDeferred`.

**Semantics are unchanged.** Deferring the REPLY rather than the pane keeps
spawn-failure reporting intact: the client still learns the outcome on its own
`create_pane` request, one tick later. Only the shortcut variant (never waiting
for the handshake, replying optimistically) trades that away, and it was
avoided.

**A 40ms inline grace period is why this is not simply tick-driven.** Measured
spawns take 15/22/31ms while the tick fires every 100ms, so unconditional
deferral would have made every split *feel* ~50ms slower to fix a stall nobody
notices. 40ms sits just above the observed maximum: the common case completes
inline at its old speed, only a genuinely slow pod defers, and the worst-case
loop stall is now **40ms** — against 500ms after (b) and 2s originally.

**The verification that mattered.** The full suite passing with the 40ms grace
proved little, because at 15-31ms almost every spawn completes INLINE and the
new deferred code never runs. Re-running the whole suite with the grace clamped
to **0**, forcing every spawn through the tick-driven path, is what actually
exercised it. Same trap as the four regression tests that initially passed
against unfixed code: a green suite that never entered the new branch.

That forced run did surface one red — `smoke_attach_stress` round 10, "stolen
frontend did not exit", a symptom not seen before. It looked like a real
consequence of the new window in which a requesting client can vanish
mid-spawn. It was not: forced-async passed **3/3** on re-run, the shipping
config **3/3**, and the pre-1.1(c) BASELINE failed **1/3**. `attach_stress` is
itself load-flaky here, like `attach_chaos`. Worth noting the reasoning that
nearly went wrong — "grace=40 hides it, so don't ship" would have been right IF
the window were real, since a slow pod reopens it; the three-way comparison is
what distinguished a real window from a flaky test.

Kept for reference — what the change involved:

**Split `pane_creation.createPane` at the `spawnPod` call** (`pane_creation.zig`
line ~23 — everything above is preparation, everything below needs `child_pid`):

- *Begin*: client check, uuid, unique name, pod socket path, fork the pod. Needs
  a new `pane_spawn.startPodSpawn` returning `{pod_pid, stdout_fd}` without
  reading the handshake.
- *Pending state* to carry across the boundary: `client_id`, `uuid`, owned
  `name` and `pod_socket_path`, `pod_pid`, `stdout_fd`, owned `sticky_pwd`,
  `sticky_key`, a deadline, and the deferred reply `(fd, request_id)`.
- *Complete*: parse the handshake for `child_pid`, build and insert the Pane,
  `connectPodVt`, `client.appendUuid`, then send `pane_created`.

**The parts that will bite:**

1. **Ownership.** `name` and `pod_socket_path` are heap-allocated before the
   spawn and currently freed by `errdefer` on any failure below. Once those
   failures move to a later tick, the pending record owns them and every exit
   path — timeout, bad handshake, dead client — must free them exactly once.
2. **Orphaned pods.** The existing `errdefer` reaps the forked pod if insertion
   fails. The timeout path must do the same (`podPidMatchesPane` then SIGTERM),
   or a slow pod becomes a permanent orphan holding a pty and a shell.
3. **The reply fd may be gone.** Validate `(fd, request_id)` against the
   closed-fd log before replying, exactly as the CLI waiter path does — an fd
   number is reused aggressively here.
4. **`layout_apply` must keep the synchronous path.** It creates panes in a loop
   and consumes each immediately; converting it is a separate, larger change.
   Keep `createPane` as-is for it and add the async path alongside, rather than
   converting the one function both callers share.

**Semantics stay intact** if the REPLY is what defers: spawn failure is still
reported on the `create_pane` request. Only the shortcut variant — never waiting
for the handshake — trades that away, and that is the variant to avoid.

**Correction to the earlier writeup of (c):** I described it as "accepting
optimistic `pane_created`", but that cost applies only to the *shortcut* variant
that never waits for the handshake. A proper deferred-REPLY state machine — hold
`(fd, request_id, fd generation)`, finish the pane when the handshake lands,
reply then — preserves spawn-failure reporting exactly. So (c)'s real cost is
implementation complexity plus making `layout_apply` async (it creates panes in
a loop and consumes each immediately), not error semantics. That is the honest
framing for whoever picks it up.
- **1.2** ~~Resumable non-blocking CTL reader~~ — **done**, header and payload.
- **1.3** Same for VT routing; makes `skipBytes` unnecessary and fixes G-7.
- **1.4** Deferred, non-blocking handshake dispatch in `dispatchNewConnection`,
  with a reaper timer for connections that never complete.
- **1.5** ~~Non-blocking CTL replies~~ — **done**.

**Verification:** SIGSTOP one frontend mid-frame and assert a second session's
round-trip stays under ~50 ms; create panes in session A in a loop while
measuring session B's keystroke echo latency.

### Heavy smokes: attributing failures on a loaded box

After the pod work I ran `smoke_heavy`, `smoke_heavy2` and
`smoke_multi_bighistory` back-to-back and all three FAILED — including
`multi_bighistory` with "pane 1 shell never became ready", which is exactly the
signature a too-tight `ses_spawn_timeout` would produce. It would have been easy
to blame the 500ms change and revert it.

A three-point attribution says otherwise. Running `multi_bighistory` alone with
a clean scratch dir at each point:

| point | tree | result |
|---|---|---|
| A | working tree (C-4 + C-1 + **500ms**) | PASS |
| B | HEAD `c0688e4` (C-4 + C-1 + 2000ms) | PASS |
| C | `f1c74c7~1` (before the pod work) | PASS |

So the failures came from running three heavy smokes back-to-back on a box at
load ~63/24 cores, not from any code change. Two rules this reinforces: run
heavy smokes **one at a time with a fresh scratch dir**, and attribute a red run
to a specific commit before believing it — the failure signature can point
convincingly at the wrong culprit.

### Open finding: `smoke_attach_chaos` "daemon died and stayed dead"

Seen during the post-1.5 suite run and **not caused by it** — the same seed
(`HEXE_STRESS_SEED=2792088`) fails on the pre-1.5 build too. Evidence that it is
load-dependent rather than a logic bug tied to a code change:

- Same seed, pre-1.5 build: fails at round 5. Same seed, post-1.5 build: failed
  at round 3 once and round 5 on the next run. The failure round is not stable,
  so it is not determined by the seed.
- Plain daemon-kill recovery in isolation is clean: **12/12 rounds** of
  SIGKILL-then-reconnect brought the daemon back every time.
- The box is running at load average ~60 on 24 cores from unrelated tenants
  (qemu, rustc, rush), i.e. 2.5x oversubscribed. The check allows a 25s
  reconnect plus a 3s grace before declaring the daemon dead.
- **Rate measured: ~1 failure in 5** (4 pass / 1 fail over 5 consecutive runs),
  at a varying round each time.

**It also nearly cost a good change.** The first run containing A-5 (verify the
server's uid on connect) failed this smoke, and a 3-vs-3 A/B came back 1 fail
with A-5 against 0 without — enough to look like a regression in a security
change that touches every connect path. Pass rates at n=3 cannot separate a 20%
flake from a real fault. What settled it was a **mechanism** test rather than a
statistical one: A-5 can only break a connection by *refusing* it, and every
refusal logs "refusing to connect ... owned by another uid". Across 5 runs
(including the failing one) there were **zero** such messages, so A-5 cannot
have caused it. Prefer a signal that is causally tied to the change over a pass
rate whenever the test is known to be flaky.

So it needs the other chaos operations (kill/steal/abort) interleaved AND a
loaded machine. Worth chasing on a quiet box before assuming a product bug;
`acquireInstanceLock()` returning silently when the lock is held is the first
thing to instrument, since a losing daemon exits with no diagnostic at all.

## Phase 2 — Security and containment — **DONE**

Independent of the performance work; A-1 through A-4 are the priorities.

**Shipped (commit `a6945b9`):**

- **A-1 / A-2 — done.** Project `.hexe.lua` now loads via
  `LuaRuntime.loadProjectConfig`. Untrusted files execute in a runtime with
  `io`, `package`, `dofile`, `loadfile`, `load`, `debug` and `hexe.exec`
  removed, `os` reduced to clock/formatting helpers, and `require` limited to
  `"hexe"`. Explicit safe mode also revokes now, so the
  `HEXE_UNRESTRICTED_CONFIG` opt-out no longer leaves `/bin/sh` reachable via
  `hexe.exec`. Regression tests both ways in `session_config.zig`
  ("sandboxes an UNTRUSTED project file" / "keeps full capabilities for a
  TRUSTED project file"); verified the first fails with the gate disabled.
- **A-7 — done.** `loadProjectConfig` reads the file once and both hashes and
  executes those same bytes (`trust.bytesAreTrusted`, `loadConfigBuffer`),
  closing the verify-vs-execute window.
- **A-12 — done.** `allowNewPane` is now called from `handleBinaryCreatePane`,
  so `max_panes_per_session` / `HEXE_MAX_PANES_PER_SESSION` actually apply.
- **A-4 — done.** `memory`/`cpu`/`pids` reach the pod as `HEXE_CGROUP_*` via the
  spawn env (no protocol change needed — `spawnPod` already overlays caller
  env). Producer and consumer now exist in the same tree.
- **A-3 — partial.** `--isolated` maps to the `default` voidbox profile instead
  of setting the inert `HEXE_POD_ISOLATE=1`. `src/core/isolation.zig` is still
  dead code (~400 lines, no call sites, not exported from `mod.zig`) — deleting
  it is left as an explicit call for the maintainer rather than done unilaterally.
- **Docs.** `docs/isolation.md` claimed dropped capabilities and a contained
  fork bomb. Both corrected, plus a new **Known gaps** section covering A-9
  (`cap_drop = ""` makes the drop a no-op), the dead module, and A-10 (unknown
  profiles silently downgrade).

**A-5 — done.** `Client.connectTimeout` now calls `verifyPeerUid` on the
CONNECTED socket before a single handshake byte is sent. The check existed only
on the accept side, so nothing verified who we had connected *to*; combined with
the `/tmp` socket-directory fallback (A-6) another local user can bind
`ses.sock` first, the real daemon then fails with `AddressInUse`, and every
frontend and CLI hands its session traffic — keystrokes included — to whoever
got there first. Doing it in `connectTimeout` covers every connect path at
once. `HEXE_ALLOW_CROSS_UID=1` remains the deliberate escape hatch.

**A-11 — done.** `sanitizeInstanceName` now rejects names made only of dots.
`strings.sanitize` maps `/` to `_`, so a separator could never get through, but
it deliberately keeps `.` — leaving `HEXE_INSTANCE=..` free to place an
instance's sockets, state and logs one directory ABOVE their namespace (and `.`
to collide with the un-namespaced default). Returning empty makes callers fall
back to the plain path, exactly as an unset variable does. Unit-tested both
ways, including that a dot inside an ordinary name (`my.instance`) still works.

**A-8 (env half) — done.** `pty.buildEnv` now strips
`HEXE_TRUST_ALL_PROJECTS`, `HEXE_ALLOW_CROSS_UID` and
`HEXE_UNRESTRICTED_CONFIG` from the environment handed to pane shells. These
exist so an operator can loosen hexe's own checks; inherited by everything a
pane runs, they silently loosened them for anything that re-entered hexe from
inside a pane — including a `.hexe.lua` that would otherwise be sandboxed.
*Still open in A-8:* binding trust entries to a realpath (`<realpath>\t<hash>`).

**A-9 — satisfied via the documented option.** The finding's fix is "populate
`cap_drop`, **or** correct the docs", and `docs/isolation.md` now states plainly
under **Known gaps** that capabilities are not dropped, why (`cap_drop = ""`
makes libvoid's `caps.apply` return early), and that `no_new_privs` *is*
applied. Actually populating `cap_drop` is safe ordering-wise — libvoid applies
caps in `process_exec.zig` pre-exec, after mounts — but it fails closed
(`capset` errors abort the spawn) and **no smoke exercises an isolated pane at
all**, so shipping it would be a blind change to the spawn path of a
security-sensitive feature. Left as deliberate follow-up, with the prerequisite
being a smoke that spawns an isolated pane.

**A-10 — done.** Unknown isolation profiles no longer downgrade silently: the
SES boundary parses the profile with `isolation_voidbox.parseProfile` and
rejects anything unrecognised with `unknown_isolation_profile`.

  **The near-miss worth recording.** My first attempt defined the enum as
  `{minimal, balanced, sandbox, full}` — the four names `getIsolationOptions`
  matches — and "hardened" the fallthrough branch to the STRICTEST profile. Both
  were wrong. The vocabulary the CLI actually advertises is
  `none|minimal|default|balanced|sandbox|full` (`mux_float.zig`), and `default`
  is a **real profile** — the config default — that deliberately maps to the
  fallthrough's middle-strength options. Shipping that would have rejected
  legitimate `none`/`default` requests *and* silently given every
  default-isolated pane full network isolation it never asked for. Checking the
  callers, not just the function being changed, is what caught it.

**A-14 — done.** The connection rate limit was global (60/min) and applied at
accept, before SES knew who was connecting. Every pod redials from its own ~1s
tick, so a daemon restart with a dozen panes saturated the window in seconds and
SES then rejected the user's attach and every CLI command — the pods win that
race because they retry automatically and a human does not. The check is now
split: the hard concurrent-connection ceiling still applies at accept (cheap,
and safe before identification), while the per-minute RATE applies in
`dispatchWithPreamble` to interactive channels only, with POD channels exempt.
`smoke_rate_limit_attach.py` (new) opens 90 POD_CTL connections against a 60/min
budget and then requires an ordinary CLI command to still work.

### New finding (2026-07-29): CLI reports failure but exits 0

Found while diagnosing A-14, not from reading code. With SES refusing
connections, `hexe ses list` prints

    Error: failed to handshake with ses daemon: RuntimeEpochMismatch

and still **exits 0**. Any script or CI step that checks the exit status treats
a total failure to reach the daemon as success. It also made the first version
of `smoke_rate_limit_attach.py` pass against the unfixed daemon, since that test
keyed on the exit code plus the word "overload".

Two things to fix: propagate a non-zero exit status from the CLI's connect and
handshake failures, and make the refusal reason survive to the user — SES sends
a structured `error` frame ("server_overloaded: connection rate limit
exceeded"), but the client reports the generic epoch mismatch it hits next,
which points at the wrong cause entirely.

**A-13 — done (counter half).** The connection cap read
`stats.active_connections`, refreshed at most once every 5s from
`clients.items.len` — i.e. REGISTERED clients only — so anything accepted but
not yet registered was invisible and a burst could blow straight past
`max_connections`. It now uses a live count derived from
`ctl_watchers + vt_watchers + pending_handshakes`.

  **Derived, not incremented, on purpose.** A hand-maintained counter that
  missed one close path would drift upward forever and eventually refuse every
  connection — a worse failure than the bug, and one that only appears after
  hours of uptime. Deriving it from the maps that already own those fds cannot
  drift.

  **The break this nearly caused.** Counting every fd instead of registered
  clients changes what the number MEANS: SES holds two connections per pane
  (pod CTL uplink + pod VT) plus two per frontend, so a 30-pane session already
  sits near 62 — against a ceiling of 64 that was sized for *clients*. Shipping
  the count change alone would have started refusing connections at roughly 32
  panes. Added a separate `Limits.max_connections = 512` (~250 panes) and left
  `max_clients = 64` for its original meaning. Verified against the many-pane
  smokes rather than assumed.

  *Still open in A-13:* the idle timeout for established-but-unregistered
  connections. The 5s pending-handshake reaper (1.4) covers the peer that never
  handshakes; a peer that handshakes and then goes quiet forever is not yet
  bounded.

**A-6 — done (the exposure half).** Two changes:

- **The debug log left `/tmp`.** `getLogPath` hardcoded
  `/tmp/hexe/<instance>/log`, ignoring XDG entirely, in a world-writable
  directory created with a bare `makePath` — and that file records cwds,
  command lines and pane metadata. It now follows `XDG_STATE_HOME` (then
  `~/.local/state`), with `/tmp` only when there is no HOME at all.
- **Directories are verified before use.** New `ensurePrivateDir` creates the
  path, then opens it and checks the *fd* — directory, owned by us, and
  tightened to 0700 if it is group/world writable. Checking the fd rather than
  the name closes the TOCTOU window that checking-then-using leaves open. It
  guards both the log dir and the socket parent dir.

  The check is deliberately asymmetric: a directory owned by *someone else* is
  the actual attack and hard-fails, while merely loose permissions on one we own
  are tightened, or warned about. Hard-failing on a umask quirk would brick the
  daemon for no security gain.

`smoke_log_not_in_tmp.py` (new): PASS with the fix, and on baseline FAIL —
"debug log was written to world-writable /tmp". A unit test covers
`ensurePrivateDir` accepting a directory we own (idempotently) and refusing a
non-directory.

### Bug found by 1.1(c), fixed: a steal could resurrect a frontend

Making pane creation asynchronous opened a window that did not exist before.
`finishCreatePane` guards `getClient(client_id)` -> `ClientNotFound`, which
covers a client that is GONE. A **steal** is different: `forceDetachWithPurge`
moves the session away but leaves the old client alive and merely paneless. So a
`create_pane` still in flight completes a tick later, `getClient` succeeds, and
the pane attaches to the OLD client — a frontend that was supposed to exit is
holding a pane again. Synchronously this could not happen: the pane always
existed before a steal could begin.

`cancelPendingSpawnsForClient` hooks `purgeClientFdState`, the funnel every
session-takeover path already goes through, and fails those spawns with
`session_taken_over`.

**How this was nearly missed.** The symptom ("stolen frontend did not exit")
first appeared in the forced-async run; I hypothesised this exact window, then
DROPPED the hypothesis when a 3-vs-3 pass-rate A/B came back clean on a
load-flaky test. That was the wrong instrument — it measured whether the test
went red, not whether the mechanism could occur. Seeing the same distinctive
symptom a second time forced re-deriving it from the code, which settles it
regardless of pass rates.

A 10-run A/B at grace=0 did NOT reproduce the symptom either way, so the guard
is **not** justified by test evidence — it is justified by the code path being
reachable and producing a wrong result when taken. Worth stating plainly rather
than claiming a fix the runs do not support. Equally, shipping grace=40 because
it makes the window rare would have been hiding a bug behind a timing constant:
a slow pod reopens it.

**A-6's socket half — done too.** On re-examination the safe scope was much
narrower than "relocate the socket directory": when `XDG_RUNTIME_DIR` is set —
every normal system — nothing moves, so there is no migration at all. Only the
FALLBACK changes. `getSocketDir` now prefers `/run/user/<uid>` (the directory
that variable normally points at, created 0700 and owned by us on any logind
system, verified by `fstat` before use) and reaches for world-writable `/tmp`
only if that is genuinely unavailable.

This narrows exposure rather than being the whole defence: sockets bind through
`makeSocketParentPath` -> `ensurePrivateDir`, which already refuses any
directory we do not own, so a pre-created or symlinked `/tmp/hexe` fails closed.
The change simply stops us reaching for `/tmp` when a private runtime dir exists.

Two tests: the fallback picks `/run/user/<uid>` when it exists and is ours, and
a worst-case path-length check (24-char instance + 32-hex pod socket) stays
inside the 108-byte `sockaddr_un` limit — the specific hazard that made this
look risky. Also verified live with `XDG_RUNTIME_DIR` unset.

**A `pgrep` trap worth knowing (found while writing the A-6 smoke).** A daemon
started by hand has `session daemon ...` in its argv; one autostarted by a
frontend has `ses daemon ...` (`frontend_client.zig` appends `"ses"`). A smoke
grepping for `"ses daemon --instance"` therefore silently matches NOTHING for a
manually started daemon and reports "the daemon did not start". Match on
`"daemon --instance"` to cover both. `smoke_attach_chaos` happens to be correct
today only because its daemon is always frontend-autostarted — which is a
coincidence its checks depend on, not a property they assert.

**A-8 — done (both halves).** Ledger lines are now `<sha256-hex>\t<realpath>`.
A bare hash trusts CONTENT anywhere, so allowing one repo's `.hexe.lua` silently
blessed a byte-identical file in every other checkout you opened. `allow` records
the canonical realpath (so `./x`, `../dir/x` and a symlink cannot bind the same
file twice), and the check requires both hash and path to match.
`bytesAreTrusted` became `bytesAreTrustedAt(path, bytes)` — the byte-based entry
point still exists to keep the TOCTOU-free read-once-then-verify property, it
just needs the path too.

  **Legacy entries are refused, not grandfathered.** Honouring old bare-hash
  lines would leave exactly the hole A-8 describes open forever. They are
  detected though, and produce a warning naming the file and telling the user to
  re-run `hexe allow` — the failure is fail-SAFE (hooks stop running) and
  actionable, rather than silent. Two unit tests pin this: identical content at
  a second path is not trusted, and a legacy path-less entry grants nothing
  until re-allowed.

**A-13 — done (both halves).** The idle timeout landed too:
`reapUnregisteredCtl` reclaims frontend CTL connections that completed a
handshake and then never sent `register`, after a deliberately generous 120s
(a real frontend registers in milliseconds).

  **The scoping is the whole risk.** Idleness alone must NEVER close anything:
  a registered frontend can sit silent for hours while its user is away, and
  reaping it would kill live sessions. Only the *absence of a client record*
  qualifies. Pod uplinks share `binary_ctl_fds` but are never registered as
  clients, so they are excluded explicitly — safe because `pane.pod_ctl_fd` is
  assigned before the fd enters that map, leaving no window where a live pod
  looks unregistered. A unit test pins that a stale entry is reclaimed and a
  fresh one is spared.

**Still open in this phase:** only A-6's socket-path relocation — a migration
question rather than a hardening one, since it changes where running sessions
live and risks the 108-byte `sockaddr_un` limit.

**Note — `smoke_float_content` is flaky, pre-existing.** It fails roughly 1 run
in 3 on unmodified `develop` as well (measured 3x each side). Do not read a
single failure of it as a regression; it is worth stabilizing, and it is exactly
the class of false failure the pty-smoke harness is known for.


- **2.1** Close the trust-ledger bypass (A-1) and gate `hexe.exec` (A-2). Fix the
  TOCTOU (A-7) by hashing the parsed bytes, and bind trust to a path (A-8).
- **2.2** Resolve the isolation gap (A-3, A-4): either wire the implementation in
  or delete it and correct `docs/isolation.md`. **Shipping docs that promise
  containment which does not exist is the worst of the three options.**
- **2.3** Path hardening (A-6), client-side UID verification (A-5), instance-name
  validation (A-11).
- **2.4** Enforce the resource caps that already exist (A-12, A-13) and fix the
  rate-limiter livelock (A-14).

## Phase 3 — Correctness backlog — **PARTIALLY DONE**

**Shipped (`ab1f531`, `9becc05`):**

- **F-1 — done.** `handleFocusedInputLoop` no longer returns after forwarding
  one event. Reproduced on `develop` with `smoke_input_batch.py` (new): a line
  of non-Latin-1 text sent as one write lost everything after the first
  codepoint > 0xFF, because those never map to a BindKey.
- **D-1 — done.** Blocked CLI waiters now record which frontend owes them an
  answer and are released when it dies — answered (`allow = 1` / a failed
  float result), not merely closed. `smoke_cli_waiter_release.py` (new) hangs
  for the full 25s timeout on `develop` and clears in 0.0s here.
- **E-2 — done.** `hexe.exec()` returned the internal cache table; fixed by
  removing that table by index rather than with a deferred `pop`. Added a
  deterministic shape test (verified it fails when the bug is reintroduced).
- **F-2 — done.** `passesWhen` is now called from `drawModule` and
  `calcModuleWidth`, which were discarding the `PaneQuery` built three lines
  above them expressly "for condition evaluation".
- **B-2 — done.** `tab_visible` is shifted alongside `parent_tab` at all three
  tab insert/remove sites, with unit tests for the mask shifts.
- **F-6 — done.** `resizeVaxisForSize` carries `width_method` (and cursor/mouse
  shape) across the screen rebuild.
- **G-6 — done.** `vtWatcherCallback` defers the stale-watcher free instead of
  destroying inline, matching CTL and the rule stated in
  `processPendingVtCloses`.
- **G-7 — done.** `skipBytes` returns success; a partial skip now drops the
  desynced connection instead of leaving every later frame to be parsed as
  garbage.

**Flaky smokes found along the way** — all fail on unmodified `develop` too, so
do not read a single red run as a regression:

| Smoke | Observed rate on `develop` |
|---|---|
| `smoke_float_content` | ~1 in 3 |
| `smoke_startup_chooser` | ~1 in 6 |
| `smoke_kill` | occasional `FileNotFoundError` racing `ses_state.json` |
| `smoke_heavy2` | occasional "expected >=8 pods, got 7" (random seed) |

`smoke_startup_chooser` additionally does **not** isolate `XDG_CONFIG_HOME`, so
it loads the developer's personal `~/.config/hexe/init.lua` and its result
depends on that file. Worth fixing before trusting it as a gate.

### The suite leaks, and that is the real source of "flakiness"

After a few hundred smoke runs this machine held **63 orphaned `hexe`
processes**, **334 directories under `/tmp/hexe-smoke`** (106 MB), and **229
stale instance directories** under `$XDG_RUNTIME_DIR/hexe`.

Separately — and this is the bigger confound — the box was carrying a load
average of ~37 from *unrelated* tenants (several qemu VMs, `rustc`/`cargo`, and
several `codex` processes). Under that load `smoke_heavy2` failed
*consistently*, including on untouched `origin/develop`, which is the controlled
comparison that established it was not a regression. Earlier in the same session
it had passed repeatedly.

**Later in the same session this was demonstrated directly.** With 39 leaked
`hexe` processes present, `smoke_heavy2` failed **2/2 on untouched
`origin/develop`** ("other tab unresponsive", "expected >=8 pods, got 7"). After
`pkill`-ing the leaked processes and clearing the scratch dirs, the *same* smoke
passed on the working tree. Nothing in the code changed between those runs.

That is the clearest possible statement of the problem: **the suite's own leaks
make it fail, and the failure mode is indistinguishable from a product bug.**
Anyone bisecting against it will chase ghosts — I did, twice.

Two consequences worth stating plainly:

- **The flakiness rates in the table above are not trustworthy in absolute
  terms** — they were measured under varying ambient load. What they do
  establish is the *relative* result: each of those smokes fails on unmodified
  `develop` under the same conditions.
- These pty smokes are timing-sensitive enough that a loaded machine
  manufactures failures. They need either generous, load-aware budgets or a
  dedicated runner before they can gate anything.

This matters more than any individual flaky test: **a leaking suite manufactures
failures that look exactly like product bugs**, and it gets worse the longer you
run it. Every `cleanup()` in these scripts terminates the processes it spawned
directly, but pods and daemons reparented away from the test's process group
survive, and no script removes its scratch or runtime directory.

**Root-caused and fixed (`05c6ebe`).** Two causes, both silent:

1. `pgrep -f "--instance smkNNN"` — the pattern begins with `--`, so **pgrep
   parses it as an option** and exits with "unrecognized option". `cleanup()`
   therefore matched nothing and killed nothing, on every run, without a word.
2. `cleanup()` ran only on the success path and inside `fail()`, so any
   unhandled exception or `timeout` kill skipped it entirely.

All `pgrep` calls now pass `--` before the pattern, `cleanup()` is registered
with `atexit`, and a SIGTERM handler exits via `sys.exit` so `atexit` still
fires. Added `make smoke-clean` (a dependency of `smoke` and `smoke-heavy`) for
leftovers from older runs or hard SIGKILLs.

Verified: a successful run and a run killed mid-flight both leave **zero** hexe
processes; five consecutive smokes leave zero.

Remaining hygiene, not yet done:

1. Remove `$HEXE_SMOKE_TMP/<instance>` and `$XDG_RUNTIME_DIR/hexe/<instance>`
   per script on exit (currently only swept wholesale by `make smoke-clean`).
2. Isolate `XDG_CONFIG_HOME` in `smoke_startup_chooser`.
3. **Re-measure the "flaky" list above on a clean, idle machine.** Those rates
   were all taken while the suite was leaking, so most of them are suspect.

   I could not do this re-measurement here: with the leak fixed and **zero**
   hexe processes present, this box was still carrying load 150-230 from
   unrelated tenants (several qemu VMs, `rustc`/`cargo`, `codex`, `forge`), and
   `smoke_float_content` failed 3/3 under it. That is an environment result, not
   a code result. These pty smokes need either load-aware budgets or a dedicated
   runner before any of their rates mean anything.

**Also shipped (`c1c3aee`):**

- **C-1 — partial.** `hexe pod attach` now sends the required 16-byte
  `(epoch, seq)` prefix on INPUT frames, so keystrokes are no longer dropped by
  `applyInputFrame`'s length check (and no longer poison the pod's dedup state).
  Verified against the protocol contract, not end to end — `pod new` holds the
  foreground, which makes a scripted harness disproportionately costly. **Still
  open:** it also *evicts* SES's VT client, because `acceptVtClient` closes the
  existing client unconditionally; a non-destructive attach needs its own
  handshake class (aux observer for output + a persistent aux input channel),
  which in turn needs `handleAuxInput` to stop being one-frame-and-close (C-11)
  and to move off the blocking accept path (C-4).
- **C-2 — done.** A back-pressure-paused PTY resumes for any consumer, not just
  a VT client.
- **C-3 — done.** Observer replay and broadcast use bounded writes, so
  `hexe pod record` no longer dies at the first EAGAIN.

**Also shipped (`47fa903`):**

- **E-1 — done.** `evalLuaBuiltinDesc`'s six `raiseError()` calls run after
  `beginLuaEval` returned, with no `pcall` frame, so they reached Lua's default
  panic function and `abort()`ed the frontend. They now warn and fall back to
  the field's default. Verified by construction: I could not build a config that
  reaches this path from outside (the new `smoke_bad_config` case still passes
  with the `raiseError` reintroduced), so that case only adds coverage that
  builtin-descriptor configs degrade cleanly.

**Also shipped later:** B-3 (`active_tab` not shifted when a collapsed tab is
removed — focus silently moved to a different tab), B-5 (`kill_session <name>`
destroyed an arbitrary session on a name collision), B-9 (uuid slices handed out
shorter than their allocation, then freed at the wrong length), B-10 (a pod
orphaned forever if pane creation failed after the fork), B-11 (`TxEntry`
written to disk with compiler-chosen layout and uninitialised padding), C-5
(unvalidated skip length — one bad header made a pane permanently deaf), C-6
(a ≥4 MiB paste emitted an oversized frame that cost the frontend its whole VT
channel), C-11, G-3 (fd leaks on every `Pty.spawnInternal` error path), and D-14
(CLI failures exiting 0 — worst case `popup confirm` returning "yes").

All of these carry deterministic unit tests, chosen deliberately: the pty smokes
were unusable while this box sat at load 150+, so unit tests were the only
trustworthy signal available.

**C-4 — done (`f1c74c7`).** The pod's accept callback drains the whole listen
backlog in a loop and handled each connection with bounded BLOCKING reads: 2s
for the handshake, and for SHP three more (~6s). Silent peers therefore froze
the pod *and the user's shell*. The handshake now accumulates without blocking
(inline attempt first, remainder drained on the 100ms tick, reaped after 5s),
and the SHP / aux-input request bodies are read resumably instead of inline.
`VtStreamReader` moved to `core/stream_reader.zig` so both daemons share it —
it only ever depended on std.

`smoke_stalled_pod_peer.py` (new): 12 peers staged at the three points that used
to block (pre-handshake, mid-handshake, mid-SHP-request). Keystroke round trip
in that pod's own shell is **24.03s on the unfixed build vs 0.10s here**
(baseline 0.07s) — the worst single stall found in this whole effort.

**The regression this introduced, and the lesson.** Deferring the handshake
moved `acceptVtClient` off the accept path and onto the timer — but the accept
callback does critical work *after* dispatch: clearing a stale `watched_fd`,
arming the client watcher, and resuming a paused PTY. Skipping it left the pod
never watching the new client fd, i.e. permanently deaf to input.
`smoke_reconnect` caught it (2/3 failures, vs 3/3 passes on baseline — worth
noting the FULL suite is what surfaced it; the smoke passes standalone). That
settling is now `settleAfterAccept`, called from both paths. **General rule:
when moving work off a callback, audit what the callback did AFTER the moved
call, not just the call itself.**

**C-1 — done (`c0688e4`).** `hexe pod attach` handshaked as
POD_HANDSHAKE_SES_VT, making it the pod's *authoritative* client — and
`acceptVtClient` unconditionally closes the previous one. Attaching to a live
pane evicted SES, which re-dialled, which evicted the attach client: a flap
replaying the whole backlog every cycle. Output now uses a persistent
AUX_OBSERVER connection and input short-lived AUX_INPUT connections, neither of
which touches `Pod.client`. (The other half of C-1, the missing 16-byte
epoch/seq prefix, was already fixed earlier; aux input bypasses that path, so
the prefix is correctly NOT sent on the new channel.)

`smoke_pod_attach.py` (new). **This test lied twice before it was honest.**
Asserting "attach works" and "the mux pane still responds" PASSES on the unfixed
build, because the flap re-dials faster than a 25s echo check can observe. The
discriminating signal is *which channel* the pod accepts it on — fixed:
`observer_accepts=1, vt_client_accepts=0`; unfixed: `observer_accepts=0,
vt_client_accepts=2`. Counting evictions directly does NOT work either: SES
legitimately re-dials for backlog replay, so replacements are not attributable
to the attach.

**Corrections to this document, found by checking rather than trusting it:**

- **F-11 is already fixed.** `pollResize` is SIGWINCH-gated with a periodic
  backstop (`host.zig:130-147`); it is not running an ioctl per loop pass.
- **F-9 is already fixed** by `500bc24` — `drawSplitBorders` collects row spans
  in one pass over the panes instead of re-running `splitIterator()` per
  (line, row) pair; the code comment records the old behaviour.
- **F-10 — done.** A fired hold-timer was parked with `deadline_ms = maxInt`
  and removed only by a matching key release, so if releases never arrive (a
  terminal ignoring `report_events`, or a timed-out capability probe) the entry
  lived for the life of the process while four functions walked the list on
  every keystroke. It is now parked with a 5-minute TTL; the existing expiry
  loop already removes an expired `hold_fired` and does nothing else with it, so
  a deadline was the whole fix. The TTL is far longer than any real key hold —
  expiring one early costs a single stray key forward, whereas a short TTL would
  break genuine long holds.
- **The whole B/C/D/G backlog listed as open was already done** — see the
  itemised re-check below.
- **G-2's premise does not hold, and I am deliberately NOT doing it.** The
  finding assumes the frontend pays `page_allocator`'s mmap/munmap per
  allocation on hot paths. It does not: rendering goes through a
  `frame_arena` (`render_core.zig:28`) that is `reset(.retain_capacity)` every
  frame (`loop_render.zig:591`), so after warm-up the arena reuses its backing
  memory and never calls the page allocator per frame. ASCII cells are
  documented as needing no arena allocation at all, and there are **zero**
  direct `allocator.alloc`/`dupe` calls in `loop_render.zig` or
  `statusbar.zig`. What is left on `page_allocator` is config/session/startup
  work, which is infrequent.

  Against that near-zero benefit sits a real cost. `page_allocator.free()` on a
  rodata default **panics immediately** — which is precisely why the defensive
  pointer-identity guards in `config.zig:48-64` exist and why they were
  discovered. `smp_allocator.free()` on the same pointer would instead push it
  onto a free list and hand it out later, turning a loud, local failure into a
  crash far from its cause. Swapping the allocator makes a whole bug class
  harder to diagnose in exchange for essentially nothing. Same shape as F-8:
  the finding was written from reading the allocator choice, not from measuring
  what actually allocates.
- **F-8's headline cost is overstated.** The statusbar's expensive evaluation
  (Lua/bash `when` conditions, progress text) is already memoised with TTLs in
  `statusbar.zig` (`when_lua_cache`, `when_bash_cache`, `progress_text_cache`).
  Pane output does not re-run Lua per frame. What remains of F-8 is the
  screen-clear + re-blit + border redraw — real, but CPU-bound work needing
  per-pane dirty tracking, which is the architectural change already
  deprioritised below.

**Nothing is open in this phase.** I re-checked every item still listed here
against the code rather than trusting the list, and all eight were already
implemented — several in earlier phases of this effort, one by the C-4 work:

- **B-1** — `main.zig:75-81` treats "replay hit the size cap" as *roll nothing
  back*, so a `detach_commit` past the cutoff can no longer destroy a valid
  detached session. Compaction on settled commits keeps the log away from the
  cap in the first place.
- **B-4** — `reconcileRecoveredSessionPanes` relinks crash-recovered panes to
  their session as `.detached` with `orphaned_at = null`, so they follow the
  session's 168h TTL instead of being reaped by the 24h orphan sweep.
- **C-7** — `PodUplink.tick` now keeps `send_pending` across a failed send, so a
  connect failure or write timeout is retried instead of permanently
  suppressing the cwd/foreground update.
- **C-8** — cross-validated in `handleShpRequest` (`trail_len != trail.len`),
  written as part of C-4's rewrite.
- **C-11** — `RingBuffer.copyOut` starts at `(start + (len - n)) % cap`, i.e.
  the NEWEST `n` bytes; the latent trap for a future buffer shrink is gone.
- **D-9** — `skipPayloadChecked` clamps against `MAX_PAYLOAD_LEN` and carries a
  single `SKIP_TOTAL_TIMEOUT_MS` deadline across chunks.
- **D-10** — `readMuxVtFrame` rejects `header.len > MAX_PAYLOAD_LEN` before
  draining.
- **G-4** — `noteClosedFd` now logs loudly on insert failure instead of
  swallowing it.

**F-11 is likewise already done** (`pollResize` is SIGWINCH-gated with a
periodic backstop). The lesson: this document's "still open" lists drifted out
of date as the work landed; check the code before scheduling from them.

**Full suite status at this point:** 15 debug smokes, `zig build` and
`zig fmt --check` all pass. `smoke_attach_chaos` remains the one flaky test (see
the open finding above): it passed at seed 39152 and failed at seed 2394572
round 5 in back-to-back runs on a box at load ~60/24 cores.

**Environment caveat (2026-07-29):** `/tmp` here is a tmpfs mounted `usrquota`
and this user is over the per-user quota — from unrelated projects' ISOs and VM
images, not hexe. Symptoms are confusing: the shell cannot capture stdout at
all, `zig build` dies with "IO failure on output stream: Disk quota exceeded",
and three unit tests fail with `error.DiskQuota` because they write to hardcoded
`/tmp` paths. Workaround that touches nothing of the user's:
`TMPDIR=/home/bresilla/data/tmp/hexe-build HEXE_SMOKE_TMP=/home/bresilla/data/tmp/hexe-smoke`.

Original ordering, for reference:

- **3.1** F-1 (dropped keystrokes) and D-1 (a shell that can never exit) — the
  two highest-impact items in this group; both are small fixes.
- **3.1b** F-2 (statusbar `when` clauses never evaluated) and F-6 (resize reverts
  the Unicode width method) — configured behavior that silently does nothing.
- **3.2** C-1, C-2, C-3 (`hexe pod attach` / `pod record` are broken today).
- **3.3** E-1, E-2 (config aborts the frontend; `hexe.exec` returns the wrong
  value). Un-`dormantSkip` the test that covers E-2.
- **3.4** B-1, B-2, B-3, B-4, B-5 (session-graph and recovery correctness).
- **3.5** C-5, C-6, D-9, D-10 (unvalidated lengths from the wire).
- **3.6** G-6, G-3, G-4, B-9, B-10, D-17, F-7 (memory/fd lifetime).
- **3.7** D-14 (CLI exit codes) — small, but `popup confirm` defaulting to "yes"
  on error is a footgun in shell scripts.

## Phase 4 — Throughput and footprint — **PARTIALLY DONE**

**Shipped:**

- **4.1 — done** (with 1.3, `bfece8b`). VT routing drains up to 32 frames per
  wakeup instead of one.
- **4.2 — partial** (`5988313`). `killPane` removed `pane_id_to_uuid` on only one
  branch, so every pane killed while detached left a stale entry forcing the
  per-frame hot path onto its full-table scan; and `allocPaneId` handed out its
  wrapped `u16` unconditionally, aliasing a live pane's routes after 65535
  creations. Both fixed. *Still open:* retiring the scan fallbacks entirely by
  making the index authoritative.
- **4.3 — mostly done.**
  - `0673ec0` — the statusbar rebuilt the whole Lua context per Context: a full
    `getEnvMap()` copy of the process environment pushed into a fresh Lua table,
    plus a `dupeZ` of a compile-time-constant chunk. A Context is built per
    statusbar draw *and* per visible float title, on frames driven by pane
    output, so this ran hundreds of times a second. Env table is built once; the
    chunk is passed straight through. *Still open:* per-pane tables are still
    rebuilt, and the chunk is still `loadString`-compiled per Context.
  - `aab4370` — `netspeed` derived its rate from bytes since the previous call,
    so the second of the two per-frame evaluations divided by microseconds: the
    value **actually displayed** was inflated by ~4 orders of magnitude while
    the width came from the sane one. Now samples at most every 250ms, returning
    before the `/sys/class/net` walk. `cpu` and `uptime` gated likewise, for
    cost only.
  - `ec44e93` — `AsyncCmdCache.entries` had no cap, TTL or eviction while its
    keys come from user-controllable strings, so a config composing a command
    dynamically minted an entry per frame, each spawning a child and retaining
    its buffers forever. Now capped at 512 with a 5-minute idle TTL and LRU
    eviction; in-flight entries are never evicted.
  - `9f8c4dc` — `setVaxisCell` duped every cell's grapheme into a frame arena
    reset only above 8 MB, and `drawBorderFrame` fills a float's whole rect one
    cell at a time; steady state was ~200 KB/s, crossing the threshold every
    ~30s and forcing a full repaint the user sees as a flash. ASCII cells (the
    vast majority, and every fill) now point at static storage.
  - `7ea9f1c` — `pollResize` ran a `TIOCGWINSZ` ioctl every loop iteration.
    Now driven by SIGWINCH with a 2s backstop.
  - *Still open:* F-8 (one global `needs_render`, so any pane's output repaints
    everything), F-9 (`drawSplitBorders` is O(lines × dimension × panes)),
    F-4 (kitty image re-hashed per frame), F-5 (`floatState` is O(F²)).
- **4.4 — partial** (`3a8ea62`). The pod's shared PTY/client I/O buffer was
  `MAX_FRAME_LEN` (4 MiB) — the protocol's max *single message*, not a working
  set — and fully touched, so every pod paid it in RSS. Now 64 KiB, which also
  caps the frames a pod emits. Fixed `RingBuffer.copyOut` returning the OLDEST
  bytes when the destination is smaller than the ring (latent today, fatal the
  moment buffers are sized independently). *Still open:* `backlog_tmp` is
  deliberately still ring-sized, so replay behaviour is byte-identical.

- **F-4 — done** (`4df40df`). Kitty images were re-hashed in full every frame per
  pane (~120 MB/s for one 2 MiB image); the cheap fields plus the payload
  address now settle it without touching the pixels.
- **F-9 — done** (`500bc24`). `drawSplitBorders` re-ran `splitIterator()` per
  (line, cell); it now collects spans in one pass per line.
- **F-11 — done** (`7ea9f1c`). Resize driven by SIGWINCH instead of an ioctl per
  loop iteration.

**Still open, with the specific reason each was not done:**

- **F-8** (one global `needs_render`, so any pane's output repaints everything)
  and **F-5** (`floatState` is O(F²)). F-8 is a real architectural change
  (per-pane dirty tracking + region rendering); F-5 is genuinely cheap in
  practice — F is a handful of floats, so O(F²) is a few hundred uuid compares.
- **4.5 / G-1 — TRIED IT; the plan's own analysis was wrong.** This document
  previously argued the "must be `page_allocator` across the fork" rationale was
  stale, because `run()` completes both forks in `daemonize()` before creating
  any allocator and the daemon is single-threaded, so the classic
  held-allocator-mutex-at-fork hazard cannot arise.

  I implemented it. **It does not work.** With `SesState.init`/`Server.init`
  switched to a GeneralPurposeAllocator the DAEMONIZED process panics "reached
  unreachable code" immediately after its first log line and every smoke fails
  to start a frontend — while the same binary under `--foreground` (which skips
  `daemonize`) runs fine. The likely culprit is `daemonize()` closing stdio and
  `chdir("/")`, which breaks the self-debug-info lookup the GPA's safety
  machinery uses. Reverted, with the evidence recorded in the code comment so
  the next person does not repeat it.

  The investigation did find a real bug on the way:
  `txlog.findIncompleteOperations` allocated with `page_allocator` while its
  caller freed with `ses_state.allocator` — harmless only while everything was
  page_allocator. Fixed in `f152c5d`.

  **The approach that actually works — done (`a7b9389`).** `FramePool` is a
  plain free list of already-mapped buffers with no debug machinery, so
  `daemonize()` cannot affect it. The MUX direction's per-frame
  mmap/munmap pair is gone.

  Only the MUX direction is pooled, deliberately: the pod-direction queue is
  owned by the STORE and freed from paths with no handle on the server's pool
  (`noteClosedFd`, store teardown), so pooling it is a cross-allocator free —
  the unit tests caught exactly that when I tried it. **G-2 (the frontend on
  `page_allocator`) is untouched** and would need the same care.

  Note the pattern worth remembering from this whole exercise: two of the three
  allocator bugs found here were *ownership* mismatches that the
  page_allocator monoculture had been hiding.
- **4.6 (off-thread persistence).** Introduces a thread into a codebase whose
  correctness model is explicitly single-threaded; same validation constraint.

  **Measured, and deliberately NOT done.** The persisted state is tiny: a real
  12-pane session serialises to **5.6 KB** (`ses_state.json`), and the smoke
  sessions to ~3.5 KB. That is a sub-millisecond write, on a periodic tick and
  at detach — not a stall worth introducing a thread for, and a thread is
  exactly the change most likely to break a codebase whose invariants all
  assume run-to-completion on one loop. Revisit only if session state grows by
  orders of magnitude. Third finding in a row (with F-8 and G-2) whose cost was
  assumed from the code shape rather than measured.

### Original plan text

- **4.1** Batch drain per wakeup with a byte/frame budget, plus round-robin
  fairness across pod VT fds.
- **4.2** Make `pane_id_to_uuid` authoritative and retire the full-scan fallbacks
  (needs B-8); index the linear scans (`mux_vt_fd → client_id`,
  `ctl_fd → client_id`).
- **4.3** Statusbar: evaluate each module once per frame (E-5), cache the Lua
  context and precompile the `pane_api` chunk (E-4, E-9), fix the segment cache
  aliasing (E-3 / F-3), bound `AsyncCmdCache` (E-8).
- **4.3b** Render granularity: a per-pane dirty set instead of one global
  `needs_render` (F-8), stop duping static graphemes into the frame arena and
  skip the float interior fill (F-3), precompute split-border runs (F-9),
  short-circuit the kitty image hash (F-4), index floats by uuid (F-5), and
  drive resize from SIGWINCH (F-11).
- **4.4** Right-size pod buffers (C-10) — needs C-11 fixed first — and
  `vt_route_buf` (after 4.1).
- **4.5** Allocator discipline (G-1, G-2): a real allocator after daemonization,
  arenas for per-frame work.
- **4.6** Off-thread persistence; cache pane liveness with SIGCHLD-driven
  invalidation.

## Explicitly not recommended: multi-threading SES

Sharding sessions across threads was considered and rejected. The daemon's
correctness model is load-bearing single-threaded and well-commented: deferred
watcher destruction (`server.zig:630-634`), the closed-fd log guarding fd-number
reuse (`:823`, `:928`), and the shared `vt_route_buf` whose safety argument is
literally "the event loop is single-threaded, so this is never reentrant"
(`:1866`). Retrofitting locks would trade a well-understood latency problem for a
class of use-after-free and fd-reuse races this codebase has already paid dearly
to eliminate — and G-6 shows that model is not even fully upheld today.

Phase 1 delivers the actual goal without that risk. If per-session parallelism is
ever genuinely needed, the safe shape is multiple SES *processes* keyed by
instance — which `HEXE_INSTANCE` already supports — not threads inside one.

## Suggested order

1. ~~Phase 0~~ — done (`c89341a`)
2. ~~Phase 2.1–2.2~~ — done (`a6945b9`)
3. **Phase 3 taken next, ahead of Phase 1.** F-1 (keystrokes silently dropped
   today) and D-1 (a shell that can never exit) are small, verified, and hurt
   users right now; Phase 1 is a large refactor of the daemon's I/O core. Doing
   the cheap high-impact fixes first keeps the tree shippable at every step.
4. Phase 1
5. Phase 4

Each phase is independently shippable and independently verifiable.
