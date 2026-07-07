const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ipc = core.ipc;
const wire = core.wire;
const state = @import("state.zig");
const sticky_panes = @import("sticky_panes.zig");
const server_session_handlers = @import("server_session_handlers.zig");
const server_pod_event_handlers = @import("server_pod_event_handlers.zig");
const server_pane_meta_handlers = @import("server_pane_meta_handlers.zig");
const server_pane_lifecycle_handlers = @import("server_pane_lifecycle_handlers.zig");
const server_reattach_handlers = @import("server_reattach_handlers.zig");
const server_cli_layout_handlers = @import("server_cli_layout_handlers.zig");
const server_reporting_handlers = @import("server_reporting_handlers.zig");
const server_listing_handlers = @import("server_listing_handlers.zig");
const server_register_handler = @import("server_register_handler.zig");
const ses = @import("main.zig");
const xev = @import("xev").Dynamic;

// Keep VT routing I/O short to avoid blocking the whole SES event loop when a
// peer dies mid-frame on stream sockets.
const VT_ROUTE_IO_TIMEOUT_MS: i32 = 2000;
const CTL_FRAME_IO_TIMEOUT_MS: i32 = 2000;
const MUX_VT_QUEUE_MAX_BYTES: usize = 4 * 1024 * 1024;
// Symmetric cap for the MUX→POD (input) direction. A frame is always accepted
// onto an empty queue (so a single large paste is never undeliverable);
// overflow only trips once backlog already exists, at which point the wedged
// POD connection is dropped rather than blocking the loop.
const POD_VT_QUEUE_MAX_BYTES: usize = 4 * 1024 * 1024;
const VT_FRAME_TYPE_BACKLOG_END: u8 = @intFromEnum(core.pod_protocol.FrameType.backlog_end);
const VT_FRAME_TYPE_PASSWORD_MODE: u8 = @intFromEnum(core.pod_protocol.FrameType.password_mode);

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
        .mux_vt_queues = std.AutoHashMap(posix.fd_t, MuxVtQueue).init(allocator),
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
    var mux_queue_it = server.mux_vt_queues.iterator();
    while (mux_queue_it.next()) |entry| entry.value_ptr.deinit(server.allocator);
    server.mux_vt_queues.deinit();
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

test "Server replies echo request id only to current request fd" {
    const allocator = std.testing.allocator;
    const request_pair = try testSocketPair();
    defer posix.close(request_pair.a);
    defer posix.close(request_pair.b);
    const other_pair = try testSocketPair();
    defer posix.close(other_pair.a);
    defer posix.close(other_pair.b);

    var server = testServer(allocator);
    defer deinitTestServer(&server);
    server.current_ctl_request_fd = request_pair.a;
    server.current_ctl_request_id = 77;

    server.replyOrClose(request_pair.a, .ok, &.{});
    server.replyOrClose(other_pair.a, .ok, &.{});

    const request_hdr = try wire.readControlHeader(request_pair.b);
    try std.testing.expectEqual(@as(u32, 77), request_hdr.request_id);

    const other_hdr = try wire.readControlHeader(other_pair.b);
    try std.testing.expectEqual(@as(u32, 0), other_hdr.request_id);
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
    server_session_handlers.handleBinarySessionRemoveTab(&server, pair.a, @sizeOf(wire.SessionRemoveTab), &buf);
    try expectBinaryError(pair.b, "unknown tab uuid");
}

test "Server.handleBinarySessionRenameTab rejects unknown snapshot tab" {
    const allocator = std.testing.allocator;
    const pair = try testSocketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);

    var ses_state = state.SesState.init(allocator);
    defer ses_state.deinit();
    _ = try addSnapshotClient(&ses_state, pair.a);

    var server = testServerWithState(allocator, &ses_state);
    defer deinitTestServer(&server);

    const new_name = "renamed";
    const msg = wire.SessionRenameTab{
        .tab_uuid = [_]u8{'t'} ** 32,
        .name_len = @intCast(new_name.len),
    };
    try wire.writeAll(pair.b, std.mem.asBytes(&msg));
    try wire.writeAll(pair.b, new_name);

    var buf: [128]u8 = undefined;
    server_session_handlers.handleBinarySessionRenameTab(&server, pair.a, @sizeOf(wire.SessionRenameTab) + @as(u32, new_name.len), &buf);
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
    server_session_handlers.handleBinarySessionRemoveFloat(&server, pair.a, @sizeOf(wire.SessionRemoveFloat), &buf);
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
    server_session_handlers.handleBinarySessionSplitPane(&server, pair.a, @sizeOf(wire.SessionSplitPane), &buf);
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
    server_session_handlers.handleBinarySessionReplaceSplitPane(&server, pair.a, @sizeOf(wire.SessionReplaceSplitPane), &buf);
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
    server_session_handlers.handleBinarySessionSetSplitRatio(&server, pair.a, @sizeOf(wire.SessionSetSplitRatio), &buf);
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

const QueuedVtFrame = struct {
    bytes: []u8,
    written: usize = 0,
};

const MuxVtQueue = struct {
    frames: std.ArrayList(QueuedVtFrame) = .empty,
    bytes: usize = 0,
    head: usize = 0,

    fn frameHeader(frame: QueuedVtFrame) ?wire.MuxVtHeader {
        if (frame.bytes.len < @sizeOf(wire.MuxVtHeader)) return null;
        var hdr_buf: [@sizeOf(wire.MuxVtHeader)]u8 = undefined;
        @memcpy(&hdr_buf, frame.bytes[0..@sizeOf(wire.MuxVtHeader)]);
        return std.mem.bytesToValue(wire.MuxVtHeader, &hdr_buf);
    }

    fn pendingLen(self: *const MuxVtQueue) usize {
        if (self.head >= self.frames.items.len) return 0;
        return self.frames.items.len - self.head;
    }

    fn compactConsumed(self: *MuxVtQueue) void {
        if (self.head == 0) return;
        if (self.head >= self.frames.items.len) {
            self.frames.clearRetainingCapacity();
            self.head = 0;
            return;
        }
        if (self.head < 64 and self.head * 2 < self.frames.items.len) return;

        const remaining = self.frames.items.len - self.head;
        std.mem.copyForwards(
            QueuedVtFrame,
            self.frames.items[0..remaining],
            self.frames.items[self.head..],
        );
        self.frames.shrinkRetainingCapacity(remaining);
        self.head = 0;
    }

    fn removeUnwrittenFrameTypeForPane(self: *MuxVtQueue, allocator: std.mem.Allocator, pane_id: u16, frame_type: u8) void {
        self.compactConsumed();
        var i: usize = self.head;
        while (i < self.frames.items.len) {
            const frame = self.frames.items[i];
            const hdr = frameHeader(frame) orelse {
                i += 1;
                continue;
            };
            if (frame.written == 0 and hdr.pane_id == pane_id and hdr.frame_type == frame_type) {
                self.bytes -= frame.bytes.len;
                allocator.free(frame.bytes);
                _ = self.frames.orderedRemove(i);
                continue;
            }
            i += 1;
        }
    }

    fn deinit(self: *MuxVtQueue, allocator: std.mem.Allocator) void {
        var i: usize = self.head;
        while (i < self.frames.items.len) : (i += 1) {
            allocator.free(self.frames.items[i].bytes);
        }
        self.frames.deinit(allocator);
        self.* = .{};
    }

    fn frameTypeIsLowValueCoalescible(frame_type: u8) bool {
        return frame_type == VT_FRAME_TYPE_BACKLOG_END or frame_type == VT_FRAME_TYPE_PASSWORD_MODE;
    }
};

fn testQueuedMuxFrame(allocator: std.mem.Allocator, pane_id: u16, frame_type: u8, written: usize) !QueuedVtFrame {
    const bytes = try allocator.alloc(u8, @sizeOf(wire.MuxVtHeader));
    const hdr = wire.MuxVtHeader{
        .pane_id = pane_id,
        .frame_type = frame_type,
        .len = 0,
    };
    @memcpy(bytes, std.mem.asBytes(&hdr));
    return .{ .bytes = bytes, .written = written };
}

test "MuxVtQueue coalesces only unwritten backlog_end frames for the same pane" {
    const allocator = std.testing.allocator;
    var queue = MuxVtQueue{};
    defer queue.deinit(allocator);

    const frame_len = @sizeOf(wire.MuxVtHeader);
    try queue.frames.append(allocator, try testQueuedMuxFrame(allocator, 1, VT_FRAME_TYPE_BACKLOG_END, 0));
    queue.bytes += frame_len;
    try queue.frames.append(allocator, try testQueuedMuxFrame(allocator, 2, VT_FRAME_TYPE_BACKLOG_END, 0));
    queue.bytes += frame_len;
    try queue.frames.append(allocator, try testQueuedMuxFrame(allocator, 1, @intFromEnum(core.pod_protocol.FrameType.output), 0));
    queue.bytes += frame_len;
    try queue.frames.append(allocator, try testQueuedMuxFrame(allocator, 1, VT_FRAME_TYPE_BACKLOG_END, 1));
    queue.bytes += frame_len;

    queue.removeUnwrittenFrameTypeForPane(allocator, 1, VT_FRAME_TYPE_BACKLOG_END);

    try std.testing.expectEqual(@as(usize, 3), queue.frames.items.len);
    try std.testing.expectEqual(@as(usize, frame_len * 3), queue.bytes);
    try std.testing.expectEqual(@as(u16, 2), MuxVtQueue.frameHeader(queue.frames.items[0]).?.pane_id);
    try std.testing.expectEqual(@intFromEnum(core.pod_protocol.FrameType.output), MuxVtQueue.frameHeader(queue.frames.items[1]).?.frame_type);
    try std.testing.expectEqual(@as(usize, 1), queue.frames.items[2].written);
}

test "MuxVtQueue coalesces only configured low-value frame types" {
    const allocator = std.testing.allocator;
    var queue = MuxVtQueue{};
    defer queue.deinit(allocator);

    const frame_len = @sizeOf(wire.MuxVtHeader);
    try queue.frames.append(allocator, try testQueuedMuxFrame(allocator, 1, VT_FRAME_TYPE_PASSWORD_MODE, 0));
    queue.bytes += frame_len;
    try queue.frames.append(allocator, try testQueuedMuxFrame(allocator, 1, VT_FRAME_TYPE_PASSWORD_MODE, 1));
    queue.bytes += frame_len;
    try queue.frames.append(allocator, try testQueuedMuxFrame(allocator, 1, @intFromEnum(core.pod_protocol.FrameType.output), 0));
    queue.bytes += frame_len;

    queue.removeUnwrittenFrameTypeForPane(allocator, 1, VT_FRAME_TYPE_PASSWORD_MODE);

    try std.testing.expectEqual(@as(usize, 2), queue.frames.items.len);
    try std.testing.expectEqual(@as(usize, frame_len * 2), queue.bytes);
    try std.testing.expectEqual(VT_FRAME_TYPE_PASSWORD_MODE, MuxVtQueue.frameHeader(queue.frames.items[0]).?.frame_type);
    try std.testing.expectEqual(@as(usize, 1), queue.frames.items[0].written);
    try std.testing.expectEqual(@intFromEnum(core.pod_protocol.FrameType.output), MuxVtQueue.frameHeader(queue.frames.items[1]).?.frame_type);

    try std.testing.expect(MuxVtQueue.frameTypeIsLowValueCoalescible(VT_FRAME_TYPE_BACKLOG_END));
    try std.testing.expect(MuxVtQueue.frameTypeIsLowValueCoalescible(VT_FRAME_TYPE_PASSWORD_MODE));
    try std.testing.expect(!MuxVtQueue.frameTypeIsLowValueCoalescible(@intFromEnum(core.pod_protocol.FrameType.output)));
}

test "MuxVtQueue compacts consumed frames without freeing active frames" {
    const allocator = std.testing.allocator;
    var queue = MuxVtQueue{};
    defer queue.deinit(allocator);

    const frame_len = @sizeOf(wire.MuxVtHeader);
    var i: usize = 0;
    while (i < 80) : (i += 1) {
        try queue.frames.append(allocator, try testQueuedMuxFrame(
            allocator,
            @intCast(i + 1),
            @intFromEnum(core.pod_protocol.FrameType.output),
            0,
        ));
        queue.bytes += frame_len;
    }

    i = 0;
    while (i < 70) : (i += 1) {
        queue.bytes -= queue.frames.items[queue.head].bytes.len;
        allocator.free(queue.frames.items[queue.head].bytes);
        queue.head += 1;
    }

    try std.testing.expectEqual(@as(usize, 10), queue.pendingLen());
    queue.compactConsumed();

    try std.testing.expectEqual(@as(usize, 0), queue.head);
    try std.testing.expectEqual(@as(usize, 10), queue.frames.items.len);
    try std.testing.expectEqual(@as(usize, frame_len * 10), queue.bytes);
    try std.testing.expectEqual(@as(u16, 71), MuxVtQueue.frameHeader(queue.frames.items[0]).?.pane_id);
}

test "enqueuePodVtFrame + flushPodVtQueue delivers pod_protocol frames in order" {
    const allocator = std.testing.allocator;
    const pair = try testSocketPair();
    defer posix.close(pair.a);
    defer posix.close(pair.b);
    // pair.a is the SES→POD write side; non-blocking as connectPodVt sets it.
    try core.ipc.setNonBlocking(pair.a);

    var ses_state = state.SesState.init(allocator);
    defer ses_state.deinit();

    var server = testServerWithState(allocator, &ses_state);
    defer deinitTestServer(&server);

    try server.enqueuePodVtFrame(pair.a, 1, "hello");
    try server.enqueuePodVtFrame(pair.a, 2, "world");
    try std.testing.expect(server.flushPodVtQueue(pair.a));

    // Queue fully drained.
    const q = ses_state.store.pod_vt_queues.getPtr(pair.a).?;
    try std.testing.expectEqual(@as(usize, 0), q.pendingLen());

    // POD side sees two well-formed pod_protocol frames, in order.
    var buf: [24]u8 = undefined;
    try wire.readExact(pair.b, buf[0..20]);
    const expected = [_]u8{ 1, 0, 0, 0, 5 } ++ "hello".* ++ [_]u8{ 2, 0, 0, 0, 5 } ++ "world".*;
    try std.testing.expectEqualSlices(u8, &expected, buf[0..20]);
}

test "enqueuePodVtFrame backpressures only once backlog exists" {
    const allocator = std.testing.allocator;
    var ses_state = state.SesState.init(allocator);
    defer ses_state.deinit();

    var server = testServerWithState(allocator, &ses_state);
    defer deinitTestServer(&server);

    const fd: posix.fd_t = 4242; // key only — never written (no flush).
    const big = try allocator.alloc(u8, POD_VT_QUEUE_MAX_BYTES);
    defer allocator.free(big);
    @memset(big, 'x');

    // First frame is accepted even though it fills the cap (empty-queue rule),
    // so a single large paste is never undeliverable.
    try server.enqueuePodVtFrame(fd, 0, big);
    // A second frame now overflows and must be rejected, not silently dropped.
    try std.testing.expectError(error.QueueFull, server.enqueuePodVtFrame(fd, 0, "!"));

    // Closing the fd frees the queue (fd-reuse safety); testing.allocator would
    // flag a leak if noteClosedFd missed it.
    ses_state.store.noteClosedFd(fd);
    try std.testing.expect(!ses_state.store.pod_vt_queues.contains(fd));
}

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
    mux_vt_queues: std.AutoHashMap(posix.fd_t, MuxVtQueue),
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
    current_ctl_request_fd: ?posix.fd_t = null,
    current_ctl_request_id: u32 = 0,

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
            .mux_vt_queues = std.AutoHashMap(posix.fd_t, MuxVtQueue).init(page_alloc),
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
        var mux_queue_it = self.mux_vt_queues.iterator();
        while (mux_queue_it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.mux_vt_queues.deinit();
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
            // Notes recorded earlier have now protected this iteration's
            // queued closes; age them out (two-iteration lifetime) so a
            // reused fd number is not shielded forever.
            self.ses_state.store.rotateClosedFdLog();
            loop.run(.once) catch |err| {
                ses.debugLog("event loop error (continuing): {s}", .{@errorName(err)});
                continue;
            };
        }

        // Final flush: mutations made since the last periodic save (e.g. a
        // detach acked moments before SIGTERM) must survive shutdown.
        if (self.ses_state.store.dirty) self.persistNow();
    }

    /// Save the canonical store now. Leaves the dirty flag set on failure so
    /// the periodic tick retries.
    pub fn persistNow(self: *Server) void {
        @import("persist.zig").save(self.allocator, self.ses_state) catch |e| {
            core.logging.logError("ses", "persist.save failed", e);
            return;
        };
        self.ses_state.store.dirty = false;
    }

    fn processPendingCtlCloses(self: *Server) void {
        if (self.pending_ctl_close_fds.items.len > 0) {
            ses.debugLog("processPendingCtlCloses: {d} pending", .{self.pending_ctl_close_fds.items.len});
        }
        for (self.pending_ctl_close_fds.items) |pending| {
            ses.debugLog("processPendingCtlCloses: fd={d}", .{pending.fd});
            if (!self.disarmCtlWatcherMatching(pending.fd, pending.watcher)) continue;

            // The fd was already closed by a direct path (client removal,
            // detach, killPane) after this entry was queued. The number may
            // belong to a brand-new connection by now — touching it would
            // close that connection or remove the wrong client.
            if (self.ses_state.store.closedFdNoted(pending.fd)) {
                ses.debugLog("processPendingCtlCloses: fd={d} already closed elsewhere, skipping", .{pending.fd});
                continue;
            }
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
                self.ses_state.store.noteClosedFd(kv.value);
                posix.close(kv.value);
            }

            // If this was a POD CTL uplink, drop the pane's reference before
            // the fd number can be reused by a new connection.
            var pane_iter = self.ses_state.store.panes.valueIterator();
            while (pane_iter.next()) |pane| {
                if (pane.pod_ctl_fd) |pod_fd| {
                    if (pod_fd == pending.fd) {
                        pane.pod_ctl_fd = null;
                        break;
                    }
                }
            }

            if (!closed_by_client_remove) {
                posix.close(pending.fd);
            }
        }
        self.pending_ctl_close_fds.clearRetainingCapacity();
    }

    fn removeClientWithWatcherCleanup(self: *Server, client_id: usize) void {
        self.purgeClientFdState(client_id);
        self.ses_state.removeClient(client_id);
    }

    /// Remove all server-side per-fd state for a client's mux fds. Must run
    /// BEFORE the state layer closes those fds: their queued closes are then
    /// skipped via the closed-fd log, so map cleanup cannot be left to the
    /// pending-close processors (which would find either nothing or, worse, a
    /// brand-new connection that reused the fd number).
    pub fn purgeClientFdState(self: *Server, client_id: usize) void {
        const client = self.ses_state.getClient(client_id) orelse return;
        if (client.mux_ctl_fd) |ctl_fd| {
            _ = self.binary_ctl_fds.remove(ctl_fd);
            self.disarmCtlWatcher(ctl_fd);
            if (self.pending_pop_requests.fetchRemove(ctl_fd)) |kv| {
                self.ses_state.store.noteClosedFd(kv.value);
                posix.close(kv.value);
            }
        }
        if (client.mux_vt_fd) |vt_fd| {
            self.disarmVtWatcher(vt_fd);
            if (self.mux_vt_queues.fetchRemove(vt_fd)) |entry| {
                var queue = entry.value;
                queue.deinit(self.allocator);
            }
        }
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
                // already returned .disarm so no CQE is pending.
                if (pending.watcher) |w| self.deferDestroyVtWatcher(w);
                continue;
            }

            // Callback already returned .disarm; defer the node's destruction
            // (do not free here). Matches the CTL path: xev may still hold a
            // reference to the completion until the current loop batch finishes,
            // so immediate free is a use-after-free in ReleaseFast. The node is
            // freed by flushDeferredDestroys at the same safe point CTL uses
            // (PLAN.md 2.5 — one agreed destruction strategy for both channels).
            if (pending.watcher) |w| self.deferDestroyVtWatcher(w);

            // Already closed by a direct path (killPane, detach, client
            // removal) after being queued here: the fd number may already
            // belong to a new connection, so neither close it nor run the
            // routing-table teardown against it.
            if (self.ses_state.store.closedFdNoted(pending.fd)) {
                ses.debugLog("processPendingVtCloses: fd={d} already closed elsewhere, skipping", .{pending.fd});
                continue;
            }

            if (self.ses_state.store.pod_vt_to_pane_id.contains(pending.fd)) {
                ses.debugLog("processPendingVtCloses: fd={d} removing pod VT", .{pending.fd});
                self.removePodVtFd(pending.fd);
            }
            if (self.isMuxVtFd(pending.fd)) {
                ses.debugLog("processPendingVtCloses: fd={d} removing MUX VT", .{pending.fd});
                self.removeMuxVtFd(pending.fd);
            }
            if (self.mux_vt_queues.fetchRemove(pending.fd)) |entry| {
                var queue = entry.value;
                queue.deinit(self.allocator);
            }
            // This close path does not route through store.noteClosedFd, so free
            // the MUX→POD input queue explicitly before the fd number is reused.
            if (self.ses_state.store.pod_vt_queues.fetchRemove(pending.fd)) |entry| {
                var queue = entry.value;
                queue.deinit(self.ses_state.store.allocator);
            }

            posix.close(pending.fd);
            ses.debugLog("processPendingVtCloses: fd={d} closed", .{pending.fd});
        }
        self.pending_vt_close_fds.clearRetainingCapacity();
    }

    /// Enqueue an fd for deferred close, deduped by fd. Shared by the CTL and
    /// VT channels so the enqueue path can't drift between them (PLAN.md 2.5).
    /// The channel-specific *drain* (processPending{Ctl,Vt}Closes) stays
    /// separate — it does genuinely different teardown per channel.
    fn queuePendingClose(
        comptime T: type,
        list: *std.ArrayList(T),
        allocator: std.mem.Allocator,
        entry: T,
        comptime label: []const u8,
    ) void {
        for (list.items) |existing| {
            if (existing.fd == entry.fd) return;
        }
        list.append(allocator, entry) catch |err| {
            core.logging.logError("ses", "failed to queue " ++ label ++ " fd close", err);
        };
    }

    pub fn queueCtlClose(self: *Server, fd: posix.fd_t, watcher: ?*CtlWatcher) void {
        queuePendingClose(PendingCtlClose, &self.pending_ctl_close_fds, self.allocator, .{ .fd = fd, .watcher = watcher }, "CTL");
    }

    fn queueVtClose(self: *Server, fd: posix.fd_t, watcher: ?*VtWatcher) void {
        queuePendingClose(PendingVtClose, &self.pending_vt_close_fds, self.allocator, .{ .fd = fd, .watcher = watcher }, "VT");
    }

    /// Write a control reply to a client fd; on failure log and queue the
    /// connection for close so stale fds don't accumulate.
    pub fn replyOrClose(self: *Server, fd: posix.fd_t, msg_type: wire.MsgType, payload: []const u8) void {
        wire.writeControlWithRequestId(fd, msg_type, self.responseRequestIdForFd(fd), payload) catch |err| {
            core.logging.warnWithSource("ses", "reply failed: fd={d} type={s} err={s}", .{ fd, @tagName(msg_type), @errorName(err) }, @src());
            self.queueCtlClose(fd, null);
        };
    }

    /// Same as replyOrClose but for messages with a trailing byte blob.
    pub fn replyOrCloseWithTrail(
        self: *Server,
        fd: posix.fd_t,
        msg_type: wire.MsgType,
        payload: []const u8,
        trail: []const u8,
    ) void {
        wire.writeControlWithTrailAndRequestId(fd, msg_type, self.responseRequestIdForFd(fd), payload, trail) catch |err| {
            core.logging.warnWithSource("ses", "reply-with-trail failed: fd={d} type={s} err={s}", .{ fd, @tagName(msg_type), @errorName(err) }, @src());
            self.queueCtlClose(fd, null);
        };
    }

    pub fn responseRequestIdForFd(self: *const Server, fd: posix.fd_t) u32 {
        if (self.current_ctl_request_fd) |request_fd| {
            if (request_fd == fd) return self.current_ctl_request_id;
        }
        return 0;
    }

    /// Assert that `client` owns `tab_uuid` in its canonical snapshot. If
    /// not, log a warning and reply with an error; returns `false` so the
    /// caller can bail out. Used by session_* handlers to reject mutations
    /// that reference tabs the client never saw.
    pub fn requireSnapshotTab(self: *Server, fd: posix.fd_t, client: *const state.Client, tab_uuid: [32]u8, op: []const u8) bool {
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
    pub fn requireSnapshotPane(self: *Server, fd: posix.fd_t, client: *const state.Client, pane_uuid: [32]u8, op: []const u8) bool {
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
    pub fn requireLiveAttachedPane(self: *Server, fd: posix.fd_t, client_id: usize, pane_uuid: [32]u8, op: []const u8) bool {
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

    /// Defer a VT watcher's destruction to `flushDeferredDestroys`, mirroring
    /// `disarmCtlWatcher`. Used when the watcher's callback has already returned
    /// `.disarm` (no pending CQE) but xev may still hold a reference to the
    /// completion until the current loop batch finishes — freeing immediately
    /// is a use-after-free in ReleaseFast. On append failure, leak rather than
    /// risk a UAF.
    fn deferDestroyVtWatcher(self: *Server, watcher: *VtWatcher) void {
        self.deferred_destroy_vt.append(self.allocator, watcher) catch |err| {
            core.logging.logError("ses", "failed to defer VT watcher destruction", err);
        };
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

    /// Collect exited pod children so they do not accumulate as zombies.
    /// Pods are the daemon's only children, so waiting on any child is safe.
    fn reapExitedPods() void {
        while (true) {
            var status: c_int = 0;
            const pid = std.c.waitpid(-1, &status, std.c.W.NOHANG);
            if (pid <= 0) break;
            ses.debugLog("reaped exited pod pid={d}", .{pid});
        }
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

        periodic.server.flushMuxVtQueues();
        periodic.server.flushPodVtQueues();

        if (periodic.server.ses_state.store.dirty and now_ms - periodic.last_save >= 1000) {
            // Keep the store dirty when the save fails (disk full, EIO) so
            // the next tick retries instead of silently dropping the state.
            periodic.server.persistNow();
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
            // Reap exited pods: they are direct children spawned without a
            // matching wait, so each would otherwise linger as a zombie and
            // keep its /proc entry alive for pid-liveness checks.
            reapExitedPods();
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
    fn enqueueMuxVtFrame(self: *Server, mux_vt_fd: posix.fd_t, pane_id: u16, frame_type: u8, payload: []const u8) !void {
        const frame_len = @sizeOf(wire.MuxVtHeader) + payload.len;
        var entry = try self.mux_vt_queues.getOrPut(mux_vt_fd);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        if (MuxVtQueue.frameTypeIsLowValueCoalescible(frame_type)) {
            entry.value_ptr.removeUnwrittenFrameTypeForPane(self.allocator, pane_id, frame_type);
        }
        if (entry.value_ptr.bytes + frame_len > MUX_VT_QUEUE_MAX_BYTES) {
            if (MuxVtQueue.frameTypeIsLowValueCoalescible(frame_type)) return;
            return error.QueueFull;
        }

        const frame = try self.allocator.alloc(u8, frame_len);
        errdefer self.allocator.free(frame);
        const mux_hdr = wire.MuxVtHeader{
            .pane_id = pane_id,
            .frame_type = frame_type,
            .len = @intCast(payload.len),
        };
        @memcpy(frame[0..@sizeOf(wire.MuxVtHeader)], std.mem.asBytes(&mux_hdr));
        if (payload.len > 0) {
            @memcpy(frame[@sizeOf(wire.MuxVtHeader)..], payload);
        }
        try entry.value_ptr.frames.append(self.allocator, .{ .bytes = frame });
        entry.value_ptr.bytes += frame_len;
    }

    fn muxVtQueueHasPending(self: *Server, mux_vt_fd: posix.fd_t) bool {
        const queue = self.mux_vt_queues.getPtr(mux_vt_fd) orelse return false;
        return queue.pendingLen() > 0;
    }

    fn flushMuxVtQueue(self: *Server, mux_vt_fd: posix.fd_t) bool {
        var queue = self.mux_vt_queues.getPtr(mux_vt_fd) orelse return true;
        defer queue.compactConsumed();

        while (queue.pendingLen() > 0) {
            var frame = &queue.frames.items[queue.head];
            const n = posix.write(mux_vt_fd, frame.bytes[frame.written..]) catch |err| {
                switch (err) {
                    error.WouldBlock => {},
                    else => {
                        ses.debugLog("vt pod->mux: queued write failed fd={d}: {s}", .{ mux_vt_fd, @errorName(err) });
                        return false;
                    },
                }
                break;
            };
            if (n == 0) return false;
            frame.written += n;
            if (frame.written < frame.bytes.len) break;

            queue.bytes -= frame.bytes.len;
            self.allocator.free(frame.bytes);
            queue.head += 1;
        }
        return true;
    }

    fn flushMuxVtQueues(self: *Server) void {
        var it = self.mux_vt_queues.iterator();
        while (it.next()) |entry| {
            _ = self.flushMuxVtQueue(entry.key_ptr.*);
        }
    }

    /// Queue a MUX→POD input frame (pod_protocol header + payload) for
    /// non-blocking delivery to a POD VT socket. Returns error.QueueFull when
    /// backlog already exists and adding this frame would exceed the cap — the
    /// caller then drops the wedged POD connection. Allocated with the store's
    /// allocator so the store can free the queue at any fd-close site.
    fn enqueuePodVtFrame(self: *Server, pod_vt_fd: posix.fd_t, frame_type: u8, payload: []const u8) !void {
        const store = &self.ses_state.store;
        const frame_len = 5 + payload.len;
        var entry = try store.pod_vt_queues.getOrPut(pod_vt_fd);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        // Always accept onto an empty queue; only backpressure once backlog
        // exists, so a single ≤MAX_PAYLOAD_LEN frame is never undeliverable.
        if (entry.value_ptr.pendingLen() > 0 and entry.value_ptr.bytes + frame_len > POD_VT_QUEUE_MAX_BYTES) {
            return error.QueueFull;
        }

        const frame = try store.allocator.alloc(u8, frame_len);
        errdefer store.allocator.free(frame);
        frame[0] = frame_type;
        std.mem.writeInt(u32, frame[1..5], @intCast(payload.len), .big);
        if (payload.len > 0) {
            @memcpy(frame[5..], payload);
        }
        try entry.value_ptr.frames.append(store.allocator, .{ .bytes = frame });
        entry.value_ptr.bytes += frame_len;
    }

    /// Drain a POD VT queue with non-blocking writes. Returns false if the
    /// connection should be removed (fatal write error).
    fn flushPodVtQueue(self: *Server, pod_vt_fd: posix.fd_t) bool {
        const store = &self.ses_state.store;
        var queue = store.pod_vt_queues.getPtr(pod_vt_fd) orelse return true;
        defer queue.compactConsumed();

        while (queue.pendingLen() > 0) {
            var frame = &queue.frames.items[queue.head];
            const n = posix.write(pod_vt_fd, frame.bytes[frame.written..]) catch |err| {
                switch (err) {
                    error.WouldBlock => {},
                    else => {
                        ses.debugLog("vt mux->pod: queued write failed fd={d}: {s}", .{ pod_vt_fd, @errorName(err) });
                        return false;
                    },
                }
                break;
            };
            if (n == 0) return false;
            frame.written += n;
            if (frame.written < frame.bytes.len) break;

            queue.bytes -= frame.bytes.len;
            store.allocator.free(frame.bytes);
            queue.head += 1;
        }
        return true;
    }

    fn flushPodVtQueues(self: *Server) void {
        // queueVtClose only appends to the pending-close list (no map mutation),
        // so closing a wedged connection mid-iteration is safe.
        var it = self.ses_state.store.pod_vt_queues.iterator();
        while (it.next()) |entry| {
            if (!self.flushPodVtQueue(entry.key_ptr.*)) {
                self.queueVtClose(entry.key_ptr.*, null);
            }
        }
    }

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

        self.enqueueMuxVtFrame(mux_vt_fd, pane_id, frame_type, payload) catch |err| {
            core.logging.logError("ses", "failed to queue MUX VT frame", err);
            self.queueVtClose(mux_vt_fd, null);
            return true;
        };
        if (!self.flushMuxVtQueue(mux_vt_fd)) {
            self.queueVtClose(mux_vt_fd, null);
        }
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

        // Ownership gate: only the pane's current owner may inject input.
        // Float steals notify the old mux best-effort, so a client with a
        // stale view can keep sending keystrokes for a pane that now renders
        // in another mux — without this check they land in the new owner's
        // shell (cross-client input injection).
        if (!self.muxVtFdOwnsPane(mux_vt_fd, mux_hdr.pane_id)) {
            ses.debugLog("vt mux->pod: dropping frame for pane_id={d} from non-owner fd={d}", .{ mux_hdr.pane_id, mux_vt_fd });
            self.skipBytes(mux_vt_fd, mux_hdr.len);
            return true;
        }

        // Read the full payload from the MUX first, so a POD that exits
        // mid-frame never receives a header without its payload. Reuse the
        // shared route buffer — the event loop is single-threaded, so this is
        // never reentrant with the POD→MUX path that also uses it.
        if (mux_hdr.len > self.vt_route_buf.len) {
            core.logging.warn("ses", "MUX VT frame exceeds route buffer: fd={d} len={d}", .{ mux_vt_fd, mux_hdr.len });
            self.skipBytes(mux_vt_fd, mux_hdr.len);
            return true;
        }
        const payload = self.vt_route_buf[0..mux_hdr.len];
        wire.readExactTimeout(mux_vt_fd, payload, VT_ROUTE_IO_TIMEOUT_MS) catch |err| {
            ses.debugLog("vt mux->pod: failed to read payload from mux: {s}", .{@errorName(err)});
            return false;
        };

        // Enqueue for non-blocking delivery. A wedged POD (child not draining
        // its VT input) must never block the SES event loop on a synchronous
        // write, so writes go through a bounded per-POD queue drained by the
        // periodic tick — symmetric with the POD→MUX path. On overflow drop the
        // whole POD VT connection (reconnected by backlog-replay if the pod is
        // still alive) rather than silently losing keystrokes.
        self.enqueuePodVtFrame(pod_vt_fd, mux_hdr.frame_type, payload) catch |err| {
            ses.debugLog("vt mux->pod: pod queue overflow fd={d}: {s}, dropping", .{ pod_vt_fd, @errorName(err) });
            self.queueVtClose(pod_vt_fd, null);
            return true;
        };
        if (!self.flushPodVtQueue(pod_vt_fd)) {
            self.queueVtClose(pod_vt_fd, null);
        }
        return true;
    }

    /// Find the MUX VT fd that should receive output for a given pane_id.
    /// Hot path: called once per pod→mux output frame, so resolve through the
    /// pane_id_to_uuid index (validated against the pane) before falling back
    /// to a full pane scan.
    fn findMuxVtForPane(self: *Server, pane_id: u16) ?posix.fd_t {
        if (self.ses_state.store.pane_id_to_uuid.get(pane_id)) |uuid| {
            if (self.ses_state.store.panes.getPtr(uuid)) |pane| {
                if (pane.pane_id == pane_id) {
                    return self.muxVtFdForPane(pane);
                }
            }
        }

        // Index miss or stale — find which pane has this pane_id by scanning.
        var pane_iter = self.ses_state.store.panes.valueIterator();
        while (pane_iter.next()) |pane| {
            if (pane.pane_id == pane_id) {
                return self.muxVtFdForPane(pane);
            }
        }
        return null;
    }

    fn muxVtFdForPane(self: *Server, pane: anytype) ?posix.fd_t {
        if (pane.attached_to) |client_id| {
            if (self.ses_state.getClient(client_id)) |client| {
                return client.mux_vt_fd;
            }
        }
        return null;
    }

    /// Whether input arriving on this mux VT fd targets a pane whose current
    /// owner is that same client. Resolves the pane like findMuxVtForPane
    /// (validated index, then scan) and compares owner VT fds.
    fn muxVtFdOwnsPane(self: *Server, mux_vt_fd: posix.fd_t, pane_id: u16) bool {
        if (self.ses_state.store.pane_id_to_uuid.get(pane_id)) |uuid| {
            if (self.ses_state.store.panes.getPtr(uuid)) |pane| {
                if (pane.pane_id == pane_id) {
                    return self.muxVtFdForPane(pane) == mux_vt_fd;
                }
            }
        }
        var pane_iter = self.ses_state.store.panes.valueIterator();
        while (pane_iter.next()) |pane| {
            if (pane.pane_id == pane_id) {
                return self.muxVtFdForPane(pane) == mux_vt_fd;
            }
        }
        // No pane record at all: the routing map alone brought us here.
        // Treat as not owned; the frame is dropped rather than injected.
        return false;
    }

    fn removePodVtFd(self: *Server, fd: posix.fd_t) void {
        ses.debugLog("remove pod_vt fd={d}", .{fd});
        const pane_id = if (self.ses_state.store.pod_vt_to_pane_id.fetchRemove(fd)) |kv| blk: {
            _ = self.ses_state.store.pane_id_to_pod_vt.remove(kv.value);
            _ = self.ses_state.store.pane_id_to_uuid.remove(kv.value);
            break :blk kv.value;
        } else null;

        // Clear from pane and decide the pane's fate.
        var exited_uuid: ?[32]u8 = null;
        var pane_iter = self.ses_state.store.panes.iterator();
        while (pane_iter.next()) |entry| {
            const pane = entry.value_ptr;
            if (pane.pod_vt_fd) |vt_fd| {
                if (vt_fd == fd) {
                    @constCast(pane).pod_vt_fd = null;

                    // A VT channel can drop for reasons other than pane death:
                    // a routing I/O timeout, a frontend dying mid-frame, or an
                    // fd mixup. SIGTERMing a healthy pod on any of those turns
                    // a transient glitch into permanent loss of the user's
                    // process. If the pod and child are still alive, let the
                    // periodic backlog-replay reconnect re-establish the
                    // channel instead of declaring the pane dead.
                    if (sticky_panes.isPidAlive(pane.pod_pid) and sticky_panes.isPidAlive(pane.child_pid)) {
                        ses.debugLog("pod VT dropped but pod alive: uuid={s} pane_id={?d}, scheduling reconnect", .{
                            entry.key_ptr[0..8],
                            pane_id,
                        });
                        pane.needs_backlog_replay = true;
                        return;
                    }

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
    pub fn findClientForCtlFd(self: *Server, fd: posix.fd_t) ?usize {
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
        const prev_request_fd = self.current_ctl_request_fd;
        const prev_request_id = self.current_ctl_request_id;
        self.current_ctl_request_fd = fd;
        self.current_ctl_request_id = hdr.request_id;
        defer {
            self.current_ctl_request_fd = prev_request_fd;
            self.current_ctl_request_id = prev_request_id;
        }

        switch (msg_type) {
            .ping => {
                self.replyOrClose(fd, .pong, &.{});
            },
            .register => {
                server_register_handler.handleBinaryRegister(self, fd, hdr.payload_len, &buf);
            },
            .create_pane => {
                server_pane_lifecycle_handlers.handleBinaryCreatePane(self, fd, hdr.payload_len, &buf);
            },
            .find_sticky => {
                server_pane_lifecycle_handlers.handleBinaryFindSticky(self, fd, hdr.payload_len, &buf);
            },
            .orphan_pane => {
                server_pane_lifecycle_handlers.handleBinaryOrphanPane(self, fd, hdr.payload_len, &buf);
            },
            .adopt_pane => {
                server_pane_lifecycle_handlers.handleBinaryAdoptPane(self, fd, hdr.payload_len, &buf);
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
                server_pane_lifecycle_handlers.handleBinaryKillPane(self, fd, hdr.payload_len, &buf);
            },
            .set_sticky => {
                server_pane_lifecycle_handlers.handleBinarySetSticky(self, fd, hdr.payload_len, &buf);
            },
            .get_pane_cwd => {
                server_pane_lifecycle_handlers.handleBinaryGetPaneCwd(self, fd, hdr.payload_len, &buf);
            },
            .pane_info => {
                if (hdr.payload_len < @sizeOf(wire.PaneUuid)) {
                    self.skipBinaryPayload(fd, hdr.payload_len, &buf);
                    self.replyOrClose(fd, .@"error", &.{});
                    return false;
                }
                const pu = wire.readStruct(wire.PaneUuid, fd) catch |err| {
                    self.ctlStreamDesynced(fd, "mid-message read failed");
                    core.logging.logError("ses", "failed to read pane_info payload", err);
                    return false;
                };
                server_reporting_handlers.handleBinaryPaneInfo(self, fd, pu.uuid);
            },
            .list_orphaned => {
                server_listing_handlers.handleBinaryListOrphaned(self, fd, &buf);
            },
            .list_sessions => {
                server_listing_handlers.handleBinaryListSessions(self, fd, &buf);
            },
            .detach => {
                server_reattach_handlers.handleBinaryDetach(self, fd, hdr.payload_len, &buf);
            },
            .reattach => {
                server_reattach_handlers.handleBinaryReattach(self, fd, hdr.payload_len, &buf);
            },
            .disconnect => {
                return server_reattach_handlers.handleBinaryDisconnect(self, fd, hdr.payload_len, &buf);
            },
            .update_pane_name => {
                server_pane_meta_handlers.handleBinaryUpdatePaneName(self, fd, hdr.payload_len, &buf);
            },
            .update_pane_shell => {
                server_pane_meta_handlers.handleBinaryUpdatePaneShell(self, fd, hdr.payload_len, &buf);
            },
            .update_pane_aux => {
                server_pane_meta_handlers.handleBinaryUpdatePaneAux(self, fd, hdr.payload_len, &buf);
            },
            .pop_response => {
                server_listing_handlers.handleBinaryPopResponse(self, fd, hdr.payload_len, &buf);
            },
            .exit_intent_result => {
                server_reporting_handlers.handleBinaryExitIntentResult(self, fd, hdr.payload_len, &buf);
            },
            .float_result => {
                server_reporting_handlers.handleBinaryFloatResult(self, fd, hdr.payload_len, &buf);
            },
            .session_add_tab => {
                server_session_handlers.handleBinarySessionAddTab(self, fd, hdr.payload_len, &buf);
            },
            .session_remove_tab => {
                server_session_handlers.handleBinarySessionRemoveTab(self, fd, hdr.payload_len, &buf);
            },
            .session_rename_tab => {
                server_session_handlers.handleBinarySessionRenameTab(self, fd, hdr.payload_len, &buf);
            },
            .session_sync_float => {
                server_session_handlers.handleBinarySessionSyncFloat(self, fd, hdr.payload_len, &buf);
            },
            .session_remove_float => {
                server_session_handlers.handleBinarySessionRemoveFloat(self, fd, hdr.payload_len, &buf);
            },
            .session_split_pane => {
                server_session_handlers.handleBinarySessionSplitPane(self, fd, hdr.payload_len, &buf);
            },
            .session_replace_split_pane => {
                server_session_handlers.handleBinarySessionReplaceSplitPane(self, fd, hdr.payload_len, &buf);
            },
            .session_set_split_ratio => {
                server_session_handlers.handleBinarySessionSetSplitRatio(self, fd, hdr.payload_len, &buf);
            },
            // POD control channel messages
            .cwd_changed => {
                server_pod_event_handlers.handleBinaryCwdChanged(self, fd, hdr.payload_len, &buf);
            },
            .fg_changed => {
                server_pod_event_handlers.handleBinaryFgChanged(self, fd, hdr.payload_len, &buf);
            },
            .shell_event => {
                server_pod_event_handlers.handleBinaryShellEvent(self, fd, hdr.payload_len, &buf);
            },
            .exited => {
                server_listing_handlers.handleBinaryExited(self, fd, hdr.payload_len, &buf);
            },
            // Named MsgTypes that never arrive on the MUX→SES binary CTL
            // channel: responses SES sends to clients, CLI-path requests
            // (dispatched in handleCliRequest), and out-of-band notifications.
            // Enumerated explicitly so adding a new MsgType is a compile error
            // here until it's categorized (PLAN.md 2.1 — no silently-dropped
            // messages). Behavior matches the former `else`: skip + error.
            .registered, .pane_created, .destroy_pane, .session_state, .notify, .pop_confirm, .pop_choose, .pong, .ok, .@"error", .pane_found, .pane_not_found, .orphaned_panes, .sessions_list, .session_reattached, .session_detached, .send_keys, .broadcast_notify, .targeted_notify, .status, .focus_move, .exit_intent, .float_request, .float_created, .pane_exited, .kill_session, .clear_sessions, .clear_orphaned_panes, .get_layout, .apply_layout, .get_session_state, .session_stolen, .bell, .shp_shell_event => {
                self.skipBinaryPayload(fd, hdr.payload_len, &buf);
                self.replyOrClose(fd, .@"error", &.{});
            },
            // Unknown wire value (not a named MsgType) — same safe handling.
            _ => {
                self.skipBinaryPayload(fd, hdr.payload_len, &buf);
                self.replyOrClose(fd, .@"error", &.{});
            },
        }
        return true;
    }

    pub fn skipBinaryPayload(self: *Server, fd: posix.fd_t, len: u32, buf: []u8) void {
        var remaining: usize = len;
        while (remaining > 0) {
            const chunk = @min(remaining, buf.len);
            wire.readExact(fd, buf[0..chunk]) catch |err| {
                core.logging.logError("ses", "failed to skip CTL payload", err);
                // The skip consumed an unknown number of bytes: the stream
                // framing is unrecoverable, so tear the connection down.
                self.ctlStreamDesynced(fd, "payload skip failed");
                return;
            };
            remaining -= chunk;
        }
    }

    /// A read failed partway through a message body: an unknown number of
    /// payload bytes were consumed, so every subsequent header read on this
    /// connection would parse garbage. The only safe recovery is to close the
    /// connection; the peer (mux or pod) reconnects through its normal path.
    pub fn ctlStreamDesynced(self: *Server, fd: posix.fd_t, comptime context: []const u8) void {
        core.logging.warnWithSource("ses", "CTL stream desynced (" ++ context ++ "): fd={d}, closing connection", .{fd}, @src());
        self.queueCtlClose(fd, null);
    }

    pub fn sendBinaryError(self: *Server, fd: posix.fd_t, msg: []const u8) void {
        var err_payload: wire.Error = .{ .msg_len = @intCast(@min(msg.len, std.math.maxInt(u16))) };
        self.replyOrCloseWithTrail(fd, .@"error", std.mem.asBytes(&err_payload), msg[0..err_payload.msg_len]);
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
                    self.ctlStreamDesynced(fd, "mid-message read failed");
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
                    self.ctlStreamDesynced(fd, "mid-message read failed");
                    core.logging.logError("ses", "exit_intent read failed", err);
                    self.closeCliRequest(fd, "exit_intent read failed");
                    return;
                };
                // Find MUX ctl fd.
                const mux_fd = self.findMuxCtlForUuid(ei.uuid) orelse {
                    // No MUX — allow exit. Close only via the queue:
                    // replyOrClose already queues the fd on write failure.
                    const allow = wire.ExitIntentResult{ .allow = 1 };
                    self.replyOrClose(fd, .exit_intent_result, std.mem.asBytes(&allow));
                    self.queueCtlClose(fd, null);
                    return;
                };
                // Close any previous pending exit_intent CLI fd.
                if (self.pending_exit_intent_cli_fd) |old_fd| {
                    self.ses_state.store.noteClosedFd(old_fd);
                    posix.close(old_fd);
                }
                self.pending_exit_intent_cli_fd = fd;
                // Forward to MUX.
                wire.writeControl(mux_fd, .exit_intent, std.mem.asBytes(&ei)) catch |err| {
                    core.logging.logError("ses", "failed to forward exit_intent to mux", err);
                    // If forward fails, allow exit.
                    const allow = wire.ExitIntentResult{ .allow = 1 };
                    self.replyOrClose(fd, .exit_intent_result, std.mem.asBytes(&allow));
                    self.queueCtlClose(fd, null);
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
                    self.ctlStreamDesynced(fd, "mid-message read failed");
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
                        self.ctlStreamDesynced(fd, "mid-message read failed");
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
                // A second concurrent float request would overwrite (and leak)
                // the previous waiter's fd; close the stale one first.
                if (self.pending_float_cli_fds.fetchRemove(zero_uuid)) |stale| {
                    self.ses_state.store.noteClosedFd(stale.value);
                    posix.close(stale.value);
                }
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
                        self.ctlStreamDesynced(fd, "mid-message read failed");
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
                    self.ctlStreamDesynced(fd, "mid-message read failed");
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
                    self.ctlStreamDesynced(fd, "mid-message read failed");
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
                        self.ctlStreamDesynced(fd, "mid-message read failed");
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
                    self.ctlStreamDesynced(fd, "mid-message read failed");
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
                    if (self.pending_pop_requests.fetchRemove(mfd)) |stale| {
                        self.ses_state.store.noteClosedFd(stale.value);
                        posix.close(stale.value);
                    }
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
                    self.ctlStreamDesynced(fd, "mid-message read failed");
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
                    if (self.pending_pop_requests.fetchRemove(mfd)) |stale| {
                        self.ses_state.store.noteClosedFd(stale.value);
                        posix.close(stale.value);
                    }
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
                    self.ctlStreamDesynced(fd, "mid-message read failed");
                    core.logging.logError("ses", "pane_info payload read failed", err);
                    self.closeCliRequest(fd, "pane_info payload read failed");
                    return;
                };
                server_reporting_handlers.handleBinaryPaneInfo(self, fd, pu.uuid);
                posix.close(fd);
            },
            .status => {
                // Payload is 1 byte: full_mode flag (0 or 1).
                var full_mode: bool = false;
                if (hdr.payload_len >= 1) {
                    var flag: [1]u8 = undefined;
                    wire.readExact(fd, &flag) catch |err| {
                        self.ctlStreamDesynced(fd, "mid-message read failed");
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
                server_reporting_handlers.handleBinaryStatus(self, fd, full_mode);
            },
            .kill_session => {
                server_cli_layout_handlers.handleKillSession(self, fd, hdr.payload_len, &buf);
            },
            .clear_sessions => {
                server_cli_layout_handlers.handleClearSessions(self, fd);
            },
            .clear_orphaned_panes => {
                server_cli_layout_handlers.handleClearOrphanedPanes(self, fd);
            },
            .get_layout => {
                server_cli_layout_handlers.handleGetLayout(self, fd, hdr.payload_len, &buf);
            },
            .apply_layout => {
                server_cli_layout_handlers.handleApplyLayout(self, fd, hdr.payload_len, &buf);
            },
            .get_session_state => {
                server_cli_layout_handlers.handleGetSessionState(self, fd, hdr.payload_len, &buf);
            },
            // Named MsgTypes that never arrive on the CLI-tool request channel
            // (handshake 0x04): MUX→SES binary CTL messages, responses, and POD
            // channel-④ events, all dispatched elsewhere. Enumerated explicitly
            // so a new MsgType is a compile error here until categorized
            // (PLAN.md 2.1). Behavior matches the former `else`.
            .register, .registered, .create_pane, .pane_created, .destroy_pane, .detach, .reattach, .session_state, .pop_response, .disconnect, .orphan_pane, .list_orphaned, .adopt_pane, .kill_pane, .set_sticky, .find_sticky, .update_pane_aux, .update_pane_name, .update_pane_shell, .get_pane_cwd, .list_sessions, .ping, .pong, .ok, .@"error", .pane_found, .pane_not_found, .orphaned_panes, .sessions_list, .session_reattached, .session_detached, .exit_intent_result, .float_created, .float_result, .pane_exited, .replay_backlogs, .session_stolen, .session_add_tab, .session_remove_tab, .session_sync_float, .session_remove_float, .session_split_pane, .session_replace_split_pane, .session_set_split_ratio, .session_rename_tab, .cwd_changed, .fg_changed, .shell_event, .bell, .exited, .shp_shell_event => {
                self.skipBinaryPayload(fd, hdr.payload_len, &buf);
                self.closeCliRequest(fd, "unsupported cli request type");
            },
            _ => {
                self.skipBinaryPayload(fd, hdr.payload_len, &buf);
                self.closeCliRequest(fd, "unsupported cli request type");
            },
        }
    }

    fn closeCliRequest(self: *Server, fd: posix.fd_t, comptime context: []const u8) void {
        core.logging.warn("ses", "closing CLI request fd={d}: {s}", .{ fd, context });
        // Several callers pair this with ctlStreamDesynced/replyOrClose, which
        // queue the same fd; the note stops the queued entry from closing a
        // reused fd number a second time.
        self.ses_state.store.noteClosedFd(fd);
        posix.close(fd);
    }

    pub fn appendStatusBytesOrClose(self: *Server, fd: posix.fd_t, buf: *std.ArrayListUnmanaged(u8), bytes: []const u8, comptime context: []const u8) bool {
        buf.appendSlice(self.ses_state.allocator, bytes) catch |err| {
            core.logging.logError("ses", "failed to build " ++ context, err);
            self.queueCtlClose(fd, null);
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

    /// Find the client (MUX) that owns a given pane UUID.
    pub fn pushClientSessionSnapshot(self: *Server, client_id: usize) void {
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

    pub fn findClientForPaneUuid(self: *Server, uuid: [32]u8) ?*state.Client {
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
