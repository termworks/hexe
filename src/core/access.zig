//! What a helper program is allowed to do.
//!
//! hexe's control socket is all-or-nothing: whoever can open it can do
//! everything, and file permissions are the only gate. That is right for the
//! user's own CLI and wrong for a helper they installed, which usually wants
//! one narrow thing -- a streamer wants bytes, a dictation tool wants to type,
//! a compositor bridge wants to press keys.
//!
//! So a plugin declares what it needs and hexe grants exactly that:
//!
//!     hexe.plugin("share", { command = "...", access = { "stream", "popup" } })
//!
//! **This is a declaration boundary, not a sandbox.** A plugin runs as you,
//! with your filesystem, so nothing here stops a determined program from
//! opening the unscoped socket itself. What it does buy is real anyway: least
//! privilege by default, a plugin that cannot type into your shell by accident,
//! and a list you can read to see what you actually installed.

const std = @import("std");

/// One kind of access. Deliberately about *what a program wants to do* rather
/// than about which verbs exist, so the list stays short and a new verb joins
/// an existing kind instead of inventing one.
pub const Kind = enum {
    /// The shape of the session: what panes and tabs exist, how big they are,
    /// what they are called. Always granted, because every plugin needs it to
    /// address anything at all, and knowing a pane is 80 columns wide harms
    /// nobody.
    read,
    /// What is actually ON a pane: its text, its scrollback, its environment.
    /// Split from `read` because structure is harmless and contents are not --
    /// a password on screen is `screen_text`, not `panes`.
    screen,
    /// Put text into a pane, as though it were pasted. What dictation needs,
    /// and all it needs.
    typing,
    /// Press keys *at hexe*: a chord goes through the keybinding machinery, so
    /// it can trigger a hexe action rather than reaching the program inside.
    /// Separate from `typing` because they are different powers -- typing
    /// cannot detach your session, and a compositor bridge that presses
    /// `ctrl+alt+d` has no business writing into a shell.
    keyboard,
    /// Read a pane's live output: the pod socket, scrollback and stream.
    stream,
    /// Interrupt the user: notifications, popups, a link or QR to scan.
    popup,
    /// Change the session: split, close, focus, move, rename, share, quit.
    /// The broad one, and the one to think twice about.
    control,

    pub fn name(self: Kind) []const u8 {
        return @tagName(self);
    }

    pub fn parse(text: []const u8) ?Kind {
        inline for (@typeInfo(Kind).@"enum".fields) |f| {
            if (std.mem.eql(u8, text, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

/// A grant: which kinds are held. A bit set rather than a list so a check is a
/// test rather than a search, and so the empty grant is the default.
pub const Set = struct {
    bits: u8 = 0,

    /// Held by everyone, declared by no one. Kept as a constant rather than
    /// spelled into each grant so there is one place to change if `read` ever
    /// stops being harmless.
    pub const baseline: Set = .{ .bits = @as(u8, 1) << @intFromEnum(Kind.read) };

    /// What a pane's own socket carries: read it, see its screen, type into it.
    ///
    /// Grants nothing to whoever is already running in that pane -- it IS the
    /// process there and can do all three by definition. What the socket adds
    /// is a way to ask hexe precisely instead of guessing, and what it withholds
    /// is every other pane and the session's shape.
    pub const pane_local: Set = baseline
        .with(.screen)
        .with(.typing);

    pub const all: Set = blk: {
        var s: Set = .{};
        for (@typeInfo(Kind).@"enum".fields) |f| {
            s.bits |= @as(u8, 1) << f.value;
        }
        break :blk s;
    };

    pub fn has(self: Set, kind: Kind) bool {
        return (self.bits & (@as(u8, 1) << @intFromEnum(kind))) != 0;
    }

    pub fn with(self: Set, kind: Kind) Set {
        return .{ .bits = self.bits | (@as(u8, 1) << @intFromEnum(kind)) };
    }

    pub fn isEmpty(self: Set) bool {
        return self.bits == 0;
    }

    pub fn merge(self: Set, other: Set) Set {
        return .{ .bits = self.bits | other.bits };
    }

    /// Write the held kinds as `read,typing`, for an env var or a listing.
    pub fn format(self: Set, writer: anytype) !void {
        var first = true;
        inline for (@typeInfo(Kind).@"enum".fields) |f| {
            const kind: Kind = @enumFromInt(f.value);
            if (self.has(kind)) {
                if (!first) try writer.writeAll(",");
                try writer.writeAll(f.name);
                first = false;
            }
        }
    }

    /// Read back what `format` wrote. Unknown names are reported rather than
    /// ignored: a typo in `access` should not quietly grant less than asked.
    pub fn parse(spec: []const u8, unknown: ?*[]const u8) ?Set {
        var out: Set = .{};
        var it = std.mem.tokenizeAny(u8, spec, ", \t");
        while (it.next()) |word| {
            const kind = Kind.parse(word) orelse {
                if (unknown) |u| u.* = word;
                return null;
            };
            out = out.with(kind);
        }
        return out;
    }
};

test "set round-trips through its own text form" {
    const s = (Set{}).with(.stream).with(.popup);
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try s.format(stream.writer());
    try std.testing.expectEqualStrings("stream,popup", stream.getWritten());

    const back = Set.parse(stream.getWritten(), null).?;
    try std.testing.expect(back.has(.stream));
    try std.testing.expect(back.has(.popup));
    try std.testing.expect(!back.has(.typing));
}

test "an unknown kind fails rather than granting less" {
    var bad: []const u8 = "";
    try std.testing.expect(Set.parse("stream,tpying", &bad) == null);
    try std.testing.expectEqualStrings("tpying", bad);
}

test "the baseline is read and nothing else" {
    try std.testing.expect(Set.baseline.has(.read));
    try std.testing.expect(!Set.baseline.has(.screen));
    try std.testing.expect(!Set.baseline.has(.typing));
}

test "all holds every kind" {
    inline for (@typeInfo(Kind).@"enum".fields) |f| {
        try std.testing.expect(Set.all.has(@enumFromInt(f.value)));
    }
}

/// What a verb costs on the door being asked.
///
/// A pane's own socket pays the scoped price where a verb names one. That is not a
/// discount on the power: the pane-scoped resolver confines every selector to the
/// caller, so the authority actually being exercised is over the caller's own
/// rectangle. `geometry` is the case that motivates it -- moving your own float is
/// not the session-wide power `control` names.
///
/// Both the dispatcher and `verbs()` ask here, so the list cannot advertise a price
/// the gate does not charge.
pub fn priceOf(needs: Kind, scoped_needs: ?Kind, pane_scoped: bool) Kind {
    if (!pane_scoped) return needs;
    return scoped_needs orelse needs;
}

test "a pane pays the scoped price, and every other door pays the full one" {
    // geometry's shape: `control` over the session, `read` over your own rectangle.
    try std.testing.expectEqual(Kind.control, priceOf(.control, .read, false));
    try std.testing.expectEqual(Kind.read, priceOf(.control, .read, true));

    // A verb with no scoped price costs the same at every door, so adding the field
    // changed nothing for the verbs that did not ask for it.
    try std.testing.expectEqual(Kind.typing, priceOf(.typing, null, false));
    try std.testing.expectEqual(Kind.typing, priceOf(.typing, null, true));
}

test "a pane's grant covers the scoped price of moving itself" {
    // The point of the exercise: the pane socket holds read/screen/typing, and that
    // is enough for geometry once the price is the scoped one.
    try std.testing.expect(Set.pane_local.has(priceOf(.control, .read, true)));
    try std.testing.expect(!Set.pane_local.has(priceOf(.control, .read, false)));
}
