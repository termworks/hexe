const std = @import("std");
const posix = std.posix;

const core = @import("core");
const pop = @import("pop");

const state_types = @import("state_types.zig");
pub const PendingAction = state_types.PendingAction;
pub const Tab = state_types.Tab;
pub const PendingFloatRequest = state_types.PendingFloatRequest;
pub const CursorSnapshot = state_types.CursorSnapshot;

const layout_mod = @import("layout.zig");
const Layout = layout_mod.Layout;

const Renderer = @import("render_core.zig").Renderer;

const FrontendAttachState = core.FrontendAttachState;
const FrontendSessionCache = core.FrontendSessionCache;
const PaneShellInfo = core.FrontendPaneShellInfo;
const PaneProcInfo = core.FrontendPaneProcInfo;
const SesClient = core.FrontendClient;

const NotificationManager = pop.notification.NotificationManager;

const OverlayManager = pop.overlay.OverlayManager;

const Pane = @import("pane.zig").Pane;
const VtWriteQueue = @import("vt_write_queue.zig").Queue;

const BindKey = core.Config.BindKey;
const BindAction = core.Config.BindAction;
/// Simple focus context for timer storage (float vs split).
pub const FocusContext = enum { split, float };

const state_tabs = @import("state_tabs.zig");
const state_serialize = @import("state_serialize.zig");
const state_sync = @import("state_sync.zig");
const state_session = @import("state_session.zig");
const mouse_selection = @import("mouse_selection.zig");

pub const TabFocusKind = core.FrontendTabFocusKind;

const max_pending_mux_vt_bytes: usize = 8 * 1024 * 1024;

pub const PaneBounds = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};

pub const State = struct {
    /// Get float definition by key from active layout
    pub fn getLayoutFloatByKey(self: *const State, key: u8) ?*const core.LayoutFloatDef {
        for (self.active_layout_floats) |*f| {
            if (f.key == key) return f;
        }
        return null;
    }
    pub const MouseDragSplitResize = struct {
        split: *layout_mod.LayoutNode.Split,
        dir: layout_mod.SplitDir,
        x: u16,
        y: u16,
        w: u16,
        h: u16,
    };

    pub const MouseDragFloatMove = struct {
        uuid: [32]u8,
        start_x: u16,
        start_y: u16,
        orig_x: u16,
        orig_y: u16,
    };

    pub const MouseDragFloatResize = struct {
        uuid: [32]u8,
        edge_mask: u8,
        start_x: u16,
        start_y: u16,
        orig_x: u16,
        orig_y: u16,
        orig_w: u16,
        orig_h: u16,
    };

    pub const MouseDrag = union(enum) {
        none,
        split_resize: MouseDragSplitResize,
        float_move: MouseDragFloatMove,
        float_resize: MouseDragFloatResize,
    };

    allocator: std.mem.Allocator,
    config: core.Config,
    pop_config: pop.PopConfig,
    ses_config: core.SesConfig,
    session_cache: FrontendSessionCache,
    active_layout_floats: []const core.LayoutFloatDef,
    tabs: std.ArrayList(Tab),
    active_tab: usize,
    floats: std.ArrayList(*Pane),
    active_floating: ?usize,
    running: bool,
    needs_render: bool,
    force_full_render: bool,
    /// When true, force cursor visible on next render (set after float death)
    cursor_needs_restore: bool,
    /// One-shot cursor snapshot restored after transient CLI float exits.
    cursor_restore_snapshot: ?CursorSnapshot,
    term_width: u16,
    term_height: u16,
    status_height: u16,
    layout_width: u16,
    layout_height: u16,
    renderer: Renderer,
    ses_client: SesClient,
    notifications: NotificationManager,
    overlays: OverlayManager,
    popups: pop.PopupManager,
    pending_action: ?PendingAction,
    exit_from_shell_death: bool,
    pending_exit_intent: bool,
    /// If non-zero and in the future, skip confirm_on_exit for the next last-pane death.
    exit_intent_deadline_ms: i64,
    /// If true, respawn the focused pane after handling input
    needs_respawn: bool,
    attach_state: FrontendAttachState,
    skip_dead_check: bool,
    pending_pop_response: bool,
    pending_pop_scope: pop.Scope,
    pending_pop_tab: usize,
    pending_pop_pane: ?*Pane,

    osc_reply_target_uuid: ?[32]u8,
    osc_reply_targets: std.ArrayList([32]u8),
    osc_reply_target_enqueued_ms: std.ArrayList(i64),
    osc_reply_buf: std.ArrayList(u8),
    osc_reply_in_progress: bool,
    osc_reply_prev_esc: bool,

    csi_reply_target_uuid: ?[32]u8,
    csi_reply_targets: std.ArrayList([32]u8),
    csi_reply_target_enqueued_ms: std.ArrayList(i64),
    csi_reply_buf: std.ArrayList(u8),
    csi_reply_in_progress: bool,

    mux_vt_write_queue: VtWriteQueue,
    mux_vt_write_overflow_notified: bool,

    // Stdin input can arrive split across reads. When using escape-sequence based
    // encodings (CSI-u, mouse events, etc) we must not forward partial sequences
    // into the focused pane. Keep a small tail buffer to stitch reads.
    stdin_tail: [256]u8 = undefined,
    stdin_tail_len: u8 = 0,

    // Track bracketed paste mode to suppress keycast during paste
    in_bracketed_paste: bool = false,
    bracketed_paste_target_uuid: ?[32]u8 = null,
    bracketed_paste_buf: std.ArrayList(u8) = .empty,

    // Terminal capability query lifecycle for custom event loop mode.
    terminal_query_in_flight: bool = false,
    terminal_query_deadline_ms: i64 = 0,
    terminal_caps_ready: bool = false,
    terminal_query_timed_out: bool = false,

    // Drop one stdin batch after focus handoff to a newly spawned float.
    drop_next_input_batch: bool = false,

    pending_float_requests: std.AutoHashMap([32]u8, PendingFloatRequest),

    mouse_selection: mouse_selection.MouseSelection,
    mouse_selection_last_autoscroll_ms: i64,

    mouse_drag: MouseDrag,

    // Float title rename (inline editing)
    float_rename_uuid: ?[32]u8,
    float_rename_buf: std.ArrayList(u8),

    // Title click counter (for double-click rename)
    mouse_title_last_ms: i64,
    mouse_title_click_count: u8,
    mouse_title_last_uuid: ?[32]u8,
    mouse_title_last_x: u16,
    mouse_title_last_y: u16,

    mouse_click_last_ms: i64,
    mouse_click_count: u8,
    mouse_click_last_pane_uuid: ?[32]u8,
    mouse_click_last_x: u16,
    mouse_click_last_y: u16,

    // Keybinding timers (hold/double-tap delayed press)
    key_timers: std.ArrayList(PendingKeyTimer),

    // Scroll acceleration tracking
    scroll_repeat_count: u8 = 0,
    last_scroll_key: u8 = 0, // 5=pageup, 6=pagedown
    last_scroll_time_ms: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16, debug: bool, log_file: ?[]const u8) !State {
        const cfg = core.Config.load(allocator);
        const pop_cfg = pop.PopConfig.load(allocator);
        const ses_cfg = core.SesConfig.load(allocator);

        // Find enabled layout's floats and merge with default attributes
        var layout_floats: []const core.LayoutFloatDef = &[_]core.LayoutFloatDef{};
        for (ses_cfg.layouts) |*layout| {
            if (layout.enabled) {
                // Merge default attributes into each float definition
                const floats_with_defaults = allocator.alloc(core.LayoutFloatDef, layout.floats.len) catch {
                    layout_floats = layout.floats;
                    break;
                };
                for (layout.floats, 0..) |float_def, i| {
                    var merged = float_def;
                    if (!float_def.has_custom_attributes) {
                        // Float has no custom attributes table - use all defaults
                        merged.attributes = cfg.float_default_attributes;
                    } else {
                        // Float has custom attributes - merge with defaults using OR
                        // This means: if default is true, it stays true unless float explicitly overrides
                        // If float sets something true, it becomes true
                        // Limitation: can't explicitly set to false when default is true
                        merged.attributes.exclusive = cfg.float_default_attributes.exclusive or float_def.attributes.exclusive;
                        merged.attributes.sticky = cfg.float_default_attributes.sticky or float_def.attributes.sticky;
                        merged.attributes.global = cfg.float_default_attributes.global or float_def.attributes.global;
                        merged.attributes.destroy = cfg.float_default_attributes.destroy or float_def.attributes.destroy;
                        merged.attributes.isolated = cfg.float_default_attributes.isolated or float_def.attributes.isolated;
                        merged.attributes.per_cwd = cfg.float_default_attributes.per_cwd or float_def.attributes.per_cwd;
                        merged.attributes.inherit_env = cfg.float_default_attributes.inherit_env or float_def.attributes.inherit_env;
                    }
                    floats_with_defaults[i] = merged;
                }
                layout_floats = floats_with_defaults;
                break;
            }
        }

        const status_h: u16 = if (cfg.tabs.status.enabled) 1 else 0;
        const layout_h = height - status_h;

        const uuid = core.ipc.generateUuid();
        const session_name = core.ipc.generateSessionName();

        return .{
            .allocator = allocator,
            .config = cfg,
            .pop_config = pop_cfg,
            .ses_config = ses_cfg,
            .session_cache = try FrontendSessionCache.init(allocator, uuid, session_name),
            .active_layout_floats = layout_floats,
            .tabs = .empty,
            .active_tab = 0,
            .floats = .empty,
            .active_floating = null,
            .running = true,
            .needs_render = true,
            .force_full_render = true,
            .cursor_needs_restore = false,
            .cursor_restore_snapshot = null,
            .term_width = width,
            .term_height = height,
            .status_height = status_h,
            .layout_width = width,
            .layout_height = layout_h,
            .renderer = try Renderer.init(allocator, width, height),
            .ses_client = SesClient.initLocalIpc(allocator, uuid, session_name, true, debug, log_file, .terminal),
            .notifications = NotificationManager.initWithConfig(allocator, pop_cfg.carrier.notification),
            .overlays = OverlayManager.initWithConfig(allocator, pop_cfg.widgets.keycast),
            .popups = pop.PopupManager.init(allocator),
            .pending_action = null,
            .exit_from_shell_death = false,
            .pending_exit_intent = false,
            .exit_intent_deadline_ms = 0,
            .needs_respawn = false,
            .attach_state = .{},
            .skip_dead_check = false,
            .pending_pop_response = false,
            .pending_pop_scope = .mux,
            .pending_pop_tab = 0,
            .pending_pop_pane = null,

            .osc_reply_target_uuid = null,
            .osc_reply_targets = .empty,
            .osc_reply_target_enqueued_ms = .empty,
            .osc_reply_buf = .empty,
            .osc_reply_in_progress = false,
            .osc_reply_prev_esc = false,

            .csi_reply_target_uuid = null,
            .csi_reply_targets = .empty,
            .csi_reply_target_enqueued_ms = .empty,
            .csi_reply_buf = .empty,
            .csi_reply_in_progress = false,

            .mux_vt_write_queue = .{},
            .mux_vt_write_overflow_notified = false,

            .terminal_query_in_flight = false,
            .terminal_query_deadline_ms = 0,
            .terminal_caps_ready = false,
            .terminal_query_timed_out = false,
            .drop_next_input_batch = false,

            .pending_float_requests = std.AutoHashMap([32]u8, PendingFloatRequest).init(allocator),

            .mouse_selection = .{},
            .mouse_selection_last_autoscroll_ms = 0,

            .mouse_drag = .none,

            .float_rename_uuid = null,
            .float_rename_buf = .empty,

            .mouse_title_last_ms = 0,
            .mouse_title_click_count = 0,
            .mouse_title_last_uuid = null,
            .mouse_title_last_x = 0,
            .mouse_title_last_y = 0,

            .mouse_click_last_ms = 0,
            .mouse_click_count = 0,
            .mouse_click_last_pane_uuid = null,
            .mouse_click_last_x = 0,
            .mouse_click_last_y = 0,

            .key_timers = .empty,
        };
    }

    pub fn beginFloatRename(self: *State, pane: *Pane) void {
        const title = pane.float_title orelse return;
        if (title.len == 0) return;

        self.float_rename_uuid = pane.uuid;
        self.float_rename_buf.clearRetainingCapacity();

        const cap: usize = 64;
        const slice = title[0..@min(title.len, cap)];
        self.float_rename_buf.appendSlice(self.allocator, slice) catch {};
        self.needs_render = true;
    }

    pub fn clearFloatRename(self: *State) void {
        self.float_rename_uuid = null;
        self.float_rename_buf.clearRetainingCapacity();
        self.needs_render = true;
    }

    pub fn commitFloatRename(self: *State) void {
        const uuid = self.float_rename_uuid orelse return;
        const pane = self.findPaneByUuid(uuid) orelse {
            self.clearFloatRename();
            return;
        };

        const new_title = std.mem.trim(u8, self.float_rename_buf.items, " \t\r\n");
        if (pane.float_title) |old| {
            self.allocator.free(old);
            pane.float_title = null;
        }
        if (new_title.len > 0) {
            pane.float_title = self.allocator.dupe(u8, new_title) catch null;
        }

        // Don't update pane name to float title - keep the pod's Pokemon name
        // Best-effort: store title in ses memory for reattach.
        // if (self.ses_client.isConnected()) {
        //     self.ses_client.updatePaneName(pane.uuid, pane.float_title) catch {};
        // }

        self.clearFloatRename();
        self.renderer.invalidate();
        self.force_full_render = true;
        self.syncSessionFloat(pane, self.active_floating != null);
    }

    pub fn deinit(self: *State) void {
        // If the terminal is gone (window closed, SSH dropped), auto-detach to
        // preserve sessions even when SIGTERM arrived instead of SIGHUP.
        // tcgetattr returns EIO on a dead PTY slave.
        if (!self.attach_state.detach_mode) {
            _ = posix.tcgetattr(posix.STDIN_FILENO) catch {
                self.attach_state.detach_mode = true;
            };
        }

        // When exiting normally (not detach), tell SES to kill regular panes but
        // preserve sticky panes/floats.
        // When detaching, panes stay alive for later reattach.
        if (!self.attach_state.detach_mode and self.ses_client.isConnected()) {
            self.ses_client.shutdown(true) catch |err| {
                core.logging.logError("mux", "failed to send shutdown to SES", err);
            };
        }

        self.key_timers.deinit(self.allocator);

        // Deinit floats.
        for (self.floats.items) |pane| {
            pane.deinit();
            self.allocator.destroy(pane);
        }
        self.floats.deinit(self.allocator);

        for (self.tabs.items) |*tab| {
            tab.deinit();
        }
        self.tabs.deinit(self.allocator);
        self.session_cache.deinit();
        self.config.deinit();
        var ses_cfg = self.ses_config;
        ses_cfg.deinit(self.allocator);
        self.osc_reply_targets.deinit(self.allocator);
        self.osc_reply_target_enqueued_ms.deinit(self.allocator);
        self.osc_reply_buf.deinit(self.allocator);
        self.csi_reply_targets.deinit(self.allocator);
        self.csi_reply_target_enqueued_ms.deinit(self.allocator);
        self.csi_reply_buf.deinit(self.allocator);
        self.mux_vt_write_queue.deinit(self.allocator);
        self.bracketed_paste_buf.deinit(self.allocator);
        self.renderer.deinit();
        self.ses_client.deinit();
        self.notifications.deinit();
        self.overlays.deinit();
        self.popups.deinit();
        var req_it = self.pending_float_requests.iterator();
        while (req_it.next()) |entry| {
            if (entry.value_ptr.result_path) |path| {
                self.allocator.free(path);
            }
        }
        self.pending_float_requests.deinit();

        self.float_rename_buf.deinit(self.allocator);
    }

    pub fn enqueueOscReplyTarget(self: *State, uuid: [32]u8) void {
        self.osc_reply_targets.append(self.allocator, uuid) catch {};
        self.osc_reply_target_enqueued_ms.append(self.allocator, std.time.milliTimestamp()) catch {
            if (self.osc_reply_targets.items.len > 0) {
                _ = self.osc_reply_targets.pop();
            }
        };
    }

    pub fn dequeueOscReplyTarget(self: *State) ?[32]u8 {
        const now_ms = std.time.milliTimestamp();
        while (self.osc_reply_targets.items.len > 0) {
            const queued_at = if (self.osc_reply_target_enqueued_ms.items.len > 0)
                self.osc_reply_target_enqueued_ms.items[0]
            else
                now_ms;
            const next = self.osc_reply_targets.items[0];
            _ = self.osc_reply_targets.orderedRemove(0);
            if (self.osc_reply_target_enqueued_ms.items.len > 0) {
                _ = self.osc_reply_target_enqueued_ms.orderedRemove(0);
            }

            // Drop stale expected replies so old panes cannot monopolize routing.
            if (now_ms - queued_at > 1200) continue;
            return next;
        }
        return null;
    }

    pub fn enqueueCsiReplyTarget(self: *State, uuid: [32]u8) void {
        self.csi_reply_targets.append(self.allocator, uuid) catch {};
        self.csi_reply_target_enqueued_ms.append(self.allocator, std.time.milliTimestamp()) catch {
            if (self.csi_reply_targets.items.len > 0) {
                _ = self.csi_reply_targets.pop();
            }
        };
    }

    pub fn dequeueCsiReplyTarget(self: *State) ?[32]u8 {
        const now_ms = std.time.milliTimestamp();
        while (self.csi_reply_targets.items.len > 0) {
            const queued_at = if (self.csi_reply_target_enqueued_ms.items.len > 0)
                self.csi_reply_target_enqueued_ms.items[0]
            else
                now_ms;
            const next = self.csi_reply_targets.items[0];
            _ = self.csi_reply_targets.orderedRemove(0);
            if (self.csi_reply_target_enqueued_ms.items.len > 0) {
                _ = self.csi_reply_target_enqueued_ms.orderedRemove(0);
            }

            if (now_ms - queued_at > 1200) continue;
            return next;
        }
        return null;
    }

    fn handleMuxVtWriteFailure(self: *State, fd: posix.fd_t) void {
        self.mux_vt_write_queue.clear();
        if (self.ses_client.vt_fd) |live_fd| {
            if (live_fd == fd) {
                posix.close(live_fd);
                self.ses_client.vt_fd = null;
            }
        }
        self.notifications.showFor("Warning: Lost connection to ses daemon (VT channel) - panes frozen", 5000);
        self.needs_render = true;
    }

    fn noteMuxVtQueueOverflow(self: *State) void {
        if (self.mux_vt_write_overflow_notified) return;
        self.mux_vt_write_overflow_notified = true;
        self.notifications.showFor("Pane input queue full; some pasted bytes were dropped", 3000);
        self.needs_render = true;
    }

    pub fn flushPendingMuxVtWrites(self: *State) void {
        const fd = self.ses_client.getVtFd() orelse return;
        self.mux_vt_write_queue.flushToFd(fd) catch {
            self.handleMuxVtWriteFailure(fd);
            return;
        };
        if (self.mux_vt_write_queue.queuedBytes() == 0) {
            self.mux_vt_write_overflow_notified = false;
        }
    }

    pub fn writePaneInput(self: *State, pane: *Pane, data: []const u8) void {
        if (data.len == 0) return;
        const pod = pane.backend.pod;
        self.flushPendingMuxVtWrites();
        const frame_type = @intFromEnum(core.pod_protocol.FrameType.input);
        const queued = self.mux_vt_write_queue.enqueueFrame(
            self.allocator,
            pod.pane_id,
            frame_type,
            data,
            max_pending_mux_vt_bytes,
        ) catch {
            self.noteMuxVtQueueOverflow();
            return;
        };
        if (!queued) {
            self.noteMuxVtQueueOverflow();
            return;
        }
        self.flushPendingMuxVtWrites();
    }

    pub const PendingKeyTimerKind = enum { delayed_press, tap_pending, hold, hold_fired, repeat_wait, repeat_active, repeat_locked };

    pub const PendingKeyTimer = struct {
        kind: PendingKeyTimerKind,
        deadline_ms: i64,
        mods: u8,
        key: BindKey,
        action: BindAction,
        focus_ctx: FocusContext,
        press_start_ms: i64 = 0, // When the key was first pressed (for tap vs repeat detection)
        is_repeat: bool = false, // True if this press was part of a repeat sequence (don't fire tap)
    };

    pub fn nextKeyTimerDeadlineMs(self: *const State, now_ms: i64) ?i64 {
        var next: ?i64 = null;
        for (self.key_timers.items) |t| {
            if (t.kind == .hold_fired) continue;
            if (t.kind == .repeat_wait or t.kind == .repeat_active) continue;
            // tap_pending needs to fire to trigger deferred tap action
            if (t.deadline_ms <= now_ms) return now_ms;
            const d = t.deadline_ms;
            if (next == null or d < next.?) next = d;
        }
        return next;
    }

    pub fn currentLayout(self: *State) *Layout {
        return state_tabs.currentLayout(self);
    }

    pub fn sessionUuid(self: *const State) [32]u8 {
        return self.session_cache.sessionUuid();
    }

    pub fn sessionName(self: *const State) []const u8 {
        return self.session_cache.sessionName();
    }

    pub fn sessionTabCounter(self: *const State) usize {
        return self.session_cache.tab_counter;
    }

    pub fn isDetachMode(self: *const State) bool {
        return self.attach_state.detach_mode;
    }

    pub fn setDetachMode(self: *State, enabled: bool) void {
        self.attach_state.setDetachMode(enabled);
    }

    pub fn nextStateVersion(self: *State) u32 {
        return self.attach_state.nextStateVersion();
    }

    pub fn activeTabIndex(self: *const State) usize {
        return self.session_cache.activeTab(self.tabs.items.len);
    }

    pub fn setActiveTabIndex(self: *State, idx: usize) void {
        const clamped = if (self.tabs.items.len == 0) 0 else @min(idx, self.tabs.items.len - 1);
        self.session_cache.setActiveTab(clamped);
        self.active_tab = clamped;
    }

    pub fn focusedPaneUuid(self: *const State) ?[32]u8 {
        return self.session_cache.focusedPaneUuid();
    }

    pub fn setFocusedPaneUuid(self: *State, uuid: ?[32]u8) void {
        self.session_cache.setFocusedPaneUuid(uuid);
    }

    pub fn setSessionIdentity(self: *State, uuid: [32]u8, session_name: []const u8) bool {
        self.session_cache.setSessionIdentity(uuid, session_name) catch return false;
        self.ses_client.session_id = self.session_cache.sessionUuid();
        self.ses_client.session_name = self.session_cache.sessionName();
        return true;
    }

    pub fn setSessionName(self: *State, session_name: []const u8) bool {
        return self.setSessionIdentity(self.sessionUuid(), session_name);
    }

    pub fn setSessionTabCounter(self: *State, tab_counter: usize) void {
        self.session_cache.setTabCounter(tab_counter);
    }

    pub fn takeNextTabCounter(self: *State) usize {
        return self.session_cache.takeNextTabCounter();
    }

    pub fn replaceAttachedSessionSnapshot(self: *State, snapshot: core.session_model.SessionSnapshot) bool {
        self.session_cache.replaceAttachedSnapshotOwned(snapshot) catch return false;
        self.ses_client.session_id = self.session_cache.sessionUuid();
        self.ses_client.session_name = self.session_cache.sessionName();
        self.setActiveTabIndex(self.session_cache.activeTab(self.tabs.items.len));
        self.setActiveFloatingUuid(self.session_cache.activeFloatUuid());
        return true;
    }

    pub fn resetTabFocusMemory(self: *State) bool {
        self.session_cache.resetTabFocusMemory(self.tabs.items.len) catch return false;
        return true;
    }

    pub fn clearTabFocusMemory(self: *State) void {
        self.session_cache.clearTabFocusMemory();
    }

    pub fn clearTabMeta(self: *State) void {
        self.session_cache.clearTabMeta();
    }

    pub fn appendTabMeta(self: *State, uuid: [32]u8, name: []const u8) bool {
        self.session_cache.appendTab(uuid, name) catch return false;
        return true;
    }

    pub fn removeTabMeta(self: *State, idx: usize) void {
        self.session_cache.removeTab(idx);
    }

    pub fn tabUuid(self: *const State, idx: usize) ?[32]u8 {
        return self.session_cache.tabUuid(idx);
    }

    pub fn tabName(self: *const State, idx: usize) []const u8 {
        return self.session_cache.tabName(idx) orelse "tab";
    }

    pub fn activeFloatingIndex(self: *State) ?usize {
        if (self.session_cache.activeFloatUuid()) |uuid| {
            if (self.active_floating) |idx| {
                if (idx < self.floats.items.len and std.mem.eql(u8, &self.floats.items[idx].uuid, &uuid)) {
                    return idx;
                }
            }
            for (self.floats.items, 0..) |pane, idx| {
                if (std.mem.eql(u8, &pane.uuid, &uuid)) {
                    self.active_floating = idx;
                    return idx;
                }
            }
        }
        self.active_floating = null;
        self.session_cache.setActiveFloatUuid(null);
        return null;
    }

    pub fn setActiveFloatingIndex(self: *State, idx: ?usize) void {
        if (idx) |value| {
            if (value < self.floats.items.len) {
                self.active_floating = value;
                self.session_cache.setActiveFloatUuid(self.floats.items[value].uuid);
                return;
            }
        }
        self.active_floating = null;
        self.session_cache.setActiveFloatUuid(null);
    }

    pub fn setActiveFloatingUuid(self: *State, uuid: ?[32]u8) void {
        self.session_cache.setActiveFloatUuid(uuid);
        if (uuid) |live_uuid| {
            for (self.floats.items, 0..) |pane, idx| {
                if (std.mem.eql(u8, &pane.uuid, &live_uuid)) {
                    self.active_floating = idx;
                    return;
                }
            }
        }
        self.active_floating = null;
    }

    pub fn appendTabFocusMemory(self: *State) bool {
        self.session_cache.appendTabFocusMemory() catch return false;
        return true;
    }

    pub fn removeTabFocusMemory(self: *State, idx: usize) void {
        self.session_cache.removeTabFocusMemory(idx);
    }

    pub fn rememberFloatingFocus(self: *State, pane: *Pane) void {
        self.session_cache.rememberFloatingFocus(self.active_tab, pane.uuid);
    }

    pub fn rememberSplitFocus(self: *State) void {
        self.session_cache.rememberSplitFocus(self.active_tab);
    }

    pub fn lastFocusKindForTab(self: *const State, idx: usize) ?TabFocusKind {
        return self.session_cache.lastFocusKind(idx);
    }

    pub fn lastFloatingUuidForTab(self: *const State, idx: usize) ?[32]u8 {
        return self.session_cache.lastFloatingUuid(idx);
    }

    pub fn findPaneByUuid(self: *State, uuid: [32]u8) ?*Pane {
        return state_tabs.findPaneByUuid(self, uuid);
    }

    pub fn findPaneByPaneId(self: *State, pane_id: u16) ?*Pane {
        return state_tabs.findPaneByPaneId(self, pane_id);
    }

    pub fn createTab(self: *State) !void {
        return state_tabs.createTab(self);
    }

    pub fn closeCurrentTab(self: *State) bool {
        return state_tabs.closeCurrentTab(self);
    }

    pub fn adoptStickyPanes(self: *State) void {
        return state_tabs.adoptStickyPanes(self);
    }

    pub fn adoptAsFloat(self: *State, uuid: [32]u8, pane_id: u16, float_def: *const core.LayoutFloatDef, cwd: []const u8) !void {
        return state_tabs.adoptAsFloat(self, uuid, pane_id, float_def, cwd);
    }

    pub fn nextTab(self: *State) void {
        return state_tabs.nextTab(self);
    }

    pub fn prevTab(self: *State) void {
        return state_tabs.prevTab(self);
    }

    pub fn adoptOrphanedPane(self: *State) bool {
        return state_tabs.adoptOrphanedPane(self);
    }

    pub fn reattachSession(self: *State, session_id_prefix: []const u8) bool {
        return state_tabs.reattachSession(self, session_id_prefix);
    }

    pub fn applySessionSnapshot(self: *State, session_state_json: []const u8) bool {
        return state_tabs.applySessionSnapshot(self, session_state_json);
    }

    pub fn attachOrphanedPane(self: *State, uuid_prefix: []const u8) bool {
        return state_tabs.attachOrphanedPane(self, uuid_prefix);
    }

    pub fn applySessionConfig(self: *State, config: core.SessionConfig, tab_filter: ?[]const u8) !void {
        return state_session.applySessionConfig(self, config, tab_filter);
    }

    pub fn replaceWithSessionConfig(self: *State, config: core.SessionConfig, tab_filter: ?[]const u8) !void {
        return state_session.replaceWithSessionConfig(self, config, tab_filter);
    }

    pub fn serializeState(self: *State) ![]const u8 {
        return state_serialize.serializeState(self);
    }

    pub fn serializeLayoutNode(self: *State, writer: anytype, node: *layout_mod.LayoutNode) !void {
        return state_serialize.serializeLayoutNode(self, writer, node);
    }

    pub fn serializePane(self: *State, writer: anytype, pane: *Pane) !void {
        return state_serialize.serializePane(self, writer, pane);
    }

    pub fn deserializeLayoutNode(self: *State, obj: std.json.ObjectMap) !*layout_mod.LayoutNode {
        return state_serialize.deserializeLayoutNode(self, obj);
    }

    pub fn syncStateToSes(self: *State) void {
        return state_sync.syncStateToSes(self);
    }

    pub fn buildSessionSnapshot(self: *State) !core.session_model.SessionSnapshot {
        return state_sync.buildSessionSnapshot(self);
    }

    pub fn syncSessionTabAdded(self: *State, tab_uuid: [32]u8, name: []const u8, pane_uuid: [32]u8) void {
        return state_sync.syncSessionTabAdded(self, tab_uuid, name, pane_uuid);
    }

    pub fn syncSessionTabRemoved(self: *State, tab_uuid: [32]u8) void {
        return state_sync.syncSessionTabRemoved(self, tab_uuid);
    }

    pub fn syncSessionFloat(self: *State, pane: *Pane, active: bool) void {
        return state_sync.syncSessionFloat(self, pane, active);
    }

    pub fn syncSessionFloatRemoved(self: *State, pane_uuid: [32]u8) void {
        return state_sync.syncSessionFloatRemoved(self, pane_uuid);
    }

    pub fn syncActiveTabLayout(self: *State) void {
        return state_sync.syncActiveTabLayout(self);
    }

    pub fn getCurrentFocusedUuid(self: *State) ?[32]u8 {
        return state_sync.getCurrentFocusedUuid(self);
    }

    pub fn syncPaneAux(self: *State, pane: *Pane, created_from: ?[32]u8) void {
        return state_sync.syncPaneAux(self, pane, created_from);
    }

    pub fn unfocusAllPanes(self: *State) void {
        return state_sync.unfocusAllPanes(self);
    }

    pub fn syncPaneFocus(self: *State, pane: *Pane, focused_from: ?[32]u8) void {
        return state_sync.syncPaneFocus(self, pane, focused_from);
    }

    pub fn syncPaneUnfocus(self: *State, pane: *Pane) void {
        return state_sync.syncPaneUnfocus(self, pane);
    }

    pub fn refreshPaneCwd(self: *State, pane: *Pane) ?[]const u8 {
        return state_sync.refreshPaneCwd(self, pane);
    }

    pub fn getSpawnCwd(self: *State, pane: *Pane) ?[]const u8 {
        return state_sync.getSpawnCwd(self, pane);
    }

    pub fn getReliableCwd(self: *State, pane: *Pane) ?[]const u8 {
        return state_sync.getReliableCwd(self, pane);
    }

    pub fn syncFocusedPaneInfo(self: *State) void {
        return state_sync.syncFocusedPaneInfo(self);
    }

    pub fn resizeFloatingPanes(self: *State) void {
        return state_sync.resizeFloatingPanes(self);
    }

    pub fn applyTerminalResize(self: *State, cols: u16, rows: u16) void {
        if (cols == 0 or rows == 0) return;
        if (cols == self.term_width and rows == self.term_height) return;

        self.term_width = cols;
        self.term_height = rows;
        const status_h: u16 = if (self.config.tabs.status.enabled) 1 else 0;
        self.status_height = status_h;
        self.layout_width = cols;
        self.layout_height = rows - status_h;

        for (self.tabs.items) |*tab| {
            tab.layout.resize(self.layout_width, self.layout_height);
        }

        self.resizeFloatingPanes();
        self.renderer.resize(cols, rows) catch {};
        self.renderer.invalidate();
        self.needs_render = true;
        self.force_full_render = true;
    }

    pub fn setPaneShell(self: *State, uuid: [32]u8, cmd: ?[]const u8, cwd: ?[]const u8, status: ?i32, duration_ms: ?u64, jobs: ?u16) void {
        self.session_cache.setPaneShell(uuid, cmd, cwd, status, duration_ms, jobs);
    }

    pub fn setPaneShellRunning(self: *State, uuid: [32]u8, running: bool, started_at_ms: ?u64, cmd: ?[]const u8, cwd: ?[]const u8, jobs: ?u16) void {
        self.session_cache.setPaneShellRunning(uuid, running, started_at_ms, cmd, cwd, jobs);
    }

    pub fn clearPaneShellStartedAt(self: *State, uuid: [32]u8) void {
        self.session_cache.clearPaneShellStartedAt(uuid);
    }

    pub fn setPaneProc(self: *State, uuid: [32]u8, name: ?[]const u8, pid: ?i32) void {
        self.session_cache.setPaneProc(uuid, name, pid);
    }

    pub fn getPaneShell(self: *const State, uuid: [32]u8) ?PaneShellInfo {
        return self.session_cache.getPaneShell(uuid);
    }

    pub fn getPaneProc(self: *const State, uuid: [32]u8) ?PaneProcInfo {
        return self.session_cache.getPaneProc(uuid);
    }

    pub fn setPaneNameOwned(self: *State, uuid: [32]u8, name_owned: []u8) void {
        self.session_cache.setPaneNameOwned(uuid, name_owned);
    }

    pub fn paneName(self: *const State, uuid: [32]u8) ?[]const u8 {
        return self.session_cache.paneName(uuid);
    }

    pub fn hasPaneName(self: *const State, uuid: [32]u8) bool {
        return self.session_cache.hasPaneName(uuid);
    }

    pub fn removePaneProcMetadata(self: *State, uuid: [32]u8) void {
        self.session_cache.removePaneProc(uuid);
    }

    pub fn removePaneName(self: *State, uuid: [32]u8) void {
        self.session_cache.removePaneName(uuid);
    }
};
