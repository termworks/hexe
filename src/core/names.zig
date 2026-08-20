//! Where names come from.
//!
//! hexe keeps two small built-in alphabets — Greek for sessions, NATO for panes
//! — and takes anything richer from a command supplied in the config. A name is
//! not decoration: a pod is addressed by `--name` and its socket is
//! `pod@<name>.sock`, so the vocabulary is also a namespace of filenames and CLI
//! arguments. That is why entries are constrained rather than free text.
//!
//! Selection takes the first *free* entry rather than a random one, so two panes
//! cannot collide on a socket path, and falls back to a numbered suffix once the
//! dictionary is exhausted.

const std = @import("std");
const logging = @import("logging.zig");

/// How to walk the dictionary looking for a free entry.
pub const Order = enum { random, sequential };

/// Longest entry accepted. Matches the pane-name limit the pod socket path
/// assumes; a longer name is a config error, not a truncation.
pub const MAX_ENTRY_LEN = 32;

/// Most entries hexe will take from a command. A dictionary is a naming pool,
/// not a data feed; a runaway command must not be able to consume memory here.
pub const MAX_ENTRIES = 4096;

/// How long a dictionary command may take before hexe gives up and uses the
/// built-in pool. Config load is interactive, so this cannot be generous.
pub const COMMAND_TIMEOUT_MS: u64 = 2000;

/// `[a-z0-9][a-z0-9._-]*`, at most MAX_ENTRY_LEN.
///
/// Lowercase only, because the name reaches a filename and a case-insensitive
/// filesystem would make two entries collide that do not look alike.
pub fn validEntry(entry: []const u8) bool {
    if (entry.len == 0 or entry.len > MAX_ENTRY_LEN) return false;
    const first = entry[0];
    const first_ok = (first >= 'a' and first <= 'z') or (first >= '0' and first <= '9');
    if (!first_ok) return false;
    for (entry[1..]) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or
            ch == '.' or ch == '_' or ch == '-';
        if (!ok) return false;
    }
    return true;
}

/// Split command output into entries, skipping blank lines.
///
/// Returns null when nothing usable came back, which the caller treats as "use
/// the built-in pool". An invalid entry is reported and skipped rather than
/// failing the whole dictionary: a pack that grows one bad id should not cost
/// the user every other name in it.
pub fn parseLines(allocator: std.mem.Allocator, out: []const u8, source: []const u8) !?[][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |e| allocator.free(e);
        list.deinit(allocator);
    }

    var rejected: usize = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (list.items.len >= MAX_ENTRIES) break;
        if (!validEntry(line)) {
            rejected += 1;
            continue;
        }
        try list.append(allocator, try allocator.dupe(u8, line));
    }

    if (rejected > 0) {
        logging.warn("names", "{s}: skipped {d} entry/entries that are not [a-z0-9][a-z0-9._-]*", .{ source, rejected });
    }
    if (list.items.len == 0) {
        list.deinit(allocator);
        return null;
    }
    return try list.toOwnedSlice(allocator);
}

/// Run a dictionary command and collect its entries.
///
/// Never fails the caller: a command that is missing, fails, times out or
/// prints nothing usable returns null and logs once. A painter that is not
/// installed must not stop panes from being created.
pub fn fromCommand(allocator: std.mem.Allocator, cmd: []const u8) ?[][]const u8 {
    var timeout_buf: [32]u8 = undefined;
    const timeout_arg = std.fmt.bufPrint(&timeout_buf, "{d}.{d:0>3}s", .{
        COMMAND_TIMEOUT_MS / 1000, COMMAND_TIMEOUT_MS % 1000,
    }) catch "2.000s";

    const argv = [_][]const u8{ "timeout", timeout_arg, "/bin/sh", "-c", cmd };
    const result = std.process.Child.run(.{ .allocator = allocator, .argv = &argv }) catch |err| {
        logging.warn("names", "dictionary command failed to start ({s}): {s}", .{ cmd, @errorName(err) });
        return null;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const status: i32 = switch (result.term) {
        .Exited => |code| @intCast(code),
        else => 127,
    };
    if (status == 124) {
        logging.warn("names", "dictionary command timed out after {d}ms: {s}", .{ COMMAND_TIMEOUT_MS, cmd });
        return null;
    }
    if (status != 0) {
        logging.warn("names", "dictionary command exited {d}: {s}", .{ status, cmd });
        return null;
    }

    return parseLines(allocator, result.stdout, cmd) catch null orelse blk: {
        logging.warn("names", "dictionary command produced no usable entries: {s}", .{cmd});
        break :blk null;
    };
}

pub fn freeEntries(allocator: std.mem.Allocator, entries: [][]const u8) void {
    for (entries) |e| allocator.free(e);
    allocator.free(entries);
}

/// Render `suffix` for attempt `n`, substituting the first `%d`.
///
/// A template without `%d` still has to produce distinct names, so the number is
/// appended rather than dropped — otherwise exhaustion would loop forever
/// handing out the same taken name.
pub fn renderSuffix(buf: []u8, suffix: []const u8, n: usize) []const u8 {
    if (std.mem.indexOf(u8, suffix, "%d")) |at| {
        return std.fmt.bufPrint(buf, "{s}{d}{s}", .{ suffix[0..at], n, suffix[at + 2 ..] }) catch "";
    }
    return std.fmt.bufPrint(buf, "{s}{d}", .{ suffix, n }) catch "";
}

/// The first entry nothing is using, else an entry plus a numbered suffix.
///
/// `taken` answers whether a candidate is already in use; the caller owns that
/// question because only it knows what "in use" means (a live pane, a pod
/// socket). The returned name is owned by the caller.
pub fn pick(
    allocator: std.mem.Allocator,
    entries: []const []const u8,
    order: Order,
    suffix: []const u8,
    ctx: anytype,
    comptime taken: fn (@TypeOf(ctx), []const u8) bool,
) ![]u8 {
    if (entries.len == 0) return error.EmptyDictionary;

    // Random order still takes the first FREE entry: it only changes where the
    // walk starts, so a fresh session does not always open on `alfa` while two
    // panes can still never collide.
    const start: usize = switch (order) {
        .sequential => 0,
        .random => blk: {
            var b: [8]u8 = undefined;
            std.crypto.random.bytes(&b);
            break :blk @as(usize, @intCast(std.mem.readInt(u64, &b, .little) % entries.len));
        },
    };

    for (0..entries.len) |i| {
        const entry = entries[(start + i) % entries.len];
        if (!taken(ctx, entry)) return allocator.dupe(u8, entry);
    }

    // Every entry is in use: walk suffixes over the whole dictionary, lowest
    // number first, so the result is stable rather than dependent on which
    // entry we happened to start from.
    var n: usize = 2;
    while (n < std.math.maxInt(u16)) : (n += 1) {
        var suffix_buf: [MAX_ENTRY_LEN]u8 = undefined;
        const rendered = renderSuffix(&suffix_buf, suffix, n);
        for (0..entries.len) |i| {
            const entry = entries[(start + i) % entries.len];
            const candidate = try std.fmt.allocPrint(allocator, "{s}{s}", .{ entry, rendered });
            if (!taken(ctx, candidate)) return candidate;
            allocator.free(candidate);
        }
    }
    return error.NoFreeName;
}

test "entry ids are constrained to what a filename and a CLI argument allow" {
    try std.testing.expect(validEntry("alfa"));
    try std.testing.expect(validEntry("nidorina"));
    try std.testing.expect(validEntry("a1._-"));
    try std.testing.expect(validEntry("0"));

    try std.testing.expect(!validEntry(""));
    try std.testing.expect(!validEntry("Alfa")); // uppercase folds on some filesystems
    try std.testing.expect(!validEntry("-lead")); // a leading dash reads as a flag
    try std.testing.expect(!validEntry(".hidden"));
    try std.testing.expect(!validEntry("has space"));
    try std.testing.expect(!validEntry("has/slash")); // would escape the socket dir
    try std.testing.expect(!validEntry("a" ** (MAX_ENTRY_LEN + 1)));
}

const TakenSet = struct {
    names: []const []const u8,
    fn has(self: TakenSet, candidate: []const u8) bool {
        for (self.names) |n| {
            if (std.mem.eql(u8, n, candidate)) return true;
        }
        return false;
    }
};

test "sequential order takes the first free entry, not a random one" {
    const entries = [_][]const u8{ "alfa", "bravo", "charlie" };
    const taken = TakenSet{ .names = &.{ "alfa", "bravo" } };

    const got = try pick(std.testing.allocator, &entries, .sequential, "-%d", taken, TakenSet.has);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("charlie", got);
}

test "an exhausted dictionary suffixes with the lowest free number" {
    const entries = [_][]const u8{ "alfa", "bravo" };
    const taken = TakenSet{ .names = &.{ "alfa", "bravo", "alfa-2" } };

    const got = try pick(std.testing.allocator, &entries, .sequential, "-%d", taken, TakenSet.has);
    defer std.testing.allocator.free(got);
    // alfa and bravo are gone and alfa-2 is gone, so bravo-2 is the lowest free.
    try std.testing.expectEqualStrings("bravo-2", got);
}

test "suffix keeps numbering distinct even without a %d placeholder" {
    var buf: [MAX_ENTRY_LEN]u8 = undefined;
    try std.testing.expectEqualStrings("-2", renderSuffix(&buf, "-%d", 2));
    try std.testing.expectEqualStrings(".v7", renderSuffix(&buf, ".v%d", 7));
    // No placeholder: append rather than drop, or exhaustion would never end.
    try std.testing.expectEqualStrings("_3", renderSuffix(&buf, "_", 3));
}

test "random order still never returns a taken entry" {
    const entries = [_][]const u8{ "alfa", "bravo", "charlie" };
    const taken = TakenSet{ .names = &.{ "alfa", "charlie" } };

    for (0..32) |_| {
        const got = try pick(std.testing.allocator, &entries, .random, "-%d", taken, TakenSet.has);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("bravo", got);
    }
}

test "command output becomes entries, and unusable lines are skipped" {
    const out = "nidorina\n\n  pikachu  \nBAD NAME\nsquirtle\n";
    const entries = (try parseLines(std.testing.allocator, out, "test")).?;
    defer freeEntries(std.testing.allocator, entries);

    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("nidorina", entries[0]);
    try std.testing.expectEqualStrings("pikachu", entries[1]);
    try std.testing.expectEqualStrings("squirtle", entries[2]);
}

test "output with nothing usable falls back rather than yielding an empty pool" {
    try std.testing.expect(try parseLines(std.testing.allocator, "", "test") == null);
    try std.testing.expect(try parseLines(std.testing.allocator, "\n\n \n", "test") == null);
    try std.testing.expect(try parseLines(std.testing.allocator, "NOPE\n/etc/passwd\n", "test") == null);
}
