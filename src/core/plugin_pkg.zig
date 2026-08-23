//! Plugins as packages, not command strings.
//!
//! A plugin used to be a line in your config naming a shell command, which put
//! the plugin's own wiring -- its keybindings, its glue, its arguments -- into
//! the user's file. Install one and you were pasting somebody's shell snippet;
//! remove it and you were hunting for the lines to delete.
//!
//! A package is a directory instead:
//!
//!     ~/.local/share/hexe/plugins/<name>/
//!         plugin.lua   what it is and what it needs
//!         init.lua     what it does, in Lua, against hexe's own API
//!
//! `plugin.lua` is read in an interpreter with **no `hexe` in it**, so hexe can
//! see what a plugin asks for before deciding whether to run any of it. That
//! ordering is the whole point of splitting the manifest from the body.
//!
//! Trust is the existing ledger: the directory is hashed at install, and hexe
//! refuses to run a plugin whose files changed until `hexe plugin allow` says
//! otherwise -- the same rule `.hexe.lua` already lives under.

const std = @import("std");
const posix = std.posix;

const trust = @import("trust.zig");
const access = @import("access.zig");
const logging = @import("logging.zig");

pub const MANIFEST = "plugin.lua";
pub const DEFAULT_ENTRY = "init.lua";

/// A name is a directory name, so it is held to the same rule as a pane name:
/// no separators, no traversal, nothing that stops being one path component.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (name[0] == '.' or name[0] == '-') return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

pub const Manifest = struct {
    name: []const u8,
    version: []const u8 = "",
    description: []const u8 = "",
    /// Lua file run inside hexe's runtime.
    entry: []const u8 = DEFAULT_ENTRY,
    /// A helper process hexe starts for it, if it needs one. Optional: a plugin
    /// that is only Lua needs no process at all.
    command: []const u8 = "",
    granted: access.Set = access.Set.baseline,

    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.version.len > 0) allocator.free(self.version);
        if (self.description.len > 0) allocator.free(self.description);
        allocator.free(self.entry);
        if (self.command.len > 0) allocator.free(self.command);
        self.* = undefined;
    }
};

pub fn pluginsDir(allocator: std.mem.Allocator) ![]u8 {
    if (posix.getenv("XDG_DATA_HOME")) |xdg| {
        return std.fmt.allocPrint(allocator, "{s}/hexe/plugins", .{xdg});
    }
    const home = posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.local/share/hexe/plugins", .{home});
}

pub fn pluginPath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const dir = try pluginsDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
}

/// Hash of everything hexe would run: the manifest and the entry together.
///
/// Both, because either one alone can change what the plugin does -- a manifest
/// that quietly widens `access` is exactly as much a change as a rewritten
/// `init.lua`, and trusting one without the other would miss it.
pub fn packageBytes(allocator: std.mem.Allocator, dir: []const u8, entry: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const names = [_][]const u8{ MANIFEST, entry };
    for (names) |file| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, file });
        defer allocator.free(path);
        const contents = std.fs.cwd().readFileAlloc(allocator, path, 1 << 20) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(contents);
        try buf.appendSlice(allocator, file);
        try buf.appendSlice(allocator, contents);
    }
    return buf.toOwnedSlice(allocator);
}

/// Read `plugin.lua` in a bare interpreter and return what it declares.
///
/// Bare on purpose: the manifest is evaluated with no `hexe` in scope, so
/// reading what a plugin *asks for* cannot itself be the thing that runs it.
/// A manifest that tries to touch hexe fails here rather than later.
pub fn readManifest(allocator: std.mem.Allocator, name: []const u8) !Manifest {
    const zlua = @import("zlua");
    const dir = try pluginPath(allocator, name);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, MANIFEST });
    defer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var lua = try zlua.Lua.init(allocator);
    defer lua.deinit();
    lua.openLibs();

    lua.loadFile(path_z, .text) catch return error.BadManifest;
    lua.protectedCall(.{ .args = 0, .results = 1 }) catch return error.BadManifest;
    if (lua.typeOf(-1) != .table) return error.BadManifest;

    var out = Manifest{ .name = try allocator.dupe(u8, name), .entry = try allocator.dupe(u8, DEFAULT_ENTRY) };
    errdefer out.deinit(allocator);

    // Assigned, never freed first: the default is a comptime literal in
    // rodata, and handing that to the allocator is the "incorrect alignment"
    // panic this codebase has already been bitten by twice.
    if (readField(allocator, lua, "version")) |v| out.version = v;
    if (readField(allocator, lua, "description")) |v| out.description = v;
    if (readField(allocator, lua, "entry")) |v| {
        allocator.free(out.entry);
        out.entry = v;
    }
    if (readField(allocator, lua, "command")) |v| out.command = v;

    // `access = { "stream", "popup" }`
    if (lua.getField(-1, "access") == .table) {
        var granted = access.Set{};
        const n = lua.rawLen(-1);
        var i: i32 = 1;
        while (i <= @as(i32, @intCast(n))) : (i += 1) {
            _ = lua.rawGetIndex(-1, i);
            defer lua.pop(1);
            const word = lua.toString(-1) catch continue;
            if (access.Kind.parse(word)) |kind| granted = granted.with(kind);
        }
        out.granted = granted.merge(access.Set.baseline);
    }
    lua.pop(1);

    return out;
}

fn readField(allocator: std.mem.Allocator, lua: anytype, key: [:0]const u8) ?[]const u8 {
    defer lua.pop(1);
    if (lua.getField(-1, key) != .string) return null;
    const text = lua.toString(-1) catch return null;
    if (text.len == 0) return null;
    return allocator.dupe(u8, text) catch null;
}

/// Copy a plugin directory into place.
///
/// Copied rather than symlinked so that what hexe runs is what was reviewed:
/// a link would let the source change under an approval that was given once.
pub fn install(allocator: std.mem.Allocator, source: []const u8, name: []const u8) !void {
    if (!validName(name)) return error.InvalidName;

    const dest = try pluginPath(allocator, name);
    defer allocator.free(dest);

    std.fs.cwd().deleteTree(dest) catch {};
    if (std.fs.path.dirname(dest)) |parent| std.fs.cwd().makePath(parent) catch {};

    var src_dir = try std.fs.cwd().openDir(source, .{ .iterate = true });
    defer src_dir.close();
    try std.fs.cwd().makePath(dest);
    var dst_dir = try std.fs.cwd().openDir(dest, .{});
    defer dst_dir.close();

    var it = src_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        try src_dir.copyFile(entry.name, dst_dir, entry.name, .{});
    }
}

pub fn remove(allocator: std.mem.Allocator, name: []const u8) !void {
    if (!validName(name)) return error.InvalidName;
    const dir = try pluginPath(allocator, name);
    defer allocator.free(dir);
    try std.fs.cwd().deleteTree(dir);
}

/// Installed plugin names, sorted. Caller frees each and the slice.
pub fn list(allocator: std.mem.Allocator) ![][]u8 {
    const dir_path = try pluginsDir(allocator);
    defer allocator.free(dir_path);

    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |n| allocator.free(n);
        out.deinit(allocator);
    }

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return try out.toOwnedSlice(allocator),
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (!validName(entry.name)) continue;
        try out.append(allocator, try allocator.dupe(u8, entry.name));
    }

    const items = try out.toOwnedSlice(allocator);
    std.mem.sort([]u8, items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return items;
}

/// Whether the package still hashes to what was approved.
pub fn isTrusted(allocator: std.mem.Allocator, name: []const u8, entry: []const u8) bool {
    const dir = pluginPath(allocator, name) catch return false;
    defer allocator.free(dir);
    const bytes = packageBytes(allocator, dir, entry) catch return false;
    defer allocator.free(bytes);

    // Keyed on the manifest's path, so one plugin is one ledger entry and the
    // existing `.hexe.lua` machinery needs no second concept.
    const key = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, MANIFEST }) catch return false;
    defer allocator.free(key);
    return trust.bytesAreTrustedAt(allocator, key, bytes);
}

/// Record the package's current contents as approved.
pub fn allow(allocator: std.mem.Allocator, name: []const u8, entry: []const u8) !void {
    const dir = try pluginPath(allocator, name);
    defer allocator.free(dir);
    const bytes = try packageBytes(allocator, dir, entry);
    defer allocator.free(bytes);

    const key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, MANIFEST });
    defer allocator.free(key);
    try trust.allowBytesAt(allocator, key, bytes);
}

test "a name has to stay one path component" {
    try std.testing.expect(validName("drop"));
    try std.testing.expect(validName("share-web_2"));
    try std.testing.expect(!validName("../etc"));
    try std.testing.expect(!validName("a/b"));
    try std.testing.expect(!validName(".hidden"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("Caps"));
}
