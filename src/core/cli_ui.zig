//! Shared CLI styling, output helpers, and exit/detach banners.
//!
//! Uses standard ANSI 16-color semantic tokens so CLI output adapts to the
//! user's terminal theme, and automatically disables styling when output is not
//! a TTY, `NO_COLOR` is set, or `TERM=dumb`.

const std = @import("std");
const posix = std.posix;

pub const Palette = struct {
    enabled: bool = false,
    reset: []const u8 = "",
    bold: []const u8 = "",
    dim: []const u8 = "",
    accent: []const u8 = "", // cyan
    success: []const u8 = "", // green
    warn: []const u8 = "", // yellow
    err: []const u8 = "", // red
    info: []const u8 = "", // blue
    special: []const u8 = "", // magenta
    muted: []const u8 = "", // bright black / gray

    pub fn styled(enabled: bool) Palette {
        if (!enabled) return .{};
        return .{
            .enabled = true,
            .reset = "\x1b[0m",
            .bold = "\x1b[1m",
            .dim = "\x1b[2m",
            .accent = "\x1b[36m",
            .success = "\x1b[32m",
            .warn = "\x1b[33m",
            .err = "\x1b[31m",
            .info = "\x1b[34m",
            .special = "\x1b[35m",
            .muted = "\x1b[90m",
        };
    }

    pub fn forFd(fd: posix.fd_t) Palette {
        return styled(useColor(fd));
    }

    pub fn forStdout() Palette {
        return forFd(posix.STDOUT_FILENO);
    }

    pub fn forStderr() Palette {
        return forFd(posix.STDERR_FILENO);
    }
};

/// Print a styled error diagnostic to stderr.
/// Emits `✗ Error: ...` in bold red on color terminals and plain `Error: ...`
/// when piped or when `NO_COLOR` is set.
pub fn printErr(comptime fmt: []const u8, args: anytype) void {
    const p = Palette.forStderr();
    if (p.enabled) {
        std.debug.print("{s}{s}✗ Error:{s} " ++ fmt ++ "\n", .{ p.err, p.bold, p.reset } ++ args);
    } else {
        std.debug.print("Error: " ++ fmt ++ "\n", args);
    }
}

/// Print a dim follow-up hint line under an error or warning on stderr.
pub fn printErrHint(comptime fmt: []const u8, args: anytype) void {
    const p = Palette.forStderr();
    std.debug.print("  {s}" ++ fmt ++ "{s}\n", .{p.dim} ++ args ++ .{p.reset});
}

/// Print a styled warning diagnostic to stderr.
/// Emits `! Warning: ...` in bold yellow on color terminals and plain
/// `Warning: ...` when piped or when `NO_COLOR` is set.
pub fn printWarn(comptime fmt: []const u8, args: anytype) void {
    const p = Palette.forStderr();
    if (p.enabled) {
        std.debug.print("{s}{s}! Warning:{s} " ++ fmt ++ "\n", .{ p.warn, p.bold, p.reset } ++ args);
    } else {
        std.debug.print("Warning: " ++ fmt ++ "\n", args);
    }
}

/// Print a styled success line to stdout (`✓ ...`).
pub fn printOk(comptime fmt: []const u8, args: anytype) void {
    const p = Palette.forStdout();
    var out = std.fs.File.stdout().deprecatedWriter();
    out.print("{s}✓{s} " ++ fmt ++ "\n", .{ p.success, p.reset } ++ args) catch {};
}

/// Print a styled informational line to stdout (`• ...`).
pub fn printInfo(comptime fmt: []const u8, args: anytype) void {
    const p = Palette.forStdout();
    var out = std.fs.File.stdout().deprecatedWriter();
    out.print("{s}•{s} " ++ fmt ++ "\n", .{ p.accent, p.reset } ++ args) catch {};
}

/// Format a 24-bit ANSI foreground color swatch (`██`) for terminal previews.
pub fn formatRgbSwatch(buf: []u8, r: u8, g: u8, b: u8) []const u8 {
    return std.fmt.bufPrint(buf, "\x1b[38;2;{d};{d};{d}m██\x1b[0m", .{ r, g, b }) catch "";
}

/// Whether ANSI color styling should be emitted to `fd`.
pub fn useColor(fd: posix.fd_t) bool {
    return useColorWithEnv(
        posix.isatty(fd),
        posix.getenv("NO_COLOR"),
        posix.getenv("CLICOLOR_FORCE"),
        posix.getenv("TERM"),
    );
}

pub fn useColorWithEnv(
    is_tty: bool,
    no_color: ?[]const u8,
    clicolor_force: ?[]const u8,
    term: ?[]const u8,
) bool {
    if (clicolor_force) |v| {
        if (v.len > 0 and !std.mem.eql(u8, v, "0")) return true;
    }
    if (no_color) |v| {
        if (v.len > 0) return false;
    }
    if (term) |t| {
        if (std.mem.eql(u8, t, "dumb")) return false;
    }
    return is_tty;
}

/// Replace a leading `$HOME` prefix with `~` for compact display.
pub fn compactHome(path: []const u8, buf: []u8) []const u8 {
    const home = posix.getenv("HOME") orelse return path;
    return compactHomeWith(path, home, buf);
}

pub fn compactHomeWith(path: []const u8, home: []const u8, buf: []u8) []const u8 {
    if (home.len == 0 or path.len < home.len) return path;
    if (!std.mem.startsWith(u8, path, home)) return path;
    if (path.len == home.len) {
        if (buf.len < 1) return path;
        buf[0] = '~';
        return buf[0..1];
    }
    if (path[home.len] != '/') return path;
    const rest = path[home.len..];
    if (1 + rest.len > buf.len) return path;
    buf[0] = '~';
    @memcpy(buf[1 .. 1 + rest.len], rest);
    return buf[0 .. 1 + rest.len];
}

/// Format a reattach command hint, including `-P <profile>` when a named profile is active.
pub fn formatAttachCmd(buf: []u8, target: []const u8, profile: ?[]const u8) []const u8 {
    if (profile) |inst| {
        if (inst.len > 0 and !std.mem.eql(u8, inst, "default")) {
            return std.fmt.bufPrint(buf, "hexe -P {s} attach {s}", .{ inst, target }) catch target;
        }
    }
    return std.fmt.bufPrint(buf, "hexe attach {s}", .{target}) catch target;
}

pub fn formatListCmd(buf: []u8, profile: ?[]const u8) []const u8 {
    if (profile) |inst| {
        if (inst.len > 0 and !std.mem.eql(u8, inst, "default")) {
            return std.fmt.bufPrint(buf, "hexe -P {s} ls", .{inst}) catch "hexe ls";
        }
    }
    return "hexe ls";
}

/// Format a clean post-detach banner printed after the terminal screen is restored.
pub fn formatDetachBanner(
    allocator: std.mem.Allocator,
    color: bool,
    session_name: []const u8,
    uuid8: []const u8,
    pane_count: usize,
    profile: ?[]const u8,
) ![]u8 {
    const p = Palette.styled(color);
    const display_name = if (session_name.len > 0) session_name else uuid8;
    const target = if (session_name.len > 0) session_name else uuid8;
    var attach_buf: [256]u8 = undefined;
    var list_buf: [128]u8 = undefined;
    const attach_cmd = formatAttachCmd(&attach_buf, target, profile);
    const list_cmd = formatListCmd(&list_buf, profile);
    const pane_word: []const u8 = if (pane_count == 1) "pane" else "panes";

    if (pane_count > 0) {
        return std.fmt.allocPrint(
            allocator,
            "{s}✓{s} Detached from session {s}{s}{s} {s}[{s}]{s} {s}({d} {s}){s}\n" ++
                "  {s}Reattach:{s}  {s}{s}{s}\n" ++
                "  {s}List all:{s}  {s}{s}{s}\n",
            .{
                p.success, p.reset,
                p.bold,    display_name, p.reset,
                p.muted,   uuid8,        p.reset,
                p.dim,     pane_count,   pane_word, p.reset,
                p.dim,     p.reset,      p.accent,  attach_cmd, p.reset,
                p.dim,     p.reset,      p.accent,  list_cmd,   p.reset,
            },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{s}✓{s} Detached from session {s}{s}{s} {s}[{s}]{s}\n" ++
            "  {s}Reattach:{s}  {s}{s}{s}\n" ++
            "  {s}List all:{s}  {s}{s}{s}\n",
        .{
            p.success, p.reset,
            p.bold,    display_name, p.reset,
            p.muted,   uuid8,        p.reset,
            p.dim,     p.reset,      p.accent, attach_cmd, p.reset,
            p.dim,     p.reset,      p.accent, list_cmd,   p.reset,
        },
    );
}

/// Format a banner when another terminal stole/attached this session.
pub fn formatStolenBanner(
    allocator: std.mem.Allocator,
    color: bool,
    session_name: []const u8,
    uuid8: []const u8,
    profile: ?[]const u8,
) ![]u8 {
    const p = Palette.styled(color);
    const display_name = if (session_name.len > 0) session_name else uuid8;
    const target = if (session_name.len > 0) session_name else uuid8;
    var attach_buf: [256]u8 = undefined;
    const attach_cmd = formatAttachCmd(&attach_buf, target, profile);

    return std.fmt.allocPrint(
        allocator,
        "{s}!{s} Session {s}{s}{s} {s}[{s}]{s} was attached from another terminal\n" ++
            "  {s}Reattach:{s}  {s}{s}{s}\n",
        .{
            p.warn,  p.reset,
            p.bold,  display_name, p.reset,
            p.muted, uuid8,        p.reset,
            p.dim,   p.reset,      p.accent, attach_cmd, p.reset,
        },
    );
}

/// Format a banner when the frontend disconnected unexpectedly while preserving the session.
pub fn formatDisconnectBanner(
    allocator: std.mem.Allocator,
    color: bool,
    session_name: []const u8,
    uuid8: []const u8,
    profile: ?[]const u8,
) ![]u8 {
    const p = Palette.styled(color);
    const display_name = if (session_name.len > 0) session_name else uuid8;
    const target = if (session_name.len > 0) session_name else uuid8;
    var attach_buf: [256]u8 = undefined;
    const attach_cmd = formatAttachCmd(&attach_buf, target, profile);

    return std.fmt.allocPrint(
        allocator,
        "{s}!{s} Disconnected from session {s}{s}{s} {s}[{s}]{s} {s}(still running in background){s}\n" ++
            "  {s}Reattach:{s}  {s}{s}{s}\n",
        .{
            p.warn,  p.reset,
            p.bold,  display_name, p.reset,
            p.muted, uuid8,        p.reset,
            p.dim,   p.reset,
            p.dim,   p.reset,      p.accent, attach_cmd, p.reset,
        },
    );
}

/// Format a banner when detach failed and panes were orphaned.
pub fn formatDetachFailedBanner(allocator: std.mem.Allocator, color: bool) ![]u8 {
    const p = Palette.styled(color);
    return std.fmt.allocPrint(
        allocator,
        "{s}✗{s} Detach failed — panes were preserved as orphans\n" ++
            "  {s}Inspect:{s}  {s}hexe ls{s}\n",
        .{ p.err, p.reset, p.dim, p.reset, p.accent, p.reset },
    );
}

/// Format a clean banner when detaching from `hexe pod attach`.
pub fn formatPodDetachBanner(
    allocator: std.mem.Allocator,
    color: bool,
    pod_label: []const u8,
    reattach_hint: []const u8,
) ![]u8 {
    const p = Palette.styled(color);
    return std.fmt.allocPrint(
        allocator,
        "\n{s}✓{s} Detached from pod {s}{s}{s}\n" ++
            "  {s}Reattach:{s}  {s}{s}{s}\n",
        .{
            p.success, p.reset,
            p.bold,    pod_label, p.reset,
            p.dim,     p.reset,   p.accent, reattach_hint, p.reset,
        },
    );
}

test "useColorWithEnv respects NO_COLOR, CLICOLOR_FORCE, TERM=dumb, and isatty" {
    try std.testing.expect(useColorWithEnv(true, null, null, "xterm-256color"));
    try std.testing.expect(!useColorWithEnv(false, null, null, "xterm-256color"));
    try std.testing.expect(!useColorWithEnv(true, "1", null, "xterm-256color"));
    try std.testing.expect(useColorWithEnv(true, "", null, "xterm-256color"));
    try std.testing.expect(!useColorWithEnv(true, null, null, "dumb"));
    try std.testing.expect(useColorWithEnv(false, "1", "1", "dumb"));
}

test "compactHomeWith replaces exact home and nested paths safely" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("~", compactHomeWith("/home/alice", "/home/alice", &buf));
    try std.testing.expectEqualStrings("~/code/hexe", compactHomeWith("/home/alice/code/hexe", "/home/alice", &buf));
    try std.testing.expectEqualStrings("/home/alice2/code", compactHomeWith("/home/alice2/code", "/home/alice", &buf));
    try std.testing.expectEqualStrings("/tmp/work", compactHomeWith("/tmp/work", "/home/alice", &buf));
}

test "formatDetachBanner includes profile flag when non-default and omits ANSI when color disabled" {
    const alloc = std.testing.allocator;
    const plain = try formatDetachBanner(alloc, false, "work", "a3f29c10", 3, "dev");
    defer alloc.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "\x1b[") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Detached from session work [a3f29c10] (3 panes)") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "hexe -P dev attach work") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "hexe -P dev ls") != null);

    const colored = try formatDetachBanner(alloc, true, "work", "a3f29c10", 1, null);
    defer alloc.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[32m") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored, "(1 pane)") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored, "hexe attach work") != null);
}

test "formatRgbSwatch formats truecolor block" {
    var buf: [48]u8 = undefined;
    const swatch = formatRgbSwatch(&buf, 0x12, 0x34, 0x56);
    try std.testing.expectEqualStrings("\x1b[38;2;18;52;86m██\x1b[0m", swatch);
}
