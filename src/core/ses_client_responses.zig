//! SesClient response store: the pending sync/async response queues captured
//! while a synchronous CTL call is in flight (pane exits, cwd replies, pane-info
//! replies, session-state pushes, control-response bodies, session-stolen
//! pushes) plus the resolved-name handoff.
//!
//! Extracted from `frontend_client.zig` as free functions taking `*SesClient`
//! and re-exported there via `pub const` aliases, so call sites are unchanged
//! (PLAN.md 2.3). These touch only the client's `pending_*` fields,
//! `resolved_name`, and its allocator — no transport or wire I/O.

const std = @import("std");
const posix = std.posix;
const logging = @import("logging.zig");
const wire = @import("wire.zig");
const frontend_client = @import("frontend_client.zig");

const SesClient = frontend_client.SesClient;
const PendingCwdResponse = SesClient.PendingCwdResponse;
const PendingPaneInfoResponse = SesClient.PendingPaneInfoResponse;
const PendingControlResponse = SesClient.PendingControlResponse;

pub fn queuePendingPaneExit(self: *SesClient, uuid: [32]u8) void {
    for (self.pending_pane_exits.items) |existing| {
        if (std.mem.eql(u8, &existing, &uuid)) return;
    }
    self.pending_pane_exits.append(self.allocator, uuid) catch |err| {
        logging.logError("frontend-client", "failed to queue pending pane exit", err);
    };
}

/// Move queued pane-exit messages captured during sync calls into `out`.
pub fn drainPendingPaneExits(self: *SesClient, out: *std.ArrayList([32]u8)) void {
    if (self.pending_pane_exits.items.len == 0) return;
    out.appendSlice(self.allocator, self.pending_pane_exits.items) catch |err| {
        logging.logError("frontend-client", "failed to drain pending pane exits", err);
        return;
    };
    self.pending_pane_exits.clearRetainingCapacity();
}

pub fn queuePendingSessionState(self: *SesClient, session_state_json: []const u8) void {
    const owned = self.allocator.dupe(u8, session_state_json) catch |err| {
        logging.logError("frontend-client", "failed to queue pending session state", err);
        return;
    };
    if (self.pending_session_state) |old| self.allocator.free(old);
    self.pending_session_state = owned;
}

pub fn queuePendingCwdResponse(self: *SesClient, uuid: [32]u8, cwd: []const u8) void {
    const owned = self.allocator.dupe(u8, cwd) catch |err| {
        logging.logError("frontend-client", "failed to copy pending cwd response", err);
        return;
    };
    self.pending_cwd_responses.append(self.allocator, .{ .uuid = uuid, .cwd = owned }) catch |err| {
        logging.logError("frontend-client", "failed to queue pending cwd response", err);
        self.allocator.free(owned);
        return;
    };
}

pub fn drainPendingCwdResponse(self: *SesClient) ?PendingCwdResponse {
    if (self.pending_cwd_responses.items.len == 0) return null;
    return self.pending_cwd_responses.orderedRemove(0);
}

pub fn queuePendingPaneInfoResponse(self: *SesClient, response: PendingPaneInfoResponse) void {
    var owned = response;
    self.pending_pane_info_responses.append(self.allocator, owned) catch {
        owned.deinit(self.allocator);
        return;
    };
}

pub fn drainPendingPaneInfoResponse(self: *SesClient) ?PendingPaneInfoResponse {
    if (self.pending_pane_info_responses.items.len == 0) return null;
    return self.pending_pane_info_responses.orderedRemove(0);
}

pub fn drainPendingSessionState(self: *SesClient) ?[]u8 {
    const pending = self.pending_session_state orelse return null;
    self.pending_session_state = null;
    return pending;
}

pub fn queuePendingControlResponse(self: *SesClient, response: PendingControlResponse) void {
    var owned = response;
    self.pending_control_responses.append(self.allocator, owned) catch |err| {
        owned.deinit(self.allocator);
        logging.logError("frontend-client", "failed to queue pending control response", err);
        return;
    };
}

pub fn takePendingControlResponse(self: *SesClient, request_id: u32) ?PendingControlResponse {
    if (request_id == 0) return null;
    for (self.pending_control_responses.items, 0..) |resp, i| {
        if (resp.request_id == request_id) {
            return self.pending_control_responses.orderedRemove(i);
        }
    }
    return null;
}

pub fn takeResolvedNameOwned(self: *SesClient) ?[]u8 {
    const resolved = self.resolved_name orelse return null;
    self.resolved_name = null;
    return resolved;
}

/// Returns true once per consumed session_stolen push (see field docs).
pub fn drainPendingSessionStolen(self: *SesClient) bool {
    const stolen = self.pending_session_stolen;
    self.pending_session_stolen = false;
    return stolen;
}

/// Capture an async push consumed by a synchronous reader so the IPC loop can
/// replay it. Bounded in count and payload size: overflow falls back to the
/// old skip-and-drop (logged), never to blocking or unbounded memory. The
/// payload cap also guarantees a replay pipe write cannot block (< 64K pipe
/// buffer).
pub const MAX_QUEUED_PUSHES: usize = 64;
pub const MAX_QUEUED_PUSH_PAYLOAD: usize = 60 * 1024;

pub fn queuePendingPush(self: *SesClient, fd: posix.fd_t, hdr: wire.ControlHeader) void {
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    const replayable = switch (msg_type) {
        .float_request,
        .notify,
        .targeted_notify,
        .shell_event,
        .send_keys,
        .focus_move,
        .exit_intent,
        .pane_exited,
        .pop_confirm,
        .pop_choose,
        => true,
        else => false,
    };
    if (!replayable or hdr.payload_len > MAX_QUEUED_PUSH_PAYLOAD or
        self.pending_pushes.items.len >= MAX_QUEUED_PUSHES)
    {
        if (replayable) {
            logging.warn("frontend-client", "dropping queued push type=0x{x:0>4} len={d} (queue full or oversized)", .{ hdr.msg_type, hdr.payload_len });
        }
        self.skipPayload(fd, hdr.payload_len);
        return;
    }
    const payload = self.allocator.alloc(u8, hdr.payload_len) catch {
        self.skipPayload(fd, hdr.payload_len);
        return;
    };
    wire.readExact(fd, payload) catch |err| {
        self.allocator.free(payload);
        logging.logError("frontend-client", "failed to read queued push payload", err);
        if (self.ctl_fd == fd) self.ctl_fd = null;
        return;
    };
    self.pending_pushes.append(self.allocator, .{
        .msg_type = hdr.msg_type,
        .request_id = hdr.request_id,
        .payload = payload,
    }) catch {
        self.allocator.free(payload);
    };
}
