//! `hexe api <call> [json-arg]` — one call against a running mux.
//!
//! The same request any other client makes, so the CLI doubles as the way to
//! see what a web gateway would receive. Output is the raw JSON reply: this is
//! a machine interface, and formatting it for eyes would only invite scraping
//! the formatting.

const std = @import("std");
const core = @import("core");

const print = std.debug.print;

/// The reply can carry a whole screen's text, so the ceiling is generous; it
/// exists to bound a malformed length header, not to limit real answers.
const MAX_REPLY = 16 * 1024 * 1024;

fn socketPath(allocator: std.mem.Allocator, session: []const u8) ![]u8 {
    const dir = try core.ipc.getSocketDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/api@{s}.sock", .{ dir, session });
}

/// Every session with a control socket, keyed the way its socket is named.
fn listeningSessions(allocator: std.mem.Allocator) ![][]u8 {
    const dir = try core.ipc.getSocketDir(allocator);
    defer allocator.free(dir);

    var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch return error.NoControlSocket;
    defer d.close();

    var keys: std.ArrayList([]u8) = .empty;
    errdefer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit(allocator);
    }
    var it = d.iterate();
    while (try it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "api@")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sock")) continue;
        try keys.append(allocator, try allocator.dupe(u8, entry.name["api@".len .. entry.name.len - ".sock".len]));
    }
    return keys.toOwnedSlice(allocator);
}

fn freeKeys(allocator: std.mem.Allocator, keys: [][]u8) void {
    for (keys) |k| allocator.free(k);
    allocator.free(keys);
}

/// Whether the session listening on `path` calls itself `wanted`.
///
/// Asked of the session rather than read off the socket's filename, because the
/// filename is only its name at bind time -- `hexe.live.session` says so
/// itself -- while a caller may hold either spelling.
fn answersTo(allocator: std.mem.Allocator, path: []const u8, wanted: []const u8) bool {
    const reply = request(allocator, path, path, "{\"call\":\"session\"}", true) catch return false;
    defer allocator.free(reply);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, reply, .{}) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return false,
    };
    const list = switch (root.get("result") orelse return false) {
        .array => |a| a,
        else => return false,
    };
    if (list.items.len == 0) return false;
    const rec = switch (list.items[0]) {
        .object => |o| o,
        else => return false,
    };
    for ([_][]const u8{ "name", "uuid" }) |field| {
        if (rec.get(field)) |v| switch (v) {
            .string => |s| if (std.mem.eql(u8, s, wanted)) return true,
            else => {},
        };
    }
    return false;
}

/// The only session with a control socket, when the caller did not name one.
///
/// Guessing among several would act on the wrong session sooner or later, so
/// more than one is an error that names the candidates instead.
fn soleSession(allocator: std.mem.Allocator) ![]u8 {
    const dir = try core.ipc.getSocketDir(allocator);
    defer allocator.free(dir);

    var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch return error.NoControlSocket;
    defer d.close();

    var found: ?[]u8 = null;
    var extra: usize = 0;
    var it = d.iterate();
    while (try it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "api@")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sock")) continue;
        const name = entry.name["api@".len .. entry.name.len - ".sock".len];
        if (found == null) {
            found = try allocator.dupe(u8, name);
        } else {
            extra += 1;
            print("Error: several sessions are listening; pass --session\n", .{});
        }
    }
    if (extra > 0) {
        if (found) |f| allocator.free(f);
        return error.AmbiguousSession;
    }
    return found orelse error.NoControlSocket;
}

/// Which socket to call, and what to call it in an error.
pub const Endpoint = struct {
    label: []u8,
    path: []u8,

    pub fn deinit(self: Endpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.path);
    }
};

/// The socket a call should go to.
///
/// In order: an explicit `--session`, then `HEXE_API_SOCKET` (a path, so no
/// guessing -- it is what a plugin is handed), then `HEXE_SESSION`, then the
/// only session listening.
///
/// `HEXE_SESSION` is NOT the socket's filename, which is what this used to
/// assume. Every pane gets the session's UUID there, while the socket is named
/// for the session's name at bind time, so `api@$HEXE_SESSION.sock` did not
/// exist and `hexe api` failed inside a pane with "FileNotFound" -- the one
/// place it is most useful. `hexe.live.session` already warns that the name is
/// not a reliable key either, since a renamed or reattached session keeps its
/// old file. So a key with no socket of its own is not an error yet: the
/// sessions that ARE listening are asked whether they answer to it.
pub fn resolveEndpoint(allocator: std.mem.Allocator, session_opt: ?[]const u8) !Endpoint {
    if (session_opt == null) {
        if (std.posix.getenv("HEXE_API_SOCKET")) |sock| {
            if (sock.len > 0) return .{
                .label = try allocator.dupe(u8, "HEXE_API_SOCKET"),
                .path = try allocator.dupe(u8, sock),
            };
        }
    }

    const from_env: ?[]const u8 = if (session_opt == null) std.posix.getenv("HEXE_SESSION") else null;
    if (session_opt orelse from_env) |want| {
        if (want.len > 0) {
            const direct = try socketPath(allocator, want);
            if (std.fs.cwd().access(direct, .{})) |_| {
                return .{ .label = try allocator.dupe(u8, want), .path = direct };
            } else |_| {
                allocator.free(direct);
            }

            const keys = listeningSessions(allocator) catch try allocator.alloc([]u8, 0);
            defer freeKeys(allocator, keys);
            for (keys) |key| {
                const candidate = try socketPath(allocator, key);
                if (answersTo(allocator, candidate, want)) {
                    return .{ .label = try allocator.dupe(u8, key), .path = candidate };
                }
                allocator.free(candidate);
            }

            print("Error: no listening session answers to '{s}'\n", .{want});
            if (keys.len == 0) {
                print("       Nothing is listening; is hexe attached?\n", .{});
            } else {
                print("       Listening:", .{});
                for (keys) |key| print(" {s}", .{key});
                print("\n", .{});
            }
            return error.NoSession;
        }
    }

    const sole = soleSession(allocator) catch |err| {
        switch (err) {
            error.NoControlSocket => print("Error: no running session is listening; is hexe attached?\n", .{}),
            error.AmbiguousSession => {},
            else => print("Error: {s}\n", .{@errorName(err)}),
        }
        return error.NoSession;
    };
    errdefer allocator.free(sole);
    return .{ .label = sole, .path = try socketPath(allocator, sole) };
}

pub fn run(
    allocator: std.mem.Allocator,
    call: []const u8,
    arg_json: ?[]const u8,
    arg2_json: ?[]const u8,
    session_opt: ?[]const u8,
) !void {
    if (call.len == 0) {
        print("Error: a call name is required\n", .{});
        return error.InvalidArgument;
    }

    const endpoint = try resolveEndpoint(allocator, session_opt);
    defer endpoint.deinit(allocator);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    const w = body.writer(allocator);
    try w.writeAll("{\"call\":");
    try core.regions.writeJsonString(w, call);
    // Validated here rather than at the far end: a malformed argument should
    // name itself locally, not come back as a generic refusal.
    const check = struct {
        fn go(alloc: std.mem.Allocator, text: []const u8) !void {
            var parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch {
                print("Error: argument is not valid JSON: {s}\n", .{text});
                return error.InvalidArgument;
            };
            parsed.deinit();
        }
    }.go;

    const a1: ?[]const u8 = if (arg_json) |a| (if (a.len > 0) a else null) else null;
    const a2: ?[]const u8 = if (arg2_json) |a| (if (a.len > 0) a else null) else null;

    if (a2) |second| {
        // Two arguments means a positional call -- `geometry <sel> <spec>`,
        // `ratio <sel> <value>` -- which a single `arg` cannot express.
        const first = a1 orelse "null";
        try check(allocator, first);
        try check(allocator, second);
        try w.writeAll(",\"args\":[");
        try w.writeAll(first);
        try w.writeAll(",");
        try w.writeAll(second);
        try w.writeAll("]");
    } else if (a1) |only| {
        try check(allocator, only);
        try w.writeAll(",\"arg\":");
        try w.writeAll(only);
    }
    try w.writeAll("}");

    const reply = try request(allocator, endpoint.label, endpoint.path, body.items, false);
    defer allocator.free(reply);

    // `hexe api` is a client like any other, so it unwraps. The wire carries a
    // list of return values (`n` + `result`), which is what lets a sibling's
    // client read hexe at all; a person or a script reading this output wants
    // the value, and has done since before the wire changed.
    var out = std.fs.File.stdout().deprecatedWriter();
    try writeUnwrapped(&out, reply);
    try out.writeAll("\n");

    // The exit code follows the call, so a script can branch on it without
    // parsing the body.
    if (std.mem.startsWith(u8, reply, "{\"ok\":false")) return error.CallFailed;
}

/// One framed request/response against a control socket.
///
/// `quiet` is for probing: working out which of several sessions answers to a
/// name means connecting to each, and reporting every miss would bury the one
/// message the caller needs.
fn request(
    allocator: std.mem.Allocator,
    label: []const u8,
    path: []const u8,
    body: []const u8,
    quiet: bool,
) ![]u8 {
    const stream = std.net.connectUnixSocket(path) catch |err| {
        if (!quiet) print("Error: cannot reach session '{s}': {s}\n", .{ label, @errorName(err) });
        return error.NotConnected;
    };
    defer stream.close();

    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, @intCast(body.len), .big);
    try stream.writeAll(&hdr);
    try stream.writeAll(body);

    var len_buf: [4]u8 = undefined;
    var got: usize = 0;
    while (got < 4) {
        const n = try stream.read(len_buf[got..]);
        if (n == 0) {
            if (!quiet) print("Error: session closed the connection without replying\n", .{});
            return error.UnexpectedEof;
        }
        got += n;
    }
    const len = std.mem.readInt(u32, &len_buf, .big);
    if (len > MAX_REPLY) {
        if (!quiet) print("Error: reply is implausibly large ({d} bytes)\n", .{len});
        return error.StreamTooLong;
    }

    const reply = try allocator.alloc(u8, len);
    errdefer allocator.free(reply);
    got = 0;
    while (got < len) {
        const n = try stream.read(reply[got..]);
        if (n == 0) {
            if (!quiet) print("Error: reply was truncated\n", .{});
            return error.UnexpectedEof;
        }
        got += n;
    }
    return reply;
}

/// Turn `{"ok":true,"n":1,"result":[V]}` back into `{"ok":true,"result":V}`.
///
/// Textual rather than a parse-and-re-encode: re-encoding would mean a second
/// JSON writer in the CLI, and two encoders of the same values drift the moment
/// either is touched. Anything that does not match the exact prefix is passed
/// through unchanged, so an error reply or a future shape is never mangled.
/// Written in pieces rather than assembled first. Building the unwrapped reply
/// needed somewhere to put it, and that somewhere was a `[MAX_REPLY]u8` static
/// -- 16 MB of `.bss` reserved for every `hexe` process ever started, to hold a
/// reply that is usually a few dozen bytes. The output is written immediately,
/// so there is no reason to have it contiguous anywhere.
fn writeUnwrapped(out: anytype, reply: []const u8) !void {
    const head = "{\"ok\":true,\"n\":1,\"result\":[";
    if (!std.mem.startsWith(u8, reply, head) or !std.mem.endsWith(u8, reply, "]}")) {
        try out.writeAll(reply);
        return;
    }
    try out.writeAll("{\"ok\":true,\"result\":");
    try out.writeAll(reply[head.len .. reply.len - 2]);
    try out.writeAll("}");
}
