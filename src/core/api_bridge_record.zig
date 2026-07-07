//! Record C-API glue: the `hexe_record_{start,stop,toggle,status}` Lua-exported
//! functions and their command builders. Split from `api_bridge.zig` (PLAN.md
//! 2.3 spirit); the exports are re-exported from there so lua_runtime's
//! registration is unchanged. Self-contained — the only api_bridge helper it
//! used (`appendBridgeCommandChunk`) had no other callers and moved with it.

const std = @import("std");
const zlua = @import("zlua");

const Lua = zlua.Lua;
const LuaState = zlua.LuaState;
const log = std.log.scoped(.api_bridge);

fn appendBridgeCommandChunk(cmd: *std.array_list.Managed(u8), chunk: []const u8, comptime context: []const u8) bool {
    cmd.appendSlice(chunk) catch |err| {
        log.warn(context ++ ": {}", .{err});
        return false;
    };
    return true;
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

    if (!appendBridgeCommandChunk(&cmd, "hexe record ", "failed to append record command prefix")) return null;
    if (!appendBridgeCommandChunk(&cmd, action_name, "failed to append record command action")) return null;
    if (!appendBridgeCommandChunk(&cmd, " --scope ", "failed to append record command scope flag")) return null;
    if (!appendBridgeCommandChunk(&cmd, scope, "failed to append record command scope")) return null;

    if ((action == .start or action == .toggle) and out.len > 0) {
        const qout = shellQuote(allocator, out) catch |err| {
            log.warn("failed to quote record output path: {}", .{err});
            return null;
        };
        defer allocator.free(qout);
        if (!appendBridgeCommandChunk(&cmd, " --out ", "failed to append record command output flag")) return null;
        if (!appendBridgeCommandChunk(&cmd, qout, "failed to append record command output path")) return null;
    }
    if (std.mem.eql(u8, scope, "pod") and target_flag.len > 0 and (action == .start or action == .toggle)) {
        if (!appendBridgeCommandChunk(&cmd, " ", "failed to append record command target separator")) return null;
        if (!appendBridgeCommandChunk(&cmd, target_flag, "failed to append record command target flag")) return null;
        if (!appendBridgeCommandChunk(&cmd, " ", "failed to append record command target value separator")) return null;
        if (std.mem.startsWith(u8, target_value, "$HEXE_") or std.mem.startsWith(u8, target_value, "${HEXE_")) {
            // Allow runtime env expansion for hexe-provided dynamic targets.
            if (!appendBridgeCommandChunk(&cmd, target_value, "failed to append record command dynamic target")) return null;
        } else {
            const qtarget = shellQuote(allocator, target_value) catch |err| {
                log.warn("failed to quote record target value: {}", .{err});
                return null;
            };
            defer allocator.free(qtarget);
            if (!appendBridgeCommandChunk(&cmd, qtarget, "failed to append record command target value")) return null;
        }
    }
    if ((action == .start or action == .toggle) and capture_input) {
        if (!appendBridgeCommandChunk(&cmd, " --capture-input", "failed to append record command capture flag")) return null;
    }
    return cmd.toOwnedSlice() catch |err| {
        log.warn("failed to finalize API bridge record command: {}", .{err});
        return null;
    };
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
        std.fs.cwd().deleteFile(state_path) catch |err| {
            if (err != error.FileNotFound) log.warn("record.status: failed to delete stale state file '{s}': {}", .{ state_path, err });
        };
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
