const std = @import("std");
const vt_mod = @import("vt.zig");
const ghostty = @import("ghostty-vt");

pub const Direction = enum { previous, next };

pub fn jump(vt: *vt_mod.VT, direction: Direction) bool {
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

/// Whether this screen carries OSC 133 prompt marks at all.
///
/// Without shell integration every row is `.unknown`, and then "the last
/// command" is not a question the screen can answer. Asked separately so a
/// caller can say that, rather than hand back a plausible-looking screenful and
/// let it pass for a command's output.
pub fn hasMarks(vt: *vt_mod.VT) bool {
    const screen = vt.terminal.screens.active;
    const bottom = screen.pages.getBottomRight(.screen) orelse return false;
    var iterator = bottom.rowIterator(.left_up, null);
    while (iterator.next()) |pin| {
        switch (pin.rowAndCell().row.semantic_prompt) {
            .unknown => {},
            else => return true,
        }
    }
    return false;
}

/// Whether a row has anything on it.
fn rowIsBlank(allocator: std.mem.Allocator, screen: anytype, pin: ghostty.PageList.Pin) bool {
    const sel = ghostty.Selection.init(pin, pin, false);
    const text = screen.selectionString(allocator, .{ .sel = sel, .trim = true }) catch return false;
    defer allocator.free(text);
    return std.mem.sliceTo(text, 0).len == 0;
}

/// The last `n` rows that have something on them, as text.
///
/// The plain answer for a pane with no shell integration, and the one `-n`
/// asks for. Rows rather than bytes: `screen_text` budgets bytes and anchors at
/// the cursor, which answers a different question.
///
/// The walk starts at the last row with content, not at the bottom of the
/// screen. A shell that just printed a line leaves the cursor on the blank row
/// below it, so counting from the bottom spent one of the `n` on nothing and
/// `-n 2` came back with a single line.
pub fn lastLinesAlloc(allocator: std.mem.Allocator, vt: *vt_mod.VT, n: usize) !?[:0]const u8 {
    if (n == 0) return try allocator.dupeZ(u8, "");
    const screen = vt.terminal.screens.active;
    const screen_bottom = screen.pages.getBottomRight(.screen) orelse return null;

    var bottom = screen_bottom;
    var down = screen_bottom.rowIterator(.left_up, null);
    while (down.next()) |pin| {
        if (!rowIsBlank(allocator, screen, pin)) {
            bottom = pin;
            break;
        }
    }

    // Then up n-1 more rows, stopping at the top: asking for more rows than
    // exist is not an error, it is the whole history.
    var top = bottom;
    var iterator = bottom.rowIterator(.left_up, null);
    var seen: usize = 0;
    while (iterator.next()) |pin| {
        top = pin;
        seen += 1;
        if (seen >= n) break;
    }

    // The iterator hands out pins at column 0, so the end pin has to be pushed
    // to the last column or the final row is cut after one character.
    var end = bottom;
    if (vt.terminal.cols > 0) end.x = @intCast(vt.terminal.cols - 1);

    const sel = ghostty.Selection.init(top, end, false);
    return try screen.selectionString(allocator, .{ .sel = sel, .trim = true });
}

/// The output of the last `n` commands, oldest first.
///
/// `n == 1` is `lastOutputAlloc`. Beyond that the walk keeps going up, counting
/// a command boundary each time it crosses from one block into the one above,
/// and the selection runs from the oldest kept block's output to the newest.
/// One selection rather than n of them: consecutive blocks are contiguous rows,
/// so joining their text separately would only risk losing what sat between.
pub fn lastCommandsAlloc(allocator: std.mem.Allocator, vt: *vt_mod.VT, n: usize) !?[:0]const u8 {
    if (n <= 1) return lastOutputAlloc(allocator, vt);
    // Null, not empty: "this pane has no prompt marks" is a different answer
    // from "the last commands printed nothing", and the caller has to be able
    // to tell them apart to suggest `-n` instead.
    if (!hasMarks(vt)) return null;

    const screen = vt.terminal.screens.active;
    const bottom = screen.pages.getBottomRight(.screen) orelse return null;
    var iterator = bottom.rowIterator(.left_up, null);

    var newest_output: ?ghostty.PageList.Pin = null;
    var oldest_output: ?ghostty.PageList.Pin = null;
    var blocks: usize = 0;
    // `.input` is the row the command was typed on, so crossing one means the
    // block above is a different command. That is the boundary to count.
    var in_block = false;

    while (iterator.next()) |pin| {
        switch (pin.rowAndCell().row.semantic_prompt) {
            .unknown, .prompt_continuation => {},
            .command => {
                in_block = true;
                if (newest_output == null) newest_output = pin;
                oldest_output = pin;
            },
            .prompt => in_block = true,
            .input => {
                if (!in_block) continue;
                blocks += 1;
                in_block = false;
                if (blocks >= n) break;
            },
        }
    }

    const newest = newest_output orelse return try allocator.dupeZ(u8, "");
    const oldest = oldest_output orelse newest;
    const newest_sel = screen.selectOutput(newest) orelse return try allocator.dupeZ(u8, "");
    const oldest_sel = screen.selectOutput(oldest) orelse newest_sel;
    const sel = ghostty.Selection.init(oldest_sel.start(), newest_sel.end(), false);
    return try screen.selectionString(allocator, .{ .sel = sel, .trim = true });
}

pub fn lastOutputAlloc(allocator: std.mem.Allocator, vt: *vt_mod.VT) !?[:0]const u8 {
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
///
/// # The walk stops at output, and that is the whole safety of it
///
/// **A prompt mark further up the screen is not this prompt's.** Searching until *some* `.prompt`
/// turned up looked right, and was the worst answer possible when it was wrong: the shell was told
/// its block began where the *previous* command's block began, went back that far, and erased from
/// there — taking that command's frame and the whole of its output with it.
///
/// It is wrong more often than it looks, because a shell may legitimately un-mark its own prompt.
/// `OSC 133;C` stamps the row the cursor is on as output, and a key bound with `erase` — a key that
/// *is* a command — deliberately parks the cursor back at the top of its block before the command
/// starts. That row is the one `133;A` marked, so the block still on screen has no mark left by the
/// time anybody asks about it.
///
/// So what the walk goes back through is the block's own: `.input` and continuation rows are its,
/// and unmarked rows may be. A row marked as output is not, and reaching one means this block has
/// no mark of its own — which is a `0`, and a shell that counts for itself.
pub fn rowsAboveCursor(vt: *vt_mod.VT) u32 {
    const screen = vt.terminal.screens.active;
    const cursor_y = vt.getCursor().y;
    var y: u32 = cursor_y;
    while (true) : (y -= 1) {
        const pin = screen.pages.pin(.{ .active = .{ .x = 0, .y = y } }) orelse return 0;
        switch (pin.rowAndCell().row.semantic_prompt) {
            .prompt => return cursor_y - y + 1,
            .command => return 0,
            .unknown, .prompt_continuation, .input => {},
        }
        if (y == 0) return 0;
    }
}

fn setSemantic(vt: *vt_mod.VT, y: u32, semantic: anytype) !void {
    const pin = vt.terminal.screens.active.pages.pin(.{ .screen = .{ .x = 0, .y = y } }) orelse return error.UnknownPoint;
    pin.rowAndCell().row.semantic_prompt = semantic;
}

fn viewportY(vt: *vt_mod.VT) u32 {
    const screen = vt.terminal.screens.active;
    const point = screen.pages.pointFromPin(.screen, screen.pages.getTopLeft(.viewport)).?;
    return point.screen.y;
}

test "prompt jump is a no-op without marks" {
    var vt: vt_mod.VT = .{};
    try vt.init(std.testing.allocator, 8, 3);
    defer vt.deinit();
    try vt.feed("one\r\ntwo\r\nthree\r\nfour\r\n");

    const before = viewportY(&vt);
    try std.testing.expect(!jump(&vt, .previous));
    try std.testing.expectEqual(before, viewportY(&vt));
    try std.testing.expect((try lastOutputAlloc(std.testing.allocator, &vt)) == null);
}

test "prompt jump crosses scrollback and skips continuation marks" {
    var vt: vt_mod.VT = .{};
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
    var vt: vt_mod.VT = .{};
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
    var vt: vt_mod.VT = .{};
    try vt.init(std.testing.allocator, 16, 5);
    defer vt.deinit();
    try vt.feed("\x1b]133;A\x07$ \x1b]133;B\x07printf\r\n\x1b]133;C\x07abcdefghijklmno\r\n\x1b]133;D;0\x07\x1b]133;A\x07$ ");

    try vt.resize(7, 5);
    const output = (try lastOutputAlloc(std.testing.allocator, &vt)).?;
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("abcdefghijklmno", output);
}

test "hasMarks tells shell integration from a bare screen" {
    var vt: vt_mod.VT = .{};
    try vt.init(std.testing.allocator, 20, 6);
    defer vt.deinit();
    try vt.feed("plain output\r\nno marks here\r\n");
    try std.testing.expect(!hasMarks(&vt));

    try vt.feed("\x1b]133;A\x07$ ");
    try std.testing.expect(hasMarks(&vt));
}

test "lastLinesAlloc takes rows from the bottom, and clamps to what exists" {
    var vt: vt_mod.VT = .{};
    try vt.init(std.testing.allocator, 20, 4);
    defer vt.deinit();
    try vt.feed("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n");

    const two = (try lastLinesAlloc(std.testing.allocator, &vt, 2)).?;
    defer std.testing.allocator.free(two);
    try std.testing.expectEqualStrings("four\nfive", two);

    const one = (try lastLinesAlloc(std.testing.allocator, &vt, 1)).?;
    defer std.testing.allocator.free(one);
    try std.testing.expectEqualStrings("five", one);

    // More rows than exist is the whole history, not an error: a caller asking
    // for 500 lines of a 5-line pane wants the 5.
    const all = (try lastLinesAlloc(std.testing.allocator, &vt, 500)).?;
    defer std.testing.allocator.free(all);
    try std.testing.expect(std.mem.endsWith(u8, all, "five"));
    try std.testing.expect(std.mem.indexOf(u8, all, "one") != null);

    // Zero is a request for nothing, which is an answer, not a null.
    const none = (try lastLinesAlloc(std.testing.allocator, &vt, 0)).?;
    defer std.testing.allocator.free(none);
    try std.testing.expectEqualStrings("", none);
}

test "lastCommandsAlloc spans n command blocks, newest last" {
    var vt: vt_mod.VT = .{};
    try vt.init(std.testing.allocator, 20, 12);
    defer vt.deinit();

    // Three complete commands, each a full OSC 133 lifecycle.
    try vt.feed("\x1b]133;A\x07$ \x1b]133;B\x07echo a\r\n\x1b]133;C\x07aaa\r\n\x1b]133;D;0\x07");
    try vt.feed("\x1b]133;A\x07$ \x1b]133;B\x07echo b\r\n\x1b]133;C\x07bbb\r\n\x1b]133;D;0\x07");
    try vt.feed("\x1b]133;A\x07$ \x1b]133;B\x07echo c\r\n\x1b]133;C\x07ccc\r\n\x1b]133;D;0\x07\x1b]133;A\x07$ ");

    // One command is the last one only -- same answer as lastOutputAlloc.
    const one = (try lastCommandsAlloc(std.testing.allocator, &vt, 1)).?;
    defer std.testing.allocator.free(one);
    try std.testing.expectEqualStrings("ccc", one);

    // Two reaches back over the previous block and keeps both, in order.
    const two = (try lastCommandsAlloc(std.testing.allocator, &vt, 2)).?;
    defer std.testing.allocator.free(two);
    try std.testing.expect(std.mem.indexOf(u8, two, "bbb") != null);
    try std.testing.expect(std.mem.indexOf(u8, two, "ccc") != null);
    try std.testing.expect(std.mem.indexOf(u8, two, "bbb").? < std.mem.indexOf(u8, two, "ccc").?);
    // Not the one before that.
    try std.testing.expect(std.mem.indexOf(u8, two, "aaa") == null);

    // Asking for more blocks than the screen holds returns what there is.
    const many = (try lastCommandsAlloc(std.testing.allocator, &vt, 99)).?;
    defer std.testing.allocator.free(many);
    try std.testing.expect(std.mem.indexOf(u8, many, "aaa") != null);
    try std.testing.expect(std.mem.indexOf(u8, many, "ccc") != null);
}

test "lastCommandsAlloc is null on a screen with no marks" {
    var vt: vt_mod.VT = .{};
    try vt.init(std.testing.allocator, 20, 4);
    defer vt.deinit();
    try vt.feed("just output\r\nnothing marked\r\n");
    try std.testing.expect((try lastCommandsAlloc(std.testing.allocator, &vt, 3)) == null);
}
