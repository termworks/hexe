//! Hexe answers questions about its own emulation. The host answers questions
//! about appearance.

const std = @import("std");
const core = @import("core");

pub const Disposition = union(enum) {
    ignore,
    forward_to_host,
    reply: []const u8,
};

pub fn csiDisposition(vt: *core.VT, final: u8, params: []const u8, reply_buf: []u8) Disposition {
    // Kitty keyboard protocol: CSI ? u queries the current progressive flags;
    // the terminal replies CSI ? <flags> u.
    // https://sw.kovidgoyal.net/kitty/keyboard-protocol/
    if (final == 'u' and std.mem.eql(u8, params, "?")) {
        const reply = std.fmt.bufPrint(reply_buf, "\x1b[?{d}u", .{
            vt.terminal.screens.active.kitty_keyboard.current().int(),
        }) catch return .ignore;
        return .{ .reply = reply };
    }

    if (final == 'p' and params.len > 1 and params[params.len - 1] == '$') {
        const private = params[0] == '?';
        const digits = params[if (private) 1 else 0 .. params.len - 1];
        if (digits.len == 0) return .ignore;
        const mode = std.fmt.parseInt(u16, digits, 10) catch return .ignore;
        const state: u8 = if (modeValue(vt, mode, private)) |enabled|
            if (enabled) 1 else 2
        else
            0;
        const reply = if (private)
            std.fmt.bufPrint(reply_buf, "\x1b[?{d};{d}$y", .{ mode, state }) catch return .ignore
        else
            std.fmt.bufPrint(reply_buf, "\x1b[{d};{d}$y", .{ mode, state }) catch return .ignore;
        return .{ .reply = reply };
    }

    if (final == 'n') {
        if (std.mem.eql(u8, params, "5")) return .{ .reply = "\x1b[0n" };
        if (std.mem.eql(u8, params, "6") or std.mem.eql(u8, params, "?6")) {
            const cursor = vt.getCursor();
            const row = @as(u32, cursor.y) + 1;
            const column = @as(u32, cursor.x) + 1;
            const reply = if (params[0] == '?')
                std.fmt.bufPrint(reply_buf, "\x1b[?{d};{d}R", .{ row, column }) catch return .ignore
            else
                std.fmt.bufPrint(reply_buf, "\x1b[{d};{d}R", .{ row, column }) catch return .ignore;
            return .{ .reply = reply };
        }
    }

    if (final == 'c') {
        if (params.len == 0 or std.mem.eql(u8, params, "0") or params[0] == '>') {
            return .forward_to_host;
        }
    }

    return .ignore;
}

fn modeValue(vt: *const core.VT, mode: u16, private: bool) ?bool {
    if (!private) return switch (mode) {
        2 => vt.terminal.modes.get(.disable_keyboard),
        4 => vt.terminal.modes.get(.insert),
        12 => vt.terminal.modes.get(.send_receive_mode),
        20 => vt.terminal.modes.get(.linefeed),
        else => null,
    };

    return switch (mode) {
        25 => vt.terminal.modes.get(.cursor_visible),
        1000 => vt.terminal.modes.get(.mouse_event_normal),
        1002 => vt.terminal.modes.get(.mouse_event_button),
        1003 => vt.terminal.modes.get(.mouse_event_any),
        1006 => vt.terminal.modes.get(.mouse_format_sgr),
        1049 => vt.terminal.modes.get(.alt_screen_save_cursor_clear_enter),
        2004 => vt.terminal.modes.get(.bracketed_paste),
        2026 => vt.terminal.modes.get(.synchronized_output),
        else => null,
    };
}

fn expectReply(disposition: Disposition, expected: []const u8) !void {
    switch (disposition) {
        .reply => |actual| try std.testing.expectEqualStrings(expected, actual),
        else => return error.ExpectedReply,
    }
}

test "CSI routing keeps emulation and appearance ownership explicit" {
    var vt: core.VT = .{};
    try vt.init(std.testing.allocator, 80, 24);
    defer vt.deinit();
    var reply: [128]u8 = undefined;

    try expectReply(csiDisposition(&vt, 'n', "5", &reply), "\x1b[0n");
    try expectReply(csiDisposition(&vt, 'n', "6", &reply), "\x1b[1;1R");
    try std.testing.expect(csiDisposition(&vt, 'c', "", &reply) == .forward_to_host);
    try std.testing.expect(csiDisposition(&vt, 'c', ">0", &reply) == .forward_to_host);
    try expectReply(csiDisposition(&vt, 'p', "?2026$", &reply), "\x1b[?2026;2$y");
}

test "Kitty keyboard query reports the active flag stack" {
    var vt: core.VT = .{};
    try vt.init(std.testing.allocator, 80, 24);
    defer vt.deinit();
    var reply: [128]u8 = undefined;

    try expectReply(csiDisposition(&vt, 'u', "?", &reply), "\x1b[?0u");
    try vt.feed("\x1b[>1u");
    try expectReply(csiDisposition(&vt, 'u', "?", &reply), "\x1b[?1u");
    try vt.feed("\x1b[>2u");
    try expectReply(csiDisposition(&vt, 'u', "?", &reply), "\x1b[?2u");
    try vt.feed("\x1b[<u");
    try expectReply(csiDisposition(&vt, 'u', "?", &reply), "\x1b[?1u");
    try std.testing.expect(csiDisposition(&vt, 'u', "=1", &reply) == .ignore);
}

test "DECRQM reports modeled pane modes and rejects unknown modes" {
    var vt: core.VT = .{};
    try vt.init(std.testing.allocator, 80, 24);
    defer vt.deinit();
    var reply: [128]u8 = undefined;

    try expectReply(csiDisposition(&vt, 'p', "?2026$", &reply), "\x1b[?2026;2$y");
    try vt.feed("\x1b[?2026h");
    try expectReply(csiDisposition(&vt, 'p', "?2026$", &reply), "\x1b[?2026;1$y");
    try vt.feed("\x1b[?2026l");
    try expectReply(csiDisposition(&vt, 'p', "?2026$", &reply), "\x1b[?2026;2$y");

    try expectReply(csiDisposition(&vt, 'p', "?2004$", &reply), "\x1b[?2004;2$y");
    try vt.feed("\x1b[?2004h");
    try expectReply(csiDisposition(&vt, 'p', "?2004$", &reply), "\x1b[?2004;1$y");

    try expectReply(csiDisposition(&vt, 'p', "4$", &reply), "\x1b[4;2$y");
    try vt.feed("\x1b[4h");
    try expectReply(csiDisposition(&vt, 'p', "4$", &reply), "\x1b[4;1$y");

    try expectReply(csiDisposition(&vt, 'p', "?9999$", &reply), "\x1b[?9999;0$y");
    try std.testing.expect(csiDisposition(&vt, 'p', "?bad$", &reply) == .ignore);
}

test "DSR reports pane-local one-based cursor coordinates" {
    var vt: core.VT = .{};
    try vt.init(std.testing.allocator, 80, 24);
    defer vt.deinit();
    var reply: [128]u8 = undefined;

    try expectReply(csiDisposition(&vt, 'n', "5", &reply), "\x1b[0n");
    try expectReply(csiDisposition(&vt, 'n', "6", &reply), "\x1b[1;1R");
    try expectReply(csiDisposition(&vt, 'n', "?6", &reply), "\x1b[?1;1R");

    try vt.feed("\x1b[10;20H");
    try expectReply(csiDisposition(&vt, 'n', "6", &reply), "\x1b[10;20R");
    try expectReply(csiDisposition(&vt, 'n', "?6", &reply), "\x1b[?10;20R");

    try vt.feed("\x1b[24;80H");
    try expectReply(csiDisposition(&vt, 'n', "6", &reply), "\x1b[24;80R");
    try std.testing.expect(csiDisposition(&vt, 'n', "?5", &reply) == .ignore);
}
