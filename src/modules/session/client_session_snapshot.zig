const std = @import("std");
const core = @import("core");

const session_model = core.session_model;
const store_mod = @import("store.zig");

pub fn ensureClientSessionSnapshot(
    allocator: std.mem.Allocator,
    client: *store_mod.Client,
) !*session_model.SessionSnapshot {
    if (client.session_snapshot == null) {
        const session_id = client.session_id orelse [_]u8{'0'} ** 16;
        const hex_id: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
        const session_name = client.session_name orelse "session";
        client.session_snapshot = try session_model.SessionSnapshot.initMinimal(allocator, hex_id, session_name);
        if (client.base_root) |base_root| {
            client.session_snapshot.?.base_root = try allocator.dupe(u8, base_root);
        }
    }
    return &client.session_snapshot.?;
}

pub fn updateFocus(
    self: anytype,
    client_id: usize,
    pane_uuid: [32]u8,
    active_tab_hint: ?u16,
    is_focused: bool,
) void {
    if (!is_focused) return;

    const client = self.getClient(client_id) orelse {
        core.logging.warn("ses", "client snapshot focus update skipped: client {d} is not registered", .{client_id});
        return;
    };
    const snapshot = ensureClientSessionSnapshot(self.allocator, client) catch |err| {
        core.logging.logError("ses", "failed to ensure client session snapshot for focus update", err);
        return;
    };
    const pane = snapshot.panes.get(pane_uuid) orelse {
        core.logging.warn("ses", "client snapshot focus update skipped: pane is not in snapshot", .{});
        return;
    };

    var active_tab: ?usize = null;
    if (active_tab_hint) |hint| {
        const idx: usize = @intCast(hint);
        if (idx < snapshot.tabs.items.len) {
            active_tab = idx;
        }
    }
    if (active_tab == null) {
        active_tab = pane.parent_tab;
    }

    snapshot.focused_pane_uuid = pane_uuid;
    if (active_tab) |idx| {
        snapshot.active_tab = idx;
    }

    switch (pane.kind) {
        .split => {
            snapshot.active_float_uuid = null;
            if (active_tab) |idx| {
                snapshot.tabs.items[idx].focused_pane_uuid = pane_uuid;
            } else if (pane.parent_tab) |idx| {
                if (idx < snapshot.tabs.items.len) {
                    snapshot.tabs.items[idx].focused_pane_uuid = pane_uuid;
                }
            }
        },
        .float => {
            snapshot.active_float_uuid = pane_uuid;
        },
    }
    // Attached-session crash recovery persists this snapshot: without a
    // dirty mark the periodic save skips it and a crash restores stale layout.
    self.store.markDirty();
}

pub fn addTab(
    self: anytype,
    client_id: usize,
    tab_uuid: [32]u8,
    pane_uuid: [32]u8,
    tab_index: usize,
    name: []const u8,
) !void {
    const client = self.getClient(client_id) orelse {
        core.logging.warn("ses", "client snapshot tab add failed: client {d} is not registered", .{client_id});
        return error.InvalidClient;
    };
    const snapshot = try ensureClientSessionSnapshot(self.allocator, client);
    const insert_index = @min(tab_index, snapshot.tabs.items.len);

    var pane_iter = snapshot.panes.iterator();
    while (pane_iter.next()) |entry| {
        if (entry.value_ptr.parent_tab) |parent| {
            if (parent >= insert_index) {
                entry.value_ptr.parent_tab = parent + 1;
            }
        }
    }
    for (snapshot.floats.items) |*float_state| {
        if (float_state.parent_tab) |parent| {
            if (parent >= insert_index) {
                float_state.parent_tab = parent + 1;
            }
        }
    }

    const root = try snapshot.allocator.create(session_model.SessionLayoutNode);
    errdefer snapshot.allocator.destroy(root);
    root.* = .{ .pane = pane_uuid };

    var tab = session_model.SessionTab{
        .uuid = tab_uuid,
        .name = try snapshot.allocator.dupe(u8, name),
        .root = root,
        .focused_pane_uuid = pane_uuid,
        .allocator = snapshot.allocator,
    };
    errdefer tab.deinit();

    try snapshot.tabs.insert(snapshot.allocator, insert_index, tab);
    try snapshot.panes.put(pane_uuid, .{
        .uuid = pane_uuid,
        .kind = .split,
        .parent_tab = insert_index,
    });
    snapshot.tab_counter +%= 1;
    snapshot.active_tab = insert_index;
    snapshot.active_float_uuid = null;
    snapshot.focused_pane_uuid = pane_uuid;
    self.store.markDirty();
}

pub fn renameTab(
    self: anytype,
    client_id: usize,
    tab_uuid: [32]u8,
    name: []const u8,
) void {
    const client = self.getClient(client_id) orelse {
        core.logging.warn("ses", "client snapshot tab rename skipped: client {d} is not registered", .{client_id});
        return;
    };
    const snapshot = ensureClientSessionSnapshot(self.allocator, client) catch |err| {
        core.logging.logError("ses", "failed to ensure client session snapshot for tab rename", err);
        return;
    };
    for (snapshot.tabs.items) |*tab| {
        if (std.mem.eql(u8, &tab.uuid, &tab_uuid)) {
            const owned = snapshot.allocator.dupe(u8, name) catch |err| {
                core.logging.logError("ses", "failed to allocate renamed tab name", err);
                return;
            };
            snapshot.allocator.free(tab.name);
            tab.name = owned;
            self.store.markDirty();
            return;
        }
    }
    core.logging.warn("ses", "client snapshot tab rename skipped: tab UUID is not in snapshot", .{});
}

pub fn removeTab(
    self: anytype,
    client_id: usize,
    tab_uuid: [32]u8,
    active_tab_hint: ?u16,
) void {
    const client = self.getClient(client_id) orelse {
        core.logging.warn("ses", "client snapshot tab removal skipped: client {d} is not registered", .{client_id});
        return;
    };
    const snapshot = ensureClientSessionSnapshot(self.allocator, client) catch |err| {
        core.logging.logError("ses", "failed to ensure client session snapshot for tab removal", err);
        return;
    };

    var removed_index: ?usize = null;
    for (snapshot.tabs.items, 0..) |tab, idx| {
        if (std.mem.eql(u8, &tab.uuid, &tab_uuid)) {
            removed_index = idx;
            break;
        }
    }
    const idx = removed_index orelse {
        core.logging.warn("ses", "client snapshot tab removal skipped: tab UUID is not in snapshot", .{});
        return;
    };

    var removed = snapshot.tabs.orderedRemove(idx);
    removed.deinit();
    self.store.markDirty();

    var remove_pane_uuids: std.ArrayList([32]u8) = .empty;
    defer remove_pane_uuids.deinit(self.allocator);

    var pane_iter = snapshot.panes.iterator();
    while (pane_iter.next()) |entry| {
        if (entry.value_ptr.parent_tab) |parent| {
            if (parent == idx) {
                remove_pane_uuids.append(self.allocator, entry.key_ptr.*) catch |err| {
                    core.logging.logError("ses", "failed to collect pane for tab removal", err);
                };
            } else if (parent > idx) {
                entry.value_ptr.parent_tab = parent - 1;
            }
        }
    }
    for (remove_pane_uuids.items) |pane_uuid| {
        _ = snapshot.panes.remove(pane_uuid);
    }

    var float_index: usize = 0;
    while (float_index < snapshot.floats.items.len) {
        const float_state = &snapshot.floats.items[float_index];
        if (float_state.parent_tab) |parent| {
            if (parent == idx) {
                _ = snapshot.floats.orderedRemove(float_index);
                continue;
            } else if (parent > idx) {
                float_state.parent_tab = parent - 1;
            }
        }
        float_index += 1;
    }

    if (snapshot.tabs.items.len == 0) {
        snapshot.active_tab = 0;
        snapshot.active_float_uuid = null;
        snapshot.focused_pane_uuid = null;
        return;
    }

    if (active_tab_hint) |hint| {
        const new_active: usize = @intCast(hint);
        snapshot.active_tab = @min(new_active, snapshot.tabs.items.len - 1);
    } else if (snapshot.active_tab >= snapshot.tabs.items.len) {
        snapshot.active_tab = snapshot.tabs.items.len - 1;
    }

    if (snapshot.active_float_uuid) |active_float_uuid| {
        if (!snapshot.panes.contains(active_float_uuid)) {
            snapshot.active_float_uuid = null;
        }
    }
    snapshot.focused_pane_uuid = if (snapshot.active_float_uuid) |float_uuid|
        float_uuid
    else
        snapshot.tabs.items[snapshot.active_tab].focused_pane_uuid;
}

fn findSnapshotTabIndex(snapshot: *session_model.SessionSnapshot, tab_uuid: [32]u8) ?usize {
    for (snapshot.tabs.items, 0..) |tab, idx| {
        if (std.mem.eql(u8, tab.uuid[0..], tab_uuid[0..])) return idx;
    }
    return null;
}

fn setSnapshotActiveTab(snapshot: *session_model.SessionSnapshot, active_tab: u16) void {
    if (snapshot.tabs.items.len == 0) {
        snapshot.active_tab = 0;
        return;
    }
    snapshot.active_tab = @min(@as(usize, @intCast(active_tab)), snapshot.tabs.items.len - 1);
}

fn setSnapshotSplitFocus(
    snapshot: *session_model.SessionSnapshot,
    tab_index: usize,
    focused_pane_uuid: ?[32]u8,
) void {
    if (tab_index < snapshot.tabs.items.len) {
        snapshot.tabs.items[tab_index].focused_pane_uuid = focused_pane_uuid;
    }
    snapshot.active_float_uuid = null;
    snapshot.focused_pane_uuid = focused_pane_uuid;
}

pub fn splitPane(
    self: anytype,
    client_id: usize,
    tab_uuid: [32]u8,
    source_pane_uuid: [32]u8,
    new_pane_uuid: [32]u8,
    active_tab: u16,
    focused_pane_uuid: ?[32]u8,
    dir: session_model.SessionSplitDir,
) !void {
    const client = self.getClient(client_id) orelse {
        core.logging.warn("ses", "client snapshot split-pane failed: client {d} is not registered", .{client_id});
        return error.InvalidClient;
    };
    const snapshot = try ensureClientSessionSnapshot(self.allocator, client);
    const tab_index = findSnapshotTabIndex(snapshot, tab_uuid) orelse return error.InvalidLayout;
    const root = snapshot.tabs.items[tab_index].root orelse return error.InvalidLayout;

    if (!try session_model.splitPaneInLayout(
        snapshot.allocator,
        root,
        source_pane_uuid,
        new_pane_uuid,
        dir,
    )) {
        return error.InvalidLayout;
    }

    try snapshot.panes.put(new_pane_uuid, .{
        .uuid = new_pane_uuid,
        .kind = .split,
        .parent_tab = tab_index,
    });

    setSnapshotActiveTab(snapshot, active_tab);
    setSnapshotSplitFocus(snapshot, tab_index, focused_pane_uuid);
    self.store.markDirty();
}

pub fn replaceSplitPane(
    self: anytype,
    client_id: usize,
    tab_uuid: [32]u8,
    old_pane_uuid: [32]u8,
    new_pane_uuid: [32]u8,
    active_tab: u16,
    focused_pane_uuid: ?[32]u8,
) !void {
    const client = self.getClient(client_id) orelse {
        core.logging.warn("ses", "client snapshot split-pane replacement failed: client {d} is not registered", .{client_id});
        return error.InvalidClient;
    };
    const snapshot = try ensureClientSessionSnapshot(self.allocator, client);
    const tab_index = findSnapshotTabIndex(snapshot, tab_uuid) orelse return error.InvalidLayout;
    const root = snapshot.tabs.items[tab_index].root orelse return error.InvalidLayout;

    if (!session_model.replacePaneUuidInLayout(root, old_pane_uuid, new_pane_uuid)) {
        return error.InvalidLayout;
    }

    var new_pane_state = snapshot.panes.get(old_pane_uuid) orelse session_model.SessionPane{
        .uuid = new_pane_uuid,
        .kind = .split,
        .parent_tab = tab_index,
    };
    _ = snapshot.panes.remove(old_pane_uuid);
    new_pane_state.uuid = new_pane_uuid;
    new_pane_state.kind = .split;
    new_pane_state.parent_tab = tab_index;
    try snapshot.panes.put(new_pane_uuid, new_pane_state);

    setSnapshotActiveTab(snapshot, active_tab);
    setSnapshotSplitFocus(snapshot, tab_index, focused_pane_uuid);
    self.store.markDirty();
}

pub fn setSplitRatio(
    self: anytype,
    client_id: usize,
    tab_uuid: [32]u8,
    active_tab: u16,
    first_anchor_uuid: [32]u8,
    second_anchor_uuid: [32]u8,
    ratio: f32,
) !void {
    const client = self.getClient(client_id) orelse {
        core.logging.warn("ses", "client snapshot split-ratio update failed: client {d} is not registered", .{client_id});
        return error.InvalidClient;
    };
    const snapshot = try ensureClientSessionSnapshot(self.allocator, client);
    const tab_index = findSnapshotTabIndex(snapshot, tab_uuid) orelse return error.InvalidLayout;
    const root = snapshot.tabs.items[tab_index].root orelse return error.InvalidLayout;

    if (!session_model.setSplitRatioByAnchors(root, first_anchor_uuid, second_anchor_uuid, ratio)) {
        return error.InvalidLayout;
    }

    setSnapshotActiveTab(snapshot, active_tab);
    self.store.markDirty();
}

pub fn syncFloat(
    self: anytype,
    client_id: usize,
    pane_uuid: [32]u8,
    active_tab_hint: ?u16,
    parent_tab_hint: ?u16,
    visible: bool,
    tab_visible: u64,
    sticky: bool,
    is_pwd: bool,
    float_key: u8,
    width_pct: u8,
    height_pct: u8,
    pos_x_pct: u8,
    pos_y_pct: u8,
    pad_x: u8,
    pad_y: u8,
    active: bool,
) !void {
    const client = self.getClient(client_id) orelse {
        core.logging.warn("ses", "client snapshot float sync failed: client {d} is not registered", .{client_id});
        return error.InvalidClient;
    };
    const snapshot = try ensureClientSessionSnapshot(self.allocator, client);

    const parent_tab: ?usize = if (parent_tab_hint) |hint| @intCast(hint) else null;
    try snapshot.panes.put(pane_uuid, .{
        .uuid = pane_uuid,
        .kind = .float,
        .parent_tab = parent_tab,
        .sticky = sticky,
        .is_pwd = is_pwd,
        .float_key = float_key,
    });

    const float_state = session_model.SessionFloat{
        .pane_uuid = pane_uuid,
        .parent_tab = parent_tab,
        .visible = visible,
        .tab_visible = tab_visible,
        .sticky = sticky,
        .is_pwd = is_pwd,
        .float_key = float_key,
        .width_pct = width_pct,
        .height_pct = height_pct,
        .pos_x_pct = pos_x_pct,
        .pos_y_pct = pos_y_pct,
        .pad_x = pad_x,
        .pad_y = pad_y,
    };

    for (snapshot.floats.items) |*existing| {
        if (std.mem.eql(u8, &existing.pane_uuid, &pane_uuid)) {
            existing.* = float_state;
            break;
        }
    } else {
        try snapshot.floats.append(snapshot.allocator, float_state);
    }

    if (active) {
        if (active_tab_hint) |hint| {
            const tab_idx: usize = @intCast(hint);
            if (tab_idx < snapshot.tabs.items.len) {
                snapshot.active_tab = tab_idx;
            }
        }
        snapshot.active_float_uuid = pane_uuid;
        snapshot.focused_pane_uuid = pane_uuid;
    } else if (!visible) {
        if (snapshot.active_float_uuid) |active_float_uuid| {
            if (std.mem.eql(u8, &active_float_uuid, &pane_uuid)) {
                snapshot.active_float_uuid = null;
                if (snapshot.active_tab < snapshot.tabs.items.len) {
                    snapshot.focused_pane_uuid = snapshot.tabs.items[snapshot.active_tab].focused_pane_uuid;
                }
            }
        }
    }
    self.store.markDirty();
}

pub fn removeFloat(self: anytype, client_id: usize, pane_uuid: [32]u8) void {
    const client = self.getClient(client_id) orelse {
        core.logging.warn("ses", "client snapshot float removal skipped: client {d} is not registered", .{client_id});
        return;
    };
    const snapshot = ensureClientSessionSnapshot(self.allocator, client) catch |err| {
        core.logging.logError("ses", "failed to ensure client session snapshot for float removal", err);
        return;
    };

    var float_index: ?usize = null;
    for (snapshot.floats.items, 0..) |float_state, idx| {
        if (std.mem.eql(u8, &float_state.pane_uuid, &pane_uuid)) {
            float_index = idx;
            break;
        }
    }
    if (float_index) |idx| {
        _ = snapshot.floats.orderedRemove(idx);
    }

    if (snapshot.panes.get(pane_uuid)) |pane| {
        if (pane.kind == .float) {
            _ = snapshot.panes.remove(pane_uuid);
        }
    }

    if (snapshot.active_float_uuid) |active_float_uuid| {
        if (std.mem.eql(u8, &active_float_uuid, &pane_uuid)) {
            snapshot.active_float_uuid = null;
        }
    }
    if (snapshot.focused_pane_uuid) |focused_pane_uuid| {
        if (std.mem.eql(u8, &focused_pane_uuid, &pane_uuid)) {
            snapshot.focused_pane_uuid = if (snapshot.active_tab < snapshot.tabs.items.len)
                snapshot.tabs.items[snapshot.active_tab].focused_pane_uuid
            else
                null;
        }
    }
    self.store.markDirty();
}
