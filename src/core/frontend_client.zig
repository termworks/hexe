const std = @import("std");
const posix = std.posix;
const ipc = @import("ipc.zig");
const liblink_transport = @import("frontend_liblink_transport.zig");
const logging = @import("logging.zig");
const session_model = @import("session_model.zig");
const wire = @import("wire.zig");
const responses = @import("ses_client_responses.zig");

pub const LocalIpcTransport = struct {
    autostart_ses: bool = true,
    socket_path: ?[]const u8 = null,
};

pub const PreconnectedTransport = struct {
    ctl_fd: posix.fd_t,
    vt_fd: posix.fd_t,
};

pub const LiblinkTransport = liblink_transport.Config;

pub const Transport = union(enum) {
    local_ipc: LocalIpcTransport,
    liblink: LiblinkTransport,
    preconnected: PreconnectedTransport,
};

/// Static buffer for synchronous CWD fetch (getPaneCwdSync).
var sync_cwd_buf: [4096]u8 = undefined;

const SYNC_RESPONSE_TIMEOUT_MS: i64 = 10_000;
const REATTACH_RESPONSE_TIMEOUT_MS: i64 = 15_000;
const COMMAND_ACK_TIMEOUT_MS: i64 = 5_000;

fn deleteSocketPath(path: []const u8) void {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.deleteFileAbsolute(path) catch {};
    } else {
        std.fs.cwd().deleteFile(path) catch {};
    }
}

fn defaultCapabilityFlags(frontend_kind: wire.FrontendKind, transport_kind: wire.FrontendTransportKind) u32 {
    var flags: u32 = wire.FrontendCapabilityFlag.interactive_input | wire.FrontendCapabilityFlag.cell_render;
    switch (frontend_kind) {
        .terminal => {
            flags |= wire.FrontendCapabilityFlag.mouse |
                wire.FrontendCapabilityFlag.clipboard |
                wire.FrontendCapabilityFlag.desktop_notify;
        },
        .web => {
            flags |= wire.FrontendCapabilityFlag.pixel_render |
                wire.FrontendCapabilityFlag.mouse |
                wire.FrontendCapabilityFlag.clipboard |
                wire.FrontendCapabilityFlag.desktop_notify |
                wire.FrontendCapabilityFlag.reconnect;
        },
        .desktop => {
            flags |= wire.FrontendCapabilityFlag.pixel_render |
                wire.FrontendCapabilityFlag.mouse |
                wire.FrontendCapabilityFlag.clipboard |
                wire.FrontendCapabilityFlag.desktop_notify |
                wire.FrontendCapabilityFlag.reconnect;
        },
    }
    if (transport_kind == .liblink) {
        flags |= wire.FrontendCapabilityFlag.remote_transport | wire.FrontendCapabilityFlag.reconnect;
    }
    return flags;
}

/// Client for communicating with the ses daemon using binary protocol.
/// Opens two channels:
///   - ctl_fd (handshake 0x01): binary control messages
///   - vt_fd (handshake 0x02): multiplexed VT data (MuxVtHeader frames)
pub const SesClient = struct {
    pub const PendingCwdResponse = struct {
        uuid: [32]u8,
        cwd: []u8,
    };
    pub const PendingPaneInfoResponse = struct {
        uuid: [32]u8,
        name: ?[]u8 = null,
        fg_name: ?[]u8 = null,
        fg_pid: ?i32 = null,

        pub fn deinit(self: *PendingPaneInfoResponse, allocator: std.mem.Allocator) void {
            if (self.name) |name| allocator.free(name);
            if (self.fg_name) |fg_name| allocator.free(fg_name);
            self.* = .{ .uuid = .{0} ** 32 };
        }
    };
    pub const PendingControlResponse = struct {
        request_id: u32,
        msg_type: wire.MsgType,
        payload: []u8,

        pub fn deinit(self: *PendingControlResponse, allocator: std.mem.Allocator) void {
            allocator.free(self.payload);
            self.* = undefined;
        }
    };
    pub const ControlResponseRead = struct {
        hdr: wire.ControlHeader,
        payload: ?[]u8 = null,
        offset: usize = 0,

        pub fn deinit(self: *ControlResponseRead, allocator: std.mem.Allocator) void {
            if (self.payload) |payload| allocator.free(payload);
            self.* = undefined;
        }

        pub fn msgType(self: *const ControlResponseRead) wire.MsgType {
            return @enumFromInt(self.hdr.msg_type);
        }

        pub fn readExact(self: *ControlResponseRead, client: *SesClient, fd: posix.fd_t, dest: []u8) !void {
            if (self.payload) |payload| {
                if (self.offset + dest.len > payload.len) return error.UnexpectedResponse;
                @memcpy(dest, payload[self.offset .. self.offset + dest.len]);
                self.offset += dest.len;
                return;
            }
            try wire.readExact(fd, dest);
            _ = client;
        }

        pub fn readStruct(self: *ControlResponseRead, client: *SesClient, fd: posix.fd_t, comptime T: type) !T {
            var value: T = undefined;
            try self.readExact(client, fd, std.mem.asBytes(&value));
            return value;
        }

        pub fn skip(self: *ControlResponseRead, client: *SesClient, fd: posix.fd_t, len: usize) void {
            if (len == 0) return;
            if (self.payload) |payload| {
                self.offset = @min(payload.len, self.offset + len);
                return;
            }
            client.skipPayload(fd, @intCast(len));
        }

        pub fn skipRemaining(self: *ControlResponseRead, client: *SesClient, fd: posix.fd_t) void {
            const consumed = @min(self.offset, @as(usize, self.hdr.payload_len));
            const remaining = @as(usize, self.hdr.payload_len) - consumed;
            self.skip(client, fd, remaining);
        }
    };

    allocator: std.mem.Allocator,
    ctl_fd: ?posix.fd_t,
    vt_fd: ?posix.fd_t,
    just_started_daemon: bool,
    debug: bool,
    log_level: ?logging.Level,
    log_file: ?[]const u8,
    frontend_kind: wire.FrontendKind,
    transport: Transport,
    stale_runtime_detected: bool,
    bridge: ?*liblink_transport.Bridge = null,

    // Registration info
    session_id: [32]u8, // mux UUID as hex string
    session_name: []const u8, // Pokemon name
    base_root: []const u8, // launch/root directory for this session
    keepalive: bool,

    // Resolved session name from server (may differ if collision detected).
    // Owned by SesClient if non-null. Caller should update their state if this differs.
    resolved_name: ?[]u8 = null,

    // Pending async request tracking
    pending_cwd_responses: std.ArrayList(PendingCwdResponse),
    pending_pane_info_responses: std.ArrayList(PendingPaneInfoResponse),
    pending_pane_exits: std.ArrayList([32]u8),
    pending_control_responses: std.ArrayList(PendingControlResponse),
    pending_session_state: ?[]u8 = null,
    /// Set when a session_stolen push is consumed by a synchronous reader
    /// instead of the IPC loop; the loop drains it so the steal is never lost.
    pending_session_stolen: bool = false,
    next_ctl_request_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, session_id: [32]u8, session_name: []const u8, keepalive: bool, log_level: ?logging.Level, log_file: ?[]const u8) SesClient {
        return initLocalIpc(allocator, session_id, session_name, keepalive, log_level, log_file, .terminal);
    }

    pub fn initLocalIpc(
        allocator: std.mem.Allocator,
        session_id: [32]u8,
        session_name: []const u8,
        keepalive: bool,
        log_level: ?logging.Level,
        log_file: ?[]const u8,
        frontend_kind: wire.FrontendKind,
    ) SesClient {
        return initWithTransport(allocator, session_id, session_name, keepalive, log_level, log_file, frontend_kind, .{
            .local_ipc = .{},
        });
    }

    pub fn initWithTransport(
        allocator: std.mem.Allocator,
        session_id: [32]u8,
        session_name: []const u8,
        keepalive: bool,
        log_level: ?logging.Level,
        log_file: ?[]const u8,
        frontend_kind: wire.FrontendKind,
        transport: Transport,
    ) SesClient {
        return .{
            .allocator = allocator,
            .ctl_fd = null,
            .vt_fd = null,
            .just_started_daemon = false,
            .debug = logging.levelEnablesDebug(log_level),
            .log_level = log_level,
            .log_file = log_file,
            .frontend_kind = frontend_kind,
            .transport = transport,
            .stale_runtime_detected = false,
            .session_id = session_id,
            .session_name = session_name,
            .base_root = "",
            .keepalive = keepalive,
            .pending_cwd_responses = .empty,
            .pending_pane_info_responses = .empty,
            .pending_pane_exits = .empty,
            .pending_control_responses = .empty,
        };
    }

    pub fn deinit(self: *SesClient) void {
        if (self.ctl_fd) |fd| posix.close(fd);
        if (self.vt_fd) |fd| posix.close(fd);
        if (self.bridge) |bridge| bridge.deinit();
        if (self.resolved_name) |rn| self.allocator.free(rn);
        for (self.pending_cwd_responses.items) |resp| self.allocator.free(resp.cwd);
        self.pending_cwd_responses.deinit(self.allocator);
        for (self.pending_pane_info_responses.items) |*resp| resp.deinit(self.allocator);
        self.pending_pane_info_responses.deinit(self.allocator);
        self.pending_pane_exits.deinit(self.allocator);
        for (self.pending_control_responses.items) |*resp| resp.deinit(self.allocator);
        self.pending_control_responses.deinit(self.allocator);
        if (self.pending_session_state) |json| self.allocator.free(json);
        self.ctl_fd = null;
        self.vt_fd = null;
        self.bridge = null;
        self.resolved_name = null;
        self.pending_session_state = null;
    }

    fn debugLog(self: *const SesClient, comptime fmt: []const u8, args: anytype) void {
        if (!self.debug) return;
        logging.debugWithSource("frontend-client", fmt, args, @src());
    }

    fn debugLogUuid(self: *const SesClient, uuid: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (!self.debug) return;
        const short_uuid = if (uuid.len >= 8) uuid[0..8] else uuid;
        logging.debugWithSource("frontend-client", "[{s}] " ++ fmt, .{short_uuid} ++ args, @src());
    }

    fn traceLog(self: *const SesClient, comptime fmt: []const u8, args: anytype) void {
        if (self.log_level != .trace) return;
        logging.traceWithSource("frontend-client", fmt, args, @src());
    }

    fn traceLogUuid(self: *const SesClient, uuid: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (self.log_level != .trace) return;
        const short_uuid = if (uuid.len >= 8) uuid[0..8] else uuid;
        logging.traceWithSource("frontend-client", "[{s}] " ++ fmt, .{short_uuid} ++ args, @src());
    }

    fn transportKind(self: *const SesClient) wire.FrontendTransportKind {
        return switch (self.transport) {
            .local_ipc => .local_ipc,
            .liblink => .liblink,
            .preconnected => .preconnected,
        };
    }

    // Response store: pending sync/async response queues captured while a
    // synchronous CTL call is in flight. Bodies live in `ses_client_responses`;
    // aliased here so `client.<name>(...)` call sites are unchanged (PLAN 2.3).
    const queuePendingPaneExit = responses.queuePendingPaneExit;
    pub const drainPendingPaneExits = responses.drainPendingPaneExits;
    pub const queuePendingSessionState = responses.queuePendingSessionState;
    const queuePendingCwdResponse = responses.queuePendingCwdResponse;
    pub const drainPendingCwdResponse = responses.drainPendingCwdResponse;
    const queuePendingPaneInfoResponse = responses.queuePendingPaneInfoResponse;
    pub const drainPendingPaneInfoResponse = responses.drainPendingPaneInfoResponse;
    pub const drainPendingSessionState = responses.drainPendingSessionState;
    const queuePendingControlResponse = responses.queuePendingControlResponse;
    const takePendingControlResponse = responses.takePendingControlResponse;
    pub const takeResolvedNameOwned = responses.takeResolvedNameOwned;
    pub const drainPendingSessionStolen = responses.drainPendingSessionStolen;

    /// Reconnect hygiene: a fresh connection must not inherit fds or queued
    /// responses from a previous one. Stale queued responses can match a new
    /// request_id and attribute an old connection's reply to a new operation;
    /// stale fds simply leak.
    fn resetConnectionState(self: *SesClient) void {
        if (self.ctl_fd) |old_fd| {
            posix.close(old_fd);
            self.ctl_fd = null;
        }
        if (self.vt_fd) |old_fd| {
            posix.close(old_fd);
            self.vt_fd = null;
        }
        for (self.pending_cwd_responses.items) |resp| self.allocator.free(resp.cwd);
        self.pending_cwd_responses.clearRetainingCapacity();
        for (self.pending_pane_info_responses.items) |*resp| resp.deinit(self.allocator);
        self.pending_pane_info_responses.clearRetainingCapacity();
        self.pending_pane_exits.clearRetainingCapacity();
        for (self.pending_control_responses.items) |*resp| resp.deinit(self.allocator);
        self.pending_control_responses.clearRetainingCapacity();
        if (self.pending_session_state) |json| {
            self.allocator.free(json);
            self.pending_session_state = null;
        }
        self.pending_session_stolen = false;
    }

    /// Connect to the ses daemon, starting it if necessary.
    /// Opens CTL channel, registers, then opens VT channel.
    pub fn connect(self: *SesClient) !void {
        self.resetConnectionState();
        switch (self.transport) {
            .local_ipc => |transport| try self.connectLocalIpc(transport),
            .liblink => |transport| try self.connectLiblink(transport),
            .preconnected => |transport| try self.connectPreconnected(transport),
        }
    }

    fn allocateCtlRequestId(self: *SesClient) u32 {
        const id = self.next_ctl_request_id;
        self.next_ctl_request_id +%= 1;
        if (self.next_ctl_request_id == 0) self.next_ctl_request_id = 1;
        return id;
    }

    fn writeControlRequest(self: *SesClient, fd: posix.fd_t, msg_type: wire.MsgType, payload: []const u8) !u32 {
        const request_id = self.allocateCtlRequestId();
        try wire.writeControlWithRequestId(fd, msg_type, request_id, payload);
        return request_id;
    }

    fn writeControlTrailRequest(self: *SesClient, fd: posix.fd_t, msg_type: wire.MsgType, fixed: []const u8, trail: []const u8) !u32 {
        const request_id = self.allocateCtlRequestId();
        try wire.writeControlWithTrailAndRequestId(fd, msg_type, request_id, fixed, trail);
        return request_id;
    }

    fn writeControlMsgRequest(self: *SesClient, fd: posix.fd_t, msg_type: wire.MsgType, fixed: []const u8, trails: []const []const u8) !u32 {
        const request_id = self.allocateCtlRequestId();
        try wire.writeControlMsgWithRequestId(fd, msg_type, request_id, fixed, trails);
        return request_id;
    }

    fn connectLiblink(self: *SesClient, transport: LiblinkTransport) !void {
        self.debugLog("ses connect: transport=liblink host={s}:{d} user={s}", .{
            transport.host,
            transport.port,
            transport.user,
        });

        const result = try liblink_transport.connect(self.allocator, transport);
        errdefer result.bridge.deinit();

        try self.connectPreconnected(.{
            .ctl_fd = result.ctl_fd,
            .vt_fd = result.vt_fd,
        });
        self.bridge = result.bridge;
    }

    fn connectPreconnected(self: *SesClient, transport: PreconnectedTransport) !void {
        self.debugLog("ses connect: transport=preconnected ctl_fd={d} vt_fd={d}", .{
            transport.ctl_fd,
            transport.vt_fd,
        });
        self.traceLog("connectPreconnected: session={s} keepalive={} log_level={s}", .{
            self.session_id[0..8],
            self.keepalive,
            if (self.log_level) |level| @tagName(level) else "off",
        });

        self.ctl_fd = transport.ctl_fd;
        self.vt_fd = transport.vt_fd;
        self.just_started_daemon = false;
        errdefer {
            if (self.ctl_fd) |fd| posix.close(fd);
            if (self.vt_fd) |fd| posix.close(fd);
            self.ctl_fd = null;
            self.vt_fd = null;
        }

        try self.register();
        self.setCtlNonBlocking();

        const O_NONBLOCK: usize = 0o4000;
        const flags = posix.fcntl(transport.vt_fd, posix.F.GETFL, 0) catch |err| {
            logging.logError("frontend-client", "failed to read preconnected VT fd flags", err);
            return error.ConnectionRefused;
        };
        _ = posix.fcntl(transport.vt_fd, posix.F.SETFL, flags | O_NONBLOCK) catch |err| {
            logging.logError("frontend-client", "failed to set preconnected VT fd nonblocking", err);
            return error.ConnectionRefused;
        };
    }

    fn connectLocalIpc(self: *SesClient, transport: LocalIpcTransport) !void {
        var owned_socket_path: ?[]const u8 = null;
        defer if (owned_socket_path) |path| self.allocator.free(path);
        const socket_path = if (transport.socket_path) |path|
            path
        else blk: {
            owned_socket_path = try ipc.getSesSocketPath(self.allocator);
            break :blk owned_socket_path.?;
        };
        self.debugLog("ses connect: transport=local_ipc socket_path={s}", .{socket_path});
        self.stale_runtime_detected = false;

        // Try to connect to existing daemon first
        if (self.connectCtl(socket_path)) {
            self.debugLog("ses connect: connected to existing daemon", .{});
            self.just_started_daemon = false;
        } else {
            if (!transport.autostart_ses) {
                self.debugLog("ses connect: local_ipc autostart disabled", .{});
                return error.ConnectionRefused;
            }
            if (self.stale_runtime_detected) {
                self.debugLog("ses connect: removing stale runtime socket before daemon restart", .{});
                deleteSocketPath(socket_path);
                self.stale_runtime_detected = false;
            }
            // Daemon not running, start it
            self.debugLog("ses connect: daemon not running, starting...", .{});
            try self.startSes();
            self.just_started_daemon = true;

            // Wait for daemon to be ready
            std.Thread.sleep(200 * std.time.ns_per_ms);

            // Retry connection
            if (!self.connectCtl(socket_path)) {
                self.debugLog("ses connect: retry connection failed", .{});
                return error.ConnectionRefused;
            }
            self.debugLog("ses connect: retry succeeded", .{});
        }

        // Register on CTL channel first, so SES knows our session_id.
        self.debugLog("ses connect: registering session_id={s}", .{&self.session_id});
        try self.register();
        self.debugLog("ses connect: registration complete", .{});

        // Switch to non-blocking mode after successful registration.
        self.setCtlNonBlocking();

        // Now open VT channel — SES can match our session_id.
        if (!self.connectVt(socket_path)) {
            self.debugLog("ses connect: VT channel connection failed", .{});
            return error.ConnectionRefused;
        }
        self.debugLog("ses connect: VT channel connected, fully connected!", .{});
    }

    /// Open the control channel to SES.
    fn connectCtl(self: *SesClient, socket_path: []const u8) bool {
        const ctl_client = ipc.Client.connect(socket_path) catch |err| {
            logging.logError("frontend-client", "failed to connect SES control socket", err);
            return false;
        };
        const ctl_fd = ctl_client.fd;

        // Set socket timeouts for initial registration (prevents hanging on dead daemon).
        // This is needed because register() does blocking I/O waiting for response.
        const timeout = posix.timeval{ .sec = 5, .usec = 0 };
        posix.setsockopt(ctl_fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch |err| {
            logging.logError("frontend-client", "failed to set SES control receive timeout", err);
        };
        posix.setsockopt(ctl_fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch |err| {
            logging.logError("frontend-client", "failed to set SES control send timeout", err);
        };

        wire.sendHandshake(ctl_fd, wire.SES_HANDSHAKE_FRONTEND_CTL) catch {
            posix.close(ctl_fd);
            return false;
        };
        wire.readAndValidateServerHello(ctl_fd) catch |err| {
            self.debugLog("ses ctl runtime hello failed: {s}", .{@errorName(err)});
            self.stale_runtime_detected = true;
            posix.close(ctl_fd);
            return false;
        };
        self.ctl_fd = ctl_fd;
        self.debugLog("ses ctl connected: fd={d}", .{ctl_fd});
        return true;
    }

    /// Set non-blocking mode on CTL fd after registration succeeds.
    /// Called after register() so main loop sync calls don't block.
    fn setCtlNonBlocking(self: *SesClient) void {
        const fd = self.ctl_fd orelse return;
        const O_NONBLOCK: usize = 0o4000;
        const flags = posix.fcntl(fd, posix.F.GETFL, 0) catch |err| {
            logging.logError("frontend-client", "failed to read SES control fd flags", err);
            return;
        };
        _ = posix.fcntl(fd, posix.F.SETFL, flags | O_NONBLOCK) catch |err| {
            logging.logError("frontend-client", "failed to set SES control fd nonblocking", err);
        };
        // Clear the socket timeouts now that we're non-blocking.
        const zero_timeout = posix.timeval{ .sec = 0, .usec = 0 };
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&zero_timeout)) catch |err| {
            logging.logError("frontend-client", "failed to clear SES control receive timeout", err);
        };
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&zero_timeout)) catch |err| {
            logging.logError("frontend-client", "failed to clear SES control send timeout", err);
        };
    }

    /// Open the VT data channel to SES.
    fn connectVt(self: *SesClient, socket_path: []const u8) bool {
        const vt_client = ipc.Client.connect(socket_path) catch |err| {
            logging.logError("frontend-client", "failed to connect SES VT socket", err);
            return false;
        };
        const vt_fd = vt_client.fd;

        // Set non-blocking — the VT fd is polled in the event loop, must not block.
        const O_NONBLOCK: usize = 0o4000;
        const flags = posix.fcntl(vt_fd, posix.F.GETFL, 0) catch {
            posix.close(vt_fd);
            return false;
        };
        _ = posix.fcntl(vt_fd, posix.F.SETFL, flags | O_NONBLOCK) catch {
            posix.close(vt_fd);
            return false;
        };

        wire.sendHandshake(vt_fd, wire.SES_HANDSHAKE_FRONTEND_VT) catch {
            posix.close(vt_fd);
            return false;
        };
        // Send 32-byte hex session_id so SES can match us to the registered client.
        wire.writeAll(vt_fd, &self.session_id) catch {
            posix.close(vt_fd);
            return false;
        };
        self.vt_fd = vt_fd;
        self.debugLog("ses vt connected: fd={d}", .{vt_fd});
        return true;
    }

    /// Register with ses — send session_id, session_name, and keepalive preference.
    /// Server may return a different name if collision detected - stored in resolved_name.
    fn register(self: *SesClient) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        self.debugLog("registering frontend={s} session={s} name={s}", .{
            @tagName(self.frontend_kind),
            self.session_id[0..8],
            self.session_name,
        });

        var reg: wire.FrontendRegister = .{
            .session_id = self.session_id,
            .keepalive = if (self.keepalive) 1 else 0,
            .frontend_kind = @intFromEnum(self.frontend_kind),
            .transport_kind = @intFromEnum(self.transportKind()),
            .capability_flags = defaultCapabilityFlags(self.frontend_kind, self.transportKind()),
            .name_len = @intCast(self.session_name.len),
            .base_root_len = @intCast(@min(self.base_root.len, std.math.maxInt(u16))),
        };
        const trails: []const []const u8 = &.{ self.session_name, self.base_root[0..reg.base_root_len] };
        const request_id = try self.writeControlMsgRequest(fd, .register, std.mem.asBytes(&reg), trails);

        // Wait for registered response.
        var read = try self.readSyncResponseForRequest(fd, request_id);
        defer read.deinit(self.allocator);
        const hdr = read.hdr;
        const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (msg_type == .@"error") {
            read.skipRemaining(self, fd);
            return error.RegistrationFailed;
        }
        if (msg_type != .registered) {
            read.skipRemaining(self, fd);
            return error.UnexpectedResponse;
        }

        // Read the Registered response with resolved name
        if (hdr.payload_len >= @sizeOf(wire.FrontendRegistered)) {
            const resp = try read.readStruct(self, fd, wire.FrontendRegistered);
            const remaining = hdr.payload_len - @sizeOf(wire.FrontendRegistered);

            // Read resolved name if present
            if (resp.name_len > 0 and resp.name_len <= remaining) {
                // Free old resolved_name if any
                if (self.resolved_name) |old| {
                    self.allocator.free(old);
                    self.resolved_name = null;
                }

                const name_buf = self.allocator.alloc(u8, resp.name_len) catch {
                    read.skip(self, fd, remaining);
                    return;
                };
                read.readExact(self, fd, name_buf) catch {
                    self.allocator.free(name_buf);
                    return;
                };
                self.resolved_name = name_buf;
                self.debugLog("register: server resolved name to '{s}'", .{name_buf});

                // Skip any remaining payload
                if (remaining > resp.name_len) {
                    read.skip(self, fd, remaining - resp.name_len);
                }
            } else if (remaining > 0) {
                read.skip(self, fd, remaining);
            }
        } else if (hdr.payload_len > 0) {
            read.skipRemaining(self, fd);
        }
    }

    /// Update session info and re-register with ses (used after reattach).
    pub fn updateSession(self: *SesClient, session_id: [32]u8, session_name: []const u8) !void {
        self.session_id = session_id;
        self.session_name = session_name;
        try self.register();
    }

    /// Tell ses this mux is exiting normally, then close connections.
    pub fn shutdown(self: *SesClient, preserve_sticky: bool) !void {
        try self.shutdownWithReason(preserve_sticky, .user_exit);
    }

    /// Tell ses this frontend is exiting with an explicit reason, then close
    /// connections. Best effort: if the notify fails, local fd cleanup still
    /// happens.
    pub fn shutdownWithReason(self: *SesClient, preserve_sticky: bool, reason: wire.DisconnectReason) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.Disconnect = .{
            .mode = @intFromEnum(wire.DisconnectMode.shutdown),
            .preserve_sticky = if (preserve_sticky) 1 else 0,
            .reason = @intFromEnum(reason),
        };
        // Best-effort: don't block on a reply.
        _ = self.writeControlRequest(fd, .disconnect, std.mem.asBytes(&msg)) catch |err| {
            self.debugLog("disconnect notify write failed: {s}", .{@errorName(err)});
        };
        // Close fds after notifying
        if (self.ctl_fd) |cfd| posix.close(cfd);
        if (self.vt_fd) |vfd| posix.close(vfd);
        self.ctl_fd = null;
        self.vt_fd = null;
    }

    pub fn sessionAddTab(
        self: *SesClient,
        tab_uuid: [32]u8,
        pane_uuid: [32]u8,
        tab_index: usize,
        name: []const u8,
    ) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.SessionAddTab = .{
            .tab_uuid = tab_uuid,
            .pane_uuid = pane_uuid,
            .tab_index = @intCast(tab_index),
            .name_len = @intCast(name.len),
        };
        self.drainQueuedControlResponses(fd);
        const request_id = try self.writeControlTrailRequest(fd, .session_add_tab, std.mem.asBytes(&msg), name);
        try self.readCommandAckForRequest(fd, request_id);
    }

    pub fn sessionRemoveTab(self: *SesClient, tab_uuid: [32]u8, active_tab: ?usize) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.SessionRemoveTab = .{
            .tab_uuid = tab_uuid,
            .active_tab = @intCast(active_tab orelse 0),
            .has_active_tab = if (active_tab != null) 1 else 0,
        };
        self.drainQueuedControlResponses(fd);
        const request_id = try self.writeControlRequest(fd, .session_remove_tab, std.mem.asBytes(&msg));
        try self.readCommandAckForRequest(fd, request_id);
    }

    pub fn sessionSyncFloat(
        self: *SesClient,
        pane_uuid: [32]u8,
        active_tab: ?usize,
        parent_tab: ?usize,
        visible: bool,
        tab_visible: u64,
        sticky: bool,
        is_pwd: bool,
        float_key: u8,
        width_pct: u8,
        height_pct: u8,
        pos_x_pct: u8,
        pos_y_pct: u8,
        pad_x: u8,
        pad_y: u8,
        active: bool,
    ) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.SessionSyncFloat = .{
            .pane_uuid = pane_uuid,
            .active_tab = @intCast(active_tab orelse 0),
            .parent_tab = @intCast(parent_tab orelse 0),
            .tab_visible = tab_visible,
            .has_active_tab = if (active_tab != null) 1 else 0,
            .has_parent_tab = if (parent_tab != null) 1 else 0,
            .visible = @intFromBool(visible),
            .sticky = @intFromBool(sticky),
            .is_pwd = @intFromBool(is_pwd),
            .float_key = float_key,
            .width_pct = width_pct,
            .height_pct = height_pct,
            .pos_x_pct = pos_x_pct,
            .pos_y_pct = pos_y_pct,
            .pad_x = pad_x,
            .pad_y = pad_y,
            .active = @intFromBool(active),
        };
        self.drainQueuedControlResponses(fd);
        const request_id = try self.writeControlRequest(fd, .session_sync_float, std.mem.asBytes(&msg));
        try self.readCommandAckForRequest(fd, request_id);
    }

    pub fn sessionRemoveFloat(self: *SesClient, pane_uuid: [32]u8) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.SessionRemoveFloat = .{ .pane_uuid = pane_uuid };
        self.drainQueuedControlResponses(fd);
        const request_id = try self.writeControlRequest(fd, .session_remove_float, std.mem.asBytes(&msg));
        try self.readCommandAckForRequest(fd, request_id);
    }

    pub fn sessionSplitPane(
        self: *SesClient,
        tab_uuid: [32]u8,
        source_pane_uuid: [32]u8,
        new_pane_uuid: [32]u8,
        active_tab: usize,
        focused_pane_uuid: ?[32]u8,
        dir: session_model.SessionSplitDir,
    ) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.SessionSplitPane = .{
            .tab_uuid = tab_uuid,
            .source_pane_uuid = source_pane_uuid,
            .new_pane_uuid = new_pane_uuid,
            .focused_pane_uuid = if (focused_pane_uuid) |uuid| uuid else .{0} ** 32,
            .active_tab = @intCast(active_tab),
            .dir = switch (dir) {
                .horizontal => 0,
                .vertical => 1,
            },
            .has_focused_pane = if (focused_pane_uuid != null) 1 else 0,
        };
        self.drainQueuedControlResponses(fd);
        const request_id = try self.writeControlRequest(fd, .session_split_pane, std.mem.asBytes(&msg));
        try self.readCommandAckForRequest(fd, request_id);
    }

    pub fn sessionReplaceSplitPane(
        self: *SesClient,
        tab_uuid: [32]u8,
        old_pane_uuid: [32]u8,
        new_pane_uuid: [32]u8,
        active_tab: usize,
        focused_pane_uuid: ?[32]u8,
    ) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.SessionReplaceSplitPane = .{
            .tab_uuid = tab_uuid,
            .old_pane_uuid = old_pane_uuid,
            .new_pane_uuid = new_pane_uuid,
            .focused_pane_uuid = if (focused_pane_uuid) |uuid| uuid else .{0} ** 32,
            .active_tab = @intCast(active_tab),
            .has_focused_pane = if (focused_pane_uuid != null) 1 else 0,
        };
        self.drainQueuedControlResponses(fd);
        const request_id = try self.writeControlRequest(fd, .session_replace_split_pane, std.mem.asBytes(&msg));
        try self.readCommandAckForRequest(fd, request_id);
    }

    pub fn sessionSetSplitRatio(
        self: *SesClient,
        tab_uuid: [32]u8,
        active_tab: usize,
        first_anchor_uuid: [32]u8,
        second_anchor_uuid: [32]u8,
        ratio: f32,
    ) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.SessionSetSplitRatio = .{
            .tab_uuid = tab_uuid,
            .first_anchor_uuid = first_anchor_uuid,
            .second_anchor_uuid = second_anchor_uuid,
            .active_tab = @intCast(active_tab),
            .ratio = ratio,
        };
        self.drainQueuedControlResponses(fd);
        const request_id = try self.writeControlRequest(fd, .session_set_split_ratio, std.mem.asBytes(&msg));
        try self.readCommandAckForRequest(fd, request_id);
    }

    /// Create a new pane via ses.
    /// Returns the pane UUID, pane_id (for VT routing), and pod PID.
    /// If inherit_env_parent_uuid is set, SES will read environment from that pane's process
    /// and pass it to the new pod.
    pub fn createPane(
        self: *SesClient,
        shell: ?[]const u8,
        cwd: ?[]const u8,
        sticky_pwd: ?[]const u8,
        sticky_key: ?u8,
        env: ?[]const []const u8,
        isolation_profile: ?[]const u8,
        inherit_env_parent_uuid: ?[32]u8,
    ) !struct { uuid: [32]u8, pane_id: u16, pid: posix.pid_t } {
        const fd = self.ctl_fd orelse return error.NotConnected;

        const shell_bytes = shell orelse "";
        const cwd_bytes = cwd orelse "";
        const sticky_pwd_bytes = sticky_pwd orelse "";
        const isolation_profile_bytes = isolation_profile orelse "";
        const parent_uuid_bytes: []const u8 = if (inherit_env_parent_uuid) |*u| u[0..] else "";
        const env_items = env orelse &.{};

        var trail: std.ArrayList(u8) = .empty;
        defer trail.deinit(self.allocator);
        var tw = trail.writer(self.allocator);
        try tw.writeAll(shell_bytes);
        try tw.writeAll(cwd_bytes);
        try tw.writeAll(sticky_pwd_bytes);
        try tw.writeAll(isolation_profile_bytes);
        try tw.writeAll(parent_uuid_bytes);
        for (env_items) |entry| {
            const entry_len: u16 = @intCast(entry.len);
            try tw.writeAll(std.mem.asBytes(&entry_len));
            try tw.writeAll(entry);
        }

        var msg: wire.CreatePane = .{
            .shell_len = @intCast(shell_bytes.len),
            .cwd_len = @intCast(cwd_bytes.len),
            .sticky_key = sticky_key orelse 0,
            .sticky_pwd_len = @intCast(sticky_pwd_bytes.len),
            .isolation_profile_len = @intCast(isolation_profile_bytes.len),
            .inherit_env_parent_uuid_len = @intCast(parent_uuid_bytes.len),
            .env_count = @intCast(env_items.len),
        };
        self.debugLog("createPane: shell={s} cwd={s} isolation={s}", .{ shell_bytes, cwd_bytes, isolation_profile_bytes });
        const request_id = try self.writeControlTrailRequest(fd, .create_pane, std.mem.asBytes(&msg), trail.items);

        // Read response.
        var read = try self.readSyncResponseForRequest(fd, request_id);
        defer read.deinit(self.allocator);
        const hdr = read.hdr;
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type == .@"error") {
            read.skipRemaining(self, fd);
            return error.SesError;
        }
        if (resp_type != .pane_created) {
            read.skipRemaining(self, fd);
            return error.UnexpectedResponse;
        }

        const resp = try read.readStruct(self, fd, wire.PaneCreated);
        // Skip socket_path (we don't need it — VT goes through SES).
        if (resp.socket_path_len > 0) {
            read.skip(self, fd, resp.socket_path_len);
        }

        self.debugLog("pane created: uuid={s} pane_id={d} pid={d}", .{ resp.uuid[0..8], resp.pane_id, resp.pid });
        return .{
            .uuid = resp.uuid,
            .pane_id = resp.pane_id,
            .pid = resp.pid,
        };
    }

    /// Find a sticky pane (for pwd floats). With `claim_free` set, SES only
    /// returns (and attaches) the pane when no live client owns it and it is
    /// not parked in a detached session — a safe, non-stealing lookup for
    /// speculative reconciliation. With it unset, SES performs the full
    /// user-driven handoff (steal from live owner / unpark from detached).
    pub fn findStickyPane(self: *SesClient, pwd: []const u8, key: u8, claim_free: bool) !?struct { uuid: [32]u8, pane_id: u16, pid: posix.pid_t } {
        const fd = self.ctl_fd orelse return error.NotConnected;

        var msg: wire.FindSticky = .{
            .key = key,
            .claim_free = if (claim_free) 1 else 0,
            .pwd_len = @intCast(pwd.len),
        };
        const request_id = try self.writeControlTrailRequest(fd, .find_sticky, std.mem.asBytes(&msg), pwd);

        var read = try self.readSyncResponseForRequest(fd, request_id);
        defer read.deinit(self.allocator);
        const hdr = read.hdr;
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type == .pane_not_found) {
            read.skipRemaining(self, fd);
            return null;
        }
        if (resp_type != .pane_found) {
            read.skipRemaining(self, fd);
            return error.UnexpectedResponse;
        }

        const resp = try read.readStruct(self, fd, wire.PaneFound);
        // Skip socket_path.
        if (resp.socket_path_len > 0) {
            read.skip(self, fd, resp.socket_path_len);
        }

        return .{ .uuid = resp.uuid, .pane_id = resp.pane_id, .pid = resp.pid };
    }

    /// Orphan a pane (manual suspend).
    pub fn orphanPane(self: *SesClient, uuid: [32]u8) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        self.drainQueuedControlResponses(fd);
        var msg: wire.PaneUuid = .{ .uuid = uuid };
        const request_id = try self.writeControlRequest(fd, .orphan_pane, std.mem.asBytes(&msg));
        try self.readCommandAckForRequest(fd, request_id);
    }

    /// Set sticky info on a pane.
    pub fn setSticky(self: *SesClient, uuid: [32]u8, pwd: []const u8, key: u8) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.SetSticky = .{
            .uuid = uuid,
            .key = key,
            .pwd_len = @intCast(pwd.len),
        };
        self.drainQueuedControlResponses(fd);
        const request_id = try self.writeControlTrailRequest(fd, .set_sticky, std.mem.asBytes(&msg), pwd);
        try self.readCommandAckForRequest(fd, request_id);
    }

    /// Kill a pane.
    pub fn killPane(self: *SesClient, uuid: [32]u8) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        self.debugLogUuid(&uuid, "killPane: sending to SES ctl_fd={d} vt_fd={?d}", .{ fd, self.vt_fd });
        self.drainQueuedControlResponses(fd);
        var msg: wire.PaneUuid = .{ .uuid = uuid };
        const request_id = try self.writeControlRequest(fd, .kill_pane, std.mem.asBytes(&msg));
        try self.readCommandAckForRequest(fd, request_id);
        self.debugLogUuid(&uuid, "killPane: acknowledged by SES", .{});
    }

    /// Request pane CWD from ses (fire-and-forget; response handled in handleSesMessage).
    pub fn requestPaneCwd(self: *SesClient, uuid: [32]u8) void {
        const fd = self.ctl_fd orelse return;
        var msg: wire.GetPaneCwd = .{ .uuid = uuid };
        _ = self.writeControlRequest(fd, .get_pane_cwd, std.mem.asBytes(&msg)) catch |err| {
            logging.logError("frontend-client", "failed to request pane cwd", err);
            if (self.ctl_fd == fd) self.ctl_fd = null;
        };
    }

    /// Synchronous CWD fetch — blocks until SES responds.
    /// Returns a slice into a static buffer (valid until next call).
    pub fn getPaneCwdSync(self: *SesClient, uuid: [32]u8) ?[]const u8 {
        const fd = self.ctl_fd orelse return null;
        var msg: wire.GetPaneCwd = .{ .uuid = uuid };
        const request_id = self.writeControlRequest(fd, .get_pane_cwd, std.mem.asBytes(&msg)) catch |err| {
            logging.logError("frontend-client", "failed to request sync pane cwd", err);
            if (self.ctl_fd == fd) self.ctl_fd = null;
            return null;
        };

        var resp = self.readExpectedPaneCwdResponse(fd, uuid, request_id) catch |err| {
            logging.logError("frontend-client", "failed to read sync pane cwd response", err);
            return null;
        };
        defer resp.deinit(self.allocator);
        if (resp.cwd.len == 0) return null;
        if (resp.cwd.len > sync_cwd_buf.len) {
            return null;
        }
        @memcpy(sync_cwd_buf[0..resp.cwd.len], resp.cwd);
        return sync_cwd_buf[0..resp.cwd.len];
    }

    /// Ping ses to check if it's alive.
    pub fn ping(self: *SesClient) !bool {
        const fd = self.ctl_fd orelse return false;
        const request_id = try self.writeControlRequest(fd, .ping, &.{});

        var read = self.readSyncResponseForRequest(fd, request_id) catch |err| {
            logging.logError("frontend-client", "failed to read ping response", err);
            if (self.ctl_fd == fd) self.ctl_fd = null;
            return false;
        };
        defer read.deinit(self.allocator);
        const hdr = read.hdr;
        read.skipRemaining(self, fd);
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        return resp_type == .pong;
    }

    /// Update pane name in ses and consume its acknowledgement.
    pub fn updatePaneName(self: *SesClient, uuid: [32]u8, name: ?[]const u8) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        const name_bytes = name orelse "";
        var msg: wire.UpdatePaneName = .{
            .uuid = uuid,
            .name_len = @intCast(name_bytes.len),
        };
        self.drainQueuedControlResponses(fd);
        const request_id = try self.writeControlTrailRequest(fd, .update_pane_name, std.mem.asBytes(&msg), name_bytes);
        try self.readCommandAckForRequest(fd, request_id);
    }

    /// Rename a tab in the canonical session snapshot (MUX → SES).
    pub fn sessionRenameTab(self: *SesClient, tab_uuid: [32]u8, name: []const u8) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.SessionRenameTab = .{
            .tab_uuid = tab_uuid,
            .name_len = @intCast(name.len),
        };
        self.drainQueuedControlResponses(fd);
        const request_id = try self.writeControlTrailRequest(fd, .session_rename_tab, std.mem.asBytes(&msg), name);
        try self.readCommandAckForRequest(fd, request_id);
    }

    /// Update shell-provided pane metadata and consume its acknowledgement.
    pub fn updatePaneShell(self: *SesClient, uuid: [32]u8, cmd: ?[]const u8, cwd: ?[]const u8, status: ?i32, duration_ms: ?u64, jobs: ?u16) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        const cmd_bytes = cmd orelse "";
        const cwd_bytes = cwd orelse "";
        var msg: wire.UpdatePaneShell = .{
            .uuid = uuid,
            .status = status orelse 0,
            .has_status = if (status != null) 1 else 0,
            .duration_ms = if (duration_ms) |d| @intCast(d) else 0,
            .has_duration = if (duration_ms != null) 1 else 0,
            .jobs = jobs orelse 0,
            .has_jobs = if (jobs != null) 1 else 0,
            .cmd_len = @intCast(cmd_bytes.len),
            .cwd_len = @intCast(cwd_bytes.len),
        };
        const trails: []const []const u8 = &.{ cmd_bytes, cwd_bytes };
        self.drainQueuedControlResponses(fd);
        const request_id = try self.writeControlMsgRequest(fd, .update_pane_shell, std.mem.asBytes(&msg), trails);
        try self.readCommandAckForRequest(fd, request_id);
    }

    /// Pane type enum for auxiliary info.
    pub const PaneType = enum { split, float };
    pub const PaneAuxInfo = struct { created_from: ?[32]u8, focused_from: ?[32]u8 };
    pub const PaneInfoSnapshot = struct {
        pane_id: ?u16,
        pid: ?i32,
        name: ?[]u8,
        cwd: ?[]u8,
        sticky_pwd: ?[]u8,
        fg_name: ?[]u8,
        fg_pid: ?i32,
    };
    pub const PaneProcessInfo = struct { name: ?[]u8 = null, pid: ?i32 = null };
    const PaneInfoRead = struct {
        hdr: wire.ControlHeader,
        resp: wire.PaneInfoResp,
        trail: ?[]u8 = null,
        offset: usize = 0,

        fn deinit(self: *PaneInfoRead, allocator: std.mem.Allocator) void {
            if (self.trail) |trail| allocator.free(trail);
            self.* = undefined;
        }

        fn readExact(self: *PaneInfoRead, client: *SesClient, fd: posix.fd_t, dest: []u8) !void {
            if (self.trail) |trail| {
                if (self.offset + dest.len > trail.len) return error.EndOfStream;
                @memcpy(dest, trail[self.offset .. self.offset + dest.len]);
                self.offset += dest.len;
                return;
            }
            try wire.readExact(fd, dest);
            self.offset += dest.len;
            _ = client;
        }

        fn skip(self: *PaneInfoRead, client: *SesClient, fd: posix.fd_t, len: usize) void {
            if (len == 0) return;
            if (self.trail) |trail| {
                self.offset = @min(trail.len, self.offset + len);
                return;
            }
            client.skipPayload(fd, @intCast(len));
            self.offset += len;
        }
    };
    const PaneCwdRead = struct {
        uuid: [32]u8,
        cwd: []const u8,

        fn deinit(self: *PaneCwdRead, allocator: std.mem.Allocator) void {
            if (self.cwd.len > 0) allocator.free(self.cwd);
            self.* = undefined;
        }
    };

    /// Update auxiliary pane info (synced from mux to ses).
    /// Sends created_from, focused_from, and is_focused to SES.
    pub fn updatePaneAux(
        self: *SesClient,
        uuid: [32]u8,
        active_tab: ?usize,
        _: bool, // is_floating (not used)
        is_focused: bool,
        _: PaneType, // pane_type (not used)
        created_from: ?[32]u8,
        focused_from: ?[32]u8,
        _: ?struct { x: u16, y: u16 }, // cursor (not used)
        _: ?u8, // cursor_style (not used)
        _: ?bool, // cursor_visible (not used)
        _: ?bool, // alt_screen (not used)
        _: ?struct { cols: u16, rows: u16 }, // size (not used)
        _: ?[]const u8, // cwd (not used)
        _: ?[]const u8, // fg_process (not used)
        _: ?posix.pid_t, // fg_pid (not used)
        _: ?[]const u8, // layout_path (not used)
    ) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.UpdatePaneAux = .{
            .uuid = uuid,
            .created_from = if (created_from) |cf| cf else .{0} ** 32,
            .focused_from = if (focused_from) |ff| ff else .{0} ** 32,
            .active_tab = @intCast(active_tab orelse 0),
            .has_created_from = if (created_from != null) 1 else 0,
            .has_focused_from = if (focused_from != null) 1 else 0,
            .has_active_tab = if (active_tab != null) 1 else 0,
            .is_focused = if (is_focused) 1 else 0,
        };
        self.drainQueuedControlResponses(fd);
        const request_id = try self.writeControlRequest(fd, .update_pane_aux, std.mem.asBytes(&msg));
        try self.readCommandAckForRequest(fd, request_id);
    }

    /// Get auxiliary pane info — queries SES for created_from/focused_from.
    pub fn getPaneAux(self: *SesClient, uuid: [32]u8) !PaneAuxInfo {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.PaneUuid = .{ .uuid = uuid };
        const request_id = self.writeControlRequest(fd, .pane_info, std.mem.asBytes(&msg)) catch |err| {
            logging.logError("frontend-client", "failed to request pane aux", err);
            if (self.ctl_fd == fd) self.ctl_fd = null;
            return error.WriteFailed;
        };

        var read = self.readExpectedPaneInfoResponse(fd, uuid, request_id) catch |err| {
            logging.logError("frontend-client", "failed to read pane aux response", err);
            return err;
        };
        defer read.deinit(self.allocator);
        const hdr = read.hdr;
        const resp = read.resp;
        // Skip trailing data.
        const trail_len = hdr.payload_len - @sizeOf(wire.PaneInfoResp);
        if (trail_len > 0) read.skip(self, fd, trail_len);

        return .{
            .created_from = if (resp.has_created_from != 0) resp.created_from else null,
            .focused_from = if (resp.has_focused_from != 0) resp.focused_from else null,
        };
    }

    /// Request foreground process info for a pane (fire-and-forget; response handled in handleSesMessage).
    pub fn requestPaneProcess(self: *SesClient, uuid: [32]u8) void {
        const fd = self.ctl_fd orelse return;
        var msg: wire.PaneUuid = .{ .uuid = uuid };
        _ = self.writeControlRequest(fd, .pane_info, std.mem.asBytes(&msg)) catch |err| {
            logging.logError("frontend-client", "failed to request pane process info", err);
            if (self.ctl_fd == fd) self.ctl_fd = null;
        };
    }

    /// Best-effort pane name (sync call, queues unrelated async responses).
    pub fn getPaneName(self: *SesClient, uuid: [32]u8) ?[]u8 {
        const fd = self.ctl_fd orelse return null;
        var msg: wire.PaneUuid = .{ .uuid = uuid };
        const request_id = self.writeControlRequest(fd, .pane_info, std.mem.asBytes(&msg)) catch |err| {
            logging.logError("frontend-client", "failed to request pane name", err);
            if (self.ctl_fd == fd) self.ctl_fd = null;
            return null;
        };

        var read = self.readExpectedPaneInfoResponse(fd, uuid, request_id) catch |err| {
            logging.logError("frontend-client", "failed to read pane name response", err);
            return null;
        };
        defer read.deinit(self.allocator);
        const resp = read.resp;
        var result: ?[]u8 = null;

        // Calculate total trailing bytes.
        const trail_total: usize = @as(usize, resp.name_len) + @as(usize, resp.fg_len) +
            @as(usize, resp.cwd_len) + @as(usize, resp.tty_len) +
            @as(usize, resp.socket_path_len) + @as(usize, resp.session_name_len) +
            @as(usize, resp.layout_path_len) + @as(usize, resp.last_cmd_len) +
            @as(usize, resp.base_process_len) + @as(usize, resp.sticky_pwd_len);

        if (resp.name_len > 0) {
            const buf = self.allocator.alloc(u8, resp.name_len) catch {
                self.skipPayload(fd, @intCast(trail_total));
                return null;
            };
            read.readExact(self, fd, buf) catch |err| {
                logging.logError("frontend-client", "failed to read pane name payload", err);
                if (self.ctl_fd == fd) self.ctl_fd = null;
                self.allocator.free(buf);
                return null;
            };
            result = buf;
        }
        // Skip all remaining trailing bytes.
        const remaining = trail_total - @as(usize, resp.name_len);
        if (remaining > 0) {
            read.skip(self, fd, remaining);
        }
        return result;
    }

    /// Best-effort synchronous pane metadata snapshot.
    /// Returns owned strings that caller must free.
    pub const PaneExistence = enum { exists, missing, unknown };

    pub const PaneExistenceProbe = struct {
        outcome: PaneExistence,
        pid: ?posix.pid_t = null,
    };

    /// Tri-state existence probe. `missing` is returned only when SES
    /// definitively replied pane_not_found; every transport/protocol failure
    /// is `unknown`, so callers can avoid destroying local state on a
    /// transient hiccup.
    pub fn probePaneExistence(self: *SesClient, uuid: [32]u8) PaneExistenceProbe {
        const fd = self.ctl_fd orelse return .{ .outcome = .unknown };
        var msg: wire.PaneUuid = .{ .uuid = uuid };
        const request_id = self.writeControlRequest(fd, .pane_info, std.mem.asBytes(&msg)) catch |err| {
            logging.logError("frontend-client", "failed to send pane existence probe", err);
            if (self.ctl_fd == fd) self.ctl_fd = null;
            return .{ .outcome = .unknown };
        };

        var read = self.readExpectedPaneInfoResponse(fd, uuid, request_id) catch |err| {
            if (err == error.PaneMissing) return .{ .outcome = .missing };
            logging.logError("frontend-client", "pane existence probe failed", err);
            return .{ .outcome = .unknown };
        };
        const resp = read.resp;
        const trail_total: usize = @as(usize, resp.name_len) + @as(usize, resp.fg_len) +
            @as(usize, resp.cwd_len) + @as(usize, resp.tty_len) +
            @as(usize, resp.socket_path_len) + @as(usize, resp.session_name_len) +
            @as(usize, resp.layout_path_len) + @as(usize, resp.last_cmd_len) +
            @as(usize, resp.base_process_len) + @as(usize, resp.sticky_pwd_len);
        read.skip(self, fd, trail_total);
        read.deinit(self.allocator);
        return .{ .outcome = .exists, .pid = resp.pid };
    }

    pub fn getPaneInfoSnapshot(self: *SesClient, uuid: [32]u8) ?PaneInfoSnapshot {
        const fd = self.ctl_fd orelse return null;
        var msg: wire.PaneUuid = .{ .uuid = uuid };
        const request_id = self.writeControlRequest(fd, .pane_info, std.mem.asBytes(&msg)) catch |err| {
            logging.logError("frontend-client", "failed to request pane info snapshot", err);
            if (self.ctl_fd == fd) self.ctl_fd = null;
            return null;
        };

        // Read response directly — do NOT use readSyncResponse which skips
        // large pane_info responses (treating them as async noise).
        var read = self.readExpectedPaneInfoResponse(fd, uuid, request_id) catch |err| {
            logging.logError("frontend-client", "failed to read pane info snapshot response", err);
            return null;
        };
        defer read.deinit(self.allocator);
        const resp = read.resp;
        const trail_total: usize = @as(usize, resp.name_len) + @as(usize, resp.fg_len) +
            @as(usize, resp.cwd_len) + @as(usize, resp.tty_len) +
            @as(usize, resp.socket_path_len) + @as(usize, resp.session_name_len) +
            @as(usize, resp.layout_path_len) + @as(usize, resp.last_cmd_len) +
            @as(usize, resp.base_process_len) + @as(usize, resp.sticky_pwd_len);

        var consumed: usize = 0;
        var name: ?[]u8 = null;
        var fg_name: ?[]u8 = null;
        var cwd: ?[]u8 = null;
        var sticky_pwd: ?[]u8 = null;

        if (resp.name_len > 0) {
            const n = @as(usize, resp.name_len);
            if (n <= 16 * 1024) {
                const buf = self.allocator.alloc(u8, n) catch |err| {
                    logging.logError("frontend-client", "failed to allocate pane info name", err);
                    read.skip(self, fd, trail_total - consumed);
                    return null;
                };
                read.readExact(self, fd, buf) catch |err| {
                    logging.logError("frontend-client", "failed to read pane info name payload", err);
                    if (self.ctl_fd == fd) self.ctl_fd = null;
                    self.allocator.free(buf);
                    return null;
                };
                name = buf;
            } else {
                read.skip(self, fd, n);
            }
            consumed += n;
        }

        if (resp.fg_len > 0) {
            const n = @as(usize, resp.fg_len);
            if (n <= 16 * 1024) {
                const buf = self.allocator.alloc(u8, n) catch |err| {
                    logging.logError("frontend-client", "failed to allocate pane info foreground", err);
                    read.skip(self, fd, trail_total - consumed);
                    if (name) |s| self.allocator.free(s);
                    return null;
                };
                read.readExact(self, fd, buf) catch |err| {
                    logging.logError("frontend-client", "failed to read pane info foreground payload", err);
                    if (self.ctl_fd == fd) self.ctl_fd = null;
                    self.allocator.free(buf);
                    if (name) |s| self.allocator.free(s);
                    return null;
                };
                fg_name = buf;
            } else {
                read.skip(self, fd, n);
            }
            consumed += n;
        }

        if (resp.cwd_len > 0) {
            const n = @as(usize, resp.cwd_len);
            if (n <= 64 * 1024) {
                const buf = self.allocator.alloc(u8, n) catch |err| {
                    logging.logError("frontend-client", "failed to allocate pane info cwd", err);
                    read.skip(self, fd, trail_total - consumed);
                    if (name) |s| self.allocator.free(s);
                    if (fg_name) |s| self.allocator.free(s);
                    return null;
                };
                read.readExact(self, fd, buf) catch |err| {
                    logging.logError("frontend-client", "failed to read pane info cwd payload", err);
                    if (self.ctl_fd == fd) self.ctl_fd = null;
                    self.allocator.free(buf);
                    if (name) |s| self.allocator.free(s);
                    if (fg_name) |s| self.allocator.free(s);
                    return null;
                };
                cwd = buf;
            } else {
                read.skip(self, fd, n);
            }
            consumed += n;
        }

        const before_sticky_len: usize = @as(usize, resp.tty_len) + @as(usize, resp.socket_path_len) +
            @as(usize, resp.session_name_len) + @as(usize, resp.layout_path_len) +
            @as(usize, resp.last_cmd_len) + @as(usize, resp.base_process_len);
        if (before_sticky_len > 0) {
            read.skip(self, fd, before_sticky_len);
            consumed += before_sticky_len;
        }

        if (resp.sticky_pwd_len > 0) {
            const n = @as(usize, resp.sticky_pwd_len);
            if (n <= 64 * 1024) {
                const buf = self.allocator.alloc(u8, n) catch |err| {
                    logging.logError("frontend-client", "failed to allocate pane info sticky pwd", err);
                    read.skip(self, fd, trail_total - consumed);
                    if (name) |s| self.allocator.free(s);
                    if (fg_name) |s| self.allocator.free(s);
                    if (cwd) |s| self.allocator.free(s);
                    return null;
                };
                read.readExact(self, fd, buf) catch |err| {
                    logging.logError("frontend-client", "failed to read pane info sticky pwd payload", err);
                    if (self.ctl_fd == fd) self.ctl_fd = null;
                    self.allocator.free(buf);
                    if (name) |s| self.allocator.free(s);
                    if (fg_name) |s| self.allocator.free(s);
                    if (cwd) |s| self.allocator.free(s);
                    return null;
                };
                sticky_pwd = buf;
            } else {
                read.skip(self, fd, n);
            }
            consumed += n;
        }

        const remaining = trail_total -| consumed;
        if (remaining > 0) read.skip(self, fd, remaining);

        return .{
            .pane_id = resp.pane_id,
            .pid = if (resp.pid != 0) resp.pid else null,
            .name = name,
            .cwd = cwd,
            .sticky_pwd = sticky_pwd,
            .fg_name = fg_name,
            .fg_pid = if (resp.fg_pid != 0) resp.fg_pid else null,
        };
    }

    /// Adopt an orphaned pane.
    pub fn adoptPane(self: *SesClient, uuid: [32]u8) !struct { uuid: [32]u8, pane_id: u16, pid: posix.pid_t } {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.PaneUuid = .{ .uuid = uuid };
        const request_id = try self.writeControlRequest(fd, .adopt_pane, std.mem.asBytes(&msg));

        var read = try self.readSyncResponseForRequest(fd, request_id);
        defer read.deinit(self.allocator);
        const hdr = read.hdr;
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type == .@"error") {
            read.skipRemaining(self, fd);
            return error.SesError;
        }
        if (resp_type != .pane_found) {
            read.skipRemaining(self, fd);
            return error.UnexpectedResponse;
        }

        const resp = try read.readStruct(self, fd, wire.PaneFound);
        if (resp.socket_path_len > 0) {
            read.skip(self, fd, resp.socket_path_len);
        }
        return .{ .uuid = uuid, .pane_id = resp.pane_id, .pid = resp.pid };
    }

    /// List orphaned panes.
    pub fn listOrphanedPanes(self: *SesClient, out_buf: []OrphanedPaneInfo) !usize {
        const fd = self.ctl_fd orelse return error.NotConnected;
        const request_id = try self.writeControlRequest(fd, .list_orphaned, &.{});

        var read = try self.readSyncResponseForRequest(fd, request_id);
        defer read.deinit(self.allocator);
        const hdr = read.hdr;
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type != .orphaned_panes) {
            read.skipRemaining(self, fd);
            return error.UnexpectedResponse;
        }

        const resp = try read.readStruct(self, fd, wire.OrphanedPanes);
        var count: usize = 0;
        for (0..resp.pane_count) |_| {
            const entry = read.readStruct(self, fd, wire.OrphanedPaneEntry) catch |err| {
                logging.logError("frontend-client", "failed to read orphaned pane entry", err);
                if (self.ctl_fd == fd) self.ctl_fd = null;
                return err;
            };
            var name_buf: [64]u8 = .{0} ** 64;
            const copy_len = @min(@as(usize, entry.name_len), name_buf.len);
            if (copy_len > 0) {
                read.readExact(self, fd, name_buf[0..copy_len]) catch |err| {
                    logging.logError("frontend-client", "failed to read orphaned pane name", err);
                    if (self.ctl_fd == fd) self.ctl_fd = null;
                    return err;
                };
            }
            if (@as(usize, entry.name_len) > copy_len) {
                read.skip(self, fd, entry.name_len - @as(u16, @intCast(copy_len)));
            }
            if (count < out_buf.len) {
                out_buf[count] = .{
                    .uuid = entry.uuid,
                    .pid = entry.pid,
                    .name = name_buf,
                    .name_len = copy_len,
                };
                count += 1;
            }
        }
        return count;
    }

    /// Detach session — keeps panes grouped for later reattach.
    pub fn detachSession(self: *SesClient, session_id: [32]u8) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;

        const msg: wire.Detach = .{
            .session_id = session_id,
        };
        const request_id = try self.writeControlRequest(fd, .detach, std.mem.asBytes(&msg));

        var read = try self.readSyncResponseForRequest(fd, request_id);
        defer read.deinit(self.allocator);
        const hdr = read.hdr;
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type == .@"error") {
            read.skipRemaining(self, fd);
            return error.DetachFailed;
        }
        read.skipRemaining(self, fd);
    }

    /// Result of reattaching a session.
    pub const ReattachResult = struct {
        session_state_json: []const u8, // Owned — caller must free
        pane_uuids: [][32]u8, // Owned — caller must free
    };

    /// Reattach to a detached session.
    pub fn reattachSession(self: *SesClient, session_id: []const u8) !?ReattachResult {
        const fd = self.ctl_fd orelse {
            self.debugLog("reattachSession: not connected (ctl_fd is null)", .{});
            return error.NotConnected;
        };

        self.debugLog("reattachSession: sending reattach request for id={s} len={d}", .{ session_id, session_id.len });

        var msg: wire.Reattach = .{
            .id_len = @intCast(session_id.len),
        };
        const request_id = self.writeControlTrailRequest(fd, .reattach, std.mem.asBytes(&msg), session_id) catch |e| {
            self.debugLog("reattachSession: writeControlWithTrail failed: {s}", .{@errorName(e)});
            return e;
        };

        // Reattach can trigger SES to start backlog replaying pods almost
        // immediately. During that time SES may also send async `.ok` acks.
        // If we block waiting for `.session_reattached` while those acks pile
        // up, we risk a read deadlock (user-visible as a frozen shell).
        //
        // We explicitly queue async `.ok`/`.get_pane_cwd`/`.pane_info`
        // replies here instead of dropping them.
        self.debugLog("reattachSession: waiting for response...", .{});
        const deadline_ms = std.time.milliTimestamp() + REATTACH_RESPONSE_TIMEOUT_MS;
        var read = blk: {
            while (true) {
                var h = self.readSyncResponseUntilForRequest(fd, request_id, deadline_ms, "reattachSession") catch |e| {
                    self.debugLog("reattachSession: readSyncResponse failed: {s}", .{@errorName(e)});
                    return e;
                };
                const mt = h.msgType();
                self.debugLog("reattachSession: got msg_type={d} payload_len={d}", .{ h.hdr.msg_type, h.hdr.payload_len });
                if (mt == .ok or mt == .get_pane_cwd or mt == .pane_info or mt == .pane_exited or mt == .session_state) {
                    if (h.payload != null) {
                        h.deinit(self.allocator);
                    } else {
                        self.consumeQueuedControlResponse(fd, h.hdr);
                    }
                    continue;
                }
                break :blk h;
            }
        };
        defer read.deinit(self.allocator);
        const hdr = read.hdr;
        const resp_type = read.msgType();
        self.debugLog("reattachSession: final response type={d}", .{hdr.msg_type});
        if (resp_type == .@"error") {
            self.debugLog("reattachSession: server returned error", .{});
            read.skipRemaining(self, fd);
            return null;
        }
        if (resp_type != .session_reattached) {
            self.debugLog("reattachSession: unexpected response type {d}, expected session_reattached", .{hdr.msg_type});
            read.skipRemaining(self, fd);
            return error.UnexpectedResponse;
        }

        const resp = read.readStruct(self, fd, wire.SessionReattached) catch |e| {
            self.debugLog("reattachSession: failed to read SessionReattached struct: {s}", .{@errorName(e)});
            return e;
        };
        self.debugLog("reattachSession: got SessionReattached state_len={d} pane_count={d}", .{ resp.state_len, resp.pane_count });

        // Read canonical session snapshot JSON.
        const session_state = self.allocator.alloc(u8, resp.state_len) catch |err| {
            logging.logError("frontend-client", "failed to allocate reattach session state", err);
            return error.OutOfMemory;
        };
        errdefer self.allocator.free(session_state);
        read.readExact(self, fd, session_state) catch |e| {
            self.debugLog("reattachSession: failed to read session_state_json: {s}", .{@errorName(e)});
            return e;
        };
        self.debugLog("reattachSession: read session_state_json ({d} bytes)", .{session_state.len});

        // Read pane UUIDs (each 32 bytes).
        var pane_uuids = self.allocator.alloc([32]u8, resp.pane_count) catch |err| {
            logging.logError("frontend-client", "failed to allocate reattach pane UUID list", err);
            return error.OutOfMemory;
        };
        errdefer self.allocator.free(pane_uuids);
        for (0..resp.pane_count) |i| {
            read.readExact(self, fd, &pane_uuids[i]) catch |e| {
                self.debugLog("reattachSession: failed to read pane uuid {d}: {s}", .{ i, @errorName(e) });
                return e;
            };
        }
        self.debugLog("reattachSession: read {d} pane UUIDs, success!", .{resp.pane_count});

        return .{
            .session_state_json = session_state,
            .pane_uuids = pane_uuids,
        };
    }

    /// List detached sessions.
    pub fn listSessions(self: *SesClient, out_buf: []DetachedSessionInfo) !usize {
        const fd = self.ctl_fd orelse return error.NotConnected;
        const request_id = try self.writeControlRequest(fd, .list_sessions, &.{});

        var read = try self.readSyncResponseForRequest(fd, request_id);
        defer read.deinit(self.allocator);
        const hdr = read.hdr;
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type != .sessions_list) {
            read.skipRemaining(self, fd);
            return error.UnexpectedResponse;
        }

        const resp = try read.readStruct(self, fd, wire.SessionsList);
        var count: usize = 0;
        for (0..resp.session_count) |_| {
            const entry = read.readStruct(self, fd, wire.SessionEntry) catch |err| {
                logging.logError("frontend-client", "failed to read detached session entry", err);
                if (self.ctl_fd == fd) self.ctl_fd = null;
                return err;
            };
            var info: DetachedSessionInfo = undefined;
            info.session_id = entry.session_id;
            info.pane_count = entry.pane_count;
            // Read name.
            const name_len = @min(@as(usize, entry.name_len), 32);
            if (entry.name_len > 0) {
                var name_buf: [32]u8 = undefined;
                read.readExact(self, fd, name_buf[0..name_len]) catch |err| {
                    logging.logError("frontend-client", "failed to read detached session name", err);
                    if (self.ctl_fd == fd) self.ctl_fd = null;
                    return err;
                };
                @memcpy(info.session_name[0..name_len], name_buf[0..name_len]);
                info.session_name_len = name_len;
                // Skip excess name bytes.
                if (entry.name_len > 32) {
                    read.skip(self, fd, entry.name_len - 32);
                }
            } else {
                info.session_name_len = 0;
            }

            const base_root_len = @min(@as(usize, entry.base_root_len), info.base_root.len);
            if (entry.base_root_len > 0) {
                read.readExact(self, fd, info.base_root[0..base_root_len]) catch |err| {
                    logging.logError("frontend-client", "failed to read detached session base root", err);
                    if (self.ctl_fd == fd) self.ctl_fd = null;
                    return err;
                };
                info.base_root_len = base_root_len;
                if (entry.base_root_len > info.base_root.len) {
                    read.skip(self, fd, entry.base_root_len - @as(u16, @intCast(info.base_root.len)));
                }
            } else {
                info.base_root_len = 0;
            }
            if (count < out_buf.len) {
                out_buf[count] = info;
                count += 1;
            }
        }
        return count;
    }

    /// Start the ses daemon.
    fn startSes(self: *SesClient) !void {
        var args_list: std.ArrayList([]const u8) = .empty;
        defer args_list.deinit(self.allocator);

        const exe_path = try std.fs.selfExePathAlloc(self.allocator);
        defer self.allocator.free(exe_path);

        try args_list.append(self.allocator, exe_path);
        try args_list.append(self.allocator, "ses");
        try args_list.append(self.allocator, "daemon");

        if (std.posix.getenv("HEXE_INSTANCE")) |inst| {
            if (inst.len > 0) {
                try args_list.append(self.allocator, "--instance");
                try args_list.append(self.allocator, inst);
            }
        }
        if (std.posix.getenv("HEXE_TEST_ONLY")) |v| {
            if (v.len > 0 and !std.mem.eql(u8, v, "0")) {
                try args_list.append(self.allocator, "--test-only");
            }
        }
        if (self.log_level) |level| {
            try args_list.append(self.allocator, "--log");
            try args_list.append(self.allocator, @tagName(level));
        }
        if (self.log_file) |path| {
            if (path.len > 0) {
                try args_list.append(self.allocator, "--logfile");
                try args_list.append(self.allocator, path);
            }
        }

        self.traceLog("startSes: argv_count={d}", .{args_list.items.len});
        for (args_list.items) |arg| {
            self.traceLog("startSes argv: {s}", .{arg});
        }

        var child = std.process.Child.init(args_list.items, std.heap.page_allocator);
        child.spawn() catch |err| {
            self.debugLog("failed to start ses daemon: {s}", .{@errorName(err)});
            return err;
        };
        self.traceLog("startSes: spawned pid={d}", .{child.id});
        _ = child.wait() catch |err| {
            logging.logError("frontend-client", "failed to wait for ses daemon starter", err);
        };
        self.traceLog("startSes: child exited", .{});
    }

    /// Check if connected to ses.
    pub fn isConnected(self: *SesClient) bool {
        return self.ctl_fd != null;
    }

    /// Get the VT channel fd (for polling in the event loop).
    pub fn getVtFd(self: *SesClient) ?posix.fd_t {
        return self.vt_fd;
    }

    /// Get the control channel fd (for polling async messages).
    pub fn getCtlFd(self: *SesClient) ?posix.fd_t {
        return self.ctl_fd;
    }

    /// Check if CTL channel is available. Logs a warning if not.
    /// Returns true if CTL is available, false otherwise.
    pub fn ensureCtlConnected(self: *SesClient) bool {
        if (self.ctl_fd == null) {
            self.debugLog("CTL channel not available (disconnected)", .{});
            return false;
        }
        return true;
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    fn readExpectedPaneInfoResponse(self: *SesClient, fd: posix.fd_t, expected_uuid: [32]u8, expected_request_id: u32) !PaneInfoRead {
        if (self.takePendingControlResponse(expected_request_id)) |pending_response| {
            var pending = pending_response;
            defer pending.deinit(self.allocator);
            if (pending.msg_type == .pane_not_found) return error.PaneMissing;
            if (pending.msg_type != .pane_info) return error.UnexpectedResponse;
            const read = try self.readPaneInfoPendingPayload(pending.payload);
            if (!std.mem.eql(u8, &read.resp.uuid, &expected_uuid)) {
                var owned = read;
                owned.deinit(self.allocator);
                return error.UnexpectedResponse;
            }
            return read;
        }

        while (true) {
            const hdr = try wire.readControlHeader(fd);
            const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
            switch (msg_type) {
                .ok, .pane_exited, .session_state => {
                    if (hdr.request_id != 0 and hdr.request_id != expected_request_id) {
                        try self.queuePendingControlResponseBody(fd, hdr);
                        continue;
                    }
                    self.consumeQueuedControlResponse(fd, hdr);
                    continue;
                },
                .get_pane_cwd => {
                    const resp = self.readPaneCwdBody(fd, hdr) catch |err| {
                        logging.logError("frontend-client", "failed to read queued pane cwd response", err);
                        if (self.ctl_fd == fd) self.ctl_fd = null;
                        return err;
                    };
                    self.queuePendingPaneCwdBody(fd, resp);
                    continue;
                },
                .pane_info => {
                    if (hdr.request_id != 0 and hdr.request_id != expected_request_id) {
                        try self.queuePendingControlResponseBody(fd, hdr);
                        continue;
                    }
                    if (hdr.payload_len < @sizeOf(wire.PaneInfoResp)) {
                        self.skipPayload(fd, hdr.payload_len);
                        logging.logError("frontend-client", "pane_info response too small", error.UnexpectedResponse);
                        if (self.ctl_fd == fd) self.ctl_fd = null;
                        return error.UnexpectedResponse;
                    }
                    const resp = wire.readStruct(wire.PaneInfoResp, fd) catch |err| {
                        self.skipPayload(fd, hdr.payload_len);
                        logging.logError("frontend-client", "failed to read pane_info response", err);
                        if (self.ctl_fd == fd) self.ctl_fd = null;
                        return err;
                    };
                    if (hdr.request_id == expected_request_id and std.mem.eql(u8, &resp.uuid, &expected_uuid)) {
                        return .{ .hdr = hdr, .resp = resp };
                    }
                    self.queuePaneInfoResponseBody(fd, resp);
                    continue;
                },
                .pane_not_found => {
                    self.skipPayload(fd, hdr.payload_len);
                    // Only trust a reply correlated to OUR request: the
                    // payload carries no UUID, so an uncorrelated
                    // pane_not_found could belong to any other query and
                    // must not condemn this pane.
                    if (hdr.request_id == expected_request_id) {
                        // Definitive: SES does not know this pane.
                        return error.PaneMissing;
                    }
                    continue;
                },
                else => {
                    if (hdr.request_id != 0 and hdr.request_id != expected_request_id) {
                        try self.queuePendingControlResponseBody(fd, hdr);
                        continue;
                    }
                    if (hdr.request_id == expected_request_id) {
                        // Some other definitive reply to our request.
                        self.skipPayload(fd, hdr.payload_len);
                        return error.UnexpectedResponse;
                    }
                    // Interleaved async push — consume without failing the
                    // query; a spurious failure here gets interpreted as
                    // "pane gone" and destroys live floats downstream.
                    self.consumeQueuedControlResponse(fd, hdr);
                    continue;
                },
            }
        }
    }

    fn readExpectedPaneCwdResponse(self: *SesClient, fd: posix.fd_t, expected_uuid: [32]u8, expected_request_id: u32) !PaneCwdRead {
        if (self.takePendingControlResponse(expected_request_id)) |pending_response| {
            var pending = pending_response;
            defer pending.deinit(self.allocator);
            if (pending.msg_type != .get_pane_cwd) return error.UnexpectedResponse;
            const read = try self.readPaneCwdPendingPayload(pending.payload);
            if (!std.mem.eql(u8, &read.uuid, &expected_uuid)) {
                var owned = read;
                owned.deinit(self.allocator);
                return error.UnexpectedResponse;
            }
            return read;
        }

        while (true) {
            const hdr = try wire.readControlHeader(fd);
            const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
            switch (msg_type) {
                .ok, .pane_exited, .session_state, .pane_info => {
                    if (hdr.request_id != 0 and hdr.request_id != expected_request_id and msg_type != .pane_info) {
                        self.skipPayload(fd, hdr.payload_len);
                        return error.UnexpectedResponse;
                    }
                    self.consumeQueuedControlResponse(fd, hdr);
                    continue;
                },
                .get_pane_cwd => {
                    if (hdr.request_id != 0 and hdr.request_id != expected_request_id) {
                        try self.queuePendingControlResponseBody(fd, hdr);
                        continue;
                    }
                    var resp = self.readPaneCwdBodyOwned(fd, hdr) catch |err| {
                        logging.logError("frontend-client", "failed to read pane cwd response", err);
                        if (self.ctl_fd == fd) self.ctl_fd = null;
                        return err;
                    };
                    if (hdr.request_id == expected_request_id and std.mem.eql(u8, &resp.uuid, &expected_uuid)) return resp;
                    self.queuePendingCwdResponse(resp.uuid, resp.cwd);
                    resp.deinit(self.allocator);
                    continue;
                },
                else => {
                    self.skipPayload(fd, hdr.payload_len);
                    return error.UnexpectedResponse;
                },
            }
        }
    }

    fn remainingDeadlineMs(deadline_ms: i64) !i32 {
        const remaining = deadline_ms - std.time.milliTimestamp();
        if (remaining <= 0) return error.Timeout;
        return @intCast(@min(remaining, @as(i64, std.math.maxInt(i32))));
    }

    fn readSyncResponseForRequest(self: *SesClient, fd: posix.fd_t, expected_request_id: u32) !ControlResponseRead {
        return self.readSyncResponseUntilForRequest(fd, expected_request_id, std.time.milliTimestamp() + SYNC_RESPONSE_TIMEOUT_MS, "sync response");
    }

    fn readSyncResponseUntilForRequest(self: *SesClient, fd: posix.fd_t, expected_request_id: u32, deadline_ms: i64, comptime context: []const u8) !ControlResponseRead {
        if (self.takePendingControlResponse(expected_request_id)) |pending_response| {
            return .{
                .hdr = .{
                    .msg_type = @intFromEnum(pending_response.msg_type),
                    .request_id = pending_response.request_id,
                    .payload_len = @intCast(pending_response.payload.len),
                },
                .payload = pending_response.payload,
            };
        }

        while (true) {
            const hdr = wire.readControlHeaderTimeout(fd, try remainingDeadlineMs(deadline_ms)) catch |err| {
                self.debugLog("{s}: timed out/failed waiting for control header: {s}", .{ context, @errorName(err) });
                return err;
            };
            const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
            const matches_request = hdr.request_id == expected_request_id;
            switch (msg_type) {
                // Stale acks from older commands without dedicated responses.
                .ok => {
                    if (matches_request) return .{ .hdr = hdr };
                    if (hdr.request_id != 0) {
                        try self.queuePendingControlResponseBody(fd, hdr);
                        continue;
                    }
                    self.consumeQueuedControlResponse(fd, hdr);
                    continue;
                },
                // Async get_pane_cwd response.
                .get_pane_cwd => {
                    if (hdr.request_id != 0 and hdr.request_id != expected_request_id) {
                        try self.queuePendingControlResponseBody(fd, hdr);
                        continue;
                    }
                    self.consumeQueuedControlResponse(fd, hdr);
                    continue;
                },
                // Async pane_info response (large payload = response, not request).
                .pane_info => {
                    if (hdr.payload_len >= @sizeOf(wire.PaneInfoResp) and hdr.request_id == 0) {
                        self.consumeQueuedControlResponse(fd, hdr);
                        continue;
                    }
                    if (!matches_request and hdr.request_id != 0) {
                        try self.queuePendingControlResponseBody(fd, hdr);
                        continue;
                    }
                    return .{ .hdr = hdr };
                },
                .pane_exited => {
                    self.consumeQueuedControlResponse(fd, hdr);
                    continue;
                },
                .session_state => {
                    self.consumeQueuedControlResponse(fd, hdr);
                    continue;
                },
                else => {
                    if (!matches_request) {
                        if (hdr.request_id != 0) {
                            try self.queuePendingControlResponseBody(fd, hdr);
                            continue;
                        }
                        // Interleaved async push (shell_event, notify,
                        // session_stolen, ...). It is not our response, so it
                        // must never fail this operation: consume it (types
                        // with preserve machinery are queued for the IPC
                        // loop) and keep waiting.
                        self.consumeQueuedControlResponse(fd, hdr);
                        continue;
                    }
                    return .{ .hdr = hdr };
                },
            }
        }
    }

    fn drainQueuedControlResponses(self: *SesClient, fd: posix.fd_t) void {
        while (true) {
            var fds = [_]posix.pollfd{
                .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
            };
            const ready = posix.poll(&fds, 0) catch |err| {
                logging.logError("frontend-client", "failed to poll queued control responses", err);
                if (self.ctl_fd == fd) self.ctl_fd = null;
                return;
            };
            if (ready == 0 or (fds[0].revents & posix.POLL.IN) == 0) return;

            const hdr = wire.readControlHeader(fd) catch |err| {
                logging.logError("frontend-client", "failed to read queued control response header", err);
                if (self.ctl_fd == fd) self.ctl_fd = null;
                return;
            };
            self.consumeQueuedControlResponse(fd, hdr);
        }
    }

    fn readCommandAckForRequest(self: *SesClient, fd: posix.fd_t, expected_request_id: u32) !void {
        return self.readCommandAckUntilForRequest(fd, expected_request_id, std.time.milliTimestamp() + COMMAND_ACK_TIMEOUT_MS, "command ack");
    }

    fn readCommandAckUntilForRequest(self: *SesClient, fd: posix.fd_t, expected_request_id: u32, deadline_ms: i64, comptime context: []const u8) !void {
        if (self.takePendingControlResponse(expected_request_id)) |pending_response| {
            var pending = pending_response;
            defer pending.deinit(self.allocator);
            switch (pending.msg_type) {
                .ok => return,
                .@"error" => return error.SesError,
                else => return error.UnexpectedResponse,
            }
        }

        while (true) {
            const hdr = wire.readControlHeaderTimeout(fd, try remainingDeadlineMs(deadline_ms)) catch |err| {
                self.debugLog("{s}: timed out/failed waiting for ack header: {s}", .{ context, @errorName(err) });
                return err;
            };
            const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
            const matches_request = hdr.request_id == expected_request_id;
            switch (msg_type) {
                .ok => {
                    if (!matches_request) {
                        if (hdr.request_id == 0) {
                            self.skipPayload(fd, hdr.payload_len);
                            continue;
                        }
                        try self.queuePendingControlResponseBody(fd, hdr);
                        continue;
                    }
                    self.skipPayload(fd, hdr.payload_len);
                    return;
                },
                .@"error" => {
                    if (!matches_request) {
                        if (hdr.request_id == 0) {
                            self.skipPayload(fd, hdr.payload_len);
                            continue;
                        }
                        try self.queuePendingControlResponseBody(fd, hdr);
                        continue;
                    }
                    self.skipPayload(fd, hdr.payload_len);
                    return error.SesError;
                },
                .get_pane_cwd, .pane_info, .pane_exited, .session_state => {
                    self.consumeQueuedControlResponse(fd, hdr);
                    continue;
                },
                else => {
                    if (!matches_request) {
                        if (hdr.request_id != 0) {
                            try self.queuePendingControlResponseBody(fd, hdr);
                            continue;
                        }
                        // Async push interleaved with the ack — consume it
                        // instead of failing the command (see
                        // readSyncResponseUntilForRequest).
                        self.consumeQueuedControlResponse(fd, hdr);
                        continue;
                    }
                    self.skipPayload(fd, hdr.payload_len);
                    return error.UnexpectedResponse;
                },
            }
        }
    }

    fn queuePendingControlResponseBody(self: *SesClient, fd: posix.fd_t, hdr: wire.ControlHeader) !void {
        if (hdr.request_id == 0) {
            self.skipPayload(fd, hdr.payload_len);
            return;
        }
        if (hdr.payload_len > wire.MAX_PAYLOAD_LEN) {
            self.skipPayload(fd, hdr.payload_len);
            return error.UnexpectedResponse;
        }
        const payload = try self.allocator.alloc(u8, hdr.payload_len);
        errdefer self.allocator.free(payload);
        if (hdr.payload_len > 0) {
            try wire.readExact(fd, payload);
        }
        self.queuePendingControlResponse(.{
            .request_id = hdr.request_id,
            .msg_type = @enumFromInt(hdr.msg_type),
            .payload = payload,
        });
    }

    fn consumeQueuedControlResponse(self: *SesClient, fd: posix.fd_t, hdr: wire.ControlHeader) void {
        const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        switch (msg_type) {
            .pane_exited => {
                if (hdr.payload_len >= @sizeOf(wire.PaneUuid)) {
                    const pu = wire.readStruct(wire.PaneUuid, fd) catch {
                        self.skipPayload(fd, hdr.payload_len);
                        return;
                    };
                    self.queuePendingPaneExit(pu.uuid);
                    const rem = hdr.payload_len - @sizeOf(wire.PaneUuid);
                    if (rem > 0) self.skipPayload(fd, rem);
                } else {
                    self.skipPayload(fd, hdr.payload_len);
                }
            },
            .session_state => {
                if (hdr.payload_len == 0 or hdr.payload_len > wire.MAX_PAYLOAD_LEN) {
                    self.skipPayload(fd, hdr.payload_len);
                    return;
                }
                const json = self.allocator.alloc(u8, hdr.payload_len) catch {
                    self.skipPayload(fd, hdr.payload_len);
                    return;
                };
                wire.readExact(fd, json) catch {
                    self.allocator.free(json);
                    return;
                };
                self.queuePendingSessionState(json);
                self.allocator.free(json);
            },
            .get_pane_cwd => {
                const resp = self.readPaneCwdBody(fd, hdr) catch |err| {
                    logging.logError("frontend-client", "failed to consume queued pane cwd response", err);
                    if (self.ctl_fd == fd) self.ctl_fd = null;
                    return;
                };
                self.queuePendingPaneCwdBody(fd, resp);
            },
            .pane_info => {
                if (hdr.payload_len < @sizeOf(wire.PaneInfoResp)) {
                    self.skipPayload(fd, hdr.payload_len);
                    logging.logError("frontend-client", "queued pane_info response too small", error.UnexpectedResponse);
                    if (self.ctl_fd == fd) self.ctl_fd = null;
                    return;
                }
                const resp = wire.readStruct(wire.PaneInfoResp, fd) catch |err| {
                    self.skipPayload(fd, hdr.payload_len);
                    logging.logError("frontend-client", "failed to consume queued pane_info response", err);
                    if (self.ctl_fd == fd) self.ctl_fd = null;
                    return;
                };
                self.queuePaneInfoResponseBody(fd, resp);
            },
            .session_stolen => {
                // Must never be dropped: without it this mux keeps writing
                // into a session another client now owns.
                self.skipPayload(fd, hdr.payload_len);
                self.pending_session_stolen = true;
            },
            else => self.skipPayload(fd, hdr.payload_len),
        }
    }

    fn readPaneCwdBody(self: *SesClient, fd: posix.fd_t, hdr: wire.ControlHeader) !wire.PaneCwd {
        if (hdr.payload_len < @sizeOf(wire.PaneCwd)) {
            self.skipPayload(fd, hdr.payload_len);
            return error.UnexpectedResponse;
        }
        return wire.readStruct(wire.PaneCwd, fd);
    }

    fn readPaneCwdBodyOwned(self: *SesClient, fd: posix.fd_t, hdr: wire.ControlHeader) !PaneCwdRead {
        const resp = try self.readPaneCwdBody(fd, hdr);
        const body_len = hdr.payload_len - @sizeOf(wire.PaneCwd);
        if (resp.cwd_len == 0) {
            if (body_len > 0) self.skipPayload(fd, body_len);
            return .{ .uuid = resp.uuid, .cwd = &.{} };
        }
        if (resp.cwd_len != body_len or resp.cwd_len > wire.MAX_PAYLOAD_LEN) {
            self.skipPayload(fd, body_len);
            return error.UnexpectedResponse;
        }
        const cwd = try self.allocator.alloc(u8, resp.cwd_len);
        errdefer self.allocator.free(cwd);
        try wire.readExact(fd, cwd);
        return .{ .uuid = resp.uuid, .cwd = cwd };
    }

    fn readPaneCwdPendingPayload(self: *SesClient, payload: []const u8) !PaneCwdRead {
        if (payload.len < @sizeOf(wire.PaneCwd)) return error.UnexpectedResponse;
        const resp = wire.bytesToStruct(wire.PaneCwd, payload[0..@sizeOf(wire.PaneCwd)]) orelse return error.UnexpectedResponse;
        const body = payload[@sizeOf(wire.PaneCwd)..];
        if (resp.cwd_len == 0) return .{ .uuid = resp.uuid, .cwd = &.{} };
        if (resp.cwd_len != body.len or resp.cwd_len > wire.MAX_PAYLOAD_LEN) return error.UnexpectedResponse;
        const cwd = try self.allocator.dupe(u8, body);
        return .{ .uuid = resp.uuid, .cwd = cwd };
    }

    fn queuePendingPaneCwdBody(self: *SesClient, fd: posix.fd_t, resp: wire.PaneCwd) void {
        if (resp.cwd_len == 0) return;
        if (resp.cwd_len > wire.MAX_PAYLOAD_LEN) {
            self.skipPayload(fd, resp.cwd_len);
            logging.logError("frontend-client", "queued pane cwd response too large", error.UnexpectedResponse);
            return;
        }
        const cwd = self.allocator.alloc(u8, resp.cwd_len) catch {
            self.skipPayload(fd, resp.cwd_len);
            logging.logError("frontend-client", "failed to allocate queued pane cwd response", error.OutOfMemory);
            return;
        };
        defer self.allocator.free(cwd);
        wire.readExact(fd, cwd) catch |err| {
            logging.logError("frontend-client", "failed to read queued pane cwd payload", err);
            if (self.ctl_fd == fd) self.ctl_fd = null;
            return;
        };
        self.queuePendingCwdResponse(resp.uuid, cwd);
    }

    fn readPaneInfoPendingPayload(self: *SesClient, payload: []const u8) !PaneInfoRead {
        if (payload.len < @sizeOf(wire.PaneInfoResp)) return error.UnexpectedResponse;
        const resp = wire.bytesToStruct(wire.PaneInfoResp, payload[0..@sizeOf(wire.PaneInfoResp)]) orelse return error.UnexpectedResponse;
        const trail = payload[@sizeOf(wire.PaneInfoResp)..];
        const expected_trail_len: usize = @as(usize, resp.name_len) + @as(usize, resp.fg_len) +
            @as(usize, resp.cwd_len) + @as(usize, resp.tty_len) +
            @as(usize, resp.socket_path_len) + @as(usize, resp.session_name_len) +
            @as(usize, resp.layout_path_len) + @as(usize, resp.last_cmd_len) +
            @as(usize, resp.base_process_len) + @as(usize, resp.sticky_pwd_len);
        if (expected_trail_len != trail.len) return error.UnexpectedResponse;

        const owned_trail = try self.allocator.dupe(u8, trail);
        return .{
            .hdr = .{
                .msg_type = @intFromEnum(wire.MsgType.pane_info),
                .request_id = 0,
                .payload_len = @intCast(payload.len),
            },
            .resp = resp,
            .trail = owned_trail,
        };
    }

    fn queuePaneInfoResponseBody(self: *SesClient, fd: posix.fd_t, resp: wire.PaneInfoResp) void {
        const trail_total: usize = @as(usize, resp.name_len) + @as(usize, resp.fg_len) +
            @as(usize, resp.cwd_len) + @as(usize, resp.tty_len) +
            @as(usize, resp.socket_path_len) + @as(usize, resp.session_name_len) +
            @as(usize, resp.layout_path_len) + @as(usize, resp.last_cmd_len) +
            @as(usize, resp.base_process_len) + @as(usize, resp.sticky_pwd_len);

        var pending = PendingPaneInfoResponse{
            .uuid = resp.uuid,
            .fg_pid = if (resp.fg_pid != 0) resp.fg_pid else null,
        };
        var queued = false;
        defer if (!queued) pending.deinit(self.allocator);

        if (resp.name_len > 0) {
            pending.name = self.allocator.alloc(u8, resp.name_len) catch {
                self.skipPayload(fd, @intCast(trail_total));
                logging.logError("frontend-client", "failed to allocate queued pane name", error.OutOfMemory);
                return;
            };
            wire.readExact(fd, pending.name.?) catch |err| {
                logging.logError("frontend-client", "failed to read queued pane name", err);
                if (self.ctl_fd == fd) self.ctl_fd = null;
                return;
            };
        }
        if (resp.fg_len > 0) {
            pending.fg_name = self.allocator.alloc(u8, resp.fg_len) catch {
                const remaining = trail_total -| @as(usize, resp.name_len);
                self.skipPayload(fd, @intCast(remaining));
                logging.logError("frontend-client", "failed to allocate queued pane foreground name", error.OutOfMemory);
                return;
            };
            wire.readExact(fd, pending.fg_name.?) catch |err| {
                logging.logError("frontend-client", "failed to read queued pane foreground name", err);
                if (self.ctl_fd == fd) self.ctl_fd = null;
                return;
            };
        }

        const remaining = trail_total -| @as(usize, resp.name_len) -| @as(usize, resp.fg_len);
        if (remaining > 0) self.skipPayload(fd, @intCast(remaining));
        queued = true;
        self.queuePendingPaneInfoResponse(pending);
    }

    fn skipPayloadChecked(_: *SesClient, fd: posix.fd_t, len: u32) !void {
        var remaining: usize = len;
        var buf: [4096]u8 = undefined;
        while (remaining > 0) {
            const chunk = @min(remaining, buf.len);
            try wire.readExact(fd, buf[0..chunk]);
            remaining -= chunk;
        }
    }

    fn skipPayload(self: *SesClient, fd: posix.fd_t, len: u32) void {
        self.skipPayloadChecked(fd, len) catch |err| {
            logging.logError("frontend-client", "failed to skip control payload", err);
            if (self.ctl_fd == fd) self.ctl_fd = null;
        };
    }

    fn skipPayloadU16Checked(_: *SesClient, fd: posix.fd_t, len: u16) !void {
        var remaining: usize = len;
        var buf: [4096]u8 = undefined;
        while (remaining > 0) {
            const chunk = @min(remaining, buf.len);
            try wire.readExact(fd, buf[0..chunk]);
            remaining -= chunk;
        }
    }

    fn skipPayloadU16(self: *SesClient, fd: posix.fd_t, len: u16) void {
        self.skipPayloadU16Checked(fd, len) catch |err| {
            logging.logError("frontend-client", "failed to skip control payload", err);
            if (self.ctl_fd == fd) self.ctl_fd = null;
        };
    }

    fn skipPayloadU32(self: *SesClient, fd: posix.fd_t, len: u32) void {
        self.skipPayload(fd, len);
    }

    /// Send a ping to SES to check connection is alive.
    /// Returns true if pong received, false if connection appears dead.
    pub fn sendPing(self: *SesClient) bool {
        const fd = self.ctl_fd orelse return false;
        _ = self.writeControlRequest(fd, .ping, &.{}) catch |err| {
            logging.logError("frontend-client", "failed to send ping", err);
            if (self.ctl_fd == fd) self.ctl_fd = null;
            return false;
        };
        // Note: pong response will be received asynchronously and handled
        // by the IPC loop. We just check that the write succeeded.
        return true;
    }

    /// Request SES to trigger backlog replay for adopted panes.
    /// Called after reattachSession completes and MUX is ready to receive data.
    pub fn requestBacklogReplay(self: *SesClient) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        self.debugLog("requestBacklogReplay: sending replay_backlogs", .{});
        self.drainQueuedControlResponses(fd);
        const request_id = try self.writeControlRequest(fd, .replay_backlogs, &.{});
        try self.readCommandAckForRequest(fd, request_id);
        self.debugLog("requestBacklogReplay: acknowledged by SES", .{});
    }
};

pub const OrphanedPaneInfo = struct {
    uuid: [32]u8,
    pid: posix.pid_t,
    name: [64]u8 = .{0} ** 64,
    name_len: usize = 0,

    pub fn nameSlice(self: *const OrphanedPaneInfo) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const DetachedSessionInfo = struct {
    session_id: [32]u8,
    session_name: [32]u8,
    session_name_len: usize,
    base_root: [std.fs.max_path_bytes]u8 = undefined,
    base_root_len: usize = 0,
    pane_count: usize,
};

test "SesClient: queues multiple pending CWD responses FIFO" {
    var client = SesClient.init(std.testing.allocator, [_]u8{'s'} ** 32, "test", false, null, null);
    defer client.deinit();

    const first_uuid = [_]u8{'1'} ** 32;
    const second_uuid = [_]u8{'2'} ** 32;
    client.queuePendingCwdResponse(first_uuid, "/tmp/one");
    client.queuePendingCwdResponse(second_uuid, "/tmp/two");

    const first = client.drainPendingCwdResponse().?;
    defer std.testing.allocator.free(first.cwd);
    try std.testing.expectEqualSlices(u8, &first_uuid, &first.uuid);
    try std.testing.expectEqualStrings("/tmp/one", first.cwd);

    const second = client.drainPendingCwdResponse().?;
    defer std.testing.allocator.free(second.cwd);
    try std.testing.expectEqualSlices(u8, &second_uuid, &second.uuid);
    try std.testing.expectEqualStrings("/tmp/two", second.cwd);

    try std.testing.expect(client.drainPendingCwdResponse() == null);
}

test "SesClient: queues multiple pending pane-info responses FIFO" {
    var client = SesClient.init(std.testing.allocator, [_]u8{'s'} ** 32, "test", false, null, null);
    defer client.deinit();

    const first_uuid = [_]u8{'a'} ** 32;
    const second_uuid = [_]u8{'b'} ** 32;
    client.queuePendingPaneInfoResponse(.{
        .uuid = first_uuid,
        .name = try std.testing.allocator.dupe(u8, "one"),
        .fg_name = try std.testing.allocator.dupe(u8, "shell-one"),
        .fg_pid = 11,
    });
    client.queuePendingPaneInfoResponse(.{
        .uuid = second_uuid,
        .name = try std.testing.allocator.dupe(u8, "two"),
        .fg_name = try std.testing.allocator.dupe(u8, "shell-two"),
        .fg_pid = 22,
    });

    var first = client.drainPendingPaneInfoResponse().?;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &first_uuid, &first.uuid);
    try std.testing.expectEqualStrings("one", first.name.?);
    try std.testing.expectEqualStrings("shell-one", first.fg_name.?);
    try std.testing.expectEqual(@as(?i32, 11), first.fg_pid);

    var second = client.drainPendingPaneInfoResponse().?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &second_uuid, &second.uuid);
    try std.testing.expectEqualStrings("two", second.name.?);
    try std.testing.expectEqualStrings("shell-two", second.fg_name.?);
    try std.testing.expectEqual(@as(?i32, 22), second.fg_pid);

    try std.testing.expect(client.drainPendingPaneInfoResponse() == null);
}

test "SesClient: pending control responses are retrieved by request id" {
    var client = SesClient.init(std.testing.allocator, [_]u8{'s'} ** 32, "test", false, null, null);
    defer client.deinit();

    client.queuePendingControlResponse(.{
        .request_id = 10,
        .msg_type = .ok,
        .payload = try std.testing.allocator.dupe(u8, ""),
    });
    client.queuePendingControlResponse(.{
        .request_id = 20,
        .msg_type = .@"error",
        .payload = try std.testing.allocator.dupe(u8, "bad"),
    });

    var second = client.takePendingControlResponse(20).?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 20), second.request_id);
    try std.testing.expectEqual(wire.MsgType.@"error", second.msg_type);
    try std.testing.expectEqualStrings("bad", second.payload);

    var first = client.takePendingControlResponse(10).?;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 10), first.request_id);
    try std.testing.expectEqual(wire.MsgType.ok, first.msg_type);
    try std.testing.expectEqualStrings("", first.payload);

    try std.testing.expect(client.takePendingControlResponse(20) == null);
}

test "SesClient: command ack reader queues out-of-order request ids" {
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    try wire.writeControlWithRequestId(pipe_fds[1], .ok, 20, &.{});
    try wire.writeControlWithRequestId(pipe_fds[1], .ok, 10, &.{});

    var client = SesClient.init(std.testing.allocator, [_]u8{'s'} ** 32, "test", false, null, null);
    defer client.deinit();

    try client.readCommandAckForRequest(pipe_fds[0], 10);
    try std.testing.expectEqual(@as(usize, 1), client.pending_control_responses.items.len);
    try std.testing.expectEqual(@as(u32, 20), client.pending_control_responses.items[0].request_id);

    try client.readCommandAckForRequest(pipe_fds[0], 20);
    try std.testing.expectEqual(@as(usize, 0), client.pending_control_responses.items.len);
}

test "SesClient: sync response reader queues and replays out-of-order direct payloads" {
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    const first_body = wire.PaneFound{
        .uuid = [_]u8{'a'} ** 32,
        .pid = 11,
        .pane_id = 1,
        .socket_path_len = 0,
    };
    const second_body = wire.PaneFound{
        .uuid = [_]u8{'b'} ** 32,
        .pid = 22,
        .pane_id = 2,
        .socket_path_len = 0,
    };

    try wire.writeControlWithRequestId(pipe_fds[1], .pane_found, 20, std.mem.asBytes(&second_body));
    try wire.writeControlWithRequestId(pipe_fds[1], .pane_found, 10, std.mem.asBytes(&first_body));

    var client = SesClient.init(std.testing.allocator, [_]u8{'s'} ** 32, "test", false, null, null);
    defer client.deinit();

    var first = try client.readSyncResponseForRequest(pipe_fds[0], 10);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(wire.MsgType.pane_found, first.msgType());
    const first_resp = try first.readStruct(&client, pipe_fds[0], wire.PaneFound);
    try std.testing.expectEqual(@as(i32, 11), first_resp.pid);
    try std.testing.expectEqual(@as(usize, 1), client.pending_control_responses.items.len);
    try std.testing.expectEqual(@as(u32, 20), client.pending_control_responses.items[0].request_id);

    var second = try client.readSyncResponseForRequest(pipe_fds[0], 20);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(wire.MsgType.pane_found, second.msgType());
    const second_resp = try second.readStruct(&client, pipe_fds[0], wire.PaneFound);
    try std.testing.expectEqual(@as(i32, 22), second_resp.pid);
    try std.testing.expectEqual(@as(usize, 0), client.pending_control_responses.items.len);
}

test "SesClient: sync pane cwd reader replays queued payload-bearing response" {
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    const first_uuid = [_]u8{'a'} ** 32;
    const second_uuid = [_]u8{'b'} ** 32;
    const first_cwd = "/tmp/first";
    const second_cwd = "/tmp/second";
    const first_body = wire.PaneCwd{
        .uuid = first_uuid,
        .cwd_len = @intCast(first_cwd.len),
    };
    const second_body = wire.PaneCwd{
        .uuid = second_uuid,
        .cwd_len = @intCast(second_cwd.len),
    };

    try wire.writeControlWithTrailAndRequestId(pipe_fds[1], .get_pane_cwd, 20, std.mem.asBytes(&second_body), second_cwd);
    try wire.writeControlWithTrailAndRequestId(pipe_fds[1], .get_pane_cwd, 10, std.mem.asBytes(&first_body), first_cwd);

    var client = SesClient.init(std.testing.allocator, [_]u8{'s'} ** 32, "test", false, null, null);
    defer client.deinit();

    var first = try client.readExpectedPaneCwdResponse(pipe_fds[0], first_uuid, 10);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &first_uuid, &first.uuid);
    try std.testing.expectEqualStrings(first_cwd, first.cwd);
    try std.testing.expectEqual(@as(usize, 1), client.pending_control_responses.items.len);

    var second = try client.readExpectedPaneCwdResponse(pipe_fds[0], second_uuid, 20);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &second_uuid, &second.uuid);
    try std.testing.expectEqualStrings(second_cwd, second.cwd);
    try std.testing.expectEqual(@as(usize, 0), client.pending_control_responses.items.len);
}
