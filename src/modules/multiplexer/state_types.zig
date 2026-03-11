const std = @import("std");
const posix = std.posix;
const core = @import("core");
const pop = @import("pop");

const layout_mod = @import("layout.zig");
const Layout = layout_mod.Layout;

const NotificationManager = pop.notification.NotificationManager;

/// Pending action that needs confirmation.
pub const PendingAction = enum {
    exit,
    /// Shell asked permission to exit (pre-exit handshake)
    exit_intent,
    detach,
    disown,
    close,
    pane_close, // Close split pane only (not tab)
    adopt_choose, // Choosing which orphaned pane to adopt
    adopt_confirm, // Confirming destroy vs swap
    layout_save_choose, // Choosing local/global/both for layout save
    layout_load_choose, // Choosing detach/replace for local layout load
};

/// A tab contains a layout with splits.
pub const Tab = struct {
    layout: Layout,
    notifications: NotificationManager,
    popups: pop.PopupManager,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16, notif_cfg: pop.NotificationStyle) Tab {
        return .{
            .layout = Layout.init(allocator, width, height),
            .notifications = NotificationManager.initWithConfig(allocator, notif_cfg),
            .popups = pop.PopupManager.init(allocator),
        };
    }

    pub fn deinit(self: *Tab) void {
        self.layout.deinit();
        self.notifications.deinit();
        self.popups.deinit();
    }
};

pub const PendingFloatRequest = struct {
    result_path: ?[]u8,
    cursor_snapshot: ?CursorSnapshot = null,
};

pub const CursorSnapshot = struct {
    source_uuid: [32]u8,
    rel_x: u16,
    rel_y: u16,
    style: u8,
    visible: bool,
};
