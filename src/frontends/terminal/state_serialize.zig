const std = @import("std");

const layout_mod = @import("layout.zig");
const LayoutNode = layout_mod.LayoutNode;
const SplitDir = layout_mod.SplitDir;

const Pane = @import("pane.zig").Pane;

// Current serialization format version
const SERIALIZE_VERSION: u32 = 1;

/// Serialize entire mux state to JSON for detach.
pub fn serializeState(self: anytype) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(self.allocator);
    var writer = buf.writer(self.allocator);

    try writer.writeAll("{");

    // Version and timestamp for integrity checking
    try writer.print("\"version\":{d},", .{SERIALIZE_VERSION});
    try writer.print("\"timestamp\":{d},", .{std.time.timestamp()});

    // Mux UUID and session name (persistent identity).
    try writer.writeAll("\"uuid\":");
    const session_uuid = self.sessionUuid();
    try writeJsonString(writer, session_uuid[0..]);
    try writer.writeAll(",\"session_name\":");
    try writeJsonString(writer, self.sessionName());
    try writer.writeAll(",");
    try writer.print("\"tab_counter\":{d},", .{self.sessionTabCounter()});

    // Active tab/float.
    try writer.print("\"active_tab\":{d},", .{self.activeTabIndex()});
    if (self.activeFloatingIndex()) |af| {
        try writer.print("\"active_floating\":{d},", .{af});
    } else {
        try writer.writeAll("\"active_floating\":null,");
    }

    // Tabs.
    try writer.writeAll("\"tabs\":[");
    for (self.view.tabs.items, 0..) |*tab, ti| {
        const tab_uuid = self.tabUuid(ti) orelse continue;
        if (ti > 0) try writer.writeAll(",");
        try writer.writeAll("{");
        try writer.writeAll("\"uuid\":");
        try writeJsonString(writer, tab_uuid[0..]);
        try writer.writeAll(",\"name\":");
        try writeJsonString(writer, self.tabName(ti));
        try writer.writeAll(",");
        try writer.print("\"focused_split_id\":{d},", .{tab.layout.focused_split_id});
        try writer.print("\"next_split_id\":{d},", .{tab.layout.next_split_id});

        // Layout tree.
        try writer.writeAll("\"tree\":");
        if (tab.layout.root) |root| {
            try self.serializeLayoutNode(writer, root);
        } else {
            try writer.writeAll("null");
        }

        // Splits in this tab.
        try writer.writeAll(",\"splits\":[");
        var first_split = true;
        var pit = tab.layout.splits.iterator();
        while (pit.next()) |entry| {
            const pane = entry.value_ptr.*;
            if (!first_split) try writer.writeAll(",");
            first_split = false;
            try self.serializePane(writer, pane);
        }
        try writer.writeAll("]");

        try writer.writeAll("}");
    }
    try writer.writeAll("],");

    // Floats.
    try writer.writeAll("\"floats\":[");
    for (self.view.floats.items, 0..) |pane, fi| {
        if (fi > 0) try writer.writeAll(",");
        try self.serializePane(writer, pane);
    }
    try writer.writeAll("]");

    // Close main object, then add checksum
    try writer.writeAll("}");

    // Calculate checksum of the JSON content for integrity verification
    const content = buf.items;
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(content);
    const checksum = hasher.final();

    // Reopen the JSON to add checksum field
    // Remove the closing brace and add checksum
    _ = buf.pop();
    try writer.print(",\"_checksum\":{d}}}", .{checksum});

    return buf.toOwnedSlice(self.allocator);
}

pub fn serializeLayoutNode(self: anytype, writer: anytype, node: *LayoutNode) !void {
    _ = self;
    switch (node.*) {
        .pane => |id| {
            try writer.print("{{\"type\":\"pane\",\"id\":{d}}}", .{id});
        },
        .split => |split| {
            const dir_str: []const u8 = if (split.dir == .horizontal) "horizontal" else "vertical";
            try writer.print("{{\"type\":\"split\",\"dir\":\"{s}\",\"ratio\":{d},\"first\":", .{ dir_str, split.ratio });
            try serializeLayoutNode(undefined, writer, split.first);
            try writer.writeAll(",\"second\":");
            try serializeLayoutNode(undefined, writer, split.second);
            try writer.writeAll("}");
        },
    }
}

pub fn serializePane(self: anytype, writer: anytype, pane: *Pane) !void {
    _ = self;
    try writer.writeAll("{");
    try writer.print("\"id\":{d},", .{pane.id});
    try writer.writeAll("\"uuid\":");
    try writeJsonString(writer, pane.uuid[0..]);
    try writer.writeAll(",");
    try writer.print("\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},", .{ pane.x, pane.y, pane.width, pane.height });
    try writer.print("\"focused\":{},", .{pane.focused});
    try writer.print("\"floating\":{},", .{pane.floating});
    try writer.print("\"visible\":{},", .{pane.visible});
    try writer.print("\"tab_visible\":{d},", .{pane.tab_visible});
    try writer.print("\"float_key\":{d},", .{pane.float_key});
    try writer.print("\"border_x\":{d},\"border_y\":{d},\"border_w\":{d},\"border_h\":{d},", .{ pane.border_x, pane.border_y, pane.border_w, pane.border_h });
    try writer.print("\"float_width_pct\":{d},\"float_height_pct\":{d},", .{ pane.float_width_pct, pane.float_height_pct });
    try writer.print("\"float_pos_x_pct\":{d},\"float_pos_y_pct\":{d},", .{ pane.float_pos_x_pct, pane.float_pos_y_pct });
    try writer.print("\"float_pad_x\":{d},\"float_pad_y\":{d},", .{ pane.float_pad_x, pane.float_pad_y });
    try writer.print("\"is_pwd\":{},", .{pane.is_pwd});
    try writer.print("\"sticky\":{}", .{pane.sticky});
    if (pane.parent_tab) |pt| {
        try writer.print(",\"parent_tab\":{d}", .{pt});
    }
    if (pane.pwd_dir) |pwd| {
        try writer.writeAll(",\"pwd_dir\":");
        try writeJsonString(writer, pwd);
    }
    try writer.writeAll("}");
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.print("{f}", .{std.json.fmt(value, .{})});
}

pub fn deserializeLayoutNode(self: anytype, obj: std.json.ObjectMap) error{ OutOfMemory, InvalidNode }!*LayoutNode {
    const node = try self.allocator.create(LayoutNode);
    errdefer self.allocator.destroy(node);

    const node_type = stringField(obj, "type") orelse return error.InvalidNode;

    if (std.mem.eql(u8, node_type, "pane")) {
        const id: u16 = @intCast((obj.get("id") orelse return error.InvalidNode).integer);
        node.* = .{ .pane = id };
    } else if (std.mem.eql(u8, node_type, "split")) {
        const dir_str = stringField(obj, "dir") orelse return error.InvalidNode;
        const dir: SplitDir = if (std.mem.eql(u8, dir_str, "horizontal")) .horizontal else .vertical;
        const ratio_val = obj.get("ratio") orelse return error.InvalidNode;
        const ratio: f32 = switch (ratio_val) {
            .float => @floatCast(ratio_val.float),
            .integer => @floatFromInt(ratio_val.integer),
            else => return error.InvalidNode,
        };
        const first_obj = objectField(obj, "first") orelse return error.InvalidNode;
        const second_obj = objectField(obj, "second") orelse return error.InvalidNode;

        const first = try self.deserializeLayoutNode(first_obj);
        errdefer self.allocator.destroy(first);
        const second = try self.deserializeLayoutNode(second_obj);

        node.* = .{ .split = .{
            .dir = dir,
            .ratio = ratio,
            .first = first,
            .second = second,
        } };
    } else {
        return error.InvalidNode;
    }

    return node;
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn objectField(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .object => |o| o,
        else => null,
    };
}
