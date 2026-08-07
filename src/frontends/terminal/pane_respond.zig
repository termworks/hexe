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

    if (final == 'n') {
        var value = params;
        if (value.len > 0 and value[0] == '?') value = value[1..];
        if (std.mem.eql(u8, value, "5") or std.mem.eql(u8, value, "6")) return .forward_to_host;
    }

    if (final == 'c') {
        if (params.len == 0 or std.mem.eql(u8, params, "0") or params[0] == '>') {
            return .forward_to_host;
        }
    }

    return .ignore;
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

    try std.testing.expect(csiDisposition(&vt, 'n', "5", &reply) == .forward_to_host);
    try std.testing.expect(csiDisposition(&vt, 'n', "?6", &reply) == .forward_to_host);
    try std.testing.expect(csiDisposition(&vt, 'c', "", &reply) == .forward_to_host);
    try std.testing.expect(csiDisposition(&vt, 'c', ">0", &reply) == .forward_to_host);
    try std.testing.expect(csiDisposition(&vt, 'p', "?2026$", &reply) == .ignore);
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
