//! The control socket: hexe's live API, reachable from outside the process.
//!
//! Everything the mux knows about its panes, floats, tabs and session already
//! has one precise definition — the live query API in `lua_api.zig`. Until now
//! it existed only inside the frontend, so any other program had to scrape
//! human-formatted CLI output for facts hexe held exactly. This socket hands
//! the same API to anything that can open a unix socket: a web gateway, a phone
//! client behind one, a status painter, a shell script.
//!
//! Requests are JSON, framed the same way the painter protocol frames its own
//! (4-byte big-endian length, then the body):
//!
//!     -> {"call":"panes","arg":{"visible":true}}
//!     <- {"ok":true,"result":[ ... ]}
//!
//! `call` names any function on `hexe.live`, so this surface grows whenever
//! that one does and cannot describe a pane differently from the way Lua does.
//!
//! Nothing here may block the frontend loop. A stalled reader on this socket
//! would suspend every pane in the mux, so accepts and reads are non-blocking,
//! connections are capped and time-limited, and a request that has not finished
//! arriving is left for the next iteration rather than waited on.

const std = @import("std");
const posix = std.posix;
const core = @import("core");
const zlua = @import("zlua");

const State = @import("state.zig").State;
const lua_api = @import("lua_api.zig");
const api_json = @import("api_json.zig");

const log = std.log.scoped(.api_server);

/// Concurrent connections. A control socket serves occasional requests, not
/// traffic; a client that opens more than this is misbehaving.
const MAX_CONNS = 8;

/// Largest request accepted. Arguments are small filter tables.
const MAX_REQUEST = 64 * 1024;

/// Largest response emitted. A pane list on a busy session is a few KiB; this
/// is the ceiling that stops a pathological query from allocating without end.
const MAX_RESPONSE = 4 * 1024 * 1024;

/// How long a half-finished request may sit before its connection is dropped.
const CONN_TIMEOUT_MS: i64 = 5_000;

/// How many accepts to take per loop iteration, so a flood cannot starve
/// rendering.
const ACCEPTS_PER_TICK = 4;

const Conn = struct {
    fd: posix.socket_t = -1,
    buf: std.ArrayList(u8) = .empty,
    /// Response bytes still to be written, and how far we got.
    out: std.ArrayList(u8) = .empty,
    out_sent: usize = 0,
    need: ?u32 = null,
    started_ms: i64 = 0,
    replying: bool = false,

    fn active(self: *const Conn) bool {
        return self.fd >= 0;
    }
};

pub const ApiServer = struct {
    allocator: std.mem.Allocator,
    fd: posix.socket_t = -1,
    path: []u8 = &.{},
    conns: [MAX_CONNS]Conn = @splat(.{}),

    /// Bind the socket for `session`, replacing a stale one left by a crash.
    pub fn init(allocator: std.mem.Allocator, session: []const u8) !ApiServer {
        const dir = try core.ipc.getSocketDir(allocator);
        defer allocator.free(dir);
        std.fs.cwd().makePath(dir) catch {};

        const path = try std.fmt.allocPrint(allocator, "{s}/api@{s}.sock", .{ dir, session });
        errdefer allocator.free(path);
        if (path.len >= 108) return error.NameTooLong;

        // A socket file outlives the process that made it, so a previous crash
        // leaves one that nothing is listening on. Bind would fail on it.
        std.fs.cwd().deleteFile(path) catch {};

        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0);
        errdefer posix.close(fd);

        var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..path.len], path);
        try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        try posix.listen(fd, 16);

        // The socket carries full control of the session, so it is the owner's
        // alone regardless of how permissive the runtime directory is.
        posix.fchmodat(posix.AT.FDCWD, path, 0o600, 0) catch |err| {
            log.warn("could not restrict control socket permissions: {s}", .{@errorName(err)});
        };

        return .{ .allocator = allocator, .fd = fd, .path = path };
    }

    pub fn deinit(self: *ApiServer) void {
        for (&self.conns) |*c| self.dropConn(c);
        if (self.fd >= 0) posix.close(self.fd);
        self.fd = -1;
        if (self.path.len > 0) {
            std.fs.cwd().deleteFile(self.path) catch {};
            self.allocator.free(self.path);
            self.path = &.{};
        }
    }

    fn dropConn(self: *ApiServer, c: *Conn) void {
        if (c.fd >= 0) posix.close(c.fd);
        c.fd = -1;
        c.buf.deinit(self.allocator);
        c.buf = .empty;
        c.out.deinit(self.allocator);
        c.out = .empty;
        c.out_sent = 0;
        c.need = null;
        c.replying = false;
    }

    fn slot(self: *ApiServer) ?*Conn {
        for (&self.conns) |*c| {
            if (!c.active()) return c;
        }
        return null;
    }

    /// Take pending connections and move every live one forward.
    ///
    /// Called from the frontend loop; returns immediately when there is nothing
    /// to do, which is the common case.
    pub fn service(self: *ApiServer, state: *State) void {
        if (self.fd < 0) return;

        var taken: usize = 0;
        while (taken < ACCEPTS_PER_TICK) : (taken += 1) {
            const cfd = posix.accept(self.fd, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC) catch |err| switch (err) {
                error.WouldBlock => break,
                else => break,
            };
            const c = self.slot() orelse {
                // Full. Refusing is better than queueing: the client learns now
                // instead of waiting on a reply that is not coming.
                posix.close(cfd);
                continue;
            };
            c.* = .{ .fd = cfd, .started_ms = std.time.milliTimestamp() };
        }

        const now = std.time.milliTimestamp();
        for (&self.conns) |*c| {
            if (!c.active()) continue;
            if (now - c.started_ms > CONN_TIMEOUT_MS) {
                self.dropConn(c);
                continue;
            }
            self.step(c, state);
        }
    }

    fn step(self: *ApiServer, c: *Conn, state: *State) void {
        if (c.replying) {
            self.flush(c);
            return;
        }

        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = posix.read(c.fd, &chunk) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    self.dropConn(c);
                    return;
                },
            };
            if (n == 0) {
                // Peer closed before sending a whole request.
                self.dropConn(c);
                return;
            }
            c.buf.appendSlice(self.allocator, chunk[0..n]) catch {
                self.dropConn(c);
                return;
            };

            if (c.need == null and c.buf.items.len >= 4) {
                const len = std.mem.readInt(u32, c.buf.items[0..4], .big);
                if (len == 0 or len > MAX_REQUEST) {
                    self.reply(c, "{\"ok\":false,\"error\":\"request too large\"}");
                    return;
                }
                c.need = len;
            }
            if (c.need) |need| {
                if (c.buf.items.len >= 4 + need) {
                    self.handle(c, state, c.buf.items[4 .. 4 + need]);
                    return;
                }
            }
            if (c.buf.items.len > MAX_REQUEST + 4) {
                self.reply(c, "{\"ok\":false,\"error\":\"request too large\"}");
                return;
            }
        }
    }

    fn reply(self: *ApiServer, c: *Conn, body: []const u8) void {
        c.out.clearRetainingCapacity();
        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u32, &hdr, @intCast(body.len), .big);
        c.out.appendSlice(self.allocator, &hdr) catch {
            self.dropConn(c);
            return;
        };
        c.out.appendSlice(self.allocator, body) catch {
            self.dropConn(c);
            return;
        };
        c.out_sent = 0;
        c.replying = true;
        self.flush(c);
    }

    fn flush(self: *ApiServer, c: *Conn) void {
        while (c.out_sent < c.out.items.len) {
            const n = posix.write(c.fd, c.out.items[c.out_sent..]) catch |err| switch (err) {
                // The reply is finished next iteration; the loop must not wait
                // on a client that is not reading.
                error.WouldBlock => return,
                else => {
                    self.dropConn(c);
                    return;
                },
            };
            if (n == 0) {
                self.dropConn(c);
                return;
            }
            c.out_sent += n;
        }
        self.dropConn(c);
    }

    fn fail(self: *ApiServer, c: *Conn, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const w = stream.writer();
        w.writeAll("{\"ok\":false,\"error\":") catch return self.reply(c, "{\"ok\":false,\"error\":\"failed\"}");
        var msg_buf: [400]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch "failed";
        core.regions.writeJsonString(w, msg) catch return self.reply(c, "{\"ok\":false,\"error\":\"failed\"}");
        w.writeAll("}") catch return self.reply(c, "{\"ok\":false,\"error\":\"failed\"}");
        self.reply(c, stream.getWritten());
    }

    /// Run one request against the live API.
    fn handle(self: *ApiServer, c: *Conn, state: *State, body: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
            return self.fail(c, "request is not valid JSON", .{});
        };
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return self.fail(c, "request must be a JSON object", .{}),
        };
        const call = switch (obj.get("call") orelse return self.fail(c, "request has no `call`", .{})) {
            .string => |s| s,
            else => return self.fail(c, "`call` must be a string", .{}),
        };

        const rt = state.config._lua_runtime orelse {
            return self.fail(c, "no Lua runtime; the live API is unavailable", .{});
        };

        // Accessors read this pointer, exactly as they do for a keybind
        // callback. `.handler` and not `.predicate`: a control request is a
        // deliberate act, not something evaluated on every keypress.
        const scope = lua_api.pushLiveState(rt, state, .handler);
        defer lua_api.popLiveState(rt, scope);

        const base = rt.lua.getTop();
        defer rt.lua.setTop(base);

        if (!lua_api.pushCallbackContext(rt)) {
            return self.fail(c, "the live API table is not installed", .{});
        }
        if (rt.lua.getField(-1, @ptrCast(callName(call))) != .function) {
            return self.fail(c, "no such call: {s}", .{call});
        }

        var argc: i32 = 0;
        if (obj.get("arg")) |arg| {
            if (arg != .null) {
                api_json.push(rt.lua, arg, 0) catch {
                    return self.fail(c, "argument is too deeply nested", .{});
                };
                argc = 1;
            }
        }

        rt.lua.protectedCall(.{ .args = argc, .results = 1 }) catch {
            const err = rt.lua.toString(-1) catch "call failed";
            return self.fail(c, "{s}", .{err});
        };

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        out.appendSlice(self.allocator, "{\"ok\":true,\"result\":") catch {
            return self.fail(c, "out of memory", .{});
        };
        api_json.write(rt.lua, -1, out.writer(self.allocator), 0) catch |err| {
            return self.fail(c, "result could not be encoded: {s}", .{@errorName(err)});
        };
        out.appendSlice(self.allocator, "}") catch {
            return self.fail(c, "out of memory", .{});
        };
        if (out.items.len > MAX_RESPONSE) {
            return self.fail(c, "result exceeds {d} bytes", .{MAX_RESPONSE});
        }

        // A control call can change what is on screen.
        state.needs_render = true;
        self.reply(c, out.items);
    }
};

/// Copy a call name into a sentinel-terminated buffer for `getField`.
///
/// Rejected names simply miss in the table and are reported as unknown, so an
/// over-long or embedded-NUL name cannot reach Lua at all.
var name_buf: [64:0]u8 = undefined;

fn callName(call: []const u8) [:0]const u8 {
    if (call.len >= name_buf.len) return "";
    @memcpy(name_buf[0..call.len], call);
    name_buf[call.len] = 0;
    return name_buf[0..call.len :0];
}
