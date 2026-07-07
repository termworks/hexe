const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ipc = core.ipc;
const wire = core.wire;
const ses = @import("main.zig");
const store_mod = @import("store.zig");

pub const SpawnResult = struct {
    pod_pid: posix.pid_t,
    child_pid: posix.pid_t,
};

pub fn generateUniquePaneName(
    allocator: std.mem.Allocator,
    store: *store_mod.SessionStore,
    base: []const u8,
) ![]const u8 {
    // Names are per-ses daemon, so keep them unique among all panes we track.
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const candidate = if (attempt == 0)
            try allocator.dupe(u8, base)
        else
            try std.fmt.allocPrint(allocator, "{s}-{d}", .{ base, attempt + 1 });

        var used = false;
        var it = store.panes.valueIterator();
        while (it.next()) |p| {
            if (p.name) |n| {
                if (std.mem.eql(u8, n, candidate)) {
                    used = true;
                    break;
                }
            }
        }

        if (!used) return candidate;
        allocator.free(candidate);
    }
}

pub fn spawnPod(
    allocator: std.mem.Allocator,
    uuid: [32]u8,
    name: []const u8,
    pod_socket_path: []const u8,
    shell: []const u8,
    cwd: ?[]const u8,
    env: ?[]const []const u8,
    isolation_profile: ?[]const u8,
) !SpawnResult {
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(allocator);

    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    try args_list.append(allocator, exe_path);
    try args_list.append(allocator, "pod");
    try args_list.append(allocator, "daemon");

    // Propagate instance/test-only flags for debugging/clarity.
    // Runtime behavior is primarily controlled by environment (HEXE_INSTANCE).
    if (posix.getenv("HEXE_INSTANCE")) |inst| {
        if (inst.len > 0) {
            try args_list.append(allocator, "--instance");
            try args_list.append(allocator, inst);
        }
    }
    if (posix.getenv("HEXE_TEST_ONLY")) |v| {
        if (v.len > 0 and !std.mem.eql(u8, v, "0")) {
            try args_list.append(allocator, "--test-only");
        }
    }

    try args_list.append(allocator, "--uuid");
    try args_list.append(allocator, uuid[0..]);
    try args_list.append(allocator, "--name");
    try args_list.append(allocator, name);
    try args_list.append(allocator, "--socket");
    try args_list.append(allocator, pod_socket_path);
    try args_list.append(allocator, "--shell");
    try args_list.append(allocator, shell);
    if (cwd) |dir| {
        try args_list.append(allocator, "--cwd");
        try args_list.append(allocator, dir);
    }
    if (ses.active_log_level) |level| {
        try args_list.append(allocator, "--log");
        try args_list.append(allocator, @tagName(level));
    }
    if (ses.log_file_path) |path| {
        try args_list.append(allocator, "--logfile");
        try args_list.append(allocator, path);
    }
    try args_list.append(allocator, "--foreground");

    ses.traceLog(
        "spawnPod uuid={s} name={s} socket={s} shell={s} cwd={s} log_level={s}",
        .{
            uuid[0..8],
            name,
            pod_socket_path,
            shell,
            cwd orelse "(none)",
            if (ses.active_log_level) |level| @tagName(level) else "off",
        },
    );

    var child = std.process.Child.init(args_list.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Pipe;

    var env_map_storage: ?std.process.EnvMap = null;
    defer if (env_map_storage) |*map| map.deinit();

    const instance_env = posix.getenv("HEXE_INSTANCE");
    const test_only_env = posix.getenv("HEXE_TEST_ONLY");
    const needs_runtime_env = (instance_env != null and instance_env.?.len > 0) or
        (test_only_env != null and test_only_env.?.len > 0) or
        (isolation_profile != null and isolation_profile.?.len > 0);

    if (env != null or needs_runtime_env) {
        // Start from the current SES environment so spawned pods keep
        // basic runtime variables like PATH, HOME, and XDG_RUNTIME_DIR.
        // Ad-hoc float env is meant to overlay this, not replace it.
        var env_map = try std.process.getEnvMap(allocator);

        if (env) |vars| {
            for (vars) |entry| {
                const sep = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
                if (sep == 0 or sep + 1 > entry.len) continue;
                try env_map.put(entry[0..sep], entry[sep + 1 ..]);
            }
        }

        // Force instance/test-only values from this ses process.
        // This prevents user-provided env overrides from escaping the instance namespace.
        if (instance_env) |inst| {
            if (inst.len > 0) try env_map.put("HEXE_INSTANCE", inst);
        }
        if (test_only_env) |v| {
            if (v.len > 0) try env_map.put("HEXE_TEST_ONLY", v);
        }

        if (isolation_profile) |profile| {
            if (profile.len > 0) {
                ses.debugLog("spawnPod: setting HEXE_VOIDBOX_PROFILE={s}", .{profile});
                try env_map.put("HEXE_VOIDBOX_PROFILE", profile);
            }
        } else {
            ses.debugLog("spawnPod: isolation_profile is null", .{});
        }

        env_map_storage = env_map;
        child.env_map = &env_map_storage.?;
        ses.traceLog("spawnPod: custom env map entries={d}", .{env_map_storage.?.count()});
    }

    try child.spawn();
    const pod_pid: posix.pid_t = @intCast(child.id);

    var stdout_file = child.stdout orelse return error.PodNoStdout;
    defer stdout_file.close();

    const spawn_timeout_ms: i64 = core.constants.Timing.ses_spawn_timeout;
    const deadline_ms = std.time.milliTimestamp() + spawn_timeout_ms;
    const stdout_fd = stdout_file.handle;

    var line_buf: [512]u8 = undefined;
    var pos: usize = 0;
    while (pos < line_buf.len) {
        const remaining_ms = deadline_ms - std.time.milliTimestamp();
        if (remaining_ms <= 0) return error.PodSpawnTimeout;

        wire.waitReadableTimeout(stdout_fd, @intCast(remaining_ms)) catch |err| switch (err) {
            error.Timeout => return error.PodSpawnTimeout,
            else => return err,
        };

        var one: [1]u8 = undefined;
        const n = try stdout_file.read(&one);
        if (n == 0) break;
        if (one[0] == '\n') break;
        line_buf[pos] = one[0];
        pos += 1;
    }
    if (pos == 0) return error.PodNoHandshake;
    const line = line_buf[0..pos];

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    // Validate the shape: anything writing to the pod's stdout before the
    // handshake (shell profile noise, wrapper output) can produce valid JSON
    // of the wrong type, and unchecked union accesses would be safety-checked
    // illegal behavior in the daemon.
    if (parsed.value != .object) return error.PodBadHandshake;
    const root = parsed.value.object;
    const pid_node = root.get("pid") orelse return error.PodBadHandshake;
    if (pid_node != .integer) return error.PodBadHandshake;
    const pid_val = pid_node.integer;
    if (pid_val <= 0 or pid_val > std.math.maxInt(posix.pid_t)) return error.PodBadHandshake;
    const child_pid: posix.pid_t = @intCast(pid_val);

    return .{ .pod_pid = pod_pid, .child_pid = child_pid };
}
