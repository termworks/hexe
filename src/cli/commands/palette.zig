//! `hexe palette` — per-pane palette namespaces (PLAN.md M4).
//!
//! Every subcommand is a front door onto the OSC 1330 protocol: it builds the
//! sequence an application would emit and injects it into the target pane's
//! output stream through the pod. One code path serves CLI-driven and
//! app-driven changes, and because the bytes land in the pod's backlog, a
//! detach/reattach replays them (PLAN.md M5, §6 replay contract).
const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const wire = core.wire;
const palette = core.palette;
const pod_protocol = core.pod_protocol;
const pod_list = @import("pod_list.zig");
const shared = @import("shared.zig");

const print = std.debug.print;

pub const Error = error{
    NoPanes,
    BadArgument,
    NoEntries,
};

/// `hexe palette list` — the panes a palette change would reach.
///
/// Doubles as the capability probe M7's shell hook uses: a non-zero exit means
/// "not inside hexe, fall back". Each pane is followed by the namespaces that
/// actually carry colours and how many entries each holds; `hexe palette get`
/// prints the colours themselves.
pub fn runPaletteList(allocator: std.mem.Allocator, json_output: bool) !void {
    var records = std.ArrayList(pod_list.PodRecord).empty;
    defer {
        for (records.items) |r| pod_list.freeRecord(allocator, r);
        records.deinit(allocator);
    }
    try collectPods(allocator, &records);

    if (records.items.len == 0) {
        print("Error: no live panes to address\n", .{});
        return Error.NoPanes;
    }

    if (json_output) {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(allocator);
        var w = out.writer(allocator);
        try out.appendSlice(allocator, "[");
        for (records.items, 0..) |r, i| {
            if (i > 0) try out.appendSlice(allocator, ",");
            try w.print("{{\"uuid\":\"{s}\",\"name\":\"", .{r.uuid[0..]});
            // A pane name comes from `-n` and can hold a quote or a backslash.
            try core.strings.writeJsonEscaped(&w, r.name);
            try out.appendSlice(allocator, "\"}");
        }
        try out.appendSlice(allocator, "]\n");
        try std.fs.File.stdout().writeAll(out.items);
        return;
    }

    // A listing is data, so it goes to stdout — `print` here is std.debug.print,
    // which is stderr, and a caller piping this would get nothing.
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (records.items) |r| {
        try out.writer(allocator).print("pane uuid={s} name={s}", .{ r.uuid[0..], r.name });
        // Which namespaces this pane actually carries colours for, and how
        // many entries each. `default prompt output alt` always exist; saying
        // so for every pane is noise, while saying what is *set* is the thing
        // you asked the question to find out.
        if (fetchPalette(allocator, r.uuid)) |blob| {
            defer allocator.free(blob);
            var reader = palette.BlobReader.init(blob);
            while (reader.next()) |ns| {
                var extras: usize = 0;
                if (ns.fg != null) extras += 1;
                if (ns.bg != null) extras += 1;
                if (ns.cursor != null) extras += 1;
                try out.writer(allocator).print(" {d}={d}", .{ ns.slot, ns.count() + extras });
            }
        }
        try out.appendSlice(allocator, "\n");
    }
    try std.fs.File.stdout().writeAll(out.items);
}

/// `hexe palette get [--ns <name>] [--pane <uuid>] [<index> …]`
///
/// Read back what is actually set. Answered from the session daemon's parked
/// copy, so it works against a detached session too — which is when you most
/// want to ask what a pane is carrying.
pub fn runPaletteGet(
    allocator: std.mem.Allocator,
    ns_filter: []const u8,
    pane: []const u8,
    indices: []const []const u8,
) !void {
    var records = std.ArrayList(pod_list.PodRecord).empty;
    defer {
        for (records.items) |r| pod_list.freeRecord(allocator, r);
        records.deinit(allocator);
    }

    if (pane.len > 0) {
        if (!shared.isUuid32Hex(pane)) {
            print("Error: --pane must be a 32-character pane uuid\n", .{});
            return Error.BadArgument;
        }
    } else {
        try collectPods(allocator, &records);
        if (records.items.len == 0) {
            print("Error: no live panes to address\n", .{});
            return Error.NoPanes;
        }
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    if (pane.len > 0) {
        var uuid: [32]u8 = undefined;
        @memcpy(&uuid, pane[0..32]);
        try appendPanePalette(allocator, &out, uuid, ns_filter, indices);
    } else {
        for (records.items) |r| {
            try appendPanePalette(allocator, &out, r.uuid, ns_filter, indices);
        }
    }
    try std.fs.File.stdout().writeAll(out.items);
}

/// One pane's parked palette, filtered to `ns_filter` and `indices` if given.
fn appendPanePalette(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    uuid: [32]u8,
    ns_filter: []const u8,
    indices: []const []const u8,
) !void {
    const blob = fetchPalette(allocator, uuid) orelse return;
    defer allocator.free(blob);

    var reader = palette.BlobReader.init(blob);
    while (reader.next()) |namespace| {
        if (ns_filter.len > 0 and !std.mem.eql(u8, ns_filter, "*")) {
            const want = palette.NamespaceTable.parseSlot(ns_filter) orelse continue;
            if (want != namespace.slot) continue;
        }

        var w = out.writer(allocator);
        var i: usize = 0;
        while (i < namespace.count()) : (i += 1) {
            const entry = namespace.at(i);
            if (!wantsIndex(indices, entry.index)) continue;
            try w.print("{s} {d} {d}=#{x:0>2}{x:0>2}{x:0>2}\n", .{
                uuid[0..8],  namespace.slot, entry.index,
                entry.rgb.r, entry.rgb.g,    entry.rgb.b,
            });
        }
        // Defaults only when no explicit index filter was given: `get 3` asks
        // about index 3, not about the namespace's background.
        if (indices.len == 0) {
            if (namespace.fg) |c| try w.print("{s} {d} fg=#{x:0>2}{x:0>2}{x:0>2}\n", .{ uuid[0..8], namespace.slot, c.r, c.g, c.b });
            if (namespace.bg) |c| try w.print("{s} {d} bg=#{x:0>2}{x:0>2}{x:0>2}\n", .{ uuid[0..8], namespace.slot, c.r, c.g, c.b });
            if (namespace.cursor) |c| try w.print("{s} {d} cursor=#{x:0>2}{x:0>2}{x:0>2}\n", .{ uuid[0..8], namespace.slot, c.r, c.g, c.b });
        }
    }
}

fn wantsIndex(indices: []const []const u8, idx: u8) bool {
    if (indices.len == 0) return true;
    for (indices) |text| {
        const want = std.fmt.parseUnsigned(u16, text, 10) catch continue;
        if (want == idx) return true;
    }
    return false;
}

/// Ask SES for one pane's parked palette. Null when the daemon is unreachable
/// or the pane has none, which are both "nothing to print" rather than errors.
/// Set once the daemon has failed to answer, so a sweep over many panes stops
/// asking. `list` is the capability probe a theme hook runs on every change,
/// and one connection per pane at a 3s timeout turns a wedged daemon into a
/// multi-minute hang on a session with a lot of panes.
var ses_unreachable = false;

fn fetchPalette(allocator: std.mem.Allocator, uuid: [32]u8) ?[]u8 {
    if (ses_unreachable) return null;
    const socket_path = ipc.getSesSocketPath(allocator) catch {
        ses_unreachable = true;
        return null;
    };
    defer allocator.free(socket_path);
    var client = ipc.Client.connect(socket_path) catch {
        ses_unreachable = true;
        return null;
    };
    defer client.close();
    const fd = client.fd;

    const timeout = std.posix.timeval{ .sec = 3, .usec = 0 };
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};

    // sendCliHandshake, not sendHandshake: the daemon answers the handshake
    // with a server hello, and a client that does not consume it reads those
    // bytes as its first control header — which is exactly as broken as it
    // sounds, and silently, because the garbage header just looks like a bad
    // reply.
    wire.sendCliHandshake(fd) catch {
        ses_unreachable = true;
        return null;
    };
    var req: wire.GetPanePalette = .{ .uuid = uuid };
    wire.writeControl(fd, .get_pane_palette, std.mem.asBytes(&req)) catch {
        ses_unreachable = true;
        return null;
    };

    const hdr = wire.readControlHeader(fd) catch {
        ses_unreachable = true;
        return null;
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type != .get_pane_palette or hdr.payload_len < @sizeOf(wire.PanePalette)) return null;
    const resp = wire.readStruct(wire.PanePalette, fd) catch return null;
    const trail = hdr.payload_len - @sizeOf(wire.PanePalette);
    if (trail == 0 or resp.blob_len != trail or trail > palette.MAX_BLOB_LEN) return null;

    const blob = allocator.alloc(u8, trail) catch return null;
    wire.readExact(fd, blob) catch {
        allocator.free(blob);
        return null;
    };
    return blob;
}

/// The payload built below is an escape sequence delivered to every targeted
/// pane, so anything interpolated into it must be checked here first. A theme
/// file carrying `0=#000000\x1b]0;pwned\x07\x1b[2J` would otherwise retitle and
/// clear every pane in the session, and the CLI would exit 0.
///
/// Checking here also turns the pane's silent `.ignore` into a diagnostic: a
/// misspelled key or colour used to be accepted by the CLI, injected, dropped
/// inside the pane, and reported as success.
fn validEntry(entry: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return false;
    const key = entry[0..eq];
    const value = entry[eq + 1 ..];
    if (key.len == 0) return false;
    if (palette.parseHexColor(value) == null) return false;

    if (std.ascii.eqlIgnoreCase(key, "fg")) return true;
    if (std.ascii.eqlIgnoreCase(key, "bg")) return true;
    if (std.ascii.eqlIgnoreCase(key, "cursor")) return true;
    const idx = std.fmt.parseUnsigned(u16, key, 10) catch return false;
    return idx <= 255;
}

/// The OSC number this session listens on.
///
/// The pane dispatches on its own configured number, so a CLI that always wrote
/// the default would build sequences nothing consumes — and exit 0 having done
/// nothing. The frontend exports the live value into every pane it spawns.
fn effectiveOsc() u32 {
    const raw = std.posix.getenv("HEXE_PALETTE_OSC") orelse return palette.DEFAULT_OSC;
    return std.fmt.parseUnsigned(u32, raw, 10) catch palette.DEFAULT_OSC;
}

/// `*` is the documented wildcard; every other target must be a slot number.
fn validNsArg(ns: []const u8) bool {
    return std.mem.eql(u8, ns, "*") or palette.NamespaceTable.parseSlot(ns) != null;
}

/// `hexe palette set --ns <name> <i>=#rrggbb …` / `--from <file>`.
pub fn runPaletteSet(
    allocator: std.mem.Allocator,
    ns: []const u8,
    from: []const u8,
    pane: []const u8,
    pairs: []const []const u8,
) !void {
    var entries = std.ArrayList([]const u8).empty;
    defer {
        for (entries.items) |e| allocator.free(e);
        entries.deinit(allocator);
    }

    for (pairs) |p| try entries.append(allocator, try allocator.dupe(u8, p));
    if (from.len > 0) try readEntriesFile(allocator, from, &entries);

    if (entries.items.len == 0) {
        print("Error: nothing to set (give <i>=#rrggbb pairs or --from FILE)\n", .{});
        return Error.NoEntries;
    }

    if (!validNsArg(ns)) {
        print("Error: invalid namespace {s}: expected * or a slot number 0..{d}\n", .{ ns, palette.MAX_NS - 1 });
        return Error.BadArgument;
    }
    for (entries.items) |e| {
        if (validEntry(e)) continue;
        print("Error: invalid entry {s}: expected <0-255|fg|bg|cursor>=#rrggbb\n", .{e});
        return Error.BadArgument;
    }

    // §6 caps a `set` at 32 entries per sequence; a 256-colour file is simply
    // several sequences, and `set` accumulates so the result is identical.
    //
    // Built as ONE payload and delivered once per pane. Injecting per chunk
    // opened a fresh socket per chunk per pane — a 256-colour file across a
    // twenty-pane session was 160 connections instead of 20, and a pane that
    // died midway could take half a scheme.
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(allocator);
    var sent: usize = 0;
    while (sent < entries.items.len) {
        const end = @min(sent + palette.SET_CHUNK, entries.items.len);
        try payload.writer(allocator).print("\x1b]{d};set;{s}", .{ effectiveOsc(), ns });
        for (entries.items[sent..end]) |e| {
            try payload.writer(allocator).print(";{s}", .{e});
        }
        try payload.appendSlice(allocator, "\x1b\\");
        sent = end;
    }
    try inject(allocator, pane, payload.items);
}

/// `hexe palette use|end|drop` — the selection verbs, same front door.
pub fn runPaletteVerb(
    allocator: std.mem.Allocator,
    verb: []const u8,
    ns: []const u8,
    pane: []const u8,
) !void {
    if (!std.mem.eql(u8, verb, "end") and !validNsArg(ns)) {
        print("Error: invalid namespace {s}: expected * or a slot number 0..{d}\n", .{ ns, palette.MAX_NS - 1 });
        return Error.BadArgument;
    }

    var seq = std.ArrayList(u8).empty;
    defer seq.deinit(allocator);
    if (std.mem.eql(u8, verb, "end")) {
        try seq.writer(allocator).print("\x1b]{d};end\x1b\\", .{effectiveOsc()});
    } else {
        if (ns.len == 0) {
            print("Error: {s} requires --ns NAME\n", .{verb});
            return Error.BadArgument;
        }
        try seq.writer(allocator).print("\x1b]{d};{s};{s}\x1b\\", .{ effectiveOsc(), verb, ns });
    }
    try inject(allocator, pane, seq.items);
}

/// Read `<key> <colour>` or `<key>=<colour>` lines. This is the shape
/// `~/.cache/wal/colors` and friends already have, so M7's hook can point
/// straight at one.
fn readEntriesFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    const data = std.fs.cwd().readFileAlloc(allocator, path, 1 << 20) catch |err| {
        print("Error: cannot read {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer allocator.free(data);

    var index: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        // A bare colour on its own line is the next index in order, which is
        // the whole format of `~/.cache/wal/colors`. Anything else starting
        // with `#` is a comment.
        if (std.mem.indexOfAny(u8, line, "= \t") == null) {
            if (palette.parseHexColor(line) != null) {
                try out.append(allocator, try std.fmt.allocPrint(allocator, "{d}={s}", .{ index, line }));
                index += 1;
            }
            continue;
        }
        if (line[0] == '#') continue;

        const sep = std.mem.indexOfAny(u8, line, "= \t").?;
        const key = std.mem.trim(u8, line[0..sep], " \t");
        const value = std.mem.trim(u8, line[sep + 1 ..], " \t=");
        if (key.len == 0 or value.len == 0) continue;
        try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}={s}", .{ key, value }));
    }
}

/// Send `seq` to one pane, or to every live pane when none is named. A hook
/// reacting to a theme change wants the whole session, not the pane it happens
/// to run in.
fn inject(allocator: std.mem.Allocator, pane: []const u8, seq: []const u8) !void {
    if (pane.len > 0) {
        // Validated before it becomes a path. `getPodSocketPath` interpolates
        // the string, so an unchecked `--pane` reaches the filesystem.
        if (!shared.isUuid32Hex(pane)) {
            print("Error: --pane must be a 32-character pane uuid\n", .{});
            return Error.BadArgument;
        }
        const socket = try ipc.getPodSocketPath(allocator, pane);
        defer allocator.free(socket);
        injectTo(socket, seq) catch |err| {
            print("Error: pane {s} did not accept the palette: {s}\n", .{ pane, @errorName(err) });
            return err;
        };
        return;
    }

    var records = std.ArrayList(pod_list.PodRecord).empty;
    defer {
        for (records.items) |r| pod_list.freeRecord(allocator, r);
        records.deinit(allocator);
    }
    try collectPods(allocator, &records);
    if (records.items.len == 0) {
        print("Error: no live panes to address\n", .{});
        return Error.NoPanes;
    }

    var delivered: usize = 0;
    for (records.items) |r| {
        const socket = ipc.getPodSocketPath(allocator, r.uuid[0..]) catch continue;
        defer allocator.free(socket);
        injectTo(socket, seq) catch continue;
        delivered += 1;
    }
    if (delivered == 0) {
        print("Error: no pane accepted the palette update\n", .{});
        return Error.NoPanes;
    }
}

fn injectTo(socket_path: []const u8, seq: []const u8) !void {
    var client = try ipc.Client.connect(socket_path);
    defer client.close();
    try wire.sendHandshake(client.fd, wire.POD_HANDSHAKE_AUX_INPUT);
    var conn = client.toConnection();
    try pod_protocol.writeFrame(&conn, .output, seq);
}

fn collectPods(allocator: std.mem.Allocator, out: *std.ArrayList(pod_list.PodRecord)) !void {
    const dir = try ipc.getSocketDir(allocator);
    defer allocator.free(dir);
    try pod_list.scanMetaFiles(allocator, dir, out);
}

test "colour files parse into set entries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "colors", .data = "#112233\n#445566\n# a comment here\nbg=#000000\nfg #ffffff\n" });
    const path = try tmp.dir.realpathAlloc(allocator, "colors");
    defer allocator.free(path);

    var entries = std.ArrayList([]const u8).empty;
    defer {
        for (entries.items) |e| allocator.free(e);
        entries.deinit(allocator);
    }
    try readEntriesFile(allocator, path, &entries);

    try std.testing.expectEqual(@as(usize, 4), entries.items.len);
    try std.testing.expectEqualStrings("0=#112233", entries.items[0]);
    try std.testing.expectEqualStrings("1=#445566", entries.items[1]);
    try std.testing.expectEqualStrings("bg=#000000", entries.items[2]);
    try std.testing.expectEqualStrings("fg=#ffffff", entries.items[3]);
}
