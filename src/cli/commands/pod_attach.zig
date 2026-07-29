const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const wire = core.wire;
const pod_protocol = core.pod_protocol;
const AsciicastWriter = core.recording.asciicast.AsciicastWriter;
const xev = @import("xev").Dynamic;
const tty = @import("tty.zig");
const shared = @import("shared.zig");

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
    running: bool = true,
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
                _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch 0;
                c.running = false;
                return .disarm;
            }
            var tmp: [2]u8 = .{ c.detach_code, c.in_buf[0] };
            sendAuxInput(c.socket_path, tmp[0..2]) catch |err| {
                core.logging.logError("pod_attach", "failed to send detach-prefix input", err);
                c.running = false;
                return .disarm;
            };
            if (c.capture_input) {
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
    if (c.capture_input) {
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
    const target_socket = try resolveTargetSocket(allocator, uuid, name, socket_path);
    defer allocator.free(target_socket);

    var client = ipc.Client.connect(target_socket) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            print("pod is not running\n", .{});
            return;
        }
        return err;
    };
    defer client.close();

    // Observer, NOT the authoritative VT client — see sendAuxFrame above.
    wire.sendHandshake(client.fd, wire.POD_HANDSHAKE_AUX_OBSERVER) catch |err| {
        print("Error: failed to handshake with pod: {s}\n", .{@errorName(err)});
        return;
    };

    var conn = client.toConnection();

    // Enter raw mode on stdin so we can proxy bytes.
    const orig_termios = tty.enableRawMode(std.posix.STDIN_FILENO) catch null;
    defer if (orig_termios) |t| tty.disableRawMode(std.posix.STDIN_FILENO, t) catch |err| {
        core.logging.logError("pod_attach", "failed to restore terminal mode", err);
    };

    // Initial resize.
    const term_size = tty.getTermSize();
    sendResize(target_socket, term_size) catch |err| {
        print("Warning: failed to send initial resize: {s}\n", .{@errorName(err)});
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

    // Detach sequence (tmux-ish): prefix Ctrl+<key> (default b), then 'd'.
    const det = if (detach_key.len == 1) detach_key[0] else 'b';
    const det_code: u8 = if (det >= 'a' and det <= 'z') det - 'a' + 1 else if (det >= 'A' and det <= 'Z') det - 'A' + 1 else 0x02;

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
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], size.cols, .big);
    std.mem.writeInt(u16, payload[2..4], size.rows, .big);
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
        else => {},
    }
}

fn resolveTargetSocket(allocator: std.mem.Allocator, uuid: []const u8, name: []const u8, socket_path: []const u8) ![]const u8 {
    return shared.resolvePodSocketTarget(allocator, uuid, name, socket_path) catch |err| {
        switch (err) {
            error.InvalidUuid => print("Error: --uuid must be 32 hex chars\n", .{}),
            error.MissingTarget => print("Error: must provide --socket, --uuid, or --name\n", .{}),
            else => {},
        }
        return err;
    };
}
