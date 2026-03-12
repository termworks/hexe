const std = @import("std");
const posix = std.posix;
const core = @import("core");
const wire = core.wire;
const pod_protocol = core.pod_protocol;
const xev = @import("xev").Dynamic;

const terminal = @import("terminal.zig");

const State = @import("state.zig").State;
const FrontendRuntime = core.FrontendRuntime;
const helpers = @import("helpers.zig");

const terminal_main = @import("main.zig");
const loop_input = @import("loop_input.zig");
const loop_ipc = @import("loop_ipc.zig");
const loop_mouse = @import("loop_mouse.zig");
const loop_render = @import("loop_render.zig");
const float_completion = @import("float_completion.zig");
const keybinds = @import("keybinds.zig");

const LoopTimerContext = struct {
    state: *State,
    ticker: xev.Timer,
    last_pane_sync: i64,
    last_heartbeat: i64,
    pane_sync_interval: i64,
    heartbeat_interval: i64,
};

const TERMINAL_QUERY_TIMEOUT_MS: i64 = 1200;

fn applyPostQueryFeatureModes(state: *State) void {
    const stdout = std.fs.File.stdout();
    var tty_buf: [1024]u8 = undefined;
    var tty = stdout.writer(&tty_buf);

    // Prefer Unicode width handling when explicit-width modifiers are supported.
    // This lets render output use richer grapheme width semantics without relying
    // on Mode 2027 being active.
    if (state.renderer.vx.caps.explicit_width or state.renderer.vx.caps.unicode == .unicode) {
        state.renderer.vx.screen.width_method = .unicode;
    }

    // Re-apply mouse mode after capability discovery so terminals with
    // SGR-pixels support get upgraded from cell-coordinates to pixel mode.
    state.renderer.vx.setMouseMode(&tty.interface, true) catch {};

    // Enable runtime color-scheme updates only when detected.
    if (state.renderer.vx.caps.color_scheme_updates) {
        state.renderer.vx.subscribeToColorSchemeUpdates(&tty.interface) catch {};
    }

    tty.interface.flush() catch {};
}

fn logTerminalCapabilities(state: *State, timed_out: bool) void {
    const caps = state.renderer.vx.caps;
    terminal_main.debugLog(
        "terminal caps: kitty_keyboard={} kitty_graphics={} rgb={} unicode={s} sgr_pixels={} color_updates={} multi_cursor={} explicit_width={} scaled_text={} timeout={}",
        .{
            caps.kitty_keyboard,
            caps.kitty_graphics,
            caps.rgb,
            @tagName(caps.unicode),
            caps.sgr_pixels,
            caps.color_scheme_updates,
            caps.multi_cursor,
            caps.explicit_width,
            caps.scaled_text,
            timed_out,
        },
    );

    if (timed_out) {
        terminal_main.debugLog("terminal capability query timed out; using best-effort feature set", .{});
    }
}

fn applyDeferredPaneExits(state: *State) void {
    var pending: std.ArrayList([32]u8) = .empty;
    defer pending.deinit(state.allocator);
    state.runtime.drainPendingPaneExits(&pending);
    if (pending.items.len == 0) return;

    for (pending.items) |uuid| {
        if (state.findPaneByUuid(uuid)) |pane| {
            pane.backend.pod.dead = true;
            state.needs_render = true;
        }
    }
}

fn applyDeferredSessionSnapshots(state: *State) void {
    var snapshot = state.runtime.drainPendingSessionSnapshot() orelse return;
    defer snapshot.deinit();
    _ = state.applySessionSnapshot(&snapshot);
}

fn applyRuntimeStopRequest(state: *State) bool {
    const reason = state.runtime.takeStopReason() orelse return false;
    switch (reason) {
        .session_stolen => state.notifications.showFor("Session attached elsewhere; this client is closing", 3500),
        .frontend_disconnect, .explicit_detach, .none => {},
    }
    state.running = false;
    state.needs_render = true;
    return true;
}

fn finalizeTerminalQueryIfReady(state: *State, now_ms: i64) void {
    if (!state.terminal_query_in_flight) return;

    const query_done = state.renderer.vx.queries_done.load(.unordered);
    const timed_out = now_ms >= state.terminal_query_deadline_ms;
    if (!query_done and !timed_out) return;

    const stdout = std.fs.File.stdout();
    var tty_buf: [1024]u8 = undefined;
    var tty = stdout.writer(&tty_buf);
    state.renderer.vx.enableDetectedFeatures(&tty.interface) catch {};
    applyPostQueryFeatureModes(state);
    tty.interface.flush() catch {};

    state.renderer.vx.queries_done.store(true, .unordered);
    state.terminal_query_in_flight = false;
    state.terminal_query_deadline_ms = 0;
    state.terminal_caps_ready = true;
    state.terminal_query_timed_out = timed_out;
    logTerminalCapabilities(state, timed_out);
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

const SesVtSlot = struct {
    state: *State,
    fd: posix.fd_t,
    buffer: []u8,
    watched_fd: *?posix.fd_t,
};

const SesVtWatcher = struct {
    loop: *xev.Loop,
    completion: xev.Completion = .{},
    slot: SesVtSlot = undefined,
    watched_fd: ?posix.fd_t = null,
};

const SesCtlSlot = struct {
    state: *State,
    fd: posix.fd_t,
    buffer: []u8,
    watched_fd: *?posix.fd_t,
};

const SesCtlWatcher = struct {
    loop: *xev.Loop,
    completion: xev.Completion = .{},
    slot: SesCtlSlot = undefined,
    watched_fd: ?posix.fd_t = null,
};

const StdinSlot = struct {
    state: *State,
    buffer: []u8,
};

const StdinWatcher = struct {
    loop: *xev.Loop,
    completion: xev.Completion = .{},
    slot: StdinSlot = undefined,
    armed: bool = false,
};

fn ensureSesVtWatcherArmed(state: *State, watcher: *SesVtWatcher, buffer: []u8) void {
    if (watcher.watched_fd != null) return;
    const vt_fd = state.runtime.getVtFd() orelse return;

    watcher.watched_fd = vt_fd;
    watcher.slot = .{ .state = state, .fd = vt_fd, .buffer = buffer, .watched_fd = &watcher.watched_fd };
    const file = xev.File.initFd(vt_fd);
    watcher.completion = .{};
    file.poll(watcher.loop, &watcher.completion, .read, SesVtSlot, &watcher.slot, sesVtCallback);
}

fn ensureSesCtlWatcherArmed(state: *State, watcher: *SesCtlWatcher, buffer: []u8) void {
    if (watcher.watched_fd != null) return;
    const ctl_fd = state.runtime.getCtlFd() orelse return;

    watcher.watched_fd = ctl_fd;
    watcher.slot = .{ .state = state, .fd = ctl_fd, .buffer = buffer, .watched_fd = &watcher.watched_fd };
    const file = xev.File.initFd(ctl_fd);
    watcher.completion = .{};
    file.poll(watcher.loop, &watcher.completion, .read, SesCtlSlot, &watcher.slot, sesCtlCallback);
}

fn sesVtCallback(
    ctx: ?*SesVtSlot,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.File,
    result: xev.PollError!xev.PollEvent,
) xev.CallbackAction {
    const slot = ctx orelse return .disarm;
    _ = result catch {
        if (slot.watched_fd.* == slot.fd) slot.watched_fd.* = null;
        if (slot.state.runtime.closeVtFdIf(slot.fd)) {
            slot.state.notifications.showFor("Warning: Lost connection to ses daemon (VT channel) - panes frozen", 5000);
        }
        return .disarm;
    };

    const vt_fd = slot.state.runtime.getVtFd() orelse {
        if (slot.watched_fd.* == slot.fd) slot.watched_fd.* = null;
        return .disarm;
    };
    if (vt_fd != slot.fd) {
        if (slot.watched_fd.* == slot.fd) slot.watched_fd.* = null;
        return .disarm;
    }

    var vt_frames: usize = 0;
    while (vt_frames < 64) : (vt_frames += 1) {
        const hdr = wire.tryReadMuxVtHeader(vt_fd) catch |err| switch (err) {
            error.WouldBlock => break,
            else => {
                if (slot.watched_fd.* == slot.fd) slot.watched_fd.* = null;
                if (slot.state.runtime.closeVtFdIf(slot.fd)) {
                    slot.state.notifications.showFor("Warning: Lost connection to ses daemon (VT channel) - panes frozen", 5000);
                }
                return .disarm;
            },
        };
        if (hdr.len > slot.buffer.len) {
            var remaining: usize = hdr.len;
            while (remaining > 0) {
                const chunk = @min(remaining, slot.buffer.len);
                wire.readExact(vt_fd, slot.buffer[0..chunk]) catch break;
                remaining -= chunk;
            }
            continue;
        }
        if (hdr.len > 0) {
            wire.readExact(vt_fd, slot.buffer[0..hdr.len]) catch {
                if (slot.watched_fd.* == slot.fd) slot.watched_fd.* = null;
                if (slot.state.runtime.closeVtFdIf(slot.fd)) {
                    slot.state.notifications.showFor("Warning: Lost connection to ses daemon (VT channel) - panes frozen", 5000);
                }
                return .disarm;
            };
        }

        if (slot.state.findPaneByPaneId(hdr.pane_id)) |pane| {
            if (hdr.frame_type == @intFromEnum(pod_protocol.FrameType.output)) {
                terminal_main.debugLogUuid(&pane.uuid, "vt recv: pane_id={d} output len={d}", .{ hdr.pane_id, hdr.len });
                pane.feedPodOutput(slot.buffer[0..hdr.len]);
                const osc_responses = pane.takeOscExpectedResponses();
                if (osc_responses > 0) {
                    var j: u16 = 0;
                    while (j < osc_responses) : (j += 1) {
                        slot.state.enqueueOscReplyTarget(pane.uuid);
                    }
                }
                const csi_responses = pane.takeCsiExpectedResponses();
                if (csi_responses > 0) {
                    var j: u16 = 0;
                    while (j < csi_responses) : (j += 1) {
                        slot.state.enqueueCsiReplyTarget(pane.uuid);
                    }
                }
                pane.vt.invalidateRenderState();
                slot.state.needs_render = true;
            } else if (hdr.frame_type == @intFromEnum(pod_protocol.FrameType.backlog_end)) {
                terminal_main.debugLogUuid(&pane.uuid, "vt recv: pane_id={d} backlog_end", .{hdr.pane_id});
                pane.vt.invalidateRenderState();
                slot.state.needs_render = true;
                slot.state.force_full_render = true;
            }
        } else {
            terminal_main.debugLog("vt recv: UNKNOWN pane_id={d} type={d} len={d} — no matching pane!", .{ hdr.pane_id, hdr.frame_type, hdr.len });
        }
    }

    return .rearm;
}

fn sesCtlCallback(
    ctx: ?*SesCtlSlot,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.File,
    result: xev.PollError!xev.PollEvent,
) xev.CallbackAction {
    const slot = ctx orelse return .disarm;
    _ = result catch {
        if (slot.watched_fd.* == slot.fd) slot.watched_fd.* = null;
        if (slot.state.runtime.closeCtlFdIf(slot.fd)) {
            slot.state.notifications.showFor("Warning: Lost connection to ses daemon (CTL channel)", 5000);
        }
        return .disarm;
    };

    const ctl_fd = slot.state.runtime.getCtlFd() orelse {
        if (slot.watched_fd.* == slot.fd) slot.watched_fd.* = null;
        return .disarm;
    };
    if (ctl_fd != slot.fd) {
        if (slot.watched_fd.* == slot.fd) slot.watched_fd.* = null;
        return .disarm;
    }

    loop_ipc.handleSesMessage(slot.state, slot.buffer);
    return .rearm;
}

fn ensureStdinWatcherArmed(state: *State, watcher: *StdinWatcher, buffer: []u8) void {
    if (watcher.armed) return;
    watcher.slot = .{ .state = state, .buffer = buffer };
    const file = xev.File.initFd(posix.STDIN_FILENO);
    watcher.completion = .{};
    file.poll(watcher.loop, &watcher.completion, .read, StdinSlot, &watcher.slot, stdinCallback);
    watcher.armed = true;
}

fn stdinCallback(
    ctx: ?*StdinSlot,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.File,
    result: xev.PollError!xev.PollEvent,
) xev.CallbackAction {
    const slot = ctx orelse return .disarm;
    _ = result catch {
        slot.state.runtime.requestFrontendDisconnectStop();
        return .disarm;
    };

    const n = posix.read(posix.STDIN_FILENO, slot.buffer) catch {
        slot.state.runtime.requestFrontendDisconnectStop();
        return .disarm;
    };
    if (n == 0) {
        slot.state.runtime.requestFrontendDisconnectStop();
        return .disarm;
    }

    loop_input.handleInput(slot.state, slot.buffer[0..n]);
    return .rearm;
}

fn cleanupDeadFloat(state: *State, index: usize) void {
    if (index >= state.view.floats.items.len) return;

    const pane = state.view.floats.items[index];
    const was_active = if (state.activeFloatingIndex()) |af| af == index else false;
    const exit_code = state.paneExitCode(pane.uuid);

    if (state.paneFloatKey(pane) != 0 and !state.paneCaptureOutput(pane)) {
        if (state.paneRetainedAfterExit(pane)) return;
        state.setPaneRetainedAfterExit(pane.uuid, true);

        terminal_main.debugLog("float pane retained after exit: uuid={s} exit_code={d} focused={}", .{
            pane.uuid[0..8],
            exit_code,
            was_active,
        });

        if (exit_code != 0) {
            const msg = std.fmt.allocPrint(
                state.allocator,
                "Float exited with code {d}",
                .{exit_code},
            ) catch "Float exited unexpectedly";
            defer if (!std.mem.eql(u8, msg, "Float exited unexpectedly")) state.allocator.free(msg);
            state.notifications.showFor(msg, 3000);
        }

        if (was_active) {
            state.setActiveFloatingIndex(null);
            state.cursor_needs_restore = true;
            if (state.currentLayout().getFocusedPane()) |tiled| {
                state.syncPaneFocus(tiled, pane.uuid);
            }
        }

        state.needs_render = true;
        state.force_full_render = true;
        state.renderer.invalidate();
        return;
    }

    _ = state.view.floats.orderedRemove(index);

    terminal_main.debugLog("float pane died: uuid={s} exit_code={d} focused={}", .{ pane.uuid[0..8], exit_code, was_active });

    if (!was_active and exit_code != 0) {
        const msg = std.fmt.allocPrint(
            state.allocator,
            "Background float exited with code {d}",
            .{exit_code},
        ) catch "Background float exited unexpectedly";
        defer if (!std.mem.eql(u8, msg, "Background float exited unexpectedly")) state.allocator.free(msg);
        state.notifications.showFor(msg, 3000);
    }

    float_completion.handleBlockingFloatCompletion(state, pane);

    // Float is already dead (detected via isAlive/pane_exited), so avoid
    // sending another synchronous kill request on the shared control channel.

    state.clearFloatUi(pane.uuid);
    pane.deinit();
    state.allocator.destroy(pane);
    state.needs_render = true;
    state.force_full_render = true;
    state.renderer.invalidate();
    state.syncSessionFloatRemoved(pane.uuid);

    if (was_active) {
        state.setActiveFloatingIndex(null);
        state.cursor_needs_restore = true;
        if (state.currentLayout().getFocusedPane()) |tiled| {
            state.syncPaneFocus(tiled, null);
        }
    }
}

pub fn runMainLoop(state: *State) !void {
    const allocator = state.allocator;

    try xev.detect();
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    var loop_timer = try xev.Timer.init();
    defer loop_timer.deinit();

    // Enter raw mode.
    const orig_termios = try terminal.enableRawMode(posix.STDIN_FILENO);
    defer terminal.disableRawMode(posix.STDIN_FILENO, orig_termios) catch {};

    // Enter alternate screen and initialize terminal modes through libvaxis.
    const stdout = std.fs.File.stdout();
    var tty_init_buf: [1024]u8 = undefined;
    var tty_init = stdout.writer(&tty_init_buf);
    try state.renderer.vx.enterAltScreen(&tty_init.interface);
    try state.renderer.vx.setBracketedPaste(&tty_init.interface, true);
    try state.renderer.vx.setMouseMode(&tty_init.interface, true);
    // Keep kitty keyboard available as baseline while capability probing runs.
    state.renderer.vx.caps.kitty_keyboard = true;
    state.renderer.vx.queryTerminalSend(&tty_init.interface) catch {
        try state.renderer.vx.enableDetectedFeatures(&tty_init.interface);
        applyPostQueryFeatureModes(state);
        state.renderer.vx.queries_done.store(true, .unordered);
        state.terminal_query_in_flight = false;
        state.terminal_query_deadline_ms = 0;
        state.terminal_caps_ready = true;
        state.terminal_query_timed_out = true;
        logTerminalCapabilities(state, true);
    };
    if (!state.renderer.vx.queries_done.load(.unordered)) {
        state.terminal_query_in_flight = true;
        state.terminal_query_deadline_ms = std.time.milliTimestamp() + TERMINAL_QUERY_TIMEOUT_MS;
    }
    try tty_init.interface.flush();
    defer {
        var tty_restore_buf: [512]u8 = undefined;
        var tty_restore = stdout.writer(&tty_restore_buf);
        {
            var split_it = state.currentLayout().splitIterator();
            while (split_it.next()) |pane| {
                pane.*.vt.freeCachedKittyImages(&state.renderer.vx, &tty_restore.interface);
            }
            for (state.view.floats.items) |pane| {
                pane.vt.freeCachedKittyImages(&state.renderer.vx, &tty_restore.interface);
            }
        }
        // Ensure in-band resize mode is reset even if vaxis internal state
        // tracking missed setting it during capability query setup.
        tty_restore.interface.writeAll("\x1b[?2048l") catch {};
        loop_mouse.resetShape(state);
        state.renderer.vx.resetState(&tty_restore.interface) catch {};
        tty_restore.interface.flush() catch {};
    }

    var ses_vt_buffer: [1024 * 1024]u8 = undefined;
    var ses_ctl_buffer: [1024 * 1024]u8 = undefined;
    var stdin_buffer: [64 * 1024]u8 = undefined;

    var ses_vt_watcher: SesVtWatcher = .{ .loop = &loop };
    var ses_ctl_watcher: SesCtlWatcher = .{ .loop = &loop };
    var stdin_watcher: StdinWatcher = .{ .loop = &loop };

    // Frame timing.
    var last_render: i64 = std.time.milliTimestamp();
    var last_status_update: i64 = last_render;
    // Update status bar periodically.
    // This is also used to drive lightweight animations.
    const status_update_interval_base: i64 = core.constants.Timing.status_update_interval_base;
    const status_update_interval_anim: i64 = core.constants.Timing.status_update_interval_anim;
    const pane_sync_interval: i64 = core.constants.Timing.pane_sync_interval;
    const heartbeat_interval: i64 = core.constants.Timing.heartbeat_interval;

    var timer_ctx = LoopTimerContext{
        .state = state,
        .ticker = loop_timer,
        .last_pane_sync = last_render,
        .last_heartbeat = last_render,
        .pane_sync_interval = pane_sync_interval,
        .heartbeat_interval = heartbeat_interval,
    };
    var timer_completion: xev.Completion = .{};
    loop_timer.run(&loop, &timer_completion, 100, LoopTimerContext, &timer_ctx, loopTimerCallback);

    // Reusable lists for dead pane tracking (avoid per-iteration allocations).
    var dead_splits: std.ArrayList([32]u8) = .empty;
    defer dead_splits.deinit(allocator);

    // Main loop.
    while (state.running) {
        if (applyRuntimeStopRequest(state)) break;
        applyDeferredPaneExits(state);
        applyDeferredSessionSnapshots(state);
        state.flushPendingMuxVtWrites();
        ensureSesVtWatcherArmed(state, &ses_vt_watcher, &ses_vt_buffer);
        ensureSesCtlWatcherArmed(state, &ses_ctl_watcher, &ses_ctl_buffer);
        ensureStdinWatcherArmed(state, &stdin_watcher, &stdin_buffer);

        try loop.run(.once);
        if (applyRuntimeStopRequest(state)) break;
        if (!state.running) break;

        // Clear skip flag from previous iteration.
        state.skip_dead_check = false;

        finalizeTerminalQueryIfReady(state, std.time.milliTimestamp());

        // Check for terminal resize.
        {
            const new_size = terminal.getTermSize();
            if (new_size.cols != state.term_width or new_size.rows != state.term_height) {
                state.applyTerminalResize(new_size.cols, new_size.rows);
            }
        }

        // Proactively check for dead floats before polling.
        // Iterate in reverse to avoid O(n²) behavior from orderedRemove shifts.
        {
            if (state.view.floats.items.len > 0) {
                var fi: usize = state.view.floats.items.len;
                while (fi > 0) {
                    fi -= 1;
                    if (!state.view.floats.items[fi].isAlive()) {
                        cleanupDeadFloat(state, fi);
                        // When iterating in reverse, removals don't affect unprocessed indices.
                    }
                }
            }
            // Ensure active_floating is valid.
            if (state.activeFloatingIndex()) |af| {
                if (af >= state.view.floats.items.len) {
                    state.setActiveFloatingIndex(if (state.view.floats.items.len > 0)
                        state.view.floats.items.len - 1
                    else
                        null);
                }
            }
        }

        const now2 = std.time.milliTimestamp();
        const want_anim = blk: {
            const uuid = state.getCurrentFocusedUuid() orelse break :blk false;

            // If a float is focused, allow fast refresh (spinners in statusbar).
            if (state.activeFloatingIndex() != null) break :blk true;

            // suppress while alt-screen is active (for split-focused panes)
            const alt = if (state.currentLayout().getFocusedPane()) |pane| pane.vt.inAltScreen() else false;
            if (alt) break :blk false;

            // Prefer direct fg_process; fallback to cached process name.
            const fg = if (state.activeFloatingIndex()) |idx| blk3: {
                if (idx < state.view.floats.items.len) {
                    if (state.view.floats.items[idx].getFgProcess()) |p| break :blk3 p;
                }
                break :blk3 @as(?[]const u8, null);
            } else if (state.currentLayout().getFocusedPane()) |pane| pane.getFgProcess() else null;

            const proc_name = fg orelse blk4: {
                if (state.getPaneProc(uuid)) |pi| {
                    if (pi.name) |n| break :blk4 n;
                }
                break :blk4 @as(?[]const u8, null);
            };
            if (proc_name == null) break :blk false;

            const shells = [_][]const u8{ "bash", "zsh", "fish", "sh", "dash", "nu", "xonsh", "pwsh", "cmd", "elvish" };
            for (shells) |s| {
                if (std.mem.eql(u8, proc_name.?, s)) break :blk false;
            }

            break :blk true;
        };
        const status_update_interval: i64 = if (want_anim) status_update_interval_anim else status_update_interval_base;

        // Auto-scroll while selecting when the mouse is near the top/bottom.
        // This allows selecting hidden content by holding the mouse at the edge.
        if (state.mouse_selection.active and state.mouse_selection.edge_scroll != .none) {
            const interval_ms: i64 = core.constants.Timing.key_timer_interval;
            if (now2 - state.mouse_selection_last_autoscroll_ms >= interval_ms) {
                state.mouse_selection_last_autoscroll_ms = now2;
                if (state.mouse_selection.pane_uuid) |uuid| {
                    if (state.findPaneByUuid(uuid)) |p| {
                        switch (state.mouse_selection.edge_scroll) {
                            .up => p.scrollUp(1),
                            .down => p.scrollDown(1),
                            .none => {},
                        }
                        // Recompute cursor in buffer coordinates for the current
                        // viewport after the scroll.
                        state.mouse_selection.update(p, state.mouse_selection.last_local.x, state.mouse_selection.last_local.y);
                        state.needs_render = true;
                    }
                }
            }
        }
        if (now2 - last_status_update >= status_update_interval) {
            state.needs_render = true;
            last_status_update = now2;
        }

        dead_splits.clearRetainingCapacity();
        {
            var pane_it = state.currentLayout().splitIterator();
            while (pane_it.next()) |pane| {
                if (!pane.*.isAlive()) {
                    dead_splits.append(allocator, pane.*.uuid) catch {};
                }
            }
        }
        // Ensure active_floating is still valid.
        if (state.activeFloatingIndex()) |af| {
            if (af >= state.view.floats.items.len) {
                state.setActiveFloatingIndex(null);
            }
        }

        // Remove dead splits (skip if just respawned a shell).
        if (!state.skip_dead_check) {
            var dead_idx: usize = 0;
            while (dead_idx < dead_splits.items.len) : (dead_idx += 1) {
                const dead_uuid = dead_splits.items[dead_idx];
                // Find the dead pane to get exit status and determine if notification is needed
                const dead_pane = state.currentLayout().splits.get(dead_uuid);
                // Dead-pane snapshots can become stale after tab/layout mutations.
                // Ignore UUIDs that no longer exist in the active layout.
                if (dead_pane == null) continue;
                // Only handle panes that are actually dead.
                if (dead_pane.?.isAlive()) continue;

                const was_focused = if (state.currentLayout().getFocusedPane()) |fp| std.mem.eql(u8, &fp.uuid, &dead_uuid) else false;
                const exit_code = if (dead_pane) |p| state.paneExitCode(p.uuid) else 0;

                if (state.currentLayout().splitCount() > 1) {
                    // Multiple splits in tab - close the specific dead pane.
                    _ = state.currentLayout().closePane(dead_uuid);

                    // Log pane death
                    terminal_main.debugLog("pane died: view_id={d} exit_code={d} focused={}", .{ dead_pane.?.id, exit_code, was_focused });

                    // Show notification if pane died with non-zero exit or was unfocused (unexpected)
                    if (!was_focused and exit_code != 0) {
                        const msg = std.fmt.allocPrint(
                            allocator,
                            "Background pane exited with code {d}",
                            .{exit_code},
                        ) catch "Background pane exited unexpectedly";
                        defer if (!std.mem.eql(u8, msg, "Background pane exited unexpectedly")) allocator.free(msg);
                        state.notifications.showFor(msg, 3000);
                    }

                    const next_focus_uuid = if (state.currentLayout().getFocusedPane()) |pane| pane.uuid else null;
                    state.syncSessionCloseSplitPane(dead_uuid, next_focus_uuid);
                    if (state.currentLayout().getFocusedPane()) |new_pane| {
                        state.syncPaneFocus(new_pane, null);
                    }
                    state.needs_render = true;
                } else if (state.view.tabs.items.len > 1) {
                    _ = state.closeCurrentTab();
                    state.needs_render = true;
                    // Active tab changed; remaining dead UUIDs were collected from
                    // the old tab context and must be discarded this iteration.
                    break;
                } else {
                    // If the shell asked permission to exit and we confirmed,
                    // don't ask again when it actually dies.
                    const now_ms = std.time.milliTimestamp();
                    if (state.exit_intent_deadline_ms > now_ms) {
                        state.exit_intent_deadline_ms = 0;
                        state.running = false;
                    } else if (state.config.confirm_on_exit and state.pending_action == null) {
                        state.pending_action = .exit;
                        state.exit_from_shell_death = true;
                        state.popups.showConfirm("Shell exited. Close terminal session?", .{}) catch {};
                        state.needs_render = true;
                    } else if (state.pending_action != .exit or !state.exit_from_shell_death) {
                        state.running = false;
                    }
                }
            }
        }

        // Handle deferred respawn (from shell death "No" response)
        if (state.needs_respawn) {
            state.needs_respawn = false;
            if (state.currentLayout().getFocusedPane()) |pane| {
                var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
                var cwd = state.getReliableCwd(pane);
                if (cwd == null) {
                    cwd = std.posix.getcwd(&cwd_buf) catch null;
                }
                const old_aux = state.runtime.getPaneAux(pane.uuid) catch FrontendRuntime.PaneAuxInfo{
                    .created_from = null,
                    .focused_from = null,
                };
                state.runtime.killPane(pane.uuid) catch {};
                if (state.runtime.createPane(null, cwd, null, null, null, null, null)) |result| {
                    const vt_fd = state.runtime.getVtFd();
                    var replaced = true;
                    if (vt_fd) |fd| {
                        pane.replaceWithPod(result.pane_id, fd, result.uuid) catch {
                            replaced = false;
                        };
                    } else replaced = false;
                    if (replaced) {
                        const pane_type: FrontendRuntime.PaneType = if (state.paneIsFloating(pane)) .float else .split;
                        const cursor = pane.getCursorPos();
                        const cursor_style = pane.vt.getCursorStyle();
                        const cursor_visible = pane.vt.isCursorVisible();
                        const alt_screen = pane.vt.inAltScreen();
                        const layout_path = helpers.getLayoutPath(state, pane) catch null;
                        defer if (layout_path) |path| state.allocator.free(path);
                        state.runtime.updatePaneAux(
                            pane.uuid,
                            state.activeTabIndex(),
                            state.paneIsFloating(pane),
                            state.paneIsFocused(pane),
                            pane_type,
                            old_aux.created_from,
                            old_aux.focused_from,
                            .{ .x = cursor.x, .y = cursor.y },
                            cursor_style,
                            cursor_visible,
                            alt_screen,
                            .{ .cols = pane.width, .rows = pane.height },
                            pane.getPwd(),
                            null,
                            null,
                            layout_path,
                        ) catch {};
                        state.skip_dead_check = true;
                        state.needs_render = true;
                    } else {
                        state.notifications.show("Respawn failed");
                    }
                } else |_| {
                    state.notifications.show("Respawn failed");
                }
            }
        }

        // Update MUX realm notifications.
        if (state.notifications.update()) {
            state.needs_render = true;
        }

        // Update overlays (expire info overlays, keycast entries).
        if (state.overlays.update()) {
            state.needs_render = true;
        }

        // Update MUX realm popups (check for timeout).
        const mux_popup_changed = state.popups.update();
        if (mux_popup_changed) {
            state.needs_render = true;
            // Check if a popup timed out and we need to send response.
            if (state.pending_pop_response and state.pending_pop_scope == .mux and !state.popups.isBlocked()) {
                loop_ipc.sendPopResponse(state);
            }
        }

        // Update TAB realm notifications (current tab only).
        if (state.view.tabs.items[state.activeTabIndex()].notifications.update()) {
            state.needs_render = true;
        }

        // Update TAB realm popups (check for timeout).
        if (state.view.tabs.items[state.activeTabIndex()].popups.update()) {
            state.needs_render = true;
            // Check if a popup timed out and we need to send response.
            if (state.pending_pop_response and state.pending_pop_scope == .tab and !state.view.tabs.items[state.activeTabIndex()].popups.isBlocked()) {
                loop_ipc.sendPopResponse(state);
            }
        }

        // Update PANE realm notifications (splits).
        var notif_pane_it = state.currentLayout().splitIterator();
        while (notif_pane_it.next()) |pane| {
            if (pane.*.updateNotifications()) {
                state.needs_render = true;
            }
            // Update PANE realm popups (check for timeout).
            if (pane.*.updatePopups()) {
                state.needs_render = true;
                // Check if a popup timed out and we need to send response.
                if (state.pending_pop_response and state.pending_pop_scope == .pane) {
                    if (state.pending_pop_pane) |pending_pane| {
                        if (pending_pane == pane.* and !pane.*.popups.isBlocked()) {
                            loop_ipc.sendPopResponse(state);
                        }
                    }
                }
            }
        }

        // Update PANE realm notifications (floats).
        for (state.view.floats.items) |pane| {
            if (pane.updateNotifications()) {
                state.needs_render = true;
            }
            // Update PANE realm popups (check for timeout).
            if (pane.updatePopups()) {
                state.needs_render = true;
                // Check if a popup timed out and we need to send response.
                if (state.pending_pop_response and state.pending_pop_scope == .pane) {
                    if (state.pending_pop_pane) |pending_pane| {
                        if (pending_pane == pane and !pane.popups.isBlocked()) {
                            loop_ipc.sendPopResponse(state);
                        }
                    }
                }
            }
        }

        // Process keybinding timers (hold / double-tap delayed press).
        keybinds.processKeyTimers(state, now2);

        // Render with frame rate limiting (max 60fps).
        if (state.needs_render) {
            const render_now = std.time.milliTimestamp();
            if (render_now - last_render >= 16) { // ~60fps
                loop_render.renderTo(state, stdout) catch {};
                state.needs_render = false;
                state.force_full_render = false;
                last_render = render_now;
            }
        }
    }
}
