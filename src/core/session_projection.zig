const std = @import("std");
const logging = @import("logging.zig");
const session_model = @import("session_model.zig");

pub const TabFocusKind = enum {
    split,
    float,
};

pub const TabMeta = struct {
    uuid: [32]u8,
    name_owned: []u8,

    pub fn deinit(self: *TabMeta, allocator: std.mem.Allocator) void {
        allocator.free(self.name_owned);
    }
};

pub const PaneShellInfo = struct {
    cmd: ?[]u8 = null,
    cwd: ?[]u8 = null,
    status: ?i32 = null,
    duration_ms: ?u64 = null,
    jobs: ?u16 = null,
    running: bool = false,
    started_at_ms: ?u64 = null,

    pub fn deinit(self: *PaneShellInfo, allocator: std.mem.Allocator) void {
        if (self.cmd) |c| allocator.free(c);
        if (self.cwd) |c| allocator.free(c);
        self.* = .{};
    }
};

pub const PaneProcInfo = struct {
    name: ?[]u8 = null,
    pid: ?i32 = null,

    pub fn deinit(self: *PaneProcInfo, allocator: std.mem.Allocator) void {
        if (self.name) |n| allocator.free(n);
        self.* = .{};
    }
};

// SessionProjection holds a view over an attached SessionSnapshot plus
// frontend-local per-pane runtime state (shell/proc/name info) that is not
// part of the canonical snapshot and therefore has no home in SES.
//
// `active_float_uuid`, `focused_pane_uuid`, and the float list all live on the
// attached snapshot. The active tab also mirrors into the attached snapshot,
// but it needs a pre-snapshot fallback: startup layout creation selects tabs
// before SES has pushed its first canonical snapshot, and dropping those writes
// makes later tab creation target tab 0 again.
pub const SessionProjection = struct {
    allocator: std.mem.Allocator,
    session_uuid: [32]u8,
    session_name_owned: []u8,
    base_root_owned: []u8,
    tab_counter: usize = 0,
    active_tab: usize = 0,
    attached_snapshot: ?session_model.SessionSnapshot = null,
    tabs: std.ArrayList(TabMeta),
    pane_shell: std.AutoHashMap([32]u8, PaneShellInfo),
    pane_proc: std.AutoHashMap([32]u8, PaneProcInfo),
    pane_names: std.AutoHashMap([32]u8, []u8),
    tab_last_floating_uuid: std.ArrayList(?[32]u8),
    tab_last_focus_kind: std.ArrayList(TabFocusKind),

    pub fn init(
        allocator: std.mem.Allocator,
        session_uuid: [32]u8,
        session_name: []const u8,
        base_root: []const u8,
    ) !SessionProjection {
        return .{
            .allocator = allocator,
            .session_uuid = session_uuid,
            .session_name_owned = try allocator.dupe(u8, session_name),
            .base_root_owned = try allocator.dupe(u8, base_root),
            .tabs = .empty,
            .pane_shell = std.AutoHashMap([32]u8, PaneShellInfo).init(allocator),
            .pane_proc = std.AutoHashMap([32]u8, PaneProcInfo).init(allocator),
            .pane_names = std.AutoHashMap([32]u8, []u8).init(allocator),
            .tab_last_floating_uuid = .empty,
            .tab_last_focus_kind = .empty,
        };
    }

    pub fn deinit(self: *SessionProjection) void {
        if (self.attached_snapshot) |*snapshot| snapshot.deinit();
        for (self.tabs.items) |*tab| tab.deinit(self.allocator);
        self.tabs.deinit(self.allocator);
        {
            var it = self.pane_shell.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.pane_shell.deinit();
        }
        {
            var it = self.pane_proc.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.pane_proc.deinit();
        }
        {
            var it = self.pane_names.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.value_ptr.*);
            }
            self.pane_names.deinit();
        }
        self.tab_last_floating_uuid.deinit(self.allocator);
        self.tab_last_focus_kind.deinit(self.allocator);
        self.allocator.free(self.session_name_owned);
        self.allocator.free(self.base_root_owned);
        self.* = undefined;
    }

    pub fn sessionName(self: *const SessionProjection) []const u8 {
        return self.session_name_owned;
    }

    pub fn sessionUuid(self: *const SessionProjection) [32]u8 {
        return self.session_uuid;
    }

    pub fn baseRoot(self: *const SessionProjection) []const u8 {
        return self.base_root_owned;
    }

    pub fn setBaseRoot(self: *SessionProjection, base_root: []const u8) !void {
        const owned = try self.allocator.dupe(u8, base_root);
        const snapshot_owned: ?[]u8 = if (self.attached_snapshot != null)
            try self.allocator.dupe(u8, base_root)
        else
            null;
        self.allocator.free(self.base_root_owned);
        self.base_root_owned = owned;
        if (self.attached_snapshot) |*snapshot| {
            if (snapshot.base_root) |old| self.allocator.free(old);
            snapshot.base_root = snapshot_owned.?;
        }
    }

    pub fn setSessionIdentity(
        self: *SessionProjection,
        session_uuid: [32]u8,
        session_name: []const u8,
    ) !void {
        const name_owned = try self.allocator.dupe(u8, session_name);
        const snapshot_name_owned: ?[]u8 = if (self.attached_snapshot != null)
            try self.allocator.dupe(u8, session_name)
        else
            null;
        self.allocator.free(self.session_name_owned);
        self.session_name_owned = name_owned;
        self.session_uuid = session_uuid;

        if (self.attached_snapshot) |*snapshot| {
            self.allocator.free(snapshot.session_name);
            snapshot.session_name = snapshot_name_owned.?;
            snapshot.uuid = session_uuid;
        }
    }

    pub fn setTabCounter(self: *SessionProjection, tab_counter: usize) void {
        self.tab_counter = tab_counter;
        if (self.attached_snapshot) |*snapshot| {
            snapshot.tab_counter = tab_counter;
        }
    }

    pub fn takeNextTabCounter(self: *SessionProjection) usize {
        const current = self.tab_counter;
        self.tab_counter = if (current < 999) current + 1 else 0;
        if (self.attached_snapshot) |*snapshot| {
            snapshot.tab_counter = self.tab_counter;
        }
        return current;
    }

    pub fn activeTab(self: *const SessionProjection, tab_count: usize) usize {
        if (tab_count == 0) return 0;
        const active = if (self.attached_snapshot) |*snapshot| snapshot.active_tab else self.active_tab;
        return @min(active, tab_count - 1);
    }

    pub fn setActiveTab(self: *SessionProjection, active_tab: usize) void {
        self.active_tab = active_tab;
        if (self.attached_snapshot) |*snapshot| {
            snapshot.active_tab = active_tab;
        }
    }

    pub fn activeFloatUuid(self: *const SessionProjection) ?[32]u8 {
        const snapshot = if (self.attached_snapshot) |*s| s else return null;
        return snapshot.active_float_uuid;
    }

    pub fn setActiveFloatUuid(self: *SessionProjection, uuid: ?[32]u8) void {
        if (self.attached_snapshot) |*snapshot| {
            snapshot.active_float_uuid = uuid;
        }
    }

    pub fn focusedPaneUuid(self: *const SessionProjection) ?[32]u8 {
        const snapshot = if (self.attached_snapshot) |*s| s else return null;
        return snapshot.focused_pane_uuid;
    }

    pub fn setFocusedPaneUuid(self: *SessionProjection, uuid: ?[32]u8) void {
        if (self.attached_snapshot) |*snapshot| {
            snapshot.focused_pane_uuid = uuid;
        }
    }

    pub fn replaceAttachedSnapshotOwned(
        self: *SessionProjection,
        snapshot: session_model.SessionSnapshot,
    ) !void {
        const next_session_name = try self.allocator.dupe(u8, snapshot.session_name);
        errdefer self.allocator.free(next_session_name);
        const next_base_root = try self.allocator.dupe(u8, snapshot.base_root orelse "");
        errdefer self.allocator.free(next_base_root);

        var next_tabs = try self.buildTabMetaFromSnapshot(snapshot.tabs.items);
        errdefer deinitTabMetaList(self.allocator, &next_tabs);

        var next_floating = try self.buildReplacementTabLastFloating(&snapshot);
        errdefer next_floating.deinit(self.allocator);

        var next_kind = try self.buildReplacementTabLastFocusKind(&snapshot, next_floating.items);
        errdefer next_kind.deinit(self.allocator);

        if (self.attached_snapshot) |*old| old.deinit();
        self.attached_snapshot = snapshot;

        self.allocator.free(self.session_name_owned);
        self.session_name_owned = next_session_name;
        self.allocator.free(self.base_root_owned);
        self.base_root_owned = next_base_root;
        self.session_uuid = snapshot.uuid;
        self.active_tab = snapshot.active_tab;

        self.clearTabMeta();
        self.tabs.deinit(self.allocator);
        self.tabs = next_tabs;

        self.tab_last_floating_uuid.deinit(self.allocator);
        self.tab_last_focus_kind.deinit(self.allocator);
        self.tab_last_floating_uuid = next_floating;
        self.tab_last_focus_kind = next_kind;

        // Normalize a corrupt tab_counter in-place while keeping projection
        // convenience field in sync.
        self.setTabCounter(if (snapshot.tab_counter > 1000) 0 else snapshot.tab_counter);
    }

    pub fn clearAttachedSnapshot(self: *SessionProjection) void {
        if (self.attached_snapshot) |*snapshot| snapshot.deinit();
        self.attached_snapshot = null;
    }

    pub fn attachedSnapshot(self: *const SessionProjection) ?*const session_model.SessionSnapshot {
        if (self.attached_snapshot) |*snapshot| return snapshot;
        return null;
    }

    pub fn paneMeta(
        self: *const SessionProjection,
        uuid: [32]u8,
    ) ?session_model.SessionPane {
        const snapshot = self.attached_snapshot orelse return null;
        return snapshot.panes.get(uuid);
    }

    pub fn floatState(
        self: *const SessionProjection,
        uuid: [32]u8,
    ) ?session_model.SessionFloat {
        const snapshot = if (self.attached_snapshot) |*s| s else return null;
        for (snapshot.floats.items) |f| {
            if (std.mem.eql(u8, &f.pane_uuid, &uuid)) return f;
        }
        return null;
    }

    fn findFloatPtr(
        snapshot: *session_model.SessionSnapshot,
        uuid: [32]u8,
    ) ?*session_model.SessionFloat {
        for (snapshot.floats.items) |*f| {
            if (std.mem.eql(u8, &f.pane_uuid, &uuid)) return f;
        }
        return null;
    }

    fn findFloat(snapshot: *const session_model.SessionSnapshot, uuid: [32]u8) ?session_model.SessionFloat {
        for (snapshot.floats.items) |f| {
            if (std.mem.eql(u8, &f.pane_uuid, &uuid)) return f;
        }
        return null;
    }

    fn floatVisibleOnTab(float_state: session_model.SessionFloat, tab: usize) bool {
        if (float_state.parent_tab) |parent| return parent == tab and float_state.visible;
        if (tab >= 64) return false;
        return (float_state.tab_visible & (@as(u64, 1) << @intCast(tab))) != 0;
    }

    fn snapshotFloatVisibleOnTab(snapshot: *const session_model.SessionSnapshot, uuid: [32]u8, tab: usize) bool {
        const float_state = findFloat(snapshot, uuid) orelse return false;
        return floatVisibleOnTab(float_state, tab);
    }

    fn buildReplacementTabLastFloating(
        self: *const SessionProjection,
        snapshot: *const session_model.SessionSnapshot,
    ) !std.ArrayList(?[32]u8) {
        var next_floating = try buildTabLastFloating(self.allocator, snapshot.tabs.items.len);
        errdefer next_floating.deinit(self.allocator);

        const preserve_len = @min(next_floating.items.len, self.tab_last_floating_uuid.items.len);
        for (0..preserve_len) |idx| {
            const uuid = self.tab_last_floating_uuid.items[idx] orelse continue;
            if (!snapshot.panes.contains(uuid)) continue;
            if (!snapshotFloatVisibleOnTab(snapshot, uuid, idx)) continue;
            next_floating.items[idx] = uuid;
        }

        if (snapshot.active_tab < next_floating.items.len) {
            if (snapshot.active_float_uuid) |uuid| {
                if (snapshotFloatVisibleOnTab(snapshot, uuid, snapshot.active_tab)) {
                    next_floating.items[snapshot.active_tab] = uuid;
                }
            }
        }

        return next_floating;
    }

    fn buildReplacementTabLastFocusKind(
        self: *const SessionProjection,
        snapshot: *const session_model.SessionSnapshot,
        next_floating: []const ?[32]u8,
    ) !std.ArrayList(TabFocusKind) {
        var next_kind = try buildTabLastFocusKind(self.allocator, snapshot.tabs.items.len);
        errdefer next_kind.deinit(self.allocator);

        const preserve_len = @min(next_kind.items.len, self.tab_last_focus_kind.items.len);
        for (0..preserve_len) |idx| {
            if (self.tab_last_focus_kind.items[idx] == .float and next_floating[idx] != null) {
                next_kind.items[idx] = .float;
            }
        }

        if (snapshot.active_tab < next_kind.items.len) {
            if (snapshot.active_float_uuid) |uuid| {
                if (snapshotFloatVisibleOnTab(snapshot, uuid, snapshot.active_tab)) {
                    next_kind.items[snapshot.active_tab] = .float;
                }
            } else if (snapshot.focused_pane_uuid) |uuid| {
                if (snapshot.panes.get(uuid)) |pane| {
                    if (pane.kind != .float) next_kind.items[snapshot.active_tab] = .split;
                }
            }
        }

        return next_kind;
    }

    pub fn syncFloatState(
        self: *SessionProjection,
        float_state: session_model.SessionFloat,
        active: bool,
    ) void {
        const snapshot = if (self.attached_snapshot) |*s| s else return;

        const pane_state = session_model.SessionPane{
            .uuid = float_state.pane_uuid,
            .kind = .float,
            .parent_tab = float_state.parent_tab,
            .sticky = float_state.sticky,
            .is_pwd = float_state.is_pwd,
            .float_key = float_state.float_key,
        };
        const had_pane = snapshot.panes.contains(float_state.pane_uuid);
        if (snapshot.panes.getPtr(float_state.pane_uuid)) |pane| {
            pane.* = pane_state;
        } else {
            snapshot.panes.put(float_state.pane_uuid, pane_state) catch |err| {
                logging.logError("session-projection", "failed to sync float pane metadata", err);
                return;
            };
        }

        if (findFloatPtr(snapshot, float_state.pane_uuid)) |existing| {
            existing.* = float_state;
        } else {
            snapshot.floats.append(self.allocator, float_state) catch |err| {
                logging.logError("session-projection", "failed to sync float state", err);
                if (!had_pane) _ = snapshot.panes.remove(float_state.pane_uuid);
                return;
            };
        }

        if (active) {
            snapshot.active_float_uuid = float_state.pane_uuid;
        } else if (snapshot.active_float_uuid) |uuid| {
            if (std.mem.eql(u8, &uuid, &float_state.pane_uuid)) {
                snapshot.active_float_uuid = null;
            }
        }
    }

    pub fn removeFloatState(self: *SessionProjection, pane_uuid: [32]u8) void {
        const snapshot = if (self.attached_snapshot) |*s| s else return;

        var idx: usize = 0;
        while (idx < snapshot.floats.items.len) : (idx += 1) {
            if (!std.mem.eql(u8, &snapshot.floats.items[idx].pane_uuid, &pane_uuid)) continue;
            _ = snapshot.floats.orderedRemove(idx);
            break;
        }
        _ = snapshot.panes.remove(pane_uuid);
        if (snapshot.active_float_uuid) |uuid| {
            if (std.mem.eql(u8, &uuid, &pane_uuid)) snapshot.active_float_uuid = null;
        }
        if (snapshot.focused_pane_uuid) |uuid| {
            if (std.mem.eql(u8, &uuid, &pane_uuid)) snapshot.focused_pane_uuid = null;
        }
    }

    pub fn setFloatVisibleOnTab(
        self: *SessionProjection,
        uuid: [32]u8,
        tab: usize,
        visible: bool,
    ) void {
        const snapshot = if (self.attached_snapshot) |*s| s else return;
        const entry = findFloatPtr(snapshot, uuid) orelse return;
        if (entry.parent_tab != null) {
            entry.visible = visible;
        } else if (tab < 64) {
            const mask = @as(u64, 1) << @intCast(tab);
            if (visible) {
                entry.tab_visible |= mask;
            } else {
                entry.tab_visible &= ~mask;
            }
        }
    }

    pub fn toggleFloatVisibleOnTab(self: *SessionProjection, uuid: [32]u8, tab: usize) void {
        const snapshot = if (self.attached_snapshot) |*s| s else return;
        const current = findFloatPtr(snapshot, uuid) orelse return;
        if (current.parent_tab != null) {
            self.setFloatVisibleOnTab(uuid, tab, !current.visible);
            return;
        }
        if (tab >= 64) return;
        const mask = @as(u64, 1) << @intCast(tab);
        self.setFloatVisibleOnTab(uuid, tab, (current.tab_visible & mask) == 0);
    }

    pub fn setFloatGeometry(
        self: *SessionProjection,
        uuid: [32]u8,
        width_pct: u8,
        height_pct: u8,
        pos_x_pct: u8,
        pos_y_pct: u8,
        pad_x: u8,
        pad_y: u8,
    ) void {
        const snapshot = if (self.attached_snapshot) |*s| s else return;
        const entry = findFloatPtr(snapshot, uuid) orelse return;
        entry.width_pct = width_pct;
        entry.height_pct = height_pct;
        entry.pos_x_pct = pos_x_pct;
        entry.pos_y_pct = pos_y_pct;
        entry.pad_x = pad_x;
        entry.pad_y = pad_y;
    }

    pub fn swapFloatGeometry(self: *SessionProjection, a_uuid: [32]u8, b_uuid: [32]u8) void {
        const snapshot = if (self.attached_snapshot) |*s| s else return;
        const a = findFloatPtr(snapshot, a_uuid) orelse return;
        const a_copy = a.*;
        const b = findFloatPtr(snapshot, b_uuid) orelse return;
        const b_copy = b.*;

        a.width_pct = b_copy.width_pct;
        a.height_pct = b_copy.height_pct;
        a.pos_x_pct = b_copy.pos_x_pct;
        a.pos_y_pct = b_copy.pos_y_pct;
        a.pad_x = b_copy.pad_x;
        a.pad_y = b_copy.pad_y;

        // Re-lookup b — prior mutation of a (via its pointer) doesn't move b
        // since both are slice-of-items pointers, but avoid aliasing concerns
        // by reading through the pointer only once per side above.
        b.width_pct = a_copy.width_pct;
        b.height_pct = a_copy.height_pct;
        b.pos_x_pct = a_copy.pos_x_pct;
        b.pos_y_pct = a_copy.pos_y_pct;
        b.pad_x = a_copy.pad_x;
        b.pad_y = a_copy.pad_y;
    }

    pub fn reindexFloatParentTabsAfterRemovedTab(self: *SessionProjection, removed_idx: usize) void {
        const snapshot = if (self.attached_snapshot) |*s| s else return;
        for (snapshot.floats.items) |*float_state| {
            if (float_state.parent_tab) |parent| {
                if (parent > removed_idx) {
                    float_state.parent_tab = parent - 1;
                }
            }
        }
        var pane_it = snapshot.panes.iterator();
        while (pane_it.next()) |entry| {
            if (entry.value_ptr.kind != .float) continue;
            if (entry.value_ptr.parent_tab) |parent| {
                if (parent > removed_idx) {
                    entry.value_ptr.parent_tab = parent - 1;
                }
            }
        }
    }

    pub fn normalizeFloatParentTabs(self: *SessionProjection, tab_count: usize) usize {
        const snapshot = if (self.attached_snapshot) |*s| s else return 0;
        var fixed: usize = 0;
        for (snapshot.floats.items) |*float_state| {
            if (float_state.parent_tab) |parent| {
                if (parent >= tab_count) {
                    float_state.parent_tab = null;
                    fixed += 1;
                }
            }
        }
        var pane_it = snapshot.panes.iterator();
        while (pane_it.next()) |entry| {
            if (entry.value_ptr.kind != .float) continue;
            if (entry.value_ptr.parent_tab) |parent| {
                if (parent >= tab_count) {
                    entry.value_ptr.parent_tab = null;
                }
            }
        }
        return fixed;
    }

    pub fn clearTabMeta(self: *SessionProjection) void {
        for (self.tabs.items) |*tab| tab.deinit(self.allocator);
        self.tabs.clearRetainingCapacity();
    }

    fn deinitTabMetaList(allocator: std.mem.Allocator, tabs: *std.ArrayList(TabMeta)) void {
        for (tabs.items) |*tab| tab.deinit(allocator);
        tabs.deinit(allocator);
    }

    fn buildTabMetaFromSnapshot(
        self: *SessionProjection,
        tabs: []const session_model.SessionTab,
    ) !std.ArrayList(TabMeta) {
        var next: std.ArrayList(TabMeta) = .empty;
        errdefer deinitTabMetaList(self.allocator, &next);

        for (tabs) |tab| {
            const name_owned = try self.allocator.dupe(u8, tab.name);
            next.append(self.allocator, .{
                .uuid = tab.uuid,
                .name_owned = name_owned,
            }) catch |err| {
                self.allocator.free(name_owned);
                return err;
            };
        }

        return next;
    }

    pub fn replaceTabMetaFromSnapshot(
        self: *SessionProjection,
        tabs: []const session_model.SessionTab,
    ) !void {
        const next = try self.buildTabMetaFromSnapshot(tabs);
        self.clearTabMeta();
        self.tabs.deinit(self.allocator);
        self.tabs = next;
    }

    pub fn appendTab(
        self: *SessionProjection,
        uuid: [32]u8,
        name: []const u8,
    ) !void {
        const name_owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_owned);
        try self.tabs.append(self.allocator, .{
            .uuid = uuid,
            .name_owned = name_owned,
        });
    }

    pub fn removeTab(self: *SessionProjection, index: usize) void {
        if (index >= self.tabs.items.len) return;
        var removed = self.tabs.orderedRemove(index);
        removed.deinit(self.allocator);
    }

    pub fn tabUuid(self: *const SessionProjection, index: usize) ?[32]u8 {
        if (index >= self.tabs.items.len) return null;
        return self.tabs.items[index].uuid;
    }

    pub fn tabName(self: *const SessionProjection, index: usize) ?[]const u8 {
        if (index >= self.tabs.items.len) return null;
        return self.tabs.items[index].name_owned;
    }

    /// Rename a tab locally (immediate display update). Persistence across
    /// reattach requires the SES-side rename too; see State.renameTab.
    pub fn setTabName(self: *SessionProjection, index: usize, name: []const u8) bool {
        if (index >= self.tabs.items.len) return false;
        const owned = self.allocator.dupe(u8, name) catch return false;
        self.allocator.free(self.tabs.items[index].name_owned);
        self.tabs.items[index].name_owned = owned;
        if (self.attached_snapshot) |*snap| {
            if (index < snap.tabs.items.len) {
                const snap_owned = snap.allocator.dupe(u8, name) catch return true;
                snap.allocator.free(snap.tabs.items[index].name);
                snap.tabs.items[index].name = snap_owned;
            }
        }
        return true;
    }

    pub fn setPaneShell(
        self: *SessionProjection,
        uuid: [32]u8,
        cmd: ?[]const u8,
        cwd: ?[]const u8,
        status: ?i32,
        duration_ms: ?u64,
        jobs: ?u16,
    ) void {
        var entry = self.pane_shell.getPtr(uuid);
        if (entry == null) {
            self.pane_shell.put(uuid, .{}) catch |err| {
                logging.logError("session_projection", "failed to allocate pane shell metadata", err);
                return;
            };
            entry = self.pane_shell.getPtr(uuid);
        }
        if (entry) |info| {
            if (cmd) |c| {
                const next = self.allocator.dupe(u8, c) catch |err| {
                    logging.logError("session_projection", "failed to copy pane shell command", err);
                    return;
                };
                if (info.cmd) |old| self.allocator.free(old);
                info.cmd = next;
            }
            if (cwd) |c| {
                const next = self.allocator.dupe(u8, c) catch |err| {
                    logging.logError("session_projection", "failed to copy pane cwd", err);
                    return;
                };
                if (info.cwd) |old| self.allocator.free(old);
                info.cwd = next;
            }
            if (status) |s| info.status = s;
            if (duration_ms) |d| info.duration_ms = d;
            if (jobs) |j| info.jobs = j;
        }
    }

    pub fn setPaneShellRunning(
        self: *SessionProjection,
        uuid: [32]u8,
        running: bool,
        started_at_ms: ?u64,
        cmd: ?[]const u8,
        cwd: ?[]const u8,
        jobs: ?u16,
    ) void {
        var entry = self.pane_shell.getPtr(uuid);
        if (entry == null) {
            self.pane_shell.put(uuid, .{}) catch |err| {
                logging.logError("session_projection", "failed to allocate pane shell metadata", err);
                return;
            };
            entry = self.pane_shell.getPtr(uuid);
        }
        if (entry) |info| {
            info.running = running;
            if (started_at_ms) |t| info.started_at_ms = t;
            if (cmd) |c| {
                const next = self.allocator.dupe(u8, c) catch |err| {
                    logging.logError("session_projection", "failed to copy running pane command", err);
                    return;
                };
                if (info.cmd) |old| self.allocator.free(old);
                info.cmd = next;
            }
            if (cwd) |c| {
                const next = self.allocator.dupe(u8, c) catch |err| {
                    logging.logError("session_projection", "failed to copy running pane cwd", err);
                    return;
                };
                if (info.cwd) |old| self.allocator.free(old);
                info.cwd = next;
            }
            if (jobs) |j| info.jobs = j;
        }
    }

    pub fn clearPaneShellStartedAt(self: *SessionProjection, uuid: [32]u8) void {
        if (self.pane_shell.getPtr(uuid)) |info| {
            info.started_at_ms = null;
        }
    }

    pub fn getPaneShell(self: *const SessionProjection, uuid: [32]u8) ?PaneShellInfo {
        return self.pane_shell.get(uuid);
    }

    pub fn setPaneProc(self: *SessionProjection, uuid: [32]u8, name: ?[]const u8, pid: ?i32) void {
        var entry = self.pane_proc.getPtr(uuid);
        if (entry == null) {
            self.pane_proc.put(uuid, .{}) catch |err| {
                logging.logError("session_projection", "failed to allocate pane process metadata", err);
                return;
            };
            entry = self.pane_proc.getPtr(uuid);
        }
        if (entry) |info| {
            if (name) |n| {
                const next = self.allocator.dupe(u8, n) catch |err| {
                    logging.logError("session_projection", "failed to copy pane process name", err);
                    return;
                };
                if (info.name) |old| self.allocator.free(old);
                info.name = next;
            }
            if (pid) |p| info.pid = p;
        }
    }

    pub fn getPaneProc(self: *const SessionProjection, uuid: [32]u8) ?PaneProcInfo {
        return self.pane_proc.get(uuid);
    }

    pub fn removePaneProc(self: *SessionProjection, uuid: [32]u8) void {
        if (self.pane_proc.fetchRemove(uuid)) |kv| {
            var info = kv.value;
            info.deinit(self.allocator);
        }
    }

    pub fn setPaneNameOwned(self: *SessionProjection, uuid: [32]u8, name_owned: []u8) void {
        if (self.pane_names.getPtr(uuid)) |slot| {
            self.allocator.free(slot.*);
            slot.* = name_owned;
            return;
        }
        self.pane_names.put(uuid, name_owned) catch |err| {
            logging.logError("session_projection", "failed to store pane name", err);
            self.allocator.free(name_owned);
        };
    }

    pub fn paneName(self: *const SessionProjection, uuid: [32]u8) ?[]const u8 {
        return self.pane_names.get(uuid);
    }

    pub fn hasPaneName(self: *const SessionProjection, uuid: [32]u8) bool {
        return self.pane_names.contains(uuid);
    }

    pub fn removePaneName(self: *SessionProjection, uuid: [32]u8) void {
        if (self.pane_names.fetchRemove(uuid)) |kv| {
            self.allocator.free(kv.value);
        }
    }

    fn buildTabLastFloating(allocator: std.mem.Allocator, tab_count: usize) !std.ArrayList(?[32]u8) {
        var next_floating: std.ArrayList(?[32]u8) = .empty;
        errdefer next_floating.deinit(allocator);

        for (0..tab_count) |_| {
            try next_floating.append(allocator, null);
        }

        return next_floating;
    }

    fn buildTabLastFocusKind(allocator: std.mem.Allocator, tab_count: usize) !std.ArrayList(TabFocusKind) {
        var next_kind: std.ArrayList(TabFocusKind) = .empty;
        errdefer next_kind.deinit(allocator);

        for (0..tab_count) |_| {
            try next_kind.append(allocator, .split);
        }

        return next_kind;
    }

    pub fn resetTabFocusMemory(self: *SessionProjection, tab_count: usize) !void {
        var next_floating = try buildTabLastFloating(self.allocator, tab_count);
        errdefer next_floating.deinit(self.allocator);

        var next_kind = try buildTabLastFocusKind(self.allocator, tab_count);
        errdefer next_kind.deinit(self.allocator);

        self.tab_last_floating_uuid.deinit(self.allocator);
        self.tab_last_focus_kind.deinit(self.allocator);
        self.tab_last_floating_uuid = next_floating;
        self.tab_last_focus_kind = next_kind;
    }

    pub fn appendTabFocusMemory(self: *SessionProjection) !void {
        try self.tab_last_floating_uuid.append(self.allocator, null);
        errdefer _ = self.tab_last_floating_uuid.pop();
        try self.tab_last_focus_kind.append(self.allocator, .split);
    }

    pub fn removeTabFocusMemory(self: *SessionProjection, index: usize) void {
        if (index < self.tab_last_floating_uuid.items.len) {
            _ = self.tab_last_floating_uuid.orderedRemove(index);
        }
        if (index < self.tab_last_focus_kind.items.len) {
            _ = self.tab_last_focus_kind.orderedRemove(index);
        }
    }

    pub fn clearTabFocusMemory(self: *SessionProjection) void {
        self.tab_last_floating_uuid.clearRetainingCapacity();
        self.tab_last_focus_kind.clearRetainingCapacity();
    }

    pub fn rememberFloatingFocus(
        self: *SessionProjection,
        active_tab: usize,
        pane_uuid: [32]u8,
    ) void {
        if (active_tab >= self.tab_last_floating_uuid.items.len) return;
        self.tab_last_floating_uuid.items[active_tab] = pane_uuid;
        if (active_tab < self.tab_last_focus_kind.items.len) {
            self.tab_last_focus_kind.items[active_tab] = .float;
        }
    }

    pub fn rememberSplitFocus(self: *SessionProjection, active_tab: usize) void {
        if (active_tab < self.tab_last_focus_kind.items.len) {
            self.tab_last_focus_kind.items[active_tab] = .split;
        }
    }

    pub fn lastFocusKind(
        self: *const SessionProjection,
        active_tab: usize,
    ) ?TabFocusKind {
        if (active_tab >= self.tab_last_focus_kind.items.len) return null;
        return self.tab_last_focus_kind.items[active_tab];
    }

    pub fn lastFloatingUuid(
        self: *const SessionProjection,
        active_tab: usize,
    ) ?[32]u8 {
        if (active_tab >= self.tab_last_floating_uuid.items.len) return null;
        return self.tab_last_floating_uuid.items[active_tab];
    }
};
