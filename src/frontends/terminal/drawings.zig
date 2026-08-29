//! Named rectangles anything may draw into.
//!
//! hexe already draws arbitrary art at an arbitrary rectangle -- that is what a
//! pane's sprite is. What it did not have was a way to ask for one from
//! outside: the sprite was the only caller, its position came from config, and
//! nothing else could put anything anywhere.
//!
//! A drawing is a name, a rectangle and its bytes. Give it the same name twice
//! and the second replaces the first, so a caller updating one is a `draw`
//! rather than an undraw-and-redraw that flickers.
//!
//! A drawing carries its own bytes. It names no view and borrows no painter:
//! rendering through one meant reaching into the status bar's painter and
//! refresh interval to draw something that has nothing to do with the bar, and
//! made every caller need a painter configured before it could show anything.
//! A caller that wants one runs it and sends what it draws.
//!
//! Rendering is somebody else's job; this only remembers what to draw and where.

const std = @import("std");
const core = @import("core");

/// Where a drawing sits. Resolved against the terminal at render time, so a
/// corner stays a corner across a resize.
pub const Anchor = union(enum) {
    corner: Corner,
    /// Column and row, from the top left of the terminal.
    at: struct { x: u16, y: u16 },
};

pub const Corner = enum {
    top_left,
    top_right,
    bottom_left,
    bottom_right,
    center,

    pub fn fromString(s: []const u8) ?Corner {
        if (std.mem.eql(u8, s, "topleft") or std.mem.eql(u8, s, "top_left")) return .top_left;
        if (std.mem.eql(u8, s, "topright") or std.mem.eql(u8, s, "top_right")) return .top_right;
        if (std.mem.eql(u8, s, "bottomleft") or std.mem.eql(u8, s, "bottom_left")) return .bottom_left;
        if (std.mem.eql(u8, s, "bottomright") or std.mem.eql(u8, s, "bottom_right")) return .bottom_right;
        if (std.mem.eql(u8, s, "center") or std.mem.eql(u8, s, "centre")) return .center;
        return null;
    }
};

pub const Drawing = struct {
    name: []u8,
    anchor: Anchor,
    width: u16,
    height: u16,
    /// What to draw: bytes, ready to blit.
    content: []u8,
    /// Milliseconds since the epoch, or 0 to stay until removed. A caller that
    /// dies without cleaning up should not leave something on the screen for
    /// ever, so a ttl is the polite way to ask.
    expires_at: i64 = 0,

    fn deinit(self: *Drawing, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.content);
    }

    /// Top-left cell, given the space available. `status_height` is kept clear
    /// so a bottom-anchored drawing does not land on the bar.
    pub fn origin(self: Drawing, term_w: u16, term_h: u16, status_height: u16) struct { x: u16, y: u16 } {
        const usable_h = term_h -| status_height;
        return switch (self.anchor) {
            .at => |p| .{ .x = p.x, .y = p.y },
            .corner => |c| switch (c) {
                .top_left => .{ .x = 0, .y = 0 },
                .top_right => .{ .x = term_w -| self.width, .y = 0 },
                .bottom_left => .{ .x = 0, .y = usable_h -| self.height },
                .bottom_right => .{ .x = term_w -| self.width, .y = usable_h -| self.height },
                .center => .{ .x = (term_w -| self.width) / 2, .y = (usable_h -| self.height) / 2 },
            },
        };
    }
};

/// Upper bound on how many drawings may be live at once. They come from the
/// API, so the limit is what stops a caller in a loop from growing the map
/// without end.
pub const MAX_DRAWINGS: usize = 64;

pub const Registry = struct {
    allocator: std.mem.Allocator,
    items: std.StringHashMap(Drawing),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator, .items = std.StringHashMap(Drawing).init(allocator) };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.items.valueIterator();
        while (it.next()) |d| d.deinit(self.allocator);
        self.items.deinit();
    }

    pub fn count(self: *const Registry) usize {
        return self.items.count();
    }

    /// Add or replace. Takes ownership of everything in `drawing` on success,
    /// and frees it on failure, so a caller never has to unwind by hand.
    pub fn put(self: *Registry, drawing: Drawing) !void {
        var owned = drawing;
        errdefer owned.deinit(self.allocator);

        if (self.items.getEntry(drawing.name)) |existing| {
            // Replacing: the old one's memory goes, the key stays.
            existing.value_ptr.deinit(self.allocator);
            existing.value_ptr.* = owned;
            return;
        }
        if (self.items.count() >= MAX_DRAWINGS) return error.TooManyDrawings;
        try self.items.put(owned.name, owned);
    }

    pub fn remove(self: *Registry, name: []const u8) bool {
        if (self.items.fetchRemove(name)) |kv| {
            var d = kv.value;
            d.deinit(self.allocator);
            return true;
        }
        return false;
    }

    /// Drop whatever has timed out. Called once per render rather than on a
    /// timer: a drawing nobody is drawing does not need collecting on schedule.
    pub fn sweep(self: *Registry, now: i64) void {
        var doomed: [MAX_DRAWINGS][]const u8 = undefined;
        var n: usize = 0;
        var it = self.items.valueIterator();
        while (it.next()) |d| {
            if (d.expires_at != 0 and now >= d.expires_at and n < doomed.len) {
                doomed[n] = d.name;
                n += 1;
            }
        }
        for (doomed[0..n]) |name| _ = self.remove(name);
    }

    pub fn iterator(self: *Registry) std.StringHashMap(Drawing).ValueIterator {
        return self.items.valueIterator();
    }
};

test "a corner resolves against the terminal, and a resize moves it" {
    const d = Drawing{
        .name = @constCast("x"),
        .anchor = .{ .corner = .bottom_right },
        .width = 10,
        .height = 4,
        .content = @constCast(""),
    };
    // 80x24 with a one-row bar: the usable height is 23.
    const a = d.origin(80, 24, 1);
    try std.testing.expectEqual(@as(u16, 70), a.x);
    try std.testing.expectEqual(@as(u16, 19), a.y);

    const b = d.origin(100, 40, 1);
    try std.testing.expectEqual(@as(u16, 90), b.x);
    try std.testing.expectEqual(@as(u16, 35), b.y);
}

test "a drawing larger than the terminal clamps instead of wrapping" {
    const d = Drawing{
        .name = @constCast("x"),
        .anchor = .{ .corner = .bottom_right },
        .width = 200,
        .height = 100,
        .content = @constCast(""),
    };
    const a = d.origin(80, 24, 1);
    try std.testing.expectEqual(@as(u16, 0), a.x);
    try std.testing.expectEqual(@as(u16, 0), a.y);
}

test "putting the same name twice replaces rather than accumulates" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    try reg.put(.{
        .name = try allocator.dupe(u8, "keys"),
        .anchor = .{ .corner = .top_left },
        .width = 4,
        .height = 1,
        .content = try allocator.dupe(u8, "one"),
    });
    try reg.put(.{
        .name = try allocator.dupe(u8, "keys"),
        .anchor = .{ .corner = .top_left },
        .width = 4,
        .height = 1,
        .content = try allocator.dupe(u8, "two"),
    });
    try std.testing.expectEqual(@as(usize, 1), reg.count());
    try std.testing.expectEqualStrings("two", reg.items.get("keys").?.content);

    try std.testing.expect(reg.remove("keys"));
    try std.testing.expectEqual(@as(usize, 0), reg.count());
    try std.testing.expect(!reg.remove("keys"));
}

test "a drawing with a ttl is swept, one without stays" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    try reg.put(.{
        .name = try allocator.dupe(u8, "transient"),
        .anchor = .{ .corner = .center },
        .width = 1,
        .height = 1,
        .content = try allocator.dupe(u8, ""),
        .expires_at = 1000,
    });
    try reg.put(.{
        .name = try allocator.dupe(u8, "forever"),
        .anchor = .{ .corner = .center },
        .width = 1,
        .height = 1,
        .content = try allocator.dupe(u8, ""),
    });

    reg.sweep(999);
    try std.testing.expectEqual(@as(usize, 2), reg.count());
    reg.sweep(1000);
    try std.testing.expectEqual(@as(usize, 1), reg.count());
    try std.testing.expect(reg.items.get("forever") != null);
}
