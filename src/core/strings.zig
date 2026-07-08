const std = @import("std");

/// Sanitize a string for use in filesystem/socket paths.
/// Keeps alphanumeric, underscore, hyphen, and dot. Replaces others with underscore.
/// Returns slice of out buffer containing sanitized result.
pub fn sanitize(out: []u8, raw: []const u8, max_len: usize) []const u8 {
    const limit: usize = @min(out.len, max_len);
    var n: usize = 0;
    for (raw) |ch| {
        if (n >= limit) break;
        const ok = (ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or
            ch == '_' or ch == '-' or ch == '.';
        out[n] = if (ok) ch else '_';
        n += 1;
    }
    return out[0..n];
}

/// Sanitize with fallback value if result is empty.
pub fn sanitizeWithFallback(out: []u8, raw: []const u8, max_len: usize, fallback: []const u8) []const u8 {
    const result = sanitize(out, raw, max_len);
    if (result.len == 0) {
        const copy_len = @min(out.len, fallback.len);
        @memcpy(out[0..copy_len], fallback[0..copy_len]);
        return out[0..copy_len];
    }
    return result;
}

test "sanitize basic" {
    var buf: [64]u8 = undefined;
    const result = sanitize(&buf, "hello-world_123", 64);
    try std.testing.expectEqualSlices(u8, "hello-world_123", result);
}

test "sanitize replaces invalid" {
    var buf: [64]u8 = undefined;
    const result = sanitize(&buf, "hello world!", 64);
    try std.testing.expectEqualSlices(u8, "hello_world_", result);
}

test "sanitize respects max_len" {
    var buf: [64]u8 = undefined;
    const result = sanitize(&buf, "verylongname", 5);
    try std.testing.expectEqualSlices(u8, "veryl", result);
}

test "sanitize: edge cases (empty, invalid->underscore, truncation)" {
    var buf: [64]u8 = undefined;
    // Empty stays empty (callers must treat as "no instance").
    try std.testing.expectEqualSlices(u8, "", sanitize(&buf, "", 24));
    // Invalid chars become '_' (length-preserving → distinct inputs stay distinct).
    try std.testing.expectEqualSlices(u8, "a_b_c.d", sanitize(&buf, "a b/c.d", 24)[0..7]);
    try std.testing.expectEqualSlices(u8, "___", sanitize(&buf, "/*?", 24));
    // Dot, dash, underscore are allowed through.
    try std.testing.expectEqualSlices(u8, "a.b-c_d", sanitize(&buf, "a.b-c_d", 24));
    // Truncated to max_len.
    try std.testing.expectEqualSlices(u8, "abcde", sanitize(&buf, "abcdefghij", 5));
    // Truncated to the smaller of out.len and max_len.
    var small: [3]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "abc", sanitize(&small, "abcdefg", 24));
}

test "sanitizeWithFallback: uses fallback only when the result is empty" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "default", sanitizeWithFallback(&buf, "", 24, "default"));
    try std.testing.expectEqualSlices(u8, "keep", sanitizeWithFallback(&buf, "keep", 24, "default"));
}
