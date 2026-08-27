const std = @import("std");
const testing = std.testing;
const liblink = @import("../../liblink.zig");

fn chooseTestPort() u16 {
    const ts: u64 = @intCast(std.time.nanoTimestamp());
    const base: u16 = 42000;
    return base + @as(u16, @intCast(ts % 1500));
}

fn encodeHostKeyBlob(allocator: std.mem.Allocator, public_key: *const [32]u8) ![]u8 {
    const alg = "ssh-ed25519";
    const size = 4 + alg.len + 4 + 32;
    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    var writer = liblink.protocol.wire.Writer{ .buffer = buffer };
    try writer.writeString(alg);
    try writer.writeString(public_key);
    return buffer;
}

test "Integration: listener shutdown rejects acceptConnection" {
    const allocator = testing.allocator;
    const port = chooseTestPort();

    const ed_keypair = std.crypto.sign.Ed25519.KeyPair.generate();
    var host_private_key: [64]u8 = undefined;
    @memcpy(&host_private_key, &ed_keypair.secret_key.bytes);

    const host_key_blob = try encodeHostKeyBlob(allocator, &ed_keypair.public_key.bytes);
    defer allocator.free(host_key_blob);

    var prng = std.Random.DefaultPrng.init(0x4455_6677);
    const random = prng.random();

    var listener = try liblink.connection.startServer(
        allocator,
        "127.0.0.1",
        port,
        host_key_blob,
        &host_private_key,
        random,
    );
    defer listener.deinit();

    try testing.expectEqual(@as(usize, 0), listener.getActiveConnectionCount());

    listener.shutdown();
    try testing.expectError(error.ServerShutdown, listener.acceptConnection());
}
