const std = @import("std");
const posix = std.posix;
const frontend_attach = @import("frontend_attach.zig");
const FrontendAttachState = @import("frontend_attach_state.zig").FrontendAttachState;
const FrontendClient = @import("frontend_client.zig").SesClient;
const OrphanedPaneInfo = @import("frontend_client.zig").OrphanedPaneInfo;
const Transport = @import("frontend_client.zig").Transport;
const session_model = @import("session_model.zig");
const SessionProjection = @import("session_projection.zig").SessionProjection;
const wire = @import("wire.zig");

pub const FrontendRuntime = struct {
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
        transport: Transport,
    ) !*FrontendRuntime {
        return create(
            allocator,
            session_id,
            session_name,
            true,
            debug,
            log_file,
            .terminal,
            transport,
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

    pub fn isConnected(self: *const FrontendRuntime) bool {
        return self.client.ctl_fd != null;
    }

    pub fn justStartedDaemon(self: *const FrontendRuntime) bool {
        return self.client.just_started_daemon;
    }

    pub fn getVtFd(self: *FrontendRuntime) ?posix.fd_t {
        return self.client.getVtFd();
    }

    pub fn shutdown(self: *FrontendRuntime, preserve_sticky: bool) !void {
        try self.client.shutdown(preserve_sticky);
    }

    pub fn detachSession(self: *FrontendRuntime, session_id: [32]u8) !void {
        try self.client.detachSession(session_id);
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

    pub fn beginReattach(self: *FrontendRuntime) void {
        self.attach_state.beginReattach();
    }

    pub fn endReattach(self: *FrontendRuntime) void {
        self.attach_state.endReattach();
    }

    pub fn parseSessionSnapshotJson(self: *FrontendRuntime, session_state_json: []const u8) !session_model.SessionSnapshot {
        return session_model.SessionSnapshot.fromJson(self.allocator, session_state_json);
    }

    pub fn drainPendingSessionSnapshot(self: *FrontendRuntime) ?session_model.SessionSnapshot {
        const session_json = self.client.drainPendingSessionState() orelse return null;
        defer self.allocator.free(session_json);
        return self.parseSessionSnapshotJson(session_json) catch null;
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

    pub fn replaceProjectionFromSnapshot(
        self: *FrontendRuntime,
        snapshot: *const session_model.SessionSnapshot,
        live_tab_count: usize,
    ) !void {
        try self.projection.replaceAttachedSnapshotOwned(try snapshot.clone(self.allocator));
        self.client.session_id = self.projection.sessionUuid();
        self.client.session_name = self.projection.sessionName();
        self.projection.setActiveTab(self.projection.activeTab(live_tab_count));
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
    }

    pub fn sessionRemoveFloat(self: *FrontendRuntime, pane_uuid: [32]u8) !void {
        try self.client.sessionRemoveFloat(pane_uuid);
    }

    pub fn sessionSyncTabLayout(
        self: *FrontendRuntime,
        tab_uuid: [32]u8,
        active_tab: usize,
        focused_pane_uuid: ?[32]u8,
        root_json: []const u8,
    ) !void {
        try self.client.sessionSyncTabLayout(tab_uuid, active_tab, focused_pane_uuid, root_json);
    }
};
