const std = @import("std");
const vaxis = @import("vaxis");

/// Display columns `text` occupies, counting graphemes rather than bytes.
pub fn displayWidth(text: []const u8) u16 {
    var used: u16 = 0;
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |g| {
        used +|= @intCast(vaxis.gwidth.gwidth(g.bytes(text), .unicode));
    }
    return used;
}

pub fn clipTextToWidth(text: []const u8, max_width: u16) []const u8 {
    if (text.len == 0 or max_width == 0) return "";

    var used: u16 = 0;
    var end: usize = 0;
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |g| {
        const bytes = g.bytes(text);
        const w = vaxis.gwidth.gwidth(bytes, .unicode);
        if (w == 0) {
            end = g.start + g.len;
            continue;
        }
        if (used + w > max_width) break;
        used += w;
        end = g.start + g.len;
    }
    return text[0..end];
}

/// Strip escape sequences and control characters from untrusted display text.
/// Used for float titles and for runs an external painter sends, neither of
/// which may emit terminal control bytes into the frame.
pub fn sanitizeLabelUtf8(raw: []const u8, out: []u8) []const u8 {
    var wi: usize = 0;
    var i: usize = 0;
    while (i < raw.len and wi < out.len) {
        const b = raw[i];

        // Strip ANSI/VT escape sequences so terminal control bytes never
        // leak into float titles.
        if (b == 0x1b) {
            i += 1;
            if (i >= raw.len) break;
            const esc = raw[i];

            // CSI: ESC [ ... final
            if (esc == '[') {
                i += 1;
                while (i < raw.len) : (i += 1) {
                    const c = raw[i];
                    if (c >= 0x40 and c <= 0x7e) {
                        i += 1;
                        break;
                    }
                }
                continue;
            }

            // OSC: ESC ] ... BEL or ST (ESC \\)
            if (esc == ']') {
                i += 1;
                while (i < raw.len) {
                    const c = raw[i];
                    if (c == 0x07) {
                        i += 1;
                        break;
                    }
                    if (c == 0x1b and i + 1 < raw.len and raw[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
                continue;
            }

            // DCS/PM/APC: ESC P/^/_ ... ST (ESC \\)
            if (esc == 'P' or esc == '^' or esc == '_') {
                i += 1;
                while (i < raw.len) {
                    if (raw[i] == 0x1b and i + 1 < raw.len and raw[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
                continue;
            }

            // Other escape forms are 2-byte sequences.
            i += 1;
            continue;
        }

        // C1 controls (including 0x9B CSI) are never valid label content.
        if (b >= 0x80 and b <= 0x9f) {
            i += 1;
            continue;
        }

        const len = std.unicode.utf8ByteSequenceLength(b) catch 1;
        const end = @min(i + len, raw.len);
        const chunk = raw[i..end];
        const cp = std.unicode.utf8Decode(chunk) catch {
            i = end;
            continue;
        };

        // Skip control characters.
        if (cp < 32 or cp == 127) {
            i = end;
            continue;
        }

        if (wi + chunk.len > out.len) break;
        @memcpy(out[wi .. wi + chunk.len], chunk);
        wi += chunk.len;
        i = end;
    }
    return out[0..wi];
}
