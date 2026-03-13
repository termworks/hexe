const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaState = zlua.LuaState;
const config_builder = @import("config_builder.zig");
const ConfigBuilder = config_builder.ConfigBuilder;
const config = @import("config.zig");

// Import C standard library functions
const c = @cImport({
    @cInclude("stdlib.h");
});

/// Registry key for storing ConfigBuilder pointer
const BUILDER_REGISTRY_KEY = "_hexe_config_builder";
const CALLBACK_TABLE_KEY = "__hexe_cb_table";
const CALLBACK_NEXT_ID_KEY = "__hexe_cb_next_id";
const CALLBACK_REF_PREFIX = "__hexe_cb_ref:";

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

    const ptr = lua.toPointer(-1) catch return null;
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

/// Helper to get ShpConfigBuilder, creating it if needed
pub fn getShpBuilder(lua: *Lua) !*config_builder.ShpConfigBuilder {
    const builder = getConfigBuilder(lua) orelse return error.NoConfigBuilder;

    if (builder.shp == null) {
        builder.shp = try config_builder.ShpConfigBuilder.init(builder.allocator);
    }

    return builder.shp.?;
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
        return std.fmt.allocPrint(allocator, "{s}{d}", .{ CALLBACK_REF_PREFIX, callback_id }) catch null;
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
            const s = lua.toString(-1) catch break :blk null;
            if (s.len == 0) break :blk null;
            break :blk allocator.dupe(u8, s) catch null;
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
    const field_z = allocator.dupeZ(u8, field_name) catch return;
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
/// Format: { hx.key.ctrl, hx.key.alt, hx.key.q }
/// Modifiers are prefixed with "mod:", actual keys are not
pub fn parseKeyArray(lua: *Lua, table_idx: i32) ?ParsedKey {
    if (lua.typeOf(table_idx) != .table) return null;

    var mods: u8 = 0;
    var key: ?config.Config.BindKey = null;

    const len = lua.rawLen(table_idx);
    var i: i32 = 1;
    while (i <= len) : (i += 1) {
        _ = lua.rawGetIndex(table_idx, i);
        defer lua.pop(1);

        const elem = lua.toString(-1) catch continue;

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
    }

    if (key) |k| {
        const result = ParsedKey{ .mods = mods, .key = k };
        return result;
    }

    return null;
}

/// Parse a layout pane from Lua table
fn parseLayoutPane(lua: *Lua, idx: i32, allocator: std.mem.Allocator) ?config.LayoutPaneDef {
    var pane = config.LayoutPaneDef{};

    // Parse cwd
    _ = lua.getField(idx, "cwd");
    if (lua.typeOf(-1) == .string) {
        const cwd_str = lua.toString(-1) catch null;
        if (cwd_str) |cwd_val| {
            pane.cwd = allocator.dupe(u8, cwd_val) catch null;
        }
    }
    lua.pop(1);

    // Parse command
    _ = lua.getField(idx, "command");
    if (lua.typeOf(-1) == .string) {
        const cmd_str = lua.toString(-1) catch null;
        if (cmd_str) |cmd_val| {
            pane.command = allocator.dupe(u8, cmd_val) catch null;
        }
    }
    lua.pop(1);

    return pane;
}

/// Parse a layout split recursively from Lua table
fn parseLayoutSplit(lua: *Lua, idx: i32, allocator: std.mem.Allocator) ?*config.LayoutSplitDef {
    // Check if this is a split (has array elements) or a pane
    const array_len = lua.rawLen(idx);

    if (array_len >= 2) {
        // This is a split with children
        // Parse dir
        _ = lua.getField(idx, "dir");
        const dir_str = lua.toString(-1) catch "h";
        const dir = allocator.dupe(u8, dir_str) catch return null;
        lua.pop(1);

        // Parse ratio
        _ = lua.getField(idx, "ratio");
        const ratio_f64 = if (lua.typeOf(-1) == .number)
            lua.toNumber(-1) catch 0.5
        else
            0.5;
        const ratio: f32 = @floatCast(ratio_f64);
        lua.pop(1);

        // Parse first child
        _ = lua.rawGetIndex(idx, 1);
        const first_child = parseLayoutSplit(lua, -1, allocator) orelse {
            lua.pop(1);
            allocator.free(dir);
            return null;
        };
        lua.pop(1);

        // Parse second child
        _ = lua.rawGetIndex(idx, 2);
        const second_child = parseLayoutSplit(lua, -1, allocator) orelse {
            lua.pop(1);
            first_child.deinit(allocator);
            allocator.destroy(first_child);
            allocator.free(dir);
            return null;
        };
        lua.pop(1);

        // Create split
        const split = allocator.create(config.LayoutSplitDef) catch {
            first_child.deinit(allocator);
            allocator.destroy(first_child);
            second_child.deinit(allocator);
            allocator.destroy(second_child);
            allocator.free(dir);
            return null;
        };

        split.* = .{
            .split = .{
                .dir = dir,
                .ratio = ratio,
                .first = first_child,
                .second = second_child,
            },
        };

        return split;
    } else {
        // This is a pane
        const pane = parseLayoutPane(lua, idx, allocator) orelse return null;
        const split = allocator.create(config.LayoutSplitDef) catch return null;
        split.* = .{ .pane = pane };
        return split;
    }
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

/// Parse action from Lua (string or table with parameters)
pub fn parseAction(lua: *Lua, idx: i32) ?config.Config.BindAction {
    const action_type = lua.typeOf(idx);

    // Simple string action
    if (action_type == .string) {
        const action_str = lua.toString(idx) catch return null;
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

/// Lua C function: hexe.mux.config.set(key, value)
pub fn hexe_mux_config_set(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Get key (arg 1)
    const key = lua.toString(1) catch {
        _ = lua.pushString("config.set: key must be a string");
        lua.raiseError();
    };

    // Get MuxConfigBuilder
    const mux = getMuxBuilder(lua) catch {
        _ = lua.pushString("config.set: failed to get config builder");
        lua.raiseError();
    };

    // Type-based value parsing (arg 2)
    const val_type = lua.typeOf(2);

    // Boolean options
    if (val_type == .boolean) {
        const val = lua.toBoolean(2);
        if (std.mem.eql(u8, key, "confirm_on_exit")) {
            mux.confirm_on_exit = val;
        } else if (std.mem.eql(u8, key, "confirm_on_detach")) {
            mux.confirm_on_detach = val;
        } else if (std.mem.eql(u8, key, "confirm_on_disown")) {
            mux.confirm_on_disown = val;
        } else if (std.mem.eql(u8, key, "confirm_on_close")) {
            mux.confirm_on_close = val;
        } else {
            const msg = std.fmt.allocPrint(mux.allocator, "config.set: unknown boolean key '{s}'", .{key}) catch "config.set: unknown key";
            _ = lua.pushString(msg);
            lua.raiseError();
        }
        return 0;
    }

    // Number options
    if (val_type == .number) {
        const val_f64 = lua.toNumber(2) catch {
            _ = lua.pushString("config.set: failed to parse number");
            lua.raiseError();
        };

        if (std.mem.eql(u8, key, "selection_color")) {
            mux.selection_color = @intFromFloat(val_f64);
        } else if (std.mem.eql(u8, key, "mouse_selection_override_mods")) {
            mux.mouse_selection_override_mods = @intFromFloat(val_f64);
        } else {
            const msg = std.fmt.allocPrint(mux.allocator, "config.set: unknown number key '{s}'", .{key}) catch "config.set: unknown key";
            _ = lua.pushString(msg);
            lua.raiseError();
        }
        return 0;
    }

    // Unknown type
    _ = lua.pushString("config.set: value must be boolean or number");
    lua.raiseError();
}

/// Lua C function: hexe.mux.config.setup(opts)
pub export fn hexe_mux_config_setup(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Arg 1 must be a table
    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("config.setup: argument must be a table");
        lua.raiseError();
    }

    // Get MuxConfigBuilder once
    const mux = getMuxBuilder(lua) catch {
        _ = lua.pushString("config.setup: failed to get config builder");
        lua.raiseError();
    };

    // Iterate table and set values directly
    lua.pushNil(); // First key
    while (lua.next(1)) {
        // Stack: table, key, value
        // Check if key is a string
        if (lua.typeOf(-2) != .string) {
            _ = lua.pushString("config.setup: all keys must be strings");
            lua.raiseError();
        }

        const key = lua.toString(-2) catch unreachable; // Already checked it's a string
        const val_type = lua.typeOf(-1);

        // Boolean options
        if (val_type == .boolean) {
            const val = lua.toBoolean(-1);
            if (std.mem.eql(u8, key, "confirm_on_exit")) {
                mux.confirm_on_exit = val;
            } else if (std.mem.eql(u8, key, "confirm_on_detach")) {
                mux.confirm_on_detach = val;
            } else if (std.mem.eql(u8, key, "confirm_on_disown")) {
                mux.confirm_on_disown = val;
            } else if (std.mem.eql(u8, key, "confirm_on_close")) {
                mux.confirm_on_close = val;
            }
        }
        // Number options
        else if (val_type == .number) {
            const val_f64 = lua.toNumber(-1) catch 0;
            if (std.mem.eql(u8, key, "selection_color")) {
                mux.selection_color = @intFromFloat(val_f64);
            }
        }

        // Pop value, keep key for next iteration
        lua.pop(1);
    }

    return 0;
}

/// Parse keybinding `when` condition from a Lua value at the given index.
/// New contract: `when = function(ctx) return ... end`
fn parseWhen(lua: *Lua, idx: i32, allocator: std.mem.Allocator) ?config.WhenDef {
    const ty = lua.typeOf(idx);

    if (ty != .function) {
        _ = lua.pushString("keymap when must be function(ctx)");
        lua.raiseError();
    }

    lua.pushValue(idx);
    defer lua.pop(1);

    if (parsePromptCallbackField(lua, allocator, "when")) |code| {
        return .{ .lua = code };
    }

    _ = lua.pushString("failed to parse keymap when callback");
    lua.raiseError();
}

/// Lua C function: hexe.mux.keymap.set(bindings_array or key, action, opts)
/// Supports two formats:
/// 1. Array format: keymap.set({ {key={...}, action={...}}, {key={...}, action={...}} })
/// 2. Single format: keymap.set({key...}, {action...}, opts)
pub export fn hexe_mux_keymap_set(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Get MuxConfigBuilder
    const mux = getMuxBuilder(lua) catch {
        _ = lua.pushString("keymap.set: failed to get config builder");
        lua.raiseError();
    };

    // Check if arg 1 is an array of bindings (array format) or a key array (single format)
    if (lua.typeOf(1) == .table) {
        // Check if it's an array by getting element 1
        _ = lua.rawGetIndex(1, 1);
        const is_array = lua.typeOf(-1) == .table;
        lua.pop(1);

        if (is_array) {
            // Array format: iterate and parse each binding
            const len = lua.rawLen(1);
            var i: i32 = 1;
            while (i <= len) : (i += 1) {
                _ = lua.rawGetIndex(1, i);
                defer lua.pop(1);

                // Parse this binding table
                if (lua.typeOf(-1) != .table) {
                    std.debug.print("  bind[{}]: SKIP - not a table\n", .{i});
                    continue;
                }

                // Get key array
                _ = lua.getField(-1, "key");
                const parsed_key = parseKeyArray(lua, -1) orelse {
                    std.debug.print("  bind[{}]: SKIP - invalid key array\n", .{i});
                    lua.pop(1);
                    continue;
                };
                lua.pop(1);

                // Get optional action
                _ = lua.getField(-1, "action");
                var action: config.Config.BindAction = .mux_quit; // placeholder
                var action_found = false;
                if (lua.typeOf(-1) != .nil) {
                    action = parseAction(lua, -1) orelse {
                        std.debug.print("  bind[{}]: SKIP - invalid action\n", .{i});
                        lua.pop(1);
                        continue;
                    };
                    action_found = true;
                }
                lua.pop(1);

                // Get optional "mode"
                _ = lua.getField(-1, "mode");
                var mode: config.Config.BindMode = .act_and_consume;
                if (lua.typeOf(-1) == .string) {
                    const mode_str = lua.toString(-1) catch "act_and_consume";
                    mode = std.meta.stringToEnum(config.Config.BindMode, mode_str) orelse .act_and_consume;
                }
                lua.pop(1);

                // Validate action is present unless mode is passthrough_only
                if (!action_found and mode != .passthrough_only) {
                    std.debug.print("  bind[{}]: SKIP - no action and mode != passthrough_only\n", .{i});
                    continue; // Skip this binding
                }

                // Get optional "when" condition
                _ = lua.getField(-1, "when");
                const when = if (lua.typeOf(-1) != .nil) parseWhen(lua, -1, mux.allocator) else null;
                lua.pop(1);

                // Parse "on" field
                _ = lua.getField(-1, "on");
                var on: config.Config.BindWhen = .press;
                if (lua.typeOf(-1) == .string) {
                    const on_str = lua.toString(-1) catch "press";
                    on = std.meta.stringToEnum(config.Config.BindWhen, on_str) orelse .press;
                }
                lua.pop(1);

                // Parse "hold_ms" field
                _ = lua.getField(-1, "hold_ms");
                var hold_ms: ?i64 = null;
                if (lua.typeOf(-1) == .number) {
                    const val = lua.toNumber(-1) catch 0;
                    hold_ms = @intFromFloat(val);
                }
                lua.pop(1);

                // Create and append bind
                const bind = config.Config.Bind{
                    .on = on,
                    .mods = parsed_key.mods,
                    .key = parsed_key.key,
                    .action = action,
                    .when = when,
                    .mode = mode,
                    .hold_ms = hold_ms,
                };

                // Debug: check what we're appending

                mux.binds.append(mux.allocator, bind) catch {
                    _ = lua.pushString("keymap.set: failed to append binding");
                    lua.raiseError();
                };
            }
            return 0;
        }
    }

    // Single format: parse as before
    const parsed_key = parseKeyArray(lua, 1) orelse {
        _ = lua.pushString("keymap.set: invalid key array");
        lua.raiseError();
    };

    // Parse action (arg 2) - can be nil for passthrough_only mode
    var action: config.Config.BindAction = .mux_quit; // placeholder
    var action_found = false;

    if (lua.typeOf(2) != .nil) {
        action = parseAction(lua, 2) orelse {
            _ = lua.pushString("keymap.set: invalid action");
            lua.raiseError();
        };
        action_found = true;
    }

    // Parse opts table (arg 3, optional)
    var on: config.Config.BindWhen = .press;
    var mode: config.Config.BindMode = .act_and_consume;
    var hold_ms: ?i64 = null;
    var when: ?config.WhenDef = null;

    if (lua.typeOf(3) == .table) {
        // Parse "on" field
        _ = lua.getField(3, "on");
        if (lua.typeOf(-1) == .string) {
            const on_str = lua.toString(-1) catch "press";
            on = std.meta.stringToEnum(config.Config.BindWhen, on_str) orelse .press;
        }
        lua.pop(1);

        // Parse "mode" field
        _ = lua.getField(3, "mode");
        if (lua.typeOf(-1) == .string) {
            const mode_str = lua.toString(-1) catch "act_and_consume";
            mode = std.meta.stringToEnum(config.Config.BindMode, mode_str) orelse .act_and_consume;
        }
        lua.pop(1);

        // Parse "hold_ms" field
        _ = lua.getField(3, "hold_ms");
        if (lua.typeOf(-1) == .number) {
            const val = lua.toNumber(-1) catch 0;
            hold_ms = @intFromFloat(val);
        }
        lua.pop(1);

        // Parse "when" field
        _ = lua.getField(3, "when");
        if (lua.typeOf(-1) != .nil) {
            when = parseWhen(lua, -1, mux.allocator);
        }
        lua.pop(1);
    }

    // Validate action is present unless mode is passthrough_only
    if (!action_found and mode != .passthrough_only) {
        _ = lua.pushString("keymap.set: action required unless mode is passthrough_only");
        lua.raiseError();
    }

    // Create bind
    const bind = config.Config.Bind{
        .on = on,
        .mods = parsed_key.mods,
        .key = parsed_key.key,
        .action = action,
        .when = when,
        .mode = mode,
        .hold_ms = hold_ms,
    };

    // Append to binds list
    mux.binds.append(mux.allocator, bind) catch {
        _ = lua.pushString("keymap.set: failed to append bind");
        lua.raiseError();
    };

    return 0;
}

fn parseFloatStyleTable(lua: *Lua, idx: i32, allocator: std.mem.Allocator) ?config.FloatStyle {
    if (lua.typeOf(idx) != .table) return null;

    var style = config.FloatStyle{};

    _ = lua.getField(idx, "border");
    if (lua.typeOf(-1) == .table) {
        _ = lua.getField(-1, "chars");
        if (lua.typeOf(-1) == .table) {
            const parseChar = struct {
                fn parse(l: *Lua, default: u21) u21 {
                    const s = l.toString(-1) catch return default;
                    if (s.len == 0) return default;
                    const codepoint = std.unicode.utf8Decode(s[0..@min(s.len, 4)]) catch return default;
                    return codepoint;
                }
            }.parse;

            _ = lua.getField(-1, "top_left");
            if (lua.typeOf(-1) == .string) style.top_left = parseChar(lua, style.top_left);
            lua.pop(1);

            _ = lua.getField(-1, "top_right");
            if (lua.typeOf(-1) == .string) style.top_right = parseChar(lua, style.top_right);
            lua.pop(1);

            _ = lua.getField(-1, "bottom_left");
            if (lua.typeOf(-1) == .string) style.bottom_left = parseChar(lua, style.bottom_left);
            lua.pop(1);

            _ = lua.getField(-1, "bottom_right");
            if (lua.typeOf(-1) == .string) style.bottom_right = parseChar(lua, style.bottom_right);
            lua.pop(1);

            _ = lua.getField(-1, "horizontal");
            if (lua.typeOf(-1) == .string) style.horizontal = parseChar(lua, style.horizontal);
            lua.pop(1);

            _ = lua.getField(-1, "vertical");
            if (lua.typeOf(-1) == .string) style.vertical = parseChar(lua, style.vertical);
            lua.pop(1);

            _ = lua.getField(-1, "left_t");
            if (lua.typeOf(-1) == .string) style.left_t = parseChar(lua, style.left_t);
            lua.pop(1);

            _ = lua.getField(-1, "right_t");
            if (lua.typeOf(-1) == .string) style.right_t = parseChar(lua, style.right_t);
            lua.pop(1);

            _ = lua.getField(-1, "top_t");
            if (lua.typeOf(-1) == .string) style.top_t = parseChar(lua, style.top_t);
            lua.pop(1);

            _ = lua.getField(-1, "bottom_t");
            if (lua.typeOf(-1) == .string) style.bottom_t = parseChar(lua, style.bottom_t);
            lua.pop(1);

            _ = lua.getField(-1, "cross");
            if (lua.typeOf(-1) == .string) style.cross = parseChar(lua, style.cross);
            lua.pop(1);
        }
        lua.pop(1);
    }
    lua.pop(1);

    _ = lua.getField(idx, "shadow");
    if (lua.typeOf(-1) == .table) {
        _ = lua.getField(-1, "color");
        if (lua.typeOf(-1) == .number) {
            const color_num = lua.toNumber(-1) catch 0;
            if (std.math.isFinite(color_num)) {
                style.shadow_color = @intFromFloat(std.math.clamp(color_num, 0, 255));
            }
        }
        lua.pop(1);
    }
    lua.pop(1);

    _ = lua.getField(idx, "title");
    if (lua.typeOf(-1) == .table) {
        _ = lua.getField(-1, "position");
        if (lua.typeOf(-1) == .string) {
            const pos_str = lua.toString(-1) catch "";
            style.position = std.meta.stringToEnum(config.FloatStylePosition, pos_str);
        }
        lua.pop(1);

        _ = lua.getField(-1, "segments");
        if (lua.typeOf(-1) == .table) {
            const seg_len: usize = @intCast(lua.rawLen(-1));
            if (seg_len > 0) {
                const segs = allocator.alloc(config.Segment, seg_len) catch null;
                if (segs) |arr| {
                    var count: usize = 0;
                    var i: i32 = 1;
                    while (i <= @as(i32, @intCast(seg_len))) : (i += 1) {
                        _ = lua.rawGetIndex(-1, i);
                        if (lua.typeOf(-1) == .table) {
                            if (parseSegment(lua, -1, allocator)) |segment| {
                                arr[count] = segment;
                                count += 1;
                            }
                        }
                        lua.pop(1);
                    }
                    style.title_segments = arr[0..count];
                }
            }
        }
        lua.pop(1);

        if (style.title_segments.len == 0) {
            if (parseSegment(lua, -1, allocator)) |segment| {
                style.module = segment;
            }
        }
    }
    lua.pop(1);

    _ = lua.getField(idx, "position");
    if (lua.typeOf(-1) == .string) {
        const pos_str = lua.toString(-1) catch "";
        style.position = std.meta.stringToEnum(config.FloatStylePosition, pos_str);
    }
    lua.pop(1);

    return style;
}

fn applyFloatVisualOptions(comptime allow_attributes: bool, lua: *Lua, idx: i32, allocator: std.mem.Allocator, target: anytype) void {
    _ = lua.getField(idx, "size");
    if (lua.typeOf(-1) == .table) {
        _ = lua.getField(-1, "width");
        if (lua.typeOf(-1) == .number) {
            const w = lua.toNumber(-1) catch 0;
            target.width_percent = @intFromFloat(w);
        }
        lua.pop(1);

        _ = lua.getField(-1, "height");
        if (lua.typeOf(-1) == .number) {
            const h = lua.toNumber(-1) catch 0;
            target.height_percent = @intFromFloat(h);
        }
        lua.pop(1);
    }
    lua.pop(1);

    _ = lua.getField(idx, "padding");
    if (lua.typeOf(-1) == .table) {
        _ = lua.getField(-1, "x");
        if (lua.typeOf(-1) == .number) {
            const x = lua.toNumber(-1) catch 0;
            target.padding_x = @intFromFloat(x);
        }
        lua.pop(1);

        _ = lua.getField(-1, "y");
        if (lua.typeOf(-1) == .number) {
            const y = lua.toNumber(-1) catch 0;
            target.padding_y = @intFromFloat(y);
        }
        lua.pop(1);
    }
    lua.pop(1);

    _ = lua.getField(idx, "color");
    if (lua.typeOf(-1) == .table) {
        var color = config.BorderColor{};
        _ = lua.getField(-1, "active");
        if (lua.typeOf(-1) == .number) {
            const a = lua.toNumber(-1) catch 0;
            color.active = @intFromFloat(a);
        }
        lua.pop(1);

        _ = lua.getField(-1, "passive");
        if (lua.typeOf(-1) == .number) {
            const p = lua.toNumber(-1) catch 0;
            color.passive = @intFromFloat(p);
        }
        lua.pop(1);

        target.color = color;
    }
    lua.pop(1);

    if (allow_attributes) {
        _ = lua.getField(idx, "attributes");
        if (lua.typeOf(-1) == .table) {
            if (target.attributes == null) {
                target.attributes = config.FloatAttributes{};
            }

            _ = lua.getField(-1, "exclusive");
            if (lua.typeOf(-1) == .boolean) target.attributes.?.exclusive = lua.toBoolean(-1);
            lua.pop(1);

            _ = lua.getField(-1, "sticky");
            if (lua.typeOf(-1) == .boolean) target.attributes.?.sticky = lua.toBoolean(-1);
            lua.pop(1);

            _ = lua.getField(-1, "global");
            if (lua.typeOf(-1) == .boolean) target.attributes.?.global = lua.toBoolean(-1);
            lua.pop(1);

            _ = lua.getField(-1, "destroy");
            if (lua.typeOf(-1) == .boolean) target.attributes.?.destroy = lua.toBoolean(-1);
            lua.pop(1);

            _ = lua.getField(-1, "per_cwd");
            if (lua.typeOf(-1) == .boolean) target.attributes.?.per_cwd = lua.toBoolean(-1);
            lua.pop(1);

            _ = lua.getField(-1, "navigatable");
            if (lua.typeOf(-1) == .boolean) target.attributes.?.navigatable = lua.toBoolean(-1);
            lua.pop(1);

            _ = lua.getField(-1, "isolated");
            if (lua.typeOf(-1) == .boolean) target.attributes.?.isolated = lua.toBoolean(-1);
            lua.pop(1);

            _ = lua.getField(-1, "inherit_env");
            if (lua.typeOf(-1) == .boolean) target.attributes.?.inherit_env = lua.toBoolean(-1);
            lua.pop(1);
        }
        lua.pop(1);
    }

    _ = lua.getField(idx, "style");
    if (lua.typeOf(-1) == .table) {
        if (target.style) |*existing| {
            var copy = @constCast(existing);
            copy.deinit(allocator);
        }
        target.style = parseFloatStyleTable(lua, -1, allocator);
    }
    lua.pop(1);
}

/// Lua C function: hexe.mux.float.set_defaults(opts)
pub export fn hexe_mux_float_set_defaults(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Arg 1 must be a table
    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("float.set_defaults: argument must be a table");
        lua.raiseError();
    }

    // Get MuxConfigBuilder
    const mux = getMuxBuilder(lua) catch {
        _ = lua.pushString("float.set_defaults: failed to get config builder");
        lua.raiseError();
    };

    // Initialize float_defaults if not already
    if (mux.float_defaults == null) {
        mux.float_defaults = .{};
    }
    applyFloatVisualOptions(true, lua, 1, mux.allocator, &mux.float_defaults.?);

    return 0;
}

/// Lua C function: hexe.mux.float.set_adhoc(opts)
pub export fn hexe_mux_float_set_adhoc(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("float.set_adhoc: argument must be a table");
        lua.raiseError();
    }

    const mux = getMuxBuilder(lua) catch {
        _ = lua.pushString("float.set_adhoc: failed to get config builder");
        lua.raiseError();
    };

    if (mux.float_adhoc == null) {
        mux.float_adhoc = .{};
    }
    applyFloatVisualOptions(false, lua, 1, mux.allocator, &mux.float_adhoc.?);

    return 0;
}

/// Lua C function: hexe.mux.float.set_match(pattern, opts)
pub export fn hexe_mux_float_set_match(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    const pattern = lua.toString(1) catch {
        _ = lua.pushString("float.set_match: first argument must be a regex string");
        lua.raiseError();
    };
    if (pattern.len == 0) {
        _ = lua.pushString("float.set_match: regex string must not be empty");
        lua.raiseError();
    }
    if (lua.typeOf(2) != .table) {
        _ = lua.pushString("float.set_match: second argument must be a table");
        lua.raiseError();
    }

    const mux = getMuxBuilder(lua) catch {
        _ = lua.pushString("float.set_match: failed to get config builder");
        lua.raiseError();
    };

    var rule = config_builder.MuxConfigBuilder.FloatMatchRule{
        .pattern = mux.allocator.dupe(u8, pattern) catch {
            _ = lua.pushString("float.set_match: failed to allocate regex pattern");
            lua.raiseError();
        },
        .visual = .{},
    };
    errdefer rule.deinit(mux.allocator);
    applyFloatVisualOptions(false, lua, 2, mux.allocator, &rule.visual);
    mux.float_matches.append(mux.allocator, rule) catch {
        _ = lua.pushString("float.set_match: failed to store float match rule");
        lua.raiseError();
    };

    return 0;
}

/// Lua C function: hexe.mux.float.define(key, opts)
pub export fn hexe_mux_float_define(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Get key (arg 1)
    const key_str = lua.toString(1) catch {
        _ = lua.pushString("float.define: key must be a string");
        lua.raiseError();
    };
    if (key_str.len != 1) {
        _ = lua.pushString("float.define: key must be a single character");
        lua.raiseError();
    }
    const key = key_str[0];

    // Arg 2 must be a table
    if (lua.typeOf(2) != .table) {
        _ = lua.pushString("float.define: second argument must be a table");
        lua.raiseError();
    }

    // Get MuxConfigBuilder
    const mux = getMuxBuilder(lua) catch {
        _ = lua.pushString("float.define: failed to get config builder");
        lua.raiseError();
    };

    // Create FloatDef
    var float_def = config.FloatDef{
        .key = key,
        .command = null,
        .title = null,
    };

    // Parse command
    _ = lua.getField(2, "command");
    if (lua.typeOf(-1) == .string) {
        const cmd = lua.toString(-1) catch null;
        if (cmd) |cmd_val| {
            float_def.command = mux.allocator.dupe(u8, cmd_val) catch null;
        }
    }
    lua.pop(1);

    // Parse title
    _ = lua.getField(2, "title");
    if (lua.typeOf(-1) == .string) {
        const t = lua.toString(-1) catch null;
        if (t) |title_str| {
            float_def.title = mux.allocator.dupe(u8, title_str) catch null;
        }
    }
    lua.pop(1);

    // TODO: Parse size, position, padding, attributes, color, style

    // Append to floats list
    mux.floats.append(mux.allocator, float_def) catch {
        _ = lua.pushString("float.define: failed to append float");
        lua.raiseError();
    };

    return 0;
}

/// Lua C function: hexe.mux.tabs.add_segment(position, segment)
pub export fn hexe_mux_tabs_add_segment(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Get position (arg 1)
    const position = lua.toString(1) catch {
        _ = lua.pushString("tabs.add_segment: position must be a string");
        lua.raiseError();
    };

    // Arg 2 must be a table
    if (lua.typeOf(2) != .table) {
        _ = lua.pushString("tabs.add_segment: second argument must be a table");
        lua.raiseError();
    }

    // Get MuxConfigBuilder
    const mux = getMuxBuilder(lua) catch {
        _ = lua.pushString("tabs.add_segment: failed to get config builder");
        lua.raiseError();
    };

    // Parse full segment
    const path = std.fmt.allocPrint(mux.allocator, "mux.tabs.{s}[+1]", .{position}) catch "mux.tabs.segment";
    defer if (!std.mem.eql(u8, path, "mux.tabs.segment")) mux.allocator.free(path);

    const segment = parseSegmentAtPath(lua, 2, mux.allocator, path) orelse {
        _ = lua.pushString("tabs.add_segment: failed to parse segment");
        lua.raiseError();
    };

    // Append to appropriate list
    if (std.mem.eql(u8, position, "left")) {
        mux.tabs_config.segments_left.append(mux.allocator, segment) catch {
            _ = lua.pushString("tabs.add_segment: failed to append segment");
            lua.raiseError();
        };
    } else if (std.mem.eql(u8, position, "center")) {
        mux.tabs_config.segments_center.append(mux.allocator, segment) catch {
            _ = lua.pushString("tabs.add_segment: failed to append segment");
            lua.raiseError();
        };
    } else if (std.mem.eql(u8, position, "right")) {
        mux.tabs_config.segments_right.append(mux.allocator, segment) catch {
            _ = lua.pushString("tabs.add_segment: failed to append segment");
            lua.raiseError();
        };
    } else {
        _ = lua.pushString("tabs.add_segment: position must be 'left', 'center', or 'right'");
        lua.raiseError();
    }

    return 0;
}

/// Lua C function: hexe.mux.tabs.set_status(enabled)
pub export fn hexe_mux_tabs_set_status(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Get enabled (arg 1)
    if (lua.typeOf(1) != .boolean) {
        _ = lua.pushString("tabs.set_status: argument must be a boolean");
        lua.raiseError();
    }
    const enabled = lua.toBoolean(1);

    // Get MuxConfigBuilder
    const mux = getMuxBuilder(lua) catch {
        _ = lua.pushString("tabs.set_status: failed to get config builder");
        lua.raiseError();
    };

    mux.tabs_config.status_enabled = enabled;

    return 0;
}

/// Lua C function: hexe.mux.splits.setup(opts)
pub export fn hexe_mux_splits_setup(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Arg 1 must be a table
    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("splits.setup: argument must be a table");
        lua.raiseError();
    }

    // Get MuxConfigBuilder
    const mux = getMuxBuilder(lua) catch {
        _ = lua.pushString("splits.setup: failed to get config builder");
        lua.raiseError();
    };

    // Parse color table
    _ = lua.getField(1, "color");
    if (lua.typeOf(-1) == .table) {
        var color = config.BorderColor{};
        _ = lua.getField(-1, "active");
        if (lua.typeOf(-1) == .number) {
            const a = lua.toNumber(-1) catch 0;
            color.active = @intFromFloat(a);
        }
        lua.pop(1);

        _ = lua.getField(-1, "passive");
        if (lua.typeOf(-1) == .number) {
            const p = lua.toNumber(-1) catch 0;
            color.passive = @intFromFloat(p);
        }
        lua.pop(1);

        mux.splits_config.color = color;
    }
    lua.pop(1);

    // Parse separator_v
    _ = lua.getField(1, "separator_v");
    if (lua.typeOf(-1) == .string) {
        const sep_str = lua.toString(-1) catch "";
        if (sep_str.len > 0) {
            const codepoint = std.unicode.utf8Decode(sep_str[0..@min(sep_str.len, 4)]) catch mux.splits_config.separator_v;
            mux.splits_config.separator_v = codepoint;
        }
    }
    lua.pop(1);

    // Parse separator_h
    _ = lua.getField(1, "separator_h");
    if (lua.typeOf(-1) == .string) {
        const sep_str = lua.toString(-1) catch "";
        if (sep_str.len > 0) {
            const codepoint = std.unicode.utf8Decode(sep_str[0..@min(sep_str.len, 4)]) catch mux.splits_config.separator_h;
            mux.splits_config.separator_h = codepoint;
        }
    }
    lua.pop(1);

    // TODO: Parse style (SplitStyle with junction characters)

    return 0;
}

// ===== SES API Functions =====

/// Parse a Segment from a Lua table at idx with path-aware errors.
fn parseSegmentAtPath(lua: *Lua, idx: i32, allocator: std.mem.Allocator, base_path: []const u8) ?config.Segment {
    if (lua.typeOf(idx) != .table) return null;

    // Get name (required)
    _ = lua.getField(idx, "name");
    const name_str = lua.toString(-1) catch {
        lua.pop(1);
        return null;
    };
    const name = allocator.dupe(u8, name_str) catch {
        lua.pop(1);
        return null;
    };
    lua.pop(1);

    var segment = config.Segment{
        .name = name,
    };

    // Parse priority
    _ = lua.getField(idx, "priority");
    if (lua.typeOf(-1) == .number) {
        const p = lua.toNumber(-1) catch 50;
        if (std.math.isFinite(p)) {
            segment.priority = @intFromFloat(std.math.clamp(p, 0, 255));
        }
    }
    lua.pop(1);

    // outputs is removed from segment schema.
    _ = lua.getField(idx, "outputs");
    if (lua.typeOf(-1) != .nil) {
        const msg = std.fmt.allocPrint(allocator, "{s}.outputs is removed; style must be returned from '{s}.value'", .{ base_path, base_path }) catch "segment outputs field is removed";
        defer if (!std.mem.eql(u8, msg, "segment outputs field is removed")) allocator.free(msg);
        _ = lua.pushString(msg);
        lua.raiseError();
    }
    lua.pop(1);

    // Parse value callback (required for value/progress/button segments).
    var value_command: ?[]const u8 = null;
    _ = lua.getField(idx, "value");
    if (callbackFieldPathAlloc(allocator, base_path, "value")) |field_path| {
        defer allocator.free(field_path);
        if (parsePromptCallbackField(lua, allocator, field_path)) |code| {
            defer allocator.free(code);
            value_command = allocator.dupe(u8, code) catch null;
        }
    }
    lua.pop(1);

    // Parse builtin callback.
    var builtin_command: ?[]const u8 = null;
    _ = lua.getField(idx, "builtin");
    if (callbackFieldPathAlloc(allocator, base_path, "builtin")) |field_path| {
        defer allocator.free(field_path);
        if (parsePromptCallbackField(lua, allocator, field_path)) |code| {
            defer allocator.free(code);
            builtin_command = allocator.dupe(u8, code) catch null;
        }
    }
    lua.pop(1);

    _ = lua.getField(idx, "source");
    if (lua.typeOf(-1) != .nil) {
        const msg = std.fmt.allocPrint(allocator, "{s}.source is removed; use '{s}.value' and '{s}.builtin' callbacks", .{ base_path, base_path, base_path }) catch "segment source field is removed";
        defer if (!std.mem.eql(u8, msg, "segment source field is removed")) allocator.free(msg);
        _ = lua.pushString(msg);
        lua.raiseError();
    }
    lua.pop(1);

    // Parse progress controls
    _ = lua.getField(idx, "every_ms");
    if (lua.typeOf(-1) == .number) {
        const v = lua.toNumber(-1) catch 1000;
        if (std.math.isFinite(v)) segment.progress_every_ms = @intFromFloat(std.math.clamp(v, 1, 60000));
    }
    lua.pop(1);

    _ = lua.getField(idx, "show_when");
    if (callbackFieldPathAlloc(allocator, base_path, "show_when")) |field_path| {
        defer allocator.free(field_path);
        if (parsePromptCallbackField(lua, allocator, field_path)) |code| {
            defer allocator.free(code);
            segment.progress_show_when = allocator.dupe(u8, code) catch null;
        }
    }
    lua.pop(1);

    _ = lua.getField(idx, "progress");
    if (lua.typeOf(-1) == .table) {
        _ = lua.getField(-1, "every_ms");
        if (lua.typeOf(-1) == .number) {
            const v = lua.toNumber(-1) catch 1000;
            if (std.math.isFinite(v)) segment.progress_every_ms = @intFromFloat(std.math.clamp(v, 1, 60000));
        }
        lua.pop(1);

        _ = lua.getField(-1, "show_when");
        if (callbackFieldPathAlloc(allocator, base_path, "progress.show_when")) |field_path| {
            defer allocator.free(field_path);
            if (parsePromptCallbackField(lua, allocator, field_path)) |code| {
                defer allocator.free(code);
                if (segment.progress_show_when) |old| allocator.free(old);
                segment.progress_show_when = allocator.dupe(u8, code) catch segment.progress_show_when;
            }
        }
        lua.pop(1);

        _ = lua.getField(-1, "builtin");
        if (builtin_command == null) {
            if (callbackFieldPathAlloc(allocator, base_path, "progress.builtin")) |field_path| {
                defer allocator.free(field_path);
                if (parsePromptCallbackField(lua, allocator, field_path)) |code| {
                    defer allocator.free(code);
                    builtin_command = allocator.dupe(u8, code) catch null;
                }
            }
        }
        lua.pop(1);

        _ = lua.getField(-1, "value");
        if (value_command == null) {
            if (callbackFieldPathAlloc(allocator, base_path, "progress.value")) |field_path| {
                defer allocator.free(field_path);
                if (parsePromptCallbackField(lua, allocator, field_path)) |code| {
                    defer allocator.free(code);
                    value_command = allocator.dupe(u8, code) catch null;
                }
            }
        }
        lua.pop(1);
    }
    lua.pop(1);

    var progress_every_ms: u64 = 1000;
    var progress_show_when: ?[]const u8 = null;
    _ = lua.getField(idx, "every_ms");
    if (lua.typeOf(-1) == .number) {
        const v = lua.toNumber(-1) catch 1000;
        if (std.math.isFinite(v)) progress_every_ms = @intFromFloat(std.math.clamp(v, 1, 60000));
    }
    lua.pop(1);
    _ = lua.getField(idx, "show_when");
    if (parsePromptCallbackField(lua, allocator, "segment.show_when")) |code| {
        defer allocator.free(code);
        progress_show_when = allocator.dupe(u8, code) catch null;
    }
    lua.pop(1);

    _ = lua.getField(idx, "every_ms");
    if (lua.typeOf(-1) == .number) {
        const v = lua.toNumber(-1) catch 1000;
        if (std.math.isFinite(v)) progress_every_ms = @intFromFloat(std.math.clamp(v, 1, 60000));
    }
    lua.pop(1);

    _ = lua.getField(idx, "show_when");
    if (parsePromptCallbackField(lua, allocator, "segment.show_when")) |code| {
        defer allocator.free(code);
        progress_show_when = allocator.dupe(u8, code) catch null;
    }
    lua.pop(1);

    const has_button = blk: {
        _ = lua.getField(idx, "button");
        const is_tbl = lua.typeOf(-1) == .table;
        lua.pop(1);
        _ = lua.getField(idx, "on_click");
        const has_left = lua.typeOf(-1) == .string or lua.typeOf(-1) == .function;
        lua.pop(1);
        _ = lua.getField(idx, "on_left_click");
        const has_left_alias = lua.typeOf(-1) == .string or lua.typeOf(-1) == .function;
        lua.pop(1);
        _ = lua.getField(idx, "on_right_click");
        const has_right = lua.typeOf(-1) == .string or lua.typeOf(-1) == .function;
        lua.pop(1);
        _ = lua.getField(idx, "on_middle_click");
        const has_mid = lua.typeOf(-1) == .string or lua.typeOf(-1) == .function;
        lua.pop(1);
        break :blk is_tbl or has_left or has_left_alias or has_right or has_mid;
    };
    const has_progress = blk: {
        _ = lua.getField(idx, "progress");
        const is_tbl = lua.typeOf(-1) == .table;
        lua.pop(1);
        break :blk is_tbl or segment.progress_show_when != null;
    };

    segment.kind = if (has_progress)
        .progress
    else if (has_button)
        .button
    else if ((segment.builtin != null or builtin_command != null) and value_command == null)
        .builtin
    else
        .value;

    // Parse optional click actions.
    _ = lua.getField(idx, "on_click");
    if (callbackFieldPathAlloc(allocator, base_path, "on_click")) |field_path| {
        defer allocator.free(field_path);
        if (parseCommandOrCallbackField(lua, allocator, field_path)) |code| {
            segment.on_click = code;
        }
    }
    lua.pop(1);
    _ = lua.getField(idx, "on_left_click");
    if (segment.on_click == null) {
        if (callbackFieldPathAlloc(allocator, base_path, "on_left_click")) |field_path| {
            defer allocator.free(field_path);
            if (parseCommandOrCallbackField(lua, allocator, field_path)) |code| {
                segment.on_click = code;
            }
        }
    }
    lua.pop(1);

    _ = lua.getField(idx, "on_right_click");
    if (callbackFieldPathAlloc(allocator, base_path, "on_right_click")) |field_path| {
        defer allocator.free(field_path);
        if (parseCommandOrCallbackField(lua, allocator, field_path)) |code| {
            segment.on_right_click = code;
        }
    }
    lua.pop(1);

    _ = lua.getField(idx, "on_middle_click");
    if (callbackFieldPathAlloc(allocator, base_path, "on_middle_click")) |field_path| {
        defer allocator.free(field_path);
        if (parseCommandOrCallbackField(lua, allocator, field_path)) |code| {
            segment.on_middle_click = code;
        }
    }
    lua.pop(1);

    _ = lua.getField(idx, "button_active_bash");
    if (callbackFieldPathAlloc(allocator, base_path, "button_active_bash")) |field_path| {
        defer allocator.free(field_path);
        if (parseCommandOrCallbackField(lua, allocator, field_path)) |code| {
            segment.button_active_bash = code;
        }
    }
    lua.pop(1);

    _ = lua.getField(idx, "active_when");
    if (segment.button_active_bash == null) {
        if (callbackFieldPathAlloc(allocator, base_path, "active_when")) |field_path| {
            defer allocator.free(field_path);
            if (parseCommandOrCallbackField(lua, allocator, field_path)) |code| {
                segment.button_active_bash = code;
            }
        }
    }
    lua.pop(1);

    _ = lua.getField(idx, "button_left_style");
    if (lua.typeOf(-1) == .string) {
        const s = lua.toString(-1) catch "";
        if (s.len > 0) segment.button_left_style = allocator.dupe(u8, s) catch null;
    }
    lua.pop(1);
    rejectRemovedField(lua, allocator, idx, base_path, "left_click_style", "button_left_style or button.left_style");
    rejectRemovedField(lua, allocator, idx, base_path, "on_left_click_style", "button_left_style or button.left_style");

    _ = lua.getField(idx, "button_middle_style");
    if (lua.typeOf(-1) == .string) {
        const s = lua.toString(-1) catch "";
        if (s.len > 0) segment.button_middle_style = allocator.dupe(u8, s) catch null;
    }
    lua.pop(1);
    rejectRemovedField(lua, allocator, idx, base_path, "middle_click_style", "button_middle_style or button.middle_style");
    rejectRemovedField(lua, allocator, idx, base_path, "on_middle_click_style", "button_middle_style or button.middle_style");

    _ = lua.getField(idx, "button_right_style");
    if (lua.typeOf(-1) == .string) {
        const s = lua.toString(-1) catch "";
        if (s.len > 0) segment.button_right_style = allocator.dupe(u8, s) catch null;
    }
    lua.pop(1);
    rejectRemovedField(lua, allocator, idx, base_path, "right_click_style", "button_right_style or button.right_style");
    rejectRemovedField(lua, allocator, idx, base_path, "on_right_click_style", "button_right_style or button.right_style");

    _ = lua.getField(idx, "inverse_on_hover");
    if (lua.typeOf(-1) == .boolean) {
        segment.inverse_on_hover = lua.toBoolean(-1);
    }
    lua.pop(1);

    // Parse optional button section as sugar:
    // button = { on_click = "...", on_right_click = "...", on_middle_click = "..." }
    _ = lua.getField(idx, "button");
    if (lua.typeOf(-1) == .table) {
        _ = lua.getField(-1, "builtin");
        if (builtin_command == null) {
            if (callbackFieldPathAlloc(allocator, base_path, "button.builtin")) |field_path| {
                defer allocator.free(field_path);
                if (parsePromptCallbackField(lua, allocator, field_path)) |code| {
                    defer allocator.free(code);
                    builtin_command = allocator.dupe(u8, code) catch null;
                }
            }
        }
        lua.pop(1);

        _ = lua.getField(-1, "value");
        if (value_command == null) {
            if (callbackFieldPathAlloc(allocator, base_path, "button.value")) |field_path| {
                defer allocator.free(field_path);
                if (parsePromptCallbackField(lua, allocator, field_path)) |code| {
                    defer allocator.free(code);
                    value_command = allocator.dupe(u8, code) catch null;
                }
            }
        }
        lua.pop(1);

        _ = lua.getField(-1, "on_click");
        if (segment.on_click == null) {
            if (callbackFieldPathAlloc(allocator, base_path, "button.on_click")) |field_path| {
                defer allocator.free(field_path);
                if (parseCommandOrCallbackField(lua, allocator, field_path)) |code| {
                    segment.on_click = code;
                }
            }
        }
        lua.pop(1);
        _ = lua.getField(-1, "on_left_click");
        if (segment.on_click == null) {
            if (callbackFieldPathAlloc(allocator, base_path, "button.on_left_click")) |field_path| {
                defer allocator.free(field_path);
                if (parseCommandOrCallbackField(lua, allocator, field_path)) |code| {
                    segment.on_click = code;
                }
            }
        }
        lua.pop(1);

        _ = lua.getField(-1, "on_right_click");
        if (segment.on_right_click == null) {
            if (callbackFieldPathAlloc(allocator, base_path, "button.on_right_click")) |field_path| {
                defer allocator.free(field_path);
                if (parseCommandOrCallbackField(lua, allocator, field_path)) |code| {
                    segment.on_right_click = code;
                }
            }
        }
        lua.pop(1);
        _ = lua.getField(-1, "right_click");
        if (lua.typeOf(-1) != .nil) {
            const msg = std.fmt.allocPrint(allocator, "{s}.button.right_click is removed; use {s}.button.on_right_click", .{ base_path, base_path }) catch "button.right_click is removed";
            defer if (!std.mem.eql(u8, msg, "button.right_click is removed")) allocator.free(msg);
            _ = lua.pushString(msg);
            lua.raiseError();
        }
        lua.pop(1);

        _ = lua.getField(-1, "on_middle_click");
        if (segment.on_middle_click == null) {
            if (callbackFieldPathAlloc(allocator, base_path, "button.on_middle_click")) |field_path| {
                defer allocator.free(field_path);
                if (parseCommandOrCallbackField(lua, allocator, field_path)) |code| {
                    segment.on_middle_click = code;
                }
            }
        }
        lua.pop(1);
        _ = lua.getField(-1, "middle_click");
        if (lua.typeOf(-1) != .nil) {
            const msg = std.fmt.allocPrint(allocator, "{s}.button.middle_click is removed; use {s}.button.on_middle_click", .{ base_path, base_path }) catch "button.middle_click is removed";
            defer if (!std.mem.eql(u8, msg, "button.middle_click is removed")) allocator.free(msg);
            _ = lua.pushString(msg);
            lua.raiseError();
        }
        lua.pop(1);

        _ = lua.getField(-1, "active_when");
        if (segment.button_active_bash == null) {
            if (callbackFieldPathAlloc(allocator, base_path, "button.active_when")) |field_path| {
                defer allocator.free(field_path);
                if (parseCommandOrCallbackField(lua, allocator, field_path)) |code| {
                    segment.button_active_bash = code;
                }
            }
        }
        lua.pop(1);

        _ = lua.getField(-1, "left_style");
        if (segment.button_left_style == null and lua.typeOf(-1) == .string) {
            const s = lua.toString(-1) catch "";
            if (s.len > 0) segment.button_left_style = allocator.dupe(u8, s) catch null;
        }
        lua.pop(1);
        _ = lua.getField(-1, "left_click_style");
        if (lua.typeOf(-1) != .nil) {
            const msg = std.fmt.allocPrint(allocator, "{s}.button.left_click_style is removed; use {s}.button.left_style", .{ base_path, base_path }) catch "button.left_click_style is removed";
            defer if (!std.mem.eql(u8, msg, "button.left_click_style is removed")) allocator.free(msg);
            _ = lua.pushString(msg);
            lua.raiseError();
        }
        lua.pop(1);
        _ = lua.getField(-1, "on_left_click_style");
        if (lua.typeOf(-1) != .nil) {
            const msg = std.fmt.allocPrint(allocator, "{s}.button.on_left_click_style is removed; use {s}.button.left_style", .{ base_path, base_path }) catch "button.on_left_click_style is removed";
            defer if (!std.mem.eql(u8, msg, "button.on_left_click_style is removed")) allocator.free(msg);
            _ = lua.pushString(msg);
            lua.raiseError();
        }
        lua.pop(1);

        _ = lua.getField(-1, "middle_style");
        if (segment.button_middle_style == null and lua.typeOf(-1) == .string) {
            const s = lua.toString(-1) catch "";
            if (s.len > 0) segment.button_middle_style = allocator.dupe(u8, s) catch null;
        }
        lua.pop(1);
        _ = lua.getField(-1, "middle_click_style");
        if (lua.typeOf(-1) != .nil) {
            const msg = std.fmt.allocPrint(allocator, "{s}.button.middle_click_style is removed; use {s}.button.middle_style", .{ base_path, base_path }) catch "button.middle_click_style is removed";
            defer if (!std.mem.eql(u8, msg, "button.middle_click_style is removed")) allocator.free(msg);
            _ = lua.pushString(msg);
            lua.raiseError();
        }
        lua.pop(1);
        _ = lua.getField(-1, "on_middle_click_style");
        if (lua.typeOf(-1) != .nil) {
            const msg = std.fmt.allocPrint(allocator, "{s}.button.on_middle_click_style is removed; use {s}.button.middle_style", .{ base_path, base_path }) catch "button.on_middle_click_style is removed";
            defer if (!std.mem.eql(u8, msg, "button.on_middle_click_style is removed")) allocator.free(msg);
            _ = lua.pushString(msg);
            lua.raiseError();
        }
        lua.pop(1);

        _ = lua.getField(-1, "right_style");
        if (segment.button_right_style == null and lua.typeOf(-1) == .string) {
            const s = lua.toString(-1) catch "";
            if (s.len > 0) segment.button_right_style = allocator.dupe(u8, s) catch null;
        }
        lua.pop(1);
        _ = lua.getField(-1, "right_click_style");
        if (lua.typeOf(-1) != .nil) {
            const msg = std.fmt.allocPrint(allocator, "{s}.button.right_click_style is removed; use {s}.button.right_style", .{ base_path, base_path }) catch "button.right_click_style is removed";
            defer if (!std.mem.eql(u8, msg, "button.right_click_style is removed")) allocator.free(msg);
            _ = lua.pushString(msg);
            lua.raiseError();
        }
        lua.pop(1);
        _ = lua.getField(-1, "on_right_click_style");
        if (lua.typeOf(-1) != .nil) {
            const msg = std.fmt.allocPrint(allocator, "{s}.button.on_right_click_style is removed; use {s}.button.right_style", .{ base_path, base_path }) catch "button.on_right_click_style is removed";
            defer if (!std.mem.eql(u8, msg, "button.on_right_click_style is removed")) allocator.free(msg);
            _ = lua.pushString(msg);
            lua.raiseError();
        }
        lua.pop(1);

        _ = lua.getField(-1, "inverse_on_hover");
        if (lua.typeOf(-1) == .boolean) {
            segment.inverse_on_hover = lua.toBoolean(-1);
        }
        lua.pop(1);
    }
    lua.pop(1);

    // Segment-level `when` is intentionally unsupported.

    // Parse spinner
    _ = lua.getField(idx, "spinner");
    if (lua.typeOf(-1) == .table) {
        var spinner = config.SpinnerDef{};
        spinner.kind = allocator.dupe(u8, spinner.kind) catch {
            lua.pop(1);
            return segment;
        };

        // kind
        _ = lua.getField(-1, "kind");
        if (lua.typeOf(-1) == .string) {
            const kind = lua.toString(-1) catch "knight_rider";
            const kind_copy = allocator.dupe(u8, kind) catch spinner.kind;
            if (kind_copy.ptr != spinner.kind.ptr) {
                allocator.free(spinner.kind);
                spinner.kind = kind_copy;
            }
        }
        lua.pop(1);

        // width
        _ = lua.getField(-1, "width");
        if (lua.typeOf(-1) == .number) {
            const v = lua.toNumber(-1) catch @as(f64, @floatFromInt(spinner.width));
            if (std.math.isFinite(v)) spinner.width = @intFromFloat(std.math.clamp(v, 1, 64));
        }
        lua.pop(1);

        // step / step_ms
        _ = lua.getField(-1, "step");
        if (lua.typeOf(-1) == .number) {
            const v = lua.toNumber(-1) catch @as(f64, @floatFromInt(spinner.step_ms));
            if (std.math.isFinite(v)) spinner.step_ms = @intFromFloat(std.math.clamp(v, 1, 5000));
        }
        lua.pop(1);
        _ = lua.getField(-1, "step_ms");
        if (lua.typeOf(-1) == .number) {
            const v = lua.toNumber(-1) catch @as(f64, @floatFromInt(spinner.step_ms));
            if (std.math.isFinite(v)) spinner.step_ms = @intFromFloat(std.math.clamp(v, 1, 5000));
        }
        lua.pop(1);

        // hold / hold_frames
        _ = lua.getField(-1, "hold");
        if (lua.typeOf(-1) == .number) {
            const v = lua.toNumber(-1) catch @as(f64, @floatFromInt(spinner.hold_frames));
            if (std.math.isFinite(v)) spinner.hold_frames = @intFromFloat(std.math.clamp(v, 0, 120));
        }
        lua.pop(1);
        _ = lua.getField(-1, "hold_frames");
        if (lua.typeOf(-1) == .number) {
            const v = lua.toNumber(-1) catch @as(f64, @floatFromInt(spinner.hold_frames));
            if (std.math.isFinite(v)) spinner.hold_frames = @intFromFloat(std.math.clamp(v, 0, 120));
        }
        lua.pop(1);

        // bg / bg_color
        _ = lua.getField(-1, "bg");
        if (lua.typeOf(-1) == .number) {
            const v = lua.toNumber(-1) catch 0;
            if (std.math.isFinite(v)) spinner.bg_color = @intFromFloat(std.math.clamp(v, 0, 255));
        }
        lua.pop(1);
        _ = lua.getField(-1, "bg_color");
        if (lua.typeOf(-1) == .number) {
            const v = lua.toNumber(-1) catch 0;
            if (std.math.isFinite(v)) spinner.bg_color = @intFromFloat(std.math.clamp(v, 0, 255));
        }
        lua.pop(1);

        // placeholder / placeholder_color
        _ = lua.getField(-1, "placeholder");
        if (lua.typeOf(-1) == .number) {
            const v = lua.toNumber(-1) catch 0;
            if (std.math.isFinite(v)) spinner.placeholder_color = @intFromFloat(std.math.clamp(v, 0, 255));
        }
        lua.pop(1);
        _ = lua.getField(-1, "placeholder_color");
        if (lua.typeOf(-1) == .number) {
            const v = lua.toNumber(-1) catch 0;
            if (std.math.isFinite(v)) spinner.placeholder_color = @intFromFloat(std.math.clamp(v, 0, 255));
        }
        lua.pop(1);

        // colors = { ...palette indexes... }
        _ = lua.getField(-1, "colors");
        if (lua.typeOf(-1) == .table) {
            var colors = std.ArrayList(u8).empty;
            const len = lua.rawLen(-1);
            var i: i32 = 1;
            while (i <= len) : (i += 1) {
                _ = lua.rawGetIndex(-1, i);
                if (lua.typeOf(-1) == .number) {
                    const v = lua.toNumber(-1) catch 0;
                    if (std.math.isFinite(v)) {
                        colors.append(allocator, @intFromFloat(std.math.clamp(v, 0, 255))) catch {};
                    }
                }
                lua.pop(1);
            }
            if (colors.items.len > 0) {
                spinner.colors = colors.toOwnedSlice(allocator) catch spinner.colors;
            } else {
                colors.deinit(allocator);
            }
        }
        lua.pop(1);

        segment.spinner = spinner;
    }
    lua.pop(1);

    segment.command = switch (segment.kind) {
        .value => value_command,
        .builtin => builtin_command,
        .button, .progress => value_command,
    };

    if (segment.command == null and segment.builtin == null) {
        const msg = switch (segment.kind) {
            .value => "value segment requires a non-empty 'value'",
            .builtin => "builtin segment requires non-empty 'builtin'",
            .button => "button segment requires 'value' or 'builtin'",
            .progress => "progress segment requires 'value' or 'builtin'",
        };
        const owned_msg = std.fmt.allocPrint(allocator, "{s}: {s}", .{ base_path, msg }) catch null;
        defer if (owned_msg) |m| allocator.free(m);
        _ = lua.pushString(owned_msg orelse msg);
        lua.raiseError();
    }

    return segment;
}

/// Backward-compatible parse entry with generic base path.
fn parseSegment(lua: *Lua, idx: i32, allocator: std.mem.Allocator) ?config.Segment {
    return parseSegmentAtPath(lua, idx, allocator, "segment");
}

/// Parse a LayoutFloatDef from a Lua table at idx
fn parseLayoutFloat(lua: *Lua, idx: i32, allocator: std.mem.Allocator) ?config.LayoutFloatDef {
    if (lua.typeOf(idx) != .table) {
        return null;
    }

    rejectRemovedField(lua, allocator, idx, "ses.layout.float", "padding", "hexe.mux.float.set_defaults / set_adhoc / set_match");
    rejectRemovedField(lua, allocator, idx, "ses.layout.float", "color", "hexe.mux.float.set_defaults / set_adhoc / set_match");
    rejectRemovedField(lua, allocator, idx, "ses.layout.float", "style", "hexe.mux.float.set_defaults / set_adhoc / set_match");

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
        float_def.command = allocator.dupe(u8, cmd) catch null;
    }
    lua.pop(1);

    // Parse title
    _ = lua.getField(idx, "title");
    if (lua.typeOf(-1) == .string) {
        const title = lua.toString(-1) catch {
            lua.pop(1);
            return null;
        };
        float_def.title = allocator.dupe(u8, title) catch null;
    }
    lua.pop(1);

    // Parse attributes table
    _ = lua.getField(idx, "attributes");
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
            const w = lua.toNumber(-1) catch 0;
            if (std.math.isFinite(w)) {
                float_def.width_percent = @intFromFloat(std.math.clamp(w, 0, 100));
            }
        }
        lua.pop(1);

        _ = lua.getField(-1, "height");
        if (lua.typeOf(-1) == .number) {
            const h = lua.toNumber(-1) catch 0;
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
            const x = lua.toNumber(-1) catch 0;
            if (std.math.isFinite(x)) {
                float_def.pos_x = @intFromFloat(std.math.clamp(x, 0, 100));
            }
        }
        lua.pop(1);

        _ = lua.getField(-1, "y");
        if (lua.typeOf(-1) == .number) {
            const y = lua.toNumber(-1) catch 0;
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
            .profile = allocator.dupe(u8, "default") catch return null,
        };

        // Parse profile
        _ = lua.getField(-1, "profile");
        if (lua.typeOf(-1) == .string) {
            const profile_str = lua.toString(-1) catch "";
            if (profile_str.len > 0) {
                allocator.free(isolation.profile);
                isolation.profile = allocator.dupe(u8, profile_str) catch return null;
            }
        }
        lua.pop(1);

        // Parse memory
        _ = lua.getField(-1, "memory");
        if (lua.typeOf(-1) == .string) {
            const mem_str = lua.toString(-1) catch null;
            if (mem_str) |m| {
                isolation.memory = allocator.dupe(u8, m) catch null;
            }
        }
        lua.pop(1);

        // Parse cpu
        _ = lua.getField(-1, "cpu");
        if (lua.typeOf(-1) == .string) {
            const cpu_str = lua.toString(-1) catch null;
            if (cpu_str) |cpu_val| {
                isolation.cpu = allocator.dupe(u8, cpu_val) catch null;
            }
        }
        lua.pop(1);

        // Parse pids (can be string or number)
        _ = lua.getField(-1, "pids");
        if (lua.typeOf(-1) == .string) {
            const pids_str = lua.toString(-1) catch null;
            if (pids_str) |p| {
                isolation.pids = allocator.dupe(u8, p) catch null;
            }
        } else if (lua.typeOf(-1) == .number) {
            const pids_num = lua.toNumber(-1) catch 0;
            var buf: [32]u8 = undefined;
            const pids_str = std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(pids_num))}) catch "";
            if (pids_str.len > 0) {
                isolation.pids = allocator.dupe(u8, pids_str) catch null;
            }
        }
        lua.pop(1);

        float_def.isolation = isolation;
    }
    lua.pop(1); // pop isolation table

    return float_def;
}

/// Lua C function: hexe.ses.layout.define(opts)
pub export fn hexe_ses_layout_define(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Arg 1 must be a table
    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("layout.define: argument must be a table");
        lua.raiseError();
    }

    // Get name from table
    _ = lua.getField(1, "name");
    const name_str = lua.toString(-1) catch {
        lua.pop(1);
        _ = lua.pushString("layout.define: layout must have a 'name' field");
        lua.raiseError();
    };
    lua.pop(1);

    // Get SesConfigBuilder
    const ses = getSesBuilder(lua) catch {
        _ = lua.pushString("layout.define: failed to get config builder");
        lua.raiseError();
    };

    const name = ses.allocator.dupe(u8, name_str) catch {
        _ = lua.pushString("layout.define: failed to allocate name");
        lua.raiseError();
    };

    // Parse enabled
    _ = lua.getField(1, "enabled");
    const enabled = if (lua.typeOf(-1) == .boolean)
        lua.toBoolean(-1)
    else
        false;
    lua.pop(1);

    // Parse tabs array
    var tabs = std.ArrayList(config.LayoutTabDef){};
    _ = lua.getField(1, "tabs");
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
                const tab_name = ses.allocator.dupe(u8, tab_name_str) catch {
                    lua.pop(2);
                    continue;
                };
                lua.pop(1); // pop name

                // Parse root split
                _ = lua.getField(-1, "root");
                const root = if (lua.typeOf(-1) == .table)
                    parseLayoutSplit(lua, -1, ses.allocator)
                else
                    null;
                lua.pop(1); // pop root

                const tab = config.LayoutTabDef{
                    .name = tab_name,
                    .enabled = true,
                    .root = if (root) |r| r.* else null,
                };
                tabs.append(ses.allocator, tab) catch {};
            }
            lua.pop(1); // pop tab
        }
    }
    lua.pop(1); // pop tabs array

    // Parse floats array
    var floats = std.ArrayList(config.LayoutFloatDef).empty;
    _ = lua.getField(1, "floats");
    if (lua.typeOf(-1) == .table) {
        const floats_len = lua.rawLen(-1);
        var i: i32 = 1;
        while (i <= floats_len) : (i += 1) {
            _ = lua.rawGetIndex(-1, i);
            if (parseLayoutFloat(lua, -1, ses.allocator)) |float_def| {
                floats.append(ses.allocator, float_def) catch {};
            }
            lua.pop(1); // pop float table
        }
    }
    lua.pop(1); // pop floats array

    // Create layout
    const layout = config.LayoutDef{
        .name = name,
        .enabled = enabled,
        .tabs = tabs.toOwnedSlice(ses.allocator) catch &[_]config.LayoutTabDef{},
        .floats = floats.toOwnedSlice(ses.allocator) catch &[_]config.LayoutFloatDef{},
    };

    // Append to layouts
    ses.layouts.append(ses.allocator, layout) catch {
        _ = lua.pushString("layout.define: failed to append layout");
        lua.raiseError();
    };

    return 0;
}

/// Lua C function: hexe.ses.session.setup(opts)
/// hexe.ses.isolation.set({ profile = "balanced", memory = "1G", ... })
/// Configure POD isolation settings (libvoid)
pub export fn hexe_ses_isolation_set(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Get SesConfigBuilder
    const ses = getSesBuilder(lua) catch {
        _ = lua.pushString("isolation.set: failed to get config builder");
        lua.raiseError();
    };

    // Arg 1 must be a table
    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("isolation.set: argument must be a table");
        lua.raiseError();
    }

    // Parse profile
    _ = lua.getField(1, "profile");
    if (lua.typeOf(-1) == .string) {
        const profile_str = lua.toString(-1) catch "default";
        const profile = ses.allocator.dupe(u8, profile_str) catch {
            lua.pop(1);
            _ = lua.pushString("isolation.set: failed to allocate profile");
            lua.raiseError();
        };
        if (ses.isolation_profile) |old| ses.allocator.free(old);
        ses.isolation_profile = profile;

        // NOTE: Don't set env vars globally - only apply isolation per-float
        // Environment variables will be set only when spawning PODs with explicit isolation config
    }
    lua.pop(1);

    // Parse memory limit
    _ = lua.getField(1, "memory");
    if (lua.typeOf(-1) == .string) {
        const mem_str = lua.toString(-1) catch null;
        if (mem_str) |m| {
            const memory = ses.allocator.dupe(u8, m) catch {
                lua.pop(1);
                _ = lua.pushString("isolation.set: failed to allocate memory");
                lua.raiseError();
            };
            if (ses.isolation_memory) |old| ses.allocator.free(old);
            ses.isolation_memory = memory;
        }
    }
    lua.pop(1);

    // Parse CPU limit
    _ = lua.getField(1, "cpu");
    if (lua.typeOf(-1) == .string) {
        const cpu_str = lua.toString(-1) catch null;
        if (cpu_str) |cpu_val| {
            const cpu = ses.allocator.dupe(u8, cpu_val) catch {
                lua.pop(1);
                _ = lua.pushString("isolation.set: failed to allocate cpu");
                lua.raiseError();
            };
            if (ses.isolation_cpu) |old| ses.allocator.free(old);
            ses.isolation_cpu = cpu;
        }
    }
    lua.pop(1);

    // Parse PIDs limit
    _ = lua.getField(1, "pids");
    if (lua.typeOf(-1) == .string) {
        const pids_str = lua.toString(-1) catch null;
        if (pids_str) |p| {
            const pids = ses.allocator.dupe(u8, p) catch {
                lua.pop(1);
                _ = lua.pushString("isolation.set: failed to allocate pids");
                lua.raiseError();
            };
            if (ses.isolation_pids) |old| ses.allocator.free(old);
            ses.isolation_pids = pids;
        }
    } else if (lua.typeOf(-1) == .number) {
        const pids_num = lua.toNumber(-1) catch 0;
        var buf: [32]u8 = undefined;
        const pids_str = std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(pids_num))}) catch {
            lua.pop(1);
            _ = lua.pushString("isolation.set: failed to format pids");
            lua.raiseError();
        };
        const pids = ses.allocator.dupe(u8, pids_str) catch {
            lua.pop(1);
            _ = lua.pushString("isolation.set: failed to allocate pids");
            lua.raiseError();
        };
        if (ses.isolation_pids) |old| ses.allocator.free(old);
        ses.isolation_pids = pids;
    }
    lua.pop(1);

    return 0;
}

pub export fn hexe_ses_session_setup(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Arg 1 must be a table
    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("session.setup: argument must be a table");
        lua.raiseError();
    }

    // Get SesConfigBuilder
    const ses = getSesBuilder(lua) catch {
        _ = lua.pushString("session.setup: failed to get config builder");
        lua.raiseError();
    };

    // Parse auto_restore
    _ = lua.getField(1, "auto_restore");
    if (lua.typeOf(-1) == .boolean) {
        ses.auto_restore = lua.toBoolean(-1);
    }
    lua.pop(1);

    // Parse save_on_detach
    _ = lua.getField(1, "save_on_detach");
    if (lua.typeOf(-1) == .boolean) {
        ses.save_on_detach = lua.toBoolean(-1);
    }
    lua.pop(1);

    return 0;
}

// ============================================================================
// Section 3: SHP (Shell Prompt) C API
// ============================================================================

/// Helper: Parse output definition from a table
fn parseOutputDef(lua: *Lua, idx: i32, allocator: std.mem.Allocator) ?config_builder.ShpConfigBuilder.OutputDef {
    if (lua.typeOf(idx) != .table) return null;

    var style: ?[]const u8 = null;
    var format: ?[]const u8 = null;

    _ = lua.getField(idx, "style");
    if (lua.typeOf(-1) == .string) {
        const s = lua.toString(-1) catch return null;
        style = allocator.dupe(u8, s) catch return null;
    }
    lua.pop(1);

    _ = lua.getField(idx, "format");
    if (lua.typeOf(-1) == .string) {
        const f = lua.toString(-1) catch return null;
        format = allocator.dupe(u8, f) catch return null;
    }
    lua.pop(1);

    if (style == null or format == null) return null;

    return config_builder.ShpConfigBuilder.OutputDef{
        .style = style.?,
        .format = format.?,
    };
}

fn callbackFieldPathAlloc(allocator: std.mem.Allocator, base_path: []const u8, field_name: []const u8) ?[]u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ base_path, field_name }) catch null;
}

/// Helper: Parse segment definition from a table
fn parseSegmentDef(lua: *Lua, idx: i32, allocator: std.mem.Allocator, base_path: []const u8) ?config_builder.ShpConfigBuilder.SegmentDef {
    if (lua.typeOf(idx) != .table) return null;

    var name: ?[]const u8 = null;
    var priority: i64 = 50; // default priority
    var outputs = std.ArrayList(config_builder.ShpConfigBuilder.OutputDef){};
    var command: ?[]const u8 = null;
    var builtin_command: ?[]const u8 = null;
    var progress_every_ms: u64 = 1000;
    var progress_show_when: ?[]const u8 = null;

    // Parse name (required)
    _ = lua.getField(idx, "name");
    if (lua.typeOf(-1) == .string) {
        const n = lua.toString(-1) catch return null;
        name = allocator.dupe(u8, n) catch return null;
    }
    lua.pop(1);

    if (name == null) {
        const msg = std.fmt.allocPrint(allocator, "{s}.name is required", .{base_path}) catch "segment name is required";
        defer if (!std.mem.eql(u8, msg, "segment name is required")) allocator.free(msg);
        _ = lua.pushString(msg);
        lua.raiseError();
    }

    // Parse priority (optional)
    _ = lua.getField(idx, "priority");
    if (lua.typeOf(-1) == .number) {
        priority = lua.toInteger(-1) catch 50;
    }
    lua.pop(1);

    // outputs is removed from segment schema.
    _ = lua.getField(idx, "outputs");
    if (lua.typeOf(-1) != .nil) {
        const msg = std.fmt.allocPrint(allocator, "{s}.outputs is removed; style must be returned from '{s}.value'", .{ base_path, base_path }) catch "segment outputs field is removed";
        defer if (!std.mem.eql(u8, msg, "segment outputs field is removed")) allocator.free(msg);
        _ = lua.pushString(msg);
        lua.raiseError();
    }
    lua.pop(1);

    // Parse value callback.
    _ = lua.getField(idx, "value");
    if (callbackFieldPathAlloc(allocator, base_path, "value")) |field_path| {
        defer allocator.free(field_path);
        if (parsePromptCallbackField(lua, allocator, field_path)) |code| {
            defer allocator.free(code);
            command = allocator.dupe(u8, code) catch null;
        }
    }
    lua.pop(1);

    _ = lua.getField(idx, "builtin");
    if (callbackFieldPathAlloc(allocator, base_path, "builtin")) |field_path| {
        defer allocator.free(field_path);
        if (parsePromptCallbackField(lua, allocator, field_path)) |code| {
            defer allocator.free(code);
            builtin_command = allocator.dupe(u8, code) catch null;
        }
    }
    lua.pop(1);

    const has_button = blk: {
        _ = lua.getField(idx, "button");
        const is_tbl = lua.typeOf(-1) == .table;
        lua.pop(1);
        _ = lua.getField(idx, "on_click");
        const has_left = lua.typeOf(-1) == .string;
        lua.pop(1);
        _ = lua.getField(idx, "on_left_click");
        const has_left_alias = lua.typeOf(-1) == .string;
        lua.pop(1);
        _ = lua.getField(idx, "on_right_click");
        const has_right = lua.typeOf(-1) == .string;
        lua.pop(1);
        _ = lua.getField(idx, "on_middle_click");
        const has_mid = lua.typeOf(-1) == .string;
        lua.pop(1);
        break :blk is_tbl or has_left or has_left_alias or has_right or has_mid;
    };
    const has_progress = blk: {
        _ = lua.getField(idx, "progress");
        const is_tbl = lua.typeOf(-1) == .table;
        lua.pop(1);
        break :blk is_tbl or progress_show_when != null;
    };
    const kind: config.SegmentKind = if (has_progress)
        .progress
    else if (has_button)
        .button
    else if (builtin_command != null and command == null)
        .builtin
    else
        .value;

    _ = lua.getField(idx, "progress");
    if (kind == .progress and lua.typeOf(-1) == .table and command == null) {
        _ = lua.getField(-1, "builtin");
        if (builtin_command == null) {
            if (callbackFieldPathAlloc(allocator, base_path, "progress.builtin")) |field_path| {
                defer allocator.free(field_path);
                if (parsePromptCallbackField(lua, allocator, field_path)) |code| {
                    defer allocator.free(code);
                    builtin_command = allocator.dupe(u8, code) catch null;
                }
            }
        }
        lua.pop(1);
        _ = lua.getField(-1, "every_ms");
        if (lua.typeOf(-1) == .number) {
            const v = lua.toNumber(-1) catch 1000;
            if (std.math.isFinite(v)) progress_every_ms = @intFromFloat(std.math.clamp(v, 1, 60000));
        }
        lua.pop(1);
        _ = lua.getField(-1, "show_when");
        if (progress_show_when == null) {
            if (callbackFieldPathAlloc(allocator, base_path, "progress.show_when")) |field_path| {
                defer allocator.free(field_path);
                if (parsePromptCallbackField(lua, allocator, field_path)) |code| {
                    defer allocator.free(code);
                    progress_show_when = allocator.dupe(u8, code) catch null;
                }
            }
        }
        lua.pop(1);
        _ = lua.getField(-1, "value");
        if (command == null) {
            if (callbackFieldPathAlloc(allocator, base_path, "progress.value")) |field_path| {
                defer allocator.free(field_path);
                if (parsePromptCallbackField(lua, allocator, field_path)) |code| {
                    defer allocator.free(code);
                    command = allocator.dupe(u8, code) catch null;
                }
            }
        }
        lua.pop(1);
    }
    lua.pop(1);

    if (kind == .button) {
        const msg = std.fmt.allocPrint(allocator, "{s}: button segments are not allowed in prompt", .{base_path}) catch null;
        defer if (msg) |m| allocator.free(m);
        _ = lua.pushString(msg orelse "button segments are not allowed in prompt");
        lua.raiseError();
    }

    if (kind == .progress) {
        const msg = std.fmt.allocPrint(allocator, "{s}: progress segments are not allowed in prompt", .{base_path}) catch null;
        defer if (msg) |m| allocator.free(m);
        _ = lua.pushString(msg orelse "progress segments are not allowed in prompt");
        lua.raiseError();
    }

    if (kind == .builtin and command == null) command = builtin_command;

    var inverse_on_hover: bool = true;
    _ = lua.getField(idx, "inverse_on_hover");
    if (lua.typeOf(-1) == .boolean) inverse_on_hover = lua.toBoolean(-1);
    lua.pop(1);

    _ = lua.getField(idx, "button");
    if (lua.typeOf(-1) == .table) {
        _ = lua.getField(-1, "inverse_on_hover");
        if (lua.typeOf(-1) == .boolean) inverse_on_hover = lua.toBoolean(-1);
        lua.pop(1);
    }
    lua.pop(1);

    if (command == null) {
        const msg = switch (kind) {
            .builtin => "builtin segment requires non-empty 'builtin'",
            .value => "value segment requires a non-empty 'value'",
            .button => "button segment requires 'value' or 'builtin'",
            .progress => "progress segment requires 'value' or 'builtin'",
        };
        const owned_msg = std.fmt.allocPrint(allocator, "{s}: {s}", .{ base_path, msg }) catch null;
        defer if (owned_msg) |m| allocator.free(m);
        _ = lua.pushString(owned_msg orelse msg);
        lua.raiseError();
    }

    return config_builder.ShpConfigBuilder.SegmentDef{
        .name = name.?,
        .kind = kind,
        .priority = priority,
        .outputs = outputs.toOwnedSlice(allocator) catch &[_]config_builder.ShpConfigBuilder.OutputDef{},
        .command = command,
        .builtin = null,
        .progress_every_ms = progress_every_ms,
        .progress_show_when = progress_show_when,
        .inverse_on_hover = inverse_on_hover,
        .when = null,
    };
}

/// Lua C function: hexe.shp.prompt.left(segments)
pub export fn hexe_shp_prompt_left(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Arg 1 must be a table (array of segments)
    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("prompt.left: argument must be a table");
        lua.raiseError();
    }

    // Get ShpConfigBuilder
    const shp = getShpBuilder(lua) catch {
        _ = lua.pushString("prompt.left: failed to get config builder");
        lua.raiseError();
    };

    // Parse segments array
    const n = lua.rawLen(1);
    var i: i32 = 1;
    while (i <= n) : (i += 1) {
        _ = lua.rawGetIndex(1, i);
        const seg_path = std.fmt.allocPrint(shp.allocator, "prompt.left[{d}]", .{i}) catch "prompt.left[?]";
        defer if (!std.mem.eql(u8, seg_path, "prompt.left[?]")) shp.allocator.free(seg_path);
        if (parseSegmentDef(lua, -1, shp.allocator, seg_path)) |segment| {
            shp.left_segments.append(shp.allocator, segment) catch {};
        }
        lua.pop(1);
    }

    return 0;
}

/// Lua C function: hexe.shp.prompt.right(segments)
pub export fn hexe_shp_prompt_right(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Arg 1 must be a table (array of segments)
    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("prompt.right: argument must be a table");
        lua.raiseError();
    }

    // Get ShpConfigBuilder
    const shp = getShpBuilder(lua) catch {
        _ = lua.pushString("prompt.right: failed to get config builder");
        lua.raiseError();
    };

    // Parse segments array
    const n = lua.rawLen(1);
    var i: i32 = 1;
    while (i <= n) : (i += 1) {
        _ = lua.rawGetIndex(1, i);
        const seg_path = std.fmt.allocPrint(shp.allocator, "prompt.right[{d}]", .{i}) catch "prompt.right[?]";
        defer if (!std.mem.eql(u8, seg_path, "prompt.right[?]")) shp.allocator.free(seg_path);
        if (parseSegmentDef(lua, -1, shp.allocator, seg_path)) |segment| {
            shp.right_segments.append(shp.allocator, segment) catch {};
        }
        lua.pop(1);
    }

    return 0;
}

/// Lua C function: hexe.shp.prompt.add(side, segment)
pub export fn hexe_shp_prompt_add(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Arg 1: side (string: "left" or "right")
    // Arg 2: segment (table)
    if (lua.typeOf(1) != .string or lua.typeOf(2) != .table) {
        _ = lua.pushString("prompt.add: arguments must be (string, table)");
        lua.raiseError();
    }

    const side = lua.toString(1) catch {
        _ = lua.pushString("prompt.add: invalid side string");
        lua.raiseError();
    };

    // Get ShpConfigBuilder
    const shp = getShpBuilder(lua) catch {
        _ = lua.pushString("prompt.add: failed to get config builder");
        lua.raiseError();
    };

    // Parse segment
    if (parseSegmentDef(lua, 2, shp.allocator, "prompt.add.segment")) |segment| {
        if (std.mem.eql(u8, side, "left")) {
            shp.left_segments.append(shp.allocator, segment) catch {};
        } else if (std.mem.eql(u8, side, "right")) {
            shp.right_segments.append(shp.allocator, segment) catch {};
        } else {
            _ = lua.pushString("prompt.add: side must be 'left' or 'right'");
            lua.raiseError();
        }
    }

    return 0;
}

// ============================================================================
// Section 4: POP (Popups & Overlays) C API
// ============================================================================

/// Helper: Parse notification style from table
fn parseNotificationStyle(lua: *Lua, idx: i32, allocator: std.mem.Allocator) config_builder.PopConfigBuilder.NotificationStyleDef {
    var style = config_builder.PopConfigBuilder.NotificationStyleDef{};

    _ = lua.getField(idx, "fg");
    if (lua.typeOf(-1) == .number) style.fg = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "bg");
    if (lua.typeOf(-1) == .number) style.bg = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "bold");
    if (lua.typeOf(-1) == .boolean) style.bold = lua.toBoolean(-1);
    lua.pop(1);

    _ = lua.getField(idx, "padding_x");
    if (lua.typeOf(-1) == .number) style.padding_x = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "padding_y");
    if (lua.typeOf(-1) == .number) style.padding_y = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "offset");
    if (lua.typeOf(-1) == .number) style.offset = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "alignment");
    if (lua.typeOf(-1) == .string) {
        const s = lua.toString(-1) catch "";
        style.alignment = allocator.dupe(u8, s) catch null;
    }
    lua.pop(1);

    _ = lua.getField(idx, "duration_ms");
    if (lua.typeOf(-1) == .number) style.duration_ms = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    return style;
}

/// Lua C function: hexe.pop.notify.setup(opts)
pub export fn hexe_pop_notify_setup(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("notify.setup: argument must be a table");
        lua.raiseError();
    }

    const pop = getPopBuilder(lua) catch {
        _ = lua.pushString("notify.setup: failed to get config builder");
        lua.raiseError();
    };

    // Parse carrier realm
    _ = lua.getField(1, "carrier");
    if (lua.typeOf(-1) == .table) {
        pop.carrier_notification = parseNotificationStyle(lua, -1, pop.allocator);
    }
    lua.pop(1);

    // Parse pane realm
    _ = lua.getField(1, "pane");
    if (lua.typeOf(-1) == .table) {
        pop.pane_notification = parseNotificationStyle(lua, -1, pop.allocator);
    }
    lua.pop(1);

    return 0;
}

/// Helper: Parse confirm style from table
fn parseConfirmStyle(lua: *Lua, idx: i32, allocator: std.mem.Allocator) config_builder.PopConfigBuilder.ConfirmStyleDef {
    var style = config_builder.PopConfigBuilder.ConfirmStyleDef{};

    _ = lua.getField(idx, "fg");
    if (lua.typeOf(-1) == .number) style.fg = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "bg");
    if (lua.typeOf(-1) == .number) style.bg = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "bold");
    if (lua.typeOf(-1) == .boolean) style.bold = lua.toBoolean(-1);
    lua.pop(1);

    _ = lua.getField(idx, "padding_x");
    if (lua.typeOf(-1) == .number) style.padding_x = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "padding_y");
    if (lua.typeOf(-1) == .number) style.padding_y = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "yes_label");
    if (lua.typeOf(-1) == .string) {
        const s = lua.toString(-1) catch "";
        style.yes_label = allocator.dupe(u8, s) catch null;
    }
    lua.pop(1);

    _ = lua.getField(idx, "no_label");
    if (lua.typeOf(-1) == .string) {
        const s = lua.toString(-1) catch "";
        style.no_label = allocator.dupe(u8, s) catch null;
    }
    lua.pop(1);

    return style;
}

/// Lua C function: hexe.pop.confirm.setup(opts)
pub export fn hexe_pop_confirm_setup(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("confirm.setup: argument must be a table");
        lua.raiseError();
    }

    const pop = getPopBuilder(lua) catch {
        _ = lua.pushString("confirm.setup: failed to get config builder");
        lua.raiseError();
    };

    // Parse carrier realm
    _ = lua.getField(1, "carrier");
    if (lua.typeOf(-1) == .table) {
        pop.carrier_confirm = parseConfirmStyle(lua, -1, pop.allocator);
    }
    lua.pop(1);

    // Parse pane realm
    _ = lua.getField(1, "pane");
    if (lua.typeOf(-1) == .table) {
        pop.pane_confirm = parseConfirmStyle(lua, -1, pop.allocator);
    }
    lua.pop(1);

    return 0;
}

/// Helper: Parse choose style from table
fn parseChooseStyle(lua: *Lua, idx: i32, allocator: std.mem.Allocator) config_builder.PopConfigBuilder.ChooseStyleDef {
    _ = allocator;
    var style = config_builder.PopConfigBuilder.ChooseStyleDef{};

    _ = lua.getField(idx, "fg");
    if (lua.typeOf(-1) == .number) style.fg = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "bg");
    if (lua.typeOf(-1) == .number) style.bg = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "highlight_fg");
    if (lua.typeOf(-1) == .number) style.highlight_fg = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "highlight_bg");
    if (lua.typeOf(-1) == .number) style.highlight_bg = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "bold");
    if (lua.typeOf(-1) == .boolean) style.bold = lua.toBoolean(-1);
    lua.pop(1);

    _ = lua.getField(idx, "padding_x");
    if (lua.typeOf(-1) == .number) style.padding_x = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "padding_y");
    if (lua.typeOf(-1) == .number) style.padding_y = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "visible_count");
    if (lua.typeOf(-1) == .number) style.visible_count = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    return style;
}

/// Lua C function: hexe.pop.choose.setup(opts)
pub export fn hexe_pop_choose_setup(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("choose.setup: argument must be a table");
        lua.raiseError();
    }

    const pop = getPopBuilder(lua) catch {
        _ = lua.pushString("choose.setup: failed to get config builder");
        lua.raiseError();
    };

    // Parse carrier realm
    _ = lua.getField(1, "carrier");
    if (lua.typeOf(-1) == .table) {
        pop.carrier_choose = parseChooseStyle(lua, -1, pop.allocator);
    }
    lua.pop(1);

    // Parse pane realm
    _ = lua.getField(1, "pane");
    if (lua.typeOf(-1) == .table) {
        pop.pane_choose = parseChooseStyle(lua, -1, pop.allocator);
    }
    lua.pop(1);

    return 0;
}

/// Lua C function: hexe.pop.widgets.pokemon(opts)
pub export fn hexe_pop_widgets_pokemon(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("widgets.pokemon: argument must be a table");
        lua.raiseError();
    }

    const pop = getPopBuilder(lua) catch {
        _ = lua.pushString("widgets.pokemon: failed to get config builder");
        lua.raiseError();
    };

    _ = lua.getField(1, "enabled");
    if (lua.typeOf(-1) == .boolean) {
        pop.widgets.pokemon_enabled = lua.toBoolean(-1);
    }
    lua.pop(1);

    _ = lua.getField(1, "position");
    if (lua.typeOf(-1) == .string) {
        const s = lua.toString(-1) catch "";
        pop.widgets.pokemon_position = pop.allocator.dupe(u8, s) catch null;
    }
    lua.pop(1);

    _ = lua.getField(1, "shiny_chance");
    if (lua.typeOf(-1) == .number) {
        pop.widgets.pokemon_shiny_chance = @floatCast(lua.toNumber(-1) catch 0.01);
    }
    lua.pop(1);

    return 0;
}

/// Lua C function: hexe.pop.widgets.keycast(opts)
pub export fn hexe_pop_widgets_keycast(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("widgets.keycast: argument must be a table");
        lua.raiseError();
    }

    const pop = getPopBuilder(lua) catch {
        _ = lua.pushString("widgets.keycast: failed to get config builder");
        lua.raiseError();
    };

    _ = lua.getField(1, "enabled");
    if (lua.typeOf(-1) == .boolean) {
        pop.widgets.keycast_enabled = lua.toBoolean(-1);
    }
    lua.pop(1);

    _ = lua.getField(1, "position");
    if (lua.typeOf(-1) == .string) {
        const s = lua.toString(-1) catch "";
        pop.widgets.keycast_position = pop.allocator.dupe(u8, s) catch null;
    }
    lua.pop(1);

    _ = lua.getField(1, "duration_ms");
    if (lua.typeOf(-1) == .number) {
        pop.widgets.keycast_duration_ms = lua.toInteger(-1) catch 3000;
    }
    lua.pop(1);

    _ = lua.getField(1, "max_entries");
    if (lua.typeOf(-1) == .number) {
        pop.widgets.keycast_max_entries = @intCast(lua.toInteger(-1) catch 5);
    }
    lua.pop(1);

    _ = lua.getField(1, "grouping_timeout_ms");
    if (lua.typeOf(-1) == .number) {
        pop.widgets.keycast_grouping_timeout_ms = lua.toInteger(-1) catch 500;
    }
    lua.pop(1);

    return 0;
}

/// Lua C function: hexe.pop.widgets.digits(opts)
pub export fn hexe_pop_widgets_digits(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("widgets.digits: argument must be a table");
        lua.raiseError();
    }

    const pop = getPopBuilder(lua) catch {
        _ = lua.pushString("widgets.digits: failed to get config builder");
        lua.raiseError();
    };

    _ = lua.getField(1, "enabled");
    if (lua.typeOf(-1) == .boolean) {
        pop.widgets.digits_enabled = lua.toBoolean(-1);
    }
    lua.pop(1);

    _ = lua.getField(1, "position");
    if (lua.typeOf(-1) == .string) {
        const s = lua.toString(-1) catch "";
        pop.widgets.digits_position = pop.allocator.dupe(u8, s) catch null;
    }
    lua.pop(1);

    _ = lua.getField(1, "size");
    if (lua.typeOf(-1) == .string) {
        const s = lua.toString(-1) catch "";
        pop.widgets.digits_size = pop.allocator.dupe(u8, s) catch null;
    }
    lua.pop(1);

    return 0;
}

fn shellQuote(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();
    try out.append('\'');
    for (text) |ch| {
        if (ch == '\'') {
            try out.appendSlice("'\"'\"'");
        } else {
            try out.append(ch);
        }
    }
    try out.append('\'');
    return out.toOwnedSlice();
}

fn buildRecordCommand(lua: *Lua, action: enum { start, stop, toggle, status }) ?[]u8 {
    if (lua.typeOf(1) != .table) return null;
    const allocator = std.heap.page_allocator;

    _ = lua.getField(1, "scope");
    const scope = if (lua.typeOf(-1) == .string) (lua.toString(-1) catch "pod") else "pod";
    lua.pop(1);
    if (!std.mem.eql(u8, scope, "pod") and !std.mem.eql(u8, scope, "mux")) return null;

    _ = lua.getField(1, "target");
    _ = if (lua.typeOf(-1) == .string) (lua.toString(-1) catch "") else "";
    lua.pop(1);

    _ = lua.getField(1, "uuid");
    const uuid = if (lua.typeOf(-1) == .string) (lua.toString(-1) catch "") else "";
    lua.pop(1);
    _ = lua.getField(1, "name");
    const name = if (lua.typeOf(-1) == .string) (lua.toString(-1) catch "") else "";
    lua.pop(1);
    _ = lua.getField(1, "socket");
    const socket = if (lua.typeOf(-1) == .string) (lua.toString(-1) catch "") else "";
    lua.pop(1);

    _ = lua.getField(1, "out");
    const out = if (lua.typeOf(-1) == .string) (lua.toString(-1) catch "") else "/tmp/hexe-pod.cast";
    lua.pop(1);

    _ = lua.getField(1, "capture_input");
    const capture_input = if (lua.typeOf(-1) == .boolean) lua.toBoolean(-1) else false;
    lua.pop(1);

    var target_flag: []const u8 = "";
    var target_value: []const u8 = "";
    if (uuid.len > 0) {
        target_flag = "--uuid";
        target_value = uuid;
    } else if (name.len > 0) {
        target_flag = "--name";
        target_value = name;
    } else if (socket.len > 0) {
        target_flag = "--socket";
        target_value = socket;
    }

    var cmd = std.array_list.Managed(u8).init(allocator);
    defer cmd.deinit();

    const action_name: []const u8 = switch (action) {
        .start => "start",
        .stop => "stop",
        .toggle => "toggle",
        .status => "status",
    };

    cmd.appendSlice("hexe record ") catch return null;
    cmd.appendSlice(action_name) catch return null;
    cmd.appendSlice(" --scope ") catch return null;
    cmd.appendSlice(scope) catch return null;

    if ((action == .start or action == .toggle) and out.len > 0) {
        const qout = shellQuote(allocator, out) catch return null;
        defer allocator.free(qout);
        cmd.appendSlice(" --out ") catch return null;
        cmd.appendSlice(qout) catch return null;
    }
    if (std.mem.eql(u8, scope, "pod") and target_flag.len > 0 and (action == .start or action == .toggle)) {
        cmd.appendSlice(" ") catch return null;
        cmd.appendSlice(target_flag) catch return null;
        cmd.appendSlice(" ") catch return null;
        if (std.mem.startsWith(u8, target_value, "$HEXE_") or std.mem.startsWith(u8, target_value, "${HEXE_")) {
            // Allow runtime env expansion for hexe-provided dynamic targets.
            cmd.appendSlice(target_value) catch return null;
        } else {
            const qtarget = shellQuote(allocator, target_value) catch return null;
            defer allocator.free(qtarget);
            cmd.appendSlice(qtarget) catch return null;
        }
    }
    if ((action == .start or action == .toggle) and capture_input) {
        cmd.appendSlice(" --capture-input") catch return null;
    }
    return cmd.toOwnedSlice() catch null;
}

pub export fn hexe_record_start(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);
    const cmd = buildRecordCommand(lua, .start) orelse {
        _ = lua.pushString("record.start: expected opts table with scope='pod' or 'mux'");
        lua.raiseError();
    };
    defer std.heap.page_allocator.free(cmd);
    _ = lua.pushString(cmd);
    return 1;
}

pub export fn hexe_record_stop(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);
    const cmd = buildRecordCommand(lua, .stop) orelse {
        _ = lua.pushString("record.stop: expected opts table with scope='pod' or 'mux'");
        lua.raiseError();
    };
    defer std.heap.page_allocator.free(cmd);
    _ = lua.pushString(cmd);
    return 1;
}

pub export fn hexe_record_toggle(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);
    const cmd = buildRecordCommand(lua, .toggle) orelse {
        _ = lua.pushString("record.toggle: expected opts table with scope='pod' or 'mux'");
        lua.raiseError();
    };
    defer std.heap.page_allocator.free(cmd);
    _ = lua.pushString(cmd);
    return 1;
}

fn sanitizeInstanceNameLocal(buf: []u8, input: []const u8) []const u8 {
    var n: usize = 0;
    for (input) |ch| {
        if (n >= buf.len) break;
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_' or ch == '-') {
            buf[n] = ch;
            n += 1;
        }
    }
    if (n == 0) {
        const d = "default";
        @memcpy(buf[0..d.len], d);
        return buf[0..d.len];
    }
    return buf[0..n];
}

fn recordStatePathAlloc(allocator: std.mem.Allocator, scope: []const u8) ![]u8 {
    const inst = std.posix.getenv("HEXE_INSTANCE") orelse "default";
    var safe_buf: [64]u8 = undefined;
    const safe = sanitizeInstanceNameLocal(safe_buf[0..], inst);
    return std.fmt.allocPrint(allocator, "/tmp/hexe/{s}/record-{s}.state", .{ safe, scope });
}

pub export fn hexe_record_status(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    var scope: []const u8 = "pod";
    if (lua.typeOf(1) == .table) {
        _ = lua.getField(1, "scope");
        if (lua.typeOf(-1) == .string) {
            scope = lua.toString(-1) catch "pod";
        }
        lua.pop(1);
    }
    if (!std.mem.eql(u8, scope, "pod") and !std.mem.eql(u8, scope, "mux")) {
        scope = "pod";
    }

    const allocator = std.heap.page_allocator;
    const state_path = recordStatePathAlloc(allocator, scope) catch {
        lua.createTable(0, 2);
        lua.pushBoolean(false);
        lua.setField(-2, "active");
        _ = lua.pushString(scope);
        lua.setField(-2, "scope");
        return 1;
    };
    defer allocator.free(state_path);

    const data = std.fs.cwd().readFileAlloc(allocator, state_path, 16 * 1024) catch {
        lua.createTable(0, 2);
        lua.pushBoolean(false);
        lua.setField(-2, "active");
        _ = lua.pushString(scope);
        lua.setField(-2, "scope");
        return 1;
    };
    defer allocator.free(data);

    var pid: i32 = 0;
    var started_ms: i64 = 0;
    var out: []const u8 = "";
    var uuid: []const u8 = "";
    var lines = std.mem.tokenizeAny(u8, data, "\n");
    while (lines.next()) |line| {
        var kv = std.mem.splitScalar(u8, line, '=');
        const k = kv.first();
        const v = kv.next() orelse "";
        if (std.mem.eql(u8, k, "pid")) pid = std.fmt.parseInt(i32, v, 10) catch 0;
        if (std.mem.eql(u8, k, "started_ms")) started_ms = std.fmt.parseInt(i64, v, 10) catch 0;
        if (std.mem.eql(u8, k, "out")) out = v;
        if (std.mem.eql(u8, k, "uuid")) uuid = v;
    }

    const active = pid > 0 and std.c.kill(pid, 0) == 0;
    if (!active) {
        std.fs.cwd().deleteFile(state_path) catch {};
    }

    lua.createTable(0, 6);
    lua.pushBoolean(active);
    lua.setField(-2, "active");
    _ = lua.pushString(scope);
    lua.setField(-2, "scope");
    if (active) {
        lua.pushInteger(pid);
        lua.setField(-2, "pid");
        if (out.len > 0) {
            _ = lua.pushString(out);
            lua.setField(-2, "out");
        }
        if (uuid.len > 0) {
            _ = lua.pushString(uuid);
            lua.setField(-2, "uuid");
        }
        if (started_ms > 0) {
            lua.pushInteger(started_ms);
            lua.setField(-2, "started_ms");
        }
    }
    return 1;
}

fn freeParsedSegment(seg: *config.Segment, allocator: std.mem.Allocator) void {
    allocator.free(seg.name);
    if (seg.command) |v| allocator.free(v);
    if (seg.builtin) |v| allocator.free(v);
    if (seg.progress_show_when) |v| allocator.free(v);
    if (seg.on_click) |v| allocator.free(v);
    if (seg.on_right_click) |v| allocator.free(v);
    if (seg.on_middle_click) |v| allocator.free(v);
    if (seg.button_active_bash) |v| allocator.free(v);
    if (seg.button_left_style) |v| allocator.free(v);
    if (seg.button_middle_style) |v| allocator.free(v);
    if (seg.button_right_style) |v| allocator.free(v);
    if (seg.when) |*w| {
        var when = w.*;
        when.deinit(allocator);
    }
    if (seg.spinner) |*sp| {
        var spinner = sp.*;
        spinner.deinit(allocator);
    }
}

test "parseSegmentAtPath accepts callback active_when in button table" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.deinit();

    const chunk =
        "seg = {" ++
        "name='rec'," ++
        "value=function(_) return 'REC' end," ++
        "button={ active_when=function(_) return true end }" ++
        "}";
    const z = try std.testing.allocator.dupeZ(u8, chunk);
    defer std.testing.allocator.free(z);
    try lua.loadString(z);
    try lua.protectedCall(.{ .args = 0, .results = 0 });

    _ = try lua.getGlobal("seg");
    defer lua.pop(1);

    var seg = parseSegmentAtPath(&lua, -1, std.testing.allocator, "mux.tabs.left[1]") orelse return error.TestUnexpectedResult;
    defer freeParsedSegment(&seg, std.testing.allocator);

    try std.testing.expect(seg.button_active_bash != null);
    try std.testing.expect(std.mem.startsWith(u8, seg.button_active_bash.?, CALLBACK_REF_PREFIX));
}

test "parseSegmentAtPath accepts callback active_when at segment level" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.deinit();

    const chunk =
        "seg = {" ++
        "name='rec'," ++
        "value=function(_) return 'REC' end," ++
        "active_when=function(_) return true end" ++
        "}";
    const z = try std.testing.allocator.dupeZ(u8, chunk);
    defer std.testing.allocator.free(z);
    try lua.loadString(z);
    try lua.protectedCall(.{ .args = 0, .results = 0 });

    _ = try lua.getGlobal("seg");
    defer lua.pop(1);

    var seg = parseSegmentAtPath(&lua, -1, std.testing.allocator, "mux.tabs.left[1]") orelse return error.TestUnexpectedResult;
    defer freeParsedSegment(&seg, std.testing.allocator);

    try std.testing.expect(seg.button_active_bash != null);
    try std.testing.expect(std.mem.startsWith(u8, seg.button_active_bash.?, CALLBACK_REF_PREFIX));
}
