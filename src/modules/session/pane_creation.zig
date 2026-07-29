const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const ses = @import("main.zig");
const pane_spawn = @import("pane_spawn.zig");
const store_mod = @import("store.zig");
const sticky_panes = @import("sticky_panes.zig");

fn killPaneLogged(self: anytype, pane_uuid: [32]u8, comptime context: []const u8) void {
    self.killPane(pane_uuid) catch |err| {
        core.logging.logError("ses", context, err);
    };
}

/// Everything `createPane` does BEFORE the pod's handshake is known.
///
/// Returned to the caller so the wait can happen off the event loop
/// (PLAN.md 1.1). The returned value OWNS `name`, `pod_socket_path`,
/// `sticky_pwd` and the forked pod: exactly one of `finishCreatePane` or
/// `abortCreatePane` must be called on it.
pub const InFlightPane = struct {
    client_id: usize,
    uuid: [32]u8,
    name: []const u8,
    pod_socket_path: []const u8,
    sticky_pwd: ?[]const u8,
    sticky_key: ?u8,
    spawn: pane_spawn.PendingPodSpawn,
};

pub fn beginCreatePane(
    self: anytype,
    client_id: usize,
    shell: []const u8,
    cwd: ?[]const u8,
    sticky_pwd: ?[]const u8,
    sticky_key: ?u8,
    env: ?[]const []const u8,
    isolation_profile: ?[]const u8,
) !InFlightPane {
    _ = self.getClient(client_id) orelse return error.ClientNotFound;

    const uuid = ipc.generateUuid();
    const base_name = ipc.generatePaneName();
    const name = try pane_spawn.generateUniquePaneName(self.allocator, &self.store, base_name);
    errdefer self.allocator.free(name);
    const pod_socket_path = try ipc.getPodSocketPath(self.allocator, &uuid);
    errdefer self.allocator.free(pod_socket_path);

    const owned_pwd: ?[]const u8 = if (sticky_pwd) |pwd| try self.allocator.dupe(u8, pwd) else null;
    errdefer if (owned_pwd) |pwd| self.allocator.free(pwd);

    const spawn = try pane_spawn.startPodSpawn(self.allocator, uuid, name, pod_socket_path, shell, cwd, env, isolation_profile);

    return .{
        .client_id = client_id,
        .uuid = uuid,
        .name = name,
        .pod_socket_path = pod_socket_path,
        .sticky_pwd = owned_pwd,
        .sticky_key = sticky_key,
        .spawn = spawn,
    };
}

/// Insert the pane now that the pod has reported its shell pid. Consumes
/// `flight` either way — on failure it reaps the pod and frees the strings.
pub fn finishCreatePane(self: anytype, flight: *InFlightPane, child_pid: std.posix.pid_t) !*store_mod.Pane {
    flight.spawn.deinit();

    var pane_inserted = false;
    // Same hazard as the synchronous path: a forked pod with no store record is
    // an orphan holding a pty, a shell and a socket that no sweep can find.
    errdefer if (!pane_inserted) {
        if (sticky_panes.podPidMatchesPane(flight.spawn.pod_pid, flight.uuid)) {
            _ = std.c.kill(flight.spawn.pod_pid, std.c.SIG.TERM);
        }
        self.allocator.free(flight.name);
        self.allocator.free(flight.pod_socket_path);
        if (flight.sticky_pwd) |pwd| self.allocator.free(pwd);
    };

    const pane = store_mod.Pane{
        .uuid = flight.uuid,
        .name = flight.name,
        .pod_pid = flight.spawn.pod_pid,
        .pod_socket_path = flight.pod_socket_path,
        .child_pid = child_pid,
        .state = .attached,
        .sticky_pwd = flight.sticky_pwd,
        .sticky_key = flight.sticky_key,
        .attached_to = flight.client_id,
        .session_id = null,
        .created_at = std.time.timestamp(),
        .orphaned_at = null,
        .pane_id = self.allocPaneId(),
        .allocator = self.allocator,
    };

    try self.store.panes.put(flight.uuid, pane);
    pane_inserted = true;
    self.store.dirty = true;

    if (!self.connectPodVt(flight.uuid, flight.pod_socket_path, pane.pane_id)) {
        killPaneLogged(self, flight.uuid, "killPane failed after POD VT attach failure");
        return error.PodVtAttachFailed;
    }

    if (self.getClient(flight.client_id)) |client| {
        client.appendUuid(flight.uuid) catch |err| {
            killPaneLogged(self, flight.uuid, "killPane failed after client pane-list append failure");
            return err;
        };
    } else {
        killPaneLogged(self, flight.uuid, "killPane failed after createPane client disappeared");
        return error.ClientNotFound;
    }

    return self.store.panes.getPtr(flight.uuid).?;
}

/// Give up on an in-flight pane: reap the forked pod and free what it owns.
pub fn abortCreatePane(self: anytype, flight: *InFlightPane) void {
    flight.spawn.deinit();
    if (sticky_panes.podPidMatchesPane(flight.spawn.pod_pid, flight.uuid)) {
        ses.debugLog("abortCreatePane: reaping pod pid={d}", .{flight.spawn.pod_pid});
        _ = std.c.kill(flight.spawn.pod_pid, std.c.SIG.TERM);
    }
    self.allocator.free(flight.name);
    self.allocator.free(flight.pod_socket_path);
    if (flight.sticky_pwd) |pwd| self.allocator.free(pwd);
}

pub fn createPane(
    self: anytype,
    client_id: usize,
    shell: []const u8,
    cwd: ?[]const u8,
    sticky_pwd: ?[]const u8,
    sticky_key: ?u8,
    env: ?[]const []const u8,
    isolation_profile: ?[]const u8,
) !*store_mod.Pane {
    _ = self.getClient(client_id) orelse return error.ClientNotFound;

    var pane_inserted = false;
    const uuid = ipc.generateUuid();
    const base_name = ipc.generatePaneName();
    const name = try pane_spawn.generateUniquePaneName(self.allocator, &self.store, base_name);
    ses.debugLog("createPane: generated name='{s}'", .{name});
    errdefer if (!pane_inserted) self.allocator.free(name);
    const pod_socket_path = try ipc.getPodSocketPath(self.allocator, &uuid);
    errdefer if (!pane_inserted) self.allocator.free(pod_socket_path);

    const spawn = try pane_spawn.spawnPod(self.allocator, uuid, name, pod_socket_path, shell, cwd, env, isolation_profile);
    // spawnPod forked a real `hexe pod daemon`. If anything below fails before
    // the pane is in the store, that process is orphaned: it keeps its pty, its
    // shell child and its socket forever, with no record for any sweep to find.
    // The later failures already route through killPaneLogged; these earlier
    // ones (the sticky-pwd dupe, the panes.put) had nothing at all.
    errdefer if (!pane_inserted) {
        if (sticky_panes.podPidMatchesPane(spawn.pod_pid, uuid)) {
            ses.debugLog("createPane: reaping orphaned pod pid={d} after failed insert", .{spawn.pod_pid});
            _ = std.c.kill(spawn.pod_pid, std.c.SIG.TERM);
        }
    };

    const owned_pwd: ?[]const u8 = if (sticky_pwd) |pwd|
        try self.allocator.dupe(u8, pwd)
    else
        null;
    errdefer if (!pane_inserted) {
        if (owned_pwd) |pwd| self.allocator.free(pwd);
    };

    const now = std.time.timestamp();
    const pane_id = self.allocPaneId();

    const pane = store_mod.Pane{
        .uuid = uuid,
        .name = name,
        .pod_pid = spawn.pod_pid,
        .pod_socket_path = pod_socket_path,
        .child_pid = spawn.child_pid,
        .state = .attached,
        .sticky_pwd = owned_pwd,
        .sticky_key = sticky_key,
        .attached_to = client_id,
        .session_id = null,
        .created_at = now,
        .orphaned_at = null,
        .pane_id = pane_id,
        .allocator = self.allocator,
    };

    try self.store.panes.put(uuid, pane);
    pane_inserted = true;
    self.store.dirty = true;

    if (!self.connectPodVt(uuid, pod_socket_path, pane_id)) {
        killPaneLogged(self, uuid, "killPane failed after POD VT attach failure");
        return error.PodVtAttachFailed;
    }

    if (self.getClient(client_id)) |client| {
        client.appendUuid(uuid) catch |err| {
            killPaneLogged(self, uuid, "killPane failed after client pane-list append failure");
            return err;
        };
    } else {
        killPaneLogged(self, uuid, "killPane failed after createPane client disappeared");
        return error.ClientNotFound;
    }

    return self.store.panes.getPtr(uuid).?;
}
