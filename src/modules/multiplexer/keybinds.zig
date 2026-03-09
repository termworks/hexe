const std = @import("std");
const core = @import("core");
const vaxis = @import("vaxis");

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;

const input = @import("input.zig");
const loop_ipc = @import("loop_ipc.zig");
const keybinds_actions = @import("keybinds_actions.zig");
const key_translate = @import("key_translate.zig");
const main = @import("main.zig");

pub const BindWhen = core.Config.BindWhen;
pub const BindKey = core.Config.BindKey;
pub const BindKeyKind = core.Config.BindKeyKind;
pub const BindAction = core.Config.BindAction;
const PaneQuery = core.PaneQuery;
const FocusContext = @import("state.zig").FocusContext;
const LuaRuntime = core.LuaRuntime;
const CALLBACK_REF_PREFIX = "__hexe_cb_ref:";
threadlocal var last_focused_pane_uuid: ?[32]u8 = null;

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

fn handleBlockedPopup(popups: anytype, parsed_event: ?vaxis.Event) bool {
    if (parsed_event) |ev| {
        return input.handlePopupEvent(popups, ev);
    }
    return false;
}

pub fn forwardInputToFocusedPaneWithEvent(state: *State, bytes: []const u8, parsed_event: ?vaxis.Event) void {
    if (state.active_floating) |idx| {
        const fpane = state.floats.items[idx];
        const can_interact = if (fpane.parent_tab) |parent| parent == state.active_tab else true;
        if (fpane.isVisibleOnTab(state.active_tab) and can_interact) {
            if (fpane.popups.isBlocked()) {
                if (handleBlockedPopup(&fpane.popups, parsed_event)) {
                    loop_ipc.sendPopResponse(state);
                }
                state.needs_render = true;
                return;
            }
            if (fpane.isScrolled()) {
                fpane.scrollToBottom();
                state.needs_render = true;
            }
            state.writePaneInput(fpane, bytes);
            return;
        }
    }

    if (state.currentLayout().getFocusedPane()) |pane| {
        if (pane.popups.isBlocked()) {
            if (handleBlockedPopup(&pane.popups, parsed_event)) {
                loop_ipc.sendPopResponse(state);
            }
            state.needs_render = true;
            return;
        }
        if (pane.isScrolled()) {
            pane.scrollToBottom();
            state.needs_render = true;
        }
        state.writePaneInput(pane, bytes);
    }
}

/// Forward a key (with modifiers) to the focused pane as escape sequence.
pub fn forwardKeyToPane(state: *State, mods: u8, key: BindKey) void {
    forwardKeyToPaneWithText(state, mods, key, null);
}

pub fn forwardKeyToPaneWithText(state: *State, mods: u8, key: BindKey, text_codepoint: ?u21) void {
    var out: [64]u8 = undefined;

    // For plain Ctrl+letter keys, prefer canonical C0 control bytes.
    // This guarantees signals like Ctrl+C (ETX) reach apps reliably.
    if (mods == 2 and @as(BindKeyKind, key) == .char) {
        const ch = key.char;
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')) {
            const lc = std.ascii.toLower(ch);
            out[0] = (lc - 'a') + 1;
            forwardInputToFocusedPaneWithEvent(state, out[0..1], null);
            return;
        }
    }

    if (@as(BindKeyKind, key) == .char) {
        if (text_codepoint) |cp| {
            // For text-producing keys, prefer forwarding the produced codepoint
            // directly unless Ctrl/Super is involved.
            if ((mods & 2) == 0 and (mods & 8) == 0) {
                var n: usize = 0;
                if ((mods & 1) != 0) {
                    out[n] = 0x1b;
                    n += 1;
                }
                n += std.unicode.utf8Encode(cp, out[n..]) catch 0;
                if (n > 0) {
                    forwardInputToFocusedPaneWithEvent(state, out[0..n], null);
                    return;
                }
            }
        }
    }

    const target_pane = blk: {
        if (state.active_floating) |idx| {
            const fpane = state.floats.items[idx];
            const can_interact = if (fpane.parent_tab) |parent| parent == state.active_tab else true;
            if (fpane.isVisibleOnTab(state.active_tab) and can_interact) {
                break :blk fpane;
            }
        }

        if (state.currentLayout().getFocusedPane()) |pane| {
            break :blk pane;
        }

        break :blk null;
    };

    if (target_pane) |pane| {
        if (key_translate.encodeKey(&out, mods, key, text_codepoint, &pane.vt.terminal)) |bytes| {
            if (bytes.len > 0) {
                forwardInputToFocusedPaneWithEvent(state, bytes, null);
            }
        }
    }
}

/// Focus context used for key timer bookkeeping.
fn currentFocusContext(state: *State) FocusContext {
    return if (state.active_floating != null) .float else .split;
}

/// Build a PaneQuery from the current mux state for condition evaluation.
fn buildPaneQuery(state: *State) PaneQuery {
    const is_float = state.active_floating != null;
    const pane: ?*Pane = if (state.active_floating) |idx| blk: {
        if (idx < state.floats.items.len) break :blk state.floats.items[idx];
        break :blk @as(?*Pane, null);
    } else state.currentLayout().getFocusedPane();

    // Get foreground process name.
    const fg_proc: ?[]const u8 = blk: {
        if (pane) |p| {
            if (p.getFgProcess()) |proc_name| break :blk proc_name;
        }
        if (state.getCurrentFocusedUuid()) |uuid| {
            if (state.getPaneProc(uuid)) |pi| {
                if (pi.name) |n| break :blk n;
            }
        }
        break :blk null;
    };

    // Get float attributes if this is a float.
    var float_key: u8 = 0;
    var float_sticky = false;
    var float_exclusive = false;
    var float_per_cwd = false;
    var float_global = false;
    var float_isolated = false;
    var float_destroyable = false;

    if (pane) |p| {
        if (is_float) {
            float_key = p.float_key;
            float_sticky = p.sticky;
            // Look up float def for other attributes.
            if (float_key != 0) {
                if (state.getLayoutFloatByKey(float_key)) |fd| {
                    float_exclusive = fd.attributes.exclusive;
                    float_per_cwd = fd.attributes.per_cwd;
                    float_global = fd.attributes.global or fd.attributes.per_cwd;
                    float_isolated = fd.attributes.isolated;
                    float_destroyable = fd.attributes.destroy;
                }
            }
        }
    }

    return .{
        .is_float = is_float,
        .is_split = !is_float,
        .float_key = float_key,
        .float_sticky = float_sticky,
        .float_exclusive = float_exclusive,
        .float_per_cwd = float_per_cwd,
        .float_global = float_global,
        .float_isolated = float_isolated,
        .float_destroyable = float_destroyable,
        .tab_count = @intCast(state.tabs.items.len),
        .active_tab = @intCast(state.active_tab),
        .fg_process = fg_proc,
        .now_ms = @intCast(std.time.milliTimestamp()),
    };
}

/// Evaluate a bind's when condition against the current state.
fn matchesWhen(state: *State, when: ?core.config.WhenDef, query: *const PaneQuery) bool {
    if (when) |w| {
        return matchesLuaWhen(state, query, w);
    }
    return true; // No condition = always matches.
}

fn callbackIdFromCode(code: []const u8) ?i32 {
    if (!std.mem.startsWith(u8, code, CALLBACK_REF_PREFIX)) return null;
    return std.fmt.parseInt(i32, code[CALLBACK_REF_PREFIX.len..], 10) catch null;
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
    rt.lua.pushBoolean(!pane.floating);
    rt.lua.setField(-2, "focus_split");
    rt.lua.pushBoolean(pane.floating);
    rt.lua.setField(-2, "focus_float");
    rt.lua.pushBoolean(!pane.floating);
    rt.lua.setField(-2, "is_split");
    rt.lua.pushBoolean(pane.floating);
    rt.lua.setField(-2, "is_float");
    rt.lua.pushBoolean(pane.floating);
    rt.lua.setField(-2, "floating");

    rt.lua.pushInteger(pane.float_key);
    rt.lua.setField(-2, "float_key");
    rt.lua.pushBoolean(pane.sticky);
    rt.lua.setField(-2, "float_sticky");

    var float_exclusive = false;
    var float_per_cwd = false;
    var float_global = pane.parent_tab == null;
    var float_isolated = false;
    var float_destroyable = false;
    if (pane.float_key != 0) {
        if (state.getLayoutFloatByKey(pane.float_key)) |fd| {
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

fn populateWhenLuaContext(state: *State, rt: *LuaRuntime, query: *const PaneQuery) void {
    rt.lua.createTable(0, 20);

    rt.lua.pushBoolean(query.is_split);
    rt.lua.setField(-2, "focus_split");
    rt.lua.pushBoolean(query.is_float);
    rt.lua.setField(-2, "focus_float");

    rt.lua.pushBoolean(query.is_float);
    rt.lua.setField(-2, "is_float");
    rt.lua.pushBoolean(query.is_split);
    rt.lua.setField(-2, "is_split");
    rt.lua.pushBoolean(query.alt_screen);
    rt.lua.setField(-2, "alt_screen");
    rt.lua.pushBoolean(query.shell_running);
    rt.lua.setField(-2, "shell_running");
    rt.lua.pushBoolean(query.fg_process != null);
    rt.lua.setField(-2, "process_running");
    rt.lua.pushBoolean(query.is_float and query.float_key == 0);
    rt.lua.setField(-2, "adhoc_float");

    rt.lua.pushInteger(query.float_key);
    rt.lua.setField(-2, "float_key");
    rt.lua.pushInteger(query.tab_count);
    rt.lua.setField(-2, "tab_count");
    rt.lua.pushInteger(query.active_tab);
    rt.lua.setField(-2, "active_tab");
    rt.lua.pushInteger(query.jobs);
    rt.lua.setField(-2, "jobs");
    rt.lua.pushInteger(@intCast(query.now_ms));
    rt.lua.setField(-2, "now_ms");

    if (query.fg_process) |p| {
        _ = rt.lua.pushString(p);
        rt.lua.setField(-2, "fg_process");
        _ = rt.lua.pushString(p);
        rt.lua.setField(-2, "process_name");
    }
    if (query.fg_pid) |pid| {
        rt.lua.pushInteger(pid);
        rt.lua.setField(-2, "fg_pid");
    }

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

    const focused_uuid = state.getCurrentFocusedUuid();
    const previous_focused_uuid = last_focused_pane_uuid;
    if (focused_uuid) |fu| {
        if (previous_focused_uuid == null or !std.mem.eql(u8, &previous_focused_uuid.?, &fu)) {
            last_focused_pane_uuid = fu;
        }
    }
    var pane_index: usize = 1;

    for (state.tabs.items, 0..) |*tab, tab_idx| {
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

    for (state.floats.items) |pane| {
        const is_focused = if (focused_uuid) |fu|
            std.mem.eql(u8, &pane.uuid, &fu)
        else
            false;
        const tab_idx = pane.parent_tab orelse state.active_tab;
        appendPaneApiEntry(rt, state, pane, is_focused, tab_idx, pane_index, null);
        pane_index += 1;
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
    rt.lua.setGlobal("ctx");

    const status_api =
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
    const status_api_z = rt.allocator.dupeZ(u8, status_api) catch return;
    defer rt.allocator.free(status_api_z);
    rt.lua.loadString(status_api_z) catch return;
    rt.lua.protectedCall(.{ .args = 0, .results = 0 }) catch {
        rt.lua.pop(1);
        return;
    };

    rt.lua.setGlobal("ctx");
}

fn matchesLuaWhen(state: *State, query: *const PaneQuery, w: core.config.WhenDef) bool {
    const code = w.lua orelse return true;
    const trace_start_ms = std.time.milliTimestamp();
    const callback_id = callbackIdFromCode(code) orelse {
        traceLuaEval("keybind.when", code, false, trace_start_ms);
        return false;
    };
    const rt = state.config._lua_runtime orelse {
        traceLuaEval("keybind.when", code, false, trace_start_ms);
        return false;
    };

    populateWhenLuaContext(state, rt, query);

    if (!core.lua_runtime.pushRegisteredCallback(rt, callback_id)) {
        traceLuaEval("keybind.when", code, false, trace_start_ms);
        return false;
    }
    _ = rt.lua.getGlobal("ctx") catch {
        rt.lua.pop(2);
        traceLuaEval("keybind.when", code, false, trace_start_ms);
        return false;
    };

    rt.lua.protectedCall(.{ .args = 1, .results = 1 }) catch {
        rt.lua.pop(2);
        traceLuaEval("keybind.when", code, false, trace_start_ms);
        return false;
    };
    defer {
        rt.lua.pop(1); // result
        rt.lua.pop(1); // callback table
    }

    if (rt.lua.typeOf(-1) != .boolean) {
        traceLuaEval("keybind.when", code, false, trace_start_ms);
        return false;
    }
    const ok = rt.lua.toBoolean(-1);
    traceLuaEval("keybind.when", code, true, trace_start_ms);
    return ok;
}

fn keyEq(a: BindKey, b: BindKey) bool {
    if (@as(BindKeyKind, a) != @as(BindKeyKind, b)) return false;
    if (@as(BindKeyKind, a) == .char) return a.char == b.char;
    return true;
}

fn findBestBind(state: *State, mods: u8, key: BindKey, on: BindWhen, allow_only_tabs: bool, query: *const PaneQuery) ?core.Config.Bind {
    const cfg = &state.config;

    var best: ?core.Config.Bind = null;
    var best_score: u8 = 0;

    for (cfg.input.binds, 0..) |b, idx| {
        _ = idx;

        if (b.on != on) continue;
        if (b.mods != mods) continue;
        if (!keyEq(b.key, key)) continue;
        const when_match = matchesWhen(state, b.when, query);
        if (!when_match) continue;

        if (allow_only_tabs) {
            if (b.action != .tab_next and b.action != .tab_prev) continue;
        }

        var score: u8 = 0;
        if (b.when != null) score += 2; // Conditional binds are more specific.
        if (b.hold_ms != null) score += 1;

        if (best == null or score > best_score) {
            best = b;
            best_score = score;
        }
    }

    return best;
}

fn cancelTimer(state: *State, kind: State.PendingKeyTimerKind, mods: u8, key: BindKey) void {
    var i: usize = 0;
    while (i < state.key_timers.items.len) {
        const t = state.key_timers.items[i];
        if (t.kind == kind and t.mods == mods and keyEq(t.key, key)) {
            _ = state.key_timers.orderedRemove(i);
            continue;
        }
        i += 1;
    }
}

fn findStoredModsForKey(state: *State, key: BindKey, focus_ctx: FocusContext) ?u8 {
    // When a terminal reports repeat/release with missing modifier bits, we still
    // need to resolve the chord using the modifiers from the original press.
    for (state.key_timers.items) |t| {
        if (!keyEq(t.key, key)) continue;
        if (t.focus_ctx != focus_ctx) continue;
        switch (t.kind) {
            .tap_pending, .hold, .hold_fired, .repeat_wait, .repeat_active, .repeat_locked, .delayed_press => return t.mods,
        }
    }
    return null;
}

fn scheduleTimer(state: *State, kind: State.PendingKeyTimerKind, deadline_ms: i64, mods: u8, key: BindKey, action: BindAction, focus_ctx: FocusContext) void {
    scheduleTimerFull(state, kind, deadline_ms, mods, key, action, focus_ctx, 0, false);
}

fn scheduleTimerWithStart(state: *State, kind: State.PendingKeyTimerKind, deadline_ms: i64, mods: u8, key: BindKey, action: BindAction, focus_ctx: FocusContext, press_start_ms: i64) void {
    scheduleTimerFull(state, kind, deadline_ms, mods, key, action, focus_ctx, press_start_ms, false);
}

fn scheduleTimerFull(state: *State, kind: State.PendingKeyTimerKind, deadline_ms: i64, mods: u8, key: BindKey, action: BindAction, focus_ctx: FocusContext, press_start_ms: i64, is_repeat: bool) void {
    state.key_timers.append(state.allocator, .{
        .kind = kind,
        .deadline_ms = deadline_ms,
        .mods = mods,
        .key = key,
        .action = action,
        .focus_ctx = focus_ctx,
        .press_start_ms = press_start_ms,
        .is_repeat = is_repeat,
    }) catch {};
}

pub fn processKeyTimers(state: *State, now_ms: i64) void {
    var i: usize = 0;
    while (i < state.key_timers.items.len) {
        const t = state.key_timers.items[i];
        if (t.kind == .hold_fired or t.kind == .repeat_wait or t.kind == .repeat_active or t.kind == .repeat_locked) {
            i += 1;
            continue;
        }
        if (t.deadline_ms > now_ms) {
            i += 1;
            continue;
        }

        // Hold timers need to survive until release so we can decide whether to
        // forward the key to the pane.
        if (t.kind == .hold) {
            // Enforce context at fire time.
            if (t.focus_ctx == currentFocusContext(state)) {
                _ = dispatchAction(state, t.action);
            }
            state.key_timers.items[i].kind = .hold_fired;
            state.key_timers.items[i].deadline_ms = std.math.maxInt(i64);
            i += 1;
            continue;
        }

        _ = state.key_timers.orderedRemove(i);

        // Enforce context at fire time.
        if (t.focus_ctx != currentFocusContext(state)) {
            continue;
        }

        switch (t.kind) {
            .tap_pending => {
                // Quick release timer expired without same key pressed again = TAP
                main.debugLog("tap_pending expired: firing action", .{});
                _ = dispatchAction(state, t.action);
            },
            .delayed_press => {
                _ = dispatchAction(state, t.action);
            },
            .hold_fired => {},
            .repeat_wait => {},
            .repeat_active => {},
            .repeat_locked => {},
            .hold => unreachable,
        }
    }
}

pub fn handleKeyEvent(state: *State, mods: u8, key: BindKey, when: BindWhen, allow_only_tabs: bool) bool {
    const cfg = &state.config;
    const query = buildPaneQuery(state);
    const focus_ctx = currentFocusContext(state);
    const now_ms = std.time.milliTimestamp();

    // Modifier latching: repeat/release may arrive with mods=0 if user
    // released the modifier before the primary key. Use stored mods.
    const mods_eff: u8 = blk: {
        if (when == .press) break :blk mods;
        if (mods != 0) break :blk mods;
        break :blk findStoredModsForKey(state, key, focus_ctx) orelse mods;
    };

    return switch (when) {
        .release => handleReleaseEvent(state, cfg, &query, mods_eff, key, allow_only_tabs, focus_ctx, now_ms),
        .repeat => handleRepeatEvent(state, &query, mods_eff, key, allow_only_tabs, focus_ctx, now_ms),
        .press => handlePressEvent(state, cfg, &query, mods_eff, key, allow_only_tabs, focus_ctx, now_ms),
        .hold => false,
    };
}

fn consumeHoldFiredTimer(state: *State, mods_eff: u8, key: BindKey) bool {
    var had_hold_fired = false;
    var i: usize = 0;
    while (i < state.key_timers.items.len) {
        const t = state.key_timers.items[i];
        if (t.kind == .hold_fired and t.mods == mods_eff and keyEq(t.key, key)) {
            _ = state.key_timers.orderedRemove(i);
            had_hold_fired = true;
            continue;
        }
        i += 1;
    }
    return had_hold_fired;
}

const HoldPendingInfo = struct {
    had_pending: bool = false,
    press_start_ms: i64 = 0,
    was_repeat: bool = false,
};

fn consumeHoldPendingTimer(state: *State, mods_eff: u8, key: BindKey) HoldPendingInfo {
    var info: HoldPendingInfo = .{};
    var i: usize = 0;
    while (i < state.key_timers.items.len) {
        const t = state.key_timers.items[i];
        if (t.kind == .hold and t.mods == mods_eff and keyEq(t.key, key)) {
            info.press_start_ms = t.press_start_ms;
            info.was_repeat = t.is_repeat;
            _ = state.key_timers.orderedRemove(i);
            info.had_pending = true;
            continue;
        }
        i += 1;
    }
    return info;
}

fn handleReleaseEvent(state: *State, cfg: *const core.Config, query: *const PaneQuery, mods_eff: u8, key: BindKey, allow_only_tabs: bool, focus_ctx: FocusContext, now_ms: i64) bool {
    if (consumeHoldFiredTimer(state, mods_eff, key)) return true;

    const pending = consumeHoldPendingTimer(state, mods_eff, key);

    cancelTimer(state, .repeat_active, mods_eff, key);

    if (pending.had_pending) {
        const duration_ms = now_ms - pending.press_start_ms;
        main.debugLog("release: mods_eff={d} key={any} duration={d}ms was_repeat={}", .{ mods_eff, key, duration_ms, pending.was_repeat });

        if (pending.was_repeat) {
            main.debugLog("release: was_repeat=true, not firing tap", .{});
            return true;
        }

        const maybe_bind = findBestBind(state, mods_eff, key, .press, allow_only_tabs, query);
        if (duration_ms >= cfg.input.tap_ms) {
            main.debugLog("release: TAP (duration >= {d}ms)", .{cfg.input.tap_ms});
            if (maybe_bind) |b| {
                _ = dispatchBindWithMode(state, b, mods_eff, key);
            } else {
                forwardKeyToPane(state, mods_eff, key);
            }
        } else {
            main.debugLog("release: quick (<{d}ms), scheduling tap_pending", .{cfg.input.tap_ms});
            if (maybe_bind) |b| {
                scheduleTimer(state, .tap_pending, now_ms + cfg.input.tap_ms, mods_eff, key, b.action, focus_ctx);
            } else {
                forwardKeyToPane(state, mods_eff, key);
            }
        }
        return true;
    }

    if (findBestBind(state, mods_eff, key, .release, allow_only_tabs, query)) |b| {
        return dispatchBindWithMode(state, b, mods_eff, key);
    }
    return true;
}

fn touchRepeatActiveTimer(state: *State, mods_eff: u8, key: BindKey, focus_ctx: FocusContext, now_ms: i64) void {
    const repeat_timeout: i64 = core.constants.Timing.key_repeat_timeout;
    var found = false;
    for (state.key_timers.items) |*t| {
        if (t.kind == .repeat_active and t.mods == mods_eff and keyEq(t.key, key)) {
            t.deadline_ms = now_ms + repeat_timeout;
            found = true;
            break;
        }
    }
    if (!found) {
        scheduleTimer(state, .repeat_active, now_ms + repeat_timeout, mods_eff, key, .mux_quit, focus_ctx);
    }
}

fn handleRepeatEvent(state: *State, query: *const PaneQuery, mods_eff: u8, key: BindKey, allow_only_tabs: bool, focus_ctx: FocusContext, now_ms: i64) bool {
    cancelTimer(state, .hold, mods_eff, key);
    cancelTimer(state, .hold_fired, mods_eff, key);
    touchRepeatActiveTimer(state, mods_eff, key, focus_ctx, now_ms);

    if (findBestBind(state, mods_eff, key, .repeat, allow_only_tabs, query)) |b| {
        return dispatchBindWithMode(state, b, mods_eff, key);
    }
    if (mods_eff != 0) {
        const has_press = findBestBind(state, mods_eff, key, .press, false, query) != null;
        const has_hold = findBestBind(state, mods_eff, key, .hold, false, query) != null;
        const has_release = findBestBind(state, mods_eff, key, .release, false, query) != null;
        if (has_press or has_hold or has_release) return true;
        return false;
    }
    return false;
}

fn isRepeatLockedForKey(state: *State, mods_eff: u8, key: BindKey) bool {
    var in_repeat_mode = false;
    var i: usize = 0;
    while (i < state.key_timers.items.len) {
        const t = state.key_timers.items[i];
        if (t.kind == .repeat_locked) {
            if (t.mods == mods_eff and keyEq(t.key, key)) {
                in_repeat_mode = true;
                main.debugLog("press: repeat_locked for same key, still REPEAT", .{});
                i += 1;
            } else {
                main.debugLog("press: repeat_locked for different key, exiting repeat mode", .{});
                _ = state.key_timers.orderedRemove(i);
            }
            continue;
        }
        i += 1;
    }
    return in_repeat_mode;
}

fn consumeTapPending(state: *State, mods_eff: u8, key: BindKey) bool {
    var had_tap_pending = false;
    var i: usize = 0;
    while (i < state.key_timers.items.len) {
        const t = state.key_timers.items[i];
        if (t.kind == .tap_pending and t.mods == mods_eff and keyEq(t.key, key)) {
            _ = state.key_timers.orderedRemove(i);
            had_tap_pending = true;
            main.debugLog("press: found tap_pending, entering REPEAT mode", .{});
            continue;
        }
        i += 1;
    }
    return had_tap_pending;
}

fn handlePressEvent(state: *State, cfg: *const core.Config, query: *const PaneQuery, mods_eff: u8, key: BindKey, allow_only_tabs: bool, focus_ctx: FocusContext, now_ms: i64) bool {
    if (mods_eff == 3 and @as(BindKeyKind, key) == .char) {
        main.debugLog("press: Ctrl+Alt+{c} (0x{x})", .{ key.char, key.char });
    }

    const in_repeat_mode = isRepeatLockedForKey(state, mods_eff, key);
    const had_tap_pending = consumeTapPending(state, mods_eff, key);

    if (had_tap_pending or in_repeat_mode) {
        cancelTimer(state, .hold, mods_eff, key);
        scheduleTimerFull(state, .hold, std.math.maxInt(i64), mods_eff, key, .mux_quit, focus_ctx, now_ms, true);
        if (had_tap_pending) {
            scheduleTimer(state, .repeat_locked, std.math.maxInt(i64), mods_eff, key, .mux_quit, focus_ctx);
        }
        return true;
    }

    if (mods_eff != 0) {
        const press_bind = findBestBind(state, mods_eff, key, .press, allow_only_tabs, query);
        const has_press = press_bind != null;
        const has_hold = findBestBind(state, mods_eff, key, .hold, allow_only_tabs, query) != null;
        const has_release = findBestBind(state, mods_eff, key, .release, allow_only_tabs, query) != null;

        if (!has_press and !has_hold and !has_release) return false;

        if (press_bind) |pb| {
            if (!has_hold and !has_release) {
                return dispatchBindWithMode(state, pb, mods_eff, key);
            }
        }

        main.debugLog("press defer: mods_eff={d} key={any}", .{ mods_eff, key });
        if (findBestBind(state, mods_eff, key, .hold, allow_only_tabs, query)) |hb| {
            const hold_ms = hb.hold_ms orelse cfg.input.hold_ms;
            cancelTimer(state, .hold, mods_eff, key);
            cancelTimer(state, .hold_fired, mods_eff, key);
            scheduleTimerWithStart(state, .hold, now_ms + hold_ms, mods_eff, key, hb.action, focus_ctx, now_ms);
        } else {
            cancelTimer(state, .hold, mods_eff, key);
            scheduleTimerWithStart(state, .hold, std.math.maxInt(i64), mods_eff, key, .mux_quit, focus_ctx, now_ms);
        }
        return true;
    }

    if (findBestBind(state, mods_eff, key, .press, allow_only_tabs, query)) |b| {
        return dispatchBindWithMode(state, b, mods_eff, key);
    }
    return false;
}

/// Dispatch a bind action respecting its mode setting.
/// Returns true if key should be consumed, false if it should passthrough.
fn dispatchBindWithMode(state: *State, bind: core.Config.Bind, mods: u8, key: BindKey) bool {
    switch (bind.mode) {
        .passthrough_only => {
            // Don't execute action, just pass the key through
            forwardKeyToPane(state, mods, key);
            return true; // Return true so we don't double-forward
        },
        .act_and_passthrough => {
            // Execute action AND pass the key to pane
            _ = dispatchAction(state, bind.action);
            forwardKeyToPane(state, mods, key);
            return true; // Return true so we don't double-forward
        },
        .act_and_consume => {
            // Execute action and consume (default behavior)
            return dispatchAction(state, bind.action);
        },
    }
}

fn dispatchAction(state: *State, action: BindAction) bool {
    return keybinds_actions.dispatchAction(state, action);
}
