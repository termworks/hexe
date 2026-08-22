//! `hexe pod share` — read or cut the observers watching a pane.
//!
//! Separate from `hexe api share` because it does not need a frontend. A pane
//! can be shared while detached, and the moment you most want to cut a stream
//! is the moment something else has gone wrong; requiring an attached mux to
//! do it would make the kill switch depend on the parts most likely to be the
//! problem.

const std = @import("std");
const core = @import("core");
const shared = @import("shared.zig");

const print = std.debug.print;

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
        print("Error: --on and --off are mutually exclusive\n", .{});
        return error.ConflictingOptions;
    }

    const path = shared.resolvePodSocketTarget(allocator, uuid, name, socket_path) catch |err| {
        print("Error: could not resolve pod target: {s}\n", .{@errorName(err)});
        return err;
    };
    defer allocator.free(path);

    const cmd: core.wire.PodShareCmd = if (off) .block else if (on) .allow else .query;
    const status = core.pod_share.requestPath(path, cmd) catch |err| {
        print("Error: pod share request failed: {s}\n", .{@errorName(err)});
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

    if (status.blocked) {
        try out.writeAll("blocked — no one can watch this pane\n");
    } else if (status.observers == 0) {
        try out.writeAll("not shared — no one is watching\n");
    } else {
        try out.print("shared — {d} watching\n", .{status.observers});
    }
}
