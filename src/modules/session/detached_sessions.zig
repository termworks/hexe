const std = @import("std");
const snapshot_mod = @import("snapshot.zig");
const store_mod = @import("store.zig");

pub fn removeDetachedSession(store: *store_mod.SessionStore, session_id: [16]u8) void {
    if (store.detached_sessions.fetchRemove(session_id)) |kv| {
        for (kv.value.pane_uuids) |uuid| {
            if (store.panes.getPtr(uuid)) |pane| {
                pane.session_id = null;
            }
        }
        var state = kv.value;
        state.deinit();
        store.dirty = true;
    }
}

/// A pane is "parked" only when it is actually listed in a detached session's
/// adoptable pane set. `pane.session_id` alone is NOT sufficient: it is a
/// historical marker that can go stale (e.g. a pane preserved as `.sticky`
/// after its session detached again without it), and treating stale markers
/// as parked makes free sticky panes unclaimable.
pub fn isPaneParked(store: *store_mod.SessionStore, pane: *const store_mod.Pane) bool {
    const sid = pane.session_id orelse return false;
    const detached = store.detached_sessions.getPtr(sid) orelse return false;
    for (detached.pane_uuids) |uuid| {
        if (std.mem.eql(u8, &uuid, &pane.uuid)) return true;
    }
    return false;
}

pub fn removePaneFromDetachedSessions(
    allocator: std.mem.Allocator,
    store: *store_mod.SessionStore,
    pane_uuid: [32]u8,
) void {
    var sessions_to_remove: std.ArrayList([16]u8) = .empty;
    defer sessions_to_remove.deinit(allocator);

    var iter = store.detached_sessions.iterator();
    while (iter.next()) |entry| {
        var found_idx: ?usize = null;
        for (entry.value_ptr.pane_uuids, 0..) |uuid, idx| {
            if (std.mem.eql(u8, &uuid, &pane_uuid)) {
                found_idx = idx;
                break;
            }
        }
        const idx = found_idx orelse continue;

        var pane_uuids = std.ArrayList([32]u8).fromOwnedSlice(entry.value_ptr.pane_uuids);
        _ = pane_uuids.orderedRemove(idx);
        entry.value_ptr.pane_uuids = pane_uuids.toOwnedSlice(entry.value_ptr.allocator) catch {
            entry.value_ptr.pane_uuids = pane_uuids.items;
            continue;
        };
        snapshot_mod.removePaneFromSessionSnapshot(allocator, &entry.value_ptr.session_snapshot, pane_uuid);

        if (entry.value_ptr.pane_uuids.len == 0) {
            sessions_to_remove.append(allocator, entry.key_ptr.*) catch {};
        }
    }

    for (sessions_to_remove.items) |session_id| {
        removeDetachedSession(store, session_id);
    }
    if (store.panes.getPtr(pane_uuid)) |pane| {
        pane.session_id = null;
    }
    store.dirty = true;
}

pub fn listDetachedSessions(
    allocator: std.mem.Allocator,
    store: *const store_mod.SessionStore,
) ![]store_mod.DetachedSession {
    var result: std.ArrayList(store_mod.DetachedSession) = .empty;
    errdefer result.deinit(allocator);

    var iter = store.detached_sessions.valueIterator();
    while (iter.next()) |detached| {
        try result.append(allocator, .{
            .session_id = detached.session_id,
            .session_name = detached.session_snapshot.session_name,
            .base_root = detached.session_snapshot.base_root orelse "",
            .pane_count = detached.pane_uuids.len,
        });
    }

    return result.toOwnedSlice(allocator);
}

pub fn findByNameOrPrefix(store: *const store_mod.SessionStore, id: []const u8) ?[16]u8 {
    // An empty id must never match: `startsWith(hex, "")` is always true, so it
    // would otherwise reattach to an arbitrary (hashmap-order) session.
    if (id.len == 0) return null;

    var iter = store.detached_sessions.iterator();
    while (iter.next()) |entry| {
        const session = entry.value_ptr;
        if (std.mem.eql(u8, session.session_snapshot.session_name, id)) {
            return entry.key_ptr.*;
        }

        const hex_id = std.fmt.bytesToHex(entry.key_ptr.*, .lower);
        if (id.len <= hex_id.len and std.mem.startsWith(u8, &hex_id, id)) {
            return entry.key_ptr.*;
        }
    }
    return null;
}
