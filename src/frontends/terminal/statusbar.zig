const std = @import("std");
const core = @import("core");
const shp = @import("shp");
const vaxis = @import("vaxis");
const animations = core.segments.animations;
const randomdo_mod = core.segments.randomdo;

const LuaRuntime = core.LuaRuntime;

const State = @import("state.zig").State;
const Renderer = @import("render_core.zig").Renderer;
const lua_events = @import("lua_events.zig");
const Color = core.style.Color;
const Pane = @import("pane.zig").Pane;
const segment_render = core.segment_render;
const DEFAULT_OUTPUTS = [_]core.config.OutputDef{.{ .style = "", .format = "$output" }};
const CALLBACK_REF_PREFIX = "__hexe_cb_ref:";

const LuaTraceMode = enum { off, all, slow };

fn parseLuaTraceMode() LuaTraceMode {
    const v = std.posix.getenv("HEXE_LUA_TRACE") orelse return .off;
    if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "all")) return .all;
    if (std.mem.eql(u8, v, "slow")) return .slow;
    return .off;
}

fn luaTraceSlowMs() i64 {
    const raw = std.posix.getenv("HEXE_LUA_TRACE_SLOW_MS") orelse return 8;
    return std.fmt.parseInt(i64, raw, 10) catch 8;
}

fn traceLuaEval(scope: []const u8, code: []const u8, ok: bool, start_ms: i64) void {
    const mode = parseLuaTraceMode();
    if (mode == .off) return;
    const elapsed = std.time.milliTimestamp() - start_ms;
    if (mode == .slow and elapsed < luaTraceSlowMs()) return;
    const code_hint = if (callbackIdFromCode(code) != null) code else "<chunk>";
    std.debug.print("[hexe-lua:{s}] ok={s} elapsed_ms={d} code={s}\n", .{ scope, if (ok) "true" else "false", elapsed, code_hint });
}

fn callbackIdFromCode(code: []const u8) ?i32 {
    if (!std.mem.startsWith(u8, code, CALLBACK_REF_PREFIX)) return null;
    return std.fmt.parseInt(i32, code[CALLBACK_REF_PREFIX.len..], 10) catch null;
}

const LuaEvalMode = enum { chunk, callback };

fn beginLuaEval(rt: *LuaRuntime, code: []const u8) ?LuaEvalMode {
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

    const code_z = rt.allocator.dupeZ(u8, code) catch return null;
    defer rt.allocator.free(code_z);

    rt.lua.loadString(code_z) catch return null;
    rt.lua.protectedCall(.{ .args = 0, .results = 1 }) catch {
        rt.lua.pop(1);
        return null;
    };
    return .chunk;
}

fn endLuaEval(rt: *LuaRuntime, mode: LuaEvalMode) void {
    rt.lua.pop(1);
    if (mode == .callback) rt.lua.pop(1);
}

const WhenCacheEntry = struct {
    last_eval_ms: u64,
    last_result: bool,
};

threadlocal var when_bash_cache: ?std.AutoHashMap(usize, WhenCacheEntry) = null;
threadlocal var when_lua_cache: ?std.AutoHashMap(usize, WhenCacheEntry) = null;
threadlocal var when_lua_rt: ?LuaRuntime = null;
threadlocal var callback_lua_rt: ?*LuaRuntime = null;
threadlocal var callback_state: ?*State = null;
threadlocal var last_focused_pane_uuid: ?[32]u8 = null;

const RandomdoState = struct {
    active: bool,
    idx: u16,
};

threadlocal var randomdo_state: ?std.AutoHashMap(usize, RandomdoState) = null;
threadlocal var button_click_state: ?std.AutoHashMap(usize, u8) = null;
const ProgressCacheEntry = struct {
    last_eval_ms: u64,
    text: [256]u8,
    len: usize,
};
threadlocal var progress_text_cache: ?std.AutoHashMap(usize, ProgressCacheEntry) = null;
threadlocal var hover_x: ?u16 = null;
threadlocal var hover_y: ?u16 = null;
threadlocal var statusbar_redraw_last_emit_ms: ?u64 = null;
threadlocal var click_command_buf: [1024]u8 = [_]u8{0} ** 1024;
threadlocal var eval_cache_ctx_ptr: usize = 0;
threadlocal var eval_cache_frame_ms: u64 = 0;
threadlocal var eval_cache_ready: bool = false;

fn tabTitleForDisplay(state: *State, tab_idx: usize, tab: anytype, use_basename: bool) []const u8 {
    if (use_basename) {
        if (tab.layout.getFocusedPane()) |pane| {
            if (state.paneRealCwd(pane)) |p| {
                const base = std.fs.path.basename(p);
                return if (base.len == 0) "/" else base;
            }
        }
    }
    return state.runtime.tabName(tab_idx) orelse "tab";
}

pub fn beginExternalCallbackEval(state: *State, lua_rt: ?*LuaRuntime) void {
    callback_state = state;
    callback_lua_rt = lua_rt;
}

pub fn endExternalCallbackEval() void {
    callback_state = null;
    callback_lua_rt = null;
}

fn statusbarRedrawEventIntervalMs() u64 {
    const raw = std.posix.getenv("HEXE_STATUSBAR_REDRAW_EVENT_MS") orelse return 120;
    return std.fmt.parseInt(u64, raw, 10) catch 120;
}

fn emitStatusbarRedrawEventIfDue(state: *State, ctx: *const shp.Context, term_width: u16, term_height: u16, active_tab: usize) void {
    const rt = state.config._lua_runtime orelse return;
    const interval_ms = statusbarRedrawEventIntervalMs();
    if (statusbar_redraw_last_emit_ms) |last| {
        if (ctx.now_ms >= last and (ctx.now_ms - last) < interval_ms) return;
    }
    statusbar_redraw_last_emit_ms = ctx.now_ms;

    rt.lua.createTable(0, 12);
    _ = rt.lua.pushString("statusbar_redraw");
    rt.lua.setField(-2, "event");
    rt.lua.pushInteger(@intCast(ctx.now_ms));
    rt.lua.setField(-2, "now_ms");
    rt.lua.pushInteger(term_width);
    rt.lua.setField(-2, "term_width");
    rt.lua.pushInteger(term_height);
    rt.lua.setField(-2, "term_height");
    rt.lua.pushInteger(@intCast(active_tab + 1));
    rt.lua.setField(-2, "active_tab");
    rt.lua.pushInteger(ctx.tab_count);
    rt.lua.setField(-2, "tab_count");
    rt.lua.pushBoolean(ctx.focus_is_float);
    rt.lua.setField(-2, "focus_float");
    rt.lua.pushBoolean(ctx.focus_is_split);
    rt.lua.setField(-2, "focus_split");
    rt.lua.pushBoolean(ctx.shell_running);
    rt.lua.setField(-2, "shell_running");
    rt.lua.pushInteger(@intCast(interval_ms));
    rt.lua.setField(-2, "interval_ms");

    lua_events.emitAutocmdWithPayloadOnStack(rt, "statusbar_redraw");
}

fn builtinNameFromMarker(s: []const u8) ?[]const u8 {
    return segment_render.builtinNameFromMarker(s);
}

pub fn updateHover(term_height: u16, x: u16, y: u16) bool {
    const old_x = hover_x;
    const old_y = hover_y;
    hover_x = x;
    hover_y = y;

    if (old_x == hover_x and old_y == hover_y) return false;
    if (term_height == 0) return false;
    const bar_y = term_height - 1;
    const was_on_bar = old_y != null and old_y.? == bar_y;
    const is_on_bar = y == bar_y;
    return was_on_bar or is_on_bar;
}

fn isClickable(mod: *const core.Segment) bool {
    if (mod.kind != .button) return false;
    return mod.on_click != null or mod.on_right_click != null or mod.on_middle_click != null;
}

fn isButtonActive(mod: *const core.Segment, ctx: *shp.Context) bool {
    if (mod.button_active_bash) |code| {
        if (callbackIdFromCode(code) != null) {
            return evalLuaWhen(code, ctx, 150);
        }
        return evalBashWhen(code, ctx, 300);
    }
    return false;
}

fn isHoveredRange(start_x: u16, width: u16, y: u16) bool {
    if (hover_x == null or hover_y == null) return false;
    const hx = hover_x.?;
    const hy = hover_y.?;
    return hy == y and hx >= start_x and hx < start_x +| width;
}

fn spinnerAsciiFrame(now_ms: u64, started_at_ms: u64, step_ms: u64) []const u8 {
    const frames = [_][]const u8{ "|", "/", "-", "\\" };
    const step: u64 = if (step_ms == 0) 100 else step_ms;
    const tick = (now_ms - started_at_ms) / step;
    return frames[@intCast(tick % frames.len)];
}

/// Clean up all threadlocal resources. Call this on MUX shutdown.
pub fn deinitThreadlocals() void {
    // Deinit when_bash_cache if it was initialized
    if (when_bash_cache) |*cache| {
        cache.deinit();
        when_bash_cache = null;
    }

    // Deinit when_lua_cache if it was initialized
    if (when_lua_cache) |*cache| {
        cache.deinit();
        when_lua_cache = null;
    }

    // Deinit when_lua_rt if it was initialized
    if (when_lua_rt) |*rt| {
        rt.deinit();
        when_lua_rt = null;
    }

    // Deinit randomdo_state if it was initialized
    if (randomdo_state) |*state| {
        state.deinit();
        randomdo_state = null;
    }

    if (button_click_state) |*state| {
        state.deinit();
        button_click_state = null;
    }

    if (progress_text_cache) |*cache| {
        cache.deinit();
        progress_text_cache = null;
    }

    if (command_eval_cache) |*cache| {
        cache.deinit();
        command_eval_cache = null;
    }

    if (builtin_desc_cache) |*cache| {
        cache.deinit();
        builtin_desc_cache = null;
    }

    eval_cache_ctx_ptr = 0;
    eval_cache_frame_ms = 0;
    eval_cache_ready = false;
}

fn getProgressTextCache() *std.AutoHashMap(usize, ProgressCacheEntry) {
    if (progress_text_cache == null) {
        progress_text_cache = std.AutoHashMap(usize, ProgressCacheEntry).init(std.heap.page_allocator);
    }
    return &progress_text_cache.?;
}

fn progressKey(mod: *const core.config.Segment) usize {
    return (@intFromPtr(mod.name.ptr) << 1) ^ @as(usize, mod.priority) ^ @as(usize, @intFromEnum(mod.kind));
}

fn getRandomdoStateMap() *std.AutoHashMap(usize, RandomdoState) {
    if (randomdo_state == null) {
        randomdo_state = std.AutoHashMap(usize, RandomdoState).init(std.heap.page_allocator);
    }
    return &randomdo_state.?;
}

fn getButtonClickStateMap() *std.AutoHashMap(usize, u8) {
    if (button_click_state == null) {
        button_click_state = std.AutoHashMap(usize, u8).init(std.heap.page_allocator);
    }
    return &button_click_state.?;
}

fn moduleKey(mod: *const core.Segment) usize {
    return @intFromPtr(mod);
}

fn clickedButtonFor(mod: *const core.Segment) ?u8 {
    if (button_click_state == null) return null;
    return button_click_state.?.get(moduleKey(mod));
}

fn toggleClickedButton(mod: *const core.Segment, button: u8) void {
    if (!isClickable(mod)) return;
    if (button > 2) return;
    const key = moduleKey(mod);
    const map = getButtonClickStateMap();
    if (map.get(key)) |current| {
        if (current == button) {
            _ = map.remove(key);
        } else {
            _ = map.remove(key);
        }
        return;
    }
    map.put(key, button) catch {};
}

fn clickedButtonStyle(mod: *const core.Segment, clicked_button: u8) ?shp.Style {
    const style_str = switch (clicked_button) {
        0 => mod.button_left_style,
        1 => mod.button_middle_style,
        2 => mod.button_right_style,
        else => null,
    } orelse return null;
    if (style_str.len == 0) return null;
    return shp.Style.parse(style_str);
}

fn randomdoKey(mod: *const core.config.Segment) usize {
    return (@intFromPtr(mod.outputs.ptr) << 1) ^ @as(usize, mod.priority) ^ mod.name.len;
}

fn randomdoTextFor(ctx: *shp.Context, mod: *const core.config.Segment, visible: bool) []const u8 {
    const key = randomdoKey(mod);
    const map = getRandomdoStateMap();

    if (!visible) {
        if (map.getPtr(key)) |st| st.active = false;
        return "";
    }

    var entry = map.getPtr(key);
    if (entry == null) {
        map.put(key, .{ .active = false, .idx = 0 }) catch {};
        entry = map.getPtr(key);
    }
    if (entry) |st| {
        if (!st.active) {
            const idx = randomdo_mod.chooseIndex(ctx.now_ms, ctx.cwd);
            st.idx = @intCast(idx);
            st.active = true;
        }
        return randomdo_mod.WORDS[@min(@as(usize, st.idx), randomdo_mod.WORDS.len - 1)];
    }
    return "";
}

fn whenKey(s: []const u8) usize {
    return (@intFromPtr(s.ptr) << 1) ^ s.len;
}

fn getWhenCache(map_ptr: *?std.AutoHashMap(usize, WhenCacheEntry)) *std.AutoHashMap(usize, WhenCacheEntry) {
    if (map_ptr.* == null) {
        map_ptr.* = std.AutoHashMap(usize, WhenCacheEntry).init(std.heap.page_allocator);
    }
    return &map_ptr.*.?;
}

/// Build a PaneQuery from the populated rendering context.
pub fn queryFromContext(ctx: *const shp.Context) core.PaneQuery {
    return .{
        .is_float = ctx.focus_is_float,
        .is_split = ctx.focus_is_split,
        .float_key = ctx.float_key,
        .float_sticky = ctx.float_sticky,
        .float_exclusive = ctx.float_exclusive,
        .float_per_cwd = ctx.float_per_cwd,
        .float_global = ctx.float_global,
        .float_isolated = ctx.float_isolated,
        .float_destroyable = ctx.float_destroyable,
        .tab_count = ctx.tab_count,
        .active_tab = @intCast(ctx.active_tab),
        .alt_screen = ctx.alt_screen,
        .cwd = if (ctx.cwd.len > 0) ctx.cwd else null,
        .last_command = ctx.last_command,
        .exit_status = ctx.exit_status,
        .cmd_duration_ms = ctx.cmd_duration_ms,
        .jobs = ctx.jobs,
        .shell_running = ctx.shell_running,
        .shell_running_cmd = ctx.shell_running_cmd,
        .shell_started_at_ms = ctx.shell_started_at_ms,
        .session_name = ctx.session_name,
        .now_ms = ctx.now_ms,
    };
}

/// Get bash condition timeout in milliseconds from environment or use default.
/// Default is 100ms, configurable via HEXE_CONDITION_TIMEOUT.
fn getConditionTimeout() u32 {
    if (std.posix.getenv("HEXE_CONDITION_TIMEOUT")) |timeout_str| {
        const timeout = std.fmt.parseInt(u32, timeout_str, 10) catch 100;
        // Clamp to reasonable range: 10ms to 5000ms
        return @min(@max(timeout, 10), 5000);
    }
    return 100; // Default: 100ms
}

fn evalBashWhen(code: []const u8, ctx: *shp.Context, ttl_ms: u64) bool {
    const now = ctx.now_ms;
    const key = whenKey(code);
    const map = getWhenCache(&when_bash_cache);
    if (map.get(key)) |e| {
        if (now - e.last_eval_ms < ttl_ms) return e.last_result;
    }

    // Export a few useful ctx vars.
    var env_map = std.process.EnvMap.init(std.heap.page_allocator);
    defer env_map.deinit();
    env_map.put("HEXE_STATUS_PROCESS_RUNNING", if (ctx.shell_running) "1" else "0") catch {};
    env_map.put("HEXE_STATUS_ALT_SCREEN", if (ctx.alt_screen) "1" else "0") catch {};
    if (ctx.last_command) |c| env_map.put("HEXE_STATUS_LAST_CMD", c) catch {};
    if (ctx.cwd.len > 0) env_map.put("HEXE_STATUS_CWD", ctx.cwd) catch {};

    // Spawn process with timeout support
    var child = std.process.Child.init(&.{ "/bin/bash", "-c", code }, std.heap.page_allocator);
    child.env_map = &env_map;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch {
        map.put(key, .{ .last_eval_ms = now, .last_result = false }) catch {};
        return false;
    };

    // Wait for process with timeout using non-blocking waitpid polling.
    const timeout_ms = getConditionTimeout();
    const start_ms = std.time.milliTimestamp();

    while (std.time.milliTimestamp() - start_ms < timeout_ms) {
        const wait_res = std.posix.waitpid(child.id, std.posix.W.NOHANG);
        if (wait_res.pid == child.id) {
            child.id = undefined;
            const ok = std.posix.W.IFEXITED(wait_res.status) and std.posix.W.EXITSTATUS(wait_res.status) == 0;
            map.put(key, .{ .last_eval_ms = now, .last_result = ok }) catch {};
            return ok;
        }

        std.Thread.sleep(5 * std.time.ns_per_ms); // Sleep 5ms between checks
    }

    // Timeout - kill the process
    _ = child.kill() catch {};
    map.put(key, .{ .last_eval_ms = now, .last_result = false }) catch {};
    return false;
}

fn pushPaneLuaTable(rt: *LuaRuntime, state: *State, pane: *Pane, is_focused: bool, tab_index: usize, pane_index: usize) void {
    rt.lua.createTable(0, 24);

    _ = rt.lua.pushString(pane.uuid[0..]);
    rt.lua.setField(-2, "uuid");
    rt.lua.pushInteger(pane.id);
    rt.lua.setField(-2, "id");
    rt.lua.pushInteger(@intCast(tab_index));
    rt.lua.setField(-2, "tab_index");
    rt.lua.pushInteger(@intCast(pane_index));
    rt.lua.setField(-2, "pane_index");

    rt.lua.pushBoolean(is_focused);
    rt.lua.setField(-2, "focused");
    rt.lua.pushBoolean(!state.paneIsFloating(pane));
    rt.lua.setField(-2, "focus_split");
    rt.lua.pushBoolean(state.paneIsFloating(pane));
    rt.lua.setField(-2, "focus_float");
    rt.lua.pushBoolean(!state.paneIsFloating(pane));
    rt.lua.setField(-2, "is_split");
    rt.lua.pushBoolean(state.paneIsFloating(pane));
    rt.lua.setField(-2, "is_float");
    rt.lua.pushBoolean(state.paneIsFloating(pane));
    rt.lua.setField(-2, "floating");

    const float_key = state.paneFloatKey(pane);
    rt.lua.pushInteger(float_key);
    rt.lua.setField(-2, "float_key");
    rt.lua.pushBoolean(state.paneSticky(pane));
    rt.lua.setField(-2, "float_sticky");

    var float_exclusive = false;
    var float_per_cwd = false;
    var float_global = state.paneParentTab(pane) == null;
    var float_isolated = false;
    var float_destroyable = false;
    if (float_key != 0) {
        if (state.getLayoutFloatByKey(float_key)) |fd| {
            float_destroyable = fd.attributes.destroy;
            float_exclusive = fd.attributes.exclusive;
            float_per_cwd = fd.attributes.per_cwd;
            float_isolated = fd.attributes.isolated;
            float_global = float_global or fd.attributes.global;
        }
    }
    rt.lua.pushBoolean(float_destroyable);
    rt.lua.setField(-2, "float_destroyable");
    rt.lua.pushBoolean(float_exclusive);
    rt.lua.setField(-2, "float_exclusive");
    rt.lua.pushBoolean(float_per_cwd);
    rt.lua.setField(-2, "float_per_cwd");
    rt.lua.pushBoolean(float_global);
    rt.lua.setField(-2, "float_global");
    rt.lua.pushBoolean(float_isolated);
    rt.lua.setField(-2, "float_isolated");

    const alt_screen = pane.vt.inAltScreen();
    rt.lua.pushBoolean(alt_screen);
    rt.lua.setField(-2, "alt_screen");

    if (state.getPaneProc(pane.uuid)) |proc_info| {
        if (proc_info.name) |name| {
            _ = rt.lua.pushString(name);
            rt.lua.setField(-2, "process_name");
            _ = rt.lua.pushString(name);
            rt.lua.setField(-2, "fg_process");
            rt.lua.pushBoolean(true);
            rt.lua.setField(-2, "process_running");
        }
        if (proc_info.pid) |pid| {
            rt.lua.pushInteger(pid);
            rt.lua.setField(-2, "fg_pid");
        }
    } else {
        rt.lua.pushBoolean(false);
        rt.lua.setField(-2, "process_running");
    }

    if (state.getPaneShell(pane.uuid)) |shell_info| {
        if (shell_info.cwd) |cwd| {
            _ = rt.lua.pushString(cwd);
            rt.lua.setField(-2, "cwd");
        }
        if (shell_info.cmd) |cmd| {
            _ = rt.lua.pushString(cmd);
            rt.lua.setField(-2, "last_command");
        }
        rt.lua.pushBoolean(shell_info.running);
        rt.lua.setField(-2, "shell_running");
    }
}

fn appendPaneApiEntry(rt: *LuaRuntime, state: *State, pane: *Pane, is_focused: bool, tab_index: usize, pane_index: usize, tab_focus_slot: ?usize) void {
    pushPaneLuaTable(rt, state, pane, is_focused, tab_index, pane_index);

    rt.lua.pushValue(-1);
    rt.lua.rawSetIndex(-5, @intCast(pane_index));

    _ = rt.lua.pushString(pane.uuid[0..]);
    rt.lua.pushValue(-2);
    rt.lua.setTable(-5);

    if (tab_focus_slot) |slot| {
        rt.lua.pushValue(-1);
        rt.lua.rawSetIndex(-3, @intCast(slot));
    }

    if (is_focused) {
        rt.lua.pushValue(-1);
        rt.lua.setGlobal("__hexe_when_pane0");
    }

    rt.lua.pop(1);
}

fn populateLuaContext(rt: *LuaRuntime, ctx: *shp.Context) void {
    rt.lua.createTable(0, 20);

    rt.lua.pushBoolean(ctx.shell_running);
    rt.lua.setField(-2, "shell_running");
    rt.lua.pushBoolean(ctx.shell_running);
    rt.lua.setField(-2, "process_running");
    rt.lua.pushBoolean(ctx.alt_screen);
    rt.lua.setField(-2, "alt_screen");
    rt.lua.pushBoolean(!ctx.alt_screen);
    rt.lua.setField(-2, "not_alt_screen");
    rt.lua.pushBoolean(ctx.focus_is_float);
    rt.lua.setField(-2, "focus_is_float");
    rt.lua.pushBoolean(ctx.focus_is_float);
    rt.lua.setField(-2, "focus_float");
    rt.lua.pushBoolean(ctx.focus_is_split);
    rt.lua.setField(-2, "focus_split");
    rt.lua.pushInteger(ctx.float_key);
    rt.lua.setField(-2, "float_key");
    rt.lua.pushBoolean(ctx.focus_is_float and ctx.float_key == 0);
    rt.lua.setField(-2, "adhoc_float");

    _ = rt.lua.pushString(ctx.cwd);
    rt.lua.setField(-2, "cwd");
    if (ctx.home) |home| {
        _ = rt.lua.pushString(home);
        rt.lua.setField(-2, "home");
    }

    if (ctx.exit_status) |st| {
        rt.lua.pushInteger(st);
        rt.lua.setField(-2, "exit_status");
        rt.lua.pushInteger(st);
        rt.lua.setField(-2, "last_status");
    }
    if (ctx.last_command) |c| {
        _ = rt.lua.pushString(c);
        rt.lua.setField(-2, "last_command");
    }
    if (ctx.shell_running_cmd) |c| {
        _ = rt.lua.pushString(c);
        rt.lua.setField(-2, "process_name");
        _ = rt.lua.pushString(c);
        rt.lua.setField(-2, "fg_process");
    }
    if (ctx.cmd_duration_ms) |d| {
        rt.lua.pushInteger(@intCast(d));
        rt.lua.setField(-2, "cmd_duration_ms");
    }

    rt.lua.pushInteger(ctx.jobs);
    rt.lua.setField(-2, "jobs");
    rt.lua.pushInteger(ctx.terminal_width);
    rt.lua.setField(-2, "terminal_width");
    rt.lua.pushInteger(@intCast(ctx.now_ms));
    rt.lua.setField(-2, "now_ms");

    var env_map_opt = std.process.getEnvMap(rt.allocator) catch null;
    if (env_map_opt) |*env_map| {
        defer env_map.deinit();
        rt.lua.createTable(0, @intCast(env_map.count()));
        var it = env_map.iterator();
        while (it.next()) |entry| {
            _ = rt.lua.pushString(entry.key_ptr.*);
            _ = rt.lua.pushString(entry.value_ptr.*);
            rt.lua.setTable(-3);
        }
        rt.lua.setField(-2, "env");
    } else {
        rt.lua.createTable(0, 0);
        rt.lua.setField(-2, "env");
    }

    // Build pane lookup maps: numeric index, uuid, and tab focus.
    rt.lua.createTable(0, 64); // index map (1-based)
    rt.lua.createTable(0, 64); // uuid map
    rt.lua.createTable(0, 32); // tab:N/focus map (1-based tabs)

    rt.lua.pushValue(-3);
    rt.lua.setGlobal("__hexe_when_pane0");

    const previous_focused_uuid = last_focused_pane_uuid;
    if (callback_state) |state| {
        const focused_uuid = state.getCurrentFocusedUuid();
        if (focused_uuid) |fu| {
            if (previous_focused_uuid == null or !std.mem.eql(u8, &previous_focused_uuid.?, &fu)) {
                last_focused_pane_uuid = fu;
            }
        }
        var pane_index: usize = 1;

        for (state.view.tab_views.items, 0..) |*tab, tab_idx| {
            const tab_focused_uuid = if (tab.layout.getFocusedPane()) |fp| fp.uuid else null;
            var pane_it = tab.layout.splitIterator();
            while (pane_it.next()) |pane| {
                const is_focused = if (focused_uuid) |fu|
                    std.mem.eql(u8, &pane.*.uuid, &fu)
                else
                    false;
                const tab_focus_slot: ?usize = if (tab_focused_uuid) |tfu|
                    if (std.mem.eql(u8, &pane.*.uuid, &tfu)) (tab_idx + 1) else null
                else
                    null;
                appendPaneApiEntry(rt, state, pane.*, is_focused, tab_idx, pane_index, tab_focus_slot);
                pane_index += 1;
            }
        }

        for (state.view.float_views.items) |pane| {
            const is_focused = if (focused_uuid) |fu|
                std.mem.eql(u8, &pane.uuid, &fu)
            else
                false;
            const tab_idx = state.paneParentTab(pane) orelse state.activeTabIndex();
            appendPaneApiEntry(rt, state, pane, is_focused, tab_idx, pane_index, null);
            pane_index += 1;
        }
    }

    rt.lua.pushValue(-3);
    rt.lua.setField(-5, "panes");

    rt.lua.pushValue(-2);
    rt.lua.setGlobal("__hexe_panes_by_uuid");
    rt.lua.pushValue(-3);
    rt.lua.setGlobal("__hexe_panes_by_index");
    rt.lua.pushValue(-1);
    rt.lua.setGlobal("__hexe_panes_by_tab_focus");

    if (previous_focused_uuid) |pu| {
        _ = rt.lua.pushString(pu[0..]);
        rt.lua.setGlobal("__hexe_last_pane_uuid");
    } else {
        rt.lua.pushNil();
        rt.lua.setGlobal("__hexe_last_pane_uuid");
    }

    rt.lua.pop(3);

    // Expose pragmatic pane API: ctx.pane(0)
    rt.lua.pushValue(-1);
    rt.lua.setGlobal("__hexe_when_pane0");
    rt.lua.pushValue(-1);
    rt.lua.setGlobal("ctx");

    const pane_api =
        "if type(ctx)=='table' then " ++
        "ctx.pane=function(id) " ++
        "if id==nil or id==0 then return __hexe_when_pane0 end " ++
        "local t=type(id); " ++
        "if t=='number' then return __hexe_panes_by_index[id] end; " ++
        "if t=='string' then " ++
        "if id=='focused' or id=='current' then return __hexe_when_pane0 end; " ++
        "if id=='last' and __hexe_last_pane_uuid then return __hexe_panes_by_uuid[__hexe_last_pane_uuid] end; " ++
        "local n=string.match(id,'^tab:(%d+)/focus$'); " ++
        "if n then return __hexe_panes_by_tab_focus[tonumber(n)] end; " ++
        "return __hexe_panes_by_uuid[id] end; " ++
        "return nil end; " ++
        "__hexe_ctx_cache=__hexe_ctx_cache or {}; " ++
        "ctx.cache = ctx.cache or {}; " ++
        "ctx.cache.get=function(key) " ++
        "local k=tostring(key); local e=__hexe_ctx_cache[k]; if not e then return nil end; " ++
        "local now=(ctx.now_ms or 0); if e.exp and e.exp < now then __hexe_ctx_cache[k]=nil; return nil end; " ++
        "return e.val end; " ++
        "ctx.cache.set=function(key,val,ttl_ms) " ++
        "local k=tostring(key); local exp=nil; " ++
        "if ttl_ms and type(ttl_ms)=='number' and ttl_ms>0 then exp=(ctx.now_ms or 0)+ttl_ms end; " ++
        "__hexe_ctx_cache[k]={ val=val, exp=exp }; return val end; " ++
        "ctx.cache.del=function(key) __hexe_ctx_cache[tostring(key)]=nil end; " ++
        "ctx.status = ctx.pane(0); " ++
        "end; " ++
        "if type(hexe)=='table' then " ++
        "hexe.status=hexe.status or {}; " ++
        "hexe.status.pane=ctx.pane; " ++
        "end";
    const pane_api_z = rt.allocator.dupeZ(u8, pane_api) catch {
        rt.lua.setGlobal("ctx");
        return;
    };
    defer rt.allocator.free(pane_api_z);
    rt.lua.loadString(pane_api_z) catch {
        rt.lua.setGlobal("ctx");
        return;
    };
    rt.lua.protectedCall(.{ .args = 0, .results = 0 }) catch {
        rt.lua.pop(1);
        rt.lua.setGlobal("ctx");
        return;
    };

    rt.lua.setGlobal("ctx");
}

fn evalLuaWhen(code: []const u8, ctx: *shp.Context, ttl_ms: u64) bool {
    const trace_start_ms = std.time.milliTimestamp();
    const now = ctx.now_ms;
    const key = whenKey(code);
    const map = getWhenCache(&when_lua_cache);
    if (map.get(key)) |e| {
        if (now - e.last_eval_ms < ttl_ms) return e.last_result;
    }

    var rt: *LuaRuntime = undefined;
    if (callback_lua_rt) |cb| {
        rt = cb;
    } else {
        if (when_lua_rt == null) {
            when_lua_rt = LuaRuntime.init(std.heap.page_allocator) catch null;
            if (when_lua_rt == null) {
                map.put(key, .{ .last_eval_ms = now, .last_result = false }) catch {};
                return false;
            }
        }
        rt = &when_lua_rt.?;
    }

    populateLuaContext(rt, ctx);

    const mode = beginLuaEval(rt, code) orelse {
        traceLuaEval("statusbar.when", code, false, trace_start_ms);
        map.put(key, .{ .last_eval_ms = now, .last_result = false }) catch {};
        return false;
    };
    defer endLuaEval(rt, mode);

    const ok = switch (rt.lua.typeOf(-1)) {
        .boolean => rt.lua.toBoolean(-1),
        .number => (rt.lua.toNumber(-1) catch 0) != 0,
        .string => (rt.lua.toString(-1) catch "").len > 0,
        else => false,
    };
    traceLuaEval("statusbar.when", code, true, trace_start_ms);
    map.put(key, .{ .last_eval_ms = now, .last_result = ok }) catch {};
    return ok;
}

fn progressVisible(mod: *const core.config.Segment, ctx: *shp.Context) bool {
    if (mod.progress_show_when) |expr| {
        return evalLuaWhen(expr, ctx, 150);
    }
    return true;
}

const LuaEval = struct {
    text: [256]u8 = [_]u8{0} ** 256,
    text_len: usize = 0,
    seg_text: [16][64]u8 = [_][64]u8{[_]u8{0} ** 64} ** 16,
    seg_style: [16]shp.Style = [_]shp.Style{.{}} ** 16,
    seg_text_len: [16]usize = [_]usize{0} ** 16,
    seg_count: usize = 0,

    fn textSlice(self: *const LuaEval) []const u8 {
        return self.text[0..self.text_len];
    }

    fn segSlice(self: *const LuaEval, into: *[16]shp.Segment) ?[]const shp.Segment {
        if (self.seg_count == 0) return null;
        var i: usize = 0;
        while (i < self.seg_count and i < into.len) : (i += 1) {
            const n = self.seg_text_len[i];
            into[i] = .{
                .text = self.seg_text[i][0..n],
                .style = self.seg_style[i],
            };
        }
        return into[0..@min(self.seg_count, into.len)];
    }
};

const LuaEvalCacheEntry = struct {
    eval: LuaEval,
};

threadlocal var command_eval_cache: ?std.AutoHashMap(usize, LuaEvalCacheEntry) = null;

fn getCommandEvalCache() *std.AutoHashMap(usize, LuaEvalCacheEntry) {
    if (command_eval_cache == null) {
        command_eval_cache = std.AutoHashMap(usize, LuaEvalCacheEntry).init(std.heap.page_allocator);
    }
    return &command_eval_cache.?;
}

fn resetFrameEvalCachesIfNeeded(ctx: *shp.Context) void {
    const ctx_ptr = @intFromPtr(ctx);
    if (eval_cache_ready and eval_cache_ctx_ptr == ctx_ptr and eval_cache_frame_ms == ctx.now_ms) return;

    eval_cache_ctx_ptr = ctx_ptr;
    eval_cache_frame_ms = ctx.now_ms;
    eval_cache_ready = true;

    if (command_eval_cache) |*cache| cache.clearRetainingCapacity();
    if (builtin_desc_cache) |*cache| cache.clearRetainingCapacity();
}

fn evalLuaCommandCached(code: []const u8, ctx: *shp.Context) LuaEval {
    resetFrameEvalCachesIfNeeded(ctx);
    const key = whenKey(code);
    const cache = getCommandEvalCache();
    if (cache.get(key)) |entry| return entry.eval;

    const eval = evalLuaCommand(code, ctx);
    cache.put(key, .{ .eval = eval }) catch {};
    return eval;
}

fn evalLuaCommand(code: []const u8, ctx: *shp.Context) LuaEval {
    var out: LuaEval = .{};
    const trace_start_ms = std.time.milliTimestamp();
    var rt: *LuaRuntime = undefined;
    if (callback_lua_rt) |cb| {
        rt = cb;
    } else {
        if (when_lua_rt == null) {
            when_lua_rt = LuaRuntime.init(std.heap.page_allocator) catch null;
            if (when_lua_rt == null) return out;
        }
        rt = &when_lua_rt.?;
    }
    populateLuaContext(rt, ctx);
    const mode = beginLuaEval(rt, code) orelse {
        traceLuaEval("statusbar.value", code, false, trace_start_ms);
        return out;
    };
    defer endLuaEval(rt, mode);
    defer traceLuaEval("statusbar.value", code, true, trace_start_ms);

    switch (rt.lua.typeOf(-1)) {
        .string => {
            const s = rt.lua.toString(-1) catch return out;
            const n = @min(s.len, out.text.len);
            @memcpy(out.text[0..n], s[0..n]);
            out.text_len = n;
            return out;
        },
        .number => {
            const n = rt.lua.toNumber(-1) catch return out;
            const rendered = std.fmt.bufPrint(out.text[0..], "{d}", .{n}) catch "";
            out.text_len = rendered.len;
            return out;
        },
        .boolean => {
            if (rt.lua.toBoolean(-1)) {
                @memcpy(out.text[0..4], "true");
                out.text_len = 4;
            }
            return out;
        },
        .table => {
            const len: i32 = @intCast(@min(rt.lua.rawLen(-1), out.seg_text.len));
            var i: i32 = 1;
            while (i <= len) : (i += 1) {
                _ = rt.lua.rawGetIndex(-1, i);
                defer rt.lua.pop(1);
                if (rt.lua.typeOf(-1) != .table) continue;

                _ = rt.lua.getField(-1, "text");
                if (rt.lua.typeOf(-1) != .string) {
                    rt.lua.pop(1);
                    continue;
                }
                const txt = rt.lua.toString(-1) catch {
                    rt.lua.pop(1);
                    continue;
                };
                rt.lua.pop(1);

                if (txt.len == 0 or out.seg_count >= out.seg_text.len) continue;
                const bi = out.seg_count;
                const tn = @min(txt.len, out.seg_text[bi].len);
                @memcpy(out.seg_text[bi][0..tn], txt[0..tn]);
                out.seg_text_len[bi] = tn;

                var style = shp.Style{};
                _ = rt.lua.getField(-1, "style");
                if (rt.lua.typeOf(-1) == .string) {
                    const ss = rt.lua.toString(-1) catch "";
                    style = shp.Style.parse(ss);
                }
                rt.lua.pop(1);

                _ = rt.lua.getField(-1, "fg");
                if (rt.lua.typeOf(-1) == .number) {
                    const fg = rt.lua.toInteger(-1) catch -1;
                    if (fg >= 0 and fg <= 255) style.fg = .{ .palette = @intCast(fg) };
                }
                rt.lua.pop(1);

                _ = rt.lua.getField(-1, "bg");
                if (rt.lua.typeOf(-1) == .number) {
                    const bg = rt.lua.toInteger(-1) catch -1;
                    if (bg >= 0 and bg <= 255) style.bg = .{ .palette = @intCast(bg) };
                }
                rt.lua.pop(1);

                _ = rt.lua.getField(-1, "bold");
                if (rt.lua.typeOf(-1) == .boolean) style.bold = rt.lua.toBoolean(-1);
                rt.lua.pop(1);

                _ = rt.lua.getField(-1, "italic");
                if (rt.lua.typeOf(-1) == .boolean) style.italic = rt.lua.toBoolean(-1);
                rt.lua.pop(1);

                out.seg_style[bi] = style;
                out.seg_count += 1;
            }
            return out;
        },
        else => return out,
    }
}

const BuiltinDesc = struct {
    name_buf: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    style: shp.Style = .{},
    prefix_buf: [32]u8 = [_]u8{0} ** 32,
    prefix_len: usize = 0,
    prefix_style: shp.Style = .{},
    suffix_buf: [32]u8 = [_]u8{0} ** 32,
    suffix_len: usize = 0,
    suffix_style: shp.Style = .{},
    spinner_kind_buf: [32]u8 = [_]u8{0} ** 32,
    spinner_kind_len: usize = 0,
    spinner_width: ?u8 = null,
    spinner_step_ms: ?u64 = null,
    spinner_hold_frames: ?u8 = null,
    spinner_bg: ?u8 = null,
    spinner_placeholder: ?u8 = null,
    spinner_colors_buf: [16]u8 = [_]u8{0} ** 16,
    spinner_colors_len: usize = 0,

    fn name(self: *const BuiltinDesc) ?[]const u8 {
        if (self.name_len == 0) return null;
        return self.name_buf[0..self.name_len];
    }

    fn prefix(self: *const BuiltinDesc) []const u8 {
        return self.prefix_buf[0..self.prefix_len];
    }

    fn suffix(self: *const BuiltinDesc) []const u8 {
        return self.suffix_buf[0..self.suffix_len];
    }

    fn prefixStyle(self: *const BuiltinDesc) shp.Style {
        return if (self.prefix_style.isEmpty()) self.style else self.prefix_style;
    }

    fn suffixStyle(self: *const BuiltinDesc) shp.Style {
        return if (self.suffix_style.isEmpty()) self.style else self.suffix_style;
    }

    fn spinnerKind(self: *const BuiltinDesc) ?[]const u8 {
        if (self.spinner_kind_len == 0) return null;
        return self.spinner_kind_buf[0..self.spinner_kind_len];
    }

    fn spinnerColors(self: *const BuiltinDesc) []const u8 {
        return self.spinner_colors_buf[0..self.spinner_colors_len];
    }
};

const BuiltinDescCacheEntry = struct {
    desc: BuiltinDesc,
};

threadlocal var builtin_desc_cache: ?std.AutoHashMap(usize, BuiltinDescCacheEntry) = null;

fn getBuiltinDescCache() *std.AutoHashMap(usize, BuiltinDescCacheEntry) {
    if (builtin_desc_cache == null) {
        builtin_desc_cache = std.AutoHashMap(usize, BuiltinDescCacheEntry).init(std.heap.page_allocator);
    }
    return &builtin_desc_cache.?;
}

fn evalLuaBuiltinDescCached(code: []const u8, ctx: *shp.Context) BuiltinDesc {
    resetFrameEvalCachesIfNeeded(ctx);
    const key = whenKey(code);
    const cache = getBuiltinDescCache();
    if (cache.get(key)) |entry| return entry.desc;

    const desc = evalLuaBuiltinDesc(code, ctx);
    cache.put(key, .{ .desc = desc }) catch {};
    return desc;
}

fn evalLuaBuiltinDesc(code: []const u8, ctx: *shp.Context) BuiltinDesc {
    var desc: BuiltinDesc = .{};
    const trace_start_ms = std.time.milliTimestamp();
    var rt: *LuaRuntime = undefined;
    if (callback_lua_rt) |cb| {
        rt = cb;
    } else {
        if (when_lua_rt == null) {
            when_lua_rt = LuaRuntime.init(std.heap.page_allocator) catch null;
            if (when_lua_rt == null) return desc;
        }
        rt = &when_lua_rt.?;
    }
    populateLuaContext(rt, ctx);
    const mode = beginLuaEval(rt, code) orelse {
        traceLuaEval("statusbar.builtin", code, false, trace_start_ms);
        return desc;
    };
    defer endLuaEval(rt, mode);
    defer traceLuaEval("statusbar.builtin", code, true, trace_start_ms);

    switch (rt.lua.typeOf(-1)) {
        .string => {
            const s = rt.lua.toString(-1) catch return desc;
            const t = std.mem.trim(u8, s, " \t\r\n");
            if (t.len > 0) {
                const n = @min(t.len, desc.name_buf.len);
                @memcpy(desc.name_buf[0..n], t[0..n]);
                desc.name_len = n;
            }
            return desc;
        },
        .table => {
            _ = rt.lua.getField(-1, "name");
            if (rt.lua.typeOf(-1) == .string) {
                const s = rt.lua.toString(-1) catch "";
                const t = std.mem.trim(u8, s, " \t\r\n");
                if (t.len > 0) {
                    const n = @min(t.len, desc.name_buf.len);
                    @memcpy(desc.name_buf[0..n], t[0..n]);
                    desc.name_len = n;
                }
            }
            rt.lua.pop(1);

            _ = rt.lua.getField(-1, "style");
            if (rt.lua.typeOf(-1) == .string) {
                const ss = rt.lua.toString(-1) catch "";
                desc.style = shp.Style.parse(ss);
            }
            rt.lua.pop(1);

            _ = rt.lua.getField(-1, "fg");
            if (rt.lua.typeOf(-1) == .number) {
                const fg = rt.lua.toInteger(-1) catch -1;
                if (fg >= 0 and fg <= 255) desc.style.fg = .{ .palette = @intCast(fg) };
            }
            rt.lua.pop(1);

            _ = rt.lua.getField(-1, "bg");
            if (rt.lua.typeOf(-1) == .number) {
                const bg = rt.lua.toInteger(-1) catch -1;
                if (bg >= 0 and bg <= 255) desc.style.bg = .{ .palette = @intCast(bg) };
            }
            rt.lua.pop(1);

            _ = rt.lua.getField(-1, "prefix");
            if (rt.lua.typeOf(-1) == .string) {
                const s = rt.lua.toString(-1) catch "";
                const n = @min(s.len, desc.prefix_buf.len);
                @memcpy(desc.prefix_buf[0..n], s[0..n]);
                desc.prefix_len = n;
            } else if (rt.lua.typeOf(-1) == .table) {
                _ = rt.lua.getField(-1, "output");
                if (rt.lua.typeOf(-1) == .string) {
                    const s = rt.lua.toString(-1) catch "";
                    const n = @min(s.len, desc.prefix_buf.len);
                    @memcpy(desc.prefix_buf[0..n], s[0..n]);
                    desc.prefix_len = n;
                } else if (rt.lua.typeOf(-1) != .nil) {
                    _ = rt.lua.pushString("builtin.prefix.output must be string");
                    rt.lua.raiseError();
                }
                rt.lua.pop(1);

                _ = rt.lua.getField(-1, "style");
                if (rt.lua.typeOf(-1) == .string) {
                    const s = rt.lua.toString(-1) catch "";
                    desc.prefix_style = shp.Style.parse(s);
                } else if (rt.lua.typeOf(-1) != .nil) {
                    _ = rt.lua.pushString("builtin.prefix.style must be string");
                    rt.lua.raiseError();
                }
                rt.lua.pop(1);
            }
            rt.lua.pop(1);

            _ = rt.lua.getField(-1, "suffix");
            if (rt.lua.typeOf(-1) == .string) {
                const s = rt.lua.toString(-1) catch "";
                const n = @min(s.len, desc.suffix_buf.len);
                @memcpy(desc.suffix_buf[0..n], s[0..n]);
                desc.suffix_len = n;
            } else if (rt.lua.typeOf(-1) == .table) {
                _ = rt.lua.getField(-1, "output");
                if (rt.lua.typeOf(-1) == .string) {
                    const s = rt.lua.toString(-1) catch "";
                    const n = @min(s.len, desc.suffix_buf.len);
                    @memcpy(desc.suffix_buf[0..n], s[0..n]);
                    desc.suffix_len = n;
                } else if (rt.lua.typeOf(-1) != .nil) {
                    _ = rt.lua.pushString("builtin.suffix.output must be string");
                    rt.lua.raiseError();
                }
                rt.lua.pop(1);

                _ = rt.lua.getField(-1, "style");
                if (rt.lua.typeOf(-1) == .string) {
                    const s = rt.lua.toString(-1) catch "";
                    desc.suffix_style = shp.Style.parse(s);
                } else if (rt.lua.typeOf(-1) != .nil) {
                    _ = rt.lua.pushString("builtin.suffix.style must be string");
                    rt.lua.raiseError();
                }
                rt.lua.pop(1);
            }
            rt.lua.pop(1);

            if (desc.suffix_len == 0 and desc.suffix_style.isEmpty()) {
                _ = rt.lua.getField(-1, "sufix");
                if (rt.lua.typeOf(-1) == .table) {
                    _ = rt.lua.getField(-1, "output");
                    if (rt.lua.typeOf(-1) == .string) {
                        const s = rt.lua.toString(-1) catch "";
                        const n = @min(s.len, desc.suffix_buf.len);
                        @memcpy(desc.suffix_buf[0..n], s[0..n]);
                        desc.suffix_len = n;
                    } else if (rt.lua.typeOf(-1) != .nil) {
                        _ = rt.lua.pushString("builtin.sufix.output must be string");
                        rt.lua.raiseError();
                    }
                    rt.lua.pop(1);

                    _ = rt.lua.getField(-1, "style");
                    if (rt.lua.typeOf(-1) == .string) {
                        const s = rt.lua.toString(-1) catch "";
                        desc.suffix_style = shp.Style.parse(s);
                    } else if (rt.lua.typeOf(-1) != .nil) {
                        _ = rt.lua.pushString("builtin.sufix.style must be string");
                        rt.lua.raiseError();
                    }
                    rt.lua.pop(1);
                }
                rt.lua.pop(1);
            }

            _ = rt.lua.getField(-1, "prefix_style");
            if (rt.lua.typeOf(-1) == .string) {
                const s = rt.lua.toString(-1) catch "";
                desc.prefix_style = shp.Style.parse(s);
            }
            rt.lua.pop(1);

            _ = rt.lua.getField(-1, "suffix_style");
            if (rt.lua.typeOf(-1) == .string) {
                const s = rt.lua.toString(-1) catch "";
                desc.suffix_style = shp.Style.parse(s);
            }
            rt.lua.pop(1);

            _ = rt.lua.getField(-1, "kind");
            if (rt.lua.typeOf(-1) == .string) {
                const s = rt.lua.toString(-1) catch "";
                const n = @min(s.len, desc.spinner_kind_buf.len);
                @memcpy(desc.spinner_kind_buf[0..n], s[0..n]);
                desc.spinner_kind_len = n;
            }
            rt.lua.pop(1);

            _ = rt.lua.getField(-1, "width");
            if (rt.lua.typeOf(-1) == .number) {
                const v = rt.lua.toNumber(-1) catch 0;
                if (std.math.isFinite(v)) desc.spinner_width = @intFromFloat(std.math.clamp(v, 1, 64));
            }
            rt.lua.pop(1);

            _ = rt.lua.getField(-1, "step");
            if (rt.lua.typeOf(-1) == .number) {
                const v = rt.lua.toNumber(-1) catch 0;
                if (std.math.isFinite(v)) desc.spinner_step_ms = @intFromFloat(std.math.clamp(v, 1, 5000));
            }
            rt.lua.pop(1);

            _ = rt.lua.getField(-1, "step_ms");
            if (rt.lua.typeOf(-1) == .number) {
                const v = rt.lua.toNumber(-1) catch 0;
                if (std.math.isFinite(v)) desc.spinner_step_ms = @intFromFloat(std.math.clamp(v, 1, 5000));
            }
            rt.lua.pop(1);

            _ = rt.lua.getField(-1, "hold");
            if (rt.lua.typeOf(-1) == .number) {
                const v = rt.lua.toNumber(-1) catch 0;
                if (std.math.isFinite(v)) desc.spinner_hold_frames = @intFromFloat(std.math.clamp(v, 0, 120));
            }
            rt.lua.pop(1);

            _ = rt.lua.getField(-1, "hold_frames");
            if (rt.lua.typeOf(-1) == .number) {
                const v = rt.lua.toNumber(-1) catch 0;
                if (std.math.isFinite(v)) desc.spinner_hold_frames = @intFromFloat(std.math.clamp(v, 0, 120));
            }
            rt.lua.pop(1);

            _ = rt.lua.getField(-1, "bg");
            if (rt.lua.typeOf(-1) == .number) {
                const v = rt.lua.toNumber(-1) catch 0;
                if (std.math.isFinite(v)) desc.spinner_bg = @intFromFloat(std.math.clamp(v, 0, 255));
            }
            rt.lua.pop(1);

            _ = rt.lua.getField(-1, "placeholder");
            if (rt.lua.typeOf(-1) == .number) {
                const v = rt.lua.toNumber(-1) catch 0;
                if (std.math.isFinite(v)) desc.spinner_placeholder = @intFromFloat(std.math.clamp(v, 0, 255));
            }
            rt.lua.pop(1);

            _ = rt.lua.getField(-1, "colors");
            if (rt.lua.typeOf(-1) == .table) {
                const len: i32 = @intCast(@min(rt.lua.rawLen(-1), desc.spinner_colors_buf.len));
                var i: i32 = 1;
                while (i <= len) : (i += 1) {
                    _ = rt.lua.rawGetIndex(-1, i);
                    if (rt.lua.typeOf(-1) == .number) {
                        const v = rt.lua.toNumber(-1) catch -1;
                        if (std.math.isFinite(v)) {
                            const iv: i32 = @intFromFloat(std.math.clamp(v, 0, 255));
                            desc.spinner_colors_buf[desc.spinner_colors_len] = @intCast(iv);
                            desc.spinner_colors_len += 1;
                        }
                    }
                    rt.lua.pop(1);
                }
            }
            rt.lua.pop(1);

            return desc;
        },
        else => return desc,
    }
}

fn passesWhen(ctx: *shp.Context, query: *const core.PaneQuery, mod: core.config.Segment) bool {
    if (mod.when == null) return true;
    return passesWhenClause(ctx, query, mod.when.?);
}

fn passesWhenClause(ctx: *shp.Context, query: *const core.PaneQuery, w: core.WhenDef) bool {
    // Token-based 'all' conditions
    if (w.all) |tokens| {
        for (tokens) |t| {
            if (!core.query.evalToken(query, t)) return false;
        }
    }

    // Nested 'any' conditions (OR): at least one must match
    if (w.any) |clauses| {
        var any_match = false;
        for (clauses) |c| {
            if (passesWhenClause(ctx, query, c)) {
                any_match = true;
                break;
            }
        }
        if (!any_match) return false;
    }

    // Lua/bash conditions — evaluated with caching
    if (w.lua) |lua_code| {
        if (!evalLuaWhen(lua_code, ctx, 500)) return false;
    }
    if (w.bash) |bash_code| {
        if (!evalBashWhen(bash_code, ctx, 2000)) return false;
    }

    return true;
}

pub const RenderedSegment = struct {
    text: []const u8,
    fg: Color,
    bg: Color,
    bold: bool,
    italic: bool,
};

pub const RenderedSegments = struct {
    items: [16]RenderedSegment,
    buffers: [16][64]u8,
    count: usize,
    total_len: usize,
};

pub fn renderSegmentOutput(module: *const core.Segment, output: []const u8) RenderedSegments {
    var result = RenderedSegments{
        .items = undefined,
        .buffers = undefined,
        .count = 0,
        .total_len = 0,
    };

    for (module.outputs) |out| {
        if (result.count >= 16) break;

        var text_len: usize = 0;
        var i: usize = 0;
        while (i < out.format.len and text_len < 64) {
            if (i + 6 < out.format.len and std.mem.eql(u8, out.format[i .. i + 7], "$output")) {
                const copy_len = @min(output.len, 64 - text_len);
                @memcpy(result.buffers[result.count][text_len .. text_len + copy_len], output[0..copy_len]);
                text_len += copy_len;
                i += 7;
            } else {
                const cp_len = std.unicode.utf8ByteSequenceLength(out.format[i]) catch 1;
                const end = @min(i + cp_len, out.format.len);
                const token_len = end - i;
                if (text_len + token_len > 64) break;
                @memcpy(result.buffers[result.count][text_len .. text_len + token_len], out.format[i..end]);
                text_len += token_len;
                i = end;
            }
        }

        const style = shp.Style.parse(out.style);

        result.items[result.count] = .{
            .text = result.buffers[result.count][0..text_len],
            .fg = if (style.fg != .none) styleColorToRender(style.fg) else .none,
            .bg = if (style.bg != .none) styleColorToRender(style.bg) else .none,
            .bold = style.bold,
            .italic = style.italic,
        };
        result.total_len += measureText(result.items[result.count].text);
        result.count += 1;
    }

    return result;
}

pub fn styleColorToRender(col: shp.Color) Color {
    return switch (col) {
        .none => .none,
        .palette => |p| .{ .palette = p },
        .rgb => |rgb| .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
    };
}

pub fn runSegment(module: *const core.Segment, buf: []u8) ![]const u8 {
    if (module.command) |cmd| {
        const result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "/bin/sh", "-c", cmd },
        }) catch return "";
        defer std.heap.page_allocator.free(result.stdout);
        defer std.heap.page_allocator.free(result.stderr);

        var len = result.stdout.len;
        while (len > 0 and (result.stdout[len - 1] == '\n' or result.stdout[len - 1] == '\r')) {
            len -= 1;
        }
        const copy_len = @min(len, buf.len);
        @memcpy(buf[0..copy_len], result.stdout[0..copy_len]);
        return buf[0..copy_len];
    }

    const copy_len = @min(module.name.len, buf.len);
    @memcpy(buf[0..copy_len], module.name[0..copy_len]);
    return buf[0..copy_len];
}

pub fn draw(
    renderer: *Renderer,
    state: *State,
    allocator: std.mem.Allocator,
    config: *const core.Config,
    term_width: u16,
    term_height: u16,
    tabs: anytype,
    active_tab: usize,
    session_name: []const u8,
) void {
    const y = term_height - 1;
    const width = term_width;
    const cfg = &config.tabs.status;

    callback_lua_rt = config._lua_runtime;
    callback_state = state;
    defer callback_lua_rt = null;
    defer callback_state = null;

    // Clear status bar
    for (0..width) |xi| {
        renderer.setVaxisCell(@intCast(xi), y, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{},
        });
    }

    // Create shp context
    var ctx = shp.Context.init(allocator);
    defer ctx.deinit();
    ctx.terminal_width = width;
    ctx.home = std.posix.getenv("HOME");

    ctx.now_ms = @intCast(std.time.milliTimestamp());

    // Provide shell metadata for status modules.
    // Also ensure we have a stable `shell_started_at_ms` while a float is focused,
    // so spinner modules can animate even without shell hooks.
    if (state.getCurrentFocusedUuid()) |uuid| {
        if (state.activeFloatingIndex() != null) {
            const info_opt = state.getPaneShell(uuid);
            const needs_start = if (info_opt) |info| info.started_at_ms == null else true;
            if (needs_start) {
                state.setPaneShellRunning(uuid, false, ctx.now_ms, null, null, null);
            }
        }

        if (state.getPaneShell(uuid)) |info| {
            if (info.cmd) |c| {
                ctx.last_command = c;
            }
            if (info.cwd) |c| {
                ctx.cwd = c;
            }
            if (info.status) |st| {
                ctx.exit_status = st;
            }
            if (info.duration_ms) |d| {
                ctx.cmd_duration_ms = d;
            }
            if (info.jobs) |j| {
                ctx.jobs = j;
            }

            ctx.shell_running = info.running;
            if (info.cmd) |c| ctx.shell_running_cmd = c;
            ctx.shell_started_at_ms = info.started_at_ms;
        }
    }

    // Mux focus state.
    ctx.tab_count = @intCast(@min(tabs.items.len, @as(usize, std.math.maxInt(u16))));
    ctx.focus_is_float = state.activeFloatingIndex() != null;
    ctx.focus_is_split = state.activeFloatingIndex() == null;

    // Provide pane state for animation policy + float attributes.
    if (state.activeFloatingIndex()) |idx| {
        if (idx < state.view.float_views.items.len) {
            ctx.alt_screen = state.view.float_views.items[idx].vt.inAltScreen();

            const fp = state.view.float_views.items[idx];
            ctx.float_key = state.paneFloatKey(fp);
            ctx.float_sticky = state.paneSticky(fp);
            ctx.float_global = state.paneParentTab(fp) == null;

            if (ctx.float_key != 0) {
                if (state.getLayoutFloatByKey(ctx.float_key)) |fd| {
                    ctx.float_destroyable = fd.attributes.destroy;
                    ctx.float_exclusive = fd.attributes.exclusive;
                    ctx.float_per_cwd = fd.attributes.per_cwd;
                    ctx.float_isolated = fd.attributes.isolated;
                    ctx.float_global = ctx.float_global or fd.attributes.global;
                }
            }
        }
    } else if (state.currentLayout().getFocusedPane()) |pane| {
        ctx.alt_screen = pane.vt.inAltScreen();
    }

    emitStatusbarRedrawEventIfDue(state, &ctx, term_width, term_height, active_tab);

    // Find the tabs module to check tab_title setting
    var use_basename = true;
    for (cfg.center) |mod| {
        if (std.mem.eql(u8, mod.name, "tabs")) {
            use_basename = std.mem.eql(u8, mod.tab_title, "basename");
            break;
        }
    }

    // Collect tab titles for center section.
    // Keep active-tab mapping in display space (especially when clipped to 16).
    var tab_names: [16][]const u8 = undefined;
    var tab_count: usize = 0;
    var active_display_tab: ?usize = null;
    for (tabs.items, 0..) |*tab, ti| {
        const tab_name = tabTitleForDisplay(state, ti, tab, use_basename);

        if (tab_count < tab_names.len) {
            tab_names[tab_count] = tab_name;
            if (ti == active_tab) active_display_tab = tab_count;
            tab_count += 1;
        } else if (ti == active_tab) {
            // Keep active tab visible when list is clipped.
            tab_names[tab_names.len - 1] = tab_name;
            active_display_tab = tab_names.len - 1;
        }
    }
    ctx.tab_names = tab_names[0..tab_count];
    ctx.active_tab = active_display_tab orelse 0;
    ctx.session_name = session_name;

    // Build PaneQuery for condition evaluation
    const query = queryFromContext(&ctx);

    // === PRIORITY-BASED LAYOUT ===
    // Measure center (tabs) width and get arrow config
    var center_width: u16 = 0;
    var tabs_left_arrow: []const u8 = "";
    var tabs_right_arrow: []const u8 = "";
    for (cfg.center) |mod| {
        if (std.mem.eql(u8, mod.name, "tabs")) {
            tabs_left_arrow = mod.left_arrow;
            tabs_right_arrow = mod.right_arrow;
            center_width = measureTabsWidth(ctx.tab_names, mod.separator, mod.left_arrow, mod.right_arrow);
            break;
        }
    }

    // True center position
    const center_start = (width -| center_width) / 2;
    const left_budget = center_start;
    const right_budget = width -| (center_start +| center_width);

    // Collect left modules with widths
    const ModuleInfo = struct { mod: *const core.Segment, width: u16, visible: bool };
    var left_modules: [24]ModuleInfo = undefined;
    var left_count: usize = 0;
    for (cfg.left) |*mod| {
        if (left_count < 24) {
            left_modules[left_count] = .{
                .mod = mod,
                .width = calcModuleWidth(&ctx, &query, mod),
                .visible = false,
            };
            left_count += 1;
        }
    }

    // Sort left by priority and mark visible
    var left_order: [24]usize = undefined;
    for (0..left_count) |i| left_order[i] = i;

    for (1..left_count) |i| {
        const key = left_order[i];
        var j: usize = i;
        while (j > 0 and left_modules[left_order[j - 1]].mod.priority > left_modules[key].mod.priority) : (j -= 1) {
            left_order[j] = left_order[j - 1];
        }
        left_order[j] = key;
    }
    var left_used: u16 = 0;
    for (left_order[0..left_count]) |idx| {
        if (left_used + left_modules[idx].width <= left_budget) {
            left_modules[idx].visible = true;
            left_used += left_modules[idx].width;
        }
    }

    // Update randomdo visibility state (off->on changes word).
    for (0..left_count) |i| {
        if (std.mem.eql(u8, left_modules[i].mod.name, "randomdo")) {
            const shown = left_modules[i].visible and left_modules[i].width != 0;
            _ = randomdoTextFor(&ctx, left_modules[i].mod, shown);
        }
    }

    // Collect right modules with widths
    var right_modules: [24]ModuleInfo = undefined;
    var right_count: usize = 0;
    for (cfg.right) |*mod| {
        if (right_count < 24) {
            right_modules[right_count] = .{
                .mod = mod,
                .width = calcModuleWidth(&ctx, &query, mod),
                .visible = false,
            };
            right_count += 1;
        }
    }

    // Sort right by priority and mark visible
    var right_order: [24]usize = undefined;
    for (0..right_count) |i| right_order[i] = i;
    for (1..right_count) |i| {
        const key = right_order[i];
        var j: usize = i;
        while (j > 0 and right_modules[right_order[j - 1]].mod.priority > right_modules[key].mod.priority) : (j -= 1) {
            right_order[j] = right_order[j - 1];
        }
        right_order[j] = key;
    }
    var right_used: u16 = 0;
    for (right_order[0..right_count]) |idx| {
        if (right_used + right_modules[idx].width <= right_budget) {
            right_modules[idx].visible = true;
            right_used += right_modules[idx].width;
        }
    }

    for (0..right_count) |i| {
        if (std.mem.eql(u8, right_modules[i].mod.name, "randomdo")) {
            const shown = right_modules[i].visible and right_modules[i].width != 0;
            _ = randomdoTextFor(&ctx, right_modules[i].mod, shown);
        }
    }

    // === DRAW LEFT SECTION ===
    var left_x: u16 = 0;
    for (0..left_count) |i| {
        if (left_modules[i].visible) {
            const hovered = isHoveredRange(left_x, left_modules[i].width, y);
            left_x = drawModule(renderer, &ctx, &query, left_modules[i].mod, left_x, y, hovered);
        }
    }

    // === DRAW RIGHT SECTION (from right edge) ===
    const right_start = width -| right_used;
    var rx: u16 = right_start;
    for (0..right_count) |i| {
        if (right_modules[i].visible) {
            const hovered = isHoveredRange(rx, right_modules[i].width, y);
            rx = drawModule(renderer, &ctx, &query, right_modules[i].mod, rx, y, hovered);
        }
    }

    // === DRAW CENTER SECTION (truly centered, drawn last to win overlaps) ===
    if (center_width > 0) {
        // Use calculated center_start
        var cx: u16 = center_start;

        for (cfg.center) |mod| {
            if (std.mem.eql(u8, mod.name, "tabs")) {
                const active_style = shp.Style.parse(mod.active_style);
                const inactive_style = shp.Style.parse(mod.inactive_style);
                const sep_style = shp.Style.parse(mod.separator_style);

                for (ctx.tab_names, 0..) |tab_name, ti| {
                    // Stop at terminal edge
                    if (cx >= width) break;

                    if (ti > 0) {
                        cx = drawStyledText(renderer, cx, y, mod.separator, sep_style);
                        if (cx >= width) break;
                    }
                    const is_active = ti == ctx.active_tab;
                    const style = if (is_active) active_style else inactive_style;
                    const arrow_fg = if (is_active) active_style.bg else inactive_style.bg;
                    const arrow_style = shp.Style{ .fg = arrow_fg };

                    cx = drawStyledText(renderer, cx, y, tabs_left_arrow, arrow_style);
                    cx = drawStyledText(renderer, cx, y, " ", style);
                    cx = drawStyledText(renderer, cx, y, tab_name, style);
                    cx = drawStyledText(renderer, cx, y, " ", style);
                    cx = drawStyledText(renderer, cx, y, tabs_right_arrow, arrow_style);
                }
            }
        }
    }
}

/// If the mouse click at (x,y) hits a tab in the center tabs widget,
/// return the tab index.
pub fn hitTestTab(
    state: *State,
    allocator: std.mem.Allocator,
    config: *const core.Config,
    term_width: u16,
    term_height: u16,
    tabs: anytype,
    active_tab: usize,
    session_name: []const u8,
    x: u16,
    y: u16,
) ?usize {
    if (!config.tabs.status.enabled) return null;
    if (term_height == 0) return null;
    const bar_y = term_height - 1;
    if (y != bar_y) return null;

    const width = term_width;
    const cfg = &config.tabs.status;

    // Create shp context for tab name resolution.
    var ctx = shp.Context.init(allocator);
    defer ctx.deinit();
    ctx.terminal_width = width;

    // Find the tabs module and its tab_title setting.
    var use_basename = true;
    var tabs_mod: ?*const core.Segment = null;
    for (cfg.center) |mod| {
        if (std.mem.eql(u8, mod.name, "tabs")) {
            use_basename = std.mem.eql(u8, mod.tab_title, "basename");
            tabs_mod = &mod;
            break;
        }
    }
    if (tabs_mod == null) return null;

    var tab_names: [16][]const u8 = undefined;
    var tab_count: usize = 0;
    var active_display_tab: ?usize = null;
    for (tabs.items, 0..) |*tab, ti| {
        const tab_name = tabTitleForDisplay(state, ti, tab, use_basename);

        if (tab_count < tab_names.len) {
            tab_names[tab_count] = tab_name;
            if (ti == active_tab) active_display_tab = tab_count;
            tab_count += 1;
        } else if (ti == active_tab) {
            tab_names[tab_names.len - 1] = tab_name;
            active_display_tab = tab_names.len - 1;
        }
    }
    if (tab_count == 0) return null;

    ctx.tab_names = tab_names[0..tab_count];
    ctx.active_tab = active_display_tab orelse 0;
    ctx.session_name = session_name;

    const mod = tabs_mod.?;
    const center_width = measureTabsWidth(ctx.tab_names, mod.separator, mod.left_arrow, mod.right_arrow);
    if (center_width == 0) return null;
    const center_start = (width -| center_width) / 2;

    var cx: u16 = center_start;
    const left_arrow_width = measureText(mod.left_arrow);
    const right_arrow_width = measureText(mod.right_arrow);
    const sep_width = measureText(mod.separator);

    for (ctx.tab_names, 0..) |tab_name, ti| {
        if (ti > 0) {
            cx +|= sep_width;
        }
        const start_x = cx;
        cx +|= left_arrow_width;
        cx +|= 1;
        cx +|= measureText(tab_name);
        cx +|= 1;
        cx +|= right_arrow_width;
        const end_x = cx;

        if (x >= start_x and x < end_x) {
            return ti;
        }
    }

    return null;
}

fn clickCommandFor(mod: *const core.Segment, button: u8) ?[]const u8 {
    return switch (button) {
        0 => mod.on_click,
        1 => mod.on_middle_click,
        2 => mod.on_right_click,
        else => null,
    };
}

fn evalLuaClickCommand(code: []const u8, ctx: *shp.Context) ?[]const u8 {
    var rt_ptr: *LuaRuntime = undefined;
    if (callback_lua_rt) |existing| {
        rt_ptr = existing;
    } else {
        if (when_lua_rt == null) {
            when_lua_rt = LuaRuntime.init(std.heap.page_allocator) catch return null;
        }
        rt_ptr = &when_lua_rt.?;
    }

    populateLuaContext(rt_ptr, ctx);
    const mode = beginLuaEval(rt_ptr, code) orelse return null;
    defer endLuaEval(rt_ptr, mode);

    if (rt_ptr.lua.typeOf(-1) == .string) {
        const s = rt_ptr.lua.toString(-1) catch return null;
        const n = @min(s.len, click_command_buf.len);
        @memcpy(click_command_buf[0..n], s[0..n]);
        return click_command_buf[0..n];
    }

    if (rt_ptr.lua.typeOf(-1) == .table) {
        // Unified click action contract:
        // 1) { command = "..." }
        // 2) { kind = "command", command = "..." }
        _ = rt_ptr.lua.getField(-1, "command");
        const has_command = rt_ptr.lua.typeOf(-1) == .string;
        var cmd_val: []const u8 = "";
        if (has_command) {
            cmd_val = rt_ptr.lua.toString(-1) catch "";
        }
        rt_ptr.lua.pop(1);

        if (has_command and cmd_val.len > 0) {
            _ = rt_ptr.lua.getField(-1, "kind");
            const kind_ok = if (rt_ptr.lua.typeOf(-1) == .string)
                std.mem.eql(u8, (rt_ptr.lua.toString(-1) catch ""), "command")
            else
                true;
            rt_ptr.lua.pop(1);

            _ = rt_ptr.lua.getField(-1, "type");
            const type_ok = if (rt_ptr.lua.typeOf(-1) == .string)
                std.mem.eql(u8, (rt_ptr.lua.toString(-1) catch ""), "command")
            else
                true;
            rt_ptr.lua.pop(1);

            if (kind_ok and type_ok) {
                const n = @min(cmd_val.len, click_command_buf.len);
                @memcpy(click_command_buf[0..n], cmd_val[0..n]);
                return click_command_buf[0..n];
            }
        }
    }

    return null;
}

fn resolveClickCommandFor(mod: *const core.Segment, button: u8, ctx: *shp.Context) ?[]const u8 {
    const cmd = clickCommandFor(mod, button) orelse return null;
    if (callbackIdFromCode(cmd) != null) {
        return evalLuaClickCommand(cmd, ctx);
    }
    return cmd;
}

pub fn hitTestAction(
    state: *State,
    allocator: std.mem.Allocator,
    config: *const core.Config,
    term_width: u16,
    term_height: u16,
    tabs: anytype,
    active_tab: usize,
    session_name: []const u8,
    x: u16,
    y: u16,
    button: u8,
) ?[]const u8 {
    if (!config.tabs.status.enabled) return null;
    if (term_height == 0) return null;
    const bar_y = term_height - 1;
    if (y != bar_y) return null;

    const width = term_width;
    const cfg = &config.tabs.status;

    callback_lua_rt = config._lua_runtime;
    callback_state = state;
    defer callback_lua_rt = null;
    defer callback_state = null;

    var ctx = shp.Context.init(allocator);
    defer ctx.deinit();
    ctx.terminal_width = width;
    ctx.home = std.posix.getenv("HOME");
    ctx.now_ms = @intCast(std.time.milliTimestamp());

    // Keep context parity with draw() for consistent width/when decisions.
    // Important: do not mutate runtime shell state during hit-testing.
    if (state.getCurrentFocusedUuid()) |uuid| {
        if (state.getPaneShell(uuid)) |info| {
            if (info.cmd) |c| ctx.last_command = c;
            if (info.cwd) |c| ctx.cwd = c;
            if (info.status) |st| ctx.exit_status = st;
            if (info.duration_ms) |d| ctx.cmd_duration_ms = d;
            if (info.jobs) |j| ctx.jobs = j;
            ctx.shell_running = info.running;
            if (info.cmd) |c| ctx.shell_running_cmd = c;
            ctx.shell_started_at_ms = info.started_at_ms;
        }
    }

    ctx.tab_count = @intCast(@min(tabs.items.len, @as(usize, std.math.maxInt(u16))));
    ctx.focus_is_float = state.activeFloatingIndex() != null;
    ctx.focus_is_split = state.activeFloatingIndex() == null;

    if (state.activeFloatingIndex()) |idx| {
        if (idx < state.view.float_views.items.len) {
            ctx.alt_screen = state.view.float_views.items[idx].vt.inAltScreen();
            const fp = state.view.float_views.items[idx];
            ctx.float_key = state.paneFloatKey(fp);
            ctx.float_sticky = state.paneSticky(fp);
            ctx.float_global = state.paneParentTab(fp) == null;
            if (ctx.float_key != 0) {
                if (state.getLayoutFloatByKey(ctx.float_key)) |fd| {
                    ctx.float_destroyable = fd.attributes.destroy;
                    ctx.float_exclusive = fd.attributes.exclusive;
                    ctx.float_per_cwd = fd.attributes.per_cwd;
                    ctx.float_isolated = fd.attributes.isolated;
                    ctx.float_global = ctx.float_global or fd.attributes.global;
                }
            }
        }
    } else if (state.currentLayout().getFocusedPane()) |pane| {
        ctx.alt_screen = pane.vt.inAltScreen();
    }

    var use_basename = true;
    for (cfg.center) |mod| {
        if (std.mem.eql(u8, mod.name, "tabs")) {
            use_basename = std.mem.eql(u8, mod.tab_title, "basename");
            break;
        }
    }

    var tab_names: [16][]const u8 = undefined;
    var tab_count: usize = 0;
    var active_display_tab: ?usize = null;
    for (tabs.items, 0..) |*tab, ti| {
        const tab_name = tabTitleForDisplay(state, ti, tab, use_basename);

        if (tab_count < tab_names.len) {
            tab_names[tab_count] = tab_name;
            if (ti == active_tab) active_display_tab = tab_count;
            tab_count += 1;
        } else if (ti == active_tab) {
            tab_names[tab_names.len - 1] = tab_name;
            active_display_tab = tab_names.len - 1;
        }
    }
    ctx.tab_names = tab_names[0..tab_count];
    ctx.active_tab = active_display_tab orelse 0;
    ctx.session_name = session_name;

    const query = queryFromContext(&ctx);

    var center_width: u16 = 0;
    for (cfg.center) |mod| {
        if (std.mem.eql(u8, mod.name, "tabs")) {
            center_width = measureTabsWidth(ctx.tab_names, mod.separator, mod.left_arrow, mod.right_arrow);
            break;
        }
    }

    const center_start = (width -| center_width) / 2;
    const left_budget = center_start;
    const right_budget = width -| (center_start +| center_width);

    const ModuleInfo = struct { mod: *const core.Segment, width: u16, visible: bool };
    var left_modules: [24]ModuleInfo = undefined;
    var left_count: usize = 0;
    for (cfg.left) |*mod| {
        if (left_count < 24) {
            left_modules[left_count] = .{ .mod = mod, .width = calcModuleWidth(&ctx, &query, mod), .visible = false };
            left_count += 1;
        }
    }

    var left_order: [24]usize = undefined;
    for (0..left_count) |i| left_order[i] = i;
    for (1..left_count) |i| {
        const key = left_order[i];
        var j: usize = i;
        while (j > 0 and left_modules[left_order[j - 1]].mod.priority > left_modules[key].mod.priority) : (j -= 1) {
            left_order[j] = left_order[j - 1];
        }
        left_order[j] = key;
    }
    var left_used: u16 = 0;
    for (left_order[0..left_count]) |idx| {
        if (left_used + left_modules[idx].width <= left_budget) {
            left_modules[idx].visible = true;
            left_used += left_modules[idx].width;
        }
    }

    var right_modules: [24]ModuleInfo = undefined;
    var right_count: usize = 0;
    for (cfg.right) |*mod| {
        if (right_count < 24) {
            right_modules[right_count] = .{ .mod = mod, .width = calcModuleWidth(&ctx, &query, mod), .visible = false };
            right_count += 1;
        }
    }
    var right_order: [24]usize = undefined;
    for (0..right_count) |i| right_order[i] = i;
    for (1..right_count) |i| {
        const key = right_order[i];
        var j: usize = i;
        while (j > 0 and right_modules[right_order[j - 1]].mod.priority > right_modules[key].mod.priority) : (j -= 1) {
            right_order[j] = right_order[j - 1];
        }
        right_order[j] = key;
    }
    var right_used: u16 = 0;
    for (right_order[0..right_count]) |idx| {
        if (right_used + right_modules[idx].width <= right_budget) {
            right_modules[idx].visible = true;
            right_used += right_modules[idx].width;
        }
    }

    var lx: u16 = 0;
    for (0..left_count) |i| {
        const info = left_modules[i];
        if (!info.visible or info.width == 0) continue;
        const start = lx;
        const end = start +| info.width;
        if (x >= start and x < end) {
            toggleClickedButton(info.mod, button);
            return resolveClickCommandFor(info.mod, button, &ctx);
        }
        lx = end;
    }

    var rx: u16 = width -| right_used;
    for (0..right_count) |i| {
        const info = right_modules[i];
        if (!info.visible or info.width == 0) continue;
        const start = rx;
        const end = start +| info.width;
        if (x >= start and x < end) {
            toggleClickedButton(info.mod, button);
            return resolveClickCommandFor(info.mod, button, &ctx);
        }
        rx = end;
    }

    return null;
}

// Helper to measure tabs width - mirrors exact rendering logic
fn measureTabsWidth(tab_names: []const []const u8, separator: []const u8, left_arrow: []const u8, right_arrow: []const u8) u16 {
    var w: u16 = 0;
    const left_arrow_width = measureText(left_arrow);
    const right_arrow_width = measureText(right_arrow);

    for (tab_names, 0..) |tab_name, ti| {
        if (ti > 0) w += measureText(separator);
        w += left_arrow_width;
        w += 1; // space
        w += measureText(tab_name);
        w += 1; // space
        w += right_arrow_width;
    }
    return w;
}

pub fn drawModule(renderer: *Renderer, ctx: *shp.Context, query: *const core.PaneQuery, mod: *const core.config.Segment, start_x: u16, y: u16, hovered: bool) u16 {
    var x = start_x;
    _ = query;

    const prev_module_style = ctx.module_default_style;
    defer ctx.module_default_style = prev_module_style;

    var spinner_allowed = true;
    if (mod.spinner != null) {
        if (mod.kind == .progress and !progressVisible(mod, ctx)) {
            spinner_allowed = false;
        }
        if (mod.command) |cmd| {
            if (mod.kind == .builtin) {
                const bdesc = evalLuaBuiltinDescCached(cmd, ctx);
                spinner_allowed = spinner_allowed and (bdesc.name() != null);
            } else {
                const gate_eval = evalLuaCommandCached(cmd, ctx);
                const gate_text = gate_eval.textSlice();
                spinner_allowed = spinner_allowed and (gate_eval.seg_count > 0 or gate_text.len > 0);
            }
        } else if (mod.builtin) |builtin_name| {
            spinner_allowed = spinner_allowed and (ctx.renderSegment(builtin_name) != null);
        }
    }
    if (mod.spinner != null and !spinner_allowed) return x;

    const clickable = isClickable(mod);
    const active_when = if (clickable) isButtonActive(mod, ctx) else false;
    const clicked_button = if (clickable) clickedButtonFor(mod) else null;
    const clicked_active = clicked_button != null;
    const invert_style = clickable and mod.inverse_on_hover and if (clicked_active) hovered else (hovered != active_when);

    var command_output: []const u8 = "";
    var command_output_ready = false;
    var command_eval: LuaEval = .{};
    var command_eval_segs: [16]shp.Segment = undefined;

    const outputs = if (mod.outputs.len == 0) DEFAULT_OUTPUTS[0..] else mod.outputs;
    for (outputs) |out| {
        var style = shp.Style.parse(out.style);
        var format_use = out.format;
        if (mod.outputs.len == 0) {
            if (std.mem.eql(u8, mod.name, "spinner")) {
                format_use = " $output ";
            } else if (std.mem.eql(u8, mod.name, "randomdo")) {
                format_use = "$output ";
                if (style.isEmpty()) style = shp.Style.parse("bg:0 fg:1");
            }
        }
        var style_final = style;
        if (clicked_button) |btn| {
            if (clickedButtonStyle(mod, btn)) |click_style| {
                style_final = click_style;
            }
        }
        if (invert_style) {
            const fg_tmp = style_final.fg;
            style_final.fg = style_final.bg;
            style_final.bg = fg_tmp;
        }
        ctx.module_default_style = style_final;

        var output_segs: ?[]const shp.Segment = null;
        var output_text: []const u8 = "";
        if (mod.spinner) |cfg_in| {
            var cfg = cfg_in;
            cfg.started_at_ms = ctx.shell_started_at_ms orelse ctx.now_ms;
            output_segs = animations.renderSegments(ctx, cfg);
            if (output_segs) |segs| {
                if (segs.len == 0) output_segs = null;
            }
            if (output_segs == null) {
                output_text = animations.renderWithOptions(cfg.kind, ctx.now_ms, cfg.started_at_ms, cfg.width, cfg.step_ms, cfg.hold_frames);
                if (output_text.len == 0) {
                    output_text = spinnerAsciiFrame(ctx.now_ms, cfg.started_at_ms, cfg.step_ms);
                }
            }
        } else if (mod.command) |cmd| {
            if (!command_output_ready) {
                if (mod.kind == .builtin) {
                    const bdesc = evalLuaBuiltinDescCached(cmd, ctx);
                    if (bdesc.name()) |builtin_name| {
                        if (std.mem.eql(u8, builtin_name, "spinner")) {
                            var cfg = core.config.SpinnerDef{};
                            cfg.started_at_ms = ctx.shell_started_at_ms orelse ctx.now_ms;
                            if (bdesc.spinnerKind()) |k| cfg.kind = k;
                            if (bdesc.spinner_width) |v| cfg.width = v;
                            if (bdesc.spinner_step_ms) |v| cfg.step_ms = v;
                            if (bdesc.spinner_hold_frames) |v| cfg.hold_frames = v;
                            if (bdesc.spinner_bg) |v| cfg.bg_color = v;
                            if (bdesc.spinner_placeholder) |v| cfg.placeholder_color = v;
                            const cols = bdesc.spinnerColors();
                            if (cols.len > 0) cfg.colors = cols;
                            output_segs = animations.renderSegments(ctx, cfg);
                            if (output_segs) |segs| {
                                if (segs.len == 0) output_segs = null;
                            }
                            if (output_segs == null) {
                                output_text = animations.renderWithOptions(cfg.kind, ctx.now_ms, cfg.started_at_ms, cfg.width, cfg.step_ms, cfg.hold_frames);
                                if (output_text.len == 0) {
                                    output_text = spinnerAsciiFrame(ctx.now_ms, cfg.started_at_ms, cfg.step_ms);
                                }
                            }
                        } else if (std.mem.eql(u8, builtin_name, "randomdo")) {
                            output_text = randomdoTextFor(ctx, mod, true);
                        } else if (ctx.renderSegment(builtin_name)) |segs| {
                            var styled: [16]shp.Segment = undefined;
                            var text_buf: [16][96]u8 = undefined;
                            var count: usize = 0;
                            const pref = bdesc.prefix();
                            if (pref.len > 0 and count < styled.len) {
                                const pn = @min(pref.len, text_buf[count].len);
                                @memcpy(text_buf[count][0..pn], pref[0..pn]);
                                styled[count] = .{ .text = text_buf[count][0..pn], .style = bdesc.prefixStyle() };
                                count += 1;
                            }
                            for (segs) |seg| {
                                if (count >= styled.len) break;
                                const tn = @min(seg.text.len, text_buf[count].len);
                                @memcpy(text_buf[count][0..tn], seg.text[0..tn]);
                                styled[count] = .{ .text = text_buf[count][0..tn], .style = if (bdesc.style.isEmpty()) seg.style else bdesc.style };
                                count += 1;
                            }
                            const suff = bdesc.suffix();
                            if (suff.len > 0 and count < styled.len) {
                                const sn = @min(suff.len, text_buf[count].len);
                                @memcpy(text_buf[count][0..sn], suff[0..sn]);
                                styled[count] = .{ .text = text_buf[count][0..sn], .style = bdesc.suffixStyle() };
                                count += 1;
                            }
                            output_segs = styled[0..count];
                        }
                    }
                } else if (mod.kind == .progress and !progressVisible(mod, ctx)) {
                    command_output = "";
                } else {
                    if (mod.kind == .progress and mod.progress_every_ms > 0) {
                        const key = progressKey(mod);
                        const cache = getProgressTextCache();
                        if (cache.getPtr(key)) |entry| {
                            if (ctx.now_ms - entry.last_eval_ms < mod.progress_every_ms) {
                                command_output = entry.text[0..entry.len];
                            } else {
                                command_eval = evalLuaCommandCached(cmd, ctx);
                                command_output = command_eval.textSlice();
                                const n = @min(command_output.len, entry.text.len);
                                @memcpy(entry.text[0..n], command_output[0..n]);
                                entry.len = n;
                                entry.last_eval_ms = ctx.now_ms;
                                command_output = entry.text[0..entry.len];
                            }
                        } else {
                            command_eval = evalLuaCommandCached(cmd, ctx);
                            command_output = command_eval.textSlice();
                            var buf: [256]u8 = [_]u8{0} ** 256;
                            const n = @min(command_output.len, buf.len);
                            @memcpy(buf[0..n], command_output[0..n]);
                            cache.put(key, .{ .last_eval_ms = ctx.now_ms, .text = buf, .len = n }) catch {};
                        }
                    } else {
                        command_eval = evalLuaCommandCached(cmd, ctx);
                        command_output = command_eval.textSlice();
                    }
                }
                command_output_ready = true;
            }
            if (output_segs == null and output_text.len == 0) {
                output_segs = command_eval.segSlice(&command_eval_segs);
                output_text = command_output;
            }
            if (output_segs == null) {
                if (builtinNameFromMarker(output_text)) |builtin_name| {
                    if (std.mem.eql(u8, builtin_name, "randomdo")) {
                        output_text = randomdoTextFor(ctx, mod, true);
                    } else {
                        output_segs = ctx.renderSegment(builtin_name);
                        output_text = "";
                    }
                }
            }
        } else if (mod.builtin) |builtin_name| {
            output_segs = ctx.renderSegment(builtin_name);
        } else if (std.mem.eql(u8, mod.name, "spinner")) {
            output_text = spinnerAsciiFrame(ctx.now_ms, ctx.shell_started_at_ms orelse 0, 100);
        } else if (std.mem.eql(u8, mod.name, "session")) {
            output_text = ctx.session_name;
        } else if (std.mem.eql(u8, mod.name, "randomdo")) {
            output_text = randomdoTextFor(ctx, mod, true);
        } else {
            output_segs = ctx.renderSegment(mod.name);
        }
        if ((output_segs == null or output_segs.?.len == 0) and output_text.len == 0) continue;

        var segs_for_draw = output_segs;
        var styled_for_button: [16]shp.Segment = undefined;
        if (clickable) {
            if (output_segs) |segs| {
                const click_override = if (clicked_button) |btn| clickedButtonStyle(mod, btn) else null;
                const n = @min(segs.len, styled_for_button.len);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    var rs = if (click_override) |cs|
                        cs
                    else if (segs[i].style.isEmpty())
                        style
                    else
                        segs[i].style;
                    if (invert_style) {
                        const fg_tmp = rs.fg;
                        rs.fg = rs.bg;
                        rs.bg = fg_tmp;
                    }
                    styled_for_button[i] = .{ .text = segs[i].text, .style = rs };
                }
                segs_for_draw = styled_for_button[0..n];
            }
        }

        x = drawFormatted(renderer, ctx, x, y, format_use, output_text, segs_for_draw, style_final);
    }

    return x;
}

pub fn drawFormatted(renderer: *Renderer, ctx: *shp.Context, start_x: u16, y: u16, format: []const u8, output: []const u8, output_segs: ?[]const shp.Segment, style: shp.Style) u16 {
    const DrawState = struct {
        renderer: *Renderer,
        ctx: *shp.Context,
        x: u16,
        y: u16,

        fn resolve(self: *@This(), builtin_name: []const u8) ?[]const shp.Segment {
            return self.ctx.renderSegment(builtin_name);
        }

        fn emit(self: *@This(), text: []const u8, run_style: shp.Style) !void {
            if (text.len == 0) return;
            self.x = drawStyledText(self.renderer, self.x, self.y, text, run_style);
        }
    };

    var state: DrawState = .{ .renderer = renderer, .ctx = ctx, .x = start_x, .y = y };
    segment_render.forEachFormattedRun(DrawState, &state, format, output, output_segs, style, DrawState.resolve, DrawState.emit) catch {};
    return state.x;
}

pub fn calcModuleWidth(ctx: *shp.Context, query: *const core.PaneQuery, mod: *const core.config.Segment) u16 {
    _ = query;

    const prev_module_style = ctx.module_default_style;
    defer ctx.module_default_style = prev_module_style;

    var spinner_allowed = true;
    if (mod.spinner != null) {
        if (mod.kind == .progress and !progressVisible(mod, ctx)) {
            spinner_allowed = false;
        }
        if (mod.command) |cmd| {
            if (mod.kind == .builtin) {
                const bdesc = evalLuaBuiltinDescCached(cmd, ctx);
                spinner_allowed = spinner_allowed and (bdesc.name() != null);
            } else {
                const gate_eval = evalLuaCommandCached(cmd, ctx);
                const gate_text = gate_eval.textSlice();
                spinner_allowed = spinner_allowed and (gate_eval.seg_count > 0 or gate_text.len > 0);
            }
        } else if (mod.builtin) |builtin_name| {
            spinner_allowed = spinner_allowed and (ctx.renderSegment(builtin_name) != null);
        }
    }
    if (mod.spinner != null and !spinner_allowed) return 0;
    var width: u16 = 0;

    var command_output: []const u8 = "";
    var command_output_ready = false;
    var command_eval: LuaEval = .{};
    var command_eval_segs: [16]shp.Segment = undefined;

    const outputs = if (mod.outputs.len == 0) DEFAULT_OUTPUTS[0..] else mod.outputs;
    for (outputs) |out| {
        var style = shp.Style.parse(out.style);
        var format_use = out.format;
        if (mod.outputs.len == 0) {
            if (std.mem.eql(u8, mod.name, "spinner")) {
                format_use = " $output ";
            } else if (std.mem.eql(u8, mod.name, "randomdo")) {
                format_use = "$output ";
                if (style.isEmpty()) style = shp.Style.parse("bg:0 fg:1");
            }
        }
        ctx.module_default_style = style;

        var output_segs: ?[]const shp.Segment = null;
        var output_text: []const u8 = "";
        if (mod.spinner) |cfg_in| {
            var cfg = cfg_in;
            cfg.started_at_ms = ctx.shell_started_at_ms orelse ctx.now_ms;
            output_segs = animations.renderSegments(ctx, cfg);
            if (output_segs) |segs| {
                if (segs.len == 0) output_segs = null;
            }
            if (output_segs == null) {
                output_text = animations.renderWithOptions(cfg.kind, ctx.now_ms, cfg.started_at_ms, cfg.width, cfg.step_ms, cfg.hold_frames);
                if (output_text.len == 0) {
                    output_text = spinnerAsciiFrame(ctx.now_ms, cfg.started_at_ms, cfg.step_ms);
                }
            }
        } else if (mod.command) |cmd| {
            if (!command_output_ready) {
                if (mod.kind == .builtin) {
                    const bdesc = evalLuaBuiltinDescCached(cmd, ctx);
                    if (bdesc.name()) |builtin_name| {
                        if (std.mem.eql(u8, builtin_name, "spinner")) {
                            var cfg = core.config.SpinnerDef{};
                            cfg.started_at_ms = ctx.shell_started_at_ms orelse ctx.now_ms;
                            if (bdesc.spinnerKind()) |k| cfg.kind = k;
                            if (bdesc.spinner_width) |v| cfg.width = v;
                            if (bdesc.spinner_step_ms) |v| cfg.step_ms = v;
                            if (bdesc.spinner_hold_frames) |v| cfg.hold_frames = v;
                            if (bdesc.spinner_bg) |v| cfg.bg_color = v;
                            if (bdesc.spinner_placeholder) |v| cfg.placeholder_color = v;
                            const cols = bdesc.spinnerColors();
                            if (cols.len > 0) cfg.colors = cols;
                            output_segs = animations.renderSegments(ctx, cfg);
                            if (output_segs) |segs| {
                                if (segs.len == 0) output_segs = null;
                            }
                            if (output_segs == null) {
                                output_text = animations.renderWithOptions(cfg.kind, ctx.now_ms, cfg.started_at_ms, cfg.width, cfg.step_ms, cfg.hold_frames);
                                if (output_text.len == 0) {
                                    output_text = spinnerAsciiFrame(ctx.now_ms, cfg.started_at_ms, cfg.step_ms);
                                }
                            }
                        } else if (std.mem.eql(u8, builtin_name, "randomdo")) {
                            width += calcFormattedWidthMax(format_use, randomdo_mod.MAX_LEN);
                            continue;
                        } else if (ctx.renderSegment(builtin_name)) |segs| {
                            var styled: [16]shp.Segment = undefined;
                            var text_buf: [16][96]u8 = undefined;
                            var count: usize = 0;
                            const pref = bdesc.prefix();
                            if (pref.len > 0 and count < styled.len) {
                                const pn = @min(pref.len, text_buf[count].len);
                                @memcpy(text_buf[count][0..pn], pref[0..pn]);
                                styled[count] = .{ .text = text_buf[count][0..pn], .style = bdesc.prefixStyle() };
                                count += 1;
                            }
                            for (segs) |seg| {
                                if (count >= styled.len) break;
                                const tn = @min(seg.text.len, text_buf[count].len);
                                @memcpy(text_buf[count][0..tn], seg.text[0..tn]);
                                styled[count] = .{ .text = text_buf[count][0..tn], .style = if (bdesc.style.isEmpty()) seg.style else bdesc.style };
                                count += 1;
                            }
                            const suff = bdesc.suffix();
                            if (suff.len > 0 and count < styled.len) {
                                const sn = @min(suff.len, text_buf[count].len);
                                @memcpy(text_buf[count][0..sn], suff[0..sn]);
                                styled[count] = .{ .text = text_buf[count][0..sn], .style = bdesc.suffixStyle() };
                                count += 1;
                            }
                            output_segs = styled[0..count];
                        }
                    }
                } else if (mod.kind == .progress and !progressVisible(mod, ctx)) {
                    command_output = "";
                } else {
                    if (mod.kind == .progress and mod.progress_every_ms > 0) {
                        const key = progressKey(mod);
                        const cache = getProgressTextCache();
                        if (cache.getPtr(key)) |entry| {
                            if (ctx.now_ms - entry.last_eval_ms < mod.progress_every_ms) {
                                command_output = entry.text[0..entry.len];
                            } else {
                                command_eval = evalLuaCommandCached(cmd, ctx);
                                command_output = command_eval.textSlice();
                                const n = @min(command_output.len, entry.text.len);
                                @memcpy(entry.text[0..n], command_output[0..n]);
                                entry.len = n;
                                entry.last_eval_ms = ctx.now_ms;
                                command_output = entry.text[0..entry.len];
                            }
                        } else {
                            command_eval = evalLuaCommandCached(cmd, ctx);
                            command_output = command_eval.textSlice();
                            var buf: [256]u8 = [_]u8{0} ** 256;
                            const n = @min(command_output.len, buf.len);
                            @memcpy(buf[0..n], command_output[0..n]);
                            cache.put(key, .{ .last_eval_ms = ctx.now_ms, .text = buf, .len = n }) catch {};
                        }
                    } else {
                        command_eval = evalLuaCommandCached(cmd, ctx);
                        command_output = command_eval.textSlice();
                    }
                }
                command_output_ready = true;
            }
            if (output_segs == null and output_text.len == 0) {
                output_segs = command_eval.segSlice(&command_eval_segs);
                output_text = command_output;
            }
            if (output_segs == null) {
                if (builtinNameFromMarker(output_text)) |builtin_name| {
                    if (std.mem.eql(u8, builtin_name, "randomdo")) {
                        width += calcFormattedWidthMax(format_use, randomdo_mod.MAX_LEN);
                        continue;
                    }
                    output_segs = ctx.renderSegment(builtin_name);
                    output_text = "";
                }
            }
        } else if (mod.builtin) |builtin_name| {
            output_segs = ctx.renderSegment(builtin_name);
        } else if (std.mem.eql(u8, mod.name, "spinner")) {
            output_text = spinnerAsciiFrame(ctx.now_ms, ctx.shell_started_at_ms orelse 0, 100);
        } else if (std.mem.eql(u8, mod.name, "session")) {
            output_text = ctx.session_name;
        } else if (std.mem.eql(u8, mod.name, "randomdo")) {
            width += calcFormattedWidthMax(out.format, randomdo_mod.MAX_LEN);
            continue;
        } else {
            output_segs = ctx.renderSegment(mod.name);
        }
        if ((output_segs == null or output_segs.?.len == 0) and output_text.len == 0) continue;
        width += calcFormattedWidth(ctx, format_use, output_text, output_segs);
    }

    return width;
}

fn calcFormattedWidthMax(format: []const u8, output_max: u16) u16 {
    var width: u16 = 0;
    var i: usize = 0;
    while (i < format.len) {
        if (i + 7 <= format.len and std.mem.eql(u8, format[i..][0..7], "$output")) {
            width += output_max;
            i += 7;
        } else {
            const len = std.unicode.utf8ByteSequenceLength(format[i]) catch 1;
            const end = @min(i + len, format.len);
            width += vaxis.gwidth.gwidth(format[i..end], .unicode);
            i = end;
        }
    }
    return width;
}

pub fn countDisplayWidth(text: []const u8) u16 {
    return measureText(text);
}

// Measure text width in terminal cells (same logic as drawStyledText)
pub fn measureText(text: []const u8) u16 {
    return vaxis.gwidth.gwidth(text, .unicode);
}

pub fn calcFormattedWidth(ctx: *shp.Context, format: []const u8, output: []const u8, output_segs: ?[]const shp.Segment) u16 {
    const WidthState = struct {
        ctx: *shp.Context,
        width: u16 = 0,

        fn resolve(self: *@This(), builtin_name: []const u8) ?[]const shp.Segment {
            return self.ctx.renderSegment(builtin_name);
        }

        fn emit(self: *@This(), text: []const u8, _: shp.Style) !void {
            if (text.len == 0) return;
            self.width += measureText(text);
        }
    };

    var state: WidthState = .{ .ctx = ctx };
    segment_render.forEachFormattedRun(WidthState, &state, format, output, output_segs, .{}, WidthState.resolve, WidthState.emit) catch {};
    return state.width;
}

fn mergeStyle(base: shp.Style, override: shp.Style) shp.Style {
    return segment_render.mergeStyle(base, override);
}

fn shpStyleToVaxis(style: shp.Style) vaxis.Style {
    var out: vaxis.Style = .{};
    out.fg = style.fg.toVaxis();
    out.bg = style.bg.toVaxis();
    out.bold = style.bold;
    out.italic = style.italic;
    out.dim = style.dim;
    out.ul_style = if (style.underline) .single else .off;
    return out;
}

pub fn drawSegment(renderer: *Renderer, x: u16, y: u16, seg: shp.Segment, default_style: shp.Style) u16 {
    const style = segment_render.resolveSegmentStyle(default_style, seg.style);
    return drawStyledText(renderer, x, y, seg.text, style);
}

pub fn drawStyledText(renderer: *Renderer, start_x: u16, y: u16, text: []const u8, style: shp.Style) u16 {
    const screen_w = renderer.screenWidth();
    const screen_h = renderer.vx.screen.height;
    if (start_x >= screen_w or y >= screen_h) return start_x;

    // Status text often comes from short-lived buffers. Keep the printed text
    // in the frame arena so vaxis never sees dangling slices.
    const owned_text = renderer.frame_arena.allocator().dupe(u8, text) catch text;

    const row = renderer.vx.window().child(.{
        .x_off = @intCast(start_x),
        .y_off = @intCast(y),
        .width = screen_w - start_x,
        .height = 1,
    });

    const seg = vaxis.Segment{ .text = owned_text, .style = shpStyleToVaxis(style) };
    const res = row.print(&.{seg}, .{ .row_offset = 0, .col_offset = 0, .wrap = .none, .commit = true });
    return start_x + @min(res.col, row.width);
}
