const std = @import("std");
const connection = @import("../connection.zig");
const channels = @import("../channels/channels.zig");
const channel_protocol = @import("../protocol/channel.zig");
const wire = @import("../protocol/wire.zig");
const pty = @import("../platform/pty.zig");
const user = @import("../platform/user.zig");
const sftp = @import("../sftp/sftp.zig");

pub const SessionMode = enum {
    shell,
    exec,
    subsystem_sftp,
};

const PtyRequestInfo = struct {
    term: []const u8,
    width_chars: u32,
    height_rows: u32,
    width_pixels: u32,
    height_pixels: u32,
    modes: []const u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *PtyRequestInfo) void {
        self.allocator.free(self.term);
        self.allocator.free(self.modes);
    }
};

const SessionEnvInfo = struct {
    lang: ?[]u8 = null,
    lc_all: ?[]u8 = null,
    lc_ctype: ?[]u8 = null,
    colorterm: ?[]u8 = null,
    allocator: std.mem.Allocator,

    fn deinit(self: *SessionEnvInfo) void {
        if (self.lang) |value| self.allocator.free(value);
        if (self.lc_all) |value| self.allocator.free(value);
        if (self.lc_ctype) |value| self.allocator.free(value);
        if (self.colorterm) |value| self.allocator.free(value);
    }

    fn set(self: *SessionEnvInfo, name: []const u8, value: []const u8) !void {
        const copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(copy);

        if (std.mem.eql(u8, name, "LANG")) {
            if (self.lang) |old| self.allocator.free(old);
            self.lang = copy;
            return;
        }
        if (std.mem.eql(u8, name, "LC_ALL")) {
            if (self.lc_all) |old| self.allocator.free(old);
            self.lc_all = copy;
            return;
        }
        if (std.mem.eql(u8, name, "LC_CTYPE")) {
            if (self.lc_ctype) |old| self.allocator.free(old);
            self.lc_ctype = copy;
            return;
        }
        if (std.mem.eql(u8, name, "COLORTERM")) {
            if (self.colorterm) |old| self.allocator.free(old);
            self.colorterm = copy;
            return;
        }

        self.allocator.free(copy);
        return error.UnsupportedEnvironmentVariable;
    }
};

const PtySession = struct {
    pty: *pty.Pty,
    pid: std.posix.pid_t,
    allocator: std.mem.Allocator,

    fn deinit(self: *PtySession) void {
        // Send SIGTERM so the child shell exits cleanly
        std.posix.kill(self.pid, std.posix.SIG.TERM) catch {};

        // Give the process a moment to exit gracefully
        var exited = false;
        for (0..10) |_| {
            const wait_result = std.posix.waitpid(self.pid, std.c.W.NOHANG);
            if (wait_result.pid != 0) {
                exited = true;
                break;
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        // Force kill if still running
        if (!exited) {
            std.posix.kill(self.pid, std.posix.SIG.KILL) catch {};
            _ = std.posix.waitpid(self.pid, 0);
        }

        self.pty.deinit();
        self.allocator.destroy(self.pty);
    }
};

pub const SessionRuntime = struct {
    allocator: std.mem.Allocator,
    authenticated_user: []u8,

    active_shells: std.AutoHashMap(u64, PtySession),
    active_exec: std.AutoHashMap(u64, []u8),
    session_modes: std.AutoHashMap(u64, SessionMode),
    pty_requests: std.AutoHashMap(u64, PtyRequestInfo),
    session_env: std.AutoHashMap(u64, SessionEnvInfo),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, authenticated_user: []const u8) !Self {
        return .{
            .allocator = allocator,
            .authenticated_user = try allocator.dupe(u8, authenticated_user),
            .active_shells = std.AutoHashMap(u64, PtySession).init(allocator),
            .active_exec = std.AutoHashMap(u64, []u8).init(allocator),
            .session_modes = std.AutoHashMap(u64, SessionMode).init(allocator),
            .pty_requests = std.AutoHashMap(u64, PtyRequestInfo).init(allocator),
            .session_env = std.AutoHashMap(u64, SessionEnvInfo).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var shell_it = self.active_shells.iterator();
        while (shell_it.next()) |entry| {
            var session = entry.value_ptr.*;
            session.deinit();
        }
        self.active_shells.deinit();

        var exec_it = self.active_exec.iterator();
        while (exec_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.active_exec.deinit();

        var pty_it = self.pty_requests.iterator();
        while (pty_it.next()) |entry| {
            var info = entry.value_ptr.*;
            info.deinit();
        }
        self.pty_requests.deinit();

        var env_it = self.session_env.iterator();
        while (env_it.next()) |entry| {
            var info = entry.value_ptr.*;
            info.deinit();
        }
        self.session_env.deinit();

        self.session_modes.deinit();
        self.allocator.free(self.authenticated_user);
    }

    pub fn run(self: *Self, server_conn: *connection.ServerConnection) !void {
        const stream_id = try self.waitForSessionChannel(server_conn, 30000);

        if (self.active_shells.fetchRemove(stream_id)) |entry| {
            var old = entry.value;
            old.deinit();
        }

        var session_started = false;
        const session_deadline = std.time.milliTimestamp() + 30000;
        while (!session_started) {
            if (std.time.milliTimestamp() >= session_deadline) {
                return error.SessionRequestTimeout;
            }

            server_conn.transport.poll(100) catch {};

            var buffer: [4096]u8 = undefined;
            const len = server_conn.transport.receiveFromStream(stream_id, &buffer) catch 0;
            if (len == 0) continue;

            var request_info = try server_conn.channel_manager.handleRequest(stream_id, buffer[0..len]);
            defer request_info.deinit(self.allocator);

            self.handleRequest(server_conn, stream_id, &request_info) catch |err| {
                std.log.debug("Session request handling error: {}", .{err});
            };

            if (self.session_modes.get(stream_id)) |_| {
                session_started = true;
            }
        }

        const mode = self.session_modes.get(stream_id) orelse return error.NoSessionMode;
        switch (mode) {
            .shell => try self.bridgeSession(server_conn, stream_id),
            .exec => try self.runExecRequest(server_conn, stream_id),
            .subsystem_sftp => try self.runSftpSubsystem(server_conn, stream_id),
        }
    }

    fn waitForSessionChannel(self: *Self, server_conn: *connection.ServerConnection, timeout_ms: u32) !u64 {
        _ = self;

        const deadline_ms = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (std.time.milliTimestamp() < deadline_ms) {
            server_conn.transport.poll(50) catch {};

            const stream_id = server_conn.acceptChannel() catch |err| {
                std.log.debug("acceptChannel while waiting for session: {}", .{err});
                std.Thread.sleep(2 * std.time.ns_per_ms);
                continue;
            };
            return stream_id;
        }

        return error.ChannelAcceptTimeout;
    }

    fn handleRequest(self: *Self, server_conn: *connection.ServerConnection, stream_id: u64, request_info: *channels.ChannelRequestInfo) !void {
        const req = request_info.request;
        const want_reply = req.want_reply;

        if (std.mem.eql(u8, req.request_type, "pty-req")) {
            self.handlePtyRequest(stream_id, req.type_specific_data) catch |err| {
                if (want_reply) server_conn.channel_manager.sendFailure(stream_id) catch {};
                return err;
            };
        } else if (std.mem.eql(u8, req.request_type, "env")) {
            self.handleEnvRequest(stream_id, req.type_specific_data) catch |err| {
                if (want_reply) server_conn.channel_manager.sendFailure(stream_id) catch {};
                return err;
            };
        } else if (std.mem.eql(u8, req.request_type, "shell")) {
            self.handleShellRequest(stream_id) catch |err| {
                if (want_reply) server_conn.channel_manager.sendFailure(stream_id) catch {};
                return err;
            };
        } else if (std.mem.eql(u8, req.request_type, "window-change")) {
            self.handleWindowChange(stream_id, req.type_specific_data) catch |err| {
                if (want_reply) server_conn.channel_manager.sendFailure(stream_id) catch {};
                return err;
            };
        } else if (std.mem.eql(u8, req.request_type, "exec")) {
            var reader = wire.Reader{ .buffer = req.type_specific_data };
            const command = reader.readString(self.allocator) catch |err| {
                if (want_reply) server_conn.channel_manager.sendFailure(stream_id) catch {};
                return err;
            };
            defer self.allocator.free(command);
            self.handleExecRequest(stream_id, command) catch |err| {
                if (want_reply) server_conn.channel_manager.sendFailure(stream_id) catch {};
                return err;
            };
        } else if (std.mem.eql(u8, req.request_type, "subsystem")) {
            var reader = wire.Reader{ .buffer = req.type_specific_data };
            const subsystem_name = reader.readString(self.allocator) catch |err| {
                if (want_reply) server_conn.channel_manager.sendFailure(stream_id) catch {};
                return err;
            };
            defer self.allocator.free(subsystem_name);
            if (!std.mem.eql(u8, subsystem_name, "sftp")) {
                if (want_reply) server_conn.channel_manager.sendFailure(stream_id) catch {};
                return error.UnsupportedSubsystem;
            }
            try self.session_modes.put(stream_id, .subsystem_sftp);
        } else {
            if (want_reply) server_conn.channel_manager.sendFailure(stream_id) catch {};
            return error.UnsupportedRequest;
        }

        if (want_reply) {
            server_conn.channel_manager.sendSuccess(stream_id) catch {};
        }
    }

    fn handlePtyRequest(self: *Self, stream_id: u64, type_specific_data: []const u8) !void {
        var reader = wire.Reader{ .buffer = type_specific_data };
        const term = try reader.readString(self.allocator);
        errdefer self.allocator.free(term);
        const width_chars = try reader.readUint32();
        const height_rows = try reader.readUint32();
        const width_pixels = try reader.readUint32();
        const height_pixels = try reader.readUint32();
        const modes = try reader.readString(self.allocator);
        errdefer self.allocator.free(modes);

        const info = PtyRequestInfo{
            .term = try self.allocator.dupe(u8, term),
            .width_chars = width_chars,
            .height_rows = height_rows,
            .width_pixels = width_pixels,
            .height_pixels = height_pixels,
            .modes = try self.allocator.dupe(u8, modes),
            .allocator = self.allocator,
        };

        if (self.pty_requests.fetchRemove(stream_id)) |entry| {
            var old = entry.value;
            old.deinit();
        }
        try self.pty_requests.put(stream_id, info);
    }

    fn handleEnvRequest(self: *Self, stream_id: u64, type_specific_data: []const u8) !void {
        var reader = wire.Reader{ .buffer = type_specific_data };
        const name = try reader.readString(self.allocator);
        defer self.allocator.free(name);
        const value = try reader.readString(self.allocator);
        defer self.allocator.free(value);

        if (!isAllowedEnvName(name) or !isValidEnvValue(value)) {
            return error.UnsupportedEnvironmentVariable;
        }

        var entry = try self.session_env.getOrPut(stream_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .allocator = self.allocator };
        }
        try entry.value_ptr.set(name, value);
    }

    fn handleShellRequest(self: *Self, stream_id: u64) !void {
        const pty_info = self.pty_requests.get(stream_id);

        const p = try self.allocator.create(pty.Pty);
        errdefer self.allocator.destroy(p);
        p.* = try pty.Pty.create(self.allocator);
        errdefer p.deinit();

        if (pty_info) |info| {
            try p.setWindowSize(@intCast(info.height_rows), @intCast(info.width_chars));
        } else {
            try p.setWindowSize(24, 80);
        }

        var account = try user.lookup(self.allocator, self.authenticated_user);
        defer account.deinit();

        var term_buf: [256]u8 = undefined;
        var lang_buf: [128]u8 = undefined;
        var lc_all_buf: [128]u8 = undefined;
        var lc_ctype_buf: [128]u8 = undefined;
        var colorterm_buf: [64]u8 = undefined;
        var term_ptr: [*:0]const u8 = "xterm-256color";
        var lang_ptr: ?[*:0]const u8 = null;
        var lc_all_ptr: ?[*:0]const u8 = null;
        var lc_ctype_ptr: ?[*:0]const u8 = null;
        var colorterm_ptr: ?[*:0]const u8 = null;
        if (pty_info) |info| {
            if (info.term.len > 0 and info.term.len < term_buf.len - 1 and isValidTermName(info.term)) {
                @memcpy(term_buf[0..info.term.len], info.term);
                term_buf[info.term.len] = 0;
                term_ptr = @ptrCast(term_buf[0..info.term.len :0]);
            }
        }
        if (self.session_env.get(stream_id)) |env_info| {
            lang_ptr = makeZString(&lang_buf, env_info.lang);
            lc_all_ptr = makeZString(&lc_all_buf, env_info.lc_all);
            lc_ctype_ptr = makeZString(&lc_ctype_buf, env_info.lc_ctype);
            colorterm_ptr = makeZString(&colorterm_buf, env_info.colorterm);
        }

        const shell_env = pty.ShellEnv{
            .term = term_ptr,
            .home = account.home_z.ptr,
            .shell = account.shell_z.ptr,
            .user = account.username_z.ptr,
            .logname = account.username_z.ptr,
            .lang = lang_ptr,
            .lc_all = lc_all_ptr,
            .lc_ctype = lc_ctype_ptr,
            .colorterm = colorterm_ptr,
            .uid = account.uid,
            .gid = account.gid,
            .modes = if (pty_info) |info| info.modes else null,
        };

        const pid = try pty.spawnShell(p, shell_env);

        try self.active_shells.put(stream_id, .{
            .pty = p,
            .pid = pid,
            .allocator = self.allocator,
        });
        try self.session_modes.put(stream_id, .shell);
    }

    fn handleWindowChange(self: *Self, stream_id: u64, type_specific_data: []const u8) !void {
        var reader = wire.Reader{ .buffer = type_specific_data };
        const width_chars = try reader.readUint32();
        const height_rows = try reader.readUint32();
        const width_pixels = try reader.readUint32();
        const height_pixels = try reader.readUint32();

        if (self.active_shells.getPtr(stream_id)) |session| {
            try session.pty.setWindowSize(@intCast(height_rows), @intCast(width_chars));
        }

        if (self.pty_requests.getPtr(stream_id)) |info| {
            info.width_chars = width_chars;
            info.height_rows = height_rows;
            info.width_pixels = width_pixels;
            info.height_pixels = height_pixels;
        }
    }

    fn handleExecRequest(self: *Self, stream_id: u64, command: []const u8) !void {
        const command_copy = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(command_copy);

        if (self.active_exec.fetchRemove(stream_id)) |entry| {
            self.allocator.free(entry.value);
        }

        try self.active_exec.put(stream_id, command_copy);
        try self.session_modes.put(stream_id, .exec);
    }

    fn sendExitStatus(server_conn: *connection.ServerConnection, stream_id: u64, status: u32) !void {
        var status_data: [4]u8 = undefined;
        std.mem.writeInt(u32, &status_data, status, .big);
        try server_conn.channel_manager.sendRequest(stream_id, "exit-status", false, &status_data);
    }

    fn runExecRequest(self: *Self, server_conn: *connection.ServerConnection, stream_id: u64) !void {
        const command = if (self.active_exec.fetchRemove(stream_id)) |entry|
            entry.value
        else
            return error.MissingExecRequest;
        defer self.allocator.free(command);

        var account = try user.lookup(self.allocator, self.authenticated_user);
        defer account.deinit();

        const result = try user.runCommandAsUser(self.allocator, &account, command, 16 * 1024 * 1024);
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.stdout.len > 0) {
            try server_conn.channel_manager.sendData(stream_id, result.stdout);
        }
        if (result.stderr.len > 0) {
            try server_conn.channel_manager.sendExtendedData(stream_id, 1, result.stderr);
        }

        var exit_code: u32 = 1;
        switch (result.term) {
            .Exited => |code| exit_code = code,
            .Signal => |sig| exit_code = 128 + @as(u32, @intCast(sig)),
            else => {},
        }

        try sendExitStatus(server_conn, stream_id, exit_code);
        server_conn.channel_manager.sendEof(stream_id) catch {};
        server_conn.channel_manager.closeChannel(stream_id) catch {};
        if (self.session_env.fetchRemove(stream_id)) |entry| {
            var info = entry.value;
            info.deinit();
        }
        if (self.pty_requests.fetchRemove(stream_id)) |entry| {
            var info = entry.value;
            info.deinit();
        }
        _ = self.session_modes.fetchRemove(stream_id);
    }

    fn runSftpSubsystem(self: *Self, server_conn: *connection.ServerConnection, stream_id: u64) !void {
        var root_buf: [4096]u8 = undefined;
        var derived_root: ?[]u8 = null;
        defer if (derived_root) |root| self.allocator.free(root);

        const sftp_root = std.process.getEnvVarOwned(self.allocator, "SL_SFTP_ROOT") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        defer if (sftp_root) |root| self.allocator.free(root);

        const remote_root = if (sftp_root) |root|
            root
        else blk: {
            if (user.lookup(self.allocator, self.authenticated_user)) |account| {
                defer {
                    var m = account;
                    m.deinit();
                }
                derived_root = try self.allocator.dupe(u8, account.home_z);
                break :blk derived_root.?;
            } else |_| {}

            const cwd = try std.posix.getcwd(&root_buf);
            break :blk cwd;
        };

        const session_channel = channels.SessionChannel{
            .manager = &server_conn.channel_manager,
            .stream_id = stream_id,
            .allocator = self.allocator,
        };

        const sftp_channel = sftp.SftpChannel.init(self.allocator, session_channel);
        var sftp_server = try sftp.SftpServer.initWithOptions(self.allocator, sftp_channel, .{ .remote_root = remote_root });
        defer sftp_server.deinit();

        sftp_server.run() catch |err| {
            if (err != error.EndOfStream and err != error.ConnectionClosed) return err;
        };

        server_conn.channel_manager.sendEof(stream_id) catch {};
        server_conn.channel_manager.closeChannel(stream_id) catch {};
        if (self.session_env.fetchRemove(stream_id)) |entry| {
            var info = entry.value;
            info.deinit();
        }
        if (self.pty_requests.fetchRemove(stream_id)) |entry| {
            var info = entry.value;
            info.deinit();
        }
        _ = self.session_modes.fetchRemove(stream_id);
    }

    fn isValidTermName(term: []const u8) bool {
        for (term) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') {
                return false;
            }
        }
        return true;
    }

    fn isAllowedEnvName(name: []const u8) bool {
        return std.mem.eql(u8, name, "LANG") or
            std.mem.eql(u8, name, "LC_ALL") or
            std.mem.eql(u8, name, "LC_CTYPE") or
            std.mem.eql(u8, name, "COLORTERM");
    }

    fn isValidEnvValue(value: []const u8) bool {
        if (value.len == 0 or value.len > 96) return false;

        for (value) |ch| {
            if (ch == 0) return false;
            if (ch < 0x20 or ch == 0x7f) return false;
        }

        return true;
    }

    fn makeZString(buffer: []u8, value: ?[]const u8) ?[*:0]const u8 {
        const slice = value orelse return null;
        if (slice.len == 0 or slice.len >= buffer.len) return null;

        @memcpy(buffer[0..slice.len], slice);
        buffer[slice.len] = 0;
        return @ptrCast(buffer[0..slice.len :0]);
    }

    fn nextClientChannelMessageLen(buffer: []const u8) !?usize {
        if (buffer.len < 1) return null;

        return switch (buffer[0]) {
            94 => blk: {
                if (buffer.len < 5) break :blk null;
                const payload_len = (@as(u32, buffer[1]) << 24) |
                    (@as(u32, buffer[2]) << 16) |
                    (@as(u32, buffer[3]) << 8) |
                    @as(u32, buffer[4]);
                const total = 5 + @as(usize, @intCast(payload_len));
                if (buffer.len < total) break :blk null;
                break :blk total;
            },
            98 => blk: {
                const req_type_end = parseWireStringEnd(buffer, 1) orelse break :blk null;
                if (buffer.len < req_type_end + 1) break :blk null;

                const req_type = buffer[5..req_type_end];
                var idx = req_type_end + 1;

                if (std.mem.eql(u8, req_type, "window-change")) {
                    if (buffer.len < idx + 16) break :blk null;
                    break :blk idx + 16;
                }

                if (std.mem.eql(u8, req_type, "shell")) {
                    break :blk idx;
                }

                if (std.mem.eql(u8, req_type, "exec") or std.mem.eql(u8, req_type, "subsystem") or std.mem.eql(u8, req_type, "signal")) {
                    const field_end = parseWireStringEnd(buffer, idx) orelse break :blk null;
                    break :blk field_end;
                }

                if (std.mem.eql(u8, req_type, "env")) {
                    const name_end = parseWireStringEnd(buffer, idx) orelse break :blk null;
                    const value_end = parseWireStringEnd(buffer, name_end) orelse break :blk null;
                    break :blk value_end;
                }

                if (std.mem.eql(u8, req_type, "pty-req")) {
                    const term_end = parseWireStringEnd(buffer, idx) orelse break :blk null;
                    if (buffer.len < term_end + 16) break :blk null;
                    idx = term_end + 16;
                    const modes_end = parseWireStringEnd(buffer, idx) orelse break :blk null;
                    break :blk modes_end;
                }

                break :blk null;
            },
            96, 97 => 1,
            else => 1,
        };
    }

    fn parseWireStringEnd(buffer: []const u8, start: usize) ?usize {
        if (buffer.len < start + 4) return null;
        const field_len = (@as(u32, buffer[start]) << 24) |
            (@as(u32, buffer[start + 1]) << 16) |
            (@as(u32, buffer[start + 2]) << 8) |
            @as(u32, buffer[start + 3]);
        const end = start + 4 + @as(usize, @intCast(field_len));
        if (buffer.len < end) return null;
        return end;
    }

    fn writeAllToPty(p: *pty.Pty, data: []const u8) !void {
        var written: usize = 0;
        var stall_count: u32 = 0;

        while (written < data.len) {
            const chunk_len = p.write(data[written..]) catch |err| {
                if (err == error.WouldBlock) {
                    stall_count += 1;
                    if (stall_count > 4000) return error.PtyWriteStalled;
                    std.Thread.sleep(250 * std.time.ns_per_us);
                    continue;
                }
                return err;
            };

            if (chunk_len == 0) {
                stall_count += 1;
                if (stall_count > 4000) return error.PtyWriteStalled;
                std.Thread.sleep(250 * std.time.ns_per_us);
                continue;
            }

            written += chunk_len;
            stall_count = 0;
        }
    }

    fn sendPtyOutput(server_conn: *connection.ServerConnection, stream_id: u64, data: []const u8) !void {
        const max_chunk_len = 900;
        var offset: usize = 0;

        while (offset < data.len) {
            const end = @min(offset + max_chunk_len, data.len);
            try server_conn.channel_manager.sendData(stream_id, data[offset..end]);
            offset = end;
        }
    }

    fn bridgeSession(self: *Self, server_conn: *connection.ServerConnection, stream_id: u64) !void {
        const session = self.active_shells.get(stream_id) orelse return error.NoPtyForSession;
        const p = session.pty;

        var pty_buffer: [16384]u8 = undefined;
        var channel_buffer: [16384]u8 = undefined;
        var pending_client = std.ArrayListUnmanaged(u8){};
        defer pending_client.deinit(self.allocator);

        const flags = try std.posix.fcntl(p.master_fd, std.posix.F.GETFL, 0);
        _ = try std.posix.fcntl(p.master_fd, std.posix.F.SETFL, flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));

        // Keepalive probing for dead-client detection.
        // When idle, the server periodically sends a QUIC PING.  If the
        // client is dead the UDP packet provokes ICMP port-unreachable,
        // which poll() surfaces as ConnectionRefused on the next recv.
        var last_client_activity = std.time.milliTimestamp();
        var last_keepalive_sent = std.time.milliTimestamp();
        const keepalive_interval_ms: i64 = 15_000; // probe every 15s

        var exit_reason: []const u8 = "unknown";

        bridge: while (true) {
            // Poll for incoming QUIC packets. On a connected UDP socket,
            // recvfrom returns ConnectionRefused when the peer's port is
            // closed (ICMP unreachable). This is the fastest signal that
            // the client died.
            server_conn.transport.poll(1) catch |err| {
                if (err == error.ConnectionRefused or
                    err == error.ConnectionResetByPeer or
                    err == error.NetworkUnreachable)
                {
                    exit_reason = "client disconnected (network error)";
                    break :bridge;
                }
                // Other errors (e.g. WouldBlock already handled inside poll): ignore
            };

            const channel_len: usize = server_conn.transport.receiveFromStream(stream_id, &channel_buffer) catch |err| blk: {
                if (err == error.NoData or err == error.EndOfBuffer or err == error.StreamNotFound) break :blk @as(usize, 0);
                if (err == error.StreamClosed) {
                    exit_reason = "client stream closed";
                    break :bridge;
                }
                break :blk @as(usize, 0);
            };

            if (channel_len > 0) {
                last_client_activity = std.time.milliTimestamp();
                try pending_client.appendSlice(self.allocator, channel_buffer[0..channel_len]);

                while (try nextClientChannelMessageLen(pending_client.items)) |msg_len| {
                    const msg = pending_client.items[0..msg_len];
                    const msg_type = msg[0];

                    const remaining = pending_client.items.len - msg_len;
                    if (remaining > 0) {
                        std.mem.copyForwards(u8, pending_client.items[0..remaining], pending_client.items[msg_len..]);
                    }
                    pending_client.items.len = remaining;

                    switch (msg_type) {
                        94 => {
                            var channel_data = channel_protocol.ChannelData.decode(self.allocator, msg) catch continue;
                            defer channel_data.deinit(self.allocator);
                            // The PTY master is non-blocking for reads, which means
                            // writes can also short-write under pressure. Drop-free
                            // input handling matters for TUI escape sequences.
                            Self.writeAllToPty(p, channel_data.data) catch {
                                exit_reason = "pty write failed";
                                break :bridge;
                            };
                        },
                        98 => {
                            var req = channel_protocol.ChannelRequest.decode(self.allocator, msg) catch continue;
                            defer req.deinit(self.allocator);

                            if (std.mem.eql(u8, req.request_type, "window-change")) {
                                self.handleWindowChange(stream_id, req.type_specific_data) catch {};
                            }
                        },
                        96 => {
                            exit_reason = "client sent EOF";
                            break :bridge;
                        },
                        97 => {
                            exit_reason = "client sent channel close";
                            break :bridge;
                        },
                        else => {},
                    }
                }
            }

            const pty_len = p.read(&pty_buffer) catch |err| {
                if (err == error.WouldBlock) {
                    // Check if child process has exited
                    const wait_result = std.posix.waitpid(session.pid, std.c.W.NOHANG);
                    if (wait_result.pid != 0) {
                        exit_reason = "child process exited";
                        break;
                    }

                    // Keepalive probe: after 15s of silence, send a QUIC
                    // PING to provoke ICMP if the client is gone.  The
                    // next poll() iteration picks up ConnectionRefused.
                    const now = std.time.milliTimestamp();
                    if (now - last_client_activity > keepalive_interval_ms and
                        now - last_keepalive_sent > keepalive_interval_ms)
                    {
                        server_conn.transport.sendKeepalive() catch {
                            exit_reason = "keepalive failed (client disconnected)";
                            break;
                        };
                        last_keepalive_sent = now;
                    }
                    continue;
                }
                exit_reason = "pty read error";
                break;
            };

            if (pty_len == 0) {
                exit_reason = "pty EOF (child exited)";
                break;
            }

            // Send PTY output to client. If the client is dead, the QUIC
            // send window fills up and this returns ConnectionStalled after ~30s.
            sendPtyOutput(server_conn, stream_id, pty_buffer[0..pty_len]) catch {
                exit_reason = "send to client failed (client likely disconnected)";
                break;
            };
        }

        std.debug.print("Session closing: {s}\n", .{exit_reason});

        server_conn.channel_manager.sendEof(stream_id) catch {};
        server_conn.channel_manager.closeChannel(stream_id) catch {};

        if (self.active_shells.fetchRemove(stream_id)) |entry| {
            var pty_session = entry.value;
            pty_session.deinit();
        }

        if (self.pty_requests.fetchRemove(stream_id)) |entry| {
            var info = entry.value;
            info.deinit();
        }

        if (self.session_env.fetchRemove(stream_id)) |entry| {
            var info = entry.value;
            info.deinit();
        }

        _ = self.session_modes.fetchRemove(stream_id);
    }
};

fn appendWireString(list: *std.ArrayList(u8), value: []const u8) !void {
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(value.len), .big);
    try list.appendSlice(&len_bytes);
    try list.appendSlice(value);
}

test "isValidTermName accepts expected terminal names" {
    try std.testing.expect(SessionRuntime.isValidTermName("xterm-256color"));
    try std.testing.expect(SessionRuntime.isValidTermName("screen.tmux"));
    try std.testing.expect(SessionRuntime.isValidTermName("alacritty_1"));
}

test "isValidTermName rejects control and shell metacharacters" {
    try std.testing.expect(!SessionRuntime.isValidTermName("xterm;rm -rf /"));
    try std.testing.expect(!SessionRuntime.isValidTermName("ansi$"));
    try std.testing.expect(!SessionRuntime.isValidTermName("term with space"));
}

test "session env validation whitelists terminal-safe variables" {
    try std.testing.expect(SessionRuntime.isAllowedEnvName("LANG"));
    try std.testing.expect(SessionRuntime.isAllowedEnvName("LC_ALL"));
    try std.testing.expect(SessionRuntime.isAllowedEnvName("LC_CTYPE"));
    try std.testing.expect(SessionRuntime.isAllowedEnvName("COLORTERM"));
    try std.testing.expect(!SessionRuntime.isAllowedEnvName("LD_PRELOAD"));
}

test "session env validation rejects control bytes and empty values" {
    try std.testing.expect(SessionRuntime.isValidEnvValue("en_US.UTF-8"));
    try std.testing.expect(SessionRuntime.isValidEnvValue("truecolor"));
    try std.testing.expect(!SessionRuntime.isValidEnvValue(""));
    try std.testing.expect(!SessionRuntime.isValidEnvValue("bad\nvalue"));
}

test "parseWireStringEnd returns end offset for complete field" {
    const field = [_]u8{ 0, 0, 0, 3, 'f', 'o', 'o' };
    const end = SessionRuntime.parseWireStringEnd(&field, 0);
    try std.testing.expectEqual(@as(?usize, 7), end);
}

test "parseWireStringEnd returns null for truncated field" {
    const truncated = [_]u8{ 0, 0, 0, 5, 'a', 'b' };
    try std.testing.expectEqual(@as(?usize, null), SessionRuntime.parseWireStringEnd(&truncated, 0));
}

test "nextClientChannelMessageLen handles channel data packet boundaries" {
    const full = [_]u8{ 94, 0, 0, 0, 3, 1, 2, 3 };
    try std.testing.expectEqual(@as(?usize, 8), try SessionRuntime.nextClientChannelMessageLen(&full));

    const partial = [_]u8{ 94, 0, 0, 0, 3, 1 };
    try std.testing.expectEqual(@as(?usize, null), try SessionRuntime.nextClientChannelMessageLen(&partial));
}

test "nextClientChannelMessageLen parses shell and exec requests" {
    const allocator = std.testing.allocator;

    var shell_msg = std.ArrayList(u8).init(allocator);
    defer shell_msg.deinit();
    try shell_msg.append(98);
    try appendWireString(&shell_msg, "shell");
    try shell_msg.append(1);
    try std.testing.expectEqual(@as(?usize, shell_msg.items.len), try SessionRuntime.nextClientChannelMessageLen(shell_msg.items));

    var exec_msg = std.ArrayList(u8).init(allocator);
    defer exec_msg.deinit();
    try exec_msg.append(98);
    try appendWireString(&exec_msg, "exec");
    try exec_msg.append(0);
    try appendWireString(&exec_msg, "echo ok");
    try std.testing.expectEqual(@as(?usize, exec_msg.items.len), try SessionRuntime.nextClientChannelMessageLen(exec_msg.items));
}

test "nextClientChannelMessageLen parses env requests" {
    const allocator = std.testing.allocator;

    var env_msg = std.ArrayList(u8).init(allocator);
    defer env_msg.deinit();
    try env_msg.append(98);
    try appendWireString(&env_msg, "env");
    try env_msg.append(1);
    try appendWireString(&env_msg, "LANG");
    try appendWireString(&env_msg, "en_US.UTF-8");

    try std.testing.expectEqual(@as(?usize, env_msg.items.len), try SessionRuntime.nextClientChannelMessageLen(env_msg.items));
}

test "nextClientChannelMessageLen parses pty-req and rejects truncated modes" {
    const allocator = std.testing.allocator;

    var pty_req = std.ArrayList(u8).init(allocator);
    defer pty_req.deinit();
    try pty_req.append(98);
    try appendWireString(&pty_req, "pty-req");
    try pty_req.append(1);
    try appendWireString(&pty_req, "xterm-256color");

    try pty_req.appendSlice(&[_]u8{
        0,
        0,
        0,
        80,
        0,
        0,
        0,
        24,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    });
    try appendWireString(&pty_req, "\x00");

    try std.testing.expectEqual(@as(?usize, pty_req.items.len), try SessionRuntime.nextClientChannelMessageLen(pty_req.items));

    const truncated = pty_req.items[0 .. pty_req.items.len - 1];
    try std.testing.expectEqual(@as(?usize, null), try SessionRuntime.nextClientChannelMessageLen(truncated));
}
