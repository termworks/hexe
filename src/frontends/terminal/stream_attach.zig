//! Handing a pane's byte stream to a plugin.
//!
//! hexe has no idea what the stream is for. It is not "sharing", not
//! "streaming", not "recording" -- those are things a plugin does. What hexe
//! knows is narrower and duller: a pane produces bytes, a plugin may be given
//! them, and the format is one anybody already reads.
//!
//! That format is asciicast v2: line-delimited JSON, a header then
//! `[t, "o", data]` events. So a plugin here is an ordinary asciicast consumer
//! that happens to be fed by a pipe instead of a file, and the same program
//! works against `asciinema play`, a recording on disk, or another hexe.
//!
//! Permission is not a new idea either. A plugin holding `stream` may watch; one
//! holding `stream` and `typing` may also send `[t, "i", data]` back on its
//! stdout, and hexe types it into the pane. View-only versus read-write is the
//! access it declared, not a flag on a share.

const std = @import("std");
const posix = std.posix;
const core = @import("core");

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;
const AsciicastWriter = core.recording.asciicast.AsciicastWriter;

const log = std.log.scoped(.stream_attach);

/// A plugin hexe kept hold of, because it declared `stream` and may therefore
/// be handed one. Plugins without it are spawned and forgotten as before.
pub const Attachable = struct {
    name: []const u8,
    child: std.process.Child,
    access: core.access.Set,
    /// The pane whose bytes are going to it, if any.
    pane: ?[32]u8 = null,
    cast: ?AsciicastWriter = null,
    /// Partial line from the plugin's stdout, waiting for its newline.
    in_buf: std.ArrayList(u8) = .empty,

    pub fn attached(self: *const Attachable) bool {
        return self.pane != null;
    }
};

/// Begin sending `pane`'s output to the plugin called `name`.
///
/// Returns a message when it could not, because a keybinding that silently does
/// nothing is indistinguishable from a broken key.
pub fn attach(state: *State, name: []const u8, pane: *Pane) ?[]const u8 {
    const p = find(state, name) orelse return "no such plugin, or it does not hold `stream` access";
    if (p.attached()) return "that plugin already has a stream";

    const stdin = p.child.stdin orelse return "that plugin has no stdin to write to";

    // The header names the size, so a viewer can lay out the pane before the
    // first byte arrives rather than guessing 80x24 and reflowing.
    var cast = AsciicastWriter.initFile(stdin, false, .{
        .width = pane.width,
        .height = pane.height,
        .title = state.paneName(pane.uuid),
    }) catch |err| {
        core.logging.logError("stream_attach", "could not start the cast", err);
        return "could not start the stream";
    };

    // Everything already on screen, so the far end sees the pane as it looks
    // now rather than only what happens next. `screen` access is not required
    // for this: the plugin was granted the live stream, and withholding the
    // first screenful would only mean it sees the same bytes a second later.
    if (@import("lua_api.zig").paneScreenText(state.allocator, pane)) |text| {
        defer state.allocator.free(text);
        cast.writeOutput(text) catch {};
    }

    p.cast = cast;
    p.pane = pane.uuid;
    log.debug("attached pane {s} to plugin {s}", .{ pane.uuid[0..8], name });
    return null;
}

/// Stop sending, and tell the plugin by closing what it was reading.
pub fn detach(state: *State, name: []const u8) void {
    const p = find(state, name) orelse return;
    if (!p.attached()) return;
    if (p.cast) |*c| {
        c.flush() catch {};
        c.deinit();
    }
    p.cast = null;
    p.pane = null;
    log.debug("detached plugin {s}", .{name});
}

/// Every plugin currently receiving `uuid`'s bytes gets this chunk.
///
/// Called from the pane's output path, which is where the frontend already has
/// the bytes -- a second observer connection to the pod would deliver the same
/// data twice and put another consumer against the pod's cap for no reason.
pub fn feedOutput(state: *State, uuid: [32]u8, bytes: []const u8) void {
    if (state.stream_plugins.items.len == 0 or bytes.len == 0) return;
    for (state.stream_plugins.items) |*p| {
        if (p.pane == null or !std.mem.eql(u8, &p.pane.?, &uuid)) continue;
        if (p.cast) |*c| {
            c.writeOutput(bytes) catch |err| {
                // A plugin that stopped reading is gone, not something to keep
                // blocking the render loop for.
                core.logging.logError("stream_attach", "plugin stopped reading its stream", err);
                detachPtr(p);
            };
        }
    }
}

/// A pane entered or left password mode.
///
/// Emitted as an asciicast marker so a plugin keeping its own scrollback can
/// scrub it. It must: detection cannot precede the prompt, so the bytes that
/// drew `Password:` were already sent, and a downstream buffer that merely
/// stops appending still holds them.
pub fn feedPasswordMode(state: *State, uuid: [32]u8, on: bool) void {
    if (state.stream_plugins.items.len == 0) return;
    for (state.stream_plugins.items) |*p| {
        if (p.pane == null or !std.mem.eql(u8, &p.pane.?, &uuid)) continue;
        if (p.cast) |*c| {
            c.writeMarker(if (on) "password-on" else "password-off") catch {};
        }
    }
}

/// Read anything a plugin typed back. Only for plugins that hold `typing`.
pub fn pollInput(state: *State) void {
    for (state.stream_plugins.items) |*p| {
        if (!p.access.has(.typing)) continue;
        const out = p.child.stdout orelse continue;

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = posix.read(out.handle, &buf) catch |err| switch (err) {
                error.WouldBlock => break,
                else => break,
            };
            if (n == 0) break;
            p.in_buf.appendSlice(state.allocator, buf[0..n]) catch break;
            if (p.in_buf.items.len > 1 << 20) {
                // A plugin writing megabytes without a newline is not sending
                // input events; drop what it has rather than grow forever.
                p.in_buf.clearRetainingCapacity();
                break;
            }
        }

        while (std.mem.indexOfScalar(u8, p.in_buf.items, '\n')) |nl| {
            const line = p.in_buf.items[0..nl];
            applyInputEvent(state, p, line);
            // The newline goes too.
            const rest = p.in_buf.items[nl + 1 ..];
            std.mem.copyForwards(u8, p.in_buf.items, rest);
            p.in_buf.shrinkRetainingCapacity(rest.len);
        }
    }
}

/// One `[t, "i", "text"]` line from a plugin, typed into its attached pane.
fn applyInputEvent(state: *State, p: *Attachable, line: []const u8) void {
    const uuid = p.pane orelse return;
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return;

    var parsed = std.json.parseFromSlice(std.json.Value, state.allocator, trimmed, .{}) catch return;
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a.items,
        else => return,
    };
    if (arr.len < 3) return;
    const kind = switch (arr[1]) {
        .string => |s| s,
        else => return,
    };
    // Only input. A plugin echoing output events back would otherwise be able
    // to write into the pane through a channel meant for keystrokes.
    if (!std.mem.eql(u8, kind, "i")) return;
    const data = switch (arr[2]) {
        .string => |s| s,
        else => return,
    };
    const pane = state.findPaneByUuid(uuid) orelse return;
    state.writePaneInput(pane, data);
    state.needs_render = true;
}

fn find(state: *State, name: []const u8) ?*Attachable {
    for (state.stream_plugins.items) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

fn detachPtr(p: *Attachable) void {
    if (p.cast) |*c| c.deinit();
    p.cast = null;
    p.pane = null;
}
