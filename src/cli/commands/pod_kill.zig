const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const pod_meta = core.pod_meta;
const shared = @import("shared.zig");

const print = std.debug.print;

pub fn runPodKill(allocator: std.mem.Allocator, uuid: []const u8, name: []const u8, signal_name: []const u8, force: bool) !void {
    const pid = resolvePodPid(allocator, uuid, name) catch |err| {
        if (err == error.InvalidUuid) {
            print("Error: --uuid must be 32 hex chars\n", .{});
        }
        return err;
    };
    if (pid == null) {
        print("pod not found\n", .{});
        std.process.exit(1);
    }

    const sig = parseSignal(signal_name);
    if (sig == null) {
        print("Error: invalid --signal\n", .{});
        std.process.exit(1);
    }

    const rc = std.c.kill(@intCast(pid.?), sig.?);
    if (rc != 0) {
        // errno not surfaced here in a nice way; keep message simple.
        print("kill failed\n", .{});
        std.process.exit(1);
    }

    if (force and sig.? != std.c.SIG.KILL) {
        // best-effort SIGKILL after short delay
        std.Thread.sleep(50 * std.time.ns_per_ms);
        _ = std.c.kill(@intCast(pid.?), std.c.SIG.KILL);
    }
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
