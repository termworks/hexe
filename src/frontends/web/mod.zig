pub const host = @import("host.zig");

pub const BrowserEvent = host.BrowserEvent;
pub const WebHost = host.WebHost;

test {
    // Force test collection from every re-exported submodule: a plain
    // `pub const x = @import(...)` does not pull in the imported file's test
    // blocks, so without this the web host test target runs zero tests.
    @import("std").testing.refAllDeclsRecursive(@This());
}
