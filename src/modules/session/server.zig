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
const pane_creation = @import("pane_creation.zig");
const pane_spawn = @import("pane_spawn.zig");
const server_pane_lifecycle_handlers = @import("server_pane_lifecycle_handlers.zig");
const server_reattach_handlers = @import("server_reattach_handlers.zig");
const server_cli_layout_handlers = @import("server_cli_layout_handlers.zig");
const server_reporting_handlers = @import("server_reporting_handlers.zig");
const server_listing_handlers = @import("server_listing_handlers.zig");
const server_register_handler = @import("server_register_handler.zig");
const ses = @import("main.zig");
const vt_stream_reader = core.stream_reader;
const FramePool = @import("frame_pool.zig").FramePool;
const CtlOutQueue = @import("ctl_out_queue.zig").CtlOutQueue;
const VtStreamReader = vt_stream_reader.VtStreamReader;
const xev = @import("xev").Dynamic;

// Keep VT routing I/O short to avoid blocking the whole SES event loop when a
// peer dies mid-frame on stream sockets.
// Stall budgets for reads inside the single-threaded event loop. These used
// to be 2s (and 10s via wire defaults), which let ONE stalled client — e.g. a
// frontend SIGSTOPped between a frame header and its payload — freeze every
// other session's I/O for that long, repeatedly. Local unix-socket peers
// complete frame writes in microseconds once scheduled; 500ms is generous
// slack for a loaded machine, and a peer that stalls longer is dropped and
// heals via reconnect/backlog-replay.
const VT_ROUTE_IO_TIMEOUT_MS: i32 = 500;
const CTL_FRAME_IO_TIMEOUT_MS: i32 = 500;
pub const HANDLER_IO_TIMEOUT_MS: i32 = 500;

/// How long a FRONTEND control connection may sit accepted-but-unregistered
/// before SES reclaims it (PLAN.md A-13).
///
/// Deliberately generous. A real frontend sends `register` as its first
/// message, in milliseconds; this only reclaims sockets that completed a
/// handshake and then went silent forever, which would otherwise hold an fd
/// and a slot against the connection cap for the life of the daemon.
const UNREGISTERED_CTL_TIMEOUT_MS: i64 = 120_000;

/// How long `create_pane` may wait inline for the pod's handshake before the
/// rest of the wait moves to the periodic tick (PLAN.md 1.1).
///
/// Purely a LATENCY optimisation, and the reason this is not simply
/// tick-driven: measured spawns take 15ms/22ms/31ms (min/median/max under load
/// ~58), while the tick fires every 100ms — so deferring unconditionally would
/// make every split feel ~50ms slower for no benefit. 40ms sits just above the
/// observed maximum, so the common case completes inline at its old speed and
/// only a genuinely slow pod defers. The worst-case stall this can cost the
/// loop is therefore 40ms, against 500ms before and 2s before that.
const SPAWN_INLINE_GRACE_MS: i32 = 40;
/// Whole-skip budget. The per-chunk timeouts above restart on every chunk, so
/// only a total deadline actually bounds a peer that trickles a huge payload.
const SKIP_TOTAL_TIMEOUT_MS: i64 = 2_000;
/// Budget for reading a CLI request header. Previously this was the only read on
/// the accept path still on the 10s wire default — any process that connected
/// with the CLI handshake byte and then stalled froze EVERY session for 10s, and
/// could do it again immediately.
const CLI_HEADER_IO_TIMEOUT_MS: i32 = 500;
const MUX_VT_QUEUE_MAX_BYTES: usize = 4 * 1024 * 1024;
/// Backpressure thresholds for the POD→MUX direction.
///
/// Overflowing the per-client queue used to DROP the frontend's VT channel,
/// which the frontend heals with a full re-register + reattach — and that
/// reattach replays every pane's backlog into the same queue, overflowing it
/// again. With enough scrollback across enough panes that never converges: the
/// session flaps every RECONNECT_RETRY_MS forever.
///
/// So instead of dropping, stop READING the pods that feed a deep queue. The
/// unread bytes stay in the pod→SES socket, the pod's own bounded write starts
/// failing, and it falls back to its backlog ring — which is exactly what the
/// ring is for. Nothing is lost and no channel is torn down.
const MUX_VT_QUEUE_HIGH_WATER: usize = MUX_VT_QUEUE_MAX_BYTES * 3 / 4;
const MUX_VT_QUEUE_LOW_WATER: usize = MUX_VT_QUEUE_MAX_BYTES / 2;
// Symmetric cap for the MUX→POD (input) direction. A frame is always accepted
// onto an empty queue (so a single large paste is never undeliverable);
// overflow only trips once backlog already exists, at which point the wedged
// POD connection is dropped rather than blocking the loop.
const POD_VT_QUEUE_MAX_BYTES: usize = 4 * 1024 * 1024;
const VT_FRAME_TYPE_BACKLOG_END: u8 = @intFromEnum(core.pod_protocol.FrameType.backlog_end);
const VT_FRAME_TYPE_PASSWORD_MODE: u8 = @intFromEnum(core.pod_protocol.FrameType.password_mode);

/// Maximum number of concurrent client connections (MUX instances).
const MAX_CLIENTS: usize = core.constants.Limits.max_clients;

/// pod_protocol header: [type:u8][len:u32 big-endian].
fn podVtPayloadLen(hdr: []const u8) u32 {
    return std.mem.readInt(u32, hdr[1..5], .big);
}

/// Payload length of a wire.ControlHeader, for the resumable CTL reader.
fn ctlPayloadLen(hdr: []const u8) u32 {
    const parsed = std.mem.bytesToValue(wire.ControlHeader, hdr[0..@sizeOf(wire.ControlHeader)]);
    return parsed.payload_len;
}

/// Scratch for a whole CTL frame's payload.
///
/// Matches the 64KiB stack buffer the handlers already used, so a payload the
/// handlers could never have processed is still rejected — just earlier, and
/// without blocking.
const CTL_PAYLOAD_BUF_LEN: usize = 65536;

/// Scratch for assembling a CTL reply frame before it is written or queued.
/// Sized to hold the common case outright; larger replies fall back to a heap
/// assembly so a frame is still delivered as one all-or-nothing unit.
const CTL_FRAME_STACK_LEN: usize = 65536;

/// Cap on reply bytes buffered for one client. A peer that lets this much pile
/// up is not reading its control socket; the connection is dropped rather than
/// letting a dead client pin daemon memory. Generous enough for a full session
/// state/layout dump plus the replies around it.
const CTL_OUT_QUEUE_MAX_BYTES: usize = 4 * 1024 * 1024;

/// Cursor over a CTL payload that has already been read into memory.
///
/// Handlers used to read their payload straight off the fd with bounded
/// BLOCKING reads, using the same fd they reply on. Making those reads
/// non-blocking therefore meant separating "where the payload comes from" from
/// "where the reply goes"; this cursor is the former, and `fd` stays the
/// latter, so handler signatures are unchanged.
const PayloadCursor = struct {
    buf: []const u8 = &.{},
    pos: usize = 0,

    fn remaining(self: *const PayloadCursor) usize {
        return self.buf.len - self.pos;
    }

    fn take(self: *PayloadCursor, n: usize) ![]const u8 {
        if (n > self.remaining()) return error.PayloadTruncated;
        const out = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return out;
    }
};

/// wire.MuxVtHeader is an extern struct with align(1) fields, so `len` sits at
/// a fixed offset and is native-endian.
fn muxVtPayloadLen(hdr: []const u8) u32 {
    const parsed = std.mem.bytesToValue(wire.MuxVtHeader, hdr[0..@sizeOf(wire.MuxVtHeader)]);
    return parsed.len;
}

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
        .pending_spawns = .empty,
        .ctl_unregistered_since = std.AutoHashMap(posix.fd_t, i64).init(allocator),
        .ctl_watchers = std.AutoHashMap(posix.fd_t, *CtlWatcher).init(allocator),
        .pending_ctl_close_fds = .empty,
        .vt_watchers = std.AutoHashMap(posix.fd_t, *VtWatcher).init(allocator),
        .pending_vt_close_fds = .empty,
        .mux_vt_queues = std.AutoHashMap(posix.fd_t, MuxVtQueue).init(allocator),
        .ctl_out_queues = std.AutoHashMap(posix.fd_t, CtlOutQueue).init(allocator),
        .pending_handshakes = .empty,
        .frame_pool = FramePool.init(allocator),
        .ctl_payload_buf = allocator.alloc(u8, CTL_PAYLOAD_BUF_LEN) catch unreachable,
        .vt_readers = std.AutoHashMap(posix.fd_t, VtStreamReader).init(allocator),
        .ctl_readers = std.AutoHashMap(posix.fd_t, VtStreamReader).init(allocator),
        .paused_pod_vt_fds = std.AutoHashMap(posix.fd_t, void).init(allocator),
        .deferred_destroy_ctl = .empty,
        .deferred_destroy_vt = .empty,
        .pending_float_cli_fds = std.AutoHashMap(u32, PendingCliWait).init(allocator),
        .next_float_request_id = 1,
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
    var ctl_out_it = server.ctl_out_queues.iterator();
    while (ctl_out_it.next()) |entry| entry.value_ptr.deinit(server.allocator);
    server.ctl_out_queues.deinit();
    server.paused_pod_vt_fds.deinit();
    server.pending_handshakes.deinit(server.allocator);
    var vr_it = server.vt_readers.valueIterator();
    while (vr_it.next()) |r| r.deinit(server.allocator);
    server.vt_readers.deinit();
    var cr_it = server.ctl_readers.valueIterator();
    while (cr_it.next()) |r| r.deinit(server.allocator);
    server.ctl_readers.deinit();
    server.frame_pool.deinit();
    server.allocator.free(server.ctl_payload_buf);
    server.deferred_destroy_ctl.deinit(server.allocator);
    server.deferred_destroy_vt.deinit(server.allocator);
    server.pending_spawns.deinit(server.allocator);
    server.binary_ctl_fds.deinit();
    server.ctl_unregistered_since.deinit();
    server.allocator.free(server.vt_route_buf);
}

/// Stage a CTL payload for a handler invoked directly by a test.
///
/// In production `handleBinaryCtlMessage` reads the whole frame into
/// `ctl_payload_buf` and points the cursor at it before dispatching; these
/// tests call handlers directly, so they must do the same.
fn setTestPayload(server: *Server, parts: []const []const u8) void {
    var off: usize = 0;
    for (parts) |part| {
        @memcpy(server.ctl_payload_buf[off .. off + part.len], part);
        off += part.len;
    }
    server.ctl_payload = .{ .buf = server.ctl_payload_buf[0..off], .pos = 0 };
}

fn expectBinaryError(fd: posix.fd_t, expected: []const u8) !void {
    const hdr = try wire.readControlHeader(fd);
    try std.testing.expectEqual(@as(u16, @intFromEnum(wire.MsgType.@"error")), hdr.msg_type);
    try std.testing.expectEqual(@as(u32, @intCast(@sizeOf(wire.Error) + expected.len)), hdr.payload_len);

    const payload = try wire.readStructTimeout(wire.Error, fd, HANDLER_IO_TIMEOUT_MS);
    try std.testing.expectEqual(@as(u16, @intCast(expected.len)), payload.msg_len);

    var buf: [128]u8 = undefined;
    try std.testing.expect(expected.len <= buf.len);
    try wire.readExactTimeout(fd, buf[0..expected.len], HANDLER_IO_TIMEOUT_MS);
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

test "reapUnregisteredCtl reclaims a stale unregistered CTL fd but spares a fresh one" {
    const allocator = std.testing.allocator;
    // Needs real state: the reaper consults the client list and the pane table
    // to decide what is registered / what is a pod uplink.
    var ses_state = state.SesState.init(allocator);
    defer ses_state.deinit();
    var server = testServerWithState(allocator, &ses_state);
    defer deinitTestServer(&server);

    // Fake fd numbers: the reaper only queues them for deferred close, it does
    // not touch the descriptors itself.
    const stale_fd: posix.fd_t = 4242;
    const fresh_fd: posix.fd_t = 4243;
    const now = std.time.milliTimestamp();
    try server.ctl_unregistered_since.put(stale_fd, now - UNREGISTERED_CTL_TIMEOUT_MS - 1_000);
    try server.ctl_unregistered_since.put(fresh_fd, now);

    server.reapUnregisteredCtl();

    // Stale: queued for close and no longer tracked.
    try std.testing.expect(!server.ctl_unregistered_since.contains(stale_fd));
    var queued = false;
    for (server.pending_ctl_close_fds.items) |pending| {
        if (pending.fd == stale_fd) queued = true;
    }
    try std.testing.expect(queued);

    // Fresh: still tracked, and NOT queued. A frontend gets its full grace
    // period to send `register`.
    try std.testing.expect(server.ctl_unregistered_since.contains(fresh_fd));
    for (server.pending_ctl_close_fds.items) |pending| {
        try std.testing.expect(pending.fd != fresh_fd);
    }
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
    setTestPayload(&server, &.{std.mem.asBytes(&msg)});

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
    setTestPayload(&server, &.{ std.mem.asBytes(&msg), new_name });

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
    setTestPayload(&server, &.{std.mem.asBytes(&msg)});

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
    setTestPayload(&server, &.{std.mem.asBytes(&msg)});

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
    setTestPayload(&server, &.{std.mem.asBytes(&msg)});

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
    setTestPayload(&server, &.{std.mem.asBytes(&msg)});

    var buf: [128]u8 = undefined;
    server_session_handlers.handleBinarySessionSetSplitRatio(&server, pair.a, @sizeOf(wire.SessionSetSplitRatio), &buf);
    try expectBinaryError(pair.b, "unknown tab uuid");
}

const PendingCtlClose = struct {
    fd: posix.fd_t,
    watcher: ?*CtlWatcher,
};

/// How long a freshly accepted connection may take to send its handshake
/// preamble before we give up on it.
const HANDSHAKE_PREAMBLE_TIMEOUT_MS: i64 = 5_000;

/// A connection that has been accepted but whose handshake preamble has not
/// fully arrived yet.
///
/// The accept path used to read the preamble with blocking bounded reads: 500ms
/// for `[channel, version]`, then another 500ms for a frontend VT session id or
/// a POD uuid. Any local process could connect, send nothing, and freeze every
/// session for that long — repeatedly, and for free. The bytes are now
/// accumulated without blocking; `dispatchNewConnection` still tries once
/// inline, so a well-behaved peer (whose preamble is already in the socket
/// buffer) is dispatched with no added latency at all.
/// A `create_pane` whose pod has been forked but has not yet said hello.
///
/// SES used to block the whole event loop reading that handshake. The reply is
/// deferred instead, which keeps spawn-FAILURE reporting intact: the client
/// still learns the outcome on its original request, it just learns it a tick
/// later (PLAN.md 1.1).
const PendingSpawn = struct {
    flight: pane_creation.InFlightPane,
    /// Where the deferred `pane_created` (or error) goes. Validated against the
    /// closed-fd log before use: by the time the handshake lands this frontend
    /// may be gone and its fd number handed to somebody else.
    reply_fd: posix.fd_t,
    request_id: u32,
};

const PendingHandshake = struct {
    /// 2 bytes of `[channel, version]` plus the largest follow-on: a 32-byte
    /// frontend VT session id.
    const MAX_PREAMBLE = 34;

    fd: posix.fd_t,
    buf: [MAX_PREAMBLE]u8 = undefined,
    got: usize = 0,
    need: usize = 2,
    started_ms: i64,
};

/// A CLI process blocked in `wire.readControlHeaderBlocking` (an unbounded
/// `poll(-1)`) waiting for a frontend to answer. `owner_ctl_fd` records WHICH
/// frontend owes the answer, so its death can release the waiter instead of
/// stranding it forever — `runExitIntent` is wired into the shell's exit hook,
/// so a stranded waiter is a shell that can never exit.
const PendingCliWait = struct {
    cli_fd: posix.fd_t,
    owner_ctl_fd: posix.fd_t,
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
    /// Backing buffer, which may be LONGER than the frame: buffers come from a
    /// FramePool and are handed out with `len >= requested`.
    bytes: []u8,
    /// Logical frame length. Always use this, never `bytes.len`.
    len: usize,
    written: usize = 0,
};

const MuxVtQueue = struct {
    frames: std.ArrayList(QueuedVtFrame) = .empty,
    bytes: usize = 0,
    head: usize = 0,

    fn frameHeader(frame: QueuedVtFrame) ?wire.MuxVtHeader {
        if (frame.len < @sizeOf(wire.MuxVtHeader)) return null;
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
                self.bytes -= frame.len;
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
    return .{ .bytes = bytes, .len = bytes.len, .written = written };
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
/// Whether an fd can be polled by the event loop. Watchers are armed by fd
/// NUMBER; if a number was freed and reused by a REGULAR FILE (the state
/// file, txlog, or log), arming it makes epoll reject the completion — and
/// the loop then re-errors on it forever, pinning a core at 100% with a
/// daemon that no longer makes progress. Refuse the arm instead.
fn fdIsPollable(fd: posix.fd_t) bool {
    const st = posix.fstat(fd) catch return false;
    const kind = st.mode & posix.S.IFMT;
    return kind == posix.S.IFSOCK or kind == posix.S.IFIFO or kind == posix.S.IFCHR;
}

pub const Server = struct {
    allocator: std.mem.Allocator,
    socket: ipc.Server,
    ses_state: *state.SesState,
    running: bool,
    // Track pending pop requests: mux_fd -> cli_fd
    pending_pop_requests: std.AutoHashMap(posix.fd_t, posix.fd_t),
    // Track which fds use binary control protocol (MUX_CTL and POD_CTL connections).
    binary_ctl_fds: std.AutoHashMap(posix.fd_t, void),
    /// Panes forked but still waiting on their pod's handshake (PLAN.md 1.1).
    pending_spawns: std.ArrayList(PendingSpawn),
    /// Frontend CTL fds still awaiting `register`, and when they arrived.
    ctl_unregistered_since: std.AutoHashMap(posix.fd_t, i64),
    ctl_watchers: std.AutoHashMap(posix.fd_t, *CtlWatcher),
    pending_ctl_close_fds: std.ArrayList(PendingCtlClose),
    vt_watchers: std.AutoHashMap(posix.fd_t, *VtWatcher),
    pending_vt_close_fds: std.ArrayList(PendingVtClose),
    mux_vt_queues: std.AutoHashMap(posix.fd_t, MuxVtQueue),
    ctl_out_queues: std.AutoHashMap(posix.fd_t, CtlOutQueue),
    /// Connections accepted but still waiting for their handshake preamble.
    pending_handshakes: std.ArrayList(PendingHandshake),
    /// Resumable HEADER readers, one per CTL fd. See handleBinaryCtlMessage.
    ctl_readers: std.AutoHashMap(posix.fd_t, VtStreamReader),
    /// Resumable frame readers, one per VT fd. Keyed by fd rather than held on
    /// the watcher node because backpressure pause/resume destroys and recreates
    /// that node, which would discard a half-read frame and desync the stream.
    /// Reusable byte buffers for queued VT frames, so the routing hot path
    /// stops paying an mmap/munmap per frame under page_allocator.
    frame_pool: FramePool,
    /// Scratch holding the CTL frame currently being dispatched.
    ctl_payload_buf: []u8,
    /// Cursor handlers read their payload through.
    ctl_payload: PayloadCursor = .{},
    vt_readers: std.AutoHashMap(posix.fd_t, VtStreamReader),
    /// POD VT fds whose watcher is intentionally disarmed because the client
    /// they feed is not draining fast enough. Re-armed by
    /// `resumePausedPodVtWatchers` once the queue falls below the low-water
    /// mark. See MUX_VT_QUEUE_HIGH_WATER.
    paused_pod_vt_fds: std.AutoHashMap(posix.fd_t, void),
    // Deferred watcher destruction: nodes are kept alive for one loop iteration
    // after disarm so xev can finish processing their completions. Freeing
    // immediately causes use-after-free in ReleaseFast (xev still holds refs).
    deferred_destroy_ctl: std.ArrayList(*CtlWatcher),
    deferred_destroy_vt: std.ArrayList(*VtWatcher),
    loop_ptr: ?*xev.Loop = null,
    // CLI fd waiting for exit_intent response.
    pending_exit_intent_cli_fd: ?PendingCliWait = null,
    // CLI fds waiting for float result, keyed by float pane UUID.
    pending_float_cli_fds: std.AutoHashMap(u32, PendingCliWait),
    /// Correlates a float_request with its float_result. Every waiter used to
    /// share one all-zero uuid key, so a second concurrent request closed the
    /// first caller's fd and then received its result.
    next_float_request_id: u32,
    current_ctl_request_fd: ?posix.fd_t = null,
    current_ctl_request_id: u32 = 0,

    // Resource monitoring and limits
    resource_monitor: core.resource_limits.ResourceMonitor,
    // Reused by the single-threaded VT router to avoid alloc/free per output frame.
    vt_route_buf: []u8,

    /// Allocator is ignored — see `SesState.init`, which records the measured
    /// reason this cannot simply be switched to a GeneralPurposeAllocator.
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
            .pending_spawns = .empty,
            .ctl_unregistered_since = std.AutoHashMap(posix.fd_t, i64).init(page_alloc),
            .ctl_watchers = std.AutoHashMap(posix.fd_t, *CtlWatcher).init(page_alloc),
            .pending_ctl_close_fds = .empty,
            .vt_watchers = std.AutoHashMap(posix.fd_t, *VtWatcher).init(page_alloc),
            .pending_vt_close_fds = .empty,
            .mux_vt_queues = std.AutoHashMap(posix.fd_t, MuxVtQueue).init(page_alloc),
            .ctl_out_queues = std.AutoHashMap(posix.fd_t, CtlOutQueue).init(page_alloc),
            .pending_handshakes = .empty,
            .frame_pool = FramePool.init(page_alloc),
            .ctl_payload_buf = try page_alloc.alloc(u8, CTL_PAYLOAD_BUF_LEN),
            .vt_readers = std.AutoHashMap(posix.fd_t, VtStreamReader).init(page_alloc),
            .ctl_readers = std.AutoHashMap(posix.fd_t, VtStreamReader).init(page_alloc),
            .paused_pod_vt_fds = std.AutoHashMap(posix.fd_t, void).init(page_alloc),
            .deferred_destroy_ctl = .empty,
            .deferred_destroy_vt = .empty,
            .pending_float_cli_fds = std.AutoHashMap(u32, PendingCliWait).init(page_alloc),
            .next_float_request_id = 1,
            .resource_monitor = core.resource_limits.ResourceMonitor.init(limits),
            .vt_route_buf = try page_alloc.alloc(u8, wire.MAX_PAYLOAD_LEN),
        };
    }

    pub fn deinit(self: *Server) void {
        if (self.pending_exit_intent_cli_fd) |wait| posix.close(wait.cli_fd);
        var float_it = self.pending_float_cli_fds.iterator();
        while (float_it.next()) |entry| posix.close(entry.value_ptr.cli_fd);
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
        var ctl_out_it = self.ctl_out_queues.iterator();
        while (ctl_out_it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.ctl_out_queues.deinit();
        self.mux_vt_queues.deinit();
        self.paused_pod_vt_fds.deinit();
        for (self.pending_handshakes.items) |ph| posix.close(ph.fd);
        self.pending_handshakes.deinit(self.allocator);
        var vt_reader_it = self.vt_readers.valueIterator();
        while (vt_reader_it.next()) |r| r.deinit(self.allocator);
        self.vt_readers.deinit();
        var ctl_reader_it = self.ctl_readers.valueIterator();
        while (ctl_reader_it.next()) |r| r.deinit(self.allocator);
        self.ctl_readers.deinit();
        self.frame_pool.deinit();
        self.allocator.free(self.ctl_payload_buf);
        self.flushDeferredDestroys();
        self.deferred_destroy_ctl.deinit(self.allocator);
        self.deferred_destroy_vt.deinit(self.allocator);

        for (self.pending_spawns.items) |*ps| self.ses_state.abortCreatePane(&ps.flight);
        self.pending_spawns.deinit(self.allocator);
        self.binary_ctl_fds.deinit();
        self.ctl_unregistered_since.deinit();
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
        periodic_ctx.last_fire = std.time.milliTimestamp();
        ticker.run(&loop, &timer_completion, 100, PeriodicContext, &periodic_ctx, periodicCallback);

        var loop_err_burst: usize = 0;
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
            const dbg_t0 = std.time.milliTimestamp();
            var loop_ok = true;
            loop.run(.once) catch |err| {
                loop_ok = false;
                loop_err_burst +|= 1;
                ses.debugLog("event loop error (continuing): {s}", .{@errorName(err)});
            };
            if (loop_ok) loop_err_burst = 0;
            const dbg_t1 = std.time.milliTimestamp();
            if (dbg_t1 - dbg_t0 > 300) ses.debugLog("SLOW ses loop.run: {d}ms", .{dbg_t1 - dbg_t0});

            // Spin guard: a completion the backend keeps rejecting (e.g. a
            // watcher armed on an fd the kernel will not poll) makes
            // loop.run return an error IMMEDIATELY, every time — the old
            // "log and continue" then burned a whole core forever while the
            // daemon made no progress (observed: 1.8M errors in seconds).
            // Back off so the daemon stays responsive and the log stays
            // readable; the arm guards above prevent the usual cause.
            if (loop_err_burst > 0) {
                if (loop_err_burst % 1000 == 0) {
                    core.logging.warn("ses", "event loop erroring repeatedly ({d} in a row); backing off", .{loop_err_burst});
                }
                if (loop_err_burst > 8) std.Thread.sleep(20 * std.time.ns_per_ms);
            }

            // Ticker watchdog: the re-arm chain can die silently (xev
            // io_uring submission loss under load). All ready CQEs were just
            // processed, so 5s of silence proves no pending CQE — the
            // completion is safe to reuse. A dead ticker means no persist,
            // no queue flush, no cleanup sweeps: a slowly dying daemon.
            if (dbg_t1 - periodic_ctx.last_fire > 5000) {
                ses.debugLog("periodic ticker silent {d}ms; resurrecting", .{dbg_t1 - periodic_ctx.last_fire});
                periodic_ctx.last_fire = dbg_t1;
                ticker.run(&loop, &timer_completion, 100, PeriodicContext, &periodic_ctx, periodicCallback);
            }
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
            if (!self.disarmCtlWatcherMatching(pending.fd, pending.watcher)) {
                // Watcher already removed from the map elsewhere; its callback
                // returned .disarm (CQE consumed), so it must be freed here —
                // no stale CQE will ever fire for it.
                if (pending.watcher) |w| self.deferDestroyCtlWatcher(w);
                continue;
            }
            // Callback returned .disarm before queueing: CQE consumed, safe
            // to free after this loop batch.
            if (pending.watcher) |w| self.deferDestroyCtlWatcher(w);

            // The fd was already closed by a direct path (client removal,
            // detach, killPane) after this entry was queued. The number may
            // belong to a brand-new connection by now — touching it would
            // close that connection or remove the wrong client.
            if (self.ses_state.store.closedFdNoted(pending.fd)) {
                ses.debugLog("processPendingCtlCloses: fd={d} already closed elsewhere, skipping", .{pending.fd});
                continue;
            }
            // Reply-then-close is common here (error replies, disconnect acks,
            // the CLI request paths). The reply may still be sitting in the out
            // queue, so give it one last chance to reach the peer before the fd
            // goes away — dropCtlReader discards whatever is left.
            _ = self.flushCtlQueue(pending.fd);
            _ = self.binary_ctl_fds.remove(pending.fd);
            self.dropCtlReader(pending.fd);
            // Covers a CTL fd with no client record (never registered, or the
            // record is already gone); purgeMuxFdState handles the rest.
            self.releasePendingCliWaiters(pending.fd);

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
        self.cancelPendingSpawnsForClient(client_id);
        const client = self.ses_state.getClient(client_id) orelse return;
        self.purgeMuxFdState(client.mux_ctl_fd, client.mux_vt_fd);
    }

    /// Drop spawns still in flight for a client that just lost its session.
    ///
    /// A `create_pane` that was mid-flight when the session got STOLEN would
    /// otherwise complete a tick later and attach a brand-new pane to the OLD
    /// client — resurrecting a frontend that was supposed to exit, which is the
    /// "stolen frontend did not exit" failure.
    ///
    /// `finishCreatePane` only guards against the client being GONE
    /// (`ClientNotFound`). A steal is the case that slips through: it leaves the
    /// client alive and merely paneless, so the pane lands successfully on a
    /// frontend nobody expects to still be running. Making pane creation
    /// asynchronous is what opened this window — synchronously, the pane always
    /// existed before the steal could begin.
    pub fn cancelPendingSpawnsForClient(self: *Server, client_id: usize) void {
        var i: usize = 0;
        while (i < self.pending_spawns.items.len) {
            const ps = &self.pending_spawns.items[i];
            if (ps.flight.client_id != client_id) {
                i += 1;
                continue;
            }
            self.failPendingSpawn(ps, "session_taken_over");
            _ = self.pending_spawns.swapRemove(i);
        }
    }

    /// Release every CLI process blocked waiting on this frontend to answer.
    ///
    /// `pending_exit_intent_cli_fd` and `pending_float_cli_fds` were only ever
    /// cleaned in `deinit` or when a newer request displaced them — neither
    /// `processPendingCtlCloses` nor `purgeClientFdState` touched them, though
    /// both handle `pending_pop_requests`. So if the frontend crashed, was
    /// SIGKILLed, or had its session stolen while a request was outstanding,
    /// the CLI stayed parked in an unbounded `poll(-1)` forever and the daemon
    /// leaked its fd. Since `runExitIntent` is wired into the shell's exit hook,
    /// that presented as a shell that could never exit.
    ///
    /// Answer rather than just closing: with the frontend gone nothing can veto
    /// an exit, so `allow = 1` is the correct verdict, and a float that will
    /// never run should report failure rather than an ambiguous EOF.
    fn releasePendingCliWaiters(self: *Server, owner_ctl_fd: posix.fd_t) void {
        if (self.pending_exit_intent_cli_fd) |wait| {
            if (wait.owner_ctl_fd == owner_ctl_fd) {
                ses.debugLog("releasing exit_intent CLI waiter fd={d} (owner mux fd={d} gone)", .{ wait.cli_fd, owner_ctl_fd });
                const allow = wire.ExitIntentResult{ .allow = 1 };
                self.replyOrClose(wait.cli_fd, .exit_intent_result, std.mem.asBytes(&allow));
                self.queueCtlClose(wait.cli_fd, null);
                self.pending_exit_intent_cli_fd = null;
            }
        }

        // Collect first: replyOrClose/queueCtlClose must not run while the map
        // is being iterated.
        var orphaned: std.ArrayList(u32) = .empty;
        defer orphaned.deinit(self.allocator);
        var it = self.pending_float_cli_fds.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.owner_ctl_fd != owner_ctl_fd) continue;
            orphaned.append(self.allocator, entry.key_ptr.*) catch |err| {
                core.logging.logError("ses", "failed to collect orphaned float CLI waiter", err);
                break;
            };
        }
        for (orphaned.items) |key| {
            const entry = self.pending_float_cli_fds.fetchRemove(key) orelse continue;
            ses.debugLog("releasing float CLI waiter fd={d} (owner mux fd={d} gone)", .{ entry.value.cli_fd, owner_ctl_fd });
            const result = wire.FloatResult{
                // The waiter is keyed by request id now; the caller only cares
                // about the non-zero exit code here.
                .uuid = .{0} ** 32,
                .exit_code = 1,
                .output_len = 0,
            };
            self.replyOrClose(entry.value.cli_fd, .float_result, std.mem.asBytes(&result));
            self.queueCtlClose(entry.value.cli_fd, null);
        }
    }

    /// fd-keyed core of `purgeClientFdState`. Split out so the detach path can
    /// purge AFTER the client record is gone: `detachSession` removes the
    /// client, so a client_id lookup at that point finds nothing.
    pub fn purgeMuxFdState(self: *Server, ctl_fd: ?posix.fd_t, vt_fd: ?posix.fd_t) void {
        if (ctl_fd) |cfd| {
            self.releasePendingCliWaiters(cfd);
            self.dropCtlReader(cfd);
            _ = self.binary_ctl_fds.remove(cfd);
            self.disarmCtlWatcher(cfd);
            if (self.pending_pop_requests.fetchRemove(cfd)) |kv| {
                self.ses_state.store.noteClosedFd(kv.value);
                posix.close(kv.value);
            }
        }
        if (vt_fd) |vfd| {
            self.disarmVtWatcher(vfd);
            self.dropVtReader(vfd);
            if (self.mux_vt_queues.fetchRemove(vfd)) |entry| {
                var queue = entry.value;
                queue.deinit(self.allocator);
            }
        }
    }

    /// Purge and close a detached client's mux fds.
    ///
    /// `detachSession` removes the client record without closing these — every
    /// sibling removal path (`removeClient`, `removeClientGraceful`,
    /// `shutdownClient`, `forceDetachAttachedSession`) calls `closeClientFds`,
    /// but detach did not. That left both fds open with armed watchers and a
    /// queued-output entry owned by no client; if the frontend re-registered on
    /// the same CTL fd instead of hanging up, the new client got
    /// `mux_vt_fd = null` while the old VT fd was still armed and queued.
    ///
    /// Must run only AFTER the detach ack has been written, since the CTL fd is
    /// the connection the request arrived on.
    pub fn closeDetachedMuxFds(self: *Server, ctl_fd: ?posix.fd_t, vt_fd: ?posix.fd_t) void {
        self.purgeMuxFdState(ctl_fd, vt_fd);
        if (vt_fd) |vfd| {
            self.ses_state.store.noteClosedFd(vfd);
            posix.close(vfd);
        }
        if (ctl_fd) |cfd| {
            // Guard the (not expected, but cheap to rule out) aliasing case so
            // a double close cannot land on a recycled fd number.
            if (vt_fd == null or vt_fd.? != cfd) {
                self.ses_state.store.noteClosedFd(cfd);
                posix.close(cfd);
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
            _ = self.paused_pod_vt_fds.remove(pending.fd);
            // A reused fd number must never inherit the previous
            // connection's half-read frame.
            self.dropVtReader(pending.fd);
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

    /// Connections this daemon is actually holding right now.
    ///
    /// The cap used to read `stats.active_connections`, which the periodic tick
    /// refreshed at most once every 5s from `clients.items.len` — i.e. from
    /// REGISTERED clients only (PLAN.md A-13). Anything accepted but not yet
    /// registered was invisible to it, so a burst could blow straight past
    /// `max_connections` while the cap still saw the old, lower number.
    ///
    /// Derived from the live maps rather than kept as a counter on purpose: an
    /// increment/decrement pair that misses one close path would drift upward
    /// forever and eventually refuse every connection — a worse failure than
    /// the one being fixed, and one that only shows up after hours of uptime.
    fn liveConnectionCount(self: *const Server) usize {
        return self.ctl_watchers.count() + self.vt_watchers.count() + self.pending_handshakes.items.len;
    }

    /// Reclaim frontend CTL connections that handshaked and then never
    /// registered (PLAN.md A-13).
    ///
    /// Scoped tightly on purpose. A REGISTERED frontend may legitimately sit
    /// idle for hours (a user away from the keyboard sends no control traffic),
    /// so idleness alone must never close anything — only the absence of a
    /// client record does. Pod uplinks share `binary_ctl_fds` but are never
    /// registered as clients, so they are excluded explicitly; `pane.pod_ctl_fd`
    /// is assigned before the fd is added to that map, so there is no window in
    /// which a live pod looks unregistered.
    fn reapUnregisteredCtl(self: *Server) void {
        if (self.ctl_unregistered_since.count() == 0) return;
        const now = std.time.milliTimestamp();

        var doomed: [16]posix.fd_t = undefined;
        var doomed_n: usize = 0;

        var it = self.ctl_unregistered_since.iterator();
        while (it.next()) |entry| {
            const fd = entry.key_ptr.*;
            if (self.findClientForCtlFd(fd) != null) {
                // Registered: stop tracking it, never reap it.
                doomed[doomed_n] = fd;
                doomed_n += 1;
                if (doomed_n == doomed.len) break;
                continue;
            }
            if (now - entry.value_ptr.* <= UNREGISTERED_CTL_TIMEOUT_MS) continue;
            if (self.isPodCtlFd(fd)) continue;

            core.logging.warn("ses", "closing CTL fd={d}: handshaked but never registered", .{fd});
            self.queueCtlClose(fd, null);
            doomed[doomed_n] = fd;
            doomed_n += 1;
            if (doomed_n == doomed.len) break;
        }
        // Mutate the map only after iteration.
        for (doomed[0..doomed_n]) |fd| _ = self.ctl_unregistered_since.remove(fd);
    }

    fn isPodCtlFd(self: *const Server, fd: posix.fd_t) bool {
        var panes = self.ses_state.store.panes.valueIterator();
        while (panes.next()) |pane| {
            if (pane.pod_ctl_fd) |pod_fd| {
                if (pod_fd == fd) return true;
            }
        }
        return false;
    }

    /// Take ownership of an in-flight pane and remember where to answer.
    ///
    /// Gives the pod a brief inline grace period first (see
    /// SPAWN_INLINE_GRACE_MS) so an ordinary split keeps its old latency; a pod
    /// that misses it finishes on the tick instead, with the reply deferred.
    pub fn trackPendingSpawn(self: *Server, flight: pane_creation.InFlightPane, reply_fd: posix.fd_t) !void {
        try self.pending_spawns.append(self.allocator, .{
            .flight = flight,
            .reply_fd = reply_fd,
            .request_id = self.current_ctl_request_id,
        });

        const stdout_fd = self.pending_spawns.items[self.pending_spawns.items.len - 1].flight.spawn.stdout_file.handle;
        wire.waitReadableTimeout(stdout_fd, SPAWN_INLINE_GRACE_MS) catch {};
        self.processPendingSpawns();
    }

    /// Send a reply that belongs to a request we answered LATER than dispatch.
    ///
    /// `replyOrClose*` derive the request id from `current_ctl_request_*`, which
    /// only the dispatch path sets, so a deferred reply has to restore that pair
    /// around the send. It also has to check the fd is still ours: by now the
    /// requesting frontend may be gone and its fd number reused, and injecting a
    /// stale `pane_created` into somebody else's control stream would be worse
    /// than dropping the reply.
    fn replyDeferred(
        self: *Server,
        fd: posix.fd_t,
        request_id: u32,
        msg_type: wire.MsgType,
        payload: []const u8,
        trail: []const u8,
    ) void {
        if (self.ses_state.store.closedFdNoted(fd)) {
            ses.debugLog("deferred reply dropped: fd={d} was closed", .{fd});
            return;
        }
        const prev_fd = self.current_ctl_request_fd;
        const prev_id = self.current_ctl_request_id;
        self.current_ctl_request_fd = fd;
        self.current_ctl_request_id = request_id;
        defer {
            self.current_ctl_request_fd = prev_fd;
            self.current_ctl_request_id = prev_id;
        }
        self.replyOrCloseWithTrail(fd, msg_type, payload, trail);
    }

    fn failPendingSpawn(self: *Server, ps: *PendingSpawn, reason: []const u8) void {
        core.logging.warn("ses", "create_pane failed: {s} (uuid={s})", .{ reason, ps.flight.uuid[0..8] });
        self.ses_state.abortCreatePane(&ps.flight);
        const err_payload = wire.Error{ .msg_len = @intCast(reason.len) };
        self.replyDeferred(ps.reply_fd, ps.request_id, .@"error", std.mem.asBytes(&err_payload), reason);
    }

    /// Drive forked-but-unannounced pods. Runs on the periodic tick, so a slow
    /// pod costs latency for its own pane instead of freezing every session
    /// (PLAN.md 1.1).
    fn processPendingSpawns(self: *Server) void {
        if (self.pending_spawns.items.len == 0) return;
        const now = std.time.milliTimestamp();

        var i: usize = 0;
        while (i < self.pending_spawns.items.len) {
            const ps = &self.pending_spawns.items[i];
            switch (pane_spawn.pollPodHandshake(&ps.flight.spawn)) {
                .pending => {
                    if (!ps.flight.spawn.expired(now)) {
                        i += 1;
                        continue;
                    }
                    self.failPendingSpawn(ps, "pod_spawn_timeout");
                },
                .failed => self.failPendingSpawn(ps, "pod_bad_handshake"),
                .ready => |child_pid| {
                    if (self.ses_state.finishCreatePane(&ps.flight, child_pid)) |pane| {
                        self.ses_state.markDirty();
                        ses.debugLog("binary: pane created {s} (pid={d}, pane_id={d})", .{ pane.uuid[0..8], pane.child_pid, pane.pane_id });
                        const resp = wire.PaneCreated{
                            .uuid = pane.uuid,
                            .pid = pane.child_pid,
                            .pane_id = pane.pane_id,
                            .socket_path_len = @intCast(pane.pod_socket_path.len),
                        };
                        // NOTE: read pod_socket_path from the STORE's pane, not
                        // from the flight — finishCreatePane transferred
                        // ownership and the flight's copy is stale.
                        self.replyDeferred(ps.reply_fd, ps.request_id, .pane_created, std.mem.asBytes(&resp), pane.pod_socket_path);
                    } else |err| {
                        core.logging.logError("ses", "create_pane failed to finish", err);
                        const reason = "create_failed";
                        const err_payload = wire.Error{ .msg_len = @intCast(reason.len) };
                        self.replyDeferred(ps.reply_fd, ps.request_id, .@"error", std.mem.asBytes(&err_payload), reason);
                    }
                },
            }
            _ = self.pending_spawns.swapRemove(i);
        }
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

    /// Send a whole CTL frame without ever waiting for the peer (PLAN.md 1.5).
    ///
    /// Writes inline for as long as the socket accepts bytes, then buffers the
    /// rest. Returns false if the connection is dead or has exceeded its
    /// backlog cap, in which case the caller should close it.
    ///
    /// Ordering is the subtle part: if ANYTHING is already queued for this fd,
    /// the whole frame must queue behind it. Writing inline in that case would
    /// interleave this frame ahead of the pending bytes and desync the peer's
    /// control stream.
    pub fn writeCtlBytes(self: *Server, fd: posix.fd_t, bytes: []const u8) bool {
        if (bytes.len == 0) return true;

        var off: usize = 0;
        const queued = if (self.ctl_out_queues.getPtr(fd)) |q| q.pending() else 0;
        if (queued == 0) {
            while (off < bytes.len) {
                const n = posix.write(fd, bytes[off..]) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => {
                        ses.debugLog("ctl reply: write failed fd={d}: {s}", .{ fd, @errorName(err) });
                        return false;
                    },
                };
                if (n == 0) return false;
                off += n;
            }
            if (off == bytes.len) return true;
        }
        return self.enqueueCtlBytes(fd, bytes[off..]);
    }

    /// Buffer the unwritten tail of a frame. Overflow closes the connection: a
    /// peer that has let this much reply data pile up is not reading its
    /// control socket at all, and the alternative (dropping bytes) would leave
    /// a truncated frame on the wire.
    fn enqueueCtlBytes(self: *Server, fd: posix.fd_t, bytes: []const u8) bool {
        var entry = self.ctl_out_queues.getOrPut(fd) catch |err| {
            core.logging.logError("ses", "failed to allocate CTL out queue", err);
            return false;
        };
        if (!entry.found_existing) entry.value_ptr.* = .{};
        if (entry.value_ptr.pending() + bytes.len > CTL_OUT_QUEUE_MAX_BYTES) {
            core.logging.warnWithSource(
                "ses",
                "CTL reply backlog exceeded: fd={d} pending={d} max={d}",
                .{ fd, entry.value_ptr.pending(), CTL_OUT_QUEUE_MAX_BYTES },
                @src(),
            );
            return false;
        }
        entry.value_ptr.append(self.allocator, bytes) catch |err| {
            core.logging.logError("ses", "failed to queue CTL reply", err);
            return false;
        };
        return true;
    }

    /// Push whatever the socket will now take. Returns false on a permanent
    /// failure (EPIPE/ECONNRESET), so the caller can drop the connection.
    fn flushCtlQueue(self: *Server, fd: posix.fd_t) bool {
        const queue = self.ctl_out_queues.getPtr(fd) orelse return true;
        defer queue.compact();

        while (queue.pending() > 0) {
            const n = posix.write(fd, queue.unsent()) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    ses.debugLog("ctl reply: queued write failed fd={d}: {s}", .{ fd, @errorName(err) });
                    return false;
                },
            };
            if (n == 0) return false;
            queue.consume(n);
        }
        return true;
    }

    fn flushCtlQueues(self: *Server) void {
        // Mirrors flushMuxVtQueues: a peer that never drains would otherwise
        // pin its backlog forever. queueCtlClose only appends to a pending
        // list, so closing mid-iteration does not mutate this map.
        var it = self.ctl_out_queues.iterator();
        while (it.next()) |entry| {
            if (!self.flushCtlQueue(entry.key_ptr.*)) {
                self.queueCtlClose(entry.key_ptr.*, null);
            }
        }
    }

    /// Serialize `[header][fixed][trails...]` into `scratch` when it fits.
    /// Returns null if it does not, so the caller can fall back rather than
    /// emit a partial frame.
    fn buildCtlFrame(
        scratch: []u8,
        msg_type: wire.MsgType,
        request_id: u32,
        fixed: []const u8,
        trails: []const []const u8,
    ) ?[]const u8 {
        var total: usize = fixed.len;
        for (trails) |t| total += t.len;
        const frame_len = @sizeOf(wire.ControlHeader) + total;
        if (frame_len > scratch.len) return null;

        const hdr = wire.ControlHeader{
            .msg_type = @intFromEnum(msg_type),
            .request_id = request_id,
            .payload_len = @intCast(total),
        };
        @memcpy(scratch[0..@sizeOf(wire.ControlHeader)], std.mem.asBytes(&hdr));
        var off: usize = @sizeOf(wire.ControlHeader);
        if (fixed.len > 0) {
            @memcpy(scratch[off .. off + fixed.len], fixed);
            off += fixed.len;
        }
        for (trails) |t| {
            if (t.len == 0) continue;
            @memcpy(scratch[off .. off + t.len], t);
            off += t.len;
        }
        return scratch[0..frame_len];
    }

    /// Build and send a CTL frame, closing the connection if it cannot be
    /// delivered. The single funnel for every SES reply.
    pub fn sendCtlFrame(
        self: *Server,
        fd: posix.fd_t,
        msg_type: wire.MsgType,
        fixed: []const u8,
        trails: []const []const u8,
        comptime what: []const u8,
    ) bool {
        var stack: [CTL_FRAME_STACK_LEN]u8 = undefined;
        const request_id = self.responseRequestIdForFd(fd);

        if (buildCtlFrame(&stack, msg_type, request_id, fixed, trails)) |frame| {
            if (self.writeCtlBytes(fd, frame)) return true;
            core.logging.warnWithSource("ses", what ++ " failed: fd={d} type={s}", .{ fd, @tagName(msg_type) }, @src());
            self.queueCtlClose(fd, null);
            return false;
        }

        // Rare: a reply bigger than the stack frame (large layout/state JSON).
        // Heap-assemble rather than write piecewise, so the frame still reaches
        // writeCtlBytes as one all-or-nothing unit.
        var total: usize = fixed.len;
        for (trails) |t| total += t.len;
        const heap = self.allocator.alloc(u8, @sizeOf(wire.ControlHeader) + total) catch |err| {
            core.logging.logError("ses", what ++ ": failed to allocate reply frame", err);
            self.queueCtlClose(fd, null);
            return false;
        };
        defer self.allocator.free(heap);
        const frame = buildCtlFrame(heap, msg_type, request_id, fixed, trails).?;
        if (self.writeCtlBytes(fd, frame)) return true;
        core.logging.warnWithSource("ses", what ++ " failed: fd={d} type={s}", .{ fd, @tagName(msg_type) }, @src());
        self.queueCtlClose(fd, null);
        return false;
    }

    /// Write a control reply to a client fd; on failure log and queue the
    /// connection for close so stale fds don't accumulate.
    pub fn replyOrClose(self: *Server, fd: posix.fd_t, msg_type: wire.MsgType, payload: []const u8) void {
        _ = self.sendCtlFrame(fd, msg_type, payload, &.{}, "reply");
    }

    /// Send an UNSOLICITED push to a client, never stamped with a request id.
    ///
    /// `sendCtlFrame` tags every frame with `responseRequestIdForFd`, which is
    /// the id of the request currently being serviced. That is right for a
    /// reply and wrong for a notification: pushing `pane_exited` to a mux while
    /// servicing a request from that same fd made the notification look like
    /// the response, and the frontend's synchronous reader consumed it instead
    /// of dispatching it. A blocking float then never learned its pane had
    /// exited, so `hexe terminal float` hung forever.
    pub fn notifyOrClose(self: *Server, fd: posix.fd_t, msg_type: wire.MsgType, payload: []const u8) void {
        var stack: [CTL_FRAME_STACK_LEN]u8 = undefined;
        if (buildCtlFrame(&stack, msg_type, 0, payload, &.{})) |frame| {
            if (self.writeCtlBytes(fd, frame)) return;
            core.logging.warnWithSource("ses", "notify failed: fd={d} type={s}", .{ fd, @tagName(msg_type) }, @src());
            self.queueCtlClose(fd, null);
        }
    }

    /// Same as replyOrClose but for messages with a trailing byte blob.
    pub fn replyOrCloseWithTrail(
        self: *Server,
        fd: posix.fd_t,
        msg_type: wire.MsgType,
        payload: []const u8,
        trail: []const u8,
    ) void {
        _ = self.sendCtlFrame(fd, msg_type, payload, &.{trail}, "reply-with-trail");
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
            // These fds were closed by the STATE layer (connectPodVt replacing
            // a pod dial, detachSession, killPane), which has no handle on the
            // server's per-fd readers. Without dropping the reader here, a
            // half-read frame outlives the connection and the next connection
            // to reuse the fd number inherits it — the stream desyncs and that
            // pane goes silent. This queue is the one place all three of those
            // paths funnel through.
            self.dropVtReader(fd);
            self.dropCtlReader(fd);
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
        if (!fdIsPollable(fd)) {
            core.logging.warn("ses", "refusing to arm CTL watcher on non-pollable fd={d} (stale arm for a reused fd number)", .{fd});
            return false;
        }

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
        // Remove from map but do NOT free — the io_uring POLL_ADD may still be
        // pending, and the ring holds a pointer to node.completion that it
        // WRITES into when the CQE finally arrives (fd event, or the fd's
        // last close completing the poll). Freeing after one loop iteration
        // was a use-after-free that crashed the daemon inside Loop.tick.
        // The stale CQE reaches ctlWatcherCallback, which detects the map
        // miss and frees the orphaned node then (same model as VT watchers).
        _ = self.ctl_watchers.fetchRemove(fd);
    }

    /// Defer a CTL watcher's destruction to `flushDeferredDestroys`. Only
    /// valid once its callback has consumed the final CQE (returned .disarm):
    /// xev may still reference the completion until the loop batch finishes,
    /// but no further CQE can arrive.
    fn deferDestroyCtlWatcher(self: *Server, watcher: *CtlWatcher) void {
        self.deferred_destroy_ctl.append(self.allocator, watcher) catch |err| {
            core.logging.logError("ses", "failed to defer CTL watcher destruction", err);
            // On append failure, leak rather than risk a UAF.
        };
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
        if (!fdIsPollable(fd)) {
            core.logging.warn("ses", "refusing to arm VT watcher on non-pollable fd={d} (stale arm for a reused fd number)", .{fd});
            return false;
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
        last_fire: i64 = 0,
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

        // Disarmed while the poll was still pending: this CQE is the last
        // reference to the orphaned node. Defer its destruction (xev may
        // still touch the completion until the loop batch ends).
        const current = server.ctl_watchers.get(watch.fd);
        if (current == null or current.? != watch) {
            server.deferDestroyCtlWatcher(watch);
            return .disarm;
        }

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
            // Defer, do NOT destroy inline. The CTL path handles the identical
            // stale-CQE case with deferDestroyCtlWatcher, and the comment in
            // processPendingVtCloses states outright that an immediate free here
            // is a use-after-free in ReleaseFast because xev may still reference
            // the completion until the loop batch finishes. This path was the
            // one place that broke that rule.
            server.deferDestroyVtWatcher(watch);
            return .disarm;
        }

        _ = result catch |err| {
            core.logging.logError("ses", "VT watcher event failed", err);
            server.queueVtClose(watch.fd, watch);
            return .disarm;
        };

        // Backpressure gate: decided BEFORE reading, so the unread bytes stay
        // in the pod's socket rather than being dropped or forced into an
        // already-deep queue.
        if (watch.direction == .pod_to_mux and server.shouldPausePodVt(watch.fd)) {
            server.pausePodVtWatcher(watch.fd, watch);
            return .disarm;
        }

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
        periodic.last_fire = now_ms;

        // Advance connections whose handshake preamble has not fully arrived.
        periodic.server.processPendingHandshakes();
        periodic.server.reapUnregisteredCtl();
        periodic.server.processPendingSpawns();
        periodic.server.flushMuxVtQueues();
        periodic.server.flushPodVtQueues();
        periodic.server.flushCtlQueues();
        // Queues just drained; re-arm anything paused for backpressure.
        periodic.server.resumePausedPodVtWatchers();

        if (periodic.server.ses_state.store.dirty and now_ms - periodic.last_save >= 1000) {
            // Keep the store dirty when the save fails (disk full, EIO) so
            // the next tick retries instead of silently dropping the state.
            periodic.server.persistNow();
            periodic.last_save = now_ms;
        }

        if (now_ms - periodic.last_stats_update >= 5000) {
            const detached_sessions = periodic.server.ses_state.store.detached_sessions.count();
            const total_panes = periodic.server.ses_state.store.panes.count();
            // Report what the cap actually enforces, not just registered clients.
            const active_connections = periodic.server.liveConnectionCount();

            periodic.server.resource_monitor.updateStats(
                active_connections,
                detached_sessions,
                total_panes,
                0,
            );
            periodic.last_stats_update = now_ms;
        }

        // Backlog reconnects run on the fast tick, not the 1s cleanup sweep:
        // each pass dials at most BACKLOG_REPLAY_MAX_PER_PASS pods, so pacing
        // them at 100ms replays a whole session in well under a second while
        // keeping any single pass's blocking cost (and the resulting VT queue
        // depth) small. At the 1s cadence the same cap would have made attach
        // visibly slow.
        periodic.server.ses_state.processBacklogReplays();

        if (now_ms - periodic.last_cleanup >= 1000) {
            // Reap exited pods: they are direct children spawned without a
            // matching wait, so each would otherwise linger as a zombie and
            // keep its /proc entry alive for pid-liveness checks.
            reapExitedPods();
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
        // Drain queued watcher removals BEFORE this fd number can collide
        // with them: a pane kill queues its dead fd for watcher disarm, and
        // if a new connection reuses the number before the queue drains, the
        // stale removal would disarm the NEW connection's watcher — the
        // daemon then never reads that client's registration ("attach
        // sometimes times out").
        self.processPendingWatcherUpdates();
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

        // Only the hard COUNT ceiling here — the per-minute rate limit moved to
        // dispatchWithPreamble, where the channel type is known (PLAN.md A-14).
        // Applying the rate limit at accept time meant pod reconnects, which
        // retry from a ~1s tick, could exhaust the window and lock the user out
        // of attach; a human gets one try, a dozen pods get sixty.
        if (self.liveConnectionCount() >= self.resource_monitor.limits.max_connections) {
            ses.debugLog("reject: connection count limit exceeded (live={d})", .{self.liveConnectionCount()});
            const err_msg = "server_overloaded: connection limit exceeded";
            const err_payload = wire.Error{ .msg_len = @intCast(err_msg.len) };
            self.replyOrCloseWithTrail(conn.fd, .@"error", std.mem.asBytes(&err_payload), err_msg);
            var tmp = conn;
            tmp.close();
            return;
        }

        // Accumulate the handshake preamble without blocking. The common case
        // (preamble already buffered) completes inside this call.
        var pending = PendingHandshake{ .fd = conn.fd, .started_ms = std.time.milliTimestamp() };
        if (self.advanceHandshake(&pending) == .pending) {
            self.pending_handshakes.append(self.allocator, pending) catch |err| {
                core.logging.logError("ses", "failed to track pending handshake", err);
                self.ses_state.store.noteClosedFd(conn.fd);
                posix.close(conn.fd);
            };
        }
    }

    const HandshakeProgress = enum { done, pending };

    /// Read as much of the preamble as is available right now. `.done` means the
    /// connection was dispatched or closed and the entry must be dropped.
    fn advanceHandshake(self: *Server, ph: *PendingHandshake) HandshakeProgress {
        while (ph.got < ph.need) {
            const n = posix.read(ph.fd, ph.buf[ph.got..ph.need]) catch |err| switch (err) {
                error.WouldBlock => return .pending,
                else => {
                    core.logging.logError("ses", "connection handshake read failed", err);
                    self.closeHandshakeFd(ph.fd);
                    return .done;
                },
            };
            if (n == 0) {
                // Peer hung up before completing the preamble.
                self.closeHandshakeFd(ph.fd);
                return .done;
            }
            ph.got += n;

            if (ph.got == 2 and ph.need == 2) {
                // Decide the version verdict now, before waiting on any
                // follow-on bytes a rejected peer would never send.
                if (!self.acceptHandshakeVersion(ph.fd, ph.buf[0], ph.buf[1])) return .done;
                ph.need = switch (ph.buf[0]) {
                    wire.SES_HANDSHAKE_FRONTEND_VT => 2 + 32,
                    wire.SES_HANDSHAKE_POD_CTL => 2 + 16,
                    else => 2,
                };
            }
        }

        self.dispatchWithPreamble(ipc.Connection{ .fd = ph.fd }, ph.buf[0..ph.got]);
        return .done;
    }

    fn closeHandshakeFd(self: *Server, fd: posix.fd_t) void {
        self.ses_state.store.noteClosedFd(fd);
        posix.close(fd);
    }

    /// Drive handshakes that could not complete inline. Runs on the periodic
    /// tick, so a peer that trickles its preamble costs latency instead of
    /// freezing the loop.
    fn processPendingHandshakes(self: *Server) void {
        if (self.pending_handshakes.items.len == 0) return;
        const now = std.time.milliTimestamp();
        var i: usize = 0;
        while (i < self.pending_handshakes.items.len) {
            const ph = &self.pending_handshakes.items[i];
            if (self.advanceHandshake(ph) == .done) {
                _ = self.pending_handshakes.swapRemove(i);
                continue;
            }
            if (now - ph.started_ms > HANDSHAKE_PREAMBLE_TIMEOUT_MS) {
                core.logging.warn("ses", "handshake preamble timed out on fd={d} ({d}/{d} bytes)", .{ ph.fd, ph.got, ph.need });
                self.closeHandshakeFd(ph.fd);
                _ = self.pending_handshakes.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    /// Version gate. Returns false if the connection was rejected and closed.
    fn acceptHandshakeVersion(self: *Server, fd: posix.fd_t, channel: u8, client_version: u8) bool {
        if (!wire.isProtocolVersionSupported(client_version)) {
            ses.debugLog("reject: unsupported protocol version {d} (supported: {d}-{d})", .{
                client_version,
                wire.MIN_PROTOCOL_VERSION,
                wire.PROTOCOL_VERSION,
            });
            if (channel == wire.SES_HANDSHAKE_FRONTEND_CTL or channel == wire.SES_HANDSHAKE_POD_CTL) {
                const err_msg = std.fmt.allocPrint(
                    self.allocator,
                    "protocol_version_mismatch: client={d} supported={d}-{d}",
                    .{ client_version, wire.MIN_PROTOCOL_VERSION, wire.PROTOCOL_VERSION },
                ) catch "protocol_version_mismatch";
                defer if (!std.mem.eql(u8, err_msg, "protocol_version_mismatch")) self.allocator.free(err_msg);
                const err_payload = wire.Error{ .msg_len = @intCast(err_msg.len) };
                self.replyOrCloseWithTrail(fd, .@"error", std.mem.asBytes(&err_payload), err_msg);
            }
            self.closeHandshakeFd(fd);
            return false;
        }

        if (wire.isProtocolVersionDeprecated(client_version)) {
            ses.debugLog("warning: client using deprecated protocol version {d} (current: {d})", .{
                client_version,
                wire.PROTOCOL_VERSION,
            });
            if (channel == wire.SES_HANDSHAKE_FRONTEND_CTL) {
                const warn_msg = std.fmt.allocPrint(
                    self.allocator,
                    "Protocol version {d} is deprecated. Please update to version {d}.",
                    .{ client_version, wire.PROTOCOL_VERSION },
                ) catch "";
                defer if (warn_msg.len > 0) self.allocator.free(warn_msg);
                if (warn_msg.len > 0) {
                    const notify = wire.Notify{ .msg_len = @intCast(warn_msg.len) };
                    self.replyOrCloseWithTrail(fd, .notify, std.mem.asBytes(&notify), warn_msg);
                }
            }
        }
        return true;
    }

    /// Dispatch a connection whose full preamble has been read.
    fn dispatchWithPreamble(self: *Server, conn: ipc.Connection, preamble: []const u8) void {
        const handshake: [2]u8 = .{ preamble[0], preamble[1] };

        // Rate-limit only what a person or a script drives. POD channels are
        // exempt: they reconnect on their own timer, so counting them is what
        // starved interactive attach after a daemon restart (PLAN.md A-14).
        // Every connection is still bounded by the count ceiling at accept.
        const is_pod = handshake[0] == wire.SES_HANDSHAKE_POD_CTL;
        if (!is_pod) {
            if (!self.resource_monitor.allowNewConnectionRate()) {
                ses.debugLog("reject: connection rate limit exceeded", .{});
                const err_msg = "server_overloaded: connection rate limit exceeded";
                const err_payload = wire.Error{ .msg_len = @intCast(err_msg.len) };
                self.replyOrCloseWithTrail(conn.fd, .@"error", std.mem.asBytes(&err_payload), err_msg);
                var tmp = conn;
                tmp.close();
                return;
            }
            self.resource_monitor.recordConnection();
        }

        // Version was validated at the 2-byte boundary in advanceHandshake.
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
                self.ctl_unregistered_since.put(conn.fd, std.time.milliTimestamp()) catch {};
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
                if (preamble.len < 2 + 32) {
                    core.logging.warn("ses", "frontend VT preamble too short fd={d}", .{conn.fd});
                    var tmp = conn;
                    tmp.close();
                    return;
                }
                var sid: [32]u8 = undefined;
                @memcpy(&sid, preamble[2..34]);
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
                if (preamble.len < 2 + 16) {
                    core.logging.warn("ses", "POD ctl preamble too short fd={d}", .{conn.fd});
                    var tmp = conn;
                    tmp.close();
                    return;
                }
                var uuid_bin: [16]u8 = undefined;
                @memcpy(&uuid_bin, preamble[2..18]);
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

        const frame = try self.frame_pool.acquire(frame_len);
        errdefer self.frame_pool.release(frame);
        const mux_hdr = wire.MuxVtHeader{
            .pane_id = pane_id,
            .frame_type = frame_type,
            .len = @intCast(payload.len),
        };
        @memcpy(frame[0..@sizeOf(wire.MuxVtHeader)], std.mem.asBytes(&mux_hdr));
        if (payload.len > 0) {
            @memcpy(frame[@sizeOf(wire.MuxVtHeader)..frame_len], payload);
        }
        try entry.value_ptr.frames.append(self.allocator, .{ .bytes = frame, .len = frame_len });
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
            const n = posix.write(mux_vt_fd, frame.bytes[frame.written..frame.len]) catch |err| {
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
            if (frame.written < frame.len) break;

            queue.bytes -= frame.len;
            self.frame_pool.release(frame.bytes);
            queue.head += 1;
        }
        return true;
    }

    /// Queued bytes waiting to reach this client, without allocating.
    fn muxVtQueueBytes(self: *Server, mux_vt_fd: posix.fd_t) usize {
        const queue = self.mux_vt_queues.getPtr(mux_vt_fd) orelse return 0;
        return queue.bytes;
    }

    /// Resolve where a POD VT fd's output would go, consuming no bytes. Used to
    /// decide backpressure BEFORE reading a frame off the socket.
    fn muxVtTargetForPodVt(self: *Server, pod_vt_fd: posix.fd_t) ?posix.fd_t {
        const pane_id = self.ses_state.store.pod_vt_to_pane_id.get(pod_vt_fd) orelse return null;
        return self.findMuxVtForPane(pane_id);
    }

    /// Whether this pod's output should stop being read for now.
    fn shouldPausePodVt(self: *Server, pod_vt_fd: posix.fd_t) bool {
        const mux_vt_fd = self.muxVtTargetForPodVt(pod_vt_fd) orelse return false;
        return self.muxVtQueueBytes(mux_vt_fd) >= MUX_VT_QUEUE_HIGH_WATER;
    }

    /// Disarm a POD VT watcher for backpressure and remember to re-arm it.
    /// Only valid from the watcher callback immediately before it returns
    /// `.disarm` — the CQE is consumed at that point, so the node is safe to
    /// defer-destroy (same contract as processPendingVtCloses).
    fn pausePodVtWatcher(self: *Server, fd: posix.fd_t, watcher: *VtWatcher) void {
        self.paused_pod_vt_fds.put(fd, {}) catch |err| {
            // Without a pause record nothing would ever re-arm this fd and the
            // pane would go permanently silent. Keep reading instead: a deep
            // queue is far better than a dead pane.
            core.logging.logError("ses", "failed to record paused POD VT fd", err);
            return;
        };
        // Defer-destroy on BOTH branches, matching processPendingVtCloses: the
        // callback returns .disarm right after this either way, so no further
        // CQE can arrive for the node and freeing it at the next safe point is
        // correct whether or not it was still the map's current watcher.
        _ = self.disarmVtWatcherMatching(fd, watcher);
        self.deferDestroyVtWatcher(watcher);
        ses.debugLog("vt pod->mux: pausing pod_vt_fd={d} (client queue above high water)", .{fd});
    }

    /// Re-arm pod VT watchers whose destination has drained. Also releases the
    /// pause when the destination went away entirely — otherwise a client that
    /// disconnected while a pod was paused would leave that pod silent forever.
    fn resumePausedPodVtWatchers(self: *Server) void {
        if (self.paused_pod_vt_fds.count() == 0) return;

        var resume_fds: std.ArrayList(posix.fd_t) = .empty;
        defer resume_fds.deinit(self.allocator);

        var it = self.paused_pod_vt_fds.keyIterator();
        while (it.next()) |fd_ptr| {
            const fd = fd_ptr.*;
            const still_paused = blk: {
                const mux_vt_fd = self.muxVtTargetForPodVt(fd) orelse break :blk false;
                break :blk self.muxVtQueueBytes(mux_vt_fd) > MUX_VT_QUEUE_LOW_WATER;
            };
            if (still_paused) continue;
            resume_fds.append(self.allocator, fd) catch |err| {
                core.logging.logError("ses", "failed to collect resumable POD VT fd", err);
                break;
            };
        }

        for (resume_fds.items) |fd| {
            _ = self.paused_pod_vt_fds.remove(fd);
            // A pod fd closed while paused is no longer pollable; armVtWatcher
            // refuses it and we simply drop the pause record.
            if (self.armVtWatcher(fd, .pod_to_mux)) {
                ses.debugLog("vt pod->mux: resuming pod_vt_fd={d}", .{fd});
            }
        }
    }

    fn flushMuxVtQueues(self: *Server) void {
        // Drop a connection whose queued write failed permanently (EPIPE,
        // ECONNRESET), exactly as flushPodVtQueues does for the other
        // direction. Discarding the result left a dead frontend's queue pinning
        // up to MUX_VT_QUEUE_MAX_BYTES and being retried at 10Hz forever; it
        // was only ever cleaned up incidentally, when a new pod frame happened
        // to route to the same fd — which never happens for an idle pane.
        // queueVtClose only appends to the pending-close list (no map
        // mutation), so closing mid-iteration is safe.
        var it = self.mux_vt_queues.iterator();
        while (it.next()) |entry| {
            if (!self.flushMuxVtQueue(entry.key_ptr.*)) {
                self.queueVtClose(entry.key_ptr.*, null);
            }
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

        // Deliberately NOT pooled: this queue is owned by the STORE and is
        // freed from paths that have no handle on the server's pool
        // (noteClosedFd, store teardown). Handing it server-owned buffers is a
        // cross-allocator free waiting to happen -- the unit tests caught
        // exactly that. The mux direction, which the server owns end to end,
        // is pooled instead, and it is the higher-volume one.
        const frame = try store.allocator.alloc(u8, frame_len);
        errdefer store.allocator.free(frame);
        frame[0] = frame_type;
        std.mem.writeInt(u32, frame[1..5], @intCast(payload.len), .big);
        if (payload.len > 0) {
            @memcpy(frame[5..frame_len], payload);
        }
        try entry.value_ptr.frames.append(store.allocator, .{ .bytes = frame, .len = frame_len });
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
            const n = posix.write(pod_vt_fd, frame.bytes[frame.written..frame.len]) catch |err| {
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
            if (frame.written < frame.len) break;

            queue.bytes -= frame.len;
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

    /// Frames routed per wakeup before yielding, so one loud pane cannot
    /// starve the others. The reader keeps any partial frame, so a budget
    /// boundary is never a desync.
    const VT_FRAMES_PER_WAKEUP: usize = 32;

    fn vtReaderFor(self: *Server, fd: posix.fd_t, hdr_len: u8, len_fn: vt_stream_reader.PayloadLenFn) ?*VtStreamReader {
        const entry = self.vt_readers.getOrPut(fd) catch |err| {
            core.logging.logError("ses", "failed to allocate VT stream reader", err);
            return null;
        };
        if (!entry.found_existing) entry.value_ptr.* = VtStreamReader.init(hdr_len, len_fn);
        return entry.value_ptr;
    }

    fn ctlReaderFor(self: *Server, fd: posix.fd_t) ?*VtStreamReader {
        const entry = self.ctl_readers.getOrPut(fd) catch |err| {
            core.logging.logError("ses", "failed to allocate CTL header reader", err);
            return null;
        };
        if (!entry.found_existing) {
            entry.value_ptr.* = VtStreamReader.init(@sizeOf(wire.ControlHeader), ctlPayloadLen);
        }
        return entry.value_ptr;
    }

    /// Read a fixed struct from the CTL payload currently being dispatched.
    pub fn readPayloadStruct(self: *Server, comptime T: type) !T {
        const bytes = try self.ctl_payload.take(@sizeOf(T));
        return std.mem.bytesToValue(T, bytes[0..@sizeOf(T)]);
    }

    /// Copy `dest.len` bytes out of the current CTL payload.
    pub fn readPayloadInto(self: *Server, dest: []u8) !void {
        const bytes = try self.ctl_payload.take(dest.len);
        @memcpy(dest, bytes);
    }

    /// Discard the rest of the current CTL payload. Always succeeds: the frame
    /// is already in memory, so there is nothing left to fail on.
    pub fn skipPayloadRest(self: *Server) void {
        self.ctl_payload.pos = self.ctl_payload.buf.len;
    }

    /// Drop all per-fd CTL stream state: the resumable reader AND the outbound
    /// reply queue. Both are keyed by fd number and both are lethal if they
    /// outlive the connection — a reused fd number would inherit a half-read
    /// frame on the way in, or unsent reply bytes prepended to a brand-new
    /// client's stream on the way out. They are dropped together so the
    /// several cleanup paths that call this cannot cover one and miss the
    /// other.
    pub fn dropCtlReader(self: *Server, fd: posix.fd_t) void {
        if (self.ctl_readers.fetchRemove(fd)) |kv| {
            var reader = kv.value;
            reader.deinit(self.allocator);
        }
        _ = self.ctl_unregistered_since.remove(fd);
        if (self.ctl_out_queues.fetchRemove(fd)) |kv| {
            var queue = kv.value;
            if (queue.pending() > 0) {
                ses.debugLog("ctl reply: dropping {d} unsent bytes for fd={d}", .{ queue.pending(), fd });
            }
            queue.deinit(self.allocator);
        }
    }

    pub fn dropVtReader(self: *Server, fd: posix.fd_t) void {
        if (self.vt_readers.fetchRemove(fd)) |kv| {
            var reader = kv.value;
            reader.deinit(self.allocator);
        }
    }

    /// Route VT data from POD -> MUX.
    ///
    /// Drains without blocking: the reader retains any partial frame, so a pod
    /// that stalls mid-frame costs nothing instead of freezing every session for
    /// the read timeout. Because the payload is always fully in hand before
    /// routing, an unroutable frame is simply discarded — no `skipBytes`, and
    /// therefore no way to leave the stream desynced.
    fn routePodToMux(self: *Server, pod_vt_fd: posix.fd_t) bool {
        const reader = self.vtReaderFor(pod_vt_fd, 5, podVtPayloadLen) orelse return false;

        var routed: usize = 0;
        while (routed < VT_FRAMES_PER_WAKEUP) : (routed += 1) {
            switch (reader.next(pod_vt_fd, self.vt_route_buf, self.allocator)) {
                .none => return true,
                .closed => {
                    ses.debugLog("vt pod->mux: pod_vt_fd={d} closed", .{pod_vt_fd});
                    return false;
                },
                .failed => {
                    core.logging.logError("ses", "POD VT read failed", error.BrokenPipe);
                    return false;
                },
                .oversize => |len| {
                    core.logging.warn("ses", "POD VT frame too large: fd={d} len={d}; dropping connection", .{ pod_vt_fd, len });
                    return false;
                },
                .frame => |frame| {
                    const frame_type = frame.hdr[0];
                    const pane_id = self.ses_state.store.pod_vt_to_pane_id.get(pod_vt_fd) orelse {
                        ses.debugLog("vt pod->mux: pod_vt_fd={d} not routed, discarding {d} bytes", .{ pod_vt_fd, frame.payload.len });
                        continue;
                    };
                    const mux_vt_fd = self.findMuxVtForPane(pane_id) orelse {
                        core.logging.warn("ses", "POD VT frame has no mux target: pod_vt_fd={d} pane_id={d}", .{ pod_vt_fd, pane_id });
                        continue;
                    };
                    self.enqueueMuxVtFrame(mux_vt_fd, pane_id, frame_type, frame.payload) catch |err| {
                        // See enqueueMuxVtFrame: dropping one frame beats
                        // dropping the client's channel and re-triggering the
                        // replay that overflowed the queue.
                        core.logging.warn("ses", "mux VT queue full: dropping frame pane_id={d} len={d} ({s})", .{
                            pane_id,
                            frame.payload.len,
                            @errorName(err),
                        });
                        continue;
                    };
                    if (!self.flushMuxVtQueue(mux_vt_fd)) {
                        self.queueVtClose(mux_vt_fd, null);
                    }
                },
            }
        }
        return true;
    }

    /// Route VT data from MUX -> POD. Same non-blocking contract as above.
    fn routeMuxToPod(self: *Server, mux_vt_fd: posix.fd_t) bool {
        const reader = self.vtReaderFor(mux_vt_fd, @sizeOf(wire.MuxVtHeader), muxVtPayloadLen) orelse return false;

        var routed: usize = 0;
        while (routed < VT_FRAMES_PER_WAKEUP) : (routed += 1) {
            switch (reader.next(mux_vt_fd, self.vt_route_buf, self.allocator)) {
                .none => return true,
                .closed => {
                    ses.debugLog("vt mux->pod: mux_vt_fd={d} closed", .{mux_vt_fd});
                    return false;
                },
                .failed => {
                    ses.debugLog("vt mux->pod: read failed fd={d}", .{mux_vt_fd});
                    return false;
                },
                .oversize => |len| {
                    core.logging.warn("ses", "MUX VT frame too large: fd={d} len={d}; dropping connection", .{ mux_vt_fd, len });
                    return false;
                },
                .frame => |frame| {
                    const mux_hdr = std.mem.bytesToValue(wire.MuxVtHeader, frame.hdr[0..@sizeOf(wire.MuxVtHeader)]);
                    const pod_vt_fd = self.ses_state.store.pane_id_to_pod_vt.get(mux_hdr.pane_id) orelse {
                        core.logging.warn("ses", "MUX VT frame for unknown pane_id={d} fd={d}", .{ mux_hdr.pane_id, mux_vt_fd });
                        continue;
                    };
                    // Ownership gate: only the pane's current owner may inject
                    // input, or a client with a stale view keeps typing into a
                    // pane that now renders elsewhere.
                    if (!self.muxVtFdOwnsPane(mux_vt_fd, mux_hdr.pane_id)) {
                        ses.debugLog("vt mux->pod: dropping frame for pane_id={d} from non-owner fd={d}", .{ mux_hdr.pane_id, mux_vt_fd });
                        continue;
                    }
                    self.enqueuePodVtFrame(pod_vt_fd, mux_hdr.frame_type, frame.payload) catch |err| {
                        ses.debugLog("vt mux->pod: pod queue overflow fd={d}: {s}, dropping", .{ pod_vt_fd, @errorName(err) });
                        self.queueVtClose(pod_vt_fd, null);
                        continue;
                    };
                    if (!self.flushPodVtQueue(pod_vt_fd)) {
                        self.queueVtClose(pod_vt_fd, null);
                    }
                },
            }
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
        // Drop any backpressure pause for this fd: the number can be reused by
        // a new connection, and re-arming it later would attach a pod_to_mux
        // watcher to something else entirely.
        _ = self.paused_pod_vt_fds.remove(fd);
        self.dropVtReader(fd);
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
                        pane.requestBacklogReplay();
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
                                self.notifyOrClose(ctl_fd, .pane_exited, std.mem.asBytes(&msg));
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
        self.dropVtReader(fd);
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
    ///
    /// The per-chunk timeout alone is NOT a bound: readExactTimeout starts a
    /// fresh deadline on every call, so a peer that trickles one chunk just
    /// inside the budget never trips it. With a 4MB max payload and 4KB chunks
    /// that is 1024 chunks x 500ms = ~8.5 MINUTES of frozen daemon. The total
    /// deadline below is what actually bounds it.
    /// Find client_id for a binary CTL fd.
    pub fn findClientForCtlFd(self: *Server, fd: posix.fd_t) ?usize {
        for (self.ses_state.store.clients.items) |client| {
            if (client.fd == fd or client.mux_ctl_fd == fd) return client.id;
        }
        return null;
    }

    /// Handle a binary control message. Returns false if connection should be removed.
    fn handleBinaryCtlMessage(self: *Server, fd: posix.fd_t) bool {
        // Read the header RESUMABLY and without blocking.
        //
        // `readControlHeaderTimeout` blocked for up to CTL_FRAME_IO_TIMEOUT_MS
        // once any part of the 10-byte header had arrived — the cheapest stall
        // vector there was: send one byte, wait, repeat, and every session
        // freezes each time. Splitting a header across writes is not just a
        // hostile act either; `writeAllTimeout` produces it whenever the peer's
        // socket buffer is briefly full under load, which is exactly what made
        // the frontend's own header read busy-spin before it was fixed.
        //
        // The PAYLOAD is read here too, in the same resumable pass. Handlers
        // used to pull it off this fd themselves with bounded blocking reads,
        // which reopened the same stall vector one level down: a client that
        // sent a header and then dribbled its payload froze every session for
        // the timeout. They now read it through `ctl_payload`, so a handler
        // cannot block on the socket at all. That is why the fd argument they
        // still take is a REPLY SINK only, never a read source.
        const reader = self.ctlReaderFor(fd) orelse return false;
        const hdr = switch (reader.next(fd, self.ctl_payload_buf, self.allocator)) {
            .none => return true, // frame still in flight; resume on next wakeup
            .closed => {
                ses.debugLog("ctl: fd={d} closed", .{fd});
                return false;
            },
            .failed => {
                core.logging.logError("ses", "failed to read control frame", error.BrokenPipe);
                return false;
            },
            .oversize => |len| {
                // Bigger than any handler could ever process (they all used a
                // 64KiB stack buffer). Rejected here rather than drained,
                // because a payload that large means the stream is desynced and
                // cannot be resynchronised by skipping.
                core.logging.warnWithSource(
                    "ses",
                    "ctl payload too large: len={d} max={d} fd={d}",
                    .{ len, CTL_PAYLOAD_BUF_LEN, fd },
                    @src(),
                );
                return false;
            },
            .frame => |frame| blk: {
                // The whole payload is now in memory; handlers read it through
                // the cursor instead of blocking on the socket.
                self.ctl_payload = .{ .buf = frame.payload, .pos = 0 };
                break :blk std.mem.bytesToValue(wire.ControlHeader, frame.hdr[0..@sizeOf(wire.ControlHeader)]);
            },
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
        const prev_payload = self.ctl_payload;
        self.current_ctl_request_fd = fd;
        self.current_ctl_request_id = hdr.request_id;
        defer {
            self.current_ctl_request_fd = prev_request_fd;
            self.current_ctl_request_id = prev_request_id;
            // Restored with the rest of the per-request state. Nothing reenters
            // this function today, but the cursor borrows a SHARED scratch
            // buffer, so leaving it dangling past the dispatch would hand the
            // next caller a stale window into a buffer that has been refilled.
            self.ctl_payload = prev_payload;
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
                    self.skipPayloadRest();
                    self.replyOrClose(fd, .@"error", &.{});
                    return false;
                }
                const pu = self.readPayloadStruct(wire.PaneUuid) catch |err| {
                    core.logging.logError("ses", "failed to read pane_info payload", err);
                    self.replyOrClose(fd, .@"error", &.{});
                    return true;
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
                server_reporting_handlers.handleBinaryFloatResult(self, fd, hdr.request_id, hdr.payload_len, &buf);
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
            .registered, .pane_created, .destroy_pane, .session_state, .notify, .pop_confirm, .pop_choose, .pong, .ok, .@"error", .pane_found, .pane_not_found, .orphaned_panes, .sessions_list, .session_reattached, .session_detached, .send_keys, .broadcast_notify, .targeted_notify, .status, .focus_move, .exit_intent, .float_request, .float_created, .pane_exited, .kill_session, .kill_target, .clear_sessions, .clear_orphaned_panes, .get_layout, .apply_layout, .get_session_state, .session_stolen, .bell, .shp_shell_event => {
                self.skipPayloadRest();
                self.replyOrClose(fd, .@"error", &.{});
            },
            // Unknown wire value (not a named MsgType) — same safe handling.
            _ => {
                self.skipPayloadRest();
                self.replyOrClose(fd, .@"error", &.{});
            },
        }
        return true;
    }

    /// Same trickle hazard as skipBytes: bound the WHOLE skip, not each chunk.
    pub fn skipBinaryPayload(self: *Server, fd: posix.fd_t, len: u32, buf: []u8) void {
        var remaining: usize = len;
        const deadline = std.time.milliTimestamp() + SKIP_TOTAL_TIMEOUT_MS;
        while (remaining > 0) {
            if (std.time.milliTimestamp() >= deadline) {
                core.logging.warn("ses", "giving up skipping CTL payload ({d} bytes left)", .{remaining});
                self.ctlStreamDesynced(fd, "payload skip timed out");
                return;
            }
            const chunk = @min(remaining, buf.len);
            wire.readExactTimeout(fd, buf[0..chunk], HANDLER_IO_TIMEOUT_MS) catch |err| {
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
        const hdr = wire.readControlHeaderTimeout(fd, CLI_HEADER_IO_TIMEOUT_MS) catch |err| {
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
                const fm = wire.readStructTimeout(wire.FocusMove, fd, HANDLER_IO_TIMEOUT_MS) catch |err| {
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
                self.finishCliRequest(fd);
            },
            .exit_intent => {
                if (hdr.payload_len < @sizeOf(wire.ExitIntent)) {
                    self.closeCliRequest(fd, "exit_intent payload too small");
                    return;
                }
                const ei = wire.readStructTimeout(wire.ExitIntent, fd, HANDLER_IO_TIMEOUT_MS) catch |err| {
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
                if (self.pending_exit_intent_cli_fd) |old_wait| {
                    self.ses_state.store.noteClosedFd(old_wait.cli_fd);
                    posix.close(old_wait.cli_fd);
                }
                self.pending_exit_intent_cli_fd = .{ .cli_fd = fd, .owner_ctl_fd = mux_fd };
                // Forward to MUX.
                wire.writeControlTimeout(mux_fd, .exit_intent, std.mem.asBytes(&ei), HANDLER_IO_TIMEOUT_MS) catch |err| {
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
                const fr = wire.readStructTimeout(wire.FloatRequest, fd, HANDLER_IO_TIMEOUT_MS) catch |err| {
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
                    wire.readExactTimeout(fd, buf[0..trail_len], HANDLER_IO_TIMEOUT_MS) catch |err| {
                        self.ctlStreamDesynced(fd, "mid-message read failed");
                        core.logging.logError("ses", "float_request trail read failed", err);
                        self.closeCliRequest(fd, "float_request trail read failed");
                        return;
                    };
                }
                // Resolve the caller's own session — never another one.
                const mux_fd = self.resolveFloatTargetMux(fr.source_session_id) orelse {
                    core.logging.warn("ses", "float_request target mux not found for session={s}", .{fr.source_session_id[0..8]});
                    self.sendBinaryError(fd, "no_mux");
                    self.finishCliRequest(fd);
                    return;
                };
                // Forward entire float_request to MUX.
                // Tag the request so its result can be matched back to THIS
                // caller. Concurrent `hexe terminal float` calls are ordinary
                // (a picker float in two panes); without a correlation id they
                // shared one slot.
                const float_req_id = self.next_float_request_id;
                self.next_float_request_id +%= 1;
                if (self.next_float_request_id == 0) self.next_float_request_id = 1;

                const trails: []const []const u8 = &.{buf[0..trail_len]};
                wire.writeControlMsgWithRequestIdTimeout(mux_fd, .float_request, float_req_id, std.mem.asBytes(&fr), trails, HANDLER_IO_TIMEOUT_MS) catch |err| {
                    core.logging.logError("ses", "float_request forward to mux failed", err);
                    self.sendBinaryError(fd, "forward_failed");
                    self.finishCliRequest(fd);
                    return;
                };
                // Keyed by the request id, so concurrent waiters coexist.
                self.pending_float_cli_fds.put(float_req_id, .{ .cli_fd = fd, .owner_ctl_fd = mux_fd }) catch |err| {
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
                    wire.readExactTimeout(fd, buf[0..hdr.payload_len], HANDLER_IO_TIMEOUT_MS) catch |err| {
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
                self.finishCliRequest(fd);
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
                wire.readExactTimeout(fd, buf[0..hdr.payload_len], HANDLER_IO_TIMEOUT_MS) catch |err| {
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
                    // A specific pane was named: resolve it or drop. Falling
                    // back to any mux injected keystrokes into a pane in a
                    // DIFFERENT session.
                    self.findMuxCtlForUuid(sk.uuid);
                if (mux_fd) |mfd| {
                    self.replyOrClose(mfd, .send_keys, buf[0..hdr.payload_len]);
                }
                self.finishCliRequest(fd);
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
                wire.readExactTimeout(fd, buf[0..hdr.payload_len], HANDLER_IO_TIMEOUT_MS) catch |err| {
                    self.ctlStreamDesynced(fd, "mid-message read failed");
                    core.logging.logError("ses", "targeted_notify payload read failed", err);
                    self.closeCliRequest(fd, "targeted_notify payload read failed");
                    return;
                };
                const tn = wire.bytesToStruct(wire.TargetedNotify, buf[0..hdr.payload_len]) orelse {
                    self.closeCliRequest(fd, "targeted_notify payload malformed");
                    return;
                };
                const tn_zero_uuid: [32]u8 = .{0} ** 32;
                const mux_fd = if (std.mem.eql(u8, &tn.uuid, &tn_zero_uuid))
                    self.findAnyMuxCtl()
                else
                    // Specific pane: resolve it or drop — never notify a
                    // different session.
                    self.findMuxCtlForUuid(tn.uuid);
                if (mux_fd) |mfd| {
                    self.replyOrClose(mfd, .targeted_notify, buf[0..hdr.payload_len]);
                }
                self.finishCliRequest(fd);
            },
            .broadcast_notify => {
                if (hdr.payload_len > buf.len) {
                    self.closeCliRequest(fd, "broadcast_notify payload too large");
                    return;
                }
                if (hdr.payload_len > 0) {
                    wire.readExactTimeout(fd, buf[0..hdr.payload_len], HANDLER_IO_TIMEOUT_MS) catch |err| {
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
                self.finishCliRequest(fd);
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
                wire.readExactTimeout(fd, buf[0..hdr.payload_len], HANDLER_IO_TIMEOUT_MS) catch |err| {
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
                    // Specific pane: resolve it or report no_mux — a popup must
                    // never appear in a session the caller did not target.
                    self.findMuxCtlForUuid(pc.uuid);
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
                wire.readExactTimeout(fd, buf[0..hdr.payload_len], HANDLER_IO_TIMEOUT_MS) catch |err| {
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
                    // Specific pane: resolve it or report no_mux (see pop_confirm).
                    self.findMuxCtlForUuid(pch.uuid);
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
                const pu = wire.readStructTimeout(wire.PaneUuid, fd, HANDLER_IO_TIMEOUT_MS) catch |err| {
                    self.ctlStreamDesynced(fd, "mid-message read failed");
                    core.logging.logError("ses", "pane_info payload read failed", err);
                    self.closeCliRequest(fd, "pane_info payload read failed");
                    return;
                };
                server_reporting_handlers.handleBinaryPaneInfo(self, fd, pu.uuid);
                self.finishCliRequest(fd);
            },
            .status => {
                // Payload is 1 byte: full_mode flag (0 or 1).
                var full_mode: bool = false;
                if (hdr.payload_len >= 1) {
                    var flag: [1]u8 = undefined;
                    wire.readExactTimeout(fd, &flag, HANDLER_IO_TIMEOUT_MS) catch |err| {
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
            .kill_target => {
                server_cli_layout_handlers.handleKillTarget(self, fd, hdr.payload_len, &buf);
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
            // `hexe ses export` and `hexe ses stats` both open with this. It was
            // only wired on the MUX CTL channel, so both commands failed at
            // their first request -- silently, with a non-zero exit and no
            // message. The handler reads no request payload, so it is
            // channel-agnostic.
            .list_sessions => {
                server_listing_handlers.handleBinaryListSessions(self, fd, &buf);
            },
            // Named MsgTypes that never arrive on the CLI-tool request channel
            // (handshake 0x04): MUX→SES binary CTL messages, responses, and POD
            // channel-④ events, all dispatched elsewhere. Enumerated explicitly
            // so a new MsgType is a compile error here until categorized
            // (PLAN.md 2.1). Behavior matches the former `else`.
            .register, .registered, .create_pane, .pane_created, .destroy_pane, .detach, .reattach, .session_state, .pop_response, .disconnect, .orphan_pane, .list_orphaned, .adopt_pane, .kill_pane, .set_sticky, .find_sticky, .update_pane_aux, .update_pane_name, .update_pane_shell, .get_pane_cwd, .ping, .pong, .ok, .@"error", .pane_found, .pane_not_found, .orphaned_panes, .sessions_list, .session_reattached, .session_detached, .exit_intent_result, .float_created, .float_result, .pane_exited, .replay_backlogs, .session_stolen, .session_add_tab, .session_remove_tab, .session_sync_float, .session_remove_float, .session_split_pane, .session_replace_split_pane, .session_set_split_ratio, .session_rename_tab, .cwd_changed, .fg_changed, .shell_event, .bell, .exited, .shp_shell_event => {
                self.skipBinaryPayload(fd, hdr.payload_len, &buf);
                self.closeCliRequest(fd, "unsupported cli request type");
            },
            _ => {
                self.skipBinaryPayload(fd, hdr.payload_len, &buf);
                self.closeCliRequest(fd, "unsupported cli request type");
            },
        }
    }

    /// Close a finished CLI request fd. Same note-then-close discipline as
    /// `closeCliRequest`, without the warn — these are success paths. The note
    /// matters because `replyOrClose`/`sendBinaryError` earlier in the arm may
    /// already have queued this fd, and the queued entry would otherwise fire
    /// later against whatever connection reused the number.
    fn finishCliRequest(self: *Server, fd: posix.fd_t) void {
        self.ses_state.store.noteClosedFd(fd);
        posix.close(fd);
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

    /// Find the MUX CTL fd that owns a given pane UUID, or null.
    ///
    /// NEVER falls back to "any connected mux". Resolving a SPECIFIC pane to an
    /// arbitrary other session is how keystrokes (send_keys), popups and
    /// notifications ended up in a session the caller never targeted — the
    /// caller must handle null (report no_mux) instead.
    fn findMuxCtlForUuid(self: *Server, uuid: [32]u8) ?posix.fd_t {
        if (self.ses_state.store.panes.get(uuid)) |pane| {
            if (pane.attached_to) |client_id| {
                if (self.ses_state.getClient(client_id)) |client| {
                    return client.mux_ctl_fd;
                }
            }
        }
        return null;
    }

    /// Resolve a float request's target mux.
    ///
    /// The CLI sends its session uuid when it has one, otherwise its PANE uuid
    /// (pane shells only ever get HEXE_PANE_UUID), so try both. Returns null
    /// rather than guessing: a float must open in the session that asked for it.
    fn resolveFloatTargetMux(self: *Server, id: [32]u8) ?posix.fd_t {
        if (self.findMuxCtlForSessionId(id)) |mux_fd| return mux_fd;
        return self.findMuxCtlForUuid(id);
    }

    /// Find the MUX CTL fd for a given session ID (32-char hex).
    ///
    /// A ZEROED id means "no session specified" (the CLI was run outside a hexe
    /// pane, so HEXE_SESSION was unset) — there, any connected mux is the
    /// intended best-effort target.
    ///
    /// But when a SPECIFIC session is named and cannot be resolved, this returns
    /// null so the caller reports no_mux. It must NEVER fall back to "any mux":
    /// that silently delivered the request to a DIFFERENT session — a float
    /// launched from one hexe session popped up inside another one. The id goes
    /// stale easily: a pane's shell inherits HEXE_SESSION at spawn, and a
    /// reattach can change the session uuid afterwards, so every long-lived
    /// shell can end up asking for a session that no longer matches.
    fn findMuxCtlForSessionId(self: *Server, session_hex: [32]u8) ?posix.fd_t {
        const zero: [32]u8 = .{0} ** 32;
        if (std.mem.eql(u8, &session_hex, &zero)) return self.findAnyMuxCtl();

        // Convert 32-char hex to 16-byte binary for comparison with client.session_id.
        const session_bin = core.uuid.hexToBin(session_hex) orelse return null;

        for (self.ses_state.store.clients.items) |client| {
            if (client.session_id) |csid| {
                if (std.mem.eql(u8, &csid, &session_bin)) {
                    if (client.mux_ctl_fd) |mux_fd| return mux_fd;
                }
            }
        }
        return null;
    }

    /// The SOLE connected MUX CTL fd, for requests that name no target.
    ///
    /// Returns null when more than one mux is connected: with several sessions
    /// open there is no correct answer, and picking the first one delivered
    /// floats/keystrokes/popups into whichever session happened to be first in
    /// the list. An untargeted request is better refused (the caller reports
    /// no_mux) than silently executed in someone else's session.
    fn findAnyMuxCtl(self: *Server) ?posix.fd_t {
        var found: ?posix.fd_t = null;
        var count: usize = 0;
        for (self.ses_state.store.clients.items) |client| {
            if (client.mux_ctl_fd) |mux_fd| {
                count += 1;
                if (found == null) found = mux_fd;
            }
        }
        if (count > 1) {
            core.logging.warn("ses", "untargeted request with {d} connected muxes: refusing to guess a session", .{count});
            return null;
        }
        return found;
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

test {
    // A test root only collects tests from files it explicitly references, so
    // the handlers split out of this file need to be pulled back in here.
    _ = @import("server_pane_lifecycle_handlers.zig");
}
