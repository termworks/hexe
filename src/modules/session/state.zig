const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ipc = core.ipc;
const wire = core.wire;
const ses = @import("main.zig");
const session_model = core.session_model;
const txlog = @import("txlog.zig");

pub const SessionSnapshot = session_model.SessionSnapshot;

const POD_VT_ACK_TIMEOUT_MS: i32 = 100;

/// Pane state machine for session lifecycle management.
/// See /doc/code/hexa/SESSION_LIFECYCLE.md for complete documentation.
///
/// Valid transitions:
///   attached  → detached, sticky, orphaned
///   detached  → attached, orphaned
///   sticky    → attached, orphaned
///   orphaned  → attached, sticky
///
/// CRITICAL: Always use Pane.transitionState() to change states.
/// Never set pane.state directly - transitions are validated and logged.
pub const PaneState = enum {
    /// Active connection to MUX client. Pane receives input, sends output.
    /// - attached_to: contains client_id
    /// - session_id: null (not part of detached session)
    /// - VT channels: connected to MUX
    attached,

    /// Part of a detached session (keepalive), waiting for reattachment.
    /// Full session state preserved for restoration. Cannot be adopted individually.
    /// - attached_to: null
    /// - session_id: contains detached session UUID
    /// - VT channels: disconnected
    /// - Stored in: detached_sessions map
    detached,

    /// Half-orphaned pane with sticky pwd+key, waiting for same-directory adoption.
    /// Prefers reattaching to the same session (session affinity).
    /// - attached_to: null
    /// - sticky_pwd: working directory path
    /// - sticky_key: keybinding identifier
    /// - sticky_session_name: originating session (optional, for affinity)
    /// - orphaned_at: timestamp set
    sticky,

    /// Fully orphaned pane, can be adopted by any MUX.
    /// No pwd/key restrictions on adoption.
    /// - attached_to: null
    /// - sticky_pwd/sticky_key: null or missing
    /// - orphaned_at: timestamp set
    orphaned,

    /// Validate state transition and return true if valid.
    /// Idempotent updates (same state) are always valid.
    /// Invalid transitions return false and are logged.
    pub fn isValidTransition(from: PaneState, to: PaneState) bool {
        // Same state is always valid (idempotent updates)
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

/// Pane type - split or float
pub const PaneType = enum {
    split,
    float,
};

/// Minimal pane structure - just what's needed to keep process alive
pub const Pane = struct {
    uuid: [32]u8,
    name: ?[]const u8 = null,
    pod_pid: posix.pid_t,
    pod_socket_path: []const u8,
    child_pid: posix.pid_t,
    state: PaneState,

    // Binary protocol fields (Phase 3+4)
    pane_id: u16 = 0,
    pod_vt_fd: ?posix.fd_t = null,
    pod_ctl_fd: ?posix.fd_t = null,

    // Flag for deferred backlog replay on reattach
    needs_backlog_replay: bool = false,

    // For sticky pwd floats
    sticky_pwd: ?[]const u8,
    sticky_key: ?u8,
    sticky_session_name: ?[]const u8 = null, // Session that created this sticky pane (for affinity)

    // Which client owns this pane (null if orphaned/detached)
    attached_to: ?usize,

    // Session ID for detached panes (so they can be reattached together)
    session_id: ?[16]u8,

    // Timestamps
    created_at: i64,
    orphaned_at: ?i64,

    // Auxiliary info (synced from mux)
    is_float: bool = false,
    is_focused: bool = false,
    pane_type: PaneType = .split,
    created_from: ?[32]u8 = null,
    focused_from: ?[32]u8 = null,
    // Cursor position (synced from mux, screen coordinates)
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
    // Cursor style and visibility (synced from mux)
    cursor_style: u8 = 0,
    cursor_visible: bool = true,
    // Alt screen state (synced from mux)
    alt_screen: bool = false,
    // Pane window size (synced from mux)
    cols: u16 = 0,
    rows: u16 = 0,
    // Current working directory (synced from mux, owned)
    cwd: ?[]const u8 = null,
    // Foreground process info (synced from mux)
    fg_process: ?[]const u8 = null,
    fg_pid: ?i32 = null,
    // Layout path (synced from mux, owned)
    layout_path: ?[]const u8 = null,

    // Shell-provided metadata (owned)
    last_cmd: ?[]const u8 = null,
    last_status: ?i32 = null,
    last_duration_ms: ?u64 = null,
    last_jobs: ?u16 = null,

    allocator: std.mem.Allocator,

    /// Transition pane to new state with validation and logging.
    /// Returns true if transition succeeded, false if invalid.
    pub fn transitionState(self: *Pane, new_state: PaneState, reason: []const u8) bool {
        const old_state = self.state;

        // Validate transition
        if (!PaneState.isValidTransition(old_state, new_state)) {
            ses.debugLog("INVALID state transition: {s} -> {s} (reason: {s}) uuid={s}", .{
                @tagName(old_state),
                @tagName(new_state),
                reason,
                self.uuid[0..8],
            });
            return false;
        }

        // Log transition (skip if same state)
        if (old_state != new_state) {
            ses.debugLog("state transition: {s} -> {s} (reason: {s}) uuid={s}", .{
                @tagName(old_state),
                @tagName(new_state),
                reason,
                self.uuid[0..8],
            });
        }

        // Update state
        self.state = new_state;

        // Update timestamps
        if (new_state == .orphaned and old_state != .orphaned) {
            self.orphaned_at = std.time.timestamp();
        }

        return true;
    }

    pub fn deinit(self: *Pane) void {
        if (self.name) |n| {
            self.allocator.free(n);
        }
        self.allocator.free(self.pod_socket_path);
        if (self.sticky_pwd) |pwd| {
            self.allocator.free(pwd);
        }
        if (self.sticky_session_name) |ssn| {
            self.allocator.free(ssn);
        }
        if (self.cwd) |c| {
            self.allocator.free(c);
        }
        if (self.fg_process) |p| {
            self.allocator.free(p);
        }
        if (self.layout_path) |path| {
            self.allocator.free(path);
        }
        if (self.last_cmd) |c| {
            self.allocator.free(c);
        }
    }

    // Static buffer for getProcCwd to avoid returning dangling pointer
    var proc_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var proc_comm_buf: [128]u8 = undefined;
    var proc_stat_buf: [512]u8 = undefined;
    var proc_tty_buf: [std.fs.max_path_bytes]u8 = undefined;

    /// Get current working directory from /proc/<child_pid>/cwd
    /// This is the authoritative CWD from OS, not dependent on shell OSC 7
    pub fn getProcCwd(self: *const Pane) ?[]const u8 {
        if (self.child_pid == 0) return null;

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cwd", .{self.child_pid}) catch return null;
        const link = posix.readlink(path, &proc_cwd_buf) catch return null;
        return link;
    }

    fn parseNulSeparatedEnv(allocator: std.mem.Allocator, data: []const u8) ?[]const []const u8 {
        if (data.len == 0) return null;

        var count: usize = 0;
        for (data) |b| {
            if (b == 0) count += 1;
        }
        if (data[data.len - 1] != 0) count += 1;

        const entries = allocator.alloc([]const u8, count) catch return null;
        errdefer allocator.free(entries);

        var idx: usize = 0;
        var start: usize = 0;
        for (data, 0..) |b, i| {
            if (b != 0) continue;
            if (i > start) {
                entries[idx] = allocator.dupe(u8, data[start..i]) catch {
                    for (entries[0..idx]) |e| allocator.free(e);
                    allocator.free(entries);
                    return null;
                };
                idx += 1;
            }
            start = i + 1;
        }

        if (start < data.len) {
            entries[idx] = allocator.dupe(u8, data[start..]) catch {
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
            const shrunk = allocator.realloc(entries, idx) catch return entries[0..idx];
            return shrunk;
        }
        return entries;
    }

    /// Read shell-exported environment snapshot for this pane.
    /// The snapshot is written by shell hooks to /tmp/hexe-env-<pane_uuid>.
    fn getSnapshotEnviron(self: *const Pane, allocator: std.mem.Allocator) ?[]const []const u8 {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/tmp/hexe-env-{s}", .{&self.uuid}) catch return null;
        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();

        const max_size: usize = 256 * 1024;
        const data = file.readToEndAlloc(allocator, max_size) catch return null;
        defer allocator.free(data);

        return parseNulSeparatedEnv(allocator, data);
    }

    /// Read environment variables from the pane shell process.
    /// Prefers a live shell snapshot and falls back to /proc/<child_pid>/environ.
    /// Returns owned slice of "KEY=VALUE" strings. Caller must free with the same allocator.
    pub fn getProcEnviron(self: *const Pane, allocator: std.mem.Allocator) ?[]const []const u8 {
        if (self.getSnapshotEnviron(allocator)) |snapshot| return snapshot;
        if (self.child_pid == 0) return null;

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/environ", .{self.child_pid}) catch return null;
        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();

        const max_size: usize = 128 * 1024;
        const data = file.readToEndAlloc(allocator, max_size) catch return null;
        defer allocator.free(data);

        return parseNulSeparatedEnv(allocator, data);
    }

    fn readProcComm(self: *const Pane, pid: i32) ?[]const u8 {
        _ = self;
        if (pid <= 0) return null;

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return null;
        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();

        const len = file.read(&proc_comm_buf) catch return null;
        if (len == 0) return null;
        const end = if (proc_comm_buf[len - 1] == '\n') len - 1 else len;
        return proc_comm_buf[0..end];
    }

    /// Get process name from /proc/<child_pid>/comm.
    pub fn getProcProcessName(self: *const Pane) ?[]const u8 {
        if (self.child_pid == 0) return null;
        return self.readProcComm(@intCast(self.child_pid));
    }

    /// Get foreground process group PID from /proc/<child_pid>/stat.
    pub fn getProcForegroundPid(self: *const Pane) ?i32 {
        if (self.child_pid == 0) return null;

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{self.child_pid}) catch return null;
        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();

        const len = file.read(&proc_stat_buf) catch return null;
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
                const tpgid = std.fmt.parseInt(i32, tok, 10) catch return null;
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

    /// Get controlling TTY path from /proc/<child_pid>/fd/0.
    pub fn getProcTty(self: *const Pane) ?[]const u8 {
        if (self.child_pid == 0) return null;

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/fd/0", .{self.child_pid}) catch return null;
        const link = posix.readlink(path, &proc_tty_buf) catch return null;
        return link;
    }
};

/// Client connection state
pub const Client = struct {
    id: usize,
    fd: posix.fd_t,
    pane_uuids: std.ArrayList([32]u8),
    allocator: std.mem.Allocator,

    // Keepalive settings
    keepalive: bool,
    session_id: ?[16]u8, // mux's UUID for this client
    session_name: ?[]const u8, // Pokemon name for this session
    session_snapshot: ?session_model.SessionSnapshot,

    // Binary protocol channels (Phase 3+4)
    mux_ctl_fd: ?posix.fd_t = null,
    mux_vt_fd: ?posix.fd_t = null,

    pub fn init(allocator: std.mem.Allocator, id: usize, fd: posix.fd_t) Client {
        return .{
            .id = id,
            .fd = fd,
            .pane_uuids = .empty,
            .allocator = allocator,
            .keepalive = true, // default to keepalive
            .session_id = null,
            .session_name = null,
            .session_snapshot = null,
        };
    }

    pub fn deinit(self: *Client) void {
        self.pane_uuids.deinit(self.allocator);
        if (self.session_name) |name| {
            self.allocator.free(name);
        }
        if (self.session_snapshot) |*snapshot| {
            snapshot.deinit();
        }
    }

    pub fn appendUuid(self: *Client, uuid: [32]u8) !void {
        try self.pane_uuids.append(self.allocator, uuid);
    }

    pub fn updateSessionSnapshot(self: *Client, snapshot: session_model.SessionSnapshot) void {
        if (self.session_snapshot) |*old| {
            old.deinit();
        }
        self.session_snapshot = snapshot;
    }

    /// Does this client's canonical snapshot contain this pane UUID? Used to
    /// reject session_* commands that reference panes the client doesn't own.
    /// Returns `true` when no snapshot exists yet (pre-first-sync) so the
    /// initial registration flow is not blocked — ownership is only enforced
    /// once SES has populated the snapshot.
    pub fn snapshotOwnsPane(self: *const Client, uuid: [32]u8) bool {
        const snap = &(self.session_snapshot orelse return true);
        return snap.panes.contains(uuid);
    }

    /// Does this client's canonical snapshot contain this tab UUID? Same
    /// "no snapshot yet = allow" semantics as `snapshotOwnsPane`.
    pub fn snapshotOwnsTab(self: *const Client, tab_uuid: [32]u8) bool {
        const snap = &(self.session_snapshot orelse return true);
        for (snap.tabs.items) |*tab| {
            if (std.mem.eql(u8, &tab.uuid, &tab_uuid)) return true;
        }
        return false;
    }
};

/// Session lock state - prevents concurrent attach/detach
pub const SessionLockState = enum {
    attaching, // Reattach in progress
    detaching, // Detach in progress
};

/// Session lock entry - tracks ongoing operations
pub const SessionLock = struct {
    client_id: usize,
    state: SessionLockState,
    locked_at: i64, // Timestamp for timeout detection
};

/// Detached session info (for listing)
pub const DetachedSession = struct {
    session_id: [16]u8,
    session_name: []const u8,
    pane_count: usize,
};

/// Detached session state stored in SES canonical form.
pub const DetachedSessionState = struct {
    session_id: [16]u8,
    session_snapshot: session_model.SessionSnapshot,
    pane_uuids: [][32]u8, // List of pane UUIDs in this session
    detached_at: i64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DetachedSessionState) void {
        self.session_snapshot.deinit();
        self.allocator.free(self.pane_uuids);
    }
};

/// Main ses state - the PTY holder
/// Note: Uses page_allocator internally to avoid GPA issues after fork/daemonization
pub const SesState = struct {
    allocator: std.mem.Allocator,
    panes: std.AutoHashMap([32]u8, Pane),
    clients: std.ArrayList(Client),
    detached_sessions: std.AutoHashMap([16]u8, DetachedSessionState),
    next_client_id: usize,
    orphan_timeout_hours: u32,
    detached_session_ttl_hours: u32,
    dirty: bool,

    // Binary protocol state (Phase 3+4)
    next_pane_id: u16 = 1,
    pane_id_to_pod_vt: std.AutoHashMap(u16, posix.fd_t),
    pod_vt_to_pane_id: std.AutoHashMap(posix.fd_t, u16),
    /// Fds that need to be added to the server poll set (populated by connectPodVt).
    pending_poll_fds: std.ArrayList(posix.fd_t),
    /// Fds that need to be removed from the server poll set (old fds closed by connectPodVt).
    pending_remove_poll_fds: std.ArrayList(posix.fd_t),

    // Session locks (prevent concurrent attach/detach)
    session_locks: std.AutoHashMap([16]u8, SessionLock),

    // Transaction log for crash recovery
    txlog: txlog.TxLog,
    txlog_path: []const u8, // Owned, must be freed in deinit()
    txlog_path_is_fallback: bool, // Track if using string literal fallback

    /// The allocator argument is ignored: SES daemonizes by `fork()` + `exec()`-less
    /// continuation, and any heap-allocating bookkeeping that lives across the
    /// fork must be on `page_allocator` so the child doesn't inherit a broken
    /// GPA arena. The parameter is kept in the signature for call-site symmetry
    /// with other modules (and so tests can still pass `testing.allocator`
    /// without the callsite looking wrong).
    pub fn init(_: std.mem.Allocator) SesState {
        const page_alloc = std.heap.page_allocator;

        // Initialize transaction log path
        const fallback_path = "/tmp/hexe-ses.txlog";
        const txlog_path = ipc.getTxLogPath(page_alloc) catch fallback_path;
        const is_fallback = std.mem.eql(u8, txlog_path, fallback_path);

        return .{
            .allocator = page_alloc,
            .panes = std.AutoHashMap([32]u8, Pane).init(page_alloc),
            .clients = .empty,
            .detached_sessions = std.AutoHashMap([16]u8, DetachedSessionState).init(page_alloc),
            .next_client_id = 1,
            .orphan_timeout_hours = 24,
            .detached_session_ttl_hours = 168, // 7 days
            .dirty = false,
            .pane_id_to_pod_vt = std.AutoHashMap(u16, posix.fd_t).init(page_alloc),
            .pod_vt_to_pane_id = std.AutoHashMap(posix.fd_t, u16).init(page_alloc),
            .pending_poll_fds = .empty,
            .pending_remove_poll_fds = .empty,
            .session_locks = std.AutoHashMap([16]u8, SessionLock).init(page_alloc),
            .txlog = txlog.TxLog.init(page_alloc, txlog_path) catch unreachable,
            .txlog_path = txlog_path,
            .txlog_path_is_fallback = is_fallback,
        };
    }

    pub fn allocPaneId(self: *SesState) u16 {
        const id = self.next_pane_id;
        self.next_pane_id +%= 1;
        if (self.next_pane_id == 0) self.next_pane_id = 1;
        return id;
    }

    fn buildDetachedSessionSnapshot(
        self: *SesState,
        client: *const Client,
        session_id: [16]u8,
    ) !session_model.SessionSnapshot {
        if (client.session_snapshot) |snapshot| {
            return snapshot.clone(self.allocator);
        }

        const session_name = client.session_name orelse "unknown";
        const hex_id: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
        return session_model.SessionSnapshot.initMinimal(self.allocator, hex_id, session_name);
    }

    fn ensureClientSessionSnapshot(self: *SesState, client: *Client) !*session_model.SessionSnapshot {
        if (client.session_snapshot == null) {
            const session_id = client.session_id orelse [_]u8{'0'} ** 16;
            const hex_id: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
            const session_name = client.session_name orelse "session";
            client.session_snapshot = try session_model.SessionSnapshot.initMinimal(self.allocator, hex_id, session_name);
        }
        return &client.session_snapshot.?;
    }

    fn firstLayoutPaneUuid(node: ?*const session_model.SessionLayoutNode) ?[32]u8 {
        const root = node orelse return null;
        return switch (root.*) {
            .pane => |uuid| uuid,
            .split => |split| firstLayoutPaneUuid(split.first) orelse firstLayoutPaneUuid(split.second),
        };
    }

    fn normalizeSessionSnapshotAfterPaneRemoval(snapshot: *session_model.SessionSnapshot) void {
        if (snapshot.tabs.items.len == 0) {
            snapshot.active_tab = 0;
            if (snapshot.active_float_uuid) |active_float_uuid| {
                if (!snapshot.panes.contains(active_float_uuid)) {
                    snapshot.active_float_uuid = null;
                }
            }
            snapshot.focused_pane_uuid = snapshot.active_float_uuid;
            return;
        }

        if (snapshot.active_tab >= snapshot.tabs.items.len) {
            snapshot.active_tab = snapshot.tabs.items.len - 1;
        }

        if (snapshot.tabs.items[snapshot.active_tab].focused_pane_uuid == null) {
            snapshot.tabs.items[snapshot.active_tab].focused_pane_uuid =
                firstLayoutPaneUuid(snapshot.tabs.items[snapshot.active_tab].root);
        }

        if (snapshot.active_float_uuid) |active_float_uuid| {
            if (!snapshot.panes.contains(active_float_uuid)) {
                snapshot.active_float_uuid = null;
            }
        }

        if (snapshot.active_float_uuid) |active_float_uuid| {
            snapshot.focused_pane_uuid = active_float_uuid;
        } else {
            snapshot.focused_pane_uuid = snapshot.tabs.items[snapshot.active_tab].focused_pane_uuid;
        }
    }

    fn removePaneFromSessionSnapshot(
        allocator: std.mem.Allocator,
        snapshot: *session_model.SessionSnapshot,
        pane_uuid: [32]u8,
    ) void {
        const pane_state = snapshot.panes.get(pane_uuid) orelse {
            var float_idx: ?usize = null;
            for (snapshot.floats.items, 0..) |float_state, idx| {
                if (std.mem.eql(u8, &float_state.pane_uuid, &pane_uuid)) {
                    float_idx = idx;
                    break;
                }
            }
            if (float_idx) |idx| {
                _ = snapshot.floats.orderedRemove(idx);
            }
            if (snapshot.active_float_uuid) |active_float_uuid| {
                if (std.mem.eql(u8, &active_float_uuid, &pane_uuid)) {
                    snapshot.active_float_uuid = null;
                }
            }
            if (snapshot.focused_pane_uuid) |focused_pane_uuid| {
                if (std.mem.eql(u8, &focused_pane_uuid, &pane_uuid)) {
                    snapshot.focused_pane_uuid = null;
                }
            }
            normalizeSessionSnapshotAfterPaneRemoval(snapshot);
            return;
        };

        switch (pane_state.kind) {
            .float => {
                var float_idx: ?usize = null;
                for (snapshot.floats.items, 0..) |float_state, idx| {
                    if (std.mem.eql(u8, &float_state.pane_uuid, &pane_uuid)) {
                        float_idx = idx;
                        break;
                    }
                }
                if (float_idx) |idx| {
                    _ = snapshot.floats.orderedRemove(idx);
                }
                _ = snapshot.panes.remove(pane_uuid);
            },
            .split => {
                var removed_tab_idx: ?usize = null;
                if (pane_state.parent_tab) |tab_idx| {
                    if (tab_idx < snapshot.tabs.items.len) {
                        _ = session_model.removePaneFromLayout(snapshot.allocator, &snapshot.tabs.items[tab_idx].root, pane_uuid) catch false;
                        if (snapshot.tabs.items[tab_idx].focused_pane_uuid) |focused_pane_uuid| {
                            if (std.mem.eql(u8, &focused_pane_uuid, &pane_uuid)) {
                                snapshot.tabs.items[tab_idx].focused_pane_uuid =
                                    firstLayoutPaneUuid(snapshot.tabs.items[tab_idx].root);
                            }
                        }
                        if (snapshot.tabs.items[tab_idx].root == null) {
                            var removed_tab = snapshot.tabs.orderedRemove(tab_idx);
                            removed_tab.deinit();
                            removed_tab_idx = tab_idx;
                        }
                    }
                }

                _ = snapshot.panes.remove(pane_uuid);

                if (removed_tab_idx) |tab_idx| {
                    var remove_split_uuids: std.ArrayList([32]u8) = .empty;
                    defer remove_split_uuids.deinit(allocator);

                    var pane_iter = snapshot.panes.iterator();
                    while (pane_iter.next()) |entry| {
                        if (entry.value_ptr.parent_tab) |parent| {
                            if (entry.value_ptr.kind == .split and parent == tab_idx) {
                                remove_split_uuids.append(allocator, entry.key_ptr.*) catch {};
                            } else if (parent > tab_idx) {
                                entry.value_ptr.parent_tab = parent - 1;
                            }
                        }
                    }
                    for (remove_split_uuids.items) |split_uuid| {
                        _ = snapshot.panes.remove(split_uuid);
                    }

                    for (snapshot.floats.items) |*float_state| {
                        if (float_state.parent_tab) |parent| {
                            if (parent == tab_idx) {
                                float_state.parent_tab = null;
                            } else if (parent > tab_idx) {
                                float_state.parent_tab = parent - 1;
                            }
                        }
                    }

                    var remapped_iter = snapshot.panes.iterator();
                    while (remapped_iter.next()) |entry| {
                        if (entry.value_ptr.kind != .float) continue;
                        if (entry.value_ptr.parent_tab) |parent| {
                            if (parent == tab_idx) {
                                entry.value_ptr.parent_tab = null;
                            } else if (parent > tab_idx) {
                                entry.value_ptr.parent_tab = parent - 1;
                            }
                        }
                    }
                }
            },
        }

        if (snapshot.active_float_uuid) |active_float_uuid| {
            if (std.mem.eql(u8, &active_float_uuid, &pane_uuid)) {
                snapshot.active_float_uuid = null;
            }
        }
        if (snapshot.focused_pane_uuid) |focused_pane_uuid| {
            if (std.mem.eql(u8, &focused_pane_uuid, &pane_uuid)) {
                snapshot.focused_pane_uuid = null;
            }
        }

        normalizeSessionSnapshotAfterPaneRemoval(snapshot);
    }

    fn prunePaneFromClientSnapshot(self: *SesState, client_id: usize, pane_uuid: [32]u8) void {
        const client = self.getClient(client_id) orelse return;
        if (client.session_snapshot) |*snapshot| {
            removePaneFromSessionSnapshot(self.allocator, snapshot, pane_uuid);
        }
    }

    fn prunePaneFromDetachedSnapshot(self: *SesState, session_id: [16]u8, pane_uuid: [32]u8) void {
        const detached = self.detached_sessions.getPtr(session_id) orelse return;

        var found_idx: ?usize = null;
        for (detached.pane_uuids, 0..) |existing_uuid, idx| {
            if (std.mem.eql(u8, &existing_uuid, &pane_uuid)) {
                found_idx = idx;
                break;
            }
        }

        if (found_idx) |idx| {
            var uuids = std.ArrayList([32]u8).fromOwnedSlice(detached.pane_uuids);
            _ = uuids.orderedRemove(idx);
            detached.pane_uuids = uuids.toOwnedSlice(detached.allocator) catch {
                detached.pane_uuids = uuids.items;
                return;
            };
        }

        removePaneFromSessionSnapshot(self.allocator, &detached.session_snapshot, pane_uuid);
    }

    fn paneProcessDead(pane: *const Pane) bool {
        return !isPidAlive(pane.child_pid) or !isPidAlive(pane.pod_pid);
    }

    fn pruneDetachedSessionPanes(self: *SesState, session_id: [16]u8) void {
        const detached = self.detached_sessions.getPtr(session_id) orelse return;

        var stale_panes: std.ArrayList([32]u8) = .empty;
        defer stale_panes.deinit(self.allocator);

        for (detached.pane_uuids) |pane_uuid| {
            const pane = self.panes.getPtr(pane_uuid) orelse {
                stale_panes.append(self.allocator, pane_uuid) catch {};
                continue;
            };

            if (paneProcessDead(pane)) {
                stale_panes.append(self.allocator, pane_uuid) catch {};
            }
        }

        for (stale_panes.items) |pane_uuid| {
            ses.debugLog("pruneDetachedSessionPanes: dropping stale pane uuid={s}", .{pane_uuid[0..8]});
            if (self.panes.contains(pane_uuid)) {
                self.killPane(pane_uuid) catch {};
            } else {
                self.prunePaneFromDetachedSnapshot(session_id, pane_uuid);
            }
        }
    }

    pub fn updateClientSessionFocus(
        self: *SesState,
        client_id: usize,
        pane_uuid: [32]u8,
        active_tab_hint: ?u16,
        is_focused: bool,
    ) void {
        if (!is_focused) return;

        const client = self.getClient(client_id) orelse return;
        const snapshot = self.ensureClientSessionSnapshot(client) catch return;
        const pane = snapshot.panes.get(pane_uuid) orelse return;

        var active_tab: ?usize = null;
        if (active_tab_hint) |hint| {
            const idx: usize = @intCast(hint);
            if (idx < snapshot.tabs.items.len) {
                active_tab = idx;
            }
        }
        if (active_tab == null) {
            active_tab = pane.parent_tab;
        }

        snapshot.focused_pane_uuid = pane_uuid;
        if (active_tab) |idx| {
            snapshot.active_tab = idx;
        }

        switch (pane.kind) {
            .split => {
                snapshot.active_float_uuid = null;
                if (active_tab) |idx| {
                    snapshot.tabs.items[idx].focused_pane_uuid = pane_uuid;
                } else if (pane.parent_tab) |idx| {
                    if (idx < snapshot.tabs.items.len) {
                        snapshot.tabs.items[idx].focused_pane_uuid = pane_uuid;
                    }
                }
            },
            .float => {
                snapshot.active_float_uuid = pane_uuid;
            },
        }
    }

    pub fn addClientSessionTab(
        self: *SesState,
        client_id: usize,
        tab_uuid: [32]u8,
        pane_uuid: [32]u8,
        tab_index: usize,
        name: []const u8,
    ) !void {
        const client = self.getClient(client_id) orelse return;
        const snapshot = try self.ensureClientSessionSnapshot(client);
        const insert_index = @min(tab_index, snapshot.tabs.items.len);

        var pane_iter = snapshot.panes.iterator();
        while (pane_iter.next()) |entry| {
            if (entry.value_ptr.parent_tab) |parent| {
                if (parent >= insert_index) {
                    entry.value_ptr.parent_tab = parent + 1;
                }
            }
        }
        for (snapshot.floats.items) |*float_state| {
            if (float_state.parent_tab) |parent| {
                if (parent >= insert_index) {
                    float_state.parent_tab = parent + 1;
                }
            }
        }

        const root = try snapshot.allocator.create(session_model.SessionLayoutNode);
        errdefer snapshot.allocator.destroy(root);
        root.* = .{ .pane = pane_uuid };

        var tab = session_model.SessionTab{
            .uuid = tab_uuid,
            .name = try snapshot.allocator.dupe(u8, name),
            .root = root,
            .focused_pane_uuid = pane_uuid,
            .allocator = snapshot.allocator,
        };
        errdefer tab.deinit();

        try snapshot.tabs.insert(snapshot.allocator, insert_index, tab);
        try snapshot.panes.put(pane_uuid, .{
            .uuid = pane_uuid,
            .kind = .split,
            .parent_tab = insert_index,
        });
        snapshot.tab_counter +%= 1;
        snapshot.active_tab = insert_index;
        snapshot.active_float_uuid = null;
        snapshot.focused_pane_uuid = pane_uuid;
    }

    pub fn removeClientSessionTab(
        self: *SesState,
        client_id: usize,
        tab_uuid: [32]u8,
        active_tab_hint: ?u16,
    ) void {
        const client = self.getClient(client_id) orelse return;
        const snapshot = self.ensureClientSessionSnapshot(client) catch return;

        var removed_index: ?usize = null;
        for (snapshot.tabs.items, 0..) |tab, idx| {
            if (std.mem.eql(u8, &tab.uuid, &tab_uuid)) {
                removed_index = idx;
                break;
            }
        }
        const idx = removed_index orelse return;

        var removed = snapshot.tabs.orderedRemove(idx);
        removed.deinit();

        var remove_split_uuids: std.ArrayList([32]u8) = .empty;
        defer remove_split_uuids.deinit(self.allocator);

        var pane_iter = snapshot.panes.iterator();
        while (pane_iter.next()) |entry| {
            if (entry.value_ptr.parent_tab) |parent| {
                if (parent == idx and entry.value_ptr.kind == .split) {
                    remove_split_uuids.append(self.allocator, entry.key_ptr.*) catch {};
                } else if (parent > idx) {
                    entry.value_ptr.parent_tab = parent - 1;
                }
            }
        }
        for (remove_split_uuids.items) |pane_uuid| {
            _ = snapshot.panes.remove(pane_uuid);
        }

        for (snapshot.floats.items) |*float_state| {
            if (float_state.parent_tab) |parent| {
                if (parent > idx) {
                    float_state.parent_tab = parent - 1;
                }
            }
        }

        if (snapshot.tabs.items.len == 0) {
            snapshot.active_tab = 0;
            snapshot.active_float_uuid = null;
            snapshot.focused_pane_uuid = null;
            return;
        }

        if (active_tab_hint) |hint| {
            const new_active: usize = @intCast(hint);
            snapshot.active_tab = @min(new_active, snapshot.tabs.items.len - 1);
        } else if (snapshot.active_tab >= snapshot.tabs.items.len) {
            snapshot.active_tab = snapshot.tabs.items.len - 1;
        }

        if (snapshot.active_float_uuid) |active_float_uuid| {
            if (!snapshot.panes.contains(active_float_uuid)) {
                snapshot.active_float_uuid = null;
            }
        }
        snapshot.focused_pane_uuid = if (snapshot.active_float_uuid) |float_uuid|
            float_uuid
        else
            snapshot.tabs.items[snapshot.active_tab].focused_pane_uuid;
    }

    fn findSnapshotTabIndex(snapshot: *session_model.SessionSnapshot, tab_uuid: [32]u8) ?usize {
        for (snapshot.tabs.items, 0..) |tab, idx| {
            if (std.mem.eql(u8, tab.uuid[0..], tab_uuid[0..])) return idx;
        }
        return null;
    }

    fn setSnapshotActiveTab(snapshot: *session_model.SessionSnapshot, active_tab: u16) void {
        if (snapshot.tabs.items.len == 0) {
            snapshot.active_tab = 0;
            return;
        }
        snapshot.active_tab = @min(@as(usize, @intCast(active_tab)), snapshot.tabs.items.len - 1);
    }

    fn setSnapshotSplitFocus(
        snapshot: *session_model.SessionSnapshot,
        tab_index: usize,
        focused_pane_uuid: ?[32]u8,
    ) void {
        if (tab_index < snapshot.tabs.items.len) {
            snapshot.tabs.items[tab_index].focused_pane_uuid = focused_pane_uuid;
        }
        snapshot.active_float_uuid = null;
        snapshot.focused_pane_uuid = focused_pane_uuid;
    }

    pub fn splitClientSessionPane(
        self: *SesState,
        client_id: usize,
        tab_uuid: [32]u8,
        source_pane_uuid: [32]u8,
        new_pane_uuid: [32]u8,
        active_tab: u16,
        focused_pane_uuid: ?[32]u8,
        dir: session_model.SessionSplitDir,
    ) !void {
        const client = self.getClient(client_id) orelse return;
        const snapshot = try self.ensureClientSessionSnapshot(client);
        const tab_index = findSnapshotTabIndex(snapshot, tab_uuid) orelse return error.InvalidLayout;
        const root = snapshot.tabs.items[tab_index].root orelse return error.InvalidLayout;

        if (!try session_model.splitPaneInLayout(
            snapshot.allocator,
            root,
            source_pane_uuid,
            new_pane_uuid,
            dir,
        )) {
            return error.InvalidLayout;
        }

        try snapshot.panes.put(new_pane_uuid, .{
            .uuid = new_pane_uuid,
            .kind = .split,
            .parent_tab = tab_index,
        });

        setSnapshotActiveTab(snapshot, active_tab);
        setSnapshotSplitFocus(snapshot, tab_index, focused_pane_uuid);
    }

    pub fn closeClientSessionSplitPane(
        self: *SesState,
        client_id: usize,
        tab_uuid: [32]u8,
        pane_uuid: [32]u8,
        active_tab: u16,
        focused_pane_uuid: ?[32]u8,
    ) !void {
        const client = self.getClient(client_id) orelse return;
        const snapshot = try self.ensureClientSessionSnapshot(client);
        const tab_index = findSnapshotTabIndex(snapshot, tab_uuid) orelse return error.InvalidLayout;

        if (!try session_model.removePaneFromLayout(
            snapshot.allocator,
            &snapshot.tabs.items[tab_index].root,
            pane_uuid,
        )) {
            return error.InvalidLayout;
        }

        _ = snapshot.panes.remove(pane_uuid);
        setSnapshotActiveTab(snapshot, active_tab);
        setSnapshotSplitFocus(snapshot, tab_index, focused_pane_uuid);
    }

    pub fn replaceClientSessionSplitPane(
        self: *SesState,
        client_id: usize,
        tab_uuid: [32]u8,
        old_pane_uuid: [32]u8,
        new_pane_uuid: [32]u8,
        active_tab: u16,
        focused_pane_uuid: ?[32]u8,
    ) !void {
        const client = self.getClient(client_id) orelse return;
        const snapshot = try self.ensureClientSessionSnapshot(client);
        const tab_index = findSnapshotTabIndex(snapshot, tab_uuid) orelse return error.InvalidLayout;
        const root = snapshot.tabs.items[tab_index].root orelse return error.InvalidLayout;

        if (!session_model.replacePaneUuidInLayout(root, old_pane_uuid, new_pane_uuid)) {
            return error.InvalidLayout;
        }

        var new_pane_state = snapshot.panes.get(old_pane_uuid) orelse session_model.SessionPane{
            .uuid = new_pane_uuid,
            .kind = .split,
            .parent_tab = tab_index,
        };
        _ = snapshot.panes.remove(old_pane_uuid);
        new_pane_state.uuid = new_pane_uuid;
        new_pane_state.kind = .split;
        new_pane_state.parent_tab = tab_index;
        try snapshot.panes.put(new_pane_uuid, new_pane_state);

        setSnapshotActiveTab(snapshot, active_tab);
        setSnapshotSplitFocus(snapshot, tab_index, focused_pane_uuid);
    }

    pub fn setClientSessionSplitRatio(
        self: *SesState,
        client_id: usize,
        tab_uuid: [32]u8,
        active_tab: u16,
        first_anchor_uuid: [32]u8,
        second_anchor_uuid: [32]u8,
        ratio: f32,
    ) !void {
        const client = self.getClient(client_id) orelse return;
        const snapshot = try self.ensureClientSessionSnapshot(client);
        const tab_index = findSnapshotTabIndex(snapshot, tab_uuid) orelse return error.InvalidLayout;
        const root = snapshot.tabs.items[tab_index].root orelse return error.InvalidLayout;

        if (!session_model.setSplitRatioByAnchors(root, first_anchor_uuid, second_anchor_uuid, ratio)) {
            return error.InvalidLayout;
        }

        setSnapshotActiveTab(snapshot, active_tab);
    }

    pub fn syncClientSessionFloat(
        self: *SesState,
        client_id: usize,
        pane_uuid: [32]u8,
        active_tab_hint: ?u16,
        parent_tab_hint: ?u16,
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
        const client = self.getClient(client_id) orelse return;
        const snapshot = try self.ensureClientSessionSnapshot(client);

        const parent_tab: ?usize = if (parent_tab_hint) |hint| @intCast(hint) else null;
        try snapshot.panes.put(pane_uuid, .{
            .uuid = pane_uuid,
            .kind = .float,
            .parent_tab = parent_tab,
            .sticky = sticky,
            .is_pwd = is_pwd,
            .float_key = float_key,
        });

        const float_state = session_model.SessionFloat{
            .pane_uuid = pane_uuid,
            .parent_tab = parent_tab,
            .visible = visible,
            .tab_visible = tab_visible,
            .sticky = sticky,
            .is_pwd = is_pwd,
            .float_key = float_key,
            .width_pct = width_pct,
            .height_pct = height_pct,
            .pos_x_pct = pos_x_pct,
            .pos_y_pct = pos_y_pct,
            .pad_x = pad_x,
            .pad_y = pad_y,
        };

        for (snapshot.floats.items) |*existing| {
            if (std.mem.eql(u8, &existing.pane_uuid, &pane_uuid)) {
                existing.* = float_state;
                break;
            }
        } else {
            try snapshot.floats.append(snapshot.allocator, float_state);
        }

        if (active) {
            if (active_tab_hint) |hint| {
                const tab_idx: usize = @intCast(hint);
                if (tab_idx < snapshot.tabs.items.len) {
                    snapshot.active_tab = tab_idx;
                }
            }
            snapshot.active_float_uuid = pane_uuid;
            snapshot.focused_pane_uuid = pane_uuid;
        } else if (!visible) {
            if (snapshot.active_float_uuid) |active_float_uuid| {
                if (std.mem.eql(u8, &active_float_uuid, &pane_uuid)) {
                    snapshot.active_float_uuid = null;
                    if (snapshot.active_tab < snapshot.tabs.items.len) {
                        snapshot.focused_pane_uuid = snapshot.tabs.items[snapshot.active_tab].focused_pane_uuid;
                    }
                }
            }
        }
    }

    pub fn removeClientSessionFloat(self: *SesState, client_id: usize, pane_uuid: [32]u8) void {
        const client = self.getClient(client_id) orelse return;
        const snapshot = self.ensureClientSessionSnapshot(client) catch return;

        var float_index: ?usize = null;
        for (snapshot.floats.items, 0..) |float_state, idx| {
            if (std.mem.eql(u8, &float_state.pane_uuid, &pane_uuid)) {
                float_index = idx;
                break;
            }
        }
        if (float_index) |idx| {
            _ = snapshot.floats.orderedRemove(idx);
        }

        if (snapshot.panes.get(pane_uuid)) |pane| {
            if (pane.kind == .float) {
                _ = snapshot.panes.remove(pane_uuid);
            }
        }

        if (snapshot.active_float_uuid) |active_float_uuid| {
            if (std.mem.eql(u8, &active_float_uuid, &pane_uuid)) {
                snapshot.active_float_uuid = null;
            }
        }
        if (snapshot.focused_pane_uuid) |focused_pane_uuid| {
            if (std.mem.eql(u8, &focused_pane_uuid, &pane_uuid)) {
                snapshot.focused_pane_uuid = if (snapshot.active_tab < snapshot.tabs.items.len)
                    snapshot.tabs.items[snapshot.active_tab].focused_pane_uuid
                else
                    null;
            }
        }
    }

    fn collectLayoutPaneUuids(
        allocator: std.mem.Allocator,
        node: ?*const session_model.SessionLayoutNode,
        out: *std.ArrayList([32]u8),
    ) !void {
        const root = node orelse return;
        switch (root.*) {
            .pane => |uuid| try out.append(allocator, uuid),
            .split => |split| {
                try collectLayoutPaneUuids(allocator, split.first, out);
                try collectLayoutPaneUuids(allocator, split.second, out);
            },
        }
    }

    fn countTemplateLeaves(value: std.json.Value) usize {
        const obj = switch (value) {
            .object => |o| o,
            else => return 0,
        };
        const type_val = obj.get("type") orelse return 0;
        const type_str = switch (type_val) {
            .string => |s| s,
            else => return 0,
        };
        if (std.mem.eql(u8, type_str, "pane")) return 1;
        if (std.mem.eql(u8, type_str, "split")) {
            const first = obj.get("first") orelse return 0;
            const second = obj.get("second") orelse return 0;
            return countTemplateLeaves(first) + countTemplateLeaves(second);
        }
        return 0;
    }

    fn collectTemplateCwds(
        value: std.json.Value,
        list: *std.ArrayList(?[]const u8),
        allocator: std.mem.Allocator,
    ) void {
        const obj = switch (value) {
            .object => |o| o,
            else => return,
        };
        const type_val = obj.get("type") orelse return;
        const type_str = switch (type_val) {
            .string => |s| s,
            else => return,
        };
        if (std.mem.eql(u8, type_str, "pane")) {
            if (obj.get("cwd")) |cwd_val| {
                if (cwd_val == .string) {
                    list.append(allocator, cwd_val.string) catch {};
                    return;
                }
            }
            list.append(allocator, null) catch {};
        } else if (std.mem.eql(u8, type_str, "split")) {
            if (obj.get("first")) |first| collectTemplateCwds(first, list, allocator);
            if (obj.get("second")) |second| collectTemplateCwds(second, list, allocator);
        }
    }

    fn buildTemplateLayoutNode(
        allocator: std.mem.Allocator,
        value: std.json.Value,
        pane_uuids: []const [32]u8,
        next_idx: *usize,
    ) !*session_model.SessionLayoutNode {
        const obj = switch (value) {
            .object => |o| o,
            else => return error.InvalidNode,
        };
        const type_val = obj.get("type") orelse return error.InvalidNode;
        const type_str = switch (type_val) {
            .string => |s| s,
            else => return error.InvalidNode,
        };

        const node = try allocator.create(session_model.SessionLayoutNode);
        errdefer allocator.destroy(node);

        if (std.mem.eql(u8, type_str, "pane")) {
            if (next_idx.* >= pane_uuids.len) return error.InvalidNode;
            node.* = .{ .pane = pane_uuids[next_idx.*] };
            next_idx.* += 1;
            return node;
        }

        if (!std.mem.eql(u8, type_str, "split")) return error.InvalidNode;

        const dir_val = obj.get("dir") orelse return error.InvalidNode;
        const dir_str = switch (dir_val) {
            .string => |s| s,
            else => return error.InvalidNode,
        };
        const ratio_val = obj.get("ratio") orelse return error.InvalidNode;
        const ratio: f32 = switch (ratio_val) {
            .float => @floatCast(ratio_val.float),
            .integer => @floatFromInt(ratio_val.integer),
            else => return error.InvalidNode,
        };
        const first_val = obj.get("first") orelse return error.InvalidNode;
        const second_val = obj.get("second") orelse return error.InvalidNode;

        const first = try buildTemplateLayoutNode(allocator, first_val, pane_uuids, next_idx);
        errdefer {
            first.deinit(allocator);
            allocator.destroy(first);
        }
        const second = try buildTemplateLayoutNode(allocator, second_val, pane_uuids, next_idx);
        errdefer {
            second.deinit(allocator);
            allocator.destroy(second);
        }

        node.* = .{
            .split = .{
                .dir = if (std.mem.eql(u8, dir_str, "horizontal")) .horizontal else .vertical,
                .ratio = ratio,
                .first = first,
                .second = second,
            },
        };
        return node;
    }

    pub fn applyClientSessionLayoutTemplate(
        self: *SesState,
        client_id: usize,
        source_uuid: [32]u8,
        tree_json: []const u8,
    ) !void {
        const client = self.getClient(client_id) orelse return error.ClientNotFound;
        const snapshot = try self.ensureClientSessionSnapshot(client);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, tree_json, .{});
        defer parsed.deinit();

        const leaf_count = countTemplateLeaves(parsed.value);
        if (leaf_count == 0) return error.InvalidLayout;

        var cwds: std.ArrayList(?[]const u8) = .empty;
        defer cwds.deinit(self.allocator);
        collectTemplateCwds(parsed.value, &cwds, self.allocator);

        var target_tab_idx: ?usize = null;
        if (snapshot.panes.get(source_uuid)) |pane_state| {
            target_tab_idx = pane_state.parent_tab;
        }
        if (target_tab_idx == null and snapshot.active_tab < snapshot.tabs.items.len) {
            target_tab_idx = snapshot.active_tab;
        }
        const tab_idx = target_tab_idx orelse return error.InvalidLayout;
        if (tab_idx >= snapshot.tabs.items.len) return error.InvalidLayout;

        var current_split_uuids: std.ArrayList([32]u8) = .empty;
        defer current_split_uuids.deinit(self.allocator);
        collectLayoutPaneUuids(self.allocator, snapshot.tabs.items[tab_idx].root, &current_split_uuids) catch return error.OutOfMemory;

        var source_in_tab = false;
        for (current_split_uuids.items) |pane_uuid| {
            if (std.mem.eql(u8, &pane_uuid, &source_uuid)) {
                source_in_tab = true;
                break;
            }
        }
        if (!source_in_tab) return error.InvalidLayout;

        var leaf_uuids: std.ArrayList([32]u8) = .empty;
        defer leaf_uuids.deinit(self.allocator);
        try leaf_uuids.append(self.allocator, source_uuid);

        var created_uuids: std.ArrayList([32]u8) = .empty;
        defer {
            for (created_uuids.items) |pane_uuid| {
                if (!self.panes.contains(pane_uuid)) continue;
                self.killPane(pane_uuid) catch {};
            }
            created_uuids.deinit(self.allocator);
        }

        var leaf_idx: usize = 1;
        while (leaf_idx < leaf_count) : (leaf_idx += 1) {
            const cwd = if (leaf_idx < cwds.items.len) cwds.items[leaf_idx] else null;
            const pane = try self.createPane(client_id, std.posix.getenv("SHELL") orelse "/bin/sh", cwd, null, null, null, null);
            pane.needs_backlog_replay = true;
            try leaf_uuids.append(self.allocator, pane.uuid);
            try created_uuids.append(self.allocator, pane.uuid);
        }

        var next_uuid_idx: usize = 0;
        const new_root = try buildTemplateLayoutNode(snapshot.allocator, parsed.value, leaf_uuids.items, &next_uuid_idx);
        errdefer {
            new_root.deinit(snapshot.allocator);
            snapshot.allocator.destroy(new_root);
        }

        var live_uuids = leaf_uuids;
        defer live_uuids.deinit(self.allocator);
        leaf_uuids = .empty;

        var remove_split_uuids: std.ArrayList([32]u8) = .empty;
        defer remove_split_uuids.deinit(self.allocator);
        for (current_split_uuids.items) |pane_uuid| {
            var keep = false;
            for (live_uuids.items) |live_uuid| {
                if (std.mem.eql(u8, &live_uuid, &pane_uuid)) {
                    keep = true;
                    break;
                }
            }
            if (!keep) try remove_split_uuids.append(self.allocator, pane_uuid);
        }

        if (snapshot.tabs.items[tab_idx].root) |old_root| {
            old_root.deinit(snapshot.allocator);
            snapshot.allocator.destroy(old_root);
        }
        snapshot.tabs.items[tab_idx].root = new_root;
        snapshot.tabs.items[tab_idx].focused_pane_uuid = source_uuid;
        snapshot.active_tab = tab_idx;
        if (snapshot.active_float_uuid == null) {
            snapshot.focused_pane_uuid = source_uuid;
        }

        for (remove_split_uuids.items) |pane_uuid| {
            _ = snapshot.panes.remove(pane_uuid);
        }
        for (live_uuids.items) |pane_uuid| {
            if (snapshot.panes.getPtr(pane_uuid)) |pane_state| {
                pane_state.kind = .split;
                pane_state.parent_tab = tab_idx;
                pane_state.sticky = false;
                pane_state.is_pwd = false;
                pane_state.float_key = 0;
            } else {
                try snapshot.panes.put(pane_uuid, .{
                    .uuid = pane_uuid,
                    .kind = .split,
                    .parent_tab = tab_idx,
                });
            }
        }

        for (remove_split_uuids.items) |pane_uuid| {
            self.killPane(pane_uuid) catch {};
        }

        created_uuids.clearRetainingCapacity();
        self.markDirty();
    }

    /// Check if a session name is already in use by a detached session or connected client.
    /// Optionally excludes one client id (used during re-register).
    fn isSessionNameInUse(
        self: *SesState,
        name: []const u8,
        exclude_client_id: ?usize,
        exclude_session_id: ?[16]u8,
    ) bool {
        // Check detached sessions
        var iter = self.detached_sessions.iterator();
        while (iter.next()) |entry| {
            if (exclude_session_id) |exclude| {
                if (std.mem.eql(u8, &entry.key_ptr.*, &exclude)) continue;
            }
            const detached = entry.value_ptr;
            if (std.ascii.eqlIgnoreCase(detached.session_snapshot.session_name, name)) {
                return true;
            }
        }
        // Check connected clients
        for (self.clients.items) |*client| {
            if (exclude_client_id) |exclude| {
                if (client.id == exclude) continue;
            }
            if (client.session_name) |client_name| {
                if (std.ascii.eqlIgnoreCase(client_name, name)) {
                    return true;
                }
            }
        }
        return false;
    }

    /// Resolve a session name to ensure uniqueness.
    /// If name conflicts, appends "-2", "-3", etc. until unique.
    /// Returns allocated string that caller must free.
    pub fn resolveSessionName(
        self: *SesState,
        requested_name: []const u8,
        exclude_client_id: ?usize,
        exclude_session_id: ?[16]u8,
    ) ?[]u8 {
        const trimmed = std.mem.trim(u8, requested_name, " \t\r\n");
        const base_name = if (trimmed.len > 0) trimmed else "session";

        // If name is not in use, just return a copy
        if (!self.isSessionNameInUse(base_name, exclude_client_id, exclude_session_id)) {
            return self.allocator.dupe(u8, base_name) catch null;
        }

        // Name is in use, try appending suffix
        var suffix: u32 = 2;
        var buf: [128]u8 = undefined;
        while (suffix < 100) : (suffix += 1) {
            const resolved = std.fmt.bufPrint(&buf, "{s}-{d}", .{ base_name, suffix }) catch break;
            if (!self.isSessionNameInUse(resolved, exclude_client_id, exclude_session_id)) {
                return self.allocator.dupe(u8, resolved) catch null;
            }
        }

        // Fallback: use first 8 chars of a random UUID
        var uuid_bytes: [4]u8 = undefined;
        std.crypto.random.bytes(&uuid_bytes);
        const hex = std.fmt.bytesToHex(&uuid_bytes, .lower);
        const fallback = std.fmt.bufPrint(&buf, "{s}-{s}", .{ base_name, hex }) catch return null;
        return self.allocator.dupe(u8, fallback) catch null;
    }

    /// Connect the VT data channel (③) to a POD socket.
    /// On success, stores the fd in the pane and populates routing tables.
    /// Returns true when the VT channel is fully connected.
    pub fn connectPodVt(self: *SesState, uuid: [32]u8, pod_socket_path: []const u8, pane_id: u16) bool {
        const client = core.ipc.Client.connect(pod_socket_path) catch {
            ses.debugLog("connectPodVt: failed to connect to {s}", .{pod_socket_path});
            return false;
        };
        const fd = client.fd;

        // Send versioned handshake.
        wire.sendHandshake(fd, wire.POD_HANDSHAKE_SES_VT) catch {
            posix.close(fd);
            return false;
        };

        // Wait for acknowledgment from POD to avoid race during init.
        const ack_hdr = wire.readControlHeaderTimeout(fd, POD_VT_ACK_TIMEOUT_MS) catch {
            posix.close(fd);
            return false;
        };
        const ack_type: wire.MsgType = @enumFromInt(ack_hdr.msg_type);
        if (ack_type != .ok) {
            ses.debugLog("connectPodVt: unexpected ack {x}, closing", .{ack_hdr.msg_type});
            posix.close(fd);
            return false;
        }

        // Store in pane.
        if (self.panes.getPtr(uuid)) |pane| {
            if (pane.pod_vt_fd) |old_fd| {
                ses.debugLog("connectPodVt: closing old fd={d}", .{old_fd});
                _ = self.pod_vt_to_pane_id.remove(old_fd);
                // Track for removal from poll_fds BEFORE closing, to prevent
                // fd reuse causing duplicate poll entries that block on read.
                self.pending_remove_poll_fds.append(self.allocator, old_fd) catch {};
                posix.close(old_fd);
            }
            pane.pod_vt_fd = fd;
        }

        // Populate routing tables.
        self.pane_id_to_pod_vt.put(pane_id, fd) catch {};
        self.pod_vt_to_pane_id.put(fd, pane_id) catch {};

        // Queue fd for poll set addition by the server loop.
        self.pending_poll_fds.append(self.allocator, fd) catch {};

        const hex_uuid: [32]u8 = std.fmt.bytesToHex(uuid[0..16], .lower);
        ses.debugLog("connectPodVt: uuid={s} pane_id={d} fd={d}", .{ hex_uuid[0..8], pane_id, fd });
        return true;
    }

    pub fn markDirty(self: *SesState) void {
        self.dirty = true;
    }

    /// Acquire session lock for attach/detach operation.
    /// Returns error if session is already locked.
    pub fn acquireSessionLock(self: *SesState, session_id: [16]u8, client_id: usize, state: SessionLockState) !void {
        // Check if already locked
        if (self.session_locks.get(session_id)) |existing_lock| {
            // Check for timeout (30 seconds)
            const now = std.time.timestamp();
            const lock_age = now - existing_lock.locked_at;
            if (lock_age > 30) {
                // Lock expired, remove it and continue
                ses.debugLog("acquireSessionLock: expired lock detected, removing (age={d}s)", .{lock_age});
                _ = self.session_locks.remove(session_id);
            } else {
                // Lock still valid
                return error.SessionLocked;
            }
        }

        // Acquire lock
        const lock = SessionLock{
            .client_id = client_id,
            .state = state,
            .locked_at = std.time.timestamp(),
        };
        try self.session_locks.put(session_id, lock);
        ses.debugLog("acquireSessionLock: locked session {s} for {s}", .{
            std.fmt.bytesToHex(&session_id, .lower)[0..8],
            @tagName(state),
        });
    }

    /// Release session lock after operation completes.
    pub fn releaseSessionLock(self: *SesState, session_id: [16]u8) void {
        if (self.session_locks.remove(session_id)) {
            ses.debugLog("releaseSessionLock: released session {s}", .{
                std.fmt.bytesToHex(&session_id, .lower)[0..8],
            });
        }
    }

    /// Check if session is currently locked.
    pub fn isSessionLocked(self: *SesState, session_id: [16]u8) bool {
        return self.session_locks.contains(session_id);
    }

    pub fn deinit(self: *SesState) void {
        // Close all panes
        var pane_iter = self.panes.valueIterator();
        while (pane_iter.next()) |pane| {
            // ses is registry-only; do not kill pods on shutdown.
            var p = pane;
            if (p.pod_vt_fd) |fd| posix.close(fd);
            if (p.pod_ctl_fd) |fd| posix.close(fd);
            p.deinit();
        }
        self.panes.deinit();

        // Cleanup detached sessions
        var sess_iter = self.detached_sessions.valueIterator();
        while (sess_iter.next()) |sess| {
            var s = sess;
            s.deinit();
        }
        self.detached_sessions.deinit();

        // Cleanup clients
        for (self.clients.items) |*client| {
            if (client.mux_ctl_fd) |fd| posix.close(fd);
            if (client.mux_vt_fd) |fd| posix.close(fd);
            client.deinit();
        }
        self.clients.deinit(self.allocator);

        self.pane_id_to_pod_vt.deinit();
        self.pod_vt_to_pane_id.deinit();
        self.pending_poll_fds.deinit(self.allocator);
        self.pending_remove_poll_fds.deinit(self.allocator);
        self.session_locks.deinit();
        self.txlog.deinit();
        // Free txlog_path if it was allocated (not the fallback literal)
        if (!self.txlog_path_is_fallback) {
            self.allocator.free(self.txlog_path);
        }
    }

    /// Add a new client connection
    pub fn addClient(self: *SesState, fd: posix.fd_t) !usize {
        const id = self.next_client_id;
        self.next_client_id += 1;

        try self.clients.append(self.allocator, Client.init(self.allocator, id, fd));
        return id;
    }

    /// Remove a client - behavior depends on keepalive setting
    /// keepalive=true: auto-detach session (preserve for reattach)
    /// keepalive=false: kill all panes
    pub fn removeClient(self: *SesState, client_id: usize) void {
        ses.debugLog("removeClient: client_id={d}", .{client_id});

        // Find and remove client
        var client_index: ?usize = null;
        for (self.clients.items, 0..) |*client, i| {
            if (client.id == client_id) {
                ses.debugLog("removeClient: found client keepalive={} has_session_id={} pane_count={d}", .{
                    client.keepalive,
                    client.session_id != null,
                    client.pane_uuids.items.len,
                });

                if (client.keepalive) {
                    // Auto-detach: preserve session with last known state
                    if (client.session_id) |session_id| {
                        // Use detachSessionDirect to avoid removing client twice
                        self.detachSessionDirect(client, session_id);
                    } else {
                        ses.debugLog("removeClient: no session_id, killing panes", .{});
                        // No session_id yet, just kill panes
                        for (client.pane_uuids.items) |uuid| {
                            self.killPane(uuid) catch |e| {
                                core.logging.logError("ses", "killPane failed in removeClient", e);
                            };
                        }
                    }
                } else {
                    ses.debugLog("removeClient: keepalive=false, killing panes", .{});
                    // No keepalive: kill all panes
                    for (client.pane_uuids.items) |uuid| {
                        self.killPane(uuid) catch |e| {
                            core.logging.logError("ses", "killPane failed in removeClient", e);
                        };
                    }
                }
                // Close connection fds before deinit to prevent fd leaks
                if (client.mux_ctl_fd) |fd| posix.close(fd);
                if (client.mux_vt_fd) |fd| posix.close(fd);
                client.deinit();
                client_index = i;
                break;
            }
        }

        if (client_index) |idx| {
            _ = self.clients.orderedRemove(idx);
        } else {
            ses.debugLog("removeClient: client_id={d} not found", .{client_id});
        }
    }

    /// Remove a client gracefully - mux already handled cleanup, no auto-detach.
    pub fn removeClientGraceful(self: *SesState, client_id: usize) void {
        var client_index: ?usize = null;
        for (self.clients.items, 0..) |*client, i| {
            if (client.id == client_id) {
                // Close connection fds before deinit to prevent fd leaks
                if (client.mux_ctl_fd) |fd| posix.close(fd);
                if (client.mux_vt_fd) |fd| posix.close(fd);
                client.deinit();
                client_index = i;
                break;
            }
        }

        if (client_index) |idx| {
            _ = self.clients.orderedRemove(idx);
        }
    }

    /// Shutdown a client (normal mux exit):
    /// - optionally preserve sticky panes
    /// - kill everything else
    /// - remove client without creating a detached session
    pub fn shutdownClient(self: *SesState, client_id: usize, preserve_sticky: bool) void {
        var client_index: ?usize = null;
        for (self.clients.items, 0..) |*client, i| {
            if (client.id == client_id) {
                for (client.pane_uuids.items) |uuid| {
                    if (preserve_sticky) {
                        if (self.panes.getPtr(uuid)) |pane| {
                            if (pane.sticky_pwd != null and pane.sticky_key != null) {
                                _ = pane.transitionState(.sticky, "mux shutdown with sticky pwd");
                                pane.attached_to = null;
                                continue;
                            }
                        }
                    }
                    self.killPane(uuid) catch |e| {
                        core.logging.logError("ses", "killPane failed in shutdownClient", e);
                    };
                }

                // Close connection fds before deinit to prevent fd leaks
                if (client.mux_ctl_fd) |fd| posix.close(fd);
                if (client.mux_vt_fd) |fd| posix.close(fd);
                client.deinit();
                client_index = i;
                break;
            }
        }

        if (client_index) |idx| {
            _ = self.clients.orderedRemove(idx);
        }
        self.dirty = true;
    }

    /// Internal: detach session without removing client (used by removeClient)
    fn detachSessionDirect(self: *SesState, client: *Client, session_id: [16]u8) void {
        const hex_id: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
        ses.debugLog("detachSessionDirect: session={s} name={s}", .{ hex_id[0..8], client.session_name orelse "null" });

        // Transaction log: detach start
        self.txlog.write(.detach_start, session_id, &hex_id) catch {};

        var pane_uuids_list: std.ArrayList([32]u8) = .empty;

        // Mark all panes as detached and collect UUIDs
        for (client.pane_uuids.items) |uuid| {
            if (self.panes.getPtr(uuid)) |pane| {
                _ = pane.transitionState(.detached, "session detach");
                pane.session_id = session_id;
                pane.attached_to = null;

                // Detach SES<->POD VT while session is detached so POD can
                // retain output in backlog for replay on reattach.
                if (pane.pod_vt_fd) |vt_fd| {
                    _ = self.pod_vt_to_pane_id.remove(vt_fd);
                    _ = self.pane_id_to_pod_vt.remove(pane.pane_id);
                    self.pending_remove_poll_fds.append(self.allocator, vt_fd) catch {};
                    posix.close(vt_fd);
                    pane.pod_vt_fd = null;
                }

                pane_uuids_list.append(self.allocator, uuid) catch continue;
            }
        }
        ses.debugLog("detachSessionDirect: marked {d} panes as detached", .{pane_uuids_list.items.len});

        // If session already exists (re-detach), remove old state first
        if (self.detached_sessions.fetchRemove(session_id)) |old| {
            var old_state = old.value;
            old_state.deinit();
            ses.debugLog("detachSessionDirect: replaced existing detached session", .{});
        }

        const session_snapshot = self.buildDetachedSessionSnapshot(client, session_id) catch {
            ses.debugLog("detachSessionDirect: failed to build session_snapshot", .{});
            pane_uuids_list.deinit(self.allocator);
            return;
        };
        errdefer {
            var snapshot = session_snapshot;
            snapshot.deinit();
        }

        const owned_uuids = pane_uuids_list.toOwnedSlice(self.allocator) catch {
            ses.debugLog("detachSessionDirect: failed to toOwnedSlice", .{});
            return;
        };

        const detached_state = DetachedSessionState{
            .session_id = session_id,
            .session_snapshot = session_snapshot,
            .pane_uuids = owned_uuids,
            .detached_at = std.time.timestamp(),
            .allocator = self.allocator,
        };

        self.detached_sessions.put(session_id, detached_state) catch {
            ses.debugLog("detachSessionDirect: failed to put detached_state", .{});
            var snapshot = session_snapshot;
            snapshot.deinit();
            self.allocator.free(owned_uuids);
            return;
        };
        ses.debugLog("detachSessionDirect: success, detached_sessions.count={d}", .{self.detached_sessions.count()});
        self.dirty = true;

        // Transaction log: detach commit
        self.txlog.write(.detach_commit, session_id, &hex_id) catch {};
    }

    /// Detach a client's session with a specific session ID (frontend UUID)
    /// Stores the canonical SES session snapshot for later restoration
    /// If the session already exists (re-detach), it updates the existing state
    /// Returns true on success, false if client not found
    pub fn detachSession(self: *SesState, client_id: usize, session_id: [16]u8, session_name: []const u8) bool {
        // Find client
        var client_index: ?usize = null;
        var pane_uuids_list: std.ArrayList([32]u8) = .empty;
        var detached_snapshot: ?session_model.SessionSnapshot = null;

        _ = session_name;

        // Backup for rollback: track original pane states before modification
        const PaneBackup = struct {
            uuid: [32]u8,
            state: PaneState,
            session_id: ?[16]u8,
            attached_to: ?usize,
        };
        var pane_backups: std.ArrayList(PaneBackup) = .empty;
        defer pane_backups.deinit(self.allocator);

        for (self.clients.items, 0..) |*client, i| {
            if (client.id == client_id) {
                detached_snapshot = self.buildDetachedSessionSnapshot(client, session_id) catch {
                    ses.debugLog("detachSession: failed to build session_snapshot", .{});
                    return false;
                };

                // Mark all panes as detached with session_id and collect UUIDs
                for (client.pane_uuids.items) |uuid| {
                    if (self.panes.getPtr(uuid)) |pane| {
                        // Save original state for rollback
                        pane_backups.append(self.allocator, .{
                            .uuid = uuid,
                            .state = pane.state,
                            .session_id = pane.session_id,
                            .attached_to = pane.attached_to,
                        }) catch continue;

                        // Apply new state
                        _ = pane.transitionState(.detached, "atomic detach");
                        pane.session_id = session_id;
                        pane.attached_to = null;

                        // Detach SES<->POD VT channel while session is detached.
                        // This prevents SES from draining and discarding output
                        // when no mux is attached, so POD can replay backlog on
                        // reattach.
                        if (pane.pod_vt_fd) |vt_fd| {
                            _ = self.pod_vt_to_pane_id.remove(vt_fd);
                            _ = self.pane_id_to_pod_vt.remove(pane.pane_id);
                            self.pending_remove_poll_fds.append(self.allocator, vt_fd) catch {};
                            posix.close(vt_fd);
                            pane.pod_vt_fd = null;
                        }

                        pane_uuids_list.append(self.allocator, uuid) catch continue;
                    }
                }
                client.deinit();
                client_index = i;
                break;
            }
        }

        if (client_index) |idx| {
            _ = self.clients.orderedRemove(idx);

            // If session already exists (re-detach), remove old state first
            if (self.detached_sessions.fetchRemove(session_id)) |old| {
                var old_state = old.value;
                old_state.deinit();
            }

            const session_snapshot = detached_snapshot orelse {
                ses.debugLog("detachSession: missing detached snapshot", .{});
                pane_uuids_list.deinit(self.allocator);
                for (pane_backups.items) |backup| {
                    if (self.panes.getPtr(backup.uuid)) |pane| {
                        _ = pane.transitionState(backup.state, "detach rollback (missing session snapshot)");
                        pane.session_id = backup.session_id;
                        pane.attached_to = backup.attached_to;
                    }
                }
                return false;
            };
            errdefer {
                var snapshot = session_snapshot;
                snapshot.deinit();
            }

            const owned_uuids = pane_uuids_list.toOwnedSlice(self.allocator) catch {
                ses.debugLog("detachSession: failed to toOwnedSlice, rolling back", .{});
                var snapshot = session_snapshot;
                snapshot.deinit();
                // Rollback pane states
                for (pane_backups.items) |backup| {
                    if (self.panes.getPtr(backup.uuid)) |pane| {
                        _ = pane.transitionState(backup.state, "detach rollback (uuid list alloc failure)");
                        pane.session_id = backup.session_id;
                        pane.attached_to = backup.attached_to;
                    }
                }
                return false;
            };

            const detached_state = DetachedSessionState{
                .session_id = session_id,
                .session_snapshot = session_snapshot,
                .pane_uuids = owned_uuids,
                .detached_at = std.time.timestamp(),
                .allocator = self.allocator,
            };

            self.detached_sessions.put(session_id, detached_state) catch {
                ses.debugLog("detachSession: failed to put detached_state, rolling back", .{});
                var snapshot = session_snapshot;
                snapshot.deinit();
                self.allocator.free(owned_uuids);
                // Rollback pane states
                for (pane_backups.items) |backup| {
                    if (self.panes.getPtr(backup.uuid)) |pane| {
                        _ = pane.transitionState(backup.state, "detach rollback (session map put failure)");
                        pane.session_id = backup.session_id;
                        pane.attached_to = backup.attached_to;
                    }
                }
                return false;
            };
            self.dirty = true;

            return true;
        } else {
            pane_uuids_list.deinit(self.allocator);
        }
        return false;
    }

    /// Result of reattaching a session
    pub const ReattachResult = struct {
        session_snapshot: *const session_model.SessionSnapshot,
        pane_uuids: [][32]u8, // UUIDs of panes to adopt
    };

    /// Reattach to a detached session - returns the canonical session snapshot and pane UUIDs.
    /// The session is NOT removed from detached_sessions yet — call
    /// removeDetachedSession() after the terminal frontend confirms successful restore.
    pub fn reattachSession(self: *SesState, session_id: [16]u8, client_id: usize) !?ReattachResult {
        self.pruneDetachedSessionPanes(session_id);

        // Find the detached session (don't remove yet).
        const detached_state = self.detached_sessions.getPtr(session_id) orelse return null;

        // Seed the live client snapshot from detached state before frontend
        // restore begins. Reattach can issue semantic mutations (tab add/remove,
        // float sync, focus updates) before final register completes.
        if (self.getClient(client_id)) |client| {
            client.updateSessionSnapshot(try detached_state.session_snapshot.clone(self.allocator));
        }

        // Return the stored state (caller borrows — session stays in map as safety net).
        return .{
            .session_snapshot = &detached_state.session_snapshot,
            .pane_uuids = detached_state.pane_uuids,
        };
    }

    /// Force-detach an actively attached session so another mux can attach.
    /// Returns true when an attached owner was found and detached.
    pub fn forceDetachAttachedSession(self: *SesState, session_id: [16]u8) bool {
        var owner_index: ?usize = null;

        for (self.clients.items, 0..) |client, i| {
            if (client.session_id) |sid| {
                if (std.mem.eql(u8, &sid, &session_id)) {
                    owner_index = i;
                    break;
                }
            }
        }

        const idx = owner_index orelse return false;
        const owner = &self.clients.items[idx];

        // Tell the current owner mux to terminate cleanly.
        if (owner.mux_ctl_fd) |mfd| {
            wire.writeControl(mfd, .session_stolen, &.{}) catch {};
        }

        // Move all panes/session metadata into detached storage.
        self.detachSessionDirect(owner, session_id);

        // Close owner channels and remove the owner client.
        posix.close(owner.fd);
        if (owner.mux_ctl_fd) |fd| posix.close(fd);
        if (owner.mux_vt_fd) |fd| posix.close(fd);
        owner.deinit();
        _ = self.clients.orderedRemove(idx);

        self.dirty = true;
        return true;
    }

    /// Remove a detached session after successful reattach.
    pub fn removeDetachedSession(self: *SesState, session_id: [16]u8) void {
        if (self.detached_sessions.fetchRemove(session_id)) |kv| {
            // Clear session_id from panes so they can be adopted.
            for (kv.value.pane_uuids) |uuid| {
                if (self.panes.getPtr(uuid)) |pane| {
                    pane.session_id = null;
                }
            }
            var state = kv.value;
            state.deinit();
            self.dirty = true;
        }
    }

    /// List detached sessions
    pub fn listDetachedSessions(self: *SesState, allocator: std.mem.Allocator) ![]DetachedSession {
        var result: std.ArrayList(DetachedSession) = .empty;
        errdefer result.deinit(allocator);

        var iter = self.detached_sessions.valueIterator();
        while (iter.next()) |detached| {
            try result.append(allocator, .{
                .session_id = detached.session_id,
                .session_name = detached.session_snapshot.session_name,
                .pane_count = detached.pane_uuids.len,
            });
        }

        return result.toOwnedSlice(allocator);
    }

    /// Get client by ID
    pub fn getClient(self: *SesState, client_id: usize) ?*Client {
        for (self.clients.items) |*client| {
            if (client.id == client_id) return client;
        }
        return null;
    }

    /// Orphan a pane (either half or full depending on sticky)
    fn orphanPane(self: *SesState, pane: *Pane) void {
        _ = self;
        const now = std.time.timestamp();

        if (pane.sticky_pwd != null and pane.sticky_key != null) {
            // Sticky pwd float - becomes half-orphaned
            _ = pane.transitionState(.sticky, "disown with sticky pwd");
        } else {
            // Regular pane - becomes fully orphaned
            _ = pane.transitionState(.orphaned, "disown without sticky pwd");
        }

        pane.attached_to = null;
        pane.orphaned_at = now;
    }

    /// Create a new pane by spawning a per-pane pod process.
    pub fn createPane(
        self: *SesState,
        client_id: usize,
        shell: []const u8,
        cwd: ?[]const u8,
        sticky_pwd: ?[]const u8,
        sticky_key: ?u8,
        env: ?[]const []const u8,
        isolation_profile: ?[]const u8,
    ) !*Pane {
        const uuid = ipc.generateUuid();
        const base_name = ipc.generatePaneName();
        const name = try self.generateUniquePaneName(base_name);
        ses.debugLog("createPane: generated name='{s}'", .{name});
        errdefer self.allocator.free(name);
        const pod_socket_path = try ipc.getPodSocketPath(self.allocator, &uuid);
        errdefer self.allocator.free(pod_socket_path);

        const spawn = try self.spawnPod(uuid, name, pod_socket_path, shell, cwd, env, isolation_profile);

        // Copy sticky_pwd if provided
        const owned_pwd: ?[]const u8 = if (sticky_pwd) |pwd|
            try self.allocator.dupe(u8, pwd)
        else
            null;
        errdefer if (owned_pwd) |pwd| self.allocator.free(pwd);

        const now = std.time.timestamp();

        const pane_id = self.allocPaneId();

        const pane = Pane{
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

        // Add errdefer to clean up pane resources if put fails
        errdefer {
            if (pane.name) |n| self.allocator.free(n);
            self.allocator.free(pane.pod_socket_path);
            if (pane.sticky_pwd) |pwd| self.allocator.free(pwd);
        }

        try self.panes.put(uuid, pane);
        self.dirty = true;

        // Connect VT channel (③) to POD. If this fails, the pod either died
        // before VT attach or never became usable, so tear it down now.
        if (!self.connectPodVt(uuid, pod_socket_path, pane_id)) {
            self.killPane(uuid) catch {};
            return error.PodVtAttachFailed;
        }

        // Add to client's pane list
        if (self.getClient(client_id)) |client| {
            try client.appendUuid(uuid);
        }

        return self.panes.getPtr(uuid).?;
    }

    fn generateUniquePaneName(self: *SesState, base: []const u8) ![]const u8 {
        // Names are per-ses daemon, so keep them unique among all panes we track.
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const candidate = if (attempt == 0)
                try self.allocator.dupe(u8, base)
            else
                try std.fmt.allocPrint(self.allocator, "{s}-{d}", .{ base, attempt + 1 });

            var used = false;
            var it = self.panes.valueIterator();
            while (it.next()) |p| {
                if (p.name) |n| {
                    if (std.mem.eql(u8, n, candidate)) {
                        used = true;
                        break;
                    }
                }
            }

            if (!used) return candidate;
            self.allocator.free(candidate);
        }
    }

    fn spawnPod(
        self: *SesState,
        uuid: [32]u8,
        name: []const u8,
        pod_socket_path: []const u8,
        shell: []const u8,
        cwd: ?[]const u8,
        env: ?[]const []const u8,
        isolation_profile: ?[]const u8,
    ) !struct { pod_pid: posix.pid_t, child_pid: posix.pid_t } {
        var args_list: std.ArrayList([]const u8) = .empty;
        defer args_list.deinit(self.allocator);

        const exe_path = try std.fs.selfExePathAlloc(self.allocator);
        defer self.allocator.free(exe_path);

        try args_list.append(self.allocator, exe_path);
        try args_list.append(self.allocator, "pod");
        try args_list.append(self.allocator, "daemon");

        // Propagate instance/test-only flags for debugging/clarity.
        // Runtime behavior is primarily controlled by environment (HEXE_INSTANCE).
        if (posix.getenv("HEXE_INSTANCE")) |inst| {
            if (inst.len > 0) {
                try args_list.append(self.allocator, "--instance");
                try args_list.append(self.allocator, inst);
            }
        }
        if (posix.getenv("HEXE_TEST_ONLY")) |v| {
            if (v.len > 0 and !std.mem.eql(u8, v, "0")) {
                try args_list.append(self.allocator, "--test-only");
            }
        }

        try args_list.append(self.allocator, "--uuid");
        try args_list.append(self.allocator, uuid[0..]);
        try args_list.append(self.allocator, "--name");
        try args_list.append(self.allocator, name);
        try args_list.append(self.allocator, "--socket");
        try args_list.append(self.allocator, pod_socket_path);
        try args_list.append(self.allocator, "--shell");
        try args_list.append(self.allocator, shell);
        if (cwd) |dir| {
            try args_list.append(self.allocator, "--cwd");
            try args_list.append(self.allocator, dir);
        }
        if (ses.active_log_level) |level| {
            try args_list.append(self.allocator, "--log");
            try args_list.append(self.allocator, @tagName(level));
        }
        if (ses.log_file_path) |path| {
            try args_list.append(self.allocator, "--logfile");
            try args_list.append(self.allocator, path);
        }
        try args_list.append(self.allocator, "--foreground");

        ses.traceLog(
            "spawnPod uuid={s} name={s} socket={s} shell={s} cwd={s} log_level={s}",
            .{
                uuid[0..8],
                name,
                pod_socket_path,
                shell,
                cwd orelse "(none)",
                if (ses.active_log_level) |level| @tagName(level) else "off",
            },
        );

        var child = std.process.Child.init(args_list.items, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.stdout_behavior = .Pipe;

        var env_map_storage: ?std.process.EnvMap = null;
        defer if (env_map_storage) |*map| map.deinit();

        const instance_env = posix.getenv("HEXE_INSTANCE");
        const test_only_env = posix.getenv("HEXE_TEST_ONLY");
        const needs_runtime_env = (instance_env != null and instance_env.?.len > 0) or
            (test_only_env != null and test_only_env.?.len > 0) or
            (isolation_profile != null and isolation_profile.?.len > 0);

        if (env != null or needs_runtime_env) {
            // Start from the current SES environment so spawned pods keep
            // basic runtime variables like PATH, HOME, and XDG_RUNTIME_DIR.
            // Ad-hoc float env is meant to overlay this, not replace it.
            var env_map = try std.process.getEnvMap(self.allocator);

            if (env) |vars| {
                for (vars) |entry| {
                    const sep = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
                    if (sep == 0 or sep + 1 > entry.len) continue;
                    try env_map.put(entry[0..sep], entry[sep + 1 ..]);
                }
            }

            // Force instance/test-only values from this ses process.
            // This prevents user-provided env overrides from escaping the instance namespace.
            if (instance_env) |inst| {
                if (inst.len > 0) try env_map.put("HEXE_INSTANCE", inst);
            }
            if (test_only_env) |v| {
                if (v.len > 0) try env_map.put("HEXE_TEST_ONLY", v);
            }

            // Add isolation profile if specified
            if (isolation_profile) |profile| {
                if (profile.len > 0) {
                    ses.debugLog("spawnPod: setting HEXE_VOIDBOX_PROFILE={s}", .{profile});
                    try env_map.put("HEXE_VOIDBOX_PROFILE", profile);
                }
            } else {
                ses.debugLog("spawnPod: isolation_profile is null", .{});
            }

            env_map_storage = env_map;
            child.env_map = &env_map_storage.?;
            ses.traceLog("spawnPod: custom env map entries={d}", .{env_map_storage.?.count()});
        }

        try child.spawn();
        const pod_pid: posix.pid_t = @intCast(child.id);

        var stdout_file = child.stdout orelse return error.PodNoStdout;
        defer stdout_file.close();

        const spawn_timeout_ms: i64 = core.constants.Timing.ses_spawn_timeout;
        const deadline_ms = std.time.milliTimestamp() + spawn_timeout_ms;
        const stdout_fd = stdout_file.handle;

        var line_buf: [512]u8 = undefined;
        var pos: usize = 0;
        while (pos < line_buf.len) {
            const remaining_ms = deadline_ms - std.time.milliTimestamp();
            if (remaining_ms <= 0) return error.PodSpawnTimeout;

            wire.waitReadableTimeout(stdout_fd, @intCast(remaining_ms)) catch |err| switch (err) {
                error.Timeout => return error.PodSpawnTimeout,
                else => return err,
            };

            var one: [1]u8 = undefined;
            const n = try stdout_file.read(&one);
            if (n == 0) break;
            if (one[0] == '\n') break;
            line_buf[pos] = one[0];
            pos += 1;
        }
        if (pos == 0) return error.PodNoHandshake;
        const line = line_buf[0..pos];

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, line, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        const pid_val = (root.get("pid") orelse return error.PodBadHandshake).integer;
        const child_pid: posix.pid_t = @intCast(pid_val);

        return .{ .pod_pid = pod_pid, .child_pid = child_pid };
    }

    /// Find a half-orphaned sticky pane matching pwd and key
    /// Find a sticky pane by pwd and key, with optional session affinity.
    /// If preferred_session_name is provided, prefer panes from that session.
    pub fn findStickyPane(self: *SesState, pwd: []const u8, key: u8) ?*Pane {
        return self.findStickyPaneWithAffinity(pwd, key, null);
    }

    /// Find a sticky pane with session affinity preference.
    pub fn findStickyPaneWithAffinity(self: *SesState, pwd: []const u8, key: u8, preferred_session_name: ?[]const u8) ?*Pane {
        var fallback_pane: ?*Pane = null;

        var iter = self.panes.valueIterator();
        while (iter.next()) |pane| {
            // Sticky candidates can be idle (.sticky) or currently active
            // (.attached). Active ones may be taken over by another mux.
            if (pane.state == .sticky or pane.state == .attached) {
                if (!isPidAlive(pane.child_pid)) continue;
                if (pane.sticky_pwd) |spwd| {
                    if (pane.sticky_key) |skey| {
                        if (skey == key and std.mem.eql(u8, spwd, pwd)) {
                            // Check for session affinity
                            if (preferred_session_name) |psn| {
                                if (pane.sticky_session_name) |ssn| {
                                    if (std.mem.eql(u8, ssn, psn)) {
                                        // Perfect match - same session
                                        ses.debugLog("findStickyPane: affinity match (session={s})", .{psn});
                                        return @constCast(pane);
                                    }
                                }
                            }
                            // Save as fallback
                            if (fallback_pane == null) {
                                fallback_pane = @constCast(pane);
                            }
                        }
                    }
                }
            }
        }

        // Return fallback if no affinity match found
        if (fallback_pane != null) {
            if (preferred_session_name) |psn| {
                ses.debugLog("findStickyPane: using fallback (preferred={s})", .{psn});
            }
        }
        return fallback_pane;
    }

    fn isPidAlive(pid: posix.pid_t) bool {
        if (pid <= 0) return false;
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return false;
        const file = std.fs.openFileAbsolute(path, .{}) catch return false;
        file.close();
        return true;
    }

    /// Transfer a pane from its current owner to another client.
    /// Sends pane_exited to the previous owner so it tears down renderer state.
    pub fn stealAttachedPane(self: *SesState, uuid: [32]u8, new_client_id: usize) bool {
        const pane = self.panes.getPtr(uuid) orelse return false;
        const old_client_id = pane.attached_to orelse return true;
        if (old_client_id == new_client_id) return true;

        if (self.getClient(old_client_id)) |old_client| {
            // Tell previous mux this pane is gone from its viewport.
            if (old_client.mux_ctl_fd) |ctl_fd| {
                var msg: wire.PaneUuid = .{ .uuid = uuid };
                wire.writeControl(ctl_fd, .pane_exited, std.mem.asBytes(&msg)) catch {};
            }

            // Remove pane from previous owner's list.
            var i: usize = 0;
            while (i < old_client.pane_uuids.items.len) {
                if (std.mem.eql(u8, &old_client.pane_uuids.items[i], &uuid)) {
                    _ = old_client.pane_uuids.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        pane.attached_to = null;
        if (pane.sticky_pwd != null and pane.sticky_key != null) {
            _ = pane.transitionState(.sticky, "sticky pane takeover");
        } else {
            _ = pane.transitionState(.orphaned, "pane takeover");
        }
        pane.orphaned_at = std.time.timestamp();
        self.dirty = true;
        return true;
    }

    /// Attach an orphaned/detached pane to a client.
    /// Marks pane for deferred backlog replay (processed by server loop).
    pub fn attachPane(self: *SesState, uuid: [32]u8, client_id: usize) !*Pane {
        const pane = self.panes.getPtr(uuid) orelse return error.PaneNotFound;

        ses.debugLog("attachPane: uuid={s} state={s} client_id={d}", .{
            uuid[0..8],
            @tagName(pane.state),
            client_id,
        });

        if (pane.state == .attached) {
            return error.PaneAlreadyAttached;
        }

        // Defensive: if ownership is still set, do not steal silently.
        if (pane.attached_to != null and pane.attached_to.? != client_id) {
            return error.PaneAlreadyAttached;
        }

        // Only request deferred VT reconnect/backlog replay when we currently
        // have no pod VT channel. In the common detach/reattach path SES keeps
        // pod_vt_fd alive, so reconnecting here would unnecessarily replace a
        // healthy stream and can stall old panes during attach.
        pane.needs_backlog_replay = (pane.pod_vt_fd == null);
        if (pane.needs_backlog_replay) {
            ses.debugLog("attachPane: marked for deferred backlog replay", .{});
        } else {
            ses.debugLog("attachPane: pod VT already connected, replay not needed", .{});
        }

        _ = pane.transitionState(.attached, "pane attached to client");
        pane.attached_to = client_id;
        pane.orphaned_at = null;
        self.dirty = true;

        // Add to client's pane list - fail if client not found
        const client = self.getClient(client_id) orelse return error.ClientNotFound;
        try client.appendUuid(uuid);

        ses.debugLog("attachPane: success, pane_id={d}", .{pane.pane_id});
        return pane;
    }

    /// Process panes that need backlog replay (called from server loop).
    /// Reconnects VT channel to each marked pane, triggering POD backlog replay.
    pub fn processBacklogReplays(self: *SesState) void {
        var stale_panes: std.ArrayList([32]u8) = .empty;
        defer stale_panes.deinit(self.allocator);

        var iter = self.panes.iterator();
        while (iter.next()) |entry| {
            const pane = entry.value_ptr;
            if (pane.needs_backlog_replay) {
                if (paneProcessDead(pane)) {
                    ses.debugLog("processBacklogReplays: pruning dead pane uuid={s}", .{entry.key_ptr[0..8]});
                    stale_panes.append(self.allocator, entry.key_ptr.*) catch {};
                    continue;
                }

                // Wait until the owning mux VT channel is attached before
                // reconnecting to POD VT. If we reconnect too early, POD will
                // stream backlog immediately and SES may discard it because no
                // mux VT fd exists yet.
                const owner_id = pane.attached_to orelse {
                    ses.debugLog("processBacklogReplays: skip uuid={s} (no owner)", .{entry.key_ptr[0..8]});
                    continue;
                };
                const owner = self.getClient(owner_id) orelse {
                    ses.debugLog("processBacklogReplays: skip uuid={s} (owner missing)", .{entry.key_ptr[0..8]});
                    continue;
                };
                if (owner.mux_vt_fd == null) {
                    ses.debugLog("processBacklogReplays: defer uuid={s} (mux VT not ready)", .{entry.key_ptr[0..8]});
                    continue;
                }

                ses.debugLog("processBacklogReplays: uuid={s} pane_id={d}", .{
                    entry.key_ptr[0..8],
                    pane.pane_id,
                });
                // Reconnect VT channel to trigger backlog replay
                if (self.connectPodVt(entry.key_ptr.*, pane.pod_socket_path, pane.pane_id)) {
                    pane.needs_backlog_replay = false;
                } else {
                    if (paneProcessDead(pane)) {
                        ses.debugLog("processBacklogReplays: connect failed for dead pane uuid={s}", .{entry.key_ptr[0..8]});
                        stale_panes.append(self.allocator, entry.key_ptr.*) catch {};
                        continue;
                    }

                    // Keep the flag set so periodic retries can reconnect once
                    // the pod VT endpoint is ready.
                    ses.debugLog("processBacklogReplays: deferred retry uuid={s}", .{entry.key_ptr[0..8]});
                }
            }
        }

        for (stale_panes.items) |pane_uuid| {
            self.killPane(pane_uuid) catch {};
        }
    }

    /// Manually orphan a pane (user requested suspend)
    pub fn suspendPane(self: *SesState, uuid: [32]u8) !void {
        const pane = self.panes.getPtr(uuid) orelse return error.PaneNotFound;

        // Remove from client's list
        if (pane.attached_to) |client_id| {
            if (self.getClient(client_id)) |client| {
                var i: usize = 0;
                while (i < client.pane_uuids.items.len) {
                    if (std.mem.eql(u8, &client.pane_uuids.items[i], &uuid)) {
                        _ = client.pane_uuids.orderedRemove(i);
                    } else {
                        i += 1;
                    }
                }
            }
        }

        // Check if sticky info is set - becomes sticky, otherwise orphaned
        if (pane.sticky_pwd != null and pane.sticky_key != null) {
            _ = pane.transitionState(.sticky, "suspend with sticky pwd");
            ses.debugLog("suspendPane: {s} pwd={s}, key={c}", .{ uuid[0..8], pane.sticky_pwd.?, pane.sticky_key.? });
        } else {
            _ = pane.transitionState(.orphaned, "suspend without sticky pwd");
            ses.debugLog("suspendPane: {s} pwd={any}, key={any}", .{ uuid[0..8], pane.sticky_pwd != null, pane.sticky_key != null });
        }
        pane.attached_to = null;
        pane.orphaned_at = std.time.timestamp();
        self.dirty = true;
    }

    /// Kill a pane
    pub fn killPane(self: *SesState, uuid: [32]u8) !void {
        const hex_uuid: [32]u8 = std.fmt.bytesToHex(uuid[0..16], .lower);
        var pane = self.panes.fetchRemove(uuid) orelse {
            ses.debugLog("killPane: {s} NOT FOUND", .{hex_uuid[0..8]});
            return error.PaneNotFound;
        };
        self.dirty = true;
        ses.debugLog("killPane: {s} pane_id={d} pod_pid={d} pod_vt_fd={?d} state={s}", .{
            hex_uuid[0..8],
            pane.value.pane_id,
            pane.value.pod_pid,
            pane.value.pod_vt_fd,
            @tagName(pane.value.state),
        });

        // Remove from client's pane_uuids list if attached
        if (pane.value.attached_to) |client_id| {
            if (self.getClient(client_id)) |client| {
                var i: usize = 0;
                while (i < client.pane_uuids.items.len) {
                    if (std.mem.eql(u8, &client.pane_uuids.items[i], &uuid)) {
                        _ = client.pane_uuids.orderedRemove(i);
                    } else {
                        i += 1;
                    }
                }
            }
            self.prunePaneFromClientSnapshot(client_id, uuid);
        } else if (pane.value.session_id) |session_id| {
            self.prunePaneFromDetachedSnapshot(session_id, uuid);
        }

        if (pane.value.pod_vt_fd) |vt_fd| {
            ses.debugLog("killPane: {s} closing pod_vt_fd={d}, removing from routing tables", .{ hex_uuid[0..8], vt_fd });
            _ = self.pod_vt_to_pane_id.remove(vt_fd);
            _ = self.pane_id_to_pod_vt.remove(pane.value.pane_id);
            self.pending_remove_poll_fds.append(self.allocator, vt_fd) catch {};
            posix.close(vt_fd);
        } else {
            ses.debugLog("killPane: {s} pod_vt_fd=null, removing pane_id from routing", .{hex_uuid[0..8]});
            _ = self.pane_id_to_pod_vt.remove(pane.value.pane_id);
        }

        // Stop pod process (which owns PTY)
        ses.debugLog("killPane: {s} sending SIGTERM to pid={d}", .{ hex_uuid[0..8], pane.value.pod_pid });
        _ = std.c.kill(pane.value.pod_pid, std.c.SIG.TERM);

        // Clean up
        pane.value.deinit();
        ses.debugLog("killPane: {s} done", .{hex_uuid[0..8]});
    }

    /// Get all orphaned panes
    pub fn getOrphanedPanes(self: *SesState, allocator: std.mem.Allocator) ![]Pane {
        var result: std.ArrayList(Pane) = .empty;
        errdefer result.deinit(allocator);

        var iter = self.panes.valueIterator();
        while (iter.next()) |pane| {
            if (pane.state == .orphaned or pane.state == .sticky) {
                try result.append(allocator, pane.*);
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Clean up timed-out orphaned panes
    pub fn cleanupOrphanedPanes(self: *SesState) void {
        const now = std.time.timestamp();
        const timeout_secs = @as(i64, @intCast(self.orphan_timeout_hours)) * 3600;

        var to_remove: std.ArrayList([32]u8) = .empty;
        defer to_remove.deinit(self.allocator);

        var iter = self.panes.iterator();
        while (iter.next()) |entry| {
            const pane = entry.value_ptr;
            if (pane.state == .orphaned or pane.state == .sticky) {
                if (pane.orphaned_at) |orphaned_time| {
                    if (now - orphaned_time > timeout_secs) {
                        to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
                    }
                }
            }
        }

        for (to_remove.items) |uuid| {
            self.killPane(uuid) catch |e| {
                core.logging.logError("ses", "killPane failed in cleanupTimedOut", e);
            };
        }
    }

    /// Clean up expired detached sessions (TTL enforcement)
    pub fn cleanupExpiredDetachedSessions(self: *SesState) void {
        if (self.detached_session_ttl_hours == 0) return; // 0 = disabled

        const now = std.time.timestamp();
        const ttl_secs = @as(i64, @intCast(self.detached_session_ttl_hours)) * 3600;

        var to_remove: std.ArrayList([16]u8) = .empty;
        defer to_remove.deinit(self.allocator);

        var iter = self.detached_sessions.iterator();
        while (iter.next()) |entry| {
            const session = entry.value_ptr;
            if (now - session.detached_at > ttl_secs) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |session_id| {
            // Remove session from detached_sessions map
            if (self.detached_sessions.fetchRemove(session_id)) |kv| {
                var session_state = kv.value;

                // Kill all panes in the session
                for (session_state.pane_uuids) |pane_uuid| {
                    self.killPane(pane_uuid) catch |e| {
                        core.logging.logError("ses", "killPane failed in cleanupExpiredSessions", e);
                    };
                }

                session_state.deinit();
                self.dirty = true;
            }
        }
    }

    /// Clean up detached sessions:
    /// 1. Remove sessions with no live panes (all panes dead)
    /// 2. Remove duplicate sessions with same name (keep most recent)
    pub fn cleanupDetachedSessions(self: *SesState) void {
        var to_remove: std.ArrayList([16]u8) = .empty;
        defer to_remove.deinit(self.allocator);

        // First pass: find sessions with no live panes
        var iter = self.detached_sessions.iterator();
        while (iter.next()) |entry| {
            const session = entry.value_ptr;
            var has_live_panes = false;

            for (session.pane_uuids) |pane_uuid| {
                if (self.panes.get(pane_uuid)) |pane| {
                    // Check if pod process is still alive
                    if (std.c.kill(pane.pod_pid, 0) == 0) {
                        has_live_panes = true;
                        break;
                    }
                }
            }

            if (!has_live_panes) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
                ses.debugLog("cleanup: session {s} has no live panes, removing", .{session.session_snapshot.session_name});
            }
        }

        // Second pass: find duplicate names (keep most recent)
        var name_to_newest = std.StringHashMap(struct { session_id: [16]u8, detached_at: i64 }).init(self.allocator);
        defer name_to_newest.deinit();

        iter = self.detached_sessions.iterator();
        while (iter.next()) |entry| {
            const session = entry.value_ptr;
            const name = session.session_snapshot.session_name;

            if (name_to_newest.get(name)) |existing| {
                // Duplicate name found - keep the newer one
                if (session.detached_at > existing.detached_at) {
                    // Current is newer, remove the old one
                    to_remove.append(self.allocator, existing.session_id) catch continue;
                    name_to_newest.put(name, .{ .session_id = entry.key_ptr.*, .detached_at = session.detached_at }) catch continue;
                    ses.debugLog("cleanup: removing older duplicate session '{s}'", .{name});
                } else {
                    // Old is newer, remove current
                    to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
                    ses.debugLog("cleanup: removing older duplicate session '{s}'", .{name});
                }
            } else {
                name_to_newest.put(name, .{ .session_id = entry.key_ptr.*, .detached_at = session.detached_at }) catch continue;
            }
        }

        // Remove collected sessions
        for (to_remove.items) |session_id| {
            if (self.detached_sessions.fetchRemove(session_id)) |kv| {
                var session_state = kv.value;

                // Kill orphaned panes
                for (session_state.pane_uuids) |pane_uuid| {
                    self.killPane(pane_uuid) catch {};
                }

                session_state.deinit();
                self.dirty = true;
            }
        }

        if (to_remove.items.len > 0) {
            ses.debugLog("cleanup: removed {d} sessions, {d} remaining", .{ to_remove.items.len, self.detached_sessions.count() });
        }
    }

    /// Check if a pane's pod process is still alive.
    pub fn checkPaneAlive(self: *SesState, uuid: [32]u8) bool {
        const pane = self.panes.get(uuid) orelse return false;
        // kill(pid, 0) checks existence/permission without sending a signal.
        return std.c.kill(pane.pod_pid, 0) == 0;
    }

    /// Get pane by UUID
    pub fn getPane(self: *SesState, uuid: [32]u8) ?*Pane {
        return self.panes.getPtr(uuid);
    }

    /// Kill a detached session by its 16-byte binary session_id.
    /// Returns the number of panes killed, or null if session not found.
    pub fn killDetachedSession(self: *SesState, session_id: [16]u8) ?usize {
        const kv = self.detached_sessions.fetchRemove(session_id) orelse return null;
        var session_state = kv.value;

        var killed_panes: usize = 0;
        for (session_state.pane_uuids) |pane_uuid| {
            self.killPane(pane_uuid) catch |e| {
                core.logging.logError("ses", "killPane failed in killDetachedSession", e);
                continue;
            };
            killed_panes += 1;
        }

        session_state.deinit();
        self.dirty = true;
        return killed_panes;
    }

    /// Kill all detached sessions.
    /// Returns the number of sessions and panes killed.
    pub fn killAllDetachedSessions(self: *SesState) struct { sessions: usize, panes: usize } {
        var session_ids: std.ArrayList([16]u8) = .empty;
        defer session_ids.deinit(self.allocator);

        // Collect all session IDs first to avoid iterator invalidation.
        var iter = self.detached_sessions.keyIterator();
        while (iter.next()) |key| {
            session_ids.append(self.allocator, key.*) catch continue;
        }

        var total_sessions: usize = 0;
        var total_panes: usize = 0;

        for (session_ids.items) |session_id| {
            if (self.killDetachedSession(session_id)) |panes_killed| {
                total_sessions += 1;
                total_panes += panes_killed;
            }
        }

        return .{ .sessions = total_sessions, .panes = total_panes };
    }

    /// Kill all orphaned and sticky panes (cleanup operation).
    pub fn killAllOrphanedPanes(self: *SesState) usize {
        var uuids_to_kill: std.ArrayList([32]u8) = .empty;
        defer uuids_to_kill.deinit(self.allocator);

        // Collect all orphaned/sticky pane UUIDs first to avoid iterator invalidation.
        var iter = self.panes.iterator();
        while (iter.next()) |entry| {
            const pane = entry.value_ptr;
            if (pane.state == .orphaned or pane.state == .sticky) {
                uuids_to_kill.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        var killed: usize = 0;
        for (uuids_to_kill.items) |uuid| {
            self.killPane(uuid) catch continue;
            killed += 1;
        }

        if (killed > 0) {
            self.dirty = true;
        }

        return killed;
    }

    /// Find a detached session by name or UUID prefix.
    /// Returns the 16-byte session_id if found.
    pub fn findDetachedSessionByNameOrPrefix(self: *SesState, id: []const u8) ?[16]u8 {
        var iter = self.detached_sessions.iterator();
        while (iter.next()) |entry| {
            const session = entry.value_ptr;
            // Check name match (exact).
            if (std.mem.eql(u8, session.session_snapshot.session_name, id)) {
                return entry.key_ptr.*;
            }
            // Check UUID prefix match.
            const hex_id = std.fmt.bytesToHex(entry.key_ptr.*, .lower);
            if (id.len <= hex_id.len and std.mem.startsWith(u8, &hex_id, id)) {
                return entry.key_ptr.*;
            }
        }
        return null;
    }
};
