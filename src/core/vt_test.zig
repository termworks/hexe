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

/// The tag hexe stamps onto the cursor is what ghostty copies onto every cell
/// written next. These assert on that tag directly rather than through a
/// rendered frame: a screen capture goes through the renderer, vaxis diffing and
/// a pty, any of which can mask the thing under test.
fn initTagVt(vt: *core.VT) !void {
    try vt.init(std.testing.allocator, 20, 5);
    vt.ns_table.setEnabled(true);
}

fn cursorTag(vt: *core.VT) u8 {
    return vt.terminal.screens.active.cursor.style.flags.ns;
}

test "the tag hexe stamps reaches the cursor" {
    var vt: core.VT = undefined;
    try initTagVt(&vt);
    defer vt.deinit();

    try std.testing.expectEqual(@as(u8, 0), cursorTag(&vt));
    _ = core.palette.applyOsc(&vt.ns_table, "use;2");
    vt.syncNamespaceStyle();
    try std.testing.expectEqual(@as(u8, 2), cursorTag(&vt));
}

test "an SGR reset does not clear the tag" {
    var vt: core.VT = undefined;
    try initTagVt(&vt);
    defer vt.deinit();
    _ = core.palette.applyOsc(&vt.ns_table, "use;2");
    vt.syncNamespaceStyle();

    // Programs emit this constantly; clearing here would untag everything
    // printed after the first reset in a run of output.
    try vt.feed("A\x1b[0mB");
    try std.testing.expectEqual(@as(u8, 2), cursorTag(&vt));
}

test "a cursor restore does not resurrect a released selection" {
    var vt: core.VT = undefined;
    try initTagVt(&vt);
    defer vt.deinit();
    _ = core.palette.applyOsc(&vt.ns_table, "use;2");
    vt.syncNamespaceStyle();

    try vt.feed("\x1b7"); // DECSC, saves the style with the tag
    _ = core.palette.applyOsc(&vt.ns_table, "end");
    vt.syncNamespaceStyle();
    try std.testing.expectEqual(@as(u8, 0), cursorTag(&vt));

    try vt.feed("\x1b8"); // DECRC
    // The program released it; the restore must not bring it back, or whatever
    // prints next is stamped with someone else's namespace.
    try std.testing.expectEqual(@as(u8, 0), cursorTag(&vt));
}

test "a full reset does not silently untag later output" {
    var vt: core.VT = undefined;
    try initTagVt(&vt);
    defer vt.deinit();
    _ = core.palette.applyOsc(&vt.ns_table, "use;2");
    vt.syncNamespaceStyle();
    try std.testing.expectEqual(@as(u8, 2), cursorTag(&vt));

    // RIS and the output after it in ONE feed: hexe cannot re-stamp between
    // bytes it has already handed over, so if the reset clears the tag then
    // everything the program prints afterwards is untagged and hexe has no way
    // to notice — it never sees the sequence.
    try vt.feed("\x1bcAFTER");
    try std.testing.expectEqual(@as(u8, 2), cursorTag(&vt));
}

test "the tag follows the pane across an alt-screen switch" {
    var vt: core.VT = undefined;
    try initTagVt(&vt);
    defer vt.deinit();
    _ = core.palette.applyOsc(&vt.ns_table, "use;3");
    vt.syncNamespaceStyle();

    try vt.feed("\x1b[?1049h");
    try std.testing.expectEqual(@as(u8, 3), cursorTag(&vt));

    _ = core.palette.applyOsc(&vt.ns_table, "end");
    vt.syncNamespaceStyle();
    try vt.feed("\x1b[?1049l");
    // Released inside the alternate screen: leaving must not bring it back onto
    // the primary, where the shell's own output would then carry it.
    try std.testing.expectEqual(@as(u8, 0), cursorTag(&vt));
}
