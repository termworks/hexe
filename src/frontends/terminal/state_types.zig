const std = @import("std");
const posix = std.posix;
const core = @import("core");
const pop = @import("pop");

const layout_mod = @import("layout.zig");
const Layout = layout_mod.Layout;
const Pane = @import("pane.zig").Pane;

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
    /// Bare `hexe` startup, level 1: exactly one session rooted at this cwd.
    startup_attach_confirm,
    /// Bare `hexe` startup, level 1: several sessions rooted at this cwd.
    startup_attach_choose,
    /// Bare `hexe` startup, level 2: a local .hexe.lua exists.
    startup_layout_confirm,
};

/// A terminal tab view contains only terminal widgets for one projected tab.
pub const TabView = struct {
    layout: Layout,
    notifications: NotificationManager,
    popups: pop.PopupManager,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16, notif_cfg: pop.NotificationStyle) TabView {
        return .{
            .layout = Layout.init(allocator, width, height),
            .notifications = NotificationManager.initWithConfig(allocator, notif_cfg),
            .popups = pop.PopupManager.init(allocator),
        };
    }

    pub fn deinit(self: *TabView) void {
        self.layout.deinit();
        self.notifications.deinit();
        self.popups.deinit();
    }
};

pub const TerminalViewState = struct {
    /// Visual tab widgets derived from the shared projection.
    tab_views: std.ArrayList(TabView),
    /// Visual float widgets derived from the shared projection.
    float_views: std.ArrayList(*Pane),

    pub fn init() TerminalViewState {
        return .{
            .tab_views = .empty,
            .float_views = .empty,
        };
    }

    pub fn deinit(self: *TerminalViewState, allocator: std.mem.Allocator) void {
        for (self.float_views.items) |pane| {
            pane.deinit();
            allocator.destroy(pane);
        }
        self.float_views.deinit(allocator);

        for (self.tab_views.items) |*tab| {
            tab.deinit();
        }
        self.tab_views.deinit(allocator);
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

pub const FloatUiState = struct {
    border_x: u16 = 0,
    border_y: u16 = 0,
    border_w: u16 = 0,
    border_h: u16 = 0,
    border_color: core.BorderColor = .{},
    width_pct: u8 = 60,
    height_pct: u8 = 60,
    pos_x_pct: u8 = 50,
    pos_y_pct: u8 = 50,
    pad_x: u8 = 1,
    pad_y: u8 = 0,
    pwd_dir: ?[]u8 = null,
    navigatable: bool = false,
    retained_after_exit: bool = false,
    capture_output: bool = false,
    exit_key: ?[]u8 = null,
    closed_by_exit_key: bool = false,
    float_style: ?*const core.FloatStyle = null,
    float_title: ?[]u8 = null,

    pub fn deinit(self: *FloatUiState, allocator: std.mem.Allocator) void {
        if (self.pwd_dir) |dir| {
            allocator.free(dir);
        }
        if (self.exit_key) |key| {
            allocator.free(key);
        }
        if (self.float_title) |title| {
            allocator.free(title);
        }
        self.* = .{};
    }
};
