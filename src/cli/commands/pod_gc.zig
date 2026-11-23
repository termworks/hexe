const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const pod_meta = core.pod_meta;
const cli_ui = core.cli_ui;

fn deleteGcEntry(
    out: anytype,
    p: cli_ui.Palette,
    dir: std.fs.Dir,
    dir_path: []const u8,
    name: []const u8,
) bool {
    dir.deleteFile(name) catch |err| {
        cli_ui.printErr("gc: failed to delete {s}/{s}: {s}", .{ dir_path, name, @errorName(err) });
        return false;
    };
    out.print("  {s}✓{s} {s}deleted{s} {s}/{s}\n", .{ p.success, p.reset, p.dim, p.reset, dir_path, name }) catch {};
    return true;
}

pub fn runPodGc(allocator: std.mem.Allocator, dry_run: bool) !void {
    const dir = try ipc.getSocketDir(allocator);
    defer allocator.free(dir);

    var d = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer d.close();

    var out = std.fs.File.stdout().deprecatedWriter();
    const p = cli_ui.Palette.forStdout();
    var count: usize = 0;

    var it = d.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;

        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "pod-") and std.mem.endsWith(u8, entry.name, ".meta")) {
            // If socket missing or not connectable, delete meta.
            const uuid = extractUuidFromMetaFilename(entry.name) orelse continue;
            const sock = try ipc.getPodSocketPath(allocator, uuid);
            defer allocator.free(sock);
            const alive = (ipc.Client.connect(sock) catch null) != null;
            if (!alive) {
                if (dry_run) {
                    try out.print("  {s}○{s} {s}would delete{s} {s}/{s}\n", .{ p.warn, p.reset, p.dim, p.reset, dir, entry.name });
                    count += 1;
                } else if (deleteGcEntry(out, p, d, dir, entry.name)) {
                    count += 1;
                }
            }
            continue;
        }

        if (entry.kind == .sym_link and std.mem.startsWith(u8, entry.name, "pod@") and std.mem.endsWith(u8, entry.name, ".sock")) {
            // If link is broken or target not connectable, delete it.
            var link_buf: [std.fs.max_path_bytes]u8 = undefined;
            const target = d.readLink(entry.name, &link_buf) catch "";
            if (target.len == 0) {
                if (dry_run) {
                    try out.print("  {s}○{s} {s}would delete{s} {s}/{s}\n", .{ p.warn, p.reset, p.dim, p.reset, dir, entry.name });
                    count += 1;
                } else if (deleteGcEntry(out, p, d, dir, entry.name)) {
                    count += 1;
                }
                continue;
            }
            // Try connect to link path itself (more robust than resolving).
            const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, entry.name });
            defer allocator.free(full);
            const alive = (ipc.Client.connect(full) catch null) != null;
            if (!alive) {
                if (dry_run) {
                    try out.print("  {s}○{s} {s}would delete{s} {s}\n", .{ p.warn, p.reset, p.dim, p.reset, full });
                    count += 1;
                } else if (deleteGcEntry(out, p, d, dir, entry.name)) {
                    count += 1;
                }
            }
            continue;
        }
    }

    const file_word: []const u8 = if (count == 1) "file" else "files";
    if (count == 0) {
        try out.print("{s}✓{s} No stale pod files found\n", .{ p.success, p.reset });
    } else if (dry_run) {
        try out.print("{s}○{s} Would remove {s}{d}{s} stale pod {s} {s}(dry run){s}\n", .{
            p.warn, p.reset, p.bold, count, p.reset, file_word, p.dim, p.reset,
        });
    } else {
        try out.print("{s}✓{s} Removed {s}{d}{s} stale pod {s}\n", .{
            p.success, p.reset, p.bold, count, p.reset, file_word,
        });
    }

    _ = pod_meta;
}

fn extractUuidFromMetaFilename(name: []const u8) ?[]const u8 {
    // "pod-<uuid>.meta"
    if (!std.mem.startsWith(u8, name, "pod-")) return null;
    if (!std.mem.endsWith(u8, name, ".meta")) return null;
    const mid = name[4 .. name.len - 5];
    if (mid.len != 32) return null;
    return mid;
}
