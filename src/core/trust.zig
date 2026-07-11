//! Project `.hexe.lua` command trust ledger (PLAN.md 1.9).
//!
//! A project-local `.hexe.lua` can carry `on_start`/`on_stop` shell hooks that
//! run automatically when a session opens in that directory — the direnv
//! auto-trust hazard. This ledger gates those hooks: a `.hexe.lua` is only
//! honored once its *content hash* has been explicitly recorded via
//! `hexe allow`. Editing the file invalidates trust (hash changes), so a
//! compromised repo can't silently swap in new commands after being allowed.
//!
//! Ledger = one lowercase hex SHA-256 per line at
//! `$XDG_STATE_HOME/hexe/trust` (fallback `~/.local/state/hexe/trust`),
//! overridable with `$HEXE_TRUST_LEDGER` (used by tests).

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const HASH_HEX_LEN = Sha256.digest_length * 2;

/// Resolve the trust-ledger file path (caller frees).
pub fn ledgerPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("HEXE_TRUST_LEDGER")) |override| {
        return allocator.dupe(u8, override);
    }
    if (std.posix.getenv("XDG_STATE_HOME")) |state_home| {
        if (state_home.len > 0) return std.fmt.allocPrint(allocator, "{s}/hexe/trust", .{state_home});
    }
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    return std.fmt.allocPrint(allocator, "{s}/.local/state/hexe/trust", .{home});
}

/// Compute the lowercase-hex SHA-256 of a file's contents.
pub fn hashFile(allocator: std.mem.Allocator, path: []const u8) ![HASH_HEX_LEN]u8 {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 8 * 1024 * 1024);
    defer allocator.free(bytes);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Whether `path`'s current content hash is recorded in the ledger. Any I/O
/// error (missing ledger, unreadable file) is treated as NOT trusted — the
/// safe default is to withhold command execution.
pub fn isTrusted(allocator: std.mem.Allocator, path: []const u8) bool {
    const hash = hashFile(allocator, path) catch return false;
    const ledger = ledgerPath(allocator) catch return false;
    defer allocator.free(ledger);
    const contents = std.fs.cwd().readFileAlloc(allocator, ledger, 4 * 1024 * 1024) catch return false;
    defer allocator.free(contents);
    var it = std.mem.tokenizeScalar(u8, contents, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), &hash)) return true;
    }
    return false;
}

/// Record `path`'s current content hash in the ledger (idempotent). Creates the
/// ledger directory and file as needed.
pub fn allow(allocator: std.mem.Allocator, path: []const u8) !void {
    const hash = try hashFile(allocator, path);
    if (isTrusted(allocator, path)) return;

    const ledger = try ledgerPath(allocator);
    defer allocator.free(ledger);
    if (std.fs.path.dirname(ledger)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    var file = try std.fs.cwd().createFile(ledger, .{ .truncate = false, .read = false, .mode = 0o600 });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(&hash);
    try file.writeAll("\n");
}

test "trust ledger: allow makes a file trusted; edits invalidate it" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Point the ledger at a temp path for this test.
    var ledger_buf: [512]u8 = undefined;
    const real_ledger = try tmp.dir.realpath(".", &ledger_buf);
    const ledger_path = try std.fmt.allocPrint(testing.allocator, "{s}/trust", .{real_ledger});
    defer testing.allocator.free(ledger_path);
    const prev = std.posix.getenv("HEXE_TRUST_LEDGER");
    setenvForTest("HEXE_TRUST_LEDGER", ledger_path);
    defer restoreEnvForTest("HEXE_TRUST_LEDGER", prev);

    // A project config file inside the temp dir.
    try tmp.dir.writeFile(.{ .sub_path = "proj.lua", .data = "on_start = { 'echo hi' }\n" });
    const cfg_path = try std.fmt.allocPrint(testing.allocator, "{s}/proj.lua", .{real_ledger});
    defer testing.allocator.free(cfg_path);

    try testing.expect(!isTrusted(testing.allocator, cfg_path));
    try allow(testing.allocator, cfg_path);
    try testing.expect(isTrusted(testing.allocator, cfg_path));
    try allow(testing.allocator, cfg_path); // idempotent

    // Editing the file breaks trust (content hash changes).
    try tmp.dir.writeFile(.{ .sub_path = "proj.lua", .data = "on_start = { 'rm -rf /' }\n" });
    try testing.expect(!isTrusted(testing.allocator, cfg_path));
}

// Minimal setenv shims for the test (std has no cross-call setenv wrapper).
fn setenvForTest(name: [*:0]const u8, value: []const u8) void {
    var buf: [512]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{value}) catch return;
    _ = std.c.setenv(name, z.ptr, 1);
}
fn restoreEnvForTest(name: [*:0]const u8, prev: ?[]const u8) void {
    if (prev) |p| {
        setenvForTest(name, p);
    } else {
        _ = std.c.unsetenv(name);
    }
}
