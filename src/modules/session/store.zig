const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ses = @import("main.zig");
const session_model = core.session_model;

/// Pane state machine for session lifecycle management.
/// See /doc/code/hexa/SESSION_LIFECYCLE.md for complete documentation.
///
/// Valid transitions:
///   attached  -> detached, sticky, orphaned
///   detached  -> attached, orphaned
///   sticky    -> attached, orphaned
///   orphaned  -> attached, sticky
///
/// CRITICAL: Always use Pane.transitionState() to change states.
/// Never set pane.state directly - transitions are validated and logged.
pub const PaneState = enum {
    /// Active connection to MUX client. Pane receives input, sends output.
    attached,
    /// Part of a detached session (keepalive), waiting for reattachment.
    detached,
    /// Half-orphaned pane with sticky pwd+key, waiting for same-directory adoption.
    sticky,
    /// Fully orphaned pane, can be adopted by any MUX.
    orphaned,

    /// Validate state transition and return true if valid.
    /// Idempotent updates (same state) are always valid.
    /// Invalid transitions return false and are logged.
    pub fn isValidTransition(from: PaneState, to: PaneState) bool {
        if (from == to) return true;

        return switch (from) {
            .attached => switch (to) {
                .detached, .sticky, .orphaned => true,
                else => false,
            },
            .detached => switch (to) {
                .attached, .orphaned => true,
                else => false,
            },
            .sticky => switch (to) {
                .attached, .orphaned => true,
                else => false,
            },
            .orphaned => switch (to) {
                .attached, .sticky => true,
                else => false,
            },
        };
    }
};

/// Pane type - split or float.
pub const PaneType = enum {
    split,
    float,
};

/// Minimal pane structure - just what's needed to keep process alive.
pub const Pane = struct {
    uuid: [32]u8,
    name: ?[]const u8 = null,
    pod_pid: posix.pid_t,
    pod_socket_path: []const u8,
    child_pid: posix.pid_t,
    state: PaneState,

    pane_id: u16 = 0,
    pod_vt_fd: ?posix.fd_t = null,
    pod_ctl_fd: ?posix.fd_t = null,
    needs_backlog_replay: bool = false,

    sticky_pwd: ?[]const u8,
    sticky_key: ?u8,
    sticky_session_name: ?[]const u8 = null,

    attached_to: ?usize,
    session_id: ?[16]u8,

    created_at: i64,
    orphaned_at: ?i64,

    is_float: bool = false,
    is_focused: bool = false,
    pane_type: PaneType = .split,
    created_from: ?[32]u8 = null,
    focused_from: ?[32]u8 = null,
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
    cursor_style: u8 = 0,
    cursor_visible: bool = true,
    alt_screen: bool = false,
    cols: u16 = 0,
    rows: u16 = 0,
    cwd: ?[]const u8 = null,
    fg_process: ?[]const u8 = null,
    fg_pid: ?i32 = null,
    layout_path: ?[]const u8 = null,
    last_cmd: ?[]const u8 = null,
    last_status: ?i32 = null,
    last_duration_ms: ?u64 = null,
    last_jobs: ?u16 = null,

    allocator: std.mem.Allocator,

    pub fn transitionState(self: *Pane, new_state: PaneState, reason: []const u8) bool {
        const old_state = self.state;

        if (!PaneState.isValidTransition(old_state, new_state)) {
            ses.debugLog("INVALID state transition: {s} -> {s} (reason: {s}) uuid={s}", .{
                @tagName(old_state),
                @tagName(new_state),
                reason,
                self.uuid[0..8],
            });
            return false;
        }

        if (old_state != new_state) {
            ses.debugLog("state transition: {s} -> {s} (reason: {s}) uuid={s}", .{
                @tagName(old_state),
                @tagName(new_state),
                reason,
                self.uuid[0..8],
            });
        }

        self.state = new_state;
        if (new_state == .orphaned and old_state != .orphaned) {
            self.orphaned_at = std.time.timestamp();
        }

        return true;
    }

    pub fn deinit(self: *Pane) void {
        if (self.name) |n| self.allocator.free(n);
        self.allocator.free(self.pod_socket_path);
        if (self.sticky_pwd) |pwd| self.allocator.free(pwd);
        if (self.sticky_session_name) |ssn| self.allocator.free(ssn);
        if (self.cwd) |c| self.allocator.free(c);
        if (self.fg_process) |p| self.allocator.free(p);
        if (self.layout_path) |path| self.allocator.free(path);
        if (self.last_cmd) |c| self.allocator.free(c);
    }

    var proc_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var proc_comm_buf: [128]u8 = undefined;
    var proc_stat_buf: [512]u8 = undefined;
    var proc_tty_buf: [std.fs.max_path_bytes]u8 = undefined;

    pub fn getProcCwd(self: *const Pane) ?[]const u8 {
        if (self.child_pid == 0) return null;

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cwd", .{self.child_pid}) catch |err| {
            core.logging.logError("ses", "failed to format pane cwd path", err);
            return null;
        };
        const link = posix.readlink(path, &proc_cwd_buf) catch |err| {
            if (err != error.FileNotFound) {
                core.logging.logError("ses", "failed to read pane cwd link", err);
            }
            return null;
        };
        return link;
    }

    fn parseNulSeparatedEnv(allocator: std.mem.Allocator, data: []const u8) ?[]const []const u8 {
        if (data.len == 0) return null;

        var count: usize = 0;
        for (data) |b| {
            if (b == 0) count += 1;
        }
        if (data[data.len - 1] != 0) count += 1;

        const entries = allocator.alloc([]const u8, count) catch |err| {
            core.logging.logError("ses", "failed to allocate environment entry list", err);
            return null;
        };
        errdefer allocator.free(entries);

        var idx: usize = 0;
        var start: usize = 0;
        for (data, 0..) |b, i| {
            if (b != 0) continue;
            if (i > start) {
                entries[idx] = allocator.dupe(u8, data[start..i]) catch |err| {
                    core.logging.logError("ses", "failed to copy environment entry", err);
                    for (entries[0..idx]) |e| allocator.free(e);
                    allocator.free(entries);
                    return null;
                };
                idx += 1;
            }
            start = i + 1;
        }

        if (start < data.len) {
            entries[idx] = allocator.dupe(u8, data[start..]) catch |err| {
                core.logging.logError("ses", "failed to copy trailing environment entry", err);
                for (entries[0..idx]) |e| allocator.free(e);
                allocator.free(entries);
                return null;
            };
            idx += 1;
        }

        if (idx == 0) {
            allocator.free(entries);
            return null;
        }

        if (idx < count) {
            const shrunk = allocator.realloc(entries, idx) catch |err| {
                core.logging.logError("ses", "failed to shrink environment entry list", err);
                return entries[0..idx];
            };
            return shrunk;
        }
        return entries;
    }

    fn getSnapshotEnviron(self: *const Pane, allocator: std.mem.Allocator) ?[]const []const u8 {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/tmp/hexe-env-{s}", .{&self.uuid}) catch |err| {
            core.logging.logError("ses", "failed to format pane env snapshot path", err);
            return null;
        };
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            if (err != error.FileNotFound) {
                core.logging.logError("ses", "failed to open pane env snapshot", err);
            }
            return null;
        };
        defer file.close();

        const max_size: usize = 256 * 1024;
        const data = file.readToEndAlloc(allocator, max_size) catch |err| {
            core.logging.logError("ses", "failed to read pane env snapshot", err);
            return null;
        };
        defer allocator.free(data);

        return parseNulSeparatedEnv(allocator, data);
    }

    pub fn getProcEnviron(self: *const Pane, allocator: std.mem.Allocator) ?[]const []const u8 {
        if (self.getSnapshotEnviron(allocator)) |snapshot| return snapshot;
        if (self.child_pid == 0) return null;

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/environ", .{self.child_pid}) catch |err| {
            core.logging.logError("ses", "failed to format process environ path", err);
            return null;
        };
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            if (err != error.FileNotFound) {
                core.logging.logError("ses", "failed to open process environ", err);
            }
            return null;
        };
        defer file.close();

        const max_size: usize = 128 * 1024;
        const data = file.readToEndAlloc(allocator, max_size) catch |err| {
            core.logging.logError("ses", "failed to read process environ", err);
            return null;
        };
        defer allocator.free(data);

        return parseNulSeparatedEnv(allocator, data);
    }

    fn readProcComm(self: *const Pane, pid: i32) ?[]const u8 {
        _ = self;
        if (pid <= 0) return null;

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch |err| {
            core.logging.logError("ses", "failed to format process comm path", err);
            return null;
        };
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            if (err != error.FileNotFound) {
                core.logging.logError("ses", "failed to open process comm", err);
            }
            return null;
        };
        defer file.close();

        const len = file.read(&proc_comm_buf) catch |err| {
            core.logging.logError("ses", "failed to read process comm", err);
            return null;
        };
        if (len == 0) return null;
        const end = if (proc_comm_buf[len - 1] == '\n') len - 1 else len;
        return proc_comm_buf[0..end];
    }

    pub fn getProcProcessName(self: *const Pane) ?[]const u8 {
        if (self.child_pid == 0) return null;
        return self.readProcComm(@intCast(self.child_pid));
    }

    pub fn getProcForegroundPid(self: *const Pane) ?i32 {
        if (self.child_pid == 0) return null;

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{self.child_pid}) catch |err| {
            core.logging.logError("ses", "failed to format process stat path", err);
            return null;
        };
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            if (err != error.FileNotFound) {
                core.logging.logError("ses", "failed to open process stat", err);
            }
            return null;
        };
        defer file.close();

        const len = file.read(&proc_stat_buf) catch |err| {
            core.logging.logError("ses", "failed to read process stat", err);
            return null;
        };
        if (len == 0) return null;
        const stat = proc_stat_buf[0..len];

        const right_paren = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
        if (right_paren + 2 >= stat.len) return null;
        const rest = stat[right_paren + 2 ..];

        var it = std.mem.tokenizeScalar(u8, rest, ' ');
        var idx: usize = 0;
        while (it.next()) |tok| {
            idx += 1;
            if (idx == 6) {
                const tpgid = std.fmt.parseInt(i32, tok, 10) catch |err| {
                    core.logging.logError("ses", "failed to parse process foreground pid", err);
                    return null;
                };
                if (tpgid <= 0) return null;
                return tpgid;
            }
        }

        return null;
    }

    pub fn getProcForegroundProcess(self: *const Pane) ?struct { name: []const u8, pid: i32 } {
        const fg_pid = self.getProcForegroundPid() orelse return null;
        const name = self.readProcComm(fg_pid) orelse return null;
        return .{ .name = name, .pid = fg_pid };
    }

    pub fn getProcTty(self: *const Pane) ?[]const u8 {
        if (self.child_pid == 0) return null;

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/fd/0", .{self.child_pid}) catch |err| {
            core.logging.logError("ses", "failed to format process tty path", err);
            return null;
        };
        const link = posix.readlink(path, &proc_tty_buf) catch |err| {
            if (err != error.FileNotFound) {
                core.logging.logError("ses", "failed to read process tty link", err);
            }
            return null;
        };
        return link;
    }
};

/// Client connection state.
pub const Client = struct {
    id: usize,
    fd: posix.fd_t,
    pane_uuids: std.ArrayList([32]u8),
    allocator: std.mem.Allocator,

    keepalive: bool,
    session_id: ?[16]u8,
    pending_reattach_session_id: ?[16]u8,
    /// When pending_reattach_session_id was set. The reattach float-steal
    /// privilege is time-boxed on this: the flag itself must survive until
    /// commit (client removal uses it to restore panes to the detached
    /// session), but the right to rip floats out of live muxes must not
    /// outlive the reattach flow if the commit register never arrives.
    pending_reattach_started_at: i64 = 0,
    session_name: ?[]const u8,
    base_root: ?[]const u8,
    session_snapshot: ?session_model.SessionSnapshot,
    frontend_kind: u8 = 0,
    transport_kind: u8 = 0,
    capability_flags: u32 = 0,

    mux_ctl_fd: ?posix.fd_t = null,
    mux_vt_fd: ?posix.fd_t = null,

    pub fn init(allocator: std.mem.Allocator, id: usize, fd: posix.fd_t) Client {
        return .{
            .id = id,
            .fd = fd,
            .pane_uuids = .empty,
            .allocator = allocator,
            .keepalive = true,
            .session_id = null,
            .pending_reattach_session_id = null,
            .session_name = null,
            .base_root = null,
            .session_snapshot = null,
        };
    }

    pub fn deinit(self: *Client) void {
        self.pane_uuids.deinit(self.allocator);
        if (self.session_name) |name| self.allocator.free(name);
        if (self.base_root) |root| self.allocator.free(root);
        if (self.session_snapshot) |*snapshot| snapshot.deinit();
    }

    pub fn appendUuid(self: *Client, uuid: [32]u8) !void {
        for (self.pane_uuids.items) |existing| {
            if (std.mem.eql(u8, &existing, &uuid)) return;
        }
        try self.pane_uuids.append(self.allocator, uuid);
    }

    pub fn updateSessionSnapshot(self: *Client, snapshot: session_model.SessionSnapshot) void {
        if (self.session_snapshot) |*old| old.deinit();
        self.session_snapshot = snapshot;
    }

    pub fn snapshotOwnsPane(self: *const Client, uuid: [32]u8) bool {
        const snap = &(self.session_snapshot orelse return true);
        return snap.panes.contains(uuid);
    }

    pub fn snapshotOwnsTab(self: *const Client, tab_uuid: [32]u8) bool {
        const snap = &(self.session_snapshot orelse return true);
        for (snap.tabs.items) |*tab| {
            if (std.mem.eql(u8, &tab.uuid, &tab_uuid)) return true;
        }
        return false;
    }
};

fn closeUniqueFd(fd: posix.fd_t, closed: *[3]posix.fd_t, closed_count: *usize) void {
    for (closed[0..closed_count.*]) |existing| {
        if (existing == fd) return;
    }
    posix.close(fd);
    closed[closed_count.*] = fd;
    closed_count.* += 1;
}

pub fn closeClientFds(store: *SessionStore, client: *Client) void {
    var closed: [3]posix.fd_t = undefined;
    var closed_count: usize = 0;

    if (client.mux_ctl_fd) |fd| {
        closeUniqueFd(fd, &closed, &closed_count);
        store.noteClosedFd(fd);
        client.mux_ctl_fd = null;
    }
    if (client.mux_vt_fd) |fd| {
        closeUniqueFd(fd, &closed, &closed_count);
        store.noteClosedFd(fd);
        client.mux_vt_fd = null;
    }
}

/// Detached session info (for listing).
pub const DetachedSession = struct {
    session_id: [16]u8,
    session_name: []const u8,
    base_root: []const u8,
    pane_count: usize,
};

/// Detached session state stored in SES canonical form.
pub const DetachedSessionState = struct {
    session_id: [16]u8,
    session_snapshot: session_model.SessionSnapshot,
    pane_uuids: [][32]u8,
    detached_at: i64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DetachedSessionState) void {
        self.session_snapshot.deinit();
        self.allocator.free(self.pane_uuids);
    }
};

/// Canonical session graph: panes, clients, detached sessions, plus the
/// pane-id <-> pod VT fd routing maps.
pub const SessionStore = struct {
    allocator: std.mem.Allocator,
    panes: std.AutoHashMap([32]u8, Pane),
    clients: std.ArrayList(Client),
    detached_sessions: std.AutoHashMap([16]u8, DetachedSessionState),
    next_client_id: usize = 1,
    orphan_timeout_hours: u32 = 24,
    detached_session_ttl_hours: u32 = 168,
    dirty: bool = false,
    next_pane_id: u16 = 1,
    pane_id_to_pod_vt: std.AutoHashMap(u16, posix.fd_t),
    pod_vt_to_pane_id: std.AutoHashMap(posix.fd_t, u16),
    pane_id_to_uuid: std.AutoHashMap(u16, [32]u8),
    /// fds closed directly (client removal, killPane, detach) in the last two
    /// event-loop iterations. The server's pending-close queues consult this
    /// before their own posix.close: an fd number already released here may
    /// have been reused by a brand-new connection, and closing it again would
    /// tear that connection down (or trip the EBADF safety check). Two
    /// generations because a watcher error CQE for a directly-closed fd can
    /// surface one full loop iteration after the close.
    closed_fds_cur: std.AutoHashMap(posix.fd_t, void),
    closed_fds_prev: std.AutoHashMap(posix.fd_t, void),

    pub fn init(allocator: std.mem.Allocator) SessionStore {
        return .{
            .allocator = allocator,
            .panes = std.AutoHashMap([32]u8, Pane).init(allocator),
            .clients = .empty,
            .detached_sessions = std.AutoHashMap([16]u8, DetachedSessionState).init(allocator),
            .pane_id_to_pod_vt = std.AutoHashMap(u16, posix.fd_t).init(allocator),
            .pod_vt_to_pane_id = std.AutoHashMap(posix.fd_t, u16).init(allocator),
            .pane_id_to_uuid = std.AutoHashMap(u16, [32]u8).init(allocator),
            .closed_fds_cur = std.AutoHashMap(posix.fd_t, void).init(allocator),
            .closed_fds_prev = std.AutoHashMap(posix.fd_t, void).init(allocator),
        };
    }

    pub fn noteClosedFd(self: *SessionStore, fd: posix.fd_t) void {
        self.closed_fds_cur.put(fd, {}) catch |err| {
            core.logging.logError("ses", "failed to record closed fd", err);
        };
    }

    pub fn closedFdNoted(self: *const SessionStore, fd: posix.fd_t) bool {
        return self.closed_fds_cur.contains(fd) or self.closed_fds_prev.contains(fd);
    }

    /// Age the log by one event-loop iteration: notes survive exactly two
    /// pending-close processing rounds, then stop shielding the fd number.
    pub fn rotateClosedFdLog(self: *SessionStore) void {
        std.mem.swap(std.AutoHashMap(posix.fd_t, void), &self.closed_fds_cur, &self.closed_fds_prev);
        self.closed_fds_cur.clearRetainingCapacity();
    }

    pub fn deinit(self: *SessionStore) void {
        var pane_iter = self.panes.valueIterator();
        while (pane_iter.next()) |pane| {
            var p = pane;
            if (p.pod_vt_fd) |fd| posix.close(fd);
            if (p.pod_ctl_fd) |fd| posix.close(fd);
            p.deinit();
        }
        self.panes.deinit();

        var sess_iter = self.detached_sessions.valueIterator();
        while (sess_iter.next()) |sess| {
            var s = sess;
            s.deinit();
        }
        self.detached_sessions.deinit();

        for (self.clients.items) |*client| {
            closeClientFds(self, client);
            client.deinit();
        }
        self.clients.deinit(self.allocator);

        self.pane_id_to_pod_vt.deinit();
        self.pod_vt_to_pane_id.deinit();
        self.pane_id_to_uuid.deinit();
        self.closed_fds_cur.deinit();
        self.closed_fds_prev.deinit();
    }

    pub fn allocPaneId(self: *SessionStore) u16 {
        const id = self.next_pane_id;
        self.next_pane_id +%= 1;
        if (self.next_pane_id == 0) self.next_pane_id = 1;
        return id;
    }

    pub fn markDirty(self: *SessionStore) void {
        self.dirty = true;
    }
};
