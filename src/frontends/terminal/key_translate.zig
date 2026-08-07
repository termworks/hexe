const std = @import("std");
const ghostty = @import("ghostty-vt");
const core = @import("core");
const log = std.log.scoped(.terminal_key_translate);

const BindKey = core.Config.BindKey;
const BindKeyKind = core.Config.BindKeyKind;

pub fn encodeKey(
    out: *[64]u8,
    mods: u8,
    key: BindKey,
    text_codepoint: ?u21,
    terminal: *const ghostty.Terminal,
) ?[]const u8 {
    var utf8_buf: [4]u8 = undefined;
    const utf8 = keyUtf8(key, text_codepoint, &utf8_buf);

    const shift = (mods & 4) != 0;

    const event: ghostty.input.KeyEvent = .{
        .key = bindKeyToGhosttyKey(key),
        .utf8 = utf8,
        .unshifted_codepoint = bindKeyCodepoint(key),
        .mods = .{
            .alt = (mods & 1) != 0,
            .ctrl = (mods & 2) != 0,
            .shift = shift,
            .super = (mods & 8) != 0,
        },
        // Shift is spent producing the character itself: `2` gives `@`, `a`
        // gives `A`. The encoder subtracts consumed mods before deciding
        // whether a key still counts as unmodified text, and only unmodified
        // text is sent as-is under the Kitty protocol. Leaving this empty made
        // every shifted character encode as a CSI-u sequence instead — so with
        // a pane in Kitty mode, no symbol or capital reached the application.
        .consumed_mods = .{ .shift = shift and utf8.len > 0 },
    };

    var writer = std.Io.Writer.fixed(out);
    var opts = ghostty.input.KeyEncodeOptions.fromTerminal(terminal);
    opts.macos_option_as_alt = .false;
    ghostty.input.encodeKey(&writer, event, opts) catch |err| {
        log.debug("failed to encode key event: {}", .{err});
        return null;
    };
    return writer.buffered();
}

fn bindKeyCodepoint(key: BindKey) u21 {
    return switch (@as(BindKeyKind, key)) {
        .space => ' ',
        .char => key.char,
        else => 0,
    };
}

fn keyUtf8(key: BindKey, text_codepoint: ?u21, out: *[4]u8) []const u8 {
    if (text_codepoint) |cp| {
        if (cp == 0) return "";
        const n = std.unicode.utf8Encode(cp, out) catch |err| {
            log.debug("failed to encode key text codepoint {d}: {}", .{ cp, err });
            return "";
        };
        return out[0..n];
    }

    return switch (@as(BindKeyKind, key)) {
        .space => " ",
        .char => blk: {
            out[0] = key.char;
            break :blk out[0..1];
        },
        else => "",
    };
}

fn bindKeyToGhosttyKey(key: BindKey) ghostty.input.Key {
    return switch (@as(BindKeyKind, key)) {
        .up => .arrow_up,
        .down => .arrow_down,
        .left => .arrow_left,
        .right => .arrow_right,
        .space => .space,
        .char => charToGhosttyKey(key.char),
    };
}

fn charToGhosttyKey(ch: u8) ghostty.input.Key {
    const c = std.ascii.toLower(ch);
    return switch (c) {
        'a' => .key_a,
        'b' => .key_b,
        'c' => .key_c,
        'd' => .key_d,
        'e' => .key_e,
        'f' => .key_f,
        'g' => .key_g,
        'h' => .key_h,
        'i' => .key_i,
        'j' => .key_j,
        'k' => .key_k,
        'l' => .key_l,
        'm' => .key_m,
        'n' => .key_n,
        'o' => .key_o,
        'p' => .key_p,
        'q' => .key_q,
        'r' => .key_r,
        's' => .key_s,
        't' => .key_t,
        'u' => .key_u,
        'v' => .key_v,
        'w' => .key_w,
        'x' => .key_x,
        'y' => .key_y,
        'z' => .key_z,
        '0' => .digit_0,
        '1' => .digit_1,
        '2' => .digit_2,
        '3' => .digit_3,
        '4' => .digit_4,
        '5' => .digit_5,
        '6' => .digit_6,
        '7' => .digit_7,
        '8' => .digit_8,
        '9' => .digit_9,
        '-' => .minus,
        '=' => .equal,
        '[' => .bracket_left,
        ']' => .bracket_right,
        '\\' => .backslash,
        ';' => .semicolon,
        '\'' => .quote,
        '`' => .backquote,
        ',' => .comma,
        '.' => .period,
        '/' => .slash,
        '\t' => .tab,
        '\r', '\n' => .enter,
        0x7f, 0x08 => .backspace,
        0x1b => .escape,
        else => .unidentified,
    };
}
