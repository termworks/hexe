//! `hexe lua-api` — hand another program the client library, as source.
//!
//!   local src  = io.popen("hexe lua-api"):read("a")
//!   local hexe = load(src)(my_transport)
//!   local mux  = hexe.connect()
//!
//! Printed rather than installed to a path, because the consumer is another
//! program's Lua and it has no business knowing where hexe keeps files. The
//! source is embedded in the binary, so the copy you get is the one this build
//! speaks.

const std = @import("std");
const core = @import("core");

pub fn runLuaApi() !void {
    var out = std.fs.File.stdout().deprecatedWriter();
    try out.writeAll(core.lua_client.SOURCE);
}
