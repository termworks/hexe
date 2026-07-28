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
