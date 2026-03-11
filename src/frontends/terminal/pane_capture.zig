const std = @import("std");

pub fn captureOutput(self: anytype, allocator: std.mem.Allocator) ![]u8 {
    if (self.capture_output and self.captured_output.items.len > 0) {
        return try extractLastLineFromOutput(allocator, self.captured_output.items);
    }

    const state = try self.getRenderState();
    const row_slice = state.row_data.slice();
    if (row_slice.len == 0 or state.cols == 0) {
        return allocator.dupe(u8, "");
    }

    const row_cells = row_slice.items(.cells);
    const rows = @min(@as(usize, state.rows), row_slice.len);

    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(allocator);

    var ri: usize = rows;
    while (ri > 0) {
        ri -= 1;
        line_buf.clearRetainingCapacity();

        const cells_slice = row_cells[ri].slice();
        const raw_cells = cells_slice.items(.raw);
        const cols = @min(@as(usize, state.cols), raw_cells.len);

        for (0..cols) |ci| {
            const raw = raw_cells[ci];
            if (raw.wide == .spacer_tail) continue;

            var codepoint = raw.codepoint();
            if (codepoint == 0 or codepoint < 32 or codepoint == 127) {
                codepoint = ' ';
            }

            var utf8_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch {
                line_buf.append(allocator, ' ') catch {};
                continue;
            };
            line_buf.appendSlice(allocator, utf8_buf[0..len]) catch {};
        }

        const trimmed = std.mem.trimRight(u8, line_buf.items, " ");
        if (trimmed.len > 0) {
            return allocator.dupe(u8, trimmed);
        }
    }

    return allocator.dupe(u8, "");
}

pub fn appendCapturedOutput(self: anytype, data: []const u8) void {
    const MAX_CAPTURED_OUTPUT: usize = 1024 * 1024;
    if (data.len >= MAX_CAPTURED_OUTPUT) {
        self.captured_output.clearRetainingCapacity();
        const start = data.len - MAX_CAPTURED_OUTPUT;
        self.captured_output.appendSlice(self.allocator, data[start..]) catch {};
        return;
    }

    if (self.captured_output.items.len + data.len > MAX_CAPTURED_OUTPUT) {
        self.captured_output.clearRetainingCapacity();
    }

    self.captured_output.appendSlice(self.allocator, data) catch {};
}

fn extractLastLineFromOutput(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(allocator);
    var clean_all: std.ArrayList(u8) = .empty;
    defer clean_all.deinit(allocator);

    var in_alt_screen = false;
    var i: usize = 0;
    while (i < data.len) {
        const b = data[i];
        if (b == 0x1b) {
            if (i + 1 < data.len and data[i + 1] == '[') {
                i += 2;
                const start = i;
                while (i < data.len) : (i += 1) {
                    const c = data[i];
                    if (c >= 0x40 and c <= 0x7e) {
                        handleAltScreenCsi(c, data[start..i], &in_alt_screen);
                        i += 1;
                        break;
                    }
                }
                continue;
            }
            if (i + 1 < data.len and data[i + 1] == ']') {
                i += 2;
                while (i < data.len) : (i += 1) {
                    if (data[i] == 0x07) {
                        i += 1;
                        break;
                    }
                    if (data[i] == 0x1b and i + 1 < data.len and data[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
                continue;
            }
            if (i + 1 < data.len and data[i + 1] == 'P') {
                i += 2;
                while (i < data.len) : (i += 1) {
                    if (data[i] == 0x1b and i + 1 < data.len and data[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
                continue;
            }
            if (i + 1 < data.len and (data[i + 1] == 'G' or data[i + 1] == '^' or data[i + 1] == '_')) {
                i += 2;
                while (i < data.len) : (i += 1) {
                    if (data[i] == 0x1b and i + 1 < data.len and data[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
                continue;
            }
            i += 1;
            continue;
        }

        if (b == '\r') {
            if (!in_alt_screen) {
                try clean.append(allocator, '\n');
            }
            try clean_all.append(allocator, '\n');
            i += 1;
            continue;
        }

        if (b == '\n' or b == '\t' or b >= 0x20) {
            if (!in_alt_screen) {
                try clean.append(allocator, b);
            }
            try clean_all.append(allocator, b);
        }
        i += 1;
    }

    if (lastNonEmptyLine(clean.items)) |line| {
        return allocator.dupe(u8, line);
    }
    if (extractLastPathToken(allocator, clean_all.items)) |path| {
        return path;
    }
    if (lastMatchingLine(clean_all.items, isLikelySelectionLine)) |line| {
        return allocator.dupe(u8, line);
    }
    return allocator.dupe(u8, "");
}

fn lastNonEmptyLine(buf: []const u8) ?[]const u8 {
    return lastMatchingLine(buf, isNonEmptyLine);
}

fn lastMatchingLine(buf: []const u8, predicate: *const fn ([]const u8) bool) ?[]const u8 {
    var it = std.mem.splitScalar(u8, buf, '\n');
    var last: []const u8 = "";
    while (it.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, " ");
        if (predicate(trimmed)) last = trimmed;
    }
    if (last.len == 0) return null;
    return last;
}

fn isNonEmptyLine(line: []const u8) bool {
    return line.len > 0;
}

fn isLikelySelectionLine(line: []const u8) bool {
    if (line.len == 0 or line.len > 512) return false;
    for (line) |ch| {
        if (ch < 0x20 or ch == 0x7f) return false;
        if (ch >= 0x80) return false;
    }
    return true;
}

fn extractLastPathToken(allocator: std.mem.Allocator, buf: []const u8) ?[]u8 {
    var it = std.mem.tokenizeAny(u8, buf, " \n\r\t");
    var last: []const u8 = "";
    while (it.next()) |tok| {
        const normalized = normalizePathToken(tok);
        if (normalized.len == 0) continue;
        if (isLikelyPathToken(normalized)) {
            last = normalized;
        }
    }
    if (last.len == 0) return null;
    return allocator.dupe(u8, last) catch null;
}

fn normalizePathToken(token: []const u8) []const u8 {
    if (token.len == 0) return token;
    var start: usize = 0;
    var end: usize = token.len;
    while (end > start and (token[end - 1] == '%' or token[end - 1] == '>' or token[end - 1] == '$' or token[end - 1] == '#')) {
        end -= 1;
    }
    var slash_idx: ?usize = null;
    for (start..end) |i| {
        if (token[i] == '/') {
            slash_idx = i;
            break;
        }
    }
    if (slash_idx) |idx| {
        var all_digits = idx > start;
        for (start..idx) |i| {
            if (token[i] < '0' or token[i] > '9') {
                all_digits = false;
                break;
            }
        }
        if (all_digits) {
            start = idx;
        }
    }
    return if (start < end) token[start..end] else token[0..0];
}

fn isLikelyPathToken(token: []const u8) bool {
    if (token.len == 0 or token.len > 512) return false;
    for (token) |ch| {
        if (ch < 0x20 or ch == 0x7f or ch >= 0x80) return false;
    }
    if (token[0] == '/' or token[0] == '.') return true;
    return std.mem.indexOfScalar(u8, token, '/') != null;
}

fn handleAltScreenCsi(final: u8, params: []const u8, in_alt_screen: *bool) void {
    if (final != 'h' and final != 'l') return;

    var it = std.mem.splitScalar(u8, params, ';');
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (tok[0] != '?') continue;
        const value = std.fmt.parseInt(u16, tok[1..], 10) catch continue;
        if (value == 1049 or value == 47 or value == 1047) {
            in_alt_screen.* = (final == 'h');
        }
    }
}
