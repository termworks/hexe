//! Pane-lifecycle CTL handlers (create/find-sticky/orphan/adopt/kill/set-sticky/
//! get-cwd), extracted from server.zig (PLAN.md 2.3 god-object split). Pure
//! move: Server methods taking `*Server`, dispatched by name.
const std = @import("std");
const posix = std.posix;
const core = @import("core");
const wire = core.wire;
const ses = @import("main.zig");
const server = @import("server.zig");
const Server = server.Server;

pub fn handleBinaryCreatePane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.CreatePane)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "create_pane: payload too small for CreatePane struct");
        return;
    }
    const cp = wire.readStructTimeout(wire.CreatePane, fd, server.HANDLER_IO_TIMEOUT_MS) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "create_pane request read failed", err);
        self.sendBinaryError(fd, "create_pane: read failed");
        return;
    };
    const trail_len = payload_len - @sizeOf(wire.CreatePane);

    // Read trailing: shell + cwd + sticky_pwd.
    if (trail_len > buf.len) {
        self.skipBinaryPayload(fd, trail_len, buf);
        self.sendBinaryError(fd, "payload_too_large");
        return;
    }
    if (trail_len > 0) {
        wire.readExactTimeout(fd, buf[0..trail_len], server.HANDLER_IO_TIMEOUT_MS) catch |err| {
            self.ctlStreamDesynced(fd, "mid-message read failed");
            core.logging.logError("ses", "create_pane trail read failed", err);
            self.sendBinaryError(fd, "create_pane: trail read failed");
            return;
        };
    }

    ses.debugLog("create_pane: shell_len={d} cwd_len={d} sticky_key={d} isolation_profile_len={d} env_count={d}", .{ cp.shell_len, cp.cwd_len, cp.sticky_key, cp.isolation_profile_len, cp.env_count });

    var offset: usize = 0;
    const shell = if (cp.shell_len > 0) blk: {
        if (offset + cp.shell_len > trail_len) {
            self.sendBinaryError(fd, "create_pane: malformed shell trail");
            return;
        }
        const s = buf[offset .. offset + cp.shell_len];
        offset += cp.shell_len;
        break :blk s;
    } else blk: {
        break :blk @as([]const u8, std.posix.getenv("SHELL") orelse "/bin/sh");
    };
    const cwd: ?[]const u8 = if (cp.cwd_len > 0) blk: {
        if (offset + cp.cwd_len > trail_len) {
            self.sendBinaryError(fd, "create_pane: malformed cwd trail");
            return;
        }
        const c = buf[offset .. offset + cp.cwd_len];
        offset += cp.cwd_len;
        break :blk c;
    } else null;
    const sticky_pwd: ?[]const u8 = if (cp.sticky_pwd_len > 0) blk: {
        if (offset + cp.sticky_pwd_len > trail_len) {
            self.sendBinaryError(fd, "create_pane: malformed sticky pwd trail");
            return;
        }
        const p = buf[offset .. offset + cp.sticky_pwd_len];
        offset += cp.sticky_pwd_len;
        break :blk p;
    } else null;
    const isolation_profile: ?[]const u8 = if (cp.isolation_profile_len > 0) blk: {
        if (offset + cp.isolation_profile_len > trail_len) {
            self.sendBinaryError(fd, "create_pane: malformed isolation profile trail");
            return;
        }
        const p = buf[offset .. offset + cp.isolation_profile_len];
        offset += cp.isolation_profile_len;
        break :blk p;
    } else null;
    const inherit_env_parent_uuid: ?[32]u8 = if (cp.inherit_env_parent_uuid_len > 0) blk: {
        if (cp.inherit_env_parent_uuid_len != 32 or offset + 32 > trail_len) {
            self.sendBinaryError(fd, "create_pane: malformed inherit-env parent uuid");
            return;
        }
        var uuid: [32]u8 = undefined;
        @memcpy(&uuid, buf[offset .. offset + 32]);
        offset += 32;
        break :blk uuid;
    } else null;
    const sticky_key: ?u8 = if (cp.sticky_key != 0) cp.sticky_key else null;

    var env_list: std.ArrayList([]const u8) = .empty;
    defer env_list.deinit(self.allocator);
    for (0..cp.env_count) |_| {
        if (offset + 2 > trail_len) {
            self.sendBinaryError(fd, "create_pane: malformed env entry header");
            return;
        }
        const entry_len = std.mem.readInt(u16, buf[offset..][0..2], .little);
        offset += 2;
        if (offset + entry_len > trail_len) {
            self.sendBinaryError(fd, "create_pane: malformed env entry body");
            return;
        }
        env_list.append(self.allocator, buf[offset .. offset + entry_len]) catch |err| {
            core.logging.logError("ses", "create_pane env list allocation failed", err);
            self.sendBinaryError(fd, "create_pane: env list alloc failed");
            return;
        };
        offset += entry_len;
    }
    if (offset != trail_len) {
        self.sendBinaryError(fd, "create_pane: trailing payload length mismatch");
        return;
    }

    // Resolve parent environment if inherit_env was requested.
    var parent_env: ?[]const []const u8 = null;
    defer if (parent_env) |env_entries| {
        for (env_entries) |e| self.allocator.free(e);
        self.allocator.free(env_entries);
    };
    if (inherit_env_parent_uuid) |parent_uuid| {
        if (self.ses_state.getPane(parent_uuid)) |parent_pane| {
            parent_env = parent_pane.getProcEnviron(self.allocator);
        }
    }

    var merged_env_storage: ?[]const []const u8 = null;
    defer if (merged_env_storage) |slice| self.allocator.free(slice);
    const spawn_env: ?[]const []const u8 = blk: {
        if (parent_env) |base| {
            if (env_list.items.len == 0) break :blk base;
            const merged = self.allocator.alloc([]const u8, base.len + env_list.items.len) catch |err| {
                core.logging.logError("ses", "create_pane environment merge allocation failed", err);
                self.sendBinaryError(fd, "create_pane: env merge alloc failed");
                return;
            };
            @memcpy(merged[0..base.len], base);
            @memcpy(merged[base.len..], env_list.items);
            merged_env_storage = merged;
            break :blk merged;
        }
        if (env_list.items.len > 0) break :blk env_list.items;
        break :blk null;
    };

    const client_id = self.findClientForCtlFd(fd) orelse blk: {
        const cid = self.ses_state.addClient(fd) catch |err| {
            core.logging.logError("ses", "create_pane failed to add client", err);
            self.sendBinaryError(fd, "client_add_failed");
            return;
        };
        break :blk cid;
    };

    // Sticky/per-cwd pane reuse: if a matching sticky pane already exists,
    // attach/take over it instead of spawning a new pod.
    if (sticky_pwd) |pwd| {
        if (sticky_key) |key| {
            const preferred_session = if (self.ses_state.getClient(client_id)) |client|
                client.session_name
            else
                null;

            if (self.ses_state.findStickyPaneWithAffinity(pwd, key, preferred_session)) |existing| {
                if (existing.state == .detached or self.ses_state.isPaneParked(existing)) {
                    self.ses_state.removePaneFromDetachedSessions(existing.uuid);
                }
                if (existing.attached_to) |owner_id| {
                    if (owner_id != client_id) {
                        _ = self.ses_state.stealAttachedPane(existing.uuid, client_id);
                        _ = self.ses_state.attachPane(existing.uuid, client_id) catch |err| {
                            core.logging.logError("ses", "create_pane failed to attach stolen sticky pane", err);
                            self.sendBinaryError(fd, "attach_existing_failed");
                            return;
                        };
                    }
                } else {
                    _ = self.ses_state.attachPane(existing.uuid, client_id) catch |err| {
                        core.logging.logError("ses", "create_pane failed to attach sticky pane", err);
                        self.sendBinaryError(fd, "attach_existing_failed");
                        return;
                    };
                }

                // Force backlog replay for fresh renderer state in the new mux.
                if (self.ses_state.getPane(existing.uuid)) |p| {
                    p.needs_backlog_replay = true;
                }
                replayPaneBacklogNow(self, existing.uuid);

                self.ses_state.markDirty();
                var existing_resp = wire.PaneCreated{
                    .uuid = existing.uuid,
                    .pid = existing.child_pid,
                    .pane_id = existing.pane_id,
                    .socket_path_len = @intCast(existing.pod_socket_path.len),
                };
                self.replyOrCloseWithTrail(fd, .pane_created, std.mem.asBytes(&existing_resp), existing.pod_socket_path);
                return;
            }
        }
    }

    const pane = self.ses_state.createPane(client_id, shell, cwd, sticky_pwd, sticky_key, spawn_env, isolation_profile) catch |err| {
        core.logging.logError("ses", "create_pane failed to spawn pane", err);
        self.sendBinaryError(fd, "create_failed");
        return;
    };
    self.ses_state.markDirty();
    ses.debugLog("binary: pane created {s} (pid={d}, pane_id={d})", .{ pane.uuid[0..8], pane.child_pid, pane.pane_id });

    // Send PaneCreated response.
    var resp = wire.PaneCreated{
        .uuid = pane.uuid,
        .pid = pane.child_pid,
        .pane_id = pane.pane_id,
        .socket_path_len = @intCast(pane.pod_socket_path.len),
    };
    self.replyOrCloseWithTrail(fd, .pane_created, std.mem.asBytes(&resp), pane.pod_socket_path);
}

pub fn replayPaneBacklogNow(self: *Server, uuid: [32]u8) void {
    const pane = self.ses_state.getPane(uuid) orelse return;
    const owner_id = pane.attached_to orelse {
        pane.needs_backlog_replay = true;
        return;
    };
    const owner = self.ses_state.getClient(owner_id) orelse {
        pane.needs_backlog_replay = true;
        return;
    };
    if (owner.mux_vt_fd == null) {
        pane.needs_backlog_replay = true;
        return;
    }

    const pane_id = pane.pane_id;
    const pod_socket_path = pane.pod_socket_path;
    if (self.ses_state.connectPodVt(uuid, pod_socket_path, pane_id)) {
        if (self.ses_state.getPane(uuid)) |updated| {
            updated.needs_backlog_replay = false;
        }
    } else if (self.ses_state.getPane(uuid)) |updated| {
        updated.needs_backlog_replay = true;
    }
}

pub fn handleBinaryFindSticky(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.FindSticky)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "find_sticky: payload too small");
        return;
    }
    const fs = wire.readStructTimeout(wire.FindSticky, fd, server.HANDLER_IO_TIMEOUT_MS) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "find_sticky request read failed", err);
        self.sendBinaryError(fd, "find_sticky: read failed");
        return;
    };
    if (fs.pwd_len > buf.len) {
        self.skipBinaryPayload(fd, fs.pwd_len, buf);
        self.sendBinaryError(fd, "find_sticky: pwd too large");
        return;
    }
    if (fs.pwd_len > 0) {
        wire.readExactTimeout(fd, buf[0..fs.pwd_len], server.HANDLER_IO_TIMEOUT_MS) catch |err| {
            self.ctlStreamDesynced(fd, "mid-message read failed");
            core.logging.logError("ses", "find_sticky pwd read failed", err);
            self.sendBinaryError(fd, "find_sticky: pwd read failed");
            return;
        };
    }
    const pwd = buf[0..fs.pwd_len];

    const client_id = self.findClientForCtlFd(fd) orelse {
        self.replyOrClose(fd, .pane_not_found, &.{});
        return;
    };

    // Get session name for affinity preference
    const preferred_session = if (self.ses_state.getClient(client_id)) |client|
        client.session_name
    else
        null;

    if (self.ses_state.findStickyPaneWithAffinity(pwd, fs.key, preferred_session)) |pane| {
        var already_attached_to_client = false;
        if (pane.attached_to) |owner_id| {
            already_attached_to_client = owner_id == client_id;
        }

        if (fs.claim_free != 0 and !already_attached_to_client) {
            // Claim-free lookups (startup/reattach reconciliation) must
            // never steal: refuse panes owned by another live client and
            // panes parked inside a detached session's adoptable set. The
            // explicit toggle handoff path uses claim_free=0 instead.
            if (pane.attached_to) |owner_id| {
                if (self.ses_state.getClient(owner_id) != null) {
                    ses.debugLog("find_sticky: claim_free refused, uuid={s} owned by live client {d}", .{ pane.uuid[0..8], owner_id });
                    self.replyOrClose(fd, .pane_not_found, &.{});
                    return;
                }
            }
            if (self.ses_state.isPaneParked(pane)) {
                ses.debugLog("find_sticky: claim_free refused, uuid={s} parked in detached session", .{pane.uuid[0..8]});
                self.replyOrClose(fd, .pane_not_found, &.{});
                return;
            }
        }

        if (pane.state == .detached or self.ses_state.isPaneParked(pane)) {
            self.ses_state.removePaneFromDetachedSessions(pane.uuid);
        }
        if (!already_attached_to_client) {
            if (pane.attached_to) |owner_id| {
                if (owner_id != client_id) {
                    _ = self.ses_state.stealAttachedPane(pane.uuid, client_id);
                }
            }
        }

        if (!already_attached_to_client) {
            _ = self.ses_state.attachPane(pane.uuid, client_id) catch |err| {
                core.logging.logError("ses", "find_sticky failed to attach sticky pane", err);
                self.replyOrClose(fd, .pane_not_found, &.{});
                return;
            };
        }

        // New mux needs a full screen restore for sticky adoption/takeover.
        // Try the VT replay immediately so cross-session CWD-float handoff
        // feels instant; keep needs_backlog_replay set if the mux VT/pod VT
        // endpoint is not ready yet so the periodic worker can retry.
        if (self.ses_state.getPane(pane.uuid)) |p| {
            p.needs_backlog_replay = true;
        }
        replayPaneBacklogNow(self, pane.uuid);
        ses.debugLog("find_sticky: requested immediate backlog replay for uuid={s}", .{pane.uuid[0..8]});

        var resp = wire.PaneFound{
            .uuid = pane.uuid,
            .pid = pane.child_pid,
            .pane_id = pane.pane_id,
            .socket_path_len = @intCast(pane.pod_socket_path.len),
        };
        self.replyOrCloseWithTrail(fd, .pane_found, std.mem.asBytes(&resp), pane.pod_socket_path);
    } else {
        self.replyOrClose(fd, .pane_not_found, &.{});
    }
}

pub fn handleBinaryOrphanPane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.PaneUuid)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "orphan_pane: payload too small for PaneUuid");
        return;
    }
    const pu = wire.readStructTimeout(wire.PaneUuid, fd, server.HANDLER_IO_TIMEOUT_MS) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "orphan_pane request read failed", err);
        self.sendBinaryError(fd, "orphan_pane: read failed");
        return;
    };
    if (!requesterMayReleasePane(self, pu.uuid, self.findClientForCtlFd(fd), "orphan_pane")) {
        self.sendBinaryError(fd, "orphan_pane: pane owned by another client");
        return;
    }
    self.ses_state.suspendPane(pu.uuid) catch |e| {
        ses.debugLog("handleBinaryOrphanPane: suspendPane error: {s}", .{@errorName(e)});
        self.sendBinaryError(fd, "orphan_pane: pane not found");
        return;
    };
    self.ses_state.markDirty();
    self.replyOrClose(fd, .ok, &.{});
}

/// A client may kill/orphan a pane it owns, or one that nobody living
/// owns. It must never release a pane attached to another live client:
/// steal notifications are best-effort, so a mux can hold a stale view of
/// a float that has since moved to a different mux — acting on that stale
/// view would destroy the new owner's pane mid-use.
pub fn requesterMayReleasePane(self: *Server, uuid: [32]u8, requester: ?usize, comptime op: []const u8) bool {
    const pane = self.ses_state.store.panes.getPtr(uuid) orelse return true;
    const owner_id = pane.attached_to orelse return true;
    if (requester) |cid| {
        if (owner_id == cid) return true;
    }
    if (self.ses_state.getClient(owner_id) == null) return true;
    core.logging.warnWithSource(
        "ses",
        op ++ ": refused, pane {s} attached to live client {d} (requester {?d})",
        .{ uuid[0..8], owner_id, requester },
        @src(),
    );
    return false;
}

pub fn handleBinaryAdoptPane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.PaneUuid)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "adopt_pane: payload too small for PaneUuid");
        return;
    }
    const pu = wire.readStructTimeout(wire.PaneUuid, fd, server.HANDLER_IO_TIMEOUT_MS) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "adopt_pane request read failed", err);
        self.sendBinaryError(fd, "adopt_pane: read failed");
        return;
    };

    const client_id = self.findClientForCtlFd(fd) orelse {
        self.sendBinaryError(fd, "adopt_pane: client not registered");
        return;
    };

    const pane = self.ses_state.attachPane(pu.uuid, client_id) catch |err| {
        core.logging.logError("ses", "adopt_pane failed to attach pane", err);
        self.sendBinaryError(fd, "adopt_pane: pane not found or already attached");
        return;
    };

    // Adopt into a fresh mux view: request a screen restore, but do not
    // run replay inline. Reconnecting POD VT sockets from the CTL handler
    // can stall attach/reattach; the periodic replay worker will pick this
    // up once the mux VT channel is ready.
    pane.needs_backlog_replay = true;
    ses.debugLog("adopt_pane: queued deferred backlog replay for uuid={s}", .{pu.uuid[0..8]});

    self.ses_state.markDirty();

    var resp = wire.PaneFound{
        .uuid = pane.uuid,
        .pid = pane.child_pid,
        .pane_id = pane.pane_id,
        .socket_path_len = @intCast(pane.pod_socket_path.len),
    };
    self.replyOrCloseWithTrail(fd, .pane_found, std.mem.asBytes(&resp), pane.pod_socket_path);
}

pub fn handleBinaryKillPane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.PaneUuid)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "kill_pane: payload too small for PaneUuid");
        return;
    }
    const pu = wire.readStructTimeout(wire.PaneUuid, fd, server.HANDLER_IO_TIMEOUT_MS) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "kill_pane request read failed", err);
        self.sendBinaryError(fd, "kill_pane: read failed");
        return;
    };
    const client_id = self.findClientForCtlFd(fd);
    const hex_uuid: [32]u8 = std.fmt.bytesToHex(pu.uuid[0..16], .lower);
    ses.debugLog("handleBinaryKillPane: uuid={s} ctl_fd={d}", .{ hex_uuid[0..8], fd });
    if (!requesterMayReleasePane(self, pu.uuid, client_id, "kill_pane")) {
        self.sendBinaryError(fd, "kill_pane: pane owned by another client");
        return;
    }
    self.ses_state.killPane(pu.uuid) catch |e| {
        ses.debugLog("handleBinaryKillPane: killPane error: {s}", .{@errorName(e)});
        self.sendBinaryError(fd, "kill_pane: pane not found");
        return;
    };
    self.ses_state.markDirty();
    if (client_id) |cid| {
        self.pushClientSessionSnapshot(cid);
    }
    ses.debugLog("handleBinaryKillPane: sending .ok response", .{});
    self.replyOrClose(fd, .ok, &.{});
    ses.debugLog("handleBinaryKillPane: done", .{});
}

pub fn handleBinarySetSticky(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.SetSticky)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "set_sticky: payload too small");
        return;
    }
    const ss = wire.readStructTimeout(wire.SetSticky, fd, server.HANDLER_IO_TIMEOUT_MS) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "set_sticky request read failed", err);
        self.sendBinaryError(fd, "set_sticky: read failed");
        return;
    };
    if (ss.pwd_len > buf.len) {
        self.skipBinaryPayload(fd, ss.pwd_len, buf);
        self.sendBinaryError(fd, "set_sticky: pwd too large");
        return;
    }
    if (ss.pwd_len > 0) {
        wire.readExactTimeout(fd, buf[0..ss.pwd_len], server.HANDLER_IO_TIMEOUT_MS) catch |err| {
            self.ctlStreamDesynced(fd, "mid-message read failed");
            core.logging.logError("ses", "set_sticky pwd read failed", err);
            self.sendBinaryError(fd, "set_sticky: pwd read failed");
            return;
        };
    }

    if (self.ses_state.store.panes.getPtr(ss.uuid)) |pane| {
        const new_sticky_pwd = if (ss.pwd_len > 0)
            self.allocator.dupe(u8, buf[0..ss.pwd_len]) catch |err| {
                core.logging.logError("ses", "failed to store sticky pane cwd", err);
                self.sendBinaryError(fd, "set_sticky: cwd allocation failed");
                return;
            }
        else
            null;

        // Store session name for affinity
        const client_id = self.findClientForCtlFd(fd) orelse null;
        const new_sticky_session_name = if (client_id) |cid| blk: {
            if (self.ses_state.getClient(cid)) |client| {
                if (client.session_name) |sn| {
                    break :blk self.allocator.dupe(u8, sn) catch |err| {
                        core.logging.logError("ses", "failed to store sticky pane session name", err);
                        if (new_sticky_pwd) |owned| self.allocator.free(owned);
                        self.sendBinaryError(fd, "set_sticky: session name allocation failed");
                        return;
                    };
                }
            }
            break :blk null;
        } else null;

        // Apply the identity atomically, only after every allocation
        // succeeded: mutating sticky_key before a failable alloc could
        // leave a new-key/old-pwd hybrid that matches neither identity,
        // making the float unreachable by key.
        if (pane.sticky_pwd) |old| self.allocator.free(old);
        if (pane.sticky_session_name) |old_ssn| self.allocator.free(old_ssn);
        pane.sticky_key = if (ss.key != 0) ss.key else null;
        pane.sticky_pwd = new_sticky_pwd;
        pane.sticky_session_name = new_sticky_session_name;

        // set_sticky sets sticky metadata, but must not force attached panes
        // into sticky state. Sticky state is entered on suspend/disown.
        if (pane.sticky_pwd != null and pane.attached_to == null) {
            _ = pane.transitionState(.sticky, "set_sticky command");
        }
        self.ses_state.markDirty();
    }
    self.replyOrClose(fd, .ok, &.{});
}

pub fn handleBinaryGetPaneCwd(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.GetPaneCwd)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "get_pane_cwd: payload too small");
        return;
    }
    const gpc = wire.readStructTimeout(wire.GetPaneCwd, fd, server.HANDLER_IO_TIMEOUT_MS) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "get_pane_cwd request read failed", err);
        self.sendBinaryError(fd, "get_pane_cwd: read failed");
        return;
    };

    if (self.ses_state.getPane(gpc.uuid)) |pane| {
        const cwd = pane.getProcCwd();
        if (cwd) |c| {
            var resp = wire.PaneCwd{ .uuid = gpc.uuid, .cwd_len = @intCast(c.len) };
            self.replyOrCloseWithTrail(fd, .get_pane_cwd, std.mem.asBytes(&resp), c);
            return;
        }
    }
    // No CWD available.
    var resp = wire.PaneCwd{ .uuid = gpc.uuid, .cwd_len = 0 };
    self.replyOrClose(fd, .get_pane_cwd, std.mem.asBytes(&resp));
}
