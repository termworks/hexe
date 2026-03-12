const std = @import("std");
const posix = std.posix;

const core = @import("core");
const wire = core.wire;
const pop = @import("pop");

const state_types = @import("state_types.zig");
pub const PendingAction = state_types.PendingAction;
pub const TabView = state_types.TabView;
pub const TerminalViewState = state_types.TerminalViewState;
pub const PendingFloatRequest = state_types.PendingFloatRequest;
pub const CursorSnapshot = state_types.CursorSnapshot;
pub const FloatUiState = state_types.FloatUiState;

const layout_mod = @import("layout.zig");
const Layout = layout_mod.Layout;

const Renderer = @import("render_core.zig").Renderer;

const FrontendRuntime = core.FrontendRuntime;
const PaneShellInfo = core.SessionProjectionPaneShellInfo;
const PaneProcInfo = core.SessionProjectionPaneProcInfo;

const NotificationManager = pop.notification.NotificationManager;

const OverlayManager = pop.overlay.OverlayManager;

const Pane = @import("pane.zig").Pane;
const VtWriteQueue = @import("vt_write_queue.zig").Queue;

const BindKey = core.Config.BindKey;
const BindAction = core.Config.BindAction;
/// Simple focus context for timer storage (float vs split).
pub const FocusContext = enum { split, float };

const state_tabs = @import("state_tabs.zig");
const state_sync = @import("state_sync.zig");
const state_session = @import("state_session.zig");
const mouse_selection = @import("mouse_selection.zig");

const max_pending_mux_vt_bytes: usize = 8 * 1024 * 1024;

pub const PaneBounds = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};

pub const PaneFloatUiConfig = struct {
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
    pwd_dir: ?[]const u8 = null,
    navigatable: bool = false,
    retained_after_exit: bool = false,
    capture_output: bool = false,
    dim_background: bool = false,
    exit_key: ?[]const u8 = null,
    closed_by_exit_key: bool = false,
    float_style: ?*const core.FloatStyle = null,
    float_title: ?[]const u8 = null,
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
        first_anchor_uuid: [32]u8,
        second_anchor_uuid: [32]u8,
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
    runtime: *FrontendRuntime,
    active_layout_floats: []const core.LayoutFloatDef,
    view: TerminalViewState,
    float_ui: std.AutoHashMap([32]u8, FloatUiState),
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

    pub fn init(
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
        debug: bool,
        log_file: ?[]const u8,
        connect_options: core.FrontendConnectOptions,
    ) !State {
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
        const runtime = try FrontendRuntime.createTerminal(allocator, uuid, session_name, debug, log_file, connect_options);
        errdefer runtime.destroy();

        return .{
            .allocator = allocator,
            .config = cfg,
            .pop_config = pop_cfg,
            .ses_config = ses_cfg,
            .runtime = runtime,
            .active_layout_floats = layout_floats,
            .view = TerminalViewState.init(),
            .float_ui = std.AutoHashMap([32]u8, FloatUiState).init(allocator),
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
        const title = self.paneFloatTitle(pane) orelse return;
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

    fn removeQueuedPaneReplyTargets(
        uuids: *std.ArrayList([32]u8),
        enqueued_ms: *std.ArrayList(i64),
        pane_uuid: [32]u8,
    ) void {
        var i: usize = 0;
        while (i < uuids.items.len) {
            if (std.mem.eql(u8, &uuids.items[i], &pane_uuid)) {
                _ = uuids.orderedRemove(i);
                if (i < enqueued_ms.items.len) {
                    _ = enqueued_ms.orderedRemove(i);
                }
                continue;
            }
            i += 1;
        }
    }

    pub fn clearTransientPaneState(self: *State, pane: *const Pane) void {
        const pane_uuid = pane.uuid;

        if (self.pending_pop_pane) |pending_pane| {
            if (@intFromPtr(pending_pane) == @intFromPtr(pane)) {
                self.pending_pop_pane = null;
                if (self.pending_pop_response and self.pending_pop_scope == .pane) {
                    self.pending_pop_response = false;
                    self.pending_pop_scope = .mux;
                    self.pending_pop_tab = 0;
                    if (self.runtime.getCtlFd()) |fd| {
                        const resp = wire.PopResponse{
                            .response_type = 0,
                            .selected_idx = 0,
                        };
                        wire.writeControl(fd, .pop_response, std.mem.asBytes(&resp)) catch {};
                    }
                }
            }
        }

        if (self.mouse_selection.pane_uuid) |uuid| {
            if (std.mem.eql(u8, &uuid, &pane_uuid)) {
                self.mouse_selection.clear();
            }
        }

        if (self.bracketed_paste_target_uuid) |uuid| {
            if (std.mem.eql(u8, &uuid, &pane_uuid)) {
                self.bracketed_paste_target_uuid = null;
                self.in_bracketed_paste = false;
                self.bracketed_paste_buf.clearRetainingCapacity();
            }
        }

        if (self.osc_reply_target_uuid) |uuid| {
            if (std.mem.eql(u8, &uuid, &pane_uuid)) {
                self.osc_reply_target_uuid = null;
                self.osc_reply_in_progress = false;
                self.osc_reply_prev_esc = false;
                self.osc_reply_buf.clearRetainingCapacity();
            }
        }
        removeQueuedPaneReplyTargets(&self.osc_reply_targets, &self.osc_reply_target_enqueued_ms, pane_uuid);

        if (self.csi_reply_target_uuid) |uuid| {
            if (std.mem.eql(u8, &uuid, &pane_uuid)) {
                self.csi_reply_target_uuid = null;
                self.csi_reply_in_progress = false;
                self.csi_reply_buf.clearRetainingCapacity();
            }
        }
        removeQueuedPaneReplyTargets(&self.csi_reply_targets, &self.csi_reply_target_enqueued_ms, pane_uuid);

        switch (self.mouse_drag) {
            .float_move => |drag| {
                if (std.mem.eql(u8, &drag.uuid, &pane_uuid)) {
                    self.mouse_drag = .none;
                }
            },
            .float_resize => |drag| {
                if (std.mem.eql(u8, &drag.uuid, &pane_uuid)) {
                    self.mouse_drag = .none;
                }
            },
            else => {},
        }

        if (self.float_rename_uuid) |uuid| {
            if (std.mem.eql(u8, &uuid, &pane_uuid)) {
                self.float_rename_uuid = null;
                self.float_rename_buf.clearRetainingCapacity();
            }
        }

        if (self.mouse_title_last_uuid) |uuid| {
            if (std.mem.eql(u8, &uuid, &pane_uuid)) {
                self.mouse_title_last_uuid = null;
                self.mouse_title_click_count = 0;
            }
        }

        if (self.mouse_click_last_pane_uuid) |uuid| {
            if (std.mem.eql(u8, &uuid, &pane_uuid)) {
                self.mouse_click_last_pane_uuid = null;
                self.mouse_click_count = 0;
            }
        }
    }

    pub fn commitFloatRename(self: *State) void {
        const uuid = self.float_rename_uuid orelse return;
        const pane = self.findPaneByUuid(uuid) orelse {
            self.clearFloatRename();
            return;
        };

        const new_title = std.mem.trim(u8, self.float_rename_buf.items, " \t\r\n");
        _ = self.setPaneFloatTitle(pane.uuid, if (new_title.len > 0) new_title else null);

        // Keep the pod's pane name separate from the float title.

        self.clearFloatRename();
        self.renderer.invalidate();
        self.force_full_render = true;
        self.syncSessionFloat(pane, self.activeFloatingIndex() != null);
    }

    pub fn deinit(self: *State) void {
        self.runtime.prepareFrontendExit(posix.STDIN_FILENO, true) catch |err| {
            core.logging.logError("terminal", "failed to finalize frontend exit with SES", err);
        };

        self.key_timers.deinit(self.allocator);

        self.view.deinit(self.allocator);
        {
            var it = self.float_ui.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.float_ui.deinit();
        }
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
        self.runtime.destroy();
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
        _ = self.runtime.closeVtFdIf(fd);
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
        const fd = self.runtime.getVtFd() orelse return;
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

    pub fn isDetachMode(self: *const State) bool {
        return self.runtime.isDetachMode();
    }

    pub fn setDetachMode(self: *State, enabled: bool) void {
        self.runtime.setDetachMode(enabled);
    }

    pub fn nextStateVersion(self: *State) u32 {
        return self.runtime.nextStateVersion();
    }

    pub fn activeTabIndex(self: *const State) usize {
        return self.runtime.activeTab(self.view.tab_views.items.len);
    }

    pub fn setActiveTabIndex(self: *State, idx: usize) void {
        const clamped = if (self.view.tab_views.items.len == 0) 0 else @min(idx, self.view.tab_views.items.len - 1);
        self.runtime.setActiveTab(clamped);
    }

    pub fn activeFloatingIndex(self: *State) ?usize {
        if (self.runtime.activeFloatUuid()) |uuid| {
            for (self.view.float_views.items, 0..) |pane, idx| {
                if (std.mem.eql(u8, &pane.uuid, &uuid)) return idx;
            }
        }

        if (self.runtime.focusedPaneUuid()) |focused_uuid| {
            for (self.view.float_views.items, 0..) |pane, idx| {
                if (std.mem.eql(u8, &pane.uuid, &focused_uuid)) {
                    self.runtime.setActiveFloatUuid(focused_uuid);
                    return idx;
                }
            }
        }

        if (self.runtime.activeFloatUuid() != null) {
            self.runtime.setActiveFloatUuid(null);
        }
        return null;
    }

    pub fn setActiveFloatingIndex(self: *State, idx: ?usize) void {
        if (idx) |value| {
            if (value < self.view.float_views.items.len) {
                self.runtime.setActiveFloatUuid(self.view.float_views.items[value].uuid);
                return;
            }
        }
        self.runtime.setActiveFloatUuid(null);
    }

    pub fn setActiveFloatingUuid(self: *State, uuid: ?[32]u8) void {
        self.runtime.setActiveFloatUuid(uuid);
    }

    pub fn rememberFloatingFocus(self: *State, pane: *Pane) void {
        self.runtime.rememberFloatingFocus(self.activeTabIndex(), pane.uuid);
    }

    pub fn rememberSplitFocus(self: *State) void {
        self.runtime.rememberSplitFocus(self.activeTabIndex());
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

    pub fn applySessionSnapshot(self: *State) bool {
        return state_tabs.applySessionSnapshot(self);
    }

    pub fn attachOrphanedPane(self: *State, uuid_prefix: []const u8) bool {
        return state_tabs.attachOrphanedPane(self, uuid_prefix);
    }

    pub fn applySessionConfig(self: *State, config: core.SessionConfig, tab_filter: ?[]const u8) !void {
        return state_session.applySessionConfig(self, config, tab_filter);
    }

    pub fn applyLayoutDef(self: *State, layout: *const core.LayoutDef) !void {
        return state_session.applyLayoutDef(self, layout);
    }

    pub fn replaceWithSessionConfig(self: *State, config: core.SessionConfig, tab_filter: ?[]const u8) !void {
        return state_session.replaceWithSessionConfig(self, config, tab_filter);
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

    pub fn syncSessionSplitPane(
        self: *State,
        source_pane_uuid: [32]u8,
        new_pane_uuid: [32]u8,
        dir: layout_mod.SplitDir,
        focused_pane_uuid: ?[32]u8,
    ) void {
        return state_sync.syncSessionSplitPane(self, source_pane_uuid, new_pane_uuid, dir, focused_pane_uuid);
    }

    pub fn syncSessionCloseSplitPane(
        self: *State,
        pane_uuid: [32]u8,
        focused_pane_uuid: ?[32]u8,
    ) void {
        return state_sync.syncSessionCloseSplitPane(self, pane_uuid, focused_pane_uuid);
    }

    pub fn syncSessionReplaceSplitPane(
        self: *State,
        old_pane_uuid: [32]u8,
        new_pane_uuid: [32]u8,
        focused_pane_uuid: ?[32]u8,
    ) void {
        return state_sync.syncSessionReplaceSplitPane(self, old_pane_uuid, new_pane_uuid, focused_pane_uuid);
    }

    pub fn syncSessionSplitRatio(
        self: *State,
        first_anchor_uuid: [32]u8,
        second_anchor_uuid: [32]u8,
        ratio: f32,
    ) void {
        return state_sync.syncSessionSplitRatio(self, first_anchor_uuid, second_anchor_uuid, ratio);
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

        for (self.view.tab_views.items) |*tab| {
            tab.layout.resize(self.layout_width, self.layout_height);
        }

        self.resizeFloatingPanes();
        self.renderer.resize(cols, rows) catch {};
        self.renderer.invalidate();
        self.needs_render = true;
        self.force_full_render = true;
    }

    pub fn setPaneShell(self: *State, uuid: [32]u8, cmd: ?[]const u8, cwd: ?[]const u8, status: ?i32, duration_ms: ?u64, jobs: ?u16) void {
        self.runtime.setPaneShell(uuid, cmd, cwd, status, duration_ms, jobs);
    }

    pub fn setPaneShellRunning(self: *State, uuid: [32]u8, running: bool, started_at_ms: ?u64, cmd: ?[]const u8, cwd: ?[]const u8, jobs: ?u16) void {
        self.runtime.setPaneShellRunning(uuid, running, started_at_ms, cmd, cwd, jobs);
    }

    pub fn clearPaneShellStartedAt(self: *State, uuid: [32]u8) void {
        self.runtime.clearPaneShellStartedAt(uuid);
    }

    pub fn setPaneProc(self: *State, uuid: [32]u8, name: ?[]const u8, pid: ?i32) void {
        self.runtime.setPaneProc(uuid, name, pid);
    }

    pub fn getPaneShell(self: *const State, uuid: [32]u8) ?PaneShellInfo {
        return self.runtime.getPaneShell(uuid);
    }

    pub fn getPaneProc(self: *const State, uuid: [32]u8) ?PaneProcInfo {
        return self.runtime.getPaneProc(uuid);
    }

    pub fn paneExitCode(self: *const State, uuid: [32]u8) u8 {
        const shell_info = self.getPaneShell(uuid) orelse return 0;
        const status = shell_info.status orelse return 0;
        if (status < 0) return 0;
        return @intCast(@min(status, std.math.maxInt(u8)));
    }

    pub fn paneRealCwd(self: *const State, pane: *Pane) ?[]const u8 {
        if (pane.getPwd()) |pwd| {
            return pwd;
        }
        if (self.getPaneShell(pane.uuid)) |shell_info| {
            if (shell_info.cwd) |cwd| {
                return cwd;
            }
        }
        return null;
    }

    pub fn paneSessionMeta(self: *const State, pane: *const Pane) core.session_model.SessionPane {
        if (self.runtime.paneMeta(pane.uuid)) |meta| return meta;
        return .{
            .uuid = pane.uuid,
            .kind = .split,
        };
    }

    pub fn paneFloatState(self: *const State, pane: *const Pane) ?core.session_model.SessionFloat {
        return self.runtime.floatState(pane.uuid);
    }

    pub fn paneIsFloating(self: *const State, pane: *const Pane) bool {
        return self.runtime.floatState(pane.uuid) != null;
    }

    pub fn paneIsFocused(self: *const State, pane: *const Pane) bool {
        if (self.runtime.focusedPaneUuid()) |uuid| {
            return std.mem.eql(u8, &uuid, &pane.uuid);
        }
        return pane.focused;
    }

    pub fn paneParentTab(self: *const State, pane: *const Pane) ?usize {
        if (self.paneFloatState(pane)) |float_state| return float_state.parent_tab;
        return null;
    }

    pub fn paneVisibleOnTab(self: *const State, pane: *const Pane, tab: usize) bool {
        if (self.paneFloatState(pane)) |float_state| {
            if (float_state.parent_tab != null) {
                return float_state.visible;
            }
            if (tab >= 64) return false;
            return (float_state.tab_visible & (@as(u64, 1) << @intCast(tab))) != 0;
        }
        return true;
    }

    pub fn paneFloatKey(self: *const State, pane: *const Pane) u8 {
        if (self.paneFloatState(pane)) |float_state| return float_state.float_key;
        return 0;
    }

    pub fn paneSticky(self: *const State, pane: *const Pane) bool {
        if (self.paneFloatState(pane)) |float_state| return float_state.sticky;
        return false;
    }

    pub fn paneIsPwd(self: *const State, pane: *const Pane) bool {
        if (self.paneFloatState(pane)) |float_state| return float_state.is_pwd;
        return false;
    }

    pub fn floatUi(self: *State, pane: *const Pane) ?*FloatUiState {
        return self.float_ui.getPtr(pane.uuid);
    }

    pub fn floatUiConst(self: *const State, pane: *const Pane) ?*const FloatUiState {
        return self.float_ui.getPtr(pane.uuid);
    }

    pub fn ensureFloatUi(self: *State, pane_uuid: [32]u8) ?*FloatUiState {
        const entry = self.float_ui.getOrPut(pane_uuid) catch return null;
        if (!entry.found_existing) {
            entry.value_ptr.* = .{};
        }
        return entry.value_ptr;
    }

    pub fn clearFloatUi(self: *State, pane_uuid: [32]u8) void {
        if (self.float_ui.fetchRemove(pane_uuid)) |entry| {
            var ui = entry.value;
            ui.deinit(self.allocator);
        }
        if (self.float_rename_uuid) |uuid| {
            if (std.mem.eql(u8, &uuid, &pane_uuid)) {
                self.float_rename_uuid = null;
                self.float_rename_buf.clearRetainingCapacity();
            }
        }
    }

    pub fn setPaneFloatUi(self: *State, pane_uuid: [32]u8, cfg: PaneFloatUiConfig) bool {
        const ui = self.ensureFloatUi(pane_uuid) orelse return false;
        ui.deinit(self.allocator);
        ui.* = .{
            .border_x = cfg.border_x,
            .border_y = cfg.border_y,
            .border_w = cfg.border_w,
            .border_h = cfg.border_h,
            .border_color = cfg.border_color,
            .width_pct = cfg.width_pct,
            .height_pct = cfg.height_pct,
            .pos_x_pct = cfg.pos_x_pct,
            .pos_y_pct = cfg.pos_y_pct,
            .pad_x = cfg.pad_x,
            .pad_y = cfg.pad_y,
            .navigatable = cfg.navigatable,
            .retained_after_exit = cfg.retained_after_exit,
            .capture_output = cfg.capture_output,
            .dim_background = cfg.dim_background,
            .closed_by_exit_key = cfg.closed_by_exit_key,
            .float_style = cfg.float_style,
        };
        if (cfg.pwd_dir) |dir| {
            ui.pwd_dir = self.allocator.dupe(u8, dir) catch null;
        }
        if (cfg.exit_key) |key| {
            ui.exit_key = self.allocator.dupe(u8, key) catch null;
        }
        if (cfg.float_title) |title| {
            ui.float_title = self.allocator.dupe(u8, title) catch null;
        }
        return true;
    }

    pub fn setPaneBorderFrame(
        self: *State,
        pane_uuid: [32]u8,
        border_x: u16,
        border_y: u16,
        border_w: u16,
        border_h: u16,
        border_color: core.BorderColor,
    ) void {
        if (self.ensureFloatUi(pane_uuid)) |ui| {
            ui.border_x = border_x;
            ui.border_y = border_y;
            ui.border_w = border_w;
            ui.border_h = border_h;
            ui.border_color = border_color;
        }
    }

    pub fn setPaneFloatGeometryUi(
        self: *State,
        pane_uuid: [32]u8,
        width_pct: u8,
        height_pct: u8,
        pos_x_pct: u8,
        pos_y_pct: u8,
        pad_x: u8,
        pad_y: u8,
    ) void {
        if (self.ensureFloatUi(pane_uuid)) |ui| {
            ui.width_pct = width_pct;
            ui.height_pct = height_pct;
            ui.pos_x_pct = pos_x_pct;
            ui.pos_y_pct = pos_y_pct;
            ui.pad_x = pad_x;
            ui.pad_y = pad_y;
        }
    }

    pub fn swapPaneFloatUi(self: *State, a_uuid: [32]u8, b_uuid: [32]u8) void {
        const a = self.float_ui.getPtr(a_uuid) orelse return;
        const b = self.float_ui.getPtr(b_uuid) orelse return;

        std.mem.swap(u16, &a.border_x, &b.border_x);
        std.mem.swap(u16, &a.border_y, &b.border_y);
        std.mem.swap(u16, &a.border_w, &b.border_w);
        std.mem.swap(u16, &a.border_h, &b.border_h);
        std.mem.swap(u8, &a.width_pct, &b.width_pct);
        std.mem.swap(u8, &a.height_pct, &b.height_pct);
        std.mem.swap(u8, &a.pos_x_pct, &b.pos_x_pct);
        std.mem.swap(u8, &a.pos_y_pct, &b.pos_y_pct);
        std.mem.swap(u8, &a.pad_x, &b.pad_x);
        std.mem.swap(u8, &a.pad_y, &b.pad_y);
    }

    pub fn paneBorderX(self: *const State, pane: *const Pane) u16 {
        if (self.floatUiConst(pane)) |ui| return ui.border_x;
        return 0;
    }

    pub fn paneBorderY(self: *const State, pane: *const Pane) u16 {
        if (self.floatUiConst(pane)) |ui| return ui.border_y;
        return 0;
    }

    pub fn paneBorderW(self: *const State, pane: *const Pane) u16 {
        if (self.floatUiConst(pane)) |ui| return ui.border_w;
        return 0;
    }

    pub fn paneBorderH(self: *const State, pane: *const Pane) u16 {
        if (self.floatUiConst(pane)) |ui| return ui.border_h;
        return 0;
    }

    pub fn paneBorderColor(self: *const State, pane: *const Pane) core.BorderColor {
        if (self.floatUiConst(pane)) |ui| return ui.border_color;
        return .{};
    }

    pub fn paneFloatStyle(self: *const State, pane: *const Pane) ?*const core.FloatStyle {
        if (self.floatUiConst(pane)) |ui| return ui.float_style;
        return null;
    }

    pub fn paneFloatHasShadow(self: *const State, pane: *const Pane) bool {
        if (self.paneFloatStyle(pane)) |style| {
            return style.shadow_color != null;
        }
        return false;
    }

    pub fn paneFloatTitle(self: *const State, pane: *const Pane) ?[]const u8 {
        if (self.floatUiConst(pane)) |ui| return ui.float_title;
        return null;
    }

    pub fn setPaneFloatTitle(self: *State, pane_uuid: [32]u8, title: ?[]const u8) bool {
        const ui = self.ensureFloatUi(pane_uuid) orelse return false;
        if (ui.float_title) |old| {
            self.allocator.free(old);
            ui.float_title = null;
        }
        if (title) |value| {
            ui.float_title = self.allocator.dupe(u8, value) catch null;
        }
        return true;
    }

    pub fn panePwdDir(self: *const State, pane: *const Pane) ?[]const u8 {
        if (self.floatUiConst(pane)) |ui| return ui.pwd_dir;
        return null;
    }

    pub fn paneNavigatable(self: *const State, pane: *const Pane) bool {
        if (self.floatUiConst(pane)) |ui| return ui.navigatable;
        return false;
    }

    pub fn paneRetainedAfterExit(self: *const State, pane: *const Pane) bool {
        if (self.floatUiConst(pane)) |ui| return ui.retained_after_exit;
        return false;
    }

    pub fn setPaneRetainedAfterExit(self: *State, pane_uuid: [32]u8, retained: bool) void {
        if (self.ensureFloatUi(pane_uuid)) |ui| {
            ui.retained_after_exit = retained;
        }
    }

    pub fn paneCaptureOutput(self: *const State, pane: *const Pane) bool {
        if (self.floatUiConst(pane)) |ui| return ui.capture_output;
        return false;
    }

    pub fn setPaneCaptureOutput(self: *State, pane_uuid: [32]u8, capture_output: bool) void {
        if (self.ensureFloatUi(pane_uuid)) |ui| {
            ui.capture_output = capture_output;
        }
    }

    pub fn paneDimBackground(self: *const State, pane: *const Pane) bool {
        if (self.floatUiConst(pane)) |ui| return ui.dim_background;
        return false;
    }

    pub fn paneExitKey(self: *const State, pane: *const Pane) ?[]const u8 {
        if (self.floatUiConst(pane)) |ui| return ui.exit_key;
        return null;
    }

    pub fn paneClosedByExitKey(self: *const State, pane_uuid: [32]u8) bool {
        if (self.float_ui.get(pane_uuid)) |ui| return ui.closed_by_exit_key;
        return false;
    }

    pub fn setPaneClosedByExitKey(self: *State, pane_uuid: [32]u8, closed: bool) void {
        if (self.ensureFloatUi(pane_uuid)) |ui| {
            ui.closed_by_exit_key = closed;
        }
    }

    pub fn paneFloatWidthPct(self: *const State, pane: *const Pane) u8 {
        if (self.floatUiConst(pane)) |ui| return ui.width_pct;
        return 60;
    }

    pub fn paneFloatHeightPct(self: *const State, pane: *const Pane) u8 {
        if (self.floatUiConst(pane)) |ui| return ui.height_pct;
        return 60;
    }

    pub fn paneFloatPosXPct(self: *const State, pane: *const Pane) u8 {
        if (self.floatUiConst(pane)) |ui| return ui.pos_x_pct;
        return 50;
    }

    pub fn paneFloatPosYPct(self: *const State, pane: *const Pane) u8 {
        if (self.floatUiConst(pane)) |ui| return ui.pos_y_pct;
        return 50;
    }

    pub fn paneFloatPadX(self: *const State, pane: *const Pane) u8 {
        if (self.floatUiConst(pane)) |ui| return ui.pad_x;
        return 1;
    }

    pub fn paneFloatPadY(self: *const State, pane: *const Pane) u8 {
        if (self.floatUiConst(pane)) |ui| return ui.pad_y;
        return 0;
    }

    pub fn setLocalFloatState(
        self: *State,
        pane_uuid: [32]u8,
        parent_tab: ?usize,
        visible: bool,
        tab_visible: u64,
        sticky: bool,
        is_pwd: bool,
        float_key: u8,
        width_pct: u8,
        height_pct: u8,
        pos_x_pct: u8,
        pos_y_pct: u8,
        pad_x: u8,
        pad_y: u8,
        active: bool,
    ) void {
        self.runtime.syncFloatState(.{
            .pane_uuid = pane_uuid,
            .parent_tab = parent_tab,
            .visible = visible,
            .tab_visible = tab_visible,
            .sticky = sticky,
            .is_pwd = is_pwd,
            .float_key = float_key,
            .width_pct = width_pct,
            .height_pct = height_pct,
            .pos_x_pct = pos_x_pct,
            .pos_y_pct = pos_y_pct,
            .pad_x = pad_x,
            .pad_y = pad_y,
        }, active);
    }

    pub fn setPaneVisibleOnTab(self: *State, pane: *const Pane, tab: usize, visible: bool) void {
        self.runtime.setFloatVisibleOnTab(pane.uuid, tab, visible);
    }

    pub fn togglePaneVisibleOnTab(self: *State, pane: *const Pane, tab: usize) void {
        self.runtime.toggleFloatVisibleOnTab(pane.uuid, tab);
    }

    pub fn setPaneFloatGeometry(
        self: *State,
        pane: *const Pane,
        width_pct: u8,
        height_pct: u8,
        pos_x_pct: u8,
        pos_y_pct: u8,
        pad_x: u8,
        pad_y: u8,
    ) void {
        self.runtime.setFloatGeometry(
            pane.uuid,
            width_pct,
            height_pct,
            pos_x_pct,
            pos_y_pct,
            pad_x,
            pad_y,
        );
    }

    pub fn swapPaneFloatGeometry(self: *State, a: *const Pane, b: *const Pane) void {
        self.runtime.swapFloatGeometry(a.uuid, b.uuid);
    }

    pub fn reindexFloatParentTabsAfterRemovedTab(self: *State, removed_idx: usize) void {
        self.runtime.reindexFloatParentTabsAfterRemovedTab(removed_idx);
    }

    pub fn normalizeFloatParentTabs(self: *State, tab_count: usize) usize {
        return self.runtime.normalizeFloatParentTabs(tab_count);
    }

    pub fn setPaneNameOwned(self: *State, uuid: [32]u8, name_owned: []u8) void {
        self.runtime.setPaneNameOwned(uuid, name_owned);
    }

    pub fn paneName(self: *const State, uuid: [32]u8) ?[]const u8 {
        return self.runtime.paneName(uuid);
    }

    pub fn hasPaneName(self: *const State, uuid: [32]u8) bool {
        return self.runtime.hasPaneName(uuid);
    }

    pub fn removePaneProcMetadata(self: *State, uuid: [32]u8) void {
        self.runtime.removePaneProc(uuid);
    }

    pub fn removePaneName(self: *State, uuid: [32]u8) void {
        self.runtime.removePaneName(uuid);
    }
};
