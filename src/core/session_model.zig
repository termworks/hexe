const std = @import("std");
const log = std.log.scoped(.session_model);

pub const SessionSplitDir = enum {
    horizontal,
    vertical,
};

pub const SessionPaneKind = enum {
    split,
    float,
};

pub const SessionLayoutNode = union(enum) {
    pane: [32]u8,
    split: Split,

    pub const Split = struct {
        dir: SessionSplitDir,
        ratio: f32,
        first: *SessionLayoutNode,
        second: *SessionLayoutNode,
    };

    pub fn deinit(self: *SessionLayoutNode, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .pane => {},
            .split => |*split| {
                split.first.deinit(allocator);
                allocator.destroy(split.first);
                split.second.deinit(allocator);
                allocator.destroy(split.second);
            },
        }
    }

    pub fn clone(self: *const SessionLayoutNode, allocator: std.mem.Allocator) !*SessionLayoutNode {
        const node = try allocator.create(SessionLayoutNode);
        errdefer allocator.destroy(node);

        switch (self.*) {
            .pane => |uuid| node.* = .{ .pane = uuid },
            .split => |split| {
                const first = try split.first.clone(allocator);
                errdefer {
                    first.deinit(allocator);
                    allocator.destroy(first);
                }
                const second = try split.second.clone(allocator);
                errdefer {
                    second.deinit(allocator);
                    allocator.destroy(second);
                }
                node.* = .{
                    .split = .{
                        .dir = split.dir,
                        .ratio = split.ratio,
                        .first = first,
                        .second = second,
                    },
                };
            },
        }

        return node;
    }
};

pub fn layoutNodeToJson(allocator: std.mem.Allocator, node: ?*const SessionLayoutNode) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var writer = buf.writer(allocator);
    if (node) |root| {
        try serializeLayoutNode(writer, root);
    } else {
        try writer.writeAll("null");
    }
    return buf.toOwnedSlice(allocator);
}

pub fn layoutNodeFromJson(allocator: std.mem.Allocator, json: []const u8) !?*SessionLayoutNode {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    return switch (parsed.value) {
        .null => null,
        else => try parseCanonicalLayoutNode(allocator, parsed.value),
    };
}

fn uuidsEqual(a: [32]u8, b: [32]u8) bool {
    return std.mem.eql(u8, a[0..], b[0..]);
}

pub fn layoutContainsPaneUuid(node: *const SessionLayoutNode, pane_uuid: [32]u8) bool {
    return switch (node.*) {
        .pane => |uuid| uuidsEqual(uuid, pane_uuid),
        .split => |split| layoutContainsPaneUuid(split.first, pane_uuid) or layoutContainsPaneUuid(split.second, pane_uuid),
    };
}

pub fn splitPaneInLayout(
    allocator: std.mem.Allocator,
    node: *SessionLayoutNode,
    source_pane_uuid: [32]u8,
    new_pane_uuid: [32]u8,
    dir: SessionSplitDir,
) !bool {
    switch (node.*) {
        .pane => |uuid| {
            if (!uuidsEqual(uuid, source_pane_uuid)) return false;

            const first = try allocator.create(SessionLayoutNode);
            errdefer allocator.destroy(first);
            first.* = .{ .pane = uuid };

            const second = try allocator.create(SessionLayoutNode);
            errdefer allocator.destroy(second);
            second.* = .{ .pane = new_pane_uuid };

            node.* = .{
                .split = .{
                    .dir = dir,
                    .ratio = 0.5,
                    .first = first,
                    .second = second,
                },
            };
            return true;
        },
        .split => |*split| {
            if (try splitPaneInLayout(allocator, split.first, source_pane_uuid, new_pane_uuid, dir)) return true;
            return try splitPaneInLayout(allocator, split.second, source_pane_uuid, new_pane_uuid, dir);
        },
    }
}

pub fn replacePaneUuidInLayout(
    node: *SessionLayoutNode,
    old_pane_uuid: [32]u8,
    new_pane_uuid: [32]u8,
) bool {
    switch (node.*) {
        .pane => |*uuid| {
            if (!uuidsEqual(uuid.*, old_pane_uuid)) return false;
            uuid.* = new_pane_uuid;
            return true;
        },
        .split => |*split| {
            if (replacePaneUuidInLayout(split.first, old_pane_uuid, new_pane_uuid)) return true;
            return replacePaneUuidInLayout(split.second, old_pane_uuid, new_pane_uuid);
        },
    }
}

const RemoveCloneResult = struct {
    found: bool,
    node: ?*SessionLayoutNode,
};

fn freeLayoutClone(allocator: std.mem.Allocator, node: ?*SessionLayoutNode) void {
    if (node) |root| {
        root.deinit(allocator);
        allocator.destroy(root);
    }
}

fn cloneWithoutPane(
    allocator: std.mem.Allocator,
    node: *const SessionLayoutNode,
    pane_uuid: [32]u8,
) !RemoveCloneResult {
    switch (node.*) {
        .pane => |uuid| {
            if (uuidsEqual(uuid, pane_uuid)) {
                return .{ .found = true, .node = null };
            }
            return .{ .found = false, .node = try node.clone(allocator) };
        },
        .split => |split| {
            const first = try cloneWithoutPane(allocator, split.first, pane_uuid);
            errdefer freeLayoutClone(allocator, first.node);

            const second = try cloneWithoutPane(allocator, split.second, pane_uuid);
            errdefer freeLayoutClone(allocator, second.node);

            if (first.node == null and second.node == null) {
                return .{ .found = first.found or second.found, .node = null };
            }
            if (first.node == null) {
                return .{ .found = first.found or second.found, .node = second.node };
            }
            if (second.node == null) {
                return .{ .found = first.found or second.found, .node = first.node };
            }

            const out = try allocator.create(SessionLayoutNode);
            errdefer allocator.destroy(out);
            out.* = .{
                .split = .{
                    .dir = split.dir,
                    .ratio = split.ratio,
                    .first = first.node.?,
                    .second = second.node.?,
                },
            };
            return .{ .found = first.found or second.found, .node = out };
        },
    }
}

pub fn removePaneFromLayout(
    allocator: std.mem.Allocator,
    root: *?*SessionLayoutNode,
    pane_uuid: [32]u8,
) !bool {
    const current = root.* orelse return false;
    const result = try cloneWithoutPane(allocator, current, pane_uuid);

    if (!result.found) {
        freeLayoutClone(allocator, result.node);
        return false;
    }

    current.deinit(allocator);
    allocator.destroy(current);
    root.* = result.node;
    return true;
}

pub fn setSplitRatioByAnchors(
    node: *SessionLayoutNode,
    first_anchor_uuid: [32]u8,
    second_anchor_uuid: [32]u8,
    target_ratio: f32,
) bool {
    switch (node.*) {
        .pane => return false,
        .split => |*split| {
            if (setSplitRatioByAnchors(split.first, first_anchor_uuid, second_anchor_uuid, target_ratio)) return true;
            if (setSplitRatioByAnchors(split.second, first_anchor_uuid, second_anchor_uuid, target_ratio)) return true;

            const first_has_first = layoutContainsPaneUuid(split.first, first_anchor_uuid);
            const first_has_second = layoutContainsPaneUuid(split.first, second_anchor_uuid);
            const second_has_first = layoutContainsPaneUuid(split.second, first_anchor_uuid);
            const second_has_second = layoutContainsPaneUuid(split.second, second_anchor_uuid);

            if (!((first_has_first and second_has_second) or (first_has_second and second_has_first))) {
                return false;
            }

            var ratio = target_ratio;
            if (ratio < 0.1) ratio = 0.1;
            if (ratio > 0.9) ratio = 0.9;
            split.ratio = ratio;
            return true;
        },
    }
}

pub const SessionTab = struct {
    uuid: [32]u8,
    name: []u8,
    root: ?*SessionLayoutNode = null,
    focused_pane_uuid: ?[32]u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SessionTab) void {
        if (self.root) |root| {
            root.deinit(self.allocator);
            self.allocator.destroy(root);
        }
        self.allocator.free(self.name);
    }

    pub fn clone(self: *const SessionTab, allocator: std.mem.Allocator) !SessionTab {
        return .{
            .uuid = self.uuid,
            .name = try allocator.dupe(u8, self.name),
            .root = if (self.root) |root| try root.clone(allocator) else null,
            .focused_pane_uuid = self.focused_pane_uuid,
            .allocator = allocator,
        };
    }
};

pub const SessionPane = struct {
    uuid: [32]u8,
    kind: SessionPaneKind,
    parent_tab: ?usize = null,
    sticky: bool = false,
    is_pwd: bool = false,
    float_key: u8 = 0,
};

pub const SessionFloat = struct {
    pane_uuid: [32]u8,
    parent_tab: ?usize = null,
    visible: bool = true,
    tab_visible: u64 = 0,
    sticky: bool = false,
    is_pwd: bool = false,
    float_key: u8 = 0,
    width_pct: u8 = 60,
    height_pct: u8 = 60,
    pos_x_pct: u8 = 50,
    pos_y_pct: u8 = 50,
    pad_x: u8 = 1,
    pad_y: u8 = 0,
};

pub const SessionSnapshot = struct {
    allocator: std.mem.Allocator,
    uuid: [32]u8,
    session_name: []u8,
    base_root: ?[]u8 = null,
    tab_counter: usize,
    active_tab: usize,
    active_float_uuid: ?[32]u8 = null,
    focused_pane_uuid: ?[32]u8 = null,
    tabs: std.ArrayList(SessionTab),
    panes: std.AutoHashMap([32]u8, SessionPane),
    floats: std.ArrayList(SessionFloat),

    pub fn initMinimal(allocator: std.mem.Allocator, uuid: [32]u8, session_name: []const u8) !SessionSnapshot {
        return .{
            .allocator = allocator,
            .uuid = uuid,
            .session_name = try allocator.dupe(u8, session_name),
            .tab_counter = 0,
            .active_tab = 0,
            .tabs = .empty,
            .panes = std.AutoHashMap([32]u8, SessionPane).init(allocator),
            .floats = .empty,
        };
    }

    pub fn deinit(self: *SessionSnapshot) void {
        for (self.tabs.items) |*tab| tab.deinit();
        self.tabs.deinit(self.allocator);
        self.panes.deinit();
        self.floats.deinit(self.allocator);
        if (self.base_root) |root| self.allocator.free(root);
        self.allocator.free(self.session_name);
    }

    pub fn clone(self: *const SessionSnapshot, allocator: std.mem.Allocator) !SessionSnapshot {
        var tabs: std.ArrayList(SessionTab) = .empty;
        errdefer {
            for (tabs.items) |*tab| tab.deinit();
            tabs.deinit(allocator);
        }
        for (self.tabs.items) |tab| {
            try tabs.append(allocator, try tab.clone(allocator));
        }

        var panes = std.AutoHashMap([32]u8, SessionPane).init(allocator);
        errdefer panes.deinit();
        var pane_iter = self.panes.iterator();
        while (pane_iter.next()) |entry| {
            try panes.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        var floats: std.ArrayList(SessionFloat) = .empty;
        errdefer floats.deinit(allocator);
        try floats.appendSlice(allocator, self.floats.items);

        return .{
            .allocator = allocator,
            .uuid = self.uuid,
            .session_name = try allocator.dupe(u8, self.session_name),
            .base_root = if (self.base_root) |root| try allocator.dupe(u8, root) else null,
            .tab_counter = self.tab_counter,
            .active_tab = self.active_tab,
            .active_float_uuid = self.active_float_uuid,
            .focused_pane_uuid = self.focused_pane_uuid,
            .tabs = tabs,
            .panes = panes,
            .floats = floats,
        };
    }

    pub fn fromJson(allocator: std.mem.Allocator, json: []const u8) !SessionSnapshot {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return error.InvalidStateJson,
        };

        if (root.get("panes") != null) {
            return fromCanonicalRoot(allocator, root);
        }
        return fromMuxRoot(allocator, root);
    }

    pub fn toJson(self: *const SessionSnapshot, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        var writer = buf.writer(allocator);

        try writer.writeAll("{");
        try writer.writeAll("\"version\":1,");
        try writer.writeAll("\"uuid\":");
        try writeJsonString(writer, self.uuid[0..]);
        try writer.writeAll(",\"session_name\":");
        try writeJsonString(writer, self.session_name);
        try writer.writeAll(",\"base_root\":");
        if (self.base_root) |root| {
            try writeJsonString(writer, root);
        } else {
            try writer.writeAll("null");
        }
        try writer.print(",\"tab_counter\":{d}", .{self.tab_counter});
        try writer.print(",\"active_tab\":{d}", .{self.active_tab});
        try writer.writeAll(",\"active_float_uuid\":");
        if (self.active_float_uuid) |uuid| {
            try writeJsonString(writer, uuid[0..]);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"focused_pane_uuid\":");
        if (self.focused_pane_uuid) |uuid| {
            try writeJsonString(writer, uuid[0..]);
        } else {
            try writer.writeAll("null");
        }

        try writer.writeAll(",\"tabs\":[");
        for (self.tabs.items, 0..) |tab, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"uuid\":");
            try writeJsonString(writer, tab.uuid[0..]);
            try writer.writeAll(",\"name\":");
            try writeJsonString(writer, tab.name);
            try writer.writeAll(",\"focused_pane_uuid\":");
            if (tab.focused_pane_uuid) |uuid| {
                try writeJsonString(writer, uuid[0..]);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(",\"root\":");
            if (tab.root) |root| {
                try serializeLayoutNode(writer, root);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll("}");
        }
        try writer.writeAll("]");

        try writer.writeAll(",\"panes\":[");
        var pane_iter = self.panes.iterator();
        var pane_index: usize = 0;
        while (pane_iter.next()) |entry| {
            if (pane_index > 0) try writer.writeAll(",");
            pane_index += 1;
            const pane = entry.value_ptr.*;
            try writer.writeAll("{\"uuid\":");
            try writeJsonString(writer, pane.uuid[0..]);
            try writer.writeAll(",\"kind\":");
            try writeJsonString(writer, @tagName(pane.kind));
            try writer.writeAll(",\"parent_tab\":");
            if (pane.parent_tab) |parent_tab| {
                try writer.print("{d}", .{parent_tab});
            } else {
                try writer.writeAll("null");
            }
            try writer.print(",\"sticky\":{}", .{pane.sticky});
            try writer.print(",\"is_pwd\":{}", .{pane.is_pwd});
            try writer.print(",\"float_key\":{d}", .{pane.float_key});
            try writer.writeAll("}");
        }
        try writer.writeAll("]");

        try writer.writeAll(",\"floats\":[");
        for (self.floats.items, 0..) |float_state, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"pane_uuid\":");
            try writeJsonString(writer, float_state.pane_uuid[0..]);
            try writer.writeAll(",\"parent_tab\":");
            if (float_state.parent_tab) |parent_tab| {
                try writer.print("{d}", .{parent_tab});
            } else {
                try writer.writeAll("null");
            }
            try writer.print(",\"visible\":{}", .{float_state.visible});
            try writer.print(",\"tab_visible\":{d}", .{float_state.tab_visible});
            try writer.print(",\"sticky\":{}", .{float_state.sticky});
            try writer.print(",\"is_pwd\":{}", .{float_state.is_pwd});
            try writer.print(",\"float_key\":{d}", .{float_state.float_key});
            try writer.print(",\"width_pct\":{d}", .{float_state.width_pct});
            try writer.print(",\"height_pct\":{d}", .{float_state.height_pct});
            try writer.print(",\"pos_x_pct\":{d}", .{float_state.pos_x_pct});
            try writer.print(",\"pos_y_pct\":{d}", .{float_state.pos_y_pct});
            try writer.print(",\"pad_x\":{d}", .{float_state.pad_x});
            try writer.print(",\"pad_y\":{d}", .{float_state.pad_y});
            try writer.writeAll("}");
        }
        try writer.writeAll("]");

        try writer.writeAll("}");
        return buf.toOwnedSlice(allocator);
    }

    pub fn fromMuxJson(allocator: std.mem.Allocator, mux_state_json: []const u8) !SessionSnapshot {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, mux_state_json, .{});
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return error.InvalidStateJson,
        };

        return fromMuxRoot(allocator, root);
    }
};

fn fromMuxRoot(allocator: std.mem.Allocator, root: std.json.ObjectMap) !SessionSnapshot {
    const uuid_str = stringField(root, "uuid") orelse return error.InvalidStateJson;
    const session_name = stringField(root, "session_name") orelse return error.InvalidStateJson;
    const tabs_val = root.get("tabs") orelse return error.InvalidStateJson;
    const floats_val = root.get("floats") orelse return error.InvalidStateJson;

    var snapshot = try SessionSnapshot.initMinimal(allocator, try parseUuid(uuid_str), session_name);
    errdefer snapshot.deinit();

    if (stringField(root, "base_root")) |base_root| {
        snapshot.base_root = try allocator.dupe(u8, base_root);
    }
    snapshot.tab_counter = intField(root, "tab_counter") orelse 0;
    snapshot.active_tab = intField(root, "active_tab") orelse 0;

    const tabs = switch (tabs_val) {
        .array => |arr| arr,
        else => return error.InvalidStateJson,
    };
    const floats = switch (floats_val) {
        .array => |arr| arr,
        else => return error.InvalidStateJson,
    };

    for (tabs.items, 0..) |tab_val, tab_idx| {
        const tab_obj = switch (tab_val) {
            .object => |obj| obj,
            else => return error.InvalidStateJson,
        };

        var id_to_uuid = std.AutoHashMap(u16, [32]u8).init(allocator);
        defer id_to_uuid.deinit();

        const splits_val = tab_obj.get("splits") orelse return error.InvalidStateJson;
        const splits = switch (splits_val) {
            .array => |arr| arr,
            else => return error.InvalidStateJson,
        };
        for (splits.items) |split_val| {
            const split_obj = switch (split_val) {
                .object => |obj| obj,
                else => return error.InvalidStateJson,
            };

            const pane_uuid = try parseUuid(stringField(split_obj, "uuid") orelse return error.InvalidStateJson);
            const split_id: u16 = @intCast(intField(split_obj, "id") orelse return error.InvalidStateJson);
            try id_to_uuid.put(split_id, pane_uuid);
            try snapshot.panes.put(pane_uuid, .{
                .uuid = pane_uuid,
                .kind = .split,
                .parent_tab = tab_idx,
            });
        }

        const tab_uuid = try parseUuid(stringField(tab_obj, "uuid") orelse return error.InvalidStateJson);
        var tab = SessionTab{
            .uuid = tab_uuid,
            .name = try allocator.dupe(u8, stringField(tab_obj, "name") orelse return error.InvalidStateJson),
            .allocator = allocator,
        };
        errdefer tab.deinit();

        if (intField(tab_obj, "focused_split_id")) |focused_split_id| {
            tab.focused_pane_uuid = id_to_uuid.get(@intCast(focused_split_id));
        }

        if (tab_obj.get("tree")) |tree_val| {
            if (tree_val != .null) {
                tab.root = try parseLegacyLayoutNode(allocator, tree_val, &id_to_uuid);
            }
        }

        try snapshot.tabs.append(allocator, tab);
    }

    for (floats.items, 0..) |float_val, float_idx| {
        const float_obj = switch (float_val) {
            .object => |obj| obj,
            else => return error.InvalidStateJson,
        };

        const pane_uuid = try parseUuid(stringField(float_obj, "uuid") orelse return error.InvalidStateJson);
        const parent_tab_int = intField(float_obj, "parent_tab");
        const float_state = SessionFloat{
            .pane_uuid = pane_uuid,
            .parent_tab = if (parent_tab_int) |idx| @intCast(idx) else null,
            .visible = boolField(float_obj, "visible") orelse true,
            .tab_visible = if (intField(float_obj, "tab_visible")) |mask| @intCast(mask) else 0,
            .sticky = boolField(float_obj, "sticky") orelse false,
            .is_pwd = boolField(float_obj, "is_pwd") orelse false,
            .float_key = if (intField(float_obj, "float_key")) |key| @intCast(key) else 0,
            .width_pct = if (intField(float_obj, "float_width_pct")) |v| @intCast(v) else 60,
            .height_pct = if (intField(float_obj, "float_height_pct")) |v| @intCast(v) else 60,
            .pos_x_pct = if (intField(float_obj, "float_pos_x_pct")) |v| @intCast(v) else 50,
            .pos_y_pct = if (intField(float_obj, "float_pos_y_pct")) |v| @intCast(v) else 50,
            .pad_x = if (intField(float_obj, "float_pad_x")) |v| @intCast(v) else 1,
            .pad_y = if (intField(float_obj, "float_pad_y")) |v| @intCast(v) else 0,
        };

        try snapshot.floats.append(allocator, float_state);
        try snapshot.panes.put(pane_uuid, .{
            .uuid = pane_uuid,
            .kind = .float,
            .parent_tab = float_state.parent_tab,
            .sticky = float_state.sticky,
            .is_pwd = float_state.is_pwd,
            .float_key = float_state.float_key,
        });

        if (intField(root, "active_floating")) |active_float_idx| {
            if (@as(usize, @intCast(active_float_idx)) == float_idx) {
                snapshot.active_float_uuid = pane_uuid;
            }
        }
    }

    if (snapshot.active_tab >= snapshot.tabs.items.len and snapshot.tabs.items.len > 0) {
        snapshot.active_tab = 0;
    }

    if (snapshot.active_float_uuid) |active_float_uuid| {
        snapshot.focused_pane_uuid = active_float_uuid;
    } else if (snapshot.tabs.items.len > 0) {
        snapshot.focused_pane_uuid = snapshot.tabs.items[snapshot.active_tab].focused_pane_uuid;
    }

    return snapshot;
}

fn fromCanonicalRoot(allocator: std.mem.Allocator, root: std.json.ObjectMap) !SessionSnapshot {
    const uuid_str = stringField(root, "uuid") orelse return error.InvalidStateJson;
    const session_name = stringField(root, "session_name") orelse return error.InvalidStateJson;
    const tabs_val = root.get("tabs") orelse return error.InvalidStateJson;
    const panes_val = root.get("panes") orelse return error.InvalidStateJson;
    const floats_val = root.get("floats") orelse return error.InvalidStateJson;

    var snapshot = try SessionSnapshot.initMinimal(allocator, try parseUuid(uuid_str), session_name);
    errdefer snapshot.deinit();

    if (stringField(root, "base_root")) |base_root| {
        snapshot.base_root = try allocator.dupe(u8, base_root);
    }
    snapshot.tab_counter = intField(root, "tab_counter") orelse 0;
    snapshot.active_tab = intField(root, "active_tab") orelse 0;
    snapshot.active_float_uuid = if (nullableUuidField(root, "active_float_uuid")) |uuid| uuid else null;
    snapshot.focused_pane_uuid = if (nullableUuidField(root, "focused_pane_uuid")) |uuid| uuid else null;

    const tabs = switch (tabs_val) {
        .array => |arr| arr,
        else => return error.InvalidStateJson,
    };
    for (tabs.items) |tab_val| {
        const tab_obj = switch (tab_val) {
            .object => |obj| obj,
            else => return error.InvalidStateJson,
        };
        var tab = SessionTab{
            .uuid = try parseUuid(stringField(tab_obj, "uuid") orelse return error.InvalidStateJson),
            .name = try allocator.dupe(u8, stringField(tab_obj, "name") orelse return error.InvalidStateJson),
            .focused_pane_uuid = if (nullableUuidField(tab_obj, "focused_pane_uuid")) |uuid| uuid else null,
            .allocator = allocator,
        };
        errdefer tab.deinit();
        if (tab_obj.get("root")) |root_val| {
            if (root_val != .null) {
                tab.root = try parseCanonicalLayoutNode(allocator, root_val);
            }
        }
        try snapshot.tabs.append(allocator, tab);
    }

    const panes = switch (panes_val) {
        .array => |arr| arr,
        else => return error.InvalidStateJson,
    };
    for (panes.items) |pane_val| {
        const pane_obj = switch (pane_val) {
            .object => |obj| obj,
            else => return error.InvalidStateJson,
        };
        const uuid = try parseUuid(stringField(pane_obj, "uuid") orelse return error.InvalidStateJson);
        const kind_str = stringField(pane_obj, "kind") orelse return error.InvalidStateJson;
        try snapshot.panes.put(uuid, .{
            .uuid = uuid,
            .kind = if (std.mem.eql(u8, kind_str, "float")) .float else .split,
            .parent_tab = intField(pane_obj, "parent_tab"),
            .sticky = boolField(pane_obj, "sticky") orelse false,
            .is_pwd = boolField(pane_obj, "is_pwd") orelse false,
            .float_key = if (intField(pane_obj, "float_key")) |key| @intCast(key) else 0,
        });
    }

    const floats = switch (floats_val) {
        .array => |arr| arr,
        else => return error.InvalidStateJson,
    };
    for (floats.items) |float_val| {
        const float_obj = switch (float_val) {
            .object => |obj| obj,
            else => return error.InvalidStateJson,
        };
        try snapshot.floats.append(allocator, .{
            .pane_uuid = try parseUuid(stringField(float_obj, "pane_uuid") orelse return error.InvalidStateJson),
            .parent_tab = intField(float_obj, "parent_tab"),
            .visible = boolField(float_obj, "visible") orelse true,
            .tab_visible = if (intField(float_obj, "tab_visible")) |mask| @intCast(mask) else 0,
            .sticky = boolField(float_obj, "sticky") orelse false,
            .is_pwd = boolField(float_obj, "is_pwd") orelse false,
            .float_key = if (intField(float_obj, "float_key")) |key| @intCast(key) else 0,
            .width_pct = if (intField(float_obj, "width_pct")) |v| @intCast(v) else 60,
            .height_pct = if (intField(float_obj, "height_pct")) |v| @intCast(v) else 60,
            .pos_x_pct = if (intField(float_obj, "pos_x_pct")) |v| @intCast(v) else 50,
            .pos_y_pct = if (intField(float_obj, "pos_y_pct")) |v| @intCast(v) else 50,
            .pad_x = if (intField(float_obj, "pad_x")) |v| @intCast(v) else 1,
            .pad_y = if (intField(float_obj, "pad_y")) |v| @intCast(v) else 0,
        });
    }

    if (snapshot.active_tab >= snapshot.tabs.items.len and snapshot.tabs.items.len > 0) {
        snapshot.active_tab = 0;
    }

    if (snapshot.focused_pane_uuid == null) {
        if (snapshot.active_float_uuid) |uuid| {
            snapshot.focused_pane_uuid = uuid;
        } else if (snapshot.tabs.items.len > 0) {
            snapshot.focused_pane_uuid = snapshot.tabs.items[snapshot.active_tab].focused_pane_uuid;
        }
    }

    return snapshot;
}

fn serializeLayoutNode(writer: anytype, node: *const SessionLayoutNode) !void {
    switch (node.*) {
        .pane => |uuid| {
            try writer.writeAll("{\"type\":\"pane\",\"uuid\":");
            try writeJsonString(writer, uuid[0..]);
            try writer.writeAll("}");
        },
        .split => |split| {
            try writer.writeAll("{\"type\":\"split\",\"dir\":");
            try writeJsonString(writer, @tagName(split.dir));
            try writer.print(",\"ratio\":{d},\"first\":", .{split.ratio});
            try serializeLayoutNode(writer, split.first);
            try writer.writeAll(",\"second\":");
            try serializeLayoutNode(writer, split.second);
            try writer.writeAll("}");
        },
    }
}

fn parseLegacyLayoutNode(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    id_to_uuid: *const std.AutoHashMap(u16, [32]u8),
) !*SessionLayoutNode {
    return parseLayoutNode(allocator, value, id_to_uuid, true);
}

fn parseCanonicalLayoutNode(allocator: std.mem.Allocator, value: std.json.Value) !*SessionLayoutNode {
    return parseLayoutNode(allocator, value, null, false);
}

fn parseLayoutNode(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    id_to_uuid: ?*const std.AutoHashMap(u16, [32]u8),
    legacy: bool,
) !*SessionLayoutNode {
    const obj = switch (value) {
        .object => |obj| obj,
        else => return error.InvalidStateJson,
    };

    const node_type = stringField(obj, "type") orelse return error.InvalidStateJson;
    const node = try allocator.create(SessionLayoutNode);
    errdefer allocator.destroy(node);

    if (std.mem.eql(u8, node_type, "pane")) {
        const pane_uuid = if (legacy) blk: {
            const pane_id: u16 = @intCast(intField(obj, "id") orelse return error.InvalidStateJson);
            break :blk (id_to_uuid orelse return error.InvalidStateJson).get(pane_id) orelse return error.InvalidStateJson;
        } else try parseUuid(stringField(obj, "uuid") orelse return error.InvalidStateJson);
        node.* = .{ .pane = pane_uuid };
        return node;
    }

    if (std.mem.eql(u8, node_type, "split")) {
        const dir_str = stringField(obj, "dir") orelse return error.InvalidStateJson;
        const first_val = obj.get("first") orelse return error.InvalidStateJson;
        const second_val = obj.get("second") orelse return error.InvalidStateJson;
        const first = try parseLayoutNode(allocator, first_val, id_to_uuid, legacy);
        errdefer {
            first.deinit(allocator);
            allocator.destroy(first);
        }
        const second = try parseLayoutNode(allocator, second_val, id_to_uuid, legacy);
        errdefer {
            second.deinit(allocator);
            allocator.destroy(second);
        }

        node.* = .{
            .split = .{
                .dir = if (std.mem.eql(u8, dir_str, "horizontal")) .horizontal else .vertical,
                .ratio = floatField(obj, "ratio") orelse 0.5,
                .first = first,
                .second = second,
            },
        };
        return node;
    }

    return error.InvalidStateJson;
}

fn parseUuid(value: []const u8) ![32]u8 {
    if (value.len != 32) return error.InvalidStateJson;
    var out: [32]u8 = undefined;
    @memcpy(&out, value[0..32]);
    return out;
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn nullableUuidField(obj: std.json.ObjectMap, key: []const u8) ?[32]u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .string => |s| parseUuid(s) catch |err| {
            log.warn("failed to parse nullable uuid field '{s}': {}", .{ key, err });
            return null;
        },
        else => null,
    };
}

fn intField(obj: std.json.ObjectMap, key: []const u8) ?usize {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

fn floatField(obj: std.json.ObjectMap, key: []const u8) ?f32 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn boolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.print("{f}", .{std.json.fmt(value, .{})});
}
