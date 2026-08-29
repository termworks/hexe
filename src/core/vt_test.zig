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

test "VT stores a Kitty image transmitted over APC" {
    var vt: core.VT = undefined;
    try vt.init(std.testing.allocator, 20, 5);
    defer vt.deinit();

    // 4x4 RGBA, transmitted and displayed in one command.
    const pixels = [_]u8{ 255, 0, 0, 255 } ** 16;
    var b64: [128]u8 = undefined;
    const payload = std.base64.standard.Encoder.encode(&b64, &pixels);

    var seq: std.ArrayListUnmanaged(u8) = .empty;
    defer seq.deinit(std.testing.allocator);
    try seq.appendSlice(std.testing.allocator, "\x1b_Gf=32,s=4,v=4,i=42,a=T;");
    try seq.appendSlice(std.testing.allocator, payload);
    try seq.appendSlice(std.testing.allocator, "\x1b\\");

    try vt.feed(seq.items);

    const storage = &vt.terminal.screens.active.kitty_images;
    try std.testing.expectEqual(@as(usize, 1), storage.images.count());
    try std.testing.expect(storage.imageById(42) != null);
    try std.testing.expect(storage.placements.count() > 0);
}

/// Text on the VT's first row, trimmed. Images are asserted through the image
/// store; this is for the bytes that must reach the screen unchanged.
fn firstRow(vt: *core.VT, buf: []u8) []const u8 {
    const state = vt.getRenderState() catch return "";
    if (state.rows == 0) return "";
    const rows = state.row_data.slice();
    const cells = rows.items(.cells)[0].slice().items(.raw);
    var n: usize = 0;
    for (cells) |cell| {
        const cp = cell.codepoint();
        if (cp == 0 or cp > 127) continue;
        if (n < buf.len) {
            buf[n] = @intCast(cp);
            n += 1;
        }
    }
    return std.mem.trimRight(u8, buf[0..n], " ");
}

test "VT imports a sixel image and keeps the text around it" {
    var vt: core.VT = undefined;
    try vt.init(std.testing.allocator, 20, 5);
    defer vt.deinit();

    // Red, four columns wide, one band tall, with ordinary text either side.
    try vt.feed("AB\x1bP0;1;0q#1;2;100;0;0!4~\x1b\\CD");

    const storage = &vt.terminal.screens.active.kitty_images;
    try std.testing.expectEqual(@as(usize, 1), storage.images.count());
    try std.testing.expect(storage.placements.count() > 0);

    var it = storage.images.iterator();
    const img = it.next().?.value_ptr.*;
    try std.testing.expectEqual(@as(u32, 4), img.width);
    try std.testing.expectEqual(@as(u32, 6), img.height);

    // The sixel itself must not have reached the screen as text.
    var buf: [64]u8 = undefined;
    const row = firstRow(&vt, &buf);
    try std.testing.expect(std.mem.indexOf(u8, row, "#1") == null);
    try std.testing.expect(std.mem.startsWith(u8, row, "AB"));
}

test "VT imports a sixel split across feeds" {
    var vt: core.VT = undefined;
    try vt.init(std.testing.allocator, 20, 5);
    defer vt.deinit();

    // A pty read can land anywhere, including between the introducer and its
    // parameters, or mid-payload.
    try vt.feed("\x1bP0;1");
    try vt.feed(";0q#1;2;0;100;0!3");
    try vt.feed("~\x1b");
    try vt.feed("\\done");

    const storage = &vt.terminal.screens.active.kitty_images;
    try std.testing.expectEqual(@as(usize, 1), storage.images.count());

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("done", firstRow(&vt, &buf));
}

test "VT leaves non-image escape sequences alone" {
    var vt: core.VT = undefined;
    try vt.init(std.testing.allocator, 20, 5);
    defer vt.deinit();

    // An OSC that is not an inline image, a DCS that is not sixel, and a bare
    // ESC sequence. None may be swallowed, and none may load an image.
    try vt.feed("\x1b]0;a title\x07");
    try vt.feed("\x1bP$q\"p\x1b\\");
    try vt.feed("\x1b[31mred\x1b[m");

    const storage = &vt.terminal.screens.active.kitty_images;
    try std.testing.expectEqual(@as(usize, 0), storage.images.count());

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("red", firstRow(&vt, &buf));
}

test "VT imports an iTerm2 inline PNG" {
    var vt: core.VT = undefined;
    try vt.init(std.testing.allocator, 20, 5);
    defer vt.deinit();

    // The smallest valid PNG: 1x1, fully transparent.
    const png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
        0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    };
    var b64: [256]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&b64, &png);

    var seq: std.ArrayListUnmanaged(u8) = .empty;
    defer seq.deinit(std.testing.allocator);
    try seq.appendSlice(std.testing.allocator, "\x1b]1337;File=inline=1;size=69:");
    try seq.appendSlice(std.testing.allocator, encoded);
    try seq.appendSlice(std.testing.allocator, "\x07after");

    try vt.feed(seq.items);

    const storage = &vt.terminal.screens.active.kitty_images;
    try std.testing.expectEqual(@as(usize, 1), storage.images.count());
    var it = storage.images.iterator();
    const img = it.next().?.value_ptr.*;
    try std.testing.expectEqual(@as(u32, 1), img.width);
    try std.testing.expectEqual(@as(u32, 1), img.height);

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("after", firstRow(&vt, &buf));
}
