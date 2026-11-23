const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const wire = core.wire;
const pod_protocol = core.pod_protocol;
const AsciicastWriter = core.recording.asciicast.AsciicastWriter;
const xev = @import("xev").Dynamic;
const tty = @import("tty.zig");
const shared = @import("shared.zig");
const pod_list = @import("pod_list.zig");
const terminal = @import("terminal");

const print = std.debug.print;

/// `hexe pod attach` must NOT displace the pane's real VT client.
///
/// It used to handshake as POD_HANDSHAKE_SES_VT, which made it the pod's
/// authoritative client — and `acceptVtClient` unconditionally closes the
/// existing one. Running it against a live pane therefore evicted SES, which
/// re-dialled, which evicted the attach client, and so on: a flap with a full
/// backlog replay every cycle (PLAN.md C-1).
///
/// Now the two directions use the pod's existing non-authoritative channels:
///
///   - OUTPUT: one persistent POD_HANDSHAKE_AUX_OBSERVER connection. Observers
///     receive the backlog replay and every subsequent output frame in exactly
///     the pod_protocol framing this command already parses, and attaching one
///     never touches `Pod.client`.
///   - INPUT: a short-lived POD_HANDSHAKE_AUX_INPUT connection per burst. That
///     channel writes straight to the PTY without becoming the client.
///
/// Aux input bypasses `applyInputFrame`, so it takes the RAW payload — the
/// 16-byte `[epoch:u64][seq:u64]` prefix that path requires must not be sent
/// here. (Adding that prefix was the fix for the other half of C-1, back when
/// this command still spoke on the authoritative channel.)
fn sendAuxFrame(socket_path: []const u8, frame_type: pod_protocol.FrameType, payload: []const u8) !void {
    var client = try ipc.Client.connect(socket_path);
    defer client.close();
    try wire.sendHandshake(client.fd, wire.POD_HANDSHAKE_AUX_INPUT);
    var conn = client.toConnection();
    try pod_protocol.writeFrame(&conn, frame_type, payload);
}

fn sendAuxInput(socket_path: []const u8, payload: []const u8) !void {
    try sendAuxFrame(socket_path, .input, payload);
}

const AttachContext = struct {
    conn: *ipc.Connection,
    socket_path: []const u8,
    frame_reader: *pod_protocol.Reader,
    recorder: ?*AsciicastWriter,
    capture_input: bool,
    detach_code: u8,
    saw_prefix: bool = false,
    detached_by_user: bool = false,
    running: bool = true,
    password_mode: bool = false,
    net_buf: [4096]u8 = undefined,
    in_buf: [4096]u8 = undefined,
};

fn stdinCallback(
    ctx: ?*AttachContext,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.File,
    result: xev.PollError!xev.PollEvent,
) xev.CallbackAction {
    const c = ctx orelse return .disarm;
    _ = result catch |err| {
        core.logging.logError("pod_attach", "stdin poll failed", err);
        c.running = false;
        return .disarm;
    };

    const n = std.posix.read(std.posix.STDIN_FILENO, &c.in_buf) catch |err| {
        core.logging.logError("pod_attach", "stdin read failed", err);
        c.running = false;
        return .disarm;
    };
    if (n == 0) {
        c.running = false;
        return .disarm;
    }

    if (n == 1) {
        if (c.saw_prefix) {
            c.saw_prefix = false;
            if (c.in_buf[0] == 'd' or c.in_buf[0] == 'D') {
                c.detached_by_user = true;
                c.running = false;
                return .disarm;
            }
            var tmp: [2]u8 = .{ c.detach_code, c.in_buf[0] };
            sendAuxInput(c.socket_path, tmp[0..2]) catch |err| {
                core.logging.logError("pod_attach", "failed to send detach-prefix input", err);
                c.running = false;
                return .disarm;
            };
            if (c.capture_input and !c.password_mode) {
                if (c.recorder) |r| {
                    r.writeInput(tmp[0..2]) catch |err| {
                        core.logging.logError("pod_attach", "failed to record detach-prefix input", err);
                    };
                }
            }
            return .rearm;
        }
        if (c.in_buf[0] == c.detach_code) {
            c.saw_prefix = true;
            return .rearm;
        }
    }

    sendAuxInput(c.socket_path, c.in_buf[0..n]) catch |err| {
        core.logging.logError("pod_attach", "failed to send input", err);
        c.running = false;
        return .disarm;
    };
    if (c.capture_input and !c.password_mode) {
        if (c.recorder) |r| {
            r.writeInput(c.in_buf[0..n]) catch |err| {
                core.logging.logError("pod_attach", "failed to record input", err);
            };
        }
    }
    return .rearm;
}

fn connCallback(
    ctx: ?*AttachContext,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.File,
    result: xev.PollError!xev.PollEvent,
) xev.CallbackAction {
    const c = ctx orelse return .disarm;
    _ = result catch |err| {
        core.logging.logError("pod_attach", "connection poll failed", err);
        c.running = false;
        return .disarm;
    };

    const n = std.posix.read(c.conn.fd, &c.net_buf) catch |err| switch (err) {
        error.WouldBlock => 0,
        else => {
            core.logging.logError("pod_attach", "pod connection read failed", err);
            c.running = false;
            return .disarm;
        },
    };
    if (n == 0) {
        c.running = false;
        return .disarm;
    }

    c.frame_reader.feed(c.net_buf[0..n], @ptrCast(@alignCast(c)), podFrameCallback);
    return .rearm;
}

const ResizeContext = struct {
    conn: *ipc.Connection,
    socket_path: []const u8,
    pipe_fd: std.posix.fd_t,
    net_buf: [4096]u8 = undefined,
};

fn resizeCallback(
    ctx: ?*ResizeContext,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.File,
    result: xev.PollError!xev.PollEvent,
) xev.CallbackAction {
    const c = ctx orelse return .disarm;
    _ = result catch |err| {
        core.logging.logError("pod_attach", "resize pipe poll failed", err);
        return .disarm;
    };
    _ = std.posix.read(c.pipe_fd, &c.net_buf) catch |err| {
        core.logging.logError("pod_attach", "resize pipe read failed", err);
        return .disarm;
    };
    sendResize(c.socket_path, tty.getTermSize()) catch |err| {
        core.logging.logError("pod_attach", "failed to send resize after SIGWINCH", err);
    };
    return .rearm;
}

pub fn runPodAttach(
    allocator: std.mem.Allocator,
    uuid: []const u8,
    name: []const u8,
    socket_path: []const u8,
    detach_key: []const u8,
    record_path: []const u8,
    capture_input: bool,
) !void {
    var picked_uuid_buf: [32]u8 = undefined;
    var picked_name_owned: ?[]u8 = null;
    defer if (picked_name_owned) |n| allocator.free(n);

    var eff_uuid = uuid;
    var eff_name = name;

    if (uuid.len == 0 and name.len == 0 and socket_path.len == 0) {
        if (std.posix.isatty(std.posix.STDIN_FILENO) and std.posix.isatty(std.posix.STDOUT_FILENO)) {
            if (try pickPodInteractively(allocator, &picked_uuid_buf, &picked_name_owned)) {
                eff_uuid = picked_uuid_buf[0..];
                if (picked_name_owned) |pn| eff_name = pn;
            } else {
                return;
            }
        }
    }

    const target_socket = try resolveTargetSocket(allocator, eff_uuid, eff_name, socket_path);
    defer allocator.free(target_socket);

    var client = ipc.Client.connect(target_socket) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            core.cli_ui.printErr("pod is not running", .{});
            std.process.exit(1);
        }
        return err;
    };
    defer client.close();

    // Observer, NOT the authoritative VT client — see sendAuxFrame above.
    wire.sendHandshake(client.fd, wire.POD_HANDSHAKE_AUX_OBSERVER) catch |err| {
        core.cli_ui.printErr("failed to handshake with pod: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    var conn = client.toConnection();

    // Detach sequence (tmux-ish): prefix Ctrl+<key> (default b), then 'd'.
    const det = if (detach_key.len == 1) detach_key[0] else 'b';
    const det_code: u8 = if (det >= 'a' and det <= 'z') det - 'a' + 1 else if (det >= 'A' and det <= 'Z') det - 'A' + 1 else 0x02;

    // Enter raw mode on stdin so we can proxy bytes.
    const orig_termios = tty.enableRawMode(std.posix.STDIN_FILENO) catch null;
    var raw_restored = false;
    defer if (!raw_restored) {
        if (orig_termios) |t| tty.disableRawMode(std.posix.STDIN_FILENO, t) catch |err| {
            core.logging.logError("pod_attach", "failed to restore terminal mode", err);
        };
    };

    // Initial resize.
    const term_size = tty.getTermSize();
    sendResize(target_socket, term_size) catch |err| {
        core.cli_ui.printWarn("failed to send initial resize: {s}", .{@errorName(err)});
    };

    var recorder: ?AsciicastWriter = null;
    if (record_path.len > 0) {
        recorder = try AsciicastWriter.init(record_path, .{
            .width = term_size.cols,
            .height = term_size.rows,
            .title = "hexe pod attach",
            .command = "hexe pod attach",
        });
    }
    defer {
        if (recorder) |*r| {
            r.flush() catch |err| {
                core.logging.logError("pod_attach", "failed to flush recording", err);
            };
            r.deinit();
        }
    }

    // Winch handling via a self-pipe.
    var pipe_fds: [2]std.posix.fd_t = .{ -1, -1 };
    if (std.posix.pipe() catch null) |fds| {
        pipe_fds = fds;
    }
    defer {
        if (pipe_fds[0] >= 0) std.posix.close(pipe_fds[0]);
        if (pipe_fds[1] >= 0) std.posix.close(pipe_fds[1]);
    }

    const builtin = @import("builtin");
    if (pipe_fds[1] >= 0 and builtin.os.tag == .linux) {
        const c = @cImport({
            @cInclude("signal.h");
            @cInclude("unistd.h");
        });
        // Global-ish through a comptime static.
        WinchPipe.write_fd = pipe_fds[1];
        _ = c.signal(c.SIGWINCH, winchHandler);
    }

    var frame_reader = try pod_protocol.Reader.init(allocator, pod_protocol.MAX_FRAME_LEN);
    defer frame_reader.deinit(allocator);

    try xev.detect();
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var attach_ctx = AttachContext{
        .conn = &conn,
        .socket_path = target_socket,
        .frame_reader = &frame_reader,
        .recorder = if (recorder) |*r| r else null,
        .capture_input = capture_input,
        .detach_code = det_code,
    };

    var stdin_completion: xev.Completion = .{};
    var conn_completion: xev.Completion = .{};
    const stdin_watcher = xev.File.initFd(std.posix.STDIN_FILENO);
    const conn_watcher = xev.File.initFd(conn.fd);
    stdin_watcher.poll(&loop, &stdin_completion, .read, AttachContext, &attach_ctx, stdinCallback);
    conn_watcher.poll(&loop, &conn_completion, .read, AttachContext, &attach_ctx, connCallback);

    var resize_completion: xev.Completion = .{};
    var resize_ctx: ResizeContext = undefined;
    if (pipe_fds[0] >= 0) {
        resize_ctx = .{ .conn = &conn, .socket_path = target_socket, .pipe_fd = pipe_fds[0] };
        const resize_watcher = xev.File.initFd(pipe_fds[0]);
        resize_watcher.poll(&loop, &resize_completion, .read, ResizeContext, &resize_ctx, resizeCallback);
    }

    while (attach_ctx.running) {
        try loop.run(.once);
    }

    // Restore cooked mode before printing the detach summary.
    if (orig_termios) |t| {
        tty.disableRawMode(std.posix.STDIN_FILENO, t) catch {};
        raw_restored = true;
    }

    if (attach_ctx.detached_by_user) {
        var label_buf: [160]u8 = undefined;
        var hint_buf: [256]u8 = undefined;
        const label = if (eff_name.len > 0 and eff_uuid.len >= 8)
            std.fmt.bufPrint(&label_buf, "{s} [{s}]", .{ eff_name, eff_uuid[0..8] }) catch eff_name
        else if (eff_name.len > 0)
            eff_name
        else if (eff_uuid.len >= 8)
            eff_uuid[0..8]
        else
            target_socket;

        const hint = if (eff_uuid.len == 32)
            std.fmt.bufPrint(&hint_buf, "hexe pod attach --uuid {s}", .{eff_uuid}) catch "hexe pod attach"
        else if (eff_name.len > 0)
            std.fmt.bufPrint(&hint_buf, "hexe pod attach --name {s}", .{eff_name}) catch "hexe pod attach"
        else
            std.fmt.bufPrint(&hint_buf, "hexe pod attach --socket {s}", .{target_socket}) catch "hexe pod attach";

        const color = core.cli_ui.useColor(std.posix.STDERR_FILENO);
        if (core.cli_ui.formatPodDetachBanner(allocator, color, label, hint)) |banner| {
            defer allocator.free(banner);
            _ = std.posix.write(std.posix.STDERR_FILENO, banner) catch 0;
        } else |_| {}
    }
}

fn pickPodInteractively(
    allocator: std.mem.Allocator,
    out_uuid: *[32]u8,
    out_name: *?[]u8,
) !bool {
    const dir = try ipc.getSocketDir(allocator);
    defer allocator.free(dir);

    var records = std.ArrayList(pod_list.PodRecord).empty;
    defer {
        for (records.items) |r| pod_list.freeRecord(allocator, r);
        records.deinit(allocator);
    }

    pod_list.scanMetaFiles(allocator, dir, &records) catch {};

    // Filter to live pods only.
    var live = std.ArrayList(pod_list.PodRecord).empty;
    defer live.deinit(allocator);
    for (records.items) |rec| {
        const sock = ipc.getPodSocketPath(allocator, &rec.uuid) catch continue;
        defer allocator.free(sock);
        if (ipc.Client.connect(sock)) |conn_val| {
            var c = conn_val;
            c.close();
            try live.append(allocator, rec);
        } else |_| {}
    }

    if (live.items.len == 0) {
        const p = core.cli_ui.Palette.forStderr();
        print("{s}○{s} No running pods found\n  {s}Create one:{s}  {s}hexe pod new{s}\n", .{
            p.warn, p.reset, p.dim, p.reset, p.accent, p.reset,
        });
        return false;
    }

    var labels = try allocator.alloc([]const u8, live.items.len);
    var labels_built: usize = 0;
    defer {
        for (labels[0..labels_built]) |l| allocator.free(l);
        allocator.free(labels);
    }

    var badges = try allocator.alloc([]const u8, live.items.len);
    var badges_built: usize = 0;
    defer {
        for (badges[0..badges_built]) |b| allocator.free(b);
        allocator.free(badges);
    }

    var details = try allocator.alloc([]const u8, live.items.len);
    var details_built: usize = 0;
    defer {
        for (details[0..details_built]) |d| allocator.free(d);
        allocator.free(details);
    }

    for (live.items, 0..) |rec, i| {
        labels[i] = try std.fmt.allocPrint(allocator, "{s:<14} [{s}]", .{ rec.name, rec.uuid[0..8] });
        labels_built = i + 1;
        badges[i] = try std.fmt.allocPrint(allocator, "pid {d}", .{rec.child_pid});
        badges_built = i + 1;
        var home_buf: [256]u8 = undefined;
        const cwd_disp = core.cli_ui.compactHome(rec.cwd, &home_buf);
        details[i] = try std.fmt.allocPrint(allocator, "cwd: {s}{s}{s}", .{
            cwd_disp,
            if (rec.shell.len > 0) " · " else "",
            rec.shell,
        });
        details_built = i + 1;
    }

    const chosen = try terminal.runStandalonePicker(allocator, labels, .{
        .title = "Attach to pod",
        .badges = badges,
        .details = details,
        .hint = "↑↓/jk move · / filter · Enter attach · Ctrl+B d detaches · Esc cancel",
        .filterable = true,
    });
    const idx = chosen orelse return false;
    out_uuid.* = live.items[idx].uuid;
    if (live.items[idx].name.len > 0 and !std.mem.eql(u8, live.items[idx].name, "-")) {
        out_name.* = try allocator.dupe(u8, live.items[idx].name);
    }
    return true;
}

const WinchPipe = struct {
    pub var write_fd: std.posix.fd_t = -1;
};

fn winchHandler(_: i32) callconv(.c) void {
    if (WinchPipe.write_fd < 0) return;
    const c = @cImport({
        @cInclude("unistd.h");
    });
    var b: [1]u8 = .{0};
    _ = c.write(WinchPipe.write_fd, &b, 1);
}

fn sendResize(socket_path: []const u8, size: tty.TermSize) !void {
    // The cell size goes with it so the pod's pty can report a pixel geometry.
    // A terminal that reports none sends zeroes, which the pod reads as
    // "unknown" and leaves the pty's pixel fields alone.
    var payload: [8]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], size.cols, .big);
    std.mem.writeInt(u16, payload[2..4], size.rows, .big);
    std.mem.writeInt(u16, payload[4..6], size.cell_w, .big);
    std.mem.writeInt(u16, payload[6..8], size.cell_h, .big);
    try sendAuxFrame(socket_path, .resize, &payload);
}

fn podFrameCallback(ctx: *anyopaque, frame: pod_protocol.Frame) void {
    const attach: *AttachContext = @ptrCast(@alignCast(ctx));
    switch (frame.frame_type) {
        .output => {
            _ = std.posix.write(std.posix.STDOUT_FILENO, frame.payload) catch |err| {
                core.logging.logError("pod_attach", "failed to write pod output to stdout", err);
                attach.running = false;
                return;
            };
            if (attach.recorder) |r| {
                r.writeOutput(frame.payload) catch |err| {
                    core.logging.logError("pod_attach", "failed to record pod output", err);
                };
            }
        },
        .backlog_end => {},
        .password_mode => {
            if (frame.payload.len >= 1) attach.password_mode = frame.payload[0] != 0;
        },
        else => {},
    }
}

fn resolveTargetSocket(allocator: std.mem.Allocator, uuid: []const u8, name: []const u8, socket_path: []const u8) ![]const u8 {
    return shared.resolvePodSocketTarget(allocator, uuid, name, socket_path) catch |err| {
        switch (err) {
            error.InvalidUuid => core.cli_ui.printErr("--uuid must be 32 hex chars", .{}),
            error.MissingTarget => core.cli_ui.printErr("must provide --socket, --uuid, or --name", .{}),
            // Pane names are unique per session, so one name can belong to
            // two panes in two sessions. Picking either could type into, or
            // signal, the wrong one.
            error.AmbiguousPodName => core.cli_ui.printErr("several pods are called that; use --uuid", .{}),
            else => {},
        }
        return err;
    };
}
