const std = @import("std");
const core = @import("core");

const State = @import("state.zig").State;
const CursorInfo = @import("render_core.zig").CursorInfo;
const Renderer = @import("render_core.zig").Renderer;
const ghostty = @import("ghostty-vt");

const statusbar = @import("statusbar.zig");
const popup_render = @import("popup_render.zig");
const borders = @import("borders.zig");
const mouse_selection = @import("mouse_selection.zig");
const float_title = @import("float_title.zig");
const overlay_render = @import("overlay_render.zig");
const notification = @import("notification.zig");
const render_vx = @import("render_vx.zig");
const vaxis = @import("vaxis");
const pane_search = @import("pane_search.zig");
const vt_bridge = @import("vt_bridge.zig");
const region_render = @import("region_render.zig");
const decor = @import("decor.zig");
const sanitizeLabelUtf8 = @import("text_width.zig").sanitizeLabelUtf8;
const Pane = @import("pane.zig").Pane;

/// Draw the scrollback-search prompt on the bottom terminal row:
/// `/<query>` while typing, `/<query>  [i/N]` (or `[no matches]`) after running.
fn renderSearchPrompt(state: *State, renderer: *Renderer) void {
    const w = state.term_width;
    if (w == 0 or state.term_height == 0) return;
    const row: u16 = state.term_height - 1;
    const sm = &state.search_mode;

    var buf: [576]u8 = undefined;
    const text: []const u8 = switch (sm.phase) {
        .typing => std.fmt.bufPrint(&buf, "/{s}", .{sm.query.items}) catch "/",
        .results => if (sm.match_count == 0)
            std.fmt.bufPrint(&buf, "/{s}  [no matches]", .{sm.query.items}) catch "/"
        else
            std.fmt.bufPrint(&buf, "/{s}  [{d}/{d}]", .{ sm.query.items, sm.current, sm.match_count }) catch "/",
    };

    const bar_style: vaxis.Style = .{ .bg = .{ .index = 4 }, .fg = .{ .index = 15 } };
    // Fill the row, then overlay the prompt text one codepoint per cell so
    // multibyte queries render as their glyph rather than mojibake.
    var x: u16 = 0;
    while (x < w) : (x += 1) {
        renderer.setVaxisCell(x, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = bar_style });
    }
    x = 0;
    if (std.unicode.Utf8View.init(text)) |view| {
        var it = view.iterator();
        while (it.nextCodepointSlice()) |cp_bytes| {
            if (x >= w) break;
            renderer.setVaxisCell(x, row, .{ .char = .{ .grapheme = cp_bytes, .width = 1 }, .style = bar_style });
            x += 1;
        }
    } else |_| {
        // Invalid UTF-8 (shouldn't happen for typed input) — draw raw bytes.
        for (text) |b| {
            if (x >= w) break;
            renderer.setVaxisCell(x, row, .{ .char = .{ .grapheme = &[_]u8{b}, .width = 1 }, .style = bar_style });
            x += 1;
        }
    }
}

/// Highlight a search match's cells (inclusive viewport range, pane-local) over
/// the already-drawn focused pane. `current` matches reverse-video; others get
/// a yellow tint.
fn highlightSearchMatch(renderer: *Renderer, pane: *Pane, m: pane_search.PaneSearch.MatchViewport, current: bool) void {
    if (pane.width == 0 or pane.height == 0) return;
    var y = m.sy;
    while (y <= m.ey and y < pane.height) : (y += 1) {
        const row_start: u16 = if (y == m.sy) m.sx else 0;
        const row_end: u16 = if (y == m.ey) m.ex else pane.width - 1;
        var x = row_start;
        while (x <= row_end and x < pane.width) : (x += 1) {
            const cx = pane.x + x;
            const cy = pane.y + y;
            if (renderer.getVaxisCell(cx, cy)) |cell| {
                var c = cell;
                if (current) {
                    c.style.reverse = true;
                } else {
                    c.style.bg = .{ .index = 3 };
                    c.style.fg = .{ .index = 0 };
                }
                renderer.setVaxisCell(cx, cy, c);
            }
        }
    }
}

/// Position name the painter understands, from the pokemon widget config.
fn spritePositionName(pos: anytype) []const u8 {
    return switch (pos) {
        .topleft => "topleft",
        .topright => "topright",
        .bottomleft => "bottomleft",
        .bottomright => "bottomright",
        .center => "center",
    };
}

/// Composite every live drawing.
///
/// A drawing is bytes and a rectangle, and nothing else. It borrows no config
/// from anywhere: an earlier version could also name a painter view, which
/// meant reaching into the STATUS BAR's painter and refresh interval to render
/// something that has nothing to do with the bar. A caller that wants a painter
/// can run one and send what it draws.
///
/// Last, so a caller putting something on the screen puts it ON the screen --
/// over panes, over chrome, over the bar. A drawing that has timed out is
/// dropped here rather than on a timer: one nobody is drawing does not need
/// collecting on schedule.
fn drawDrawings(state: *State, renderer: *Renderer, stdout: std.fs.File) void {
    if (state.drawings.count() == 0) return;
    const cache = region_render.active orelse return;
    state.drawings.sweep(std.time.milliTimestamp());

    var it = state.drawings.iterator();
    while (it.next()) |d| {
        if (d.width == 0 or d.height == 0 or d.content.len == 0) continue;
        const at = d.origin(state.term_width, state.term_height, state.status_height);
        _ = region_render.drawSurface(renderer, cache, d.name, d.content, at.x, at.y, d.width, d.height, stdout);
    }
}

fn drawPaneSprite(state: *State, renderer: *Renderer, pane: *Pane, stdout: std.fs.File) void {
    const cache = region_render.active orelse return;
    const name = pane.pokemon_state.sprite_name orelse state.paneName(pane.uuid) orelse return;
    region_render.drawPaneSprite(
        renderer,
        cache,
        &state.config.tabs.status,
        name,
        pane.pokemon_state.is_shiny,
        spritePositionName(state.pop_config.widgets.pokemon.position),
        pane.x,
        pane.y,
        pane.width,
        pane.height,
        stdout,
    );
}

fn drawPaneRenderState(
    renderer: *Renderer,
    pane: *Pane,
    state: *const ghostty.RenderState,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    stdout: std.fs.File,
    occluders: []const vt_bridge.Rect,
) void {
    const root = renderer.vx.window();
    const win = root.child(.{
        .x_off = @intCast(x),
        .y_off = @intCast(y),
        .width = width,
        .height = height,
    });
    vt_bridge.drawRenderState(win, state, width, height, renderer.frame_arena.allocator(), &pane.vt, &renderer.vx, stdout, occluders);
}

/// Every visible float's outer rectangle, in the order they are drawn.
///
/// Cells are composited by whoever writes them last, but an image is not: the
/// terminal draws it from one anchor cell across as many cells as the placement
/// claims. So a pane's images have to be trimmed against whatever will be drawn
/// on top of them, and that means knowing the floats before the panes are
/// drawn rather than after.
///
/// The border is part of it -- a picture drawn over a float's frame is the same
/// bug as one drawn over its contents.
fn collectFloatRects(state: *State, out: *[MAX_TRACKED_FLOATS]vt_bridge.Rect) []const vt_bridge.Rect {
    var n: usize = 0;
    const active = state.activeFloatingIndex();

    for (state.view.float_views.items, 0..) |pane, i| {
        if (n >= out.len) break;
        if (active == i) continue; // drawn last, appended below
        if (!state.paneVisibleOnTab(pane, state.activeTabIndex())) continue;
        if (state.paneParentTab(pane)) |parent| {
            if (parent != state.activeTabIndex()) continue;
        }
        out[n] = .{
            .x = state.paneBorderX(pane),
            .y = state.paneBorderY(pane),
            .w = state.paneBorderW(pane),
            .h = state.paneBorderH(pane),
        };
        n += 1;
    }

    if (active) |idx| {
        if (n < out.len and idx < state.view.float_views.items.len) {
            const pane = state.view.float_views.items[idx];
            const on_tab = if (state.paneParentTab(pane)) |parent|
                parent == state.activeTabIndex()
            else
                true;
            if (on_tab and state.paneVisibleOnTab(pane, state.activeTabIndex())) {
                out[n] = .{
                    .x = state.paneBorderX(pane),
                    .y = state.paneBorderY(pane),
                    .w = state.paneBorderW(pane),
                    .h = state.paneBorderH(pane),
                };
                n += 1;
            }
        }
    }

    return out[0..n];
}

/// Enough for any plausible number of floats on one screen. Past this the
/// extras simply do not occlude, which is the pre-existing behaviour.
const MAX_TRACKED_FLOATS = 32;

fn composeFloatBorderLabel(state: *State, pane: *const Pane, out: *[256]u8) []const u8 {
    _ = out;
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

    if (title.len > 0) return title;
    return pokemon;
}

/// Push a namespace's cursor colour to the host terminal, or take it back.
///
/// The cursor is the terminal's own, not a cell hexe paints, so OSC 12 is the
/// only way to colour it — and OSC 12 is global, which is why this is strictly
/// change-driven. Moving the cursor within one zone emits nothing; crossing
/// into a zone with a different colour emits once. `OSC 112` restores the
/// terminal's own colour when the cursor leaves a namespace that set one.
fn applyCursorColor(state: *State, want: ?core.palette.RGB) void {
    const same = blk: {
        if (want == null and state.cursor_color == null) break :blk true;
        const a_rgb = want orelse break :blk false;
        const b_rgb = state.cursor_color orelse break :blk false;
        break :blk a_rgb.r == b_rgb.r and a_rgb.g == b_rgb.g and a_rgb.b == b_rgb.b;
    };
    if (same) return;

    var buf: [32]u8 = undefined;
    const seq = if (want) |c|
        std.fmt.bufPrint(&buf, "\x1b]12;#{x:0>2}{x:0>2}{x:0>2}\x07", .{ c.r, c.g, c.b }) catch return
    else
        // Nothing to undo if we never set one: a bare reset would clobber a
        // colour the user's own terminal config chose.
        if (!state.cursor_color_set) {
            state.cursor_color = null;
            return;
        } else "\x1b]112\x07";

    std.fs.File.stdout().writeAll(seq) catch |err| {
        core.logging.logError("terminal", "failed to set cursor colour", err);
        return;
    };
    state.cursor_color = want;
    if (want != null) state.cursor_color_set = true;
}

pub fn renderTo(state: *State, stdout: std.fs.File) !void {
    const renderer = &state.renderer;

    // Begin a new frame.
    renderer.vx.screen.clear();

    // Tab-less frame: the bare-`hexe` startup chooser is asking whether to
    // attach / load .hexe.lua before any pane exists. Everything below indexes
    // the active tab, so draw the MUX popup on an empty screen and stop.
    if (state.view.tab_views.items.len == 0) {
        // Same order as the full path: notifications first, MUX popup on top.
        notification.renderFull(&state.notifications, renderer, state.term_width, state.term_height);
        if (state.popups.getActivePopup()) |popup| {
            popup_render.draw(renderer, popup, &state.pop_config.carrier, state.term_width, state.term_height);
        }
        try render_vx.renderFrame(&renderer.vx, stdout, CursorInfo{}, state.force_full_render);
        state.force_full_render = false;
        return;
    }

    // The floats that will be drawn over the splits, gathered before anything
    // is drawn: an image has to be trimmed against them, and by the time a
    // float is drawn the pane's placement has already been written.
    var float_rect_buf: [MAX_TRACKED_FLOATS]vt_bridge.Rect = undefined;
    const float_rects = collectFloatRects(state, &float_rect_buf);

    // Draw splits into the cell buffer.
    var pane_it = state.currentLayout().splitIterator();
    while (pane_it.next()) |pane| {
        // When a pane is zoomed, render only it (at full tab bounds) and skip
        // the rest of the tiled layout.
        if (state.zoomed_pane_uuid) |zu| {
            if (!std.mem.eql(u8, &pane.*.uuid, &zu)) continue;
        }
        const render_state = pane.*.getRenderState() catch |err| {
            core.logging.logError("terminal", "failed to get split pane render state", err);
            continue;
        };
        drawPaneRenderState(renderer, pane.*, render_state, pane.*.x, pane.*.y, pane.*.width, pane.*.height, stdout, float_rects);

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
            drawPaneSprite(state, renderer, pane.*, stdout);
        }

        decor.draw(state, renderer, pane.*, stdout);
        // Last, so the meter is never painted over by chrome: it is the one
        // thing on screen that says a microphone is open.
        @import("capture.zig").draw(state, renderer, pane.*);
    }

    // Draw split borders when there are multiple splits (never while zoomed —
    // only the zoomed pane is visible).
    if (state.zoomed_pane_uuid == null and state.currentLayout().splitCount() > 1) {
        const content_height = state.term_height - state.status_height;
        borders.drawSplitBorders(renderer, state.currentLayout(), &state.config.splits, state.term_width, content_height);
    }

    // Copy-mode cursor: reverse-video the cell under the keyboard cursor.
    if (state.copy_mode.active) {
        if (state.currentLayout().getFocusedPane()) |fp| {
            const max_x: u16 = if (fp.width > 0) fp.width - 1 else 0;
            const max_y: u16 = if (fp.height > 0) fp.height - 1 else 0;
            const cx = fp.x + @min(state.copy_mode.x, max_x);
            const cy = fp.y + @min(state.copy_mode.y, max_y);
            if (renderer.getVaxisCell(cx, cy)) |cell| {
                var c = cell;
                c.style.reverse = true;
                renderer.setVaxisCell(cx, cy, c);
            }
        }
    }

    // Scrollback search (PLAN 3.3): reverse-video the current match in the
    // focused pane (drawn above), then a vim-style `/query [i/N]` bar on the
    // bottom row.
    if (state.search_mode.active) {
        if (state.currentLayout().getFocusedPane()) |fp| {
            // All on-screen matches get a yellow tint; the current one is drawn
            // last with reverse-video so it stands out.
            for (state.search_mode.visible[0..state.search_mode.visible_count]) |m| {
                highlightSearchMatch(renderer, fp, m, false);
            }
            if (state.search_mode.currentMatchViewport(fp)) |m| {
                highlightSearchMatch(renderer, fp, m, true);
            }
        }
        renderSearchPrompt(state, renderer);
    }

    // Draw visible floats (on top of splits).
    // Draw inactive floats first, then active one last so it's on top.
    var drawn_floats: usize = 0;
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
        borders.drawFloatingBorder(renderer, state.paneBorderX(pane), state.paneBorderY(pane), state.paneBorderW(pane), state.paneBorderH(pane), false, float_label, state.paneBorderColor(pane), state.paneFloatStyle(pane), state);
        if (state.float_rename_uuid) |uuid| {
            if (std.mem.eql(u8, &uuid, &pane.uuid)) {
                float_title.drawTitleEditor(state, renderer, pane, state.float_rename_buf.items);
            }
        }

        const render_state = pane.getRenderState() catch |err| {
            core.logging.logError("terminal", "failed to get floating pane render state", err);
            continue;
        };
        // Only what is drawn after this float can cover it. `collectFloatRects`
        // lists them in draw order, so that is the tail past this one.
        drawn_floats += 1;
        const above = if (drawn_floats <= float_rects.len) float_rects[drawn_floats..] else float_rects[0..0];
        drawPaneRenderState(renderer, pane, render_state, pane.x, pane.y, pane.width, pane.height, stdout, above);

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
            drawPaneSprite(state, renderer, pane, stdout);
        }

        decor.draw(state, renderer, pane, stdout);
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
            borders.drawFloatingBorder(renderer, state.paneBorderX(pane), state.paneBorderY(pane), state.paneBorderW(pane), state.paneBorderH(pane), true, active_float_label, state.paneBorderColor(pane), state.paneFloatStyle(pane), state);
            if (state.float_rename_uuid) |uuid| {
                if (std.mem.eql(u8, &uuid, &pane.uuid)) {
                    float_title.drawTitleEditor(state, renderer, pane, state.float_rename_buf.items);
                }
            }

            if (pane.getRenderState()) |render_state| {
                // Drawn last, so nothing covers it.
                drawPaneRenderState(renderer, pane, render_state, pane.x, pane.y, pane.width, pane.height, stdout, &.{});

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
                drawPaneSprite(state, renderer, pane, stdout);
            }

            decor.draw(state, renderer, pane, stdout);
        }
    }

    // Draw status bar if enabled.
    if (state.config.tabs.status.enabled) {
        statusbar.draw(renderer, state, state.allocator, &state.config, state.term_width, state.term_height, state.view.tab_views, state.activeTabIndex(), state.runtime.sessionName());
    }

    // Draw overlays (pane labels, resize info)
    if (state.overlays.hasContent() or state.overlays.shouldDim()) {
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

    // Above the panes and the bar, below a blocking popup: a drawing is
    // something a caller put on the screen, and a modal is something the user
    // has to answer.
    drawDrawings(state, renderer, stdout);

    // Draw MUX-level blocking popup overlay (on top of everything).
    if (state.popups.getActivePopup()) |popup| {
        popup_render.draw(renderer, popup, &state.pop_config.carrier, state.term_width, state.term_height);
    }

    // Gather cursor info.
    var cursor = CursorInfo{};
    var cursor_palette: ?core.palette.RGB = null;

    if (state.activeFloatingIndex()) |idx| {
        const pane = state.view.float_views.items[idx];
        const pos = pane.getCursorPos();
        cursor.x = pos.x;
        cursor.y = pos.y;
        cursor.style = pane.getCursorStyle();
        cursor.visible = pane.isCursorVisible();
        cursor_palette = pane.vt.ns_table.cursorFor(pane.vt.cursorNamespace());
    } else if (state.currentLayout().getFocusedPane()) |pane| {
        const pos = pane.getCursorPos();
        cursor.x = pos.x;
        cursor.y = pos.y;
        cursor.style = pane.getCursorStyle();
        cursor.visible = pane.isCursorVisible();
        cursor_palette = pane.vt.ns_table.cursorFor(pane.vt.cursorNamespace());
    }
    applyCursorColor(state, cursor_palette);

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
    state.force_full_render = false;

    // The frame arena backs grapheme slices stored INSIDE vx.screen cells,
    // and cells persist across frames until rewritten. Resetting the arena
    // every frame left every not-redrawn cell pointing at reused memory; the
    // next diff/gwidth pass then ran the grapheme iterator over garbage —
    // the intermittent segfault in utf8.Iterator after reattach. Reset ONLY
    // together with a full screen clear, so no cell can outlive its bytes;
    // the threshold keeps memory bounded by forcing a periodic repaint.
    const frame_arena_compact_bytes: usize = 8 * 1024 * 1024;
    if (renderer.frame_arena.queryCapacity() > frame_arena_compact_bytes) {
        renderer.invalidate();
        _ = renderer.frame_arena.reset(.retain_capacity);
        state.force_full_render = true;
        state.needs_render = true;
    }
}
