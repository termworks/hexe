//! Listing + misc CTL handlers (list_orphaned, list_sessions, pop_response,
//! exited), extracted from server.zig (PLAN.md 2.3 god-object split). Pure
//! move: Server methods taking `*Server`, dispatched by name.
const std = @import("std");
const posix = std.posix;
const core = @import("core");
const wire = core.wire;
const server = @import("server.zig");
const Server = server.Server;

pub fn handleBinaryListOrphaned(self: *Server, fd: posix.fd_t, buf: []u8) void {
    _ = buf;
    const orphaned = self.ses_state.getOrphanedPanes(self.allocator) catch |err| {
        core.logging.logError("ses", "failed to collect orphaned panes", err);
        self.sendBinaryError(fd, "list_orphaned: collection failed");
        return;
    };
    defer self.allocator.free(orphaned);

    // Build response: OrphanedPanes header + pane_count * OrphanedPaneEntry.
    var resp_hdr = wire.OrphanedPanes{ .pane_count = @intCast(@min(orphaned.len, 32)) };
    const entry_count: usize = resp_hdr.pane_count;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(self.allocator);
    var writer = payload.writer(self.allocator);
    writer.writeAll(std.mem.asBytes(&resp_hdr)) catch |err| {
        core.logging.logError("ses", "failed to build orphaned panes list header", err);
        self.sendBinaryError(fd, "list_orphaned: response alloc failed");
        return;
    };
    for (orphaned[0..entry_count]) |pane| {
        const name = pane.name orelse "";
        var entry = wire.OrphanedPaneEntry{
            .uuid = pane.uuid,
            .pid = pane.child_pid,
            .name_len = @intCast(@min(name.len, 64)),
        };
        writer.writeAll(std.mem.asBytes(&entry)) catch |err| {
            core.logging.logError("ses", "failed to build orphaned panes list entry", err);
            self.sendBinaryError(fd, "list_orphaned: response alloc failed");
            return;
        };
        if (entry.name_len > 0) {
            writer.writeAll(name[0..entry.name_len]) catch |err| {
                core.logging.logError("ses", "failed to build orphaned pane name", err);
                self.sendBinaryError(fd, "list_orphaned: response alloc failed");
                return;
            };
        }
    }
    self.replyOrClose(fd, .orphaned_panes, payload.items);
}

pub fn handleBinaryListSessions(self: *Server, fd: posix.fd_t, buf: []u8) void {
    _ = buf;
    const sessions = self.ses_state.listDetachedSessions(self.allocator) catch |err| {
        core.logging.logError("ses", "failed to collect detached sessions", err);
        self.sendBinaryError(fd, "list_sessions: collection failed");
        return;
    };
    defer self.allocator.free(sessions);

    const entry_count = @min(sessions.len, std.math.maxInt(u16));
    var resp_hdr = wire.SessionsList{ .session_count = @intCast(entry_count) };
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(self.allocator);
    var writer = payload.writer(self.allocator);
    writer.writeAll(std.mem.asBytes(&resp_hdr)) catch |err| {
        core.logging.logError("ses", "failed to build detached sessions list header", err);
        self.sendBinaryError(fd, "list_sessions: response alloc failed");
        return;
    };

    for (sessions[0..entry_count]) |s| {
        if (s.session_name.len > std.math.maxInt(u16)) {
            self.sendBinaryError(fd, "list_sessions: session name too long");
            return;
        }
        if (s.base_root.len > std.math.maxInt(u16)) {
            self.sendBinaryError(fd, "list_sessions: base root too long");
            return;
        }
        const hex_id: [32]u8 = std.fmt.bytesToHex(&s.session_id, .lower);
        var entry = wire.SessionEntry{
            .session_id = hex_id,
            .pane_count = @intCast(@min(s.pane_count, std.math.maxInt(u16))),
            .name_len = @intCast(s.session_name.len),
            .base_root_len = @intCast(s.base_root.len),
        };
        writer.writeAll(std.mem.asBytes(&entry)) catch |err| {
            core.logging.logError("ses", "failed to build detached sessions list entry", err);
            self.sendBinaryError(fd, "list_sessions: response alloc failed");
            return;
        };
        if (s.session_name.len > 0) {
            writer.writeAll(s.session_name) catch |err| {
                core.logging.logError("ses", "failed to build detached sessions list name", err);
                self.sendBinaryError(fd, "list_sessions: response alloc failed");
                return;
            };
        }
        if (s.base_root.len > 0) {
            writer.writeAll(s.base_root) catch |err| {
                core.logging.logError("ses", "failed to build detached sessions list base root", err);
                self.sendBinaryError(fd, "list_sessions: response alloc failed");
                return;
            };
        }
    }
    self.replyOrClose(fd, .sessions_list, payload.items);
}

pub fn handleBinaryPopResponse(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.PopResponse)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "pop_response: payload too small");
        return;
    }
    const pr = wire.readStructTimeout(wire.PopResponse, fd, server.HANDLER_IO_TIMEOUT_MS) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "pop_response request read failed", err);
        self.sendBinaryError(fd, "pop_response: read failed");
        return;
    };

    // Find the CLI fd waiting for this response.
    const cli_fd = self.pending_pop_requests.fetchRemove(fd);
    if (cli_fd) |kv| {
        // Single owner: replyOrClose queues the fd on write failure, so
        // the success path must close via the queue too.
        self.replyOrClose(kv.value, .pop_response, std.mem.asBytes(&pr));
        self.queueCtlClose(kv.value, null);
    } else {
        core.logging.warn("ses", "pop_response arrived without pending CLI fd for mux fd={d}", .{fd});
    }
}

pub fn handleBinaryExited(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.Exited)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        core.logging.warnWithSource("ses", "exited payload too small: fd={d} len={d}", .{ fd, payload_len }, @src());
        return;
    }
    const ex = wire.readStructTimeout(wire.Exited, fd, server.HANDLER_IO_TIMEOUT_MS) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.warnWithSource("ses", "exited read failed: fd={d} err={s}", .{ fd, @errorName(err) }, @src());
        return;
    };

    if (self.ses_state.store.panes.getPtr(ex.uuid)) |pane| {
        pane.last_status = ex.status;
        // Notify owning mux immediately so it can tear down dead pane UI.
        if (pane.attached_to) |client_id| {
            if (self.ses_state.getClient(client_id)) |client| {
                if (client.mux_ctl_fd) |ctl_fd| {
                    var msg = wire.PaneUuid{ .uuid = ex.uuid };
                    self.replyOrClose(ctl_fd, .pane_exited, std.mem.asBytes(&msg));
                }
            }
        }
    }

    // Fully remove dead pane from SES routing/state so sticky/adopt lookup
    // cannot return a process that already exited.
    self.ses_state.killPane(ex.uuid) catch |e| {
        core.logging.logError("ses", "killPane failed after pane exit", e);
    };
    self.ses_state.markDirty();
}
