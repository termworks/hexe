//! MUX→SES pane-metadata sync handlers (update_pane_name, update_pane_aux,
//! update_pane_shell), extracted from server.zig (PLAN.md 2.3 god-object
//! split). Pure move: Server methods taking `*Server`, dispatched by name.
const std = @import("std");
const posix = std.posix;
const core = @import("core");
const wire = core.wire;
const server = @import("server.zig");
const Server = server.Server;

pub fn handleBinaryUpdatePaneName(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.UpdatePaneName)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "update_pane_name: payload too small");
        return;
    }
    const upn = wire.readStruct(wire.UpdatePaneName, fd) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "update_pane_name request read failed", err);
        self.sendBinaryError(fd, "update_pane_name: read failed");
        return;
    };
    if (upn.name_len > wire.MAX_PAYLOAD_LEN or upn.name_len > buf.len) {
        self.skipBinaryPayload(fd, upn.name_len, buf);
        self.sendBinaryError(fd, "update_pane_name: name too large");
        return;
    }
    if (upn.name_len > 0) {
        wire.readExact(fd, buf[0..upn.name_len]) catch |err| {
            self.ctlStreamDesynced(fd, "mid-message read failed");
            core.logging.logError("ses", "update_pane_name name read failed", err);
            self.sendBinaryError(fd, "update_pane_name: name read failed");
            return;
        };
    }

    if (self.ses_state.store.panes.getPtr(upn.uuid)) |pane| {
        const new_name = if (upn.name_len > 0)
            self.allocator.dupe(u8, buf[0..upn.name_len]) catch |err| {
                core.logging.logError("ses", "failed to store pane name", err);
                self.sendBinaryError(fd, "update_pane_name: name allocation failed");
                return;
            }
        else
            null;
        if (pane.name) |old| self.allocator.free(old);
        pane.name = new_name;
        self.ses_state.markDirty();
    }
    self.replyOrClose(fd, .ok, &.{});
}

pub fn handleBinaryUpdatePaneAux(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.UpdatePaneAux)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "update_pane_aux: payload too small");
        return;
    }
    const upa = wire.readStruct(wire.UpdatePaneAux, fd) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "update_pane_aux request read failed", err);
        self.sendBinaryError(fd, "update_pane_aux: read failed");
        return;
    };
    const client_id = self.findClientForCtlFd(fd);

    if (self.ses_state.store.panes.getPtr(upa.uuid)) |pane| {
        if (upa.has_created_from != 0) {
            pane.created_from = upa.created_from;
        }
        if (upa.has_focused_from != 0) {
            pane.focused_from = upa.focused_from;
        }
        pane.is_focused = (upa.is_focused != 0);
        if (client_id) |cid| {
            self.ses_state.updateClientSessionFocus(
                cid,
                upa.uuid,
                if (upa.has_active_tab != 0) upa.active_tab else null,
                upa.is_focused != 0,
            );
        }
        self.ses_state.markDirty();
    }
    self.replyOrClose(fd, .ok, &.{});
}

pub fn handleBinaryUpdatePaneShell(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.UpdatePaneShell)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "update_pane_shell: payload too small");
        return;
    }
    const ups = wire.readStruct(wire.UpdatePaneShell, fd) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "update_pane_shell request read failed", err);
        self.sendBinaryError(fd, "update_pane_shell: read failed");
        return;
    };
    const trail_len = payload_len - @sizeOf(wire.UpdatePaneShell);
    if (trail_len > wire.MAX_PAYLOAD_LEN or trail_len > buf.len) {
        self.skipBinaryPayload(fd, trail_len, buf);
        self.sendBinaryError(fd, "update_pane_shell: payload too large");
        return;
    }
    if (trail_len > 0) {
        wire.readExact(fd, buf[0..trail_len]) catch |err| {
            self.ctlStreamDesynced(fd, "mid-message read failed");
            core.logging.logError("ses", "update_pane_shell trail read failed", err);
            self.sendBinaryError(fd, "update_pane_shell: trail read failed");
            return;
        };
    }

    var offset: usize = 0;
    const cmd: ?[]const u8 = if (ups.cmd_len > 0) blk: {
        if (offset + ups.cmd_len > trail_len) {
            self.sendBinaryError(fd, "update_pane_shell: malformed cmd trail");
            return;
        }
        const c = buf[offset .. offset + ups.cmd_len];
        offset += ups.cmd_len;
        break :blk c;
    } else null;
    const cwd: ?[]const u8 = if (ups.cwd_len > 0) blk: {
        if (offset + ups.cwd_len > trail_len) {
            self.sendBinaryError(fd, "update_pane_shell: malformed cwd trail");
            return;
        }
        const c = buf[offset .. offset + ups.cwd_len];
        offset += ups.cwd_len;
        break :blk c;
    } else null;
    if (offset != trail_len) {
        self.sendBinaryError(fd, "update_pane_shell: trailing payload length mismatch");
        return;
    }

    if (self.ses_state.store.panes.getPtr(ups.uuid)) |pane| {
        if (ups.has_status != 0) pane.last_status = ups.status;
        const new_cmd = if (cmd) |c|
            self.allocator.dupe(u8, c) catch |err| {
                core.logging.logError("ses", "failed to store pane command", err);
                self.sendBinaryError(fd, "update_pane_shell: command allocation failed");
                return;
            }
        else
            null;
        const new_cwd = if (cwd) |c|
            self.allocator.dupe(u8, c) catch |err| {
                core.logging.logError("ses", "failed to store pane cwd", err);
                if (new_cmd) |owned| self.allocator.free(owned);
                self.sendBinaryError(fd, "update_pane_shell: cwd allocation failed");
                return;
            }
        else
            null;
        if (cmd) |c| {
            if (pane.last_cmd) |old| self.allocator.free(old);
            _ = c;
            pane.last_cmd = new_cmd;
        }
        if (cwd) |c| {
            if (pane.cwd) |old| self.allocator.free(old);
            _ = c;
            pane.cwd = new_cwd;
        }
        self.ses_state.markDirty();
    }
    self.replyOrClose(fd, .ok, &.{});
}
