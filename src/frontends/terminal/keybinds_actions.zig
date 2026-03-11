const std = @import("std");
const core = @import("core");

const layout_mod = @import("layout.zig");
const actions = @import("loop_actions.zig");
const focus_move = @import("focus_move.zig");
const mouse_selection = @import("mouse_selection.zig");

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;

const BindAction = core.Config.BindAction;

pub fn dispatchAction(state: *State, action: BindAction) bool {
    const cfg = &state.config;

    switch (action) {
        .mux_quit => {
            if (cfg.confirm_on_exit) {
                state.pending_action = .exit;
                state.popups.showConfirm("Exit mux?", .{}) catch {};
                state.needs_render = true;
            } else {
                state.running = false;
            }
            return true;
        },
        .pane_disown => {
            const current_pane: ?*Pane = if (state.activeFloatingIndex()) |idx|
                state.view.floats.items[idx]
            else
                state.currentLayout().getFocusedPane();

            if (current_pane) |p| {
                if (p.sticky) {
                    state.notifications.show("Cannot disown sticky float");
                    state.needs_render = true;
                    return true;
                }
            }

            if (cfg.confirm_on_disown) {
                state.pending_action = .disown;
                state.popups.showConfirm("Disown pane?", .{}) catch {};
                state.needs_render = true;
            } else {
                actions.performDisown(state);
            }
            return true;
        },
        .pane_adopt => {
            actions.startAdoptFlow(state);
            return true;
        },
        .pane_select_mode => {
            actions.enterPaneSelectMode(state, false);
            return true;
        },
        .clipboard_copy => {
            const pane: ?*Pane = if (state.activeFloatingIndex()) |idx|
                state.view.floats.items[idx]
            else
                state.currentLayout().getFocusedPane();

            const p = pane orelse {
                state.notifications.showFor("No focused pane", 1200);
                state.needs_render = true;
                return true;
            };

            const range = state.mouse_selection.bufRangeForPane(state.activeTabIndex(), p) orelse {
                state.notifications.showFor("No text selected", 1200);
                state.needs_render = true;
                return true;
            };

            const bytes = mouse_selection.extractText(state.allocator, p, range) catch {
                state.notifications.showFor("Copy failed", 1200);
                state.needs_render = true;
                return true;
            };
            defer state.allocator.free(bytes);

            if (bytes.len == 0) {
                state.notifications.showFor("No text selected", 1200);
                state.needs_render = true;
                return true;
            }

            const stdout = std.fs.File.stdout();
            var io_buf: [256]u8 = undefined;
            var writer = stdout.writer(&io_buf);
            state.renderer.vx.copyToSystemClipboard(&writer.interface, bytes, state.allocator) catch {
                state.notifications.showFor("Clipboard copy failed", 1200);
                state.needs_render = true;
                return true;
            };

            state.notifications.showFor("Copied selection", 1200);
            state.needs_render = true;
            return true;
        },
        .clipboard_request => {
            const stdout = std.fs.File.stdout();
            var buf: [256]u8 = undefined;
            var writer = stdout.writer(&buf);
            state.renderer.vx.requestSystemClipboard(&writer.interface) catch {
                state.notifications.showFor("Clipboard request failed", 1200);
                state.needs_render = true;
                return true;
            };
            state.notifications.showFor("Requested clipboard", 900);
            state.needs_render = true;
            return true;
        },
        .system_notify => {
            const stdout = std.fs.File.stdout();
            var io_buf: [512]u8 = undefined;
            var writer = stdout.writer(&io_buf);

            const body = if (state.view.tabs.items.len > 0 and state.activeTabIndex() < state.view.tabs.items.len)
                state.tabName(state.activeTabIndex())
            else
                "hexe";

            state.renderer.vx.notify(&writer.interface, "hexe", body) catch {
                state.notifications.showFor("Notification send failed", 1200);
                state.needs_render = true;
                return true;
            };
            state.notifications.showFor("Notification sent", 900);
            state.needs_render = true;
            return true;
        },
        .keycast_toggle => {
            state.overlays.toggleKeycast();
            state.needs_render = true;
            return true;
        },
        .sprite_toggle => {
            // Toggle sprite on the focused pane - use the pane's actual Pokemon name!
            if (state.activeFloatingIndex()) |idx| {
                if (idx < state.view.floats.items.len) {
                    const pane = state.view.floats.items[idx];
                    if (pane.pokemon_initialized) {
                        if (pane.pokemon_state.show_sprite) {
                            pane.pokemon_state.hide();
                        } else {
                            // Get the pane's Pokemon name from pane_names cache
                            const pokemon_name = state.paneName(pane.uuid) orelse "pikachu";

                            pane.pokemon_state.loadSprite(pokemon_name, false) catch {
                                // Fallback to pikachu if loading fails
                                pane.pokemon_state.loadSprite("pikachu", false) catch {};
                            };
                        }
                        state.needs_render = true;
                    }
                }
            } else if (state.currentLayout().getFocusedPane()) |pane| {
                if (pane.pokemon_initialized) {
                    if (pane.pokemon_state.show_sprite) {
                        pane.pokemon_state.hide();
                    } else {
                        // Get the pane's Pokemon name from pane_names cache
                        const pokemon_name = state.paneName(pane.uuid) orelse "pikachu";

                        pane.pokemon_state.loadSprite(pokemon_name, false) catch {
                            pane.pokemon_state.loadSprite("pikachu", false) catch {};
                        };
                    }
                    state.needs_render = true;
                }
            }
            return true;
        },
        .split_h => {
            // Prevent split creation during detach (race prevention)
            if (state.isDetachMode()) {
                return true; // Silently ignore during detach
            }
            const parent_uuid = state.getCurrentFocusedUuid();
            var cwd: ?[]const u8 = null;
            if (state.currentLayout().getFocusedPane()) |p| {
                cwd = state.getReliableCwd(p);
            }
            // Fallback to mux's CWD if pane CWD unavailable
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (cwd == null) {
                cwd = std.posix.getcwd(&cwd_buf) catch null;
            }
            if (state.currentLayout().splitFocused(.horizontal, cwd) catch null) |new_pane| {
                state.syncPaneAux(new_pane, parent_uuid);
            }
            state.needs_render = true;
            state.syncActiveTabLayout();
            return true;
        },
        .split_v => {
            // Prevent split creation during detach (race prevention)
            if (state.isDetachMode()) {
                return true; // Silently ignore during detach
            }
            const parent_uuid = state.getCurrentFocusedUuid();
            var cwd: ?[]const u8 = null;
            if (state.currentLayout().getFocusedPane()) |p| {
                cwd = state.getReliableCwd(p);
            }
            // Fallback to mux's CWD if pane CWD unavailable
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (cwd == null) {
                cwd = std.posix.getcwd(&cwd_buf) catch null;
            }
            if (state.currentLayout().splitFocused(.vertical, cwd) catch null) |new_pane| {
                state.syncPaneAux(new_pane, parent_uuid);
            }
            state.needs_render = true;
            state.syncActiveTabLayout();
            return true;
        },
        .split_resize => |dir_kind| {
            // Only applies to split panes (floats should ignore).
            if (state.activeFloatingIndex() != null) return true;
            const dir: ?layout_mod.Layout.Direction = switch (dir_kind) {
                .up => .up,
                .down => .down,
                .left => .left,
                .right => .right,
                else => null,
            };
            if (dir == null) return true;
            if (state.currentLayout().resizeFocused(dir.?, 1)) {
                state.needs_render = true;
                state.renderer.invalidate();
                state.force_full_render = true;
                state.syncActiveTabLayout();
            }
            return true;
        },
        .tab_new => {
            // Prevent tab creation during detach (race prevention)
            if (state.isDetachMode()) {
                return true; // Silently ignore during detach
            }
            state.setActiveFloatingIndex(null);
            state.createTab() catch |e| {
                core.logging.logError("mux", "createTab failed", e);
            };
            state.needs_render = true;
            return true;
        },
        .tab_next => {
            actions.switchToNextTab(state);
            return true;
        },
        .tab_prev => {
            actions.switchToPrevTab(state);
            return true;
        },
        .pane_close => {
            // Close float or split pane, but never the tab.
            if (state.activeFloatingIndex() != null) {
                // Close the focused float.
                if (cfg.confirm_on_close) {
                    state.pending_action = .close;
                    state.popups.showConfirm("Close float?", .{}) catch {};
                    state.needs_render = true;
                } else {
                    actions.performClose(state);
                }
            } else {
                // Close split pane if there are multiple splits.
                const layout = state.currentLayout();
                if (layout.splitCount() > 1) {
                    if (cfg.confirm_on_close) {
                        state.pending_action = .pane_close;
                        state.popups.showConfirm("Close pane?", .{}) catch {};
                        state.needs_render = true;
                    } else {
                        _ = layout.closePane(layout.focused_split_id);
                        if (layout.getFocusedPane()) |new_pane| {
                            state.syncPaneFocus(new_pane, null);
                        }
                        state.syncActiveTabLayout();
                        state.needs_render = true;
                    }
                }
                // If only one pane, do nothing (don't close the tab).
            }
            return true;
        },
        .tab_close => {
            if (cfg.confirm_on_close) {
                state.pending_action = .close;
                const msg = if (state.activeFloatingIndex() != null) "Close float?" else "Close tab?";
                state.popups.showConfirm(msg, .{}) catch {};
                state.needs_render = true;
            } else {
                actions.performClose(state);
            }
            return true;
        },
        .mux_detach => {
            if (cfg.confirm_on_detach) {
                state.pending_action = .detach;
                state.popups.showConfirm("Detach session?", .{}) catch {};
                state.needs_render = true;
                return true;
            }
            actions.performDetach(state);
            return true;
        },
        .float_toggle => |fk| {
            if (state.getLayoutFloatByKey(fk)) |float_def| {
                actions.toggleNamedFloat(state, float_def);
                state.needs_render = true;
                return true;
            }
            return false;
        },
        .float_nudge => |dir_kind| {
            const dir: ?layout_mod.Layout.Direction = switch (dir_kind) {
                .up => .up,
                .down => .down,
                .left => .left,
                .right => .right,
                else => null,
            };
            if (dir == null) return false;
            const fi = state.activeFloatingIndex() orelse return false;
            if (fi >= state.view.floats.items.len) return false;
            const pane = state.view.floats.items[fi];
            if (pane.parent_tab) |parent| {
                if (parent != state.activeTabIndex()) return false;
            }

            nudgeFloat(state, pane, dir.?, 1);
            state.needs_render = true;
            return true;
        },
        .focus_move => |dir_kind| {
            const dir: ?layout_mod.Layout.Direction = switch (dir_kind) {
                .up => .up,
                .down => .down,
                .left => .left,
                .right => .right,
                else => null,
            };
            if (dir) |d| return focus_move.perform(state, d);
            return true;
        },
        .layout_save => {
            var items = std.ArrayList([]const u8).empty;
            defer items.deinit(state.allocator);

            const local_item = state.allocator.dupe(u8, "local") catch return true;
            const global_item = state.allocator.dupe(u8, "global") catch {
                state.allocator.free(local_item);
                return true;
            };
            const both_item = state.allocator.dupe(u8, "both") catch {
                state.allocator.free(local_item);
                state.allocator.free(global_item);
                return true;
            };

            items.append(state.allocator, local_item) catch {
                state.allocator.free(local_item);
                state.allocator.free(global_item);
                state.allocator.free(both_item);
                return true;
            };
            items.append(state.allocator, global_item) catch {
                state.allocator.free(global_item);
                state.allocator.free(both_item);
                return true;
            };
            items.append(state.allocator, both_item) catch {
                state.allocator.free(both_item);
                return true;
            };

            state.popups.showPickerOwned(items.items, .{ .title = "Save layout scope" }) catch {
                for (items.items) |item| state.allocator.free(item);
                return true;
            };
            state.pending_action = .layout_save_choose;
            state.needs_render = true;
            return true;
        },
        .layout_load => {
            if (std.fs.cwd().access(".hexe.lua", .{})) |_| {} else |_| {
                state.notifications.showFor("No local .hexe.lua", 1400);
                state.needs_render = true;
                return true;
            }

            var items = std.ArrayList([]const u8).empty;
            defer items.deinit(state.allocator);

            const detach_item = state.allocator.dupe(u8, "detach") catch return true;
            const replace_item = state.allocator.dupe(u8, "replace") catch {
                state.allocator.free(detach_item);
                return true;
            };

            items.append(state.allocator, detach_item) catch {
                state.allocator.free(detach_item);
                state.allocator.free(replace_item);
                return true;
            };
            items.append(state.allocator, replace_item) catch {
                state.allocator.free(replace_item);
                return true;
            };

            state.popups.showPickerOwned(items.items, .{ .title = "Load local layout: detach or replace" }) catch {
                for (items.items) |item| state.allocator.free(item);
                return true;
            };
            state.pending_action = .layout_load_choose;
            state.needs_render = true;
            return true;
        },
    }
}

fn nudgeFloat(state: *State, pane: *Pane, dir: layout_mod.Layout.Direction, step_cells: u16) void {
    const avail_h: u16 = state.term_height - state.status_height;

    const shadow_enabled = if (pane.float_style) |s| s.shadow_color != null else false;
    const usable_w: u16 = if (shadow_enabled) (state.term_width -| 1) else state.term_width;
    const usable_h: u16 = if (shadow_enabled and state.status_height == 0) (avail_h -| 1) else avail_h;

    const outer_w: u16 = usable_w * pane.float_width_pct / 100;
    const outer_h: u16 = usable_h * pane.float_height_pct / 100;

    const max_x: u16 = usable_w -| outer_w;
    const max_y: u16 = usable_h -| outer_h;

    var outer_x: i32 = @intCast(pane.border_x);
    var outer_y: i32 = @intCast(pane.border_y);
    const dx: i32 = switch (dir) {
        .left => -@as(i32, @intCast(step_cells)),
        .right => @as(i32, @intCast(step_cells)),
        else => 0,
    };
    const dy: i32 = switch (dir) {
        .up => -@as(i32, @intCast(step_cells)),
        .down => @as(i32, @intCast(step_cells)),
        else => 0,
    };

    outer_x += dx;
    outer_y += dy;

    if (outer_x < 0) outer_x = 0;
    if (outer_y < 0) outer_y = 0;
    if (outer_x > @as(i32, @intCast(max_x))) outer_x = @as(i32, @intCast(max_x));
    if (outer_y > @as(i32, @intCast(max_y))) outer_y = @as(i32, @intCast(max_y));

    // Convert back to percentage (stable across resizes).
    if (max_x > 0) {
        const xp: u32 = (@as(u32, @intCast(outer_x)) * 100) / @as(u32, max_x);
        pane.float_pos_x_pct = @intCast(@min(100, xp));
    }
    if (max_y > 0) {
        const yp: u32 = (@as(u32, @intCast(outer_y)) * 100) / @as(u32, max_y);
        pane.float_pos_y_pct = @intCast(@min(100, yp));
    }

    state.resizeFloatingPanes();
}
