const vaxis = @import("vaxis");

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
