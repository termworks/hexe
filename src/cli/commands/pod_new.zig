const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const cli_ui = core.cli_ui;

pub fn runPodNew(
    allocator: std.mem.Allocator,
    name: []const u8,
    shell: []const u8,
    cwd: []const u8,
    labels: []const u8,
    alias: bool,
    log_level: ?core.logging.Level,
    log_file: []const u8,
    json_output: bool,
) !void {
    const uuid = ipc.generateUuid();
    const uuid_str = uuid[0..];
    const pod_socket_path = try ipc.getPodSocketPath(allocator, uuid_str);
    defer allocator.free(pod_socket_path);

    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    try args.append(allocator, exe_path);
    try args.append(allocator, "pod");
    try args.append(allocator, "daemon");

    // Preserve instance/test-only behavior by passing through flags (env still drives runtime dir).
    if (std.posix.getenv("HEXE_INSTANCE")) |inst| {
        if (inst.len > 0) {
            try args.append(allocator, "--instance");
            try args.append(allocator, inst);
        }
    }
    if (std.posix.getenv("HEXE_TEST_ONLY")) |v| {
        if (v.len > 0 and !std.mem.eql(u8, v, "0")) {
            try args.append(allocator, "--test-only");
        }
    }

    try args.append(allocator, "--uuid");
    try args.append(allocator, uuid_str);
    if (name.len > 0) {
        try args.append(allocator, "--name");
        try args.append(allocator, name);
    }
    try args.append(allocator, "--socket");
    try args.append(allocator, pod_socket_path);
    if (shell.len > 0) {
        try args.append(allocator, "--shell");
        try args.append(allocator, shell);
    }
    if (cwd.len > 0) {
        try args.append(allocator, "--cwd");
        try args.append(allocator, cwd);
    }
    if (labels.len > 0) {
        try args.append(allocator, "--labels");
        try args.append(allocator, labels);
    }
    if (alias) {
        try args.append(allocator, "--write-alias");
    }
    if (log_level) |level| {
        try args.append(allocator, "--log");
        try args.append(allocator, @tagName(level));
    }
    if (log_file.len > 0) {
        try args.append(allocator, "--logfile");
        try args.append(allocator, log_file);
    }
    try args.append(allocator, "--foreground");

    // Spawn in foreground so we can read the existing ready handshake.
    var child = std.process.Child.init(args.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Pipe;

    try child.spawn();

    const pod_pid: i64 = @intCast(child.id);
    var stdout_file = child.stdout orelse return error.PodNoStdout;
    defer stdout_file.close();

    // Read JSON handshake line with timeout.
    const spawn_timeout_ms: i64 = core.constants.Timing.pod_spawn_timeout;
    const deadline_ms = std.time.milliTimestamp() + spawn_timeout_ms;
    const stdout_fd = stdout_file.handle;
    var line_buf: [512]u8 = undefined;
    var pos: usize = 0;
    while (pos < line_buf.len) {
        const remaining_ms = deadline_ms - std.time.milliTimestamp();
        if (remaining_ms <= 0) return error.PodSpawnTimeout;

        core.wire.waitReadableTimeout(stdout_fd, @intCast(remaining_ms)) catch |err| switch (err) {
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
    const root = parsed.value.object;
    const pid_val = (root.get("pid") orelse return error.PodBadHandshake).integer;
    const child_pid: i64 = @intCast(pid_val);

    // Detach the pod process (keep it running).
    // The pod was started with --foreground so it didn't daemonize, but we
    // still want `hexe pod new` to exit immediately after readiness.
    // We print a JSON response for scripting.
    const PodNewResponse = struct {
        type: []const u8,
        uuid: []const u8,
        socket: []const u8,
        pod_pid: i32,
        child_pid: i32,
    };

    const response = PodNewResponse{
        .type = "pod_new",
        .uuid = uuid_str,
        .socket = pod_socket_path,
        .pod_pid = @intCast(pod_pid),
        .child_pid = @intCast(child_pid),
    };

    const stdout = std.fs.File.stdout();
    const is_tty = std.posix.isatty(std.posix.STDOUT_FILENO);
    if (!is_tty or json_output) {
        var buf: [4096]u8 = undefined;
        const json_str = try std.fmt.bufPrint(&buf, "{{\"type\":\"{s}\",\"uuid\":\"{s}\",\"socket\":\"{s}\",\"pod_pid\":{d},\"child_pid\":{d}}}\n", .{ response.type, response.uuid, response.socket, response.pod_pid, response.child_pid });
        try stdout.writeAll(json_str);
        return;
    }

    var out = stdout.deprecatedWriter();
    const p = cli_ui.Palette.forStdout();
    const disp_name: []const u8 = if (name.len > 0) name else uuid_str[0..8];
    try out.print("{s}✓{s} Created pod {s}{s}{s} {s}[{s}]{s}\n", .{
        p.success, p.reset, p.bold, disp_name, p.reset, p.muted, uuid_str[0..8], p.reset,
    });
    try out.print("  {s}UUID:{s}    {s}{s}{s}\n", .{ p.dim, p.reset, p.muted, response.uuid, p.reset });
    try out.print("  {s}PID:{s}     pod={d}  shell={d}\n", .{ p.dim, p.reset, response.pod_pid, response.child_pid });
    try out.print("  {s}Socket:{s}  {s}{s}{s}\n", .{ p.dim, p.reset, p.dim, response.socket, p.reset });
    if (name.len > 0) {
        try out.print("  {s}Attach:{s}  {s}hexe pod attach --name {s}{s}\n", .{ p.dim, p.reset, p.accent, name, p.reset });
    } else {
        try out.print("  {s}Attach:{s}  {s}hexe pod attach --uuid {s}{s}\n", .{ p.dim, p.reset, p.accent, response.uuid, p.reset });
    }
}
