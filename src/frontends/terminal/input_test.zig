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
    const legacy = key_translate.encodeKey(&buf, ev.mods, ev.key, ev.text_codepoint, .press, &vt.terminal) orelse
        return error.MissingEncoding;
    try testing.expectEqualStrings("\x1c", legacy);

    try vt.feed("\x1b[>1u");
    const kitty = key_translate.encodeKey(&buf, ev.mods, ev.key, ev.text_codepoint, .press, &vt.terminal) orelse
        return error.MissingEncoding;
    try testing.expectEqualStrings("\x1b[92;5u", kitty);
}

test "keyEventFromVaxisEvent: escape is not swept up by the new range" {
    const ev = input.keyEventFromVaxisEvent(press(vaxis.Key.escape)) orelse
        return error.NotDecoded;
    try testing.expectEqual(@as(u8, 0x1b), ev.key.char);
    try testing.expectEqual(@as(u8, 0), ev.mods & CTRL);
}

fn release(codepoint: u21) vaxis.Event {
    return .{ .key_release = .{ .codepoint = codepoint } };
}

// An application that holds a key needs to be told when it is let go. hexe used
// to encode every forwarded key as a press regardless, so a release -- if one
// had been forwarded at all -- arrived as a phantom second press, and a hold
// counter never cleared.
test "a release encodes as a release, not as another press" {
    var vt: core.VT = .{};
    try vt.init(testing.allocator, 80, 24);
    defer vt.deinit();

    // The pane asks for the disambiguate + report_events flags, which is what
    // makes the protocol carry an event type at all.
    try vt.feed("\x1b[>3u");

    const ev = input.keyEventFromVaxisEvent(release(' ')) orelse return error.NotDecoded;
    try testing.expectEqual(core.Config.BindWhen.release, ev.when);

    var buf: [64]u8 = undefined;
    const down = key_translate.encodeKey(&buf, ev.mods, ev.key, ev.text_codepoint, .press, &vt.terminal) orelse
        return error.MissingEncoding;
    var press_buf: [64]u8 = undefined;
    @memcpy(press_buf[0..down.len], down);
    const pressed = press_buf[0..down.len];

    const up = key_translate.encodeKey(&buf, ev.mods, ev.key, ev.text_codepoint, .release, &vt.terminal) orelse
        return error.MissingEncoding;

    // The two halves must not be the same bytes, and the release carries the
    // Kitty event type `3`.
    try testing.expect(!std.mem.eql(u8, pressed, up));
    try testing.expect(std.mem.indexOf(u8, up, ":3") != null);
}

test "with no flags set there is nothing to distinguish, so a release must not be sent" {
    var vt: core.VT = .{};
    try vt.init(testing.allocator, 80, 24);
    defer vt.deinit();

    // No `CSI > u`: the pane never asked. A release has no legacy spelling, so
    // the encoder produces nothing at all -- which is why forwarding has to be
    // gated on the flag rather than left to the encoder.
    const ev = input.keyEventFromVaxisEvent(release('a')) orelse return error.NotDecoded;
    var buf: [64]u8 = undefined;
    const up = key_translate.encodeKey(&buf, ev.mods, ev.key, ev.text_codepoint, .release, &vt.terminal);
    try testing.expect(up == null or up.?.len == 0);
}
