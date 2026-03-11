const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ghostty = @import("ghostty-vt");
const pod_protocol = core.pod_protocol;
const wire = core.wire;

const pane_capture = @import("pane_capture.zig");
const pane_output = @import("pane_output.zig");
const widgets = pop.widgets;

const pop = @import("pop");
const NotificationManager = pop.notification.NotificationManager;

const Backend = union(enum) {
    /// Pod-backed pane — VT routed through SES.
    pod: struct {
        pane_id: u16,
        vt_fd: posix.fd_t, // shared MUX VT channel fd
        dead: bool = false,
    },
};

const DcsQueryState = enum {
    idle,
    esc,
    dcs,
    dcs_esc,
};

const CsiQueryState = enum {
    idle,
    esc,
    csi,
};

/// A Pane is a ghostty VT that receives bytes via the SES VT channel
/// (pod-backed, persistent scrollback).
pub const Pane = struct {
    allocator: std.mem.Allocator = undefined,
    id: u16 = 0,
    vt: core.VT = .{},
    backend: Backend = undefined,

    // UUID for tracking (32 hex chars)
    uuid: [32]u8 = undefined,

    // Position and size in the terminal
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    // Is this pane focused?
    focused: bool = false,
    // Is this a floating pane?
    floating: bool = false,
    // Is this pane visible? (for floating panes that can be toggled)
    // For tab-bound floats, this is the simple visibility state
    visible: bool = true,
    // For global floats (parent_tab == null), per-tab visibility bitmask
    // Bit N = visible on tab N (supports up to 64 tabs)
    tab_visible: u64 = 0,
    // Key binding for this float (for matching)
    float_key: u8 = 0,
    // Outer border dimensions (for floating panes with padding)
    border_x: u16 = 0,
    border_y: u16 = 0,
    border_w: u16 = 0,
    border_h: u16 = 0,
    // Per-float style settings
    border_color: core.BorderColor = .{},
    // Float layout percentages (for resize recalculation)
    float_width_pct: u8 = 60,
    float_height_pct: u8 = 60,
    float_pos_x_pct: u8 = 50,
    float_pos_y_pct: u8 = 50,
    float_pad_x: u8 = 1,
    float_pad_y: u8 = 0,
    // For pwd floats: the directory this float is bound to
    pwd_dir: ?[]const u8 = null,
    is_pwd: bool = false,
    // Sticky float - survives mux exit, can be reattached
    sticky: bool = false,
    // Navigatable float - directional navigation works like splits
    navigatable: bool = false,
    // Cached CWD from ses daemon (for pod panes where /proc access is in ses)
    ses_cwd: ?[]const u8 = null,
    // Exit status for the most recent observed process exit, if available.
    exit_status: ?u32 = null,
    // Named floats keep their last frame after exit so the same toggle can hide
    // them cleanly and the next toggle can recreate them.
    retained_after_exit: bool = false,
    // Capture raw output for blocking floats
    capture_output: bool = false,
    captured_output: std.ArrayList(u8) = .empty,
    // Dim background when this float is visible (focus mode)
    dim_background: bool = false,
    // Exit key for adhoc floats (close float when this key is pressed)
    exit_key: ?[]const u8 = null,
    // Set when float is closed via exit key (to return error exit code)
    closed_by_exit_key: bool = false,
    // For tab-bound floats: which tab owns this float
    // null = global float (special=true or pwd=true)
    parent_tab: ?usize = null,
    // Border style and optional module
    float_style: ?*const core.FloatStyle = null,
    float_title: ?[]u8 = null,

    // Tracks whether we saw a clear-screen sequence in the last output.
    did_clear: bool = false,
    // Keep last bytes so we can detect escape sequences across boundaries.
    esc_tail: [3]u8 = .{ 0, 0, 0 },
    esc_tail_len: u8 = 0,

    // OSC passthrough (clipboard, colors, etc.)
    osc_buf: std.ArrayList(u8) = .empty,
    osc_in_progress: bool = false,
    osc_pending_esc: bool = false,
    osc_prev_esc: bool = false,
    osc_expected_responses: u16 = 0,

    // Pane-local DCS query capture (DECRQSS support)
    dcs_query_state: DcsQueryState = .idle,
    dcs_query_buf: [128]u8 = undefined,
    dcs_query_len: u8 = 0,

    // Pane-local CSI query capture (CPR support)
    csi_query_state: CsiQueryState = .idle,
    csi_query_buf: [32]u8 = undefined,
    csi_query_len: u8 = 0,
    csi_expected_responses: u16 = 0,

    // Pane-local notifications (PANE realm - renders at bottom of pane)
    notifications: NotificationManager = undefined,
    notifications_initialized: bool = false,
    // Pane-local popups (blocking at PANE level)
    popups: pop.PopupManager = undefined,
    popups_initialized: bool = false,

    // Pokemon widget
    pokemon_state: widgets.PokemonState = undefined,
    pokemon_initialized: bool = false,

    pub fn isVisibleOnTab(self: *const Pane, tab: usize) bool {
        if (self.parent_tab != null) {
            return self.visible;
        }
        if (tab >= 64) return false;
        return (self.tab_visible & (@as(u64, 1) << @intCast(tab))) != 0;
    }

    pub fn takeOscExpectedResponses(self: *Pane) u16 {
        const v = self.osc_expected_responses;
        self.osc_expected_responses = 0;
        return v;
    }

    pub fn takeCsiExpectedResponses(self: *Pane) u16 {
        const v = self.csi_expected_responses;
        self.csi_expected_responses = 0;
        return v;
    }

    pub fn setVisibleOnTab(self: *Pane, tab: usize, vis: bool) void {
        if (self.parent_tab != null) {
            self.visible = vis;
            return;
        }
        if (tab >= 64) return;
        const mask = @as(u64, 1) << @intCast(tab);
        if (vis) {
            self.tab_visible |= mask;
        } else {
            self.tab_visible &= ~mask;
        }
    }

    pub fn toggleVisibleOnTab(self: *Pane, tab: usize) void {
        self.setVisibleOnTab(tab, !self.isVisibleOnTab(tab));
    }

    /// Initialize a pane backed by a per-pane pod process.
    /// VT data is routed through the SES VT channel.
    pub fn initWithPod(self: *Pane, allocator: std.mem.Allocator, id: u16, x: u16, y: u16, width: u16, height: u16, pane_id: u16, vt_fd: posix.fd_t, uuid: [32]u8) !void {
        self.* = .{ .allocator = allocator, .id = id, .x = x, .y = y, .width = width, .height = height, .uuid = uuid };

        self.backend = .{ .pod = .{ .pane_id = pane_id, .vt_fd = vt_fd } };

        try self.vt.init(allocator, width, height);
        errdefer self.vt.deinit();

        self.notifications = NotificationManager.init(allocator);
        self.notifications_initialized = true;
        self.popups = pop.PopupManager.init(allocator);
        self.popups_initialized = true;
        self.pokemon_state = widgets.PokemonState.init(allocator);
        self.pokemon_initialized = true;

        // Tell pod initial size via VT channel.
        self.sendResizeToPod(width, height);
    }

    pub fn deinit(self: *Pane) void {
        self.vt.deinit();
        self.osc_buf.deinit(self.allocator);
        self.captured_output.deinit(self.allocator);
        if (self.pwd_dir) |dir| {
            self.allocator.free(dir);
        }
        if (self.ses_cwd) |cwd| {
            self.allocator.free(cwd);
        }
        if (self.notifications_initialized) {
            self.notifications.deinit();
        }
        if (self.popups_initialized) {
            self.popups.deinit();
        }
        if (self.pokemon_initialized) {
            self.pokemon_state.deinit();
        }
        if (self.float_title) |t| {
            self.allocator.free(t);
            self.float_title = null;
        }
        if (self.exit_key) |k| {
            self.allocator.free(k);
            self.exit_key = null;
        }
    }

    /// Set cached CWD from ses daemon (for pod panes)
    pub fn setSesCwd(self: *Pane, cwd: ?[]u8) void {
        if (self.ses_cwd) |old| {
            self.allocator.free(old);
        }
        self.ses_cwd = cwd;
    }

    /// Replace backend with a pod (used during reattach to adopt panes).
    pub fn replaceWithPod(self: *Pane, pane_id: u16, vt_fd: posix.fd_t, uuid: [32]u8) !void {
        self.uuid = uuid;
        self.backend = .{ .pod = .{ .pane_id = pane_id, .vt_fd = vt_fd } };

        // Reset VT state (will be reconstructed from pod backlog replay).
        self.vt.deinit();
        try self.vt.init(self.allocator, self.width, self.height);

        self.did_clear = false;
        self.esc_tail = .{ 0, 0, 0 };
        self.esc_tail_len = 0;
        self.osc_in_progress = false;
        self.osc_pending_esc = false;
        self.osc_prev_esc = false;
        self.osc_buf.clearRetainingCapacity();
        self.dcs_query_state = .idle;
        self.dcs_query_len = 0;
        self.csi_query_state = .idle;
        self.csi_query_len = 0;

        self.sendResizeToPod(self.width, self.height);
    }

    /// Feed output data received from the SES VT channel.
    /// Called by the event loop when a MuxVtHeader frame arrives for this pane.
    pub fn feedPodOutput(self: *Pane, data: []const u8) void {
        self.did_clear = false;
        pane_output.processOutput(self, data);
        self.vt.feed(data) catch {};
    }

    /// Write input to backend.
    pub fn write(self: *Pane, data: []const u8) !void {
        const pod = self.backend.pod;
        const frame_type = @intFromEnum(pod_protocol.FrameType.input);
        wire.writeMuxVt(pod.vt_fd, pod.pane_id, frame_type, data) catch {};
    }

    pub fn resize(self: *Pane, x: u16, y: u16, width: u16, height: u16) !void {
        self.x = x;
        self.y = y;
        if (width != self.width or height != self.height) {
            self.width = width;
            self.height = height;
            try self.vt.resize(width, height);
            self.sendResizeToPod(width, height);
        }
    }

    pub fn syncBackendSize(self: *Pane) void {
        self.sendResizeToPod(self.width, self.height);
    }

    pub fn isAlive(self: *Pane) bool {
        return !self.backend.pod.dead;
    }

    pub fn getExitCode(self: *Pane) u8 {
        const status = self.exit_status orelse return 0;
        if (posix.W.IFEXITED(status)) return posix.W.EXITSTATUS(status);
        if (posix.W.IFSIGNALED(status)) return @intCast(128 + posix.W.TERMSIG(status));
        return 0;
    }

    pub fn captureOutput(self: *Pane, allocator: std.mem.Allocator) ![]u8 {
        return pane_capture.captureOutput(self, allocator);
    }

    fn appendCapturedOutput(self: *Pane, data: []const u8) void {
        pane_capture.appendCapturedOutput(self, data);
    }

    pub fn getTerminal(self: *Pane) *ghostty.Terminal {
        return &self.vt.terminal;
    }

    /// Get a stable snapshot of the viewport for rendering.
    pub fn getRenderState(self: *Pane) !*const ghostty.RenderState {
        return self.vt.getRenderState();
    }

    /// Get cursor position relative to screen
    pub fn getCursorPos(self: *Pane) struct { x: u16, y: u16 } {
        const cursor = self.vt.getCursor();
        return .{ .x = self.x + cursor.x, .y = self.y + cursor.y };
    }

    /// Get cursor style (DECSCUSR value)
    pub fn getCursorStyle(self: *Pane) u8 {
        return self.vt.getCursorStyle();
    }

    pub fn isCursorVisible(self: *Pane) bool {
        return self.vt.isCursorVisible();
    }

    /// Get current working directory (from OSC 7)
    pub fn getPwd(self: *Pane) ?[]const u8 {
        return self.vt.getPwd();
    }

    pub fn getRealCwd(self: *Pane) ?[]const u8 {
        if (self.vt.getPwd()) |pwd| {
            return pwd;
        }
        return self.ses_cwd;
    }

    pub fn getFgPid(self: *Pane) ?posix.pid_t {
        _ = self;
        return null;
    }

    pub fn getFgProcess(self: *Pane) ?[]const u8 {
        _ = self;
        return null;
    }

    /// Get the pane_id for pod-backed panes (used for VT routing).
    pub fn getPaneId(self: *const Pane) ?u16 {
        return self.backend.pod.pane_id;
    }

    /// Scroll up by given number of lines
    pub fn scrollUp(self: *Pane, lines: u32) void {
        self.vt.terminal.scrollViewport(.{ .delta = -@as(isize, @intCast(lines)) }) catch {};
        self.vt.invalidateRenderState();
    }

    /// Scroll down by given number of lines
    pub fn scrollDown(self: *Pane, lines: u32) void {
        self.vt.terminal.scrollViewport(.{ .delta = @as(isize, @intCast(lines)) }) catch {};
        self.vt.invalidateRenderState();
    }

    /// Scroll to top of history
    pub fn scrollToTop(self: *Pane) void {
        self.vt.terminal.scrollViewport(.top) catch {};
        self.vt.invalidateRenderState();
    }

    /// Scroll to bottom (current output)
    pub fn scrollToBottom(self: *Pane) void {
        self.vt.terminal.scrollViewport(.bottom) catch {};
        self.vt.invalidateRenderState();
    }

    /// Check if we're scrolled (not at bottom)
    pub fn isScrolled(self: *Pane) bool {
        return !self.vt.terminal.screens.active.viewportIsBottom();
    }

    /// Show a notification on this pane
    pub fn showNotification(self: *Pane, message: []const u8) void {
        if (self.notifications_initialized) {
            self.notifications.show(message);
        }
    }

    /// Show a notification with custom duration
    pub fn showNotificationFor(self: *Pane, message: []const u8, duration_ms: i64) void {
        if (self.notifications_initialized) {
            self.notifications.showFor(message, duration_ms);
        }
    }

    /// Update notifications (call each frame)
    pub fn updateNotifications(self: *Pane) bool {
        if (self.notifications_initialized) {
            return self.notifications.update();
        }
        return false;
    }

    /// Update popups (call each frame) - checks for timeout
    pub fn updatePopups(self: *Pane) bool {
        if (self.popups_initialized) {
            return self.popups.update();
        }
        return false;
    }

    /// Check if pane has active notification
    pub fn hasActiveNotification(self: *Pane) bool {
        if (self.notifications_initialized) {
            return self.notifications.hasActive();
        }
        return false;
    }

    /// Configure notifications from config
    pub fn configureNotifications(self: *Pane, cfg: anytype) void {
        if (self.notifications_initialized) {
            self.notifications.default_style = pop.notification.Style.fromConfig(cfg);
            self.notifications.default_duration_ms = @intCast(cfg.duration_ms);
        }
    }

    /// Configure notifications from pop.NotificationStyle config
    pub fn configureNotificationsFromPop(self: *Pane, cfg: anytype) void {
        if (self.notifications_initialized) {
            self.notifications.default_style = pop.notification.Style.fromConfig(cfg);
            self.notifications.default_duration_ms = @intCast(cfg.duration_ms);
        }
    }
    fn sendResizeToPod(self: *Pane, cols: u16, rows: u16) void {
        const pod = self.backend.pod;
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], cols, .big);
        std.mem.writeInt(u16, payload[2..4], rows, .big);
        const frame_type = @intFromEnum(pod_protocol.FrameType.resize);
        wire.writeMuxVt(pod.vt_fd, pod.pane_id, frame_type, &payload) catch {};
    }
};
