const std = @import("std");
const linux = std.os.linux;
const checkErr = @import("utils.zig").checkErr;

pub fn makeRootPrivate() !void {
    try checkErr(linux.mount(null, "/", null, linux.MS.REC | linux.MS.PRIVATE, 0), error.MountPrivate);
}

pub fn makeRootSlave() !void {
    try checkErr(linux.mount(null, "/", null, linux.MS.REC | linux.MS.SLAVE, 0), error.MountPrivate);
}

pub fn enterRoot(rootfs: []const u8, use_pivot: bool) !void {
    if (use_pivot) {
        try pivotRoot(rootfs);
    } else {
        const rootfs_z = try std.posix.toPosixPath(rootfs);
        try checkErr(linux.chroot(&rootfs_z), error.Chroot);
        try checkErr(linux.chdir("/"), error.Chdir);
    }
}

/// Syscall wrapper for pivot_root (no glibc wrapper exists)
fn pivotRootSyscall(new_root: [*:0]const u8, put_old: [*:0]const u8) !void {
    const result = linux.syscall2(
        .pivot_root,
        @intFromPtr(new_root),
        @intFromPtr(put_old),
    );
    try checkErr(result, error.PivotRoot);
}

/// Perform pivot_root to switch to new root filesystem
/// Uses the "." technique to avoid creating put_old directory
pub fn pivotRoot(rootfs: []const u8) !void {
    const rootfs_z = try std.posix.toPosixPath(rootfs);

    // 1. Bind mount rootfs to itself to ensure it's a mount point
    try checkErr(linux.mount(&rootfs_z, &rootfs_z, null, linux.MS.BIND | linux.MS.REC, 0), error.BindMount);

    // 2. Change to new root directory
    try checkErr(linux.chdir(&rootfs_z), error.Chdir);

    // 3. Pivot using "." for both new_root and put_old
    //    This stacks old root on top of new root at /
    const dot = [_:0]u8{'.'};
    try pivotRootSyscall(&dot, &dot);

    // Ensure the old-root stack is private before detach so unmounts do not
    // propagate back outside the sandbox namespace.
    try checkErr(linux.mount(&dot, &dot, null, linux.MS.REC | linux.MS.PRIVATE, 0), error.MountPrivate);

    // 4. Unmount old root (now stacked at /)
    try checkErr(linux.umount2(&dot, linux.MNT.DETACH), error.UnmountOldRoot);

    // 5. Change to actual root
    const slash = [_:0]u8{'/'};
    try checkErr(linux.chdir(&slash), error.Chdir);
}

pub fn setupDefault() !void {
    try checkErr(linux.mount("proc", "proc", "proc", 0, 0), error.MountProc);
    try checkErr(linux.mount("tmpfs", "tmp", "tmpfs", 0, 0), error.MountTmpFs);
    _ = linux.mount("sysfs", "sys", "sysfs", 0, 0);
}

test "toPosixPath conversion preserves rootfs path" {
    const path = "/tmp/rootfs";
    const path_z = try std.posix.toPosixPath(path);
    const as_slice = std.mem.sliceTo(&path_z, 0);
    try std.testing.expectEqualStrings(path, as_slice);
}
