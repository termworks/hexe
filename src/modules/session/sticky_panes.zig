const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ses = @import("main.zig");
const store_mod = @import("store.zig");
const persist = @import("persist.zig");

pub fn isPidAlive(pid: posix.pid_t) bool {
    if (pid <= 0) return false;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch |err| {
        core.logging.logError("ses", "failed to format sticky pane pid stat path", err);
        return false;
    };
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        if (err != error.FileNotFound) {
            core.logging.logError("ses", "failed to open sticky pane pid stat", err);
        }
        return false;
    };
    defer file.close();

    // A zombie still has a /proc entry but the process is gone: treating it
    // as alive makes pane reuse race against pod teardown (the user closes a
    // float, immediately reopens, and gets handed the dying pane). The state
    // char is the first non-space byte after the last ')' in the stat line.
    var buf: [512]u8 = undefined;
    const n = file.read(&buf) catch return true;
    const data = buf[0..n];
    const close_paren = std.mem.lastIndexOfScalar(u8, data, ')') orelse return true;
    var i = close_paren + 1;
    while (i < data.len and data[i] == ' ') i += 1;
    if (i < data.len and (data[i] == 'Z' or data[i] == 'X')) return false;
    return true;
}

pub fn findStickyPane(store: *store_mod.SessionStore, pwd: []const u8, key: u8) ?*store_mod.Pane {
    return findStickyPaneWithAffinity(store, pwd, key, null);
}

pub fn findStickyPaneWithAffinity(
    store: *store_mod.SessionStore,
    pwd: []const u8,
    key: u8,
    preferred_session_name: ?[]const u8,
) ?*store_mod.Pane {
    var fallback_pane: ?*store_mod.Pane = null;

    var iter = store.panes.valueIterator();
    while (iter.next()) |pane| {
        // Sticky candidates can be idle (.sticky), currently active
        // (.attached), or parked inside a detached session (.detached).
        // Per-CWD sticky floats are globally keyed by pwd+key, so launching
        // one after reattach must reuse the existing detached pod instead of
        // spawning a duplicate just because it is not currently attached.
        if (pane.state == .sticky or pane.state == .attached or pane.state == .detached) {
            if (!isPidAlive(pane.child_pid)) continue;
            // A pane whose pod died cannot be wired up again: skip it so the
            // caller falls through to spawning a fresh pod instead of handing
            // the frontend a dead pane.
            if (!isPidAlive(pane.pod_pid)) continue;
            // Pid liveness is not enough across reboots or pid reuse: the pid
            // may belong to an unrelated process now. Only a pod that still
            // accepts on its socket can be re-adopted; anything else must fall
            // through to a fresh spawn instead of a float that never opens.
            if (!persist.podSocketAlive(pane.pod_socket_path)) continue;
            if (pane.sticky_pwd) |spwd| {
                if (pane.sticky_key) |skey| {
                    if (skey == key and std.mem.eql(u8, spwd, pwd)) {
                        if (preferred_session_name) |psn| {
                            if (pane.sticky_session_name) |ssn| {
                                if (std.mem.eql(u8, ssn, psn)) {
                                    ses.debugLog("findStickyPane: affinity match (session={s})", .{psn});
                                    return pane;
                                }
                            }
                        }
                        if (fallback_pane == null) {
                            fallback_pane = pane;
                        }
                    }
                }
            }
        }
    }

    if (fallback_pane != null) {
        if (preferred_session_name) |psn| {
            ses.debugLog("findStickyPane: using fallback (preferred={s})", .{psn});
        }
    }
    return fallback_pane;
}
