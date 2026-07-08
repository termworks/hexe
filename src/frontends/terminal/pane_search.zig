//! Scrollback text search (PLAN.md 3.3) — a modal query over a pane's full
//! ghostty scrollback using `ghostty.search.Screen` (ScreenSearch), with match
//! navigation. Built as a self-contained state machine so its lifetime surface
//! (it holds a `*Screen` + tracked pins while active) stays isolated and is
//! torn down explicitly on every pane-lifecycle change by the owner.
//!
//! Flow: `enter` → type into `query` (phase `.typing`) → `run` builds the search
//! and jumps to the first match (phase `.results`) → `next`/`prev` navigate,
//! each scrolling the viewport to the match → `exit` frees the search.

const std = @import("std");
const ghostty = @import("ghostty-vt");
const core = @import("core");
const Pane = @import("pane.zig").Pane;

const ScreenSearch = ghostty.search.Screen;

pub const MAX_QUERY_LEN: usize = 256;
/// Cap on matches highlighted in the viewport at once (dense pages).
pub const MAX_VISIBLE_MATCHES: usize = 256;

pub const PaneSearch = struct {
    active: bool = false,
    phase: enum { typing, results } = .typing,
    query: std.ArrayList(u8) = .empty,
    search: ?ScreenSearch = null,
    /// Total matches found by the last `run`.
    match_count: usize = 0,
    /// 1-based position of the current match (0 = none selected).
    current: usize = 0,
    /// Viewport ranges of matches currently on screen, refreshed on each
    /// navigation (not per-frame) so the renderer can highlight them cheaply.
    visible: [MAX_VISIBLE_MATCHES]MatchViewport = undefined,
    visible_count: usize = 0,

    pub fn deinit(self: *PaneSearch, allocator: std.mem.Allocator) void {
        self.clearSearch();
        self.query.deinit(allocator);
        self.* = .{};
    }

    fn clearSearch(self: *PaneSearch) void {
        if (self.search) |*s| s.deinit();
        self.search = null;
        self.match_count = 0;
        self.current = 0;
        self.visible_count = 0;
    }

    /// Begin a new search: activate, reset to the typing phase, clear the query.
    pub fn enter(self: *PaneSearch) void {
        self.clearSearch();
        self.query.clearRetainingCapacity();
        self.active = true;
        self.phase = .typing;
    }

    /// Tear down the search and deactivate. Safe to call when inactive. MUST be
    /// called before the searched pane is resized away, closed, or replaced —
    /// the search holds a `*Screen` and tracked pins into its pagelist.
    pub fn exit(self: *PaneSearch) void {
        self.clearSearch();
        self.active = false;
        self.phase = .typing;
    }

    pub fn appendText(self: *PaneSearch, allocator: std.mem.Allocator, text: []const u8) void {
        if (self.phase != .typing) return;
        if (self.query.items.len >= MAX_QUERY_LEN) return;
        const room = MAX_QUERY_LEN - self.query.items.len;
        const n = @min(room, text.len);
        self.query.appendSlice(allocator, text[0..n]) catch |err| {
            core.logging.logError("terminal", "failed to append search text", err);
        };
    }

    pub fn backspace(self: *PaneSearch) void {
        if (self.phase != .typing) return;
        if (self.query.items.len == 0) return;
        // Drop a whole trailing UTF-8 codepoint, not a single continuation byte.
        var i: usize = self.query.items.len;
        while (i > 0) {
            i -= 1;
            if (self.query.items[i] & 0xC0 != 0x80) break;
        }
        self.query.shrinkRetainingCapacity(i);
    }

    /// Run the search for the current query against the pane's active screen and
    /// jump to the first (newest) match. Returns the match count.
    pub fn run(self: *PaneSearch, allocator: std.mem.Allocator, pane: *Pane) usize {
        self.clearSearch();
        self.phase = .results;
        if (self.query.items.len == 0) return 0;

        const screen = pane.vt.terminal.screens.active;
        var s = ScreenSearch.init(allocator, screen, self.query.items) catch |err| {
            core.logging.logError("terminal", "failed to init scrollback search", err);
            return 0;
        };
        s.searchAll() catch |err| {
            core.logging.logError("terminal", "scrollback search failed", err);
            s.deinit();
            return 0;
        };
        self.search = s;
        self.match_count = self.search.?.matchesLen();
        if (self.match_count > 0 and (self.search.?.select(.next) catch false)) {
            self.current = 1;
            self.scrollToCurrent(pane);
        }
        self.refreshVisible(allocator, pane);
        return self.match_count;
    }

    /// Advance to the next (older) match, if any.
    pub fn next(self: *PaneSearch, allocator: std.mem.Allocator, pane: *Pane) void {
        if (self.search == null or self.current >= self.match_count) return;
        if (self.search.?.select(.next) catch false) {
            self.current += 1;
            self.scrollToCurrent(pane);
            self.refreshVisible(allocator, pane);
        }
    }

    /// Move to the previous (newer) match, if any.
    pub fn prev(self: *PaneSearch, allocator: std.mem.Allocator, pane: *Pane) void {
        if (self.search == null or self.current <= 1) return;
        if (self.search.?.select(.prev) catch false) {
            self.current -= 1;
            self.scrollToCurrent(pane);
            self.refreshVisible(allocator, pane);
        }
    }

    /// Recompute the on-screen match ranges after the viewport moved. Cheap
    /// enough to skip caching invalidation: only called on navigation, never
    /// per render frame.
    fn refreshVisible(self: *PaneSearch, allocator: std.mem.Allocator, pane: *Pane) void {
        self.visible_count = 0;
        if (self.search == null) return;
        const all = self.search.?.matches(allocator) catch return;
        defer allocator.free(all); // shallow slice; entries alias the search's data
        const pages = &pane.vt.terminal.screens.active.pages;
        for (all) |hl| {
            if (self.visible_count >= self.visible.len) break;
            const sp = pages.pointFromPin(.viewport, hl.startPin()) orelse continue;
            const ep = pages.pointFromPin(.viewport, hl.endPin()) orelse continue;
            self.visible[self.visible_count] = .{
                .sx = @intCast(sp.viewport.x),
                .sy = @intCast(sp.viewport.y),
                .ex = @intCast(ep.viewport.x),
                .ey = @intCast(ep.viewport.y),
            };
            self.visible_count += 1;
        }
    }

    fn scrollToCurrent(self: *PaneSearch, pane: *Pane) void {
        const s = &(self.search orelse return);
        const hl = s.selectedMatch() orelse return;
        // Bring the match into the viewport. The pin is tracked into the
        // screen's pagelist so it stays valid across incidental scrollback
        // growth while the search is open.
        pane.vt.terminal.screens.active.scroll(.{ .pin = hl.startPin() });
    }

    /// Inclusive viewport-local cell bounds of the current match, or null if it
    /// is not currently in the pane's viewport. Coordinates are pane-local
    /// (0-based); the caller offsets by the pane's on-screen origin.
    pub const MatchViewport = struct { sx: u16, sy: u16, ex: u16, ey: u16 };

    pub fn currentMatchViewport(self: *PaneSearch, pane: *Pane) ?MatchViewport {
        if (self.search) |*s| {
            const hl = s.selectedMatch() orelse return null;
            const pages = &pane.vt.terminal.screens.active.pages;
            const sp = pages.pointFromPin(.viewport, hl.startPin()) orelse return null;
            const ep = pages.pointFromPin(.viewport, hl.endPin()) orelse return null;
            return .{
                .sx = @intCast(sp.viewport.x),
                .sy = @intCast(sp.viewport.y),
                .ex = @intCast(ep.viewport.x),
                .ey = @intCast(ep.viewport.y),
            };
        }
        return null;
    }
};

test "PaneSearch finds and counts matches in scrollback" {
    const testing = std.testing;
    var vt: core.VT = .{};
    try vt.init(testing.allocator, 80, 24);
    defer vt.deinit();

    try vt.feed("hello world\r\nfoo hello bar\r\nnothing here\r\n");

    var search: PaneSearch = .{};
    defer search.deinit(testing.allocator);
    search.enter();
    search.appendText(testing.allocator, "hello");
    try testing.expectEqualStrings("hello", search.query.items);

    var pane: Pane = .{ .x = 0, .y = 0, .width = 80, .height = 24 };
    pane.vt = vt;
    const count = search.run(testing.allocator, &pane);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqual(@as(usize, 1), search.current);
    // Both matches sit in the 24-row viewport, so both are highlightable.
    try testing.expectEqual(@as(usize, 2), search.visible_count);

    // Navigation is bounded and moves the selection.
    search.next(testing.allocator, &pane);
    try testing.expectEqual(@as(usize, 2), search.current);
    search.next(testing.allocator, &pane); // already at last → no-op
    try testing.expectEqual(@as(usize, 2), search.current);
    search.prev(testing.allocator, &pane);
    try testing.expectEqual(@as(usize, 1), search.current);

    // The current match resolves to an inclusive viewport range spanning the
    // 5-cell "hello" needle on a single row.
    const mv = search.currentMatchViewport(&pane).?;
    try testing.expectEqual(mv.sy, mv.ey);
    try testing.expectEqual(@as(u16, 4), mv.ex - mv.sx);

    // Clear the borrowed VT so deinit doesn't double-free (owned by `vt`).
    pane.vt = .{};
}

test "PaneSearch query editing: append cap and utf8 backspace" {
    const testing = std.testing;
    var search: PaneSearch = .{};
    defer search.deinit(testing.allocator);
    search.enter();

    search.appendText(testing.allocator, "café");
    try testing.expectEqualStrings("café", search.query.items);
    search.backspace(); // drops 'é' (2 bytes) whole
    try testing.expectEqualStrings("caf", search.query.items);
}
