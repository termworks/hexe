const std = @import("std");

pub const ExtensionError = error{
    InvalidAlpnWire,
    InvalidSelectedAlpn,
};

pub fn validate_alpn_list_wire(alpn_wire: []const u8) ExtensionError!void {
    if (alpn_wire.len < 2) return error.InvalidAlpnWire;
    const list_len: usize = (@as(usize, alpn_wire[0]) << 8) | alpn_wire[1];
    if (list_len + 2 != alpn_wire.len) return error.InvalidAlpnWire;
}

pub fn parse_selected_alpn(alpn_wire: []const u8) ExtensionError![]const u8 {
    try validate_alpn_list_wire(alpn_wire);
    if (alpn_wire.len < 3) return error.InvalidSelectedAlpn;

    const name_len: usize = alpn_wire[2];
    if (name_len == 0) return error.InvalidSelectedAlpn;
    if (3 + name_len != alpn_wire.len) return error.InvalidSelectedAlpn;
    return alpn_wire[3 .. 3 + name_len];
}

pub fn offered_alpn_contains(offered_alpn_wire: []const u8, selected: []const u8) bool {
    validate_alpn_list_wire(offered_alpn_wire) catch return false;

    var pos: usize = 2;
    while (pos < offered_alpn_wire.len) {
        const protocol_len = offered_alpn_wire[pos];
        pos += 1;
        if (protocol_len == 0) return false;
        if (pos + protocol_len > offered_alpn_wire.len) return false;
        if (std.mem.eql(u8, offered_alpn_wire[pos .. pos + protocol_len], selected)) return true;
        pos += protocol_len;
    }

    return false;
}

test "validate alpn list wire" {
    try std.testing.expectError(error.InvalidAlpnWire, validate_alpn_list_wire(&[_]u8{0x00}));
    try std.testing.expectError(error.InvalidAlpnWire, validate_alpn_list_wire(&[_]u8{ 0x00, 0x02, 0x01 }));
    try validate_alpn_list_wire(&[_]u8{ 0x00, 0x02, 0x01, 'h' });
}

test "parse selected alpn" {
    const wire = [_]u8{ 0x00, 0x03, 0x02, 'h', '3' };
    const selected = try parse_selected_alpn(&wire);
    try std.testing.expectEqualStrings("h3", selected);
}

test "offered alpn contains helper" {
    const offered = [_]u8{ 0x00, 0x06, 0x02, 'h', '2', 0x02, 'h', '3' };
    try std.testing.expect(offered_alpn_contains(&offered, "h3"));
    try std.testing.expect(!offered_alpn_contains(&offered, "h1"));
}
