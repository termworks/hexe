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

pub const PaneSearch = struct {
    active: bool = false,
    phase: enum { typing, results } = .typing,
    query: std.ArrayList(u8) = .empty,
    search: ?ScreenSearch = null,
    /// Total matches found by the last `run`.
    match_count: usize = 0,
    /// 1-based position of the current match (0 = none selected).
    current: usize = 0,

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
        return self.match_count;
    }

    /// Advance to the next (older) match, if any.
    pub fn next(self: *PaneSearch, pane: *Pane) void {
        if (self.search == null or self.current >= self.match_count) return;
        if (self.search.?.select(.next) catch false) {
            self.current += 1;
            self.scrollToCurrent(pane);
        }
    }

    /// Move to the previous (newer) match, if any.
    pub fn prev(self: *PaneSearch, pane: *Pane) void {
        if (self.search == null or self.current <= 1) return;
        if (self.search.?.select(.prev) catch false) {
            self.current -= 1;
            self.scrollToCurrent(pane);
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

    // Navigation is bounded and moves the selection.
    search.next(&pane);
    try testing.expectEqual(@as(usize, 2), search.current);
    search.next(&pane); // already at last → no-op
    try testing.expectEqual(@as(usize, 2), search.current);
    search.prev(&pane);
    try testing.expectEqual(@as(usize, 1), search.current);

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
