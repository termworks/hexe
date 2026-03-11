const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ipc = core.ipc;
const wire = core.wire;
const state = @import("state.zig");
const ses = @import("main.zig");
const xev = @import("xev").Dynamic;

// Keep VT routing I/O short to avoid blocking the whole SES event loop when a
// peer dies mid-frame on stream sockets.
const VT_ROUTE_IO_TIMEOUT_MS: i32 = 2000;

/// Maximum number of concurrent client connections (MUX instances).
const MAX_CLIENTS: usize = core.constants.Limits.max_clients;

const CtlWatcher = struct {
    srv: *anyopaque,
    fd: posix.fd_t,
    completion: xev.Completion = .{},
};

const PendingCtlClose = struct {
    fd: posix.fd_t,
    watcher: ?*CtlWatcher,
};

const VtDirection = enum {
    pod_to_mux,
    mux_to_pod,
};

const VtWatcher = struct {
    srv: *anyopaque,
    fd: posix.fd_t,
    direction: VtDirection,
    completion: xev.Completion = .{},
};

const PendingVtClose = struct {
    fd: posix.fd_t,
    watcher: ?*VtWatcher,
};

/// Server that handles mux connections
/// Note: Uses page_allocator internally to avoid GPA issues after fork/daemonization
pub const Server = struct {
    allocator: std.mem.Allocator,
    socket: ipc.Server,
    ses_state: *state.SesState,
    running: bool,
    // Track pending pop requests: mux_fd -> cli_fd
    pending_pop_requests: std.AutoHashMap(posix.fd_t, posix.fd_t),
    // Track which fds use binary control protocol (MUX_CTL and POD_CTL connections).
    binary_ctl_fds: std.AutoHashMap(posix.fd_t, void),
    ctl_watchers: std.AutoHashMap(posix.fd_t, *CtlWatcher),
    pending_ctl_close_fds: std.ArrayList(PendingCtlClose),
    vt_watchers: std.AutoHashMap(posix.fd_t, *VtWatcher),
    pending_vt_close_fds: std.ArrayList(PendingVtClose),
    // Deferred watcher destruction: nodes are kept alive for one loop iteration
    // after disarm so xev can finish processing their completions. Freeing
    // immediately causes use-after-free in ReleaseFast (xev still holds refs).
    deferred_destroy_ctl: std.ArrayList(*CtlWatcher),
    deferred_destroy_vt: std.ArrayList(*VtWatcher),
    loop_ptr: ?*xev.Loop = null,
    // CLI fd waiting for exit_intent response.
    pending_exit_intent_cli_fd: ?posix.fd_t = null,
    // CLI fds waiting for float result, keyed by float pane UUID.
    pending_float_cli_fds: std.AutoHashMap([32]u8, posix.fd_t),

    // Resource monitoring and limits
    resource_monitor: core.resource_limits.ResourceMonitor,

    pub fn init(_: std.mem.Allocator, ses_state: *state.SesState) !Server {
        // Use page_allocator for everything to avoid GPA issues after fork
        const page_alloc = std.heap.page_allocator;
        const socket_path = try ipc.getSesSocketPath(page_alloc);
        defer page_alloc.free(socket_path);

        const socket = try ipc.Server.init(page_alloc, socket_path);
        const limits = core.resource_limits.ResourceLimits.fromEnv();

        return Server{
            .allocator = page_alloc,
            .socket = socket,
            .ses_state = ses_state,
            .running = true,
            .pending_pop_requests = std.AutoHashMap(posix.fd_t, posix.fd_t).init(page_alloc),
            .binary_ctl_fds = std.AutoHashMap(posix.fd_t, void).init(page_alloc),
            .ctl_watchers = std.AutoHashMap(posix.fd_t, *CtlWatcher).init(page_alloc),
            .pending_ctl_close_fds = .empty,
            .vt_watchers = std.AutoHashMap(posix.fd_t, *VtWatcher).init(page_alloc),
            .pending_vt_close_fds = .empty,
            .deferred_destroy_ctl = .empty,
            .deferred_destroy_vt = .empty,
            .pending_float_cli_fds = std.AutoHashMap([32]u8, posix.fd_t).init(page_alloc),
            .resource_monitor = core.resource_limits.ResourceMonitor.init(limits),
        };
    }

    pub fn deinit(self: *Server) void {
        if (self.pending_exit_intent_cli_fd) |fd| posix.close(fd);
        var float_it = self.pending_float_cli_fds.iterator();
        while (float_it.next()) |entry| posix.close(entry.value_ptr.*);
        self.pending_float_cli_fds.deinit();
        self.pending_pop_requests.deinit();
        var watch_it = self.ctl_watchers.iterator();
        while (watch_it.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.ctl_watchers.deinit();
        self.pending_ctl_close_fds.deinit(self.allocator);

        var vt_it = self.vt_watchers.iterator();
        while (vt_it.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.vt_watchers.deinit();
        self.pending_vt_close_fds.deinit(self.allocator);
        self.flushDeferredDestroys();
        self.deferred_destroy_ctl.deinit(self.allocator);
        self.deferred_destroy_vt.deinit(self.allocator);

        self.binary_ctl_fds.deinit();
        self.socket.deinit();
    }

    /// Main server loop - handles connections and messages
    pub fn run(self: *Server) !void {
        try xev.detect();
        var loop = try xev.Loop.init(.{});
        defer loop.deinit();
        self.loop_ptr = &loop;
        defer self.loop_ptr = null;

        const server_watcher = xev.File.initFd(self.socket.getFd());
        var server_completion: xev.Completion = .{};
        var timer_completion: xev.Completion = .{};
        var ticker = try xev.Timer.init();
        defer ticker.deinit();
        var accept_ctx = AcceptContext{
            .server = self,
        };
        server_watcher.poll(&loop, &server_completion, .read, AcceptContext, &accept_ctx, acceptCallback);

        var periodic_ctx = PeriodicContext{
            .server = self,
            .ticker = ticker,
            .last_save = std.time.milliTimestamp(),
            .last_stats_update = std.time.milliTimestamp(),
            .last_cleanup = std.time.milliTimestamp(),
        };
        ticker.run(&loop, &timer_completion, 100, PeriodicContext, &periodic_ctx, periodicCallback);

        while (self.running) {
            // Free watcher nodes that were disarmed in a previous iteration.
            // We defer destruction by one loop iteration so xev can finish
            // processing completions that reference the node memory.
            self.flushDeferredDestroys();
            self.processPendingWatcherUpdates();
            self.processPendingCtlCloses();
            self.processPendingVtCloses();
            loop.run(.once) catch |err| {
                ses.debugLog("event loop error (continuing): {s}", .{@errorName(err)});
                continue;
            };
        }
    }

    fn processPendingCtlCloses(self: *Server) void {
        if (self.pending_ctl_close_fds.items.len > 0) {
            ses.debugLog("processPendingCtlCloses: {d} pending", .{self.pending_ctl_close_fds.items.len});
        }
        for (self.pending_ctl_close_fds.items) |pending| {
            ses.debugLog("processPendingCtlCloses: fd={d}", .{pending.fd});
            if (!self.disarmCtlWatcherMatching(pending.fd, pending.watcher)) continue;
            _ = self.binary_ctl_fds.remove(pending.fd);

            var client_id: ?usize = null;
            for (self.ses_state.clients.items) |client| {
                if (client.fd == pending.fd or client.mux_ctl_fd == pending.fd) {
                    client_id = client.id;
                    break;
                }
            }
            var closed_by_client_remove = false;
            if (client_id) |cid| {
                ses.debugLog("processPendingCtlCloses: removing client_id={d}", .{cid});
                self.removeClientWithWatcherCleanup(cid);
                ses.debugLog("processPendingCtlCloses: client removed", .{});
                closed_by_client_remove = true;
            }

            if (self.pending_pop_requests.fetchRemove(pending.fd)) |kv| {
                posix.close(kv.value);
            }

            if (!closed_by_client_remove) {
                posix.close(pending.fd);
            }
        }
        self.pending_ctl_close_fds.clearRetainingCapacity();
    }

    fn removeClientWithWatcherCleanup(self: *Server, client_id: usize) void {
        if (self.ses_state.getClient(client_id)) |client| {
            if (client.mux_ctl_fd) |ctl_fd| {
                _ = self.binary_ctl_fds.remove(ctl_fd);
                self.disarmCtlWatcher(ctl_fd);
            }
            if (client.mux_vt_fd) |vt_fd| {
                self.disarmVtWatcher(vt_fd);
            }
        }
        self.ses_state.removeClient(client_id);
    }

    fn processPendingVtCloses(self: *Server) void {
        if (self.pending_vt_close_fds.items.len > 0) {
            ses.debugLog("processPendingVtCloses: {d} pending", .{self.pending_vt_close_fds.items.len});
        }
        for (self.pending_vt_close_fds.items) |pending| {
            ses.debugLog("processPendingVtCloses: fd={d} is_pod_vt={} is_mux_vt={}", .{
                pending.fd,
                self.ses_state.pod_vt_to_pane_id.contains(pending.fd),
                self.isMuxVtFd(pending.fd),
            });
            if (!self.disarmVtWatcherMatching(pending.fd, pending.watcher)) {
                ses.debugLog("processPendingVtCloses: fd={d} disarm failed, skipping", .{pending.fd});
                // Watcher was already removed from map (e.g. by
                // processPendingWatcherUpdates during detach). Its callback
                // already returned .disarm so no CQE is pending. Free now.
                if (pending.watcher) |w| self.allocator.destroy(w);
                continue;
            }

            // Callback already returned .disarm, free the node now.
            if (pending.watcher) |w| self.allocator.destroy(w);

            if (self.ses_state.pod_vt_to_pane_id.contains(pending.fd)) {
                ses.debugLog("processPendingVtCloses: fd={d} removing pod VT", .{pending.fd});
                self.removePodVtFd(pending.fd);
            }
            if (self.isMuxVtFd(pending.fd)) {
                ses.debugLog("processPendingVtCloses: fd={d} removing MUX VT", .{pending.fd});
                self.removeMuxVtFd(pending.fd);
            }

            posix.close(pending.fd);
            ses.debugLog("processPendingVtCloses: fd={d} closed", .{pending.fd});
        }
        self.pending_vt_close_fds.clearRetainingCapacity();
    }

    fn queueCtlClose(self: *Server, fd: posix.fd_t, watcher: ?*CtlWatcher) void {
        for (self.pending_ctl_close_fds.items) |existing| {
            if (existing.fd == fd) return;
        }
        self.pending_ctl_close_fds.append(self.allocator, .{ .fd = fd, .watcher = watcher }) catch {};
    }

    fn queueVtClose(self: *Server, fd: posix.fd_t, watcher: ?*VtWatcher) void {
        for (self.pending_vt_close_fds.items) |existing| {
            if (existing.fd == fd) return;
        }
        self.pending_vt_close_fds.append(self.allocator, .{ .fd = fd, .watcher = watcher }) catch {};
    }

    fn flushDeferredDestroys(self: *Server) void {
        for (self.deferred_destroy_ctl.items) |node| {
            self.allocator.destroy(node);
        }
        self.deferred_destroy_ctl.clearRetainingCapacity();
        for (self.deferred_destroy_vt.items) |node| {
            self.allocator.destroy(node);
        }
        self.deferred_destroy_vt.clearRetainingCapacity();
    }

    fn processPendingWatcherUpdates(self: *Server) void {
        // Disarm old watchers BEFORE arming new ones to prevent fd-reuse
        // collisions. When a closed fd number is reused by a new connection,
        // armVtWatcher would skip it if the old watcher entry still exists.
        if (self.ses_state.pending_remove_poll_fds.items.len > 0 or self.ses_state.pending_poll_fds.items.len > 0) {
            ses.debugLog("processPendingWatcherUpdates: remove={d} add={d}", .{
                self.ses_state.pending_remove_poll_fds.items.len,
                self.ses_state.pending_poll_fds.items.len,
            });
        }
        for (self.ses_state.pending_remove_poll_fds.items) |fd| {
            ses.debugLog("processPendingWatcherUpdates: disarm fd={d}", .{fd});
            if (self.binary_ctl_fds.contains(fd)) {
                self.disarmCtlWatcher(fd);
            }
            self.disarmVtWatcher(fd);
        }
        self.ses_state.pending_remove_poll_fds.clearRetainingCapacity();

        for (self.ses_state.pending_poll_fds.items) |fd| {
            ses.debugLog("processPendingWatcherUpdates: arm fd={d}", .{fd});
            self.armVtWatcher(fd, .pod_to_mux);
        }
        self.ses_state.pending_poll_fds.clearRetainingCapacity();
    }

    fn armCtlWatcher(self: *Server, fd: posix.fd_t) void {
        if (self.loop_ptr == null) return;
        if (self.ctl_watchers.contains(fd)) return;

        const node = self.allocator.create(CtlWatcher) catch return;
        node.* = .{ .srv = @ptrCast(self), .fd = fd };
        self.ctl_watchers.put(fd, node) catch {
            self.allocator.destroy(node);
            return;
        };

        const watcher = xev.File.initFd(fd);
        watcher.poll(self.loop_ptr.?, &node.completion, .read, CtlWatcher, node, ctlWatcherCallback);
    }

    fn disarmCtlWatcher(self: *Server, fd: posix.fd_t) void {
        if (self.ctl_watchers.fetchRemove(fd)) |kv| {
            // Defer destruction: xev may still reference the completion struct
            self.deferred_destroy_ctl.append(self.allocator, kv.value) catch {
                // If append fails, leak rather than use-after-free
            };
        }
    }

    fn disarmCtlWatcherMatching(self: *Server, fd: posix.fd_t, expected: ?*CtlWatcher) bool {
        if (expected) |watcher| {
            const current = self.ctl_watchers.get(fd) orelse return false;
            if (current != watcher) return false;
        }
        self.disarmCtlWatcher(fd);
        return true;
    }

    fn armVtWatcher(self: *Server, fd: posix.fd_t, direction: VtDirection) void {
        if (self.loop_ptr == null) {
            ses.debugLog("armVtWatcher: SKIP fd={d} (no loop)", .{fd});
            return;
        }
        if (self.vt_watchers.contains(fd)) {
            ses.debugLog("armVtWatcher: SKIP fd={d} (already armed)", .{fd});
            return;
        }
        ses.debugLog("armVtWatcher: ARMED fd={d} dir={s}", .{ fd, @tagName(direction) });

        const node = self.allocator.create(VtWatcher) catch return;
        node.* = .{ .srv = @ptrCast(self), .fd = fd, .direction = direction };
        self.vt_watchers.put(fd, node) catch {
            self.allocator.destroy(node);
            return;
        };

        const watcher = xev.File.initFd(fd);
        watcher.poll(self.loop_ptr.?, &node.completion, .read, VtWatcher, node, vtWatcherCallback);
    }

    fn disarmVtWatcher(self: *Server, fd: posix.fd_t) void {
        // Remove from map but do NOT free — the io_uring POLL_ADD may still
        // be pending. The stale CQE will fire eventually and vtWatcherCallback
        // will detect the orphaned node (map miss) and free it.
        _ = self.vt_watchers.fetchRemove(fd);
    }

    fn disarmVtWatcherMatching(self: *Server, fd: posix.fd_t, expected: ?*VtWatcher) bool {
        if (expected) |watcher| {
            const current = self.vt_watchers.get(fd) orelse return false;
            if (current != watcher) return false;
        }
        self.disarmVtWatcher(fd);
        return true;
    }

    const AcceptContext = struct {
        server: *Server,
    };

    const PeriodicContext = struct {
        server: *Server,
        ticker: xev.Timer,
        last_save: i64,
        last_stats_update: i64,
        last_cleanup: i64,
    };

    fn acceptCallback(
        ctx: ?*AcceptContext,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.File,
        result: xev.PollError!xev.PollEvent,
    ) xev.CallbackAction {
        const accept_ctx = ctx orelse return .disarm;
        _ = result catch return .rearm;

        while (accept_ctx.server.socket.tryAccept() catch null) |conn| {
            accept_ctx.server.dispatchNewConnection(conn);
        }

        return .rearm;
    }

    fn ctlWatcherCallback(
        ctx: ?*CtlWatcher,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.File,
        result: xev.PollError!xev.PollEvent,
    ) xev.CallbackAction {
        const watch = ctx orelse return .disarm;
        const server: *Server = @ptrCast(@alignCast(watch.srv));
        _ = result catch {
            server.queueCtlClose(watch.fd, watch);
            return .disarm;
        };

        if (!server.handleBinaryCtlMessage(watch.fd)) {
            server.queueCtlClose(watch.fd, watch);
            return .disarm;
        }

        return .rearm;
    }

    fn vtWatcherCallback(
        ctx: ?*VtWatcher,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.File,
        result: xev.PollError!xev.PollEvent,
    ) xev.CallbackAction {
        const watch = ctx orelse return .disarm;
        const server: *Server = @ptrCast(@alignCast(watch.srv));

        // If this watcher was disarmed (removed from vt_watchers map) but its
        // io_uring poll was still pending, this is a stale CQE. Free the
        // orphaned node and stop polling.
        const current = server.vt_watchers.get(watch.fd);
        if (current == null or current.? != watch) {
            server.allocator.destroy(watch);
            return .disarm;
        }

        _ = result catch {
            server.queueVtClose(watch.fd, watch);
            return .disarm;
        };

        const ok = switch (watch.direction) {
            .pod_to_mux => server.routePodToMux(watch.fd),
            .mux_to_pod => server.routeMuxToPod(watch.fd),
        };
        if (!ok) {
            ses.debugLog("vtWatcher: fd={d} dir={s} returned false, queueing close", .{ watch.fd, @tagName(watch.direction) });
            server.queueVtClose(watch.fd, watch);
            return .disarm;
        }

        return .rearm;
    }

    fn periodicCallback(
        ctx: ?*PeriodicContext,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        const periodic = ctx orelse return .disarm;
        _ = result catch {
            // Re-arm with fresh absolute timestamp (workaround for xev io_uring timer re-arm bug)
            periodic.ticker.run(loop, completion, 100, PeriodicContext, periodic, periodicCallback);
            return .disarm;
        };

        const now_ms = std.time.milliTimestamp();

        if (periodic.server.ses_state.dirty and now_ms - periodic.last_save >= 1000) {
            @import("persist.zig").save(periodic.server.allocator, periodic.server.ses_state) catch |e| {
                core.logging.logError("ses", "persist.save failed", e);
            };
            periodic.server.ses_state.dirty = false;
            periodic.last_save = now_ms;
        }

        if (now_ms - periodic.last_stats_update >= 5000) {
            const detached_sessions = periodic.server.ses_state.detached_sessions.count();
            const total_panes = periodic.server.ses_state.panes.count();
            const active_connections = periodic.server.ses_state.clients.items.len;

            periodic.server.resource_monitor.updateStats(
                active_connections,
                detached_sessions,
                total_panes,
                0,
            );
            periodic.last_stats_update = now_ms;
        }

        if (now_ms - periodic.last_cleanup >= 1000) {
            // Retry any deferred backlog reconnects. This avoids attach-time
            // races where a pod VT endpoint is not ready on the first attempt.
            periodic.server.ses_state.processBacklogReplays();
            periodic.server.ses_state.cleanupOrphanedPanes();
            periodic.server.ses_state.cleanupExpiredDetachedSessions();
            periodic.last_cleanup = now_ms;
        }

        // Re-arm with fresh absolute timestamp (workaround for xev io_uring timer re-arm bug)
        periodic.ticker.run(loop, completion, 100, PeriodicContext, periodic, periodicCallback);
        return .disarm;
    }

    /// Dispatch a newly accepted connection based on its handshake bytes.
    /// Handshake format: [channel_type, protocol_version]
    fn dispatchNewConnection(self: *Server, conn: ipc.Connection) void {
        // Check resource limits and rate limiting
        if (!self.resource_monitor.allowNewConnection()) {
            ses.debugLog("reject: connection limit or rate limit exceeded", .{});
            // Try to send error message before closing
            const err_msg = "server_overloaded: connection/rate limit exceeded";
            const err_payload = wire.Error{ .msg_len = @intCast(err_msg.len) };
            wire.writeControlWithTrail(conn.fd, .@"error", std.mem.asBytes(&err_payload), err_msg) catch {};
            var tmp = conn;
            tmp.close();
            return;
        }
        self.resource_monitor.recordConnection();

        // Read versioned handshake: [channel_type, version]
        var handshake: [2]u8 = undefined;
        var off: usize = 0;
        while (off < 2) {
            const n = posix.read(conn.fd, handshake[off..]) catch {
                var tmp = conn;
                tmp.close();
                return;
            };
            if (n == 0) {
                var tmp = conn;
                tmp.close();
                return;
            }
            off += n;
        }

        // Validate protocol version with negotiation.
        const client_version = handshake[1];
        if (!wire.isProtocolVersionSupported(client_version)) {
            ses.debugLog("reject: unsupported protocol version {d} (supported: {d}-{d})", .{
                client_version,
                wire.MIN_PROTOCOL_VERSION,
                wire.PROTOCOL_VERSION,
            });
            // Send error message if this is a CTL channel (can receive error responses)
            if (handshake[0] == wire.SES_HANDSHAKE_MUX_CTL or handshake[0] == wire.SES_HANDSHAKE_POD_CTL) {
                // Send version mismatch error with version range
                const err_msg = std.fmt.allocPrint(
                    self.allocator,
                    "protocol_version_mismatch: client={d} supported={d}-{d}",
                    .{ client_version, wire.MIN_PROTOCOL_VERSION, wire.PROTOCOL_VERSION },
                ) catch "protocol_version_mismatch";
                defer if (!std.mem.eql(u8, err_msg, "protocol_version_mismatch")) self.allocator.free(err_msg);

                const err_payload = wire.Error{ .msg_len = @intCast(err_msg.len) };
                wire.writeControlWithTrail(conn.fd, .@"error", std.mem.asBytes(&err_payload), err_msg) catch {};
            }
            var tmp = conn;
            tmp.close();
            return;
        }

        // Log deprecation warning if client is using old version
        if (wire.isProtocolVersionDeprecated(client_version)) {
            ses.debugLog("warning: client using deprecated protocol version {d} (current: {d})", .{
                client_version,
                wire.PROTOCOL_VERSION,
            });
            // Send deprecation notice if this is a CTL channel
            if (handshake[0] == wire.SES_HANDSHAKE_MUX_CTL) {
                const warn_msg = std.fmt.allocPrint(
                    self.allocator,
                    "Protocol version {d} is deprecated. Please update to version {d}.",
                    .{ client_version, wire.PROTOCOL_VERSION },
                ) catch "";
                defer if (warn_msg.len > 0) self.allocator.free(warn_msg);

                if (warn_msg.len > 0) {
                    const notify = wire.Notify{ .msg_len = @intCast(warn_msg.len) };
                    wire.writeControlWithTrail(conn.fd, .notify, std.mem.asBytes(&notify), warn_msg) catch {};
                }
            }
        }

        switch (handshake[0]) {
            wire.SES_HANDSHAKE_MUX_CTL => {
                // MUX binary control channel.
                ses.debugLog("accept: MUX ctl channel fd={d}", .{conn.fd});
                self.binary_ctl_fds.put(conn.fd, {}) catch {};
                self.armCtlWatcher(conn.fd);
            },
            wire.SES_HANDSHAKE_MUX_VT => {
                // MUX VT data channel — read 32-byte session_id to identify client.
                ses.debugLog("accept: MUX VT channel fd={d}", .{conn.fd});
                var sid: [32]u8 = undefined;
                wire.readExact(conn.fd, &sid) catch {
                    var tmp = conn;
                    tmp.close();
                    return;
                };
                // Convert 32-char hex to 16-byte session_id for lookup.
                const session_id = core.uuid.hexToBin(sid) orelse {
                    // Invalid hex — close connection.
                    var tmp = conn;
                    tmp.close();
                    return;
                };
                // Find client with matching session_id.
                var found = false;
                for (self.ses_state.clients.items) |*client| {
                    if (client.session_id) |csid| {
                        if (std.mem.eql(u8, &csid, &session_id)) {
                            if (client.mux_vt_fd) |old| {
                                self.queueVtClose(old, null);
                            }
                            client.mux_vt_fd = conn.fd;
                            ses.debugLog("MUX VT: assigned fd={d} to client_id={d}", .{ conn.fd, client.id });
                            found = true;
                            break;
                        }
                    }
                }
                if (!found) {
                    ses.debugLog("MUX VT: no client for session {s}", .{sid});
                    var tmp = conn;
                    tmp.close();
                    return;
                }
                self.armVtWatcher(conn.fd, .mux_to_pod);
            },
            wire.SES_HANDSHAKE_CLI => {
                // CLI tool request (focus_move, exit_intent, float).
                self.handleCliRequest(conn.fd);
            },
            wire.SES_HANDSHAKE_POD_CTL => {
                // POD control uplink — read 16-byte binary UUID.
                ses.debugLog("accept: POD ctl uplink fd={d}", .{conn.fd});
                var uuid_bin: [16]u8 = undefined;
                wire.readExact(conn.fd, &uuid_bin) catch {
                    var tmp = conn;
                    tmp.close();
                    return;
                };
                // Convert 16 binary bytes → 32-char hex UUID key.
                const uuid_hex = core.uuid.binToHex(uuid_bin);
                // Store fd in the pane's pod_ctl_fd.
                if (self.ses_state.panes.getPtr(uuid_hex)) |pane| {
                    if (pane.pod_ctl_fd) |old_fd| {
                        self.queueCtlClose(old_fd, null);
                    }
                    pane.pod_ctl_fd = conn.fd;
                    self.binary_ctl_fds.put(conn.fd, {}) catch {};
                    self.armCtlWatcher(conn.fd);
                } else {
                    ses.debugLog("POD ctl: unknown UUID {s}", .{uuid_hex});
                    var tmp = conn;
                    tmp.close();
                }
            },
            else => {
                // Unknown handshake byte — close.
                var tmp = conn;
                tmp.close();
            },
        }
    }

    /// Check if fd is a MUX VT data channel.
    fn isMuxVtFd(self: *Server, fd: posix.fd_t) bool {
        for (self.ses_state.clients.items) |client| {
            if (client.mux_vt_fd) |vt_fd| {
                if (vt_fd == fd) return true;
            }
        }
        return false;
    }

    /// Route VT data from POD → MUX.
    /// Reads a full pod frame first, then writes MUX header+payload.
    /// This avoids emitting a header with missing payload when POD exits
    /// mid-frame (which would desync MUX VT parser and drop the whole channel).
    /// Returns false if the connection should be removed.
    fn routePodToMux(self: *Server, pod_vt_fd: posix.fd_t) bool {
        // Read 5-byte pod_protocol header (type:u8 + len:u32 big-endian).
        var hdr: [5]u8 = undefined;
        wire.readExactTimeout(pod_vt_fd, &hdr, VT_ROUTE_IO_TIMEOUT_MS) catch return false;

        const frame_type = hdr[0];
        const payload_len = std.mem.readInt(u32, hdr[1..5], .big);

        // Safety cap.
        if (payload_len > wire.MAX_PAYLOAD_LEN) return false;

        // Look up pane_id.
        const pane_id = self.ses_state.pod_vt_to_pane_id.get(pod_vt_fd) orelse {
            ses.debugLog("vt pod->mux: pod_vt_fd={d} NOT in routing table, draining {d} bytes", .{ pod_vt_fd, payload_len });
            self.skipBytes(pod_vt_fd, payload_len);
            return true;
        };
        ses.debugLog("vt pod->mux: pane_id={d} type={d} len={d} pod_vt_fd={d}", .{ pane_id, frame_type, payload_len, pod_vt_fd });

        // Find the MUX VT fd for this pane.
        const mux_vt_fd = self.findMuxVtForPane(pane_id) orelse {
            // No MUX connected — skip payload.
            self.skipBytes(pod_vt_fd, payload_len);
            return true;
        };

        // Read the full payload before sending any MUX header.
        const payload = self.allocator.alloc(u8, payload_len) catch {
            self.skipBytes(pod_vt_fd, payload_len);
            return true;
        };
        defer self.allocator.free(payload);

        wire.readExactTimeout(pod_vt_fd, payload, VT_ROUTE_IO_TIMEOUT_MS) catch {
            self.queueVtClose(pod_vt_fd, null);
            return true;
        };

        // Write 7-byte MuxVtHeader to MUX.
        var mux_hdr: wire.MuxVtHeader = .{
            .pane_id = pane_id,
            .frame_type = frame_type,
            .len = payload_len,
        };
        wire.writeAllTimeout(mux_vt_fd, std.mem.asBytes(&mux_hdr), VT_ROUTE_IO_TIMEOUT_MS) catch |err| {
            ses.debugLog("vt pod->mux: mux header write failed: {s}", .{@errorName(err)});
            switch (err) {
                error.ConnectionClosed, error.BrokenPipe => self.queueVtClose(mux_vt_fd, null),
                else => {},
            }
            return true;
        };

        wire.writeAllTimeout(mux_vt_fd, payload, VT_ROUTE_IO_TIMEOUT_MS) catch |err| {
            ses.debugLog("vt pod->mux: mux payload write failed: {s}", .{@errorName(err)});
            switch (err) {
                error.ConnectionClosed, error.BrokenPipe => self.queueVtClose(mux_vt_fd, null),
                else => {},
            }
            return true;
        };
        return true;
    }

    /// Route VT data from MUX → POD.
    /// Reads a 7-byte MuxVtHeader + payload from mux_vt_fd,
    /// wraps it in a 5-byte pod_protocol header, and writes to the POD VT channel.
    /// Returns false if the connection should be removed.
    fn routeMuxToPod(self: *Server, mux_vt_fd: posix.fd_t) bool {
        // Read 7-byte MuxVtHeader.
        var mux_hdr_buf: [@sizeOf(wire.MuxVtHeader)]u8 = undefined;
        wire.readExactTimeout(mux_vt_fd, &mux_hdr_buf, VT_ROUTE_IO_TIMEOUT_MS) catch |err| {
            ses.debugLog("vt mux->pod: mux disconnected: {s}", .{@errorName(err)});
            return false;
        };
        const mux_hdr = std.mem.bytesToValue(wire.MuxVtHeader, &mux_hdr_buf);
        ses.debugLog("vt mux->pod: pane_id={d} type={d} len={d} mux_vt_fd={d}", .{ mux_hdr.pane_id, mux_hdr.frame_type, mux_hdr.len, mux_vt_fd });

        // Safety cap.
        if (mux_hdr.len > wire.MAX_PAYLOAD_LEN) return false;

        // Look up pod_vt_fd from pane_id.
        const pod_vt_fd = self.ses_state.pane_id_to_pod_vt.get(mux_hdr.pane_id) orelse {
            // Unknown pane — skip payload.
            self.skipBytes(mux_vt_fd, mux_hdr.len);
            return true;
        };

        // Write 5-byte pod_protocol header to POD.
        var pod_hdr: [5]u8 = undefined;
        pod_hdr[0] = mux_hdr.frame_type;
        std.mem.writeInt(u32, pod_hdr[1..5], mux_hdr.len, .big);
        wire.writeAll(pod_vt_fd, &pod_hdr) catch {
            ses.debugLog("vt mux->pod: pod_vt_fd write failed, queuing close", .{});
            self.skipBytes(mux_vt_fd, mux_hdr.len);
            self.queueVtClose(pod_vt_fd, null);
            return true;
        };

        // Splice payload: read from mux, write to pod.
        self.spliceData(mux_vt_fd, pod_vt_fd, mux_hdr.len) catch {
            self.queueVtClose(pod_vt_fd, null);
            return true;
        };
        return true;
    }

    /// Find the MUX VT fd that should receive output for a given pane_id.
    fn findMuxVtForPane(self: *Server, pane_id: u16) ?posix.fd_t {
        // Find which pane has this pane_id, then find its owning client's mux_vt_fd.
        var pane_iter = self.ses_state.panes.valueIterator();
        while (pane_iter.next()) |pane| {
            if (pane.pane_id == pane_id) {
                if (pane.attached_to) |client_id| {
                    if (self.ses_state.getClient(client_id)) |client| {
                        return client.mux_vt_fd;
                    }
                }
                return null;
            }
        }
        return null;
    }

    fn removePodVtFd(self: *Server, fd: posix.fd_t) void {
        ses.debugLog("remove pod_vt fd={d}", .{fd});
        const pane_id = if (self.ses_state.pod_vt_to_pane_id.fetchRemove(fd)) |kv| blk: {
            _ = self.ses_state.pane_id_to_pod_vt.remove(kv.value);
            break :blk kv.value;
        } else null;

        // Clear from pane and notify MUX.
        var pane_iter = self.ses_state.panes.iterator();
        while (pane_iter.next()) |entry| {
            const pane = entry.value_ptr;
            if (pane.pod_vt_fd) |vt_fd| {
                if (vt_fd == fd) {
                    @constCast(pane).pod_vt_fd = null;
                    // Notify the owning MUX that this pane exited.
                    if (pane.attached_to) |client_id| {
                        if (self.ses_state.getClient(client_id)) |client| {
                            if (client.mux_ctl_fd) |ctl_fd| {
                                const uuid = entry.key_ptr.*;
                                ses.debugLog("pane_exited: uuid={s} pane_id={?d}", .{ uuid[0..8], pane_id });
                                var msg = wire.PaneUuid{ .uuid = uuid };
                                wire.writeControl(ctl_fd, .pane_exited, std.mem.asBytes(&msg)) catch {};
                            }
                        }
                    }
                    return;
                }
            }
        }
    }

    fn removeMuxVtFd(self: *Server, fd: posix.fd_t) void {
        ses.debugLog("remove mux_vt fd={d}", .{fd});
        for (self.ses_state.clients.items) |*client| {
            if (client.mux_vt_fd) |vt_fd| {
                if (vt_fd == fd) {
                    client.mux_vt_fd = null;
                    return;
                }
            }
        }
    }

    /// Read from src and write to dst, `len` bytes total.
    fn spliceData(_: *Server, src: posix.fd_t, dst: posix.fd_t, len: u32) !void {
        var remaining: usize = len;
        var buf: [16 * 1024]u8 = undefined;
        while (remaining > 0) {
            const chunk = @min(remaining, buf.len);
            wire.readExactTimeout(src, buf[0..chunk], VT_ROUTE_IO_TIMEOUT_MS) catch return error.ConnectionClosed;
            wire.writeAllTimeout(dst, buf[0..chunk], VT_ROUTE_IO_TIMEOUT_MS) catch return error.ConnectionClosed;
            remaining -= chunk;
        }
    }

    /// Discard `len` bytes from fd.
    fn skipBytes(_: *Server, fd: posix.fd_t, len: u32) void {
        var remaining: usize = len;
        var buf: [4096]u8 = undefined;
        while (remaining > 0) {
            const chunk = @min(remaining, buf.len);
            wire.readExactTimeout(fd, buf[0..chunk], VT_ROUTE_IO_TIMEOUT_MS) catch return;
            remaining -= chunk;
        }
    }

    /// Find client_id for a binary CTL fd.
    fn findClientForCtlFd(self: *Server, fd: posix.fd_t) ?usize {
        for (self.ses_state.clients.items) |client| {
            if (client.fd == fd or client.mux_ctl_fd == fd) return client.id;
        }
        return null;
    }

    /// Handle a binary control message. Returns false if connection should be removed.
    fn handleBinaryCtlMessage(self: *Server, fd: posix.fd_t) bool {
        const hdr = wire.readControlHeader(fd) catch return false;
        const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        ses.debugLog("ctl msg: type=0x{x:0>4} len={d} fd={d}", .{ hdr.msg_type, hdr.payload_len, fd });
        var buf: [65536]u8 = undefined;

        switch (msg_type) {
            .ping => {
                wire.writeControl(fd, .pong, &.{}) catch {};
            },
            .register => {
                self.handleBinaryRegister(fd, hdr.payload_len, &buf);
            },
            .sync_state => {
                self.handleBinarySyncState(fd, hdr.payload_len, &buf);
            },
            .layout_sync => {
                self.handleBinaryLayoutSync(fd, hdr.payload_len, &buf);
            },
            .create_pane => {
                self.handleBinaryCreatePane(fd, hdr.payload_len, &buf);
            },
            .find_sticky => {
                self.handleBinaryFindSticky(fd, hdr.payload_len, &buf);
            },
            .orphan_pane => {
                self.handleBinaryOrphanPane(fd, hdr.payload_len, &buf);
            },
            .adopt_pane => {
                self.handleBinaryAdoptPane(fd, hdr.payload_len, &buf);
            },
            .replay_backlogs => {
                // MUX signals it's ready for backlog replay after reattach.
                // Ack immediately and let periodic loop perform replay.
                // Running replay inline here can block on pod VT reconnect
                // handshake and freeze the event loop for seconds.
                ses.debugLog("replay_backlogs: sending ok (deferred processing)", .{});
                wire.writeControl(fd, .ok, &.{}) catch {};
            },
            .kill_pane => {
                self.handleBinaryKillPane(fd, hdr.payload_len, &buf);
            },
            .set_sticky => {
                self.handleBinarySetSticky(fd, hdr.payload_len, &buf);
            },
            .get_pane_cwd => {
                self.handleBinaryGetPaneCwd(fd, hdr.payload_len, &buf);
            },
            .pane_info => {
                if (hdr.payload_len < @sizeOf(wire.PaneUuid)) {
                    self.skipBinaryPayload(fd, hdr.payload_len, &buf);
                    wire.writeControl(fd, .@"error", &.{}) catch {};
                    return false;
                }
                const pu = wire.readStruct(wire.PaneUuid, fd) catch return false;
                self.handleBinaryPaneInfo(fd, pu.uuid);
            },
            .list_orphaned => {
                self.handleBinaryListOrphaned(fd, &buf);
            },
            .list_sessions => {
                self.handleBinaryListSessions(fd, &buf);
            },
            .detach => {
                self.handleBinaryDetach(fd, hdr.payload_len, &buf);
            },
            .reattach => {
                self.handleBinaryReattach(fd, hdr.payload_len, &buf);
            },
            .disconnect => {
                self.handleBinaryDisconnect(fd, hdr.payload_len, &buf);
            },
            .update_pane_name => {
                self.handleBinaryUpdatePaneName(fd, hdr.payload_len, &buf);
            },
            .update_pane_shell => {
                self.handleBinaryUpdatePaneShell(fd, hdr.payload_len, &buf);
            },
            .update_pane_aux => {
                self.handleBinaryUpdatePaneAux(fd, hdr.payload_len, &buf);
            },
            .pop_response => {
                self.handleBinaryPopResponse(fd, hdr.payload_len, &buf);
            },
            .exit_intent_result => {
                self.handleBinaryExitIntentResult(fd, hdr.payload_len, &buf);
            },
            .float_result => {
                self.handleBinaryFloatResult(fd, hdr.payload_len, &buf);
            },
            .session_add_tab => {
                self.handleBinarySessionAddTab(fd, hdr.payload_len, &buf);
            },
            .session_remove_tab => {
                self.handleBinarySessionRemoveTab(fd, hdr.payload_len, &buf);
            },
            .session_sync_float => {
                self.handleBinarySessionSyncFloat(fd, hdr.payload_len, &buf);
            },
            .session_remove_float => {
                self.handleBinarySessionRemoveFloat(fd, hdr.payload_len, &buf);
            },
            .session_sync_tab_layout => {
                self.handleBinarySessionSyncTabLayout(fd, hdr.payload_len, &buf);
            },
            // POD control channel messages
            .cwd_changed => {
                self.handleBinaryCwdChanged(fd, hdr.payload_len, &buf);
            },
            .fg_changed => {
                self.handleBinaryFgChanged(fd, hdr.payload_len, &buf);
            },
            .shell_event => {
                self.handleBinaryShellEvent(fd, hdr.payload_len, &buf);
            },
            .exited => {
                self.handleBinaryExited(fd, hdr.payload_len, &buf);
            },
            else => {
                // Unknown — skip payload and send error so the MUX doesn't hang.
                self.skipBinaryPayload(fd, hdr.payload_len, &buf);
                wire.writeControl(fd, .@"error", &.{}) catch {};
            },
        }
        return true;
    }

    fn skipBinaryPayload(_: *Server, fd: posix.fd_t, len: u32, buf: []u8) void {
        var remaining: usize = len;
        while (remaining > 0) {
            const chunk = @min(remaining, buf.len);
            wire.readExact(fd, buf[0..chunk]) catch return;
            remaining -= chunk;
        }
    }

    fn sendBinaryError(_: *Server, fd: posix.fd_t, msg: []const u8) void {
        var err_payload: wire.Error = .{ .msg_len = @intCast(@min(msg.len, std.math.maxInt(u16))) };
        wire.writeControlWithTrail(fd, .@"error", std.mem.asBytes(&err_payload), msg[0..err_payload.msg_len]) catch {};
    }

    fn handleBinaryRegister(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.Register)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "register: payload too small");
            return;
        }
        const reg = wire.readStruct(wire.Register, fd) catch {
            self.sendBinaryError(fd, "register: read failed");
            return;
        };

        // Read trailing name.
        var name_slice: []const u8 = "";
        if (reg.name_len > 0) {
            if (reg.name_len > wire.MAX_PAYLOAD_LEN) {
                // Name exceeds protocol limit - drain and reject
                self.skipBinaryPayload(fd, reg.name_len, buf);
                self.sendBinaryError(fd, "register: name exceeds MAX_PAYLOAD_LEN");
                return;
            }
            if (reg.name_len <= buf.len) {
                wire.readExact(fd, buf[0..reg.name_len]) catch {
                    self.sendBinaryError(fd, "register: name read failed");
                    return;
                };
                name_slice = buf[0..reg.name_len];
            } else {
                // Name too large for buffer - drain bytes to keep stream aligned, then reject
                self.skipBinaryPayload(fd, reg.name_len, buf);
                self.sendBinaryError(fd, "register: name too long for buffer");
                return;
            }
        }

        // Convert 32-byte hex session_id to 16-byte binary.
        const session_id = core.uuid.hexToBin(reg.session_id) orelse {
            self.sendBinaryError(fd, "register: invalid session_id hex");
            return;
        };

        // Find or create client.
        const client_id = self.findClientForCtlFd(fd) orelse blk: {
            const cid = self.ses_state.addClient(fd) catch {
                self.sendBinaryError(fd, "register: addClient failed");
                return;
            };
            break :blk cid;
        };

        // Resolve session name to ensure uniqueness (avoid collisions with detached sessions)
        const resolved_name: ?[]u8 = if (name_slice.len > 0)
            self.ses_state.resolveSessionName(name_slice, client_id)
        else
            null;
        defer if (resolved_name) |rn| self.allocator.free(rn);

        if (self.ses_state.getClient(client_id)) |client| {
            client.keepalive = (reg.keepalive != 0);
            client.session_id = session_id;
            client.mux_ctl_fd = fd;
            if (client.session_name) |old| client.allocator.free(old);
            // Store the resolved name (duplicated since resolved_name will be freed)
            client.session_name = if (resolved_name) |rn| client.allocator.dupe(u8, rn) catch null else null;
        }

        // If this session_id matches a detached session, the MUX has successfully
        // restored it — remove the detached entry now.
        self.ses_state.removeDetachedSession(session_id);

        // Transaction log: reattach commit
        const hex_id: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
        self.ses_state.txlog.write(.reattach_commit, session_id, &hex_id) catch {};

        // Release session lock (set during reattach in completeReattach)
        self.ses_state.releaseSessionLock(session_id);

        const final_name = resolved_name orelse name_slice;
        ses.debugLog("registered: session={s} name={s} (requested={s}) client_id={d}", .{ reg.session_id[0..8], final_name, name_slice, client_id });

        // Send Registered response with resolved name
        const resp = wire.Registered{ .name_len = @intCast(final_name.len) };
        wire.writeControlWithTrail(fd, .registered, std.mem.asBytes(&resp), final_name) catch {};
    }

    fn handleBinarySyncState(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.SyncState)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const ss = wire.readStruct(wire.SyncState, fd) catch return;
        if (ss.state_len > wire.MAX_PAYLOAD_LEN) {
            self.skipBinaryPayload(fd, payload_len - @sizeOf(wire.SyncState), buf);
            return;
        }

        // Read state data into allocated buffer.
        const state_buf = self.allocator.alloc(u8, ss.state_len) catch {
            self.skipBinaryPayload(fd, ss.state_len, buf);
            return;
        };
        defer self.allocator.free(state_buf);
        wire.readExact(fd, state_buf) catch return;

        const client_id = self.findClientForCtlFd(fd) orelse return;
        if (self.ses_state.getClient(client_id)) |client| {
            // Reject stale/out-of-order updates based on version.
            if (ss.version <= client.last_sync_version) {
                ses.debugLog("sync_state: reject stale version {d} <= {d}", .{ ss.version, client.last_sync_version });
                wire.writeControl(fd, .ok, &.{}) catch {};
                return;
            }
            client.last_sync_version = ss.version;
            if (state.SessionSnapshot.fromJson(self.allocator, state_buf)) |snapshot| {
                client.updateSessionSnapshot(snapshot);
            } else |err| {
                ses.debugLog("sync_state: failed to parse canonical session snapshot: {s}", .{@errorName(err)});
            }
        }
        wire.writeControl(fd, .ok, &.{}) catch {};
    }

    fn handleBinaryLayoutSync(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.SyncState)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const ss = wire.readStruct(wire.SyncState, fd) catch return;
        if (ss.state_len > wire.MAX_PAYLOAD_LEN) {
            self.skipBinaryPayload(fd, payload_len - @sizeOf(wire.SyncState), buf);
            return;
        }

        const state_buf = self.allocator.alloc(u8, ss.state_len) catch {
            self.skipBinaryPayload(fd, ss.state_len, buf);
            return;
        };
        defer self.allocator.free(state_buf);
        wire.readExact(fd, state_buf) catch return;

        const client_id = self.findClientForCtlFd(fd) orelse return;
        if (self.ses_state.getClient(client_id)) |client| {
            client.updateMuxState(state_buf) catch {};
        }
        wire.writeControl(fd, .ok, &.{}) catch {};
    }

    fn handleBinarySessionAddTab(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.SessionAddTab)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const msg = wire.readStruct(wire.SessionAddTab, fd) catch return;
        if (msg.name_len > wire.MAX_PAYLOAD_LEN or msg.name_len > buf.len) {
            self.skipBinaryPayload(fd, msg.name_len, buf);
            self.sendBinaryError(fd, "session_add_tab: name too large");
            return;
        }
        if (msg.name_len > 0) {
            wire.readExact(fd, buf[0..msg.name_len]) catch return;
        }

        const client_id = self.findClientForCtlFd(fd) orelse return;
        self.ses_state.addClientSessionTab(
            client_id,
            msg.tab_uuid,
            msg.pane_uuid,
            msg.tab_index,
            buf[0..msg.name_len],
        ) catch {
            self.sendBinaryError(fd, "session_add_tab_failed");
            return;
        };
        wire.writeControl(fd, .ok, &.{}) catch {};
    }

    fn handleBinarySessionRemoveTab(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.SessionRemoveTab)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const msg = wire.readStruct(wire.SessionRemoveTab, fd) catch return;
        const client_id = self.findClientForCtlFd(fd) orelse return;
        self.ses_state.removeClientSessionTab(
            client_id,
            msg.tab_uuid,
            if (msg.has_active_tab != 0) msg.active_tab else null,
        );
        wire.writeControl(fd, .ok, &.{}) catch {};
    }

    fn handleBinarySessionSyncFloat(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.SessionSyncFloat)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const msg = wire.readStruct(wire.SessionSyncFloat, fd) catch return;
        const client_id = self.findClientForCtlFd(fd) orelse return;
        self.ses_state.syncClientSessionFloat(
            client_id,
            msg.pane_uuid,
            if (msg.has_active_tab != 0) msg.active_tab else null,
            if (msg.has_parent_tab != 0) msg.parent_tab else null,
            msg.visible != 0,
            msg.tab_visible,
            msg.sticky != 0,
            msg.is_pwd != 0,
            msg.float_key,
            msg.width_pct,
            msg.height_pct,
            msg.pos_x_pct,
            msg.pos_y_pct,
            msg.pad_x,
            msg.pad_y,
            msg.active != 0,
        ) catch {
            self.sendBinaryError(fd, "session_sync_float_failed");
            return;
        };
        wire.writeControl(fd, .ok, &.{}) catch {};
    }

    fn handleBinarySessionRemoveFloat(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.SessionRemoveFloat)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const msg = wire.readStruct(wire.SessionRemoveFloat, fd) catch return;
        const client_id = self.findClientForCtlFd(fd) orelse return;
        self.ses_state.removeClientSessionFloat(client_id, msg.pane_uuid);
        wire.writeControl(fd, .ok, &.{}) catch {};
    }

    fn handleBinarySessionSyncTabLayout(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.SessionSyncTabLayout)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const msg = wire.readStruct(wire.SessionSyncTabLayout, fd) catch return;
        if (msg.root_len > wire.MAX_PAYLOAD_LEN or msg.root_len > buf.len) {
            self.skipBinaryPayload(fd, msg.root_len, buf);
            self.sendBinaryError(fd, "session_sync_tab_layout: root too large");
            return;
        }
        if (msg.root_len > 0) {
            wire.readExact(fd, buf[0..msg.root_len]) catch return;
        }

        const client_id = self.findClientForCtlFd(fd) orelse return;
        self.ses_state.updateClientSessionTabLayout(
            client_id,
            msg.tab_uuid,
            msg.active_tab,
            if (msg.has_focused_pane != 0) msg.focused_pane_uuid else null,
            buf[0..msg.root_len],
        ) catch {
            self.sendBinaryError(fd, "session_sync_tab_layout_failed");
            return;
        };
        wire.writeControl(fd, .ok, &.{}) catch {};
    }

    fn handleBinaryCreatePane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.CreatePane)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "create_pane: payload too small for CreatePane struct");
            return;
        }
        const cp = wire.readStruct(wire.CreatePane, fd) catch return;
        const trail_len = payload_len - @sizeOf(wire.CreatePane);

        // Read trailing: shell + cwd + sticky_pwd.
        if (trail_len > buf.len) {
            self.skipBinaryPayload(fd, trail_len, buf);
            self.sendBinaryError(fd, "payload_too_large");
            return;
        }
        if (trail_len > 0) {
            wire.readExact(fd, buf[0..trail_len]) catch return;
        }

        ses.debugLog("create_pane: shell_len={d} cwd_len={d} sticky_key={d} isolation_profile_len={d}", .{ cp.shell_len, cp.cwd_len, cp.sticky_key, cp.isolation_profile_len });

        var offset: usize = 0;
        const shell = if (cp.shell_len > 0 and offset + cp.shell_len <= trail_len) blk: {
            const s = buf[offset .. offset + cp.shell_len];
            offset += cp.shell_len;
            break :blk s;
        } else blk: {
            break :blk @as([]const u8, std.posix.getenv("SHELL") orelse "/bin/sh");
        };
        const cwd: ?[]const u8 = if (cp.cwd_len > 0 and offset + cp.cwd_len <= trail_len) blk: {
            const c = buf[offset .. offset + cp.cwd_len];
            offset += cp.cwd_len;
            break :blk c;
        } else null;
        const sticky_pwd: ?[]const u8 = if (cp.sticky_pwd_len > 0 and offset + cp.sticky_pwd_len <= trail_len) blk: {
            const p = buf[offset .. offset + cp.sticky_pwd_len];
            offset += cp.sticky_pwd_len;
            break :blk p;
        } else null;
        const isolation_profile: ?[]const u8 = if (cp.isolation_profile_len > 0 and offset + cp.isolation_profile_len <= trail_len) blk: {
            const p = buf[offset .. offset + cp.isolation_profile_len];
            offset += cp.isolation_profile_len;
            break :blk p;
        } else null;
        const inherit_env_parent_uuid: ?[32]u8 = if (cp.inherit_env_parent_uuid_len == 32 and offset + 32 <= trail_len) blk: {
            var uuid: [32]u8 = undefined;
            @memcpy(&uuid, buf[offset .. offset + 32]);
            offset += 32;
            break :blk uuid;
        } else null;
        const sticky_key: ?u8 = if (cp.sticky_key != 0) cp.sticky_key else null;

        // Resolve parent environment if inherit_env was requested.
        var parent_env: ?[]const []const u8 = null;
        defer if (parent_env) |env_entries| {
            for (env_entries) |e| self.allocator.free(e);
            self.allocator.free(env_entries);
        };
        if (inherit_env_parent_uuid) |parent_uuid| {
            if (self.ses_state.getPane(parent_uuid)) |parent_pane| {
                parent_env = parent_pane.getProcEnviron(self.allocator);
            }
        }

        const client_id = self.findClientForCtlFd(fd) orelse blk: {
            const cid = self.ses_state.addClient(fd) catch {
                self.sendBinaryError(fd, "client_add_failed");
                return;
            };
            break :blk cid;
        };

        // Sticky/per-cwd pane reuse: if a matching sticky pane already exists,
        // attach/take over it instead of spawning a new pod.
        if (sticky_pwd) |pwd| {
            if (sticky_key) |key| {
                const preferred_session = if (self.ses_state.getClient(client_id)) |client|
                    client.session_name
                else
                    null;

                if (self.ses_state.findStickyPaneWithAffinity(pwd, key, preferred_session)) |existing| {
                    if (existing.attached_to) |owner_id| {
                        if (owner_id != client_id) {
                            _ = self.ses_state.stealAttachedPane(existing.uuid, client_id);
                            _ = self.ses_state.attachPane(existing.uuid, client_id) catch {
                                self.sendBinaryError(fd, "attach_existing_failed");
                                return;
                            };
                        }
                    } else {
                        _ = self.ses_state.attachPane(existing.uuid, client_id) catch {
                            self.sendBinaryError(fd, "attach_existing_failed");
                            return;
                        };
                    }

                    // Force backlog replay for fresh renderer state in the new mux.
                    if (self.ses_state.getPane(existing.uuid)) |p| {
                        p.needs_backlog_replay = true;
                    }

                    self.ses_state.markDirty();
                    var existing_resp = wire.PaneCreated{
                        .uuid = existing.uuid,
                        .pid = existing.child_pid,
                        .pane_id = existing.pane_id,
                        .socket_path_len = @intCast(existing.pod_socket_path.len),
                    };
                    wire.writeControlWithTrail(fd, .pane_created, std.mem.asBytes(&existing_resp), existing.pod_socket_path) catch {};
                    return;
                }
            }
        }

        const pane = self.ses_state.createPane(client_id, shell, cwd, sticky_pwd, sticky_key, parent_env, isolation_profile) catch {
            self.sendBinaryError(fd, "create_failed");
            return;
        };
        self.ses_state.markDirty();
        ses.debugLog("binary: pane created {s} (pid={d}, pane_id={d})", .{ pane.uuid[0..8], pane.child_pid, pane.pane_id });

        // Send PaneCreated response.
        var resp = wire.PaneCreated{
            .uuid = pane.uuid,
            .pid = pane.child_pid,
            .pane_id = pane.pane_id,
            .socket_path_len = @intCast(pane.pod_socket_path.len),
        };
        wire.writeControlWithTrail(fd, .pane_created, std.mem.asBytes(&resp), pane.pod_socket_path) catch {};
    }

    fn handleBinaryFindSticky(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.FindSticky)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            wire.writeControl(fd, .pane_not_found, &.{}) catch {};
            return;
        }
        const fs = wire.readStruct(wire.FindSticky, fd) catch return;
        if (fs.pwd_len > buf.len) {
            self.skipBinaryPayload(fd, fs.pwd_len, buf);
            wire.writeControl(fd, .pane_not_found, &.{}) catch {};
            return;
        }
        if (fs.pwd_len > 0) {
            wire.readExact(fd, buf[0..fs.pwd_len]) catch return;
        }
        const pwd = buf[0..fs.pwd_len];

        const client_id = self.findClientForCtlFd(fd) orelse {
            wire.writeControl(fd, .pane_not_found, &.{}) catch {};
            return;
        };

        // Get session name for affinity preference
        const preferred_session = if (self.ses_state.getClient(client_id)) |client|
            client.session_name
        else
            null;

        if (self.ses_state.findStickyPaneWithAffinity(pwd, fs.key, preferred_session)) |pane| {
            if (pane.attached_to) |owner_id| {
                if (owner_id != client_id) {
                    _ = self.ses_state.stealAttachedPane(pane.uuid, client_id);
                }
            }

            _ = self.ses_state.attachPane(pane.uuid, client_id) catch {
                wire.writeControl(fd, .pane_not_found, &.{}) catch {};
                return;
            };

            // New mux needs a full screen restore for sticky adoption/takeover.
            if (self.ses_state.getPane(pane.uuid)) |p| {
                p.needs_backlog_replay = true;
            }
            // Try replay immediately (periodic retry remains as fallback).
            self.ses_state.processBacklogReplays();

            var resp = wire.PaneFound{
                .uuid = pane.uuid,
                .pid = pane.child_pid,
                .pane_id = pane.pane_id,
                .socket_path_len = @intCast(pane.pod_socket_path.len),
            };
            wire.writeControlWithTrail(fd, .pane_found, std.mem.asBytes(&resp), pane.pod_socket_path) catch {};
        } else {
            wire.writeControl(fd, .pane_not_found, &.{}) catch {};
        }
    }

    fn handleBinaryOrphanPane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.PaneUuid)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const pu = wire.readStruct(wire.PaneUuid, fd) catch return;
        self.ses_state.suspendPane(pu.uuid) catch {};
        self.ses_state.markDirty();
        wire.writeControl(fd, .ok, &.{}) catch {};
    }

    fn handleBinaryAdoptPane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.PaneUuid)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "adopt_pane: payload too small for PaneUuid");
            return;
        }
        const pu = wire.readStruct(wire.PaneUuid, fd) catch return;

        const client_id = self.findClientForCtlFd(fd) orelse {
            self.sendBinaryError(fd, "adopt_pane: client not registered");
            return;
        };

        const pane = self.ses_state.attachPane(pu.uuid, client_id) catch {
            self.sendBinaryError(fd, "adopt_pane: pane not found or already attached");
            return;
        };

        // Adopt into a fresh mux view: force backlog replay so screen state
        // is restored immediately instead of waiting for new output.
        pane.needs_backlog_replay = true;
        self.ses_state.processBacklogReplays();

        self.ses_state.markDirty();

        var resp = wire.PaneFound{
            .uuid = pane.uuid,
            .pid = pane.child_pid,
            .pane_id = pane.pane_id,
            .socket_path_len = @intCast(pane.pod_socket_path.len),
        };
        wire.writeControlWithTrail(fd, .pane_found, std.mem.asBytes(&resp), pane.pod_socket_path) catch {};
    }

    fn handleBinaryKillPane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.PaneUuid)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const pu = wire.readStruct(wire.PaneUuid, fd) catch return;
        const hex_uuid: [32]u8 = std.fmt.bytesToHex(pu.uuid[0..16], .lower);
        ses.debugLog("handleBinaryKillPane: uuid={s} ctl_fd={d}", .{ hex_uuid[0..8], fd });
        self.ses_state.killPane(pu.uuid) catch |e| {
            ses.debugLog("handleBinaryKillPane: killPane error: {s}", .{@errorName(e)});
        };
        self.ses_state.markDirty();
        ses.debugLog("handleBinaryKillPane: sending .ok response", .{});
        wire.writeControl(fd, .ok, &.{}) catch |e| {
            ses.debugLog("handleBinaryKillPane: writeControl .ok failed: {s}", .{@errorName(e)});
        };
        ses.debugLog("handleBinaryKillPane: done", .{});
    }

    fn handleBinarySetSticky(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.SetSticky)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const ss = wire.readStruct(wire.SetSticky, fd) catch return;
        if (ss.pwd_len > buf.len) {
            self.skipBinaryPayload(fd, ss.pwd_len, buf);
            return;
        }
        if (ss.pwd_len > 0) {
            wire.readExact(fd, buf[0..ss.pwd_len]) catch return;
        }

        if (self.ses_state.panes.getPtr(ss.uuid)) |pane| {
            if (pane.sticky_pwd) |old| self.allocator.free(old);
            if (pane.sticky_session_name) |old_ssn| self.allocator.free(old_ssn);

            pane.sticky_pwd = if (ss.pwd_len > 0) self.allocator.dupe(u8, buf[0..ss.pwd_len]) catch null else null;
            pane.sticky_key = if (ss.key != 0) ss.key else null;

            // Store session name for affinity
            const client_id = self.findClientForCtlFd(fd) orelse null;
            pane.sticky_session_name = if (client_id) |cid| blk: {
                if (self.ses_state.getClient(cid)) |client| {
                    if (client.session_name) |sn| {
                        break :blk self.allocator.dupe(u8, sn) catch null;
                    }
                }
                break :blk null;
            } else null;

            // set_sticky sets sticky metadata, but must not force attached panes
            // into sticky state. Sticky state is entered on suspend/disown.
            if (pane.sticky_pwd != null and pane.attached_to == null) {
                _ = pane.transitionState(.sticky, "set_sticky command");
            }
            self.ses_state.markDirty();
        }
        wire.writeControl(fd, .ok, &.{}) catch {};
    }

    fn handleBinaryGetPaneCwd(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.GetPaneCwd)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const gpc = wire.readStruct(wire.GetPaneCwd, fd) catch return;

        if (self.ses_state.getPane(gpc.uuid)) |pane| {
            const cwd = pane.getProcCwd();
            if (cwd) |c| {
                var resp = wire.PaneCwd{ .cwd_len = @intCast(c.len) };
                wire.writeControlWithTrail(fd, .get_pane_cwd, std.mem.asBytes(&resp), c) catch {};
                return;
            }
        }
        // No CWD available.
        var resp = wire.PaneCwd{ .cwd_len = 0 };
        wire.writeControl(fd, .get_pane_cwd, std.mem.asBytes(&resp)) catch {};
    }

    fn handleBinaryListOrphaned(self: *Server, fd: posix.fd_t, buf: []u8) void {
        _ = buf;
        const orphaned = self.ses_state.getOrphanedPanes(self.allocator) catch {
            var resp = wire.OrphanedPanes{ .pane_count = 0 };
            wire.writeControl(fd, .orphaned_panes, std.mem.asBytes(&resp)) catch {};
            return;
        };
        defer self.allocator.free(orphaned);

        // Build response: OrphanedPanes header + pane_count * OrphanedPaneEntry.
        var resp_hdr = wire.OrphanedPanes{ .pane_count = @intCast(@min(orphaned.len, 32)) };
        const entry_count: usize = resp_hdr.pane_count;
        const total_len = @sizeOf(wire.OrphanedPanes) + entry_count * @sizeOf(wire.OrphanedPaneEntry);

        var hdr: wire.ControlHeader = .{
            .msg_type = @intFromEnum(wire.MsgType.orphaned_panes),
            .payload_len = @intCast(total_len),
        };
        wire.writeAll(fd, std.mem.asBytes(&hdr)) catch return;
        wire.writeAll(fd, std.mem.asBytes(&resp_hdr)) catch return;

        for (orphaned[0..entry_count]) |pane| {
            var entry = wire.OrphanedPaneEntry{
                .uuid = pane.uuid,
                .pid = pane.child_pid,
            };
            wire.writeAll(fd, std.mem.asBytes(&entry)) catch return;
        }
    }

    fn handleBinaryListSessions(self: *Server, fd: posix.fd_t, buf: []u8) void {
        _ = buf;
        const sessions = self.ses_state.listDetachedSessions(self.allocator) catch {
            var resp = wire.SessionsList{ .session_count = 0 };
            wire.writeControl(fd, .sessions_list, std.mem.asBytes(&resp)) catch {};
            return;
        };
        defer self.allocator.free(sessions);

        // Calculate total payload: SessionsList + entries + name strings.
        var total: usize = @sizeOf(wire.SessionsList);
        for (sessions) |s| {
            total += @sizeOf(wire.SessionEntry) + s.session_name.len;
        }

        var hdr: wire.ControlHeader = .{
            .msg_type = @intFromEnum(wire.MsgType.sessions_list),
            .payload_len = @intCast(total),
        };
        wire.writeAll(fd, std.mem.asBytes(&hdr)) catch return;

        var resp_hdr = wire.SessionsList{ .session_count = @intCast(sessions.len) };
        wire.writeAll(fd, std.mem.asBytes(&resp_hdr)) catch return;

        for (sessions) |s| {
            const hex_id: [32]u8 = std.fmt.bytesToHex(&s.session_id, .lower);
            var entry = wire.SessionEntry{
                .session_id = hex_id,
                .pane_count = @intCast(s.pane_count),
                .name_len = @intCast(s.session_name.len),
            };
            wire.writeAll(fd, std.mem.asBytes(&entry)) catch return;
            if (s.session_name.len > 0) {
                wire.writeAll(fd, s.session_name) catch return;
            }
        }
    }

    fn handleBinaryDetach(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.Detach)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "detach: payload too small for Detach header");
            return;
        }
        const det = wire.readStruct(wire.Detach, fd) catch return;
        if (det.state_len > wire.MAX_PAYLOAD_LEN) {
            self.skipBinaryPayload(fd, det.state_len, buf);
            self.sendBinaryError(fd, "detach: state too large (exceeds MAX_PAYLOAD_LEN)");
            return;
        }

        // Read mux state.
        const state_data = self.allocator.alloc(u8, det.state_len) catch {
            self.skipBinaryPayload(fd, det.state_len, buf);
            self.sendBinaryError(fd, "detach: memory allocation failed for state data");
            return;
        };
        defer self.allocator.free(state_data);
        wire.readExact(fd, state_data) catch return;

        // Convert session_id hex to binary.
        const session_id = core.uuid.hexToBin(det.session_id) orelse {
            self.sendBinaryError(fd, "detach: invalid session_id hex format");
            return;
        };

        const client_id = self.findClientForCtlFd(fd) orelse {
            self.sendBinaryError(fd, "detach: client not registered");
            return;
        };

        const session_name = if (self.ses_state.getClient(client_id)) |client|
            client.session_name orelse "unknown"
        else
            "unknown";

        // Acquire session lock to prevent concurrent reattach
        self.ses_state.acquireSessionLock(session_id, client_id, .detaching) catch {
            self.sendBinaryError(fd, "session_locked: another client is attaching this session");
            return;
        };
        // Lock will be released after detach completes

        if (self.ses_state.detachSession(client_id, session_id, session_name, state_data)) {
            self.ses_state.markDirty();
            // Release lock after successful detach
            self.ses_state.releaseSessionLock(session_id);
            wire.writeControl(fd, .session_detached, &.{}) catch {};
        } else {
            // Release lock on failure too
            self.ses_state.releaseSessionLock(session_id);
            self.sendBinaryError(fd, "detach_failed");
        }
    }

    fn handleBinaryReattach(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.Reattach)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "invalid_payload");
            return;
        }
        const ra = wire.readStruct(wire.Reattach, fd) catch return;
        if (ra.id_len > buf.len or ra.id_len == 0) {
            self.skipBinaryPayload(fd, ra.id_len, buf);
            self.sendBinaryError(fd, "invalid_id");
            return;
        }
        wire.readExact(fd, buf[0..ra.id_len]) catch return;
        const id_prefix = buf[0..ra.id_len];

        // Enforce minimum prefix length to avoid ambiguous matches
        if (id_prefix.len < 4) {
            self.sendBinaryError(fd, "prefix_too_short: provide at least 4 characters (UUID or session name)");
            return;
        }

        // Phase 1: Try UUID prefix match (most specific, unambiguous).
        // UUID matching takes priority over name matching.
        var uuid_matched_id: ?[16]u8 = null;
        var uuid_match_count: usize = 0;
        var ds_iter = self.ses_state.detached_sessions.iterator();
        while (ds_iter.next()) |entry| {
            const key_ptr = entry.key_ptr;
            const hex_id: [32]u8 = std.fmt.bytesToHex(key_ptr, .lower);
            if (std.mem.startsWith(u8, &hex_id, id_prefix)) {
                uuid_matched_id = key_ptr.*;
                uuid_match_count += 1;
            }
        }

        // If UUID matched uniquely, use it immediately (don't try name matching).
        if (uuid_match_count == 1) {
            const session_id = uuid_matched_id.?;
            const client_id = self.findClientForCtlFd(fd) orelse {
                self.sendBinaryError(fd, "no_client");
                return;
            };
            self.completeReattach(fd, session_id, client_id);
            return;
        }

        // If multiple UUID matches (very rare, but possible with short prefixes), report ambiguity.
        if (uuid_match_count > 1) {
            self.sendBinaryError(fd, "ambiguous_uuid_prefix: provide more characters");
            return;
        }

        // Phase 2: No detached UUID match, try exact DETACHED session name match.
        // Collect all matching detached sessions for disambiguation.
        var name_matches: [16]struct {
            session_id: [16]u8,
            name: []const u8,
        } = undefined;
        var name_match_count: usize = 0;

        ds_iter = self.ses_state.detached_sessions.iterator();
        while (ds_iter.next()) |entry| {
            const key_ptr = entry.key_ptr;
            const detached = entry.value_ptr;

            // Exact name match (case-insensitive).
            if (std.ascii.eqlIgnoreCase(detached.session_snapshot.session_name, id_prefix)) {
                if (name_match_count < name_matches.len) {
                    name_matches[name_match_count] = .{
                        .session_id = key_ptr.*,
                        .name = detached.session_snapshot.session_name,
                    };
                    name_match_count += 1;
                }
            }
        }

        if (name_match_count == 0) {
            // Phase 3: Session may be actively attached elsewhere.
            // If matched, force-detach owner and continue attach here.

            // 3a) UUID prefix among attached sessions.
            var attached_uuid_match: ?[16]u8 = null;
            var attached_uuid_count: usize = 0;
            for (self.ses_state.clients.items) |client| {
                if (client.session_id) |sid| {
                    const sid_hex: [32]u8 = std.fmt.bytesToHex(&sid, .lower);
                    if (std.mem.startsWith(u8, &sid_hex, id_prefix)) {
                        attached_uuid_match = sid;
                        attached_uuid_count += 1;
                    }
                }
            }

            if (attached_uuid_count == 1) {
                const session_id = attached_uuid_match.?;
                if (!self.ses_state.forceDetachAttachedSession(session_id)) {
                    self.sendBinaryError(fd, "reattach_failed");
                    return;
                }

                const client_id = self.findClientForCtlFd(fd) orelse {
                    self.sendBinaryError(fd, "no_client");
                    return;
                };
                self.completeReattach(fd, session_id, client_id);
                return;
            }

            if (attached_uuid_count > 1) {
                self.sendBinaryError(fd, "ambiguous_uuid_prefix: provide more characters");
                return;
            }

            // 3b) Exact attached session name match.
            var attached_name_matches: [16]struct {
                session_id: [16]u8,
                name: []const u8,
            } = undefined;
            var attached_name_count: usize = 0;

            for (self.ses_state.clients.items) |client| {
                const sid = client.session_id orelse continue;
                const sname = client.session_name orelse continue;
                if (std.ascii.eqlIgnoreCase(sname, id_prefix)) {
                    if (attached_name_count < attached_name_matches.len) {
                        attached_name_matches[attached_name_count] = .{
                            .session_id = sid,
                            .name = sname,
                        };
                        attached_name_count += 1;
                    }
                }
            }

            if (attached_name_count == 0) {
                self.sendBinaryError(fd, "session_not_found");
                return;
            }

            if (attached_name_count == 1) {
                const session_id = attached_name_matches[0].session_id;
                if (!self.ses_state.forceDetachAttachedSession(session_id)) {
                    self.sendBinaryError(fd, "reattach_failed");
                    return;
                }

                const client_id = self.findClientForCtlFd(fd) orelse {
                    self.sendBinaryError(fd, "no_client");
                    return;
                };
                self.completeReattach(fd, session_id, client_id);
                return;
            }

            var attached_err_buf: [512]u8 = undefined;
            var attached_stream = std.io.fixedBufferStream(&attached_err_buf);
            const attached_writer = attached_stream.writer();
            attached_writer.print("ambiguous: multiple sessions named '{s}'. Use UUID prefix:\n", .{id_prefix}) catch {};
            for (attached_name_matches[0..attached_name_count]) |match| {
                const hex_id = std.fmt.bytesToHex(&match.session_id, .lower);
                attached_writer.print("  {s} ({s})\n", .{ hex_id[0..8], match.name }) catch {};
            }
            self.sendBinaryError(fd, attached_stream.getWritten());
            return;
        }

        if (name_match_count == 1) {
            const session_id = name_matches[0].session_id;
            const client_id = self.findClientForCtlFd(fd) orelse {
                self.sendBinaryError(fd, "no_client");
                return;
            };
            self.completeReattach(fd, session_id, client_id);
            return;
        }

        // Multiple sessions with the same name - build disambiguation message.
        var err_buf: [512]u8 = undefined;
        var err_stream = std.io.fixedBufferStream(&err_buf);
        const writer = err_stream.writer();
        writer.print("ambiguous: multiple sessions named '{s}'. Use UUID prefix:\n", .{id_prefix}) catch {};
        for (name_matches[0..name_match_count]) |match| {
            const hex_id = std.fmt.bytesToHex(&match.session_id, .lower);
            writer.print("  {s} ({s})\n", .{ hex_id[0..8], match.name }) catch {};
        }
        self.sendBinaryError(fd, err_stream.getWritten());
    }

    /// Helper to complete reattach after session_id is resolved.
    fn completeReattach(self: *Server, fd: posix.fd_t, session_id: [16]u8, client_id: usize) void {
        // Transaction log: reattach start
        const hex_id: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
        self.ses_state.txlog.write(.reattach_start, session_id, &hex_id) catch {};

        // Acquire session lock to prevent concurrent reattach
        self.ses_state.acquireSessionLock(session_id, client_id, .attaching) catch {
            self.sendBinaryError(fd, "session_locked: another client is attaching this session");
            return;
        };
        // Note: Lock will be released in handleBinaryRegister after successful registration

        const result = self.ses_state.reattachSession(session_id, client_id) catch {
            self.ses_state.releaseSessionLock(session_id);
            self.sendBinaryError(fd, "reattach_failed");
            return;
        };
        if (result == null) {
            self.ses_state.releaseSessionLock(session_id);
            self.sendBinaryError(fd, "session_not_found");
            return;
        }
        const reattach_result = result.?;
        const session_json = reattach_result.session_snapshot.toJson(self.allocator) catch {
            self.ses_state.releaseSessionLock(session_id);
            self.sendBinaryError(fd, "reattach_snapshot_failed");
            return;
        };
        defer self.allocator.free(session_json);

        // Send SessionReattached: header + mux_state bytes + pane_count * 32 UUID bytes.
        var resp = wire.SessionReattached{
            .state_len = @intCast(session_json.len),
            .pane_count = @intCast(reattach_result.pane_uuids.len),
        };
        const uuid_data_len = reattach_result.pane_uuids.len * 32;
        const total_payload = @sizeOf(wire.SessionReattached) + session_json.len + uuid_data_len;

        var ctrl_hdr: wire.ControlHeader = .{
            .msg_type = @intFromEnum(wire.MsgType.session_reattached),
            .payload_len = @intCast(total_payload),
        };
        wire.writeAll(fd, std.mem.asBytes(&ctrl_hdr)) catch return;
        wire.writeAll(fd, std.mem.asBytes(&resp)) catch return;
        wire.writeAll(fd, session_json) catch return;
        for (reattach_result.pane_uuids) |uuid| {
            wire.writeAll(fd, &uuid) catch return;
        }
    }

    fn handleBinaryDisconnect(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.Disconnect)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const dc = wire.readStruct(wire.Disconnect, fd) catch return;
        const client_id = self.findClientForCtlFd(fd) orelse return;

        if (dc.mode == 0) { // shutdown
            self.ses_state.shutdownClient(client_id, dc.preserve_sticky != 0);
        } else {
            self.ses_state.removeClientGraceful(client_id);
        }
        wire.writeControl(fd, .ok, &.{}) catch {};
    }

    fn handleBinaryUpdatePaneName(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.UpdatePaneName)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const upn = wire.readStruct(wire.UpdatePaneName, fd) catch return;
        if (upn.name_len > wire.MAX_PAYLOAD_LEN or upn.name_len > buf.len) {
            self.skipBinaryPayload(fd, upn.name_len, buf);
            self.sendBinaryError(fd, "update_pane_name: name too large");
            return;
        }
        if (upn.name_len > 0) {
            wire.readExact(fd, buf[0..upn.name_len]) catch return;
        }

        if (self.ses_state.panes.getPtr(upn.uuid)) |pane| {
            if (pane.name) |old| self.allocator.free(old);
            pane.name = if (upn.name_len > 0) self.allocator.dupe(u8, buf[0..upn.name_len]) catch null else null;
            self.ses_state.markDirty();
        }
        wire.writeControl(fd, .ok, &.{}) catch {};
    }

    fn handleBinaryUpdatePaneAux(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.UpdatePaneAux)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const upa = wire.readStruct(wire.UpdatePaneAux, fd) catch return;
        const client_id = self.findClientForCtlFd(fd);

        if (self.ses_state.panes.getPtr(upa.uuid)) |pane| {
            if (upa.has_created_from != 0) {
                pane.created_from = upa.created_from;
            }
            if (upa.has_focused_from != 0) {
                pane.focused_from = upa.focused_from;
            }
            pane.is_focused = (upa.is_focused != 0);
            if (client_id) |cid| {
                self.ses_state.updateClientSessionFocus(
                    cid,
                    upa.uuid,
                    if (upa.has_active_tab != 0) upa.active_tab else null,
                    upa.is_focused != 0,
                );
            }
            self.ses_state.markDirty();
        }
        wire.writeControl(fd, .ok, &.{}) catch {};
    }

    fn handleBinaryUpdatePaneShell(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.UpdatePaneShell)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const ups = wire.readStruct(wire.UpdatePaneShell, fd) catch return;
        const trail_len = payload_len - @sizeOf(wire.UpdatePaneShell);
        if (trail_len > wire.MAX_PAYLOAD_LEN or trail_len > buf.len) {
            self.skipBinaryPayload(fd, trail_len, buf);
            self.sendBinaryError(fd, "update_pane_shell: payload too large");
            return;
        }
        if (trail_len > 0) {
            wire.readExact(fd, buf[0..trail_len]) catch return;
        }

        var offset: usize = 0;
        const cmd: ?[]const u8 = if (ups.cmd_len > 0 and offset + ups.cmd_len <= trail_len) blk: {
            const c = buf[offset .. offset + ups.cmd_len];
            offset += ups.cmd_len;
            break :blk c;
        } else null;
        const cwd: ?[]const u8 = if (ups.cwd_len > 0 and offset + ups.cwd_len <= trail_len) blk: {
            const c = buf[offset .. offset + ups.cwd_len];
            offset += ups.cwd_len;
            break :blk c;
        } else null;

        if (self.ses_state.panes.getPtr(ups.uuid)) |pane| {
            if (ups.has_status != 0) pane.last_status = ups.status;
            if (cmd) |c| {
                if (pane.last_cmd) |old| self.allocator.free(old);
                pane.last_cmd = self.allocator.dupe(u8, c) catch null;
            }
            if (cwd) |c| {
                if (pane.cwd) |old| self.allocator.free(old);
                pane.cwd = self.allocator.dupe(u8, c) catch null;
            }
            self.ses_state.markDirty();
        }
        wire.writeControl(fd, .ok, &.{}) catch {};
    }

    fn handleBinaryPopResponse(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.PopResponse)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const pr = wire.readStruct(wire.PopResponse, fd) catch return;

        // Find the CLI fd waiting for this response.
        const cli_fd = self.pending_pop_requests.fetchRemove(fd);
        if (cli_fd) |kv| {
            wire.writeControl(kv.value, .pop_response, std.mem.asBytes(&pr)) catch {};
            posix.close(kv.value);
        }
    }

    fn handleBinaryCwdChanged(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.CwdChanged)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const cc = wire.readStruct(wire.CwdChanged, fd) catch return;
        if (cc.cwd_len > wire.MAX_PAYLOAD_LEN or cc.cwd_len > buf.len) {
            self.skipBinaryPayload(fd, cc.cwd_len, buf);
            self.sendBinaryError(fd, "cwd_changed: path too large");
            return;
        }
        if (cc.cwd_len > 0) {
            wire.readExact(fd, buf[0..cc.cwd_len]) catch return;
        }

        if (self.ses_state.panes.getPtr(cc.uuid)) |pane| {
            ses.debugLog("cwd_changed: uuid={s} cwd={s}", .{ cc.uuid[0..8], if (cc.cwd_len > 0) buf[0..cc.cwd_len] else "(empty)" });
            if (pane.cwd) |old| self.allocator.free(old);
            pane.cwd = if (cc.cwd_len > 0) self.allocator.dupe(u8, buf[0..cc.cwd_len]) catch null else null;
            self.ses_state.markDirty();
        }
    }

    fn handleBinaryFgChanged(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.FgChanged)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const fc = wire.readStruct(wire.FgChanged, fd) catch return;
        if (fc.name_len > wire.MAX_PAYLOAD_LEN or fc.name_len > buf.len) {
            self.skipBinaryPayload(fd, fc.name_len, buf);
            self.sendBinaryError(fd, "fg_changed: name too large");
            return;
        }
        if (fc.name_len > 0) {
            wire.readExact(fd, buf[0..fc.name_len]) catch return;
        }

        if (self.ses_state.panes.getPtr(fc.uuid)) |pane| {
            ses.debugLog("fg_changed: uuid={s} pid={d} name={s}", .{ fc.uuid[0..8], fc.pid, if (fc.name_len > 0) buf[0..fc.name_len] else "(empty)" });
            pane.fg_pid = fc.pid;
            if (pane.fg_process) |old| self.allocator.free(old);
            pane.fg_process = if (fc.name_len > 0) self.allocator.dupe(u8, buf[0..fc.name_len]) catch null else null;
            self.ses_state.markDirty();
        }
    }

    fn handleBinaryShellEvent(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.ShpShellEvent)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const ev = wire.readStruct(wire.ShpShellEvent, fd) catch return;
        const trail_len = payload_len - @sizeOf(wire.ShpShellEvent);
        if (trail_len > wire.MAX_PAYLOAD_LEN or trail_len > buf.len) {
            self.skipBinaryPayload(fd, trail_len, buf);
            return;
        }
        if (trail_len > 0) {
            wire.readExact(fd, buf[0..trail_len]) catch return;
        }

        // Identify pane by pod_ctl_fd.
        var pane_uuid: ?[32]u8 = null;
        var pane_iter = self.ses_state.panes.iterator();
        while (pane_iter.next()) |entry| {
            if (entry.value_ptr.pod_ctl_fd) |ctl_fd| {
                if (ctl_fd == fd) {
                    pane_uuid = entry.key_ptr.*;
                    break;
                }
            }
        }
        const uuid = pane_uuid orelse return;
        ses.debugLog("shell_event: uuid={s} phase={d} status={d}", .{ uuid[0..8], ev.phase, ev.status });

        // Forward to MUX as ForwardedShellEvent.
        var fwd = wire.ForwardedShellEvent{
            .uuid = uuid,
            .phase = ev.phase,
            .status = ev.status,
            .duration_ms = ev.duration_ms,
            .started_at = ev.started_at,
            .jobs = ev.jobs,
            .running = ev.running,
            .cmd_len = ev.cmd_len,
            .cwd_len = ev.cwd_len,
        };

        // Find the MUX CTL fd for this pane's owning client.
        if (self.ses_state.panes.get(uuid)) |pane| {
            if (pane.attached_to) |client_id| {
                if (self.ses_state.getClient(client_id)) |client| {
                    if (client.mux_ctl_fd) |mux_fd| {
                        const trails: []const []const u8 = &.{buf[0..trail_len]};
                        wire.writeControlMsg(mux_fd, .shell_event, std.mem.asBytes(&fwd), trails) catch {};
                    }
                }
            }
        }
    }

    fn handleBinaryExited(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.Exited)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const ex = wire.readStruct(wire.Exited, fd) catch return;

        if (self.ses_state.panes.getPtr(ex.uuid)) |pane| {
            pane.last_status = ex.status;
            // Notify owning mux immediately so it can tear down dead pane UI.
            if (pane.attached_to) |client_id| {
                if (self.ses_state.getClient(client_id)) |client| {
                    if (client.mux_ctl_fd) |ctl_fd| {
                        var msg = wire.PaneUuid{ .uuid = ex.uuid };
                        wire.writeControl(ctl_fd, .pane_exited, std.mem.asBytes(&msg)) catch {};
                    }
                }
            }
        }

        // Fully remove dead pane from SES routing/state so sticky/adopt lookup
        // cannot return a process that already exited.
        self.ses_state.killPane(ex.uuid) catch {};
        self.ses_state.markDirty();
    }

    /// Handle a CLI tool request (handshake byte 0x04).
    /// CLI sends one control message; SES forwards to MUX and optionally waits for response.
    fn handleCliRequest(self: *Server, fd: posix.fd_t) void {
        const hdr = wire.readControlHeader(fd) catch {
            posix.close(fd);
            return;
        };
        const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        ses.debugLog("cli req: type=0x{x:0>4} len={d} fd={d}", .{ hdr.msg_type, hdr.payload_len, fd });
        var buf: [65536]u8 = undefined;

        switch (msg_type) {
            .focus_move => {
                if (hdr.payload_len < @sizeOf(wire.FocusMove)) {
                    posix.close(fd);
                    return;
                }
                const fm = wire.readStruct(wire.FocusMove, fd) catch {
                    posix.close(fd);
                    return;
                };
                // Find MUX ctl fd for this pane's session.
                const mux_fd = self.findMuxCtlForUuid(fm.uuid) orelse {
                    posix.close(fd);
                    return;
                };
                // Forward to MUX.
                wire.writeControl(mux_fd, .focus_move, std.mem.asBytes(&fm)) catch {};
                posix.close(fd);
            },
            .exit_intent => {
                if (hdr.payload_len < @sizeOf(wire.ExitIntent)) {
                    posix.close(fd);
                    return;
                }
                const ei = wire.readStruct(wire.ExitIntent, fd) catch {
                    posix.close(fd);
                    return;
                };
                // Find MUX ctl fd.
                const mux_fd = self.findMuxCtlForUuid(ei.uuid) orelse {
                    // No MUX — allow exit.
                    const allow = wire.ExitIntentResult{ .allow = 1 };
                    wire.writeControl(fd, .exit_intent_result, std.mem.asBytes(&allow)) catch {};
                    posix.close(fd);
                    return;
                };
                // Close any previous pending exit_intent CLI fd.
                if (self.pending_exit_intent_cli_fd) |old_fd| posix.close(old_fd);
                self.pending_exit_intent_cli_fd = fd;
                // Forward to MUX.
                wire.writeControl(mux_fd, .exit_intent, std.mem.asBytes(&ei)) catch {
                    // If forward fails, allow exit.
                    const allow = wire.ExitIntentResult{ .allow = 1 };
                    wire.writeControl(fd, .exit_intent_result, std.mem.asBytes(&allow)) catch {};
                    posix.close(fd);
                    self.pending_exit_intent_cli_fd = null;
                };
            },
            .float_request => {
                if (hdr.payload_len < @sizeOf(wire.FloatRequest)) {
                    posix.close(fd);
                    return;
                }
                const payload_len = hdr.payload_len;
                const fr = wire.readStruct(wire.FloatRequest, fd) catch {
                    posix.close(fd);
                    return;
                };
                // Read trailing data.
                const trail_len = payload_len - @sizeOf(wire.FloatRequest);
                if (trail_len > buf.len) {
                    posix.close(fd);
                    return;
                }
                if (trail_len > 0) {
                    wire.readExact(fd, buf[0..trail_len]) catch {
                        posix.close(fd);
                        return;
                    };
                }
                // Find the MUX for the source session (or fallback to any MUX).
                const mux_fd = self.findMuxCtlForSessionId(fr.source_session_id) orelse {
                    self.sendBinaryError(fd, "no_mux");
                    posix.close(fd);
                    return;
                };
                // Forward entire float_request to MUX.
                wire.writeControlWithTrail(mux_fd, .float_request, std.mem.asBytes(&fr), buf[0..trail_len]) catch {
                    self.sendBinaryError(fd, "forward_failed");
                    posix.close(fd);
                    return;
                };
                // Store CLI fd — MUX will respond with float_created or float_result.
                // We'll use a placeholder UUID (zeroed) until float_created gives us the real one.
                // For now, keep the fd in a temporary spot. When MUX sends float_created,
                // we move it to pending_float_cli_fds keyed by UUID.
                // Use a simple approach: store as pending with zeroed UUID.
                const zero_uuid: [32]u8 = .{0} ** 32;
                self.pending_float_cli_fds.put(zero_uuid, fd) catch {
                    self.sendBinaryError(fd, "track_failed");
                    posix.close(fd);
                };
            },
            .notify => {
                // Forward notify to MUX.
                if (hdr.payload_len > buf.len) {
                    posix.close(fd);
                    return;
                }
                if (hdr.payload_len > 0) {
                    wire.readExact(fd, buf[0..hdr.payload_len]) catch {
                        posix.close(fd);
                        return;
                    };
                }
                const mux_fd = self.findAnyMuxCtl() orelse {
                    posix.close(fd);
                    return;
                };
                wire.writeControl(mux_fd, .notify, buf[0..hdr.payload_len]) catch {};
                posix.close(fd);
            },
            .send_keys => {
                if (hdr.payload_len < @sizeOf(wire.SendKeys)) {
                    posix.close(fd);
                    return;
                }
                if (hdr.payload_len > buf.len) {
                    posix.close(fd);
                    return;
                }
                wire.readExact(fd, buf[0..hdr.payload_len]) catch {
                    posix.close(fd);
                    return;
                };
                const sk = wire.bytesToStruct(wire.SendKeys, buf[0..hdr.payload_len]) orelse {
                    posix.close(fd);
                    return;
                };
                const zero_uuid: [32]u8 = .{0} ** 32;
                const mux_fd = if (std.mem.eql(u8, &sk.uuid, &zero_uuid))
                    self.findAnyMuxCtl()
                else
                    self.findMuxCtlForUuid(sk.uuid) orelse self.findAnyMuxCtl();
                if (mux_fd) |mfd| {
                    wire.writeControl(mfd, .send_keys, buf[0..hdr.payload_len]) catch {};
                }
                posix.close(fd);
            },
            .targeted_notify => {
                if (hdr.payload_len < @sizeOf(wire.TargetedNotify)) {
                    posix.close(fd);
                    return;
                }
                if (hdr.payload_len > buf.len) {
                    posix.close(fd);
                    return;
                }
                wire.readExact(fd, buf[0..hdr.payload_len]) catch {
                    posix.close(fd);
                    return;
                };
                const tn = wire.bytesToStruct(wire.TargetedNotify, buf[0..hdr.payload_len]) orelse {
                    posix.close(fd);
                    return;
                };
                const mux_fd = self.findMuxCtlForUuid(tn.uuid) orelse self.findAnyMuxCtl();
                if (mux_fd) |mfd| {
                    wire.writeControl(mfd, .targeted_notify, buf[0..hdr.payload_len]) catch {};
                }
                posix.close(fd);
            },
            .broadcast_notify => {
                if (hdr.payload_len > buf.len) {
                    posix.close(fd);
                    return;
                }
                if (hdr.payload_len > 0) {
                    wire.readExact(fd, buf[0..hdr.payload_len]) catch {
                        posix.close(fd);
                        return;
                    };
                }
                // Forward to all connected MUX clients.
                for (self.ses_state.clients.items) |*client| {
                    if (client.mux_ctl_fd) |mfd| {
                        wire.writeControl(mfd, .notify, buf[0..hdr.payload_len]) catch {};
                    }
                }
                posix.close(fd);
            },
            .pop_confirm => {
                if (hdr.payload_len < @sizeOf(wire.PopConfirm)) {
                    posix.close(fd);
                    return;
                }
                if (hdr.payload_len > buf.len) {
                    posix.close(fd);
                    return;
                }
                wire.readExact(fd, buf[0..hdr.payload_len]) catch {
                    posix.close(fd);
                    return;
                };
                const pc = wire.bytesToStruct(wire.PopConfirm, buf[0..hdr.payload_len]) orelse {
                    posix.close(fd);
                    return;
                };
                const zero_uuid: [32]u8 = .{0} ** 32;
                const mux_fd = if (std.mem.eql(u8, &pc.uuid, &zero_uuid))
                    self.findAnyMuxCtl()
                else
                    self.findMuxCtlForUuid(pc.uuid) orelse self.findAnyMuxCtl();
                if (mux_fd) |mfd| {
                    wire.writeControl(mfd, .pop_confirm, buf[0..hdr.payload_len]) catch {};
                    self.pending_pop_requests.put(mfd, fd) catch {
                        posix.close(fd);
                    };
                } else {
                    posix.close(fd);
                }
            },
            .pop_choose => {
                if (hdr.payload_len < @sizeOf(wire.PopChoose)) {
                    posix.close(fd);
                    return;
                }
                if (hdr.payload_len > buf.len) {
                    posix.close(fd);
                    return;
                }
                wire.readExact(fd, buf[0..hdr.payload_len]) catch {
                    posix.close(fd);
                    return;
                };
                const pch = wire.bytesToStruct(wire.PopChoose, buf[0..hdr.payload_len]) orelse {
                    posix.close(fd);
                    return;
                };
                const zero_uuid: [32]u8 = .{0} ** 32;
                const mux_fd = if (std.mem.eql(u8, &pch.uuid, &zero_uuid))
                    self.findAnyMuxCtl()
                else
                    self.findMuxCtlForUuid(pch.uuid) orelse self.findAnyMuxCtl();
                if (mux_fd) |mfd| {
                    wire.writeControl(mfd, .pop_choose, buf[0..hdr.payload_len]) catch {};
                    self.pending_pop_requests.put(mfd, fd) catch {
                        posix.close(fd);
                    };
                } else {
                    posix.close(fd);
                }
            },
            .pane_info => {
                if (hdr.payload_len < @sizeOf(wire.PaneUuid)) {
                    posix.close(fd);
                    return;
                }
                const pu = wire.readStruct(wire.PaneUuid, fd) catch {
                    posix.close(fd);
                    return;
                };
                self.handleBinaryPaneInfo(fd, pu.uuid);
                posix.close(fd);
            },
            .status => {
                // Payload is 1 byte: full_mode flag (0 or 1).
                var full_mode: bool = false;
                if (hdr.payload_len >= 1) {
                    var flag: [1]u8 = undefined;
                    wire.readExact(fd, &flag) catch {
                        posix.close(fd);
                        return;
                    };
                    full_mode = (flag[0] != 0);
                    // Skip any remaining bytes.
                    if (hdr.payload_len > 1) {
                        self.skipBinaryPayload(fd, hdr.payload_len - 1, &buf);
                    }
                }
                self.handleBinaryStatus(fd, full_mode);
            },
            .kill_session => {
                self.handleKillSession(fd, hdr.payload_len, &buf);
            },
            .clear_sessions => {
                self.handleClearSessions(fd);
            },
            .clear_orphaned_panes => {
                self.handleClearOrphanedPanes(fd);
            },
            .get_layout => {
                self.handleGetLayout(fd, hdr.payload_len, &buf);
            },
            .apply_layout => {
                self.handleApplyLayout(fd, hdr.payload_len, &buf);
            },
            .get_session_state => {
                self.handleGetSessionState(fd, hdr.payload_len, &buf);
            },
            else => {
                self.skipBinaryPayload(fd, hdr.payload_len, &buf);
                posix.close(fd);
            },
        }
    }

    /// Handle exit_intent_result from MUX — forward to waiting CLI.
    fn handleBinaryExitIntentResult(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.ExitIntentResult)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const result = wire.readStruct(wire.ExitIntentResult, fd) catch return;
        if (self.pending_exit_intent_cli_fd) |cli_fd| {
            wire.writeControl(cli_fd, .exit_intent_result, std.mem.asBytes(&result)) catch {};
            posix.close(cli_fd);
            self.pending_exit_intent_cli_fd = null;
        }
    }

    /// Handle float_result from MUX — forward to waiting CLI.
    fn handleBinaryFloatResult(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.FloatResult)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const result = wire.readStruct(wire.FloatResult, fd) catch return;
        const trail_len = payload_len - @sizeOf(wire.FloatResult);

        // Find CLI fd by UUID.
        var cli_fd: ?posix.fd_t = null;
        if (self.pending_float_cli_fds.fetchRemove(result.uuid)) |entry| {
            cli_fd = entry.value;
        } else {
            // Try zero UUID (pending assignment).
            const zero_uuid: [32]u8 = .{0} ** 32;
            if (self.pending_float_cli_fds.fetchRemove(zero_uuid)) |entry| {
                cli_fd = entry.value;
            }
        }

        if (cli_fd) |cfd| {
            // Forward the full message to CLI.
            if (trail_len > 0 and trail_len <= buf.len) {
                wire.readExact(fd, buf[0..trail_len]) catch {
                    posix.close(cfd);
                    return;
                };
                wire.writeControlWithTrail(cfd, .float_result, std.mem.asBytes(&result), buf[0..trail_len]) catch {};
            } else {
                wire.writeControl(cfd, .float_result, std.mem.asBytes(&result)) catch {};
                if (trail_len > 0) self.skipBinaryPayload(fd, @intCast(trail_len), buf);
            }
            posix.close(cfd);
        } else {
            // No CLI waiting — skip trailing data.
            if (trail_len > 0) self.skipBinaryPayload(fd, @intCast(trail_len), buf);
        }
    }

    /// Handle binary pane_info query — respond with PaneInfoResp.
    /// Does NOT close the fd — caller is responsible for closing if needed.
    fn handleBinaryPaneInfo(self: *Server, fd: posix.fd_t, uuid: [32]u8) void {
        ses.debugLog("pane_info: uuid={s} fd={d}", .{ uuid[0..8], fd });
        const pane = self.ses_state.panes.get(uuid) orelse {
            ses.debugLog("pane_info: not found", .{});
            wire.writeControl(fd, .pane_not_found, &.{}) catch {};
            return;
        };

        var resp: wire.PaneInfoResp = .{
            .uuid = uuid,
            .pid = pane.child_pid,
            .fg_pid = pane.fg_pid orelse pane.child_pid,
            .base_pid = pane.child_pid,
            .cols = pane.cols,
            .rows = pane.rows,
            .cursor_x = pane.cursor_x,
            .cursor_y = pane.cursor_y,
            .cursor_style = pane.cursor_style,
            .cursor_visible = @intFromBool(pane.cursor_visible),
            .alt_screen = @intFromBool(pane.alt_screen),
            .is_focused = @intFromBool(pane.is_focused),
            .pane_type = @intFromEnum(pane.pane_type),
            .state = @intFromEnum(pane.state),
            .last_status = if (pane.last_status) |s| s else 0,
            .has_last_status = @intFromBool(pane.last_status != null),
            .last_duration_ms = if (pane.last_duration_ms) |d| @intCast(d) else 0,
            .has_last_duration = @intFromBool(pane.last_duration_ms != null),
            .last_jobs = pane.last_jobs orelse 0,
            .has_last_jobs = @intFromBool(pane.last_jobs != null),
            .created_at = pane.created_at,
            .sticky_key = pane.sticky_key orelse 0,
            .has_sticky_key = @intFromBool(pane.sticky_key != null),
            .created_from = .{0} ** 32,
            .focused_from = .{0} ** 32,
            .has_created_from = 0,
            .has_focused_from = 0,
            .name_len = 0,
            .fg_len = 0,
            .cwd_len = 0,
            .tty_len = 0,
            .socket_path_len = 0,
            .session_name_len = 0,
            .layout_path_len = 0,
            .last_cmd_len = 0,
            .base_process_len = 0,
            .sticky_pwd_len = 0,
        };

        if (pane.created_from) |cf| {
            resp.created_from = cf;
            resp.has_created_from = 1;
        }
        if (pane.focused_from) |ff| {
            resp.focused_from = ff;
            resp.has_focused_from = 1;
        }

        // Gather trailing data in order: name, fg, cwd, tty, socket, session_name, layout, last_cmd, base_proc, sticky_pwd
        var trail_buf: [8192]u8 = undefined;
        var trail_len: usize = 0;

        // Name
        if (pane.name) |name| {
            ses.debugLog("pane_info: sending name='{s}' len={d}", .{ name, name.len });
            const n = @min(name.len, trail_buf.len - trail_len);
            @memcpy(trail_buf[trail_len .. trail_len + n], name[0..n]);
            resp.name_len = @intCast(n);
            trail_len += n;
        }

        // Foreground process
        if (pane.getProcForegroundProcess()) |fg| {
            const n = @min(fg.name.len, trail_buf.len - trail_len);
            @memcpy(trail_buf[trail_len .. trail_len + n], fg.name[0..n]);
            resp.fg_len = @intCast(n);
            resp.fg_pid = fg.pid;
            trail_len += n;
        } else if (pane.fg_process) |proc| {
            const n = @min(proc.len, trail_buf.len - trail_len);
            @memcpy(trail_buf[trail_len .. trail_len + n], proc[0..n]);
            resp.fg_len = @intCast(n);
            trail_len += n;
        }

        // CWD
        const cwd = pane.getProcCwd() orelse pane.cwd;
        if (cwd) |c| {
            const n = @min(c.len, trail_buf.len - trail_len);
            @memcpy(trail_buf[trail_len .. trail_len + n], c[0..n]);
            resp.cwd_len = @intCast(n);
            trail_len += n;
        }

        // TTY
        if (pane.getProcTty()) |tty| {
            const n = @min(tty.len, trail_buf.len - trail_len);
            @memcpy(trail_buf[trail_len .. trail_len + n], tty[0..n]);
            resp.tty_len = @intCast(n);
            trail_len += n;
        }

        // Socket path
        {
            const sp = pane.pod_socket_path;
            const n = @min(sp.len, trail_buf.len - trail_len);
            @memcpy(trail_buf[trail_len .. trail_len + n], sp[0..n]);
            resp.socket_path_len = @intCast(n);
            trail_len += n;
        }

        // Session name (from attached client)
        if (pane.attached_to) |client_id| {
            if (self.ses_state.getClient(client_id)) |client| {
                if (client.session_name) |sn| {
                    const n = @min(sn.len, trail_buf.len - trail_len);
                    @memcpy(trail_buf[trail_len .. trail_len + n], sn[0..n]);
                    resp.session_name_len = @intCast(n);
                    trail_len += n;
                }
            }
        }

        // Layout path
        if (pane.layout_path) |path| {
            const n = @min(path.len, trail_buf.len - trail_len);
            @memcpy(trail_buf[trail_len .. trail_len + n], path[0..n]);
            resp.layout_path_len = @intCast(n);
            trail_len += n;
        }

        // Last command
        if (pane.last_cmd) |cmd| {
            const n = @min(cmd.len, trail_buf.len - trail_len);
            @memcpy(trail_buf[trail_len .. trail_len + n], cmd[0..n]);
            resp.last_cmd_len = @intCast(n);
            trail_len += n;
        }

        // Base process name
        if (pane.getProcProcessName()) |proc| {
            const n = @min(proc.len, trail_buf.len - trail_len);
            @memcpy(trail_buf[trail_len .. trail_len + n], proc[0..n]);
            resp.base_process_len = @intCast(n);
            trail_len += n;
        }

        // Sticky pwd
        if (pane.sticky_pwd) |pwd| {
            const n = @min(pwd.len, trail_buf.len - trail_len);
            @memcpy(trail_buf[trail_len .. trail_len + n], pwd[0..n]);
            resp.sticky_pwd_len = @intCast(n);
            trail_len += n;
        }

        wire.writeControlWithTrail(fd, .pane_info, std.mem.asBytes(&resp), trail_buf[0..trail_len]) catch {};
    }

    /// Handle binary status query from CLI — respond with StatusResp + entries.
    fn handleBinaryStatus(self: *Server, fd: posix.fd_t, full_mode: bool) void {
        ses.debugLog("status: full={} fd={d} clients={d} panes={d}", .{ full_mode, fd, self.ses_state.clients.items.len, self.ses_state.panes.count() });
        // Count entries
        var orphaned_count: u16 = 0;
        var sticky_count: u16 = 0;
        var pane_iter = self.ses_state.panes.iterator();
        while (pane_iter.next()) |_entry| {
            const p = _entry.value_ptr;
            if (p.state == .orphaned) orphaned_count += 1;
            if (p.state == .sticky) sticky_count += 1;
        }

        const hdr = wire.StatusResp{
            .client_count = @intCast(self.ses_state.clients.items.len),
            .detached_count = @intCast(self.ses_state.detached_sessions.count()),
            .orphaned_count = orphaned_count,
            .sticky_count = sticky_count,
            .full_mode = @intFromBool(full_mode),
        };

        const alloc = self.ses_state.allocator;

        // Build the entire response in a dynamic buffer
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);

        // Header
        buf.appendSlice(alloc, std.mem.asBytes(&hdr)) catch {
            posix.close(fd);
            return;
        };

        // Connected clients
        for (self.ses_state.clients.items) |client| {
            var sc: wire.StatusClient = .{
                .id = @intCast(client.id),
                .session_id = .{0} ** 32,
                .has_session_id = 0,
                .name_len = 0,
                .pane_count = @intCast(client.pane_uuids.items.len),
                .mux_state_len = 0,
            };

            if (client.session_id) |sid| {
                const hex_id: [32]u8 = std.fmt.bytesToHex(sid, .lower);
                sc.session_id = hex_id;
                sc.has_session_id = 1;
            }

            const name = client.session_name orelse "";
            sc.name_len = @intCast(name.len);
            if (full_mode) {
                if (client.last_mux_state) |ms| {
                    sc.mux_state_len = @intCast(ms.len);
                }
            }

            buf.appendSlice(alloc, std.mem.asBytes(&sc)) catch {
                posix.close(fd);
                return;
            };
            if (name.len > 0) buf.appendSlice(alloc, name) catch {};
            if (full_mode) {
                if (client.last_mux_state) |ms| {
                    buf.appendSlice(alloc, ms) catch {};
                }
            }

            // Pane entries for this client
            for (client.pane_uuids.items) |uuid| {
                var pe: wire.StatusPaneEntry = .{
                    .uuid = uuid,
                    .pid = 0,
                    .name_len = 0,
                    .sticky_pwd_len = 0,
                };
                var pname: []const u8 = "";
                var spwd: []const u8 = "";
                if (self.ses_state.panes.get(uuid)) |pane| {
                    pe.pid = pane.child_pid;
                    if (pane.name) |n| {
                        pname = n;
                        pe.name_len = @intCast(n.len);
                    }
                    if (pane.sticky_pwd) |pwd| {
                        spwd = pwd;
                        pe.sticky_pwd_len = @intCast(pwd.len);
                    }
                }
                buf.appendSlice(alloc, std.mem.asBytes(&pe)) catch {};
                if (pname.len > 0) buf.appendSlice(alloc, pname) catch {};
                if (spwd.len > 0) buf.appendSlice(alloc, spwd) catch {};
            }
        }

        // Detached sessions
        var sess_iter = self.ses_state.detached_sessions.iterator();
        while (sess_iter.next()) |entry| {
            const detached = entry.value_ptr;
            const hex_id: [32]u8 = std.fmt.bytesToHex(detached.session_id, .lower);
            var de: wire.DetachedSessionEntry = .{
                .session_id = hex_id,
                .name_len = @intCast(detached.session_snapshot.session_name.len),
                .pane_count = @intCast(detached.pane_uuids.len),
                .mux_state_len = 0,
            };
            if (full_mode) {
                de.mux_state_len = @intCast(detached.legacy_mux_state_json.len);
            }
            buf.appendSlice(alloc, std.mem.asBytes(&de)) catch {};
            buf.appendSlice(alloc, detached.session_snapshot.session_name) catch {};
            if (full_mode) {
                buf.appendSlice(alloc, detached.legacy_mux_state_json) catch {};
            }
        }

        // Orphaned panes
        pane_iter = self.ses_state.panes.iterator();
        while (pane_iter.next()) |entry| {
            const pane = entry.value_ptr;
            if (pane.state != .orphaned) continue;
            var pe: wire.StatusPaneEntry = .{
                .uuid = entry.key_ptr.*,
                .pid = pane.child_pid,
                .name_len = 0,
                .sticky_pwd_len = 0,
            };
            if (pane.name) |n| pe.name_len = @intCast(n.len);
            buf.appendSlice(alloc, std.mem.asBytes(&pe)) catch {};
            if (pane.name) |n| buf.appendSlice(alloc, n) catch {};
        }

        // Sticky panes
        pane_iter = self.ses_state.panes.iterator();
        while (pane_iter.next()) |entry| {
            const pane = entry.value_ptr;
            if (pane.state != .sticky) continue;
            var se: wire.StickyPaneEntry = .{
                .uuid = entry.key_ptr.*,
                .pid = pane.child_pid,
                .key = pane.sticky_key orelse 0,
                .name_len = 0,
                .pwd_len = 0,
            };
            if (pane.name) |n| se.name_len = @intCast(n.len);
            if (pane.sticky_pwd) |pwd| se.pwd_len = @intCast(pwd.len);
            buf.appendSlice(alloc, std.mem.asBytes(&se)) catch {};
            if (pane.name) |n| buf.appendSlice(alloc, n) catch {};
            if (pane.sticky_pwd) |pwd| buf.appendSlice(alloc, pwd) catch {};
        }

        // Send all at once
        wire.writeControl(fd, .status, buf.items) catch {};
        posix.close(fd);
    }

    /// Find the MUX CTL fd for a given pane UUID.
    fn findMuxCtlForUuid(self: *Server, uuid: [32]u8) ?posix.fd_t {
        if (self.ses_state.panes.get(uuid)) |pane| {
            if (pane.attached_to) |client_id| {
                if (self.ses_state.getClient(client_id)) |client| {
                    return client.mux_ctl_fd;
                }
            }
        }
        // Fallback: try any connected MUX.
        return self.findAnyMuxCtl();
    }

    /// Find the MUX CTL fd for a given session ID (32-char hex).
    /// Falls back to findAnyMuxCtl if session_id is zeroed or not found.
    fn findMuxCtlForSessionId(self: *Server, session_hex: [32]u8) ?posix.fd_t {
        const zero: [32]u8 = .{0} ** 32;
        if (std.mem.eql(u8, &session_hex, &zero)) return self.findAnyMuxCtl();

        // Convert 32-char hex to 16-byte binary for comparison with client.session_id.
        const session_bin = core.uuid.hexToBin(session_hex) orelse return self.findAnyMuxCtl();

        for (self.ses_state.clients.items) |client| {
            if (client.session_id) |csid| {
                if (std.mem.eql(u8, &csid, &session_bin)) {
                    if (client.mux_ctl_fd) |mux_fd| return mux_fd;
                }
            }
        }
        // Fallback: try any connected MUX.
        return self.findAnyMuxCtl();
    }

    /// Find any connected MUX CTL fd.
    fn findAnyMuxCtl(self: *Server) ?posix.fd_t {
        for (self.ses_state.clients.items) |client| {
            if (client.mux_ctl_fd) |mux_fd| return mux_fd;
        }
        return null;
    }

    /// Handle kill_session CLI request.
    fn handleKillSession(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        defer posix.close(fd);

        if (payload_len < @sizeOf(wire.KillSession)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            const result = wire.KillSessionResult{ .success = 0, .killed_panes = 0, .error_len = 15 };
            wire.writeControlWithTrail(fd, .kill_session, std.mem.asBytes(&result), "invalid payload") catch {};
            return;
        }

        const ks = wire.readStruct(wire.KillSession, fd) catch {
            const result = wire.KillSessionResult{ .success = 0, .killed_panes = 0, .error_len = 11 };
            wire.writeControlWithTrail(fd, .kill_session, std.mem.asBytes(&result), "read failed") catch {};
            return;
        };

        if (ks.id_len == 0 or ks.id_len > buf.len) {
            const result = wire.KillSessionResult{ .success = 0, .killed_panes = 0, .error_len = 10 };
            wire.writeControlWithTrail(fd, .kill_session, std.mem.asBytes(&result), "invalid id") catch {};
            return;
        }

        wire.readExact(fd, buf[0..ks.id_len]) catch {
            const result = wire.KillSessionResult{ .success = 0, .killed_panes = 0, .error_len = 11 };
            wire.writeControlWithTrail(fd, .kill_session, std.mem.asBytes(&result), "read failed") catch {};
            return;
        };
        const session_id_str = buf[0..ks.id_len];

        ses.debugLog("kill_session: id={s}", .{session_id_str});

        // Find session by name or UUID prefix.
        const session_id = self.ses_state.findDetachedSessionByNameOrPrefix(session_id_str) orelse {
            const result = wire.KillSessionResult{ .success = 0, .killed_panes = 0, .error_len = 17 };
            wire.writeControlWithTrail(fd, .kill_session, std.mem.asBytes(&result), "session not found") catch {};
            return;
        };

        // Kill the session.
        const killed_panes = self.ses_state.killDetachedSession(session_id) orelse {
            const result = wire.KillSessionResult{ .success = 0, .killed_panes = 0, .error_len = 11 };
            wire.writeControlWithTrail(fd, .kill_session, std.mem.asBytes(&result), "kill failed") catch {};
            return;
        };

        ses.debugLog("kill_session: killed {d} panes", .{killed_panes});
        const result = wire.KillSessionResult{ .success = 1, .killed_panes = @intCast(killed_panes), .error_len = 0 };
        wire.writeControl(fd, .kill_session, std.mem.asBytes(&result)) catch {};
    }

    /// Handle clear_sessions CLI request.
    fn handleClearSessions(self: *Server, fd: posix.fd_t) void {
        defer posix.close(fd);

        ses.debugLog("clear_sessions: starting", .{});
        const counts = self.ses_state.killAllDetachedSessions();
        ses.debugLog("clear_sessions: killed {d} sessions, {d} panes", .{ counts.sessions, counts.panes });

        const result = wire.ClearSessionsResult{
            .killed_sessions = @intCast(counts.sessions),
            .killed_panes = @intCast(counts.panes),
        };
        wire.writeControl(fd, .clear_sessions, std.mem.asBytes(&result)) catch {};
    }

    /// Handle clear_orphaned_panes CLI request.
    fn handleClearOrphanedPanes(self: *Server, fd: posix.fd_t) void {
        defer posix.close(fd);

        ses.debugLog("clear_orphaned_panes: starting", .{});
        const killed = self.ses_state.killAllOrphanedPanes();
        ses.debugLog("clear_orphaned_panes: killed {d} panes", .{killed});

        const result = wire.ClearOrphanedPanesResult{
            .killed_panes = @intCast(killed),
        };
        wire.writeControl(fd, .clear_orphaned_panes, std.mem.asBytes(&result)) catch {};
    }

    /// Handle get_layout CLI request — return last_mux_state for the pane's session.
    fn handleGetLayout(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        defer posix.close(fd);

        if (payload_len < @sizeOf(wire.PaneUuid)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "invalid payload");
            return;
        }
        const pu = wire.readStruct(wire.PaneUuid, fd) catch {
            self.sendBinaryError(fd, "read failed");
            return;
        };

        // Find the client that owns this pane UUID.
        const client = self.findClientForPaneUuid(pu.uuid) orelse {
            self.sendBinaryError(fd, "pane not found");
            return;
        };

        const mux_state = client.last_mux_state orelse {
            self.sendBinaryError(fd, "no mux state");
            return;
        };

        // Send the raw mux_state JSON back as get_layout response.
        wire.writeControl(fd, .get_layout, mux_state) catch {};
    }

    /// Handle get_session_state CLI request — return JSON state for detached session.
    fn handleGetSessionState(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        defer posix.close(fd);

        // Expect exactly 32 bytes (hex UUID)
        if (payload_len != 32) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "invalid payload (expected 32-byte hex UUID)");
            return;
        }

        var hex_uuid: [32]u8 = undefined;
        wire.readExact(fd, &hex_uuid) catch {
            self.sendBinaryError(fd, "read failed");
            return;
        };

        // Convert hex UUID to binary
        const session_id = core.uuid.hexToBin(hex_uuid) orelse {
            self.sendBinaryError(fd, "invalid hex UUID");
            return;
        };

        // Look up detached session
        const detached_state = self.ses_state.detached_sessions.get(session_id) orelse {
            self.sendBinaryError(fd, "session not found");
            return;
        };

        const session_json = detached_state.session_snapshot.toJson(self.allocator) catch {
            self.sendBinaryError(fd, "session_snapshot_failed");
            return;
        };
        defer self.allocator.free(session_json);

        wire.writeControl(fd, .session_state, session_json) catch {};
    }

    /// Handle apply_layout CLI request — forward layout tree to MUX.
    fn handleApplyLayout(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        defer posix.close(fd);

        if (payload_len < @sizeOf(wire.ApplyLayout)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "invalid payload");
            return;
        }

        const al = wire.readStruct(wire.ApplyLayout, fd) catch {
            self.sendBinaryError(fd, "read failed");
            return;
        };

        // Read tree JSON.
        if (al.tree_json_len == 0 or al.tree_json_len > wire.MAX_PAYLOAD_LEN) {
            self.sendBinaryError(fd, "invalid json len");
            return;
        }

        const json_buf = self.allocator.alloc(u8, al.tree_json_len) catch {
            self.sendBinaryError(fd, "alloc failed");
            return;
        };
        defer self.allocator.free(json_buf);

        wire.readExact(fd, json_buf) catch {
            self.sendBinaryError(fd, "read json failed");
            return;
        };

        // Find MUX CTL fd for this pane.
        const mux_fd = self.findMuxCtlForUuid(al.uuid) orelse {
            self.sendBinaryError(fd, "no mux");
            return;
        };

        // Forward to MUX.
        wire.writeControlWithTrail(mux_fd, .apply_layout, std.mem.asBytes(&al), json_buf) catch {
            self.sendBinaryError(fd, "forward failed");
            return;
        };
    }

    /// Find the client (MUX) that owns a given pane UUID.
    fn findClientForPaneUuid(self: *Server, uuid: [32]u8) ?*state.Client {
        for (self.ses_state.clients.items) |*client| {
            for (client.pane_uuids.items) |pane_uuid| {
                if (std.mem.eql(u8, &pane_uuid, &uuid)) return client;
            }
        }
        return null;
    }

    pub fn stop(self: *Server) void {
        self.running = false;
    }
};
