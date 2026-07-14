//! Bounded external-command execution.
//!
//! Statusbar segments, float titles and `when` conditions run user-supplied
//! shell commands — and they run them SYNCHRONOUSLY, inside the render path
//! of a single-threaded event loop. The old call sites used
//! `std.process.Child.run` / a blocking `stdout.read()`, so a command that
//! never exits (or merely runs long: git in a huge repo, a network call, a
//! shell that waits on stdin) froze the entire terminal — no rendering, no
//! keystrokes, nothing. Observed live: the frontend parked in
//! `anon_pipe_read` at 0% CPU with a fully built session behind it.
//!
//! Everything here is bounded: the child gets a deadline, and on expiry it is
//! killed and reaped. A misbehaving segment costs one stale value, never the
//! UI.

const std = @import("std");
const posix = std.posix;
const logging = @import("logging.zig");
const async_cmd = @import("async_cmd.zig");

/// The terminal frontend registers a cache here at startup. When it is set,
/// the *Cached helpers below become fully NON-BLOCKING: they serve the last
/// completed result and let the event loop drive the command in the
/// background. Short-lived processes (the `shp` prompt, CLI helpers) never
/// register one and keep the bounded synchronous path — they must produce a
/// value and exit, so blocking briefly is exactly right for them.
pub var async_cache: ?*async_cmd.AsyncCmdCache = null;

pub fn setAsyncCache(cache: *async_cmd.AsyncCmdCache) void {
    async_cache = cache;
}

/// Non-blocking in the terminal (cached, refreshed in the background);
/// bounded-synchronous everywhere else. Returned memory is owned by the cache
/// when async — callers must NOT free it; when synchronous the caller owns it.
/// Use `valueIsOwned()` to know which, or prefer copying into a local buffer.
pub fn cachedValue(cmd: []const u8, refresh_ms: i64) ?[]const u8 {
    if (async_cache) |cache| return cache.value(cmd, refresh_ms);
    return null; // no cache: caller falls back to its own bounded path
}

pub fn cachedSucceeded(cmd: []const u8, refresh_ms: i64) ?bool {
    if (async_cache) |cache| return cache.succeeded(cmd, refresh_ms);
    return null;
}

pub fn cachedValueArgv(key: []const u8, argv: []const []const u8, refresh_ms: i64) ?[]const u8 {
    if (async_cache) |cache| return cache.valueArgv(key, argv, refresh_ms);
    return null;
}

pub fn cachedSucceededArgv(key: []const u8, argv: []const []const u8, refresh_ms: i64) ?bool {
    if (async_cache) |cache| return cache.succeededArgv(key, argv, refresh_ms);
    return null;
}

pub fn cachedSucceededWithEnv(cmd: []const u8, env: *const std.process.EnvMap, refresh_ms: i64) ?bool {
    if (async_cache) |cache| return cache.succeededWithEnv(cmd, env, refresh_ms);
    return null;
}

/// Full outcome (stdout + exit code) of a background command. Null when no
/// async cache is registered, so the caller keeps its bounded synchronous path.
pub fn cachedResult(cmd: []const u8, refresh_ms: i64) ?async_cmd.Result {
    if (async_cache) |cache| return cache.result(cmd, refresh_ms);
    return null;
}

pub fn cachedResultArgv(key: []const u8, argv: []const []const u8, refresh_ms: i64) ?async_cmd.Result {
    if (async_cache) |cache| return cache.resultArgv(key, argv, refresh_ms);
    return null;
}

pub fn hasAsyncCache() bool {
    return async_cache != null;
}

/// Default budget for a segment command. Segments re-run on a timer, so this
/// is per render, not per session — it must stay small.
pub const DEFAULT_TIMEOUT_MS: i32 = 500;

fn deadlineExpired(deadline_ms: i64) bool {
    return std.time.milliTimestamp() >= deadline_ms;
}

/// Kill the child and reap it. The caller must NOT also call `wait()` — that
/// double-reap aborts.
///
/// Deliberately not std's `Child.kill()`: it sends SIGTERM and then blocks in
/// waitpid, so a command that ignores SIGTERM would hang us on the very command
/// we are killing for taking too long. SIGKILL cannot be ignored.
fn killAndReap(child: *std.process.Child, cmd: []const u8) void {
    logging.warn("cmd", "command exceeded its time budget and was killed: {s}", .{cmd});
    async_cmd.killAndReapBounded(child, 100);
}

/// Run an explicit argv, capturing stdout, with a hard deadline. Same
/// rationale as `runCaptured`: these run in the render path (git status,
/// sudo -n) and a slow repo or a wedged sudo must not freeze the UI.
pub fn runArgvCaptured(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    max_bytes: usize,
    timeout_ms: i32,
) ?[]u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;

    const out = child.stdout orelse {
        _ = child.wait() catch {};
        return null;
    };
    var buf = allocator.alloc(u8, max_bytes) catch {
        async_cmd.killAndReapBounded(&child, 100);
        return null;
    };
    var len: usize = 0;
    const deadline = std.time.milliTimestamp() + timeout_ms;
    var timed_out = false;
    var exit_ok = false;

    while (len < buf.len) {
        const remaining = deadline - std.time.milliTimestamp();
        if (remaining <= 0) {
            timed_out = true;
            break;
        }
        var pfd = [_]posix.pollfd{.{ .fd = out.handle, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&pfd, @intCast(@min(remaining, 1000))) catch break;
        if (ready == 0) continue;
        const n = out.read(buf[len..]) catch break;
        if (n == 0) break;
        len += n;
    }

    if (timed_out) {
        killAndReap(&child, argv[0]);
    } else if (child.wait()) |term| {
        exit_ok = switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };
    } else |_| {}

    if (timed_out or !exit_ok) {
        allocator.free(buf);
        return null;
    }
    const owned = allocator.realloc(buf, len) catch {
        allocator.free(buf);
        return null;
    };
    return owned;
}

/// Run `cmd` under /bin/sh, capturing stdout, with a hard deadline.
/// Returns an allocator-owned, trimmed copy of stdout (caller frees), or null
/// on failure/timeout/empty output.
///
/// NOTE: callers must not hold on to the returned slice past their own
/// lifetime — it is heap-owned, unlike the stack buffer the old
/// implementation leaked (that slice dangled the moment it returned).
pub fn runCaptured(
    allocator: std.mem.Allocator,
    cmd: []const u8,
    max_bytes: usize,
    timeout_ms: i32,
) ?[]u8 {
    var child = std.process.Child.init(&.{ "/bin/sh", "-c", cmd }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch |err| {
        logging.logError("cmd", "failed to spawn command", err);
        return null;
    };

    const out = child.stdout orelse {
        _ = child.wait() catch {};
        return null;
    };

    var buf = allocator.alloc(u8, max_bytes) catch {
        killAndReap(&child, cmd);
        return null;
    };
    var len: usize = 0;
    const deadline = std.time.milliTimestamp() + timeout_ms;
    var timed_out = false;

    while (len < buf.len) {
        const remaining = deadline - std.time.milliTimestamp();
        if (remaining <= 0) {
            timed_out = true;
            break;
        }
        var pfd = [_]posix.pollfd{.{
            .fd = out.handle,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = posix.poll(&pfd, @intCast(@min(remaining, 1000))) catch break;
        if (ready == 0) continue; // nothing yet; deadline re-checked above
        const n = out.read(buf[len..]) catch break;
        if (n == 0) break; // EOF: the command finished
        len += n;
    }

    if (timed_out) {
        killAndReap(&child, cmd);
    } else {
        _ = child.wait() catch {};
    }

    const trimmed = std.mem.trim(u8, buf[0..len], " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(buf);
        return null;
    }
    // Return exactly the trimmed bytes, heap-owned.
    const owned = allocator.alloc(u8, trimmed.len) catch {
        allocator.free(buf);
        return null;
    };
    @memcpy(owned, trimmed);
    allocator.free(buf);
    return owned;
}

/// Run an explicit argv with a deadline; true only if it exits 0 in time.
/// (Commands like `sudo -n true` produce no stdout, so success cannot be
/// inferred from captured output.)
pub fn runArgvSucceeds(allocator: std.mem.Allocator, argv: []const []const u8, timeout_ms: i32) bool {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;

    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (true) {
        const res = posix.waitpid(child.id, posix.W.NOHANG);
        if (res.pid != 0) {
            child.id = undefined;
            return posix.W.IFEXITED(res.status) and posix.W.EXITSTATUS(res.status) == 0;
        }
        if (deadlineExpired(deadline)) {
            killAndReap(&child, argv[0]);
            return false;
        }
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }
}

/// Run `cmd` under /bin/sh with a deadline; true only if it exits 0 in time.
/// A command that overruns its budget is killed and reported as false.
pub fn runSucceeds(allocator: std.mem.Allocator, cmd: []const u8, timeout_ms: i32) bool {
    var child = std.process.Child.init(&.{ "/bin/sh", "-c", cmd }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch |err| {
        logging.logError("cmd", "failed to spawn condition command", err);
        return false;
    };

    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (true) {
        // Poll the child instead of blocking in wait(): a `when` condition
        // that hangs used to hang the render loop with it.
        const res = posix.waitpid(child.id, posix.W.NOHANG);
        if (res.pid != 0) {
            child.id = undefined; // reaped by us; keep Child.wait from double-reaping
            return posix.W.IFEXITED(res.status) and posix.W.EXITSTATUS(res.status) == 0;
        }
        if (deadlineExpired(deadline)) {
            killAndReap(&child, cmd);
            return false;
        }
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }
}

const testing = std.testing;

test "runCaptured: returns trimmed heap-owned output" {
    const out = runCaptured(testing.allocator, "printf 'hello\\n'", 256, 2000) orelse return error.NoOutput;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello", out);
}

test "runCaptured: a hanging command is killed at the deadline, not waited on" {
    const t0 = std.time.milliTimestamp();
    // `sleep` never writes and never exits within the budget: the old
    // blocking read would hang here forever.
    const out = runCaptured(testing.allocator, "sleep 30", 256, 300);
    const elapsed = std.time.milliTimestamp() - t0;
    if (out) |o| testing.allocator.free(o);
    try testing.expect(out == null);
    try testing.expect(elapsed < 5_000);
}

test "runCaptured: partial output before a hang is still returned" {
    const t0 = std.time.milliTimestamp();
    const out = runCaptured(testing.allocator, "printf 'partial'; sleep 30", 256, 400);
    const elapsed = std.time.milliTimestamp() - t0;
    defer if (out) |o| testing.allocator.free(o);
    try testing.expect(elapsed < 5_000);
    try testing.expectEqualStrings("partial", out orelse return error.NoOutput);
}

test "runSucceeds: exit status honored; a hanging condition is killed" {
    try testing.expect(runSucceeds(testing.allocator, "true", 2000));
    try testing.expect(!runSucceeds(testing.allocator, "false", 2000));
    const t0 = std.time.milliTimestamp();
    try testing.expect(!runSucceeds(testing.allocator, "sleep 30", 300));
    try testing.expect(std.time.milliTimestamp() - t0 < 5_000);
}
