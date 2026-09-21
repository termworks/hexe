//! OSC 1332 — stretch lines.
//!
//! A program marks points on a line where it may stretch, and hexe fills the
//! space so the line spans the pane at whatever width the pane has now. The
//! mark is stored in the cell itself: a placeholder cell whose codepoint names
//! a pattern in the pane's table. The terminal keeps it like any other cell, so
//! scrolling, scrollback, reflow and backlog replay carry it untouched, and the
//! renderer expands it to the current width every frame.

const std = @import("std");

pub const OSC: u32 = 1332;
pub const VERSION: u8 = 1;

/// Fill placeholders are `BASE + pattern id`, in Supplementary Private Use
/// Area-B, which neither Nerd Fonts nor ordinary text occupy.
pub const BASE: u21 = 0x10F000;
pub const MAX_PATTERNS: usize = 64;
pub const MAX_PATTERN_CELLS: usize = 8;

pub const Applied = union(enum) {
    ignore,
    have,
    begin,
    end,
    fill: u8,
};

/// One fill pattern: single-cell glyphs repeated across the fill.
pub const Pattern = struct {
    glyphs: [MAX_PATTERN_CELLS]u21 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Pattern) []const u21 {
        return self.glyphs[0..self.len];
    }

    /// The glyph drawn at column `i` of a fill.
    pub fn at(self: *const Pattern, i: usize) u21 {
        return self.glyphs[i % self.len];
    }
};

/// Per-pane protocol state.
pub const State = struct {
    patterns: [MAX_PATTERNS]Pattern = undefined,
    count: u8 = 0,
    /// Between `begin` and `end`.
    in_line: bool = false,
    /// Autowrap as it was before `begin`, restored by `end`.
    saved_wrap: bool = true,

    pub fn apply(self: *State, params: []const u8) Applied {
        var fields = std.mem.splitScalar(u8, params, ';');
        const verb = fields.next() orelse return .ignore;

        if (std.ascii.eqlIgnoreCase(verb, "fill")) {
            if (!self.in_line) return .ignore;
            const glyphs = fields.next() orelse return .ignore;
            // Later fields (a weight, say) belong to a later version.
            var candidate: Pattern = .{};
            if (!parsePattern(glyphs, &candidate)) return .ignore;
            const id = self.intern(candidate) orelse return .ignore;
            return .{ .fill = id };
        }

        if (fields.next() != null) return .ignore;
        if (std.ascii.eqlIgnoreCase(verb, "ask")) return .have;
        if (std.ascii.eqlIgnoreCase(verb, "begin")) return .begin;
        if (std.ascii.eqlIgnoreCase(verb, "end")) return if (self.in_line) .end else .ignore;
        return .ignore;
    }

    /// The id of `wanted`, adding it when new. Null when the table is full.
    pub fn intern(self: *State, wanted: Pattern) ?u8 {
        for (self.patterns[0..self.count], 0..) |*p, i| {
            if (std.mem.eql(u21, p.slice(), wanted.slice())) return @intCast(i);
        }
        if (self.count >= MAX_PATTERNS) return null;
        self.patterns[self.count] = wanted;
        self.count += 1;
        return self.count - 1;
    }

    pub fn pattern(self: *const State, id: u8) ?*const Pattern {
        if (id >= self.count) return null;
        return &self.patterns[id];
    }
};

/// The pattern id a cell's codepoint names, or null for an ordinary cell.
pub fn fillId(cp: u21) ?u8 {
    if (cp < BASE or cp >= BASE + MAX_PATTERNS) return null;
    return @intCast(cp - BASE);
}

pub fn placeholder(id: u8) u21 {
    return BASE + @as(u21, id);
}

/// Width of fill `index` of `fills` when `free` columns are shared: evenly,
/// with the leftover going one column each to the leftmost fills.
pub fn fillWidth(free: usize, fills: usize, index: usize) usize {
    if (fills == 0) return 0;
    return free / fills + @intFromBool(index < free % fills);
}

/// `text` with every fill placeholder replaced by its pattern, laid out line by
/// line at `width` columns. For copying a stretch line as it is drawn. Content
/// width is counted one cell per codepoint.
pub fn expandText(allocator: std.mem.Allocator, text: []const u8, state: *const State, width: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        first = false;

        const view = std.unicode.Utf8View.init(line) catch {
            try out.appendSlice(allocator, line);
            continue;
        };
        var content: usize = 0;
        var fills: usize = 0;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (fillId(cp) != null) fills += 1 else content += 1;
        }
        if (fills == 0) {
            try out.appendSlice(allocator, line);
            continue;
        }

        const free = width -| content;
        var nth: usize = 0;
        it = view.iterator();
        while (it.nextCodepointSlice()) |bytes| {
            const cp = std.unicode.utf8Decode(bytes) catch unreachable;
            const id = fillId(cp) orelse {
                try out.appendSlice(allocator, bytes);
                continue;
            };
            const w = fillWidth(free, fills, nth);
            nth += 1;
            const p = state.pattern(id) orelse continue;
            var buf: [4]u8 = undefined;
            for (0..w) |i| {
                const n = std.unicode.utf8Encode(p.at(i), &buf) catch continue;
                try out.appendSlice(allocator, buf[0..n]);
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Decode `text` as 1..MAX_PATTERN_CELLS single-cell glyphs.
fn parsePattern(text: []const u8, out: *Pattern) bool {
    const view = std.unicode.Utf8View.init(text) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (!isSingleCell(cp) or out.len >= MAX_PATTERN_CELLS) return false;
        out.glyphs[out.len] = cp;
        out.len += 1;
    }
    return out.len > 0;
}

/// Glyphs that always occupy exactly one cell: space and ASCII, Latin-1,
/// general punctuation, arrows, box drawing, blocks and geometric shapes.
fn isSingleCell(cp: u21) bool {
    return switch (cp) {
        0x20...0x7e => true,
        0xa1...0xff => true,
        0x2010...0x2027, 0x2030...0x205e => true,
        0x2190...0x21ff => true,
        0x2500...0x25fc => true,
        else => false,
    };
}

const testing = std.testing;

test "ask, begin and end" {
    var s: State = .{};
    try testing.expectEqual(Applied.have, s.apply("ask"));
    try testing.expectEqual(Applied.have, s.apply("ASK"));
    try testing.expectEqual(Applied.ignore, s.apply("end"));
    try testing.expectEqual(Applied.begin, s.apply("begin"));
    s.in_line = true;
    try testing.expectEqual(Applied.end, s.apply("End"));
    try testing.expectEqual(Applied.ignore, s.apply("ask;extra"));
    try testing.expectEqual(Applied.ignore, s.apply("nope"));
}

test "fill interns patterns and only inside a line" {
    var s: State = .{};
    try testing.expectEqual(Applied.ignore, s.apply("fill;-"));
    s.in_line = true;
    try testing.expectEqual(Applied{ .fill = 0 }, s.apply("fill;-"));
    try testing.expectEqual(Applied{ .fill = 1 }, s.apply("fill;─╌"));
    try testing.expectEqual(Applied{ .fill = 0 }, s.apply("FILL;-"));
    try testing.expectEqual(Applied{ .fill = 1 }, s.apply("fill;─╌;w=2"));
    try testing.expectEqualSlices(u21, &.{ '─', '╌' }, s.pattern(1).?.slice());
}

test "malformed fills leave the table untouched" {
    var s: State = .{ .in_line = true };
    for ([_][]const u8{ "fill", "fill;", "fill;123456789", "fill;\x07", "fill;漢", "fill;\xff" }) |bad| {
        try testing.expectEqual(Applied.ignore, s.apply(bad));
    }
    try testing.expectEqual(@as(u8, 0), s.count);
}

test "a full table refuses a new pattern but still serves old ones" {
    var s: State = .{ .in_line = true };
    var i: u8 = 0;
    while (i < MAX_PATTERNS) : (i += 1) {
        var p: Pattern = .{};
        p.glyphs[0] = 0x2500 + @as(u21, i);
        p.len = 1;
        try testing.expect(s.intern(p) != null);
    }
    try testing.expectEqual(Applied.ignore, s.apply("fill;="));
    try testing.expectEqual(Applied{ .fill = 0 }, s.apply("fill;─"));
}

test "free width is shared evenly, leftover to the leftmost fills" {
    try testing.expectEqual(@as(usize, 4), fillWidth(10, 3, 0));
    try testing.expectEqual(@as(usize, 3), fillWidth(10, 3, 1));
    try testing.expectEqual(@as(usize, 3), fillWidth(10, 3, 2));
    try testing.expectEqual(@as(usize, 0), fillWidth(0, 2, 0));
    try testing.expectEqual(@as(usize, 7), fillWidth(7, 1, 0));
}

test "placeholders round-trip and ordinary codepoints are not fills" {
    try testing.expectEqual(@as(?u8, 5), fillId(placeholder(5)));
    try testing.expectEqual(@as(?u8, null), fillId('-'));
    try testing.expectEqual(@as(?u8, null), fillId(BASE + MAX_PATTERNS));
    try testing.expectEqual(@as(?u8, null), fillId(0xF0001));
}

test "copied text expands each fill to its drawn width" {
    var s: State = .{ .in_line = true };
    const dash = s.apply("fill;-").fill;
    const eq = s.apply("fill;=").fill;

    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for ([_]u21{ 'a', placeholder(dash), 'b', placeholder(eq), 'c' }) |cp| {
        n += try std.unicode.utf8Encode(cp, buf[n..]);
    }
    const line = buf[0..n];
    const text = try std.mem.concat(testing.allocator, u8, &.{ "plain\n", line });
    defer testing.allocator.free(text);

    const wide = try expandText(testing.allocator, text, &s, 10);
    defer testing.allocator.free(wide);
    try testing.expectEqualStrings("plain\na----b===c", wide);

    const narrow = try expandText(testing.allocator, text, &s, 2);
    defer testing.allocator.free(narrow);
    try testing.expectEqualStrings("plain\nabc", narrow);
}

test "a pattern repeats from its start" {
    var p: Pattern = .{};
    p.glyphs[0] = '-';
    p.glyphs[1] = '=';
    p.len = 2;
    try testing.expectEqual(@as(u21, '-'), p.at(0));
    try testing.expectEqual(@as(u21, '='), p.at(1));
    try testing.expectEqual(@as(u21, '-'), p.at(4));
}
