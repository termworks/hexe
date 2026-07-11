const std = @import("std");
const core = @import("core");
const session_model = core.session_model;

pub fn collectLayoutPaneUuids(
    allocator: std.mem.Allocator,
    node: ?*const session_model.SessionLayoutNode,
    out: *std.ArrayList([32]u8),
) !void {
    const root = node orelse return;
    switch (root.*) {
        .pane => |uuid| try out.append(allocator, uuid),
        .split => |split| {
            try collectLayoutPaneUuids(allocator, split.first, out);
            try collectLayoutPaneUuids(allocator, split.second, out);
        },
    }
}

pub fn countTemplateLeaves(value: std.json.Value) usize {
    const obj = switch (value) {
        .object => |o| o,
        else => return 0,
    };
    const type_val = obj.get("type") orelse return 0;
    const type_str = switch (type_val) {
        .string => |s| s,
        else => return 0,
    };
    if (std.mem.eql(u8, type_str, "pane")) return 1;
    if (std.mem.eql(u8, type_str, "split")) {
        const first = obj.get("first") orelse return 0;
        const second = obj.get("second") orelse return 0;
        return countTemplateLeaves(first) + countTemplateLeaves(second);
    }
    return 0;
}

pub fn collectTemplateCwds(
    value: std.json.Value,
    list: *std.ArrayList(?[]const u8),
    allocator: std.mem.Allocator,
) !void {
    const obj = switch (value) {
        .object => |o| o,
        else => return,
    };
    const type_val = obj.get("type") orelse return;
    const type_str = switch (type_val) {
        .string => |s| s,
        else => return,
    };
    if (std.mem.eql(u8, type_str, "pane")) {
        if (obj.get("cwd")) |cwd_val| {
            if (cwd_val == .string) {
                try list.append(allocator, cwd_val.string);
                return;
            }
        }
        try list.append(allocator, null);
    } else if (std.mem.eql(u8, type_str, "split")) {
        if (obj.get("first")) |first| try collectTemplateCwds(first, list, allocator);
        if (obj.get("second")) |second| try collectTemplateCwds(second, list, allocator);
    }
}

pub fn buildTemplateLayoutNode(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    pane_uuids: []const [32]u8,
    next_idx: *usize,
) !*session_model.SessionLayoutNode {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidNode,
    };
    const type_val = obj.get("type") orelse return error.InvalidNode;
    const type_str = switch (type_val) {
        .string => |s| s,
        else => return error.InvalidNode,
    };

    const node = try allocator.create(session_model.SessionLayoutNode);
    errdefer allocator.destroy(node);

    if (std.mem.eql(u8, type_str, "pane")) {
        if (next_idx.* >= pane_uuids.len) return error.InvalidNode;
        node.* = .{ .pane = pane_uuids[next_idx.*] };
        next_idx.* += 1;
        return node;
    }

    if (!std.mem.eql(u8, type_str, "split")) return error.InvalidNode;

    const dir_val = obj.get("dir") orelse return error.InvalidNode;
    const dir_str = switch (dir_val) {
        .string => |s| s,
        else => return error.InvalidNode,
    };
    const ratio_val = obj.get("ratio") orelse return error.InvalidNode;
    const ratio: f32 = switch (ratio_val) {
        .float => @floatCast(ratio_val.float),
        .integer => @floatFromInt(ratio_val.integer),
        else => return error.InvalidNode,
    };
    const first_val = obj.get("first") orelse return error.InvalidNode;
    const second_val = obj.get("second") orelse return error.InvalidNode;

    const first = try buildTemplateLayoutNode(allocator, first_val, pane_uuids, next_idx);
    errdefer {
        first.deinit(allocator);
        allocator.destroy(first);
    }
    const second = try buildTemplateLayoutNode(allocator, second_val, pane_uuids, next_idx);
    errdefer {
        second.deinit(allocator);
        allocator.destroy(second);
    }

    node.* = .{
        .split = .{
            .dir = if (session_model.isVerticalSplitDir(dir_str)) .vertical else .horizontal,
            .ratio = ratio,
            .first = first,
            .second = second,
        },
    };
    return node;
}
