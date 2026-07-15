const std = @import("std");

/// Exactly-once dedup for mux→pod input frames across a frontend VT reconnect.
///
/// Each input frame carries `(epoch, seq)`: `epoch` is stable for a frontend
/// process across its own reconnects and unique vs a freshly reattaching one;
/// `seq` is monotonic per frontend and a replayed frame keeps its original seq.
/// The pod is the dedup authority — it is the only process that survives every
/// reconnect trigger (frontend slow, VT-overflow drop, daemon crash).
pub const InputDedup = struct {
    epoch: u64 = 0,
    last_seq: u64 = 0,
    epoch_set: bool = false,

    /// Record `(epoch, seq)` and return whether the frame should be APPLIED.
    /// - different (or first) epoch → new frontend stream: adopt it, apply.
    /// - seq <= last_seq            → a replay of an already-applied frame: drop.
    /// - else                       → apply, advance.
    pub fn accept(self: *InputDedup, epoch: u64, seq: u64) bool {
        if (!self.epoch_set or epoch != self.epoch) {
            self.epoch = epoch;
            self.epoch_set = true;
            self.last_seq = seq;
            return true;
        }
        if (seq <= self.last_seq) return false;
        self.last_seq = seq;
        return true;
    }
};

const testing = std.testing;

test "InputDedup: monotonic seqs all apply; duplicates drop" {
    var d: InputDedup = .{};
    try testing.expect(d.accept(100, 1)); // first frame: apply, adopt epoch 100
    try testing.expect(d.accept(100, 2));
    try testing.expect(d.accept(100, 3));
    try testing.expect(!d.accept(100, 3)); // exact replay: drop
    try testing.expect(!d.accept(100, 2)); // older replay: drop
    try testing.expect(!d.accept(100, 1));
    try testing.expect(d.accept(100, 4)); // new seq resumes
}

test "InputDedup: replayed window is deduped, only newer frames apply" {
    var d: InputDedup = .{};
    // Live traffic reaches seq 5.
    for (1..6) |s| try testing.expect(d.accept(100, @intCast(s)));
    // Reconnect: the frontend replays its ring (seqs 3..7). 3,4,5 already applied
    // → dropped; 6,7 are new → applied. Exactly-once.
    try testing.expect(!d.accept(100, 3));
    try testing.expect(!d.accept(100, 4));
    try testing.expect(!d.accept(100, 5));
    try testing.expect(d.accept(100, 6));
    try testing.expect(d.accept(100, 7));
}

test "InputDedup: a new epoch (reattach) resets the stream" {
    var d: InputDedup = .{};
    for (1..100) |s| _ = d.accept(100, @intCast(s)); // old frontend, high last_seq

    // A freshly reattached frontend has a new epoch and restarts seq at 1. Its
    // low seqs must NOT be mistaken for duplicates of the old stream.
    try testing.expect(d.accept(777, 1));
    try testing.expect(d.accept(777, 2));
    try testing.expect(!d.accept(777, 1)); // now a replay within the new stream
    try testing.expect(d.accept(777, 3));
}
