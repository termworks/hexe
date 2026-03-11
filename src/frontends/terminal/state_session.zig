const std = @import("std");
const core = @import("core");
const mux = @import("main.zig");

const state_types = @import("state_types.zig");
const Tab = state_types.Tab;

const layout_mod = @import("layout.zig");
const Layout = layout_mod.Layout;
const LayoutNode = layout_mod.LayoutNode;
const SplitDir = layout_mod.SplitDir;

const Pane = @import("pane.zig").Pane;

const SessionConfig = core.session_config.SessionConfig;
const SplitConfig = core.session_config.SplitConfig;
const TabConfig = core.session_config.TabConfig;
const SplitChild = core.session_config.SplitChild;

/// Apply a session config to the mux state.
/// Creates tabs with the specified split trees, panes with commands/cwds.
pub fn applySessionConfig(self: anytype, config: SessionConfig, tab_filter: ?[]const u8) !void {
    mux.debugLog("applySessionConfig: {d} tabs, {d} global floats", .{ config.tabs.len, config.floats.len });

    if (config.tabs.len == 0) {
        // No tabs defined — create a single default tab
        try self.createTab();
        return;
    }

    // Run on_start hooks (fire and forget)
    for (config.on_start) |cmd| {
        runShellCommand(cmd);
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
    if (self.view.tabs.items.len > 0) {
        if (self.view.tabs.items[0].layout.getFocusedPane()) |pane| {
            self.syncPaneFocus(pane, null);
        }
    }
    self.renderer.invalidate();
    self.force_full_render = true;
}

/// Replace current runtime tabs/floats with a session config.
pub fn replaceWithSessionConfig(self: anytype, config: SessionConfig, tab_filter: ?[]const u8) !void {
    // Remove floating panes.
    for (self.view.floats.items) |pane| {
        pane.deinit();
        self.allocator.destroy(pane);
    }
    self.view.floats.clearRetainingCapacity();
    self.setActiveFloatingIndex(null);
    self.setFocusedPaneUuid(null);

    // Remove all tabs.
    for (self.view.tabs.items) |*tab| {
        tab.deinit();
    }
    self.view.tabs.clearRetainingCapacity();
    self.clearTabMeta();
    self.clearTabFocusMemory();
    self.setActiveTabIndex(0);
    self.setFocusedPaneUuid(null);

    try applySessionConfig(self, config, tab_filter);
}

fn createTabFromConfig(self: anytype, tab_config: TabConfig) !void {
    // Generate tab name
    const name_owned = self.allocator.dupe(u8, tab_config.name) catch blk: {
        const tab_counter = self.takeNextTabCounter();
        break :blk try core.ipc.generateTabName(self.allocator, self.sessionName(), tab_counter);
    };

    const tab_uuid = core.ipc.generateUuid();
    var tab = Tab.init(self.allocator, self.layout_width, self.layout_height, self.pop_config.carrier.notification);

    if (self.frontend_client.isConnected()) {
        tab.layout.setFrontendClient(self.frontend_client);
    }
    tab.layout.setPanePopConfig(&self.pop_config.pane.notification);

    if (tab_config.split) |split_config| {
        // Build the split tree from config
        try buildSplitTree(self, &tab.layout, split_config);
    } else {
        // No split defined — create single default pane
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.posix.getcwd(&cwd_buf) catch null;
        _ = try tab.layout.createFirstPane(cwd);
    }

    try self.view.tabs.append(self.allocator, tab);
    errdefer {
        var failed_tab = self.view.tabs.pop().?;
        failed_tab.deinit();
    }
    if (!self.appendTabMeta(tab_uuid, name_owned)) return error.OutOfMemory;
    errdefer self.removeTabMeta(self.view.tabs.items.len - 1);
    self.allocator.free(name_owned);
    if (!self.appendTabFocusMemory()) return error.OutOfMemory;
    errdefer self.removeTabFocusMemory(self.view.tabs.items.len - 1);

    self.setActiveTabIndex(self.view.tabs.items.len - 1);
    const created_tab = &self.view.tabs.items[self.activeTabIndex()];
    const focused = created_tab.layout.getFocusedPane() orelse return error.InvalidLayout;
    self.syncSessionTabAdded(tab_uuid, self.tabName(self.activeTabIndex()), focused.uuid);
    self.syncActiveTabLayout();
}

fn buildSplitTree(self: anytype, layout: *Layout, split_config: SplitConfig) !void {
    switch (split_config) {
        .pane => |pane_config| {
            // Single pane
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = resolvePaneCwd(pane_config.cwd) orelse (std.posix.getcwd(&cwd_buf) catch null);
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
                const cwd = std.posix.getcwd(&cwd_buf) catch null;
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
                const cwd = std.posix.getcwd(&cwd_buf) catch null;
                _ = try layout.createFirstPane(cwd);
                return;
            }

            // Build binary layout tree from N-child config
            const root = try buildBinaryTree(self.allocator, split_config, panes.items, &layout.next_split_id);
            layout.root = root;

            // Set the first pane as focused
            layout.focused_split_id = panes.items[0].id;
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

/// Recursively collect all leaf panes, creating them via SES.
fn collectLeafPanes(self: anytype, layout: *Layout, config: SplitConfig, panes: *std.ArrayList(*Pane), cmds: *std.ArrayList(?[]const u8)) !void {
    switch (config) {
        .pane => |pane_config| {
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = resolvePaneCwd(pane_config.cwd) orelse (std.posix.getcwd(&cwd_buf) catch null);
            const id = layout.next_split_id;
            layout.next_split_id += 1;

            const pane = try self.allocator.create(Pane);
            errdefer self.allocator.destroy(pane);

            const client = layout.frontend_client orelse return error.SesUnavailable;
            if (!client.isConnected()) return error.SesUnavailable;
            const result = try client.createPane(null, cwd, null, null, null, null, null);
            const vt_fd = client.getVtFd() orelse return error.SesUnavailable;
            try pane.initWithPod(self.allocator, id, 0, 0, layout.width, layout.height, result.pane_id, vt_fd, result.uuid);

            layout.configurePaneNotifications(pane);
            try layout.splits.put(id, pane);
            try panes.append(self.allocator, pane);
            try cmds.append(self.allocator, pane_config.cmd);
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
fn buildBinaryTree(allocator: std.mem.Allocator, config: SplitConfig, panes: []*Pane, pane_idx: *u16) !*LayoutNode {
    _ = pane_idx;
    var leaf_idx: usize = 0;
    return buildBinaryTreeInner(allocator, config, panes, &leaf_idx);
}

fn buildBinaryTreeInner(allocator: std.mem.Allocator, config: SplitConfig, panes: []*Pane, leaf_idx: *usize) error{ OutOfMemory, InvalidNode }!*LayoutNode {
    const node = try allocator.create(LayoutNode);
    errdefer allocator.destroy(node);

    switch (config) {
        .pane => {
            if (leaf_idx.* < panes.len) {
                node.* = .{ .pane = panes[leaf_idx.*].id };
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

fn resolvePaneCwd(cwd: ?[]const u8) ?[]const u8 {
    if (cwd) |c| {
        if (std.fs.path.isAbsolute(c)) return c;
        // For relative paths, they're relative to the root (which we already chdir'd to)
        return c;
    }
    return null;
}

fn writePaneCommand(self: anytype, pane: *Pane, cmd: []const u8) void {
    _ = self;
    if (cmd.len == 0) return;

    // Write command + newline to the pane (handles both local and pod backends)
    pane.write(cmd) catch return;
    pane.write("\n") catch return;
}

fn runShellCommand(cmd: []const u8) void {
    if (cmd.len == 0) return;

    // Use page_allocator for a null-terminated copy since this is fire-and-forget
    const allocator = std.heap.page_allocator;
    const cmd_z = allocator.dupeZ(u8, cmd) catch return;
    defer allocator.free(cmd_z);

    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z, null };
    const pid = std.posix.fork() catch return;
    if (pid == 0) {
        // Child
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
        std.posix.execveZ("/bin/sh", @ptrCast(&argv), envp) catch {};
        std.posix.exit(1);
    }
    // Parent: don't wait — fire and forget
}
