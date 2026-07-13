const std = @import("std");
const ses = @import("main.zig");

/// Session lock state - prevents concurrent attach/detach.
pub const SessionLockState = enum {
    attaching, // Reattach in progress
    detaching, // Detach in progress
};

/// Session lock entry - tracks ongoing operations.
pub const SessionLock = struct {
    client_id: usize,
    state: SessionLockState,
    locked_at: i64, // Timestamp for timeout detection (expiry: 5s — attach
    // commits within milliseconds; a longer window holds every reattach of
    // the session hostage when a lock leaks)
};

/// Concurrent attach/detach serialization per session_id.
pub const SessionLocks = struct {
    session_locks: std.AutoHashMap([16]u8, SessionLock),

    pub fn init(allocator: std.mem.Allocator) SessionLocks {
        return .{
            .session_locks = std.AutoHashMap([16]u8, SessionLock).init(allocator),
        };
    }

    pub fn deinit(self: *SessionLocks) void {
        self.session_locks.deinit();
    }

    /// Acquire a session lock for an attach/detach operation.
    /// Returns `error.SessionLocked` if another op holds an active lock.
    pub fn acquire(
        self: *SessionLocks,
        session_id: [16]u8,
        client_id: usize,
        state: SessionLockState,
    ) !void {
        if (self.session_locks.get(session_id)) |existing_lock| {
            const now = std.time.timestamp();
            const lock_age = now - existing_lock.locked_at;
            if (lock_age > 5) {
                ses.debugLog("acquireSessionLock: expired lock detected, removing (age={d}s)", .{lock_age});
                _ = self.session_locks.remove(session_id);
            } else {
                return error.SessionLocked;
            }
        }

        const lock = SessionLock{
            .client_id = client_id,
            .state = state,
            .locked_at = std.time.timestamp(),
        };
        try self.session_locks.put(session_id, lock);
        ses.debugLog("acquireSessionLock: locked session {s} for {s}", .{
            std.fmt.bytesToHex(&session_id, .lower)[0..8],
            @tagName(state),
        });
    }

    pub fn release(self: *SessionLocks, session_id: [16]u8) void {
        if (self.session_locks.remove(session_id)) {
            ses.debugLog("releaseSessionLock: released session {s}", .{
                std.fmt.bytesToHex(&session_id, .lower)[0..8],
            });
        }
    }

    pub fn isLocked(self: *const SessionLocks, session_id: [16]u8) bool {
        return self.session_locks.contains(session_id);
    }

    pub fn releaseClient(self: *SessionLocks, allocator: std.mem.Allocator, client_id: usize) void {
        var to_release: std.ArrayList([16]u8) = .empty;
        defer to_release.deinit(allocator);

        var iter = self.session_locks.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.client_id == client_id) {
                to_release.append(allocator, entry.key_ptr.*) catch |err| {
                    ses.debugLog("releaseClientLocks: failed to collect lock for client {d}: {s}", .{ client_id, @errorName(err) });
                    continue;
                };
            }
        }

        for (to_release.items) |session_id| {
            self.release(session_id);
        }
    }
};
