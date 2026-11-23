const std = @import("std");
const core = @import("core");
const pop = @import("pop");
const vaxis = @import("vaxis");
const log = std.log.scoped(.terminal_input);

pub fn parseEvent(parser: *vaxis.Parser, bytes: []const u8, allocator: std.mem.Allocator) !vaxis.Parser.Result {
    if (std.mem.startsWith(u8, bytes, "\x1b[Z")) {
        return .{
            .event = .{ .key_press = .{ .codepoint = vaxis.Key.tab, .mods = .{ .shift = true } } },
            .n = 3,
        };
    }
    return parser.parse(bytes, allocator);
}

pub fn handlePopupEvent(popups: *pop.PopupManager, event: vaxis.Event) bool {
    const key = popupKeyFromVaxisEvent(event) orelse return false;
    const result = popups.handleKey(key);
    return result == .dismissed;
}

pub fn popupKeyFromVaxisEvent(event: vaxis.Event) ?pop.PopupKey {
    const key = switch (event) {
        .key_press => |k| k,
        else => return null,
    };

    if (key.mods.ctrl) {
        const cp = key.base_layout_codepoint orelse key.codepoint;
        if (cp == 'c' or cp == 'C' or cp == 0x03) return .ctrl_c;
        if (cp == 'u' or cp == 'U' or cp == 0x15) return .ctrl_u;
        if (cp == 'j' or cp == 'J' or cp == 'n' or cp == 'N') return .down;
        if (cp == 'k' or cp == 'K' or cp == 'p' or cp == 'P') return .up;
    }

    return switch (key.codepoint) {
        vaxis.Key.up => .up,
        vaxis.Key.down => .down,
        vaxis.Key.left => .left,
        vaxis.Key.right => .right,
        vaxis.Key.page_up => .page_up,
        vaxis.Key.page_down => .page_down,
        vaxis.Key.home => .home,
        vaxis.Key.end => .end,
        vaxis.Key.enter => .enter,
        vaxis.Key.tab => if (key.mods.shift) .shift_tab else .tab,
        vaxis.Key.backspace => .backspace,
        vaxis.Key.escape => .escape,
        else => blk: {
            if (key.codepoint == 0x03) break :blk .ctrl_c;
            if (key.codepoint == 0x15) break :blk .ctrl_u;
            if (key.codepoint == 0x7f or key.codepoint == 0x08) break :blk .backspace;
            if (key.codepoint == '\r' or key.codepoint == '\n') break :blk .enter;
            if (key.codepoint == '\t') break :blk if (key.mods.shift) .shift_tab else .tab;
            if (key.text) |txt| {
                if (txt.len == 1 and txt[0] >= 0x20 and txt[0] <= 0x7e) {
                    break :blk .{ .char = txt[0] };
                }
            }
            const cp = key.shifted_codepoint orelse key.base_layout_codepoint orelse key.codepoint;
            if (cp > 0xFF) break :blk null;
            break :blk .{ .char = @intCast(cp) };
        },
    };
}

pub const KeyEvent = struct {
    mods: u8,
    key: core.Config.BindKey,
    text_codepoint: ?u21,
    when: core.Config.BindWhen,
};

pub const ScrollAction = enum {
    page_up,
    page_down,
    home,
    end,
    shift_up,
    shift_down,
};

pub fn keyEventFromVaxisEvent(event: vaxis.Event) ?KeyEvent {
    return switch (event) {
        .key_press => |key| parseVaxisKey(key, .press),
        .key_release => |key| parseVaxisKey(key, .release),
        else => null,
    };
}

pub fn scrollActionFromVaxisEvent(event: vaxis.Event) ?ScrollAction {
    const key = switch (event) {
        .key_press => |k| k,
        else => return null,
    };

    return switch (key.codepoint) {
        vaxis.Key.page_up => .page_up,
        vaxis.Key.page_down => .page_down,
        vaxis.Key.home => .home,
        vaxis.Key.end => .end,
        vaxis.Key.up => if (key.mods.shift) .shift_up else null,
        vaxis.Key.down => if (key.mods.shift) .shift_down else null,
        else => null,
    };
}

fn parseVaxisKey(vk: vaxis.Key, when: core.Config.BindWhen) ?KeyEvent {
    var mods = modsMaskFromVaxis(vk.mods);
    const bind_key = vaxisKeyToBindKey(vk, &mods) orelse return null;
    const text_cp = switch (@as(core.Config.BindKeyKind, bind_key)) {
        .char, .space => textCodepointForForwarding(vk),
        else => null,
    };
    return .{
        .mods = mods,
        .key = bind_key,
        .text_codepoint = text_cp,
        .when = when,
    };
}

fn textCodepointForForwarding(vk: vaxis.Key) ?u21 {
    // Prefer parser-provided text when available. This preserves shifted
    // punctuation (e.g. ':' vs ';') and non-ASCII text input.
    if (vk.text) |txt| {
        var view = std.unicode.Utf8View.init(txt) catch |err| {
            log.debug("failed to parse forwarded key text as UTF-8: {}", .{err});
            return null;
        };
        var it = view.iterator();
        const cp = it.nextCodepoint() orelse return null;
        if (it.nextCodepoint() != null) return null;
        if (cp < 0x20 or cp == 0x7f) return null;
        if (cp >= 0x80 and cp <= 0x9f) return null;
        if (cp <= 0x10ffff) return cp;
    }

    // Fallback to shifted codepoint when available.
    if (vk.shifted_codepoint) |cp_shifted| {
        if (cp_shifted >= 0x20 and cp_shifted != 0x7f and !(cp_shifted >= 0x80 and cp_shifted <= 0x9f) and cp_shifted <= 0x10ffff) {
            return cp_shifted;
        }
    }

    const cp = vk.codepoint;
    if (cp < 0x20 or cp == 0x7f) return null;
    if (cp >= 0x80 and cp <= 0x9f) return null;
    if (cp > 0x10ffff) return null;
    return cp;
}

fn modsMaskFromVaxis(mods: vaxis.Key.Modifiers) u8 {
    var out: u8 = 0;
    if (mods.alt) out |= 1;
    if (mods.ctrl) out |= 2;
    if (mods.shift) out |= 4;
    if (mods.super) out |= 8;
    return out;
}

fn vaxisKeyToBindKey(vk: vaxis.Key, mods_inout: *u8) ?core.Config.BindKey {
    return switch (vk.codepoint) {
        vaxis.Key.up => .up,
        vaxis.Key.down => .down,
        vaxis.Key.left => .left,
        vaxis.Key.right => .right,
        vaxis.Key.space => .space,
        vaxis.Key.enter => .{ .char = '\r' },
        vaxis.Key.tab => .{ .char = '\t' },
        vaxis.Key.backspace => .{ .char = 0x7f },
        vaxis.Key.escape => .{ .char = 0x1b },
        else => blk: {
            var cp: u21 = vk.base_layout_codepoint orelse vk.codepoint;

            // Normalize Ctrl+letter control bytes (0x01..0x1A) to a-z.
            if (cp >= 1 and cp <= 26) {
                cp = 'a' + (cp - 1);
                mods_inout.* |= 2;
            }

            // The control bytes above the alphabet, which a legacy terminal sends bare and with no
            // modifier to say what they were. Without this they decode as unidentified keys with no
            // text, and the encoder — correctly — writes nothing for them, so ^\ ^] ^^ ^_ reach no
            // program in a pane at all.
            if (cp >= 0x1c and cp <= 0x1f) {
                cp = "\\]^_"[cp - 0x1c];
                mods_inout.* |= 2;
            }

            // Match config key style: use lowercase alpha key + shift mod.
            if (cp >= 'A' and cp <= 'Z') {
                cp = std.ascii.toLower(@intCast(cp));
                mods_inout.* |= 4;
            }

            if (cp > 0xFF) break :blk null;
            break :blk .{ .char = @intCast(cp) };
        },
    };
}
