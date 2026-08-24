const std = @import("std");

pub const AsciicastOptions = struct {
    width: u16,
    height: u16,
    title: ?[]const u8 = null,
    command: ?[]const u8 = null,
};

pub const AsciicastWriter = struct {
    file: std.fs.File,
    start_ms: i64,
    /// stdout is not ours to close, and closing it would take the rest of the
    /// program's output with it.
    owns_file: bool = true,
    /// Whether `flush` may fsync. A pipe cannot: fsync answers EINVAL, and
    /// Zig's wrapper treats that as unreachable, so it PANICS rather than
    /// returning an error -- `flush() catch {}` does not save you. Decided once
    /// here instead of at each call site, which is where it was missed.
    syncable: bool = true,

    /// `-` means stdout, so a pane's stream can be piped into any program that
    /// reads asciicast. That is the whole reason this exists: a consumer should
    /// need to know the format, not the producer.
    pub fn init(path: []const u8, opts: AsciicastOptions) !AsciicastWriter {
        if (std.mem.eql(u8, path, "-")) return initFile(std.fs.File.stdout(), false, opts);

        if (std.fs.path.dirname(path)) |dir| {
            if (dir.len > 0) {
                try std.fs.cwd().makePath(dir);
            }
        }

        const file = try std.fs.cwd().createFile(path, .{ .truncate = true, .mode = 0o600 });
        errdefer file.close();
        return initFile(file, true, opts);
    }

    pub fn initFile(file: std.fs.File, owns: bool, opts: AsciicastOptions) !AsciicastWriter {
        // One fstat at open time rather than a guess per write. A caller can
        // hand us a file, a pipe or a socket, and only the first can be synced.
        const syncable = blk: {
            const st = std.posix.fstat(file.handle) catch break :blk false;
            break :blk std.posix.S.ISREG(st.mode);
        };
        var writer = AsciicastWriter{
            .file = file,
            .start_ms = std.time.milliTimestamp(),
            .owns_file = owns,
            .syncable = syncable,
        };
        try writer.writeHeader(opts);
        return writer;
    }

    pub fn deinit(self: *AsciicastWriter) void {
        if (self.owns_file) self.file.close();
        self.* = undefined;
    }

    /// An asciicast v2 marker: `[t, "m", label]`.
    ///
    /// How password mode leaves hexe's own framing and becomes something any
    /// asciicast reader can see. A player that does not know the label ignores
    /// it, which is exactly right -- and one that keeps its own scrollback can
    /// use it to scrub, which is the thing that actually matters.
    pub fn writeMarker(self: *AsciicastWriter, label: []const u8) !void {
        try self.writeEvent('m', label);
    }

    pub fn writeOutput(self: *AsciicastWriter, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.writeEvent('o', bytes);
    }

    pub fn writeInput(self: *AsciicastWriter, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.writeEvent('i', bytes);
    }

    pub fn flush(self: *AsciicastWriter) !void {
        // Events are written straight to the fd, so there is nothing buffered
        // here to push; this only asks the kernel to commit a real file.
        if (!self.syncable) return;
        try self.file.sync();
    }

    fn writeHeader(self: *AsciicastWriter, opts: AsciicastOptions) !void {
        try self.file.writeAll("{\"version\":2,\"width\":");
        try writeInt(&self.file, opts.width);
        try self.file.writeAll(",\"height\":");
        try writeInt(&self.file, opts.height);
        try self.file.writeAll(",\"timestamp\":");
        try writeInt(&self.file, std.time.timestamp());

        if (opts.title) |title| {
            try self.file.writeAll(",\"title\":");
            try writeJsonStringEscaped(&self.file, title);
        }

        if (opts.command) |command| {
            try self.file.writeAll(",\"command\":");
            try writeJsonStringEscaped(&self.file, command);
        }

        try self.file.writeAll("}\n");
    }

    fn writeEvent(self: *AsciicastWriter, kind: u8, bytes: []const u8) !void {
        const elapsed_ms = std.time.milliTimestamp() - self.start_ms;
        const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;

        try self.file.writeAll("[");
        try writeFloat3(&self.file, elapsed_s);
        try self.file.writeAll(",\"");
        _ = try self.file.write(&[_]u8{kind});
        try self.file.writeAll("\",");
        try writeJsonStringEscaped(&self.file, bytes);
        try self.file.writeAll("]\n");
    }
};

fn writeJsonStringEscaped(file: *std.fs.File, input: []const u8) !void {
    _ = try file.write(&[_]u8{'"'});
    for (input) |ch| {
        switch (ch) {
            '"' => try file.writeAll("\\\""),
            '\\' => try file.writeAll("\\\\"),
            '\n' => try file.writeAll("\\n"),
            '\r' => try file.writeAll("\\r"),
            '\t' => try file.writeAll("\\t"),
            0x08 => try file.writeAll("\\b"),
            0x0c => try file.writeAll("\\f"),
            else => {
                if (ch < 0x20) {
                    var esc_buf: [6]u8 = undefined;
                    const esc = try std.fmt.bufPrint(&esc_buf, "\\u00{x:0>2}", .{ch});
                    try file.writeAll(esc);
                } else {
                    _ = try file.write(&[_]u8{ch});
                }
            },
        }
    }
    _ = try file.write(&[_]u8{'"'});
}

fn writeInt(file: *std.fs.File, value: anytype) !void {
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{value});
    try file.writeAll(s);
}

fn writeFloat3(file: *std.fs.File, value: f64) !void {
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d:.3}", .{value});
    try file.writeAll(s);
}

fn tempCastPath(allocator: std.mem.Allocator, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "/tmp/hexe-asciicast-test-{d}-{s}.cast", .{ std.time.nanoTimestamp(), suffix });
}

test "asciicast writes header and both event kinds" {
    const allocator = std.testing.allocator;
    const path = try tempCastPath(allocator, "events");
    defer allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    var writer = try AsciicastWriter.init(path, .{
        .width = 120,
        .height = 33,
        .title = "record test",
        .command = "echo hi",
    });
    defer writer.deinit();

    try writer.writeOutput("hello\n");
    try writer.writeInput("ls\t-a\r\n");
    try writer.flush();

    const content = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "\"version\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"width\":120") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"height\":33") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"title\":\"record test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"command\":\"echo hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ",\"o\",\"hello\\n\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ",\"i\",\"ls\\t-a\\r\\n\"") != null);
}

test "asciicast escapes quotes backslashes and control chars" {
    const allocator = std.testing.allocator;
    const path = try tempCastPath(allocator, "escape");
    defer allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    var writer = try AsciicastWriter.init(path, .{ .width = 80, .height = 24 });
    defer writer.deinit();

    const payload = "\"\\\x01\n";
    try writer.writeOutput(payload);
    try writer.flush();

    const content = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "\\\"\\\\\\u0001\\n") != null);
}

test "asciicast skips empty input and output events" {
    const allocator = std.testing.allocator;
    const path = try tempCastPath(allocator, "empty");
    defer allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    var writer = try AsciicastWriter.init(path, .{ .width = 80, .height = 24 });
    defer writer.deinit();

    try writer.writeOutput("");
    try writer.writeInput("");
    try writer.flush();

    const content = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024);
    defer allocator.free(content);

    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    var count: usize = 0;
    while (lines.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
}
