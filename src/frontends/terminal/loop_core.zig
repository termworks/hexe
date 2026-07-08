const std = @import("std");
const core = @import("core");
const xev = @import("xev").Dynamic;

const State = @import("state.zig").State;
const HostHooks = @import("loop_host_hooks.zig").HostHooks;

const loop_watchers = @import("loop_watchers.zig");
const runtime_events = @import("runtime_events.zig");
const dead_panes = @import("dead_panes.zig");
const loop_updates = @import("loop_updates.zig");
const terminal_main = @import("main.zig");

const LoopTimerContext = struct {
    state: *State,
    ticker: xev.Timer,
    last_pane_sync: i64,
    last_heartbeat: i64,
    pane_sync_interval: i64,
    heartbeat_interval: i64,
};

fn loopTimerCallback(
    ctx: ?*LoopTimerContext,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    const timer_ctx = ctx orelse return .disarm;
    _ = result catch {
        // Re-arm with fresh absolute timestamp (workaround for xev io_uring timer re-arm bug)
        timer_ctx.ticker.run(loop, completion, 100, LoopTimerContext, timer_ctx, loopTimerCallback);
        return .disarm;
    };

    const now = std.time.milliTimestamp();
    if (now - timer_ctx.last_pane_sync >= timer_ctx.pane_sync_interval) {
        timer_ctx.last_pane_sync = now;
        timer_ctx.state.syncFocusedPaneInfo();
    }
    if (now - timer_ctx.last_heartbeat >= timer_ctx.heartbeat_interval) {
        timer_ctx.last_heartbeat = now;
        _ = timer_ctx.state.runtime.sendPing();
    }

    // Re-arm with fresh absolute timestamp (workaround for xev io_uring timer re-arm bug)
    timer_ctx.ticker.run(loop, completion, 100, LoopTimerContext, timer_ctx, loopTimerCallback);
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

fn maybeReconnectSes(state: *State, last_attempt_ms: *i64) void {
    // VT-only loss (e.g. the intentional mux-queue-overflow drop after a huge
    // output burst) used to freeze all panes forever while CTL stayed healthy.
    // A full reconnect + reattach heals it too: panes are rebuilt from the
    // session snapshot and re-painted from pod backlogs, so there is no
    // missed-output gap or duplicated content a raw VT re-open would cause.
    const ctl_ok = state.runtime.getCtlFd() != null;
    const vt_ok = state.runtime.getVtFd() != null;
    if (ctl_ok and vt_ok) return;
    const now = std.time.milliTimestamp();
    if (now - last_attempt_ms.* < RECONNECT_RETRY_MS) return;
    last_attempt_ms.* = now;

    // The previous session survives (persisted or still live) under our old
    // identity; capture it before re-registering mints anything new.
    const old_uuid: [32]u8 = state.runtime.sessionUuid();

    var attach = state.runtime.attachFrontend() catch |err| {
        terminal_main.debugLog("ses reconnect attempt failed: {s}", .{@errorName(err)});
        return;
    };
    defer attach.deinit(state.allocator);
    terminal_main.debugLog("ses reconnected (started_daemon={}); restoring session {s}", .{ attach.started_daemon, old_uuid[0..8] });

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
    loop_timer.run(loop, &timer_completion, 100, LoopTimerContext, &timer_ctx, loopTimerCallback);

    // Reusable lists for dead pane tracking (avoid per-iteration allocations).
    var dead_splits: std.ArrayList([32]u8) = .empty;
    defer dead_splits.deinit(allocator);

    var last_reconnect_attempt: i64 = 0;

    // Main loop.
    while (state.running) {
        if (runtime_events.applyRuntimeStopRequest(state, hooks)) break;
        maybeReconnectSes(state, &last_reconnect_attempt);
        runtime_events.applyDeferredPaneExits(state);
        runtime_events.applyDeferredCwdResponse(state);
        runtime_events.applyDeferredPaneInfoResponse(state);
        runtime_events.applyDeferredSessionSnapshots(state);
        runtime_events.applyDeferredSessionStolen(state);
        state.flushPendingMuxVtWrites();
        loop_watchers.ensureSesVtWatcherArmed(state, &resources.ses_vt_watcher, &resources.ses_vt_buffer);
        loop_watchers.ensureSesCtlWatcherArmed(state, &resources.ses_ctl_watcher, &resources.ses_ctl_buffer);
        loop_watchers.ensureStdinWatcherArmed(state, &resources.stdin_watcher, &resources.stdin_buffer, &hooks);

        try loop.run(.once);
        if (runtime_events.applyRuntimeStopRequest(state, hooks)) break;
        if (!state.running) break;
        runtime_events.applyDeferredCwdResponse(state);
        runtime_events.applyDeferredPaneInfoResponse(state);
        runtime_events.applyDeferredSessionSnapshots(state);
        runtime_events.applyDeferredSessionStolen(state);
        if (state.view.tab_views.items.len == 0) {
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

        dead_panes.cleanupDeadFloats(state);

        const now2 = std.time.milliTimestamp();
        loop_updates.updateSelectionAndStatus(state, now2, &last_status_update);

        // Handle a cancelled shell-death exit confirmation before dead-pane
        // cleanup re-enters the last-pane exit path.
        dead_panes.handleDeferredRespawn(state);

        dead_panes.cleanupDeadSplits(state, &dead_splits);

        loop_updates.updateOverlaysPopupsAndKeyTimers(state, now2);

        hooks.renderIfDue(state, &last_render);
    }
}
