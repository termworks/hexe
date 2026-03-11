const std = @import("std");
const ghostty = @import("ghostty-vt");

const Pane = @import("pane.zig").Pane;
const Renderer = @import("render_core.zig").Renderer;

/// Pane-local mouse coordinate (viewport coordinate space).
pub const Pos = struct {
    x: u16 = 0,
    y: u16 = 0,
};

/// Terminal-buffer coordinate space ("screen" tag in ghostty).
pub const BufPos = struct {
    x: u16 = 0,
    y: u32 = 0,
};

pub const Range = struct {
    a: Pos,
    b: Pos,
};

pub const BufRange = struct {
    a: BufPos,
    b: BufPos,
};

pub const EdgeScroll = enum { none, up, down };

/// Pane-local selection state driven by mux mouse events.
///
/// Internally we store Y positions in terminal "screen" coordinates so the
/// selection stays attached to the same buffer lines when the viewport scrolls.
/// In alternate screen mode, we store local coordinates directly since there's
/// no scrollback.
pub const MouseSelection = struct {
    tab: ?usize = null,
    pane_uuid: ?[32]u8 = null,

    active: bool = false,
    dragging: bool = false,

    last_local: Pos = .{},
    edge_scroll: EdgeScroll = .none,

    anchor: BufPos = .{},
    cursor: BufPos = .{},

    has_range: bool = false,
    last_range: BufRange = .{ .a = .{}, .b = .{} },

    /// True if selection was started in alternate screen mode.
    /// In alt screen, we store local coords directly (no viewport offset).
    alt_screen_mode: bool = false,

    pub fn clear(self: *MouseSelection) void {
        self.* = .{};
    }

    pub fn begin(self: *MouseSelection, tab_idx: usize, pane_uuid: [32]u8, pane: *Pane, local_x: u16, local_y: u16) void {
        const is_alt = pane.vt.inAltScreen();
        self.tab = tab_idx;
        self.pane_uuid = pane_uuid;
        self.active = true;
        self.dragging = false;
        self.alt_screen_mode = is_alt;
        self.last_local = .{ .x = local_x, .y = local_y };
        self.edge_scroll = edgeFromLocalY(local_y, pane.height);
        // In alt screen mode, store local coords directly (no viewport offset needed).
        // In normal mode, add viewport offset so selection tracks buffer lines during scroll.
        if (is_alt) {
            self.anchor = .{ .x = local_x, .y = local_y };
        } else {
            const viewport_top = getViewportTopScreenY(pane);
            self.anchor = .{ .x = local_x, .y = viewport_top + local_y };
        }
        self.cursor = self.anchor;
        self.has_range = false;
    }

    pub fn update(self: *MouseSelection, pane: *Pane, local_x: u16, local_y: u16) void {
        if (!self.active) return;
        self.last_local = .{ .x = local_x, .y = local_y };
        self.edge_scroll = edgeFromLocalY(local_y, pane.height);
        // Use same coordinate mode as when selection started
        const next: BufPos = if (self.alt_screen_mode)
            .{ .x = local_x, .y = local_y }
        else blk: {
            const viewport_top = getViewportTopScreenY(pane);
            break :blk .{ .x = local_x, .y = viewport_top + local_y };
        };
        if (self.cursor.x != next.x or self.cursor.y != next.y) {
            self.dragging = true;
        }
        self.cursor = next;
    }

    pub fn finish(self: *MouseSelection) void {
        if (!self.active) return;
        self.active = false;
        self.edge_scroll = .none;
        if (self.dragging) {
            self.has_range = true;
            self.last_range = .{ .a = self.anchor, .b = self.cursor };
        } else {
            self.has_range = false;
        }
    }

    pub fn bufRangeForPane(self: *const MouseSelection, tab_idx: usize, pane: *Pane) ?BufRange {
        if (self.tab == null or self.pane_uuid == null) return null;
        if (self.tab.? != tab_idx) return null;
        if (!std.mem.eql(u8, &self.pane_uuid.?, &pane.uuid)) return null;

        if (self.active) return .{ .a = self.anchor, .b = self.cursor };
        if (self.has_range) return self.last_range;
        return null;
    }

    pub fn setRange(self: *MouseSelection, tab_idx: usize, pane_uuid: [32]u8, pane: *Pane, range: BufRange) void {
        self.tab = tab_idx;
        self.pane_uuid = pane_uuid;
        self.active = false;
        self.dragging = false;
        self.edge_scroll = .none;
        self.alt_screen_mode = pane.vt.inAltScreen();
        self.has_range = true;
        self.last_range = range;
    }

    /// Convert selection to pane-local viewport coordinates for overlay.
    /// Returns null if the selection isn't currently visible in this viewport.
    pub fn rangeForPane(self: *const MouseSelection, tab_idx: usize, pane: *Pane) ?Range {
        const br = self.bufRangeForPane(tab_idx, pane) orelse return null;
        const norm = normalizeBufRange(br);

        // In alt screen mode, coordinates are already local - just clamp to pane bounds.
        if (self.alt_screen_mode) {
            return .{
                .a = clampToPane(@intCast(@min(norm.start.x, 65535)), @intCast(@min(norm.start.y, 65535)), pane.width, pane.height),
                .b = clampToPane(@intCast(@min(norm.end.x, 65535)), @intCast(@min(norm.end.y, 65535)), pane.width, pane.height),
            };
        }

        // Normal mode: convert from buffer coordinates to viewport-local.
        const viewport_top = getViewportTopScreenY(pane);
        const viewport_bottom: u32 = viewport_top + @as(u32, @intCast(@max(pane.height, 1) - 1));

        // Not visible at all.
        if (norm.end.y < viewport_top or norm.start.y > viewport_bottom) return null;

        return .{
            .a = bufToLocalClipped(norm.start, viewport_top, pane.width, pane.height, true),
            .b = bufToLocalClipped(norm.end, viewport_top, pane.width, pane.height, false),
        };
    }
};

fn clampToPane(x: u16, y: u16, w: u16, h: u16) Pos {
    const cx: u16 = if (w == 0) 0 else @min(x, w - 1);
    const cy: u16 = if (h == 0) 0 else @min(y, h - 1);
    return .{ .x = cx, .y = cy };
}

fn normalizeRange(range: Range) struct { start: Pos, end: Pos } {
    const a = range.a;
    const b = range.b;
    if (a.y < b.y or (a.y == b.y and a.x <= b.x)) {
        return .{ .start = a, .end = b };
    }
    return .{ .start = b, .end = a };
}

fn normalizeBufRange(range: BufRange) struct { start: BufPos, end: BufPos } {
    const a = range.a;
    const b = range.b;
    if (a.y < b.y or (a.y == b.y and a.x <= b.x)) {
        return .{ .start = a, .end = b };
    }
    return .{ .start = b, .end = a };
}

pub fn clampLocalToPane(local_x: u16, local_y: u16, pane_w: u16, pane_h: u16) Pos {
    return clampToPane(local_x, local_y, pane_w, pane_h);
}

pub fn applyOverlay(renderer: *Renderer, pane_x: u16, pane_y: u16, pane_w: u16, pane_h: u16, range: Range, selection_color: u8) void {
    if (pane_w == 0 or pane_h == 0) return;
    const a = clampToPane(range.a.x, range.a.y, pane_w, pane_h);
    const b = clampToPane(range.b.x, range.b.y, pane_w, pane_h);
    const norm = normalizeRange(.{ .a = a, .b = b });

    var y: u16 = norm.start.y;
    while (y <= norm.end.y) : (y += 1) {
        const start_x: u16 = if (y == norm.start.y) norm.start.x else 0;
        const end_x: u16 = if (y == norm.end.y) norm.end.x else (pane_w - 1);
        var x: u16 = start_x;
        while (x <= end_x) : (x += 1) {
            var cell = renderer.getVaxisCell(pane_x + x, pane_y + y) orelse continue;
            cell.style.bg = .{ .index = selection_color };
            renderer.setVaxisCell(pane_x + x, pane_y + y, cell);
        }
    }
}

/// Apply a selection overlay but avoid highlighting trailing whitespace.
///
/// When a multi-line selection covers the full width of a line (the typical
/// "middle lines" case), the default overlay would invert all remaining cells
/// to the right margin. This function trims the overlay to the last non-space
/// cell on each visible row.
pub fn applyOverlayTrimmed(renderer: *Renderer, render_state: *const ghostty.RenderState, pane_x: u16, pane_y: u16, pane_w: u16, pane_h: u16, range: Range, selection_color: u8) void {
    if (pane_w == 0 or pane_h == 0) return;

    const a = clampToPane(range.a.x, range.a.y, pane_w, pane_h);
    const b = clampToPane(range.b.x, range.b.y, pane_w, pane_h);
    const norm = normalizeRange(.{ .a = a, .b = b });

    const row_slice = render_state.row_data.slice();
    if (row_slice.len == 0 or render_state.cols == 0 or render_state.rows == 0) {
        applyOverlay(renderer, pane_x, pane_y, pane_w, pane_h, range, selection_color);
        return;
    }

    const rows_max: u16 = @intCast(@min(@as(usize, pane_h), @min(@as(usize, render_state.rows), row_slice.len)));
    const cols_max: u16 = @intCast(@min(@as(usize, pane_w), @as(usize, render_state.cols)));
    if (rows_max == 0 or cols_max == 0) return;

    const row_cells = row_slice.items(.cells);

    var y: u16 = norm.start.y;
    while (y <= norm.end.y and y < rows_max) : (y += 1) {
        const start_x: u16 = if (y == norm.start.y) norm.start.x else 0;
        var end_x: u16 = if (y == norm.end.y) norm.end.x else (cols_max - 1);

        if (start_x >= cols_max) continue;
        if (end_x >= cols_max) end_x = cols_max - 1;

        // If the selection wants to cover to the right edge, trim it to the last
        // non-blank cell on this row.
        if (end_x == cols_max - 1) {
            const cells_slice = row_cells[@intCast(y)].slice();
            const raw_cells = cells_slice.items(.raw);
            if (raw_cells.len == 0) continue;

            var idx: i32 = @intCast(@min(@as(usize, cols_max), raw_cells.len) - 1);
            const min_idx: i32 = @intCast(start_x);
            var found: ?u16 = null;
            while (idx >= min_idx) : (idx -= 1) {
                const raw = raw_cells[@intCast(idx)];
                if (raw.wide == .spacer_tail) continue;
                var cp: u21 = raw.codepoint();
                if (cp == 0 or cp < 32 or cp == 127) cp = ' ';
                if (cp != ' ') {
                    found = @intCast(idx);
                    break;
                }
            }

            // Entire row is blank in the selected span: don't highlight it.
            if (found == null) continue;
            end_x = found.?;
        }

        if (end_x < start_x) continue;

        var x: u16 = start_x;
        while (x <= end_x) : (x += 1) {
            var cell = renderer.getVaxisCell(pane_x + x, pane_y + y) orelse continue;
            cell.style.bg = .{ .index = selection_color };
            renderer.setVaxisCell(pane_x + x, pane_y + y, cell);
        }
    }
}

/// Extract selection text from the full terminal buffer (supports scrollback).
///
/// This uses ghostty's `Screen.selectionString` to correctly unwrap soft wraps
/// and handle scrollback/history.
pub fn extractText(allocator: std.mem.Allocator, pane: *Pane, range: BufRange) ![]u8 {
    const screen = pane.vt.terminal.screens.active;
    const pages = &screen.pages;
    const norm = normalizeBufRange(range);

    const start_pin = pages.pin(.{ .screen = .{ .x = @intCast(norm.start.x), .y = norm.start.y } }) orelse return allocator.dupe(u8, "");
    const end_pin = pages.pin(.{ .screen = .{ .x = @intCast(norm.end.x), .y = norm.end.y } }) orelse return allocator.dupe(u8, "");

    const sel = ghostty.Selection.init(start_pin, end_pin, false);
    const text_z = try screen.selectionString(allocator, .{ .sel = sel, .trim = true });
    defer allocator.free(text_z);

    const slice = std.mem.sliceTo(text_z, 0);
    return dupeTrimBlankLines(allocator, slice);
}

/// Standard word separators for terminal word selection
const word_separators = [_]u21{
    ' ', '\t', '\n', '\r', // Whitespace
    '\'', '"', '`', // Quotes
    '(', ')', '[', ']', '{', '}', '<', '>', // Brackets
    ',', ';', ':', '!', '?', '.', // Punctuation
    '/', '\\', '|', '&', // Path/operators
    '=', '+', '-', '*', '%', '^', '~', '#', '@', '$', // Operators/special
};

/// Select the word under the given viewport-local coordinate.
pub fn selectWordRange(pane: *Pane, local_x: u16, local_y: u16) ?BufRange {
    const screen = pane.vt.terminal.screens.active;
    const pages = &screen.pages;
    const pin = pages.pin(.{ .viewport = .{ .x = @intCast(local_x), .y = local_y } }) orelse return null;
    const sel = screen.selectWord(pin, &word_separators) orelse return null;
    return bufRangeFromSelection(screen, sel);
}

/// Select word including adjacent separators (triple-click behavior).
/// Uses whitespace-only separators so punctuation/symbols are included.
pub fn selectWordWithSeparatorsRange(pane: *Pane, local_x: u16, local_y: u16) ?BufRange {
    const whitespace_only = [_]u21{ ' ', '\t', '\n', '\r' };
    const screen = pane.vt.terminal.screens.active;
    const pages = &screen.pages;
    const pin = pages.pin(.{ .viewport = .{ .x = @intCast(local_x), .y = local_y } }) orelse return null;
    const sel = screen.selectWord(pin, &whitespace_only) orelse return null;
    return bufRangeFromSelection(screen, sel);
}

/// Select the logical line under the given viewport-local coordinate.
pub fn selectLineRange(pane: *Pane, local_x: u16, local_y: u16) ?BufRange {
    const screen = pane.vt.terminal.screens.active;
    const pages = &screen.pages;
    const pin = pages.pin(.{ .viewport = .{ .x = @intCast(local_x), .y = local_y } }) orelse return null;
    const sel = screen.selectLine(.{ .pin = pin }) orelse return null;
    return bufRangeFromSelection(screen, sel);
}

fn bufRangeFromSelection(screen: *ghostty.Screen, sel: ghostty.Selection) ?BufRange {
    const tl_pin = sel.topLeft(screen);
    const br_pin = sel.bottomRight(screen);
    const tl_pt = screen.pages.pointFromPin(.screen, tl_pin) orelse return null;
    const br_pt = screen.pages.pointFromPin(.screen, br_pin) orelse return null;

    const tl = tl_pt.screen;
    const br = br_pt.screen;

    return .{
        .a = .{ .x = @intCast(tl.x), .y = tl.y },
        .b = .{ .x = @intCast(br.x), .y = br.y },
    };
}

fn getViewportTopScreenY(pane: *Pane) u32 {
    // Alternate screen has no scrollback - viewport is always at top
    if (pane.vt.inAltScreen()) {
        return 0;
    }
    const screen = pane.vt.terminal.screens.active;
    const pin = screen.pages.getTopLeft(.viewport);
    const pt = screen.pages.pointFromPin(.screen, pin) orelse return 0;
    return pt.screen.y;
}

fn edgeFromLocalY(local_y: u16, pane_h: u16) EdgeScroll {
    if (pane_h == 0) return .none;
    // Start scrolling when cursor is in the top/bottom margin.
    const margin: u16 = 1;
    if (local_y <= margin) return .up;
    if (local_y + margin >= pane_h - 1) return .down;
    return .none;
}

fn isBlankLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    return trimmed.len == 0;
}

fn dupeTrimBlankLines(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len == 0) return allocator.dupe(u8, "");

    // Find first non-blank line.
    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        const line = text[i..line_end];
        if (!isBlankLine(line)) {
            start = i;
            break;
        }
        if (line_end == text.len) return allocator.dupe(u8, "");
        i = line_end + 1;
    }

    // Find last non-blank line.
    var end: usize = text.len;
    var j: usize = text.len;
    while (j > start) {
        // Identify the start/end of the previous line.
        const nl = std.mem.lastIndexOfScalar(u8, text[0..j], '\n');
        const line_start: usize = if (nl) |p| p + 1 else 0;
        const line_end: usize = j;
        const line = text[line_start..line_end];
        if (!isBlankLine(line)) {
            end = line_end;
            break;
        }
        if (nl) |p| {
            if (p == 0) break;
            j = p;
        } else {
            break;
        }
    }

    if (start >= end) return allocator.dupe(u8, "");
    return allocator.dupe(u8, text[start..end]);
}

fn bufToLocalClipped(p: BufPos, viewport_top: u32, pane_w: u16, pane_h: u16, is_start: bool) Pos {
    if (pane_w == 0 or pane_h == 0) return .{};
    const viewport_bottom: u32 = viewport_top + @as(u32, @intCast(pane_h - 1));

    // Clip vertically to the viewport. For clipped ends we stretch to full
    // line so the visible portion is highlighted.
    if (p.y < viewport_top) {
        return .{ .x = if (is_start) 0 else pane_w - 1, .y = 0 };
    }
    if (p.y > viewport_bottom) {
        return .{ .x = if (is_start) 0 else pane_w - 1, .y = pane_h - 1 };
    }

    const local_y: u16 = @intCast(p.y - viewport_top);
    const local_x: u16 = if (p.x >= pane_w) pane_w - 1 else p.x;
    return .{ .x = local_x, .y = local_y };
}
