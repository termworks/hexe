const core = @import("core");
const LuaRuntime = core.LuaRuntime;
const std = @import("std");

/// Emit autocmd callback(s) for `event_name`.
/// Expects payload table at stack top and always consumes it.
///
/// Supported handler registration in Lua config:
/// - `hx.events.on(event_name, function(ev) ... end)` (canonical)
/// Internally, handlers are stored under `hexe.autocmd[event_name]` as a function
/// or an array of functions.
pub fn emitAutocmdWithPayloadOnStack(runtime: *LuaRuntime, event_name: []const u8) void {
    // Stack: [..., payload]
    _ = runtime.lua.getGlobal("hexe") catch {
        runtime.lua.pop(1); // payload
        return;
    };
    if (runtime.lua.typeOf(-1) != .table) {
        runtime.lua.pop(2); // hexe, payload
        return;
    }

    _ = runtime.lua.getField(-1, "autocmd");
    if (runtime.lua.typeOf(-1) != .table) {
        runtime.lua.pop(3); // autocmd/hexe/payload
        return;
    }

    _ = runtime.lua.pushString(event_name);
    _ = runtime.lua.getTable(-2);
    const handler_ty = runtime.lua.typeOf(-1);
    switch (handler_ty) {
        .function => {
            runtime.lua.pushValue(-4); // payload
            runtime.lua.protectedCall(.{ .args = 1, .results = 0 }) catch {
                runtime.lua.pop(1); // lua error object
            };
        },
        .table => {
            const len: i32 = @intCast(runtime.lua.rawLen(-1));
            var i: i32 = 1;
            while (i <= len) : (i += 1) {
                _ = runtime.lua.rawGetIndex(-1, i);
                if (runtime.lua.typeOf(-1) != .function) {
                    runtime.lua.pop(1);
                    continue;
                }
                runtime.lua.pushValue(-6); // payload
                runtime.lua.protectedCall(.{ .args = 1, .results = 0 }) catch {
                    runtime.lua.pop(1); // lua error object
                };
            }
        },
        else => {},
    }

    runtime.lua.pop(4); // handler/autocmd/hexe/payload
}

test "emitAutocmdWithPayloadOnStack calls single function handler" {
    var rt = try LuaRuntime.init(std.testing.allocator);
    defer rt.deinit();

    const setup_z = try rt.allocator.dupeZ(
        u8,
        "__t_count = 0; __t_last = ''; hx.events.on('test_event', function(ev) __t_count = __t_count + 1; __t_last = ev.kind or '' end)",
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
        "__t_a = 0; __t_b = 0; hx.events.on('test_event', function(ev) __t_a = __t_a + (ev.v or 0) end); hx.events.on('test_event', function(ev) __t_b = __t_b + 1 end)",
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
        "__t_ok = 0; hx.events.on('test_event', function(_) error('boom') end); hx.events.on('test_event', function(_) __t_ok = __t_ok + 1 end)",
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
