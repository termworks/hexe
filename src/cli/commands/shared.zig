const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const pod_meta = core.pod_meta;

/// Parse a ` key=value` field from a line.
/// Returns the value (until next space or end of line), or null if not found.
pub fn parseField(line: []const u8, key: []const u8) ?[]const u8 {
    var pat_buf: [64]u8 = undefined;
    if (key.len + 2 > pat_buf.len) return null;
    pat_buf[0] = ' ';
    @memcpy(pat_buf[1 .. 1 + key.len], key);
    pat_buf[1 + key.len] = '=';
    const pat = pat_buf[0 .. 2 + key.len];

    const start = std.mem.indexOf(u8, line, pat) orelse return null;
    const val_start = start + pat.len;
    const rest = line[val_start..];
    const end_rel = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    return rest[0..end_rel];
}

pub fn parseFieldDecodedAlloc(allocator: std.mem.Allocator, line: []const u8, key: []const u8) !?[]u8 {
    const raw = parseField(line, key) orelse return null;
    return decodePercentAlloc(allocator, raw);
}

pub fn isUuid32Hex(uuid: []const u8) bool {
    if (uuid.len != 32) return false;
    for (uuid) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// Whether a selector looks like a uuid rather than a name.
///
/// Hex and at least 4 characters. A pane name is lowercase alphanumeric too, so
/// the two alphabets overlap — but a name short enough to be confused with a
/// prefix (`fade`, `beef`) is resolved as a uuid prefix first and falls through
/// to a name only if nothing matches, which `resolvePaneTarget` handles by
/// asking twice rather than by guessing here.
pub fn looksLikeUuidPrefix(sel: []const u8) bool {
    if (sel.len < 4 or sel.len > 32) return false;
    for (sel) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// How a pane was named on the command line.
pub const PaneTarget = struct {
    /// `--uuid`: a full uuid or a prefix of one.
    uuid: []const u8 = "",
    /// `--pane`: a name, unique within its session.
    pane: []const u8 = "",
    /// `--session`: which session `pane` belongs to. Empty means any, which is
    /// an error only if the name turns out to be ambiguous.
    session: []const u8 = "",
    /// `--creator` / `--last`, resolved against the pane this command runs in.
    creator: bool = false,
    last: bool = false,
};

/// What a resolved target is, and whether the whole-session verbs can reach it.
pub const ResolvedPane = struct {
    uuid: [32]u8,
    /// False when the owning session has no frontend attached. Typing still
    /// works (it goes to the pod); keys, focus and screen reads do not.
    attached: bool,
};

pub const ResolveError = error{
    NoTarget,
    NoSuchSession,
    NoSuchPane,
    Ambiguous,
    Unreachable,
};

/// Type into a pane, by writing to the pod that owns its pty.
///
/// The pod, not the session daemon, because the pod is what survives: a
/// detached session has no frontend for SES to route input through, so
/// `send_keys` reached nothing and still reported success. The pod holds the
/// pty whether anyone is attached or not, so this is the one delivery that
/// works in both cases.
pub fn writePodInput(allocator: std.mem.Allocator, uuid: [32]u8, data: []const u8) !void {
    const socket_path = try ipc.getPodSocketPath(allocator, &uuid);
    defer allocator.free(socket_path);

    var client = ipc.Client.connect(socket_path) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) return error.PodNotRunning;
        return err;
    };
    defer client.close();

    try core.wire.sendHandshake(client.fd, core.wire.POD_HANDSHAKE_AUX_INPUT);
    var conn = client.toConnection();
    try core.pod_protocol.writeFrame(&conn, .input, data);
}

pub const PodRead = struct {
    text: []u8,
    /// The ring had already dropped its oldest bytes, so this may start
    /// mid-history.
    truncated: bool,
};

/// Read a pane's text back from the pod that owns its pty.
///
/// The same reach as `writePodInput`, and for the same reason: the pod holds
/// the scrollback whether or not a frontend is attached.
pub fn readPod(
    allocator: std.mem.Allocator,
    uuid: [32]u8,
    mode: core.wire.PodReadMode,
    count: u32,
) !PodRead {
    const socket_path = try ipc.getPodSocketPath(allocator, &uuid);
    defer allocator.free(socket_path);

    var client = ipc.Client.connect(socket_path) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) return error.PodNotRunning;
        return err;
    };
    defer client.close();

    const hello = [_]u8{ core.wire.POD_HANDSHAKE_AUX_READ, core.wire.PROTOCOL_VERSION };
    try core.wire.writeAll(client.fd, &hello);
    const req: core.wire.PodReadRequest = .{ .mode = @intFromEnum(mode), .count = count };
    try core.wire.writeAll(client.fd, std.mem.asBytes(&req));

    var reply: core.wire.PodReadReply = undefined;
    try core.wire.readExact(client.fd, std.mem.asBytes(&reply));

    switch (@as(core.wire.PodReadOutcome, @enumFromInt(reply.outcome))) {
        .no_marks => return error.NoPromptMarks,
        .unreadable => return error.PaneUnreadable,
        .ok => {},
    }

    if (reply.text_len == 0) {
        return .{ .text = try allocator.alloc(u8, 0), .truncated = reply.truncated != 0 };
    }
    if (reply.text_len > core.wire.MAX_PAYLOAD_LEN) return error.ReplyTooLarge;
    const text = try allocator.alloc(u8, reply.text_len);
    errdefer allocator.free(text);
    try core.wire.readExact(client.fd, text);
    return .{ .text = text, .truncated = reply.truncated != 0 };
}

/// The exit status for a failed resolve, so a script can branch without parsing.
pub fn resolveExitCode(err: ResolveError) u8 {
    return switch (err) {
        ResolveError.NoTarget => 1,
        ResolveError.Unreachable => 2,
        ResolveError.NoSuchSession, ResolveError.NoSuchPane => 3,
        ResolveError.Ambiguous => 4,
    };
}

pub fn resolvePodSocketTarget(
    allocator: std.mem.Allocator,
    uuid: []const u8,
    name: []const u8,
    socket_path: []const u8,
) ![]const u8 {
    if (socket_path.len > 0) {
        return allocator.dupe(u8, socket_path);
    }
    if (uuid.len > 0) {
        if (!isUuid32Hex(uuid)) {
            return error.InvalidUuid;
        }
        return ipc.getPodSocketPath(allocator, uuid);
    }
    if (name.len > 0) {
        if (try findNewestPodMetaByName(allocator, name)) |match| {
            return ipc.getPodSocketPath(allocator, &match.uuid);
        }
        return pod_meta.PodMeta.aliasSocketPath(allocator, name);
    }
    return error.MissingTarget;
}

pub fn resolveNewestPodPidByName(allocator: std.mem.Allocator, name: []const u8) !?i64 {
    if (name.len == 0) return null;
    const match = try findNewestPodMetaByName(allocator, name);
    if (match) |m| {
        return m.pid;
    }
    return null;
}

const PodMetaMatch = struct {
    uuid: [32]u8,
    pid: i64,
    created_at: i64,
};

fn findNewestPodMetaByName(allocator: std.mem.Allocator, name: []const u8) !?PodMetaMatch {
    const dir = try ipc.getSocketDir(allocator);
    defer allocator.free(dir);

    var best: ?PodMetaMatch = null;
    var matches: usize = 0;

    var d = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer d.close();
    var it = d.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "pod-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".meta")) continue;

        var f = d.openFile(entry.name, .{}) catch continue;
        defer f.close();
        var buf: [4096]u8 = undefined;
        const n = f.readAll(&buf) catch continue;
        if (n == 0) continue;
        const line = std.mem.trim(u8, buf[0..n], " \t\n\r");
        if (!std.mem.startsWith(u8, line, pod_meta.POD_META_PREFIX)) continue;

        const name_val = parseField(line, "name") orelse continue;
        const name_decoded = decodePercentAlloc(allocator, name_val) catch continue;
        defer allocator.free(name_decoded);
        if (!std.mem.eql(u8, name_decoded, name)) continue;

        const uuid_text = parseField(line, "uuid") orelse continue;
        if (!isUuid32Hex(uuid_text)) continue;

        const pid_text = parseField(line, "pid") orelse continue;
        const pid = std.fmt.parseInt(i64, pid_text, 10) catch continue;
        const created_at_text = parseField(line, "created_at") orelse "0";
        const created_at = std.fmt.parseInt(i64, created_at_text, 10) catch 0;

        // Counted, not overwritten. This used to keep the NEWEST match with no
        // diagnostic, which was harmless only while pane names were unique per
        // daemon. They are unique per SESSION now, so two sessions may each
        // have a `romeo` and picking the newer one would signal or type into
        // whichever pane happened to start last -- `pod kill --name` sends a
        // signal to the pid this returns.
        matches += 1;
        if (best == null or created_at >= best.?.created_at) {
            var uuid_buf: [32]u8 = undefined;
            @memcpy(&uuid_buf, uuid_text[0..32]);
            best = .{ .uuid = uuid_buf, .pid = pid, .created_at = created_at };
        }
    }

    if (matches > 1) return error.AmbiguousPodName;
    return best;
}

pub fn decodePercentAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, value, '%') == null) {
        return allocator.dupe(u8, value);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == '%' and i + 2 < value.len) {
            const hi = std.fmt.charToDigit(value[i + 1], 16) catch {
                try out.append(allocator, value[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(value[i + 2], 16) catch {
                try out.append(allocator, value[i]);
                i += 1;
                continue;
            };
            try out.append(allocator, @as(u8, @intCast((hi << 4) | lo)));
            i += 3;
            continue;
        }
        try out.append(allocator, value[i]);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

test "parseField basic" {
    const line = " uuid=abc123 pid=456 state=running";
    try std.testing.expectEqualSlices(u8, "abc123", parseField(line, "uuid").?);
    try std.testing.expectEqualSlices(u8, "456", parseField(line, "pid").?);
    try std.testing.expectEqualSlices(u8, "running", parseField(line, "state").?);
    try std.testing.expect(parseField(line, "missing") == null);
}

test "parseFieldDecodedAlloc decodes percent escapes" {
    const alloc = std.testing.allocator;
    const line = " uuid=abc name=hello%20world cwd=/tmp/a%20b";
    const name = (try parseFieldDecodedAlloc(alloc, line, "name")).?;
    defer alloc.free(name);
    const cwd = (try parseFieldDecodedAlloc(alloc, line, "cwd")).?;
    defer alloc.free(cwd);
    try std.testing.expectEqualSlices(u8, "hello world", name);
    try std.testing.expectEqualSlices(u8, "/tmp/a b", cwd);
}

const wire = core.wire;

/// Read a one-shot CLI reply and report it. SES answers every CLI request with
/// `.ok` or `.error` + message; a caller that writes and prints success without
/// reading this cannot tell "applied" from "pane not attached".
/// Returns true on `.ok`; prints the reason and returns false otherwise.
pub fn readOkOrError(allocator: std.mem.Allocator, fd: std.posix.fd_t) bool {
    const print = std.debug.print;
    const hdr = wire.readControlHeader(fd) catch |err| {
        print("Error: no reply from ses daemon: {s}\n", .{@errorName(err)});
        return false;
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type == .ok) return true;
    if (msg_type != .@"error") {
        print("Error: unexpected reply from ses daemon\n", .{});
        return false;
    }
    if (hdr.payload_len == 0 or hdr.payload_len > wire.MAX_PAYLOAD_LEN) {
        print("Error: ses daemon reported failure\n", .{});
        return false;
    }
    const buf = allocator.alloc(u8, hdr.payload_len) catch {
        print("Error: ses daemon reported failure\n", .{});
        return false;
    };
    defer allocator.free(buf);
    wire.readExact(fd, buf) catch {
        print("Error: ses daemon reported failure\n", .{});
        return false;
    };
    if (buf.len > @sizeOf(wire.Error)) {
        const e = std.mem.bytesToValue(wire.Error, buf[0..@sizeOf(wire.Error)]);
        const start = @sizeOf(wire.Error);
        const end = @min(buf.len, start + e.msg_len);
        if (end > start) {
            print("Error: {s}\n", .{buf[start..end]});
            return false;
        }
    }
    print("Error: ses daemon reported failure\n", .{});
    return false;
}
