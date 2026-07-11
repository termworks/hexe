pub const host = @import("host.zig");

pub const RemoteTerminalEvent = host.RemoteTerminalEvent;
pub const SyslinkHost = host.SyslinkHost;

test {
    // Force test collection from every re-exported submodule: a plain
    // `pub const x = @import(...)` does not pull in the imported file's test
    // blocks, so without this the syslink host test target runs zero tests.
    @import("std").testing.refAllDeclsRecursive(@This());
}
