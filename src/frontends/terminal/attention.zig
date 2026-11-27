//! Pane status & attention queue management.
//!
//! Coordinates per-pane lifecycle status (`idle`, `working`, `blocked`, `done`),
//! event emission (`pane_status_changed`), cross-tab/float jump-to-attention
//! (`pane.attention_next`), and the interactive attention picker (`pane.attention_list`).

const std = @import("std");
const core = @import("core");
const pop = @import("pop");
const frontend_core = @import("frontend_core");

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;
const lua_events = @import("lua_events.zig");
const tab_switch = @import("tab_switch.zig");
const state_tabs = @import("state_tabs.zig");

pub const MAX_ATTENTION_ITEMS = 64;

pub const AttentionItem = struct {
    pane: *Pane,
    uuid: [32]u8,
    rank: u8,
    updated_at_ms: i64,
    is_float: bool,
    tab_idx: ?usize,
};

pub const TabRollup = struct {
    attention_count: usize = 0,
    status: core.pane_status.Status = .idle,
};

fn paneIsCurrentlyFocused(state: *State, pane: *const Pane) bool {
    if (state.getCurrentFocusedUuid()) |fu| {
        return std.mem.eql(u8, &fu, &pane.uuid);
    }
    return pane.focused;
}

/// Resolve the preferred tab index for any floating pane:
/// 1. Explicit `parent_tab` for tab-bound floats.
/// 2. For `per_cwd` / `per_git` floats: first tab whose CWD/git-root matches
///    the float's sticky directory (preferring a tab where it is already visible).
/// 3. For global floats: active tab if currently visible there, else lowest
///    tab index set in `tab_visible`.
fn floatPreferredTab(state: *State, pane: *Pane) ?usize {
    if (state.paneParentTab(pane)) |pt| return pt;
    const fs = state.outerFloatState(pane) orelse return null;
    const tab_count = state.view.tab_views.items.len;
    if (tab_count == 0) return null;

    if (fs.is_pwd) {
        if (state_tabs.ensureStickyFloatDir(state, pane)) |fdir| {
            const fkey = fs.float_key;
            const is_git = if (fkey != 0)
                (if (state.getLayoutFloatByKey(fkey)) |fdef| fdef.attributes.per_git else false)
            else
                false;
            var first_match: ?usize = null;
            for (state.view.tab_views.items, 0..) |*tab, idx| {
                const tiled = tab.layout.getFocusedPane() orelse continue;
                const tab_cwd = state.paneRealCwd(tiled) orelse continue;
                var git_buf: [std.fs.max_path_bytes]u8 = undefined;
                const tab_key_dir: []const u8 = if (is_git)
                    (core.config.gitRootOf(tab_cwd, &git_buf) orelse tab_cwd)
                else
                    tab_cwd;
                if (std.mem.eql(u8, fdir, tab_key_dir)) {
                    if (idx < 64 and (fs.tab_visible & (@as(u64, 1) << @intCast(idx))) != 0) {
                        return idx;
                    }
                    if (first_match == null) first_match = idx;
                }
            }
            if (first_match) |m| return m;
        }
    }

    if (fs.tab_visible != 0) {
        const active = state.activeTabIndex();
        if (active < 64 and active < tab_count and (fs.tab_visible & (@as(u64, 1) << @intCast(active))) != 0) {
            return active;
        }
        const first: usize = @intCast(@ctz(fs.tab_visible));
        if (first < tab_count) return first;
    }
    return null;
}

/// Emit `pane_status_changed` to Lua handlers and control-socket subscribers.
pub fn emitStatusChanged(state: *State, pane: *Pane) void {
    const rt = state.config._lua_runtime orelse return;
    const is_float = state.paneIsFloating(pane);
    const focused = paneIsCurrentlyFocused(state, pane);
    const parent_tab = if (is_float) floatPreferredTab(state, pane) else state.paneParentTab(pane);

    const lua = rt.lua;
    lua.createTable(0, 10);
    _ = lua.pushString("pane_status_changed");
    lua.setField(-2, "event");
    lua.pushInteger(@intCast(std.time.milliTimestamp()));
    lua.setField(-2, "now_ms");
    _ = lua.pushString(pane.uuid[0..]);
    lua.setField(-2, "pane_uuid");
    _ = lua.pushString(pane.status_state.status.toString());
    lua.setField(-2, "status");
    if (pane.status_state.note()) |note| {
        _ = lua.pushString(note);
    } else {
        lua.pushNil();
    }
    lua.setField(-2, "note");
    lua.pushBoolean(pane.status_state.needsAttentionNow(focused));
    lua.setField(-2, "attention");
    lua.pushInteger(pane.status_state.updated_at_ms);
    lua.setField(-2, "updated_at_ms");
    lua.pushBoolean(is_float);
    lua.setField(-2, "is_float");
    if (parent_tab) |t| {
        lua.pushInteger(@intCast(t + 1));
    } else {
        lua.pushNil();
    }
    lua.setField(-2, "tab");
    if (state.paneName(pane.uuid)) |nm| {
        _ = lua.pushString(nm);
    } else {
        lua.pushNil();
    }
    lua.setField(-2, "name");

    lua_events.emitWithState(state, rt, "pane_status_changed");
}

fn paneDisplayLabel(state: *State, pane: *Pane, buf: []u8) []const u8 {
    if (state.paneIsFloating(pane)) {
        if (state.paneFloatTitle(pane)) |t| {
            if (t.len > 0) return std.fmt.bufPrint(buf, "{s}", .{t}) catch t;
        }
    }
    if (state.paneName(pane.uuid)) |nm| {
        if (nm.len > 0) return std.fmt.bufPrint(buf, "{s}", .{nm}) catch nm;
    }
    return std.fmt.bufPrint(buf, "{s}", .{pane.uuid[0..8]}) catch pane.uuid[0..8];
}

/// Present a non-intrusive toast (and desktop notification when enabled) when
/// an unfocused pane transitions into `blocked` or `done`.
fn notifyStatusAttention(state: *State, pane: *Pane) void {
    const st = pane.status_state.status;
    if (!st.needsAttention()) return;

    var label_buf: [96]u8 = undefined;
    const label = paneDisplayLabel(state, pane, &label_buf);

    var msg_buf: [320]u8 = undefined;
    const msg = if (pane.status_state.note()) |note|
        std.fmt.bufPrint(&msg_buf, "[{s}] {s}: {s}", .{ label, st.toString(), note }) catch return
    else
        std.fmt.bufPrint(&msg_buf, "[{s}] {s}", .{ label, st.toString() }) catch return;

    state.notifications.showFor(msg, 2600);

    if (frontend_core.defaultCapabilities(.terminal).desktop_notify) {
        var title_buf: [160]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "hexe {s} — {s}", .{ label, st.toString() }) catch return;
        const body = pane.status_state.note() orelse st.toString();
        const stdout = std.fs.File.stdout();
        var writer_buf: [512]u8 = undefined;
        var writer = stdout.writer(&writer_buf);
        state.renderer.vx.notify(&writer.interface, title, body) catch |err| {
            core.logging.logError("terminal", "pane status desktop notification failed", err);
        };
    }
}

/// Handle a status change that arrived via OSC 1333 from inside a pane.
pub fn handleOscStatusChanged(state: *State, pane: *Pane, present: bool) void {
    const focused = paneIsCurrentlyFocused(state, pane);
    // Keep attention consistent with live focus state (pane.focused can lag on floats).
    if (focused) {
        pane.status_state.attention = false;
    } else if (pane.status_state.status.needsAttention()) {
        pane.status_state.attention = true;
    }
    emitStatusChanged(state, pane);
    if (present and !focused and pane.status_state.status.needsAttention()) {
        notifyStatusAttention(state, pane);
    }
    state.needs_render = true;
}

/// Explicitly set a pane's status from the live API or CLI.
pub fn setPaneStatus(
    state: *State,
    pane: *Pane,
    next: core.pane_status.Status,
    note_opt: ?[]const u8,
) void {
    const focused = paneIsCurrentlyFocused(state, pane);
    const now_ms = std.time.milliTimestamp();
    const changed = pane.status_state.set(next, note_opt, focused, now_ms);
    if (!changed) return;

    emitStatusChanged(state, pane);
    if (!focused and next.needsAttention()) {
        notifyStatusAttention(state, pane);
    }
    state.needs_render = true;
}

/// Clear a pane's status and attention flag back to `idle`.
pub fn clearPaneStatus(state: *State, pane: *Pane) bool {
    const now_ms = std.time.milliTimestamp();
    if (!pane.status_state.clear(now_ms)) return false;
    emitStatusChanged(state, pane);
    state.needs_render = true;
    return true;
}

/// Collect all live unfocused panes needing attention, ordered by urgency
/// (`blocked` > `done` > notification) then oldest update first.
pub fn collect(state: *State, out: *[MAX_ATTENTION_ITEMS]AttentionItem) usize {
    var n: usize = 0;

    for (state.view.tab_views.items, 0..) |*tab, tab_idx| {
        var it = tab.layout.splitIterator();
        while (it.next()) |pane_ptr| {
            if (n >= MAX_ATTENTION_ITEMS) break;
            const pane = pane_ptr.*;
            if (!pane.isAlive()) continue;
            const focused = paneIsCurrentlyFocused(state, pane);
            const rank = pane.status_state.attentionRank(focused);
            if (rank == 0) continue;
            out[n] = .{
                .pane = pane,
                .uuid = pane.uuid,
                .rank = rank,
                .updated_at_ms = pane.status_state.updated_at_ms,
                .is_float = false,
                .tab_idx = tab_idx,
            };
            n += 1;
        }
    }

    for (state.view.float_views.items) |pane| {
        if (n >= MAX_ATTENTION_ITEMS) break;
        if (!pane.isAlive()) continue;
        const focused = paneIsCurrentlyFocused(state, pane);
        const rank = pane.status_state.attentionRank(focused);
        if (rank == 0) continue;
        out[n] = .{
            .pane = pane,
            .uuid = pane.uuid,
            .rank = rank,
            .updated_at_ms = pane.status_state.updated_at_ms,
            .is_float = true,
            .tab_idx = floatPreferredTab(state, pane),
        };
        n += 1;
    }

    std.mem.sort(AttentionItem, out[0..n], {}, struct {
        fn lessThan(_: void, a: AttentionItem, b: AttentionItem) bool {
            if (a.rank != b.rank) return a.rank > b.rank;
            if (a.updated_at_ms != b.updated_at_ms) return a.updated_at_ms < b.updated_at_ms;
            return std.mem.lessThan(u8, &a.uuid, &b.uuid);
        }
    }.lessThan);

    return n;
}

/// Fast count of unfocused live panes currently needing attention.
pub fn countAttention(state: *State) u16 {
    var total: u16 = 0;
    for (state.view.tab_views.items) |*tab| {
        var it = tab.layout.splitIterator();
        while (it.next()) |pane_ptr| {
            const pane = pane_ptr.*;
            if (!pane.isAlive()) continue;
            if (pane.status_state.needsAttentionNow(paneIsCurrentlyFocused(state, pane))) {
                total +|= 1;
            }
        }
    }
    for (state.view.float_views.items) |pane| {
        if (!pane.isAlive()) continue;
        if (pane.status_state.needsAttentionNow(paneIsCurrentlyFocused(state, pane))) {
            total +|= 1;
        }
    }
    return total;
}

/// Rollup of attention count and highest-priority status for one tab
/// (includes tiled splits on `tab_idx` and tab-bound floats owned by `tab_idx`).
pub fn tabRollup(state: *State, tab_idx: usize) TabRollup {
    var out = TabRollup{};
    if (tab_idx >= state.view.tab_views.items.len) return out;

    var it = state.view.tab_views.items[tab_idx].layout.splitIterator();
    while (it.next()) |pane_ptr| {
        const pane = pane_ptr.*;
        if (!pane.isAlive()) continue;
        if (pane.status_state.status.priority() > out.status.priority()) {
            out.status = pane.status_state.status;
        }
        if (pane.status_state.needsAttentionNow(paneIsCurrentlyFocused(state, pane))) {
            out.attention_count += 1;
        }
    }

    for (state.view.float_views.items) |pane| {
        if (!pane.isAlive()) continue;
        const pt = floatPreferredTab(state, pane) orelse continue;
        if (pt != tab_idx) continue;
        if (pane.status_state.status.priority() > out.status.priority()) {
            out.status = pane.status_state.status;
        }
        if (pane.status_state.needsAttentionNow(paneIsCurrentlyFocused(state, pane))) {
            out.attention_count += 1;
        }
    }

    return out;
}

/// Focus any live pane across tabs, hidden floats, or sub-float chips.
pub fn focusPaneAnywhere(state: *State, pane: *Pane) bool {
    if (!pane.isAlive()) return false;

    if (state.paneIsFloating(pane)) {
        if (floatPreferredTab(state, pane)) |pt| {
            if (pt < state.view.tab_views.items.len and pt != state.activeTabIndex()) {
                tab_switch.switchToTab(state, pt);
            }
        }
        const active_tab = state.activeTabIndex();
        var vis_changed = false;
        if (!state.paneVisibleOnTab(pane, active_tab)) {
            state.setPaneVisibleOnTab(pane, active_tab, true);
            vis_changed = true;
        }
        if (!state.isCurrentFamilyMember(pane)) {
            _ = state.showFamilyMember(pane.uuid, true);
            state.needs_render = true;
            state.force_full_render = true;
            return true;
        }
        state.unfocusAllPanes();
        for (state.view.float_views.items, 0..) |fp, i| {
            if (fp == pane) {
                state.setActiveFloatingIndex(i);
                fp.focused = true;
                break;
            }
        }
        if (vis_changed) {
            _ = state.syncFamilyFloats(pane, true);
        }
    } else {
        if (state.paneParentTab(pane)) |t| {
            if (t < state.view.tab_views.items.len and t != state.activeTabIndex()) {
                tab_switch.switchToTab(state, t);
            }
        }
        state.clearZoom();
        state.setActiveFloatingIndex(null);
        state.unfocusAllPanes();
        pane.focused = true;
        if (state.paneParentTab(pane)) |t| {
            if (t < state.view.tab_views.items.len) {
                state.view.tab_views.items[t].layout.focused_pane_uuid = pane.uuid;
            }
        }
    }

    state.syncPaneFocus(pane, null);
    state.needs_render = true;
    state.force_full_render = true;
    return true;
}

/// Jump directly to the highest-priority pane needing attention.
pub fn jumpNext(state: *State) void {
    var items: [MAX_ATTENTION_ITEMS]AttentionItem = undefined;
    const count = collect(state, &items);
    if (count == 0) {
        state.notifications.showFor("No panes need attention", 1400);
        state.needs_render = true;
        return;
    }

    const target = items[0];
    var label_buf: [96]u8 = undefined;
    const label = paneDisplayLabel(state, target.pane, &label_buf);
    const status_str = if (target.pane.status_state.status != .idle)
        target.pane.status_state.status.toString()
    else
        "notice";

    if (focusPaneAnywhere(state, target.pane)) {
        var msg_buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Attention: {s} ({s})", .{ label, status_str }) catch "Jumped to pane";
        state.notifications.showFor(msg, 1600);
    }
}

/// Open an interactive filterable picker of all panes needing attention.
pub fn openPicker(state: *State) void {
    var items: [MAX_ATTENTION_ITEMS]AttentionItem = undefined;
    const count = collect(state, &items);
    state.attention_count = count;

    if (count == 0) {
        state.notifications.showFor("No panes need attention", 1400);
        state.needs_render = true;
        return;
    }

    var label_storage: [MAX_ATTENTION_ITEMS][128]u8 = undefined;
    var badge_storage: [MAX_ATTENTION_ITEMS][24]u8 = undefined;
    var detail_storage: [MAX_ATTENTION_ITEMS][256]u8 = undefined;
    var labels: [MAX_ATTENTION_ITEMS][]const u8 = undefined;
    var badges: [MAX_ATTENTION_ITEMS][]const u8 = undefined;
    var details: [MAX_ATTENTION_ITEMS][]const u8 = undefined;

    for (items[0..count], 0..) |item, i| {
        state.attention_uuids[i] = item.uuid;
        var name_buf: [96]u8 = undefined;
        const disp = paneDisplayLabel(state, item.pane, &name_buf);

        labels[i] = if (item.is_float) blk: {
            if (item.tab_idx) |t| {
                break :blk std.fmt.bufPrint(&label_storage[i], "{s}  (float · tab {d})", .{ disp, t + 1 }) catch disp;
            }
            break :blk std.fmt.bufPrint(&label_storage[i], "{s}  (float)", .{disp}) catch disp;
        } else blk: {
            const tab_num = (item.tab_idx orelse 0) + 1;
            break :blk std.fmt.bufPrint(&label_storage[i], "{s}  (tab {d})", .{ disp, tab_num }) catch disp;
        };

        badges[i] = if (item.pane.status_state.status == .blocked)
            std.fmt.bufPrint(&badge_storage[i], "blocked", .{}) catch "blocked"
        else if (item.pane.status_state.status == .done)
            std.fmt.bufPrint(&badge_storage[i], "done", .{}) catch "done"
        else
            std.fmt.bufPrint(&badge_storage[i], "notice", .{}) catch "notice";

        if (item.pane.status_state.note()) |note| {
            details[i] = std.fmt.bufPrint(&detail_storage[i], "{s}", .{note}) catch note;
        } else if (state.paneRealCwd(item.pane)) |cwd| {
            var home_buf: [256]u8 = undefined;
            const compact = core.cli_ui.compactHome(cwd, &home_buf);
            details[i] = std.fmt.bufPrint(&detail_storage[i], "{s}", .{compact}) catch compact;
        } else {
            details[i] = "";
        }
    }

    _ = state.showPickerWithOptions(.attention_choose, labels[0..count], .{
        .title = "Panes needing attention",
        .badges = badges[0..count],
        .details = details[0..count],
        .hint = "↑↓/jk move · / filter · Enter jump · x clear · Esc cancel",
        .filterable = true,
        .action_keys = "x",
    });
}

fn findPaneByUuid(state: *State, uuid: [32]u8) ?*Pane {
    for (state.view.tab_views.items) |*tab| {
        var it = tab.layout.splitIterator();
        while (it.next()) |pane_ptr| {
            if (std.mem.eql(u8, &pane_ptr.*.uuid, &uuid)) return pane_ptr.*;
        }
    }
    for (state.view.float_views.items) |pane| {
        if (std.mem.eql(u8, &pane.uuid, &uuid)) return pane;
    }
    return null;
}

/// Handle a choice or hotkey from the attention picker.
pub fn handlePickerResult(state: *State, selected: ?usize, act: ?pop.PickerAction) void {
    if (selected) |idx| {
        if (idx < state.attention_count) {
            if (findPaneByUuid(state, state.attention_uuids[idx])) |pane| {
                _ = focusPaneAnywhere(state, pane);
                return;
            }
        }
        state.notifications.showFor("Pane is no longer available", 1400);
        state.needs_render = true;
        return;
    }

    if (act) |picker_act| {
        if (picker_act.key == 'x') {
            if (picker_act.selected) |idx| {
                if (idx < state.attention_count) {
                    if (findPaneByUuid(state, state.attention_uuids[idx])) |pane| {
                        _ = clearPaneStatus(state, pane);
                    }
                }
            }
            if (countAttention(state) > 0) {
                openPicker(state);
            } else {
                state.notifications.showFor("All attention cleared", 1400);
                state.needs_render = true;
            }
            return;
        }
    }
    state.needs_render = true;
}
