//! Float visual-options Lua parsing: `applyFloatVisualOptions` (the entry point
//! lua_runtime calls) plus its `parseFloatStyleTable` / `parseLuaCodepoint`
//! helpers. Split from `api_bridge.zig` (PLAN.md 2.3 spirit); the entry point is
//! re-exported from there so lua_runtime call sites are unchanged. Shared
//! helpers are aliased from api_bridge (circular import is fine in Zig).

const std = @import("std");
const zlua = @import("zlua");
const config = @import("config.zig");
const ab = @import("api_bridge.zig");

const Lua = zlua.Lua;
const log = std.log.scoped(.api_bridge);
const luaNumberOrRaise = ab.luaNumberOrRaise;
const parseSegment = ab.parseSegment;

fn parseFloatStyleTable(lua: *Lua, idx: i32, allocator: std.mem.Allocator) ?config.FloatStyle {
    if (lua.typeOf(idx) != .table) return null;

    var style = config.FloatStyle{};

    _ = lua.getField(idx, "border");
    if (lua.typeOf(-1) == .table) {
        _ = lua.getField(-1, "chars");
        if (lua.typeOf(-1) == .table) {
            const parseChar = struct {
                fn parse(l: *Lua, default: u21) u21 {
                    const s = l.toString(-1) catch |err| {
                        log.warn("failed to read float border character: {}", .{err});
                        return default;
                    };
                    if (s.len == 0) return default;
                    const codepoint = std.unicode.utf8Decode(s[0..@min(s.len, 4)]) catch |err| {
                        log.warn("failed to decode float border character: {}", .{err});
                        return default;
                    };
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
                const segs = allocator.alloc(config.Segment, seg_len) catch |err| blk: {
                    log.warn("failed to allocate API bridge float title segments: {}", .{err});
                    break :blk null;
                };
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

fn parseLuaCodepoint(lua: *Lua, default: u21, context: []const u8) u21 {
    const s = lua.toString(-1) catch |err| {
        log.warn("{s}: failed to read character: {}", .{ context, err });
        return default;
    };
    if (s.len == 0) return default;
    return std.unicode.utf8Decode(s[0..@min(s.len, 4)]) catch |err| {
        log.warn("{s}: failed to decode character: {}", .{ context, err });
        return default;
    };
}

pub fn applyFloatVisualOptions(comptime allow_attributes: bool, lua: *Lua, idx: i32, allocator: std.mem.Allocator, target: anytype) void {
    _ = lua.getField(idx, "size");
    if (lua.typeOf(-1) == .table) {
        _ = lua.getField(-1, "width");
        if (lua.typeOf(-1) == .number) {
            const w = luaNumberOrRaise(lua, -1, "float style: failed to parse width");
            target.width_percent = @intFromFloat(w);
        }
        lua.pop(1);

        _ = lua.getField(-1, "height");
        if (lua.typeOf(-1) == .number) {
            const h = luaNumberOrRaise(lua, -1, "float style: failed to parse height");
            target.height_percent = @intFromFloat(h);
        }
        lua.pop(1);
    }
    lua.pop(1);

    _ = lua.getField(idx, "padding");
    if (lua.typeOf(-1) == .table) {
        _ = lua.getField(-1, "x");
        if (lua.typeOf(-1) == .number) {
            const x = luaNumberOrRaise(lua, -1, "float style: failed to parse padding.x");
            target.padding_x = @intFromFloat(x);
        }
        lua.pop(1);

        _ = lua.getField(-1, "y");
        if (lua.typeOf(-1) == .number) {
            const y = luaNumberOrRaise(lua, -1, "float style: failed to parse padding.y");
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
            const a = luaNumberOrRaise(lua, -1, "float style: failed to parse color.active");
            color.active = @intFromFloat(a);
        }
        lua.pop(1);

        _ = lua.getField(-1, "passive");
        if (lua.typeOf(-1) == .number) {
            const p = luaNumberOrRaise(lua, -1, "float style: failed to parse color.passive");
            color.passive = @intFromFloat(p);
        }
        lua.pop(1);

        target.color = color;
    }
    lua.pop(1);

    if (allow_attributes) {
        _ = lua.getField(idx, "attributes");
        if (lua.typeOf(-1) != .nil) {
            _ = lua.pushString("float defaults field 'attributes' is removed; use attrs");
            lua.raiseError();
        }
        lua.pop(1);

        _ = lua.getField(idx, "attrs");
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
