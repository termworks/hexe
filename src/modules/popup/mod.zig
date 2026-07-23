const std = @import("std");

// Re-export submodules
pub const style = @import("style.zig");
pub const notification = @import("notification.zig");
pub const confirm = @import("confirm.zig");
pub const picker = @import("picker.zig");
pub const config = @import("config.zig");
pub const overlay = @import("overlay/mod.zig");
pub const widgets = @import("widgets/mod.zig");

// Re-export config types
pub const PopConfig = config.PopConfig;
pub const NotificationStyle = config.NotificationStyle;
pub const ConfirmStyle = config.ConfirmStyle;
pub const ChooseStyle = config.ChooseStyle;
pub const CarrierConfig = config.CarrierConfig;
pub const PaneConfig = config.PaneConfig;

// Re-export common types
pub const Style = style.Style;
pub const Color = style.Color;
pub const Align = style.Align;
pub const Bounds = style.Bounds;
pub const Position = style.Position;
pub const InputResult = style.InputResult;

pub const Notification = notification.Notification;
pub const NotificationManager = notification.NotificationManager;
pub const NotifyOptions = notification.NotifyOptions;

pub const Confirm = confirm.Confirm;
pub const ConfirmOptions = confirm.ConfirmOptions;
pub const Selection = confirm.Selection;

pub const Picker = picker.Picker;
pub const PickerOptions = picker.PickerOptions;

/// Blocking popup scope
pub const Scope = enum {
    mux, // Blocks entire mux until resolved
    tab, // Can switch tabs, but this tab blocked
    pane, // Only this pane blocked
};

/// Active popup union - only one blocking popup at a time
pub const Popup = union(enum) {
    confirm: *Confirm,
    picker: *Picker,

    pub fn handleInput(self: Popup, key: u8) InputResult {
        return switch (self) {
            .confirm => |c| c.handleInput(key),
            .picker => |p| p.handleInput(key),
        };
    }

    pub fn isBlocking(self: Popup) bool {
        return switch (self) {
            .confirm => |c| c.isBlocking(),
            .picker => |p| p.isBlocking(),
        };
    }

    pub fn isTimedOut(self: Popup) bool {
        return switch (self) {
            .confirm => |c| c.isTimedOut(),
            .picker => |p| p.isTimedOut(),
        };
    }

    pub fn forceTimeout(self: Popup) void {
        switch (self) {
            .confirm => |c| c.forceTimeout(),
            .picker => |p| p.forceTimeout(),
        }
    }

    pub fn deinit(self: Popup, allocator: std.mem.Allocator) void {
        switch (self) {
            .confirm => |c| {
                c.deinit();
                allocator.destroy(c);
            },
            .picker => |p| {
                p.deinit();
                allocator.destroy(p);
            },
        }
    }
};

/// PopupManager - manages popups for a single scope (mux, tab, or pane)
pub const PopupManager = struct {
    allocator: std.mem.Allocator,
    notifications: NotificationManager,
    active: ?Popup,
    // Store last result for retrieval after popup is dismissed
    last_confirm_result: ?bool,
    last_picker_result: ?usize,
    last_picker_cancelled: bool,

    pub fn init(allocator: std.mem.Allocator) PopupManager {
        return .{
            .allocator = allocator,
            .notifications = NotificationManager.init(allocator),
            .active = null,
            .last_confirm_result = null,
            .last_picker_result = null,
            .last_picker_cancelled = false,
        };
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, cfg: anytype) PopupManager {
        return .{
            .allocator = allocator,
            .notifications = NotificationManager.initWithConfig(allocator, cfg),
            .active = null,
            .last_confirm_result = null,
            .last_picker_result = null,
            .last_picker_cancelled = false,
        };
    }

    pub fn deinit(self: *PopupManager) void {
        self.notifications.deinit();
        if (self.active) |popup| {
            popup.deinit(self.allocator);
        }
    }

    // =========================================================================
    // Notification methods (non-blocking)
    // =========================================================================

    /// Show a notification with default settings
    pub fn notify(self: *PopupManager, message: []const u8) void {
        self.notifications.show(message);
    }

    /// Show a notification for a specific duration
    pub fn notifyFor(self: *PopupManager, message: []const u8, duration_ms: i64) void {
        self.notifications.showFor(message, duration_ms);
    }

    /// Show a notification with full options
    pub fn notifyWithOptions(self: *PopupManager, message: []const u8, opts: NotifyOptions) void {
        self.notifications.showWithOptions(message, opts);
    }

    // =========================================================================
    // Confirm methods (blocking)
    // =========================================================================

    /// Show a confirm dialog (blocking).
    ///
    /// The message is COPIED. It used to be borrowed, and a popup outlives the
    /// call by however long the user takes to answer — so any caller formatting
    /// its prompt into a stack buffer left the renderer walking freed bytes.
    /// Same defect class as the notification manager's borrowed message.
    pub fn showConfirm(self: *PopupManager, message: []const u8, opts: ConfirmOptions) !void {
        if (self.active != null) return error.PopupAlreadyActive;

        const c = try self.allocator.create(Confirm);
        errdefer self.allocator.destroy(c);
        c.* = try Confirm.initOwned(self.allocator, message, opts);
        self.active = .{ .confirm = c };
    }

    /// Show a confirm dialog with owned message (blocking)
    pub fn showConfirmOwned(self: *PopupManager, message: []const u8, opts: ConfirmOptions) !void {
        if (self.active != null) return error.PopupAlreadyActive;

        const c = try self.allocator.create(Confirm);
        c.* = try Confirm.initOwned(self.allocator, message, opts);
        self.active = .{ .confirm = c };
    }

    // =========================================================================
    // Picker methods (blocking)
    // =========================================================================

    /// Show a picker dialog (blocking). Items are COPIED — see showConfirm.
    pub fn showPicker(self: *PopupManager, items: []const []const u8, opts: PickerOptions) !void {
        if (self.active != null) return error.PopupAlreadyActive;

        const p = try self.allocator.create(Picker);
        errdefer self.allocator.destroy(p);
        p.* = try Picker.initOwned(self.allocator, items, opts);
        self.active = .{ .picker = p };
    }

    /// Show a picker dialog with owned items (blocking)
    pub fn showPickerOwned(self: *PopupManager, items: []const []const u8, opts: PickerOptions) !void {
        if (self.active != null) return error.PopupAlreadyActive;

        const p = try self.allocator.create(Picker);
        p.* = try Picker.initOwned(self.allocator, items, opts);
        self.active = .{ .picker = p };
    }

    // =========================================================================
    // Lifecycle methods
    // =========================================================================

    /// Update popup state - call each frame
    /// Returns true if display needs refresh
    pub fn update(self: *PopupManager) bool {
        var needs_refresh = self.notifications.update();

        // Check for timeout on active blocking popup
        if (self.active) |popup| {
            if (popup.isTimedOut()) {
                // Store result (timeout = cancelled)
                switch (popup) {
                    .confirm => |c| {
                        c.forceTimeout();
                        self.last_confirm_result = c.getResult();
                        self.last_picker_result = null;
                        self.last_picker_cancelled = false;
                    },
                    .picker => |p| {
                        p.forceTimeout();
                        self.last_picker_result = null;
                        self.last_picker_cancelled = true;
                        self.last_confirm_result = null;
                    },
                }
                // Clean up the popup
                popup.deinit(self.allocator);
                self.active = null;
                needs_refresh = true;
            }
        }

        return needs_refresh;
    }

    /// Handle keyboard input
    /// Returns null if no popup handled it, otherwise the result
    pub fn handleInput(self: *PopupManager, key: u8) ?InputResult {
        if (self.active) |popup| {
            const result = popup.handleInput(key);
            if (result == .dismissed) {
                // Store result before cleanup
                switch (popup) {
                    .confirm => |c| {
                        self.last_confirm_result = c.getResult();
                        self.last_picker_result = null;
                        self.last_picker_cancelled = false;
                    },
                    .picker => |p| {
                        self.last_picker_result = p.getResult();
                        self.last_picker_cancelled = p.wasCancelled();
                        self.last_confirm_result = null;
                    },
                }
                // Popup is done, clean up
                popup.deinit(self.allocator);
                self.active = null;
            }
            return result;
        }
        return null;
    }

    /// Check if there's an active blocking popup
    pub fn isBlocked(self: *PopupManager) bool {
        if (self.active) |popup| {
            return popup.isBlocking();
        }
        return false;
    }

    /// Check if there's any active content (notifications or popups)
    pub fn hasActive(self: *PopupManager) bool {
        return self.active != null or self.notifications.hasActive();
    }

    /// Check if there's an active notification
    pub fn hasNotification(self: *PopupManager) bool {
        return self.notifications.hasActive();
    }

    /// Get the active notification for rendering
    pub fn getActiveNotification(self: *PopupManager) ?*const Notification {
        return if (self.notifications.current) |*n| n else null;
    }

    /// Get the active popup for rendering
    pub fn getActivePopup(self: *PopupManager) ?Popup {
        return self.active;
    }

    /// Get result from the last confirm dialog (if any)
    /// Returns the stored result from the last dismissed confirm popup
    pub fn getConfirmResult(self: *PopupManager) ?bool {
        return self.last_confirm_result;
    }

    /// Get result from the last picker dialog (if any)
    /// Returns the stored result from the last dismissed picker popup
    pub fn getPickerResult(self: *PopupManager) ?usize {
        return self.last_picker_result;
    }

    /// Check if last picker was cancelled
    pub fn wasPickerCancelled(self: *PopupManager) bool {
        return self.last_picker_cancelled;
    }

    /// Clear stored results
    pub fn clearResults(self: *PopupManager) void {
        self.last_confirm_result = null;
        self.last_picker_result = null;
        self.last_picker_cancelled = false;
    }

    /// Dismiss the active popup without waiting for user input
    pub fn dismiss(self: *PopupManager) void {
        if (self.active) |popup| {
            popup.deinit(self.allocator);
            self.active = null;
        }
    }

    /// Clear all notifications
    pub fn clearNotifications(self: *PopupManager) void {
        self.notifications.clear();
    }
};
