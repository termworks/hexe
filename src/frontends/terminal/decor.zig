//! The twelve addressable slots around a pane.
//!
//! Each edge carries three: `start`, `center`, `end`. On the top and bottom that
//! is the border row, generalising the single float title into three
//! independently addressed pieces. On the left and right it is a strip of
//! reserved columns — a vertical row of buttons, the shape a phone emulator puts
//! beside its screen.
//!
//! The two axes are drawn differently on purpose. A border row is one cell tall,
//! so it takes styled runs and hexe places them. A side strip is a rectangle, so
//! it takes a painter-drawn surface and hexe blits it: icons stack vertically,
//! and the painter never has to encode a layout in a single line of text.
//!
//! Side strips are reserved in `layout.zig` and `state.zig` before the pane is
//! sized, so the program inside really is narrower. A panel is not an overlay;
//! nothing is ever drawn on top of a program's output.

const std = @import("std");
const core = @import("core");

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;
const Renderer = @import("render_core.zig").Renderer;
const region_render = @import("region_render.zig");
const statusbar = @import("statusbar.zig");
const borders = @import("borders.zig");

pub const Edge = enum { top, bottom, left, right };
pub const Slot = enum { start, center, end };

pub const Rect = struct { x: u16, y: u16, w: u16, h: u16 };

/// A slot and where it landed, so a click can be resolved against the same
/// rectangle that was drawn.
pub const Hit = struct {
    edge: Edge,
    slot: Slot,
    view: []const u8,
    rect: Rect,
};

pub fn edgeOf(cfg: *const core.config.DecorConfig, edge: Edge) *const core.config.DecorEdge {
    return switch (edge) {
        .top => &cfg.top,
        .bottom => &cfg.bottom,
        .left => &cfg.left,
        .right => &cfg.right,
    };
}

/// The painter view configured for a slot, or null when that slot is unused.
pub fn slotView(cfg: *const core.config.DecorConfig, edge: Edge, slot: Slot) ?[]const u8 {
    const e = edgeOf(cfg, edge);
    return switch (slot) {
        .start => e.start,
        .center => e.center,
        .end => e.end,
    };
}

/// The reserved strip beside a pane, in absolute screen coordinates.
///
/// The pane's own origin is already inset by the strip width, so the strip is
/// the columns immediately outside it. Deriving the rect from the pane rather
/// than from the border keeps this correct for both floats and splits, which
/// compute their frames in different places.
fn stripRect(state: *const State, pane: *const Pane, edge: Edge) ?Rect {
    const cfg = &state.config.decor;
    if (pane.height == 0) return null;
    return switch (edge) {
        .left => blk: {
            const w = cfg.leftInset();
            if (w == 0 or pane.x < w) break :blk null;
            break :blk .{ .x = pane.x - w, .y = pane.y, .w = w, .h = pane.height };
        },
        .right => blk: {
            const w = cfg.rightInset();
            if (w == 0) break :blk null;
            break :blk .{ .x = pane.x + pane.width, .y = pane.y, .w = w, .h = pane.height };
        },
        else => null,
    };
}

/// A strip's three slots split its height into thirds, top to bottom.
///
/// A fixed split rather than one sized to its content: the painter is asked for
/// a surface and must be told the height up front, and a strip whose buttons
/// moved as neighbours changed size would be unclickable in practice.
fn stripSlotRect(strip: Rect, slot: Slot) ?Rect {
    const third = strip.h / 3;
    if (third == 0) return null;
    return switch (slot) {
        .start => .{ .x = strip.x, .y = strip.y, .w = strip.w, .h = third },
        .center => .{ .x = strip.x, .y = strip.y + third, .w = strip.w, .h = third },
        // The remainder goes to the last slot so the three always cover the
        // strip exactly, whatever the height divides to.
        .end => .{ .x = strip.x, .y = strip.y + third * 2, .w = strip.w, .h = strip.h - third * 2 },
    };
}

/// Where a border-row slot of `width` cells sits.
fn rowSlotRect(state: *const State, pane: *const Pane, edge: Edge, slot: Slot, width: u16) ?Rect {
    const outer_x = state.paneBorderX(pane);
    const outer_y = state.paneBorderY(pane);
    const outer_w = state.paneBorderW(pane);
    const outer_h = state.paneBorderH(pane);
    if (outer_w < 3 or outer_h < 3 or width == 0) return null;

    const inner = borders.floatTitleInnerWidth(outer_w);
    if (inner == 0) return null;
    const w = @min(width, inner);

    const y = switch (edge) {
        .top => outer_y,
        .bottom => outer_y + outer_h - 1,
        else => return null,
    };
    const x = switch (slot) {
        .start => outer_x + 2,
        .center => outer_x + (outer_w -| w) / 2,
        .end => outer_x + outer_w -| 2 -| w,
    };
    return .{ .x = x, .y = y, .w = w, .h = 1 };
}

/// One painter request per slot.
///
/// `key_suffix` carries the pane and the slot together: without it every pane
/// would share one cache entry per view and they would all show whatever was
/// fetched last.
fn specFor(
    cfg: *const core.config.StatusBarConfig,
    view: []const u8,
    mode: core.regions.Mode,
    w: u16,
    h: u16,
    key: []const u8,
) core.regions.Spec {
    return .{
        .selector = view,
        .mode = mode,
        .width = w,
        .height = h,
        .socket_path = cfg.socket,
        .refresh_ms = @intCast(cfg.refresh_ms),
        .stale_ms = @intCast(cfg.stale_ms),
        .key_suffix = key,
        .command = cfg.command,
    };
}

/// Identity of one slot on one pane, used both as a cache key and as the
/// surface key. Written into `buf`, which the caller keeps alive.
fn slotKey(buf: []u8, pane: *const Pane, edge: Edge, slot: Slot) []const u8 {
    return std.fmt.bufPrint(buf, "{s}.{s}.{s}", .{
        pane.uuid[0..8],
        @tagName(edge),
        @tagName(slot),
    }) catch buf[0..0];
}

fn contextFor(extra: []const u8) core.regions.RequestContext {
    return .{
        .now_ms = @intCast(std.time.milliTimestamp()),
        .home = std.posix.getenv("HOME"),
        .extra_json = extra,
    };
}

/// The slot's own identity, handed to the painter so one view can serve several
/// slots and still know which one it is drawing.
fn extraJson(buf: []u8, state: *State, pane: *const Pane, edge: Edge, slot: Slot) []const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const w = stream.writer();
    w.writeAll("\"decor_edge\":") catch return "";
    core.regions.writeJsonString(w, @tagName(edge)) catch return "";
    w.writeAll(",\"decor_slot\":") catch return "";
    core.regions.writeJsonString(w, @tagName(slot)) catch return "";
    // The pane name is user-settable, so it is escaped rather than spliced.
    if (state.paneName(pane.uuid)) |name| {
        w.writeAll(",\"pane_name\":") catch return "";
        core.regions.writeJsonString(w, name) catch return "";
    }
    // What a share indicator is drawn from. Handed to every slot rather than
    // fetched by the painter, because the painter has no way to ask: the
    // observer sockets are open in a different process.
    const proc = state.getPaneProc(pane.uuid);
    const observers: u16 = if (proc) |p| p.observers else 0;
    const blocked = if (proc) |p| p.share_blocked else false;
    w.print(",\"observers\":{d},\"shared\":{s},\"share_blocked\":{s}", .{
        observers,
        if (observers > 0) "true" else "false",
        if (blocked) "true" else "false",
    }) catch return "";
    // The pane's own uuid, so a button can name its target instead of relying
    // on whichever pane happens to be focused when the click lands.
    w.writeAll(",\"pane_uuid\":") catch return "";
    core.regions.writeJsonString(w, pane.uuid[0..]) catch return "";
    return stream.getWritten();
}

/// Draw every configured slot around one pane.
pub fn draw(state: *State, renderer: *Renderer, pane: *Pane, stdout: std.fs.File) void {
    const cfg = &state.config.decor;
    if (!cfg.any()) return;
    const registry = core.regions.active orelse return;
    const cache = region_render.active orelse return;
    const status = &state.config.tabs.status;

    for ([_]Edge{ .top, .bottom, .left, .right }) |edge| {
        for ([_]Slot{ .start, .center, .end }) |slot| {
            const view = slotView(cfg, edge, slot) orelse continue;

            var key_buf: [64]u8 = undefined;
            const key = slotKey(&key_buf, pane, edge, slot);
            var extra_buf: [768]u8 = undefined;
            const extra = extraJson(&extra_buf, state, pane, edge, slot);
            const ctx = contextFor(extra);

            switch (edge) {
                .left, .right => {
                    const strip = stripRect(state, pane, edge) orelse continue;
                    const r = stripSlotRect(strip, slot) orelse continue;
                    const snap = registry.snapshot(specFor(status, view, .surface, r.w, r.h, key), ctx);
                    if (!snap.done or snap.ansi.len == 0) continue;
                    _ = region_render.drawSurface(renderer, cache, key, snap.ansi, r.x, r.y, r.w, r.h, stdout);
                },
                .top, .bottom => {
                    // Asked at the full border width; hexe places what comes
                    // back, the same bargain the status zones strike.
                    const inner = borders.floatTitleInnerWidth(state.paneBorderW(pane));
                    if (inner == 0) continue;
                    const snap = registry.snapshot(specFor(status, view, .run, inner, 1, key), ctx);
                    if (!snap.done) continue;
                    const painted = statusbar.runsWidth(snap.runs);
                    if (painted == 0) continue;
                    const r = rowSlotRect(state, pane, edge, slot, painted) orelse continue;
                    _ = statusbar.drawRuns(renderer, r.x, r.y, snap.runs, r.w);
                },
            }
        }
    }
}

/// Which slot a screen position falls in, if any.
///
/// Recomputed from the same geometry `draw` uses rather than cached from the
/// last frame, so a click can never be resolved against an origin the pane has
/// since moved away from.
pub fn hitTest(state: *State, pane: *Pane, px: u16, py: u16) ?Hit {
    const cfg = &state.config.decor;
    if (!cfg.any()) return null;

    for ([_]Edge{ .left, .right }) |edge| {
        const strip = stripRect(state, pane, edge) orelse continue;
        for ([_]Slot{ .start, .center, .end }) |slot| {
            const view = slotView(cfg, edge, slot) orelse continue;
            const r = stripSlotRect(strip, slot) orelse continue;
            if (px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h) {
                return .{ .edge = edge, .slot = slot, .view = view, .rect = r };
            }
        }
    }
    return null;
}

/// The action a click on one pane's panels asks for, if it hit a button.
///
/// The painter declares its own buttons inside the surface it drew, in
/// coordinates local to that surface. hexe knows where the surface was put, so
/// it does the translating; the painter never has to know where on screen it
/// ended up.
pub fn hitTestAction(state: *State, pane: *Pane, px: u16, py: u16, button: u8) ?[]const u8 {
    const hit = hitTest(state, pane, px, py) orelse return null;
    const registry = core.regions.active orelse return null;

    var key_buf: [64]u8 = undefined;
    const key = slotKey(&key_buf, pane, hit.edge, hit.slot);
    var extra_buf: [768]u8 = undefined;
    const extra = extraJson(&extra_buf, state, pane, hit.edge, hit.slot);
    const spec = specFor(&state.config.tabs.status, hit.view, .surface, hit.rect.w, hit.rect.h, key);
    const snap = registry.snapshot(spec, contextFor(extra));
    if (!snap.done) return null;

    for (snap.hits) |h| {
        if (!h.contains(px - hit.rect.x, py - hit.rect.y)) continue;
        const action = h.actionFor(button);
        if (action.len == 0) continue;
        return action;
    }
    return null;
}

/// The same question asked of every pane on screen.
///
/// Panels sit outside their pane, so the pane-under-cursor search cannot find
/// them: a click on a panel is not a click on any pane's rectangle. Floats come
/// first, matching the order they are drawn in.
pub fn hitTestVisible(state: *State, px: u16, py: u16, button: u8) ?[]const u8 {
    if (!state.config.decor.any()) return null;

    var fi: usize = state.view.float_views.items.len;
    while (fi > 0) {
        fi -= 1;
        const fp = state.view.float_views.items[fi];
        if (hitTestAction(state, fp, px, py, button)) |a| return a;
    }

    var it = state.currentLayout().splits.valueIterator();
    while (it.next()) |pane_ptr| {
        if (hitTestAction(state, pane_ptr.*, px, py, button)) |a| return a;
    }
    return null;
}
