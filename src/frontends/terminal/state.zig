const std = @import("std");
const posix = std.posix;
const cregex = @cImport({
    @cInclude("regex_shim.h");
});

const core = @import("core");
const frontend_core = @import("frontend_core");
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
const pane_search = @import("pane_search.zig");
const Layout = layout_mod.Layout;

const Renderer = @import("render_core.zig").Renderer;

const FrontendRuntime = core.FrontendRuntime;
const PaneShellInfo = core.SessionProjectionPaneShellInfo;
const PaneProcInfo = core.SessionProjectionPaneProcInfo;

const NotificationManager = pop.notification.NotificationManager;

const OverlayManager = pop.overlay.OverlayManager;

const Pane = @import("pane.zig").Pane;
const VtWriteQueue = @import("vt_write_queue.zig").Queue;
const helpers = @import("helpers.zig");

const BindKey = core.Config.BindKey;

fn writeControlLogged(fd: posix.fd_t, msg_type: wire.MsgType, payload: []const u8, comptime context: []const u8) void {
    wire.writeControl(fd, msg_type, payload) catch |err| {
        core.logging.logError("terminal", context, err);
    };
}
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
    exit_key: ?[]const u8 = null,
    closed_by_exit_key: bool = false,
    float_style: ?*const core.FloatStyle = null,
    float_title: ?[]const u8 = null,
};

pub const FloatVisualKind = enum { named, adhoc };

pub const ResolvedFloatVisuals = struct {
    width_pct: u8,
    height_pct: u8,
    pad_x: u8,
    pad_y: u8,
    border_color: core.BorderColor,
    float_style: ?*const core.FloatStyle = null,
};

const ReplacementNewPaneRollback = enum {
    kill_new_pane,
    orphan_new_pane,
};

const adhoc_title_outputs = [_]core.OutputDef{
    .{ .style = "bg:1 fg:0", .format = " $output " },
};

const adhoc_title_segment = core.Segment{
    .name = "title",
    .kind = .builtin,
    .builtin = "title",
    .outputs = adhoc_title_outputs[0..],
};

const adhoc_title_style = core.FloatStyle{
    .position = .bottomright,
    .module = adhoc_title_segment,
};

/// Keyboard copy-mode cursor state. Coordinates are local to the focused pane
/// (same convention mouse_selection.begin/update expect), so selection reuses
/// the exact scroll-aware machinery the mouse path uses.
pub const CopyMode = struct {
    active: bool = false,
    x: u16 = 0,
    y: u16 = 0,
    selecting: bool = false,
};

fn clampAdd(cur: u16, delta: i16, max: u16) u16 {
    const signed = @as(i32, cur) + delta;
    if (signed < 0) return 0;
    const val: u16 = @intCast(@min(signed, @as(i32, max)));
    return val;
}

pub const State = struct {
    fn floatStyleShowsTitle(style: ?*const core.FloatStyle) bool {
        const value = style orelse return false;
        if (value.position == null) return false;
        return value.module != null or value.title_segments.len > 0;
    }

    fn titleMatchesPattern(self: *const State, pattern: []const u8, title: ?[]const u8) bool {
        const title_text = title orelse return false;
        if (pattern.len == 0 or title_text.len == 0) return false;
        const pattern_z = self.allocator.dupeZ(u8, pattern) catch |err| {
            core.logging.logError("terminal", "failed to allocate float match pattern", err);
            return false;
        };
        defer self.allocator.free(pattern_z);
        const title_z = self.allocator.dupeZ(u8, title_text) catch |err| {
            core.logging.logError("terminal", "failed to allocate float title match text", err);
            return false;
        };
        defer self.allocator.free(title_z);

        const holder = cregex.hexe_regex_create() orelse return false;
        defer cregex.hexe_regex_destroy(holder);

        if (cregex.hexe_regex_compile(holder, pattern_z.ptr) != 0) {
            return false;
        }
        return cregex.hexe_regex_match(holder, title_z.ptr) == 0;
    }

    fn applyFloatMatchRule(result: *ResolvedFloatVisuals, rule: *const core.config.FloatVisualRule) void {
        if (rule.width_percent) |value| result.width_pct = value;
        if (rule.height_percent) |value| result.height_pct = value;
        if (rule.padding_x) |value| result.pad_x = value;
        if (rule.padding_y) |value| result.pad_y = value;
        if (rule.color) |value| result.border_color = value;
        if (rule.style) |*value| result.float_style = value;
    }

    pub fn resolveFloatVisuals(self: *const State, kind: FloatVisualKind, title: ?[]const u8) ResolvedFloatVisuals {
        const base = switch (kind) {
            .named => &self.config.float_named_defaults,
            .adhoc => &self.config.float_adhoc_defaults,
        };

        var result = ResolvedFloatVisuals{
            .width_pct = base.width_percent,
            .height_pct = base.height_percent,
            .pad_x = base.padding_x,
            .pad_y = base.padding_y,
            .border_color = base.color,
            .float_style = if (base.style) |*style| style else null,
        };

        for (self.config.float_match_rules) |*rule| {
            if (!self.titleMatchesPattern(rule.pattern, title)) continue;
            applyFloatMatchRule(&result, &rule.visual);
        }

        if (kind == .adhoc and !floatStyleShowsTitle(result.float_style)) {
            if (title) |value| {
                if (value.len > 0) {
                    if (floatStyleShowsTitle(if (self.config.float_named_defaults.style) |*style| style else null)) {
                        result.float_style = if (self.config.float_named_defaults.style) |*style| style else null;
                    } else {
                        result.float_style = &adhoc_title_style;
                    }
                }
            }
        }

        return result;
    }

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
    frontend_view: ?frontend_core.SessionView,
    active_layout_floats: []const core.LayoutFloatDef,
    view: TerminalViewState,
    float_ui: std.AutoHashMap([32]u8, FloatUiState),
    running: bool,
    needs_render: bool,
    force_full_render: bool,
    /// When true, keyboard input is broadcast to every split pane in the
    /// active tab (tmux `synchronize-panes`). Toggled by pane.sync_toggle.
    sync_input: bool = false,
    /// When set, the tiled pane with this uuid is zoomed to full tab bounds
    /// (tmux `resize-pane -Z`). Local view state — resets on reattach. Toggled
    /// by pane.zoom; auto-cleared by any layout-mutating operation.
    zoomed_pane_uuid: ?[32]u8 = null,
    /// Keyboard copy-mode (tmux copy-mode): a cursor over the focused pane that
    /// drives the shared mouse_selection machinery. When active, input is
    /// captured for navigation/selection instead of forwarded to the pane.
    copy_mode: CopyMode = .{},
    search_mode: pane_search.PaneSearch = .{},
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
    /// Background runner for every external command the render path needs
    /// (statusbar segments, float titles, `when` conditions, git, sudo).
    /// Driven once per event-loop iteration; the render path only ever reads
    /// its last completed values, so a slow command can never stall a frame.
    async_cmds: core.async_cmd.AsyncCmdCache,
    /// Resumable non-blocking reader for the SES VT stream. Reset whenever
    /// the VT connection is replaced (loop_watchers arms a new node).
    mux_vt_reader: @import("frontend_core").MuxVtReader = .{},
    mux_vt_write_overflow_notified: bool,

    // Stdin input can arrive split across reads. When using escape-sequence based
    // encodings (CSI-u, mouse events, etc) we must not forward partial sequences
    // into the focused pane. Keep a small tail buffer to stitch reads.
    stdin_tail: [256]u8 = undefined,
    stdin_tail_len: u16 = 0,

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

    // Tab rename (inline editing). While active, keystrokes edit the tab name
    // live in the projection (so the tab bar reflects them with no special
    // render path); Enter persists to SES, Esc restores the original.
    tab_rename_index: ?usize = null,
    tab_rename_buf: std.ArrayList(u8) = .empty,
    tab_rename_original: std.ArrayList(u8) = .empty,

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
        log_level: ?core.logging.Level,
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
        const runtime = try FrontendRuntime.createTerminal(allocator, uuid, session_name, log_level, log_file, connect_options);
        errdefer runtime.destroy();

        return .{
            .allocator = allocator,
            .config = cfg,
            .pop_config = pop_cfg,
            .ses_config = ses_cfg,
            .runtime = runtime,
            .frontend_view = null,
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
            .async_cmds = core.async_cmd.AsyncCmdCache.init(allocator),
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
        self.float_rename_buf.appendSlice(self.allocator, slice) catch |err| {
            core.logging.logError("terminal", "failed to initialize float rename buffer", err);
            self.float_rename_uuid = null;
            self.notifications.show("Rename failed");
            self.needs_render = true;
            return;
        };
        self.needs_render = true;
    }

    pub fn clearFloatRename(self: *State) void {
        self.float_rename_uuid = null;
        self.float_rename_buf.clearRetainingCapacity();
        self.needs_render = true;
    }

    pub fn beginTabRename(self: *State) void {
        const idx = self.activeTabIndex();
        const current = self.runtime.tabName(idx) orelse "";
        self.tab_rename_buf.clearRetainingCapacity();
        self.tab_rename_original.clearRetainingCapacity();
        const cap: usize = 64;
        const slice = current[0..@min(current.len, cap)];
        self.tab_rename_buf.appendSlice(self.allocator, slice) catch {
            self.notifications.show("Rename failed");
            self.needs_render = true;
            return;
        };
        self.tab_rename_original.appendSlice(self.allocator, current) catch {};
        self.tab_rename_index = idx;
        self.needs_render = true;
    }

    /// Append typed text to the tab rename buffer and reflect it live.
    pub fn appendTabRenameText(self: *State, text: []const u8) void {
        const idx = self.tab_rename_index orelse return;
        const max_len: usize = 64;
        if (self.tab_rename_buf.items.len >= max_len) return;
        const remaining = max_len - self.tab_rename_buf.items.len;
        const n = @min(text.len, remaining);
        self.tab_rename_buf.appendSlice(self.allocator, text[0..n]) catch return;
        _ = self.runtime.setTabName(idx, self.tab_rename_buf.items);
        self.needs_render = true;
    }

    pub fn backspaceTabRename(self: *State) void {
        const idx = self.tab_rename_index orelse return;
        if (self.tab_rename_buf.items.len > 0) {
            _ = self.tab_rename_buf.pop();
            _ = self.runtime.setTabName(idx, self.tab_rename_buf.items);
            self.needs_render = true;
        }
    }

    pub fn commitTabRename(self: *State) void {
        const idx = self.tab_rename_index orelse return;
        const new_name = std.mem.trim(u8, self.tab_rename_buf.items, " \t\r\n");
        if (new_name.len > 0) {
            _ = self.runtime.setTabName(idx, new_name);
            if (self.runtime.tabUuid(idx)) |tab_uuid| {
                self.runtime.sessionRenameTab(tab_uuid, new_name) catch |err| {
                    core.logging.logError("terminal", "tab rename SES sync failed", err);
                };
            }
        } else {
            // Empty name — restore the original.
            _ = self.runtime.setTabName(idx, self.tab_rename_original.items);
        }
        self.tab_rename_index = null;
        self.renderer.invalidate();
        self.force_full_render = true;
        self.needs_render = true;
    }

    pub fn cancelTabRename(self: *State) void {
        const idx = self.tab_rename_index orelse return;
        _ = self.runtime.setTabName(idx, self.tab_rename_original.items);
        self.tab_rename_index = null;
        self.needs_render = true;
    }

    pub fn isTabRenameActive(self: *const State) bool {
        return self.tab_rename_index != null;
    }

    /// Toggle zoom (maximize) of the focused tiled pane to full tab bounds.
    pub fn toggleZoom(self: *State) void {
        if (self.zoomed_pane_uuid != null) {
            self.clearZoom();
            return;
        }
        // Only tiled panes zoom; ignore when a float is focused or there is
        // nothing to maximize over.
        if (self.activeFloatingIndex() != null) return;
        const layout = self.currentLayout();
        if (layout.splitCount() <= 1) return;
        const pane = layout.getFocusedPane() orelse return;
        pane.resize(0, 0, self.layout_width, self.layout_height) catch |err| {
            core.logging.logError("terminal", "zoom resize failed", err);
            return;
        };
        self.zoomed_pane_uuid = pane.uuid;
        self.renderer.invalidate();
        self.force_full_render = true;
        self.needs_render = true;
        self.notifications.showFor("Zoom: ON", 900);
    }

    /// Restore normal tiled geometry if a pane is currently zoomed.
    pub fn clearZoom(self: *State) void {
        if (self.zoomed_pane_uuid == null) return;
        self.zoomed_pane_uuid = null;
        // Recompute the split tree geometry, resizing every pane back.
        self.currentLayout().resize(self.layout_width, self.layout_height);
        self.renderer.invalidate();
        self.force_full_render = true;
        self.needs_render = true;
        self.notifications.showFor("Zoom: OFF", 900);
    }

    /// Silently drop zoom state without a notification or recalc — used by
    /// layout-mutating operations that will recompute geometry themselves.
    pub fn dropZoom(self: *State) void {
        self.zoomed_pane_uuid = null;
    }

    pub fn isZoomed(self: *const State) bool {
        return self.zoomed_pane_uuid != null;
    }

    /// Enter keyboard copy-mode over the focused tiled pane.
    pub fn enterCopyMode(self: *State) void {
        if (self.activeFloatingIndex() != null) return; // tiled panes only (v1)
        if (self.currentLayout().getFocusedPane() == null) return;
        self.copy_mode = .{ .active = true, .x = 0, .y = 0, .selecting = false };
        self.notifications.showFor("Copy mode: hjkl/arrows move · v select · y yank · Esc exit", 2500);
        self.needs_render = true;
    }

    /// Move the copy-mode cursor, extending the selection if one is active.
    pub fn copyMove(self: *State, dx: i16, dy: i16) void {
        if (!self.copy_mode.active) return;
        const pane = self.currentLayout().getFocusedPane() orelse return;
        const max_x = if (pane.width > 0) pane.width - 1 else 0;
        const max_y = if (pane.height > 0) pane.height - 1 else 0;
        self.copy_mode.x = clampAdd(self.copy_mode.x, dx, max_x);
        self.copy_mode.y = clampAdd(self.copy_mode.y, dy, max_y);
        if (self.copy_mode.selecting) {
            self.mouse_selection.update(pane, self.copy_mode.x, self.copy_mode.y);
        }
        self.needs_render = true;
    }

    /// Start (or restart) a selection anchored at the current cursor.
    pub fn copyToggleSelect(self: *State) void {
        if (!self.copy_mode.active) return;
        const pane = self.currentLayout().getFocusedPane() orelse return;
        if (self.copy_mode.selecting) {
            self.mouse_selection.clear();
            self.copy_mode.selecting = false;
        } else {
            self.mouse_selection.begin(self.activeTabIndex(), pane.uuid, pane, self.copy_mode.x, self.copy_mode.y);
            self.copy_mode.selecting = true;
        }
        self.needs_render = true;
    }

    /// Yank the current selection to the system clipboard and exit copy-mode.
    pub fn copyYank(self: *State) void {
        if (!self.copy_mode.active) return;
        defer self.exitCopyMode();
        if (!self.copy_mode.selecting) return;
        const pane = self.currentLayout().getFocusedPane() orelse return;
        self.mouse_selection.update(pane, self.copy_mode.x, self.copy_mode.y);
        self.mouse_selection.finish();
        const range = self.mouse_selection.bufRangeForPane(self.activeTabIndex(), pane) orelse return;
        const bytes = mouse_selection.extractText(self.allocator, pane, range) catch return;
        defer self.allocator.free(bytes);
        if (bytes.len == 0) return;
        const stdout = std.fs.File.stdout();
        var io_buf: [256]u8 = undefined;
        var writer = stdout.writer(&io_buf);
        self.renderer.vx.copyToSystemClipboard(&writer.interface, bytes, self.allocator) catch return;
        self.notifications.showFor("Copied selection", 1200);
    }

    pub fn exitCopyMode(self: *State) void {
        self.copy_mode = .{};
        self.mouse_selection.clear();
        self.renderer.invalidate();
        self.force_full_render = true;
        self.needs_render = true;
    }

    pub fn isCopyModeActive(self: *const State) bool {
        return self.copy_mode.active;
    }

    // ── Scrollback search (PLAN 3.3) ──────────────────────────────────────────

    /// Enter scrollback-search over the focused pane.
    pub fn enterSearchMode(self: *State) void {
        if (self.currentLayout().getFocusedPane() == null) return;
        self.search_mode.enter();
        self.notifications.showFor("Search: type · Enter search · n/N next/prev · Esc exit", 2500);
        self.needs_render = true;
    }

    pub fn searchAppend(self: *State, text: []const u8) void {
        self.search_mode.appendText(self.allocator, text);
        self.needs_render = true;
    }

    pub fn searchBackspace(self: *State) void {
        self.search_mode.backspace();
        self.needs_render = true;
    }

    /// Run the typed query against the focused pane's scrollback.
    pub fn searchRun(self: *State) void {
        const pane = self.currentLayout().getFocusedPane() orelse {
            self.exitSearchMode();
            return;
        };
        const count = self.search_mode.run(self.allocator, pane);
        if (count == 0) self.notifications.showFor("No matches", 1500);
        self.markSearchDirty();
    }

    pub fn searchNext(self: *State) void {
        const pane = self.currentLayout().getFocusedPane() orelse return;
        self.search_mode.next(self.allocator, pane);
        self.markSearchDirty();
    }

    pub fn searchPrev(self: *State) void {
        const pane = self.currentLayout().getFocusedPane() orelse return;
        self.search_mode.prev(self.allocator, pane);
        self.markSearchDirty();
    }

    /// Tear down search. MUST be called before the focused pane can change
    /// (tab switch, pane close, reattach) — the search holds a screen pointer.
    pub fn exitSearchMode(self: *State) void {
        self.search_mode.exit();
        self.markSearchDirty();
    }

    pub fn isSearchActive(self: *const State) bool {
        return self.search_mode.active;
    }

    fn markSearchDirty(self: *State) void {
        self.renderer.invalidate();
        self.force_full_render = true;
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
                        writeControlLogged(fd, .pop_response, std.mem.asBytes(&resp), "failed to send pane pop cancel response");
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
        if (!self.setPaneFloatTitle(pane.uuid, if (new_title.len > 0) new_title else null)) {
            self.notifications.show("Rename failed");
            self.needs_render = true;
            return;
        }

        // Keep the pod's pane name separate from the float title.

        self.clearFloatRename();
        self.renderer.invalidate();
        self.force_full_render = true;
        if (!self.syncSessionFloatChecked(pane, self.activeFloatingIndex() != null)) {
            self.notifications.show("Rename failed: session sync rejected update");
        }
    }

    pub fn showConfirmOrNotify(self: *State, pending_action: PendingAction, message: []const u8) bool {
        self.pending_action = pending_action;
        self.popups.showConfirm(message, .{}) catch |err| {
            core.logging.logError("terminal", "failed to show confirmation popup", err);
            self.pending_action = null;
            self.notifications.show("Confirmation failed");
            self.needs_render = true;
            return false;
        };
        self.needs_render = true;
        return true;
    }

    pub fn showPickerOrNotify(
        self: *State,
        pending_action: PendingAction,
        labels: []const []const u8,
        title: []const u8,
    ) bool {
        self.popups.showPickerOwned(labels, .{ .title = title }) catch |err| {
            core.logging.logError("terminal", "failed to show picker popup", err);
            self.pending_action = null;
            self.notifications.show("Picker failed");
            self.needs_render = true;
            return false;
        };
        self.pending_action = pending_action;
        self.needs_render = true;
        return true;
    }

    pub fn deinit(self: *State) void {
        self.runtime.prepareFrontendExit(posix.STDIN_FILENO, true) catch |err| {
            core.logging.logError("terminal", "failed to finalize frontend exit with SES", err);
        };

        if (self.frontend_view) |*view| view.deinit();
        self.frontend_view = null;

        self.search_mode.deinit(self.allocator);
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
        self.async_cmds.deinit();
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
        self.tab_rename_buf.deinit(self.allocator);
        self.tab_rename_original.deinit(self.allocator);
        self.runtime.destroy();
    }

    pub fn enqueueOscReplyTarget(self: *State, uuid: [32]u8) void {
        self.osc_reply_targets.append(self.allocator, uuid) catch |err| {
            core.logging.logError("terminal", "failed to enqueue OSC reply target", err);
            return;
        };
        self.osc_reply_target_enqueued_ms.append(self.allocator, std.time.milliTimestamp()) catch |err| {
            core.logging.logError("terminal", "failed to timestamp OSC reply target", err);
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
        self.csi_reply_targets.append(self.allocator, uuid) catch |err| {
            core.logging.logError("terminal", "failed to enqueue CSI reply target", err);
            return;
        };
        self.csi_reply_target_enqueued_ms.append(self.allocator, std.time.milliTimestamp()) catch |err| {
            core.logging.logError("terminal", "failed to timestamp CSI reply target", err);
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
        // The write to the dying socket failed. Drop the live queue (its head
        // frame may be half-written to the dead socket) but KEEP the replay ring
        // — the reconnect rebuilds the live queue from it, so input typed as the
        // daemon died is re-sent and the pod dedups anything already applied.
        self.mux_vt_write_queue.clear();
        _ = self.runtime.closeVtFdIf(fd);
        self.notifications.showFor("Lost connection to ses daemon (VT) — reconnecting...", 5000);
        self.needs_render = true;
    }

    fn noteMuxVtQueueOverflow(self: *State) void {
        if (self.mux_vt_write_overflow_notified) return;
        self.mux_vt_write_overflow_notified = true;
        self.notifications.showFor("Pane input queue full; some pasted bytes were dropped", 3000);
        self.needs_render = true;
    }

    pub fn flushPendingMuxVtWrites(self: *State) void {
        const fd = self.runtime.getVtFd() orelse {
            if (self.mux_vt_write_queue.queuedBytes() > 0) {
                core.logging.warn("terminal", "pending pane input cannot flush: SES VT channel is unavailable", .{});
            }
            return;
        };
        self.mux_vt_write_queue.flushToFd(fd) catch {
            self.handleMuxVtWriteFailure(fd);
            return;
        };
        if (self.mux_vt_write_queue.queuedBytes() == 0) {
            self.mux_vt_write_overflow_notified = false;
        }
    }

    /// Register this State's mux-VT write queue as the single writer for all
    /// pane->pod frames (input, resize, password-mode). Must be called once
    /// the State has a stable address. See pane.zig queuePodFrame for why
    /// direct writes are forbidden.
    pub fn registerSharedVtQueue(self: *State) void {
        // A per-process input epoch, stable across THIS frontend's own reconnects
        // but unique vs a fresh reattaching frontend. The pod uses it to tell a
        // reconnect (dedup by seq) from a reattach (reset the input stream).
        if (self.mux_vt_write_queue.epoch == 0) {
            self.mux_vt_write_queue.epoch = std.crypto.random.int(u64) | 1; // never 0
        }
        @import("pane.zig").setSharedVtWriteQueue(&self.mux_vt_write_queue, self.allocator);
        // Register the async command runner too: from here on, every segment
        // command in the render path is served from cache and executed in the
        // background instead of blocking the loop.
        core.cmd.setAsyncCache(&self.async_cmds);
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
        // Zoom is per-tab and would blank a tab whose panes don't match the
        // zoomed uuid — drop it on any tab change.
        self.zoomed_pane_uuid = null;
        const clamped = if (self.view.tab_views.items.len == 0) 0 else @min(idx, self.view.tab_views.items.len - 1);
        self.runtime.setActiveTab(clamped);
        if (self.frontend_view) |*view| {
            _ = frontend_core.applyViewActionWithContext(view, .tab_select, .{
                .active_tab_idx = clamped,
            }) catch |err| {
                core.logging.logError("terminal", "failed to apply shared active tab selection", err);
            };
        }
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
                const uuid = self.view.float_views.items[value].uuid;
                self.runtime.setActiveFloatUuid(uuid);
                if (self.frontend_view) |*view| {
                    _ = frontend_core.applyViewActionWithContext(view, .float_select, .{
                        .active_float_uuid = uuid,
                    }) catch |err| {
                        core.logging.logError("terminal", "failed to apply shared active float selection", err);
                    };
                }
                return;
            }
        }
        self.runtime.setActiveFloatUuid(null);
        if (self.frontend_view) |*view| {
            _ = frontend_core.applyViewActionWithContext(view, .float_select, .{
                .clear_active_float = true,
            }) catch |err| {
                core.logging.logError("terminal", "failed to clear shared active float selection", err);
            };
        }
    }

    pub fn setActiveFloatingUuid(self: *State, uuid: ?[32]u8) void {
        self.runtime.setActiveFloatUuid(uuid);
        if (self.frontend_view) |*view| {
            _ = frontend_core.applyViewActionWithContext(view, .float_select, if (uuid) |value| .{
                .active_float_uuid = value,
            } else .{
                .clear_active_float = true,
            }) catch |err| {
                core.logging.logError("terminal", "failed to apply shared active float uuid", err);
            };
        }
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

    /// SES-authoritative identity directory for a sticky/per-CWD float.
    /// Returns the captured `sticky_pwd`, never the float shell's live cwd.
    pub fn stickyFloatDir(self: *State, pane: *Pane) ?[]const u8 {
        return state_tabs.ensureStickyFloatDir(self, pane);
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
        const applied = state_tabs.applySessionSnapshot(self);
        if (applied) self.refreshFrontendView();
        return applied;
    }

    /// PARKED (PLAN.md 2.2): `frontend_view` is a `SessionView` mirror of the
    /// runtime that nothing renders from — `state.view` + `runtime` are the
    /// source of truth, and the only readers (switchToNextTab/Prev) fall back to
    /// them when it is null. Rather than pay to rebuild the mirror on every
    /// refresh for a consumer that doesn't exist yet, we leave it permanently
    /// null: every mutation site is already null-guarded and inert, and the
    /// `SessionView` machinery stays in the tree dormant for when a real second
    /// frontend needs it (at which point this becomes a populate + a renderer
    /// that reads it — the "commit" path). Do not repopulate it piecemeal.
    pub fn refreshFrontendView(self: *State) void {
        _ = self;
    }

    pub fn applyFrontendPaneCwd(self: *State, uuid: [32]u8, cwd: []const u8) void {
        if (self.frontend_view) |*view| {
            frontend_core.applyPaneCwdPayload(view, .{
                .uuid = uuid,
                .cwd = @constCast(cwd),
            }) catch {};
        }
    }

    pub fn applyFrontendPaneInfo(self: *State, uuid: [32]u8, name: ?[]const u8, fg_name: ?[]const u8, fg_pid: ?i32) void {
        if (self.frontend_view) |*view| {
            frontend_core.applyPaneInfoPayload(view, .{
                .uuid = uuid,
                .name = if (name) |value| @constCast(value) else null,
                .fg_name = if (fg_name) |value| @constCast(value) else null,
                .fg_pid = fg_pid,
            }) catch {};
        }
    }

    pub fn applyFrontendShellEvent(self: *State, payload: frontend_core.ShellEventPayload) void {
        if (self.frontend_view) |*view| {
            frontend_core.applyShellEventPayload(view, payload) catch {};
        }
    }

    pub fn applyFrontendPaneExited(self: *State, uuid: [32]u8) void {
        if (self.frontend_view) |*view| {
            frontend_core.applyPaneExitedPayload(view, .{ .uuid = uuid }) catch {};
        }
    }

    pub fn applyFrontendTabAdded(self: *State, tab_idx: usize, tab_uuid: [32]u8, name: []const u8, pane_uuid: [32]u8) void {
        if (self.frontend_view) |*view| {
            _ = frontend_core.applyViewActionWithContext(view, .tab_new, .{
                .add_tab = .{
                    .tab_idx = tab_idx,
                    .tab_uuid = tab_uuid,
                    .name = name,
                    .pane_uuid = pane_uuid,
                },
            }) catch |err| {
                core.logging.logError("terminal", "failed to mirror added tab into shared frontend view", err);
                return;
            };
        }
    }

    pub fn applyFrontendSplitPane(self: *State, tab_idx: usize, source_pane_uuid: [32]u8, new_pane_uuid: [32]u8, focused_pane_uuid: ?[32]u8, dir: layout_mod.SplitDir) void {
        if (self.frontend_view) |*view| {
            _ = frontend_core.applyViewActionWithContext(
                view,
                switch (dir) {
                    .horizontal => .split_h,
                    .vertical => .split_v,
                },
                .{
                    .split_pane = .{
                        .tab_idx = tab_idx,
                        .source_pane_uuid = source_pane_uuid,
                        .new_pane_uuid = new_pane_uuid,
                        .focused_pane_uuid = focused_pane_uuid,
                    },
                },
            ) catch |err| {
                core.logging.logError("terminal", "failed to mirror split pane into shared frontend view", err);
                return;
            };
        }
    }

    pub fn applyFrontendPaneRemoved(self: *State, pane_uuid: [32]u8, next_focus_uuid: ?[32]u8) void {
        if (self.frontend_view) |*view| {
            _ = frontend_core.applyViewActionWithContext(
                view,
                .pane_close,
                .{
                    .remove_pane_uuid = pane_uuid,
                    .next_focus_uuid = next_focus_uuid,
                },
            ) catch |err| {
                core.logging.logError("terminal", "failed to mirror removed pane into shared frontend view", err);
                return;
            };
        }
    }

    pub fn applyFrontendFloatSynced(self: *State, pane_uuid: [32]u8, pane: *Pane, active: bool) void {
        if (self.frontend_view) |*view| {
            _ = frontend_core.applyViewActionWithContext(view, .{ .float_toggle = self.paneFloatKey(pane) }, .{
                .sync_float = .{
                    .float_state = .{
                        .pane_uuid = pane_uuid,
                        .parent_tab = self.paneParentTab(pane),
                        .visible = if (self.paneFloatState(pane)) |float_state| float_state.visible else true,
                        .tab_visible = if (self.paneFloatState(pane)) |float_state| float_state.tab_visible else 0,
                        .sticky = self.paneSticky(pane),
                        .is_pwd = self.paneIsPwd(pane),
                        .float_key = self.paneFloatKey(pane),
                        .width_pct = self.paneFloatWidthPct(pane),
                        .height_pct = self.paneFloatHeightPct(pane),
                        .pos_x_pct = self.paneFloatPosXPct(pane),
                        .pos_y_pct = self.paneFloatPosYPct(pane),
                        .pad_x = self.paneFloatPadX(pane),
                        .pad_y = self.paneFloatPadY(pane),
                    },
                    .active = active,
                },
            }) catch |err| {
                core.logging.logError("terminal", "failed to mirror synced float into shared frontend view", err);
                return;
            };
        }
    }

    pub fn applyFrontendFloatGeometry(self: *State, pane: *Pane) void {
        if (self.frontend_view) |*view| {
            _ = frontend_core.applyViewActionWithContext(
                view,
                .{ .float_nudge = .right },
                .{
                    .float_geometry = .{
                        .pane_uuid = pane.uuid,
                        .width_pct = self.paneFloatWidthPct(pane),
                        .height_pct = self.paneFloatHeightPct(pane),
                        .pos_x_pct = self.paneFloatPosXPct(pane),
                        .pos_y_pct = self.paneFloatPosYPct(pane),
                        .pad_x = self.paneFloatPadX(pane),
                        .pad_y = self.paneFloatPadY(pane),
                    },
                },
            ) catch |err| {
                core.logging.logError("terminal", "failed to mirror float geometry into shared frontend view", err);
            };
        }
    }

    pub fn applyFrontendPaneReplaced(self: *State, old_pane_uuid: [32]u8, new_pane_uuid: [32]u8) void {
        if (self.frontend_view) |*view| {
            _ = frontend_core.applyViewActionWithContext(view, .pane_adopt, .{
                .replace_pane = .{
                    .old_pane_uuid = old_pane_uuid,
                    .new_pane_uuid = new_pane_uuid,
                },
            }) catch |err| {
                core.logging.logError("terminal", "failed to mirror replaced pane into shared frontend view", err);
                return;
            };
        }
    }

    pub fn applyFrontendSplitRatio(self: *State, first_anchor_uuid: [32]u8, second_anchor_uuid: [32]u8, ratio: f32) void {
        if (self.frontend_view) |*view| {
            _ = frontend_core.applyViewActionWithContext(view, .{ .split_resize = .right }, .{
                .split_ratio = .{
                    .first_anchor_uuid = first_anchor_uuid,
                    .second_anchor_uuid = second_anchor_uuid,
                    .ratio = ratio,
                },
            }) catch |err| {
                core.logging.logError("terminal", "failed to mirror split ratio into shared frontend view", err);
                return;
            };
        }
    }

    pub fn applyFrontendSplitResize(self: *State, direction: frontend_core.Direction, step_cells: u16) ?frontend_core.SplitRatioChange {
        if (self.frontend_view) |*view| {
            const axis_cells = switch (direction) {
                .left, .right => self.currentLayout().width,
                .up, .down => self.currentLayout().height,
            };
            const outcome = frontend_core.applyViewActionWithContext(
                view,
                .{ .split_resize = direction },
                .{
                    .split_axis_cells = axis_cells,
                    .step_cells = step_cells,
                },
            ) catch |err| {
                core.logging.logError("terminal", "failed to apply shared split resize", err);
                return null;
            };
            if (outcome.result != .applied) return null;
            return outcome.split_ratio;
        }
        return null;
    }

    pub fn applyFrontendFloatNudge(self: *State, pane: *Pane) void {
        if (self.frontend_view) |*view| {
            _ = frontend_core.applyViewActionWithContext(
                view,
                .{ .float_nudge = .right },
                .{
                    .float_geometry = .{
                        .pane_uuid = pane.uuid,
                        .width_pct = self.paneFloatWidthPct(pane),
                        .height_pct = self.paneFloatHeightPct(pane),
                        .pos_x_pct = self.paneFloatPosXPct(pane),
                        .pos_y_pct = self.paneFloatPosYPct(pane),
                        .pad_x = self.paneFloatPadX(pane),
                        .pad_y = self.paneFloatPadY(pane),
                    },
                },
            ) catch |err| {
                core.logging.logError("terminal", "failed to apply shared float nudge", err);
                return;
            };
        }
    }

    pub fn applyFrontendFocusMove(self: *State, direction: frontend_core.Direction, target_uuid: [32]u8) void {
        if (self.frontend_view) |*view| {
            _ = frontend_core.applyViewActionWithContext(
                view,
                .{ .focus_move = direction },
                .{ .focus_target_uuid = target_uuid },
            ) catch |err| {
                core.logging.logError("terminal", "failed to apply shared focus move", err);
                return;
            };
        }
    }

    pub fn applyFrontendTabRemoved(self: *State, tab_idx: usize, next_active_tab: ?usize) void {
        if (self.frontend_view) |*view| {
            if (view.active_tab == tab_idx) {
                switch (frontend_core.applyViewAction(view, .tab_close) catch |err| {
                    core.logging.logError("terminal", "failed to apply shared tab-close action", err);
                    return;
                }) {
                    .applied, .ignored => return,
                    .unsupported => {},
                }
            }
            _ = frontend_core.applyViewActionWithContext(view, .tab_remove, .{
                .remove_tab_idx = tab_idx,
                .next_active_tab_idx = next_active_tab,
            }) catch |err| {
                core.logging.logError("terminal", "failed to mirror removed tab into shared frontend view", err);
            };
        }
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

    pub fn replaceWithLayoutDef(self: *State, layout: *const core.LayoutDef) !void {
        return state_session.replaceWithLayoutDef(self, layout);
    }

    pub fn syncSessionTabAddedChecked(self: *State, tab_uuid: [32]u8, name: []const u8, pane_uuid: [32]u8) bool {
        if (!self.runtime.isConnected()) {
            self.applyFrontendTabAdded(self.activeTabIndex(), tab_uuid, name, pane_uuid);
            return true;
        }
        self.runtime.sessionAddTab(tab_uuid, pane_uuid, self.activeTabIndex(), name) catch |err| {
            core.logging.logError("terminal", "failed sessionAddTab IPC", err);
            return false;
        };
        self.applyFrontendTabAdded(self.activeTabIndex(), tab_uuid, name, pane_uuid);
        return true;
    }

    pub fn syncSessionTabRemovedChecked(self: *State, tab_uuid: [32]u8, active_tab: ?usize) bool {
        if (!self.runtime.isConnected()) return true;
        self.runtime.sessionRemoveTab(tab_uuid, active_tab) catch |err| {
            core.logging.logError("terminal", "failed sessionRemoveTab IPC", err);
            return false;
        };
        return true;
    }

    pub fn syncSessionFloatChecked(self: *State, pane: *Pane, active: bool) bool {
        if (!self.runtime.isConnected()) {
            self.applyFrontendFloatSynced(pane.uuid, pane, active);
            return true;
        }
        if (pane.uuid[0] == 0) return true;

        return self.syncSessionFloatUuid(pane.uuid, pane, active, "failed sessionSyncFloat IPC");
    }

    fn syncSessionFloatUuid(
        self: *State,
        pane_uuid: [32]u8,
        pane: *Pane,
        active: bool,
        comptime context: []const u8,
    ) bool {
        self.runtime.sessionSyncFloat(
            pane_uuid,
            self.activeTabIndex(),
            self.paneParentTab(pane),
            if (self.paneFloatState(pane)) |float_state| float_state.visible else true,
            if (self.paneFloatState(pane)) |float_state| float_state.tab_visible else 0,
            self.paneSticky(pane),
            self.paneIsPwd(pane),
            self.paneFloatKey(pane),
            self.paneFloatWidthPct(pane),
            self.paneFloatHeightPct(pane),
            self.paneFloatPosXPct(pane),
            self.paneFloatPosYPct(pane),
            self.paneFloatPadX(pane),
            self.paneFloatPadY(pane),
            active,
        ) catch |err| {
            core.logging.logError("terminal", context, err);
            return false;
        };
        self.applyFrontendFloatSynced(pane_uuid, pane, active);
        return true;
    }

    pub fn syncSessionSplitPaneChecked(
        self: *State,
        source_pane_uuid: [32]u8,
        new_pane_uuid: [32]u8,
        dir: layout_mod.SplitDir,
        focused_pane_uuid: ?[32]u8,
    ) bool {
        if (!self.runtime.isConnected()) {
            self.applyFrontendSplitPane(self.activeTabIndex(), source_pane_uuid, new_pane_uuid, focused_pane_uuid, dir);
            return true;
        }
        const tab_uuid = self.runtime.tabUuid(self.activeTabIndex()) orelse {
            core.logging.warn("terminal", "session split-pane sync skipped: active tab has no session UUID", .{});
            return false;
        };
        self.runtime.sessionSplitPane(
            tab_uuid,
            source_pane_uuid,
            new_pane_uuid,
            self.activeTabIndex(),
            focused_pane_uuid,
            switch (dir) {
                .horizontal => .horizontal,
                .vertical => .vertical,
            },
        ) catch |err| {
            core.logging.logError("terminal", "failed sessionSplitPane IPC", err);
            return false;
        };
        self.applyFrontendSplitPane(self.activeTabIndex(), source_pane_uuid, new_pane_uuid, focused_pane_uuid, dir);
        return true;
    }

    pub fn syncSessionPaneUuidReplacement(
        self: *State,
        old_pane_uuid: [32]u8,
        new_pane_uuid: [32]u8,
        pane: *Pane,
        active_float: bool,
    ) bool {
        if (!self.runtime.isConnected()) return true;

        if (self.paneIsFloating(pane)) {
            self.runtime.sessionRemoveFloat(old_pane_uuid) catch |err| {
                core.logging.logError("terminal", "failed sessionRemoveFloat IPC during pane replacement", err);
                return false;
            };
            if (!self.syncSessionFloatUuid(
                new_pane_uuid,
                pane,
                active_float,
                "failed sessionSyncFloat IPC during pane replacement",
            )) {
                _ = self.syncSessionFloatUuid(
                    old_pane_uuid,
                    pane,
                    active_float,
                    "failed sessionSyncFloat rollback during pane replacement",
                );
                return false;
            }
        } else {
            const tab_uuid = self.runtime.tabUuid(self.activeTabIndex()) orelse {
                core.logging.warn("terminal", "session split-pane replacement skipped: active tab has no session UUID", .{});
                return false;
            };
            self.runtime.sessionReplaceSplitPane(
                tab_uuid,
                old_pane_uuid,
                new_pane_uuid,
                self.activeTabIndex(),
                if (pane.focused) new_pane_uuid else null,
            ) catch |err| {
                core.logging.logError("terminal", "failed sessionReplaceSplitPane IPC during pane replacement", err);
                return false;
            };
        }
        return true;
    }

    pub fn rollbackSessionPaneUuidReplacement(
        self: *State,
        old_pane_uuid: [32]u8,
        new_pane_uuid: [32]u8,
        pane: *Pane,
        active_float: bool,
    ) void {
        if (!self.runtime.isConnected()) return;

        if (self.paneIsFloating(pane)) {
            self.runtime.sessionRemoveFloat(new_pane_uuid) catch |err| {
                core.logging.logError("terminal", "failed sessionRemoveFloat rollback IPC", err);
            };
            _ = self.syncSessionFloatUuid(
                old_pane_uuid,
                pane,
                active_float,
                "failed sessionSyncFloat rollback IPC",
            );
        } else {
            const tab_uuid = self.runtime.tabUuid(self.activeTabIndex()) orelse {
                core.logging.warn("terminal", "session split-pane replacement rollback skipped: active tab has no session UUID", .{});
                return;
            };
            self.runtime.sessionReplaceSplitPane(
                tab_uuid,
                new_pane_uuid,
                old_pane_uuid,
                self.activeTabIndex(),
                if (pane.focused) old_pane_uuid else null,
            ) catch |err| {
                core.logging.logError("terminal", "failed sessionReplaceSplitPane rollback IPC", err);
            };
        }
    }

    fn rollbackNewReplacementPane(
        self: *State,
        new_pane_uuid: [32]u8,
        rollback: ReplacementNewPaneRollback,
        comptime context: []const u8,
    ) void {
        switch (rollback) {
            .kill_new_pane => self.runtime.killPane(new_pane_uuid) catch |err| {
                core.logging.logError("terminal", context, err);
            },
            .orphan_new_pane => self.runtime.orphanPane(new_pane_uuid) catch |err| {
                core.logging.logError("terminal", context, err);
            },
        }
    }

    pub fn replacePaneWithPodSynced(
        self: *State,
        old_pane_uuid: [32]u8,
        new_pane_uuid: [32]u8,
        pane_id: u16,
        vt_fd: posix.fd_t,
        pane: *Pane,
        active_float: bool,
        rollback: ReplacementNewPaneRollback,
        comptime rollback_context: []const u8,
    ) bool {
        if (!self.syncSessionPaneUuidReplacement(old_pane_uuid, new_pane_uuid, pane, active_float)) {
            self.rollbackNewReplacementPane(new_pane_uuid, rollback, rollback_context);
            return false;
        }

        pane.replaceWithPod(pane_id, vt_fd, new_pane_uuid) catch |err| {
            core.logging.logError("terminal", "replacePaneWithPodSynced replaceWithPod failed", err);
            self.rollbackSessionPaneUuidReplacement(old_pane_uuid, new_pane_uuid, pane, active_float);
            self.rollbackNewReplacementPane(new_pane_uuid, rollback, rollback_context);
            return false;
        };
        self.applyFrontendPaneReplaced(old_pane_uuid, new_pane_uuid);

        return true;
    }

    pub fn respawnFocusedPaneAfterShellDeath(self: *State) bool {
        if (self.view.tab_views.items.len == 0) {
            core.logging.warn("terminal", "respawn shell death: no local tabs remain; creating replacement tab", .{});
            self.createTab() catch |err| {
                core.logging.logError("terminal", "respawn dead pane: failed to create replacement tab", err);
                self.notifications.show("Respawn failed");
                return false;
            };
            self.skip_dead_check = true;
            self.needs_render = true;
            return true;
        }

        const pane = self.currentLayout().getFocusedPane() orelse return false;
        const old_uuid = pane.uuid;
        if (!pane.isAlive() and self.currentLayout().splitCount() <= 1) {
            core.logging.warn("terminal", "respawn shell death: replacing last dead split with fresh tab", .{});
            self.runtime.killPane(old_uuid) catch |err| {
                core.logging.logError("terminal", "respawn dead pane: kill old pane failed", err);
            };
            self.clearTransientPaneState(pane);
            while (self.view.tab_views.items.len > 0) {
                const tab_opt = self.view.tab_views.pop();
                if (tab_opt) |tab_const| {
                    var tab = tab_const;
                    tab.deinit();
                }
            }
            self.runtime.clearTabMeta();
            self.runtime.clearTabFocusMemory();
            self.setActiveTabIndex(0);
            self.runtime.setFocusedPaneUuid(null);
            self.createTab() catch |err| {
                core.logging.logError("terminal", "respawn dead pane: failed to create replacement tab after clearing dead split", err);
                self.notifications.show("Respawn failed");
                return false;
            };
            self.skip_dead_check = true;
            self.needs_render = true;
            return true;
        }

        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        var cwd = self.getReliableCwd(pane);
        if (cwd == null) {
            cwd = std.posix.getcwd(&cwd_buf) catch |err| blk: {
                core.logging.logError("terminal", "respawn dead pane: failed to get fallback cwd", err);
                break :blk null;
            };
        }
        const old_aux = self.runtime.getPaneAux(pane.uuid) catch FrontendRuntime.PaneAuxInfo{
            .created_from = null,
            .focused_from = null,
        };
        const result = self.runtime.createPane(null, cwd, null, null, null, null, null) catch {
            self.notifications.show("Respawn failed");
            return false;
        };
        const vt_fd = self.runtime.getVtFd() orelse {
            self.runtime.killPane(result.uuid) catch {};
            self.notifications.show("Respawn failed: no VT channel");
            return false;
        };

        const active_float = self.paneIsFloating(pane);
        if (!self.replacePaneWithPodSynced(
            old_uuid,
            result.uuid,
            result.pane_id,
            vt_fd,
            pane,
            active_float,
            .kill_new_pane,
            "respawn dead pane: rollback killPane failed after replacement error",
        )) {
            self.notifications.show("Respawn failed");
            return false;
        }

        self.runtime.killPane(old_uuid) catch {};
        const pane_type: FrontendRuntime.PaneType = if (self.paneIsFloating(pane)) .float else .split;
        const cursor = pane.getCursorPos();
        const cursor_style = pane.vt.getCursorStyle();
        const cursor_visible = pane.vt.isCursorVisible();
        const alt_screen = pane.vt.inAltScreen();
        const layout_path = helpers.getLayoutPath(self, pane) catch |err| blk: {
            core.logging.logError("terminal", "respawn dead pane: failed to resolve layout path", err);
            break :blk null;
        };
        defer if (layout_path) |path| self.allocator.free(path);
        self.runtime.updatePaneAux(
            pane.uuid,
            self.activeTabIndex(),
            self.paneIsFloating(pane),
            self.paneIsFocused(pane),
            pane_type,
            old_aux.created_from,
            old_aux.focused_from,
            .{ .x = cursor.x, .y = cursor.y },
            cursor_style,
            cursor_visible,
            alt_screen,
            .{ .cols = pane.width, .rows = pane.height },
            pane.getPwd(),
            null,
            null,
            layout_path,
        ) catch |err| {
            core.logging.logError("terminal", "respawn dead pane: updatePaneAux failed after replacement", err);
            self.notifications.show("Respawn metadata sync failed");
        };

        self.skip_dead_check = true;
        self.needs_render = true;
        return true;
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
        self.renderer.resize(cols, rows) catch |err| {
            core.logging.logError("terminal", "renderer resize failed after terminal resize", err);
        };
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
        const entry = self.float_ui.getOrPut(pane_uuid) catch |err| {
            core.logging.logError("terminal", "failed to allocate float UI state", err);
            return null;
        };
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
        var next = FloatUiState{
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
            .closed_by_exit_key = cfg.closed_by_exit_key,
            .float_style = cfg.float_style,
        };
        if (cfg.pwd_dir) |dir| {
            next.pwd_dir = self.allocator.dupe(u8, dir) catch {
                core.logging.logError("terminal", "failed to allocate float pwd dir", error.OutOfMemory);
                next.deinit(self.allocator);
                return false;
            };
        }
        if (cfg.exit_key) |key| {
            next.exit_key = self.allocator.dupe(u8, key) catch {
                core.logging.logError("terminal", "failed to allocate float exit key", error.OutOfMemory);
                next.deinit(self.allocator);
                return false;
            };
        }
        if (cfg.float_title) |title| {
            next.float_title = self.allocator.dupe(u8, title) catch {
                core.logging.logError("terminal", "failed to allocate float title", error.OutOfMemory);
                next.deinit(self.allocator);
                return false;
            };
        }
        const ui = self.ensureFloatUi(pane_uuid) orelse {
            next.deinit(self.allocator);
            return false;
        };
        ui.deinit(self.allocator);
        ui.* = next;
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
        const a = self.float_ui.getPtr(a_uuid) orelse {
            core.logging.warn("terminal", "swapPaneFloatUi skipped: first pane has no float UI state", .{});
            return;
        };
        const b = self.float_ui.getPtr(b_uuid) orelse {
            core.logging.warn("terminal", "swapPaneFloatUi skipped: second pane has no float UI state", .{});
            return;
        };

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

    pub const FloatUsableArea = struct {
        w: u16,
        h: u16,
    };

    pub const FloatFrame = struct {
        usable_w: u16,
        usable_h: u16,
        outer_x: u16,
        outer_y: u16,
        outer_w: u16,
        outer_h: u16,
        content_x: u16,
        content_y: u16,
        content_w: u16,
        content_h: u16,
        max_x: u16,
        max_y: u16,
    };

    pub fn floatUsableArea(self: *const State, shadow_enabled: bool) FloatUsableArea {
        const avail_h: u16 = self.term_height - self.status_height;
        return .{
            .w = if (shadow_enabled) (self.term_width -| 1) else self.term_width,
            .h = if (shadow_enabled and self.status_height == 0) (avail_h -| 1) else avail_h,
        };
    }

    pub fn floatFrameFromValues(
        self: *const State,
        width_pct: u16,
        height_pct: u16,
        pos_x_pct: u16,
        pos_y_pct: u16,
        pad_x_cfg: u16,
        pad_y_cfg: u16,
        shadow_enabled: bool,
    ) FloatFrame {
        const usable = self.floatUsableArea(shadow_enabled);
        const width = @min(width_pct, 100);
        const height = @min(height_pct, 100);
        const pos_x = @min(pos_x_pct, 100);
        const pos_y = @min(pos_y_pct, 100);

        const outer_w: u16 = usable.w * width / 100;
        const outer_h: u16 = usable.h * height / 100;
        const max_x: u16 = usable.w -| outer_w;
        const max_y: u16 = usable.h -| outer_h;
        const outer_x: u16 = max_x * pos_x / 100;
        const outer_y: u16 = max_y * pos_y / 100;
        const pad_x: u16 = 1 + pad_x_cfg;
        const pad_y: u16 = 1 + pad_y_cfg;

        return .{
            .usable_w = usable.w,
            .usable_h = usable.h,
            .outer_x = outer_x,
            .outer_y = outer_y,
            .outer_w = outer_w,
            .outer_h = outer_h,
            .content_x = outer_x + pad_x,
            .content_y = outer_y + pad_y,
            .content_w = outer_w -| (pad_x * 2),
            .content_h = outer_h -| (pad_y * 2),
            .max_x = max_x,
            .max_y = max_y,
        };
    }

    pub fn floatFrameForPane(self: *const State, pane: *const Pane) FloatFrame {
        return self.floatFrameFromValues(
            self.paneFloatWidthPct(pane),
            self.paneFloatHeightPct(pane),
            self.paneFloatPosXPct(pane),
            self.paneFloatPosYPct(pane),
            self.paneFloatPadX(pane),
            self.paneFloatPadY(pane),
            self.paneFloatHasShadow(pane),
        );
    }

    pub fn paneFloatTitle(self: *const State, pane: *const Pane) ?[]const u8 {
        if (self.floatUiConst(pane)) |ui| return ui.float_title;
        return null;
    }

    pub fn setPaneFloatTitle(self: *State, pane_uuid: [32]u8, title: ?[]const u8) bool {
        const ui = self.ensureFloatUi(pane_uuid) orelse {
            core.logging.warn("terminal", "setPaneFloatTitle skipped: failed to ensure float UI state", .{});
            return false;
        };
        const next_title = if (title) |value|
            self.allocator.dupe(u8, value) catch |err| {
                core.logging.logError("terminal", "failed to allocate pane float title", err);
                return false;
            }
        else
            null;
        if (ui.float_title) |old| {
            self.allocator.free(old);
            ui.float_title = null;
        }
        ui.float_title = next_title;
        return true;
    }

    pub fn panePwdDir(self: *const State, pane: *const Pane) ?[]const u8 {
        if (self.floatUiConst(pane)) |ui| return ui.pwd_dir;
        return null;
    }

    pub fn setPanePwdDir(self: *State, pane_uuid: [32]u8, pwd_dir: ?[]const u8) bool {
        const ui = self.ensureFloatUi(pane_uuid) orelse return false;
        if (ui.pwd_dir) |old| {
            self.allocator.free(old);
            ui.pwd_dir = null;
        }
        if (pwd_dir) |dir| {
            ui.pwd_dir = self.allocator.dupe(u8, dir) catch {
                core.logging.logError("terminal", "failed to allocate float pwd dir", error.OutOfMemory);
                return false;
            };
        }
        return true;
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

    pub fn clearLocalFloatState(self: *State, pane_uuid: [32]u8) void {
        self.runtime.removeLocalFloatState(pane_uuid);
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
