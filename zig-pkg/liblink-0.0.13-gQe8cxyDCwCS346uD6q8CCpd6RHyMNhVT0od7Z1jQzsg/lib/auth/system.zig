const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("pwd.h");
});

/// System-level authentication
///
/// Public key authentication via ~/.ssh/authorized_keys

/// Parse authorized_keys line and extract key blob
/// Returns true if the line matches the provided algorithm and key
fn matchAuthorizedKey(
    line: []const u8,
    algorithm: []const u8,
    public_key_blob: []const u8,
    allocator: Allocator,
) bool {
    // Skip empty lines and comments
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed[0] == '#') {
        return false;
    }

    // Format: [options] keytype base64-key [comment]
    var iter = std.mem.tokenizeAny(u8, trimmed, &std.ascii.whitespace);

    // First token might be options or keytype
    const first = iter.next() orelse return false;
    const second = iter.next();

    var keytype: []const u8 = undefined;
    var base64_key: []const u8 = undefined;

    if (second == null) {
        return false;
    } else if (std.mem.indexOf(u8, first, "=") != null) {
        // First token has '=' so it's an option
        keytype = second.?;
        base64_key = iter.next() orelse return false;
    } else {
        // No options
        keytype = first;
        base64_key = second.?;
    }

    // Check if algorithm matches
    if (!std.mem.eql(u8, keytype, algorithm)) {
        return false;
    }

    // Decode base64 key
    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(base64_key) catch return false;
    const decoded = allocator.alloc(u8, decoded_size) catch return false;
    defer allocator.free(decoded);

    std.base64.standard.Decoder.decode(decoded, base64_key) catch return false;

    // Compare with provided public key blob using constant-time comparison
    if (decoded.len != public_key_blob.len) return false;
    var diff: u8 = 0;
    for (decoded, public_key_blob) |a, b| {
        diff |= a ^ b;
    }
    return diff == 0;
}

/// Validate public key against user's authorized_keys
pub fn validatePublicKey(
    username: []const u8,
    algorithm: []const u8,
    public_key_blob: []const u8,
) bool {
    var user_buf: [256]u8 = undefined;
    if (username.len >= user_buf.len) {
        return false;
    }

    @memcpy(user_buf[0..username.len], username);
    user_buf[username.len] = 0;
    const user_cstr: [*:0]const u8 = @ptrCast(&user_buf);

    // Get user's home directory
    const pwd = c.getpwnam(user_cstr);
    if (pwd == null) {
        std.log.debug("User '{s}' not found on system", .{username});
        return false;
    }

    const home_dir = std.mem.span(pwd.*.pw_dir);

    // Build path to authorized_keys
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const auth_keys_path = std.fmt.bufPrint(&path_buf, "{s}/.ssh/authorized_keys", .{home_dir}) catch {
        std.log.debug("Path too long for authorized_keys", .{});
        return false;
    };

    // Read authorized_keys file
    const file = std.fs.openFileAbsolute(auth_keys_path, .{}) catch |err| {
        std.log.debug("Failed to open authorized_keys: {}", .{err});
        return false;
    };
    defer file.close();

    var allocator = std.heap.page_allocator;

    // Read file content
    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        std.log.debug("Failed to read authorized_keys: {}", .{err});
        return false;
    };
    defer allocator.free(content);

    // Check each line
    var line_iter = std.mem.tokenizeScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        if (matchAuthorizedKey(line, algorithm, public_key_blob, allocator)) {
            std.log.info("Public key authenticated for user '{s}'", .{username});
            return true;
        }
    }

    std.log.debug("Public key not found in authorized_keys for user '{s}'", .{username});
    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "validatePublicKey - invalid user" {
    const testing = std.testing;

    const dummy_key = [_]u8{0} ** 32;
    const result = validatePublicKey("nonexistent_user_12345", "ssh-ed25519", &dummy_key);
    try testing.expect(!result);
}

test "matchAuthorizedKey - basic parsing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test comment line
    const comment = "# This is a comment";
    const result1 = matchAuthorizedKey(comment, "ssh-ed25519", "dummy", allocator);
    try testing.expect(!result1);

    // Test empty line
    const empty = "   ";
    const result2 = matchAuthorizedKey(empty, "ssh-ed25519", "dummy", allocator);
    try testing.expect(!result2);
}
