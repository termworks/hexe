const std = @import("std");
const frontend_attach = @import("frontend_attach.zig");
const FrontendAttachState = @import("frontend_attach_state.zig").FrontendAttachState;
const FrontendClient = @import("frontend_client.zig").SesClient;
const Transport = @import("frontend_client.zig").Transport;
const session_model = @import("session_model.zig");
const SessionProjection = @import("session_projection.zig").SessionProjection;
const wire = @import("wire.zig");

pub const FrontendRuntime = struct {
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
};
