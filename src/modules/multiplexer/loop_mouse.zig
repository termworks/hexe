const std = @import("std");
const vaxis = @import("vaxis");

const core = @import("core");

const layout_mod = @import("layout.zig");
const focus_nav = @import("focus_nav.zig");
const float_title = @import("float_title.zig");
const float_util = @import("float_util.zig");
const mouse_selection = @import("mouse_selection.zig");
const statusbar = @import("statusbar.zig");

const Pane = @import("pane.zig").Pane;
const State = @import("state.zig").State;

const FocusTarget = focus_nav.FocusTarget;

fn runStatusbarAction(state: *State, command: []const u8) void {
    if (command.len == 0) return;

    const wrapped = std.fmt.allocPrint(state.allocator, "({s}) >/dev/null 2>&1 &", .{command}) catch {
        state.notifications.showFor("status action alloc failed", 1400);
        state.needs_render = true;
        return;
    };
    defer state.allocator.free(wrapped);

    var env_map_opt = std.process.getEnvMap(state.allocator) catch null;
    defer if (env_map_opt) |*m| m.deinit();

    if (env_map_opt) |*env_map| {
        if (state.getCurrentFocusedUuid()) |uuid| {
            env_map.put("HEXE_PANE_UUID", uuid[0..]) catch {};
            env_map.put("HEXE_FOCUSED_PANE_UUID", uuid[0..]) catch {};
            env_map.put("HEXE_STATUS_FOCUSED_PANE_UUID", uuid[0..]) catch {};
        }
    }

    var child = std.process.Child.init(&.{ "/bin/bash", "-lc", wrapped }, state.allocator);
    if (env_map_opt) |*env_map| child.env_map = env_map;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch {
        state.notifications.showFor("status action spawn failed", 1400);
        state.needs_render = true;
        return;
    };
    _ = child.wait() catch {};
}

fn mouseModsMask(btn: u16) u8 {
    // SGR mouse modifier bits:
    // - shift: 4
    // - alt: 8
    // - ctrl: 16
    // Map to hexe mod mask:
    // - alt: 1
    // - ctrl: 2
    // - shift: 4
    var mods: u8 = 0;
    if ((btn & 8) != 0) mods |= 1;
    if ((btn & 16) != 0) mods |= 2;
    if ((btn & 4) != 0) mods |= 4;
    return mods;
}

fn absDiffU16(a: u16, b: u16) u16 {
    return if (a >= b) a - b else b - a;
}

fn toLocalClamped(pane: *Pane, abs_x: u16, abs_y: u16) mouse_selection.Pos {
    const lx = if (abs_x > pane.x) abs_x - pane.x else 0;
    const ly = if (abs_y > pane.y) abs_y - pane.y else 0;
    return mouse_selection.clampLocalToPane(lx, ly, pane.width, pane.height);
}

/// Forward a mouse event to a pane with translated coordinates.
/// The app expects pane-local coordinates, not absolute screen coordinates.
const MouseEvent = struct {
    btn: u16,
    x: u16,
    y: u16,
    is_release: bool,
};

fn encodeMouseEvent(mouse: vaxis.Mouse) MouseEvent {
    var btn: u16 = switch (mouse.button) {
        .left => 0,
        .middle => 1,
        .right => 2,
        .none => 3,
        .wheel_up => 64,
        .wheel_down => 65,
        .wheel_right => 66,
        .wheel_left => 67,
        .button_8 => 128,
        .button_9 => 129,
        .button_10 => 130,
        .button_11 => 131,
    };

    if (mouse.mods.shift) btn |= 4;
    if (mouse.mods.alt) btn |= 8;
    if (mouse.mods.ctrl) btn |= 16;
    if (mouse.type == .motion or mouse.type == .drag) btn |= 32;

    return .{
        .btn = btn,
        .x = if (mouse.col <= 0) 0 else @intCast(mouse.col),
        .y = if (mouse.row <= 0) 0 else @intCast(mouse.row),
        .is_release = mouse.type == .release,
    };
}

fn forwardMouseToPane(pane: *Pane, ev: MouseEvent) void {
    // Convert absolute coords to pane-local (1-based for SGR)
    const local_x: u16 = if (ev.x >= pane.x) ev.x - pane.x + 1 else 1;
    const local_y: u16 = if (ev.y >= pane.y) ev.y - pane.y + 1 else 1;

    // Build SGR mouse sequence: ESC [ < btn ; x ; y M/m
    var buf: [32]u8 = undefined;
    const terminator: u8 = if (ev.is_release) 'm' else 'M';
    const len = std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{ ev.btn, local_x, local_y, terminator }) catch return;
    pane.write(len) catch {};
}

fn focusTarget(state: *State, target: FocusTarget) void {
    const old_uuid = state.getCurrentFocusedUuid();
    if (target.kind == .float) {
        state.active_floating = target.float_index;
        state.syncPaneFocus(target.pane, old_uuid);
    } else {
        state.active_floating = null;
        state.syncPaneFocus(target.pane, old_uuid);
    }
    state.renderer.invalidate();
    state.force_full_render = true;
    state.needs_render = true;
}

const isFloatRenderableOnTab = float_util.isFloatRenderableOnTab;

fn findFocusableAt(state: *State, x: u16, y: u16) ?FocusTarget {
    // Floats are topmost - check active first, then others in reverse.
    if (state.active_floating) |afi| {
        if (afi < state.floats.items.len) {
            const fp = state.floats.items[afi];
            if (isFloatRenderableOnTab(fp, state.active_tab)) {
                if (x >= fp.border_x and x < fp.border_x + fp.border_w and y >= fp.border_y and y < fp.border_y + fp.border_h) {
                    return .{ .kind = .float, .pane = fp, .float_index = afi };
                }
            }
        }
    }

    var fi: usize = state.floats.items.len;
    while (fi > 0) {
        fi -= 1;
        const fp = state.floats.items[fi];
        if (!isFloatRenderableOnTab(fp, state.active_tab)) continue;
        if (x >= fp.border_x and x < fp.border_x + fp.border_w and y >= fp.border_y and y < fp.border_y + fp.border_h) {
            return .{ .kind = .float, .pane = fp, .float_index = fi };
        }
    }

    var it = state.currentLayout().splits.valueIterator();
    while (it.next()) |pane_ptr| {
        const p = pane_ptr.*;
        if (x >= p.x and x < p.x + p.width and y >= p.y and y < p.y + p.height) {
            return .{ .kind = .split, .pane = p, .float_index = null };
        }
    }
    return null;
}

fn isSplitJunction(state: *State, x: u16, y: u16) bool {
    // Matches the border draw logic: a junction is where a vertical divider and
    // a horizontal divider cross.
    var v_lines: [64]u16 = undefined;
    var v_count: usize = 0;
    var h_lines: [64]u16 = undefined;
    var h_count: usize = 0;

    const layout = state.currentLayout();
    var pit = layout.splitIterator();
    while (pit.next()) |pane| {
        const right_edge = pane.*.x + pane.*.width;
        const bottom_edge = pane.*.y + pane.*.height;
        if (v_count < v_lines.len) {
            var seen = false;
            for (v_lines[0..v_count]) |vx| {
                if (vx == right_edge) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                v_lines[v_count] = right_edge;
                v_count += 1;
            }
        }
        if (h_count < h_lines.len) {
            var seen2 = false;
            for (h_lines[0..h_count]) |hy| {
                if (hy == bottom_edge) {
                    seen2 = true;
                    break;
                }
            }
            if (!seen2) {
                h_lines[h_count] = bottom_edge;
                h_count += 1;
            }
        }
    }

    var is_v = false;
    for (v_lines[0..v_count]) |vx| {
        if (vx == x) {
            is_v = true;
            break;
        }
    }
    if (!is_v) return false;
    for (h_lines[0..h_count]) |hy| {
        if (hy == y) return true;
    }
    return false;
}

const DividerHit = State.MouseDragSplitResize;

fn hitTestDivider(layout: *layout_mod.Layout, x: u16, y: u16) ?DividerHit {
    if (layout.root == null) return null;

    const Rec = struct {
        fn rec(node: *layout_mod.LayoutNode, rx: u16, ry: u16, rw: u16, rh: u16, mx: u16, my: u16) ?DividerHit {
            return switch (node.*) {
                .pane => null,
                .split => |*sp| blk: {
                    switch (sp.dir) {
                        .horizontal => {
                            const first_w: u16 = @as(u16, @intFromFloat(@as(f32, @floatFromInt(rw)) * sp.ratio)) -| 1;
                            const div_x = rx + first_w;
                            if (mx == div_x and my >= ry and my < ry + rh) {
                                break :blk .{ .split = sp, .dir = .horizontal, .x = rx, .y = ry, .w = rw, .h = rh };
                            }
                            if (mx < div_x) {
                                break :blk rec(sp.first, rx, ry, first_w, rh, mx, my);
                            }
                            if (mx > div_x) {
                                const second_w = rw -| first_w -| 1;
                                break :blk rec(sp.second, rx + first_w + 1, ry, second_w, rh, mx, my);
                            }
                            break :blk null;
                        },
                        .vertical => {
                            const first_h: u16 = @as(u16, @intFromFloat(@as(f32, @floatFromInt(rh)) * sp.ratio)) -| 1;
                            const div_y = ry + first_h;
                            if (my == div_y and mx >= rx and mx < rx + rw) {
                                break :blk .{ .split = sp, .dir = .vertical, .x = rx, .y = ry, .w = rw, .h = rh };
                            }
                            if (my < div_y) {
                                break :blk rec(sp.first, rx, ry, rw, first_h, mx, my);
                            }
                            if (my > div_y) {
                                const second_h = rh -| first_h -| 1;
                                break :blk rec(sp.second, rx, ry + first_h + 1, rw, second_h, mx, my);
                            }
                            break :blk null;
                        },
                    }
                },
            };
        }
    };

    return Rec.rec(layout.root.?, layout.x, layout.y, layout.width, layout.height, x, y);
}

fn beginFloatMove(state: *State, pane: *Pane, start_x: u16, start_y: u16) void {
    // Only movable if it has a title widget.
    if (float_title.getTitleRect(pane) == null) return;
    state.mouse_drag = .{ .float_move = .{ .uuid = pane.uuid, .start_x = start_x, .start_y = start_y, .orig_x = pane.border_x, .orig_y = pane.border_y } };
}

fn beginFloatResize(state: *State, pane: *Pane, edge_mask: u8, start_x: u16, start_y: u16) void {
    state.mouse_drag = .{ .float_resize = .{ .uuid = pane.uuid, .edge_mask = edge_mask, .start_x = start_x, .start_y = start_y, .orig_x = pane.border_x, .orig_y = pane.border_y, .orig_w = pane.border_w, .orig_h = pane.border_h } };
    // Show resize info overlay
    state.overlays.showResizeInfo(pane.uuid, pane.width, pane.height, pane.border_x, pane.border_y);
}

fn updateFloatMove(state: *State, pane: *Pane, mx: u16, my: u16, drag: *const State.MouseDragFloatMove) void {
    const dx: i32 = @as(i32, @intCast(mx)) - @as(i32, @intCast(drag.start_x));
    const dy: i32 = @as(i32, @intCast(my)) - @as(i32, @intCast(drag.start_y));

    const avail_h: u16 = state.term_height - state.status_height;
    const shadow_enabled = if (pane.float_style) |s| s.shadow_color != null else false;
    const usable_w: u16 = if (shadow_enabled) (state.term_width -| 1) else state.term_width;
    const usable_h: u16 = if (shadow_enabled and state.status_height == 0) (avail_h -| 1) else avail_h;

    const outer_w: u16 = usable_w * pane.float_width_pct / 100;
    const outer_h: u16 = usable_h * pane.float_height_pct / 100;

    const max_x: u16 = usable_w -| outer_w;
    const max_y: u16 = usable_h -| outer_h;

    var outer_x: i32 = @intCast(drag.orig_x);
    var outer_y: i32 = @intCast(drag.orig_y);
    outer_x += dx;
    outer_y += dy;
    if (outer_x < 0) outer_x = 0;
    if (outer_y < 0) outer_y = 0;
    if (outer_x > @as(i32, @intCast(max_x))) outer_x = @as(i32, @intCast(max_x));
    if (outer_y > @as(i32, @intCast(max_y))) outer_y = @as(i32, @intCast(max_y));

    if (max_x > 0) {
        const xp: u32 = (@as(u32, @intCast(outer_x)) * 100) / @as(u32, max_x);
        pane.float_pos_x_pct = @intCast(@min(100, xp));
    } else {
        pane.float_pos_x_pct = 0;
    }
    if (max_y > 0) {
        const yp: u32 = (@as(u32, @intCast(outer_y)) * 100) / @as(u32, max_y);
        pane.float_pos_y_pct = @intCast(@min(100, yp));
    } else {
        pane.float_pos_y_pct = 0;
    }

    state.resizeFloatingPanes();
    state.renderer.invalidate();
    state.force_full_render = true;
    state.needs_render = true;
}

fn updateFloatResize(state: *State, pane: *Pane, mx: u16, my: u16, drag: *const State.MouseDragFloatResize) void {
    const dx: i32 = @as(i32, @intCast(mx)) - @as(i32, @intCast(drag.start_x));
    const dy: i32 = @as(i32, @intCast(my)) - @as(i32, @intCast(drag.start_y));

    var x0: i32 = @intCast(drag.orig_x);
    var y0: i32 = @intCast(drag.orig_y);
    var w0: i32 = @intCast(drag.orig_w);
    var h0: i32 = @intCast(drag.orig_h);

    // Edge mask bits: 1=left 2=right 4=top 8=bottom
    if ((drag.edge_mask & 1) != 0) {
        x0 += dx;
        w0 -= dx;
    }
    if ((drag.edge_mask & 2) != 0) {
        w0 += dx;
    }
    if ((drag.edge_mask & 4) != 0) {
        y0 += dy;
        h0 -= dy;
    }
    if ((drag.edge_mask & 8) != 0) {
        h0 += dy;
    }

    const avail_h: u16 = state.term_height - state.status_height;
    const shadow_enabled = if (pane.float_style) |s| s.shadow_color != null else false;
    const usable_w: u16 = if (shadow_enabled) (state.term_width -| 1) else state.term_width;
    const usable_h: u16 = if (shadow_enabled and state.status_height == 0) (avail_h -| 1) else avail_h;

    const min_outer_w: i32 = @intCast((@as(u16, 1) + pane.float_pad_x) * 2 + 1);
    const min_outer_h: i32 = @intCast((@as(u16, 1) + pane.float_pad_y) * 2 + 1);

    if (w0 < min_outer_w) w0 = min_outer_w;
    if (h0 < min_outer_h) h0 = min_outer_h;
    if (w0 > @as(i32, @intCast(usable_w))) w0 = @as(i32, @intCast(usable_w));
    if (h0 > @as(i32, @intCast(usable_h))) h0 = @as(i32, @intCast(usable_h));

    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;

    const max_x: i32 = @as(i32, @intCast(usable_w)) - w0;
    const max_y: i32 = @as(i32, @intCast(usable_h)) - h0;
    if (x0 > max_x) x0 = max_x;
    if (y0 > max_y) y0 = max_y;

    // Convert to percentage fields.
    const usable_w_i: i32 = @intCast(@max(usable_w, 1));
    const usable_h_i: i32 = @intCast(@max(usable_h, 1));
    pane.float_width_pct = @intCast(@max(@as(i32, 1), @divTrunc(100 * w0, usable_w_i)));
    pane.float_height_pct = @intCast(@max(@as(i32, 1), @divTrunc(100 * h0, usable_h_i)));

    const max_x_u: u16 = @intCast(@max(@as(i32, 0), max_x));
    const max_y_u: u16 = @intCast(@max(@as(i32, 0), max_y));
    if (max_x_u > 0) {
        const xp: u32 = (@as(u32, @intCast(x0)) * 100) / @as(u32, max_x_u);
        pane.float_pos_x_pct = @intCast(@min(100, xp));
    } else {
        pane.float_pos_x_pct = 0;
    }
    if (max_y_u > 0) {
        const yp: u32 = (@as(u32, @intCast(y0)) * 100) / @as(u32, max_y_u);
        pane.float_pos_y_pct = @intCast(@min(100, yp));
    } else {
        pane.float_pos_y_pct = 0;
    }

    state.resizeFloatingPanes();
    state.renderer.invalidate();
    state.force_full_render = true;
    state.needs_render = true;

    // Update resize info overlay with new dimensions
    state.overlays.showResizeInfo(pane.uuid, pane.width, pane.height, pane.border_x, pane.border_y);
}

fn copySelectionRange(state: *State, pane: *Pane, range: anytype) bool {
    state.mouse_selection.setRange(state.active_tab, pane.uuid, pane, range);
    const bytes = mouse_selection.extractText(state.allocator, pane, range) catch {
        state.notifications.showFor("Copy failed", 1200);
        state.needs_render = true;
        return true;
    };
    defer state.allocator.free(bytes);

    if (bytes.len == 0) {
        state.notifications.showFor("No text selected", 1200);
    } else {
        if (!copyTextToSystemClipboard(state, bytes)) {
            state.notifications.showFor("Clipboard copy failed", 1200);
            state.needs_render = true;
            return true;
        }
        state.notifications.showFor("Copied selection", 1200);
    }
    state.needs_render = true;
    return true;
}

fn forwardToFocusedAltPane(state: *State, ev: MouseEvent) bool {
    if (state.active_floating) |afi| {
        if (afi < state.floats.items.len and state.floats.items[afi].vt.inAltScreen()) {
            forwardMouseToPane(state.floats.items[afi], ev);
            return true;
        }
    } else if (state.currentLayout().getFocusedPane()) |p| {
        if (p.vt.inAltScreen()) {
            forwardMouseToPane(p, ev);
            return true;
        }
    }
    return false;
}

fn copyTextToSystemClipboard(state: *State, bytes: []const u8) bool {
    const stdout = std.fs.File.stdout();
    var buf: [256]u8 = undefined;
    var writer = stdout.writer(&buf);
    state.renderer.vx.copyToSystemClipboard(&writer.interface, bytes, state.allocator) catch return false;
    return true;
}

fn shapeForResizeEdge(mask: u8) vaxis.Mouse.Shape {
    const has_h = (mask & 1) != 0 or (mask & 2) != 0;
    const has_v = (mask & 4) != 0 or (mask & 8) != 0;
    if (has_h and !has_v) return .@"ew-resize";
    if (has_v and !has_h) return .@"ns-resize";
    return .@"ew-resize";
}

fn applyMouseShape(state: *State, shape: vaxis.Mouse.Shape) void {
    if (state.renderer.vx.screen.mouse_shape == shape) return;
    state.renderer.vx.setMouseShape(shape);
    state.needs_render = true;
}

pub fn resetShape(state: *State) void {
    applyMouseShape(state, .default);
}

fn desiredMouseShape(state: *State, ev: MouseEvent, override_active: bool) vaxis.Mouse.Shape {
    if (state.mouse_drag != .none) {
        return switch (state.mouse_drag) {
            .split_resize => |d| if (d.dir == .horizontal) .@"ew-resize" else .@"ns-resize",
            .float_resize => |d| shapeForResizeEdge(d.edge_mask),
            .float_move => .pointer,
            .none => .default,
        };
    }

    if (state.config.tabs.status.enabled and ev.y == state.term_height - 1) {
        return .pointer;
    }

    const target = findFocusableAt(state, ev.x, ev.y) orelse {
        if (isSplitJunction(state, ev.x, ev.y)) return .pointer;
        if (hitTestDivider(state.currentLayout(), ev.x, ev.y)) |d| {
            return if (d.dir == .horizontal) .@"ew-resize" else .@"ns-resize";
        }
        return .default;
    };

    if (target.kind == .float) {
        const fp = target.pane;
        if (float_title.hitTestTitle(fp, ev.x, ev.y)) return .pointer;

        const in_content = ev.x >= fp.x and ev.x < fp.x + fp.width and ev.y >= fp.y and ev.y < fp.y + fp.height;
        if (!in_content) {
            var mask: u8 = 0;
            if (ev.x == fp.border_x) mask |= 1;
            if (ev.x == fp.border_x + fp.border_w -| 1) mask |= 2;
            if (ev.y == fp.border_y) mask |= 4;
            if (ev.y == fp.border_y + fp.border_h -| 1) mask |= 8;
            if (mask != 0) return shapeForResizeEdge(mask);
            return .pointer;
        }
    }

    const in_content = ev.x >= target.pane.x and ev.x < target.pane.x + target.pane.width and ev.y >= target.pane.y and ev.y < target.pane.y + target.pane.height;
    if (in_content and (override_active or !target.pane.vt.inAltScreen())) return .text;
    return .default;
}

pub fn handle(state: *State, mouse: vaxis.Mouse) bool {
    const ev = encodeMouseEvent(mouse);
    const mouse_mods = mouseModsMask(ev.btn);
    const sel_override = state.config.mouse.selection_override_mods;
    const override_active = sel_override != 0 and (mouse_mods & sel_override) == sel_override;

    applyMouseShape(state, desiredMouseShape(state, ev, override_active));

    if (statusbar.updateHover(state.term_height, ev.x, ev.y)) {
        state.needs_render = true;
    }

    const is_motion = (ev.btn & 32) != 0;
    const is_wheel = (!ev.is_release) and (ev.btn & 64) != 0;
    const is_left_btn = (ev.btn & 3) == 0;

    // Cancel title rename if user clicks elsewhere.
    if (!ev.is_release and !is_motion and is_left_btn and state.float_rename_uuid != null) {
        const uuid = state.float_rename_uuid.?;
        const pane = state.findPaneByUuid(uuid);
        if (pane == null or !float_title.hitTestTitle(pane.?, ev.x, ev.y)) {
            state.clearFloatRename();
        }
    }

    // While renaming a float title, consume clicks on the title itself so
    // release events are not forwarded into the pane as raw mouse sequences.
    if (state.float_rename_uuid) |uuid| {
        if (is_left_btn) {
            if (state.findPaneByUuid(uuid)) |pane| {
                if (float_title.hitTestTitle(pane, ev.x, ev.y)) {
                    return true;
                }
            }
        }
    }

    // Handle active drag modes.
    switch (state.mouse_drag) {
        .none => {},
        .split_resize => |d| {
            if (is_wheel) return true;
            if (ev.is_release) {
                state.mouse_drag = .none;
                state.syncActiveTabLayout();
                return true;
            }
            if (!is_motion) return true;

            const rel_x: u16 = if (ev.x > d.x) ev.x - d.x else 0;
            const rel_y: u16 = if (ev.y > d.y) ev.y - d.y else 0;
            var ratio: f32 = d.split.ratio;
            if (d.dir == .horizontal and d.w > 0) {
                const off = @min(rel_x, d.w - 1);
                ratio = (@as(f32, @floatFromInt(off + 1))) / @as(f32, @floatFromInt(d.w));
            } else if (d.dir == .vertical and d.h > 0) {
                const off = @min(rel_y, d.h - 1);
                ratio = (@as(f32, @floatFromInt(off + 1))) / @as(f32, @floatFromInt(d.h));
            }
            if (ratio < 0.1) ratio = 0.1;
            if (ratio > 0.9) ratio = 0.9;
            d.split.ratio = ratio;
            state.currentLayout().recalculateLayout();
            state.renderer.invalidate();
            state.force_full_render = true;
            state.needs_render = true;
            return true;
        },
        .float_move => |d| {
            if (is_wheel) return true;
            if (ev.is_release) {
                state.mouse_drag = .none;
                if (state.findPaneByUuid(d.uuid)) |pane| {
                    state.syncSessionFloat(pane, state.active_floating != null and state.floats.items[state.active_floating.?] == pane);
                }
                return true;
            }
            if (!is_motion) return true;
            if (state.findPaneByUuid(d.uuid)) |p| {
                updateFloatMove(state, p, ev.x, ev.y, &d);
            }
            return true;
        },
        .float_resize => |d| {
            if (is_wheel) return true;
            if (ev.is_release) {
                state.mouse_drag = .none;
                state.overlays.hideResizeInfo();
                state.needs_render = true;
                if (state.findPaneByUuid(d.uuid)) |pane| {
                    state.syncSessionFloat(pane, state.active_floating != null and state.floats.items[state.active_floating.?] == pane);
                }
                return true;
            }
            if (!is_motion) return true;
            if (state.findPaneByUuid(d.uuid)) |p| {
                updateFloatResize(state, p, ev.x, ev.y, &d);
            }
            return true;
        },
    }

    // Selection: if a mux selection is currently active, consume drag/release
    // regardless of where the pointer is.
    if (state.mouse_selection.active) {
        if (state.mouse_selection.pane_uuid) |uuid| {
            if (state.mouse_selection.tab) |tab_idx| {
                if (tab_idx == state.active_tab) {
                    if (state.findPaneByUuid(uuid)) |sel_pane| {
                        const local = toLocalClamped(sel_pane, ev.x, ev.y);

                        if (!ev.is_release and is_motion and is_left_btn and !is_wheel) {
                            state.mouse_selection.update(sel_pane, local.x, local.y);
                            state.needs_render = true;
                            return true;
                        }

                        if (ev.is_release) {
                            state.mouse_selection.update(sel_pane, local.x, local.y);
                            state.mouse_selection.finish();
                            if (state.mouse_selection.bufRangeForPane(state.active_tab, sel_pane)) |range| {
                                const bytes = mouse_selection.extractText(state.allocator, sel_pane, range) catch {
                                    state.notifications.showFor("Copy failed", 1200);
                                    state.needs_render = true;
                                    return true;
                                };
                                defer state.allocator.free(bytes);
                                if (bytes.len == 0) {
                                    state.notifications.showFor("No text selected", 1200);
                                } else {
                                    if (!copyTextToSystemClipboard(state, bytes)) {
                                        state.notifications.showFor("Clipboard copy failed", 1200);
                                        state.needs_render = true;
                                        return true;
                                    }
                                    state.notifications.showFor("Copied selection", 1200);
                                }
                            }
                            state.needs_render = true;
                            return true;
                        }
                    } else {
                        state.mouse_selection.clear();
                    }
                } else {
                    state.mouse_selection.clear();
                }
            }
        }
    }

    // Status bar tab switching (only on press).
    if (!ev.is_release and state.config.tabs.status.enabled and ev.y == state.term_height - 1) {
        if (statusbar.hitTestTab(state.allocator, &state.config, state.term_width, state.term_height, state.tabs, state.active_tab, state.sessionName(), ev.x, ev.y)) |ti| {
            if (ti != state.active_tab) {
                @import("tab_switch.zig").switchToTab(state, ti);
            }
            return true;
        }

        if (statusbar.hitTestAction(
            state,
            state.allocator,
            &state.config,
            state.term_width,
            state.term_height,
            state.tabs,
            state.active_tab,
            state.sessionName(),
            ev.x,
            ev.y,
            @intCast(ev.btn & 3),
        )) |cmd| {
            runStatusbarAction(state, cmd);
            return true;
        }
    }

    const target = findFocusableAt(state, ev.x, ev.y);
    const forward_to_app = if (target) |t| t.pane.vt.inAltScreen() else false;

    // Wheel scroll.
    if (is_wheel) {
        const wheel_dir = ev.btn & 3;
        if (target) |t| {
            const selection_owns = (state.mouse_selection.pane_uuid != null and std.mem.eql(u8, &state.mouse_selection.pane_uuid.?, &t.pane.uuid)) and (state.mouse_selection.active or state.mouse_selection.has_range);
            const use_mux_scroll = !forward_to_app or override_active or selection_owns;
            if (!use_mux_scroll) {
                forwardMouseToPane(t.pane, ev);
            } else {
                if (wheel_dir == 0) {
                    t.pane.scrollUp(3);
                } else if (wheel_dir == 1) {
                    t.pane.scrollDown(3);
                }

                if (state.mouse_selection.active and state.mouse_selection.pane_uuid != null and std.mem.eql(u8, &state.mouse_selection.pane_uuid.?, &t.pane.uuid)) {
                    state.mouse_selection.update(t.pane, state.mouse_selection.last_local.x, state.mouse_selection.last_local.y);
                }
                state.needs_render = true;
            }
        } else {
            if (state.active_floating) |afi| {
                if (afi < state.floats.items.len) {
                    forwardMouseToPane(state.floats.items[afi], ev);
                }
            } else if (state.currentLayout().getFocusedPane()) |p| {
                forwardMouseToPane(p, ev);
            }
        }
        return true;
    }

    // Left button press: split-divider resize, float move/resize/title rename, focus, selection.
    if (!ev.is_release and !is_motion and is_left_btn) {
        // Split divider drag starts only when click isn't inside a pane.
        if (target == null and !isSplitJunction(state, ev.x, ev.y)) {
            if (hitTestDivider(state.currentLayout(), ev.x, ev.y)) |hit| {
                state.mouse_drag = .{ .split_resize = hit };
                return true;
            }
        }

        if (target) |t| {
            focusTarget(state, t);

            // Float border interactions.
            if (t.kind == .float) {
                const fp = t.pane;
                const in_content = ev.x >= fp.x and ev.x < fp.x + fp.width and ev.y >= fp.y and ev.y < fp.y + fp.height;

                // Title move/rename (only if title exists and click is on it).
                if (float_title.hitTestTitle(fp, ev.x, ev.y)) {
                    // Double-click title: begin rename in-place.
                    const now_ms = std.time.milliTimestamp();
                    const same = state.mouse_title_last_uuid != null and std.mem.eql(u8, &state.mouse_title_last_uuid.?, &fp.uuid);
                    const within_time = now_ms - state.mouse_title_last_ms <= 400;
                    const within_dist = absDiffU16(ev.x, state.mouse_title_last_x) <= 1 and absDiffU16(ev.y, state.mouse_title_last_y) <= 1;
                    var count: u8 = 1;
                    if (same and within_time and within_dist) {
                        count = @min(@as(u8, 2), state.mouse_title_click_count + 1);
                    }
                    state.mouse_title_last_ms = now_ms;
                    state.mouse_title_click_count = count;
                    state.mouse_title_last_uuid = fp.uuid;
                    state.mouse_title_last_x = ev.x;
                    state.mouse_title_last_y = ev.y;

                    if (count == 2) {
                        state.beginFloatRename(fp);
                        return true;
                    }

                    beginFloatMove(state, fp, ev.x, ev.y);
                    return true;
                }

                // Border resize drag.
                if (!in_content) {
                    // Identify which edge/corner.
                    var mask: u8 = 0;
                    if (ev.x == fp.border_x) mask |= 1;
                    if (ev.x == fp.border_x + fp.border_w -| 1) mask |= 2;
                    if (ev.y == fp.border_y) mask |= 4;
                    if (ev.y == fp.border_y + fp.border_h -| 1) mask |= 8;

                    if (mask != 0) {
                        beginFloatResize(state, fp, mask, ev.x, ev.y);
                        return true;
                    }
                }
            }

            const in_content = ev.x >= t.pane.x and ev.x < t.pane.x + t.pane.width and ev.y >= t.pane.y and ev.y < t.pane.y + t.pane.height;
            const use_mux_selection = in_content and (override_active or !t.pane.vt.inAltScreen());

            if (!use_mux_selection and (state.mouse_selection.has_range or state.mouse_selection.active)) {
                state.mouse_selection.clear();
                state.needs_render = true;
            }

            if (use_mux_selection) {
                const local = toLocalClamped(t.pane, ev.x, ev.y);

                const now_ms = std.time.milliTimestamp();
                const same_pane = state.mouse_click_last_pane_uuid != null and std.mem.eql(u8, &state.mouse_click_last_pane_uuid.?, &t.pane.uuid);
                const within_time = now_ms - state.mouse_click_last_ms <= 400;
                const within_dist = absDiffU16(local.x, state.mouse_click_last_x) <= 1 and absDiffU16(local.y, state.mouse_click_last_y) <= 1;

                var click_count: u8 = 1;
                if (same_pane and within_time and within_dist) {
                    click_count = @min(@as(u8, 4), state.mouse_click_count + 1);
                }
                state.mouse_click_last_ms = now_ms;
                state.mouse_click_count = click_count;
                state.mouse_click_last_pane_uuid = t.pane.uuid;
                state.mouse_click_last_x = local.x;
                state.mouse_click_last_y = local.y;

                if (click_count == 2) {
                    // Double-click: select word (stops at separators)
                    if (mouse_selection.selectWordRange(t.pane, local.x, local.y)) |range| {
                        return copySelectionRange(state, t.pane, range);
                    }
                } else if (click_count == 3) {
                    // Triple-click: select word including adjacent separators
                    if (mouse_selection.selectWordWithSeparatorsRange(t.pane, local.x, local.y)) |range| {
                        return copySelectionRange(state, t.pane, range);
                    }
                } else if (click_count == 4) {
                    // Quad-click: select entire line
                    if (mouse_selection.selectLineRange(t.pane, local.x, local.y)) |range| {
                        return copySelectionRange(state, t.pane, range);
                    }
                }

                state.mouse_selection.begin(state.active_tab, t.pane.uuid, t.pane, local.x, local.y);
                state.needs_render = true;
            } else if (forward_to_app) {
                forwardMouseToPane(t.pane, ev);
            }
        } else {
            if (state.mouse_selection.has_range or state.mouse_selection.active) {
                state.mouse_selection.clear();
                state.needs_render = true;
            }
            _ = forwardToFocusedAltPane(state, ev);
        }

        return true;
    }

    // Other mouse events (including release): forward only when target is in alt-screen.
    if (target) |t| {
        if (forward_to_app) {
            forwardMouseToPane(t.pane, ev);
            return true;
        }
    } else if (forwardToFocusedAltPane(state, ev)) {
        return true;
    }

    return true;
}
