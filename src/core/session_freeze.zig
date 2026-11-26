//! Shared session-to-Lua serializer and layout saver.
//!
//! Used by both `hexe layout save` (CLI) and the native in-mux `layout.save`
//! action so saved sessions are always valid, rich, human-readable `.hexe.lua`
//! files that round-trip cleanly through `session_config.parseSessionLuaOnce`.

const std = @import("std");
const session_config = @import("session_config.zig");
const config = @import("config.zig");

pub const SaveScope = enum {
    local,
    global,
    both,
};

pub const FreezeNode = union(enum) {
    pane: struct {
        cwd: ?[]const u8 = null,
    },
    split: struct {
        dir: []const u8, // "horizontal" or "vertical"
        ratio: f32 = 0.5,
        first: *const FreezeNode,
        second: *const FreezeNode,
    },
};

pub const FreezeTab = struct {
    name: []const u8,
    root: ?*const FreezeNode = null,
};

pub const FreezeFloat = struct {
    name: []const u8,
    key: u8 = 0,
    title: ?[]const u8 = null,
    command: ?[]const u8 = null,
    width_pct: ?u8 = null,
    height_pct: ?u8 = null,
    pos_x_pct: ?u8 = null,
    pos_y_pct: ?u8 = null,
    attributes: config.FloatAttributes = .{},
};

pub const FreezeSession = struct {
    name: []const u8,
    root: []const u8,
    tabs: []const FreezeTab = &.{},
    floats: []const FreezeFloat = &.{},
};

pub const SaveResult = struct {
    /// Path to the `.lua` file that was written (owned by allocator).
    written_path: []u8,
    /// Layout name registered / written (owned by allocator).
    name: []u8,
    scope: SaveScope,

    pub fn deinit(self: *SaveResult, allocator: std.mem.Allocator) void {
        allocator.free(self.written_path);
        allocator.free(self.name);
        self.* = undefined;
    }
};

fn writeLuaEscaped(writer: anytype, value: []const u8) !void {
    for (value) |ch| {
        switch (ch) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(ch),
        }
    }
}

fn writeLuaStringField(writer: anytype, prefix: []const u8, value: []const u8, suffix: []const u8) !void {
    try writer.writeAll(prefix);
    try writeLuaEscaped(writer, value);
    try writer.writeAll(suffix);
}

fn writeIndent(writer: anytype, level: usize) !void {
    var i: usize = 0;
    while (i < level) : (i += 1) {
        try writer.writeAll("  ");
    }
}

fn writeSplitTree(
    writer: anytype,
    node: *const FreezeNode,
    root_cwd: []const u8,
    indent: usize,
    size: ?u8,
) anyerror!void {
    switch (node.*) {
        .pane => |p| {
            const diff_cwd = if (p.cwd) |c| c.len > 0 and !std.mem.eql(u8, c, root_cwd) else false;
            if (size == null and !diff_cwd) {
                try writer.writeAll("hexe.pane()");
                return;
            }
            try writer.writeAll("hexe.pane({");
            if (size) |s| try writer.print(" size = {d},", .{s});
            if (diff_cwd) {
                try writeLuaStringField(writer, " cwd = \"", p.cwd.?, "\",");
            }
            try writer.writeAll(" })");
        },
        .split => |sp| {
            const dir = if (std.mem.eql(u8, sp.dir, "vertical") or std.mem.eql(u8, sp.dir, "v"))
                "vertical"
            else
                "horizontal";
            try writer.print("hexe.split(\"{s}\", {{\n", .{dir});

            const clamped_ratio: f64 = std.math.clamp(@as(f64, sp.ratio), 0.05, 0.95);
            const size_first: u8 = @intFromFloat(@round(clamped_ratio * 100.0));
            const size_second: u8 = 100 - size_first;

            try writeIndent(writer, indent + 1);
            try writeSplitTree(writer, sp.first, root_cwd, indent + 1, size_first);
            try writer.writeAll(",\n");

            try writeIndent(writer, indent + 1);
            try writeSplitTree(writer, sp.second, root_cwd, indent + 1, size_second);
            try writer.writeAll(",\n");

            try writeIndent(writer, indent);
            if (size) |s| {
                try writer.print("}}, {{ size = {d} }})", .{s});
            } else {
                try writer.writeAll("})");
            }
        },
    }
}

fn hasAnyTrueAttr(a: config.FloatAttributes) bool {
    return a.per_cwd or a.per_git or a.global or a.exclusive or a.sticky or
        a.destroy or a.navigatable or a.isolated or a.inherit_env;
}

/// Serialize a `FreezeSession` into a canonical `.hexe.lua` source file.
pub fn writeSessionLua(allocator: std.mem.Allocator, session: FreezeSession) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.writeAll("local hexe = require(\"hexe\")\n\n");
    try writeLuaStringField(writer, "hexe.layout(\"", session.name, "\", {\n");
    if (session.root.len > 0) {
        try writeLuaStringField(writer, "  root = \"", session.root, "\",\n");
    }

    if (session.tabs.len > 0) {
        try writer.writeAll("  tabs = {\n");
        for (session.tabs, 0..) |tab, ti| {
            const tab_name = if (tab.name.len > 0) tab.name else "tab";
            try writeLuaStringField(writer, "    hexe.tab(\"", tab_name, "\", {\n");
            try writer.writeAll("      root = ");
            if (tab.root) |root| {
                try writeSplitTree(writer, root, session.root, 3, null);
            } else {
                try writer.writeAll("hexe.pane()");
            }
            try writer.writeAll(",\n    })");
            if (ti + 1 < session.tabs.len) try writer.writeAll(",");
            try writer.writeAll("\n");
        }
        try writer.writeAll("  },\n");
    }

    if (session.floats.len > 0) {
        try writer.writeAll("  floats = {\n");
        for (session.floats, 0..) |fl, fi| {
            var fallback_name_buf: [32]u8 = undefined;
            const fname = if (fl.name.len > 0)
                fl.name
            else
                std.fmt.bufPrint(&fallback_name_buf, "float-{d}", .{fi + 1}) catch "float";

            try writeLuaStringField(writer, "    hexe.float(\"", fname, "\", {");
            if (fl.key >= 32 and fl.key < 127) {
                const key_slice = [_]u8{fl.key};
                try writeLuaStringField(writer, " key = \"", &key_slice, "\",");
            }
            if (fl.title) |title| {
                if (title.len > 0) {
                    try writeLuaStringField(writer, " title = \"", title, "\",");
                }
            }
            if (fl.command) |cmd| {
                if (cmd.len > 0) {
                    try writeLuaStringField(writer, " command = \"", cmd, "\",");
                }
            }
            if (fl.width_pct != null or fl.height_pct != null) {
                try writer.writeAll(" size = {");
                if (fl.width_pct) |w| try writer.print(" width = {d},", .{w});
                if (fl.height_pct) |h| try writer.print(" height = {d},", .{h});
                try writer.writeAll(" },");
            }
            if (fl.pos_x_pct != null or fl.pos_y_pct != null) {
                const px = fl.pos_x_pct orelse 50;
                const py = fl.pos_y_pct orelse 50;
                if (px != 50 or py != 50) {
                    try writer.print(" position = {{ x = {d}, y = {d} }},", .{ px, py });
                }
            }
            if (hasAnyTrueAttr(fl.attributes)) {
                try writer.writeAll(" attrs = {");
                if (fl.attributes.per_git) try writer.writeAll(" per_git = true,");
                if (fl.attributes.per_cwd and !fl.attributes.per_git) try writer.writeAll(" per_cwd = true,");
                if (fl.attributes.global and !fl.attributes.per_cwd and !fl.attributes.per_git) try writer.writeAll(" global = true,");
                if (fl.attributes.sticky) try writer.writeAll(" sticky = true,");
                if (fl.attributes.exclusive) try writer.writeAll(" exclusive = true,");
                if (fl.attributes.destroy) try writer.writeAll(" destroy = true,");
                if (fl.attributes.navigatable) try writer.writeAll(" navigatable = true,");
                if (fl.attributes.isolated) try writer.writeAll(" isolated = true,");
                if (fl.attributes.inherit_env) try writer.writeAll(" inherit_env = true,");
                try writer.writeAll(" },");
            }
            try writer.writeAll(" })");
            if (fi + 1 < session.floats.len) try writer.writeAll(",");
            try writer.writeAll("\n");
        }
        try writer.writeAll("  },\n");
    }

    try writer.writeAll("})\n");
    return buf.toOwnedSlice(allocator);
}

fn writeFileAtomically(allocator: std.mem.Allocator, dest_path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(dest_path)) |parent| {
        if (parent.len > 0) {
            try std.fs.cwd().makePath(parent);
        }
    }
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{dest_path});
    defer allocator.free(tmp_path);

    const file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(content);
    try std.fs.cwd().rename(tmp_path, dest_path);
}

/// Persist a serialized `.hexe.lua` layout according to `scope`:
/// - `.local`:  writes `{root_cwd}/.hexe.lua` (no global registry change).
/// - `.global`: writes `~/.local/share/hexe/layouts/<name>.lua` and registers it in `sessions.json`.
/// - `.both`:   writes `{root_cwd}/.hexe.lua` and registers `{name, root_cwd}` in `sessions.json`.
pub fn saveSessionLayout(
    allocator: std.mem.Allocator,
    scope: SaveScope,
    name: []const u8,
    root_cwd: []const u8,
    lua_content: []const u8,
) !SaveResult {
    const clean_name = std.mem.trim(u8, name, " \t\r\n");
    if (clean_name.len == 0) return error.InvalidName;
    for (clean_name) |ch| {
        if (ch == '/' or ch == '\\' or ch == 0) return error.InvalidName;
    }

    const written_path: []u8 = switch (scope) {
        .local => blk: {
            const dest = try std.fmt.allocPrint(allocator, "{s}/.hexe.lua", .{root_cwd});
            errdefer allocator.free(dest);
            try writeFileAtomically(allocator, dest, lua_content);
            break :blk dest;
        },
        .global => blk: {
            const dest = try session_config.getGlobalLayoutPath(allocator, clean_name);
            errdefer allocator.free(dest);
            try writeFileAtomically(allocator, dest, lua_content);
            try session_config.upsertLayoutRegistryEntry(allocator, clean_name, dest);
            break :blk dest;
        },
        .both => blk: {
            const dest = try std.fmt.allocPrint(allocator, "{s}/.hexe.lua", .{root_cwd});
            errdefer allocator.free(dest);
            try writeFileAtomically(allocator, dest, lua_content);
            try session_config.upsertLayoutRegistryEntry(allocator, clean_name, root_cwd);
            break :blk dest;
        },
    };
    errdefer allocator.free(written_path);

    return .{
        .written_path = written_path,
        .name = try allocator.dupe(u8, clean_name),
        .scope = scope,
    };
}

test "writeSessionLua round-trips tabs, splits, and rich floats" {
    const allocator = std.testing.allocator;
    const left = FreezeNode{ .pane = .{ .cwd = "/tmp/proj" } };
    const right = FreezeNode{ .pane = .{ .cwd = "/tmp/proj/sub" } };
    const root = FreezeNode{ .split = .{
        .dir = "horizontal",
        .ratio = 0.6,
        .first = &left,
        .second = &right,
    } };
    const lua_src = try writeSessionLua(allocator, .{
        .name = "demo",
        .root = "/tmp/proj",
        .tabs = &.{
            .{ .name = "code", .root = &root },
            .{ .name = "shell", .root = null },
        },
        .floats = &.{
            .{
                .name = "agent",
                .key = '4',
                .title = "Agent",
                .command = "claude",
                .width_pct = 70,
                .height_pct = 80,
                .pos_x_pct = 90,
                .pos_y_pct = 50,
                .attributes = .{ .per_cwd = true, .sticky = true },
            },
        },
    });
    defer allocator.free(lua_src);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "demo.lua", .data = lua_src });
    const full_path = try tmp.dir.realpathAlloc(allocator, "demo.lua");
    defer allocator.free(full_path);

    const parsed = try session_config.parseSessionLuaOnce(allocator, full_path);
    switch (parsed) {
        .layout => |layout_val| {
            var layout = layout_val;
            defer layout.deinit(allocator);
            try std.testing.expectEqualStrings("demo", layout.name);
            try std.testing.expectEqual(@as(usize, 2), layout.tabs.len);
            try std.testing.expectEqualStrings("code", layout.tabs[0].name);
            try std.testing.expectEqual(@as(usize, 1), layout.floats.len);
            try std.testing.expectEqual(@as(u8, '4'), layout.floats[0].key);
            try std.testing.expectEqualStrings("Agent", layout.floats[0].title.?);
            try std.testing.expectEqualStrings("claude", layout.floats[0].command.?);
            try std.testing.expect(layout.floats[0].attributes.per_cwd);
            try std.testing.expect(layout.floats[0].attributes.sticky);
            try std.testing.expectEqual(@as(?u8, 90), layout.floats[0].pos_x);
        },
        .legacy => |cfg_val| {
            var cfg = cfg_val;
            defer cfg.deinit(allocator);
            return error.ExpectedCanonicalLayout;
        },
    }
}
