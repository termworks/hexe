//! Putting an image on the screen from hexe's own side.
//!
//! Everything else in hexe's image handling is about a program inside a pane
//! drawing something. This is the other direction: hexe itself placing an image
//! file, because a caller asked it to.
//!
//! It does that by writing the Kitty protocol into the surface's own VT rather
//! than by adding a second way to draw. A drawing, a status zone and a pane
//! sprite are all bytes fed to a `core.VT`, so an image encoded here travels the
//! path every other image already takes: ghostty decodes it into the surface's
//! image storage, and the renderer either re-transmits it to the host terminal
//! or draws it as half blocks when the host has no graphics. Nothing downstream
//! needs to know an image came from hexe rather than from a program.

const std = @import("std");
const image_file = @import("image_file.zig");

pub const Error = error{
    NotAnImage,
    FileTooLarge,
    DecodeFailed,
    OutOfMemory,
};

/// Largest image file to place. Well past any icon or chart, and far below the
/// per-pane storage cap, so a mistyped path cannot read a disk image into RAM.
pub const max_file_bytes: usize = 16 * 1024 * 1024;

/// A stable image id for a named surface.
///
/// Transmitting with an id that is already loaded replaces it, so a drawing
/// updated every second occupies one slot rather than accumulating a new image
/// per frame. These share no space with a program's images: a drawing has its
/// own VT, which no program writes to.
pub fn idForName(name: []const u8) u32 {
    const h = std.hash.Wyhash.hash(0x9e3779b9, name);
    // Zero means "assign me one", which would defeat the point.
    const id: u32 = @truncate(h);
    return if (id == 0) 1 else id;
}

/// Read an image file and encode it as a Kitty transmit-and-display sequence
/// scaled to `cols` x `rows` cells.
///
/// PNG only. ghostty decodes it on the way in, through the same wuffs path a
/// program's `f=100` transmission takes, which is why nothing here needs a
/// decoder of its own.
pub fn fromFile(
    alloc: std.mem.Allocator,
    path: []const u8,
    cols: u16,
    rows: u16,
    id: u32,
) (Error || std.fs.File.OpenError || std.fs.File.ReadError)![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    if (stat.size > max_file_bytes) return error.FileTooLarge;

    const bytes = try alloc.alloc(u8, @intCast(stat.size));
    defer alloc.free(bytes);
    const n = try file.readAll(bytes);

    return encode(alloc, bytes[0..n], cols, rows, id);
}

/// Encode already-read image bytes. Split out from `fromFile` so the encoding
/// can be tested without touching a filesystem.
///
/// PNG is handed on as itself -- the protocol carries it and ghostty decodes it
/// on the way in, so decoding here would swap a compressed image for a raw one
/// several times the size. JPEG has no place in the protocol, so it is decoded
/// to pixels first and those are sent instead.
pub fn encode(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    cols: u16,
    rows: u16,
    id: u32,
) Error![]u8 {
    const format = image_file.detect(bytes) orelse return error.NotAnImage;
    switch (format) {
        .png => return build(alloc, bytes, "f=100", cols, rows, id),
        .jpeg => {
            var px = image_file.decodeJpeg(alloc, bytes) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.DecodeFailed,
            };
            defer px.deinit(alloc);
            var shape: [32]u8 = undefined;
            const spec = std.fmt.bufPrint(&shape, "f=32,s={d},v={d}", .{ px.width, px.height }) catch
                return error.DecodeFailed;
            return build(alloc, px.rgba, spec, cols, rows, id);
        },
    }
}

/// Wrap a payload as a Kitty transmit-and-display sized to the rectangle.
fn build(
    alloc: std.mem.Allocator,
    payload: []const u8,
    spec: []const u8,
    cols: u16,
    rows: u16,
    id: u32,
) Error![]u8 {
    const enc = std.base64.standard.Encoder;
    const payload_len = enc.calcSize(payload.len);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, payload_len + 96);

    // `C=1` keeps the cursor where it was: a surface positions its image by the
    // rectangle it was given, not by where a cursor happened to end up.
    var head: [96]u8 = undefined;
    const header = std.fmt.bufPrint(
        &head,
        "\x1b_G{s},a=T,i={d},c={d},r={d},C=1,q=2;",
        .{ spec, id, cols, rows },
    ) catch return error.OutOfMemory;
    try out.appendSlice(alloc, header);

    const at = out.items.len;
    try out.resize(alloc, at + payload_len);
    _ = enc.encode(out.items[at..], payload);

    try out.appendSlice(alloc, "\x1b\\");
    return out.toOwnedSlice(alloc);
}

const testing = std.testing;

/// The smallest valid PNG: 1x1, fully transparent.
const tiny_png = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
    0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
};

test "encode wraps a PNG as a sized Kitty placement" {
    const out = try encode(testing.allocator, &tiny_png, 10, 4, 77);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.startsWith(u8, out, "\x1b_Gf=100,a=T,i=77,c=10,r=4,C=1,q=2;"));
    try testing.expect(std.mem.endsWith(u8, out, "\x1b\\"));

    // The payload must be the file, base64'd, and nothing else.
    const semi = std.mem.indexOfScalar(u8, out, ';').?;
    const payload = out[semi + 1 .. out.len - 2];
    const dec = std.base64.standard.Decoder;
    const size = try dec.calcSizeForSlice(payload);
    const back = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(back);
    try dec.decode(back, payload);
    try testing.expectEqualSlices(u8, &tiny_png, back);
}

test "encode refuses anything that is not an image it can read" {
    try testing.expectError(error.NotAnImage, encode(testing.allocator, "not an image", 4, 2, 1));
    // A truncated magic is still not a PNG.
    try testing.expectError(error.NotAnImage, encode(testing.allocator, "\x89PNG", 4, 2, 1));
    // A format hexe has no decoder for is refused rather than sent as garbage.
    try testing.expectError(error.NotAnImage, encode(testing.allocator, "GIF89a....", 4, 2, 1));
    // Recognisably a JPEG, but not a decodable one.
    try testing.expectError(error.DecodeFailed, encode(testing.allocator, "\xff\xd8\xff nope", 4, 2, 1));
}

test "a name maps to a stable non-zero id" {
    const a = idForName("logo");
    try testing.expectEqual(a, idForName("logo"));
    try testing.expect(a != idForName("chart"));
    try testing.expect(a != 0);
}
