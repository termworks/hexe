const std = @import("std");
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

pub const SessionProjection = struct {
    allocator: std.mem.Allocator,
    session_uuid: [32]u8,
    session_name_owned: []u8,
    tab_counter: usize = 0,
    active_tab: usize = 0,
    active_float_uuid: ?[32]u8 = null,
    focused_pane_uuid: ?[32]u8 = null,
    attached_snapshot: ?session_model.SessionSnapshot = null,
    tabs: std.ArrayList(TabMeta),
    local_floats: std.AutoHashMap([32]u8, session_model.SessionFloat),
    pane_shell: std.AutoHashMap([32]u8, PaneShellInfo),
    pane_proc: std.AutoHashMap([32]u8, PaneProcInfo),
    pane_names: std.AutoHashMap([32]u8, []u8),
    tab_last_floating_uuid: std.ArrayList(?[32]u8),
    tab_last_focus_kind: std.ArrayList(TabFocusKind),

    pub fn init(
        allocator: std.mem.Allocator,
        session_uuid: [32]u8,
        session_name: []const u8,
    ) !SessionProjection {
        return .{
            .allocator = allocator,
            .session_uuid = session_uuid,
            .session_name_owned = try allocator.dupe(u8, session_name),
            .tabs = .empty,
            .local_floats = std.AutoHashMap([32]u8, session_model.SessionFloat).init(allocator),
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
        self.local_floats.deinit();
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
        self.* = undefined;
    }

    pub fn sessionName(self: *const SessionProjection) []const u8 {
        return self.session_name_owned;
    }

    pub fn sessionUuid(self: *const SessionProjection) [32]u8 {
        return self.session_uuid;
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
        return @min(self.active_tab, tab_count - 1);
    }

    pub fn setActiveTab(self: *SessionProjection, active_tab: usize) void {
        self.active_tab = active_tab;
        if (self.attached_snapshot) |*snapshot| {
            snapshot.active_tab = active_tab;
        }
    }

    pub fn activeFloatUuid(self: *const SessionProjection) ?[32]u8 {
        return self.active_float_uuid;
    }

    pub fn setActiveFloatUuid(self: *SessionProjection, uuid: ?[32]u8) void {
        self.active_float_uuid = uuid;
        if (self.attached_snapshot) |*snapshot| {
            snapshot.active_float_uuid = uuid;
        }
    }

    pub fn focusedPaneUuid(self: *const SessionProjection) ?[32]u8 {
        return self.focused_pane_uuid;
    }

    pub fn setFocusedPaneUuid(self: *SessionProjection, uuid: ?[32]u8) void {
        self.focused_pane_uuid = uuid;
        if (self.attached_snapshot) |*snapshot| {
            snapshot.focused_pane_uuid = uuid;
        }
    }

    pub fn replaceAttachedSnapshotOwned(
        self: *SessionProjection,
        snapshot: session_model.SessionSnapshot,
    ) !void {
        if (self.attached_snapshot) |*old| old.deinit();
        self.attached_snapshot = snapshot;
        self.local_floats.clearRetainingCapacity();
        for (snapshot.floats.items) |float_state| {
            try self.local_floats.put(float_state.pane_uuid, float_state);
        }
        try self.setSessionIdentity(snapshot.uuid, snapshot.session_name);
        self.setTabCounter(if (snapshot.tab_counter > 1000) 0 else snapshot.tab_counter);
        self.setActiveTab(snapshot.active_tab);
        self.setActiveFloatUuid(snapshot.active_float_uuid);
        self.setFocusedPaneUuid(snapshot.focused_pane_uuid);
        try self.replaceTabMetaFromSnapshot(snapshot.tabs.items);
        try self.resetTabFocusMemory(snapshot.tabs.items.len);
    }

    pub fn clearAttachedSnapshot(self: *SessionProjection) void {
        if (self.attached_snapshot) |*snapshot| snapshot.deinit();
        self.attached_snapshot = null;
        self.local_floats.clearRetainingCapacity();
    }

    pub fn attachedSnapshot(self: *const SessionProjection) ?*const session_model.SessionSnapshot {
        if (self.attached_snapshot) |*snapshot| return snapshot;
        return null;
    }

    pub fn paneMeta(
        self: *const SessionProjection,
        uuid: [32]u8,
    ) ?session_model.SessionPane {
        if (self.local_floats.get(uuid)) |float_state| {
            return .{
                .uuid = uuid,
                .kind = .float,
                .parent_tab = float_state.parent_tab,
                .sticky = float_state.sticky,
                .is_pwd = float_state.is_pwd,
                .float_key = float_state.float_key,
            };
        }
        const snapshot = self.attached_snapshot orelse return null;
        return snapshot.panes.get(uuid);
    }

    pub fn floatState(
        self: *const SessionProjection,
        uuid: [32]u8,
    ) ?session_model.SessionFloat {
        return self.local_floats.get(uuid);
    }

    pub fn syncFloatState(
        self: *SessionProjection,
        float_state: session_model.SessionFloat,
        active: bool,
    ) void {
        self.local_floats.put(float_state.pane_uuid, float_state) catch return;
        if (self.attached_snapshot) |*snapshot| {
            const pane_state = session_model.SessionPane{
                .uuid = float_state.pane_uuid,
                .kind = .float,
                .parent_tab = float_state.parent_tab,
                .sticky = float_state.sticky,
                .is_pwd = float_state.is_pwd,
                .float_key = float_state.float_key,
            };
            if (snapshot.panes.getPtr(float_state.pane_uuid)) |pane| {
                pane.* = pane_state;
            } else {
                snapshot.panes.put(float_state.pane_uuid, pane_state) catch {};
            }

            for (snapshot.floats.items) |*existing| {
                if (!std.mem.eql(u8, &existing.pane_uuid, &float_state.pane_uuid)) continue;
                existing.* = float_state;
                if (active) {
                    snapshot.active_float_uuid = float_state.pane_uuid;
                } else if (snapshot.active_float_uuid) |uuid| {
                    if (std.mem.eql(u8, &uuid, &float_state.pane_uuid)) {
                        snapshot.active_float_uuid = null;
                    }
                }
                return;
            }

            snapshot.floats.append(self.allocator, float_state) catch return;
            if (active) snapshot.active_float_uuid = float_state.pane_uuid;
        }
        if (active) {
            self.active_float_uuid = float_state.pane_uuid;
            self.focused_pane_uuid = float_state.pane_uuid;
        } else if (self.active_float_uuid) |uuid| {
            if (std.mem.eql(u8, &uuid, &float_state.pane_uuid) and !float_state.visible) {
                self.active_float_uuid = null;
            }
        }
    }

    pub fn removeFloatState(self: *SessionProjection, pane_uuid: [32]u8) void {
        _ = self.local_floats.remove(pane_uuid);
        if (self.attached_snapshot) |*snapshot| {
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
        if (self.active_float_uuid) |uuid| {
            if (std.mem.eql(u8, &uuid, &pane_uuid)) self.active_float_uuid = null;
        }
        if (self.focused_pane_uuid) |uuid| {
            if (std.mem.eql(u8, &uuid, &pane_uuid)) self.focused_pane_uuid = null;
        }
    }

    pub fn setFloatVisibleOnTab(
        self: *SessionProjection,
        uuid: [32]u8,
        tab: usize,
        visible: bool,
    ) void {
        const entry = self.local_floats.getPtr(uuid) orelse return;
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
        self.syncFloatState(entry.*, self.active_float_uuid != null and std.mem.eql(u8, &(self.active_float_uuid.?), &uuid));
    }

    pub fn toggleFloatVisibleOnTab(self: *SessionProjection, uuid: [32]u8, tab: usize) void {
        const current = self.local_floats.get(uuid) orelse return;
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
        const entry = self.local_floats.getPtr(uuid) orelse return;
        entry.width_pct = width_pct;
        entry.height_pct = height_pct;
        entry.pos_x_pct = pos_x_pct;
        entry.pos_y_pct = pos_y_pct;
        entry.pad_x = pad_x;
        entry.pad_y = pad_y;
        self.syncFloatState(entry.*, self.active_float_uuid != null and std.mem.eql(u8, &(self.active_float_uuid.?), &uuid));
    }

    pub fn swapFloatGeometry(self: *SessionProjection, a_uuid: [32]u8, b_uuid: [32]u8) void {
        const a = self.local_floats.get(a_uuid) orelse return;
        const b = self.local_floats.get(b_uuid) orelse return;

        var new_a = a;
        var new_b = b;

        new_a.width_pct = b.width_pct;
        new_a.height_pct = b.height_pct;
        new_a.pos_x_pct = b.pos_x_pct;
        new_a.pos_y_pct = b.pos_y_pct;
        new_a.pad_x = b.pad_x;
        new_a.pad_y = b.pad_y;

        new_b.width_pct = a.width_pct;
        new_b.height_pct = a.height_pct;
        new_b.pos_x_pct = a.pos_x_pct;
        new_b.pos_y_pct = a.pos_y_pct;
        new_b.pad_x = a.pad_x;
        new_b.pad_y = a.pad_y;

        self.syncFloatState(new_a, self.active_float_uuid != null and std.mem.eql(u8, &(self.active_float_uuid.?), &a_uuid));
        self.syncFloatState(new_b, self.active_float_uuid != null and std.mem.eql(u8, &(self.active_float_uuid.?), &b_uuid));
    }

    pub fn reindexFloatParentTabsAfterRemovedTab(self: *SessionProjection, removed_idx: usize) void {
        var it = self.local_floats.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.parent_tab) |parent| {
                if (parent > removed_idx) {
                    entry.value_ptr.parent_tab = parent - 1;
                }
            }
        }
        if (self.attached_snapshot) |*snapshot| {
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
    }

    pub fn normalizeFloatParentTabs(self: *SessionProjection, tab_count: usize) usize {
        var fixed: usize = 0;
        var it = self.local_floats.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.parent_tab) |parent| {
                if (parent >= tab_count) {
                    entry.value_ptr.parent_tab = null;
                    fixed += 1;
                }
            }
        }
        if (self.attached_snapshot) |*snapshot| {
            for (snapshot.floats.items) |*float_state| {
                if (float_state.parent_tab) |parent| {
                    if (parent >= tab_count) {
                        float_state.parent_tab = null;
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
        }
        return fixed;
    }

    pub fn clearTabMeta(self: *SessionProjection) void {
        for (self.tabs.items) |*tab| tab.deinit(self.allocator);
        self.tabs.clearRetainingCapacity();
    }

    pub fn replaceTabMetaFromSnapshot(
        self: *SessionProjection,
        tabs: []const session_model.SessionTab,
    ) !void {
        self.clearTabMeta();
        for (tabs) |tab| {
            try self.appendTab(tab.uuid, tab.name);
        }
    }

    pub fn appendTab(
        self: *SessionProjection,
        uuid: [32]u8,
        name: []const u8,
    ) !void {
        try self.tabs.append(self.allocator, .{
            .uuid = uuid,
            .name_owned = try self.allocator.dupe(u8, name),
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
            self.pane_shell.put(uuid, .{}) catch return;
            entry = self.pane_shell.getPtr(uuid);
        }
        if (entry) |info| {
            if (cmd) |c| {
                if (info.cmd) |old| self.allocator.free(old);
                info.cmd = self.allocator.dupe(u8, c) catch info.cmd;
            }
            if (cwd) |c| {
                if (info.cwd) |old| self.allocator.free(old);
                info.cwd = self.allocator.dupe(u8, c) catch info.cwd;
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
            self.pane_shell.put(uuid, .{}) catch return;
            entry = self.pane_shell.getPtr(uuid);
        }
        if (entry) |info| {
            info.running = running;
            if (started_at_ms) |t| info.started_at_ms = t;
            if (cmd) |c| {
                if (info.cmd) |old| self.allocator.free(old);
                info.cmd = self.allocator.dupe(u8, c) catch info.cmd;
            }
            if (cwd) |c| {
                if (info.cwd) |old| self.allocator.free(old);
                info.cwd = self.allocator.dupe(u8, c) catch info.cwd;
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
            self.pane_proc.put(uuid, .{}) catch return;
            entry = self.pane_proc.getPtr(uuid);
        }
        if (entry) |info| {
            if (name) |n| {
                if (info.name) |old| self.allocator.free(old);
                info.name = self.allocator.dupe(u8, n) catch info.name;
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
        if (self.pane_names.get(uuid)) |old_name| {
            self.allocator.free(old_name);
        }
        self.pane_names.put(uuid, name_owned) catch self.allocator.free(name_owned);
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

    pub fn resetTabFocusMemory(self: *SessionProjection, tab_count: usize) !void {
        self.tab_last_floating_uuid.clearRetainingCapacity();
        self.tab_last_focus_kind.clearRetainingCapacity();
        for (0..tab_count) |_| {
            try self.tab_last_floating_uuid.append(self.allocator, null);
            try self.tab_last_focus_kind.append(self.allocator, .split);
        }
    }

    pub fn appendTabFocusMemory(self: *SessionProjection) !void {
        try self.tab_last_floating_uuid.append(self.allocator, null);
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
