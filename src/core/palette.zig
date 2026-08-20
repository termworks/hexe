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

/// Namespaces are addressed by number, 0..MAX_NS-1.
///
/// The number IS the address: it is exactly what each cell records, so there is
/// no name-to-slot mapping that can be lost, rebuilt in a different order, or
/// exhausted — any of which would silently repoint existing cells at another
/// program's colours. Callers agree among themselves on what a number means;
/// hexe assigns meaning to none of them.
///
/// Slot 0 is what a cell that selected nothing resolves against. Setting it
/// recolours the ordinary indexed palette for this pane.
///
/// The bound is the tag carried on each cell: 5 bits of ghostty's style flags
/// (patches/ghostty-vt-ns.patch), which are bits that were already padding.
/// Widening it to a byte would grow the style struct from 14 to 16 and needs
/// explicit equality and hashing changes, for 224 more slots than a pane uses.
pub const MAX_NS = 32;
/// PLAN.md §3.2: the spec floor is 8.
pub const STACK_DEPTH = 16;

pub const RGB = struct { r: u8, g: u8, b: u8 };

pub const Resolved = union(enum) {
    passthrough: u8,
    rgb: RGB,
};

/// A namespace's default colours, for cells that name none of their own.
/// Both null means "inherit slot 0", which is the terminal's own default.
pub const Defaults = struct {
    fg: ?RGB = null,
    bg: ?RGB = null,
};

pub const Palette = struct {
    entries: [256]RGB = .{RGB{ .r = 0, .g = 0, .b = 0 }} ** 256,
    /// Which entries `set` has actually patched. Decision #4 makes `set` a
    /// patch, so an untouched index must resolve as if the namespace did not
    /// claim it — otherwise enabling a fresh namespace paints its rows black.
    /// A flat [256]bool rather than [256]?RGB keeps the hot path one indexed
    /// load and a branch instead of an optional unwrap.
    patched: [256]bool = .{false} ** 256,
    /// null = inherit slot 0.
    fg: ?RGB = null,
    bg: ?RGB = null,
    cursor: ?RGB = null,
};

/// A name is valid if it matches `[a-z0-9_.-]{1,32}`. Case is folded by the
/// caller; `default` is reserved for slot 0.
pub const NamespaceTable = struct {
    allocator: std.mem.Allocator,
    /// Lazily allocated: a populated namespace is 256*3 B, and a typical pane
    /// holds a handful.
    palettes: [MAX_NS]?*Palette = .{null} ** MAX_NS,
    stack: [STACK_DEPTH]StackEntry = .{StackEntry{}} ** STACK_DEPTH,
    stack_len: u8 = 0,
    current: u8 = 0,
    /// Feature flag (PLAN.md §10): when false, `current` is forced to 0 and
    /// resolution behaves exactly as it did before, with the indirection still
    /// compiled in.
    enabled: bool = false,

    /// The OSC number this pane answers on. Per-table so a config reload can
    /// move it without disturbing panes already speaking the old number.
    osc: u32 = DEFAULT_OSC,

    pub fn init(allocator: std.mem.Allocator) NamespaceTable {
        var table: NamespaceTable = .{ .allocator = allocator, .osc = default_osc };
        table.setEnabled(default_enabled);
        return table;
    }

    /// Re-apply the process-wide settings after a config reload.
    pub fn applyDefaults(self: *NamespaceTable) void {
        self.osc = default_osc;
        self.setEnabled(default_enabled);
    }

    pub fn deinit(self: *NamespaceTable) void {
        for (self.palettes) |maybe| {
            if (maybe) |p| self.allocator.destroy(p);
        }
        self.* = .{ .allocator = self.allocator };
    }

    /// Parse a slot from the wire, or null if it is not one.
    pub fn parseSlot(text: []const u8) ?u8 {
        if (text.len == 0 or text.len > 2) return null;
        const n = std.fmt.parseUnsigned(u16, text, 10) catch return null;
        if (n >= MAX_NS) return null;
        return @intCast(n);
    }

    /// The palette for `slot`, allocating on first use.
    ///
    /// Slot 0 allocates like any other: setting it is how a caller recolours
    /// the ordinary indexed palette for everything that selected nothing.
    fn ensure(self: *NamespaceTable, slot: u8) ?*Palette {
        if (slot >= MAX_NS) return null;
        if (self.palettes[slot]) |p| return p;
        const p = self.allocator.create(Palette) catch return null;
        p.* = .{};
        self.palettes[slot] = p;
        return p;
    }

    /// The namespace a cell drawn right now belongs to.
    pub fn currentSlot(self: *const NamespaceTable) u8 {
        return if (self.enabled) self.current else 0;
    }

    /// Turn the feature on or off. Palettes set while off are kept, so a
    /// re-enable shows them again.
    pub fn setEnabled(self: *NamespaceTable, on: bool) void {
        self.enabled = on;
    }

    /// A namespace's default fg/bg — what a cell that names no colour of its
    /// own resolves to (PLAN.md §3.2 `fg`/`bg`, null = inherit slot 0).
    ///
    /// Read once per row on the render path, next to the slot lookup, so the
    /// per-cell path stays a null check on an already-loaded struct.
    pub fn defaultsFor(self: *const NamespaceTable, ns: u8) Defaults {
        if (ns >= MAX_NS) return .{};
        const palette = self.palettes[ns] orelse return .{};
        return .{ .fg = palette.fg, .bg = palette.bg };
    }

    /// A namespace's cursor colour, if it set one.
    ///
    /// Separate from `defaultsFor` because it is consumed somewhere else
    /// entirely: cells go through the cell path, while the cursor is the real
    /// terminal cursor and can only be recoloured by telling the host terminal
    /// (OSC 12).
    pub fn cursorFor(self: *const NamespaceTable, ns: u8) ?RGB {
        if (ns == 0) return null;
        if (ns >= MAX_NS) return null;
        const palette = self.palettes[ns] orelse return null;
        return palette.cursor;
    }

    /// Slot for a row's auto-namespace. A flat index; no hashing.
    /// Resolve one indexed colour.
    ///
    /// The only per-cell-per-frame addition on the render path, so it stays a
    /// compare plus a flat array index: no hash lookup, no allocation, and the
    /// common case (slot 0) returns before touching the table at all.
    pub inline fn resolveIndex(self: *const NamespaceTable, ns: u8, idx: u8) Resolved {
        if (ns >= MAX_NS) return .{ .passthrough = idx };
        const palette = self.palettes[ns] orelse return .{ .passthrough = idx };
        if (!palette.patched[idx]) return .{ .passthrough = idx };
        return .{ .rgb = palette.entries[idx] };
    }

    pub fn setEntry(self: *NamespaceTable, slot: u8, idx: u8, value: RGB) void {
        const palette = self.ensure(slot) orelse return;
        palette.entries[idx] = value;
        palette.patched[idx] = true;
    }

    /// Select `slot`, rebinding the auto-namespace `kind` until the matching
    /// `end`.
    ///
    /// A full stack drops the push rather than selecting without a restore
    /// point: an app that overflows would otherwise leave its colours behind
    /// for good, and "silently maps to slot 0" is the contract.
    pub fn push(self: *NamespaceTable, slot: u8) void {
        if (self.stack_len >= STACK_DEPTH) return;
        self.stack[self.stack_len] = .{ .prev_current = self.current };
        self.stack_len += 1;
        self.current = slot;
    }

    /// Pop. An empty stack is a no-op, not an error (PLAN.md §6).
    pub fn pop(self: *NamespaceTable) void {
        if (self.stack_len == 0) {
            self.current = 0;
            return;
        }
        self.stack_len -= 1;
        self.current = self.stack[self.stack_len].prev_current;
    }

    /// Forget every colour a slot was given, returning its cells to the
    /// terminal's own theme. `*` resets every slot, slot 0 included.
    pub fn reset(self: *NamespaceTable, slot_text: []const u8) bool {
        if (std.mem.eql(u8, slot_text, "*")) {
            var any = false;
            for (self.palettes) |maybe| {
                const p = maybe orelse continue;
                p.* = .{};
                any = true;
            }
            return any;
        }
        const slot = parseSlot(slot_text) orelse return false;
        const p = self.palettes[slot] orelse return false;
        p.* = .{};
        return true;
    }

    /// The highest slot a caller may address, for the `have` reply.
    ///
    /// Not a count of free slots: nothing is allocated on a caller's behalf any
    /// more, so there is nothing to run out of. A client needs the ceiling.
    pub fn maxSlot(self: *const NamespaceTable) u16 {
        _ = self;
        return MAX_NS - 1;
    }

    /// Pack every patched colour into a blob SES can hold as opaque session
    /// metadata (PLAN.md §2, M4).
    ///
    /// The pane's byte ring is NOT a store: a clear-screen empties it and a
    /// busy pane scrolls it, either of which loses a palette across a
    /// detach/reattach. This is what actually survives. It carries colours
    /// only — never the stack, `current` or the overrides, which describe what
    /// a *running* program selected and must not outlive it.
    ///
    /// Structured, not VT bytes: SES stores and returns it without ever
    /// learning what it means.
    pub fn serialize(self: *const NamespaceTable, allocator: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        var w = out.writer(allocator);

        try w.writeByte(BLOB_VERSION);
        const count_at = out.items.len;
        try w.writeByte(0); // namespace count, patched up below

        var written: u8 = 0;
        for (self.palettes, 0..) |maybe, slot| {
            const palette = maybe orelse continue;

            var patched: u16 = 0;
            for (palette.patched) |p| {
                if (p) patched += 1;
            }
            const has_defaults = palette.fg != null or palette.bg != null or palette.cursor != null;
            if (patched == 0 and !has_defaults) continue;
            if (written == std.math.maxInt(u8)) break;

            // Stop before the wire cap rather than sailing past it. A blob over
            // MAX_BLOB_LEN is refused wholesale by the receiver, so an
            // unbounded writer here means a pane with many populated
            // namespaces persists NOTHING — losing every colour on detach
            // instead of the excess. Unreachable for a realistic pane (a
            // handful of namespaces is a few KB); this is the bound that keeps
            // the failure proportional if one ever gets there.
            const record_len = 1 + 2 + @as(usize, patched) * 4 + 12;
            if (out.items.len + record_len > MAX_BLOB_LEN) break;

            // The slot IS the identity. Nothing to re-derive on the way back in,
            // so a restored blob cannot land a colour on a different namespace
            // than the one that set it.
            try w.writeByte(@intCast(slot));
            try w.writeInt(u16, patched, .big);
            for (palette.patched, 0..) |p, idx| {
                if (!p) continue;
                const c = palette.entries[idx];
                try w.writeAll(&[_]u8{ @intCast(idx), c.r, c.g, c.b });
            }
            try writeOptionalRgb(&w, palette.fg);
            try writeOptionalRgb(&w, palette.bg);
            try writeOptionalRgb(&w, palette.cursor);
            written += 1;
        }

        out.items[count_at] = written;
        if (written == 0) {
            out.deinit(allocator);
            return try allocator.alloc(u8, 0);
        }
        return try out.toOwnedSlice(allocator);
    }

    /// Restore a blob produced by `serialize`.
    ///
    /// Every field is bounds-checked against the buffer: the blob round-trips
    /// through another process, so a truncated or garbled one must degrade to
    /// "fewer namespaces restored", never to a crash or a wild read.
    pub fn applySerialized(self: *NamespaceTable, blob: []const u8) void {
        var reader = BlobReader.init(blob);
        while (reader.next()) |ns| {
            // A name the blob carries but this table has never seen is created
            // here; an exhausted table yields slot 0 and the entries are
            // dropped, which is the same degradation as everywhere else.
            const slot = ns.slot;
            var i: usize = 0;
            while (i < ns.count()) : (i += 1) {
                const entry = ns.at(i);
                self.setEntry(slot, entry.index, entry.rgb);
            }
            if (self.palettes[slot]) |p| {
                if (ns.fg) |c| p.fg = c;
                if (ns.bg) |c| p.bg = c;
                if (ns.cursor) |c| p.cursor = c;
            }
        }
    }
};

/// Reads a blob produced by `serialize`, one namespace at a time.
///
/// The ONE parser for the format. `applySerialized` and `hexe palette get` both
/// go through it, so a bounds check added here covers both — two hand-rolled
/// parsers of the same byte layout is how a format grows divergent bugs.
///
/// Every field is checked against the buffer. A truncated or garbled blob ends
/// the iteration early rather than reading past the end: the bytes round-trip
/// through another process, so "fewer namespaces than expected" is the only
/// acceptable failure.
pub const BlobReader = struct {
    blob: []const u8,
    off: usize = 0,
    remaining: usize = 0,

    pub const Entry = struct { index: u8, rgb: RGB };

    pub const Namespace = struct {
        slot: u8,
        /// Raw 4-byte records: index, r, g, b.
        records: []const u8,
        fg: ?RGB = null,
        bg: ?RGB = null,
        cursor: ?RGB = null,

        pub fn count(self: Namespace) usize {
            return self.records.len / 4;
        }

        pub fn at(self: Namespace, i: usize) Entry {
            const rec = self.records[i * 4 ..][0..4];
            return .{ .index = rec[0], .rgb = .{ .r = rec[1], .g = rec[2], .b = rec[3] } };
        }
    };

    pub fn init(blob: []const u8) BlobReader {
        if (blob.len < 2 or blob[0] != BLOB_VERSION) return .{ .blob = blob };
        return .{ .blob = blob, .off = 2, .remaining = blob[1] };
    }

    pub fn next(self: *BlobReader) ?Namespace {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        const blob = self.blob;

        if (self.off >= blob.len) return self.stop();
        const slot = blob[self.off];
        self.off += 1;
        if (slot >= MAX_NS) return self.stop();

        if (self.off + 2 > blob.len) return self.stop();
        const entries = std.mem.readInt(u16, blob[self.off..][0..2], .big);
        self.off += 2;
        if (entries > 256) return self.stop();
        const bytes = @as(usize, entries) * 4;
        if (self.off + bytes > blob.len) return self.stop();
        const records = blob[self.off .. self.off + bytes];
        self.off += bytes;

        const fg = readOptionalRgb(blob, &self.off) orelse return self.stop();
        const bg = readOptionalRgb(blob, &self.off) orelse return self.stop();
        const cursor = readOptionalRgb(blob, &self.off) orelse return self.stop();

        return .{
            .slot = slot,
            .records = records,
            .fg = if (fg.present) fg.value else null,
            .bg = if (bg.present) bg.value else null,
            .cursor = if (cursor.present) cursor.value else null,
        };
    }

    fn stop(self: *BlobReader) ?Namespace {
        self.remaining = 0;
        return null;
    }
};

/// Bumped whenever the blob layout changes. A reader that does not recognise
/// the version restores nothing rather than misreading it.
pub const BLOB_VERSION: u8 = 1;

/// A serialized blob larger than this is refused rather than stored. 255
/// namespaces of 256 colours is ~262 KB; nothing legitimate approaches it, and
/// SES should not hold an unbounded buffer per pane on a pane's say-so.
/// Upper bound on a serialized table.
///
/// Sized to stay under the frontend client's queued-push payload cap once the
/// wire header is added (`ses_client_responses.MAX_QUEUED_PUSH_PAYLOAD`, which
/// exists so a replay pipe write cannot block). A blob larger than that cap is
/// dropped when the parked-palette answer races a synchronous request, and the
/// request is fire-and-forget, so nothing retries: the pane reattaches with no
/// colours. A compile-time check in that file keeps the two from drifting.
pub const MAX_BLOB_LEN: usize = 56 * 1024;

const OptionalRgb = struct { present: bool, value: RGB };

fn writeOptionalRgb(w: anytype, value: ?RGB) !void {
    if (value) |c| {
        try w.writeAll(&[_]u8{ 1, c.r, c.g, c.b });
    } else {
        try w.writeAll(&[_]u8{ 0, 0, 0, 0 });
    }
}

fn readOptionalRgb(blob: []const u8, off: *usize) ?OptionalRgb {
    if (off.* + 4 > blob.len) return null;
    const rec = blob[off.*..][0..4];
    off.* += 4;
    return .{
        .present = rec[0] != 0,
        .value = .{ .r = rec[1], .g = rec[2], .b = rec[3] },
    };
}

const StackEntry = struct {
    prev_current: u8 = 0,
};

/// Default OSC number (PLAN.md Decision #5), adjacent to OSC 133.
pub const DEFAULT_OSC = 1330;

/// OSC numbers hexe already forwards or consumes, and which `palette.osc`
/// must therefore not claim.
///
/// The dispatch checks the configured number BEFORE the ordinary families, so
/// `palette.osc = 4` would quietly stop OSC 4 reaching the terminal — the very
/// sequence that sets the base palette this feature layers on top of. A config
/// that breaks colour handling to enable colour handling is worth refusing.
///
/// Mirrors `pane_output.isPassthroughOscCode` / `isConsumedOscCode`; the two
/// lists are small, stable and deliberately duplicated rather than coupling
/// core to a frontend file.
pub fn isReservedOsc(code: u32) bool {
    return switch (code) {
        0, 1, 2, 7 => true, // title / icon / cwd
        4, 5, 104, 105 => true, // palette control and resets
        9, 99, 777 => true, // progress and notifications
        10...19, 50...59, 110...119 => true, // dynamic colour and font families
        133 => true, // semantic prompt marks, which the zones are read from
        else => false,
    };
}

/// Process-wide settings from `hexe.palette` in the config.
///
/// A frontend process serves one session and the config is global to it, so
/// this is a setting rather than shared mutable state: panes read it when their
/// table is created, and a reload re-applies it to the panes that already exist.
pub var default_enabled: bool = false;
pub var default_osc: u32 = DEFAULT_OSC;
/// PLAN.md §6: how many entries a SENDER should put in one `set`. Advice for
/// senders whose other terminals cap an OSC payload — the receiver accepts
/// however many actually arrive.
pub const SET_CHUNK = 32;

/// What the caller must do after applying a sequence.
pub const Applied = union(enum) {
    /// Unrecognised or malformed: discard, exactly as a non-hexe terminal does.
    ignore,
    /// Palette state changed; the pane needs a repaint.
    changed,
    /// `ask` — the caller should emit `have`. Silence means unsupported, so
    /// this is the one verb hexe answers.
    have: struct { osc: u32, free: u16 },
};

/// Apply one OSC 1330 payload: everything after the OSC number and its `;`.
///
/// Applies straight to the table rather than returning a command struct — a
/// `set` carries up to 32 entries and copying that per sequence buys nothing.
/// Every verb is idempotent, which is what makes replay after a detach safe
/// (PLAN.md §6, replay contract).
pub fn applyOsc(self: *NamespaceTable, params: []const u8) Applied {
    var it = std.mem.splitScalar(u8, params, ';');
    const verb = it.next() orelse return .ignore;

    if (eqlFold(verb, "end")) {
        self.pop();
        return .changed;
    }
    if (eqlFold(verb, "ask")) {
        // Silence is the documented "unsupported" answer, and a table that is
        // switched off IS unsupported: its colours resolve to nothing. Replying
        // `have` here would hand a client a false positive on the single check
        // the protocol gives it, and it would then set colours that never
        // render. Every other verb stays accepted — they persist, and flipping
        // the flag on later shows them.
        if (!self.enabled) return .ignore;
        return .{ .have = .{ .osc = self.osc, .free = self.maxSlot() } };
    }

    const target = it.next() orelse return .ignore;

    if (eqlFold(verb, "use")) {
        // Out of range selects nothing rather than guessing: silently folding
        // slot 40 onto slot 8 would paint cells with another caller's colours.
        const slot = NamespaceTable.parseSlot(target) orelse return .ignore;
        self.push(slot);
        return .changed;
    }
    if (eqlFold(verb, "reset")) {
        return if (self.reset(target)) .changed else .ignore;
    }
    if (!eqlFold(verb, "set")) return .ignore;

    // `*` addresses every slot, 0 included.
    const all = std.mem.eql(u8, target, "*");
    const one: ?u8 = if (all) null else (NamespaceTable.parseSlot(target) orelse return .ignore);
    var touched = false;
    // No cap on entries accepted. SET_CHUNK is advice to SENDERS, whose other
    // terminals may cap an OSC payload; refusing the 33rd entry of a sequence
    // that already arrived intact just loses colours silently. The payload is
    // already bounded upstream by the OSC buffer limit.
    while (it.next()) |field| {
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const rgb = parseHexColor(field[eq + 1 ..]) orelse continue;
        const key = field[0..eq];
        if (all) {
            // Only slots something has already touched: `*` means "everything
            // in use", not "allocate all 32".
            var slot: u16 = 0;
            while (slot < MAX_NS) : (slot += 1) {
                if (self.palettes[slot] != null and applyKey(self, @intCast(slot), key, rgb)) touched = true;
            }
        } else if (applyKey(self, one.?, key, rgb)) {
            touched = true;
        }
    }
    return if (touched) .changed else .ignore;
}

/// One `<key>=#rrggbb` pair. `fg`/`bg`/`cursor` address the defaults; anything
/// else must be a decimal index.
fn applyKey(self: *NamespaceTable, slot: u8, key: []const u8, rgb: RGB) bool {
    const palette = self.ensure(slot) orelse return false;
    if (eqlFold(key, "fg")) {
        palette.fg = rgb;
        return true;
    }
    if (eqlFold(key, "bg")) {
        palette.bg = rgb;
        return true;
    }
    if (eqlFold(key, "cursor")) {
        palette.cursor = rgb;
        return true;
    }
    const idx = std.fmt.parseUnsigned(u16, key, 10) catch return false;
    if (idx > 255) return false;
    self.setEntry(slot, @intCast(idx), rgb);
    return true;
}

/// `#rrggbb`, `rrggbb`, or the `rgb:rr/gg/bb` form OSC 4 already uses.
pub fn parseHexColor(text: []const u8) ?RGB {
    var body = text;
    if (std.mem.startsWith(u8, body, "#")) body = body[1..];
    if (eqlFold(if (body.len >= 4) body[0..4] else body, "rgb:")) {
        body = body[4..];
        var parts = std.mem.splitScalar(u8, body, '/');
        const r = parseHexByte(parts.next() orelse return null) orelse return null;
        const g = parseHexByte(parts.next() orelse return null) orelse return null;
        const b = parseHexByte(parts.next() orelse return null) orelse return null;
        if (parts.next() != null) return null;
        return .{ .r = r, .g = g, .b = b };
    }
    if (body.len != 6) return null;
    return .{
        .r = parseHexByte(body[0..2]) orelse return null,
        .g = parseHexByte(body[2..4]) orelse return null,
        .b = parseHexByte(body[4..6]) orelse return null,
    };
}

/// `rgb:` components may be 1-4 hex digits wide; scale to 8 bits.
fn parseHexByte(text: []const u8) ?u8 {
    if (text.len == 0 or text.len > 4) return null;
    const value = std.fmt.parseUnsigned(u16, text, 16) catch return null;
    return switch (text.len) {
        1 => @intCast(value * 0x11),
        2 => @intCast(value),
        3 => @intCast(value >> 4),
        4 => @intCast(value >> 8),
        else => unreachable,
    };
}

fn eqlFold(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

test "slot 0 is what an unselected cell resolves against" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    t.setEnabled(true);

    // Untouched: the index passes through and the terminal's own theme wins.
    try std.testing.expectEqual(@as(u8, 7), t.resolveIndex(0, 7).passthrough);

    // Set it, and every cell that selected nothing follows — this is how a
    // caller recolours the ordinary indexed palette for the pane.
    _ = applyOsc(&t, "set;0;7=#123456");
    try std.testing.expectEqual(RGB{ .r = 0x12, .g = 0x34, .b = 0x56 }, t.resolveIndex(0, 7).rgb);
    // Indices nobody set still pass through: `set` is a patch, not a replace.
    try std.testing.expectEqual(@as(u8, 8), t.resolveIndex(0, 8).passthrough);
}

test "a slot number is the address, with no mapping to lose" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    t.setEnabled(true);

    _ = applyOsc(&t, "set;3;1=#ff0000");
    _ = applyOsc(&t, "set;9;1=#00ff00");

    try std.testing.expectEqual(@as(u8, 0xff), t.resolveIndex(3, 1).rgb.r);
    try std.testing.expectEqual(@as(u8, 0xff), t.resolveIndex(9, 1).rgb.g);
    // Slots nobody set are untouched, whatever order they were addressed in.
    try std.testing.expect(t.resolveIndex(4, 1) == .passthrough);
}

test "use selects a slot and end restores the previous one" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    t.setEnabled(true);

    try std.testing.expectEqual(@as(u8, 0), t.currentSlot());
    _ = applyOsc(&t, "use;5");
    try std.testing.expectEqual(@as(u8, 5), t.currentSlot());
    _ = applyOsc(&t, "use;6");
    try std.testing.expectEqual(@as(u8, 6), t.currentSlot());
    _ = applyOsc(&t, "end");
    try std.testing.expectEqual(@as(u8, 5), t.currentSlot());
    _ = applyOsc(&t, "end");
    try std.testing.expectEqual(@as(u8, 0), t.currentSlot());
    // Underflow is a no-op, not an error.
    _ = applyOsc(&t, "end");
    try std.testing.expectEqual(@as(u8, 0), t.currentSlot());
}

test "a slot outside the range selects nothing rather than folding onto one" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    t.setEnabled(true);
    _ = applyOsc(&t, "use;7");

    // 32, 40 and 255 must not wrap onto 0, 8 or 31 — that would paint cells
    // with another caller's colours.
    for ([_][]const u8{ "use;32", "use;40", "use;255", "use;-1", "use;x", "use;" }) |seq| {
        try std.testing.expect(applyOsc(&t, seq) == .ignore);
        try std.testing.expectEqual(@as(u8, 7), t.currentSlot());
    }
    try std.testing.expect(NamespaceTable.parseSlot("31") != null);
    try std.testing.expect(NamespaceTable.parseSlot("32") == null);
}

test "the feature flag forces slot 0 with the indirection compiled in" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    t.setEnabled(true);
    _ = applyOsc(&t, "set;2;1=#ff0000");
    _ = applyOsc(&t, "use;2");
    try std.testing.expectEqual(@as(u8, 2), t.currentSlot());

    t.setEnabled(false);
    try std.testing.expectEqual(@as(u8, 0), t.currentSlot());
    // Colours set while off are kept, so re-enabling shows them again.
    t.setEnabled(true);
    try std.testing.expectEqual(@as(u8, 0xff), t.resolveIndex(2, 1).rgb.r);
}

test "set patches entries, defaults, and every slot with *" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    t.setEnabled(true);

    _ = applyOsc(&t, "set;1;1=#010203;fg=#040506;bg=#070809;cursor=#0a0b0c");
    try std.testing.expectEqual(RGB{ .r = 1, .g = 2, .b = 3 }, t.resolveIndex(1, 1).rgb);
    try std.testing.expectEqual(RGB{ .r = 4, .g = 5, .b = 6 }, t.defaultsFor(1).fg.?);
    try std.testing.expectEqual(RGB{ .r = 7, .g = 8, .b = 9 }, t.defaultsFor(1).bg.?);
    try std.testing.expectEqual(RGB{ .r = 10, .g = 11, .b = 12 }, t.cursorFor(1).?);

    _ = applyOsc(&t, "set;2;1=#000000");
    try std.testing.expect(applyOsc(&t, "set;*;5=#ffffff") == .changed);
    // Every slot already in use, slot 0 included once it has been touched.
    try std.testing.expectEqual(@as(u8, 0xff), t.resolveIndex(1, 5).rgb.r);
    try std.testing.expectEqual(@as(u8, 0xff), t.resolveIndex(2, 5).rgb.r);
    // A slot nobody has touched is not conjured into existence by `*`.
    try std.testing.expect(t.resolveIndex(30, 5) == .passthrough);
}

test "reset forgets a slot's colours, and * forgets all of them" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    t.setEnabled(true);
    _ = applyOsc(&t, "set;1;1=#ff0000");
    _ = applyOsc(&t, "set;2;1=#00ff00");

    try std.testing.expect(applyOsc(&t, "reset;1") == .changed);
    try std.testing.expect(t.resolveIndex(1, 1) == .passthrough);
    try std.testing.expectEqual(@as(u8, 0xff), t.resolveIndex(2, 1).rgb.g);

    _ = applyOsc(&t, "reset;*");
    try std.testing.expect(t.resolveIndex(2, 1) == .passthrough);
}

test "ask answers have with the addressable ceiling, and is silent when off" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();

    t.setEnabled(false);
    try std.testing.expect(applyOsc(&t, "ask") == .ignore);

    t.setEnabled(true);
    const reply = applyOsc(&t, "ask");
    try std.testing.expect(reply == .have);
    try std.testing.expectEqual(t.osc, reply.have.osc);
    try std.testing.expectEqual(@as(u16, MAX_NS - 1), reply.have.free);
}

test "a blob round-trips by slot, so a colour cannot land on another namespace" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    t.setEnabled(true);
    _ = applyOsc(&t, "set;0;1=#111111");
    _ = applyOsc(&t, "set;4;7=#ff0000;bg=#222222");
    _ = applyOsc(&t, "set;31;7=#00ff00");
    _ = applyOsc(&t, "use;4");

    const blob = try t.serialize(std.testing.allocator);
    defer std.testing.allocator.free(blob);

    var restored = NamespaceTable.init(std.testing.allocator);
    defer restored.deinit();
    restored.setEnabled(true);
    restored.applySerialized(blob);

    // Same numbers on the way back, with nothing re-derived in between.
    try std.testing.expectEqual(@as(u8, 0x11), restored.resolveIndex(0, 1).rgb.r);
    try std.testing.expectEqual(@as(u8, 0xff), restored.resolveIndex(4, 7).rgb.r);
    try std.testing.expectEqual(@as(u8, 0xff), restored.resolveIndex(31, 7).rgb.g);
    try std.testing.expectEqual(RGB{ .r = 0x22, .g = 0x22, .b = 0x22 }, restored.defaultsFor(4).bg.?);
    // Selection belongs to the running program, never to the parked state.
    try std.testing.expectEqual(@as(u8, 0), restored.currentSlot());
}

test "a truncated or garbled blob restores what it can and never faults" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    t.setEnabled(true);
    _ = applyOsc(&t, "set;1;1=#010203");
    _ = applyOsc(&t, "set;2;1=#040506");
    const blob = try t.serialize(std.testing.allocator);
    defer std.testing.allocator.free(blob);

    var cut: usize = 0;
    while (cut <= blob.len) : (cut += 1) {
        var r = NamespaceTable.init(std.testing.allocator);
        defer r.deinit();
        r.setEnabled(true);
        r.applySerialized(blob[0..cut]);
    }

    // A slot byte past the ceiling ends the read rather than indexing out.
    var forged = try std.testing.allocator.dupe(u8, blob);
    defer std.testing.allocator.free(forged);
    if (forged.len > 2) forged[2] = 200;
    var r2 = NamespaceTable.init(std.testing.allocator);
    defer r2.deinit();
    r2.setEnabled(true);
    r2.applySerialized(forged);
}

test "applyOsc never faults on arbitrary bytes" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    t.setEnabled(true);

    const verbs = [_][]const u8{ "set", "use", "end", "reset", "ask", "", "SET", "sett", ";;;", "drop" };
    const targets = [_][]const u8{ "0", "31", "32", "999", "-1", "*", "", "x", "1.5", "\x00" };
    const pairs = [_][]const u8{ "1=#ff0000", "1=", "=#ff0000", "1=#gg0000", "noequals", "999=#ffffff", "" };
    for (verbs) |v| {
        for (targets) |n| {
            for (pairs) |pair| {
                var buf: [64]u8 = undefined;
                const seq = std.fmt.bufPrint(&buf, "{s};{s};{s}", .{ v, n, pair }) catch continue;
                _ = applyOsc(&t, seq);
            }
        }
    }
}

test "colour forms, and malformed payloads are discarded" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    t.setEnabled(true);

    _ = applyOsc(&t, "set;1;1=#ff8000;2=ff8000;3=rgb:ff/80/00");
    for ([_]u8{ 1, 2, 3 }) |idx| {
        try std.testing.expectEqual(RGB{ .r = 0xff, .g = 0x80, .b = 0x00 }, t.resolveIndex(1, idx).rgb);
    }
    // Nothing usable: the slot keeps what it had.
    try std.testing.expect(applyOsc(&t, "set;1;4=#gg0000") == .ignore);
    try std.testing.expect(t.resolveIndex(1, 4) == .passthrough);
}

test "reserved OSC numbers cannot be claimed by the config" {
    try std.testing.expect(isReservedOsc(4));
    try std.testing.expect(isReservedOsc(133));
    try std.testing.expect(isReservedOsc(52));
    try std.testing.expect(!isReservedOsc(DEFAULT_OSC));
    try std.testing.expect(!isReservedOsc(1331));
}
