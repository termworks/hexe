//! What an image file is, and how to get pixels out of one.
//!
//! One place in hexe is handed a whole encoded image rather than a stream of
//! terminal escapes: a path given to `draw`. It reads PNG and JPEG.
//!
//! PNG travels on untouched: the Kitty protocol carries it directly and
//! ghostty decodes it on the way in, so re-decoding here would only cost time.
//! JPEG has no place in that protocol, so hexe decodes it to pixels and sends
//! those instead. Either way the caller ends up with something the Kitty image
//! storage accepts.

const std = @import("std");
const logging = @import("logging.zig");

/// The JPEG decoder, from the vendored ghostty tree. It is already compiled
/// into the binary for ghostty's own PNG path; this only reaches the other
/// decoder sitting next to it.
const wuffs = @import("wuffs");

pub const Error = error{
    /// The bytes are not an image hexe can read.
    UnsupportedFormat,
    DecodeFailed,
    OutOfMemory,
};

pub const Format = enum {
    png,
    jpeg,

    pub fn name(self: Format) []const u8 {
        return switch (self) {
            .png => "PNG",
            .jpeg => "JPEG",
        };
    }
};

const png_magic = "\x89PNG\r\n\x1a\n";
/// SOI, then the first marker of a JFIF/EXIF/raw stream.
const jpeg_magic = "\xff\xd8\xff";

/// Identify an image by its leading bytes. Extensions lie; magic numbers do
/// not.
pub fn detect(bytes: []const u8) ?Format {
    if (std.mem.startsWith(u8, bytes, png_magic)) return .png;
    if (std.mem.startsWith(u8, bytes, jpeg_magic)) return .jpeg;
    return null;
}

/// Decoded pixels, RGBA, owned by the caller.
pub const Pixels = struct {
    width: u32,
    height: u32,
    rgba: []u8,

    pub fn deinit(self: *Pixels, alloc: std.mem.Allocator) void {
        alloc.free(self.rgba);
        self.* = undefined;
    }
};

/// Decode a JPEG to RGBA.
///
/// PNG deliberately has no equivalent here: it is carried by the protocol as
/// itself, and decoding it early would replace a compressed image with a raw
/// one several times its size for no gain.
pub fn decodeJpeg(alloc: std.mem.Allocator, bytes: []const u8) Error!Pixels {
    const decoded = wuffs.jpeg.decode(alloc, bytes) catch |err| {
        logging.logError("image", "failed to decode a JPEG", err);
        return error.DecodeFailed;
    };
    return .{ .width = decoded.width, .height = decoded.height, .rgba = decoded.data };
}

const testing = std.testing;

test "detect reads the magic, not the extension" {
    try testing.expectEqual(Format.png, detect("\x89PNG\r\n\x1a\n rest").?);
    try testing.expectEqual(Format.jpeg, detect("\xff\xd8\xff\xe0 JFIF").?);
    // EXIF JPEGs start with a different third byte in the app marker, but the
    // first three are the same.
    try testing.expectEqual(Format.jpeg, detect("\xff\xd8\xff\xe1 Exif").?);

    try testing.expect(detect("GIF89a") == null);
    try testing.expect(detect("not an image at all") == null);
    try testing.expect(detect("") == null);
    // A truncated magic is not a match.
    try testing.expect(detect("\x89PNG") == null);
    try testing.expect(detect("\xff\xd8") == null);
}

test "decodeJpeg returns pixels for a real JPEG" {
    // A genuine 1x1 white JPEG. Hand-assembling one produces a file the
    // decoder rejects for reasons that have nothing to do with hexe, so this
    // is a real encoder's output, byte for byte.
    const jpg = [_]u8{
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
        0x01, 0x01, 0x00, 0x48, 0x00, 0x48, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
        0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        0x01, 0x01, 0x01, 0x01, 0x01, 0xFF, 0xDB, 0x00, 0x43, 0x01, 0x01, 0x01,
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        0x01, 0x01, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x01, 0x00, 0x01, 0x03,
        0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, 0xFF, 0xC4, 0x00,
        0x14, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0A, 0xFF, 0xC4, 0x00, 0x14, 0x10,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xC4, 0x00, 0x14, 0x01, 0x01, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0xFF, 0xC4, 0x00, 0x14, 0x11, 0x01, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11,
        0x00, 0x3F, 0x00, 0x7F, 0x00, 0xFF, 0xD9,
    };
    try testing.expectEqual(Format.jpeg, detect(&jpg).?);

    var px = try decodeJpeg(testing.allocator, &jpg);
    defer px.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), px.width);
    try testing.expectEqual(@as(u32, 1), px.height);
    try testing.expectEqual(@as(usize, 4), px.rgba.len);
    // White and opaque: the pixels are real, not a zeroed buffer.
    try testing.expectEqual(@as(u8, 255), px.rgba[3]);
    try testing.expect(px.rgba[0] > 200 and px.rgba[1] > 200 and px.rgba[2] > 200);
}

test "decodeJpeg refuses bytes that are not a JPEG" {
    try testing.expectError(error.DecodeFailed, decodeJpeg(testing.allocator, "\xff\xd8\xff garbage"));
}
