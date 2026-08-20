const std = @import("std");
const core = @import("core");
const frontend_core = @import("frontend_core");

const layout_mod = @import("layout.zig");
const actions = @import("loop_actions.zig");
const focus_move = @import("focus_move.zig");
const mouse_selection = @import("mouse_selection.zig");
const prompt_navigation = @import("prompt_navigation.zig");
const statusbar = @import("statusbar.zig");

const state_mod = @import("state.zig");
const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;

const BindAction = core.Config.BindAction;
const lua_api = @import("lua_api.zig");
const float_geometry = @import("float_geometry.zig");

/// Run a keybinding whose action is a Lua function.
///
/// Same invocation shape as a `when` predicate: the live query API is published
/// for the duration of the call and revoked after, so the callback can inspect
/// the session and act on it, and cannot retain a pointer past the call.
fn runLuaAction(state: *State, code: []const u8) bool {
    const rt = state.config._lua_runtime orelse return false;
    const callback_id = std.fmt.parseInt(
        i32,
        if (std.mem.startsWith(u8, code, "__hexe_cb_ref:")) code["__hexe_cb_ref:".len..] else return false,
        10,
    ) catch return false;

    const scope = lua_api.pushLiveState(rt, state, .handler);
    defer lua_api.popLiveState(rt, scope);

    if (!core.lua_runtime.pushRegisteredCallback(rt, callback_id)) return false;
    if (!lua_api.pushCallbackContext(rt)) {
        rt.lua.pop(2);
        return false;
    }
    rt.lua.protectedCall(.{ .args = 1, .results = 0 }) catch {
        core.logging.warn("terminal", "keybind Lua action raised an error", .{});
        rt.lua.pop(2);
        return true;
    };
    rt.lua.pop(1); // callback table
    state.needs_render = true;
    return true;
}

fn layoutDirectionFromCore(direction: frontend_core.Direction) layout_mod.Layout.Direction {
    return switch (direction) {
        .up => .up,
        .down => .down,
        .left => .left,
        .right => .right,
    };
}

fn focusedPane(state: *State) ?*Pane {
    if (state.activeFloatingIndex()) |index| {
        if (index < state.view.float_views.items.len) return state.view.float_views.items[index];
        return null;
    }
    return state.currentLayout().getFocusedPane();
}

/// Roll widgets.pokemon.shiny_chance for a freshly shown sprite.
fn rollShiny(state: *State) bool {
    const chance = state.pop_config.widgets.pokemon.shiny_chance;
    if (chance <= 0) return false;
    if (chance >= 1) return true;
    return std.crypto.random.float(f32) < chance;
}

pub fn dispatchAction(state: *State, action: BindAction) bool {
    const cfg = &state.config;

    // A Lua action is handled here, before the shared mapping: it runs in this
    // frontend's Lua runtime and has no shared-view representation.
    if (action == .lua) return runLuaAction(state, action.lua);

    const request = frontend_core.actionRequestFromBindAction(action);

    switch (request) {
        .frontend_local => return false,
        .mux_quit => {
            if (cfg.confirm_on_exit) {
                _ = state.showConfirmOrNotify(.exit, "Exit terminal session?");
            } else {
                state.running = false;
            }
            return true;
        },
        .pane_disown => {
            const current_pane: ?*Pane = if (state.activeFloatingIndex()) |idx|
                state.view.float_views.items[idx]
            else
                state.currentLayout().getFocusedPane();

            if (current_pane) |p| {
                if (state.paneSticky(p)) {
                    state.notifications.show("Cannot disown sticky float");
                    state.needs_render = true;
                    return true;
                }
            }

            if (cfg.confirm_on_disown) {
                _ = state.showConfirmOrNotify(.disown, "Disown pane?");
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
        .host_surface => |host_action| return dispatchHostSurfaceAction(state, host_action),
        .tab_select,
        .tab_remove,
        .float_select,
        .focus_set,
        .tab_focus_set,
        => return false,
        .split_h => {
            // Prevent split creation during detach (race prevention)
            if (state.isDetachMode()) {
                return true; // Silently ignore during detach
            }
            state.dropZoom();
            const parent_pane = state.currentLayout().getFocusedPane() orelse {
                core.logging.warn("terminal", "split_h skipped: no focused pane", .{});
                return true;
            };
            const parent_uuid = parent_pane.uuid;
            var cwd: ?[]const u8 = null;
            if (state.currentLayout().getFocusedPane()) |p| {
                cwd = state.getReliableCwd(p);
            }
            // Fallback to the terminal process CWD if pane CWD is unavailable.
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (cwd == null) {
                cwd = std.posix.getcwd(&cwd_buf) catch |err| blk: {
                    core.logging.logError("terminal", "split_h: failed to get fallback cwd", err);
                    break :blk null;
                };
            }
            const new_pane = state.currentLayout().splitFocused(.horizontal, cwd) catch |err| blk: {
                core.logging.logError("terminal", "split_h failed to create pane", err);
                state.notifications.show("Split failed: pane creation error");
                break :blk null;
            };
            if (new_pane) |pane| {
                if (state.syncSessionSplitPaneChecked(parent_uuid, pane.uuid, .horizontal, pane.uuid)) {
                    state.syncPaneAux(pane, parent_uuid);
                } else {
                    _ = state.currentLayout().closePane(pane.uuid);
                    state.notifications.show("Split failed: session sync rejected pane");
                }
            }
            state.needs_render = true;
            return true;
        },
        .split_v => {
            // Prevent split creation during detach (race prevention)
            if (state.isDetachMode()) {
                return true; // Silently ignore during detach
            }
            state.dropZoom();
            const parent_pane = state.currentLayout().getFocusedPane() orelse {
                core.logging.warn("terminal", "split_v skipped: no focused pane", .{});
                return true;
            };
            const parent_uuid = parent_pane.uuid;
            var cwd: ?[]const u8 = null;
            if (state.currentLayout().getFocusedPane()) |p| {
                cwd = state.getReliableCwd(p);
            }
            // Fallback to the terminal process CWD if pane CWD is unavailable.
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (cwd == null) {
                cwd = std.posix.getcwd(&cwd_buf) catch |err| blk: {
                    core.logging.logError("terminal", "split_v: failed to get fallback cwd", err);
                    break :blk null;
                };
            }
            const new_pane = state.currentLayout().splitFocused(.vertical, cwd) catch |err| blk: {
                core.logging.logError("terminal", "split_v failed to create pane", err);
                state.notifications.show("Split failed: pane creation error");
                break :blk null;
            };
            if (new_pane) |pane| {
                if (state.syncSessionSplitPaneChecked(parent_uuid, pane.uuid, .vertical, pane.uuid)) {
                    state.syncPaneAux(pane, parent_uuid);
                } else {
                    _ = state.currentLayout().closePane(pane.uuid);
                    state.notifications.show("Split failed: session sync rejected pane");
                }
            }
            state.needs_render = true;
            return true;
        },
        .split_resize => |dir| {
            // Only applies to split panes (floats should ignore).
            if (state.activeFloatingIndex() != null) return true;
            const shared_sync = state.applyFrontendSplitResize(dir, 1);
            if (state.currentLayout().resizeFocused(layoutDirectionFromCore(dir), 1)) |sync| {
                state.needs_render = true;
                state.renderer.invalidate();
                state.force_full_render = true;
                const sync_to_send: frontend_core.SplitRatioChange = shared_sync orelse .{
                    .first_anchor_uuid = sync.first_anchor_uuid,
                    .second_anchor_uuid = sync.second_anchor_uuid,
                    .ratio = sync.ratio,
                };
                state.syncSessionSplitRatio(sync_to_send.first_anchor_uuid, sync_to_send.second_anchor_uuid, sync_to_send.ratio);
            } else if (shared_sync != null) {
                // The shared projection should mirror the terminal tree. If it
                // could resize but the terminal presentation could not, throw
                // away the optimistic shared mutation and wait for the next
                // authoritative snapshot/runtime refresh.
                state.refreshFrontendView();
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
                core.logging.logError("terminal", "createTab failed", e);
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
            state.dropZoom();
            // Close float or split pane, but never the tab.
            if (state.activeFloatingIndex() != null) {
                // Close the focused float.
                if (cfg.confirm_on_close) {
                    _ = state.showConfirmOrNotify(.close, "Close float?");
                } else {
                    actions.performClose(state);
                }
            } else {
                // Close split pane if there are multiple splits.
                const layout = state.currentLayout();
                if (layout.splitCount() > 1) {
                    if (cfg.confirm_on_close) {
                        _ = state.showConfirmOrNotify(.pane_close, "Close pane?");
                    } else {
                        const closing_pane = layout.getFocusedPane().?;
                        const closing_uuid = closing_pane.uuid;
                        state.runtime.killPane(closing_uuid) catch |err| {
                            core.logging.logError("terminal", "killPane failed before split close", err);
                            state.notifications.show("Close pane failed: session rejected pane kill");
                            state.needs_render = true;
                            return true;
                        };
                        state.clearTransientPaneState(closing_pane);
                        _ = layout.closePaneLocal(closing_uuid);
                        if (layout.getFocusedPane()) |new_pane| {
                            state.applyFrontendPaneRemoved(closing_uuid, new_pane.uuid);
                            state.syncPaneFocus(new_pane, null);
                        } else {
                            state.applyFrontendPaneRemoved(closing_uuid, null);
                        }
                        state.needs_render = true;
                    }
                }
                // If only one pane, do nothing (don't close the tab).
            }
            return true;
        },
        .tab_close => {
            if (cfg.confirm_on_close) {
                const msg = if (state.activeFloatingIndex() != null) "Close float?" else "Close tab?";
                _ = state.showConfirmOrNotify(.close, msg);
            } else {
                actions.performClose(state);
            }
            return true;
        },
        .mux_detach => {
            if (cfg.confirm_on_detach) {
                _ = state.showConfirmOrNotify(.detach, "Detach session?");
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
        .float_nudge => |dir| {
            const fi = state.activeFloatingIndex() orelse {
                core.logging.warn("terminal", "float_nudge skipped: no active float", .{});
                return false;
            };
            if (fi >= state.view.float_views.items.len) {
                core.logging.warn("terminal", "float_nudge skipped: active float index is out of range", .{});
                return false;
            }
            const pane = state.view.float_views.items[fi];
            if (state.paneParentTab(pane)) |parent| {
                if (parent != state.activeTabIndex()) {
                    core.logging.warn("terminal", "float_nudge skipped: active float belongs to another tab", .{});
                    return false;
                }
            }

            nudgeFloat(state, pane, layoutDirectionFromCore(dir), 1);
            if (!state.syncSessionFloatChecked(pane, true)) {
                if (state.paneSticky(pane) or state.paneIsPwd(pane)) {
                    core.logging.warn("terminal", "float_nudge: shared sticky/per-CWD float sync rejected; kept local nudge", .{});
                } else {
                    state.notifications.show("Nudge float failed: session sync rejected update");
                }
            }
            state.needs_render = true;
            return true;
        },
        .focus_move => |dir| {
            state.clearZoom();
            return focus_move.perform(state, layoutDirectionFromCore(dir));
        },
        .layout_save => {
            _ = state.showPickerOrNotify(
                .layout_save_choose,
                &.{ "local", "global", "both" },
                "Save layout scope",
            );
            return true;
        },
        .layout_load => {
            if (std.fs.cwd().access(".hexe.lua", .{})) |_| {} else |_| {
                state.notifications.showFor("No local .hexe.lua", 1400);
                state.needs_render = true;
                return true;
            }

            _ = state.showPickerOrNotify(
                .layout_load_choose,
                &.{ "detach", "replace" },
                "Load local layout: detach or replace",
            );
            return true;
        },
        .invalid_direction => return true,
    }
}

/// Re-read the Lua config and hot-swap it into the running frontend.
///
/// Safe because: keybinds, segments and border styling all read `state.config`
/// live each frame; the only long-lived holders of the old config's Lua runtime
/// are the statusbar threadlocal caches (cleared here via `deinitThreadlocals`),
/// and no pane/float caches a pointer into `config`. On a parse error we keep
/// the current config rather than clobber a working one with defaults.
/// Push `hexe.palette` to every live pane. Reaching panes that already exist
/// is the point: turning namespaces on and reloading should light up the
/// session you are looking at, not only panes opened afterwards.
fn applyPaletteConfig(state: *State) void {
    core.palette.default_enabled = state.config.palette_namespaces;
    core.palette.default_osc = state.config.palette_osc;
    for (state.view.tab_views.items) |*tab| {
        var it = tab.layout.splitIterator();
        while (it.next()) |p| p.*.vt.ns_table.applyDefaults();
    }
    for (state.view.float_views.items) |p| p.vt.ns_table.applyDefaults();
}

fn performConfigReload(state: *State) void {
    var new_config = core.Config.load(state.allocator);
    if (new_config.status == .@"error") {
        state.notifications.showFor("Config reload failed — kept current config", 1800);
        new_config.deinit();
        state.needs_render = true;
        return;
    }
    // Drop every cache/threadlocal that holds a reference into the old runtime
    // before we free it.
    statusbar.deinitThreadlocals();
    // Reload the SES-side config too. `state.ses_config` holds the layouts and
    // `state.active_layout_floats` the resolved float definitions; neither was
    // refreshed, so editing a float and reloading did nothing (and leaked the
    // previous resolution).
    var new_ses = core.SesConfig.load(state.allocator);
    const new_floats = state_mod.resolveLayoutFloats(state.allocator, &new_config, &new_ses);

    var old = state.config;
    state.config = new_config;
    state.applyDecorInsets();
    old.deinit();

    if (state.active_layout_floats.len > 0) state.allocator.free(state.active_layout_floats);
    state.active_layout_floats = new_floats;
    var old_ses = state.ses_config;
    state.ses_config = new_ses;
    old_ses.deinit(state.allocator);
    // The new config carries a NEW LuaRuntime, and `hexe.live` is installed on
    // a runtime, not on a config. Without this, every `ctx.*` accessor and
    // every callback registered by the reloaded config is dead after a reload —
    // conditions silently stop matching and actions silently do nothing.
    if (state.config._lua_runtime) |rt| lua_api.install(rt);
    applyPaletteConfig(state);
    state.renderer.invalidate();
    state.force_full_render = true;
    state.needs_render = true;
    state.notifications.showFor("Config reloaded", 1200);
}

fn dispatchHostSurfaceAction(state: *State, action: frontend_core.HostSurfaceAction) bool {
    switch (action) {
        .clipboard_copy => {
            const pane: ?*Pane = if (state.activeFloatingIndex()) |idx|
                state.view.float_views.items[idx]
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

            const body = if (state.view.tab_views.items.len > 0 and state.activeTabIndex() < state.view.tab_views.items.len)
                (state.runtime.tabName(state.activeTabIndex()) orelse "tab")
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
        .sync_toggle => {
            state.sync_input = !state.sync_input;
            state.notifications.showFor(if (state.sync_input) "Input sync: ON" else "Input sync: OFF", 1200);
            state.needs_render = true;
            return true;
        },
        .tab_rename => {
            state.beginTabRename();
            return true;
        },
        .pane_zoom => {
            state.toggleZoom();
            return true;
        },
        .config_reload => {
            performConfigReload(state);
            return true;
        },
        .copy_enter => {
            state.enterCopyMode();
            return true;
        },
        .search_enter => {
            state.enterSearchMode();
            return true;
        },
        .prompt_previous, .prompt_next => {
            const pane = focusedPane(state) orelse return true;
            const direction: prompt_navigation.Direction = if (action == .prompt_previous) .previous else .next;
            if (prompt_navigation.jump(&pane.vt, direction)) {
                state.needs_render = true;
                state.force_full_render = true;
            }
            return true;
        },
        .prompt_copy_output => {
            const pane = focusedPane(state) orelse return true;
            const output = prompt_navigation.lastOutputAlloc(state.allocator, &pane.vt) catch {
                state.notifications.showFor("Copy command output failed", 1200);
                state.needs_render = true;
                return true;
            } orelse return true;
            defer state.allocator.free(output);

            const stdout = std.fs.File.stdout();
            var writer_buf: [256]u8 = undefined;
            var writer = stdout.writer(&writer_buf);
            state.renderer.vx.copyToSystemClipboard(&writer.interface, output, state.allocator) catch {
                state.notifications.showFor("Clipboard copy failed", 1200);
                state.needs_render = true;
                return true;
            };
            state.notifications.showFor("Copied command output", 1200);
            state.needs_render = true;
            return true;
        },
        .sprite_toggle => {
            // Toggle sprite on the focused pane - use the pane's actual Pokemon name!
            if (state.activeFloatingIndex()) |idx| {
                if (idx < state.view.float_views.items.len) {
                    const pane = state.view.float_views.items[idx];
                    if (pane.pokemon_initialized) {
                        if (pane.pokemon_state.show_sprite) {
                            pane.pokemon_state.hide();
                        } else {
                            // Get the pane's Pokemon name from pane_names cache
                            const pokemon_name = pane.pokemon_state.sprite_name orelse state.paneName(pane.uuid) orelse "pikachu";

                            pane.pokemon_state.loadSprite(pokemon_name, rollShiny(state)) catch {
                                // Fallback to pikachu if loading fails
                                pane.pokemon_state.loadSprite("pikachu", rollShiny(state)) catch |err| {
                                    core.logging.logError("terminal", "failed to load fallback sprite for focused float", err);
                                };
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
                        const pokemon_name = pane.pokemon_state.sprite_name orelse state.paneName(pane.uuid) orelse "pikachu";

                        pane.pokemon_state.loadSprite(pokemon_name, rollShiny(state)) catch {
                            pane.pokemon_state.loadSprite("pikachu", rollShiny(state)) catch |err| {
                                core.logging.logError("terminal", "failed to load fallback sprite for focused pane", err);
                            };
                        };
                    }
                    state.needs_render = true;
                }
            }
            return true;
        },
    }
}

fn nudgeFloat(state: *State, pane: *Pane, dir: layout_mod.Layout.Direction, step_cells: u16) void {
    const frame = state.floatFrameForPane(pane);
    const max_x: u16 = frame.max_x;
    const max_y: u16 = frame.max_y;

    var outer_x: i32 = @intCast(state.paneBorderX(pane));
    var outer_y: i32 = @intCast(state.paneBorderY(pane));
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

    // Convert back to a percentage, which is what is stored (it survives a
    // resize). Both directions of that conversion truncate, and the frame is
    // recomputed from the percentage every frame — so the naive
    // `pct = cells * 100 / max` round-tripped straight back to the ORIGINAL
    // cell for most terminal widths, and nudging right or down did nothing at
    // all while left and up jumped two cells.
    //
    // Pick the nearest percentage that actually lands on the requested cell.
    const pos_x_pct: u8 = float_geometry.pctForCell(@intCast(outer_x), max_x, dx);
    const pos_y_pct: u8 = float_geometry.pctForCell(@intCast(outer_y), max_y, dy);
    state.setPaneFloatGeometryUi(
        pane.uuid,
        state.paneFloatWidthPct(pane),
        state.paneFloatHeightPct(pane),
        pos_x_pct,
        pos_y_pct,
        state.paneFloatPadX(pane),
        state.paneFloatPadY(pane),
    );
    state.setPaneFloatGeometry(
        pane,
        state.paneFloatWidthPct(pane),
        state.paneFloatHeightPct(pane),
        pos_x_pct,
        pos_y_pct,
        state.paneFloatPadX(pane),
        state.paneFloatPadY(pane),
    );
    state.applyFrontendFloatNudge(pane);

    state.resizeFloatingPanes();
}
