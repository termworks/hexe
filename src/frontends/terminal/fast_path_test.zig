// Regression tests for fast_path.fastPathBytes — the helper that decides
// whether text-producing key events should be forwarded as raw UTF-8 without
// going through ghostty's full key encoder.
//
// The canonical bug this guards against: .space with a text_codepoint was
// previously skipped by the fast path (only .char was covered), so pressing
// space in a pane that had enabled Kitty keyboard report_all produced a
// CSI u sequence instead of " ". Apps that opted into report_all for event
// tracking but parsed input as text saw space "disappear".
//
// These tests pin the post-fix behavior: for every plain text-producing
// key (including bare space), the fast path must emit raw UTF-8.

const std = @import("std");
const testing = std.testing;
const core = @import("core");
const fast_path = @import("fast_path.zig");
const key_translate = @import("key_translate.zig");

const BindKey = core.Config.BindKey;

test "fastPathBytes: bare space with codepoint → 0x20" {
    var buf: [16]u8 = undefined;
    const n = fast_path.fastPathBytes(&buf, 0, .space, 0x20, 0) orelse {
        return error.ShouldHaveTakenFastPath;
    };
    try testing.expectEqualSlices(u8, &.{0x20}, buf[0..n]);
}

test "fastPathBytes: bare letter with codepoint → single byte" {
    var buf: [16]u8 = undefined;
    const n = fast_path.fastPathBytes(&buf, 0, .{ .char = 'a' }, 'a', 0) orelse {
        return error.ShouldHaveTakenFastPath;
    };
    try testing.expectEqualSlices(u8, "a", buf[0..n]);
}

test "fastPathBytes: Alt+letter → ESC + letter" {
    var buf: [16]u8 = undefined;
    const n = fast_path.fastPathBytes(&buf, 1, .{ .char = 'x' }, 'x', 0) orelse {
        return error.ShouldHaveTakenFastPath;
    };
    try testing.expectEqualSlices(u8, &.{ 0x1b, 'x' }, buf[0..n]);
}

test "fastPathBytes: Alt+space → ESC + 0x20" {
    var buf: [16]u8 = undefined;
    const n = fast_path.fastPathBytes(&buf, 1, .space, 0x20, 0) orelse {
        return error.ShouldHaveTakenFastPath;
    };
    try testing.expectEqualSlices(u8, &.{ 0x1b, 0x20 }, buf[0..n]);
}

test "fastPathBytes: Ctrl+letter → C0 byte (no codepoint needed)" {
    var buf: [16]u8 = undefined;
    // Ctrl+C (mods=2, 'c') → 0x03. The Ctrl+letter path does not look at
    // text_codepoint, so pass null.
    const n = fast_path.fastPathBytes(&buf, 2, .{ .char = 'c' }, null, 0) orelse {
        return error.ShouldHaveTakenFastPath;
    };
    try testing.expectEqualSlices(u8, &.{0x03}, buf[0..n]);
}

test "fastPathBytes: Ctrl+letter accepts uppercase and lowercases it" {
    var buf: [16]u8 = undefined;
    const n = fast_path.fastPathBytes(&buf, 2, .{ .char = 'C' }, null, 0) orelse {
        return error.ShouldHaveTakenFastPath;
    };
    try testing.expectEqualSlices(u8, &.{0x03}, buf[0..n]);
}

test "fastPathBytes: Ctrl+space falls through (not .char)" {
    // Ctrl+space has mods=2 and key=.space — the Ctrl+letter branch only
    // matches .char, and the text fast path rejects Ctrl. The caller must
    // fall back to the full encoder to produce 0x00.
    var buf: [16]u8 = undefined;
    try testing.expect(fast_path.fastPathBytes(&buf, 2, .space, 0x20, 0) == null);
}

test "fastPathBytes: Super+key falls through" {
    // Super (mods bit 8) implies a binding intent; the encoder decides.
    var buf: [16]u8 = undefined;
    try testing.expect(fast_path.fastPathBytes(&buf, 8, .{ .char = 'a' }, 'a', 0) == null);
}

test "fastPathBytes: arrow keys fall through (not text-producing)" {
    var buf: [16]u8 = undefined;
    try testing.expect(fast_path.fastPathBytes(&buf, 0, .up, null, 0) == null);
    try testing.expect(fast_path.fastPathBytes(&buf, 0, .down, null, 0) == null);
    try testing.expect(fast_path.fastPathBytes(&buf, 0, .left, null, 0) == null);
    try testing.expect(fast_path.fastPathBytes(&buf, 0, .right, null, 0) == null);
}

test "fastPathBytes: .char without codepoint falls through" {
    // Without a decoded text_codepoint we can't emit raw text — let the
    // encoder handle legacy keyboard layouts etc.
    var buf: [16]u8 = undefined;
    try testing.expect(fast_path.fastPathBytes(&buf, 0, .{ .char = 'a' }, null, 0) == null);
}

test "fastPathBytes: non-ASCII codepoint emits multi-byte UTF-8" {
    var buf: [16]u8 = undefined;
    // é = U+00E9 = C3 A9 in UTF-8.
    const n = fast_path.fastPathBytes(&buf, 0, .{ .char = 0 }, 0xE9, 0) orelse {
        return error.ShouldHaveTakenFastPath;
    };
    try testing.expectEqualSlices(u8, &.{ 0xc3, 0xa9 }, buf[0..n]);
}

test "fastPathBytes: Kitty keyboard flags use the protocol encoder" {
    var buf: [16]u8 = undefined;
    try testing.expect(fast_path.fastPathBytes(&buf, 2, .{ .char = 'i' }, null, 1) == null);
    try testing.expect(fast_path.fastPathBytes(&buf, 0, .space, 0x20, 2) == null);
}

test "key encoder distinguishes control chords from legacy keys" {
    var vt: core.VT = .{};
    try vt.init(testing.allocator, 80, 24);
    defer vt.deinit();
    try vt.feed("\x1b[>1u");

    var buf: [64]u8 = undefined;
    const ctrl_i = key_translate.encodeKey(&buf, 2, .{ .char = 'i' }, null, &vt.terminal) orelse return error.MissingEncoding;
    try testing.expectEqualStrings("\x1b[105;5u", ctrl_i);
    const tab = key_translate.encodeKey(&buf, 0, .{ .char = '\t' }, null, &vt.terminal) orelse return error.MissingEncoding;
    try testing.expectEqualStrings("\t", tab);
    const ctrl_m = key_translate.encodeKey(&buf, 2, .{ .char = 'm' }, null, &vt.terminal) orelse return error.MissingEncoding;
    try testing.expectEqualStrings("\x1b[109;5u", ctrl_m);
    const enter = key_translate.encodeKey(&buf, 0, .{ .char = '\r' }, null, &vt.terminal) orelse return error.MissingEncoding;
    try testing.expectEqualStrings("\r", enter);
}
