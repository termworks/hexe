const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const c = @cImport({
    @cInclude("pty.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("sys/ioctl.h");
});

const isolation_voidbox = @import("isolation_voidbox.zig");
const voidbox = @import("libvoid");

const log = std.log.scoped(.pty);

// External declaration for environ (modified by setenv)
extern var environ: [*:null]?[*:0]u8;

pub const Pty = struct {
    master_fd: posix.fd_t,
    child_pid: posix.pid_t,
    child_reaped: bool = false,
    // If true, we don't own the process (ses does) - don't try to kill on close
    external_process: bool = false,

    pub fn spawn(shell: []const u8) !Pty {
        return spawnWithCwd(shell, null);
    }

    pub fn spawnWithCwd(shell: []const u8, cwd: ?[]const u8) !Pty {
        return spawnInternal(shell, cwd, null);
    }

    pub fn spawnWithEnv(shell: []const u8, cwd: ?[]const u8, extra_env: ?[]const [2][]const u8) !Pty {
        return spawnInternal(shell, cwd, extra_env);
    }

    /// Create a Pty from an existing file descriptor
    /// Used when ses daemon owns the PTY and passes us the fd
    pub fn fromFd(fd: posix.fd_t, pid: posix.pid_t) Pty {
        return Pty{
            .master_fd = fd,
            .child_pid = pid,
            .child_reaped = false,
            .external_process = true, // ses owns the process
        };
    }

    fn spawnInternal(shell: []const u8, cwd: ?[]const u8, extra_env: ?[]const [2][]const u8) !Pty {
        var master_fd: c_int = 0;
        var slave_fd: c_int = 0;

        // Check isolation profile
        const profile = isolation_voidbox.getProfile();
        const isolated = isolation_voidbox.needsIsolation(profile);

        // Build voidbox config if isolation is needed
        const voidbox_config = if (isolated)
            isolation_voidbox.buildConfig(std.heap.c_allocator, profile, shell) catch {
                return error.VoidboxConfigFailed;
            }
        else
            null;

        // Create sync pipes for parent-child user namespace coordination.
        //
        // Every fd opened between here and the fork needs an errdefer: there
        // was none, so a failure part-way leaked whatever had already been
        // opened -- 6 fds if the fork itself failed. fork() fails with EAGAIN
        // precisely under process pressure, i.e. exactly when a caller would
        // retry, so each retry burned another 6 fds until the process could no
        // longer spawn anything at all. The errdefers are cancelled by
        // `spawn_committed` once the fork succeeds and ownership moves to the
        // parent/child split below.
        var spawn_committed = false;

        const sync_pipe = if (isolated) try posix.pipe() else .{ @as(posix.fd_t, -1), @as(posix.fd_t, -1) };
        errdefer if (isolated and !spawn_committed) {
            posix.close(sync_pipe[0]);
            posix.close(sync_pipe[1]);
        };

        const done_pipe = if (isolated) try posix.pipe() else .{ @as(posix.fd_t, -1), @as(posix.fd_t, -1) };
        errdefer if (isolated and !spawn_committed) {
            posix.close(done_pipe[0]);
            posix.close(done_pipe[1]);
        };

        // Get current terminal size to pass to the new PTY
        var ws: c.winsize = undefined;
        if (c.ioctl(posix.STDOUT_FILENO, c.TIOCGWINSZ, &ws) != 0) {
            ws.ws_col = 80;
            ws.ws_row = 24;
            ws.ws_xpixel = 0;
            ws.ws_ypixel = 0;
        }

        if (c.openpty(&master_fd, &slave_fd, null, null, &ws) != 0) {
            return error.OpenPtyFailed;
        }
        errdefer if (!spawn_committed) {
            posix.close(master_fd);
            posix.close(slave_fd);
        };

        const pid = try posix.fork();
        spawn_committed = true;
        if (pid == 0) {
            // ============================================================
            // CHILD PROCESS
            // ============================================================

            // Close parent ends of sync pipes
            if (isolated) {
                posix.close(sync_pipe[0]);
                posix.close(done_pipe[1]);
            }

            // Restore default signal dispositions before the shell inherits ours.
            //
            // SIG_IGN survives both fork AND exec. SES ignores SIGHUP so it can
            // outlive its launching terminal, and both SES and POD ignore
            // SIGPIPE — all of which reached every pane's shell. An ignored
            // SIGHUP is the reason a killed pane leaked its process tree: the
            // pod died, the kernel hung up the pty, and the shell shrugged it
            // off and ran forever.
            const dfl = std.os.linux.Sigaction{
                .handler = .{ .handler = std.os.linux.SIG.DFL },
                .mask = std.os.linux.sigemptyset(),
                .flags = 0,
            };
            _ = std.os.linux.sigaction(posix.SIG.HUP, &dfl, null);
            _ = std.os.linux.sigaction(posix.SIG.PIPE, &dfl, null);

            // Create new session, becoming session leader
            _ = posix.setsid() catch posix.exit(1);

            // Set the slave PTY as the controlling terminal
            if (c.ioctl(slave_fd, c.TIOCSCTTY, @as(c_int, 0)) != 0) {}

            posix.dup2(@intCast(slave_fd), posix.STDIN_FILENO) catch posix.exit(1);
            posix.dup2(@intCast(slave_fd), posix.STDOUT_FILENO) catch posix.exit(1);
            posix.dup2(@intCast(slave_fd), posix.STDERR_FILENO) catch posix.exit(1);
            _ = posix.close(@intCast(slave_fd));
            _ = posix.close(@intCast(master_fd));

            // Change to working directory if specified
            if (cwd) |dir| {
                posix.chdir(dir) catch {
                    if (posix.getenv("HOME")) |home| {
                        posix.chdir(home) catch posix.exit(1);
                    } else {
                        posix.exit(1);
                    }
                };
            }

            // Apply voidbox isolation if needed
            if (voidbox_config) |cfg| {
                const sync = voidbox.UsernsSync{
                    .ready_fd = sync_pipe[1],
                    .done_fd = done_pipe[0],
                };
                voidbox.applyIsolationInChildSync(cfg, std.heap.c_allocator, sync) catch |err| {
                    // Report to the pane's stderr (the pty slave, already
                    // dup2'd above) instead of a fixed, world-shared /tmp path
                    // that follows symlinks and truncates (CWE-59/CWE-377). The
                    // child is about to exit; the message surfaces in the pane.
                    var errbuf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&errbuf, "hexe: pane isolation failed: {}\r\n", .{err}) catch "hexe: pane isolation failed\r\n";
                    _ = posix.write(posix.STDERR_FILENO, msg) catch {};
                    posix.exit(1);
                };
            }

            // Build environment: inherit parent env + BOX=1 + TERM override + extra
            const envp = buildEnv(extra_env) catch posix.exit(1);

            // Close all file descriptors >= 3 before exec to prevent FD leaks
            // into the child process (other PTY masters, server sockets, etc.)
            closeExtraFds();

            // Check if command has spaces (needs shell wrapper)
            const has_spaces = std.mem.indexOfScalar(u8, shell, ' ') != null;

            if (has_spaces) {
                const cmd_z = std.heap.c_allocator.dupeZ(u8, shell) catch posix.exit(1);
                var argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z, null };
                const err = posix.execvpeZ("/bin/sh", &argv, envp);
                writeExecFailure(shell, err);
                posix.exit(execFailureExitCode(err));
            } else {
                const shell_z = std.heap.c_allocator.dupeZ(u8, shell) catch posix.exit(1);
                var argv = [_:null]?[*:0]const u8{ shell_z, null };
                const err = posix.execvpeZ(shell_z, &argv, envp);
                writeExecFailure(shell, err);
                posix.exit(execFailureExitCode(err));
            }
            unreachable;
        }

        // ============================================================
        // PARENT PROCESS
        // ============================================================

        _ = posix.close(@intCast(slave_fd));

        if (isolated) {
            // Close child ends of sync pipes
            posix.close(sync_pipe[1]);
            posix.close(done_pipe[0]);

            // Wait for child to create all namespaces (single unshare call)
            var buf: [1]u8 = undefined;
            const sync_n = posix.read(sync_pipe[0], &buf) catch |err| {
                abortIsolatedSpawn(pid, @intCast(master_fd), .{ sync_pipe[0], -1 }, .{ -1, done_pipe[1] });
                return err;
            };
            posix.close(sync_pipe[0]);
            if (sync_n != 1) {
                abortIsolatedSpawn(pid, @intCast(master_fd), .{ -1, -1 }, .{ -1, done_pipe[1] });
                return error.IsolationSyncFailed;
            }

            // Write uid_map and gid_map from parent side
            const ns = @import("libvoid").namespace;
            ns.writeUserRootMappings(std.heap.c_allocator, pid) catch |err| {
                abortIsolatedSpawn(pid, @intCast(master_fd), .{ -1, -1 }, .{ -1, done_pipe[1] });
                return err;
            };

            // Signal child that mapping is done
            const done_n = posix.write(done_pipe[1], &[_]u8{1}) catch |err| {
                abortIsolatedSpawn(pid, @intCast(master_fd), .{ -1, -1 }, .{ -1, done_pipe[1] });
                return err;
            };
            posix.close(done_pipe[1]);
            if (done_n != 1) {
                abortIsolatedSpawn(pid, @intCast(master_fd), .{ -1, -1 }, .{ -1, -1 });
                return error.IsolationSyncFailed;
            }

            // Apply cgroups (resource limits)
            const pane_uuid = findPaneUuid(extra_env);
            isolation_voidbox.applyParentCgroups(pid, pane_uuid);
        }

        return Pty{
            .master_fd = @intCast(master_fd),
            .child_pid = pid,
        };
    }

    fn abortIsolatedSpawn(pid: posix.pid_t, master_fd: posix.fd_t, sync_pipe: [2]posix.fd_t, done_pipe: [2]posix.fd_t) void {
        if (sync_pipe[0] >= 0) posix.close(sync_pipe[0]);
        if (sync_pipe[1] >= 0) posix.close(sync_pipe[1]);
        if (done_pipe[0] >= 0) posix.close(done_pipe[0]);
        if (done_pipe[1] >= 0) posix.close(done_pipe[1]);
        if (master_fd >= 0) posix.close(master_fd);
        posix.kill(pid, posix.SIG.KILL) catch |err| {
            log.warn("failed to kill child after isolated spawn failure pid={d}: {}", .{ pid, err });
        };
    }

    fn findPaneUuid(extra_env: ?[]const [2][]const u8) ?[]const u8 {
        const extras = extra_env orelse return null;
        for (extras) |kv| {
            if (std.mem.eql(u8, kv[0], "HEXE_PANE_UUID")) return kv[1];
        }
        return null;
    }

    fn execFailureExitCode(err: anyerror) u8 {
        return switch (err) {
            error.FileNotFound => 127,
            error.AccessDenied, error.PermissionDenied, error.InvalidExe => 126,
            else => 126,
        };
    }

    fn execFailureReason(err: anyerror) []const u8 {
        return switch (err) {
            error.FileNotFound => "command not found",
            error.AccessDenied, error.PermissionDenied => "permission denied",
            error.InvalidExe => "not executable",
            else => @errorName(err),
        };
    }

    fn writeExecFailure(command: []const u8, err: anyerror) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "hexe: {s}: {s}\r\n", .{ command, execFailureReason(err) }) catch {
            const fallback = "hexe: failed to exec command\r\n";
            _ = posix.write(posix.STDERR_FILENO, fallback) catch 0;
            return;
        };
        _ = posix.write(posix.STDERR_FILENO, msg) catch 0;
    }

    fn extraEnvHasKey(extra_env: ?[]const [2][]const u8, key: []const u8) bool {
        const extras = extra_env orelse return false;
        for (extras) |kv| {
            if (std.mem.eql(u8, kv[0], key)) return true;
        }
        return false;
    }

    fn buildEnv(extra_env: ?[]const [2][]const u8) ![*:null]const ?[*:0]const u8 {
        const allocator = std.heap.c_allocator;
        var env_list: std.ArrayList(?[*:0]const u8) = .empty;

        var skip_keys: [24][]const u8 = undefined;
        var skip_count: usize = 0;
        skip_keys[skip_count] = "BOX";
        skip_count += 1;
        skip_keys[skip_count] = "TERM";
        skip_count += 1;
        // The child has already chdir'd, but an inherited PWD/OLDPWD still
        // names the directory the SES daemon was started in. Anything that
        // trusts $PWD over getcwd() — direnv, prompts, `hexe shp`, most build
        // wrappers — then acts on a foreign directory. Drop both and restate
        // PWD from the real cwd below; a fresh shell has no previous dir, so
        // OLDPWD is simply not set.
        skip_keys[skip_count] = "PWD";
        skip_count += 1;
        skip_keys[skip_count] = "OLDPWD";
        skip_count += 1;
        // Never hand the daemon's security opt-outs to a pane's shell
        // (PLAN.md A-8). These exist so an operator can loosen hexe's own
        // checks; inherited by every process a pane runs, they would silently
        // loosen them for anything that re-enters hexe from inside a pane —
        // including a `.hexe.lua` that would otherwise be sandboxed.
        for ([_][]const u8{
            "HEXE_TRUST_ALL_PROJECTS",
            "HEXE_ALLOW_CROSS_UID",
            "HEXE_UNRESTRICTED_CONFIG",
        }) |key| {
            skip_keys[skip_count] = key;
            skip_count += 1;
        }
        if (extra_env) |extras| {
            for (extras) |kv| {
                if (skip_count < skip_keys.len) {
                    skip_keys[skip_count] = kv[0];
                    skip_count += 1;
                }
            }
        }

        var i: usize = 0;
        outer: while (environ[i]) |env_ptr| : (i += 1) {
            const env_str = std.mem.span(env_ptr);
            for (skip_keys[0..skip_count]) |key| {
                if (std.mem.startsWith(u8, env_str, key) and env_str.len > key.len and env_str[key.len] == '=') {
                    continue :outer;
                }
            }
            try env_list.append(allocator, env_ptr);
        }

        try env_list.append(allocator, "BOX=1");
        try env_list.append(allocator, "TERM=xterm-256color");

        // Runs in the forked child after chdir and after any isolation has been
        // applied, so this is the directory the shell actually starts in.
        // Skipped when extra_env sets PWD itself — that is an explicit request.
        if (!extraEnvHasKey(extra_env, "PWD")) {
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (posix.getcwd(&cwd_buf)) |real_cwd| {
                const entry = try allocator.allocSentinel(u8, 4 + real_cwd.len, 0);
                @memcpy(entry[0..4], "PWD=");
                @memcpy(entry[4..][0..real_cwd.len], real_cwd);
                try env_list.append(allocator, entry.ptr);
            } else |_| {}
        }

        if (extra_env) |extras| {
            for (extras) |kv| {
                const len = kv[0].len + 1 + kv[1].len;
                const buf = try allocator.allocSentinel(u8, len, 0);
                @memcpy(buf[0..kv[0].len], kv[0]);
                buf[kv[0].len] = '=';
                @memcpy(buf[kv[0].len + 1 ..][0..kv[1].len], kv[1]);
                try env_list.append(allocator, buf.ptr);
            }
        }

        try env_list.append(allocator, null);

        const slice = try env_list.toOwnedSlice(allocator);
        return @ptrCast(slice.ptr);
    }

    fn closeExtraFds() void {
        const first_fd: usize = 3;
        const max_fd: usize = std.math.maxInt(u32);
        const result = linux.syscall3(.close_range, first_fd, max_fd, 0);
        const signed: isize = @bitCast(result);
        if (!(signed < 0 and signed > -4096)) return;
        // Fallback: close_range not available (pre-Linux 5.9). Walk up to the
        // actual RLIMIT_NOFILE so raised ulimits don't leak FDs >= 1024 to
        // the child shell.
        const limit = posix.getrlimit(.NOFILE) catch posix.rlimit{ .cur = 1024, .max = 1024 };
        const end_fd: usize = @intCast(limit.cur);
        var fd: usize = first_fd;
        while (fd < end_fd) : (fd += 1) {
            posix.close(@intCast(fd));
        }
    }

    pub fn read(self: Pty, buffer: []u8) !usize {
        return posix.read(self.master_fd, buffer);
    }

    pub fn write(self: Pty, data: []const u8) !usize {
        return posix.write(self.master_fd, data);
    }

    pub fn pollStatus(self: *Pty) ?u32 {
        if (self.child_reaped) return 0;
        if (self.external_process) return null;
        const result = posix.waitpid(self.child_pid, posix.W.NOHANG);
        if (result.pid == 0) return null;
        self.child_reaped = true;
        return result.status;
    }

    pub fn close(self: *Pty) void {
        _ = posix.close(self.master_fd);

        if (self.external_process) {
            return;
        }

        if (!self.child_reaped) {
            const result = posix.waitpid(self.child_pid, posix.W.NOHANG);
            if (result.pid != 0) {
                self.child_reaped = true;
                return;
            }

            _ = std.c.kill(self.child_pid, std.c.SIG.HUP);

            std.Thread.sleep(10 * std.time.ns_per_ms);
            const result2 = posix.waitpid(self.child_pid, posix.W.NOHANG);
            if (result2.pid != 0) {
                self.child_reaped = true;
                return;
            }

            _ = std.c.kill(self.child_pid, std.c.SIG.KILL);

            const kill_deadline_ms: i64 = std.time.milliTimestamp() + 250;
            while (true) {
                const r = posix.waitpid(self.child_pid, posix.W.NOHANG);
                if (r.pid != 0) {
                    self.child_reaped = true;
                    return;
                }
                if (std.time.milliTimestamp() >= kill_deadline_ms) {
                    return;
                }
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
        }
    }

    pub fn setSize(self: Pty, cols: u16, rows: u16) !void {
        var ws: c.winsize = .{
            .ws_col = cols,
            .ws_row = rows,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        if (c.ioctl(self.master_fd, c.TIOCSWINSZ, &ws) != 0) {
            return error.SetSizeFailed;
        }
    }

    pub fn getSize(self: Pty) !struct { cols: u16, rows: u16 } {
        var ws: c.winsize = undefined;
        if (c.ioctl(self.master_fd, c.TIOCGWINSZ, &ws) != 0) {
            return error.GetSizeFailed;
        }
        return .{ .cols = ws.ws_col, .rows = ws.ws_row };
    }
};

// Terminal size utilities
pub const TermSize = struct {
    cols: u16,
    rows: u16,

    pub fn fromStdout() TermSize {
        var ws: c.winsize = undefined;
        if (c.ioctl(posix.STDOUT_FILENO, c.TIOCGWINSZ, &ws) == 0) {
            return .{
                .cols = if (ws.ws_col > 0) ws.ws_col else 80,
                .rows = if (ws.ws_row > 0) ws.ws_row else 24,
            };
        }
        return .{ .cols = 80, .rows = 24 };
    }
};
