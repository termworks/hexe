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
const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaState = zlua.LuaState;
const LuaRuntime = core.LuaRuntime;

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;
const api_bridge = core.api_bridge;
const keybinds_actions = @import("keybinds_actions.zig");

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
pub const Scope = struct { prev: ?*State };

pub fn pushLiveState(rt: *LuaRuntime, state: *State) Scope {
    const prev = liveState(rt.lua);
    rt.lua.pushLightUserdata(state);
    rt.lua.setField(zlua.registry_index, LIVE_STATE_KEY);
    return .{ .prev = prev };
}

pub fn popLiveState(rt: *LuaRuntime, scope: Scope) void {
    if (scope.prev) |prev| {
        rt.lua.pushLightUserdata(prev);
    } else {
        rt.lua.pushNil();
    }
    rt.lua.setField(zlua.registry_index, LIVE_STATE_KEY);
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

    // Terminal state
    setBool(lua, "alt_screen", pane.vt.inAltScreen());
    setBool(lua, "scrolled", pane.isScrolled());
    const cursor = pane.getCursorPos();
    setInt(lua, "cursor_x", cursor.x);
    setInt(lua, "cursor_y", cursor.y);

    // Process
    if (state.getPaneProc(pane.uuid)) |proc| {
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

    var exclusive = false;
    var isolated = false;
    var destroyable = false;
    var global = state.paneParentTab(pane) == null;
    if (float_key != 0) {
        if (state.getLayoutFloatByKey(float_key)) |fd| {
            exclusive = fd.attributes.exclusive;
            isolated = fd.attributes.isolated;
            destroyable = fd.attributes.destroy;
            global = global or fd.attributes.global;
        }
    }
    setBool(lua, "exclusive", exclusive);
    setBool(lua, "isolated", isolated);
    setBool(lua, "destroyable", destroyable);
    setBool(lua, "global", global);
    setBool(lua, "adhoc", is_float and float_key == 0);
    setOptStr(lua, "title", if (is_float) state.paneFloatTitle(pane) else null);
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
            if (t != state.activeTabIndex()) state.setActiveTabIndex(t);
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
    state.setActiveTabIndex(@intCast(n - 1));
    state.needs_render = true;
    lua.pushBoolean(true);
    return 1;
}

/// `ctx.rename_tab([n,] name)` — set a tab's name directly. The `tab.rename`
/// action only opens the inline editor, which a plugin cannot drive.
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

/// `ctx.close(selector)` — close any pane, not just the focused one.
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
    const uuid = pane.uuid;
    const ok = state.currentLayout().closePane(uuid);
    if (ok) state.revalidateZoom();
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

// ─── installation ───────────────────────────────────────────────────────────

const Entry = struct { name: [:0]const u8, func: *const fn (?*LuaState) callconv(.c) c_int };

const ENTRIES = [_]Entry{
    .{ .name = "pane", .func = hexe_pane },
    .{ .name = "panes", .func = hexe_panes },
    .{ .name = "floats", .func = hexe_floats },
    .{ .name = "splits", .func = hexe_splits },
    .{ .name = "tabs", .func = hexe_tabs },
    .{ .name = "session", .func = hexe_session },
    .{ .name = "ui", .func = hexe_ui },
    .{ .name = "count", .func = hexe_count },
    .{ .name = "env", .func = hexe_env },
    .{ .name = "act", .func = hexe_act },
    .{ .name = "notify", .func = hexe_notify },
    .{ .name = "send", .func = hexe_send },
    .{ .name = "focus", .func = hexe_focus },
    .{ .name = "tab_select", .func = hexe_tab_select },
    .{ .name = "rename_tab", .func = hexe_rename_tab },
    .{ .name = "close", .func = hexe_close },
    .{ .name = "scroll", .func = hexe_scroll },
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
