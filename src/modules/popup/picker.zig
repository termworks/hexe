const std = @import("std");
const style = @import("style.zig");
pub const Style = style.Style;
pub const Color = style.Color;
pub const Align = style.Align;
pub const Bounds = style.Bounds;
pub const InputResult = style.InputResult;
pub const PopupKey = style.PopupKey;

/// Result of pressing a registered single-char action hotkey in a picker.
pub const PickerAction = struct {
    key: u8,
    /// Original (unfiltered) index of the highlighted item, or null if list is empty.
    selected: ?usize,
};

/// Options for creating a picker
pub const PickerOptions = struct {
    style: ?Style = null,
    visible_count: usize = 10,
    title: ?[]const u8 = null,
    timeout_ms: ?i64 = null, // Auto-cancel after this many milliseconds (null = no timeout)
    /// Optional per-item detail line shown in the preview footer for the selected item.
    details: ?[]const []const u8 = null,
    /// Optional per-item right-aligned badge (e.g. "attached", "detached", "here").
    badges: ?[]const []const u8 = null,
    /// Custom footer hint line.
    hint: ?[]const u8 = null,
    /// Allow `/` to enter case-insensitive substring filtering.
    filterable: bool = true,
    /// Open directly in filter mode.
    start_filtering: bool = false,
    /// Pre-populate the filter query (implies filtering items immediately).
    initial_filter: ?[]const u8 = null,
    /// Optional single-char action hotkeys recognized outside filter mode (e.g. "nxar").
    action_keys: []const u8 = &.{},
    /// Allow pressing 1-9 to quick-select a visible item outside filter mode.
    show_numbers: bool = true,
};

/// Picker/Choose - Multi-option selector blocking popup
pub const Picker = struct {
    allocator: std.mem.Allocator,
    items: []const []const u8,
    items_owned: bool,
    details: ?[]const []const u8,
    details_owned: bool,
    badges: ?[]const []const u8,
    badges_owned: bool,
    hint: ?[]const u8,
    hint_owned: bool,
    action_keys: []const u8,
    action_keys_owned: bool,
    filterable: bool,
    show_numbers: bool,

    // Filter state
    filter_active: bool,
    filter_buf: [128]u8,
    filter_len: usize,
    filtered_indices: std.ArrayList(usize),

    /// Selected position inside `filtered_indices`.
    selected: usize,
    /// Scroll offset inside `filtered_indices`.
    scroll_offset: usize,
    visible_count: usize,
    style: Style,
    title: ?[]const u8,
    title_owned: bool,
    result: ?usize, // Original item index if selected, null if cancelled/action
    action_result: ?PickerAction,
    cancelled: bool,
    timeout_ms: ?i64, // Auto-cancel timeout (null = no timeout)
    created_at: i64, // Timestamp when created (milliseconds)

    pub fn init(allocator: std.mem.Allocator, items: []const []const u8, opts: PickerOptions) Picker {
        const visible = @max(@min(opts.visible_count, if (items.len == 0) 1 else items.len), 1);
        var p = Picker{
            .allocator = allocator,
            .items = items,
            .items_owned = false,
            .details = opts.details,
            .details_owned = false,
            .badges = opts.badges,
            .badges_owned = false,
            .hint = opts.hint,
            .hint_owned = false,
            .action_keys = opts.action_keys,
            .action_keys_owned = false,
            .filterable = opts.filterable,
            .show_numbers = opts.show_numbers,
            .filter_active = opts.start_filtering and opts.filterable,
            .filter_buf = undefined,
            .filter_len = 0,
            .filtered_indices = .empty,
            .selected = 0,
            .scroll_offset = 0,
            .visible_count = visible,
            .style = opts.style orelse Style.withColors(7, 0),
            .title = opts.title,
            .title_owned = false,
            .result = null,
            .action_result = null,
            .cancelled = false,
            .timeout_ms = opts.timeout_ms,
            .created_at = std.time.milliTimestamp(),
        };
        if (opts.initial_filter) |q| {
            const n = @min(q.len, p.filter_buf.len);
            @memcpy(p.filter_buf[0..n], q[0..n]);
            p.filter_len = n;
        }
        p.rebuildFilter();
        return p;
    }

    /// Create with owned copies of items, details, badges, title, hint, and action_keys.
    pub fn initOwned(allocator: std.mem.Allocator, items: []const []const u8, opts: PickerOptions) !Picker {
        var owned_items = try allocator.alloc([]const u8, items.len);
        var items_duped: usize = 0;
        errdefer {
            for (owned_items[0..items_duped]) |it| allocator.free(it);
            allocator.free(owned_items);
        }
        for (items, 0..) |item, i| {
            owned_items[i] = try allocator.dupe(u8, item);
            items_duped = i + 1;
        }

        var owned_details: ?[][]const u8 = null;
        var details_duped: usize = 0;
        errdefer if (owned_details) |ds| {
            for (ds[0..details_duped]) |d| allocator.free(d);
            allocator.free(ds);
        };
        if (opts.details) |ds| {
            const buf = try allocator.alloc([]const u8, ds.len);
            owned_details = buf;
            for (ds, 0..) |d, i| {
                buf[i] = try allocator.dupe(u8, d);
                details_duped = i + 1;
            }
        }

        var owned_badges: ?[][]const u8 = null;
        var badges_duped: usize = 0;
        errdefer if (owned_badges) |bs| {
            for (bs[0..badges_duped]) |b| allocator.free(b);
            allocator.free(bs);
        };
        if (opts.badges) |bs| {
            const buf = try allocator.alloc([]const u8, bs.len);
            owned_badges = buf;
            for (bs, 0..) |b, i| {
                buf[i] = try allocator.dupe(u8, b);
                badges_duped = i + 1;
            }
        }

        var owned_title: ?[]u8 = null;
        if (opts.title) |t| owned_title = try allocator.dupe(u8, t);
        errdefer if (owned_title) |t| allocator.free(t);

        var owned_hint: ?[]u8 = null;
        if (opts.hint) |h| owned_hint = try allocator.dupe(u8, h);
        errdefer if (owned_hint) |h| allocator.free(h);

        var owned_actions: ?[]u8 = null;
        if (opts.action_keys.len > 0) owned_actions = try allocator.dupe(u8, opts.action_keys);
        errdefer if (owned_actions) |a| allocator.free(a);

        var picker = init(allocator, owned_items, opts);
        picker.items_owned = true;
        if (owned_details) |ds| {
            picker.details = ds;
            picker.details_owned = true;
        }
        if (owned_badges) |bs| {
            picker.badges = bs;
            picker.badges_owned = true;
        }
        if (owned_title) |t| {
            picker.title = t;
            picker.title_owned = true;
        }
        if (owned_hint) |h| {
            picker.hint = h;
            picker.hint_owned = true;
        }
        if (owned_actions) |a| {
            picker.action_keys = a;
            picker.action_keys_owned = true;
        }
        return picker;
    }

    pub fn deinit(self: *Picker) void {
        self.filtered_indices.deinit(self.allocator);
        if (self.items_owned) {
            for (self.items) |item| self.allocator.free(item);
            self.allocator.free(self.items);
        }
        if (self.details_owned) {
            if (self.details) |ds| {
                for (ds) |d| self.allocator.free(d);
                self.allocator.free(ds);
            }
        }
        if (self.badges_owned) {
            if (self.badges) |bs| {
                for (bs) |b| self.allocator.free(b);
                self.allocator.free(bs);
            }
        }
        if (self.title_owned) {
            if (self.title) |t| self.allocator.free(t);
        }
        if (self.hint_owned) {
            if (self.hint) |h| self.allocator.free(h);
        }
        if (self.action_keys_owned) {
            self.allocator.free(self.action_keys);
        }
    }

    pub fn filterQuery(self: *const Picker) []const u8 {
        return self.filter_buf[0..self.filter_len];
    }

    pub fn visibleLen(self: *const Picker) usize {
        return self.filtered_indices.items.len;
    }

    pub fn originalIndexAt(self: *const Picker, filtered_pos: usize) ?usize {
        if (filtered_pos >= self.filtered_indices.items.len) return null;
        return self.filtered_indices.items[filtered_pos];
    }

    pub fn selectedOriginalIndex(self: *const Picker) ?usize {
        return self.originalIndexAt(self.selected);
    }

    pub fn selectedDetail(self: *const Picker) ?[]const u8 {
        const ds = self.details orelse return null;
        const idx = self.selectedOriginalIndex() orelse return null;
        if (idx >= ds.len) return null;
        if (ds[idx].len == 0) return null;
        return ds[idx];
    }

    pub fn badgeAt(self: *const Picker, original_idx: usize) ?[]const u8 {
        const bs = self.badges orelse return null;
        if (original_idx >= bs.len) return null;
        if (bs[original_idx].len == 0) return null;
        return bs[original_idx];
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            var matched = true;
            for (needle, 0..) |nc, j| {
                if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }

    pub fn rebuildFilter(self: *Picker) void {
        const prev_orig = self.selectedOriginalIndex();
        self.filtered_indices.clearRetainingCapacity();

        const query = self.filterQuery();
        for (self.items, 0..) |item, i| {
            const match_item = containsIgnoreCase(item, query);
            const match_detail = if (!match_item and self.details != null and i < self.details.?.len)
                containsIgnoreCase(self.details.?[i], query)
            else
                false;
            const match_badge = if (!match_item and !match_detail and self.badges != null and i < self.badges.?.len)
                containsIgnoreCase(self.badges.?[i], query)
            else
                false;
            if (match_item or match_detail or match_badge) {
                self.filtered_indices.append(self.allocator, i) catch break;
            }
        }

        // Preserve selection on the same item if it still matches.
        self.selected = 0;
        if (prev_orig) |orig| {
            for (self.filtered_indices.items, 0..) |idx, pos| {
                if (idx == orig) {
                    self.selected = pos;
                    break;
                }
            }
        }
        self.clampScroll();
    }

    fn clampScroll(self: *Picker) void {
        const len = self.filtered_indices.items.len;
        if (len == 0) {
            self.selected = 0;
            self.scroll_offset = 0;
            return;
        }
        if (self.selected >= len) self.selected = len - 1;
        if (self.selected < self.scroll_offset) {
            self.scroll_offset = self.selected;
        } else if (self.visible_count > 0 and self.selected >= self.scroll_offset + self.visible_count) {
            self.scroll_offset = self.selected - self.visible_count + 1;
        }
    }

    fn isActionKey(self: *const Picker, ch: u8) bool {
        for (self.action_keys) |k| {
            if (k == ch) return true;
        }
        return false;
    }

    /// Handle structured keyboard input.
    pub fn handleKey(self: *Picker, key: PopupKey) InputResult {
        if (self.filter_active) {
            return self.handleFilterKey(key);
        }

        switch (key) {
            .up => {
                self.moveUp();
                return .consumed;
            },
            .down => {
                self.moveDown();
                return .consumed;
            },
            .page_up => {
                self.pageUp();
                return .consumed;
            },
            .page_down => {
                self.pageDown();
                return .consumed;
            },
            .home => {
                self.moveToTop();
                return .consumed;
            },
            .end => {
                self.moveToBottom();
                return .consumed;
            },
            .enter => {
                if (self.selectedOriginalIndex()) |orig| {
                    self.result = orig;
                    return .dismissed;
                }
                return .consumed;
            },
            .escape => {
                if (self.filter_len > 0) {
                    self.filter_len = 0;
                    self.rebuildFilter();
                    return .consumed;
                }
                self.cancelled = true;
                self.result = null;
                return .dismissed;
            },
            .ctrl_c => {
                self.cancelled = true;
                self.result = null;
                return .dismissed;
            },
            .char => |ch| {
                if (ch == '/' and self.filterable) {
                    self.filter_active = true;
                    return .consumed;
                }
                if (self.isActionKey(ch)) {
                    self.action_result = .{
                        .key = ch,
                        .selected = self.selectedOriginalIndex(),
                    };
                    self.result = null;
                    return .dismissed;
                }
                switch (ch) {
                    'j', 'J' => {
                        self.moveDown();
                        return .consumed;
                    },
                    'k', 'K' => {
                        self.moveUp();
                        return .consumed;
                    },
                    'g' => {
                        self.moveToTop();
                        return .consumed;
                    },
                    'G' => {
                        self.moveToBottom();
                        return .consumed;
                    },
                    ' ' => {
                        if (self.selectedOriginalIndex()) |orig| {
                            self.result = orig;
                            return .dismissed;
                        }
                        return .consumed;
                    },
                    'q', 'Q' => {
                        self.cancelled = true;
                        self.result = null;
                        return .dismissed;
                    },
                    '1'...'9' => {
                        if (self.show_numbers) {
                            const offset: usize = ch - '1';
                            const pos = self.scroll_offset + offset;
                            if (self.originalIndexAt(pos)) |orig| {
                                self.selected = pos;
                                self.result = orig;
                                return .dismissed;
                            }
                        }
                        return .consumed;
                    },
                    else => return .consumed,
                }
            },
            else => return .consumed,
        }
    }

    fn handleFilterKey(self: *Picker, key: PopupKey) InputResult {
        switch (key) {
            .up => {
                self.moveUp();
                return .consumed;
            },
            .down => {
                self.moveDown();
                return .consumed;
            },
            .page_up => {
                self.pageUp();
                return .consumed;
            },
            .page_down => {
                self.pageDown();
                return .consumed;
            },
            .home => {
                self.moveToTop();
                return .consumed;
            },
            .end => {
                self.moveToBottom();
                return .consumed;
            },
            .enter => {
                if (self.selectedOriginalIndex()) |orig| {
                    self.result = orig;
                    return .dismissed;
                }
                return .consumed;
            },
            .escape => {
                self.filter_active = false;
                if (self.filter_len > 0) {
                    self.filter_len = 0;
                    self.rebuildFilter();
                }
                return .consumed;
            },
            .ctrl_c => {
                self.cancelled = true;
                self.result = null;
                return .dismissed;
            },
            .ctrl_u => {
                if (self.filter_len > 0) {
                    self.filter_len = 0;
                    self.rebuildFilter();
                }
                return .consumed;
            },
            .backspace => {
                if (self.filter_len > 0) {
                    self.filter_len -= 1;
                    self.rebuildFilter();
                } else {
                    self.filter_active = false;
                }
                return .consumed;
            },
            .char => |ch| {
                if (ch >= 0x20 and ch <= 0x7e and self.filter_len < self.filter_buf.len) {
                    self.filter_buf[self.filter_len] = ch;
                    self.filter_len += 1;
                    self.rebuildFilter();
                }
                return .consumed;
            },
            else => return .consumed,
        }
    }

    /// Handle legacy single-byte keyboard input.
    pub fn handleInput(self: *Picker, key: u8) InputResult {
        return self.handleKey(PopupKey.fromByte(key));
    }

    /// Move selection down
    pub fn moveDown(self: *Picker) void {
        const len = self.filtered_indices.items.len;
        if (len == 0) return;
        if (self.selected + 1 < len) {
            self.selected += 1;
            self.clampScroll();
        }
    }

    /// Move selection up
    pub fn moveUp(self: *Picker) void {
        if (self.selected > 0) {
            self.selected -= 1;
            self.clampScroll();
        }
    }

    pub fn pageUp(self: *Picker) void {
        const step = @max(self.visible_count, 1);
        self.selected -|= step;
        self.clampScroll();
    }

    pub fn pageDown(self: *Picker) void {
        const len = self.filtered_indices.items.len;
        if (len == 0) return;
        const step = @max(self.visible_count, 1);
        self.selected = @min(self.selected + step, len - 1);
        self.clampScroll();
    }

    /// Move to top
    pub fn moveToTop(self: *Picker) void {
        self.selected = 0;
        self.scroll_offset = 0;
    }

    /// Move to bottom
    pub fn moveToBottom(self: *Picker) void {
        const len = self.filtered_indices.items.len;
        if (len == 0) return;
        self.selected = len - 1;
        self.clampScroll();
    }

    /// Get the result (null if cancelled or action hotkey, original index if selected)
    pub fn getResult(self: *Picker) ?usize {
        return self.result;
    }

    /// Get the action hotkey result, if dismissed via a registered action key.
    pub fn getAction(self: *Picker) ?PickerAction {
        return self.action_result;
    }

    /// Check if cancelled
    pub fn wasCancelled(self: *Picker) bool {
        return self.cancelled;
    }

    /// Check if this is a blocking popup
    pub fn isBlocking(_: *Picker) bool {
        return true;
    }

    /// Check if the popup has timed out
    pub fn isTimedOut(self: *Picker) bool {
        if (self.timeout_ms) |timeout| {
            const now = std.time.milliTimestamp();
            return (now - self.created_at) >= timeout;
        }
        return false;
    }

    /// Force timeout (set result to cancelled)
    pub fn forceTimeout(self: *Picker) void {
        self.cancelled = true;
        self.result = null;
    }

    /// Calculate required box dimensions
    pub fn getBoxDimensions(self: *Picker) struct { width: u16, height: u16 } {
        const s = self.style;

        var max_item_width: usize = 0;
        for (self.items, 0..) |item, i| {
            var row_w = item.len;
            if (self.badgeAt(i)) |b| row_w += b.len + 2;
            max_item_width = @max(max_item_width, row_w);
        }

        var title_width: usize = 0;
        if (self.title) |t| {
            title_width = t.len + 12; // title + count badge
        }

        const content_width = @max(max_item_width + 4, title_width);
        const box_width: u16 = @intCast(content_width + s.padding_x * 2);

        var box_height: u16 = @intCast(self.visible_count + s.padding_y * 2);
        if (self.title != null) box_height += 1;
        return .{ .width = box_width, .height = box_height };
    }
};

test "Picker filtering maps back to original index and Escape clears filter before cancel" {
    const alloc = std.testing.allocator;
    const items = [_][]const u8{ "alpha", "bravo", "charlie" };
    const details = [_][]const u8{ "/tmp/one", "/tmp/work", "/tmp/two" };
    var p = try Picker.initOwned(alloc, &items, .{
        .title = "Sessions",
        .details = &details,
        .action_keys = "nx",
    });
    defer p.deinit();

    // Enter filter mode with '/' and type "work" (matches detail of bravo, idx 1)
    try std.testing.expectEqual(InputResult.consumed, p.handleKey(.{ .char = '/' }));
    try std.testing.expect(p.filter_active);
    for ("work") |ch| {
        try std.testing.expectEqual(InputResult.consumed, p.handleKey(.{ .char = ch }));
    }
    try std.testing.expectEqual(@as(usize, 1), p.visibleLen());
    try std.testing.expectEqual(@as(?usize, 1), p.selectedOriginalIndex());

    // Enter selects original index 1
    try std.testing.expectEqual(InputResult.dismissed, p.handleKey(.enter));
    try std.testing.expectEqual(@as(?usize, 1), p.getResult());

    // Test action hotkey outside filter mode
    var p2 = try Picker.initOwned(alloc, &items, .{ .action_keys = "nx" });
    defer p2.deinit();
    try std.testing.expectEqual(InputResult.consumed, p2.handleKey(.down));
    try std.testing.expectEqual(InputResult.dismissed, p2.handleKey(.{ .char = 'x' }));
    const act = p2.getAction().?;
    try std.testing.expectEqual(@as(u8, 'x'), act.key);
    try std.testing.expectEqual(@as(?usize, 1), act.selected);

    // Test number quick-select
    var p3 = try Picker.initOwned(alloc, &items, .{});
    defer p3.deinit();
    try std.testing.expectEqual(InputResult.dismissed, p3.handleKey(.{ .char = '3' }));
    try std.testing.expectEqual(@as(?usize, 2), p3.getResult());
}
