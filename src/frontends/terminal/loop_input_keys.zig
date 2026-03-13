const std = @import("std");
const core = @import("core");
const vaxis = @import("vaxis");

const State = @import("state.zig").State;
const input = @import("input.zig");
const actions = @import("loop_actions.zig");

var keycast_parser: vaxis.Parser = .{};

/// Parsed exit key with modifiers.
const ParsedExitKey = struct {
    mods: u8, // 1=Alt, 2=Ctrl, 4=Shift
    key: []const u8, // The base key (e.g., "k", "Esc", "Enter")
};

/// Record input for keycast if enabled.
pub fn recordKeycastInput(state: *State, inp: []const u8) void {
    if (!state.overlays.isKeycastEnabled()) return;
    if (inp.len == 0) return;

    // Don't show keycast during bracketed paste
    if (state.in_bracketed_paste) return;

    // Don't show keycast if focused pane might be in password mode
    if (isFocusedPaneInPasswordMode(state)) return;

    var i: usize = 0;
    while (i < inp.len) {
        const res = keycast_parser.parse(inp[i..], state.allocator) catch {
            i += 1;
            continue;
        };
        if (res.n == 0) break;
        if (res.event) |ev_raw| {
            if (input.keyEventFromVaxisEvent(ev_raw)) |ev| {
                if (ev.when == .press) {
                    var event_buf: [32]u8 = undefined;
                    const event_text = formatKeycastEvent(ev, &event_buf);
                    if (event_text.len > 0) {
                        state.overlays.recordKeypress(event_text);
                        state.needs_render = true;
                    }
                }
            }
        }
        i += res.n;
    }
}

fn formatKeycastEvent(ev: input.KeyEvent, buf: *[32]u8) []const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    if (ev.mods & 2 != 0) writer.writeAll("C-") catch {};
    if (ev.mods & 1 != 0) writer.writeAll("A-") catch {};

    switch (@as(core.Config.BindKeyKind, ev.key)) {
        .up => writer.writeAll("Up") catch {},
        .down => writer.writeAll("Down") catch {},
        .left => writer.writeAll("Left") catch {},
        .right => writer.writeAll("Right") catch {},
        .space => writer.writeAll("Space") catch {},
        .char => {
            const ch = ev.key.char;
            switch (ch) {
                '\r' => writer.writeAll("Enter") catch {},
                '\t' => writer.writeAll("Tab") catch {},
                0x7f => writer.writeAll("Bksp") catch {},
                0x1b => writer.writeAll("Esc") catch {},
                else => {
                    if (ch >= 0x20 and ch < 0x7f) {
                        writer.writeByte(ch) catch {};
                    } else {
                        std.fmt.format(writer, "0x{x:0>2}", .{ch}) catch {};
                    }
                },
            }
        },
    }

    return buf[0..stream.pos];
}

/// Check parser-decoded key event against focused float exit_key.
/// Returns true when it consumed the event by closing the float.
pub fn checkExitKeyEvent(state: *State, mods: u8, key: core.Config.BindKey, when: core.Config.BindWhen) bool {
    if (when != .press) return false;
    const exit_key = getFocusedFloatExitKey(state) orelse return false;
    if (exit_key.len == 0) return false;

    const parsed = parseExitKeySpec(exit_key);
    if (mods != parsed.mods) return false;

    const expected = getKeyChar(parsed.key) orelse return false;

    const matched = switch (@as(core.Config.BindKeyKind, key)) {
        .space => expected == ' ',
        .char => blk: {
            var got = key.char;
            if (got >= 'A' and got <= 'Z') got = std.ascii.toLower(got);
            var exp = expected;
            if (exp >= 'A' and exp <= 'Z') exp = std.ascii.toLower(exp);
            break :blk got == exp;
        },
        else => false,
    };

    if (!matched) return false;

    if (state.activeFloatingIndex()) |idx| {
        if (idx < state.view.float_views.items.len) {
            state.setPaneClosedByExitKey(state.view.float_views.items[idx].uuid, true);
        }
    }
    actions.performClose(state);
    state.needs_render = true;
    return true;
}

fn isFocusedPaneInPasswordMode(state: *State) bool {
    const pane = if (state.activeFloatingIndex()) |idx|
        if (idx < state.view.float_views.items.len) state.view.float_views.items[idx] else return false
    else
        state.currentLayout().getFocusedPane() orelse return false;

    return pane.vt.terminal.flags.password_input;
}

fn getFocusedFloatExitKey(state: *State) ?[]const u8 {
    const idx = state.activeFloatingIndex() orelse return null;
    if (idx >= state.view.float_views.items.len) return null;
    const pane = state.view.float_views.items[idx];
    return state.paneExitKey(pane);
}

fn parseExitKeySpec(exit_key: []const u8) ParsedExitKey {
    var mods: u8 = 0;
    var remaining = exit_key;

    while (remaining.len > 0) {
        if (remaining.len > 4 and std.ascii.startsWithIgnoreCase(remaining, "Alt+")) {
            mods |= 1;
            remaining = remaining[4..];
            continue;
        }
        if (remaining.len > 2 and (std.mem.startsWith(u8, remaining, "A-") or std.mem.startsWith(u8, remaining, "a-"))) {
            mods |= 1;
            remaining = remaining[2..];
            continue;
        }
        if (remaining.len > 5 and std.ascii.startsWithIgnoreCase(remaining, "Ctrl+")) {
            mods |= 2;
            remaining = remaining[5..];
            continue;
        }
        if (remaining.len > 2 and (std.mem.startsWith(u8, remaining, "C-") or std.mem.startsWith(u8, remaining, "c-"))) {
            mods |= 2;
            remaining = remaining[2..];
            continue;
        }
        if (remaining.len > 6 and std.ascii.startsWithIgnoreCase(remaining, "Shift+")) {
            mods |= 4;
            remaining = remaining[6..];
            continue;
        }
        if (remaining.len > 2 and (std.mem.startsWith(u8, remaining, "S-") or std.mem.startsWith(u8, remaining, "s-"))) {
            mods |= 4;
            remaining = remaining[2..];
            continue;
        }
        break;
    }

    return .{ .mods = mods, .key = remaining };
}

fn getKeyChar(key: []const u8) ?u8 {
    if (key.len == 0) return null;
    if (key.len == 1) return key[0];
    if (std.ascii.eqlIgnoreCase(key, "Esc") or std.ascii.eqlIgnoreCase(key, "Escape")) return 0x1b;
    if (std.ascii.eqlIgnoreCase(key, "Enter")) return 0x0d;
    if (std.ascii.eqlIgnoreCase(key, "Space")) return ' ';
    if (std.ascii.eqlIgnoreCase(key, "Tab")) return 0x09;
    return null;
}
