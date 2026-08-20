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
const layout = @import("statusbar_layout.zig");
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

/// Where each zone was drawn on the frame the user is looking at. Hit-testing
/// must offset by these, not by freshly computed origins: a zone that changed
/// width between draw and click would otherwise send the click to the wrong
/// segment.
threadlocal var drawn_slots: [3]layout.Slot = .{layout.Slot{}} ** 3;

/// Latches the "every zone refused" diagnostic to once per outage.
threadlocal var zones_all_silent_logged: bool = false;

pub fn deinitThreadlocals() void {
    statusbar_redraw_last_emit_ms = null;
    hover_len = 0;
    press_len = 0;
    drawn_slots = .{layout.Slot{}} ** 3;
    zones_all_silent_logged = false;
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

    if (cfg.zonesEnabled()) {
        drawZones(renderer, registry, cfg, ctx, term_width, y);
        return;
    }

    drawn_slots = .{ .{ .x = 0, .width = term_width, .drawn = true }, .{}, .{} };
    const snap = registry.snapshot(specFor(cfg, cfg.view, term_width, 1), ctx);
    if (!snap.done) return;

    // Content older than stale_ms means the painter stopped answering. Drawing
    // it unchanged left a frozen clock looking live; dimming says "this is the
    // last thing the painter said" without blanking the bar.
    _ = drawRunsDimmed(renderer, 0, y, snap.runs, term_width, snap.stale);
}

/// Zones pointed at selectors the painter does not implement leave the bar
/// blank, which looks like hexe is broken. Name the selectors that were asked
/// for: the fix is always either the painter or those names.
fn warnIfEveryZoneSilent(cfg: *const core.config.StatusBarConfig, snaps: [3]regions.Snapshot) void {
    for (snaps) |s| {
        if (s.done) {
            zones_all_silent_logged = false;
            return;
        }
    }
    if (zones_all_silent_logged) return;
    zones_all_silent_logged = true;
    log.warn("no status zone answered; asked for {s} / {s} / {s}", .{
        cfg.zone_left orelse "(unset)",
        cfg.zone_center orelse "(unset)",
        cfg.zone_right orelse "(unset)",
    });
}

/// The zone view configured for a slot, or null when that zone is unused.
fn zoneView(cfg: *const core.config.StatusBarConfig, zone: layout.Zone) ?[]const u8 {
    return switch (zone) {
        .left => cfg.zone_left,
        .center => cfg.zone_center,
        .right => cfg.zone_right,
    };
}

/// One spec per zone, distinguished by `key_suffix` so the three share no cache
/// entry. Asked at the full bar width: the painter composes freely and hexe
/// places what comes back.
fn zoneSpec(cfg: *const core.config.StatusBarConfig, zone: layout.Zone, view: []const u8, term_width: u16) regions.Spec {
    var spec = specFor(cfg, view, term_width, 1);
    spec.key_suffix = @tagName(zone);
    return spec;
}

fn drawZones(
    renderer: *Renderer,
    registry: *regions.Registry,
    cfg: *const core.config.StatusBarConfig,
    ctx: regions.RequestContext,
    term_width: u16,
    y: u16,
) void {
    var snaps: [3]regions.Snapshot = .{regions.Snapshot{}} ** 3;
    var widths: [3]u16 = .{ 0, 0, 0 };

    for (0..3) |i| {
        const zone: layout.Zone = @enumFromInt(i);
        const view = zoneView(cfg, zone) orelse continue;
        snaps[i] = registry.snapshot(zoneSpec(cfg, zone, view, term_width), ctx);
        // A zone that has not answered yet, or answered `ok:false`, measures
        // zero and takes no width.
        if (snaps[i].done) widths[i] = runsWidth(snaps[i].runs);
    }

    warnIfEveryZoneSilent(cfg, snaps);

    var shrink: [3]layout.Zone = undefined;
    for (cfg.shrink, 0..) |idx, i| shrink[i] = @enumFromInt(@min(idx, 2));

    const placement = layout.place(term_width, widths, shrink);
    drawn_slots = placement.slots;

    // Staleness is per zone: one silent painter dims its own zone while the
    // others stay live.
    for (placement.slots, 0..) |slot, i| {
        if (!slot.drawn) continue;
        _ = drawRunsDimmed(renderer, slot.x, y, snaps[i].runs, slot.width, snaps[i].stale);
    }
}

/// Walks every zone's hit rectangles, translated from zone-local coordinates
/// into bar coordinates. Yielding translated copies keeps callers written
/// against plain `hit.contains(x, 0)`.
const HitIter = struct {
    zones: [3]Zone = .{Zone{}} ** 3,
    zi: usize = 0,
    hi: usize = 0,

    const Zone = struct {
        hits: []const regions.Interactive = &.{},
        origin: u16 = 0,
        width: u16 = 0,
    };

    fn next(self: *HitIter) ?regions.Interactive {
        while (self.zi < self.zones.len) {
            const zone = self.zones[self.zi];
            if (self.hi < zone.hits.len) {
                var hit = zone.hits[self.hi];
                self.hi += 1;
                // A painter reports rectangles against the width it was given,
                // which is the whole bar, not the slot it ended up in. Left
                // unclamped, a zone's rectangle answers for columns another
                // zone is drawn on.
                if (hit.x >= zone.width) continue;
                hit.width = @min(hit.width, zone.width - hit.x);
                hit.x = hit.x +| zone.origin;
                return hit;
            }
            self.zi += 1;
            self.hi = 0;
        }
        return null;
    }
};

/// Re-read the painter's last reported hit rectangles. Cheap: no fetch is
/// started, this is the same completed frame the bar was drawn from.
fn currentHits(state: *State, config: *const core.Config, term_width: u16, tabs: anytype, active_tab: usize, session_name: []const u8) HitIter {
    const registry = regions.active orelse return .{};
    const cfg = &config.tabs.status;
    var tab_names: [16][]const u8 = undefined;
    const ctx = buildContext(state, tabs, active_tab, session_name, &tab_names);

    var iter: HitIter = .{};
    if (!cfg.zonesEnabled()) {
        const snap = registry.snapshot(specFor(cfg, cfg.view, term_width, 1), ctx);
        iter.zones[0] = .{ .hits = snap.hits, .origin = 0, .width = term_width };
        return iter;
    }

    // Origins come from the drawn frame, never from a fresh placement.
    for (0..3) |i| {
        const slot = drawn_slots[i];
        if (!slot.drawn) continue;
        const zone: layout.Zone = @enumFromInt(i);
        const view = zoneView(cfg, zone) orelse continue;
        const snap = registry.snapshot(zoneSpec(cfg, zone, view, term_width), ctx);
        iter.zones[i] = .{ .hits = snap.hits, .origin = slot.x, .width = slot.width };
    }
    return iter;
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

    var hits = currentHits(state, config, term_width, tabs, active_tab, session_name);
    while (hits.next()) |hit| {
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

    var hits = currentHits(state, config, term_width, tabs, active_tab, session_name);
    while (hits.next()) |hit| {
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
    var hits = currentHits(state, config, term_width, tabs, active_tab, session_name);
    while (hits.next()) |hit| {
        if (hit.contains(x, 0)) return setSlot(&hover_buf, &hover_len, hit.id);
    }
    return setSlot(&hover_buf, &hover_len, "");
}

/// Ask the painter for a pane or float title. Empty until the first response.
pub fn titleRuns(state: *const State, title: []const u8, width: u16, is_float: bool, active: bool) []const regions.Run {
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
        // The focused float and a background one must be distinguishable by the
        // painter; this used to report is_float, i.e. always true for floats.
        .active = active,
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
    return drawRunsDimmed(renderer, start_x, y, runs, max_width, false);
}

pub fn drawRunsDimmed(renderer: *Renderer, start_x: u16, y: u16, runs: []const regions.Run, max_width: u16, dim: bool) u16 {
    const limit = start_x +| max_width;
    var x = start_x;
    var scratch: [512]u8 = undefined;
    for (runs) |run| {
        if (x >= limit) break;
        const text = sanitizeLabelUtf8(run.text, &scratch);
        if (text.len == 0) continue;
        const clipped = clipTextToWidth(text, limit -| x);
        if (clipped.len == 0) break;
        var style = run.style;
        if (dim) {
            style.dim = true;
            style.bold = false;
        }
        x = drawStyledText(renderer, x, y, clipped, style);
    }
    return x;
}

pub fn runsWidth(runs: []const regions.Run) u16 {
    var width: usize = 0;
    for (runs) |run| width += vaxis.gwidth.gwidth(run.text, .unicode);
    return @intCast(@min(width, std.math.maxInt(u16)));
}
