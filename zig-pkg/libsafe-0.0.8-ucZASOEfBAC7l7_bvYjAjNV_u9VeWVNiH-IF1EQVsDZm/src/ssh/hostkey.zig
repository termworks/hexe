const std = @import("std");
const ssh_algorithms = @import("algorithms.zig");

pub const HostKeyError = error{
    InvalidSignatureBlob,
    InvalidHostKeyBlob,
    InvalidSignatureLength,
    InvalidPublicKeyLength,
    UnsupportedAlgorithm,
    BlobTooLarge,
    TrailingData,
};

pub const MAX_SSH_BLOB_FIELD_LENGTH: usize = 1024 * 1024;

pub fn encode_ed25519_signature_blob(
    allocator: std.mem.Allocator,
    signature: *const [64]u8,
) ![]u8 {
    const algorithm = ssh_algorithms.SignatureAlgorithm.ssh_ed25519.name();
    const blob_size = 4 + algorithm.len + 4 + signature.len;
    const signature_blob = try allocator.alloc(u8, blob_size);
    errdefer allocator.free(signature_blob);

    var offset: usize = 0;
    std.mem.writeInt(u32, signature_blob[offset..][0..4], @intCast(algorithm.len), .big);
    offset += 4;
    @memcpy(signature_blob[offset .. offset + algorithm.len], algorithm);
    offset += algorithm.len;

    std.mem.writeInt(u32, signature_blob[offset..][0..4], @intCast(signature.len), .big);
    offset += 4;
    @memcpy(signature_blob[offset .. offset + signature.len], signature);

    return signature_blob;
}

pub fn decode_ed25519_signature_blob(blob: []const u8) HostKeyError![64]u8 {
    return decode_ed25519_signature_blob_internal(blob, false);
}

fn decode_ed25519_signature_blob_internal(blob: []const u8, strict: bool) HostKeyError![64]u8 {
    var offset: usize = 0;

    const algorithm = try read_ssh_field(blob, &offset, error.InvalidSignatureBlob);

    if (!std.mem.eql(u8, algorithm, ssh_algorithms.SignatureAlgorithm.ssh_ed25519.name())) return error.UnsupportedAlgorithm;

    const signature_slice = try read_ssh_field(blob, &offset, error.InvalidSignatureBlob);

    if (signature_slice.len != 64) return error.InvalidSignatureLength;
    if (strict and offset != blob.len) return error.TrailingData;

    var signature: [64]u8 = undefined;
    @memcpy(&signature, signature_slice);
    return signature;
}

pub fn decode_ed25519_signature_blob_strict(blob: []const u8) HostKeyError![64]u8 {
    return decode_ed25519_signature_blob_internal(blob, true);
}

pub fn encode_ed25519_host_key_blob(
    allocator: std.mem.Allocator,
    public_key: *const [32]u8,
) ![]u8 {
    const algorithm = ssh_algorithms.HostKeyAlgorithm.ssh_ed25519.name();
    const blob_size = 4 + algorithm.len + 4 + public_key.len;
    const host_key_blob = try allocator.alloc(u8, blob_size);
    errdefer allocator.free(host_key_blob);

    var offset: usize = 0;
    std.mem.writeInt(u32, host_key_blob[offset..][0..4], @intCast(algorithm.len), .big);
    offset += 4;
    @memcpy(host_key_blob[offset .. offset + algorithm.len], algorithm);
    offset += algorithm.len;

    std.mem.writeInt(u32, host_key_blob[offset..][0..4], @intCast(public_key.len), .big);
    offset += 4;
    @memcpy(host_key_blob[offset .. offset + public_key.len], public_key);

    return host_key_blob;
}

pub fn decode_ed25519_host_key_blob(blob: []const u8) HostKeyError![32]u8 {
    return decode_ed25519_host_key_blob_internal(blob, false);
}

fn decode_ed25519_host_key_blob_internal(blob: []const u8, strict: bool) HostKeyError![32]u8 {
    var offset: usize = 0;

    const algorithm = try read_ssh_field(blob, &offset, error.InvalidHostKeyBlob);

    if (!std.mem.eql(u8, algorithm, ssh_algorithms.HostKeyAlgorithm.ssh_ed25519.name())) return error.UnsupportedAlgorithm;

    const public_key_slice = try read_ssh_field(blob, &offset, error.InvalidHostKeyBlob);

    if (public_key_slice.len != 32) return error.InvalidPublicKeyLength;
    if (strict and offset != blob.len) return error.TrailingData;

    var public_key: [32]u8 = undefined;
    @memcpy(&public_key, public_key_slice);
    return public_key;
}

pub fn decode_ed25519_host_key_blob_strict(blob: []const u8) HostKeyError![32]u8 {
    return decode_ed25519_host_key_blob_internal(blob, true);
}

pub fn validate_ed25519_host_key_blob(blob: []const u8) HostKeyError!void {
    _ = try decode_ed25519_host_key_blob_strict(blob);
}

pub fn validate_ed25519_signature_blob(blob: []const u8) HostKeyError!void {
    _ = try decode_ed25519_signature_blob_strict(blob);
}

fn read_ssh_field(
    blob: []const u8,
    offset: *usize,
    invalid_error: HostKeyError,
) HostKeyError![]const u8 {
    if (offset.* + 4 > blob.len) return invalid_error;
    const field_len_u32 = std.mem.readInt(u32, blob[offset.*..][0..4], .big);
    offset.* += 4;

    const field_len: usize = field_len_u32;
    if (field_len > MAX_SSH_BLOB_FIELD_LENGTH) return error.BlobTooLarge;
    if (field_len > blob.len - offset.*) return invalid_error;

    const field = blob[offset.* .. offset.* + field_len];
    offset.* += field_len;
    return field;
}

pub fn fingerprint_sha256(allocator: std.mem.Allocator, host_key_blob: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(host_key_blob, &digest, .{});

    const b64_len = std.base64.standard.Encoder.calcSize(digest.len);
    const b64 = try allocator.alloc(u8, b64_len);
    defer allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, &digest);

    return std.fmt.allocPrint(allocator, "SHA256:{s}", .{b64});
}

test "host key blob roundtrip" {
    const allocator = std.testing.allocator;
    const public_key: [32]u8 = [_]u8{0x11} ** 32;

    const blob = try encode_ed25519_host_key_blob(allocator, &public_key);
    defer allocator.free(blob);

    const decoded = try decode_ed25519_host_key_blob(blob);
    try std.testing.expectEqualSlices(u8, &public_key, &decoded);
}

test "strict host key validator rejects trailing bytes" {
    const allocator = std.testing.allocator;
    const public_key: [32]u8 = [_]u8{0xA5} ** 32;

    const blob = try encode_ed25519_host_key_blob(allocator, &public_key);
    defer allocator.free(blob);

    const padded = try allocator.alloc(u8, blob.len + 1);
    defer allocator.free(padded);
    @memcpy(padded[0..blob.len], blob);
    padded[padded.len - 1] = 0xFF;

    _ = try decode_ed25519_host_key_blob(padded);
    try std.testing.expectError(error.TrailingData, decode_ed25519_host_key_blob_strict(padded));
    try std.testing.expectError(error.TrailingData, validate_ed25519_host_key_blob(padded));
}

test "strict signature validator rejects trailing bytes" {
    const allocator = std.testing.allocator;
    const signature: [64]u8 = [_]u8{0x5A} ** 64;

    const blob = try encode_ed25519_signature_blob(allocator, &signature);
    defer allocator.free(blob);

    const padded = try allocator.alloc(u8, blob.len + 1);
    defer allocator.free(padded);
    @memcpy(padded[0..blob.len], blob);
    padded[padded.len - 1] = 0xFF;

    _ = try decode_ed25519_signature_blob(padded);
    try std.testing.expectError(error.TrailingData, decode_ed25519_signature_blob_strict(padded));
    try std.testing.expectError(error.TrailingData, validate_ed25519_signature_blob(padded));
}

test "host key decode rejects oversized algorithm field" {
    var blob: [4]u8 = [_]u8{0x00} ** 4;
    std.mem.writeInt(u32, blob[0..4], @intCast(MAX_SSH_BLOB_FIELD_LENGTH + 1), .big);
    try std.testing.expectError(error.BlobTooLarge, decode_ed25519_host_key_blob(blob[0..]));
}

test "signature decode rejects oversized algorithm field" {
    var blob: [4]u8 = [_]u8{0x00} ** 4;
    std.mem.writeInt(u32, blob[0..4], @intCast(MAX_SSH_BLOB_FIELD_LENGTH + 1), .big);
    try std.testing.expectError(error.BlobTooLarge, decode_ed25519_signature_blob(blob[0..]));
}

test "strict validators accept valid host key and signature blobs" {
    const allocator = std.testing.allocator;
    const public_key: [32]u8 = [_]u8{0x12} ** 32;
    const signature: [64]u8 = [_]u8{0x34} ** 64;

    const host_key_blob = try encode_ed25519_host_key_blob(allocator, &public_key);
    defer allocator.free(host_key_blob);
    const signature_blob = try encode_ed25519_signature_blob(allocator, &signature);
    defer allocator.free(signature_blob);

    try validate_ed25519_host_key_blob(host_key_blob);
    try validate_ed25519_signature_blob(signature_blob);
}

test "strict decoders reject unsupported algorithm names" {
    const allocator = std.testing.allocator;

    const host_blob = try allocator.alloc(u8, 4 + 7 + 4 + 32);
    defer allocator.free(host_blob);
    std.mem.writeInt(u32, host_blob[0..4], 7, .big);
    @memcpy(host_blob[4..11], "ssh-rsa");
    std.mem.writeInt(u32, host_blob[11..15], 32, .big);
    @memset(host_blob[15..47], 0xAA);

    const sig_blob = try allocator.alloc(u8, 4 + 7 + 4 + 64);
    defer allocator.free(sig_blob);
    std.mem.writeInt(u32, sig_blob[0..4], 7, .big);
    @memcpy(sig_blob[4..11], "ssh-rsa");
    std.mem.writeInt(u32, sig_blob[11..15], 64, .big);
    @memset(sig_blob[15..79], 0xBB);

    try std.testing.expectError(error.UnsupportedAlgorithm, decode_ed25519_host_key_blob_strict(host_blob));
    try std.testing.expectError(error.UnsupportedAlgorithm, decode_ed25519_signature_blob_strict(sig_blob));
}

test "host key fingerprint is deterministic and prefixed" {
    const allocator = std.testing.allocator;
    const public_key: [32]u8 = [_]u8{0x77} ** 32;

    const host_key_blob = try encode_ed25519_host_key_blob(allocator, &public_key);
    defer allocator.free(host_key_blob);

    const a = try fingerprint_sha256(allocator, host_key_blob);
    defer allocator.free(a);
    const b = try fingerprint_sha256(allocator, host_key_blob);
    defer allocator.free(b);

    try std.testing.expect(std.mem.startsWith(u8, a, "SHA256:"));
    try std.testing.expectEqualStrings(a, b);
}
