const std = @import("std");
const core = @import("core");
const layout_template = @import("layout_template.zig");
const client_session_snapshot = @import("client_session_snapshot.zig");

pub fn applyClientSessionLayoutTemplate(
    self: anytype,
    client_id: usize,
    source_uuid: [32]u8,
    tree_json: []const u8,
) !void {
    const client = self.getClient(client_id) orelse return error.ClientNotFound;
    const snapshot = try client_session_snapshot.ensureClientSessionSnapshot(self.allocator, client);

    const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, tree_json, .{});
    defer parsed.deinit();

    const leaf_count = layout_template.countTemplateLeaves(parsed.value);
    if (leaf_count == 0) return error.InvalidLayout;

    var cwds: std.ArrayList(?[]const u8) = .empty;
    defer cwds.deinit(self.allocator);
    try layout_template.collectTemplateCwds(parsed.value, &cwds, self.allocator);

    var target_tab_idx: ?usize = null;
    if (snapshot.panes.get(source_uuid)) |pane_state| {
        target_tab_idx = pane_state.parent_tab;
    }
    if (target_tab_idx == null and snapshot.active_tab < snapshot.tabs.items.len) {
        target_tab_idx = snapshot.active_tab;
    }
    const tab_idx = target_tab_idx orelse return error.InvalidLayout;
    if (tab_idx >= snapshot.tabs.items.len) return error.InvalidLayout;

    var current_split_uuids: std.ArrayList([32]u8) = .empty;
    defer current_split_uuids.deinit(self.allocator);
    layout_template.collectLayoutPaneUuids(self.allocator, snapshot.tabs.items[tab_idx].root, &current_split_uuids) catch |err| {
        core.logging.logError("ses", "failed to collect current layout pane uuids", err);
        return error.OutOfMemory;
    };

    var source_in_tab = false;
    for (current_split_uuids.items) |pane_uuid| {
        if (std.mem.eql(u8, &pane_uuid, &source_uuid)) {
            source_in_tab = true;
            break;
        }
    }
    if (!source_in_tab) return error.InvalidLayout;

    var leaf_uuids: std.ArrayList([32]u8) = .empty;
    defer leaf_uuids.deinit(self.allocator);
    try leaf_uuids.append(self.allocator, source_uuid);

    var created_uuids: std.ArrayList([32]u8) = .empty;
    defer {
        for (created_uuids.items) |pane_uuid| {
            if (!self.store.panes.contains(pane_uuid)) continue;
            self.killPane(pane_uuid) catch |err| {
                core.logging.logError("ses", "killPane failed rolling back session layout replacement", err);
            };
        }
        created_uuids.deinit(self.allocator);
    }

    var leaf_idx: usize = 1;
    while (leaf_idx < leaf_count) : (leaf_idx += 1) {
        const cwd = if (leaf_idx < cwds.items.len) cwds.items[leaf_idx] else null;
        const pane = try self.createPane(client_id, std.posix.getenv("SHELL") orelse "/bin/sh", cwd, null, null, null, null);
        pane.requestBacklogReplay();
        try leaf_uuids.append(self.allocator, pane.uuid);
        try created_uuids.append(self.allocator, pane.uuid);
    }

    var next_uuid_idx: usize = 0;
    const new_root = try layout_template.buildTemplateLayoutNode(snapshot.allocator, parsed.value, leaf_uuids.items, &next_uuid_idx);
    errdefer {
        new_root.deinit(snapshot.allocator);
        snapshot.allocator.destroy(new_root);
    }

    var live_uuids = leaf_uuids;
    defer live_uuids.deinit(self.allocator);
    leaf_uuids = .empty;

    var remove_split_uuids: std.ArrayList([32]u8) = .empty;
    defer remove_split_uuids.deinit(self.allocator);
    for (current_split_uuids.items) |pane_uuid| {
        var keep = false;
        for (live_uuids.items) |live_uuid| {
            if (std.mem.eql(u8, &live_uuid, &pane_uuid)) {
                keep = true;
                break;
            }
        }
        if (!keep) try remove_split_uuids.append(self.allocator, pane_uuid);
    }

    if (snapshot.tabs.items[tab_idx].root) |old_root| {
        old_root.deinit(snapshot.allocator);
        snapshot.allocator.destroy(old_root);
    }
    snapshot.tabs.items[tab_idx].root = new_root;
    snapshot.tabs.items[tab_idx].focused_pane_uuid = source_uuid;
    snapshot.active_tab = tab_idx;
    if (snapshot.active_float_uuid == null) {
        snapshot.focused_pane_uuid = source_uuid;
    }

    for (remove_split_uuids.items) |pane_uuid| {
        _ = snapshot.panes.remove(pane_uuid);
    }
    for (live_uuids.items) |pane_uuid| {
        if (snapshot.panes.getPtr(pane_uuid)) |pane_state| {
            pane_state.kind = .split;
            pane_state.parent_tab = tab_idx;
            pane_state.sticky = false;
            pane_state.is_pwd = false;
            pane_state.float_key = 0;
        } else {
            try snapshot.panes.put(pane_uuid, .{
                .uuid = pane_uuid,
                .kind = .split,
                .parent_tab = tab_idx,
            });
        }
    }

    for (remove_split_uuids.items) |pane_uuid| {
        self.killPane(pane_uuid) catch |err| {
            core.logging.logError("ses", "killPane failed removing replaced split pane", err);
        };
    }

    created_uuids.clearRetainingCapacity();
    self.markDirty();
}
