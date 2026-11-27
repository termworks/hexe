//! Per-pane lifecycle status and attention tracking, plus private OSC 1333.
//!
//! Designed for coding agents, build watchers, and long-running tools inside
//! panes so users can see at a glance which panes are `working`, `blocked`
//! (needing approval/input), `done`, or `idle`, and jump directly to panes
//! requiring attention.
//!
//! Private OSC 1333 protocol:
//!   - `\x1b]1333;have\x1b\\`                -> replies `\x1b]1333;have;1\x1b\\`
//!   - `\x1b]1333;set;<status>[;<note>]\x1b\\` -> sets status (+ optional note)
//!   - `\x1b]1333;<status>[;<note>]\x1b\\`    -> shorthand for `set`
//!   - `\x1b]1333;clear\x1b\\`                -> resets status to `idle` and clears attention

const std = @import("std");

pub const OSC: u32 = 1333;
pub const MAX_NOTE_LEN: usize = 160;

pub const Status = enum(u8) {
    idle = 0,
    working = 1,
    blocked = 2,
    done = 3,

    pub fn fromString(s: []const u8) ?Status {
        if (std.ascii.eqlIgnoreCase(s, "idle") or std.ascii.eqlIgnoreCase(s, "clear") or std.ascii.eqlIgnoreCase(s, "none")) {
            return .idle;
        }
        if (std.ascii.eqlIgnoreCase(s, "working") or std.ascii.eqlIgnoreCase(s, "busy") or std.ascii.eqlIgnoreCase(s, "running")) {
            return .working;
        }
        if (std.ascii.eqlIgnoreCase(s, "blocked") or std.ascii.eqlIgnoreCase(s, "waiting") or std.ascii.eqlIgnoreCase(s, "input")) {
            return .blocked;
        }
        if (std.ascii.eqlIgnoreCase(s, "done") or std.ascii.eqlIgnoreCase(s, "finished") or std.ascii.eqlIgnoreCase(s, "ready")) {
            return .done;
        }
        return null;
    }

    pub fn toString(self: Status) []const u8 {
        return switch (self) {
            .idle => "idle",
            .working => "working",
            .blocked => "blocked",
            .done => "done",
        };
    }

    pub fn needsAttention(self: Status) bool {
        return self == .blocked or self == .done;
    }

    /// Priority for attention ordering and tab rollup (`blocked` > `done` > `working` > `idle`).
    pub fn priority(self: Status) u8 {
        return switch (self) {
            .blocked => 3,
            .done => 2,
            .working => 1,
            .idle => 0,
        };
    }
};

pub const OscOutcome = union(enum) {
    ignore,
    have,
    changed: struct {
        status: Status,
        has_note: bool,
    },
};

pub const State = struct {
    status: Status = .idle,
    note_buf: [MAX_NOTE_LEN]u8 = undefined,
    note_len: u8 = 0,
    updated_at_ms: i64 = 0,
    /// True when an unfocused pane became `blocked` or `done`, or emitted an
    /// OSC 9/99/777 notification. Cleared on focus; `blocked` still stays
    /// visible as `status == .blocked` until cleared or updated.
    attention: bool = false,

    pub fn note(self: *const State) ?[]const u8 {
        if (self.note_len == 0) return null;
        return self.note_buf[0..self.note_len];
    }

    pub fn clear(self: *State, now_ms: i64) bool {
        if (self.status == .idle and self.note_len == 0 and !self.attention) return false;
        self.status = .idle;
        self.note_len = 0;
        self.attention = false;
        self.updated_at_ms = now_ms;
        return true;
    }

    /// Set the pane's status and optional note. Returns true if anything changed.
    pub fn set(self: *State, next: Status, note_opt: ?[]const u8, focused: bool, now_ms: i64) bool {
        var new_note_buf: [MAX_NOTE_LEN]u8 = undefined;
        const new_note_len: u8 = if (note_opt) |n|
            @intCast(sanitizeNote(&new_note_buf, n))
        else
            0;

        const next_attention = !focused and next.needsAttention();
        const same_note = self.note_len == new_note_len and
            std.mem.eql(u8, self.note_buf[0..self.note_len], new_note_buf[0..new_note_len]);
        if (self.status == next and self.attention == next_attention and same_note) {
            return false;
        }

        self.status = next;
        self.note_len = new_note_len;
        if (new_note_len > 0) {
            @memcpy(self.note_buf[0..new_note_len], new_note_buf[0..new_note_len]);
        }
        self.attention = next_attention;
        self.updated_at_ms = now_ms;
        return true;
    }

    /// Mark an unfocused pane as needing attention after an OSC 9/99/777 notification.
    pub fn markNotificationAttention(self: *State, summary: ?[]const u8, now_ms: i64) bool {
        var changed = false;
        if (!self.attention) {
            self.attention = true;
            changed = true;
        }
        if (self.note_len == 0) {
            if (summary) |s| {
                const n: u8 = @intCast(sanitizeNote(&self.note_buf, s));
                if (n > 0) {
                    self.note_len = n;
                    changed = true;
                }
            }
        }
        if (changed) self.updated_at_ms = now_ms;
        return changed;
    }

    /// Called when the user focuses this pane.
    /// - `.done` is acknowledged -> transitions back to `.idle` and clears note/attention.
    /// - Any pending `attention` flag is cleared so the user has seen it.
    /// - `.blocked` keeps `status = .blocked` until the agent/user clears or advances it.
    pub fn acknowledgeOnFocus(self: *State, now_ms: i64) bool {
        var changed = false;
        if (self.status == .done) {
            self.status = .idle;
            self.note_len = 0;
            changed = true;
        }
        if (self.attention) {
            self.attention = false;
            // If attention was only from an idle notification, drop its transient note too.
            if (self.status == .idle) self.note_len = 0;
            changed = true;
        }
        if (changed) self.updated_at_ms = now_ms;
        return changed;
    }

    /// Whether this pane should appear in the attention queue / `attention_next` jump.
    pub fn needsAttentionNow(self: *const State, focused: bool) bool {
        if (focused) return false;
        return self.attention or self.status == .blocked;
    }

    /// Attention sort priority (higher = surfaced earlier):
    /// `blocked` (3) > `done` (2) > notification-only attention (1) > none (0).
    pub fn attentionRank(self: *const State, focused: bool) u8 {
        if (!self.needsAttentionNow(focused)) return 0;
        if (self.status == .blocked) return 3;
        if (self.status == .done) return 2;
        return 1;
    }

    /// Parse and apply OSC 1333 parameters (everything after `1333;`).
    pub fn applyOsc(self: *State, params: []const u8, focused: bool, now_ms: i64) OscOutcome {
        const trimmed = std.mem.trim(u8, params, " \t");
        if (trimmed.len == 0) return .ignore;

        if (std.mem.eql(u8, trimmed, "have") or std.mem.eql(u8, trimmed, "?")) {
            return .have;
        }

        if (std.mem.eql(u8, trimmed, "clear")) {
            if (self.clear(now_ms)) {
                return .{ .changed = .{ .status = .idle, .has_note = false } };
            }
            return .ignore;
        }

        var rest = trimmed;
        if (std.mem.startsWith(u8, rest, "set;")) {
            rest = rest["set;".len..];
        }

        var status_tok: []const u8 = rest;
        var note_opt: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, rest, ';')) |semi| {
            status_tok = rest[0..semi];
            const raw_note = rest[semi + 1 ..];
            if (raw_note.len > 0) note_opt = raw_note;
        }

        const next = Status.fromString(std.mem.trim(u8, status_tok, " \t")) orelse return .ignore;
        if (self.set(next, note_opt, focused, now_ms)) {
            return .{ .changed = .{ .status = next, .has_note = self.note_len > 0 } };
        }
        return .ignore;
    }
};

/// Sanitize a status note to a single printable line capped at `MAX_NOTE_LEN`.
pub fn sanitizeNote(dst: *[MAX_NOTE_LEN]u8, src: []const u8) usize {
    var out_len: usize = 0;
    var prev_space = true;
    for (src) |b| {
        if (out_len >= MAX_NOTE_LEN) break;
        if (b == '\r' or b == '\n' or b == '\t' or b == ' ') {
            if (!prev_space) {
                dst[out_len] = ' ';
                out_len += 1;
                prev_space = true;
            }
            continue;
        }
        if (b < 0x20 or b == 0x7f) continue;
        dst[out_len] = b;
        out_len += 1;
        prev_space = false;
    }
    while (out_len > 0 and dst[out_len - 1] == ' ') {
        out_len -= 1;
    }
    return out_len;
}

test "OSC 1333 parses capability query, set, shorthand, and clear" {
    var st = State{};
    try std.testing.expectEqual(OscOutcome.have, st.applyOsc("have", false, 100));

    const r1 = st.applyOsc("set;blocked;Approve migration?", false, 200);
    try std.testing.expect(r1 == .changed);
    try std.testing.expectEqual(Status.blocked, st.status);
    try std.testing.expectEqualStrings("Approve migration?", st.note().?);
    try std.testing.expect(st.attention);
    try std.testing.expect(st.needsAttentionNow(false));
    try std.testing.expect(!st.needsAttentionNow(true));

    const r2 = st.applyOsc("done;All 42 tests passed\n", false, 300);
    try std.testing.expect(r2 == .changed);
    try std.testing.expectEqual(Status.done, st.status);
    try std.testing.expectEqualStrings("All 42 tests passed", st.note().?);
    try std.testing.expect(st.attention);

    // Focusing a `done` pane acknowledges it back to `idle`.
    try std.testing.expect(st.acknowledgeOnFocus(400));
    try std.testing.expectEqual(Status.idle, st.status);
    try std.testing.expect(st.note() == null);
    try std.testing.expect(!st.attention);

    // Focusing a `blocked` pane clears the unread attention flag but preserves `blocked`.
    _ = st.applyOsc("blocked;Need input", false, 500);
    try std.testing.expect(st.acknowledgeOnFocus(600));
    try std.testing.expectEqual(Status.blocked, st.status);
    try std.testing.expect(!st.attention);
    // Still surfaces in attention queue if user moves away without clearing.
    try std.testing.expect(st.needsAttentionNow(false));

    const r3 = st.applyOsc("clear", true, 700);
    try std.testing.expect(r3 == .changed);
    try std.testing.expectEqual(Status.idle, st.status);
    try std.testing.expect(!st.needsAttentionNow(false));
}

test "notification attention marks unfocused idle pane and clears on focus" {
    var st = State{};
    try std.testing.expect(st.markNotificationAttention("Build finished", 100));
    try std.testing.expect(st.needsAttentionNow(false));
    try std.testing.expectEqual(@as(u8, 1), st.attentionRank(false));
    try std.testing.expectEqualStrings("Build finished", st.note().?);

    try std.testing.expect(st.acknowledgeOnFocus(200));
    try std.testing.expect(!st.needsAttentionNow(false));
    try std.testing.expect(st.note() == null);
}
