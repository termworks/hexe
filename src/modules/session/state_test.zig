const std = @import("std");
const testing = std.testing;
const state = @import("state.zig");
const txlog = @import("txlog.zig");

/// Test helper: failing allocator that fails after N allocations
const FailingAllocator = struct {
    parent_allocator: std.mem.Allocator,
    fail_after: usize,
    alloc_count: usize = 0,

    fn init(parent: std.mem.Allocator, fail_after: usize) FailingAllocator {
        return .{
            .parent_allocator = parent,
            .fail_after = fail_after,
        };
    }

    fn allocator(self: *FailingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *FailingAllocator = @ptrCast(@alignCast(ctx));
        self.alloc_count += 1;
        if (self.alloc_count > self.fail_after) {
            return null; // Simulate allocation failure
        }
        return self.parent_allocator.rawAlloc(len, ptr_align, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *FailingAllocator = @ptrCast(@alignCast(ctx));
        return self.parent_allocator.rawResize(buf, buf_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        const self: *FailingAllocator = @ptrCast(@alignCast(ctx));
        self.parent_allocator.rawFree(buf, buf_align, ret_addr);
    }
};

// ============================================================================
// State Transition Tests
// ============================================================================

test "PaneState: all valid transitions succeed" {
    const transitions = .{
        // From attached
        .{ state.PaneState.attached, state.PaneState.attached },
        .{ state.PaneState.attached, state.PaneState.detached },
        .{ state.PaneState.attached, state.PaneState.sticky },
        .{ state.PaneState.attached, state.PaneState.orphaned },
        // From detached
        .{ state.PaneState.detached, state.PaneState.detached },
        .{ state.PaneState.detached, state.PaneState.attached },
        .{ state.PaneState.detached, state.PaneState.orphaned },
        // From sticky
        .{ state.PaneState.sticky, state.PaneState.sticky },
        .{ state.PaneState.sticky, state.PaneState.attached },
        .{ state.PaneState.sticky, state.PaneState.orphaned },
        // From orphaned
        .{ state.PaneState.orphaned, state.PaneState.orphaned },
        .{ state.PaneState.orphaned, state.PaneState.attached },
        .{ state.PaneState.orphaned, state.PaneState.sticky },
    };

    inline for (transitions) |t| {
        const from = t[0];
        const to = t[1];
        try testing.expect(state.PaneState.isValidTransition(from, to));
    }
}

test "PaneState: all invalid transitions fail" {
    const invalid_transitions = .{
        // From detached
        .{ state.PaneState.detached, state.PaneState.sticky },
        // From sticky
        .{ state.PaneState.sticky, state.PaneState.detached },
        // From orphaned
        .{ state.PaneState.orphaned, state.PaneState.detached },
    };

    inline for (invalid_transitions) |t| {
        const from = t[0];
        const to = t[1];
        try testing.expect(!state.PaneState.isValidTransition(from, to));
    }
}

test "Pane.transitionState: valid transition updates state" {
    var pane = state.Pane{
        .uuid = [_]u8{0} ** 32,
        .name = null,
        .pod_pid = 1234,
        .pod_socket_path = "/tmp/test",
        .child_pid = 5678,
        .state = .attached,
        .sticky_pwd = null,
        .sticky_key = null,
        .attached_to = 1,
        .session_id = null,
        .created_at = 0,
        .orphaned_at = null,
        .allocator = testing.allocator,
    };

    // Valid transition
    const result = pane.transitionState(.sticky, "test transition");
    try testing.expect(result);
    try testing.expectEqual(state.PaneState.sticky, pane.state);
}

test "Pane.transitionState: invalid transition rejected" {
    var pane = state.Pane{
        .uuid = [_]u8{0} ** 32,
        .name = null,
        .pod_pid = 1234,
        .pod_socket_path = "/tmp/test",
        .child_pid = 5678,
        .state = .detached,
        .sticky_pwd = null,
        .sticky_key = null,
        .attached_to = null,
        .session_id = [_]u8{1} ** 16,
        .created_at = 0,
        .orphaned_at = null,
        .allocator = testing.allocator,
    };

    // Invalid transition: detached -> sticky
    const result = pane.transitionState(.sticky, "invalid test");
    try testing.expect(!result);
    try testing.expectEqual(state.PaneState.detached, pane.state); // State unchanged
}

test "Pane.transitionState: sets orphaned_at timestamp" {
    var pane = state.Pane{
        .uuid = [_]u8{0} ** 32,
        .name = null,
        .pod_pid = 1234,
        .pod_socket_path = "/tmp/test",
        .child_pid = 5678,
        .state = .attached,
        .sticky_pwd = null,
        .sticky_key = null,
        .attached_to = 1,
        .session_id = null,
        .created_at = 0,
        .orphaned_at = null,
        .allocator = testing.allocator,
    };

    try testing.expect(pane.orphaned_at == null);
    _ = pane.transitionState(.orphaned, "test orphan");
    try testing.expect(pane.orphaned_at != null);
}

// ============================================================================
// Session Lock Tests
// ============================================================================

test "SessionLock: acquire and release" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const session_id = [_]u8{1} ** 16;
    const client_id: usize = 1;

    // Should acquire successfully
    try ses_state.acquireSessionLock(session_id, client_id, .detaching);
    try testing.expect(ses_state.isSessionLocked(session_id));

    // Should fail to acquire again
    try testing.expectError(error.SessionLocked, ses_state.acquireSessionLock(session_id, client_id, .attaching));

    // Release and verify
    ses_state.releaseSessionLock(session_id);
    try testing.expect(!ses_state.isSessionLocked(session_id));

    // Should acquire successfully after release
    try ses_state.acquireSessionLock(session_id, client_id, .attaching);
    try testing.expect(ses_state.isSessionLocked(session_id));

    ses_state.releaseSessionLock(session_id);
}

test "SessionLock: timeout releases stale locks" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const session_id = [_]u8{1} ** 16;
    const client_id: usize = 1;

    // Acquire lock
    try ses_state.acquireSessionLock(session_id, client_id, .detaching);
    try testing.expect(ses_state.isSessionLocked(session_id));

    // Manually set lock timestamp to old value (simulate timeout)
    if (ses_state.session_locks.getPtr(session_id)) |lock| {
        lock.locked_at = std.time.timestamp() - 31; // 31 seconds ago (timeout is 30s)
    }

    // Should acquire successfully (old lock auto-removed)
    try ses_state.acquireSessionLock(session_id, client_id, .attaching);
    try testing.expect(ses_state.isSessionLocked(session_id));

    ses_state.releaseSessionLock(session_id);
}

// ============================================================================
// Session Name Resolution Tests
// ============================================================================

test "resolveSessionName: unique name returned as-is" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const name = "alpha";
    const resolved = ses_state.resolveSessionName(name, null) orelse return error.AllocationFailed;
    // Note: resolved is allocated with page_allocator (SesState.allocator), not testing.allocator
    defer ses_state.allocator.free(resolved);

    try testing.expectEqualStrings(name, resolved);
}

test "resolveSessionName: conflicting name gets suffix" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    // Add a client with session name "alpha"
    const fd: std.posix.fd_t = 99; // Fake fd
    const client_id = try ses_state.addClient(fd);
    if (ses_state.getClient(client_id)) |client| {
        client.session_name = try ses_state.allocator.dupe(u8, "alpha");
    }

    // Try to resolve "alpha" - should get "alpha-2"
    const resolved = ses_state.resolveSessionName("alpha", null) orelse return error.AllocationFailed;
    defer ses_state.allocator.free(resolved);

    try testing.expectEqualStrings("alpha-2", resolved);
}

test "resolveSessionName: ignores current client on re-register" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const fd: std.posix.fd_t = 100;
    const client_id = try ses_state.addClient(fd);
    if (ses_state.getClient(client_id)) |client| {
        client.session_name = try ses_state.allocator.dupe(u8, "alpha");
    }

    const resolved = ses_state.resolveSessionName("alpha", client_id) orelse return error.AllocationFailed;
    defer ses_state.allocator.free(resolved);

    try testing.expectEqualStrings("alpha", resolved);
}

// ============================================================================
// Transaction Log Tests
// ============================================================================

test "TxLog: write and read entries" {
    const tmp_path = "/tmp/hexa-test-txlog";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var log = try txlog.TxLog.init(testing.allocator, tmp_path);
    defer log.deinit();

    try log.open();

    const session_id = [_]u8{1} ** 16;
    const payload = "test_payload";

    // Write detach_start
    try log.write(.detach_start, session_id, payload);

    // Write detach_commit
    try log.write(.detach_commit, session_id, payload);

    // Read all entries
    var entries = try log.readAll(testing.allocator);
    defer {
        for (entries.items) |*e| {
            testing.allocator.free(e.payload);
        }
        entries.deinit(testing.allocator);
    }

    try testing.expectEqual(@as(usize, 2), entries.items.len);
    try testing.expectEqual(txlog.TxType.detach_start, entries.items[0].tx_type);
    try testing.expectEqual(txlog.TxType.detach_commit, entries.items[1].tx_type);
    try testing.expectEqualSlices(u8, &session_id, &entries.items[0].session_id);
}

test "TxLog: findIncompleteTransactions detects incomplete detach" {
    const page_alloc = std.heap.page_allocator;
    var entries: std.ArrayList(txlog.TxLogEntry) = .empty;
    defer entries.deinit(page_alloc);

    const session_id_1 = [_]u8{1} ** 16;
    const session_id_2 = [_]u8{2} ** 16;

    // Complete transaction
    try entries.append(page_alloc, .{
        .tx_type = .detach_start,
        .timestamp = 100,
        .session_id = session_id_1,
        .payload = "",
    });
    try entries.append(page_alloc, .{
        .tx_type = .detach_commit,
        .timestamp = 101,
        .session_id = session_id_1,
        .payload = "",
    });

    // Incomplete transaction
    try entries.append(page_alloc, .{
        .tx_type = .detach_start,
        .timestamp = 200,
        .session_id = session_id_2,
        .payload = "",
    });

    var incomplete = try txlog.findIncompleteTransactions(entries.items);
    defer incomplete.deinit(page_alloc); // Use page_alloc since that's what findIncompleteTransactions uses

    try testing.expectEqual(@as(usize, 1), incomplete.items.len);
    try testing.expectEqualSlices(u8, &session_id_2, &incomplete.items[0]);
}

test "TxLog: truncate clears log" {
    const tmp_path = "/tmp/hexa-test-txlog-truncate";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var log = try txlog.TxLog.init(testing.allocator, tmp_path);
    defer log.deinit();

    try log.open();

    const session_id = [_]u8{1} ** 16;
    try log.write(.detach_start, session_id, "payload");

    // Truncate
    try log.truncate();

    // Reopen and verify empty
    try log.open();
    var entries = try log.readAll(testing.allocator);
    defer entries.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), entries.items.len);
}

// ============================================================================
// Detach Error Handling Tests
// ============================================================================

test "detachSession: allocation failure during name dupe" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    // Create a client with panes
    const fd: std.posix.fd_t = 99;
    const client_id = try ses_state.addClient(fd);

    if (ses_state.getClient(client_id)) |client| {
        client.session_id = [_]u8{1} ** 16;
        client.session_name = try ses_state.allocator.dupe(u8, "test-session");
    }
    defer {
        // Clean up allocated session name
        if (ses_state.getClient(client_id)) |client| {
            if (client.session_name) |name| {
                ses_state.allocator.free(name);
                client.session_name = null;
            }
        }
    }

    // Detach with failing allocator is difficult to test directly since
    // SesState uses page_allocator internally. This test documents the
    // expected behavior: detachSession should return false on allocation
    // failure and leave state unchanged.

    // Verify client exists before detach
    try testing.expect(ses_state.getClient(client_id) != null);

    // Note: Full allocation failure testing would require dependency injection
    // of allocators, which is out of scope for this test suite.
}

// ============================================================================
// Cleanup Tests
// ============================================================================

test "cleanupOrphanedPanes: removes timed-out panes" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    // Create orphaned pane with old timestamp
    const uuid = [_]u8{1} ** 32;
    const pane = state.Pane{
        .uuid = uuid,
        .name = try testing.allocator.dupe(u8, "test-pane"),
        .pod_pid = 1234,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/test"),
        .child_pid = 5678,
        .state = .orphaned,
        .sticky_pwd = null,
        .sticky_key = null,
        .attached_to = null,
        .session_id = null,
        .created_at = 0,
        .orphaned_at = std.time.timestamp() - (25 * 3600), // 25 hours ago
        .allocator = testing.allocator,
    };

    try ses_state.panes.put(uuid, pane);

    // Set timeout to 24 hours
    ses_state.orphan_timeout_hours = 24;

    // Cleanup should remove the pane
    ses_state.cleanupOrphanedPanes();

    try testing.expect(!ses_state.panes.contains(uuid));
}

test "killAllOrphanedPanes: removes all orphaned and sticky panes" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    // Create multiple panes in different states
    const orphaned_uuid = [_]u8{1} ** 32;
    const sticky_uuid = [_]u8{2} ** 32;
    const attached_uuid = [_]u8{3} ** 32;

    const orphaned_pane = state.Pane{
        .uuid = orphaned_uuid,
        .name = try testing.allocator.dupe(u8, "orphaned"),
        .pod_pid = 1234,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/orphaned"),
        .child_pid = 5678,
        .state = .orphaned,
        .sticky_pwd = null,
        .sticky_key = null,
        .attached_to = null,
        .session_id = null,
        .created_at = 0,
        .orphaned_at = std.time.timestamp(),
        .allocator = testing.allocator,
    };

    const sticky_pane = state.Pane{
        .uuid = sticky_uuid,
        .name = try testing.allocator.dupe(u8, "sticky"),
        .pod_pid = 1235,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/sticky"),
        .child_pid = 5679,
        .state = .sticky,
        .sticky_pwd = try testing.allocator.dupe(u8, "/home/test"),
        .sticky_key = 'a',
        .attached_to = null,
        .session_id = null,
        .created_at = 0,
        .orphaned_at = std.time.timestamp(),
        .allocator = testing.allocator,
    };

    const attached_pane = state.Pane{
        .uuid = attached_uuid,
        .name = try testing.allocator.dupe(u8, "attached"),
        .pod_pid = 1236,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/attached"),
        .child_pid = 5680,
        .state = .attached,
        .sticky_pwd = null,
        .sticky_key = null,
        .attached_to = 1,
        .session_id = null,
        .created_at = 0,
        .orphaned_at = null,
        .allocator = testing.allocator,
    };

    try ses_state.panes.put(orphaned_uuid, orphaned_pane);
    try ses_state.panes.put(sticky_uuid, sticky_pane);
    try ses_state.panes.put(attached_uuid, attached_pane);

    // Kill all orphaned panes
    const killed = ses_state.killAllOrphanedPanes();

    try testing.expectEqual(@as(usize, 2), killed);
    try testing.expect(!ses_state.panes.contains(orphaned_uuid));
    try testing.expect(!ses_state.panes.contains(sticky_uuid));
    try testing.expect(ses_state.panes.contains(attached_uuid)); // Should remain
}

// ============================================================================
// Resource Cleanup Tests
// ============================================================================

test "Pane.deinit: cleans up all optional fields" {
    const pane = state.Pane{
        .uuid = [_]u8{0} ** 32,
        .name = try testing.allocator.dupe(u8, "test-pane"),
        .pod_pid = 1234,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/test"),
        .child_pid = 5678,
        .state = .sticky,
        .sticky_pwd = try testing.allocator.dupe(u8, "/home/test"),
        .sticky_key = 'a',
        .sticky_session_name = try testing.allocator.dupe(u8, "alpha"),
        .attached_to = null,
        .session_id = null,
        .created_at = 0,
        .orphaned_at = null,
        .cwd = try testing.allocator.dupe(u8, "/home/user"),
        .fg_process = try testing.allocator.dupe(u8, "bash"),
        .layout_path = try testing.allocator.dupe(u8, "/tmp/layout.json"),
        .last_cmd = try testing.allocator.dupe(u8, "echo hello"),
        .allocator = testing.allocator,
    };

    // This should not leak - verified by test allocator
    var p = pane;
    p.deinit();
}

test "Client.deinit: cleans up all resources" {
    var client = state.Client.init(testing.allocator, 1, 99);

    client.session_name = try testing.allocator.dupe(u8, "test-session");
    client.last_mux_state = try testing.allocator.dupe(u8, "{}");

    try client.appendUuid([_]u8{1} ** 32);
    try client.appendUuid([_]u8{2} ** 32);

    // This should not leak - verified by test allocator
    client.deinit();
}

test "DetachedMuxState.deinit: cleans up all resources" {
    var detached = state.DetachedMuxState{
        .session_id = [_]u8{1} ** 16,
        .session_name = try testing.allocator.dupe(u8, "alpha"),
        .mux_state_json = try testing.allocator.dupe(u8, "{}"),
        .pane_uuids = try testing.allocator.alloc([32]u8, 2),
        .detached_at = std.time.timestamp(),
        .allocator = testing.allocator,
    };

    // This should not leak - verified by test allocator
    detached.deinit();
}

// ============================================================================
// Session Affinity Tests
// ============================================================================

test "findStickyPaneWithAffinity: prefers same session" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const pwd = "/home/test";
    const key: u8 = 'a';

    // Create two sticky panes with same pwd+key, different sessions
    const uuid1 = [_]u8{1} ** 32;
    const uuid2 = [_]u8{2} ** 32;

    const pane1 = state.Pane{
        .uuid = uuid1,
        .name = try testing.allocator.dupe(u8, "pane1"),
        .pod_pid = 1234,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/pane1"),
        .child_pid = 5678,
        .state = .sticky,
        .sticky_pwd = try testing.allocator.dupe(u8, pwd),
        .sticky_key = key,
        .sticky_session_name = try testing.allocator.dupe(u8, "alpha"),
        .attached_to = null,
        .session_id = null,
        .created_at = 0,
        .orphaned_at = std.time.timestamp(),
        .allocator = testing.allocator,
    };

    const pane2 = state.Pane{
        .uuid = uuid2,
        .name = try testing.allocator.dupe(u8, "pane2"),
        .pod_pid = 1235,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/pane2"),
        .child_pid = 5679,
        .state = .sticky,
        .sticky_pwd = try testing.allocator.dupe(u8, pwd),
        .sticky_key = key,
        .sticky_session_name = try testing.allocator.dupe(u8, "beta"),
        .attached_to = null,
        .session_id = null,
        .created_at = 0,
        .orphaned_at = std.time.timestamp(),
        .allocator = testing.allocator,
    };

    try ses_state.panes.put(uuid1, pane1);
    try ses_state.panes.put(uuid2, pane2);

    // Search with affinity for "beta"
    const found = ses_state.findStickyPaneWithAffinity(pwd, key, "beta");
    try testing.expect(found != null);
    if (found) |pane| {
        try testing.expectEqualSlices(u8, &uuid2, &pane.uuid);
    }
}

test "findStickyPaneWithAffinity: fallback when no affinity match" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const pwd = "/home/test";
    const key: u8 = 'a';

    const uuid = [_]u8{1} ** 32;
    const pane = state.Pane{
        .uuid = uuid,
        .name = try testing.allocator.dupe(u8, "pane1"),
        .pod_pid = 1234,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/pane1"),
        .child_pid = 5678,
        .state = .sticky,
        .sticky_pwd = try testing.allocator.dupe(u8, pwd),
        .sticky_key = key,
        .sticky_session_name = try testing.allocator.dupe(u8, "alpha"),
        .attached_to = null,
        .session_id = null,
        .created_at = 0,
        .orphaned_at = std.time.timestamp(),
        .allocator = testing.allocator,
    };

    try ses_state.panes.put(uuid, pane);

    // Search with affinity for "beta" (doesn't match "alpha")
    const found = ses_state.findStickyPaneWithAffinity(pwd, key, "beta");
    try testing.expect(found != null);
    if (found) |p| {
        // Should still find the pane (fallback to any match)
        try testing.expectEqualSlices(u8, &uuid, &p.uuid);
    }
}
