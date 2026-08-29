const std = @import("std");
const posix = std.posix;

const c = @cImport({
    @cInclude("sys/ioctl.h");
});

pub const TermSize = struct {
    cols: u16,
    rows: u16,
    /// The terminal's cell size in pixels, or zero when it reports none.
    /// Carried alongside the cell counts so a pty opened from here can report a
    /// pixel geometry, which is how a program works out how tall an image will
    /// be. Most terminals fill this in; those that do not leave it zero, and
    /// zero means "unknown" rather than a made-up figure.
    cell_w: u16 = 0,
    cell_h: u16 = 0,
};

pub fn getTermSize() TermSize {
    var ws: c.winsize = undefined;
    if (c.ioctl(posix.STDOUT_FILENO, c.TIOCGWINSZ, &ws) == 0) {
        const cols: u16 = if (ws.ws_col > 0) ws.ws_col else 80;
        const rows: u16 = if (ws.ws_row > 0) ws.ws_row else 24;
        return .{
            .cols = cols,
            .rows = rows,
            .cell_w = if (ws.ws_col > 0) ws.ws_xpixel / ws.ws_col else 0,
            .cell_h = if (ws.ws_row > 0) ws.ws_ypixel / ws.ws_row else 0,
        };
    }
    return .{ .cols = 80, .rows = 24 };
}

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

pub fn disableRawMode(fd: posix.fd_t, orig: posix.termios) !void {
    try posix.tcsetattr(fd, .NOW, orig);
}
