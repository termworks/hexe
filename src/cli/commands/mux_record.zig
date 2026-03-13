const std = @import("std");
const core = @import("core");
const AsciicastWriter = core.recording.asciicast.AsciicastWriter;
const tty = @import("tty.zig");

const print = std.debug.print;
const posix = std.posix;

pub fn runMuxRecord(out_path: []const u8, capture_input: bool) !void {
    if (out_path.len == 0) {
        print("Error: --out is required for terminal record\n", .{});
        return;
    }

    const term_size = tty.getTermSize();
    var rec = try AsciicastWriter.init(out_path, .{
        .width = term_size.cols,
        .height = term_size.rows,
        .title = "hexe terminal record",
        .command = "hexe terminal attach",
    });
    defer {
        rec.flush() catch {};
        rec.deinit();
    }

    var pty = try core.Pty.spawn("hexe terminal attach");
    defer pty.close();
    pty.setSize(term_size.cols, term_size.rows) catch {};

    const stdin_is_tty = posix.isatty(posix.STDIN_FILENO);
    var orig_termios: ?posix.termios = null;
    if (stdin_is_tty) {
        orig_termios = try tty.enableRawMode(posix.STDIN_FILENO);
    }
    defer if (orig_termios) |orig| tty.disableRawMode(posix.STDIN_FILENO, orig) catch {};

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
                _ = pty.write(in_buf[0..n]) catch {};
                if (capture_input) rec.writeInput(in_buf[0..n]) catch {};
            }
        }

        if ((fds[1].revents & posix.POLL.IN) != 0) {
            const n = pty.read(&out_buf) catch 0;
            if (n > 0) {
                _ = posix.write(posix.STDOUT_FILENO, out_buf[0..n]) catch {};
                rec.writeOutput(out_buf[0..n]) catch {};
            }
        }

        if (pty.pollStatus() != null and (fds[1].revents & posix.POLL.IN) == 0) break;
    }
}
