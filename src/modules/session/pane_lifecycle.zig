const std = @import("std");
const posix = std.posix;
const core = @import("core");
const wire = core.wire;
const ses = @import("main.zig");
const detached_sessions = @import("detached_sessions.zig");
const snapshot_mod = @import("snapshot.zig");
const sticky_panes = @import("sticky_panes.zig");
const store_mod = @import("store.zig");

pub fn paneAttachedToClient(store: *store_mod.SessionStore, uuid: [32]u8, client_id: usize) bool {
    const pane = store.panes.get(uuid) orelse return false;
    return pane.state == .attached and pane.attached_to != null and pane.attached_to.? == client_id;
}

fn paneProcessDead(pane: *const store_mod.Pane) bool {
    return !sticky_panes.isPidAlive(pane.child_pid) or !sticky_panes.isPidAlive(pane.pod_pid);
}

fn removePaneFromClientList(client: *store_mod.Client, uuid: [32]u8) void {
    var i: usize = 0;
    while (i < client.pane_uuids.items.len) {
        if (std.mem.eql(u8, &client.pane_uuids.items[i], &uuid)) {
            _ = client.pane_uuids.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn clientSnapshotHasFloat(client: *const store_mod.Client, uuid: [32]u8) bool {
    const snapshot = client.session_snapshot orelse return false;
    if (snapshot.panes.get(uuid)) |pane_state| {
        if (pane_state.kind == .float) return true;
    }
    for (snapshot.floats.items) |float_state| {
        if (std.mem.eql(u8, &float_state.pane_uuid, &uuid)) return true;
    }
    return false;
}

/// The reattach flow (restore + commit register) completes within seconds;
/// well past that, a still-set pending flag means the commit never arrived.
const REATTACH_STEAL_WINDOW_SECS: i64 = 30;

/// Whether an explicit session reattach may reclaim this float from a live
/// owner. Time-boxed: the pending flag survives until commit so that client
/// death can restore panes to the detached session, but the steal privilege
/// must not outlive the reattach flow itself — otherwise a client whose
/// commit register failed keeps a lifetime license to rip floats out of
/// other muxes via its stale snapshot.
fn reattachStealAllowed(client: *const store_mod.Client, uuid: [32]u8) bool {
    if (client.pending_reattach_session_id == null) return false;
    if (std.time.timestamp() - client.pending_reattach_started_at > REATTACH_STEAL_WINDOW_SECS) return false;
    return clientSnapshotHasFloat(client, uuid);
}

fn notifyPaneExitedBestEffort(fd: posix.fd_t, uuid: [32]u8) void {
    var msg: wire.PaneUuid = .{ .uuid = uuid };
    var hdr: wire.ControlHeader = .{
        .msg_type = @intFromEnum(wire.MsgType.pane_exited),
        .request_id = 0,
        .payload_len = @sizeOf(wire.PaneUuid),
    };

    var buf: [@sizeOf(wire.ControlHeader) + @sizeOf(wire.PaneUuid)]u8 = undefined;
    const hdr_bytes = std.mem.asBytes(&hdr);
    const msg_bytes = std.mem.asBytes(&msg);
    @memcpy(buf[0..hdr_bytes.len], hdr_bytes);
    @memcpy(buf[hdr_bytes.len .. hdr_bytes.len + msg_bytes.len], msg_bytes);

    // This write targets a different frontend while SES is handling the new
    // owner's synchronous find_sticky/create_pane request. Never wait here:
    // a slow/wedged old frontend must not stall handoff for every other CWD
    // float. Also avoid writeAllTimeout because a timed-out partial frame would
    // corrupt the old client's control stream.
    var fds = [_]posix.pollfd{
        .{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 },
    };
    const ready = posix.poll(&fds, 0) catch |err| {
        core.logging.logError("ses", "best-effort pane_exited notify poll failed during pane takeover", err);
        return;
    };
    if (ready == 0 or (fds[0].revents & posix.POLL.OUT) == 0) {
        core.logging.warn("ses", "best-effort pane_exited notify skipped: old mux ctl fd not writable", .{});
        return;
    }

    const n = posix.write(fd, &buf) catch |err| {
        core.logging.logError("ses", "best-effort pane_exited notify write failed during pane takeover", err);
        return;
    };
    if (n != buf.len) {
        core.logging.warn("ses", "best-effort pane_exited notify wrote partial frame during pane takeover", .{});
    }
}

fn prunePaneFromClientSnapshot(allocator: std.mem.Allocator, client: *store_mod.Client, pane_uuid: [32]u8) void {
    if (client.session_snapshot) |*snapshot| {
        snapshot_mod.removePaneFromSessionSnapshot(allocator, snapshot, pane_uuid);
    }
}

fn prunePaneFromDetachedSnapshot(
    allocator: std.mem.Allocator,
    store: *store_mod.SessionStore,
    session_id: [16]u8,
    pane_uuid: [32]u8,
) void {
    const detached = store.detached_sessions.getPtr(session_id) orelse {
        core.logging.warn("ses", "prune detached snapshot skipped: session is not detached", .{});
        return;
    };

    var found_idx: ?usize = null;
    for (detached.pane_uuids, 0..) |existing_uuid, idx| {
        if (std.mem.eql(u8, &existing_uuid, &pane_uuid)) {
            found_idx = idx;
            break;
        }
    }

    if (found_idx) |idx| {
        var uuids = std.ArrayList([32]u8).fromOwnedSlice(detached.pane_uuids);
        _ = uuids.orderedRemove(idx);
        detached.pane_uuids = uuids.toOwnedSlice(detached.allocator) catch |err| {
            core.logging.logError("ses", "failed to shrink detached pane UUID list after pruning", err);
            detached.pane_uuids = uuids.items;
            return;
        };
    }

    snapshot_mod.removePaneFromSessionSnapshot(allocator, &detached.session_snapshot, pane_uuid);
}

pub fn stealAttachedPane(self: anytype, uuid: [32]u8, new_client_id: usize) bool {
    const pane = self.store.panes.getPtr(uuid) orelse {
        core.logging.warn("ses", "stealAttachedPane failed: pane UUID is not registered", .{});
        return false;
    };
    const old_client_id = pane.attached_to orelse return true;
    if (old_client_id == new_client_id) return true;

    if (self.getClient(old_client_id)) |old_client| {
        if (old_client.mux_ctl_fd) |ctl_fd| {
            notifyPaneExitedBestEffort(ctl_fd, uuid);
        }

        removePaneFromClientList(old_client, uuid);
    }

    pane.attached_to = null;
    if (pane.sticky_pwd != null and pane.sticky_key != null) {
        _ = pane.transitionState(.sticky, "sticky pane takeover");
    } else {
        _ = pane.transitionState(.orphaned, "pane takeover");
    }
    // A stolen pane is free, not parked: a stale session marker here would
    // make later claims look like cross-session theft and get refused.
    pane.session_id = null;
    pane.orphaned_at = std.time.timestamp();
    self.store.dirty = true;
    return true;
}

pub fn attachPane(self: anytype, uuid: [32]u8, client_id: usize) !*store_mod.Pane {
    var pane = self.store.panes.getPtr(uuid) orelse return error.PaneNotFound;
    const client = self.getClient(client_id) orelse return error.ClientNotFound;

    ses.debugLog("attachPane: uuid={s} state={s} client_id={d}", .{
        uuid[0..8],
        @tagName(pane.state),
        client_id,
    });

    if (pane.state == .attached) {
        if (pane.attached_to) |owner_id| {
            // During explicit session reattach, the detached snapshot is the
            // user's requested restore set. If a float from that exact snapshot
            // is still owned by another live frontend, reclaim that UUID
            // instead of silently dropping the float from the restored session.
            // This is intentionally UUID/snapshot-scoped; generic sticky CWD
            // discovery still goes through find_sticky.
            if (owner_id != client_id) {
                if (reattachStealAllowed(client, uuid)) {
                    if (!stealAttachedPane(self, uuid, client_id)) return error.PaneAlreadyAttached;
                    pane = self.store.panes.getPtr(uuid) orelse return error.PaneNotFound;
                } else {
                    return error.PaneAlreadyAttached;
                }
            } else {
                return pane;
            }
        }

        // Persisted state deliberately does not store clients, so after a SES
        // restart a live pane can come back as `.attached` with no owner. That
        // is not actually attached to any mux; let the new client claim it so
        // every sticky/per-CWD float for the directory is reusable after a
        // daemon restart instead of only the panes that happened to be
        // converted to `.sticky` before persistence.
        ses.debugLog("attachPane: recovering no-owner attached pane uuid={s}", .{uuid[0..8]});
    } else if (pane.attached_to != null and pane.attached_to.? != client_id) {
        if (reattachStealAllowed(client, uuid)) {
            if (!stealAttachedPane(self, uuid, client_id)) return error.PaneAlreadyAttached;
            pane = self.store.panes.getPtr(uuid) orelse return error.PaneNotFound;
        } else {
            // Defensive: if ownership is still set, do not steal silently.
            return error.PaneAlreadyAttached;
        }
    }

    // Add to the client's pane list before mutating pane ownership. If the
    // client is gone, the pane must remain adoptable/orphaned.

    // A pane parked inside a detached session's adoptable pane set belongs to
    // that session: only a client reattaching (or attached to) that exact
    // session may adopt it directly. Cross-session takeover of sticky panes
    // must go through the explicit find_sticky/create_pane claim paths, which
    // unpark the pane via removePaneFromDetachedSessions first. Parked status
    // is membership in pane_uuids — pane.session_id alone is a historical
    // marker that can go stale and must not block free sticky panes.
    if (pane.attached_to == null and detached_sessions.isPaneParked(&self.store, pane)) {
        const sid = pane.session_id.?;
        const allowed = blk: {
            if (client.pending_reattach_session_id) |pending| {
                if (std.mem.eql(u8, &pending, &sid)) break :blk true;
            }
            if (client.session_id) |csid| {
                if (std.mem.eql(u8, &csid, &sid)) break :blk true;
            }
            break :blk false;
        };
        if (!allowed) {
            ses.debugLog("attachPane: refused, uuid={s} parked in another detached session", .{uuid[0..8]});
            return error.PaneParkedInOtherSession;
        }
    }

    try client.appendUuid(uuid);

    // Only request deferred VT reconnect/backlog replay when we currently
    // have no pod VT channel. In the common detach/reattach path SES keeps
    // pod_vt_fd alive, so reconnecting here would unnecessarily replace a
    // healthy stream and can stall old panes during attach.
    pane.needs_backlog_replay = (pane.pod_vt_fd == null);
    if (pane.needs_backlog_replay) {
        ses.debugLog("attachPane: marked for deferred backlog replay", .{});
    } else {
        ses.debugLog("attachPane: pod VT already connected, replay not needed", .{});
    }

    _ = pane.transitionState(.attached, "pane attached to client");
    pane.attached_to = client_id;
    pane.orphaned_at = null;
    self.store.dirty = true;

    ses.debugLog("attachPane: success, pane_id={d}", .{pane.pane_id});
    return pane;
}

pub fn processBacklogReplays(self: anytype) void {
    var stale_panes: std.ArrayList([32]u8) = .empty;
    defer stale_panes.deinit(self.allocator);

    var iter = self.store.panes.iterator();
    while (iter.next()) |entry| {
        const pane = entry.value_ptr;
        if (!pane.needs_backlog_replay) continue;

        if (paneProcessDead(pane)) {
            ses.debugLog("processBacklogReplays: pruning dead pane uuid={s}", .{entry.key_ptr[0..8]});
            stale_panes.append(self.allocator, entry.key_ptr.*) catch |err| {
                core.logging.logError("ses", "failed to collect dead backlog pane for pruning", err);
            };
            continue;
        }

        // Wait until the owning mux VT channel is attached before reconnecting
        // to POD VT. If we reconnect too early, POD can stream backlog before
        // a mux VT fd exists and SES may discard it.
        const owner_id = pane.attached_to orelse {
            ses.debugLog("processBacklogReplays: skip uuid={s} (no owner)", .{entry.key_ptr[0..8]});
            continue;
        };
        const owner = self.getClient(owner_id) orelse {
            ses.debugLog("processBacklogReplays: skip uuid={s} (owner missing)", .{entry.key_ptr[0..8]});
            continue;
        };
        if (owner.mux_vt_fd == null) {
            ses.debugLog("processBacklogReplays: defer uuid={s} (mux VT not ready)", .{entry.key_ptr[0..8]});
            continue;
        }

        ses.debugLog("processBacklogReplays: uuid={s} pane_id={d}", .{
            entry.key_ptr[0..8],
            pane.pane_id,
        });
        if (self.connectPodVt(entry.key_ptr.*, pane.pod_socket_path, pane.pane_id)) {
            pane.needs_backlog_replay = false;
        } else {
            if (paneProcessDead(pane)) {
                ses.debugLog("processBacklogReplays: connect failed for dead pane uuid={s}", .{entry.key_ptr[0..8]});
                stale_panes.append(self.allocator, entry.key_ptr.*) catch |err| {
                    core.logging.logError("ses", "failed to collect dead backlog pane after connect failure", err);
                };
                continue;
            }

            // Keep the flag set so periodic retries can reconnect once the pod
            // VT endpoint is ready.
            ses.debugLog("processBacklogReplays: deferred retry uuid={s}", .{entry.key_ptr[0..8]});
        }
    }

    for (stale_panes.items) |pane_uuid| {
        // The owning mux only learns about pane death from an explicit
        // pane_exited; pruning silently would leave it rendering a frozen
        // pane forever (this path runs when a pod dies between a VT drop
        // classified as transient and the reconnect attempt).
        if (self.store.panes.getPtr(pane_uuid)) |pane| {
            if (pane.attached_to) |owner_id| {
                if (self.getClient(owner_id)) |owner| {
                    if (owner.mux_ctl_fd) |ctl_fd| notifyPaneExitedBestEffort(ctl_fd, pane_uuid);
                }
            }
        }
        self.killPane(pane_uuid) catch |err| {
            core.logging.logError("ses", "killPane failed in processBacklogReplays", err);
        };
    }
}

pub fn suspendPane(self: anytype, uuid: [32]u8) !void {
    const pane = self.store.panes.getPtr(uuid) orelse return error.PaneNotFound;

    if (pane.attached_to) |client_id| {
        if (self.getClient(client_id)) |client| {
            removePaneFromClientList(client, uuid);
            prunePaneFromClientSnapshot(self.allocator, client, uuid);
        }
    }

    if (pane.sticky_pwd != null and pane.sticky_key != null) {
        _ = pane.transitionState(.sticky, "suspend with sticky pwd");
        ses.debugLog("suspendPane: {s} pwd={s}, key={c}", .{ uuid[0..8], pane.sticky_pwd.?, pane.sticky_key.? });
    } else {
        _ = pane.transitionState(.orphaned, "suspend without sticky pwd");
        ses.debugLog("suspendPane: {s} pwd={any}, key={any}", .{ uuid[0..8], pane.sticky_pwd != null, pane.sticky_key != null });
    }
    pane.attached_to = null;
    // Suspended/disowned panes are free, not parked in any detached session.
    pane.session_id = null;
    pane.orphaned_at = std.time.timestamp();
    self.store.dirty = true;
}

pub fn killPane(self: anytype, uuid: [32]u8) !void {
    const hex_uuid: [32]u8 = std.fmt.bytesToHex(uuid[0..16], .lower);
    var pane = self.store.panes.fetchRemove(uuid) orelse {
        ses.debugLog("killPane: {s} NOT FOUND", .{hex_uuid[0..8]});
        return error.PaneNotFound;
    };
    self.store.dirty = true;
    ses.debugLog("killPane: {s} pane_id={d} pod_pid={d} pod_vt_fd={?d} state={s}", .{
        hex_uuid[0..8],
        pane.value.pane_id,
        pane.value.pod_pid,
        pane.value.pod_vt_fd,
        @tagName(pane.value.state),
    });

    if (pane.value.attached_to) |client_id| {
        if (self.getClient(client_id)) |client| {
            removePaneFromClientList(client, uuid);
            prunePaneFromClientSnapshot(self.allocator, client, uuid);
        }
    } else if (pane.value.session_id) |session_id| {
        prunePaneFromDetachedSnapshot(self.allocator, &self.store, session_id, uuid);
    }

    if (pane.value.pod_vt_fd) |vt_fd| {
        ses.debugLog("killPane: {s} closing pod_vt_fd={d}, removing from routing tables", .{ hex_uuid[0..8], vt_fd });
        _ = self.store.pod_vt_to_pane_id.remove(vt_fd);
        _ = self.store.pane_id_to_pod_vt.remove(pane.value.pane_id);
        _ = self.store.pane_id_to_uuid.remove(pane.value.pane_id);
        self.polling.pending_remove_poll_fds.append(self.allocator, vt_fd) catch |err| {
            core.logging.logError("ses", "failed to queue killed POD VT fd removal", err);
        };
        self.store.noteClosedFd(vt_fd);
        posix.close(vt_fd);
    } else {
        ses.debugLog("killPane: {s} pod_vt_fd=null, removing pane_id from routing", .{hex_uuid[0..8]});
        _ = self.store.pane_id_to_pod_vt.remove(pane.value.pane_id);
    }

    // Never signal a pid that is no longer our pod: after pid reuse it may
    // belong to an unrelated process (killing a ghost pane must not SIGTERM
    // an innocent pid). A wedged real pod still matches by cmdline uuid and
    // is signaled; a dead pod simply has nothing to signal.
    if (sticky_panes.podPidMatchesPane(pane.value.pod_pid, uuid)) {
        ses.debugLog("killPane: {s} sending SIGTERM to pid={d}", .{ hex_uuid[0..8], pane.value.pod_pid });
        _ = std.c.kill(pane.value.pod_pid, std.c.SIG.TERM);
    } else {
        ses.debugLog("killPane: {s} pid={d} is not our pod (dead or reused); not signaling", .{ hex_uuid[0..8], pane.value.pod_pid });
    }

    pane.value.deinit();
    ses.debugLog("killPane: {s} done", .{hex_uuid[0..8]});
}
