const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const pod_meta = core.pod_meta;
const cli_ui = core.cli_ui;
const shared = @import("shared.zig");
const pod_list = @import("pod_list.zig");
const terminal = @import("terminal");

pub fn runPodKill(allocator: std.mem.Allocator, uuid: []const u8, name: []const u8, signal_name: []const u8, force: bool) !void {
    var picked_uuid_buf: [32]u8 = undefined;
    var picked_name_owned: ?[]u8 = null;
    defer if (picked_name_owned) |n| allocator.free(n);

    var eff_uuid = uuid;
    var eff_name = name;

    if (uuid.len == 0 and name.len == 0) {
        if (std.posix.isatty(std.posix.STDIN_FILENO) and std.posix.isatty(std.posix.STDOUT_FILENO)) {
            if (try pickPodToKill(allocator, &picked_uuid_buf, &picked_name_owned)) {
                eff_uuid = picked_uuid_buf[0..];
                if (picked_name_owned) |pn| eff_name = pn;
            } else {
                return;
            }
        } else {
            cli_ui.printErr("must provide --uuid or --name (or run interactively on a TTY)", .{});
            std.process.exit(1);
        }
    }

    const pid = resolvePodPid(allocator, eff_uuid, eff_name) catch |err| {
        if (err == error.InvalidUuid) {
            cli_ui.printErr("--uuid must be 32 hex chars", .{});
        } else if (err == error.AmbiguousPodName) {
            cli_ui.printErr("several pods are called '{s}'; use --uuid", .{eff_name});
        } else {
            cli_ui.printErr("failed to resolve pod: {s}", .{@errorName(err)});
        }
        return err;
    };
    if (pid == null) {
        cli_ui.printErr("pod not found", .{});
        cli_ui.printErrHint("List running pods with: hexe pod list", .{});
        std.process.exit(1);
    }

    const sig = parseSignal(signal_name);
    if (sig == null) {
        cli_ui.printErr("invalid --signal '{s}'", .{signal_name});
        std.process.exit(1);
    }

    const rc = std.c.kill(@intCast(pid.?), sig.?);
    if (rc != 0) {
        cli_ui.printErr("kill failed for pid {d}", .{pid.?});
        std.process.exit(1);
    }

    if (force and sig.? != std.c.SIG.KILL) {
        // best-effort SIGKILL after short delay
        std.Thread.sleep(50 * std.time.ns_per_ms);
        _ = std.c.kill(@intCast(pid.?), std.c.SIG.KILL);
    }

    var out = std.fs.File.stdout().deprecatedWriter();
    const p = cli_ui.Palette.forStdout();
    const sig_disp: []const u8 = if (signal_name.len > 0) signal_name else "TERM";
    const label: []const u8 = if (eff_name.len > 0) eff_name else if (eff_uuid.len >= 8) eff_uuid[0..8] else "pod";
    try out.print("{s}✓{s} Sent {s}{s}{s} to pod {s}{s}{s} {s}(pid={d}){s}\n", .{
        p.success, p.reset,
        p.warn,    sig_disp, p.reset,
        p.bold,    label,    p.reset,
        p.dim,     pid.?,    p.reset,
    });
}

fn pickPodToKill(
    allocator: std.mem.Allocator,
    out_uuid: *[32]u8,
    out_name: *?[]u8,
) !bool {
    const dir = try ipc.getSocketDir(allocator);
    defer allocator.free(dir);

    var records = std.ArrayList(pod_list.PodRecord).empty;
    defer {
        for (records.items) |r| pod_list.freeRecord(allocator, r);
        records.deinit(allocator);
    }
    pod_list.scanMetaFiles(allocator, dir, &records) catch {};

    var live = std.ArrayList(pod_list.PodRecord).empty;
    defer live.deinit(allocator);
    for (records.items) |rec| {
        const sock = ipc.getPodSocketPath(allocator, &rec.uuid) catch continue;
        defer allocator.free(sock);
        if (ipc.Client.connect(sock)) |conn_val| {
            var c = conn_val;
            c.close();
            try live.append(allocator, rec);
        } else |_| {}
    }

    if (live.items.len == 0) {
        const p = cli_ui.Palette.forStderr();
        std.debug.print("{s}○{s} No running pods found\n", .{ p.warn, p.reset });
        return false;
    }

    var labels = try allocator.alloc([]const u8, live.items.len);
    var labels_built: usize = 0;
    defer {
        for (labels[0..labels_built]) |l| allocator.free(l);
        allocator.free(labels);
    }

    var badges = try allocator.alloc([]const u8, live.items.len);
    var badges_built: usize = 0;
    defer {
        for (badges[0..badges_built]) |b| allocator.free(b);
        allocator.free(badges);
    }

    var details = try allocator.alloc([]const u8, live.items.len);
    var details_built: usize = 0;
    defer {
        for (details[0..details_built]) |d| allocator.free(d);
        allocator.free(details);
    }

    for (live.items, 0..) |rec, i| {
        labels[i] = try std.fmt.allocPrint(allocator, "{s:<14} [{s}]", .{ rec.name, rec.uuid[0..8] });
        labels_built = i + 1;
        badges[i] = try std.fmt.allocPrint(allocator, "pid {d}", .{rec.child_pid});
        badges_built = i + 1;
        var home_buf: [256]u8 = undefined;
        const cwd_disp = cli_ui.compactHome(rec.cwd, &home_buf);
        details[i] = try std.fmt.allocPrint(allocator, "cwd: {s}{s}{s}", .{
            cwd_disp,
            if (rec.shell.len > 0) " · " else "",
            rec.shell,
        });
        details_built = i + 1;
    }

    const chosen = try terminal.runStandalonePicker(allocator, labels, .{
        .title = "Kill pod",
        .badges = badges,
        .details = details,
        .hint = "↑↓/jk move · / filter · Enter kill · Esc cancel",
        .filterable = true,
    });
    const idx = chosen orelse return false;
    out_uuid.* = live.items[idx].uuid;
    if (live.items[idx].name.len > 0 and !std.mem.eql(u8, live.items[idx].name, "-")) {
        out_name.* = try allocator.dupe(u8, live.items[idx].name);
    }
    return true;
}

fn parseSignal(name: []const u8) ?c_int {
    if (name.len == 0) return std.c.SIG.TERM;
    // Standard termination signals
    if (std.mem.eql(u8, name, "TERM") or std.mem.eql(u8, name, "SIGTERM")) return std.c.SIG.TERM;
    if (std.mem.eql(u8, name, "KILL") or std.mem.eql(u8, name, "SIGKILL")) return std.c.SIG.KILL;
    if (std.mem.eql(u8, name, "INT") or std.mem.eql(u8, name, "SIGINT")) return std.c.SIG.INT;
    if (std.mem.eql(u8, name, "HUP") or std.mem.eql(u8, name, "SIGHUP")) return std.c.SIG.HUP;
    if (std.mem.eql(u8, name, "QUIT") or std.mem.eql(u8, name, "SIGQUIT")) return std.c.SIG.QUIT;
    // Job control signals
    if (std.mem.eql(u8, name, "STOP") or std.mem.eql(u8, name, "SIGSTOP")) return std.c.SIG.STOP;
    if (std.mem.eql(u8, name, "CONT") or std.mem.eql(u8, name, "SIGCONT")) return std.c.SIG.CONT;
    if (std.mem.eql(u8, name, "TSTP") or std.mem.eql(u8, name, "SIGTSTP")) return std.c.SIG.TSTP;
    // User-defined signals
    if (std.mem.eql(u8, name, "USR1") or std.mem.eql(u8, name, "SIGUSR1")) return std.c.SIG.USR1;
    if (std.mem.eql(u8, name, "USR2") or std.mem.eql(u8, name, "SIGUSR2")) return std.c.SIG.USR2;
    // Numeric signal (e.g., "9" for SIGKILL)
    if (std.fmt.parseInt(c_int, name, 10)) |num| {
        if (num >= 1 and num <= 31) return num;
    } else |_| {}
    return null;
}

fn resolvePodPid(allocator: std.mem.Allocator, uuid: []const u8, name: []const u8) !?i64 {
    // If uuid is provided, we can just read the .meta file for pid.
    if (uuid.len > 0) {
        if (!shared.isUuid32Hex(uuid)) return error.InvalidUuid;
        const dir = try ipc.getSocketDir(allocator);
        defer allocator.free(dir);
        const path = try std.fmt.allocPrint(allocator, "{s}/pod-{s}.meta", .{ dir, uuid });
        defer allocator.free(path);
        return readPidFromMeta(path);
    }
    return shared.resolveNewestPodPidByName(allocator, name);
}

fn readPidFromMeta(path: []const u8) ?i64 {
    var f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    var buf: [4096]u8 = undefined;
    const n = f.readAll(&buf) catch return null;
    if (n == 0) return null;
    const line = std.mem.trim(u8, buf[0..n], " \t\n\r");
    if (!std.mem.startsWith(u8, line, pod_meta.POD_META_PREFIX)) return null;
    const pid_s = parseField(line, "pid") orelse return null;
    return std.fmt.parseInt(i64, pid_s, 10) catch null;
}

const parseField = shared.parseField;
