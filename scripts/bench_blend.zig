const std = @import("std");
const vt_bridge = @import("vt_bridge");

const runs = 30;
const budget_ns = 16 * std.time.ns_per_ms;

pub fn main() !void {
    for (0..10) |_| _ = try vt_bridge.benchmarkMixedViewport();

    var samples: [runs]u64 = undefined;
    for (&samples) |*sample| sample.* = try vt_bridge.benchmarkMixedViewport();

    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    const median = samples[runs / 2];
    std.debug.print("mixed cells : 10000\n", .{});
    std.debug.print("runs        : {d}\n", .{runs});
    std.debug.print("median      : {d:.3} ms\n", .{@as(f64, @floatFromInt(median)) / std.time.ns_per_ms});
    std.debug.print("range       : {d:.3}..{d:.3} ms\n", .{
        @as(f64, @floatFromInt(samples[0])) / std.time.ns_per_ms,
        @as(f64, @floatFromInt(samples[runs - 1])) / std.time.ns_per_ms,
    });
    if (median >= budget_ns) return error.FrameBudgetExceeded;
}
