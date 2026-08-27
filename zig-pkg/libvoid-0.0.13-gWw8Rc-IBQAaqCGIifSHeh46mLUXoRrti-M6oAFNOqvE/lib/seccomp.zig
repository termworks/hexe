const std = @import("std");
const linux = std.os.linux;
const checkErr = @import("utils.zig").checkErr;

const SecurityOptions = @import("config.zig").SecurityOptions;
const SeccompInstruction = @import("config.zig").SecurityOptions.SeccompInstruction;

const SECCOMP_SET_MODE_FILTER: u32 = 1;

const SeccompProgram = extern struct {
    len: u16,
    filter: [*]SeccompInstruction,
};

pub fn apply(security: SecurityOptions, allocator: std.mem.Allocator) !void {
    if (security.seccomp_mode == .strict) {
        try checkErr(linux.prctl(@intFromEnum(linux.PR.SET_SECCOMP), 1, 0, 0, 0), error.SeccompFailed);
        return;
    }

    if (security.seccomp_filter) |filter| {
        try applySeccompFilter(filter);
    }
    for (security.seccomp_filters) |filter| {
        try applySeccompFilter(filter);
    }
    for (security.seccomp_filter_fds) |fd| {
        try applySeccompFilterFd(fd, allocator);
    }
}

fn applySeccompFilter(filter: []const SeccompInstruction) !void {
    var prog = SeccompProgram{
        .len = @intCast(filter.len),
        .filter = @constCast(filter.ptr),
    };
    try checkErr(linux.seccomp(SECCOMP_SET_MODE_FILTER, 0, @ptrCast(&prog)), error.SeccompFailed);
}

fn applySeccompFilterFd(fd: i32, allocator: std.mem.Allocator) !void {
    var file = std.fs.File{ .handle = fd };
    const raw = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(raw);

    if (raw.len == 0 or raw.len % @sizeOf(SeccompInstruction) != 0) {
        return error.InvalidSeccompFdProgram;
    }

    const count = raw.len / @sizeOf(SeccompInstruction);
    const filter = try allocator.alloc(SeccompInstruction, count);
    defer allocator.free(filter);

    @memcpy(std.mem.sliceAsBytes(filter), raw);
    try applySeccompFilter(filter);
}
