const std = @import("std");
const c = @cImport({
    @cInclude("grp.h");
    @cInclude("pwd.h");
});

pub const UserAccount = struct {
    allocator: std.mem.Allocator,
    username_z: [:0]u8,
    home_z: [:0]u8,
    shell_z: [:0]u8,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,

    pub fn deinit(self: *UserAccount) void {
        self.allocator.free(self.username_z);
        self.allocator.free(self.home_z);
        self.allocator.free(self.shell_z);
    }
};

pub fn lookup(allocator: std.mem.Allocator, username: []const u8) !UserAccount {
    const username_z = try allocator.dupeZ(u8, username);
    errdefer allocator.free(username_z);

    const pw_ptr = c.getpwnam(username_z.ptr) orelse return error.UserNotFound;
    const pw = pw_ptr.*;

    if (pw.pw_dir == null or pw.pw_shell == null) {
        return error.InvalidUserRecord;
    }

    const home_z = try allocator.dupeZ(u8, std.mem.span(pw.pw_dir));
    errdefer allocator.free(home_z);
    const shell_z = try allocator.dupeZ(u8, std.mem.span(pw.pw_shell));
    errdefer allocator.free(shell_z);

    return .{
        .allocator = allocator,
        .username_z = username_z,
        .home_z = home_z,
        .shell_z = shell_z,
        .uid = pw.pw_uid,
        .gid = pw.pw_gid,
    };
}

pub fn applyIdentity(account: *const UserAccount) !void {
    try applyIdentityRaw(account.username_z.ptr, account.uid, account.gid);
}

pub fn applyIdentityRaw(username_z: [*:0]const u8, uid: std.posix.uid_t, gid: std.posix.gid_t) !void {
    if (c.initgroups(username_z, @intCast(gid)) != 0) {
        return error.InitGroupsFailed;
    }
    try std.posix.setregid(gid, gid);
    try std.posix.setreuid(uid, uid);
}

pub fn runCommandAsUser(
    allocator: std.mem.Allocator,
    account: *const UserAccount,
    command: []const u8,
    max_output_bytes: usize,
) !std.process.Child.RunResult {
    const argv = [_][]const u8{ account.shell_z, "-c", command };

    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = account.home_z;
    child.uid = account.uid;
    child.gid = account.gid;

    try child.spawn();

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(allocator);

    try child.collectOutput(allocator, &stdout, &stderr, max_output_bytes);

    return .{
        .term = try child.wait(),
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
    };
}

test "lookup rejects unknown user" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UserNotFound, lookup(allocator, "__liblink_user_does_not_exist__"));
}

test "runCommandAsUser executes command in account shell" {
    const allocator = std.testing.allocator;
    const username_owned = std.process.getEnvVarOwned(allocator, "USER") catch null;
    defer if (username_owned) |u| allocator.free(u);
    const username = username_owned orelse "root";

    var account = try lookup(allocator, username);
    defer account.deinit();

    const result = try runCommandAsUser(allocator, &account, "printf test-ok", 1024);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqualStrings("test-ok", result.stdout);
    try std.testing.expectEqual(@as(usize, 0), result.stderr.len);
}
