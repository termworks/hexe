const std = @import("std");
const ssh_hostkey = @import("hostkey.zig");
const ssh_signature = @import("signature.zig");

pub const AuthCryptoError = error{
    SignatureBlobMalformed,
    SignatureAlgorithmMismatch,
    SignatureLengthInvalid,
    HostKeyBlobMalformed,
    HostKeyAlgorithmMismatch,
    PublicKeyLengthInvalid,
    VerificationFailed,
    OutOfMemory,
};

pub fn create_ed25519_auth_signature_blob(
    allocator: std.mem.Allocator,
    payload: []const u8,
    private_key: *const [64]u8,
) AuthCryptoError![]u8 {
    const raw_signature = ssh_signature.sign(payload, private_key) catch {
        return error.SignatureBlobMalformed;
    };

    return ssh_hostkey.encode_ed25519_signature_blob(allocator, &raw_signature) catch {
        return error.OutOfMemory;
    };
}

pub fn verify_ed25519_auth_signature_blob(
    payload: []const u8,
    signature_blob: []const u8,
    public_key: []const u8,
) AuthCryptoError!void {
    if (public_key.len != 32) return error.PublicKeyLengthInvalid;

    const decoded_signature = ssh_hostkey.decode_ed25519_signature_blob_strict(signature_blob) catch |err| {
        return switch (err) {
            error.UnsupportedAlgorithm => error.SignatureAlgorithmMismatch,
            error.InvalidSignatureLength => error.SignatureLengthInvalid,
            error.InvalidSignatureBlob, error.BlobTooLarge, error.TrailingData => error.SignatureBlobMalformed,
            else => error.SignatureBlobMalformed,
        };
    };

    var public_key_fixed: [32]u8 = undefined;
    @memcpy(&public_key_fixed, public_key);

    if (!ssh_signature.verify_ed25519(payload, &decoded_signature, &public_key_fixed)) {
        return error.VerificationFailed;
    }
}

pub fn verify_ed25519_auth_signature_with_host_key_blob(
    payload: []const u8,
    signature_blob: []const u8,
    host_key_blob: []const u8,
) AuthCryptoError!void {
    const decoded_public_key = ssh_hostkey.decode_ed25519_host_key_blob_strict(host_key_blob) catch |err| {
        return switch (err) {
            error.UnsupportedAlgorithm => error.HostKeyAlgorithmMismatch,
            error.InvalidPublicKeyLength, error.InvalidHostKeyBlob, error.BlobTooLarge, error.TrailingData => error.HostKeyBlobMalformed,
            else => error.HostKeyBlobMalformed,
        };
    };

    return verify_ed25519_auth_signature_blob(payload, signature_blob, &decoded_public_key);
}

pub fn timing_safe_equal(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;

    var diff: u8 = 0;
    for (a, b) |av, bv| {
        diff |= av ^ bv;
    }
    return diff == 0;
}

test "auth signature blob create and verify" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(1234);
    const kp = ssh_signature.KeyPair.generate(prng.random());
    const payload = "ssh-userauth-request";

    const blob = try create_ed25519_auth_signature_blob(allocator, payload, &kp.private_key);
    defer allocator.free(blob);

    try verify_ed25519_auth_signature_blob(payload, blob, &kp.public_key);
}

test "auth signature verify rejects unsupported algorithm" {
    const allocator = std.testing.allocator;
    const bad_blob = try allocator.alloc(u8, 4 + 7 + 4 + 64);
    defer allocator.free(bad_blob);

    var offset: usize = 0;
    std.mem.writeInt(u32, bad_blob[offset..][0..4], 7, .big);
    offset += 4;
    @memcpy(bad_blob[offset .. offset + 7], "ssh-rsa");
    offset += 7;
    std.mem.writeInt(u32, bad_blob[offset..][0..4], 64, .big);
    offset += 4;
    @memset(bad_blob[offset .. offset + 64], 0xAA);

    const pk: [32]u8 = [_]u8{0x11} ** 32;
    try std.testing.expectError(
        error.SignatureAlgorithmMismatch,
        verify_ed25519_auth_signature_blob("payload", bad_blob, &pk),
    );
}

test "auth signature verify rejects malformed trailing bytes" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(77);
    const kp = ssh_signature.KeyPair.generate(prng.random());
    const payload = "auth-payload";

    const blob = try create_ed25519_auth_signature_blob(allocator, payload, &kp.private_key);
    defer allocator.free(blob);

    const padded = try allocator.alloc(u8, blob.len + 1);
    defer allocator.free(padded);
    @memcpy(padded[0..blob.len], blob);
    padded[padded.len - 1] = 0xEE;

    try std.testing.expectError(
        error.SignatureBlobMalformed,
        verify_ed25519_auth_signature_blob(payload, padded, &kp.public_key),
    );
}

test "auth signature verify maps invalid signature length" {
    const allocator = std.testing.allocator;
    const bad_blob = try allocator.alloc(u8, 4 + 11 + 4 + 63);
    defer allocator.free(bad_blob);

    var offset: usize = 0;
    std.mem.writeInt(u32, bad_blob[offset..][0..4], 11, .big);
    offset += 4;
    @memcpy(bad_blob[offset .. offset + 11], "ssh-ed25519");
    offset += 11;
    std.mem.writeInt(u32, bad_blob[offset..][0..4], 63, .big);
    offset += 4;
    @memset(bad_blob[offset .. offset + 63], 0xBB);

    const pk: [32]u8 = [_]u8{0x33} ** 32;
    try std.testing.expectError(
        error.SignatureLengthInvalid,
        verify_ed25519_auth_signature_blob("payload", bad_blob, &pk),
    );
}

test "auth signature verify rejects wrong payload and public key size" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(91);
    const kp = ssh_signature.KeyPair.generate(prng.random());

    const blob = try create_ed25519_auth_signature_blob(allocator, "right", &kp.private_key);
    defer allocator.free(blob);

    try std.testing.expectError(
        error.VerificationFailed,
        verify_ed25519_auth_signature_blob("wrong", blob, &kp.public_key),
    );

    try std.testing.expectError(
        error.PublicKeyLengthInvalid,
        verify_ed25519_auth_signature_blob("right", blob, "short"),
    );
}

test "auth signature verify with host key blob happy path" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(991);
    const kp = ssh_signature.KeyPair.generate(prng.random());
    const payload = "userauth payload";

    const signature_blob = try create_ed25519_auth_signature_blob(allocator, payload, &kp.private_key);
    defer allocator.free(signature_blob);

    const host_key_blob = try ssh_hostkey.encode_ed25519_host_key_blob(allocator, &kp.public_key);
    defer allocator.free(host_key_blob);

    try verify_ed25519_auth_signature_with_host_key_blob(payload, signature_blob, host_key_blob);
}

test "auth signature verify with host key blob rejects malformed blob" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(101);
    const kp = ssh_signature.KeyPair.generate(prng.random());

    const signature_blob = try create_ed25519_auth_signature_blob(allocator, "payload", &kp.private_key);
    defer allocator.free(signature_blob);

    const host_key_blob = try ssh_hostkey.encode_ed25519_host_key_blob(allocator, &kp.public_key);
    defer allocator.free(host_key_blob);

    const padded = try allocator.alloc(u8, host_key_blob.len + 1);
    defer allocator.free(padded);
    @memcpy(padded[0..host_key_blob.len], host_key_blob);
    padded[padded.len - 1] = 0x01;

    try std.testing.expectError(
        error.HostKeyBlobMalformed,
        verify_ed25519_auth_signature_with_host_key_blob("payload", signature_blob, padded),
    );
}

test "auth signature verify with host key blob rejects algorithm mismatch" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(202);
    const kp = ssh_signature.KeyPair.generate(prng.random());

    const signature_blob = try create_ed25519_auth_signature_blob(allocator, "payload", &kp.private_key);
    defer allocator.free(signature_blob);

    const bad_host_key_blob = try allocator.alloc(u8, 4 + 7 + 4 + 32);
    defer allocator.free(bad_host_key_blob);

    var offset: usize = 0;
    std.mem.writeInt(u32, bad_host_key_blob[offset..][0..4], 7, .big);
    offset += 4;
    @memcpy(bad_host_key_blob[offset .. offset + 7], "ssh-rsa");
    offset += 7;
    std.mem.writeInt(u32, bad_host_key_blob[offset..][0..4], 32, .big);
    offset += 4;
    @memcpy(bad_host_key_blob[offset .. offset + 32], &kp.public_key);

    try std.testing.expectError(
        error.HostKeyAlgorithmMismatch,
        verify_ed25519_auth_signature_with_host_key_blob("payload", signature_blob, bad_host_key_blob),
    );
}

test "auth signature verify with host key blob rejects wrong payload" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(303);
    const kp = ssh_signature.KeyPair.generate(prng.random());

    const signature_blob = try create_ed25519_auth_signature_blob(allocator, "right-payload", &kp.private_key);
    defer allocator.free(signature_blob);

    const host_key_blob = try ssh_hostkey.encode_ed25519_host_key_blob(allocator, &kp.public_key);
    defer allocator.free(host_key_blob);

    try std.testing.expectError(
        error.VerificationFailed,
        verify_ed25519_auth_signature_with_host_key_blob("wrong-payload", signature_blob, host_key_blob),
    );
}

test "auth signature verify with host key blob maps signature format errors" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(404);
    const kp = ssh_signature.KeyPair.generate(prng.random());

    const host_key_blob = try ssh_hostkey.encode_ed25519_host_key_blob(allocator, &kp.public_key);
    defer allocator.free(host_key_blob);

    const malformed_signature_blob = [_]u8{ 0x00, 0x00, 0x00, 0x0B, 's', 's', 'h', '-', 'e', 'd', '2' };
    try std.testing.expectError(
        error.SignatureBlobMalformed,
        verify_ed25519_auth_signature_with_host_key_blob("payload", &malformed_signature_blob, host_key_blob),
    );
}

test "timing safe equal utility" {
    const a = [_]u8{ 1, 2, 3, 4 };
    const b = [_]u8{ 1, 2, 3, 4 };
    const c = [_]u8{ 1, 2, 3, 5 };

    try std.testing.expect(timing_safe_equal(&a, &b));
    try std.testing.expect(!timing_safe_equal(&a, &c));
    try std.testing.expect(!timing_safe_equal("x", "xy"));
}
