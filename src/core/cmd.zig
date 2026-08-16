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

pub fn cachedResultArgv(key: []const u8, argv: []const []const u8, refresh_ms: i64) ?async_cmd.Result {
    if (async_cache) |cache| return cache.resultArgv(key, argv, refresh_ms);
    return null;
}

/// Hand a spawned child to the background reaper. True if it was adopted; false
/// means there is no cache (a short-lived process) and the caller must reap it
/// itself.
pub fn reapLater(child: std.process.Child) bool {
    if (async_cache) |cache| return cache.adoptForReaping(child);
    return false;
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

const testing = std.testing;
