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
/// "not inside hexe, fall back". It reports reachable panes rather than live
/// namespace contents; reading state back from the frontend needs a channel
/// that does not exist yet.
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
        try out.writer(allocator).print("pane uuid={s} name={s}\n", .{ r.uuid[0..], r.name });
    }
    // Auto-namespaces exist in every pane whether or not anything set them.
    try out.appendSlice(allocator, "namespaces default prompt output alt\n");
    try std.fs.File.stdout().writeAll(out.items);
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
        try payload.writer(allocator).print("\x1b]{d};set;{s}", .{ palette.DEFAULT_OSC, ns });
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
    var seq = std.ArrayList(u8).empty;
    defer seq.deinit(allocator);
    if (std.mem.eql(u8, verb, "end")) {
        try seq.writer(allocator).print("\x1b]{d};end\x1b\\", .{palette.DEFAULT_OSC});
    } else {
        if (ns.len == 0) {
            print("Error: {s} requires --ns NAME\n", .{verb});
            return Error.BadArgument;
        }
        try seq.writer(allocator).print("\x1b]{d};{s};{s}\x1b\\", .{ palette.DEFAULT_OSC, verb, ns });
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
