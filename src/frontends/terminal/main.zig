const std = @import("std");
const posix = std.posix;
const core = @import("core");
const terminal = @import("terminal.zig");

const c = @cImport({
    @cInclude("stdlib.h");
});

const FrontendClient = core.FrontendClient;
const FrontendAttach = core.FrontendAttach;
const FrontendTransport = core.FrontendTransport;
const DetachedSessionInfo = core.FrontendDetachedSessionInfo;
const OrphanedPaneInfo = core.FrontendOrphanedPaneInfo;

const State = @import("state.zig").State;
const loop_core = @import("loop_core.zig");
const statusbar = @import("statusbar.zig");

var debug_enabled: bool = false;

/// Global state pointer for signal handlers.
var global_state: std.atomic.Value(?*State) = std.atomic.Value(?*State).init(null);

/// SIGHUP handler: set detach mode and stop the main loop.
/// This is called when the terminal closes unexpectedly.
fn sighupHandler(_: c_int) callconv(.c) void {
    if (global_state.load(.acquire)) |state| {
        state.setDetachMode(true);
        state.running = false;
    }
}

/// SIGTERM/SIGINT handler: gracefully stop the main loop.
/// This allows the defer cleanup to run (disable kitty keyboard protocol, etc.).
fn sigtermHandler(_: c_int) callconv(.c) void {
    if (global_state.load(.acquire)) |state| {
        state.running = false;
    }
}

pub fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled) return;
    const ms = std.time.milliTimestamp();
    const secs = @divTrunc(ms, 1000);
    const frac = @mod(ms, 1000);
    std.debug.print("{d}.{d:0>3} [mux] " ++ fmt ++ "\n", .{ secs, frac } ++ args);
}

pub fn debugLogUuid(uuid: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled) return;
    const short_uuid = if (uuid.len >= 8) uuid[0..8] else uuid;
    const ms = std.time.milliTimestamp();
    const secs = @divTrunc(ms, 1000);
    const frac = @mod(ms, 1000);
    std.debug.print("{d}.{d:0>3} [mux][{s}] " ++ fmt ++ "\n", .{ secs, frac, short_uuid } ++ args);
}

fn notifySessionNameChange(state: *State, change: *FrontendAttach.SessionNameChange) void {
    const msg = std.fmt.allocPrint(
        state.allocator,
        "Session name changed: '{s}' -> '{s}' (collision)",
        .{ change.previous_name, change.resolved_name },
    ) catch null;
    if (msg) |owned| {
        state.notifications.showFor(owned, 4000);
        state.allocator.free(owned);
    }
}

/// Arguments for terminal frontend commands.
pub const MuxArgs = struct {
    name: ?[]const u8 = null,
    attach: ?[]const u8 = null,
    notify_message: ?[]const u8 = null,
    list: bool = false,
    debug: bool = false,
    log_file: ?[]const u8 = null,
    session_config_path: ?[]const u8 = null,
    session_tab_filter: ?[]const u8 = null,
    transport: FrontendTransport = .{ .local_ipc = .{} },
};

/// Entry point for the terminal frontend - can be called directly from unified CLI.
pub fn run(mux_args: MuxArgs) !void {
    const allocator = std.heap.page_allocator;

    // Handle --notify: send to parent terminal frontend and exit.
    if (mux_args.notify_message) |msg| {
        sendNotifyToParentMux(allocator, mux_args.transport, msg);
        return;
    }

    // Handle --list: show detached sessions and orphaned panes.
    if (mux_args.list) {
        const tmp_uuid = core.ipc.generateUuid();
        const tmp_name = core.ipc.generateSessionName();
        var frontend = FrontendClient.initWithTransport(allocator, tmp_uuid, tmp_name, false, false, null, .terminal, mux_args.transport); // keepalive=false for temp connection
        defer frontend.deinit();
        frontend.connect() catch {
            std.debug.print("Could not connect to ses daemon\n", .{});
            return;
        };

        // List detached sessions.
        var sessions: [16]DetachedSessionInfo = undefined;
        const sess_count = frontend.listSessions(&sessions) catch 0;
        if (sess_count > 0) {
            std.debug.print("Detached sessions (attach by name or UUID prefix):\n", .{});
            const instance = std.posix.getenv("HEXE_INSTANCE");
            for (sessions[0..sess_count]) |s| {
                const name = s.session_name[0..s.session_name_len];
                const uuid_prefix = s.session_id[0..8];
                if (instance) |inst| {
                    if (inst.len > 0) {
                        std.debug.print("  [{s}] {s:<12} ({d} tabs)\n", .{ uuid_prefix, name, s.pane_count });
                        std.debug.print("    → hexe terminal attach --instance {s} {s}\n", .{ inst, uuid_prefix });
                    } else {
                        std.debug.print("  [{s}] {s:<12} ({d} tabs)\n", .{ uuid_prefix, name, s.pane_count });
                        std.debug.print("    → hexe terminal attach {s}\n", .{uuid_prefix});
                    }
                } else {
                    std.debug.print("  [{s}] {s:<12} ({d} tabs)\n", .{ uuid_prefix, name, s.pane_count });
                    std.debug.print("    → hexe terminal attach {s}\n", .{uuid_prefix});
                }
            }
        }

        // List orphaned panes.
        var tabs: [32]OrphanedPaneInfo = undefined;
        const count = frontend.listOrphanedPanes(&tabs) catch 0;
        if (count > 0) {
            std.debug.print("Orphaned panes (disowned):\n", .{});
            for (tabs[0..count]) |p| {
                std.debug.print("  [{s}] pid={d}\n", .{ p.uuid[0..8], p.pid });
            }
        }

        if (sess_count == 0 and count == 0) {
            std.debug.print("No detached sessions or orphaned panes\n", .{});
        }
        return;
    }

    // Handle --attach: attach to detached session by name or UUID prefix.
    if (mux_args.attach) |uuid_arg| {
        if (uuid_arg.len < 3) {
            std.debug.print("Session name/UUID too short (need at least 3 chars)\n", .{});
            return;
        }
        // Will be handled after state init.
    }

    // Ignore SIGPIPE so writes to disconnected pod sockets return EPIPE
    // instead of killing the mux process.
    const sigpipe_action = std.os.linux.Sigaction{
        .handler = .{ .handler = std.os.linux.SIG.IGN },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    _ = std.os.linux.sigaction(posix.SIG.PIPE, &sigpipe_action, null);

    // Handle SIGHUP: terminal closed unexpectedly - preserve session for reattach.
    const sighup_action = std.os.linux.Sigaction{
        .handler = .{ .handler = sighupHandler },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    _ = std.os.linux.sigaction(posix.SIG.HUP, &sighup_action, null);

    // Handle SIGTERM/SIGINT: graceful shutdown (allows cleanup to run).
    const sigterm_action = std.os.linux.Sigaction{
        .handler = .{ .handler = sigtermHandler },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    _ = std.os.linux.sigaction(posix.SIG.TERM, &sigterm_action, null);
    _ = std.os.linux.sigaction(posix.SIG.INT, &sigterm_action, null);

    // Redirect stderr to a log file or /dev/null to avoid display corruption.
    // When --debug is set without --logfile, default to instance-specific log.
    var default_log_path: ?[]const u8 = null;
    defer if (default_log_path) |p| allocator.free(p);

    const effective_log: ?[]const u8 = if (mux_args.log_file) |p|
        (if (p.len > 0) p else null)
    else if (mux_args.debug) blk: {
        default_log_path = core.ipc.getLogPath(allocator) catch null;
        break :blk default_log_path;
    } else null;
    redirectStderr(effective_log);
    debug_enabled = mux_args.debug;
    debugLog("started", .{});

    // Get terminal size.
    const size = terminal.getTermSize();

    // Initialize state.
    var state = try State.init(allocator, size.cols, size.rows, mux_args.debug, mux_args.log_file, mux_args.transport);
    defer {
        statusbar.deinitThreadlocals();
        state.deinit();
    }

    // Register state for signal handlers.
    global_state.store(&state, .release);
    defer global_state.store(null, .release);

    // Show notification for config status.
    switch (state.config.status) {
        .missing => state.notifications.showFor("Config not found (~/.config/hexe/init.lua), using defaults", 5000),
        .@"error" => {
            if (state.config.status_message) |msg| {
                const err_msg = std.fmt.allocPrint(allocator, "Config error: {s}", .{msg}) catch null;
                if (err_msg) |m| {
                    state.notifications.showFor(m, 8000);
                    allocator.free(m);
                } else {
                    state.notifications.showFor("Config error, using defaults", 5000);
                }
            } else {
                state.notifications.showFor("Config error, using defaults", 5000);
            }
        },
        .loaded => {},
    }

    // Set custom session name if provided.
    if (mux_args.name) |custom_name| {
        _ = state.setSessionName(custom_name);
    }

    // Set HEXE_MUX_SOCKET as a flag for shell integrations.
    _ = c.setenv("HEXE_MUX_SOCKET", "1", 1);

    // Connect to ses daemon FIRST (start it if needed).
    state.frontend_client.connect() catch |e| {
        debugLog("ses connect failed: {s}", .{@errorName(e)});
        std.debug.print("Could not connect to ses daemon: {s}\n", .{@errorName(e)});
        return;
    };
    debugLog("ses connected (started={})", .{state.frontend_client.just_started_daemon});

    // If server resolved to a different name (collision avoidance), update state.
    if (state.runtime.reconcileResolvedName() catch null) |change| {
        var owned_change = change;
        defer owned_change.deinit(allocator);
        debugLog("session name resolved from '{s}' to '{s}'", .{ owned_change.previous_name, owned_change.resolved_name });
        notifySessionNameChange(&state, &owned_change);
    }

    // Show notification if we just started the daemon.
    if (state.frontend_client.just_started_daemon) {
        state.notifications.showFor("ses daemon started", 2000);
    }

    // Export session ID so child panes can identify their parent mux.
    // Must happen BEFORE createTab/reattach which fork pane shells.
    var session_id_z: [33]u8 = undefined;
    const session_uuid = state.sessionUuid();
    @memcpy(session_id_z[0..32], &session_uuid);
    session_id_z[32] = 0;
    _ = c.setenv("HEXE_SESSION", &session_id_z, 1);

    // Handle --attach: try session first, then orphaned pane.
    if (mux_args.attach) |uuid_prefix| {
        debugLog("attach: trying to reattach with prefix={s}", .{uuid_prefix});
        if (state.reattachSession(uuid_prefix)) {
            debugLog("attach: reattachSession succeeded", .{});
            state.notifications.show("Session reattached");
            // Reattach may change state.uuid — update env for subsequent panes.
            const reattached_uuid = state.sessionUuid();
            @memcpy(session_id_z[0..32], &reattached_uuid);
            _ = c.setenv("HEXE_SESSION", &session_id_z, 1);
        } else if (state.attachOrphanedPane(uuid_prefix)) {
            debugLog("attach: attachOrphanedPane succeeded", .{});
            state.notifications.show("Attached to orphaned pane");
        } else {
            // Session/pane not found - EXIT with error, don't create new session
            debugLog("attach: both reattach methods failed, exiting", .{});
            std.debug.print("Session or pane '{s}' not found\n", .{uuid_prefix});
            std.debug.print("Use 'hexe terminal list' to see available sessions\n", .{});
            return; // Exit without entering main loop
        }
    } else if (mux_args.session_config_path) |config_path| {
        // Launch from session config (.hexe.lua)
        debugLog("applying session config from: {s}", .{config_path});
        const session_config = core.session_config;
        var config = session_config.parseSessionLua(allocator, config_path) catch |err| {
            if (err == error.FileNotFound) {
                std.debug.print("Session config not found: {s}\n", .{config_path});
            } else {
                std.debug.print("Error parsing session config: {s}\n", .{@errorName(err)});
            }
            // Fall back to default tab
            try state.createTab();
            state.adoptStickyPanes();
            try loop_core.runMainLoop(&state);
            return;
        };
        defer config.deinit(allocator);

        // Prefer layout-config name when provided.
        if (config.name) |loaded_name| {
            if (state.setSessionName(loaded_name)) {
                if (state.runtime.syncSessionIdentity() catch null) |change| {
                    var owned_change = change;
                    defer owned_change.deinit(allocator);
                }
            }
        }

        state.applySessionConfig(config, mux_args.session_tab_filter) catch |err| {
            debugLog("applySessionConfig failed: {s}", .{@errorName(err)});
            std.debug.print("Error applying session config: {s}\n", .{@errorName(err)});
            // Fall back to default tab
            try state.createTab();
        };
    } else {
        // Create first tab with one pane (will use ses if connected).
        try state.createTab();
    }

    // Auto-adopt sticky panes from ses for this directory.
    state.adoptStickyPanes();

    // Continue with main loop.
    try loop_core.runMainLoop(&state);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var mux_args = MuxArgs{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if ((std.mem.eql(u8, arg, "--notify") or std.mem.eql(u8, arg, "-n")) and i + 1 < args.len) {
            i += 1;
            mux_args.notify_message = args[i];
        } else if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            mux_args.list = true;
        } else if ((std.mem.eql(u8, arg, "--attach") or std.mem.eql(u8, arg, "-a")) and i + 1 < args.len) {
            i += 1;
            mux_args.attach = args[i];
        } else if ((std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "-N")) and i + 1 < args.len) {
            i += 1;
            mux_args.name = args[i];
        } else if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "-d")) {
            mux_args.debug = true;
        } else if ((std.mem.eql(u8, arg, "--logfile") or std.mem.eql(u8, arg, "-L")) and i + 1 < args.len) {
            i += 1;
            mux_args.log_file = args[i];
        } else if (std.mem.eql(u8, arg, "--no-autostart-ses")) {
            mux_args.transport = .{ .local_ipc = .{
                .autostart_ses = false,
                .socket_path = switch (mux_args.transport) {
                    .local_ipc => |transport| transport.socket_path,
                },
            } };
        } else if (std.mem.eql(u8, arg, "--ses-socket") and i + 1 < args.len) {
            i += 1;
            mux_args.transport = .{ .local_ipc = .{
                .autostart_ses = switch (mux_args.transport) {
                    .local_ipc => |transport| transport.autostart_ses,
                },
                .socket_path = args[i],
            } };
        }
    }

    try run(mux_args);
}

fn redirectStderr(log_file: ?[]const u8) void {
    var redirected = false;
    if (log_file) |path| {
        if (path.len > 0) {
            const logfd = posix.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644) catch null;
            if (logfd) |fd| {
                posix.dup2(fd, posix.STDERR_FILENO) catch |err| {
                    core.logging.logError("mux", "failed to dup2 stderr for logging", err);
                };
                if (fd > 2) posix.close(fd);
                redirected = true;
            }
        }
    }

    if (redirected) return;

    const devnull = std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only }) catch return;
    posix.dup2(devnull.handle, posix.STDERR_FILENO) catch |err| {
        core.logging.logError("mux", "failed to redirect stderr to /dev/null", err);
    };
    devnull.close();
}

fn sendNotifyToParentMux(allocator: std.mem.Allocator, transport: FrontendTransport, message: []const u8) void {
    core.FrontendTransportHelpers.sendNotify(allocator, transport, message) catch |err| {
        core.logging.logError("mux", "failed to send notify message to parent", err);
    };
}
