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

    // A script running inside a pane means its own session, not whichever one
    // happens to be the only listener. Scanning is the fallback for callers
    // outside hexe entirely.
    const from_env: ?[]const u8 = if (session_opt == null) std.posix.getenv("HEXE_SESSION") else null;
    const session = if (session_opt orelse from_env) |s| try allocator.dupe(u8, s) else soleSession(allocator) catch |err| {
        switch (err) {
            error.NoControlSocket => print("Error: no running session is listening; is hexe attached?\n", .{}),
            error.AmbiguousSession => {},
            else => print("Error: {s}\n", .{@errorName(err)}),
        }
        return error.NoSession;
    };
    defer allocator.free(session);

    const path = try socketPath(allocator, session);
    defer allocator.free(path);

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

    const stream = std.net.connectUnixSocket(path) catch |err| {
        print("Error: cannot reach session '{s}': {s}\n", .{ session, @errorName(err) });
        return error.NotConnected;
    };
    defer stream.close();

    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, @intCast(body.items.len), .big);
    try stream.writeAll(&hdr);
    try stream.writeAll(body.items);

    var len_buf: [4]u8 = undefined;
    var got: usize = 0;
    while (got < 4) {
        const n = try stream.read(len_buf[got..]);
        if (n == 0) {
            print("Error: session closed the connection without replying\n", .{});
            return error.UnexpectedEof;
        }
        got += n;
    }
    const len = std.mem.readInt(u32, &len_buf, .big);
    if (len > MAX_REPLY) {
        print("Error: reply is implausibly large ({d} bytes)\n", .{len});
        return error.StreamTooLong;
    }

    const reply = try allocator.alloc(u8, len);
    defer allocator.free(reply);
    got = 0;
    while (got < len) {
        const n = try stream.read(reply[got..]);
        if (n == 0) {
            print("Error: reply was truncated\n", .{});
            return error.UnexpectedEof;
        }
        got += n;
    }

    var out = std.fs.File.stdout().deprecatedWriter();
    try out.writeAll(reply);
    try out.writeAll("\n");

    // The exit code follows the call, so a script can branch on it without
    // parsing the body.
    if (std.mem.startsWith(u8, reply, "{\"ok\":false")) return error.CallFailed;
}
