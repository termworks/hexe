//! Images that arrive in a protocol ghostty's VT does not speak.
//!
//! A mux sits between a program and a terminal, and the two rarely agree on how
//! to draw an image. hexe's renderer emits the Kitty protocol; programs emit
//! whatever they were written for, which is often sixel (`img2sixel`, `timg`,
//! `chafa -f sixel`, matplotlib) or iTerm2's inline images (`imgcat`). ghostty's
//! VT implements neither: its readonly stream ignores DCS outright, and OSC 1337
//! `File=` is parsed and dropped.
//!
//! So hexe takes them itself. This watches the pane's byte stream, lifts out the
//! sequences carrying an image, decodes them, and hands the pixels to ghostty's
//! Kitty image storage as though the program had sent Kitty all along. Every
//! other byte passes through untouched, by slice, without a copy.
//!
//! The result is that which protocol a program speaks and which one the terminal
//! speaks stop being the same question.

const std = @import("std");
const sixel = @import("sixel.zig");
const logging = @import("logging.zig");

const ghostty = @import("ghostty-vt");

/// Largest sequence to hold while deciding what it is and decoding it. Sixel is
/// verbose -- a full-width photo runs to megabytes -- but a stream that never
/// terminates must not grow without bound.
const max_capture: usize = 32 * 1024 * 1024;

/// How much of an OSC to hold before deciding it is not an inline image. Only
/// as long as the prefix it must match, so an ordinary OSC (a title, a cwd, a
/// prompt mark) is delayed by ten bytes and never buffered whole.
const osc_probe = "1337;File=";

/// Sixel introducer parameters are a handful of digits; anything longer is not
/// a sixel and is passed through.
const max_dcs_params = 32;

pub const Importer = struct {
    state: State = .ground,
    /// Which protocol the capture in progress belongs to. Tracked rather than
    /// inferred from the payload: both protocols end at ST, so by the time the
    /// terminator arrives the bytes alone no longer say which one it was.
    kind: Kind = .none,
    /// The sequence being captured, or the introducer bytes being probed.
    buf: std.ArrayListUnmanaged(u8) = .empty,
    /// Set when a capture outgrew `max_capture`. The sequence is still consumed
    /// to its terminator -- dropping it whole beats emitting its tail as text.
    overflowed: bool = false,
    /// The introducer bytes held back while deciding what the sequence is.
    ///
    /// These cannot be tracked as an index into the caller's chunk: a pty read
    /// can end on the ESC itself, and the decision then belongs to the next
    /// chunk. Holding the bytes here is what lets the introducer be replayed
    /// intact once the sequence turns out to carry no image.
    held: [2]u8 = undefined,
    held_len: u8 = 0,

    const Kind = enum { none, sixel, iterm2 };

    const State = enum {
        ground,
        /// Saw ESC, waiting to see whether an introducer follows.
        esc,
        /// Saw ESC P, collecting introducer parameters to see if it is sixel.
        dcs_probe,
        /// Saw ESC ], matching against the iTerm2 inline-image prefix.
        osc_probe,
        /// Inside an image payload.
        capture,
        /// Inside a payload, having just seen an ESC that may begin an ST.
        capture_esc,
    };

    pub fn deinit(self: *Importer, alloc: std.mem.Allocator) void {
        self.buf.deinit(alloc);
        self.* = .{};
    }

    /// Feed a chunk of program output. `vt` is the owning `core.VT`; it is taken
    /// as `anytype` only to keep this module free of a circular import.
    ///
    /// Sequences split across chunks are held across calls, which is why the
    /// importer is per-pane state and not a free function.
    pub fn feed(self: *Importer, vt: anytype, data: []const u8) !void {
        const alloc = vt.allocator;
        // Start of the run of bytes passing straight through, flushed whenever
        // a capture begins and again at the end of the chunk. Everything not
        // part of an image sequence reaches the VT as a slice of the caller's
        // buffer, with no copy.
        var pass_start: usize = 0;
        var i: usize = 0;

        while (i < data.len) {
            const c = data[i];
            switch (self.state) {
                // Jump to the next ESC rather than walking bytes. Output is
                // overwhelmingly text and this is the VT's hot path: a per-byte
                // loop here would tax every pane to catch the rare image.
                .ground => {
                    const esc = std.mem.indexOfScalarPos(u8, data, i, 0x1b) orelse {
                        i = data.len;
                        continue;
                    };
                    try emit(vt, data[pass_start..esc]);
                    self.hold(0x1b);
                    pass_start = esc + 1;
                    self.state = .esc;
                    i = esc + 1;
                },

                .esc => switch (c) {
                    'P' => {
                        self.buf.clearRetainingCapacity();
                        self.hold('P');
                        self.state = .dcs_probe;
                        pass_start = i + 1;
                        i += 1;
                    },
                    ']' => {
                        self.buf.clearRetainingCapacity();
                        self.hold(']');
                        self.state = .osc_probe;
                        pass_start = i + 1;
                        i += 1;
                    },
                    // Not a sequence that can carry an image: replay the ESC and
                    // reread this byte in ground, where it may itself be the
                    // start of the next sequence.
                    else => {
                        try self.release(vt);
                        pass_start = i;
                        self.state = .ground;
                    },
                },

                .dcs_probe => switch (c) {
                    '0'...'9', ';', ':' => {
                        if (self.buf.items.len >= max_dcs_params) {
                            try self.release(vt);
                            pass_start = i;
                            self.state = .ground;
                        } else {
                            try self.buf.append(alloc, c);
                            i += 1;
                        }
                    },
                    'q' => {
                        // The decoder wants the introducer parameters too.
                        try self.buf.append(alloc, 'q');
                        self.beginCapture(.sixel);
                        i += 1;
                    },
                    // A DCS that is not sixel -- a DECRQSS request, say. Hand it
                    // back to the VT verbatim and stop looking.
                    else => {
                        try self.release(vt);
                        pass_start = i;
                        self.state = .ground;
                    },
                },

                .osc_probe => {
                    if (c == osc_probe[self.buf.items.len]) {
                        try self.buf.append(alloc, c);
                        if (self.buf.items.len == osc_probe.len) self.beginCapture(.iterm2);
                        i += 1;
                    } else {
                        // An ordinary OSC: a title, a cwd, a prompt mark.
                        try self.release(vt);
                        pass_start = i;
                        self.state = .ground;
                    }
                },

                .capture => {
                    switch (c) {
                        0x1b => self.state = .capture_esc,
                        // BEL terminates an OSC. Inside a sixel payload it
                        // cannot occur -- every sixel byte is printable.
                        0x07 => if (self.kind == .iterm2) {
                            self.finish(vt);
                            pass_start = i + 1;
                            self.state = .ground;
                        },
                        else => try self.capture(alloc, c),
                    }
                    i += 1;
                },

                .capture_esc => {
                    if (c == '\\') {
                        self.finish(vt);
                        pass_start = i + 1;
                        self.state = .ground;
                    } else {
                        // Not a terminator after all: the ESC was payload.
                        try self.capture(alloc, 0x1b);
                        try self.capture(alloc, c);
                        self.state = .capture;
                    }
                    i += 1;
                },
            }
        }

        if (self.state == .ground and pass_start < data.len) {
            try emit(vt, data[pass_start..]);
        }
    }

    fn hold(self: *Importer, c: u8) void {
        if (self.held_len >= self.held.len) return;
        self.held[self.held_len] = c;
        self.held_len += 1;
    }

    fn beginCapture(self: *Importer, kind: Kind) void {
        // Sixel keeps its introducer parameters, which the decoder parses; the
        // iTerm2 prefix is consumed and only the arguments and payload remain.
        if (kind == .iterm2) self.buf.clearRetainingCapacity();
        self.held_len = 0;
        self.kind = kind;
        self.overflowed = false;
        self.state = .capture;
    }

    fn capture(self: *Importer, alloc: std.mem.Allocator, c: u8) !void {
        if (self.overflowed) return;
        if (self.buf.items.len >= max_capture) {
            self.overflowed = true;
            self.buf.clearAndFree(alloc);
            return;
        }
        try self.buf.append(alloc, c);
    }

    /// Give up on a sequence that turned out not to be an image, replaying its
    /// introducer and everything held since so the VT sees it unchanged.
    fn release(self: *Importer, vt: anytype) !void {
        try emit(vt, self.held[0..self.held_len]);
        self.held_len = 0;
        if (self.buf.items.len > 0) try emit(vt, self.buf.items);
        self.buf.clearRetainingCapacity();
    }

    fn finish(self: *Importer, vt: anytype) void {
        const kind = self.kind;
        self.kind = .none;
        defer self.buf.clearRetainingCapacity();

        if (self.overflowed) {
            self.overflowed = false;
            logging.debug("vt", "dropped an inline image larger than the capture limit", .{});
            return;
        }
        if (self.buf.items.len == 0) return;

        switch (kind) {
            .sixel => self.injectSixel(vt),
            .iterm2 => self.injectIterm2(vt),
            .none => {},
        }
    }

    fn injectSixel(self: *Importer, vt: anytype) void {
        const alloc = vt.allocator;
        var img = sixel.decode(alloc, self.buf.items, .{}) catch |err| {
            logging.logError("vt", "failed to decode a sixel image", err);
            return;
        };
        defer img.deinit(alloc);
        inject(vt, .rgba, img.width, img.height, img.rgba);
    }

    fn injectIterm2(self: *Importer, vt: anytype) void {
        const alloc = vt.allocator;
        // `File=<key=value;...>:<base64>`; the prefix is already consumed.
        const colon = std.mem.indexOfScalar(u8, self.buf.items, ':') orelse return;
        const encoded = std.mem.trim(u8, self.buf.items[colon + 1 ..], " \t\r\n");
        if (encoded.len == 0) return;

        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(encoded) catch |err| {
            logging.logError("vt", "malformed base64 in an iTerm2 inline image", err);
            return;
        };
        const bytes = alloc.alloc(u8, size) catch |err| {
            logging.logError("vt", "failed to allocate an iTerm2 inline image", err);
            return;
        };
        defer alloc.free(bytes);
        decoder.decode(bytes, encoded) catch |err| {
            logging.logError("vt", "failed to decode an iTerm2 inline image", err);
            return;
        };

        // The payload is a whole image file. PNG is the one ghostty can decode
        // for us, through the same wuffs path a Kitty `f=100` transmission
        // takes; anything else would need a decoder hexe does not carry yet.
        const png_magic = "\x89PNG\r\n\x1a\n";
        if (!std.mem.startsWith(u8, bytes, png_magic)) {
            logging.debug("vt", "ignoring an iTerm2 inline image that is not a PNG", .{});
            return;
        }
        inject(vt, .png, 0, 0, bytes);
    }
};

fn emit(vt: anytype, slice: []const u8) !void {
    if (slice.len == 0) return;
    try vt.stream.nextSlice(slice);
}

/// What the decoded bytes are. ghostty's own format enum is not re-exported
/// from its graphics namespace, and naming it is not worth reaching past that.
const Payload = enum { rgba, png };

/// Hand pixels to ghostty's image storage as a transmit-and-display, which is
/// what the program would have sent had it spoken Kitty. ghostty copies the
/// data and assigns the image id, so nothing here has to track either.
fn inject(
    vt: anytype,
    payload: Payload,
    width: u32,
    height: u32,
    data: []const u8,
) void {
    var cmd: ghostty.kitty.graphics.Command = .{
        .control = .{ .transmit_and_display = .{
            .transmission = .{
                .format = switch (payload) {
                    .rgba => .rgba,
                    .png => .png,
                },
                .medium = .direct,
                .width = width,
                .height = height,
            },
            // Cursor movement defaults to `after`, which is where sixel and
            // iTerm2 both leave it.
            .display = .{},
        } },
        // hexe is answering on the program's behalf for a protocol that has no
        // response, so there is nothing to report back.
        .quiet = .failures,
        .data = data,
    };

    if (vt.terminal.kittyGraphics(vt.allocator, &cmd)) |resp| {
        if (!resp.ok()) {
            logging.debug("vt", "image storage rejected an imported image: {s}", .{resp.message});
        }
    }
}
