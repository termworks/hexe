const std = @import("std");
const posix = std.posix;

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("sys/socket.h");
});

const linux = std.os.linux;

const core = @import("core");

/// Verify connecting peer has same UID as current process (security check).
/// Thin wrapper around `core.ipc.verifyPeerUid` that preserves the debug log.
fn verifyPeerCredentials(fd: posix.fd_t) bool {
    if (core.ipc.verifyPeerUid(fd)) return true;
    debugLog("peer uid mismatch on fd={d}, rejecting", .{fd});
    return false;
}
const pod_protocol = core.pod_protocol;
const pod_meta = core.pod_meta;
const wire = core.wire;
const input_dedup_mod = @import("input_dedup.zig");
const xev = @import("xev").Dynamic;
const PodUplink = @import("uplink.zig").PodUplink;
const buffering = @import("buffering.zig");
const RingBuffer = buffering.RingBuffer;
const Osc7Scanner = buffering.Osc7Scanner;
const containsClearSeq = buffering.containsClearSeq;

const POD_CTL_IO_TIMEOUT_MS: i32 = 2000;

var pod_debug: bool = false;

inline fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (!pod_debug) return;
    core.logging.debugWithSource("pod", fmt, args, @src());
}

/// Stall budget for writes to the SES VT uplink. The uplink fd is
/// non-blocking: a SES that stops draining (stopped, swapping, wedged) makes
/// a blocking write freeze this pod's event loop — and the user's shell —
/// forever. Output is appended to the backlog ring BEFORE the uplink write,
/// so on timeout the connection is dropped and SES heals via backlog replay.
const CLIENT_WRITE_TIMEOUT_MS: i32 = 2_000;

/// mux→pod INPUT frames from the SES main client carry a 16-byte
/// `[epoch:u64][seq:u64]` (little-endian) prefix for exactly-once dedup across a
/// frontend VT reconnect. Must match vt_write_queue.INPUT_SEQ_PREFIX_LEN.
const INPUT_SEQ_PREFIX_LEN: usize = 16;

fn setNonBlocking(fd: posix.fd_t) void {
    const flags = posix.fcntl(fd, posix.F.GETFL, 0) catch |err| {
        debugLog("setNonBlocking: fcntl GETFL failed for fd={d}: {s}", .{ fd, @errorName(err) });
        return;
    };
    _ = posix.fcntl(fd, posix.F.SETFL, flags | @as(usize, @intCast(c.O_NONBLOCK))) catch |err| {
        debugLog("setNonBlocking: fcntl SETFL failed for fd={d}: {s}", .{ fd, @errorName(err) });
    };
}

pub const PodArgs = struct {
    daemon: bool = true,
    uuid: []const u8,
    name: ?[]const u8 = null,
    socket_path: []const u8,
    shell: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    labels: ?[]const u8 = null,
    write_meta: bool = true,
    write_alias: bool = false,
    log_level: ?core.logging.Level = null,
    log_file: ?[]const u8 = null,
    /// When true, print a single JSON line on stdout once ready.
    emit_ready: bool = false,
};

/// Run a per-pane pod process.
///
/// In normal operation pods are launched by `hexe-ses`.
pub fn run(args: PodArgs) !void {
    // Ignore SIGPIPE so writes to disconnected mux sockets return EPIPE
    // instead of killing the pod process. This is critical for surviving
    // mux detach (terminal close) while the shell is producing output.
    const sigpipe_action = std.os.linux.Sigaction{
        .handler = .{ .handler = std.os.linux.SIG.IGN },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    _ = std.os.linux.sigaction(posix.SIG.PIPE, &sigpipe_action, null);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    if (args.uuid.len != 32) return error.InvalidUuid;

    const sh = args.shell orelse (posix.getenv("SHELL") orelse "/bin/sh");
    // Use page_allocator for log path since it must survive daemonization
    const log_path: ?[]const u8 = if (args.log_file) |path|
        (if (path.len > 0) path else null)
    else if (args.log_level != null)
        (core.ipc.getLogPath(std.heap.page_allocator) catch |err| blk: {
            core.logging.logError("pod", "failed to resolve default log path", err);
            break :blk null;
        })
    else
        null;

    if (args.daemon) {
        try daemonize(log_path);
    } else if (log_path) |path| {
        redirectStderrToLog(path);
    }

    core.logging.setLogLevel(args.log_level);

    // Best-effort: name this process for `ps` discovery.
    setProcessName(args.name);

    var pod = try Pod.init(allocator, args.uuid, args.socket_path, sh, args.cwd, args.name);
    defer pod.deinit();

    // Best-effort: write grep-friendly .meta sidecar for discovery.
    const created_at: i64 = std.time.timestamp();
    if (args.write_meta) {
        writePodMetaSidecar(allocator, args.uuid, args.name, args.cwd, args.labels, @intCast(c.getpid()), pod.pty.child_pid, created_at) catch |e| {
            core.logging.logError("pod", "writePodMetaSidecar failed", e);
        };
    }

    var created_alias_path: ?[]const u8 = null;
    defer if (created_alias_path) |p| allocator.free(p);

    // Optional: create alias symlink pod@<name>.sock -> pod-<uuid>.sock
    if (args.write_alias and args.name != null and args.name.?.len > 0) {
        created_alias_path = createAliasSymlink(allocator, args.name.?, args.socket_path) catch |err| blk: {
            core.logging.logError("pod", "failed to create pod alias symlink", err);
            break :blk null;
        };
    }

    pod_debug = core.logging.levelEnablesDebug(args.log_level);
    debugLog("started uuid={s} socket={s} name={s}", .{ args.uuid[0..@min(args.uuid.len, 8)], args.socket_path, args.name orelse "(none)" });
    debugLog("daemon={} level={s} logfile={s}", .{
        args.daemon,
        if (args.log_level) |level| @tagName(level) else "off",
        log_path orelse "(none)",
    });

    if (args.emit_ready) {
        // IMPORTANT: write handshake to stdout (ses reads stdout).
        const stdout = std.fs.File.stdout();
        var msg_buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "{{\"type\":\"pod_ready\",\"uuid\":\"{s}\",\"pid\":{d}}}\n", .{ args.uuid, pod.pty.child_pid });
        try stdout.writeAll(msg);
    }

    try pod.run(.{ .write_meta = args.write_meta, .created_at = created_at, .name = args.name, .labels = args.labels });

    // Best-effort cleanup on exit.
    if (args.write_meta) {
        deletePodMetaSidecar(allocator, args.uuid) catch |e| {
            core.logging.logError("pod", "deletePodMetaSidecar failed", e);
        };
    }
    if (created_alias_path) |p| {
        std.fs.cwd().deleteFile(p) catch |err| {
            if (err != error.FileNotFound) debugLog("cleanupMetaForUuid: delete alias failed for '{s}': {s}", .{ p, @errorName(err) });
        };
    }
}

fn setProcessName(name: ?[]const u8) void {
    if (name == null or name.?.len == 0) return;

    // Linux prctl(PR_SET_NAME) sets the comm field, max 15 bytes + NUL.
    // Best-effort: ignore errors / non-linux.
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux) return;

    const pc = @cImport({
        @cInclude("sys/prctl.h");
    });

    var buf: [16]u8 = .{0} ** 16;
    // Prefix helps scanning; keep ASCII and short.
    const prefix = "hexe-pod:";
    var i: usize = 0;
    while (i < prefix.len and i < buf.len - 1) : (i += 1) {
        buf[i] = prefix[i];
    }
    const raw = name.?;
    for (raw) |ch| {
        if (i >= buf.len - 1) break;
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_' or ch == '-' or ch == '.';
        buf[i] = if (ok) ch else '_';
        i += 1;
    }
    buf[i] = 0;
    _ = pc.prctl(pc.PR_SET_NAME, @as(*const anyopaque, @ptrCast(&buf)), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
}

fn writePodMetaSidecar(
    allocator: std.mem.Allocator,
    uuid: []const u8,
    name: ?[]const u8,
    cwd: ?[]const u8,
    labels: ?[]const u8,
    pod_pid: std.posix.pid_t,
    child_pid: std.posix.pid_t,
    created_at: i64,
) !void {
    // Detect shell type from /proc/<child_pid>/comm
    const shell = detectShell(child_pid);

    var meta = try pod_meta.PodMeta.init(
        allocator,
        uuid,
        name,
        pod_pid,
        child_pid,
        cwd,
        shell,
        false,
        labels,
        created_at,
    );
    defer meta.deinit();

    const path = try meta.metaPath(allocator);
    defer allocator.free(path);

    const dir = std.fs.path.dirname(path) orelse return;
    std.fs.cwd().makePath(dir) catch |err| {
        debugLog("writePodMetaSidecar: makePath failed for '{s}': {s}", .{ dir, @errorName(err) });
        return;
    };

    const line = try meta.formatMetaLine(allocator);
    defer allocator.free(line);

    // Write to a temp file then atomically rename into place. Truncating the
    // real path in place let a discovery scan (`hexe pod ls`) read an empty or
    // half-written file and drop this pane from listings; rename is atomic on
    // the same filesystem, so readers only ever see the old or the new file.
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    {
        var f = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true, .mode = 0o600 });
        errdefer std.fs.cwd().deleteFile(tmp_path) catch {};
        defer f.close();
        try f.writeAll(line);
        try f.writeAll("\n");
    }
    errdefer std.fs.cwd().deleteFile(tmp_path) catch {};
    try std.fs.cwd().rename(tmp_path, path);
}

fn detectShell(child_pid: posix.pid_t) ?[]const u8 {
    if (child_pid <= 0) return null;

    var comm_path_buf: [64]u8 = undefined;
    const comm_path = std.fmt.bufPrint(&comm_path_buf, "/proc/{d}/comm", .{child_pid}) catch |err| {
        debugLog("detectShell: failed to format comm path for pid={d}: {s}", .{ child_pid, @errorName(err) });
        return null;
    };
    const comm_file = std.fs.openFileAbsolute(comm_path, .{}) catch |err| {
        debugLog("detectShell: failed to open {s}: {s}", .{ comm_path, @errorName(err) });
        return null;
    };
    defer comm_file.close();

    var comm_buf: [64]u8 = undefined;
    const comm_len = comm_file.read(&comm_buf) catch |err| {
        debugLog("detectShell: failed to read {s}: {s}", .{ comm_path, @errorName(err) });
        return null;
    };
    if (comm_len == 0) return null;

    const comm = std.mem.trim(u8, comm_buf[0..comm_len], " \t\n\r");
    if (comm.len == 0) return null;

    // Return known shell types
    if (std.mem.eql(u8, comm, "bash")) return "bash";
    if (std.mem.eql(u8, comm, "zsh")) return "zsh";
    if (std.mem.eql(u8, comm, "fish")) return "fish";
    if (std.mem.eql(u8, comm, "sh")) return "sh";
    if (std.mem.eql(u8, comm, "dash")) return "dash";
    if (std.mem.eql(u8, comm, "ksh")) return "ksh";
    if (std.mem.eql(u8, comm, "tcsh")) return "tcsh";
    if (std.mem.eql(u8, comm, "csh")) return "csh";
    if (std.mem.eql(u8, comm, "nu")) return "nushell";
    if (std.mem.eql(u8, comm, "pwsh")) return "powershell";
    if (std.mem.eql(u8, comm, "elvish")) return "elvish";
    if (std.mem.eql(u8, comm, "xonsh")) return "xonsh";
    if (std.mem.eql(u8, comm, "oil")) return "oil";

    return null;
}

fn createAliasSymlink(allocator: std.mem.Allocator, raw_name: []const u8, target_socket_path: []const u8) ![]const u8 {
    // Create pod@<name>.sock -> pod-<uuid>.sock in the socket dir.
    const base_alias = try pod_meta.PodMeta.aliasSocketPath(allocator, raw_name);
    defer allocator.free(base_alias);

    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const alias_path = if (attempt == 0) blk: {
            break :blk try allocator.dupe(u8, base_alias);
        } else blk: {
            // Insert suffix before ".sock".
            const dot = std.mem.lastIndexOfScalar(u8, base_alias, '.') orelse base_alias.len;
            break :blk try std.fmt.allocPrint(allocator, "{s}-{d}{s}", .{ base_alias[0..dot], attempt + 1, base_alias[dot..] });
        };
        // Do not defer free on success; return it.

        // Remove existing alias if it points to us; otherwise keep trying.
        std.fs.cwd().deleteFile(alias_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {},
        };

        // Try create. If collision races, just try next.
        std.fs.cwd().symLink(target_socket_path, alias_path, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(alias_path);
                continue;
            },
            else => {
                allocator.free(alias_path);
                return err;
            },
        };

        return alias_path;
    }

    return error.AliasFailed;
}

fn deletePodMetaSidecar(allocator: std.mem.Allocator, uuid: []const u8) !void {
    if (uuid.len != 32) return;
    var tmp = try pod_meta.PodMeta.init(allocator, uuid, null, 0, 0, null, null, false, null, 0);
    defer tmp.deinit();
    const path = try tmp.metaPath(allocator);
    defer allocator.free(path);
    std.fs.cwd().deleteFile(path) catch |err| {
        if (err != error.FileNotFound) debugLog("deletePodMetaSidecar: delete failed for '{s}': {s}", .{ path, @errorName(err) });
    };
}

fn daemonize(log_file: ?[]const u8) !void {
    // First fork
    const pid1 = try posix.fork();
    if (pid1 != 0) posix.exit(0);

    _ = try posix.setsid();

    // Second fork
    const pid2 = try posix.fork();
    if (pid2 != 0) posix.exit(0);

    // Redirect stdin/stdout/stderr to /dev/null
    const devnull = try posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
    try posix.dup2(devnull, posix.STDIN_FILENO);
    try posix.dup2(devnull, posix.STDOUT_FILENO);
    if (log_file) |path| {
        const logfd = try posix.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
        try posix.dup2(logfd, posix.STDERR_FILENO);
        if (logfd > 2) posix.close(logfd);
    } else {
        try posix.dup2(devnull, posix.STDERR_FILENO);
    }
    if (devnull > 2) posix.close(devnull);

    try std.posix.chdir("/");
}

fn redirectStderrToLog(log_path: []const u8) void {
    const logfd = posix.open(log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644) catch |err| {
        debugLog("redirectStderrToLog: open {s} failed: {s}", .{ log_path, @errorName(err) });
        return;
    };
    posix.dup2(logfd, posix.STDERR_FILENO) catch |err| {
        debugLog("redirectStderrToLog: dup2 failed: {s}", .{@errorName(err)});
    };
    if (logfd > 2) posix.close(logfd);
}

/// Write buffer capacity for non-blocking PTY writes.
/// Large enough to absorb typical clipboard pastes without dropping data.
const PTY_WRITE_BUF_CAP: usize = 256 * 1024;
/// Reattach replay window: enough for the visible screen plus generous recent
/// scrollback, small enough that a reattach never feels stuck. A torn head is
/// the same status quo as a wrapped ring.
const REPLAY_TAIL_CAP: usize = 1024 * 1024;
/// Hard ceiling for the PTY input buffer. Dropping input bytes is NEVER okay
/// short of this: a torn bracketed paste (lost ESC[201~) leaves the shell or
/// app in paste mode swallowing every later keystroke — the pane looks
/// permanently frozen. Grow instead; real pastes are a few MB at most.
const PTY_WRITE_BUF_MAX: usize = 16 * 1024 * 1024;
const POD_EXIT_ATTACH_GRACE_MS: i64 = 300;

fn applyPasswordMode(backlog: *RingBuffer, password_mode: *bool, enabled: bool) void {
    if (password_mode.* == enabled) return;
    password_mode.* = enabled;
    if (enabled) backlog.clear();
}

const Pod = struct {
    allocator: std.mem.Allocator,
    uuid: [32]u8,
    pty: core.Pty,
    server: core.IpcServer,
    client: ?core.IpcConnection = null,
    /// Bumped every time `client` is replaced. The read watcher is keyed on
    /// this, NOT on the fd number: closing a client frees its fd, and the
    /// kernel hands the SAME number back to the next accept. A number-only
    /// check then reads "already watched" for a brand-new connection whose
    /// poll registration died with the old file description — the pod goes
    /// permanently deaf to input while its output keeps flowing.
    client_gen: u64 = 0,
    observers: std.array_list.Managed(core.IpcConnection),
    backlog: RingBuffer,
    /// Absolute offset of the byte AFTER the last one appended to `backlog`
    /// (ring start offset = backlog_abs - backlog.len).
    backlog_abs: u64 = 0,
    alt_tracker: buffering.AltScreenTracker = .{},
    reader: pod_protocol.Reader,
    pty_paused: bool = false,
    password_mode: bool = false,

    // Exactly-once input dedup across a frontend VT reconnect. See applyInputFrame.
    input_dedup: input_dedup_mod.InputDedup = .{},

    uplink: PodUplink,

    // Non-blocking PTY write buffer: absorbs data when master_fd would block.
    pty_wbuf: []u8,
    pty_wbuf_len: usize = 0,
    pty_drain_ctx: ?*PtyDrainContext = null,

    // OSC 7 CWD tracking
    osc7_scanner: Osc7Scanner = .{},
    osc7_cwd: ?[]u8 = null,
    vt_client_ever_attached: bool = false,

    const RunOptions = struct {
        write_meta: bool,
        created_at: i64,
        name: ?[]const u8,
        labels: ?[]const u8,
    };

    pub fn init(allocator: std.mem.Allocator, uuid_str: []const u8, socket_path: []const u8, shell: []const u8, cwd: ?[]const u8, pod_name: ?[]const u8) !Pod {
        var uuid: [32]u8 = undefined;
        @memcpy(&uuid, uuid_str[0..32]);

        const extra_env = [_][2][]const u8{
            .{ "HEXE_PANE_UUID", uuid_str },
            .{ "HEXE_POD_NAME", pod_name orelse "" },
            .{ "HEXE_POD_SOCKET", socket_path },
        };
        var pty = try core.Pty.spawnWithEnv(shell, cwd, &extra_env);
        errdefer pty.close();

        var server = try core.ipc.Server.init(allocator, socket_path);
        errdefer server.deinit();

        var backlog = try RingBuffer.init(allocator, core.wire.MAX_PAYLOAD_LEN);
        errdefer backlog.deinit(allocator);

        var reader = try pod_protocol.Reader.init(allocator, pod_protocol.MAX_FRAME_LEN);
        errdefer reader.deinit(allocator);

        const pty_wbuf = try allocator.alloc(u8, PTY_WRITE_BUF_CAP);
        errdefer allocator.free(pty_wbuf);

        // Make PTY master non-blocking so writes never stall the event loop
        // (e.g. during large clipboard pastes when the shell is slow to consume).
        setNonBlocking(pty.master_fd);

        return .{
            .allocator = allocator,
            .uuid = uuid,
            .pty = pty,
            .server = server,
            .observers = std.array_list.Managed(core.IpcConnection).init(allocator),
            .backlog = backlog,
            .reader = reader,
            .pty_wbuf = pty_wbuf,
            .uplink = PodUplink.init(allocator, uuid),
        };
    }

    pub fn deinit(self: *Pod) void {
        if (self.client) |*client| {
            client.close();
        }
        for (self.observers.items) |*obs| obs.close();
        self.observers.deinit();
        self.server.deinit();
        self.pty.close();
        self.backlog.deinit(self.allocator);
        self.reader.deinit(self.allocator);
        self.allocator.free(self.pty_wbuf);
        self.uplink.deinit();
        if (self.osc7_cwd) |cwd| self.allocator.free(cwd);
    }

    fn setPasswordMode(self: *Pod, enabled: bool) void {
        const old = self.password_mode;
        applyPasswordMode(&self.backlog, &self.password_mode, enabled);
        if (old == self.password_mode) return;
        debugLog("password_mode: {}", .{enabled});
    }

    pub fn run(self: *Pod, opts: RunOptions) !void {
        try xev.detect();
        var loop = try xev.Loop.init(.{});
        defer loop.deinit();

        const server_watcher = xev.File.initFd(self.server.getFd());
        const pty_watcher = xev.File.initFd(self.pty.master_fd);
        var server_completion: xev.Completion = .{};
        var pty_completion: xev.Completion = .{};
        var pty_drain_completion: xev.Completion = .{};
        var timer_completion: xev.Completion = .{};
        var ticker = try xev.Timer.init();
        defer ticker.deinit();
        var drain_ticker = try xev.Timer.init();
        defer drain_ticker.deinit();

        const buf = try self.allocator.alloc(u8, pod_protocol.MAX_FRAME_LEN);
        defer self.allocator.free(buf);
        const backlog_tmp = try self.allocator.alloc(u8, pod_protocol.MAX_FRAME_LEN);
        defer self.allocator.free(backlog_tmp);

        var should_stop = false;
        var callback_error: ?anyerror = null;
        var exit_grace_deadline_ms: ?i64 = null;
        var pty_armed = false;
        var client_completion_0: xev.Completion = .{};
        var client_completion_1: xev.Completion = .{};
        var client_slot_0: ClientSlot = .{ .parent = undefined, .fd = -1 };
        var client_slot_1: ClientSlot = .{ .parent = undefined, .fd = -1 };
        var client_gen: u1 = 0;

        var pty_ctx = PtyContext{
            .pod = self,
            .io_buf = buf,
            .loop = &loop,
            .watcher = pty_watcher,
            .completion = &pty_completion,
            .should_stop = &should_stop,
            .callback_error = &callback_error,
            .armed = &pty_armed,
        };

        var pty_drain_ctx = PtyDrainContext{
            .pod = self,
            .loop = &loop,
            .timer = drain_ticker,
            .completion = &pty_drain_completion,
        };
        self.pty_drain_ctx = &pty_drain_ctx;
        defer self.pty_drain_ctx = null;

        var client_ctx = ClientContext{
            .pod = self,
            .io_buf = buf,
            .loop = &loop,
            .callback_error = &callback_error,
            .completions = .{ &client_completion_0, &client_completion_1 },
            .slots = .{ &client_slot_0, &client_slot_1 },
            .gen = &client_gen,
        };

        var accept_ctx = AcceptContext{
            .pod = self,
            .backlog_tmp = backlog_tmp,
            .pty_ctx = &pty_ctx,
            .client_ctx = &client_ctx,
        };
        server_watcher.poll(&loop, &server_completion, .read, AcceptContext, &accept_ctx, acceptCallback);
        armPtyWatcher(&pty_ctx);

        var timer_ctx = TimerContext{
            .pod = self,
            .opts = opts,
            .ticker = ticker,
        };
        ticker.run(&loop, &timer_completion, 100, TimerContext, &timer_ctx, timerCallback);

        var loop_err_burst: usize = 0;
        while (true) {
            var waiting_for_initial_vt_attach = false;
            if (self.pty.pollStatus() != null) {
                self.flushRemainingPtyOutput(buf);
                if (self.client != null or self.vt_client_ever_attached) {
                    break;
                }
                if (exit_grace_deadline_ms == null) {
                    exit_grace_deadline_ms = std.time.milliTimestamp() + POD_EXIT_ATTACH_GRACE_MS;
                }
                if (std.time.milliTimestamp() >= exit_grace_deadline_ms.?) {
                    break;
                }
                waiting_for_initial_vt_attach = true;
            }

            if (should_stop and !waiting_for_initial_vt_attach) break;
            if (callback_error) |err| return err;

            // A loop error must NEVER kill the pod — that kills the user's
            // shell. Log, back off (a persistently rejected completion would
            // otherwise pin a core), and keep serving the PTY.
            var loop_ok = true;
            loop.run(.once) catch |err| {
                loop_ok = false;
                loop_err_burst +|= 1;
                debugLog("pod event loop error (continuing): {s}", .{@errorName(err)});
            };
            if (loop_ok) {
                loop_err_burst = 0;
            } else if (loop_err_burst > 8) {
                std.Thread.sleep(20 * std.time.ns_per_ms);
            }

            if (should_stop and !waiting_for_initial_vt_attach) break;
            if (callback_error) |err| return err;
        }
    }

    const AcceptContext = struct {
        pod: *Pod,
        backlog_tmp: []u8,
        pty_ctx: *PtyContext,
        client_ctx: *ClientContext,
    };

    const PtyContext = struct {
        pod: *Pod,
        io_buf: []u8,
        loop: *xev.Loop,
        watcher: xev.File,
        completion: *xev.Completion,
        should_stop: *bool,
        callback_error: *?anyerror,
        armed: *bool,
    };

    const PtyDrainContext = struct {
        pod: *Pod,
        loop: *xev.Loop,
        timer: xev.Timer,
        completion: *xev.Completion,
        armed: bool = false,
    };

    const ClientSlot = struct {
        parent: *ClientContext,
        fd: posix.fd_t,
    };

    const ClientContext = struct {
        pod: *Pod,
        io_buf: []u8,
        loop: *xev.Loop,
        callback_error: *?anyerror,
        /// Two completion/slot pairs to alternate between during VT client
        /// replacement. When a new client replaces an old one, the old
        /// io_uring POLL_ADD CQE may still reference the previous completion.
        /// Switching to the alternate pair avoids overwriting a live entry.
        completions: [2]*xev.Completion,
        slots: [2]*ClientSlot,
        gen: *u1,
        watched_fd: ?posix.fd_t = null,
        watched_gen: u64 = 0,
    };

    const TimerContext = struct {
        pod: *Pod,
        opts: RunOptions,
        ticker: xev.Timer,
        last_meta_ms: i64 = 0,
        last_meta_cwd_hash: ?u64 = null,
        last_meta_write_ms: i64 = 0,
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
            debugLog("acceptCallback: poll error: {s}", .{@errorName(err)});
            return .rearm;
        };

        while (accept_ctx.pod.server.tryAccept() catch |err| blk: {
            debugLog("acceptCallback: tryAccept failed: {s}", .{@errorName(err)});
            break :blk null;
        }) |conn| {
            debugLog("acceptCallback: new conn fd={d}, client_before={?d}, watched_fd={?d}, pty_paused={}, pty_armed={}", .{
                conn.fd,
                if (accept_ctx.pod.client) |cl| cl.fd else null,
                accept_ctx.client_ctx.watched_fd,
                accept_ctx.pod.pty_paused,
                accept_ctx.pty_ctx.armed.*,
            });
            accept_ctx.pod.handleAcceptedConnection(conn, accept_ctx.backlog_tmp);
            debugLog("acceptCallback: after handle, client={?d}, watched_fd={?d}, pty_paused={}, pty_armed={}", .{
                if (accept_ctx.pod.client) |cl| cl.fd else null,
                accept_ctx.client_ctx.watched_fd,
                accept_ctx.pod.pty_paused,
                accept_ctx.pty_ctx.armed.*,
            });
            // If the client fd changed (old was closed+replaced by acceptVtClient),
            // clear the stale watched_fd. The old fd was closed so epoll silently
            // deregistered it — clientCallback will never fire to clear watched_fd.
            if (accept_ctx.client_ctx.watched_fd) |old_watched| {
                const cur_fd = if (accept_ctx.pod.client) |cl| cl.fd else null;
                if (cur_fd == null or cur_fd.? != old_watched) {
                    debugLog("acceptCallback: clearing stale watched_fd={d} (client now={?d})", .{ old_watched, cur_fd });
                    accept_ctx.client_ctx.watched_fd = null;
                }
            }
            if (accept_ctx.pod.client) |client| {
                armClientWatcher(accept_ctx.client_ctx, client.fd);
            }
            debugLog("acceptCallback: after armClient, watched_fd={?d}", .{accept_ctx.client_ctx.watched_fd});
            if (accept_ctx.pod.client != null and accept_ctx.pod.pty_paused) {
                debugLog("acceptCallback: re-arming pty watcher (was paused)", .{});
                accept_ctx.pod.pty_paused = false;
                armPtyWatcher(accept_ctx.pty_ctx);
            }
        }

        return .rearm;
    }

    fn armClientWatcher(ctx: *ClientContext, client_fd: posix.fd_t) void {
        // Only skip when this is genuinely the SAME connection we already
        // watch. Comparing fd numbers alone is not enough — see Pod.client_gen.
        if (ctx.watched_fd != null and
            ctx.watched_fd.? == client_fd and
            ctx.watched_gen == ctx.pod.client_gen)
        {
            debugLog("armClientWatcher: SKIP fd={d} (already watching gen={d})", .{ client_fd, ctx.watched_gen });
            return;
        }
        // Alternate between two completion/slot pairs so we never overwrite
        // a completion that io_uring still references from a previous poll.
        ctx.gen.* ^= 1;
        const completion = ctx.completions[ctx.gen.*];
        const slot = ctx.slots[ctx.gen.*];

        debugLog("armClientWatcher: ARMED fd={d} slot={d} conn_gen={d}", .{ client_fd, ctx.gen.*, ctx.pod.client_gen });
        ctx.watched_fd = client_fd;
        ctx.watched_gen = ctx.pod.client_gen;

        slot.* = .{ .parent = ctx, .fd = client_fd };
        const watcher = xev.File.initFd(client_fd);
        completion.* = .{};
        watcher.poll(ctx.loop, completion, .read, ClientSlot, slot, clientCallback);
    }

    fn clientCallback(
        ctx: ?*ClientSlot,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.File,
        result: xev.PollError!xev.PollEvent,
    ) xev.CallbackAction {
        const slot = ctx orelse return .disarm;
        const client_ctx = slot.parent;
        _ = result catch {
            debugLog("clientCallback: ERROR on slot.fd={d}, watched_fd={?d}, client={?d}", .{
                slot.fd,
                client_ctx.watched_fd,
                if (client_ctx.pod.client) |cl| cl.fd else null,
            });
            // Poll error (fd closed). Clear tracked fd so a replacement
            // client can be armed. If the client was already replaced by
            // acceptVtClient, arm the watcher for the new fd now.
            if (client_ctx.watched_fd) |w| {
                if (w == slot.fd) client_ctx.watched_fd = null;
            }
            if (client_ctx.pod.client) |cur| {
                if (cur.fd != slot.fd) {
                    debugLog("clientCallback: client replaced, re-arming for fd={d}", .{cur.fd});
                    armClientWatcher(client_ctx, cur.fd);
                }
            }
            return .disarm;
        };

        const current = client_ctx.pod.client orelse {
            debugLog("clientCallback: no client, disarming slot.fd={d}", .{slot.fd});
            if (client_ctx.watched_fd == slot.fd) client_ctx.watched_fd = null;
            return .disarm;
        };
        if (current.fd != slot.fd) {
            debugLog("clientCallback: stale fd={d}, current={d}, re-arming", .{ slot.fd, current.fd });
            if (client_ctx.watched_fd == slot.fd) client_ctx.watched_fd = null;
            armClientWatcher(client_ctx, current.fd);
            return .disarm;
        }

        const n = posix.read(slot.fd, client_ctx.io_buf) catch |err| switch (err) {
            // Spurious wakeup with no data — this is not EOF; keep watching.
            error.WouldBlock => return .rearm,
            else => {
                // An abnormal error on the SES link (e.g. ECONNRESET on a
                // crashed daemon) must not take down the pod — that would
                // kill the user's shell and defeat SES-restart survival.
                // Drop the client exactly like EOF and keep buffering into
                // the ring so a restarted SES can reattach.
                debugLog("clientCallback: read error on fd={d}, dropping client: {s}", .{ slot.fd, @errorName(err) });
                if (client_ctx.pod.client) |*conn| conn.close();
                client_ctx.pod.client = null;
                client_ctx.watched_fd = null;
                return .disarm;
            },
        };

        if (n == 0) {
            debugLog("clientCallback: EOF on fd={d}, closing client", .{slot.fd});
            if (client_ctx.pod.client) |*conn| conn.close();
            client_ctx.pod.client = null;
            client_ctx.watched_fd = null;
            return .disarm;
        }

        debugLog("clientCallback: read {d} bytes from fd={d}", .{ n, slot.fd });
        client_ctx.pod.reader.feed(client_ctx.io_buf[0..n], @ptrCast(client_ctx.pod), podFrameCallback);
        return .rearm;
    }

    fn armPtyWatcher(ctx: *PtyContext) void {
        if (ctx.armed.* or ctx.pod.pty_paused) {
            debugLog("armPtyWatcher: SKIP (armed={}, pty_paused={})", .{ ctx.armed.*, ctx.pod.pty_paused });
            return;
        }
        debugLog("armPtyWatcher: ARMED", .{});
        ctx.watcher.poll(ctx.loop, ctx.completion, .read, PtyContext, ctx, ptyCallback);
        ctx.armed.* = true;
    }

    fn ptyCallback(
        ctx: ?*PtyContext,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.File,
        result: xev.PollError!xev.PollEvent,
    ) xev.CallbackAction {
        const pty_ctx = ctx orelse return .disarm;
        _ = result catch {
            debugLog("ptyCallback: ERROR, disarming, stopping", .{});
            pty_ctx.armed.* = false;
            pty_ctx.should_stop.* = true;
            return .disarm;
        };

        if (pty_ctx.pod.client == null and pty_ctx.pod.observers.items.len == 0) {
            const free = pty_ctx.pod.backlog.available();
            if (free == 0) {
                pty_ctx.pod.pty_paused = true;
                pty_ctx.armed.* = false;
                return .disarm;
            }

            const read_buf = pty_ctx.io_buf[0..@min(pty_ctx.io_buf.len, free)];
            const n = pty_ctx.pod.pty.read(read_buf) catch |err| switch (err) {
                // Spurious poll wakeup with nothing to read. This must never
                // be conflated with child exit (n == 0): the PTY master is
                // non-blocking, and treating EAGAIN as EOF kills a live shell.
                error.WouldBlock => return .rearm,
                // PTY masters commonly report EIO once the child side is gone.
                // Treat that as clean end-of-stream so the pod can keep the
                // socket alive briefly and SES can still attach/read backlog.
                error.InputOutput => 0,
                else => {
                    pty_ctx.callback_error.* = err;
                    pty_ctx.armed.* = false;
                    return .disarm;
                },
            };

            if (n == 0) {
                pty_ctx.should_stop.* = true;
                pty_ctx.armed.* = false;
                return .disarm;
            }

            const data = read_buf[0..n];
            pty_ctx.pod.scanOutputMetadata(data);
            pty_ctx.pod.alt_tracker.feed(data, pty_ctx.pod.backlog_abs);
            if (pty_ctx.pod.password_mode) return .rearm;
            const appended = pty_ctx.pod.backlog.appendNoDrop(data);
            // Every ring append MUST bump backlog_abs — the replay window
            // derives the ring's absolute start from it.
            if (appended) pty_ctx.pod.backlog_abs += data.len;
            if (!appended or pty_ctx.pod.backlog.isFull()) {
                pty_ctx.pod.pty_paused = true;
                pty_ctx.armed.* = false;
                return .disarm;
            }

            return .rearm;
        }

        const n = pty_ctx.pod.pty.read(pty_ctx.io_buf) catch |err| switch (err) {
            // See above: EAGAIN is a spurious wakeup, never child exit.
            error.WouldBlock => return .rearm,
            error.InputOutput => 0,
            else => {
                pty_ctx.callback_error.* = err;
                pty_ctx.armed.* = false;
                return .disarm;
            },
        };
        if (n == 0) {
            pty_ctx.should_stop.* = true;
            pty_ctx.armed.* = false;
            return .disarm;
        }

        pty_ctx.pod.processPtyOutput(pty_ctx.io_buf[0..n]);

        return .rearm;
    }

    /// Queue data for non-blocking write to the PTY master fd.
    /// Tries to write directly first; any remainder is buffered and
    /// an xev write-readiness watcher drains it asynchronously.
    fn queuePtyWrite(self: *Pod, data: []const u8) void {
        // Try to drain any previously buffered data first.
        self.drainPtyWriteBuf();

        var remaining = data;

        // If the buffer is empty, attempt a direct write.
        if (self.pty_wbuf_len == 0 and remaining.len > 0) {
            const n = self.pty.write(remaining) catch |err| switch (err) {
                error.WouldBlock => 0,
                else => {
                    debugLog("queuePtyWrite: pty write error: {s}", .{@errorName(err)});
                    return;
                },
            };
            remaining = remaining[n..];
        }

        // Buffer whatever could not be written, growing as needed: a large
        // paste into a slow reader (vim reads pastes in tiny chunks) easily
        // exceeds the initial capacity, and dropping the tail used to tear
        // the bracketed-paste framing and freeze the pane.
        if (remaining.len > 0) {
            const needed = self.pty_wbuf_len + remaining.len;
            if (needed > self.pty_wbuf.len and needed <= PTY_WRITE_BUF_MAX) {
                const new_cap = @min(PTY_WRITE_BUF_MAX, @max(needed, self.pty_wbuf.len * 2));
                if (self.allocator.realloc(self.pty_wbuf, new_cap)) |grown| {
                    self.pty_wbuf = grown;
                } else |err| {
                    core.logging.logError("pod", "failed to grow pty write buffer", err);
                }
            }
            const space = self.pty_wbuf.len - self.pty_wbuf_len;
            const to_copy = @min(remaining.len, space);
            if (to_copy > 0) {
                @memcpy(self.pty_wbuf[self.pty_wbuf_len..][0..to_copy], remaining[0..to_copy]);
                self.pty_wbuf_len += to_copy;
            }
            if (to_copy < remaining.len) {
                core.logging.warn("pod", "pty input buffer overflow: dropped {d} bytes — input framing may be torn", .{remaining.len - to_copy});
            }
            self.armPtyDrainTimer();
        }
    }

    /// Try to write as much of the PTY write buffer as possible.
    fn drainPtyWriteBuf(self: *Pod) void {
        while (self.pty_wbuf_len > 0) {
            const n = self.pty.write(self.pty_wbuf[0..self.pty_wbuf_len]) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    debugLog("drainPtyWriteBuf: pty write error: {s}, discarding {d} bytes", .{ @errorName(err), self.pty_wbuf_len });
                    self.pty_wbuf_len = 0;
                    return;
                },
            };
            if (n == 0) return;
            const leftover = self.pty_wbuf_len - n;
            if (leftover > 0) {
                std.mem.copyForwards(u8, self.pty_wbuf[0..leftover], self.pty_wbuf[n..self.pty_wbuf_len]);
            }
            self.pty_wbuf_len = leftover;
        }
    }

    fn armPtyDrainTimer(self: *Pod) void {
        const ctx = self.pty_drain_ctx orelse return;
        if (ctx.armed) return;
        debugLog("armPtyDrainTimer: ARMED (buffered={d})", .{self.pty_wbuf_len});
        ctx.armed = true;
        // Use fresh timer.run() to avoid xev io_uring absolute-timestamp re-arm bug.
        ctx.timer.run(ctx.loop, ctx.completion, 1, PtyDrainContext, ctx, ptyDrainCallback);
    }

    fn ptyDrainCallback(
        ctx: ?*PtyDrainContext,
        _: *xev.Loop,
        _: *xev.Completion,
        result: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        const drain_ctx = ctx orelse return .disarm;
        drain_ctx.armed = false;

        _ = result catch {
            // Timer error; re-arm if there's still data.
            if (drain_ctx.pod.pty_wbuf_len > 0) {
                drain_ctx.pod.armPtyDrainTimer();
            }
            return .disarm;
        };

        drain_ctx.pod.drainPtyWriteBuf();

        if (drain_ctx.pod.pty_wbuf_len > 0) {
            // Still have data — re-arm with a fresh absolute timestamp.
            drain_ctx.pod.armPtyDrainTimer();
        }
        return .disarm;
    }

    fn timerCallback(
        ctx: ?*TimerContext,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        const timer_ctx = ctx orelse return .disarm;
        _ = result catch {
            // Re-arm with fresh absolute timestamp (workaround for xev io_uring timer re-arm bug)
            timer_ctx.ticker.run(loop, completion, 100, TimerContext, timer_ctx, timerCallback);
            return .disarm;
        };

        const uplink_attached = timer_ctx.pod.client != null or timer_ctx.pod.observers.items.len > 0;
        timer_ctx.pod.uplink.tick(timer_ctx.pod.pty.child_pid, uplink_attached);

        if (timer_ctx.opts.write_meta) {
            const now_ms: i64 = std.time.milliTimestamp();
            if (now_ms - timer_ctx.last_meta_ms >= 1000) {
                timer_ctx.last_meta_ms = now_ms;
                const live_cwd = timer_ctx.pod.lastOsc7Cwd();
                // Only the cwd is live in the sidecar; skip the disk write
                // when it hasn't changed since the last successful write.
                // Still rewrite every 5 minutes regardless: sidecars can live
                // in /tmp where tmpfiles cleaners reap by mtime, and a forced
                // rewrite also recreates an externally deleted file.
                const cwd_hash = std.hash.Wyhash.hash(0, live_cwd orelse "");
                const keepalive_due = now_ms - timer_ctx.last_meta_write_ms >= 5 * std.time.ms_per_min;
                if (timer_ctx.last_meta_cwd_hash == null or timer_ctx.last_meta_cwd_hash.? != cwd_hash or keepalive_due) {
                    if (writePodMetaSidecar(
                        timer_ctx.pod.allocator,
                        timer_ctx.pod.uuid[0..],
                        timer_ctx.opts.name,
                        live_cwd,
                        timer_ctx.opts.labels,
                        @intCast(c.getpid()),
                        timer_ctx.pod.pty.child_pid,
                        timer_ctx.opts.created_at,
                    )) |_| {
                        timer_ctx.last_meta_cwd_hash = cwd_hash;
                        timer_ctx.last_meta_write_ms = now_ms;
                    } else |err| {
                        debugLog("timerCallback: writePodMetaSidecar failed: {s}", .{@errorName(err)});
                    }
                }
            }
        }

        // Re-arm with fresh absolute timestamp (workaround for xev io_uring timer re-arm bug)
        timer_ctx.ticker.run(loop, completion, 100, TimerContext, timer_ctx, timerCallback);
        return .disarm;
    }

    fn handleAcceptedConnection(self: *Pod, conn: core.IpcConnection, backlog_tmp: []u8) void {
        if (!verifyPeerCredentials(conn.fd)) {
            var tmp = conn;
            tmp.close();
            return;
        }
        setNonBlocking(conn.fd);

        var handshake: [2]u8 = undefined;
        wire.readExactTimeout(conn.fd, &handshake, POD_CTL_IO_TIMEOUT_MS) catch |err| {
            debugLog("reject: handshake read failed fd={d}: {s}", .{ conn.fd, @errorName(err) });
            var tmp_conn = conn;
            tmp_conn.close();
            return;
        };

        if (!wire.isProtocolVersionSupported(handshake[1])) {
            debugLog("reject: unsupported protocol version {d} fd={d}", .{ handshake[1], conn.fd });
            var tmp_conn = conn;
            tmp_conn.close();
            return;
        }
        if (wire.isProtocolVersionDeprecated(handshake[1])) {
            debugLog("accept: deprecated protocol version {d} fd={d} (current={d})", .{ handshake[1], conn.fd, wire.PROTOCOL_VERSION });
        }

        if (handshake[0] == wire.POD_HANDSHAKE_SES_VT) {
            debugLog("accept: SES VT client fd={d}", .{conn.fd});
            self.acceptVtClient(conn, backlog_tmp);
        } else if (handshake[0] == wire.POD_HANDSHAKE_SHP_CTL) {
            debugLog("accept: SHP ctl fd={d}", .{conn.fd});
            self.handleBinaryShpConnection(conn);
        } else if (handshake[0] == wire.POD_HANDSHAKE_AUX_INPUT) {
            debugLog("accept: aux input fd={d}", .{conn.fd});
            self.handleAuxInput(conn);
        } else if (handshake[0] == wire.POD_HANDSHAKE_AUX_OBSERVER) {
            debugLog("accept: aux observer fd={d}", .{conn.fd});
            self.acceptObserver(conn, backlog_tmp);
        } else {
            debugLog("accept: unknown handshake 0x{x:0>2} fd={d}", .{ handshake[0], conn.fd });
            var tmp_conn = conn;
            tmp_conn.close();
        }
    }

    fn acceptObserver(self: *Pod, conn: core.IpcConnection, backlog_tmp: []u8) void {
        var obs_conn = conn;
        // Observers are secondary/diagnostic clients. Keep their fd
        // non-blocking so a stalled observer that stops draining returns
        // EAGAIN on write instead of blocking the PTY hot path forever; the
        // write-failure paths below (and broadcastToObservers) then drop it.
        // The main VT client fd is ALSO non-blocking now (acceptVtClient) with
        // bounded writeFrameBounded writes; output survives in the backlog
        // ring and replays on reconnect.
        setNonBlocking(conn.fd);

        // Replay current backlog to new observer unless password mode is
        // active; password-mode output is live-only and never recorded.
        const n = if (self.password_mode) 0 else self.backlog.copyOut(backlog_tmp);
        var off: usize = buffering.replaySkipBytes(
            self.alt_tracker.in_alt,
            self.alt_tracker.alt_enter_offset,
            self.backlog_abs -| self.backlog.len,
            n,
            REPLAY_TAIL_CAP,
        );
        while (off < n) {
            const chunk = @min(@as(usize, 16 * 1024), n - off);
            pod_protocol.writeFrame(&obs_conn, .output, backlog_tmp[off .. off + chunk]) catch {
                var tmp = obs_conn;
                tmp.close();
                return;
            };
            off += chunk;
        }
        pod_protocol.writeFrame(&obs_conn, .backlog_end, &[_]u8{}) catch {
            var tmp = obs_conn;
            tmp.close();
            return;
        };

        self.observers.append(obs_conn) catch {
            var tmp = obs_conn;
            tmp.close();
            return;
        };

        // Refresh cwd/fg info right away — detached polling is slow.
        self.uplink.forceRefresh();
        self.uplink.tick(self.pty.child_pid, true);
    }

    fn broadcastToObservers(self: *Pod, data: []const u8) void {
        if (self.password_mode) return;
        var i: usize = 0;
        while (i < self.observers.items.len) {
            const obs = &self.observers.items[i];
            pod_protocol.writeFrame(obs, .output, data) catch {
                obs.close();
                _ = self.observers.swapRemove(i);
                continue;
            };
            i += 1;
        }
    }

    fn processPtyOutput(self: *Pod, data: []const u8) void {
        self.scanOutputMetadata(data);
        // Track alt-screen enter/leave against ring offsets so reattach
        // replay can start at the fullscreen app's initial paint instead of
        // replaying megabytes of invisible history behind it.
        self.alt_tracker.feed(data, self.backlog_abs);
        if (!self.password_mode) {
            self.backlog.append(data);
            self.backlog_abs += data.len;
        }
        if (self.client) |*client| {
            pod_protocol.writeFrameBounded(client, .output, data, CLIENT_WRITE_TIMEOUT_MS) catch {
                debugLog("processPtyOutput: writeFrame FAILED, closing client fd={d}", .{client.fd});
                client.close();
                self.client = null;
            };
        } else if (self.observers.items.len == 0) {
            debugLog("processPtyOutput: no client, data goes to backlog only ({d} bytes)", .{data.len});
        }
        self.broadcastToObservers(data);
    }

    fn flushRemainingPtyOutput(self: *Pod, io_buf: []u8) void {
        while (true) {
            const n = self.pty.read(io_buf) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    debugLog("flushRemainingPtyOutput: read error: {s}", .{@errorName(err)});
                    return;
                },
            };
            if (n == 0) return;
            self.processPtyOutput(io_buf[0..n]);
        }
    }

    fn handleFrame(self: *Pod, frame: pod_protocol.Frame) void {
        switch (frame.frame_type) {
            .input => {
                // mux→pod input from the SES main client carries a 16-byte
                // (epoch, seq) prefix for exactly-once dedup across reconnects.
                // applyInputFrame strips it and applies the real bytes. (The aux
                // input path, handleAuxInput, is a separate un-prefixed channel.)
                self.applyInputFrame(frame.payload);
            },
            .resize => {
                if (frame.payload.len >= 4) {
                    const cols = std.mem.readInt(u16, frame.payload[0..2], .big);
                    const rows = std.mem.readInt(u16, frame.payload[2..4], .big);
                    self.pty.setSize(cols, rows) catch |err| {
                        debugLog("handleFrame: resize to {d}x{d} failed: {s}", .{ cols, rows, @errorName(err) });
                    };
                }
            },
            .password_mode => {
                if (frame.payload.len < 1) return;
                self.setPasswordMode(frame.payload[0] != 0);
            },
            else => {},
        }
    }

    /// Apply a mux→pod input frame, deduplicating replays across a VT reconnect.
    ///
    /// The 16-byte prefix is `[epoch:u64][seq:u64]` (little-endian). The pod is
    /// the dedup authority because it is the only process that survives every
    /// reconnect trigger (frontend slow, VT-overflow drop, daemon crash):
    ///   - different epoch → a NEW frontend (reattach): adopt it, apply.
    ///   - seq <= last_seq  → already applied (a replay): DROP.
    ///   - else             → apply, advance last_seq.
    /// This makes input exactly-once: the frontend re-sends its replay ring on
    /// reconnect, and anything already delivered here is dropped.
    fn applyInputFrame(self: *Pod, payload: []const u8) void {
        if (payload.len < INPUT_SEQ_PREFIX_LEN) {
            // Malformed (a v4 frontend always prefixes). Drop rather than write
            // partial/garbage bytes to the shell.
            debugLog("applyInputFrame: input frame too short ({d} bytes), dropping", .{payload.len});
            return;
        }
        const epoch = std.mem.readInt(u64, payload[0..8], .little);
        const seq = std.mem.readInt(u64, payload[8..16], .little);
        const real = payload[INPUT_SEQ_PREFIX_LEN..];

        if (!self.input_dedup.accept(epoch, seq)) return; // replayed duplicate
        if (real.len > 0) self.queuePtyWrite(real);
    }

    /// Accept a VT client — replays backlog, then streams live output.
    fn acceptVtClient(self: *Pod, conn: core.IpcConnection, backlog_tmp: []u8) void {
        debugLog("acceptVtClient: fd={d} replacing={}", .{ conn.fd, self.client != null });
        // Replace existing client if any.
        if (self.client) |*old| old.close();

        // Non-blocking: writes go through writeFrameBounded so a wedged SES
        // costs at most CLIENT_WRITE_TIMEOUT_MS before the drop-and-replay
        // path takes over, instead of freezing the pod (and shell) forever.
        setNonBlocking(conn.fd);
        self.client = conn;
        self.client_gen +%= 1;

        // Send acknowledgment so client knows we're ready. Bounded like every
        // other write to this peer — plain writeControl carries the 10s wire
        // default, which is 10s of frozen shell on the attach path.
        wire.writeControlTimeout(conn.fd, .ok, &.{}, CLIENT_WRITE_TIMEOUT_MS) catch {
            debugLog("acceptVtClient: failed to send ack, closing fd={d}", .{conn.fd});
            var tmp = conn;
            tmp.close();
            self.client = null;
            return;
        };
        self.vt_client_ever_attached = true;
        self.reader.reset();

        // Replay backlog unless password mode is active; while active, screen
        // contents are intentionally not persisted or replayed.
        const n = if (self.password_mode) 0 else self.backlog.copyOut(backlog_tmp);
        // Bounded window: reattaching to tens of thousands of lines used to
        // replay the whole 4MB ring, wedging the frontend. Start at the alt
        // enter for fullscreen apps, else the last REPLAY_TAIL_CAP bytes.
        var off: usize = buffering.replaySkipBytes(
            self.alt_tracker.in_alt,
            self.alt_tracker.alt_enter_offset,
            self.backlog_abs -| self.backlog.len,
            n,
            REPLAY_TAIL_CAP,
        );
        if (off > 0) debugLog("acceptVtClient: replay skipping {d} of {d} backlog bytes (alt={})", .{ off, n, self.alt_tracker.in_alt });
        while (off < n) {
            const chunk = @min(@as(usize, 16 * 1024), n - off);
            pod_protocol.writeFrameBounded(&self.client.?, .output, backlog_tmp[off .. off + chunk], CLIENT_WRITE_TIMEOUT_MS) catch |err| {
                debugLog("acceptVtClient: backlog replay failed at offset={d}: {s}", .{ off, @errorName(err) });
                if (self.client) |*current| current.close();
                self.client = null;
                return;
            };
            off += chunk;
        }
        pod_protocol.writeFrameBounded(&self.client.?, .backlog_end, &[_]u8{}, CLIENT_WRITE_TIMEOUT_MS) catch |err| {
            debugLog("acceptVtClient: backlog_end write failed: {s}", .{@errorName(err)});
            if (self.client) |*current| current.close();
            self.client = null;
            return;
        };

        // Refresh cwd/fg info right away — detached polling is slow, so the
        // session authority may hold values up to one slow tick stale.
        self.uplink.forceRefresh();
        self.uplink.tick(self.pty.child_pid, true);

        // Keep backlog after replay so repeated detach/reattach cycles can
        // still restore scrollback for panes that stayed idle between
        // attaches. Ring capacity naturally bounds history size.
        // Note: do NOT reset pty_paused here. The acceptCallback caller
        // checks pty_paused and calls armPtyWatcher. If we clear the flag
        // here, the caller sees pty_paused=false and skips re-arming,
        // leaving the PTY watcher permanently disarmed after reconnect.
    }

    /// Handle a binary SHP control connection (channel ⑤).
    /// Reads one ShpShellEvent from SHP and forwards as binary shell_event on POD uplink.
    fn handleBinaryShpConnection(self: *Pod, conn: core.IpcConnection) void {
        debugLog("shp connection fd={d}", .{conn.fd});
        // Read the binary control header.
        const hdr = wire.readControlHeaderTimeout(conn.fd, POD_CTL_IO_TIMEOUT_MS) catch {
            var tmp = conn;
            tmp.close();
            return;
        };

        const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (msg_type != .shp_shell_event or hdr.payload_len < @sizeOf(wire.ShpShellEvent)) {
            var tmp = conn;
            tmp.close();
            return;
        }

        // Read the fixed struct.
        const evt = wire.readStructTimeout(wire.ShpShellEvent, conn.fd, POD_CTL_IO_TIMEOUT_MS) catch {
            var tmp = conn;
            tmp.close();
            return;
        };

        // Read trailing variable data (cmd + cwd).
        var trail_buf: [8192]u8 = undefined;
        const trail_len: usize = @as(usize, evt.cmd_len) + @as(usize, evt.cwd_len);
        if (trail_len > trail_buf.len) {
            var tmp = conn;
            tmp.close();
            return;
        }
        if (trail_len > 0) {
            wire.readExactTimeout(conn.fd, trail_buf[0..trail_len], POD_CTL_IO_TIMEOUT_MS) catch {
                var tmp = conn;
                tmp.close();
                return;
            };
        }

        var tmp = conn;
        tmp.close();

        // Forward as binary shell_event on the POD uplink (channel ④).
        if (!self.uplink.ensureConnected()) return;
        const uplink_fd = self.uplink.fd orelse return;
        wire.writeControlWithTrailTimeout(uplink_fd, .shell_event, std.mem.asBytes(&evt), trail_buf[0..trail_len], CLIENT_WRITE_TIMEOUT_MS) catch {
            self.uplink.disconnect();
        };
    }

    /// Handle auxiliary input connection (e.g., `hexe pod send`).
    /// Reads pod_protocol frames and writes input directly to the PTY
    /// without replacing the main VT client.
    fn handleAuxInput(self: *Pod, conn: core.IpcConnection) void {
        var hdr: [5]u8 = undefined;
        wire.readExactTimeout(conn.fd, &hdr, POD_CTL_IO_TIMEOUT_MS) catch |err| {
            debugLog("handleAuxInput: frame header read failed fd={d}: {s}", .{ conn.fd, @errorName(err) });
            var tmp = conn;
            tmp.close();
            return;
        };

        const frame_type_byte = hdr[0];
        const payload_len = std.mem.readInt(u32, hdr[1..5], .big);
        var buf: [4096]u8 = undefined;
        if (payload_len > buf.len) {
            debugLog("handleAuxInput: frame too large len={d}", .{payload_len});
            var tmp = conn;
            tmp.close();
            return;
        }
        wire.readExactTimeout(conn.fd, buf[0..payload_len], POD_CTL_IO_TIMEOUT_MS) catch |err| {
            debugLog("handleAuxInput: frame payload read failed fd={d}: {s}", .{ conn.fd, @errorName(err) });
            var tmp = conn;
            tmp.close();
            return;
        };

        if (frame_type_byte == @intFromEnum(pod_protocol.FrameType.input)) {
            self.queuePtyWrite(buf[0..payload_len]);
        } else if (frame_type_byte == @intFromEnum(pod_protocol.FrameType.resize) and payload_len >= 4) {
            const cols = std.mem.readInt(u16, buf[0..2], .big);
            const rows = std.mem.readInt(u16, buf[2..4], .big);
            self.pty.setSize(cols, rows) catch |err| {
                debugLog("handleAuxInput: resize to {d}x{d} failed: {s}", .{ cols, rows, @errorName(err) });
            };
        }
        var tmp = conn;
        tmp.close();
    }

    fn lastOsc7Cwd(self: *Pod) ?[]const u8 {
        return self.osc7_cwd;
    }

    fn scanOsc7(self: *Pod, data: []const u8) void {
        var new_cwd: ?[]const u8 = null;
        self.osc7_scanner.feed(data, &new_cwd);
        if (new_cwd) |path| {
            // Store a copy of the path
            const copy = self.allocator.dupe(u8, path) catch |err| {
                debugLog("scanOsc7: failed to allocate cwd path: {s}", .{@errorName(err)});
                return;
            };
            if (self.osc7_cwd) |old| self.allocator.free(old);
            self.osc7_cwd = copy;
        }
    }

    fn scanOutputMetadata(self: *Pod, data: []const u8) void {
        if (!self.shouldScanOutputMetadata(data)) return;
        self.scanOsc7(data);
        if (containsClearSeq(data)) {
            self.backlog.clear();
        }
    }

    fn shouldScanOutputMetadata(self: *const Pod, data: []const u8) bool {
        if (data.len == 0) return false;
        if (!self.osc7_scanner.isIdle()) return true;
        for (data) |byte| {
            if (byte == 0x1b or byte == 0x0c) return true;
        }
        return false;
    }
};

fn podFrameCallback(ctx: *anyopaque, frame: pod_protocol.Frame) void {
    const pod: *Pod = @ptrCast(@alignCast(ctx));
    pod.handleFrame(frame);
}

test "ring buffer basic" {
    var buf: [8]u8 = undefined;
    var rb = RingBuffer{ .buf = &buf };
    rb.append("abcd");
    rb.append("ef");
    var out: [8]u8 = undefined;
    const n1 = rb.copyOut(&out);
    try std.testing.expectEqual(@as(usize, 6), n1);
    try std.testing.expect(std.mem.eql(u8, out[0..6], "abcdef"));

    rb.append("0123456789");
    const n2 = rb.copyOut(&out);
    try std.testing.expectEqual(@as(usize, 8), n2);
}

test "password mode clears backlog on enter" {
    var buf: [16]u8 = undefined;
    var rb = RingBuffer{ .buf = &buf };
    rb.append("secret-ish");

    var password_mode = false;
    applyPasswordMode(&rb, &password_mode, true);

    try std.testing.expect(password_mode);
    var out: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), rb.copyOut(&out));
}
