const std = @import("std");

pub fn defaultPath(allocator: std.mem.Allocator) ![]u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.HomeNotSet,
        else => return err,
    };
    defer allocator.free(home);

    return std.fmt.allocPrint(allocator, "{s}/.ssh/known_hosts", .{home});
}

pub fn hostKeyForEndpoint(allocator: std.mem.Allocator, host: []const u8, port: u16) ![]u8 {
    // Bracket IPv6-style hosts to avoid ambiguity with host:port separator.
    if (std.mem.indexOfScalar(u8, host, ':') != null and !(host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']')) {
        return std.fmt.allocPrint(allocator, "[{s}]:{d}", .{ host, port });
    }
    return std.fmt.allocPrint(allocator, "{s}:{d}", .{ host, port });
}

pub fn loadFingerprintsForHost(allocator: std.mem.Allocator, host_key: []const u8) ![][]u8 {
    const path = try defaultPath(allocator);
    defer allocator.free(path);

    return loadFingerprintsForHostAtPath(allocator, path, host_key);
}

pub fn loadFingerprintsForHostAtPath(allocator: std.mem.Allocator, path: []const u8, host_key: []const u8) ![][]u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc([]u8, 0),
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 512 * 1024);
    defer allocator.free(content);

    var list = std.ArrayListUnmanaged([]u8){};
    errdefer {
        for (list.items) |fp| allocator.free(fp);
        list.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue;

        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        const host = parts.next() orelse continue;
        const fingerprint = parts.next() orelse continue;
        if (!std.mem.eql(u8, host, host_key)) continue;

        try list.append(allocator, try allocator.dupe(u8, fingerprint));
    }

    return list.toOwnedSlice(allocator);
}

pub fn freeFingerprints(allocator: std.mem.Allocator, fingerprints: [][]u8) void {
    for (fingerprints) |fp| allocator.free(fp);
    allocator.free(fingerprints);
}

pub fn addFingerprint(allocator: std.mem.Allocator, host_key: []const u8, fingerprint: []const u8) !void {
    const path = try defaultPath(allocator);
    defer allocator.free(path);

    return addFingerprintAtPath(allocator, path, host_key, fingerprint);
}

pub fn addFingerprintAtPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    host_key: []const u8,
    fingerprint: []const u8,
) !void {
    const existing = try loadFingerprintsForHostAtPath(allocator, path, host_key);
    defer freeFingerprints(allocator, existing);

    for (existing) |fp| {
        if (std.mem.eql(u8, fp, fingerprint)) return;
    }

    if (std.fs.path.dirname(path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = false });
    defer file.close();
    try file.seekFromEnd(0);

    const line = try std.fmt.allocPrint(allocator, "{s} {s}\n", .{ host_key, fingerprint });
    defer allocator.free(line);
    try file.writeAll(line);
}

test "known_hosts host key endpoint formatting" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const h1 = try hostKeyForEndpoint(allocator, "example.com", 2222);
    defer allocator.free(h1);
    try testing.expectEqualStrings("example.com:2222", h1);

    const h2 = try hostKeyForEndpoint(allocator, "2001:db8::1", 2222);
    defer allocator.free(h2);
    try testing.expectEqualStrings("[2001:db8::1]:2222", h2);
}

test "known_hosts add and load by explicit path" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/liblink-known-hosts-{}", .{std.time.nanoTimestamp()});
    defer allocator.free(tmp_path);
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    try addFingerprintAtPath(allocator, tmp_path, "example.com:2222", "SHA256:abc");
    try addFingerprintAtPath(allocator, tmp_path, "example.com:2222", "SHA256:abc"); // dedupe
    try addFingerprintAtPath(allocator, tmp_path, "example.com:2222", "SHA256:def");

    const fps = try loadFingerprintsForHostAtPath(allocator, tmp_path, "example.com:2222");
    defer freeFingerprints(allocator, fps);

    try testing.expectEqual(@as(usize, 2), fps.len);
    try testing.expectEqualStrings("SHA256:abc", fps[0]);
    try testing.expectEqualStrings("SHA256:def", fps[1]);
}
