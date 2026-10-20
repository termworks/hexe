//! Telling a terminal's colour ANSWER from everything else on the wire.
//!
//! `OSC 4;N;?` asks what palette entry N is; the terminal answers
//! `OSC 4;N;rgb:RRRR/GGGG/BBBB`, four hex digits a channel. The two look alike
//! and travel the same path, so anything routing OSC has to be able to say
//! which it is holding.
//!
//! In `core` because both ends need the same answer from the same code: the pod
//! refuses to write an answer into a pty nobody is reading, and the frontend
//! refuses to hand one to a pane that asked for something else.

const std = @import("std");

/// The body of an OSC sequence: what sits between the introducer and the
/// terminator. Null when `data` does not begin with one.
///
/// Both introducers are accepted -- `ESC ]` and the single-byte C1 `0x9d` --
/// and both terminators, `ESC \` (ST) and `BEL`.
pub fn body(data: []const u8) ?[]const u8 {
    const start: usize = if (std.mem.startsWith(u8, data, "\x1b]"))
        2
    else if (data.len > 0 and data[0] == 0x9d)
        1
    else
        return null;
    const rest = data[start..];
    const end = std.mem.indexOfAny(u8, rest, "\x1b\x07") orelse rest.len;
    return rest[0..end];
}

/// Whether this OSC body addresses a colour: the palette, or fg/bg/cursor.
pub fn isColorBody(b: []const u8) bool {
    return std.mem.startsWith(u8, b, "10;") or
        std.mem.startsWith(u8, b, "11;") or
        std.mem.startsWith(u8, b, "12;") or
        std.mem.startsWith(u8, b, "4;");
}

/// Whether `data` is a terminal's colour ANSWER rather than a question or a set.
///
/// The value is the last `;` field and must begin `rgb:`: the form a terminal
/// replies in, and one no program sends.
pub fn isColorReply(data: []const u8) bool {
    const b = body(data) orelse return false;
    if (!isColorBody(b)) return false;
    const semi = std.mem.lastIndexOfScalar(u8, b, ';') orelse return false;
    return std.mem.startsWith(u8, b[semi + 1 ..], "rgb:");
}

/// Whether `data` carries a terminal colour answer's PAYLOAD anywhere in it.
///
/// `isColorReply` needs a whole sequence; past the event parser a reply can
/// arrive as a fragment with its `ESC ]` gone, and still reach a pane as text.
/// So this matches `rgb:` plus four hex digits and `/` -- the reply form and
/// only the reply form, since a set writes `#rrggbb` and a question writes `?`.
/// Typing cannot trip it: it arrives a character at a time, and a paste travels
/// as a paste event.
pub fn containsColorReplyPayload(data: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, data, i, "rgb:")) |at| {
        i = at + 4;
        const rest = data[i..];
        if (rest.len < 5) continue;
        var hex: usize = 0;
        while (hex < 4 and hex < rest.len and std.ascii.isHex(rest[hex])) hex += 1;
        if (hex == 4 and rest.len > 4 and rest[4] == '/') return true;
    }
    return false;
}

test "a reply payload is recognised without its introducer" {
    const t = std.testing;
    // What actually leaked: the frame is gone, the payload is not.
    try t.expect(containsColorReplyPayload("4;248;rgb:6e6e/ffff/5757"));
    try t.expect(containsColorReplyPayload("\x1b]4;198;rgb:6e6e/ffff/5757\x1b\\"));
    try t.expect(containsColorReplyPayload("rgb:2222/5050/1818"));
    // Buried in a larger chunk, which is how a split read delivers it.
    try t.expect(containsColorReplyPayload("junk\x1b]4;7;rgb:0000/1111/2222\x1b\\more"));

    // A set is still not an answer, however it arrives.
    try t.expect(!containsColorReplyPayload("\x1b]4;0;#0a120d\x1b\\"));
    try t.expect(!containsColorReplyPayload("4;0;#0a120d"));
    // Nor a question.
    try t.expect(!containsColorReplyPayload("4;198;?"));
    // Ordinary text that merely says rgb.
    try t.expect(!containsColorReplyPayload("see rgb: values"));
    try t.expect(!containsColorReplyPayload("rgb:12/34/56"));
    try t.expect(!containsColorReplyPayload("rgb:zzzz/0000/0000"));
    try t.expect(!containsColorReplyPayload(""));
}

test "an answer is told from a question and from a set" {
    const t = std.testing;
    // What a terminal sends back, which is the thing that must never be
    // routed to a pane that did not ask for it.
    try t.expect(isColorReply("\x1b]4;198;rgb:6e6e/ffff/5757\x1b\\"));
    try t.expect(isColorReply("\x1b]11;rgb:2222/5050/1818\x07"));
    try t.expect(isColorReply("\x1b]10;rgb:ffff/ffff/ffff\x1b\\"));
    // The C1 single-byte introducer is the same sequence.
    try t.expect(isColorReply("\x9d4;7;rgb:0000/0000/0000\x1b\\"));

    // A question is not an answer.
    try t.expect(!isColorReply("\x1b]4;198;?\x1b\\"));
    try t.expect(!isColorReply("\x1b]11;?\x1b\\"));

    // A SET is not an answer. This is what a pywal-style script sends, by the
    // hundred, and treating one as an answer would break recolouring outright.
    try t.expect(!isColorReply("\x1b]4;0;#0a120d\x1b\\"));
    try t.expect(!isColorReply("\x1b]11;#0a120d\x1b\\"));

    // Other OSC replies still have to reach the pane that asked, so they must
    // not look like colour answers.
    try t.expect(!isColorReply("\x1b]52;c;SGVsbG8=\x1b\\"));
    try t.expect(!isColorReply("\x1b]7;file:///home\x1b\\"));
    try t.expect(!isColorReply("\x1b]0;a title\x1b\\"));

    // Not an OSC at all.
    try t.expect(!isColorReply("plain text"));
    try t.expect(!isColorReply("\x1b[31m"));
    try t.expect(!isColorReply(""));
}

test "a colour index is not confused with another OSC code" {
    const t = std.testing;
    // `104` resets the palette and `110`/`111` reset fg/bg: all begin with the
    // digits of a colour code, and none carries an `rgb:` value.
    try t.expect(!isColorReply("\x1b]104\x1b\\"));
    try t.expect(!isColorReply("\x1b]110\x1b\\"));
    // A title that happens to contain `rgb:` is still a title: the code has to
    // be a colour code for the value to matter.
    try t.expect(!isColorReply("\x1b]2;rgb:dead/beef/0000\x1b\\"));
}
