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

/// Fork `hexe pod daemon` and return immediately, WITHOUT reading its
/// handshake. The caller polls `pollPodHandshake` until it resolves.
pub fn startPodSpawn(
    allocator: std.mem.Allocator,
    uuid: [32]u8,
    name: []const u8,
    pod_socket_path: []const u8,
    shell: []const u8,
    cwd: ?[]const u8,
    env: ?[]const []const u8,
    isolation_profile: ?[]const u8,
) !PendingPodSpawn {
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

    const stdout_file = child.stdout orelse return error.PodNoStdout;
    // Non-blocking, so `pollHandshake` can be called from the event loop
    // without ever waiting on a slow pod (PLAN.md 1.1).
    core.ipc.setNonBlocking(stdout_file.handle) catch {};

    return .{
        .pod_pid = @intCast(child.id),
        .stdout_file = stdout_file,
        .deadline_ms = std.time.milliTimestamp() + core.constants.Timing.ses_spawn_timeout,
    };
}

/// A forked pod whose handshake line has not fully arrived yet.
///
/// `spawnPod` used to fork and then BLOCK reading this line, for up to
/// `ses_spawn_timeout`, on the single-threaded SES loop — so one slow pod
/// stalled every other session (PLAN.md 1.1). Splitting the fork from the read
/// lets the caller poll it from the periodic tick instead.
///
/// Owns `stdout_file`; whoever drops the spawn must call `deinit`.
pub const PendingPodSpawn = struct {
    pod_pid: posix.pid_t,
    stdout_file: std.fs.File,
    deadline_ms: i64,
    buf: [512]u8 = undefined,
    pos: usize = 0,

    pub fn deinit(self: *PendingPodSpawn) void {
        self.stdout_file.close();
    }

    pub fn expired(self: *const PendingPodSpawn, now_ms: i64) bool {
        return now_ms >= self.deadline_ms;
    }
};

pub const HandshakeProgress = union(enum) {
    /// Nothing to do yet; call again later.
    pending,
    /// Handshake parsed; this is the pod's shell pid.
    ready: posix.pid_t,
    /// Unusable (EOF, malformed, or oversized). The caller must reap the pod.
    failed,
};

/// Read whatever of the handshake line is available right now. Never blocks.
pub fn pollPodHandshake(sp: *PendingPodSpawn) HandshakeProgress {
    while (sp.pos < sp.buf.len) {
        const n = sp.stdout_file.read(sp.buf[sp.pos..]) catch |err| switch (err) {
            error.WouldBlock => return .pending,
            else => return .failed,
        };
        if (n == 0) return .failed; // EOF before a newline
        const chunk_start = sp.pos;
        sp.pos += n;
        if (std.mem.indexOfScalar(u8, sp.buf[chunk_start..sp.pos], '\n')) |rel| {
            return parseHandshakeLine(sp.buf[0 .. chunk_start + rel]);
        }
    }
    // Filled the buffer with no newline: this is not a handshake.
    return .failed;
}

/// Parse the pod's handshake JSON and extract its shell pid.
///
/// Validates the shape: anything writing to the pod's stdout before the
/// handshake (shell profile noise, wrapper output) can produce valid JSON of
/// the wrong type, and unchecked union accesses would be safety-checked illegal
/// behavior in the daemon.
fn parseHandshakeLine(line: []const u8) HandshakeProgress {
    if (line.len == 0) return .failed;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), line, .{}) catch return .failed;
    if (parsed.value != .object) return .failed;
    const pid_node = parsed.value.object.get("pid") orelse return .failed;
    if (pid_node != .integer) return .failed;
    const pid_val = pid_node.integer;
    if (pid_val <= 0 or pid_val > std.math.maxInt(posix.pid_t)) return .failed;
    return .{ .ready = @intCast(pid_val) };
}

/// Fork a pod AND wait for its handshake, blocking up to `ses_spawn_timeout`.
///
/// Retained for `layout_apply`, which builds a tree from panes it consumes
/// immediately and so cannot tolerate a deferred result. The interactive
/// `create_pane` path uses `startPodSpawn` + `pollPodHandshake` instead.
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
    var sp = try startPodSpawn(allocator, uuid, name, pod_socket_path, shell, cwd, env, isolation_profile);
    defer sp.deinit();

    while (true) {
        switch (pollPodHandshake(&sp)) {
            .ready => |child_pid| return .{ .pod_pid = sp.pod_pid, .child_pid = child_pid },
            .failed => return error.PodBadHandshake,
            .pending => {},
        }
        const remaining_ms = sp.deadline_ms - std.time.milliTimestamp();
        if (remaining_ms <= 0) return error.PodSpawnTimeout;
        wire.waitReadableTimeout(sp.stdout_file.handle, @intCast(remaining_ms)) catch |err| switch (err) {
            error.Timeout => return error.PodSpawnTimeout,
            else => return err,
        };
    }
}
