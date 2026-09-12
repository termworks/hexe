const std = @import("std");
const core = @import("core");

pub const QUERY_TIMEOUT_MS: i64 = 1500;
pub const REFRESH_COOLDOWN_MS: i64 = 50;
pub const MAX_PENDING: usize = 512;

pub const QueryKey = union(enum) {
    foreground,
    background,
    cursor,
    palette: u8,
};

pub const Report = struct {
    key: QueryKey,
    value: [3]u8,
};

pub const Invalidation = struct {
    palette: [4]u64 = .{0} ** 4,
    palette_all: bool = false,
    foreground: bool = false,
    background: bool = false,

    pub fn empty(self: *const Invalidation) bool {
        if (self.palette_all or self.foreground or self.background) return false;
        for (self.palette) |word| {
            if (word != 0) return false;
        }
        return true;
    }

    pub fn addPalette(self: *Invalidation, index: u8) void {
        const word: usize = index / 64;
        const bit: u6 = @truncate(index);
        self.palette[word] |= @as(u64, 1) << bit;
    }

    pub fn hasPalette(self: *const Invalidation, index: u8) bool {
        if (self.palette_all) return true;
        const word: usize = index / 64;
        const bit: u6 = @truncate(index);
        return self.palette[word] & (@as(u64, 1) << bit) != 0;
    }

    pub fn merge(self: *Invalidation, other: Invalidation) void {
        self.palette_all = self.palette_all or other.palette_all;
        self.foreground = self.foreground or other.foreground;
        self.background = self.background or other.background;
        for (&self.palette, other.palette) |*word, incoming| word.* |= incoming;
    }
};

const Owner = union(enum) {
    hexe,
    pane: [32]u8,
};

const Pending = struct {
    key: QueryKey,
    owner: Owner,
    deadline_ms: i64,
};

pub const ReportAction = union(enum) {
    unowned,
    cached: bool,
    pane: [32]u8,
};

pub const HostColors = struct {
    palette: [256]?core.palette.RGB = .{null} ** 256,
    foreground: ?core.palette.RGB = null,
    background: ?core.palette.RGB = null,
    pending: [MAX_PENDING]Pending = undefined,
    pending_len: u16 = 0,
    generation: u64 = 0,
    used: Invalidation = .{},
    last_refresh_ms: i64 = 0,

    pub fn beginFrame(self: *HostColors) void {
        self.used = .{};
    }

    pub fn resolvePalette(self: *HostColors, index: u8) ?core.palette.RGB {
        self.used.addPalette(index);
        return self.palette[index];
    }

    pub fn resolveForeground(self: *HostColors) ?core.palette.RGB {
        self.used.foreground = true;
        return self.foreground;
    }

    pub fn resolveBackground(self: *HostColors) ?core.palette.RGB {
        self.used.background = true;
        return self.background;
    }

    pub fn registerPane(self: *HostColors, key: QueryKey, uuid: [32]u8, now_ms: i64) bool {
        self.expire(now_ms);
        return self.appendPending(.{ .key = key, .owner = .{ .pane = uuid }, .deadline_ms = now_ms + QUERY_TIMEOUT_MS });
    }

    pub fn queryAll(self: *HostColors, writer: anytype, now_ms: i64) !void {
        self.invalidateAll();
        try self.queryKey(writer, .foreground, now_ms);
        try self.queryKey(writer, .background, now_ms);
        for (0..256) |index| try self.queryKey(writer, .{ .palette = @intCast(index) }, now_ms);
    }

    pub fn refresh(self: *HostColors, writer: anytype, invalidation: Invalidation, now_ms: i64) !void {
        if (invalidation.empty()) return;
        self.invalidate(invalidation);
        if (invalidation.foreground) try self.queryKey(writer, .foreground, now_ms);
        if (invalidation.background) try self.queryKey(writer, .background, now_ms);
        if (invalidation.palette_all) {
            for (0..256) |index| try self.queryKey(writer, .{ .palette = @intCast(index) }, now_ms);
            return;
        }
        for (0..256) |index| {
            const palette_index: u8 = @intCast(index);
            if (invalidation.hasPalette(palette_index)) try self.queryKey(writer, .{ .palette = palette_index }, now_ms);
        }
    }

    pub fn refreshUsed(self: *HostColors, writer: anytype, now_ms: i64) !bool {
        if (self.used.empty() or now_ms - self.last_refresh_ms < REFRESH_COOLDOWN_MS) return false;
        self.last_refresh_ms = now_ms;

        var queried = false;
        if (self.used.foreground and self.foreground != null) {
            queried = try self.refreshKey(writer, .foreground, now_ms) or queried;
        }
        if (self.used.background and self.background != null) {
            queried = try self.refreshKey(writer, .background, now_ms) or queried;
        }
        for (0..256) |index| {
            const palette_index: u8 = @intCast(index);
            if (self.used.hasPalette(palette_index) and self.palette[index] != null) {
                queried = try self.refreshKey(writer, .{ .palette = palette_index }, now_ms) or queried;
            }
        }
        return queried;
    }

    pub fn handleReport(self: *HostColors, report: Report, now_ms: i64) ReportAction {
        self.expire(now_ms);
        const index = self.findPending(report.key) orelse return .unowned;
        const pending = self.removePending(index);
        return switch (pending.owner) {
            .pane => |uuid| .{ .pane = uuid },
            .hexe => .{ .cached = self.store(report.key, report.value) },
        };
    }

    pub fn expire(self: *HostColors, now_ms: i64) void {
        var index: usize = 0;
        while (index < self.pending_len) {
            if (self.pending[index].deadline_ms > now_ms) {
                index += 1;
                continue;
            }
            _ = self.removePending(index);
        }
    }

    fn queryKey(self: *HostColors, writer: anytype, key: QueryKey, now_ms: i64) !void {
        self.removeHexePending(key);
        if (!self.appendPending(.{ .key = key, .owner = .hexe, .deadline_ms = now_ms + QUERY_TIMEOUT_MS })) return error.QueryQueueFull;
        errdefer self.removeHexePending(key);
        switch (key) {
            .foreground => try writer.writeAll("\x1b]10;?\x1b\\"),
            .background => try writer.writeAll("\x1b]11;?\x1b\\"),
            .cursor => try writer.writeAll("\x1b]12;?\x1b\\"),
            .palette => |index| try writer.print("\x1b]4;{d};?\x1b\\", .{index}),
        }
    }

    fn refreshKey(self: *HostColors, writer: anytype, key: QueryKey, now_ms: i64) !bool {
        if (self.hasHexePending(key)) return false;
        try self.queryKey(writer, key, now_ms);
        return true;
    }

    fn appendPending(self: *HostColors, pending: Pending) bool {
        if (self.pending_len >= MAX_PENDING) return false;
        self.pending[self.pending_len] = pending;
        self.pending_len += 1;
        return true;
    }

    fn findPending(self: *const HostColors, key: QueryKey) ?usize {
        for (self.pending[0..self.pending_len], 0..) |pending, index| {
            if (std.meta.eql(pending.key, key)) return index;
        }
        return null;
    }

    fn removeHexePending(self: *HostColors, key: QueryKey) void {
        var index: usize = 0;
        while (index < self.pending_len) {
            const pending = self.pending[index];
            if (pending.owner == .hexe and std.meta.eql(pending.key, key)) {
                _ = self.removePending(index);
                continue;
            }
            index += 1;
        }
    }

    fn hasHexePending(self: *const HostColors, key: QueryKey) bool {
        for (self.pending[0..self.pending_len]) |pending| {
            if (pending.owner == .hexe and std.meta.eql(pending.key, key)) return true;
        }
        return false;
    }

    fn removePending(self: *HostColors, index: usize) Pending {
        const result = self.pending[index];
        const last: usize = self.pending_len - 1;
        if (index < last) std.mem.copyForwards(Pending, self.pending[index..last], self.pending[index + 1 .. self.pending_len]);
        self.pending_len -= 1;
        return result;
    }

    fn store(self: *HostColors, key: QueryKey, value: [3]u8) bool {
        const rgb: core.palette.RGB = .{ .r = value[0], .g = value[1], .b = value[2] };
        const changed = switch (key) {
            .foreground => !optionalRgbEql(self.foreground, rgb),
            .background => !optionalRgbEql(self.background, rgb),
            .cursor => false,
            .palette => |index| !optionalRgbEql(self.palette[index], rgb),
        };
        switch (key) {
            .foreground => self.foreground = rgb,
            .background => self.background = rgb,
            .cursor => {},
            .palette => |index| self.palette[index] = rgb,
        }
        if (changed) self.generation +%= 1;
        return changed;
    }

    fn invalidate(self: *HostColors, invalidation: Invalidation) void {
        var changed = false;
        if (invalidation.foreground and self.foreground != null) {
            self.foreground = null;
            changed = true;
        }
        if (invalidation.background and self.background != null) {
            self.background = null;
            changed = true;
        }
        for (0..256) |index| {
            const palette_index: u8 = @intCast(index);
            if (invalidation.hasPalette(palette_index) and self.palette[index] != null) {
                self.palette[index] = null;
                changed = true;
            }
        }
        if (changed) self.generation +%= 1;
    }

    fn invalidateAll(self: *HostColors) void {
        self.invalidate(.{ .palette_all = true, .foreground = true, .background = true });
        var index: usize = 0;
        while (index < self.pending_len) {
            if (self.pending[index].owner == .hexe) {
                _ = self.removePending(index);
                continue;
            }
            index += 1;
        }
    }
};

fn optionalRgbEql(current: ?core.palette.RGB, value: core.palette.RGB) bool {
    const rgb = current orelse return false;
    return rgb.r == value.r and rgb.g == value.g and rgb.b == value.b;
}

test "reports follow query ownership for each colour" {
    var colors: HostColors = .{};
    const pane_uuid: [32]u8 = @splat('a');

    var bytes: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try colors.queryKey(&writer, .{ .palette = 1 }, 100);
    try std.testing.expect(colors.registerPane(.{ .palette = 1 }, pane_uuid, 101));

    const report: Report = .{ .key = .{ .palette = 1 }, .value = .{ 10, 20, 30 } };
    try std.testing.expectEqual(ReportAction{ .cached = true }, colors.handleReport(report, 102));
    try std.testing.expectEqual(core.palette.RGB{ .r = 10, .g = 20, .b = 30 }, colors.palette[1].?);
    try std.testing.expectEqual(ReportAction{ .pane = pane_uuid }, colors.handleReport(report, 103));
}

test "reports can arrive out of order across colour kinds" {
    var colors: HostColors = .{};
    var bytes: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try colors.queryKey(&writer, .foreground, 100);
    try colors.queryKey(&writer, .background, 100);

    const bg: Report = .{ .key = .background, .value = .{ 1, 2, 3 } };
    const fg: Report = .{ .key = .foreground, .value = .{ 4, 5, 6 } };
    try std.testing.expect(colors.handleReport(bg, 101) == .cached);
    try std.testing.expect(colors.handleReport(fg, 102) == .cached);
    try std.testing.expectEqual(core.palette.RGB{ .r = 1, .g = 2, .b = 3 }, colors.background.?);
    try std.testing.expectEqual(core.palette.RGB{ .r = 4, .g = 5, .b = 6 }, colors.foreground.?);
}

test "invalidations target only affected entries" {
    var colors: HostColors = .{};
    colors.palette[1] = .{ .r = 1, .g = 1, .b = 1 };
    colors.palette[2] = .{ .r = 2, .g = 2, .b = 2 };
    colors.foreground = .{ .r = 3, .g = 3, .b = 3 };

    var invalidation: Invalidation = .{ .foreground = true };
    invalidation.addPalette(2);
    var bytes: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try colors.refresh(&writer, invalidation, 100);

    try std.testing.expect(colors.palette[1] != null);
    try std.testing.expect(colors.palette[2] == null);
    try std.testing.expect(colors.foreground == null);
    try std.testing.expectEqualStrings("\x1b]10;?\x1b\\\x1b]4;2;?\x1b\\", writer.buffered());
}

test "expired ownership is never reused" {
    var colors: HostColors = .{};
    try std.testing.expect(colors.registerPane(.background, @splat('b'), 100));
    colors.expire(100 + QUERY_TIMEOUT_MS);
    const report: Report = .{ .key = .background, .value = .{ 1, 2, 3 } };
    try std.testing.expectEqual(ReportAction.unowned, colors.handleReport(report, 2000));
}

test "used cached colours refresh without invalidation" {
    var colors: HostColors = .{};
    colors.palette[1] = .{ .r = 255, .g = 0, .b = 0 };
    colors.palette[2] = .{ .r = 0, .g = 255, .b = 0 };
    colors.background = .{ .r = 0, .g = 0, .b = 0 };
    colors.beginFrame();
    _ = colors.resolvePalette(1);
    _ = colors.resolveBackground();

    var bytes: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try std.testing.expect(try colors.refreshUsed(&writer, REFRESH_COOLDOWN_MS));
    try std.testing.expectEqualStrings("\x1b]11;?\x1b\\\x1b]4;1;?\x1b\\", writer.buffered());
    try std.testing.expectEqual(core.palette.RGB{ .r = 255, .g = 0, .b = 0 }, colors.palette[1].?);
    try std.testing.expectEqual(core.palette.RGB{ .r = 0, .g = 255, .b = 0 }, colors.palette[2].?);
    try std.testing.expectEqual(core.palette.RGB{ .r = 0, .g = 0, .b = 0 }, colors.background.?);

    try std.testing.expect(!try colors.refreshUsed(&writer, REFRESH_COOLDOWN_MS * 2));
    try std.testing.expectEqualStrings("\x1b]11;?\x1b\\\x1b]4;1;?\x1b\\", writer.buffered());
}

test "unknown used colours are not queried on refresh" {
    var colors: HostColors = .{};
    colors.beginFrame();
    try std.testing.expect(colors.resolvePalette(200) == null);
    try std.testing.expect(colors.resolveBackground() == null);

    var bytes: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try std.testing.expect(!try colors.refreshUsed(&writer, REFRESH_COOLDOWN_MS));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
}
