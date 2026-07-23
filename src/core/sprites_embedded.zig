//! Embedded Pokemon sprites, stored as a packed archive of per-sprite gzip
//! streams built by src/tools/sprite_pack.zig (see that file for the archive
//! layout). Looking up a sprite scans the embedded index and inflates just
//! that one stream, so the binary carries the ~1.6MB compressed archive
//! instead of ~9MB of raw ANSI art.

const std = @import("std");

const pack: []const u8 = @import("sprites_pack").data;

const magic = "HXSP";
const version: u32 = 1;
const header_len = magic.len + 4 + 4 + 4;

pub const GetError = error{ SpriteNotFound, CorruptSpriteArchive, OutOfMemory };

/// Find `name` in the embedded archive and return its inflated content.
/// Caller owns the returned memory.
pub fn getSpriteAlloc(gpa: std.mem.Allocator, name: []const u8, shiny: bool) GetError![]u8 {
    if (pack.len < header_len or !std.mem.eql(u8, pack[0..magic.len], magic))
        return error.CorruptSpriteArchive;
    if (readU32(magic.len) != version) return error.CorruptSpriteArchive;
    const count = readU32(magic.len + 4);
    const index_len = readU32(magic.len + 8);
    const data_start: usize = header_len + index_len;
    if (data_start > pack.len) return error.CorruptSpriteArchive;

    const want_kind: u8 = if (shiny) 1 else 0;
    var cursor: usize = header_len;
    var data_off: usize = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (cursor + 10 > data_start) return error.CorruptSpriteArchive;
        const kind = pack[cursor];
        const name_len = pack[cursor + 1];
        const raw_len = readU32(cursor + 2);
        const comp_len = readU32(cursor + 6);
        cursor += 10;
        if (cursor + name_len > data_start) return error.CorruptSpriteArchive;
        const entry_name = pack[cursor..][0..name_len];
        cursor += name_len;

        if (kind == want_kind and std.mem.eql(u8, entry_name, name)) {
            const comp_start = data_start + data_off;
            if (comp_start + comp_len > pack.len) return error.CorruptSpriteArchive;
            return inflate(gpa, pack[comp_start..][0..comp_len], raw_len);
        }
        data_off += comp_len;
    }
    return error.SpriteNotFound;
}

fn inflate(gpa: std.mem.Allocator, comp: []const u8, raw_len: u32) GetError![]u8 {
    const out = try gpa.alloc(u8, raw_len);
    errdefer gpa.free(out);
    var in: std.Io.Reader = .fixed(comp);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var dec: std.compress.flate.Decompress = .init(&in, .gzip, &window);
    dec.reader.readSliceAll(out) catch return error.CorruptSpriteArchive;
    return out;
}

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, pack[offset..][0..4], .little);
}

test "embedded sprite archive round-trips a known sprite" {
    const gpa = std.testing.allocator;
    const data = try getSpriteAlloc(gpa, "pikachu", false);
    defer gpa.free(data);
    try std.testing.expect(data.len > 0);
    // ANSI art must contain escape sequences.
    try std.testing.expect(std.mem.indexOfScalar(u8, data, 0x1b) != null);

    const shiny = try getSpriteAlloc(gpa, "pikachu", true);
    defer gpa.free(shiny);
    try std.testing.expect(shiny.len > 0);

    try std.testing.expectError(error.SpriteNotFound, getSpriteAlloc(gpa, "not-a-pokemon", false));
}
