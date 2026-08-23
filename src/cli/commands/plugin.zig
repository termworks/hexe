//! `hexe plugin` — list, install, remove, allow.
//!
//! A plugin is a directory you install, not a command string you paste into
//! your config. So the verbs are the ones you already expect from a package
//! manager, and your config file stays yours.

const std = @import("std");
const core = @import("core");

const pkg = core.plugin_pkg;
const print = std.debug.print;

fn out() @TypeOf(std.fs.File.stdout().deprecatedWriter()) {
    return std.fs.File.stdout().deprecatedWriter();
}

/// What is installed, what it may do, and whether it still hashes to what was
/// approved. The last column is the point: a plugin that changed under you is
/// the thing worth seeing at a glance.
pub fn runList(allocator: std.mem.Allocator, json: bool) !void {
    const names = try pkg.list(allocator);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    var w = out();
    if (json) try w.writeAll("[");
    if (names.len == 0 and !json) {
        try w.writeAll("no plugins installed\n");
        return;
    }

    for (names, 0..) |name, i| {
        var manifest = pkg.readManifest(allocator, name) catch {
            if (json) {
                if (i > 0) try w.writeAll(",");
                try w.print("{{\"name\":\"{s}\",\"state\":\"unreadable\"}}", .{name});
            } else {
                try w.print("{s: <16} (its {s} could not be read)\n", .{ name, pkg.MANIFEST });
            }
            continue;
        };
        defer manifest.deinit(allocator);

        const trusted = pkg.isTrusted(allocator, name, manifest.entry);
        var acc_buf: [96]u8 = undefined;
        var acc_stream = std.io.fixedBufferStream(&acc_buf);
        manifest.granted.format(acc_stream.writer()) catch {};

        if (json) {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"name\":\"{s}\",\"version\":\"{s}\",\"access\":\"{s}\",\"trusted\":{s}}}", .{
                name,
                manifest.version,
                acc_stream.getWritten(),
                if (trusted) "true" else "false",
            });
        } else {
            try w.print("{s: <16} {s: <10} {s: <28} {s}\n", .{
                name,
                manifest.version,
                acc_stream.getWritten(),
                if (trusted) "ok" else "CHANGED — run `hexe plugin allow`",
            });
        }
    }
    if (json) try w.writeAll("]\n");
}

/// Install from a directory, then show what it asked for.
///
/// Installing does NOT approve it. The two are separate because the point of
/// the manifest is to be read before anything runs, and an install that also
/// trusted would collapse that back into one step.
pub fn runInstall(allocator: std.mem.Allocator, source: []const u8, yes: bool) !void {
    if (source.len == 0) {
        print("Error: `hexe plugin install` needs a directory\n", .{});
        return error.MissingTarget;
    }

    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ source, pkg.MANIFEST });
    defer allocator.free(manifest_path);
    std.fs.cwd().access(manifest_path, .{}) catch {
        print("Error: {s} has no {s}, so there is nothing to read before running it\n", .{ source, pkg.MANIFEST });
        return error.NotAPlugin;
    };

    // The name comes from the directory, which is also where it will live.
    const base = std.fs.path.basename(source);
    if (!pkg.validName(base)) {
        print("Error: '{s}' is not a usable plugin name ([a-z0-9_-], no separators)\n", .{base});
        return error.InvalidName;
    }

    pkg.install(allocator, source, base) catch |err| {
        print("Error: could not install {s}: {s}\n", .{ base, @errorName(err) });
        return err;
    };

    var manifest = pkg.readManifest(allocator, base) catch |err| {
        print("Error: installed, but its {s} does not read as a manifest: {s}\n", .{ pkg.MANIFEST, @errorName(err) });
        return err;
    };
    defer manifest.deinit(allocator);

    var acc_buf: [96]u8 = undefined;
    var acc_stream = std.io.fixedBufferStream(&acc_buf);
    manifest.granted.format(acc_stream.writer()) catch {};

    var w = out();
    try w.print("installed {s} {s}\n", .{ base, manifest.version });
    if (manifest.description.len > 0) try w.print("  {s}\n", .{manifest.description});
    try w.print("  it asks for: {s}\n", .{acc_stream.getWritten()});
    if (manifest.command.len > 0) try w.print("  it runs: {s}\n", .{manifest.command});

    if (yes) {
        try pkg.allow(allocator, base, manifest.entry);
        try w.writeAll("  approved\n");
    } else {
        try w.print("\nNothing of it has run. When you are happy with what it asks for:\n  hexe plugin allow {s}\n", .{base});
    }
}

pub fn runRemove(allocator: std.mem.Allocator, name: []const u8) !void {
    pkg.remove(allocator, name) catch |err| {
        // deleteTree does not distinguish "was not there" from a real failure,
        // so say which plugin and what happened and let the user judge.
        print("Error: could not remove '{s}': {s}\n", .{ name, @errorName(err) });
        return err;
    };
    try out().print("removed {s}\n", .{name});
}

pub fn runAllow(allocator: std.mem.Allocator, name: []const u8) !void {
    var manifest = pkg.readManifest(allocator, name) catch |err| {
        print("Error: cannot read {s} for '{s}': {s}\n", .{ pkg.MANIFEST, name, @errorName(err) });
        return err;
    };
    defer manifest.deinit(allocator);

    try pkg.allow(allocator, name, manifest.entry);
    try out().print("approved {s} {s}\n", .{ name, manifest.version });
}
