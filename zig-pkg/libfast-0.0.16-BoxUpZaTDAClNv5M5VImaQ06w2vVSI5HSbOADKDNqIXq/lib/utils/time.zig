const std = @import("std");

/// Monotonic timestamp in microseconds
pub const Instant = struct {
    micros: u64,

    /// Get current time
    pub fn now() Instant {
        const nanos = std.time.nanoTimestamp();
        return Instant{ .micros = @intCast(@divFloor(nanos, 1000)) };
    }

    /// Duration since another instant in microseconds
    pub fn durationSince(self: Instant, earlier: Instant) u64 {
        if (self.micros >= earlier.micros) {
            return self.micros - earlier.micros;
        }
        return 0;
    }

    /// Duration until another instant in microseconds
    pub fn durationUntil(self: Instant, later: Instant) u64 {
        if (later.micros >= self.micros) {
            return later.micros - self.micros;
        }
        return 0;
    }

    /// Add duration in microseconds
    pub fn add(self: Instant, micros: u64) Instant {
        return Instant{ .micros = self.micros + micros };
    }

    /// Subtract duration in microseconds
    pub fn sub(self: Instant, micros: u64) Instant {
        return Instant{ .micros = self.micros -| micros };
    }

    /// Check if this instant is before another
    pub fn isBefore(self: Instant, other: Instant) bool {
        return self.micros < other.micros;
    }

    /// Check if this instant is after another
    pub fn isAfter(self: Instant, other: Instant) bool {
        return self.micros > other.micros;
    }
};

/// Timer for tracking timeouts
pub const Timer = struct {
    start: Instant,
    timeout_micros: u64,

    pub fn init(timeout_micros: u64) Timer {
        return Timer{
            .start = Instant.now(),
            .timeout_micros = timeout_micros,
        };
    }

    /// Check if timer has expired
    pub fn isExpired(self: Timer) bool {
        const now = Instant.now();
        return now.durationSince(self.start) >= self.timeout_micros;
    }

    /// Get remaining time in microseconds
    pub fn remaining(self: Timer) u64 {
        const now = Instant.now();
        const elapsed = now.durationSince(self.start);
        if (elapsed >= self.timeout_micros) {
            return 0;
        }
        return self.timeout_micros - elapsed;
    }

    /// Reset timer to start counting from now
    pub fn reset(self: *Timer) void {
        self.start = Instant.now();
    }
};

/// Duration constants
pub const Duration = struct {
    pub const MICROSECOND: u64 = 1;
    pub const MILLISECOND: u64 = 1000 * MICROSECOND;
    pub const SECOND: u64 = 1000 * MILLISECOND;
    pub const MINUTE: u64 = 60 * SECOND;
};

// Tests

test "instant creation and comparison" {
    const t1 = Instant.now();
    const t2 = Instant.now();

    try std.testing.expect(t2.micros >= t1.micros);
    try std.testing.expect(t1.isBefore(t2) or t1.micros == t2.micros);
}

test "instant duration" {
    const t1 = Instant{ .micros = 1000 };
    const t2 = Instant{ .micros = 2000 };

    try std.testing.expectEqual(@as(u64, 1000), t2.durationSince(t1));
    try std.testing.expectEqual(@as(u64, 1000), t1.durationUntil(t2));
    try std.testing.expectEqual(@as(u64, 0), t1.durationSince(t2));
}

test "instant arithmetic" {
    const t = Instant{ .micros = 1000 };

    const t_plus = t.add(500);
    try std.testing.expectEqual(@as(u64, 1500), t_plus.micros);

    const t_minus = t.sub(300);
    try std.testing.expectEqual(@as(u64, 700), t_minus.micros);

    // Saturating subtraction
    const t_underflow = t.sub(2000);
    try std.testing.expectEqual(@as(u64, 0), t_underflow.micros);
}

test "timer expiration" {
    var timer = Timer.init(1); // 1 microsecond timeout

    // Timer should eventually expire (or be immediate in fast execution)
    var retries: u32 = 1000;
    while (retries > 0) : (retries -= 1) {
        if (timer.isExpired()) break;
    }

    try std.testing.expect(timer.isExpired());
}

test "timer reset" {
    var timer = Timer.init(Duration.SECOND);

    const remaining1 = timer.remaining();

    // Reset timer
    timer.reset();

    const remaining2 = timer.remaining();

    // After reset, remaining time should be close to original timeout
    try std.testing.expect(remaining2 >= remaining1);
}

test "duration constants" {
    try std.testing.expectEqual(@as(u64, 1), Duration.MICROSECOND);
    try std.testing.expectEqual(@as(u64, 1000), Duration.MILLISECOND);
    try std.testing.expectEqual(@as(u64, 1000000), Duration.SECOND);
    try std.testing.expectEqual(@as(u64, 60000000), Duration.MINUTE);
}
