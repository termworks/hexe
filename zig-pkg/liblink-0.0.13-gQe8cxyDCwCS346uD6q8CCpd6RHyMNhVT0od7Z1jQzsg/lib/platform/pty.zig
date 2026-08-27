const std = @import("std");
const posix = std.posix;
const user = @import("user.zig");
const ttymodes = @import("../protocol/ttymodes.zig");

// External C functions for PTY
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) [*:0]const u8;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" var environ: [*:null]?[*:0]u8;

/// PTY (Pseudo-Terminal) for shell sessions
///
/// Platform-specific implementation for Linux/Unix
pub const Pty = struct {
    master_fd: posix.fd_t,
    slave_path: []const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create a new PTY pair
    pub fn create(allocator: std.mem.Allocator) !Self {
        // Open PTY master
        const master_fd = try posix.open(
            "/dev/ptmx",
            .{ .ACCMODE = .RDWR, .NOCTTY = true },
            0,
        );
        errdefer posix.close(master_fd);

        // Grant access and unlock
        if (grantpt(master_fd) != 0) {
            return error.GrantPtFailed;
        }

        if (unlockpt(master_fd) != 0) {
            return error.UnlockPtFailed;
        }

        // Get slave device name
        const slave_name_ptr = ptsname(master_fd);
        const slave_name = std.mem.span(slave_name_ptr);
        const slave_path = try allocator.dupe(u8, slave_name);
        errdefer allocator.free(slave_path);

        return Self{
            .master_fd = master_fd,
            .slave_path = slave_path,
            .allocator = allocator,
        };
    }

    /// Clean up PTY
    pub fn deinit(self: *Self) void {
        posix.close(self.master_fd);
        self.allocator.free(self.slave_path);
    }

    /// Read data from PTY master (shell output)
    pub fn read(self: *Self, buffer: []u8) !usize {
        return posix.read(self.master_fd, buffer);
    }

    /// Write data to PTY master (shell input)
    pub fn write(self: *Self, data: []const u8) !usize {
        return posix.write(self.master_fd, data);
    }

    /// Set terminal window size
    pub fn setWindowSize(self: *Self, rows: u16, cols: u16) !void {
        const winsize = posix.winsize{
            .row = rows,
            .col = cols,
            .xpixel = 0,
            .ypixel = 0,
        };

        const TIOCSWINSZ = 0x5414; // Linux ioctl number for setting window size
        const result = std.c.ioctl(self.master_fd, TIOCSWINSZ, @intFromPtr(&winsize));
        if (result != 0) {
            return error.IoctlFailed;
        }
    }
};

pub const ShellEnv = struct {
    term: [*:0]const u8 = "xterm-256color",
    home: [*:0]const u8,
    shell: [*:0]const u8,
    user: [*:0]const u8,
    logname: [*:0]const u8,
    lang: ?[*:0]const u8 = null,
    lc_all: ?[*:0]const u8 = null,
    lc_ctype: ?[*:0]const u8 = null,
    colorterm: ?[*:0]const u8 = null,
    uid: ?std.posix.uid_t = null,
    gid: ?std.posix.gid_t = null,
    modes: ?[]const u8 = null,
};

/// Spawn a shell in a PTY
pub fn spawnShell(pty: *Pty, env: ShellEnv) !posix.pid_t {
    const pid = try posix.fork();

    if (pid == 0) {
        // Child process
        childSetup(pty, env) catch |err| {
            std.debug.print("Child setup failed: {}\n", .{err});
            std.process.exit(1);
        };
        // If we get here, exec failed
        std.process.exit(1);
    }

    // Parent process - return child PID
    return pid;
}

/// Child process setup (runs in forked child)
fn childSetup(pty: *Pty, env: ShellEnv) !void {
    // Create new session
    if (std.c.setsid() < 0) {
        return error.SetsidFailed;
    }

    // Open PTY slave
    var slave_fd = try posix.open(
        pty.slave_path,
        .{ .ACCMODE = .RDWR },
        0,
    );

    // Make slave the controlling terminal
    const TIOCSCTTY = 0x540E; // Linux ioctl number for setting controlling terminal
    if (std.c.ioctl(slave_fd, TIOCSCTTY, @as(c_int, 0)) != 0) {
        posix.close(slave_fd);
        return error.IoctlFailed;
    }

    // Redirect stdin, stdout, stderr to PTY slave
    posix.dup2(slave_fd, 0) catch {
        posix.close(slave_fd);
        return error.DupFailed;
    };
    posix.dup2(slave_fd, 1) catch {
        posix.close(slave_fd);
        return error.DupFailed;
    };
    posix.dup2(slave_fd, 2) catch {
        posix.close(slave_fd);
        return error.DupFailed;
    };

    // Close original slave fd if it's not 0, 1, or 2
    if (slave_fd > 2) {
        posix.close(slave_fd);
        slave_fd = 0; // sentinel — fd is now stdin
    }

    // Close master fd (child doesn't need it)
    posix.close(pty.master_fd);

    if (env.modes) |modes| {
        ttymodes.applyTerminalModes(slave_fd, modes) catch {};
    }

    // Apply user identity (setuid/setgid) — must happen after PTY setup
    // but before exec. If the server isn't running as root, initgroups
    // will fail; skip silently since the shell works as the current user.
    if (env.uid != null and env.gid != null) {
        user.applyIdentityRaw(env.user, env.uid.?, env.gid.?) catch {};
    }

    // Set environment variables (same as SSH does)
    _ = setenv("TERM", env.term, 1);
    _ = setenv("HOME", env.home, 1);
    _ = setenv("SHELL", env.shell, 1);
    _ = setenv("USER", env.user, 1);
    _ = setenv("LOGNAME", env.logname, 1);
    _ = setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
    if (env.lang) |lang| _ = setenv("LANG", lang, 1);
    if (env.lc_all) |lc_all| _ = setenv("LC_ALL", lc_all, 1);
    if (env.lc_ctype) |lc_ctype| _ = setenv("LC_CTYPE", lc_ctype, 1);
    if (env.colorterm) |colorterm| _ = setenv("COLORTERM", colorterm, 1);

    // SSH runs a LOGIN shell for PTY sessions (argv[0] starts with '-')
    // This is shell-agnostic - works for bash, zsh, fish, etc.
    // Example: "/bin/zsh" -> argv[0] = "-zsh", "/bin/bash" -> argv[0] = "-bash"
    const shell_path = std.mem.span(env.shell);
    const basename_start = if (std.mem.lastIndexOfScalar(u8, shell_path, '/')) |idx|
        idx + 1
    else
        0;
    const basename = shell_path[basename_start..];

    // Create login shell name by prefixing basename with '-'
    var login_name_buf: [256]u8 = undefined;
    login_name_buf[0] = '-';
    @memcpy(login_name_buf[1 .. 1 + basename.len], basename);
    login_name_buf[1 + basename.len] = 0;

    const argv = [_:null]?[*:0]const u8{
        @ptrCast(&login_name_buf), // argv[0] = "-{shell}" (login shell)
        null,
    };

    // exec never returns on success
    const err = posix.execveZ(env.shell, &argv, @ptrCast(environ));
    return err;
}
