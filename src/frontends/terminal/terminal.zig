const std = @import("std");
const posix = std.posix;

const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("stdlib.h");
});

pub const TermSize = struct {
    cols: u16,
    rows: u16,
};

/// Get terminal size using ioctl
pub fn getTermSize() TermSize {
    var ws: c.winsize = undefined;
    if (c.ioctl(posix.STDOUT_FILENO, c.TIOCGWINSZ, &ws) == 0) {
        return .{
            .cols = if (ws.ws_col > 0) ws.ws_col else 80,
            .rows = if (ws.ws_row > 0) ws.ws_row else 24,
        };
    }
    return .{ .cols = 80, .rows = 24 };
}

/// Enable raw mode for terminal input
pub fn enableRawMode(fd: posix.fd_t) !posix.termios {
    var termios = try posix.tcgetattr(fd);
    const orig = termios;

    termios.iflag.BRKINT = false;
    termios.iflag.ICRNL = false;
    termios.iflag.INPCK = false;
    termios.iflag.ISTRIP = false;
    termios.iflag.IXON = false;
    termios.oflag.OPOST = false;
    termios.cflag.CSIZE = .CS8;
    termios.lflag.ECHO = false;
    termios.lflag.ICANON = false;
    termios.lflag.IEXTEN = false;
    termios.lflag.ISIG = false;
    termios.cc[@intFromEnum(posix.V.TIME)] = 0;
    termios.cc[@intFromEnum(posix.V.MIN)] = 0;

    try posix.tcsetattr(fd, .NOW, termios);
    return orig;
}

/// Disable raw mode (restore original termios)
pub fn disableRawMode(fd: posix.fd_t, orig: posix.termios) !void {
    try posix.tcsetattr(fd, .NOW, orig);
}
