//! Per-pane palette namespaces (PLAN.md).
//!
//! A namespace is a private 256-colour table. Cells drawn under one resolve
//! their indexed colours against it, so repainting a namespace touches those
//! cells and nothing else. All 256 indices stay available in every namespace.
//!
//! Slot 0 is deliberately special. hexe does not resolve indexed colours at
//! all today: `vt_bridge.convertStyle` hands the INDEX to vaxis, which emits
//! `ESC[38;5;N`, and the host terminal resolves it against the user's own
//! theme (see PLAN.md M0/Q1). Resolving slot 0 here would override that theme
//! for every pane the moment this compiled in. So slot 0 answers `passthrough`
//! and the emitted bytes stay byte-for-byte what they are today; only a real
//! namespace (slot != 0) resolves to RGB.
//!
//! That is also what makes every failure mode in PLAN.md §7 benign: an unknown
//! name, an exhausted table, a truncated replay and a disabled feature all land
//! on slot 0, which is "behave exactly as before".

const std = @import("std");

/// Slot numbers fit a u8; 0 is reserved for the pane's ordinary palette.
pub const MAX_NS = 256;
/// PLAN.md §3.2: the spec floor is 8.
pub const STACK_DEPTH = 16;
/// Names are `[a-z0-9_.-]{1,32}`, case-insensitive (PLAN.md §6).
pub const MAX_NAME_LEN = 32;

pub const RGB = struct { r: u8, g: u8, b: u8 };

/// What the renderer should do with a colour.
///
/// `passthrough` keeps the index in the output so the host terminal resolves
/// it, which is the pre-namespace behaviour.
pub const Resolved = union(enum) {
    passthrough: u8,
    rgb: RGB,
};

pub const Palette = struct {
    entries: [256]RGB,
    /// null = inherit slot 0.
    fg: ?RGB = null,
    bg: ?RGB = null,
    cursor: ?RGB = null,
};

/// A name is valid if it matches `[a-z0-9_.-]{1,32}`. Case is folded by the
/// caller; `default` is reserved for slot 0.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_NAME_LEN) return false;
    for (name) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or
            ch == '_' or ch == '.' or ch == '-';
        if (!ok) return false;
    }
    return true;
}

pub const NamespaceTable = struct {
    allocator: std.mem.Allocator,
    /// Lazily allocated: a populated namespace is 256*3 B, and a typical pane
    /// holds a handful.
    palettes: [MAX_NS]?*Palette = .{null} ** MAX_NS,
    names: std.StringHashMapUnmanaged(u8) = .empty,
    refs: [MAX_NS]u32 = .{0} ** MAX_NS,
    stack: [STACK_DEPTH]u8 = .{0} ** STACK_DEPTH,
    stack_len: u8 = 0,
    current: u8 = 0,
    /// Feature flag (PLAN.md §10): when false, `current` is forced to 0 and
    /// resolution behaves exactly as it did before, with the indirection still
    /// compiled in.
    enabled: bool = false,

    pub fn init(allocator: std.mem.Allocator) NamespaceTable {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *NamespaceTable) void {
        for (self.palettes) |maybe| {
            if (maybe) |p| self.allocator.destroy(p);
        }
        var it = self.names.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.names.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator };
    }

    /// The namespace a cell drawn right now belongs to.
    pub fn currentSlot(self: *const NamespaceTable) u8 {
        return if (self.enabled) self.current else 0;
    }

    /// Resolve one indexed colour.
    ///
    /// The only per-cell-per-frame addition on the render path, so it stays a
    /// compare plus a flat array index: no hash lookup, no allocation, and the
    /// common case (slot 0) returns before touching the table at all.
    pub inline fn resolveIndex(self: *const NamespaceTable, ns: u8, idx: u8) Resolved {
        if (ns == 0) return .{ .passthrough = idx };
        const palette = self.palettes[ns] orelse return .{ .passthrough = idx };
        return .{ .rgb = palette.entries[idx] };
    }

    /// Slot for `name`, allocating one if this is the first use.
    ///
    /// Returns 0 when the table is full or the name is invalid, which is the
    /// silent-degradation contract: `use` maps to slot 0 rather than failing.
    pub fn slotFor(self: *NamespaceTable, name: []const u8) u8 {
        if (!validName(name)) return 0;
        if (std.mem.eql(u8, name, "default")) return 0;
        if (self.names.get(name)) |slot| return slot;

        var slot: u8 = 1;
        while (slot < MAX_NS) : (slot += 1) {
            if (self.palettes[slot] == null and self.refs[slot] == 0) break;
            if (slot == MAX_NS - 1) return 0;
        }
        if (slot >= MAX_NS) return 0;

        const owned = self.allocator.dupe(u8, name) catch return 0;
        const palette = self.allocator.create(Palette) catch {
            self.allocator.free(owned);
            return 0;
        };
        // A new namespace inherits nothing concrete yet; entries stay black
        // until `set` patches them, and unset slots fall back to slot 0 via
        // resolveIndex when the palette is absent. Seeding with black keeps
        // `set` a patch rather than a replacement (Decision #4).
        palette.* = .{ .entries = .{RGB{ .r = 0, .g = 0, .b = 0 }} ** 256 };
        self.names.put(self.allocator, owned, slot) catch {
            self.allocator.free(owned);
            self.allocator.destroy(palette);
            return 0;
        };
        self.palettes[slot] = palette;
        self.refs[slot] = 1;
        return slot;
    }

    /// Patch entries in a namespace. Creating it if needed; never selects it.
    pub fn setEntry(self: *NamespaceTable, slot: u8, idx: u8, value: RGB) void {
        if (slot == 0) return;
        const palette = self.palettes[slot] orelse return;
        palette.entries[idx] = value;
    }

    pub fn push(self: *NamespaceTable, slot: u8) void {
        if (self.stack_len < STACK_DEPTH) {
            self.stack[self.stack_len] = self.current;
            self.stack_len += 1;
        }
        self.current = slot;
    }

    /// Pop. An empty stack is a no-op, not an error (PLAN.md §6).
    pub fn pop(self: *NamespaceTable) void {
        if (self.stack_len == 0) {
            self.current = 0;
            return;
        }
        self.stack_len -= 1;
        self.current = self.stack[self.stack_len];
    }
};

test "slot 0 passes the index through untouched" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    try std.testing.expectEqual(@as(u8, 7), t.resolveIndex(0, 7).passthrough);
}

test "a populated namespace resolves to its own rgb" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    const slot = t.slotFor("prompt");
    try std.testing.expect(slot != 0);
    t.setEntry(slot, 3, .{ .r = 0x33, .g = 0x11, .b = 0x11 });
    const got = t.resolveIndex(slot, 3).rgb;
    try std.testing.expectEqual(@as(u8, 0x33), got.r);
    // A different index in the same namespace is untouched by that patch.
    try std.testing.expectEqual(@as(u8, 0), t.resolveIndex(slot, 4).rgb.r);
}

test "an unallocated slot falls back to slot 0" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    try std.testing.expectEqual(@as(u8, 9), t.resolveIndex(200, 9).passthrough);
}

test "names are stable and reserved names map to slot 0" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    const a = t.slotFor("prompt");
    const b = t.slotFor("prompt");
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(@as(u8, 0), t.slotFor("default"));
    try std.testing.expectEqual(@as(u8, 0), t.slotFor("Not Valid"));
    try std.testing.expectEqual(@as(u8, 0), t.slotFor(""));
    try std.testing.expectEqual(@as(u8, 0), t.slotFor("x" ** 33));
}

test "the stack pushes, pops, and underflows to slot 0" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    const a = t.slotFor("alpha");
    const b = t.slotFor("bravo");
    t.push(a);
    t.push(b);
    try std.testing.expectEqual(b, t.current);
    t.pop();
    try std.testing.expectEqual(a, t.current);
    t.pop();
    try std.testing.expectEqual(@as(u8, 0), t.current);
    t.pop(); // underflow is a no-op
    try std.testing.expectEqual(@as(u8, 0), t.current);
}

test "the feature flag forces slot 0 with the indirection compiled in" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    const slot = t.slotFor("prompt");
    t.push(slot);
    try std.testing.expectEqual(@as(u8, 0), t.currentSlot());
    t.enabled = true;
    try std.testing.expectEqual(slot, t.currentSlot());
}
