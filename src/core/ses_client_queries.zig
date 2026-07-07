//! SesClient pane read-queries: synchronous `pane_info` lookups (aux info, name,
//! existence probe, full snapshot) and the fire-and-forget process request.
//! Each writes a `pane_info` request and reads the correlated reply through the
//! interleaved-push-tolerant readers in `ses_client_reads`.
//!
//! Extracted from `frontend_client.zig` as free functions taking `*SesClient`
//! and re-exported there via `pub const` aliases, so call sites are unchanged
//! (PLAN.md 2.3).

const std = @import("std");
const posix = std.posix;
const logging = @import("logging.zig");
const wire = @import("wire.zig");
const frontend_client = @import("frontend_client.zig");

const SesClient = frontend_client.SesClient;
const PaneAuxInfo = SesClient.PaneAuxInfo;
const PaneInfoSnapshot = SesClient.PaneInfoSnapshot;
const PaneExistence = SesClient.PaneExistence;
const PaneExistenceProbe = SesClient.PaneExistenceProbe;

/// Get auxiliary pane info — queries SES for created_from/focused_from.
pub fn getPaneAux(self: *SesClient, uuid: [32]u8) !PaneAuxInfo {
    const fd = self.ctl_fd orelse return error.NotConnected;
    var msg: wire.PaneUuid = .{ .uuid = uuid };
    const request_id = self.writeControlRequest(fd, .pane_info, std.mem.asBytes(&msg)) catch |err| {
        logging.logError("frontend-client", "failed to request pane aux", err);
        if (self.ctl_fd == fd) self.ctl_fd = null;
        return error.WriteFailed;
    };

    var read = self.readExpectedPaneInfoResponse(fd, uuid, request_id) catch |err| {
        logging.logError("frontend-client", "failed to read pane aux response", err);
        return err;
    };
    defer read.deinit(self.allocator);
    const hdr = read.hdr;
    const resp = read.resp;
    // Skip trailing data.
    const trail_len = hdr.payload_len - @sizeOf(wire.PaneInfoResp);
    if (trail_len > 0) read.skip(self, fd, trail_len);

    return .{
        .created_from = if (resp.has_created_from != 0) resp.created_from else null,
        .focused_from = if (resp.has_focused_from != 0) resp.focused_from else null,
    };
}

/// Request foreground process info for a pane (fire-and-forget; response handled in handleSesMessage).
pub fn requestPaneProcess(self: *SesClient, uuid: [32]u8) void {
    const fd = self.ctl_fd orelse return;
    var msg: wire.PaneUuid = .{ .uuid = uuid };
    _ = self.writeControlRequest(fd, .pane_info, std.mem.asBytes(&msg)) catch |err| {
        logging.logError("frontend-client", "failed to request pane process info", err);
        if (self.ctl_fd == fd) self.ctl_fd = null;
    };
}

/// Best-effort pane name (sync call, queues unrelated async responses).
pub fn getPaneName(self: *SesClient, uuid: [32]u8) ?[]u8 {
    const fd = self.ctl_fd orelse return null;
    var msg: wire.PaneUuid = .{ .uuid = uuid };
    const request_id = self.writeControlRequest(fd, .pane_info, std.mem.asBytes(&msg)) catch |err| {
        logging.logError("frontend-client", "failed to request pane name", err);
        if (self.ctl_fd == fd) self.ctl_fd = null;
        return null;
    };

    var read = self.readExpectedPaneInfoResponse(fd, uuid, request_id) catch |err| {
        logging.logError("frontend-client", "failed to read pane name response", err);
        return null;
    };
    defer read.deinit(self.allocator);
    const resp = read.resp;
    var result: ?[]u8 = null;

    // Calculate total trailing bytes.
    const trail_total: usize = @as(usize, resp.name_len) + @as(usize, resp.fg_len) +
        @as(usize, resp.cwd_len) + @as(usize, resp.tty_len) +
        @as(usize, resp.socket_path_len) + @as(usize, resp.session_name_len) +
        @as(usize, resp.layout_path_len) + @as(usize, resp.last_cmd_len) +
        @as(usize, resp.base_process_len) + @as(usize, resp.sticky_pwd_len);

    if (resp.name_len > 0) {
        const buf = self.allocator.alloc(u8, resp.name_len) catch {
            self.skipPayload(fd, @intCast(trail_total));
            return null;
        };
        read.readExact(self, fd, buf) catch |err| {
            logging.logError("frontend-client", "failed to read pane name payload", err);
            if (self.ctl_fd == fd) self.ctl_fd = null;
            self.allocator.free(buf);
            return null;
        };
        result = buf;
    }
    // Skip all remaining trailing bytes.
    const remaining = trail_total - @as(usize, resp.name_len);
    if (remaining > 0) {
        read.skip(self, fd, remaining);
    }
    return result;
}

/// Tri-state existence probe. `missing` is returned only when SES
/// definitively replied pane_not_found; every transport/protocol failure
/// is `unknown`, so callers can avoid destroying local state on a
/// transient hiccup.
pub fn probePaneExistence(self: *SesClient, uuid: [32]u8) PaneExistenceProbe {
    const fd = self.ctl_fd orelse return .{ .outcome = .unknown };
    var msg: wire.PaneUuid = .{ .uuid = uuid };
    const request_id = self.writeControlRequest(fd, .pane_info, std.mem.asBytes(&msg)) catch |err| {
        logging.logError("frontend-client", "failed to send pane existence probe", err);
        if (self.ctl_fd == fd) self.ctl_fd = null;
        return .{ .outcome = .unknown };
    };

    var read = self.readExpectedPaneInfoResponse(fd, uuid, request_id) catch |err| {
        if (err == error.PaneMissing) return .{ .outcome = .missing };
        logging.logError("frontend-client", "pane existence probe failed", err);
        return .{ .outcome = .unknown };
    };
    const resp = read.resp;
    const trail_total: usize = @as(usize, resp.name_len) + @as(usize, resp.fg_len) +
        @as(usize, resp.cwd_len) + @as(usize, resp.tty_len) +
        @as(usize, resp.socket_path_len) + @as(usize, resp.session_name_len) +
        @as(usize, resp.layout_path_len) + @as(usize, resp.last_cmd_len) +
        @as(usize, resp.base_process_len) + @as(usize, resp.sticky_pwd_len);
    read.skip(self, fd, trail_total);
    read.deinit(self.allocator);
    return .{ .outcome = .exists, .pid = resp.pid };
}

pub fn getPaneInfoSnapshot(self: *SesClient, uuid: [32]u8) ?PaneInfoSnapshot {
    const fd = self.ctl_fd orelse return null;
    var msg: wire.PaneUuid = .{ .uuid = uuid };
    const request_id = self.writeControlRequest(fd, .pane_info, std.mem.asBytes(&msg)) catch |err| {
        logging.logError("frontend-client", "failed to request pane info snapshot", err);
        if (self.ctl_fd == fd) self.ctl_fd = null;
        return null;
    };

    // Read response directly — do NOT use readSyncResponse which skips
    // large pane_info responses (treating them as async noise).
    var read = self.readExpectedPaneInfoResponse(fd, uuid, request_id) catch |err| {
        logging.logError("frontend-client", "failed to read pane info snapshot response", err);
        return null;
    };
    defer read.deinit(self.allocator);
    const resp = read.resp;
    const trail_total: usize = @as(usize, resp.name_len) + @as(usize, resp.fg_len) +
        @as(usize, resp.cwd_len) + @as(usize, resp.tty_len) +
        @as(usize, resp.socket_path_len) + @as(usize, resp.session_name_len) +
        @as(usize, resp.layout_path_len) + @as(usize, resp.last_cmd_len) +
        @as(usize, resp.base_process_len) + @as(usize, resp.sticky_pwd_len);

    var consumed: usize = 0;
    var name: ?[]u8 = null;
    var fg_name: ?[]u8 = null;
    var cwd: ?[]u8 = null;
    var sticky_pwd: ?[]u8 = null;

    if (resp.name_len > 0) {
        const n = @as(usize, resp.name_len);
        if (n <= 16 * 1024) {
            const buf = self.allocator.alloc(u8, n) catch |err| {
                logging.logError("frontend-client", "failed to allocate pane info name", err);
                read.skip(self, fd, trail_total - consumed);
                return null;
            };
            read.readExact(self, fd, buf) catch |err| {
                logging.logError("frontend-client", "failed to read pane info name payload", err);
                if (self.ctl_fd == fd) self.ctl_fd = null;
                self.allocator.free(buf);
                return null;
            };
            name = buf;
        } else {
            read.skip(self, fd, n);
        }
        consumed += n;
    }

    if (resp.fg_len > 0) {
        const n = @as(usize, resp.fg_len);
        if (n <= 16 * 1024) {
            const buf = self.allocator.alloc(u8, n) catch |err| {
                logging.logError("frontend-client", "failed to allocate pane info foreground", err);
                read.skip(self, fd, trail_total - consumed);
                if (name) |s| self.allocator.free(s);
                return null;
            };
            read.readExact(self, fd, buf) catch |err| {
                logging.logError("frontend-client", "failed to read pane info foreground payload", err);
                if (self.ctl_fd == fd) self.ctl_fd = null;
                self.allocator.free(buf);
                if (name) |s| self.allocator.free(s);
                return null;
            };
            fg_name = buf;
        } else {
            read.skip(self, fd, n);
        }
        consumed += n;
    }

    if (resp.cwd_len > 0) {
        const n = @as(usize, resp.cwd_len);
        if (n <= 64 * 1024) {
            const buf = self.allocator.alloc(u8, n) catch |err| {
                logging.logError("frontend-client", "failed to allocate pane info cwd", err);
                read.skip(self, fd, trail_total - consumed);
                if (name) |s| self.allocator.free(s);
                if (fg_name) |s| self.allocator.free(s);
                return null;
            };
            read.readExact(self, fd, buf) catch |err| {
                logging.logError("frontend-client", "failed to read pane info cwd payload", err);
                if (self.ctl_fd == fd) self.ctl_fd = null;
                self.allocator.free(buf);
                if (name) |s| self.allocator.free(s);
                if (fg_name) |s| self.allocator.free(s);
                return null;
            };
            cwd = buf;
        } else {
            read.skip(self, fd, n);
        }
        consumed += n;
    }

    const before_sticky_len: usize = @as(usize, resp.tty_len) + @as(usize, resp.socket_path_len) +
        @as(usize, resp.session_name_len) + @as(usize, resp.layout_path_len) +
        @as(usize, resp.last_cmd_len) + @as(usize, resp.base_process_len);
    if (before_sticky_len > 0) {
        read.skip(self, fd, before_sticky_len);
        consumed += before_sticky_len;
    }

    if (resp.sticky_pwd_len > 0) {
        const n = @as(usize, resp.sticky_pwd_len);
        if (n <= 64 * 1024) {
            const buf = self.allocator.alloc(u8, n) catch |err| {
                logging.logError("frontend-client", "failed to allocate pane info sticky pwd", err);
                read.skip(self, fd, trail_total - consumed);
                if (name) |s| self.allocator.free(s);
                if (fg_name) |s| self.allocator.free(s);
                if (cwd) |s| self.allocator.free(s);
                return null;
            };
            read.readExact(self, fd, buf) catch |err| {
                logging.logError("frontend-client", "failed to read pane info sticky pwd payload", err);
                if (self.ctl_fd == fd) self.ctl_fd = null;
                self.allocator.free(buf);
                if (name) |s| self.allocator.free(s);
                if (fg_name) |s| self.allocator.free(s);
                if (cwd) |s| self.allocator.free(s);
                return null;
            };
            sticky_pwd = buf;
        } else {
            read.skip(self, fd, n);
        }
        consumed += n;
    }

    const remaining = trail_total -| consumed;
    if (remaining > 0) read.skip(self, fd, remaining);

    return .{
        .pane_id = resp.pane_id,
        .pid = if (resp.pid != 0) resp.pid else null,
        .name = name,
        .cwd = cwd,
        .sticky_pwd = sticky_pwd,
        .fg_name = fg_name,
        .fg_pid = if (resp.fg_pid != 0) resp.fg_pid else null,
    };
}
