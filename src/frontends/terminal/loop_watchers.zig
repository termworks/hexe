const std = @import("std");
const posix = std.posix;
const core = @import("core");
const frontend_core = @import("frontend_core");
const xev = @import("xev").Dynamic;

const State = @import("state.zig").State;
const HostHooks = @import("loop_host_hooks.zig").HostHooks;
const terminal_main = @import("main.zig");
const loop_ipc = @import("loop_ipc.zig");

// SES fd watchers use heap-allocated per-connection nodes (the same model as
// the SES daemon's watchers). The completion handed to io_uring must stay
// alive until its CQE — and a poll on a since-closed fd may NEVER complete,
// so a node can neither be reused nor freed at replace time. When the
// connection fd changes (reattach, reconnect), the old node is ORPHANED: a
// fresh node is armed immediately for the new fd, and the orphan is left
// allocated (a stale CQE just disarms it). Waiting for the old CQE instead —
// the previous design — left the NEW fd unwatched forever: after a reattach
// the loop only woke on unrelated CTL pushes and VT replay trickled in at
// one frame per ~2.5s ("reattach is stuck").
const SesVtSlot = struct {
    state: *State,
    fd: posix.fd_t,
    gen: u64,
    buffer: []u8,
    watcher: *SesVtWatcher,
    node: *SesVtNode,
};

pub const SesVtNode = struct {
    completion: xev.Completion = .{},
    slot: SesVtSlot = undefined,
};

pub const SesVtWatcher = struct {
    loop: *xev.Loop,
    current: ?*SesVtNode = null,
};

const SesVtDispatchContext = struct {
    state: *State,
};

const SesCtlSlot = struct {
    state: *State,
    fd: posix.fd_t,
    gen: u64,
    buffer: []u8,
    watcher: *SesCtlWatcher,
    node: *SesCtlNode,
};

pub const SesCtlNode = struct {
    completion: xev.Completion = .{},
    slot: SesCtlSlot = undefined,
};

pub const SesCtlWatcher = struct {
    loop: *xev.Loop,
    current: ?*SesCtlNode = null,
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
    const vt_fd = state.runtime.getVtFd() orelse {
        watcher.current = null; // connection gone; orphan any node
        return;
    };
    const gen = state.runtime.vtConnGen();
    if (watcher.current) |node| {
        // Compare the GENERATION, not just the fd number: a reconnect often
        // reuses the number, but the old poll watches the old (closed) file
        // description and will never fire for the new connection.
        if (node.slot.fd == vt_fd and node.slot.gen == gen) return;
        watcher.current = null; // connection replaced: orphan, arm fresh below
    }
    const node = state.allocator.create(SesVtNode) catch |err| {
        core.logging.logError("terminal", "failed to allocate SES VT watcher node", err);
        return;
    };
    node.* = .{};
    node.slot = .{ .state = state, .fd = vt_fd, .gen = gen, .buffer = buffer, .watcher = watcher, .node = node };
    watcher.current = node;
    // Fresh connection: any partial-frame progress belonged to the old one.
    state.mux_vt_reader.reset();
    const file = xev.File.initFd(vt_fd);
    file.poll(watcher.loop, &node.completion, .read, SesVtSlot, &node.slot, sesVtCallback);
}

pub fn ensureSesCtlWatcherArmed(state: *State, watcher: *SesCtlWatcher, buffer: []u8) void {
    const ctl_fd = state.runtime.getCtlFd() orelse {
        watcher.current = null;
        return;
    };
    const gen = state.runtime.ctlConnGen();
    if (watcher.current) |node| {
        if (node.slot.fd == ctl_fd and node.slot.gen == gen) return;
        watcher.current = null;
    }
    const node = state.allocator.create(SesCtlNode) catch |err| {
        core.logging.logError("terminal", "failed to allocate SES CTL watcher node", err);
        return;
    };
    node.* = .{};
    node.slot = .{ .state = state, .fd = ctl_fd, .gen = gen, .buffer = buffer, .watcher = watcher, .node = node };
    watcher.current = node;
    const file = xev.File.initFd(ctl_fd);
    file.poll(watcher.loop, &node.completion, .read, SesCtlSlot, &node.slot, sesCtlCallback);
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

    state.mux_vt_reader.drain(
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
    // Stale CQE for an orphaned node (fd was replaced): just stop. The node
    // stays allocated — freeing here races xev's batch processing, and
    // orphans are rare (one per reconnect/reattach) and tiny.
    if (slot.watcher.current != slot.node) return .disarm;
    _ = result catch {
        if (slot.watcher.current == slot.node) slot.watcher.current = null;
        if (slot.state.runtime.closeVtFdIf(slot.fd)) {
            slot.state.notifications.showFor("Lost connection to ses daemon (VT) — reconnecting...", 5000);
        }
        return .disarm;
    };

    const vt_fd = slot.state.runtime.getVtFd() orelse {
        if (slot.watcher.current == slot.node) slot.watcher.current = null;
        return .disarm;
    };
    if (vt_fd != slot.fd) {
        if (slot.watcher.current == slot.node) slot.watcher.current = null;
        return .disarm;
    }

    slot.state.mux_vt_reader.drain(
        vt_fd,
        slot.buffer,
        64,
        SesVtDispatchContext{ .state = slot.state },
        dispatchSesVtFrame,
        dispatchOversizedSesVtFrame,
    ) catch |read_err| {
        core.logging.logError("terminal", "failed to read SES VT frame", read_err);
        if (slot.watcher.current == slot.node) slot.watcher.current = null;
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
                // During backlog replay, feed the VT silently: scheduling a
                // render per 16K chunk repainted the whole UI hundreds of
                // times and made reattaching to a large history feel stuck.
                // backlog_end triggers the single full repaint. If the end
                // frame is ever lost, any other render trigger (statusbar
                // tick, input) still paints the current VT state — the
                // suppression only skips per-chunk scheduling.
                if (!pane.backlog_replaying) {
                    pane.vt.invalidateRenderState();
                    state.needs_render = true;
                }
            },
            .backlog_end => {
                terminal_main.debugLogUuid(&pane.uuid, "vt recv: pane_id={d} backlog_end", .{vt_event.pane_id});
                pane.backlog_replaying = false;
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
    if (slot.watcher.current != slot.node) return .disarm;
    _ = result catch {
        if (slot.watcher.current == slot.node) slot.watcher.current = null;
        if (slot.state.runtime.closeCtlFdIf(slot.fd)) {
            slot.state.notifications.showFor("Lost connection to ses daemon — reconnecting...", 5000);
        }
        return .disarm;
    };

    const ctl_fd = slot.state.runtime.getCtlFd() orelse {
        if (slot.watcher.current == slot.node) slot.watcher.current = null;
        return .disarm;
    };
    if (ctl_fd != slot.fd) {
        if (slot.watcher.current == slot.node) slot.watcher.current = null;
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
