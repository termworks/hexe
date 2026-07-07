const std = @import("std");
const core = @import("core");
const frontend_core = @import("frontend_core");

const State = @import("state.zig").State;
const HostHooks = @import("loop_host_hooks.zig").HostHooks;

pub fn applyDeferredPaneExits(state: *State) void {
    var pending: std.ArrayList([32]u8) = .empty;
    defer pending.deinit(state.allocator);
    state.runtime.drainPendingPaneExits(&pending);
    if (pending.items.len == 0) return;

    for (pending.items) |uuid| {
        state.applyFrontendPaneExited(uuid);
        if (state.findPaneByUuid(uuid)) |pane| {
            pane.backend.pod.dead = true;
            state.needs_render = true;
        }
    }
}

pub fn applyDeferredCwdResponse(state: *State) void {
    while (state.runtime.drainPendingCwdResponse()) |resp| {
        defer state.allocator.free(resp.cwd);
        state.applyFrontendPaneCwd(resp.uuid, resp.cwd);
        state.setPaneShell(resp.uuid, null, resp.cwd, null, null, null);
    }
}

pub fn applyDeferredPaneInfoResponse(state: *State) void {
    while (state.runtime.drainPendingPaneInfoResponse()) |pending| {
        var resp = pending;
        defer resp.deinit(state.allocator);
        state.applyFrontendPaneInfo(resp.uuid, resp.name, resp.fg_name, resp.fg_pid);
        if (resp.name) |name| {
            const name_owned = state.allocator.dupe(u8, name) catch |err| {
                core.logging.logError("terminal", "failed to allocate deferred pane name", err);
                return;
            };
            state.setPaneNameOwned(resp.uuid, name_owned);
        }
        if (resp.fg_name != null or resp.fg_pid != null) {
            state.setPaneProc(resp.uuid, resp.fg_name, resp.fg_pid);
        }
    }
}

pub fn applyDeferredSessionSnapshots(state: *State) void {
    if (!state.runtime.applyPendingSessionSnapshot()) return;
    _ = state.applySessionSnapshot();
}

/// Apply a session_stolen push that a synchronous reader consumed on behalf
/// of the IPC loop — losing it would leave this mux writing into a session
/// another client now owns.
pub fn applyDeferredSessionStolen(state: *State) void {
    _ = state.runtime.applyPendingSessionStolen();
}

pub fn applyRuntimeStopRequest(state: *State, hooks: HostHooks) bool {
    const reason = state.runtime.takeStopReason() orelse return false;
    if (frontend_core.stopRequestFromRuntime(reason)) |request| {
        hooks.handleStopRequest(state, request);
    }
    state.running = false;
    state.needs_render = true;
    return true;
}
