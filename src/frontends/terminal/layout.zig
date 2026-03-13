const std = @import("std");
const posix = std.posix;
const core = @import("core");
const pop = @import("pop");
const Pane = @import("pane.zig").Pane;
const FrontendRuntime = core.FrontendRuntime;

/// Cursor position for directional navigation
pub const CursorPos = struct { x: u16, y: u16 };

pub const SplitRatioSync = struct {
    first_anchor_uuid: [32]u8,
    second_anchor_uuid: [32]u8,
    ratio: f32,
};

/// Direction of a split
pub const SplitDir = enum {
    horizontal, // side by side (left | right)
    vertical, // stacked (top / bottom)
};

/// A node in the layout tree - either a pane or a split
pub const LayoutNode = union(enum) {
    pane: [32]u8, // pane uuid
    split: Split,

    pub const Split = struct {
        dir: SplitDir,
        ratio: f32, // 0.0 to 1.0, position of divider
        first: *LayoutNode,
        second: *LayoutNode,
    };
};

/// Layout manager - handles split arrangement via binary tree
pub const Layout = struct {
    allocator: std.mem.Allocator,
    root: ?*LayoutNode,
    splits: std.AutoHashMap([32]u8, *Pane),
    next_pane_view_id: u16,
    focused_pane_uuid: ?[32]u8,
    // Usable area (excluding status bar)
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    // Optional shared runtime for pane creation
    runtime: ?*FrontendRuntime,
    // Optional pane notification config (from pop.json)
    pane_pop_cfg: ?*const pop.NotificationStyle,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) Layout {
        return .{
            .allocator = allocator,
            .root = null,
            .splits = std.AutoHashMap([32]u8, *Pane).init(allocator),
            .next_pane_view_id = 0,
            .focused_pane_uuid = null,
            .x = 0,
            .y = 0,
            .width = width,
            .height = height,
            .runtime = null,
            .pane_pop_cfg = null,
        };
    }

    /// Set the shared runtime for pane creation
    pub fn setFrontendRuntime(self: *Layout, runtime: *FrontendRuntime) void {
        self.runtime = runtime;
    }

    /// Set the pane notification config from pop.json
    pub fn setPanePopConfig(self: *Layout, cfg: *const pop.NotificationStyle) void {
        self.pane_pop_cfg = cfg;
    }

    /// Apply notification config to a pane
    pub fn configurePaneNotifications(self: *Layout, pane: *Pane) void {
        if (self.pane_pop_cfg) |cfg| {
            pane.configureNotificationsFromPop(cfg);
        }
    }

    pub fn deinit(self: *Layout) void {
        // Deinit all panes (don't kill in ses - caller handles that)
        var it = self.splits.valueIterator();
        while (it.next()) |pane_ptr| {
            pane_ptr.*.deinit();
            self.allocator.destroy(pane_ptr.*);
        }
        self.splits.deinit();

        // Free layout nodes
        if (self.root) |root| {
            self.freeNode(root);
        }
    }

    pub fn freeNode(self: *Layout, node: *LayoutNode) void {
        switch (node.*) {
            .pane => {},
            .split => |split| {
                self.freeNode(split.first);
                self.freeNode(split.second);
            },
        }
        self.allocator.destroy(node);
    }

    /// Create the first pane
    pub fn createFirstPane(self: *Layout, cwd: ?[]const u8) !*Pane {
        const runtime = self.runtime orelse return error.SesUnavailable;
        if (!runtime.isConnected()) return error.SesUnavailable;

        const view_id = self.next_pane_view_id;
        self.next_pane_view_id +%= 1;

        const pane = try self.allocator.create(Pane);
        errdefer self.allocator.destroy(pane);

        const result = try runtime.createPane(null, cwd, null, null, null, null, null);
        const vt_fd = runtime.getVtFd() orelse return error.SesUnavailable;
        try pane.initWithPod(self.allocator, view_id, self.x, self.y, self.width, self.height, result.pane_id, vt_fd, result.uuid);

        pane.focused = true;
        self.focused_pane_uuid = pane.uuid;

        try self.splits.put(pane.uuid, pane);
        self.configurePaneNotifications(pane);

        const node = try self.allocator.create(LayoutNode);
        node.* = .{ .pane = pane.uuid };
        self.root = node;

        return pane;
    }

    /// Split the focused pane
    pub fn splitFocused(self: *Layout, dir: SplitDir, cwd: ?[]const u8) !?*Pane {
        const runtime = self.runtime orelse return error.SesUnavailable;
        if (!runtime.isConnected()) return error.SesUnavailable;
        if (self.root == null) return null;

        const focused = self.getFocusedPane() orelse return null;
        const old_uuid = focused.uuid;

        // Create new pane
        const view_id = self.next_pane_view_id;
        self.next_pane_view_id +%= 1;

        const new_pane = try self.allocator.create(Pane);
        errdefer self.allocator.destroy(new_pane);

        // Calculate new sizes based on split direction
        const new_width = if (dir == .horizontal) focused.width / 2 else focused.width;
        const new_height = if (dir == .vertical) focused.height / 2 else focused.height;
        const new_x = if (dir == .horizontal) focused.x + focused.width - new_width else focused.x;
        const new_y = if (dir == .vertical) focused.y + focused.height - new_height else focused.y;

        const result = try runtime.createPane(null, cwd, null, null, null, null, null);
        const vt_fd = runtime.getVtFd() orelse return error.SesUnavailable;
        try new_pane.initWithPod(self.allocator, view_id, new_x, new_y, new_width, new_height, result.pane_id, vt_fd, result.uuid);
        errdefer new_pane.deinit();

        try self.splits.put(new_pane.uuid, new_pane);
        self.configurePaneNotifications(new_pane);

        // Find and replace the node containing the focused pane
        const node_to_split = self.findNode(self.root.?, old_uuid) orelse return null;

        // Create new split node
        const first_node = try self.allocator.create(LayoutNode);
        first_node.* = .{ .pane = old_uuid };

        const second_node = try self.allocator.create(LayoutNode);
        second_node.* = .{ .pane = new_pane.uuid };

        node_to_split.* = .{
            .split = .{
                .dir = dir,
                .ratio = 0.5,
                .first = first_node,
                .second = second_node,
            },
        };

        // Recalculate all pane positions
        self.recalculateLayout();

        // Focus the new pane (like tmux behavior)
        focused.focused = false;
        new_pane.focused = true;
        self.focused_pane_uuid = new_pane.uuid;

        return new_pane;
    }

    fn findNode(self: *Layout, node: *LayoutNode, pane_uuid: [32]u8) ?*LayoutNode {
        switch (node.*) {
            .pane => |uuid| {
                if (std.mem.eql(u8, &uuid, &pane_uuid)) return node;
                return null;
            },
            .split => |split| {
                if (self.findNode(split.first, pane_uuid)) |found| return found;
                if (self.findNode(split.second, pane_uuid)) |found| return found;
                return null;
            },
        }
    }

    fn firstLeafPaneUuid(self: *Layout, node: *const LayoutNode) ?[32]u8 {
        return switch (node.*) {
            .pane => |uuid| if (self.splits.get(uuid)) |pane| pane.uuid else null,
            .split => |split| self.firstLeafPaneUuid(split.first) orelse self.firstLeafPaneUuid(split.second),
        };
    }

    pub fn splitRatioSyncForSplit(self: *Layout, split: *const LayoutNode.Split) ?SplitRatioSync {
        const first_anchor_uuid = self.firstLeafPaneUuid(split.first) orelse return null;
        const second_anchor_uuid = self.firstLeafPaneUuid(split.second) orelse return null;
        return .{
            .first_anchor_uuid = first_anchor_uuid,
            .second_anchor_uuid = second_anchor_uuid,
            .ratio = split.ratio,
        };
    }

    /// Recalculate all pane positions based on layout tree
    pub fn recalculateLayout(self: *Layout) void {
        if (self.root) |root| {
            self.layoutNode(root, self.x, self.y, self.width, self.height);
        }
    }

    fn layoutNode(self: *Layout, node: *LayoutNode, x: u16, y: u16, w: u16, h: u16) void {
        switch (node.*) {
            .pane => |uuid| {
                if (self.splits.get(uuid)) |pane| {
                    pane.resize(x, y, w, h) catch {};
                }
            },
            .split => |split| {
                switch (split.dir) {
                    .horizontal => {
                        const first_w = @as(u16, @intFromFloat(@as(f32, @floatFromInt(w)) * split.ratio)) -| 1;
                        const second_w = w -| first_w -| 1; // -1 for border
                        self.layoutNode(split.first, x, y, first_w, h);
                        self.layoutNode(split.second, x + first_w + 1, y, second_w, h);
                    },
                    .vertical => {
                        const first_h = @as(u16, @intFromFloat(@as(f32, @floatFromInt(h)) * split.ratio)) -| 1;
                        const second_h = h -| first_h -| 1; // -1 for border
                        self.layoutNode(split.first, x, y, w, first_h);
                        self.layoutNode(split.second, x, y + first_h + 1, w, second_h);
                    },
                }
            },
        }
    }

    /// Remove nodes from the tree that reference pane IDs not in `splits`.
    /// This handles the case where some pods died during detach and their
    /// panes couldn't be recreated on reattach. Without pruning, the tree
    /// allocates space for non-existent panes, corrupting the layout.
    pub fn pruneDeadNodes(self: *Layout) void {
        if (self.root) |root| {
            const result = self.pruneNode(root);
            if (result.dead) {
                // Entire tree is dead
                self.freeNode(root);
                self.root = null;
            } else if (result.replacement) |replacement| {
                // Root was a split where one side died
                self.root = replacement;
                self.allocator.destroy(root);
            }
        }
        // Ensure focused_pane_uuid points to a live pane
        if (self.focused_pane_uuid == null or !self.splits.contains(self.focused_pane_uuid.?)) {
            var it = self.splits.keyIterator();
            if (it.next()) |first_uuid| {
                self.focused_pane_uuid = first_uuid.*;
                if (self.splits.get(first_uuid.*)) |pane| {
                    pane.focused = true;
                }
            } else {
                self.focused_pane_uuid = null;
            }
        }
    }

    const PruneResult = struct {
        dead: bool, // This node references only dead panes
        replacement: ?*LayoutNode, // If non-null, replace this node with this
    };

    fn pruneNode(self: *Layout, node: *LayoutNode) PruneResult {
        switch (node.*) {
            .pane => |uuid| {
                if (self.splits.contains(uuid)) {
                    return .{ .dead = false, .replacement = null };
                } else {
                    return .{ .dead = true, .replacement = null };
                }
            },
            .split => |split| {
                const first_result = self.pruneNode(split.first);
                const second_result = self.pruneNode(split.second);

                if (first_result.dead and second_result.dead) {
                    // Both children dead - this whole subtree is dead
                    self.freeNode(split.first);
                    self.freeNode(split.second);
                    return .{ .dead = true, .replacement = null };
                } else if (first_result.dead) {
                    // First child dead - replace this split with second child
                    self.freeNode(split.first);
                    if (second_result.replacement) |repl| {
                        self.allocator.destroy(split.second);
                        return .{ .dead = false, .replacement = repl };
                    }
                    return .{ .dead = false, .replacement = split.second };
                } else if (second_result.dead) {
                    // Second child dead - replace this split with first child
                    self.freeNode(split.second);
                    if (first_result.replacement) |repl| {
                        self.allocator.destroy(split.first);
                        return .{ .dead = false, .replacement = repl };
                    }
                    return .{ .dead = false, .replacement = split.first };
                } else {
                    // Both alive - apply any child replacements in-place
                    if (first_result.replacement) |repl| {
                        self.allocator.destroy(split.first);
                        node.split.first = repl;
                    }
                    if (second_result.replacement) |repl| {
                        self.allocator.destroy(split.second);
                        node.split.second = repl;
                    }
                    return .{ .dead = false, .replacement = null };
                }
            },
        }
    }

    /// Resize the entire layout area
    pub fn resize(self: *Layout, width: u16, height: u16) void {
        self.width = width;
        self.height = height;
        self.recalculateLayout();
    }

    /// Get focused pane
    pub fn getFocusedPane(self: *Layout) ?*Pane {
        const focused_uuid = self.focused_pane_uuid orelse return null;
        return self.splits.get(focused_uuid);
    }

    /// Focus next pane
    pub fn focusNext(self: *Layout) void {
        if (self.splits.count() <= 1) return;

        if (self.getFocusedPane()) |current| {
            current.focused = false;
        }

        var panes: std.ArrayList(*Pane) = .empty;
        defer panes.deinit(self.allocator);

        var it = self.splits.valueIterator();
        while (it.next()) |pane_ptr| {
            panes.append(self.allocator, pane_ptr.*) catch continue;
        }

        const Ctx = struct {
            fn lessThan(_: void, a: *Pane, b: *Pane) bool {
                return a.id < b.id;
            }
        };
        std.mem.sort(*Pane, panes.items, {}, Ctx.lessThan);

        const focused_uuid = self.focused_pane_uuid orelse return;
        for (panes.items, 0..) |pane, i| {
            if (std.mem.eql(u8, &pane.uuid, &focused_uuid)) {
                const next_idx = (i + 1) % panes.items.len;
                self.focused_pane_uuid = panes.items[next_idx].uuid;
                break;
            }
        }

        if (self.getFocusedPane()) |new_focus| {
            new_focus.focused = true;
        }
    }

    /// Focus previous pane
    pub fn focusPrev(self: *Layout) void {
        if (self.splits.count() <= 1) return;

        if (self.getFocusedPane()) |current| {
            current.focused = false;
        }

        var panes: std.ArrayList(*Pane) = .empty;
        defer panes.deinit(self.allocator);

        var it = self.splits.valueIterator();
        while (it.next()) |pane_ptr| {
            panes.append(self.allocator, pane_ptr.*) catch continue;
        }

        const Ctx = struct {
            fn lessThan(_: void, a: *Pane, b: *Pane) bool {
                return a.id < b.id;
            }
        };
        std.mem.sort(*Pane, panes.items, {}, Ctx.lessThan);

        const focused_uuid = self.focused_pane_uuid orelse return;
        for (panes.items, 0..) |pane, i| {
            if (std.mem.eql(u8, &pane.uuid, &focused_uuid)) {
                const prev_idx = if (i == 0) panes.items.len - 1 else i - 1;
                self.focused_pane_uuid = panes.items[prev_idx].uuid;
                break;
            }
        }

        if (self.getFocusedPane()) |new_focus| {
            new_focus.focused = true;
        }
    }

    /// Focus pane in given direction (up/down/left/right)
    /// If cursor_pos is provided, use it for alignment; otherwise use pane center
    pub fn focusDirection(self: *Layout, dir: Direction, cursor_pos: ?CursorPos) void {
        if (self.splits.count() <= 1) return;

        const current = self.getFocusedPane() orelse return;
        // Use cursor position if provided, otherwise fall back to pane center
        const cur_cx = if (cursor_pos) |pos| pos.x else current.x + current.width / 2;
        const cur_cy = if (cursor_pos) |pos| pos.y else current.y + current.height / 2;

        var best_uuid: ?[32]u8 = null;
        var best_dist: i32 = std.math.maxInt(i32);

        var it = self.splits.iterator();
        while (it.next()) |entry| {
            const pane = entry.value_ptr.*;
            if (self.focused_pane_uuid) |focused_uuid| {
                if (std.mem.eql(u8, &pane.uuid, &focused_uuid)) continue;
            }

            const pane_cx = pane.x + pane.width / 2;
            const pane_cy = pane.y + pane.height / 2;

            // Check if pane is in the right direction
            const is_valid = switch (dir) {
                .up => pane.y + pane.height <= current.y, // pane is above
                .down => pane.y >= current.y + current.height, // pane is below
                .left => pane.x + pane.width <= current.x, // pane is left
                .right => pane.x >= current.x + current.width, // pane is right
            };

            if (!is_valid) continue;

            // Calculate distance - primary axis (direction) + secondary axis (alignment)
            const dist: i32 = switch (dir) {
                .up, .down => blk: {
                    const dy = @as(i32, @intCast(cur_cy)) - @as(i32, @intCast(pane_cy));
                    const dx = @as(i32, @intCast(cur_cx)) - @as(i32, @intCast(pane_cx));
                    // Primary: vertical distance, Secondary: horizontal alignment
                    const abs_dy: i32 = @intCast(@abs(dy));
                    const abs_dx: i32 = @intCast(@abs(dx));
                    break :blk abs_dy + @divTrunc(abs_dx, 2);
                },
                .left, .right => blk: {
                    const dx = @as(i32, @intCast(cur_cx)) - @as(i32, @intCast(pane_cx));
                    const dy = @as(i32, @intCast(cur_cy)) - @as(i32, @intCast(pane_cy));
                    // Primary: horizontal distance, Secondary: vertical alignment
                    const abs_dx: i32 = @intCast(@abs(dx));
                    const abs_dy: i32 = @intCast(@abs(dy));
                    break :blk abs_dx + @divTrunc(abs_dy, 2);
                },
            };

            if (dist < best_dist) {
                best_dist = dist;
                best_uuid = pane.uuid;
            }
        }

        if (best_uuid) |new_uuid| {
            current.focused = false;
            self.focused_pane_uuid = new_uuid;
            if (self.getFocusedPane()) |new_focus| {
                new_focus.focused = true;
            }
        }
    }

    pub const Direction = enum { up, down, left, right };

    pub fn resizeFocused(self: *Layout, dir: Direction, step_cells: u16) ?SplitRatioSync {
        // Adjust the nearest split divider that borders the focused pane in the
        // requested direction (i3/tmux-style resize).
        if (self.root == null) return null;
        if (self.splits.count() <= 1) return null;

        const focused_uuid = self.focused_pane_uuid orelse return null;
        const root = self.root.?;

        const Helper = struct {
            const Target = struct {
                split: *LayoutNode.Split,
                inc_ratio: bool,
            };

            const RecResult = struct {
                found: bool,
                target: ?Target,
            };

            fn rec(node: *LayoutNode, pane_uuid: [32]u8, want: Direction) RecResult {
                return switch (node.*) {
                    .pane => |uuid| .{ .found = std.mem.eql(u8, &uuid, &pane_uuid), .target = null },
                    .split => |*sp| blk: {
                        const left_res: RecResult = rec(sp.first, pane_uuid, want);
                        const right_res: RecResult = if (!left_res.found)
                            rec(sp.second, pane_uuid, want)
                        else
                            .{ .found = false, .target = null };

                        const found = left_res.found or right_res.found;
                        if (!found) break :blk .{ .found = false, .target = null };

                        if (left_res.target) |t| break :blk .{ .found = true, .target = t };
                        if (right_res.target) |t| break :blk .{ .found = true, .target = t };

                        const focused_in_first = left_res.found;
                        const want_split_dir: SplitDir = switch (want) {
                            .left, .right => .horizontal,
                            .up, .down => .vertical,
                        };
                        const need_in_first: bool = switch (want) {
                            .right, .down => true,
                            .left, .up => false,
                        };
                        if (sp.dir != want_split_dir) break :blk .{ .found = true, .target = null };
                        if (focused_in_first != need_in_first) break :blk .{ .found = true, .target = null };

                        const inc_ratio: bool = switch (want) {
                            .right, .down => true,
                            .left, .up => false,
                        };
                        break :blk .{ .found = true, .target = .{ .split = sp, .inc_ratio = inc_ratio } };
                    },
                };
            }
        };

        const res = Helper.rec(root, focused_uuid, dir);
        if (res.target == null) return null;

        const t = res.target.?;
        const axis: u16 = switch (dir) {
            .left, .right => self.width,
            .up, .down => self.height,
        };
        if (axis == 0) return null;
        const delta: f32 = @as(f32, @floatFromInt(step_cells)) / @as(f32, @floatFromInt(axis));

        var r = t.split.ratio;
        if (t.inc_ratio) r += delta else r -= delta;

        // Clamp to keep both sides usable.
        if (r < 0.1) r = 0.1;
        if (r > 0.9) r = 0.9;
        t.split.ratio = r;
        self.recalculateLayout();
        return self.splitRatioSyncForSplit(t.split);
    }

    /// Close the focused pane
    pub fn closeFocused(self: *Layout) bool {
        if (self.splits.count() <= 1) return false;

        const uuid_to_close = self.focused_pane_uuid orelse return false;

        // Focus next before removing
        self.focusNext();

        // Remove pane
        if (self.splits.fetchRemove(uuid_to_close)) |kv| {
            // Tell ses to kill only if the pane is still alive.
            // Dead panes already reported by SES should be removed locally
            // without another synchronous kill request.
            if (self.runtime) |runtime| {
                if (kv.value.isAlive()) {
                    runtime.killPane(kv.value.uuid) catch {};
                }
            }
            kv.value.deinit();
            self.allocator.destroy(kv.value);
        }

        // Remove from layout tree and restructure
        if (self.root) |root| {
            self.removeFromTree(root, null, uuid_to_close);
        }

        self.recalculateLayout();
        return true;
    }

    /// Close a specific pane by ID.
    ///
    /// This is used when the event loop detects a specific pane has died.
    pub fn closePane(self: *Layout, uuid_to_close: [32]u8) bool {
        if (self.splits.count() <= 1) return false;
        if (!self.splits.contains(uuid_to_close)) return false;

        // If we're closing the focused pane, move focus first.
        if (self.focused_pane_uuid) |focused_uuid| {
            if (std.mem.eql(u8, &uuid_to_close, &focused_uuid)) {
                self.focusNext();
            }
        }

        if (self.splits.fetchRemove(uuid_to_close)) |kv| {
            if (self.runtime) |runtime| {
                if (kv.value.isAlive()) {
                    runtime.killPane(kv.value.uuid) catch {};
                }
            }
            kv.value.deinit();
            self.allocator.destroy(kv.value);
        }

        if (self.root) |root| {
            self.removeFromTree(root, null, uuid_to_close);
        }
        self.recalculateLayout();
        return true;
    }

    pub fn swapPaneNodes(self: *Layout, pane_a_uuid: [32]u8, pane_b_uuid: [32]u8) bool {
        if (std.mem.eql(u8, &pane_a_uuid, &pane_b_uuid)) return false;
        const root = self.root orelse return false;

        const node_a = self.findNode(root, pane_a_uuid) orelse return false;
        const node_b = self.findNode(root, pane_b_uuid) orelse return false;

        node_a.* = .{ .pane = pane_b_uuid };
        node_b.* = .{ .pane = pane_a_uuid };
        self.recalculateLayout();
        return true;
    }

    fn removeFromTree(self: *Layout, node: *LayoutNode, parent: ?*LayoutNode, pane_uuid: [32]u8) void {
        switch (node.*) {
            .pane => |uuid| {
                if (std.mem.eql(u8, &uuid, &pane_uuid) and parent != null) {
                    // This is handled by the parent split case
                }
            },
            .split => |split| {
                // Check if either child is the pane to remove
                switch (split.first.*) {
                    .pane => |uuid| {
                        if (std.mem.eql(u8, &uuid, &pane_uuid)) {
                            // Replace this split with second child
                            const second = split.second.*;
                            self.allocator.destroy(split.first);
                            self.allocator.destroy(split.second);
                            node.* = second;
                            return;
                        }
                    },
                    else => {},
                }
                switch (split.second.*) {
                    .pane => |uuid| {
                        if (std.mem.eql(u8, &uuid, &pane_uuid)) {
                            // Replace this split with first child
                            const first = split.first.*;
                            self.allocator.destroy(split.first);
                            self.allocator.destroy(split.second);
                            node.* = first;
                            return;
                        }
                    },
                    else => {},
                }
                // Recurse
                self.removeFromTree(split.first, node, pane_uuid);
                self.removeFromTree(split.second, node, pane_uuid);
            },
        }
    }

    /// Get iterator over all panes
    pub fn splitIterator(self: *Layout) std.AutoHashMap([32]u8, *Pane).ValueIterator {
        return self.splits.valueIterator();
    }

    /// Get pane count
    pub fn splitCount(self: *Layout) usize {
        return self.splits.count();
    }

    /// Get index of focused pane in iteration order
    pub fn getFocusedIndex(self: *Layout) usize {
        var panes: [16]*Pane = undefined;
        var count: usize = 0;

        var it = self.splits.valueIterator();
        while (it.next()) |pane| {
            if (count < 16) {
                panes[count] = pane.*;
                count += 1;
            }
        }

        const Ctx = struct {
            fn lessThan(_: void, a: *Pane, b: *Pane) bool {
                return a.id < b.id;
            }
        };
        std.mem.sort(*Pane, panes[0..count], {}, Ctx.lessThan);

        const focused_uuid = self.focused_pane_uuid orelse return 0;
        for (panes[0..count], 0..) |pane, i| {
            if (std.mem.eql(u8, &pane.uuid, &focused_uuid)) return i;
        }

        return 0;
    }
};
