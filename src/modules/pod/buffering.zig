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
