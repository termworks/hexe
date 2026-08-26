const std = @import("std");
const testing = std.testing;
const liblink = @import("../../liblink.zig");

fn publicKeyValidator(username: []const u8, algorithm: []const u8, public_key_blob: []const u8) bool {
    _ = public_key_blob;
    return std.mem.eql(u8, username, "testuser") and std.mem.eql(u8, algorithm, "ssh-ed25519");
}

fn encodePublicKeyBlob(allocator: std.mem.Allocator, public_key: *const [32]u8) ![]u8 {
    const alg = "ssh-ed25519";
    const size = 4 + alg.len + 4 + public_key.len;
    const blob = try allocator.alloc(u8, size);
    errdefer allocator.free(blob);

    var writer = liblink.protocol.wire.Writer{ .buffer = blob };
    try writer.writeString(alg);
    try writer.writeString(public_key);
    return blob;
}

test "Integration: publickey auth two-step roundtrip" {
    const allocator = testing.allocator;

    const ed = std.crypto.sign.Ed25519.KeyPair.generate();
    var private_key: [64]u8 = undefined;
    @memcpy(&private_key, &ed.secret_key.bytes);

    const pub_blob = try encodePublicKeyBlob(allocator, &ed.public_key.bytes);
    defer allocator.free(pub_blob);

    var client = liblink.auth.client.AuthClient.init(allocator, "testuser");
    var server = liblink.auth.dispatcher.AuthServer.init(allocator);
    server.setPublicKeyValidator(publicKeyValidator);

    // Step 1: query (no signature) -> PK_OK
    const query = try client.authenticatePublicKey("ssh-ed25519", pub_blob, null, "exchange_hash");
    defer allocator.free(query);

    var query_resp = try server.processRequest(query, "exchange_hash");
    defer query_resp.deinit(allocator);
    try testing.expect(!query_resp.success);
    try testing.expectEqual(@as(u8, liblink.common.constants.SSH_MSG.USERAUTH_PK_OK), query_resp.data[0]);

    var query_result = try client.processResponse(query_resp.data);
    defer query_result.deinit(allocator);
    try testing.expect(query_result == .pk_ok);

    // Step 2: signed request -> SUCCESS
    const signed = try client.authenticatePublicKey("ssh-ed25519", pub_blob, &private_key, "exchange_hash");
    defer allocator.free(signed);

    var signed_resp = try server.processRequest(signed, "exchange_hash");
    defer signed_resp.deinit(allocator);
    try testing.expect(signed_resp.success);

    var signed_result = try client.processResponse(signed_resp.data);
    defer signed_result.deinit(allocator);
    try testing.expect(signed_result == .success);
}
