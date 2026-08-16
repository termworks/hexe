const std = @import("std");
const logly = @import("logly");

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

var backend_logger: ?*logly.Logger = null;
var backend_config: logly.Config = logly.Config.default();
const backend_allocator = std.heap.page_allocator;

fn toLoglyLevel(level: Level) logly.Level {
    return switch (level) {
        .trace => .trace,
        .debug => .debug,
        .info => .info,
        .warn => .warning,
        .err => .err,
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

fn makeConfig() logly.Config {
    var cfg = logly.Config.default();
    cfg.level = toLoglyLevel(min_level);
    cfg.show_time = true;
    cfg.show_module = true;
    cfg.show_filename = include_source;
    cfg.show_lineno = include_source;
    cfg.show_function = false;
    cfg.color = std.posix.isatty(std.posix.STDERR_FILENO);
    cfg.auto_sink = false;
    cfg.global_console_display = false;
    cfg.global_file_storage = false;
    cfg.check_for_updates = false;
    cfg.emit_system_diagnostics_on_init = false;
    cfg.enable_callbacks = true;
    return cfg;
}

fn writeAllStderr(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.posix.write(std.posix.STDERR_FILENO, bytes[off..]) catch return;
        if (n == 0) return;
        off += n;
    }
}

fn callbackWriteRecord(record: *const logly.Record) anyerror!void {
    var formatter = logly.Formatter.init(backend_allocator);
    defer formatter.deinit();

    const line = formatter.format(record, backend_config) catch {
        std.debug.print(
            "[{s}][{s}] {s}\n",
            .{ record.level.asString(), record.module orelse "unknown", record.message },
        );
        return;
    };
    defer backend_allocator.free(line);

    writeAllStderr(line);
    writeAllStderr("\n");
}

fn ensureBackend() ?*logly.Logger {
    if (backend_logger) |logger| return logger;

    backend_config = makeConfig();
    const logger = logly.Logger.initWithConfig(backend_allocator, backend_config) catch |init_err| {
        std.debug.print("[error][logging] failed to initialize logging backend: {s}\n", .{@errorName(init_err)});
        return null;
    };
    logger.setLogCallback(callbackWriteRecord);
    backend_logger = logger;
    return logger;
}

fn reconfigureBackend() void {
    backend_config = makeConfig();
    if (backend_logger) |logger| {
        logger.configure(backend_config);
        if (enabled) logger.enable() else logger.disable();
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
    reconfigureBackend();
}

/// Enable logging output at a specific minimum level.
pub fn enableAtLevel(level: Level) void {
    enabled = true;
    min_level = level;
    include_source = @intFromEnum(level) <= @intFromEnum(Level.debug);
    refreshModuleFlags();
    reconfigureBackend();
}

/// Disable logging output.
pub fn disableAll() void {
    enabled = false;
    min_level = .warn;
    include_source = false;
    refreshModuleFlags();
    reconfigureBackend();
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

/// Explicitly release logger resources.
pub fn shutdown() void {
    if (backend_logger) |logger| {
        logger.deinit();
        backend_logger = null;
    }
}

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

fn emit(level: Level, module: []const u8, msg: []const u8, src: std.builtin.SourceLocation) void {
    const logger = ensureBackend() orelse {
        fallbackLog(level, module, msg);
        return;
    };

    const scoped = logger.scoped(module);
    switch (level) {
        .trace => scoped.tracef("{s}", .{msg}, src) catch fallbackLog(level, module, msg),
        .debug => scoped.debugf("{s}", .{msg}, src) catch fallbackLog(level, module, msg),
        .info => scoped.infof("{s}", .{msg}, src) catch fallbackLog(level, module, msg),
        .warn => scoped.warningf("{s}", .{msg}, src) catch fallbackLog(level, module, msg),
        .err => scoped.errf("{s}", .{msg}, src) catch fallbackLog(level, module, msg),
    }
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
