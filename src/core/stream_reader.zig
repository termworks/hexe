//! Resumable, fully non-blocking frame reader for SES's VT routing.
//!
//! Both routing directions used blocking bounded reads — `readExactTimeout` for
//! the header and again for the payload. A peer that sent a partial frame and
//! stalled therefore froze the whole single-threaded daemon (every other
//! session included) for up to the timeout, twice per frame.
//!
//! The obvious fix — a resumable reader per fd, like the frontend's
//! `MuxVtReader` — has a memory problem SES does not share with the frontend:
//! retaining a partial payload needs a per-fd buffer, and a pod can emit a
//! frame up to `MAX_FRAME_LEN` (4 MiB), because `processPtyOutput` forwards a
//! whole PTY read. A fixed per-fd buffer of that size costs 4 MiB × N pods, and
//! shrinking it would mean silently dropping oversized frames.
//!
//! So the payload buffer is **allocated on demand and only when a frame is
//! actually split across reads**:
//!
//!   - Complete frame available in one read (the overwhelmingly common case):
//!     routed straight out of the caller's shared scratch buffer. No
//!     allocation, no retained state.
//!   - Frame split mid-payload: the partial bytes move to a right-sized heap
//!     buffer, which is freed the moment the frame completes.
//!
//! Steady-state cost is therefore the same as before (one shared scratch
//! buffer), while a stalled peer costs memory proportional to its own
//! in-flight frame instead of freezing the daemon.

const std = @import("std");
const posix = std.posix;

/// Extracts the payload length from a fully-read header.
pub const PayloadLenFn = *const fn (hdr: []const u8) u32;

pub const Frame = struct {
    hdr: []const u8,
    payload: []const u8,
};

pub const Result = union(enum) {
    /// Socket is dry. Any partial progress is retained for the next call.
    none,
    frame: Frame,
    /// Peer hung up.
    closed,
    /// Unrecoverable read error.
    failed,
    /// Header declares a payload larger than the caller's cap. The stream is
    /// left positioned at the payload so the caller can decide (drop the
    /// connection); it cannot be resynchronised by skipping without reading.
    oversize: u32,
};

pub const VtStreamReader = struct {
    /// Header size in bytes: 5 for the pod protocol, 7 for MuxVtHeader.
    hdr_len: u8,
    payload_len_fn: PayloadLenFn,

    /// Sized for the largest header this reader is used with: 5 (pod
    /// protocol), 7 (wire.MuxVtHeader), 10 (wire.ControlHeader).
    hdr: [16]u8 = undefined,
    hdr_got: u8 = 0,
    have_hdr: bool = false,
    payload_len: u32 = 0,

    /// Only present while a payload is split across reads.
    spill: ?[]u8 = null,
    spill_got: usize = 0,

    pub fn init(hdr_len: u8, payload_len_fn: PayloadLenFn) VtStreamReader {
        std.debug.assert(hdr_len <= 16);
        return .{ .hdr_len = hdr_len, .payload_len_fn = payload_len_fn };
    }

    pub fn deinit(self: *VtStreamReader, allocator: std.mem.Allocator) void {
        if (self.spill) |buf| allocator.free(buf);
        self.spill = null;
    }

    fn resetFrame(self: *VtStreamReader, allocator: std.mem.Allocator) void {
        if (self.spill) |buf| allocator.free(buf);
        self.spill = null;
        self.spill_got = 0;
        self.hdr_got = 0;
        self.have_hdr = false;
        self.payload_len = 0;
    }

    /// One non-blocking read. `0` means the socket is dry.
    fn readSome(fd: posix.fd_t, out: []u8, closed: *bool, failed: *bool) usize {
        if (out.len == 0) return 0;
        const n = posix.read(fd, out) catch |err| switch (err) {
            error.WouldBlock => return 0,
            else => {
                failed.* = true;
                return 0;
            },
        };
        if (n == 0) closed.* = true;
        return n;
    }

    /// Try to produce one complete frame without blocking.
    ///
    /// `scratch` must be at least as large as the biggest payload the caller is
    /// willing to accept; anything larger comes back as `.oversize`. A returned
    /// frame's payload aliases either `scratch` or internal storage and is only
    /// valid until the next call.
    pub fn next(
        self: *VtStreamReader,
        fd: posix.fd_t,
        scratch: []u8,
        allocator: std.mem.Allocator,
    ) Result {
        var closed = false;
        var failed = false;

        // --- header ---------------------------------------------------------
        while (!self.have_hdr) {
            const n = readSome(fd, self.hdr[self.hdr_got..self.hdr_len], &closed, &failed);
            if (failed) return .failed;
            if (closed) return .closed;
            if (n == 0) return .none;
            self.hdr_got += @intCast(n);
            if (self.hdr_got == self.hdr_len) {
                self.have_hdr = true;
                self.payload_len = self.payload_len_fn(self.hdr[0..self.hdr_len]);
            }
        }

        const want: usize = self.payload_len;
        if (want == 0) {
            const hdr_slice = self.hdr[0..self.hdr_len];
            defer self.resetFrame(allocator);
            return .{ .frame = .{ .hdr = hdr_slice, .payload = scratch[0..0] } };
        }
        if (want > scratch.len) return .{ .oversize = self.payload_len };

        // --- payload --------------------------------------------------------
        // Already spilled: keep filling the heap buffer.
        if (self.spill) |buf| {
            while (self.spill_got < want) {
                const n = readSome(fd, buf[self.spill_got..want], &closed, &failed);
                if (failed) return .failed;
                if (closed) return .closed;
                if (n == 0) return .none;
                self.spill_got += n;
            }
            const hdr_slice = self.hdr[0..self.hdr_len];
            @memcpy(scratch[0..want], buf[0..want]);
            self.resetFrame(allocator);
            return .{ .frame = .{ .hdr = hdr_slice, .payload = scratch[0..want] } };
        }

        // Fast path: try to take the whole payload straight into scratch.
        var got: usize = self.spill_got;
        while (got < want) {
            const n = readSome(fd, scratch[got..want], &closed, &failed);
            if (failed) return .failed;
            if (closed) return .closed;
            if (n == 0) {
                // Split frame. Move what we have somewhere it survives the
                // return, sized to this frame only.
                if (got > 0) {
                    const buf = allocator.alloc(u8, want) catch {
                        // Cannot retain: treat as fatal for this connection
                        // rather than silently desyncing the stream.
                        return .failed;
                    };
                    @memcpy(buf[0..got], scratch[0..got]);
                    self.spill = buf;
                    self.spill_got = got;
                }
                return .none;
            }
            got += n;
        }

        const hdr_slice = self.hdr[0..self.hdr_len];
        self.resetFrame(allocator);
        return .{ .frame = .{ .hdr = hdr_slice, .payload = scratch[0..want] } };
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

fn podPayloadLen(hdr: []const u8) u32 {
    return std.mem.readInt(u32, hdr[1..5], .big);
}

fn testPair() ![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    const rc = std.os.linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0, &fds);
    if (rc != 0) return error.SocketpairFailed;
    return fds;
}

fn writePodFrame(fd: posix.fd_t, frame_type: u8, payload: []const u8) !void {
    var hdr: [5]u8 = undefined;
    hdr[0] = frame_type;
    std.mem.writeInt(u32, hdr[1..5], @intCast(payload.len), .big);
    _ = try posix.write(fd, &hdr);
    if (payload.len > 0) _ = try posix.write(fd, payload);
}

test "VtStreamReader: whole frame in one read needs no allocation" {
    const fds = try testPair();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var r = VtStreamReader.init(5, podPayloadLen);
    defer r.deinit(std.testing.allocator);
    var scratch: [256]u8 = undefined;

    try writePodFrame(fds[1], 1, "hello");
    switch (r.next(fds[0], &scratch, std.testing.allocator)) {
        .frame => |f| {
            try std.testing.expectEqual(@as(u8, 1), f.hdr[0]);
            try std.testing.expectEqualStrings("hello", f.payload);
        },
        else => return error.TestUnexpectedResult,
    }
    // No spill buffer was ever needed.
    try std.testing.expect(r.spill == null);
    try std.testing.expectEqual(Result.none, r.next(fds[0], &scratch, std.testing.allocator));
}

test "VtStreamReader: resumes a frame split at every boundary" {
    const fds = try testPair();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var r = VtStreamReader.init(5, podPayloadLen);
    defer r.deinit(std.testing.allocator);
    var scratch: [256]u8 = undefined;

    // Header arrives in two pieces, then the payload in three.
    var hdr: [5]u8 = undefined;
    hdr[0] = 7;
    std.mem.writeInt(u32, hdr[1..5], 9, .big);

    _ = try posix.write(fds[1], hdr[0..2]);
    try std.testing.expectEqual(Result.none, r.next(fds[0], &scratch, std.testing.allocator));

    _ = try posix.write(fds[1], hdr[2..5]);
    try std.testing.expectEqual(Result.none, r.next(fds[0], &scratch, std.testing.allocator));

    _ = try posix.write(fds[1], "abc");
    try std.testing.expectEqual(Result.none, r.next(fds[0], &scratch, std.testing.allocator));
    // A split payload must be retained somewhere that survives the return.
    try std.testing.expect(r.spill != null);

    _ = try posix.write(fds[1], "def");
    try std.testing.expectEqual(Result.none, r.next(fds[0], &scratch, std.testing.allocator));

    _ = try posix.write(fds[1], "ghi");
    switch (r.next(fds[0], &scratch, std.testing.allocator)) {
        .frame => |f| {
            try std.testing.expectEqual(@as(u8, 7), f.hdr[0]);
            try std.testing.expectEqualStrings("abcdefghi", f.payload);
        },
        else => return error.TestUnexpectedResult,
    }
    // Spill is released as soon as the frame completes.
    try std.testing.expect(r.spill == null);
}

test "VtStreamReader: drains several frames from one read" {
    const fds = try testPair();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var r = VtStreamReader.init(5, podPayloadLen);
    defer r.deinit(std.testing.allocator);
    var scratch: [256]u8 = undefined;

    try writePodFrame(fds[1], 1, "one");
    try writePodFrame(fds[1], 2, "two");
    try writePodFrame(fds[1], 3, "");

    var seen: usize = 0;
    while (true) {
        switch (r.next(fds[0], &scratch, std.testing.allocator)) {
            .frame => |f| {
                seen += 1;
                switch (seen) {
                    1 => try std.testing.expectEqualStrings("one", f.payload),
                    2 => try std.testing.expectEqualStrings("two", f.payload),
                    3 => try std.testing.expectEqual(@as(usize, 0), f.payload.len),
                    else => return error.TestUnexpectedResult,
                }
            },
            .none => break,
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
}

test "VtStreamReader: reports EOF and oversize distinctly" {
    {
        const fds = try testPair();
        defer posix.close(fds[0]);
        var r = VtStreamReader.init(5, podPayloadLen);
        defer r.deinit(std.testing.allocator);
        var scratch: [256]u8 = undefined;
        posix.close(fds[1]);
        try std.testing.expectEqual(Result.closed, r.next(fds[0], &scratch, std.testing.allocator));
    }
    {
        const fds = try testPair();
        defer posix.close(fds[0]);
        defer posix.close(fds[1]);
        var r = VtStreamReader.init(5, podPayloadLen);
        defer r.deinit(std.testing.allocator);
        var scratch: [16]u8 = undefined;

        var hdr: [5]u8 = undefined;
        hdr[0] = 1;
        std.mem.writeInt(u32, hdr[1..5], 4096, .big);
        _ = try posix.write(fds[1], &hdr);

        switch (r.next(fds[0], &scratch, std.testing.allocator)) {
            .oversize => |len| try std.testing.expectEqual(@as(u32, 4096), len),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "VtStreamReader: header buffer fits every header it is used with" {
    // wire.ControlHeader is 10 bytes -- larger than the original [8]u8 buffer,
    // which tripped the init assert at runtime and took down every frontend.
    // Keep this in sync with the call sites in server.zig.
    const used_header_sizes = [_]u8{ 5, 7, 10 };
    const probe = VtStreamReader.init(5, podPayloadLen);
    for (used_header_sizes) |len| {
        try std.testing.expect(len <= probe.hdr.len);
    }
}

test "VtStreamReader: header-only mode yields a frame as soon as the header lands" {
    const fds = try testPair();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const Zero = struct {
        fn f(_: []const u8) u32 {
            return 0;
        }
    };
    // 10-byte header, payload deliberately left in the socket for a caller that
    // reads it separately (how SES handles CTL frames).
    var r = VtStreamReader.init(10, Zero.f);
    defer r.deinit(std.testing.allocator);

    const hdr = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    _ = try posix.write(fds[1], hdr[0..4]);
    try std.testing.expectEqual(Result.none, r.next(fds[0], &.{}, std.testing.allocator));

    _ = try posix.write(fds[1], hdr[4..10]);
    _ = try posix.write(fds[1], "payload-stays-put");
    switch (r.next(fds[0], &.{}, std.testing.allocator)) {
        .frame => |f| {
            try std.testing.expectEqual(@as(usize, 10), f.hdr.len);
            try std.testing.expectEqualSlices(u8, &hdr, f.hdr);
            try std.testing.expectEqual(@as(usize, 0), f.payload.len);
        },
        else => return error.TestUnexpectedResult,
    }

    // The payload really is still in the socket for the caller to read.
    var rest: [17]u8 = undefined;
    const n = try posix.read(fds[0], &rest);
    try std.testing.expectEqualStrings("payload-stays-put", rest[0..n]);
}
