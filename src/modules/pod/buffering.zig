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
                out_cwd.* = after_scheme[slash_idx..];
            }
        }
    }
};

pub fn containsClearSeq(data: []const u8) bool {
    if (std.mem.indexOfScalar(u8, data, 0x0c) != null) return true;
    return std.mem.indexOf(u8, data, "\x1b[3J") != null;
}
