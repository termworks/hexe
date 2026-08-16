const std = @import("std");

/// How long a fired hold-timer stays parked waiting for its key release before
/// it is reaped. See the park site below (PLAN.md F-10).
const HOLD_PARK_TTL_MS: i64 = 5 * 60 * 1000;
const core = @import("core");
const vaxis = @import("vaxis");
const log = std.log.scoped(.terminal_keybinds);

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;
const lua_api = @import("lua_api.zig");

const input = @import("input.zig");
const loop_ipc = @import("loop_ipc.zig");
const keybinds_actions = @import("keybinds_actions.zig");
const key_translate = @import("key_translate.zig");
const fast_path = @import("fast_path.zig");
const main = @import("main.zig");

pub const BindWhen = core.Config.BindWhen;
pub const BindKey = core.Config.BindKey;
pub const BindKeyKind = core.Config.BindKeyKind;
pub const BindAction = core.Config.BindAction;
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
    if (state.activeFloatingIndex()) |idx| {
        const fpane = state.view.float_views.items[idx];
        const can_interact = if (state.paneParentTab(fpane)) |parent| parent == state.activeTabIndex() else true;
        if (state.paneVisibleOnTab(fpane, state.activeTabIndex()) and can_interact) {
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
        // Broadcast mode (pane.sync_toggle): fan the same input out to every
        // split pane in the active tab, tmux `synchronize-panes` style.
        if (state.sync_input) {
            var it = state.currentLayout().splitIterator();
            while (it.next()) |p| {
                if (p.*.isScrolled()) p.*.scrollToBottom();
                state.writePaneInput(p.*, bytes);
            }
            return;
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

    const target_pane = blk: {
        if (state.activeFloatingIndex()) |idx| {
            const fpane = state.view.float_views.items[idx];
            const can_interact = if (state.paneParentTab(fpane)) |parent| parent == state.activeTabIndex() else true;
            if (state.paneVisibleOnTab(fpane, state.activeTabIndex()) and can_interact) {
                break :blk fpane;
            }
        }

        if (state.currentLayout().getFocusedPane()) |pane| {
            break :blk pane;
        }

        break :blk null;
    };

    if (target_pane) |pane| {
        const kitty_flags: u8 = @intCast(pane.vt.terminal.screens.active.kitty_keyboard.current().int());
        if (fast_path.fastPathBytes(&out, mods, key, text_codepoint, kitty_flags)) |n| {
            forwardInputToFocusedPaneWithEvent(state, out[0..n], null);
            return;
        }
        if (key_translate.encodeKey(&out, mods, key, text_codepoint, &pane.vt.terminal)) |bytes| {
            if (bytes.len > 0) {
                forwardInputToFocusedPaneWithEvent(state, bytes, null);
            }
        }
    }
}

/// Focus context used for key timer bookkeeping.
fn currentFocusContext(state: *State) FocusContext {
    return if (state.activeFloatingIndex() != null) .float else .split;
}

/// Evaluate a bind's condition.
///
/// A condition is a Lua predicate invoked with the live query API bound. The
/// old path built a whole context table first — every pane in every tab, the
/// entire process environment, and a compiled Lua chunk to define `ctx.pane` —
/// on every evaluation of every candidate bind. Now the callback is handed
/// accessor functions and pays only for what it reads.
fn matchesWhen(state: *State, when: ?[]const u8) bool {
    const code = when orelse return true; // No condition = always matches.
    const trace_start_ms = std.time.milliTimestamp();

    const callback_id = callbackIdFromCode(code) orelse {
        traceLuaEval("keybind.when", code, false, trace_start_ms);
        return false;
    };
    const rt = state.config._lua_runtime orelse {
        traceLuaEval("keybind.when", code, false, trace_start_ms);
        return false;
    };

    // The accessors read this pointer; it must not outlive the call.
    const scope = lua_api.pushLiveState(rt, state, .predicate);
    defer lua_api.popLiveState(rt, scope);

    if (!core.lua_runtime.pushRegisteredCallback(rt, callback_id)) {
        traceLuaEval("keybind.when", code, false, trace_start_ms);
        return false;
    }
    if (!lua_api.pushCallbackContext(rt)) {
        rt.lua.pop(2);
        traceLuaEval("keybind.when", code, false, trace_start_ms);
        return false;
    }

    rt.lua.protectedCall(.{ .args = 1, .results = 1 }) catch {
        rt.lua.pop(2);
        traceLuaEval("keybind.when", code, false, trace_start_ms);
        return false;
    };
    defer {
        rt.lua.pop(1); // result
        rt.lua.pop(1); // callback table
    }

    // Lua truthiness, not "is a boolean": the previous check rejected every
    // non-boolean, so `when = function() return hexe.pane() end` was false.
    const ty = rt.lua.typeOf(-1);
    const ok = switch (ty) {
        .nil, .none => false,
        .boolean => rt.lua.toBoolean(-1),
        else => true,
    };
    traceLuaEval("keybind.when", code, true, trace_start_ms);
    return ok;
}

fn callbackIdFromCode(code: []const u8) ?i32 {
    if (!std.mem.startsWith(u8, code, CALLBACK_REF_PREFIX)) return null;
    return std.fmt.parseInt(i32, code[CALLBACK_REF_PREFIX.len..], 10) catch |err| {
        log.warn("failed to parse keybind callback id: {}", .{err});
        return null;
    };
}

fn keyEq(a: BindKey, b: BindKey) bool {
    if (@as(BindKeyKind, a) != @as(BindKeyKind, b)) return false;
    if (@as(BindKeyKind, a) == .char) return a.char == b.char;
    return true;
}

fn findBestBind(state: *State, mods: u8, key: BindKey, on: BindWhen, allow_only_tabs: bool) ?core.Config.Bind {
    const cfg = &state.config;

    var best: ?core.Config.Bind = null;
    var best_score: u8 = 0;

    for (cfg.input.binds, 0..) |b, idx| {
        _ = idx;

        if (b.on != on) continue;
        if (b.mods != mods) continue;
        if (!keyEq(b.key, key)) continue;
        const when_match = matchesWhen(state, b.when);
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
    }) catch |err| {
        core.logging.logError("terminal", "failed to schedule key timer", err);
    };
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
            // Park with a TTL, not forever (PLAN.md F-10). A `hold_fired`
            // entry exists only so the matching RELEASE can decide whether to
            // forward the key to the pane — but releases are not guaranteed to
            // arrive (a terminal that ignores `report_events`, or a capability
            // probe that timed out), and `maxInt` meant such an entry lived for
            // the rest of the process while four functions walked the list on
            // every key event. The expiry loop below already removes a
            // `hold_fired` whose deadline passed and does nothing else with it,
            // so a deadline is all that is needed to bound the list.
            //
            // The TTL is deliberately far longer than any real key hold: the
            // only cost of expiring one early is a single stray forward of that
            // key, whereas too short a TTL would break genuine long holds.
            state.key_timers.items[i].deadline_ms = now_ms + HOLD_PARK_TTL_MS;
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
            .hold => {
                core.logging.warn("terminal", "key timer sweep encountered stale hold timer after deadline processing", .{});
            },
        }
    }
}

pub fn handleKeyEvent(state: *State, mods: u8, key: BindKey, when: BindWhen, allow_only_tabs: bool) bool {
    const cfg = &state.config;
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
        .release => handleReleaseEvent(state, cfg, mods_eff, key, allow_only_tabs, focus_ctx, now_ms),
        .repeat => handleRepeatEvent(state, mods_eff, key, allow_only_tabs, focus_ctx, now_ms),
        .press => handlePressEvent(state, cfg, mods_eff, key, allow_only_tabs, focus_ctx, now_ms),
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

fn handleReleaseEvent(state: *State, cfg: *const core.Config, mods_eff: u8, key: BindKey, allow_only_tabs: bool, focus_ctx: FocusContext, now_ms: i64) bool {
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

        const maybe_bind = findBestBind(state, mods_eff, key, .press, allow_only_tabs);
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

    if (findBestBind(state, mods_eff, key, .release, allow_only_tabs)) |b| {
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

fn handleRepeatEvent(state: *State, mods_eff: u8, key: BindKey, allow_only_tabs: bool, focus_ctx: FocusContext, now_ms: i64) bool {
    cancelTimer(state, .hold, mods_eff, key);
    cancelTimer(state, .hold_fired, mods_eff, key);
    touchRepeatActiveTimer(state, mods_eff, key, focus_ctx, now_ms);

    if (findBestBind(state, mods_eff, key, .repeat, allow_only_tabs)) |b| {
        return dispatchBindWithMode(state, b, mods_eff, key);
    }
    if (mods_eff != 0) {
        const has_press = findBestBind(state, mods_eff, key, .press, false) != null;
        const has_hold = findBestBind(state, mods_eff, key, .hold, false) != null;
        const has_release = findBestBind(state, mods_eff, key, .release, false) != null;
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

fn handlePressEvent(state: *State, cfg: *const core.Config, mods_eff: u8, key: BindKey, allow_only_tabs: bool, focus_ctx: FocusContext, now_ms: i64) bool {
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
        const press_bind = findBestBind(state, mods_eff, key, .press, allow_only_tabs);
        const has_press = press_bind != null;
        const has_hold = findBestBind(state, mods_eff, key, .hold, allow_only_tabs) != null;
        const has_release = findBestBind(state, mods_eff, key, .release, allow_only_tabs) != null;

        if (!has_press and !has_hold and !has_release) return false;

        if (press_bind) |pb| {
            if (!has_hold and !has_release) {
                return dispatchBindWithMode(state, pb, mods_eff, key);
            }
        }

        main.debugLog("press defer: mods_eff={d} key={any}", .{ mods_eff, key });
        if (findBestBind(state, mods_eff, key, .hold, allow_only_tabs)) |hb| {
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

    if (findBestBind(state, mods_eff, key, .press, allow_only_tabs)) |b| {
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
