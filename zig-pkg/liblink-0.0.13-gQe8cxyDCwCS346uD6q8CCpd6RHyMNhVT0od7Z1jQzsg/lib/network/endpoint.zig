const std = @import("std");

pub const ParsedEndpoint = struct {
    username: []const u8,
    host: []const u8,
    port: u16,
};

/// Parse endpoint forms:
/// - host
/// - host:port
/// - user@host
/// - user@host:port
/// - user@[ipv6]:port
/// - [ipv6]:port
/// - ipv6 (without port)
pub fn parseUserHostPort(input: []const u8, default_user: []const u8, default_port: u16) !ParsedEndpoint {
    var username = default_user;
    var host_part = input;

    if (std.mem.indexOfScalar(u8, input, '@')) |at_pos| {
        username = input[0..at_pos];
        host_part = input[at_pos + 1 ..];
        if (username.len == 0) return error.InvalidUsername;
    }

    if (host_part.len == 0) return error.InvalidHost;

    var host = host_part;
    var port = default_port;

    if (host_part[0] == '[') {
        const close_bracket = std.mem.indexOfScalar(u8, host_part, ']') orelse return error.InvalidHost;
        host = host_part[1..close_bracket];
        if (close_bracket + 1 < host_part.len) {
            if (host_part[close_bracket + 1] != ':') return error.InvalidHost;
            const port_str = host_part[close_bracket + 2 ..];
            if (port_str.len == 0) return error.InvalidPort;
            port = try std.fmt.parseInt(u16, port_str, 10);
        }
    } else {
        var colon_count: usize = 0;
        for (host_part) |ch| {
            if (ch == ':') colon_count += 1;
        }

        if (colon_count == 1) {
            const colon_pos = std.mem.lastIndexOfScalar(u8, host_part, ':').?;
            host = host_part[0..colon_pos];
            const port_str = host_part[colon_pos + 1 ..];
            if (host.len == 0 or port_str.len == 0) return error.InvalidPort;
            port = try std.fmt.parseInt(u16, port_str, 10);
        } else {
            // No port delimiter or IPv6 literal without brackets.
            host = host_part;
        }
    }

    if (host.len == 0) return error.InvalidHost;

    return .{
        .username = username,
        .host = host,
        .port = port,
    };
}

test "endpoint parser basic cases" {
    const testing = std.testing;

    const a = try parseUserHostPort("user@example.com:2222", "root", 22);
    try testing.expectEqualStrings("user", a.username);
    try testing.expectEqualStrings("example.com", a.host);
    try testing.expectEqual(@as(u16, 2222), a.port);

    const b = try parseUserHostPort("example.com", "root", 22);
    try testing.expectEqualStrings("root", b.username);
    try testing.expectEqualStrings("example.com", b.host);
    try testing.expectEqual(@as(u16, 22), b.port);

    const c = try parseUserHostPort("[2001:db8::1]:2222", "root", 22);
    try testing.expectEqualStrings("root", c.username);
    try testing.expectEqualStrings("2001:db8::1", c.host);
    try testing.expectEqual(@as(u16, 2222), c.port);
}
