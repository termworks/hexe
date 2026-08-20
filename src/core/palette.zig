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
/// Slots must fit the tag carried on each cell, which is 5 bits of ghostty's
/// style flags (patches/ghostty-vt-ns.patch). Widening it to a byte grew the
/// style struct and cost ~19MB resident per frontend, which is not worth 224
/// more namespaces than any pane uses.
pub const MAX_NS = 32;
/// PLAN.md §3.2: the spec floor is 8.
pub const STACK_DEPTH = 16;
/// Names are `[a-z0-9_.-]{1,32}`, case-insensitive (PLAN.md §6).
pub const MAX_NAME_LEN = 32;

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
        var it = self.names.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.names.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator };
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
        if (ns == 0) return .{};
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
        if (ns == 0) return .{ .passthrough = idx };
        if (ns >= MAX_NS) return .{ .passthrough = idx };
        const palette = self.palettes[ns] orelse return .{ .passthrough = idx };
        if (!palette.patched[idx]) return .{ .passthrough = idx };
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

        // u16, deliberately. A u8 counter is always `< MAX_NS` (256), so the
        // loop's real bound would be an interior `== 255` guard and the
        // increment at 255 would wrap — an infinite loop on the OSC path the
        // moment anyone reordered the guard.
        var free_slot: u16 = 1;
        while (free_slot < MAX_NS and self.palettes[free_slot] != null) : (free_slot += 1) {}
        if (free_slot >= MAX_NS) return 0;
        const slot: u8 = @intCast(free_slot);

        const owned = self.allocator.dupe(u8, name) catch return 0;
        const palette = self.allocator.create(Palette) catch {
            self.allocator.free(owned);
            return 0;
        };
        palette.* = .{};
        self.names.put(self.allocator, owned, slot) catch {
            self.allocator.free(owned);
            self.allocator.destroy(palette);
            return 0;
        };
        self.palettes[slot] = palette;
        return slot;
    }

    /// Patch entries in a namespace. Creating it if needed; never selects it.
    pub fn setEntry(self: *NamespaceTable, slot: u8, idx: u8, value: RGB) void {
        if (slot == 0) return;
        if (slot >= MAX_NS) return;
        const palette = self.palettes[slot] orelse return;
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

    /// Stop applying a namespace: deselect it if it is current.
    ///
    /// The name stays bound to its slot and the colours stay with it. Cells
    /// already drawn reference the slot, so unbinding the name would let a
    /// later namespace take that slot and recolour history — PLAN.md Decision
    /// #3 chose never-release over walking scrollback to bake them. `use` on
    /// the same name therefore restores it exactly.
    pub fn drop(self: *NamespaceTable, name: []const u8) void {
        const slot = self.names.get(name) orelse return;
        if (self.current == slot) self.current = 0;
    }

    /// Forget every colour a namespace was given, returning its cells to the
    /// terminal's own theme.
    ///
    /// Not in PLAN.md §6, and it should have been: `set` is a patch and `drop`
    /// releases the *binding*, so before this there was no way to undo a
    /// colour at all — a mistyped hex code was permanent for the life of the
    /// pane. `*` resets every live namespace.
    pub fn reset(self: *NamespaceTable, name: []const u8) bool {
        if (std.mem.eql(u8, name, "*")) {
            var any = false;
            for (self.palettes) |maybe| {
                const p = maybe orelse continue;
                p.* = .{};
                any = true;
            }
            return any;
        }
        const slot = self.names.get(name) orelse return false;
        if (slot >= MAX_NS) return false;
        const p = self.palettes[slot] orelse return false;
        p.* = .{};
        return true;
    }

    /// How many slots a `have` reply should advertise as free.
    pub fn freeSlots(self: *const NamespaceTable) u16 {
        var free: u16 = 0;
        var slot: u16 = 1;
        while (slot < MAX_NS) : (slot += 1) {
            if (self.palettes[slot] == null) free += 1;
        }
        return free;
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
        var it = self.names.iterator();
        while (it.next()) |entry| {
            const slot = entry.value_ptr.*;
            const palette = self.palettes[slot] orelse continue;
            const name = entry.key_ptr.*;
            if (name.len == 0 or name.len > MAX_NAME_LEN) continue;

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
            const record_len = 1 + name.len + 2 + @as(usize, patched) * 4 + 12;
            if (out.items.len + record_len > MAX_BLOB_LEN) break;

            try w.writeByte(@intCast(name.len));
            try w.writeAll(name);
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
            const slot = self.slotFor(ns.name);
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
        name: []const u8,
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
        const name_len = blob[self.off];
        self.off += 1;
        if (name_len == 0 or name_len > MAX_NAME_LEN) return self.stop();
        if (self.off + name_len > blob.len) return self.stop();
        const name = blob[self.off .. self.off + name_len];
        self.off += name_len;

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
            .name = name,
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
        return .{ .have = .{ .osc = self.osc, .free = self.freeSlots() } };
    }

    var name_buf: [MAX_NAME_LEN]u8 = undefined;
    const raw_name = it.next() orelse return .ignore;
    const name = foldName(&name_buf, raw_name) orelse return .ignore;

    if (eqlFold(verb, "use")) {
        // An unknown-but-valid name creates the namespace; an exhausted table
        // yields slot 0, which is "behave as before" rather than an error.
        self.push(self.slotFor(name));
        return .changed;
    }
    if (eqlFold(verb, "drop")) {
        self.drop(name);
        return .changed;
    }
    if (eqlFold(verb, "reset")) {
        return if (self.reset(name)) .changed else .ignore;
    }
    if (!eqlFold(verb, "set")) return .ignore;

    // `*` addresses every live namespace (PLAN.md §6).
    const all = std.mem.eql(u8, name, "*");
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
            var slot: u16 = 1;
            while (slot < MAX_NS) : (slot += 1) {
                if (self.palettes[slot] != null and applyKey(self, @intCast(slot), key, rgb)) touched = true;
            }
        } else {
            const slot = self.slotFor(name);
            if (applyKey(self, slot, key, rgb)) touched = true;
        }
    }
    return if (touched) .changed else .ignore;
}

/// One `<key>=#rrggbb` pair. `fg`/`bg`/`cursor` address the defaults; anything
/// else must be a decimal index.
fn applyKey(self: *NamespaceTable, slot: u8, key: []const u8, rgb: RGB) bool {
    if (slot == 0) return false;
    const palette = self.palettes[slot] orelse return false;
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

/// Lowercase a name into `buf`. Returns null if it cannot be a valid name,
/// so a malformed one is discarded rather than silently truncated.
pub fn foldName(buf: *[MAX_NAME_LEN]u8, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "*")) return "*";
    if (name.len == 0 or name.len > MAX_NAME_LEN) return null;
    for (name, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    const folded = buf[0..name.len];
    return if (validName(folded)) folded else null;
}

fn eqlFold(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

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
    // An index the patch did not name still passes through, so a namespace
    // with one entry set does not blacken the other 255.
    try std.testing.expectEqual(@as(u8, 4), t.resolveIndex(slot, 4).passthrough);
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

test "set patches entries and creates the namespace" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    t.setEnabled(true);

    try std.testing.expect(applyOsc(&t, "set;prompt;4=#331111;bg=#0a0a0a") == .changed);
    const slot = t.slotFor("prompt");
    try std.testing.expectEqual(@as(u8, 0x33), t.resolveIndex(slot, 4).rgb.r);
    try std.testing.expectEqual(@as(u8, 0x0a), t.palettes[slot].?.bg.?.r);

    // Accumulates rather than replacing (Decision #4).
    try std.testing.expect(applyOsc(&t, "set;prompt;5=#00ff00") == .changed);
    try std.testing.expectEqual(@as(u8, 0x33), t.resolveIndex(slot, 4).rgb.r);
    try std.testing.expectEqual(@as(u8, 0xff), t.resolveIndex(slot, 5).rgb.g);
}

test "colour forms, and malformed payloads are discarded" {
    try std.testing.expectEqual(@as(u8, 0x33), parseHexColor("#331111").?.r);
    try std.testing.expectEqual(@as(u8, 0x33), parseHexColor("331111").?.r);
    try std.testing.expectEqual(@as(u8, 0xab), parseHexColor("rgb:ab/cd/ef").?.r);
    try std.testing.expectEqual(@as(u8, 0xff), parseHexColor("rgb:ffff/0/0").?.r);
    try std.testing.expect(parseHexColor("#33111") == null);
    try std.testing.expect(parseHexColor("#gg1111") == null);
    try std.testing.expect(parseHexColor("") == null);

    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    t.setEnabled(true);
    try std.testing.expect(applyOsc(&t, "") == .ignore);
    try std.testing.expect(applyOsc(&t, "wat;prompt;1=#000000") == .ignore);
    try std.testing.expect(applyOsc(&t, "set;prompt") == .ignore);
    try std.testing.expect(applyOsc(&t, "set;prompt;300=#000000") == .ignore);
    try std.testing.expect(applyOsc(&t, "set;prompt;1=notacolour") == .ignore);
    try std.testing.expect(applyOsc(&t, "set;" ++ "x" ** 33 ++ ";1=#000000") == .ignore);
    try std.testing.expect(applyOsc(&t, "set;Not Valid;1=#000000") == .ignore);
}

test "names fold case and set is idempotent across replays" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    t.setEnabled(true);

    _ = applyOsc(&t, "set;NVIM;1=#010203");
    _ = applyOsc(&t, "set;nvim;1=#010203");
    const slot = t.slotFor("nvim");
    try std.testing.expectEqual(@as(u8, 0x01), t.resolveIndex(slot, 1).rgb.r);
    // Two spellings, one namespace: replaying a stream must not burn slots.
    // One slot gone for `nvim`, and slot 0 is never handed out.
    try std.testing.expectEqual(@as(u16, MAX_NS - 1 - 1), t.freeSlots());
}

test "set with * reaches every live namespace but not slot 0" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    t.setEnabled(true);

    _ = applyOsc(&t, "use;alpha");
    _ = applyOsc(&t, "end");
    _ = applyOsc(&t, "set;beta;1=#000000");
    try std.testing.expect(applyOsc(&t, "set;*;2=#123456") == .changed);

    for ([_][]const u8{ "alpha", "beta" }) |n| {
        try std.testing.expectEqual(@as(u8, 0x12), t.resolveIndex(t.slotFor(n), 2).rgb.r);
    }
    try std.testing.expectEqual(@as(u8, 2), t.resolveIndex(0, 2).passthrough);
}

test "an exhausted table maps use to slot 0" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();

    var buf: [8]u8 = undefined;
    var i: usize = 0;
    while (i < MAX_NS) : (i += 1) {
        _ = t.slotFor(std.fmt.bufPrint(&buf, "n{d}", .{i}) catch unreachable);
    }
    try std.testing.expectEqual(@as(u16, 0), t.freeSlots());
    try std.testing.expectEqual(@as(u8, 0), t.slotFor("overflow"));
}

test "a palette round-trips through a blob" {
    const alloc = std.testing.allocator;
    var a = NamespaceTable.init(alloc);
    defer a.deinit();
    a.setEnabled(true);
    _ = applyOsc(&a, "set;prompt;33=#ff00aa;0=#010203;255=#0a0b0c;bg=#111213");
    _ = applyOsc(&a, "set;output;7=#445566");

    const blob = try a.serialize(alloc);
    defer alloc.free(blob);
    try std.testing.expect(blob.len > 0);

    var b = NamespaceTable.init(alloc);
    defer b.deinit();
    b.setEnabled(true);
    b.applySerialized(blob);

    const p = b.slotFor("prompt");
    try std.testing.expectEqual(@as(u8, 0xff), b.resolveIndex(p, 33).rgb.r);
    try std.testing.expectEqual(@as(u8, 0x03), b.resolveIndex(p, 0).rgb.b);
    try std.testing.expectEqual(@as(u8, 0x0a), b.resolveIndex(p, 255).rgb.r);
    try std.testing.expectEqual(@as(u8, 0x11), b.palettes[p].?.bg.?.r);
    try std.testing.expectEqual(@as(u8, 0x44), b.resolveIndex(b.slotFor("output"), 7).rgb.r);

    // Indices nobody patched stay passthrough on the far side too, or a
    // restore would blacken every zone it touched.
    try std.testing.expectEqual(@as(u8, 9), b.resolveIndex(p, 9).passthrough);
}

test "an empty table serializes to nothing" {
    const alloc = std.testing.allocator;
    var t = NamespaceTable.init(alloc);
    defer t.deinit();
    t.setEnabled(true); // allocates prompt/output/alt, but patches nothing

    const blob = try t.serialize(alloc);
    defer alloc.free(blob);
    try std.testing.expectEqual(@as(usize, 0), blob.len);
}

test "a truncated or garbled blob restores what it can and never faults" {
    const alloc = std.testing.allocator;
    var src = NamespaceTable.init(alloc);
    defer src.deinit();
    src.setEnabled(true);
    _ = applyOsc(&src, "set;prompt;1=#ff0000;2=#00ff00");
    _ = applyOsc(&src, "set;output;3=#0000ff");
    const blob = try src.serialize(alloc);
    defer alloc.free(blob);

    // Every prefix of a valid blob.
    var cut: usize = 0;
    while (cut <= blob.len) : (cut += 1) {
        var t = NamespaceTable.init(alloc);
        defer t.deinit();
        t.setEnabled(true);
        t.applySerialized(blob[0..cut]);
    }

    // Every single-byte corruption of a valid blob.
    const scratch = try alloc.dupe(u8, blob);
    defer alloc.free(scratch);
    for (0..blob.len) |i| {
        for ([_]u8{ 0, 1, 0x7f, 0xff }) |v| {
            @memcpy(scratch, blob);
            scratch[i] = v;
            var t = NamespaceTable.init(alloc);
            defer t.deinit();
            t.setEnabled(true);
            t.applySerialized(scratch);
        }
    }

    // A wrong version restores nothing rather than misreading the layout.
    @memcpy(scratch, blob);
    scratch[0] = BLOB_VERSION +% 1;
    var t = NamespaceTable.init(alloc);
    defer t.deinit();
    t.setEnabled(true);
    t.applySerialized(scratch);
    try std.testing.expectEqual(@as(u8, 1), t.resolveIndex(t.slotFor("prompt"), 1).passthrough);
}

test "reset forgets colours so cells fall back to the terminal theme" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    t.setEnabled(true);

    _ = applyOsc(&t, "set;prompt;33=#ff00aa;bg=#111111");
    const p = t.slotFor("prompt");
    try std.testing.expectEqual(@as(u8, 0xff), t.resolveIndex(p, 33).rgb.r);

    try std.testing.expect(applyOsc(&t, "reset;prompt") == .changed);
    try std.testing.expectEqual(@as(u8, 33), t.resolveIndex(p, 33).passthrough);
    try std.testing.expect(t.palettes[p].?.bg == null);

    // The namespace itself survives, so a later `set` lands in the same slot.
    try std.testing.expectEqual(p, t.slotFor("prompt"));
    // Resetting one that was never coloured is a no-op, not an error.
    try std.testing.expect(applyOsc(&t, "reset;never-used") == .ignore);
}

test "a set larger than the sender chunk is accepted whole" {
    const alloc = std.testing.allocator;
    var t = NamespaceTable.init(alloc);
    defer t.deinit();
    t.setEnabled(true);

    // 200 entries in one sequence. SET_CHUNK is advice to senders; dropping
    // the tail of a sequence that arrived intact would lose colours silently.
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(alloc);
    try payload.appendSlice(alloc, "set;prompt");
    for (0..200) |i| {
        try payload.writer(alloc).print(";{d}=#0000{x:0>2}", .{ i, i });
    }
    try std.testing.expect(applyOsc(&t, payload.items) == .changed);

    const p = t.slotFor("prompt");
    try std.testing.expectEqual(@as(u8, 199), t.resolveIndex(p, 199).rgb.b);
    try std.testing.expectEqual(@as(u8, 200), t.resolveIndex(p, 200).passthrough);
}

test "applyOsc never faults on arbitrary bytes" {
    const alloc = std.testing.allocator;
    // A cheap deterministic fuzz over the shapes a hostile or buggy program
    // can put in an OSC payload: every verb prefix crossed with junk, control
    // bytes, huge numbers, unterminated fields and very long names.
    const verbs = [_][]const u8{ "set", "use", "end", "drop", "reset", "ask", "", "SET", "sett", ";;;" };
    const tails = [_][]const u8{
        "",                   ";",                     ";;",                      ";prompt",
        ";prompt;",           ";prompt;=",             ";prompt;=#",              ";prompt;999999999999=#ff0000",
        ";prompt;-1=#ff0000", ";prompt;1=#gggggg",     ";prompt;1=#ff00",         ";prompt;1=rgb:",
        ";prompt;1=rgb:1/2",  ";prompt;1=rgb:1/2/3/4", ";*;1=#ff0000",            ";" ++ "n" ** 40,
        ";prompt;\x00=\x01",  ";\xff\xfe;1=#ff0000",   ";prompt;fg=;bg=;cursor=", ";default;1=#ff0000",
    };

    for (verbs) |v| {
        for (tails) |tail| {
            var t = NamespaceTable.init(alloc);
            defer t.deinit();
            t.setEnabled(true);
            const payload = try std.mem.concat(alloc, u8, &.{ v, tail });
            defer alloc.free(payload);
            _ = applyOsc(&t, payload);
            _ = applyOsc(&t, payload);
            // Whatever happened, the table is still coherent and slot 0 still
            // passes through — the property every failure mode reduces to.
            try std.testing.expectEqual(@as(u8, 77), t.resolveIndex(0, 77).passthrough);
            try std.testing.expect(t.stack_len <= STACK_DEPTH);
        }
    }
}

test "a table of many namespaces still serializes inside the wire cap" {
    const alloc = std.testing.allocator;
    var t = NamespaceTable.init(alloc);
    defer t.deinit();
    t.setEnabled(true);

    // The worst case a pane can reach: every slot claimed, each with one
    // colour. The cap exists so SES never holds an unbounded buffer on a
    // pane's say-so; this pins that a realistic table stays well under it.
    var buf: [16]u8 = undefined;
    for (0..MAX_NS - 1) |i| {
        const name = std.fmt.bufPrint(&buf, "ns{d}", .{i}) catch unreachable;
        const slot = t.slotFor(name);
        if (slot == 0) break;
        t.setEntry(slot, @intCast(i % 256), .{ .r = 1, .g = 2, .b = 3 });
    }
    const blob = try t.serialize(alloc);
    defer alloc.free(blob);
    try std.testing.expect(blob.len > 0);
    try std.testing.expect(blob.len < MAX_BLOB_LEN);
}

test "BlobReader yields exactly what serialize wrote" {
    const alloc = std.testing.allocator;
    var t = NamespaceTable.init(alloc);
    defer t.deinit();
    t.setEnabled(true);
    _ = applyOsc(&t, "set;prompt;0=#010203;255=#0a0b0c;bg=#111213");
    _ = applyOsc(&t, "set;output;7=#445566;fg=#778899");

    const blob = try t.serialize(alloc);
    defer alloc.free(blob);

    var seen_prompt = false;
    var seen_output = false;
    var reader = BlobReader.init(blob);
    while (reader.next()) |ns| {
        if (std.mem.eql(u8, ns.name, "prompt")) {
            seen_prompt = true;
            try std.testing.expectEqual(@as(usize, 2), ns.count());
            try std.testing.expectEqual(@as(u8, 0), ns.at(0).index);
            try std.testing.expectEqual(@as(u8, 0x03), ns.at(0).rgb.b);
            try std.testing.expectEqual(@as(u8, 255), ns.at(1).index);
            try std.testing.expectEqual(@as(u8, 0x11), ns.bg.?.r);
            try std.testing.expect(ns.fg == null);
        } else if (std.mem.eql(u8, ns.name, "output")) {
            seen_output = true;
            try std.testing.expectEqual(@as(usize, 1), ns.count());
            try std.testing.expectEqual(@as(u8, 0x77), ns.fg.?.r);
            try std.testing.expect(ns.bg == null);
        } else {
            return error.UnexpectedNamespace;
        }
    }
    try std.testing.expect(seen_prompt and seen_output);
    // Exhausted readers keep answering null rather than restarting.
    try std.testing.expect(reader.next() == null);
}

test "BlobReader refuses a blob it does not understand" {
    var empty = BlobReader.init(&.{});
    try std.testing.expect(empty.next() == null);
    var short = BlobReader.init(&[_]u8{BLOB_VERSION});
    try std.testing.expect(short.next() == null);
    // Right length, wrong version: yields nothing rather than misreading.
    const wrong = [_]u8{ BLOB_VERSION +% 1, 1, 6 } ++ "prompt".* ++ [_]u8{ 0, 0 };
    var r = BlobReader.init(&wrong);
    try std.testing.expect(r.next() == null);
    // Claims one namespace, provides no bytes for it.
    const lying = [_]u8{ BLOB_VERSION, 1 };
    var r2 = BlobReader.init(&lying);
    try std.testing.expect(r2.next() == null);
}

test "serialize stops at the wire cap instead of overflowing it" {
    const alloc = std.testing.allocator;
    var t = NamespaceTable.init(alloc);
    defer t.deinit();
    t.setEnabled(true);

    // Every slot claimed, every one fully populated: far past MAX_BLOB_LEN if
    // the writer were unbounded (255 x ~1KB).
    var buf: [16]u8 = undefined;
    for (0..MAX_NS - 1) |i| {
        const name = std.fmt.bufPrint(&buf, "n{d}", .{i}) catch unreachable;
        const slot = t.slotFor(name);
        if (slot == 0) break;
        var idx: u16 = 0;
        while (idx < 256) : (idx += 1) {
            t.setEntry(slot, @intCast(idx), .{ .r = 1, .g = 2, .b = 3 });
        }
    }

    const blob = try t.serialize(alloc);
    defer alloc.free(blob);
    try std.testing.expect(blob.len <= MAX_BLOB_LEN);
    try std.testing.expect(blob.len > 0);

    // What it did write is still a coherent blob, not a truncated one: every
    // namespace in it round-trips.
    var restored = NamespaceTable.init(alloc);
    defer restored.deinit();
    restored.setEnabled(true);
    restored.applySerialized(blob);

    var reader = BlobReader.init(blob);
    var count: usize = 0;
    while (reader.next()) |ns| {
        count += 1;
        try std.testing.expectEqual(@as(usize, 256), ns.count());
        try std.testing.expectEqual(@as(u8, 1), restored.resolveIndex(restored.slotFor(ns.name), 7).rgb.r);
    }
    try std.testing.expect(count > 0);
}

test "reserved OSC numbers cannot be claimed by the config" {
    // Everything hexe forwards or consumes. Claiming one would make the
    // palette dispatch swallow it before it reached its real handler.
    for ([_]u32{ 0, 1, 2, 4, 5, 7, 9, 10, 12, 19, 50, 59, 99, 104, 105, 110, 119, 133, 777 }) |code| {
        try std.testing.expect(isReservedOsc(code));
    }
    // The default and its neighbours are free, or the feature could not ship.
    for ([_]u32{ DEFAULT_OSC, 1331, 3, 8, 20, 49, 60, 98, 100, 120, 1000 }) |code| {
        try std.testing.expect(!isReservedOsc(code));
    }
}

test "ask is silent while the feature is off" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();

    // Off: no reply at all. A client reads silence as "not supported" and
    // falls back, which is the truth — colours would resolve to nothing.
    try std.testing.expect(!t.enabled);
    try std.testing.expect(applyOsc(&t, "ask") == .ignore);

    // On: the capability answer, carrying the live OSC number.
    t.setEnabled(true);
    const reply = applyOsc(&t, "ask");
    try std.testing.expectEqual(@as(u32, DEFAULT_OSC), reply.have.osc);

    // Off again, mid-session: still silent, even though the namespaces and
    // their colours are still there and would come back with the flag.
    _ = applyOsc(&t, "set;prompt;3=#ff0000");
    t.setEnabled(false);
    try std.testing.expect(applyOsc(&t, "ask") == .ignore);
    try std.testing.expect(applyOsc(&t, "set;prompt;4=#00ff00") == .changed);
    t.setEnabled(true);
    try std.testing.expectEqual(@as(u8, 0x00), t.resolveIndex(t.slotFor("prompt"), 4).rgb.r);
    try std.testing.expectEqual(@as(u8, 0xff), t.resolveIndex(t.slotFor("prompt"), 4).rgb.g);
}

test "the stack drops a push past its depth instead of losing a restore point" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    t.setEnabled(true);

    const first = t.slotFor("first");
    t.push(first);
    var i: usize = 0;
    while (i < STACK_DEPTH + 4) : (i += 1) {
        var buf: [8]u8 = undefined;
        t.push(t.slotFor(std.fmt.bufPrint(&buf, "n{d}", .{i}) catch unreachable));
    }
    // Unwinding must still reach the namespace pushed before the overflow.
    i = 0;
    while (i < STACK_DEPTH + 8) : (i += 1) t.pop();
    try std.testing.expectEqual(@as(u8, 0), t.currentSlot());
}

test "ask answers have while the feature is on" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    t.setEnabled(true);

    const reply = applyOsc(&t, "ask");
    try std.testing.expect(reply == .have);
    try std.testing.expectEqual(t.osc, reply.have.osc);
    try std.testing.expect(reply.have.free > 0);
}

test "drop deselects the namespace but keeps its colours addressable" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    t.setEnabled(true);

    _ = applyOsc(&t, "set;work;3=#ff0000");
    _ = applyOsc(&t, "use;work");
    const slot = t.currentSlot();
    try std.testing.expect(slot != 0);

    _ = applyOsc(&t, "drop;work");
    try std.testing.expectEqual(@as(u8, 0), t.currentSlot());
    // The colours stayed with the slot: cells already drawn under it are still
    // on screen, so `use` must bring the same palette back.
    _ = applyOsc(&t, "use;work");
    try std.testing.expectEqual(slot, t.currentSlot());
    try std.testing.expectEqual(RGB{ .r = 255, .g = 0, .b = 0 }, t.resolveIndex(slot, 3).rgb);
}

test "a blob carries colours but never what a program had selected" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    t.setEnabled(true);
    _ = applyOsc(&t, "set;a;1=#010203");
    _ = applyOsc(&t, "use;a");

    const blob = try t.serialize(std.testing.allocator);
    defer std.testing.allocator.free(blob);

    var restored = NamespaceTable.init(std.testing.allocator);
    defer restored.deinit();
    restored.setEnabled(true);
    restored.applySerialized(blob);

    // Selection belongs to the running program, not to the parked state.
    try std.testing.expectEqual(@as(u8, 0), restored.currentSlot());
    const slot = restored.slotFor("a");
    try std.testing.expectEqual(RGB{ .r = 1, .g = 2, .b = 3 }, restored.resolveIndex(slot, 1).rgb);
}

test "reset with * clears every namespace" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    t.setEnabled(true);
    _ = applyOsc(&t, "set;a;1=#010203");
    _ = applyOsc(&t, "set;b;1=#040506");

    _ = applyOsc(&t, "reset;*");
    try std.testing.expect(t.resolveIndex(t.slotFor("a"), 1) == .passthrough);
    try std.testing.expect(t.resolveIndex(t.slotFor("b"), 1) == .passthrough);
}

test "a namespace's default fg and bg are readable for the render path" {
    var t = NamespaceTable.init(std.testing.allocator);
    defer t.deinit();
    t.setEnabled(true);
    _ = applyOsc(&t, "set;a;fg=#112233;bg=#445566");

    const d = t.defaultsFor(t.slotFor("a"));
    try std.testing.expectEqual(RGB{ .r = 0x11, .g = 0x22, .b = 0x33 }, d.fg.?);
    try std.testing.expectEqual(RGB{ .r = 0x44, .g = 0x55, .b = 0x66 }, d.bg.?);
    // Slot 0 has no defaults of its own: it is the terminal's own theme.
    try std.testing.expect(t.defaultsFor(0).fg == null);
}
