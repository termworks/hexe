const std = @import("std");
const core = @import("core");
const vaxis = @import("vaxis");
const log = std.log.scoped(.terminal_input_keys);

const State = @import("state.zig").State;
const input = @import("input.zig");
const actions = @import("loop_actions.zig");
const lua_events = @import("lua_events.zig");

var key_parser: vaxis.Parser = .{};

/// Parsed exit key with modifiers.
const ParsedExitKey = struct {
    mods: u8, // 1=Alt, 2=Ctrl, 4=Shift
    key: []const u8, // The base key (e.g., "k", "Esc", "Enter")
};

/// Announce each key press as `key_pressed`, so anything that wants to show
/// keys can.
///
/// This used to feed a keycast overlay hexe drew itself. Showing keys is not
/// something a terminal multiplexer has to know how to do -- it is something a
/// plugin does, given the keys -- so hexe reports them and draws nothing.
///
/// **The two guards stay here, and cannot move into a plugin.** A subscriber
/// cannot tell that a pane is reading a password or that a paste is in flight;
/// hexe can. Anything downstream sees keys that were already judged safe to
/// show, which is the only place that judgement can be made.
pub fn emitKeyPresses(state: *State, inp: []const u8) void {
    if (inp.len == 0) return;
    if (state.in_bracketed_paste) return;
    if (isFocusedPaneInPasswordMode(state)) return;

    // Nothing is listening, so parsing every keystroke would be work for no one.
    const rt = state.config._lua_runtime orelse return;
    if (!lua_events.hasHandlers(rt, "key_pressed")) return;

    var i: usize = 0;
    while (i < inp.len) {
        const res = key_parser.parse(inp[i..], state.allocator) catch {
            i += 1;
            continue;
        };
        if (res.n == 0) break;
        if (res.event) |ev_raw| {
            if (input.keyEventFromVaxisEvent(ev_raw)) |ev| {
                if (ev.when == .press) {
                    var event_buf: [32]u8 = undefined;
                    const event_text = formatChord(ev, &event_buf);
                    if (event_text.len > 0) {
                        lua_events.emit(state, rt, "key_pressed", &.{
                            .{ .name = "key", .value = .{ .str = event_text } },
                        });
                    }
                }
            }
        }
        i += res.n;
    }
}

fn formatChord(ev: input.KeyEvent, buf: *[32]u8) []const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    if (ev.mods & 2 != 0) writer.writeAll("C-") catch |err| {
        log.debug("failed to format ctrl modifier: {}", .{err});
        return buf[0..stream.pos];
    };
    if (ev.mods & 1 != 0) writer.writeAll("A-") catch |err| {
        log.debug("failed to format alt modifier: {}", .{err});
        return buf[0..stream.pos];
    };

    switch (@as(core.Config.BindKeyKind, ev.key)) {
        .up => writer.writeAll("Up") catch |err| {
            log.debug("failed to format Up key: {}", .{err});
            return buf[0..stream.pos];
        },
        .down => writer.writeAll("Down") catch |err| {
            log.debug("failed to format Down key: {}", .{err});
            return buf[0..stream.pos];
        },
        .left => writer.writeAll("Left") catch |err| {
            log.debug("failed to format Left key: {}", .{err});
            return buf[0..stream.pos];
        },
        .right => writer.writeAll("Right") catch |err| {
            log.debug("failed to format Right key: {}", .{err});
            return buf[0..stream.pos];
        },
        .space => writer.writeAll("Space") catch |err| {
            log.debug("failed to format Space key: {}", .{err});
            return buf[0..stream.pos];
        },
        .char => {
            const ch = ev.key.char;
            switch (ch) {
                '\r' => writer.writeAll("Enter") catch |err| {
                    log.debug("failed to format Enter key: {}", .{err});
                    return buf[0..stream.pos];
                },
                '\t' => writer.writeAll("Tab") catch |err| {
                    log.debug("failed to format Tab key: {}", .{err});
                    return buf[0..stream.pos];
                },
                0x7f => writer.writeAll("Bksp") catch |err| {
                    log.debug("failed to format Backspace key: {}", .{err});
                    return buf[0..stream.pos];
                },
                0x1b => writer.writeAll("Esc") catch |err| {
                    log.debug("failed to format Escape key: {}", .{err});
                    return buf[0..stream.pos];
                },
                else => {
                    if (ch >= 0x20 and ch < 0x7f) {
                        writer.writeByte(ch) catch |err| {
                            log.debug("failed to format printable byte: {}", .{err});
                            return buf[0..stream.pos];
                        };
                    } else {
                        std.fmt.format(writer, "0x{x:0>2}", .{ch}) catch |err| {
                            log.debug("failed to format byte value: {}", .{err});
                            return buf[0..stream.pos];
                        };
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
    const trimmed_key = std.mem.trim(u8, exit_key, " \t\r\n");
    if (trimmed_key.len == 0) return false;

    const parsed = parseExitKeySpec(trimmed_key);
    const adhoc = isFocusedAdhocFloat(state);
    if (!(adhoc and parsed.mods == 0) and mods != parsed.mods) return false;

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

    closeFocusedFloatViaExitKey(state);
    return true;
}

/// Fallback matcher for undecoded raw stdin bytes.
/// This keeps adhoc exit keys responsive even if a terminal doesn't decode a
/// particular key press into a parser key event.
pub fn checkExitKeyRawByte(state: *State, b: u8) bool {
    if (!isFocusedAdhocFloat(state)) return false;
    const exit_key = getFocusedFloatExitKey(state) orelse return false;
    const trimmed_key = std.mem.trim(u8, exit_key, " \t\r\n");
    if (trimmed_key.len == 0) return false;

    const parsed = parseExitKeySpec(trimmed_key);
    if (parsed.mods != 0) return false;

    var expected = getKeyChar(parsed.key) orelse return false;
    var got = b;
    if (got >= 'A' and got <= 'Z') got = std.ascii.toLower(got);
    if (expected >= 'A' and expected <= 'Z') expected = std.ascii.toLower(expected);
    if (got != expected) return false;

    closeFocusedFloatViaExitKey(state);
    return true;
}

fn closeFocusedFloatViaExitKey(state: *State) void {
    if (state.activeFloatingIndex()) |idx| {
        if (idx < state.view.float_views.items.len) {
            state.setPaneClosedByExitKey(state.view.float_views.items[idx].uuid, true);
        }
    }
    actions.performClose(state);
    state.needs_render = true;
}

fn isFocusedAdhocFloat(state: *State) bool {
    const idx = state.activeFloatingIndex() orelse return false;
    if (idx >= state.view.float_views.items.len) return false;
    return state.paneFloatKey(state.view.float_views.items[idx]) == 0;
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
