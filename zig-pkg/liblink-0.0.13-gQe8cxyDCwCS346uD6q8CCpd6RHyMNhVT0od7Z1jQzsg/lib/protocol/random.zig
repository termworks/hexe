const std = @import("std");
const Allocator = std.mem.Allocator;
const Random = std.Random;

/// Generate random length preferring shorter values but allowing longer ones
/// Based on SPEC.md Appendix A
pub fn randomLengthPreferShort(random: Random, min_len: usize, max_len: usize) usize {
    const span_threshold = 7;
    const len_span = max_len - min_len;

    if (len_span <= 0) return min_len;

    if (len_span > span_threshold) {
        // 75% chance to use short range
        if (random.intRangeAtMost(u32, 0, 3) != 0) {
            return min_len + random.intRangeAtMost(usize, 0, span_threshold);
        }
    }

    return min_len + random.intRangeAtMost(usize, 0, len_span);
}

/// Generate Random Bytes with values 0..255
/// Length is chosen randomly, preferring shorter lengths
/// Caller owns returned slice
pub fn randomBytes(
    random: Random,
    allocator: Allocator,
    min_len: usize,
    max_len: usize,
) Allocator.Error![]u8 {
    const len = randomLengthPreferShort(random, min_len, max_len);
    const bytes = try allocator.alloc(u8, len);
    random.bytes(bytes);
    return bytes;
}

/// Character set for Random Names (Assigned Form)
/// ASCII 33..126 excluding @ (64) and comma (44)
const assigned_charset = blk: {
    var chars: [92]u8 = undefined;
    var idx: usize = 0;
    for (33..127) |c| {
        if (c != '@' and c != ',') {
            chars[idx] = @intCast(c);
            idx += 1;
        }
    }
    break :blk chars;
};

/// Character set for Anonymous Form (A-Z, a-z, 0-9)
const anonymous_charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

/// Random Name generation form
pub const RandomNameForm = enum {
    /// Assigned Form: 20-64 bytes, ASCII 33-126 excluding @ and comma
    assigned,
    /// Private Form: Assigned + @domain (domain controlled by implementer)
    private,
    /// Anonymous Form: (local)@(domain).example.com with A-Z, a-z, 0-9
    anonymous,
};

/// Generate a Random Name in Assigned Form
/// Length: 20-64 bytes
/// Characters: ASCII 33-126 excluding @ and comma
/// Caller owns returned slice
pub fn randomNameAssigned(
    random: Random,
    allocator: Allocator,
) Allocator.Error![]u8 {
    // Min 20, max 64 bytes
    const len = randomLengthPreferShort(random, 20, 64);
    const name = try allocator.alloc(u8, len);

    for (name) |*c| {
        const idx = random.intRangeAtMost(usize, 0, assigned_charset.len - 1);
        c.* = assigned_charset[idx];
    }

    return name;
}

/// Generate a Random Name in Private Form
/// Format: <assigned>@<domain>
/// Total length: max 64 bytes
/// Domain should be controlled by implementer
/// Caller owns returned slice
pub fn randomNamePrivate(
    random: Random,
    allocator: Allocator,
    domain: []const u8,
) Allocator.Error![]u8 {
    // Generate assigned part, leaving room for @ and domain
    const max_assigned = 64 - 1 - domain.len; // -1 for @
    if (max_assigned < 20) {
        // Domain too long, use minimum assigned length
        const assigned = try randomNameAssigned(random, allocator);
        defer allocator.free(assigned);

        // Truncate if total would exceed 64
        const assigned_len = @min(assigned.len, 64 - 1 - domain.len);
        const total_len = assigned_len + 1 + domain.len;
        const name = try allocator.alloc(u8, total_len);

        @memcpy(name[0..assigned_len], assigned[0..assigned_len]);
        name[assigned_len] = '@';
        @memcpy(name[assigned_len + 1 ..], domain);

        return name;
    }

    const assigned_len = randomLengthPreferShort(random, 20, max_assigned);
    const total_len = assigned_len + 1 + domain.len;

    const name = try allocator.alloc(u8, total_len);

    // Generate assigned part
    for (name[0..assigned_len]) |*c| {
        const idx = random.intRangeAtMost(usize, 0, assigned_charset.len - 1);
        c.* = assigned_charset[idx];
    }

    // Add @ and domain
    name[assigned_len] = '@';
    @memcpy(name[assigned_len + 1 ..], domain);

    return name;
}

/// Generate a Random Name in Anonymous Form
/// Format: (local)@(domain).example.com
/// Both local and domain use A-Z, a-z, 0-9
/// Total length: 35-64 bytes (must contain at least 22 random chars)
/// Caller owns returned slice
pub fn randomNameAnonymous(
    random: Random,
    allocator: Allocator,
) Allocator.Error![]u8 {
    // Format: local@domain.example.com
    // Suffix ".example.com" = 12 bytes
    // Need @ = 1 byte
    // Total fixed: 13 bytes
    // Remaining for random: 35-13 = 22 minimum, 64-13 = 51 maximum
    // Need at least 22 random characters total

    const suffix = ".example.com";
    const min_random = 22;
    const max_random = 51;

    const random_count = randomLengthPreferShort(random, min_random, max_random);

    // Split random chars between local and domain (roughly equal)
    const local_len = random_count / 2;
    const domain_len = random_count - local_len;

    const total_len = local_len + 1 + domain_len + suffix.len;
    const name = try allocator.alloc(u8, total_len);

    var offset: usize = 0;

    // Generate local part
    for (name[0..local_len]) |*c| {
        const idx = random.intRangeAtMost(usize, 0, anonymous_charset.len - 1);
        c.* = anonymous_charset[idx];
    }
    offset += local_len;

    // Add @
    name[offset] = '@';
    offset += 1;

    // Generate domain part
    for (name[offset..][0..domain_len]) |*c| {
        const idx = random.intRangeAtMost(usize, 0, anonymous_charset.len - 1);
        c.* = anonymous_charset[idx];
    }
    offset += domain_len;

    // Add suffix
    @memcpy(name[offset..], suffix);

    return name;
}

/// Generate a Random Name, choosing form randomly
/// Prefers Assigned Form (shorter)
/// Caller owns returned slice
pub fn randomName(
    random: Random,
    allocator: Allocator,
    domain: ?[]const u8,
) Allocator.Error![]u8 {
    // Choose form: 60% assigned, 30% private (if domain provided), 10% anonymous
    const choice = random.intRangeAtMost(u32, 0, 9);

    if (choice < 6) {
        // Assigned form
        return randomNameAssigned(random, allocator);
    } else if (choice < 9 and domain != null) {
        // Private form (if domain available)
        return randomNamePrivate(random, allocator, domain.?);
    } else {
        // Anonymous form
        return randomNameAnonymous(random, allocator);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "randomLengthPreferShort - min equals max" {
    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    const len = randomLengthPreferShort(random, 5, 5);
    try testing.expectEqual(@as(usize, 5), len);
}

test "randomLengthPreferShort - range" {
    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    // Test multiple times to check range
    for (0..100) |_| {
        const len = randomLengthPreferShort(random, 10, 50);
        try testing.expect(len >= 10);
        try testing.expect(len <= 50);
    }
}

test "randomBytes - basic" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    const bytes = try randomBytes(random, allocator, 16, 64);
    defer allocator.free(bytes);

    try testing.expect(bytes.len >= 16);
    try testing.expect(bytes.len <= 64);
}

test "randomBytes - zero length" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    const bytes = try randomBytes(random, allocator, 0, 0);
    defer allocator.free(bytes);

    try testing.expectEqual(@as(usize, 0), bytes.len);
}

test "randomNameAssigned - length" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    const name = try randomNameAssigned(random, allocator);
    defer allocator.free(name);

    try testing.expect(name.len >= 20);
    try testing.expect(name.len <= 64);
}

test "randomNameAssigned - charset" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    const name = try randomNameAssigned(random, allocator);
    defer allocator.free(name);

    // Verify all characters are in valid range
    for (name) |c| {
        try testing.expect(c >= 33);
        try testing.expect(c <= 126);
        try testing.expect(c != '@');
        try testing.expect(c != ',');
    }
}

test "randomNamePrivate - format" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    const domain = "example.com";
    const name = try randomNamePrivate(random, allocator, domain);
    defer allocator.free(name);

    // Should be <= 64 bytes
    try testing.expect(name.len <= 64);

    // Should contain @ followed by domain
    const at_pos = std.mem.indexOf(u8, name, "@");
    try testing.expect(at_pos != null);

    const suffix = name[at_pos.? + 1 ..];
    try testing.expectEqualStrings(domain, suffix);

    // Part before @ should be valid assigned form chars
    for (name[0..at_pos.?]) |c| {
        try testing.expect(c >= 33);
        try testing.expect(c <= 126);
        try testing.expect(c != '@');
        try testing.expect(c != ',');
    }
}

test "randomNameAnonymous - format" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    const name = try randomNameAnonymous(random, allocator);
    defer allocator.free(name);

    // Should be 35-64 bytes
    try testing.expect(name.len >= 35);
    try testing.expect(name.len <= 64);

    // Should end with .example.com
    try testing.expect(std.mem.endsWith(u8, name, ".example.com"));

    // Should have @ before .example.com
    const at_pos = std.mem.indexOf(u8, name, "@");
    try testing.expect(at_pos != null);

    // All chars should be alphanumeric (except @ and .)
    for (name, 0..) |c, i| {
        if (i == at_pos.? or c == '.') continue;
        const is_alpha = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
        const is_digit = (c >= '0' and c <= '9');
        try testing.expect(is_alpha or is_digit);
    }
}

test "randomName - generates valid names" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(123);
    const random = prng.random();

    // Test with domain
    for (0..10) |_| {
        const name = try randomName(random, allocator, "test.com");
        defer allocator.free(name);

        try testing.expect(name.len >= 20);
        try testing.expect(name.len <= 64);
    }

    // Test without domain
    for (0..10) |_| {
        const name = try randomName(random, allocator, null);
        defer allocator.free(name);

        try testing.expect(name.len >= 20);
        try testing.expect(name.len <= 64);
    }
}

test "assigned_charset - verification" {
    const testing = std.testing;

    // Should have 92 characters (94 printable ASCII - @ - comma)
    try testing.expectEqual(@as(usize, 92), assigned_charset.len);

    // Verify no @ or comma
    for (assigned_charset) |c| {
        try testing.expect(c != '@');
        try testing.expect(c != ',');
        try testing.expect(c >= 33);
        try testing.expect(c <= 126);
    }
}

test "anonymous_charset - verification" {
    const testing = std.testing;

    // Should have 62 characters (26 + 26 + 10)
    try testing.expectEqual(@as(usize, 62), anonymous_charset.len);

    // Verify all are alphanumeric
    for (anonymous_charset) |c| {
        const is_upper = c >= 'A' and c <= 'Z';
        const is_lower = c >= 'a' and c <= 'z';
        const is_digit = c >= '0' and c <= '9';
        try testing.expect(is_upper or is_lower or is_digit);
    }
}

test "randomBytes - distribution prefers short" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(999);
    const random = prng.random();

    // Generate many samples and check distribution
    var short_count: usize = 0;
    var long_count: usize = 0;

    for (0..100) |_| {
        const bytes = try randomBytes(random, allocator, 16, 100);
        defer allocator.free(bytes);

        if (bytes.len <= 30) {
            short_count += 1;
        } else if (bytes.len > 50) {
            long_count += 1;
        }
    }

    // Should prefer shorter lengths
    try testing.expect(short_count > long_count);
}
