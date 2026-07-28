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

/// mux->pod INPUT frames carry a 16-byte `[epoch:u64][seq:u64]` little-endian
/// prefix (see frontends/terminal/vt_write_queue.zig and Pod.applyInputFrame),
/// which the pod strips before writing to the PTY. `hexe pod attach`
/// handshakes as POD_HANDSHAKE_SES_VT, so it IS the authoritative VT client and
/// its frames go through that dedup path — but it was sending raw stdin bytes.
/// A single keystroke is 1 byte, fails the `payload.len >= 16` check, and was
/// dropped: every key, arrow and Ctrl-C silently vanished. A >=16-byte burst
/// was worse, its first 16 bytes being consumed as a bogus (epoch, seq) that
/// then poisoned the pod's dedup state for the next real client.
const INPUT_SEQ_PREFIX_LEN: usize = 16;

/// Distinct per attach process so the pod's dedup treats us as a new client
/// (a different epoch is adopted rather than compared against a stale seq).
var input_epoch: u64 = 0;
var input_seq: u64 = 0;

fn inputEpoch() u64 {
    if (input_epoch == 0) {
        const pid: u64 = @intCast(std.os.linux.getpid());
        const now: u64 = @bitCast(std.time.milliTimestamp());
        input_epoch = (now << 16) ^ pid;
        if (input_epoch == 0) input_epoch = 1;
    }
    return input_epoch;
}

/// Send an INPUT frame with the (epoch, seq) prefix the pod requires.
fn writeInputFrame(conn: *ipc.Connection, payload: []const u8) !void {
    var buf: [4096 + INPUT_SEQ_PREFIX_LEN]u8 = undefined;
    if (payload.len > buf.len - INPUT_SEQ_PREFIX_LEN) return error.PayloadTooLarge;
    input_seq += 1;
    std.mem.writeInt(u64, buf[0..8], inputEpoch(), .little);
    std.mem.writeInt(u64, buf[8..16], input_seq, .little);
    @memcpy(buf[INPUT_SEQ_PREFIX_LEN..][0..payload.len], payload);
    return pod_protocol.writeFrame(conn, .input, buf[0 .. INPUT_SEQ_PREFIX_LEN + payload.len]);
}

const AttachContext = struct {
    conn: *ipc.Connection,
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
            writeInputFrame(c.conn, tmp[0..2]) catch |err| {
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

    writeInputFrame(c.conn, c.in_buf[0..n]) catch |err| {
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
    sendResize(c.conn, tty.getTermSize()) catch |err| {
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

    // Send versioned handshake to identify as VT client.
    wire.sendHandshake(client.fd, wire.POD_HANDSHAKE_SES_VT) catch |err| {
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
    sendResize(&conn, term_size) catch |err| {
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
        resize_ctx = .{ .conn = &conn, .pipe_fd = pipe_fds[0] };
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

fn sendResize(conn: *ipc.Connection, size: tty.TermSize) !void {
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], size.cols, .big);
    std.mem.writeInt(u16, payload[2..4], size.rows, .big);
    try pod_protocol.writeFrame(conn, .resize, &payload);
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
