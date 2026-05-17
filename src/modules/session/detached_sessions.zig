const std = @import("std");
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
