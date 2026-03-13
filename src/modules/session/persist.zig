const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const state = @import("state.zig");

pub fn save(allocator: std.mem.Allocator, ses_state: *state.SesState) !void {
    const path = try ipc.getSesStatePath(allocator);
    defer allocator.free(path);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("{");

    // panes
    try w.writeAll("\"panes\":[");
    var pit = ses_state.panes.valueIterator();
    var first: bool = true;
    while (pit.next()) |p| {
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("{{\"uuid\":\"{s}\",\"pod_pid\":{d},\"child_pid\":{d},\"socket\":\"{s}\",\"state\":\"{s}\"", .{
            p.uuid,
            p.pod_pid,
            p.child_pid,
            p.pod_socket_path,
            @tagName(p.state),
        });
        // Intentionally do not persist pane.name.
        if (p.sticky_pwd) |pwd| {
            try w.print(",\"sticky_pwd\":\"{s}\"", .{pwd});
        }
        if (p.sticky_key) |key| {
            try w.print(",\"sticky_key\":{d}", .{key});
        }
        if (p.session_id) |sid| {
            const hex_id: [32]u8 = std.fmt.bytesToHex(&sid, .lower);
            try w.print(",\"session_id\":\"{s}\"", .{&hex_id});
        }
        try w.writeAll("}");
    }
    try w.writeAll("],");

    // detached sessions
    try w.writeAll("\"detached_sessions\":[");
    var sit = ses_state.detached_sessions.valueIterator();
    first = true;
    while (sit.next()) |s| {
        if (!first) try w.writeAll(",");
        first = false;
        const hex_id: [32]u8 = std.fmt.bytesToHex(&s.session_id, .lower);
        const snapshot_json = try s.session_snapshot.toJson(allocator);
        defer allocator.free(snapshot_json);
        try w.print("{{\"session_id\":\"{s}\",\"session_name\":\"{s}\",\"detached_at\":{d},\"session_snapshot\":\"", .{
            &hex_id,
            s.session_snapshot.session_name,
            s.detached_at,
        });
        for (snapshot_json) |c| {
            switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                else => try w.writeByte(c),
            }
        }
        try w.writeAll("\",\"panes\":[");
        for (s.pane_uuids, 0..) |uuid, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("\"{s}\"", .{uuid});
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");

    try w.writeAll("}\n");

    // Atomic overwrite: write tmp then rename.
    {
        var file = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(buf.items);
        try file.sync();
    }
    try std.fs.renameAbsolute(tmp_path, path);
}

pub fn load(_: std.mem.Allocator, ses_state: *state.SesState) !void {
    // Use page_allocator for ALL temporary allocations to avoid GPA issues after fork.
    // Only ses_state.allocator is used for final owned data that persists.
    const tmp_alloc = std.heap.page_allocator;

    const path = try ipc.getSesStatePath(tmp_alloc);
    defer tmp_alloc.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch {
        return;
    };
    defer file.close();

    const data = try file.readToEndAlloc(tmp_alloc, 8 * 1024 * 1024);
    defer tmp_alloc.free(data);

    const parsed = std.json.parseFromSlice(std.json.Value, tmp_alloc, data, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value.object;

    if (root.get("panes")) |panes_val| {
        for (panes_val.array.items) |pane_val| {
            const obj = pane_val.object;
            const uuid_str = (obj.get("uuid") orelse continue).string;
            const socket_str = (obj.get("socket") orelse continue).string;
            if (uuid_str.len != 32) continue;

            var uuid: [32]u8 = undefined;
            @memcpy(&uuid, uuid_str[0..32]);

            const pod_pid: std.posix.pid_t = @intCast((obj.get("pod_pid") orelse continue).integer);
            const child_pid: std.posix.pid_t = @intCast((obj.get("child_pid") orelse continue).integer);

            // Verify pod process is still running before restoring.
            // kill(pid, 0) checks process existence without sending a signal.
            if (std.posix.kill(pod_pid, 0)) |_| {
                // Process exists, continue
            } else |_| {
                // Process doesn't exist, skip this pane
                continue;
            }

            const state_str = (obj.get("state") orelse continue).string;
            const pane_state: state.PaneState = if (std.mem.eql(u8, state_str, "attached")) .attached else if (std.mem.eql(u8, state_str, "detached")) .detached else if (std.mem.eql(u8, state_str, "sticky")) .sticky else .orphaned;

            const owned_socket = try ses_state.allocator.dupe(u8, socket_str);

            const sticky_pwd: ?[]const u8 = if (obj.get("sticky_pwd")) |p| try ses_state.allocator.dupe(u8, p.string) else null;
            const sticky_key: ?u8 = if (obj.get("sticky_key")) |k| @intCast(k.integer) else null;

            // Intentionally do not load pane.name.
            const name: ?[]const u8 = null;

            var session_id: ?[16]u8 = null;
            if (obj.get("session_id")) |sid_val| {
                const sid_hex = sid_val.string;
                if (sid_hex.len == 32) {
                    var sid: [16]u8 = undefined;
                    _ = std.fmt.hexToBytes(&sid, sid_hex) catch {};
                    session_id = sid;
                }
            }

            const pane = state.Pane{
                .uuid = uuid,
                .name = name,
                .pod_pid = pod_pid,
                .pod_socket_path = owned_socket,
                .child_pid = child_pid,
                .state = pane_state,
                .sticky_pwd = sticky_pwd,
                .sticky_key = sticky_key,
                .attached_to = null,
                .session_id = session_id,
                .created_at = std.time.timestamp(),
                .orphaned_at = null,
                .allocator = ses_state.allocator,
            };
            ses_state.panes.put(uuid, pane) catch {
                ses_state.allocator.free(owned_socket);
                if (name) |nn| ses_state.allocator.free(nn);
                if (sticky_pwd) |pwd| ses_state.allocator.free(pwd);
            };
        }
    }

    if (root.get("detached_sessions")) |sess_val| {
        for (sess_val.array.items) |sv| {
            const obj = sv.object;
            const sid_hex = (obj.get("session_id") orelse continue).string;
            if (sid_hex.len != 32) continue;
            var sid: [16]u8 = undefined;
            _ = std.fmt.hexToBytes(&sid, sid_hex) catch continue;

            const name = (obj.get("session_name") orelse continue).string;
            const detached_at: i64 = @intCast((obj.get("detached_at") orelse continue).integer);
            const session_state = if (obj.get("session_snapshot")) |v| v.string else if (obj.get("mux_state")) |v| v.string else continue;
            const panes_arr = (obj.get("panes") orelse continue).array;

            const state_owned = try ses_state.allocator.dupe(u8, session_state);
            errdefer ses_state.allocator.free(state_owned);
            const snapshot = state.SessionSnapshot.fromJson(ses_state.allocator, state_owned) catch blk: {
                const hex_sid: [32]u8 = std.fmt.bytesToHex(&sid, .lower);
                break :blk try state.SessionSnapshot.initMinimal(ses_state.allocator, hex_sid, name);
            };
            errdefer {
                var owned_snapshot = snapshot;
                owned_snapshot.deinit();
            }

            const pane_uuids = try ses_state.allocator.alloc([32]u8, panes_arr.items.len);
            errdefer ses_state.allocator.free(pane_uuids);
            for (panes_arr.items, 0..) |pu, i| {
                const u = pu.string;
                if (u.len == 32) {
                    @memcpy(&pane_uuids[i], u[0..32]);
                } else {
                    @memset(&pane_uuids[i], 0);
                }
            }

            const detached = state.DetachedSessionState{
                .session_id = sid,
                .session_snapshot = snapshot,
                .pane_uuids = pane_uuids,
                .detached_at = detached_at,
                .allocator = ses_state.allocator,
            };
            ses_state.detached_sessions.put(sid, detached) catch {
                var d = detached;
                d.deinit();
            };
        }
    }
}
