//! POD→SES channel-④ event handlers (cwd_changed, fg_changed, shell_event),
//! extracted from server.zig (PLAN.md 2.3 god-object split). Pure move: these
//! are Server methods relocated to a sibling file; they take `*Server` and call
//! back into its (pub) helpers. server.zig dispatches to them by name.
const std = @import("std");
const posix = std.posix;
const core = @import("core");
const wire = core.wire;
const ses = @import("main.zig");
const server = @import("server.zig");
const Server = server.Server;

pub fn handleBinaryCwdChanged(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.CwdChanged)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        core.logging.warnWithSource("ses", "cwd_changed payload too small: fd={d} len={d}", .{ fd, payload_len }, @src());
        return;
    }
    const cc = wire.readStructTimeout(wire.CwdChanged, fd, server.HANDLER_IO_TIMEOUT_MS) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.warnWithSource("ses", "cwd_changed read failed: fd={d} err={s}", .{ fd, @errorName(err) }, @src());
        return;
    };
    if (cc.cwd_len > wire.MAX_PAYLOAD_LEN or cc.cwd_len > buf.len) {
        self.skipBinaryPayload(fd, cc.cwd_len, buf);
        self.sendBinaryError(fd, "cwd_changed: path too large");
        return;
    }
    if (cc.cwd_len > 0) {
        wire.readExactTimeout(fd, buf[0..cc.cwd_len], server.HANDLER_IO_TIMEOUT_MS) catch |err| {
            self.ctlStreamDesynced(fd, "mid-message read failed");
            core.logging.warnWithSource("ses", "cwd_changed path read failed: fd={d} err={s}", .{ fd, @errorName(err) }, @src());
            return;
        };
    }

    if (self.ses_state.store.panes.getPtr(cc.uuid)) |pane| {
        ses.debugLog("cwd_changed: uuid={s} cwd={s}", .{ cc.uuid[0..8], if (cc.cwd_len > 0) buf[0..cc.cwd_len] else "(empty)" });
        const new_cwd = if (cc.cwd_len > 0)
            self.allocator.dupe(u8, buf[0..cc.cwd_len]) catch |err| {
                core.logging.logError("ses", "failed to store cwd_changed path", err);
                return;
            }
        else
            null;
        if (pane.cwd) |old| self.allocator.free(old);
        pane.cwd = new_cwd;
        self.ses_state.markDirty();
    }
}

pub fn handleBinaryFgChanged(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.FgChanged)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        core.logging.warnWithSource("ses", "fg_changed payload too small: fd={d} len={d}", .{ fd, payload_len }, @src());
        return;
    }
    const fc = wire.readStructTimeout(wire.FgChanged, fd, server.HANDLER_IO_TIMEOUT_MS) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.warnWithSource("ses", "fg_changed read failed: fd={d} err={s}", .{ fd, @errorName(err) }, @src());
        return;
    };
    if (fc.name_len > wire.MAX_PAYLOAD_LEN or fc.name_len > buf.len) {
        self.skipBinaryPayload(fd, fc.name_len, buf);
        self.sendBinaryError(fd, "fg_changed: name too large");
        return;
    }
    if (fc.name_len > 0) {
        wire.readExactTimeout(fd, buf[0..fc.name_len], server.HANDLER_IO_TIMEOUT_MS) catch |err| {
            self.ctlStreamDesynced(fd, "mid-message read failed");
            core.logging.warnWithSource("ses", "fg_changed name read failed: fd={d} err={s}", .{ fd, @errorName(err) }, @src());
            return;
        };
    }

    if (self.ses_state.store.panes.getPtr(fc.uuid)) |pane| {
        ses.debugLog("fg_changed: uuid={s} pid={d} name={s}", .{ fc.uuid[0..8], fc.pid, if (fc.name_len > 0) buf[0..fc.name_len] else "(empty)" });
        const new_fg_process = if (fc.name_len > 0)
            self.allocator.dupe(u8, buf[0..fc.name_len]) catch |err| {
                core.logging.logError("ses", "failed to store foreground process name", err);
                return;
            }
        else
            null;
        pane.fg_pid = fc.pid;
        if (pane.fg_process) |old| self.allocator.free(old);
        pane.fg_process = new_fg_process;
        self.ses_state.markDirty();
    }
}

pub fn handleBinaryShellEvent(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.ShpShellEvent)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        core.logging.warnWithSource("ses", "shell_event payload too small: fd={d} len={d}", .{ fd, payload_len }, @src());
        return;
    }
    const ev = wire.readStructTimeout(wire.ShpShellEvent, fd, server.HANDLER_IO_TIMEOUT_MS) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.warnWithSource("ses", "shell_event read failed: fd={d} err={s}", .{ fd, @errorName(err) }, @src());
        return;
    };
    const trail_len = payload_len - @sizeOf(wire.ShpShellEvent);
    if (trail_len > wire.MAX_PAYLOAD_LEN or trail_len > buf.len) {
        self.skipBinaryPayload(fd, trail_len, buf);
        return;
    }
    if (trail_len > 0) {
        wire.readExactTimeout(fd, buf[0..trail_len], server.HANDLER_IO_TIMEOUT_MS) catch |err| {
            self.ctlStreamDesynced(fd, "mid-message read failed");
            core.logging.warnWithSource("ses", "shell_event trail read failed: fd={d} err={s}", .{ fd, @errorName(err) }, @src());
            return;
        };
    }

    // Identify pane by pod_ctl_fd.
    var pane_uuid: ?[32]u8 = null;
    var pane_iter = self.ses_state.store.panes.iterator();
    while (pane_iter.next()) |entry| {
        if (entry.value_ptr.pod_ctl_fd) |ctl_fd| {
            if (ctl_fd == fd) {
                pane_uuid = entry.key_ptr.*;
                break;
            }
        }
    }
    const uuid = pane_uuid orelse {
        core.logging.warn("ses", "shell_event skipped: no pane registered for POD control fd {d}", .{fd});
        return;
    };
    ses.debugLog("shell_event: uuid={s} phase={d} status={d}", .{ uuid[0..8], ev.phase, ev.status });

    // Forward to MUX as ForwardedShellEvent.
    var fwd = wire.ForwardedShellEvent{
        .uuid = uuid,
        .phase = ev.phase,
        .status = ev.status,
        .duration_ms = ev.duration_ms,
        .started_at = ev.started_at,
        .jobs = ev.jobs,
        .running = ev.running,
        .cmd_len = ev.cmd_len,
        .cwd_len = ev.cwd_len,
    };

    // Find the MUX CTL fd for this pane's owning client.
    if (self.ses_state.store.panes.get(uuid)) |pane| {
        if (pane.attached_to) |client_id| {
            if (self.ses_state.getClient(client_id)) |client| {
                if (client.mux_ctl_fd) |mux_fd| {
                    const trails: []const []const u8 = &.{buf[0..trail_len]};
                    wire.writeControlMsgTimeout(mux_fd, .shell_event, std.mem.asBytes(&fwd), trails, server.HANDLER_IO_TIMEOUT_MS) catch |err| {
                        core.logging.warnWithSource("ses", "shell_event forward failed: fd={d} err={s}", .{ mux_fd, @errorName(err) }, @src());
                        self.queueCtlClose(mux_fd, null);
                    };
                }
            }
        }
    }
}
