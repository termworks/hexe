//! Profiles: a named, wholly separate hexe.
//!
//! A profile has its own ses daemon, its own sessions, its own sockets, state
//! and log. Nothing is shared, so `work` and `personal` cannot see or disturb
//! each other. The name comes from `--profile` (or HEXE_INSTANCE), and every
//! path is derived from it in `core.ipc`.
//!
//! Listing has to look in two places, because the two halves live apart: the
//! runtime dir holds the sockets of profiles that are up, and the state dir
//! holds what a profile left behind. A profile in the second but not the first
//! is one whose daemon is not running.

const std = @import("std");
const core = @import("core");
const ipc = core.ipc;

const print = std.debug.print;

const Profile = struct {
    name: []const u8,
    running: bool,
    socket: ?[]const u8,
    state_dir: ?[]const u8,
};

/// A live daemon is one whose socket accepts a connection. A socket FILE alone
/// proves nothing: a killed daemon leaves its path behind.
fn daemonAlive(path: []const u8) bool {
    var client = ipc.Client.connect(path) catch return false;
    client.close();
    return true;
}

fn runtimeRoot(allocator: std.mem.Allocator) ![]const u8 {
    var fallback: [64]u8 = undefined;
    const dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse ipc.fallbackRuntimeDir(&fallback);
    return std.fmt.allocPrint(allocator, "{s}/hexe", .{dir});
}

fn stateRoot(allocator: std.mem.Allocator) !?[]const u8 {
    if (std.posix.getenv("XDG_STATE_HOME")) |xdg| {
        return try std.fmt.allocPrint(allocator, "{s}/hexe", .{xdg});
    }
    const home = std.posix.getenv("HOME") orelse return null;
    return try std.fmt.allocPrint(allocator, "{s}/.local/state/hexe", .{home});
}

fn addOrUpdate(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Profile),
    name: []const u8,
    running: ?bool,
    socket: ?[]const u8,
    state_dir: ?[]const u8,
) !void {
    for (list.items) |*p| {
        if (!std.mem.eql(u8, p.name, name)) continue;
        if (running) |r| p.running = p.running or r;
        if (socket) |s| if (p.socket == null) {
            p.socket = s;
        };
        if (state_dir) |d| if (p.state_dir == null) {
            p.state_dir = d;
        };
        return;
    }
    try list.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .running = running orelse false,
        .socket = socket,
        .state_dir = state_dir,
    });
}

/// Whether this profile has its own config file rather than the shared one.
fn hasOwnConfig(allocator: std.mem.Allocator, name: []const u8) bool {
    const dir = core.lua_runtime.getConfigDir(allocator) catch return false;
    defer allocator.free(dir);
    const path = std.fmt.allocPrint(allocator, "{s}/profiles/{s}.lua", .{ dir, name }) catch return false;
    defer allocator.free(path);
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

pub fn runProfileList(allocator: std.mem.Allocator) !void {
    var list: std.ArrayList(Profile) = .empty;
    defer list.deinit(allocator);

    const rt_root = try runtimeRoot(allocator);
    defer allocator.free(rt_root);

    // The unnamed profile keeps its socket directly in the runtime root; named
    // ones get a subdirectory each.
    {
        const sock = try std.fmt.allocPrint(allocator, "{s}/ses.sock", .{rt_root});
        if (daemonAlive(sock)) {
            try addOrUpdate(allocator, &list, "default", true, sock, null);
        } else {
            allocator.free(sock);
        }
    }

    if (std.fs.openDirAbsolute(rt_root, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .directory) continue;
            const sock = try std.fmt.allocPrint(allocator, "{s}/{s}/ses.sock", .{ rt_root, entry.name });
            // A socket DIRECTORY with no live daemon is leftover, not a
            // profile: every short-lived run (tests, probes) leaves one, and
            // listing them buried the real profiles under hundreds of rows.
            // What makes a stopped profile real is its state, found below.
            if (daemonAlive(sock)) {
                try addOrUpdate(allocator, &list, entry.name, true, sock, null);
            } else {
                allocator.free(sock);
            }
        }
    } else |_| {}

    if (try stateRoot(allocator)) |st_root| {
        defer allocator.free(st_root);
        if (std.fs.openDirAbsolute(st_root, .{ .iterate = true })) |dir_const| {
            var dir = dir_const;
            defer dir.close();
            var it = dir.iterate();
            while (it.next() catch null) |entry| {
                if (entry.kind != .directory) continue;
                const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ st_root, entry.name });
                try addOrUpdate(allocator, &list, entry.name, null, null, path);
            }
        } else |_| {}
    }

    defer for (list.items) |p| {
        allocator.free(p.name);
        if (p.socket) |s| allocator.free(s);
        if (p.state_dir) |d| allocator.free(d);
    };

    if (list.items.len == 0) {
        print("No profiles yet.\n", .{});
        print("Start one with: hexe --profile work\n", .{});
        return;
    }

    const current = std.posix.getenv("HEXE_INSTANCE") orelse "default";
    print("{s:<20} {s:<9} {s:<10} {s}\n", .{ "PROFILE", "DAEMON", "CONFIG", "STATE" });
    for (list.items) |p| {
        const mark: []const u8 = if (std.mem.eql(u8, p.name, current)) "*" else " ";
        print("{s}{s:<19} {s:<9} {s:<10} {s}\n", .{
            mark,
            p.name,
            if (p.running) "running" else "stopped",
            if (hasOwnConfig(allocator, p.name)) "own" else "shared",
            p.state_dir orelse "-",
        });
    }
    print("\n* = this shell's profile. Select one with --profile NAME.\n", .{});
    print("CONFIG 'own' = profiles/<name>.lua; 'shared' = the common init.lua.\n", .{});
}
