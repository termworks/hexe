const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const state = @import("state.zig");
const log = std.log.scoped(.session_persist);

// Caps applied while parsing a (possibly corrupted or adversarial) session
// state file. A field longer than its cap causes the pane/session entry to be
// skipped with a warning rather than inflating daemon memory.
const MAX_SOCKET_PATH: usize = 256;
const MAX_STICKY_PWD: usize = 4096;
const MAX_PANES_PER_SESSION: usize = 1024;
const SESSION_STATE_VERSION: i64 = 1;

fn syncDirBestEffort(dir: std.fs.Dir) !void {
    const rc = std.os.linux.fsync(dir.fd);
    switch (std.os.linux.E.init(rc)) {
        .SUCCESS => return,
        // Some filesystems or descriptor modes reject directory fsync. This
        // is a durability downgrade, not a reason to panic the daemon after
        // the state file was already atomically renamed.
        .BADF, .INVAL, .ROFS => return,
        .IO => return error.InputOutput,
        .NOSPC => return error.NoSpaceLeft,
        .DQUOT => return error.DiskQuota,
        else => |err| {
            log.warn("unexpected directory fsync errno: {}", .{err});
            return error.InputOutput;
        },
    }
}

pub fn parseSessionIdHex(hex: []const u8) ?[16]u8 {
    if (hex.len != 32) return null;
    var session_id: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&session_id, hex) catch |err| {
        log.warn("failed to parse persisted session id hex: {}", .{err});
        return null;
    };
    return session_id;
}

pub fn parseStoredUuidHex(hex: []const u8) ?[32]u8 {
    if (hex.len != 32) return null;
    var decoded: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&decoded, hex) catch |err| {
        log.warn("failed to parse persisted pane uuid hex: {}", .{err});
        return null;
    };
    var uuid: [32]u8 = undefined;
    @memcpy(&uuid, hex[0..32]);
    return uuid;
}

pub fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

fn jsonObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn jsonArray(value: std.json.Value) ?std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => null,
    };
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn jsonI64(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |integer| integer,
        else => null,
    };
}

fn jsonPid(value: std.json.Value) ?std.posix.pid_t {
    return std.math.cast(std.posix.pid_t, jsonI64(value) orelse return null);
}

fn jsonU8(value: std.json.Value) ?u8 {
    return std.math.cast(u8, jsonI64(value) orelse return null);
}

pub fn save(allocator: std.mem.Allocator, ses_state: *state.SesState) !void {
    const path = try ipc.getSesStatePath(allocator);
    defer allocator.free(path);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buildStateJson(allocator, ses_state, &buf);

    // Atomic overwrite: write tmp then rename.
    {
        var file = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true, .mode = 0o600 });
        defer file.close();
        try file.writeAll(buf.items);
        try file.sync();
    }
    try std.fs.renameAbsolute(tmp_path, path);

    // fsync the parent directory so the rename is durable. Without this a
    // crash between rename and directory commit could lose the update even
    // though the data file itself reached disk.
    if (std.fs.path.dirname(path)) |dir_path| {
        if (std.fs.openDirAbsolute(dir_path, .{})) |d| {
            var dir = d;
            defer dir.close();
            try syncDirBestEffort(dir);
        } else |_| {}
    }
}

/// Serialize the canonical store to the persisted JSON shape. Split out from
/// `save` so the serialization (including attached-session recovery) can be
/// unit-tested without touching the filesystem.
pub fn buildStateJson(allocator: std.mem.Allocator, ses_state: *state.SesState, buf: *std.ArrayList(u8)) !void {
    const w = buf.writer(allocator);

    try w.writeAll("{\"version\":");
    try w.print("{d},", .{SESSION_STATE_VERSION});

    // panes
    try w.writeAll("\"panes\":[");
    var pit = ses_state.store.panes.valueIterator();
    var first: bool = true;
    while (pit.next()) |p| {
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("{\"uuid\":");
        try writeJsonString(w, &p.uuid);
        try w.print(",\"pod_pid\":{d},\"child_pid\":{d},\"socket\":", .{
            p.pod_pid,
            p.child_pid,
        });
        try writeJsonString(w, p.pod_socket_path);
        try w.writeAll(",\"state\":");
        try writeJsonString(w, @tagName(p.state));
        // Intentionally do not persist pane.name.
        if (p.sticky_pwd) |pwd| {
            try w.writeAll(",\"sticky_pwd\":");
            try writeJsonString(w, pwd);
        }
        if (p.sticky_key) |key| {
            try w.print(",\"sticky_key\":{d}", .{key});
        }
        if (p.sticky_session_name) |ssn| {
            try w.writeAll(",\"sticky_session_name\":");
            try writeJsonString(w, ssn);
        }
        if (p.session_id) |sid| {
            const hex_id: [32]u8 = std.fmt.bytesToHex(&sid, .lower);
            try w.writeAll(",\"session_id\":");
            try writeJsonString(w, &hex_id);
        }
        try w.writeAll("}");
    }
    try w.writeAll("],");

    // detached sessions
    try w.writeAll("\"detached_sessions\":[");
    var sit = ses_state.store.detached_sessions.valueIterator();
    first = true;
    while (sit.next()) |s| {
        if (!first) try w.writeAll(",");
        first = false;
        const hex_id: [32]u8 = std.fmt.bytesToHex(&s.session_id, .lower);
        const snapshot_json = try s.session_snapshot.toJson(allocator);
        defer allocator.free(snapshot_json);
        try w.writeAll("{\"session_id\":");
        try writeJsonString(w, &hex_id);
        try w.writeAll(",\"session_name\":");
        try writeJsonString(w, s.session_snapshot.session_name);
        try w.print(",\"detached_at\":{d},\"session_snapshot\":", .{s.detached_at});
        try writeJsonString(w, snapshot_json);
        try w.writeAll(",\"panes\":[");
        for (s.pane_uuids, 0..) |uuid, i| {
            if (i > 0) try w.writeAll(",");
            try writeJsonString(w, &uuid);
        }
        try w.writeAll("]}");
    }

    // Also persist ATTACHED sessions as recoverable detached entries. Without
    // this, a daemon crash while a session is attached loses the whole layout
    // (only the loose panes survive in panes[]); on restart the session
    // reappears as detached and the frontend can reattach by id/name. The
    // panes load unowned and are re-adopted by the reattach flow.
    const now = std.time.timestamp();
    for (ses_state.store.clients.items) |*client| {
        const sid = client.session_id orelse continue;
        if (client.session_snapshot == null) continue;
        const snapshot = &client.session_snapshot.?;
        // Skip if this session is already represented as detached.
        if (ses_state.store.detached_sessions.contains(sid)) continue;

        const hex_id: [32]u8 = std.fmt.bytesToHex(&sid, .lower);
        const snapshot_json = try snapshot.toJson(allocator);
        defer allocator.free(snapshot_json);
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("{\"session_id\":");
        try writeJsonString(w, &hex_id);
        try w.writeAll(",\"session_name\":");
        try writeJsonString(w, snapshot.session_name);
        try w.print(",\"detached_at\":{d},\"session_snapshot\":", .{now});
        try writeJsonString(w, snapshot_json);
        try w.writeAll(",\"panes\":[");
        for (client.pane_uuids.items, 0..) |uuid, i| {
            if (i > 0) try w.writeAll(",");
            try writeJsonString(w, &uuid);
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");

    try w.writeAll("}\n");
}

/// Move an unreadable state file aside instead of leaving it in place, where
/// the first dirty save would atomically overwrite it and destroy the only
/// copy of the user's sessions. The `.corrupt` copy allows manual recovery.
fn quarantineStateFile(allocator: std.mem.Allocator, path: []const u8) void {
    const backup_path = std.fmt.allocPrint(allocator, "{s}.corrupt", .{path}) catch |err| {
        core.logging.logError("ses", "failed to build corrupt state backup path", err);
        return;
    };
    defer allocator.free(backup_path);
    std.fs.renameAbsolute(path, backup_path) catch |err| {
        core.logging.logError("ses", "failed to quarantine corrupt state file", err);
        return;
    };
    core.logging.warn("ses", "unreadable session state moved to {s}", .{backup_path});
}

pub fn load(_: std.mem.Allocator, ses_state: *state.SesState) !void {
    const tmp_alloc = std.heap.page_allocator;

    const path = try ipc.getSesStatePath(tmp_alloc);
    defer tmp_alloc.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch {
        return;
    };
    defer file.close();

    const data = try file.readToEndAlloc(tmp_alloc, 8 * 1024 * 1024);
    defer tmp_alloc.free(data);

    const parsed = std.json.parseFromSlice(std.json.Value, tmp_alloc, data, .{}) catch |err| {
        core.logging.logError("ses", "failed to parse persisted session state", err);
        quarantineStateFile(tmp_alloc, path);
        return;
    };
    defer parsed.deinit();

    const root = jsonObject(parsed.value) orelse {
        quarantineStateFile(tmp_alloc, path);
        return;
    };
    const version = jsonI64(root.get("version") orelse {
        core.logging.warn("ses", "ignoring persisted session state without version", .{});
        quarantineStateFile(tmp_alloc, path);
        return;
    }) orelse {
        core.logging.warn("ses", "ignoring persisted session state with invalid version", .{});
        quarantineStateFile(tmp_alloc, path);
        return;
    };
    if (version != SESSION_STATE_VERSION) {
        core.logging.warn("ses", "ignoring persisted session state version {d}; expected {d}", .{ version, SESSION_STATE_VERSION });
        quarantineStateFile(tmp_alloc, path);
        return;
    }

    if (root.get("panes")) |panes_val| {
        const panes = jsonArray(panes_val) orelse return;
        for (panes.items) |pane_val| {
            const obj = jsonObject(pane_val) orelse continue;
            const uuid_str = jsonString(obj.get("uuid") orelse continue) orelse continue;
            const socket_str = jsonString(obj.get("socket") orelse continue) orelse continue;
            if (socket_str.len == 0 or socket_str.len > MAX_SOCKET_PATH) continue;

            const uuid = parseStoredUuidHex(uuid_str) orelse continue;

            const pod_pid = jsonPid(obj.get("pod_pid") orelse continue) orelse continue;
            const child_pid = jsonPid(obj.get("child_pid") orelse continue) orelse continue;

            // Verify pod process is still running before restoring.
            // kill(pid, 0) checks process existence without sending a signal.
            if (std.posix.kill(pod_pid, 0)) |_| {
                // Process exists, continue
            } else |_| {
                // Process doesn't exist, skip this pane
                continue;
            }

            const state_str = jsonString(obj.get("state") orelse continue) orelse continue;

            const owned_socket = try ses_state.allocator.dupe(u8, socket_str);

            const sticky_pwd: ?[]const u8 = if (obj.get("sticky_pwd")) |p|
                if (jsonString(p)) |pwd|
                    (if (pwd.len > MAX_STICKY_PWD) null else try ses_state.allocator.dupe(u8, pwd))
                else
                    null
            else
                null;
            const sticky_key: ?u8 = if (obj.get("sticky_key")) |k| jsonU8(k) else null;
            const sticky_session_name: ?[]const u8 = if (obj.get("sticky_session_name")) |v|
                if (jsonString(v)) |ssn|
                    (if (ssn.len > MAX_STICKY_PWD) null else try ses_state.allocator.dupe(u8, ssn))
                else
                    null
            else
                null;

            const stored_state: state.PaneState = if (std.mem.eql(u8, state_str, "attached")) .attached else if (std.mem.eql(u8, state_str, "detached")) .detached else if (std.mem.eql(u8, state_str, "sticky")) .sticky else .orphaned;
            const pane_state: state.PaneState = if (stored_state == .attached)
                if (sticky_pwd != null and sticky_key != null) .sticky else .orphaned
            else
                stored_state;

            // Intentionally do not load pane.name.
            const name: ?[]const u8 = null;

            var session_id: ?[16]u8 = null;
            if (obj.get("session_id")) |sid_val| {
                if (jsonString(sid_val)) |sid_hex| {
                    session_id = parseSessionIdHex(sid_hex);
                }
            }

            const pane = state.Pane{
                .uuid = uuid,
                .name = name,
                .pod_pid = pod_pid,
                .pod_socket_path = owned_socket,
                .child_pid = child_pid,
                .state = pane_state,
                // pane_id is an ephemeral SES-side routing id: it is not
                // persisted, so every recovered pane must get a fresh one.
                // Leaving the default (0) gives ALL recovered panes the same
                // id and corrupts the pane_id->pod VT routing tables.
                .pane_id = ses_state.store.allocPaneId(),
                .sticky_pwd = sticky_pwd,
                .sticky_key = sticky_key,
                .sticky_session_name = sticky_session_name,
                .attached_to = null,
                .session_id = session_id,
                .created_at = std.time.timestamp(),
                // Restart the cleanup clock: recovered panes are unowned, and
                // a null orphaned_at makes the orphan-timeout sweep skip them
                // forever.
                .orphaned_at = if (pane_state == .attached) null else std.time.timestamp(),
                .allocator = ses_state.allocator,
            };
            ses_state.store.panes.put(uuid, pane) catch {
                ses_state.allocator.free(owned_socket);
                if (name) |nn| ses_state.allocator.free(nn);
                if (sticky_pwd) |pwd| ses_state.allocator.free(pwd);
                if (sticky_session_name) |ssn| ses_state.allocator.free(ssn);
            };
        }
    }

    if (root.get("detached_sessions")) |sess_val| {
        const sessions = jsonArray(sess_val) orelse return;
        for (sessions.items) |sv| {
            const obj = jsonObject(sv) orelse continue;
            const sid_hex = jsonString(obj.get("session_id") orelse continue) orelse continue;
            const sid = parseSessionIdHex(sid_hex) orelse continue;

            const name = jsonString(obj.get("session_name") orelse continue) orelse continue;
            const detached_at = jsonI64(obj.get("detached_at") orelse continue) orelse continue;
            const session_state = if (obj.get("session_snapshot")) |v|
                jsonString(v) orelse continue
            else if (obj.get("mux_state")) |v|
                jsonString(v) orelse continue
            else
                continue;
            const panes_arr = jsonArray(obj.get("panes") orelse continue) orelse continue;
            if (panes_arr.items.len > MAX_PANES_PER_SESSION) continue;

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

            var pane_uuid_list: std.ArrayList([32]u8) = .empty;
            errdefer pane_uuid_list.deinit(ses_state.allocator);
            for (panes_arr.items) |pu| {
                const u = jsonString(pu) orelse continue;
                const pane_uuid = parseStoredUuidHex(u) orelse continue;
                try pane_uuid_list.append(ses_state.allocator, pane_uuid);
            }
            const pane_uuids = try pane_uuid_list.toOwnedSlice(ses_state.allocator);
            errdefer ses_state.allocator.free(pane_uuids);

            const detached = state.DetachedSessionState{
                .session_id = sid,
                .session_snapshot = snapshot,
                .pane_uuids = pane_uuids,
                .detached_at = detached_at,
                .allocator = ses_state.allocator,
            };
            ses_state.store.detached_sessions.put(sid, detached) catch {
                var d = detached;
                d.deinit();
            };
        }
    }
}
