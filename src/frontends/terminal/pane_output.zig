const std = @import("std");
const core = @import("core");

const pane_mod = @import("pane.zig");
const Pane = pane_mod.Pane;
const pane_respond = @import("pane_respond.zig");

fn writeResponse(self: *Pane, data: []const u8, comptime context: []const u8) void {
    self.write(data) catch |err| {
        core.logging.logError("terminal", context, err);
    };
}

fn processVtOutput(self: *Pane, data: []const u8) void {
    if (canSkipControlScanners(self, data)) {
        updateEscTail(self, data);
        return;
    }

    handleCsiQueries(self, data);
    handleDcsQueries(self, data);

    if (containsClearSeq(self.esc_tail[0..self.esc_tail_len], data)) {
        self.did_clear = true;
    }

    updateEscTail(self, data);
}

fn feedVtOutput(self: *Pane, data: []const u8) void {
    var offset: usize = 0;
    while (offset < data.len) {
        const remaining = data[offset..];
        const segment_len = nextResponseBoundary(self, remaining) orelse remaining.len;
        const segment = remaining[0..segment_len];
        self.vt.feed(segment) catch |err| {
            core.logging.logError("terminal", "pane VT feed failed", err);
            return;
        };
        processVtOutput(self, segment);
        offset += segment_len;
    }
}

/// Split `data` into OSC sequences and everything else, feeding the rest to the
/// VT in order.
///
/// The C1 form of OSC (a bare 0x9d) is deliberately NOT recognised here. 0x9d is
/// also a UTF-8 continuation byte: it is the second byte of U+276F `❯`, and of
/// every codepoint in U+2740..U+277F. Treating it as an introducer swallows the
/// rest of the stream into an OSC that never terminates — a shell prompt or TUI
/// using `❯` loses everything printed after it. C1 controls are unreachable in a
/// UTF-8 stream, which is why the VT parser does not honour them either.
pub fn feedOutput(self: *Pane, data: []const u8) void {
    const ESC: u8 = 0x1b;

    var plain_start: usize = 0;
    var i: usize = 0;
    while (i < data.len) {
        const b = data[i];

        if (self.osc_in_progress) {
            appendOscByte(self, b);
            i += 1;
            plain_start = i;
            continue;
        }

        if (self.osc_pending_esc) {
            self.osc_pending_esc = false;
            if (b == ']') {
                beginOsc(self, false);
                i += 1;
                plain_start = i;
                continue;
            }
            feedVtOutput(self, "\x1b");
            plain_start = i;
            continue;
        }

        if (b == ESC) {
            feedVtOutput(self, data[plain_start..i]);
            self.osc_pending_esc = true;
            i += 1;
            plain_start = i;
            continue;
        }

        i += 1;
    }

    if (!self.osc_in_progress and !self.osc_pending_esc) {
        feedVtOutput(self, data[plain_start..]);
    }
}

pub fn nextResponseBoundary(self: *const Pane, data: []const u8) ?usize {
    var csi_state = self.csi_query_state;
    var dcs_state = self.dcs_query_state;

    for (data, 0..) |byte, index| {
        switch (csi_state) {
            .idle => if (byte == 0x1b) {
                csi_state = .esc;
            },
            .esc => csi_state = if (byte == '[') .csi else .idle,
            .csi => if (byte >= 0x40 and byte <= 0x7e) {
                csi_state = .idle;
                if (std.mem.indexOfScalar(u8, "cnpqu", byte) != null) return index + 1;
            },
        }

        switch (dcs_state) {
            .idle => if (byte == 0x1b) {
                dcs_state = .esc;
            },
            .esc => dcs_state = if (byte == 'P') .dcs else .idle,
            .dcs => if (byte == 0x1b) {
                dcs_state = .dcs_esc;
            },
            .dcs_esc => {
                if (byte == '\\') return index + 1;
                dcs_state = .dcs;
            },
        }
    }
    return null;
}

fn canSkipControlScanners(self: *const Pane, data: []const u8) bool {
    if (data.len == 0) return true;
    if (self.csi_query_state != .idle) return false;
    if (self.dcs_query_state != .idle) return false;
    if (self.osc_in_progress or self.osc_pending_esc or self.osc_prev_esc) return false;
    if (std.mem.indexOfScalar(u8, self.esc_tail[0..self.esc_tail_len], 0x1b) != null) return false;

    return std.mem.indexOfAny(u8, data, &.{ 0x1b, 0x0c }) == null;
}

fn updateEscTail(self: *Pane, data: []const u8) void {
    const take: usize = @min(@as(usize, 3), data.len);
    if (take == 0) return;
    @memcpy(self.esc_tail[0..take], data[data.len - take .. data.len]);
    self.esc_tail_len = @intCast(take);
}

fn handleCsiQueries(self: *Pane, data: []const u8) void {
    scanCsi(self, data, self, handleCsiQueryFinal);
}

fn scanCsi(scanner: anytype, data: []const u8, context: anytype, comptime on_final: anytype) void {
    const ESC: u8 = 0x1b;

    for (data) |b| {
        switch (scanner.csi_query_state) {
            .idle => {
                if (b == ESC) scanner.csi_query_state = .esc;
            },
            .esc => {
                if (b == '[') {
                    scanner.csi_query_state = .csi;
                    scanner.csi_query_len = 0;
                } else {
                    scanner.csi_query_state = .idle;
                }
            },
            .csi => {
                if (b >= 0x40 and b <= 0x7e) {
                    on_final(context, b, scanner.csi_query_buf[0..scanner.csi_query_len]);
                    scanner.csi_query_state = .idle;
                    scanner.csi_query_len = 0;
                } else if (scanner.csi_query_len < scanner.csi_query_buf.len) {
                    scanner.csi_query_buf[scanner.csi_query_len] = b;
                    scanner.csi_query_len += 1;
                } else {
                    scanner.csi_query_state = .idle;
                    scanner.csi_query_len = 0;
                }
            },
        }
    }
}

fn handleCsiQueryFinal(self: *Pane, final: u8, params: []const u8) void {
    var reply_buf: [128]u8 = undefined;
    switch (pane_respond.csiDisposition(&self.vt, final, params, &reply_buf)) {
        .ignore => return,
        .reply => |reply| {
            writeResponse(self, reply, "local CSI response write failed");
            return;
        },
        .forward_to_host => {},
    }

    var seq_buf: [80]u8 = undefined;
    var n: usize = 0;
    seq_buf[n] = 0x1b;
    n += 1;
    seq_buf[n] = '[';
    n += 1;
    if (params.len > 0) {
        @memcpy(seq_buf[n .. n + params.len], params);
        n += params.len;
    }
    seq_buf[n] = final;
    n += 1;

    self.csi_expected_responses +|= 1;
    const stdout = std.fs.File.stdout();
    stdout.writeAll(seq_buf[0..n]) catch |err| {
        core.logging.logError("terminal", "forward CSI query to terminal stdout", err);
    };
}

fn handleDcsQueries(self: *Pane, data: []const u8) void {
    const ESC: u8 = 0x1b;

    for (data) |b| {
        switch (self.dcs_query_state) {
            .idle => {
                if (b == ESC) self.dcs_query_state = .esc;
            },
            .esc => {
                if (b == 'P') {
                    self.dcs_query_state = .dcs;
                    self.dcs_query_len = 0;
                } else {
                    self.dcs_query_state = .idle;
                }
            },
            .dcs => {
                if (b == ESC) {
                    self.dcs_query_state = .dcs_esc;
                } else if (self.dcs_query_len < self.dcs_query_buf.len) {
                    self.dcs_query_buf[self.dcs_query_len] = b;
                    self.dcs_query_len += 1;
                } else {
                    self.dcs_query_state = .idle;
                    self.dcs_query_len = 0;
                }
            },
            .dcs_esc => {
                if (b == '\\') {
                    handleDcsQuery(self, self.dcs_query_buf[0..self.dcs_query_len]);
                    self.dcs_query_state = .idle;
                    self.dcs_query_len = 0;
                } else if (self.dcs_query_len + 2 <= self.dcs_query_buf.len) {
                    self.dcs_query_buf[self.dcs_query_len] = ESC;
                    self.dcs_query_len += 1;
                    self.dcs_query_buf[self.dcs_query_len] = b;
                    self.dcs_query_len += 1;
                    self.dcs_query_state = .dcs;
                } else {
                    self.dcs_query_state = .idle;
                    self.dcs_query_len = 0;
                }
            },
        }
    }
}

fn handleDcsQuery(self: *Pane, payload: []const u8) void {
    // DECRQSS: DCS $ q <request> ST
    if (!std.mem.startsWith(u8, payload, "$q")) return;
    const req = std.mem.trim(u8, payload[2..], " ");

    // SGR request
    if (std.mem.eql(u8, req, "m")) {
        writeResponse(self, "\x1bP1$r 0m\x1b\\", "DCS SGR response write failed");
        return;
    }

    // DECSCUSR request (SP q)
    if (std.mem.eql(u8, req, "q")) {
        const style = self.vt.getCursorStyle();
        var buf: [64]u8 = undefined;
        const resp = std.fmt.bufPrint(&buf, "\x1bP1$r q{d}\x1b\\", .{style}) catch |err| {
            core.logging.logError("terminal", "DCS cursor-style response format failed", err);
            return;
        };
        writeResponse(self, resp, "DCS cursor-style response write failed");
        return;
    }

    // DECSTBM request
    if (std.mem.eql(u8, req, "r")) {
        var buf: [64]u8 = undefined;
        const resp = std.fmt.bufPrint(&buf, "\x1bP1$r 1;{d}r\x1b\\", .{self.height}) catch |err| {
            core.logging.logError("terminal", "DCS margin response format failed", err);
            return;
        };
        writeResponse(self, resp, "DCS margin response write failed");
        return;
    }

    // Invalid/unavailable request
    writeResponse(self, "\x1bP0$r\x1b\\", "DCS unavailable response write failed");
}

fn beginOsc(self: *Pane, c1: bool) void {
    self.osc_in_progress = true;
    self.osc_prev_esc = false;
    self.osc_discarding = false;
    self.osc_buf.clearRetainingCapacity();
    self.osc_buf.append(self.allocator, if (c1) 0x9d else 0x1b) catch {
        self.osc_discarding = true;
        return;
    };
    if (!c1) {
        self.osc_buf.append(self.allocator, ']') catch {
            self.osc_discarding = true;
            self.osc_buf.clearRetainingCapacity();
        };
    }
}

fn appendOscByte(self: *Pane, b: u8) void {
    // BEL or ESC \ only. 0x9c (C1 ST) is a UTF-8 continuation byte — accepting
    // it truncates any OSC whose payload carries non-ASCII text, such as a
    // title or a hyperlink URI containing U+2700..U+273F.
    const done = b == 0x07 or (self.osc_prev_esc and b == '\\');
    self.osc_prev_esc = b == 0x1b;

    if (!self.osc_discarding) {
        self.osc_buf.append(self.allocator, b) catch {
            self.osc_discarding = true;
            self.osc_buf.clearRetainingCapacity();
        };
        if (self.osc_buf.items.len > core.constants.Sizes.max_clipboard_osc_bytes) {
            self.osc_discarding = true;
            self.osc_buf.clearRetainingCapacity();
        }
    }

    if (done) finishOsc(self);
}

fn finishOsc(self: *Pane) void {
    self.osc_in_progress = false;
    self.osc_pending_esc = false;
    self.osc_prev_esc = false;
    defer {
        self.osc_discarding = false;
        self.osc_buf.clearRetainingCapacity();
    }
    if (self.osc_discarding) return;

    const code = parseOscCode(self.osc_buf.items) orelse {
        feedVtOutput(self, self.osc_buf.items);
        return;
    };
    if (isConsumedOscCode(code)) {
        consumeOsc(self, self.osc_buf.items);
        return;
    }
    if (!shouldPassthroughOsc(self.osc_buf.items)) {
        feedVtOutput(self, self.osc_buf.items);
        return;
    }

    if (isOscQuery(self.osc_buf.items)) {
        if (handleOscQuery(self, code)) return;
        self.osc_expected_responses +|= 1;
    }
    const stdout = std.fs.File.stdout();
    stdout.writeAll(self.osc_buf.items) catch |err| {
        core.logging.logError("terminal", "forward OSC sequence to terminal stdout", err);
    };
}

fn consumeOsc(self: *Pane, seq: []const u8) void {
    switch (self.osc_consumer.consume(seq, std.time.milliTimestamp())) {
        .ignore => {},
        .notification => |notification| {
            if (self.osc_notifications.items.len >= 16) return;
            self.osc_notifications.append(self.allocator, notification) catch |err| {
                core.logging.logError("terminal", "queue pane OSC notification", err);
            };
        },
        .progress => |progress| {
            self.osc_progress = progress;
            self.osc_progress_changed = true;
        },
        .kitty_query => |query| {
            var reply_buf: [160]u8 = undefined;
            const reply = if (query.id().len > 0)
                std.fmt.bufPrint(&reply_buf, "\x1b]99;i={s}:p=?;p=title,body\x1b\\", .{query.id()}) catch return
            else
                std.fmt.bufPrint(&reply_buf, "\x1b]99;p=?;p=title,body\x1b\\", .{}) catch return;
            writeResponse(self, reply, "OSC 99 capability response write failed");
        },
    }
}

fn parseOscCode(seq: []const u8) ?u32 {
    const starts_esc = seq.len >= 2 and seq[0] == 0x1b and seq[1] == ']';
    const starts_c1 = seq.len >= 1 and seq[0] == 0x9d;
    if (!starts_esc and !starts_c1) return null;

    var i: usize = if (starts_esc) 2 else 1;
    var code: u32 = 0;
    var any: bool = false;
    while (i < seq.len) : (i += 1) {
        const c = seq[i];
        if (c == ';') break;
        if (c < '0' or c > '9') return null;
        any = true;
        code = code * 10 + @as(u32, c - '0');
        if (code > 10000) return null;
    }
    if (!any) return null;
    return code;
}

fn handleOscQuery(self: *Pane, code: u32) bool {
    // All color queries (OSC 10/11/12 and others) are forwarded to the
    // real terminal so child applications receive the actual palette.
    _ = self;
    _ = code;
    return false;
}

fn shouldPassthroughOsc(seq: []const u8) bool {
    const code = parseOscCode(seq) orelse return false;
    return isPassthroughOscCode(code);
}

fn isOscQuery(seq: []const u8) bool {
    const code = parseOscCode(seq) orelse return false;
    if (!isQueryReplyOscCode(code)) return false;
    return std.mem.indexOf(u8, seq, ";?") != null;
}

fn isPassthroughOscCode(code: u32) bool {
    // Window title / icon title / cwd updates.
    if (code == 0 or code == 1 or code == 2 or code == 7) return true;

    // Palette and dynamic-color control/query families. Keep this deliberately
    // broader than only OSC 4/10/11/12: terminals and TUIs use OSC 5, 13-19,
    // 50/51, and reset forms such as 104/105/110-119 for color/font feedback.
    if (code == 4 or code == 5 or code == 104 or code == 105) return true;
    if (code >= 10 and code <= 19) return true;
    if (code >= 50 and code <= 59) return true;
    if (code >= 110 and code <= 119) return true;
    return false;
}

fn isConsumedOscCode(code: u32) bool {
    return code == 9 or code == 99 or code == 777;
}

fn isQueryReplyOscCode(code: u32) bool {
    if (code == 4 or code == 5 or code == 104 or code == 105) return true;
    if (code >= 10 and code <= 19) return true;
    if (code >= 50 and code <= 59) return true;
    if (code >= 110 and code <= 119) return true;
    return false;
}

test "OSC passthrough keeps color feedback families including OSC 51" {
    try std.testing.expect(shouldPassthroughOsc("\x1b]4;1;?\x07"));
    try std.testing.expect(shouldPassthroughOsc("\x1b]10;?\x07"));
    try std.testing.expect(shouldPassthroughOsc("\x1b]11;?\x07"));
    try std.testing.expect(shouldPassthroughOsc("\x1b]51;?\x07"));
    try std.testing.expect(shouldPassthroughOsc("\x1b]110;?\x07"));

    try std.testing.expect(isOscQuery("\x1b]51;?\x07"));
    try std.testing.expect(isOscQuery("\x1b]119;?\x07"));
    try std.testing.expect(!shouldPassthroughOsc("\x1b]99;?\x07"));
    try std.testing.expect(isConsumedOscCode(9));
    try std.testing.expect(isConsumedOscCode(99));
    try std.testing.expect(isConsumedOscCode(777));
}

test "CSI scanner preserves query state across every split" {
    const QueryState = enum { idle, esc, csi };
    const Scanner = struct {
        csi_query_state: QueryState = .idle,
        csi_query_buf: [32]u8 = undefined,
        csi_query_len: u8 = 0,
    };
    const Capture = struct {
        count: usize = 0,
        final: u8 = 0,
        params: [32]u8 = undefined,
        params_len: usize = 0,

        fn receive(self: *@This(), final: u8, params: []const u8) void {
            self.count += 1;
            self.final = final;
            self.params_len = params.len;
            @memcpy(self.params[0..params.len], params);
        }
    };

    const sequences = [_][]const u8{
        "\x1b[?u",
        "\x1b[?2026$p",
        "\x1b[6n",
        "\x1b[>0q",
    };
    for (sequences) |sequence| {
        for (0..sequence.len + 1) |split| {
            var scanner: Scanner = .{};
            var capture: Capture = .{};
            scanCsi(&scanner, sequence[0..split], &capture, Capture.receive);
            scanCsi(&scanner, sequence[split..], &capture, Capture.receive);
            try std.testing.expectEqual(@as(usize, 1), capture.count);
            try std.testing.expectEqual(sequence[sequence.len - 1], capture.final);
            try std.testing.expectEqualStrings(sequence[2 .. sequence.len - 1], capture.params[0..capture.params_len]);
        }
    }
}

fn readTestFrame(fd: std.posix.fd_t, buffer: []u8) !struct { header: core.wire.MuxVtHeader, payload: []const u8 } {
    var header_bytes: [@sizeOf(core.wire.MuxVtHeader)]u8 = undefined;
    try readTestExact(fd, &header_bytes);
    const header = std.mem.bytesToValue(core.wire.MuxVtHeader, &header_bytes);
    if (header.len > buffer.len) return error.TestFrameTooLarge;
    try readTestExact(fd, buffer[0..header.len]);
    return .{ .header = header, .payload = buffer[0..header.len] };
}

fn readTestExact(fd: std.posix.fd_t, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const count = try std.posix.read(fd, buffer[offset..]);
        if (count == 0) return error.EndOfStream;
        offset += count;
    }
}

test "Kitty replies return to the pane across every query split" {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    try std.testing.expectEqual(@as(usize, 0), rc);
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    var pane: Pane = undefined;
    try pane.initWithPod(std.testing.allocator, 1, 0, 0, 80, 24, 7, fds[0], @splat('0'));
    defer pane.deinit();

    var frame_buf: [256]u8 = undefined;
    const resize = try readTestFrame(fds[1], &frame_buf);
    try std.testing.expectEqual(@intFromEnum(core.pod_protocol.FrameType.resize), resize.header.frame_type);

    const query = "\x1b[?u";
    for (0..query.len + 1) |split| {
        pane.feedPodOutput(query[0..split]);
        pane.feedPodOutput(query[split..]);
        const frame = try readTestFrame(fds[1], &frame_buf);
        try std.testing.expectEqual(@as(u16, 7), frame.header.pane_id);
        try std.testing.expectEqual(@intFromEnum(core.pod_protocol.FrameType.input), frame.header.frame_type);
        try std.testing.expectEqualStrings("\x1b[?0u", frame.payload[16..]);
    }

    pane.feedPodOutput("\x1b[>1u");
    pane.feedPodOutput(query);
    const enabled = try readTestFrame(fds[1], &frame_buf);
    try std.testing.expectEqualStrings("\x1b[?1u", enabled.payload[16..]);
}

test "DECRQM replies return to the pane across every query split" {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    try std.testing.expectEqual(@as(usize, 0), rc);
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    var pane: Pane = undefined;
    try pane.initWithPod(std.testing.allocator, 1, 0, 0, 80, 24, 7, fds[0], @splat('0'));
    defer pane.deinit();

    var frame_buf: [256]u8 = undefined;
    _ = try readTestFrame(fds[1], &frame_buf);

    const query = "\x1b[?2026$p";
    for (0..query.len + 1) |split| {
        pane.feedPodOutput(query[0..split]);
        pane.feedPodOutput(query[split..]);
        const frame = try readTestFrame(fds[1], &frame_buf);
        try std.testing.expectEqualStrings("\x1b[?2026;2$y", frame.payload[16..]);
    }

    pane.feedPodOutput("\x1b[?2026h");
    pane.feedPodOutput(query);
    const enabled = try readTestFrame(fds[1], &frame_buf);
    try std.testing.expectEqualStrings("\x1b[?2026;1$y", enabled.payload[16..]);
}

test "DSR replies use pane-local coordinates across every query split" {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    try std.testing.expectEqual(@as(usize, 0), rc);
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    var pane: Pane = undefined;
    try pane.initWithPod(std.testing.allocator, 1, 31, 12, 80, 24, 7, fds[0], @splat('0'));
    defer pane.deinit();

    var frame_buf: [256]u8 = undefined;
    _ = try readTestFrame(fds[1], &frame_buf);
    pane.focused = false;
    pane.feedPodOutput("\x1b[10;20H");

    const query = "\x1b[6n";
    for (0..query.len + 1) |split| {
        pane.feedPodOutput(query[0..split]);
        pane.feedPodOutput(query[split..]);
        const frame = try readTestFrame(fds[1], &frame_buf);
        try std.testing.expectEqualStrings("\x1b[10;20R", frame.payload[16..]);
    }

    pane.feedPodOutput("\x1b[24;80H");
    pane.feedPodOutput("\x1b[?6n");
    const decxcpr = try readTestFrame(fds[1], &frame_buf);
    try std.testing.expectEqualStrings("\x1b[?24;80R", decxcpr.payload[16..]);
}

test "local replies preserve byte ordering within one output frame" {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    try std.testing.expectEqual(@as(usize, 0), rc);
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    var pane: Pane = undefined;
    try pane.initWithPod(std.testing.allocator, 1, 0, 0, 80, 24, 7, fds[0], @splat('0'));
    defer pane.deinit();

    var frame_buf: [256]u8 = undefined;
    _ = try readTestFrame(fds[1], &frame_buf);

    pane.feedPodOutput("\x1b[10;20H\x1b[6n");
    const after_move = try readTestFrame(fds[1], &frame_buf);
    try std.testing.expectEqualStrings("\x1b[10;20R", after_move.payload[16..]);

    pane.feedPodOutput("\x1b[1;1H\x1b[6n\x1b[10;20H");
    const before_move = try readTestFrame(fds[1], &frame_buf);
    try std.testing.expectEqualStrings("\x1b[1;1R", before_move.payload[16..]);

    pane.feedPodOutput("\x1b[>1u\x1b[?u");
    const after_flags = try readTestFrame(fds[1], &frame_buf);
    try std.testing.expectEqualStrings("\x1b[?1u", after_flags.payload[16..]);

    pane.feedPodOutput("\x1b[?u\x1b[>2u");
    const before_flags = try readTestFrame(fds[1], &frame_buf);
    try std.testing.expectEqualStrings("\x1b[?1u", before_flags.payload[16..]);
}

test "XTVERSION replies return to the pane across every query split" {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    try std.testing.expectEqual(@as(usize, 0), rc);
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    var pane: Pane = undefined;
    try pane.initWithPod(std.testing.allocator, 1, 0, 0, 80, 24, 7, fds[0], @splat('0'));
    defer pane.deinit();

    var frame_buf: [256]u8 = undefined;
    _ = try readTestFrame(fds[1], &frame_buf);
    var expected_buf: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "\x1bP>|hexe({s})\x1b\\", .{
        core.build_options.version,
    });

    const query = "\x1b[>0q";
    for (0..query.len + 1) |split| {
        pane.feedPodOutput(query[0..split]);
        pane.feedPodOutput(query[split..]);
        const frame = try readTestFrame(fds[1], &frame_buf);
        try std.testing.expectEqualStrings(expected, frame.payload[16..]);
    }
}

test "consumed OSC notifications and progress survive every split" {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    try std.testing.expectEqual(@as(usize, 0), rc);
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    var pane: Pane = undefined;
    try pane.initWithPod(std.testing.allocator, 1, 0, 0, 80, 24, 7, fds[0], @splat('0'));
    defer pane.deinit();

    var frame_buf: [256]u8 = undefined;
    _ = try readTestFrame(fds[1], &frame_buf);

    const notification_seq = "\x1b]777;notify;Build;done\x1b\\";
    for (0..notification_seq.len + 1) |split| {
        pane.feedPodOutput(notification_seq[0..split]);
        pane.feedPodOutput(notification_seq[split..]);
        const notification = pane.takeOscNotification() orelse return error.TestExpectedNotification;
        try std.testing.expectEqualStrings("Build", notification.title());
        try std.testing.expectEqualStrings("done", notification.body());
    }

    const progress_seq = "\x1b]9;4;1;73\x07";
    for (0..progress_seq.len + 1) |split| {
        pane.feedPodOutput(progress_seq[0..split]);
        pane.feedPodOutput(progress_seq[split..]);
        try std.testing.expect(pane.takeOscProgressChanged());
        try std.testing.expectEqual(@as(?u8, 73), pane.osc_progress.percentage);
    }
}

test "OSC 99 capability replies return to the pane across every split" {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    try std.testing.expectEqual(@as(usize, 0), rc);
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    var pane: Pane = undefined;
    try pane.initWithPod(std.testing.allocator, 1, 0, 0, 80, 24, 7, fds[0], @splat('0'));
    defer pane.deinit();

    var frame_buf: [256]u8 = undefined;
    _ = try readTestFrame(fds[1], &frame_buf);

    const query = "\x1b]99;i=probe:p=?;\x1b\\";
    for (0..query.len + 1) |split| {
        pane.feedPodOutput(query[0..split]);
        pane.feedPodOutput(query[split..]);
        const frame = try readTestFrame(fds[1], &frame_buf);
        try std.testing.expectEqualStrings("\x1b]99;i=probe:p=?;p=title,body\x1b\\", frame.payload[16..]);
    }
}

fn containsClearSeq(tail: []const u8, data: []const u8) bool {
    const has_esc = std.mem.indexOfScalar(u8, data, 0x1b) != null;
    const has_ff = std.mem.indexOfScalar(u8, data, 0x0c) != null;
    const tail_has_esc = tail.len > 0 and tail[tail.len - 1] == 0x1b;
    if (!has_esc and !has_ff and !tail_has_esc) return false;

    return has_ff or
        containsSeq(tail, data, "\x1b[2J") or
        containsSeq(tail, data, "\x1b[3J") or
        containsSeq(tail, data, "\x1b[J") or
        containsSeq(tail, data, "\x1b[0J") or
        containsSeq(tail, data, "\x1b[H\x1b[2J") or
        containsSeq(tail, data, "\x1b[H\x1b[J") or
        containsSeq(tail, data, "\x1b[H\x1b[0J") or
        containsSeq(tail, data, "\x1b[1;1H\x1b[2J") or
        containsSeq(tail, data, "\x1b[1;1H\x1b[J") or
        containsSeq(tail, data, "\x1b[1;1H\x1b[0J");
}

fn containsSeq(tail: []const u8, data: []const u8, seq: []const u8) bool {
    if (std.mem.indexOf(u8, data, seq) != null) return true;
    if (tail.len == 0) return false;

    const max_k = @min(tail.len, seq.len - 1);
    var k: usize = 1;
    while (k <= max_k) : (k += 1) {
        if (std.mem.eql(u8, tail[tail.len - k .. tail.len], seq[0..k]) and
            data.len >= seq.len - k and
            std.mem.eql(u8, data[0 .. seq.len - k], seq[k..seq.len]))
        {
            return true;
        }
    }

    return false;
}
