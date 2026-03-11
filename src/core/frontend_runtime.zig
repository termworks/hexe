const std = @import("std");
const frontend_attach = @import("frontend_attach.zig");
const FrontendAttachState = @import("frontend_attach_state.zig").FrontendAttachState;
const FrontendClient = @import("frontend_client.zig").SesClient;
const Transport = @import("frontend_client.zig").Transport;
const FrontendSessionCache = @import("frontend_session_cache.zig").FrontendSessionCache;
const wire = @import("wire.zig");

pub const FrontendRuntime = struct {
    allocator: std.mem.Allocator,
    client: FrontendClient,
    session_cache: FrontendSessionCache,
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

        runtime.session_cache = try FrontendSessionCache.init(allocator, session_id, session_name);
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
        self.session_cache.deinit();
        self.client.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn reconcileResolvedName(self: *FrontendRuntime) !?frontend_attach.SessionNameChange {
        return frontend_attach.reconcileResolvedName(self.allocator, &self.client, &self.session_cache);
    }

    pub fn syncSessionIdentity(self: *FrontendRuntime) !?frontend_attach.SessionNameChange {
        return frontend_attach.syncSessionIdentity(self.allocator, &self.client, &self.session_cache);
    }

    pub fn completeReattach(self: *FrontendRuntime) !?frontend_attach.SessionNameChange {
        return frontend_attach.completeReattach(self.allocator, &self.client, &self.session_cache);
    }

    pub fn markSessionStolen(self: *FrontendRuntime) void {
        frontend_attach.markSessionStolen(&self.attach_state);
    }
};
