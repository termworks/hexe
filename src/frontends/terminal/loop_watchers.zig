const std = @import("std");
const posix = std.posix;
const core = @import("core");
const frontend_core = @import("frontend_core");
const xev = @import("xev").Dynamic;

const State = @import("state.zig").State;
const HostHooks = @import("loop_host_hooks.zig").HostHooks;
const terminal_main = @import("main.zig");
const loop_ipc = @import("loop_ipc.zig");

const SesVtSlot = struct {
    state: *State,
    fd: posix.fd_t,
    buffer: []u8,
    watched_fd: *?posix.fd_t,
};

pub const SesVtWatcher = struct {
    loop: *xev.Loop,
    completion: xev.Completion = .{},
    slot: SesVtSlot = undefined,
    watched_fd: ?posix.fd_t = null,
};

const SesVtDispatchContext = struct {
    state: *State,
};

const SesCtlSlot = struct {
    state: *State,
    fd: posix.fd_t,
    buffer: []u8,
    watched_fd: *?posix.fd_t,
};

pub const SesCtlWatcher = struct {
    loop: *xev.Loop,
    completion: xev.Completion = .{},
    slot: SesCtlSlot = undefined,
    watched_fd: ?posix.fd_t = null,
};

const StdinSlot = struct {
    state: *State,
    fd: posix.fd_t,
    buffer: []u8,
    hooks: *const HostHooks,
};

pub const StdinWatcher = struct {
    loop: *xev.Loop,
    completion: xev.Completion = .{},
    slot: StdinSlot = undefined,
    armed: bool = false,
};

/// Host-owned watcher and reusable read-buffer storage.
///
/// `TerminalHost` owns an instance of this type and passes it to the loop. The
/// callback implementations live here so `loop_core` is no longer the implicit
/// owner of terminal stdin/SES fd plumbing.
pub const LoopResources = struct {
    ses_vt_buffer: [1024 * 1024]u8 = undefined,
    ses_ctl_buffer: [1024 * 1024]u8 = undefined,
    stdin_buffer: [64 * 1024]u8 = undefined,
    ses_vt_watcher: SesVtWatcher = undefined,
    ses_ctl_watcher: SesCtlWatcher = undefined,
    stdin_watcher: StdinWatcher = undefined,

    pub fn init(self: *LoopResources, loop: *xev.Loop) void {
        self.ses_vt_watcher = .{ .loop = loop };
        self.ses_ctl_watcher = .{ .loop = loop };
        self.stdin_watcher = .{ .loop = loop };
    }
};

pub fn ensureSesVtWatcherArmed(state: *State, watcher: *SesVtWatcher, buffer: []u8) void {
    if (watcher.watched_fd != null) return;
    const vt_fd = state.runtime.getVtFd() orelse return;

    watcher.watched_fd = vt_fd;
    watcher.slot = .{ .state = state, .fd = vt_fd, .buffer = buffer, .watched_fd = &watcher.watched_fd };
    const file = xev.File.initFd(vt_fd);
    watcher.completion = .{};
    file.poll(watcher.loop, &watcher.completion, .read, SesVtSlot, &watcher.slot, sesVtCallback);
}

pub fn ensureSesCtlWatcherArmed(state: *State, watcher: *SesCtlWatcher, buffer: []u8) void {
    if (watcher.watched_fd != null) return;
    const ctl_fd = state.runtime.getCtlFd() orelse return;

    watcher.watched_fd = ctl_fd;
    watcher.slot = .{ .state = state, .fd = ctl_fd, .buffer = buffer, .watched_fd = &watcher.watched_fd };
    const file = xev.File.initFd(ctl_fd);
    watcher.completion = .{};
    file.poll(watcher.loop, &watcher.completion, .read, SesCtlSlot, &watcher.slot, sesCtlCallback);
}

pub fn ensureStdinWatcherArmed(state: *State, watcher: *StdinWatcher, buffer: []u8, hooks: *const HostHooks) void {
    if (watcher.armed) return;
    watcher.slot = .{ .state = state, .fd = hooks.stdin_fd, .buffer = buffer, .hooks = hooks };
    const file = xev.File.initFd(hooks.stdin_fd);
    watcher.completion = .{};
    file.poll(watcher.loop, &watcher.completion, .read, StdinSlot, &watcher.slot, stdinCallback);
    watcher.armed = true;
}

/// Best-effort synchronous SES VT catch-up.
///
/// This is used before revealing a previously hidden float. Some TUIs (notably
/// Codex-style redraw-heavy terminal apps) can generate a lot of viewport
/// updates while the float is hidden. If the frontend reveals the float before
/// draining those queued frames, the user sees stale history repaint/catch up
/// from the beginning instead of the latest viewport. Draining here advances the
/// pane VT models to the freshest available state before the first visible
/// render.
pub fn drainSesVtAvailable(state: *State, max_frames: usize, comptime context: []const u8) void {
    const vt_fd = state.runtime.getVtFd() orelse return;
    const buffer = state.allocator.alloc(u8, 1024 * 1024) catch |err| {
        core.logging.logError("terminal", context ++ ": failed to allocate VT catch-up buffer", err);
        return;
    };
    defer state.allocator.free(buffer);

    frontend_core.drainMuxVtFrames(
        vt_fd,
        buffer,
        max_frames,
        SesVtDispatchContext{ .state = state },
        dispatchSesVtFrame,
        dispatchOversizedSesVtFrame,
    ) catch |err| {
        core.logging.logError("terminal", context ++ ": failed to catch up SES VT frames", err);
        if (state.runtime.closeVtFdIf(vt_fd)) {
            state.notifications.showFor("Lost connection to ses daemon (VT) — reconnecting...", 5000);
        }
    };
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
            slot.state.notifications.showFor("Lost connection to ses daemon (VT) — reconnecting...", 5000);
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

    frontend_core.drainMuxVtFrames(
        vt_fd,
        slot.buffer,
        64,
        SesVtDispatchContext{ .state = slot.state },
        dispatchSesVtFrame,
        dispatchOversizedSesVtFrame,
    ) catch |read_err| {
        core.logging.logError("terminal", "failed to read SES VT frame", read_err);
        if (slot.watched_fd.* == slot.fd) slot.watched_fd.* = null;
        if (slot.state.runtime.closeVtFdIf(slot.fd)) {
            slot.state.notifications.showFor("Lost connection to ses daemon (VT) — reconnecting...", 5000);
        }
        return .disarm;
    };

    return .rearm;
}

fn dispatchSesVtFrame(ctx: SesVtDispatchContext, vt_event: frontend_core.VtFrameEvent, payload: []const u8) bool {
    const state = ctx.state;
    if (state.findPaneByPaneId(vt_event.pane_id)) |pane| {
        switch (vt_event.kind) {
            .output => {
                terminal_main.debugLogUuid(&pane.uuid, "vt recv: pane_id={d} output len={d}", .{ vt_event.pane_id, vt_event.payload_len });
                pane.feedPodOutput(payload);
                const osc_responses = pane.takeOscExpectedResponses();
                if (osc_responses > 0) {
                    var j: u16 = 0;
                    while (j < osc_responses) : (j += 1) {
                        state.enqueueOscReplyTarget(pane.uuid);
                    }
                }
                const csi_responses = pane.takeCsiExpectedResponses();
                if (csi_responses > 0) {
                    var j: u16 = 0;
                    while (j < csi_responses) : (j += 1) {
                        state.enqueueCsiReplyTarget(pane.uuid);
                    }
                }
                pane.vt.invalidateRenderState();
                state.needs_render = true;
            },
            .backlog_end => {
                terminal_main.debugLogUuid(&pane.uuid, "vt recv: pane_id={d} backlog_end", .{vt_event.pane_id});
                pane.vt.invalidateRenderState();
                state.needs_render = true;
                state.force_full_render = true;
            },
            .ignored => {},
        }
    } else {
        terminal_main.debugLog("vt recv: UNKNOWN pane_id={d} type={d} len={d} — no matching pane!", .{ vt_event.pane_id, vt_event.raw_frame_type, vt_event.payload_len });
    }
    return true;
}

fn dispatchOversizedSesVtFrame(ctx: SesVtDispatchContext, vt_event: frontend_core.VtFrameEvent) bool {
    _ = ctx;
    terminal_main.debugLog("vt recv: drained oversized pane_id={d} type={d} len={d}", .{ vt_event.pane_id, vt_event.raw_frame_type, vt_event.payload_len });
    return true;
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
            slot.state.notifications.showFor("Lost connection to ses daemon — reconnecting...", 5000);
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

fn stdinCallback(
    ctx: ?*StdinSlot,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.File,
    result: xev.PollError!xev.PollEvent,
) xev.CallbackAction {
    const slot = ctx orelse return .disarm;
    _ = result catch {
        slot.hooks.connectionLost(slot.state);
        return .disarm;
    };

    const n = slot.hooks.readInput(slot.fd, slot.buffer) catch {
        slot.hooks.connectionLost(slot.state);
        return .disarm;
    };
    if (n == 0) {
        slot.hooks.connectionLost(slot.state);
        return .disarm;
    }

    slot.hooks.handleInput(slot.state, slot.buffer[0..n]);
    return .rearm;
}
