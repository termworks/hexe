const std = @import("std");
const Allocator = std.mem.Allocator;

/// SSH Key File Parser
///
/// Parses OpenSSH private key files (id_ed25519, id_rsa, etc.)
/// Supports the modern OpenSSH format and Ed25519/RSA keys.

pub const KeyType = enum {
    ed25519,
    rsa,
    ecdsa,
    unknown,
};

pub const ParsedKey = struct {
    key_type: KeyType,
    algorithm_name: []const u8,
    public_key: []const u8,
    private_key: []const u8,
    allocator: Allocator,

    pub fn deinit(self: *ParsedKey) void {
        self.allocator.free(self.algorithm_name);
        self.allocator.free(self.public_key);
        self.allocator.free(self.private_key);
    }
};

/// Parse OpenSSH private key file
///
/// Supports:
/// - Ed25519 keys (id_ed25519)
/// - RSA keys (id_rsa)
///
/// Format: OpenSSH private key format (RFC 4716 style)
pub fn parsePrivateKeyFile(allocator: Allocator, file_path: []const u8) !ParsedKey {
    // Read the key file
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024); // Max 1MB
    defer allocator.free(content);

    return try parsePrivateKey(allocator, content);
}

/// Parse OpenSSH private key from content
pub fn parsePrivateKey(allocator: Allocator, content: []const u8) !ParsedKey {
    // Check for OpenSSH format
    const openssh_header = "-----BEGIN OPENSSH PRIVATE KEY-----";
    const openssh_footer = "-----END OPENSSH PRIVATE KEY-----";

    if (!std.mem.startsWith(u8, content, openssh_header)) {
        return error.UnsupportedKeyFormat;
    }

    // Find the key data between headers
    const data_start = std.mem.indexOf(u8, content, openssh_header) orelse return error.InvalidKeyFile;
    const data_end = std.mem.indexOf(u8, content, openssh_footer) orelse return error.InvalidKeyFile;

    const base64_data = content[data_start + openssh_header.len .. data_end];

    // Strip whitespace/newlines and decode base64 as a single block
    var stripped = std.ArrayListUnmanaged(u8){};
    defer stripped.deinit(allocator);

    for (base64_data) |ch| {
        if (ch != '\n' and ch != '\r' and ch != ' ' and ch != '\t') {
            try stripped.append(allocator, ch);
        }
    }

    const decoder = std.base64.standard.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(stripped.items);
    var decoded_buf = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded_buf);
    try decoder.decode(decoded_buf, stripped.items);

    var decoded = std.ArrayListUnmanaged(u8){};
    defer decoded.deinit(allocator);
    try decoded.appendSlice(allocator, decoded_buf[0..decoded_len]);

    // Parse the OpenSSH key format
    return try parseOpenSSHKeyBlob(allocator, decoded.items);
}

/// Parse OpenSSH key blob structure
fn parseOpenSSHKeyBlob(allocator: Allocator, blob: []const u8) !ParsedKey {
    var pos: usize = 0;

    // Magic bytes: "openssh-key-v1\0"
    const magic = "openssh-key-v1\x00";
    if (pos + magic.len > blob.len or !std.mem.eql(u8, blob[pos .. pos + magic.len], magic)) {
        return error.InvalidKeyFormat;
    }
    pos += magic.len;

    // Read cipher name (should be "none" for unencrypted keys)
    const cipher = try readString(blob, &pos);
    if (!std.mem.eql(u8, cipher, "none")) {
        return error.EncryptedKeysNotSupported;
    }

    // Read KDF name (should be "none")
    const kdf = try readString(blob, &pos);
    _ = kdf;

    // Read KDF options (should be empty)
    const kdf_options = try readString(blob, &pos);
    _ = kdf_options;

    // Read number of keys (should be 1)
    const num_keys = try readUint32(blob, &pos);
    if (num_keys != 1) {
        return error.MultipleKeysNotSupported;
    }

    // Read public key
    const public_key_blob = try readString(blob, &pos);

    // Parse public key to get algorithm
    var pub_pos: usize = 0;
    const algorithm_name = try readString(public_key_blob, &pub_pos);

    // Read private key section
    const private_section = try readString(blob, &pos);

    // Parse private section
    var priv_pos: usize = 0;

    // Check1 and Check2 (should match for unencrypted keys)
    const check1 = try readUint32(private_section, &priv_pos);
    const check2 = try readUint32(private_section, &priv_pos);
    if (check1 != check2) {
        return error.CorruptedKey;
    }

    // Read algorithm name again
    const priv_algorithm = try readString(private_section, &priv_pos);
    if (!std.mem.eql(u8, algorithm_name, priv_algorithm)) {
        return error.AlgorithmMismatch;
    }

    // Determine key type and parse accordingly
    const key_type = if (std.mem.eql(u8, algorithm_name, "ssh-ed25519"))
        KeyType.ed25519
    else if (std.mem.eql(u8, algorithm_name, "ssh-rsa"))
        KeyType.rsa
    else
        KeyType.unknown;

    if (key_type == .ed25519) {
        // Ed25519: public key (32 bytes) + private key (64 bytes)
        const ed25519_public = try readString(private_section, &priv_pos);
        const ed25519_private = try readString(private_section, &priv_pos);

        return ParsedKey{
            .key_type = key_type,
            .algorithm_name = try allocator.dupe(u8, algorithm_name),
            .public_key = try allocator.dupe(u8, ed25519_public),
            .private_key = try allocator.dupe(u8, ed25519_private),
            .allocator = allocator,
        };
    } else {
        return error.UnsupportedKeyType;
    }
}

/// Read a uint32 in network byte order (big endian)
fn readUint32(data: []const u8, pos: *usize) !u32 {
    if (pos.* + 4 > data.len) return error.UnexpectedEndOfData;
    const value = std.mem.readInt(u32, data[pos.*..][0..4], .big);
    pos.* += 4;
    return value;
}

/// Read a length-prefixed string
fn readString(data: []const u8, pos: *usize) ![]const u8 {
    const len = try readUint32(data, pos);
    if (pos.* + len > data.len) return error.UnexpectedEndOfData;
    const str = data[pos.* .. pos.* + len];
    pos.* += len;
    return str;
}

// =============================================================================
// Tests
// =============================================================================

test "readUint32" {
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x05 };
    var pos: usize = 0;
    const value = try readUint32(&data, &pos);
    try std.testing.expectEqual(@as(u32, 5), value);
    try std.testing.expectEqual(@as(usize, 4), pos);
}

test "readString" {
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x05 } ++ "hello".*;
    var pos: usize = 0;
    const str = try readString(&data, &pos);
    try std.testing.expectEqualStrings("hello", str);
    try std.testing.expectEqual(@as(usize, 9), pos);
}
