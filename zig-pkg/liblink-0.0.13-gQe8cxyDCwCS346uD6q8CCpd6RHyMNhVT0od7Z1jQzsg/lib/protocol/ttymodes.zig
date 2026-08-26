const std = @import("std");
const posix = std.posix;
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

/// Terminal mode opcodes from RFC 4254 Section 8
pub const TTY_OP_END = 0;
pub const VINTR = 1;
pub const VQUIT = 2;
pub const VERASE = 3;
pub const VKILL = 4;
pub const VEOF = 5;
pub const VEOL = 6;
pub const VEOL2 = 7;
pub const VSTART = 8;
pub const VSTOP = 9;
pub const VSUSP = 10;
pub const VDSUSP = 11;
pub const VREPRINT = 12;
pub const VWERASE = 13;
pub const VLNEXT = 14;
pub const VFLUSH = 15;
pub const VSWTCH = 16;
pub const VSTATUS = 17;
pub const VDISCARD = 18;

// Input modes
pub const IGNPAR = 30;
pub const PARMRK = 31;
pub const INPCK = 32;
pub const ISTRIP = 33;
pub const INLCR = 34;
pub const IGNCR = 35;
pub const ICRNL = 36;
pub const IUCLC = 37;
pub const IXON = 38;
pub const IXANY = 39;
pub const IXOFF = 40;
pub const IMAXBEL = 41;

// Local modes
pub const ISIG = 50;
pub const ICANON = 51;
pub const XCASE = 52;
pub const ECHO = 53;
pub const ECHOE = 54;
pub const ECHOK = 55;
pub const ECHONL = 56;
pub const NOFLSH = 57;
pub const TOSTOP = 58;
pub const IEXTEN = 59;
pub const ECHOCTL = 60;
pub const ECHOKE = 61;
pub const PENDIN = 62;

// Output modes
pub const OPOST = 70;
pub const OLCUC = 71;
pub const ONLCR = 72;
pub const OCRNL = 73;
pub const ONOCR = 74;
pub const ONLRET = 75;

// Control modes
pub const CS7 = 90;
pub const CS8 = 91;
pub const PARENB = 92;
pub const PARODD = 93;

// Baud rates
pub const TTY_OP_ISPEED = 128;
pub const TTY_OP_OSPEED = 129;

/// Encode current terminal modes for SSH PTY request
///
/// Returns encoded byte stream according to RFC 4254 Section 8
pub fn encodeTerminalModes(allocator: std.mem.Allocator) ![]u8 {
    // Get current terminal settings
    var termios_p: c.termios = undefined;
    if (c.tcgetattr(posix.STDIN_FILENO, &termios_p) != 0) {
        // If we can't get terminal settings, return minimal modes
        return try encodeMinimalModes(allocator);
    }

    // Allocate buffer for encoded modes (max ~300 bytes)
    var buffer: [512]u8 = undefined;
    var offset: usize = 0;

    // Helper to encode a mode
    const encodeByte = struct {
        fn call(buf: []u8, idx: *usize, opcode: u8, value: u32) !void {
            buf[idx.*] = opcode;
            idx.* += 1;
            buf[idx.*] = @intCast((value >> 24) & 0xFF);
            idx.* += 1;
            buf[idx.*] = @intCast((value >> 16) & 0xFF);
            idx.* += 1;
            buf[idx.*] = @intCast((value >> 8) & 0xFF);
            idx.* += 1;
            buf[idx.*] = @intCast(value & 0xFF);
            idx.* += 1;
        }
    }.call;

    // Encode control characters
    if (termios_p.c_cc[c.VINTR] != 0) try encodeByte(&buffer, &offset, VINTR, termios_p.c_cc[c.VINTR]);
    if (termios_p.c_cc[c.VQUIT] != 0) try encodeByte(&buffer, &offset, VQUIT, termios_p.c_cc[c.VQUIT]);
    if (termios_p.c_cc[c.VERASE] != 0) try encodeByte(&buffer, &offset, VERASE, termios_p.c_cc[c.VERASE]);
    if (termios_p.c_cc[c.VKILL] != 0) try encodeByte(&buffer, &offset, VKILL, termios_p.c_cc[c.VKILL]);
    if (termios_p.c_cc[c.VEOF] != 0) try encodeByte(&buffer, &offset, VEOF, termios_p.c_cc[c.VEOF]);
    if (termios_p.c_cc[c.VEOL] != 0) try encodeByte(&buffer, &offset, VEOL, termios_p.c_cc[c.VEOL]);
    if (termios_p.c_cc[c.VSUSP] != 0) try encodeByte(&buffer, &offset, VSUSP, termios_p.c_cc[c.VSUSP]);

    // Encode input modes
    try encodeByte(&buffer, &offset, IGNPAR, if (termios_p.c_iflag & c.IGNPAR != 0) 1 else 0);
    try encodeByte(&buffer, &offset, PARMRK, if (termios_p.c_iflag & c.PARMRK != 0) 1 else 0);
    try encodeByte(&buffer, &offset, INPCK, if (termios_p.c_iflag & c.INPCK != 0) 1 else 0);
    try encodeByte(&buffer, &offset, ISTRIP, if (termios_p.c_iflag & c.ISTRIP != 0) 1 else 0);
    try encodeByte(&buffer, &offset, INLCR, if (termios_p.c_iflag & c.INLCR != 0) 1 else 0);
    try encodeByte(&buffer, &offset, IGNCR, if (termios_p.c_iflag & c.IGNCR != 0) 1 else 0);
    try encodeByte(&buffer, &offset, ICRNL, if (termios_p.c_iflag & c.ICRNL != 0) 1 else 0);
    try encodeByte(&buffer, &offset, IXON, if (termios_p.c_iflag & c.IXON != 0) 1 else 0);
    try encodeByte(&buffer, &offset, IXANY, if (termios_p.c_iflag & c.IXANY != 0) 1 else 0);
    try encodeByte(&buffer, &offset, IXOFF, if (termios_p.c_iflag & c.IXOFF != 0) 1 else 0);

    // Encode local modes
    try encodeByte(&buffer, &offset, ISIG, if (termios_p.c_lflag & c.ISIG != 0) 1 else 0);
    try encodeByte(&buffer, &offset, ICANON, if (termios_p.c_lflag & c.ICANON != 0) 1 else 0);
    try encodeByte(&buffer, &offset, ECHO, if (termios_p.c_lflag & c.ECHO != 0) 1 else 0);
    try encodeByte(&buffer, &offset, ECHOE, if (termios_p.c_lflag & c.ECHOE != 0) 1 else 0);
    try encodeByte(&buffer, &offset, ECHOK, if (termios_p.c_lflag & c.ECHOK != 0) 1 else 0);
    try encodeByte(&buffer, &offset, ECHONL, if (termios_p.c_lflag & c.ECHONL != 0) 1 else 0);
    try encodeByte(&buffer, &offset, NOFLSH, if (termios_p.c_lflag & c.NOFLSH != 0) 1 else 0);
    try encodeByte(&buffer, &offset, TOSTOP, if (termios_p.c_lflag & c.TOSTOP != 0) 1 else 0);
    try encodeByte(&buffer, &offset, IEXTEN, if (termios_p.c_lflag & c.IEXTEN != 0) 1 else 0);

    // Encode output modes
    try encodeByte(&buffer, &offset, OPOST, if (termios_p.c_oflag & c.OPOST != 0) 1 else 0);
    try encodeByte(&buffer, &offset, ONLCR, if (termios_p.c_oflag & c.ONLCR != 0) 1 else 0);

    // Encode baud rates
    const ispeed = c.cfgetispeed(&termios_p);
    const ospeed = c.cfgetospeed(&termios_p);
    try encodeByte(&buffer, &offset, TTY_OP_ISPEED, speedToBaud(ispeed));
    try encodeByte(&buffer, &offset, TTY_OP_OSPEED, speedToBaud(ospeed));

    // Terminate with TTY_OP_END
    buffer[offset] = TTY_OP_END;
    offset += 1;

    return try allocator.dupe(u8, buffer[0..offset]);
}

/// Encode minimal terminal modes for when we can't get real terminal settings
fn encodeMinimalModes(allocator: std.mem.Allocator) ![]u8 {
    var buffer: [256]u8 = undefined;
    var offset: usize = 0;

    const encodeByte = struct {
        fn call(buf: []u8, idx: *usize, opcode: u8, value: u32) !void {
            buf[idx.*] = opcode;
            idx.* += 1;
            buf[idx.*] = @intCast((value >> 24) & 0xFF);
            idx.* += 1;
            buf[idx.*] = @intCast((value >> 16) & 0xFF);
            idx.* += 1;
            buf[idx.*] = @intCast((value >> 8) & 0xFF);
            idx.* += 1;
            buf[idx.*] = @intCast(value & 0xFF);
            idx.* += 1;
        }
    }.call;

    // Set reasonable defaults
    try encodeByte(&buffer, &offset, VINTR, 3); // Ctrl+C
    try encodeByte(&buffer, &offset, VQUIT, 28); // Ctrl+\
    try encodeByte(&buffer, &offset, VERASE, 127); // Backspace
    try encodeByte(&buffer, &offset, VEOF, 4); // Ctrl+D
    try encodeByte(&buffer, &offset, ISIG, 1); // Enable signals
    try encodeByte(&buffer, &offset, ICANON, 1); // Canonical mode
    try encodeByte(&buffer, &offset, ECHO, 1); // Echo input
    try encodeByte(&buffer, &offset, ECHOE, 1); // Visual erase
    try encodeByte(&buffer, &offset, ECHOK, 1); // Echo kill
    try encodeByte(&buffer, &offset, OPOST, 1); // Output processing
    try encodeByte(&buffer, &offset, ONLCR, 1); // NL to CR+NL

    // Terminate
    buffer[offset] = TTY_OP_END;
    offset += 1;

    return try allocator.dupe(u8, buffer[0..offset]);
}

fn decodeModeValue(encoded: []const u8, start: usize) u32 {
    return (@as(u32, encoded[start + 1]) << 24) |
        (@as(u32, encoded[start + 2]) << 16) |
        (@as(u32, encoded[start + 3]) << 8) |
        @as(u32, encoded[start + 4]);
}

pub fn applyTerminalModes(fd: posix.fd_t, encoded: []const u8) !void {
    if (encoded.len == 0) return;

    var termios_p: c.termios = undefined;
    if (c.tcgetattr(fd, &termios_p) != 0) {
        return error.TcGetAttrFailed;
    }

    try applyEncodedTerminalModesToTermios(&termios_p, encoded);

    if (c.tcsetattr(fd, c.TCSANOW, &termios_p) != 0) {
        return error.TcSetAttrFailed;
    }
}

pub fn applyEncodedTerminalModesToTermios(termios_p: *c.termios, encoded: []const u8) !void {
    var offset: usize = 0;

    while (offset < encoded.len) {
        const opcode = encoded[offset];
        if (opcode == TTY_OP_END) return;
        if (offset + 5 > encoded.len) return error.InvalidTerminalModes;

        const value = decodeModeValue(encoded, offset);
        applyMode(termios_p, opcode, value);
        offset += 5;
    }

    return error.InvalidTerminalModes;
}

pub fn speedToBaud(speed: c.speed_t) u32 {
    if (@hasDecl(c, "B0") and speed == c.B0) return 0;
    if (@hasDecl(c, "B50") and speed == c.B50) return 50;
    if (@hasDecl(c, "B75") and speed == c.B75) return 75;
    if (@hasDecl(c, "B110") and speed == c.B110) return 110;
    if (@hasDecl(c, "B134") and speed == c.B134) return 134;
    if (@hasDecl(c, "B150") and speed == c.B150) return 150;
    if (@hasDecl(c, "B200") and speed == c.B200) return 200;
    if (@hasDecl(c, "B300") and speed == c.B300) return 300;
    if (@hasDecl(c, "B600") and speed == c.B600) return 600;
    if (@hasDecl(c, "B1200") and speed == c.B1200) return 1200;
    if (@hasDecl(c, "B1800") and speed == c.B1800) return 1800;
    if (@hasDecl(c, "B2400") and speed == c.B2400) return 2400;
    if (@hasDecl(c, "B4800") and speed == c.B4800) return 4800;
    if (@hasDecl(c, "B9600") and speed == c.B9600) return 9600;
    if (@hasDecl(c, "B19200") and speed == c.B19200) return 19200;
    if (@hasDecl(c, "B38400") and speed == c.B38400) return 38400;
    if (@hasDecl(c, "B57600") and speed == c.B57600) return 57600;
    if (@hasDecl(c, "B115200") and speed == c.B115200) return 115200;
    if (@hasDecl(c, "B230400") and speed == c.B230400) return 230400;
    if (@hasDecl(c, "B460800") and speed == c.B460800) return 460800;
    if (@hasDecl(c, "B500000") and speed == c.B500000) return 500000;
    if (@hasDecl(c, "B576000") and speed == c.B576000) return 576000;
    if (@hasDecl(c, "B921600") and speed == c.B921600) return 921600;
    if (@hasDecl(c, "B1000000") and speed == c.B1000000) return 1000000;
    if (@hasDecl(c, "B1152000") and speed == c.B1152000) return 1152000;
    if (@hasDecl(c, "B1500000") and speed == c.B1500000) return 1500000;
    if (@hasDecl(c, "B2000000") and speed == c.B2000000) return 2000000;
    if (@hasDecl(c, "B2500000") and speed == c.B2500000) return 2500000;
    if (@hasDecl(c, "B3000000") and speed == c.B3000000) return 3000000;
    if (@hasDecl(c, "B3500000") and speed == c.B3500000) return 3500000;
    if (@hasDecl(c, "B4000000") and speed == c.B4000000) return 4000000;
    return 0;
}

pub fn baudToSpeed(baud: u32) ?c.speed_t {
    return switch (baud) {
        0 => if (@hasDecl(c, "B0")) c.B0 else null,
        50 => if (@hasDecl(c, "B50")) c.B50 else null,
        75 => if (@hasDecl(c, "B75")) c.B75 else null,
        110 => if (@hasDecl(c, "B110")) c.B110 else null,
        134 => if (@hasDecl(c, "B134")) c.B134 else null,
        150 => if (@hasDecl(c, "B150")) c.B150 else null,
        200 => if (@hasDecl(c, "B200")) c.B200 else null,
        300 => if (@hasDecl(c, "B300")) c.B300 else null,
        600 => if (@hasDecl(c, "B600")) c.B600 else null,
        1200 => if (@hasDecl(c, "B1200")) c.B1200 else null,
        1800 => if (@hasDecl(c, "B1800")) c.B1800 else null,
        2400 => if (@hasDecl(c, "B2400")) c.B2400 else null,
        4800 => if (@hasDecl(c, "B4800")) c.B4800 else null,
        9600 => if (@hasDecl(c, "B9600")) c.B9600 else null,
        19200 => if (@hasDecl(c, "B19200")) c.B19200 else null,
        38400 => if (@hasDecl(c, "B38400")) c.B38400 else null,
        57600 => if (@hasDecl(c, "B57600")) c.B57600 else null,
        115200 => if (@hasDecl(c, "B115200")) c.B115200 else null,
        230400 => if (@hasDecl(c, "B230400")) c.B230400 else null,
        460800 => if (@hasDecl(c, "B460800")) c.B460800 else null,
        500000 => if (@hasDecl(c, "B500000")) c.B500000 else null,
        576000 => if (@hasDecl(c, "B576000")) c.B576000 else null,
        921600 => if (@hasDecl(c, "B921600")) c.B921600 else null,
        1000000 => if (@hasDecl(c, "B1000000")) c.B1000000 else null,
        1152000 => if (@hasDecl(c, "B1152000")) c.B1152000 else null,
        1500000 => if (@hasDecl(c, "B1500000")) c.B1500000 else null,
        2000000 => if (@hasDecl(c, "B2000000")) c.B2000000 else null,
        2500000 => if (@hasDecl(c, "B2500000")) c.B2500000 else null,
        3000000 => if (@hasDecl(c, "B3000000")) c.B3000000 else null,
        3500000 => if (@hasDecl(c, "B3500000")) c.B3500000 else null,
        4000000 => if (@hasDecl(c, "B4000000")) c.B4000000 else null,
        else => null,
    };
}

fn applyMode(termios_p: *c.termios, opcode: u8, value: u32) void {
    switch (opcode) {
        VINTR => setControlChar(termios_p, "VINTR", value),
        VQUIT => setControlChar(termios_p, "VQUIT", value),
        VERASE => setControlChar(termios_p, "VERASE", value),
        VKILL => setControlChar(termios_p, "VKILL", value),
        VEOF => setControlChar(termios_p, "VEOF", value),
        VEOL => setControlChar(termios_p, "VEOL", value),
        VEOL2 => setControlChar(termios_p, "VEOL2", value),
        VSTART => setControlChar(termios_p, "VSTART", value),
        VSTOP => setControlChar(termios_p, "VSTOP", value),
        VSUSP => setControlChar(termios_p, "VSUSP", value),
        VDSUSP => setControlChar(termios_p, "VDSUSP", value),
        VREPRINT => setControlChar(termios_p, "VREPRINT", value),
        VWERASE => setControlChar(termios_p, "VWERASE", value),
        VLNEXT => setControlChar(termios_p, "VLNEXT", value),
        VFLUSH => setControlChar(termios_p, "VDISCARD", value),
        VSWTCH => setControlChar(termios_p, "VSWTCH", value),
        VSTATUS => setControlChar(termios_p, "VSTATUS", value),
        VDISCARD => setControlChar(termios_p, "VDISCARD", value),

        IGNPAR => setFlagByName(&termios_p.c_iflag, "IGNPAR", value),
        PARMRK => setFlagByName(&termios_p.c_iflag, "PARMRK", value),
        INPCK => setFlagByName(&termios_p.c_iflag, "INPCK", value),
        ISTRIP => setFlagByName(&termios_p.c_iflag, "ISTRIP", value),
        INLCR => setFlagByName(&termios_p.c_iflag, "INLCR", value),
        IGNCR => setFlagByName(&termios_p.c_iflag, "IGNCR", value),
        ICRNL => setFlagByName(&termios_p.c_iflag, "ICRNL", value),
        IUCLC => setFlagByName(&termios_p.c_iflag, "IUCLC", value),
        IXON => setFlagByName(&termios_p.c_iflag, "IXON", value),
        IXANY => setFlagByName(&termios_p.c_iflag, "IXANY", value),
        IXOFF => setFlagByName(&termios_p.c_iflag, "IXOFF", value),
        IMAXBEL => setFlagByName(&termios_p.c_iflag, "IMAXBEL", value),

        ISIG => setFlagByName(&termios_p.c_lflag, "ISIG", value),
        ICANON => setFlagByName(&termios_p.c_lflag, "ICANON", value),
        XCASE => setFlagByName(&termios_p.c_lflag, "XCASE", value),
        ECHO => setFlagByName(&termios_p.c_lflag, "ECHO", value),
        ECHOE => setFlagByName(&termios_p.c_lflag, "ECHOE", value),
        ECHOK => setFlagByName(&termios_p.c_lflag, "ECHOK", value),
        ECHONL => setFlagByName(&termios_p.c_lflag, "ECHONL", value),
        NOFLSH => setFlagByName(&termios_p.c_lflag, "NOFLSH", value),
        TOSTOP => setFlagByName(&termios_p.c_lflag, "TOSTOP", value),
        IEXTEN => setFlagByName(&termios_p.c_lflag, "IEXTEN", value),
        ECHOCTL => setFlagByName(&termios_p.c_lflag, "ECHOCTL", value),
        ECHOKE => setFlagByName(&termios_p.c_lflag, "ECHOKE", value),
        PENDIN => setFlagByName(&termios_p.c_lflag, "PENDIN", value),

        OPOST => setFlagByName(&termios_p.c_oflag, "OPOST", value),
        OLCUC => setFlagByName(&termios_p.c_oflag, "OLCUC", value),
        ONLCR => setFlagByName(&termios_p.c_oflag, "ONLCR", value),
        OCRNL => setFlagByName(&termios_p.c_oflag, "OCRNL", value),
        ONOCR => setFlagByName(&termios_p.c_oflag, "ONOCR", value),
        ONLRET => setFlagByName(&termios_p.c_oflag, "ONLRET", value),

        CS7 => setControlModeSize(termios_p, "CS7"),
        CS8 => setControlModeSize(termios_p, "CS8"),
        PARENB => setFlagByName(&termios_p.c_cflag, "PARENB", value),
        PARODD => setFlagByName(&termios_p.c_cflag, "PARODD", value),

        TTY_OP_ISPEED => if (baudToSpeed(value)) |speed| {
            _ = c.cfsetispeed(termios_p, speed);
        },
        TTY_OP_OSPEED => if (baudToSpeed(value)) |speed| {
            _ = c.cfsetospeed(termios_p, speed);
        },

        else => {},
    }
}

fn setControlChar(termios_p: *c.termios, comptime decl_name: []const u8, value: u32) void {
    if (!@hasDecl(c, decl_name)) return;

    const cc_index: usize = @intCast(@field(c, decl_name));
    if (cc_index >= termios_p.c_cc.len) return;

    const cc_type = @TypeOf(termios_p.c_cc[0]);
    const max_value: u32 = std.math.maxInt(cc_type);
    termios_p.c_cc[cc_index] = @intCast(@min(value, max_value));
}

fn setFlagByName(field: anytype, comptime decl_name: []const u8, value: u32) void {
    if (!@hasDecl(c, decl_name)) return;
    applyFlag(field, @field(c, decl_name), value != 0);
}

fn applyFlag(field: anytype, mask: anytype, enabled: bool) void {
    const field_type = @TypeOf(field.*);
    const typed_mask: field_type = @intCast(mask);

    if (enabled) {
        field.* |= typed_mask;
    } else {
        field.* &= ~typed_mask;
    }
}

fn setControlModeSize(termios_p: *c.termios, comptime decl_name: []const u8) void {
    if (!@hasDecl(c, "CSIZE") or !@hasDecl(c, decl_name)) return;

    const cflag_type = @TypeOf(termios_p.c_cflag);
    termios_p.c_cflag &= ~@as(cflag_type, @intCast(c.CSIZE));
    termios_p.c_cflag |= @as(cflag_type, @intCast(@field(c, decl_name)));
}

fn appendEncodedMode(list: *std.ArrayList(u8), opcode: u8, value: u32) !void {
    try list.append(opcode);

    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    try list.appendSlice(&bytes);
}

test "encodeMinimalModes includes expected defaults" {
    const allocator = std.testing.allocator;

    const encoded = try encodeMinimalModes(allocator);
    defer allocator.free(encoded);

    try std.testing.expect(encoded.len > 1);
    try std.testing.expectEqual(TTY_OP_END, encoded[encoded.len - 1]);

    var offset: usize = 0;
    var found_intr = false;
    var found_eof = false;
    var found_icanon = false;
    var found_echo = false;

    while (offset < encoded.len and encoded[offset] != TTY_OP_END) : (offset += 5) {
        try std.testing.expect(offset + 5 <= encoded.len);

        const opcode = encoded[offset];
        const value = decodeModeValue(encoded, offset);

        switch (opcode) {
            VINTR => {
                found_intr = true;
                try std.testing.expectEqual(@as(u32, 3), value);
            },
            VEOF => {
                found_eof = true;
                try std.testing.expectEqual(@as(u32, 4), value);
            },
            ICANON => {
                found_icanon = true;
                try std.testing.expectEqual(@as(u32, 1), value);
            },
            ECHO => {
                found_echo = true;
                try std.testing.expectEqual(@as(u32, 1), value);
            },
            else => {},
        }
    }

    try std.testing.expect(found_intr);
    try std.testing.expect(found_eof);
    try std.testing.expect(found_icanon);
    try std.testing.expect(found_echo);
}

test "encodeMinimalModes entries are fixed-width and end terminated" {
    const allocator = std.testing.allocator;

    const encoded = try encodeMinimalModes(allocator);
    defer allocator.free(encoded);

    const payload_len = encoded.len - 1;
    try std.testing.expectEqual(@as(usize, 0), payload_len % 5);
    try std.testing.expectEqual(TTY_OP_END, encoded[encoded.len - 1]);
}

test "encodeTerminalModes always terminates with TTY_OP_END" {
    const allocator = std.testing.allocator;

    const encoded = try encodeTerminalModes(allocator);
    defer allocator.free(encoded);

    try std.testing.expect(encoded.len > 0);
    try std.testing.expectEqual(TTY_OP_END, encoded[encoded.len - 1]);
}

test "speed conversion uses baud values instead of raw termios constants" {
    if (@hasDecl(c, "B38400")) {
        try std.testing.expectEqual(@as(u32, 38400), speedToBaud(c.B38400));
        try std.testing.expectEqual(c.B38400, baudToSpeed(38400).?);
    }

    try std.testing.expectEqual(@as(?c.speed_t, null), baudToSpeed(12345));
}

test "applyEncodedTerminalModesToTermios updates flags control chars and speed" {
    const allocator = std.testing.allocator;

    var encoded = std.ArrayList(u8).init(allocator);
    defer encoded.deinit();

    try appendEncodedMode(&encoded, ECHO, 0);
    try appendEncodedMode(&encoded, ICANON, 0);
    try appendEncodedMode(&encoded, IXON, 1);
    try appendEncodedMode(&encoded, VERASE, 127);
    try appendEncodedMode(&encoded, OPOST, 1);
    try appendEncodedMode(&encoded, TTY_OP_ISPEED, 38400);
    try appendEncodedMode(&encoded, TTY_OP_OSPEED, 38400);
    try encoded.append(TTY_OP_END);

    var termios_p = std.mem.zeroes(c.termios);
    try applyEncodedTerminalModesToTermios(&termios_p, encoded.items);

    if (@hasDecl(c, "ECHO")) {
        const echo_mask: @TypeOf(termios_p.c_lflag) = @intCast(c.ECHO);
        try std.testing.expect(termios_p.c_lflag & echo_mask == 0);
    }
    if (@hasDecl(c, "ICANON")) {
        const icanon_mask: @TypeOf(termios_p.c_lflag) = @intCast(c.ICANON);
        try std.testing.expect(termios_p.c_lflag & icanon_mask == 0);
    }
    if (@hasDecl(c, "IXON")) {
        const ixon_mask: @TypeOf(termios_p.c_iflag) = @intCast(c.IXON);
        try std.testing.expect(termios_p.c_iflag & ixon_mask != 0);
    }
    if (@hasDecl(c, "OPOST")) {
        const opost_mask: @TypeOf(termios_p.c_oflag) = @intCast(c.OPOST);
        try std.testing.expect(termios_p.c_oflag & opost_mask != 0);
    }
    if (@hasDecl(c, "VERASE")) {
        try std.testing.expectEqual(@as(@TypeOf(termios_p.c_cc[0]), 127), termios_p.c_cc[@intCast(c.VERASE)]);
    }
    if (baudToSpeed(38400) != null) {
        try std.testing.expectEqual(@as(u32, 38400), speedToBaud(c.cfgetispeed(&termios_p)));
        try std.testing.expectEqual(@as(u32, 38400), speedToBaud(c.cfgetospeed(&termios_p)));
    }
}

test "applyEncodedTerminalModesToTermios rejects truncated payloads" {
    const truncated = [_]u8{ ECHO, 0, 0, 0 };
    var termios_p = std.mem.zeroes(c.termios);

    try std.testing.expectError(error.InvalidTerminalModes, applyEncodedTerminalModesToTermios(&termios_p, &truncated));
}
