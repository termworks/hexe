const std = @import("std");
const core = @import("core");
const view_model = @import("view_model.zig");

const BindAction = core.Config.BindAction;
const BindKeyKind = core.Config.BindKeyKind;
const session_model = core.session_model;

/// Frontend-neutral cardinal direction used by actions. Concrete hosts can map
/// this to split resizing, float movement, focus movement, or web pointer UI.
pub const Direction = enum {
    up,
    down,
    left,
    right,
};

/// Actions that are inherently tied to a concrete host surface rather than SES
/// session semantics.
pub const HostSurfaceAction = enum {
    clipboard_copy,
    clipboard_request,
    system_notify,
    keycast_toggle,
    sprite_toggle,
    sync_toggle,
    tab_rename,
    pane_zoom,
    config_reload,
    copy_enter,
    search_enter,
};

/// Frontend-neutral action request distilled from a config keybinding.
///
/// This is intentionally only semantic normalization for now. The actual state
/// mutation still lives in the terminal frontend until each behavior can be
/// moved behind test-covered core state/action modules safely.
pub const ActionRequest = union(enum) {
    mux_quit,
    mux_detach,
    pane_disown,
    pane_adopt,
    pane_close,
    pane_select_mode,
    split_h,
    split_v,
    split_resize: Direction,
    tab_new,
    tab_select,
    tab_next,
    tab_prev,
    tab_close,
    tab_remove,
    float_toggle: u8,
    float_select,
    float_nudge: Direction,
    focus_set,
    tab_focus_set,
    focus_move: Direction,
    layout_save,
    layout_load,
    host_surface: HostSurfaceAction,
    invalid_direction,
};

pub const ActionApplyResult = enum {
    applied,
    ignored,
    unsupported,
};

pub const FloatGeometryContext = struct {
    pane_uuid: [32]u8,
    width_pct: u8,
    height_pct: u8,
    pos_x_pct: u8,
    pos_y_pct: u8,
    pad_x: u8,
    pad_y: u8,
};

pub const AddTabContext = struct {
    tab_idx: usize,
    tab_uuid: [32]u8,
    name: []const u8,
    pane_uuid: [32]u8,
};

pub const SplitPaneContext = struct {
    tab_idx: usize,
    source_pane_uuid: [32]u8,
    new_pane_uuid: [32]u8,
    focused_pane_uuid: ?[32]u8 = null,
};

pub const SyncFloatContext = struct {
    float_state: session_model.SessionFloat,
    active: bool,
};

pub const ReplacePaneContext = struct {
    old_pane_uuid: [32]u8,
    new_pane_uuid: [32]u8,
};

pub const SplitRatioContext = struct {
    first_anchor_uuid: [32]u8,
    second_anchor_uuid: [32]u8,
    ratio: f32,
};

pub const ViewActionContext = struct {
    split_axis_cells: u16 = 0,
    step_cells: u16 = 1,
    add_tab: ?AddTabContext = null,
    split_pane: ?SplitPaneContext = null,
    sync_float: ?SyncFloatContext = null,
    replace_pane: ?ReplacePaneContext = null,
    split_ratio: ?SplitRatioContext = null,
    float_geometry: ?FloatGeometryContext = null,
    active_tab_idx: ?usize = null,
    remove_tab_idx: ?usize = null,
    next_active_tab_idx: ?usize = null,
    active_float_uuid: ?[32]u8 = null,
    clear_active_float: bool = false,
    focus_target_uuid: ?[32]u8 = null,
    focus_tab_idx: ?usize = null,
    clear_focus: bool = false,
    remove_pane_uuid: ?[32]u8 = null,
    next_focus_uuid: ?[32]u8 = null,
};

pub const ViewActionOutcome = struct {
    result: ActionApplyResult,
    split_ratio: ?view_model.SplitRatioChange = null,
};

pub fn directionFromBindKeyKind(kind: BindKeyKind) ?Direction {
    return switch (kind) {
        .up => .up,
        .down => .down,
        .left => .left,
        .right => .right,
        else => null,
    };
}

pub fn actionRequestFromBindAction(action: BindAction) ActionRequest {
    return switch (action) {
        .mux_quit => .mux_quit,
        .mux_detach => .mux_detach,
        .pane_disown => .pane_disown,
        .pane_adopt => .pane_adopt,
        .pane_close => .pane_close,
        .pane_select_mode => .pane_select_mode,
        .clipboard_copy => .{ .host_surface = .clipboard_copy },
        .clipboard_request => .{ .host_surface = .clipboard_request },
        .system_notify => .{ .host_surface = .system_notify },
        .keycast_toggle => .{ .host_surface = .keycast_toggle },
        .sprite_toggle => .{ .host_surface = .sprite_toggle },
        .sync_toggle => .{ .host_surface = .sync_toggle },
        .tab_rename => .{ .host_surface = .tab_rename },
        .pane_zoom => .{ .host_surface = .pane_zoom },
        .config_reload => .{ .host_surface = .config_reload },
        .copy_enter => .{ .host_surface = .copy_enter },
        .search_enter => .{ .host_surface = .search_enter },
        .split_h => .split_h,
        .split_v => .split_v,
        .split_resize => |dir| if (directionFromBindKeyKind(dir)) |value|
            .{ .split_resize = value }
        else
            .invalid_direction,
        .tab_new => .tab_new,
        .tab_next => .tab_next,
        .tab_prev => .tab_prev,
        .tab_close => .tab_close,
        .float_toggle => |key| .{ .float_toggle = key },
        .float_nudge => |dir| if (directionFromBindKeyKind(dir)) |value|
            .{ .float_nudge = value }
        else
            .invalid_direction,
        .focus_move => |dir| if (directionFromBindKeyKind(dir)) |value|
            .{ .focus_move = value }
        else
            .invalid_direction,
        .layout_save => .layout_save,
        .layout_load => .layout_load,
    };
}

/// Apply the subset of frontend actions that are pure shared-view mutations.
///
/// This is intentionally small: actions that create/kill panes, talk to SES, or
/// need host presentation remain outside this helper until they can be moved
/// with explicit tests. Non-terminal hosts can still unit-test navigation
/// semantics here without raw terminal setup.
pub fn applyViewAction(view: *view_model.SessionView, request: ActionRequest) !ActionApplyResult {
    return (try applyViewActionWithContext(view, request, .{})).result;
}

/// Apply frontend actions that can be expressed as shared-view mutations.
///
/// Some actions need host measurements or host-computed geometry. The context
/// carries only those neutral values; the mutation itself still happens in the
/// shared `SessionView`, so terminal/web/syslink can converge on the same
/// semantics without depending on terminal `State`.
pub fn applyViewActionWithContext(view: *view_model.SessionView, request: ActionRequest, context: ViewActionContext) !ViewActionOutcome {
    return switch (request) {
        .tab_next => {
            if (view.tabs.items.len <= 1 or view.active_tab >= view.tabs.items.len - 1) return .{ .result = .ignored };
            try view.applyActiveTab(view.active_tab + 1);
            return .{ .result = .applied };
        },
        .tab_prev => {
            if (view.tabs.items.len <= 1 or view.active_tab == 0) return .{ .result = .ignored };
            try view.applyActiveTab(view.active_tab - 1);
            return .{ .result = .applied };
        },
        .tab_new => {
            const add = context.add_tab orelse return .{ .result = .ignored };
            try view.applyAddTab(add.tab_idx, add.tab_uuid, add.name, add.pane_uuid);
            return .{ .result = .applied };
        },
        .tab_select => {
            const idx = context.active_tab_idx orelse return .{ .result = .ignored };
            try view.applyActiveTab(idx);
            return .{ .result = .applied };
        },
        .tab_close => {
            if (view.tabs.items.len <= 1 or view.active_tab >= view.tabs.items.len) return .{ .result = .ignored };
            const closing_tab = view.active_tab;
            const next_active_tab: usize = if (closing_tab >= view.tabs.items.len - 1)
                view.tabs.items.len - 2
            else
                closing_tab;
            try view.applyRemoveTab(closing_tab, next_active_tab);
            return .{ .result = .applied };
        },
        .tab_remove => {
            const tab_idx = context.remove_tab_idx orelse return .{ .result = .ignored };
            try view.applyRemoveTab(tab_idx, context.next_active_tab_idx);
            return .{ .result = .applied };
        },
        .pane_close => {
            const pane_uuid = context.remove_pane_uuid orelse return .{ .result = .ignored };
            try view.applyRemovePane(pane_uuid, context.next_focus_uuid);
            return .{ .result = .applied };
        },
        .split_h, .split_v => {
            const split = context.split_pane orelse return .{ .result = .ignored };
            try view.applySplitPane(
                split.tab_idx,
                split.source_pane_uuid,
                split.new_pane_uuid,
                split.focused_pane_uuid,
                if (request == .split_h) .horizontal else .vertical,
            );
            return .{ .result = .applied };
        },
        .split_resize => |dir| {
            if (context.split_ratio) |ratio| {
                if (try view.applySplitRatio(
                    view.active_tab,
                    ratio.first_anchor_uuid,
                    ratio.second_anchor_uuid,
                    ratio.ratio,
                )) {
                    return .{
                        .result = .applied,
                        .split_ratio = .{
                            .first_anchor_uuid = ratio.first_anchor_uuid,
                            .second_anchor_uuid = ratio.second_anchor_uuid,
                            .ratio = ratio.ratio,
                        },
                    };
                }
                return .{ .result = .ignored };
            }
            const change = try view.applyResizeFocusedSplit(
                view.active_tab,
                resizeDirectionFromAction(dir),
                context.split_axis_cells,
                context.step_cells,
            ) orelse return .{ .result = .ignored };
            return .{ .result = .applied, .split_ratio = change };
        },
        .float_nudge => {
            const geometry = context.float_geometry orelse return .{ .result = .ignored };
            try view.applyFloatGeometry(
                geometry.pane_uuid,
                geometry.width_pct,
                geometry.height_pct,
                geometry.pos_x_pct,
                geometry.pos_y_pct,
                geometry.pad_x,
                geometry.pad_y,
            );
            return .{ .result = .applied };
        },
        .float_toggle => {
            const sync = context.sync_float orelse return .{ .result = .ignored };
            try view.applySyncFloat(sync.float_state, sync.active);
            return .{ .result = .applied };
        },
        .float_select => {
            if (context.clear_active_float) {
                try view.applyActiveFloat(null);
                return .{ .result = .applied };
            }
            const uuid = context.active_float_uuid orelse return .{ .result = .ignored };
            try view.applyActiveFloat(uuid);
            return .{ .result = .applied };
        },
        .focus_set => {
            if (context.clear_focus) {
                try view.applyFocusedPane(null);
                return .{ .result = .applied };
            }
            const target_uuid = context.focus_target_uuid orelse return .{ .result = .ignored };
            try view.applyFocusedPane(target_uuid);
            return .{ .result = .applied };
        },
        .tab_focus_set => {
            const tab_idx = context.focus_tab_idx orelse return .{ .result = .ignored };
            if (context.clear_focus) {
                try view.applyTabFocusedPane(tab_idx, null);
                return .{ .result = .applied };
            }
            const target_uuid = context.focus_target_uuid orelse return .{ .result = .ignored };
            try view.applyTabFocusedPane(tab_idx, target_uuid);
            return .{ .result = .applied };
        },
        .focus_move => {
            const target_uuid = context.focus_target_uuid orelse return .{ .result = .ignored };
            try view.applyFocusedPane(target_uuid);
            return .{ .result = .applied };
        },
        .pane_adopt, .pane_disown => {
            const replace = context.replace_pane orelse return .{ .result = .ignored };
            try view.applyReplacePane(replace.old_pane_uuid, replace.new_pane_uuid);
            return .{ .result = .applied };
        },
        else => .{ .result = .unsupported },
    };
}

fn resizeDirectionFromAction(direction: Direction) view_model.ResizeDirection {
    return switch (direction) {
        .up => .up,
        .down => .down,
        .left => .left,
        .right => .right,
    };
}

test "directionFromBindKeyKind normalizes cardinal directions" {
    try std.testing.expectEqual(Direction.up, directionFromBindKeyKind(.up).?);
    try std.testing.expectEqual(Direction.down, directionFromBindKeyKind(.down).?);
    try std.testing.expectEqual(Direction.left, directionFromBindKeyKind(.left).?);
    try std.testing.expectEqual(Direction.right, directionFromBindKeyKind(.right).?);
}

test "directionFromBindKeyKind rejects non-direction keys" {
    try std.testing.expect(directionFromBindKeyKind(.space) == null);
    try std.testing.expect(directionFromBindKeyKind(.char) == null);
}

test "actionRequestFromBindAction preserves payloads" {
    try std.testing.expectEqual(Direction.left, actionRequestFromBindAction(.{ .focus_move = .left }).focus_move);
    try std.testing.expectEqual(@as(u8, '3'), actionRequestFromBindAction(.{ .float_toggle = '3' }).float_toggle);
}

test "actionRequestFromBindAction categorizes host-surface actions" {
    try std.testing.expectEqual(
        HostSurfaceAction.clipboard_copy,
        actionRequestFromBindAction(.clipboard_copy).host_surface,
    );
    try std.testing.expectEqual(
        HostSurfaceAction.system_notify,
        actionRequestFromBindAction(.system_notify).host_surface,
    );
    try std.testing.expectEqual(
        HostSurfaceAction.sync_toggle,
        actionRequestFromBindAction(.sync_toggle).host_surface,
    );
    try std.testing.expectEqual(
        HostSurfaceAction.tab_rename,
        actionRequestFromBindAction(.tab_rename).host_surface,
    );
    try std.testing.expectEqual(
        HostSurfaceAction.pane_zoom,
        actionRequestFromBindAction(.pane_zoom).host_surface,
    );
    try std.testing.expectEqual(
        HostSurfaceAction.config_reload,
        actionRequestFromBindAction(.config_reload).host_surface,
    );
    try std.testing.expectEqual(
        HostSurfaceAction.copy_enter,
        actionRequestFromBindAction(.copy_enter).host_surface,
    );
    try std.testing.expectEqual(
        HostSurfaceAction.search_enter,
        actionRequestFromBindAction(.search_enter).host_surface,
    );
}

test "applyViewAction handles pure tab navigation in shared view" {
    const allocator = std.testing.allocator;

    var snapshot = try session_model.SessionSnapshot.initMinimal(allocator, [_]u8{'s'} ** 32, "alpha");
    defer snapshot.deinit();
    try snapshot.tabs.append(allocator, .{
        .uuid = [_]u8{'a'} ** 32,
        .name = try allocator.dupe(u8, "one"),
        .allocator = allocator,
    });
    try snapshot.tabs.append(allocator, .{
        .uuid = [_]u8{'b'} ** 32,
        .name = try allocator.dupe(u8, "two"),
        .allocator = allocator,
    });

    var view = try view_model.SessionView.fromSnapshot(allocator, &snapshot);
    defer view.deinit();

    try std.testing.expectEqual(ActionApplyResult.applied, try applyViewAction(&view, .tab_next));
    try std.testing.expectEqual(@as(usize, 1), view.active_tab);
    try std.testing.expectEqual(ActionApplyResult.ignored, try applyViewAction(&view, .tab_next));
    try std.testing.expectEqual(ActionApplyResult.applied, try applyViewAction(&view, .tab_prev));
    try std.testing.expectEqual(@as(usize, 0), view.active_tab);
    // pane_close now has a handler arm; without a remove_pane_uuid context it
    // is understood-but-not-actionable, i.e. `.ignored` (it used to be
    // `.unsupported` when the action had no arm at all).
    try std.testing.expectEqual(ActionApplyResult.ignored, try applyViewAction(&view, .pane_close));
}

test "applyViewAction closes the active tab in shared view" {
    const allocator = std.testing.allocator;

    var snapshot = try session_model.SessionSnapshot.initMinimal(allocator, [_]u8{'s'} ** 32, "alpha");
    defer snapshot.deinit();
    snapshot.active_tab = 1;
    try snapshot.tabs.append(allocator, .{
        .uuid = [_]u8{'a'} ** 32,
        .name = try allocator.dupe(u8, "one"),
        .allocator = allocator,
    });
    try snapshot.tabs.append(allocator, .{
        .uuid = [_]u8{'b'} ** 32,
        .name = try allocator.dupe(u8, "two"),
        .allocator = allocator,
    });
    try snapshot.tabs.append(allocator, .{
        .uuid = [_]u8{'c'} ** 32,
        .name = try allocator.dupe(u8, "three"),
        .allocator = allocator,
    });
    try snapshot.panes.put([_]u8{'a'} ** 32, .{
        .uuid = [_]u8{'a'} ** 32,
        .kind = .split,
        .parent_tab = 0,
    });
    try snapshot.panes.put([_]u8{'b'} ** 32, .{
        .uuid = [_]u8{'b'} ** 32,
        .kind = .split,
        .parent_tab = 1,
    });
    try snapshot.panes.put([_]u8{'c'} ** 32, .{
        .uuid = [_]u8{'c'} ** 32,
        .kind = .split,
        .parent_tab = 2,
    });

    var view = try view_model.SessionView.fromSnapshot(allocator, &snapshot);
    defer view.deinit();

    try std.testing.expectEqual(ActionApplyResult.applied, try applyViewAction(&view, .tab_close));
    try std.testing.expectEqual(@as(usize, 2), view.tabs.items.len);
    try std.testing.expect(view.findPane([_]u8{'b'} ** 32) == null);
    try std.testing.expectEqual(@as(?usize, 1), view.findPane([_]u8{'c'} ** 32).?.parent_tab);
    try std.testing.expectEqual(@as(usize, 1), view.active_tab);
}

test "applyViewActionWithContext handles split resize and float geometry actions" {
    const allocator = std.testing.allocator;

    var snapshot = try session_model.SessionSnapshot.initMinimal(allocator, [_]u8{'s'} ** 32, "alpha");
    defer snapshot.deinit();
    try snapshot.tabs.append(allocator, .{
        .uuid = [_]u8{'t'} ** 32,
        .name = try allocator.dupe(u8, "one"),
        .focused_pane_uuid = [_]u8{'p'} ** 32,
        .allocator = allocator,
    });
    try snapshot.panes.put([_]u8{'p'} ** 32, .{
        .uuid = [_]u8{'p'} ** 32,
        .kind = .split,
        .parent_tab = 0,
    });
    try snapshot.panes.put([_]u8{'q'} ** 32, .{
        .uuid = [_]u8{'q'} ** 32,
        .kind = .split,
        .parent_tab = 0,
    });
    try snapshot.panes.put([_]u8{'f'} ** 32, .{
        .uuid = [_]u8{'f'} ** 32,
        .kind = .float,
        .parent_tab = 0,
    });
    const left = try allocator.create(session_model.SessionLayoutNode);
    errdefer allocator.destroy(left);
    left.* = .{ .pane = [_]u8{'p'} ** 32 };
    const right = try allocator.create(session_model.SessionLayoutNode);
    errdefer allocator.destroy(right);
    right.* = .{ .pane = [_]u8{'q'} ** 32 };
    const root = try allocator.create(session_model.SessionLayoutNode);
    root.* = .{ .split = .{
        .dir = .horizontal,
        .ratio = 0.5,
        .first = left,
        .second = right,
    } };
    snapshot.tabs.items[0].root = root;
    try snapshot.floats.append(allocator, .{
        .pane_uuid = [_]u8{'f'} ** 32,
        .parent_tab = 0,
    });

    var view = try view_model.SessionView.fromSnapshot(allocator, &snapshot);
    defer view.deinit();

    const add = try applyViewActionWithContext(&view, .tab_new, .{
        .add_tab = .{
            .tab_idx = 1,
            .tab_uuid = [_]u8{'n'} ** 32,
            .name = "new",
            .pane_uuid = [_]u8{'r'} ** 32,
        },
    });
    try std.testing.expectEqual(ActionApplyResult.applied, add.result);
    try std.testing.expectEqual(@as(usize, 2), view.tabs.items.len);
    try std.testing.expectEqualSlices(u8, "new", view.tabs.items[1].name);

    const tab_select = try applyViewActionWithContext(&view, .tab_select, .{
        .active_tab_idx = 1,
    });
    try std.testing.expectEqual(ActionApplyResult.applied, tab_select.result);
    try std.testing.expectEqual(@as(usize, 1), view.active_tab);

    const float_select = try applyViewActionWithContext(&view, .float_select, .{
        .active_float_uuid = [_]u8{'f'} ** 32,
    });
    try std.testing.expectEqual(ActionApplyResult.applied, float_select.result);
    try std.testing.expectEqualSlices(u8, &([_]u8{'f'} ** 32), &view.active_float_uuid.?);
    const float_clear = try applyViewActionWithContext(&view, .float_select, .{
        .clear_active_float = true,
    });
    try std.testing.expectEqual(ActionApplyResult.applied, float_clear.result);
    try std.testing.expect(view.active_float_uuid == null);

    const focus_set = try applyViewActionWithContext(&view, .focus_set, .{
        .focus_target_uuid = [_]u8{'p'} ** 32,
    });
    try std.testing.expectEqual(ActionApplyResult.applied, focus_set.result);
    try std.testing.expectEqualSlices(u8, &([_]u8{'p'} ** 32), &view.focused_pane_uuid.?);
    const tab_focus_set = try applyViewActionWithContext(&view, .tab_focus_set, .{
        .focus_tab_idx = 0,
        .focus_target_uuid = [_]u8{'p'} ** 32,
    });
    try std.testing.expectEqual(ActionApplyResult.applied, tab_focus_set.result);
    try std.testing.expectEqualSlices(u8, &([_]u8{'p'} ** 32), &view.tabs.items[0].focused_pane_uuid.?);
    const focus_clear = try applyViewActionWithContext(&view, .focus_set, .{
        .clear_focus = true,
    });
    try std.testing.expectEqual(ActionApplyResult.applied, focus_clear.result);
    try std.testing.expect(view.focused_pane_uuid == null);
    _ = try applyViewActionWithContext(&view, .tab_select, .{
        .active_tab_idx = 0,
    });

    const resize = try applyViewActionWithContext(&view, .{ .split_resize = .right }, .{
        .split_axis_cells = 10,
        .step_cells = 1,
    });
    try std.testing.expectEqual(ActionApplyResult.applied, resize.result);
    try std.testing.expect(resize.split_ratio != null);
    try std.testing.expect(std.math.approxEqAbs(f32, 0.6, resize.split_ratio.?.ratio, 0.0001));

    const geometry = try applyViewActionWithContext(&view, .{ .float_nudge = .right }, .{
        .float_geometry = .{
            .pane_uuid = [_]u8{'f'} ** 32,
            .width_pct = 61,
            .height_pct = 62,
            .pos_x_pct = 63,
            .pos_y_pct = 64,
            .pad_x = 2,
            .pad_y = 3,
        },
    });
    try std.testing.expectEqual(ActionApplyResult.applied, geometry.result);
    try std.testing.expectEqual(@as(u8, 63), view.findFloat([_]u8{'f'} ** 32).?.pos_x_pct);

    const sync_float = try applyViewActionWithContext(&view, .{ .float_toggle = '3' }, .{
        .sync_float = .{
            .float_state = .{
                .pane_uuid = [_]u8{'f'} ** 32,
                .parent_tab = 0,
                .visible = false,
                .sticky = true,
                .float_key = '3',
            },
            .active = false,
        },
    });
    try std.testing.expectEqual(ActionApplyResult.applied, sync_float.result);
    try std.testing.expect(view.findPane([_]u8{'f'} ** 32).?.sticky);

    const replace = try applyViewActionWithContext(&view, .pane_adopt, .{
        .replace_pane = .{
            .old_pane_uuid = [_]u8{'f'} ** 32,
            .new_pane_uuid = [_]u8{'g'} ** 32,
        },
    });
    try std.testing.expectEqual(ActionApplyResult.applied, replace.result);
    try std.testing.expect(view.findPane([_]u8{'f'} ** 32) == null);
    try std.testing.expect(view.findPane([_]u8{'g'} ** 32) != null);

    const focus = try applyViewActionWithContext(&view, .{ .focus_move = .right }, .{
        .focus_target_uuid = [_]u8{'q'} ** 32,
    });
    try std.testing.expectEqual(ActionApplyResult.applied, focus.result);
    try std.testing.expectEqualSlices(u8, &([_]u8{'q'} ** 32), &view.focused_pane_uuid.?);
    try std.testing.expectEqualSlices(u8, &([_]u8{'q'} ** 32), &view.tabs.items[0].focused_pane_uuid.?);

    const close = try applyViewActionWithContext(&view, .pane_close, .{
        .remove_pane_uuid = [_]u8{'q'} ** 32,
        .next_focus_uuid = [_]u8{'p'} ** 32,
    });
    try std.testing.expectEqual(ActionApplyResult.applied, close.result);
    try std.testing.expect(view.findPane([_]u8{'q'} ** 32) == null);
    try std.testing.expectEqualSlices(u8, &([_]u8{'p'} ** 32), &view.focused_pane_uuid.?);

    const split = try applyViewActionWithContext(&view, .split_v, .{
        .split_pane = .{
            .tab_idx = 1,
            .source_pane_uuid = [_]u8{'r'} ** 32,
            .new_pane_uuid = [_]u8{'s'} ** 32,
            .focused_pane_uuid = [_]u8{'s'} ** 32,
        },
    });
    try std.testing.expectEqual(ActionApplyResult.applied, split.result);
    try std.testing.expect(view.findPane([_]u8{'s'} ** 32) != null);
}
