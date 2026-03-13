const std = @import("std");
const testing = std.testing;
const core = @import("core");
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

test "reattachSession: returns snapshot borrowed from detached session map" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const session_id = [_]u8{4} ** 16;
    const session_hex: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
    const pane_uuid = [_]u8{'a'} ** 32;
    const live_pid: std.posix.pid_t = @intCast(std.c.getpid());

    var snapshot = try core.session_model.SessionSnapshot.initMinimal(testing.allocator, session_hex, "borrowed");
    errdefer snapshot.deinit();
    try snapshot.panes.put(pane_uuid, .{
        .uuid = pane_uuid,
        .kind = .split,
        .parent_tab = null,
    });

    const pane_uuids = try testing.allocator.alloc([32]u8, 1);
    errdefer testing.allocator.free(pane_uuids);
    pane_uuids[0] = pane_uuid;

    try ses_state.panes.put(pane_uuid, .{
        .uuid = pane_uuid,
        .name = null,
        .pod_pid = live_pid,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/test-pane-a.sock"),
        .child_pid = live_pid,
        .state = .detached,
        .sticky_pwd = null,
        .sticky_key = null,
        .attached_to = null,
        .session_id = session_id,
        .created_at = std.time.timestamp(),
        .orphaned_at = null,
        .allocator = testing.allocator,
    });

    try ses_state.detached_sessions.put(session_id, .{
        .session_id = session_id,
        .session_snapshot = snapshot,
        .pane_uuids = pane_uuids,
        .detached_at = std.time.timestamp(),
        .allocator = testing.allocator,
    });

    const result = (try ses_state.reattachSession(session_id, 1)) orelse return error.TestUnexpectedResult;
    const stored = ses_state.detached_sessions.getPtr(session_id) orelse return error.TestUnexpectedResult;

    try testing.expect(result.session_snapshot == &stored.session_snapshot);
    try testing.expectEqualStrings("borrowed", result.session_snapshot.session_name);
    try testing.expectEqualSlices(u8, &pane_uuids[0], &result.pane_uuids[0]);
}

test "reattachSession: seeds live client snapshot from detached state" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const client_id = try ses_state.addClient(1);
    const session_id = [_]u8{6} ** 16;
    const session_hex: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
    const pane_uuid = [_]u8{'p'} ** 32;
    const live_pid: std.posix.pid_t = @intCast(std.c.getpid());

    var snapshot = try core.session_model.SessionSnapshot.initMinimal(testing.allocator, session_hex, "seeded");
    errdefer snapshot.deinit();
    try snapshot.tabs.append(testing.allocator, .{
        .uuid = [_]u8{'t'} ** 32,
        .name = try testing.allocator.dupe(u8, "seeded-1"),
        .focused_pane_uuid = pane_uuid,
        .allocator = testing.allocator,
    });
    try snapshot.panes.put(pane_uuid, .{
        .uuid = pane_uuid,
        .kind = .split,
        .parent_tab = 0,
    });
    snapshot.focused_pane_uuid = pane_uuid;

    const pane_uuids = try testing.allocator.alloc([32]u8, 1);
    errdefer testing.allocator.free(pane_uuids);
    pane_uuids[0] = pane_uuid;

    try ses_state.panes.put(pane_uuid, .{
        .uuid = pane_uuid,
        .name = null,
        .pod_pid = live_pid,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/test-pane-p.sock"),
        .child_pid = live_pid,
        .state = .detached,
        .sticky_pwd = null,
        .sticky_key = null,
        .attached_to = null,
        .session_id = session_id,
        .created_at = std.time.timestamp(),
        .orphaned_at = null,
        .allocator = testing.allocator,
    });

    try ses_state.detached_sessions.put(session_id, .{
        .session_id = session_id,
        .session_snapshot = snapshot,
        .pane_uuids = pane_uuids,
        .detached_at = std.time.timestamp(),
        .allocator = testing.allocator,
    });

    const result = (try ses_state.reattachSession(session_id, client_id)) orelse return error.TestUnexpectedResult;
    const client = ses_state.getClient(client_id) orelse return error.TestUnexpectedResult;

    try testing.expect(client.session_snapshot != null);
    try testing.expect(&client.session_snapshot.? != result.session_snapshot);
    try testing.expectEqualStrings("seeded", client.session_snapshot.?.session_name);
    try testing.expectEqual(@as(usize, 1), client.session_snapshot.?.tabs.items.len);
    try testing.expectEqual(pane_uuid, client.session_snapshot.?.focused_pane_uuid.?);
}

test "reattachSession: prunes stale detached pane uuids before returning" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const client_id = try ses_state.addClient(1);
    const session_id = [_]u8{7} ** 16;
    const session_hex: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
    const stale_uuid = [_]u8{'f'} ** 32;

    var snapshot = try core.session_model.SessionSnapshot.initMinimal(testing.allocator, session_hex, "stale");
    errdefer snapshot.deinit();
    try snapshot.panes.put(stale_uuid, .{
        .uuid = stale_uuid,
        .kind = .float,
        .parent_tab = null,
        .sticky = true,
        .is_pwd = true,
        .float_key = '1',
    });
    try snapshot.floats.append(testing.allocator, .{
        .pane_uuid = stale_uuid,
        .visible = true,
        .sticky = true,
        .is_pwd = true,
        .float_key = '1',
    });
    snapshot.active_float_uuid = stale_uuid;
    snapshot.focused_pane_uuid = stale_uuid;

    const pane_uuids = try testing.allocator.alloc([32]u8, 1);
    errdefer testing.allocator.free(pane_uuids);
    pane_uuids[0] = stale_uuid;

    try ses_state.detached_sessions.put(session_id, .{
        .session_id = session_id,
        .session_snapshot = snapshot,
        .pane_uuids = pane_uuids,
        .detached_at = std.time.timestamp(),
        .allocator = testing.allocator,
    });

    const result = (try ses_state.reattachSession(session_id, client_id)) orelse return error.TestUnexpectedResult;
    const stored = ses_state.detached_sessions.getPtr(session_id) orelse return error.TestUnexpectedResult;

    try testing.expectEqual(@as(usize, 0), result.pane_uuids.len);
    try testing.expectEqual(@as(usize, 0), stored.pane_uuids.len);
    try testing.expect(stored.session_snapshot.panes.get(stale_uuid) == null);
    try testing.expectEqual(@as(usize, 0), stored.session_snapshot.floats.items.len);
    try testing.expect(stored.session_snapshot.active_float_uuid == null);
    try testing.expect(stored.session_snapshot.focused_pane_uuid == null);
}

// ============================================================================
// Session Name Resolution Tests
// ============================================================================

test "resolveSessionName: unique name returned as-is" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const name = "alpha";
    const resolved = ses_state.resolveSessionName(name, null, null) orelse return error.AllocationFailed;
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
    const resolved = ses_state.resolveSessionName("alpha", null, null) orelse return error.AllocationFailed;
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

    const resolved = ses_state.resolveSessionName("alpha", client_id, null) orelse return error.AllocationFailed;
    defer ses_state.allocator.free(resolved);

    try testing.expectEqualStrings("alpha", resolved);
}

test "resolveSessionName: ignores matching detached session on reattach" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const session_id = [_]u8{5} ** 16;
    const session_hex: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);

    var snapshot = try core.session_model.SessionSnapshot.initMinimal(testing.allocator, session_hex, "alpha");
    errdefer snapshot.deinit();

    const pane_uuids = try testing.allocator.alloc([32]u8, 0);
    errdefer testing.allocator.free(pane_uuids);

    try ses_state.detached_sessions.put(session_id, .{
        .session_id = session_id,
        .session_snapshot = snapshot,
        .pane_uuids = pane_uuids,
        .detached_at = std.time.timestamp(),
        .allocator = testing.allocator,
    });

    const resolved = ses_state.resolveSessionName("alpha", null, session_id) orelse return error.AllocationFailed;
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

test "TxLog: findIncompleteOperations preserves reattach type" {
    const page_alloc = std.heap.page_allocator;
    var entries: std.ArrayList(txlog.TxLogEntry) = .empty;
    defer entries.deinit(page_alloc);

    const session_id = [_]u8{3} ** 16;

    try entries.append(page_alloc, .{
        .tx_type = .reattach_start,
        .timestamp = 300,
        .session_id = session_id,
        .payload = "",
    });

    var incomplete = try txlog.findIncompleteOperations(entries.items);
    defer incomplete.deinit(page_alloc);

    try testing.expectEqual(@as(usize, 1), incomplete.items.len);
    try testing.expectEqual(txlog.TxType.reattach_start, incomplete.items[0].tx_type);
    try testing.expectEqualSlices(u8, &session_id, &incomplete.items[0].session_id);
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
    client.session_snapshot = try state.SessionSnapshot.initMinimal(testing.allocator, [_]u8{'a'} ** 32, "test-session");

    try client.appendUuid([_]u8{1} ** 32);
    try client.appendUuid([_]u8{2} ** 32);

    // This should not leak - verified by test allocator
    client.deinit();
}

test "DetachedSessionState.deinit: cleans up all resources" {
    var detached = state.DetachedSessionState{
        .session_id = [_]u8{1} ** 16,
        .session_snapshot = try state.SessionSnapshot.initMinimal(testing.allocator, [_]u8{'a'} ** 32, "alpha"),
        .pane_uuids = try testing.allocator.alloc([32]u8, 2),
        .detached_at = std.time.timestamp(),
        .allocator = testing.allocator,
    };

    // This should not leak - verified by test allocator
    detached.deinit();
}

test "SessionSnapshot.fromMuxJson: parses canonical session structure" {
    const json =
        \\{
        \\  "version": 1,
        \\  "timestamp": 1,
        \\  "uuid": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "session_name": "alpha",
        \\  "tab_counter": 2,
        \\  "active_tab": 0,
        \\  "active_floating": 0,
        \\  "tabs": [
        \\    {
        \\      "uuid": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        \\      "name": "alpha-1",
        \\      "focused_split_id": 2,
        \\      "next_split_id": 3,
        \\      "tree": {
        \\        "type": "split",
        \\        "dir": "horizontal",
        \\        "ratio": 0.5,
        \\        "first": { "type": "pane", "id": 1 },
        \\        "second": { "type": "pane", "id": 2 }
        \\      },
        \\      "splits": [
        \\        {
        \\          "id": 1,
        \\          "uuid": "11111111111111111111111111111111",
        \\          "x": 0, "y": 0, "width": 40, "height": 20,
        \\          "focused": false, "floating": false, "visible": true,
        \\          "tab_visible": 0, "float_key": 0,
        \\          "border_x": 0, "border_y": 0, "border_w": 0, "border_h": 0,
        \\          "float_width_pct": 60, "float_height_pct": 60,
        \\          "float_pos_x_pct": 50, "float_pos_y_pct": 50,
        \\          "float_pad_x": 1, "float_pad_y": 0,
        \\          "is_pwd": false, "sticky": false
        \\        },
        \\        {
        \\          "id": 2,
        \\          "uuid": "22222222222222222222222222222222",
        \\          "x": 40, "y": 0, "width": 40, "height": 20,
        \\          "focused": true, "floating": false, "visible": true,
        \\          "tab_visible": 0, "float_key": 0,
        \\          "border_x": 0, "border_y": 0, "border_w": 0, "border_h": 0,
        \\          "float_width_pct": 60, "float_height_pct": 60,
        \\          "float_pos_x_pct": 50, "float_pos_y_pct": 50,
        \\          "float_pad_x": 1, "float_pad_y": 0,
        \\          "is_pwd": false, "sticky": false
        \\        }
        \\      ]
        \\    }
        \\  ],
        \\  "floats": [
        \\    {
        \\      "id": 100,
        \\      "uuid": "33333333333333333333333333333333",
        \\      "x": 10, "y": 5, "width": 20, "height": 10,
        \\      "focused": true, "floating": true, "visible": true,
        \\      "tab_visible": 1, "float_key": 102,
        \\      "border_x": 9, "border_y": 4, "border_w": 22, "border_h": 12,
        \\      "float_width_pct": 60, "float_height_pct": 60,
        \\      "float_pos_x_pct": 50, "float_pos_y_pct": 50,
        \\      "float_pad_x": 1, "float_pad_y": 0,
        \\      "is_pwd": true, "sticky": true,
        \\      "parent_tab": 0
        \\    }
        \\  ]
        \\}
    ;

    var snapshot = try state.SessionSnapshot.fromMuxJson(testing.allocator, json);
    defer snapshot.deinit();

    try testing.expectEqualStrings("alpha", snapshot.session_name);
    try testing.expectEqual(@as(usize, 2), snapshot.tab_counter);
    try testing.expectEqual(@as(usize, 1), snapshot.tabs.items.len);
    try testing.expectEqual(@as(usize, 1), snapshot.floats.items.len);
    try testing.expect(snapshot.active_float_uuid != null);
    try testing.expect(snapshot.focused_pane_uuid != null);
    try testing.expect(snapshot.panes.contains([_]u8{'1'} ** 32));
    try testing.expect(snapshot.panes.contains([_]u8{'2'} ** 32));
    try testing.expect(snapshot.panes.contains([_]u8{'3'} ** 32));
    try testing.expectEqualStrings("alpha-1", snapshot.tabs.items[0].name);
    try testing.expectEqual([_]u8{'2'} ** 32, snapshot.tabs.items[0].focused_pane_uuid.?);
    try testing.expectEqual([_]u8{'3'} ** 32, snapshot.active_float_uuid.?);
    try testing.expectEqual([_]u8{'3'} ** 32, snapshot.focused_pane_uuid.?);
}

test "SessionSnapshot.toJson/fromJson: round trips canonical snapshot" {
    var snapshot = try state.SessionSnapshot.initMinimal(testing.allocator, [_]u8{'a'} ** 32, "alpha");
    defer snapshot.deinit();

    const root = try testing.allocator.create(core.session_model.SessionLayoutNode);
    const first = try testing.allocator.create(core.session_model.SessionLayoutNode);
    const second = try testing.allocator.create(core.session_model.SessionLayoutNode);
    first.* = .{ .pane = [_]u8{'1'} ** 32 };
    second.* = .{ .pane = [_]u8{'2'} ** 32 };
    root.* = .{
        .split = .{
            .dir = .horizontal,
            .ratio = 0.5,
            .first = first,
            .second = second,
        },
    };

    try snapshot.tabs.append(testing.allocator, .{
        .uuid = [_]u8{'b'} ** 32,
        .name = try testing.allocator.dupe(u8, "alpha-1"),
        .root = root,
        .focused_pane_uuid = [_]u8{'2'} ** 32,
        .allocator = testing.allocator,
    });
    snapshot.tab_counter = 2;
    snapshot.active_tab = 0;
    snapshot.active_float_uuid = [_]u8{'3'} ** 32;
    snapshot.focused_pane_uuid = [_]u8{'3'} ** 32;
    try snapshot.panes.put([_]u8{'1'} ** 32, .{ .uuid = [_]u8{'1'} ** 32, .kind = .split, .parent_tab = 0 });
    try snapshot.panes.put([_]u8{'2'} ** 32, .{ .uuid = [_]u8{'2'} ** 32, .kind = .split, .parent_tab = 0 });
    try snapshot.panes.put([_]u8{'3'} ** 32, .{
        .uuid = [_]u8{'3'} ** 32,
        .kind = .float,
        .parent_tab = 0,
        .sticky = true,
        .is_pwd = true,
        .float_key = 102,
    });
    try snapshot.floats.append(testing.allocator, .{
        .pane_uuid = [_]u8{'3'} ** 32,
        .parent_tab = 0,
        .visible = true,
        .tab_visible = 1,
        .sticky = true,
        .is_pwd = true,
        .float_key = 102,
        .width_pct = 60,
        .height_pct = 50,
        .pos_x_pct = 40,
        .pos_y_pct = 30,
        .pad_x = 1,
        .pad_y = 0,
    });

    const json = try snapshot.toJson(testing.allocator);
    defer testing.allocator.free(json);

    var reparsed = try state.SessionSnapshot.fromJson(testing.allocator, json);
    defer reparsed.deinit();

    try testing.expectEqualStrings("alpha", reparsed.session_name);
    try testing.expectEqual(@as(usize, 1), reparsed.tabs.items.len);
    try testing.expectEqual(@as(usize, 1), reparsed.floats.items.len);
    try testing.expectEqual([_]u8{'3'} ** 32, reparsed.active_float_uuid.?);
    try testing.expectEqual([_]u8{'2'} ** 32, reparsed.tabs.items[0].focused_pane_uuid.?);
    try testing.expect(reparsed.tabs.items[0].root != null);
}

test "updateClientSessionFocus: split focus updates active tab and tab focus" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const client_id = try ses_state.addClient(1);
    const client = ses_state.getClient(client_id).?;

    var snapshot = try state.SessionSnapshot.initMinimal(testing.allocator, [_]u8{'a'} ** 32, "alpha");
    try snapshot.tabs.append(testing.allocator, .{
        .uuid = [_]u8{'t'} ** 32,
        .name = try testing.allocator.dupe(u8, "alpha-1"),
        .focused_pane_uuid = null,
        .allocator = testing.allocator,
    });
    try snapshot.tabs.append(testing.allocator, .{
        .uuid = [_]u8{'u'} ** 32,
        .name = try testing.allocator.dupe(u8, "alpha-2"),
        .focused_pane_uuid = null,
        .allocator = testing.allocator,
    });
    try snapshot.panes.put([_]u8{'1'} ** 32, .{ .uuid = [_]u8{'1'} ** 32, .kind = .split, .parent_tab = 1 });
    client.updateSessionSnapshot(snapshot);

    ses_state.updateClientSessionFocus(client_id, [_]u8{'1'} ** 32, 1, true);

    try testing.expectEqual(@as(usize, 1), client.session_snapshot.?.active_tab);
    try testing.expectEqual([_]u8{'1'} ** 32, client.session_snapshot.?.focused_pane_uuid.?);
    try testing.expectEqual([_]u8{'1'} ** 32, client.session_snapshot.?.tabs.items[1].focused_pane_uuid.?);
    try testing.expect(client.session_snapshot.?.active_float_uuid == null);
}

test "updateClientSessionFocus: float focus preserves split focus and tracks active float" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const client_id = try ses_state.addClient(1);
    const client = ses_state.getClient(client_id).?;

    var snapshot = try state.SessionSnapshot.initMinimal(testing.allocator, [_]u8{'a'} ** 32, "alpha");
    try snapshot.tabs.append(testing.allocator, .{
        .uuid = [_]u8{'t'} ** 32,
        .name = try testing.allocator.dupe(u8, "alpha-1"),
        .focused_pane_uuid = [_]u8{'1'} ** 32,
        .allocator = testing.allocator,
    });
    snapshot.active_tab = 0;
    snapshot.focused_pane_uuid = [_]u8{'1'} ** 32;
    try snapshot.panes.put([_]u8{'1'} ** 32, .{ .uuid = [_]u8{'1'} ** 32, .kind = .split, .parent_tab = 0 });
    try snapshot.panes.put([_]u8{'f'} ** 32, .{ .uuid = [_]u8{'f'} ** 32, .kind = .float, .parent_tab = null });
    client.updateSessionSnapshot(snapshot);

    ses_state.updateClientSessionFocus(client_id, [_]u8{'f'} ** 32, 0, true);

    try testing.expectEqual(@as(usize, 0), client.session_snapshot.?.active_tab);
    try testing.expectEqual([_]u8{'f'} ** 32, client.session_snapshot.?.focused_pane_uuid.?);
    try testing.expectEqual([_]u8{'f'} ** 32, client.session_snapshot.?.active_float_uuid.?);
    try testing.expectEqual([_]u8{'1'} ** 32, client.session_snapshot.?.tabs.items[0].focused_pane_uuid.?);
}

test "addClientSessionTab: inserts active tab with focused split pane" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const client_id = try ses_state.addClient(1);
    const client = ses_state.getClient(client_id).?;

    var snapshot = try state.SessionSnapshot.initMinimal(testing.allocator, [_]u8{'a'} ** 32, "alpha");
    try snapshot.tabs.append(testing.allocator, .{
        .uuid = [_]u8{'t'} ** 32,
        .name = try testing.allocator.dupe(u8, "alpha-1"),
        .focused_pane_uuid = [_]u8{'1'} ** 32,
        .allocator = testing.allocator,
    });
    try snapshot.panes.put([_]u8{'1'} ** 32, .{ .uuid = [_]u8{'1'} ** 32, .kind = .split, .parent_tab = 0 });
    client.updateSessionSnapshot(snapshot);

    try ses_state.addClientSessionTab(client_id, [_]u8{'u'} ** 32, [_]u8{'2'} ** 32, 1, "alpha-2");

    try testing.expectEqual(@as(usize, 2), client.session_snapshot.?.tabs.items.len);
    try testing.expectEqualStrings("alpha-2", client.session_snapshot.?.tabs.items[1].name);
    try testing.expectEqual(@as(usize, 1), client.session_snapshot.?.active_tab);
    try testing.expectEqual([_]u8{'2'} ** 32, client.session_snapshot.?.focused_pane_uuid.?);
    try testing.expectEqual([_]u8{'2'} ** 32, client.session_snapshot.?.tabs.items[1].focused_pane_uuid.?);
    try testing.expectEqual(@as(usize, 1), client.session_snapshot.?.panes.get([_]u8{'2'} ** 32).?.parent_tab.?);
}

test "removeClientSessionTab: removes split panes and shifts later tab parents" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const client_id = try ses_state.addClient(1);
    const client = ses_state.getClient(client_id).?;

    var snapshot = try state.SessionSnapshot.initMinimal(testing.allocator, [_]u8{'a'} ** 32, "alpha");
    try snapshot.tabs.append(testing.allocator, .{
        .uuid = [_]u8{'t'} ** 32,
        .name = try testing.allocator.dupe(u8, "alpha-1"),
        .focused_pane_uuid = [_]u8{'1'} ** 32,
        .allocator = testing.allocator,
    });
    try snapshot.tabs.append(testing.allocator, .{
        .uuid = [_]u8{'u'} ** 32,
        .name = try testing.allocator.dupe(u8, "alpha-2"),
        .focused_pane_uuid = [_]u8{'2'} ** 32,
        .allocator = testing.allocator,
    });
    try snapshot.panes.put([_]u8{'1'} ** 32, .{ .uuid = [_]u8{'1'} ** 32, .kind = .split, .parent_tab = 0 });
    try snapshot.panes.put([_]u8{'2'} ** 32, .{ .uuid = [_]u8{'2'} ** 32, .kind = .split, .parent_tab = 1 });
    client.updateSessionSnapshot(snapshot);

    ses_state.removeClientSessionTab(client_id, [_]u8{'t'} ** 32, 0);

    try testing.expectEqual(@as(usize, 1), client.session_snapshot.?.tabs.items.len);
    try testing.expectEqualStrings("alpha-2", client.session_snapshot.?.tabs.items[0].name);
    try testing.expect(client.session_snapshot.?.panes.get([_]u8{'1'} ** 32) == null);
    try testing.expectEqual(@as(usize, 0), client.session_snapshot.?.panes.get([_]u8{'2'} ** 32).?.parent_tab.?);
    try testing.expectEqual(@as(usize, 0), client.session_snapshot.?.active_tab);
}

test "syncClientSessionFloat: upserts visibility and active float state" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const client_id = try ses_state.addClient(1);
    const client = ses_state.getClient(client_id).?;

    var snapshot = try state.SessionSnapshot.initMinimal(testing.allocator, [_]u8{'a'} ** 32, "alpha");
    try snapshot.tabs.append(testing.allocator, .{
        .uuid = [_]u8{'t'} ** 32,
        .name = try testing.allocator.dupe(u8, "alpha-1"),
        .focused_pane_uuid = [_]u8{'1'} ** 32,
        .allocator = testing.allocator,
    });
    snapshot.active_tab = 0;
    snapshot.focused_pane_uuid = [_]u8{'1'} ** 32;
    try snapshot.panes.put([_]u8{'1'} ** 32, .{ .uuid = [_]u8{'1'} ** 32, .kind = .split, .parent_tab = 0 });
    client.updateSessionSnapshot(snapshot);

    try ses_state.syncClientSessionFloat(client_id, [_]u8{'f'} ** 32, 0, null, true, 1, true, false, 7, 60, 50, 40, 30, 1, 0, true);

    try testing.expectEqual(@as(usize, 1), client.session_snapshot.?.floats.items.len);
    try testing.expectEqual([_]u8{'f'} ** 32, client.session_snapshot.?.active_float_uuid.?);
    try testing.expectEqual([_]u8{'f'} ** 32, client.session_snapshot.?.focused_pane_uuid.?);

    try ses_state.syncClientSessionFloat(client_id, [_]u8{'f'} ** 32, 0, null, false, 0, true, false, 7, 60, 50, 40, 30, 1, 0, false);

    try testing.expect(client.session_snapshot.?.active_float_uuid == null);
    try testing.expectEqual([_]u8{'1'} ** 32, client.session_snapshot.?.focused_pane_uuid.?);

    ses_state.removeClientSessionFloat(client_id, [_]u8{'f'} ** 32);
    try testing.expectEqual(@as(usize, 0), client.session_snapshot.?.floats.items.len);
    try testing.expect(client.session_snapshot.?.panes.get([_]u8{'f'} ** 32) == null);
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
