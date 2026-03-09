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

const ses_client = @import("ses_client.zig");
const SesClient = ses_client.SesClient;
const OrphanedPaneInfo = ses_client.OrphanedPaneInfo;

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

pub const TabFocusKind = enum { split, float };

const max_pending_mux_vt_bytes: usize = 8 * 1024 * 1024;

pub const PaneShellInfo = struct {
    cmd: ?[]u8 = null,
    cwd: ?[]u8 = null,
    status: ?i32 = null,
    duration_ms: ?u64 = null,
    jobs: ?u16 = null,

    // Running command telemetry (best-effort, sourced from shell integration).
    running: bool = false,
    started_at_ms: ?u64 = null,

    pub fn deinit(self: *PaneShellInfo, allocator: std.mem.Allocator) void {
        if (self.cmd) |c| allocator.free(c);
        if (self.cwd) |c| allocator.free(c);
        self.* = .{};
    }
};

pub const PaneProcInfo = struct {
    name: ?[]u8 = null,
    pid: ?i32 = null,

    pub fn deinit(self: *PaneProcInfo, allocator: std.mem.Allocator) void {
        if (self.name) |n| allocator.free(n);
        self.* = .{};
    }
};

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
    active_layout_floats: []const core.LayoutFloatDef,
    tabs: std.ArrayList(Tab),
    active_tab: usize,
    /// Per-tab remembered floating focus (by pane UUID).
    /// This is used to restore float focus when switching tabs.
    tab_last_floating_uuid: std.ArrayList(?[32]u8),
    /// Remembers whether the last focus in a tab was a split or a float.
    tab_last_focus_kind: std.ArrayList(TabFocusKind),
    floats: std.ArrayList(*Pane),
    active_floating: ?usize,
    running: bool,
    detach_mode: bool,
    reattach_in_progress: std.atomic.Value(bool),
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
    adopt_orphans: [32]OrphanedPaneInfo = undefined,
    adopt_orphan_count: usize = 0,
    adopt_selected_uuid: ?[32]u8 = null,
    skip_dead_check: bool,
    pending_pop_response: bool,
    pending_pop_scope: pop.Scope,
    pending_pop_tab: usize,
    pending_pop_pane: ?*Pane,
    uuid: [32]u8,
    session_name: []const u8,
    session_name_owned: ?[]const u8,

    /// Tab counter for generating unique tab names (session-N format)
    tab_counter: usize = 0,

    /// Monotonically increasing version counter for state sync.
    /// SES uses this to reject stale/out-of-order updates.
    state_version: u32 = 0,

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

    /// Shell-provided metadata (last command, status, duration) keyed by pane UUID.
    pane_shell: std.AutoHashMap([32]u8, PaneShellInfo),

    /// Best-effort foreground process info keyed by pane UUID.
    ///
    /// For local PTY panes we can read this directly in mux.
    /// For pod panes we query it from ses (which can inspect /proc).
    pane_proc: std.AutoHashMap([32]u8, PaneProcInfo),

    /// Pane names (Pokemon names) keyed by pane UUID
    pane_names: std.AutoHashMap([32]u8, []u8),

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
            .active_layout_floats = layout_floats,
            .tabs = .empty,
            .active_tab = 0,
            .tab_last_floating_uuid = .empty,
            .tab_last_focus_kind = .empty,
            .floats = .empty,
            .active_floating = null,
            .running = true,
            .detach_mode = false,
            .reattach_in_progress = std.atomic.Value(bool).init(false),
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
            .ses_client = SesClient.init(allocator, uuid, session_name, true, debug, log_file),
            .notifications = NotificationManager.initWithConfig(allocator, pop_cfg.carrier.notification),
            .overlays = OverlayManager.initWithConfig(allocator, pop_cfg.widgets.keycast),
            .popups = pop.PopupManager.init(allocator),
            .pending_action = null,
            .exit_from_shell_death = false,
            .pending_exit_intent = false,
            .exit_intent_deadline_ms = 0,
            .needs_respawn = false,
            .skip_dead_check = false,
            .pending_pop_response = false,
            .pending_pop_scope = .mux,
            .pending_pop_tab = 0,
            .pending_pop_pane = null,
            .uuid = uuid,
            .session_name = session_name,
            .session_name_owned = null,

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

            .pane_shell = std.AutoHashMap([32]u8, PaneShellInfo).init(allocator),

            .pane_proc = std.AutoHashMap([32]u8, PaneProcInfo).init(allocator),

            .pane_names = std.AutoHashMap([32]u8, []u8).init(allocator),

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
        self.syncStateToSes();
    }

    pub fn deinit(self: *State) void {
        // If the terminal is gone (window closed, SSH dropped), auto-detach to
        // preserve sessions even when SIGTERM arrived instead of SIGHUP.
        // tcgetattr returns EIO on a dead PTY slave.
        if (!self.detach_mode) {
            _ = posix.tcgetattr(posix.STDIN_FILENO) catch {
                self.detach_mode = true;
            };
        }

        // When exiting normally (not detach), tell SES to kill regular panes but
        // preserve sticky panes/floats.
        // When detaching, panes stay alive for later reattach.
        if (!self.detach_mode and self.ses_client.isConnected()) {
            self.ses_client.shutdown(true) catch |err| {
                core.logging.logError("mux", "failed to send shutdown to SES", err);
            };
        }

        // Free shell metadata.
        {
            var it = self.pane_shell.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.pane_shell.deinit();
        }

        // Free proc metadata.
        {
            var it = self.pane_proc.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.pane_proc.deinit();
        }

        // Free pane names.
        {
            var it = self.pane_names.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.value_ptr.*);
            }
            self.pane_names.deinit();
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
        self.tab_last_floating_uuid.deinit(self.allocator);
        self.tab_last_focus_kind.deinit(self.allocator);
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
        if (self.session_name_owned) |owned| {
            self.allocator.free(owned);
        }
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

        switch (pane.backend) {
            .local => pane.write(data) catch {},
            .pod => |pod| {
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
            },
        }
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
        var entry = self.pane_shell.getPtr(uuid);
        if (entry == null) {
            self.pane_shell.put(uuid, .{}) catch return;
            entry = self.pane_shell.getPtr(uuid);
        }
        if (entry) |info| {
            if (cmd) |c| {
                if (info.cmd) |old| self.allocator.free(old);
                info.cmd = self.allocator.dupe(u8, c) catch info.cmd;
            }
            if (cwd) |c| {
                if (info.cwd) |old| self.allocator.free(old);
                info.cwd = self.allocator.dupe(u8, c) catch info.cwd;
            }
            if (status) |s| info.status = s;
            if (duration_ms) |d| info.duration_ms = d;
            if (jobs) |j| info.jobs = j;
        }
    }

    pub fn setPaneShellRunning(self: *State, uuid: [32]u8, running: bool, started_at_ms: ?u64, cmd: ?[]const u8, cwd: ?[]const u8, jobs: ?u16) void {
        var entry = self.pane_shell.getPtr(uuid);
        if (entry == null) {
            self.pane_shell.put(uuid, .{}) catch return;
            entry = self.pane_shell.getPtr(uuid);
        }
        if (entry) |info| {
            info.running = running;
            if (started_at_ms) |t| info.started_at_ms = t;
            if (cmd) |c| {
                if (info.cmd) |old| self.allocator.free(old);
                info.cmd = self.allocator.dupe(u8, c) catch info.cmd;
            }
            if (cwd) |c| {
                if (info.cwd) |old| self.allocator.free(old);
                info.cwd = self.allocator.dupe(u8, c) catch info.cwd;
            }
            if (jobs) |j| info.jobs = j;
        }
    }

    pub fn setPaneProc(self: *State, uuid: [32]u8, name: ?[]const u8, pid: ?i32) void {
        var entry = self.pane_proc.getPtr(uuid);
        if (entry == null) {
            self.pane_proc.put(uuid, .{}) catch return;
            entry = self.pane_proc.getPtr(uuid);
        }
        if (entry) |info| {
            if (name) |n| {
                if (info.name) |old| self.allocator.free(old);
                info.name = self.allocator.dupe(u8, n) catch info.name;
            }
            if (pid) |p| info.pid = p;
        }
    }

    /// Apply a saved layout template to the active tab.
    /// The tree_json describes the split structure with optional CWDs per leaf.
    pub fn applyLayout(self: *State, source_uuid: [32]u8, tree_json: []const u8) void {
        const mux = @import("main.zig");
        mux.debugLog("applyLayout: uuid={s} json_len={d}", .{ source_uuid[0..8], tree_json.len });

        // Parse the template JSON.
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, tree_json, .{}) catch {
            mux.debugLog("applyLayout: json parse failed", .{});
            return;
        };
        defer parsed.deinit();

        const root_obj = switch (parsed.value) {
            .object => |o| o,
            else => return,
        };

        // Count leaf nodes in the template.
        const leaf_count = countLeaves(parsed.value);
        if (leaf_count == 0) return;

        // Collect CWDs from template leaves (in traversal order).
        var cwds: std.ArrayList(?[]const u8) = .empty;
        defer cwds.deinit(self.allocator);
        collectCwds(parsed.value, &cwds, self.allocator);

        // Find active tab.
        if (self.active_tab >= self.tabs.items.len) return;
        const tab = &self.tabs.items[self.active_tab];

        // Find the source pane to keep alive.
        var source_pane: ?*Pane = null;
        var source_id: ?u16 = null;
        {
            var it = tab.layout.splits.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, &entry.value_ptr.*.uuid, &source_uuid)) {
                    source_pane = entry.value_ptr.*;
                    source_id = entry.key_ptr.*;
                    break;
                }
            }
        }
        if (source_pane == null) {
            mux.debugLog("applyLayout: source pane not found", .{});
            return;
        }

        // Close all OTHER panes in this tab.
        var to_close: std.ArrayList(u16) = .empty;
        defer to_close.deinit(self.allocator);
        {
            var it = tab.layout.splits.keyIterator();
            while (it.next()) |id_ptr| {
                if (id_ptr.* != source_id.?) {
                    to_close.append(self.allocator, id_ptr.*) catch continue;
                }
            }
        }
        for (to_close.items) |id| {
            if (tab.layout.splits.fetchRemove(id)) |kv| {
                if (tab.layout.ses_client) |ses| {
                    ses.killPane(kv.value.uuid) catch {};
                }
                kv.value.deinit();
                self.allocator.destroy(kv.value);
            }
        }

        // Free old tree nodes.
        if (tab.layout.root) |root| {
            tab.layout.freeNode(root);
            tab.layout.root = null;
        }

        // Create N-1 new panes via ses.
        var new_pane_ids: std.ArrayList(u16) = .empty;
        defer new_pane_ids.deinit(self.allocator);

        // First pane ID slot is for the source pane; reassign it.
        const first_id: u16 = 0;
        // Move source pane to id 0.
        _ = tab.layout.splits.fetchRemove(source_id.?);
        source_pane.?.id = first_id;
        tab.layout.splits.put(first_id, source_pane.?) catch return;
        new_pane_ids.append(self.allocator, first_id) catch return;

        var next_id: u16 = 1;
        var create_idx: usize = 1; // start from second leaf
        while (create_idx < leaf_count) : (create_idx += 1) {
            const cwd: ?[]const u8 = if (create_idx < cwds.items.len) cwds.items[create_idx] else null;

            const pane = self.allocator.create(Pane) catch break;
            if (tab.layout.ses_client) |ses| {
                if (ses.isConnected()) {
                    if (ses.createPane(null, cwd, null, null, null, null, null)) |result| {
                        if (ses.getVtFd()) |vt_fd| {
                            pane.initWithPod(self.allocator, next_id, 0, 0, tab.layout.width, tab.layout.height, result.pane_id, vt_fd, result.uuid) catch {
                                self.allocator.destroy(pane);
                                break;
                            };
                        } else {
                            pane.init(self.allocator, next_id, 0, 0, tab.layout.width, tab.layout.height) catch {
                                self.allocator.destroy(pane);
                                break;
                            };
                        }
                    } else |_| {
                        pane.init(self.allocator, next_id, 0, 0, tab.layout.width, tab.layout.height) catch {
                            self.allocator.destroy(pane);
                            break;
                        };
                    }
                } else {
                    pane.init(self.allocator, next_id, 0, 0, tab.layout.width, tab.layout.height) catch {
                        self.allocator.destroy(pane);
                        break;
                    };
                }
            } else {
                pane.init(self.allocator, next_id, 0, 0, tab.layout.width, tab.layout.height) catch {
                    self.allocator.destroy(pane);
                    break;
                };
            }
            tab.layout.configurePaneNotifications(pane);
            tab.layout.splits.put(next_id, pane) catch {
                pane.deinit();
                self.allocator.destroy(pane);
                break;
            };
            new_pane_ids.append(self.allocator, next_id) catch break;
            next_id += 1;
        }

        // Build layout tree from template, assigning pane IDs sequentially.
        var pane_idx: usize = 0;
        const new_root = buildTreeFromTemplate(self.allocator, root_obj, new_pane_ids.items, &pane_idx) catch {
            mux.debugLog("applyLayout: tree build failed", .{});
            return;
        };

        tab.layout.root = new_root;
        tab.layout.next_split_id = next_id;
        tab.layout.focused_split_id = first_id;
        source_pane.?.focused = true;

        // Recalculate and sync.
        tab.layout.recalculateLayout();
        self.syncStateToSes();
        self.needs_render = true;
    }

    fn countLeaves(value: std.json.Value) usize {
        const obj = switch (value) {
            .object => |o| o,
            else => return 0,
        };
        const type_str = (obj.get("type") orelse return 0).string;
        if (std.mem.eql(u8, type_str, "pane")) return 1;
        if (std.mem.eql(u8, type_str, "split")) {
            const first = obj.get("first") orelse return 0;
            const second = obj.get("second") orelse return 0;
            return countLeaves(first) + countLeaves(second);
        }
        return 0;
    }

    fn collectCwds(value: std.json.Value, list: *std.ArrayList(?[]const u8), allocator: std.mem.Allocator) void {
        const obj = switch (value) {
            .object => |o| o,
            else => return,
        };
        const type_str = (obj.get("type") orelse return).string;
        if (std.mem.eql(u8, type_str, "pane")) {
            if (obj.get("cwd")) |cwd_val| {
                switch (cwd_val) {
                    .string => |s| {
                        list.append(allocator, s) catch {};
                        return;
                    },
                    else => {},
                }
            }
            list.append(allocator, null) catch {};
        } else if (std.mem.eql(u8, type_str, "split")) {
            if (obj.get("first")) |first| collectCwds(first, list, allocator);
            if (obj.get("second")) |second| collectCwds(second, list, allocator);
        }
    }

    fn buildTreeFromTemplate(allocator: std.mem.Allocator, obj: std.json.ObjectMap, pane_ids: []const u16, idx: *usize) !*layout_mod.LayoutNode {
        const node = try allocator.create(layout_mod.LayoutNode);
        errdefer allocator.destroy(node);

        const type_str = (obj.get("type") orelse return error.InvalidNode).string;

        if (std.mem.eql(u8, type_str, "pane")) {
            if (idx.* < pane_ids.len) {
                node.* = .{ .pane = pane_ids[idx.*] };
                idx.* += 1;
            } else {
                return error.InvalidNode;
            }
        } else if (std.mem.eql(u8, type_str, "split")) {
            const dir_str = (obj.get("dir") orelse return error.InvalidNode).string;
            const dir: layout_mod.SplitDir = if (std.mem.eql(u8, dir_str, "horizontal")) .horizontal else .vertical;
            const ratio_val = obj.get("ratio") orelse return error.InvalidNode;
            const ratio: f32 = switch (ratio_val) {
                .float => @floatCast(ratio_val.float),
                .integer => @floatFromInt(ratio_val.integer),
                else => return error.InvalidNode,
            };
            const first_obj = (obj.get("first") orelse return error.InvalidNode).object;
            const second_obj = (obj.get("second") orelse return error.InvalidNode).object;

            const first = try buildTreeFromTemplate(allocator, first_obj, pane_ids, idx);
            errdefer allocator.destroy(first);
            const second = try buildTreeFromTemplate(allocator, second_obj, pane_ids, idx);

            node.* = .{ .split = .{
                .dir = dir,
                .ratio = ratio,
                .first = first,
                .second = second,
            } };
        } else {
            return error.InvalidNode;
        }

        return node;
    }

    pub fn getPaneShell(self: *const State, uuid: [32]u8) ?PaneShellInfo {
        if (self.pane_shell.get(uuid)) |v| return v;
        return null;
    }

    pub fn getPaneProc(self: *const State, uuid: [32]u8) ?PaneProcInfo {
        if (self.pane_proc.get(uuid)) |v| return v;
        return null;
    }
};
