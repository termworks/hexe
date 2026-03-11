const std = @import("std");
const core = @import("core");
const mux = @import("main.zig");
const session_model = core.session_model;

const state_types = @import("state_types.zig");
const Tab = state_types.Tab;

const layout_mod = @import("layout.zig");
const LayoutNode = layout_mod.LayoutNode;

const Pane = @import("pane.zig").Pane;
const OrphanedPaneInfo = core.FrontendOrphanedPaneInfo;

const SessionSnapshot = session_model.SessionSnapshot;
const SessionLayoutNode = session_model.SessionLayoutNode;
const SessionFloat = session_model.SessionFloat;
const AdoptInfo = struct { pane_id: u16 };
const ExistingPaneViews = std.AutoHashMap([32]u8, *Pane);

/// Validate the structure of mux state JSON before attempting restoration.
/// This prevents crashes from malformed/corrupted JSON.
fn validateMuxStateJson(value: *const std.json.Value) bool {
    // Root must be an object
    if (value.* != .object) {
        mux.debugLog("validateMuxStateJson: root is not an object", .{});
        return false;
    }
    const root = value.object;

    // Required fields with type checks
    const required_fields = .{
        .{ "uuid", .string },
        .{ "session_name", .string },
        .{ "tab_counter", .integer },
        .{ "tabs", .array },
        .{ "floats", .array },
        .{ "active_tab", .integer },
    };

    inline for (required_fields) |field_spec| {
        const field_name = field_spec[0];
        const expected_type = field_spec[1];

        const field_value = root.get(field_name) orelse {
            mux.debugLog("validateMuxStateJson: missing required field '{s}'", .{field_name});
            return false;
        };

        const matches = switch (expected_type) {
            .string => field_value == .string,
            .integer => field_value == .integer,
            .array => field_value == .array,
            else => false,
        };

        if (!matches) {
            mux.debugLog("validateMuxStateJson: field '{s}' has wrong type", .{field_name});
            return false;
        }
    }

    // active_floating can be null or integer
    if (root.get("active_floating")) |af| {
        if (af != .null and af != .integer) {
            mux.debugLog("validateMuxStateJson: active_floating must be null or integer", .{});
            return false;
        }
    }

    // Validate tabs array elements
    const tabs = root.get("tabs").?.array;
    for (tabs.items) |tab_val| {
        if (tab_val != .object) {
            mux.debugLog("validateMuxStateJson: tabs array contains non-object", .{});
            return false;
        }
        const tab_obj = tab_val.object;

        // Each tab must have name, splits array
        if (tab_obj.get("name")) |name| {
            if (name != .string) {
                mux.debugLog("validateMuxStateJson: tab name is not a string", .{});
                return false;
            }
        } else {
            mux.debugLog("validateMuxStateJson: tab missing name", .{});
            return false;
        }

        if (tab_obj.get("splits")) |splits| {
            if (splits != .array) {
                mux.debugLog("validateMuxStateJson: tab splits is not an array", .{});
                return false;
            }
        }
    }

    // Validate floats array elements
    const floats = root.get("floats").?.array;
    for (floats.items) |float_val| {
        if (float_val != .object) {
            mux.debugLog("validateMuxStateJson: floats array contains non-object", .{});
            return false;
        }
    }

    mux.debugLog("validateMuxStateJson: validation passed", .{});
    return true;
}

fn applyDeferredPaneExits(self: anytype) void {
    var pending: std.ArrayList([32]u8) = .empty;
    defer pending.deinit(self.allocator);
    self.frontend_client.drainPendingPaneExits(&pending);

    for (pending.items) |uuid| {
        var marked = false;

        for (self.view.tabs.items) |*tab| {
            var it = tab.layout.splits.valueIterator();
            while (it.next()) |pane_ptr| {
                if (std.mem.eql(u8, &pane_ptr.*.uuid, &uuid)) {
                    pane_ptr.*.backend.pod.dead = true;
                    marked = true;
                }
            }
        }

        for (self.view.floats.items) |pane| {
            if (std.mem.eql(u8, &pane.uuid, &uuid)) {
                pane.backend.pod.dead = true;
                marked = true;
            }
        }

        if (marked) {
            mux.debugLog("reattachSession: applied deferred pane_exited uuid={s}", .{uuid[0..8]});
        }
    }
}

fn normalizeRestoredSessionName(name: []const u8) []const u8 {
    if (name.len >= 3) {
        const last_char = name[name.len - 1];
        if (last_char >= '1' and last_char <= '9' and name[name.len - 2] == '-') {
            return name[0 .. name.len - 2];
        }
    }
    return name;
}

fn clearStateForRestore(self: anytype) void {
    while (self.view.tabs.items.len > 0) {
        const tab_opt = self.view.tabs.pop();
        if (tab_opt) |tab_const| {
            var tab = tab_const;
            tab.deinit();
        }
    }

    while (self.view.floats.items.len > 0) {
        const p_opt = self.view.floats.pop();
        if (p_opt) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
    }

    self.setActiveTabIndex(0);
    self.setActiveFloatingIndex(null);
    self.setFocusedPaneUuid(null);
    self.clearTabFocusMemory();
}

fn deinitTabPreservingPanes(tab: *Tab) void {
    tab.layout.splits.deinit();
    if (tab.layout.root) |root| {
        tab.layout.freeNode(root);
        tab.layout.root = null;
    }
    tab.notifications.deinit();
    tab.popups.deinit();
}

fn captureExistingPaneViews(self: anytype, out: *ExistingPaneViews) void {
    for (self.view.tabs.items) |*tab| {
        var it = tab.layout.splits.valueIterator();
        while (it.next()) |pane_ptr| {
            out.put(pane_ptr.*.uuid, pane_ptr.*) catch {};
        }
    }
    for (self.view.floats.items) |pane| {
        out.put(pane.uuid, pane) catch {};
    }
}

fn clearStatePreservingPanes(self: anytype) void {
    while (self.view.tabs.items.len > 0) {
        const tab_opt = self.view.tabs.pop();
        if (tab_opt) |tab_const| {
            var tab = tab_const;
            deinitTabPreservingPanes(&tab);
        }
    }

    self.view.floats.clearRetainingCapacity();
    self.setActiveTabIndex(0);
    self.setActiveFloatingIndex(null);
    self.setFocusedPaneUuid(null);
    self.clearTabFocusMemory();
}

fn clearPaneAuxCaches(self: anytype, uuid: [32]u8) void {
    self.removePaneProcMetadata(uuid);
    self.removePaneName(uuid);
    if (self.float_rename_uuid) |rename_uuid| {
        if (std.mem.eql(u8, &rename_uuid, &uuid)) {
            self.float_rename_uuid = null;
            self.float_rename_buf.clearRetainingCapacity();
        }
    }
}

fn destroyUnusedPaneViews(self: anytype, existing_views: *ExistingPaneViews) void {
    var it = existing_views.iterator();
    while (it.next()) |entry| {
        clearPaneAuxCaches(self, entry.key_ptr.*);
        entry.value_ptr.*.deinit();
        self.allocator.destroy(entry.value_ptr.*);
    }
}

fn recyclePaneForSplit(self: anytype, tab: *Tab, pane: *Pane, pane_id: u16, pane_uuid: [32]u8, actual_focus_uuid: ?[32]u8) void {
    pane.id = pane_id;
    pane.uuid = pane_uuid;
    pane.floating = false;
    pane.focused = if (actual_focus_uuid) |focused_uuid| std.mem.eql(u8, &focused_uuid, &pane_uuid) else false;
    pane.visible = true;
    pane.tab_visible = 0;
    pane.float_key = 0;
    pane.border_x = 0;
    pane.border_y = 0;
    pane.border_w = 0;
    pane.border_h = 0;
    pane.float_width_pct = 60;
    pane.float_height_pct = 60;
    pane.float_pos_x_pct = 50;
    pane.float_pos_y_pct = 50;
    pane.float_pad_x = 1;
    pane.float_pad_y = 0;
    if (pane.pwd_dir) |dir| {
        self.allocator.free(dir);
        pane.pwd_dir = null;
    }
    pane.is_pwd = false;
    pane.sticky = false;
    pane.navigatable = false;
    pane.retained_after_exit = false;
    pane.capture_output = false;
    pane.captured_output.clearRetainingCapacity();
    pane.dim_background = false;
    if (pane.exit_key) |k| {
        self.allocator.free(k);
        pane.exit_key = null;
    }
    pane.closed_by_exit_key = false;
    pane.parent_tab = null;
    pane.float_style = null;
    if (pane.float_title) |t| {
        self.allocator.free(t);
        pane.float_title = null;
    }
    pane.backend.pod.dead = false;
    tab.layout.configurePaneNotifications(pane);
}

fn recyclePaneForFloat(self: anytype, pane: *Pane, float_state: SessionFloat, actual_focus_uuid: ?[32]u8) void {
    pane.uuid = float_state.pane_uuid;
    pane.floating = true;
    pane.focused = if (actual_focus_uuid) |focused_uuid| std.mem.eql(u8, &focused_uuid, &float_state.pane_uuid) else false;
    pane.visible = float_state.visible;
    pane.tab_visible = float_state.tab_visible;
    pane.float_key = float_state.float_key;
    pane.float_width_pct = float_state.width_pct;
    pane.float_height_pct = float_state.height_pct;
    pane.float_pos_x_pct = float_state.pos_x_pct;
    pane.float_pos_y_pct = float_state.pos_y_pct;
    pane.float_pad_x = float_state.pad_x;
    pane.float_pad_y = float_state.pad_y;
    pane.is_pwd = float_state.is_pwd;
    pane.sticky = float_state.sticky;
    pane.navigatable = false;
    pane.parent_tab = float_state.parent_tab;
    pane.retained_after_exit = false;
    pane.capture_output = false;
    pane.captured_output.clearRetainingCapacity();
    pane.dim_background = false;
    if (pane.exit_key) |k| {
        self.allocator.free(k);
        pane.exit_key = null;
    }
    pane.closed_by_exit_key = false;
    pane.float_style = null;
    if (pane.float_title) |t| {
        self.allocator.free(t);
        pane.float_title = null;
    }
    pane.backend.pod.dead = false;
    if (!pane.is_pwd and pane.pwd_dir != null) {
        self.allocator.free(pane.pwd_dir.?);
        pane.pwd_dir = null;
    }
}

fn hydratePaneMetadata(self: anytype, pane: *Pane, uuid: [32]u8) void {
    if (self.frontend_client.getPaneInfoSnapshot(uuid)) |snap| {
        defer if (snap.fg_name) |s| self.allocator.free(s);
        if (snap.name) |name| {
            self.setPaneNameOwned(uuid, name);
        }
        pane.setSesCwd(snap.cwd);
        self.setPaneProc(uuid, snap.fg_name, snap.fg_pid);
    } else {
        self.frontend_client.requestPaneProcess(uuid);
        self.frontend_client.requestPaneCwd(uuid);
    }
}

fn ensureAdoptInfo(
    self: anytype,
    uuid: [32]u8,
    uuid_pane_map: *std.AutoHashMap([32]u8, AdoptInfo),
    existing_views: ?*ExistingPaneViews,
    attached_snapshot: bool,
) ?AdoptInfo {
    if (uuid_pane_map.get(uuid)) |info| return info;
    if (existing_views) |views| {
        if (views.get(uuid)) |pane| {
            if (pane.getPaneId()) |pane_id| {
                return .{ .pane_id = pane_id };
            }
        }
    }
    if (attached_snapshot) {
        if (self.frontend_client.getPaneInfoSnapshot(uuid)) |snap| {
            defer if (snap.name) |s| self.allocator.free(s);
            defer if (snap.cwd) |s| self.allocator.free(s);
            defer if (snap.fg_name) |s| self.allocator.free(s);
            if (snap.pane_id) |pane_id| {
                const info = AdoptInfo{ .pane_id = pane_id };
                uuid_pane_map.put(uuid, info) catch {};
                return info;
            }
        }
    }
    if (self.frontend_client.adoptPane(uuid)) |adopt_res| {
        const info = AdoptInfo{ .pane_id = adopt_res.pane_id };
        uuid_pane_map.put(uuid, info) catch {};
        return info;
    } else |_| {
        return null;
    }
}

fn ensureSplitPaneView(
    self: anytype,
    tab: *Tab,
    pane_uuid: [32]u8,
    local_ids: *std.AutoHashMap([32]u8, u16),
    uuid_pane_map: *std.AutoHashMap([32]u8, AdoptInfo),
    existing_views: ?*ExistingPaneViews,
    attached_snapshot: bool,
    used_uuids: *std.AutoHashMap([32]u8, void),
    remembered_focus_uuid: ?[32]u8,
    actual_focus_uuid: ?[32]u8,
) ?u16 {
    if (local_ids.get(pane_uuid)) |existing| return existing;
    if (used_uuids.contains(pane_uuid)) return null;

    const info = ensureAdoptInfo(self, pane_uuid, uuid_pane_map, existing_views, attached_snapshot) orelse return null;
    const vt_fd = self.frontend_client.getVtFd() orelse return null;

    const pane_id = tab.layout.next_split_id;
    tab.layout.next_split_id +%= 1;
    if (tab.layout.next_split_id == 0) tab.layout.next_split_id = 1;

    const pane = blk: {
        if (existing_views) |views| {
            if (views.fetchRemove(pane_uuid)) |entry| {
                const pane = entry.value;
                if (pane.getPaneId() != info.pane_id or !std.mem.eql(u8, &pane.uuid, &pane_uuid)) {
                    pane.replaceWithPod(info.pane_id, vt_fd, pane_uuid) catch {
                        pane.deinit();
                        self.allocator.destroy(pane);
                        return null;
                    };
                }
                recyclePaneForSplit(self, tab, pane, pane_id, pane_uuid, actual_focus_uuid);
                break :blk pane;
            }
        }

        const pane = self.allocator.create(Pane) catch return null;
        errdefer self.allocator.destroy(pane);

        pane.initWithPod(self.allocator, pane_id, 0, 0, self.layout_width, self.layout_height, info.pane_id, vt_fd, pane_uuid) catch return null;
        recyclePaneForSplit(self, tab, pane, pane_id, pane_uuid, actual_focus_uuid);
        pane.configureNotificationsFromPop(&self.pop_config.pane.notification);
        break :blk pane;
    };

    hydratePaneMetadata(self, pane, pane_uuid);

    tab.layout.splits.put(pane_id, pane) catch {
        pane.deinit();
        self.allocator.destroy(pane);
        return null;
    };
    local_ids.put(pane_uuid, pane_id) catch {};
    used_uuids.put(pane_uuid, {}) catch {};

    if (remembered_focus_uuid) |focus_uuid| {
        if (std.mem.eql(u8, &focus_uuid, &pane_uuid)) {
            tab.layout.focused_split_id = pane_id;
        }
    }

    return pane_id;
}

fn freeRestoredLayoutNode(allocator: std.mem.Allocator, node: *LayoutNode) void {
    switch (node.*) {
        .pane => {},
        .split => |split| {
            freeRestoredLayoutNode(allocator, split.first);
            freeRestoredLayoutNode(allocator, split.second);
        },
    }
    allocator.destroy(node);
}

fn restoreLayoutNode(
    self: anytype,
    tab: *Tab,
    node: *const SessionLayoutNode,
    local_ids: *std.AutoHashMap([32]u8, u16),
    uuid_pane_map: *std.AutoHashMap([32]u8, AdoptInfo),
    existing_views: ?*ExistingPaneViews,
    attached_snapshot: bool,
    used_uuids: *std.AutoHashMap([32]u8, void),
    remembered_focus_uuid: ?[32]u8,
    actual_focus_uuid: ?[32]u8,
) ?*LayoutNode {
    switch (node.*) {
        .pane => |pane_uuid| {
            const pane_id = ensureSplitPaneView(
                self,
                tab,
                pane_uuid,
                local_ids,
                uuid_pane_map,
                existing_views,
                attached_snapshot,
                used_uuids,
                remembered_focus_uuid,
                actual_focus_uuid,
            ) orelse return null;
            const restored = self.allocator.create(LayoutNode) catch return null;
            restored.* = .{ .pane = pane_id };
            return restored;
        },
        .split => |split| {
            const first = restoreLayoutNode(self, tab, split.first, local_ids, uuid_pane_map, existing_views, attached_snapshot, used_uuids, remembered_focus_uuid, actual_focus_uuid);
            const second = restoreLayoutNode(self, tab, split.second, local_ids, uuid_pane_map, existing_views, attached_snapshot, used_uuids, remembered_focus_uuid, actual_focus_uuid);

            if (first == null and second == null) return null;
            if (first == null) return second;
            if (second == null) return first;

            const restored = self.allocator.create(LayoutNode) catch {
                if (first) |f| {
                    freeRestoredLayoutNode(self.allocator, f);
                }
                if (second) |s| {
                    freeRestoredLayoutNode(self.allocator, s);
                }
                return null;
            };
            restored.* = .{
                .split = .{
                    .dir = if (split.dir == .horizontal) .horizontal else .vertical,
                    .ratio = split.ratio,
                    .first = first.?,
                    .second = second.?,
                },
            };
            return restored;
        },
    }
}

fn restoreFloatPane(
    self: anytype,
    float_state: SessionFloat,
    uuid_pane_map: *std.AutoHashMap([32]u8, AdoptInfo),
    existing_views: ?*ExistingPaneViews,
    attached_snapshot: bool,
    used_uuids: *std.AutoHashMap([32]u8, void),
    actual_focus_uuid: ?[32]u8,
) ?*Pane {
    if (used_uuids.contains(float_state.pane_uuid)) return null;
    const info = ensureAdoptInfo(self, float_state.pane_uuid, uuid_pane_map, existing_views, attached_snapshot) orelse return null;
    const vt_fd = self.frontend_client.getVtFd() orelse return null;

    const pane = blk: {
        if (existing_views) |views| {
            if (views.fetchRemove(float_state.pane_uuid)) |entry| {
                const pane = entry.value;
                if (pane.getPaneId() != info.pane_id or !std.mem.eql(u8, &pane.uuid, &float_state.pane_uuid)) {
                    pane.replaceWithPod(info.pane_id, vt_fd, float_state.pane_uuid) catch {
                        pane.deinit();
                        self.allocator.destroy(pane);
                        return null;
                    };
                }
                break :blk pane;
            }
        }

        const pane = self.allocator.create(Pane) catch return null;
        errdefer self.allocator.destroy(pane);

        const local_id: u16 = @intCast(100 + self.view.floats.items.len);
        pane.initWithPod(self.allocator, local_id, 0, 0, self.layout_width, self.layout_height, info.pane_id, vt_fd, float_state.pane_uuid) catch return null;
        pane.configureNotificationsFromPop(&self.pop_config.pane.notification);
        break :blk pane;
    };
    pane.id = @intCast(100 + self.view.floats.items.len);
    pane.uuid = float_state.pane_uuid;
    recyclePaneForFloat(self, pane, float_state, actual_focus_uuid);
    hydratePaneMetadata(self, pane, float_state.pane_uuid);

    if (pane.float_key != 0) {
        if (self.getLayoutFloatByKey(pane.float_key)) |float_def| {
            const style = if (float_def.style) |*s| s else if (self.config.float_style_default) |*s| s else null;
            if (style) |s| pane.float_style = s;
            pane.border_color = float_def.color orelse self.config.float_color;
        }
    }

    if (self.frontend_client.isConnected()) {
        if (self.frontend_client.getPaneName(float_state.pane_uuid)) |name| {
            pane.float_title = name;
        }
    }

    used_uuids.put(float_state.pane_uuid, {}) catch {};
    return pane;
}

fn countSessionLayoutPanes(node: ?*const SessionLayoutNode) usize {
    const root = node orelse return 0;
    return switch (root.*) {
        .pane => 1,
        .split => |split| countSessionLayoutPanes(split.first) + countSessionLayoutPanes(split.second),
    };
}

fn layoutMatchesSnapshot(layout: *const layout_mod.Layout, node: ?*const LayoutNode, snapshot_node: ?*const SessionLayoutNode) bool {
    const live = node orelse return snapshot_node == null;
    const expected = snapshot_node orelse return false;

    return switch (live.*) {
        .pane => |pane_id| switch (expected.*) {
            .pane => |pane_uuid| blk: {
                const pane = layout.splits.get(pane_id) orelse break :blk false;
                break :blk std.mem.eql(u8, &pane.uuid, &pane_uuid);
            },
            .split => false,
        },
        .split => |split| switch (expected.*) {
            .pane => false,
            .split => |expected_split|
                split.dir == @as(layout_mod.SplitDir, if (expected_split.dir == .horizontal) .horizontal else .vertical) and
                std.math.approxEqAbs(f32, split.ratio, expected_split.ratio, 0.0001) and
                layoutMatchesSnapshot(layout, split.first, expected_split.first) and
                layoutMatchesSnapshot(layout, split.second, expected_split.second),
        },
    };
}

fn canApplySnapshotIncrementally(self: anytype, snapshot: *const SessionSnapshot) bool {
    if (self.view.tabs.items.len != snapshot.tabs.items.len) return false;
    if (self.view.floats.items.len != snapshot.floats.items.len) return false;

    for (snapshot.tabs.items, 0..) |snapshot_tab, idx| {
        if (!std.mem.eql(u8, &snapshot_tab.uuid, &(self.tabUuid(idx) orelse return false))) return false;
        if (!std.mem.eql(u8, snapshot_tab.name, self.tabName(idx))) return false;

        const live_tab = &self.view.tabs.items[idx];
        if (live_tab.layout.splits.count() != countSessionLayoutPanes(snapshot_tab.root)) return false;
        if (!layoutMatchesSnapshot(&live_tab.layout, live_tab.layout.root, snapshot_tab.root)) return false;
    }

    for (snapshot.floats.items, 0..) |float_state, idx| {
        if (!std.mem.eql(u8, &self.view.floats.items[idx].uuid, &float_state.pane_uuid)) return false;
    }

    return true;
}

fn applyTabSnapshotFocus(tab: *Tab, remembered_focus_uuid: ?[32]u8, actual_focus_uuid: ?[32]u8) void {
    const target_focus_uuid = remembered_focus_uuid orelse actual_focus_uuid;

    var found_focus = false;
    var it = tab.layout.splits.iterator();
    while (it.next()) |entry| {
        const pane = entry.value_ptr.*;
        const matches_actual = if (actual_focus_uuid) |focused_uuid|
            std.mem.eql(u8, &pane.uuid, &focused_uuid)
        else
            false;
        pane.focused = matches_actual;

        if (target_focus_uuid) |focused_uuid| {
            if (std.mem.eql(u8, &pane.uuid, &focused_uuid)) {
                tab.layout.focused_split_id = entry.key_ptr.*;
                found_focus = true;
            }
        }
    }

    if (!found_focus) {
        var first = tab.layout.splits.iterator();
        if (first.next()) |entry| {
            tab.layout.focused_split_id = entry.key_ptr.*;
        }
    }
}

fn updateFloatPresentation(self: anytype, pane: *Pane, float_state: SessionFloat, actual_focus_uuid: ?[32]u8) void {
    pane.floating = true;
    pane.focused = if (actual_focus_uuid) |focused_uuid|
        std.mem.eql(u8, &focused_uuid, &float_state.pane_uuid)
    else
        false;
    pane.visible = float_state.visible;
    pane.tab_visible = float_state.tab_visible;
    pane.float_key = float_state.float_key;
    pane.float_width_pct = float_state.width_pct;
    pane.float_height_pct = float_state.height_pct;
    pane.float_pos_x_pct = float_state.pos_x_pct;
    pane.float_pos_y_pct = float_state.pos_y_pct;
    pane.float_pad_x = float_state.pad_x;
    pane.float_pad_y = float_state.pad_y;
    pane.parent_tab = float_state.parent_tab;
    pane.sticky = float_state.sticky;
    pane.is_pwd = float_state.is_pwd;

    if (!pane.is_pwd and pane.pwd_dir != null) {
        self.allocator.free(pane.pwd_dir.?);
        pane.pwd_dir = null;
    }

    pane.float_style = null;
    if (pane.float_key != 0) {
        if (self.getLayoutFloatByKey(pane.float_key)) |float_def| {
            if (float_def.style) |*style| {
                pane.float_style = style;
            } else if (self.config.float_style_default) |*style| {
                pane.float_style = style;
            }
            pane.border_color = float_def.color orelse self.config.float_color;
        }
    }
}

fn applySnapshotIncrementally(self: anytype, snapshot: *const SessionSnapshot) bool {
    if (!canApplySnapshotIncrementally(self, snapshot)) return false;

    for (snapshot.tabs.items, 0..) |snapshot_tab, idx| {
        applyTabSnapshotFocus(&self.view.tabs.items[idx], snapshot_tab.focused_pane_uuid, snapshot.focused_pane_uuid);
    }

    for (snapshot.floats.items, 0..) |float_state, idx| {
        updateFloatPresentation(self, self.view.floats.items[idx], float_state, snapshot.focused_pane_uuid);
    }

    self.resizeFloatingPanes();

    if (!self.replaceAttachedSessionSnapshot(snapshot)) return false;

    if (self.view.tabs.items.len > 0) {
        self.setActiveTabIndex(@min(snapshot.active_tab, self.view.tabs.items.len - 1));
    } else {
        self.setActiveTabIndex(0);
    }
    self.setActiveFloatingUuid(snapshot.active_float_uuid);
    self.setFocusedPaneUuid(snapshot.focused_pane_uuid);

    if (self.activeFloatingIndex()) |idx| {
        self.rememberFloatingFocus(self.view.floats.items[idx]);
    } else if (self.view.tabs.items.len > 0) {
        self.rememberSplitFocus();
    }

    self.renderer.invalidate();
    self.force_full_render = true;
    self.needs_render = true;
    return true;
}

/// Reattach to a detached session, restoring full state.
pub fn reattachSession(self: anytype, session_id_prefix: []const u8) bool {
    mux.debugLog("reattachSession: starting with prefix={s}", .{session_id_prefix});

    // Set flag to prevent SIGHUP from interrupting reattach
    self.runtime.beginReattach();
    defer self.runtime.endReattach();

    // Track reattach start time for timeout detection
    const reattach_start = std.time.milliTimestamp();

    if (!self.frontend_client.isConnected()) {
        mux.debugLog("reattachSession: frontend_client not connected, aborting", .{});
        return false;
    }

    // Try to reattach session (server supports prefix matching).
    mux.debugLog("reattachSession: calling runtime.reattachSessionSnapshot", .{});
    const result = self.runtime.reattachSessionSnapshot(session_id_prefix) catch |e| {
        mux.debugLog("reattachSession: runtime.reattachSessionSnapshot failed: {s}", .{@errorName(e)});
        return false;
    };
    if (result == null) {
        mux.debugLog("reattachSession: runtime.reattachSessionSnapshot returned null (session not found)", .{});
        return false;
    }

    var reattach_result = result.?;
    defer reattach_result.deinit();
    mux.debugLog("reattachSession: got parsed result with {d} panes", .{reattach_result.pane_uuids.len});
    const snapshot = &reattach_result.snapshot;

    // Check timeout after JSON parsing
    {
        const elapsed = std.time.milliTimestamp() - reattach_start;
        if (elapsed > 30000) {
            mux.debugLog("reattachSession: timeout after JSON parse ({d}ms > 30s), aborting", .{elapsed});
            self.notifications.showFor("Reattach timeout: JSON parsing took too long", 5000);
            return false;
        } else if (elapsed > 10000) {
            const msg = std.fmt.allocPrint(
                self.allocator,
                "Warning: reattach slow ({d}s elapsed)",
                .{@divTrunc(elapsed, 1000)},
            ) catch "Warning: reattach taking longer than expected";
            defer if (!std.mem.eql(u8, msg, "Warning: reattach taking longer than expected")) self.allocator.free(msg);
            self.notifications.showFor(msg, 3000);
            mux.debugLog("reattachSession: slow progress warning after JSON parse ({d}ms)", .{elapsed});
        }
    }

    clearStateForRestore(self);
    self.clearTabMeta();
    const restored_name = normalizeRestoredSessionName(snapshot.session_name);
    if (!self.setSessionIdentity(snapshot.uuid, restored_name)) return false;
    self.setSessionTabCounter(if (snapshot.tab_counter > 1000) 0 else snapshot.tab_counter);
    const wanted_active_tab = snapshot.active_tab;

    var uuid_pane_map = std.AutoHashMap([32]u8, AdoptInfo).init(self.allocator);
    defer uuid_pane_map.deinit();

    var used_uuids = std.AutoHashMap([32]u8, void).init(self.allocator);
    defer used_uuids.deinit();

    mux.debugLog("reattachSession: adopting {d} panes", .{reattach_result.pane_uuids.len});
    var failed_adoptions: usize = 0;
    const total_panes = reattach_result.pane_uuids.len;

    for (reattach_result.pane_uuids, 0..) |uuid, i| {
        mux.debugLog("reattachSession: adopting pane {d}/{d} uuid={s}", .{ i + 1, total_panes, uuid[0..8] });

        // Check for duplicate UUID in the list
        if (uuid_pane_map.contains(uuid)) {
            mux.debugLog("reattachSession: DUPLICATE UUID detected: {s}, skipping", .{uuid[0..8]});
            failed_adoptions += 1;
            continue;
        }

        const adopt_result = self.frontend_client.adoptPane(uuid) catch |e| {
            mux.debugLog("reattachSession: adoptPane failed for uuid={s}: {s}", .{ uuid[0..8], @errorName(e) });
            failed_adoptions += 1;
            continue;
        };
        mux.debugLogUuid(&uuid, "reattachSession: adoptPane ok pane_id={d} vt_fd={?d}", .{ adopt_result.pane_id, self.frontend_client.vt_fd });
        uuid_pane_map.put(uuid, .{ .pane_id = adopt_result.pane_id }) catch {};
    }
    mux.debugLog("reattachSession: adopted {d} panes into uuid_pane_map", .{uuid_pane_map.count()});

    // Notify user if some panes failed to reattach
    if (failed_adoptions > 0) {
        const msg = std.fmt.allocPrint(
            self.allocator,
            "Warning: {d}/{d} panes failed to reattach",
            .{ failed_adoptions, total_panes },
        ) catch "Warning: Some panes failed to reattach";
        defer if (!std.mem.eql(u8, msg, "Warning: Some panes failed to reattach")) self.allocator.free(msg);
        self.notifications.showFor(msg, 5000);
        mux.debugLog("reattachSession: notified user about {d} failed adoptions", .{failed_adoptions});
    }

    // Check timeout after pane adoption
    {
        const elapsed = std.time.milliTimestamp() - reattach_start;
        if (elapsed > 30000) {
            mux.debugLog("reattachSession: timeout after pane adoption ({d}ms > 30s), aborting", .{elapsed});
            self.notifications.showFor("Reattach timeout: pane adoption took too long", 5000);
            return false;
        } else if (elapsed > 10000) {
            const msg = std.fmt.allocPrint(
                self.allocator,
                "Warning: reattach slow ({d}s elapsed, {d} panes adopted)",
                .{ @divTrunc(elapsed, 1000), uuid_pane_map.count() },
            ) catch "Warning: reattach taking longer than expected";
            defer if (!std.mem.eql(u8, msg, "Warning: reattach taking longer than expected")) self.allocator.free(msg);
            self.notifications.showFor(msg, 3000);
            mux.debugLog("reattachSession: slow progress warning after adoption ({d}ms)", .{elapsed});
        }
    }

    for (snapshot.tabs.items) |snapshot_tab| {
        var tab = Tab.init(self.allocator, self.layout_width, self.layout_height, self.pop_config.carrier.notification);

        if (self.frontend_client.isConnected()) {
            tab.layout.setFrontendClient(self.frontend_client);
        }
        tab.layout.setPanePopConfig(&self.pop_config.pane.notification);

        var local_ids = std.AutoHashMap([32]u8, u16).init(self.allocator);
        defer local_ids.deinit();

        if (snapshot_tab.root) |root| {
            tab.layout.root = restoreLayoutNode(
                self,
                &tab,
                root,
                &local_ids,
                &uuid_pane_map,
                null,
                false,
                &used_uuids,
                snapshot_tab.focused_pane_uuid,
                snapshot.focused_pane_uuid,
            );
        }

        if (!tab.layout.splits.contains(tab.layout.focused_split_id)) {
            var split_it = tab.layout.splits.iterator();
            if (split_it.next()) |entry| {
                tab.layout.focused_split_id = entry.key_ptr.*;
            }
        }

        if (tab.layout.root == null and tab.layout.splits.count() > 0) {
            const node = self.allocator.create(LayoutNode) catch {
                tab.deinit();
                continue;
            };
            node.* = .{ .pane = tab.layout.focused_split_id };
            tab.layout.root = node;
        }

        self.view.tabs.append(self.allocator, tab) catch {
            tab.deinit();
            continue;
        };
        if (!self.appendTabMeta(snapshot_tab.uuid, snapshot_tab.name)) return false;
    }

    if (!self.resetTabFocusMemory()) return false;

    for (snapshot.floats.items) |float_state| {
        const pane = restoreFloatPane(self, float_state, &uuid_pane_map, null, false, &used_uuids, snapshot.focused_pane_uuid) orelse continue;
        self.view.floats.append(self.allocator, pane) catch {
            pane.deinit();
            self.allocator.destroy(pane);
            continue;
        };
    }

    // Prune dead pane nodes from layout trees. Pods that died during detach
    // (e.g., from SIGPIPE) leave orphan nodes in the tree that would corrupt
    // the layout by allocating space for non-existent panes.
    for (self.view.tabs.items) |*tab| {
        tab.layout.pruneDeadNodes();
    }

    // Remove tabs that have no live panes (all pods died).
    {
        var i: usize = 0;
        var removed_tabs: usize = 0;
        while (i < self.view.tabs.items.len) {
            if (self.view.tabs.items[i].layout.splits.count() == 0) {
                // Don't remove the LAST tab - keep at least one tab always.
                if (self.view.tabs.items.len > 1) {
                    mux.debugLog("reattachSession: removing empty tab at index {d}", .{i});
                    var dead_tab = self.view.tabs.orderedRemove(i);
                    dead_tab.deinit();
                    self.removeTabMeta(i);
                    removed_tabs += 1;
                    // Don't increment i, next tab shifted into this position
                } else {
                    mux.debugLog("reattachSession: keeping last empty tab to prevent zero tabs", .{});
                    i += 1;
                }
            } else {
                i += 1;
            }
        }

        // Notify user if tabs were removed
        if (removed_tabs > 0) {
            const msg = std.fmt.allocPrint(
                self.allocator,
                "Warning: {d} empty tab(s) removed (all panes died)",
                .{removed_tabs},
            ) catch "Warning: Empty tabs were removed";
            defer if (!std.mem.eql(u8, msg, "Warning: Empty tabs were removed")) self.allocator.free(msg);
            self.notifications.showFor(msg, 4000);
            mux.debugLog("reattachSession: removed {d} empty tabs", .{removed_tabs});
        }
    }

    // Safety check: ensure we have at least one tab.
    // If all tabs were empty and removed, create a new one.
    if (self.view.tabs.items.len == 0) {
        mux.debugLog("reattachSession: CRITICAL - all tabs removed, creating new tab", .{});
        self.createTab() catch {
            mux.debugLog("reattachSession: FAILED to create recovery tab", .{});
            return false;
        };
        self.notifications.showFor("Warning: All tabs were empty, created new tab", 5000);
    }

    // Recalculate all layouts for current terminal size.
    for (self.view.tabs.items) |*tab| {
        tab.layout.resize(self.layout_width, self.layout_height);
    }

    // Validate and fix parent_tab indices for floating panes
    var invalid_parent_tabs: usize = 0;
    for (self.view.floats.items) |fp| {
        if (fp.parent_tab) |parent_idx| {
            if (parent_idx >= self.view.tabs.items.len) {
                mux.debugLog("reattachSession: invalid parent_tab {d} (only {d} tabs), setting to null", .{ parent_idx, self.view.tabs.items.len });
                fp.parent_tab = null;
                invalid_parent_tabs += 1;
            }
        }
    }
    // Notify user if any parent_tab links were broken
    if (invalid_parent_tabs > 0) {
        const msg = std.fmt.allocPrint(
            self.allocator,
            "Warning: {d} float(s) had invalid parent tab, reset to global",
            .{invalid_parent_tabs},
        ) catch "Warning: Some floats had invalid parent tab references";
        defer if (!std.mem.eql(u8, msg, "Warning: Some floats had invalid parent tab references")) self.allocator.free(msg);
        self.notifications.showFor(msg, 4000);
        mux.debugLog("reattachSession: corrected {d} invalid parent_tab references", .{invalid_parent_tabs});
    }

    // Recalculate floating pane positions.
    self.resizeFloatingPanes();

    // Apply restored active indices now that all state is present.
    if (self.view.tabs.items.len > 0) {
        self.setActiveTabIndex(@min(wanted_active_tab, self.view.tabs.items.len - 1));
    } else {
        self.setActiveTabIndex(0);
    }
    self.setActiveFloatingIndex(null);
    if (snapshot.active_float_uuid) |active_float_uuid| {
        for (self.view.floats.items, 0..) |pane, idx| {
            if (std.mem.eql(u8, &pane.uuid, &active_float_uuid)) {
                self.setActiveFloatingIndex(idx);
                break;
            }
        }
    }
    if (self.activeFloatingIndex()) |idx| {
        self.rememberFloatingFocus(self.view.floats.items[idx]);
    }

    if (!self.replaceAttachedSessionSnapshot(snapshot)) return false;
    if (!self.setSessionIdentity(snapshot.uuid, restored_name)) return false;

    self.renderer.invalidate();
    self.force_full_render = true;

    mux.debugLog("reattachSession: tabs restored={d}, floats restored={d}", .{ self.view.tabs.items.len, self.view.floats.items.len });

    // Check timeout after layout restoration
    {
        const elapsed = std.time.milliTimestamp() - reattach_start;
        if (elapsed > 30000) {
            mux.debugLog("reattachSession: timeout after layout restore ({d}ms > 30s), aborting", .{elapsed});
            self.notifications.showFor("Reattach timeout: layout restoration took too long", 5000);
            return false;
        } else if (elapsed > 10000) {
            const msg = std.fmt.allocPrint(
                self.allocator,
                "Warning: reattach slow ({d}s total, {d} tabs restored)",
                .{ @divTrunc(elapsed, 1000), self.view.tabs.items.len },
            ) catch "Warning: reattach taking longer than expected";
            defer if (!std.mem.eql(u8, msg, "Warning: reattach taking longer than expected")) self.allocator.free(msg);
            self.notifications.showFor(msg, 3000);
            mux.debugLog("reattachSession: slow progress warning after layout restore ({d}ms)", .{elapsed});
        }
    }

    if (self.view.tabs.items.len == 0) {
        mux.debugLog("reattachSession: no tabs restored, returning false", .{});
        return false;
    }

    // Re-register with restored UUID/name before requesting backlog replay.
    // This releases the attach session lock and stabilizes client identity first.
    const session_uuid = self.sessionUuid();
    mux.debugLog("reattachSession: finalizing attach uuid={s} name={s}", .{ session_uuid[0..8], self.sessionName() });
    if (self.runtime.completeReattach()) |change_opt| {
        if (change_opt) |change| {
            var owned_change = change;
            defer owned_change.deinit(self.allocator);
            mux.debugLog("reattachSession: resolved session name from '{s}' to '{s}'", .{ owned_change.previous_name, owned_change.resolved_name });
        }
        mux.debugLog("reattachSession: requestBacklogReplay done", .{});
    } else |e| {
        core.logging.logError("mux", "completeReattach failed in restoreLayout", e);
        mux.debugLog("reattachSession: completeReattach FAILED: {s}", .{@errorName(e)});
    }

    // Sync-phase reads can consume async pane_exited messages before the IPC
    // loop starts. Apply those exits now so dead panes/floats are not kept
    // around in a frozen state.
    applyDeferredPaneExits(self);

    // Final timeout check after backlog replay
    {
        const elapsed = std.time.milliTimestamp() - reattach_start;
        mux.debugLog("reattachSession: total elapsed time: {d}ms", .{elapsed});
        if (elapsed > 30000) {
            mux.debugLog("reattachSession: timeout after backlog replay ({d}ms > 30s), aborting", .{elapsed});
            self.notifications.showFor("Reattach timeout: session restored but backlog replay incomplete", 5000);
            // Don't return false here - the session is already restored, just warn user
        }
    }

    mux.debugLog("reattachSession: returning true, tabs={d} floats={d}", .{ self.view.tabs.items.len, self.view.floats.items.len });
    return true;
}

pub fn applySessionSnapshot(self: anytype, snapshot: *const SessionSnapshot) bool {
    if (applySnapshotIncrementally(self, snapshot)) {
        mux.debugLog("applySessionSnapshot: incrementally applied tabs={d} floats={d}", .{ self.view.tabs.items.len, self.view.floats.items.len });
        return true;
    }

    var existing_views = ExistingPaneViews.init(self.allocator);
    defer {
        destroyUnusedPaneViews(self, &existing_views);
        existing_views.deinit();
    }
    captureExistingPaneViews(self, &existing_views);
    clearStatePreservingPanes(self);
    self.clearTabMeta();

    if (!self.setSessionIdentity(snapshot.uuid, snapshot.session_name)) return false;
    self.setSessionTabCounter(if (snapshot.tab_counter > 1000) 0 else snapshot.tab_counter);

    const wanted_active_tab = snapshot.active_tab;

    var uuid_pane_map = std.AutoHashMap([32]u8, AdoptInfo).init(self.allocator);
    defer uuid_pane_map.deinit();

    var used_uuids = std.AutoHashMap([32]u8, void).init(self.allocator);
    defer used_uuids.deinit();

    for (snapshot.tabs.items) |snapshot_tab| {
        var tab = Tab.init(self.allocator, self.layout_width, self.layout_height, self.pop_config.carrier.notification);

        if (self.frontend_client.isConnected()) {
            tab.layout.setFrontendClient(self.frontend_client);
        }
        tab.layout.setPanePopConfig(&self.pop_config.pane.notification);

        var local_ids = std.AutoHashMap([32]u8, u16).init(self.allocator);
        defer local_ids.deinit();

        if (snapshot_tab.root) |root| {
            tab.layout.root = restoreLayoutNode(
                self,
                &tab,
                root,
                &local_ids,
                &uuid_pane_map,
                &existing_views,
                true,
                &used_uuids,
                snapshot_tab.focused_pane_uuid,
                snapshot.focused_pane_uuid,
            );
        }

        if (!tab.layout.splits.contains(tab.layout.focused_split_id)) {
            var split_it = tab.layout.splits.iterator();
            if (split_it.next()) |entry| {
                tab.layout.focused_split_id = entry.key_ptr.*;
            }
        }

        if (tab.layout.root == null and tab.layout.splits.count() > 0) {
            const node = self.allocator.create(LayoutNode) catch {
                tab.deinit();
                continue;
            };
            node.* = .{ .pane = tab.layout.focused_split_id };
            tab.layout.root = node;
        }

        self.view.tabs.append(self.allocator, tab) catch {
            tab.deinit();
            continue;
        };
        if (!self.appendTabMeta(snapshot_tab.uuid, snapshot_tab.name)) return false;
    }

    if (!self.resetTabFocusMemory()) return false;

    for (snapshot.floats.items) |float_state| {
        const pane = restoreFloatPane(self, float_state, &uuid_pane_map, &existing_views, true, &used_uuids, snapshot.focused_pane_uuid) orelse continue;
        self.view.floats.append(self.allocator, pane) catch {
            pane.deinit();
            self.allocator.destroy(pane);
            continue;
        };
    }

    for (self.view.tabs.items) |*tab| {
        tab.layout.pruneDeadNodes();
        tab.layout.resize(self.layout_width, self.layout_height);
    }

    var fi: usize = 0;
    while (fi < self.view.floats.items.len) : (fi += 1) {
        const pane = self.view.floats.items[fi];
        if (pane.parent_tab) |parent_idx| {
            if (parent_idx >= self.view.tabs.items.len) {
                pane.parent_tab = null;
            }
        }
    }
    self.resizeFloatingPanes();

    if (self.view.tabs.items.len > 0) {
        self.setActiveTabIndex(@min(wanted_active_tab, self.view.tabs.items.len - 1));
    } else {
        self.setActiveTabIndex(0);
    }
    self.setActiveFloatingIndex(null);
    if (snapshot.active_float_uuid) |active_float_uuid| {
        for (self.view.floats.items, 0..) |pane, idx| {
            if (std.mem.eql(u8, &pane.uuid, &active_float_uuid)) {
                self.setActiveFloatingIndex(idx);
                break;
            }
        }
    }
    if (self.activeFloatingIndex()) |idx| {
        self.rememberFloatingFocus(self.view.floats.items[idx]);
    }

    if (!self.replaceAttachedSessionSnapshot(snapshot)) return false;
    self.renderer.invalidate();
    self.force_full_render = true;
    self.needs_render = true;
    mux.debugLog("applySessionSnapshot: tabs={d} floats={d}", .{ self.view.tabs.items.len, self.view.floats.items.len });
    return true;
}

fn intFieldCast(comptime T: type, obj: std.json.ObjectMap, key: []const u8) ?T {
    const value = obj.get(key) orelse return null;
    if (value != .integer) return null;
    if (value.integer < 0) return null;
    return std.math.cast(T, value.integer);
}

/// Attach to orphaned pane by UUID prefix (for --attach CLI).
pub fn attachOrphanedPane(self: anytype, uuid_prefix: []const u8) bool {
    if (!self.frontend_client.isConnected()) return false;

    // Get list of orphaned panes and find matching UUID.
    var tabs: [32]OrphanedPaneInfo = undefined;
    const count = self.frontend_client.listOrphanedPanes(&tabs) catch return false;

    for (tabs[0..count]) |p| {
        if (std.mem.startsWith(u8, &p.uuid, uuid_prefix)) {
            // Found matching pane, adopt it.
            const result = self.frontend_client.adoptPane(p.uuid) catch return false;

            // Create a new tab with this pane.
            const tab_uuid = core.ipc.generateUuid();
            var tab = Tab.init(self.allocator, self.layout_width, self.layout_height, self.pop_config.carrier.notification);
            var tab_needs_cleanup = true;
            defer if (tab_needs_cleanup) tab.deinit();

            if (self.frontend_client.isConnected()) {
                tab.layout.setFrontendClient(self.frontend_client);
            }
            tab.layout.setPanePopConfig(&self.pop_config.pane.notification);

            const vt_fd = self.frontend_client.getVtFd() orelse return false;

            const pane = self.allocator.create(Pane) catch return false;
            var pane_needs_cleanup = true;
            defer if (pane_needs_cleanup) self.allocator.destroy(pane);

            pane.initWithPod(self.allocator, 0, 0, 0, self.layout_width, self.layout_height, result.pane_id, vt_fd, result.uuid) catch {
                return false;
            };

            if (self.frontend_client.getPaneInfoSnapshot(result.uuid)) |snap| {
                defer if (snap.fg_name) |s| self.allocator.free(s);
                if (snap.name) |name| {
                    self.setPaneNameOwned(result.uuid, name);
                }
                pane.setSesCwd(snap.cwd);
                self.setPaneProc(result.uuid, snap.fg_name, snap.fg_pid);
            } else {
                self.frontend_client.requestPaneProcess(result.uuid);
                self.frontend_client.requestPaneCwd(result.uuid);
            }

            pane.focused = true;
            pane.configureNotificationsFromPop(&self.pop_config.pane.notification);

            // Add pane to layout manually.
            tab.layout.splits.put(0, pane) catch {
                pane.deinit();
                return false;
            };
            // Pane is now owned by tab, no longer needs separate cleanup
            pane_needs_cleanup = false;

            const node = self.allocator.create(LayoutNode) catch return false;
            node.* = .{ .pane = 0 };
            tab.layout.root = node;
            tab.layout.next_split_id = 1;

            self.view.tabs.append(self.allocator, tab) catch return false;
            // Tab is now owned by tabs array, no longer needs cleanup
            tab_needs_cleanup = false;
            if (!self.appendTabMeta(tab_uuid, "attached")) {
                var failed_tab = self.view.tabs.pop().?;
                failed_tab.deinit();
                return false;
            }
            if (!self.appendTabFocusMemory()) {
                self.removeTabMeta(self.view.tabs.items.len - 1);
                var failed_tab = self.view.tabs.pop().?;
                failed_tab.deinit();
                return false;
            }
            self.setActiveTabIndex(self.view.tabs.items.len - 1);
            self.syncSessionTabAdded(tab_uuid, self.tabName(self.activeTabIndex()), pane.uuid);
            self.renderer.invalidate();
            self.force_full_render = true;
            return true;
        }
    }
    return false;
}
