const std = @import("std");
const frontend_client = @import("frontend_client.zig");

pub const FrontendAttachState = struct {
    pub const StopReason = enum(u8) {
        none = 0,
        frontend_disconnect = 1,
        session_stolen = 2,
        explicit_detach = 3,
    };

    detach_mode: bool = false,
    reattach_in_progress: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop_reason: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(StopReason.none)),
    adopt_orphans: [32]frontend_client.OrphanedPaneInfo = undefined,
    adopt_orphan_count: usize = 0,
    adopt_selected_uuid: ?[32]u8 = null,
    state_version: u32 = 0,

    pub fn beginReattach(self: *FrontendAttachState) void {
        self.reattach_in_progress.store(true, .release);
    }

    pub fn endReattach(self: *FrontendAttachState) void {
        self.reattach_in_progress.store(false, .release);
    }

    pub fn setDetachMode(self: *FrontendAttachState, enabled: bool) void {
        self.detach_mode = enabled;
    }

    fn clearTransientAttachState(self: *FrontendAttachState) void {
        self.endReattach();
        self.adopt_orphan_count = 0;
        self.adopt_selected_uuid = null;
    }

    pub fn requestStop(self: *FrontendAttachState, reason: StopReason, detach: bool) void {
        if (detach) self.detach_mode = true;
        self.clearTransientAttachState();
        self.stop_reason.store(@intFromEnum(reason), .release);
        self.stop_requested.store(true, .release);
    }

    pub fn requestFrontendDisconnectStop(self: *FrontendAttachState) void {
        self.requestStop(.frontend_disconnect, true);
    }

    pub fn requestExplicitDetachStop(self: *FrontendAttachState) void {
        self.requestStop(.explicit_detach, true);
    }

    pub fn markSessionStolen(self: *FrontendAttachState) void {
        self.requestStop(.session_stolen, true);
    }

    pub fn takeStopReason(self: *FrontendAttachState) ?StopReason {
        if (!self.stop_requested.swap(false, .acq_rel)) return null;
        const raw = self.stop_reason.swap(@intFromEnum(StopReason.none), .acq_rel);
        const reason: StopReason = @enumFromInt(raw);
        return if (reason == .none) null else reason;
    }

    pub fn nextStateVersion(self: *FrontendAttachState) u32 {
        self.state_version +%= 1;
        return self.state_version;
    }
};
