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
const CTL_FRAME_IO_TIMEOUT_MS: i32 = 2000;

/// Maximum number of concurrent client connections (MUX instances).
const MAX_CLIENTS: usize = core.constants.Limits.max_clients;

fn setNonBlocking(fd: posix.fd_t) void {
    const O_NONBLOCK: usize = 0o4000;
    const flags = posix.fcntl(fd, posix.F.GETFL, 0) catch |err| {
        core.logging.logError("ses", "failed to read accepted fd flags", err);
        return;
    };
    _ = posix.fcntl(fd, posix.F.SETFL, flags | O_NONBLOCK) catch |err| {
        core.logging.logError("ses", "failed to set accepted fd nonblocking", err);
    };
}

const CtlWatcher = struct {
    srv: *anyopaque,
    fd: posix.fd_t,
    completion: xev.Completion = .{},
};

fn testSocketPair() !struct { a: posix.fd_t, b: posix.fd_t } {
    var fds: [2]posix.fd_t = undefined;
    const rc = std.os.linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return error.SocketpairFailed;
    return .{ .a = fds[0], .b = fds[1] };
}

fn testServer(allocator: std.mem.Allocator) Server {
    return .{
        .allocator = allocator,
        .socket = undefined,
        .ses_state = undefined,
        .running = true,
        .pending_pop_requests = std.AutoHashMap(posix.fd_t, posix.fd_t).init(allocator),
        .binary_ctl_fds = std.AutoHashMap(posix.fd_t, void).init(allocator),
        .ctl_watchers = std.AutoHashMap(posix.fd_t, *CtlWatcher).init(allocator),
        .pending_ctl_close_fds = .empty,
        .vt_watchers = std.AutoHashMap(posix.fd_t, *VtWatcher).init(allocator),
        .pending_vt_close_fds = .empty,
        .deferred_destroy_ctl = .empty,
        .deferred_destroy_vt = .empty,
        .pending_float_cli_fds = std.AutoHashMap([32]u8, posix.fd_t).init(allocator),
        .resource_monitor = core.resource_limits.ResourceMonitor.init(.{}),
        .vt_route_buf = allocator.alloc(u8, wire.MAX_PAYLOAD_LEN) catch unreachable,
    };
}

fn testServerWithState(allocator: std.mem.Allocator, ses_state: *state.SesState) Server {
    var server = testServer(allocator);
    server.ses_state = ses_state;
    return server;
}

fn deinitTestServer(server: *Server) void {
    server.pending_float_cli_fds.deinit();
    server.pending_pop_requests.deinit();
    server.ctl_watchers.deinit();
    server.pending_ctl_close_fds.deinit(server.allocator);
    server.vt_watchers.deinit();
    server.pending_vt_close_fds.deinit(server.allocator);
    server.deferred_destroy_ctl.deinit(server.allocator);
    server.deferred_destroy_vt.deinit(server.allocator);
    server.binary_ctl_fds.deinit();
    server.allocator.free(server.vt_route_buf);
}

fn expectBinaryError(fd: posix.fd_t, expected: []const u8) !void {
    const hdr = try wire.readControlHeader(fd);
    try std.testing.expectEqual(@as(u16, @intFromEnum(wire.MsgType.@"error")), hdr.msg_type);
    try std.testing.expectEqual(@as(u32, @intCast(@sizeOf(wire.Error) + expected.len)), hdr.payload_len);

    const payload = try wire.readStruct(wire.Error, fd);
    try std.testing.expectEqual(@as(u16, @intCast(expected.len)), payload.msg_len);

    var buf: [128]u8 = undefined;
    try std.testing.expect(expected.len <= buf.len);
    try wire.readExact(fd, buf[0..expected.len]);
    try std.testing.expectEqualStrings(expected, buf[0..expected.len]);
}

fn addSnapshotClient(ses_state: *state.SesState, fd: posix.fd_t) !usize {
    const client_id = try ses_state.addClient(fd);
    const client = ses_state.getClient(client_id).?;
    const snapshot = try state.SessionSnapshot.initMinimal(ses_state.allocator, [_]u8{'s'} ** 32, "alpha");
    client.updateSessionSnapshot(snapshot);
    return client_id;
}

test "Server.requireSnapshotPane rejects unknown pane with binary error" {
    const allocator = std.testing.allocator;
    const pair = try testSocketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);

    var server = testServer(allocator);
    defer deinitTestServer(&server);

    var client = state.Client.init(allocator, 42, pair.a);
    defer client.deinit();
    const snapshot = try state.SessionSnapshot.initMinimal(allocator, [_]u8{'s'} ** 32, "alpha");
    client.updateSessionSnapshot(snapshot);

    try std.testing.expect(!server.requireSnapshotPane(pair.a, &client, [_]u8{'u'} ** 32, "test_op"));
    try expectBinaryError(pair.b, "unknown pane uuid");
}

test "Server.requireSnapshotTab rejects unknown tab with binary error" {
    const allocator = std.testing.allocator;
    const pair = try testSocketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);

    var server = testServer(allocator);
    defer deinitTestServer(&server);

    var client = state.Client.init(allocator, 43, pair.a);
    defer client.deinit();
    const snapshot = try state.SessionSnapshot.initMinimal(allocator, [_]u8{'s'} ** 32, "alpha");
    client.updateSessionSnapshot(snapshot);

    try std.testing.expect(!server.requireSnapshotTab(pair.a, &client, [_]u8{'t'} ** 32, "test_op"));
    try expectBinaryError(pair.b, "unknown tab uuid");
}

test "Server.handleBinarySessionRemoveTab rejects unknown snapshot tab" {
    const allocator = std.testing.allocator;
    const pair = try testSocketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);

    var ses_state = state.SesState.init(allocator);
    defer ses_state.deinit();
    _ = try addSnapshotClient(&ses_state, pair.a);

    var server = testServerWithState(allocator, &ses_state);
    defer deinitTestServer(&server);

    const msg = wire.SessionRemoveTab{
        .tab_uuid = [_]u8{'t'} ** 32,
        .active_tab = 0,
        .has_active_tab = 0,
    };
    try wire.writeAll(pair.b, std.mem.asBytes(&msg));

    var buf: [128]u8 = undefined;
    server.handleBinarySessionRemoveTab(pair.a, @sizeOf(wire.SessionRemoveTab), &buf);
    try expectBinaryError(pair.b, "unknown tab uuid");
}

test "Server.handleBinarySessionRemoveFloat rejects unknown snapshot pane" {
    const allocator = std.testing.allocator;
    const pair = try testSocketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);

    var ses_state = state.SesState.init(allocator);
    defer ses_state.deinit();
    _ = try addSnapshotClient(&ses_state, pair.a);

    var server = testServerWithState(allocator, &ses_state);
    defer deinitTestServer(&server);

    const msg = wire.SessionRemoveFloat{
        .pane_uuid = [_]u8{'p'} ** 32,
    };
    try wire.writeAll(pair.b, std.mem.asBytes(&msg));

    var buf: [128]u8 = undefined;
    server.handleBinarySessionRemoveFloat(pair.a, @sizeOf(wire.SessionRemoveFloat), &buf);
    try expectBinaryError(pair.b, "unknown pane uuid");
}

test "Server.handleBinarySessionSplitPane rejects unknown snapshot tab" {
    const allocator = std.testing.allocator;
    const pair = try testSocketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);

    var ses_state = state.SesState.init(allocator);
    defer ses_state.deinit();
    _ = try addSnapshotClient(&ses_state, pair.a);

    var server = testServerWithState(allocator, &ses_state);
    defer deinitTestServer(&server);

    const msg = wire.SessionSplitPane{
        .tab_uuid = [_]u8{'t'} ** 32,
        .source_pane_uuid = [_]u8{'p'} ** 32,
        .new_pane_uuid = [_]u8{'n'} ** 32,
        .focused_pane_uuid = [_]u8{0} ** 32,
        .active_tab = 0,
        .dir = 0,
        .has_focused_pane = 0,
    };
    try wire.writeAll(pair.b, std.mem.asBytes(&msg));

    var buf: [128]u8 = undefined;
    server.handleBinarySessionSplitPane(pair.a, @sizeOf(wire.SessionSplitPane), &buf);
    try expectBinaryError(pair.b, "unknown tab uuid");
}

test "Server.handleBinarySessionReplaceSplitPane rejects unknown snapshot tab" {
    const allocator = std.testing.allocator;
    const pair = try testSocketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);

    var ses_state = state.SesState.init(allocator);
    defer ses_state.deinit();
    _ = try addSnapshotClient(&ses_state, pair.a);

    var server = testServerWithState(allocator, &ses_state);
    defer deinitTestServer(&server);

    const msg = wire.SessionReplaceSplitPane{
        .tab_uuid = [_]u8{'t'} ** 32,
        .old_pane_uuid = [_]u8{'o'} ** 32,
        .new_pane_uuid = [_]u8{'n'} ** 32,
        .focused_pane_uuid = [_]u8{0} ** 32,
        .active_tab = 0,
        .has_focused_pane = 0,
    };
    try wire.writeAll(pair.b, std.mem.asBytes(&msg));

    var buf: [128]u8 = undefined;
    server.handleBinarySessionReplaceSplitPane(pair.a, @sizeOf(wire.SessionReplaceSplitPane), &buf);
    try expectBinaryError(pair.b, "unknown tab uuid");
}

test "Server.handleBinarySessionSetSplitRatio rejects unknown snapshot tab" {
    const allocator = std.testing.allocator;
    const pair = try testSocketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);

    var ses_state = state.SesState.init(allocator);
    defer ses_state.deinit();
    _ = try addSnapshotClient(&ses_state, pair.a);

    var server = testServerWithState(allocator, &ses_state);
    defer deinitTestServer(&server);

    const msg = wire.SessionSetSplitRatio{
        .tab_uuid = [_]u8{'t'} ** 32,
        .first_anchor_uuid = [_]u8{'a'} ** 32,
        .second_anchor_uuid = [_]u8{'b'} ** 32,
        .active_tab = 0,
        .ratio = 0.5,
    };
    try wire.writeAll(pair.b, std.mem.asBytes(&msg));

    var buf: [128]u8 = undefined;
    server.handleBinarySessionSetSplitRatio(pair.a, @sizeOf(wire.SessionSetSplitRatio), &buf);
    try expectBinaryError(pair.b, "unknown tab uuid");
}

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
    // Reused by the single-threaded VT router to avoid alloc/free per output frame.
    vt_route_buf: []u8,

    /// Allocator is ignored — see `SesState.init` for the rationale. Everything
    /// that outlives the fork runs on `page_allocator`.
    pub fn init(_: std.mem.Allocator, ses_state: *state.SesState) !Server {
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
            .vt_route_buf = try page_alloc.alloc(u8, wire.MAX_PAYLOAD_LEN),
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
        self.allocator.free(self.vt_route_buf);
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
            for (self.ses_state.store.clients.items) |client| {
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
                self.ses_state.store.pod_vt_to_pane_id.contains(pending.fd),
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

            if (self.ses_state.store.pod_vt_to_pane_id.contains(pending.fd)) {
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
        self.pending_ctl_close_fds.append(self.allocator, .{ .fd = fd, .watcher = watcher }) catch |err| {
            core.logging.logError("ses", "failed to queue CTL fd close", err);
        };
    }

    fn queueVtClose(self: *Server, fd: posix.fd_t, watcher: ?*VtWatcher) void {
        for (self.pending_vt_close_fds.items) |existing| {
            if (existing.fd == fd) return;
        }
        self.pending_vt_close_fds.append(self.allocator, .{ .fd = fd, .watcher = watcher }) catch |err| {
            core.logging.logError("ses", "failed to queue VT fd close", err);
        };
    }

    /// Write a control reply to a client fd; on failure log and queue the
    /// connection for close so stale fds don't accumulate.
    fn replyOrClose(self: *Server, fd: posix.fd_t, msg_type: wire.MsgType, payload: []const u8) void {
        wire.writeControl(fd, msg_type, payload) catch |err| {
            core.logging.warnWithSource("ses", "reply failed: fd={d} type={s} err={s}", .{ fd, @tagName(msg_type), @errorName(err) }, @src());
            self.queueCtlClose(fd, null);
        };
    }

    /// Same as replyOrClose but for messages with a trailing byte blob.
    fn replyOrCloseWithTrail(
        self: *Server,
        fd: posix.fd_t,
        msg_type: wire.MsgType,
        payload: []const u8,
        trail: []const u8,
    ) void {
        wire.writeControlWithTrail(fd, msg_type, payload, trail) catch |err| {
            core.logging.warnWithSource("ses", "reply-with-trail failed: fd={d} type={s} err={s}", .{ fd, @tagName(msg_type), @errorName(err) }, @src());
            self.queueCtlClose(fd, null);
        };
    }

    /// Assert that `client` owns `tab_uuid` in its canonical snapshot. If
    /// not, log a warning and reply with an error; returns `false` so the
    /// caller can bail out. Used by session_* handlers to reject mutations
    /// that reference tabs the client never saw.
    fn requireSnapshotTab(self: *Server, fd: posix.fd_t, client: *const state.Client, tab_uuid: [32]u8, op: []const u8) bool {
        if (client.snapshotOwnsTab(tab_uuid)) return true;
        core.logging.warnWithSource(
            "ses",
            "{s}: client_id={d} referenced unknown tab {x}",
            .{ op, client.id, std.fmt.bytesToHex(&tab_uuid, .lower) },
            @src(),
        );
        self.sendBinaryError(fd, "unknown tab uuid");
        return false;
    }

    /// Assert that `client` owns `pane_uuid` in its canonical snapshot.
    /// Same contract as `requireSnapshotTab`.
    fn requireSnapshotPane(self: *Server, fd: posix.fd_t, client: *const state.Client, pane_uuid: [32]u8, op: []const u8) bool {
        if (client.snapshotOwnsPane(pane_uuid)) return true;
        core.logging.warnWithSource(
            "ses",
            "{s}: client_id={d} referenced unknown pane {x}",
            .{ op, client.id, std.fmt.bytesToHex(&pane_uuid, .lower) },
            @src(),
        );
        self.sendBinaryError(fd, "unknown pane uuid");
        return false;
    }

    /// Assert that a pane exists in the live SES store and is currently
    /// attached to this client. Snapshot membership is not enough when a
    /// session_* command introduces a pane into canonical layout state.
    fn requireLiveAttachedPane(self: *Server, fd: posix.fd_t, client_id: usize, pane_uuid: [32]u8, op: []const u8) bool {
        if (self.ses_state.paneAttachedToClient(pane_uuid, client_id)) return true;
        core.logging.warnWithSource(
            "ses",
            "{s}: client_id={d} referenced unowned live pane {x}",
            .{ op, client_id, std.fmt.bytesToHex(&pane_uuid, .lower) },
            @src(),
        );
        self.sendBinaryError(fd, "pane not attached to client");
        return false;
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
        if (self.ses_state.polling.pending_remove_poll_fds.items.len > 0 or self.ses_state.polling.pending_poll_fds.items.len > 0) {
            ses.debugLog("processPendingWatcherUpdates: remove={d} add={d}", .{
                self.ses_state.polling.pending_remove_poll_fds.items.len,
                self.ses_state.polling.pending_poll_fds.items.len,
            });
        }
        for (self.ses_state.polling.pending_remove_poll_fds.items) |fd| {
            ses.debugLog("processPendingWatcherUpdates: disarm fd={d}", .{fd});
            if (self.binary_ctl_fds.contains(fd)) {
                self.disarmCtlWatcher(fd);
            }
            self.disarmVtWatcher(fd);
        }
        self.ses_state.polling.pending_remove_poll_fds.clearRetainingCapacity();

        for (self.ses_state.polling.pending_poll_fds.items) |fd| {
            ses.debugLog("processPendingWatcherUpdates: arm fd={d}", .{fd});
            if (!self.armVtWatcher(fd, .pod_to_mux)) {
                core.logging.logError("ses", "failed to arm pending POD VT watcher", error.OutOfMemory);
                self.removePodVtFd(fd);
                posix.close(fd);
            }
        }
        self.ses_state.polling.pending_poll_fds.clearRetainingCapacity();
    }

    fn armCtlWatcher(self: *Server, fd: posix.fd_t) bool {
        if (self.loop_ptr == null) return true;
        if (self.ctl_watchers.contains(fd)) return true;

        const node = self.allocator.create(CtlWatcher) catch |err| {
            core.logging.logError("ses", "failed to allocate CTL watcher", err);
            return false;
        };
        node.* = .{ .srv = @ptrCast(self), .fd = fd };
        self.ctl_watchers.put(fd, node) catch |err| {
            core.logging.logError("ses", "failed to register CTL watcher", err);
            self.allocator.destroy(node);
            return false;
        };

        const watcher = xev.File.initFd(fd);
        watcher.poll(self.loop_ptr.?, &node.completion, .read, CtlWatcher, node, ctlWatcherCallback);
        return true;
    }

    fn disarmCtlWatcher(self: *Server, fd: posix.fd_t) void {
        if (self.ctl_watchers.fetchRemove(fd)) |kv| {
            // Defer destruction: xev may still reference the completion struct
            self.deferred_destroy_ctl.append(self.allocator, kv.value) catch |err| {
                core.logging.logError("ses", "failed to defer CTL watcher destruction", err);
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

    fn armVtWatcher(self: *Server, fd: posix.fd_t, direction: VtDirection) bool {
        if (self.loop_ptr == null) {
            ses.debugLog("armVtWatcher: SKIP fd={d} (no loop)", .{fd});
            return true;
        }
        if (self.vt_watchers.contains(fd)) {
            ses.debugLog("armVtWatcher: SKIP fd={d} (already armed)", .{fd});
            return true;
        }
        ses.debugLog("armVtWatcher: ARMED fd={d} dir={s}", .{ fd, @tagName(direction) });

        const node = self.allocator.create(VtWatcher) catch |err| {
            core.logging.logError("ses", "failed to allocate VT watcher", err);
            return false;
        };
        node.* = .{ .srv = @ptrCast(self), .fd = fd, .direction = direction };
        self.vt_watchers.put(fd, node) catch |err| {
            core.logging.logError("ses", "failed to register VT watcher", err);
            self.allocator.destroy(node);
            return false;
        };

        const watcher = xev.File.initFd(fd);
        watcher.poll(self.loop_ptr.?, &node.completion, .read, VtWatcher, node, vtWatcherCallback);
        return true;
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
        _ = result catch |err| {
            core.logging.logError("ses", "accept watcher event failed", err);
            return .rearm;
        };

        while (accept_ctx.server.socket.tryAccept() catch |err| {
            core.logging.logError("ses", "accept failed", err);
            return .rearm;
        }) |conn| {
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
        _ = result catch |err| {
            core.logging.logError("ses", "CTL watcher event failed", err);
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

        _ = result catch |err| {
            core.logging.logError("ses", "VT watcher event failed", err);
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
        _ = result catch |err| {
            core.logging.logError("ses", "periodic timer failed", err);
            // Re-arm with fresh absolute timestamp (workaround for xev io_uring timer re-arm bug)
            periodic.ticker.run(loop, completion, 100, PeriodicContext, periodic, periodicCallback);
            return .disarm;
        };

        const now_ms = std.time.milliTimestamp();

        if (periodic.server.ses_state.store.dirty and now_ms - periodic.last_save >= 1000) {
            @import("persist.zig").save(periodic.server.allocator, periodic.server.ses_state) catch |e| {
                core.logging.logError("ses", "persist.save failed", e);
            };
            periodic.server.ses_state.store.dirty = false;
            periodic.last_save = now_ms;
        }

        if (now_ms - periodic.last_stats_update >= 5000) {
            const detached_sessions = periodic.server.ses_state.store.detached_sessions.count();
            const total_panes = periodic.server.ses_state.store.panes.count();
            const active_connections = periodic.server.ses_state.store.clients.items.len;

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
        setNonBlocking(conn.fd);

        // Reject peers running as a different UID. This prevents a sibling
        // process owned by another user from driving our session. Override
        // via HEXE_ALLOW_CROSS_UID=1 for legitimate test setups.
        if (!ipc.verifyPeerUid(conn.fd)) {
            core.logging.warnWithSource(
                "ses",
                "reject: peer uid mismatch on fd={d}",
                .{conn.fd},
                @src(),
            );
            var tmp = conn;
            tmp.close();
            return;
        }

        // Check resource limits and rate limiting
        if (!self.resource_monitor.allowNewConnection()) {
            ses.debugLog("reject: connection limit or rate limit exceeded", .{});
            // Try to send error message before closing
            const err_msg = "server_overloaded: connection/rate limit exceeded";
            const err_payload = wire.Error{ .msg_len = @intCast(err_msg.len) };
            self.replyOrCloseWithTrail(conn.fd, .@"error", std.mem.asBytes(&err_payload), err_msg);
            var tmp = conn;
            tmp.close();
            return;
        }
        self.resource_monitor.recordConnection();

        // Read versioned handshake: [channel_type, version]
        var handshake: [2]u8 = undefined;
        wire.readExactTimeout(conn.fd, &handshake, CTL_FRAME_IO_TIMEOUT_MS) catch |err| {
            core.logging.logError("ses", "connection handshake read failed", err);
            var tmp = conn;
            tmp.close();
            return;
        };

        // Validate protocol version with negotiation.
        const client_version = handshake[1];
        if (!wire.isProtocolVersionSupported(client_version)) {
            ses.debugLog("reject: unsupported protocol version {d} (supported: {d}-{d})", .{
                client_version,
                wire.MIN_PROTOCOL_VERSION,
                wire.PROTOCOL_VERSION,
            });
            // Send error message if this is a CTL channel (can receive error responses)
            if (handshake[0] == wire.SES_HANDSHAKE_FRONTEND_CTL or handshake[0] == wire.SES_HANDSHAKE_POD_CTL) {
                // Send version mismatch error with version range
                const err_msg = std.fmt.allocPrint(
                    self.allocator,
                    "protocol_version_mismatch: client={d} supported={d}-{d}",
                    .{ client_version, wire.MIN_PROTOCOL_VERSION, wire.PROTOCOL_VERSION },
                ) catch "protocol_version_mismatch";
                defer if (!std.mem.eql(u8, err_msg, "protocol_version_mismatch")) self.allocator.free(err_msg);

                const err_payload = wire.Error{ .msg_len = @intCast(err_msg.len) };
                self.replyOrCloseWithTrail(conn.fd, .@"error", std.mem.asBytes(&err_payload), err_msg);
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
            if (handshake[0] == wire.SES_HANDSHAKE_FRONTEND_CTL) {
                const warn_msg = std.fmt.allocPrint(
                    self.allocator,
                    "Protocol version {d} is deprecated. Please update to version {d}.",
                    .{ client_version, wire.PROTOCOL_VERSION },
                ) catch "";
                defer if (warn_msg.len > 0) self.allocator.free(warn_msg);

                if (warn_msg.len > 0) {
                    const notify = wire.Notify{ .msg_len = @intCast(warn_msg.len) };
                    self.replyOrCloseWithTrail(conn.fd, .notify, std.mem.asBytes(&notify), warn_msg);
                }
            }
        }

        switch (handshake[0]) {
            wire.SES_HANDSHAKE_FRONTEND_CTL => {
                wire.sendServerHello(conn.fd) catch |err| {
                    core.logging.logError("ses", "frontend CTL server hello failed", err);
                    var tmp = conn;
                    tmp.close();
                    return;
                };
                // Frontend binary control channel.
                ses.debugLog("accept: frontend ctl channel fd={d}", .{conn.fd});
                self.binary_ctl_fds.put(conn.fd, {}) catch |err| {
                    core.logging.logError("ses", "failed to register frontend CTL fd", err);
                    var tmp = conn;
                    tmp.close();
                    return;
                };
                if (!self.armCtlWatcher(conn.fd)) {
                    _ = self.binary_ctl_fds.remove(conn.fd);
                    var tmp = conn;
                    tmp.close();
                    return;
                }
            },
            wire.SES_HANDSHAKE_FRONTEND_VT => {
                // Frontend VT data channel — read 32-byte session_id to identify client.
                ses.debugLog("accept: frontend VT channel fd={d}", .{conn.fd});
                var sid: [32]u8 = undefined;
                wire.readExact(conn.fd, &sid) catch |err| {
                    core.logging.logError("ses", "frontend VT session id read failed", err);
                    var tmp = conn;
                    tmp.close();
                    return;
                };
                // Convert 32-char hex to 16-byte session_id for lookup.
                const session_id = core.uuid.hexToBin(sid) orelse {
                    // Invalid hex — close connection.
                    core.logging.warn("ses", "frontend VT invalid session id fd={d}", .{conn.fd});
                    var tmp = conn;
                    tmp.close();
                    return;
                };
                // Find client with matching session_id.
                var found = false;
                for (self.ses_state.store.clients.items) |*client| {
                    if (client.session_id) |csid| {
                        if (std.mem.eql(u8, &csid, &session_id)) {
                            if (client.mux_vt_fd) |old| {
                                self.queueVtClose(old, null);
                            }
                            client.mux_vt_fd = conn.fd;
                            ses.debugLog("frontend VT: assigned fd={d} to client_id={d}", .{ conn.fd, client.id });
                            found = true;
                            break;
                        }
                    }
                }
                if (!found) {
                    ses.debugLog("frontend VT: no client for session {s}", .{sid});
                    var tmp = conn;
                    tmp.close();
                    return;
                }
                if (!self.armVtWatcher(conn.fd, .mux_to_pod)) {
                    for (self.ses_state.store.clients.items) |*client| {
                        if (client.mux_vt_fd == conn.fd) {
                            client.mux_vt_fd = null;
                            break;
                        }
                    }
                    var tmp = conn;
                    tmp.close();
                    return;
                }
            },
            wire.SES_HANDSHAKE_CLI => {
                wire.sendServerHello(conn.fd) catch |err| {
                    core.logging.logError("ses", "CLI server hello failed", err);
                    var tmp = conn;
                    tmp.close();
                    return;
                };
                // CLI tool request (focus_move, exit_intent, float).
                self.handleCliRequest(conn.fd);
            },
            wire.SES_HANDSHAKE_POD_CTL => {
                // POD control uplink — read 16-byte binary UUID.
                ses.debugLog("accept: POD ctl uplink fd={d}", .{conn.fd});
                var uuid_bin: [16]u8 = undefined;
                wire.readExact(conn.fd, &uuid_bin) catch |err| {
                    core.logging.logError("ses", "POD ctl uuid read failed", err);
                    var tmp = conn;
                    tmp.close();
                    return;
                };
                // Convert 16 binary bytes → 32-char hex UUID key.
                const uuid_hex = core.uuid.binToHex(uuid_bin);
                // Store fd in the pane's pod_ctl_fd.
                if (self.ses_state.store.panes.getPtr(uuid_hex)) |pane| {
                    if (pane.pod_ctl_fd) |old_fd| {
                        self.queueCtlClose(old_fd, null);
                    }
                    pane.pod_ctl_fd = conn.fd;
                    self.binary_ctl_fds.put(conn.fd, {}) catch |err| {
                        core.logging.logError("ses", "failed to register POD CTL fd", err);
                        pane.pod_ctl_fd = null;
                        var tmp = conn;
                        tmp.close();
                        return;
                    };
                    if (!self.armCtlWatcher(conn.fd)) {
                        _ = self.binary_ctl_fds.remove(conn.fd);
                        pane.pod_ctl_fd = null;
                        var tmp = conn;
                        tmp.close();
                        return;
                    }
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
        for (self.ses_state.store.clients.items) |client| {
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
        wire.readExactTimeout(pod_vt_fd, &hdr, VT_ROUTE_IO_TIMEOUT_MS) catch |err| {
            core.logging.logError("ses", "failed to read POD VT frame header", err);
            return false;
        };

        const frame_type = hdr[0];
        const payload_len = std.mem.readInt(u32, hdr[1..5], .big);

        // Safety cap.
        if (payload_len > wire.MAX_PAYLOAD_LEN) {
            core.logging.warn("ses", "POD VT frame too large: fd={d} len={d}", .{ pod_vt_fd, payload_len });
            return false;
        }

        // Look up pane_id.
        const pane_id = self.ses_state.store.pod_vt_to_pane_id.get(pod_vt_fd) orelse {
            ses.debugLog("vt pod->mux: pod_vt_fd={d} NOT in routing table, draining {d} bytes", .{ pod_vt_fd, payload_len });
            self.skipBytes(pod_vt_fd, payload_len);
            return true;
        };
        ses.debugLog("vt pod->mux: pane_id={d} type={d} len={d} pod_vt_fd={d}", .{ pane_id, frame_type, payload_len, pod_vt_fd });

        // Find the MUX VT fd for this pane.
        const mux_vt_fd = self.findMuxVtForPane(pane_id) orelse {
            // No MUX connected — skip payload.
            core.logging.warn("ses", "POD VT frame has no mux target: pod_vt_fd={d} pane_id={d}", .{ pod_vt_fd, pane_id });
            self.skipBytes(pod_vt_fd, payload_len);
            return true;
        };

        if (payload_len > self.vt_route_buf.len) {
            core.logging.warn("ses", "POD VT frame exceeds route buffer: fd={d} len={d}", .{ pod_vt_fd, payload_len });
            self.skipBytes(pod_vt_fd, payload_len);
            return true;
        }
        const payload = self.vt_route_buf[0..payload_len];

        wire.readExactTimeout(pod_vt_fd, payload, VT_ROUTE_IO_TIMEOUT_MS) catch |err| {
            core.logging.logError("ses", "failed to read POD VT payload", err);
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
        if (mux_hdr.len > wire.MAX_PAYLOAD_LEN) {
            core.logging.warn("ses", "MUX VT frame too large: fd={d} len={d}", .{ mux_vt_fd, mux_hdr.len });
            return false;
        }

        // Look up pod_vt_fd from pane_id.
        const pod_vt_fd = self.ses_state.store.pane_id_to_pod_vt.get(mux_hdr.pane_id) orelse {
            // Unknown pane — skip payload.
            core.logging.warn("ses", "MUX VT frame for unknown pane_id={d} fd={d}", .{ mux_hdr.pane_id, mux_vt_fd });
            self.skipBytes(mux_vt_fd, mux_hdr.len);
            return true;
        };

        // Write 5-byte pod_protocol header to POD.
        var pod_hdr: [5]u8 = undefined;
        pod_hdr[0] = mux_hdr.frame_type;
        std.mem.writeInt(u32, pod_hdr[1..5], mux_hdr.len, .big);
        wire.writeAll(pod_vt_fd, &pod_hdr) catch |err| {
            core.logging.logError("ses", "failed to write POD VT frame header", err);
            ses.debugLog("vt mux->pod: pod_vt_fd write failed, queuing close", .{});
            self.skipBytes(mux_vt_fd, mux_hdr.len);
            self.queueVtClose(pod_vt_fd, null);
            return true;
        };

        // Splice payload: read from mux, write to pod.
        self.spliceData(mux_vt_fd, pod_vt_fd, mux_hdr.len) catch |err| {
            core.logging.logError("ses", "failed to splice MUX VT payload to POD", err);
            self.queueVtClose(pod_vt_fd, null);
            return true;
        };
        return true;
    }

    /// Find the MUX VT fd that should receive output for a given pane_id.
    fn findMuxVtForPane(self: *Server, pane_id: u16) ?posix.fd_t {
        // Find which pane has this pane_id, then find its owning client's mux_vt_fd.
        var pane_iter = self.ses_state.store.panes.valueIterator();
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
        const pane_id = if (self.ses_state.store.pod_vt_to_pane_id.fetchRemove(fd)) |kv| blk: {
            _ = self.ses_state.store.pane_id_to_pod_vt.remove(kv.value);
            break :blk kv.value;
        } else null;

        // Clear from pane and notify MUX.
        var exited_uuid: ?[32]u8 = null;
        var pane_iter = self.ses_state.store.panes.iterator();
        while (pane_iter.next()) |entry| {
            const pane = entry.value_ptr;
            if (pane.pod_vt_fd) |vt_fd| {
                if (vt_fd == fd) {
                    @constCast(pane).pod_vt_fd = null;
                    exited_uuid = entry.key_ptr.*;
                    // Notify the owning MUX that this pane exited.
                    if (pane.attached_to) |client_id| {
                        if (self.ses_state.getClient(client_id)) |client| {
                            if (client.mux_ctl_fd) |ctl_fd| {
                                const uuid = entry.key_ptr.*;
                                ses.debugLog("pane_exited: uuid={s} pane_id={?d}", .{ uuid[0..8], pane_id });
                                var msg = wire.PaneUuid{ .uuid = uuid };
                                self.replyOrClose(ctl_fd, .pane_exited, std.mem.asBytes(&msg));
                            }
                        }
                    }
                    break;
                }
            }
        }
        if (exited_uuid) |uuid| {
            // Treat POD VT disconnect as terminal for the pane. This keeps SES
            // authoritative for snapshot pruning instead of relying on the
            // frontend to repair canonical state after receiving pane_exited.
            self.ses_state.killPane(uuid) catch |e| {
                core.logging.logError("ses", "killPane failed after POD VT disconnect", e);
            };
        }
    }

    fn removeMuxVtFd(self: *Server, fd: posix.fd_t) void {
        ses.debugLog("remove mux_vt fd={d}", .{fd});
        for (self.ses_state.store.clients.items) |*client| {
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
            wire.readExactTimeout(src, buf[0..chunk], VT_ROUTE_IO_TIMEOUT_MS) catch |err| {
                core.logging.logError("ses", "failed to read VT splice payload", err);
                return error.ConnectionClosed;
            };
            wire.writeAllTimeout(dst, buf[0..chunk], VT_ROUTE_IO_TIMEOUT_MS) catch |err| {
                core.logging.logError("ses", "failed to write VT splice payload", err);
                return error.ConnectionClosed;
            };
            remaining -= chunk;
        }
    }

    /// Discard `len` bytes from fd.
    fn skipBytes(_: *Server, fd: posix.fd_t, len: u32) void {
        var remaining: usize = len;
        var buf: [4096]u8 = undefined;
        while (remaining > 0) {
            const chunk = @min(remaining, buf.len);
            wire.readExactTimeout(fd, buf[0..chunk], VT_ROUTE_IO_TIMEOUT_MS) catch |err| {
                core.logging.logError("ses", "failed to skip VT payload", err);
                return;
            };
            remaining -= chunk;
        }
    }

    /// Find client_id for a binary CTL fd.
    fn findClientForCtlFd(self: *Server, fd: posix.fd_t) ?usize {
        for (self.ses_state.store.clients.items) |client| {
            if (client.fd == fd or client.mux_ctl_fd == fd) return client.id;
        }
        return null;
    }

    /// Handle a binary control message. Returns false if connection should be removed.
    fn handleBinaryCtlMessage(self: *Server, fd: posix.fd_t) bool {
        const hdr = wire.readControlHeaderTimeout(fd, CTL_FRAME_IO_TIMEOUT_MS) catch |err| {
            core.logging.logError("ses", "failed to read control header", err);
            return false;
        };
        // Cap payload length before any allocation or chunked read. A
        // misbehaving or malicious client cannot coerce us into a giant
        // allocation — close the connection on overflow.
        if (hdr.payload_len > wire.MAX_PAYLOAD_LEN) {
            core.logging.warnWithSource(
                "ses",
                "ctl payload too large: type=0x{x:0>4} len={d} max={d} fd={d}",
                .{ hdr.msg_type, hdr.payload_len, wire.MAX_PAYLOAD_LEN, fd },
                @src(),
            );
            return false;
        }
        const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        ses.debugLog("ctl msg: type=0x{x:0>4} len={d} fd={d}", .{ hdr.msg_type, hdr.payload_len, fd });
        var buf: [65536]u8 = undefined;

        switch (msg_type) {
            .ping => {
                self.replyOrClose(fd, .pong, &.{});
            },
            .register => {
                self.handleBinaryRegister(fd, hdr.payload_len, &buf);
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
                self.replyOrClose(fd, .ok, &.{});
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
                    self.replyOrClose(fd, .@"error", &.{});
                    return false;
                }
                const pu = wire.readStruct(wire.PaneUuid, fd) catch |err| {
                    core.logging.logError("ses", "failed to read pane_info payload", err);
                    return false;
                };
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
            .session_split_pane => {
                self.handleBinarySessionSplitPane(fd, hdr.payload_len, &buf);
            },
            .session_replace_split_pane => {
                self.handleBinarySessionReplaceSplitPane(fd, hdr.payload_len, &buf);
            },
            .session_set_split_ratio => {
                self.handleBinarySessionSetSplitRatio(fd, hdr.payload_len, &buf);
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
                self.replyOrClose(fd, .@"error", &.{});
            },
        }
        return true;
    }

    fn skipBinaryPayload(_: *Server, fd: posix.fd_t, len: u32, buf: []u8) void {
        var remaining: usize = len;
        while (remaining > 0) {
            const chunk = @min(remaining, buf.len);
            wire.readExact(fd, buf[0..chunk]) catch |err| {
                core.logging.logError("ses", "failed to skip CTL payload", err);
                return;
            };
            remaining -= chunk;
        }
    }

    fn sendBinaryError(self: *Server, fd: posix.fd_t, msg: []const u8) void {
        var err_payload: wire.Error = .{ .msg_len = @intCast(@min(msg.len, std.math.maxInt(u16))) };
        self.replyOrCloseWithTrail(fd, .@"error", std.mem.asBytes(&err_payload), msg[0..err_payload.msg_len]);
    }

    fn handleBinaryRegister(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.Register)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "register: payload too small");
            return;
        }
        const reg = wire.readStruct(wire.FrontendRegister, fd) catch |err| {
            core.logging.logError("ses", "register request read failed", err);
            self.sendBinaryError(fd, "register: read failed");
            return;
        };

        const trailing_len: usize = @as(usize, reg.name_len) + @as(usize, reg.base_root_len);
        if (trailing_len != payload_len - @sizeOf(wire.Register)) {
            self.skipBinaryPayload(fd, payload_len - @sizeOf(wire.Register), buf);
            self.sendBinaryError(fd, "register: trailing payload size mismatch");
            return;
        }

        // Read trailing name and base root.
        var name_slice: []const u8 = "";
        var base_root_slice: []const u8 = "";
        if (trailing_len > 0) {
            if (trailing_len > wire.MAX_PAYLOAD_LEN) {
                // Name exceeds protocol limit - drain and reject
                self.skipBinaryPayload(fd, @intCast(trailing_len), buf);
                self.sendBinaryError(fd, "register: trailing payload exceeds MAX_PAYLOAD_LEN");
                return;
            }
            if (trailing_len <= buf.len) {
                wire.readExact(fd, buf[0..trailing_len]) catch |err| {
                    core.logging.logError("ses", "register trailing payload read failed", err);
                    self.sendBinaryError(fd, "register: name read failed");
                    return;
                };
                name_slice = buf[0..reg.name_len];
                base_root_slice = buf[reg.name_len..trailing_len];
            } else {
                // Name too large for buffer - drain bytes to keep stream aligned, then reject
                self.skipBinaryPayload(fd, @intCast(trailing_len), buf);
                self.sendBinaryError(fd, "register: trailing payload too long for buffer");
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
            const cid = self.ses_state.addClient(fd) catch |err| {
                core.logging.logError("ses", "register failed to add client", err);
                self.sendBinaryError(fd, "register: addClient failed");
                return;
            };
            break :blk cid;
        };

        // Resolve session name to ensure uniqueness (avoid collisions with detached sessions)
        const resolved_name: ?[]u8 = if (name_slice.len > 0)
            self.ses_state.resolveSessionName(name_slice, client_id, session_id) catch |err| {
                core.logging.logError("ses", "failed to resolve client session name", err);
                self.sendBinaryError(fd, "register: session name resolution failed");
                return;
            }
        else
            null;
        defer if (resolved_name) |rn| self.allocator.free(rn);

        if (self.ses_state.getClient(client_id)) |client| {
            client.keepalive = (reg.keepalive != 0);
            client.session_id = session_id;
            client.pending_reattach_session_id = null;
            client.mux_ctl_fd = fd;
            if (base_root_slice.len > 0) {
                const owned_root = client.allocator.dupe(u8, base_root_slice) catch |err| {
                    core.logging.logError("ses", "failed to store frontend base root", err);
                    self.sendBinaryError(fd, "register: base root allocation failed");
                    return;
                };
                if (client.base_root) |old| client.allocator.free(old);
                client.base_root = owned_root;
                if (client.session_snapshot) |*snapshot| {
                    if (snapshot.base_root) |old| snapshot.allocator.free(old);
                    snapshot.base_root = snapshot.allocator.dupe(u8, base_root_slice) catch |err| {
                        core.logging.logError("ses", "failed to store snapshot base root", err);
                        self.sendBinaryError(fd, "register: snapshot base root allocation failed");
                        return;
                    };
                }
            }
            // Store the resolved name (duplicated since resolved_name will be freed)
            if (resolved_name) |rn| {
                const owned_name = client.allocator.dupe(u8, rn) catch |err| {
                    core.logging.logError("ses", "failed to store resolved client session name", err);
                    self.sendBinaryError(fd, "register: session name allocation failed");
                    return;
                };
                if (client.session_name) |old| client.allocator.free(old);
                client.session_name = owned_name;
            } else {
                if (client.session_name) |old| client.allocator.free(old);
                client.session_name = null;
            }
        }

        // If this session_id matches a detached session, the frontend has successfully
        // restored it — remove the detached entry now.
        self.ses_state.removeDetachedSession(session_id);

        // Transaction log: reattach commit
        const hex_id: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
        self.ses_state.persistence.txlog.write(.reattach_commit, session_id, &hex_id) catch |err| {
            core.logging.logError("ses", "failed to write reattach_commit txlog entry", err);
        };

        // Release session lock (set during reattach in completeReattach)
        self.ses_state.releaseSessionLock(session_id);

        const final_name = resolved_name orelse name_slice;
        ses.debugLog("registered: session={s} name={s} (requested={s}) client_id={d}", .{ reg.session_id[0..8], final_name, name_slice, client_id });

        // Send Registered response with resolved name
        const resp = wire.FrontendRegistered{ .name_len = @intCast(final_name.len) };
        self.replyOrCloseWithTrail(fd, .registered, std.mem.asBytes(&resp), final_name);
    }

    fn handleBinarySessionAddTab(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.SessionAddTab)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "session_add_tab: payload too small");
            return;
        }
        const msg = wire.readStruct(wire.SessionAddTab, fd) catch |err| {
            core.logging.logError("ses", "session_add_tab request read failed", err);
            self.sendBinaryError(fd, "session_add_tab: read failed");
            return;
        };
        if (msg.name_len > wire.MAX_PAYLOAD_LEN or msg.name_len > buf.len) {
            self.skipBinaryPayload(fd, msg.name_len, buf);
            self.sendBinaryError(fd, "session_add_tab: name too large");
            return;
        }
        if (msg.name_len > 0) {
            wire.readExact(fd, buf[0..msg.name_len]) catch |err| {
                core.logging.logError("ses", "session_add_tab name read failed", err);
                self.sendBinaryError(fd, "session_add_tab: name read failed");
                return;
            };
        }

        const client_id = self.findClientForCtlFd(fd) orelse {
            core.logging.warn("ses", "session_add_tab from unregistered fd={d}", .{fd});
            self.sendBinaryError(fd, "session_add_tab: client not registered");
            return;
        };
        self.ses_state.addClientSessionTab(
            client_id,
            msg.tab_uuid,
            msg.pane_uuid,
            msg.tab_index,
            buf[0..msg.name_len],
        ) catch |err| {
            core.logging.logError("ses", "session_add_tab snapshot update failed", err);
            self.sendBinaryError(fd, "session_add_tab_failed");
            return;
        };
        self.pushClientSessionSnapshot(client_id);
        self.replyOrClose(fd, .ok, &.{});
    }

    fn handleBinarySessionRemoveTab(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.SessionRemoveTab)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "session_remove_tab: payload too small");
            return;
        }
        const msg = wire.readStruct(wire.SessionRemoveTab, fd) catch |err| {
            core.logging.logError("ses", "session_remove_tab request read failed", err);
            self.sendBinaryError(fd, "session_remove_tab: read failed");
            return;
        };
        const client_id = self.findClientForCtlFd(fd) orelse {
            core.logging.warn("ses", "session_remove_tab from unregistered fd={d}", .{fd});
            self.sendBinaryError(fd, "session_remove_tab: client not registered");
            return;
        };
        const client = self.ses_state.getClient(client_id) orelse {
            core.logging.warn("ses", "session_remove_tab missing client id={d}", .{client_id});
            self.sendBinaryError(fd, "session_remove_tab: client not found");
            return;
        };
        if (!self.requireSnapshotTab(fd, client, msg.tab_uuid, "session_remove_tab")) return;
        self.ses_state.removeClientSessionTab(
            client_id,
            msg.tab_uuid,
            if (msg.has_active_tab != 0) msg.active_tab else null,
        );
        self.pushClientSessionSnapshot(client_id);
        self.replyOrClose(fd, .ok, &.{});
    }

    fn handleBinarySessionSyncFloat(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.SessionSyncFloat)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "session_sync_float: payload too small");
            return;
        }
        const msg = wire.readStruct(wire.SessionSyncFloat, fd) catch |err| {
            core.logging.logError("ses", "session_sync_float request read failed", err);
            self.sendBinaryError(fd, "session_sync_float: read failed");
            return;
        };
        const client_id = self.findClientForCtlFd(fd) orelse {
            core.logging.warn("ses", "session_sync_float from unregistered fd={d}", .{fd});
            self.sendBinaryError(fd, "session_sync_float: client not registered");
            return;
        };
        if (!self.requireLiveAttachedPane(fd, client_id, msg.pane_uuid, "session_sync_float")) return;
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
        ) catch |err| {
            core.logging.logError("ses", "session_sync_float snapshot update failed", err);
            self.sendBinaryError(fd, "session_sync_float_failed");
            return;
        };
        self.pushClientSessionSnapshot(client_id);
        self.replyOrClose(fd, .ok, &.{});
    }

    fn handleBinarySessionRemoveFloat(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.SessionRemoveFloat)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "session_remove_float: payload too small");
            return;
        }
        const msg = wire.readStruct(wire.SessionRemoveFloat, fd) catch |err| {
            core.logging.logError("ses", "session_remove_float request read failed", err);
            self.sendBinaryError(fd, "session_remove_float: read failed");
            return;
        };
        const client_id = self.findClientForCtlFd(fd) orelse {
            core.logging.warn("ses", "session_remove_float from unregistered fd={d}", .{fd});
            self.sendBinaryError(fd, "session_remove_float: client not registered");
            return;
        };
        const client = self.ses_state.getClient(client_id) orelse {
            core.logging.warn("ses", "session_remove_float missing client id={d}", .{client_id});
            self.sendBinaryError(fd, "session_remove_float: client not found");
            return;
        };
        if (!self.requireSnapshotPane(fd, client, msg.pane_uuid, "session_remove_float")) return;
        self.ses_state.removeClientSessionFloat(client_id, msg.pane_uuid);
        self.pushClientSessionSnapshot(client_id);
        self.replyOrClose(fd, .ok, &.{});
    }

    fn handleBinarySessionSplitPane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.SessionSplitPane)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "session_split_pane: payload too small");
            return;
        }
        const msg = wire.readStruct(wire.SessionSplitPane, fd) catch |err| {
            core.logging.logError("ses", "session_split_pane request read failed", err);
            self.sendBinaryError(fd, "session_split_pane: read failed");
            return;
        };
        const dir: core.session_model.SessionSplitDir = switch (msg.dir) {
            0 => .horizontal,
            1 => .vertical,
            else => {
                self.sendBinaryError(fd, "session_split_pane: invalid dir");
                return;
            },
        };
        const client_id = self.findClientForCtlFd(fd) orelse {
            core.logging.warn("ses", "session_split_pane from unregistered fd={d}", .{fd});
            self.sendBinaryError(fd, "session_split_pane: client not registered");
            return;
        };
        const client = self.ses_state.getClient(client_id) orelse {
            core.logging.warn("ses", "session_split_pane missing client id={d}", .{client_id});
            self.sendBinaryError(fd, "session_split_pane: client not found");
            return;
        };
        if (!self.requireSnapshotTab(fd, client, msg.tab_uuid, "session_split_pane")) return;
        if (!self.requireSnapshotPane(fd, client, msg.source_pane_uuid, "session_split_pane")) return;
        if (!self.requireLiveAttachedPane(fd, client_id, msg.new_pane_uuid, "session_split_pane")) return;
        self.ses_state.splitClientSessionPane(
            client_id,
            msg.tab_uuid,
            msg.source_pane_uuid,
            msg.new_pane_uuid,
            msg.active_tab,
            if (msg.has_focused_pane != 0) msg.focused_pane_uuid else null,
            dir,
        ) catch |err| {
            core.logging.logError("ses", "session_split_pane snapshot update failed", err);
            self.sendBinaryError(fd, "session_split_pane_failed");
            return;
        };
        self.pushClientSessionSnapshot(client_id);
        self.replyOrClose(fd, .ok, &.{});
    }

    fn handleBinarySessionReplaceSplitPane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.SessionReplaceSplitPane)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "session_replace_split_pane: payload too small");
            return;
        }
        const msg = wire.readStruct(wire.SessionReplaceSplitPane, fd) catch |err| {
            core.logging.logError("ses", "session_replace_split_pane request read failed", err);
            self.sendBinaryError(fd, "session_replace_split_pane: read failed");
            return;
        };
        const client_id = self.findClientForCtlFd(fd) orelse {
            core.logging.warn("ses", "session_replace_split_pane from unregistered fd={d}", .{fd});
            self.sendBinaryError(fd, "session_replace_split_pane: client not registered");
            return;
        };
        const client = self.ses_state.getClient(client_id) orelse {
            core.logging.warn("ses", "session_replace_split_pane missing client id={d}", .{client_id});
            self.sendBinaryError(fd, "session_replace_split_pane: client not found");
            return;
        };
        if (!self.requireSnapshotTab(fd, client, msg.tab_uuid, "session_replace_split_pane")) return;
        if (!self.requireSnapshotPane(fd, client, msg.old_pane_uuid, "session_replace_split_pane")) return;
        if (!self.requireLiveAttachedPane(fd, client_id, msg.new_pane_uuid, "session_replace_split_pane")) return;
        self.ses_state.replaceClientSessionSplitPane(
            client_id,
            msg.tab_uuid,
            msg.old_pane_uuid,
            msg.new_pane_uuid,
            msg.active_tab,
            if (msg.has_focused_pane != 0) msg.focused_pane_uuid else null,
        ) catch |err| {
            core.logging.logError("ses", "session_replace_split_pane snapshot update failed", err);
            self.sendBinaryError(fd, "session_replace_split_pane_failed");
            return;
        };
        self.pushClientSessionSnapshot(client_id);
        self.replyOrClose(fd, .ok, &.{});
    }

    fn handleBinarySessionSetSplitRatio(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.SessionSetSplitRatio)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "session_set_split_ratio: payload too small");
            return;
        }
        const msg = wire.readStruct(wire.SessionSetSplitRatio, fd) catch |err| {
            core.logging.logError("ses", "session_set_split_ratio request read failed", err);
            self.sendBinaryError(fd, "session_set_split_ratio: read failed");
            return;
        };
        const client_id = self.findClientForCtlFd(fd) orelse {
            core.logging.warn("ses", "session_set_split_ratio from unregistered fd={d}", .{fd});
            self.sendBinaryError(fd, "session_set_split_ratio: client not registered");
            return;
        };
        const client = self.ses_state.getClient(client_id) orelse {
            core.logging.warn("ses", "session_set_split_ratio missing client id={d}", .{client_id});
            self.sendBinaryError(fd, "session_set_split_ratio: client not found");
            return;
        };
        if (!self.requireSnapshotTab(fd, client, msg.tab_uuid, "session_set_split_ratio")) return;
        if (!self.requireSnapshotPane(fd, client, msg.first_anchor_uuid, "session_set_split_ratio")) return;
        if (!self.requireSnapshotPane(fd, client, msg.second_anchor_uuid, "session_set_split_ratio")) return;
        self.ses_state.setClientSessionSplitRatio(
            client_id,
            msg.tab_uuid,
            msg.active_tab,
            msg.first_anchor_uuid,
            msg.second_anchor_uuid,
            msg.ratio,
        ) catch |err| {
            core.logging.logError("ses", "session_set_split_ratio snapshot update failed", err);
            self.sendBinaryError(fd, "session_set_split_ratio_failed");
            return;
        };
        self.pushClientSessionSnapshot(client_id);
        self.replyOrClose(fd, .ok, &.{});
    }

    fn handleBinaryCreatePane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.CreatePane)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "create_pane: payload too small for CreatePane struct");
            return;
        }
        const cp = wire.readStruct(wire.CreatePane, fd) catch |err| {
            core.logging.logError("ses", "create_pane request read failed", err);
            self.sendBinaryError(fd, "create_pane: read failed");
            return;
        };
        const trail_len = payload_len - @sizeOf(wire.CreatePane);

        // Read trailing: shell + cwd + sticky_pwd.
        if (trail_len > buf.len) {
            self.skipBinaryPayload(fd, trail_len, buf);
            self.sendBinaryError(fd, "payload_too_large");
            return;
        }
        if (trail_len > 0) {
            wire.readExact(fd, buf[0..trail_len]) catch |err| {
                core.logging.logError("ses", "create_pane trail read failed", err);
                self.sendBinaryError(fd, "create_pane: trail read failed");
                return;
            };
        }

        ses.debugLog("create_pane: shell_len={d} cwd_len={d} sticky_key={d} isolation_profile_len={d} env_count={d}", .{ cp.shell_len, cp.cwd_len, cp.sticky_key, cp.isolation_profile_len, cp.env_count });

        var offset: usize = 0;
        const shell = if (cp.shell_len > 0) blk: {
            if (offset + cp.shell_len > trail_len) {
                self.sendBinaryError(fd, "create_pane: malformed shell trail");
                return;
            }
            const s = buf[offset .. offset + cp.shell_len];
            offset += cp.shell_len;
            break :blk s;
        } else blk: {
            break :blk @as([]const u8, std.posix.getenv("SHELL") orelse "/bin/sh");
        };
        const cwd: ?[]const u8 = if (cp.cwd_len > 0) blk: {
            if (offset + cp.cwd_len > trail_len) {
                self.sendBinaryError(fd, "create_pane: malformed cwd trail");
                return;
            }
            const c = buf[offset .. offset + cp.cwd_len];
            offset += cp.cwd_len;
            break :blk c;
        } else null;
        const sticky_pwd: ?[]const u8 = if (cp.sticky_pwd_len > 0) blk: {
            if (offset + cp.sticky_pwd_len > trail_len) {
                self.sendBinaryError(fd, "create_pane: malformed sticky pwd trail");
                return;
            }
            const p = buf[offset .. offset + cp.sticky_pwd_len];
            offset += cp.sticky_pwd_len;
            break :blk p;
        } else null;
        const isolation_profile: ?[]const u8 = if (cp.isolation_profile_len > 0) blk: {
            if (offset + cp.isolation_profile_len > trail_len) {
                self.sendBinaryError(fd, "create_pane: malformed isolation profile trail");
                return;
            }
            const p = buf[offset .. offset + cp.isolation_profile_len];
            offset += cp.isolation_profile_len;
            break :blk p;
        } else null;
        const inherit_env_parent_uuid: ?[32]u8 = if (cp.inherit_env_parent_uuid_len > 0) blk: {
            if (cp.inherit_env_parent_uuid_len != 32 or offset + 32 > trail_len) {
                self.sendBinaryError(fd, "create_pane: malformed inherit-env parent uuid");
                return;
            }
            var uuid: [32]u8 = undefined;
            @memcpy(&uuid, buf[offset .. offset + 32]);
            offset += 32;
            break :blk uuid;
        } else null;
        const sticky_key: ?u8 = if (cp.sticky_key != 0) cp.sticky_key else null;

        var env_list: std.ArrayList([]const u8) = .empty;
        defer env_list.deinit(self.allocator);
        for (0..cp.env_count) |_| {
            if (offset + 2 > trail_len) {
                self.sendBinaryError(fd, "create_pane: malformed env entry header");
                return;
            }
            const entry_len = std.mem.readInt(u16, buf[offset..][0..2], .little);
            offset += 2;
            if (offset + entry_len > trail_len) {
                self.sendBinaryError(fd, "create_pane: malformed env entry body");
                return;
            }
            env_list.append(self.allocator, buf[offset .. offset + entry_len]) catch |err| {
                core.logging.logError("ses", "create_pane env list allocation failed", err);
                self.sendBinaryError(fd, "create_pane: env list alloc failed");
                return;
            };
            offset += entry_len;
        }
        if (offset != trail_len) {
            self.sendBinaryError(fd, "create_pane: trailing payload length mismatch");
            return;
        }

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

        var merged_env_storage: ?[]const []const u8 = null;
        defer if (merged_env_storage) |slice| self.allocator.free(slice);
        const spawn_env: ?[]const []const u8 = blk: {
            if (parent_env) |base| {
                if (env_list.items.len == 0) break :blk base;
                const merged = self.allocator.alloc([]const u8, base.len + env_list.items.len) catch |err| {
                    core.logging.logError("ses", "create_pane environment merge allocation failed", err);
                    self.sendBinaryError(fd, "create_pane: env merge alloc failed");
                    return;
                };
                @memcpy(merged[0..base.len], base);
                @memcpy(merged[base.len..], env_list.items);
                merged_env_storage = merged;
                break :blk merged;
            }
            if (env_list.items.len > 0) break :blk env_list.items;
            break :blk null;
        };

        const client_id = self.findClientForCtlFd(fd) orelse blk: {
            const cid = self.ses_state.addClient(fd) catch |err| {
                core.logging.logError("ses", "create_pane failed to add client", err);
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
                            _ = self.ses_state.attachPane(existing.uuid, client_id) catch |err| {
                                core.logging.logError("ses", "create_pane failed to attach stolen sticky pane", err);
                                self.sendBinaryError(fd, "attach_existing_failed");
                                return;
                            };
                        }
                    } else {
                        _ = self.ses_state.attachPane(existing.uuid, client_id) catch |err| {
                            core.logging.logError("ses", "create_pane failed to attach sticky pane", err);
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
                    self.replyOrCloseWithTrail(fd, .pane_created, std.mem.asBytes(&existing_resp), existing.pod_socket_path);
                    return;
                }
            }
        }

        const pane = self.ses_state.createPane(client_id, shell, cwd, sticky_pwd, sticky_key, spawn_env, isolation_profile) catch |err| {
            core.logging.logError("ses", "create_pane failed to spawn pane", err);
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
        self.replyOrCloseWithTrail(fd, .pane_created, std.mem.asBytes(&resp), pane.pod_socket_path);
    }

    fn handleBinaryFindSticky(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.FindSticky)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "find_sticky: payload too small");
            return;
        }
        const fs = wire.readStruct(wire.FindSticky, fd) catch |err| {
            core.logging.logError("ses", "find_sticky request read failed", err);
            self.sendBinaryError(fd, "find_sticky: read failed");
            return;
        };
        if (fs.pwd_len > buf.len) {
            self.skipBinaryPayload(fd, fs.pwd_len, buf);
            self.sendBinaryError(fd, "find_sticky: pwd too large");
            return;
        }
        if (fs.pwd_len > 0) {
            wire.readExact(fd, buf[0..fs.pwd_len]) catch |err| {
                core.logging.logError("ses", "find_sticky pwd read failed", err);
                self.sendBinaryError(fd, "find_sticky: pwd read failed");
                return;
            };
        }
        const pwd = buf[0..fs.pwd_len];

        const client_id = self.findClientForCtlFd(fd) orelse {
            self.replyOrClose(fd, .pane_not_found, &.{});
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

            _ = self.ses_state.attachPane(pane.uuid, client_id) catch |err| {
                core.logging.logError("ses", "find_sticky failed to attach sticky pane", err);
                self.replyOrClose(fd, .pane_not_found, &.{});
                return;
            };

            // New mux needs a full screen restore for sticky adoption/takeover.
            // Queue it for the periodic worker instead of reconnecting POD VT
            // inline from the CTL handler, which can make attach feel hung.
            if (self.ses_state.getPane(pane.uuid)) |p| {
                p.needs_backlog_replay = true;
            }
            ses.debugLog("find_sticky: queued deferred backlog replay for uuid={s}", .{pane.uuid[0..8]});

            var resp = wire.PaneFound{
                .uuid = pane.uuid,
                .pid = pane.child_pid,
                .pane_id = pane.pane_id,
                .socket_path_len = @intCast(pane.pod_socket_path.len),
            };
            self.replyOrCloseWithTrail(fd, .pane_found, std.mem.asBytes(&resp), pane.pod_socket_path);
        } else {
            self.replyOrClose(fd, .pane_not_found, &.{});
        }
    }

    fn handleBinaryOrphanPane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.PaneUuid)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "orphan_pane: payload too small for PaneUuid");
            return;
        }
        const pu = wire.readStruct(wire.PaneUuid, fd) catch |err| {
            core.logging.logError("ses", "orphan_pane request read failed", err);
            self.sendBinaryError(fd, "orphan_pane: read failed");
            return;
        };
        self.ses_state.suspendPane(pu.uuid) catch |e| {
            ses.debugLog("handleBinaryOrphanPane: suspendPane error: {s}", .{@errorName(e)});
            self.sendBinaryError(fd, "orphan_pane: pane not found");
            return;
        };
        self.ses_state.markDirty();
        self.replyOrClose(fd, .ok, &.{});
    }

    fn handleBinaryAdoptPane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.PaneUuid)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "adopt_pane: payload too small for PaneUuid");
            return;
        }
        const pu = wire.readStruct(wire.PaneUuid, fd) catch |err| {
            core.logging.logError("ses", "adopt_pane request read failed", err);
            self.sendBinaryError(fd, "adopt_pane: read failed");
            return;
        };

        const client_id = self.findClientForCtlFd(fd) orelse {
            self.sendBinaryError(fd, "adopt_pane: client not registered");
            return;
        };

        const pane = self.ses_state.attachPane(pu.uuid, client_id) catch |err| {
            core.logging.logError("ses", "adopt_pane failed to attach pane", err);
            self.sendBinaryError(fd, "adopt_pane: pane not found or already attached");
            return;
        };

        // Adopt into a fresh mux view: request a screen restore, but do not
        // run replay inline. Reconnecting POD VT sockets from the CTL handler
        // can stall attach/reattach; the periodic replay worker will pick this
        // up once the mux VT channel is ready.
        pane.needs_backlog_replay = true;
        ses.debugLog("adopt_pane: queued deferred backlog replay for uuid={s}", .{pu.uuid[0..8]});

        self.ses_state.markDirty();

        var resp = wire.PaneFound{
            .uuid = pane.uuid,
            .pid = pane.child_pid,
            .pane_id = pane.pane_id,
            .socket_path_len = @intCast(pane.pod_socket_path.len),
        };
        self.replyOrCloseWithTrail(fd, .pane_found, std.mem.asBytes(&resp), pane.pod_socket_path);
    }

    fn handleBinaryKillPane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.PaneUuid)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "kill_pane: payload too small for PaneUuid");
            return;
        }
        const pu = wire.readStruct(wire.PaneUuid, fd) catch |err| {
            core.logging.logError("ses", "kill_pane request read failed", err);
            self.sendBinaryError(fd, "kill_pane: read failed");
            return;
        };
        const client_id = self.findClientForCtlFd(fd);
        const hex_uuid: [32]u8 = std.fmt.bytesToHex(pu.uuid[0..16], .lower);
        ses.debugLog("handleBinaryKillPane: uuid={s} ctl_fd={d}", .{ hex_uuid[0..8], fd });
        self.ses_state.killPane(pu.uuid) catch |e| {
            ses.debugLog("handleBinaryKillPane: killPane error: {s}", .{@errorName(e)});
            self.sendBinaryError(fd, "kill_pane: pane not found");
            return;
        };
        self.ses_state.markDirty();
        if (client_id) |cid| {
            self.pushClientSessionSnapshot(cid);
        }
        ses.debugLog("handleBinaryKillPane: sending .ok response", .{});
        self.replyOrClose(fd, .ok, &.{});
        ses.debugLog("handleBinaryKillPane: done", .{});
    }

    fn handleBinarySetSticky(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.SetSticky)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "set_sticky: payload too small");
            return;
        }
        const ss = wire.readStruct(wire.SetSticky, fd) catch |err| {
            core.logging.logError("ses", "set_sticky request read failed", err);
            self.sendBinaryError(fd, "set_sticky: read failed");
            return;
        };
        if (ss.pwd_len > buf.len) {
            self.skipBinaryPayload(fd, ss.pwd_len, buf);
            self.sendBinaryError(fd, "set_sticky: pwd too large");
            return;
        }
        if (ss.pwd_len > 0) {
            wire.readExact(fd, buf[0..ss.pwd_len]) catch |err| {
                core.logging.logError("ses", "set_sticky pwd read failed", err);
                self.sendBinaryError(fd, "set_sticky: pwd read failed");
                return;
            };
        }

        if (self.ses_state.store.panes.getPtr(ss.uuid)) |pane| {
            const new_sticky_pwd = if (ss.pwd_len > 0)
                self.allocator.dupe(u8, buf[0..ss.pwd_len]) catch |err| {
                    core.logging.logError("ses", "failed to store sticky pane cwd", err);
                    self.sendBinaryError(fd, "set_sticky: cwd allocation failed");
                    return;
                }
            else
                null;

            pane.sticky_key = if (ss.key != 0) ss.key else null;

            // Store session name for affinity
            const client_id = self.findClientForCtlFd(fd) orelse null;
            const new_sticky_session_name = if (client_id) |cid| blk: {
                if (self.ses_state.getClient(cid)) |client| {
                    if (client.session_name) |sn| {
                        break :blk self.allocator.dupe(u8, sn) catch |err| {
                            core.logging.logError("ses", "failed to store sticky pane session name", err);
                            if (new_sticky_pwd) |owned| self.allocator.free(owned);
                            self.sendBinaryError(fd, "set_sticky: session name allocation failed");
                            return;
                        };
                    }
                }
                break :blk null;
            } else null;

            if (pane.sticky_pwd) |old| self.allocator.free(old);
            if (pane.sticky_session_name) |old_ssn| self.allocator.free(old_ssn);
            pane.sticky_pwd = new_sticky_pwd;
            pane.sticky_session_name = new_sticky_session_name;

            // set_sticky sets sticky metadata, but must not force attached panes
            // into sticky state. Sticky state is entered on suspend/disown.
            if (pane.sticky_pwd != null and pane.attached_to == null) {
                _ = pane.transitionState(.sticky, "set_sticky command");
            }
            self.ses_state.markDirty();
        }
        self.replyOrClose(fd, .ok, &.{});
    }

    fn handleBinaryGetPaneCwd(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.GetPaneCwd)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "get_pane_cwd: payload too small");
            return;
        }
        const gpc = wire.readStruct(wire.GetPaneCwd, fd) catch |err| {
            core.logging.logError("ses", "get_pane_cwd request read failed", err);
            self.sendBinaryError(fd, "get_pane_cwd: read failed");
            return;
        };

        if (self.ses_state.getPane(gpc.uuid)) |pane| {
            const cwd = pane.getProcCwd();
            if (cwd) |c| {
                var resp = wire.PaneCwd{ .uuid = gpc.uuid, .cwd_len = @intCast(c.len) };
                self.replyOrCloseWithTrail(fd, .get_pane_cwd, std.mem.asBytes(&resp), c);
                return;
            }
        }
        // No CWD available.
        var resp = wire.PaneCwd{ .uuid = gpc.uuid, .cwd_len = 0 };
        self.replyOrClose(fd, .get_pane_cwd, std.mem.asBytes(&resp));
    }

    fn handleBinaryListOrphaned(self: *Server, fd: posix.fd_t, buf: []u8) void {
        _ = buf;
        const orphaned = self.ses_state.getOrphanedPanes(self.allocator) catch |err| {
            core.logging.logError("ses", "failed to collect orphaned panes", err);
            self.sendBinaryError(fd, "list_orphaned: collection failed");
            return;
        };
        defer self.allocator.free(orphaned);

        // Build response: OrphanedPanes header + pane_count * OrphanedPaneEntry.
        var resp_hdr = wire.OrphanedPanes{ .pane_count = @intCast(@min(orphaned.len, 32)) };
        const entry_count: usize = resp_hdr.pane_count;
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        var writer = payload.writer(self.allocator);
        writer.writeAll(std.mem.asBytes(&resp_hdr)) catch |err| {
            core.logging.logError("ses", "failed to build orphaned panes list header", err);
            self.sendBinaryError(fd, "list_orphaned: response alloc failed");
            return;
        };
        for (orphaned[0..entry_count]) |pane| {
            const name = pane.name orelse "";
            var entry = wire.OrphanedPaneEntry{
                .uuid = pane.uuid,
                .pid = pane.child_pid,
                .name_len = @intCast(@min(name.len, 64)),
            };
            writer.writeAll(std.mem.asBytes(&entry)) catch |err| {
                core.logging.logError("ses", "failed to build orphaned panes list entry", err);
                self.sendBinaryError(fd, "list_orphaned: response alloc failed");
                return;
            };
            if (entry.name_len > 0) {
                writer.writeAll(name[0..entry.name_len]) catch |err| {
                    core.logging.logError("ses", "failed to build orphaned pane name", err);
                    self.sendBinaryError(fd, "list_orphaned: response alloc failed");
                    return;
                };
            }
        }
        self.replyOrClose(fd, .orphaned_panes, payload.items);
    }

    fn handleBinaryListSessions(self: *Server, fd: posix.fd_t, buf: []u8) void {
        _ = buf;
        const sessions = self.ses_state.listDetachedSessions(self.allocator) catch |err| {
            core.logging.logError("ses", "failed to collect detached sessions", err);
            self.sendBinaryError(fd, "list_sessions: collection failed");
            return;
        };
        defer self.allocator.free(sessions);

        const entry_count = @min(sessions.len, std.math.maxInt(u16));
        var resp_hdr = wire.SessionsList{ .session_count = @intCast(entry_count) };
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        var writer = payload.writer(self.allocator);
        writer.writeAll(std.mem.asBytes(&resp_hdr)) catch |err| {
            core.logging.logError("ses", "failed to build detached sessions list header", err);
            self.sendBinaryError(fd, "list_sessions: response alloc failed");
            return;
        };

        for (sessions[0..entry_count]) |s| {
            if (s.session_name.len > std.math.maxInt(u16)) {
                self.sendBinaryError(fd, "list_sessions: session name too long");
                return;
            }
            if (s.base_root.len > std.math.maxInt(u16)) {
                self.sendBinaryError(fd, "list_sessions: base root too long");
                return;
            }
            const hex_id: [32]u8 = std.fmt.bytesToHex(&s.session_id, .lower);
            var entry = wire.SessionEntry{
                .session_id = hex_id,
                .pane_count = @intCast(@min(s.pane_count, std.math.maxInt(u16))),
                .name_len = @intCast(s.session_name.len),
                .base_root_len = @intCast(s.base_root.len),
            };
            writer.writeAll(std.mem.asBytes(&entry)) catch |err| {
                core.logging.logError("ses", "failed to build detached sessions list entry", err);
                self.sendBinaryError(fd, "list_sessions: response alloc failed");
                return;
            };
            if (s.session_name.len > 0) {
                writer.writeAll(s.session_name) catch |err| {
                    core.logging.logError("ses", "failed to build detached sessions list name", err);
                    self.sendBinaryError(fd, "list_sessions: response alloc failed");
                    return;
                };
            }
            if (s.base_root.len > 0) {
                writer.writeAll(s.base_root) catch |err| {
                    core.logging.logError("ses", "failed to build detached sessions list base root", err);
                    self.sendBinaryError(fd, "list_sessions: response alloc failed");
                    return;
                };
            }
        }
        self.replyOrClose(fd, .sessions_list, payload.items);
    }

    fn handleBinaryDetach(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.Detach)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "detach: payload too small for Detach header");
            return;
        }
        const det = wire.readStruct(wire.Detach, fd) catch |err| {
            core.logging.logError("ses", "detach request read failed", err);
            self.sendBinaryError(fd, "detach: read failed");
            return;
        };
        const extra_len = payload_len - @sizeOf(wire.Detach);
        if (extra_len > 0) {
            self.skipBinaryPayload(fd, extra_len, buf);
            self.sendBinaryError(fd, "detach: legacy state payload is no longer accepted");
            return;
        }

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
        self.ses_state.acquireSessionLock(session_id, client_id, .detaching) catch |err| {
            core.logging.logError("ses", "detach failed to acquire session lock", err);
            self.sendBinaryError(fd, "session_locked: another client is attaching this session");
            return;
        };
        // Lock will be released after detach completes

        if (self.ses_state.detachSession(client_id, session_id, session_name)) {
            self.ses_state.markDirty();
            // Release lock after successful detach
            self.ses_state.releaseSessionLock(session_id);
            self.replyOrClose(fd, .session_detached, &.{});
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
        const ra = wire.readStruct(wire.Reattach, fd) catch |err| {
            core.logging.logError("ses", "reattach request read failed", err);
            self.sendBinaryError(fd, "reattach: read failed");
            return;
        };
        if (ra.id_len > buf.len or ra.id_len == 0) {
            self.skipBinaryPayload(fd, ra.id_len, buf);
            self.sendBinaryError(fd, "invalid_id");
            return;
        }
        wire.readExact(fd, buf[0..ra.id_len]) catch |err| {
            core.logging.logError("ses", "reattach id read failed", err);
            self.sendBinaryError(fd, "reattach: id read failed");
            return;
        };
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
        var ds_iter = self.ses_state.store.detached_sessions.iterator();
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

        ds_iter = self.ses_state.store.detached_sessions.iterator();
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
            for (self.ses_state.store.clients.items) |client| {
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
                    core.logging.warn("ses", "reattach failed to force-detach attached session by uuid session={s}", .{id_prefix});
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

            for (self.ses_state.store.clients.items) |client| {
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
                    core.logging.warn("ses", "reattach failed to force-detach attached session by name session={s}", .{id_prefix});
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
            attached_writer.print("ambiguous: multiple sessions named '{s}'. Use UUID prefix:\n", .{id_prefix}) catch {
                self.sendBinaryError(fd, "ambiguous_session_name");
                return;
            };
            for (attached_name_matches[0..attached_name_count]) |match| {
                const hex_id = std.fmt.bytesToHex(&match.session_id, .lower);
                attached_writer.print("  {s} ({s})\n", .{ hex_id[0..8], match.name }) catch {
                    self.sendBinaryError(fd, "ambiguous_session_name");
                    return;
                };
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
        writer.print("ambiguous: multiple sessions named '{s}'. Use UUID prefix:\n", .{id_prefix}) catch {
            self.sendBinaryError(fd, "ambiguous_session_name");
            return;
        };
        for (name_matches[0..name_match_count]) |match| {
            const hex_id = std.fmt.bytesToHex(&match.session_id, .lower);
            writer.print("  {s} ({s})\n", .{ hex_id[0..8], match.name }) catch {
                self.sendBinaryError(fd, "ambiguous_session_name");
                return;
            };
        }
        self.sendBinaryError(fd, err_stream.getWritten());
    }

    /// Helper to complete reattach after session_id is resolved.
    fn completeReattach(self: *Server, fd: posix.fd_t, session_id: [16]u8, client_id: usize) void {
        const hex_id_dbg: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
        ses.debugLog("completeReattach: begin session={s} client_id={d} fd={d}", .{ hex_id_dbg[0..8], client_id, fd });

        // Transaction log: reattach start
        const hex_id: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
        self.ses_state.persistence.txlog.write(.reattach_start, session_id, &hex_id) catch |err| {
            core.logging.logError("ses", "failed to write reattach_start txlog entry", err);
        };

        // Acquire session lock to prevent concurrent reattach
        self.ses_state.acquireSessionLock(session_id, client_id, .attaching) catch |err| {
            core.logging.logError("ses", "reattach failed to acquire session lock", err);
            self.sendBinaryError(fd, "session_locked: another client is attaching this session");
            return;
        };
        // Note: Lock will be released in handleBinaryRegister after successful registration

        const result = self.ses_state.reattachSession(session_id, client_id) catch |err| {
            core.logging.logError("ses", "reattach session state mutation failed", err);
            ses.debugLog("completeReattach: ses_state.reattachSession threw", .{});
            self.ses_state.releaseSessionLock(session_id);
            self.sendBinaryError(fd, "reattach_failed");
            return;
        };
        if (result == null) {
            ses.debugLog("completeReattach: session not found after lock", .{});
            self.ses_state.releaseSessionLock(session_id);
            self.sendBinaryError(fd, "session_not_found");
            return;
        }
        const reattach_result = result.?;
        ses.debugLog("completeReattach: borrowed snapshot panes={d}", .{reattach_result.pane_uuids.len});
        const snapshot = reattach_result.session_snapshot;
        ses.debugLog(
            "completeReattach: snapshot name={s} uuid={s} tabs={d} panes={d} floats={d} active_tab={d}",
            .{
                snapshot.session_name,
                snapshot.uuid[0..8],
                snapshot.tabs.items.len,
                snapshot.panes.count(),
                snapshot.floats.items.len,
                snapshot.active_tab,
            },
        );
        for (snapshot.tabs.items, 0..) |tab, idx| {
            ses.debugLog(
                "completeReattach: tab[{d}] name={s} root={} focused={}",
                .{ idx, tab.name, tab.root != null, tab.focused_pane_uuid != null },
            );
        }
        const session_json = reattach_result.session_snapshot.toJson(self.allocator) catch |err| {
            core.logging.logError("ses", "reattach snapshot serialization failed", err);
            ses.debugLog("completeReattach: snapshot toJson failed", .{});
            self.ses_state.releaseSessionLock(session_id);
            self.sendBinaryError(fd, "reattach_snapshot_failed");
            return;
        };
        defer self.allocator.free(session_json);
        ses.debugLog("completeReattach: session_json_len={d}", .{session_json.len});

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
        ses.debugLog("completeReattach: writing response payload={d}", .{total_payload});
        wire.writeAll(fd, std.mem.asBytes(&ctrl_hdr)) catch |err| {
            core.logging.logError("ses", "reattach response header write failed", err);
            self.ses_state.releaseSessionLock(session_id);
            return;
        };
        wire.writeAll(fd, std.mem.asBytes(&resp)) catch |err| {
            core.logging.logError("ses", "reattach response body header write failed", err);
            self.ses_state.releaseSessionLock(session_id);
            return;
        };
        wire.writeAll(fd, session_json) catch |err| {
            core.logging.logError("ses", "reattach response session json write failed", err);
            self.ses_state.releaseSessionLock(session_id);
            return;
        };
        for (reattach_result.pane_uuids) |uuid| {
            wire.writeAll(fd, &uuid) catch |err| {
                core.logging.logError("ses", "reattach response pane uuid write failed", err);
                self.ses_state.releaseSessionLock(session_id);
                return;
            };
        }
        ses.debugLog("completeReattach: response sent", .{});
    }

    fn handleBinaryDisconnect(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.Disconnect)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "disconnect: payload too small");
            return;
        }
        const dc = wire.readStruct(wire.Disconnect, fd) catch |err| {
            core.logging.logError("ses", "disconnect request read failed", err);
            self.sendBinaryError(fd, "disconnect: read failed");
            return;
        };
        const client_id = self.findClientForCtlFd(fd) orelse {
            core.logging.warn("ses", "disconnect from unregistered fd={d}", .{fd});
            self.sendBinaryError(fd, "disconnect: client not registered");
            return;
        };

        if (dc.mode == 0) { // shutdown
            self.ses_state.shutdownClient(client_id, dc.preserve_sticky != 0);
        } else {
            self.ses_state.removeClientGraceful(client_id);
        }
        self.replyOrClose(fd, .ok, &.{});
    }

    fn handleBinaryUpdatePaneName(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.UpdatePaneName)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "update_pane_name: payload too small");
            return;
        }
        const upn = wire.readStruct(wire.UpdatePaneName, fd) catch |err| {
            core.logging.logError("ses", "update_pane_name request read failed", err);
            self.sendBinaryError(fd, "update_pane_name: read failed");
            return;
        };
        if (upn.name_len > wire.MAX_PAYLOAD_LEN or upn.name_len > buf.len) {
            self.skipBinaryPayload(fd, upn.name_len, buf);
            self.sendBinaryError(fd, "update_pane_name: name too large");
            return;
        }
        if (upn.name_len > 0) {
            wire.readExact(fd, buf[0..upn.name_len]) catch |err| {
                core.logging.logError("ses", "update_pane_name name read failed", err);
                self.sendBinaryError(fd, "update_pane_name: name read failed");
                return;
            };
        }

        if (self.ses_state.store.panes.getPtr(upn.uuid)) |pane| {
            const new_name = if (upn.name_len > 0)
                self.allocator.dupe(u8, buf[0..upn.name_len]) catch |err| {
                    core.logging.logError("ses", "failed to store pane name", err);
                    self.sendBinaryError(fd, "update_pane_name: name allocation failed");
                    return;
                }
            else
                null;
            if (pane.name) |old| self.allocator.free(old);
            pane.name = new_name;
            self.ses_state.markDirty();
        }
        self.replyOrClose(fd, .ok, &.{});
    }

    fn handleBinaryUpdatePaneAux(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.UpdatePaneAux)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "update_pane_aux: payload too small");
            return;
        }
        const upa = wire.readStruct(wire.UpdatePaneAux, fd) catch |err| {
            core.logging.logError("ses", "update_pane_aux request read failed", err);
            self.sendBinaryError(fd, "update_pane_aux: read failed");
            return;
        };
        const client_id = self.findClientForCtlFd(fd);

        if (self.ses_state.store.panes.getPtr(upa.uuid)) |pane| {
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
        self.replyOrClose(fd, .ok, &.{});
    }

    fn handleBinaryUpdatePaneShell(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.UpdatePaneShell)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "update_pane_shell: payload too small");
            return;
        }
        const ups = wire.readStruct(wire.UpdatePaneShell, fd) catch |err| {
            core.logging.logError("ses", "update_pane_shell request read failed", err);
            self.sendBinaryError(fd, "update_pane_shell: read failed");
            return;
        };
        const trail_len = payload_len - @sizeOf(wire.UpdatePaneShell);
        if (trail_len > wire.MAX_PAYLOAD_LEN or trail_len > buf.len) {
            self.skipBinaryPayload(fd, trail_len, buf);
            self.sendBinaryError(fd, "update_pane_shell: payload too large");
            return;
        }
        if (trail_len > 0) {
            wire.readExact(fd, buf[0..trail_len]) catch |err| {
                core.logging.logError("ses", "update_pane_shell trail read failed", err);
                self.sendBinaryError(fd, "update_pane_shell: trail read failed");
                return;
            };
        }

        var offset: usize = 0;
        const cmd: ?[]const u8 = if (ups.cmd_len > 0) blk: {
            if (offset + ups.cmd_len > trail_len) {
                self.sendBinaryError(fd, "update_pane_shell: malformed cmd trail");
                return;
            }
            const c = buf[offset .. offset + ups.cmd_len];
            offset += ups.cmd_len;
            break :blk c;
        } else null;
        const cwd: ?[]const u8 = if (ups.cwd_len > 0) blk: {
            if (offset + ups.cwd_len > trail_len) {
                self.sendBinaryError(fd, "update_pane_shell: malformed cwd trail");
                return;
            }
            const c = buf[offset .. offset + ups.cwd_len];
            offset += ups.cwd_len;
            break :blk c;
        } else null;
        if (offset != trail_len) {
            self.sendBinaryError(fd, "update_pane_shell: trailing payload length mismatch");
            return;
        }

        if (self.ses_state.store.panes.getPtr(ups.uuid)) |pane| {
            if (ups.has_status != 0) pane.last_status = ups.status;
            const new_cmd = if (cmd) |c|
                self.allocator.dupe(u8, c) catch |err| {
                    core.logging.logError("ses", "failed to store pane command", err);
                    self.sendBinaryError(fd, "update_pane_shell: command allocation failed");
                    return;
                }
            else
                null;
            const new_cwd = if (cwd) |c|
                self.allocator.dupe(u8, c) catch |err| {
                    core.logging.logError("ses", "failed to store pane cwd", err);
                    if (new_cmd) |owned| self.allocator.free(owned);
                    self.sendBinaryError(fd, "update_pane_shell: cwd allocation failed");
                    return;
                }
            else
                null;
            if (cmd) |c| {
                if (pane.last_cmd) |old| self.allocator.free(old);
                _ = c;
                pane.last_cmd = new_cmd;
            }
            if (cwd) |c| {
                if (pane.cwd) |old| self.allocator.free(old);
                _ = c;
                pane.cwd = new_cwd;
            }
            self.ses_state.markDirty();
        }
        self.replyOrClose(fd, .ok, &.{});
    }

    fn handleBinaryPopResponse(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.PopResponse)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "pop_response: payload too small");
            return;
        }
        const pr = wire.readStruct(wire.PopResponse, fd) catch |err| {
            core.logging.logError("ses", "pop_response request read failed", err);
            self.sendBinaryError(fd, "pop_response: read failed");
            return;
        };

        // Find the CLI fd waiting for this response.
        const cli_fd = self.pending_pop_requests.fetchRemove(fd);
        if (cli_fd) |kv| {
            self.replyOrClose(kv.value, .pop_response, std.mem.asBytes(&pr));
            posix.close(kv.value);
        } else {
            core.logging.warn("ses", "pop_response arrived without pending CLI fd for mux fd={d}", .{fd});
        }
    }

    fn handleBinaryCwdChanged(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.CwdChanged)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            core.logging.warnWithSource("ses", "cwd_changed payload too small: fd={d} len={d}", .{ fd, payload_len }, @src());
            return;
        }
        const cc = wire.readStruct(wire.CwdChanged, fd) catch |err| {
            core.logging.warnWithSource("ses", "cwd_changed read failed: fd={d} err={s}", .{ fd, @errorName(err) }, @src());
            return;
        };
        if (cc.cwd_len > wire.MAX_PAYLOAD_LEN or cc.cwd_len > buf.len) {
            self.skipBinaryPayload(fd, cc.cwd_len, buf);
            self.sendBinaryError(fd, "cwd_changed: path too large");
            return;
        }
        if (cc.cwd_len > 0) {
            wire.readExact(fd, buf[0..cc.cwd_len]) catch |err| {
                core.logging.warnWithSource("ses", "cwd_changed path read failed: fd={d} err={s}", .{ fd, @errorName(err) }, @src());
                return;
            };
        }

        if (self.ses_state.store.panes.getPtr(cc.uuid)) |pane| {
            ses.debugLog("cwd_changed: uuid={s} cwd={s}", .{ cc.uuid[0..8], if (cc.cwd_len > 0) buf[0..cc.cwd_len] else "(empty)" });
            const new_cwd = if (cc.cwd_len > 0)
                self.allocator.dupe(u8, buf[0..cc.cwd_len]) catch |err| {
                    core.logging.logError("ses", "failed to store cwd_changed path", err);
                    return;
                }
            else
                null;
            if (pane.cwd) |old| self.allocator.free(old);
            pane.cwd = new_cwd;
            self.ses_state.markDirty();
        }
    }

    fn handleBinaryFgChanged(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.FgChanged)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            core.logging.warnWithSource("ses", "fg_changed payload too small: fd={d} len={d}", .{ fd, payload_len }, @src());
            return;
        }
        const fc = wire.readStruct(wire.FgChanged, fd) catch |err| {
            core.logging.warnWithSource("ses", "fg_changed read failed: fd={d} err={s}", .{ fd, @errorName(err) }, @src());
            return;
        };
        if (fc.name_len > wire.MAX_PAYLOAD_LEN or fc.name_len > buf.len) {
            self.skipBinaryPayload(fd, fc.name_len, buf);
            self.sendBinaryError(fd, "fg_changed: name too large");
            return;
        }
        if (fc.name_len > 0) {
            wire.readExact(fd, buf[0..fc.name_len]) catch |err| {
                core.logging.warnWithSource("ses", "fg_changed name read failed: fd={d} err={s}", .{ fd, @errorName(err) }, @src());
                return;
            };
        }

        if (self.ses_state.store.panes.getPtr(fc.uuid)) |pane| {
            ses.debugLog("fg_changed: uuid={s} pid={d} name={s}", .{ fc.uuid[0..8], fc.pid, if (fc.name_len > 0) buf[0..fc.name_len] else "(empty)" });
            const new_fg_process = if (fc.name_len > 0)
                self.allocator.dupe(u8, buf[0..fc.name_len]) catch |err| {
                    core.logging.logError("ses", "failed to store foreground process name", err);
                    return;
                }
            else
                null;
            pane.fg_pid = fc.pid;
            if (pane.fg_process) |old| self.allocator.free(old);
            pane.fg_process = new_fg_process;
            self.ses_state.markDirty();
        }
    }

    fn handleBinaryShellEvent(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.ShpShellEvent)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            core.logging.warnWithSource("ses", "shell_event payload too small: fd={d} len={d}", .{ fd, payload_len }, @src());
            return;
        }
        const ev = wire.readStruct(wire.ShpShellEvent, fd) catch |err| {
            core.logging.warnWithSource("ses", "shell_event read failed: fd={d} err={s}", .{ fd, @errorName(err) }, @src());
            return;
        };
        const trail_len = payload_len - @sizeOf(wire.ShpShellEvent);
        if (trail_len > wire.MAX_PAYLOAD_LEN or trail_len > buf.len) {
            self.skipBinaryPayload(fd, trail_len, buf);
            return;
        }
        if (trail_len > 0) {
            wire.readExact(fd, buf[0..trail_len]) catch |err| {
                core.logging.warnWithSource("ses", "shell_event trail read failed: fd={d} err={s}", .{ fd, @errorName(err) }, @src());
                return;
            };
        }

        // Identify pane by pod_ctl_fd.
        var pane_uuid: ?[32]u8 = null;
        var pane_iter = self.ses_state.store.panes.iterator();
        while (pane_iter.next()) |entry| {
            if (entry.value_ptr.pod_ctl_fd) |ctl_fd| {
                if (ctl_fd == fd) {
                    pane_uuid = entry.key_ptr.*;
                    break;
                }
            }
        }
        const uuid = pane_uuid orelse {
            core.logging.warn("ses", "shell_event skipped: no pane registered for POD control fd {d}", .{fd});
            return;
        };
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
        if (self.ses_state.store.panes.get(uuid)) |pane| {
            if (pane.attached_to) |client_id| {
                if (self.ses_state.getClient(client_id)) |client| {
                    if (client.mux_ctl_fd) |mux_fd| {
                        const trails: []const []const u8 = &.{buf[0..trail_len]};
                        wire.writeControlMsg(mux_fd, .shell_event, std.mem.asBytes(&fwd), trails) catch |err| {
                            core.logging.warnWithSource("ses", "shell_event forward failed: fd={d} err={s}", .{ mux_fd, @errorName(err) }, @src());
                            self.queueCtlClose(mux_fd, null);
                        };
                    }
                }
            }
        }
    }

    fn handleBinaryExited(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.Exited)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            core.logging.warnWithSource("ses", "exited payload too small: fd={d} len={d}", .{ fd, payload_len }, @src());
            return;
        }
        const ex = wire.readStruct(wire.Exited, fd) catch |err| {
            core.logging.warnWithSource("ses", "exited read failed: fd={d} err={s}", .{ fd, @errorName(err) }, @src());
            return;
        };

        if (self.ses_state.store.panes.getPtr(ex.uuid)) |pane| {
            pane.last_status = ex.status;
            // Notify owning mux immediately so it can tear down dead pane UI.
            if (pane.attached_to) |client_id| {
                if (self.ses_state.getClient(client_id)) |client| {
                    if (client.mux_ctl_fd) |ctl_fd| {
                        var msg = wire.PaneUuid{ .uuid = ex.uuid };
                        self.replyOrClose(ctl_fd, .pane_exited, std.mem.asBytes(&msg));
                    }
                }
            }
        }

        // Fully remove dead pane from SES routing/state so sticky/adopt lookup
        // cannot return a process that already exited.
        self.ses_state.killPane(ex.uuid) catch |e| {
            core.logging.logError("ses", "killPane failed after pane exit", e);
        };
        self.ses_state.markDirty();
    }

    /// Handle a CLI tool request (handshake byte 0x04).
    /// CLI sends one control message; SES forwards to MUX and optionally waits for response.
    fn handleCliRequest(self: *Server, fd: posix.fd_t) void {
        const hdr = wire.readControlHeader(fd) catch |err| {
            core.logging.logError("ses", "cli request header read failed", err);
            self.closeCliRequest(fd, "header read failed");
            return;
        };
        const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        ses.debugLog("cli req: type=0x{x:0>4} len={d} fd={d}", .{ hdr.msg_type, hdr.payload_len, fd });
        var buf: [65536]u8 = undefined;

        switch (msg_type) {
            .focus_move => {
                if (hdr.payload_len < @sizeOf(wire.FocusMove)) {
                    self.closeCliRequest(fd, "focus_move payload too small");
                    return;
                }
                const fm = wire.readStruct(wire.FocusMove, fd) catch |err| {
                    core.logging.logError("ses", "focus_move read failed", err);
                    self.closeCliRequest(fd, "focus_move read failed");
                    return;
                };
                // Find MUX ctl fd for this pane's session.
                const mux_fd = self.findMuxCtlForUuid(fm.uuid) orelse {
                    self.closeCliRequest(fd, "focus_move target mux not found");
                    return;
                };
                // Forward to MUX.
                self.replyOrClose(mux_fd, .focus_move, std.mem.asBytes(&fm));
                posix.close(fd);
            },
            .exit_intent => {
                if (hdr.payload_len < @sizeOf(wire.ExitIntent)) {
                    self.closeCliRequest(fd, "exit_intent payload too small");
                    return;
                }
                const ei = wire.readStruct(wire.ExitIntent, fd) catch |err| {
                    core.logging.logError("ses", "exit_intent read failed", err);
                    self.closeCliRequest(fd, "exit_intent read failed");
                    return;
                };
                // Find MUX ctl fd.
                const mux_fd = self.findMuxCtlForUuid(ei.uuid) orelse {
                    // No MUX — allow exit.
                    const allow = wire.ExitIntentResult{ .allow = 1 };
                    self.replyOrClose(fd, .exit_intent_result, std.mem.asBytes(&allow));
                    posix.close(fd);
                    return;
                };
                // Close any previous pending exit_intent CLI fd.
                if (self.pending_exit_intent_cli_fd) |old_fd| posix.close(old_fd);
                self.pending_exit_intent_cli_fd = fd;
                // Forward to MUX.
                wire.writeControl(mux_fd, .exit_intent, std.mem.asBytes(&ei)) catch |err| {
                    core.logging.logError("ses", "failed to forward exit_intent to mux", err);
                    // If forward fails, allow exit.
                    const allow = wire.ExitIntentResult{ .allow = 1 };
                    self.replyOrClose(fd, .exit_intent_result, std.mem.asBytes(&allow));
                    posix.close(fd);
                    self.pending_exit_intent_cli_fd = null;
                };
            },
            .float_request => {
                if (hdr.payload_len < @sizeOf(wire.FloatRequest)) {
                    self.closeCliRequest(fd, "float_request payload too small");
                    return;
                }
                const payload_len = hdr.payload_len;
                const fr = wire.readStruct(wire.FloatRequest, fd) catch |err| {
                    core.logging.logError("ses", "float_request read failed", err);
                    self.closeCliRequest(fd, "float_request read failed");
                    return;
                };
                // Read trailing data.
                const trail_len = payload_len - @sizeOf(wire.FloatRequest);
                if (trail_len > buf.len) {
                    self.closeCliRequest(fd, "float_request trail too large");
                    return;
                }
                if (trail_len > 0) {
                    wire.readExact(fd, buf[0..trail_len]) catch |err| {
                        core.logging.logError("ses", "float_request trail read failed", err);
                        self.closeCliRequest(fd, "float_request trail read failed");
                        return;
                    };
                }
                // Find the MUX for the source session (or fallback to any MUX).
                const mux_fd = self.findMuxCtlForSessionId(fr.source_session_id) orelse {
                    core.logging.warn("ses", "float_request target mux not found for session={s}", .{fr.source_session_id[0..8]});
                    self.sendBinaryError(fd, "no_mux");
                    posix.close(fd);
                    return;
                };
                // Forward entire float_request to MUX.
                wire.writeControlWithTrail(mux_fd, .float_request, std.mem.asBytes(&fr), buf[0..trail_len]) catch |err| {
                    core.logging.logError("ses", "float_request forward to mux failed", err);
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
                self.pending_float_cli_fds.put(zero_uuid, fd) catch |err| {
                    core.logging.logError("ses", "failed to track pending float CLI request", err);
                    self.sendBinaryError(fd, "track_failed");
                    posix.close(fd);
                };
            },
            .notify => {
                // Forward notify to MUX.
                if (hdr.payload_len > buf.len) {
                    self.closeCliRequest(fd, "notify payload too large");
                    return;
                }
                if (hdr.payload_len > 0) {
                    wire.readExact(fd, buf[0..hdr.payload_len]) catch |err| {
                        core.logging.logError("ses", "notify payload read failed", err);
                        self.closeCliRequest(fd, "notify payload read failed");
                        return;
                    };
                }
                const mux_fd = self.findAnyMuxCtl() orelse {
                    self.closeCliRequest(fd, "notify target mux not found");
                    return;
                };
                self.replyOrClose(mux_fd, .notify, buf[0..hdr.payload_len]);
                posix.close(fd);
            },
            .send_keys => {
                if (hdr.payload_len < @sizeOf(wire.SendKeys)) {
                    self.closeCliRequest(fd, "send_keys payload too small");
                    return;
                }
                if (hdr.payload_len > buf.len) {
                    self.closeCliRequest(fd, "send_keys payload too large");
                    return;
                }
                wire.readExact(fd, buf[0..hdr.payload_len]) catch |err| {
                    core.logging.logError("ses", "send_keys payload read failed", err);
                    self.closeCliRequest(fd, "send_keys payload read failed");
                    return;
                };
                const sk = wire.bytesToStruct(wire.SendKeys, buf[0..hdr.payload_len]) orelse {
                    self.closeCliRequest(fd, "send_keys payload malformed");
                    return;
                };
                const zero_uuid: [32]u8 = .{0} ** 32;
                const mux_fd = if (std.mem.eql(u8, &sk.uuid, &zero_uuid))
                    self.findAnyMuxCtl()
                else
                    self.findMuxCtlForUuid(sk.uuid) orelse self.findAnyMuxCtl();
                if (mux_fd) |mfd| {
                    self.replyOrClose(mfd, .send_keys, buf[0..hdr.payload_len]);
                }
                posix.close(fd);
            },
            .targeted_notify => {
                if (hdr.payload_len < @sizeOf(wire.TargetedNotify)) {
                    self.closeCliRequest(fd, "targeted_notify payload too small");
                    return;
                }
                if (hdr.payload_len > buf.len) {
                    self.closeCliRequest(fd, "targeted_notify payload too large");
                    return;
                }
                wire.readExact(fd, buf[0..hdr.payload_len]) catch |err| {
                    core.logging.logError("ses", "targeted_notify payload read failed", err);
                    self.closeCliRequest(fd, "targeted_notify payload read failed");
                    return;
                };
                const tn = wire.bytesToStruct(wire.TargetedNotify, buf[0..hdr.payload_len]) orelse {
                    self.closeCliRequest(fd, "targeted_notify payload malformed");
                    return;
                };
                const mux_fd = self.findMuxCtlForUuid(tn.uuid) orelse self.findAnyMuxCtl();
                if (mux_fd) |mfd| {
                    self.replyOrClose(mfd, .targeted_notify, buf[0..hdr.payload_len]);
                }
                posix.close(fd);
            },
            .broadcast_notify => {
                if (hdr.payload_len > buf.len) {
                    self.closeCliRequest(fd, "broadcast_notify payload too large");
                    return;
                }
                if (hdr.payload_len > 0) {
                    wire.readExact(fd, buf[0..hdr.payload_len]) catch |err| {
                        core.logging.logError("ses", "broadcast_notify payload read failed", err);
                        self.closeCliRequest(fd, "broadcast_notify payload read failed");
                        return;
                    };
                }
                // Forward to all connected MUX clients.
                for (self.ses_state.store.clients.items) |*client| {
                    if (client.mux_ctl_fd) |mfd| {
                        self.replyOrClose(mfd, .notify, buf[0..hdr.payload_len]);
                    }
                }
                posix.close(fd);
            },
            .pop_confirm => {
                if (hdr.payload_len < @sizeOf(wire.PopConfirm)) {
                    self.closeCliRequest(fd, "pop_confirm payload too small");
                    return;
                }
                if (hdr.payload_len > buf.len) {
                    self.closeCliRequest(fd, "pop_confirm payload too large");
                    return;
                }
                wire.readExact(fd, buf[0..hdr.payload_len]) catch |err| {
                    core.logging.logError("ses", "pop_confirm payload read failed", err);
                    self.closeCliRequest(fd, "pop_confirm payload read failed");
                    return;
                };
                const pc = wire.bytesToStruct(wire.PopConfirm, buf[0..hdr.payload_len]) orelse {
                    self.closeCliRequest(fd, "pop_confirm payload malformed");
                    return;
                };
                const zero_uuid: [32]u8 = .{0} ** 32;
                const mux_fd = if (std.mem.eql(u8, &pc.uuid, &zero_uuid))
                    self.findAnyMuxCtl()
                else
                    self.findMuxCtlForUuid(pc.uuid) orelse self.findAnyMuxCtl();
                if (mux_fd) |mfd| {
                    self.replyOrClose(mfd, .pop_confirm, buf[0..hdr.payload_len]);
                    self.pending_pop_requests.put(mfd, fd) catch |err| {
                        core.logging.logError("ses", "failed to track pending pop_confirm CLI request", err);
                        self.sendBinaryError(fd, "track_failed");
                        posix.close(fd);
                    };
                } else {
                    self.closeCliRequest(fd, "pop_confirm target mux not found");
                }
            },
            .pop_choose => {
                if (hdr.payload_len < @sizeOf(wire.PopChoose)) {
                    self.closeCliRequest(fd, "pop_choose payload too small");
                    return;
                }
                if (hdr.payload_len > buf.len) {
                    self.closeCliRequest(fd, "pop_choose payload too large");
                    return;
                }
                wire.readExact(fd, buf[0..hdr.payload_len]) catch |err| {
                    core.logging.logError("ses", "pop_choose payload read failed", err);
                    self.closeCliRequest(fd, "pop_choose payload read failed");
                    return;
                };
                const pch = wire.bytesToStruct(wire.PopChoose, buf[0..hdr.payload_len]) orelse {
                    self.closeCliRequest(fd, "pop_choose payload malformed");
                    return;
                };
                const zero_uuid: [32]u8 = .{0} ** 32;
                const mux_fd = if (std.mem.eql(u8, &pch.uuid, &zero_uuid))
                    self.findAnyMuxCtl()
                else
                    self.findMuxCtlForUuid(pch.uuid) orelse self.findAnyMuxCtl();
                if (mux_fd) |mfd| {
                    self.replyOrClose(mfd, .pop_choose, buf[0..hdr.payload_len]);
                    self.pending_pop_requests.put(mfd, fd) catch |err| {
                        core.logging.logError("ses", "failed to track pending pop_choose CLI request", err);
                        self.sendBinaryError(fd, "track_failed");
                        posix.close(fd);
                    };
                } else {
                    self.closeCliRequest(fd, "pop_choose target mux not found");
                }
            },
            .pane_info => {
                if (hdr.payload_len < @sizeOf(wire.PaneUuid)) {
                    self.closeCliRequest(fd, "pane_info payload too small");
                    return;
                }
                const pu = wire.readStruct(wire.PaneUuid, fd) catch |err| {
                    core.logging.logError("ses", "pane_info payload read failed", err);
                    self.closeCliRequest(fd, "pane_info payload read failed");
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
                    wire.readExact(fd, &flag) catch |err| {
                        core.logging.logError("ses", "status flag read failed", err);
                        self.closeCliRequest(fd, "status flag read failed");
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
                self.closeCliRequest(fd, "unsupported cli request type");
            },
        }
    }

    fn closeCliRequest(self: *Server, fd: posix.fd_t, comptime context: []const u8) void {
        _ = self;
        core.logging.warn("ses", "closing CLI request fd={d}: {s}", .{ fd, context });
        posix.close(fd);
    }

    /// Handle exit_intent_result from MUX — forward to waiting CLI.
    fn handleBinaryExitIntentResult(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.ExitIntentResult)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "exit_intent_result: payload too small");
            return;
        }
        const result = wire.readStruct(wire.ExitIntentResult, fd) catch |err| {
            core.logging.logError("ses", "exit_intent_result request read failed", err);
            self.sendBinaryError(fd, "exit_intent_result: read failed");
            return;
        };
        if (self.pending_exit_intent_cli_fd) |cli_fd| {
            self.replyOrClose(cli_fd, .exit_intent_result, std.mem.asBytes(&result));
            posix.close(cli_fd);
            self.pending_exit_intent_cli_fd = null;
        } else {
            core.logging.warn("ses", "exit_intent_result arrived without pending CLI fd from mux fd={d}", .{fd});
        }
    }

    /// Handle float_result from MUX — forward to waiting CLI.
    fn handleBinaryFloatResult(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.FloatResult)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "float_result: payload too small");
            return;
        }
        const result = wire.readStruct(wire.FloatResult, fd) catch |err| {
            core.logging.logError("ses", "float_result request read failed", err);
            self.sendBinaryError(fd, "float_result: read failed");
            return;
        };
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
                wire.readExact(fd, buf[0..trail_len]) catch |err| {
                    core.logging.warnWithSource("ses", "float_result trail read failed: fd={d} err={s}", .{ fd, @errorName(err) }, @src());
                    posix.close(cfd);
                    return;
                };
                self.replyOrCloseWithTrail(cfd, .float_result, std.mem.asBytes(&result), buf[0..trail_len]);
            } else if (trail_len > buf.len) {
                core.logging.warn("ses", "float_result trail too large: fd={d} len={d}", .{ fd, trail_len });
                self.skipBinaryPayload(fd, @intCast(trail_len), buf);
                self.sendBinaryError(cfd, "float_result: trail too large");
            } else {
                self.replyOrClose(cfd, .float_result, std.mem.asBytes(&result));
            }
            posix.close(cfd);
        } else {
            // No CLI waiting — skip trailing data.
            core.logging.warn("ses", "float_result arrived without pending CLI fd for uuid={s}", .{result.uuid[0..8]});
            if (trail_len > 0) self.skipBinaryPayload(fd, @intCast(trail_len), buf);
        }
    }

    /// Handle binary pane_info query — respond with PaneInfoResp.
    /// Does NOT close the fd — caller is responsible for closing if needed.
    fn handleBinaryPaneInfo(self: *Server, fd: posix.fd_t, uuid: [32]u8) void {
        ses.debugLog("pane_info: uuid={s} fd={d}", .{ uuid[0..8], fd });
        const pane = self.ses_state.store.panes.get(uuid) orelse {
            ses.debugLog("pane_info: not found", .{});
            self.replyOrClose(fd, .pane_not_found, &.{});
            return;
        };

        var resp: wire.PaneInfoResp = .{
            .uuid = uuid,
            .pid = pane.child_pid,
            .fg_pid = pane.fg_pid orelse pane.child_pid,
            .base_pid = pane.child_pid,
            .pane_id = pane.pane_id,
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

        self.replyOrCloseWithTrail(fd, .pane_info, std.mem.asBytes(&resp), trail_buf[0..trail_len]);
    }

    /// Handle binary status query from CLI — respond with StatusResp + entries.
    fn handleBinaryStatus(self: *Server, fd: posix.fd_t, full_mode: bool) void {
        ses.debugLog("status: full={} fd={d} clients={d} panes={d}", .{ full_mode, fd, self.ses_state.store.clients.items.len, self.ses_state.store.panes.count() });
        // Count entries
        var orphaned_count: u16 = 0;
        var sticky_count: u16 = 0;
        var pane_iter = self.ses_state.store.panes.iterator();
        while (pane_iter.next()) |_entry| {
            const p = _entry.value_ptr;
            if (p.state == .orphaned) orphaned_count += 1;
            if (p.state == .sticky) sticky_count += 1;
        }

        const hdr = wire.StatusResp{
            .client_count = @intCast(self.ses_state.store.clients.items.len),
            .detached_count = @intCast(self.ses_state.store.detached_sessions.count()),
            .orphaned_count = orphaned_count,
            .sticky_count = sticky_count,
            .full_mode = @intFromBool(full_mode),
        };

        const alloc = self.ses_state.allocator;

        // Build the entire response in a dynamic buffer
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);

        // Header
        if (!self.appendStatusBytesOrClose(fd, &buf, std.mem.asBytes(&hdr), "status header")) return;

        // Connected clients
        for (self.ses_state.store.clients.items) |client| {
            var sc: wire.StatusClient = .{
                .id = @intCast(client.id),
                .session_id = .{0} ** 32,
                .has_session_id = 0,
                .name_len = 0,
                .pane_count = @intCast(client.pane_uuids.items.len),
                .session_state_len = 0,
            };

            if (client.session_id) |sid| {
                const hex_id: [32]u8 = std.fmt.bytesToHex(sid, .lower);
                sc.session_id = hex_id;
                sc.has_session_id = 1;
            }

            const name = client.session_name orelse "";
            sc.name_len = @intCast(name.len);
            const session_json = if (full_mode and client.session_snapshot != null)
                client.session_snapshot.?.toJson(alloc) catch |err| {
                    core.logging.logError("ses", "failed to serialize attached session status snapshot", err);
                    posix.close(fd);
                    return;
                }
            else
                null;
            defer if (session_json) |json| alloc.free(json);
            if (session_json) |json| sc.session_state_len = @intCast(json.len);

            if (!self.appendStatusBytesOrClose(fd, &buf, std.mem.asBytes(&sc), "status client entry")) return;
            if (name.len > 0 and !self.appendStatusBytesOrClose(fd, &buf, name, "status client name")) return;
            if (session_json) |json| {
                if (!self.appendStatusBytesOrClose(fd, &buf, json, "status attached session json")) return;
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
                if (self.ses_state.store.panes.get(uuid)) |pane| {
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
                if (!self.appendStatusBytesOrClose(fd, &buf, std.mem.asBytes(&pe), "status client pane entry")) return;
                if (pname.len > 0 and !self.appendStatusBytesOrClose(fd, &buf, pname, "status client pane name")) return;
                if (spwd.len > 0 and !self.appendStatusBytesOrClose(fd, &buf, spwd, "status client pane sticky pwd")) return;
            }
        }

        // Detached sessions
        var sess_iter = self.ses_state.store.detached_sessions.iterator();
        while (sess_iter.next()) |entry| {
            const detached = entry.value_ptr;
            const hex_id: [32]u8 = std.fmt.bytesToHex(detached.session_id, .lower);
            var de: wire.DetachedSessionEntry = .{
                .session_id = hex_id,
                .name_len = @intCast(detached.session_snapshot.session_name.len),
                .pane_count = @intCast(detached.pane_uuids.len),
                .session_state_len = 0,
            };
            const session_json = if (full_mode)
                detached.session_snapshot.toJson(alloc) catch |err| {
                    core.logging.logError("ses", "failed to serialize detached session status snapshot", err);
                    posix.close(fd);
                    return;
                }
            else
                null;
            defer if (session_json) |json| alloc.free(json);
            if (session_json) |json| de.session_state_len = @intCast(json.len);
            if (!self.appendStatusBytesOrClose(fd, &buf, std.mem.asBytes(&de), "status detached session entry")) return;
            if (!self.appendStatusBytesOrClose(fd, &buf, detached.session_snapshot.session_name, "status detached session name")) return;
            if (session_json) |json| {
                if (!self.appendStatusBytesOrClose(fd, &buf, json, "status detached session json")) return;
            }
        }

        // Orphaned panes
        pane_iter = self.ses_state.store.panes.iterator();
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
            if (!self.appendStatusBytesOrClose(fd, &buf, std.mem.asBytes(&pe), "status orphan pane entry")) return;
            if (pane.name) |n| {
                if (!self.appendStatusBytesOrClose(fd, &buf, n, "status orphan pane name")) return;
            }
        }

        // Sticky panes
        pane_iter = self.ses_state.store.panes.iterator();
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
            if (!self.appendStatusBytesOrClose(fd, &buf, std.mem.asBytes(&se), "status sticky pane entry")) return;
            if (pane.name) |n| {
                if (!self.appendStatusBytesOrClose(fd, &buf, n, "status sticky pane name")) return;
            }
            if (pane.sticky_pwd) |pwd| {
                if (!self.appendStatusBytesOrClose(fd, &buf, pwd, "status sticky pane pwd")) return;
            }
        }

        // Send all at once
        self.replyOrClose(fd, .status, buf.items);
        posix.close(fd);
    }

    fn appendStatusBytesOrClose(self: *Server, fd: posix.fd_t, buf: *std.ArrayListUnmanaged(u8), bytes: []const u8, comptime context: []const u8) bool {
        buf.appendSlice(self.ses_state.allocator, bytes) catch |err| {
            core.logging.logError("ses", "failed to build " ++ context, err);
            posix.close(fd);
            return false;
        };
        return true;
    }

    /// Find the MUX CTL fd for a given pane UUID.
    fn findMuxCtlForUuid(self: *Server, uuid: [32]u8) ?posix.fd_t {
        if (self.ses_state.store.panes.get(uuid)) |pane| {
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

        for (self.ses_state.store.clients.items) |client| {
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
        for (self.ses_state.store.clients.items) |client| {
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
            self.replyOrCloseWithTrail(fd, .kill_session, std.mem.asBytes(&result), "invalid payload");
            return;
        }

        const ks = wire.readStruct(wire.KillSession, fd) catch |err| {
            core.logging.logError("ses", "kill_session request read failed", err);
            const result = wire.KillSessionResult{ .success = 0, .killed_panes = 0, .error_len = 11 };
            self.replyOrCloseWithTrail(fd, .kill_session, std.mem.asBytes(&result), "read failed");
            return;
        };

        if (ks.id_len == 0 or ks.id_len > buf.len) {
            const result = wire.KillSessionResult{ .success = 0, .killed_panes = 0, .error_len = 10 };
            self.replyOrCloseWithTrail(fd, .kill_session, std.mem.asBytes(&result), "invalid id");
            return;
        }

        wire.readExact(fd, buf[0..ks.id_len]) catch |err| {
            core.logging.logError("ses", "kill_session id read failed", err);
            const result = wire.KillSessionResult{ .success = 0, .killed_panes = 0, .error_len = 11 };
            self.replyOrCloseWithTrail(fd, .kill_session, std.mem.asBytes(&result), "read failed");
            return;
        };
        const session_id_str = buf[0..ks.id_len];

        ses.debugLog("kill_session: id={s}", .{session_id_str});

        // Find session by name or UUID prefix.
        const session_id = self.ses_state.findDetachedSessionByNameOrPrefix(session_id_str) orelse {
            const result = wire.KillSessionResult{ .success = 0, .killed_panes = 0, .error_len = 17 };
            self.replyOrCloseWithTrail(fd, .kill_session, std.mem.asBytes(&result), "session not found");
            return;
        };

        // Kill the session.
        const killed_panes = self.ses_state.killDetachedSession(session_id) orelse {
            const result = wire.KillSessionResult{ .success = 0, .killed_panes = 0, .error_len = 11 };
            self.replyOrCloseWithTrail(fd, .kill_session, std.mem.asBytes(&result), "kill failed");
            return;
        };

        ses.debugLog("kill_session: killed {d} panes", .{killed_panes});
        const result = wire.KillSessionResult{ .success = 1, .killed_panes = @intCast(killed_panes), .error_len = 0 };
        self.replyOrClose(fd, .kill_session, std.mem.asBytes(&result));
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
        self.replyOrClose(fd, .clear_sessions, std.mem.asBytes(&result));
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
        self.replyOrClose(fd, .clear_orphaned_panes, std.mem.asBytes(&result));
    }

    const LayoutExportTabCtx = struct {
        allocator: std.mem.Allocator,
        ids: std.AutoHashMap([32]u8, u16),
        ordered: std.ArrayList([32]u8),
        next_id: u16 = 0,

        fn init(allocator: std.mem.Allocator) LayoutExportTabCtx {
            return .{
                .allocator = allocator,
                .ids = std.AutoHashMap([32]u8, u16).init(allocator),
                .ordered = .empty,
            };
        }

        fn deinit(self: *LayoutExportTabCtx) void {
            self.ids.deinit();
            self.ordered.deinit(self.allocator);
        }

        fn assign(self: *LayoutExportTabCtx, uuid: [32]u8) !void {
            if (self.ids.contains(uuid)) return;
            try self.ids.put(uuid, self.next_id);
            try self.ordered.append(self.allocator, uuid);
            self.next_id +%= 1;
        }
    };

    fn collectLayoutPaneIds(ctx: *LayoutExportTabCtx, node: ?*const core.session_model.SessionLayoutNode) !void {
        const root = node orelse return;
        switch (root.*) {
            .pane => |uuid| try ctx.assign(uuid),
            .split => |split| {
                try collectLayoutPaneIds(ctx, split.first);
                try collectLayoutPaneIds(ctx, split.second);
            },
        }
    }

    fn writeLayoutExportNode(
        writer: anytype,
        node: ?*const core.session_model.SessionLayoutNode,
        ids: *const std.AutoHashMap([32]u8, u16),
    ) !void {
        const root = node orelse {
            try writer.writeAll("null");
            return;
        };

        switch (root.*) {
            .pane => |uuid| {
                const pane_id = ids.get(uuid) orelse 0;
                try writer.print("{{\"type\":\"pane\",\"id\":{d}}}", .{pane_id});
            },
            .split => |split| {
                try writer.writeAll("{\"type\":\"split\",\"dir\":");
                try writer.print("{f}", .{std.json.fmt(@tagName(split.dir), .{})});
                try writer.print(",\"ratio\":{d},\"first\":", .{split.ratio});
                try writeLayoutExportNode(writer, split.first, ids);
                try writer.writeAll(",\"second\":");
                try writeLayoutExportNode(writer, split.second, ids);
                try writer.writeAll("}");
            },
        }
    }

    fn buildLayoutExportJson(self: *Server, snapshot: *const state.SessionSnapshot) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);
        var writer = buf.writer(self.allocator);
        const active_float_index = blk: {
            if (snapshot.active_float_uuid) |active_uuid| {
                for (snapshot.floats.items, 0..) |float_state, idx| {
                    if (std.mem.eql(u8, &float_state.pane_uuid, &active_uuid)) {
                        break :blk idx;
                    }
                }
            }
            break :blk null;
        };

        try writer.writeAll("{\"active_tab\":");
        try writer.print("{d}", .{snapshot.active_tab});
        try writer.writeAll(",\"active_floating\":");
        if (active_float_index) |idx| {
            try writer.print("{d}", .{idx});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"tabs\":[");

        for (snapshot.tabs.items, 0..) |tab, ti| {
            if (ti > 0) try writer.writeAll(",");

            var ctx = LayoutExportTabCtx.init(self.allocator);
            defer ctx.deinit();
            try collectLayoutPaneIds(&ctx, tab.root);

            try writer.writeAll("{\"name\":");
            try writer.print("{f}", .{std.json.fmt(tab.name, .{})});
            try writer.writeAll(",\"tree\":");
            try writeLayoutExportNode(writer, tab.root, &ctx.ids);
            try writer.writeAll(",\"splits\":[");
            for (ctx.ordered.items, 0..) |uuid, pi| {
                if (pi > 0) try writer.writeAll(",");
                const pane_id = ctx.ids.get(uuid) orelse 0;
                try writer.print("{{\"id\":{d},\"uuid\":", .{pane_id});
                try writer.print("{f}", .{std.json.fmt(uuid[0..], .{})});
                if (self.ses_state.getPane(uuid)) |pane| {
                    if (pane.cwd) |cwd| {
                        try writer.writeAll(",\"pwd_dir\":");
                        try writer.print("{f}", .{std.json.fmt(cwd, .{})});
                    }
                }
                try writer.writeAll("}");
            }
            try writer.writeAll("]}");
        }

        try writer.writeAll("],\"floats\":[");
        for (snapshot.floats.items, 0..) |float_state, fi| {
            if (fi > 0) try writer.writeAll(",");
            try writer.writeAll("{\"uuid\":");
            try writer.print("{f}", .{std.json.fmt(float_state.pane_uuid[0..], .{})});
            try writer.print(",\"visible\":{}", .{float_state.visible});
            try writer.print(",\"tab_visible\":{d}", .{float_state.tab_visible});
            try writer.print(",\"float_key\":{d}", .{float_state.float_key});
            try writer.print(",\"float_width_pct\":{d}", .{float_state.width_pct});
            try writer.print(",\"float_height_pct\":{d}", .{float_state.height_pct});
            try writer.print(",\"float_pos_x_pct\":{d}", .{float_state.pos_x_pct});
            try writer.print(",\"float_pos_y_pct\":{d}", .{float_state.pos_y_pct});
            try writer.print(",\"float_pad_x\":{d}", .{float_state.pad_x});
            try writer.print(",\"float_pad_y\":{d}", .{float_state.pad_y});
            try writer.print(",\"is_pwd\":{}", .{float_state.is_pwd});
            try writer.print(",\"sticky\":{}", .{float_state.sticky});
            if (float_state.parent_tab) |parent_tab| {
                try writer.print(",\"parent_tab\":{d}", .{parent_tab});
            }
            if (self.ses_state.getPane(float_state.pane_uuid)) |pane| {
                if (pane.cwd) |cwd| {
                    try writer.writeAll(",\"pwd_dir\":");
                    try writer.print("{f}", .{std.json.fmt(cwd, .{})});
                }
            }
            try writer.writeAll("}");
        }
        try writer.writeAll("]}");
        return buf.toOwnedSlice(self.allocator);
    }

    /// Handle get_layout CLI request — derive layout export JSON from the
    /// canonical session snapshot owned by SES.
    fn handleGetLayout(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        defer posix.close(fd);

        if (payload_len < @sizeOf(wire.PaneUuid)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "invalid payload");
            return;
        }
        const pu = wire.readStruct(wire.PaneUuid, fd) catch |err| {
            core.logging.logError("ses", "get_layout pane uuid read failed", err);
            self.sendBinaryError(fd, "read failed");
            return;
        };

        // Find the client that owns this pane UUID.
        const client = self.findClientForPaneUuid(pu.uuid) orelse {
            self.sendBinaryError(fd, "pane not found");
            return;
        };

        const snapshot = client.session_snapshot orelse {
            self.sendBinaryError(fd, "no session snapshot");
            return;
        };
        const layout_json = self.buildLayoutExportJson(&snapshot) catch |err| {
            core.logging.logError("ses", "failed to build layout export json", err);
            self.sendBinaryError(fd, "layout_export_failed");
            return;
        };
        defer self.allocator.free(layout_json);

        self.replyOrClose(fd, .get_layout, layout_json);
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
        wire.readExact(fd, &hex_uuid) catch |err| {
            core.logging.logError("ses", "get_session_state uuid read failed", err);
            self.sendBinaryError(fd, "read failed");
            return;
        };

        // Convert hex UUID to binary
        const session_id = core.uuid.hexToBin(hex_uuid) orelse {
            self.sendBinaryError(fd, "invalid hex UUID");
            return;
        };

        // Look up detached session
        const detached_state = self.ses_state.store.detached_sessions.get(session_id) orelse {
            self.sendBinaryError(fd, "session not found");
            return;
        };

        const session_json = detached_state.session_snapshot.toJson(self.allocator) catch |err| {
            core.logging.logError("ses", "failed to serialize detached session state", err);
            self.sendBinaryError(fd, "session_snapshot_failed");
            return;
        };
        defer self.allocator.free(session_json);

        self.replyOrClose(fd, .session_state, session_json);
    }

    fn pushClientSessionSnapshot(self: *Server, client_id: usize) void {
        const client = self.ses_state.getClient(client_id) orelse {
            core.logging.warn("ses", "cannot push session snapshot: missing client id={d}", .{client_id});
            return;
        };
        const mux_fd = client.mux_ctl_fd orelse {
            core.logging.warn("ses", "cannot push session snapshot: client id={d} has no mux ctl fd", .{client_id});
            return;
        };
        const snapshot = client.session_snapshot orelse {
            core.logging.warn("ses", "cannot push session snapshot: client id={d} has no snapshot", .{client_id});
            return;
        };
        const session_json = snapshot.toJson(self.allocator) catch |err| {
            core.logging.logError("ses", "failed to serialize client session snapshot push", err);
            return;
        };
        defer self.allocator.free(session_json);
        self.replyOrClose(mux_fd, .session_state, session_json);
    }

    /// Handle apply_layout CLI request — mutate canonical SES state, then push
    /// the updated snapshot to the attached frontend.
    fn handleApplyLayout(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        defer posix.close(fd);

        if (payload_len < @sizeOf(wire.ApplyLayout)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "invalid payload");
            return;
        }

        const al = wire.readStruct(wire.ApplyLayout, fd) catch |err| {
            core.logging.logError("ses", "apply_layout request read failed", err);
            self.sendBinaryError(fd, "read failed");
            return;
        };

        // Read tree JSON.
        if (al.tree_json_len == 0 or al.tree_json_len > wire.MAX_PAYLOAD_LEN) {
            self.sendBinaryError(fd, "invalid json len");
            return;
        }

        const json_buf = self.allocator.alloc(u8, al.tree_json_len) catch |err| {
            core.logging.logError("ses", "apply_layout json allocation failed", err);
            self.sendBinaryError(fd, "alloc failed");
            return;
        };
        defer self.allocator.free(json_buf);

        wire.readExact(fd, json_buf) catch |err| {
            core.logging.logError("ses", "apply_layout json read failed", err);
            self.sendBinaryError(fd, "read json failed");
            return;
        };

        const pane = self.ses_state.getPane(al.uuid) orelse {
            self.sendBinaryError(fd, "pane not found");
            return;
        };
        const client_id = pane.attached_to orelse {
            self.sendBinaryError(fd, "pane not attached");
            return;
        };

        self.ses_state.applyClientSessionLayoutTemplate(client_id, al.uuid, json_buf) catch |err| {
            core.logging.logError("ses", "apply_layout template application failed", err);
            self.sendBinaryError(fd, "apply layout failed");
            return;
        };
        self.pushClientSessionSnapshot(client_id);
        self.replyOrClose(fd, .ok, &.{});
    }

    /// Find the client (MUX) that owns a given pane UUID.
    fn findClientForPaneUuid(self: *Server, uuid: [32]u8) ?*state.Client {
        for (self.ses_state.store.clients.items) |*client| {
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
