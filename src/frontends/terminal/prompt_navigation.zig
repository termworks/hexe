const std = @import("std");
const core = @import("core");
const ghostty = @import("ghostty-vt");

pub const Direction = enum { previous, next };

pub fn jump(vt: *core.VT, direction: Direction) bool {
    const screen = vt.terminal.screens.active;
    const start = screen.pages.getTopLeft(.viewport);
    var iterator = start.rowIterator(switch (direction) {
        .previous => .left_up,
        .next => .right_down,
    }, null);
    _ = iterator.next();

    while (iterator.next()) |pin| {
        if (pin.rowAndCell().row.semantic_prompt != .prompt) continue;
        screen.scroll(.{ .pin = pin });
        vt.invalidateRenderState();
        return true;
    }
    return false;
}

pub fn lastOutputAlloc(allocator: std.mem.Allocator, vt: *core.VT) !?[:0]const u8 {
    const screen = vt.terminal.screens.active;
    const bottom = screen.pages.getBottomRight(.screen) orelse return null;
    var iterator = bottom.rowIterator(.left_up, null);
    var output_pin: ?ghostty.PageList.Pin = null;
    var found_boundary = false;

    while (iterator.next()) |pin| {
        switch (pin.rowAndCell().row.semantic_prompt) {
            .unknown, .prompt_continuation => {},
            .prompt => found_boundary = true,
            .command => {
                found_boundary = true;
                if (output_pin == null) output_pin = pin;
            },
            .input => {
                if (!found_boundary) continue;
                const output = output_pin orelse return try allocator.dupeZ(u8, "");
                const selection = screen.selectOutput(output) orelse return try allocator.dupeZ(u8, "");
                return try screen.selectionString(allocator, .{ .sel = selection, .trim = true });
            },
        }
    }
    return null;
}

/// How many rows above the cursor this pane's prompt block begins, `+ 1`.
///
/// **The answer a shell cannot work out for itself.** A shell redraws its prompt by going back up
/// to the block's first row and writing it again, and the only thing it has to go on is a count it
/// kept while drawing. That count is a guess the moment anything else moves the cursor — a float
/// opening over the pane, a program that scrolled, a prompt with rows added above or below it — and
/// a guess that is one out deletes somebody else's line or leaves a stale copy of its own.
///
/// The mux is the one party that does not have to guess: `OSC 133;A` already stamped the row, and
/// it is still stamped however much has happened since. So it answers, and the shell asks.
///
/// Offset by one so that `0` is a real answer meaning *no prompt is marked* — a shell that gets it
/// falls back to its own count instead of waiting out a timeout for silence.
pub fn rowsAboveCursor(vt: *core.VT) u32 {
    const screen = vt.terminal.screens.active;
    const cursor_y = vt.getCursor().y;
    var y: u32 = cursor_y;
    while (true) : (y -= 1) {
        const pin = screen.pages.pin(.{ .active = .{ .x = 0, .y = y } }) orelse return 0;
        if (pin.rowAndCell().row.semantic_prompt == .prompt) return cursor_y - y + 1;
        if (y == 0) return 0;
    }
}

fn setSemantic(vt: *core.VT, y: u32, semantic: anytype) !void {
    const pin = vt.terminal.screens.active.pages.pin(.{ .screen = .{ .x = 0, .y = y } }) orelse return error.UnknownPoint;
    pin.rowAndCell().row.semantic_prompt = semantic;
}

fn viewportY(vt: *core.VT) u32 {
    const screen = vt.terminal.screens.active;
    const point = screen.pages.pointFromPin(.screen, screen.pages.getTopLeft(.viewport)).?;
    return point.screen.y;
}

test "prompt jump is a no-op without marks" {
    var vt: core.VT = .{};
    try vt.init(std.testing.allocator, 8, 3);
    defer vt.deinit();
    try vt.feed("one\r\ntwo\r\nthree\r\nfour\r\n");

    const before = viewportY(&vt);
    try std.testing.expect(!jump(&vt, .previous));
    try std.testing.expectEqual(before, viewportY(&vt));
    try std.testing.expect((try lastOutputAlloc(std.testing.allocator, &vt)) == null);
}

test "prompt jump crosses scrollback and skips continuation marks" {
    var vt: core.VT = .{};
    try vt.init(std.testing.allocator, 8, 3);
    defer vt.deinit();
    try vt.feed("0\r\n1\r\n2\r\n3\r\n4\r\n5\r\n");
    try setSemantic(&vt, 1, .prompt);
    try setSemantic(&vt, 2, .prompt_continuation);
    try setSemantic(&vt, 4, .prompt);

    try std.testing.expect(jump(&vt, .previous));
    try std.testing.expectEqual(@as(u32, 1), viewportY(&vt));
    try std.testing.expect(!jump(&vt, .previous));
    try std.testing.expectEqual(@as(u32, 1), viewportY(&vt));
    try std.testing.expect(jump(&vt, .next));
    try std.testing.expectEqual(@as(u32, 4), viewportY(&vt));
}

test "copy last output follows OSC 133 lifecycle and handles empty output" {
    var vt: core.VT = .{};
    try vt.init(std.testing.allocator, 20, 6);
    defer vt.deinit();

    try vt.feed("\x1b]133;A\x07$ \x1b]133;B\x07echo one\r\n\x1b]133;C\x07one\r\n\x1b]133;D;0\x07\x1b]133;A\x07$ ");
    const first = (try lastOutputAlloc(std.testing.allocator, &vt)).?;
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("one", first);

    try vt.feed("\x1b]133;B\x07true\r\n\x1b]133;C\x07\x1b]133;D;0\x07\x1b]133;A\x07$ ");
    const empty = (try lastOutputAlloc(std.testing.allocator, &vt)).?;
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

test "OSC 133 marks and output survive resize reflow" {
    var vt: core.VT = .{};
    try vt.init(std.testing.allocator, 16, 5);
    defer vt.deinit();
    try vt.feed("\x1b]133;A\x07$ \x1b]133;B\x07printf\r\n\x1b]133;C\x07abcdefghijklmno\r\n\x1b]133;D;0\x07\x1b]133;A\x07$ ");

    try vt.resize(7, 5);
    const output = (try lastOutputAlloc(std.testing.allocator, &vt)).?;
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("abcdefghijklmno", output);
}
