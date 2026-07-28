//! Reusable byte buffers for VT queue frames.
//!
//! Every routed VT frame allocates a buffer, queues it, writes it out, and
//! frees it. The daemon runs on `page_allocator`, so each of those is an
//! `mmap` + `munmap` pair rounded up to a page — two syscalls and a TLB
//! shootdown per frame, on the routing hot path, at up to VT_FRAMES_PER_WAKEUP
//! frames per wakeup per fd.
//!
//! The obvious fix — give the daemon a real allocator — was tried and reverted:
//! a GeneralPurposeAllocator makes the daemonized process panic, because
//! `daemonize()` closes stdio and `chdir("/")` and that breaks the self
//! debug-info lookup the GPA's safety machinery depends on. See the comment on
//! `SesState.init`.
//!
//! This pool sidesteps all of that. It is a plain free list of already-mapped
//! buffers with no debug machinery of any kind, so `daemonize()` cannot affect
//! it. Frames are short-lived and highly uniform in size (a pod's output frames
//! are bounded by its I/O buffer), so a small pool serves nearly every request.
//!
//! Buffers are handed out with `len >= requested`; callers must therefore track
//! their own logical length rather than relying on `buf.len`.

const std = @import("std");

pub const FramePool = struct {
    /// Buffers kept for reuse. Small: the queues drain continuously, so only a
    /// handful are ever in flight at once.
    const MAX_BUFFERS: usize = 64;
    /// Buffers larger than this are freed rather than pooled — a rare huge
    /// frame should not pin memory for the life of the daemon.
    const MAX_POOLED_BYTES: usize = 128 * 1024;

    allocator: std.mem.Allocator,
    free_list: [MAX_BUFFERS][]u8 = undefined,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) FramePool {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FramePool) void {
        for (self.free_list[0..self.count]) |buf| self.allocator.free(buf);
        self.count = 0;
    }

    /// Get a buffer of at least `len` bytes. The returned slice may be LONGER
    /// than requested; the caller owns tracking its logical length.
    pub fn acquire(self: *FramePool, len: usize) ![]u8 {
        // Best fit among pooled buffers, so a big buffer is not consumed by a
        // tiny request while small ones sit idle.
        var best: ?usize = null;
        for (self.free_list[0..self.count], 0..) |buf, i| {
            if (buf.len < len) continue;
            if (best) |b| {
                if (buf.len < self.free_list[b].len) best = i;
            } else {
                best = i;
            }
        }
        if (best) |i| {
            const buf = self.free_list[i];
            self.count -= 1;
            self.free_list[i] = self.free_list[self.count];
            return buf;
        }
        return self.allocator.alloc(u8, len);
    }

    /// Return a buffer for reuse.
    pub fn release(self: *FramePool, buf: []u8) void {
        if (buf.len > MAX_POOLED_BYTES or self.count == MAX_BUFFERS) {
            self.allocator.free(buf);
            return;
        }
        self.free_list[self.count] = buf;
        self.count += 1;
    }
};

test "FramePool reuses a released buffer instead of allocating" {
    const testing = std.testing;
    var pool = FramePool.init(testing.allocator);
    defer pool.deinit();

    const first = try pool.acquire(1024);
    const first_ptr = first.ptr;
    pool.release(first);

    // Same size: must come back as the very same allocation.
    const again = try pool.acquire(1024);
    try testing.expectEqual(first_ptr, again.ptr);
    pool.release(again);

    // Smaller request also reuses it (len >= requested is the contract).
    const smaller = try pool.acquire(16);
    try testing.expectEqual(first_ptr, smaller.ptr);
    try testing.expect(smaller.len >= 16);
    pool.release(smaller);
}

test "FramePool best-fits rather than burning a large buffer on a small request" {
    const testing = std.testing;
    var pool = FramePool.init(testing.allocator);
    defer pool.deinit();

    const small = try pool.acquire(64);
    const large = try pool.acquire(8192);
    const small_ptr = small.ptr;
    const large_ptr = large.ptr;
    pool.release(large);
    pool.release(small);

    // A 64-byte request must take the 64-byte buffer, leaving the big one.
    const got = try pool.acquire(64);
    try testing.expectEqual(small_ptr, got.ptr);
    pool.release(got);

    const got_large = try pool.acquire(8192);
    try testing.expectEqual(large_ptr, got_large.ptr);
    pool.release(got_large);
}

test "FramePool does not pool oversized buffers or exceed its cap" {
    const testing = std.testing;
    var pool = FramePool.init(testing.allocator);
    defer pool.deinit();

    // Oversized buffers are freed, not retained.
    const huge = try pool.acquire(FramePool.MAX_POOLED_BYTES + 1);
    pool.release(huge);
    try testing.expectEqual(@as(usize, 0), pool.count);

    // The pool never grows past its cap; the excess is freed.
    var bufs: [FramePool.MAX_BUFFERS + 4][]u8 = undefined;
    for (&bufs) |*b| b.* = try pool.acquire(32);
    for (bufs) |b| pool.release(b);
    try testing.expectEqual(FramePool.MAX_BUFFERS, pool.count);
}
