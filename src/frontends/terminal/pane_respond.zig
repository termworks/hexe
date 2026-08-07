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
    _ = vt;
    _ = reply_buf;

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

test "CSI routing keeps emulation and appearance ownership explicit" {
    var vt: core.VT = .{};
    try vt.init(std.testing.allocator, 80, 24);
    defer vt.deinit();
    var reply: [128]u8 = undefined;

    try std.testing.expect(csiDisposition(&vt, 'n', "5", &reply) == .forward_to_host);
    try std.testing.expect(csiDisposition(&vt, 'n', "?6", &reply) == .forward_to_host);
    try std.testing.expect(csiDisposition(&vt, 'c', "", &reply) == .forward_to_host);
    try std.testing.expect(csiDisposition(&vt, 'c', ">0", &reply) == .forward_to_host);
    try std.testing.expect(csiDisposition(&vt, 'u', "?", &reply) == .ignore);
    try std.testing.expect(csiDisposition(&vt, 'p', "?2026$", &reply) == .ignore);
}
