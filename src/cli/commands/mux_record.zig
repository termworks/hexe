const std = @import("std");
const core = @import("core");
const AsciicastWriter = core.recording.asciicast.AsciicastWriter;
const tty = @import("tty.zig");

const print = std.debug.print;
const posix = std.posix;

pub fn runMuxRecord(session: []const u8, out_path: []const u8, capture_input: bool) !void {
    if (out_path.len == 0) {
        print("Error: --out is required for terminal record\n", .{});
        std.process.exit(1);
    }
    if (session.len == 0) {
        print("Error: session name required\n", .{});
        std.process.exit(1);
    }

    // The attach command has to name a session. It used to be the literal
    // string "hexe terminal attach", which prints "session name required" and
    // exits — so a recording contained nothing but that error message.
    //
    // It also has to be THIS binary, not whatever `hexe` resolves to. A machine
    // with an older hexe earlier on PATH recorded that one instead, which fails
    // the moment the two builds disagree about the wire protocol: the cast then
    // contains the daemon-mismatch notice rather than the session. `hexe record
    // start` already resolved itself this way; this path did not.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = std.fs.selfExePath(&exe_buf) catch "hexe";

    var cmd_buf: [std.fs.max_path_bytes + 256]u8 = undefined;
    const attach_cmd = std.fmt.bufPrint(&cmd_buf, "'{s}' terminal attach {s}", .{ exe, session }) catch {
        print("Error: attach command too long\n", .{});
        std.process.exit(1);
    };

    const term_size = tty.getTermSize();
    var rec = try AsciicastWriter.init(out_path, .{
        .width = term_size.cols,
        .height = term_size.rows,
        .title = "hexe terminal record",
        .command = attach_cmd,
    });
    defer {
        rec.flush() catch |err| {
            core.logging.logError("mux_record", "failed to flush recording", err);
        };
        rec.deinit();
    }

    var pty = try core.Pty.spawn(attach_cmd);
    defer pty.close();
    pty.setSize(term_size.cols, term_size.rows) catch |err| {
        print("Warning: failed to set PTY size: {s}\n", .{@errorName(err)});
    };

    const stdin_is_tty = posix.isatty(posix.STDIN_FILENO);
    var orig_termios: ?posix.termios = null;
    if (stdin_is_tty) {
        orig_termios = try tty.enableRawMode(posix.STDIN_FILENO);
    }
    defer if (orig_termios) |orig| tty.disableRawMode(posix.STDIN_FILENO, orig) catch |err| {
        core.logging.logError("mux_record", "failed to restore terminal mode", err);
    };

    var fds = [_]posix.pollfd{
        .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = pty.master_fd, .events = posix.POLL.IN, .revents = 0 },
    };

    var in_buf: [4096]u8 = undefined;
    var out_buf: [4096]u8 = undefined;

    while (true) {
        _ = try posix.poll(&fds, 100);

        if ((fds[0].revents & posix.POLL.IN) != 0) {
            const n = posix.read(posix.STDIN_FILENO, &in_buf) catch 0;
            if (n > 0) {
                _ = try pty.write(in_buf[0..n]);
                if (capture_input) try rec.writeInput(in_buf[0..n]);
            }
        }

        if ((fds[1].revents & posix.POLL.IN) != 0) {
            const n = pty.read(&out_buf) catch 0;
            if (n > 0) {
                _ = try posix.write(posix.STDOUT_FILENO, out_buf[0..n]);
                try rec.writeOutput(out_buf[0..n]);
            }
        }

        if (pty.pollStatus() != null and (fds[1].revents & posix.POLL.IN) == 0) break;
    }
}
