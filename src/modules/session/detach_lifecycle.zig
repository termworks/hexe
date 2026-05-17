const std = @import("std");
const posix = std.posix;
const core = @import("core");
const wire = core.wire;
const ses = @import("main.zig");
const client_panes = @import("client_panes.zig");
const snapshot_mod = @import("snapshot.zig");
const sticky_panes = @import("sticky_panes.zig");
const store_mod = @import("store.zig");

const session_model = core.session_model;

pub const ReattachResult = struct {
    session_snapshot: *const session_model.SessionSnapshot,
    pane_uuids: [][32]u8,
};

fn buildDetachedSessionSnapshot(
    self: anytype,
    client: *const store_mod.Client,
    session_id: [16]u8,
) !session_model.SessionSnapshot {
    if (client.session_snapshot) |snapshot| {
        return snapshot.clone(self.allocator);
    }

    const session_name = client.session_name orelse "unknown";
    const hex_id: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
    return session_model.SessionSnapshot.initMinimal(self.allocator, hex_id, session_name);
}

fn paneProcessDead(pane: *const store_mod.Pane) bool {
    return !sticky_panes.isPidAlive(pane.child_pid) or !sticky_panes.isPidAlive(pane.pod_pid);
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

fn pruneDetachedSessionPanes(self: anytype, session_id: [16]u8) void {
    const detached = self.store.detached_sessions.getPtr(session_id) orelse {
        core.logging.warn("ses", "detached pane prune skipped: session is not detached", .{});
        return;
    };

    var stale_panes: std.ArrayList([32]u8) = .empty;
    defer stale_panes.deinit(self.allocator);

    for (detached.pane_uuids) |pane_uuid| {
        const pane = self.store.panes.getPtr(pane_uuid) orelse {
            stale_panes.append(self.allocator, pane_uuid) catch |err| {
                core.logging.logError("ses", "failed to collect missing detached pane for pruning", err);
            };
            continue;
        };

        if (paneProcessDead(pane)) {
            stale_panes.append(self.allocator, pane_uuid) catch |err| {
                core.logging.logError("ses", "failed to collect dead detached pane for pruning", err);
            };
        }
    }

    for (stale_panes.items) |pane_uuid| {
        ses.debugLog("pruneDetachedSessionPanes: dropping stale pane uuid={s}", .{pane_uuid[0..8]});
        if (self.store.panes.contains(pane_uuid)) {
            self.killPane(pane_uuid) catch |err| {
                core.logging.logError("ses", "killPane failed in pruneDetachedSessionPanes", err);
            };
        } else {
            prunePaneFromDetachedSnapshot(self.allocator, &self.store, session_id, pane_uuid);
        }
    }
}

pub fn detachSessionDirect(self: anytype, client: *store_mod.Client, session_id: [16]u8) bool {
    const hex_id: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
    ses.debugLog("detachSessionDirect: session={s} name={s}", .{ hex_id[0..8], client.session_name orelse "null" });

    self.persistence.txlog.write(.detach_start, session_id, &hex_id) catch |err| {
        core.logging.logError("ses", "failed to write detach_start txlog entry", err);
    };

    var pane_uuids_list: std.ArrayList([32]u8) = .empty;

    client_panes.collectDetachPaneUuids(self.allocator, &self.store, client, &pane_uuids_list) catch {
        ses.debugLog("detachSessionDirect: failed to collect pane UUIDs", .{});
        pane_uuids_list.deinit(self.allocator);
        return false;
    };

    var session_snapshot = buildDetachedSessionSnapshot(self, client, session_id) catch {
        ses.debugLog("detachSessionDirect: failed to build session_snapshot", .{});
        pane_uuids_list.deinit(self.allocator);
        return false;
    };
    client_panes.pruneSnapshotToPaneList(self.allocator, &session_snapshot, pane_uuids_list.items) catch |err| {
        core.logging.logError("ses", "failed to prune detached session snapshot", err);
        pane_uuids_list.deinit(self.allocator);
        session_snapshot.deinit();
        return false;
    };

    const owned_uuids = pane_uuids_list.toOwnedSlice(self.allocator) catch {
        ses.debugLog("detachSessionDirect: failed to toOwnedSlice", .{});
        session_snapshot.deinit();
        return false;
    };

    const detached_state = store_mod.DetachedSessionState{
        .session_id = session_id,
        .session_snapshot = session_snapshot,
        .pane_uuids = owned_uuids,
        .detached_at = std.time.timestamp(),
        .allocator = self.allocator,
    };

    const replaced = self.store.detached_sessions.fetchPut(session_id, detached_state) catch {
        ses.debugLog("detachSessionDirect: failed to put detached_state", .{});
        var snapshot = session_snapshot;
        snapshot.deinit();
        self.allocator.free(owned_uuids);
        return false;
    };
    if (replaced) |old| {
        var old_state = old.value;
        old_state.deinit();
        ses.debugLog("detachSessionDirect: replaced existing detached session", .{});
    }

    for (owned_uuids) |uuid| {
        if (self.store.panes.getPtr(uuid)) |pane| {
            _ = pane.transitionState(.detached, "session detach");
            pane.session_id = session_id;
            pane.attached_to = null;

            if (pane.pod_vt_fd) |vt_fd| {
                _ = self.store.pod_vt_to_pane_id.remove(vt_fd);
                _ = self.store.pane_id_to_pod_vt.remove(pane.pane_id);
                self.polling.pending_remove_poll_fds.append(self.allocator, vt_fd) catch |err| {
                    core.logging.logError("ses", "failed to queue detached POD VT fd removal", err);
                };
                posix.close(vt_fd);
                pane.pod_vt_fd = null;
            }
        }
    }
    ses.debugLog("detachSessionDirect: marked {d} panes as detached", .{owned_uuids.len});
    ses.debugLog("detachSessionDirect: success, detached_sessions.count={d}", .{self.store.detached_sessions.count()});
    self.store.dirty = true;

    self.persistence.txlog.write(.detach_commit, session_id, &hex_id) catch |err| {
        core.logging.logError("ses", "failed to write detach_commit txlog entry", err);
    };
    return true;
}

pub fn detachSession(self: anytype, client_id: usize, session_id: [16]u8) bool {
    var client_index: ?usize = null;
    var pane_uuids_list: std.ArrayList([32]u8) = .empty;
    var detached_snapshot: ?session_model.SessionSnapshot = null;

    for (self.store.clients.items, 0..) |*client, i| {
        if (client.id == client_id) {
            detached_snapshot = buildDetachedSessionSnapshot(self, client, session_id) catch {
                ses.debugLog("detachSession: failed to build session_snapshot", .{});
                return false;
            };

            client_panes.collectDetachPaneUuids(self.allocator, &self.store, client, &pane_uuids_list) catch {
                ses.debugLog("detachSession: failed to collect pane UUIDs", .{});
                var snapshot = detached_snapshot.?;
                snapshot.deinit();
                detached_snapshot = null;
                return false;
            };
            if (detached_snapshot) |*snapshot| {
                client_panes.pruneSnapshotToPaneList(self.allocator, snapshot, pane_uuids_list.items) catch |err| {
                    core.logging.logError("ses", "failed to prune detached session snapshot", err);
                    pane_uuids_list.deinit(self.allocator);
                    var owned_snapshot = snapshot.*;
                    owned_snapshot.deinit();
                    detached_snapshot = null;
                    return false;
                };
            }

            client_index = i;
            break;
        }
    }

    if (client_index) |idx| {
        const session_snapshot = detached_snapshot orelse {
            ses.debugLog("detachSession: missing detached snapshot", .{});
            pane_uuids_list.deinit(self.allocator);
            return false;
        };
        errdefer {
            var snapshot = session_snapshot;
            snapshot.deinit();
        }

        const owned_uuids = pane_uuids_list.toOwnedSlice(self.allocator) catch {
            ses.debugLog("detachSession: failed to toOwnedSlice", .{});
            var snapshot = session_snapshot;
            snapshot.deinit();
            return false;
        };

        const detached_state = store_mod.DetachedSessionState{
            .session_id = session_id,
            .session_snapshot = session_snapshot,
            .pane_uuids = owned_uuids,
            .detached_at = std.time.timestamp(),
            .allocator = self.allocator,
        };

        const replaced = self.store.detached_sessions.fetchPut(session_id, detached_state) catch {
            ses.debugLog("detachSession: failed to put detached_state", .{});
            var snapshot = session_snapshot;
            snapshot.deinit();
            self.allocator.free(owned_uuids);
            return false;
        };
        if (replaced) |old| {
            var old_state = old.value;
            old_state.deinit();
        }

        for (owned_uuids) |uuid| {
            if (self.store.panes.getPtr(uuid)) |pane| {
                _ = pane.transitionState(.detached, "atomic detach");
                pane.session_id = session_id;
                pane.attached_to = null;

                if (pane.pod_vt_fd) |vt_fd| {
                    _ = self.store.pod_vt_to_pane_id.remove(vt_fd);
                    _ = self.store.pane_id_to_pod_vt.remove(pane.pane_id);
                    self.polling.pending_remove_poll_fds.append(self.allocator, vt_fd) catch |err| {
                        core.logging.logError("ses", "failed to queue atomic detach POD VT fd removal", err);
                    };
                    posix.close(vt_fd);
                    pane.pod_vt_fd = null;
                }
            }
        }

        var client = &self.store.clients.items[idx];
        client.deinit();
        _ = self.store.clients.orderedRemove(idx);
        self.store.dirty = true;

        return true;
    } else {
        pane_uuids_list.deinit(self.allocator);
    }
    return false;
}

pub fn reattachSession(self: anytype, session_id: [16]u8, client_id: usize) !?ReattachResult {
    pruneDetachedSessionPanes(self, session_id);

    const detached_state = self.store.detached_sessions.getPtr(session_id) orelse return null;

    if (self.getClient(client_id)) |client| {
        client.updateSessionSnapshot(try detached_state.session_snapshot.clone(self.allocator));
        client.pending_reattach_session_id = session_id;
    }

    return .{
        .session_snapshot = &detached_state.session_snapshot,
        .pane_uuids = detached_state.pane_uuids,
    };
}

pub fn cancelPendingReattach(self: anytype, session_id: [16]u8, client_id: usize) bool {
    const detached_state = self.store.detached_sessions.getPtr(session_id) orelse {
        ses.debugLog("cancelPendingReattach: detached session missing", .{});
        return false;
    };

    ses.debugLog("cancelPendingReattach: session={s} panes={d} client_id={d}", .{
        std.fmt.bytesToHex(&session_id, .lower)[0..8],
        detached_state.pane_uuids.len,
        client_id,
    });

    for (detached_state.pane_uuids) |uuid| {
        const pane = self.store.panes.getPtr(uuid) orelse continue;
        if (pane.attached_to) |owner_id| {
            if (owner_id != client_id) {
                ses.debugLog("cancelPendingReattach: skip uuid={s}, owned by client_id={d}", .{ uuid[0..8], owner_id });
                continue;
            }
        }

        _ = pane.transitionState(.detached, "cancel pending reattach");
        pane.session_id = session_id;
        pane.attached_to = null;
        pane.needs_backlog_replay = false;

        if (pane.pod_vt_fd) |vt_fd| {
            _ = self.store.pod_vt_to_pane_id.remove(vt_fd);
            _ = self.store.pane_id_to_pod_vt.remove(pane.pane_id);
            self.polling.pending_remove_poll_fds.append(self.allocator, vt_fd) catch |err| {
                core.logging.logError("ses", "failed to queue canceled reattach POD VT fd removal", err);
            };
            posix.close(vt_fd);
            pane.pod_vt_fd = null;
        }
    }

    if (self.getClient(client_id)) |client| {
        if (client.pending_reattach_session_id) |pending| {
            if (std.mem.eql(u8, &pending, &session_id)) {
                client.pending_reattach_session_id = null;
            }
        }
    }

    self.store.dirty = true;
    return true;
}

pub fn forceDetachAttachedSession(self: anytype, session_id: [16]u8) bool {
    var owner_index: ?usize = null;

    for (self.store.clients.items, 0..) |client, i| {
        if (client.session_id) |sid| {
            if (std.mem.eql(u8, &sid, &session_id)) {
                owner_index = i;
                break;
            }
        }
    }

    const idx = owner_index orelse {
        core.logging.warn("ses", "force-detach skipped: no attached owner for requested session", .{});
        return false;
    };
    const owner = &self.store.clients.items[idx];

    if (!detachSessionDirect(self, owner, session_id)) {
        return false;
    }

    if (owner.mux_ctl_fd) |mfd| {
        wire.writeControl(mfd, .session_stolen, &.{}) catch |err| {
            core.logging.logError("ses", "failed to notify owner session was stolen", err);
        };
    }

    store_mod.closeClientFds(owner);
    owner.deinit();
    _ = self.store.clients.orderedRemove(idx);

    self.store.dirty = true;
    return true;
}
