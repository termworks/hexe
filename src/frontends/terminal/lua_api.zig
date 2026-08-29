//! The live query API exposed to Lua callbacks.
//!
//! Predicates (`when = function(ctx) ... end`) run synchronously on the input
//! path, so the old approach — build one enormous context table per evaluation
//! — put the whole cost on every keystroke: a full `getEnvMap` copy, a table
//! per pane across every tab, three index tables, and a Lua source chunk
//! compiled and executed to define `ctx.pane`. A predicate testing one boolean
//! paid all of it.
//!
//! Here the callback receives accessor FUNCTIONS instead. Nothing is computed
//! until the predicate asks for it, so `return hexe.pane().process == "nvim"`
//! builds exactly one small table.
//!
//! **Rule for anything added here:** read only `State` fields, `Pane`/VT struct
//! reads, and `SessionProjection` caches. Never call the blocking half of
//! `FrontendRuntime`/`SesClient` — `getPaneCwdSync`, `getPaneInfoSnapshot`,
//! `getPaneAux`, `probePaneExistence`, `listSessions`, `getReliableCwd`,
//! `stickyFloatDir` and friends are synchronous write-then-read on the shared
//! ctl fd with a 10s ceiling. A predicate that called one would freeze the
//! terminal for ten seconds PER KEYSTROKE against a wedged daemon, and the sync
//! reader re-queues interleaved async pushes while it waits. If a value is only
//! reachable over IPC, it does not belong in this API.
//!
//! The accessors need the live `*State` at CALL time, not at config-load time.
//! It is published as light userdata in the Lua registry for the duration of a
//! single callback (see `withLiveState`) and revoked immediately after, so a
//! closure that squirrels away an accessor and calls it later gets nil rather
//! than a dangling pointer.

const std = @import("std");
const core = @import("core");
const drawings_mod = @import("drawings.zig");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaState = zlua.LuaState;
const LuaRuntime = core.LuaRuntime;

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;
const api_bridge = core.api_bridge;
const keybinds_actions = @import("keybinds_actions.zig");
const loop_actions = @import("loop_actions.zig");
const mouse_selection = @import("mouse_selection.zig");
const ghostty = @import("ghostty-vt");
const tab_switch = @import("tab_switch.zig");

const log = std.log.scoped(.lua_api);

/// Registry slot holding the `*State` that accessors read. Present only while a
/// callback is running.
const LIVE_STATE_KEY = "_hexe_live_state";

/// What was published before this scope, so it can be put back.
///
/// These nest: a Lua action calls `ctx.focus()`, which syncs focus, which emits
/// `pane_focus_changed`, which publishes state for the handler and then has to
/// restore — not clear — or every accessor after that call in the OUTER
/// callback goes dead. A plain set/clear pair silently broke exactly that.
pub const Scope = struct { prev: ?*State, prev_kind: i64 };

/// Where the callback is running from.
///
/// A predicate runs on the input path for every candidate bind of every
/// keypress, so it must not do anything that blocks or costs much. A handler
/// (a keybind action, an event handler) runs once in response to something the
/// user did, and may. Verbs that block check this rather than trusting a
/// comment in the docs.
pub const Kind = enum(i64) { predicate = 1, handler = 2 };

const SCOPE_KIND_KEY = "_hexe_live_scope";

pub fn pushLiveState(rt: *LuaRuntime, state: *State, kind: Kind) Scope {
    const prev = liveState(rt.lua);
    const prev_kind = scopeKind(rt.lua);
    rt.lua.pushLightUserdata(state);
    rt.lua.setField(zlua.registry_index, LIVE_STATE_KEY);
    rt.lua.pushInteger(@intFromEnum(kind));
    rt.lua.setField(zlua.registry_index, SCOPE_KIND_KEY);
    return .{ .prev = prev, .prev_kind = prev_kind };
}

pub fn popLiveState(rt: *LuaRuntime, scope: Scope) void {
    if (scope.prev) |prev| {
        rt.lua.pushLightUserdata(prev);
    } else {
        rt.lua.pushNil();
    }
    rt.lua.setField(zlua.registry_index, LIVE_STATE_KEY);
    rt.lua.pushInteger(scope.prev_kind);
    rt.lua.setField(zlua.registry_index, SCOPE_KIND_KEY);
}

fn scopeKind(lua: *Lua) i64 {
    _ = lua.getField(zlua.registry_index, SCOPE_KIND_KEY);
    defer lua.pop(1);
    if (lua.typeOf(-1) != .number) return 0;
    return lua.toInteger(-1) catch 0;
}

/// True when the current callback may do expensive or blocking work.
fn inHandlerScope(lua: *Lua) bool {
    return scopeKind(lua) == @intFromEnum(Kind.handler);
}

fn liveState(lua: *Lua) ?*State {
    _ = lua.getField(zlua.registry_index, LIVE_STATE_KEY);
    defer lua.pop(1);
    if (lua.typeOf(-1) != .light_userdata) return null;
    const ptr = lua.toPointer(-1) catch return null;
    return @ptrFromInt(@intFromPtr(ptr));
}

// ─── small push helpers ─────────────────────────────────────────────────────

fn setStr(lua: *Lua, name: [:0]const u8, value: []const u8) void {
    _ = lua.pushString(value);
    lua.setField(-2, name);
}

fn setOptStr(lua: *Lua, name: [:0]const u8, value: ?[]const u8) void {
    if (value) |v| setStr(lua, name, v) else {
        lua.pushNil();
        lua.setField(-2, name);
    }
}

fn setBool(lua: *Lua, name: [:0]const u8, value: bool) void {
    lua.pushBoolean(value);
    lua.setField(-2, name);
}

fn setInt(lua: *Lua, name: [:0]const u8, value: i64) void {
    lua.pushInteger(value);
    lua.setField(-2, name);
}

fn setOptInt(lua: *Lua, name: [:0]const u8, value: ?i64) void {
    if (value) |v| setInt(lua, name, v) else {
        lua.pushNil();
        lua.setField(-2, name);
    }
}

// ─── pane ───────────────────────────────────────────────────────────────────

/// Push one pane as a table. Every field is a plain read off State or the
/// pane's own VT — no IPC, no /proc walk — so this stays safe on the input path.
pub fn pushPaneTable(lua: *Lua, state: *State, pane: *Pane, pane_index: usize) void {
    lua.createTable(0, 48);

    const is_float = state.paneIsFloating(pane);
    const focused = if (state.getCurrentFocusedUuid()) |fu|
        std.mem.eql(u8, &pane.uuid, &fu)
    else
        false;

    setStr(lua, "uuid", pane.uuid[0..]);
    setInt(lua, "id", pane.id);
    setInt(lua, "index", @intCast(pane_index));
    setOptStr(lua, "name", state.paneName(pane.uuid));

    // Identity / role
    setBool(lua, "focused", focused);
    setOptInt(lua, "pane_id", if (pane.getPaneId()) |pid| @intCast(pid) else null);
    // `pane.zoom` is a bindable action; without this a predicate could not ask
    // whether it had taken effect.
    setBool(lua, "zoomed", if (state.zoomed_pane_uuid) |zu| std.mem.eql(u8, &pane.uuid, &zu) else false);
    setBool(lua, "sync_input", state.sync_input);
    setBool(lua, "is_float", is_float);
    setBool(lua, "is_split", !is_float);
    setOptInt(lua, "tab", if (state.paneParentTab(pane)) |t| @intCast(t + 1) else null);

    // Geometry, as laid out on screen right now.
    setInt(lua, "x", pane.x);
    setInt(lua, "y", pane.y);
    setInt(lua, "width", pane.width);
    setInt(lua, "height", pane.height);

    // Liveness. Handlers run before the reaper collects corpses, so without
    // these a plugin cannot tell a dead pane from a live one, and everything
    // below is transient garbage while a backlog is replaying.
    setBool(lua, "alive", pane.isAlive());
    setBool(lua, "replaying", pane.backlog_replaying);

    // Terminal state
    setBool(lua, "alt_screen", pane.vt.inAltScreen());
    setInt(lua, "cursor_style", pane.vt.getCursorStyle());
    setBool(lua, "cursor_visible", pane.vt.isCursorVisible());
    // The shell's own idea of where it is, as opposed to `cwd`, which falls
    // back to the last shell event.
    setOptStr(lua, "osc7_cwd", pane.vt.getPwd());

    // Input modes the pane's application has set. A bind that grabs Ctrl+V or
    // the arrow keys has to know these or it silently breaks inside vim/fzf,
    // and a plugin intercepting clicks has to know whether the app wants them.
    setBool(lua, "bracketed_paste", pane.vt.terminal.modes.get(.bracketed_paste));
    setBool(lua, "app_cursor", pane.vt.terminal.modes.get(.cursor_keys));
    setBool(lua, "synchronized_output", pane.vt.outputSynchronized());
    setInt(lua, "kitty_keyboard", @intCast(pane.vt.terminal.screens.active.kitty_keyboard.current().int()));
    setBool(lua, "mouse_tracking", pane.vt.terminal.flags.mouse_event != .none);
    // The shell is reading a password (DECSET 2004-adjacent; hexe already
    // suppresses keycast on it, pane.zig:235). Any plugin that logs keys,
    // mirrors input or renders a preview MUST hard-stop on this — without it
    // there is no way for Lua to know, and a sudo prompt looks like any other.
    setBool(lua, "password_input", pane.vt.terminal.flags.password_input);
    setBool(lua, "scrolled", pane.isScrolled());
    const cursor = pane.getCursorPos();
    setInt(lua, "cursor_x", cursor.x);
    setInt(lua, "cursor_y", cursor.y);

    // Process
    if (state.getPaneProc(pane.uuid)) |proc| {
        // SES-side facts, arriving on the fire-and-forget pane_info response.
        // The frontend cannot compute any of them: Pane.getFgPid is a stub, and
        // the lifecycle state and birth time live only in the daemon.
        setOptInt(lua, "pid", if (proc.shell_pid) |v| @intCast(v) else null);
        setStr(lua, "ses_state", switch (proc.ses_state) {
            0 => "attached",
            1 => "detached",
            2 => "sticky",
            3 => "orphaned",
            else => "unknown",
        });
        setOptInt(lua, "created_at", if (proc.created_at != 0) proc.created_at else null);
        setOptInt(lua, "age_ms", if (proc.created_at != 0)
            @max(std.time.milliTimestamp() - proc.created_at * 1000, 0)
        else
            null);
        setOptStr(lua, "process", proc.name);
        setOptInt(lua, "process_pid", if (proc.pid) |p| @intCast(p) else null);
        setBool(lua, "process_running", proc.name != null);
    } else {
        setOptStr(lua, "process", pane.getFgProcess());
        setOptInt(lua, "process_pid", if (pane.getFgPid()) |p| @intCast(p) else null);
        setBool(lua, "process_running", pane.getFgProcess() != null);
    }

    // Shell integration
    setOptStr(lua, "cwd", state.paneRealCwd(pane));
    if (state.getPaneShell(pane.uuid)) |sh| {
        setOptStr(lua, "last_command", sh.cmd);
        setOptInt(lua, "exit_status", if (sh.status) |s| @intCast(s) else null);
        setOptInt(lua, "duration_ms", if (sh.duration_ms) |d| @intCast(d) else null);
        setInt(lua, "jobs", if (sh.jobs) |j| @intCast(j) else 0);
        setBool(lua, "shell_running", sh.running);
        setOptInt(lua, "started_at_ms", if (sh.started_at_ms) |t| @intCast(t) else null);
    } else {
        setOptStr(lua, "last_command", null);
        setOptInt(lua, "exit_status", null);
        setOptInt(lua, "duration_ms", null);
        setInt(lua, "jobs", 0);
        setBool(lua, "shell_running", false);
        setOptInt(lua, "started_at_ms", null);
    }

    // OSC 9;4 progress
    const prog = pane.osc_progress;
    setStr(lua, "progress_state", switch (prog.state) {
        .inactive => "inactive",
        .in_progress => "in_progress",
        .error_state => "error",
        .indeterminate => "indeterminate",
        .paused => "paused",
    });
    setOptInt(lua, "progress_pct", if (prog.percentage) |p| @intCast(p) else null);

    // Float-only attributes. Present as false/nil on splits so a predicate can
    // read them unconditionally.
    const float_key = state.paneFloatKey(pane);
    setInt(lua, "float_key", float_key);
    setBool(lua, "sticky", state.paneSticky(pane));
    setBool(lua, "per_cwd", state.paneIsPwd(pane));
    setBool(lua, "visible", paneIsVisible(state, pane, is_float));
    // Which tabs a float shows on. `visible` answers only for the active tab;
    // a global float is a per-tab bitmask and a plugin cycling floats needs to
    // know where else it is showing.
    if (is_float) {
        if (state.paneFloatState(pane)) |fs| {
            lua.createTable(8, 0);
            var n: i32 = 0;
            var t: u6 = 0;
            while (t < 63) : (t += 1) {
                if (t >= state.view.tab_views.items.len) break;
                if ((fs.tab_visible & (@as(u64, 1) << t)) != 0) {
                    n += 1;
                    lua.pushInteger(@as(i64, t) + 1);
                    lua.rawSetIndex(-2, n);
                }
            }
            lua.setField(-2, "visible_tabs");
        }
    }

    var exclusive = false;
    var isolated = false;
    var destroyable = false;
    var global = state.paneParentTab(pane) == null;
    var command: ?[]const u8 = null;
    if (float_key != 0) {
        if (state.getLayoutFloatByKey(float_key)) |fd| {
            exclusive = fd.attributes.exclusive;
            isolated = fd.attributes.isolated;
            destroyable = fd.attributes.destroy;
            global = global or fd.attributes.global;
            // Already looked up; discarding it was free information lost.
            command = fd.command;
        }
    }
    setOptStr(lua, "command", command);
    setBool(lua, "exclusive", exclusive);
    setBool(lua, "isolated", isolated);
    setBool(lua, "destroyable", destroyable);
    setBool(lua, "global", global);
    setBool(lua, "adhoc", is_float and float_key == 0);
    // Geometry the bind actions can already CHANGE but Lua could not READ, so
    // every size-cycling plugin had to shadow it and desynced on a mouse resize.
    // nil on a split: the underlying getters return float defaults for any
    // pane, and reporting 60% width for a tiled pane is a lie.
    if (is_float) {
        setInt(lua, "width_pct", state.paneFloatWidthPct(pane));
        setInt(lua, "height_pct", state.paneFloatHeightPct(pane));
        setInt(lua, "pos_x_pct", state.paneFloatPosXPct(pane));
        setInt(lua, "pos_y_pct", state.paneFloatPosYPct(pane));
        setInt(lua, "pad_x", state.paneFloatPadX(pane));
        setInt(lua, "pad_y", state.paneFloatPadY(pane));
    } else {
        setOptInt(lua, "width_pct", null);
        setOptInt(lua, "height_pct", null);
        setOptInt(lua, "pos_x_pct", null);
        setOptInt(lua, "pos_y_pct", null);
        setOptInt(lua, "pad_x", null);
        setOptInt(lua, "pad_y", null);
    }
    // Which directory this per-cwd instance belongs to; `per_cwd` alone cannot
    // distinguish two instances of one float key.
    setOptStr(lua, "pwd_dir", state.panePwdDir(pane));
    setOptStr(lua, "exit_key", state.paneExitKey(pane));
    setOptStr(lua, "title", if (is_float) state.paneFloatTitle(pane) else null);

    // Who is watching this pane, straight from the pod that holds their
    // sockets. `shared` is the question a privacy indicator actually asks, and
    // deriving it from a count every caller would get subtly wrong on the
    // blocked-with-zero-observers case is worse than answering it here.
    {
        const proc = state.getPaneProc(pane.uuid);
        const observers: i64 = if (proc) |p| @intCast(p.observers) else 0;
        const blocked = if (proc) |p| p.share_blocked else false;
        setInt(lua, "observers", observers);
        setBool(lua, "shared", observers > 0);
        setBool(lua, "share_blocked", blocked);
    }

    // Where this pane's bytes can be read: the pod socket, which serves
    // scrollback and the live stream to an observer (docs/streaming.md).
    //
    // Reported rather than left to be derived, so a program that wants the
    // stream does not have to know hexe's runtime layout. Built with the same
    // helper SES used when it spawned the pod, so this is the path in use and
    // not a guess at one.
    if (!state.api_grant.has(.stream)) {
        // Withheld rather than faked: a caller without stream access should
        // learn it cannot have the bytes, not be handed a path that fails.
        setOptStr(lua, "pod_socket", null);
    } else {
        var scratch: [std.fs.max_path_bytes]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        if (core.ipc.getPodSocketPath(fba.allocator(), pane.uuid[0..])) |path| {
            setStr(lua, "pod_socket", path);
        } else |err| {
            core.logging.logError("lua_api", "could not resolve pod socket path", err);
            setOptStr(lua, "pod_socket", null);
        }
    }
}

/// Is this pane showing on the active tab right now? For a split, membership in
/// the current layout is enough; a float additionally has to be flagged visible.
fn paneIsVisible(state: *State, pane: *Pane, is_float: bool) bool {
    const active_tab = state.activeTabIndex();
    if (!is_float) {
        if (state.paneParentTab(pane)) |t| return t == active_tab;
        return true;
    }
    if (state.paneFloatState(pane)) |fs| {
        if (!fs.visible) return false;
    } else return false;
    return state.paneVisibleOnTab(pane, active_tab);
}

// ─── iteration ──────────────────────────────────────────────────────────────

const PaneVisitor = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, pane: *Pane, index: usize) void,
};

/// Walk every pane the frontend knows about: splits of every tab, then floats.
/// One place so the accessors cannot disagree about what "all panes" means.
fn forEachPane(state: *State, visitor: PaneVisitor) void {
    var index: usize = 1;
    for (state.view.tab_views.items) |*tab| {
        var it = tab.layout.splitIterator();
        while (it.next()) |p| {
            visitor.call(visitor.ctx, p.*, index);
            index += 1;
        }
    }
    for (state.view.float_views.items) |p| {
        visitor.call(visitor.ctx, p, index);
        index += 1;
    }
}

fn focusedPane(state: *State) ?*Pane {
    // On a pane's own socket, "the current pane" is that pane whatever holds
    // focus. It can see no other, so the session's focus is not its business --
    // and this is the single place every no-selector call passes through.
    if (state.api_pane_scope) |uuid| {
        var f = Finder{ .want_uuid = std.mem.sliceTo(uuid[0..], 0) };
        forEachPane(state, .{ .ctx = &f, .call = Finder.visit });
        return f.found;
    }
    if (state.activeFloatingIndex()) |idx| {
        if (idx < state.view.float_views.items.len) return state.view.float_views.items[idx];
    }
    return state.currentLayout().getFocusedPane();
}

const Finder = struct {
    want_index: ?usize = null,
    want_uuid: ?[]const u8 = null,
    want_ptr: ?*Pane = null,
    found: ?*Pane = null,
    found_index: usize = 0,

    fn visit(ctx: *anyopaque, pane: *Pane, index: usize) void {
        const self: *Finder = @ptrCast(@alignCast(ctx));
        if (self.found != null) return;
        if (self.want_ptr) |wp| {
            if (wp == pane) {
                self.found = pane;
                self.found_index = index;
            }
            return;
        }
        if (self.want_index) |wi| {
            if (wi == index) {
                self.found = pane;
                self.found_index = index;
            }
            return;
        }
        if (self.want_uuid) |wu| {
            if (wu.len <= pane.uuid.len and std.mem.startsWith(u8, pane.uuid[0..], wu)) {
                self.found = pane;
                self.found_index = index;
            }
        }
    }
};

/// Position of `pane` in `hexe.live.panes()` order, or 0 if it is not in the
/// layout. Keeps `p.index` meaningful however the pane was selected.
fn indexOf(state: *State, pane: *Pane) usize {
    var f = Finder{ .want_ptr = pane };
    forEachPane(state, .{ .ctx = &f, .call = Finder.visit });
    return f.found_index;
}

// ─── accessors ──────────────────────────────────────────────────────────────

/// Resolve a selector argument at `idx` to a pane. Shared by every accessor
/// and mutator that takes one, so they cannot drift apart.
fn resolvePane(lua: *Lua, state: *State, idx: i32) ?*Pane {
    if (state.api_pane_scope != null) {
        const mine = focusedPane(state) orelse return null;
        const picked = resolvePaneUnscoped(lua, state, idx) orelse return null;
        // A selector naming somebody else resolves to nothing rather than
        // silently to the caller's own pane: retargeting a write is worse than
        // refusing it.
        return if (picked == mine) mine else null;
    }
    return resolvePaneUnscoped(lua, state, idx);
}

fn resolvePaneUnscoped(lua: *Lua, state: *State, idx: i32) ?*Pane {
    switch (lua.typeOf(idx)) {
        .none, .nil => return focusedPane(state),
        .number => {
            const n = lua.toInteger(idx) catch 0;
            if (n <= 0) return focusedPane(state);
            var f = Finder{ .want_index = @intCast(n) };
            forEachPane(state, .{ .ctx = &f, .call = Finder.visit });
            return f.found;
        },
        .string => {
            const sel = lua.toString(idx) catch "";
            if (sel.len == 0 or std.mem.eql(u8, sel, "focused") or std.mem.eql(u8, sel, "current")) {
                return focusedPane(state);
            }
            if (std.mem.eql(u8, sel, "last")) {
                const prev = state.prev_focused_pane_uuid orelse return null;
                var f = Finder{ .want_uuid = prev[0..] };
                forEachPane(state, .{ .ctx = &f, .call = Finder.visit });
                return f.found;
            }
            if (std.mem.startsWith(u8, sel, "tab:") and std.mem.endsWith(u8, sel, "/focus")) {
                const digits = sel["tab:".len .. sel.len - "/focus".len];
                const n = std.fmt.parseInt(usize, digits, 10) catch return null;
                if (n < 1 or n > state.view.tab_views.items.len) return null;
                return state.view.tab_views.items[n - 1].layout.getFocusedPane();
            }
            var f = Finder{ .want_uuid = sel };
            forEachPane(state, .{ .ctx = &f, .call = Finder.visit });
            return f.found;
        },
        else => return null,
    }
}

/// `hexe.pane([selector])` — nil/0/"focused"/"current" = focused pane,
/// a number = 1-based index, a string = uuid or uuid prefix.
fn hexe_pane(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushNil();
        return 1;
    };
    const pane = resolvePane(lua, state, 1) orelse {
        lua.pushNil();
        return 1;
    };
    pushPaneTable(lua, state, pane, indexOf(state, pane));
    return 1;
}

const Collector = struct {
    lua: *Lua,
    state: *State,
    out: i32 = 0,
    only_floats: bool = false,
    only_splits: bool = false,
    only_visible: bool = false,
    only_tab: ?usize = null,

    fn visit(ctx: *anyopaque, pane: *Pane, index: usize) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        const is_float = self.state.paneIsFloating(pane);
        if (self.only_floats and !is_float) return;
        if (self.only_splits and is_float) return;
        if (self.only_visible and !paneIsVisible(self.state, pane, is_float)) return;
        if (self.only_tab) |t| {
            const parent = self.state.paneParentTab(pane) orelse return;
            if (parent != t) return;
        }
        self.out += 1;
        pushPaneTable(self.lua, self.state, pane, index);
        self.lua.rawSetIndex(-2, self.out);
    }
};

fn readFilter(lua: *Lua, c: *Collector) void {
    if (lua.typeOf(1) != .table) return;
    if (lua.getField(1, "visible") == .boolean) c.only_visible = lua.toBoolean(-1);
    lua.pop(1);
    if (lua.getField(1, "tab") == .number) {
        const n = lua.toInteger(-1) catch 0;
        if (n > 0) c.only_tab = @intCast(n - 1);
    }
    lua.pop(1);
}

/// `hexe.panes([filter])` — every pane; filter accepts `{visible=, tab=}`.
fn hexe_panes(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.createTable(0, 0);
        return 1;
    };
    var c = Collector{ .lua = lua, .state = state };
    readFilter(lua, &c);
    lua.createTable(16, 0);
    forEachPane(state, .{ .ctx = &c, .call = Collector.visit });
    return 1;
}

/// `hexe.floats([filter])` — float panes only. `hexe.floats{visible=true}` is
/// the "how many floats are showing" question.
fn hexe_floats(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.createTable(0, 0);
        return 1;
    };
    var c = Collector{ .lua = lua, .state = state, .only_floats = true };
    readFilter(lua, &c);
    lua.createTable(8, 0);
    forEachPane(state, .{ .ctx = &c, .call = Collector.visit });
    return 1;
}

/// `hexe.splits([filter])` — tiled panes only.
fn hexe_splits(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.createTable(0, 0);
        return 1;
    };
    var c = Collector{ .lua = lua, .state = state, .only_splits = true };
    readFilter(lua, &c);
    lua.createTable(8, 0);
    forEachPane(state, .{ .ctx = &c, .call = Collector.visit });
    return 1;
}

/// `hexe.tabs()` — one entry per tab.
fn hexe_tabs(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.createTable(0, 0);
        return 1;
    };
    const active = state.activeTabIndex();
    lua.createTable(@intCast(state.view.tab_views.items.len), 0);
    for (state.view.tab_views.items, 0..) |*tab, i| {
        lua.createTable(0, 6);
        setInt(lua, "index", @intCast(i + 1));
        setOptStr(lua, "name", state.runtime.tabName(i));
        setBool(lua, "active", i == active);
        setInt(lua, "pane_count", @intCast(tab.layout.splitCount()));
        if (tab.layout.getFocusedPane()) |fp| {
            setStr(lua, "focused_uuid", fp.uuid[0..]);
        } else {
            setOptStr(lua, "focused_uuid", null);
        }
        lua.rawSetIndex(-2, @intCast(i + 1));
    }
    return 1;
}

/// `hexe.session()` — identity and shape of the current session.
fn hexe_session(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushNil();
        return 1;
    };
    lua.createTable(0, 8);
    setStr(lua, "name", state.runtime.sessionName());
    // The socket this session is reachable on. Not derivable from `name`: the
    // path is fixed when the control socket binds, and a session that is later
    // renamed or reattached keeps the old file. A caller that read `name` and
    // built `api@<name>.sock` from it would miss exactly those sessions.
    if (state.api_server) |*srv| {
        setStr(lua, "socket", srv.path);
    } else {
        setOptStr(lua, "socket", null);
    }
    const uuid = state.runtime.sessionUuid();
    setStr(lua, "uuid", uuid[0..]);
    setStr(lua, "root", state.runtime.baseRoot());
    setBool(lua, "connected", state.runtime.isConnected());
    setInt(lua, "tab_count", @intCast(state.view.tab_views.items.len));
    setInt(lua, "active_tab", @intCast(state.activeTabIndex() + 1));
    return 1;
}

/// `hexe.ui()` — modes and geometry of the frontend itself.
fn hexe_ui(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushNil();
        return 1;
    };
    lua.createTable(0, 12);
    setInt(lua, "width", state.term_width);
    setInt(lua, "height", state.term_height);
    setInt(lua, "status_height", state.status_height);
    setBool(lua, "zoomed", state.zoomed_pane_uuid != null);
    setBool(lua, "copy_mode", state.isCopyModeActive());
    setBool(lua, "search_mode", state.isSearchActive());
    setBool(lua, "tab_rename", state.isTabRenameActive());
    setBool(lua, "pane_select", state.overlays.isPaneSelectActive());
    setBool(lua, "float_focused", state.activeFloatingIndex() != null);
    setBool(lua, "sync_input", state.sync_input);

    // Copy-mode cursor, so a plugin can follow it.
    setInt(lua, "copy_x", state.copy_mode.x);
    setInt(lua, "copy_y", state.copy_mode.y);
    setBool(lua, "copy_selecting", state.copy_mode.selecting);

    // Search: `search_mode` says a search is open, these say what it is.
    setStr(lua, "search_query", state.search_mode.query.items);
    setInt(lua, "search_matches", @intCast(state.search_mode.match_count));
    return 1;
}

/// `ctx.selection([{max_bytes = N}])` — the selected text, or nil.
///
/// Bounded. `extractText` runs `selectionString` over the whole range and then
/// copies it again to trim blank lines, so a drag-select to the top of a 16 MiB
/// scrollback allocated that twice — per call, and a predicate calls it once
/// per keystroke. The row span is clamped to the budget before extracting.
fn hexe_selection(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushNil();
        return 1;
    };
    const max_bytes = readMaxBytes(lua, 1);
    const tab = state.activeTabIndex();
    var it = state.currentLayout().splitIterator();
    while (it.next()) |p| {
        const range = state.mouse_selection.bufRangeForPane(tab, p.*) orelse continue;
        var clamped = range;
        const budget_rows = rowsForBudget(p.*, max_bytes);
        const top = @min(clamped.a.y, clamped.b.y);
        const bottom = @max(clamped.a.y, clamped.b.y);
        if (bottom - top + 1 > budget_rows) {
            const new_bottom: u32 = top + @as(u32, @intCast(budget_rows - 1));
            if (clamped.a.y <= clamped.b.y) clamped.b.y = new_bottom else clamped.a.y = new_bottom;
        }
        const text = mouse_selection.extractText(state.allocator, p.*, clamped) catch {
            lua.pushNil();
            return 1;
        };
        defer state.allocator.free(text);
        _ = lua.pushString(text[0..@min(text.len, max_bytes)]);
        return 1;
    }
    lua.pushNil();
    return 1;
}

/// `hexe.count(what)` — cheap cardinalities without materialising tables.
/// what: "tabs" | "panes" | "splits" | "floats" | "visible_floats".
fn hexe_count(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushInteger(0);
        return 1;
    };
    const what = lua.toString(1) catch "";

    if (std.mem.eql(u8, what, "tabs")) {
        lua.pushInteger(@intCast(state.view.tab_views.items.len));
        return 1;
    }
    if (std.mem.eql(u8, what, "floats")) {
        lua.pushInteger(@intCast(state.view.float_views.items.len));
        return 1;
    }
    if (std.mem.eql(u8, what, "visible_floats")) {
        var n: i64 = 0;
        for (state.view.float_views.items) |p| {
            if (paneIsVisible(state, p, true)) n += 1;
        }
        lua.pushInteger(n);
        return 1;
    }
    var splits: i64 = 0;
    for (state.view.tab_views.items) |*tab| splits += @intCast(tab.layout.splitCount());
    if (std.mem.eql(u8, what, "splits")) {
        lua.pushInteger(splits);
        return 1;
    }
    if (std.mem.eql(u8, what, "panes")) {
        lua.pushInteger(splits + @as(i64, @intCast(state.view.float_views.items.len)));
        return 1;
    }
    lua.pushInteger(0);
    return 1;
}

/// `hexe.env(name)` — one variable. The old context copied the entire
/// environment into a Lua table on every evaluation to support `ctx.env.FOO`.
fn hexe_env(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const name = lua.toString(1) catch {
        lua.pushNil();
        return 1;
    };
    var buf: [256]u8 = undefined;
    if (name.len >= buf.len) {
        lua.pushNil();
        return 1;
    }
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const value = std.posix.getenv(buf[0..name.len :0]) orelse {
        lua.pushNil();
        return 1;
    };
    _ = lua.pushString(value);
    return 1;
}

// ─── doing things ───────────────────────────────────────────────────────────

/// Guards against a Lua action that dispatches an action that runs Lua that…
/// Depth 1 is the normal case (a callback acting once); anything deeper is a
/// plugin calling into itself, and without this it would recurse until the
/// stack goes.
var dispatch_depth: u8 = 0;
const MAX_DISPATCH_DEPTH: u8 = 8;

/// `ctx.act(spec)` — perform any bind action, right now.
///
/// `spec` is exactly what the `hexe.action.*` constructors already produce, so
/// this covers the whole action set (and anything added to it later) without a
/// second list of names to keep in sync:
///
///     ctx.act(hexe.action.split.horizontal())
///     ctx.act(hexe.action.focus.move("up"))
///     ctx.act("tab.next")
fn hexe_act(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushBoolean(false);
        return 1;
    };
    if (dispatch_depth >= MAX_DISPATCH_DEPTH) {
        log.warn("ctx.act nested deeper than {d}; refusing", .{MAX_DISPATCH_DEPTH});
        lua.pushBoolean(false);
        return 1;
    }
    // A function is not an action spec -- just call it.
    if (lua.typeOf(1) == .function) {
        lua.pushBoolean(false);
        return 1;
    }
    const action = api_bridge.parseAction(lua, 1) orelse {
        lua.pushBoolean(false);
        return 1;
    };

    dispatch_depth += 1;
    defer dispatch_depth -= 1;
    const ok = keybinds_actions.dispatchAction(state, action);
    state.needs_render = true;
    lua.pushBoolean(ok);
    return 1;
}

/// `ctx.notify(message [, ms])` — mux-level notification.
/// Read an optional string field, duplicated for the caller to own.
fn optOwnedString(lua: *Lua, idx: i32, name: [:0]const u8, allocator: std.mem.Allocator) ?[]u8 {
    const ty = lua.getField(idx, name);
    defer lua.pop(1);
    if (ty != .string) return null;
    const v = lua.toString(-1) catch return null;
    return allocator.dupe(u8, v) catch null;
}

/// Read an optional unsigned field, clamped into `u16`.
fn optU16(lua: *Lua, idx: i32, name: [:0]const u8, fallback: u16) u16 {
    const ty = lua.getField(idx, name);
    defer lua.pop(1);
    if (ty != .number) return fallback;
    const v = lua.toNumber(-1) catch return fallback;
    if (v <= 0) return 0;
    if (v >= 65535) return 65535;
    return @intFromFloat(v);
}

/// `ctx.draw(name, {content=, corner=|x=,y=, width=, height=, ttl_ms=})`
///
/// Puts something on the screen and leaves it there. hexe has always been able
/// to draw art at a rectangle -- a pane's sprite is exactly that -- but only
/// its own config could ask for one. This is the same capability, addressed by
/// name, from outside.
///
/// Naming it twice replaces it, so a caller updating a drawing does not have to
/// remove it first and flicker.
fn hexe_draw(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushBoolean(false);
        return 1;
    };
    const name = lua.toString(1) catch {
        lua.pushBoolean(false);
        return 1;
    };
    if (name.len == 0 or lua.typeOf(2) != .table) {
        lua.pushBoolean(false);
        return 1;
    }
    const allocator = state.allocator;

    const width = optU16(lua, 2, "width", 0);
    const height = optU16(lua, 2, "height", 0);
    if (width == 0 or height == 0) {
        lua.pushBoolean(false);
        return 1;
    }

    // Where. A corner is resolved at render time so it survives a resize; x/y
    // is taken literally.
    var anchor: drawings_mod.Anchor = .{ .corner = .top_left };
    if (optOwnedString(lua, 2, "corner", allocator)) |c| {
        defer allocator.free(c);
        anchor = .{ .corner = drawings_mod.Corner.fromString(c) orelse .top_left };
    } else {
        anchor = .{ .at = .{ .x = optU16(lua, 2, "x", 0), .y = optU16(lua, 2, "y", 0) } };
    }

    const ttl = optU16(lua, 2, "ttl_ms", 0);
    const expires_at: i64 = if (ttl == 0) 0 else std.time.milliTimestamp() + @as(i64, ttl);

    // The caller's bytes. A drawing renders nothing itself and asks nothing to
    // render for it: whoever wants a painter runs one and sends what it draws.
    const content = optOwnedString(lua, 2, "content", allocator) orelse {
        lua.pushBoolean(false);
        return 1;
    };

    const owned_name = allocator.dupe(u8, name) catch {
        allocator.free(content);
        lua.pushBoolean(false);
        return 1;
    };

    state.drawings.put(.{
        .name = owned_name,
        .anchor = anchor,
        .width = width,
        .height = height,
        .content = content,
        .expires_at = expires_at,
    }) catch {
        lua.pushBoolean(false);
        return 1;
    };
    state.needs_render = true;
    lua.pushBoolean(true);
    return 1;
}

/// `ctx.undraw(name)` -- take one back off the screen.
fn hexe_undraw(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushBoolean(false);
        return 1;
    };
    const name = lua.toString(1) catch {
        lua.pushBoolean(false);
        return 1;
    };
    const removed = state.drawings.remove(name);
    if (removed) state.needs_render = true;
    lua.pushBoolean(removed);
    return 1;
}

fn hexe_notify(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushBoolean(false);
        return 1;
    };
    const msg = lua.toString(1) catch {
        lua.pushBoolean(false);
        return 1;
    };
    if (lua.typeOf(2) == .number) {
        const ms = lua.toInteger(2) catch 0;
        state.notifications.showFor(msg, ms);
    } else {
        state.notifications.show(msg);
    }
    state.needs_render = true;
    lua.pushBoolean(true);
    return 1;
}

/// `ctx.send(selector, text)` — write bytes to a pane's pty as if typed.
fn hexe_send(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushBoolean(false);
        return 1;
    };
    // (selector, text) or just (text) for the focused pane.
    const two_args = lua.typeOf(2) == .string;
    const text = (if (two_args) lua.toString(2) else lua.toString(1)) catch {
        lua.pushBoolean(false);
        return 1;
    };
    const pane = (if (two_args) resolvePane(lua, state, 1) else focusedPane(state)) orelse {
        lua.pushBoolean(false);
        return 1;
    };
    state.writePaneInput(pane, text);
    state.needs_render = true;
    lua.pushBoolean(true);
    return 1;
}

/// `ctx.focus(selector)` — focus any pane directly. The action set can only
/// move focus by direction, so this is not expressible through `ctx.act`.
fn hexe_focus(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushBoolean(false);
        return 1;
    };
    const pane = resolvePane(lua, state, 1) orelse {
        lua.pushBoolean(false);
        return 1;
    };
    if (state.paneIsFloating(pane)) {
        for (state.view.float_views.items, 0..) |fp, i| {
            if (fp == pane) {
                state.setActiveFloatingIndex(i);
                break;
            }
        }
    } else {
        if (state.paneParentTab(pane)) |t| {
            if (t != state.activeTabIndex()) tab_switch.switchToTab(state, t);
        }
        state.setActiveFloatingIndex(null);
        state.unfocusAllPanes();
        pane.focused = true;
    }
    state.syncPaneFocus(pane, null);
    state.needs_render = true;
    lua.pushBoolean(true);
    return 1;
}

/// `ctx.tab_select(n)` — switch to tab n (1-based).
fn hexe_tab_select(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushBoolean(false);
        return 1;
    };
    const n = lua.toInteger(1) catch {
        lua.pushBoolean(false);
        return 1;
    };
    if (n < 1 or @as(usize, @intCast(n)) > state.view.tab_views.items.len) {
        lua.pushBoolean(false);
        return 1;
    }
    // Through switchToTab, not setActiveTabIndex: the former also clears the
    // mouse selection and float rename, resets the drag, and unfocus-syncs the
    // outgoing pane. Skipping it leaves a selection highlighted on a tab that
    // is no longer visible.
    tab_switch.switchToTab(state, @intCast(n - 1));
    state.needs_render = true;
    lua.pushBoolean(true);
    return 1;
}

/// `ctx.rename_tab([n,] name)` — set a tab's name directly. The `tab.rename`
/// action only opens the inline editor, which a plugin cannot drive.
/// Read one optional percentage from a table field, clamped to 0..100.
///
/// Absent leaves the current value alone, so a caller can move a float without
/// restating its size and vice versa -- a drag changes one axis, not six.
fn optPct(lua: *Lua, idx: i32, name: [:0]const u8, current: u8) u8 {
    const ty = lua.getField(idx, name);
    defer lua.pop(1);
    if (ty != .number) return current;
    const v = lua.toNumber(-1) catch return current;
    if (v < 0) return 0;
    if (v > 100) return 100;
    return @intFromFloat(v);
}

/// `ctx.geometry([selector] [, {width=, height=, x=, y=, pad_x=, pad_y=}])`
///
/// Reads a float's geometry, and sets it when given a table. Percentages, and
/// absolute: `float.nudge` can only step in a direction, which is the wrong
/// shape for a pointer that already knows where it was dropped.
///
/// Returns the resulting geometry, so a caller sees what the clamp did rather
/// than assuming its request survived intact.
fn hexe_geometry(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushNil();
        return 1;
    };

    // The spec may be the first argument (meaning the focused pane) or the
    // second (after a selector), so a caller need not pass a placeholder.
    const spec_idx: ?i32 = if (lua.typeOf(1) == .table) 1 else if (lua.typeOf(2) == .table) 2 else null;
    const sel_idx: i32 = if (spec_idx == 1) 3 else 1;

    const pane = resolvePane(lua, state, sel_idx) orelse {
        lua.pushNil();
        return 1;
    };
    if (!state.paneIsFloating(pane)) {
        // A tiled pane has no percentage geometry of its own -- the layout
        // decides its rect -- but "where is this pane" still has an answer, and
        // nil would send a caller looking for another verb to ask it with.
        lua.createTable(0, 6);
        setInt(lua, "x", pane.x);
        setInt(lua, "y", pane.y);
        setInt(lua, "width", pane.width);
        setInt(lua, "height", pane.height);
        setBool(lua, "float", false);
        if (state.currentLayout().splitContaining(pane.uuid)) |split| {
            lua.pushNumber(split.ratio);
            lua.setField(-2, "ratio");
        }
        return 1;
    }

    if (spec_idx) |idx| {
        const w = optPct(lua, idx, "width", state.paneFloatWidthPct(pane));
        const h = optPct(lua, idx, "height", state.paneFloatHeightPct(pane));
        const x = optPct(lua, idx, "x", state.paneFloatPosXPct(pane));
        const y = optPct(lua, idx, "y", state.paneFloatPosYPct(pane));
        const px = optPct(lua, idx, "pad_x", state.paneFloatPadX(pane));
        const py = optPct(lua, idx, "pad_y", state.paneFloatPadY(pane));

        // Both halves, in this order, exactly as the nudge bind does: the UI
        // copy is what gets drawn, the runtime copy is what SES persists, and
        // setting only one leaves the float in a state that survives a redraw
        // but not a reattach.
        state.setPaneFloatGeometryUi(pane.uuid, w, h, x, y, px, py);
        state.setPaneFloatGeometry(pane, w, h, x, y, px, py);
        state.applyFrontendFloatNudge(pane);
        state.resizeFloatingPanes();
        state.needs_render = true;
    }

    // Percentages are what was asked for and what persists; the cell rect is
    // what actually landed after clamping, which is what a pointer needs to
    // draw a handle in the right place.
    lua.createTable(0, 11);
    setInt(lua, "width", state.paneFloatWidthPct(pane));
    setInt(lua, "height", state.paneFloatHeightPct(pane));
    setInt(lua, "x", state.paneFloatPosXPct(pane));
    setInt(lua, "y", state.paneFloatPosYPct(pane));
    setInt(lua, "pad_x", state.paneFloatPadX(pane));
    setInt(lua, "pad_y", state.paneFloatPadY(pane));
    setInt(lua, "cell_x", pane.x);
    setInt(lua, "cell_y", pane.y);
    setInt(lua, "cell_width", pane.width);
    setInt(lua, "cell_height", pane.height);
    setBool(lua, "float", true);
    return 1;
}

/// `ctx.ratio([selector] [, value])` — the divider above a tiled pane.
///
/// Reads the ratio of the split this pane sits in, and sets it when given a
/// number in 0..1. `split.resize` only steps by cells in a direction, which
/// cannot express "the user dragged the divider to here".
fn hexe_ratio(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushNil();
        return 1;
    };

    // The selector comes first, as in every other verb, and the new value only
    // ever second. Reading a number in the first position as the value would
    // make `ratio(2)` -- plainly "pane 2" -- silently resize a divider instead.
    const num_idx: ?i32 = if (lua.typeOf(2) == .number) 2 else null;

    const pane = resolvePane(lua, state, 1) orelse {
        lua.pushNil();
        return 1;
    };
    const layout = state.currentLayout();
    const split = layout.splitContaining(pane.uuid) orelse {
        lua.pushNil();
        return 1;
    };

    if (num_idx) |idx| {
        var v = lua.toNumber(idx) catch {
            lua.pushNil();
            return 1;
        };
        // A divider at 0 or 1 leaves a zero-width pane that cannot be grabbed
        // again, so the range stops short of both ends.
        if (v < 0.05) v = 0.05;
        if (v > 0.95) v = 0.95;
        // The terminal's own tree first: that is what decides pane rects. Going
        // only through SES would leave the divider where it was until the
        // round trip came back, and leave it there for good if SES is not
        // reachable. `split.resize` moves the tree the same way before syncing.
        split.ratio = @floatCast(v);
        layout.recalculateLayout();

        if (layout.splitRatioSyncForSplit(split)) |sync| {
            state.applyFrontendSplitRatio(sync.first_anchor_uuid, sync.second_anchor_uuid, @floatCast(v));
            state.syncSessionSplitRatio(sync.first_anchor_uuid, sync.second_anchor_uuid, @floatCast(v));
        }
        state.needs_render = true;
        state.renderer.invalidate();
        state.force_full_render = true;
    }

    lua.pushNumber(split.ratio);
    return 1;
}

/// `ctx.rename(selector, name)` — a pane's name.
///
/// Names reach socket paths and CLI arguments, so the same constraint the name
/// pool enforces applies to one chosen by hand.
fn hexe_rename(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushBoolean(false);
        return 1;
    };

    const two_args = lua.typeOf(2) == .string;
    const name = (if (two_args) lua.toString(2) else lua.toString(1)) catch {
        lua.pushBoolean(false);
        return 1;
    };
    if (!core.names.validEntry(name)) {
        lua.pushBoolean(false);
        return 1;
    }
    const pane = resolvePane(lua, state, if (two_args) 1 else 3) orelse {
        lua.pushBoolean(false);
        return 1;
    };

    const owned = state.allocator.dupe(u8, name) catch {
        lua.pushBoolean(false);
        return 1;
    };
    state.setPaneNameOwned(pane.uuid, owned);
    state.needs_render = true;
    lua.pushBoolean(true);
    return 1;
}

/// Read or change who may watch a pane: `share(sel)`, `share(sel, false)`.
///
/// Goes to the pod rather than to whatever opened the observers, so it still
/// works when that program is hung -- the case a stop button exists for. The
/// answer is the pod's own state after the change, not an echo of the request,
/// so a caller that is refused finds out.
fn hexe_share(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushNil();
        return 1;
    };

    // `share(false)` acts on the focused pane; `share(sel, false)` names one.
    const has_selector = lua.typeOf(1) != .boolean;
    const enable_idx: i32 = if (has_selector) 2 else 1;
    const cmd: core.wire.PodShareCmd = switch (lua.typeOf(enable_idx)) {
        .boolean => if (lua.toBoolean(enable_idx)) .allow else .block,
        else => .query,
    };

    const pane = resolvePane(lua, state, if (has_selector) 1 else 3) orelse {
        lua.pushNil();
        return 1;
    };

    const status = core.pod_share.requestLogged(state.allocator, pane.uuid[0..], cmd) orelse {
        lua.pushNil();
        return 1;
    };

    // Do not wait for the pod's uplink to come back around: a button whose
    // label updates on the next event tick reads as a button that did nothing.
    state.setPaneObservers(pane.uuid, status.observers, status.blocked);
    state.needs_render = true;

    lua.createTable(0, 3);
    setInt(lua, "observers", @intCast(status.observers));
    setBool(lua, "shared", status.observers > 0);
    setBool(lua, "blocked", status.blocked);
    return 1;
}

/// Parse `ctrl+alt+d`, `super+left`, `space` into hexe's chord representation.
///
/// Mod names match the ones a config writes (`hexe.key.ctrl`), because a person
/// bridging a compositor to hexe is reading their hexe config to decide what to
/// send, and having to translate between two spellings is a bug generator.
fn parseChord(spec: []const u8) ?struct { mods: u8, key: core.Config.BindKey } {
    var mods: u8 = 0;
    var key: ?core.Config.BindKey = null;

    var it = std.mem.tokenizeAny(u8, spec, "+- \t");
    while (it.next()) |part| {
        var lower_buf: [16]u8 = undefined;
        if (part.len > lower_buf.len) return null;
        const word = std.ascii.lowerString(lower_buf[0..part.len], part);

        if (std.mem.eql(u8, word, "alt")) {
            mods |= 1;
        } else if (std.mem.eql(u8, word, "ctrl") or std.mem.eql(u8, word, "control")) {
            mods |= 2;
        } else if (std.mem.eql(u8, word, "shift")) {
            mods |= 4;
        } else if (std.mem.eql(u8, word, "super") or std.mem.eql(u8, word, "meta")) {
            mods |= 8;
        } else if (std.mem.eql(u8, word, "up")) {
            key = .up;
        } else if (std.mem.eql(u8, word, "down")) {
            key = .down;
        } else if (std.mem.eql(u8, word, "left")) {
            key = .left;
        } else if (std.mem.eql(u8, word, "right")) {
            key = .right;
        } else if (std.mem.eql(u8, word, "space")) {
            key = .space;
        } else if (word.len == 1) {
            key = .{ .char = word[0] };
        } else {
            return null;
        }
    }
    // A chord with only modifiers is not a chord; refusing beats pressing
    // something the caller did not name.
    return if (key) |k| .{ .mods = mods, .key = k } else null;
}

/// `stream("drop")` hands the focused pane's bytes to that plugin;
/// `stream("drop", false)` stops.
///
/// hexe does not know what the plugin does with them -- publish them, record
/// them, feed another hexe. It knows only that a pane makes bytes and this
/// plugin was granted them. Whether the far end may type back is the plugin's
/// `typing` access, not an argument here: view-only and read-write are
/// different grants, not different calls.
fn hexe_stream(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushNil();
        return 1;
    };
    const attach_mod = @import("stream_attach.zig");

    const plugin = lua.toString(1) catch {
        lua.pushNil();
        return 1;
    };

    if (lua.typeOf(2) == .boolean and !lua.toBoolean(2)) {
        attach_mod.detach(state, plugin);
        lua.createTable(0, 2);
        setBool(lua, "attached", false);
        setOptStr(lua, "error", null);
        return 1;
    }

    const pane = (if (lua.typeOf(2) == .string or lua.typeOf(2) == .number)
        resolvePane(lua, state, 2)
    else
        focusedPane(state)) orelse {
        lua.pushNil();
        return 1;
    };

    const err = attach_mod.attach(state, plugin, pane);
    state.needs_render = true;
    lua.createTable(0, 3);
    setBool(lua, "attached", err == null);
    setOptStr(lua, "error", err);
    if (err == null) setStr(lua, "pane_uuid", pane.uuid[0..]);
    return 1;
}

/// `client()` — hexe's own client library, as source.
///
/// So a peer can obtain it **over the wire it is already speaking**, rather
/// than shelling out to `hexe lua-api` or being handed a file. A sandboxed host
/// -- oslo's VM removes `io.popen` -- has no other way to get it in code.
///
/// The bootstrap problem is smaller than it looks: any sibling that speaks
/// 4-byte-length + JSON can already call this, and every one of them ships a
/// client that does. It fetches the right vocabulary with the wrong one.
///
/// `read` access: it is a constant compiled into the binary, and a caller that
/// can reach the socket at all can already run `hexe lua-api`.
fn hexe_client(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    _ = lua.pushString(core.lua_client.SOURCE);
    return 1;
}

/// `popup("text")` shows a block until the user dismisses it; `popup()` clears.
///
/// hexe does not interpret the text. A link is a string; a QR code is a grid of
/// block characters the caller already rendered, and hexe has no idea it is a
/// QR. That is deliberate -- the moment hexe knows what a QR is, it owns a QR
/// library and a set of opinions about them.
fn hexe_popup(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushBoolean(false);
        return 1;
    };

    if (lua.typeOf(1) != .string) {
        _ = state.overlays.dismissMessages();
        state.needs_render = true;
        lua.pushBoolean(true);
        return 1;
    }
    const text = lua.toString(1) catch {
        lua.pushBoolean(false);
        return 1;
    };
    // Copied: the request buffer this points into is gone by the next frame.
    const owned = state.allocator.dupe(u8, text) catch {
        lua.pushBoolean(false);
        return 1;
    };
    state.overlays.showMessage(owned);
    state.needs_render = true;
    lua.pushBoolean(true);
    return 1;
}

/// `capture(true)` says something is recording this pane; `capture(false)` stops.
///
/// hexe does not know what is being captured -- a microphone, a camera, the
/// screen -- and draws the same three bars regardless, meaning only "something
/// is recording you right now".
///
/// Deliberately cheap: any plugin may claim it, because *claiming* to capture is
/// harmless and the harm runs the other way. A claim lapses after a few seconds
/// unless renewed, so a plugin that dies mid-capture cannot leave the light on.
fn hexe_capture(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushNil();
        return 1;
    };
    const capture_mod = @import("capture.zig");

    const on = lua.typeOf(1) != .boolean or lua.toBoolean(1);
    if (lua.typeOf(1) == .boolean and !on) {
        capture_mod.release(state);
    } else if (lua.typeOf(1) == .boolean) {
        const pane = (if (lua.typeOf(2) == .string or lua.typeOf(2) == .number)
            resolvePane(lua, state, 2)
        else
            focusedPane(state)) orelse {
            lua.pushNil();
            return 1;
        };
        const by = lua.toString(3) catch "plugin";
        capture_mod.claim(state, pane, by);
    }

    const c = &state.capture;
    const live = c.active(std.time.milliTimestamp());
    lua.createTable(0, 3);
    setBool(lua, "capturing", live);
    if (live and c.pane != null) {
        setStr(lua, "pane_uuid", c.pane.?[0..]);
        setStr(lua, "by", c.owner());
    } else {
        setOptStr(lua, "pane_uuid", null);
        setOptStr(lua, "by", null);
    }
    return 1;
}

/// `keys("ctrl+alt+d")` — press a chord *at hexe*; `keys(chord, "release")`
/// releases it.
///
/// Both halves are needed, not just the first. A chord that has a release
/// binding cannot be resolved on press alone -- hexe has to wait to see whether
/// it was a tap -- so a bridge that can only press can never drive
/// push-to-talk, which is the main thing a bridge is for.
///
/// Not `send`: this goes through the keybinding machinery, so it fires whatever
/// the user bound rather than reaching the program inside the pane. That is the
/// whole point of a compositor bridge — Hyprland knows the key was pressed, but
/// only hexe knows what it means here.
///
/// Returns whether a binding consumed it, so a bridge can fall back to its own
/// handling instead of silently swallowing the key.
fn hexe_keys(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushBoolean(false);
        return 1;
    };
    const spec = lua.toString(1) catch {
        lua.pushBoolean(false);
        return 1;
    };
    const chord = parseChord(spec) orelse {
        lua.pushBoolean(false);
        return 1;
    };

    // Which moment this is. Named rather than a boolean because hexe already
    // has four, and a bridge sending `repeat` should not have to lie about it.
    var phase: core.Config.BindWhen = .press;
    if (lua.typeOf(2) == .string) {
        const word = lua.toString(2) catch "press";
        phase = std.meta.stringToEnum(core.Config.BindWhen, word) orelse .press;
    }

    const keybinds = @import("keybinds.zig");
    const consumed = keybinds.handleKeyEvent(state, chord.mods, chord.key, phase, false);
    state.needs_render = true;
    lua.pushBoolean(consumed);
    return 1;
}

fn hexe_rename_tab(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushBoolean(false);
        return 1;
    };
    const two_args = lua.typeOf(2) == .string;
    const name = (if (two_args) lua.toString(2) else lua.toString(1)) catch {
        lua.pushBoolean(false);
        return 1;
    };
    var idx = state.activeTabIndex();
    if (two_args) {
        const n = lua.toInteger(1) catch 0;
        if (n < 1 or @as(usize, @intCast(n)) > state.view.tab_views.items.len) {
            lua.pushBoolean(false);
            return 1;
        }
        idx = @intCast(n - 1);
    }
    const ok = state.runtime.setTabName(idx, name);
    state.needs_render = true;
    lua.pushBoolean(ok);
    return 1;
}

/// `ctx.close(selector [, {kill = false}])` — close any pane, not just the
/// focused one.
///
/// cost: BLOCKING-IPC by default. `Layout.closePane` kills the live pane, which
/// waits on a SES ack; a predicate must not call it. `{kill = false}` drops the
/// pane locally only and never touches the socket.
///
/// This also does the bookkeeping the bind path does — clearing transient pane
/// state, telling the shared view the pane went away, and re-syncing focus.
/// Skipping it left the shared projection pointing at a pane that no longer
/// existed.
/// Whether this pane is a float rather than a member of the split tree.
fn isFloat(state: *State, pane: *Pane) bool {
    for (state.view.float_views.items) |p| {
        if (p == pane) return true;
    }
    return false;
}

fn hexe_close(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushBoolean(false);
        return 1;
    };
    const pane = resolvePane(lua, state, 1) orelse {
        lua.pushBoolean(false);
        return 1;
    };

    var kill = true;
    if (lua.typeOf(2) == .table) {
        if (lua.getField(2, "kill") == .boolean) kill = lua.toBoolean(-1);
        lua.pop(1);
    }
    if (kill and !inHandlerScope(lua)) {
        log.warn("ctx.close with kill=true is not allowed in a predicate", .{});
        lua.pushBoolean(false);
        return 1;
    }

    // A float is not in the split tree, so the close below has never been able
    // to find one: it returned false while `killPane` made the float vanish
    // anyway, and a caller that believed the answer saw a failure that had in
    // fact succeeded. Worse, nothing answered a `hexe terminal float` waiting on
    // its result, so that CLI hung for ever.
    //
    // Floats go through the same path a keybinding uses, so closing one from
    // here does what closing one by hand does -- including sending the waiting
    // caller its result.
    if (isFloat(state, pane)) {
        const tab = state.activeTabIndex();
        if (kill) {
            loop_actions.destroyFloatPane(state, pane);
        } else {
            // Respect what the float declared: sticky ones hide, transient ones
            // are destroyed because leaving one alive strands its CLI caller.
            loop_actions.hideOrDestroyFloat(state, pane, tab);
        }
        state.needs_render = true;
        lua.pushBoolean(true);
        return 1;
    }

    const uuid = pane.uuid;
    const layout = state.currentLayout();
    if (kill) {
        state.runtime.killPane(uuid) catch |err| {
            core.logging.logError("terminal", "ctx.close: killPane failed", err);
            lua.pushBoolean(false);
            return 1;
        };
    }
    state.clearTransientPaneState(pane);
    const ok = layout.closePaneLocal(uuid);
    if (ok) {
        if (layout.getFocusedPane()) |new_pane| {
            state.applyFrontendPaneRemoved(uuid, new_pane.uuid);
            state.syncPaneFocus(new_pane, null);
        } else {
            state.applyFrontendPaneRemoved(uuid, null);
        }
        state.revalidateZoom();
    }
    state.needs_render = true;
    lua.pushBoolean(ok);
    return 1;
}

/// `ctx.scroll([selector,] lines)` — positive scrolls back, negative forward.
fn hexe_scroll(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushBoolean(false);
        return 1;
    };
    const two_args = lua.typeOf(2) == .number;
    const lines = (if (two_args) lua.toInteger(2) else lua.toInteger(1)) catch {
        lua.pushBoolean(false);
        return 1;
    };
    const pane = (if (two_args) resolvePane(lua, state, 1) else focusedPane(state)) orelse {
        lua.pushBoolean(false);
        return 1;
    };
    if (lines > 0) {
        pane.scrollUp(@intCast(lines));
    } else if (lines < 0) {
        pane.scrollDown(@intCast(-lines));
    } else {
        pane.scrollToBottom();
    }
    state.needs_render = true;
    lua.pushBoolean(true);
    return 1;
}

/// `ctx.config()` — what the config DECLARES, as opposed to what is running.
///
/// `ctx.floats()` lists live float panes; this lists the float definitions a
/// user configured, so a plugin can ask "is there a float bound to key g, and
/// what would it run" before deciding to toggle it.
fn hexe_config(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushNil();
        return 1;
    };
    lua.createTable(0, 4);

    lua.createTable(@intCast(state.active_layout_floats.len), 0);
    for (state.active_layout_floats, 0..) |*f, i| {
        lua.createTable(0, 12);
        setInt(lua, "key", f.key);
        // The character the key actually is, so `float.show(f.key_name)` works
        // without the caller converting a code point by hand.
        var key_char = [_]u8{f.key};
        setStr(lua, "key_name", key_char[0..]);
        setOptStr(lua, "name", f.name);
        setBool(lua, "enabled", f.enabled);
        setOptStr(lua, "command", f.command);
        setOptStr(lua, "title", f.title);
        setOptInt(lua, "width_pct", if (f.width_percent) |v| @intCast(v) else null);
        setOptInt(lua, "height_pct", if (f.height_percent) |v| @intCast(v) else null);
        setOptInt(lua, "pos_x_pct", if (f.pos_x) |v| @intCast(v) else null);
        setOptInt(lua, "pos_y_pct", if (f.pos_y) |v| @intCast(v) else null);
        setBool(lua, "sticky", f.attributes.sticky);
        setBool(lua, "per_cwd", f.attributes.per_cwd);
        setBool(lua, "per_git", f.attributes.per_git);
        setBool(lua, "global", f.attributes.global);
        setBool(lua, "exclusive", f.attributes.exclusive);
        setBool(lua, "isolated", f.attributes.isolated);
        setBool(lua, "destroy", f.attributes.destroy);
        lua.rawSetIndex(-2, @intCast(i + 1));
    }
    lua.setField(-2, "floats");

    setInt(lua, "keybind_count", @intCast(state.config.input.binds.len));
    setBool(lua, "status_enabled", state.config.tabs.status.enabled);
    setBool(lua, "confirm_on_exit", state.config.confirm_on_exit);
    return 1;
}

// ─── content ────────────────────────────────────────────────────────────────

/// Ceiling for any single content read, and the default when none is given.
/// A predicate runs per candidate bind per keypress, so an unbounded read here
/// is an input-latency bug waiting to happen.
const DEFAULT_CONTENT_BYTES: usize = 64 * 1024;
const MAX_CONTENT_BYTES: usize = 1024 * 1024;

fn readMaxBytes(lua: *Lua, idx: i32) usize {
    if (lua.typeOf(idx) != .table) return DEFAULT_CONTENT_BYTES;
    const ty = lua.getField(idx, "max_bytes");
    defer lua.pop(1);
    if (ty != .number) return DEFAULT_CONTENT_BYTES;
    const n = lua.toInteger(-1) catch return DEFAULT_CONTENT_BYTES;
    if (n <= 0) return DEFAULT_CONTENT_BYTES;
    return @min(@as(usize, @intCast(n)), MAX_CONTENT_BYTES);
}

/// Rows of a viewport a byte budget allows, worst case 4 bytes per column.
fn rowsForBudget(pane: *Pane, max_bytes: usize) usize {
    const cols: usize = @max(pane.vt.terminal.cols, 1);
    return @max(max_bytes / (cols * 4 + 1), 1);
}

/// Text between two viewport rows of a pane, inclusive.
///
/// Goes through ghostty's own `selectionString` rather than decoding cells by
/// hand: it already handles wide cells, spacer tails and graphemes. The CALLER
/// bounds the row span, which is what keeps the allocation bounded — one row is
/// at most `cols * 4` bytes.
/// The pane's whole visible screen as text, caller owns it.
///
/// So a viewer joining a stream sees the pane as it looks now rather than a
/// blank rectangle until something is printed next.
pub fn paneScreenText(allocator: std.mem.Allocator, pane: *Pane) ?[]u8 {
    const rows: usize = pane.vt.terminal.rows;
    if (rows == 0) return null;
    return extractRows(allocator, pane, 0, rows - 1);
}

fn extractRows(allocator: std.mem.Allocator, pane: *Pane, top: usize, bottom: usize) ?[]u8 {
    const screen = pane.vt.terminal.screens.active;
    const pages = &screen.pages;
    const cols = pane.vt.terminal.cols;
    if (cols == 0) return null;

    const start_pin = pages.pin(.{ .viewport = .{ .x = 0, .y = @intCast(top) } }) orelse return null;
    const end_pin = pages.pin(.{ .viewport = .{ .x = @intCast(cols - 1), .y = @intCast(bottom) } }) orelse return null;

    const sel = ghostty.Selection.init(start_pin, end_pin, false);
    const text_z = screen.selectionString(allocator, .{ .sel = sel, .trim = true }) catch return null;
    defer allocator.free(text_z);
    return allocator.dupe(u8, std.mem.sliceTo(text_z, 0)) catch null;
}

/// `ctx.line([selector,] n)` — one row of the viewport, 0-based from the top;
/// negative counts from the bottom. One row allocated, at most.
fn hexe_line(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushNil();
        return 1;
    };
    const two_args = lua.typeOf(2) == .number;
    const n = (if (two_args) lua.toInteger(2) else lua.toInteger(1)) catch {
        lua.pushNil();
        return 1;
    };
    const pane = (if (two_args) resolvePane(lua, state, 1) else focusedPane(state)) orelse {
        lua.pushNil();
        return 1;
    };

    const rows: i64 = @intCast(pane.vt.terminal.rows);
    const row = if (n < 0) rows + n else n;
    if (row < 0 or row >= rows) {
        lua.pushNil();
        return 1;
    }
    const text = extractRows(state.allocator, pane, @intCast(row), @intCast(row)) orelse {
        lua.pushNil();
        return 1;
    };
    defer state.allocator.free(text);
    _ = lua.pushString(text);
    return 1;
}

/// `ctx.cursor_line([selector])` — the row the cursor is on.
///
/// Not sugar for `ctx.line(p.cursor_y)`: `cursor_x`/`cursor_y` are SCREEN
/// coordinates (Pane.getCursorPos adds the pane origin), so indexing a viewport
/// row with them reads the wrong line for any pane not at the top of the screen.
fn hexe_cursor_line(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushNil();
        return 1;
    };
    const pane = resolvePane(lua, state, 1) orelse {
        lua.pushNil();
        return 1;
    };
    const cur = pane.vt.getCursor(); // pane-local, unlike Pane.getCursorPos
    if (cur.y >= pane.vt.terminal.rows) {
        lua.pushNil();
        return 1;
    }
    const text = extractRows(state.allocator, pane, cur.y, cur.y) orelse {
        lua.pushNil();
        return 1;
    };
    defer state.allocator.free(text);
    _ = lua.pushString(text);
    return 1;
}

/// `ctx.screen_text([selector,] {max_bytes = N})` — the visible viewport only,
/// never the scrollback. Keeps the last whole rows that fit the budget.
fn hexe_screen_text(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushNil();
        return 1;
    };
    const sel_first = switch (lua.typeOf(1)) {
        .number, .string => true,
        else => false,
    };
    const pane = (if (sel_first) resolvePane(lua, state, 1) else focusedPane(state)) orelse {
        lua.pushNil();
        return 1;
    };
    const max_bytes = readMaxBytes(lua, if (sel_first) 2 else 1);

    const rows: usize = pane.vt.terminal.rows;
    if (rows == 0) {
        lua.pushNil();
        return 1;
    }
    // When the budget cannot hold the whole viewport, anchor the window at the
    // cursor rather than at the last row. On a mostly-blank screen the bottom
    // rows are empty, so a capped read there returns nothing at all — which
    // looks exactly like "the pane has no text".
    const budget_rows = @min(rowsForBudget(pane, max_bytes), rows);
    const anchor: usize = if (budget_rows >= rows) rows - 1 else @min(@as(usize, pane.vt.getCursor().y), rows - 1);
    const bottom = @max(anchor, budget_rows - 1);
    const top = bottom + 1 - budget_rows;
    const text = extractRows(state.allocator, pane, top, bottom) orelse {
        lua.pushNil();
        return 1;
    };
    defer state.allocator.free(text);
    _ = lua.pushString(text);
    return 1;
}

/// `ctx.find([selector,] needle)` — first viewport row containing `needle`
/// (1-based), or nil.
///
/// Viewport only. The scrollback search walks the whole page list — up to 16
/// MiB — and belongs behind the search UI, not behind a predicate.
fn hexe_find(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushNil();
        return 1;
    };
    const two_args = lua.typeOf(2) == .string;
    const needle = (if (two_args) lua.toString(2) else lua.toString(1)) catch {
        lua.pushNil();
        return 1;
    };
    if (needle.len == 0 or needle.len > 256) {
        lua.pushNil();
        return 1;
    }
    const pane = (if (two_args) resolvePane(lua, state, 1) else focusedPane(state)) orelse {
        lua.pushNil();
        return 1;
    };

    var row: usize = 0;
    while (row < pane.vt.terminal.rows) : (row += 1) {
        const text = extractRows(state.allocator, pane, row, row) orelse continue;
        defer state.allocator.free(text);
        if (std.mem.indexOf(u8, text, needle) != null) {
            lua.pushInteger(@intCast(row + 1));
            return 1;
        }
    }
    lua.pushNil();
    return 1;
}

/// `ctx.selection_range()` — where the selection is, without reading its text.
/// A plugin that only needs "is something selected, and how big" should not pay
/// for the extraction.
fn hexe_selection_range(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.pushNil();
        return 1;
    };
    const tab = state.activeTabIndex();
    var it = state.currentLayout().splitIterator();
    while (it.next()) |p| {
        const range = state.mouse_selection.bufRangeForPane(tab, p.*) orelse continue;
        const top = @min(range.a.y, range.b.y);
        const bottom = @max(range.a.y, range.b.y);
        lua.createTable(0, 7);
        setStr(lua, "pane_uuid", p.*.uuid[0..]);
        setInt(lua, "start_x", range.a.x);
        setInt(lua, "start_y", @intCast(range.a.y));
        setInt(lua, "end_x", range.b.x);
        setInt(lua, "end_y", @intCast(range.b.y));
        setInt(lua, "rows", @intCast(bottom - top + 1));
        setBool(lua, "dragging", state.mouse_selection.dragging);
        return 1;
    }
    lua.pushNil();
    return 1;
}

/// `hexe.verbs()` — every name THIS caller may call, with what each answers.
///
/// Filtered by the door the request arrived on, not the whole table: on a
/// plugin's socket or a pane's socket, a verb the grant refuses is not a name
/// this peer will answer, and listing it would be a lie a client then acts on.
/// What is missing is still discoverable -- a refusal names the access it
/// wanted -- so nothing is hidden, it is just not promised.
///
/// The record is `{name, about, access}`: the first two are the family's shape,
/// and the third is hexe's own, added rather than substituted so a sibling's
/// client reads this unchanged.
fn hexe_verbs(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const state = liveState(lua) orelse {
        lua.createTable(0, 0);
        return 1;
    };
    lua.createTable(ENTRIES.len, 0);
    var n: i32 = 0;
    inline for (ENTRIES) |e| {
        // The same price the dispatcher will charge, so the list cannot promise a verb
        // the gate refuses -- or withhold one it would allow.
        const scoped = state.api_pane_scope != null;
        const needs = core.access.priceOf(e.needs, e.needs_scoped, scoped);
        const allowed = state.api_grant.has(needs) and (!scoped or e.pane_local);
        if (allowed) {
            n += 1;
            lua.createTable(0, 3);
            setStr(lua, "name", std.mem.span(e.name.ptr));
            setStr(lua, "about", e.about);
            setStr(lua, "access", needs.name());
            lua.rawSetIndex(-2, n);
        }
    }
    return 1;
}

// ─── installation ───────────────────────────────────────────────────────────

/// A verb, and the one access kind it needs.
///
/// Kept on the verb rather than checked at each call site so the mapping is a
/// table someone can read top to bottom -- and so a new verb cannot be added
/// without stating what it costs. Lua callers are unaffected: config already
/// runs with the user's full authority. The grant is enforced at the socket,
/// where a stranger's program is on the other end.
const Entry = struct {
    name: [:0]const u8,
    func: *const fn (?*LuaState) callconv(.c) c_int,
    /// One line, for `verbs()`. A peer asks what this session answers rather
    /// than being assumed to have read the docs, so the answer lives beside the
    /// verb and cannot describe one that was renamed.
    about: []const u8 = "",
    needs: core.access.Kind = .control,
    /// Answerable for one pane alone, so a pane's own socket may serve it.
    /// Everything else describes or changes the session and is refused there.
    pane_local: bool = false,
    /// What the verb costs on a pane's own socket, when that is less than
    /// `needs`. A pane moving *itself* is not the power `control` names: the
    /// selector is confined to the caller either way, so the authority being
    /// asked for is over its own rectangle and nothing else.
    needs_scoped: ?core.access.Kind = null,
};

/// Whether `call` means something on a single pane's socket.
pub fn isPaneLocal(call: []const u8) bool {
    inline for (ENTRIES) |e| {
        if (std.mem.eql(u8, call, std.mem.span(e.name.ptr))) return e.pane_local;
    }
    return false;
}

/// What `call` requires, or null if there is no such verb.
pub fn accessFor(call: []const u8) ?core.access.Kind {
    inline for (ENTRIES) |e| {
        if (std.mem.eql(u8, call, std.mem.span(e.name.ptr))) return e.needs;
    }
    return null;
}

/// What `call` requires on a pane's own socket, where the selector cannot
/// reach past the caller.
pub fn scopedAccessFor(call: []const u8) ?core.access.Kind {
    inline for (ENTRIES) |e| {
        if (std.mem.eql(u8, call, std.mem.span(e.name.ptr))) {
            return core.access.priceOf(e.needs, e.needs_scoped, true);
        }
    }
    return null;
}

const ENTRIES = [_]Entry{
    .{ .name = "verbs", .func = hexe_verbs, .about = "this list", .needs = .read, .pane_local = true },
    .{ .name = "pane", .func = hexe_pane, .about = "one pane, by selector, uuid or index", .needs = .read, .pane_local = true },
    .{ .name = "panes", .func = hexe_panes, .about = "every pane in the session", .needs = .read },
    .{ .name = "floats", .func = hexe_floats, .about = "the floating panes", .needs = .read },
    .{ .name = "splits", .func = hexe_splits, .about = "the split tree of the current tab", .needs = .read },
    .{ .name = "tabs", .func = hexe_tabs, .about = "every tab", .needs = .read },
    .{ .name = "session", .func = hexe_session, .about = "identity and shape of this session", .needs = .read },
    .{ .name = "ui", .func = hexe_ui, .about = "what the frontend is showing", .needs = .read },
    .{ .name = "count", .func = hexe_count, .about = "how many of a thing there are", .needs = .read },
    .{ .name = "env", .func = hexe_env, .about = "a pane's environment", .needs = .screen, .pane_local = true },
    .{ .name = "act", .func = hexe_act, .about = "perform a bound action by name" },
    .{ .name = "notify", .func = hexe_notify, .about = "put a line in front of the user", .needs = .popup },
    .{ .name = "draw", .func = hexe_draw, .about = "put something on the screen and leave it there", .needs = .popup },
    .{ .name = "undraw", .func = hexe_undraw, .about = "take a drawing back off the screen", .needs = .popup },
    .{ .name = "send", .func = hexe_send, .about = "write bytes into a pane, uninterpreted", .needs = .typing, .pane_local = true },
    // Scoped, this is "focus me" -- the selector cannot name another pane, so what a
    // pane buys is the ability to ask for the cursor back after it opened something
    // that took it.
    .{ .name = "focus", .func = hexe_focus, .about = "move focus to a pane", .pane_local = true, .needs_scoped = .read },
    .{ .name = "tab_select", .func = hexe_tab_select, .about = "switch to a tab" },
    .{ .name = "rename_tab", .func = hexe_rename_tab, .about = "name a tab" },
    .{ .name = "rename", .func = hexe_rename, .about = "name a pane" },
    .{ .name = "share", .func = hexe_share, .about = "who is watching a pane, and cut them off" },
    .{ .name = "keys", .func = hexe_keys, .about = "press a chord at hexe, firing whatever it is bound to", .needs = .keyboard },
    .{ .name = "capture", .func = hexe_capture, .about = "claim or release the recording indicator", .needs = .read, .pane_local = true },
    .{ .name = "client", .func = hexe_client, .about = "this library's own source", .needs = .read, .pane_local = true },
    .{ .name = "popup", .func = hexe_popup, .about = "show a block until it is dismissed", .needs = .popup },
    .{ .name = "stream", .func = hexe_stream, .about = "hand a pane's bytes to a plugin", .needs = .stream },
    .{ .name = "geometry", .func = hexe_geometry, .about = "read or set where a pane is", .pane_local = true, .needs_scoped = .read },
    .{ .name = "ratio", .func = hexe_ratio, .about = "read or set a divider" },
    .{ .name = "close", .func = hexe_close, .about = "close a pane" },
    .{ .name = "scroll", .func = hexe_scroll, .about = "scroll a pane" },
    .{ .name = "selection", .func = hexe_selection, .about = "the current selection", .needs = .screen, .pane_local = true },
    .{ .name = "config", .func = hexe_config, .about = "the resolved configuration", .needs = .read },
    .{ .name = "line", .func = hexe_line, .about = "one line of a pane", .needs = .screen, .pane_local = true },
    .{ .name = "cursor_line", .func = hexe_cursor_line, .about = "the line the cursor is on", .needs = .screen, .pane_local = true },
    .{ .name = "screen_text", .func = hexe_screen_text, .about = "a pane's visible text", .needs = .screen, .pane_local = true },
    .{ .name = "find", .func = hexe_find, .about = "search a pane's scrollback", .needs = .screen, .pane_local = true },
    .{ .name = "selection_range", .func = hexe_selection_range, .about = "where the selection is", .needs = .screen, .pane_local = true },
};

/// Registry slot holding the accessor table, so a callback invocation can push
/// it without a global lookup.
const API_TABLE_KEY = "_hexe_live_api";

/// Build the query API as `hexe.live` and stash it in the registry.
///
/// It is a namespace, not loose entries on `hexe`: the config API already owns
/// `hexe.pane` (the layout-pane constructor, `config/layout.lua:8`), plus
/// `hexe.float`, `hexe.split`, `hexe.tab` and friends. Installing accessors
/// directly onto `hexe` silently replaced the constructor and layouts stopped
/// building — with no error, because the call still succeeded and just returned
/// something else.
pub fn install(rt: *LuaRuntime) void {
    _ = rt.lua.getGlobal("hexe") catch {
        log.warn("hexe global missing; live query API not installed", .{});
        return;
    };
    if (rt.lua.typeOf(-1) != .table) {
        rt.lua.pop(1);
        log.warn("hexe global is not a table; live query API not installed", .{});
        return;
    }

    rt.lua.createTable(0, ENTRIES.len);
    inline for (ENTRIES) |e| {
        rt.lua.pushFunction(e.func);
        rt.lua.setField(-2, e.name);
    }

    // `exec` is bound on `hexe` by the core runtime. Alias, do not reimplement,
    // so a callback reaches every capability through its argument.
    if (rt.lua.getField(-2, "exec") == .function) {
        rt.lua.setField(-2, "exec");
    } else {
        rt.lua.pop(1);
    }

    // Keep a reference for pushCallbackContext, then attach as hexe.live.
    rt.lua.pushValue(-1);
    rt.lua.setField(zlua.registry_index, API_TABLE_KEY);
    rt.lua.setField(-2, "live");
    rt.lua.pop(1); // hexe
}

/// Push the table handed to a callback as its argument: the query API itself,
/// so `function(ctx) ... ctx.pane() ... end` needs no prefix.
pub fn pushCallbackContext(rt: *LuaRuntime) bool {
    _ = rt.lua.getField(zlua.registry_index, API_TABLE_KEY);
    if (rt.lua.typeOf(-1) != .table) {
        rt.lua.pop(1);
        return false;
    }
    return true;
}
