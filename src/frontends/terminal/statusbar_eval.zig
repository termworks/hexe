//! Frontend-neutral Lua-evaluation primitives for the statusbar: snippet vs.
//! registered-callback dispatch (`beginLuaEval`/`endLuaEval`), the
//! `__hexe_cb_ref:` callback-id decoding, and the `HEXE_LUA_TRACE` tracing
//! helpers. These touch only a `*LuaRuntime` and the environment — no terminal
//! `State`/`Pane`/vaxis — so they are the cleanly separable core of the eval
//! path (PLAN.md 2.3). The condition/command evaluators and their per-frame
//! caches stay in `statusbar.zig` because they are anchored to
//! `populateLuaContext`, which is terminal-specific.
//!
//! Re-exported from `statusbar.zig` via file-level `const` aliases so its bare
//! call sites are unchanged.

const std = @import("std");
const core = @import("core");

const LuaRuntime = core.LuaRuntime;
const log = std.log.scoped(.terminal_statusbar);

pub const CALLBACK_REF_PREFIX = "__hexe_cb_ref:";

pub const LuaTraceMode = enum { off, all, slow };

pub fn parseLuaTraceMode() LuaTraceMode {
    const v = std.posix.getenv("HEXE_LUA_TRACE") orelse return .off;
    if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "all")) return .all;
    if (std.mem.eql(u8, v, "slow")) return .slow;
    return .off;
}

pub fn luaTraceSlowMs() i64 {
    const raw = std.posix.getenv("HEXE_LUA_TRACE_SLOW_MS") orelse return 8;
    return std.fmt.parseInt(i64, raw, 10) catch 8;
}

pub fn traceLuaEval(scope: []const u8, code: []const u8, ok: bool, start_ms: i64) void {
    const mode = parseLuaTraceMode();
    if (mode == .off) return;
    const elapsed = std.time.milliTimestamp() - start_ms;
    if (mode == .slow and elapsed < luaTraceSlowMs()) return;
    const code_hint = if (callbackIdFromCode(code) != null) code else "<chunk>";
    std.debug.print("[hexe-lua:{s}] ok={s} elapsed_ms={d} code={s}\n", .{ scope, if (ok) "true" else "false", elapsed, code_hint });
}

pub fn callbackIdFromCode(code: []const u8) ?i32 {
    if (!std.mem.startsWith(u8, code, CALLBACK_REF_PREFIX)) return null;
    return std.fmt.parseInt(i32, code[CALLBACK_REF_PREFIX.len..], 10) catch |err| {
        log.warn("failed to parse statusbar callback id: {}", .{err});
        return null;
    };
}

pub const LuaEvalMode = enum { chunk, callback };

pub fn beginLuaEval(rt: *LuaRuntime, code: []const u8) ?LuaEvalMode {
    if (callbackIdFromCode(code)) |cid| {
        if (!core.lua_runtime.pushRegisteredCallback(rt, cid)) return null;
        _ = rt.lua.getGlobal("ctx") catch {
            rt.lua.pop(2);
            return null;
        };
        rt.lua.protectedCall(.{ .args = 1, .results = 1 }) catch {
            rt.lua.pop(2);
            return null;
        };
        return .callback;
    }

    const code_z = rt.allocator.dupeZ(u8, code) catch |err| {
        core.logging.logError("terminal", "failed to allocate statusbar Lua snippet", err);
        return null;
    };
    defer rt.allocator.free(code_z);

    rt.lua.loadString(code_z) catch |err| {
        core.logging.logError("terminal", "failed to load statusbar Lua snippet", err);
        return null;
    };
    rt.lua.protectedCall(.{ .args = 0, .results = 1 }) catch {
        rt.lua.pop(1);
        return null;
    };
    return .chunk;
}

pub fn endLuaEval(rt: *LuaRuntime, mode: LuaEvalMode) void {
    rt.lua.pop(1);
    if (mode == .callback) rt.lua.pop(1);
}
