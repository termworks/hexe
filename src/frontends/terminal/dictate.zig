//! Speech to text, as a tool hexe drives rather than a feature hexe contains.
//!
//! hexe records nothing and transcribes nothing. It starts the configured
//! command, shows that a pane is listening, and types back whatever the command
//! prints. Everything that makes dictation good -- the engine, the model, the
//! language, the punctuation -- stays in a program you can run and debug on its
//! own, and hexe never has to ship an audio stack to change any of it.
//!
//! The contract is two lines:
//!
//!   1. record until stdin closes;
//!   2. print the text to stdout and exit.
//!
//! stdin-as-the-stop-signal rather than SIGINT because a shell script can
//! implement it without trapping anything: `pw-record ... & read; kill %1`.

const std = @import("std");
const posix = std.posix;
const core = @import("core");

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;
const Renderer = @import("render_core.zig").Renderer;

const log = std.log.scoped(.dictate);

/// Cap on what a tool may hand back. Dictation produces sentences; anything
/// past this is a tool malfunctioning, and it is about to be typed into a
/// shell, so it is truncated rather than trusted.
const MAX_TEXT_BYTES: usize = 64 * 1024;

/// Columns the meter occupies. Three, because it sits on top of the user's own
/// output and the whole point is to be noticeable without being in the way.
pub const METER_COLS: u16 = 3;

/// Eighth-block ramp. One row tall, so the meter costs three cells total and
/// still reads as bars rising and falling.
const RAMP = [_]u21{ 0x2581, 0x2582, 0x2583, 0x2584, 0x2585, 0x2586, 0x2587, 0x2588 };

pub const Phase = enum {
    /// The tool is running and stdin is still open: it is listening.
    listening,
    /// stdin is closed; we are waiting for the text and for the tool to exit.
    thinking,
};

pub const Dictation = struct {
    allocator: std.mem.Allocator,
    child: ?std.process.Child = null,
    /// Where the text goes. Captured at start: dictation that typed into
    /// whatever happened to be focused when the tool finished would put a
    /// sentence in the wrong pane every time the user looked away.
    target: [32]u8 = undefined,
    has_target: bool = false,
    phase: Phase = .listening,
    /// Accumulated stdout. Read incrementally so a tool that streams partial
    /// text does not fill a pipe and deadlock against us.
    out: std.ArrayList(u8) = .empty,
    started_ms: i64 = 0,
    stop_ms: i64 = 0,

    pub fn init(allocator: std.mem.Allocator) Dictation {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Dictation) void {
        self.abandon();
        self.out.deinit(self.allocator);
    }

    pub fn active(self: *const Dictation) bool {
        return self.child != null;
    }

    /// Whether this pane is the one being dictated into.
    pub fn targets(self: *const Dictation, uuid: [32]u8) bool {
        return self.child != null and self.has_target and std.mem.eql(u8, &self.target, &uuid);
    }

    /// Kill the tool and forget it, without delivering anything.
    fn abandon(self: *Dictation) void {
        if (self.child) |*child| {
            core.async_cmd.killAndReapBounded(child, 500);
            self.child = null;
        }
        self.has_target = false;
        self.out.clearRetainingCapacity();
    }
};

/// Begin dictating into `pane`.
///
/// Returns a message to show the user when it could not start, so the caller
/// does not have to know why -- a keybinding that silently does nothing is
/// indistinguishable from a broken keyboard.
pub fn start(state: *State, pane: *Pane) ?[]const u8 {
    const cfg = &state.config.dictate;
    if (!cfg.enabled()) return "no dictate.command configured";
    if (state.dictation.active()) return "already dictating";

    var child = std.process.Child.init(&.{ "/bin/sh", "-c", cfg.command }, state.allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    // A tool's diagnostics are its own business and must not be typed into the
    // pane: only stdout is the transcript.
    child.stderr_behavior = .Ignore;

    var env_map = std.process.getEnvMap(state.allocator) catch |err| {
        core.logging.logError("dictate", "failed to copy environment", err);
        return "could not build the tool's environment";
    };
    defer env_map.deinit();
    env_map.put("HEXE_PANE_UUID", pane.uuid[0..]) catch {};
    if (state.api_server) |*srv| env_map.put("HEXE_API_SOCKET", srv.path) catch {};
    env_map.put("HEXE_SESSION", state.runtime.sessionName()) catch {};
    child.env_map = &env_map;

    child.spawn() catch |err| {
        core.logging.logError("dictate", "failed to start the dictate command", err);
        return "could not start the dictate command";
    };

    // Non-blocking, because this pipe is read from the render loop. A tool that
    // writes nothing must not park the loop that drives every pane.
    if (child.stdout) |out| core.ipc.setNonBlocking(out.handle) catch |err| {
        core.logging.logError("dictate", "failed to set the tool's stdout non-blocking", err);
    };

    state.dictation.child = child;
    state.dictation.target = pane.uuid;
    state.dictation.has_target = true;
    state.dictation.phase = .listening;
    state.dictation.started_ms = std.time.milliTimestamp();
    state.dictation.stop_ms = 0;
    state.dictation.out.clearRetainingCapacity();
    state.needs_render = true;
    return null;
}

/// Ask the tool to stop listening: close its stdin and wait for the text.
pub fn stop(state: *State) void {
    const d = &state.dictation;
    if (d.child == null or d.phase == .thinking) return;
    if (d.child.?.stdin) |stdin| {
        stdin.close();
        d.child.?.stdin = null;
    }
    d.phase = .thinking;
    d.stop_ms = std.time.milliTimestamp();
    state.needs_render = true;
}

pub fn toggle(state: *State, pane: *Pane) ?[]const u8 {
    if (state.dictation.active()) {
        stop(state);
        return null;
    }
    return start(state, pane);
}

/// Stop without typing anything.
pub fn cancel(state: *State) void {
    if (!state.dictation.active()) return;
    state.dictation.abandon();
    state.needs_render = true;
}

/// Drain the tool's output and finish when it exits. Called from the loop tick.
pub fn poll(state: *State) void {
    const d = &state.dictation;
    if (d.child == null) return;

    drain(d);

    // Only reap once stdin is closed. Before that the tool is supposed to still
    // be running, and waiting on it would block the loop until the user
    // released the key.
    if (d.phase == .listening) {
        // Keep the meter moving even when nothing else asks for a frame.
        state.needs_render = true;
        return;
    }

    const timeout: i64 = @intCast(state.config.dictate.timeout_ms);
    if (std.time.milliTimestamp() - d.stop_ms > timeout) {
        log.warn("dictate tool did not finish within {d}ms; abandoning it", .{timeout});
        state.notifications.showFor("dictation timed out", 1600);
        d.abandon();
        state.needs_render = true;
        return;
    }

    // Non-blocking reap: waitpid(WNOHANG) rather than Child.wait(), which
    // blocks. The pipe is drained above, so the child cannot be stuck on a
    // full stdout while we do this.
    const res = posix.waitpid(d.child.?.id, posix.W.NOHANG);
    if (res.pid == 0) {
        state.needs_render = true;
        return;
    }

    drain(d);
    deliver(state);
}

/// Read whatever is available without blocking.
fn drain(d: *Dictation) void {
    const out = (d.child orelse return).stdout orelse return;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(out.handle, &buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return,
        };
        if (n == 0) return;
        if (d.out.items.len >= MAX_TEXT_BYTES) return;
        const room = MAX_TEXT_BYTES - d.out.items.len;
        d.out.appendSlice(d.allocator, buf[0..@min(n, room)]) catch return;
    }
}

/// Type the transcript into the pane it was dictated for.
fn deliver(state: *State) void {
    const d = &state.dictation;
    defer {
        // The child is already reaped; drop the handle without killing it.
        d.child = null;
        d.has_target = false;
        d.out.clearRetainingCapacity();
        state.needs_render = true;
    }

    const text = std.mem.trim(u8, d.out.items, " \t\r\n");
    if (text.len == 0) {
        state.notifications.showFor("dictation returned nothing", 1400);
        return;
    }

    // The pane can be gone -- closed while the tool was thinking. Dropping the
    // text is correct: retargeting it at whatever is focused now would type a
    // sentence into an unrelated shell.
    if (!d.has_target) return;
    const pane = state.findPaneByUuid(d.target) orelse {
        state.notifications.showFor("dictation target is gone", 1600);
        return;
    };
    state.writePaneInput(pane, text);
}

/// A fake level for one column, from the clock.
///
/// Deliberately not real audio: hexe never sees the samples, and running a
/// meter off the tool's output would mean parsing a side channel into the
/// transcript. Two detuned sines per column give motion that never repeats
/// visibly and never sits still, which is all the meter has to say -- something
/// is listening.
fn level(now_ms: i64, col: u16) usize {
    const t = @as(f32, @floatFromInt(@mod(now_ms, 1_000_000))) / 1000.0;
    const phase = @as(f32, @floatFromInt(col)) * 1.7;
    const a = @sin(t * 7.3 + phase);
    const b = @sin(t * 11.9 + phase * 2.1);
    // Two sines in -2..2, mapped across the ramp with the ends trimmed off so
    // a bar never fully empties -- a column at zero reads as a dead meter.
    const mixed = (a + b + 2.0) / 4.0;
    const scaled = mixed * @as(f32, @floatFromInt(RAMP.len - 2)) + 1.0;
    const idx: usize = @intFromFloat(@max(0.0, @min(@as(f32, @floatFromInt(RAMP.len - 1)), scaled)));
    return idx;
}

/// Draw the meter at the bottom-centre of the pane that is being dictated into.
///
/// Over the pane's own last row rather than on a border: a split pane has no
/// border to use, and the indicator has to appear in the same place whether the
/// target is a split or a float.
pub fn draw(state: *State, renderer: *Renderer, pane: *const Pane) void {
    const d = &state.dictation;
    if (!d.targets(pane.uuid)) return;
    if (pane.width < METER_COLS or pane.height == 0) return;

    const y = pane.y + pane.height - 1;
    const x0 = pane.x + (pane.width - METER_COLS) / 2;
    const now = std.time.milliTimestamp();

    var col: u16 = 0;
    while (col < METER_COLS) : (col += 1) {
        // While thinking the bars stop moving and sit at the floor: the user
        // has to be able to tell "still listening" from "stopped listening",
        // and a meter that keeps dancing after the key is released says the
        // wrong one.
        const idx = switch (d.phase) {
            .listening => level(now, col),
            .thinking => 0,
        };
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(RAMP[idx], &buf) catch continue;
        renderer.setVaxisCell(x0 + col, y, .{
            .char = .{ .grapheme = buf[0..n], .width = 1 },
            .style = .{
                .fg = (core.style.Color{ .palette = if (d.phase == .listening) 1 else 8 }).toVaxis(),
                .bold = d.phase == .listening,
            },
        });
    }
}
