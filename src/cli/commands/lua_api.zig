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

/// Where `--install` puts it. A path on `package.path` is the only way a host
/// that refuses `io.popen` -- oslo's VM does -- can get at the file at all.
pub fn installedPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("XDG_DATA_HOME")) |xdg| {
        return std.fmt.allocPrint(allocator, "{s}/hexe/lua/hexe.lua", .{xdg});
    }
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.local/share/hexe/lua/hexe.lua", .{home});
}

pub fn runLuaApi(allocator: std.mem.Allocator, install: bool) !void {
    if (!install) {
        var out = std.fs.File.stdout().deprecatedWriter();
        try out.writeAll(core.lua_client.SOURCE);
        return;
    }

    const path = try installedPath(allocator);
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(core.lua_client.SOURCE);

    var out = std.fs.File.stdout().deprecatedWriter();
    try out.print("{s}\n", .{path});
    try out.print("\nAdd its directory to package.path and `require \"hexe\"`:\n", .{});
    try out.print("  package.path = package.path .. \";{s}/?.lua\"\n", .{std.fs.path.dirname(path) orelse "."});
}
