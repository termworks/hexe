const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ghostty = @import("ghostty-vt");
const pod_protocol = core.pod_protocol;
const wire = core.wire;

const pane_output = @import("pane_output.zig");
const vt_write_queue = @import("vt_write_queue.zig");
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
/// The State's shared mux-VT write queue, registered once at State init.
/// All pane->pod frames MUST go through it: the queue can hold a PARTIAL
/// frame after a backpressured flush, and a direct writeMuxVt would inject
/// its bytes ahead of the queued remainder — desyncing the multiplexed
/// stream for every pane on the fd. Direct writes also block the UI loop
/// for up to the 10s wire default when SES stops draining.
var shared_vt_queue: ?*vt_write_queue.Queue = null;
var shared_vt_queue_alloc: std.mem.Allocator = undefined;
const max_pending_mux_vt_bytes: usize = 8 * 1024 * 1024;

pub fn setSharedVtWriteQueue(queue: *vt_write_queue.Queue, allocator: std.mem.Allocator) void {
    shared_vt_queue = queue;
    shared_vt_queue_alloc = allocator;
}

fn queuePodFrame(pane_id: u16, vt_fd: std.posix.fd_t, frame_type: u8, payload: []const u8) !void {
    if (shared_vt_queue) |queue| {
        const queued = queue.enqueueFrame(shared_vt_queue_alloc, pane_id, frame_type, payload, max_pending_mux_vt_bytes) catch {
            return error.WriteFailed;
        };
        if (!queued) return error.WriteFailed;
        return;
    }
    // No queue registered (tests / probe contexts): direct bounded write.
    try wire.writeMuxVt(vt_fd, pane_id, frame_type, payload);
}

pub const Pane = struct {
    allocator: std.mem.Allocator = undefined,
    id: u16 = 0,
    vt: core.VT = .{},
    backend: Backend = undefined,
    /// True while the pod's backlog replay is in flight (cleared by the
    /// backlog_end frame). Replay chunks feed the VT without scheduling a
    /// render each — repainting per chunk is what made reattaching to a
    /// large-history pane feel stuck.
    backlog_replaying: bool = false,

    // UUID for tracking (32 hex chars)
    uuid: [32]u8 = undefined,

    // Position and size in the terminal
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    // Is this pane focused?
    focused: bool = false,
    // Tracks whether we saw a clear-screen sequence in the last output.
    did_clear: bool = false,
    last_reported_password_input: bool = false,
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

    /// Initialize a pane backed by a per-pane pod process.
    /// VT data is routed through the SES VT channel.
    pub fn initWithPod(self: *Pane, allocator: std.mem.Allocator, id: u16, x: u16, y: u16, width: u16, height: u16, pane_id: u16, vt_fd: posix.fd_t, uuid: [32]u8) !void {
        self.* = .{ .allocator = allocator, .id = id, .x = x, .y = y, .width = width, .height = height, .uuid = uuid };

        self.backend = .{ .pod = .{ .pane_id = pane_id, .vt_fd = vt_fd } };
        self.backlog_replaying = true;

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
        if (self.notifications_initialized) {
            self.notifications.deinit();
        }
        if (self.popups_initialized) {
            self.popups.deinit();
        }
        if (self.pokemon_initialized) {
            self.pokemon_state.deinit();
        }
    }

    /// Replace backend with a pod (used during reattach to adopt panes).
    pub fn replaceWithPod(self: *Pane, pane_id: u16, vt_fd: posix.fd_t, uuid: [32]u8) !void {
        self.backlog_replaying = true;
        self.uuid = uuid;
        self.backend = .{ .pod = .{ .pane_id = pane_id, .vt_fd = vt_fd } };

        // Reset VT state (will be reconstructed from pod backlog replay).
        self.vt.deinit();
        try self.vt.init(self.allocator, self.width, self.height);

        self.did_clear = false;
        self.last_reported_password_input = false;
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
        self.vt.feed(data) catch |err| {
            core.logging.logError("terminal", "pane VT feed failed", err);
            return;
        };
        const password_input = self.vt.terminal.flags.password_input;
        if (password_input != self.last_reported_password_input) {
            self.sendPasswordModeToPod(password_input);
            self.last_reported_password_input = password_input;
        }
    }

    /// Write input to backend.
    pub fn write(self: *Pane, data: []const u8) !void {
        const pod = self.backend.pod;
        const frame_type = @intFromEnum(pod_protocol.FrameType.input);
        try queuePodFrame(pod.pane_id, pod.vt_fd, frame_type, data);
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
        self.vt.terminal.scrollViewport(.{ .delta = -@as(isize, @intCast(lines)) }) catch |err| {
            core.logging.logError("terminal", "scroll up failed", err);
        };
        self.vt.invalidateRenderState();
    }

    /// Scroll down by given number of lines
    pub fn scrollDown(self: *Pane, lines: u32) void {
        self.vt.terminal.scrollViewport(.{ .delta = @as(isize, @intCast(lines)) }) catch |err| {
            core.logging.logError("terminal", "scroll down failed", err);
        };
        self.vt.invalidateRenderState();
    }

    /// Scroll to top of history
    pub fn scrollToTop(self: *Pane) void {
        self.vt.terminal.scrollViewport(.top) catch |err| {
            core.logging.logError("terminal", "scroll to top failed", err);
        };
        self.vt.invalidateRenderState();
    }

    /// Scroll to bottom (current output)
    pub fn scrollToBottom(self: *Pane) void {
        self.vt.terminal.scrollViewport(.bottom) catch |err| {
            core.logging.logError("terminal", "scroll to bottom failed", err);
        };
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
        queuePodFrame(pod.pane_id, pod.vt_fd, frame_type, &payload) catch |err| {
            core.logging.logError("terminal", "pane resize mux write failed", err);
        };
    }

    fn sendPasswordModeToPod(self: *Pane, enabled: bool) void {
        const pod = self.backend.pod;
        const payload = [_]u8{@intFromBool(enabled)};
        const frame_type = @intFromEnum(pod_protocol.FrameType.password_mode);
        queuePodFrame(pod.pane_id, pod.vt_fd, frame_type, &payload) catch |err| {
            core.logging.logError("terminal", "pane password-mode mux write failed", err);
        };
    }
};
