const std = @import("std");
const cmd_mod = @import("../cmd.zig");
const Segment = @import("context.zig").Segment;
const Context = @import("context.zig").Context;
const Style = @import("../style.zig").Style;

/// File-cache TTL for the `sudo -n true` probe in short-lived prompt processes.
/// Default 2s; override with HEXE_SUDO_CACHE_TTL (ms, clamped 500..15000).
fn sudoCacheTtlMs() i64 {
    if (std.posix.getenv("HEXE_SUDO_CACHE_TTL")) |s| {
        const v = std.fmt.parseInt(i64, s, 10) catch 2000;
        return @min(@max(v, 500), 15000);
    }
    return 2000;
}

/// Sudo segment - displays indicator if:
/// 1. Running as root (EUID == 0)
/// 2. Sudo credentials are cached (sudo -n true succeeds)
/// Returns empty string as $output - use format like " ROOT " for display
pub fn render(ctx: *Context) ?[]const Segment {
    // Check effective UID using Linux syscall
    const euid = std.os.linux.geteuid();
    if (euid == 0) {
        const text = ctx.allocText("") catch return null;
        return ctx.addSegment(text, Style.parse("bold fg:red")) catch return null;
    }

    // Check SUDO_USER env var
    if (std.posix.getenv("SUDO_USER")) |_| {
        const text = ctx.allocText("") catch return null;
        return ctx.addSegment(text, Style.parse("bold fg:yellow")) catch return null;
    }

    // Check if sudo credentials are cached (like starship does)
    // Run: sudo -n true (non-interactive, exits 0 if cached)
    // BOUNDED: `sudo -n true` can block (PAM modules, network-backed auth);
    // it runs in the render path, so it must never hang the UI.
    // ASYNC in the terminal: `sudo -n true` can stall on PAM/network modules.
    const argv = [_][]const u8{ "sudo", "-n", "true" };
    // In the terminal frontend the async cache serves this non-blocking. In a
    // short-lived `shp` prompt process there is no async cache, so instead of
    // re-spawning `sudo -n true` on every single prompt, fall through to a
    // file-backed cache: a burst of prompts pays for one spawn. TTL is tunable
    // (staleness = the sudo indicator can lag reality by up to the TTL).
    const cached = cmd_mod.cachedSucceededArgv("sudo-n-true", &argv, 2000) orelse
        cmd_mod.fileCachedSucceededArgv("sudo-n-true", &argv, sudoCacheTtlMs());
    const result = .{ .term = std.process.Child.Term{ .Exited = @as(u8, if (cached) 0 else 1) } };

    const success = switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };

    if (success) {
        const text = ctx.allocText("") catch return null;
        return ctx.addSegment(text, Style.parse("bold fg:yellow")) catch return null;
    }

    return null;
}
