const std = @import("std");
const core = @import("core");
const log = std.log.scoped(.terminal_fast_path);

const BindKey = core.Config.BindKey;
const BindKeyKind = core.Config.BindKeyKind;

/// Encodes text and control keys directly when Kitty keyboard mode is inactive.
pub fn fastPathBytes(out: []u8, mods: u8, key: BindKey, text_codepoint: ?u21, kitty_flags: u8) ?usize {
    if (kitty_flags != 0) return null;

    // Ctrl+letter canonicalization.
    if (mods == 2 and @as(BindKeyKind, key) == .char) {
        const ch = key.char;
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')) {
            if (out.len < 1) return null;
            const lc = std.ascii.toLower(ch);
            out[0] = (lc - 'a') + 1;
            return 1;
        }
    }

    const key_kind = @as(BindKeyKind, key);
    if (key_kind != .char and key_kind != .space) return null;
    const cp = text_codepoint orelse return null;
    if ((mods & 2) != 0 or (mods & 8) != 0) return null; // Ctrl/Super → encoder

    var n: usize = 0;
    if ((mods & 1) != 0) {
        if (n >= out.len) return null;
        out[n] = 0x1b;
        n += 1;
    }
    const written = std.unicode.utf8Encode(cp, out[n..]) catch |err| {
        log.debug("failed to encode fast-path key codepoint {d}: {}", .{ cp, err });
        return null;
    };
    n += written;
    return if (n > 0) n else null;
}
