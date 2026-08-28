const std = @import("std");

/// Log levels in order of severity.
pub const Level = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,

    pub fn prefix(self: Level) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

/// Global log configuration.
pub var min_level: Level = .warn;
pub var enabled: bool = false;
pub var include_source: bool = false;

/// Module-specific debug flags (for backward compatibility).
pub var mux_debug: bool = false;
pub var ses_debug: bool = false;
pub var pod_debug: bool = false;
pub var shp_debug: bool = false;

/// Whether stderr is a terminal, decided once. Colour is for a person reading
/// along; a log being collected into a file should not carry escapes.
var tty: ?bool = null;

fn colourEnabled() bool {
    if (tty) |t| return t;
    const t = std.posix.isatty(std.posix.STDERR_FILENO);
    tty = t;
    return t;
}

fn colourFor(level: Level) []const u8 {
    return switch (level) {
        .trace => "\x1b[2m",
        .debug => "\x1b[36m",
        .info => "\x1b[32m",
        .warn => "\x1b[33m",
        .err => "\x1b[31m",
    };
}

fn toOurLevel(level: std.log.Level) Level {
    return switch (level) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .err,
    };
}

fn refreshModuleFlags() void {
    const debug_on = enabled and @intFromEnum(min_level) <= @intFromEnum(Level.debug);
    mux_debug = debug_on;
    ses_debug = debug_on;
    pod_debug = debug_on;
    shp_debug = debug_on;
}

fn writeAllStderr(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.posix.write(std.posix.STDERR_FILENO, bytes[off..]) catch return;
        if (n == 0) return;
        off += n;
    }
}

fn fallbackLog(level: Level, module: []const u8, msg: []const u8) void {
    writeAllStderr("[");
    writeAllStderr(level.prefix());
    writeAllStderr("][");
    writeAllStderr(module);
    writeAllStderr("] ");
    writeAllStderr(msg);
    writeAllStderr("\n");
}

/// Enable all debug logging.
pub fn enableAll() void {
    enabled = true;
    min_level = .trace;
    include_source = true;
    refreshModuleFlags();
}

/// Enable logging output at a specific minimum level.
pub fn enableAtLevel(level: Level) void {
    enabled = true;
    min_level = level;
    include_source = @intFromEnum(level) <= @intFromEnum(Level.debug);
    refreshModuleFlags();
}

/// Disable logging output.
pub fn disableAll() void {
    enabled = false;
    min_level = .warn;
    include_source = false;
    refreshModuleFlags();
}

pub fn setLogLevel(level: ?Level) void {
    if (level) |value| {
        enableAtLevel(value);
        return;
    }
    disableAll();
}

/// Resolve the level a process should run at from its two flags.
///
/// `--logfile PATH` on its own used to redirect stderr to PATH and leave
/// logging disabled, so the file was created and stayed 0 bytes. Asking for a
/// log file is a request for logs.
///
/// The implied level is `debug`, not `info`: hexe's own startup and lifecycle
/// lines are all logged at debug, so an info default reproduced the empty file
/// on any clean run. `--log` still overrides.
pub fn effectiveLevel(level: ?Level, log_file: ?[]const u8) ?Level {
    if (level) |value| return value;
    if (log_file) |path| {
        if (path.len > 0) return .debug;
    }
    return null;
}

test "effectiveLevel: --logfile alone implies logging" {
    try std.testing.expectEqual(@as(?Level, null), effectiveLevel(null, null));
    try std.testing.expectEqual(@as(?Level, null), effectiveLevel(null, ""));
    try std.testing.expectEqual(@as(?Level, .debug), effectiveLevel(null, "/tmp/x.log"));
    // An explicit level always wins over the implied one.
    try std.testing.expectEqual(@as(?Level, .err), effectiveLevel(.err, "/tmp/x.log"));
    try std.testing.expectEqual(@as(?Level, .trace), effectiveLevel(.trace, null));
}

pub fn parseLevel(raw: []const u8) ?Level {
    if (std.ascii.eqlIgnoreCase(raw, "trace")) return .trace;
    if (std.ascii.eqlIgnoreCase(raw, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(raw, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(raw, "warn") or std.ascii.eqlIgnoreCase(raw, "warning")) return .warn;
    if (std.ascii.eqlIgnoreCase(raw, "err") or std.ascii.eqlIgnoreCase(raw, "error")) return .err;
    return null;
}

pub fn levelEnablesDebug(level: ?Level) bool {
    if (level) |value| return @intFromEnum(value) <= @intFromEnum(Level.debug);
    return false;
}

/// Configure logging mode for a process.
pub fn setDebugMode(debug_enabled: bool) void {
    setLogLevel(if (debug_enabled) .debug else null);
}

/// Explicitly release logger resources. Nothing is held any more: a line is
/// formatted on the stack and written to stderr, so there is nothing to close.
pub fn shutdown() void {}

fn logAt(
    level: Level,
    comptime module: []const u8,
    comptime fmt: []const u8,
    args: anytype,
    src: std.builtin.SourceLocation,
) void {
    if (!enabled) return;
    if (@intFromEnum(level) < @intFromEnum(min_level)) return;

    // Everything past this point is deliberately non-generic. Handing `fmt`
    // and `args` to the backend specialized the whole formatting and writer
    // stack once per call site — 1325 copies of the fallback and 100 of
    // ghostty's stream warning alone, several MB in total. Formatting here
    // and passing a plain slice collapses that to one instantiation.
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    emit(level, module, msg, src);
}

/// One line, formatted on the stack and written in a single call.
///
/// This used to go through a logging library, and the library imported a
/// network sink -- which reached `std.http`, and through it a TLS stack, an
/// X.509 parser and a decompressor: 668 KB of a terminal multiplexer spent on
/// an update check it never made. What hexe needs of a logger is a level, a
/// module name and a line on stderr.
fn emit(level: Level, module: []const u8, msg: []const u8, src: std.builtin.SourceLocation) void {
    var buf: [2560]u8 = undefined;
    var end: usize = 0;

    const put = struct {
        fn f(b: []u8, at: *usize, bytes: []const u8) void {
            const room = b.len - at.*;
            const n = @min(room, bytes.len);
            @memcpy(b[at.*..][0..n], bytes[0..n]);
            at.* += n;
        }
    }.f;

    const colour = colourEnabled();
    if (colour) put(&buf, &end, colourFor(level));

    // Wall clock as HH:MM:SS. No date: a log read while it is being written is
    // read within the day it was written.
    const now = std.time.timestamp();
    const secs: u64 = if (now > 0) @intCast(now) else 0;
    const hh = (secs / 3600) % 24;
    const mm = (secs / 60) % 60;
    const ss = secs % 60;
    var stamp: [16]u8 = undefined;
    put(&buf, &end, std.fmt.bufPrint(&stamp, "{d:0>2}:{d:0>2}:{d:0>2} ", .{ hh, mm, ss }) catch "");

    put(&buf, &end, "[");
    put(&buf, &end, level.prefix());
    put(&buf, &end, "][");
    put(&buf, &end, module);
    put(&buf, &end, "] ");
    if (colour) put(&buf, &end, "\x1b[0m");
    put(&buf, &end, msg);

    if (include_source) {
        var loc: [256]u8 = undefined;
        put(&buf, &end, std.fmt.bufPrint(&loc, " ({s}:{d})", .{ src.file, src.line }) catch "");
    }
    put(&buf, &end, "\n");

    writeAllStderr(buf[0..end]);
}

/// Log a message with the given level and module prefix.
pub fn logWithSource(
    level: Level,
    comptime module: []const u8,
    comptime fmt: []const u8,
    args: anytype,
    src: std.builtin.SourceLocation,
) void {
    logAt(level, module, fmt, args, src);
}

pub inline fn log(
    level: Level,
    comptime module: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    logWithSource(level, module, fmt, args, @src());
}

/// Convenience functions for each level.
pub fn traceWithSource(
    comptime module: []const u8,
    comptime fmt: []const u8,
    args: anytype,
    src: std.builtin.SourceLocation,
) void {
    logAt(.trace, module, fmt, args, src);
}

pub inline fn trace(
    comptime module: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    traceWithSource(module, fmt, args, @src());
}

pub fn debugWithSource(
    comptime module: []const u8,
    comptime fmt: []const u8,
    args: anytype,
    src: std.builtin.SourceLocation,
) void {
    logAt(.debug, module, fmt, args, src);
}

pub inline fn debug(
    comptime module: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    debugWithSource(module, fmt, args, @src());
}

pub fn infoWithSource(
    comptime module: []const u8,
    comptime fmt: []const u8,
    args: anytype,
    src: std.builtin.SourceLocation,
) void {
    logAt(.info, module, fmt, args, src);
}

pub inline fn info(
    comptime module: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    infoWithSource(module, fmt, args, @src());
}

pub fn warnWithSource(
    comptime module: []const u8,
    comptime fmt: []const u8,
    args: anytype,
    src: std.builtin.SourceLocation,
) void {
    logAt(.warn, module, fmt, args, src);
}

pub inline fn warn(
    comptime module: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    warnWithSource(module, fmt, args, @src());
}

pub fn errWithSource(
    comptime module: []const u8,
    comptime fmt: []const u8,
    args: anytype,
    src: std.builtin.SourceLocation,
) void {
    logAt(.err, module, fmt, args, src);
}

pub inline fn err(
    comptime module: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    errWithSource(module, fmt, args, @src());
}

/// Log an error with context (useful for replacing silent catch {}).
pub inline fn logError(
    comptime module: []const u8,
    comptime context: []const u8,
    error_val: anyerror,
) void {
    errWithSource(module, "{s}: {s}", .{ context, @errorName(error_val) }, @src());
}

/// Helper for common pattern: log error and return.
pub fn catchLog(comptime module: []const u8, comptime context: []const u8) fn (anyerror) void {
    return struct {
        fn handler(error_val: anyerror) void {
            logError(module, context, error_val);
        }
    }.handler;
}

/// std.log bridge so scoped std.log calls use this backend.
pub fn stdLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const module = @tagName(scope);
    logAt(toOurLevel(level), module, format, args, @src());
}
