//! Shell integration: the hooks a shell installs so it can report its state to
//! the mux.
//!
//! This is the input side only. Prompt painting belongs to an external program;
//! hexe consumes what the shell reports (cwd, exit status, duration, jobs,
//! running command) and forwards it to whoever paints.

const std = @import("std");

const bash_init = @import("shell/bash.zig");
const zsh_init = @import("shell/zsh.zig");
const fish_init = @import("shell/fish.zig");
// Emits Lua rather than shell — see the note on `oslo.printInit`.
const oslo_init = @import("shell/oslo.zig");

/// Print the integration snippet for `shell` on stdout. `no_comms` suppresses
/// the shell->mux reporting hooks, leaving only command timing.
pub fn printInit(shell: []const u8, no_comms: bool) !void {
    const stdout = std.fs.File.stdout();

    if (std.mem.eql(u8, shell, "bash")) {
        try bash_init.printInit(stdout, no_comms);
    } else if (std.mem.eql(u8, shell, "zsh")) {
        try zsh_init.printInit(stdout, no_comms);
    } else if (std.mem.eql(u8, shell, "fish")) {
        try fish_init.printInit(stdout, no_comms);
    } else if (std.mem.eql(u8, shell, "oslo")) {
        try oslo_init.printInit(stdout, no_comms);
    } else {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unknown shell: {s}\nSupported shells: bash, zsh, fish, oslo\n", .{shell}) catch return;
        try stdout.writeAll(msg);
    }
}
