//! Project `.hexe.lua` command trust ledger (PLAN.md 1.9).
//!
//! A project-local `.hexe.lua` can carry `on_start`/`on_stop` shell hooks that
//! run automatically when a session opens in that directory — the direnv
//! auto-trust hazard. This ledger gates those hooks: a `.hexe.lua` is only
//! honored once its *content hash* has been explicitly recorded via
//! `hexe allow`. Editing the file invalidates trust (hash changes), so a
//! compromised repo can't silently swap in new commands after being allowed.
//!
//! Ledger lines are `<sha256-hex>\t<realpath>` (PLAN.md A-8). Binding the hash
//! to a path matters because a bare hash trusts CONTENT anywhere: allowing one
//! repo's `.hexe.lua` would silently bless a byte-identical file in any other
//! checkout you happen to open. Legacy bare-hash lines are NOT honoured — that
//! would leave the hole open — but they are detected, so the user is told to
//! re-run `hexe allow` instead of silently losing their hooks.
//!
//! Historically = one lowercase hex SHA-256 per line at
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

/// Lowercase-hex SHA-256 of an in-memory buffer.
pub fn hashBytes(bytes: []const u8) [HASH_HEX_LEN]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Canonical absolute path, so the same file cannot be bound twice under
/// different spellings (`./x`, `../dir/x`, a symlink). Caller frees.
fn realPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().realpathAlloc(allocator, path);
}

/// Does `line` grant trust for (hash, real_path)?
///
/// Returns `.match` only for a path-qualified line naming this exact file.
/// `.legacy_hash_only` flags a pre-A-8 bare-hash line whose content matches —
/// deliberately NOT trusted, but reported so the caller can tell the user to
/// re-run `hexe allow` rather than leaving them wondering why their hooks
/// stopped firing.
const LineVerdict = enum { no_match, match, legacy_hash_only };

fn classifyLine(line: []const u8, hash: []const u8, real_path: []const u8) LineVerdict {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return .no_match;

    if (std.mem.indexOfScalar(u8, trimmed, '\t')) |tab| {
        const line_hash = std.mem.trim(u8, trimmed[0..tab], " ");
        const line_path = std.mem.trim(u8, trimmed[tab + 1 ..], " ");
        if (std.mem.eql(u8, line_hash, hash) and std.mem.eql(u8, line_path, real_path)) return .match;
        return .no_match;
    }

    // No tab: a legacy bare-hash entry.
    if (std.mem.eql(u8, trimmed, hash)) return .legacy_hash_only;
    return .no_match;
}

fn lookup(allocator: std.mem.Allocator, hash: []const u8, path: []const u8) bool {
    const real_path = realPathAlloc(allocator, path) catch return false;
    defer allocator.free(real_path);

    const ledger = ledgerPath(allocator) catch return false;
    defer allocator.free(ledger);
    const contents = std.fs.cwd().readFileAlloc(allocator, ledger, 4 * 1024 * 1024) catch return false;
    defer allocator.free(contents);

    var saw_legacy = false;
    var it = std.mem.tokenizeScalar(u8, contents, '\n');
    while (it.next()) |line| {
        switch (classifyLine(line, hash, real_path)) {
            .match => return true,
            .legacy_hash_only => saw_legacy = true,
            .no_match => {},
        }
    }
    if (saw_legacy) {
        std.log.scoped(.trust).warn(
            "{s} matches a legacy (path-less) trust entry; re-run `hexe allow` on it to restore its hooks",
            .{real_path},
        );
    }
    return false;
}

/// Whether these exact bytes, AT THIS PATH, are trusted.
///
/// Prefer this over `isTrusted` wherever the caller already holds the content
/// it is about to act on: re-reading the path to hash it is a TOCTOU window in
/// which an attacker with write access to the working tree can present one file
/// for execution and another for verification.
pub fn bytesAreTrustedAt(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) bool {
    return lookup(allocator, &hashBytes(bytes), path);
}

/// Whether `path`'s current content hash is recorded for `path`. Any I/O error
/// (missing ledger, unreadable file) is treated as NOT trusted — the safe
/// default is to withhold command execution.
pub fn isTrusted(allocator: std.mem.Allocator, path: []const u8) bool {
    const hash = hashFile(allocator, path) catch return false;
    return lookup(allocator, &hash, path);
}

/// Record `path`'s current content hash in the ledger (idempotent). Creates the
/// ledger directory and file as needed.
pub fn allow(allocator: std.mem.Allocator, path: []const u8) !void {
    if (isTrusted(allocator, path)) return;
    try recordHash(allocator, path, &try hashFile(allocator, path));
}

/// Record a hash the caller computed, against `path`.
///
/// The symmetric half of `bytesAreTrustedAt`: a caller whose unit of trust is
/// not one file on disk -- a plugin package is a manifest plus an entry -- has
/// to be able to approve what it actually checked, or the two halves would
/// disagree about what was approved.
pub fn allowBytesAt(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const hash = hashBytes(bytes);
    if (lookup(allocator, &hash, path)) return;
    try recordHash(allocator, path, &hash);
}

fn recordHash(allocator: std.mem.Allocator, path: []const u8, hash: []const u8) !void {
    const ledger = try ledgerPath(allocator);
    defer allocator.free(ledger);
    if (std.fs.path.dirname(ledger)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const real_path = try realPathAlloc(allocator, path);
    defer allocator.free(real_path);

    var file = try std.fs.cwd().createFile(ledger, .{ .truncate = false, .read = false, .mode = 0o600 });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(hash);
    try file.writeAll("\t");
    try file.writeAll(real_path);
    try file.writeAll("\n");
}

test "trust ledger: trust does not follow identical content to another path" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);

    const ledger = try std.fmt.allocPrint(testing.allocator, "{s}/trust", .{base});
    defer testing.allocator.free(ledger);
    const prev_ledger = std.posix.getenv("HEXE_TRUST_LEDGER");
    setenvForTest("HEXE_TRUST_LEDGER", ledger);
    defer restoreEnvForTest("HEXE_TRUST_LEDGER", prev_ledger);

    const body = "return { on_start = 'echo hi' }\n";
    const allowed = try std.fmt.allocPrint(testing.allocator, "{s}/allowed.lua", .{base});
    defer testing.allocator.free(allowed);
    const copy = try std.fmt.allocPrint(testing.allocator, "{s}/copy.lua", .{base});
    defer testing.allocator.free(copy);
    try tmp.dir.writeFile(.{ .sub_path = "allowed.lua", .data = body });
    try tmp.dir.writeFile(.{ .sub_path = "copy.lua", .data = body });

    try allow(testing.allocator, allowed);

    // The blessed file is trusted...
    try testing.expect(isTrusted(testing.allocator, allowed));
    // ...but a byte-identical file elsewhere is NOT. This is the whole point of
    // A-8: a bare content hash would bless every copy in every checkout.
    try testing.expect(!isTrusted(testing.allocator, copy));
    try testing.expect(!bytesAreTrustedAt(testing.allocator, copy, body));
    // And the blessed path still verifies through the byte-based entry point.
    try testing.expect(bytesAreTrustedAt(testing.allocator, allowed, body));
}

test "trust ledger: a legacy path-less entry does not grant trust" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);

    const ledger = try std.fmt.allocPrint(testing.allocator, "{s}/trust", .{base});
    defer testing.allocator.free(ledger);
    const prev_ledger = std.posix.getenv("HEXE_TRUST_LEDGER");
    setenvForTest("HEXE_TRUST_LEDGER", ledger);
    defer restoreEnvForTest("HEXE_TRUST_LEDGER", prev_ledger);

    const body = "return {}\n";
    try tmp.dir.writeFile(.{ .sub_path = "p.lua", .data = body });
    const p_path = try std.fmt.allocPrint(testing.allocator, "{s}/p.lua", .{base});
    defer testing.allocator.free(p_path);

    // Write a pre-A-8 ledger: bare hash, no path.
    const h = hashBytes(body);
    const legacy = try std.fmt.allocPrint(testing.allocator, "{s}\n", .{h});
    defer testing.allocator.free(legacy);
    try tmp.dir.writeFile(.{ .sub_path = "trust", .data = legacy });

    // Content matches, but the entry is not bound to this path: withhold trust
    // rather than grandfather the hole open.
    try testing.expect(!isTrusted(testing.allocator, p_path));

    // Re-allowing restores it.
    try allow(testing.allocator, p_path);
    try testing.expect(isTrusted(testing.allocator, p_path));
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
// Declared against libc directly: `std.c` does not re-export setenv/unsetenv,
// which is why this file's tests never compiled until it was imported into a
// test target.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

pub fn setenvForTest(name: [*:0]const u8, value: []const u8) void {
    var buf: [512]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{value}) catch return;
    _ = setenv(name, z.ptr, 1);
}
pub fn restoreEnvForTest(name: [*:0]const u8, prev: ?[]const u8) void {
    if (prev) |p| {
        setenvForTest(name, p);
    } else {
        _ = unsetenv(name);
    }
}
