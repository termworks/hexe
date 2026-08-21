//! JSON on one side, Lua values on the other.
//!
//! hexe's richest API is the live query surface in `lua_api.zig` — every pane,
//! float, tab and session field the mux knows, plus the verbs that change them.
//! It was reachable only from inside the frontend process, so anything outside
//! (a web gateway, a phone client, a shell script) had to scrape human-readable
//! CLI output for facts the mux already knew precisely.
//!
//! Rather than restate that surface in a second encoder — two field lists that
//! drift the moment either is edited — the control socket calls the same Lua
//! functions and converts what comes back. There is one definition of what a
//! pane is, and it is the one Lua already sees.
//!
//! Both directions are bounded. A Lua table can be cyclic and a request can be
//! hostile, so depth and output size are capped rather than trusted.

const std = @import("std");
const zlua = @import("zlua");
const core = @import("core");

const Lua = zlua.Lua;

/// How deep a value may nest in either direction. Live API results are shallow
/// (a list of flat records); anything deeper is a cycle or a mistake.
pub const MAX_DEPTH: u8 = 12;

pub const Error = error{
    TooDeep,
    Unsupported,
    OutOfMemory,
};

/// Whether a table's keys are `1..n` with nothing else, which is the only case
/// that can round-trip through JSON as an array.
///
/// Lua cannot tell a list from a map and JSON must: guessing from `rawLen`
/// alone turns `{}` into `[]`, and a record that happens to carry a `[1]` into
/// a list with its named fields silently dropped.
fn isArray(lua: *Lua, idx: i32) bool {
    const n = lua.rawLen(idx);
    if (n == 0) return false;

    var count: usize = 0;
    lua.pushNil();
    while (lua.next(idx)) {
        // key at -2, value at -1
        if (lua.typeOf(-2) != .number) {
            lua.pop(2);
            return false;
        }
        const k = lua.toNumber(-2) catch {
            lua.pop(2);
            return false;
        };
        if (k != @floor(k) or k < 1 or k > @as(f64, @floatFromInt(n))) {
            lua.pop(2);
            return false;
        }
        count += 1;
        lua.pop(1);
    }
    return count == n;
}

fn writeNumber(w: anytype, v: f64) !void {
    // Integers print as integers: a pane index of `3` reaching a client as
    // `3.0e0` is technically a number and practically a bug report.
    if (v == @floor(v) and @abs(v) < 9007199254740992.0) {
        try w.print("{d}", .{@as(i64, @intFromFloat(v))});
    } else {
        try w.print("{d}", .{v});
    }
}

/// Serialize the Lua value at `idx` as JSON.
pub fn write(lua: *Lua, idx: i32, w: anytype, depth: u8) !void {
    if (depth > MAX_DEPTH) return Error.TooDeep;
    // Each level parks a key and a value on the Lua stack, whose default size
    // is far smaller than MAX_DEPTH levels need. Without this, a cyclic table
    // aborts the process inside lua_next before the depth guard is ever
    // reached -- a panic where an error was intended.
    lua.checkStack(8) catch return Error.TooDeep;

    const abs: i32 = if (idx < 0) lua.getTop() + idx + 1 else idx;
    switch (lua.typeOf(abs)) {
        .nil, .none => try w.writeAll("null"),
        .boolean => try w.writeAll(if (lua.toBoolean(abs)) "true" else "false"),
        .number => try writeNumber(w, lua.toNumber(abs) catch 0),
        .string => {
            const s = lua.toString(abs) catch "";
            try core.regions.writeJsonString(w, s);
        },
        .table => {
            if (isArray(lua, abs)) {
                try w.writeByte('[');
                const n = lua.rawLen(abs);
                var i: usize = 1;
                while (i <= n) : (i += 1) {
                    if (i > 1) try w.writeByte(',');
                    _ = lua.rawGetIndex(abs, @intCast(i));
                    try write(lua, -1, w, depth + 1);
                    lua.pop(1);
                }
                try w.writeByte(']');
            } else {
                try w.writeByte('{');
                var first = true;
                lua.pushNil();
                while (lua.next(abs)) {
                    // A non-string key has no JSON spelling; skipping it keeps
                    // the rest of the record rather than failing the call.
                    const kt = lua.typeOf(-2);
                    if (kt == .string or kt == .number) {
                        if (!first) try w.writeByte(',');
                        first = false;
                        // Copy the key before tostring: converting in place
                        // would rewrite it on the stack and break `next`.
                        lua.pushValue(-2);
                        const key = lua.toString(-1) catch "";
                        try core.regions.writeJsonString(w, key);
                        lua.pop(1);
                        try w.writeByte(':');
                        try write(lua, -1, w, depth + 1);
                    }
                    lua.pop(1);
                }
                try w.writeByte('}');
            }
        },
        // A function or userdata cannot cross the socket. Naming it is more
        // use to a client than a silent null.
        .function => try w.writeAll("\"<function>\""),
        else => try w.writeAll("null"),
    }
}

/// Push a parsed JSON value onto the Lua stack.
pub fn push(lua: *Lua, value: std.json.Value, depth: u8) Error!void {
    if (depth > MAX_DEPTH) return Error.TooDeep;
    switch (value) {
        .null => lua.pushNil(),
        .bool => |b| lua.pushBoolean(b),
        .integer => |i| lua.pushInteger(@intCast(i)),
        .float => |f| lua.pushNumber(f),
        .number_string => |s| _ = lua.pushString(s),
        .string => |s| _ = lua.pushString(s),
        .array => |a| {
            lua.createTable(@intCast(a.items.len), 0);
            for (a.items, 0..) |item, i| {
                try push(lua, item, depth + 1);
                lua.rawSetIndex(-2, @intCast(i + 1));
            }
        },
        .object => |o| {
            lua.createTable(0, @intCast(o.count()));
            var it = o.iterator();
            while (it.next()) |kv| {
                // Pushed as a Lua string rather than passed to `setField`: a
                // JSON key is a plain slice, and setField wants a sentinel, so
                // it would read past the key into whatever follows it.
                _ = lua.pushString(kv.key_ptr.*);
                try push(lua, kv.value_ptr.*, depth + 1);
                lua.setTable(-3);
            }
        },
    }
}

test "a record keeps its named fields even when it also has [1]" {
    const lua = try Lua.init(std.testing.allocator);
    defer lua.deinit();

    // { name = "alfa", [1] = "x" } is a record, not a list. Treating it as an
    // array would drop `name`, which is exactly the field a caller wanted.
    lua.createTable(1, 1);
    _ = lua.pushString("alfa");
    lua.setField(-2, "name");
    _ = lua.pushString("x");
    lua.rawSetIndex(-2, 1);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try write(lua, -1, buf.writer(std.testing.allocator), 0);

    const out = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\"") != null);
    try std.testing.expect(out[0] == '{');
}

test "an empty table is an object, not an array" {
    const lua = try Lua.init(std.testing.allocator);
    defer lua.deinit();
    lua.createTable(0, 0);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try write(lua, -1, buf.writer(std.testing.allocator), 0);
    try std.testing.expectEqualStrings("{}", buf.items);
}

test "a list of records round-trips as an array" {
    const lua = try Lua.init(std.testing.allocator);
    defer lua.deinit();

    lua.createTable(2, 0);
    for (0..2) |i| {
        lua.createTable(0, 1);
        lua.pushInteger(@intCast(i));
        lua.setField(-2, "index");
        lua.rawSetIndex(-2, @intCast(i + 1));
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try write(lua, -1, buf.writer(std.testing.allocator), 0);
    try std.testing.expectEqualStrings("[{\"index\":0},{\"index\":1}]", buf.items);
}

test "integers do not arrive as floats" {
    const lua = try Lua.init(std.testing.allocator);
    defer lua.deinit();
    lua.pushNumber(3.0);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try write(lua, -1, buf.writer(std.testing.allocator), 0);
    try std.testing.expectEqualStrings("3", buf.items);
}

test "a cycle is refused rather than followed forever" {
    const lua = try Lua.init(std.testing.allocator);
    defer lua.deinit();

    lua.createTable(0, 1);
    lua.pushValue(-1);
    lua.setField(-2, "self");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try std.testing.expectError(Error.TooDeep, write(lua, -1, buf.writer(std.testing.allocator), 0));
}

test "JSON arguments become Lua values" {
    const lua = try Lua.init(std.testing.allocator);
    defer lua.deinit();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"visible\":true,\"n\":2}",
        .{},
    );
    defer parsed.deinit();

    try push(lua, parsed.value, 0);
    try std.testing.expectEqual(zlua.LuaType.table, lua.typeOf(-1));
    _ = lua.getField(-1, "visible");
    try std.testing.expect(lua.toBoolean(-1));
    lua.pop(1);
    _ = lua.getField(-1, "n");
    try std.testing.expectEqual(@as(i64, 2), try lua.toInteger(-1));
}
