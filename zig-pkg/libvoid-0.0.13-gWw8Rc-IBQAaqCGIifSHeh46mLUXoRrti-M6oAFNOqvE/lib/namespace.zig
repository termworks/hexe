const std = @import("std");
const linux = std.os.linux;
const checkErr = @import("utils.zig").checkErr;
const c = @cImport({
    @cInclude("signal.h");
    @cInclude("sys/wait.h");
});

const IsolationOptions = @import("config.zig").IsolationOptions;
const NamespaceFds = @import("config.zig").NamespaceFds;

pub fn computeCloneFlags(isolation: IsolationOptions) u32 {
    var flags: u32 = c.SIGCHLD;
    if (isolation.user) flags |= linux.CLONE.NEWUSER;
    if (isolation.net) flags |= linux.CLONE.NEWNET;
    if (isolation.mount) flags |= linux.CLONE.NEWNS;
    if (isolation.pid) flags |= linux.CLONE.NEWPID;
    if (isolation.uts) flags |= linux.CLONE.NEWUTS;
    if (isolation.ipc) flags |= linux.CLONE.NEWIPC;
    if (isolation.cgroup) flags |= linux.CLONE.NEWCGROUP;
    return flags;
}

pub fn attach(namespace_fds: NamespaceFds) !void {
    if (namespace_fds.user) |fd| {
        try attachNamespaceFd(fd, linux.CLONE.NEWUSER);
    }
    if (namespace_fds.mount) |fd| {
        try attachNamespaceFd(fd, linux.CLONE.NEWNS);
    }
    if (namespace_fds.net) |fd| {
        try attachNamespaceFd(fd, linux.CLONE.NEWNET);
    }
    if (namespace_fds.uts) |fd| {
        try attachNamespaceFd(fd, linux.CLONE.NEWUTS);
    }
    if (namespace_fds.ipc) |fd| {
        try attachNamespaceFd(fd, linux.CLONE.NEWIPC);
    }
    if (namespace_fds.pid) |fd| {
        try attachNamespaceFd(fd, linux.CLONE.NEWPID);
    }
}

pub fn writeUserRootMappings(allocator: std.mem.Allocator, pid: linux.pid_t) !void {
    try writeUserMappings(allocator, pid, 0, linux.getuid(), 0, linux.getgid());
}

pub fn disableFurtherUserNamespaces(allocator: std.mem.Allocator) !void {
    const outer_uid = linux.getuid();
    const outer_gid = linux.getgid();

    try writeFileAbsolute("/proc/sys/user/max_user_namespaces", "1\n");
    checkErr(linux.unshare(linux.CLONE.NEWUSER), error.UnshareFailed) catch return error.UserNsNotDisabled;
    try writeUserMappings(allocator, linux.getpid(), 0, outer_uid, 0, outer_gid);

    // Refresh identity in the new user namespace mapping.
    try checkErr(linux.setregid(0, 0), error.GID);
    try checkErr(linux.setreuid(0, 0), error.UID);
}

fn writeUserMappings(
    allocator: std.mem.Allocator,
    pid: linux.pid_t,
    inside_uid: linux.uid_t,
    outside_uid: linux.uid_t,
    inside_gid: linux.gid_t,
    outside_gid: linux.gid_t,
) !void {
    const uidmap_path = try std.fmt.allocPrint(allocator, "/proc/{}/uid_map", .{pid});
    defer allocator.free(uidmap_path);
    const gidmap_path = try std.fmt.allocPrint(allocator, "/proc/{}/gid_map", .{pid});
    defer allocator.free(gidmap_path);
    const setgroups_path = try std.fmt.allocPrint(allocator, "/proc/{}/setgroups", .{pid});
    defer allocator.free(setgroups_path);

    var uid_buf: [64]u8 = undefined;
    var gid_buf: [64]u8 = undefined;
    const uid_line = try std.fmt.bufPrint(&uid_buf, "{} {} 1\n", .{ inside_uid, outside_uid });
    const gid_line = try std.fmt.bufPrint(&gid_buf, "{} {} 1\n", .{ inside_gid, outside_gid });

    // Step 1: MUST write to setgroups FIRST (required by kernel before gid_map)
    // This disables setgroups() in the user namespace for security
    if (std.fs.openFileAbsolute(setgroups_path, .{ .mode = .write_only })) |setgroups_file| {
        defer setgroups_file.close();
        _ = setgroups_file.write("deny\n") catch {};
    } else |_| {}

    // Step 2: Write uid_map (map root in namespace to current user outside)
    {
        const uid_map = try std.fs.openFileAbsolute(uidmap_path, .{ .mode = .write_only });
        defer uid_map.close();
        _ = try uid_map.write(uid_line);
    }

    // Step 3: Write gid_map (must come AFTER setgroups and uid_map)
    {
        const gid_map = try std.fs.openFileAbsolute(gidmap_path, .{ .mode = .write_only });
        defer gid_map.close();
        _ = try gid_map.write(gid_line);
    }
}

fn writeFileAbsolute(path: []const u8, content: []const u8) !void {
    const file = try std.fs.openFileAbsolute(path, .{ .mode = .write_only });
    defer file.close();
    _ = try file.write(content);
}

pub fn assertUserNsDisabled() !void {
    const probe_disabled = try probeUserNsDisabled();
    if (!probe_disabled) return error.UserNsNotDisabled;
}

pub fn userNsDisabledOnHost() ?bool {
    if (readBoolSysctlZeroIsTrue("/proc/sys/user/max_user_namespaces")) |v| return v;
    if (readBoolSysctlZeroIsTrue("/proc/sys/kernel/unprivileged_userns_clone")) |v| return v;
    return null;
}

fn readBoolSysctlZeroIsTrue(path: []const u8) ?bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const content = file.readToEndAlloc(std.heap.page_allocator, 64) catch return null;
    defer std.heap.page_allocator.free(content);

    const trimmed = std.mem.trim(u8, content, " \n\t\r");
    const value = std.fmt.parseInt(u64, trimmed, 10) catch return null;
    return value == 0;
}

fn probeUserNsDisabled() !bool {
    const child_pid = std.posix.fork() catch return error.UserNsStateUnknown;
    if (child_pid == 0) {
        checkErr(linux.unshare(linux.CLONE.NEWUSER), error.UnshareFailed) catch std.posix.exit(0);
        std.posix.exit(1);
    }

    const wait_res = std.posix.waitpid(child_pid, 0);
    const status = @as(c_int, @bitCast(wait_res.status));
    if (c.WIFEXITED(status)) {
        const code = c.WEXITSTATUS(status);
        if (code == 0) return true;
        if (code == 1) return false;
    }

    return error.UserNsStateUnknown;
}

fn attachNamespaceFd(fd: i32, nstype: u32) !void {
    const res = linux.syscall2(.setns, @as(usize, @bitCast(@as(isize, fd))), nstype);
    try checkErr(res, error.SetNsFailed);
}

test "computeCloneFlags includes all namespace flags by default" {
    const flags = computeCloneFlags(.{});
    try std.testing.expect((flags & linux.CLONE.NEWUSER) != 0);
    try std.testing.expect((flags & linux.CLONE.NEWNET) != 0);
    try std.testing.expect((flags & linux.CLONE.NEWNS) != 0);
    try std.testing.expect((flags & linux.CLONE.NEWPID) != 0);
    try std.testing.expect((flags & linux.CLONE.NEWUTS) != 0);
    try std.testing.expect((flags & linux.CLONE.NEWIPC) != 0);
    try std.testing.expect((flags & linux.CLONE.NEWCGROUP) == 0);
    try std.testing.expect((flags & c.SIGCHLD) != 0);
}

test "computeCloneFlags respects disabled namespaces" {
    const flags = computeCloneFlags(.{
        .user = false,
        .net = false,
        .mount = false,
        .pid = false,
        .uts = false,
        .ipc = false,
        .cgroup = false,
    });

    try std.testing.expect((flags & linux.CLONE.NEWUSER) == 0);
    try std.testing.expect((flags & c.SIGCHLD) != 0);
    try std.testing.expect((flags & linux.CLONE.NEWNET) == 0);
    try std.testing.expect((flags & linux.CLONE.NEWNS) == 0);
    try std.testing.expect((flags & linux.CLONE.NEWPID) == 0);
    try std.testing.expect((flags & linux.CLONE.NEWUTS) == 0);
    try std.testing.expect((flags & linux.CLONE.NEWIPC) == 0);
    try std.testing.expect((flags & linux.CLONE.NEWCGROUP) == 0);
}
