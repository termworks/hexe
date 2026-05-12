const std = @import("std");
const core = @import("core");

test "VT defaults to blinking block cursor" {
    var vt: core.VT = undefined;
    try vt.init(std.testing.allocator, 80, 24);
    defer vt.deinit();

    try std.testing.expectEqual(@as(u8, 1), vt.getCursorStyle());
}

test "VT preserves explicit steady cursor style" {
    var vt: core.VT = undefined;
    try vt.init(std.testing.allocator, 80, 24);
    defer vt.deinit();

    try vt.feed("\x1b[2 q");
    try std.testing.expectEqual(@as(u8, 2), vt.getCursorStyle());
}
