//! `hexe.fs` — the two filesystem reads a client library cannot do without.
//!
//! Two entries, added for one reason: a client library discovering peers has to
//! list a directory and read a small descriptor, and plain Lua cannot. Its only
//! alternative is `io.popen`, which shells out and which hexe's own safe mode
//! removes — so a project config using the client library could not find a
//! session at all.
//!
//! Read-only and non-recursive on purpose. This is not the beginning of a
//! filesystem API; it is the one call the client library needs, and anything
//! more belongs behind a capability rather than on the module table.

const std = @import("std");
const zlua = @import("zlua");

const Lua = zlua.Lua;
const LuaState = zlua.LuaState;

/// Entries returned at most. A socket directory holds a handful; this is the
/// ceiling that stops a pathological directory allocating without end.
const MAX_ENTRIES: usize = 4096;

/// Ceiling on one `read`. A descriptor is a few dozen bytes; anything at this
/// size is not what this call is for, and is refused rather than truncated.
const MAX_READ: usize = 64 * 1024;

/// `hexe.fs.ls(path) -> { { name, type, mtime }, ... }` or nil.
///
/// The field names match what oslo's `fs.ls` answers, because the client
/// libraries are copied between the two and a different shape here would mean
/// each one needed its own reader.
fn fsLs(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const path = lua.toString(1) catch {
        lua.pushNil();
        return 1;
    };

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch {
        lua.pushNil();
        return 1;
    };
    defer dir.close();

    lua.createTable(0, 0);
    var n: i32 = 0;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (n >= MAX_ENTRIES) break;
        n += 1;

        lua.createTable(0, 3);
        _ = lua.pushString(entry.name);
        lua.setField(-2, "name");
        _ = lua.pushString(@tagName(entry.kind));
        lua.setField(-2, "type");

        // mtime, so a caller can order by age. Newest-first is how a client
        // picks between several sockets when it was given no name.
        var mtime: i64 = 0;
        if (dir.statFile(entry.name)) |st| {
            mtime = @intCast(@divTrunc(st.mtime, std.time.ns_per_s));
        } else |_| {}
        lua.pushInteger(mtime);
        lua.setField(-2, "mtime");

        lua.rawSetIndex(-2, n);
    }
    return 1;
}

/// `hexe.fs.read(path) -> contents` or nil. Bounded, because the caller is a
/// client library reading a descriptor, not a file viewer.
fn fsRead(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const path = lua.toString(1) catch {
        lua.pushNil();
        return 1;
    };
    const f = std.fs.cwd().openFile(path, .{}) catch {
        lua.pushNil();
        return 1;
    };
    defer f.close();
    var buf: [MAX_READ]u8 = undefined;
    const n = f.readAll(&buf) catch {
        lua.pushNil();
        return 1;
    };
    if (n >= MAX_READ) {
        lua.pushNil();
        return 1;
    }
    _ = lua.pushString(buf[0..n]);
    return 1;
}

pub fn install(lua: *Lua) void {
    lua.pushFunction(fsLs);
    lua.setGlobal("__fs_ls");
    lua.pushFunction(fsRead);
    lua.setGlobal("__fs_read");
}

/// Hung on `hexe.fs` where a client library looks for it.
pub const BOOTSTRAP = "hexe.fs = hexe.fs or { ls = __fs_ls, read = __fs_read }; ";
