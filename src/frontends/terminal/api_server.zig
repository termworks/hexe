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
//!     <- {"ok":true,"n":1,"result":[ ... ]}
//!
//! `result` is a LIST of return values and `n` says how many, which is the
//! convention oslo's server already uses. One shape across the family means one
//! client library reads either tool; before this, hexe answered with the value
//! itself and oslo's client -- which unpacks -- silently lost every record,
//! string and number it was told.
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

/// Positional arguments one call may take. The widest live-API verb takes two.
const MAX_ARGS = 8;

/// How long a half-finished request may sit before its connection is dropped.
const CONN_TIMEOUT_MS: i64 = 5_000;

/// How many accepts to take per loop iteration, so a flood cannot starve
/// rendering.
const ACCEPTS_PER_TICK = 4;

/// How much undelivered event traffic a subscriber may accumulate before it is
/// dropped. A phone on a bad link must not be able to grow the mux's memory:
/// past this point the client is not keeping up and disconnecting it is the
/// honest outcome.
const MAX_SUBSCRIBER_BACKLOG = 1024 * 1024;

const Conn = struct {
    fd: posix.socket_t = -1,
    buf: std.ArrayList(u8) = .empty,
    /// Response bytes still to be written, and how far we got.
    out: std.ArrayList(u8) = .empty,
    out_sent: usize = 0,
    need: ?u32 = null,
    started_ms: i64 = 0,
    replying: bool = false,
    /// Once subscribed, the connection stays open and receives event frames
    /// instead of being closed after a reply.
    subscribed: bool = false,
    /// Event names this client asked for. Empty means every event.
    filter: std.ArrayList([]u8) = .empty,

    fn active(self: *const Conn) bool {
        return self.fd >= 0;
    }

    fn wants(self: *const Conn, event: []const u8) bool {
        if (self.filter.items.len == 0) return true;
        for (self.filter.items) |f| {
            if (std.mem.eql(u8, f, event)) return true;
        }
        return false;
    }
};

pub const ApiServer = struct {
    allocator: std.mem.Allocator,
    fd: posix.socket_t = -1,
    path: []u8 = &.{},
    conns: [MAX_CONNS]Conn = @splat(.{}),
    /// What callers on THIS socket may do. The session's own socket holds
    /// everything; a plugin's socket holds what it asked for.
    granted: core.access.Set = core.access.Set.all,

    /// Bind the socket for `session`, replacing a stale one left by a crash.
    pub fn init(allocator: std.mem.Allocator, session: []const u8) !ApiServer {
        return initScoped(allocator, session, null, core.access.Set.all);
    }

    /// A second socket for one plugin, carrying only what that plugin declared.
    ///
    /// A separate socket rather than a token on the shared one: a token the
    /// caller supplies is a token the caller can omit, and then the grant means
    /// nothing. A path the plugin is handed, and a listener that knows its own
    /// authority, cannot be talked out of it.
    pub fn initScoped(
        allocator: std.mem.Allocator,
        session: []const u8,
        plugin: ?[]const u8,
        granted: core.access.Set,
    ) !ApiServer {
        const dir = try core.ipc.getSocketDir(allocator);
        defer allocator.free(dir);
        std.fs.cwd().makePath(dir) catch {};

        // `plug@` and not `api@`: session discovery globs `api@*.sock` to find
        // what is listening, so naming a plugin's socket that way made three
        // plugins look like three more sessions and `hexe api` refused to pick
        // one. Different prefix, same directory, no ambiguity.
        const path = if (plugin) |p|
            try std.fmt.allocPrint(allocator, "{s}/plug@{s}.{s}.sock", .{ dir, session, p })
        else
            try std.fmt.allocPrint(allocator, "{s}/api@{s}.sock", .{ dir, session });
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

        return .{ .allocator = allocator, .fd = fd, .path = path, .granted = granted };
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
        c.subscribed = false;
        for (c.filter.items) |f| self.allocator.free(f);
        c.filter.deinit(self.allocator);
        c.filter = .empty;
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
            // Who connected, from the kernel rather than from anything the
            // peer said. The socket is already 0600 in a 0700 directory, so
            // this should be unreachable -- which is exactly why it is cheap
            // insurance against a runtime directory that is not what we assume.
            if (core.ipc.getPeerCredentials(cfd)) |peer| {
                if (peer.uid != std.os.linux.getuid()) {
                    log.warn("refused a control connection from uid {d}", .{peer.uid});
                    posix.close(cfd);
                    continue;
                }
            }

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
            // The timeout is for a request that never finished arriving. A
            // subscriber is idle on purpose and must not be reaped for it.
            if (!c.subscribed and now - c.started_ms > CONN_TIMEOUT_MS) {
                self.dropConn(c);
                continue;
            }
            self.step(c, state);
        }
    }

    fn step(self: *ApiServer, c: *Conn, state: *State) void {
        if (c.subscribed) {
            self.flush(c);
            if (!c.active()) return;
            // Notice a subscriber that has gone away, so its slot comes back.
            var probe: [256]u8 = undefined;
            const n = posix.read(c.fd, &probe) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    self.dropConn(c);
                    return;
                },
            };
            if (n == 0) self.dropConn(c);
            return;
        }
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
        c.out.clearRetainingCapacity();
        c.out_sent = 0;
        if (c.subscribed) return;

        // Ready for another request on the same connection rather than closed.
        //
        // Closing after one reply was cheap and made hexe unreadable by a
        // sibling: oslo's client holds one connection and reuses it, so its
        // second call died with a broken pipe. Keeping it costs nothing that is
        // not already bounded -- eight connections, and CONN_TIMEOUT_MS reaps
        // one that goes quiet -- and a client that wants one-shot simply closes.
        c.replying = false;
        c.need = null;
        c.buf.clearRetainingCapacity();
        c.started_ms = std.time.milliTimestamp();
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

    /// Turn this connection into an event stream.
    ///
    /// `{"subscribe":true}` or `{"subscribe":[]}` takes every event;
    /// `{"subscribe":["pane_focus_changed"]}` takes only those named.
    fn subscribe(self: *ApiServer, c: *Conn, spec: std.json.Value) void {
        switch (spec) {
            .bool => {},
            .array => |a| {
                for (a.items) |item| {
                    const name = switch (item) {
                        .string => |str| str,
                        else => return self.fail(c, "event names must be strings", .{}),
                    };
                    const owned = self.allocator.dupe(u8, name) catch {
                        return self.fail(c, "out of memory", .{});
                    };
                    c.filter.append(self.allocator, owned) catch {
                        self.allocator.free(owned);
                        return self.fail(c, "out of memory", .{});
                    };
                }
            },
            else => return self.fail(c, "`subscribe` must be true or a list of event names", .{}),
        }

        // Marked before the acknowledgement is queued, so writing it does not
        // close the connection the way a one-shot reply would.
        c.subscribed = true;
        c.buf.clearRetainingCapacity();
        c.need = null;
        self.reply(c, "{\"ok\":true,\"n\":1,\"result\":[\"subscribed\"]}");
    }

    /// Hand one event to every subscriber that asked for it.
    ///
    /// `payload` is the event's JSON object, already encoded. Nothing here can
    /// fail loudly: an event is a side effect of something the user did, and a
    /// misbehaving control client must not disturb it.
    pub fn broadcast(self: *ApiServer, event: []const u8, payload: []const u8) void {
        for (&self.conns) |*c| {
            if (!c.active() or !c.subscribed) continue;
            if (!c.wants(event)) continue;
            if (c.out.items.len - c.out_sent > MAX_SUBSCRIBER_BACKLOG) {
                self.dropConn(c);
                continue;
            }
            var hdr: [4]u8 = undefined;
            std.mem.writeInt(u32, &hdr, @intCast(payload.len), .big);
            c.out.appendSlice(self.allocator, &hdr) catch {
                self.dropConn(c);
                continue;
            };
            c.out.appendSlice(self.allocator, payload) catch {
                self.dropConn(c);
                continue;
            };
            self.flush(c);
        }
    }

    /// Whether anything is listening, so the emit path can skip encoding when
    /// nobody would read it.
    pub fn hasSubscribers(self: *const ApiServer) bool {
        for (&self.conns) |*c| {
            if (c.active() and c.subscribed) return true;
        }
        return false;
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
        // Subscribing is not a call: the connection changes mode and stays
        // open, so it is handled before the live-API lookup.
        if (obj.get("subscribe")) |sub| {
            return self.subscribe(c, sub);
        }

        const call = switch (obj.get("call") orelse return self.fail(c, "request has no `call`", .{})) {
            .string => |s| s,
            else => return self.fail(c, "`call` must be a string", .{}),
        };

        // Refused before the verb runs, and named precisely: a plugin author
        // reading "needs typing access" knows exactly what to add to their
        // `access` list, where "permission denied" would send them guessing.
        if (lua_api.accessFor(call)) |needs| {
            if (!self.granted.has(needs)) {
                return self.fail(c, "call `{s}` needs `{s}` access, which this plugin was not granted", .{ call, needs.name() });
            }
        }

        const rt = state.config._lua_runtime orelse {
            return self.fail(c, "no Lua runtime; the live API is unavailable", .{});
        };

        // Accessors read this pointer, exactly as they do for a keybind
        // callback. `.handler` and not `.predicate`: a control request is a
        // deliberate act, not something evaluated on every keypress.
        // The grant has to reach the accessors too, not just the dispatch: a
        // `read` plugin calling `panes` must not be handed `pod_socket`, which
        // is the whole byte stream behind a field name.
        state.api_grant = self.granted;
        defer state.api_grant = core.access.Set.all;

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

        // The live API is positional -- `geometry(selector, spec)`,
        // `ratio(selector, value)` -- so one argument cannot express half of
        // it. `args` carries the whole list; `arg` stays the spelling for the
        // common single-argument call, and for one that IS a list.
        var argc: i32 = 0;
        if (obj.get("args")) |list| {
            const items = switch (list) {
                .array => |a| a.items,
                else => return self.fail(c, "`args` must be a list", .{}),
            };
            if (items.len > MAX_ARGS) {
                return self.fail(c, "at most {d} arguments", .{MAX_ARGS});
            }
            for (items) |item| {
                api_json.push(rt.lua, item, 0) catch {
                    return self.fail(c, "an argument is too deeply nested", .{});
                };
                argc += 1;
            }
        } else if (obj.get("arg")) |arg| {
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
        // A list of return values, with `n`. Every hexe verb answers with one,
        // so `n` is always 1 today -- but the shape is what makes a sibling's
        // client able to read this at all, and it is what a multi-return verb
        // would need without another protocol change.
        out.appendSlice(self.allocator, "{\"ok\":true,\"n\":1,\"result\":[") catch {
            return self.fail(c, "out of memory", .{});
        };
        api_json.write(rt.lua, -1, out.writer(self.allocator), 0) catch |err| {
            return self.fail(c, "result could not be encoded: {s}", .{@errorName(err)});
        };
        out.appendSlice(self.allocator, "]}") catch {
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
