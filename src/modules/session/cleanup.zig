const std = @import("std");
const core = @import("core");
const ses = @import("main.zig");
const store_mod = @import("store.zig");

pub const Pane = store_mod.Pane;

pub const KillAllDetachedSessionsResult = struct {
    sessions: usize,
    panes: usize,
};

pub fn getOrphanedPanes(store: *store_mod.SessionStore, allocator: std.mem.Allocator) ![]Pane {
    var result: std.ArrayList(Pane) = .empty;
    errdefer result.deinit(allocator);

    var iter = store.panes.valueIterator();
    while (iter.next()) |pane| {
        if (pane.state == .orphaned) {
            try result.append(allocator, pane.*);
        }
    }

    return result.toOwnedSlice(allocator);
}

pub fn cleanupOrphanedPanes(self: anytype) void {
    const now = std.time.timestamp();
    const timeout_secs = @as(i64, @intCast(self.store.orphan_timeout_hours)) * 3600;

    var to_remove: std.ArrayList([32]u8) = .empty;
    defer to_remove.deinit(self.allocator);

    var iter = self.store.panes.iterator();
    while (iter.next()) |entry| {
        const pane = entry.value_ptr;
        if (pane.state == .orphaned or pane.state == .sticky) {
            if (pane.orphaned_at) |orphaned_time| {
                if (now - orphaned_time > timeout_secs) {
                    to_remove.append(self.allocator, entry.key_ptr.*) catch |err| {
                        core.logging.logError("ses", "failed to collect timed-out orphan pane", err);
                        continue;
                    };
                }
            }
        }
    }

    for (to_remove.items) |uuid| {
        self.killPane(uuid) catch |err| {
            core.logging.logError("ses", "killPane failed in cleanupTimedOut", err);
        };
    }
}

pub fn cleanupExpiredDetachedSessions(self: anytype) void {
    if (self.store.detached_session_ttl_hours == 0) return;

    const now = std.time.timestamp();
    const ttl_secs = @as(i64, @intCast(self.store.detached_session_ttl_hours)) * 3600;

    var to_remove: std.ArrayList([16]u8) = .empty;
    defer to_remove.deinit(self.allocator);

    var iter = self.store.detached_sessions.iterator();
    while (iter.next()) |entry| {
        const session = entry.value_ptr;
        if (now - session.detached_at > ttl_secs) {
            to_remove.append(self.allocator, entry.key_ptr.*) catch |err| {
                core.logging.logError("ses", "failed to collect expired detached session", err);
                continue;
            };
        }
    }

    for (to_remove.items) |session_id| {
        if (self.store.detached_sessions.fetchRemove(session_id)) |kv| {
            var session_state = kv.value;

            for (session_state.pane_uuids) |pane_uuid| {
                self.killPane(pane_uuid) catch |err| {
                    core.logging.logError("ses", "killPane failed in cleanupExpiredSessions", err);
                };
            }

            session_state.deinit();
            self.store.dirty = true;
        }
    }
}

pub fn cleanupDetachedSessions(self: anytype) void {
    var to_remove: std.ArrayList([16]u8) = .empty;
    defer to_remove.deinit(self.allocator);

    var iter = self.store.detached_sessions.iterator();
    while (iter.next()) |entry| {
        const session = entry.value_ptr;
        var has_live_panes = false;

        for (session.pane_uuids) |pane_uuid| {
            if (self.store.panes.get(pane_uuid)) |pane| {
                if (std.c.kill(pane.pod_pid, 0) == 0) {
                    has_live_panes = true;
                    break;
                }
            }
        }

        if (!has_live_panes) {
            to_remove.append(self.allocator, entry.key_ptr.*) catch |err| {
                core.logging.logError("ses", "failed to collect detached session with no live panes", err);
                continue;
            };
            ses.debugLog("cleanup: session {s} has no live panes, removing", .{session.session_snapshot.session_name});
        }
    }

    var name_to_newest = std.StringHashMap(struct { session_id: [16]u8, detached_at: i64 }).init(self.allocator);
    defer name_to_newest.deinit();

    iter = self.store.detached_sessions.iterator();
    while (iter.next()) |entry| {
        const session = entry.value_ptr;
        const name = session.session_snapshot.session_name;

        if (name_to_newest.get(name)) |existing| {
            if (session.detached_at > existing.detached_at) {
                to_remove.append(self.allocator, existing.session_id) catch |err| {
                    core.logging.logError("ses", "failed to collect older duplicate detached session", err);
                    continue;
                };
                name_to_newest.put(name, .{ .session_id = entry.key_ptr.*, .detached_at = session.detached_at }) catch |err| {
                    core.logging.logError("ses", "failed to update detached session duplicate index", err);
                    continue;
                };
            } else {
                to_remove.append(self.allocator, entry.key_ptr.*) catch |err| {
                    core.logging.logError("ses", "failed to collect older duplicate detached session", err);
                    continue;
                };
            }
            ses.debugLog("cleanup: removing older duplicate session '{s}'", .{name});
        } else {
            name_to_newest.put(name, .{ .session_id = entry.key_ptr.*, .detached_at = session.detached_at }) catch |err| {
                core.logging.logError("ses", "failed to index detached session by name", err);
                continue;
            };
        }
    }

    for (to_remove.items) |session_id| {
        if (self.store.detached_sessions.fetchRemove(session_id)) |kv| {
            var session_state = kv.value;

            for (session_state.pane_uuids) |pane_uuid| {
                self.killPane(pane_uuid) catch |err| {
                    core.logging.logError("ses", "killPane failed removing duplicate detached session", err);
                };
            }

            session_state.deinit();
            self.store.dirty = true;
        }
    }

    if (to_remove.items.len > 0) {
        ses.debugLog("cleanup: removed {d} sessions, {d} remaining", .{ to_remove.items.len, self.store.detached_sessions.count() });
    }
}

pub fn checkPaneAlive(store: *store_mod.SessionStore, uuid: [32]u8) bool {
    const pane = store.panes.get(uuid) orelse return false;
    return std.c.kill(pane.pod_pid, 0) == 0;
}

pub fn killDetachedSession(self: anytype, session_id: [16]u8) ?usize {
    const kv = self.store.detached_sessions.fetchRemove(session_id) orelse return null;
    var session_state = kv.value;

    var killed_panes: usize = 0;
    for (session_state.pane_uuids) |pane_uuid| {
        self.killPane(pane_uuid) catch |err| {
            core.logging.logError("ses", "killPane failed in killDetachedSession", err);
            continue;
        };
        killed_panes += 1;
    }

    session_state.deinit();
    self.store.dirty = true;
    return killed_panes;
}

pub fn killAllDetachedSessions(self: anytype) KillAllDetachedSessionsResult {
    var session_ids: std.ArrayList([16]u8) = .empty;
    defer session_ids.deinit(self.allocator);

    var iter = self.store.detached_sessions.keyIterator();
    while (iter.next()) |key| {
        session_ids.append(self.allocator, key.*) catch |err| {
            core.logging.logError("ses", "failed to collect detached session for kill-all", err);
            continue;
        };
    }

    var total_sessions: usize = 0;
    var total_panes: usize = 0;

    for (session_ids.items) |session_id| {
        if (killDetachedSession(self, session_id)) |panes_killed| {
            total_sessions += 1;
            total_panes += panes_killed;
        }
    }

    return .{ .sessions = total_sessions, .panes = total_panes };
}

pub fn killAllOrphanedPanes(self: anytype) usize {
    var uuids_to_kill: std.ArrayList([32]u8) = .empty;
    defer uuids_to_kill.deinit(self.allocator);

    var iter = self.store.panes.iterator();
    while (iter.next()) |entry| {
        const pane = entry.value_ptr;
        if (pane.state == .orphaned or pane.state == .sticky) {
            uuids_to_kill.append(self.allocator, entry.key_ptr.*) catch |err| {
                core.logging.logError("ses", "failed to collect orphaned pane for kill-all", err);
                continue;
            };
        }
    }

    var killed: usize = 0;
    for (uuids_to_kill.items) |uuid| {
        self.killPane(uuid) catch |err| {
            core.logging.logError("ses", "killPane failed in killAllOrphanedPanes", err);
            continue;
        };
        killed += 1;
    }

    if (killed > 0) {
        self.store.dirty = true;
    }

    return killed;
}
