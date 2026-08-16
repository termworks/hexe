const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ipc = core.ipc;
const state = @import("state.zig");
const server = @import("server.zig");
const persist = @import("persist.zig");
const txlog = @import("txlog.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = core.logging.stdLogFn,
};

/// Arguments the unified CLI passes when it starts the daemon.
pub const SesArgs = struct {
    daemon: bool = false,
    log_level: ?core.logging.Level = null,
    log_file: ?[]const u8 = null,
};

/// Debug logging - only outputs when debug mode is enabled
pub var debug_enabled: bool = false;
pub var active_log_level: ?core.logging.Level = null;
pub var log_file_path: ?[]const u8 = null;

pub inline fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled) return;
    core.logging.debugWithSource("ses", fmt, args, @src());
}

pub inline fn debugLogUuid(uuid: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled) return;
    const short_uuid = if (uuid.len >= 8) uuid[0..8] else uuid;
    core.logging.debugWithSource("ses", "[{s}] " ++ fmt, .{short_uuid} ++ args, @src());
}

pub inline fn traceLog(comptime fmt: []const u8, args: anytype) void {
    if (active_log_level != .trace) return;
    core.logging.traceWithSource("ses", fmt, args, @src());
}

/// Recover from incomplete transactions after crash.
/// Removes detached sessions that had incomplete operations.
fn recoverFromTransactionLog(ses_state: *state.SesState) !void {
    const allocator = ses_state.allocator;

    // Read all transaction log entries
    var entries = ses_state.persistence.txlog.readAll(allocator) catch |e| {
        debugLog("txlog readAll failed: {s}", .{@errorName(e)});
        return;
    };
    defer {
        for (entries.items) |*e| {
            allocator.free(e.payload);
        }
        entries.deinit(allocator);
    }

    if (entries.items.len == 0) {
        debugLog("txlog: no entries to recover", .{});
        return;
    }

    debugLog("txlog: checking {d} entries for incomplete transactions", .{entries.items.len});

    // A replay that stopped at the size cap read only the OLDEST entries, so a
    // `detach_start` may well have its `detach_commit` sitting just past the
    // cutoff. Rolling those back deletes fully-committed detached sessions and
    // orphans their panes -- catastrophically worse than leaving a genuinely
    // half-done transaction in place, which the next clean run resolves.
    if (ses_state.persistence.txlog.lastReadWasTruncated()) {
        core.logging.warn("ses", "txlog replay hit the size cap; rolling nothing back (cannot prove completeness)", .{});
        ses_state.persistence.txlog.truncate() catch |err| {
            core.logging.logError("ses", "failed to truncate oversized txlog", err);
        };
        return;
    }

    // Find incomplete transactions (start without commit) and keep the
    // operation type so recovery can roll back detaches without destroying a
    // still-valid detached session after a failed reattach.
    var incomplete = try txlog.findIncompleteOperations(allocator, entries.items);
    defer incomplete.deinit(allocator);

    if (incomplete.items.len == 0) {
        debugLog("txlog: no incomplete transactions", .{});
        // All transactions complete - truncate log
        ses_state.persistence.txlog.truncate() catch |err| {
            core.logging.logError("ses", "failed to truncate complete txlog", err);
        };
        return;
    }

    // Handle incomplete transactions: remove detached sessions
    debugLog("txlog: found {d} incomplete transactions, rolling back", .{incomplete.items.len});
    for (incomplete.items) |entry| {
        const hex_id: [32]u8 = std.fmt.bytesToHex(&entry.session_id, .lower);
        switch (entry.tx_type) {
            .detach_start => {
                debugLog("txlog: removing incomplete detached session {s}", .{hex_id[0..8]});

                // Remove from detached sessions (best-effort cleanup)
                ses_state.removeDetachedSession(entry.session_id);

                // Mark all panes with this session_id as orphaned
                var pane_iter = ses_state.store.panes.valueIterator();
                while (pane_iter.next()) |pane| {
                    if (pane.session_id) |sid| {
                        if (std.mem.eql(u8, &sid, &entry.session_id)) {
                            _ = pane.transitionState(.orphaned, "txlog recovery (incomplete detach)");
                            pane.session_id = null;
                            debugLog("txlog: marked pane {s} as orphaned", .{pane.uuid[0..8]});
                        }
                    }
                }
            },
            .reattach_start => {
                // Reattach start does not mutate detached session storage.
                // If SES dies before the client re-registers with the restored
                // session ID, the safe rollback is to keep the detached session.
                debugLog("txlog: preserving detached session after incomplete reattach {s}", .{hex_id[0..8]});
            },
            else => {},
        }
    }

    // Recovery mutated canonical state (orphaned panes, removed detached
    // sessions). Mark dirty so the next persistence cycle writes it out —
    // otherwise the rollback is lost on a quiet shutdown and the half-done
    // transaction reappears on the following restart.
    ses_state.store.dirty = true;

    // Truncate log after recovery
    ses_state.persistence.txlog.truncate() catch |err| {
        core.logging.logError("ses", "failed to truncate txlog after recovery", err);
    };
    debugLog("txlog: recovery complete", .{});
}

/// Entry point for ses daemon - can be called directly from unified CLI
pub fn run(args: SesArgs) !void {
    const page_alloc = std.heap.page_allocator;

    // Enable logging and optional log-file redirection.
    // When --log is set without --logfile, default to instance-specific log.
    const effective_level = core.logging.effectiveLevel(args.log_level, args.log_file);
    active_log_level = effective_level;
    debug_enabled = core.logging.levelEnablesDebug(effective_level);
    log_file_path = if (args.log_file) |path|
        (if (path.len > 0) path else null)
    else if (args.log_level != null)
        (ipc.getLogPath(page_alloc) catch |err| blk: {
            core.logging.logError("ses", "failed to resolve default log path", err);
            break :blk null;
        })
    else
        null;

    // Avoid multiple daemons: if ses socket is connectable, exit.
    {
        const check_alloc = std.heap.page_allocator;
        const socket_path = ipc.getSesSocketPath(check_alloc) catch "";
        defer if (socket_path.len > 0) check_alloc.free(socket_path);

        if (socket_path.len > 0) {
            if (ipc.Client.connect(socket_path)) |c0| {
                var c = c0;
                c.close();
                if (!args.daemon) {
                    std.debug.print("ses daemon already running at: {s}\n", .{socket_path});
                }
                return;
            } else |_| {
                // Not running or stale socket.
            }
        }
    }

    // Daemonize BEFORE creating GPA
    if (args.daemon) {
        try daemonize(log_file_path);
    }

    // Authoritative single-instance guard. The connect-probe above is a fast
    // pre-check but is a TOCTOU race: two daemons starting at once can both
    // pass it and both bind the socket (ipc.Server deletes+rebinds), splitting
    // session state across two daemons. An exclusive flock arbitrates the
    // race — the loser exits before binding. Acquired after daemonize so the
    // lock is held by the real long-lived daemon process (flock survives fork
    // and is released on process exit).
    if (!acquireInstanceLock()) {
        if (!args.daemon) {
            std.debug.print("ses daemon already starting (instance lock held)\n", .{});
        }
        return;
    }

    core.logging.setLogLevel(effective_level);
    debugLog("daemon={} level={s} logfile={s}", .{
        args.daemon,
        if (effective_level) |level| @tagName(level) else "off",
        log_file_path orelse "(none)",
    });
    traceLog("env HEXE_INSTANCE={s} HEXE_TEST_ONLY={s}", .{
        std.posix.getenv("HEXE_INSTANCE") orelse "(none)",
        std.posix.getenv("HEXE_TEST_ONLY") orelse "(none)",
    });

    // Now create GPA AFTER fork - this ensures clean allocator state
    // Note: GPA still has issues after fork, so we use page_allocator for most operations
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize state (uses page_allocator internally)
    var ses_state = state.SesState.init(allocator);
    defer ses_state.deinit();

    // Load persisted registry/layout (best-effort).
    // Uses page_allocator for temporary allocations to avoid GPA issues after fork.
    // Verifies pods are still alive before restoring them.
    persist.load(allocator, &ses_state) catch |err| {
        core.logging.logError("ses", "failed to load persisted session state", err);
    };

    // Transaction log recovery: check for incomplete operations from crash.
    recoverFromTransactionLog(&ses_state) catch |e| {
        debugLog("transaction log recovery failed: {s}", .{@errorName(e)});
    };

    // Clean up sessions with dead panes and duplicate names.
    ses_state.cleanupDetachedSessions();

    // Initialize server (uses page_allocator internally)
    var srv = server.Server.init(allocator, &ses_state) catch |err| {
        return err;
    };
    defer srv.deinit();

    // Set up signal handlers
    setupSignalHandlers(&srv);

    // Print socket path if not daemon
    if (!args.daemon) {
        const socket_path = ipc.getSesSocketPath(allocator) catch "";
        defer if (socket_path.len > 0) allocator.free(socket_path);
        std.debug.print("ses: listening on {s}\n", .{socket_path});
        traceLog("listening socket={s}", .{socket_path});
    }

    // Run server
    debugLog("ses: entering event loop", .{});
    srv.run() catch |err| {
        debugLog("ses: event loop FAILED: {s}", .{@errorName(err)});
        return err;
    };
    debugLog("ses: event loop exited normally (self.running=false)", .{});
}

fn daemonize(log_file: ?[]const u8) !void {
    // First fork
    const pid1 = try posix.fork();
    if (pid1 != 0) {
        // Parent exits
        posix.exit(0);
    }

    // Create new session
    _ = try posix.setsid();

    // Second fork (prevent reacquiring terminal)
    const pid2 = try posix.fork();
    if (pid2 != 0) {
        // First child exits
        posix.exit(0);
    }

    // We are now the daemon process

    // Do not die when the parent terminal closes.
    // We also close stdio fds below, but ignoring SIGHUP makes the intent explicit
    // and protects us from other session teardown edge-cases.
    const sighup_action = std.os.linux.Sigaction{
        .handler = .{ .handler = std.os.linux.SIG.IGN },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    _ = std.os.linux.sigaction(posix.SIG.HUP, &sighup_action, null);

    // Redirect stdin/stdout/stderr away from the controlling terminal.
    // If stderr isn't redirected too, some terminals will still keep the PTY
    // alive and can deliver a HUP/teardown in surprising ways.
    const devnull = try posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
    try posix.dup2(devnull, posix.STDIN_FILENO);
    try posix.dup2(devnull, posix.STDOUT_FILENO);

    if (log_file) |log_path| {
        if (log_path.len > 0) {
            const logfd = try posix.open(log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
            try posix.dup2(logfd, posix.STDERR_FILENO);
            if (logfd > 2) posix.close(logfd);
        } else {
            try posix.dup2(devnull, posix.STDERR_FILENO);
        }
    } else {
        // Default: no noisy logfile. If user wants logs, they pass --logfile.
        try posix.dup2(devnull, posix.STDERR_FILENO);
    }

    if (devnull > 2) posix.close(devnull);

    // Change to root directory
    try std.posix.chdir("/");
}

var global_server: std.atomic.Value(?*server.Server) = std.atomic.Value(?*server.Server).init(null);

// Held for the daemon's whole lifetime; flock releases automatically on exit.
// Intentionally never closed — the open fd is what holds the exclusive lock.
var instance_lock_fd: ?posix.fd_t = null;

/// Take the per-instance exclusive lock next to the SES socket. Returns true if
/// we own it (or if lock infrastructure is unavailable — fail open rather than
/// refuse to start), false only when another live daemon already holds it.
fn acquireInstanceLock() bool {
    const alloc = std.heap.page_allocator;
    const socket_path = ipc.getSesSocketPath(alloc) catch return true;
    defer alloc.free(socket_path);
    if (socket_path.len == 0) return true;

    const lock_path = std.fmt.allocPrintSentinel(alloc, "{s}.lock", .{socket_path}, 0) catch return true;
    defer alloc.free(lock_path);

    // Ensure the runtime dir exists (mirrors ipc.Server socket dir creation).
    if (std.fs.path.dirname(lock_path)) |dir| std.fs.cwd().makePath(dir) catch {};

    // CLOEXEC is load-bearing: a flock is owned by the open file DESCRIPTION,
    // which fork+exec'd children share. Without it every spawned pod inherits
    // the lock fd, so after a daemon crash the pods keep the instance lock
    // held and no replacement daemon can ever start (silent exit here) until
    // every pod dies — "hexe won't start" after any crash with live panes.
    const fd = posix.open(lock_path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600) catch |err| {
        debugLog("acquireInstanceLock: open '{s}' failed: {s} (allowing start)", .{ lock_path, @errorName(err) });
        return true;
    };

    posix.flock(fd, posix.LOCK.EX | posix.LOCK.NB) catch |err| switch (err) {
        error.WouldBlock => {
            // Another live daemon owns the instance.
            posix.close(fd);
            return false;
        },
        else => {
            debugLog("acquireInstanceLock: flock failed: {s} (allowing start)", .{@errorName(err)});
            posix.close(fd);
            return true;
        },
    };

    // Record our pid in the lock file so a newer-build frontend that detects
    // a stale-epoch daemon can terminate us and take over the instance (see
    // SesClient.terminateStaleDaemon). Best-effort: without it the frontend
    // just can't auto-replace a stale daemon.
    writeLockPid(fd);

    instance_lock_fd = fd;
    return true;
}

fn writeLockPid(fd: posix.fd_t) void {
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}\n", .{std.os.linux.getpid()}) catch return;
    posix.ftruncate(fd, 0) catch return;
    _ = posix.pwrite(fd, text, 0) catch return;
}

fn setupSignalHandlers(srv: *server.Server) void {
    global_server.store(srv, .release);

    // Ignore SIGPIPE - we handle closed connections gracefully
    const sigpipe_action = std.os.linux.Sigaction{
        .handler = .{ .handler = std.os.linux.SIG.IGN },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    _ = std.os.linux.sigaction(posix.SIG.PIPE, &sigpipe_action, null);

    // Set up SIGTERM and SIGINT handlers
    const sigterm_action = std.os.linux.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };

    _ = std.os.linux.sigaction(posix.SIG.TERM, &sigterm_action, null);
    _ = std.os.linux.sigaction(posix.SIG.INT, &sigterm_action, null);
}

fn signalHandler(sig: c_int) callconv(.c) void {
    // Write directly to stderr (fd=2) since debugLog may not be safe in signal context
    const msg = switch (sig) {
        std.posix.SIG.TERM => "ses: received SIGTERM, stopping\n",
        std.posix.SIG.INT => "ses: received SIGINT, stopping\n",
        else => "ses: received unknown signal, stopping\n",
    };
    _ = std.posix.write(std.posix.STDERR_FILENO, msg) catch 0;
    if (global_server.load(.acquire)) |srv| {
        srv.stop();
    }
}

// Module exports for use by mux
pub const SesState = state.SesState;
pub const Pane = state.Pane;
pub const PaneState = state.PaneState;
pub const Client = state.Client;
pub const Server = server.Server;
