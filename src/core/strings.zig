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

/// Escape a string into a JSON string body. Uses only `writeAll`, so it takes
/// both a `std.fs.File` and a buffered writer.
///
/// The two copies this replaces stopped at `" \ \n \r \t` and passed every
/// other control byte through verbatim, which is invalid JSON -- and pane
/// names and cwds routinely carry ESC/BEL from terminal title sequences.
pub fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    const hex = "0123456789abcdef";
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                const esc = [6]u8{ '\\', 'u', '0', '0', hex[(c >> 4) & 0xf], hex[c & 0xf] };
                try writer.writeAll(&esc);
            },
            else => try writer.writeAll(&[1]u8{c}),
        }
    }
}

test "writeJsonEscaped escapes control bytes as \\uXXXX" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try writeJsonEscaped(w, "a\x1bb\x07c\"d\\e\nf\tg");
    try std.testing.expectEqualSlices(u8, "a\\u001bb\\u0007c\\\"d\\\\e\\nf\\tg", buf.items);

    buf.clearRetainingCapacity();
    try writeJsonEscaped(buf.writer(std.testing.allocator), "\x00\x08\x0c\x1f");
    try std.testing.expectEqualSlices(u8, "\\u0000\\b\\f\\u001f", buf.items);

    // The escaped form must actually parse as JSON.
    buf.clearRetainingCapacity();
    try buf.appendSlice(std.testing.allocator, "{\"k\":\"");
    try writeJsonEscaped(buf.writer(std.testing.allocator), "esc\x1b bel\x07 quote\"");
    try buf.appendSlice(std.testing.allocator, "\"}");
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqualSlices(u8, "esc\x1b bel\x07 quote\"", parsed.value.object.get("k").?.string);
}
