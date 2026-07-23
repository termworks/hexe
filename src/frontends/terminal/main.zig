const std = @import("std");
const posix = std.posix;
const core = @import("core");
const terminal = @import("terminal.zig");

const c = @cImport({
    @cInclude("stdlib.h");
});

const FrontendAttach = core.FrontendAttach;
const FrontendRuntime = core.FrontendRuntime;
const FrontendConnectOptions = core.FrontendConnectOptions;
const DetachedSessionInfo = core.FrontendDetachedSessionInfo;
const OrphanedPaneInfo = core.FrontendOrphanedPaneInfo;

const State = @import("state.zig").State;
const terminal_host = @import("host.zig");
const startup_chooser = @import("startup_chooser.zig");
const statusbar = @import("statusbar.zig");

var debug_enabled: bool = false;

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = core.logging.stdLogFn,
};

/// Global state pointer for signal handlers.
var global_state: std.atomic.Value(?*State) = std.atomic.Value(?*State).init(null);

/// SIGHUP handler: set detach mode and stop the main loop.
/// This is called when the terminal closes unexpectedly.
fn sighupHandler(_: c_int) callconv(.c) void {
    if (global_state.load(.acquire)) |state| {
        state.runtime.requestFrontendDisconnectStop();
    }
}

/// SIGTERM/SIGINT handler: gracefully stop the main loop.
/// This allows the defer cleanup to run (disable kitty keyboard protocol, etc.).
fn sigtermHandler(_: c_int) callconv(.c) void {
    if (global_state.load(.acquire)) |state| {
        state.running = false;
    }
}

pub inline fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled) return;
    core.logging.debugWithSource("terminal", fmt, args, @src());
}

pub inline fn debugLogUuid(uuid: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled) return;
    const short_uuid = if (uuid.len >= 8) uuid[0..8] else uuid;
    core.logging.debugWithSource("terminal", "[{s}] " ++ fmt, .{short_uuid} ++ args, @src());
}

fn notifySessionNameChange(state: *State, change: *FrontendAttach.SessionNameChange) void {
    const msg = std.fmt.allocPrint(
        state.allocator,
        "Session name changed: '{s}' -> '{s}' (collision)",
        .{ change.previous_name, change.resolved_name },
    ) catch |err| blk: {
        core.logging.logError("terminal", "failed to allocate session-name change notification", err);
        break :blk null;
    };
    if (msg) |owned| {
        state.notifications.showFor(owned, 4000);
        state.allocator.free(owned);
    }
}

const ResolvedAttachTarget = struct {
    target: []const u8,
    owned: ?[]u8 = null,

    pub fn deinit(self: *ResolvedAttachTarget, allocator: std.mem.Allocator) void {
        if (self.owned) |owned| allocator.free(owned);
        self.* = undefined;
    }
};

/// Print to the controlling terminal directly. The frontend redirects
/// stderr to /dev/null (or the logfile) at startup so the TUI stays clean —
/// which made every attach-resolution message, INCLUDING the ambiguity
/// picker prompt, invisible: the process then blocked reading stdin behind a
/// prompt nobody could see ("attach just hangs"). Interactive output goes to
/// /dev/tty, which survives the redirect.
fn ttyPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    if (std.fs.openFileAbsolute("/dev/tty", .{ .mode = .write_only })) |tty| {
        defer tty.close();
        tty.writeAll(msg) catch {};
        return;
    } else |_| {}
    // No controlling terminal (setsid'd): stdin is the terminal for any
    // interactive session — writing to a tty through its stdin fd is valid.
    if (std.posix.isatty(std.posix.STDIN_FILENO)) {
        var off: usize = 0;
        while (off < msg.len) {
            off += std.posix.write(std.posix.STDIN_FILENO, msg[off..]) catch return;
        }
    }
}

fn readAttachSelection(max: usize) ?usize {
    var in_buf: [64]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(&in_buf);
    const line = stdin.interface.takeDelimiterExclusive('\n') catch return null;
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    const choice = std.fmt.parseInt(usize, trimmed, 10) catch return null;
    if (choice == 0 or choice > max) return null;
    return choice - 1;
}

fn resolveDotAttachTarget(allocator: std.mem.Allocator, runtime: *FrontendRuntime, original: []const u8) !ResolvedAttachTarget {
    if (!std.mem.eql(u8, original, ".")) return .{ .target = original };

    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    var sessions: [64]DetachedSessionInfo = undefined;
    const count = try runtime.listSessions(&sessions);

    // Attached sessions match too: closing a window and immediately running
    // `attach .` races the daemon's disconnect detection — the session is
    // still "attached" for a moment, and matching only detached records made
    // dot-attach fail intermittently. Attaching to an attached session goes
    // through the normal force-detach steal. The requester's own freshly
    // registered session must be excluded or it would steal itself.
    const own_uuid: [32]u8 = runtime.sessionUuid();
    debugLog("dotAttach: cwd={s} listed={d} own={s}", .{ cwd, count, own_uuid[0..8] });
    for (sessions[0..count]) |sess| {
        debugLog("dotAttach: cand id={s} att={} root={s}", .{ sess.session_id[0..8], sess.attached, sess.base_root[0..sess.base_root_len] });
    }
    var matches: [64]usize = undefined;
    var match_count: usize = 0;
    for (sessions[0..count], 0..) |session, idx| {
        if (std.mem.eql(u8, &session.session_id, &own_uuid)) continue;
        // A ZERO-pane session is never a meaningful attach target: attached
        // ones are frontends still booting (they register before creating a
        // pane — e.g. a concurrent `attach .` racer), and detached ones are
        // leftovers of aborted attaches. Matching them forced the ambiguity
        // picker on phantom candidates.
        if (session.pane_count == 0) continue;
        const base_root = session.base_root[0..session.base_root_len];
        if (base_root.len == 0 or !std.mem.eql(u8, base_root, cwd)) continue;
        // Dedup by session id: during park/steal transitions one session can
        // briefly appear both as a stale attached client and as its detached
        // record. Two entries for one session must not trigger the picker
        // (which would look like a hang). Prefer the detached record.
        var duplicate = false;
        for (matches[0..match_count]) |existing_idx| {
            if (std.mem.eql(u8, &sessions[existing_idx].session_id, &session.session_id)) {
                if (sessions[existing_idx].attached and !session.attached) {
                    matches[std.mem.indexOfScalar(usize, matches[0..match_count], existing_idx).?] = idx;
                }
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        matches[match_count] = idx;
        match_count += 1;
    }

    if (match_count == 0) {
        ttyPrint("No session rooted at: {s}\n", .{cwd});
        return error.SessionNotFound;
    }

    if (match_count == 1) {
        const session = sessions[matches[0]];
        const target = try allocator.dupe(u8, session.session_id[0..8]);
        return .{ .target = target, .owned = target };
    }

    ttyPrint("Sessions rooted at {s}:\n", .{cwd});
    for (matches[0..match_count], 0..) |session_idx, display_idx| {
        const session = sessions[session_idx];
        const name = session.session_name[0..session.session_name_len];
        const state_tag: []const u8 = if (session.attached) " (attached)" else "";
        ttyPrint("  {d}) [{s}] {s} ({d} panes){s}\n", .{ display_idx + 1, session.session_id[0..8], name, session.pane_count, state_tag });
    }
    // Never block waiting for a selection that cannot come: on a non-tty
    // stdin (scripts, pipelines) the old blocking read looked like a hang.
    if (!std.posix.isatty(std.posix.STDIN_FILENO)) {
        ttyPrint("Multiple sessions match; attach by UUID prefix instead.\n", .{});
        return error.InvalidSelection;
    }
    ttyPrint("Select session [1-{d}]: ", .{match_count});
    const selected = readAttachSelection(match_count) orelse return error.InvalidSelection;
    const session = sessions[matches[selected]];
    const target = try allocator.dupe(u8, session.session_id[0..8]);
    return .{ .target = target, .owned = target };
}

/// Arguments for terminal frontend commands.
pub const TerminalArgs = struct {
    name: ?[]const u8 = null,
    attach: ?[]const u8 = null,
    notify_message: ?[]const u8 = null,
    list: bool = false,
    log_level: ?core.logging.Level = null,
    log_file: ?[]const u8 = null,
    session_config_path: ?[]const u8 = null,
    session_tab_filter: ?[]const u8 = null,
    /// Bare `hexe` with no arguments: ask (in a popup) whether to attach to a
    /// session already rooted at this cwd, then whether to load .hexe.lua,
    /// before falling back to a plain new session. See startup_chooser.zig.
    startup_chooser: bool = false,
    connect_options: FrontendConnectOptions = .{},
};

/// Entry point for the terminal frontend - can be called directly from unified CLI.
pub fn run(terminal_args: TerminalArgs) !void {
    const allocator = std.heap.page_allocator;

    // Handle --notify: send to parent terminal frontend and exit.
    if (terminal_args.notify_message) |msg| {
        sendNotifyToParentTerminal(allocator, terminal_args.connect_options, msg);
        return;
    }

    // Handle --list: show detached sessions and orphaned panes.
    if (terminal_args.list) {
        var runtime = try FrontendRuntime.createTerminalProbe(allocator, terminal_args.log_level, terminal_args.log_file, terminal_args.connect_options);
        defer runtime.destroy();
        runtime.connect() catch {
            std.debug.print("Could not connect to ses daemon\n", .{});
            return;
        };

        // List detached sessions.
        var sessions: [16]DetachedSessionInfo = undefined;
        var list_failed = false;
        const sess_count = runtime.listSessions(&sessions) catch |err| blk: {
            list_failed = true;
            core.logging.logError("terminal", "failed to list detached sessions", err);
            std.debug.print("Warning: failed to list detached sessions: {s}\n", .{@errorName(err)});
            break :blk 0;
        };
        if (sess_count > 0) {
            std.debug.print("Sessions (attach by name or UUID prefix; attached ones are stolen):\n", .{});
            const instance = std.posix.getenv("HEXE_INSTANCE");
            for (sessions[0..sess_count]) |s| {
                const name = s.session_name[0..s.session_name_len];
                const base_root = s.base_root[0..s.base_root_len];
                const uuid_prefix = s.session_id[0..8];
                const state_mark: []const u8 = if (s.attached) " [attached]" else "";
                if (instance) |inst| {
                    if (inst.len > 0) {
                        std.debug.print("  [{s}] {s:<12} ({d} tabs) {s}{s}\n", .{ uuid_prefix, name, s.pane_count, base_root, state_mark });
                        std.debug.print("    → hexe terminal attach --instance {s} {s}\n", .{ inst, uuid_prefix });
                    } else {
                        std.debug.print("  [{s}] {s:<12} ({d} tabs) {s}{s}\n", .{ uuid_prefix, name, s.pane_count, base_root, state_mark });
                        std.debug.print("    → hexe terminal attach {s}\n", .{uuid_prefix});
                    }
                } else {
                    std.debug.print("  [{s}] {s:<12} ({d} tabs) {s}{s}\n", .{ uuid_prefix, name, s.pane_count, base_root, state_mark });
                    std.debug.print("    → hexe terminal attach {s}\n", .{uuid_prefix});
                }
            }
        }

        // List orphaned panes.
        var tabs: [32]OrphanedPaneInfo = undefined;
        const orphan_count = runtime.listOrphanedPanes(&tabs) catch |err| blk: {
            list_failed = true;
            core.logging.logError("terminal", "failed to list orphaned panes", err);
            std.debug.print("Warning: failed to list orphaned panes: {s}\n", .{@errorName(err)});
            break :blk 0;
        };
        if (orphan_count > 0) {
            std.debug.print("Orphaned panes (disowned):\n", .{});
            for (tabs[0..orphan_count]) |p| {
                const name = if (p.name_len > 0) p.nameSlice() else "-";
                std.debug.print("  [{s}] {s} pid={d}\n", .{ p.uuid[0..8], name, p.pid });
            }
        }

        if (!list_failed and sess_count == 0 and orphan_count == 0) {
            std.debug.print("No detached sessions or orphaned panes\n", .{});
        }
        return;
    }

    // Handle --attach: attach to detached session by name or UUID prefix.
    if (terminal_args.attach) |uuid_arg| {
        if (uuid_arg.len < 3 and !std.mem.eql(u8, uuid_arg, ".")) {
            std.debug.print("Session name/UUID too short (need at least 3 chars)\n", .{});
            return;
        }
        // Will be handled after state init.
    }

    // Ignore SIGPIPE so writes to disconnected pod sockets return EPIPE
    // instead of killing the terminal frontend process.
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
    // When --log is set without --logfile, default to instance-specific log.
    var default_log_path: ?[]const u8 = null;
    defer if (default_log_path) |p| allocator.free(p);

    const effective_log: ?[]const u8 = if (terminal_args.log_file) |p|
        (if (p.len > 0) p else null)
    else if (terminal_args.log_level != null) blk: {
        default_log_path = core.ipc.getLogPath(allocator) catch |err| path_blk: {
            core.logging.logError("terminal", "failed to allocate default terminal log path", err);
            break :path_blk null;
        };
        break :blk default_log_path;
    } else null;
    redirectStderr(effective_log);
    debug_enabled = core.logging.levelEnablesDebug(terminal_args.log_level);
    core.logging.setLogLevel(terminal_args.log_level);
    debugLog("started", .{});
    debugLog("level={s} logfile={s}", .{
        if (terminal_args.log_level) |level| @tagName(level) else "off",
        effective_log orelse "(none)",
    });

    // Get terminal size.
    const size = terminal.getTermSize();

    // Initialize state.
    var state = try State.init(
        allocator,
        size.cols,
        size.rows,
        terminal_args.log_level,
        effective_log,
        terminal_args.connect_options,
    );
    defer {
        statusbar.deinitThreadlocals();
        state.deinit();
    }

    // Register state for signal handlers.
    global_state.store(&state, .release);
    state.registerSharedVtQueue();
    defer global_state.store(null, .release);

    // Show notification for config status.
    switch (state.config.status) {
        .missing => state.notifications.showFor("Config not found (~/.config/hexe/init.lua), using defaults", 5000),
        .@"error" => {
            if (state.config.status_message) |msg| {
                const err_msg = std.fmt.allocPrint(allocator, "Config error: {s}", .{msg}) catch |err| err_blk: {
                    core.logging.logError("terminal", "failed to allocate config error notification", err);
                    break :err_blk null;
                };
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
    if (terminal_args.name) |custom_name| {
        _ = state.runtime.setSessionName(custom_name);
    }

    // Keep the legacy env var for shell integrations.
    _ = c.setenv("HEXE_MUX_SOCKET", "1", 1);

    // Connect to ses daemon FIRST (start it if needed).
    var startup_attach = state.runtime.attachFrontend() catch |e| {
        debugLog("ses connect failed: {s}", .{@errorName(e)});
        std.debug.print("Could not connect to ses daemon: {s}\n", .{@errorName(e)});
        return;
    };
    defer startup_attach.deinit(allocator);
    debugLog("ses connected (started={})", .{startup_attach.started_daemon});

    // If server resolved to a different name (collision avoidance), update state.
    if (startup_attach.name_change) |*change| {
        debugLog("session name resolved from '{s}' to '{s}'", .{ change.previous_name, change.resolved_name });
        notifySessionNameChange(&state, change);
    }

    // Show notification if we just started the daemon.
    if (startup_attach.started_daemon) {
        state.notifications.showFor("ses daemon started", 2000);
    }

    // Export session ID so child panes can identify their parent terminal session.
    // Must happen BEFORE createTab/reattach which fork pane shells.
    var session_id_z: [33]u8 = undefined;
    const session_uuid = state.runtime.sessionUuid();
    @memcpy(session_id_z[0..32], &session_uuid);
    session_id_z[32] = 0;
    _ = c.setenv("HEXE_SESSION", &session_id_z, 1);

    var restored_existing_target = false;

    // Handle --attach: try session first, then orphaned pane. The whole
    // resolve+attach is retried a few times: the daemon's session state is
    // in flux around kills, steals, and parks (a session can move between
    // attached/detached, or a concurrent attach may hold the commit lock),
    // and a single-shot attempt turned those transient windows into flaky
    // "sometimes it doesn't attach" failures. Each retry re-resolves from a
    // FRESH session list.
    if (terminal_args.attach) |uuid_prefix| {
        var attach_attempt: usize = 0;
        attach_retry: while (true) : (attach_attempt += 1) {
            if (attach_attempt > 0) std.Thread.sleep(600 * std.time.ns_per_ms);
            const last_try = attach_attempt + 1 >= 4;
            var resolved_attach = resolveDotAttachTarget(allocator, state.runtime, uuid_prefix) catch |err| {
                debugLog("attach: failed to resolve target {s}: {s} (attempt {d})", .{ uuid_prefix, @errorName(err), attach_attempt + 1 });
                if (err == error.SessionNotFound and !last_try) continue :attach_retry;
                if (err == error.InvalidSelection) {
                    ttyPrint("Invalid selection\n", .{});
                }
                return;
            };
            defer resolved_attach.deinit(allocator);

            debugLog("attach: trying to reattach with prefix={s}", .{resolved_attach.target});
            if (state.reattachSession(resolved_attach.target)) {
                debugLog("attach: reattachSession succeeded", .{});
                state.notifications.show("Session reattached");
                restored_existing_target = true;
                // Reattach may change state.uuid — update env for subsequent panes.
                const reattached_uuid = state.runtime.sessionUuid();
                @memcpy(session_id_z[0..32], &reattached_uuid);
                _ = c.setenv("HEXE_SESSION", &session_id_z, 1);
            } else if (state.attachOrphanedPane(resolved_attach.target)) {
                debugLog("attach: attachOrphanedPane succeeded", .{});
                state.notifications.show("Attached to orphaned pane");
                restored_existing_target = true;
            } else {
                debugLog("attach: both reattach methods failed (attempt {d})", .{attach_attempt + 1});
                if (!last_try) continue :attach_retry;
                // Session/pane not found - EXIT with error, don't create new session
                ttyPrint("Session or pane '{s}' not found\n", .{resolved_attach.target});
                ttyPrint("Use 'hexe terminal list' to see available sessions\n", .{});
                return; // Exit without entering main loop
            }
            break :attach_retry;
        }
    } else if (terminal_args.session_config_path) |config_path| {
        // Launch from session config (.hexe.lua)
        debugLog("applying session config from: {s}", .{config_path});
        const session_config = core.session_config;
        var applied_canonical_layout = false;
        var legacy_config: ?core.SessionConfig = null;
        // Single-execution parse: the old canonical-then-legacy fallback ran
        // the .hexe.lua file twice, so its Lua side effects fired twice.
        if (terminal_args.session_tab_filter == null) {
            if (session_config.parseSessionLuaOnce(allocator, config_path)) |parsed| switch (parsed) {
                .layout => |layout_value| {
                    var layout = layout_value;
                    defer layout.deinit(allocator);

                    if (state.runtime.setSessionName(layout.name)) {
                        const identity_change = state.runtime.syncSessionIdentity() catch |err| blk: {
                            core.logging.logError("terminal", "startup: failed to sync layout session identity", err);
                            break :blk null;
                        };
                        if (identity_change) |change| {
                            var owned_change = change;
                            defer owned_change.deinit(allocator);
                        }
                    }

                    state.applyLayoutDef(&layout) catch |err| {
                        debugLog("applyLayoutDef from session config failed: {s}", .{@errorName(err)});
                        std.debug.print("Error applying session layout: {s}\n", .{@errorName(err)});
                        try state.createTab();
                    };
                    applied_canonical_layout = true;
                },
                .legacy => |cfg| legacy_config = cfg,
            } else |err| {
                debugLog("parseSessionLuaOnce failed: {s}", .{@errorName(err)});
            }
        }
        if (!applied_canonical_layout) {
            var config = legacy_config orelse session_config.parseSessionLua(allocator, config_path) catch |err| {
                if (err == error.FileNotFound) {
                    std.debug.print("Session config not found: {s}\n", .{config_path});
                } else {
                    std.debug.print("Error parsing session config: {s}\n", .{@errorName(err)});
                }
                // Fall back to default tab
                try state.createTab();
                state.adoptStickyPanes();
                try terminal_host.run(&state);
                return;
            };
            defer config.deinit(allocator);

            // Prefer layout-config name when provided.
            if (config.name) |loaded_name| {
                if (state.runtime.setSessionName(loaded_name)) {
                    const identity_change = state.runtime.syncSessionIdentity() catch |err| blk: {
                        core.logging.logError("terminal", "startup: failed to sync layout-config session identity", err);
                        break :blk null;
                    };
                    if (identity_change) |change| {
                        var owned_change = change;
                        defer owned_change.deinit(allocator);
                    }
                }
            }

            state.applySessionConfig(config, terminal_args.session_tab_filter) catch |err| {
                debugLog("applySessionConfig failed: {s}", .{@errorName(err)});
                std.debug.print("Error applying session config: {s}\n", .{@errorName(err)});
                // Fall back to default tab
                try state.createTab();
            };
        }
    } else if (terminal_args.startup_chooser) {
        // Bare `hexe`: ask before committing to anything. No tab is created
        // here — the popup answer decides. See startup_chooser.zig.
        startup_chooser.begin(&state);
    } else {
        // Apply the enabled SES layout on normal startup when present.
        var applied_layout = false;
        for (state.ses_config.layouts) |*layout| {
            if (!layout.enabled) continue;
            state.applyLayoutDef(layout) catch |err| {
                debugLog("applyLayoutDef failed: {s}", .{@errorName(err)});
                std.debug.print("Error applying configured layout '{s}': {s}\n", .{ layout.name, @errorName(err) });
            };
            applied_layout = true;
            break;
        }

        if (!applied_layout) {
            // No configured layout; create a single default tab.
            try state.createTab();
        }
    }

    // Auto-adopt sticky panes only for new sessions. Explicit attach must be
    // exact: if the detached session listed four floats, the attached session
    // must not opportunistically pull in unrelated free sticky floats from the
    // same CWD.
    // The startup chooser has no panes to adopt into yet; it adopts itself
    // once the user has answered.
    if (!restored_existing_target and !state.startup_choice_pending) {
        state.adoptStickyPanes();
    }

    // Continue with main loop.
    try terminal_host.run(&state);
}

/// Export HEXE_SESSION for child panes. Reattach can change the session
/// uuid, so this must be re-run after any identity change (startup and the
/// loop's auto-reconnect both use it).
pub fn exportSessionEnv(session_uuid: [32]u8) void {
    var session_id_z: [33]u8 = undefined;
    @memcpy(session_id_z[0..32], &session_uuid);
    session_id_z[32] = 0;
    _ = c.setenv("HEXE_SESSION", &session_id_z, 1);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var terminal_args = TerminalArgs{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if ((std.mem.eql(u8, arg, "--notify") or std.mem.eql(u8, arg, "-n")) and i + 1 < args.len) {
            i += 1;
            terminal_args.notify_message = args[i];
        } else if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            terminal_args.list = true;
        } else if ((std.mem.eql(u8, arg, "--attach") or std.mem.eql(u8, arg, "-a")) and i + 1 < args.len) {
            i += 1;
            terminal_args.attach = args[i];
        } else if ((std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "-N")) and i + 1 < args.len) {
            i += 1;
            terminal_args.name = args[i];
        } else if (std.mem.eql(u8, arg, "--log")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --log requires a level (trace|debug|info)\n", .{});
                return;
            }
            i += 1;
            const parsed = core.logging.parseLevel(args[i]) orelse {
                std.debug.print("Error: invalid --log level '{s}' (use trace|debug|info)\n", .{args[i]});
                return;
            };
            if (parsed != .trace and parsed != .debug and parsed != .info) {
                std.debug.print("Error: invalid --log level '{s}' (use trace|debug|info)\n", .{args[i]});
                return;
            }
            terminal_args.log_level = parsed;
        } else if ((std.mem.eql(u8, arg, "--logfile") or std.mem.eql(u8, arg, "-L")) and i + 1 < args.len) {
            i += 1;
            terminal_args.log_file = args[i];
        } else if (std.mem.eql(u8, arg, "--no-autostart-ses")) {
            terminal_args.connect_options.autostart_ses = false;
        } else if (std.mem.eql(u8, arg, "--ses-socket") and i + 1 < args.len) {
            i += 1;
            terminal_args.connect_options.socket_path = args[i];
        }
    }

    try run(terminal_args);
}

fn redirectStderr(log_file: ?[]const u8) void {
    var redirected = false;
    if (log_file) |path| {
        if (path.len > 0) {
            const logfd = posix.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644) catch |err| fd_blk: {
                core.logging.logError("terminal", "failed to open terminal log file", err);
                break :fd_blk null;
            };
            if (logfd) |fd| {
                posix.dup2(fd, posix.STDERR_FILENO) catch |err| {
                    core.logging.logError("terminal", "failed to dup2 stderr for logging", err);
                };
                if (fd > 2) posix.close(fd);
                redirected = true;
            }
        }
    }

    if (redirected) return;

    const devnull = std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only }) catch |err| {
        core.logging.logError("terminal", "failed to open /dev/null for stderr redirection", err);
        return;
    };
    posix.dup2(devnull.handle, posix.STDERR_FILENO) catch |err| {
        core.logging.logError("terminal", "failed to redirect stderr to /dev/null", err);
    };
    devnull.close();
}

fn sendNotifyToParentTerminal(allocator: std.mem.Allocator, connect_options: FrontendConnectOptions, message: []const u8) void {
    core.FrontendTransportHelpers.sendNotifyWithConnectOptions(allocator, connect_options, message) catch |err| {
        core.logging.logError("terminal", "failed to send notify message to parent", err);
    };
}
