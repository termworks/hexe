const std = @import("std");
const core = @import("core");
const shp = @import("shp");

const State = @import("state.zig").State;
const CursorInfo = @import("render_core.zig").CursorInfo;

const statusbar = @import("statusbar.zig");
const popup_render = @import("popup_render.zig");
const borders = @import("borders.zig");
const mouse_selection = @import("mouse_selection.zig");
const float_title = @import("float_title.zig");
const overlay_render = @import("overlay_render.zig");
const notification = @import("notification.zig");
const render_vx = @import("render_vx.zig");
const vt_bridge = @import("vt_bridge.zig");
const render_sprite = @import("render_sprite.zig");
const Pane = @import("pane.zig").Pane;

fn drawPaneRenderState(renderer: anytype, pane: *Pane, state: anytype, x: u16, y: u16, width: u16, height: u16, stdout: std.fs.File) void {
    const root = renderer.vx.window();
    const win = root.child(.{
        .x_off = @intCast(x),
        .y_off = @intCast(y),
        .width = width,
        .height = height,
    });
    vt_bridge.drawRenderState(win, state, width, height, renderer.frame_arena.allocator(), &pane.vt, &renderer.vx, stdout);
}

fn sanitizeLabelUtf8(raw: []const u8, out: *[128]u8) []const u8 {
    var wi: usize = 0;
    var i: usize = 0;
    while (i < raw.len and wi < out.len) {
        const b = raw[i];

        // Strip ANSI/VT escape sequences so terminal control bytes never
        // leak into float titles.
        if (b == 0x1b) {
            i += 1;
            if (i >= raw.len) break;
            const esc = raw[i];

            // CSI: ESC [ ... final
            if (esc == '[') {
                i += 1;
                while (i < raw.len) : (i += 1) {
                    const c = raw[i];
                    if (c >= 0x40 and c <= 0x7e) {
                        i += 1;
                        break;
                    }
                }
                continue;
            }

            // OSC: ESC ] ... BEL or ST (ESC \\)
            if (esc == ']') {
                i += 1;
                while (i < raw.len) {
                    const c = raw[i];
                    if (c == 0x07) {
                        i += 1;
                        break;
                    }
                    if (c == 0x1b and i + 1 < raw.len and raw[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
                continue;
            }

            // DCS/PM/APC: ESC P/^/_ ... ST (ESC \\)
            if (esc == 'P' or esc == '^' or esc == '_') {
                i += 1;
                while (i < raw.len) {
                    if (raw[i] == 0x1b and i + 1 < raw.len and raw[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
                continue;
            }

            // Other escape forms are 2-byte sequences.
            i += 1;
            continue;
        }

        // C1 controls (including 0x9B CSI) are never valid label content.
        if (b >= 0x80 and b <= 0x9f) {
            i += 1;
            continue;
        }

        const len = std.unicode.utf8ByteSequenceLength(b) catch 1;
        const end = @min(i + len, raw.len);
        const chunk = raw[i..end];
        const cp = std.unicode.utf8Decode(chunk) catch {
            i = end;
            continue;
        };

        // Skip control characters.
        if (cp < 32 or cp == 127) {
            i = end;
            continue;
        }

        if (wi + chunk.len > out.len) break;
        @memcpy(out[wi .. wi + chunk.len], chunk);
        wi += chunk.len;
        i = end;
    }
    return out[0..wi];
}

fn composeFloatBorderLabel(state: *State, pane: *const Pane, out: *[256]u8) []const u8 {
    const title = blk: {
        if (state.paneFloatTitle(pane)) |t| break :blk t;
        const float_key = state.paneFloatKey(pane);
        if (float_key != 0) {
            if (state.getLayoutFloatByKey(float_key)) |fd| {
                if (fd.title) |t| break :blk t;
            }
        }
        break :blk "";
    };
    const pokemon = state.paneName(pane.uuid) orelse "";

    if (title.len == 0) return pokemon;
    if (pokemon.len == 0) return title;

    var n: usize = 0;
    const title_n = @min(title.len, out.len);
    @memcpy(out[0..title_n], title[0..title_n]);
    n = title_n;
    if (n < out.len) {
        out[n] = ' ';
        n += 1;
    }
    const remain = out.len - n;
    const pokemon_n = @min(pokemon.len, remain);
    @memcpy(out[n .. n + pokemon_n], pokemon[0..pokemon_n]);
    n += pokemon_n;
    return out[0..n];
}

fn populateFloatTitleContext(state: *State, pane: *Pane, ctx: *shp.Context, now_ms: u64) void {
    ctx.terminal_width = state.term_width;
    ctx.home = std.posix.getenv("HOME");
    ctx.now_ms = now_ms;
    ctx.tab_count = @intCast(@min(state.view.tab_views.items.len, @as(usize, std.math.maxInt(u16))));
    ctx.active_tab = @intCast(state.activeTabIndex());
    ctx.session_name = state.runtime.sessionName();
    ctx.focus_is_float = true;
    ctx.focus_is_split = false;
    ctx.alt_screen = pane.vt.inAltScreen();

    if (state.getPaneShell(pane.uuid)) |info| {
        if (info.cmd) |c| ctx.last_command = c;
        if (info.cwd) |c| ctx.cwd = c;
        if (info.status) |st| ctx.exit_status = st;
        if (info.duration_ms) |d| ctx.cmd_duration_ms = d;
        if (info.jobs) |j| ctx.jobs = j;
        ctx.shell_running = info.running;
        if (info.cmd) |c| ctx.shell_running_cmd = c;
        ctx.shell_started_at_ms = info.started_at_ms;
    }

    const float_key = state.paneFloatKey(pane);
    ctx.float_key = float_key;
    ctx.float_sticky = state.paneSticky(pane);
    ctx.float_global = state.paneParentTab(pane) == null;
    if (float_key != 0) {
        if (state.getLayoutFloatByKey(float_key)) |fd| {
            ctx.float_destroyable = fd.attributes.destroy;
            ctx.float_exclusive = fd.attributes.exclusive;
            ctx.float_per_cwd = fd.attributes.per_cwd;
            ctx.float_isolated = fd.attributes.isolated;
            ctx.float_global = ctx.float_global or fd.attributes.global;
        }
    }
}

pub fn renderTo(state: *State, stdout: std.fs.File) !void {
    const renderer = &state.renderer;

    // Begin a new frame.
    renderer.vx.screen.clear();

    // Draw splits into the cell buffer.
    var pane_it = state.currentLayout().splitIterator();
    while (pane_it.next()) |pane| {
        const render_state = pane.*.getRenderState() catch continue;
        drawPaneRenderState(renderer, pane.*, render_state, pane.*.x, pane.*.y, pane.*.width, pane.*.height, stdout);

        if (state.mouse_selection.rangeForPane(state.activeTabIndex(), pane.*)) |range| {
            mouse_selection.applyOverlayTrimmed(renderer, render_state, pane.*.x, pane.*.y, pane.*.width, pane.*.height, range, state.config.selection_color);
        }

        const is_scrolled = pane.*.isScrolled();

        // Draw scroll indicator if pane is scrolled.
        if (is_scrolled) {
            borders.drawScrollIndicator(renderer, pane.*.x, pane.*.y, pane.*.width);
        }

        // Draw pane-local notification (PANE realm - bottom of pane).
        if (pane.*.hasActiveNotification()) {
            notification.renderInBounds(&pane.*.notifications, renderer, pane.*.x, pane.*.y, pane.*.width, pane.*.height, false);
        }

        // Draw sprite overlay if enabled
        if (pane.*.pokemon_initialized and pane.*.pokemon_state.show_sprite) {
            if (pane.*.pokemon_state.sprite_content) |content| {
                render_sprite.drawSpriteOverlay(renderer, pane.*.x, pane.*.y, pane.*.width, pane.*.height, content, state.pop_config.widgets.pokemon);
            }
        }
    }

    // Draw split borders when there are multiple splits.
    if (state.currentLayout().splitCount() > 1) {
        const content_height = state.term_height - state.status_height;
        borders.drawSplitBorders(renderer, state.currentLayout(), &state.config.splits, state.term_width, content_height);
    }

    const now_ms: u64 = @intCast(std.time.milliTimestamp());
    statusbar.beginExternalCallbackEval(state, state.config._lua_runtime);
    defer statusbar.endExternalCallbackEval();

    // Draw visible floats (on top of splits).
    // Draw inactive floats first, then active one last so it's on top.
    for (state.view.float_views.items, 0..) |pane, i| {
        if (!state.paneVisibleOnTab(pane, state.activeTabIndex())) continue;
        if (state.activeFloatingIndex() == i) continue; // Skip active, draw it last.
        // Skip tab-bound floats on wrong tab.
        if (state.paneParentTab(pane)) |parent| {
            if (parent != state.activeTabIndex()) continue;
        }

        var float_label_compose: [256]u8 = undefined;
        const float_label_raw = composeFloatBorderLabel(state, pane, &float_label_compose);
        var float_label_buf: [128]u8 = undefined;
        const float_label = sanitizeLabelUtf8(float_label_raw, &float_label_buf);
        var float_ctx = shp.Context.init(state.allocator);
        defer float_ctx.deinit();
        populateFloatTitleContext(state, pane, &float_ctx, now_ms);
        const float_query: core.PaneQuery = statusbar.queryFromContext(&float_ctx);
        borders.drawFloatingBorder(renderer, state.paneBorderX(pane), state.paneBorderY(pane), state.paneBorderW(pane), state.paneBorderH(pane), false, float_label, state.paneBorderColor(pane), state.paneFloatStyle(pane), &float_ctx, &float_query);
        if (state.float_rename_uuid) |uuid| {
            if (std.mem.eql(u8, &uuid, &pane.uuid)) {
                float_title.drawTitleEditor(state, renderer, pane, state.float_rename_buf.items);
            }
        }

        const render_state = pane.getRenderState() catch continue;
        drawPaneRenderState(renderer, pane, render_state, pane.x, pane.y, pane.width, pane.height, stdout);

        if (state.mouse_selection.rangeForPane(state.activeTabIndex(), pane)) |range| {
            mouse_selection.applyOverlayTrimmed(renderer, render_state, pane.x, pane.y, pane.width, pane.height, range, state.config.selection_color);
        }

        if (pane.isScrolled()) {
            borders.drawScrollIndicator(renderer, pane.x, pane.y, pane.width);
        }

        // Draw pane-local notification (PANE realm - bottom of pane).
        if (pane.hasActiveNotification()) {
            notification.renderInBounds(&pane.notifications, renderer, pane.x, pane.y, pane.width, pane.height, false);
        }

        // Draw sprite overlay if enabled
        if (pane.pokemon_initialized and pane.pokemon_state.show_sprite) {
            if (pane.pokemon_state.sprite_content) |content| {
                render_sprite.drawSpriteOverlay(renderer, pane.x, pane.y, pane.width, pane.height, content, state.pop_config.widgets.pokemon);
            }
        }
    }

    // Draw active float last so it's on top.
    if (state.activeFloatingIndex()) |idx| {
        const pane = state.view.float_views.items[idx];
        // Check tab ownership for tab-bound floats.
        const can_render = if (state.paneParentTab(pane)) |parent|
            parent == state.activeTabIndex()
        else
            true;
        if (state.paneVisibleOnTab(pane, state.activeTabIndex()) and can_render) {
            var active_float_label_compose: [256]u8 = undefined;
            const active_float_label_raw = composeFloatBorderLabel(state, pane, &active_float_label_compose);
            var active_float_label_buf: [128]u8 = undefined;
            const active_float_label = sanitizeLabelUtf8(active_float_label_raw, &active_float_label_buf);
            var float_ctx = shp.Context.init(state.allocator);
            defer float_ctx.deinit();
            populateFloatTitleContext(state, pane, &float_ctx, now_ms);
            const float_query: core.PaneQuery = statusbar.queryFromContext(&float_ctx);
            borders.drawFloatingBorder(renderer, state.paneBorderX(pane), state.paneBorderY(pane), state.paneBorderW(pane), state.paneBorderH(pane), true, active_float_label, state.paneBorderColor(pane), state.paneFloatStyle(pane), &float_ctx, &float_query);
            if (state.float_rename_uuid) |uuid| {
                if (std.mem.eql(u8, &uuid, &pane.uuid)) {
                    float_title.drawTitleEditor(state, renderer, pane, state.float_rename_buf.items);
                }
            }

            if (pane.getRenderState()) |render_state| {
                drawPaneRenderState(renderer, pane, render_state, pane.x, pane.y, pane.width, pane.height, stdout);

                if (state.mouse_selection.rangeForPane(state.activeTabIndex(), pane)) |range| {
                    mouse_selection.applyOverlayTrimmed(renderer, render_state, pane.x, pane.y, pane.width, pane.height, range, state.config.selection_color);
                }
            } else |_| {}

            if (pane.isScrolled()) {
                borders.drawScrollIndicator(renderer, pane.x, pane.y, pane.width);
            }

            // Draw pane-local notification (PANE realm - bottom of pane).
            if (pane.hasActiveNotification()) {
                notification.renderInBounds(&pane.notifications, renderer, pane.x, pane.y, pane.width, pane.height, false);
            }

            // Draw sprite overlay if enabled
            if (pane.pokemon_initialized and pane.pokemon_state.show_sprite) {
                if (pane.pokemon_state.sprite_content) |content| {
                    render_sprite.drawSpriteOverlay(renderer, pane.x, pane.y, pane.width, pane.height, content, state.pop_config.widgets.pokemon);
                }
            }
        }
    }

    // Draw status bar if enabled.
    if (state.config.tabs.status.enabled) {
        statusbar.draw(renderer, state, state.allocator, &state.config, state.term_width, state.term_height, state.view.tab_views, state.activeTabIndex(), state.runtime.sessionName());
    }

    // Check if active float has dim_background set (focus mode)
    const float_dim = if (state.activeFloatingIndex()) |idx| blk: {
        if (idx < state.view.float_views.items.len) break :blk state.paneDimBackground(state.view.float_views.items[idx]);
        break :blk false;
    } else false;

    // Draw overlays (dimming, pane labels, resize info, keycast)
    if (state.overlays.hasContent() or state.overlays.shouldDim() or float_dim) {
        // Get focused pane bounds to exclude from dimming
        // For floats: use border dimensions + shadow (1 cell right/bottom) if shadow enabled
        const focused_bounds: ?overlay_render.Bounds = blk: {
            if (state.activeFloatingIndex()) |idx| {
                if (idx < state.view.float_views.items.len) {
                    const fp = state.view.float_views.items[idx];
                    const has_shadow = state.paneFloatHasShadow(fp);
                    const shadow_offset: u16 = if (has_shadow) 1 else 0;
                    break :blk .{
                        .x = state.paneBorderX(fp),
                        .y = state.paneBorderY(fp),
                        .w = state.paneBorderW(fp) + shadow_offset,
                        .h = state.paneBorderH(fp) + shadow_offset,
                    };
                }
            }
            if (state.currentLayout().getFocusedPane()) |p| {
                break :blk .{ .x = p.x, .y = p.y, .w = p.width, .h = p.height };
            }
            break :blk null;
        };

        // Apply dimming for float focus mode (when overlays.shouldDim() is false)
        if (float_dim and !state.overlays.shouldDim()) {
            overlay_render.applyDimEffect(renderer, state.term_width, state.term_height, focused_bounds);
        }

        overlay_render.renderOverlays(renderer, &state.overlays, state.term_width, state.term_height, state.status_height, focused_bounds);
    }

    // Draw TAB realm notifications (center of screen, below MUX).
    const current_tab = &state.view.tab_views.items[state.activeTabIndex()];

    // Draw PANE-level blocking popups (for ALL panes with active popups).
    // Check all splits in current tab.
    var split_iter = current_tab.layout.splits.valueIterator();
    while (split_iter.next()) |pane| {
        if (pane.*.popups.getActivePopup()) |popup| {
            popup_render.drawInBounds(renderer, popup, &state.pop_config.pane, pane.*.x, pane.*.y, pane.*.width, pane.*.height);
        }
    }
    // Check all floats.
    for (state.view.float_views.items) |fpane| {
        if (fpane.popups.getActivePopup()) |popup| {
            popup_render.drawInBounds(renderer, popup, &state.pop_config.pane, fpane.x, fpane.y, fpane.width, fpane.height);
        }
    }
    if (current_tab.notifications.hasActive()) {
        // TAB notifications render in center area (distinct from MUX at top).
        notification.renderInBounds(&current_tab.notifications, renderer, 0, 0, state.term_width, state.layout_height, true);
    }

    // Draw TAB-level blocking popup (below MUX popup).
    if (current_tab.popups.getActivePopup()) |popup| {
        popup_render.draw(renderer, popup, &state.pop_config.carrier, state.term_width, state.term_height);
    }

    // Draw MUX realm notifications overlay (top of screen).
    notification.renderFull(&state.notifications, renderer, state.term_width, state.term_height);

    // Draw MUX-level blocking popup overlay (on top of everything).
    if (state.popups.getActivePopup()) |popup| {
        popup_render.draw(renderer, popup, &state.pop_config.carrier, state.term_width, state.term_height);
    }

    // Gather cursor info.
    var cursor = CursorInfo{};

    if (state.activeFloatingIndex()) |idx| {
        const pane = state.view.float_views.items[idx];
        const pos = pane.getCursorPos();
        cursor.x = pos.x;
        cursor.y = pos.y;
        cursor.style = pane.getCursorStyle();
        cursor.visible = pane.isCursorVisible();
    } else if (state.currentLayout().getFocusedPane()) |pane| {
        const pos = pane.getCursorPos();
        cursor.x = pos.x;
        cursor.y = pos.y;
        cursor.style = pane.getCursorStyle();
        cursor.visible = pane.isCursorVisible();
    }

    // Explicit one-shot cursor restore (position + style + visibility) captured
    // before opening a transient CLI float.
    if (state.cursor_restore_snapshot) |saved| {
        if (state.findPaneByUuid(saved.source_uuid)) |pane| {
            const focused_uuid = state.getCurrentFocusedUuid();
            if (focused_uuid) |focused| {
                if (std.mem.eql(u8, &focused, &saved.source_uuid)) {
                    const rel_x = @min(saved.rel_x, pane.width -| 1);
                    const rel_y = @min(saved.rel_y, pane.height -| 1);
                    const abs_x = pane.x + rel_x;
                    const abs_y = pane.y + rel_y;
                    cursor.x = @min(abs_x, state.term_width -| 1);
                    cursor.y = @min(abs_y, state.term_height -| 1);
                    cursor.style = saved.style;
                    cursor.visible = saved.visible;
                    state.cursor_restore_snapshot = null;
                    state.cursor_needs_restore = false;
                }
            }
        } else {
            // Source pane no longer exists; drop stale snapshot and keep legacy
            // visibility restore behavior.
            state.cursor_restore_snapshot = null;
            state.cursor_needs_restore = true;
        }
    } else if (state.cursor_needs_restore) {
        // Legacy restore path (e.g., tab switch or non-CLI float death):
        // force visibility for one frame.
        cursor.visible = true;
        state.cursor_needs_restore = false;
    }

    // End frame: render current vaxis screen.
    try render_vx.renderFrame(&renderer.vx, stdout, cursor, state.force_full_render);
    _ = renderer.frame_arena.reset(.retain_capacity);
    state.force_full_render = false;
}
