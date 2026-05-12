const std = @import("std");
const posix = std.posix;
const core = @import("core");
const wire = core.wire;
const pop = @import("pop");

const terminal_main = @import("main.zig");
const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;
const CursorSnapshot = @import("state.zig").CursorSnapshot;

const actions = @import("loop_actions.zig");
const layout_mod = @import("layout.zig");
const focus_move = @import("focus_move.zig");
const lua_events = @import("lua_events.zig");

fn writeControlLogged(fd: posix.fd_t, msg_type: wire.MsgType, payload: []const u8, comptime context: []const u8) void {
    wire.writeControl(fd, msg_type, payload) catch |err| {
        core.logging.logError("terminal", context, err);
    };
}

fn readStructLogged(comptime T: type, fd: posix.fd_t, comptime context: []const u8) ?T {
    return wire.readStruct(T, fd) catch |err| {
        core.logging.logError("terminal", context, err);
        return null;
    };
}

fn readExactLogged(fd: posix.fd_t, dest: []u8, comptime context: []const u8) bool {
    wire.readExact(fd, dest) catch |err| {
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

    // Process all available messages (fire-and-forget responses may accumulate).
    var msgs: usize = 0;
    while (msgs < 32) : (msgs += 1) {
        const hdr = wire.tryReadControlHeader(fd) catch |err| switch (err) {
            error.WouldBlock => break,
            else => {
                core.logging.logError("terminal", "failed to read SES control header", err);
                if (state.runtime.closeCtlFdIf(fd)) {
                    state.notifications.showFor("Warning: Lost connection to ses daemon (CTL channel)", 5000);
                }
                break;
            },
        };
        const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        terminal_main.debugLog("ses msg: type=0x{x:0>4} len={d}", .{ hdr.msg_type, hdr.payload_len });

        switch (msg_type) {
            .notify => {
                handleNotify(state, fd, hdr.payload_len, buffer);
            },
            .targeted_notify => {
                handleTargetedNotify(state, fd, hdr.payload_len, buffer);
            },
            .pop_confirm => {
                handlePopConfirm(state, fd, hdr.payload_len, buffer);
            },
            .pop_choose => {
                handlePopChoose(state, fd, hdr.payload_len, buffer);
            },
            .shell_event => {
                handleShellEvent(state, fd, hdr.payload_len, buffer);
            },
            .send_keys => {
                handleSendKeys(state, fd, hdr.payload_len, buffer);
            },
            .focus_move => {
                handleFocusMove(state, fd, hdr.payload_len, buffer);
            },
            .exit_intent => {
                handleExitIntent(state, fd, hdr.payload_len, buffer);
            },
            .float_request => {
                handleFloatRequest(state, fd, hdr.payload_len, buffer);
            },
            .pane_exited => {
                handlePaneExited(state, fd, hdr.payload_len, buffer);
            },
            .session_state => {
                handleSessionState(state, fd, hdr.payload_len, buffer);
            },
            .session_stolen => {
                handleSessionStolen(state, fd, hdr.payload_len, buffer);
            },
            // Async responses from fire-and-forget requests:
            .ok, .pong => {
                skipPayload(fd, hdr.payload_len, buffer);
            },
            .get_pane_cwd => {
                handleCwdResponse(state, fd, hdr.payload_len, buffer);
            },
            .pane_info => {
                handlePaneInfoResponse(state, fd, hdr.payload_len, buffer);
            },
            .pane_not_found, .@"error" => {
                skipPayload(fd, hdr.payload_len, buffer);
            },
            else => {
                // Unknown message — skip payload.
                skipPayload(fd, hdr.payload_len, buffer);
            },
        }
    }
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
    if (payload_len < @sizeOf(wire.Notify)) {
        skipPayload(fd, payload_len, buffer);
        return;
    }
    const notify = readStructLogged(wire.Notify, fd, "failed to read notify payload") orelse return;
    const remaining = payload_len - @sizeOf(wire.Notify);
    if (notify.msg_len == 0 or notify.msg_len > buffer.len or notify.msg_len != remaining) {
        skipPayload(fd, payload_len - @sizeOf(wire.Notify), buffer);
        terminal_main.debugLog("notify: malformed message length", .{});
        return;
    }
    if (!readExactLogged(fd, buffer[0..notify.msg_len], "failed to read notify message")) return;
    const msg_copy = state.allocator.dupe(u8, buffer[0..notify.msg_len]) catch |err| {
        core.logging.logError("terminal", "failed to allocate notify message", err);
        return;
    };
    state.notifications.showWithOptions(msg_copy, .{
        .duration_ms = state.notifications.default_duration_ms,
        .style = state.notifications.default_style,
        .owned = true,
    });
    state.needs_render = true;
}

fn handleTargetedNotify(state: *State, fd: posix.fd_t, payload_len: u32, buffer: []u8) void {
    if (payload_len < @sizeOf(wire.TargetedNotify)) {
        skipPayload(fd, payload_len, buffer);
        return;
    }
    const notify = readStructLogged(wire.TargetedNotify, fd, "failed to read targeted_notify payload") orelse return;
    const remaining = payload_len - @sizeOf(wire.TargetedNotify);
    if (notify.msg_len == 0 or notify.msg_len > buffer.len or notify.msg_len != remaining) {
        skipPayload(fd, payload_len - @sizeOf(wire.TargetedNotify), buffer);
        terminal_main.debugLog("targeted_notify: malformed message length", .{});
        return;
    }
    if (!readExactLogged(fd, buffer[0..notify.msg_len], "failed to read targeted_notify message")) return;
    const msg_copy = state.allocator.dupe(u8, buffer[0..notify.msg_len]) catch |err| {
        core.logging.logError("terminal", "failed to allocate targeted_notify message", err);
        return;
    };
    const duration: i64 = if (notify.timeout_ms > 0) @as(i64, notify.timeout_ms) else 0;

    // Try to find pane with this UUID.
    if (state.findPaneByUuid(notify.uuid)) |pane| {
        const dur = if (duration > 0) duration else pane.notifications.default_duration_ms;
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
        if (std.mem.startsWith(u8, &tab_uuid, &notify.uuid)) {
            const dur = if (duration > 0) duration else tab.notifications.default_duration_ms;
            tab.notifications.showWithOptions(msg_copy, .{
                .duration_ms = dur,
                .style = tab.notifications.default_style,
                .owned = true,
            });
            state.needs_render = true;
            return;
        }
    }

    // Not found — free.
    state.allocator.free(msg_copy);
    state.needs_render = true;
}

fn handlePopConfirm(state: *State, fd: posix.fd_t, payload_len: u32, buffer: []u8) void {
    if (payload_len < @sizeOf(wire.PopConfirm)) {
        skipPayload(fd, payload_len, buffer);
        return;
    }
    const pc = readStructLogged(wire.PopConfirm, fd, "failed to read pop_confirm payload") orelse return;
    const remaining = payload_len - @sizeOf(wire.PopConfirm);
    if (pc.msg_len == 0 or pc.msg_len > buffer.len or pc.msg_len != remaining) {
        skipPayload(fd, payload_len - @sizeOf(wire.PopConfirm), buffer);
        terminal_main.debugLog("pop_confirm: malformed message length", .{});
        return;
    }
    if (!readExactLogged(fd, buffer[0..pc.msg_len], "failed to read pop_confirm message")) return;
    const msg = buffer[0..pc.msg_len];
    const timeout_ms: ?i64 = if (pc.timeout_ms > 0) @as(i64, pc.timeout_ms) else null;
    const target = resolvePopupTarget(state, pc.uuid);

    const confirm_cfg = switch (target.scope) {
        .pane => state.pop_config.pane.confirm,
        else => state.pop_config.carrier.confirm,
    };
    const opts: pop.ConfirmOptions = .{
        .timeout_ms = timeout_ms,
        .yes_label = confirm_cfg.yes_label,
        .no_label = confirm_cfg.no_label,
    };
    target.manager.showConfirmOwned(msg, opts) catch |err| {
        core.logging.logError("terminal", "failed to show IPC confirmation popup", err);
        state.notifications.show("Popup failed");
        state.needs_render = true;
        return;
    };
    setPendingPopupTarget(state, target);
    state.needs_render = true;
}

fn handlePopChoose(state: *State, fd: posix.fd_t, payload_len: u32, buffer: []u8) void {
    if (payload_len < @sizeOf(wire.PopChoose)) {
        skipPayload(fd, payload_len, buffer);
        return;
    }
    const pc = readStructLogged(wire.PopChoose, fd, "failed to read pop_choose payload") orelse return;
    const remaining_payload = payload_len - @sizeOf(wire.PopChoose);
    const timeout_ms: ?i64 = if (pc.timeout_ms > 0) @as(i64, pc.timeout_ms) else null;

    // Read title.
    var title: ?[]const u8 = null;
    if (pc.title_len > buffer.len or pc.title_len > remaining_payload) {
        skipPayload(fd, remaining_payload, buffer);
        terminal_main.debugLog("pop_choose: malformed title length", .{});
        return;
    }
    if (pc.title_len > 0) {
        if (!readExactLogged(fd, buffer[0..pc.title_len], "failed to read pop_choose title")) return;
        title = buffer[0..pc.title_len];
    }
    var consumed: u32 = pc.title_len;

    // Read items.
    var items_list: std.ArrayList([]const u8) = .empty;
    defer items_list.deinit(state.allocator);

    for (0..pc.item_count) |_| {
        if (remaining_payload - consumed < 2) {
            terminal_main.debugLog("pop_choose: truncated item header", .{});
            for (items_list.items) |item| state.allocator.free(item);
            return;
        }
        const item_len_buf = wire.readStruct(extern struct { len: u16 align(1) }, fd) catch |err| {
            terminal_main.debugLog("pop_choose: failed to read item header: {s}", .{@errorName(err)});
            for (items_list.items) |item| state.allocator.free(item);
            return;
        };
        consumed += 2;
        const item_len: usize = item_len_buf.len;
        if (item_len == 0 or item_len > buffer.len or item_len > remaining_payload - consumed) {
            skipPayload(fd, remaining_payload - consumed, buffer);
            terminal_main.debugLog("pop_choose: malformed item length", .{});
            for (items_list.items) |item| state.allocator.free(item);
            return;
        }
        wire.readExact(fd, buffer[0..item_len]) catch |err| {
            terminal_main.debugLog("pop_choose: failed to read item body: {s}", .{@errorName(err)});
            for (items_list.items) |item| state.allocator.free(item);
            return;
        };
        consumed += @intCast(item_len);
        const duped = state.allocator.dupe(u8, buffer[0..item_len]) catch |err| {
            terminal_main.debugLog("pop_choose: failed to copy item: {s}", .{@errorName(err)});
            for (items_list.items) |item| state.allocator.free(item);
            return;
        };
        items_list.append(state.allocator, duped) catch |err| {
            terminal_main.debugLog("pop_choose: failed to append item: {s}", .{@errorName(err)});
            state.allocator.free(duped);
            for (items_list.items) |item| state.allocator.free(item);
            return;
        };
    }
    if (consumed != remaining_payload) {
        skipPayload(fd, remaining_payload - consumed, buffer);
        terminal_main.debugLog("pop_choose: trailing payload length mismatch", .{});
        for (items_list.items) |item| state.allocator.free(item);
        return;
    }

    if (items_list.items.len == 0) return;
    const target = resolvePopupTarget(state, pc.uuid);

    const choose_cfg = switch (target.scope) {
        .pane => state.pop_config.pane.choose,
        else => state.pop_config.carrier.choose,
    };
    const opts: pop.PickerOptions = .{
        .title = title,
        .timeout_ms = timeout_ms,
        .visible_count = choose_cfg.visible_count,
    };
    target.manager.showPickerOwned(items_list.items, opts) catch |err| {
        core.logging.logError("terminal", "failed to show IPC picker popup", err);
        for (items_list.items) |item| state.allocator.free(item);
        state.notifications.show("Popup failed");
        state.needs_render = true;
        return;
    };
    for (items_list.items) |item| state.allocator.free(item);
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
    if (payload_len < @sizeOf(wire.ForwardedShellEvent)) {
        skipPayload(fd, payload_len, buffer);
        return;
    }
    const ev = readStructLogged(wire.ForwardedShellEvent, fd, "failed to read shell_event payload") orelse return;
    const remaining = payload_len - @sizeOf(wire.ForwardedShellEvent);

    // Read trailing cmd + cwd.
    var cmd: ?[]const u8 = null;
    var cwd: ?[]const u8 = null;
    var trail_offset: usize = 0;
    if (remaining > 0 and remaining <= buffer.len) {
        if (!readExactLogged(fd, buffer[0..remaining], "failed to read shell_event trail")) return;
        if (@as(usize, ev.cmd_len) + @as(usize, ev.cwd_len) > remaining) {
            terminal_main.debugLogUuid(&ev.uuid, "shell_event: malformed trail lengths", .{});
            return;
        }
        if (ev.cmd_len > 0) {
            cmd = buffer[0..ev.cmd_len];
            trail_offset = ev.cmd_len;
        }
        if (ev.cwd_len > 0) {
            cwd = buffer[trail_offset .. trail_offset + ev.cwd_len];
        }
    } else if (remaining > buffer.len) {
        skipPayload(fd, remaining, buffer);
        terminal_main.debugLogUuid(&ev.uuid, "shell_event: trail too large", .{});
        return;
    }

    const uuid = ev.uuid;
    const phase_start = (ev.phase == 1);
    const status_opt: ?i32 = if (ev.status != 0 or !phase_start) ev.status else null;
    const dur_opt: ?u64 = if (ev.duration_ms > 0) @intCast(ev.duration_ms) else null;
    const jobs_opt: ?u16 = if (ev.jobs > 0 or ev.phase == 0) ev.jobs else null;
    const running = (ev.running != 0);
    const started_at_opt: ?u64 = if (ev.started_at > 0) @intCast(ev.started_at) else null;

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
    if (payload_len < @sizeOf(wire.SendKeys)) {
        skipPayload(fd, payload_len, buffer);
        return;
    }
    const sk = readStructLogged(wire.SendKeys, fd, "failed to read send_keys payload") orelse return;
    const remaining = payload_len - @sizeOf(wire.SendKeys);
    if (sk.data_len == 0 or sk.data_len > buffer.len or sk.data_len != remaining) {
        skipPayload(fd, remaining, buffer);
        terminal_main.debugLogUuid(&sk.uuid, "send_keys: malformed data length", .{});
        return;
    }
    if (!readExactLogged(fd, buffer[0..sk.data_len], "failed to read send_keys data")) return;

    const zero_uuid: [32]u8 = .{0} ** 32;
    if (std.mem.eql(u8, &sk.uuid, &zero_uuid)) {
        // Broadcast to all panes.
        for (state.view.tab_views.items) |*tab| {
            var it = tab.layout.splits.valueIterator();
            while (it.next()) |pane_ptr| {
                pane_ptr.*.write(buffer[0..sk.data_len]) catch |err| {
                    terminal_main.debugLogUuid(&pane_ptr.*.uuid, "send_keys broadcast write failed: {s}", .{@errorName(err)});
                };
            }
        }
    } else if (state.findPaneByUuid(sk.uuid)) |pane| {
        pane.write(buffer[0..sk.data_len]) catch |err| {
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
    if (payload_len < @sizeOf(wire.FocusMove)) {
        skipPayload(fd, payload_len, buffer);
        return;
    }
    const fm = readStructLogged(wire.FocusMove, fd, "failed to read focus_move payload") orelse return;
    const remaining = payload_len - @sizeOf(wire.FocusMove);
    if (remaining > 0) skipPayload(fd, remaining, buffer);

    const dir: ?layout_mod.Layout.Direction = switch (fm.dir) {
        0 => .left,
        1 => .right,
        2 => .up,
        3 => .down,
        else => null,
    };
    if (dir) |d| {
        _ = focus_move.perform(state, d);
        state.needs_render = true;
    }
}

fn handleExitIntent(state: *State, fd: posix.fd_t, payload_len: u32, buffer: []u8) void {
    if (payload_len < @sizeOf(wire.ExitIntent)) {
        skipPayload(fd, payload_len, buffer);
        return;
    }
    _ = readStructLogged(wire.ExitIntent, fd, "failed to read exit_intent payload") orelse return;
    const remaining = payload_len - @sizeOf(wire.ExitIntent);
    if (remaining > 0) skipPayload(fd, remaining, buffer);

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
        state.drop_next_input_batch = true;
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
    if (payload_len < @sizeOf(wire.PaneUuid)) {
        skipPayload(fd, payload_len, buffer);
        return;
    }
    const pu = readStructLogged(wire.PaneUuid, fd, "failed to read pane_exited payload") orelse return;
    const remaining = payload_len - @sizeOf(wire.PaneUuid);
    if (remaining > 0) skipPayload(fd, remaining, buffer);
    terminal_main.debugLogUuid(&pu.uuid, "pane_exited received from SES", .{});

    // Mark the pane as dead in all tabs and floats.
    for (state.view.tab_views.items) |*tab| {
        var it = tab.layout.splits.valueIterator();
        while (it.next()) |pane_ptr| {
            if (std.mem.eql(u8, &pane_ptr.*.uuid, &pu.uuid)) {
                pane_ptr.*.backend.pod.dead = true;
            }
        }
    }
    for (state.view.float_views.items) |pane| {
        if (std.mem.eql(u8, &pane.uuid, &pu.uuid)) {
            pane.backend.pod.dead = true;
        }
    }
    state.needs_render = true;
}

/// Handle async get_pane_cwd response.
fn handleCwdResponse(state: *State, fd: posix.fd_t, payload_len: u32, buffer: []u8) void {
    if (payload_len < @sizeOf(wire.PaneCwd)) {
        skipPayload(fd, payload_len, buffer);
        return;
    }
    const resp = readStructLogged(wire.PaneCwd, fd, "failed to read pane cwd response") orelse return;
    const remaining = payload_len - @sizeOf(wire.PaneCwd);

    if (resp.cwd_len == 0) {
        if (remaining > 0) skipPayload(fd, remaining, buffer);
        return;
    }
    if (resp.cwd_len > buffer.len or resp.cwd_len != remaining) {
        skipPayload(fd, remaining, buffer);
        terminal_main.debugLogUuid(&resp.uuid, "pane cwd response: malformed cwd length", .{});
        return;
    }
    if (!readExactLogged(fd, buffer[0..resp.cwd_len], "failed to read pane cwd response trail")) return;

    state.setPaneShell(resp.uuid, null, buffer[0..resp.cwd_len], null, null, null);
}

/// Handle async pane_info response (updates fg_process cache).
fn handlePaneInfoResponse(state: *State, fd: posix.fd_t, payload_len: u32, buffer: []u8) void {
    if (payload_len < @sizeOf(wire.PaneInfoResp)) {
        skipPayload(fd, payload_len, buffer);
        return;
    }
    const resp = readStructLogged(wire.PaneInfoResp, fd, "failed to read pane_info response") orelse return;
    const remaining_payload = payload_len - @sizeOf(wire.PaneInfoResp);

    // Calculate total trailing bytes.
    const trail_total: usize = @as(usize, resp.name_len) + @as(usize, resp.fg_len) +
        @as(usize, resp.cwd_len) + @as(usize, resp.tty_len) +
        @as(usize, resp.socket_path_len) + @as(usize, resp.session_name_len) +
        @as(usize, resp.layout_path_len) + @as(usize, resp.last_cmd_len) +
        @as(usize, resp.base_process_len) + @as(usize, resp.sticky_pwd_len);
    if (trail_total != remaining_payload) {
        skipPayload(fd, remaining_payload, buffer);
        terminal_main.debugLogUuid(&resp.uuid, "pane_info response: malformed trail length", .{});
        return;
    }

    // Read and store pane name (Pokemon name).
    if (resp.name_len > 0) {
        if (resp.name_len <= buffer.len) {
            if (!readExactLogged(fd, buffer[0..resp.name_len], "failed to read pane_info name")) return;
            const pane_name = state.allocator.dupe(u8, buffer[0..resp.name_len]) catch |err| blk: {
                core.logging.logError("terminal", "failed to copy pane_info pane name", err);
                break :blk null;
            };
            if (pane_name) |name| {
                state.setPaneNameOwned(resp.uuid, name);

                // If pokemon widget is enabled by default, load the sprite
                // But only if not manually toggled and content is null (first load)
                if (state.pop_config.widgets.pokemon.enabled) {
                    // Find the pane with this UUID and load its sprite
                    // Check all floats
                    for (state.view.float_views.items) |pane| {
                        const uuid_match = std.mem.eql(u8, pane.uuid[0..], resp.uuid[0..]);
                        if (uuid_match and pane.pokemon_initialized and
                            !pane.pokemon_state.manually_toggled and pane.pokemon_state.sprite_content == null)
                        {
                            pane.pokemon_state.loadSprite(name, false) catch |err| {
                                core.logging.logError("terminal", "failed to load float sprite after pane-name update", err);
                            };
                        }
                    }
                    // Check splits
                    var split_iter = state.currentLayout().splits.valueIterator();
                    while (split_iter.next()) |pane| {
                        if (std.mem.eql(u8, pane.*.uuid[0..], resp.uuid[0..]) and pane.*.pokemon_initialized and
                            !pane.*.pokemon_state.manually_toggled and pane.*.pokemon_state.sprite_content == null)
                        {
                            pane.*.pokemon_state.loadSprite(name, false) catch |err| {
                                core.logging.logError("terminal", "failed to load split sprite after pane-name update", err);
                            };
                        }
                    }
                    state.needs_render = true;
                }
            }
        } else {
            skipPayload(fd, resp.name_len, buffer);
        }
    }

    // Read fg_process.
    var fg_name: ?[]u8 = null;
    if (resp.fg_len > 0 and resp.fg_len <= buffer.len) {
        if (!readExactLogged(fd, buffer[0..resp.fg_len], "failed to read pane_info fg process")) return;
        fg_name = state.allocator.dupe(u8, buffer[0..resp.fg_len]) catch |err| blk: {
            core.logging.logError("terminal", "failed to copy pane_info fg process", err);
            break :blk null;
        };
    } else if (resp.fg_len > 0) {
        skipPayload(fd, resp.fg_len, buffer);
    }

    // Skip remaining trailing bytes.
    const remaining = trail_total -| @as(usize, resp.name_len) -| @as(usize, resp.fg_len);
    if (remaining > 0) {
        skipPayload(fd, @intCast(remaining), buffer);
    }

    // Update process cache.
    if (resp.name_len > 0) {
        state.syncPaneName(resp.uuid);
    }
    const fg_pid: ?i32 = if (resp.fg_pid != 0) resp.fg_pid else null;
    if (fg_name != null or fg_pid != null) {
        state.setPaneProc(resp.uuid, fg_name, fg_pid);
    }
    if (fg_name) |n| state.allocator.free(n);
}

fn skipPayload(fd: posix.fd_t, len: u32, buffer: []u8) void {
    var remaining: usize = len;
    while (remaining > 0) {
        const chunk = @min(remaining, buffer.len);
        if (!readExactLogged(fd, buffer[0..chunk], "failed to skip IPC payload")) return;
        remaining -= chunk;
    }
}
