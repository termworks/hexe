const std = @import("std");
const cmd_mod = @import("../cmd.zig");
const Segment = @import("context.zig").Segment;
const Context = @import("context.zig").Context;
const Style = @import("../style.zig").Style;

// Starship-compatible icons
const ICON_CONFLICTED = "=";
const ICON_AHEAD = "⇡";
const ICON_BEHIND = "⇣";
const ICON_DIVERGED = "⇕";
const ICON_UNTRACKED = "?";
// NOTE: Avoid '$' here because most shells treat '$<n>' in prompts as
// parameter expansion (e.g. zsh expands $1). That can surface as weird
// strings like ".reset-prompt" depending on the shell state.
const ICON_STASHED = "≡";
const ICON_MODIFIED = "!";
const ICON_STAGED = "+";
const ICON_RENAMED = "»";
const ICON_DELETED = "✘";

// Cache for git status results (keyed by cwd hash, configurable TTL)
const GitStatusCache = struct {
    cwd_hash: u64,
    status: GitStatus,
    timestamp_ms: i64,
};

var git_status_cache: ?GitStatusCache = null;

/// Get cache TTL in milliseconds from environment variable or use default.
/// Default is 5000ms (5 seconds), configurable via HEXE_GIT_CACHE_TTL.
fn getCacheTTL() i64 {
    if (std.posix.getenv("HEXE_GIT_CACHE_TTL")) |ttl_str| {
        const ttl = std.fmt.parseInt(i64, ttl_str, 10) catch 5000;
        // Clamp to reasonable range: 500ms to 30s
        return @min(@max(ttl, 500), 30000);
    }
    return 5000; // Default: 5 seconds
}

fn hashCwd(cwd: []const u8) u64 {
    var h: u64 = 5381;
    for (cwd) |c| {
        h = ((h << 5) +% h) +% c;
    }
    return h;
}

/// Git status segment - displays git status indicators using starship icons
/// Format: ⇡1 ⇣2 +3 !4 ?5 (ahead, behind, staged, modified, untracked)
pub fn render(ctx: *Context) ?[]const Segment {
    const cwd = if (ctx.cwd.len > 0) ctx.cwd else std.posix.getenv("PWD") orelse return null;

    // Check if we're in a git repo
    if (!isGitRepo(cwd)) return null;

    const now = std.time.milliTimestamp();
    const cwd_hash = hashCwd(cwd);

    // Check cache with configurable TTL
    var status = GitStatus{};
    const cache_ttl = getCacheTTL();
    if (git_status_cache) |cached| {
        if (cached.cwd_hash == cwd_hash and (now - cached.timestamp_ms) < cache_ttl) {
            status = cached.status;
        } else {
            runGitStatus(cwd, &status);
            git_status_cache = .{ .cwd_hash = cwd_hash, .status = status, .timestamp_ms = now };
        }
    } else {
        runGitStatus(cwd, &status);
        git_status_cache = .{ .cwd_hash = cwd_hash, .status = status, .timestamp_ms = now };
    }

    if (status.isEmpty()) return null;

    // Build status string with starship icons
    var text_buf: [128]u8 = undefined;
    var text_len: usize = 0;

    // Ahead/behind
    if (status.ahead > 0 and status.behind > 0) {
        // Diverged
        const written = std.fmt.bufPrint(text_buf[text_len..], ICON_DIVERGED ++ "{d}/{d}", .{ status.ahead, status.behind }) catch return null;
        text_len += written.len;
    } else if (status.ahead > 0) {
        const written = std.fmt.bufPrint(text_buf[text_len..], ICON_AHEAD ++ "{d}", .{status.ahead}) catch return null;
        text_len += written.len;
    } else if (status.behind > 0) {
        const written = std.fmt.bufPrint(text_buf[text_len..], ICON_BEHIND ++ "{d}", .{status.behind}) catch return null;
        text_len += written.len;
    }

    // Conflicted
    if (status.conflicts > 0) {
        if (text_len > 0) text_buf[text_len] = ' ';
        if (text_len > 0) text_len += 1;
        const written = std.fmt.bufPrint(text_buf[text_len..], ICON_CONFLICTED ++ "{d}", .{status.conflicts}) catch return null;
        text_len += written.len;
    }

    // Stashed
    if (status.stashed > 0) {
        if (text_len > 0) text_buf[text_len] = ' ';
        if (text_len > 0) text_len += 1;
        const written = std.fmt.bufPrint(text_buf[text_len..], ICON_STASHED ++ "{d}", .{status.stashed}) catch return null;
        text_len += written.len;
    }

    // Staged changes
    if (status.staged > 0) {
        if (text_len > 0) text_buf[text_len] = ' ';
        if (text_len > 0) text_len += 1;
        const written = std.fmt.bufPrint(text_buf[text_len..], ICON_STAGED ++ "{d}", .{status.staged}) catch return null;
        text_len += written.len;
    }

    // Modified (unstaged)
    if (status.modified > 0) {
        if (text_len > 0) text_buf[text_len] = ' ';
        if (text_len > 0) text_len += 1;
        const written = std.fmt.bufPrint(text_buf[text_len..], ICON_MODIFIED ++ "{d}", .{status.modified}) catch return null;
        text_len += written.len;
    }

    // Deleted
    if (status.deleted > 0) {
        if (text_len > 0) text_buf[text_len] = ' ';
        if (text_len > 0) text_len += 1;
        const written = std.fmt.bufPrint(text_buf[text_len..], ICON_DELETED ++ "{d}", .{status.deleted}) catch return null;
        text_len += written.len;
    }

    // Renamed
    if (status.renamed > 0) {
        if (text_len > 0) text_buf[text_len] = ' ';
        if (text_len > 0) text_len += 1;
        const written = std.fmt.bufPrint(text_buf[text_len..], ICON_RENAMED ++ "{d}", .{status.renamed}) catch return null;
        text_len += written.len;
    }

    // Untracked
    if (status.untracked > 0) {
        if (text_len > 0) text_buf[text_len] = ' ';
        if (text_len > 0) text_len += 1;
        const written = std.fmt.bufPrint(text_buf[text_len..], ICON_UNTRACKED ++ "{d}", .{status.untracked}) catch return null;
        text_len += written.len;
    }

    if (text_len == 0) return null;

    const text = ctx.allocText(text_buf[0..text_len]) catch return null;

    // Color based on status: red if conflicts, yellow if dirty, green if only staged
    const style = if (status.conflicts > 0)
        Style.parse("bold fg:red")
    else if (status.modified > 0 or status.untracked > 0 or status.deleted > 0)
        Style.parse("fg:yellow")
    else
        Style.parse("fg:green");

    return ctx.addSegment(text, style) catch return null;
}

const GitStatus = struct {
    staged: u16 = 0,
    modified: u16 = 0,
    untracked: u16 = 0,
    conflicts: u16 = 0,
    deleted: u16 = 0,
    renamed: u16 = 0,
    ahead: u16 = 0,
    behind: u16 = 0,
    stashed: u16 = 0,

    fn isEmpty(self: GitStatus) bool {
        return self.staged == 0 and self.modified == 0 and self.untracked == 0 and
            self.conflicts == 0 and self.deleted == 0 and self.renamed == 0 and
            self.ahead == 0 and self.behind == 0 and self.stashed == 0;
    }
};

fn isGitRepo(cwd: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var current: []const u8 = cwd;

    // Walk up directory tree looking for .git
    while (current.len > 0) {
        const git_path = std.fmt.bufPrint(&path_buf, "{s}/.git", .{current}) catch return false;

        // Check if .git directory or file exists
        if (std.fs.cwd().access(git_path, .{})) |_| {
            return true;
        } else |_| {}

        if (std.fs.openFileAbsolute(git_path, .{})) |file| {
            file.close();
            return true;
        } else |_| {}

        // Move up one directory level
        if (std.mem.lastIndexOfScalar(u8, current, '/')) |idx| {
            if (idx == 0) {
                // Reached root, check /.git as final attempt
                if (std.fs.cwd().access("/.git", .{})) |_| {
                    return true;
                } else |_| {}
                return false;
            }
            current = current[0..idx];
        } else {
            // No more parent directories
            return false;
        }
    }

    return false;
}

fn runGitStatus(cwd: []const u8, status: *GitStatus) void {
    const alloc = std.heap.page_allocator;

    // Run git status --porcelain=v2 --branch
    // BOUNDED: git in a huge/locked repo (or on a slow filesystem) used to
    // block the render loop until it finished.
    const stdout = cmd_mod.runArgvCaptured(
        alloc,
        &.{ "git", "--no-optional-locks", "-C", cwd, "status", "--porcelain=v2", "--branch" },
        64 * 1024,
        cmd_mod.DEFAULT_TIMEOUT_MS,
    ) orelse return;
    defer alloc.free(stdout);
    const result = .{ .stdout = stdout };
    const exit_ok = true; // runArgvCaptured returns null unless the command exited 0
    if (!exit_ok) return;

    // Parse output
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Branch info: # branch.ab +<ahead> -<behind>
        if (std.mem.startsWith(u8, line, "# branch.ab ")) {
            parseAheadBehind(line[12..], status);
        }
        // Changed entry (porcelain v2 format)
        else if (line[0] == '1') {
            // Ordinary change: 1 XY ...
            if (line.len > 2) {
                parseChangeStatus(line[2..4], status);
            }
        } else if (line[0] == '2') {
            // Rename/copy: 2 XY ...
            status.renamed += 1;
            if (line.len > 2) {
                parseChangeStatus(line[2..4], status);
            }
        } else if (line[0] == 'u') {
            // Unmerged (conflict)
            status.conflicts += 1;
        } else if (line[0] == '?') {
            // Untracked
            status.untracked += 1;
        } else if (line[0] == '!') {
            // Ignored - skip
        }
    }

    // Check for stashes
    checkStash(cwd, status);
}

fn parseAheadBehind(s: []const u8, status: *GitStatus) void {
    // Format: +<ahead> -<behind>
    var parts = std.mem.splitScalar(u8, s, ' ');
    if (parts.next()) |ahead_str| {
        if (ahead_str.len > 1 and ahead_str[0] == '+') {
            status.ahead = std.fmt.parseInt(u16, ahead_str[1..], 10) catch 0;
        }
    }
    if (parts.next()) |behind_str| {
        if (behind_str.len > 1 and behind_str[0] == '-') {
            status.behind = std.fmt.parseInt(u16, behind_str[1..], 10) catch 0;
        }
    }
}

fn parseChangeStatus(xy: []const u8, status: *GitStatus) void {
    if (xy.len < 2) return;
    const index_status = xy[0];
    const worktree_status = xy[1];

    // Index changes (staged)
    switch (index_status) {
        'A', 'M', 'T' => status.staged += 1,
        'D' => status.deleted += 1,
        'R' => status.renamed += 1,
        else => {},
    }

    // Worktree changes (modified/deleted)
    switch (worktree_status) {
        'M', 'T' => status.modified += 1,
        'D' => status.deleted += 1,
        else => {},
    }
}

fn checkStash(cwd: []const u8, status: *GitStatus) void {
    const alloc = std.heap.page_allocator;

    const stdout = cmd_mod.runArgvCaptured(
        alloc,
        &.{ "git", "-C", cwd, "stash", "list" },
        16 * 1024,
        cmd_mod.DEFAULT_TIMEOUT_MS,
    ) orelse return;
    defer alloc.free(stdout);
    const result = .{ .stdout = stdout };

    // Count lines
    var count: u16 = 0;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }
    status.stashed = count;
}
