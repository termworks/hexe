const std = @import("std");
const keyfile = @import("keyfile.zig");
const connection = @import("../connection.zig");
const wire = @import("../protocol/wire.zig");

pub const ClientAuthOptions = struct {
    identity_path: ?[]const u8 = null,
};

/// Build SSH public key blob: string(algorithm) + string(public_key)
pub fn encodePublicKeyBlob(
    allocator: std.mem.Allocator,
    algorithm_name: []const u8,
    public_key: []const u8,
) ![]u8 {
    const size = 4 + algorithm_name.len + 4 + public_key.len;
    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    var writer = wire.Writer{ .buffer = buffer };
    try writer.writeString(algorithm_name);
    try writer.writeString(public_key);
    return buffer;
}

/// Authenticate using public key identity.
pub fn authenticateClient(
    allocator: std.mem.Allocator,
    conn: *connection.ClientConnection,
    username: []const u8,
    options: ClientAuthOptions,
) !bool {
    if (options.identity_path) |path| {
        var parsed = try keyfile.parsePrivateKeyFile(allocator, path);
        defer parsed.deinit();

        if (parsed.key_type != .ed25519) {
            return error.UnsupportedKeyType;
        }
        if (parsed.public_key.len != 32 or parsed.private_key.len != 64) {
            return error.InvalidKeyMaterial;
        }

        var private_key: [64]u8 = undefined;
        defer std.crypto.secureZero(u8, &private_key);
        @memcpy(&private_key, parsed.private_key[0..64]);

        const public_key_blob = try encodePublicKeyBlob(allocator, parsed.algorithm_name, parsed.public_key);
        defer allocator.free(public_key_blob);

        const key_authed = try conn.authenticatePublicKey(
            username,
            parsed.algorithm_name,
            public_key_blob,
            &private_key,
        );
        if (key_authed) return true;
    }

    return error.NoIdentityProvided;
}

test "encodePublicKeyBlob encodes SSH wire strings" {
    const allocator = std.testing.allocator;

    const algorithm = "ssh-ed25519";
    const pubkey = [_]u8{ 1, 2, 3, 4, 5, 6 };

    const blob = try encodePublicKeyBlob(allocator, algorithm, &pubkey);
    defer allocator.free(blob);

    var reader = wire.Reader{ .buffer = blob };
    const decoded_algorithm = try reader.readString(allocator);
    defer allocator.free(decoded_algorithm);
    const decoded_pubkey = try reader.readString(allocator);
    defer allocator.free(decoded_pubkey);

    try std.testing.expectEqualStrings(algorithm, decoded_algorithm);
    try std.testing.expectEqualSlices(u8, &pubkey, decoded_pubkey);
    try std.testing.expectEqual(@as(usize, blob.len), reader.position);
}

test "encodePublicKeyBlob handles empty public key" {
    const allocator = std.testing.allocator;

    const blob = try encodePublicKeyBlob(allocator, "ssh-ed25519", "");
    defer allocator.free(blob);

    var reader = wire.Reader{ .buffer = blob };
    const decoded_algorithm = try reader.readString(allocator);
    defer allocator.free(decoded_algorithm);
    const decoded_pubkey = try reader.readString(allocator);
    defer allocator.free(decoded_pubkey);

    try std.testing.expectEqualStrings("ssh-ed25519", decoded_algorithm);
    try std.testing.expectEqual(@as(usize, 0), decoded_pubkey.len);
}

test "authenticateClient rejects missing identity path" {
    const allocator = std.testing.allocator;

    var fake_conn: connection.ClientConnection = undefined;
    const err = authenticateClient(allocator, &fake_conn, "alice", .{}) catch |e| e;
    try std.testing.expectEqual(error.NoIdentityProvided, err);
}
