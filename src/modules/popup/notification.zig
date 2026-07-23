const std = @import("std");
const style = @import("style.zig");

const log = std.log.scoped(.popup_notification);

pub const Style = style.Style;
pub const Color = style.Color;
pub const Align = style.Align;
pub const Bounds = style.Bounds;
pub const Position = style.Position;

/// A single notification
pub const Notification = struct {
    message: []const u8,
    expires_at: i64,
    owned: bool, // true if message needs to be freed
    style: Style,

    pub fn isExpired(self: Notification) bool {
        return std.time.milliTimestamp() >= self.expires_at;
    }
};

/// Options for showing a notification
pub const NotifyOptions = struct {
    duration_ms: i64 = 3000,
    style: ?Style = null,
    owned: bool = false,
};

/// Notification manager - handles queue of notifications (non-blocking)
pub const NotificationManager = struct {
    allocator: std.mem.Allocator,
    current: ?Notification,
    queue: std.ArrayList(Notification),
    default_style: Style,
    default_duration_ms: i64,

    pub fn init(allocator: std.mem.Allocator) NotificationManager {
        return .{
            .allocator = allocator,
            .current = null,
            .queue = .empty,
            .default_style = .{},
            .default_duration_ms = 3000,
        };
    }

    /// Initialize with config
    pub fn initWithConfig(allocator: std.mem.Allocator, cfg: anytype) NotificationManager {
        return .{
            .allocator = allocator,
            .current = null,
            .queue = .empty,
            .default_style = Style.fromConfig(cfg),
            .default_duration_ms = @intCast(cfg.duration_ms),
        };
    }

    pub fn deinit(self: *NotificationManager) void {
        // Free current notification if owned
        if (self.current) |notif| {
            if (notif.owned) {
                self.allocator.free(notif.message);
            }
        }
        // Free queued notifications
        for (self.queue.items) |notif| {
            if (notif.owned) {
                self.allocator.free(notif.message);
            }
        }
        self.queue.deinit(self.allocator);
    }

    /// Show a notification with default settings
    pub fn show(self: *NotificationManager, message: []const u8) void {
        self.showWithOptions(message, .{});
    }

    /// Show a notification for a specific duration
    pub fn showFor(self: *NotificationManager, message: []const u8, duration_ms: i64) void {
        self.showWithOptions(message, .{ .duration_ms = duration_ms });
    }

    /// Show a notification with full options.
    ///
    /// The message is COPIED unless `opts.owned` transfers ownership. It used to
    /// be borrowed, which was a use-after-free waiting to happen: a notification
    /// lives for seconds, while callers routinely passed a stack buffer or an
    /// allocation released by `defer` on the very next line. The renderer then
    /// walked freed bytes with a grapheme iterator and segfaulted — the crash
    /// looked random because it needed a notification to still be on screen.
    /// Copying here fixes every call site at once and cannot be misused.
    pub fn showWithOptions(self: *NotificationManager, message: []const u8, opts: NotifyOptions) void {
        var stored: []const u8 = message;
        var stored_owned = opts.owned;
        if (!opts.owned) {
            if (self.allocator.dupe(u8, message)) |copy| {
                stored = copy;
                stored_owned = true;
            } else |err| {
                // Never store the borrowed pointer as a fallback — that is the
                // dangle this copy exists to prevent. A static string is worse
                // text but always safe to render.
                log.warn("failed to copy notification message: {}", .{err});
                stored = "(notification unavailable)";
                stored_owned = false;
            }
        }

        const notif = Notification{
            .message = stored,
            .expires_at = std.time.milliTimestamp() + (if (opts.duration_ms > 0) opts.duration_ms else self.default_duration_ms),
            .owned = stored_owned,
            .style = opts.style orelse self.default_style,
        };

        // If no current notification, show immediately
        if (self.current == null) {
            self.current = notif;
        } else {
            self.queue.append(self.allocator, notif) catch |err| {
                log.warn("failed to queue notification: {}", .{err});
                if (notif.owned) self.allocator.free(notif.message);
            };
        }
    }

    /// Update notification state - call each frame
    /// Returns true if display needs refresh
    pub fn update(self: *NotificationManager) bool {
        if (self.current) |notif| {
            if (notif.isExpired()) {
                // Clean up expired notification
                if (notif.owned) {
                    self.allocator.free(notif.message);
                }
                // Pop next from queue
                if (self.queue.items.len > 0) {
                    self.current = self.queue.orderedRemove(0);
                } else {
                    self.current = null;
                }
                return true; // needs refresh
            }
        }
        return false;
    }

    /// Check if there's an active notification
    pub fn hasActive(self: *NotificationManager) bool {
        return self.current != null;
    }

    /// Clear all notifications
    pub fn clear(self: *NotificationManager) void {
        if (self.current) |notif| {
            if (notif.owned) {
                self.allocator.free(notif.message);
            }
        }
        self.current = null;

        for (self.queue.items) |notif| {
            if (notif.owned) {
                self.allocator.free(notif.message);
            }
        }
        self.queue.clearRetainingCapacity();
    }
};

test "notification message survives the caller's buffer being freed/clobbered" {
    const testing = std.testing;
    var mgr = NotificationManager.init(testing.allocator);
    defer mgr.deinit();

    // Exactly the shape that crashed the renderer: a scratch buffer that the
    // caller reuses (or frees) the moment the call returns.
    var scratch: [64]u8 = undefined;
    const msg = try std.fmt.bufPrint(&scratch, "Background float exited with code {d}", .{7});
    mgr.showFor(msg, 3000);
    @memset(&scratch, 0xAA);

    try testing.expect(mgr.hasActive());
    try testing.expectEqualStrings("Background float exited with code 7", mgr.current.?.message);
}

test "notification takes ownership when the caller transfers it" {
    const testing = std.testing;
    var mgr = NotificationManager.init(testing.allocator);
    defer mgr.deinit();

    const owned = try testing.allocator.dupe(u8, "transferred");
    mgr.showWithOptions(owned, .{ .owned = true, .duration_ms = 3000 });
    try testing.expectEqualStrings("transferred", mgr.current.?.message);
    // deinit frees it; no leak, no double free.
}
