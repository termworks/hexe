const std = @import("std");

const palette = @import("palette.zig");

pub const RGB = palette.RGB;
pub const OSC: u32 = 1331;
pub const VERSION: u8 = 1;
pub const STACK_DEPTH: usize = 16;
pub const OPAQUE_PERCENT: u8 = 100;

pub const Applied = enum {
    ignore,
    changed,
    have,
    refresh,
};

pub const State = struct {
    current_fg_percent: u8 = OPAQUE_PERCENT,
    stack: [STACK_DEPTH]u8 = .{OPAQUE_PERCENT} ** STACK_DEPTH,
    stack_len: u8 = 0,

    pub fn currentFgPercent(self: *const State) u8 {
        return self.current_fg_percent;
    }

    pub fn push(self: *State, percent: u8) bool {
        if (self.stack_len >= STACK_DEPTH) return false;
        self.stack[self.stack_len] = self.current_fg_percent;
        self.stack_len += 1;
        self.current_fg_percent = percent;
        return true;
    }

    pub fn pop(self: *State) void {
        if (self.stack_len == 0) {
            self.current_fg_percent = OPAQUE_PERCENT;
            return;
        }
        self.stack_len -= 1;
        self.current_fg_percent = self.stack[self.stack_len];
    }

    pub fn reset(self: *State) void {
        self.current_fg_percent = OPAQUE_PERCENT;
        self.stack_len = 0;
    }

    pub fn apply(self: *State, params: []const u8) Applied {
        var fields = std.mem.splitScalar(u8, params, ';');
        const verb = fields.next() orelse return .ignore;

        if (std.ascii.eqlIgnoreCase(verb, "use")) {
            var percent: ?u8 = null;
            while (fields.next()) |field| {
                const eq = std.mem.indexOfScalar(u8, field, '=') orelse continue;
                if (!std.ascii.eqlIgnoreCase(field[0..eq], "fg")) continue;
                if (percent != null) return .ignore;
                percent = parsePercent(field[eq + 1 ..]) orelse return .ignore;
            }
            if (!self.push(percent orelse return .ignore)) return .ignore;
            return .changed;
        }

        if (fields.next() != null) return .ignore;
        if (std.ascii.eqlIgnoreCase(verb, "end")) {
            self.pop();
            return .changed;
        }
        if (std.ascii.eqlIgnoreCase(verb, "reset")) {
            self.reset();
            return .changed;
        }
        if (std.ascii.eqlIgnoreCase(verb, "ask")) return .have;
        if (std.ascii.eqlIgnoreCase(verb, "refresh")) return .refresh;
        return .ignore;
    }
};

pub fn parsePercent(text: []const u8) ?u8 {
    if (text.len == 0) return null;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    const value = std.fmt.parseUnsigned(u16, text, 10) catch return null;
    if (value > OPAQUE_PERCENT) return null;
    return @intCast(value);
}

pub fn mixRgb(src: RGB, bg: RGB, percent: u8) RGB {
    std.debug.assert(percent <= OPAQUE_PERCENT);
    return .{
        .r = mixComponent(src.r, bg.r, percent),
        .g = mixComponent(src.g, bg.g, percent),
        .b = mixComponent(src.b, bg.b, percent),
    };
}

fn mixComponent(src: u8, bg: u8, percent: u8) u8 {
    const p: u16 = percent;
    const inverse: u16 = OPAQUE_PERCENT - p;
    const value = @as(u16, src) * p + @as(u16, bg) * inverse + 50;
    return @intCast(value / 100);
}

test "source contribution boundaries and rounding are exact" {
    const src: RGB = .{ .r = 255, .g = 17, .b = 80 };
    const bg: RGB = .{ .r = 0, .g = 200, .b = 20 };

    try std.testing.expectEqual(src, mixRgb(src, bg, 100));
    try std.testing.expectEqual(bg, mixRgb(src, bg, 0));
    try std.testing.expectEqual(RGB{ .r = 77, .g = 145, .b = 38 }, mixRgb(src, bg, 30));
}

test "use scopes nest and restore" {
    var state: State = .{};
    try std.testing.expectEqual(Applied.changed, state.apply("use;fg=30"));
    try std.testing.expectEqual(@as(u8, 30), state.currentFgPercent());
    try std.testing.expectEqual(Applied.changed, state.apply("USE;FG=7;future=value"));
    try std.testing.expectEqual(@as(u8, 7), state.currentFgPercent());
    try std.testing.expectEqual(Applied.changed, state.apply("end"));
    try std.testing.expectEqual(@as(u8, 30), state.currentFgPercent());
    try std.testing.expectEqual(Applied.changed, state.apply("END"));
    try std.testing.expectEqual(@as(u8, 100), state.currentFgPercent());
    try std.testing.expectEqual(Applied.changed, state.apply("end"));
    try std.testing.expectEqual(@as(u8, 100), state.currentFgPercent());
}

test "full stack ignores another use" {
    var state: State = .{};
    for (0..STACK_DEPTH) |i| {
        var buf: [16]u8 = undefined;
        const params = try std.fmt.bufPrint(&buf, "use;fg={d}", .{i});
        try std.testing.expectEqual(Applied.changed, state.apply(params));
    }
    try std.testing.expectEqual(@as(u8, STACK_DEPTH - 1), state.currentFgPercent());
    try std.testing.expectEqual(Applied.ignore, state.apply("use;fg=99"));
    try std.testing.expectEqual(@as(u8, STACK_DEPTH - 1), state.currentFgPercent());
}

test "reset clears every scope" {
    var state: State = .{};
    _ = state.apply("use;fg=30");
    _ = state.apply("use;fg=20");
    try std.testing.expectEqual(Applied.changed, state.apply("reset"));
    try std.testing.expectEqual(@as(u8, 100), state.currentFgPercent());
    try std.testing.expectEqual(@as(u8, 0), state.stack_len);
}

test "ask reports version one support" {
    var state: State = .{};
    try std.testing.expectEqual(Applied.have, state.apply("ask"));
    try std.testing.expectEqual(@as(u8, VERSION), 1);
}

test "refresh requests host colour discovery" {
    var state: State = .{};
    try std.testing.expectEqual(Applied.refresh, state.apply("refresh"));
    try std.testing.expectEqual(@as(u8, OPAQUE_PERCENT), state.currentFgPercent());
    try std.testing.expectEqual(@as(u8, 0), state.stack_len);
}

test "malformed percentages and commands leave state unchanged" {
    const invalid = [_][]const u8{
        "use",
        "use;fg=",
        "use;fg=-1",
        "use;fg=1.5",
        "use;fg=1e2",
        "use;fg= 30",
        "use;fg=101",
        "use;fg=999999999999999999999",
        "use;fg=20;fg=30",
        "use;future=value",
        "end;extra",
        "reset;extra",
        "ask;extra",
        "refresh;extra",
        "unknown;fg=30",
    };

    for (invalid) |params| {
        var state: State = .{};
        try std.testing.expectEqual(Applied.ignore, state.apply(params));
        try std.testing.expectEqual(@as(u8, 100), state.currentFgPercent());
        try std.testing.expectEqual(@as(u8, 0), state.stack_len);
    }
}

test "leading zeroes are accepted by parsed value" {
    var state: State = .{};
    try std.testing.expectEqual(Applied.changed, state.apply("use;future=x;fg=030"));
    try std.testing.expectEqual(@as(u8, 30), state.currentFgPercent());
}

test "apply never faults on arbitrary bytes" {
    var state: State = .{};
    var bytes: [4]u8 = undefined;
    for (0..256) |a| {
        bytes[0] = @intCast(a);
        _ = state.apply(bytes[0..1]);
        for (0..256) |b| {
            bytes[1] = @intCast(b);
            _ = state.apply(bytes[0..2]);
        }
    }
}
