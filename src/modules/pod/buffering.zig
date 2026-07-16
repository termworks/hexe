const std = @import("std");

pub const RingBuffer = struct {
    buf: []u8,
    start: usize = 0,
    len: usize = 0,

    pub fn available(self: *const RingBuffer) usize {
        return self.buf.len - self.len;
    }

    pub fn isFull(self: *const RingBuffer) bool {
        return self.len == self.buf.len;
    }

    pub fn init(allocator: std.mem.Allocator, cap_bytes: usize) !RingBuffer {
        return .{ .buf = try allocator.alloc(u8, cap_bytes) };
    }

    pub fn deinit(self: *RingBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
        self.* = undefined;
    }

    pub fn clear(self: *RingBuffer) void {
        self.start = 0;
        self.len = 0;
    }

    pub fn append(self: *RingBuffer, data: []const u8) void {
        if (self.buf.len == 0) return;
        if (data.len >= self.buf.len) {
            const tail = data[data.len - self.buf.len ..];
            @memcpy(self.buf, tail);
            self.start = 0;
            self.len = self.buf.len;
            return;
        }

        const cap = self.buf.len;
        var drop: usize = 0;
        if (self.len + data.len > cap) {
            drop = self.len + data.len - cap;
        }
        if (drop > 0) {
            self.start = (self.start + drop) % cap;
            self.len -= drop;
        }

        const end = (self.start + self.len) % cap;
        const first = @min(cap - end, data.len);
        @memcpy(self.buf[end .. end + first], data[0..first]);
        if (first < data.len) {
            @memcpy(self.buf[0 .. data.len - first], data[first..]);
        }
        self.len += data.len;
    }

    pub fn appendNoDrop(self: *RingBuffer, data: []const u8) bool {
        if (self.buf.len == 0) return false;
        if (data.len > self.available()) return false;

        const cap = self.buf.len;
        const end = (self.start + self.len) % cap;
        const first = @min(cap - end, data.len);
        @memcpy(self.buf[end .. end + first], data[0..first]);
        if (first < data.len) {
            @memcpy(self.buf[0 .. data.len - first], data[first..]);
        }
        self.len += data.len;
        return true;
    }

    pub fn copyOut(self: *const RingBuffer, out: []u8) usize {
        const n = @min(out.len, self.len);
        if (n == 0) return 0;

        const cap = self.buf.len;
        const first = @min(cap - self.start, n);
        @memcpy(out[0..first], self.buf[self.start .. self.start + first]);
        if (first < n) {
            @memcpy(out[first..n], self.buf[0 .. n - first]);
        }
        return n;
    }
};

pub const Osc7Scanner = struct {
    state: State = .normal,
    buf: [4096]u8 = undefined,
    len: usize = 0,
    // Owned storage for the last extracted path. extractPath copies into this
    // rather than handing back a slice into `buf`, which a second OSC7 in the
    // same feed() overwrites before the caller reads it.
    cwd_buf: [4096]u8 = undefined,
    cwd_len: usize = 0,

    const State = enum {
        normal,
        esc,
        osc,
        osc7,
        osc7_content,
        osc7_esc,
    };

    pub fn isIdle(self: *const Osc7Scanner) bool {
        return self.state == .normal;
    }

    pub fn feed(self: *Osc7Scanner, data: []const u8, out_cwd: *?[]const u8) void {
        for (data) |byte| {
            switch (self.state) {
                .normal => {
                    if (byte == 0x1b) self.state = .esc;
                },
                .esc => {
                    if (byte == ']') {
                        self.state = .osc;
                    } else {
                        self.state = .normal;
                    }
                },
                .osc => {
                    if (byte == '7') {
                        self.state = .osc7;
                    } else {
                        self.state = .normal;
                    }
                },
                .osc7 => {
                    if (byte == ';') {
                        self.state = .osc7_content;
                        self.len = 0;
                    } else {
                        self.state = .normal;
                    }
                },
                .osc7_content => {
                    if (byte == 0x07) {
                        self.extractPath(out_cwd);
                        self.state = .normal;
                    } else if (byte == 0x1b) {
                        self.state = .osc7_esc;
                    } else if (self.len < self.buf.len) {
                        self.buf[self.len] = byte;
                        self.len += 1;
                    }
                },
                .osc7_esc => {
                    if (byte == '\\') {
                        self.extractPath(out_cwd);
                    }
                    self.state = .normal;
                },
            }
        }
    }

    fn extractPath(self: *Osc7Scanner, out_cwd: *?[]const u8) void {
        const content = self.buf[0..self.len];
        if (std.mem.startsWith(u8, content, "file://")) {
            const after_scheme = content[7..];
            if (std.mem.indexOfScalar(u8, after_scheme, '/')) |slash_idx| {
                const path = after_scheme[slash_idx..];
                // Copy into owned storage so the returned slice stays valid
                // even if a later OSC7 in this same feed() rewrites `buf`.
                const n = @min(path.len, self.cwd_buf.len);
                @memcpy(self.cwd_buf[0..n], path[0..n]);
                self.cwd_len = n;
                out_cwd.* = self.cwd_buf[0..n];
            }
        }
    }
};

pub fn containsClearSeq(data: []const u8) bool {
    if (std.mem.indexOfScalar(u8, data, 0x0c) != null) return true;
    return std.mem.indexOf(u8, data, "\x1b[3J") != null;
}

const testing = std.testing;

test "RingBuffer: append and copyOut round-trip" {
    var rb = try RingBuffer.init(testing.allocator, 8);
    defer rb.deinit(testing.allocator);

    rb.append("abc");
    try testing.expectEqual(@as(usize, 3), rb.len);
    var out: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), rb.copyOut(&out));
    try testing.expectEqualStrings("abc", out[0..3]);
}

test "RingBuffer: append drops oldest bytes when over capacity" {
    var rb = try RingBuffer.init(testing.allocator, 4);
    defer rb.deinit(testing.allocator);

    rb.append("abcd"); // full: abcd
    rb.append("ef"); // drops ab -> cdef
    try testing.expectEqual(@as(usize, 4), rb.len);
    var out: [4]u8 = undefined;
    _ = rb.copyOut(&out);
    try testing.expectEqualStrings("cdef", &out);
}

test "RingBuffer: oversized append keeps only the trailing capacity bytes" {
    var rb = try RingBuffer.init(testing.allocator, 4);
    defer rb.deinit(testing.allocator);

    rb.append("abcdefgh"); // keeps last 4: efgh
    try testing.expectEqual(@as(usize, 4), rb.len);
    var out: [4]u8 = undefined;
    _ = rb.copyOut(&out);
    try testing.expectEqualStrings("efgh", &out);
}

test "RingBuffer: append wraps around the physical buffer correctly" {
    var rb = try RingBuffer.init(testing.allocator, 4);
    defer rb.deinit(testing.allocator);

    rb.append("abc"); // start=0 len=3
    rb.append("de"); // total 5 > 4 -> drop 1 (a), wrap: bcde
    try testing.expectEqual(@as(usize, 4), rb.len);
    var out: [4]u8 = undefined;
    _ = rb.copyOut(&out);
    try testing.expectEqualStrings("bcde", &out);
}

test "RingBuffer: appendNoDrop refuses when it would overflow" {
    var rb = try RingBuffer.init(testing.allocator, 4);
    defer rb.deinit(testing.allocator);

    try testing.expect(rb.appendNoDrop("abc"));
    try testing.expect(!rb.appendNoDrop("de")); // 3+2 > 4 -> refused, unchanged
    try testing.expectEqual(@as(usize, 3), rb.len);
    try testing.expect(rb.appendNoDrop("d")); // exactly fills
    try testing.expect(rb.isFull());
}

test "RingBuffer: clear resets state" {
    var rb = try RingBuffer.init(testing.allocator, 4);
    defer rb.deinit(testing.allocator);
    rb.append("abcd");
    rb.clear();
    try testing.expectEqual(@as(usize, 0), rb.len);
    try testing.expect(!rb.isFull());
}

fn scanOnce(data: []const u8) ?[]const u8 {
    var scanner = Osc7Scanner{};
    var out: ?[]const u8 = null;
    scanner.feed(data, &out);
    return out;
}

test "Osc7Scanner: extracts cwd from a BEL-terminated OSC7" {
    const cwd = scanOnce("\x1b]7;file://host/home/user\x07") orelse return error.NoCwd;
    try testing.expectEqualStrings("/home/user", cwd);
}

test "Osc7Scanner: extracts cwd from an ST-terminated OSC7" {
    const cwd = scanOnce("\x1b]7;file://host/tmp/x\x1b\\") orelse return error.NoCwd;
    try testing.expectEqualStrings("/tmp/x", cwd);
}

test "Osc7Scanner: ignores non-file URIs" {
    try testing.expect(scanOnce("\x1b]7;http://host/nope\x07") == null);
}

test "Osc7Scanner: two OSC7s in one feed yield the LAST path intact (dangling-slice regression)" {
    // Before the fix, extractPath returned a slice into the reused scan buffer;
    // the second sequence overwrote it, so the returned cwd was garbage. Now
    // the scanner copies into owned storage and the last completed path wins.
    const cwd = scanOnce("\x1b]7;file://h/first/aaa\x07\x1b]7;file://h/second/bbb\x07") orelse return error.NoCwd;
    try testing.expectEqualStrings("/second/bbb", cwd);
}

test "Osc7Scanner: sequence split across two feeds still parses" {
    var scanner = Osc7Scanner{};
    var out: ?[]const u8 = null;
    scanner.feed("\x1b]7;file://host/ho", &out);
    try testing.expect(out == null);
    scanner.feed("me/user\x07", &out);
    try testing.expectEqualStrings("/home/user", out.?);
}

test "containsClearSeq detects FF and CSI 3J" {
    try testing.expect(containsClearSeq("abc\x0cdef"));
    try testing.expect(containsClearSeq("x\x1b[3Jy"));
    try testing.expect(!containsClearSeq("plain text"));
}

/// Tracks whether the child is on the alternate screen and where (in absolute
/// stream offset) the current alt-screen session began. Reattach replay uses
/// this to skip the invisible main-screen history behind a fullscreen app and
/// start from the enter sequence — which is immediately followed by the app's
/// full initial paint — instead of replaying megabytes of dead scrollback.
pub const AltScreenTracker = struct {
    state: State = .normal,
    in_alt: bool = false,
    /// Absolute stream offset of the ESC that started the current alt enter.
    alt_enter_offset: ?u64 = null,
    seq_start: u64 = 0,
    cur_param: u32 = 0,
    matched_param: bool = false,

    const State = enum { normal, esc, csi, private };

    fn isAltParam(p: u32) bool {
        return p == 47 or p == 1047 or p == 1049;
    }

    /// Feed a chunk that begins at absolute stream offset `base`.
    pub fn feed(self: *AltScreenTracker, data: []const u8, base: u64) void {
        for (data, 0..) |byte, i| {
            switch (self.state) {
                .normal => if (byte == 0x1b) {
                    self.state = .esc;
                    self.seq_start = base + i;
                },
                .esc => self.state = if (byte == '[') .csi else .normal,
                .csi => {
                    if (byte == '?') {
                        self.state = .private;
                        self.cur_param = 0;
                        self.matched_param = false;
                    } else {
                        self.state = .normal;
                    }
                },
                .private => switch (byte) {
                    '0'...'9' => self.cur_param = self.cur_param *% 10 +% (byte - '0'),
                    ';' => {
                        if (isAltParam(self.cur_param)) self.matched_param = true;
                        self.cur_param = 0;
                    },
                    'h' => {
                        if (isAltParam(self.cur_param) or self.matched_param) {
                            self.in_alt = true;
                            self.alt_enter_offset = self.seq_start;
                        }
                        self.state = .normal;
                    },
                    'l' => {
                        if (isAltParam(self.cur_param) or self.matched_param) {
                            self.in_alt = false;
                            self.alt_enter_offset = null;
                        }
                        self.state = .normal;
                    },
                    else => self.state = .normal,
                },
            }
        }
    }

    pub fn isIdle(self: *const AltScreenTracker) bool {
        return self.state == .normal;
    }
};

/// How many leading ring bytes to SKIP when replaying a backlog of `ring_len`
/// bytes whose first byte sits at absolute offset `ring_start_abs`.
/// On the alt screen with the enter still in the ring, start at the enter (the
/// full initial paint follows it). Otherwise replay at most `tail_cap` bytes —
/// a torn head is the same status quo as a wrapped ring, and fullscreen apps
/// repaint over it while the tail covers screen + recent scrollback.
pub fn replaySkipBytes(
    in_alt: bool,
    alt_enter_offset: ?u64,
    ring_start_abs: u64,
    ring_len: usize,
    tail_cap: usize,
) usize {
    const cap_skip = if (ring_len > tail_cap) ring_len - tail_cap else 0;
    if (in_alt) {
        if (alt_enter_offset) |enter| {
            if (enter >= ring_start_abs) {
                const alt_skip: usize = @intCast(enter - ring_start_abs);
                if (alt_skip < ring_len) return @max(alt_skip, cap_skip);
            }
        }
    }
    return cap_skip;
}

test "AltScreenTracker: enter/leave with 1049, offsets tracked" {
    var t = AltScreenTracker{};
    t.feed("hello\x1b[?1049h<paint>", 100);
    try testing.expect(t.in_alt);
    try testing.expectEqual(@as(?u64, 105), t.alt_enter_offset);
    t.feed("\x1b[?1049l", 200);
    try testing.expect(!t.in_alt);
    try testing.expect(t.alt_enter_offset == null);
}

test "AltScreenTracker: sequence split across feeds; multi-param; non-alt ignored" {
    var t = AltScreenTracker{};
    t.feed("\x1b[?10", 0);
    t.feed("49h", 5);
    try testing.expect(t.in_alt);
    try testing.expectEqual(@as(?u64, 0), t.alt_enter_offset);

    // Cursor-visibility private mode must not toggle alt state.
    t.feed("\x1b[?25l\x1b[?25h", 10);
    try testing.expect(t.in_alt);

    // Multi-param form with an alt param in the list.
    var t2 = AltScreenTracker{};
    t2.feed("\x1b[?1049;25h", 50);
    try testing.expect(t2.in_alt);
    try testing.expectEqual(@as(?u64, 50), t2.alt_enter_offset);
}

test "replaySkipBytes: alt enter inside ring wins; tail cap otherwise" {
    // Ring holds [1000..5000); alt entered at 3000 -> skip 2000.
    try testing.expectEqual(@as(usize, 2000), replaySkipBytes(true, 3000, 1000, 4000, 1_000_000));
    // Alt enter fell off the ring -> tail cap applies.
    try testing.expectEqual(@as(usize, 3000), replaySkipBytes(true, 500, 1000, 4000, 1000));
    // Main screen: tail cap only.
    try testing.expectEqual(@as(usize, 3000), replaySkipBytes(false, null, 1000, 4000, 1000));
    try testing.expectEqual(@as(usize, 0), replaySkipBytes(false, null, 0, 500, 1000));
    // Alt enter within ring but older than the cap: cap still wins.
    try testing.expectEqual(@as(usize, 3000), replaySkipBytes(true, 1500, 1000, 4000, 1000));
}
