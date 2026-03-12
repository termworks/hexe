const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ipc = core.ipc;
const state = @import("state.zig");
const server = @import("server.zig");
const persist = @import("persist.zig");
const txlog = @import("txlog.zig");

/// Arguments for ses commands
pub const SesArgs = struct {
    daemon: bool = false,
    debug: bool = false,
    log_file: ?[]const u8 = null,
    list: bool = false,
    full: bool = false,
    notify_message: ?[]const u8 = null,
    notify_uuid: ?[]const u8 = null,
};

/// Debug logging - only outputs when debug mode is enabled
pub var debug_enabled: bool = false;
pub var log_file_path: ?[]const u8 = null;

pub fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled) return;
    const ms = std.time.milliTimestamp();
    const secs = @divTrunc(ms, 1000);
    const frac = @mod(ms, 1000);
    std.debug.print("{d}.{d:0>3} [ses] " ++ fmt ++ "\n", .{ secs, frac } ++ args);
}

pub fn debugLogUuid(uuid: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled) return;
    const short_uuid = if (uuid.len >= 8) uuid[0..8] else uuid;
    const ms = std.time.milliTimestamp();
    const secs = @divTrunc(ms, 1000);
    const frac = @mod(ms, 1000);
    std.debug.print("{d}.{d:0>3} [ses][{s}] " ++ fmt ++ "\n", .{ secs, frac, short_uuid } ++ args);
}

/// Recover from incomplete transactions after crash.
/// Removes detached sessions that had incomplete operations.
fn recoverFromTransactionLog(ses_state: *state.SesState) !void {
    const allocator = ses_state.allocator;

    // Read all transaction log entries
    var entries = ses_state.txlog.readAll(allocator) catch |e| {
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

    // Find incomplete transactions (start without commit) and keep the
    // operation type so recovery can roll back detaches without destroying a
    // still-valid detached session after a failed reattach.
    var incomplete = try txlog.findIncompleteOperations(entries.items);
    defer incomplete.deinit(allocator);

    if (incomplete.items.len == 0) {
        debugLog("txlog: no incomplete transactions", .{});
        // All transactions complete - truncate log
        ses_state.txlog.truncate() catch {};
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
                var pane_iter = ses_state.panes.valueIterator();
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

    // Truncate log after recovery
    ses_state.txlog.truncate() catch {};
    debugLog("txlog: recovery complete", .{});
}

/// Entry point for ses daemon - can be called directly from unified CLI
pub fn run(args: SesArgs) !void {
    const page_alloc = std.heap.page_allocator;

    // Notify mode - send notification to muxes/panes (use page_alloc, no fork)
    if (args.notify_message) |msg| {
        try sendNotify(page_alloc, msg, args.notify_uuid);
        return;
    }

    // List mode - connect to running daemon and show status (use page_alloc, no fork)
    if (args.list) {
        try listStatus(page_alloc, args.full);
        return;
    }

    // Enable debug mode and optional logging.
    // When --debug is set without --logfile, default to instance-specific log.
    debug_enabled = args.debug;
    log_file_path = if (args.log_file) |path|
        (if (path.len > 0) path else null)
    else if (args.debug)
        (ipc.getLogPath(page_alloc) catch null)
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
    persist.load(allocator, &ses_state) catch {};

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
    }

    // Run server
    debugLog("ses: entering event loop", .{});
    srv.run() catch |err| {
        debugLog("ses: event loop FAILED: {s}", .{@errorName(err)});
        return err;
    };
    debugLog("ses: event loop exited normally (self.running=false)", .{});
}

pub fn main() !void {
    // Use page_allocator for arg parsing before fork (survives fork cleanly)
    const page_alloc = std.heap.page_allocator;

    const args = try std.process.argsAlloc(page_alloc);
    defer std.process.argsFree(page_alloc, args);

    // Check for command modes
    var ses_args = SesArgs{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--daemon") or std.mem.eql(u8, arg, "-d")) {
            ses_args.daemon = true;
        } else if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            ses_args.list = true;
        } else if (std.mem.eql(u8, arg, "--full") or std.mem.eql(u8, arg, "-f")) {
            ses_args.full = true;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            ses_args.debug = true;
        } else if (std.mem.eql(u8, arg, "--logfile") or std.mem.eql(u8, arg, "-L")) {
            if (i + 1 < args.len) {
                i += 1;
                ses_args.log_file = args[i];
            } else {
                print("Error: --logfile requires a path\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--notify") or std.mem.eql(u8, arg, "-n")) {
            // Next arg is the message
            if (i + 1 < args.len) {
                i += 1;
                ses_args.notify_message = args[i];
            } else {
                print("Error: --notify requires a message argument\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--uuid") or std.mem.eql(u8, arg, "-u")) {
            // Next arg is the UUID (mux or pane)
            if (i + 1 < args.len) {
                i += 1;
                ses_args.notify_uuid = args[i];
            } else {
                print("Error: --uuid requires a UUID argument\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage();
            return;
        }
    }

    try run(ses_args);
}

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = posix.write(posix.STDOUT_FILENO, msg) catch {};
}

fn printUsage() !void {
    print(
        \\hexe-ses - PTY session server
        \\
        \\Usage: hexe-ses [OPTIONS]
        \\
        \\Options:
        \\  -d, --daemon       Run as a background daemon
        \\  -l, --list         List connected muxes and their panes
        \\  -f, --full         Show full tree (use with --list)
        \\  --debug            Enable debug output
        \\  -L, --logfile PATH Log debug output to PATH
        \\  -n, --notify MSG   Send notification to all connected muxes
        \\  -u, --uuid UUID    Target specific mux or pane (use with --notify)
        \\  -h, --help         Show this help message
        \\
        \\Notification targeting:
        \\  --notify "msg"                   Broadcast to all muxes (MUX realm)
        \\  --notify "msg" --uuid <mux_uuid> Send to specific mux (MUX realm)
        \\  --notify "msg" --uuid <pane_uuid> Send to specific pane (PANE realm)
        \\
        \\The ses server holds PTY file descriptors to keep processes alive
        \\when mux clients disconnect. It is automatically started by mux
        \\if not already running.
        \\
    , .{});
}

fn sendNotify(allocator: std.mem.Allocator, message: []const u8, target_uuid: ?[]const u8) !void {
    const wire = core.wire;

    if (target_uuid) |uuid| {
        const socket_path = try ipc.getSesSocketPath(allocator);
        defer allocator.free(socket_path);

        var client = ipc.Client.connect(socket_path) catch |err| {
            if (err == error.ConnectionRefused or err == error.FileNotFound) {
                print("ses daemon is not running\n", .{});
                return;
            }
            return err;
        };
        defer client.close();
        const fd = client.fd;

        const handshake: [1]u8 = .{wire.SES_HANDSHAKE_CLI};
        wire.writeAll(fd, &handshake) catch return;

        if (uuid.len >= 32) {
            var tn: wire.TargetedNotify = .{
                .uuid = undefined,
                .timeout_ms = 0,
                .msg_len = @intCast(message.len),
            };
            @memcpy(&tn.uuid, uuid[0..32]);
            wire.writeControlWithTrail(fd, .targeted_notify, std.mem.asBytes(&tn), message) catch return;
        }
    } else {
        core.FrontendTransportHelpers.sendNotify(allocator, .{ .local_ipc = .{} }, message) catch |err| {
            if (err == error.ConnectionRefused or err == error.FileNotFound) {
                print("ses daemon is not running\n", .{});
                return;
            }
            return err;
        };
    }
    print("Notification sent\n", .{});
}

fn listStatus(allocator: std.mem.Allocator, full_mode: bool) !void {
    const wire = core.wire;

    const socket_path = try ipc.getSesSocketPath(allocator);
    defer allocator.free(socket_path);

    var client = ipc.Client.connect(socket_path) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            print("ses daemon is not running\n", .{});
            return;
        }
        return err;
    };
    defer client.close();
    const fd = client.fd;

    // CLI handshake
    const handshake: [1]u8 = .{wire.SES_HANDSHAKE_CLI};
    wire.writeAll(fd, &handshake) catch return;

    // Always request full to get mux_state trees
    _ = full_mode;
    const flag: [1]u8 = .{1}; // full mode
    wire.writeControl(fd, .status, &flag) catch return;

    // Read response
    const hdr = wire.readControlHeader(fd) catch return;
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type != .status or hdr.payload_len < @sizeOf(wire.StatusResp)) {
        print("Invalid response from daemon\n", .{});
        return;
    }

    const payload = allocator.alloc(u8, hdr.payload_len) catch {
        print("Allocation failed\n", .{});
        return;
    };
    defer allocator.free(payload);
    wire.readExact(fd, payload) catch return;

    var off: usize = 0;

    if (off + @sizeOf(wire.StatusResp) > payload.len) return;
    const status_hdr = std.mem.bytesToValue(wire.StatusResp, payload[off..][0..@sizeOf(wire.StatusResp)]);
    off += @sizeOf(wire.StatusResp);

    // Connected clients
    if (status_hdr.client_count > 0) {
        print("Connected muxes: {d}\n", .{status_hdr.client_count});
    }

    var ci: u16 = 0;
    while (ci < status_hdr.client_count) : (ci += 1) {
        if (off + @sizeOf(wire.StatusClient) > payload.len) return;
        const sc = std.mem.bytesToValue(wire.StatusClient, payload[off..][0..@sizeOf(wire.StatusClient)]);
        off += @sizeOf(wire.StatusClient);

        if (off + sc.name_len > payload.len) return;
        const name_str = if (sc.name_len > 0) payload[off .. off + sc.name_len] else "unknown";
        off += sc.name_len;

        if (off + sc.session_state_len > payload.len) return;
        const session_state = if (sc.session_state_len > 0) payload[off .. off + sc.session_state_len] else "";
        off += sc.session_state_len;

        const sid8: []const u8 = if (sc.has_session_id != 0) sc.session_id[0..8] else "????????";
        print("  {s} [{s}] (mux #{d}, {d} panes)\n", .{ name_str, sid8, sc.id, sc.pane_count });

        // Read pane entries
        var pi: u16 = 0;
        while (pi < sc.pane_count) : (pi += 1) {
            if (off + @sizeOf(wire.StatusPaneEntry) > payload.len) return;
            const pe = std.mem.bytesToValue(wire.StatusPaneEntry, payload[off..][0..@sizeOf(wire.StatusPaneEntry)]);
            off += @sizeOf(wire.StatusPaneEntry);
            if (off + pe.name_len > payload.len) return;
            off += pe.name_len;
            if (off + pe.sticky_pwd_len > payload.len) return;
            off += pe.sticky_pwd_len;
        }

        if (session_state.len > 0) {
            printMuxStateTree(allocator, session_state, "    ");
        }
    }

    // Detached sessions
    if (status_hdr.detached_count > 0) {
        print("\nDetached sessions: {d}\n", .{status_hdr.detached_count});
    }

    var di: u16 = 0;
    while (di < status_hdr.detached_count) : (di += 1) {
        if (off + @sizeOf(wire.DetachedSessionEntry) > payload.len) return;
        const de = std.mem.bytesToValue(wire.DetachedSessionEntry, payload[off..][0..@sizeOf(wire.DetachedSessionEntry)]);
        off += @sizeOf(wire.DetachedSessionEntry);

        if (off + de.name_len > payload.len) return;
        const name_str = if (de.name_len > 0) payload[off .. off + de.name_len] else "unknown";
        off += de.name_len;

        if (off + de.session_state_len > payload.len) return;
        const session_state = if (de.session_state_len > 0) payload[off .. off + de.session_state_len] else "";
        off += de.session_state_len;

        // Include --instance flag if not in default instance
        const instance = posix.getenv("HEXE_INSTANCE");
        if (instance) |inst| {
            if (inst.len > 0) {
                print("  {s} [{s}] {d} panes - reattach: hexe terminal attach --instance {s} {s}\n", .{ name_str, de.session_id[0..8], de.pane_count, inst, name_str });
            } else {
                print("  {s} [{s}] {d} panes - reattach: hexe terminal attach {s}\n", .{ name_str, de.session_id[0..8], de.pane_count, name_str });
            }
        } else {
            print("  {s} [{s}] {d} panes - reattach: hexe terminal attach {s}\n", .{ name_str, de.session_id[0..8], de.pane_count, name_str });
        }

        if (session_state.len > 0) {
            printMuxStateTree(allocator, session_state, "    ");
        }
    }

    // Orphaned panes
    if (status_hdr.orphaned_count > 0) {
        print("\nOrphaned panes (disowned): {d}\n", .{status_hdr.orphaned_count});
    }

    var oi: u16 = 0;
    while (oi < status_hdr.orphaned_count) : (oi += 1) {
        if (off + @sizeOf(wire.StatusPaneEntry) > payload.len) return;
        const pe = std.mem.bytesToValue(wire.StatusPaneEntry, payload[off..][0..@sizeOf(wire.StatusPaneEntry)]);
        off += @sizeOf(wire.StatusPaneEntry);
        if (off + pe.name_len > payload.len) return;
        off += pe.name_len;
        if (off + pe.sticky_pwd_len > payload.len) return;
        off += pe.sticky_pwd_len;
        print("  [{s}] pid={d}\n", .{ pe.uuid[0..8], pe.pid });
    }

    // Sticky panes
    if (status_hdr.sticky_count > 0) {
        print("\nSticky panes: {d}\n", .{status_hdr.sticky_count});
    }

    var si: u16 = 0;
    while (si < status_hdr.sticky_count) : (si += 1) {
        if (off + @sizeOf(wire.StickyPaneEntry) > payload.len) return;
        const se = std.mem.bytesToValue(wire.StickyPaneEntry, payload[off..][0..@sizeOf(wire.StickyPaneEntry)]);
        off += @sizeOf(wire.StickyPaneEntry);
        if (off + se.name_len > payload.len) return;
        off += se.name_len;
        if (off + se.pwd_len > payload.len) return;
        const pwd = if (se.pwd_len > 0) payload[off .. off + se.pwd_len] else "";
        off += se.pwd_len;

        print("  [{s}] pid={d}", .{ se.uuid[0..8], se.pid });
        if (pwd.len > 0) {
            print(" pwd={s}", .{pwd});
        }
        if (se.key != 0) {
            print(" key={c}", .{se.key});
        }
        print("\n", .{});
    }
}

fn printSessionLayoutPanes(node: ?*const core.session_model.SessionLayoutNode, focused_uuid: ?[32]u8, indent: []const u8) void {
    const root = node orelse return;
    switch (root.*) {
        .pane => |uuid| {
            const marker = if (focused_uuid) |focused|
                if (std.mem.eql(u8, &focused, &uuid)) ">" else " "
            else
                " ";
            print("{s}  {s} Pane [{s}]\n", .{ indent, marker, uuid[0..8] });
        },
        .split => |split| {
            printSessionLayoutPanes(split.first, focused_uuid, indent);
            printSessionLayoutPanes(split.second, focused_uuid, indent);
        },
    }
}

fn printMuxStateTree(allocator: std.mem.Allocator, mux_state_json: []const u8, indent: []const u8) void {
    var snapshot = core.session_model.SessionSnapshot.fromJson(allocator, mux_state_json) catch {
        print("{s}(failed to parse session snapshot)\n", .{indent});
        return;
    };
    defer snapshot.deinit();

    // Print tabs
    for (snapshot.tabs.items, 0..) |tab, ti| {
        const marker = if (ti == snapshot.active_tab) "*" else " ";
        print("{s}{s} Tab: {s}\n", .{ indent, marker, tab.name });
        printSessionLayoutPanes(tab.root, tab.focused_pane_uuid, indent);
    }

    // Print floats
    if (snapshot.floats.items.len > 0) {
        print("{s}Floats:\n", .{indent});
        for (snapshot.floats.items) |float_state| {
            const marker = if (snapshot.active_float_uuid) |active_uuid|
                if (std.mem.eql(u8, &active_uuid, &float_state.pane_uuid)) "*" else " "
            else
                " ";
            const vis_str = if (float_state.visible) "" else " (hidden)";
            const pwd_str = if (float_state.is_pwd) " [pwd]" else "";
            print("{s}  {s} Float [{s}]{s}{s}\n", .{ indent, marker, float_state.pane_uuid[0..8], pwd_str, vis_str });
        }
    }
}

fn printLayoutTree(_: std.json.ObjectMap, _: []const u8, _: usize) void {
    // Layout tree printing is optional - the pane list above shows the essentials
}

fn daemonize(log_file: ?[]const u8) !void {
    // First fork
    const pid1 = try posix.fork();
    if (pid1 != 0) {
        // Parent exits
        posix.exit(0);
    }

    // Create new session
    _ = posix.setsid() catch {};

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
    const devnull = posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch return;
    posix.dup2(devnull, posix.STDIN_FILENO) catch {};
    posix.dup2(devnull, posix.STDOUT_FILENO) catch {};

    if (log_file) |log_path| {
        if (log_path.len > 0) {
            const logfd = posix.open(log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644) catch {
                posix.dup2(devnull, posix.STDERR_FILENO) catch {};
                if (devnull > 2) posix.close(devnull);
                std.posix.chdir("/") catch {};
                return;
            };
            posix.dup2(logfd, posix.STDERR_FILENO) catch {};
            if (logfd > 2) posix.close(logfd);
        } else {
            posix.dup2(devnull, posix.STDERR_FILENO) catch {};
        }
    } else {
        // Default: no noisy logfile. If user wants logs, they pass --logfile.
        posix.dup2(devnull, posix.STDERR_FILENO) catch {};
    }

    if (devnull > 2) posix.close(devnull);

    // Change to root directory
    std.posix.chdir("/") catch {};
}

var global_server: std.atomic.Value(?*server.Server) = std.atomic.Value(?*server.Server).init(null);

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
    _ = std.posix.write(std.posix.STDERR_FILENO, msg) catch {};
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
