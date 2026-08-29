//! Where hexe looks for Lua: a path of roots, not a directory.
//!
//! This is neovim's model, because a person arriving at hexe has probably
//! already learned it and deviating buys nothing. An ordered list of roots, each
//! with the same layout inside:
//!
//!     <root>/plugin/**/*.lua    run at startup, alphabetically
//!     <root>/lua/               modules for `require`, never run on their own
//!     <root>/after/plugin/      run after everything else
//!
//! The list, in the order it is read:
//!
//!     ~/.config/hexe                    yours
//!     /etc/xdg/hexe                     the system's
//!     ~/.local/share/hexe/site          where packages install
//!       + site/pack/*/start/*           each one, as its own root
//!     ~/.local/share/hexe/runtime       hexe's own
//!     …/after                           the same list, reversed
//!
//! Three things the list buys that one scanned directory does not. hexe ships
//! its own Lua the same way you ship yours, so there is no special case for
//! built-ins. A package is just another root, so installing one is putting a
//! directory in place rather than a command hexe has to grow. And order is a
//! feature: later roots override earlier ones, and `after/` exists to be last.
//!
//! **`plugin/` runs and `lua/` is required.** A tool that runs everything it
//! finds leaves a plugin author nowhere to keep a helper, and every helper then
//! has to defend itself against running twice.
//!
//! Nothing here asks permission. What is on the path runs, because somebody put
//! it there -- see `docs/plugins.md`.

const std = @import("std");
const posix = std.posix;

/// The subdirectory whose files are run, and the one that is only required.
pub const RUN_DIR = "plugin";
pub const LUA_DIR = "lua";
pub const AFTER_DIR = "after";

/// How deep `plugin/**` is walked, and how many files may be run. Bounded
/// because the path reaches directories hexe does not own.
const MAX_DEPTH: usize = 8;
const MAX_FILES: usize = 512;

pub const Root = struct {
    path: []u8,
    /// An `after` root: same layout, read last.
    after: bool = false,
};

pub fn deinitRoots(allocator: std.mem.Allocator, list: []Root) void {
    for (list) |r| allocator.free(r.path);
    allocator.free(list);
}

fn configHome(allocator: std.mem.Allocator) ![]u8 {
    if (posix.getenv("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0) return std.fmt.allocPrint(allocator, "{s}/hexe", .{xdg});
    }
    const home = posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/hexe", .{home});
}

fn dataHome(allocator: std.mem.Allocator) ![]u8 {
    if (posix.getenv("XDG_DATA_HOME")) |xdg| {
        if (xdg.len > 0) return std.fmt.allocPrint(allocator, "{s}/hexe", .{xdg});
    }
    const home = posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.local/share/hexe", .{home});
}

/// Where `hexe`'s own Lua lives, and where a package installs to.
pub fn siteDir(allocator: std.mem.Allocator) ![]u8 {
    const data = try dataHome(allocator);
    defer allocator.free(data);
    return std.fmt.allocPrint(allocator, "{s}/site", .{data});
}

pub fn runtimeDir(allocator: std.mem.Allocator) ![]u8 {
    const data = try dataHome(allocator);
    defer allocator.free(data);
    return std.fmt.allocPrint(allocator, "{s}/runtime", .{data});
}

/// Every root, in the order they are read.
///
/// The `after` half is the first half reversed, so the root that comes first --
/// yours -- also gets the last word. That is what makes `after/` an override
/// seam rather than just another place to put files.
pub fn roots(allocator: std.mem.Allocator) ![]Root {
    var head: std.ArrayList([]u8) = .empty;
    defer {
        for (head.items) |p| allocator.free(p);
        head.deinit(allocator);
    }

    if (configHome(allocator)) |p| try head.append(allocator, p) else |_| {}
    try head.append(allocator, try allocator.dupe(u8, "/etc/xdg/hexe"));

    const site = siteDir(allocator) catch null;
    if (site) |s| {
        try head.append(allocator, s);
        try appendPackages(allocator, &head, s);
    }
    if (runtimeDir(allocator)) |p| try head.append(allocator, p) else |_| {}

    var out: std.ArrayList(Root) = .empty;
    errdefer {
        for (out.items) |r| allocator.free(r.path);
        out.deinit(allocator);
    }
    for (head.items) |p| {
        try out.append(allocator, .{ .path = try allocator.dupe(u8, p) });
    }
    var i = head.items.len;
    while (i > 0) {
        i -= 1;
        const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ head.items[i], AFTER_DIR });
        try out.append(allocator, .{ .path = p, .after = true });
    }
    return out.toOwnedSlice(allocator);
}

/// `pack/<any>/start/<plugin>` under a site directory, each added as a root.
///
/// The `<any>` level lets a person group what they installed -- by where it came
/// from, by what it is for -- without hexe having an opinion about the grouping.
/// A plugin is laid out exactly like a config root, so one can be developed
/// beside your `init.lua` and moved into a package later without being edited.
fn appendPackages(allocator: std.mem.Allocator, head: *std.ArrayList([]u8), site: []const u8) !void {
    const pack = try std.fmt.allocPrint(allocator, "{s}/pack", .{site});
    defer allocator.free(pack);

    const groups = sortedEntries(allocator, pack, .directory) catch return;
    defer freeNames(allocator, groups);

    for (groups) |group| {
        const start = try std.fmt.allocPrint(allocator, "{s}/{s}/start", .{ pack, group });
        defer allocator.free(start);
        const names = sortedEntries(allocator, start, .directory) catch continue;
        defer freeNames(allocator, names);
        for (names) |name| {
            try head.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ start, name }));
        }
    }
}

fn freeNames(allocator: std.mem.Allocator, names: [][]u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}

fn lessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Names of one kind in a directory, sorted.
///
/// Sorted because directory order is filesystem order: it differs between
/// machines and changes after a reinstall, so an unsorted walk makes load order
/// something nobody can reproduce.
///
/// A symlink is resolved before its kind is judged. Symlinking a plugin -- one
/// file, or a whole directory -- into a root is how people develop one, and a
/// walk that skipped links would work everywhere except on the machine the
/// plugin is being written on.
fn sortedEntries(allocator: std.mem.Allocator, path: []const u8, kind: std.fs.Dir.Entry.Kind) ![][]u8 {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    var out: std.ArrayList([]u8) = .empty;
    errdefer freeNames(allocator, out.toOwnedSlice(allocator) catch &.{});

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        const actual = if (entry.kind == .sym_link)
            (if (dir.statFile(entry.name)) |st| st.kind else |_| continue)
        else
            entry.kind;
        if (actual != kind) continue;
        if (kind == .file and !std.mem.endsWith(u8, entry.name, ".lua")) continue;
        try out.append(allocator, try allocator.dupe(u8, entry.name));
    }

    const items = try out.toOwnedSlice(allocator);
    std.mem.sort([]u8, items, {}, lessThan);
    return items;
}

/// One file to run, and the root it belongs to.
pub const File = struct {
    path: []u8,
    /// The root, not the `plugin/` directory: a plugin's data sits beside its
    /// `plugin/` and `lua/`, so the root is the only useful thing to hand it.
    root: []const u8,
};

pub fn deinitFiles(allocator: std.mem.Allocator, files: []File) void {
    for (files) |f| allocator.free(f.path);
    allocator.free(files);
}

/// Every file that would be run, in the order it would be run.
///
/// `<root>/plugin/**/*.lua` for each root in path order, sorted within a
/// directory, subdirectories after the files beside them.
pub fn pluginFiles(allocator: std.mem.Allocator, list: []const Root) ![]File {
    var out: std.ArrayList(File) = .empty;
    errdefer {
        for (out.items) |f| allocator.free(f.path);
        out.deinit(allocator);
    }

    for (list) |root| {
        const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root.path, RUN_DIR });
        defer allocator.free(dir);
        try walk(allocator, dir, root.path, &out, 0);
    }
    return out.toOwnedSlice(allocator);
}

fn walk(allocator: std.mem.Allocator, dir: []const u8, root: []const u8, out: *std.ArrayList(File), depth: usize) !void {
    if (depth >= MAX_DEPTH or out.items.len >= MAX_FILES) return;

    const files = sortedEntries(allocator, dir, .file) catch return;
    defer freeNames(allocator, files);
    for (files) |name| {
        if (out.items.len >= MAX_FILES) return;
        try out.append(allocator, .{
            .path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name }),
            .root = root,
        });
    }

    const subs = sortedEntries(allocator, dir, .directory) catch return;
    defer freeNames(allocator, subs);
    for (subs) |name| {
        const sub = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
        defer allocator.free(sub);
        try walk(allocator, sub, root, out, depth + 1);
    }
}

/// `package.path` for `require`, built from the same roots.
///
/// `<root>/lua/?.lua` for every root, so a plugin's helper is `require("x.y")`
/// wherever the plugin lives. The config directory itself is also on it -- not
/// only its `lua/` -- because a fragment beside `init.lua` has always been
/// `require("layout")` and moving that would break every config in existence.
pub fn requirePath(allocator: std.mem.Allocator, list: []const Root) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    if (configHome(allocator)) |cfg| {
        defer allocator.free(cfg);
        try buf.print(allocator, "{s}/?.lua;{s}/?/init.lua;", .{ cfg, cfg });
    } else |_| {}

    for (list) |root| {
        try buf.print(allocator, "{s}/{s}/?.lua;{s}/{s}/?/init.lua;", .{
            root.path, LUA_DIR, root.path, LUA_DIR,
        });
    }
    try buf.appendSlice(allocator, "./.hexe/lua/?.lua;./.hexe/lua/?/init.lua");
    return buf.toOwnedSlice(allocator);
}

test "the after half mirrors the head, so yours is both first and last" {
    const allocator = std.testing.allocator;
    const list = try roots(allocator);
    defer deinitRoots(allocator, list);

    try std.testing.expect(list.len >= 4);
    try std.testing.expect(list.len % 2 == 0);
    try std.testing.expect(!list[0].after);
    try std.testing.expect(list[list.len - 1].after);

    // The last root is the first one's `after`: whatever you put in your own
    // config directory gets the final word over everything hexe ships.
    const last = list[list.len - 1].path;
    try std.testing.expect(std.mem.startsWith(u8, last, list[0].path));
    try std.testing.expectEqualStrings("/after", last[list[0].path.len..]);

    var seen_after = false;
    for (list) |r| {
        if (r.after) seen_after = true
        // Once the after half starts, no plain root may follow it.
        else try std.testing.expect(!seen_after);
    }
}

test "every root contributes its lua directory to the require path" {
    const allocator = std.testing.allocator;
    const list = try roots(allocator);
    defer deinitRoots(allocator, list);

    const path = try requirePath(allocator, list);
    defer allocator.free(path);

    for (list) |r| {
        const want = try std.fmt.allocPrint(allocator, "{s}/lua/?.lua", .{r.path});
        defer allocator.free(want);
        try std.testing.expect(std.mem.indexOf(u8, path, want) != null);
    }
}

test "plugin files come out sorted, and a subdirectory follows its parent" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("plugin/sub");
    try tmp.dir.writeFile(.{ .sub_path = "plugin/b.lua", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "plugin/a.lua", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "plugin/skip.txt", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "plugin/sub/c.lua", .data = "" });

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);

    const list = [_]Root{.{ .path = @constCast(base) }};
    const files = try pluginFiles(allocator, &list);
    defer deinitFiles(allocator, files);

    try std.testing.expectEqual(@as(usize, 3), files.len);
    try std.testing.expect(std.mem.endsWith(u8, files[0].path, "plugin/a.lua"));
    try std.testing.expect(std.mem.endsWith(u8, files[1].path, "plugin/b.lua"));
    try std.testing.expect(std.mem.endsWith(u8, files[2].path, "plugin/sub/c.lua"));
}

test "a symlinked plugin is walked like a real one" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("elsewhere");
    try tmp.dir.makePath("root/plugin");
    try tmp.dir.writeFile(.{ .sub_path = "elsewhere/dev.lua", .data = "" });

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const target = try std.fmt.allocPrint(allocator, "{s}/elsewhere/dev.lua", .{base});
    defer allocator.free(target);
    // Developing a plugin means linking it in rather than copying it each save.
    tmp.dir.symLink(target, "root/plugin/dev.lua", .{}) catch return;

    const root = try std.fmt.allocPrint(allocator, "{s}/root", .{base});
    defer allocator.free(root);
    const list = [_]Root{.{ .path = @constCast(root) }};
    const files = try pluginFiles(allocator, &list);
    defer deinitFiles(allocator, files);

    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expect(std.mem.endsWith(u8, files[0].path, "plugin/dev.lua"));
}
