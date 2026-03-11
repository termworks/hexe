const std = @import("std");
const posix = std.posix;
const core = @import("core");
const wire = core.wire;
const mux = @import("main.zig");

/// Static buffer for synchronous CWD fetch (getPaneCwdSync).
var sync_cwd_buf: [4096]u8 = undefined;

/// Client for communicating with the ses daemon using binary protocol.
/// Opens two channels:
///   - ctl_fd (handshake 0x01): binary control messages
///   - vt_fd (handshake 0x02): multiplexed VT data (MuxVtHeader frames)
pub const SesClient = struct {
    allocator: std.mem.Allocator,
    ctl_fd: ?posix.fd_t,
    vt_fd: ?posix.fd_t,
    just_started_daemon: bool,
    debug: bool,
    log_file: ?[]const u8,

    // Registration info
    session_id: [32]u8, // mux UUID as hex string
    session_name: []const u8, // Pokemon name
    keepalive: bool,

    // Resolved session name from server (may differ if collision detected).
    // Owned by SesClient if non-null. Caller should update their state if this differs.
    resolved_name: ?[]u8 = null,

    // Pending async request tracking
    pending_cwd_uuid: ?[32]u8 = null,
    pending_pane_exits: std.ArrayList([32]u8),

    pub fn init(allocator: std.mem.Allocator, session_id: [32]u8, session_name: []const u8, keepalive: bool, debug: bool, log_file: ?[]const u8) SesClient {
        return .{
            .allocator = allocator,
            .ctl_fd = null,
            .vt_fd = null,
            .just_started_daemon = false,
            .debug = debug,
            .log_file = log_file,
            .session_id = session_id,
            .session_name = session_name,
            .keepalive = keepalive,
            .pending_pane_exits = .empty,
        };
    }

    pub fn deinit(self: *SesClient) void {
        if (self.ctl_fd) |fd| posix.close(fd);
        if (self.vt_fd) |fd| posix.close(fd);
        if (self.resolved_name) |rn| self.allocator.free(rn);
        self.pending_pane_exits.deinit(self.allocator);
        self.ctl_fd = null;
        self.vt_fd = null;
        self.resolved_name = null;
    }

    fn queuePendingPaneExit(self: *SesClient, uuid: [32]u8) void {
        for (self.pending_pane_exits.items) |existing| {
            if (std.mem.eql(u8, &existing, &uuid)) return;
        }
        self.pending_pane_exits.append(self.allocator, uuid) catch {};
    }

    /// Move queued pane-exit messages captured during sync calls into `out`.
    pub fn drainPendingPaneExits(self: *SesClient, out: *std.ArrayList([32]u8)) void {
        if (self.pending_pane_exits.items.len == 0) return;
        out.appendSlice(self.allocator, self.pending_pane_exits.items) catch return;
        self.pending_pane_exits.clearRetainingCapacity();
    }

    /// Connect to the ses daemon, starting it if necessary.
    /// Opens CTL channel, registers, then opens VT channel.
    pub fn connect(self: *SesClient) !void {
        const socket_path = try core.ipc.getSesSocketPath(self.allocator);
        defer self.allocator.free(socket_path);
        mux.debugLog("ses connect: socket_path={s}", .{socket_path});

        // Try to connect to existing daemon first
        if (self.connectCtl(socket_path)) {
            mux.debugLog("ses connect: connected to existing daemon", .{});
            self.just_started_daemon = false;
        } else {
            // Daemon not running, start it
            mux.debugLog("ses connect: daemon not running, starting...", .{});
            try self.startSes();
            self.just_started_daemon = true;

            // Wait for daemon to be ready
            std.Thread.sleep(200 * std.time.ns_per_ms);

            // Retry connection
            if (!self.connectCtl(socket_path)) {
                mux.debugLog("ses connect: retry connection failed", .{});
                return error.ConnectionRefused;
            }
            mux.debugLog("ses connect: retry succeeded", .{});
        }

        // Register on CTL channel first, so SES knows our session_id.
        mux.debugLog("ses connect: registering session_id={s}", .{&self.session_id});
        try self.register();
        mux.debugLog("ses connect: registration complete", .{});

        // Switch to non-blocking mode after successful registration.
        self.setCtlNonBlocking();

        // Now open VT channel — SES can match our session_id.
        if (!self.connectVt(socket_path)) {
            mux.debugLog("ses connect: VT channel connection failed", .{});
            return error.ConnectionRefused;
        }
        mux.debugLog("ses connect: VT channel connected, fully connected!", .{});
    }

    /// Open the control channel to SES.
    fn connectCtl(self: *SesClient, socket_path: []const u8) bool {
        const ctl_client = core.ipc.Client.connect(socket_path) catch return false;
        const ctl_fd = ctl_client.fd;

        // Set socket timeouts for initial registration (prevents hanging on dead daemon).
        // This is needed because register() does blocking I/O waiting for response.
        const timeout = posix.timeval{ .sec = 5, .usec = 0 };
        posix.setsockopt(ctl_fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
        posix.setsockopt(ctl_fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};

        wire.sendHandshake(ctl_fd, wire.SES_HANDSHAKE_MUX_CTL) catch {
            posix.close(ctl_fd);
            return false;
        };
        self.ctl_fd = ctl_fd;
        mux.debugLog("ses ctl connected: fd={d}", .{ctl_fd});
        return true;
    }

    /// Set non-blocking mode on CTL fd after registration succeeds.
    /// Called after register() so main loop sync calls don't block.
    fn setCtlNonBlocking(self: *SesClient) void {
        const fd = self.ctl_fd orelse return;
        const O_NONBLOCK: usize = 0o4000;
        const flags = posix.fcntl(fd, posix.F.GETFL, 0) catch return;
        _ = posix.fcntl(fd, posix.F.SETFL, flags | O_NONBLOCK) catch {};
        // Clear the socket timeouts now that we're non-blocking.
        const zero_timeout = posix.timeval{ .sec = 0, .usec = 0 };
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&zero_timeout)) catch {};
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&zero_timeout)) catch {};
    }

    /// Open the VT data channel to SES.
    fn connectVt(self: *SesClient, socket_path: []const u8) bool {
        const vt_client = core.ipc.Client.connect(socket_path) catch return false;
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

        wire.sendHandshake(vt_fd, wire.SES_HANDSHAKE_MUX_VT) catch {
            posix.close(vt_fd);
            return false;
        };
        // Send 32-byte hex session_id so SES can match us to the registered client.
        wire.writeAll(vt_fd, &self.session_id) catch {
            posix.close(vt_fd);
            return false;
        };
        self.vt_fd = vt_fd;
        mux.debugLog("ses vt connected: fd={d}", .{vt_fd});
        return true;
    }

    /// Register with ses — send session_id, session_name, and keepalive preference.
    /// Server may return a different name if collision detected - stored in resolved_name.
    fn register(self: *SesClient) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        mux.debugLog("registering session={s} name={s}", .{ self.session_id[0..8], self.session_name });

        var reg: wire.Register = .{
            .session_id = self.session_id,
            .keepalive = if (self.keepalive) 1 else 0,
            .name_len = @intCast(self.session_name.len),
        };
        try wire.writeControlWithTrail(fd, .register, std.mem.asBytes(&reg), self.session_name);

        // Wait for registered response.
        const hdr = try self.readSyncResponse(fd);
        const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (msg_type == .@"error") {
            self.skipPayload(fd, hdr.payload_len);
            return error.RegistrationFailed;
        }
        if (msg_type != .registered) {
            self.skipPayload(fd, hdr.payload_len);
            return error.UnexpectedResponse;
        }

        // Read the Registered response with resolved name
        if (hdr.payload_len >= @sizeOf(wire.Registered)) {
            const resp = try wire.readStruct(wire.Registered, fd);
            const remaining = hdr.payload_len - @sizeOf(wire.Registered);

            // Read resolved name if present
            if (resp.name_len > 0 and resp.name_len <= remaining) {
                // Free old resolved_name if any
                if (self.resolved_name) |old| {
                    self.allocator.free(old);
                    self.resolved_name = null;
                }

                const name_buf = self.allocator.alloc(u8, resp.name_len) catch {
                    self.skipPayload(fd, remaining);
                    return;
                };
                wire.readExact(fd, name_buf) catch {
                    self.allocator.free(name_buf);
                    return;
                };
                self.resolved_name = name_buf;
                mux.debugLog("register: server resolved name to '{s}'", .{name_buf});

                // Skip any remaining payload
                if (remaining > resp.name_len) {
                    self.skipPayload(fd, remaining - resp.name_len);
                }
            } else if (remaining > 0) {
                self.skipPayload(fd, remaining);
            }
        } else if (hdr.payload_len > 0) {
            self.skipPayload(fd, hdr.payload_len);
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
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.Disconnect = .{
            .mode = 0, // shutdown
            .preserve_sticky = if (preserve_sticky) 1 else 0,
        };
        // Best-effort: don't block on a reply.
        wire.writeControl(fd, .disconnect, std.mem.asBytes(&msg)) catch {};
        // Close fds after notifying
        if (self.ctl_fd) |cfd| posix.close(cfd);
        if (self.vt_fd) |vfd| posix.close(vfd);
        self.ctl_fd = null;
        self.vt_fd = null;
    }

    /// Sync canonical session state to ses (fire-and-forget).
    pub fn syncState(self: *SesClient, session_state_json: []const u8, version: u32) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.SyncState = .{
            .state_len = @intCast(session_state_json.len),
            .version = version,
        };
        try wire.writeControlWithTrail(fd, .sync_state, std.mem.asBytes(&msg), session_state_json);
    }

    /// Sync legacy mux layout JSON to ses for layout save/apply compatibility.
    pub fn syncLayout(self: *SesClient, mux_state_json: []const u8, version: u32) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.SyncState = .{
            .state_len = @intCast(mux_state_json.len),
            .version = version,
        };
        try wire.writeControlWithTrail(fd, .layout_sync, std.mem.asBytes(&msg), mux_state_json);
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
        try wire.writeControlWithTrail(fd, .session_add_tab, std.mem.asBytes(&msg), name);
    }

    pub fn sessionRemoveTab(self: *SesClient, tab_uuid: [32]u8, active_tab: ?usize) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.SessionRemoveTab = .{
            .tab_uuid = tab_uuid,
            .active_tab = @intCast(active_tab orelse 0),
            .has_active_tab = if (active_tab != null) 1 else 0,
        };
        try wire.writeControl(fd, .session_remove_tab, std.mem.asBytes(&msg));
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
        try wire.writeControl(fd, .session_sync_float, std.mem.asBytes(&msg));
    }

    pub fn sessionRemoveFloat(self: *SesClient, pane_uuid: [32]u8) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.SessionRemoveFloat = .{ .pane_uuid = pane_uuid };
        try wire.writeControl(fd, .session_remove_float, std.mem.asBytes(&msg));
    }

    pub fn sessionSyncTabLayout(
        self: *SesClient,
        tab_uuid: [32]u8,
        active_tab: usize,
        focused_pane_uuid: ?[32]u8,
        root_json: []const u8,
    ) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.SessionSyncTabLayout = .{
            .tab_uuid = tab_uuid,
            .focused_pane_uuid = if (focused_pane_uuid) |uuid| uuid else .{0} ** 32,
            .active_tab = @intCast(active_tab),
            .root_len = @intCast(root_json.len),
            .has_focused_pane = if (focused_pane_uuid != null) 1 else 0,
        };
        try wire.writeControlWithTrail(fd, .session_sync_tab_layout, std.mem.asBytes(&msg), root_json);
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
        _: ?[]const []const u8, // env (unused in binary protocol — pod inherits)
        isolation_profile: ?[]const u8,
        inherit_env_parent_uuid: ?[32]u8,
    ) !struct { uuid: [32]u8, pane_id: u16, pid: posix.pid_t } {
        const fd = self.ctl_fd orelse return error.NotConnected;

        const shell_bytes = shell orelse "";
        const cwd_bytes = cwd orelse "";
        const sticky_pwd_bytes = sticky_pwd orelse "";
        const isolation_profile_bytes = isolation_profile orelse "";
        const parent_uuid_bytes: []const u8 = if (inherit_env_parent_uuid) |*u| u[0..] else "";

        var msg: wire.CreatePane = .{
            .shell_len = @intCast(shell_bytes.len),
            .cwd_len = @intCast(cwd_bytes.len),
            .sticky_key = sticky_key orelse 0,
            .sticky_pwd_len = @intCast(sticky_pwd_bytes.len),
            .isolation_profile_len = @intCast(isolation_profile_bytes.len),
            .inherit_env_parent_uuid_len = @intCast(parent_uuid_bytes.len),
        };
        const trails: []const []const u8 = &.{ shell_bytes, cwd_bytes, sticky_pwd_bytes, isolation_profile_bytes, parent_uuid_bytes };
        mux.debugLog("createPane: shell={s} cwd={s} isolation={s}", .{ shell_bytes, cwd_bytes, isolation_profile_bytes });
        try wire.writeControlMsg(fd, .create_pane, std.mem.asBytes(&msg), trails);

        // Read response.
        const hdr = try self.readSyncResponse(fd);
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type == .@"error") {
            self.skipPayload(fd, hdr.payload_len);
            return error.SesError;
        }
        if (resp_type != .pane_created) {
            self.skipPayload(fd, hdr.payload_len);
            return error.UnexpectedResponse;
        }

        const resp = try wire.readStruct(wire.PaneCreated, fd);
        // Skip socket_path (we don't need it — VT goes through SES).
        if (resp.socket_path_len > 0) {
            var skip_buf: [512]u8 = undefined;
            wire.readExact(fd, skip_buf[0..resp.socket_path_len]) catch {};
        }

        mux.debugLog("pane created: uuid={s} pane_id={d} pid={d}", .{ resp.uuid[0..8], resp.pane_id, resp.pid });
        return .{
            .uuid = resp.uuid,
            .pane_id = resp.pane_id,
            .pid = resp.pid,
        };
    }

    /// Find a sticky pane (for pwd floats).
    pub fn findStickyPane(self: *SesClient, pwd: []const u8, key: u8) !?struct { uuid: [32]u8, pane_id: u16, pid: posix.pid_t } {
        const fd = self.ctl_fd orelse return error.NotConnected;

        var msg: wire.FindSticky = .{
            .key = key,
            .pwd_len = @intCast(pwd.len),
        };
        try wire.writeControlWithTrail(fd, .find_sticky, std.mem.asBytes(&msg), pwd);

        const hdr = try self.readSyncResponse(fd);
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type == .pane_not_found) {
            self.skipPayload(fd, hdr.payload_len);
            return null;
        }
        if (resp_type != .pane_found) {
            self.skipPayload(fd, hdr.payload_len);
            return error.UnexpectedResponse;
        }

        const resp = try wire.readStruct(wire.PaneFound, fd);
        // Skip socket_path.
        if (resp.socket_path_len > 0) {
            var skip_buf: [512]u8 = undefined;
            wire.readExact(fd, skip_buf[0..@min(@as(usize, resp.socket_path_len), skip_buf.len)]) catch {};
        }

        return .{ .uuid = resp.uuid, .pane_id = resp.pane_id, .pid = resp.pid };
    }

    /// Orphan a pane (manual suspend).
    pub fn orphanPane(self: *SesClient, uuid: [32]u8) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.PaneUuid = .{ .uuid = uuid };
        try wire.writeControl(fd, .orphan_pane, std.mem.asBytes(&msg));
    }

    /// Set sticky info on a pane.
    pub fn setSticky(self: *SesClient, uuid: [32]u8, pwd: []const u8, key: u8) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.SetSticky = .{
            .uuid = uuid,
            .key = key,
            .pwd_len = @intCast(pwd.len),
        };
        try wire.writeControlWithTrail(fd, .set_sticky, std.mem.asBytes(&msg), pwd);
    }

    /// Kill a pane.
    pub fn killPane(self: *SesClient, uuid: [32]u8) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        mux.debugLogUuid(&uuid, "killPane: sending to SES ctl_fd={d} vt_fd={?d}", .{ fd, self.vt_fd });
        var msg: wire.PaneUuid = .{ .uuid = uuid };
        try wire.writeControl(fd, .kill_pane, std.mem.asBytes(&msg));
        mux.debugLogUuid(&uuid, "killPane: sent ok", .{});
    }

    /// Request pane CWD from ses (fire-and-forget; response handled in handleSesMessage).
    pub fn requestPaneCwd(self: *SesClient, uuid: [32]u8) void {
        const fd = self.ctl_fd orelse return;
        self.pending_cwd_uuid = uuid;
        var msg: wire.GetPaneCwd = .{ .uuid = uuid };
        wire.writeControl(fd, .get_pane_cwd, std.mem.asBytes(&msg)) catch return;
    }

    /// Synchronous CWD fetch — blocks until SES responds.
    /// Returns a slice into a static buffer (valid until next call).
    pub fn getPaneCwdSync(self: *SesClient, uuid: [32]u8) ?[]const u8 {
        const fd = self.ctl_fd orelse return null;
        var msg: wire.GetPaneCwd = .{ .uuid = uuid };
        wire.writeControl(fd, .get_pane_cwd, std.mem.asBytes(&msg)) catch return null;

        // Block-read response, skipping pending .ok / .get_pane_cwd (from earlier fire-and-forget).
        const hdr = blk: {
            while (true) {
                const h = wire.readControlHeader(fd) catch return null;
                const mt: wire.MsgType = @enumFromInt(h.msg_type);
                if (mt == .ok) {
                    self.skipPayload(fd, h.payload_len);
                    continue;
                }
                if (mt == .pane_exited) {
                    if (h.payload_len >= @sizeOf(wire.PaneUuid)) {
                        const pu = wire.readStruct(wire.PaneUuid, fd) catch {
                            self.skipPayload(fd, h.payload_len);
                            continue;
                        };
                        self.queuePendingPaneExit(pu.uuid);
                        const rem = h.payload_len - @sizeOf(wire.PaneUuid);
                        if (rem > 0) self.skipPayload(fd, rem);
                    } else {
                        self.skipPayload(fd, h.payload_len);
                    }
                    continue;
                }
                break :blk h;
            }
        };
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type != .get_pane_cwd or hdr.payload_len < @sizeOf(wire.PaneCwd)) {
            self.skipPayload(fd, hdr.payload_len);
            return null;
        }
        const resp = wire.readStruct(wire.PaneCwd, fd) catch return null;
        if (resp.cwd_len == 0) return null;
        if (resp.cwd_len > sync_cwd_buf.len) {
            self.skipPayload(fd, resp.cwd_len);
            return null;
        }
        wire.readExact(fd, sync_cwd_buf[0..resp.cwd_len]) catch return null;
        return sync_cwd_buf[0..resp.cwd_len];
    }

    /// Ping ses to check if it's alive.
    pub fn ping(self: *SesClient) !bool {
        const fd = self.ctl_fd orelse return false;
        try wire.writeControl(fd, .ping, &.{});

        const hdr = self.readSyncResponse(fd) catch return false;
        self.skipPayload(fd, hdr.payload_len);
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        return resp_type == .pong;
    }

    /// Update pane name in ses (fire-and-forget).
    pub fn updatePaneName(self: *SesClient, uuid: [32]u8, name: ?[]const u8) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        const name_bytes = name orelse "";
        var msg: wire.UpdatePaneName = .{
            .uuid = uuid,
            .name_len = @intCast(name_bytes.len),
        };
        try wire.writeControlWithTrail(fd, .update_pane_name, std.mem.asBytes(&msg), name_bytes);
    }

    /// Update shell-provided pane metadata (fire-and-forget).
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
        try wire.writeControlMsg(fd, .update_pane_shell, std.mem.asBytes(&msg), trails);
    }

    /// Pane type enum for auxiliary info.
    pub const PaneType = enum { split, float };
    pub const PaneAuxInfo = struct { created_from: ?[32]u8, focused_from: ?[32]u8 };
    pub const PaneInfoSnapshot = struct {
        pid: ?i32,
        name: ?[]u8,
        cwd: ?[]u8,
        fg_name: ?[]u8,
        fg_pid: ?i32,
    };
    pub const PaneProcessInfo = struct { name: ?[]u8 = null, pid: ?i32 = null };

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
        wire.writeControl(fd, .update_pane_aux, std.mem.asBytes(&msg)) catch {};
    }

    /// Get auxiliary pane info — queries SES for created_from/focused_from.
    pub fn getPaneAux(self: *SesClient, uuid: [32]u8) !PaneAuxInfo {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.PaneUuid = .{ .uuid = uuid };
        wire.writeControl(fd, .pane_info, std.mem.asBytes(&msg)) catch return error.WriteFailed;

        // Read pane_info response, skipping unrelated async messages.
        const hdr = self.readPaneInfoResponse(fd) catch return .{ .created_from = null, .focused_from = null };
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type != .pane_info or hdr.payload_len < @sizeOf(wire.PaneInfoResp)) {
            self.skipPayload(fd, hdr.payload_len);
            return .{ .created_from = null, .focused_from = null };
        }
        const resp = wire.readStruct(wire.PaneInfoResp, fd) catch return .{ .created_from = null, .focused_from = null };
        // Skip trailing data.
        const trail_len = hdr.payload_len - @sizeOf(wire.PaneInfoResp);
        if (trail_len > 0) self.skipPayload(fd, @intCast(trail_len));

        return .{
            .created_from = if (resp.has_created_from != 0) resp.created_from else null,
            .focused_from = if (resp.has_focused_from != 0) resp.focused_from else null,
        };
    }

    /// Request foreground process info for a pane (fire-and-forget; response handled in handleSesMessage).
    pub fn requestPaneProcess(self: *SesClient, uuid: [32]u8) void {
        const fd = self.ctl_fd orelse return;
        var msg: wire.PaneUuid = .{ .uuid = uuid };
        wire.writeControl(fd, .pane_info, std.mem.asBytes(&msg)) catch return;
    }

    /// Best-effort pane name (sync call, skips pending .ok/.get_pane_cwd responses).
    pub fn getPaneName(self: *SesClient, uuid: [32]u8) ?[]u8 {
        const fd = self.ctl_fd orelse return null;
        var msg: wire.PaneUuid = .{ .uuid = uuid };
        wire.writeControl(fd, .pane_info, std.mem.asBytes(&msg)) catch return null;

        // Read response, skipping fire-and-forget acks (but NOT .pane_info).
        const hdr = blk: {
            while (true) {
                const h = wire.readControlHeader(fd) catch return null;
                const mt: wire.MsgType = @enumFromInt(h.msg_type);
                if (mt == .ok or mt == .get_pane_cwd) {
                    self.skipPayload(fd, h.payload_len);
                    continue;
                }
                break :blk h;
            }
        };
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type != .pane_info or hdr.payload_len < @sizeOf(wire.PaneInfoResp)) {
            self.skipPayload(fd, hdr.payload_len);
            return null;
        }
        const resp = wire.readStruct(wire.PaneInfoResp, fd) catch return null;
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
            wire.readExact(fd, buf) catch {
                self.allocator.free(buf);
                return null;
            };
            result = buf;
        }
        // Skip all remaining trailing bytes.
        const remaining = trail_total - @as(usize, resp.name_len);
        if (remaining > 0) {
            self.skipPayload(fd, @intCast(remaining));
        }
        return result;
    }

    /// Best-effort synchronous pane metadata snapshot.
    /// Returns owned strings that caller must free.
    pub fn getPaneInfoSnapshot(self: *SesClient, uuid: [32]u8) ?PaneInfoSnapshot {
        const fd = self.ctl_fd orelse return null;
        var msg: wire.PaneUuid = .{ .uuid = uuid };
        wire.writeControl(fd, .pane_info, std.mem.asBytes(&msg)) catch return null;

        // Read response directly — do NOT use readSyncResponse which skips
        // large pane_info responses (treating them as async noise).
        const hdr = self.readPaneInfoResponse(fd) catch return null;
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type != .pane_info or hdr.payload_len < @sizeOf(wire.PaneInfoResp)) {
            self.skipPayload(fd, hdr.payload_len);
            return null;
        }

        const resp = wire.readStruct(wire.PaneInfoResp, fd) catch return null;
        const trail_total: usize = @as(usize, resp.name_len) + @as(usize, resp.fg_len) +
            @as(usize, resp.cwd_len) + @as(usize, resp.tty_len) +
            @as(usize, resp.socket_path_len) + @as(usize, resp.session_name_len) +
            @as(usize, resp.layout_path_len) + @as(usize, resp.last_cmd_len) +
            @as(usize, resp.base_process_len) + @as(usize, resp.sticky_pwd_len);

        var consumed: usize = 0;
        var name: ?[]u8 = null;
        var fg_name: ?[]u8 = null;
        var cwd: ?[]u8 = null;

        if (resp.name_len > 0) {
            const n = @as(usize, resp.name_len);
            if (n <= 16 * 1024) {
                const buf = self.allocator.alloc(u8, n) catch return null;
                wire.readExact(fd, buf) catch {
                    self.allocator.free(buf);
                    return null;
                };
                name = buf;
            } else {
                self.skipPayloadU32(fd, resp.name_len);
            }
            consumed += n;
        }

        if (resp.fg_len > 0) {
            const n = @as(usize, resp.fg_len);
            if (n <= 16 * 1024) {
                const buf = self.allocator.alloc(u8, n) catch {
                    if (name) |s| self.allocator.free(s);
                    return null;
                };
                wire.readExact(fd, buf) catch {
                    self.allocator.free(buf);
                    if (name) |s| self.allocator.free(s);
                    return null;
                };
                fg_name = buf;
            } else {
                self.skipPayloadU32(fd, resp.fg_len);
            }
            consumed += n;
        }

        if (resp.cwd_len > 0) {
            const n = @as(usize, resp.cwd_len);
            if (n <= 64 * 1024) {
                const buf = self.allocator.alloc(u8, n) catch {
                    if (name) |s| self.allocator.free(s);
                    if (fg_name) |s| self.allocator.free(s);
                    return null;
                };
                wire.readExact(fd, buf) catch {
                    self.allocator.free(buf);
                    if (name) |s| self.allocator.free(s);
                    if (fg_name) |s| self.allocator.free(s);
                    return null;
                };
                cwd = buf;
            } else {
                self.skipPayloadU32(fd, resp.cwd_len);
            }
            consumed += n;
        }

        const remaining = trail_total -| consumed;
        if (remaining > 0) self.skipPayload(fd, @intCast(remaining));

        return .{
            .pid = if (resp.pid != 0) resp.pid else null,
            .name = name,
            .cwd = cwd,
            .fg_name = fg_name,
            .fg_pid = if (resp.fg_pid != 0) resp.fg_pid else null,
        };
    }

    /// Adopt an orphaned pane.
    pub fn adoptPane(self: *SesClient, uuid: [32]u8) !struct { uuid: [32]u8, pane_id: u16, pid: posix.pid_t } {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.PaneUuid = .{ .uuid = uuid };
        try wire.writeControl(fd, .adopt_pane, std.mem.asBytes(&msg));

        const hdr = try self.readSyncResponse(fd);
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type == .@"error") {
            self.skipPayload(fd, hdr.payload_len);
            return error.SesError;
        }
        if (resp_type != .pane_found) {
            self.skipPayload(fd, hdr.payload_len);
            return error.UnexpectedResponse;
        }

        const resp = try wire.readStruct(wire.PaneFound, fd);
        if (resp.socket_path_len > 0) {
            var skip_buf: [512]u8 = undefined;
            wire.readExact(fd, skip_buf[0..@min(@as(usize, resp.socket_path_len), skip_buf.len)]) catch {};
        }
        return .{ .uuid = uuid, .pane_id = resp.pane_id, .pid = resp.pid };
    }

    /// List orphaned panes.
    pub fn listOrphanedPanes(self: *SesClient, out_buf: []OrphanedPaneInfo) !usize {
        const fd = self.ctl_fd orelse return error.NotConnected;
        try wire.writeControl(fd, .list_orphaned, &.{});

        const hdr = try self.readSyncResponse(fd);
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type != .orphaned_panes) {
            self.skipPayload(fd, hdr.payload_len);
            return error.UnexpectedResponse;
        }

        const resp = try wire.readStruct(wire.OrphanedPanes, fd);
        var count: usize = 0;
        for (0..resp.pane_count) |_| {
            const entry = wire.readStruct(wire.OrphanedPaneEntry, fd) catch break;
            if (count < out_buf.len) {
                out_buf[count] = .{ .uuid = entry.uuid, .pid = entry.pid };
                count += 1;
            }
        }
        return count;
    }

    /// Detach session — keeps panes grouped for later reattach.
    pub fn detachSession(self: *SesClient, session_id: [32]u8, mux_state_json: []const u8) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;

        // Convert 32-char hex session_id to 16 binary bytes for the struct.
        var msg: wire.Detach = .{
            .session_id = session_id,
            .state_len = @intCast(mux_state_json.len),
        };
        try wire.writeControlWithTrail(fd, .detach, std.mem.asBytes(&msg), mux_state_json);

        const hdr = try self.readSyncResponse(fd);
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type == .@"error") {
            self.skipPayload(fd, hdr.payload_len);
            return error.DetachFailed;
        }
        self.skipPayload(fd, hdr.payload_len);
    }

    /// Result of reattaching a session.
    pub const ReattachResult = struct {
        session_state_json: []const u8, // Owned — caller must free
        pane_uuids: [][32]u8, // Owned — caller must free
    };

    /// Reattach to a detached session.
    pub fn reattachSession(self: *SesClient, session_id: []const u8) !?ReattachResult {
        const fd = self.ctl_fd orelse {
            mux.debugLog("reattachSession: not connected (ctl_fd is null)", .{});
            return error.NotConnected;
        };

        mux.debugLog("reattachSession: sending reattach request for id={s} len={d}", .{ session_id, session_id.len });

        var msg: wire.Reattach = .{
            .id_len = @intCast(session_id.len),
        };
        wire.writeControlWithTrail(fd, .reattach, std.mem.asBytes(&msg), session_id) catch |e| {
            mux.debugLog("reattachSession: writeControlWithTrail failed: {s}", .{@errorName(e)});
            return e;
        };

        // Reattach can trigger SES to start backlog replaying pods almost
        // immediately. During that time SES may also send async `.ok` acks.
        // If we block waiting for `.session_reattached` while those acks pile
        // up, we risk a read deadlock (user-visible as a frozen shell).
        //
        // We explicitly skip `.ok`/`.get_pane_cwd`/async `.pane_info` here.
        mux.debugLog("reattachSession: waiting for response...", .{});
        const hdr = blk: {
            while (true) {
                const h = self.readSyncResponse(fd) catch |e| {
                    mux.debugLog("reattachSession: readSyncResponse failed: {s}", .{@errorName(e)});
                    return e;
                };
                const mt: wire.MsgType = @enumFromInt(h.msg_type);
                mux.debugLog("reattachSession: got msg_type={d} payload_len={d}", .{ h.msg_type, h.payload_len });
                if (mt == .ok or mt == .get_pane_cwd) {
                    self.skipPayload(fd, h.payload_len);
                    continue;
                }
                if (mt == .pane_info and h.payload_len >= @sizeOf(wire.PaneInfoResp)) {
                    self.skipPayload(fd, h.payload_len);
                    continue;
                }
                break :blk h;
            }
        };
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        mux.debugLog("reattachSession: final response type={d}", .{hdr.msg_type});
        if (resp_type == .@"error") {
            mux.debugLog("reattachSession: server returned error", .{});
            self.skipPayload(fd, hdr.payload_len);
            return null;
        }
        if (resp_type != .session_reattached) {
            mux.debugLog("reattachSession: unexpected response type {d}, expected session_reattached", .{hdr.msg_type});
            self.skipPayload(fd, hdr.payload_len);
            return error.UnexpectedResponse;
        }

        const resp = wire.readStruct(wire.SessionReattached, fd) catch |e| {
            mux.debugLog("reattachSession: failed to read SessionReattached struct: {s}", .{@errorName(e)});
            return e;
        };
        mux.debugLog("reattachSession: got SessionReattached state_len={d} pane_count={d}", .{ resp.state_len, resp.pane_count });

        // Read canonical session snapshot JSON.
        const session_state = self.allocator.alloc(u8, resp.state_len) catch return error.OutOfMemory;
        errdefer self.allocator.free(session_state);
        wire.readExact(fd, session_state) catch |e| {
            mux.debugLog("reattachSession: failed to read session_state_json: {s}", .{@errorName(e)});
            return e;
        };
        mux.debugLog("reattachSession: read session_state_json ({d} bytes)", .{session_state.len});

        // Read pane UUIDs (each 32 bytes).
        var pane_uuids = self.allocator.alloc([32]u8, resp.pane_count) catch return error.OutOfMemory;
        errdefer self.allocator.free(pane_uuids);
        for (0..resp.pane_count) |i| {
            wire.readExact(fd, &pane_uuids[i]) catch |e| {
                mux.debugLog("reattachSession: failed to read pane uuid {d}: {s}", .{ i, @errorName(e) });
                return e;
            };
        }
        mux.debugLog("reattachSession: read {d} pane UUIDs, success!", .{resp.pane_count});

        return .{
            .session_state_json = session_state,
            .pane_uuids = pane_uuids,
        };
    }

    /// List detached sessions.
    pub fn listSessions(self: *SesClient, out_buf: []DetachedSessionInfo) !usize {
        const fd = self.ctl_fd orelse return error.NotConnected;
        try wire.writeControl(fd, .list_sessions, &.{});

        const hdr = try self.readSyncResponse(fd);
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type != .sessions_list) {
            self.skipPayload(fd, hdr.payload_len);
            return error.UnexpectedResponse;
        }

        const resp = try wire.readStruct(wire.SessionsList, fd);
        var count: usize = 0;
        for (0..resp.session_count) |_| {
            const entry = wire.readStruct(wire.SessionEntry, fd) catch break;
            var info: DetachedSessionInfo = undefined;
            info.session_id = entry.session_id;
            info.pane_count = entry.pane_count;
            // Read name.
            const name_len = @min(@as(usize, entry.name_len), 32);
            if (entry.name_len > 0) {
                var name_buf: [32]u8 = undefined;
                wire.readExact(fd, name_buf[0..name_len]) catch break;
                @memcpy(info.session_name[0..name_len], name_buf[0..name_len]);
                info.session_name_len = name_len;
                // Skip excess name bytes.
                if (entry.name_len > 32) {
                    self.skipPayloadU16(fd, entry.name_len - 32);
                }
            } else {
                info.session_name_len = 0;
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
        if (self.debug) {
            try args_list.append(self.allocator, "--debug");
        }
        if (self.log_file) |path| {
            if (path.len > 0) {
                try args_list.append(self.allocator, "--logfile");
                try args_list.append(self.allocator, path);
            }
        }

        var child = std.process.Child.init(args_list.items, std.heap.page_allocator);
        child.spawn() catch |err| {
            mux.debugLog("failed to start ses daemon: {s}", .{@errorName(err)});
            return err;
        };
        _ = child.wait() catch {};
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
            mux.debugLog("CTL channel not available (disconnected)", .{});
            return false;
        }
        return true;
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    /// Read a response from the CTL fd, skipping any fire-and-forget response
    /// types that may have arrived before our expected response.
    /// Read a pane_info response, skipping unrelated async messages but NOT
    /// skipping pane_info responses (which readSyncResponse incorrectly skips).
    fn readPaneInfoResponse(self: *SesClient, fd: posix.fd_t) !wire.ControlHeader {
        while (true) {
            const hdr = try wire.readControlHeader(fd);
            const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
            switch (msg_type) {
                .ok, .get_pane_cwd => {
                    self.skipPayload(fd, hdr.payload_len);
                    continue;
                },
                .pane_exited => {
                    if (hdr.payload_len >= @sizeOf(wire.PaneUuid)) {
                        const pu = wire.readStruct(wire.PaneUuid, fd) catch {
                            self.skipPayload(fd, hdr.payload_len);
                            continue;
                        };
                        self.queuePendingPaneExit(pu.uuid);
                        const rem = hdr.payload_len - @sizeOf(wire.PaneUuid);
                        if (rem > 0) self.skipPayload(fd, rem);
                    } else {
                        self.skipPayload(fd, hdr.payload_len);
                    }
                    continue;
                },
                // Return pane_info directly — this is what we're waiting for.
                else => return hdr,
            }
        }
    }

    fn readSyncResponse(self: *SesClient, fd: posix.fd_t) !wire.ControlHeader {
        while (true) {
            const hdr = try wire.readControlHeader(fd);
            const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
            switch (msg_type) {
                // Fire-and-forget acks from syncState/updatePaneName/updatePaneShell.
                .ok => {
                    self.skipPayload(fd, hdr.payload_len);
                    continue;
                },
                // Async get_pane_cwd response.
                .get_pane_cwd => {
                    self.skipPayload(fd, hdr.payload_len);
                    continue;
                },
                // Async pane_info response (large payload = response, not request).
                .pane_info => {
                    if (hdr.payload_len >= @sizeOf(wire.PaneInfoResp)) {
                        self.skipPayload(fd, hdr.payload_len);
                        continue;
                    }
                    return hdr;
                },
                .pane_exited => {
                    if (hdr.payload_len >= @sizeOf(wire.PaneUuid)) {
                        const pu = wire.readStruct(wire.PaneUuid, fd) catch {
                            self.skipPayload(fd, hdr.payload_len);
                            continue;
                        };
                        self.queuePendingPaneExit(pu.uuid);
                        const rem = hdr.payload_len - @sizeOf(wire.PaneUuid);
                        if (rem > 0) self.skipPayload(fd, rem);
                    } else {
                        self.skipPayload(fd, hdr.payload_len);
                    }
                    continue;
                },
                else => return hdr,
            }
        }
    }

    fn skipPayload(self: *SesClient, fd: posix.fd_t, len: u32) void {
        _ = self;
        var remaining: usize = len;
        var buf: [4096]u8 = undefined;
        while (remaining > 0) {
            const chunk = @min(remaining, buf.len);
            wire.readExact(fd, buf[0..chunk]) catch return;
            remaining -= chunk;
        }
    }

    fn skipPayloadU16(_: *SesClient, fd: posix.fd_t, len: u16) void {
        var remaining: usize = len;
        var buf: [4096]u8 = undefined;
        while (remaining > 0) {
            const chunk = @min(remaining, buf.len);
            wire.readExact(fd, buf[0..chunk]) catch return;
            remaining -= chunk;
        }
    }

    fn skipPayloadU32(self: *SesClient, fd: posix.fd_t, len: u32) void {
        self.skipPayload(fd, len);
    }

    /// Send a ping to SES to check connection is alive.
    /// Returns true if pong received, false if connection appears dead.
    pub fn sendPing(self: *SesClient) bool {
        const fd = self.ctl_fd orelse return false;
        wire.writeControl(fd, .ping, &.{}) catch return false;
        // Note: pong response will be received asynchronously and handled
        // by the IPC loop. We just check that the write succeeded.
        return true;
    }

    /// Request SES to trigger backlog replay for adopted panes.
    /// Called after reattachSession completes and MUX is ready to receive data.
    pub fn requestBacklogReplay(self: *SesClient) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        mux.debugLog("requestBacklogReplay: sending replay_backlogs", .{});
        try wire.writeControl(fd, .replay_backlogs, &.{});

        // Fire-and-forget: Don't wait for .ok response.
        // This is called BEFORE MUX enters its event loop during reattach.
        // Since the ctl_fd is non-blocking and no event loop is running yet,
        // any blocking read would busy-spin forever. The .ok from SES will
        // arrive later and be handled normally by the event loop.
        mux.debugLog("requestBacklogReplay: sent (fire-and-forget)", .{});
    }
};

pub const OrphanedPaneInfo = struct {
    uuid: [32]u8,
    pid: posix.pid_t,
};

pub const DetachedSessionInfo = struct {
    session_id: [32]u8,
    session_name: [32]u8,
    session_name_len: usize,
    pane_count: usize,
};
