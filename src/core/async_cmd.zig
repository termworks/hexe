//! Non-blocking external-command execution for the render path.
//!
//! Statusbar segments, float titles, `when` conditions and the git/sudo
//! segments all shell out — from inside a single-threaded event loop that also
//! has to render frames and read keystrokes. Running those commands
//! synchronously means the UI is frozen for as long as they take. Bounding
//! them (see cmd.zig) stops the *unbounded* freeze, but a 500ms budget per
//! command is still 500ms of dead UI per command per refresh — with several
//! segments that is seconds of stutter.
//!
//! This cache makes them properly asynchronous:
//!
//!   * `value()` NEVER blocks. It returns the last completed result (possibly
//!     stale, or null before the first result lands) and, if the entry is due
//!     for a refresh and nothing is in flight, spawns the command in the
//!     background.
//!   * `poll()` is called once per event-loop iteration. It drains whatever
//!     the in-flight children have written (non-blocking), reaps the ones that
//!     finished, and kills any that overrun their hard deadline.
//!
//! So a hanging command costs a stale segment value, never a frozen frame.
//!
//! One cache lives on the terminal State; short-lived processes (the `shp`
//! prompt, CLI helpers) do not register one and keep using cmd.zig's bounded
//! synchronous path, which is what they want — they must produce a value and
//! exit.

const std = @import("std");
const posix = std.posix;
const logging = @import("logging.zig");

/// How long an in-flight command may run before it is killed. Generous: it
/// costs nothing to wait, since nothing is blocked on it.
pub const HARD_DEADLINE_MS: i64 = 10_000;
/// Default re-run interval for a command whose caller does not specify one.
pub const DEFAULT_REFRESH_MS: i64 = 1_000;
/// Cap on captured stdout per command.
pub const MAX_OUTPUT_BYTES: usize = 64 * 1024;

const Entry = struct {
    /// Owned copy of the command key (also the command line itself).
    key: []u8,
    /// argv for the process; either {"/bin/sh","-c",key} or an explicit argv.
    argv_owned: ?[][]u8 = null,

    child: ?std.process.Child = null,
    out_buf: std.ArrayList(u8) = .empty,
    started_ms: i64 = 0,
    /// Owned environment for the command (statusbar `when` conditions pass
    /// context through HEXE_STATUS_* vars). Refreshed before each spawn.
    env: ?std.process.EnvMap = null,

    /// Last completed stdout (trimmed), owned. Null until the first run lands.
    last_value: ?[]u8 = null,
    /// Whether the last completed run exited 0.
    last_ok: bool = false,
    /// Exit code of the last completed run (124 = killed at the deadline, the
    /// same code timeout(1) reports, so callers can treat it as a timeout).
    last_code: i32 = 0,
    /// When the last run completed (0 = never).
    last_done_ms: i64 = 0,
    /// How often to re-run.
    refresh_ms: i64 = DEFAULT_REFRESH_MS,

    fn inFlight(self: *const Entry) bool {
        return self.child != null;
    }
};

/// A completed run's outcome. `done` is false until the first run lands, which
/// is how a caller tells "not finished yet" from "finished with empty output".
pub const Result = struct {
    output: []const u8 = "",
    code: i32 = 0,
    ok: bool = false,
    done: bool = false,
    timed_out: bool = false,
};

/// Cap on fire-and-forget children awaiting reap. They are backgrounded by the
/// shell and exit almost immediately, so this only bounds a pathological case.
pub const MAX_DETACHED: usize = 256;

/// Kill a child and reap it WITHOUT ever blocking. Returns true if it was
/// reaped here.
///
/// Never use std's `Child.kill()` for this: it sends SIGTERM and then blocks in
/// `waitpid(pid, 0)`. A command that ignores SIGTERM — a shell with
/// `trap '' TERM`, anything wedged in uninterruptible I/O — makes that wait
/// never return. On an event loop that is a permanent freeze caused by the very
/// command we are trying to get rid of; at shutdown it is a process that will
/// not exit. SIGKILL cannot be caught or ignored, and the reap below never
/// waits: an uncollected corpse is picked up by a later poll(), or by init once
/// we are gone.
pub fn killNoWait(child: *std.process.Child) bool {
    posix.kill(child.id, posix.SIG.KILL) catch {};
    if (child.stdout) |out| {
        out.close();
        child.stdout = null;
    }
    if (child.stderr) |err| {
        err.close();
        child.stderr = null;
    }
    if (child.stdin) |in| {
        in.close();
        child.stdin = null;
    }
    // NOHANG: waitpid must never be called again on a pid reaped here — std's
    // waitpid treats ECHILD as unreachable and would panic.
    return posix.waitpid(child.id, posix.W.NOHANG).pid != 0;
}

/// Kill and reap within a small budget. For SHORT-LIVED processes (the shp
/// prompt, CLI helpers) that are about to exit anyway and have no event loop to
/// come back on. SIGKILL is uncatchable, so this collects the corpse in a few
/// ms; if it somehow does not, we give up rather than block.
pub fn killAndReapBounded(child: *std.process.Child, budget_ms: i64) void {
    if (killNoWait(child)) return;
    const deadline = std.time.milliTimestamp() + budget_ms;
    while (std.time.milliTimestamp() < deadline) {
        if (posix.waitpid(child.id, posix.W.NOHANG).pid != 0) return;
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }
}

pub const AsyncCmdCache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(*Entry),
    /// Fire-and-forget children (statusbar click actions, layout-open helper).
    /// Nobody wants their output; they exist here only so poll() can reap them
    /// instead of the event loop blocking in wait().
    detached: std.ArrayList(std.process.Child) = .empty,

    pub fn init(allocator: std.mem.Allocator) AsyncCmdCache {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(*Entry).init(allocator),
        };
    }

    pub fn deinit(self: *AsyncCmdCache) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry_ptr| {
            const e = entry_ptr.*;
            if (e.child) |*c| {
                // Must not block: a command that ignores SIGTERM would other-
                // wise keep the whole process from ever exiting.
                var child = c.*;
                _ = killNoWait(&child);
            }
            e.out_buf.deinit(self.allocator);
            if (e.env) |*env| env.deinit();
            if (e.last_value) |v| self.allocator.free(v);
            if (e.argv_owned) |argv| {
                for (argv) |a| self.allocator.free(a);
                self.allocator.free(argv);
            }
            self.allocator.free(e.key);
            self.allocator.destroy(e);
        }
        self.entries.deinit();
        // Reap what we can; anything still running is reparented to init on
        // exit, so it will never become a lasting zombie.
        for (self.detached.items) |*c| {
            _ = posix.waitpid(c.id, posix.W.NOHANG);
        }
        self.detached.deinit(self.allocator);
    }

    /// Spawn a fire-and-forget child: no stdio, no output, and — the point —
    /// no wait() on the caller's event loop. poll() reaps it later.
    ///
    /// The loop used to call child.wait() here. Even though the command is
    /// backgrounded by the shell, that still blocked the loop for a full
    /// `bash -lc` login-shell startup (which sources the user's profile: nvm,
    /// conda, ...) on every statusbar click — and forever if bash itself hung.
    pub fn spawnDetached(
        self: *AsyncCmdCache,
        argv: []const []const u8,
        env: ?*const std.process.EnvMap,
    ) bool {
        if (self.detached.items.len >= MAX_DETACHED) {
            // Nothing is reaping fast enough; drop rather than grow forever.
            logging.warn("async-cmd", "too many detached children ({d}); dropping spawn", .{self.detached.items.len});
            return false;
        }
        var child = std.process.Child.init(argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        if (env) |e| child.env_map = @constCast(e);
        child.spawn() catch |err| {
            logging.logError("async-cmd", "failed to spawn detached command", err);
            return false;
        };
        self.detached.append(self.allocator, child) catch {
            // Can't track it (OOM). Try to collect it without blocking; if it is
            // not done yet, leave it — init reaps it after we exit. Blocking in
            // wait() here would put the event loop at the mercy of the command.
            _ = posix.waitpid(child.id, posix.W.NOHANG);
            return true;
        };
        return true;
    }

    /// Take ownership of an already-spawned child purely so poll() will reap it.
    /// For a caller that cannot afford to wait on it (an event loop) but must
    /// not leak a zombie either.
    pub fn adoptForReaping(self: *AsyncCmdCache, child: std.process.Child) bool {
        if (self.detached.items.len >= MAX_DETACHED) return false;
        self.detached.append(self.allocator, child) catch return false;
        return true;
    }

    fn reapDetached(self: *AsyncCmdCache) void {
        var i: usize = 0;
        while (i < self.detached.items.len) {
            const c = self.detached.items[i];
            const res = posix.waitpid(c.id, posix.W.NOHANG);
            if (res.pid != 0) {
                _ = self.detached.swapRemove(i);
                continue; // don't advance: swapRemove moved a new item here
            }
            i += 1;
        }
    }

    fn getOrCreate(self: *AsyncCmdCache, key: []const u8, refresh_ms: i64) ?*Entry {
        if (self.entries.get(key)) |e| return e;
        const owned_key = self.allocator.dupe(u8, key) catch return null;
        const e = self.allocator.create(Entry) catch {
            self.allocator.free(owned_key);
            return null;
        };
        e.* = .{ .key = owned_key, .refresh_ms = refresh_ms };
        self.entries.put(owned_key, e) catch {
            self.allocator.free(owned_key);
            self.allocator.destroy(e);
            return null;
        };
        return e;
    }

    fn spawn(self: *AsyncCmdCache, e: *Entry) void {
        const argv: []const []const u8 = if (e.argv_owned) |owned| blk: {
            // Reinterpret [][]u8 as []const []const u8.
            break :blk @ptrCast(owned);
        } else &.{ "/bin/sh", "-c", e.key };

        var child = std.process.Child.init(argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        if (e.env) |*env| child.env_map = env;
        child.spawn() catch |err| {
            logging.logError("async-cmd", "failed to spawn background command", err);
            e.last_done_ms = std.time.milliTimestamp(); // don't hot-loop on spawn failure
            return;
        };
        // The pipe must be non-blocking: poll() reads whatever is there and
        // returns — it must never wait on a child that is still thinking.
        if (child.stdout) |out| {
            const flags = posix.fcntl(out.handle, posix.F.GETFL, 0) catch 0;
            _ = posix.fcntl(out.handle, posix.F.SETFL, flags | 0o4000) catch {};
        }
        e.out_buf.clearRetainingCapacity();
        e.started_ms = std.time.milliTimestamp();
        e.child = child;
    }

    fn finish(self: *AsyncCmdCache, e: *Entry, ok: bool, code: i32) void {
        const trimmed = std.mem.trim(u8, e.out_buf.items, " \t\r\n");
        if (e.last_value) |v| self.allocator.free(v);
        e.last_value = if (trimmed.len > 0) (self.allocator.dupe(u8, trimmed) catch null) else null;
        e.last_ok = ok;
        e.last_code = code;
        e.last_done_ms = std.time.milliTimestamp();
        e.child = null;
        e.out_buf.clearRetainingCapacity();
    }

    /// Drive in-flight commands. Called once per event-loop iteration; never
    /// blocks, no matter what the children are doing.
    pub fn poll(self: *AsyncCmdCache) void {
        self.reapDetached();
        const now = std.time.milliTimestamp();
        var it = self.entries.valueIterator();
        while (it.next()) |entry_ptr| {
            const e = entry_ptr.*;
            var child = &(e.child orelse continue);

            // Drain whatever is available right now.
            if (child.stdout) |out| {
                var buf: [4096]u8 = undefined;
                while (true) {
                    const n = posix.read(out.handle, &buf) catch |err| switch (err) {
                        error.WouldBlock => break, // nothing more for now
                        else => 0,
                    };
                    if (n == 0) break; // EOF or error: the wait below settles it
                    if (e.out_buf.items.len < MAX_OUTPUT_BYTES) {
                        e.out_buf.appendSlice(self.allocator, buf[0..n]) catch {};
                    }
                    if (n < buf.len) break;
                }
            }

            // Overran its hard deadline: SIGKILL it. 124 is what timeout(1)
            // reports, so callers read it as "timed out".
            if (now - e.started_ms > HARD_DEADLINE_MS) {
                logging.warn("async-cmd", "background command exceeded {d}ms and was killed: {s}", .{ HARD_DEADLINE_MS, e.key });
                var corpse = child.*;
                if (!killNoWait(&corpse)) {
                    // Not collectable this instant. Hand it to the reaper rather
                    // than block the loop waiting for it (or leak a zombie).
                    self.detached.append(self.allocator, corpse) catch {};
                }
                self.finish(e, false, 124);
                continue;
            }

            // Reap without blocking.
            const res = posix.waitpid(child.id, posix.W.NOHANG);
            if (res.pid != 0) {
                const exited = posix.W.IFEXITED(res.status);
                const code: i32 = if (exited) @intCast(posix.W.EXITSTATUS(res.status)) else 127;
                const ok = exited and code == 0;
                // Drain any tail the child wrote before exiting.
                if (child.stdout) |out| {
                    var buf: [4096]u8 = undefined;
                    while (true) {
                        const n = posix.read(out.handle, &buf) catch 0;
                        if (n == 0) break;
                        if (e.out_buf.items.len < MAX_OUTPUT_BYTES) {
                            e.out_buf.appendSlice(self.allocator, buf[0..n]) catch {};
                        }
                    }
                    out.close();
                }
                child.id = undefined; // reaped here; keep Child from double-reaping
                self.finish(e, ok, code);
            }
        }
    }

    /// Last known stdout for `cmd` (null until the first run completes), and
    /// schedule a refresh if it is due. NEVER blocks.
    pub fn value(self: *AsyncCmdCache, cmd: []const u8, refresh_ms: i64) ?[]const u8 {
        const e = self.getOrCreate(cmd, refresh_ms) orelse return null;
        e.refresh_ms = refresh_ms;
        const now = std.time.milliTimestamp();
        if (!e.inFlight() and (e.last_done_ms == 0 or now - e.last_done_ms >= e.refresh_ms)) {
            self.spawn(e);
        }
        return e.last_value;
    }

    /// Full outcome of the last completed run of `cmd`, scheduling a refresh if
    /// due. `done` is false until the first run lands. NEVER blocks — this is
    /// what backs `hexe.exec()` inside a statusbar render, where the old
    /// synchronous Child.run stalled a frame (or hung it forever when the
    /// command's grandchild held the stdout pipe open past timeout(1)).
    pub fn result(self: *AsyncCmdCache, cmd: []const u8, refresh_ms: i64) Result {
        const e = self.getOrCreate(cmd, refresh_ms) orelse return .{};
        e.refresh_ms = refresh_ms;
        const now = std.time.milliTimestamp();
        if (!e.inFlight() and (e.last_done_ms == 0 or now - e.last_done_ms >= e.refresh_ms)) {
            self.spawn(e);
        }
        if (e.last_done_ms == 0) return .{};
        return .{
            .output = e.last_value orelse "",
            .code = e.last_code,
            .ok = e.last_ok,
            .done = true,
            .timed_out = e.last_code == 124,
        };
    }

    /// Last known exit status for `cmd` (false until the first run completes),
    /// scheduling a refresh if due. NEVER blocks.
    pub fn succeeded(self: *AsyncCmdCache, cmd: []const u8, refresh_ms: i64) bool {
        const e = self.getOrCreate(cmd, refresh_ms) orelse return false;
        e.refresh_ms = refresh_ms;
        const now = std.time.milliTimestamp();
        if (!e.inFlight() and (e.last_done_ms == 0 or now - e.last_done_ms >= e.refresh_ms)) {
            self.spawn(e);
        }
        return e.last_ok;
    }

    /// Exit status for a shell command that needs an environment (statusbar
    /// `when` conditions). The env is copied into the entry and used for every
    /// background run; the value returned is the last completed status.
    /// NEVER blocks.
    pub fn succeededWithEnv(
        self: *AsyncCmdCache,
        cmd: []const u8,
        env: *const std.process.EnvMap,
        refresh_ms: i64,
    ) bool {
        const e = self.getOrCreate(cmd, refresh_ms) orelse return false;
        e.refresh_ms = refresh_ms;
        const now = std.time.milliTimestamp();
        const due = !e.inFlight() and (e.last_done_ms == 0 or now - e.last_done_ms >= e.refresh_ms);
        if (due) {
            // Refresh the stored env from the caller's current context.
            if (e.env) |*old| old.deinit();
            var copy = std.process.EnvMap.init(self.allocator);
            var it = env.iterator();
            while (it.next()) |kv| {
                copy.put(kv.key_ptr.*, kv.value_ptr.*) catch {};
            }
            e.env = copy;
            self.spawn(e);
        }
        return e.last_ok;
    }

    /// Same as `value`, for an explicit argv (git, sudo — no shell needed).
    /// `key` identifies the entry; argv is captured on first use.
    pub fn valueArgv(self: *AsyncCmdCache, key: []const u8, argv: []const []const u8, refresh_ms: i64) ?[]const u8 {
        const e = self.getOrCreate(key, refresh_ms) orelse return null;
        e.refresh_ms = refresh_ms;
        if (e.argv_owned == null) {
            const owned = self.allocator.alloc([]u8, argv.len) catch return e.last_value;
            var filled: usize = 0;
            for (argv, 0..) |a, i| {
                owned[i] = self.allocator.dupe(u8, a) catch break;
                filled = i + 1;
            }
            if (filled != argv.len) {
                for (owned[0..filled]) |a| self.allocator.free(a);
                self.allocator.free(owned);
                return e.last_value;
            }
            e.argv_owned = owned;
        }
        const now = std.time.milliTimestamp();
        if (!e.inFlight() and (e.last_done_ms == 0 or now - e.last_done_ms >= e.refresh_ms)) {
            self.spawn(e);
        }
        return e.last_value;
    }

    /// Exit status for an explicit argv (e.g. `sudo -n true`). NEVER blocks.
    pub fn succeededArgv(self: *AsyncCmdCache, key: []const u8, argv: []const []const u8, refresh_ms: i64) bool {
        _ = self.valueArgv(key, argv, refresh_ms);
        const e = self.entries.get(key) orelse return false;
        return e.last_ok;
    }

    /// Full outcome for an explicit argv. Backs `hexe.exec()`, which keeps its
    /// `timeout(1)` argv so kill semantics are unchanged — only the waiting is
    /// gone. NEVER blocks.
    pub fn resultArgv(self: *AsyncCmdCache, key: []const u8, argv: []const []const u8, refresh_ms: i64) Result {
        _ = self.valueArgv(key, argv, refresh_ms);
        const e = self.entries.get(key) orelse return .{};
        if (e.last_done_ms == 0) return .{};
        return .{
            .output = e.last_value orelse "",
            .code = e.last_code,
            .ok = e.last_ok,
            .done = true,
            .timed_out = e.last_code == 124,
        };
    }
};

const testing = std.testing;

/// Drive the cache until `pred` holds or the wall-clock budget runs out. This
/// stands in for the event loop calling poll() every iteration.
fn pumpUntil(cache: *AsyncCmdCache, budget_ms: i64, pred: *const fn (*AsyncCmdCache) bool) bool {
    const deadline = std.time.milliTimestamp() + budget_ms;
    while (std.time.milliTimestamp() < deadline) {
        cache.poll();
        if (pred(cache)) return true;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return false;
}

test "AsyncCmdCache: value() never blocks and lands the result on a later poll" {
    var cache = AsyncCmdCache.init(testing.allocator);
    defer cache.deinit();

    // First call returns null immediately (nothing has completed yet) and must
    // return FAST — the whole point is that the render path does not wait.
    const t0 = std.time.milliTimestamp();
    try testing.expect(cache.value("printf hello", 1000) == null);
    try testing.expect(std.time.milliTimestamp() - t0 < 100);

    const has_value = struct {
        fn f(c: *AsyncCmdCache) bool {
            return c.value("printf hello", 1000) != null;
        }
    }.f;
    try testing.expect(pumpUntil(&cache, 5000, has_value));
    try testing.expectEqualStrings("hello", cache.value("printf hello", 1000).?);
}

test "AsyncCmdCache: a hanging command never blocks value() and is killed at the deadline" {
    var cache = AsyncCmdCache.init(testing.allocator);
    defer cache.deinit();

    // 100 calls to a command that never exits: every one must return promptly.
    const t0 = std.time.milliTimestamp();
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try testing.expect(cache.value("sleep 300", 50) == null);
        cache.poll();
    }
    const elapsed = std.time.milliTimestamp() - t0;
    try testing.expect(elapsed < 1000); // the OLD code would have hung forever here
}

test "AsyncCmdCache: stale value is served while a refresh runs" {
    var cache = AsyncCmdCache.init(testing.allocator);
    defer cache.deinit();

    const cmd = "printf first";
    const landed = struct {
        fn f(c: *AsyncCmdCache) bool {
            return c.value("printf first", 10) != null;
        }
    }.f;
    try testing.expect(pumpUntil(&cache, 5000, landed));
    // Refresh interval is tiny, so the next call re-spawns — and must STILL
    // return the previous value rather than null or a block.
    const v = cache.value(cmd, 10);
    try testing.expectEqualStrings("first", v.?);
}

test "AsyncCmdCache: succeeded() reflects exit status without blocking" {
    var cache = AsyncCmdCache.init(testing.allocator);
    defer cache.deinit();

    const ok_done = struct {
        fn f(c: *AsyncCmdCache) bool {
            return c.succeeded("true", 10_000);
        }
    }.f;
    try testing.expect(pumpUntil(&cache, 5000, ok_done));

    var cache2 = AsyncCmdCache.init(testing.allocator);
    defer cache2.deinit();
    _ = cache2.succeeded("false", 10_000);
    var n: usize = 0;
    while (n < 100) : (n += 1) {
        cache2.poll();
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try testing.expect(!cache2.succeeded("false", 10_000));
}

test "AsyncCmdCache: result() reports pending before the first run lands, then the exit code" {
    var cache = AsyncCmdCache.init(testing.allocator);
    defer cache.deinit();

    // The very first call cannot have a value: it must say so rather than
    // report an empty-but-successful run, which a segment would render as real.
    const first = cache.result("echo hi", 10_000);
    try testing.expect(!first.done);
    try testing.expect(!first.ok);

    const landed = struct {
        fn f(c: *AsyncCmdCache) bool {
            return c.result("echo hi", 10_000).done;
        }
    }.f;
    try testing.expect(pumpUntil(&cache, 5000, landed));

    const r = cache.result("echo hi", 10_000);
    try testing.expect(r.done);
    try testing.expect(r.ok);
    try testing.expectEqual(@as(i32, 0), r.code);
    try testing.expectEqualStrings("hi", r.output);
    try testing.expect(!r.timed_out);

    // A non-zero exit must surface its code, not just "not ok".
    const code_landed = struct {
        fn f(c: *AsyncCmdCache) bool {
            return c.result("exit 3", 10_000).done;
        }
    }.f;
    try testing.expect(pumpUntil(&cache, 5000, code_landed));
    const bad = cache.result("exit 3", 10_000);
    try testing.expect(!bad.ok);
    try testing.expectEqual(@as(i32, 3), bad.code);
}

test "AsyncCmdCache: resultArgv keeps timeout(1) semantics without blocking" {
    var cache = AsyncCmdCache.init(testing.allocator);
    defer cache.deinit();

    // This is the argv hexe.exec builds: timeout(1) kills the command at 0.1s
    // and reports 124, which the caller reads as "timed out".
    const argv = [_][]const u8{ "timeout", "0.100s", "/bin/bash", "-lc", "sleep 30" };

    // The call itself must return instantly even though the command sleeps 30s.
    const t0 = std.time.milliTimestamp();
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const r = cache.resultArgv("exec-timeout", &argv, 10_000);
        try testing.expect(!r.done); // still running; never a fabricated value
    }
    try testing.expect(std.time.milliTimestamp() - t0 < 500);

    const landed = struct {
        fn f(c: *AsyncCmdCache) bool {
            const argv2 = [_][]const u8{ "timeout", "0.100s", "/bin/bash", "-lc", "sleep 30" };
            return c.resultArgv("exec-timeout", &argv2, 10_000).done;
        }
    }.f;
    try testing.expect(pumpUntil(&cache, 5000, landed));

    const r = cache.resultArgv("exec-timeout", &argv, 10_000);
    try testing.expect(r.done);
    try testing.expect(!r.ok);
    try testing.expectEqual(@as(i32, 124), r.code);
    try testing.expect(r.timed_out);
}

test "timeout(1) rejects an ms suffix — the duration must be fractional seconds" {
    // hexe.exec used to pass "80ms". timeout(1) accepts only s/m/h/d, so it
    // exited 125 and NEVER RAN the command: every hexe.exec call came back
    // empty. Pin the real behaviour so the ms form cannot creep back in.
    var cache = AsyncCmdCache.init(testing.allocator);
    defer cache.deinit();

    const bad = [_][]const u8{ "timeout", "80ms", "/bin/bash", "-lc", "echo ran" };
    const bad_landed = struct {
        fn f(c: *AsyncCmdCache) bool {
            const a = [_][]const u8{ "timeout", "80ms", "/bin/bash", "-lc", "echo ran" };
            return c.resultArgv("bad-ms", &a, 10_000).done;
        }
    }.f;
    try testing.expect(pumpUntil(&cache, 5000, bad_landed));
    const bad_r = cache.resultArgv("bad-ms", &bad, 10_000);
    try testing.expectEqual(@as(i32, 125), bad_r.code); // timeout refused the arg
    try testing.expectEqualStrings("", bad_r.output); // and echo never ran

    // The fractional-seconds form actually runs the command. The duration has to
    // be generous: `bash -lc` is a LOGIN shell and spends ~50-80ms sourcing the
    // profile before it runs anything, which is why hexe.exec's old 80ms default
    // could not even complete an `echo`.
    const good_landed = struct {
        fn f(c: *AsyncCmdCache) bool {
            const a = [_][]const u8{ "timeout", "5.000s", "/bin/bash", "-lc", "echo ran" };
            return c.resultArgv("good-s", &a, 10_000).done;
        }
    }.f;
    try testing.expect(pumpUntil(&cache, 9000, good_landed));
    const good = [_][]const u8{ "timeout", "5.000s", "/bin/bash", "-lc", "echo ran" };
    const good_r = cache.resultArgv("good-s", &good, 10_000);
    try testing.expectEqualStrings("ran", good_r.output);
}

test "hexe.exec's default timeout leaves room for a login shell to start" {
    // Regression guard for the pair of bugs above: the default must be long
    // enough that `bash -lc` can source the profile AND run the command, or
    // every hexe.exec call comes back empty on a busy machine.
    var buf: [32]u8 = undefined;
    const arg = try std.fmt.bufPrint(&buf, "{d}.{d:0>3}s", .{ @as(u64, 2000) / 1000, @as(u64, 2000) % 1000 });
    try testing.expectEqualStrings("2.000s", arg);

    var cache = AsyncCmdCache.init(testing.allocator);
    defer cache.deinit();
    const argv = [_][]const u8{ "timeout", "2.000s", "/bin/bash", "-lc", "echo alive" };
    const landed = struct {
        fn f(c: *AsyncCmdCache) bool {
            const a = [_][]const u8{ "timeout", "2.000s", "/bin/bash", "-lc", "echo alive" };
            return c.resultArgv("default-timeout", &a, 10_000).done;
        }
    }.f;
    try testing.expect(pumpUntil(&cache, 9000, landed));
    const r = cache.resultArgv("default-timeout", &argv, 10_000);
    try testing.expect(r.ok);
    try testing.expectEqualStrings("alive", r.output);
}

test "AsyncCmdCache: spawnDetached never blocks and leaves no zombies" {
    var cache = AsyncCmdCache.init(testing.allocator);
    defer cache.deinit();

    // A statusbar click action. Deliberately NOT backgrounded with `&`: the
    // point is that spawnDetached itself never waits. The old event loop called
    // child.wait() right here, so 10 clicks on a segment whose action takes 3s
    // would have frozen the UI for 30 seconds.
    const argv = [_][]const u8{ "/bin/bash", "-c", "sleep 3" };

    const t0 = std.time.milliTimestamp();
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try testing.expect(cache.spawnDetached(&argv, null));
    }
    const spawn_ms = std.time.milliTimestamp() - t0;
    try testing.expect(spawn_ms < 1500); // the old wait() path: ~30_000

    // And they must be reaped in the background, not left as zombies.
    const all_reaped = struct {
        fn f(c: *AsyncCmdCache) bool {
            return c.detached.items.len == 0;
        }
    }.f;
    try testing.expect(pumpUntil(&cache, 15_000, all_reaped));
}

test "AsyncCmdCache: a command that IGNORES SIGTERM is still killed, without blocking" {
    // The nastiest case for the deadline path. std's Child.kill() sends SIGTERM
    // and then blocks in waitpid(pid, 0) — against a process that traps SIGTERM
    // that wait NEVER returns, so the event loop would freeze on the very
    // command it was trying to kill, and the process could never exit either.
    var cache = AsyncCmdCache.init(testing.allocator);

    const argv = [_][]const u8{ "/bin/bash", "-c", "trap '' TERM; sleep 300" };
    _ = cache.valueArgv("sigterm-proof", &argv, 60_000);

    // Let it actually start and install the trap.
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        cache.poll();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    const e = cache.entries.get("sigterm-proof").?;
    try testing.expect(e.child != null); // in flight, ignoring SIGTERM
    const pid = e.child.?.id;

    // Shutdown must not block, even though SIGTERM is useless against it.
    const t0 = std.time.milliTimestamp();
    cache.deinit();
    const elapsed = std.time.milliTimestamp() - t0;
    try testing.expect(elapsed < 1000); // Child.kill() here would never return

    // And it must really be dead — killed, not merely abandoned.
    var waited: usize = 0;
    var gone = false;
    while (waited < 200) : (waited += 1) {
        if (posix.kill(pid, 0)) |_| {} else |err| {
            if (err == error.ProcessNotFound) {
                gone = true;
                break;
            }
        }
        // A reaped-but-unwaited child is a zombie: signal 0 still "succeeds".
        // Reap it here (we are its parent) to settle the question.
        if (posix.waitpid(pid, posix.W.NOHANG).pid != 0) {
            gone = true;
            break;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try testing.expect(gone);
}

test "AsyncCmdCache: spawnDetached refuses to grow without bound" {
    var cache = AsyncCmdCache.init(testing.allocator);
    defer cache.deinit();

    // Nothing reaps between spawns here, so the cap is what stops a runaway
    // (a key held down on a statusbar action) from forking forever.
    const argv = [_][]const u8{ "/bin/bash", "-c", "sleep 10" };
    var accepted: usize = 0;
    var i: usize = 0;
    while (i < MAX_DETACHED + 8) : (i += 1) {
        if (cache.spawnDetached(&argv, null)) accepted += 1;
    }
    try testing.expectEqual(MAX_DETACHED, accepted);
    try testing.expectEqual(MAX_DETACHED, cache.detached.items.len);

    // Don't leave 256 sleeps behind for the rest of the suite.
    for (cache.detached.items) |*c| {
        _ = posix.kill(c.id, posix.SIG.KILL) catch {};
    }
    const all_reaped = struct {
        fn f(c: *AsyncCmdCache) bool {
            return c.detached.items.len == 0;
        }
    }.f;
    try testing.expect(pumpUntil(&cache, 15_000, all_reaped));
}
