//! The status bar, painted by an external program.
//!
//! hexe does not evaluate segments. It collects the state a painter needs,
//! asks it for the `status` view at the bar's full width, and composites the
//! styled runs that come back. Layout, colors, tabs, spinners and every other
//! decision about what the bar looks like belong to the painter.
//!
//! The fetch is asynchronous (see `core.regions`): drawing reads whatever
//! landed last and never waits, so a slow or dead painter costs a stale bar
//! rather than a frozen frame.

const std = @import("std");
const core = @import("core");
const vaxis = @import("vaxis");
const log = std.log.scoped(.terminal_statusbar);

const State = @import("state.zig").State;
const Renderer = @import("render_core.zig").Renderer;
const lua_events = @import("lua_events.zig");
const Color = core.style.Color;
const Style = core.style.Style;
const regions = core.regions;
const sanitizeLabelUtf8 = @import("text_width.zig").sanitizeLabelUtf8;
const clipTextToWidth = @import("text_width.zig").clipTextToWidth;

/// Action prefix the painter uses to ask for a tab switch: `tab.select.<n>`,
/// one-based to match how tabs are named everywhere else.
const TAB_SELECT_PREFIX = "tab.select.";

threadlocal var statusbar_redraw_last_emit_ms: ?u64 = null;

/// Which interactive region the pointer is over, and which is held down.
/// Forwarded to the painter so it can style them; hexe does not restyle.
threadlocal var hover_buf: [96]u8 = undefined;
threadlocal var hover_len: usize = 0;
threadlocal var press_buf: [96]u8 = undefined;
threadlocal var press_len: usize = 0;
threadlocal var press_button: u8 = 0;

fn hoveredId() []const u8 {
    return hover_buf[0..hover_len];
}

fn pressedId() []const u8 {
    return press_buf[0..press_len];
}

fn setSlot(buf: []u8, len: *usize, value: []const u8) bool {
    const n = @min(value.len, buf.len);
    if (len.* == n and std.mem.eql(u8, buf[0..n], value[0..n])) return false;
    @memcpy(buf[0..n], value[0..n]);
    len.* = n;
    return true;
}

pub fn deinitThreadlocals() void {
    statusbar_redraw_last_emit_ms = null;
    hover_len = 0;
    press_len = 0;
}

fn tabTitleForDisplay(state: *State, tab_idx: usize, tab: anytype, use_basename: bool) []const u8 {
    if (use_basename) {
        if (tab.layout.getFocusedPane()) |pane| {
            if (state.paneRealCwd(pane)) |p| {
                const base = std.fs.path.basename(p);
                return if (base.len == 0) "/" else base;
            }
        }
    }
    return state.runtime.tabName(tab_idx) orelse "tab";
}

/// The painter request for a named view at a given size.
pub fn specFor(cfg: *const core.config.StatusBarConfig, view: []const u8, width: u16, height: u16) regions.Spec {
    return .{
        .selector = view,
        .mode = .run,
        .width = width,
        .height = height,
        .socket_path = cfg.socket,
        .refresh_ms = @intCast(cfg.refresh_ms),
        .stale_ms = @intCast(cfg.stale_ms),
        .command = cfg.command,
    };
}

/// Hand the focused pane's OSC 9;4 progress to the painter.
fn applyProgress(ctx: *regions.RequestContext, pane: anytype) void {
    const p = pane.osc_progress;
    ctx.progress_state = switch (p.state) {
        .inactive => "inactive",
        .in_progress => "in_progress",
        .error_state => "error",
        .indeterminate => "indeterminate",
        .paused => "paused",
    };
    ctx.progress_pct = p.percentage;
}

/// Everything the painter is told about the session. Built once per draw and
/// reused for hit-testing so the two always agree on what was rendered.
pub fn buildContext(
    state: *State,
    tabs: anytype,
    active_tab: usize,
    session_name: []const u8,
    tab_names: *[16][]const u8,
) regions.RequestContext {
    var ctx = regions.RequestContext{
        .now_ms = @intCast(std.time.milliTimestamp()),
        .home = std.posix.getenv("HOME"),
        .session_name = session_name,
        .hover_region = hoveredId(),
        .press_region = pressedId(),
        .press_button = press_button,
    };

    if (state.getCurrentFocusedUuid()) |uuid| {
        if (state.activeFloatingIndex() != null) {
            const info_opt = state.getPaneShell(uuid);
            const needs_start = if (info_opt) |info| info.started_at_ms == null else true;
            if (needs_start) state.setPaneShellRunning(uuid, false, ctx.now_ms, null, null, null);
        }
        if (state.getPaneShell(uuid)) |info| {
            if (info.cmd) |c| ctx.last_command = c;
            if (info.cwd) |c| ctx.cwd = c;
            if (info.status) |st| ctx.exit_status = st;
            if (info.duration_ms) |d| ctx.duration_ms = d;
            if (info.jobs) |j| ctx.jobs = j;
            ctx.shell_running = info.running;
            ctx.started_at_ms = info.started_at_ms;
        }
    }

    if (state.activeFloatingIndex()) |idx| {
        if (idx < state.view.float_views.items.len) {
            const fp = state.view.float_views.items[idx];
            ctx.alt_screen = fp.vt.inAltScreen();
            ctx.title = state.paneFloatTitle(fp) orelse state.paneName(fp.uuid);
            ctx.adhoc_float = state.paneFloatKey(fp) == 0;
            applyProgress(&ctx, fp);
        }
    } else if (state.currentLayout().getFocusedPane()) |pane| {
        ctx.alt_screen = pane.vt.inAltScreen();
        ctx.title = state.paneName(pane.uuid);
        applyProgress(&ctx, pane);
    }

    var count: usize = 0;
    var active_display: ?usize = null;
    for (tabs.items, 0..) |*tab, ti| {
        const name = tabTitleForDisplay(state, ti, tab, true);
        if (count < tab_names.len) {
            tab_names[count] = name;
            if (ti == active_tab) active_display = count;
            count += 1;
        } else if (ti == active_tab) {
            tab_names[tab_names.len - 1] = name;
            active_display = tab_names.len - 1;
        }
    }
    ctx.tabs = tab_names[0..count];
    ctx.active_tab = active_display orelse 0;
    return ctx;
}

fn emitStatusbarRedrawEventIfDue(state: *State, ctx: *const regions.RequestContext, term_width: u16, term_height: u16, active_tab: usize) void {
    const rt = state.config._lua_runtime orelse return;
    const raw = std.posix.getenv("HEXE_STATUSBAR_REDRAW_EVENT_MS") orelse "120";
    const interval_ms = std.fmt.parseInt(u64, raw, 10) catch 120;
    if (statusbar_redraw_last_emit_ms) |last| {
        if (ctx.now_ms >= last and (ctx.now_ms - last) < interval_ms) return;
    }
    statusbar_redraw_last_emit_ms = ctx.now_ms;

    rt.lua.createTable(0, 9);
    _ = rt.lua.pushString("statusbar_redraw");
    rt.lua.setField(-2, "event");
    rt.lua.pushInteger(@intCast(ctx.now_ms));
    rt.lua.setField(-2, "now_ms");
    rt.lua.pushInteger(term_width);
    rt.lua.setField(-2, "term_width");
    rt.lua.pushInteger(term_height);
    rt.lua.setField(-2, "term_height");
    rt.lua.pushInteger(@intCast(active_tab + 1));
    rt.lua.setField(-2, "active_tab");
    rt.lua.pushInteger(@intCast(ctx.tabs.len));
    rt.lua.setField(-2, "tab_count");
    rt.lua.pushBoolean(ctx.shell_running);
    rt.lua.setField(-2, "shell_running");
    rt.lua.pushInteger(@intCast(interval_ms));
    rt.lua.setField(-2, "interval_ms");

    lua_events.emitWithState(state, rt, "statusbar_redraw");
}

pub fn draw(
    renderer: *Renderer,
    state: *State,
    allocator: std.mem.Allocator,
    config: *const core.Config,
    term_width: u16,
    term_height: u16,
    tabs: anytype,
    active_tab: usize,
    session_name: []const u8,
) void {
    _ = allocator;
    if (term_height == 0) return;
    const cfg = &config.tabs.status;
    const y = term_height - 1;

    for (0..term_width) |xi| {
        renderer.setVaxisCell(@intCast(xi), y, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{},
        });
    }

    var tab_names: [16][]const u8 = undefined;
    const ctx = buildContext(state, tabs, active_tab, session_name, &tab_names);
    emitStatusbarRedrawEventIfDue(state, &ctx, term_width, term_height, active_tab);

    const registry = regions.active orelse return;
    const snap = registry.snapshot(specFor(cfg, cfg.view, term_width, 1), ctx);
    if (!snap.done) return;

    _ = drawRuns(renderer, 0, y, snap.runs, term_width);
}

/// Re-read the painter's last reported hit rectangles. Cheap: no fetch is
/// started, this is the same completed frame the bar was drawn from.
fn currentHits(state: *State, config: *const core.Config, term_width: u16, tabs: anytype, active_tab: usize, session_name: []const u8) []const regions.Interactive {
    const registry = regions.active orelse return &.{};
    var tab_names: [16][]const u8 = undefined;
    const ctx = buildContext(state, tabs, active_tab, session_name, &tab_names);
    const snap = registry.snapshot(specFor(&config.tabs.status, config.tabs.status.view, term_width, 1), ctx);
    return snap.hits;
}

/// A click on a region whose action is `tab.select.<n>` selects that tab.
pub fn hitTestTab(
    state: *State,
    allocator: std.mem.Allocator,
    config: *const core.Config,
    term_width: u16,
    term_height: u16,
    tabs: anytype,
    active_tab: usize,
    session_name: []const u8,
    x: u16,
    y: u16,
) ?usize {
    _ = allocator;
    if (!config.tabs.status.enabled or term_height == 0) return null;
    if (y != term_height - 1) return null;

    for (currentHits(state, config, term_width, tabs, active_tab, session_name)) |hit| {
        if (!hit.contains(x, 0)) continue;
        const action = hit.actionFor(0);
        if (!std.mem.startsWith(u8, action, TAB_SELECT_PREFIX)) continue;
        const n = std.fmt.parseInt(usize, action[TAB_SELECT_PREFIX.len..], 10) catch continue;
        if (n == 0 or n > tabs.items.len) continue;
        return n - 1;
    }
    return null;
}

/// Any other action name is handed back for the caller to run.
pub fn hitTestAction(
    state: *State,
    allocator: std.mem.Allocator,
    config: *const core.Config,
    term_width: u16,
    term_height: u16,
    tabs: anytype,
    active_tab: usize,
    session_name: []const u8,
    x: u16,
    y: u16,
    button: u8,
) ?[]const u8 {
    _ = allocator;
    if (!config.tabs.status.enabled or term_height == 0) return null;
    if (y != term_height - 1) return null;

    for (currentHits(state, config, term_width, tabs, active_tab, session_name)) |hit| {
        if (!hit.contains(x, 0)) continue;
        const action = hit.actionFor(button);
        if (action.len == 0) continue;
        if (std.mem.startsWith(u8, action, TAB_SELECT_PREFIX)) continue;
        _ = setSlot(&press_buf, &press_len, hit.id);
        press_button = button;
        return action;
    }
    return null;
}

/// Resolve and record the hovered region for a pointer position.
pub fn noteHover(state: *State, config: *const core.Config, term_width: u16, term_height: u16, tabs: anytype, active_tab: usize, session_name: []const u8, x: u16, y: u16) bool {
    if (term_height == 0 or y != term_height - 1) return setSlot(&hover_buf, &hover_len, "");
    for (currentHits(state, config, term_width, tabs, active_tab, session_name)) |hit| {
        if (hit.contains(x, 0)) return setSlot(&hover_buf, &hover_len, hit.id);
    }
    return setSlot(&hover_buf, &hover_len, "");
}

/// Ask the painter for a pane or float title. Empty until the first response.
pub fn titleRuns(state: *const State, title: []const u8, width: u16, is_float: bool) []const regions.Run {
    const registry = regions.active orelse return &.{};
    const cfg = &state.config.tabs.status;
    const view = if (is_float) cfg.float_title_view else cfg.container_title_view;
    // Keyed by the title: every float would otherwise share one entry and
    // overwrite each other's frame.
    var spec = specFor(cfg, view, width, 1);
    spec.key_suffix = title;
    const snap = registry.snapshot(spec, .{
        .now_ms = @intCast(std.time.milliTimestamp()),
        .home = std.posix.getenv("HOME"),
        .title = title,
        .active = is_float,
    });
    return snap.runs;
}

pub fn clearPress() void {
    press_len = 0;
    press_button = 0;
}

pub fn countDisplayWidth(text: []const u8) u16 {
    return @intCast(@min(vaxis.gwidth.gwidth(text, .unicode), std.math.maxInt(u16)));
}

pub fn measureText(text: []const u8) u16 {
    return countDisplayWidth(text);
}

fn styleToVaxis(style: Style) vaxis.Style {
    return .{
        .fg = style.fg.toVaxis(),
        .bg = style.bg.toVaxis(),
        .bold = style.bold,
        .italic = style.italic,
        .dim = style.dim,
        .ul_style = if (style.underline) .single else .off,
    };
}

pub fn drawStyledText(renderer: *Renderer, start_x: u16, y: u16, text: []const u8, style: Style) u16 {
    const screen_w = renderer.screenWidth();
    const screen_h = renderer.vx.screen.height;
    if (start_x >= screen_w or y >= screen_h) return start_x;

    // Status text often comes from short-lived buffers. Keep the printed text
    // in the frame arena so vaxis never sees dangling slices.
    const owned_text = renderer.frame_arena.allocator().dupe(u8, text) catch text;

    const row = renderer.vx.window().child(.{
        .x_off = @intCast(start_x),
        .y_off = @intCast(y),
        .width = screen_w - start_x,
        .height = 1,
    });

    const seg = vaxis.Segment{ .text = owned_text, .style = styleToVaxis(style) };
    const res = row.print(&.{seg}, .{ .row_offset = 0, .col_offset = 0, .wrap = .none, .commit = true });
    return start_x + @min(res.col, row.width);
}

/// Draw a painter's runs into a bounded span, clipping to `max_width`. Text is
/// sanitized here, so nothing a painter emits can address cells outside it.
pub fn drawRuns(renderer: *Renderer, start_x: u16, y: u16, runs: []const regions.Run, max_width: u16) u16 {
    const limit = start_x +| max_width;
    var x = start_x;
    var scratch: [512]u8 = undefined;
    for (runs) |run| {
        if (x >= limit) break;
        const text = sanitizeLabelUtf8(run.text, &scratch);
        if (text.len == 0) continue;
        const clipped = clipTextToWidth(text, limit -| x);
        if (clipped.len == 0) break;
        x = drawStyledText(renderer, x, y, clipped, run.style);
    }
    return x;
}

pub fn runsWidth(runs: []const regions.Run) u16 {
    var width: usize = 0;
    for (runs) |run| width += vaxis.gwidth.gwidth(run.text, .unicode);
    return @intCast(@min(width, std.math.maxInt(u16)));
}
