const std = @import("std");

pub const max_title_len = 128;
pub const max_body_len = 512;
pub const max_id_len = 64;

pub const Notification = struct {
    title_buf: [max_title_len]u8 = undefined,
    title_len: u16 = 0,
    body_buf: [max_body_len]u8 = undefined,
    body_len: u16 = 0,

    pub fn title(self: *const Notification) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn body(self: *const Notification) []const u8 {
        return self.body_buf[0..self.body_len];
    }
};

pub const ProgressState = enum {
    inactive,
    in_progress,
    error_state,
    indeterminate,
    paused,
};

pub const Progress = struct {
    state: ProgressState = .inactive,
    percentage: ?u8 = null,
};

pub const QueryReply = struct {
    id_buf: [max_id_len]u8 = undefined,
    id_len: u8 = 0,

    pub fn id(self: *const QueryReply) []const u8 {
        return self.id_buf[0..self.id_len];
    }
};

pub const Action = union(enum) {
    ignore,
    notification: Notification,
    progress: Progress,
    kitty_query: QueryReply,
};

pub const Consumer = struct {
    kitty_active: bool = false,
    kitty_id_buf: [max_id_len]u8 = undefined,
    kitty_id_len: u8 = 0,
    kitty_title_buf: [max_title_len]u8 = undefined,
    kitty_title_len: u16 = 0,
    kitty_body_buf: [max_body_len]u8 = undefined,
    kitty_body_len: u16 = 0,
    last_kitty_hash: ?u64 = null,
    last_kitty_ms: i64 = 0,

    pub fn reset(self: *Consumer) void {
        self.* = .{};
    }

    pub fn consume(self: *Consumer, seq: []const u8, now_ms: i64) Action {
        const payload = oscPayload(seq) orelse return .ignore;
        const code_end = std.mem.indexOfScalar(u8, payload, ';') orelse return .ignore;
        const code = std.fmt.parseUnsigned(u32, payload[0..code_end], 10) catch return .ignore;
        const fields = payload[code_end + 1 ..];

        return switch (code) {
            9 => self.consumeOsc9(fields, now_ms),
            99 => self.consumeOsc99(fields, now_ms),
            777 => self.consumeOsc777(fields, now_ms),
            else => .ignore,
        };
    }

    fn consumeOsc9(self: *Consumer, fields: []const u8, now_ms: i64) Action {
        if (std.mem.startsWith(u8, fields, "4;")) {
            return .{ .progress = parseProgress(fields[2..]) orelse return .ignore };
        }

        var notification: Notification = .{};
        notification.body_len = @intCast(sanitizeAppend(&notification.body_buf, 0, fields));
        if (notification.body_len == 0) return .ignore;
        return self.legacyNotification(notification, now_ms);
    }

    fn consumeOsc777(self: *Consumer, fields: []const u8, now_ms: i64) Action {
        if (!std.mem.startsWith(u8, fields, "notify;")) return .ignore;
        const content = fields["notify;".len..];

        var notification: Notification = .{};
        if (std.mem.indexOfScalar(u8, content, ';')) |separator| {
            notification.title_len = @intCast(sanitizeAppend(&notification.title_buf, 0, content[0..separator]));
            notification.body_len = @intCast(sanitizeAppend(&notification.body_buf, 0, content[separator + 1 ..]));
        } else {
            notification.body_len = @intCast(sanitizeAppend(&notification.body_buf, 0, content));
        }
        if (notification.title_len == 0 and notification.body_len == 0) return .ignore;
        return self.legacyNotification(notification, now_ms);
    }

    fn legacyNotification(self: *Consumer, notification: Notification, now_ms: i64) Action {
        const hash = notificationHash(&notification);
        if (self.last_kitty_hash != null and self.last_kitty_hash.? == hash and now_ms - self.last_kitty_ms <= 1000) {
            self.last_kitty_hash = null;
            return .ignore;
        }
        self.last_kitty_hash = null;
        return .{ .notification = notification };
    }

    fn consumeOsc99(self: *Consumer, fields: []const u8, now_ms: i64) Action {
        const separator = std.mem.indexOfScalar(u8, fields, ';') orelse return .ignore;
        const metadata = fields[0..separator];
        const payload = fields[separator + 1 ..];
        const meta = parseKittyMetadata(metadata) orelse return .ignore;

        if (meta.payload == .query) {
            var reply: QueryReply = .{};
            reply.id_len = @intCast(copyIdentifier(&reply.id_buf, meta.id));
            return .{ .kitty_query = reply };
        }
        if (meta.payload != .title and meta.payload != .body) return .ignore;

        if (!self.kitty_active or !std.mem.eql(u8, self.kitty_id_buf[0..self.kitty_id_len], meta.id)) {
            self.kitty_active = true;
            self.kitty_id_len = @intCast(copyIdentifier(&self.kitty_id_buf, meta.id));
            self.kitty_title_len = 0;
            self.kitty_body_len = 0;
        }

        var decoded_buf: [4096]u8 = undefined;
        const text = if (meta.encoded) blk: {
            const decoder = std.base64.standard.Decoder;
            const decoded_len = decoder.calcSizeForSlice(payload) catch return .ignore;
            if (decoded_len > decoded_buf.len) return .ignore;
            decoder.decode(decoded_buf[0..decoded_len], payload) catch return .ignore;
            break :blk decoded_buf[0..decoded_len];
        } else payload;

        switch (meta.payload) {
            .title => self.kitty_title_len = @intCast(sanitizeAppend(&self.kitty_title_buf, self.kitty_title_len, text)),
            .body => self.kitty_body_len = @intCast(sanitizeAppend(&self.kitty_body_buf, self.kitty_body_len, text)),
            else => unreachable,
        }
        if (!meta.done) return .ignore;

        var notification: Notification = .{};
        notification.title_len = self.kitty_title_len;
        notification.body_len = self.kitty_body_len;
        @memcpy(notification.title_buf[0..notification.title_len], self.kitty_title_buf[0..notification.title_len]);
        @memcpy(notification.body_buf[0..notification.body_len], self.kitty_body_buf[0..notification.body_len]);
        self.kitty_active = false;
        self.kitty_title_len = 0;
        self.kitty_body_len = 0;

        if (notification.title_len == 0 and notification.body_len == 0) return .ignore;
        self.last_kitty_hash = notificationHash(&notification);
        self.last_kitty_ms = now_ms;
        return .{ .notification = notification };
    }
};

const KittyPayload = enum { title, body, close, query, unsupported };

const KittyMetadata = struct {
    id: []const u8 = "",
    payload: KittyPayload = .title,
    done: bool = true,
    encoded: bool = false,
};

fn parseKittyMetadata(metadata: []const u8) ?KittyMetadata {
    var result: KittyMetadata = .{};
    var parts = std.mem.splitScalar(u8, metadata, ':');
    while (parts.next()) |part| {
        if (part.len < 3 or part[1] != '=') continue;
        const value = part[2..];
        switch (part[0]) {
            'i' => {
                if (!validIdentifier(value)) return null;
                result.id = value;
            },
            'p' => result.payload = if (std.mem.eql(u8, value, "title"))
                .title
            else if (std.mem.eql(u8, value, "body"))
                .body
            else if (std.mem.eql(u8, value, "close"))
                .close
            else if (std.mem.eql(u8, value, "?"))
                .query
            else
                .unsupported,
            'd' => result.done = !std.mem.eql(u8, value, "0"),
            'e' => result.encoded = std.mem.eql(u8, value, "1"),
            else => {},
        }
    }
    return result;
}

fn validIdentifier(value: []const u8) bool {
    if (value.len > max_id_len) return false;
    for (value) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '+' and c != '.') return false;
    }
    return true;
}

fn copyIdentifier(buffer: []u8, value: []const u8) usize {
    const len = @min(buffer.len, value.len);
    @memcpy(buffer[0..len], value[0..len]);
    return len;
}

fn parseProgress(fields: []const u8) ?Progress {
    if (fields.len == 0) return null;
    const separator = std.mem.indexOfScalar(u8, fields, ';');
    const state_field = if (separator) |index| fields[0..index] else fields;
    if (state_field.len != 1) return null;

    var result: Progress = .{ .state = switch (state_field[0]) {
        '0' => .inactive,
        '1' => .in_progress,
        '2' => .error_state,
        '3' => .indeterminate,
        '4' => .paused,
        else => return null,
    } };
    if (separator) |index| {
        if (index + 1 < fields.len) {
            const parsed = std.fmt.parseUnsigned(u16, fields[index + 1 ..], 10) catch return null;
            result.percentage = @intCast(@min(parsed, 100));
        }
    }
    if (result.state == .inactive or result.state == .indeterminate) result.percentage = null;
    return result;
}

fn oscPayload(seq: []const u8) ?[]const u8 {
    var start: usize = 0;
    if (std.mem.startsWith(u8, seq, "\x1b]")) {
        start = 2;
    } else if (seq.len > 0 and seq[0] == 0x9d) {
        start = 1;
    } else {
        return null;
    }

    var end = seq.len;
    if (end > start and (seq[end - 1] == 0x07 or seq[end - 1] == 0x9c)) {
        end -= 1;
    } else if (end >= start + 2 and seq[end - 2] == 0x1b and seq[end - 1] == '\\') {
        end -= 2;
    } else {
        return null;
    }
    return seq[start..end];
}

fn sanitizeAppend(buffer: []u8, offset: usize, input: []const u8) usize {
    var write_index = @min(offset, buffer.len);
    var read_index: usize = 0;
    while (read_index < input.len and write_index < buffer.len) {
        const first = input[read_index];
        if (first < 0x20 or first == 0x7f) {
            read_index += 1;
            continue;
        }
        if (first < 0x80) {
            buffer[write_index] = first;
            write_index += 1;
            read_index += 1;
            continue;
        }

        const sequence_len = std.unicode.utf8ByteSequenceLength(first) catch {
            read_index += 1;
            continue;
        };
        if (read_index + sequence_len > input.len) break;
        const bytes = input[read_index .. read_index + sequence_len];
        const codepoint = std.unicode.utf8Decode(bytes) catch {
            read_index += 1;
            continue;
        };
        if (codepoint >= 0x80 and codepoint <= 0x9f) {
            read_index += sequence_len;
            continue;
        }
        if (write_index + sequence_len > buffer.len) break;
        @memcpy(buffer[write_index .. write_index + sequence_len], bytes);
        write_index += sequence_len;
        read_index += sequence_len;
    }
    return write_index;
}

fn notificationHash(notification: *const Notification) u64 {
    var hash = std.hash.Wyhash.init(0);
    if (notification.body_len == 0) {
        hash.update(notification.title());
    } else if (notification.title_len == 0) {
        hash.update(notification.body());
    } else {
        hash.update(notification.title());
        hash.update("\x00");
        hash.update(notification.body());
    }
    return hash.final();
}

test "OSC 777 sanitizes, caps, and accepts missing title" {
    var consumer: Consumer = .{};
    const titled = consumer.consume("\x1b]777;notify;Build;done\x07", 10);
    try std.testing.expect(titled == .notification);
    try std.testing.expectEqualStrings("Build", titled.notification.title());
    try std.testing.expectEqualStrings("done", titled.notification.body());

    const body_only = consumer.consume("\x1b]777;notify;line\x1b\\", 20);
    try std.testing.expect(body_only == .notification);
    try std.testing.expectEqualStrings("", body_only.notification.title());
    try std.testing.expectEqualStrings("line", body_only.notification.body());

    var oversized: [max_body_len + 32]u8 = undefined;
    @memset(&oversized, 'x');
    oversized[3] = 0x01;
    var seq: [max_body_len + 64]u8 = undefined;
    const framed = try std.fmt.bufPrint(&seq, "\x1b]777;notify;;{s}\x1b\\", .{oversized[0..]});
    const capped = consumer.consume(framed, 30);
    try std.testing.expect(capped == .notification);
    try std.testing.expectEqual(max_body_len, capped.notification.body().len);
    try std.testing.expect(std.mem.indexOfScalar(u8, capped.notification.body(), 0x01) == null);
}

test "OSC 9 progress maps states and clears" {
    var consumer: Consumer = .{};
    const running = consumer.consume("\x1b]9;4;1;42\x07", 10);
    try std.testing.expectEqual(ProgressState.in_progress, running.progress.state);
    try std.testing.expectEqual(@as(?u8, 42), running.progress.percentage);

    const error_state = consumer.consume("\x1b]9;4;2;120\x07", 20);
    try std.testing.expectEqual(ProgressState.error_state, error_state.progress.state);
    try std.testing.expectEqual(@as(?u8, 100), error_state.progress.percentage);

    const cleared = consumer.consume("\x1b]9;4;0\x07", 30);
    try std.testing.expectEqual(ProgressState.inactive, cleared.progress.state);
    try std.testing.expectEqual(@as(?u8, null), cleared.progress.percentage);
}

test "OSC 99 assembles chunks and suppresses matching legacy fallback" {
    var consumer: Consumer = .{};
    try std.testing.expect(consumer.consume("\x1b]99;i=build:p=title:d=0;Build\x1b\\", 100) == .ignore);
    const kitty = consumer.consume("\x1b]99;i=build:p=body;done\x1b\\", 110);
    try std.testing.expect(kitty == .notification);
    try std.testing.expectEqualStrings("Build", kitty.notification.title());
    try std.testing.expectEqualStrings("done", kitty.notification.body());

    try std.testing.expect(consumer.consume("\x1b]777;notify;Build;done\x07", 120) == .ignore);
    try std.testing.expect(consumer.consume("\x1b]777;notify;Build;done\x07", 130) == .notification);
}

test "OSC 99 decodes base64 and parses capability query" {
    var consumer: Consumer = .{};
    const encoded = consumer.consume("\x1b]99;i=x:p=body:e=1;SGVsbG8=\x1b\\", 10);
    try std.testing.expect(encoded == .notification);
    try std.testing.expectEqualStrings("Hello", encoded.notification.body());

    const query = consumer.consume("\x1b]99;i=probe:p=?;\x1b\\", 20);
    try std.testing.expect(query == .kitty_query);
    try std.testing.expectEqualStrings("probe", query.kitty_query.id());
}
