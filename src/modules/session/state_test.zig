const std = @import("std");
const testing = std.testing;
const core = @import("core");
const state = @import("state.zig");
const txlog = @import("txlog.zig");
const persist = @import("persist.zig");

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
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *FailingAllocator = @ptrCast(@alignCast(ctx));
        self.alloc_count += 1;
        if (self.alloc_count > self.fail_after) {
            return null; // Simulate allocation failure
        }
        return self.parent_allocator.rawAlloc(len, ptr_align, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *FailingAllocator = @ptrCast(@alignCast(ctx));
        return self.parent_allocator.rawResize(buf, buf_align, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *FailingAllocator = @ptrCast(@alignCast(ctx));
        return self.parent_allocator.rawRemap(buf, buf_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
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
    if (ses_state.locks.session_locks.getPtr(session_id)) |lock| {
        lock.locked_at = std.time.timestamp() - 31; // 31 seconds ago (timeout is 30s)
    }

    // Should acquire successfully (old lock auto-removed)
    try ses_state.acquireSessionLock(session_id, client_id, .attaching);
    try testing.expect(ses_state.isSessionLocked(session_id));

    ses_state.releaseSessionLock(session_id);
}

test "SessionLock: releaseClient clears locks owned by disconnected client" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const first_session = [_]u8{1} ** 16;
    const second_session = [_]u8{2} ** 16;

    try ses_state.acquireSessionLock(first_session, 10, .attaching);
    try ses_state.acquireSessionLock(second_session, 20, .attaching);

    ses_state.releaseClientLocks(10);

    try testing.expect(!ses_state.isSessionLocked(first_session));
    try testing.expect(ses_state.isSessionLocked(second_session));

    ses_state.releaseSessionLock(second_session);
}

test "SessionProjection: active tab survives before first attached snapshot" {
    var projection = try core.SessionProjection.init(testing.allocator, [_]u8{1} ** 32, "active-test", "");
    defer projection.deinit();

    projection.setActiveTab(1);
    try testing.expectEqual(@as(usize, 1), projection.activeTab(2));
    try testing.expectEqual(@as(usize, 0), projection.activeTab(1));
}

test "SessionProjection: failed metadata replacement preserves old owned strings" {
    var projection = try core.SessionProjection.init(testing.allocator, [_]u8{1} ** 32, "meta-test", "");
    defer projection.deinit();

    const pane_uuid = [_]u8{'m'} ** 32;
    projection.setPaneShell(pane_uuid, "old-cmd", "old-cwd", null, null, null);
    projection.setPaneProc(pane_uuid, "old-proc", 123);
    projection.setPaneNameOwned(pane_uuid, try testing.allocator.dupe(u8, "old-name"));

    var failing = FailingAllocator.init(testing.allocator, 0);
    const original_allocator = projection.allocator;
    projection.allocator = failing.allocator();
    projection.setPaneShell(pane_uuid, "new-cmd", "new-cwd", null, null, null);
    projection.setPaneProc(pane_uuid, "new-proc", 456);
    projection.setPaneNameOwned(pane_uuid, try testing.allocator.dupe(u8, "new-name"));
    projection.allocator = original_allocator;

    const shell = projection.getPaneShell(pane_uuid) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("old-cmd", shell.cmd orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings("old-cwd", shell.cwd orelse return error.TestUnexpectedResult);

    const proc = projection.getPaneProc(pane_uuid) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("old-proc", proc.name orelse return error.TestUnexpectedResult);
    try testing.expectEqual(@as(?i32, 123), proc.pid);
    try testing.expectEqualStrings("new-name", projection.paneName(pane_uuid) orelse return error.TestUnexpectedResult);
}

test "SessionProjection: failed tab focus memory updates are transactional" {
    var projection = try core.SessionProjection.init(testing.allocator, [_]u8{2} ** 32, "focus-test", "");
    defer projection.deinit();

    try projection.resetTabFocusMemory(1);
    try testing.expectEqual(@as(usize, 1), projection.tab_last_floating_uuid.items.len);
    try testing.expectEqual(@as(usize, 1), projection.tab_last_focus_kind.items.len);

    projection.tab_last_floating_uuid.deinit(testing.allocator);
    projection.tab_last_focus_kind.deinit(testing.allocator);
    projection.tab_last_floating_uuid = .empty;
    projection.tab_last_focus_kind = .empty;

    var failing = FailingAllocator.init(testing.allocator, 1);
    const original_allocator = projection.allocator;
    projection.allocator = failing.allocator();
    try testing.expectError(error.OutOfMemory, projection.appendTabFocusMemory());
    projection.allocator = original_allocator;

    try testing.expectEqual(@as(usize, 0), projection.tab_last_floating_uuid.items.len);
    try testing.expectEqual(@as(usize, 0), projection.tab_last_focus_kind.items.len);

    try projection.resetTabFocusMemory(1);

    failing = FailingAllocator.init(testing.allocator, 0);
    projection.allocator = failing.allocator();
    try testing.expectError(error.OutOfMemory, projection.resetTabFocusMemory(2));
    projection.allocator = original_allocator;

    try testing.expectEqual(@as(usize, 1), projection.tab_last_floating_uuid.items.len);
    try testing.expectEqual(@as(usize, 1), projection.tab_last_focus_kind.items.len);
}

test "SessionProjection: failed snapshot replacement preserves old projection" {
    var projection = try core.SessionProjection.init(testing.allocator, [_]u8{3} ** 32, "initial", "");
    defer projection.deinit();

    var old_snapshot = try core.session_model.SessionSnapshot.initMinimal(testing.allocator, [_]u8{'o'} ** 32, "old");
    try old_snapshot.tabs.append(testing.allocator, .{
        .uuid = [_]u8{'t'} ** 32,
        .name = try testing.allocator.dupe(u8, "old-tab"),
        .allocator = testing.allocator,
    });
    try projection.replaceAttachedSnapshotOwned(old_snapshot);

    var new_snapshot = try core.session_model.SessionSnapshot.initMinimal(testing.allocator, [_]u8{'n'} ** 32, "new");
    defer new_snapshot.deinit();
    try new_snapshot.tabs.append(testing.allocator, .{
        .uuid = [_]u8{'u'} ** 32,
        .name = try testing.allocator.dupe(u8, "new-tab"),
        .allocator = testing.allocator,
    });

    var failing = FailingAllocator.init(testing.allocator, 1);
    const original_allocator = projection.allocator;
    projection.allocator = failing.allocator();
    try testing.expectError(error.OutOfMemory, projection.replaceAttachedSnapshotOwned(new_snapshot));
    projection.allocator = original_allocator;

    const snapshot = projection.attachedSnapshot() orelse return error.TestUnexpectedResult;
    try testing.expectEqual([_]u8{'o'} ** 32, snapshot.uuid);
    try testing.expectEqualStrings("old", snapshot.session_name);
    try testing.expectEqualStrings("old", projection.sessionName());
    try testing.expectEqual(@as(usize, 1), projection.tabs.items.len);
    try testing.expectEqualStrings("old-tab", projection.tabs.items[0].name_owned);
    try testing.expectEqual(@as(usize, 1), projection.tab_last_floating_uuid.items.len);
    try testing.expectEqual(@as(usize, 1), projection.tab_last_focus_kind.items.len);
}

test "SessionProjection: snapshot replacement preserves per-tab float focus memory" {
    var projection = try core.SessionProjection.init(testing.allocator, [_]u8{4} ** 32, "focus-memory", "");
    defer projection.deinit();

    const tab_a = [_]u8{'a'} ** 32;
    const tab_b = [_]u8{'b'} ** 32;
    const split_a = [_]u8{'1'} ** 32;
    const split_b = [_]u8{'2'} ** 32;
    const float_a = [_]u8{'f'} ** 32;
    const float_b = [_]u8{'g'} ** 32;

    var old_snapshot = try core.session_model.SessionSnapshot.initMinimal(testing.allocator, [_]u8{'o'} ** 32, "old");
    try old_snapshot.tabs.append(testing.allocator, .{
        .uuid = tab_a,
        .name = try testing.allocator.dupe(u8, "a"),
        .focused_pane_uuid = split_a,
        .allocator = testing.allocator,
    });
    try old_snapshot.tabs.append(testing.allocator, .{
        .uuid = tab_b,
        .name = try testing.allocator.dupe(u8, "b"),
        .focused_pane_uuid = split_b,
        .allocator = testing.allocator,
    });
    try old_snapshot.panes.put(split_a, .{ .uuid = split_a, .kind = .split, .parent_tab = 0 });
    try old_snapshot.panes.put(split_b, .{ .uuid = split_b, .kind = .split, .parent_tab = 1 });
    try old_snapshot.panes.put(float_a, .{ .uuid = float_a, .kind = .float, .parent_tab = null });
    try old_snapshot.floats.append(testing.allocator, .{ .pane_uuid = float_a, .tab_visible = 1 });
    old_snapshot.active_tab = 0;
    old_snapshot.active_float_uuid = float_a;
    old_snapshot.focused_pane_uuid = float_a;
    try projection.replaceAttachedSnapshotOwned(old_snapshot);
    projection.rememberFloatingFocus(0, float_a);

    var new_snapshot = try core.session_model.SessionSnapshot.initMinimal(testing.allocator, [_]u8{'n'} ** 32, "new");
    try new_snapshot.tabs.append(testing.allocator, .{
        .uuid = tab_a,
        .name = try testing.allocator.dupe(u8, "a"),
        .focused_pane_uuid = split_a,
        .allocator = testing.allocator,
    });
    try new_snapshot.tabs.append(testing.allocator, .{
        .uuid = tab_b,
        .name = try testing.allocator.dupe(u8, "b"),
        .focused_pane_uuid = split_b,
        .allocator = testing.allocator,
    });
    try new_snapshot.panes.put(split_a, .{ .uuid = split_a, .kind = .split, .parent_tab = 0 });
    try new_snapshot.panes.put(split_b, .{ .uuid = split_b, .kind = .split, .parent_tab = 1 });
    try new_snapshot.panes.put(float_a, .{ .uuid = float_a, .kind = .float, .parent_tab = null });
    try new_snapshot.panes.put(float_b, .{ .uuid = float_b, .kind = .float, .parent_tab = null });
    try new_snapshot.floats.append(testing.allocator, .{ .pane_uuid = float_a, .tab_visible = 1 });
    try new_snapshot.floats.append(testing.allocator, .{ .pane_uuid = float_b, .tab_visible = 2 });
    new_snapshot.active_tab = 1;
    new_snapshot.active_float_uuid = float_b;
    new_snapshot.focused_pane_uuid = float_b;

    try projection.replaceAttachedSnapshotOwned(new_snapshot);

    try testing.expectEqual(core.SessionProjectionTabFocusKind.float, projection.lastFocusKind(0).?);
    try testing.expectEqual(float_a, projection.lastFloatingUuid(0).?);
    try testing.expectEqual(core.SessionProjectionTabFocusKind.float, projection.lastFocusKind(1).?);
    try testing.expectEqual(float_b, projection.lastFloatingUuid(1).?);
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

    try ses_state.store.panes.put(pane_uuid, .{
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

    try ses_state.store.detached_sessions.put(session_id, .{
        .session_id = session_id,
        .session_snapshot = snapshot,
        .pane_uuids = pane_uuids,
        .detached_at = std.time.timestamp(),
        .allocator = testing.allocator,
    });

    const result = (try ses_state.reattachSession(session_id, 1)) orelse return error.TestUnexpectedResult;
    const stored = ses_state.store.detached_sessions.getPtr(session_id) orelse return error.TestUnexpectedResult;

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

    try ses_state.store.panes.put(pane_uuid, .{
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

    try ses_state.store.detached_sessions.put(session_id, .{
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
    try testing.expectEqual(session_id, client.pending_reattach_session_id.?);
}

test "cancelPendingReattach: restores adopted panes without replacing detached snapshot" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const client_id = try ses_state.addClient(1);
    const session_id = [_]u8{8} ** 16;
    const temp_session_id = [_]u8{9} ** 16;
    const session_hex: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
    const pane_a = [_]u8{'a'} ** 32;
    const pane_b = [_]u8{'b'} ** 32;
    const live_pid: std.posix.pid_t = @intCast(std.c.getpid());

    if (ses_state.getClient(client_id)) |client| {
        client.session_id = temp_session_id;
    }

    var snapshot = try core.session_model.SessionSnapshot.initMinimal(testing.allocator, session_hex, "restore");
    errdefer snapshot.deinit();
    try snapshot.panes.put(pane_a, .{ .uuid = pane_a, .kind = .split, .parent_tab = null });
    try snapshot.panes.put(pane_b, .{ .uuid = pane_b, .kind = .split, .parent_tab = null });

    const pane_uuids = try testing.allocator.alloc([32]u8, 2);
    errdefer testing.allocator.free(pane_uuids);
    pane_uuids[0] = pane_a;
    pane_uuids[1] = pane_b;

    try ses_state.store.panes.put(pane_a, .{
        .uuid = pane_a,
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
    try ses_state.store.panes.put(pane_b, .{
        .uuid = pane_b,
        .name = null,
        .pod_pid = live_pid,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/test-pane-b.sock"),
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

    try ses_state.store.detached_sessions.put(session_id, .{
        .session_id = session_id,
        .session_snapshot = snapshot,
        .pane_uuids = pane_uuids,
        .detached_at = std.time.timestamp(),
        .allocator = testing.allocator,
    });

    _ = (try ses_state.reattachSession(session_id, client_id)) orelse return error.TestUnexpectedResult;
    _ = try ses_state.attachPane(pane_a, client_id);

    try testing.expect(ses_state.cancelPendingReattach(session_id, client_id));

    const detached = ses_state.store.detached_sessions.getPtr(session_id) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), detached.pane_uuids.len);
    try testing.expect(detached.session_snapshot.panes.contains(pane_a));
    try testing.expect(detached.session_snapshot.panes.contains(pane_b));

    const restored_a = ses_state.store.panes.get(pane_a) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(state.PaneState.detached, restored_a.state);
    try testing.expect(restored_a.attached_to == null);
    try testing.expectEqual(session_id, restored_a.session_id.?);

    const restored_b = ses_state.store.panes.get(pane_b) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(state.PaneState.detached, restored_b.state);
    try testing.expect(restored_b.attached_to == null);
    try testing.expectEqual(session_id, restored_b.session_id.?);

    const client = ses_state.getClient(client_id) orelse return error.TestUnexpectedResult;
    try testing.expect(client.pending_reattach_session_id == null);
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

    try ses_state.store.detached_sessions.put(session_id, .{
        .session_id = session_id,
        .session_snapshot = snapshot,
        .pane_uuids = pane_uuids,
        .detached_at = std.time.timestamp(),
        .allocator = testing.allocator,
    });

    const result = (try ses_state.reattachSession(session_id, client_id)) orelse return error.TestUnexpectedResult;
    const stored = ses_state.store.detached_sessions.getPtr(session_id) orelse return error.TestUnexpectedResult;

    try testing.expectEqual(@as(usize, 0), result.pane_uuids.len);
    try testing.expectEqual(@as(usize, 0), stored.pane_uuids.len);
    try testing.expect(stored.session_snapshot.panes.get(stale_uuid) == null);
    try testing.expectEqual(@as(usize, 0), stored.session_snapshot.floats.items.len);
    try testing.expect(stored.session_snapshot.active_float_uuid == null);
    try testing.expect(stored.session_snapshot.focused_pane_uuid == null);
}

test "detach to reattach to adopt preserves pane ownership and snapshot" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const original_client_id = try ses_state.addClient(99);
    const session_id = [_]u8{8} ** 16;
    const session_hex: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
    const pane_uuid = [_]u8{'r'} ** 32;
    const tab_uuid = [_]u8{'t'} ** 32;
    const live_pid: std.posix.pid_t = @intCast(std.c.getpid());

    if (ses_state.getClient(original_client_id)) |client| {
        client.session_id = session_id;
        client.session_name = try ses_state.allocator.dupe(u8, "roundtrip");
        client.session_snapshot = try state.SessionSnapshot.initMinimal(ses_state.allocator, session_hex, "roundtrip");
        try client.session_snapshot.?.tabs.append(ses_state.allocator, .{
            .uuid = tab_uuid,
            .name = try ses_state.allocator.dupe(u8, "main"),
            .focused_pane_uuid = pane_uuid,
            .allocator = ses_state.allocator,
        });
        try client.session_snapshot.?.panes.put(pane_uuid, .{ .uuid = pane_uuid, .kind = .split, .parent_tab = 0 });
        client.session_snapshot.?.focused_pane_uuid = pane_uuid;
        try client.appendUuid(pane_uuid);
    }

    try ses_state.store.panes.put(pane_uuid, .{
        .uuid = pane_uuid,
        .pod_pid = live_pid,
        .pod_socket_path = try ses_state.allocator.dupe(u8, "/tmp/hexe-pane-reattach-roundtrip"),
        .child_pid = live_pid,
        .state = .attached,
        .sticky_pwd = null,
        .sticky_key = null,
        .attached_to = original_client_id,
        .session_id = null,
        .created_at = 0,
        .orphaned_at = null,
        .allocator = ses_state.allocator,
    });

    try testing.expect(ses_state.detachSession(original_client_id, session_id, "roundtrip"));
    try testing.expect(ses_state.getClient(original_client_id) == null);

    const detached = ses_state.store.detached_sessions.getPtr(session_id) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), detached.pane_uuids.len);
    try testing.expectEqual(pane_uuid, detached.pane_uuids[0]);

    const detached_pane = ses_state.store.panes.get(pane_uuid) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(state.PaneState.detached, detached_pane.state);
    try testing.expect(detached_pane.attached_to == null);
    try testing.expectEqual(session_id, detached_pane.session_id.?);

    const reattach_client_id = try ses_state.addClient(100);
    const result = (try ses_state.reattachSession(session_id, reattach_client_id)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), result.pane_uuids.len);
    try testing.expectEqual(pane_uuid, result.pane_uuids[0]);

    const reattach_client = ses_state.getClient(reattach_client_id) orelse return error.TestUnexpectedResult;
    const snapshot = reattach_client.session_snapshot orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("roundtrip", snapshot.session_name);
    try testing.expect(snapshot.panes.get(pane_uuid) != null);
    try testing.expectEqual(pane_uuid, snapshot.focused_pane_uuid.?);

    const adopted = try ses_state.attachPane(pane_uuid, reattach_client_id);
    try testing.expectEqual(state.PaneState.attached, adopted.state);
    try testing.expectEqual(reattach_client_id, adopted.attached_to.?);
    try testing.expect(ses_state.paneAttachedToClient(pane_uuid, reattach_client_id));

    ses_state.removeDetachedSession(session_id);
    try testing.expect(ses_state.store.detached_sessions.get(session_id) == null);
    const committed_pane = ses_state.store.panes.get(pane_uuid) orelse return error.TestUnexpectedResult;
    try testing.expect(committed_pane.session_id == null);
    try testing.expectEqual(state.PaneState.attached, committed_pane.state);
    try testing.expectEqual(reattach_client_id, committed_pane.attached_to.?);
}

// ============================================================================
// Session Name Resolution Tests
// ============================================================================

test "resolveSessionName: unique name returned as-is" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const name = "alpha";
    const resolved = try ses_state.resolveSessionName(name, null, null);
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
    const resolved = try ses_state.resolveSessionName("alpha", null, null);
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

    const resolved = try ses_state.resolveSessionName("alpha", client_id, null);
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

    try ses_state.store.detached_sessions.put(session_id, .{
        .session_id = session_id,
        .session_snapshot = snapshot,
        .pane_uuids = pane_uuids,
        .detached_at = std.time.timestamp(),
        .allocator = testing.allocator,
    });

    const resolved = try ses_state.resolveSessionName("alpha", null, session_id);
    defer ses_state.allocator.free(resolved);

    try testing.expectEqualStrings("alpha", resolved);
}

// ============================================================================
// Transaction Log Tests
// ============================================================================

test "TxLog: write and read entries" {
    const tmp_path = "/tmp/hexa-test-txlog";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var log = txlog.TxLog.init(testing.allocator, tmp_path);
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

test "TxLog: readAll stops cleanly on truncated trailing entry" {
    const tmp_path = "/tmp/hexe-test-txlog-truncated";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var log = txlog.TxLog.init(testing.allocator, tmp_path);
    defer log.deinit();
    try log.open();

    const session_id = [_]u8{7} ** 16;
    try log.write(.detach_start, session_id, "ok");

    // Append a partial entry: write a header claiming 100-byte payload but
    // only provide 10 bytes. readAll must skip the partial record without
    // leaking memory or treating the corruption as fatal.
    const partial: txlog.TxEntry = .{
        .tx_type = .detach_commit,
        .timestamp = 0,
        .session_id = session_id,
        .payload_len = 100,
    };
    const fd = log.log_fd.?;
    _ = try std.posix.write(fd, std.mem.asBytes(&partial));
    var junk: [10]u8 = [_]u8{'x'} ** 10;
    _ = try std.posix.write(fd, &junk);

    var entries = try log.readAll(testing.allocator);
    defer {
        for (entries.items) |*e| {
            testing.allocator.free(e.payload);
        }
        entries.deinit(testing.allocator);
    }

    // Only the first, fully-written entry should be recovered.
    try testing.expectEqual(@as(usize, 1), entries.items.len);
    try testing.expectEqual(txlog.TxType.detach_start, entries.items[0].tx_type);
}

test "TxLog: open resets legacy unversioned log" {
    const tmp_path = "/tmp/hexe-test-txlog-legacy";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const session_id = [_]u8{9} ** 16;
    const legacy_entry: txlog.TxEntry = .{
        .tx_type = .detach_start,
        .timestamp = 0,
        .session_id = session_id,
        .payload_len = 0,
    };

    {
        var file = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true, .mode = 0o600 });
        defer file.close();
        try file.writeAll(std.mem.asBytes(&legacy_entry));
    }

    var log = txlog.TxLog.init(testing.allocator, tmp_path);
    defer log.deinit();
    try log.open();

    var entries = try log.readAll(testing.allocator);
    defer entries.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), entries.items.len);
}

test "TxLog: readAll rejects per-entry payload_len over 1MB cap" {
    const tmp_path = "/tmp/hexe-test-txlog-oversize";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var log = txlog.TxLog.init(testing.allocator, tmp_path);
    defer log.deinit();
    try log.open();

    const session_id = [_]u8{8} ** 16;
    try log.write(.detach_start, session_id, "valid");

    // Forge a header with a 2MB payload_len. readAll caps per-entry payload
    // at 1MB and breaks the replay loop.
    const forged: txlog.TxEntry = .{
        .tx_type = .reattach_start,
        .timestamp = 0,
        .session_id = session_id,
        .payload_len = 2 * 1024 * 1024,
    };
    const fd = log.log_fd.?;
    _ = try std.posix.write(fd, std.mem.asBytes(&forged));

    var entries = try log.readAll(testing.allocator);
    defer {
        for (entries.items) |*e| {
            testing.allocator.free(e.payload);
        }
        entries.deinit(testing.allocator);
    }

    // Oversized entry is skipped; only the valid first entry survives.
    try testing.expectEqual(@as(usize, 1), entries.items.len);
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

    var log = txlog.TxLog.init(testing.allocator, tmp_path);
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

test "persist: parseSessionIdHex rejects invalid pane session ids" {
    const valid = "00112233445566778899aabbccddeeff";
    const parsed = persist.parseSessionIdHex(valid) orelse return error.ExpectedValidSessionId;
    try testing.expectEqualSlices(u8, &[_]u8{
        0x00, 0x11, 0x22, 0x33,
        0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xaa, 0xbb,
        0xcc, 0xdd, 0xee, 0xff,
    }, &parsed);

    try testing.expectEqual(@as(?[16]u8, null), persist.parseSessionIdHex("short"));
    try testing.expectEqual(@as(?[16]u8, null), persist.parseSessionIdHex("00112233445566778899aabbccddeegx"));
}

test "persist: parseStoredUuidHex rejects malformed pane uuids" {
    const valid = "00112233445566778899aabbccddeeff";
    const parsed = persist.parseStoredUuidHex(valid) orelse return error.ExpectedValidPaneUuid;
    try testing.expectEqualStrings(valid, &parsed);

    try testing.expectEqual(@as(?[32]u8, null), persist.parseStoredUuidHex("short"));
    try testing.expectEqual(@as(?[32]u8, null), persist.parseStoredUuidHex("00112233445566778899aabbccddeegx"));
}

test "persist: writeJsonString escapes persisted strings" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);

    try persist.writeJsonString(out.writer(testing.allocator), "a\"b\\c\n\r\t\x08\x0c\x01");

    try testing.expectEqualStrings(
        "\"a\\\"b\\\\c\\n\\r\\t\\b\\f\\u0001\"",
        out.items,
    );
}

test "persist: attached session is serialized as a recoverable detached entry" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const client_id = try ses_state.addClient(1);
    const session_id = [_]u8{3} ** 16;
    const session_hex: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
    const pane_uuid = [_]u8{'a'} ** 32;

    var snapshot = try core.session_model.SessionSnapshot.initMinimal(testing.allocator, session_hex, "attached-work");
    errdefer snapshot.deinit();
    try snapshot.panes.put(pane_uuid, .{ .uuid = pane_uuid, .kind = .split, .parent_tab = 0 });

    const client = ses_state.getClient(client_id).?;
    client.session_id = session_id;
    client.updateSessionSnapshot(snapshot);
    try client.appendUuid(pane_uuid);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try persist.buildStateJson(testing.allocator, &ses_state, &out);

    // The attached client's session must appear in the persisted state so a
    // daemon crash while attached can recover the layout (not just loose panes).
    try testing.expect(std.mem.indexOf(u8, out.items, &session_hex) != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "attached-work") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "detached_sessions") != null);
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

test "detachSession: includes panes present only in canonical snapshot" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const client_id = try ses_state.addClient(99);
    const session_id = [_]u8{1} ** 16;
    const pane_a = [_]u8{'a'} ** 32;
    const pane_b = [_]u8{'b'} ** 32;
    const orphaned_old_pane = [_]u8{'o'} ** 32;

    if (ses_state.getClient(client_id)) |client| {
        client.session_id = session_id;
        client.session_name = try ses_state.allocator.dupe(u8, "alpha");
        client.session_snapshot = try state.SessionSnapshot.initMinimal(ses_state.allocator, [_]u8{'1'} ** 32, "alpha");
        try client.session_snapshot.?.panes.put(pane_a, .{ .uuid = pane_a, .kind = .split, .parent_tab = 0 });
        try client.session_snapshot.?.panes.put(pane_b, .{ .uuid = pane_b, .kind = .split, .parent_tab = 0 });
        try client.session_snapshot.?.panes.put(orphaned_old_pane, .{ .uuid = orphaned_old_pane, .kind = .split, .parent_tab = 0 });
        try client.appendUuid(pane_a);
    }

    try ses_state.store.panes.put(pane_a, .{
        .uuid = pane_a,
        .pod_pid = 1001,
        .pod_socket_path = try ses_state.allocator.dupe(u8, "/tmp/hexe-pane-a"),
        .child_pid = 2001,
        .state = .attached,
        .sticky_pwd = null,
        .sticky_key = null,
        .attached_to = client_id,
        .session_id = null,
        .created_at = 0,
        .orphaned_at = null,
        .allocator = ses_state.allocator,
    });
    try ses_state.store.panes.put(orphaned_old_pane, .{
        .uuid = orphaned_old_pane,
        .pod_pid = 1003,
        .pod_socket_path = try ses_state.allocator.dupe(u8, "/tmp/hexe-pane-old"),
        .child_pid = 2003,
        .state = .orphaned,
        .sticky_pwd = null,
        .sticky_key = null,
        .attached_to = null,
        .session_id = null,
        .created_at = 0,
        .orphaned_at = 1,
        .allocator = ses_state.allocator,
    });
    try ses_state.store.panes.put(pane_b, .{
        .uuid = pane_b,
        .pod_pid = 1002,
        .pod_socket_path = try ses_state.allocator.dupe(u8, "/tmp/hexe-pane-b"),
        .child_pid = 2002,
        .state = .attached,
        .sticky_pwd = null,
        .sticky_key = null,
        .attached_to = client_id,
        .session_id = null,
        .created_at = 0,
        .orphaned_at = null,
        .allocator = ses_state.allocator,
    });

    try testing.expect(ses_state.detachSession(client_id, session_id, "alpha"));
    try testing.expect(ses_state.getClient(client_id) == null);

    const detached = ses_state.store.detached_sessions.getPtr(session_id) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), detached.pane_uuids.len);

    var saw_a = false;
    var saw_b = false;
    var saw_orphaned_old = false;
    for (detached.pane_uuids) |uuid| {
        if (std.mem.eql(u8, &uuid, &pane_a)) saw_a = true;
        if (std.mem.eql(u8, &uuid, &pane_b)) saw_b = true;
        if (std.mem.eql(u8, &uuid, &orphaned_old_pane)) saw_orphaned_old = true;
    }
    try testing.expect(saw_a);
    try testing.expect(saw_b);
    try testing.expect(!saw_orphaned_old);
    try testing.expect(detached.session_snapshot.panes.get(orphaned_old_pane) == null);

    const restored_b = ses_state.store.panes.getPtr(pane_b) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(state.PaneState.detached, restored_b.state);
    try testing.expect(restored_b.attached_to == null);
    try testing.expect(restored_b.session_id != null);
    try testing.expectEqualSlices(u8, &session_id, &restored_b.session_id.?);
}

test "detachSession: closes POD VT routing without removing detached pane" {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return error.SocketpairFailed;
    var close_pod_vt = true;
    defer if (close_pod_vt) std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const client_id = try ses_state.addClient(99);
    const session_id = [_]u8{9} ** 16;
    const session_hex: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
    const pane_uuid = [_]u8{'v'} ** 32;
    const pane_id: u16 = 77;

    if (ses_state.getClient(client_id)) |client| {
        client.session_id = session_id;
        client.session_name = try ses_state.allocator.dupe(u8, "vt-detach");
        client.session_snapshot = try state.SessionSnapshot.initMinimal(ses_state.allocator, session_hex, "vt-detach");
        try client.session_snapshot.?.panes.put(pane_uuid, .{ .uuid = pane_uuid, .kind = .split, .parent_tab = 0 });
        try client.appendUuid(pane_uuid);
    }

    try ses_state.store.panes.put(pane_uuid, .{
        .uuid = pane_uuid,
        .pod_pid = @intCast(std.c.getpid()),
        .pod_socket_path = try ses_state.allocator.dupe(u8, "/tmp/hexe-pane-vt-detach"),
        .child_pid = @intCast(std.c.getpid()),
        .state = .attached,
        .pane_id = pane_id,
        .pod_vt_fd = fds[0],
        .sticky_pwd = null,
        .sticky_key = null,
        .attached_to = client_id,
        .session_id = null,
        .created_at = 0,
        .orphaned_at = null,
        .allocator = ses_state.allocator,
    });
    try ses_state.store.pod_vt_to_pane_id.put(fds[0], pane_id);
    try ses_state.store.pane_id_to_pod_vt.put(pane_id, fds[0]);

    try testing.expect(ses_state.detachSession(client_id, session_id, "vt-detach"));
    close_pod_vt = false;

    const pane = ses_state.store.panes.get(pane_uuid) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(state.PaneState.detached, pane.state);
    try testing.expect(pane.pod_vt_fd == null);
    try testing.expect(pane.attached_to == null);
    try testing.expect(pane.session_id != null);
    try testing.expectEqualSlices(u8, &session_id, &pane.session_id.?);
    try testing.expect(!ses_state.store.pod_vt_to_pane_id.contains(fds[0]));
    try testing.expect(!ses_state.store.pane_id_to_pod_vt.contains(pane_id));
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

    try ses_state.store.panes.put(uuid, pane);

    // Set timeout to 24 hours
    ses_state.store.orphan_timeout_hours = 24;

    // Cleanup should remove the pane
    ses_state.cleanupOrphanedPanes();

    try testing.expect(!ses_state.store.panes.contains(uuid));
}

test "cleanupOrphanedPanes: keyed sticky float with live pod survives timeout" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const live_pid: std.posix.pid_t = @intCast(std.c.getpid());
    const uuid = [_]u8{7} ** 32;
    try ses_state.store.panes.put(uuid, .{
        .uuid = uuid,
        .name = null,
        .pod_pid = live_pid,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/test-sticky-sweep"),
        .child_pid = live_pid,
        .state = .sticky,
        .sticky_pwd = try testing.allocator.dupe(u8, "/home/test/proj"),
        .sticky_key = 'g',
        .attached_to = null,
        .session_id = null,
        .created_at = 0,
        .orphaned_at = std.time.timestamp() - (400 * 3600),
        .allocator = testing.allocator,
    });
    ses_state.store.orphan_timeout_hours = 24;

    ses_state.cleanupOrphanedPanes();

    // A keyed sticky float is a permanent identity: as long as its pod is
    // alive it must never be reaped on a timer, no matter how old.
    try testing.expect(ses_state.store.panes.contains(uuid));
}

test "cleanupDetachedSessions: duplicate-named live session is never killed" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const live_pid: std.posix.pid_t = @intCast(std.c.getpid());

    // Older live session "work" with a live pane.
    const live_pane_uuid = [_]u8{4} ** 32;
    try ses_state.store.panes.put(live_pane_uuid, .{
        .uuid = live_pane_uuid,
        .name = null,
        .pod_pid = live_pid,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/test-dedupe-live"),
        .child_pid = live_pid,
        .state = .detached,
        .sticky_pwd = null,
        .sticky_key = null,
        .attached_to = null,
        .session_id = null,
        .created_at = 0,
        .orphaned_at = null,
        .allocator = testing.allocator,
    });

    const live_sid = [_]u8{1} ** 16;
    var live_snapshot = try core.session_model.SessionSnapshot.initMinimal(
        testing.allocator,
        std.fmt.bytesToHex(&live_sid, .lower),
        "work",
    );
    errdefer live_snapshot.deinit();
    const live_uuids = try testing.allocator.dupe([32]u8, &.{live_pane_uuid});
    try ses_state.store.detached_sessions.put(live_sid, .{
        .session_id = live_sid,
        .session_snapshot = live_snapshot,
        .pane_uuids = live_uuids,
        .detached_at = 100,
        .allocator = testing.allocator,
    });

    // Newer dead session with the same name (pane pid long gone).
    const dead_pane_uuid = [_]u8{5} ** 32;
    try ses_state.store.panes.put(dead_pane_uuid, .{
        .uuid = dead_pane_uuid,
        .name = null,
        .pod_pid = 999999999,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/test-dedupe-dead"),
        .child_pid = 999999999,
        .state = .detached,
        .sticky_pwd = null,
        .sticky_key = null,
        .attached_to = null,
        .session_id = null,
        .created_at = 0,
        .orphaned_at = null,
        .allocator = testing.allocator,
    });

    const dead_sid = [_]u8{2} ** 16;
    var dead_snapshot = try core.session_model.SessionSnapshot.initMinimal(
        testing.allocator,
        std.fmt.bytesToHex(&dead_sid, .lower),
        "work",
    );
    errdefer dead_snapshot.deinit();
    const dead_uuids = try testing.allocator.dupe([32]u8, &.{dead_pane_uuid});
    try ses_state.store.detached_sessions.put(dead_sid, .{
        .session_id = dead_sid,
        .session_snapshot = dead_snapshot,
        .pane_uuids = dead_uuids,
        .detached_at = 200,
        .allocator = testing.allocator,
    });

    ses_state.cleanupDetachedSessions();

    // The dead duplicate is swept; the live session must survive even though
    // it is older — name dedupe must never kill live panes.
    try testing.expect(ses_state.store.detached_sessions.contains(live_sid));
    try testing.expect(!ses_state.store.detached_sessions.contains(dead_sid));
    try testing.expect(ses_state.store.panes.contains(live_pane_uuid));
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

    try ses_state.store.panes.put(orphaned_uuid, orphaned_pane);
    try ses_state.store.panes.put(sticky_uuid, sticky_pane);
    try ses_state.store.panes.put(attached_uuid, attached_pane);

    // Kill all orphaned panes
    const killed = ses_state.killAllOrphanedPanes();

    try testing.expectEqual(@as(usize, 2), killed);
    try testing.expect(!ses_state.store.panes.contains(orphaned_uuid));
    try testing.expect(!ses_state.store.panes.contains(sticky_uuid));
    try testing.expect(ses_state.store.panes.contains(attached_uuid)); // Should remain
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

test "Client.appendUuid: ignores duplicate pane UUIDs" {
    var client = state.Client.init(testing.allocator, 1, 99);
    defer client.deinit();

    const uuid = [_]u8{7} ** 32;
    try client.appendUuid(uuid);
    try client.appendUuid(uuid);

    try testing.expectEqual(@as(usize, 1), client.pane_uuids.items.len);
    try testing.expectEqualSlices(u8, &uuid, &client.pane_uuids.items[0]);
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
    snapshot.base_root = try testing.allocator.dupe(u8, "/tmp/hexe-root");

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
    try testing.expectEqualStrings("/tmp/hexe-root", reparsed.base_root.?);
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
    try snapshot.panes.put([_]u8{'f'} ** 32, .{ .uuid = [_]u8{'f'} ** 32, .kind = .float, .parent_tab = 0 });
    try snapshot.panes.put([_]u8{'g'} ** 32, .{ .uuid = [_]u8{'g'} ** 32, .kind = .float, .parent_tab = 1 });
    try snapshot.floats.append(testing.allocator, .{ .pane_uuid = [_]u8{'f'} ** 32, .parent_tab = 0 });
    try snapshot.floats.append(testing.allocator, .{ .pane_uuid = [_]u8{'g'} ** 32, .parent_tab = 1 });
    client.updateSessionSnapshot(snapshot);

    ses_state.removeClientSessionTab(client_id, [_]u8{'t'} ** 32, 0);

    try testing.expectEqual(@as(usize, 1), client.session_snapshot.?.tabs.items.len);
    try testing.expectEqualStrings("alpha-2", client.session_snapshot.?.tabs.items[0].name);
    try testing.expect(client.session_snapshot.?.panes.get([_]u8{'1'} ** 32) == null);
    try testing.expect(client.session_snapshot.?.panes.get([_]u8{'f'} ** 32) == null);
    try testing.expectEqual(@as(usize, 0), client.session_snapshot.?.panes.get([_]u8{'2'} ** 32).?.parent_tab.?);
    try testing.expectEqual(@as(usize, 0), client.session_snapshot.?.panes.get([_]u8{'g'} ** 32).?.parent_tab.?);
    try testing.expectEqual(@as(usize, 1), client.session_snapshot.?.floats.items.len);
    try testing.expectEqual([_]u8{'g'} ** 32, client.session_snapshot.?.floats.items[0].pane_uuid);
    try testing.expectEqual(@as(usize, 0), client.session_snapshot.?.floats.items[0].parent_tab.?);
    try testing.expectEqual(@as(usize, 0), client.session_snapshot.?.active_tab);
}

test "renameClientSessionTab: renames the matching tab and leaves others intact" {
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
    client.updateSessionSnapshot(snapshot);

    // Rename the first tab; the second must be untouched.
    ses_state.renameClientSessionTab(client_id, [_]u8{'t'} ** 32, "renamed");
    try testing.expectEqualStrings("renamed", client.session_snapshot.?.tabs.items[0].name);
    try testing.expectEqualStrings("alpha-2", client.session_snapshot.?.tabs.items[1].name);

    // Renaming an unknown tab uuid is a no-op (no crash, no change).
    ses_state.renameClientSessionTab(client_id, [_]u8{'z'} ** 32, "ignored");
    try testing.expectEqualStrings("renamed", client.session_snapshot.?.tabs.items[0].name);
    try testing.expectEqualStrings("alpha-2", client.session_snapshot.?.tabs.items[1].name);
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

    // findStickyPaneWithAffinity filters out panes whose child_pid is dead,
    // so the tests must use a live pid. The current test process is always
    // alive, so use its pid for both synthetic panes.
    const live_pid: std.posix.pid_t = @intCast(std.os.linux.getpid());

    // Create two sticky panes with same pwd+key, different sessions
    const uuid1 = [_]u8{1} ** 32;
    const uuid2 = [_]u8{2} ** 32;

    const pane1 = state.Pane{
        .uuid = uuid1,
        .name = try testing.allocator.dupe(u8, "pane1"),
        .pod_pid = live_pid,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/pane1"),
        .child_pid = live_pid,
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
        .pod_pid = live_pid,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/pane2"),
        .child_pid = live_pid,
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

    try ses_state.store.panes.put(uuid1, pane1);
    try ses_state.store.panes.put(uuid2, pane2);

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
    const live_pid: std.posix.pid_t = @intCast(std.os.linux.getpid());

    const uuid = [_]u8{1} ** 32;
    const pane = state.Pane{
        .uuid = uuid,
        .name = try testing.allocator.dupe(u8, "pane1"),
        .pod_pid = live_pid,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/pane1"),
        .child_pid = live_pid,
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

    try ses_state.store.panes.put(uuid, pane);

    // Search with affinity for "beta" (doesn't match "alpha")
    const found = ses_state.findStickyPaneWithAffinity(pwd, key, "beta");
    try testing.expect(found != null);
    if (found) |p| {
        // Should still find the pane (fallback to any match)
        try testing.expectEqualSlices(u8, &uuid, &p.uuid);
    }
}

test "findStickyPaneWithAffinity: finds detached per-cwd sticky pane" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const pwd = "/home/test";
    const key: u8 = '2';
    const live_pid: std.posix.pid_t = @intCast(std.os.linux.getpid());
    const session_id = [_]u8{9} ** 16;
    const uuid = [_]u8{3} ** 32;

    const pane = state.Pane{
        .uuid = uuid,
        .name = try testing.allocator.dupe(u8, "detached-cwd-float"),
        .pod_pid = live_pid,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/detached-cwd-float"),
        .child_pid = live_pid,
        .state = .detached,
        .sticky_pwd = try testing.allocator.dupe(u8, pwd),
        .sticky_key = key,
        .sticky_session_name = try testing.allocator.dupe(u8, "alpha"),
        .attached_to = null,
        .session_id = session_id,
        .created_at = 0,
        .orphaned_at = std.time.timestamp(),
        .allocator = testing.allocator,
    };
    try ses_state.store.panes.put(uuid, pane);

    const found = ses_state.findStickyPaneWithAffinity(pwd, key, "alpha");
    try testing.expect(found != null);
    try testing.expectEqualSlices(u8, &uuid, &found.?.uuid);
}

test "per-CWD sticky floats: keys 1/2/3 in one pwd resolve independently" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const pwd = "/home/test/proj";
    const live_pid: std.posix.pid_t = @intCast(std.os.linux.getpid());
    const keys = [_]u8{ '1', '2', '3' };
    const uuids = [_][32]u8{
        [_]u8{0x41} ** 32,
        [_]u8{0x42} ** 32,
        [_]u8{0x43} ** 32,
    };

    for (keys, uuids) |key, uuid| {
        var sock_buf: [64]u8 = undefined;
        const sock = try std.fmt.bufPrint(&sock_buf, "/tmp/hexe-cwdfloat-{c}", .{key});
        try ses_state.store.panes.put(uuid, .{
            .uuid = uuid,
            .name = try testing.allocator.dupe(u8, "cwd-float"),
            .pod_pid = live_pid,
            .pod_socket_path = try testing.allocator.dupe(u8, sock),
            .child_pid = live_pid,
            .state = .sticky,
            .sticky_pwd = try testing.allocator.dupe(u8, pwd),
            .sticky_key = key,
            .attached_to = null,
            .session_id = null,
            .created_at = 0,
            .orphaned_at = std.time.timestamp(),
            .allocator = testing.allocator,
        });
    }

    // Each (pwd, key) identity resolves to its own distinct pane.
    for (keys, uuids) |key, uuid| {
        const found = ses_state.findStickyPaneWithAffinity(pwd, key, null);
        try testing.expect(found != null);
        try testing.expectEqualSlices(u8, &uuid, &found.?.uuid);
    }

    // A key with no sticky pane does not collide with the populated pwd.
    try testing.expect(ses_state.findStickyPaneWithAffinity(pwd, '9', null) == null);
}

test "per-CWD sticky float takeover transfers ownership without spawning" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const pwd = "/home/test/proj";
    const live_pid: std.posix.pid_t = @intCast(std.os.linux.getpid());
    const keys = [_]u8{ '1', '2', '3' };
    const uuids = [_][32]u8{
        [_]u8{0x51} ** 32,
        [_]u8{0x52} ** 32,
        [_]u8{0x53} ** 32,
    };

    for (keys, uuids) |key, uuid| {
        var sock_buf: [64]u8 = undefined;
        const sock = try std.fmt.bufPrint(&sock_buf, "/tmp/hexe-takeover-{c}", .{key});
        try ses_state.store.panes.put(uuid, .{
            .uuid = uuid,
            .name = try testing.allocator.dupe(u8, "cwd-float"),
            .pod_pid = live_pid,
            .pod_socket_path = try testing.allocator.dupe(u8, sock),
            .child_pid = live_pid,
            .state = .sticky,
            .sticky_pwd = try testing.allocator.dupe(u8, pwd),
            .sticky_key = key,
            .attached_to = null,
            .session_id = null,
            .created_at = 0,
            .orphaned_at = std.time.timestamp(),
            .allocator = testing.allocator,
        });
    }

    // Client A adopts all three per-CWD floats.
    const client_a = try ses_state.addClient(101);
    for (uuids) |uuid| {
        _ = try ses_state.attachPane(uuid, client_a);
    }
    try testing.expectEqual(@as(usize, 3), ses_state.getClient(client_a).?.pane_uuids.items.len);

    // Client B takes over key '2' only.
    const client_b = try ses_state.addClient(102);
    const target = uuids[1];
    try testing.expect(ses_state.stealAttachedPane(target, client_b));
    const taken = try ses_state.attachPane(target, client_b);

    // Takeover returns the original pane UUID — no duplicate pane spawned.
    try testing.expectEqualSlices(u8, &target, &taken.uuid);
    try testing.expectEqual(@as(usize, 3), ses_state.store.panes.count());

    // Ownership moved from A to B for key '2' only.
    try testing.expectEqual(client_b, taken.attached_to.?);
    const a_panes = ses_state.getClient(client_a).?.pane_uuids;
    try testing.expectEqual(@as(usize, 2), a_panes.items.len);
    for (a_panes.items) |uuid| {
        try testing.expect(!std.mem.eql(u8, &uuid, &target));
    }
    const b_panes = ses_state.getClient(client_b).?.pane_uuids;
    try testing.expectEqual(@as(usize, 1), b_panes.items.len);
    try testing.expectEqualSlices(u8, &target, &b_panes.items[0]);

    // Keys '1' and '3' still belong to client A and not client B.
    for ([_]usize{ 0, 2 }) |i| {
        try testing.expect(ses_state.paneAttachedToClient(uuids[i], client_a));
        try testing.expect(!ses_state.paneAttachedToClient(uuids[i], client_b));
    }
}

// ============================================================================
// SessionSnapshot mutation tests (P7.3)
//
// These exercise `removePaneFromSessionSnapshot` directly. The function is
// reached in production via the orphan/sticky/detach cleanup paths
// (`prunePaneFromClientSnapshot` / `prunePaneFromDetachedSnapshot`), and its
// branches are subtle enough to deserve unit coverage independent of those
// callers — especially the parent_tab reindex that runs when removing the
// last split pane in a tab also has to update floats living in later tabs.
// ============================================================================

fn makeLeafLayout(allocator: std.mem.Allocator, pane_uuid: [32]u8) !*core.session_model.SessionLayoutNode {
    const node = try allocator.create(core.session_model.SessionLayoutNode);
    node.* = .{ .pane = pane_uuid };
    return node;
}

fn makeSplitLayout(
    allocator: std.mem.Allocator,
    first_uuid: [32]u8,
    second_uuid: [32]u8,
) !*core.session_model.SessionLayoutNode {
    const first = try makeLeafLayout(allocator, first_uuid);
    errdefer {
        first.deinit(allocator);
        allocator.destroy(first);
    }
    const second = try makeLeafLayout(allocator, second_uuid);
    errdefer {
        second.deinit(allocator);
        allocator.destroy(second);
    }
    const node = try allocator.create(core.session_model.SessionLayoutNode);
    node.* = .{ .split = .{
        .dir = .horizontal,
        .ratio = 0.5,
        .first = first,
        .second = second,
    } };
    return node;
}

test "removePaneFromSessionSnapshot: float removal clears panes, floats, and active_float_uuid" {
    var snapshot = try state.SessionSnapshot.initMinimal(testing.allocator, [_]u8{'s'} ** 32, "alpha");
    defer snapshot.deinit();

    const float_uuid = [_]u8{'f'} ** 32;
    try snapshot.panes.put(float_uuid, .{
        .uuid = float_uuid,
        .kind = .float,
        .parent_tab = null,
    });
    try snapshot.floats.append(testing.allocator, .{
        .pane_uuid = float_uuid,
        .parent_tab = null,
        .visible = true,
    });
    snapshot.active_float_uuid = float_uuid;
    snapshot.focused_pane_uuid = float_uuid;

    state.SesState.removePaneFromSessionSnapshot(testing.allocator, &snapshot, float_uuid);

    try testing.expect(snapshot.panes.get(float_uuid) == null);
    try testing.expectEqual(@as(usize, 0), snapshot.floats.items.len);
    try testing.expect(snapshot.active_float_uuid == null);
    try testing.expect(snapshot.focused_pane_uuid == null);
}

test "removePaneFromSessionSnapshot: removing one of two split panes keeps tab and updates focus" {
    var snapshot = try state.SessionSnapshot.initMinimal(testing.allocator, [_]u8{'s'} ** 32, "alpha");
    defer snapshot.deinit();

    const left = [_]u8{'1'} ** 32;
    const right = [_]u8{'2'} ** 32;

    const root = try makeSplitLayout(testing.allocator, left, right);
    try snapshot.tabs.append(testing.allocator, .{
        .uuid = [_]u8{'t'} ** 32,
        .name = try testing.allocator.dupe(u8, "tab-0"),
        .root = root,
        .focused_pane_uuid = left,
        .allocator = testing.allocator,
    });
    try snapshot.panes.put(left, .{ .uuid = left, .kind = .split, .parent_tab = 0 });
    try snapshot.panes.put(right, .{ .uuid = right, .kind = .split, .parent_tab = 0 });
    snapshot.active_tab = 0;
    snapshot.focused_pane_uuid = left;

    state.SesState.removePaneFromSessionSnapshot(testing.allocator, &snapshot, left);

    try testing.expectEqual(@as(usize, 1), snapshot.tabs.items.len);
    try testing.expect(snapshot.panes.get(left) == null);
    try testing.expect(snapshot.panes.get(right) != null);
    try testing.expectEqual(right, snapshot.tabs.items[0].focused_pane_uuid.?);
    try testing.expectEqual(right, snapshot.focused_pane_uuid.?);

    // Layout should now be a leaf for `right`.
    const new_root = snapshot.tabs.items[0].root.?;
    try testing.expect(new_root.* == .pane);
    try testing.expectEqual(right, new_root.pane);
}

test "removePaneFromSessionSnapshot: emptying a tab reindexes floats in later tabs" {
    var snapshot = try state.SessionSnapshot.initMinimal(testing.allocator, [_]u8{'s'} ** 32, "alpha");
    defer snapshot.deinit();

    const split0 = [_]u8{'1'} ** 32;
    const split1 = [_]u8{'2'} ** 32;
    const float_in_tab1 = [_]u8{'f'} ** 32;

    // Tab 0: single split pane (will be removed → tab disappears).
    const root0 = try makeLeafLayout(testing.allocator, split0);
    try snapshot.tabs.append(testing.allocator, .{
        .uuid = [_]u8{'t'} ** 32,
        .name = try testing.allocator.dupe(u8, "tab-0"),
        .root = root0,
        .focused_pane_uuid = split0,
        .allocator = testing.allocator,
    });

    // Tab 1: another split pane, plus a float anchored to this tab.
    const root1 = try makeLeafLayout(testing.allocator, split1);
    try snapshot.tabs.append(testing.allocator, .{
        .uuid = [_]u8{'u'} ** 32,
        .name = try testing.allocator.dupe(u8, "tab-1"),
        .root = root1,
        .focused_pane_uuid = split1,
        .allocator = testing.allocator,
    });

    try snapshot.panes.put(split0, .{ .uuid = split0, .kind = .split, .parent_tab = 0 });
    try snapshot.panes.put(split1, .{ .uuid = split1, .kind = .split, .parent_tab = 1 });
    try snapshot.panes.put(float_in_tab1, .{
        .uuid = float_in_tab1,
        .kind = .float,
        .parent_tab = 1,
    });
    try snapshot.floats.append(testing.allocator, .{
        .pane_uuid = float_in_tab1,
        .parent_tab = 1,
        .visible = true,
    });
    snapshot.active_tab = 0;
    snapshot.focused_pane_uuid = split0;

    state.SesState.removePaneFromSessionSnapshot(testing.allocator, &snapshot, split0);

    // Tab 0 collapsed → tab 1 is now tab 0.
    try testing.expectEqual(@as(usize, 1), snapshot.tabs.items.len);
    try testing.expectEqualStrings("tab-1", snapshot.tabs.items[0].name);
    try testing.expectEqual(@as(usize, 0), snapshot.active_tab);

    // Surviving split pane parent_tab decremented.
    try testing.expectEqual(@as(usize, 0), snapshot.panes.get(split1).?.parent_tab.?);

    // Float reindexed in BOTH the floats ArrayList AND the panes hashmap.
    try testing.expectEqual(@as(usize, 1), snapshot.floats.items.len);
    try testing.expectEqual(@as(usize, 0), snapshot.floats.items[0].parent_tab.?);
    try testing.expectEqual(@as(usize, 0), snapshot.panes.get(float_in_tab1).?.parent_tab.?);

    // Removed pane is gone.
    try testing.expect(snapshot.panes.get(split0) == null);
}

test "suspendPane: prunes pane from client snapshot" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const client_id = try ses_state.addClient(99);
    const pane_uuid = [_]u8{'p'} ** 32;
    const session_uuid = [_]u8{'s'} ** 32;

    if (ses_state.getClient(client_id)) |client| {
        client.session_id = [_]u8{1} ** 16;
        client.session_name = try ses_state.allocator.dupe(u8, "alpha");
        client.session_snapshot = try state.SessionSnapshot.initMinimal(ses_state.allocator, session_uuid, "alpha");
        try client.session_snapshot.?.panes.put(pane_uuid, .{ .uuid = pane_uuid, .kind = .split, .parent_tab = 0 });
        client.session_snapshot.?.focused_pane_uuid = pane_uuid;
        try client.appendUuid(pane_uuid);
    }

    try ses_state.store.panes.put(pane_uuid, .{
        .uuid = pane_uuid,
        .pod_pid = 1001,
        .pod_socket_path = try ses_state.allocator.dupe(u8, "/tmp/hexe-pane-suspend"),
        .child_pid = 2001,
        .state = .attached,
        .sticky_pwd = null,
        .sticky_key = null,
        .attached_to = client_id,
        .session_id = null,
        .created_at = 0,
        .orphaned_at = null,
        .allocator = ses_state.allocator,
    });

    try ses_state.suspendPane(pane_uuid);

    const client = ses_state.getClient(client_id).?;
    try testing.expectEqual(@as(usize, 0), client.pane_uuids.items.len);
    try testing.expect(client.session_snapshot.?.panes.get(pane_uuid) == null);
    try testing.expect(client.session_snapshot.?.focused_pane_uuid == null);

    const pane = ses_state.store.panes.get(pane_uuid).?;
    try testing.expectEqual(state.PaneState.orphaned, pane.state);
    try testing.expect(pane.attached_to == null);
}

test "attachPane: missing client leaves pane adoptable" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const pane_uuid = [_]u8{'a'} ** 32;
    try ses_state.store.panes.put(pane_uuid, .{
        .uuid = pane_uuid,
        .pod_pid = 1001,
        .pod_socket_path = try ses_state.allocator.dupe(u8, "/tmp/hexe-pane-attach-missing-client"),
        .child_pid = 2001,
        .state = .orphaned,
        .sticky_pwd = null,
        .sticky_key = null,
        .attached_to = null,
        .session_id = null,
        .created_at = 0,
        .orphaned_at = 123,
        .allocator = ses_state.allocator,
    });

    try testing.expectError(error.ClientNotFound, ses_state.attachPane(pane_uuid, 404));

    const pane = ses_state.store.panes.get(pane_uuid).?;
    try testing.expectEqual(state.PaneState.orphaned, pane.state);
    try testing.expect(pane.attached_to == null);
    try testing.expectEqual(@as(?i64, 123), pane.orphaned_at);
    try testing.expect(!pane.needs_backlog_replay);
}

test "attachPane: recovers persisted attached pane with no owner" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const client_id = try ses_state.addClient(99);
    const pane_uuid = [_]u8{'r'} ** 32;
    try ses_state.store.panes.put(pane_uuid, .{
        .uuid = pane_uuid,
        .pod_pid = 1001,
        .pod_socket_path = try ses_state.allocator.dupe(u8, "/tmp/hexe-pane-attached-no-owner"),
        .child_pid = 2001,
        .state = .attached,
        .sticky_pwd = try ses_state.allocator.dupe(u8, "/home/test"),
        .sticky_key = '2',
        .attached_to = null,
        .session_id = null,
        .created_at = 0,
        .orphaned_at = null,
        .allocator = ses_state.allocator,
    });

    const pane = try ses_state.attachPane(pane_uuid, client_id);
    try testing.expectEqual(state.PaneState.attached, pane.state);
    try testing.expectEqual(client_id, pane.attached_to.?);

    const client = ses_state.getClient(client_id).?;
    try testing.expectEqual(@as(usize, 1), client.pane_uuids.items.len);
    try testing.expectEqualSlices(u8, &pane_uuid, &client.pane_uuids.items[0]);
}

test "paneAttachedToClient: requires live attached ownership" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const attached_uuid = [_]u8{'a'} ** 32;
    const orphan_uuid = [_]u8{'o'} ** 32;

    try ses_state.store.panes.put(attached_uuid, .{
        .uuid = attached_uuid,
        .pod_pid = 1001,
        .pod_socket_path = try ses_state.allocator.dupe(u8, "/tmp/hexe-pane-live-owned"),
        .child_pid = 2001,
        .state = .attached,
        .sticky_pwd = null,
        .sticky_key = null,
        .attached_to = 7,
        .session_id = null,
        .created_at = 0,
        .orphaned_at = null,
        .allocator = ses_state.allocator,
    });
    try ses_state.store.panes.put(orphan_uuid, .{
        .uuid = orphan_uuid,
        .pod_pid = 1002,
        .pod_socket_path = try ses_state.allocator.dupe(u8, "/tmp/hexe-pane-live-orphan"),
        .child_pid = 2002,
        .state = .orphaned,
        .sticky_pwd = null,
        .sticky_key = null,
        .attached_to = null,
        .session_id = null,
        .created_at = 0,
        .orphaned_at = 123,
        .allocator = ses_state.allocator,
    });

    try testing.expect(ses_state.paneAttachedToClient(attached_uuid, 7));
    try testing.expect(!ses_state.paneAttachedToClient(attached_uuid, 8));
    try testing.expect(!ses_state.paneAttachedToClient(orphan_uuid, 7));
    try testing.expect(!ses_state.paneAttachedToClient([_]u8{'m'} ** 32, 7));
}

// ============================================================================
// Client snapshot ownership tests (P8.2)
//
// These cover the `snapshotOwnsPane` / `snapshotOwnsTab` helpers used by the
// `session_*` handler guards in server.zig. The server-side glue is verified
// by the build (requireSnapshotTab/Pane callsites type-check); these unit
// tests pin the helper contract: allow before first sync, then enforce.
// ============================================================================

test "snapshotOwnsPane: allows when no snapshot attached" {
    var client = state.Client.init(testing.allocator, 1, 42);
    defer client.deinit();

    try testing.expect(client.snapshotOwnsPane([_]u8{'x'} ** 32));
}

test "snapshotOwnsPane: accepts known pane, rejects unknown" {
    var client = state.Client.init(testing.allocator, 1, 42);
    defer client.deinit();

    var snapshot = try state.SessionSnapshot.initMinimal(testing.allocator, [_]u8{'s'} ** 32, "alpha");
    const known = [_]u8{'k'} ** 32;
    try snapshot.panes.put(known, .{ .uuid = known, .kind = .split, .parent_tab = 0 });
    client.updateSessionSnapshot(snapshot);

    try testing.expect(client.snapshotOwnsPane(known));
    try testing.expect(!client.snapshotOwnsPane([_]u8{'u'} ** 32));
}

test "snapshotOwnsTab: allows when no snapshot attached" {
    var client = state.Client.init(testing.allocator, 1, 42);
    defer client.deinit();

    try testing.expect(client.snapshotOwnsTab([_]u8{'x'} ** 32));
}

test "snapshotOwnsTab: accepts known tab, rejects unknown" {
    var client = state.Client.init(testing.allocator, 1, 42);
    defer client.deinit();

    var snapshot = try state.SessionSnapshot.initMinimal(testing.allocator, [_]u8{'s'} ** 32, "alpha");
    const known = [_]u8{'t'} ** 32;
    try snapshot.tabs.append(testing.allocator, .{
        .uuid = known,
        .name = try testing.allocator.dupe(u8, "tab-known"),
        .allocator = testing.allocator,
    });
    client.updateSessionSnapshot(snapshot);

    try testing.expect(client.snapshotOwnsTab(known));
    try testing.expect(!client.snapshotOwnsTab([_]u8{'u'} ** 32));
}

// ============================================================================
// Float persistence across detach/reattach (sticky/per-CWD identity)
// ============================================================================

test "attachPane: refuses pane parked in another detached session" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const client_id = try ses_state.addClient(1);
    const parked_session = [_]u8{7} ** 16;
    const session_hex: [32]u8 = std.fmt.bytesToHex(&parked_session, .lower);
    const pane_uuid = [_]u8{'q'} ** 32;
    const live_pid: std.posix.pid_t = @intCast(std.c.getpid());

    var snapshot = try core.session_model.SessionSnapshot.initMinimal(testing.allocator, session_hex, "parked");
    errdefer snapshot.deinit();
    try snapshot.panes.put(pane_uuid, .{ .uuid = pane_uuid, .kind = .split, .parent_tab = null });

    const pane_uuids = try testing.allocator.alloc([32]u8, 1);
    errdefer testing.allocator.free(pane_uuids);
    pane_uuids[0] = pane_uuid;

    try ses_state.store.panes.put(pane_uuid, .{
        .uuid = pane_uuid,
        .name = null,
        .pod_pid = live_pid,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/test-parked.sock"),
        .child_pid = live_pid,
        .state = .detached,
        .sticky_pwd = null,
        .sticky_key = null,
        .attached_to = null,
        .session_id = parked_session,
        .created_at = std.time.timestamp(),
        .orphaned_at = null,
        .allocator = testing.allocator,
    });

    try ses_state.store.detached_sessions.put(parked_session, .{
        .session_id = parked_session,
        .session_snapshot = snapshot,
        .pane_uuids = pane_uuids,
        .detached_at = std.time.timestamp(),
        .allocator = testing.allocator,
    });

    // A client with no relationship to the parked session must not adopt.
    try testing.expectError(error.PaneParkedInOtherSession, ses_state.attachPane(pane_uuid, client_id));

    // The same client reattaching that session may adopt.
    if (ses_state.getClient(client_id)) |client| {
        client.pending_reattach_session_id = parked_session;
    }
    const pane = try ses_state.attachPane(pane_uuid, client_id);
    try testing.expectEqual(state.PaneState.attached, pane.state);
    try testing.expectEqual(client_id, pane.attached_to.?);
}

test "attachPane: reattach client reclaims exact snapshot float from live owner" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const old_owner = try ses_state.addClient(1);
    const reattach_client = try ses_state.addClient(2);
    const session_id = [_]u8{8} ** 16;
    const session_hex: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
    const float_uuid = [_]u8{'r'} ** 32;
    const live_pid: std.posix.pid_t = @intCast(std.c.getpid());

    try ses_state.store.panes.put(float_uuid, .{
        .uuid = float_uuid,
        .name = null,
        .pod_pid = live_pid,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/test-reclaim-float.sock"),
        .child_pid = live_pid,
        .state = .attached,
        .sticky_pwd = try testing.allocator.dupe(u8, "/home/test/proj"),
        .sticky_key = 'g',
        .attached_to = old_owner,
        .session_id = null,
        .created_at = std.time.timestamp(),
        .orphaned_at = null,
        .allocator = testing.allocator,
    });
    try ses_state.getClient(old_owner).?.appendUuid(float_uuid);

    var snapshot = try core.session_model.SessionSnapshot.initMinimal(testing.allocator, session_hex, "reattach");
    try snapshot.panes.put(float_uuid, .{
        .uuid = float_uuid,
        .kind = .float,
        .parent_tab = null,
        .sticky = true,
        .is_pwd = true,
        .float_key = 'g',
    });
    try snapshot.floats.append(testing.allocator, .{
        .pane_uuid = float_uuid,
        .sticky = true,
        .is_pwd = true,
        .float_key = 'g',
    });

    if (ses_state.getClient(reattach_client)) |client| {
        client.pending_reattach_session_id = session_id;
        client.pending_reattach_started_at = std.time.timestamp();
        client.updateSessionSnapshot(snapshot);
    }

    const pane = try ses_state.attachPane(float_uuid, reattach_client);
    try testing.expectEqual(state.PaneState.attached, pane.state);
    try testing.expectEqual(reattach_client, pane.attached_to.?);
    try testing.expectEqual(@as(usize, 0), ses_state.getClient(old_owner).?.pane_uuids.items.len);
    try testing.expectEqual(@as(usize, 1), ses_state.getClient(reattach_client).?.pane_uuids.items.len);
    try testing.expectEqualSlices(u8, &float_uuid, &ses_state.getClient(reattach_client).?.pane_uuids.items[0]);
}

test "detachSession: keeps sticky float identity owned by another client" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const client_a = try ses_state.addClient(1);
    const client_b = try ses_state.addClient(2);
    const session_id = [_]u8{4} ** 16;
    const session_hex: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
    const tile_uuid = [_]u8{'t'} ** 32;
    const float_uuid = [_]u8{'f'} ** 32;
    const live_pid: std.posix.pid_t = @intCast(std.c.getpid());

    try ses_state.store.panes.put(tile_uuid, .{
        .uuid = tile_uuid,
        .name = null,
        .pod_pid = live_pid,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/test-tile.sock"),
        .child_pid = live_pid,
        .state = .attached,
        .sticky_pwd = null,
        .sticky_key = null,
        .attached_to = client_a,
        .session_id = null,
        .created_at = std.time.timestamp(),
        .orphaned_at = null,
        .allocator = testing.allocator,
    });
    // Shared per-CWD float currently owned by client B.
    try ses_state.store.panes.put(float_uuid, .{
        .uuid = float_uuid,
        .name = null,
        .pod_pid = live_pid,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/test-float.sock"),
        .child_pid = live_pid,
        .state = .attached,
        .sticky_pwd = try testing.allocator.dupe(u8, "/home/test/proj"),
        .sticky_key = 'g',
        .attached_to = client_b,
        .session_id = null,
        .created_at = std.time.timestamp(),
        .orphaned_at = null,
        .allocator = testing.allocator,
    });

    if (ses_state.getClient(client_a)) |client| {
        client.session_id = session_id;
        try client.appendUuid(tile_uuid);

        var snapshot = try core.session_model.SessionSnapshot.initMinimal(testing.allocator, session_hex, "shared");
        try snapshot.panes.put(tile_uuid, .{ .uuid = tile_uuid, .kind = .split, .parent_tab = null });
        try snapshot.panes.put(float_uuid, .{
            .uuid = float_uuid,
            .kind = .float,
            .parent_tab = null,
            .sticky = true,
            .is_pwd = true,
            .float_key = 'g',
        });
        try snapshot.floats.append(testing.allocator, .{
            .pane_uuid = float_uuid,
            .sticky = true,
            .is_pwd = true,
            .float_key = 'g',
        });
        client.updateSessionSnapshot(snapshot);
    }

    try testing.expect(ses_state.detachSession(client_a, session_id, "shared"));

    const detached = ses_state.store.detached_sessions.getPtr(session_id) orelse return error.TestUnexpectedResult;

    // Only the owned tile is adoptable on reattach...
    try testing.expectEqual(@as(usize, 1), detached.pane_uuids.len);
    try testing.expectEqualSlices(u8, &tile_uuid, &detached.pane_uuids[0]);

    // ...but the sticky float identity stays in the session snapshot so the
    // session does not permanently forget its float.
    try testing.expectEqual(@as(usize, 1), detached.session_snapshot.floats.items.len);
    try testing.expectEqualSlices(u8, &float_uuid, &detached.session_snapshot.floats.items[0].pane_uuid);
    try testing.expect(detached.session_snapshot.panes.contains(float_uuid));
}

test "removeClient: preserves sticky panes when keepalive is off" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const client_id = try ses_state.addClient(1);
    const float_uuid = [_]u8{'s'} ** 32;
    const live_pid: std.posix.pid_t = @intCast(std.c.getpid());

    try ses_state.store.panes.put(float_uuid, .{
        .uuid = float_uuid,
        .name = null,
        .pod_pid = live_pid,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/test-sticky.sock"),
        .child_pid = live_pid,
        .state = .attached,
        .sticky_pwd = try testing.allocator.dupe(u8, "/home/test/proj"),
        .sticky_key = 'g',
        .attached_to = client_id,
        .session_id = null,
        .created_at = std.time.timestamp(),
        .orphaned_at = null,
        .allocator = testing.allocator,
    });
    if (ses_state.getClient(client_id)) |client| {
        client.keepalive = false;
        try client.appendUuid(float_uuid);
    }

    ses_state.removeClient(client_id);

    const pane = ses_state.store.panes.get(float_uuid) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(state.PaneState.sticky, pane.state);
    try testing.expect(pane.attached_to == null);
}

test "reattachSession: sweeps dead sticky floats kept in detached snapshot" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const client_id = try ses_state.addClient(1);
    const session_id = [_]u8{5} ** 16;
    const session_hex: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
    const tile_uuid = [_]u8{'t'} ** 32;
    const dead_float_uuid = [_]u8{'d'} ** 32;
    const live_pid: std.posix.pid_t = @intCast(std.c.getpid());

    var snapshot = try core.session_model.SessionSnapshot.initMinimal(testing.allocator, session_hex, "sweep");
    errdefer snapshot.deinit();
    try snapshot.panes.put(tile_uuid, .{ .uuid = tile_uuid, .kind = .split, .parent_tab = null });
    try snapshot.panes.put(dead_float_uuid, .{
        .uuid = dead_float_uuid,
        .kind = .float,
        .parent_tab = null,
        .sticky = true,
        .is_pwd = true,
        .float_key = 'g',
    });
    try snapshot.floats.append(testing.allocator, .{
        .pane_uuid = dead_float_uuid,
        .sticky = true,
        .is_pwd = true,
        .float_key = 'g',
    });

    const pane_uuids = try testing.allocator.alloc([32]u8, 1);
    errdefer testing.allocator.free(pane_uuids);
    pane_uuids[0] = tile_uuid;

    try ses_state.store.panes.put(tile_uuid, .{
        .uuid = tile_uuid,
        .name = null,
        .pod_pid = live_pid,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/test-sweep-tile.sock"),
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
    // The float's pane is intentionally absent from the store (pod is gone).

    try ses_state.store.detached_sessions.put(session_id, .{
        .session_id = session_id,
        .session_snapshot = snapshot,
        .pane_uuids = pane_uuids,
        .detached_at = std.time.timestamp(),
        .allocator = testing.allocator,
    });

    const result = (try ses_state.reattachSession(session_id, client_id)) orelse return error.TestUnexpectedResult;

    // The dead float is gone from the snapshot, the live tile survives.
    try testing.expectEqual(@as(usize, 0), result.session_snapshot.floats.items.len);
    try testing.expect(!result.session_snapshot.panes.contains(dead_float_uuid));
    try testing.expect(result.session_snapshot.panes.contains(tile_uuid));
    try testing.expectEqual(@as(usize, 1), result.pane_uuids.len);
}

test "isPaneParked: requires actual membership, stale session_id is not parked" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const session_id = [_]u8{3} ** 16;
    const session_hex: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
    const parked_uuid = [_]u8{'k'} ** 32;
    const stale_uuid = [_]u8{'z'} ** 32;
    const live_pid: std.posix.pid_t = @intCast(std.c.getpid());

    var snapshot = try core.session_model.SessionSnapshot.initMinimal(testing.allocator, session_hex, "parked");
    errdefer snapshot.deinit();
    try snapshot.panes.put(parked_uuid, .{ .uuid = parked_uuid, .kind = .split, .parent_tab = null });

    const pane_uuids = try testing.allocator.alloc([32]u8, 1);
    errdefer testing.allocator.free(pane_uuids);
    pane_uuids[0] = parked_uuid;

    try ses_state.store.panes.put(parked_uuid, .{
        .uuid = parked_uuid,
        .name = null,
        .pod_pid = live_pid,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/test-parked-k.sock"),
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
    // Free sticky pane carrying a stale session marker: it is NOT in the
    // detached session's adoptable set and must remain claimable.
    try ses_state.store.panes.put(stale_uuid, .{
        .uuid = stale_uuid,
        .name = null,
        .pod_pid = live_pid,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/test-stale-z.sock"),
        .child_pid = live_pid,
        .state = .sticky,
        .sticky_pwd = try testing.allocator.dupe(u8, "/home/test/proj"),
        .sticky_key = 'g',
        .attached_to = null,
        .session_id = session_id,
        .created_at = std.time.timestamp(),
        .orphaned_at = std.time.timestamp(),
        .allocator = testing.allocator,
    });

    try ses_state.store.detached_sessions.put(session_id, .{
        .session_id = session_id,
        .session_snapshot = snapshot,
        .pane_uuids = pane_uuids,
        .detached_at = std.time.timestamp(),
        .allocator = testing.allocator,
    });

    try testing.expect(ses_state.isPaneParked(ses_state.store.panes.getPtr(parked_uuid).?));
    try testing.expect(!ses_state.isPaneParked(ses_state.store.panes.getPtr(stale_uuid).?));

    // The stale-marker sticky pane must be adoptable by any client.
    const client_id = try ses_state.addClient(1);
    const pane = try ses_state.attachPane(stale_uuid, client_id);
    try testing.expectEqual(state.PaneState.attached, pane.state);
}

test "stealAttachedPane and suspendPane clear the session marker" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();

    const client_a = try ses_state.addClient(1);
    const stale_session = [_]u8{2} ** 16;
    const float_uuid = [_]u8{'w'} ** 32;
    const live_pid: std.posix.pid_t = @intCast(std.c.getpid());

    try ses_state.store.panes.put(float_uuid, .{
        .uuid = float_uuid,
        .name = null,
        .pod_pid = live_pid,
        .pod_socket_path = try testing.allocator.dupe(u8, "/tmp/test-steal-w.sock"),
        .child_pid = live_pid,
        .state = .attached,
        .sticky_pwd = try testing.allocator.dupe(u8, "/home/test/proj"),
        .sticky_key = 'g',
        .attached_to = client_a,
        .session_id = stale_session,
        .created_at = std.time.timestamp(),
        .orphaned_at = null,
        .allocator = testing.allocator,
    });

    try testing.expect(ses_state.stealAttachedPane(float_uuid, 99));
    {
        const pane = ses_state.store.panes.get(float_uuid) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(state.PaneState.sticky, pane.state);
        try testing.expect(pane.session_id == null);
    }

    // Re-attach then disown: the marker must stay clear.
    if (ses_state.store.panes.getPtr(float_uuid)) |pane| pane.session_id = stale_session;
    _ = try ses_state.attachPane(float_uuid, client_a);
    try ses_state.suspendPane(float_uuid);
    {
        const pane = ses_state.store.panes.get(float_uuid) orelse return error.TestUnexpectedResult;
        try testing.expect(pane.session_id == null);
    }
}

test "persist buildStateJson -> restore: detached snapshot survives incl float tab_visible + split layout" {
    const allocator = testing.allocator;
    var ses_state = state.SesState.init(allocator);
    defer ses_state.deinit();

    const SLN = core.session_model.SessionLayoutNode;
    const session_id = [_]u8{7} ** 16;
    const session_hex: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
    const pa = [_]u8{'a'} ** 32;
    const pb = [_]u8{'b'} ** 32;
    const fu = [_]u8{'f'} ** 32;

    // Build a detached-session snapshot: a tab with an h-split of two panes,
    // and a sticky, all-tabs-visible float (tab_visible = maxInt(u64)).
    var snapshot = try core.session_model.SessionSnapshot.initMinimal(allocator, session_hex, "persisted");
    const first = try allocator.create(SLN);
    first.* = .{ .pane = pa };
    const second = try allocator.create(SLN);
    second.* = .{ .pane = pb };
    const root = try allocator.create(SLN);
    root.* = .{ .split = .{ .dir = .horizontal, .ratio = 0.5, .first = first, .second = second } };
    try snapshot.tabs.append(allocator, .{
        .uuid = [_]u8{'t'} ** 32,
        .name = try allocator.dupe(u8, "T"),
        .root = root,
        .focused_pane_uuid = pa,
        .allocator = allocator,
    });
    try snapshot.floats.append(allocator, .{
        .pane_uuid = fu,
        .parent_tab = null,
        .visible = true,
        .tab_visible = std.math.maxInt(u64),
        .sticky = true,
        .is_pwd = true,
        .float_key = 'g',
        .width_pct = 72,
        .height_pct = 48,
    });
    try snapshot.panes.put(fu, .{ .uuid = fu, .kind = .float, .sticky = true, .is_pwd = true, .float_key = 'g' });

    const pane_uuids = try allocator.alloc([32]u8, 1);
    pane_uuids[0] = fu;

    // Ownership of `snapshot` + `pane_uuids` transfers to the store here;
    // `ses_state.deinit` frees them (no errdefer → no double-free on assert fail).
    try ses_state.store.detached_sessions.put(session_id, .{
        .session_id = session_id,
        .session_snapshot = snapshot,
        .pane_uuids = pane_uuids,
        .detached_at = std.time.timestamp(),
        .allocator = allocator,
    });

    // Serialize the whole store (FS-free), then restore the embedded snapshot
    // the way `persist.load` does (SessionSnapshot.fromJson).
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try persist.buildStateJson(allocator, &ses_state, &buf);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, buf.items, .{});
    defer parsed.deinit();
    const detached = parsed.value.object.get("detached_sessions").?.array;
    try testing.expectEqual(@as(usize, 1), detached.items.len);
    const snap_json = detached.items[0].object.get("session_snapshot").?.string;

    var restored = try core.session_model.SessionSnapshot.fromJson(allocator, snap_json);
    defer restored.deinit();

    // Float visibility bitmask survives daemon-crash recovery (the fix).
    try testing.expectEqual(@as(usize, 1), restored.floats.items.len);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), restored.floats.items[0].tab_visible);
    try testing.expect(restored.floats.items[0].sticky);
    try testing.expect(restored.floats.items[0].is_pwd);
    try testing.expectEqual(@as(u8, 72), restored.floats.items[0].width_pct);

    // Split layout structure survives.
    try testing.expectEqual(@as(usize, 1), restored.tabs.items.len);
    const rroot = restored.tabs.items[0].root orelse return error.TestUnexpectedResult;
    try testing.expect(rroot.* == .split);
    try testing.expectEqual(core.session_model.SessionSplitDir.horizontal, rroot.split.dir);
    try testing.expectEqualSlices(u8, &pa, &rroot.split.first.pane);
    try testing.expectEqualSlices(u8, &pb, &rroot.split.second.pane);
}

test "layout_template: restore a session layout tree from a saved template" {
    const allocator = testing.allocator;
    const layout_template = @import("layout_template.zig");

    // Saved-layout format: v[ pane(/a), h[ pane(/b), pane(no-cwd) ] ].
    const tmpl_json = "{\"type\":\"split\",\"dir\":\"v\",\"ratio\":0.5," ++
        "\"first\":{\"type\":\"pane\",\"cwd\":\"/a\"}," ++
        "\"second\":{\"type\":\"split\",\"dir\":\"h\",\"ratio\":0.3," ++
        "\"first\":{\"type\":\"pane\",\"cwd\":\"/b\"}," ++
        "\"second\":{\"type\":\"pane\"}}}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, tmpl_json, .{});
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 3), layout_template.countTemplateLeaves(parsed.value));

    // Cwds are collected in DFS leaf order (null where absent).
    var cwds: std.ArrayList(?[]const u8) = .empty;
    defer cwds.deinit(allocator);
    try layout_template.collectTemplateCwds(parsed.value, &cwds, allocator);
    try testing.expectEqual(@as(usize, 3), cwds.items.len);
    try testing.expectEqualStrings("/a", cwds.items[0].?);
    try testing.expectEqualStrings("/b", cwds.items[1].?);
    try testing.expect(cwds.items[2] == null);

    // Build the tree, assigning freshly-created pane uuids in DFS order.
    const pua = [_]u8{'1'} ** 32;
    const pub_ = [_]u8{'2'} ** 32;
    const puc = [_]u8{'3'} ** 32;
    const uuids = [_][32]u8{ pua, pub_, puc };
    var idx: usize = 0;
    const root = try layout_template.buildTemplateLayoutNode(allocator, parsed.value, &uuids, &idx);
    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }
    try testing.expectEqual(@as(usize, 3), idx);

    try testing.expect(root.* == .split);
    try testing.expectEqual(core.session_model.SessionSplitDir.vertical, root.split.dir);
    try testing.expectEqualSlices(u8, &pua, &root.split.first.pane);
    try testing.expect(root.split.second.* == .split);
    try testing.expectEqual(core.session_model.SessionSplitDir.horizontal, root.split.second.split.dir);
    try testing.expectEqualSlices(u8, &pub_, &root.split.second.split.first.pane);
    try testing.expectEqualSlices(u8, &puc, &root.split.second.split.second.pane);

    // Round-trip the uuids back out in the same DFS order.
    var collected: std.ArrayList([32]u8) = .empty;
    defer collected.deinit(allocator);
    try layout_template.collectLayoutPaneUuids(allocator, root, &collected);
    try testing.expectEqual(@as(usize, 3), collected.items.len);
    try testing.expectEqualSlices(u8, &pua, &collected.items[0]);
    try testing.expectEqualSlices(u8, &pub_, &collected.items[1]);
    try testing.expectEqualSlices(u8, &puc, &collected.items[2]);
}

test "layout_template: malformed template nodes are rejected" {
    const allocator = testing.allocator;
    const layout_template = @import("layout_template.zig");
    const uuids = [_][32]u8{};

    const bogus = try std.json.parseFromSlice(std.json.Value, allocator, "{\"type\":\"bogus\"}", .{});
    defer bogus.deinit();
    var idxa: usize = 0;
    try testing.expectError(error.InvalidNode, layout_template.buildTemplateLayoutNode(allocator, bogus.value, &uuids, &idxa));

    // A pane node with no remaining uuid to assign fails too.
    const pane = try std.json.parseFromSlice(std.json.Value, allocator, "{\"type\":\"pane\"}", .{});
    defer pane.deinit();
    var idxb: usize = 0;
    try testing.expectError(error.InvalidNode, layout_template.buildTemplateLayoutNode(allocator, pane.value, &uuids, &idxb));
}

test "store.allocPaneId: increments, skips 0, wraps to 1" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();
    const store = &ses_state.store;

    try testing.expectEqual(@as(u16, 1), store.allocPaneId());
    try testing.expectEqual(@as(u16, 2), store.allocPaneId());

    // At the u16 ceiling the next id wraps past 0 straight to 1 — a pane id of
    // 0 (the "no pane" sentinel) must never be handed out.
    store.next_pane_id = std.math.maxInt(u16);
    try testing.expectEqual(std.math.maxInt(u16), store.allocPaneId());
    try testing.expectEqual(@as(u16, 1), store.next_pane_id);
    try testing.expectEqual(@as(u16, 1), store.allocPaneId());
}

test "store closed-fd log: two-generation shield ages an fd out after two rotations" {
    var ses_state = state.SesState.init(testing.allocator);
    defer ses_state.deinit();
    const store = &ses_state.store;

    // A freshly-noted fd is shielded; an unrelated fd is not. This shielding is
    // what stops a reattached mux that reused an fd number from being torn down
    // by a late pending-close for the OLD connection.
    store.noteClosedFd(5);
    try testing.expect(store.closedFdNoted(5));
    try testing.expect(!store.closedFdNoted(6));

    // Survives one rotation (now in the previous generation).
    store.rotateClosedFdLog();
    try testing.expect(store.closedFdNoted(5));

    // A newly-noted fd coexists in the current generation.
    store.noteClosedFd(7);
    try testing.expect(store.closedFdNoted(5));
    try testing.expect(store.closedFdNoted(7));

    // Second rotation ages fd 5 out; fd 7 survives its first rotation.
    store.rotateClosedFdLog();
    try testing.expect(!store.closedFdNoted(5));
    try testing.expect(store.closedFdNoted(7));
}
