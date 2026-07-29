const std = @import("std");
const Segment = @import("context.zig").Segment;
const Context = @import("context.zig").Context;
const Style = @import("../style.zig").Style;

// Uptime moves at one second per second, so re-reading it twice per frame (the
// statusbar's width pass and draw pass) can never change the rendered text.
var last_uptime_secs: u64 = 0;
var last_sample_ns: i128 = 0;
var initialized: bool = false;
const MIN_SAMPLE_INTERVAL_NS: i128 = 500 * std.time.ns_per_ms;

/// Uptime segment - displays system uptime
/// Format: up 4 days, 14 hours, 38 minutes
pub fn render(ctx: *Context) ?[]const Segment {
    if (initialized and std.time.nanoTimestamp() - last_sample_ns < MIN_SAMPLE_INTERVAL_NS) {
        return renderUptime(ctx, last_uptime_secs);
    }

    // Read /proc/uptime
    const file = std.fs.openFileAbsolute("/proc/uptime", .{}) catch return null;
    defer file.close();

    var buf: [64]u8 = undefined;
    const len = file.read(&buf) catch return null;
    const str = buf[0..len];

    // Parse first number (uptime in seconds)
    var iter = std.mem.tokenizeAny(u8, str, " \t\n");
    const uptime_str = iter.next() orelse return null;

    // Parse as float and convert to integer seconds
    const uptime_float = std.fmt.parseFloat(f64, uptime_str) catch return null;
    const uptime_secs: u64 = @intFromFloat(uptime_float);

    last_uptime_secs = uptime_secs;
    last_sample_ns = std.time.nanoTimestamp();
    initialized = true;

    return renderUptime(ctx, uptime_secs);
}

fn renderUptime(ctx: *Context, uptime_secs: u64) ?[]const Segment {
    // Calculate components
    const days = uptime_secs / 86400;
    const hours = (uptime_secs % 86400) / 3600;
    const minutes = (uptime_secs % 3600) / 60;

    // Format output
    const text = if (days > 0)
        ctx.allocFmt("up {d} days, {d} hours, {d}", .{ days, hours, minutes }) catch return null
    else if (hours > 0)
        ctx.allocFmt("up {d} hours, {d} min", .{ hours, minutes }) catch return null
    else
        ctx.allocFmt("up {d} min", .{minutes}) catch return null;

    return ctx.addSegment(text, Style{}) catch return null;
}
