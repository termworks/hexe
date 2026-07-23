const std = @import("std");
const posix = std.posix;
const core = @import("core");
const frontend_core = @import("frontend_core");
const wire = core.wire;
const pop = @import("pop");

const terminal_main = @import("main.zig");
const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;
const CursorSnapshot = @import("state.zig").CursorSnapshot;

const actions = @import("loop_actions.zig");
const focus_move = @import("focus_move.zig");
const lua_events = @import("lua_events.zig");

/// How long a newly opened float may swallow already-in-flight input (the key
/// that triggered it). Those bytes sit in the tty buffer when the float request
/// arrives, so they land within milliseconds; a generous window still expires
/// long before a user's next deliberate keystroke.
const TRIGGER_KEY_DROP_WINDOW_MS: i64 = 200;

const CtlDispatchContext = struct {
    state: *State,
    fd: posix.fd_t,
    buffer: []u8,
};

// Every CTL frame payload the terminal reads, and every reply it writes, goes
// through the three helpers below — and they all carried the 10-SECOND wire
// default. The frame HEADER is read non-blockingly, but once a header landed the
// payload read blocked: a daemon that wrote a header and then stalled (or a
// truncated frame) froze the UI for 10s per frame, up to 32 frames per wakeup.
// The payload is normally already sitting in the socket buffer behind its
// header, so these budgets are generous; what they rule out is the hang.
const CTL_READ_TIMEOUT_MS: i32 = 500;
const CTL_WRITE_TIMEOUT_MS: i32 = 1_000;

fn writeControlLogged(fd: posix.fd_t, msg_type: wire.MsgType, payload: []const u8, comptime context: []const u8) void {
    wire.writeControlTimeout(fd, msg_type, payload, CTL_WRITE_TIMEOUT_MS) catch |err| {
        core.logging.logError("terminal", context, err);
    };
}

fn readStructLogged(comptime T: type, fd: posix.fd_t, comptime context: []const u8) ?T {
    return wire.readStructTimeout(T, fd, CTL_READ_TIMEOUT_MS) catch |err| {
        core.logging.logError("terminal", context, err);
        return null;
    };
}

fn readExactLogged(fd: posix.fd_t, dest: []u8, comptime context: []const u8) bool {
    wire.readExactTimeout(fd, dest, CTL_READ_TIMEOUT_MS) catch |err| {
        core.logging.logError("terminal", context, err);
        return false;
    };
    return true;
}

fn sendFailedFloatResult(state: *State, exit_code: i32, comptime context: []const u8) void {
    const ctl_fd = state.runtime.getCtlFd() orelse {
        core.logging.warn("terminal", context ++ ": SES CTL channel is unavailable", .{});
        return;
    };
    const result = wire.FloatResult{
        .uuid = .{0} ** 32,
        .exit_code = exit_code,
        .output_len = 0,
    };
    writeControlLogged(ctl_fd, .float_result, std.mem.asBytes(&result), context);
}

/// Handle binary control messages from the SES control channel.
/// Reads all available messages (CTL fd is non-blocking).
pub fn handleSesMessage(state: *State, buffer: []u8) void {
    const fd = state.runtime.getCtlFd() orelse return;

    // Replay async pushes that a synchronous reader consumed mid-request
    // BEFORE reading new frames, preserving event order. Without this a
    // float_request or pane_exited that raced a sync call was silently lost
    // ("hexe float" hanging, frozen pane views — intermittently).
    replayQueuedPushes(state, buffer);

    frontend_core.drainCtlFrameHeaders(
        fd,
        32,
        CtlDispatchContext{ .state = state, .fd = fd, .buffer = buffer },
        dispatchCtlFrame,
    ) catch |err| {
        core.logging.logError("terminal", "failed to read SES control header", err);
        if (state.runtime.closeCtlFdIf(fd)) {
            state.notifications.showFor("Lost connection to ses daemon — reconnecting...", 5000);
        }
    };
}

fn replayQueuedPushes(state: *State, buffer: []u8) void {
    var n: usize = 0;
    while (n < 64) : (n += 1) {
        const push = state.runtime.popPendingCtlPush() orelse break;
        defer state.runtime.freeCtlPushPayload(push.payload);
        dispatchQueuedPush(state, push, buffer);
    }
}

/// Re-dispatch one captured push through the regular frame handlers. The
/// handlers read their payload from an fd, so the captured bytes are staged
/// in a pipe: payloads are capped well below the 64K pipe buffer, so the
/// write never blocks, and the read side then behaves exactly like the CTL
/// socket did when the frame originally arrived.
fn dispatchQueuedPush(state: *State, push: core.FrontendClient.QueuedPush, buffer: []u8) void {
    var fds: [2]posix.fd_t = undefined;
    const rc = std.os.linux.pipe2(&fds, .{ .CLOEXEC = true });
    if (std.os.linux.E.init(rc) != .SUCCESS) return;
    defer posix.close(fds[0]);
    {
        defer posix.close(fds[1]);
        var off: usize = 0;
        while (off < push.payload.len) {
            off += posix.write(fds[1], push.payload[off..]) catch {
                return;
            };
        }
    }
    const hdr: wire.ControlHeader = .{
        .msg_type = push.msg_type,
        .request_id = push.request_id,
        .payload_len = @intCast(push.payload.len),
    };
    const event = frontend_core.ctlFrameEventFromHeader(hdr);
    _ = dispatchCtlFrame(.{ .state = state, .fd = fds[0], .buffer = buffer }, event);
}

fn dispatchCtlFrame(ctx: CtlDispatchContext, ctl_event: frontend_core.CtlFrameEvent) bool {
    const state = ctx.state;
    const fd = ctx.fd;
    const buffer = ctx.buffer;

    terminal_main.debugLog("ses msg: type=0x{x:0>4} len={d}", .{ ctl_event.raw_msg_type, ctl_event.payload_len });

    switch (ctl_event.kind) {
        .notify => {
            handleNotify(state, fd, ctl_event.payload_len, buffer);
        },
        .targeted_notify => {
            handleTargetedNotify(state, fd, ctl_event.payload_len, buffer);
        },
        .pop_confirm => {
            handlePopConfirm(state, fd, ctl_event.payload_len, buffer);
        },
        .pop_choose => {
            handlePopChoose(state, fd, ctl_event.payload_len, buffer);
        },
        .shell_event => {
            handleShellEvent(state, fd, ctl_event.payload_len, buffer);
        },
        .send_keys => {
            handleSendKeys(state, fd, ctl_event.payload_len, buffer);
        },
        .focus_move => {
            handleFocusMove(state, fd, ctl_event.payload_len, buffer);
        },
        .exit_intent => {
            handleExitIntent(state, fd, ctl_event.payload_len, buffer);
        },
        .float_request => {
            handleFloatRequest(state, fd, ctl_event.payload_len, buffer);
        },
        .pane_exited => {
            // A pane (possibly the one being searched) is about to be freed;
            // tear down any active scrollback search first so it can't hold a
            // dangling screen pointer (PLAN 3.3).
            if (state.isSearchActive()) state.exitSearchMode();
            handlePaneExited(state, fd, ctl_event.payload_len, buffer);
        },
        .session_state => {
            handleSessionState(state, fd, ctl_event.payload_len, buffer);
        },
        .session_stolen => {
            handleSessionStolen(state, fd, ctl_event.payload_len, buffer);
        },
        .ignorable_response => {
            skipPayload(fd, ctl_event.payload_len, buffer);
        },
        .cwd_response => {
            handleCwdResponse(state, fd, ctl_event.payload_len, buffer);
        },
        .pane_info_response => {
            handlePaneInfoResponse(state, fd, ctl_event.payload_len, buffer);
        },
        .error_response => {
            skipPayload(fd, ctl_event.payload_len, buffer);
        },
        .unknown => {
            // Unknown message — skip payload.
            skipPayload(fd, ctl_event.payload_len, buffer);
        },
    }

    return true;
}

fn handleSessionStolen(state: *State, fd: posix.fd_t, payload_len: u32, buffer: []u8) void {
    skipPayload(fd, payload_len, buffer);

    state.runtime.markSessionStolen();
}

fn handleSessionState(state: *State, fd: posix.fd_t, payload_len: u32, buffer: []u8) void {
    if (payload_len == 0 or payload_len > wire.MAX_PAYLOAD_LEN) {
        skipPayload(fd, payload_len, buffer);
        return;
    }

    const session_json = state.allocator.alloc(u8, payload_len) catch {
        skipPayload(fd, payload_len, buffer);
        return;
    };
    defer state.allocator.free(session_json);
    if (!readExactLogged(fd, session_json, "failed to read session_state payload")) return;

    terminal_main.debugLog("handleSessionState: payload_len={d} (queued)", .{payload_len});
    state.runtime.queueSessionStateJson(session_json);
}

fn handleNotify(state: *State, fd: posix.fd_t, payload_len: u32, buffer: []u8) void {
    var payload = frontend_core.readNotifyPayload(state.allocator, fd, payload_len, buffer) catch |err| {
        core.logging.logError("terminal", "failed to read notify payload", err);
        return;
    } orelse return;
    defer payload.deinit(state.allocator);

    const msg_copy = payload.message;
    payload.message = payload.message[0..0];
    state.notifications.showWithOptions(msg_copy, .{
        .duration_ms = state.notifications.default_duration_ms,
        .style = state.notifications.default_style,
        .owned = true,
    });
    state.needs_render = true;
}

fn handleTargetedNotify(state: *State, fd: posix.fd_t, payload_len: u32, buffer: []u8) void {
    var payload = frontend_core.readTargetedNotifyPayload(state.allocator, fd, payload_len, buffer) catch |err| {
        core.logging.logError("terminal", "failed to read targeted_notify payload", err);
        return;
    } orelse return;
    defer payload.deinit(state.allocator);

    // Try to find pane with this UUID.
    if (state.findPaneByUuid(payload.uuid)) |pane| {
        const msg_copy = payload.message;
        payload.message = payload.message[0..0];
        const dur = payload.timeout_ms orelse pane.notifications.default_duration_ms;
        pane.notifications.showWithOptions(msg_copy, .{
            .duration_ms = dur,
            .style = pane.notifications.default_style,
            .owned = true,
        });
        state.needs_render = true;
        return;
    }

    // Try to find tab with this UUID prefix.
    for (state.view.tab_views.items, 0..) |*tab, tab_idx| {
        const tab_uuid = state.runtime.tabUuid(tab_idx) orelse continue;
        if (std.mem.startsWith(u8, &tab_uuid, &payload.uuid)) {
            const msg_copy = payload.message;
            payload.message = payload.message[0..0];
            const dur = payload.timeout_ms orelse tab.notifications.default_duration_ms;
            tab.notifications.showWithOptions(msg_copy, .{
                .duration_ms = dur,
                .style = tab.notifications.default_style,
                .owned = true,
            });
            state.needs_render = true;
            return;
        }
    }

    state.needs_render = true;
}

fn handlePopConfirm(state: *State, fd: posix.fd_t, payload_len: u32, buffer: []u8) void {
    var payload = frontend_core.readPopConfirmPayload(state.allocator, fd, payload_len, buffer) catch |err| {
        core.logging.logError("terminal", "failed to read pop_confirm payload", err);
        return;
    } orelse return;
    defer payload.deinit(state.allocator);

    const target = resolvePopupTarget(state, payload.uuid);

    const confirm_cfg = switch (target.scope) {
        .pane => state.pop_config.pane.confirm,
        else => state.pop_config.carrier.confirm,
    };
    const opts: pop.ConfirmOptions = .{
        .timeout_ms = payload.timeout_ms,
        .yes_label = confirm_cfg.yes_label,
        .no_label = confirm_cfg.no_label,
    };
    target.manager.showConfirmOwned(payload.message, opts) catch |err| {
        core.logging.logError("terminal", "failed to show IPC confirmation popup", err);
        state.notifications.show("Popup failed");
        state.needs_render = true;
        return;
    };
    setPendingPopupTarget(state, target);
    state.needs_render = true;
}

fn handlePopChoose(state: *State, fd: posix.fd_t, payload_len: u32, buffer: []u8) void {
    var payload = frontend_core.readPopChoosePayload(state.allocator, fd, payload_len, buffer) catch |err| {
        core.logging.logError("terminal", "failed to read pop_choose payload", err);
        return;
    } orelse return;
    defer payload.deinit(state.allocator);

    if (payload.items.len == 0) return;
    const target = resolvePopupTarget(state, payload.uuid);

    const choose_cfg = switch (target.scope) {
        .pane => state.pop_config.pane.choose,
        else => state.pop_config.carrier.choose,
    };
    const opts: pop.PickerOptions = .{
        .title = payload.title,
        .timeout_ms = payload.timeout_ms,
        .visible_count = choose_cfg.visible_count,
    };
    target.manager.showPickerOwned(payload.items, opts) catch |err| {
        core.logging.logError("terminal", "failed to show IPC picker popup", err);
        state.notifications.show("Popup failed");
        state.needs_render = true;
        return;
    };
    setPendingPopupTarget(state, target);
    state.needs_render = true;
}

const PopupTarget = struct {
    manager: *pop.PopupManager,
    scope: pop.Scope,
    tab_idx: usize = 0,
    pane: ?*Pane = null,
};

fn resolvePopupTarget(state: *State, uuid: [32]u8) PopupTarget {
    const zero_uuid: [32]u8 = .{0} ** 32;
    if (!std.mem.eql(u8, &uuid, &zero_uuid)) {
        if (state.findPaneByUuid(uuid)) |pane| {
            return .{ .manager = &pane.popups, .scope = .pane, .pane = pane };
        }
        for (state.view.tab_views.items, 0..) |*tab, tab_idx| {
            const tab_uuid = state.runtime.tabUuid(tab_idx) orelse continue;
            if (std.mem.startsWith(u8, &tab_uuid, &uuid)) {
                return .{ .manager = &tab.popups, .scope = .tab, .tab_idx = tab_idx };
            }
        }
    }
    return .{ .manager = &state.popups, .scope = .mux };
}

fn setPendingPopupTarget(state: *State, target: PopupTarget) void {
    state.pending_pop_response = true;
    state.pending_pop_scope = target.scope;
    switch (target.scope) {
        .mux => {
            state.pending_pop_pane = null;
            state.pending_pop_tab = 0;
        },
        .tab => {
            state.pending_pop_pane = null;
            state.pending_pop_tab = target.tab_idx;
        },
        .pane => {
            state.pending_pop_pane = target.pane;
        },
    }
}

fn handleShellEvent(state: *State, fd: posix.fd_t, payload_len: u32, buffer: []u8) void {
    var payload = frontend_core.readShellEventPayload(state.allocator, fd, payload_len, buffer) catch |err| {
        core.logging.logError("terminal", "failed to read shell_event payload", err);
        return;
    } orelse return;
    defer payload.deinit(state.allocator);

    state.applyFrontendShellEvent(payload);

    const uuid = payload.uuid;
    const cmd: ?[]const u8 = payload.cmd;
    const cwd: ?[]const u8 = payload.cwd;
    const phase_start = payload.phase_start;
    const status_opt = payload.status;
    const dur_opt = payload.duration_ms;
    const jobs_opt = payload.jobs;
    const running = payload.running;
    const started_at_opt = payload.started_at_ms;

    // Job count delta notifications.
    const old_jobs: ?u16 = if (state.getPaneShell(uuid)) |info| info.jobs else null;
    const old_running: bool = if (state.getPaneShell(uuid)) |info| info.running else false;
    if (jobs_opt) |new_jobs| {
        if (old_jobs) |old| {
            if (old == 0 and new_jobs > 0) {
                var msg_buf: [64]u8 = undefined;
                const notify_msg = std.fmt.bufPrint(&msg_buf, "Background jobs: {d}", .{new_jobs}) catch |err| blk: {
                    core.logging.logError("terminal", "failed to format background jobs notification", err);
                    break :blk null;
                };
                if (notify_msg) |m| {
                    state.notifications.show(m);
                }
            } else if (old > 0 and new_jobs == 0) {
                state.notifications.show("Background jobs finished");
            }
        }
    }

    if (phase_start) {
        const now_ms: u64 = @intCast(std.time.milliTimestamp());
        const started_at_ms = started_at_opt orelse now_ms;
        state.setPaneShellRunning(uuid, running, started_at_ms, cmd, cwd, jobs_opt);

        if (old_running != running) {
            if (state.config._lua_runtime) |rt| {
                rt.lua.createTable(0, 10);
                _ = rt.lua.pushString("pane_shell_running_changed");
                rt.lua.setField(-2, "event");
                _ = rt.lua.pushString(uuid[0..]);
                rt.lua.setField(-2, "pane_uuid");
                rt.lua.pushBoolean(old_running);
                rt.lua.setField(-2, "previous_running");
                rt.lua.pushBoolean(running);
                rt.lua.setField(-2, "running");
                _ = rt.lua.pushString("start");
                rt.lua.setField(-2, "phase");
                if (cmd) |c| {
                    _ = rt.lua.pushString(c);
                    rt.lua.setField(-2, "command");
                }
                if (cwd) |c| {
                    _ = rt.lua.pushString(c);
                    rt.lua.setField(-2, "cwd");
                }
                if (jobs_opt) |j| {
                    rt.lua.pushInteger(j);
                    rt.lua.setField(-2, "jobs");
                }
                rt.lua.pushInteger(@intCast(started_at_ms));
                rt.lua.setField(-2, "started_at_ms");
                rt.lua.pushInteger(@intCast(now_ms));
                rt.lua.setField(-2, "now_ms");
                lua_events.emitAutocmdWithPayloadOnStack(rt, "pane_shell_running_changed");
            }
        }
    } else {
        const now_ms: u64 = @intCast(std.time.milliTimestamp());
        var computed_dur: ?u64 = dur_opt;
        if (state.getPaneShell(uuid)) |info| {
            if (info.started_at_ms) |t0| {
                if (now_ms >= t0) computed_dur = now_ms - t0;
            }
        }
        state.setPaneShellRunning(uuid, running, null, null, null, null);
        state.setPaneShell(uuid, cmd, cwd, status_opt, computed_dur, jobs_opt);
        state.clearPaneShellStartedAt(uuid);

        if (state.config._lua_runtime) |rt| {
            rt.lua.createTable(0, 10);
            _ = rt.lua.pushString("command_finished");
            rt.lua.setField(-2, "event");
            _ = rt.lua.pushString(uuid[0..]);
            rt.lua.setField(-2, "pane_uuid");
            if (cmd) |c| {
                _ = rt.lua.pushString(c);
                rt.lua.setField(-2, "command");
            }
            if (cwd) |c| {
                _ = rt.lua.pushString(c);
                rt.lua.setField(-2, "cwd");
            }
            if (status_opt) |s| {
                rt.lua.pushInteger(s);
                rt.lua.setField(-2, "status");
            }
            if (computed_dur) |d| {
                rt.lua.pushInteger(@intCast(d));
                rt.lua.setField(-2, "duration_ms");
            }
            if (jobs_opt) |j| {
                rt.lua.pushInteger(j);
                rt.lua.setField(-2, "jobs");
            }
            rt.lua.pushInteger(@intCast(now_ms));
            rt.lua.setField(-2, "now_ms");
            lua_events.emitAutocmdWithPayloadOnStack(rt, "command_finished");
        }

        if (old_running != running) {
            if (state.config._lua_runtime) |rt| {
                rt.lua.createTable(0, 10);
                _ = rt.lua.pushString("pane_shell_running_changed");
                rt.lua.setField(-2, "event");
                _ = rt.lua.pushString(uuid[0..]);
                rt.lua.setField(-2, "pane_uuid");
                rt.lua.pushBoolean(old_running);
                rt.lua.setField(-2, "previous_running");
                rt.lua.pushBoolean(running);
                rt.lua.setField(-2, "running");
                _ = rt.lua.pushString("end");
                rt.lua.setField(-2, "phase");
                if (cmd) |c| {
                    _ = rt.lua.pushString(c);
                    rt.lua.setField(-2, "command");
                }
                if (cwd) |c| {
                    _ = rt.lua.pushString(c);
                    rt.lua.setField(-2, "cwd");
                }
                if (jobs_opt) |j| {
                    rt.lua.pushInteger(j);
                    rt.lua.setField(-2, "jobs");
                }
                rt.lua.pushInteger(@intCast(now_ms));
                rt.lua.setField(-2, "now_ms");
                lua_events.emitAutocmdWithPayloadOnStack(rt, "pane_shell_running_changed");
            }
        }
    }

    state.needs_render = true;
}

fn handleSendKeys(state: *State, fd: posix.fd_t, payload_len: u32, buffer: []u8) void {
    var payload = frontend_core.readSendKeysPayload(state.allocator, fd, payload_len, buffer) catch |err| {
        core.logging.logError("terminal", "failed to read send_keys payload", err);
        return;
    } orelse return;
    defer payload.deinit(state.allocator);

    const zero_uuid: [32]u8 = .{0} ** 32;
    if (std.mem.eql(u8, &payload.uuid, &zero_uuid)) {
        // Broadcast to all panes.
        for (state.view.tab_views.items) |*tab| {
            var it = tab.layout.splits.valueIterator();
            while (it.next()) |pane_ptr| {
                pane_ptr.*.write(payload.data) catch |err| {
                    terminal_main.debugLogUuid(&pane_ptr.*.uuid, "send_keys broadcast write failed: {s}", .{@errorName(err)});
                };
            }
        }
    } else if (state.findPaneByUuid(payload.uuid)) |pane| {
        pane.write(payload.data) catch |err| {
            terminal_main.debugLogUuid(&pane.uuid, "send_keys targeted write failed: {s}", .{@errorName(err)});
        };
    }
}

/// Send popup response back to ses (for CLI-triggered popups).
pub fn sendPopResponse(state: *State) void {
    if (!state.pending_pop_response) return;
    state.pending_pop_response = false;

    const fd = state.runtime.getCtlFd() orelse {
        core.logging.warn("terminal", "sendPopResponse skipped: SES CTL channel is unavailable", .{});
        return;
    };

    // Get the correct PopupManager based on scope.
    const popups: *pop.PopupManager = switch (state.pending_pop_scope) {
        .mux => &state.popups,
        .tab => &state.view.tab_views.items[state.pending_pop_tab].popups,
        .pane => if (state.pending_pop_pane) |pane| &pane.popups else &state.popups,
    };

    var resp: wire.PopResponse = .{
        .response_type = 0, // cancelled
        .selected_idx = 0,
    };

    // Try to get confirm result.
    if (popups.getConfirmResult()) |confirmed| {
        resp.response_type = if (confirmed) 1 else 0;
        writeControlLogged(fd, .pop_response, std.mem.asBytes(&resp), "failed to send pop confirm response");
        popups.clearResults();
        return;
    }

    // Try to get picker result.
    if (popups.getPickerResult()) |selected| {
        resp.response_type = 2;
        resp.selected_idx = @intCast(selected);
        writeControlLogged(fd, .pop_response, std.mem.asBytes(&resp), "failed to send pop picker response");
        popups.clearResults();
        return;
    }

    // Cancelled.
    writeControlLogged(fd, .pop_response, std.mem.asBytes(&resp), "failed to send pop cancel response");
    popups.clearResults();
}

fn handleFocusMove(state: *State, fd: posix.fd_t, payload_len: u32, buffer: []u8) void {
    const payload = frontend_core.readFocusMovePayload(fd, payload_len, buffer) catch |err| {
        core.logging.logError("terminal", "failed to read focus_move payload", err);
        return;
    } orelse return;

    const dir: @import("layout.zig").Layout.Direction = switch (payload.direction orelse return) {
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
    };
    _ = focus_move.perform(state, dir);
    state.needs_render = true;
}

fn handleExitIntent(state: *State, fd: posix.fd_t, payload_len: u32, buffer: []u8) void {
    _ = frontend_core.readExitIntentPayload(fd, payload_len, buffer) catch |err| {
        core.logging.logError("terminal", "failed to read exit_intent payload", err);
        return;
    } orelse return;

    // If no tabs, allow exit.
    if (state.view.tab_views.items.len == 0) {
        sendExitIntentResultPub(state, true);
        return;
    }

    const is_last_split = (state.currentLayout().splitCount() <= 1 and state.view.tab_views.items.len <= 1);
    if (!is_last_split or !state.config.confirm_on_exit) {
        sendExitIntentResultPub(state, true);
        return;
    }

    // Need confirmation. Only one pending request at a time.
    if (state.pending_action != null or state.popups.isBlocked() or state.pending_exit_intent) {
        sendExitIntentResultPub(state, false);
        return;
    }

    state.pending_action = .exit_intent;
    // Mark that we have a pending exit_intent (no longer an fd, use sentinel).
    state.pending_exit_intent = true;
    state.popups.showConfirm("Exit terminal session?", .{}) catch |err| {
        core.logging.logError("terminal", "failed to show exit-intent confirmation popup", err);
        state.notifications.show("Confirmation failed");
        state.pending_action = null;
        state.pending_exit_intent = false;
        sendExitIntentResultPub(state, true);
        state.needs_render = true;
        return;
    };
    state.needs_render = true;
}

pub fn sendExitIntentResultPub(state: *State, allow: bool) void {
    const ctl_fd = state.runtime.getCtlFd() orelse {
        core.logging.warn("terminal", "sendExitIntentResult skipped: SES CTL channel is unavailable", .{});
        return;
    };
    const result = wire.ExitIntentResult{ .allow = if (allow) 1 else 0 };
    writeControlLogged(ctl_fd, .exit_intent_result, std.mem.asBytes(&result), "failed to send exit intent result");
}

fn handleFloatRequest(state: *State, fd: posix.fd_t, payload_len: u32, buffer: []u8) void {
    if (payload_len < @sizeOf(wire.FloatRequest)) {
        skipPayload(fd, payload_len, buffer);
        return;
    }
    const fr = readStructLogged(wire.FloatRequest, fd, "failed to read float_request payload") orelse return;
    const trail_len = payload_len - @sizeOf(wire.FloatRequest);

    // Read trailing data.
    if (trail_len > buffer.len or trail_len == 0) {
        skipPayload(fd, trail_len, buffer);
        return;
    }
    if (!readExactLogged(fd, buffer[0..trail_len], "failed to read float_request trail")) return;

    // Parse trailing: cmd + title + cwd + result_path + env entries.
    var offset: usize = 0;
    const cmd = if (fr.cmd_len > 0) blk: {
        if (offset + fr.cmd_len > trail_len) {
            terminal_main.debugLog("handleFloatRequest: malformed command trail", .{});
            return;
        }
        const s = buffer[offset .. offset + fr.cmd_len];
        offset += fr.cmd_len;
        break :blk s;
    } else return;

    const title_slice = if (fr.title_len > 0) blk: {
        if (offset + fr.title_len > trail_len) {
            terminal_main.debugLog("handleFloatRequest: malformed title trail", .{});
            return;
        }
        const s = buffer[offset .. offset + fr.title_len];
        offset += fr.title_len;
        break :blk s;
    } else blk: {
        break :blk @as([]const u8, "");
    };

    const cwd_slice = if (fr.cwd_len > 0) blk: {
        if (offset + fr.cwd_len > trail_len) {
            terminal_main.debugLog("handleFloatRequest: malformed cwd trail", .{});
            return;
        }
        const s = buffer[offset .. offset + fr.cwd_len];
        offset += fr.cwd_len;
        break :blk s;
    } else blk: {
        break :blk @as([]const u8, "");
    };

    var result_path_slice: []const u8 = "";
    if (fr.result_path_len > 0) {
        if (offset + fr.result_path_len > trail_len) {
            terminal_main.debugLog("handleFloatRequest: malformed result-path trail", .{});
            return;
        }
        result_path_slice = buffer[offset .. offset + fr.result_path_len];
        offset += fr.result_path_len;
    }

    var exit_key_slice: []const u8 = "";
    if (fr.exit_key_len > 0) {
        if (offset + fr.exit_key_len > trail_len) {
            terminal_main.debugLog("handleFloatRequest: malformed exit-key trail", .{});
            return;
        }
        exit_key_slice = buffer[offset .. offset + fr.exit_key_len];
        offset += fr.exit_key_len;
    }

    var isolation_profile_slice: []const u8 = "";
    if (fr.isolation_profile_len > 0) {
        if (offset + fr.isolation_profile_len > trail_len) {
            terminal_main.debugLog("handleFloatRequest: malformed isolation-profile trail", .{});
            return;
        }
        isolation_profile_slice = buffer[offset .. offset + fr.isolation_profile_len];
        offset += fr.isolation_profile_len;
    }

    // Parse env entries.
    var env_list: std.ArrayList([]const u8) = .empty;
    defer env_list.deinit(state.allocator);
    for (0..fr.env_count) |_| {
        if (offset + 2 > trail_len) {
            terminal_main.debugLog("handleFloatRequest: malformed env entry header", .{});
            return;
        }
        const entry_len = std.mem.readInt(u16, buffer[offset..][0..2], .little);
        offset += 2;
        if (offset + entry_len > trail_len) {
            terminal_main.debugLog("handleFloatRequest: malformed env entry body", .{});
            return;
        }
        env_list.append(state.allocator, buffer[offset .. offset + entry_len]) catch |err| {
            terminal_main.debugLog("handleFloatRequest: failed to append env entry: {s}", .{@errorName(err)});
            return;
        };
        offset += entry_len;
    }
    if (offset != trail_len) {
        terminal_main.debugLog("handleFloatRequest: trailing payload length mismatch", .{});
        return;
    }

    const wait_for_exit = (fr.flags & 1) != 0;
    const isolated = (fr.flags & 2) != 0;

    // Build extra_env (isolated flag).
    var extra_env_list: std.ArrayList([]const u8) = .empty;
    defer extra_env_list.deinit(state.allocator);
    var owned_extra: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_extra.items) |e| state.allocator.free(e);
        owned_extra.deinit(state.allocator);
    }
    if (isolated) {
        const entry = state.allocator.dupe(u8, "HEXE_POD_ISOLATE=1") catch |err| {
            core.logging.logError("terminal", "handleFloatRequest failed to allocate isolated env entry", err);
            return;
        };
        owned_extra.append(state.allocator, entry) catch |err| {
            terminal_main.debugLog("handleFloatRequest: failed to track isolated env entry: {s}", .{@errorName(err)});
            state.allocator.free(entry);
            return;
        };
        extra_env_list.append(state.allocator, entry) catch |err| {
            core.logging.logError("terminal", "handleFloatRequest failed to append isolated env entry", err);
            return;
        };
    }
    if (wait_for_exit and result_path_slice.len > 0) {
        const entry = std.fmt.allocPrint(state.allocator, "HEXE_FLOAT_RESULT_FILE={s}", .{result_path_slice}) catch |err| {
            core.logging.logError("terminal", "handleFloatRequest failed to allocate result-file env entry", err);
            return;
        };
        owned_extra.append(state.allocator, entry) catch |err| {
            terminal_main.debugLog("handleFloatRequest: failed to track result-file env entry: {s}", .{@errorName(err)});
            state.allocator.free(entry);
            return;
        };
        extra_env_list.append(state.allocator, entry) catch |err| {
            core.logging.logError("terminal", "handleFloatRequest failed to append result-file env entry", err);
            return;
        };
    }

    // Determine spawn cwd - use explicit cwd if provided, else try focused pane, else the terminal process cwd.
    var spawn_cwd: ?[]const u8 = null;
    var mux_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (cwd_slice.len > 0) {
        spawn_cwd = cwd_slice;
    } else {
        const focused_pane = if (state.activeFloatingIndex()) |idx| blk: {
            if (idx < state.view.float_views.items.len) break :blk state.view.float_views.items[idx];
            break :blk @as(?*Pane, null);
        } else state.currentLayout().getFocusedPane();
        if (focused_pane) |pane| {
            spawn_cwd = state.getReliableCwd(pane);
        }
        // Fallback to the terminal process CWD.
        if (spawn_cwd == null) {
            spawn_cwd = std.posix.getcwd(&mux_cwd_buf) catch |err| blk: {
                core.logging.logError("terminal", "handleFloatRequest failed to get fallback cwd", err);
                break :blk null;
            };
        }
    }

    // Save cursor state before opening wait-for-exit CLI float so we can
    // restore even when float process exits without cleaning cursor state.
    var cursor_snapshot: ?CursorSnapshot = null;
    if (wait_for_exit) {
        const source_pane = if (state.activeFloatingIndex()) |idx| blk: {
            if (idx < state.view.float_views.items.len) break :blk state.view.float_views.items[idx];
            break :blk @as(?*Pane, null);
        } else state.currentLayout().getFocusedPane();

        if (source_pane) |pane| {
            const rel = pane.vt.getCursor();
            cursor_snapshot = .{
                .source_uuid = pane.uuid,
                .rel_x = rel.x,
                .rel_y = rel.y,
                .style = pane.getCursorStyle(),
                .visible = pane.isCursorVisible(),
            };
        }
    }

    // Unfocus current pane.
    const old_uuid = state.getCurrentFocusedUuid();
    if (state.activeFloatingIndex()) |idx| {
        if (idx < state.view.float_views.items.len) state.syncPaneUnfocus(state.view.float_views.items[idx]);
    } else if (state.currentLayout().getFocusedPane()) |tiled| {
        state.syncPaneUnfocus(tiled);
    }

    const env_items: ?[]const []const u8 = if (env_list.items.len > 0) env_list.items else null;
    const extra_items: ?[]const []const u8 = if (extra_env_list.items.len > 0) extra_env_list.items else null;
    const isolation_profile: ?[]const u8 = if (isolation_profile_slice.len > 0) isolation_profile_slice else null;
    const use_pod = (!wait_for_exit) or isolated or (isolation_profile != null);
    const title: ?[]const u8 = if (title_slice.len > 0) title_slice else null;

    terminal_main.debugLog("handleFloatRequest: wait_for_exit={} isolation_profile={s} use_pod={}", .{ wait_for_exit, isolation_profile orelse "", use_pod });

    const command = state.allocator.dupe(u8, cmd) catch |err| {
        core.logging.logError("terminal", "failed to allocate float command", err);
        state.notifications.show("Float failed");
        state.needs_render = true;
        if (wait_for_exit) {
            sendFailedFloatResult(state, 127, "failed to send failed float result after command allocation failure");
        }
        return;
    };
    defer state.allocator.free(command);

    const float_size = actions.FloatSize{
        .width = fr.size_width,
        .height = fr.size_height,
        .shift_x = fr.shift_x,
        .shift_y = fr.shift_y,
        .exit_key = if (exit_key_slice.len > 0) exit_key_slice else null,
    };
    const new_uuid = actions.createAdhocFloatWithSize(state, command, title, spawn_cwd, env_items, extra_items, use_pod, float_size, isolation_profile) catch {
        // Spawn failed — if wait_for_exit, send error result so CLI doesn't hang.
        if (wait_for_exit) {
            sendFailedFloatResult(state, 127, "failed to send failed float result");
        }
        return;
    };

    if (state.view.float_views.items.len > 0) {
        state.syncPaneFocus(state.view.float_views.items[state.view.float_views.items.len - 1], old_uuid);
        // Only swallow input that is already in flight with the float request
        // (the trigger key's leftover bytes). See State.drop_input_until_ms.
        state.drop_input_until_ms = std.time.milliTimestamp() + TRIGGER_KEY_DROP_WINDOW_MS;
    }
    state.needs_render = true;

    if (wait_for_exit) {
        if (state.view.float_views.items.len > 0) {
            state.setPaneCaptureOutput(state.view.float_views.items[state.view.float_views.items.len - 1].uuid, true);
        }
        const stored_path = if (result_path_slice.len > 0)
            state.allocator.dupe(u8, result_path_slice) catch |err| blk: {
                core.logging.logError("terminal", "failed to allocate float result path", err);
                break :blk null;
            }
        else
            null;
        state.pending_float_requests.put(new_uuid, .{
            .result_path = stored_path,
            .cursor_snapshot = cursor_snapshot,
        }) catch |err| {
            core.logging.logError("terminal", "failed to track pending float request", err);
            if (stored_path) |path| state.allocator.free(path);
            state.notifications.show("Float result tracking failed");
            sendFailedFloatResult(state, 127, "failed to send failed float result after tracking failure");
        };
    }
}

fn handlePaneExited(state: *State, fd: posix.fd_t, payload_len: u32, buffer: []u8) void {
    const payload = frontend_core.readPaneUuidPayload(fd, payload_len, buffer) catch |err| {
        core.logging.logError("terminal", "failed to read pane_exited payload", err);
        return;
    } orelse return;
    terminal_main.debugLogUuid(&payload.uuid, "pane_exited received from SES", .{});
    state.applyFrontendPaneExited(payload.uuid);

    // Mark the pane as dead in all tabs and floats.
    for (state.view.tab_views.items) |*tab| {
        var it = tab.layout.splits.valueIterator();
        while (it.next()) |pane_ptr| {
            if (std.mem.eql(u8, &pane_ptr.*.uuid, &payload.uuid)) {
                pane_ptr.*.backend.pod.dead = true;
            }
        }
    }
    for (state.view.float_views.items) |pane| {
        if (std.mem.eql(u8, &pane.uuid, &payload.uuid)) {
            pane.backend.pod.dead = true;
        }
    }
    state.needs_render = true;
}

/// Handle async get_pane_cwd response.
fn handleCwdResponse(state: *State, fd: posix.fd_t, payload_len: u32, buffer: []u8) void {
    var payload = frontend_core.readPaneCwdPayload(state.allocator, fd, payload_len, buffer) catch |err| {
        core.logging.logError("terminal", "failed to read pane cwd response", err);
        return;
    } orelse return;
    defer payload.deinit(state.allocator);

    state.applyFrontendPaneCwd(payload.uuid, payload.cwd);
    state.setPaneShell(payload.uuid, null, payload.cwd, null, null, null);
}

/// Handle async pane_info response (updates fg_process cache).
fn handlePaneInfoResponse(state: *State, fd: posix.fd_t, payload_len: u32, buffer: []u8) void {
    var payload = frontend_core.readPaneInfoPayload(state.allocator, fd, payload_len, buffer) catch |err| {
        core.logging.logError("terminal", "failed to read pane_info response", err);
        return;
    } orelse return;
    defer payload.deinit(state.allocator);

    state.applyFrontendPaneInfo(payload.uuid, payload.name, payload.fg_name, payload.fg_pid);
    if (payload.name) |name| {
        const pane_name = state.allocator.dupe(u8, name) catch |err| {
            core.logging.logError("terminal", "failed to copy pane_info pane name", err);
            return;
        };
        state.setPaneNameOwned(payload.uuid, pane_name);
        applyPaneNameVisuals(state, payload.uuid, name);
    }

    if (payload.fg_name != null or payload.fg_pid != null) {
        state.setPaneProc(payload.uuid, payload.fg_name, payload.fg_pid);
    }
}

fn applyPaneNameVisuals(state: *State, uuid: [32]u8, name: []const u8) void {
    if (!state.pop_config.widgets.pokemon.enabled) return;

    // If pokemon widget is enabled by default, load the sprite only if not
    // manually toggled and content is null (first load).
    for (state.view.float_views.items) |pane| {
        const uuid_match = std.mem.eql(u8, pane.uuid[0..], uuid[0..]);
        if (uuid_match and pane.pokemon_initialized and
            !pane.pokemon_state.manually_toggled and pane.pokemon_state.sprite_content == null)
        {
            pane.pokemon_state.loadSprite(name, false) catch |err| {
                core.logging.logError("terminal", "failed to load float sprite after pane-name update", err);
            };
        }
    }

    var split_iter = state.currentLayout().splits.valueIterator();
    while (split_iter.next()) |pane| {
        if (std.mem.eql(u8, pane.*.uuid[0..], uuid[0..]) and pane.*.pokemon_initialized and
            !pane.*.pokemon_state.manually_toggled and pane.*.pokemon_state.sprite_content == null)
        {
            pane.*.pokemon_state.loadSprite(name, false) catch |err| {
                core.logging.logError("terminal", "failed to load split sprite after pane-name update", err);
            };
        }
    }
    state.needs_render = true;
}

fn skipPayload(fd: posix.fd_t, len: u32, buffer: []u8) void {
    var remaining: usize = len;
    while (remaining > 0) {
        const chunk = @min(remaining, buffer.len);
        if (!readExactLogged(fd, buffer[0..chunk], "failed to skip IPC payload")) return;
        remaining -= chunk;
    }
}
