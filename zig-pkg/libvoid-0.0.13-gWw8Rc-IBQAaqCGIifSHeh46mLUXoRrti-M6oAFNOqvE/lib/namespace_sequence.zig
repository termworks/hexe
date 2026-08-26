const std = @import("std");
const linux = std.os.linux;
const checkErr = @import("utils.zig").checkErr;

const NamespaceFds = @import("config.zig").NamespaceFds;

pub fn attachInitial(namespace_fds: NamespaceFds) !void {
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
}

pub fn preparePidNamespace(pid_ns_fd: i32, unshare_child_pid_ns: bool) !void {
    try attachNamespaceFd(pid_ns_fd, linux.CLONE.NEWPID);
    if (unshare_child_pid_ns) {
        try checkErr(linux.unshare(linux.CLONE.NEWPID), error.UnsharePidNsFailed);
    }
}

pub fn attachUserNs2(namespace_fds: NamespaceFds) !void {
    if (namespace_fds.user2) |fd| {
        try attachNamespaceFd(fd, linux.CLONE.NEWUSER);
    }
}

fn attachNamespaceFd(fd: i32, nstype: u32) !void {
    const res = linux.syscall2(.setns, @as(usize, @bitCast(@as(isize, fd))), nstype);
    try checkErr(res, error.SetNsFailed);
}
