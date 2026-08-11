// Regression tests for input.keyEventFromVaxisEvent — the decoder that turns what a terminal sent
// into the key event the rest of the frontend reasons about.
//
// The canonical bug this guards against: a legacy terminal sends `^\` as a bare 0x1c with nothing
// to say it was a chord. Only 0x01..0x1A were normalized back to a letter plus Ctrl, so 0x1c..0x1f
// fell through as control-byte "characters" with no modifier. Since the frontend re-encodes decoded
// presses rather than forwarding the original bytes, the encoder was then handed an unidentified
// key with no text and — correctly — wrote nothing. `^\ ^] ^^ ^_` reached no program in a pane.
//
// These tests pin the post-fix behavior: each of those four decodes to its letter plus Ctrl, which
// is what the re-encoder needs to produce the byte again.

const std = @import("std");
const testing = std.testing;
const core = @import("core");
const vaxis = @import("vaxis");
const input = @import("input.zig");
const key_translate = @import("key_translate.zig");

const CTRL: u8 = 2;

fn press(codepoint: u21) vaxis.Event {
    return .{ .key_press = .{ .codepoint = codepoint } };
}

fn decodedChar(codepoint: u21) !input.KeyEvent {
    const ev = input.keyEventFromVaxisEvent(press(codepoint)) orelse return error.NotDecoded;
    try testing.expect(@as(core.Config.BindKeyKind, ev.key) == .char);
    return ev;
}

test "keyEventFromVaxisEvent: the control bytes above the alphabet carry Ctrl and their letter" {
    const cases = [_]struct { byte: u21, char: u8 }{
        .{ .byte = 0x1c, .char = '\\' },
        .{ .byte = 0x1d, .char = ']' },
        .{ .byte = 0x1e, .char = '^' },
        .{ .byte = 0x1f, .char = '_' },
    };
    for (cases) |case| {
        const ev = try decodedChar(case.byte);
        try testing.expectEqual(case.char, ev.key.char);
        try testing.expectEqual(CTRL, ev.mods & CTRL);
    }
}

test "keyEventFromVaxisEvent: Ctrl+letter still normalizes to a-z" {
    const ev = try decodedChar(0x03);
    try testing.expectEqual(@as(u8, 'c'), ev.key.char);
    try testing.expectEqual(CTRL, ev.mods & CTRL);
}

// The whole round trip, which is what a pane actually sees: the byte a terminal sends is decoded
// into a chord and then re-encoded, because the frontend never forwards the original bytes.
// Legacy in, legacy out; and the Kitty spelling once a program in the pane has asked for it.
test "a ^\\ typed at the terminal reaches the pane, in whichever spelling is current" {
    var vt: core.VT = .{};
    try vt.init(testing.allocator, 80, 24);
    defer vt.deinit();

    const ev = input.keyEventFromVaxisEvent(press(0x1c)) orelse return error.NotDecoded;

    var buf: [64]u8 = undefined;
    const legacy = key_translate.encodeKey(&buf, ev.mods, ev.key, ev.text_codepoint, &vt.terminal) orelse
        return error.MissingEncoding;
    try testing.expectEqualStrings("\x1c", legacy);

    try vt.feed("\x1b[>1u");
    const kitty = key_translate.encodeKey(&buf, ev.mods, ev.key, ev.text_codepoint, &vt.terminal) orelse
        return error.MissingEncoding;
    try testing.expectEqualStrings("\x1b[92;5u", kitty);
}

test "keyEventFromVaxisEvent: escape is not swept up by the new range" {
    const ev = input.keyEventFromVaxisEvent(press(vaxis.Key.escape)) orelse
        return error.NotDecoded;
    try testing.expectEqual(@as(u8, 0x1b), ev.key.char);
    try testing.expectEqual(@as(u8, 0), ev.mods & CTRL);
}
