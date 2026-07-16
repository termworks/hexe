const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ses = @import("main.zig");
const client_panes = @import("client_panes.zig");
const detach_lifecycle = @import("detach_lifecycle.zig");
const store_mod = @import("store.zig");

pub fn addClient(self: anytype, fd: posix.fd_t) !usize {
    const id = self.store.next_client_id;
    self.store.next_client_id += 1;

    try self.store.clients.append(self.allocator, store_mod.Client.init(self.allocator, id, fd));
    return id;
}

pub fn getClient(self: anytype, client_id: usize) ?*store_mod.Client {
    for (self.store.clients.items) |*client| {
        if (client.id == client_id) return client;
    }
    return null;
}

fn closeClientMuxFds(store: *store_mod.SessionStore, client: *store_mod.Client) void {
    store_mod.closeClientFds(store, client);
}

fn killCollectedPanes(self: anytype, pane_uuids: []const [32]u8, comptime context: []const u8) void {
    for (pane_uuids) |uuid| {
        // Sticky/per-CWD panes promise to survive frontend death: park them
        // instead of killing them, on every client-removal path. Killing them
        // here (e.g. probe clients or crashed frontends) permanently destroys
        // floats the user expects to reclaim by key+directory.
        if (self.store.panes.getPtr(uuid)) |pane| {
            if (pane.sticky_pwd != null and pane.sticky_key != null) {
                _ = pane.transitionState(.sticky, "client removed; sticky pane preserved");
                pane.attached_to = null;
                // Preserved sticky panes are free: clear the session marker so
                // later claims are not mistaken for cross-session theft.
                pane.session_id = null;
                pane.orphaned_at = std.time.timestamp();
                self.store.dirty = true;
                continue;
            }
        }
        self.killPane(uuid) catch |err| {
            core.logging.logError("ses", context, err);
        };
    }
}

pub fn removeClient(self: anytype, client_id: usize) void {
    ses.debugLog("removeClient: client_id={d}", .{client_id});

    var client_index: ?usize = null;
    for (self.store.clients.items, 0..) |*client, i| {
        if (client.id == client_id) {
            ses.debugLog("removeClient: found client keepalive={} has_session_id={} pane_count={d}", .{
                client.keepalive,
                client.session_id != null,
                client.pane_uuids.items.len,
            });

            if (client.keepalive) {
                if (client.pending_reattach_session_id) |session_id| {
                    // The frontend disappeared mid-reattach. The canonical
                    // detached session has not been committed/removed yet, so
                    // restore any already-adopted panes back into that detached
                    // session instead of auto-detaching under the temporary
                    // startup session id.
                    if (!detach_lifecycle.cancelPendingReattach(self, session_id, client.id)) {
                        ses.debugLog("removeClient: pending reattach restore failed, leaving existing detached session untouched", .{});
                    }
                } else if (client.session_id != null and client.pane_uuids.items.len == 0) {
                    // A pane-less session has nothing worth parking. Every
                    // aborted attach (crashed racer, Ctrl-C'd startup) used
                    // to leave a permanent empty detached record rooted at
                    // its cwd — accumulating phantom targets that forced
                    // `attach .` into the ambiguity picker.
                    ses.debugLog("removeClient: empty session, not parking", .{});
                } else if (client.session_id) |session_id| {
                    // Use direct detach to avoid removing the client twice.
                    // If preserving fails, kill panes rather than leaving them
                    // owned by a client that is about to be removed.
                    if (!detach_lifecycle.detachSessionDirect(self, client, session_id)) {
                        ses.debugLog("removeClient: auto-detach failed, killing panes", .{});
                        var pane_uuids_list: std.ArrayList([32]u8) = .empty;
                        defer pane_uuids_list.deinit(self.allocator);
                        client_panes.collectDetachPaneUuidsWithFallback(
                            self.allocator,
                            &self.store,
                            client,
                            &pane_uuids_list,
                            "failed to collect pane for failed auto-detach fallback",
                        );
                        killCollectedPanes(self, pane_uuids_list.items, "killPane failed after auto-detach failure");
                    }
                } else {
                    ses.debugLog("removeClient: no session_id, killing panes", .{});
                    var pane_uuids_list: std.ArrayList([32]u8) = .empty;
                    defer pane_uuids_list.deinit(self.allocator);
                    client_panes.collectDetachPaneUuidsWithFallback(
                        self.allocator,
                        &self.store,
                        client,
                        &pane_uuids_list,
                        "failed to collect pane for removeClient fallback",
                    );
                    killCollectedPanes(self, pane_uuids_list.items, "killPane failed in removeClient");
                }
            } else {
                ses.debugLog("removeClient: keepalive=false, killing panes", .{});
                var pane_uuids_list: std.ArrayList([32]u8) = .empty;
                defer pane_uuids_list.deinit(self.allocator);
                client_panes.collectDetachPaneUuidsWithFallback(
                    self.allocator,
                    &self.store,
                    client,
                    &pane_uuids_list,
                    "failed to collect pane for removeClient fallback",
                );
                killCollectedPanes(self, pane_uuids_list.items, "killPane failed in removeClient");
            }

            closeClientMuxFds(&self.store, client);
            self.releaseClientLocks(client.id);
            client.deinit();
            client_index = i;
            break;
        }
    }

    if (client_index) |idx| {
        _ = self.store.clients.orderedRemove(idx);
    } else {
        ses.debugLog("removeClient: client_id={d} not found", .{client_id});
    }
}

pub fn removeClientGraceful(self: anytype, client_id: usize) void {
    var client_index: ?usize = null;
    for (self.store.clients.items, 0..) |*client, i| {
        if (client.id == client_id) {
            closeClientMuxFds(&self.store, client);
            self.releaseClientLocks(client.id);
            client.deinit();
            client_index = i;
            break;
        }
    }

    if (client_index) |idx| {
        _ = self.store.clients.orderedRemove(idx);
    }
}

pub fn shutdownClient(self: anytype, client_id: usize, preserve_sticky: bool) void {
    var client_index: ?usize = null;
    for (self.store.clients.items, 0..) |*client, i| {
        if (client.id == client_id) {
            var pane_uuids_list: std.ArrayList([32]u8) = .empty;
            defer pane_uuids_list.deinit(self.allocator);
            client_panes.collectDetachPaneUuidsWithFallback(
                self.allocator,
                &self.store,
                client,
                &pane_uuids_list,
                "failed to collect pane for shutdownClient fallback",
            );

            for (pane_uuids_list.items) |uuid| {
                if (preserve_sticky) {
                    if (self.store.panes.getPtr(uuid)) |pane| {
                        if (pane.sticky_pwd != null and pane.sticky_key != null) {
                            _ = pane.transitionState(.sticky, "mux shutdown with sticky pwd");
                            pane.attached_to = null;
                            // Preserved sticky panes are free, not parked.
                            pane.session_id = null;
                            continue;
                        }
                    }
                }
                self.killPane(uuid) catch |err| {
                    core.logging.logError("ses", "killPane failed in shutdownClient", err);
                };
            }

            closeClientMuxFds(&self.store, client);
            self.releaseClientLocks(client.id);
            client.deinit();
            client_index = i;
            break;
        }
    }

    if (client_index) |idx| {
        _ = self.store.clients.orderedRemove(idx);
    }
    self.store.dirty = true;
}
