const std = @import("std");
const style = @import("style.zig");
pub const Style = style.Style;
pub const Color = style.Color;
pub const Align = style.Align;
pub const Bounds = style.Bounds;
pub const InputResult = style.InputResult;
pub const PopupKey = style.PopupKey;

/// Selection state for confirm dialog
pub const Selection = enum {
    yes,
    no,
};

/// Options for creating a confirm dialog
pub const ConfirmOptions = struct {
    style: ?Style = null,
    default: Selection = .no,
    yes_label: []const u8 = "Yes",
    no_label: []const u8 = "No",
    subtitle: ?[]const u8 = null,
    hint: ?[]const u8 = null,
    timeout_ms: ?i64 = null, // Auto-cancel after this many milliseconds (null = no timeout)
};

/// Confirm dialog - Yes/No blocking popup
pub const Confirm = struct {
    allocator: std.mem.Allocator,
    message: []const u8,
    message_owned: bool,
    subtitle: ?[]const u8,
    subtitle_owned: bool,
    hint: ?[]const u8,
    hint_owned: bool,
    selected: Selection,
    style: Style,
    yes_label: []const u8,
    no_label: []const u8,
    result: ?bool, // Set when dismissed
    cancelled: bool, // True if dismissed via Esc/Ctrl+C/q/timeout
    timeout_ms: ?i64, // Auto-cancel timeout (null = no timeout)
    created_at: i64, // Timestamp when created (milliseconds)

    pub fn init(allocator: std.mem.Allocator, message: []const u8, opts: ConfirmOptions) Confirm {
        return .{
            .allocator = allocator,
            .message = message,
            .message_owned = false,
            .subtitle = opts.subtitle,
            .subtitle_owned = false,
            .hint = opts.hint,
            .hint_owned = false,
            .selected = opts.default,
            .style = opts.style orelse Style.withColors(0, 4), // black on blue
            .yes_label = opts.yes_label,
            .no_label = opts.no_label,
            .result = null,
            .cancelled = false,
            .timeout_ms = opts.timeout_ms,
            .created_at = std.time.milliTimestamp(),
        };
    }

    /// Create with owned message/subtitle/hint (will be freed on deinit)
    pub fn initOwned(allocator: std.mem.Allocator, message: []const u8, opts: ConfirmOptions) !Confirm {
        const owned_msg = try allocator.dupe(u8, message);
        errdefer allocator.free(owned_msg);

        var owned_sub: ?[]u8 = null;
        if (opts.subtitle) |sub| {
            owned_sub = try allocator.dupe(u8, sub);
        }
        errdefer if (owned_sub) |s| allocator.free(s);

        var owned_hint: ?[]u8 = null;
        if (opts.hint) |h| {
            owned_hint = try allocator.dupe(u8, h);
        }
        errdefer if (owned_hint) |h| allocator.free(h);

        var confirm = init(allocator, owned_msg, opts);
        confirm.message_owned = true;
        if (owned_sub) |s| {
            confirm.subtitle = s;
            confirm.subtitle_owned = true;
        }
        if (owned_hint) |h| {
            confirm.hint = h;
            confirm.hint_owned = true;
        }
        return confirm;
    }

    pub fn deinit(self: *Confirm) void {
        if (self.message_owned) {
            self.allocator.free(self.message);
        }
        if (self.subtitle_owned) {
            if (self.subtitle) |s| self.allocator.free(s);
        }
        if (self.hint_owned) {
            if (self.hint) |h| self.allocator.free(h);
        }
    }

    /// Handle structured keyboard input.
    /// Left/Right/Tab toggle, Enter/Space confirm, Y/N select directly, Esc/Ctrl+C/q cancel.
    pub fn handleKey(self: *Confirm, key: PopupKey) InputResult {
        switch (key) {
            .escape, .ctrl_c => {
                self.selected = .no;
                self.result = false;
                self.cancelled = true;
                return .dismissed;
            },
            .enter => {
                self.result = self.selected == .yes;
                return .dismissed;
            },
            .left, .right, .tab, .shift_tab => {
                self.toggle();
                return .consumed;
            },
            .char => |ch| switch (ch) {
                ' ' => {
                    self.result = self.selected == .yes;
                    return .dismissed;
                },
                'y', 'Y' => {
                    self.selected = .yes;
                    self.result = true;
                    return .dismissed;
                },
                'n', 'N' => {
                    self.selected = .no;
                    self.result = false;
                    return .dismissed;
                },
                'q', 'Q' => {
                    self.selected = .no;
                    self.result = false;
                    self.cancelled = true;
                    return .dismissed;
                },
                'h', 'H', 'l', 'L' => {
                    self.toggle();
                    return .consumed;
                },
                else => return .consumed,
            },
            else => return .consumed,
        }
    }

    /// Handle legacy single-byte keyboard input.
    pub fn handleInput(self: *Confirm, key: u8) InputResult {
        return self.handleKey(PopupKey.fromByte(key));
    }

    /// Toggle selection between yes and no
    pub fn toggle(self: *Confirm) void {
        self.selected = if (self.selected == .yes) .no else .yes;
    }

    /// Get the result (true = yes, false = no/cancelled)
    pub fn getResult(self: *Confirm) ?bool {
        return self.result;
    }

    /// True if dismissed by Esc/Ctrl+C/q/timeout rather than explicit Yes/No.
    pub fn wasCancelled(self: *Confirm) bool {
        return self.cancelled;
    }

    /// Check if this is a blocking popup
    pub fn isBlocking(_: *Confirm) bool {
        return true;
    }

    /// Check if the popup has timed out
    pub fn isTimedOut(self: *Confirm) bool {
        if (self.timeout_ms) |timeout| {
            const now = std.time.milliTimestamp();
            return (now - self.created_at) >= timeout;
        }
        return false;
    }

    /// Force timeout (set result to false/cancelled)
    pub fn forceTimeout(self: *Confirm) void {
        self.selected = .no;
        self.result = false;
        self.cancelled = true;
    }

    /// Calculate required box dimensions (including border)
    pub fn getBoxDimensions(self: *Confirm) struct { width: u16, height: u16 } {
        const s = self.style;
        const msg_width: u16 = @intCast(self.message.len);
        const sub_width: u16 = if (self.subtitle) |sub| @intCast(sub.len) else 0;
        const buttons_width: u16 = @intCast(self.yes_label.len + self.no_label.len + 14);
        const content_width = @max(@max(msg_width, sub_width), buttons_width);
        const box_width = content_width + s.padding_x * 2 + 2;
        var box_height: u16 = 3 + s.padding_y * 2 + 2;
        if (self.subtitle != null) box_height += 1;
        return .{ .width = box_width, .height = box_height };
    }
};

test "Confirm handles Tab, Space, y/n, Esc, and Ctrl+C" {
    const alloc = std.testing.allocator;

    var c1 = try Confirm.initOwned(alloc, "Attach?", .{
        .subtitle = "work [a3f29c10]",
        .hint = "y/n",
        .default = .no,
    });
    defer c1.deinit();

    try std.testing.expectEqual(InputResult.consumed, c1.handleKey(.tab));
    try std.testing.expectEqual(Selection.yes, c1.selected);
    try std.testing.expectEqual(InputResult.dismissed, c1.handleKey(.{ .char = ' ' }));
    try std.testing.expectEqual(@as(?bool, true), c1.getResult());
    try std.testing.expect(!c1.wasCancelled());

    var c2 = try Confirm.initOwned(alloc, "Delete?", .{ .default = .yes });
    defer c2.deinit();
    try std.testing.expectEqual(InputResult.dismissed, c2.handleKey(.ctrl_c));
    try std.testing.expectEqual(@as(?bool, false), c2.getResult());
    try std.testing.expect(c2.wasCancelled());
}
