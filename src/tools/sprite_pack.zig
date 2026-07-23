//! Build-time sprite packer: compresses src/core/sprites/{regular,shiny}
//! into a single archive of per-sprite gzip streams that gets embedded into
//! the binary (see src/core/sprites_embedded.zig for the reader).
//!
//! Compression shells out to `gzip -9` because std.compress.flate in Zig
//! 0.15 only ships a complete *decompressor*; gzip is only needed at build
//! time, the shipped binary inflates with pure Zig.
//!
//! Archive layout (all integers little-endian):
//!   magic     "HXSP"
//!   version   u32 = 1
//!   count     u32            number of index entries
//!   index_len u32            bytes of index data following this header
//!   index     count entries of:
//!     kind     u8            0 = regular, 1 = shiny
//!     name_len u8
//!     raw_len  u32           uncompressed sprite size
//!     comp_len u32           gzip stream size
//!     name     name_len bytes
//!   data      concatenated gzip streams, in index order
//!
//! Usage: sprite-pack <out_file> <sprites_dir> [fingerprint]
//! The trailing fingerprint argument is ignored; the build passes a hash of
//! the sprites directory there so the (path-only) Run-step cache manifest
//! changes when sprite files do.

const std = @import("std");

const Entry = struct {
    kind: u8,
    name: []const u8,
    raw_len: u32,
    comp: []const u8,
};

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    if (args.len < 3) {
        std.debug.print("usage: sprite-pack <out_file> <sprites_dir> [fingerprint]\n", .{});
        return error.InvalidArgs;
    }
    const out_path = args[1];
    const sprites_dir = args[2];

    var entries: std.ArrayList(Entry) = .empty;
    const kinds = [_]struct { sub: []const u8, kind: u8 }{
        .{ .sub = "regular", .kind = 0 },
        .{ .sub = "shiny", .kind = 1 },
    };
    for (kinds) |k| {
        const sub_path = try std.fs.path.join(arena, &.{ sprites_dir, k.sub });
        var dir = try std.fs.cwd().openDir(sub_path, .{ .iterate = true });
        defer dir.close();

        // Sort for a deterministic archive regardless of directory order.
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next()) |e| {
            if (e.kind != .file) continue;
            if (e.name.len > std.math.maxInt(u8)) return error.NameTooLong;
            try names.append(arena, try arena.dupe(u8, e.name));
        }
        std.mem.sort([]const u8, names.items, {}, nameLessThan);

        for (names.items) |name| {
            const full = try std.fs.path.join(arena, &.{ sub_path, name });
            const raw = try std.fs.cwd().readFileAlloc(arena, full, 16 * 1024 * 1024);
            const res = std.process.Child.run(.{
                .allocator = arena,
                .argv = &.{ "gzip", "-9", "-n", "-c", full },
                .max_output_bytes = 16 * 1024 * 1024,
            }) catch |err| {
                std.debug.print("sprite-pack: failed to run gzip (is it installed?): {}\n", .{err});
                return err;
            };
            switch (res.term) {
                .Exited => |code| if (code != 0) {
                    std.debug.print("sprite-pack: gzip failed on {s}: {s}\n", .{ full, res.stderr });
                    return error.GzipFailed;
                },
                else => return error.GzipFailed,
            }
            try entries.append(arena, .{
                .kind = k.kind,
                .name = name,
                .raw_len = @intCast(raw.len),
                .comp = res.stdout,
            });
        }
    }

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "HXSP");
    try appendU32(&out, arena, 1); // version
    try appendU32(&out, arena, @intCast(entries.items.len));
    var index_len: u32 = 0;
    for (entries.items) |e| index_len += @intCast(1 + 1 + 4 + 4 + e.name.len);
    try appendU32(&out, arena, index_len);
    for (entries.items) |e| {
        try out.append(arena, e.kind);
        try out.append(arena, @intCast(e.name.len));
        try appendU32(&out, arena, e.raw_len);
        try appendU32(&out, arena, @intCast(e.comp.len));
        try out.appendSlice(arena, e.name);
    }
    for (entries.items) |e| {
        try out.appendSlice(arena, e.comp);
    }

    const file = try std.fs.cwd().createFile(out_path, .{});
    defer file.close();
    try file.writeAll(out.items);
}

fn nameLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn appendU32(list: *std.ArrayList(u8), arena: std.mem.Allocator, v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try list.appendSlice(arena, &buf);
}
