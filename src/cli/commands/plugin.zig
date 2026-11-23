//! `hexe plugin` — what is on the runtimepath, and what it would run.
//!
//! There is no install verb, no remove verb and no approve verb, because there
//! is nothing for them to do: a plugin is a directory on the path, so installing
//! one is putting it there and removing one is taking it away. What was left is
//! the question that actually gets asked, usually at two in the morning: *is it
//! me or a plugin, and in what order did they run?*

const std = @import("std");
const core = @import("core");

const rtp = core.runtimepath;

fn out() @TypeOf(std.fs.File.stdout().deprecatedWriter()) {
    return std.fs.File.stdout().deprecatedWriter();
}

/// The path, and the files it would run, in the order it would run them.
///
/// Both, because either alone leaves the interesting case unexplained: a plugin
/// that is not running is usually in a directory that is not on the path, and a
/// plugin behaving oddly is usually one that another plugin ran before.
pub fn runList(allocator: std.mem.Allocator, json: bool) !void {
    const roots = try rtp.roots(allocator);
    defer rtp.deinitRoots(allocator, roots);
    const files = try rtp.pluginFiles(allocator, roots);
    defer rtp.deinitFiles(allocator, files);

    var w = out();
    if (json) {
        try w.writeAll("{\"runtimepath\":[");
        for (roots, 0..) |r, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("\"{s}\"", .{r.path});
        }
        try w.writeAll("],\"plugins\":[");
        for (files, 0..) |f, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("\"{s}\"", .{f.path});
        }
        try w.writeAll("]}\n");
        return;
    }

    const p = core.cli_ui.Palette.forStdout();
    try w.print("{s}runtimepath{s}\n", .{ p.bold, p.reset });
    for (roots) |r| {
        // Saying which of them exist turns "my plugin does not load" into one
        // look: the directory it is in is usually not on the path at all.
        const exists = if (std.fs.cwd().statFile(r.path)) |_| true else |_| false;
        const there: []const u8 = if (exists) " " else "-";
        const col: []const u8 = if (exists) p.reset else p.dim;
        try w.print("  {s}{s}{s} {s}{s}{s}\n", .{ p.muted, there, p.reset, col, r.path, p.reset });
    }

    try w.print("\n{s}plugins, in load order{s}\n", .{ p.bold, p.reset });
    if (files.len == 0) {
        try w.print("    {s}none{s}\n", .{ p.dim, p.reset });
    } else {
        for (files, 0..) |f, i| try w.print("  {s}{d: >3}.{s} {s}\n", .{ p.accent, i + 1, p.reset, f.path });
    }
    try w.print("\n  {s}a `-` marks a directory that is not there; nothing else is needed to\n" ++
        "  install a plugin than putting it on this path. `--noplugin` skips them all.{s}\n", .{ p.dim, p.reset });
}
