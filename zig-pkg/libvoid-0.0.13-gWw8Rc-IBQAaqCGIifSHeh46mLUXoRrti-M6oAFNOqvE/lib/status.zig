const std = @import("std");
const StatusOptions = @import("config.zig").StatusOptions;

pub const NamespaceIds = StatusOptions.NamespaceIds;

pub fn emitSpawned(fd: i32, pid: std.posix.pid_t, ns_ids: NamespaceIds) !void {
    const ts = std.time.timestamp();

    var file = std.fs.File{ .handle = fd };
    var writer = file.deprecatedWriter();

    try writer.print("{{\"event\":\"spawned\",\"pid\":{},\"ts\":{},\"ns\":{{", .{ pid, ts });
    try writeOptionalU64(writer, "user", ns_ids.user);
    try writer.print(",", .{});
    try writeOptionalU64(writer, "pid", ns_ids.pid);
    try writer.print(",", .{});
    try writeOptionalU64(writer, "net", ns_ids.net);
    try writer.print(",", .{});
    try writeOptionalU64(writer, "mount", ns_ids.mount);
    try writer.print(",", .{});
    try writeOptionalU64(writer, "uts", ns_ids.uts);
    try writer.print(",", .{});
    try writeOptionalU64(writer, "ipc", ns_ids.ipc);
    try writer.print("}}}}\n", .{});
}

pub fn emitExited(fd: i32, pid: std.posix.pid_t, exit_code: u8) !void {
    const ts = std.time.timestamp();

    var file = std.fs.File{ .handle = fd };
    var writer = file.deprecatedWriter();
    try writer.print("{{\"event\":\"exited\",\"pid\":{},\"exit_code\":{},\"ts\":{}}}\n", .{ pid, exit_code, ts });
}

pub fn emitSpawnedWithOptions(options: StatusOptions, pid: std.posix.pid_t, ns_ids: NamespaceIds) !void {
    const event: StatusOptions.Event = .{
        .kind = .spawned,
        .pid = pid,
        .timestamp = std.time.timestamp(),
        .ns_ids = ns_ids,
    };
    try emitEvent(options, event);
}

pub fn emitRuntimeInitWarningsWithOptions(options: StatusOptions, warning_count: usize) !void {
    const clipped: u16 = @intCast(@min(warning_count, std.math.maxInt(u16)));
    const event: StatusOptions.Event = .{
        .kind = .runtime_init_warnings,
        .pid = 0,
        .timestamp = std.time.timestamp(),
        .warning_count = clipped,
    };
    try emitEvent(options, event);
}

pub fn emitExitedWithOptions(options: StatusOptions, pid: std.posix.pid_t, exit_code: u8) !void {
    const event: StatusOptions.Event = .{
        .kind = .exited,
        .pid = pid,
        .timestamp = std.time.timestamp(),
        .exit_code = exit_code,
    };
    try emitEvent(options, event);
}

pub fn emitSetupFinishedWithOptions(options: StatusOptions, pid: std.posix.pid_t, ns_ids: NamespaceIds) !void {
    const event: StatusOptions.Event = .{
        .kind = .setup_finished,
        .pid = pid,
        .timestamp = std.time.timestamp(),
        .ns_ids = ns_ids,
    };
    try emitEvent(options, event);
}

fn emitEvent(options: StatusOptions, event: StatusOptions.Event) !void {
    if (options.on_event) |cb| {
        try cb(options.callback_ctx, event);
    }

    if (options.info_fd) |fd| {
        try emitInfo(fd, event);
    }

    if (options.json_status_fd) |fd| {
        switch (event.kind) {
            .runtime_init_warnings => try emitRuntimeInitWarnings(fd, event.warning_count orelse 0),
            .spawned => try emitSpawned(fd, event.pid, event.ns_ids),
            .setup_finished => try emitSetupFinished(fd, event.pid, event.ns_ids),
            .exited => try emitExited(fd, event.pid, event.exit_code orelse 0),
        }
    }
}

fn emitRuntimeInitWarnings(fd: i32, warning_count: u16) !void {
    const ts = std.time.timestamp();
    var file = std.fs.File{ .handle = fd };
    var writer = file.deprecatedWriter();
    try writer.print("{{\"event\":\"runtime_init_warnings\",\"warning_count\":{},\"ts\":{}}}\n", .{ warning_count, ts });
}

fn emitSetupFinished(fd: i32, pid: std.posix.pid_t, ns_ids: NamespaceIds) !void {
    const ts = std.time.timestamp();
    var file = std.fs.File{ .handle = fd };
    var writer = file.deprecatedWriter();

    try writer.print("{{\"event\":\"setup_finished\",\"pid\":{},\"ts\":{},\"ns\":{{", .{ pid, ts });
    try writeOptionalU64(writer, "user", ns_ids.user);
    try writer.print(",", .{});
    try writeOptionalU64(writer, "pid", ns_ids.pid);
    try writer.print(",", .{});
    try writeOptionalU64(writer, "net", ns_ids.net);
    try writer.print(",", .{});
    try writeOptionalU64(writer, "mount", ns_ids.mount);
    try writer.print(",", .{});
    try writeOptionalU64(writer, "uts", ns_ids.uts);
    try writer.print(",", .{});
    try writeOptionalU64(writer, "ipc", ns_ids.ipc);
    try writer.print("}}}}\n", .{});
}

fn emitInfo(fd: i32, event: StatusOptions.Event) !void {
    var file = std.fs.File{ .handle = fd };
    var writer = file.deprecatedWriter();
    switch (event.kind) {
        .runtime_init_warnings => try writer.print("event=runtime_init_warnings warning_count={} ts={}\n", .{ event.warning_count orelse 0, event.timestamp }),
        .spawned => try writer.print("event=spawned pid={} ts={}\n", .{ event.pid, event.timestamp }),
        .setup_finished => try writer.print("event=setup_finished pid={} ts={}\n", .{ event.pid, event.timestamp }),
        .exited => try writer.print("event=exited pid={} exit_code={} ts={}\n", .{ event.pid, event.exit_code orelse 0, event.timestamp }),
    }
}

pub fn queryNamespaceIds(pid: std.posix.pid_t) !NamespaceIds {
    return .{
        .user = try readNamespaceId(pid, "user"),
        .pid = try readNamespaceId(pid, "pid"),
        .net = try readNamespaceId(pid, "net"),
        .mount = try readNamespaceId(pid, "mnt"),
        .uts = try readNamespaceId(pid, "uts"),
        .ipc = try readNamespaceId(pid, "ipc"),
    };
}

fn readNamespaceId(pid: std.posix.pid_t, name: []const u8) !?u64 {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/proc/{}/ns/{s}", .{ pid, name });

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link = std.fs.readLinkAbsolute(path, &link_buf) catch return null;
    return parseNamespaceInode(link);
}

fn parseNamespaceInode(link: []const u8) ?u64 {
    const start = std.mem.indexOfScalar(u8, link, '[') orelse return null;
    const end = std.mem.indexOfScalarPos(u8, link, start + 1, ']') orelse return null;
    if (end <= start + 1) return null;
    return std.fmt.parseInt(u64, link[start + 1 .. end], 10) catch null;
}

fn writeOptionalU64(writer: anytype, key: []const u8, value: ?u64) !void {
    if (value) |v| {
        try writer.print("\"{s}\":{}", .{ key, v });
    } else {
        try writer.print("\"{s}\":null", .{key});
    }
}

test "parseNamespaceInode parses inode from namespace link" {
    try std.testing.expectEqual(@as(?u64, 4026532000), parseNamespaceInode("net:[4026532000]"));
    try std.testing.expectEqual(@as(?u64, null), parseNamespaceInode("invalid"));
}

test "emitEvent invokes callback sink" {
    const Ctx = struct {
        called: bool = false,
        saw_kind: ?StatusOptions.EventKind = null,
    };

    const Fn = struct {
        fn onEvent(ctx: ?*anyopaque, event: StatusOptions.Event) !void {
            const typed: *Ctx = @ptrCast(@alignCast(ctx.?));
            typed.called = true;
            typed.saw_kind = event.kind;
        }
    };

    var ctx = Ctx{};
    const options = StatusOptions{
        .on_event = Fn.onEvent,
        .callback_ctx = &ctx,
    };

    try emitSetupFinishedWithOptions(options, 1234, .{});
    try std.testing.expect(ctx.called);
    try std.testing.expectEqual(StatusOptions.EventKind.setup_finished, ctx.saw_kind.?);
}

test "emitRuntimeInitWarningsWithOptions invokes callback sink" {
    const Ctx = struct {
        called: bool = false,
        saw_kind: ?StatusOptions.EventKind = null,
        warning_count: ?u16 = null,
    };

    const Fn = struct {
        fn onEvent(ctx: ?*anyopaque, event: StatusOptions.Event) !void {
            const typed: *Ctx = @ptrCast(@alignCast(ctx.?));
            typed.called = true;
            typed.saw_kind = event.kind;
            typed.warning_count = event.warning_count;
        }
    };

    var ctx = Ctx{};
    const options = StatusOptions{
        .on_event = Fn.onEvent,
        .callback_ctx = &ctx,
    };

    try emitRuntimeInitWarningsWithOptions(options, 3);
    try std.testing.expect(ctx.called);
    try std.testing.expectEqual(StatusOptions.EventKind.runtime_init_warnings, ctx.saw_kind.?);
    try std.testing.expectEqual(@as(?u16, 3), ctx.warning_count);
}

test "emitRuntimeInitWarningsWithOptions writes json status output" {
    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);
    defer std.posix.close(pipe_fds[1]);

    const options = StatusOptions{
        .json_status_fd = pipe_fds[1],
    };

    try emitRuntimeInitWarningsWithOptions(options, 7);

    var buf: [256]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    const out = buf[0..n];

    try std.testing.expect(std.mem.indexOf(u8, out, "\"event\":\"runtime_init_warnings\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"warning_count\":7") != null);
}

test "emitRuntimeInitWarningsWithOptions clips warning count in callback" {
    const Ctx = struct {
        warning_count: ?u16 = null,
    };

    const Fn = struct {
        fn onEvent(ctx: ?*anyopaque, event: StatusOptions.Event) !void {
            const typed: *Ctx = @ptrCast(@alignCast(ctx.?));
            typed.warning_count = event.warning_count;
        }
    };

    var ctx = Ctx{};
    const options = StatusOptions{
        .on_event = Fn.onEvent,
        .callback_ctx = &ctx,
    };

    try emitRuntimeInitWarningsWithOptions(options, std.math.maxInt(usize));
    try std.testing.expectEqual(@as(?u16, std.math.maxInt(u16)), ctx.warning_count);
}
