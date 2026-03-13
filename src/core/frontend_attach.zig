const std = @import("std");
const FrontendAttachState = @import("frontend_attach_state.zig").FrontendAttachState;
const FrontendClient = @import("frontend_client.zig").SesClient;
const SessionProjection = @import("session_projection.zig").SessionProjection;

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
    projection: *SessionProjection,
) !?SessionNameChange {
    const resolved_name = client.takeResolvedNameOwned() orelse return null;
    errdefer allocator.free(resolved_name);

    if (std.mem.eql(u8, resolved_name, projection.sessionName())) {
        allocator.free(resolved_name);
        client.session_id = projection.sessionUuid();
        client.session_name = projection.sessionName();
        return null;
    }

    const previous_name = try allocator.dupe(u8, projection.sessionName());
    errdefer allocator.free(previous_name);

    try projection.setSessionIdentity(projection.sessionUuid(), resolved_name);
    client.session_id = projection.sessionUuid();
    client.session_name = projection.sessionName();

    return .{
        .previous_name = previous_name,
        .resolved_name = resolved_name,
    };
}

pub fn syncSessionIdentity(
    allocator: std.mem.Allocator,
    client: *FrontendClient,
    projection: *SessionProjection,
) !?SessionNameChange {
    try client.updateSession(projection.sessionUuid(), projection.sessionName());
    return try reconcileResolvedName(allocator, client, projection);
}

pub fn completeReattach(
    allocator: std.mem.Allocator,
    client: *FrontendClient,
    projection: *SessionProjection,
) !?SessionNameChange {
    const change = try syncSessionIdentity(allocator, client, projection);
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
