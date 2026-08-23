//! The socket primitive hexe's Lua lends to the client library.
//!
//! `hexe.lua` -- the file another program requires to talk to a running session
//! -- is plain Lua, and the one thing plain Lua cannot do is open a socket. So
//! the host lends it one, the same way it lends every other entry in the API.
//!
//! Registered like any other native, deliberately: a VM that cannot load C
//! modules needs no change to gain this, which is what lets the same client
//! file run inside hexe, inside oslo, and inside whatever embeds Lua next.
//!
//! Four functions and a file descriptor. The handle is a plain Lua table
//! carrying its fd rather than userdata with a metatable in Zig, because the
//! wrapping is nicer to read in Lua and a table costs nothing here.

const std = @import("std");
const posix = std.posix;
const zlua = @import("zlua");

const Lua = zlua.Lua;
const LuaState = zlua.LuaState;

/// A connect that cannot hang. A unix socket whose listen backlog is full parks
/// in the kernel with no timeout of its own, and this runs inside somebody's
/// editor or shell.
const DEFAULT_TIMEOUT_MS: i32 = 5_000;

/// Ceiling on one `recv`. A caller asking for more gets what fits; the client
/// library reads in a loop anyway, because a stream delivers what it likes.
const MAX_RECV: usize = 1 << 20;

fn pushErr(lua: *Lua, msg: []const u8) c_int {
    lua.pushNil();
    _ = lua.pushString(msg);
    return 2;
}

/// `__stream_connect(path, timeout_ms?) -> fd | nil, err`
fn streamConnect(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const path = lua.toString(1) catch return pushErr(lua, "connect needs a socket path");
    if (path.len == 0 or path.len >= 108) return pushErr(lua, "socket path is empty or too long");

    const timeout_ms: i32 = if (lua.typeOf(2) == .number)
        @intFromFloat(lua.toNumber(2) catch @as(f64, DEFAULT_TIMEOUT_MS))
    else
        DEFAULT_TIMEOUT_MS;

    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch
        return pushErr(lua, "could not make a socket");
    errdefer posix.close(fd);

    var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);

    posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
        posix.close(fd);
        return pushErr(lua, "nothing is listening there");
    };

    // Applied after connecting, so the timeout governs the calls a client
    // actually waits in -- a reply that never comes, rather than the connect.
    const tv = posix.timeval{
        .sec = @divTrunc(timeout_ms, 1000),
        .usec = @rem(timeout_ms, 1000) * 1000,
    };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};

    lua.pushInteger(@intCast(fd));
    return 1;
}

/// `__stream_send(fd, bytes) -> true | nil, err`
fn streamSend(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const fd: posix.fd_t = @intCast(lua.toInteger(1) catch return pushErr(lua, "send needs a handle"));
    const bytes = lua.toString(2) catch return pushErr(lua, "send needs bytes");

    var sent: usize = 0;
    while (sent < bytes.len) {
        const n = posix.write(fd, bytes[sent..]) catch return pushErr(lua, "the connection went away");
        if (n == 0) return pushErr(lua, "the connection went away");
        sent += n;
    }
    lua.pushBoolean(true);
    return 1;
}

/// `__stream_recv(fd, want) -> bytes | nil, err`
///
/// May answer fewer bytes than asked for. That is ordinary for a stream, and
/// the client library loops; a primitive that pretended otherwise would make
/// every caller's first large reply desynchronise.
fn streamRecv(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const fd: posix.fd_t = @intCast(lua.toInteger(1) catch return pushErr(lua, "recv needs a handle"));
    const want_raw: i64 = if (lua.typeOf(2) == .number)
        @intFromFloat(lua.toNumber(2) catch 4096)
    else
        4096;
    const want: usize = @min(@as(usize, @intCast(@max(want_raw, 1))), MAX_RECV);

    var buf: [MAX_RECV]u8 = undefined;
    const n = posix.read(fd, buf[0..want]) catch return pushErr(lua, "the connection went away");
    _ = lua.pushString(buf[0..n]);
    return 1;
}

/// `__stream_close(fd)`
fn streamClose(lstate: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(lstate orelse return 0);
    const fd: posix.fd_t = @intCast(lua.toInteger(1) catch return 0);
    posix.close(fd);
    lua.pushBoolean(true);
    return 1;
}

/// Register the four natives as globals. The Lua bootstrap wraps them into
/// `hexe.stream`, which is the shape the client library looks for.
pub fn install(lua: *Lua) void {
    lua.pushFunction(streamConnect);
    lua.setGlobal("__stream_connect");
    lua.pushFunction(streamSend);
    lua.setGlobal("__stream_send");
    lua.pushFunction(streamRecv);
    lua.setGlobal("__stream_recv");
    lua.pushFunction(streamClose);
    lua.setGlobal("__stream_close");
}

/// The Lua half: a handle with methods, built where it reads best.
pub const BOOTSTRAP =
    "hexe.stream = hexe.stream or (function() " ++
    "local H = {}; H.__index = H; " ++
    "function H:send(b) if not self.fd then return nil, 'closed' end return __stream_send(self.fd, b) end; " ++
    "function H:recv(n) if not self.fd then return nil, 'closed' end return __stream_recv(self.fd, n) end; " ++
    "function H:close() if self.fd then __stream_close(self.fd); self.fd = nil end return true end; " ++
    "return { connect = function(path, timeout_ms) " ++
    "local fd, why = __stream_connect(path, timeout_ms); if not fd then return nil, why end; " ++
    "return setmetatable({ fd = fd }, H) end } end)(); ";
