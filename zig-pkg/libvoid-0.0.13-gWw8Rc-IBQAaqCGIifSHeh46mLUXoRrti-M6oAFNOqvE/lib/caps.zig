const std = @import("std");
const linux = std.os.linux;
const checkErr = @import("utils.zig").checkErr;

const SecurityOptions = @import("config.zig").SecurityOptions;

const LINUX_CAPABILITY_VERSION_3 = 0x20080522;

pub fn apply(security: SecurityOptions) !void {
    if (security.cap_add.len == 0 and security.cap_drop.len == 0) {
        return;
    }

    var cap_hdr = linux.cap_user_header_t{
        .version = LINUX_CAPABILITY_VERSION_3,
        .pid = 0,
    };
    var cap_data = [_]linux.cap_user_data_t{
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
    };

    try checkErr(linux.capget(&cap_hdr, &cap_data[0]), error.CapabilityReadFailed);

    for (security.cap_add) |cap| {
        const index = linux.CAP.TO_INDEX(cap);
        const mask = linux.CAP.TO_MASK(cap);
        cap_data[index].effective |= mask;
        cap_data[index].permitted |= mask;
    }

    for (security.cap_drop) |cap| {
        const index = linux.CAP.TO_INDEX(cap);
        const mask = linux.CAP.TO_MASK(cap);
        cap_data[index].effective &= ~mask;
        cap_data[index].permitted &= ~mask;
        cap_data[index].inheritable &= ~mask;
    }

    try checkErr(linux.capset(&cap_hdr, &cap_data[0]), error.CapabilitySetFailed);

    for (security.cap_drop) |cap| {
        try checkErr(linux.prctl(@intFromEnum(linux.PR.CAPBSET_DROP), cap, 0, 0, 0), error.CapabilityDropFailed);
    }
}
