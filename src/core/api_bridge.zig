const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaState = zlua.LuaState;
const config_builder = @import("config_builder.zig");
const session_model = @import("session_model.zig");
const ConfigBuilder = config_builder.ConfigBuilder;
const config = @import("config.zig");
const log = std.log.scoped(.api_bridge);
const record = @import("api_bridge_record.zig");
const layout_mod = @import("api_bridge_layout.zig");
// Layout parsers live in `api_bridge_layout`; `parseLayoutSplit` is the entry
// point `parseLayoutDef` calls, re-exported so that call is unchanged (PLAN 2.3).
const parseLayoutSplit = layout_mod.parseLayoutSplit;
const float_mod = @import("api_bridge_float.zig");
// Float visual-options parsing lives in `api_bridge_float`; re-exported so
// lua_runtime's `api_bridge.applyFloatVisualOptions` call is unchanged.
pub const applyFloatVisualOptions = float_mod.applyFloatVisualOptions;

// Record C-API glue lives in `api_bridge_record`; re-exported so lua_runtime's
// registration (`api_bridge.hexe_record_*`) is unchanged (PLAN 2.3).
pub const hexe_record_start = record.hexe_record_start;
pub const hexe_record_stop = record.hexe_record_stop;
pub const hexe_record_toggle = record.hexe_record_toggle;
pub const hexe_record_status = record.hexe_record_status;

// Import C standard library functions
const c = @cImport({
    @cInclude("stdlib.h");
});

/// Registry key for storing ConfigBuilder pointer
const BUILDER_REGISTRY_KEY = "_hexe_config_builder";
const CALLBACK_TABLE_KEY = "__hexe_cb_table";
const CALLBACK_NEXT_ID_KEY = "__hexe_cb_next_id";
const CALLBACK_REF_PREFIX = "__hexe_cb_ref:";

pub fn dupeBridgeString(allocator: std.mem.Allocator, value: []const u8, comptime context: []const u8) ?[]u8 {
    return allocator.dupe(u8, value) catch |err| {
        log.warn(context ++ ": {}", .{err});
        return null;
    };
}

fn replaceBridgeStringSlot(slot: *?[]const u8, allocator: std.mem.Allocator, value: []const u8, comptime context: []const u8) void {
    slot.* = dupeBridgeString(allocator, value, context) orelse slot.*;
}

fn setBridgeStringSlot(slot: *?[]const u8, allocator: std.mem.Allocator, value: []const u8, comptime context: []const u8) void {
    slot.* = dupeBridgeString(allocator, value, context);
}

pub fn bridgeLuaString(lua: *Lua, idx: i32, comptime context: []const u8) ?[]const u8 {
    return lua.toString(idx) catch |err| {
        log.warn(context ++ ": {}", .{err});
        return null;
    };
}

pub fn luaNumberOrRaise(lua: *Lua, idx: i32, message: []const u8) f64 {
    return lua.toNumber(idx) catch {
        _ = lua.pushString(message);
        lua.raiseError();
    };
}

/// Store ConfigBuilder pointer in Lua registry
pub fn storeConfigBuilder(lua: *Lua, builder: *ConfigBuilder) !void {
    lua.pushLightUserdata(builder);
    lua.setField(zlua.registry_index, BUILDER_REGISTRY_KEY);
}

/// Retrieve ConfigBuilder pointer from Lua registry
pub fn getConfigBuilder(lua: *Lua) ?*ConfigBuilder {
    _ = lua.getField(zlua.registry_index, BUILDER_REGISTRY_KEY);
    defer lua.pop(1);

    if (lua.typeOf(-1) != .light_userdata) {
        return null;
    }

    const ptr = lua.toPointer(-1) catch |err| {
        log.warn("failed to read ConfigBuilder registry pointer: {}", .{err});
        return null;
    };
    const addr = @intFromPtr(ptr);
    return @ptrFromInt(addr);
}

/// Helper to get MuxConfigBuilder, creating it if needed
pub fn getMuxBuilder(lua: *Lua) !*config_builder.MuxConfigBuilder {
    const builder = getConfigBuilder(lua) orelse return error.NoConfigBuilder;

    if (builder.mux == null) {
        builder.mux = try config_builder.MuxConfigBuilder.init(builder.allocator);
    }

    return builder.mux.?;
}

/// Helper to get SesConfigBuilder, creating it if needed
pub fn getSesBuilder(lua: *Lua) !*config_builder.SesConfigBuilder {
    const builder = getConfigBuilder(lua) orelse return error.NoConfigBuilder;

    if (builder.ses == null) {
        builder.ses = try config_builder.SesConfigBuilder.init(builder.allocator);
    }

    return builder.ses.?;
}

/// Helper to get PopConfigBuilder, creating it if needed
pub fn getPopBuilder(lua: *Lua) !*config_builder.PopConfigBuilder {
    const builder = getConfigBuilder(lua) orelse return error.NoConfigBuilder;

    if (builder.pop == null) {
        builder.pop = try config_builder.PopConfigBuilder.init(builder.allocator);
    }

    return builder.pop.?;
}

// ===== Parsing Helpers =====

/// Parse a key string into BindKey
fn parseKeyString(key_str: []const u8) ?config.Config.BindKey {
    // Debug: print what we're parsing

    if (key_str.len == 1) return .{ .char = key_str[0] };
    if (std.mem.eql(u8, key_str, "space")) return .space;
    if (std.mem.eql(u8, key_str, "up")) return .up;
    if (std.mem.eql(u8, key_str, "down")) return .down;
    if (std.mem.eql(u8, key_str, "left")) return .left;
    if (std.mem.eql(u8, key_str, "right")) return .right;
    return null;
}

fn registerPromptValueCallback(lua: *Lua) ?i64 {
    if (lua.typeOf(-1) != .function) return null;

    _ = lua.getField(zlua.registry_index, CALLBACK_TABLE_KEY);
    if (lua.typeOf(-1) == .nil) {
        lua.pop(1);
        lua.createTable(0, 32);
        lua.pushValue(-1);
        lua.setField(zlua.registry_index, CALLBACK_TABLE_KEY);
        lua.pushValue(-1);
        lua.setGlobal(CALLBACK_TABLE_KEY);
    } else if (lua.typeOf(-1) != .table) {
        lua.pop(1);
        return null;
    }

    _ = lua.getField(zlua.registry_index, CALLBACK_NEXT_ID_KEY);
    var next_id: i64 = 1;
    if (lua.typeOf(-1) == .number) {
        next_id = lua.toInteger(-1) catch 1;
        if (next_id < 1) next_id = 1;
    }
    lua.pop(1);

    // Stack: ..., function, callback_table
    lua.pushValue(-2);
    lua.rawSetIndex(-2, @intCast(next_id));
    lua.pop(1);

    lua.pushInteger(next_id + 1);
    lua.setField(zlua.registry_index, CALLBACK_NEXT_ID_KEY);

    return next_id;
}

fn parsePromptValueChunkValue(lua: *Lua, allocator: std.mem.Allocator, require_boolean: bool) ?[]const u8 {
    _ = require_boolean;
    if (registerPromptValueCallback(lua)) |callback_id| {
        return std.fmt.allocPrint(allocator, "{s}{d}", .{ CALLBACK_REF_PREFIX, callback_id }) catch |err| {
            log.warn("failed to allocate prompt callback reference: {}", .{err});
            return null;
        };
    }
    return null;
}

fn parsePromptCallbackField(lua: *Lua, allocator: std.mem.Allocator, field_name: []const u8) ?[]const u8 {
    if (lua.typeOf(-1) == .nil) return null;
    if (lua.typeOf(-1) != .function) {
        const msg = std.fmt.allocPrint(allocator, "{s} must be function(ctx)", .{field_name}) catch "callback field must be function(ctx)";
        defer if (!std.mem.eql(u8, msg, "callback field must be function(ctx)")) allocator.free(msg);
        _ = lua.pushString(msg);
        lua.raiseError();
    }
    return parsePromptValueChunkValue(lua, allocator, false) orelse blk: {
        const msg = std.fmt.allocPrint(allocator, "failed to register callback for {s}", .{field_name}) catch "failed to register callback";
        defer if (!std.mem.eql(u8, msg, "failed to register callback")) allocator.free(msg);
        _ = lua.pushString(msg);
        lua.raiseError();
        break :blk null;
    };
}

fn parseCommandOrCallbackField(lua: *Lua, allocator: std.mem.Allocator, field_name: []const u8) ?[]const u8 {
    return switch (lua.typeOf(-1)) {
        .nil => null,
        .string => blk: {
            const s = bridgeLuaString(lua, -1, "failed to read command callback field") orelse break :blk null;
            if (s.len == 0) break :blk null;
            break :blk dupeBridgeString(allocator, s, "failed to allocate command callback field");
        },
        .function => parsePromptCallbackField(lua, allocator, field_name),
        else => blk: {
            const msg = std.fmt.allocPrint(allocator, "{s} must be string command or function(ctx)", .{field_name}) catch "command field type is invalid";
            defer if (!std.mem.eql(u8, msg, "command field type is invalid")) allocator.free(msg);
            _ = lua.pushString(msg);
            lua.raiseError();
            break :blk null;
        },
    };
}

fn rejectRemovedField(lua: *Lua, allocator: std.mem.Allocator, table_idx: i32, base_path: []const u8, field_name: []const u8, guidance: []const u8) void {
    const field_z = allocator.dupeZ(u8, field_name) catch |err| {
        log.warn("failed to allocate removed-field lookup key '{s}': {}", .{ field_name, err });
        return;
    };
    defer allocator.free(field_z);

    _ = lua.getField(table_idx, field_z);
    defer lua.pop(1);
    if (lua.typeOf(-1) == .nil) return;

    const msg = std.fmt.allocPrint(allocator, "{s}.{s} is removed; use {s}", .{ base_path, field_name, guidance }) catch "removed field is not supported";
    defer if (!std.mem.eql(u8, msg, "removed field is not supported")) allocator.free(msg);
    _ = lua.pushString(msg);
    lua.raiseError();
}

/// Result of parsing a key array
pub const ParsedKey = struct {
    mods: u8, // Bitmask of modifiers
    key: config.Config.BindKey,
};

/// Parse Lua array of keys into mods + key
/// Format: { hexe.key.ctrl, hexe.key.alt, hexe.key.q }
/// Modifiers are prefixed with "mod:", actual keys are not
pub fn parseKeyArray(lua: *Lua, table_idx: i32) ?ParsedKey {
    if (lua.typeOf(table_idx) != .table) return null;

    var mods: u8 = 0;
    var key: ?config.Config.BindKey = null;

    const len = lua.rawLen(table_idx);
    var i: i32 = 1;
    while (i <= len) : (i += 1) {
        _ = lua.rawGetIndex(table_idx, i);

        const elem = bridgeLuaString(lua, -1, "failed to read key sequence element") orelse {
            lua.pop(1);
            continue;
        };

        // Check if it's a modifier (prefixed with "mod:")
        if (std.mem.startsWith(u8, elem, "mod:")) {
            const mod_name = elem[4..];
            if (std.mem.eql(u8, mod_name, "ctrl")) {
                mods |= 2;
            } else if (std.mem.eql(u8, mod_name, "alt")) {
                mods |= 1;
            } else if (std.mem.eql(u8, mod_name, "shift")) {
                mods |= 4;
            } else if (std.mem.eql(u8, mod_name, "super")) {
                mods |= 8;
            }
        } else {
            // It's a key
            if (parseKeyString(elem)) |k| {
                key = k;
            }
        }
        lua.pop(1);
    }

    if (key) |k| {
        const result = ParsedKey{ .mods = mods, .key = k };
        return result;
    }

    return null;
}

/// Parse action string into BindAction
/// Handles simple actions like "mux.quit", "tab.new", etc.
fn parseSimpleAction(action_str: []const u8) ?config.Config.BindAction {
    if (std.mem.eql(u8, action_str, "mux.quit")) return .mux_quit;
    if (std.mem.eql(u8, action_str, "mux.detach")) return .mux_detach;
    if (std.mem.eql(u8, action_str, "pane.disown")) return .pane_disown;
    if (std.mem.eql(u8, action_str, "pane.adopt")) return .pane_adopt;
    if (std.mem.eql(u8, action_str, "pane.close")) return .pane_close;
    if (std.mem.eql(u8, action_str, "pane.select_mode")) return .pane_select_mode;
    if (std.mem.eql(u8, action_str, "pane.sync_toggle")) return .sync_toggle;
    if (std.mem.eql(u8, action_str, "tab.rename")) return .tab_rename;
    if (std.mem.eql(u8, action_str, "pane.zoom")) return .pane_zoom;
    if (std.mem.eql(u8, action_str, "config.reload")) return .config_reload;
    if (std.mem.eql(u8, action_str, "copy.enter")) return .copy_enter;
    if (std.mem.eql(u8, action_str, "search.enter")) return .search_enter;
    if (std.mem.eql(u8, action_str, "prompt.previous")) return .prompt_previous;
    if (std.mem.eql(u8, action_str, "prompt.next")) return .prompt_next;
    if (std.mem.eql(u8, action_str, "prompt.copy_output")) return .prompt_copy_output;
    if (std.mem.eql(u8, action_str, "clipboard.copy")) return .clipboard_copy;
    if (std.mem.eql(u8, action_str, "clipboard.request")) return .clipboard_request;
    if (std.mem.eql(u8, action_str, "system.notify")) return .system_notify;
    if (std.mem.eql(u8, action_str, "overlay.keycast_toggle")) return .keycast_toggle;
    if (std.mem.eql(u8, action_str, "overlay.sprite_toggle")) return .sprite_toggle;
    if (std.mem.eql(u8, action_str, "split.h")) return .split_h;
    if (std.mem.eql(u8, action_str, "split.v")) return .split_v;
    if (std.mem.eql(u8, action_str, "tab.new")) return .tab_new;
    if (std.mem.eql(u8, action_str, "tab.next")) return .tab_next;
    if (std.mem.eql(u8, action_str, "tab.prev")) return .tab_prev;
    if (std.mem.eql(u8, action_str, "tab.close")) return .tab_close;
    if (std.mem.eql(u8, action_str, "layout.save")) return .layout_save;
    if (std.mem.eql(u8, action_str, "layout.load")) return .layout_load;
    return null;
}

test "prompt actions parse through the config builder bridge" {
    try std.testing.expectEqual(config.Config.BindAction.prompt_previous, parseSimpleAction("prompt.previous").?);
    try std.testing.expectEqual(config.Config.BindAction.prompt_next, parseSimpleAction("prompt.next").?);
    try std.testing.expectEqual(config.Config.BindAction.prompt_copy_output, parseSimpleAction("prompt.copy_output").?);
}

/// Parse action from Lua (string or table with parameters)
pub fn parseAction(lua: *Lua, idx: i32) ?config.Config.BindAction {
    const action_type = lua.typeOf(idx);

    // A function IS the action: `action = function() ... end`. Registered like
    // a `when` predicate and invoked with the same live API bound, so a binding
    // can do anything Lua can rather than only what the action enum names.
    if (action_type == .function) {
        const builder = getConfigBuilder(lua) orelse return null;
        lua.pushValue(idx);
        defer lua.pop(1);
        const ref = parsePromptValueChunkValue(lua, builder.allocator, false) orelse return null;
        return .{ .lua = ref };
    }

    // Simple string action
    if (action_type == .string) {
        const action_str = bridgeLuaString(lua, idx, "failed to read bind action string") orelse return null;
        return parseSimpleAction(action_str);
    }

    // Table action with parameters (e.g., {type="focus.move", dir="up"})
    if (action_type == .table) {
        _ = lua.getField(idx, "type");
        const type_str = lua.toString(-1) catch {
            lua.pop(1);
            return null;
        };
        lua.pop(1); // Pop type immediately after using it!

        // Parametric actions
        if (std.mem.eql(u8, type_str, "split.resize")) {
            _ = lua.getField(idx, "dir");
            const dir_str = lua.toString(-1) catch {
                lua.pop(1);
                return null;
            };
            lua.pop(1);
            const dir = std.meta.stringToEnum(config.Config.BindKeyKind, dir_str) orelse return null;
            if (dir != .up and dir != .down and dir != .left and dir != .right) return null;
            return .{ .split_resize = dir };
        }

        if (std.mem.eql(u8, type_str, "float.toggle")) {
            _ = lua.getField(idx, "float");
            const float_key = lua.toString(-1) catch {
                lua.pop(1);
                return null;
            };
            lua.pop(1);
            if (float_key.len != 1) return null;
            return .{ .float_toggle = float_key[0] };
        }

        if (std.mem.eql(u8, type_str, "float.nudge")) {
            _ = lua.getField(idx, "dir");
            const dir_str = lua.toString(-1) catch {
                lua.pop(1);
                return null;
            };
            lua.pop(1);
            const dir = std.meta.stringToEnum(config.Config.BindKeyKind, dir_str) orelse return null;
            if (dir != .up and dir != .down and dir != .left and dir != .right) return null;
            return .{ .float_nudge = dir };
        }

        if (std.mem.eql(u8, type_str, "focus.move")) {
            _ = lua.getField(idx, "dir");
            const dir_str = lua.toString(-1) catch {
                lua.pop(1); // Pop "dir" value before returning
                return null;
            };
            const dir = std.meta.stringToEnum(config.Config.BindKeyKind, dir_str) orelse {
                lua.pop(1); // Pop "dir" value before returning
                return null;
            };
            if (dir != .up and dir != .down and dir != .left and dir != .right) {
                lua.pop(1);
                return null;
            }
            lua.pop(1); // Pop the "dir" value before returning
            return .{ .focus_move = dir };
        }

        // Fall back to simple action if type matches
        return parseSimpleAction(type_str);
    }

    return null;
}

// ===== MUX API Functions =====

/// Parse a bind's `when`.
///
/// A condition is a Lua predicate and nothing else: `when = function(ctx) ...
/// end`. It is stored as a callback-registry reference and invoked at keypress
/// with the live query API bound, so a condition is written as ordinary Lua
/// against real state rather than as a token language:
///
///     when = function() return hexe.pane().process == "nvim" end
///     when = function() return #hexe.floats{ visible = true } > 0 end
///
/// This replaced a token/table DSL (`all`/`any`/`env`/`bash` and bare-string
/// tokens). The DSL could express only a fixed vocabulary someone had to extend
/// in Zig for every new question; a function can ask anything the API exposes.
fn parseWhenNoRaise(lua: *Lua, idx: i32, allocator: std.mem.Allocator) !?[]const u8 {
    if (lua.typeOf(idx) == .nil) return null;
    if (lua.typeOf(idx) != .function) return error.InvalidKeyBinding;

    lua.pushValue(idx);
    defer lua.pop(1);

    return parsePromptValueChunkValue(lua, allocator, false) orelse error.OutOfMemory;
}

pub fn appendKeyBindingsFromArray(lua: *Lua, idx: i32, mux: *config_builder.MuxConfigBuilder) !void {
    if (lua.typeOf(idx) != .table) return;

    const len = lua.rawLen(idx);
    var i: i32 = 1;
    while (i <= len) : (i += 1) {
        _ = lua.rawGetIndex(idx, i);

        if (lua.typeOf(-1) != .table) {
            lua.pop(1);
            return error.InvalidKeyBinding;
        }

        _ = lua.getField(-1, "key");
        const parsed_key = parseKeyArray(lua, -1) orelse {
            lua.pop(2);
            return error.InvalidKeyBinding;
        };
        lua.pop(1);

        _ = lua.getField(-1, "action");
        var action: config.Config.BindAction = .mux_quit;
        var action_found = false;
        if (lua.typeOf(-1) != .nil) {
            action = parseAction(lua, -1) orelse {
                lua.pop(2);
                return error.InvalidKeyBinding;
            };
            action_found = true;
        }
        lua.pop(1);

        _ = lua.getField(-1, "mode");
        var mode: config.Config.BindMode = .act_and_consume;
        if (lua.typeOf(-1) == .string) {
            const mode_str = lua.toString(-1) catch "act_and_consume";
            mode = std.meta.stringToEnum(config.Config.BindMode, mode_str) orelse .act_and_consume;
        }
        lua.pop(1);

        if (!action_found and mode != .passthrough_only) {
            lua.pop(1);
            return error.InvalidKeyBinding;
        }

        _ = lua.getField(-1, "when");
        const when = parseWhenNoRaise(lua, -1, mux.allocator) catch |err| {
            lua.pop(2);
            return err;
        };
        lua.pop(1);

        _ = lua.getField(-1, "on");
        var on: config.Config.BindWhen = .press;
        if (lua.typeOf(-1) == .string) {
            const on_str = lua.toString(-1) catch "press";
            on = std.meta.stringToEnum(config.Config.BindWhen, on_str) orelse .press;
        }
        lua.pop(1);

        _ = lua.getField(-1, "hold_ms");
        var hold_ms: ?i64 = null;
        if (lua.typeOf(-1) == .number) {
            const val = luaNumberOrRaise(lua, -1, "keys: failed to parse hold_ms");
            hold_ms = @intFromFloat(val);
        }
        lua.pop(1);

        const bind = config.Config.Bind{
            .on = on,
            .mods = parsed_key.mods,
            .key = parsed_key.key,
            .action = action,
            .when = when,
            .mode = mode,
            .hold_ms = hold_ms,
        };
        mux.binds.append(mux.allocator, bind) catch |err| {
            lua.pop(1);
            return err;
        };
        lua.pop(1);
    }
}

// ===== SES API Functions =====

/// Parse a float's `add_env` table into owned "KEY=VALUE" entries.
///
/// Both shapes are accepted, because both read naturally in a config:
///   add_env = { FOO = "bar", DEBUG = 1 }   -- map form
///   add_env = { "FOO=bar", "DEBUG=1" }     -- array form
/// Values may be strings, numbers or booleans; anything else is skipped.
fn parseFloatEnv(lua: *Lua, idx: i32, allocator: std.mem.Allocator) []const []const u8 {
    const table_idx = lua.absIndex(idx);
    _ = lua.getField(table_idx, "add_env");
    defer lua.pop(1);
    if (lua.typeOf(-1) != .table) return &.{};
    const env_idx = lua.getTop();

    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |e| allocator.free(@constCast(e));
        list.deinit(allocator);
    }

    lua.pushNil();
    while (lua.next(env_idx)) {
        // Stack: ... key value. Never call toString on the key itself: for a
        // numeric key that rewrites it in place and derails `next`.
        const key_type = lua.typeOf(-2);
        const entry: ?[]u8 = blk: {
            const value = luaScalarToString(lua, -1, allocator) orelse break :blk null;
            defer allocator.free(value);
            if (key_type == .string) {
                const key = lua.toString(-2) catch break :blk null;
                if (key.len == 0) break :blk null;
                break :blk std.fmt.allocPrint(allocator, "{s}={s}", .{ key, value }) catch null;
            }
            // Array form: the value must already be KEY=VALUE.
            if (std.mem.indexOfScalar(u8, value, '=') == null) break :blk null;
            break :blk allocator.dupe(u8, value) catch null;
        };
        if (entry) |e| {
            list.append(allocator, e) catch allocator.free(e);
        }
        lua.pop(1); // pop value, keep key for next()
    }

    return list.toOwnedSlice(allocator) catch {
        for (list.items) |e| allocator.free(@constCast(e));
        list.deinit(allocator);
        return &.{};
    };
}

/// Stringify a string/number/boolean at `index` into an owned buffer.
fn luaScalarToString(lua: *Lua, index: i32, allocator: std.mem.Allocator) ?[]u8 {
    return switch (lua.typeOf(index)) {
        .string => blk: {
            const s = lua.toString(index) catch break :blk null;
            break :blk allocator.dupe(u8, s) catch null;
        },
        .number => blk: {
            const n = lua.toNumber(index) catch break :blk null;
            if (!std.math.isFinite(n)) break :blk null;
            if (n == @trunc(n)) {
                break :blk std.fmt.allocPrint(allocator, "{d}", .{@as(i64, @intFromFloat(n))}) catch null;
            }
            break :blk std.fmt.allocPrint(allocator, "{d}", .{n}) catch null;
        },
        .boolean => allocator.dupe(u8, if (lua.toBoolean(index)) "1" else "0") catch null,
        else => null,
    };
}

/// Parse a float's `add_path` into owned directory strings.
/// Accepts a single string or an array of strings.
fn parseFloatPathAdd(lua: *Lua, idx: i32, allocator: std.mem.Allocator) []const []const u8 {
    const table_idx = lua.absIndex(idx);
    _ = lua.getField(table_idx, "add_path");
    defer lua.pop(1);

    var list = std.ArrayList([]const u8).empty;
    const append = struct {
        fn call(l: *std.ArrayList([]const u8), a: std.mem.Allocator, raw: []const u8) void {
            const trimmed = std.mem.trim(u8, raw, " \t");
            if (trimmed.len == 0) return;
            const duped = a.dupe(u8, trimmed) catch return;
            l.append(a, duped) catch a.free(duped);
        }
    }.call;

    switch (lua.typeOf(-1)) {
        .string => {
            const s = lua.toString(-1) catch return &.{};
            append(&list, allocator, s);
        },
        .table => {
            const len = lua.rawLen(-1);
            var i: i32 = 1;
            while (i <= len) : (i += 1) {
                _ = lua.rawGetIndex(-1, i);
                defer lua.pop(1);
                const s = lua.toString(-1) catch continue;
                append(&list, allocator, s);
            }
        },
        else => return &.{},
    }

    return list.toOwnedSlice(allocator) catch {
        for (list.items) |p| allocator.free(@constCast(p));
        list.deinit(allocator);
        return &.{};
    };
}

/// Parse a LayoutFloatDef from a Lua table at idx
fn parseLayoutFloat(lua: *Lua, idx: i32, allocator: std.mem.Allocator) ?config.LayoutFloatDef {
    if (lua.typeOf(idx) != .table) {
        return null;
    }

    rejectRemovedField(lua, allocator, idx, "ses.layout.float", "padding", "mux.floats defaults/adhoc/match");
    rejectRemovedField(lua, allocator, idx, "ses.layout.float", "color", "mux.floats defaults/adhoc/match");
    rejectRemovedField(lua, allocator, idx, "ses.layout.float", "style", "mux.floats defaults/adhoc/match");
    rejectRemovedField(lua, allocator, idx, "ses.layout.float", "attributes", "attrs");

    // Get key (required)
    _ = lua.getField(idx, "key");
    const key_str = lua.toString(-1) catch {
        lua.pop(1);
        return null;
    };
    if (key_str.len != 1) {
        lua.pop(1);
        return null;
    }
    const key = key_str[0];
    lua.pop(1);

    // Create float with defaults
    var float_def = config.LayoutFloatDef{
        .key = key,
    };

    // Parse enabled
    _ = lua.getField(idx, "enabled");
    if (lua.typeOf(-1) == .boolean) {
        float_def.enabled = lua.toBoolean(-1);
    }
    lua.pop(1);

    // Parse command
    _ = lua.getField(idx, "command");
    if (lua.typeOf(-1) == .string) {
        const cmd = lua.toString(-1) catch {
            lua.pop(1);
            return null;
        };
        float_def.command = dupeBridgeString(allocator, cmd, "failed to allocate layout float command");
    }
    lua.pop(1);

    // Parse title
    _ = lua.getField(idx, "title");
    if (lua.typeOf(-1) == .string) {
        const title = lua.toString(-1) catch {
            lua.pop(1);
            return null;
        };
        float_def.title = dupeBridgeString(allocator, title, "failed to allocate layout float title");
    }
    lua.pop(1);

    // Parse attrs table
    _ = lua.getField(idx, "attrs");
    if (lua.typeOf(-1) == .table) {
        float_def.has_custom_attributes = true;

        _ = lua.getField(-1, "per_cwd");
        if (lua.typeOf(-1) == .boolean) {
            float_def.attributes.per_cwd = lua.toBoolean(-1);
        }
        lua.pop(1);

        _ = lua.getField(-1, "global");
        if (lua.typeOf(-1) == .boolean) {
            float_def.attributes.global = lua.toBoolean(-1);
        }
        lua.pop(1);

        _ = lua.getField(-1, "exclusive");
        if (lua.typeOf(-1) == .boolean) {
            float_def.attributes.exclusive = lua.toBoolean(-1);
        }
        lua.pop(1);

        _ = lua.getField(-1, "sticky");
        if (lua.typeOf(-1) == .boolean) {
            float_def.attributes.sticky = lua.toBoolean(-1);
        }
        lua.pop(1);

        _ = lua.getField(-1, "destroy");
        if (lua.typeOf(-1) == .boolean) {
            float_def.attributes.destroy = lua.toBoolean(-1);
        }
        lua.pop(1);

        _ = lua.getField(-1, "navigatable");
        if (lua.typeOf(-1) == .boolean) {
            float_def.attributes.navigatable = lua.toBoolean(-1);
        }
        lua.pop(1);

        _ = lua.getField(-1, "isolated");
        if (lua.typeOf(-1) == .boolean) {
            float_def.attributes.isolated = lua.toBoolean(-1);
        }
        lua.pop(1);

        _ = lua.getField(-1, "inherit_env");
        if (lua.typeOf(-1) == .boolean) {
            float_def.attributes.inherit_env = lua.toBoolean(-1);
        }
        lua.pop(1);
    }
    lua.pop(1); // pop attributes table

    // Parse size table
    _ = lua.getField(idx, "size");
    if (lua.typeOf(-1) == .table) {
        _ = lua.getField(-1, "width");
        if (lua.typeOf(-1) == .number) {
            const w = luaNumberOrRaise(lua, -1, "float.define: failed to parse size.width");
            if (std.math.isFinite(w)) {
                float_def.width_percent = @intFromFloat(std.math.clamp(w, 0, 100));
            }
        }
        lua.pop(1);

        _ = lua.getField(-1, "height");
        if (lua.typeOf(-1) == .number) {
            const h = luaNumberOrRaise(lua, -1, "float.define: failed to parse size.height");
            if (std.math.isFinite(h)) {
                float_def.height_percent = @intFromFloat(std.math.clamp(h, 0, 100));
            }
        }
        lua.pop(1);
    }
    lua.pop(1); // pop size table

    // Parse position table
    _ = lua.getField(idx, "position");
    if (lua.typeOf(-1) == .table) {
        _ = lua.getField(-1, "x");
        if (lua.typeOf(-1) == .number) {
            const x = luaNumberOrRaise(lua, -1, "float.define: failed to parse position.x");
            if (std.math.isFinite(x)) {
                float_def.pos_x = @intFromFloat(std.math.clamp(x, 0, 100));
            }
        }
        lua.pop(1);

        _ = lua.getField(-1, "y");
        if (lua.typeOf(-1) == .number) {
            const y = luaNumberOrRaise(lua, -1, "float.define: failed to parse position.y");
            if (std.math.isFinite(y)) {
                float_def.pos_y = @intFromFloat(std.math.clamp(y, 0, 100));
            }
        }
        lua.pop(1);
    }
    lua.pop(1); // pop position table

    // Parse isolation table
    _ = lua.getField(idx, "isolation");
    if (lua.typeOf(-1) == .table) {
        var isolation = config.IsolationConfig{
            .profile = dupeBridgeString(allocator, "default", "failed to allocate default float isolation profile") orelse return null,
        };

        // Parse profile
        _ = lua.getField(-1, "profile");
        if (lua.typeOf(-1) == .string) {
            const profile_str = lua.toString(-1) catch "";
            if (profile_str.len > 0) {
                allocator.free(isolation.profile);
                isolation.profile = dupeBridgeString(allocator, profile_str, "failed to allocate float isolation profile") orelse return null;
            }
        }
        lua.pop(1);

        // Parse memory
        _ = lua.getField(-1, "memory");
        if (lua.typeOf(-1) == .string) {
            const mem_str = bridgeLuaString(lua, -1, "failed to read float isolation memory limit");
            if (mem_str) |m| {
                isolation.memory = dupeBridgeString(allocator, m, "failed to allocate float isolation memory limit");
            }
        }
        lua.pop(1);

        // Parse cpu
        _ = lua.getField(-1, "cpu");
        if (lua.typeOf(-1) == .string) {
            const cpu_str = bridgeLuaString(lua, -1, "failed to read float isolation cpu limit");
            if (cpu_str) |cpu_val| {
                isolation.cpu = dupeBridgeString(allocator, cpu_val, "failed to allocate float isolation cpu limit");
            }
        }
        lua.pop(1);

        // Parse pids (can be string or number)
        _ = lua.getField(-1, "pids");
        if (lua.typeOf(-1) == .string) {
            const pids_str = bridgeLuaString(lua, -1, "failed to read float isolation pids limit");
            if (pids_str) |p| {
                isolation.pids = dupeBridgeString(allocator, p, "failed to allocate float isolation pids limit");
            }
        } else if (lua.typeOf(-1) == .number) {
            const pids_num = lua.toNumber(-1) catch 0;
            var buf: [32]u8 = undefined;
            const pids_str = std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(pids_num))}) catch "";
            if (pids_str.len > 0) {
                isolation.pids = dupeBridgeString(allocator, pids_str, "failed to allocate numeric float isolation pids limit");
            }
        }
        lua.pop(1);

        float_def.isolation = isolation;
    }
    lua.pop(1); // pop isolation table

    float_def.env = parseFloatEnv(lua, idx, allocator);
    float_def.path_add = parseFloatPathAdd(lua, idx, allocator);

    return float_def;
}

fn parseLayoutStringArray(lua: *Lua, idx: i32, key: [:0]const u8, allocator: std.mem.Allocator) [][]const u8 {
    _ = lua.getField(idx, key);
    defer lua.pop(1);
    if (lua.typeOf(-1) != .table) return &.{};
    const len = lua.rawLen(-1);
    if (len == 0) return &.{};

    var list = std.ArrayList([]const u8).empty;
    var i: i32 = 1;
    while (i <= len) : (i += 1) {
        _ = lua.rawGetIndex(-1, i);
        defer lua.pop(1);
        const str = lua.toString(-1) catch continue;
        const duped = allocator.dupe(u8, str) catch continue;
        list.append(allocator, duped) catch {
            allocator.free(duped);
            continue;
        };
    }
    return list.toOwnedSlice(allocator) catch {
        for (list.items) |cmd| allocator.free(cmd);
        list.deinit(allocator);
        return &.{};
    };
}

pub fn parseLayoutDef(lua: *Lua, idx: i32, allocator: std.mem.Allocator) !config.LayoutDef {
    if (lua.typeOf(idx) != .table) return error.InvalidLayout;

    _ = lua.getField(idx, "name");
    const name_str = lua.toString(-1) catch {
        lua.pop(1);
        return error.InvalidLayout;
    };
    lua.pop(1);

    const name = try allocator.dupe(u8, name_str);
    errdefer allocator.free(name);

    // Parse enabled
    _ = lua.getField(idx, "enabled");
    const enabled = if (lua.typeOf(-1) == .boolean)
        lua.toBoolean(-1)
    else
        true;
    lua.pop(1);

    // Parse tabs array
    var tabs = std.ArrayList(config.LayoutTabDef){};
    errdefer {
        for (tabs.items) |*tab| tab.deinit(allocator);
        tabs.deinit(allocator);
    }
    _ = lua.getField(idx, "tabs");
    if (lua.typeOf(-1) == .table) {
        const tabs_len = lua.rawLen(-1);
        var i: i32 = 1;
        while (i <= tabs_len) : (i += 1) {
            _ = lua.rawGetIndex(-1, i);
            if (lua.typeOf(-1) == .table) {
                // Parse tab
                _ = lua.getField(-1, "name");
                const tab_name_str = lua.toString(-1) catch {
                    lua.pop(2); // pop name and tab
                    continue;
                };
                const tab_name = allocator.dupe(u8, tab_name_str) catch {
                    lua.pop(2);
                    continue;
                };
                lua.pop(1); // pop name

                // Parse root split
                _ = lua.getField(-1, "root");
                const root = if (lua.typeOf(-1) == .table)
                    parseLayoutSplit(lua, -1, allocator)
                else
                    null;
                lua.pop(1); // pop root

                const root_value: ?config.LayoutSplitDef = if (root) |r| blk: {
                    const value = r.*;
                    allocator.destroy(r);
                    break :blk value;
                } else null;

                var tab = config.LayoutTabDef{
                    .name = tab_name,
                    .enabled = true,
                    .root = root_value,
                };
                tabs.append(allocator, tab) catch |err| {
                    log.warn("layout '{s}' tab '{s}': failed to append tab: {}", .{ name_str, tab_name, err });
                    tab.deinit(allocator);
                };
            }
            lua.pop(1); // pop tab
        }
    }
    lua.pop(1); // pop tabs array

    // Parse floats array
    var floats = std.ArrayList(config.LayoutFloatDef).empty;
    errdefer {
        for (floats.items) |*float_def| float_def.deinit(allocator);
        floats.deinit(allocator);
    }
    _ = lua.getField(idx, "floats");
    if (lua.typeOf(-1) == .table) {
        const floats_len = lua.rawLen(-1);
        var i: i32 = 1;
        while (i <= floats_len) : (i += 1) {
            _ = lua.rawGetIndex(-1, i);
            if (parseLayoutFloat(lua, -1, allocator)) |parsed_float| {
                var float_def = parsed_float;
                floats.append(allocator, float_def) catch |err| {
                    log.warn("layout '{s}' floats[{d}]: failed to append float: {}", .{ name_str, i, err });
                    float_def.deinit(allocator);
                };
            }
            lua.pop(1); // pop float table
        }
    }
    lua.pop(1); // pop floats array

    // Create layout
    const layout = config.LayoutDef{
        .name = name,
        .enabled = enabled,
        .tabs = try tabs.toOwnedSlice(allocator),
        .floats = try floats.toOwnedSlice(allocator),
        .on_start = parseLayoutStringArray(lua, idx, "on_start", allocator),
        .on_stop = parseLayoutStringArray(lua, idx, "on_stop", allocator),
    };

    return layout;
}

// ============================================================================
// Section 3: SHP (Shell Prompt) C API
// ============================================================================

fn callbackFieldPathAlloc(allocator: std.mem.Allocator, base_path: []const u8, field_name: []const u8) ?[]u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ base_path, field_name }) catch |err| {
        log.warn("failed to format API bridge callback field path: {}", .{err});
        return null;
    };
}

// ============================================================================
// Section 4: POP (Popups & Overlays) C API
// ============================================================================

test "parseLayoutFloat reads canonical attrs table" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.deinit();

    const chunk =
        "float = {" ++
        "key='g'," ++
        "command='lazygit'," ++
        "attrs={ global=true, per_cwd=true, inherit_env=true }" ++
        "}";
    const z = try std.testing.allocator.dupeZ(u8, chunk);
    defer std.testing.allocator.free(z);
    try lua.loadString(z);
    try lua.protectedCall(.{ .args = 0, .results = 0 });

    _ = try lua.getGlobal("float");
    defer lua.pop(1);

    var float = parseLayoutFloat(lua, -1, std.testing.allocator) orelse return error.TestUnexpectedResult;
    defer float.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 'g'), float.key);
    try std.testing.expect(float.has_custom_attributes);
    try std.testing.expect(float.attributes.global);
    try std.testing.expect(float.attributes.per_cwd);
    try std.testing.expect(float.attributes.inherit_env);
}

test "parseLayoutFloat reads add_env map form and add_path list" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.deinit();

    const chunk =
        "float = {" ++
        "key='g'," ++
        "command='lazygit'," ++
        "add_env={ EDITOR='hx', DEBUG=1 }," ++
        "add_path={ '/opt/bin', ' /home/me/.local/bin ' }" ++
        "}";
    const z = try std.testing.allocator.dupeZ(u8, chunk);
    defer std.testing.allocator.free(z);
    try lua.loadString(z);
    try lua.protectedCall(.{ .args = 0, .results = 0 });

    _ = try lua.getGlobal("float");
    defer lua.pop(1);

    var float = parseLayoutFloat(lua, -1, std.testing.allocator) orelse return error.TestUnexpectedResult;
    defer float.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), float.env.len);
    var saw_editor = false;
    var saw_debug = false;
    for (float.env) |entry| {
        if (std.mem.eql(u8, entry, "EDITOR=hx")) saw_editor = true;
        if (std.mem.eql(u8, entry, "DEBUG=1")) saw_debug = true;
    }
    try std.testing.expect(saw_editor);
    try std.testing.expect(saw_debug);

    try std.testing.expectEqual(@as(usize, 2), float.path_add.len);
    try std.testing.expectEqualStrings("/opt/bin", float.path_add[0]);
    try std.testing.expectEqualStrings("/home/me/.local/bin", float.path_add[1]);
}

test "parseLayoutFloat reads add_env array form and rejects entries without '='" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.deinit();

    const chunk =
        "float = {" ++
        "key='g'," ++
        "add_env={ 'FOO=bar', 'nonsense' }," ++
        "add_path='/single/dir'" ++
        "}";
    const z = try std.testing.allocator.dupeZ(u8, chunk);
    defer std.testing.allocator.free(z);
    try lua.loadString(z);
    try lua.protectedCall(.{ .args = 0, .results = 0 });

    _ = try lua.getGlobal("float");
    defer lua.pop(1);

    var float = parseLayoutFloat(lua, -1, std.testing.allocator) orelse return error.TestUnexpectedResult;
    defer float.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), float.env.len);
    try std.testing.expectEqualStrings("FOO=bar", float.env[0]);
    try std.testing.expectEqual(@as(usize, 1), float.path_add.len);
    try std.testing.expectEqualStrings("/single/dir", float.path_add[0]);
}

test "parseLayoutDef canonicalizes split directions and child sizes" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.deinit();

    const chunk =
        "layout = {" ++
        "name='unit'," ++
        "tabs={ {" ++
        "name='main'," ++
        "root={ dir='horizontal', { size=30 }, { size=70 } }" ++
        "} }" ++
        "}";
    const z = try std.testing.allocator.dupeZ(u8, chunk);
    defer std.testing.allocator.free(z);
    try lua.loadString(z);
    try lua.protectedCall(.{ .args = 0, .results = 0 });

    _ = try lua.getGlobal("layout");
    defer lua.pop(1);

    var layout = try parseLayoutDef(lua, -1, std.testing.allocator);
    defer layout.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), layout.tabs.len);
    const root = layout.tabs[0].root orelse return error.TestUnexpectedResult;
    switch (root) {
        .split => |split| {
            try std.testing.expectEqualStrings("h", split.dir);
            try std.testing.expect(@abs(split.ratio - @as(f32, 0.3)) < 0.001);
        },
        .pane => return error.TestUnexpectedResult,
    }
}

test "parseLayoutDef preserves n-ary split children" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.deinit();

    const chunk =
        "layout = {" ++
        "name='unit'," ++
        "tabs={ {" ++
        "name='main'," ++
        "root={ dir='vertical', { size=20 }, { size=30 }, { size=50 } }" ++
        "} }" ++
        "}";
    const z = try std.testing.allocator.dupeZ(u8, chunk);
    defer std.testing.allocator.free(z);
    try lua.loadString(z);
    try lua.protectedCall(.{ .args = 0, .results = 0 });

    _ = try lua.getGlobal("layout");
    defer lua.pop(1);

    var layout = try parseLayoutDef(lua, -1, std.testing.allocator);
    defer layout.deinit(std.testing.allocator);

    const root = layout.tabs[0].root orelse return error.TestUnexpectedResult;
    switch (root) {
        .split => |split| {
            try std.testing.expectEqualStrings("v", split.dir);
            try std.testing.expect(@abs(split.ratio - @as(f32, 0.2)) < 0.001);
            switch (split.second.*) {
                .split => |nested| {
                    try std.testing.expectEqualStrings("v", nested.dir);
                    try std.testing.expect(@abs(nested.ratio - @as(f32, 0.375)) < 0.001);
                },
                .pane => return error.TestUnexpectedResult,
            }
        },
        .pane => return error.TestUnexpectedResult,
    }
}
