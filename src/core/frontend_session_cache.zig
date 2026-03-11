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

pub const FrontendSessionCache = struct {
    allocator: std.mem.Allocator,
    session_uuid: [32]u8,
    session_name_owned: []u8,
    tab_counter: usize = 0,
    attached_snapshot: ?session_model.SessionSnapshot = null,
    tabs: std.ArrayList(TabMeta),
    tab_last_floating_uuid: std.ArrayList(?[32]u8),
    tab_last_focus_kind: std.ArrayList(TabFocusKind),

    pub fn init(
        allocator: std.mem.Allocator,
        session_uuid: [32]u8,
        session_name: []const u8,
    ) !FrontendSessionCache {
        return .{
            .allocator = allocator,
            .session_uuid = session_uuid,
            .session_name_owned = try allocator.dupe(u8, session_name),
            .tabs = .empty,
            .tab_last_floating_uuid = .empty,
            .tab_last_focus_kind = .empty,
        };
    }

    pub fn deinit(self: *FrontendSessionCache) void {
        if (self.attached_snapshot) |*snapshot| snapshot.deinit();
        for (self.tabs.items) |*tab| tab.deinit(self.allocator);
        self.tabs.deinit(self.allocator);
        self.tab_last_floating_uuid.deinit(self.allocator);
        self.tab_last_focus_kind.deinit(self.allocator);
        self.allocator.free(self.session_name_owned);
        self.* = undefined;
    }

    pub fn sessionName(self: *const FrontendSessionCache) []const u8 {
        return self.session_name_owned;
    }

    pub fn sessionUuid(self: *const FrontendSessionCache) [32]u8 {
        return self.session_uuid;
    }

    pub fn setSessionIdentity(
        self: *FrontendSessionCache,
        session_uuid: [32]u8,
        session_name: []const u8,
    ) !void {
        const name_owned = try self.allocator.dupe(u8, session_name);
        self.allocator.free(self.session_name_owned);
        self.session_name_owned = name_owned;
        self.session_uuid = session_uuid;

        if (self.attached_snapshot) |*snapshot| {
            self.allocator.free(snapshot.session_name);
            snapshot.session_name = try self.allocator.dupe(u8, session_name);
            snapshot.uuid = session_uuid;
        }
    }

    pub fn setTabCounter(self: *FrontendSessionCache, tab_counter: usize) void {
        self.tab_counter = tab_counter;
        if (self.attached_snapshot) |*snapshot| {
            snapshot.tab_counter = tab_counter;
        }
    }

    pub fn takeNextTabCounter(self: *FrontendSessionCache) usize {
        const current = self.tab_counter;
        self.tab_counter = if (current < 999) current + 1 else 0;
        if (self.attached_snapshot) |*snapshot| {
            snapshot.tab_counter = self.tab_counter;
        }
        return current;
    }

    pub fn replaceAttachedSnapshotOwned(
        self: *FrontendSessionCache,
        snapshot: session_model.SessionSnapshot,
    ) !void {
        if (self.attached_snapshot) |*old| old.deinit();
        self.attached_snapshot = snapshot;
        try self.setSessionIdentity(snapshot.uuid, snapshot.session_name);
        self.setTabCounter(if (snapshot.tab_counter > 1000) 0 else snapshot.tab_counter);
        try self.replaceTabMetaFromSnapshot(snapshot.tabs.items);
        try self.resetTabFocusMemory(snapshot.tabs.items.len);
    }

    pub fn clearAttachedSnapshot(self: *FrontendSessionCache) void {
        if (self.attached_snapshot) |*snapshot| snapshot.deinit();
        self.attached_snapshot = null;
    }

    pub fn clearTabMeta(self: *FrontendSessionCache) void {
        for (self.tabs.items) |*tab| tab.deinit(self.allocator);
        self.tabs.clearRetainingCapacity();
    }

    pub fn replaceTabMetaFromSnapshot(
        self: *FrontendSessionCache,
        tabs: []const session_model.SessionTab,
    ) !void {
        self.clearTabMeta();
        for (tabs) |tab| {
            try self.appendTab(tab.uuid, tab.name);
        }
    }

    pub fn appendTab(
        self: *FrontendSessionCache,
        uuid: [32]u8,
        name: []const u8,
    ) !void {
        try self.tabs.append(self.allocator, .{
            .uuid = uuid,
            .name_owned = try self.allocator.dupe(u8, name),
        });
    }

    pub fn removeTab(self: *FrontendSessionCache, index: usize) void {
        if (index >= self.tabs.items.len) return;
        var removed = self.tabs.orderedRemove(index);
        removed.deinit(self.allocator);
    }

    pub fn tabUuid(self: *const FrontendSessionCache, index: usize) ?[32]u8 {
        if (index >= self.tabs.items.len) return null;
        return self.tabs.items[index].uuid;
    }

    pub fn tabName(self: *const FrontendSessionCache, index: usize) ?[]const u8 {
        if (index >= self.tabs.items.len) return null;
        return self.tabs.items[index].name_owned;
    }

    pub fn resetTabFocusMemory(self: *FrontendSessionCache, tab_count: usize) !void {
        self.tab_last_floating_uuid.clearRetainingCapacity();
        self.tab_last_focus_kind.clearRetainingCapacity();
        for (0..tab_count) |_| {
            try self.tab_last_floating_uuid.append(self.allocator, null);
            try self.tab_last_focus_kind.append(self.allocator, .split);
        }
    }

    pub fn appendTabFocusMemory(self: *FrontendSessionCache) !void {
        try self.tab_last_floating_uuid.append(self.allocator, null);
        try self.tab_last_focus_kind.append(self.allocator, .split);
    }

    pub fn removeTabFocusMemory(self: *FrontendSessionCache, index: usize) void {
        if (index < self.tab_last_floating_uuid.items.len) {
            _ = self.tab_last_floating_uuid.orderedRemove(index);
        }
        if (index < self.tab_last_focus_kind.items.len) {
            _ = self.tab_last_focus_kind.orderedRemove(index);
        }
    }

    pub fn clearTabFocusMemory(self: *FrontendSessionCache) void {
        self.tab_last_floating_uuid.clearRetainingCapacity();
        self.tab_last_focus_kind.clearRetainingCapacity();
    }

    pub fn rememberFloatingFocus(
        self: *FrontendSessionCache,
        active_tab: usize,
        pane_uuid: [32]u8,
    ) void {
        if (active_tab >= self.tab_last_floating_uuid.items.len) return;
        self.tab_last_floating_uuid.items[active_tab] = pane_uuid;
        if (active_tab < self.tab_last_focus_kind.items.len) {
            self.tab_last_focus_kind.items[active_tab] = .float;
        }
    }

    pub fn rememberSplitFocus(self: *FrontendSessionCache, active_tab: usize) void {
        if (active_tab < self.tab_last_focus_kind.items.len) {
            self.tab_last_focus_kind.items[active_tab] = .split;
        }
    }

    pub fn lastFocusKind(
        self: *const FrontendSessionCache,
        active_tab: usize,
    ) ?TabFocusKind {
        if (active_tab >= self.tab_last_focus_kind.items.len) return null;
        return self.tab_last_focus_kind.items[active_tab];
    }

    pub fn lastFloatingUuid(
        self: *const FrontendSessionCache,
        active_tab: usize,
    ) ?[32]u8 {
        if (active_tab >= self.tab_last_floating_uuid.items.len) return null;
        return self.tab_last_floating_uuid.items[active_tab];
    }
};
