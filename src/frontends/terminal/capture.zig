//! The sign that something is capturing you.
//!
//! A plugin says it is capturing and hexe draws three bars at the bottom of the
//! pane. hexe does not know what is being captured -- a microphone, a camera, a
//! screen -- and does not need to: what it draws means "something is recording
//! you right now", which is the only part that must be true.
//!
//! Claiming to capture is harmless, so any plugin may do it. The harm runs the
//! other way: capturing *without* claiming. So this is deliberately cheap to
//! use and impossible to style away -- hexe draws it, not the painter, because
//! an indicator that disappears when no painter is running is not one.
//!
//! The bars are not a level meter. hexe never sees the audio, and a meter driven
//! by a plugin's own numbers would be a plugin drawing its own privacy
//! indicator, which is the thing this exists to avoid. They move so that
//! "capturing" cannot be confused with a frozen screen.

const std = @import("std");
const core = @import("core");

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;
const Renderer = @import("render_core.zig").Renderer;

/// Columns the indicator occupies. Three, because it sits on top of the user's
/// own output and has to be noticed without being in the way.
pub const METER_COLS: u16 = 3;

/// Eighth-block ramp, one row tall: three cells total.
const RAMP = [_]u21{ 0x2581, 0x2582, 0x2583, 0x2584, 0x2585, 0x2586, 0x2587, 0x2588 };

/// Nothing has claimed capture for this long and the claim lapses.
///
/// A plugin that crashes mid-capture would otherwise leave the indicator on
/// forever, which is worse than not having one: it trains the user to ignore
/// it. Renewing is one call, so a live plugin keeps it lit easily.
pub const CLAIM_TTL_MS: i64 = 5_000;

pub const Capture = struct {
    /// The pane being captured, if any.
    pane: ?[32]u8 = null,
    /// Who said so, for the record and for `hexe api capture`.
    by: [32]u8 = @splat(0),
    by_len: usize = 0,
    claimed_ms: i64 = 0,

    pub fn active(self: *const Capture, now_ms: i64) bool {
        return self.pane != null and now_ms - self.claimed_ms < CLAIM_TTL_MS;
    }

    pub fn owner(self: *const Capture) []const u8 {
        return self.by[0..self.by_len];
    }
};

/// Claim (or renew) the indicator for `pane`.
pub fn claim(state: *State, pane: *Pane, by: []const u8) void {
    state.capture.pane = pane.uuid;
    state.capture.claimed_ms = std.time.milliTimestamp();
    const n = @min(by.len, state.capture.by.len);
    @memcpy(state.capture.by[0..n], by[0..n]);
    state.capture.by_len = n;
    state.needs_render = true;
}

pub fn release(state: *State) void {
    state.capture.pane = null;
    state.capture.by_len = 0;
    state.needs_render = true;
}

/// Keep the bars moving, and drop a claim nobody renewed.
pub fn tick(state: *State) void {
    if (state.capture.pane == null) return;
    if (!state.capture.active(std.time.milliTimestamp())) {
        release(state);
        return;
    }
    state.needs_render = true;
}

/// A level for one column, from the clock.
///
/// Two detuned sines give motion that never repeats visibly and never sits
/// still, which is all the indicator has to say.
fn level(now_ms: i64, col: u16) usize {
    const t = @as(f32, @floatFromInt(@mod(now_ms, 1_000_000))) / 1000.0;
    const phase = @as(f32, @floatFromInt(col)) * 1.7;
    const a = @sin(t * 7.3 + phase);
    const b = @sin(t * 11.9 + phase * 2.1);
    // Ends trimmed off the ramp so a bar never fully empties -- a column at
    // zero reads as a dead indicator.
    const mixed = (a + b + 2.0) / 4.0;
    const scaled = mixed * @as(f32, @floatFromInt(RAMP.len - 2)) + 1.0;
    const idx: usize = @intFromFloat(@max(0.0, @min(@as(f32, @floatFromInt(RAMP.len - 1)), scaled)));
    return idx;
}

/// Draw it at the bottom-centre of the pane being captured.
///
/// Over the pane's own last row rather than on a border: a split pane has no
/// border to use, and this has to appear in the same place whether the target
/// is a split or a float.
pub fn draw(state: *State, renderer: *Renderer, pane: *const Pane) void {
    const c = &state.capture;
    if (c.pane == null or !std.mem.eql(u8, &c.pane.?, &pane.uuid)) return;
    if (!c.active(std.time.milliTimestamp())) return;
    if (pane.width < METER_COLS or pane.height == 0) return;

    const y = pane.y + pane.height - 1;
    const x0 = pane.x + (pane.width - METER_COLS) / 2;
    const now = std.time.milliTimestamp();

    var col: u16 = 0;
    while (col < METER_COLS) : (col += 1) {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(RAMP[level(now, col)], &buf) catch continue;
        renderer.setVaxisCell(x0 + col, y, .{
            .char = .{ .grapheme = buf[0..n], .width = 1 },
            .style = .{
                .fg = (core.style.Color{ .palette = 1 }).toVaxis(),
                .bold = true,
            },
        });
    }
}
