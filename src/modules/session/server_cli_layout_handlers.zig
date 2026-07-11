//! CLI-facing session/layout CTL handlers (kill/clear sessions, clear orphaned
//! panes, get/apply layout, get session state) + the layout-export helper,
//! extracted from server.zig (PLAN.md 2.3 god-object split). Pure move.
const std = @import("std");
const posix = std.posix;
const core = @import("core");
const wire = core.wire;
const ses = @import("main.zig");
const state = @import("state.zig");
const server = @import("server.zig");
const Server = server.Server;

/// Handle kill_session CLI request.
pub fn handleKillSession(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    // Note-then-close: a failed reply also queues this fd for close, and the
    // pending-close processor only skips NOTED fds. An unnoted direct close
    // here lets the queued entry fire later against whatever new connection
    // reused the fd number (the double-close family).
    defer {
        self.ses_state.store.noteClosedFd(fd);
        posix.close(fd);
    }

    if (payload_len < @sizeOf(wire.KillSession)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        const result = wire.KillSessionResult{ .success = 0, .killed_panes = 0, .error_len = 15 };
        self.replyOrCloseWithTrail(fd, .kill_session, std.mem.asBytes(&result), "invalid payload");
        return;
    }

    const ks = wire.readStructTimeout(wire.KillSession, fd, server.HANDLER_IO_TIMEOUT_MS) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "kill_session request read failed", err);
        const result = wire.KillSessionResult{ .success = 0, .killed_panes = 0, .error_len = 11 };
        self.replyOrCloseWithTrail(fd, .kill_session, std.mem.asBytes(&result), "read failed");
        return;
    };

    if (ks.id_len == 0 or ks.id_len > buf.len) {
        const result = wire.KillSessionResult{ .success = 0, .killed_panes = 0, .error_len = 10 };
        self.replyOrCloseWithTrail(fd, .kill_session, std.mem.asBytes(&result), "invalid id");
        return;
    }

    wire.readExactTimeout(fd, buf[0..ks.id_len], server.HANDLER_IO_TIMEOUT_MS) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "kill_session id read failed", err);
        const result = wire.KillSessionResult{ .success = 0, .killed_panes = 0, .error_len = 11 };
        self.replyOrCloseWithTrail(fd, .kill_session, std.mem.asBytes(&result), "read failed");
        return;
    };
    const session_id_str = buf[0..ks.id_len];

    ses.debugLog("kill_session: id={s}", .{session_id_str});

    // Find session by name or UUID prefix.
    const session_id = self.ses_state.findDetachedSessionByNameOrPrefix(session_id_str) orelse {
        const result = wire.KillSessionResult{ .success = 0, .killed_panes = 0, .error_len = 17 };
        self.replyOrCloseWithTrail(fd, .kill_session, std.mem.asBytes(&result), "session not found");
        return;
    };

    // Kill the session.
    const killed_panes = self.ses_state.killDetachedSession(session_id) orelse {
        const result = wire.KillSessionResult{ .success = 0, .killed_panes = 0, .error_len = 11 };
        self.replyOrCloseWithTrail(fd, .kill_session, std.mem.asBytes(&result), "kill failed");
        return;
    };

    ses.debugLog("kill_session: killed {d} panes", .{killed_panes});
    const result = wire.KillSessionResult{ .success = 1, .killed_panes = @intCast(killed_panes), .error_len = 0 };
    self.replyOrClose(fd, .kill_session, std.mem.asBytes(&result));
}

/// Handle clear_sessions CLI request.
pub fn handleClearSessions(self: *Server, fd: posix.fd_t) void {
    // Note-then-close: a failed reply also queues this fd for close, and the
    // pending-close processor only skips NOTED fds. An unnoted direct close
    // here lets the queued entry fire later against whatever new connection
    // reused the fd number (the double-close family).
    defer {
        self.ses_state.store.noteClosedFd(fd);
        posix.close(fd);
    }

    ses.debugLog("clear_sessions: starting", .{});
    const counts = self.ses_state.killAllDetachedSessions();
    ses.debugLog("clear_sessions: killed {d} sessions, {d} panes", .{ counts.sessions, counts.panes });

    const result = wire.ClearSessionsResult{
        .killed_sessions = @intCast(counts.sessions),
        .killed_panes = @intCast(counts.panes),
    };
    self.replyOrClose(fd, .clear_sessions, std.mem.asBytes(&result));
}

/// Handle clear_orphaned_panes CLI request.
pub fn handleClearOrphanedPanes(self: *Server, fd: posix.fd_t) void {
    // Note-then-close: a failed reply also queues this fd for close, and the
    // pending-close processor only skips NOTED fds. An unnoted direct close
    // here lets the queued entry fire later against whatever new connection
    // reused the fd number (the double-close family).
    defer {
        self.ses_state.store.noteClosedFd(fd);
        posix.close(fd);
    }

    ses.debugLog("clear_orphaned_panes: starting", .{});
    const killed = self.ses_state.killAllOrphanedPanes();
    ses.debugLog("clear_orphaned_panes: killed {d} panes", .{killed});

    const result = wire.ClearOrphanedPanesResult{
        .killed_panes = @intCast(killed),
    };
    self.replyOrClose(fd, .clear_orphaned_panes, std.mem.asBytes(&result));
}

const LayoutExportTabCtx = struct {
    allocator: std.mem.Allocator,
    ids: std.AutoHashMap([32]u8, u16),
    ordered: std.ArrayList([32]u8),
    next_id: u16 = 0,

    fn init(allocator: std.mem.Allocator) LayoutExportTabCtx {
        return .{
            .allocator = allocator,
            .ids = std.AutoHashMap([32]u8, u16).init(allocator),
            .ordered = .empty,
        };
    }

    fn deinit(self: *LayoutExportTabCtx) void {
        self.ids.deinit();
        self.ordered.deinit(self.allocator);
    }

    fn assign(self: *LayoutExportTabCtx, uuid: [32]u8) !void {
        if (self.ids.contains(uuid)) return;
        try self.ids.put(uuid, self.next_id);
        try self.ordered.append(self.allocator, uuid);
        self.next_id +%= 1;
    }
};

fn collectLayoutPaneIds(ctx: *LayoutExportTabCtx, node: ?*const core.session_model.SessionLayoutNode) !void {
    const root = node orelse return;
    switch (root.*) {
        .pane => |uuid| try ctx.assign(uuid),
        .split => |split| {
            try collectLayoutPaneIds(ctx, split.first);
            try collectLayoutPaneIds(ctx, split.second);
        },
    }
}

fn writeLayoutExportNode(
    writer: anytype,
    node: ?*const core.session_model.SessionLayoutNode,
    ids: *const std.AutoHashMap([32]u8, u16),
) !void {
    const root = node orelse {
        try writer.writeAll("null");
        return;
    };

    switch (root.*) {
        .pane => |uuid| {
            const pane_id = ids.get(uuid) orelse 0;
            try writer.print("{{\"type\":\"pane\",\"id\":{d}}}", .{pane_id});
        },
        .split => |split| {
            try writer.writeAll("{\"type\":\"split\",\"dir\":");
            try writer.print("{f}", .{std.json.fmt(@tagName(split.dir), .{})});
            try writer.print(",\"ratio\":{d},\"first\":", .{split.ratio});
            try writeLayoutExportNode(writer, split.first, ids);
            try writer.writeAll(",\"second\":");
            try writeLayoutExportNode(writer, split.second, ids);
            try writer.writeAll("}");
        },
    }
}

pub fn buildLayoutExportJson(self: *Server, snapshot: *const state.SessionSnapshot) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(self.allocator);
    var writer = buf.writer(self.allocator);
    const active_float_index = blk: {
        if (snapshot.active_float_uuid) |active_uuid| {
            for (snapshot.floats.items, 0..) |float_state, idx| {
                if (std.mem.eql(u8, &float_state.pane_uuid, &active_uuid)) {
                    break :blk idx;
                }
            }
        }
        break :blk null;
    };

    try writer.writeAll("{\"active_tab\":");
    try writer.print("{d}", .{snapshot.active_tab});
    try writer.writeAll(",\"active_floating\":");
    if (active_float_index) |idx| {
        try writer.print("{d}", .{idx});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"tabs\":[");

    for (snapshot.tabs.items, 0..) |tab, ti| {
        if (ti > 0) try writer.writeAll(",");

        var ctx = LayoutExportTabCtx.init(self.allocator);
        defer ctx.deinit();
        try collectLayoutPaneIds(&ctx, tab.root);

        try writer.writeAll("{\"name\":");
        try writer.print("{f}", .{std.json.fmt(tab.name, .{})});
        try writer.writeAll(",\"tree\":");
        try writeLayoutExportNode(writer, tab.root, &ctx.ids);
        try writer.writeAll(",\"splits\":[");
        for (ctx.ordered.items, 0..) |uuid, pi| {
            if (pi > 0) try writer.writeAll(",");
            const pane_id = ctx.ids.get(uuid) orelse 0;
            try writer.print("{{\"id\":{d},\"uuid\":", .{pane_id});
            try writer.print("{f}", .{std.json.fmt(uuid[0..], .{})});
            if (self.ses_state.getPane(uuid)) |pane| {
                if (pane.cwd) |cwd| {
                    try writer.writeAll(",\"pwd_dir\":");
                    try writer.print("{f}", .{std.json.fmt(cwd, .{})});
                }
            }
            try writer.writeAll("}");
        }
        try writer.writeAll("]}");
    }

    try writer.writeAll("],\"floats\":[");
    for (snapshot.floats.items, 0..) |float_state, fi| {
        if (fi > 0) try writer.writeAll(",");
        try writer.writeAll("{\"uuid\":");
        try writer.print("{f}", .{std.json.fmt(float_state.pane_uuid[0..], .{})});
        try writer.print(",\"visible\":{}", .{float_state.visible});
        try writer.print(",\"tab_visible\":{d}", .{float_state.tab_visible});
        try writer.print(",\"float_key\":{d}", .{float_state.float_key});
        try writer.print(",\"float_width_pct\":{d}", .{float_state.width_pct});
        try writer.print(",\"float_height_pct\":{d}", .{float_state.height_pct});
        try writer.print(",\"float_pos_x_pct\":{d}", .{float_state.pos_x_pct});
        try writer.print(",\"float_pos_y_pct\":{d}", .{float_state.pos_y_pct});
        try writer.print(",\"float_pad_x\":{d}", .{float_state.pad_x});
        try writer.print(",\"float_pad_y\":{d}", .{float_state.pad_y});
        try writer.print(",\"is_pwd\":{}", .{float_state.is_pwd});
        try writer.print(",\"sticky\":{}", .{float_state.sticky});
        if (float_state.parent_tab) |parent_tab| {
            try writer.print(",\"parent_tab\":{d}", .{parent_tab});
        }
        if (self.ses_state.getPane(float_state.pane_uuid)) |pane| {
            if (pane.cwd) |cwd| {
                try writer.writeAll(",\"pwd_dir\":");
                try writer.print("{f}", .{std.json.fmt(cwd, .{})});
            }
        }
        try writer.writeAll("}");
    }
    try writer.writeAll("]}");
    return buf.toOwnedSlice(self.allocator);
}

/// Handle get_layout CLI request — derive layout export JSON from the
/// canonical session snapshot owned by SES.
pub fn handleGetLayout(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    // Note-then-close: a failed reply also queues this fd for close, and the
    // pending-close processor only skips NOTED fds. An unnoted direct close
    // here lets the queued entry fire later against whatever new connection
    // reused the fd number (the double-close family).
    defer {
        self.ses_state.store.noteClosedFd(fd);
        posix.close(fd);
    }

    if (payload_len < @sizeOf(wire.PaneUuid)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "invalid payload");
        return;
    }
    const pu = wire.readStructTimeout(wire.PaneUuid, fd, server.HANDLER_IO_TIMEOUT_MS) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "get_layout pane uuid read failed", err);
        self.sendBinaryError(fd, "read failed");
        return;
    };

    // Find the client that owns this pane UUID.
    const client = self.findClientForPaneUuid(pu.uuid) orelse {
        self.sendBinaryError(fd, "pane not found");
        return;
    };

    const snapshot = client.session_snapshot orelse {
        self.sendBinaryError(fd, "no session snapshot");
        return;
    };
    const layout_json = buildLayoutExportJson(self, &snapshot) catch |err| {
        core.logging.logError("ses", "failed to build layout export json", err);
        self.sendBinaryError(fd, "layout_export_failed");
        return;
    };
    defer self.allocator.free(layout_json);

    self.replyOrClose(fd, .get_layout, layout_json);
}

/// Handle get_session_state CLI request — return JSON state for detached session.
pub fn handleGetSessionState(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    // Note-then-close: a failed reply also queues this fd for close, and the
    // pending-close processor only skips NOTED fds. An unnoted direct close
    // here lets the queued entry fire later against whatever new connection
    // reused the fd number (the double-close family).
    defer {
        self.ses_state.store.noteClosedFd(fd);
        posix.close(fd);
    }

    // Expect exactly 32 bytes (hex UUID)
    if (payload_len != 32) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "invalid payload (expected 32-byte hex UUID)");
        return;
    }

    var hex_uuid: [32]u8 = undefined;
    wire.readExactTimeout(fd, &hex_uuid, server.HANDLER_IO_TIMEOUT_MS) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "get_session_state uuid read failed", err);
        self.sendBinaryError(fd, "read failed");
        return;
    };

    // Convert hex UUID to binary
    const session_id = core.uuid.hexToBin(hex_uuid) orelse {
        self.sendBinaryError(fd, "invalid hex UUID");
        return;
    };

    // Look up detached session
    const detached_state = self.ses_state.store.detached_sessions.get(session_id) orelse {
        self.sendBinaryError(fd, "session not found");
        return;
    };

    const session_json = detached_state.session_snapshot.toJson(self.allocator) catch |err| {
        core.logging.logError("ses", "failed to serialize detached session state", err);
        self.sendBinaryError(fd, "session_snapshot_failed");
        return;
    };
    defer self.allocator.free(session_json);

    self.replyOrClose(fd, .session_state, session_json);
}

/// Handle apply_layout CLI request — mutate canonical SES state, then push
/// the updated snapshot to the attached frontend.
pub fn handleApplyLayout(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    // Note-then-close: a failed reply also queues this fd for close, and the
    // pending-close processor only skips NOTED fds. An unnoted direct close
    // here lets the queued entry fire later against whatever new connection
    // reused the fd number (the double-close family).
    defer {
        self.ses_state.store.noteClosedFd(fd);
        posix.close(fd);
    }

    if (payload_len < @sizeOf(wire.ApplyLayout)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "invalid payload");
        return;
    }

    const al = wire.readStructTimeout(wire.ApplyLayout, fd, server.HANDLER_IO_TIMEOUT_MS) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "apply_layout request read failed", err);
        self.sendBinaryError(fd, "read failed");
        return;
    };

    // Read tree JSON.
    if (al.tree_json_len == 0 or al.tree_json_len > wire.MAX_PAYLOAD_LEN) {
        self.sendBinaryError(fd, "invalid json len");
        return;
    }

    const json_buf = self.allocator.alloc(u8, al.tree_json_len) catch |err| {
        core.logging.logError("ses", "apply_layout json allocation failed", err);
        self.sendBinaryError(fd, "alloc failed");
        return;
    };
    defer self.allocator.free(json_buf);

    wire.readExactTimeout(fd, json_buf, server.HANDLER_IO_TIMEOUT_MS) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "apply_layout json read failed", err);
        self.sendBinaryError(fd, "read json failed");
        return;
    };

    const pane = self.ses_state.getPane(al.uuid) orelse {
        self.sendBinaryError(fd, "pane not found");
        return;
    };
    const client_id = pane.attached_to orelse {
        self.sendBinaryError(fd, "pane not attached");
        return;
    };

    self.ses_state.applyClientSessionLayoutTemplate(client_id, al.uuid, json_buf) catch |err| {
        core.logging.logError("ses", "apply_layout template application failed", err);
        self.sendBinaryError(fd, "apply layout failed");
        return;
    };
    self.pushClientSessionSnapshot(client_id);
    self.replyOrClose(fd, .ok, &.{});
}
