const std = @import("std");
const posix = std.posix;
const lua_runtime = @import("lua_runtime.zig");
const LuaRuntime = lua_runtime.LuaRuntime;
const logging = @import("logging.zig");
const config_mod = @import("config.zig");
const session_model = @import("session_model.zig");

/// Direction of a split in session config.
pub const SplitDir = enum {
    horizontal,
    vertical,
};

/// A leaf pane in the split tree.
pub const PaneConfig = struct {
    cmd: ?[]const u8 = null,
    cwd: ?[]const u8 = null, // relative to root, resolved at apply time

    pub fn deinit(self: *PaneConfig, allocator: std.mem.Allocator) void {
        if (self.cmd) |cmd| allocator.free(cmd);
        if (self.cwd) |cwd| allocator.free(cwd);
        self.* = .{};
    }
};

/// A node in the split tree: either a single pane or a split.
pub const SplitConfig = union(enum) {
    pane: PaneConfig,
    split: SplitNode,

    pub const SplitNode = struct {
        dir: SplitDir,
        children: []SplitChild,
    };

    pub fn deinit(self: *SplitConfig, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .pane => |*pane| pane.deinit(allocator),
            .split => |*split| {
                for (split.children) |*child| child.deinit(allocator);
                if (split.children.len > 0) allocator.free(split.children);
            },
        }
    }
};

/// A child in an N-ary split, with an optional size percentage.
pub const SplitChild = struct {
    size: ?u8 = null, // percentage, null = equal
    node: SplitConfig,

    pub fn deinit(self: *SplitChild, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
    }
};

/// A float pane definition.
pub const FloatConfig = struct {
    key: u8 = 0,
    cmd: ?[]const u8 = null,
    width: u8 = 80,
    height: u8 = 80,
    pos_x: u8 = 50,
    pos_y: u8 = 50,
    title: ?[]const u8 = null,
    global: bool = false,

    pub fn deinit(self: *FloatConfig, allocator: std.mem.Allocator) void {
        if (self.cmd) |cmd| allocator.free(cmd);
        if (self.title) |title| allocator.free(title);
        self.* = .{};
    }
};

/// A tab definition.
pub const TabConfig = struct {
    name: []const u8,
    split: ?SplitConfig = null, // null = single pane with default shell
    floats: []FloatConfig = &.{},

    pub fn deinit(self: *TabConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.split) |*split| split.deinit(allocator);
        for (self.floats) |*float| float.deinit(allocator);
        if (self.floats.len > 0) allocator.free(self.floats);
        self.* = .{
            .name = "",
            .split = null,
            .floats = &.{},
        };
    }
};

/// Top-level session configuration parsed from .hexe.lua.
pub const SessionConfig = struct {
    name: ?[]const u8 = null,
    root: ?[]const u8 = null,
    on_start: [][]const u8 = &.{},
    on_stop: [][]const u8 = &.{},
    tabs: []TabConfig = &.{},
    floats: []FloatConfig = &.{}, // global floats
    filter_tab: ?[]const u8 = null, // if set, only launch this tab
    /// Absolute path of the `.hexe.lua` this config was parsed from (when known).
    /// Used to gate `on_start`/`on_stop` shell hooks against the trust ledger.
    source_path: ?[]const u8 = null,

    pub fn deinit(self: *SessionConfig, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        if (self.root) |root| allocator.free(root);
        if (self.source_path) |sp| allocator.free(sp);
        for (self.on_start) |cmd| allocator.free(cmd);
        if (self.on_start.len > 0) allocator.free(self.on_start);
        for (self.on_stop) |cmd| allocator.free(cmd);
        if (self.on_stop.len > 0) allocator.free(self.on_stop);
        for (self.tabs) |*tab| tab.deinit(allocator);
        if (self.tabs.len > 0) allocator.free(self.tabs);
        for (self.floats) |*float| float.deinit(allocator);
        if (self.floats.len > 0) allocator.free(self.floats);
        if (self.filter_tab) |filter| allocator.free(filter);
        self.* = .{};
    }
};

/// Get the sessions directory (~/.local/share/hexe/sessions/).
pub fn getSessionsDir(allocator: std.mem.Allocator) ![]const u8 {
    if (posix.getenv("XDG_DATA_HOME")) |xdg| {
        return std.fmt.allocPrint(allocator, "{s}/hexe/sessions", .{xdg});
    }
    const home = posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.local/share/hexe/sessions", .{home});
}

/// Get the sessions index file (~/.local/share/hexe/sessions.json).
pub fn getSessionsIndexPath(allocator: std.mem.Allocator) ![]const u8 {
    if (posix.getenv("XDG_DATA_HOME")) |xdg| {
        return std.fmt.allocPrint(allocator, "{s}/hexe/sessions.json", .{xdg});
    }
    const home = posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.local/share/hexe/sessions.json", .{home});
}

pub const LayoutRegistryEntry = struct {
    name: []const u8,
    path: []const u8,
};

pub const LayoutRegistry = struct {
    entries: []LayoutRegistryEntry = &.{},
};

pub fn deinitLayoutRegistry(allocator: std.mem.Allocator, registry: *LayoutRegistry) void {
    for (registry.entries) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.path);
    }
    if (registry.entries.len > 0) allocator.free(registry.entries);
    registry.entries = &.{};
}

pub fn loadLayoutRegistry(allocator: std.mem.Allocator) !LayoutRegistry {
    const index_path = try getSessionsIndexPath(allocator);
    defer allocator.free(index_path);

    const file = std.fs.cwd().openFile(index_path, .{}) catch |err| {
        if (err == error.FileNotFound) return .{};
        return err;
    };
    defer file.close();

    const raw = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(raw);
    if (raw.len == 0) return .{};

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch |err| {
        logging.logError("session_config", "failed to parse layout registry", err);
        return .{};
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return .{},
    };
    const layouts_val = root.get("layouts") orelse return .{};
    const layouts = switch (layouts_val) {
        .array => |arr| arr,
        else => return .{},
    };

    var entries = std.ArrayList(LayoutRegistryEntry).empty;
    defer entries.deinit(allocator);

    for (layouts.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = switch (obj.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const path = switch (obj.get("path") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        try entries.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .path = try allocator.dupe(u8, path),
        });
    }

    return .{ .entries = try entries.toOwnedSlice(allocator) };
}

pub fn saveLayoutRegistry(allocator: std.mem.Allocator, registry: LayoutRegistry) !void {
    const index_path = try getSessionsIndexPath(allocator);
    defer allocator.free(index_path);

    if (std.fs.path.dirname(index_path)) |parent| {
        try std.fs.cwd().makePath(parent);
    }

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{index_path});
    defer allocator.free(tmp_path);

    const file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    const writer = out.writer(allocator);

    try writer.writeAll("{\n  \"version\": 1,\n  \"layouts\": [");
    for (registry.entries, 0..) |entry, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("\n    {\"name\":\"");
        try writeJsonEscaped(writer, entry.name);
        try writer.writeAll("\",\"path\":\"");
        try writeJsonEscaped(writer, entry.path);
        try writer.writeAll("\"}");
    }
    try writer.writeAll("\n  ]\n}\n");

    try file.writeAll(out.items);
    try std.fs.cwd().rename(tmp_path, index_path);
}

pub fn upsertLayoutRegistryEntry(allocator: std.mem.Allocator, name: []const u8, path: []const u8) !void {
    var registry = try loadLayoutRegistry(allocator);
    defer deinitLayoutRegistry(allocator, &registry);

    for (registry.entries) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            allocator.free(entry.path);
            entry.path = try allocator.dupe(u8, path);
            try saveLayoutRegistry(allocator, registry);
            return;
        }
    }

    var list = try std.ArrayList(LayoutRegistryEntry).initCapacity(allocator, registry.entries.len + 1);
    defer list.deinit(allocator);
    for (registry.entries) |entry| {
        try list.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .path = try allocator.dupe(u8, entry.path),
        });
    }
    try list.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .path = try allocator.dupe(u8, path),
    });

    var next = LayoutRegistry{ .entries = try list.toOwnedSlice(allocator) };
    defer deinitLayoutRegistry(allocator, &next);
    try saveLayoutRegistry(allocator, next);
}

fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}

/// Resolve a CLI argument to a .hexe.lua config path.
///
/// - If arg is a directory (or "."), look for .hexe.lua inside it.
/// - If arg contains ":" suffix, split into name:tab_filter.
/// - If arg is a bare name, resolve from ~/.local/share/hexe/sessions.json.
/// - If arg is a file path, use it directly.
///
/// Returns struct with path and optional tab filter.
pub const ResolvedConfig = struct {
    path: []const u8,
    tab_filter: ?[]const u8 = null,
};

pub fn resolveConfigPath(allocator: std.mem.Allocator, arg: []const u8) !?ResolvedConfig {
    // Split on ":" for tab filter (e.g., "myproject:server")
    var target = arg;
    var tab_filter: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, arg, ':')) |colon_pos| {
        target = arg[0..colon_pos];
        if (colon_pos + 1 < arg.len) {
            tab_filter = try allocator.dupe(u8, arg[colon_pos + 1 ..]);
        }
    }
    errdefer if (tab_filter) |tf| allocator.free(tf);

    // Check if target is "."
    if (std.mem.eql(u8, target, ".")) {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.posix.getcwd(&cwd_buf) catch |err| {
            logging.logError("session_config", "failed to resolve current directory layout target", err);
            return null;
        };
        const path = try std.fmt.allocPrint(allocator, "{s}/.hexe.lua", .{cwd});
        std.fs.cwd().access(path, .{}) catch {
            allocator.free(path);
            return null;
        };
        return .{ .path = path, .tab_filter = tab_filter };
    }

    // Try opening as a directory
    if (std.fs.cwd().openDir(target, .{})) |*dir_handle| {
        var dir = dir_handle.*;
        defer dir.close();
        const abs_target = dir.realpathAlloc(allocator, ".") catch |err| {
            logging.logError("session_config", "failed to resolve layout directory target", err);
            return null;
        };
        defer allocator.free(abs_target);
        const path = try std.fmt.allocPrint(allocator, "{s}/.hexe.lua", .{abs_target});
        std.fs.cwd().access(path, .{}) catch {
            allocator.free(path);
            return null;
        };
        return .{ .path = path, .tab_filter = tab_filter };
    } else |_| {}

    // If target is a file path ending in .lua, use directly
    if (std.mem.endsWith(u8, target, ".lua")) {
        const path = try allocator.dupe(u8, target);
        std.fs.cwd().access(path, .{}) catch {
            allocator.free(path);
            return null;
        };
        return .{ .path = path, .tab_filter = tab_filter };
    }

    // Treat as registered layout name from sessions.json
    var registry = loadLayoutRegistry(allocator) catch |err| {
        logging.logError("session_config", "failed to load layout registry", err);
        return null;
    };
    defer deinitLayoutRegistry(allocator, &registry);
    for (registry.entries) |entry| {
        if (!std.mem.eql(u8, entry.name, target)) continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/.hexe.lua", .{entry.path});
        std.fs.cwd().access(path, .{}) catch {
            allocator.free(path);
            return null;
        };
        return .{ .path = path, .tab_filter = tab_filter };
    }
    return null;
}

/// Parse a .hexe.lua file into a SessionConfig.
pub fn parseSessionLua(allocator: std.mem.Allocator, path: []const u8) !SessionConfig {
    var runtime = try LuaRuntime.init(allocator);
    defer runtime.deinit();

    runtime.loadConfig(path) catch |err| {
        if (err == error.FileNotFound) return err;
        if (runtime.last_error) |msg| {
            std.debug.print("Error loading {s}: {s}\n", .{ path, msg });
        }
        return error.LuaError;
    };

    return extractLegacyFromRuntime(allocator, &runtime, path);
}

/// Either shape a .hexe.lua can parse to. Callers deinit whichever arm.
pub const ParsedSessionLua = union(enum) {
    layout: config_mod.LayoutDef,
    legacy: SessionConfig,
};

/// Parse a .hexe.lua by EXECUTING IT EXACTLY ONCE, then trying the canonical
/// hexe.setup extraction and falling back to the legacy table shape on the
/// same runtime. The old two-parser fallback re-ran the whole file for the
/// legacy attempt, so any Lua side effects executed twice.
pub fn parseSessionLuaOnce(allocator: std.mem.Allocator, path: []const u8) !ParsedSessionLua {
    var runtime = try LuaRuntime.init(allocator);
    defer runtime.deinit();

    runtime.loadConfig(path) catch |err| {
        if (err == error.FileNotFound) return err;
        if (runtime.last_error) |msg| {
            std.debug.print("Error loading {s}: {s}\n", .{ path, msg });
        }
        return error.LuaError;
    };

    if (extractLayoutFromRuntime(allocator, &runtime, path)) |layout| {
        return .{ .layout = layout };
    } else |_| {}

    return .{ .legacy = try extractLegacyFromRuntime(allocator, &runtime, path) };
}

fn extractLegacyFromRuntime(allocator: std.mem.Allocator, runtime: *LuaRuntime, path: []const u8) !SessionConfig {
    // The file should return a table — check top of stack
    if (runtime.typeOf(-1) != .table) {
        std.debug.print("Error: {s} must return a table\n", .{path});
        return error.LuaError;
    }

    var config = SessionConfig{};

    // Supported format:
    // return hexe.setup({ ses = { layouts = { hexe.layout(...) } } })
    var table_idx: i32 = -1;
    var pushed: usize = 0;
    if (runtime.pushTable(-1, "ses")) {
        pushed += 1;
        if (!runtime.pushTable(-1, "layouts")) {
            return error.InvalidConfig;
        }
        pushed += 1;
        if (!runtime.pushArrayElement(-1, 1)) {
            return error.InvalidConfig;
        }
        pushed += 1;
        table_idx = -1;
    } else if (runtime.getString(-1, "__hexe_type")) |kind| {
        if (!std.mem.eql(u8, kind, "layout")) {
            return error.InvalidConfig;
        }
    } else {
        return error.InvalidConfig;
    }
    defer {
        var i: usize = 0;
        while (i < pushed) : (i += 1) runtime.pop();
    }

    // Read layout fields
    if (runtime.getStringAlloc(table_idx, "name")) |s| config.name = s;
    if (runtime.getStringAlloc(table_idx, "root")) |s| config.root = s;

    config.on_start = parseStringArray(allocator, runtime, table_idx, "on_start") catch &.{};
    config.on_stop = parseStringArray(allocator, runtime, table_idx, "on_stop") catch &.{};
    config.tabs = parseTabs(allocator, runtime, table_idx) catch &.{};
    config.floats = parseFloats(allocator, runtime, table_idx) catch &.{};

    // Set last so error-returning parses above never leak this (config is
    // discarded without deinit on the error paths). Gates on_start/on_stop
    // against the trust ledger (PLAN 1.9).
    config.source_path = std.fs.cwd().realpathAlloc(allocator, path) catch allocator.dupe(u8, path) catch null;

    return config;
}

/// Parse a canonical `hexe.setup({ ses = { layouts = { hexe.layout(...) } } })`
/// file into the same LayoutDef model used by normal local SES config loading.
/// This keeps explicit `.hexe.lua` opens on the same parser/apply path as
/// auto-loaded layouts, instead of drifting through the legacy SessionConfig
/// split parser.
pub fn parseSessionLayoutLua(allocator: std.mem.Allocator, path: []const u8) !config_mod.LayoutDef {
    var runtime = try LuaRuntime.init(allocator);
    defer runtime.deinit();

    runtime.loadConfig(path) catch |err| {
        if (err == error.FileNotFound) return err;
        if (runtime.last_error) |msg| {
            std.debug.print("Error loading {s}: {s}\n", .{ path, msg });
        }
        return error.LuaError;
    };

    return extractLayoutFromRuntime(allocator, &runtime, path);
}

fn extractLayoutFromRuntime(allocator: std.mem.Allocator, runtime: *LuaRuntime, path: []const u8) !config_mod.LayoutDef {
    const builder = runtime.getBuilder() orelse return error.InvalidConfig;
    const ses_builder = builder.ses orelse return error.InvalidConfig;
    var ses_config = try ses_builder.build();
    errdefer ses_config.deinit(allocator);

    if (ses_config.layouts.len == 0) return error.InvalidConfig;

    var layout = ses_config.layouts[0];

    for (ses_config.layouts[1..]) |*extra| {
        extra.deinit(allocator);
    }
    allocator.free(ses_config.layouts);
    ses_config.layouts = &[_]config_mod.LayoutDef{};
    ses_config.isolation.deinit(allocator);

    // Identify the project file for the on_start/on_stop trust gate; without
    // it the hooks would run ungated (null source_path means "user's own
    // config, implicitly trusted").
    if (layout.source_path == null) {
        layout.source_path = std.fs.cwd().realpathAlloc(allocator, path) catch allocator.dupe(u8, path) catch null;
    }

    return layout;
}

fn parseStringArray(allocator: std.mem.Allocator, runtime: *LuaRuntime, table_idx: i32, key: [:0]const u8) ![][]const u8 {
    if (!runtime.pushTable(table_idx, key)) return &.{};
    defer runtime.pop();

    const len = runtime.getArrayLen(-1);
    if (len == 0) return &.{};

    var list = try std.ArrayList([]const u8).initCapacity(allocator, len);
    errdefer list.deinit(allocator);

    var i: usize = 1;
    while (i <= len) : (i += 1) {
        if (runtime.pushArrayElement(-1, i)) {
            defer runtime.pop();
            if (runtime.toStringAt(-1)) |s| {
                const duped = try allocator.dupe(u8, s);
                try list.append(allocator, duped);
            }
        }
    }

    return list.toOwnedSlice(allocator);
}

fn parseTabs(allocator: std.mem.Allocator, runtime: *LuaRuntime, table_idx: i32) ![]TabConfig {
    if (!runtime.pushTable(table_idx, "tabs")) return &.{};
    defer runtime.pop();

    const len = runtime.getArrayLen(-1);
    if (len == 0) return &.{};

    var list = try std.ArrayList(TabConfig).initCapacity(allocator, len);
    errdefer list.deinit(allocator);

    var i: usize = 1;
    while (i <= len) : (i += 1) {
        if (runtime.pushArrayElement(-1, i)) {
            defer runtime.pop();

            const name = runtime.getStringAlloc(-1, "name") orelse
                try std.fmt.allocPrint(allocator, "tab-{d}", .{i});

            var tab = TabConfig{
                .name = name,
            };

            // Parse split tree.
            if (runtime.pushTable(-1, "root")) {
                defer runtime.pop();
                tab.split = parseSplitConfig(allocator, runtime) catch |err| blk: {
                    logging.logError("session_config", "failed to parse tab split config", err);
                    break :blk null;
                };
            }

            // Parse per-tab floats
            tab.floats = parseFloats(allocator, runtime, -1) catch |err| blk: {
                logging.logError("session_config", "failed to parse tab float config", err);
                break :blk &.{};
            };

            try list.append(allocator, tab);
        }
    }

    return list.toOwnedSlice(allocator);
}

fn parseSplitConfig(allocator: std.mem.Allocator, runtime: *LuaRuntime) !SplitConfig {
    // Check if this is a split node (has "dir" field) or a leaf.
    if (runtime.getString(-1, "dir")) |dir_str| {
        // It's a split node
        const dir: SplitDir = if (session_model.isVerticalSplitDir(dir_str)) .vertical else .horizontal;

        // Read array children (1-based numeric keys)
        const len = runtime.getArrayLen(-1);
        if (len == 0) return error.InvalidConfig;

        var children = try std.ArrayList(SplitChild).initCapacity(allocator, len);
        errdefer children.deinit(allocator);

        var i: usize = 1;
        while (i <= len) : (i += 1) {
            if (runtime.pushArrayElement(-1, i)) {
                defer runtime.pop();

                const size = runtime.getInt(u8, -1, "size");

                // Check if child is a split node or a leaf
                const node = if (runtime.getString(-1, "dir") != null)
                    try parseSplitConfig(allocator, runtime)
                else blk: {
                    const cmd = runtime.getStringAlloc(-1, "command");
                    const cwd = runtime.getStringAlloc(-1, "cwd");
                    break :blk SplitConfig{ .pane = .{ .cmd = cmd, .cwd = cwd } };
                };

                try children.append(allocator, .{
                    .size = size,
                    .node = node,
                });
            }
        }

        return SplitConfig{
            .split = .{
                .dir = dir,
                .children = try children.toOwnedSlice(allocator),
            },
        };
    } else {
        // It's a leaf pane
        const cmd = runtime.getStringAlloc(-1, "command");
        const cwd = runtime.getStringAlloc(-1, "cwd");
        return SplitConfig{ .pane = .{ .cmd = cmd, .cwd = cwd } };
    }
}

fn parseFloats(allocator: std.mem.Allocator, runtime: *LuaRuntime, table_idx: i32) ![]FloatConfig {
    if (!runtime.pushTable(table_idx, "floats")) return &.{};
    defer runtime.pop();

    const len = runtime.getArrayLen(-1);
    if (len == 0) return &.{};

    var list = try std.ArrayList(FloatConfig).initCapacity(allocator, len);
    errdefer list.deinit(allocator);

    var i: usize = 1;
    while (i <= len) : (i += 1) {
        if (runtime.pushArrayElement(-1, i)) {
            defer runtime.pop();

            var float = FloatConfig{};

            // key: single character
            if (runtime.getString(-1, "key")) |key_str| {
                if (key_str.len > 0) float.key = key_str[0];
            }

            float.cmd = runtime.getStringAlloc(-1, "command");
            float.width = runtime.getInt(u8, -1, "width") orelse 80;
            float.height = runtime.getInt(u8, -1, "height") orelse 80;
            float.pos_x = runtime.getInt(u8, -1, "pos_x") orelse 50;
            float.pos_y = runtime.getInt(u8, -1, "pos_y") orelse 50;
            if (runtime.pushTable(-1, "size")) {
                defer runtime.pop();
                float.width = runtime.getInt(u8, -1, "width") orelse float.width;
                float.height = runtime.getInt(u8, -1, "height") orelse float.height;
            }
            if (runtime.pushTable(-1, "position")) {
                defer runtime.pop();
                float.pos_x = runtime.getInt(u8, -1, "x") orelse float.pos_x;
                float.pos_y = runtime.getInt(u8, -1, "y") orelse float.pos_y;
            }
            float.title = runtime.getStringAlloc(-1, "title");
            float.global = runtime.getBool(-1, "global") orelse false;
            if (runtime.pushTable(-1, "attrs")) {
                defer runtime.pop();
                float.global = runtime.getBool(-1, "global") orelse float.global;
            }

            try list.append(allocator, float);
        }
    }

    return list.toOwnedSlice(allocator);
}

test "parseSessionLua reads canonical hexe.setup layout config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const code =
        "local hexe = require('hexe')\n" ++
        "return hexe.setup({ ses = { layouts = { hexe.layout('unit', {\n" ++
        "  root = '.',\n" ++
        "  tabs = { hexe.tab('main', { root = hexe.pane({ command = 'sh', cwd = 'src' }) }) },\n" ++
        "  floats = { hexe.float('codex', { key = '3', command = 'codex', size = { width = 80, height = 70 }, attrs = { global = true } }) },\n" ++
        "}) } } })\n";

    try tmp.dir.writeFile(.{ .sub_path = "layout.lua", .data = code });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "layout.lua");
    defer std.testing.allocator.free(path);

    var cfg = try parseSessionLua(std.testing.allocator, path);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("unit", cfg.name.?);
    try std.testing.expectEqual(@as(usize, 1), cfg.tabs.len);
    try std.testing.expectEqualStrings("main", cfg.tabs[0].name);
    try std.testing.expect(cfg.tabs[0].split != null);
    try std.testing.expectEqual(@as(usize, 1), cfg.floats.len);
    try std.testing.expectEqual(@as(u8, '3'), cfg.floats[0].key);
    try std.testing.expectEqualStrings("codex", cfg.floats[0].cmd.?);
    try std.testing.expect(cfg.floats[0].global);
}

test "parseSessionLayoutLua preserves saved tabs and split panes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const code =
        "local hexe = require('hexe')\n" ++
        "return hexe.setup({ ses = { layouts = { hexe.layout('hexe', {\n" ++
        "  root = '/tmp/unit',\n" ++
        "  tabs = {\n" ++
        "    hexe.tab('hexe-1', { root = hexe.split('horizontal', {\n" ++
        "      hexe.pane({ size = 50 }),\n" ++
        "      hexe.pane({ size = 50 }),\n" ++
        "    }) }),\n" ++
        "    hexe.tab('hexe-2', { root = hexe.pane() }),\n" ++
        "  },\n" ++
        "}) } } })\n";

    try tmp.dir.writeFile(.{ .sub_path = "layout.lua", .data = code });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "layout.lua");
    defer std.testing.allocator.free(path);

    var layout = try parseSessionLayoutLua(std.testing.allocator, path);
    defer layout.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hexe", layout.name);
    try std.testing.expectEqual(@as(usize, 2), layout.tabs.len);
    try std.testing.expectEqualStrings("hexe-1", layout.tabs[0].name);
    try std.testing.expectEqualStrings("hexe-2", layout.tabs[1].name);

    const root = layout.tabs[0].root orelse return error.TestUnexpectedResult;
    switch (root) {
        .split => |split| {
            try std.testing.expectEqualStrings("h", split.dir);
            try std.testing.expect(@abs(split.ratio - @as(f32, 0.5)) < 0.001);
            switch (split.first.*) {
                .pane => {},
                .split => return error.TestUnexpectedResult,
            }
            switch (split.second.*) {
                .pane => {},
                .split => return error.TestUnexpectedResult,
            }
        },
        .pane => return error.TestUnexpectedResult,
    }
}

test "parseSessionLua rejects old top-level layout wrapper" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const code =
        "return { layout = { name = 'old', tabs = { { name = 'main', split = {} } } } }\n";

    try tmp.dir.writeFile(.{ .sub_path = "old.lua", .data = code });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "old.lua");
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.InvalidConfig, parseSessionLua(std.testing.allocator, path));
}

test "parseSessionLuaOnce: canonical layout carries on_start and executes the file once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const counter_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(counter_path);

    // The file appends to a counter on every execution: the old two-parser
    // fallback executed it twice.
    const code = try std.fmt.allocPrint(std.testing.allocator, "local f = io.open('{s}/count', 'a')\n" ++
        "f:write('x')\n" ++
        "f:close()\n" ++
        "local hexe = require('hexe')\n" ++
        "return hexe.setup({{ ses = {{ layouts = {{ hexe.layout('unit', {{\n" ++
        "  root = '.',\n" ++
        "  on_start = {{ 'echo one', 'echo two' }},\n" ++
        "  tabs = {{ hexe.tab('main', {{ root = hexe.pane({{ command = 'sh' }}) }}) }},\n" ++
        "}}) }} }} }})\n", .{counter_path});
    defer std.testing.allocator.free(code);

    try tmp.dir.writeFile(.{ .sub_path = "layout.lua", .data = code });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "layout.lua");
    defer std.testing.allocator.free(path);

    var parsed = try parseSessionLuaOnce(std.testing.allocator, path);
    switch (parsed) {
        .layout => |*layout| {
            defer layout.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("unit", layout.name);
            // The canonical path used to silently drop on_start hooks.
            try std.testing.expectEqual(@as(usize, 2), layout.on_start.len);
            try std.testing.expectEqualStrings("echo one", layout.on_start[0]);
            try std.testing.expectEqualStrings("echo two", layout.on_start[1]);
            // source_path must be set for the trust-ledger gate.
            try std.testing.expect(layout.source_path != null);
        },
        .legacy => return error.TestUnexpectedResult,
    }

    // Exactly one execution.
    const count = try tmp.dir.readFileAlloc(std.testing.allocator, "count", 16);
    defer std.testing.allocator.free(count);
    try std.testing.expectEqualStrings("x", count);
}

test "parseSessionLuaOnce: legacy fallback still executes the file once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const counter_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(counter_path);

    // Legacy shape (plain returned table, no hexe.setup builder): the
    // canonical extraction fails and the legacy extraction must reuse the
    // SAME run instead of re-executing the file.
    const code = try std.fmt.allocPrint(std.testing.allocator, "local f = io.open('{s}/count', 'a')\n" ++
        "f:write('x')\n" ++
        "f:close()\n" ++
        "return {{ ses = {{ layouts = {{ {{\n" ++
        "  name = 'legacy-unit',\n" ++
        "  on_start = {{ 'echo legacy' }},\n" ++
        "  tabs = {{ {{ name = 'main' }} }},\n" ++
        "}} }} }} }}\n", .{counter_path});
    defer std.testing.allocator.free(code);

    try tmp.dir.writeFile(.{ .sub_path = "cfg.lua", .data = code });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "cfg.lua");
    defer std.testing.allocator.free(path);

    var parsed = try parseSessionLuaOnce(std.testing.allocator, path);
    switch (parsed) {
        .layout => return error.TestUnexpectedResult,
        .legacy => |*cfg| {
            defer cfg.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("legacy-unit", cfg.name.?);
            try std.testing.expectEqual(@as(usize, 1), cfg.on_start.len);
        },
    }

    const count = try tmp.dir.readFileAlloc(std.testing.allocator, "count", 16);
    defer std.testing.allocator.free(count);
    try std.testing.expectEqualStrings("x", count);
}
