const std = @import("std");

pub fn getContainerIpv4Addr(container_id: []const u8) [4]u8 {
    return getContainerIpv4AddrAttempt(container_id, 0);
}

pub fn getContainerIpv4AddrAttempt(container_id: []const u8, attempt: usize) [4]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(container_id);
    const hash = hasher.final();

    // 10.0.0.1 is reserved for the bridge gateway.
    const start: usize = @intCast(hash % 253);
    const host_octet: u8 = @intCast(((start + attempt) % 253) + 2);
    return .{ 10, 0, 0, host_octet };
}

test "getContainerIpv4Addr is deterministic per container id" {
    const a = getContainerIpv4Addr("container-a");
    const b = getContainerIpv4Addr("container-a");
    try std.testing.expectEqual(a, b);
}

test "getContainerIpv4Addr reserves network and gateway octets" {
    const addr = getContainerIpv4Addr("container-b");
    try std.testing.expectEqual(@as(u8, 10), addr[0]);
    try std.testing.expectEqual(@as(u8, 0), addr[1]);
    try std.testing.expectEqual(@as(u8, 0), addr[2]);
    try std.testing.expect(addr[3] >= 2 and addr[3] <= 254);
}

test "getContainerIpv4AddrAttempt rotates within host range" {
    const a = getContainerIpv4AddrAttempt("container-c", 0);
    const b = getContainerIpv4AddrAttempt("container-c", 1);
    try std.testing.expect(a[3] >= 2 and a[3] <= 254);
    try std.testing.expect(b[3] >= 2 and b[3] <= 254);
    try std.testing.expect(a[3] != b[3]);
}

test "getContainerIpv4AddrAttempt wraps after pool size" {
    const a = getContainerIpv4AddrAttempt("container-d", 0);
    const b = getContainerIpv4AddrAttempt("container-d", 253);
    try std.testing.expectEqual(a, b);
}
