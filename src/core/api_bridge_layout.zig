//! Layout-config Lua parsers: pane / split-tree / ratio decoding. Split from
//! `api_bridge.zig` (PLAN.md 2.3 spirit). `parseLayoutSplit` is the external
//! entry (re-exported from api_bridge so `parseLayoutDef`'s call is unchanged);
//! the rest are its internal helpers. Shared bridge string helpers are aliased
//! from api_bridge (circular import is fine in Zig).

const std = @import("std");
const zlua = @import("zlua");
const config = @import("config.zig");
const session_model = @import("session_model.zig");
const ab = @import("api_bridge.zig");

const Lua = zlua.Lua;
const log = std.log.scoped(.api_bridge);
const bridgeLuaString = ab.bridgeLuaString;
const dupeBridgeString = ab.dupeBridgeString;

/// Parse a layout pane from Lua table
fn parseLayoutPane(lua: *Lua, idx: i32, allocator: std.mem.Allocator) ?config.LayoutPaneDef {
    var pane = config.LayoutPaneDef{};

    // Parse cwd
    _ = lua.getField(idx, "cwd");
    if (lua.typeOf(-1) == .string) {
        const cwd_str = bridgeLuaString(lua, -1, "failed to read layout pane cwd");
        if (cwd_str) |cwd_val| {
            pane.cwd = dupeBridgeString(allocator, cwd_val, "failed to allocate layout pane cwd");
        }
    }
    lua.pop(1);

    // Parse command
    _ = lua.getField(idx, "command");
    if (lua.typeOf(-1) == .string) {
        const cmd_str = bridgeLuaString(lua, -1, "failed to read layout pane command");
        if (cmd_str) |cmd_val| {
            pane.command = dupeBridgeString(allocator, cmd_val, "failed to allocate layout pane command");
        }
    }
    lua.pop(1);

    return pane;
}

fn canonicalLayoutDir(lua: *Lua, idx: i32) []const u8 {
    _ = lua.getField(idx, "dir");
    defer lua.pop(1);

    const dir_str = lua.toString(-1) catch return "h";
    return if (session_model.isVerticalSplitDir(dir_str)) "v" else "h";
}

fn layoutNodeSize(lua: *Lua, idx: i32) ?u8 {
    _ = lua.getField(idx, "size");
    defer lua.pop(1);

    if (lua.typeOf(-1) != .number) return null;
    const raw = lua.toNumber(-1) catch return null;
    if (!std.math.isFinite(raw)) return null;
    return @intFromFloat(std.math.clamp(raw, 0, 100));
}

/// Ratio of the first child in [start..end] relative to the whole range.
/// Unspecified sizes share the remainder up to 100 equally, using one rule
/// for both the total and the first child so mixed specified/unspecified
/// layouts keep their proportions at every recursion depth.
fn layoutRatioFromChildSizes(lua: *Lua, idx: i32, start: i32, end: i32) f32 {
    const child_count: u32 = @intCast(end - start + 1);
    var specified_total: u32 = 0;
    var unspecified: u32 = 0;
    var first_size: ?u32 = null;

    var i = start;
    while (i <= end) : (i += 1) {
        _ = lua.rawGetIndex(idx, i);
        const size = layoutNodeSize(lua, -1);
        lua.pop(1);
        if (size) |s| {
            specified_total += s;
            if (i == start) first_size = s;
        } else {
            unspecified += 1;
        }
    }

    const unspec_share: u32 = if (unspecified > 0 and specified_total < 100)
        (100 - specified_total) / unspecified
    else
        0;
    const total = specified_total + unspec_share * unspecified;
    const equal_split = 1.0 / @as(f32, @floatFromInt(child_count));
    if (total == 0) return equal_split;

    const first = first_size orelse unspec_share;
    const ratio = @as(f32, @floatFromInt(first)) / @as(f32, @floatFromInt(total));
    // A zero-size or full-size first child would collapse a sibling to
    // nothing; fall back to an equal share instead of an invisible pane.
    if (ratio <= 0.0) return equal_split;
    if (ratio >= 1.0) return 1.0 - equal_split;
    return ratio;
}

fn explicitLayoutRatio(lua: *Lua, idx: i32) ?f32 {
    _ = lua.getField(idx, "ratio");
    defer lua.pop(1);

    if (lua.typeOf(-1) != .number) return null;
    const raw = lua.toNumber(-1) catch return null;
    if (!std.math.isFinite(raw)) return null;
    return @floatCast(std.math.clamp(raw, 0, 1));
}

fn parseLayoutSplitChildren(
    lua: *Lua,
    idx: i32,
    allocator: std.mem.Allocator,
    dir_tag: []const u8,
    start: i32,
    end: i32,
    ratio_override: ?f32,
) ?*config.LayoutSplitDef {
    if (start > end) return null;
    if (start == end) {
        _ = lua.rawGetIndex(idx, start);
        defer lua.pop(1);
        return parseLayoutSplit(lua, -1, allocator);
    }

    _ = lua.rawGetIndex(idx, start);
    const first_child = parseLayoutSplit(lua, -1, allocator) orelse {
        lua.pop(1);
        return null;
    };
    lua.pop(1);

    const second_child = if (start + 1 == end) blk: {
        _ = lua.rawGetIndex(idx, end);
        const child = parseLayoutSplit(lua, -1, allocator) orelse {
            lua.pop(1);
            first_child.deinit(allocator);
            allocator.destroy(first_child);
            return null;
        };
        lua.pop(1);
        break :blk child;
    } else parseLayoutSplitChildren(lua, idx, allocator, dir_tag, start + 1, end, null) orelse {
        first_child.deinit(allocator);
        allocator.destroy(first_child);
        return null;
    };

    const dir = dupeBridgeString(allocator, dir_tag, "failed to allocate layout split direction") orelse {
        first_child.deinit(allocator);
        allocator.destroy(first_child);
        second_child.deinit(allocator);
        allocator.destroy(second_child);
        return null;
    };

    const split = allocator.create(config.LayoutSplitDef) catch |err| {
        log.warn("failed to allocate layout split node: {}", .{err});
        allocator.free(dir);
        first_child.deinit(allocator);
        allocator.destroy(first_child);
        second_child.deinit(allocator);
        allocator.destroy(second_child);
        return null;
    };

    split.* = .{
        .split = .{
            .dir = dir,
            .ratio = ratio_override orelse layoutRatioFromChildSizes(lua, idx, start, end),
            .first = first_child,
            .second = second_child,
        },
    };

    return split;
}

/// Parse a layout split recursively from Lua table
pub fn parseLayoutSplit(lua: *Lua, idx: i32, allocator: std.mem.Allocator) ?*config.LayoutSplitDef {
    // Check if this is a split (has array elements) or a pane.
    const array_len = lua.rawLen(idx);

    if (array_len >= 2) {
        const dir_tag = canonicalLayoutDir(lua, idx);
        return parseLayoutSplitChildren(
            lua,
            idx,
            allocator,
            dir_tag,
            1,
            @intCast(array_len),
            explicitLayoutRatio(lua, idx),
        );
    }

    // This is a pane.
    const pane = parseLayoutPane(lua, idx, allocator) orelse return null;
    const split = allocator.create(config.LayoutSplitDef) catch |err| {
        log.warn("failed to allocate layout pane node: {}", .{err});
        var owned_pane = pane;
        owned_pane.deinit(allocator);
        return null;
    };
    split.* = .{ .pane = pane };
    return split;
}
