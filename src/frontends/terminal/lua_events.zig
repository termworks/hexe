const core = @import("core");
const LuaRuntime = core.LuaRuntime;
const std = @import("std");
const lua_api = @import("lua_api.zig");

/// Emit autocmd callback(s) for `event_name`.
/// Expects payload table at stack top and always consumes it.
///
/// Supported handler registration in Lua config:
/// - `hexe.events.on(event_name, function(ev) ... end)` (canonical)
/// Internally, handlers are stored under `hexe.__events[event_name]` as a function
/// or an array of functions.
/// One payload field. Keeps `emit` call sites to one line each.
pub const Value = union(enum) {
    str: []const u8,
    int: i64,
    boolean: bool,
    uuid: [32]u8,
};

pub const Field = struct { name: [:0]const u8, value: Value };

/// Emit `event` with `fields` as its payload, plus `event` and `now_ms` which
/// every handler can rely on.
///
/// Building the payload by hand is ~14 lines of stack juggling per site, which
/// is why there were only five events. Adding one is now a single call.
pub fn emit(state: anytype, runtime: *LuaRuntime, event_name: []const u8, fields: []const Field) void {
    const lua = runtime.lua;
    lua.createTable(0, @intCast(fields.len + 2));

    _ = lua.pushString(event_name);
    lua.setField(-2, "event");
    lua.pushInteger(@intCast(std.time.milliTimestamp()));
    lua.setField(-2, "now_ms");

    for (fields) |f| {
        switch (f.value) {
            .str => |v| _ = lua.pushString(v),
            .int => |v| lua.pushInteger(v),
            .boolean => |v| lua.pushBoolean(v),
            .uuid => |v| _ = lua.pushString(v[0..]),
        }
        lua.setField(-2, f.name);
    }

    emitWithState(state, runtime, event_name);
}

/// Emit with the live query API bound, so `ctx`-style accessors work the same
/// inside an event handler as inside a keybinding callback. `state` is
/// `anytype` because this file is imported by State itself.
pub fn emitWithState(state: anytype, runtime: *LuaRuntime, event_name: []const u8) void {
    const scope = lua_api.pushLiveState(runtime, state, .handler);
    defer lua_api.popLiveState(runtime, scope);
    emitAutocmdWithPayloadOnStack(runtime, event_name);
}

pub fn emitAutocmdWithPayloadOnStack(runtime: *LuaRuntime, event_name: []const u8) void {
    const lua = runtime.lua;
    // Absolute index of the payload. The previous version addressed it
    // relatively (-4, and -6 inside the multi-handler loop) and popped a fixed
    // 4 at the end -- but `protectedCall` consumes the function and its
    // argument, so after a handler ran only three values remained and the pop
    // underflowed into `unreachable`. It never showed up because handlers were
    // being stored in a different table than this one reads, so no handler was
    // ever invoked.
    const payload_idx = lua.getTop();
    defer lua.pop(1); // payload

    _ = lua.getGlobal("hexe") catch return;
    if (lua.typeOf(-1) != .table) {
        lua.pop(1);
        return;
    }
    defer lua.pop(1); // hexe

    _ = lua.getField(-1, "__events");
    if (lua.typeOf(-1) != .table) {
        lua.pop(1);
        return;
    }
    defer lua.pop(1); // __events

    _ = lua.pushString(event_name);
    _ = lua.getTable(-2);
    defer lua.pop(1); // handler slot

    switch (lua.typeOf(-1)) {
        .function => {
            lua.pushValue(payload_idx);
            lua.protectedCall(.{ .args = 1, .results = 0 }) catch {
                lua.pop(1); // error object
            };
            // The call consumed the function, so put a placeholder back for
            // the deferred pop to balance against.
            lua.pushNil();
        },
        .table => {
            const len: i32 = @intCast(lua.rawLen(-1));
            var i: i32 = 1;
            while (i <= len) : (i += 1) {
                _ = lua.rawGetIndex(-1, i);
                if (lua.typeOf(-1) != .function) {
                    lua.pop(1);
                    continue;
                }
                lua.pushValue(payload_idx);
                lua.protectedCall(.{ .args = 1, .results = 0 }) catch {
                    lua.pop(1); // error object
                };
            }
        },
        else => {},
    }
}

test "emitAutocmdWithPayloadOnStack calls single function handler" {
    var rt = try LuaRuntime.init(std.testing.allocator);
    defer rt.deinit();

    const setup_z = try rt.allocator.dupeZ(
        u8,
        "__t_count = 0; __t_last = ''; hexe.events.on('test_event', function(ev) __t_count = __t_count + 1; __t_last = ev.kind or '' end)",
    );
    defer rt.allocator.free(setup_z);
    try rt.lua.loadString(setup_z);
    try rt.lua.protectedCall(.{ .args = 0, .results = 0 });

    rt.lua.createTable(0, 1);
    _ = rt.lua.pushString("alpha");
    rt.lua.setField(-2, "kind");
    emitAutocmdWithPayloadOnStack(&rt, "test_event");

    _ = try rt.lua.getGlobal("__t_count");
    defer rt.lua.pop(1);
    try std.testing.expect(rt.lua.typeOf(-1) == .number);
    try std.testing.expectEqual(@as(i32, 1), rt.lua.toInteger(-1) catch 0);

    _ = try rt.lua.getGlobal("__t_last");
    defer rt.lua.pop(1);
    try std.testing.expect(rt.lua.typeOf(-1) == .string);
    try std.testing.expectEqualStrings("alpha", rt.lua.toString(-1) catch "");
}

test "emitAutocmdWithPayloadOnStack calls handler list" {
    var rt = try LuaRuntime.init(std.testing.allocator);
    defer rt.deinit();

    const setup_z = try rt.allocator.dupeZ(
        u8,
        "__t_a = 0; __t_b = 0; hexe.events.on('test_event', function(ev) __t_a = __t_a + (ev.v or 0) end); hexe.events.on('test_event', function(ev) __t_b = __t_b + 1 end)",
    );
    defer rt.allocator.free(setup_z);
    try rt.lua.loadString(setup_z);
    try rt.lua.protectedCall(.{ .args = 0, .results = 0 });

    rt.lua.createTable(0, 1);
    rt.lua.pushInteger(7);
    rt.lua.setField(-2, "v");
    emitAutocmdWithPayloadOnStack(&rt, "test_event");

    _ = try rt.lua.getGlobal("__t_a");
    defer rt.lua.pop(1);
    try std.testing.expect(rt.lua.typeOf(-1) == .number);
    try std.testing.expectEqual(@as(i32, 7), rt.lua.toInteger(-1) catch 0);

    _ = try rt.lua.getGlobal("__t_b");
    defer rt.lua.pop(1);
    try std.testing.expect(rt.lua.typeOf(-1) == .number);
    try std.testing.expectEqual(@as(i32, 1), rt.lua.toInteger(-1) catch 0);
}

test "emitAutocmdWithPayloadOnStack continues after handler error" {
    var rt = try LuaRuntime.init(std.testing.allocator);
    defer rt.deinit();

    const setup_z = try rt.allocator.dupeZ(
        u8,
        "__t_ok = 0; hexe.events.on('test_event', function(_) error('boom') end); hexe.events.on('test_event', function(_) __t_ok = __t_ok + 1 end)",
    );
    defer rt.allocator.free(setup_z);
    try rt.lua.loadString(setup_z);
    try rt.lua.protectedCall(.{ .args = 0, .results = 0 });

    rt.lua.createTable(0, 0);
    emitAutocmdWithPayloadOnStack(&rt, "test_event");

    _ = try rt.lua.getGlobal("__t_ok");
    defer rt.lua.pop(1);
    try std.testing.expect(rt.lua.typeOf(-1) == .number);
    try std.testing.expectEqual(@as(i32, 1), rt.lua.toInteger(-1) catch 0);
}
