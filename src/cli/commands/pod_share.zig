//! `hexe pod share` — read or cut the observers watching a pane.
//!
//! Separate from `hexe api share` because it does not need a frontend. A pane
//! can be shared while detached, and the moment you most want to cut a stream
//! is the moment something else has gone wrong; requiring an attached mux to
//! do it would make the kill switch depend on the parts most likely to be the
//! problem.

const std = @import("std");
const core = @import("core");
const cli_ui = core.cli_ui;
const shared = @import("shared.zig");

pub fn runPodShare(
    allocator: std.mem.Allocator,
    uuid: []const u8,
    name: []const u8,
    socket_path: []const u8,
    on: bool,
    off: bool,
    json: bool,
) !void {
    if (on and off) {
        cli_ui.printErr("--on and --off are mutually exclusive", .{});
        return error.ConflictingOptions;
    }

    const path = shared.resolvePodSocketTarget(allocator, uuid, name, socket_path) catch |err| {
        cli_ui.printErr("could not resolve pod target: {s}", .{@errorName(err)});
        return err;
    };
    defer allocator.free(path);

    const cmd: core.wire.PodShareCmd = if (off) .block else if (on) .allow else .query;
    const status = core.pod_share.requestPath(path, cmd) catch |err| {
        cli_ui.printErr("pod share request failed: {s}", .{@errorName(err)});
        return err;
    };

    // The answer is data, so it goes to stdout; only the errors above are
    // diagnostics. A caller piping this into `jq` gets nothing otherwise.
    var out = std.fs.File.stdout().deprecatedWriter();
    if (json) {
        try out.print("{{\"observers\":{d},\"shared\":{s},\"blocked\":{s}}}\n", .{
            status.observers,
            if (status.observers > 0) "true" else "false",
            if (status.blocked) "true" else "false",
        });
        return;
    }

    const p = cli_ui.Palette.forStdout();
    if (status.blocked) {
        if (p.enabled) {
            try out.print("{s}✗ blocked{s} {s}— no one can watch this pane{s}\n", .{ p.err, p.reset, p.dim, p.reset });
        } else {
            try out.writeAll("blocked — no one can watch this pane\n");
        }
    } else if (status.observers == 0) {
        if (p.enabled) {
            try out.print("{s}○ not shared{s} {s}— no one is watching{s}\n", .{ p.muted, p.reset, p.dim, p.reset });
        } else {
            try out.writeAll("not shared — no one is watching\n");
        }
    } else {
        if (p.enabled) {
            try out.print("{s}● shared{s} — {s}{d}{s} watching\n", .{ p.success, p.reset, p.bold, status.observers, p.reset });
        } else {
            try out.print("shared — {d} watching\n", .{status.observers});
        }
    }
}
