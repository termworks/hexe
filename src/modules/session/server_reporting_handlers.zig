//! Result + reporting CTL handlers (exit_intent_result, float_result,
//! pane_info, status), extracted from server.zig (PLAN.md 2.3 god-object
//! split). Pure move: Server methods taking `*Server`, dispatched by name.
const std = @import("std");
const posix = std.posix;
const core = @import("core");
const wire = core.wire;
const ses = @import("main.zig");
const state = @import("state.zig");
const server = @import("server.zig");
const Server = server.Server;

/// Handle exit_intent_result from MUX — forward to waiting CLI.
pub fn handleBinaryExitIntentResult(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.ExitIntentResult)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "exit_intent_result: payload too small");
        return;
    }
    const result = wire.readStruct(wire.ExitIntentResult, fd) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "exit_intent_result request read failed", err);
        self.sendBinaryError(fd, "exit_intent_result: read failed");
        return;
    };
    if (self.pending_exit_intent_cli_fd) |cli_fd| {
        // Same single-owner rule as float_result: replyOrClose queues the
        // fd on write failure, so a direct close here would double-close
        // it. Route the success path through the queue too.
        self.replyOrClose(cli_fd, .exit_intent_result, std.mem.asBytes(&result));
        self.queueCtlClose(cli_fd, null);
        self.pending_exit_intent_cli_fd = null;
    } else {
        core.logging.warn("ses", "exit_intent_result arrived without pending CLI fd from mux fd={d}", .{fd});
    }
}

/// Handle float_result from MUX — forward to waiting CLI.
pub fn handleBinaryFloatResult(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.FloatResult)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "float_result: payload too small");
        return;
    }
    const result = wire.readStruct(wire.FloatResult, fd) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "float_result request read failed", err);
        self.sendBinaryError(fd, "float_result: read failed");
        return;
    };
    const trail_len = payload_len - @sizeOf(wire.FloatResult);

    // Find CLI fd by UUID.
    var cli_fd: ?posix.fd_t = null;
    if (self.pending_float_cli_fds.fetchRemove(result.uuid)) |entry| {
        cli_fd = entry.value;
    } else {
        // Try zero UUID (pending assignment).
        const zero_uuid: [32]u8 = .{0} ** 32;
        if (self.pending_float_cli_fds.fetchRemove(zero_uuid)) |entry| {
            cli_fd = entry.value;
        }
    }

    if (cli_fd) |cfd| {
        // Forward the full message to CLI. The CLI fd is closed via the
        // pending-close queue in every branch: replyOrClose/sendBinaryError
        // already queue it on write failure, and a direct posix.close here
        // would double-close the same fd number (which may have been
        // reused by then). queueCtlClose dedups, so routing the success
        // path through it too gives the fd exactly one owner.
        if (trail_len > 0 and trail_len <= buf.len) {
            wire.readExact(fd, buf[0..trail_len]) catch |err| {
                self.ctlStreamDesynced(fd, "mid-message read failed");
                core.logging.warnWithSource("ses", "float_result trail read failed: fd={d} err={s}", .{ fd, @errorName(err) }, @src());
                self.queueCtlClose(cfd, null);
                return;
            };
            self.replyOrCloseWithTrail(cfd, .float_result, std.mem.asBytes(&result), buf[0..trail_len]);
        } else if (trail_len > buf.len) {
            core.logging.warn("ses", "float_result trail too large: fd={d} len={d}", .{ fd, trail_len });
            self.skipBinaryPayload(fd, @intCast(trail_len), buf);
            self.sendBinaryError(cfd, "float_result: trail too large");
        } else {
            self.replyOrClose(cfd, .float_result, std.mem.asBytes(&result));
        }
        self.queueCtlClose(cfd, null);
    } else {
        // No CLI waiting — skip trailing data.
        core.logging.warn("ses", "float_result arrived without pending CLI fd for uuid={s}", .{result.uuid[0..8]});
        if (trail_len > 0) self.skipBinaryPayload(fd, @intCast(trail_len), buf);
    }
}

/// Handle binary pane_info query — respond with PaneInfoResp.
/// Does NOT close the fd — caller is responsible for closing if needed.
pub fn handleBinaryPaneInfo(self: *Server, fd: posix.fd_t, uuid: [32]u8) void {
    ses.debugLog("pane_info: uuid={s} fd={d}", .{ uuid[0..8], fd });
    const pane = self.ses_state.store.panes.get(uuid) orelse {
        ses.debugLog("pane_info: not found", .{});
        self.replyOrClose(fd, .pane_not_found, &.{});
        return;
    };

    var resp: wire.PaneInfoResp = .{
        .uuid = uuid,
        .pid = pane.child_pid,
        .fg_pid = pane.fg_pid orelse pane.child_pid,
        .base_pid = pane.child_pid,
        .pane_id = pane.pane_id,
        .cols = pane.cols,
        .rows = pane.rows,
        .cursor_x = pane.cursor_x,
        .cursor_y = pane.cursor_y,
        .cursor_style = pane.cursor_style,
        .cursor_visible = @intFromBool(pane.cursor_visible),
        .alt_screen = @intFromBool(pane.alt_screen),
        .is_focused = @intFromBool(pane.is_focused),
        .pane_type = @intFromEnum(pane.pane_type),
        .state = @intFromEnum(pane.state),
        .last_status = if (pane.last_status) |s| s else 0,
        .has_last_status = @intFromBool(pane.last_status != null),
        .last_duration_ms = if (pane.last_duration_ms) |d| @intCast(d) else 0,
        .has_last_duration = @intFromBool(pane.last_duration_ms != null),
        .last_jobs = pane.last_jobs orelse 0,
        .has_last_jobs = @intFromBool(pane.last_jobs != null),
        .created_at = pane.created_at,
        .sticky_key = pane.sticky_key orelse 0,
        .has_sticky_key = @intFromBool(pane.sticky_key != null),
        .created_from = .{0} ** 32,
        .focused_from = .{0} ** 32,
        .has_created_from = 0,
        .has_focused_from = 0,
        .name_len = 0,
        .fg_len = 0,
        .cwd_len = 0,
        .tty_len = 0,
        .socket_path_len = 0,
        .session_name_len = 0,
        .layout_path_len = 0,
        .last_cmd_len = 0,
        .base_process_len = 0,
        .sticky_pwd_len = 0,
    };

    if (pane.created_from) |cf| {
        resp.created_from = cf;
        resp.has_created_from = 1;
    }
    if (pane.focused_from) |ff| {
        resp.focused_from = ff;
        resp.has_focused_from = 1;
    }

    // Gather trailing data in order: name, fg, cwd, tty, socket, session_name, layout, last_cmd, base_proc, sticky_pwd
    var trail_buf: [8192]u8 = undefined;
    var trail_len: usize = 0;

    // Name
    if (pane.name) |name| {
        ses.debugLog("pane_info: sending name='{s}' len={d}", .{ name, name.len });
        const n = @min(name.len, trail_buf.len - trail_len);
        @memcpy(trail_buf[trail_len .. trail_len + n], name[0..n]);
        resp.name_len = @intCast(n);
        trail_len += n;
    }

    // Foreground process
    if (pane.getProcForegroundProcess()) |fg| {
        const n = @min(fg.name.len, trail_buf.len - trail_len);
        @memcpy(trail_buf[trail_len .. trail_len + n], fg.name[0..n]);
        resp.fg_len = @intCast(n);
        resp.fg_pid = fg.pid;
        trail_len += n;
    } else if (pane.fg_process) |proc| {
        const n = @min(proc.len, trail_buf.len - trail_len);
        @memcpy(trail_buf[trail_len .. trail_len + n], proc[0..n]);
        resp.fg_len = @intCast(n);
        trail_len += n;
    }

    // CWD
    const cwd = pane.getProcCwd() orelse pane.cwd;
    if (cwd) |c| {
        const n = @min(c.len, trail_buf.len - trail_len);
        @memcpy(trail_buf[trail_len .. trail_len + n], c[0..n]);
        resp.cwd_len = @intCast(n);
        trail_len += n;
    }

    // TTY
    if (pane.getProcTty()) |tty| {
        const n = @min(tty.len, trail_buf.len - trail_len);
        @memcpy(trail_buf[trail_len .. trail_len + n], tty[0..n]);
        resp.tty_len = @intCast(n);
        trail_len += n;
    }

    // Socket path
    {
        const sp = pane.pod_socket_path;
        const n = @min(sp.len, trail_buf.len - trail_len);
        @memcpy(trail_buf[trail_len .. trail_len + n], sp[0..n]);
        resp.socket_path_len = @intCast(n);
        trail_len += n;
    }

    // Session name (from attached client)
    if (pane.attached_to) |client_id| {
        if (self.ses_state.getClient(client_id)) |client| {
            if (client.session_name) |sn| {
                const n = @min(sn.len, trail_buf.len - trail_len);
                @memcpy(trail_buf[trail_len .. trail_len + n], sn[0..n]);
                resp.session_name_len = @intCast(n);
                trail_len += n;
            }
        }
    }

    // Layout path
    if (pane.layout_path) |path| {
        const n = @min(path.len, trail_buf.len - trail_len);
        @memcpy(trail_buf[trail_len .. trail_len + n], path[0..n]);
        resp.layout_path_len = @intCast(n);
        trail_len += n;
    }

    // Last command
    if (pane.last_cmd) |cmd| {
        const n = @min(cmd.len, trail_buf.len - trail_len);
        @memcpy(trail_buf[trail_len .. trail_len + n], cmd[0..n]);
        resp.last_cmd_len = @intCast(n);
        trail_len += n;
    }

    // Base process name
    if (pane.getProcProcessName()) |proc| {
        const n = @min(proc.len, trail_buf.len - trail_len);
        @memcpy(trail_buf[trail_len .. trail_len + n], proc[0..n]);
        resp.base_process_len = @intCast(n);
        trail_len += n;
    }

    // Sticky pwd
    if (pane.sticky_pwd) |pwd| {
        const n = @min(pwd.len, trail_buf.len - trail_len);
        @memcpy(trail_buf[trail_len .. trail_len + n], pwd[0..n]);
        resp.sticky_pwd_len = @intCast(n);
        trail_len += n;
    }

    self.replyOrCloseWithTrail(fd, .pane_info, std.mem.asBytes(&resp), trail_buf[0..trail_len]);
}

/// Handle binary status query from CLI — respond with StatusResp + entries.
pub fn handleBinaryStatus(self: *Server, fd: posix.fd_t, full_mode: bool) void {
    ses.debugLog("status: full={} fd={d} clients={d} panes={d}", .{ full_mode, fd, self.ses_state.store.clients.items.len, self.ses_state.store.panes.count() });
    // Count entries
    var orphaned_count: u16 = 0;
    var sticky_count: u16 = 0;
    var pane_iter = self.ses_state.store.panes.iterator();
    while (pane_iter.next()) |_entry| {
        const p = _entry.value_ptr;
        if (p.state == .orphaned) orphaned_count += 1;
        if (p.state == .sticky) sticky_count += 1;
    }

    const hdr = wire.StatusResp{
        .client_count = @intCast(self.ses_state.store.clients.items.len),
        .detached_count = @intCast(self.ses_state.store.detached_sessions.count()),
        .orphaned_count = orphaned_count,
        .sticky_count = sticky_count,
        .full_mode = @intFromBool(full_mode),
    };

    const alloc = self.ses_state.allocator;

    // Build the entire response in a dynamic buffer
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);

    // Header
    if (!self.appendStatusBytesOrClose(fd, &buf, std.mem.asBytes(&hdr), "status header")) return;

    // Connected clients
    for (self.ses_state.store.clients.items) |client| {
        var sc: wire.StatusClient = .{
            .id = @intCast(client.id),
            .session_id = .{0} ** 32,
            .has_session_id = 0,
            .name_len = 0,
            .pane_count = @intCast(client.pane_uuids.items.len),
            .session_state_len = 0,
        };

        if (client.session_id) |sid| {
            const hex_id: [32]u8 = std.fmt.bytesToHex(sid, .lower);
            sc.session_id = hex_id;
            sc.has_session_id = 1;
        }

        const name = client.session_name orelse "";
        sc.name_len = @intCast(name.len);
        const session_json = if (full_mode and client.session_snapshot != null)
            client.session_snapshot.?.toJson(alloc) catch |err| {
                core.logging.logError("ses", "failed to serialize attached session status snapshot", err);
                posix.close(fd);
                return;
            }
        else
            null;
        defer if (session_json) |json| alloc.free(json);
        if (session_json) |json| sc.session_state_len = @intCast(json.len);

        if (!self.appendStatusBytesOrClose(fd, &buf, std.mem.asBytes(&sc), "status client entry")) return;
        if (name.len > 0 and !self.appendStatusBytesOrClose(fd, &buf, name, "status client name")) return;
        if (session_json) |json| {
            if (!self.appendStatusBytesOrClose(fd, &buf, json, "status attached session json")) return;
        }

        // Pane entries for this client
        for (client.pane_uuids.items) |uuid| {
            var pe: wire.StatusPaneEntry = .{
                .uuid = uuid,
                .pid = 0,
                .name_len = 0,
                .sticky_pwd_len = 0,
            };
            var pname: []const u8 = "";
            var spwd: []const u8 = "";
            if (self.ses_state.store.panes.get(uuid)) |pane| {
                pe.pid = pane.child_pid;
                if (pane.name) |n| {
                    pname = n;
                    pe.name_len = @intCast(n.len);
                }
                if (pane.sticky_pwd) |pwd| {
                    spwd = pwd;
                    pe.sticky_pwd_len = @intCast(pwd.len);
                }
            }
            if (!self.appendStatusBytesOrClose(fd, &buf, std.mem.asBytes(&pe), "status client pane entry")) return;
            if (pname.len > 0 and !self.appendStatusBytesOrClose(fd, &buf, pname, "status client pane name")) return;
            if (spwd.len > 0 and !self.appendStatusBytesOrClose(fd, &buf, spwd, "status client pane sticky pwd")) return;
        }
    }

    // Detached sessions
    var sess_iter = self.ses_state.store.detached_sessions.iterator();
    while (sess_iter.next()) |entry| {
        const detached = entry.value_ptr;
        const hex_id: [32]u8 = std.fmt.bytesToHex(detached.session_id, .lower);
        var de: wire.DetachedSessionEntry = .{
            .session_id = hex_id,
            .name_len = @intCast(detached.session_snapshot.session_name.len),
            .pane_count = @intCast(detached.pane_uuids.len),
            .session_state_len = 0,
        };
        const session_json = if (full_mode)
            detached.session_snapshot.toJson(alloc) catch |err| {
                core.logging.logError("ses", "failed to serialize detached session status snapshot", err);
                posix.close(fd);
                return;
            }
        else
            null;
        defer if (session_json) |json| alloc.free(json);
        if (session_json) |json| de.session_state_len = @intCast(json.len);
        if (!self.appendStatusBytesOrClose(fd, &buf, std.mem.asBytes(&de), "status detached session entry")) return;
        if (!self.appendStatusBytesOrClose(fd, &buf, detached.session_snapshot.session_name, "status detached session name")) return;
        if (session_json) |json| {
            if (!self.appendStatusBytesOrClose(fd, &buf, json, "status detached session json")) return;
        }
    }

    // Orphaned panes
    pane_iter = self.ses_state.store.panes.iterator();
    while (pane_iter.next()) |entry| {
        const pane = entry.value_ptr;
        if (pane.state != .orphaned) continue;
        var pe: wire.StatusPaneEntry = .{
            .uuid = entry.key_ptr.*,
            .pid = pane.child_pid,
            .name_len = 0,
            .sticky_pwd_len = 0,
        };
        if (pane.name) |n| pe.name_len = @intCast(n.len);
        if (!self.appendStatusBytesOrClose(fd, &buf, std.mem.asBytes(&pe), "status orphan pane entry")) return;
        if (pane.name) |n| {
            if (!self.appendStatusBytesOrClose(fd, &buf, n, "status orphan pane name")) return;
        }
    }

    // Sticky panes
    pane_iter = self.ses_state.store.panes.iterator();
    while (pane_iter.next()) |entry| {
        const pane = entry.value_ptr;
        if (pane.state != .sticky) continue;
        var se: wire.StickyPaneEntry = .{
            .uuid = entry.key_ptr.*,
            .pid = pane.child_pid,
            .key = pane.sticky_key orelse 0,
            .name_len = 0,
            .pwd_len = 0,
        };
        if (pane.name) |n| se.name_len = @intCast(n.len);
        if (pane.sticky_pwd) |pwd| se.pwd_len = @intCast(pwd.len);
        if (!self.appendStatusBytesOrClose(fd, &buf, std.mem.asBytes(&se), "status sticky pane entry")) return;
        if (pane.name) |n| {
            if (!self.appendStatusBytesOrClose(fd, &buf, n, "status sticky pane name")) return;
        }
        if (pane.sticky_pwd) |pwd| {
            if (!self.appendStatusBytesOrClose(fd, &buf, pwd, "status sticky pane pwd")) return;
        }
    }

    // Send all at once. Single owner: replyOrClose queues the fd on write
    // failure, so the success path must close via the queue too.
    self.replyOrClose(fd, .status, buf.items);
    self.queueCtlClose(fd, null);
}
