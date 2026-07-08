const std = @import("std");
const core = @import("core");
const terminal_main = @import("main.zig");

const state_types = @import("state_types.zig");
const TabView = state_types.TabView;

const layout_mod = @import("layout.zig");
const Layout = layout_mod.Layout;
const LayoutNode = layout_mod.LayoutNode;
const SplitDir = layout_mod.SplitDir;

const Pane = @import("pane.zig").Pane;

const SessionConfig = core.session_config.SessionConfig;
const SplitConfig = core.session_config.SplitConfig;
const TabConfig = core.session_config.TabConfig;
const SplitChild = core.session_config.SplitChild;
const LayoutDef = core.LayoutDef;
const LayoutTabDef = core.LayoutTabDef;
const LayoutSplitDef = core.LayoutSplitDef;

fn killTabPanes(self: anytype, tab: *TabView) void {
    var it = tab.layout.splits.valueIterator();
    while (it.next()) |pane_ptr| {
        self.runtime.killPane(pane_ptr.*.uuid) catch |e| {
            terminal_main.debugLogUuid(&pane_ptr.*.uuid, "killTabPanes: killPane failed during tab rollback: {s}", .{@errorName(e)});
        };
    }
}

fn rollbackCanonicalTab(self: anytype, tab_uuid: [32]u8) void {
    self.runtime.sessionRemoveTab(tab_uuid, null) catch |e| {
        terminal_main.debugLogUuid(&tab_uuid, "rollbackCanonicalTab: sessionRemoveTab failed: {s}", .{@errorName(e)});
    };
}

/// Apply a session config to the terminal frontend state.
/// Creates tabs with the specified split trees, panes with commands/cwds.
pub fn applySessionConfig(self: anytype, config: SessionConfig, tab_filter: ?[]const u8) !void {
    terminal_main.debugLog("applySessionConfig: {d} tabs, {d} global floats", .{ config.tabs.len, config.floats.len });

    if (config.tabs.len == 0) {
        // No tabs defined — create a single default tab
        try self.createTab();
        return;
    }

    // Run on_start hooks (fire and forget), gated by the trust ledger so an
    // untrusted project `.hexe.lua` can't silently auto-run shell hooks when a
    // session opens in its directory (PLAN 1.9).
    if (projectCommandsAllowed(config)) {
        for (config.on_start) |cmd| {
            runShellCommand(cmd);
        }
    } else if (config.on_start.len > 0) {
        core.logging.warn(
            "terminal",
            "skipping {d} on_start hook(s) from untrusted .hexe.lua — run `hexe allow` to trust it",
            .{config.on_start.len},
        );
    }

    var created_any = false;

    for (config.tabs) |tab_config| {
        // Apply tab filter if specified
        if (tab_filter) |filter| {
            if (!std.mem.eql(u8, tab_config.name, filter)) continue;
        }

        try createTabFromConfig(self, tab_config);
        created_any = true;
    }

    // If tab filter matched nothing, create default tab
    if (!created_any) {
        if (tab_filter) |filter| {
            std.debug.print("Warning: tab '{s}' not found in config, creating default\n", .{filter});
        }
        try self.createTab();
        return;
    }

    self.setActiveTabIndex(0);
    if (self.view.tab_views.items.len > 0) {
        if (self.view.tab_views.items[0].layout.getFocusedPane()) |pane| {
            self.syncPaneFocus(pane, null);
        }
    }
    self.renderer.invalidate();
    self.force_full_render = true;
}

/// Apply an enabled SES layout definition to a new session startup.
pub fn applyLayoutDef(self: anytype, layout: *const LayoutDef) !void {
    terminal_main.debugLog("applyLayoutDef: '{s}' tabs={d} floats={d}", .{ layout.name, layout.tabs.len, layout.floats.len });

    if (layout.tabs.len == 0) {
        try self.createTab();
        return;
    }

    var created_any = false;
    for (layout.tabs) |tab_config| {
        if (!tab_config.enabled) continue;
        try createTabFromLayoutDef(self, tab_config);
        created_any = true;
    }

    if (!created_any) {
        try self.createTab();
        return;
    }

    self.setActiveTabIndex(0);
    if (self.view.tab_views.items.len > 0) {
        if (self.view.tab_views.items[0].layout.getFocusedPane()) |pane| {
            self.syncPaneFocus(pane, null);
        }
    }
    self.renderer.invalidate();
    self.force_full_render = true;
}

/// Replace current runtime tabs/floats with a session config.
pub fn replaceWithSessionConfig(self: anytype, config: SessionConfig, tab_filter: ?[]const u8) !void {
    // Remove floating panes.
    for (self.view.float_views.items) |pane| {
        self.clearTransientPaneState(pane);
        self.clearFloatUi(pane.uuid);
        pane.deinit();
        self.allocator.destroy(pane);
    }
    self.view.float_views.clearRetainingCapacity();
    self.setActiveFloatingIndex(null);
    self.runtime.setFocusedPaneUuid(null);

    // Remove all tabs.
    for (self.view.tab_views.items) |*tab| {
        var split_it = tab.layout.splits.valueIterator();
        while (split_it.next()) |pane_ptr| {
            self.clearTransientPaneState(pane_ptr.*);
        }
        tab.deinit();
    }
    self.view.tab_views.clearRetainingCapacity();
    self.runtime.clearTabMeta();
    self.runtime.clearTabFocusMemory();
    self.setActiveTabIndex(0);
    self.runtime.setFocusedPaneUuid(null);

    try applySessionConfig(self, config, tab_filter);
}

/// Replace current runtime tabs/floats with a canonical layout definition.
pub fn replaceWithLayoutDef(self: anytype, layout: *const LayoutDef) !void {
    // Remove floating panes.
    for (self.view.float_views.items) |pane| {
        self.clearTransientPaneState(pane);
        self.clearFloatUi(pane.uuid);
        pane.deinit();
        self.allocator.destroy(pane);
    }
    self.view.float_views.clearRetainingCapacity();
    self.setActiveFloatingIndex(null);
    self.runtime.setFocusedPaneUuid(null);

    // Remove all tabs.
    for (self.view.tab_views.items) |*tab| {
        var split_it = tab.layout.splits.valueIterator();
        while (split_it.next()) |pane_ptr| {
            self.clearTransientPaneState(pane_ptr.*);
        }
        tab.deinit();
    }
    self.view.tab_views.clearRetainingCapacity();
    self.runtime.clearTabMeta();
    self.runtime.clearTabFocusMemory();
    self.setActiveTabIndex(0);
    self.runtime.setFocusedPaneUuid(null);

    try applyLayoutDef(self, layout);
}

fn createTabFromConfig(self: anytype, tab_config: TabConfig) !void {
    // Generate tab name
    const name_owned = self.allocator.dupe(u8, tab_config.name) catch blk: {
        const tab_counter = self.runtime.takeNextTabCounter();
        break :blk try core.ipc.generateTabName(self.allocator, self.runtime.sessionName(), tab_counter);
    };

    const tab_uuid = core.ipc.generateUuid();
    var tab = TabView.init(self.allocator, self.layout_width, self.layout_height, self.pop_config.carrier.notification);

    if (self.runtime.isConnected()) {
        tab.layout.setFrontendRuntime(self.runtime);
    }
    tab.layout.setPanePopConfig(&self.pop_config.pane.notification);

    if (tab_config.split) |split_config| {
        // Build the split tree from config
        try buildSplitTree(self, &tab.layout, split_config);
    } else {
        // No split defined — create single default pane
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.posix.getcwd(&cwd_buf) catch |err| blk: {
            core.logging.logError("terminal", "createTabFromConfig: failed to get default pane cwd", err);
            break :blk null;
        };
        _ = try tab.layout.createFirstPane(cwd);
    }

    try self.view.tab_views.append(self.allocator, tab);
    errdefer {
        var failed_tab = self.view.tab_views.pop().?;
        failed_tab.deinit();
    }
    if (!self.runtime.appendTabMeta(tab_uuid, name_owned)) return error.OutOfMemory;
    errdefer self.runtime.removeTabMeta(self.view.tab_views.items.len - 1);
    self.allocator.free(name_owned);
    if (!self.runtime.appendTabFocusMemory()) return error.OutOfMemory;
    errdefer self.runtime.removeTabFocusMemory(self.view.tab_views.items.len - 1);

    self.setActiveTabIndex(self.view.tab_views.items.len - 1);
    const created_tab = &self.view.tab_views.items[self.activeTabIndex()];
    const focused = created_tab.layout.getFocusedPane() orelse return error.InvalidLayout;
    if (!self.syncSessionTabAddedChecked(tab_uuid, self.runtime.tabName(self.activeTabIndex()) orelse "tab", focused.uuid)) {
        killTabPanes(self, created_tab);
        return error.SesUnavailable;
    }
    if (created_tab.layout.root) |root| {
        if (!syncConfigSplitTree(self, &created_tab.layout, root, focused.uuid)) {
            killTabPanes(self, created_tab);
            rollbackCanonicalTab(self, tab_uuid);
            return error.SesUnavailable;
        }
    }
}

fn createTabFromLayoutDef(self: anytype, tab_config: LayoutTabDef) !void {
    const name_owned = try self.allocator.dupe(u8, tab_config.name);

    const tab_uuid = core.ipc.generateUuid();
    var tab = TabView.init(self.allocator, self.layout_width, self.layout_height, self.pop_config.carrier.notification);

    if (self.runtime.isConnected()) {
        tab.layout.setFrontendRuntime(self.runtime);
    }
    tab.layout.setPanePopConfig(&self.pop_config.pane.notification);

    if (tab_config.root) |root_def| {
        const root = try buildLayoutTree(self, &tab.layout, root_def);
        tab.layout.root = root;
        tab.layout.focused_pane_uuid = leftmostPaneUuid(&tab.layout, root);
        if (tab.layout.focused_pane_uuid) |focused_uuid| {
            if (tab.layout.splits.getPtr(focused_uuid)) |pane| {
                pane.*.focused = true;
            }
        }
        tab.layout.recalculateLayout();
    } else {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.posix.getcwd(&cwd_buf) catch |err| blk: {
            core.logging.logError("terminal", "createTabFromLayout: failed to get default pane cwd", err);
            break :blk null;
        };
        _ = try tab.layout.createFirstPane(cwd);
    }

    try self.view.tab_views.append(self.allocator, tab);
    errdefer {
        var failed_tab = self.view.tab_views.pop().?;
        failed_tab.deinit();
    }
    if (!self.runtime.appendTabMeta(tab_uuid, name_owned)) return error.OutOfMemory;
    errdefer self.runtime.removeTabMeta(self.view.tab_views.items.len - 1);
    self.allocator.free(name_owned);
    if (!self.runtime.appendTabFocusMemory()) return error.OutOfMemory;
    errdefer self.runtime.removeTabFocusMemory(self.view.tab_views.items.len - 1);

    self.setActiveTabIndex(self.view.tab_views.items.len - 1);
    const created_tab = &self.view.tab_views.items[self.activeTabIndex()];
    const focused = created_tab.layout.getFocusedPane() orelse return error.InvalidLayout;
    if (!self.syncSessionTabAddedChecked(tab_uuid, self.runtime.tabName(self.activeTabIndex()) orelse "tab", focused.uuid)) {
        killTabPanes(self, created_tab);
        return error.SesUnavailable;
    }
    if (created_tab.layout.root) |root| {
        if (!syncConfigSplitTree(self, &created_tab.layout, root, focused.uuid)) {
            killTabPanes(self, created_tab);
            rollbackCanonicalTab(self, tab_uuid);
            return error.SesUnavailable;
        }
    }
}

fn leftmostPaneUuid(layout: *Layout, node: *const LayoutNode) ?[32]u8 {
    return switch (node.*) {
        .pane => |id| if (layout.splits.get(id)) |pane| pane.uuid else null,
        .split => |split| leftmostPaneUuid(layout, split.first) orelse leftmostPaneUuid(layout, split.second),
    };
}

fn syncConfigSplitTree(self: anytype, layout: *Layout, node: *const LayoutNode, focused_pane_uuid: [32]u8) bool {
    switch (node.*) {
        .pane => return true,
        .split => |split| {
            const source_pane_uuid = leftmostPaneUuid(layout, split.first) orelse {
                core.logging.warn("terminal", "config split sync failed: first split branch has no pane UUID", .{});
                return false;
            };
            const new_pane_uuid = leftmostPaneUuid(layout, split.second) orelse {
                core.logging.warn("terminal", "config split sync failed: second split branch has no pane UUID", .{});
                return false;
            };

            if (!self.syncSessionSplitPaneChecked(source_pane_uuid, new_pane_uuid, split.dir, focused_pane_uuid)) return false;
            if (!syncConfigSplitTree(self, layout, split.first, focused_pane_uuid)) return false;
            if (!syncConfigSplitTree(self, layout, split.second, focused_pane_uuid)) return false;
            self.syncSessionSplitRatio(source_pane_uuid, new_pane_uuid, split.ratio);
            return true;
        },
    }
}

fn buildSplitTree(self: anytype, layout: *Layout, split_config: SplitConfig) !void {
    switch (split_config) {
        .pane => |pane_config| {
            // Single pane
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            var resolved_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = resolvePaneCwd(pane_config.cwd, &resolved_cwd_buf) orelse fallbackCwd(&cwd_buf, "buildSplitTree pane");
            const first_pane = try layout.createFirstPane(cwd);

            // If cmd is set, type it into the shell
            if (pane_config.cmd) |cmd| {
                writePaneCommand(self, first_pane, cmd);
            }
        },
        .split => |split_node| {
            // N-child split — need to create panes and build binary tree
            if (split_node.children.len == 0) {
                var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
                const cwd = fallbackCwd(&cwd_buf, "buildSplitTree empty split");
                _ = try layout.createFirstPane(cwd);
                return;
            }

            // Collect all leaf panes from the split tree
            var panes: std.ArrayList(*Pane) = .empty;
            defer panes.deinit(self.allocator);
            var cmds: std.ArrayList(?[]const u8) = .empty;
            defer cmds.deinit(self.allocator);

            try collectLeafPanes(self, layout, split_config, &panes, &cmds);

            if (panes.items.len == 0) {
                var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
                const cwd = fallbackCwd(&cwd_buf, "buildSplitTree no leaf panes");
                _ = try layout.createFirstPane(cwd);
                return;
            }

            // Build binary layout tree from N-child config
            const root = try buildBinaryTree(self.allocator, split_config, panes.items);
            layout.root = root;

            // Set the first pane as focused
            layout.focused_pane_uuid = panes.items[0].uuid;
            panes.items[0].focused = true;

            // Recalculate layout positions
            layout.recalculateLayout();

            // Write commands to panes
            for (cmds.items, 0..) |cmd, i| {
                if (cmd) |c| {
                    if (i < panes.items.len) {
                        writePaneCommand(self, panes.items[i], c);
                    }
                }
            }
        },
    }
}

fn buildLayoutTree(self: anytype, layout: *Layout, split_def: LayoutSplitDef) !*LayoutNode {
    const node = try self.allocator.create(LayoutNode);
    errdefer self.allocator.destroy(node);

    switch (split_def) {
        .pane => |pane_config| {
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            var resolved_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = resolvePaneCwd(pane_config.cwd, &resolved_cwd_buf) orelse fallbackCwd(&cwd_buf, "buildLayoutTree pane");
            const view_id = layout.next_pane_view_id;
            layout.next_pane_view_id +%= 1;

            const pane = try self.allocator.create(Pane);
            errdefer self.allocator.destroy(pane);

            const runtime = layout.runtime orelse return error.SesUnavailable;
            if (!runtime.isConnected()) return error.SesUnavailable;
            const result = try runtime.createPane(null, cwd, null, null, null, null, null);
            var pane_registered = false;
            errdefer if (!pane_registered) runtime.killPane(result.uuid) catch |e| {
                terminal_main.debugLogUuid(&result.uuid, "collectLeafPanes rollback killPane failed: {s}", .{@errorName(e)});
            };
            const vt_fd = runtime.getVtFd() orelse return error.SesUnavailable;
            try pane.initWithPod(self.allocator, view_id, 0, 0, layout.width, layout.height, result.pane_id, vt_fd, result.uuid);
            errdefer pane.deinit();

            layout.configurePaneNotifications(pane);
            try layout.splits.put(pane.uuid, pane);
            pane_registered = true;
            if (pane_config.command) |cmd| {
                writePaneCommand(self, pane, cmd);
            }
            node.* = .{ .pane = pane.uuid };
        },
        .split => |split| {
            const dir = layoutSplitDir(split.dir);
            const first = try buildLayoutTree(self, layout, split.first.*);
            errdefer {
                destroyLayoutTreeNodes(self.allocator, first);
            }
            const second = try buildLayoutTree(self, layout, split.second.*);
            errdefer {
                destroyLayoutTreeNodes(self.allocator, second);
            }
            node.* = .{ .split = .{
                .dir = dir,
                .ratio = split.ratio,
                .first = first,
                .second = second,
            } };
        },
    }

    return node;
}

fn layoutSplitDir(dir: []const u8) SplitDir {
    if (core.session_model.isVerticalSplitDir(dir)) return .vertical;
    return .horizontal;
}

fn destroyLayoutTreeNodes(allocator: std.mem.Allocator, node: *LayoutNode) void {
    switch (node.*) {
        .pane => {},
        .split => |split| {
            destroyLayoutTreeNodes(allocator, split.first);
            destroyLayoutTreeNodes(allocator, split.second);
        },
    }
    allocator.destroy(node);
}

/// Recursively collect all leaf panes, creating them via SES.
fn collectLeafPanes(self: anytype, layout: *Layout, config: SplitConfig, panes: *std.ArrayList(*Pane), cmds: *std.ArrayList(?[]const u8)) !void {
    switch (config) {
        .pane => |pane_config| {
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            var resolved_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = resolvePaneCwd(pane_config.cwd, &resolved_cwd_buf) orelse fallbackCwd(&cwd_buf, "collectLeafPanes pane");
            const view_id = layout.next_pane_view_id;
            layout.next_pane_view_id +%= 1;

            const pane = try self.allocator.create(Pane);
            errdefer self.allocator.destroy(pane);

            const runtime = layout.runtime orelse return error.SesUnavailable;
            if (!runtime.isConnected()) return error.SesUnavailable;
            const result = try runtime.createPane(null, cwd, null, null, null, null, null);
            var pane_registered = false;
            errdefer if (!pane_registered) runtime.killPane(result.uuid) catch |e| {
                terminal_main.debugLogUuid(&result.uuid, "buildLayoutTree rollback killPane failed: {s}", .{@errorName(e)});
            };
            const vt_fd = runtime.getVtFd() orelse return error.SesUnavailable;
            try pane.initWithPod(self.allocator, view_id, 0, 0, layout.width, layout.height, result.pane_id, vt_fd, result.uuid);
            errdefer pane.deinit();

            layout.configurePaneNotifications(pane);
            try panes.append(self.allocator, pane);
            errdefer _ = panes.pop();
            try cmds.append(self.allocator, pane_config.cmd);
            errdefer _ = cmds.pop();
            try layout.splits.put(pane.uuid, pane);
            pane_registered = true;
        },
        .split => |split_node| {
            for (split_node.children) |child| {
                try collectLeafPanes(self, layout, child.node, panes, cmds);
            }
        },
    }
}

/// Convert N-child SplitConfig to a binary LayoutNode tree.
/// Pane IDs are assigned from the panes slice in traversal order.
fn buildBinaryTree(allocator: std.mem.Allocator, config: SplitConfig, panes: []*Pane) !*LayoutNode {
    var leaf_idx: usize = 0;
    return buildBinaryTreeInner(allocator, config, panes, &leaf_idx);
}

fn buildBinaryTreeInner(allocator: std.mem.Allocator, config: SplitConfig, panes: []*Pane, leaf_idx: *usize) error{ OutOfMemory, InvalidNode }!*LayoutNode {
    const node = try allocator.create(LayoutNode);
    errdefer allocator.destroy(node);

    switch (config) {
        .pane => {
            if (leaf_idx.* < panes.len) {
                node.* = .{ .pane = panes[leaf_idx.*].uuid };
                leaf_idx.* += 1;
            } else {
                return error.InvalidNode;
            }
        },
        .split => |split_node| {
            const dir: SplitDir = switch (split_node.dir) {
                .horizontal => .horizontal,
                .vertical => .vertical,
            };

            if (split_node.children.len == 0) {
                return error.InvalidNode;
            } else if (split_node.children.len == 1) {
                // Single child — just recurse into it
                allocator.destroy(node);
                return buildBinaryTreeInner(allocator, split_node.children[0].node, panes, leaf_idx);
            } else {
                // N >= 2 children: first child becomes left, rest become nested right
                const total_size = computeTotalSize(split_node.children);
                const first_size = split_node.children[0].size orelse @as(u8, @intCast(100 / split_node.children.len));

                const ratio: f32 = @as(f32, @floatFromInt(first_size)) / @as(f32, @floatFromInt(total_size));

                const first = try buildBinaryTreeInner(allocator, split_node.children[0].node, panes, leaf_idx);
                errdefer allocator.destroy(first);

                const second = if (split_node.children.len == 2)
                    try buildBinaryTreeInner(allocator, split_node.children[1].node, panes, leaf_idx)
                else
                    // Nest remaining children as a new split with the same direction
                    try buildBinaryTreeFromChildren(allocator, dir, split_node.children[1..], panes, leaf_idx);

                node.* = .{ .split = .{
                    .dir = dir,
                    .ratio = ratio,
                    .first = first,
                    .second = second,
                } };
            }
        },
    }

    return node;
}

fn buildBinaryTreeFromChildren(allocator: std.mem.Allocator, dir: SplitDir, children: []const SplitChild, panes: []*Pane, leaf_idx: *usize) error{ OutOfMemory, InvalidNode }!*LayoutNode {
    if (children.len == 0) return error.InvalidNode;
    if (children.len == 1) return buildBinaryTreeInner(allocator, children[0].node, panes, leaf_idx);

    const node = try allocator.create(LayoutNode);
    errdefer allocator.destroy(node);

    const total_size = computeTotalSize(children);
    const first_size = children[0].size orelse @as(u8, @intCast(100 / children.len));
    const ratio: f32 = @as(f32, @floatFromInt(first_size)) / @as(f32, @floatFromInt(total_size));

    const first = try buildBinaryTreeInner(allocator, children[0].node, panes, leaf_idx);
    errdefer allocator.destroy(first);

    const second = if (children.len == 2)
        try buildBinaryTreeInner(allocator, children[1].node, panes, leaf_idx)
    else
        try buildBinaryTreeFromChildren(allocator, dir, children[1..], panes, leaf_idx);

    node.* = .{ .split = .{
        .dir = dir,
        .ratio = ratio,
        .first = first,
        .second = second,
    } };

    return node;
}

fn computeTotalSize(children: []const SplitChild) u16 {
    var total: u16 = 0;
    var unspecified: u16 = 0;
    for (children) |child| {
        if (child.size) |s| {
            total += s;
        } else {
            unspecified += 1;
        }
    }
    // Distribute remaining space equally among unspecified
    if (unspecified > 0) {
        const remaining: u16 = if (total < 100) 100 - total else 0;
        total += remaining; // fills to 100
    }
    if (total == 0) total = 100;
    return total;
}

fn resolvePaneCwd(cwd: ?[]const u8, out_buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    if (cwd) |c| {
        if (std.fs.path.isAbsolute(c)) return c;
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const base = std.posix.getcwd(&cwd_buf) catch |err| {
            core.logging.logError("terminal", "failed to resolve relative pane cwd base", err);
            return null;
        };
        var fba = std.heap.FixedBufferAllocator.init(out_buf);
        return std.fs.path.resolve(fba.allocator(), &.{ base, c }) catch |err| {
            core.logging.logError("terminal", "failed to resolve relative pane cwd", err);
            return null;
        };
    }
    return null;
}

fn fallbackCwd(out_buf: *[std.fs.max_path_bytes]u8, comptime context: []const u8) ?[]const u8 {
    return std.posix.getcwd(out_buf) catch |err| {
        core.logging.logError("terminal", context ++ ": failed to get fallback cwd", err);
        return null;
    };
}

fn writePaneCommand(self: anytype, pane: *Pane, cmd: []const u8) void {
    _ = self;
    if (cmd.len == 0) return;

    pane.write(cmd) catch |err| {
        terminal_main.debugLogUuid(&pane.uuid, "layout command write failed: {s}", .{@errorName(err)});
        return;
    };
    pane.write("\n") catch |err| {
        terminal_main.debugLogUuid(&pane.uuid, "layout command newline write failed: {s}", .{@errorName(err)});
    };
}

fn envFlagSet(name: []const u8) bool {
    const v = std.posix.getenv(name) orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

/// Whether project-sourced `on_start`/`on_stop` hooks may run for this config.
/// Secure default: an identifiable `.hexe.lua` must be trusted via `hexe allow`.
fn projectCommandsAllowed(config: SessionConfig) bool {
    if (envFlagSet("HEXE_NO_PROJECT_COMMANDS")) return false; // hard opt-out
    if (envFlagSet("HEXE_TRUST_ALL_PROJECTS")) return true; // CI/dev escape hatch
    // No identifiable source file (not an auto-loaded project config): allow.
    const src = config.source_path orelse return true;
    return core.trust.isTrusted(std.heap.page_allocator, src);
}

fn runShellCommand(cmd: []const u8) void {
    if (cmd.len == 0) return;

    // These commands come from a project-local `.hexe.lua` (on_start/on_stop),
    // so opening a session in an untrusted repo runs its shell hooks — the
    // direnv auto-trust problem. Default behavior is preserved (they run), but
    // HEXE_NO_PROJECT_COMMANDS=1 disables project-sourced command execution for
    // untrusted-directory workflows. A full per-directory trust ledger is the
    // proper long-term fix (see PLAN.md 1.9).
    if (std.posix.getenv("HEXE_NO_PROJECT_COMMANDS")) |v| {
        if (v.len > 0 and !std.mem.eql(u8, v, "0")) {
            core.logging.warn("terminal", "skipping project on_start/on_stop command (HEXE_NO_PROJECT_COMMANDS set)", .{});
            return;
        }
    }

    // Use page_allocator for a null-terminated copy since this is fire-and-forget
    const allocator = std.heap.page_allocator;
    const cmd_z = allocator.dupeZ(u8, cmd) catch |err| {
        core.logging.logError("terminal", "failed to allocate layout shell command", err);
        return;
    };
    defer allocator.free(cmd_z);

    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z, null };
    const pid = std.posix.fork() catch |err| {
        core.logging.logError("terminal", "failed to fork layout shell command", err);
        return;
    };
    if (pid == 0) {
        // Child
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
        std.posix.execveZ("/bin/sh", @ptrCast(&argv), envp) catch {
            _ = std.posix.write(std.posix.STDERR_FILENO, "layout shell command exec failed\n") catch 0;
        };
        std.posix.exit(1);
    }
    // Parent: don't wait — fire and forget
}
