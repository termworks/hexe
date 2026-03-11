const std = @import("std");
const FrontendAttachState = @import("frontend_attach_state.zig").FrontendAttachState;
const FrontendClient = @import("frontend_client.zig").SesClient;
const FrontendSessionCache = @import("frontend_session_cache.zig").FrontendSessionCache;

pub const SessionNameChange = struct {
    previous_name: []u8,
    resolved_name: []u8,

    pub fn deinit(self: *SessionNameChange, allocator: std.mem.Allocator) void {
        allocator.free(self.previous_name);
        allocator.free(self.resolved_name);
        self.* = undefined;
    }
};

pub fn reconcileResolvedName(
    allocator: std.mem.Allocator,
    client: *FrontendClient,
    cache: *FrontendSessionCache,
) !?SessionNameChange {
    const resolved_name = client.takeResolvedNameOwned() orelse return null;
    errdefer allocator.free(resolved_name);

    if (std.mem.eql(u8, resolved_name, cache.sessionName())) {
        allocator.free(resolved_name);
        client.session_id = cache.sessionUuid();
        client.session_name = cache.sessionName();
        return null;
    }

    const previous_name = try allocator.dupe(u8, cache.sessionName());
    errdefer allocator.free(previous_name);

    try cache.setSessionIdentity(cache.sessionUuid(), resolved_name);
    client.session_id = cache.sessionUuid();
    client.session_name = cache.sessionName();

    return .{
        .previous_name = previous_name,
        .resolved_name = resolved_name,
    };
}

pub fn syncSessionIdentity(
    allocator: std.mem.Allocator,
    client: *FrontendClient,
    cache: *FrontendSessionCache,
) !?SessionNameChange {
    try client.updateSession(cache.sessionUuid(), cache.sessionName());
    return try reconcileResolvedName(allocator, client, cache);
}

pub fn completeReattach(
    allocator: std.mem.Allocator,
    client: *FrontendClient,
    cache: *FrontendSessionCache,
) !?SessionNameChange {
    const change = try syncSessionIdentity(allocator, client, cache);
    errdefer if (change) |value| {
        var owned_value = value;
        owned_value.deinit(allocator);
    };
    try client.requestBacklogReplay();
    return change;
}

pub fn markSessionStolen(attach_state: *FrontendAttachState) void {
    attach_state.markSessionStolen();
}
