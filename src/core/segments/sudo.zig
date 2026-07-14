const std = @import("std");
const cmd_mod = @import("../cmd.zig");
const Segment = @import("context.zig").Segment;
const Context = @import("context.zig").Context;
const Style = @import("../style.zig").Style;

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
    const cached = cmd_mod.runArgvSucceeds(
        std.heap.page_allocator,
        &.{ "sudo", "-n", "true" },
        cmd_mod.DEFAULT_TIMEOUT_MS,
    );
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
