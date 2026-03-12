const std = @import("std");
const posix = std.posix;
const ipc = @import("ipc.zig");
const frontend_attach = @import("frontend_attach.zig");
const FrontendAttachState = @import("frontend_attach_state.zig").FrontendAttachState;
const FrontendClient = @import("frontend_client.zig").SesClient;
const DetachedSessionInfo = @import("frontend_client.zig").DetachedSessionInfo;
const OrphanedPaneInfo = @import("frontend_client.zig").OrphanedPaneInfo;
const Transport = @import("frontend_client.zig").Transport;
const ConnectOptions = @import("frontend_transport_helpers.zig").ConnectOptions;
const transport_helpers = @import("frontend_transport_helpers.zig");
const session_model = @import("session_model.zig");
const TabFocusKind = @import("session_projection.zig").TabFocusKind;
const SessionProjection = @import("session_projection.zig").SessionProjection;
const logging = @import("logging.zig");
const wire = @import("wire.zig");

pub const FrontendRuntime = struct {
    pub const StopReason = FrontendAttachState.StopReason;
    pub const PaneType = FrontendClient.PaneType;
    pub const PaneAuxInfo = FrontendClient.PaneAuxInfo;
    pub const PaneInfoSnapshot = FrontendClient.PaneInfoSnapshot;
    pub const PaneProcessInfo = FrontendClient.PaneProcessInfo;
    pub const PaneAttachResult = struct {
        uuid: [32]u8,
        pane_id: u16,
        pid: posix.pid_t,
    };
    pub const CursorPos = struct {
        x: u16,
        y: u16,
    };
    pub const PaneSize = struct {
        cols: u16,
        rows: u16,
    };

    pub const ReattachSnapshotResult = struct {
        snapshot: session_model.SessionSnapshot,
        pane_uuids: [][32]u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *ReattachSnapshotResult) void {
            self.snapshot.deinit();
            self.allocator.free(self.pane_uuids);
            self.* = undefined;
        }
    };

    pub const StartupAttachResult = struct {
        started_daemon: bool,
        name_change: ?frontend_attach.SessionNameChange = null,

        pub fn deinit(self: *StartupAttachResult, allocator: std.mem.Allocator) void {
            if (self.name_change) |value| {
                var owned_value = value;
                owned_value.deinit(allocator);
            }
            self.* = undefined;
        }
    };

    allocator: std.mem.Allocator,
    client: FrontendClient,
    projection: SessionProjection,
    attach_state: FrontendAttachState,

    pub fn create(
        allocator: std.mem.Allocator,
        session_id: [32]u8,
        session_name: []const u8,
        keepalive: bool,
        debug: bool,
        log_file: ?[]const u8,
        frontend_kind: wire.FrontendKind,
        transport: Transport,
    ) !*FrontendRuntime {
        const runtime = try allocator.create(FrontendRuntime);
        errdefer allocator.destroy(runtime);

        runtime.allocator = allocator;
        runtime.client = FrontendClient.initWithTransport(
            allocator,
            session_id,
            session_name,
            keepalive,
            debug,
            log_file,
            frontend_kind,
            transport,
        );
        errdefer runtime.client.deinit();

        runtime.projection = try SessionProjection.init(allocator, session_id, session_name);
        runtime.attach_state = .{};
        return runtime;
    }

    pub fn createTerminal(
        allocator: std.mem.Allocator,
        session_id: [32]u8,
        session_name: []const u8,
        debug: bool,
        log_file: ?[]const u8,
        connect_options: ConnectOptions,
    ) !*FrontendRuntime {
        return create(
            allocator,
            session_id,
            session_name,
            true,
            debug,
            log_file,
            .terminal,
            transport_helpers.resolveTransport(connect_options),
        );
    }

    pub fn createTerminalProbe(
        allocator: std.mem.Allocator,
        debug: bool,
        log_file: ?[]const u8,
        connect_options: ConnectOptions,
    ) !*FrontendRuntime {
        return create(
            allocator,
            ipc.generateUuid(),
            ipc.generateSessionName(),
            false,
            debug,
            log_file,
            .terminal,
            transport_helpers.resolveTransport(connect_options),
        );
    }

    pub fn destroy(self: *FrontendRuntime) void {
        const allocator = self.allocator;
        self.projection.deinit();
        self.client.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn connect(self: *FrontendRuntime) !void {
        try self.client.connect();
    }

    pub fn sessionUuid(self: *const FrontendRuntime) [32]u8 {
        return self.projection.sessionUuid();
    }

    pub fn sessionName(self: *const FrontendRuntime) []const u8 {
        return self.projection.sessionName();
    }

    pub fn setSessionIdentity(self: *FrontendRuntime, uuid: [32]u8, session_name: []const u8) bool {
        self.projection.setSessionIdentity(uuid, session_name) catch return false;
        self.syncClientSessionIdentity();
        return true;
    }

    pub fn setSessionName(self: *FrontendRuntime, session_name: []const u8) bool {
        return self.setSessionIdentity(self.sessionUuid(), session_name);
    }

    pub fn focusedPaneUuid(self: *const FrontendRuntime) ?[32]u8 {
        return self.projection.focusedPaneUuid();
    }

    pub fn setFocusedPaneUuid(self: *FrontendRuntime, uuid: ?[32]u8) void {
        self.projection.setFocusedPaneUuid(uuid);
    }

    pub fn activeTab(self: *const FrontendRuntime, tab_count: usize) usize {
        return self.projection.activeTab(tab_count);
    }

    pub fn setActiveTab(self: *FrontendRuntime, active_tab: usize) void {
        self.projection.setActiveTab(active_tab);
    }

    pub fn activeFloatUuid(self: *const FrontendRuntime) ?[32]u8 {
        return self.projection.activeFloatUuid();
    }

    pub fn setActiveFloatUuid(self: *FrontendRuntime, uuid: ?[32]u8) void {
        self.projection.setActiveFloatUuid(uuid);
    }

    pub fn rememberFloatingFocus(self: *FrontendRuntime, active_tab: usize, pane_uuid: [32]u8) void {
        self.projection.rememberFloatingFocus(active_tab, pane_uuid);
    }

    pub fn rememberSplitFocus(self: *FrontendRuntime, active_tab: usize) void {
        self.projection.rememberSplitFocus(active_tab);
    }

    pub fn attachFrontend(self: *FrontendRuntime) !StartupAttachResult {
        try self.connect();
        return .{
            .started_daemon = self.justStartedDaemon(),
            .name_change = try frontend_attach.reconcileResolvedName(
                self.allocator,
                &self.client,
                &self.projection,
            ),
        };
    }

    pub fn isConnected(self: *const FrontendRuntime) bool {
        return self.client.ctl_fd != null;
    }

    pub fn justStartedDaemon(self: *const FrontendRuntime) bool {
        return self.client.just_started_daemon;
    }

    pub fn getVtFd(self: *FrontendRuntime) ?posix.fd_t {
        return self.client.getVtFd();
    }

    pub fn getCtlFd(self: *FrontendRuntime) ?posix.fd_t {
        return self.client.getCtlFd();
    }

    pub fn currentVtFd(self: *FrontendRuntime) ?posix.fd_t {
        return self.client.vt_fd;
    }

    pub fn currentCtlFd(self: *FrontendRuntime) ?posix.fd_t {
        return self.client.ctl_fd;
    }

    pub fn closeVtFdIf(self: *FrontendRuntime, fd: posix.fd_t) bool {
        if (self.client.vt_fd) |live_fd| {
            if (live_fd == fd) {
                posix.close(live_fd);
                self.client.vt_fd = null;
                return true;
            }
        }
        return false;
    }

    pub fn closeCtlFdIf(self: *FrontendRuntime, fd: posix.fd_t) bool {
        if (self.client.ctl_fd) |live_fd| {
            if (live_fd == fd) {
                posix.close(live_fd);
                self.client.ctl_fd = null;
                return true;
            }
        }
        return false;
    }

    pub fn takePendingCwdUuid(self: *FrontendRuntime) ?[32]u8 {
        const uuid = self.client.pending_cwd_uuid orelse return null;
        self.client.pending_cwd_uuid = null;
        return uuid;
    }

    pub fn syncClientSessionIdentity(self: *FrontendRuntime) void {
        self.client.session_id = self.projection.sessionUuid();
        self.client.session_name = self.projection.sessionName();
    }

    pub fn shutdown(self: *FrontendRuntime, preserve_sticky: bool) !void {
        try self.client.shutdown(preserve_sticky);
    }

    pub fn detachSession(self: *FrontendRuntime, session_id: [32]u8) !void {
        try self.client.detachSession(session_id);
    }

    pub fn detachCurrentSession(self: *FrontendRuntime) !void {
        self.setDetachMode(true);
        try self.detachSession(self.projection.sessionUuid());
    }

    pub fn prepareFrontendExit(self: *FrontendRuntime, stdin_fd: posix.fd_t, preserve_sticky: bool) !void {
        if (!self.isDetachMode()) {
            _ = posix.tcgetattr(stdin_fd) catch {
                self.setDetachMode(true);
            };
        }

        if (!self.isDetachMode() and self.isConnected()) {
            try self.shutdown(preserve_sticky);
        }
    }

    pub fn drainPendingPaneExits(self: *FrontendRuntime, out: *std.ArrayList([32]u8)) void {
        self.client.drainPendingPaneExits(out);
    }

    pub fn sendPing(self: *FrontendRuntime) bool {
        return self.client.sendPing();
    }

    pub fn createPane(
        self: *FrontendRuntime,
        shell: ?[]const u8,
        cwd: ?[]const u8,
        sticky_pwd: ?[]const u8,
        sticky_key: ?u8,
        env: ?[]const []const u8,
        isolation_profile: ?[]const u8,
        inherit_env_parent_uuid: ?[32]u8,
    ) !PaneAttachResult {
        const result = try self.client.createPane(
            shell,
            cwd,
            sticky_pwd,
            sticky_key,
            env,
            isolation_profile,
            inherit_env_parent_uuid,
        );
        return .{
            .uuid = result.uuid,
            .pane_id = result.pane_id,
            .pid = result.pid,
        };
    }

    pub fn findStickyPane(
        self: *FrontendRuntime,
        pwd: []const u8,
        key: u8,
    ) !?PaneAttachResult {
        const result = try self.client.findStickyPane(pwd, key);
        if (result) |found| {
            return .{
                .uuid = found.uuid,
                .pane_id = found.pane_id,
                .pid = found.pid,
            };
        }
        return null;
    }

    pub fn orphanPane(self: *FrontendRuntime, uuid: [32]u8) !void {
        try self.client.orphanPane(uuid);
    }

    pub fn setSticky(self: *FrontendRuntime, uuid: [32]u8, pwd: []const u8, key: u8) !void {
        try self.client.setSticky(uuid, pwd, key);
    }

    pub fn killPane(self: *FrontendRuntime, uuid: [32]u8) !void {
        try self.client.killPane(uuid);
    }

    pub fn requestPaneCwd(self: *FrontendRuntime, uuid: [32]u8) void {
        self.client.requestPaneCwd(uuid);
    }

    pub fn getPaneCwdSync(self: *FrontendRuntime, uuid: [32]u8) ?[]const u8 {
        return self.client.getPaneCwdSync(uuid);
    }

    pub fn requestPaneProcess(self: *FrontendRuntime, uuid: [32]u8) void {
        self.client.requestPaneProcess(uuid);
    }

    pub fn getPaneName(self: *FrontendRuntime, uuid: [32]u8) ?[]u8 {
        return self.client.getPaneName(uuid);
    }

    pub fn getPaneInfoSnapshot(self: *FrontendRuntime, uuid: [32]u8) ?PaneInfoSnapshot {
        return self.client.getPaneInfoSnapshot(uuid);
    }

    pub fn updatePaneAux(
        self: *FrontendRuntime,
        uuid: [32]u8,
        active_tab: ?usize,
        is_floating: bool,
        is_focused: bool,
        pane_type: PaneType,
        created_from: ?[32]u8,
        focused_from: ?[32]u8,
        cursor: ?CursorPos,
        cursor_style: ?u8,
        cursor_visible: ?bool,
        alt_screen: ?bool,
        size: ?PaneSize,
        cwd: ?[]const u8,
        fg_process: ?[]const u8,
        fg_pid: ?posix.pid_t,
        layout_path: ?[]const u8,
    ) !void {
        try self.client.updatePaneAux(
            uuid,
            active_tab,
            is_floating,
            is_focused,
            pane_type,
            created_from,
            focused_from,
            if (cursor) |value| .{ .x = value.x, .y = value.y } else null,
            cursor_style,
            cursor_visible,
            alt_screen,
            if (size) |value| .{ .cols = value.cols, .rows = value.rows } else null,
            cwd,
            fg_process,
            fg_pid,
            layout_path,
        );
    }

    pub fn getPaneAux(self: *FrontendRuntime, uuid: [32]u8) !PaneAuxInfo {
        return try self.client.getPaneAux(uuid);
    }

    pub fn adoptPane(
        self: *FrontendRuntime,
        uuid: [32]u8,
    ) !PaneAttachResult {
        const result = try self.client.adoptPane(uuid);
        return .{
            .uuid = result.uuid,
            .pane_id = result.pane_id,
            .pid = result.pid,
        };
    }

    pub fn listOrphanedPanes(self: *FrontendRuntime, out_buf: []OrphanedPaneInfo) !usize {
        return try self.client.listOrphanedPanes(out_buf);
    }

    pub fn listSessions(self: *FrontendRuntime, out_buf: []DetachedSessionInfo) !usize {
        return try self.client.listSessions(out_buf);
    }

    pub fn reconcileResolvedName(self: *FrontendRuntime) !?frontend_attach.SessionNameChange {
        return frontend_attach.reconcileResolvedName(self.allocator, &self.client, &self.projection);
    }

    pub fn syncSessionIdentity(self: *FrontendRuntime) !?frontend_attach.SessionNameChange {
        return frontend_attach.syncSessionIdentity(self.allocator, &self.client, &self.projection);
    }

    pub fn completeReattach(self: *FrontendRuntime) !?frontend_attach.SessionNameChange {
        return frontend_attach.completeReattach(self.allocator, &self.client, &self.projection);
    }

    pub fn markSessionStolen(self: *FrontendRuntime) void {
        frontend_attach.markSessionStolen(&self.attach_state);
    }

    pub fn requestFrontendDisconnectStop(self: *FrontendRuntime) void {
        self.attach_state.requestFrontendDisconnectStop();
    }

    pub fn requestExplicitDetachStop(self: *FrontendRuntime) void {
        self.attach_state.requestExplicitDetachStop();
    }

    pub fn takeStopReason(self: *FrontendRuntime) ?StopReason {
        return self.attach_state.takeStopReason();
    }

    pub fn isDetachMode(self: *const FrontendRuntime) bool {
        return self.attach_state.detach_mode;
    }

    pub fn setDetachMode(self: *FrontendRuntime, enabled: bool) void {
        self.attach_state.setDetachMode(enabled);
    }

    pub fn nextStateVersion(self: *FrontendRuntime) u32 {
        return self.attach_state.nextStateVersion();
    }

    pub fn beginReattach(self: *FrontendRuntime) void {
        self.attach_state.beginReattach();
    }

    pub fn endReattach(self: *FrontendRuntime) void {
        self.attach_state.endReattach();
    }

    pub fn refreshOrphanedPanes(self: *FrontendRuntime) !usize {
        const count = try self.client.listOrphanedPanes(&self.attach_state.adopt_orphans);
        self.attach_state.adopt_orphan_count = count;
        if (count == 0) {
            self.attach_state.adopt_selected_uuid = null;
        } else if (self.attach_state.adopt_selected_uuid) |selected| {
            var found = false;
            for (self.attach_state.adopt_orphans[0..count]) |info| {
                if (std.mem.eql(u8, &info.uuid, &selected)) {
                    found = true;
                    break;
                }
            }
            if (!found) self.attach_state.adopt_selected_uuid = null;
        }
        return count;
    }

    pub fn orphanedPaneCount(self: *const FrontendRuntime) usize {
        return self.attach_state.adopt_orphan_count;
    }

    pub fn orphanedPaneInfo(self: *const FrontendRuntime, idx: usize) ?OrphanedPaneInfo {
        if (idx >= self.attach_state.adopt_orphan_count) return null;
        return self.attach_state.adopt_orphans[idx];
    }

    pub fn selectedOrphanedPaneUuid(self: *const FrontendRuntime) ?[32]u8 {
        return self.attach_state.adopt_selected_uuid;
    }

    pub fn setSelectedOrphanedPaneUuid(self: *FrontendRuntime, uuid: ?[32]u8) void {
        self.attach_state.adopt_selected_uuid = uuid;
    }

    pub fn parseSessionSnapshotJson(self: *FrontendRuntime, session_state_json: []const u8) !session_model.SessionSnapshot {
        return session_model.SessionSnapshot.fromJson(self.allocator, session_state_json);
    }

    pub fn attachedSnapshot(self: *const FrontendRuntime) ?*const session_model.SessionSnapshot {
        return self.projection.attachedSnapshot();
    }

    pub fn paneMeta(self: *const FrontendRuntime, uuid: [32]u8) ?session_model.SessionPane {
        return self.projection.paneMeta(uuid);
    }

    pub fn floatState(self: *const FrontendRuntime, uuid: [32]u8) ?session_model.SessionFloat {
        return self.projection.floatState(uuid);
    }

    pub fn syncFloatState(
        self: *FrontendRuntime,
        float_state: session_model.SessionFloat,
        active: bool,
    ) void {
        self.projection.syncFloatState(float_state, active);
    }

    pub fn setFloatVisibleOnTab(
        self: *FrontendRuntime,
        uuid: [32]u8,
        tab: usize,
        visible: bool,
    ) void {
        self.projection.setFloatVisibleOnTab(uuid, tab, visible);
    }

    pub fn toggleFloatVisibleOnTab(self: *FrontendRuntime, uuid: [32]u8, tab: usize) void {
        self.projection.toggleFloatVisibleOnTab(uuid, tab);
    }

    pub fn setFloatGeometry(
        self: *FrontendRuntime,
        uuid: [32]u8,
        width_pct: u8,
        height_pct: u8,
        pos_x_pct: u8,
        pos_y_pct: u8,
        pad_x: u8,
        pad_y: u8,
    ) void {
        self.projection.setFloatGeometry(uuid, width_pct, height_pct, pos_x_pct, pos_y_pct, pad_x, pad_y);
    }

    pub fn swapFloatGeometry(self: *FrontendRuntime, a_uuid: [32]u8, b_uuid: [32]u8) void {
        self.projection.swapFloatGeometry(a_uuid, b_uuid);
    }

    pub fn reindexFloatParentTabsAfterRemovedTab(self: *FrontendRuntime, removed_idx: usize) void {
        self.projection.reindexFloatParentTabsAfterRemovedTab(removed_idx);
    }

    pub fn normalizeFloatParentTabs(self: *FrontendRuntime, tab_count: usize) usize {
        return self.projection.normalizeFloatParentTabs(tab_count);
    }

    pub fn setPaneShell(
        self: *FrontendRuntime,
        uuid: [32]u8,
        cmd: ?[]const u8,
        cwd: ?[]const u8,
        status: ?i32,
        duration_ms: ?u64,
        jobs: ?u16,
    ) void {
        self.projection.setPaneShell(uuid, cmd, cwd, status, duration_ms, jobs);
    }

    pub fn setPaneShellRunning(
        self: *FrontendRuntime,
        uuid: [32]u8,
        running: bool,
        started_at_ms: ?u64,
        cmd: ?[]const u8,
        cwd: ?[]const u8,
        jobs: ?u16,
    ) void {
        self.projection.setPaneShellRunning(uuid, running, started_at_ms, cmd, cwd, jobs);
    }

    pub fn clearPaneShellStartedAt(self: *FrontendRuntime, uuid: [32]u8) void {
        self.projection.clearPaneShellStartedAt(uuid);
    }

    pub fn setPaneProc(self: *FrontendRuntime, uuid: [32]u8, name: ?[]const u8, pid: ?i32) void {
        self.projection.setPaneProc(uuid, name, pid);
    }

    pub fn getPaneShell(self: *const FrontendRuntime, uuid: [32]u8) ?@import("session_projection.zig").PaneShellInfo {
        return self.projection.getPaneShell(uuid);
    }

    pub fn getPaneProc(self: *const FrontendRuntime, uuid: [32]u8) ?@import("session_projection.zig").PaneProcInfo {
        return self.projection.getPaneProc(uuid);
    }

    pub fn setPaneNameOwned(self: *FrontendRuntime, uuid: [32]u8, name_owned: []u8) void {
        self.projection.setPaneNameOwned(uuid, name_owned);
    }

    pub fn paneName(self: *const FrontendRuntime, uuid: [32]u8) ?[]const u8 {
        return self.projection.paneName(uuid);
    }

    pub fn hasPaneName(self: *const FrontendRuntime, uuid: [32]u8) bool {
        return self.projection.hasPaneName(uuid);
    }

    pub fn removePaneProc(self: *FrontendRuntime, uuid: [32]u8) void {
        self.projection.removePaneProc(uuid);
    }

    pub fn removePaneName(self: *FrontendRuntime, uuid: [32]u8) void {
        self.projection.removePaneName(uuid);
    }

    pub fn applySessionStateJson(self: *FrontendRuntime, session_state_json: []const u8) bool {
        logging.debug("frontend-runtime", "applySessionStateJson: begin len={d}", .{session_state_json.len});
        var snapshot = self.parseSessionSnapshotJson(session_state_json) catch |err| {
            logging.debug("frontend-runtime", "applySessionStateJson: parse failed: {s}", .{@errorName(err)});
            return false;
        };
        defer snapshot.deinit();
        logging.debug(
            "frontend-runtime",
            "applySessionStateJson: parsed tabs={d} floats={d} active_tab={d} active_float={} focused={}",
            .{
                snapshot.tabs.items.len,
                snapshot.floats.items.len,
                snapshot.active_tab,
                snapshot.active_float_uuid != null,
                snapshot.focused_pane_uuid != null,
            },
        );
        self.replaceProjectionFromSnapshot(&snapshot, snapshot.tabs.items.len) catch |err| {
            logging.debug("frontend-runtime", "applySessionStateJson: replaceProjectionFromSnapshot failed: {s}", .{@errorName(err)});
            return false;
        };
        logging.debug("frontend-runtime", "applySessionStateJson: projection replaced", .{});
        return true;
    }

    pub fn applyPendingSessionSnapshot(self: *FrontendRuntime) bool {
        const session_json = self.client.drainPendingSessionState() orelse return false;
        defer self.allocator.free(session_json);
        return self.applySessionStateJson(session_json);
    }

    pub fn reattachSessionSnapshot(self: *FrontendRuntime, session_id_prefix: []const u8) !?ReattachSnapshotResult {
        const result = try self.client.reattachSession(session_id_prefix);
        if (result == null) return null;

        const reattach = result.?;
        errdefer self.allocator.free(reattach.pane_uuids);
        defer self.allocator.free(reattach.session_state_json);

        var snapshot = try self.parseSessionSnapshotJson(reattach.session_state_json);
        errdefer snapshot.deinit();

        return .{
            .snapshot = snapshot,
            .pane_uuids = reattach.pane_uuids,
            .allocator = self.allocator,
        };
    }

    pub fn reattachSessionProjection(self: *FrontendRuntime, session_id_prefix: []const u8) !?ReattachSnapshotResult {
        var result = try self.reattachSessionSnapshot(session_id_prefix) orelse return null;
        errdefer result.deinit();
        try self.replaceProjectionFromSnapshot(&result.snapshot, result.snapshot.tabs.items.len);
        return result;
    }

    pub fn replaceProjectionFromSnapshot(
        self: *FrontendRuntime,
        snapshot: *const session_model.SessionSnapshot,
        live_tab_count: usize,
    ) !void {
        logging.debug(
            "frontend-runtime",
            "replaceProjectionFromSnapshot: tabs={d} floats={d} active_tab={d} active_float={} focused={}",
            .{
                snapshot.tabs.items.len,
                snapshot.floats.items.len,
                snapshot.active_tab,
                snapshot.active_float_uuid != null,
                snapshot.focused_pane_uuid != null,
            },
        );
        try self.projection.replaceAttachedSnapshotOwned(try snapshot.clone(self.allocator));
        logging.debug("frontend-runtime", "replaceProjectionFromSnapshot: attached snapshot replaced", .{});
        self.client.session_id = self.projection.sessionUuid();
        self.client.session_name = self.projection.sessionName();
        self.projection.setActiveTab(self.projection.activeTab(live_tab_count));
        logging.debug("frontend-runtime", "replaceProjectionFromSnapshot: active tab normalized", .{});
    }

    pub fn clearTabMeta(self: *FrontendRuntime) void {
        self.projection.clearTabMeta();
    }

    pub fn appendTabMeta(self: *FrontendRuntime, uuid: [32]u8, name: []const u8) bool {
        self.projection.appendTab(uuid, name) catch return false;
        return true;
    }

    pub fn removeTabMeta(self: *FrontendRuntime, idx: usize) void {
        self.projection.removeTab(idx);
    }

    pub fn tabUuid(self: *const FrontendRuntime, idx: usize) ?[32]u8 {
        return self.projection.tabUuid(idx);
    }

    pub fn tabName(self: *const FrontendRuntime, idx: usize) ?[]const u8 {
        return self.projection.tabName(idx);
    }

    pub fn setTabCounter(self: *FrontendRuntime, tab_counter: usize) void {
        self.projection.setTabCounter(tab_counter);
    }

    pub fn takeNextTabCounter(self: *FrontendRuntime) usize {
        return self.projection.takeNextTabCounter();
    }

    pub fn resetTabFocusMemory(self: *FrontendRuntime, tab_count: usize) bool {
        self.projection.resetTabFocusMemory(tab_count) catch return false;
        return true;
    }

    pub fn clearTabFocusMemory(self: *FrontendRuntime) void {
        self.projection.clearTabFocusMemory();
    }

    pub fn appendTabFocusMemory(self: *FrontendRuntime) bool {
        self.projection.appendTabFocusMemory() catch return false;
        return true;
    }

    pub fn removeTabFocusMemory(self: *FrontendRuntime, idx: usize) void {
        self.projection.removeTabFocusMemory(idx);
    }

    pub fn lastFocusKind(self: *const FrontendRuntime, idx: usize) ?TabFocusKind {
        return self.projection.lastFocusKind(idx);
    }

    pub fn lastFloatingUuid(self: *const FrontendRuntime, idx: usize) ?[32]u8 {
        return self.projection.lastFloatingUuid(idx);
    }

    pub fn sessionAddTab(
        self: *FrontendRuntime,
        tab_uuid: [32]u8,
        pane_uuid: [32]u8,
        tab_index: usize,
        name: []const u8,
    ) !void {
        try self.client.sessionAddTab(tab_uuid, pane_uuid, tab_index, name);
    }

    pub fn sessionRemoveTab(self: *FrontendRuntime, tab_uuid: [32]u8, active_tab: ?usize) !void {
        try self.client.sessionRemoveTab(tab_uuid, active_tab);
    }

    pub fn sessionSyncFloat(
        self: *FrontendRuntime,
        pane_uuid: [32]u8,
        active_tab: ?usize,
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
    ) !void {
        try self.client.sessionSyncFloat(
            pane_uuid,
            active_tab,
            parent_tab,
            visible,
            tab_visible,
            sticky,
            is_pwd,
            float_key,
            width_pct,
            height_pct,
            pos_x_pct,
            pos_y_pct,
            pad_x,
            pad_y,
            active,
        );
        self.projection.syncFloatState(.{
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

    pub fn sessionRemoveFloat(self: *FrontendRuntime, pane_uuid: [32]u8) !void {
        try self.client.sessionRemoveFloat(pane_uuid);
        self.projection.removeFloatState(pane_uuid);
    }

    pub fn sessionSplitPane(
        self: *FrontendRuntime,
        tab_uuid: [32]u8,
        source_pane_uuid: [32]u8,
        new_pane_uuid: [32]u8,
        active_tab: usize,
        focused_pane_uuid: ?[32]u8,
        dir: session_model.SessionSplitDir,
    ) !void {
        try self.client.sessionSplitPane(
            tab_uuid,
            source_pane_uuid,
            new_pane_uuid,
            active_tab,
            focused_pane_uuid,
            dir,
        );
    }

    pub fn sessionCloseSplitPane(
        self: *FrontendRuntime,
        tab_uuid: [32]u8,
        pane_uuid: [32]u8,
        active_tab: usize,
        focused_pane_uuid: ?[32]u8,
    ) !void {
        try self.client.sessionCloseSplitPane(
            tab_uuid,
            pane_uuid,
            active_tab,
            focused_pane_uuid,
        );
    }

    pub fn sessionReplaceSplitPane(
        self: *FrontendRuntime,
        tab_uuid: [32]u8,
        old_pane_uuid: [32]u8,
        new_pane_uuid: [32]u8,
        active_tab: usize,
        focused_pane_uuid: ?[32]u8,
    ) !void {
        try self.client.sessionReplaceSplitPane(
            tab_uuid,
            old_pane_uuid,
            new_pane_uuid,
            active_tab,
            focused_pane_uuid,
        );
    }

    pub fn sessionSetSplitRatio(
        self: *FrontendRuntime,
        tab_uuid: [32]u8,
        active_tab: usize,
        first_anchor_uuid: [32]u8,
        second_anchor_uuid: [32]u8,
        ratio: f32,
    ) !void {
        try self.client.sessionSetSplitRatio(
            tab_uuid,
            active_tab,
            first_anchor_uuid,
            second_anchor_uuid,
            ratio,
        );
    }
};
