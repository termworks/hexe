const std = @import("std");
const core = @import("core");
const xev = @import("xev").Dynamic;

const State = @import("state.zig").State;
const HostHooks = @import("loop_host_hooks.zig").HostHooks;

const loop_watchers = @import("loop_watchers.zig");
const runtime_events = @import("runtime_events.zig");
const dead_panes = @import("dead_panes.zig");
const loop_updates = @import("loop_updates.zig");
const loop_ipc = @import("loop_ipc.zig");
const terminal_main = @import("main.zig");

const LoopTimerContext = struct {
    last_fire: i64 = 0,
    state: *State,
    ticker: xev.Timer,
    last_pane_sync: i64,
    last_heartbeat: i64,
    pane_sync_interval: i64,
    heartbeat_interval: i64,
};

/// How long the loop timer may sleep. A painter's next_frame_ms is useless if
/// nothing wakes to serve it, and the ticker was pinned at 100ms, so animation
/// could never beat ~10fps. Never sleeps below 16ms.
fn tickDelayMs() u64 {
    const base: u64 = 100;
    const registry = core.regions.active orelse return base;
    const delta = registry.msUntilDue(std.time.milliTimestamp()) orelse return base;
    const clamped: u64 = @intCast(@max(delta, 16));
    return @min(base, clamped);
}

fn loopTimerCallback(
    ctx: ?*LoopTimerContext,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    const timer_ctx = ctx orelse return .disarm;
    _ = result catch {
        // Re-arm with fresh absolute timestamp (workaround for xev io_uring timer re-arm bug)
        timer_ctx.ticker.run(loop, completion, tickDelayMs(), LoopTimerContext, timer_ctx, loopTimerCallback);
        return .disarm;
    };

    const now = std.time.milliTimestamp();
    if (now - timer_ctx.last_pane_sync >= timer_ctx.pane_sync_interval) {
        timer_ctx.last_pane_sync = now;
        timer_ctx.state.syncFocusedPaneInfo();
        timer_ctx.state.syncNamePool();
        timer_ctx.state.syncPalettes();
    }
    if (now - timer_ctx.last_heartbeat >= timer_ctx.heartbeat_interval) {
        timer_ctx.last_heartbeat = now;
        _ = timer_ctx.state.runtime.sendPing();
    }

    timer_ctx.last_fire = std.time.milliTimestamp();
    // Re-arm with fresh absolute timestamp (workaround for xev io_uring timer re-arm bug)
    timer_ctx.ticker.run(loop, completion, tickDelayMs(), LoopTimerContext, timer_ctx, loopTimerCallback);
    return .disarm;
}

/// Reconnect-and-restore after the SES connection is lost (daemon crash or
/// restart). Everything needed to survive this already exists: pods keep
/// running with their backlogs, the daemon persists attached sessions as
/// reattachable records (loaded before it binds its socket), and the fd
/// watchers re-arm themselves once fresh fds exist. The missing piece was
/// anyone actually reconnecting — the frontend used to show "Lost
/// connection" and sit frozen until manually restarted.
const RECONNECT_RETRY_MS: i64 = 2_000;
/// Ceiling for the reconnect backoff. A flat 2s retry turns any persistent
/// reconnect fault into a tight flap loop that also hammers the daemon; back
/// off so a degraded state degrades quietly instead.
/// Backoff only engages after a few fast attempts, and caps well short of the
/// old 30s. The daemon-restart path goes through here: after a daemon dies, the
/// first attempt can legitimately fail (its socket may still be bound, or its
/// instance flock not yet released), and backing off immediately turned a
/// transient loss into a many-second outage. Keep recovery snappy first, then
/// degrade quietly if the fault persists.
const RECONNECT_FAST_ATTEMPTS: u8 = 3;
const RECONNECT_MAX_RETRY_MS: i64 = 10_000;

/// Consecutive VT-only repairs to try before falling back to full recovery.
///
/// A VT-only reconnect can *appear* to succeed and still not stick: if our CTL
/// registration is gone (daemon restarted) but our CTL fd has not been reaped
/// yet, the connect and handshake both succeed and SES then drops the channel
/// because no client matches the session id. Without this cap the frontend
/// would keep "repairing" the VT channel forever and never run the real
/// recovery.
const MAX_VT_ONLY_ATTEMPTS: u8 = 3;

const ReconnectState = struct {
    last_attempt_ms: i64 = 0,
    /// Current retry interval, doubling on each failed full reconnect.
    retry_ms: i64 = RECONNECT_RETRY_MS,
    /// Consecutive VT-only repairs that have not produced a healthy link.
    vt_only_attempts: u8 = 0,
    /// Consecutive failed full recoveries.
    failures: u8 = 0,

    fn recordSuccess(self: *ReconnectState) void {
        self.retry_ms = RECONNECT_RETRY_MS;
        self.vt_only_attempts = 0;
        self.failures = 0;
    }

    fn recordFailure(self: *ReconnectState) void {
        self.failures +|= 1;
        // Stay at the base interval for the first few tries so a daemon
        // restart is not needlessly delayed.
        if (self.failures <= RECONNECT_FAST_ATTEMPTS) return;
        self.retry_ms = @min(self.retry_ms * 2, RECONNECT_MAX_RETRY_MS);
    }
};

fn maybeReconnectSes(state: *State, rc: *ReconnectState) void {
    const ctl_ok = state.runtime.getCtlFd() != null;
    const vt_ok = state.runtime.getVtFd() != null;
    if (ctl_ok and vt_ok) {
        rc.recordSuccess();
        return;
    }
    const now = std.time.milliTimestamp();
    if (now - rc.last_attempt_ms < rc.retry_ms) return;
    rc.last_attempt_ms = now;

    // VT-only loss with a healthy CTL: just reopen the data channel. The old
    // code ran the FULL recovery here (fresh UUID + re-register + reattach),
    // which replays every pane's backlog — the very thing that overflows the
    // daemon's per-client VT queue and drops the channel, so the "cure"
    // re-caused the fault and the session flapped forever.
    if (ctl_ok and !vt_ok and rc.vt_only_attempts < MAX_VT_ONLY_ATTEMPTS) {
        rc.vt_only_attempts += 1;
        // Prove the CTL registration is actually live before attempting the
        // cheap repair. `ctl_ok` only means we still hold an fd — after a
        // daemon restart that fd can be stale, and then the VT reconnect
        // "succeeds" (connect + handshake both work) only for SES to drop the
        // channel because no client matches our session id. Burning the retry
        // budget on that delays the real recovery, which is what a killed
        // daemon actually needs.
        if (state.runtime.sendPing() and state.runtime.reconnectVtOnly()) {
            terminal_main.debugLog("ses vt-only reconnect: data channel restored (attempt {d})", .{rc.vt_only_attempts});
            // Panes must repaint from the pods' backlogs over the new channel.
            state.runtime.requestBacklogReplay() catch |err| {
                terminal_main.debugLog("ses vt-only reconnect: replay request failed: {s}", .{@errorName(err)});
            };
            // Deliberately NOT recordSuccess() here: the channel is open but
            // unproven. If it really is healthy the next iteration sees both
            // fds live and resets the backoff there; if SES drops it again we
            // come back, burn another attempt, and then do full recovery.
            state.needs_render = true;
            state.force_full_render = true;
            return;
        }
        terminal_main.debugLog("ses vt-only reconnect failed; falling back to full recovery", .{});
    }
    // Full recovery from here on: give up on cheap repairs for this episode.
    rc.vt_only_attempts = MAX_VT_ONLY_ATTEMPTS;

    // The previous session survives (persisted or still live) under our old
    // identity; capture it before re-registering mints anything new.
    const old_uuid: [32]u8 = state.runtime.sessionUuid();

    // Re-register under a FRESH identity, exactly like a manual `hexe attach`
    // from a new terminal. Registering with the OLD id would make the daemon
    // delete the persisted session record (register handler treats an id
    // match as "frontend restored it") and then the reattach RPC, finding
    // only ourselves attached under that id, would force-detach US mid-call.
    // reattachSession restores the old identity on success.
    const old_name = state.allocator.dupe(u8, state.runtime.sessionName()) catch return;
    defer state.allocator.free(old_name);
    {
        const fresh_uuid = core.uuid.generateHex();
        if (!state.runtime.setSessionIdentity(fresh_uuid, old_name)) {
            terminal_main.debugLog("ses reconnect: failed to set recovery identity", .{});
            rc.recordFailure();
            return;
        }
        state.runtime.syncClientSessionIdentity();
    }

    var attach = state.runtime.attachFrontend() catch |err| {
        terminal_main.debugLog("ses reconnect attempt failed: {s}", .{@errorName(err)});
        // Roll the identity back. Without this the throwaway UUID sticks, so
        // the NEXT attempt captures `old_uuid` = that throwaway — and once the
        // daemon returns, reattachSession asks for a session id that never
        // existed on it. The real persisted session and its pods survive but
        // become permanently unreachable ("session could not be restored"),
        // which is far worse than the failed attempt itself.
        if (!state.runtime.setSessionIdentity(old_uuid, old_name)) {
            terminal_main.debugLog("ses reconnect: failed to restore identity after failed attach", .{});
        }
        state.runtime.syncClientSessionIdentity();
        rc.recordFailure();
        return;
    };
    defer attach.deinit(state.allocator);
    terminal_main.debugLog("ses reconnected (started_daemon={}); restoring session {s}", .{ attach.started_daemon, old_uuid[0..8] });

    rc.recordSuccess();
    if (state.reattachSession(old_uuid[0..])) {
        terminal_main.exportSessionEnv(state.runtime.sessionUuid());
        state.notifications.showFor("ses daemon reconnected — session restored", 3000);
    } else {
        state.notifications.showFor("ses daemon reconnected, but the previous session could not be restored", 5000);
    }
    state.needs_render = true;
    state.force_full_render = true;
}

pub fn runMainLoop(state: *State, hooks: HostHooks, loop: *xev.Loop, loop_timer: *xev.Timer, resources: *loop_watchers.LoopResources) !void {
    const allocator = state.allocator;

    // Frame timing.
    var last_render: i64 = std.time.milliTimestamp();
    var last_status_update: i64 = last_render;
    const pane_sync_interval: i64 = core.constants.Timing.pane_sync_interval;
    const heartbeat_interval: i64 = core.constants.Timing.heartbeat_interval;

    var timer_ctx = LoopTimerContext{
        .state = state,
        .ticker = loop_timer.*,
        .last_pane_sync = last_render,
        .last_heartbeat = last_render,
        .pane_sync_interval = pane_sync_interval,
        .heartbeat_interval = heartbeat_interval,
    };
    var timer_completion: xev.Completion = .{};
    timer_ctx.last_fire = std.time.milliTimestamp();
    loop_timer.run(loop, &timer_completion, 100, LoopTimerContext, &timer_ctx, loopTimerCallback);

    // Reusable lists for dead pane tracking (avoid per-iteration allocations).
    var dead_splits: std.ArrayList([32]u8) = .empty;
    defer dead_splits.deinit(allocator);

    var reconnect_state: ReconnectState = .{};
    var loop_err_burst: usize = 0;

    // Main loop.
    while (state.running) {
        if (runtime_events.applyRuntimeStopRequest(state, hooks)) break;
        // Drive background commands (statusbar segments, git, sudo, `when`
        // conditions): drain their output, reap finished ones, kill overruns.
        // Never blocks — that is the whole point.
        state.async_cmds.poll();
        // Same contract for externally painted regions: advance in-flight
        // fetches with non-blocking syscalls only.
        state.regions.poll();
        maybeReconnectSes(state, &reconnect_state);
        runtime_events.applyDeferredPaneExits(state);
        runtime_events.applyDeferredCwdResponse(state);
        runtime_events.applyDeferredPaneInfoResponse(state);
        runtime_events.applyDeferredSessionSnapshots(state);
        runtime_events.applyDeferredSessionStolen(state);
        state.flushPendingMuxVtWrites();
        loop_watchers.ensureSesVtWatcherArmed(state, &resources.ses_vt_watcher, &resources.ses_vt_buffer);
        loop_watchers.ensureSesCtlWatcherArmed(state, &resources.ses_ctl_watcher, &resources.ses_ctl_buffer);
        loop_watchers.ensureStdinWatcherArmed(state, &resources.stdin_watcher, &resources.stdin_buffer, &hooks);

        const dbg_t0 = std.time.milliTimestamp();
        // A loop error must not tear the frontend down (it used to propagate
        // straight out of the main loop = the window just vanished) and must
        // not spin: back off if a completion keeps getting rejected.
        var loop_ok = true;
        loop.run(.once) catch |err| {
            loop_ok = false;
            loop_err_burst +|= 1;
            terminal_main.debugLog("event loop error (continuing): {s}", .{@errorName(err)});
        };
        if (loop_ok) {
            loop_err_burst = 0;
        } else if (loop_err_burst > 8) {
            std.Thread.sleep(20 * std.time.ns_per_ms);
        }
        const dbg_t1 = std.time.milliTimestamp();
        if (dbg_t1 - dbg_t0 > 300) terminal_main.debugLog("SLOW loop.run: {d}ms", .{dbg_t1 - dbg_t0});

        // Belt-and-braces keyboard input: drain stdin directly every iteration,
        // independent of the io_uring stdin watcher. A lost poll re-arm (under
        // heavy pane output) used to leave the terminal painting output but deaf
        // to the keyboard, unrecoverably. The loop is spun constantly here by
        // that same output and the 100ms ticker, so this always services keys.
        loop_watchers.pumpStdin(state, &resources.stdin_buffer, &hooks);

        // Ticker watchdog: the 100ms re-arm chain can die silently (xev
        // io_uring submission loss under load). We are AFTER loop.run, so
        // every ready CQE was just processed — if the ticker still looks
        // silent for 5s, its chain has provably no pending CQE and the
        // completion is safe to reuse for a fresh arm. A dead ticker
        // otherwise starves renders, pane sync, and key timers whenever no
        // fd event happens to wake the loop.
        if (dbg_t1 - timer_ctx.last_fire > 5000) {
            terminal_main.debugLog("loop ticker silent {d}ms; resurrecting", .{dbg_t1 - timer_ctx.last_fire});
            timer_ctx.last_fire = dbg_t1;
            timer_ctx.ticker.run(loop, &timer_completion, 100, LoopTimerContext, &timer_ctx, loopTimerCallback);
        }
        if (runtime_events.applyRuntimeStopRequest(state, hooks)) break;
        if (!state.running) break;
        runtime_events.applyDeferredCwdResponse(state);
        runtime_events.applyDeferredPaneInfoResponse(state);
        runtime_events.applyDeferredSessionSnapshots(state);
        runtime_events.applyDeferredSessionStolen(state);
        // The bare-`hexe` startup chooser runs with no tab on purpose: its
        // answer decides whether this session gets one at all, and creating a
        // fallback here would spawn the throwaway pane it exists to avoid.
        if (state.view.tab_views.items.len == 0 and !state.startup_choice_pending) {
            dead_panes.handleDeferredRespawn(state);
            if (state.view.tab_views.items.len == 0) {
                if (state.pending_action == .exit and state.exit_from_shell_death) {
                    continue;
                }
                state.createTab() catch |err| {
                    core.logging.logError("terminal", "main loop: failed to create fallback tab", err);
                    state.running = false;
                    break;
                };
                state.skip_dead_check = true;
            }
        }

        // Clear skip flag from previous iteration.
        state.skip_dead_check = false;

        hooks.finalizeCapabilities(state, std.time.milliTimestamp());

        hooks.pollResize(state);

        // The startup chooser owns a pane-less session on purpose; the
        // dead-pane sweep reads "no panes left" as "last shell exited" and
        // would tear the frontend down before the user could answer.
        const skip_dead_sweep = state.startup_choice_pending;

        // Before the dead sweep: a queued pane_exited is what marks a float
        // dead in the first place.
        loop_ipc.drainQueuedPushes(state, &resources.ses_ctl_buffer);

        if (!skip_dead_sweep) dead_panes.cleanupDeadFloats(state);

        const now2 = std.time.milliTimestamp();
        loop_updates.updateSelectionAndStatus(state, now2, &last_status_update);

        // Handle a cancelled shell-death exit confirmation before dead-pane
        // cleanup re-enters the last-pane exit path.
        if (!skip_dead_sweep) {
            dead_panes.handleDeferredRespawn(state);
            dead_panes.cleanupDeadSplits(state, &dead_splits);
        }

        loop_updates.updateOverlaysPopupsAndKeyTimers(state, now2);

        const dbg_t2 = std.time.milliTimestamp();
        hooks.renderIfDue(state, &last_render);
        const dbg_t3 = std.time.milliTimestamp();
        if (dbg_t3 - dbg_t2 > 300) terminal_main.debugLog("SLOW renderIfDue: {d}ms", .{dbg_t3 - dbg_t2});
        if (dbg_t2 - dbg_t1 > 300) terminal_main.debugLog("SLOW mid-steps: {d}ms", .{dbg_t2 - dbg_t1});
    }
}
