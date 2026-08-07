const std = @import("std");

pub const Tracking = struct {
    normal: bool = false,
    button: bool = false,
    any: bool = false,
    sgr: bool = false,

    pub fn enabled(self: Tracking) bool {
        return self.normal or self.button or self.any;
    }
};

pub const Event = struct {
    button_code: u16,
    is_release: bool,

    pub fn isMotion(self: Event) bool {
        return (self.button_code & 32) != 0;
    }

    pub fn hasButton(self: Event) bool {
        return (self.button_code & 3) != 3;
    }
};

pub fn shouldForward(tracking: Tracking, event: Event, selection_override: bool) bool {
    if (selection_override or !tracking.sgr or !tracking.enabled()) return false;
    if (!event.isMotion()) return true;
    if (tracking.any) return true;
    if (tracking.button) return event.hasButton();
    return false;
}

pub fn encodeSgr(
    buffer: []u8,
    pane_x: u16,
    pane_y: u16,
    absolute_x: u16,
    absolute_y: u16,
    event: Event,
) ![]const u8 {
    const local_x: u16 = if (absolute_x >= pane_x) absolute_x - pane_x + 1 else 1;
    const local_y: u16 = if (absolute_y >= pane_y) absolute_y - pane_y + 1 else 1;
    const terminator: u8 = if (event.is_release) 'm' else 'M';
    return std.fmt.bufPrint(buffer, "\x1b[<{d};{d};{d}{c}", .{
        event.button_code,
        local_x,
        local_y,
        terminator,
    });
}

test "mouse tracking honors event class and selection override" {
    const click: Event = .{ .button_code = 0, .is_release = false };
    const drag: Event = .{ .button_code = 32, .is_release = false };
    const hover: Event = .{ .button_code = 35, .is_release = false };

    try std.testing.expect(!shouldForward(.{}, click, false));
    try std.testing.expect(!shouldForward(.{ .normal = true }, click, false));
    try std.testing.expect(shouldForward(.{ .normal = true, .sgr = true }, click, false));
    try std.testing.expect(!shouldForward(.{ .normal = true, .sgr = true }, drag, false));
    try std.testing.expect(shouldForward(.{ .button = true, .sgr = true }, drag, false));
    try std.testing.expect(!shouldForward(.{ .button = true, .sgr = true }, hover, false));
    try std.testing.expect(shouldForward(.{ .any = true, .sgr = true }, hover, false));
    try std.testing.expect(!shouldForward(.{ .any = true, .sgr = true }, click, true));
}

test "SGR mouse encoding uses pane-local coordinates" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\x1b[<0;3;4M",
        try encodeSgr(&buffer, 10, 20, 12, 23, .{ .button_code = 0, .is_release = false }),
    );
    try std.testing.expectEqualStrings(
        "\x1b[<0;3;4m",
        try encodeSgr(&buffer, 10, 20, 12, 23, .{ .button_code = 0, .is_release = true }),
    );
}
