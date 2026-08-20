//! Keypad input normalization.
//!
//! A keypad key has no single wire form. Depending on the outer terminal it
//! arrives as a plain digit (numlock on), as a Kitty functional code
//! (`CSI 57400 u`, which the protocol uses because the keypad has no legacy
//! encoding), or as an application-keypad SS3 sequence (`ESC O q`).
//!
//! Only the first reached a pane. Kitty codes were forwarded verbatim to a
//! shell that never negotiated the protocol, and SS3 keypad sequences are not
//! decoded by the input parser at all, so the parser-first policy dropped them.
//! Both are rewritten here, before parsing, into the conventional form every
//! pane already understands — which also makes the keys bindable, since the
//! bind key type has no keypad variants.

const std = @import("std");

pub const Match = struct {
    /// Input bytes consumed.
    consumed: usize,
    /// Replacement to emit instead.
    bytes: []const u8,
};

/// Kitty functional codes for the keypad (progressive enhancement, section
/// "Functional key definitions"). Contiguous from kp_0.
const KITTY_KP_FIRST: u32 = 57399;
const KITTY_KP_LAST: u32 = 57427;

fn kittyReplacement(code: u32) ?[]const u8 {
    return switch (code) {
        57399 => "0",
        57400 => "1",
        57401 => "2",
        57402 => "3",
        57403 => "4",
        57404 => "5",
        57405 => "6",
        57406 => "7",
        57407 => "8",
        57408 => "9",
        57409 => ".",
        57410 => "/",
        57411 => "*",
        57412 => "-",
        57413 => "+",
        57414 => "\r",
        57415 => "=",
        57416 => ",",
        57417 => "\x1b[D",
        57418 => "\x1b[C",
        57419 => "\x1b[A",
        57420 => "\x1b[B",
        57421 => "\x1b[5~",
        57422 => "\x1b[6~",
        57423 => "\x1b[H",
        57424 => "\x1b[F",
        57425 => "\x1b[2~",
        57426 => "\x1b[3~",
        57427 => "\x1b[E",
        else => null,
    };
}

/// Application-keypad SS3 finals, as sent by xterm and every terminal that
/// follows it.
fn ss3Replacement(final: u8) ?[]const u8 {
    return switch (final) {
        'p' => "0",
        'q' => "1",
        'r' => "2",
        's' => "3",
        't' => "4",
        'u' => "5",
        'v' => "6",
        'w' => "7",
        'x' => "8",
        'y' => "9",
        'n' => ".",
        'M' => "\r",
        'j' => "*",
        'k' => "+",
        'l' => ",",
        'm' => "-",
        'o' => "/",
        'X' => "=",
        else => null,
    };
}

/// Recognize a keypad sequence at the head of `inp`.
///
/// Modified presses (`CSI 57400;5u`) are left alone: they carry a modifier the
/// conventional form cannot express, and rewriting them would silently drop it.
pub fn match(inp: []const u8) ?Match {
    if (inp.len < 3 or inp[0] != 0x1b) return null;

    if (inp[1] == 'O') {
        const replacement = ss3Replacement(inp[2]) orelse return null;
        return .{ .consumed = 3, .bytes = replacement };
    }

    if (inp[1] != '[') return null;

    var i: usize = 2;
    var code: u32 = 0;
    var digits: usize = 0;
    while (i < inp.len and inp[i] >= '0' and inp[i] <= '9') : (i += 1) {
        code = code * 10 + (inp[i] - '0');
        digits += 1;
        if (digits > 6) return null;
    }
    if (digits == 0 or i >= inp.len or inp[i] != 'u') return null;
    if (code < KITTY_KP_FIRST or code > KITTY_KP_LAST) return null;

    const replacement = kittyReplacement(code) orelse return null;
    return .{ .consumed = i + 1, .bytes = replacement };
}

/// Rewrite every keypad sequence in `inp` into `out`, returning the length
/// written, or null when nothing matched (so the caller can skip the copy).
pub fn rewrite(out: []u8, inp: []const u8) ?usize {
    var found = false;
    var i: usize = 0;
    var w: usize = 0;
    while (i < inp.len) {
        if (match(inp[i..])) |m| {
            if (w + m.bytes.len > out.len) return null;
            @memcpy(out[w .. w + m.bytes.len], m.bytes);
            w += m.bytes.len;
            i += m.consumed;
            found = true;
            continue;
        }
        if (w >= out.len) return null;
        out[w] = inp[i];
        w += 1;
        i += 1;
    }
    return if (found) w else null;
}

test "kitty keypad codes become their conventional form" {
    try std.testing.expectEqualStrings("1", match("\x1b[57400u").?.bytes);
    try std.testing.expectEqualStrings("\r", match("\x1b[57414u").?.bytes);
    try std.testing.expectEqualStrings("+", match("\x1b[57413u").?.bytes);
    try std.testing.expectEqualStrings("\x1b[H", match("\x1b[57423u").?.bytes);
    try std.testing.expectEqual(@as(usize, 8), match("\x1b[57400u").?.consumed);
}

test "application-keypad SS3 sequences become their conventional form" {
    try std.testing.expectEqualStrings("1", match("\x1bOq").?.bytes);
    try std.testing.expectEqualStrings("+", match("\x1bOk").?.bytes);
    try std.testing.expectEqualStrings("\r", match("\x1bOM").?.bytes);
    try std.testing.expectEqual(@as(usize, 3), match("\x1bOq").?.consumed);
}

test "non-keypad input is never rewritten" {
    // Arrows and F-keys keep their legacy form; a modified keypad press keeps
    // its modifier rather than losing it to a bare digit.
    try std.testing.expect(match("\x1bOA") == null);
    try std.testing.expect(match("\x1b[A") == null);
    try std.testing.expect(match("\x1b[57400;5u") == null);
    try std.testing.expect(match("\x1b[200~") == null);
    try std.testing.expect(match("\x1b[27u") == null);
    try std.testing.expect(match("1") == null);
}

test "rewrite only reports a change when one happened" {
    var buf: [32]u8 = undefined;
    try std.testing.expect(rewrite(&buf, "abc") == null);
    const n = rewrite(&buf, "a\x1b[57400ub").?;
    try std.testing.expectEqualStrings("a1b", buf[0..n]);
    const m = rewrite(&buf, "\x1bOq\x1bOk").?;
    try std.testing.expectEqualStrings("1+", buf[0..m]);
}
