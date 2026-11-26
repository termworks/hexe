//! Native in-mux session saving and saved-layout picker.
//!
//! Replaces the old shell-typing hack (`pane.write("hexe lay save ...")`) with
//! a direct snapshot from live `State` — so saving works cleanly even inside
//! `nvim`, TUIs, or floating terminals — and provides a filterable picker of
//! all local (`./.hexe.lua`) and globally registered layouts (`sessions.json`)
//! shared by both in-mux `layout.load` and the startup/attach chooser.

const std = @import("std");
const core = @import("core");
const pop = @import("pop");

const State = @import("state.zig").State;
const layout_mod = @import("layout.zig");
const actions = @import("loop_actions.zig");
const startup_chooser = @import("startup_chooser.zig");

const freeze = core.session_freeze;
const session_config = core.session_config;

pub const MAX_SAVED_LAYOUTS = 64;

pub const SavedLayoutItem = struct {
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    file_buf: [512]u8 = undefined,
    file_len: usize = 0,
    root_buf: [256]u8 = undefined,
    root_len: usize = 0,
    is_local_cwd: bool = false,
    is_global_store: bool = false,
    in_registry: bool = false,

    pub fn name(self: *const SavedLayoutItem) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn filePath(self: *const SavedLayoutItem) []const u8 {
        return self.file_buf[0..self.file_len];
    }

    pub fn rootPath(self: *const SavedLayoutItem) []const u8 {
        return self.root_buf[0..self.root_len];
    }
};

fn buildFreezeNode(
    arena: std.mem.Allocator,
    state: *State,
    tab_layout: *layout_mod.Layout,
    node: *const layout_mod.LayoutNode,
) !*const freeze.FreezeNode {
    const out = try arena.create(freeze.FreezeNode);
    switch (node.*) {
        .pane => |uuid| {
            var cwd_copy: ?[]const u8 = null;
            if (tab_layout.splits.get(uuid)) |pane| {
                if (state.getReliableCwd(pane)) |cwd| {
                    if (cwd.len > 0) cwd_copy = try arena.dupe(u8, cwd);
                }
            }
            out.* = .{ .pane = .{ .cwd = cwd_copy } };
        },
        .split => |sp| {
            const first = try buildFreezeNode(arena, state, tab_layout, sp.first);
            const second = try buildFreezeNode(arena, state, tab_layout, sp.second);
            out.* = .{ .split = .{
                .dir = if (sp.dir == .vertical) "vertical" else "horizontal",
                .ratio = sp.ratio,
                .first = first,
                .second = second,
            } };
        },
    }
    return out;
}

fn sanitizeSessionName(raw: []const u8, buf: *[64]u8) []const u8 {
    var n: usize = 0;
    for (raw) |ch| {
        if (n >= buf.len) break;
        if (ch == '/' or ch == '\\' or ch == 0 or ch == '\n' or ch == '\r') {
            buf[n] = '-';
        } else {
            buf[n] = ch;
        }
        n += 1;
    }
    return std.mem.trim(u8, buf[0..n], " \t-");
}

/// Snapshot the live terminal session directly from `State` and save it as a
/// canonical `.hexe.lua` layout (without typing anything into any pane).
pub fn saveCurrentSession(state: *State, scope: freeze.SaveScope) void {
    var arena_state = std.heap.ArenaAllocator.init(state.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_root = state.runtime.baseRoot();
    const root_cwd: []const u8 = blk: {
        if (base_root.len > 0) break :blk base_root;
        if (state.view.tab_views.items.len > 0) {
            if (state.currentLayout().getFocusedPane()) |pane| {
                if (state.getReliableCwd(pane)) |c| {
                    if (c.len > 0) break :blk c;
                }
            }
        }
        break :blk std.posix.getcwd(&cwd_buf) catch "/tmp";
    };

    var name_buf: [64]u8 = undefined;
    const raw_name = state.runtime.sessionName();
    const layout_name: []const u8 = blk: {
        const clean = sanitizeSessionName(raw_name, &name_buf);
        if (clean.len > 0) break :blk clean;
        const base = sanitizeSessionName(std.fs.path.basename(root_cwd), &name_buf);
        if (base.len > 0) break :blk base;
        break :blk "session";
    };

    // Build tabs.
    var tabs = std.ArrayList(freeze.FreezeTab).empty;
    for (state.view.tab_views.items, 0..) |*tab, ti| {
        const tname = state.runtime.tabName(ti) orelse "tab";
        const root_node: ?*const freeze.FreezeNode = if (tab.layout.root) |r|
            buildFreezeNode(arena, state, &tab.layout, r) catch null
        else
            null;
        tabs.append(arena, .{
            .name = tname,
            .root = root_node,
        }) catch {
            state.notifications.showFor("Save failed: out of memory", 2200);
            state.needs_render = true;
            return;
        };
    }

    // Build top-level floats (skip sub-float children).
    var floats = std.ArrayList(freeze.FreezeFloat).empty;
    for (state.view.float_views.items) |fp| {
        if (state.paneFloatState(fp)) |fs| {
            if (fs.parent_float != null) continue;
        }
        const key = state.paneFloatKey(fp);
        const def = if (key != 0) state.getLayoutFloatByKey(key) else null;

        var attrs = if (def) |d| d.attributes else core.config.FloatAttributes{};
        if (state.paneSticky(fp)) attrs.sticky = true;
        if (state.paneIsPwd(fp) and !attrs.per_git) attrs.per_cwd = true;
        if (state.paneParentTab(fp) == null and !attrs.keyedByDir()) attrs.global = true;

        const title = state.paneFloatTitle(fp) orelse if (def) |d| d.title else null;
        const fname: []const u8 = if (def) |d|
            (d.name orelse title orelse "")
        else
            (title orelse "");

        floats.append(arena, .{
            .name = fname,
            .key = key,
            .title = title,
            .command = if (def) |d| d.command else null,
            .width_pct = state.paneFloatWidthPct(fp),
            .height_pct = state.paneFloatHeightPct(fp),
            .pos_x_pct = state.paneFloatPosXPct(fp),
            .pos_y_pct = state.paneFloatPosYPct(fp),
            .attributes = attrs,
        }) catch {
            state.notifications.showFor("Save failed: out of memory", 2200);
            state.needs_render = true;
            return;
        };
    }

    const lua_src = freeze.writeSessionLua(state.allocator, .{
        .name = layout_name,
        .root = root_cwd,
        .tabs = tabs.items,
        .floats = floats.items,
    }) catch {
        state.notifications.showFor("Save failed: could not serialize layout", 2200);
        state.needs_render = true;
        return;
    };
    defer state.allocator.free(lua_src);

    var saved = freeze.saveSessionLayout(state.allocator, scope, layout_name, root_cwd, lua_src) catch |err| {
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Save failed: {s}", .{@errorName(err)}) catch "Save failed";
        state.notifications.showFor(msg, 2400);
        state.needs_render = true;
        return;
    };
    defer saved.deinit(state.allocator);

    const scope_label: []const u8 = switch (scope) {
        .local => "local",
        .global => "global",
        .both => "local+global",
    };
    var msg_buf: [192]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "Saved '{s}' ({d}t, {d}f · {s})",
        .{ saved.name, tabs.items.len, floats.items.len, scope_label },
    ) catch "Session layout saved";
    state.notifications.showFor(msg, 2400);
    state.needs_render = true;
}

/// Open the scope picker for `layout.save`.
pub fn openSaveScopePicker(state: *State) void {
    const labels = [_][]const u8{
        "Local & global",
        "Global only",
        "Local only",
    };
    const badges = [_][]const u8{
        "both",
        "clean repo",
        "project",
    };
    const details = [_][]const u8{
        "Writes ./.hexe.lua and registers globally for quick open",
        "Saves to ~/.local/share/hexe/layouts/<name>.lua (no repo file)",
        "Writes ./.hexe.lua in the project root only",
    };
    _ = state.showPickerWithOptions(.layout_save_choose, &labels, .{
        .title = "Save current session",
        .badges = &badges,
        .details = &details,
        .hint = "↑↓/jk move · Enter save · Esc cancel",
    });
}

fn copySlice(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

/// Collect all saved layouts (local `./.hexe.lua` + registered entries in
/// `sessions.json`), sorted with current-directory layouts first.
pub fn collectSavedLayouts(allocator: std.mem.Allocator, out: *[MAX_SAVED_LAYOUTS]SavedLayoutItem) usize {
    var n: usize = 0;

    const cwd_opt = std.fs.cwd().realpathAlloc(allocator, ".") catch null;
    defer if (cwd_opt) |c| allocator.free(c);

    const global_dir_opt = session_config.getGlobalLayoutsDir(allocator) catch null;
    defer if (global_dir_opt) |d| allocator.free(d);

    var registry = session_config.loadLayoutRegistry(allocator) catch session_config.LayoutRegistry{};
    defer session_config.deinitLayoutRegistry(allocator, &registry);

    var cwd_covered = false;

    for (registry.entries) |entry| {
        if (n >= MAX_SAVED_LAYOUTS) break;
        const file_path = session_config.resolveRegistryEntryPath(allocator, entry) catch continue;
        defer allocator.free(file_path);

        // Skip dangling registry entries whose backing .lua file no longer exists.
        std.fs.cwd().access(file_path, .{}) catch continue;

        const is_global_store = if (global_dir_opt) |gd|
            std.mem.startsWith(u8, file_path, gd)
        else
            false;
        const is_local_cwd = if (cwd_opt) |cwd|
            (!is_global_store and std.mem.eql(u8, entry.path, cwd))
        else
            false;
        if (is_local_cwd) cwd_covered = true;

        var item = SavedLayoutItem{
            .is_local_cwd = is_local_cwd,
            .is_global_store = is_global_store,
            .in_registry = true,
        };
        item.name_len = copySlice(&item.name_buf, entry.name);
        item.file_len = copySlice(&item.file_buf, file_path);
        const display_root = if (is_global_store) file_path else entry.path;
        item.root_len = copySlice(&item.root_buf, display_root);
        out[n] = item;
        n += 1;
    }

    // Include an unregistered `./.hexe.lua` in the current directory if present.
    if (!cwd_covered and n < MAX_SAVED_LAYOUTS) {
        if (cwd_opt) |cwd| {
            const local_path = std.fmt.allocPrint(allocator, "{s}/.hexe.lua", .{cwd}) catch null;
            if (local_path) |lp| {
                defer allocator.free(lp);
                if (std.fs.cwd().access(lp, .{})) |_| {
                    const base = std.fs.path.basename(cwd);
                    var item = SavedLayoutItem{
                        .is_local_cwd = true,
                        .is_global_store = false,
                        .in_registry = false,
                    };
                    item.name_len = copySlice(&item.name_buf, if (base.len > 0) base else "local");
                    item.file_len = copySlice(&item.file_buf, lp);
                    item.root_len = copySlice(&item.root_buf, cwd);
                    out[n] = item;
                    n += 1;
                } else |_| {}
            }
        }
    }

    // Sort: current directory first, then alphabetical by name.
    std.mem.sort(SavedLayoutItem, out[0..n], {}, struct {
        fn lessThan(_: void, a: SavedLayoutItem, b: SavedLayoutItem) bool {
            if (a.is_local_cwd != b.is_local_cwd) return a.is_local_cwd;
            return std.ascii.lessThanIgnoreCase(a.name(), b.name());
        }
    }.lessThan);

    return n;
}

fn showSavedLayoutPicker(state: *State, is_startup: bool) bool {
    const count = collectSavedLayouts(state.allocator, &state.saved_layouts);
    state.saved_layout_count = count;
    state.saved_layout_selected = null;

    if (count == 0) {
        if (is_startup) {
            state.notifications.showFor("No saved layouts yet (use layout.save inside a session)", 2200);
            startup_chooser.refreshPicker(state);
        } else {
            state.notifications.showFor("No saved layouts — save one with layout.save", 2200);
            state.needs_render = true;
        }
        return false;
    }

    var label_storage: [MAX_SAVED_LAYOUTS][96]u8 = undefined;
    var badge_storage: [MAX_SAVED_LAYOUTS][32]u8 = undefined;
    var detail_storage: [MAX_SAVED_LAYOUTS][320]u8 = undefined;
    var labels: [MAX_SAVED_LAYOUTS][]const u8 = undefined;
    var badges: [MAX_SAVED_LAYOUTS][]const u8 = undefined;
    var details: [MAX_SAVED_LAYOUTS][]const u8 = undefined;

    for (state.saved_layouts[0..count], 0..) |*item, i| {
        labels[i] = std.fmt.bufPrint(&label_storage[i], "{s}", .{item.name()}) catch item.name();
        badges[i] = if (item.is_local_cwd and item.in_registry)
            std.fmt.bufPrint(&badge_storage[i], "here · saved", .{}) catch "here"
        else if (item.is_local_cwd)
            std.fmt.bufPrint(&badge_storage[i], "here · local", .{}) catch "local"
        else if (item.is_global_store)
            std.fmt.bufPrint(&badge_storage[i], "global", .{}) catch "global"
        else
            std.fmt.bufPrint(&badge_storage[i], "saved", .{}) catch "saved";

        var home_buf: [256]u8 = undefined;
        const path_disp = core.cli_ui.compactHome(item.rootPath(), &home_buf);
        details[i] = std.fmt.bufPrint(&detail_storage[i], "{s}", .{path_disp}) catch path_disp;
    }

    const pending: @import("state_types.zig").PendingAction = if (is_startup)
        .startup_saved_layouts_choose
    else
        .layout_load_picker;

    const hint: []const u8 = if (is_startup)
        "↑↓/jk move · / filter · l sessions · n new · x delete · Enter open · Esc back"
    else
        "↑↓/jk move · / filter · Enter load · x delete · Esc cancel";

    const action_keys: []const u8 = if (is_startup) "lnxd" else "xd";

    return state.showPickerWithOptions(pending, labels[0..count], .{
        .title = "Saved session layouts",
        .badges = badges[0..count],
        .details = details[0..count],
        .hint = hint,
        .filterable = true,
        .action_keys = action_keys,
    });
}

pub fn openInMuxPicker(state: *State) void {
    _ = showSavedLayoutPicker(state, false);
}

pub fn openStartupPicker(state: *State) void {
    _ = showSavedLayoutPicker(state, true);
}

/// Handle a selection or hotkey from the in-mux saved-layout picker.
pub fn handleInMuxPicker(state: *State, selected: ?usize, action: ?pop.PickerAction) void {
    if (selected) |idx| {
        if (idx >= state.saved_layout_count) return;
        state.saved_layout_selected = idx;
        const item = &state.saved_layouts[idx];
        var title_buf: [128]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "Load layout '{s}'", .{item.name()}) catch "Load layout";
        const labels = [_][]const u8{
            "Replace current session",
            "Open in new session (detach)",
        };
        const details = [_][]const u8{
            "Replaces tabs and floats in this window",
            "Detaches this session and launches the layout fresh",
        };
        _ = state.showPickerWithOptions(.layout_load_choose, &labels, .{
            .title = title,
            .details = &details,
            .hint = "↑↓/jk move · Enter confirm · Esc cancel",
        });
        return;
    }

    if (action) |act| {
        if (act.key == 'x' or act.key == 'd') {
            promptDeleteLayout(state, act.selected, false);
        }
    }
}

/// Handle a selection or hotkey from the startup/attach saved-layout picker.
pub fn handleStartupPicker(state: *State, selected: ?usize, action: ?pop.PickerAction) void {
    if (selected) |idx| {
        if (idx >= state.saved_layout_count) {
            startup_chooser.refreshPicker(state);
            return;
        }
        const path = state.saved_layouts[idx].filePath();
        const ok = applyLayoutFileToState(state, path, false);
        startup_chooser.finishLayout(state, ok);
        return;
    }

    if (action) |act| {
        switch (act.key) {
            'l' => startup_chooser.refreshPicker(state),
            'n' => startup_chooser.finishPlain(state),
            'x', 'd' => promptDeleteLayout(state, act.selected, true),
            else => openStartupPicker(state),
        }
        return;
    }

    // Esc pressed in startup saved-layouts picker: go back to sessions picker.
    startup_chooser.refreshPicker(state);
}

fn promptDeleteLayout(state: *State, selected: ?usize, is_startup: bool) void {
    const idx = selected orelse {
        if (is_startup) openStartupPicker(state) else openInMuxPicker(state);
        return;
    };
    if (idx >= state.saved_layout_count) return;
    const item = &state.saved_layouts[idx];
    if (!item.in_registry) {
        state.notifications.showFor("Local .hexe.lua is not in registry (remove file manually)", 2400);
        if (is_startup) openStartupPicker(state) else openInMuxPicker(state);
        return;
    }
    state.saved_layout_delete_idx = idx;
    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Remove saved layout '{s}'?", .{item.name()}) catch "Remove saved layout?";
    const sub: []const u8 = if (item.is_global_store)
        "Deletes global layout file and registry entry"
    else
        "Unregisters from sessions.json (keeps project .hexe.lua)";
    const pending: @import("state_types.zig").PendingAction = if (is_startup)
        .startup_layout_delete_confirm
    else
        .layout_delete_confirm;
    if (!state.showConfirmWithOptions(pending, msg, .{
        .default = .no,
        .yes_label = "Remove",
        .no_label = "Cancel",
        .subtitle = sub,
    })) {
        if (is_startup) openStartupPicker(state) else openInMuxPicker(state);
    }
}

pub fn confirmDelete(state: *State, confirmed: bool, is_startup: bool) void {
    const idx_opt = state.saved_layout_delete_idx;
    state.saved_layout_delete_idx = null;
    if (confirmed) {
        if (idx_opt) |idx| {
            if (idx < state.saved_layout_count) {
                const name = state.saved_layouts[idx].name();
                if (session_config.removeLayoutRegistryEntry(state.allocator, name)) |removed| {
                    if (removed) {
                        state.notifications.showFor("Saved layout removed", 1800);
                    } else {
                        state.notifications.showFor("Saved layout not found", 1800);
                    }
                } else |_| {
                    state.notifications.showFor("Failed to remove saved layout", 2000);
                }
            }
        }
    }
    if (is_startup) openStartupPicker(state) else openInMuxPicker(state);
}

/// Apply the currently selected saved layout (`replace` vs `detach`) in-mux.
pub fn executeInMuxLoadChoice(state: *State, choice: usize) void {
    const idx = state.saved_layout_selected orelse return;
    state.saved_layout_selected = null;
    if (idx >= state.saved_layout_count) return;
    const file_path = state.saved_layouts[idx].filePath();

    switch (choice) {
        0 => {
            _ = applyLayoutFileToState(state, file_path, true);
        },
        1 => {
            openLayoutPathDetached(state, file_path);
        },
        else => {},
    }
}

/// Load a `.hexe.lua` layout file into `state` (replacing existing tabs when
/// `replace == true`, or applying cleanly during startup when `replace == false`).
pub fn applyLayoutFileToState(state: *State, file_path: []const u8, replace: bool) bool {
    const parsed = session_config.parseSessionLuaOnceApproving(
        state.allocator,
        file_path,
        .{ .tools = true },
    ) catch {
        state.notifications.showFor("Failed to parse saved layout", 2000);
        state.needs_render = true;
        return false;
    };

    switch (parsed) {
        .layout => |layout_value| {
            var layout = layout_value;
            defer layout.deinit(state.allocator);

            if (layout.root) |root| {
                if (root.len > 0) std.posix.chdir(root) catch {};
            }
            if (state.runtime.setSessionName(layout.name)) {
                const identity_change = state.runtime.syncSessionIdentity() catch null;
                if (identity_change) |change| {
                    var owned_change = change;
                    defer owned_change.deinit(state.allocator);
                }
            }

            const apply_res = if (replace)
                state.replaceWithLayoutDef(&layout)
            else
                state.applyLayoutDef(&layout);
            apply_res catch {
                state.notifications.showFor("Failed to apply saved layout", 2000);
                state.needs_render = true;
                return false;
            };

            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Loaded layout '{s}'", .{layout.name}) catch "Layout loaded";
            state.notifications.showFor(msg, 1800);
            state.needs_render = true;
            state.force_full_render = true;
            return true;
        },
        .legacy => |cfg_value| {
            var cfg = cfg_value;
            defer cfg.deinit(state.allocator);

            if (cfg.root) |root| {
                std.posix.chdir(root) catch {};
            }
            if (cfg.name) |desired_name| {
                if (state.runtime.setSessionName(desired_name)) {
                    const identity_change = state.runtime.syncSessionIdentity() catch null;
                    if (identity_change) |change| {
                        var owned_change = change;
                        defer owned_change.deinit(state.allocator);
                    }
                }
            }

            const apply_res = if (replace)
                state.replaceWithSessionConfig(cfg, null)
            else
                state.applySessionConfig(cfg, null);
            apply_res catch {
                state.notifications.showFor("Failed to apply saved layout", 2000);
                state.needs_render = true;
                return false;
            };

            state.notifications.showFor("Layout loaded", 1800);
            state.needs_render = true;
            state.force_full_render = true;
            return true;
        },
    }
}

fn openLayoutPathDetached(state: *State, target_path: []const u8) void {
    var env_map_opt = std.process.getEnvMap(state.allocator) catch null;
    defer if (env_map_opt) |*m| m.deinit();

    if (env_map_opt) |*env_map| {
        env_map.remove("HEXE_PANE_UUID");
        env_map.remove("HEXE_FOCUSED_PANE_UUID");
        env_map.remove("HEXE_STATUS_FOCUSED_PANE_UUID");
    }

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_buf) catch "hexe";
    const argv = [_][]const u8{ exe_path, "layout", "open", target_path };
    const env: ?*const std.process.EnvMap = if (env_map_opt) |*m| m else null;
    if (!state.async_cmds.spawnDetached(&argv, env)) {
        state.notifications.showFor("Failed to launch layout in new session", 1800);
        return;
    }
    actions.performDetach(state);
}
