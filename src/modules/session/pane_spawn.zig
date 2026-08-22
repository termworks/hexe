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
    /// The pane's environment file; the caller puts it on the `Pane`.
    env_fd: ?posix.fd_t = null,
};

/// Whether any pane already answers to this name.
///
/// A pane name is also its pod socket filename, so a duplicate is not a display
/// nuisance — the two panes collide on `pod@<name>.sock`.
pub fn paneNameTaken(store: *store_mod.SessionStore, candidate: []const u8) bool {
    var it = store.panes.valueIterator();
    while (it.next()) |p| {
        if (p.name) |n| {
            if (std.mem.eql(u8, n, candidate)) return true;
        }
    }
    return false;
}

/// Take the first free entry from `pool`, in `order`, suffixing on exhaustion.
pub fn pickPaneName(
    allocator: std.mem.Allocator,
    store: *store_mod.SessionStore,
    pool: []const []const u8,
    order: core.names.Order,
    suffix: []const u8,
) ![]const u8 {
    const Ctx = struct { store: *store_mod.SessionStore };
    return core.names.pick(allocator, pool, order, suffix, Ctx{ .store = store }, struct {
        fn taken(ctx: Ctx, candidate: []const u8) bool {
            return paneNameTaken(ctx.store, candidate);
        }
    }.taken);
}

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

/// Variables that describe the frontend *process*, not the session it opens.
/// Carried into a session env they would reach every pane: a pane claiming its
/// parent's uuid, or a stale session id from the shell hexe was launched in.
/// PWD/OLDPWD/BOX/TERM are restated per-pane by `Pty.buildEnv`.
fn isPerProcessEnvKey(key: []const u8) bool {
    for ([_][]const u8{
        "HEXE_PANE_UUID",
        "HEXE_POD_NAME",
        "HEXE_POD_SOCKET",
        "HEXE_SESSION",
        "HEXE_FLOAT",
        "HEXE_FLOAT_NAME",
        "PWD",
        "OLDPWD",
        "BOX",
        "TERM",
    }) |skip| {
        if (std.mem.eql(u8, key, skip)) return true;
    }
    return false;
}

/// Read a registering frontend's environment from `/proc/<pid>/environ`.
///
/// This is the environment the frontend was *exec'd* with — the launching
/// shell's, including its direnv/nix profile — which is exactly what the
/// session should hand to its panes. Returns a NUL-separated blob for the
/// caller to own, or null when the pid is unusable (remote frontend, exited,
/// different uid).
pub fn readFrontendEnv(allocator: std.mem.Allocator, pid: i32) ?[]u8 {
    if (pid <= 0) return null;

    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/environ", .{pid}) catch return null;
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        if (err != error.FileNotFound) {
            core.logging.logError("ses", "failed to open frontend environ", err);
        }
        return null;
    };
    defer file.close();

    const data = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        core.logging.logError("ses", "failed to read frontend environ", err);
        return null;
    };
    defer allocator.free(data);

    var blob: std.ArrayList(u8) = .empty;
    errdefer blob.deinit(allocator);

    var it = std.mem.splitScalar(u8, data, 0);
    while (it.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (eq == 0) continue;
        if (isPerProcessEnvKey(entry[0..eq])) continue;
        blob.appendSlice(allocator, entry) catch return null;
        blob.append(allocator, 0) catch return null;
    }

    if (blob.items.len == 0) {
        blob.deinit(allocator);
        return null;
    }
    return blob.toOwnedSlice(allocator) catch null;
}

/// Split a NUL-separated session env blob into `KEY=VALUE` entries.
///
/// Entries borrow `blob`, which is owned by the Client for as long as it is
/// registered — every spawn path copies them into an EnvMap before returning,
/// so nothing outlives the borrow. Only the returned slice needs freeing.
pub fn parseSessionEnv(allocator: std.mem.Allocator, blob: []const u8) !?[]const []const u8 {
    var entries: std.ArrayList([]const u8) = .empty;
    errdefer entries.deinit(allocator);

    var it = std.mem.splitScalar(u8, blob, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        if (std.mem.indexOfScalar(u8, entry, '=') == null) continue;
        try entries.append(allocator, entry);
    }

    if (entries.items.len == 0) {
        entries.deinit(allocator);
        return null;
    }
    return try entries.toOwnedSlice(allocator);
}

/// Look a key up in parsed session env entries. Later entries win, matching
/// how the environment itself resolves duplicates.
pub fn lookupSessionEnv(entries: ?[]const []const u8, key: []const u8) ?[]const u8 {
    const items = entries orelse return null;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        if (items[i].len > key.len and
            std.mem.startsWith(u8, items[i], key) and
            items[i][key.len] == '=')
        {
            return items[i][key.len + 1 ..];
        }
    }
    return null;
}

fn putEnvEntries(env_map: *std.process.EnvMap, entries: []const []const u8) !void {
    for (entries) |entry| {
        const sep = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (sep == 0) continue;
        try env_map.put(entry[0..sep], entry[sep + 1 ..]);
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
    base_env: ?[]const []const u8,
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

    // The pane's environment file. Anonymous, so there is no path for anyone
    // else to open; it dies with the last descriptor.
    //
    // Created with CLOEXEC and handed to the pod as a `dup`, which does NOT
    // carry the flag — that copy is the one that survives `execve` into the
    // pod, and its number is what `HEXE_ENV_FD` names. SES keeps the CLOEXEC
    // original so no other child it spawns inherits it.
    const env_fd: ?posix.fd_t = posix.memfd_create("hexe-env", std.os.linux.MFD.CLOEXEC) catch |err| blk: {
        core.logging.logError("ses", "failed to create pane env descriptor", err);
        break :blk null;
    };
    errdefer if (env_fd) |fd| posix.close(fd);

    var inherit_fd: ?posix.fd_t = null;
    if (env_fd) |fd| {
        inherit_fd = posix.dup(fd) catch |err| blk: {
            core.logging.logError("ses", "failed to dup pane env descriptor", err);
            break :blk null;
        };
    }
    // The parent's copy is only needed until the fork; the pod keeps its own.
    defer if (inherit_fd) |fd| posix.close(fd);

    {
        // `base_env` is the session's own environment, captured from the
        // frontend at register. Falling back to SES's environ is the legacy
        // path: the daemon outlives every session, so its environment is
        // whichever shell first started it and belongs to no session at all.
        var env_map = if (base_env) |base| blk: {
            var map = std.process.EnvMap.init(allocator);
            errdefer map.deinit();
            try putEnvEntries(&map, base);
            break :blk map;
        } else try std.process.getEnvMap(allocator);
        errdefer env_map.deinit();

        // Ad-hoc float env overlays the base, so it can override as well as add.
        if (env) |vars| try putEnvEntries(&env_map, vars);

        // Force instance/test-only values from this ses process.
        // This prevents user-provided env overrides from escaping the instance namespace.
        if (instance_env) |inst| {
            if (inst.len > 0) try env_map.put("HEXE_INSTANCE", inst);
        }
        if (test_only_env) |v| {
            if (v.len > 0) try env_map.put("HEXE_TEST_ONLY", v);
        }

        if (inherit_fd) |fd| {
            var fd_buf: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&fd_buf, "{d}", .{fd}) catch "";
            if (text.len > 0) try env_map.put("HEXE_ENV_FD", text);
        }

        // The hexe that owns this pane, by absolute path.
        //
        // The integration would otherwise run whatever `hexe` the user's PATH
        // finds, and a shell's rc file commonly reorders PATH — so the pane can
        // easily be talking to a DIFFERENT, older build than the one that
        // spawned it. When that build predates a subcommand the integration
        // uses, the hook fails silently and the feature simply does not happen.
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fs.readLinkAbsolute("/proc/self/exe", &exe_buf)) |exe| {
            try env_map.put("HEXE_BIN", exe);
        } else |err| {
            core.logging.logError("ses", "could not resolve own path for HEXE_BIN", err);
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
        .env_fd = env_fd,
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
    /// The pane's environment file, to be moved onto the `Pane`.
    ///
    /// Held here so a spawn that fails still closes it: `takeEnvFd` hands over
    /// ownership, and whatever is left when `deinit` runs was never claimed.
    env_fd: ?posix.fd_t = null,

    pub fn takeEnvFd(self: *PendingPodSpawn) ?posix.fd_t {
        const fd = self.env_fd;
        self.env_fd = null;
        return fd;
    }

    pub fn deinit(self: *PendingPodSpawn) void {
        self.stdout_file.close();
        if (self.env_fd) |fd| posix.close(fd);
        self.env_fd = null;
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
    base_env: ?[]const []const u8,
    env: ?[]const []const u8,
    isolation_profile: ?[]const u8,
) !SpawnResult {
    var sp = try startPodSpawn(allocator, uuid, name, pod_socket_path, shell, cwd, base_env, env, isolation_profile);
    defer sp.deinit();

    while (true) {
        switch (pollPodHandshake(&sp)) {
            // Taken out of `sp` so its `deinit` does not close what the pane is
            // about to own.
            .ready => |child_pid| return .{ .pod_pid = sp.pod_pid, .child_pid = child_pid, .env_fd = sp.takeEnvFd() },
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
