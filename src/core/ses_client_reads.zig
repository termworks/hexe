//! SesClient synchronous response readers: the machinery that reads a CTL
//! reply for a specific request_id while tolerating interleaved async pushes
//! (shell events, notifies, pane exits, session_stolen, cwd/pane-info bodies) —
//! queuing or consuming those pushes instead of failing, so a sync call never
//! mistakes an unrelated push for "pane gone". This is the home of the float-
//! loss bug class (see the July 2026 hardening notes); it is moved here VERBATIM
//! from `frontend_client.zig` — free functions taking `*SesClient`, re-exported
//! there via `pub const` aliases so every call site and behavior is unchanged
//! (PLAN.md 2.3).

const std = @import("std");
const posix = std.posix;
const logging = @import("logging.zig");
const wire = @import("wire.zig");
const frontend_client = @import("frontend_client.zig");

const SesClient = frontend_client.SesClient;
const PaneInfoRead = SesClient.PaneInfoRead;
const PaneCwdRead = SesClient.PaneCwdRead;
const ControlResponseRead = SesClient.ControlResponseRead;
const PendingPaneInfoResponse = SesClient.PendingPaneInfoResponse;
const SYNC_RESPONSE_TIMEOUT_MS = frontend_client.SYNC_RESPONSE_TIMEOUT_MS;
const COMMAND_ACK_TIMEOUT_MS = frontend_client.COMMAND_ACK_TIMEOUT_MS;

pub fn readExpectedPaneInfoResponse(self: *SesClient, fd: posix.fd_t, expected_uuid: [32]u8, expected_request_id: u32) !PaneInfoRead {
    if (self.takePendingControlResponse(expected_request_id)) |pending_response| {
        var pending = pending_response;
        defer pending.deinit(self.allocator);
        if (pending.msg_type == .pane_not_found) return error.PaneMissing;
        if (pending.msg_type != .pane_info) return error.UnexpectedResponse;
        const read = try self.readPaneInfoPendingPayload(pending.payload);
        if (!std.mem.eql(u8, &read.resp.uuid, &expected_uuid)) {
            var owned = read;
            owned.deinit(self.allocator);
            return error.UnexpectedResponse;
        }
        return read;
    }

    while (true) {
        const hdr = try wire.readControlHeader(fd);
        const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        switch (msg_type) {
            .ok, .pane_exited, .session_state => {
                if (hdr.request_id != 0 and hdr.request_id != expected_request_id) {
                    try self.queuePendingControlResponseBody(fd, hdr);
                    continue;
                }
                self.consumeQueuedControlResponse(fd, hdr);
                continue;
            },
            .get_pane_cwd => {
                const resp = self.readPaneCwdBody(fd, hdr) catch |err| {
                    logging.logError("frontend-client", "failed to read queued pane cwd response", err);
                    if (self.ctl_fd == fd) self.ctl_fd = null;
                    return err;
                };
                self.queuePendingPaneCwdBody(fd, resp);
                continue;
            },
            .pane_info => {
                if (hdr.request_id != 0 and hdr.request_id != expected_request_id) {
                    try self.queuePendingControlResponseBody(fd, hdr);
                    continue;
                }
                if (hdr.payload_len < @sizeOf(wire.PaneInfoResp)) {
                    self.skipPayload(fd, hdr.payload_len);
                    logging.logError("frontend-client", "pane_info response too small", error.UnexpectedResponse);
                    if (self.ctl_fd == fd) self.ctl_fd = null;
                    return error.UnexpectedResponse;
                }
                const resp = wire.readStruct(wire.PaneInfoResp, fd) catch |err| {
                    self.skipPayload(fd, hdr.payload_len);
                    logging.logError("frontend-client", "failed to read pane_info response", err);
                    if (self.ctl_fd == fd) self.ctl_fd = null;
                    return err;
                };
                if (hdr.request_id == expected_request_id and std.mem.eql(u8, &resp.uuid, &expected_uuid)) {
                    return .{ .hdr = hdr, .resp = resp };
                }
                self.queuePaneInfoResponseBody(fd, resp);
                continue;
            },
            .pane_not_found => {
                self.skipPayload(fd, hdr.payload_len);
                // Only trust a reply correlated to OUR request: the
                // payload carries no UUID, so an uncorrelated
                // pane_not_found could belong to any other query and
                // must not condemn this pane.
                if (hdr.request_id == expected_request_id) {
                    // Definitive: SES does not know this pane.
                    return error.PaneMissing;
                }
                continue;
            },
            else => {
                if (hdr.request_id != 0 and hdr.request_id != expected_request_id) {
                    try self.queuePendingControlResponseBody(fd, hdr);
                    continue;
                }
                if (hdr.request_id == expected_request_id) {
                    // Some other definitive reply to our request.
                    self.skipPayload(fd, hdr.payload_len);
                    return error.UnexpectedResponse;
                }
                // Interleaved async push — consume without failing the
                // query; a spurious failure here gets interpreted as
                // "pane gone" and destroys live floats downstream.
                self.consumeQueuedControlResponse(fd, hdr);
                continue;
            },
        }
    }
}

pub fn readExpectedPaneCwdResponse(self: *SesClient, fd: posix.fd_t, expected_uuid: [32]u8, expected_request_id: u32) !PaneCwdRead {
    if (self.takePendingControlResponse(expected_request_id)) |pending_response| {
        var pending = pending_response;
        defer pending.deinit(self.allocator);
        if (pending.msg_type != .get_pane_cwd) return error.UnexpectedResponse;
        const read = try self.readPaneCwdPendingPayload(pending.payload);
        if (!std.mem.eql(u8, &read.uuid, &expected_uuid)) {
            var owned = read;
            owned.deinit(self.allocator);
            return error.UnexpectedResponse;
        }
        return read;
    }

    while (true) {
        const hdr = try wire.readControlHeader(fd);
        const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        switch (msg_type) {
            .ok, .pane_exited, .session_state, .pane_info => {
                if (hdr.request_id != 0 and hdr.request_id != expected_request_id and msg_type != .pane_info) {
                    self.skipPayload(fd, hdr.payload_len);
                    return error.UnexpectedResponse;
                }
                self.consumeQueuedControlResponse(fd, hdr);
                continue;
            },
            .get_pane_cwd => {
                if (hdr.request_id != 0 and hdr.request_id != expected_request_id) {
                    try self.queuePendingControlResponseBody(fd, hdr);
                    continue;
                }
                var resp = self.readPaneCwdBodyOwned(fd, hdr) catch |err| {
                    logging.logError("frontend-client", "failed to read pane cwd response", err);
                    if (self.ctl_fd == fd) self.ctl_fd = null;
                    return err;
                };
                if (hdr.request_id == expected_request_id and std.mem.eql(u8, &resp.uuid, &expected_uuid)) return resp;
                self.queuePendingCwdResponse(resp.uuid, resp.cwd);
                resp.deinit(self.allocator);
                continue;
            },
            else => {
                self.skipPayload(fd, hdr.payload_len);
                return error.UnexpectedResponse;
            },
        }
    }
}

pub fn remainingDeadlineMs(deadline_ms: i64) !i32 {
    const remaining = deadline_ms - std.time.milliTimestamp();
    if (remaining <= 0) return error.Timeout;
    return @intCast(@min(remaining, @as(i64, std.math.maxInt(i32))));
}

pub fn readSyncResponseForRequest(self: *SesClient, fd: posix.fd_t, expected_request_id: u32) !ControlResponseRead {
    return self.readSyncResponseUntilForRequest(fd, expected_request_id, std.time.milliTimestamp() + SYNC_RESPONSE_TIMEOUT_MS, "sync response");
}

pub fn readSyncResponseUntilForRequest(self: *SesClient, fd: posix.fd_t, expected_request_id: u32, deadline_ms: i64, comptime context: []const u8) !ControlResponseRead {
    if (self.takePendingControlResponse(expected_request_id)) |pending_response| {
        return .{
            .hdr = .{
                .msg_type = @intFromEnum(pending_response.msg_type),
                .request_id = pending_response.request_id,
                .payload_len = @intCast(pending_response.payload.len),
            },
            .payload = pending_response.payload,
        };
    }

    while (true) {
        const hdr = wire.readControlHeaderTimeout(fd, try remainingDeadlineMs(deadline_ms)) catch |err| {
            self.debugLog("{s}: timed out/failed waiting for control header: {s}", .{ context, @errorName(err) });
            return err;
        };
        const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        const matches_request = hdr.request_id == expected_request_id;
        switch (msg_type) {
            // Stale acks from older commands without dedicated responses.
            .ok => {
                if (matches_request) return .{ .hdr = hdr };
                if (hdr.request_id != 0) {
                    try self.queuePendingControlResponseBody(fd, hdr);
                    continue;
                }
                self.consumeQueuedControlResponse(fd, hdr);
                continue;
            },
            // Async get_pane_cwd response.
            .get_pane_cwd => {
                if (hdr.request_id != 0 and hdr.request_id != expected_request_id) {
                    try self.queuePendingControlResponseBody(fd, hdr);
                    continue;
                }
                self.consumeQueuedControlResponse(fd, hdr);
                continue;
            },
            // Async pane_info response (large payload = response, not request).
            .pane_info => {
                if (hdr.payload_len >= @sizeOf(wire.PaneInfoResp) and hdr.request_id == 0) {
                    self.consumeQueuedControlResponse(fd, hdr);
                    continue;
                }
                if (!matches_request and hdr.request_id != 0) {
                    try self.queuePendingControlResponseBody(fd, hdr);
                    continue;
                }
                return .{ .hdr = hdr };
            },
            .pane_exited => {
                self.consumeQueuedControlResponse(fd, hdr);
                continue;
            },
            .session_state => {
                self.consumeQueuedControlResponse(fd, hdr);
                continue;
            },
            else => {
                if (!matches_request) {
                    if (hdr.request_id != 0) {
                        try self.queuePendingControlResponseBody(fd, hdr);
                        continue;
                    }
                    // Interleaved async push (shell_event, notify,
                    // session_stolen, ...). It is not our response, so it
                    // must never fail this operation: consume it (types
                    // with preserve machinery are queued for the IPC
                    // loop) and keep waiting.
                    self.consumeQueuedControlResponse(fd, hdr);
                    continue;
                }
                return .{ .hdr = hdr };
            },
        }
    }
}

pub fn drainQueuedControlResponses(self: *SesClient, fd: posix.fd_t) void {
    while (true) {
        var fds = [_]posix.pollfd{
            .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
        };
        const ready = posix.poll(&fds, 0) catch |err| {
            logging.logError("frontend-client", "failed to poll queued control responses", err);
            if (self.ctl_fd == fd) self.ctl_fd = null;
            return;
        };
        if (ready == 0 or (fds[0].revents & posix.POLL.IN) == 0) return;

        const hdr = wire.readControlHeader(fd) catch |err| {
            logging.logError("frontend-client", "failed to read queued control response header", err);
            if (self.ctl_fd == fd) self.ctl_fd = null;
            return;
        };
        self.consumeQueuedControlResponse(fd, hdr);
    }
}

pub fn readCommandAckForRequest(self: *SesClient, fd: posix.fd_t, expected_request_id: u32) !void {
    return self.readCommandAckUntilForRequest(fd, expected_request_id, std.time.milliTimestamp() + COMMAND_ACK_TIMEOUT_MS, "command ack");
}

pub fn readCommandAckUntilForRequest(self: *SesClient, fd: posix.fd_t, expected_request_id: u32, deadline_ms: i64, comptime context: []const u8) !void {
    if (self.takePendingControlResponse(expected_request_id)) |pending_response| {
        var pending = pending_response;
        defer pending.deinit(self.allocator);
        switch (pending.msg_type) {
            .ok => return,
            .@"error" => return error.SesError,
            else => return error.UnexpectedResponse,
        }
    }

    while (true) {
        const hdr = wire.readControlHeaderTimeout(fd, try remainingDeadlineMs(deadline_ms)) catch |err| {
            self.debugLog("{s}: timed out/failed waiting for ack header: {s}", .{ context, @errorName(err) });
            return err;
        };
        const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        const matches_request = hdr.request_id == expected_request_id;
        switch (msg_type) {
            .ok => {
                if (!matches_request) {
                    if (hdr.request_id == 0) {
                        self.skipPayload(fd, hdr.payload_len);
                        continue;
                    }
                    try self.queuePendingControlResponseBody(fd, hdr);
                    continue;
                }
                self.skipPayload(fd, hdr.payload_len);
                return;
            },
            .@"error" => {
                if (!matches_request) {
                    if (hdr.request_id == 0) {
                        self.skipPayload(fd, hdr.payload_len);
                        continue;
                    }
                    try self.queuePendingControlResponseBody(fd, hdr);
                    continue;
                }
                self.skipPayload(fd, hdr.payload_len);
                return error.SesError;
            },
            .get_pane_cwd, .pane_info, .pane_exited, .session_state => {
                self.consumeQueuedControlResponse(fd, hdr);
                continue;
            },
            else => {
                if (!matches_request) {
                    if (hdr.request_id != 0) {
                        try self.queuePendingControlResponseBody(fd, hdr);
                        continue;
                    }
                    // Async push interleaved with the ack — consume it
                    // instead of failing the command (see
                    // readSyncResponseUntilForRequest).
                    self.consumeQueuedControlResponse(fd, hdr);
                    continue;
                }
                self.skipPayload(fd, hdr.payload_len);
                return error.UnexpectedResponse;
            },
        }
    }
}

pub fn queuePendingControlResponseBody(self: *SesClient, fd: posix.fd_t, hdr: wire.ControlHeader) !void {
    if (hdr.request_id == 0) {
        self.skipPayload(fd, hdr.payload_len);
        return;
    }
    if (hdr.payload_len > wire.MAX_PAYLOAD_LEN) {
        self.skipPayload(fd, hdr.payload_len);
        return error.UnexpectedResponse;
    }
    const payload = try self.allocator.alloc(u8, hdr.payload_len);
    errdefer self.allocator.free(payload);
    if (hdr.payload_len > 0) {
        try wire.readExact(fd, payload);
    }
    self.queuePendingControlResponse(.{
        .request_id = hdr.request_id,
        .msg_type = @enumFromInt(hdr.msg_type),
        .payload = payload,
    });
}

pub fn consumeQueuedControlResponse(self: *SesClient, fd: posix.fd_t, hdr: wire.ControlHeader) void {
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    switch (msg_type) {
        .pane_exited => {
            if (hdr.payload_len >= @sizeOf(wire.PaneUuid)) {
                const pu = wire.readStruct(wire.PaneUuid, fd) catch {
                    self.skipPayload(fd, hdr.payload_len);
                    return;
                };
                self.queuePendingPaneExit(pu.uuid);
                const rem = hdr.payload_len - @sizeOf(wire.PaneUuid);
                if (rem > 0) self.skipPayload(fd, rem);
            } else {
                self.skipPayload(fd, hdr.payload_len);
            }
        },
        .session_state => {
            if (hdr.payload_len == 0 or hdr.payload_len > wire.MAX_PAYLOAD_LEN) {
                self.skipPayload(fd, hdr.payload_len);
                return;
            }
            const json = self.allocator.alloc(u8, hdr.payload_len) catch {
                self.skipPayload(fd, hdr.payload_len);
                return;
            };
            wire.readExact(fd, json) catch {
                self.allocator.free(json);
                return;
            };
            self.queuePendingSessionState(json);
            self.allocator.free(json);
        },
        .get_pane_cwd => {
            const resp = self.readPaneCwdBody(fd, hdr) catch |err| {
                logging.logError("frontend-client", "failed to consume queued pane cwd response", err);
                if (self.ctl_fd == fd) self.ctl_fd = null;
                return;
            };
            self.queuePendingPaneCwdBody(fd, resp);
        },
        .pane_info => {
            if (hdr.payload_len < @sizeOf(wire.PaneInfoResp)) {
                self.skipPayload(fd, hdr.payload_len);
                logging.logError("frontend-client", "queued pane_info response too small", error.UnexpectedResponse);
                if (self.ctl_fd == fd) self.ctl_fd = null;
                return;
            }
            const resp = wire.readStruct(wire.PaneInfoResp, fd) catch |err| {
                self.skipPayload(fd, hdr.payload_len);
                logging.logError("frontend-client", "failed to consume queued pane_info response", err);
                if (self.ctl_fd == fd) self.ctl_fd = null;
                return;
            };
            self.queuePaneInfoResponseBody(fd, resp);
        },
        .session_stolen => {
            // Must never be dropped: without it this mux keeps writing
            // into a session another client now owns.
            self.skipPayload(fd, hdr.payload_len);
            self.pending_session_stolen = true;
        },
        else => self.skipPayload(fd, hdr.payload_len),
    }
}

pub fn readPaneCwdBody(self: *SesClient, fd: posix.fd_t, hdr: wire.ControlHeader) !wire.PaneCwd {
    if (hdr.payload_len < @sizeOf(wire.PaneCwd)) {
        self.skipPayload(fd, hdr.payload_len);
        return error.UnexpectedResponse;
    }
    return wire.readStruct(wire.PaneCwd, fd);
}

pub fn readPaneCwdBodyOwned(self: *SesClient, fd: posix.fd_t, hdr: wire.ControlHeader) !PaneCwdRead {
    const resp = try self.readPaneCwdBody(fd, hdr);
    const body_len = hdr.payload_len - @sizeOf(wire.PaneCwd);
    if (resp.cwd_len == 0) {
        if (body_len > 0) self.skipPayload(fd, body_len);
        return .{ .uuid = resp.uuid, .cwd = &.{} };
    }
    if (resp.cwd_len != body_len or resp.cwd_len > wire.MAX_PAYLOAD_LEN) {
        self.skipPayload(fd, body_len);
        return error.UnexpectedResponse;
    }
    const cwd = try self.allocator.alloc(u8, resp.cwd_len);
    errdefer self.allocator.free(cwd);
    try wire.readExact(fd, cwd);
    return .{ .uuid = resp.uuid, .cwd = cwd };
}

pub fn readPaneCwdPendingPayload(self: *SesClient, payload: []const u8) !PaneCwdRead {
    if (payload.len < @sizeOf(wire.PaneCwd)) return error.UnexpectedResponse;
    const resp = wire.bytesToStruct(wire.PaneCwd, payload[0..@sizeOf(wire.PaneCwd)]) orelse return error.UnexpectedResponse;
    const body = payload[@sizeOf(wire.PaneCwd)..];
    if (resp.cwd_len == 0) return .{ .uuid = resp.uuid, .cwd = &.{} };
    if (resp.cwd_len != body.len or resp.cwd_len > wire.MAX_PAYLOAD_LEN) return error.UnexpectedResponse;
    const cwd = try self.allocator.dupe(u8, body);
    return .{ .uuid = resp.uuid, .cwd = cwd };
}

pub fn queuePendingPaneCwdBody(self: *SesClient, fd: posix.fd_t, resp: wire.PaneCwd) void {
    if (resp.cwd_len == 0) return;
    if (resp.cwd_len > wire.MAX_PAYLOAD_LEN) {
        self.skipPayload(fd, resp.cwd_len);
        logging.logError("frontend-client", "queued pane cwd response too large", error.UnexpectedResponse);
        return;
    }
    const cwd = self.allocator.alloc(u8, resp.cwd_len) catch {
        self.skipPayload(fd, resp.cwd_len);
        logging.logError("frontend-client", "failed to allocate queued pane cwd response", error.OutOfMemory);
        return;
    };
    defer self.allocator.free(cwd);
    wire.readExact(fd, cwd) catch |err| {
        logging.logError("frontend-client", "failed to read queued pane cwd payload", err);
        if (self.ctl_fd == fd) self.ctl_fd = null;
        return;
    };
    self.queuePendingCwdResponse(resp.uuid, cwd);
}

pub fn readPaneInfoPendingPayload(self: *SesClient, payload: []const u8) !PaneInfoRead {
    if (payload.len < @sizeOf(wire.PaneInfoResp)) return error.UnexpectedResponse;
    const resp = wire.bytesToStruct(wire.PaneInfoResp, payload[0..@sizeOf(wire.PaneInfoResp)]) orelse return error.UnexpectedResponse;
    const trail = payload[@sizeOf(wire.PaneInfoResp)..];
    const expected_trail_len: usize = @as(usize, resp.name_len) + @as(usize, resp.fg_len) +
        @as(usize, resp.cwd_len) + @as(usize, resp.tty_len) +
        @as(usize, resp.socket_path_len) + @as(usize, resp.session_name_len) +
        @as(usize, resp.layout_path_len) + @as(usize, resp.last_cmd_len) +
        @as(usize, resp.base_process_len) + @as(usize, resp.sticky_pwd_len);
    if (expected_trail_len != trail.len) return error.UnexpectedResponse;

    const owned_trail = try self.allocator.dupe(u8, trail);
    return .{
        .hdr = .{
            .msg_type = @intFromEnum(wire.MsgType.pane_info),
            .request_id = 0,
            .payload_len = @intCast(payload.len),
        },
        .resp = resp,
        .trail = owned_trail,
    };
}

pub fn queuePaneInfoResponseBody(self: *SesClient, fd: posix.fd_t, resp: wire.PaneInfoResp) void {
    const trail_total: usize = @as(usize, resp.name_len) + @as(usize, resp.fg_len) +
        @as(usize, resp.cwd_len) + @as(usize, resp.tty_len) +
        @as(usize, resp.socket_path_len) + @as(usize, resp.session_name_len) +
        @as(usize, resp.layout_path_len) + @as(usize, resp.last_cmd_len) +
        @as(usize, resp.base_process_len) + @as(usize, resp.sticky_pwd_len);

    var pending = PendingPaneInfoResponse{
        .uuid = resp.uuid,
        .fg_pid = if (resp.fg_pid != 0) resp.fg_pid else null,
    };
    var queued = false;
    defer if (!queued) pending.deinit(self.allocator);

    if (resp.name_len > 0) {
        pending.name = self.allocator.alloc(u8, resp.name_len) catch {
            self.skipPayload(fd, @intCast(trail_total));
            logging.logError("frontend-client", "failed to allocate queued pane name", error.OutOfMemory);
            return;
        };
        wire.readExact(fd, pending.name.?) catch |err| {
            logging.logError("frontend-client", "failed to read queued pane name", err);
            if (self.ctl_fd == fd) self.ctl_fd = null;
            return;
        };
    }
    if (resp.fg_len > 0) {
        pending.fg_name = self.allocator.alloc(u8, resp.fg_len) catch {
            const remaining = trail_total -| @as(usize, resp.name_len);
            self.skipPayload(fd, @intCast(remaining));
            logging.logError("frontend-client", "failed to allocate queued pane foreground name", error.OutOfMemory);
            return;
        };
        wire.readExact(fd, pending.fg_name.?) catch |err| {
            logging.logError("frontend-client", "failed to read queued pane foreground name", err);
            if (self.ctl_fd == fd) self.ctl_fd = null;
            return;
        };
    }

    const remaining = trail_total -| @as(usize, resp.name_len) -| @as(usize, resp.fg_len);
    if (remaining > 0) self.skipPayload(fd, @intCast(remaining));
    queued = true;
    self.queuePendingPaneInfoResponse(pending);
}

pub fn skipPayloadChecked(_: *SesClient, fd: posix.fd_t, len: u32) !void {
    var remaining: usize = len;
    var buf: [4096]u8 = undefined;
    while (remaining > 0) {
        const chunk = @min(remaining, buf.len);
        try wire.readExact(fd, buf[0..chunk]);
        remaining -= chunk;
    }
}

pub fn skipPayload(self: *SesClient, fd: posix.fd_t, len: u32) void {
    self.skipPayloadChecked(fd, len) catch |err| {
        logging.logError("frontend-client", "failed to skip control payload", err);
        if (self.ctl_fd == fd) self.ctl_fd = null;
    };
}

pub fn skipPayloadU16Checked(_: *SesClient, fd: posix.fd_t, len: u16) !void {
    var remaining: usize = len;
    var buf: [4096]u8 = undefined;
    while (remaining > 0) {
        const chunk = @min(remaining, buf.len);
        try wire.readExact(fd, buf[0..chunk]);
        remaining -= chunk;
    }
}

pub fn skipPayloadU16(self: *SesClient, fd: posix.fd_t, len: u16) void {
    self.skipPayloadU16Checked(fd, len) catch |err| {
        logging.logError("frontend-client", "failed to skip control payload", err);
        if (self.ctl_fd == fd) self.ctl_fd = null;
    };
}

pub fn skipPayloadU32(self: *SesClient, fd: posix.fd_t, len: u32) void {
    self.skipPayload(fd, len);
}
