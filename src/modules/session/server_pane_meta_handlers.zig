//! MUX→SES pane-metadata sync handlers (update_pane_name, update_pane_aux,
//! update_pane_shell), extracted from server.zig (PLAN.md 2.3 god-object
//! split). Pure move: Server methods taking `*Server`, dispatched by name.
const std = @import("std");
const posix = std.posix;
const core = @import("core");
const wire = core.wire;
const server = @import("server.zig");
const Server = server.Server;
const store = @import("store.zig");

/// Take the next `len` bytes of a trail, advancing `offset`. Null when the
/// declared length runs past what was actually read.
fn sliceTrail(buf: []const u8, offset: *usize, trail_len: usize, len: u16) ?[]const u8 {
    if (len == 0) return "";
    if (offset.* + len > trail_len) return null;
    const out = buf[offset.* .. offset.* + len];
    offset.* += len;
    return out;
}

/// Replace an owned optional string on a store pane. An empty value clears it;
/// a failed dupe leaves the previous value in place rather than losing both.
fn replaceOwned(self: *Server, slot: *?[]const u8, value: []const u8, comptime what: []const u8) void {
    if (value.len == 0) return;
    const owned = self.allocator.dupe(u8, value) catch |err| {
        core.logging.logError("ses", "failed to store pane " ++ what, err);
        return;
    };
    if (slot.*) |old| self.allocator.free(old);
    slot.* = owned;
}

pub fn handleBinaryUpdatePaneName(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.UpdatePaneName)) {
        self.skipPayloadRest();
        self.sendBinaryError(fd, "update_pane_name: payload too small");
        return;
    }
    const upn = self.readPayloadStruct(wire.UpdatePaneName) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "update_pane_name request read failed", err);
        self.sendBinaryError(fd, "update_pane_name: read failed");
        return;
    };
    if (upn.name_len > wire.MAX_PAYLOAD_LEN or upn.name_len > buf.len) {
        self.skipPayloadRest();
        self.sendBinaryError(fd, "update_pane_name: name too large");
        return;
    }
    if (upn.name_len > 0) {
        self.readPayloadInto(buf[0..upn.name_len]) catch |err| {
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
        self.skipPayloadRest();
        self.sendBinaryError(fd, "update_pane_aux: payload too small");
        return;
    }
    const upa = self.readPayloadStruct(wire.UpdatePaneAux) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "update_pane_aux request read failed", err);
        self.sendBinaryError(fd, "update_pane_aux: read failed");
        return;
    };

    const trail_len = payload_len - @sizeOf(wire.UpdatePaneAux);
    if (trail_len > wire.MAX_PAYLOAD_LEN or trail_len > buf.len) {
        self.skipPayloadRest();
        self.sendBinaryError(fd, "update_pane_aux: payload too large");
        return;
    }
    if (trail_len > 0) {
        self.readPayloadInto(buf[0..trail_len]) catch |err| {
            self.ctlStreamDesynced(fd, "mid-message read failed");
            core.logging.logError("ses", "update_pane_aux trail read failed", err);
            self.sendBinaryError(fd, "update_pane_aux: trail read failed");
            return;
        };
    }

    var offset: usize = 0;
    const cwd = sliceTrail(buf, &offset, trail_len, upa.cwd_len) orelse {
        self.sendBinaryError(fd, "update_pane_aux: malformed cwd trail");
        return;
    };
    const fg = sliceTrail(buf, &offset, trail_len, upa.fg_len) orelse {
        self.sendBinaryError(fd, "update_pane_aux: malformed fg trail");
        return;
    };
    const layout = sliceTrail(buf, &offset, trail_len, upa.layout_len) orelse {
        self.sendBinaryError(fd, "update_pane_aux: malformed layout trail");
        return;
    };
    if (offset != trail_len) {
        self.sendBinaryError(fd, "update_pane_aux: trailing payload length mismatch");
        return;
    }

    const client_id = self.findClientForCtlFd(fd);

    if (self.ses_state.store.panes.getPtr(upa.uuid)) |pane| {
        if (upa.has_created_from != 0) {
            pane.created_from = upa.created_from;
        }
        if (upa.has_focused_from != 0) {
            pane.focused_from = upa.focused_from;
        }
        pane.is_focused = (upa.is_focused != 0);
        if (upa.has_cursor != 0) {
            pane.cursor_x = upa.cursor_x;
            pane.cursor_y = upa.cursor_y;
        }
        if (upa.has_cursor_style != 0) pane.cursor_style = upa.cursor_style;
        if (upa.has_cursor_visible != 0) pane.cursor_visible = (upa.cursor_visible != 0);
        if (upa.has_alt_screen != 0) pane.alt_screen = (upa.alt_screen != 0);
        if (upa.has_size != 0) {
            pane.cols = upa.cols;
            pane.rows = upa.rows;
        }
        if (upa.has_fg_pid != 0) pane.fg_pid = upa.fg_pid;
        pane.is_float = (upa.is_floating != 0);
        pane.pane_type = std.meta.intToEnum(store.PaneType, upa.pane_type) catch pane.pane_type;

        replaceOwned(self, &pane.cwd, cwd, "cwd");
        replaceOwned(self, &pane.fg_process, fg, "fg_process");
        replaceOwned(self, &pane.layout_path, layout, "layout_path");
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
        self.skipPayloadRest();
        self.sendBinaryError(fd, "update_pane_shell: payload too small");
        return;
    }
    const ups = self.readPayloadStruct(wire.UpdatePaneShell) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "update_pane_shell request read failed", err);
        self.sendBinaryError(fd, "update_pane_shell: read failed");
        return;
    };
    const trail_len = payload_len - @sizeOf(wire.UpdatePaneShell);
    if (trail_len > wire.MAX_PAYLOAD_LEN or trail_len > buf.len) {
        self.skipPayloadRest();
        self.sendBinaryError(fd, "update_pane_shell: payload too large");
        return;
    }
    if (trail_len > 0) {
        self.readPayloadInto(buf[0..trail_len]) catch |err| {
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

/// MUX → SES: park a pane's palette namespaces (PLAN.md M4).
///
/// The blob is opaque. SES stores the bytes and hands them back on request; it
/// never parses one, which is what keeps the daemon out of the business of
/// knowing what VT bytes mean.
pub fn handleBinaryUpdatePanePalette(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.UpdatePanePalette)) {
        self.skipPayloadRest();
        self.sendBinaryError(fd, "update_pane_palette: payload too small");
        return;
    }
    const req = self.readPayloadStruct(wire.UpdatePanePalette) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "update_pane_palette request read failed", err);
        self.sendBinaryError(fd, "update_pane_palette: read failed");
        return;
    };

    const trail_len = payload_len - @sizeOf(wire.UpdatePanePalette);
    // Bounded on the daemon's own terms, not on the sender's word: a pane must
    // not be able to make SES hold an arbitrary buffer.
    if (trail_len > core.palette.MAX_BLOB_LEN or trail_len > buf.len or
        req.blob_len != trail_len)
    {
        self.skipPayloadRest();
        self.sendBinaryError(fd, "update_pane_palette: bad blob length");
        return;
    }
    if (trail_len > 0) {
        self.readPayloadInto(buf[0..trail_len]) catch |err| {
            self.ctlStreamDesynced(fd, "mid-message read failed");
            core.logging.logError("ses", "update_pane_palette trail read failed", err);
            self.sendBinaryError(fd, "update_pane_palette: trail read failed");
            return;
        };
    }

    if (self.ses_state.store.panes.getPtr(req.uuid)) |pane| {
        // Replace rather than accumulate: the frontend always sends the whole
        // palette, so an entry it dropped must not linger here.
        const copy: ?[]u8 = if (trail_len == 0) null else pane.allocator.dupe(u8, buf[0..trail_len]) catch {
            self.sendBinaryError(fd, "update_pane_palette: allocation failed");
            return;
        };
        if (pane.palette_blob) |old| pane.allocator.free(old);
        pane.palette_blob = copy;
        self.ses_state.markDirty();
    }
    self.replyOrClose(fd, .ok, &.{});
}

/// MUX → SES: fetch a pane's parked palette, on attach.
pub fn handleBinaryGetPanePalette(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    _ = buf;
    if (payload_len < @sizeOf(wire.GetPanePalette)) {
        self.skipPayloadRest();
        self.sendBinaryError(fd, "get_pane_palette: payload too small");
        return;
    }
    const req = self.readPayloadStruct(wire.GetPanePalette) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "get_pane_palette request read failed", err);
        self.sendBinaryError(fd, "get_pane_palette: read failed");
        return;
    };

    // Sent UNSTAMPED, as a push rather than a reply. The requester is
    // fire-and-forget, so nothing is waiting on this id; a stamped frame that
    // matches no in-flight request gets parked in the by-request-id queue by
    // whichever synchronous reader happens to see it first, and is never
    // claimed. Same lesson as `notifyOrClose`'s comment.
    if (self.ses_state.store.panes.getPtr(req.uuid)) |pane| {
        if (pane.palette_blob) |blob| {
            var resp = wire.PanePalette{ .uuid = req.uuid, .blob_len = @intCast(blob.len) };
            self.notifyOrCloseWithTrail(fd, .get_pane_palette, std.mem.asBytes(&resp), blob);
            return;
        }
    }
    var resp = wire.PanePalette{ .uuid = req.uuid, .blob_len = 0 };
    self.notifyOrClose(fd, .get_pane_palette, std.mem.asBytes(&resp));
}
