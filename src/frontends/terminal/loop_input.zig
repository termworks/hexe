const std = @import("std");
const core = @import("core");
const ghostty = @import("ghostty-vt");
const vaxis = @import("vaxis");

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;
const input = @import("input.zig");

const actions = @import("loop_actions.zig");
const loop_ipc = @import("loop_ipc.zig");
const keybinds = @import("keybinds.zig");
const loop_input_keys = @import("loop_input_keys.zig");
const loop_mouse = @import("loop_mouse.zig");

const tab_switch = @import("tab_switch.zig");

// Mouse helpers moved to loop_mouse.zig.

// libvaxis parser for structured input events.
var vaxis_parser: vaxis.Parser = .{};

const ParsedEventHead = struct {
    n: usize,
    event: ?vaxis.Event,
};

fn parseEventHead(state: *State, bytes: []const u8) ?ParsedEventHead {
    const parsed = vaxis_parser.parse(bytes, state.allocator) catch return null;
    if (parsed.n == 0) return null;
    return .{ .n = parsed.n, .event = parsed.event };
}

fn applyQueryProbeKeyFlags(state: *State, key: vaxis.Key) void {
    if (!state.terminal_query_in_flight) return;
    if (key.codepoint != vaxis.Key.f3) return;

    // libvaxis probe path encodes explicit-width and scaled-text detection via
    // modified F3 key parses while query mode is active.
    if (key.mods.shift) state.renderer.vx.caps.explicit_width = true;
    if (key.mods.alt) state.renderer.vx.caps.scaled_text = true;
}

fn applyInputFlagsForEvent(state: *State, event: vaxis.Event) void {
    switch (event) {
        .key_press => |k| applyQueryProbeKeyFlags(state, k),
        .key_release => |k| applyQueryProbeKeyFlags(state, k),
        .paste_start => state.in_bracketed_paste = true,
        .paste_end => state.in_bracketed_paste = false,
        .cap_kitty_keyboard => state.renderer.vx.caps.kitty_keyboard = true,
        .cap_kitty_graphics => state.renderer.vx.caps.kitty_graphics = true,
        .cap_rgb => state.renderer.vx.caps.rgb = true,
        .cap_unicode => {
            state.renderer.vx.caps.unicode = .unicode;
            state.renderer.vx.screen.width_method = .unicode;
        },
        .cap_sgr_pixels => state.renderer.vx.caps.sgr_pixels = true,
        .cap_color_scheme_updates => state.renderer.vx.caps.color_scheme_updates = true,
        .cap_multi_cursor => state.renderer.vx.caps.multi_cursor = true,
        .cap_da1 => {
            state.renderer.vx.queries_done.store(true, .unordered);
        },
        else => {},
    }
}

fn isModifierOnlyKey(cp: u21) bool {
    return cp == vaxis.Key.left_shift or cp == vaxis.Key.left_control or cp == vaxis.Key.left_alt or cp == vaxis.Key.left_super or
        cp == vaxis.Key.right_shift or cp == vaxis.Key.right_control or cp == vaxis.Key.right_alt or cp == vaxis.Key.right_super or
        cp == vaxis.Key.iso_level_3_shift or cp == vaxis.Key.iso_level_5_shift;
}

fn forwardSanitizedToFocusedPane(state: *State, bytes: []const u8, parsed_event: ?vaxis.Event) void {
    keybinds.forwardInputToFocusedPaneWithEvent(state, bytes, parsed_event);
}

fn mergeStdinTail(state: *State, input_bytes: []const u8) struct { merged: []const u8, owned: ?[]u8 } {
    if (state.stdin_tail_len == 0) return .{ .merged = input_bytes, .owned = null };

    const tl: usize = @intCast(state.stdin_tail_len);
    const total = tl + input_bytes.len;
    var tmp = state.allocator.alloc(u8, total) catch {
        // Allocation failure: drop tail rather than corrupt memory.
        state.stdin_tail_len = 0;
        return .{ .merged = input_bytes, .owned = null };
    };
    @memcpy(tmp[0..tl], state.stdin_tail[0..tl]);
    @memcpy(tmp[tl..total], input_bytes);
    state.stdin_tail_len = 0;
    return .{ .merged = tmp, .owned = tmp };
}

fn firstControlTrafficIndex(bytes: []const u8) ?usize {
    var first: ?usize = null;
    if (std.mem.indexOfScalar(u8, bytes, 0x1b)) |i| first = i;
    if (std.mem.indexOfScalar(u8, bytes, 0x9b)) |i| {
        if (first == null or i < first.?) first = i;
    }
    if (std.mem.indexOfScalar(u8, bytes, 0x9d)) |i| {
        if (first == null or i < first.?) first = i;
    }
    return first;
}

fn stashIncompleteParserTail(state: *State, inp: []const u8) []const u8 {
    var i: usize = 0;
    while (i < inp.len) {
        const res = vaxis_parser.parse(inp[i..], state.allocator) catch {
            i += 1;
            continue;
        };

        if (res.n == 0) {
            return stashFromIndex(state, inp, i);
        }
        i += res.n;
    }

    return inp;
}

fn stashFromIndex(state: *State, inp: []const u8, start: usize) []const u8 {
    const tail = inp[start..];
    if (tail.len == 0) return inp;
    if (tail.len > state.stdin_tail.len) {
        // Too large to stash; don't block input.
        return inp;
    }
    @memcpy(state.stdin_tail[0..tail.len], tail);
    state.stdin_tail_len = @intCast(tail.len);
    return inp[0..start];
}

fn handleParsedScrollAction(state: *State, action: input.ScrollAction) bool {
    const pane: ?*Pane = if (state.activeFloatingIndex()) |idx|
        state.view.floats.items[idx]
    else
        state.currentLayout().getFocusedPane();
    if (pane == null) return false;

    const p = pane.?;
    if (p.vt.inAltScreen()) return false;

    const now = std.time.milliTimestamp();
    const acceleration_timeout_ms: i64 = core.constants.Timing.mouse_acceleration_timeout;

    switch (action) {
        .page_up => {
            if (state.last_scroll_key == 5 and (now - state.last_scroll_time_ms) < acceleration_timeout_ms) {
                state.scroll_repeat_count = @min(state.scroll_repeat_count + 1, 20);
            } else {
                state.scroll_repeat_count = 0;
            }
            state.last_scroll_key = 5;
            state.last_scroll_time_ms = now;
            const scroll_amount: u32 = @min(5 + (@as(u32, state.scroll_repeat_count) * 3), 65);
            p.scrollUp(scroll_amount);
        },
        .page_down => {
            if (state.last_scroll_key == 6 and (now - state.last_scroll_time_ms) < acceleration_timeout_ms) {
                state.scroll_repeat_count = @min(state.scroll_repeat_count + 1, 20);
            } else {
                state.scroll_repeat_count = 0;
            }
            state.last_scroll_key = 6;
            state.last_scroll_time_ms = now;
            const scroll_amount: u32 = @min(5 + (@as(u32, state.scroll_repeat_count) * 3), 65);
            p.scrollDown(scroll_amount);
        },
        .home => p.scrollToTop(),
        .end => p.scrollToBottom(),
        .shift_up => p.scrollUp(1),
        .shift_down => p.scrollDown(1),
    }

    state.needs_render = true;
    return true;
}

fn forwardPasteToFocusedPane(state: *State, txt: []const u8) void {
    if (txt.len == 0) return;

    if (resolveFocusedPaneForInput(state)) |pane| {
        if (pane.popups.isBlocked()) return;
        if (pane.isScrolled()) {
            pane.scrollToBottom();
            state.needs_render = true;
        }
        sendEncodedPasteToPane(state, pane, txt);
    }
}

fn sendEncodedPasteToPane(state: *State, pane: *Pane, txt: []const u8) void {
    if (txt.len == 0) return;

    const opts = ghostty.input.PasteOptions.fromTerminal(&pane.vt.terminal);
    const vecs = ghostty.input.encodePaste(txt, opts) catch |err| switch (err) {
        error.MutableRequired => {
            const copy = state.allocator.dupe(u8, txt) catch return;
            defer state.allocator.free(copy);
            const parts = ghostty.input.encodePaste(copy, opts);
            for (parts) |part| {
                if (part.len == 0) continue;
                state.writePaneInput(pane, part);
            }
            return;
        },
    };

    for (vecs) |part| {
        if (part.len == 0) continue;
        state.writePaneInput(pane, part);
    }
}

fn beginBracketedPaste(state: *State) void {
    state.in_bracketed_paste = true;
    state.bracketed_paste_target_uuid = if (resolveFocusedPaneForInput(state)) |pane| pane.uuid else null;
    state.bracketed_paste_buf.clearRetainingCapacity();
}

fn appendBracketedPasteBytes(state: *State, bytes: []const u8) void {
    if (!state.in_bracketed_paste) return;
    if (bytes.len == 0) return;
    state.bracketed_paste_buf.appendSlice(state.allocator, bytes) catch {};
}

fn finishBracketedPaste(state: *State) void {
    defer {
        state.in_bracketed_paste = false;
        state.bracketed_paste_target_uuid = null;
        state.bracketed_paste_buf.clearRetainingCapacity();
    }

    const uuid = state.bracketed_paste_target_uuid orelse return;
    const pane = state.findPaneByUuid(uuid) orelse return;
    if (pane.popups.isBlocked()) return;
    if (pane.isScrolled()) {
        pane.scrollToBottom();
        state.needs_render = true;
    }
    sendEncodedPasteToPane(state, pane, state.bracketed_paste_buf.items);
}

fn applyInBandWinsize(state: *State, ws: vaxis.Winsize) void {
    const cols = ws.cols;
    const rows = ws.rows;
    state.applyTerminalResize(cols, rows);
}

fn handleBlockedPopupInput(popups: anytype, parsed_event: ?vaxis.Event) bool {
    if (parsed_event) |ev| {
        // Reuse already parsed event and avoid reparsing raw bytes.
        return input.handlePopupEvent(popups, ev);
    }
    return false;
}

fn freeParsedEventPayload(state: *State, parsed_event: ?vaxis.Event) void {
    const ev = parsed_event orelse return;
    switch (ev) {
        .paste => |txt| state.allocator.free(txt),
        else => {},
    }
}

fn resolveFocusedPaneForInput(state: *State) ?*Pane {
    if (state.activeFloatingIndex()) |idx| {
        const fpane = state.view.floats.items[idx];
        const can_interact = if (fpane.parent_tab) |parent|
            parent == state.activeTabIndex()
        else
            true;
        if (fpane.isVisibleOnTab(state.activeTabIndex()) and can_interact) return fpane;
    }
    return state.currentLayout().getFocusedPane();
}

fn runLayoutSaveWithScope(state: *State, scope: []const u8) void {
    const pane = resolveFocusedPaneForInput(state) orelse {
        state.notifications.showFor("no focused pane for layout save", 1400);
        return;
    };

    const cmd = std.fmt.allocPrint(state.allocator, "hexe lay save --scope {s}", .{scope}) catch {
        state.notifications.showFor("layout save alloc failed", 1400);
        return;
    };
    defer state.allocator.free(cmd);

    pane.write(cmd) catch {
        state.notifications.showFor("layout save send failed", 1400);
        return;
    };
    pane.write("\n") catch {
        state.notifications.showFor("layout save send failed", 1400);
        return;
    };
    state.notifications.showFor("layout save command sent", 1200);
}

fn runLayoutOpenDetached(state: *State) void {
    var env_map_opt = std.process.getEnvMap(state.allocator) catch null;
    defer if (env_map_opt) |*m| m.deinit();

    if (env_map_opt) |*env_map| {
        env_map.remove("HEXE_PANE_UUID");
        env_map.remove("HEXE_FOCUSED_PANE_UUID");
        env_map.remove("HEXE_STATUS_FOCUSED_PANE_UUID");
    }

    var child = std.process.Child.init(&.{ "/bin/bash", "-lc", "(hexe lay open .) >/dev/null 2>&1 &" }, state.allocator);
    if (env_map_opt) |*env_map| child.env_map = env_map;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch {
        state.notifications.showFor("layout open spawn failed", 1400);
        return;
    };
    _ = child.wait() catch {};
    actions.performDetach(state);
}

fn replaceFromLocalLayout(state: *State) void {
    var cfg = core.session_config.parseSessionLua(state.allocator, ".hexe.lua") catch {
        state.notifications.showFor("failed to parse .hexe.lua", 1500);
        return;
    };
    defer cfg.deinit(state.allocator);

    if (cfg.name) |desired_name| {
        if (state.setSessionName(desired_name)) {
            if (state.runtime.syncSessionIdentity() catch null) |change| {
                var owned_change = change;
                defer owned_change.deinit(state.allocator);
            }
        }
    }

    state.replaceWithSessionConfig(cfg, null) catch {
        state.notifications.showFor("failed to apply local layout", 1500);
        return;
    };

    state.notifications.showFor("local layout loaded", 1200);
    state.needs_render = true;
    state.force_full_render = true;
}

fn handleMuxLevelPopup(state: *State, parsed_event: ?vaxis.Event) bool {
    if (!state.popups.isBlocked()) return false;
    defer freeParsedEventPayload(state, parsed_event);

    if (handleBlockedPopupInput(&state.popups, parsed_event)) {
        // Check if this was a confirm/picker dialog for pending action
        if (state.pending_action) |action| {
            switch (action) {
                .adopt_choose => {
                    // Handle picker result for selecting orphaned pane
                    if (state.popups.getPickerResult()) |selected| {
                        if (selected < state.attach_state.adopt_orphan_count) {
                            state.attach_state.adopt_selected_uuid = state.attach_state.adopt_orphans[selected].uuid;
                            // Now show confirm dialog
                            state.pending_action = .adopt_confirm;
                            state.popups.clearResults();
                            state.popups.showConfirm("Destroy current pane?", .{}) catch {};
                        } else {
                            state.pending_action = null;
                        }
                    } else if (state.popups.wasPickerCancelled()) {
                        state.pending_action = null;
                        state.popups.clearResults();
                    }
                },
                .adopt_confirm => {
                    // Handle confirm result for adopt action
                    if (state.popups.getConfirmResult()) |destroy_current| {
                        if (state.attach_state.adopt_selected_uuid) |uuid| {
                            actions.performAdopt(state, uuid, destroy_current);
                        }
                    }
                    state.pending_action = null;
                    state.attach_state.adopt_selected_uuid = null;
                    state.popups.clearResults();
                },
                .layout_save_choose => {
                    if (state.popups.getPickerResult()) |selected| {
                        const scope = switch (selected) {
                            0 => "local",
                            1 => "global",
                            2 => "both",
                            else => "both",
                        };
                        runLayoutSaveWithScope(state, scope);
                    }
                    state.pending_action = null;
                    state.popups.clearResults();
                },
                .layout_load_choose => {
                    if (state.popups.getPickerResult()) |selected| {
                        switch (selected) {
                            0 => runLayoutOpenDetached(state),
                            1 => replaceFromLocalLayout(state),
                            else => {},
                        }
                    }
                    state.pending_action = null;
                    state.popups.clearResults();
                },
                else => {
                    // Handle other confirm dialogs (exit/detach/disown/close)
                    if (state.popups.getConfirmResult()) |confirmed| {
                        if (confirmed) {
                            switch (action) {
                                .exit => state.running = false,
                                .exit_intent => {
                                    // Shell will exit itself; we only approve.
                                    // Arm a short window to skip the later "Shell exited" confirm.
                                    state.exit_intent_deadline_ms = std.time.milliTimestamp() + 5000;
                                },
                                .detach => actions.performDetach(state),
                                .disown => actions.performDisown(state),
                                .close => actions.performClose(state),
                                .pane_close => {
                                    // Close split pane only (not tab).
                                    const layout = state.currentLayout();
                                    if (layout.splitCount() > 1) {
                                        _ = layout.closePane(layout.focused_split_id);
                                        if (layout.getFocusedPane()) |new_pane| {
                                            state.syncPaneFocus(new_pane, null);
                                        }
                                        state.syncActiveTabLayout();
                                    }
                                },
                                else => {},
                            }
                        } else {
                            // User cancelled - if exit was from shell death, defer respawn
                            if (action == .exit and state.exit_from_shell_death) {
                                state.needs_respawn = true;
                            }
                        }

                        // Reply to a pending exit_intent request via SES.
                        if (action == .exit_intent) {
                            loop_ipc.sendExitIntentResultPub(state, confirmed);
                            state.pending_exit_intent = false;
                        }
                    }
                    state.pending_action = null;
                    state.exit_from_shell_death = false;
                    state.popups.clearResults();
                },
            }
        } else {
            loop_ipc.sendPopResponse(state);
        }
    }
    state.needs_render = true;
    return true;
}

fn handleTabLevelPopup(state: *State, parsed_event: ?vaxis.Event) bool {
    const current_tab = &state.view.tabs.items[state.activeTabIndex()];
    if (!current_tab.popups.isBlocked()) return false;
    defer freeParsedEventPayload(state, parsed_event);

    // Allow only tab switching while a tab popup is open.
    if (parsed_event) |ev_raw| {
        if (input.keyEventFromVaxisEvent(ev_raw)) |ev| {
            if (keybinds.handleKeyEvent(state, ev.mods, ev.key, ev.when, true)) {
                return true;
            }
        }
    }

    // Block everything else - handle popup input.
    if (handleBlockedPopupInput(&current_tab.popups, parsed_event)) {
        loop_ipc.sendPopResponse(state);
    }
    state.needs_render = true;
    return true;
}

fn appendFloatRenameText(state: *State, text: []const u8) void {
    if (text.len == 0) return;
    const max_len: usize = 64;
    if (state.float_rename_buf.items.len >= max_len) return;
    const remaining = max_len - state.float_rename_buf.items.len;
    const n = @min(text.len, remaining);
    state.float_rename_buf.appendSlice(state.allocator, text[0..n]) catch return;
    state.needs_render = true;
}

fn handleFloatRenameParsedEvent(state: *State, parsed: ParsedEventHead) bool {
    if (state.float_rename_uuid == null) return false;

    const event = parsed.event orelse return true;
    return switch (event) {
        .mouse => false,
        .paste => |txt| blk: {
            defer state.allocator.free(txt);
            appendFloatRenameText(state, txt);
            break :blk true;
        },
        .key_release => true,
        .key_press => |k| blk: {
            switch (k.codepoint) {
                vaxis.Key.escape => {
                    state.clearFloatRename();
                    break :blk true;
                },
                vaxis.Key.enter => {
                    state.commitFloatRename();
                    break :blk true;
                },
                vaxis.Key.backspace => {
                    if (state.float_rename_buf.items.len > 0) {
                        _ = state.float_rename_buf.pop();
                        state.needs_render = true;
                    }
                    break :blk true;
                },
                else => {},
            }

            if (k.text) |txt| {
                appendFloatRenameText(state, txt);
                break :blk true;
            }

            const cp = k.base_layout_codepoint orelse k.codepoint;
            if (cp >= 32 and cp < 127) {
                const b: u8 = @intCast(cp);
                appendFloatRenameText(state, &.{b});
            }
            break :blk true;
        },
        else => true,
    };
}

const KeyDispatchResult = enum {
    consumed,
    quit,
    unhandled,
};

const ParsedDispatchResult = struct {
    consumed: bool,
    quit: bool,
    parsed_event: ?vaxis.Event,
    consumed_bytes: usize,
};

fn handleParsedNonKeyEvent(state: *State, ev: vaxis.Event) bool {
    switch (ev) {
        .mouse => |m| {
            _ = loop_mouse.handle(state, m);
            return true;
        },
        .mouse_leave => {
            loop_mouse.resetShape(state);
            return true;
        },
        .paste => |txt| {
            defer state.allocator.free(txt);
            forwardPasteToFocusedPane(state, txt);
            return true;
        },
        .paste_start,
        .paste_end,
        => return true,
        .winsize => |ws| {
            applyInBandWinsize(state, ws);
            return true;
        },
        .color_scheme => {
            state.renderer.invalidate();
            state.needs_render = true;
            return true;
        },
        .key_press => |k| return isModifierOnlyKey(k.codepoint),
        .key_release => |k| return isModifierOnlyKey(k.codepoint),
        .color_report,
        .focus_in,
        .focus_out,
        .cap_kitty_keyboard,
        .cap_kitty_graphics,
        .cap_rgb,
        .cap_unicode,
        .cap_sgr_pixels,
        .cap_color_scheme_updates,
        .cap_multi_cursor,
        .cap_da1,
        => return true,
    }
}

fn dispatchParsedEvent(state: *State, parsed: anytype) ParsedDispatchResult {
    if (parsed.n == 0) return .{ .consumed = false, .quit = false, .parsed_event = null, .consumed_bytes = 0 };
    if (parsed.event == null) return .{ .consumed = true, .quit = false, .parsed_event = null, .consumed_bytes = parsed.n };

    const ev = parsed.event.?;
    applyInputFlagsForEvent(state, ev);

    if (input.scrollActionFromVaxisEvent(ev)) |action| {
        if (handleParsedScrollAction(state, action)) {
            return .{ .consumed = true, .quit = false, .parsed_event = ev, .consumed_bytes = parsed.n };
        }
    }

    if (input.keyEventFromVaxisEvent(ev)) |key_ev| {
        switch (handleParsedKeyEvent(state, key_ev)) {
            .quit => return .{ .consumed = true, .quit = true, .parsed_event = ev, .consumed_bytes = parsed.n },
            .consumed => return .{ .consumed = true, .quit = false, .parsed_event = ev, .consumed_bytes = parsed.n },
            .unhandled => {
                // Never forward parser key-release bytes to panes.
                if (key_ev.when == .release) {
                    return .{ .consumed = true, .quit = false, .parsed_event = ev, .consumed_bytes = parsed.n };
                }
            },
        }
    }

    if (handleParsedNonKeyEvent(state, ev)) {
        return .{ .consumed = true, .quit = false, .parsed_event = ev, .consumed_bytes = parsed.n };
    }

    // If libvaxis decoded a key press that doesn't map to local BindKey
    // (for example PageUp/PageDown/Home/End/function keys), forward the
    // original bytes to the focused pane unchanged.
    switch (ev) {
        .key_press => |k| {
            // Never leak internal probe keys or bare modifier keys to panes.
            if ((state.terminal_query_in_flight and k.codepoint == vaxis.Key.f3) or isModifierOnlyKey(k.codepoint)) {
                return .{ .consumed = true, .quit = false, .parsed_event = ev, .consumed_bytes = parsed.n };
            }
            return .{ .consumed = false, .quit = false, .parsed_event = ev, .consumed_bytes = parsed.n };
        },
        .key_release => return .{ .consumed = true, .quit = false, .parsed_event = ev, .consumed_bytes = parsed.n },
        else => {},
    }

    // Parser-first policy: never forward decoded-but-unmapped events as raw bytes.
    return .{ .consumed = true, .quit = false, .parsed_event = ev, .consumed_bytes = parsed.n };
}

fn handleParsedKeyEvent(state: *State, ev: input.KeyEvent) KeyDispatchResult {
    if (loop_input_keys.checkExitKeyEvent(state, ev.mods, ev.key, ev.when)) {
        return .consumed;
    }

    if (ev.when == .press and ev.mods == 2 and @as(core.Config.BindKeyKind, ev.key) == .char and ev.key.char == 'q') {
        return .quit;
    }

    if (keybinds.handleKeyEvent(state, ev.mods, ev.key, ev.when, false)) {
        return .consumed;
    }

    // Require exact modifier matches for keybindings.
    // This prevents Alt+key from accidentally triggering Ctrl+Alt+key bindings.

    if (ev.when == .press) {
        keybinds.forwardKeyToPaneWithText(state, ev.mods, ev.key, ev.text_codepoint);
        return .consumed;
    }

    return .unhandled;
}

fn firstOrParseAt(state: *State, inp: []const u8, offset: usize, first: ?ParsedEventHead) ?ParsedEventHead {
    if (offset == 0) return first;
    return parseEventHead(state, inp[offset..]);
}

fn handlePaneSelectLoop(state: *State, inp: []const u8, first_parsed: ?ParsedEventHead) void {
    var i: usize = 0;
    while (i < inp.len) {
        const parsed = firstOrParseAt(state, inp, i, first_parsed);
        if (parsed) |res| {
            i += res.n;
            _ = actions.handlePaneSelectEvent(state, res.event);
            freeParsedEventPayload(state, res.event);
            continue;
        }

        // Keep pane-select mode isolated on parser failures.
        i += 1;
    }
}

fn handleFocusedInputLoop(state: *State, inp: []const u8, first_parsed: ?ParsedEventHead) void {
    var i: usize = 0;
    while (i < inp.len) {
        var parsed_event_for_popup: ?vaxis.Event = null;
        var forward_bytes: ?[]const u8 = null;

        // Parse once through libvaxis and dispatch key/scroll/mouse/control.
        const parsed = firstOrParseAt(state, inp, i, first_parsed);
        if (parsed) |res| {
            if (handleFloatRenameParsedEvent(state, res)) {
                i += res.n;
                continue;
            }

            if (state.in_bracketed_paste) {
                if (res.event) |ev| {
                    switch (ev) {
                        .paste_end => {
                            freeParsedEventPayload(state, res.event);
                            finishBracketedPaste(state);
                            i += res.n;
                            continue;
                        },
                        .paste_start => {
                            freeParsedEventPayload(state, res.event);
                            i += res.n;
                            continue;
                        },
                        else => {},
                    }
                }

                appendBracketedPasteBytes(state, inp[i .. i + res.n]);
                freeParsedEventPayload(state, res.event);
                i += res.n;
                continue;
            }

            if (res.event) |ev| {
                switch (ev) {
                    .paste_start => {
                        freeParsedEventPayload(state, res.event);
                        beginBracketedPaste(state);
                        i += res.n;
                        continue;
                    },
                    .paste_end => {
                        freeParsedEventPayload(state, res.event);
                        finishBracketedPaste(state);
                        i += res.n;
                        continue;
                    },
                    else => {},
                }
            }

            const dispatch = dispatchParsedEvent(state, res);
            parsed_event_for_popup = dispatch.parsed_event;
            if (dispatch.quit) {
                state.running = false;
                return;
            }
            if (dispatch.consumed) {
                i += dispatch.consumed_bytes;
                continue;
            }

            forward_bytes = inp[i .. i + res.n];
        } else {
            // Parser-first policy: never forward undecoded bytes.
            // Keep rename mode isolated and drop unknown bytes in normal mode.
            i += 1;
            continue;
        }

        // ======================================================================
        // LEVEL 3: Focused pane (float or split) popup + input forwarding
        // ======================================================================
        if (resolveFocusedPaneForInput(state)) |pane| {
            if (pane.popups.isBlocked()) {
                if (handleBlockedPopupInput(&pane.popups, parsed_event_for_popup)) {
                    loop_ipc.sendPopResponse(state);
                }
                state.needs_render = true;
                return;
            }
            if (pane.isScrolled()) {
                pane.scrollToBottom();
                state.needs_render = true;
            }
            if (forward_bytes) |bytes| {
                forwardSanitizedToFocusedPane(state, bytes, parsed_event_for_popup);
            }
        }
        return;
    }
}

fn clearOscReplyCapture(state: *State) void {
    state.osc_reply_in_progress = false;
    state.osc_reply_prev_esc = false;
    state.osc_reply_target_uuid = null;
    state.osc_reply_buf.clearRetainingCapacity();
}

fn dequeueLiveOscReplyTarget(state: *State) ?[32]u8 {
    while (state.dequeueOscReplyTarget()) |uuid| {
        if (state.findPaneByUuid(uuid) != null) return uuid;
    }
    return null;
}

fn routeCapturedOscReply(state: *State) void {
    if (state.osc_reply_target_uuid) |uuid| {
        if (state.findPaneByUuid(uuid)) |pane| {
            state.writePaneInput(pane, state.osc_reply_buf.items);
        }
    }
}

fn clearCsiReplyCapture(state: *State) void {
    state.csi_reply_in_progress = false;
    state.csi_reply_target_uuid = null;
    state.csi_reply_buf.clearRetainingCapacity();
}

fn dequeueLiveCsiReplyTarget(state: *State) ?[32]u8 {
    while (state.dequeueCsiReplyTarget()) |uuid| {
        if (state.findPaneByUuid(uuid) != null) return uuid;
    }
    return null;
}

fn routeCapturedCsiReply(state: *State) void {
    if (state.csi_reply_target_uuid) |uuid| {
        if (state.findPaneByUuid(uuid)) |pane| {
            state.writePaneInput(pane, state.csi_reply_buf.items);
        }
    }
}

fn queuePaneCsiExpected(state: *State, pane: *Pane) bool {
    const n = pane.takeCsiExpectedResponses();
    if (n == 0) return false;
    var j: u16 = 0;
    while (j < n) : (j += 1) {
        state.enqueueCsiReplyTarget(pane.uuid);
    }
    return true;
}

fn queuePaneOscExpected(state: *State, pane: *Pane) bool {
    const n = pane.takeOscExpectedResponses();
    if (n == 0) return false;
    var j: u16 = 0;
    while (j < n) : (j += 1) {
        state.enqueueOscReplyTarget(pane.uuid);
    }
    return true;
}

fn harvestPendingCsiReplies(state: *State) void {
    // Drain pending CSI reply expectations from all panes.
    for (state.view.tabs.items) |*tab| {
        var pane_it = tab.layout.splitIterator();
        while (pane_it.next()) |p| {
            const n = p.*.takeCsiExpectedResponses();
            if (n > 0) {
                var j: u16 = 0;
                while (j < n) : (j += 1) {
                    state.enqueueCsiReplyTarget(p.*.uuid);
                }
            }
        }
    }
    for (state.view.floats.items) |fp| {
        const n = fp.takeCsiExpectedResponses();
        if (n > 0) {
            var j: u16 = 0;
            while (j < n) : (j += 1) {
                state.enqueueCsiReplyTarget(fp.uuid);
            }
        }
    }
}

fn harvestPendingOscReplies(state: *State) void {
    // Drain pending OSC reply expectations from all panes.
    for (state.view.tabs.items) |*tab| {
        var pane_it = tab.layout.splitIterator();
        while (pane_it.next()) |p| {
            const n = p.*.takeOscExpectedResponses();
            if (n > 0) {
                var j: u16 = 0;
                while (j < n) : (j += 1) {
                    state.enqueueOscReplyTarget(p.*.uuid);
                }
            }
        }
    }
    for (state.view.floats.items) |fp| {
        const n = fp.takeOscExpectedResponses();
        if (n > 0) {
            var j: u16 = 0;
            while (j < n) : (j += 1) {
                state.enqueueOscReplyTarget(fp.uuid);
            }
        }
    }
}

fn parseLikelyTerminalCsiReplyLen(inp: []const u8, start: usize) usize {
    if (start >= inp.len) return 0;

    var i = start;
    const CSI_C1: u8 = 0x9b;
    if (inp[i] == 0x1b) {
        if (i + 1 >= inp.len or inp[i + 1] != '[') return 0;
        i += 2;
    } else if (inp[i] == CSI_C1) {
        i += 1;
    } else {
        return 0;
    }

    while (i < inp.len and inp[i] >= 0x30 and inp[i] <= 0x3f) : (i += 1) {}
    while (i < inp.len and inp[i] >= 0x20 and inp[i] <= 0x2f) : (i += 1) {}
    if (i >= inp.len) return 0;

    const final = inp[i];
    const seq = inp[start .. i + 1];

    if (final == 'c') {
        if (std.mem.indexOf(u8, seq, "[?") != null) return seq.len;
        if (std.mem.indexOf(u8, seq, "[>") != null) return seq.len;
        return 0;
    }
    if (final == 'n') {
        if (std.mem.endsWith(u8, seq, "0n") or std.mem.endsWith(u8, seq, "3n")) return seq.len;
        return 0;
    }
    if (final == 'R') {
        if (std.mem.indexOfScalar(u8, seq, ';') != null) return seq.len;
        return 0;
    }
    if (final == 'y') {
        if (std.mem.indexOf(u8, seq, "$y") != null) return seq.len;
        return 0;
    }
    if (final == 'u') {
        if (std.mem.indexOf(u8, seq, "[?") != null) return seq.len;
        return 0;
    }

    return 0;
}

pub fn handleInput(state: *State, input_bytes: []const u8) void {
    if (input_bytes.len == 0) return;

    var effective_input = input_bytes;

    if (state.drop_next_input_batch) {
        var keep_all = false;
        if (state.stdin_tail_len > 0) {
            const tl: usize = @intCast(state.stdin_tail_len);
            keep_all = firstControlTrafficIndex(state.stdin_tail[0..tl]) != null;
        }

        if (!keep_all) {
            if (firstControlTrafficIndex(input_bytes)) |idx| {
                if (idx > 0) {
                    effective_input = input_bytes[idx..];
                }
            } else {
                // Plain trigger-key batch: drop it entirely.
                state.drop_next_input_batch = false;
                state.stdin_tail_len = 0;
                vaxis_parser = .{};
                return;
            }
        }

        // Control/reply traffic is preserved (with optional plain-key prefix trimmed).
        if (effective_input.len == 0) {
            state.drop_next_input_batch = false;
            state.stdin_tail_len = 0;
            vaxis_parser = .{};
            return;
        }
        state.drop_next_input_batch = false;
    }

    // Stdin reads can split escape sequences. Merge with any pending tail first.
    const merged_res = mergeStdinTail(state, effective_input);
    defer if (merged_res.owned) |m| state.allocator.free(m);

    const osc_res = consumeOscReplyFromTerminal(state, merged_res.merged);
    defer if (osc_res.owned) |m| state.allocator.free(m);
    const csi_res = consumeCsiReplyFromTerminal(state, osc_res.bytes);
    defer if (csi_res.owned) |m| state.allocator.free(m);
    const slice = csi_res.bytes;
    if (slice.len == 0) return;

    // Don't process (or forward) partial parser events.
    const stable = stashIncompleteParserTail(state, slice);
    if (stable.len == 0) return;

    const cpr_res = consumeCprRepliesFromTerminal(state, stable);
    defer if (cpr_res.owned) |m| state.allocator.free(m);
    const inp = cpr_res.bytes;
    if (inp.len == 0) return;

    // Record all input for keycast display (before any processing)
    loop_input_keys.recordKeycastInput(state, inp);

    const first_parsed = parseEventHead(state, inp);
    const popup_event: ?vaxis.Event = if (first_parsed) |h| h.event else null;

    if (handleMuxLevelPopup(state, popup_event)) return;
    if (handleTabLevelPopup(state, popup_event)) return;

    // ==========================================================================
    // LEVEL 2.5: Pane select mode - captures all input
    // ==========================================================================
    if (state.overlays.isPaneSelectActive()) {
        handlePaneSelectLoop(state, inp, first_parsed);
        return;
    }

    handleFocusedInputLoop(state, inp, first_parsed);
}

pub fn switchToTab(state: *State, new_tab: usize) void {
    tab_switch.switchToTab(state, new_tab);
}

const OscConsumeResult = struct {
    bytes: []const u8,
    owned: ?[]u8 = null,
};

fn consumeOscReplyFromTerminal(state: *State, inp: []const u8) OscConsumeResult {
    harvestPendingOscReplies(state);

    if (inp.len == 0) return .{ .bytes = inp };
    if (!state.osc_reply_in_progress and state.osc_reply_targets.items.len == 0) {
        return .{ .bytes = inp };
    }

    const ESC: u8 = 0x1b;
    const BEL: u8 = 0x07;
    const OSC_C1: u8 = 0x9d;
    const ST_C1: u8 = 0x9c;

    const out = state.allocator.alloc(u8, inp.len) catch return .{ .bytes = inp };
    var out_i: usize = 0;
    var consumed_any = false;

    var i: usize = 0;
    while (i < inp.len) {
        if (!state.osc_reply_in_progress and state.osc_reply_targets.items.len == 0) {
            const starts_esc_osc = i + 1 < inp.len and inp[i] == ESC and inp[i + 1] == ']';
            const starts_c1_osc = inp[i] == OSC_C1;
            if (starts_esc_osc or starts_c1_osc) {
                // Best-effort race guard: pane output and terminal input can be
                // serviced in either order within the loop tick.
                harvestPendingOscReplies(state);
            }
        }

        if (!state.osc_reply_in_progress and state.osc_reply_targets.items.len > 0) {
            const starts_esc_osc = i + 1 < inp.len and inp[i] == ESC and inp[i + 1] == ']';
            const starts_c1_osc = inp[i] == OSC_C1;
            if (!starts_esc_osc and !starts_c1_osc) {
                out[out_i] = inp[i];
                out_i += 1;
                i += 1;
                continue;
            }

            state.osc_reply_target_uuid = dequeueLiveOscReplyTarget(state);
            if (state.osc_reply_target_uuid == null) {
                out[out_i] = inp[i];
                out_i += 1;
                i += 1;
                continue;
            }
            state.osc_reply_in_progress = true;
            state.osc_reply_prev_esc = false;
            state.osc_reply_buf.clearRetainingCapacity();

            if (starts_esc_osc) {
                state.osc_reply_buf.append(state.allocator, ESC) catch {
                    clearOscReplyCapture(state);
                    out[out_i] = inp[i];
                    out_i += 1;
                    i += 1;
                    continue;
                };
                state.osc_reply_buf.append(state.allocator, ']') catch {
                    clearOscReplyCapture(state);
                    out[out_i] = inp[i];
                    out_i += 1;
                    i += 1;
                    continue;
                };
                i += 2;
            } else {
                state.osc_reply_buf.append(state.allocator, OSC_C1) catch {
                    clearOscReplyCapture(state);
                    out[out_i] = inp[i];
                    out_i += 1;
                    i += 1;
                    continue;
                };
                i += 1;
            }
            consumed_any = true;
            continue;
        }

        if (!state.osc_reply_in_progress) {
            out[out_i] = inp[i];
            out_i += 1;
            i += 1;
            continue;
        }

        const b = inp[i];
        state.osc_reply_buf.append(state.allocator, b) catch {
            clearOscReplyCapture(state);
            i += 1;
            continue;
        };
        consumed_any = true;

        var done = false;
        if (b == BEL) {
            done = true;
        } else if (state.osc_reply_prev_esc and b == '\\') {
            done = true;
        } else if (b == ST_C1) {
            done = true;
        }
        state.osc_reply_prev_esc = (b == ESC);

        if (state.osc_reply_buf.items.len > 64 * 1024) {
            clearOscReplyCapture(state);
            i += 1;
            continue;
        }

        if (done) {
            routeCapturedOscReply(state);
            clearOscReplyCapture(state);
        }

        i += 1;
    }

    if (!consumed_any) {
        state.allocator.free(out);
        return .{ .bytes = inp };
    }
    if (out_i == 0) {
        state.allocator.free(out);
        return .{ .bytes = &[_]u8{} };
    }
    if (out_i == inp.len) {
        state.allocator.free(out);
        return .{ .bytes = inp };
    }

    const trimmed = state.allocator.alloc(u8, out_i) catch {
        state.allocator.free(out);
        return .{ .bytes = inp };
    };
    @memcpy(trimmed, out[0..out_i]);
    state.allocator.free(out);
    return .{ .bytes = trimmed, .owned = trimmed };
}

fn consumeCsiReplyFromTerminal(state: *State, inp: []const u8) OscConsumeResult {
    harvestPendingCsiReplies(state);

    if (inp.len == 0) return .{ .bytes = inp };

    const ESC: u8 = 0x1b;
    const CSI_C1: u8 = 0x9b;

    const out = state.allocator.alloc(u8, inp.len) catch return .{ .bytes = inp };
    var out_i: usize = 0;
    var consumed_any = false;

    var i: usize = 0;
    while (i < inp.len) {
        if (!state.csi_reply_in_progress and state.csi_reply_targets.items.len == 0) {
            if (state.activeFloatingIndex()) |idx| {
                if (idx < state.view.floats.items.len) {
                    const fp = state.view.floats.items[idx];
                    const can_interact = if (fp.parent_tab) |parent| parent == state.activeTabIndex() else true;
                    if (fp.isVisibleOnTab(state.activeTabIndex()) and can_interact) {
                        const n = parseLikelyTerminalCsiReplyLen(inp, i);
                        if (n > 0) {
                            fp.write(inp[i .. i + n]) catch {};
                            consumed_any = true;
                            i += n;
                            continue;
                        }
                    }
                }
            }
        }

        if (!state.csi_reply_in_progress and state.csi_reply_targets.items.len == 0) {
            const starts_esc_csi = i + 1 < inp.len and inp[i] == ESC and inp[i + 1] == '[';
            const starts_c1_csi = inp[i] == CSI_C1;
            if (starts_esc_csi or starts_c1_csi) {
                // Reply can race ahead of bookkeeping in the same loop tick.
                harvestPendingCsiReplies(state);
            }
        }

        if (!state.csi_reply_in_progress and state.csi_reply_targets.items.len > 0) {
            const starts_esc_csi = i + 1 < inp.len and inp[i] == ESC and inp[i + 1] == '[';
            const starts_c1_csi = inp[i] == CSI_C1;
            if (!starts_esc_csi and !starts_c1_csi) {
                out[out_i] = inp[i];
                out_i += 1;
                i += 1;
                continue;
            }

            state.csi_reply_target_uuid = dequeueLiveCsiReplyTarget(state);
            if (state.csi_reply_target_uuid == null) {
                out[out_i] = inp[i];
                out_i += 1;
                i += 1;
                continue;
            }
            state.csi_reply_in_progress = true;
            state.csi_reply_buf.clearRetainingCapacity();

            if (starts_esc_csi) {
                state.csi_reply_buf.append(state.allocator, ESC) catch {
                    clearCsiReplyCapture(state);
                    out[out_i] = inp[i];
                    out_i += 1;
                    i += 1;
                    continue;
                };
                state.csi_reply_buf.append(state.allocator, '[') catch {
                    clearCsiReplyCapture(state);
                    out[out_i] = inp[i];
                    out_i += 1;
                    i += 1;
                    continue;
                };
                consumed_any = true;
                i += 2;
                continue;
            }

            state.csi_reply_buf.append(state.allocator, CSI_C1) catch {
                clearCsiReplyCapture(state);
                out[out_i] = inp[i];
                out_i += 1;
                i += 1;
                continue;
            };
            consumed_any = true;
            i += 1;
            continue;
        }

        if (!state.csi_reply_in_progress) {
            out[out_i] = inp[i];
            out_i += 1;
            i += 1;
            continue;
        }

        const b = inp[i];
        state.csi_reply_buf.append(state.allocator, b) catch {
            clearCsiReplyCapture(state);
            i += 1;
            continue;
        };
        consumed_any = true;

        if (b >= 0x40 and b <= 0x7e) {
            routeCapturedCsiReply(state);
            clearCsiReplyCapture(state);
        } else if (state.csi_reply_buf.items.len > 512) {
            clearCsiReplyCapture(state);
        }

        i += 1;
    }

    if (!consumed_any) {
        state.allocator.free(out);
        return .{ .bytes = inp };
    }
    if (out_i == 0) {
        state.allocator.free(out);
        return .{ .bytes = &[_]u8{} };
    }
    if (out_i == inp.len) {
        state.allocator.free(out);
        return .{ .bytes = inp };
    }

    const trimmed = state.allocator.alloc(u8, out_i) catch {
        state.allocator.free(out);
        return .{ .bytes = inp };
    };
    @memcpy(trimmed, out[0..out_i]);
    state.allocator.free(out);
    return .{ .bytes = trimmed, .owned = trimmed };
}

fn parseCprReportLen(inp: []const u8, start: usize) usize {
    var i = start;
    const CSI_C1: u8 = 0x9b;

    if (inp[i] == 0x1b) {
        if (i + 1 >= inp.len or inp[i + 1] != '[') return 0;
        i += 2;
    } else if (inp[i] == CSI_C1) {
        i += 1;
    } else {
        return 0;
    }

    if (i < inp.len and inp[i] == '?') i += 1;

    const row_start = i;
    while (i < inp.len and inp[i] >= '0' and inp[i] <= '9') : (i += 1) {}
    if (i == row_start) return 0;
    if (i >= inp.len or inp[i] != ';') return 0;
    i += 1;

    const col_start = i;
    while (i < inp.len and inp[i] >= '0' and inp[i] <= '9') : (i += 1) {}
    if (i == col_start) return 0;
    if (i >= inp.len or inp[i] != 'R') return 0;

    return (i + 1) - start;
}

fn consumeCprRepliesFromTerminal(state: *State, inp: []const u8) OscConsumeResult {
    if (!state.terminal_query_in_flight) return .{ .bytes = inp };
    if (inp.len == 0) return .{ .bytes = inp };

    const out = state.allocator.alloc(u8, inp.len) catch return .{ .bytes = inp };
    var out_i: usize = 0;
    var consumed_any = false;

    var i: usize = 0;
    while (i < inp.len) {
        const n = parseCprReportLen(inp, i);
        if (n > 0) {
            consumed_any = true;
            i += n;
            continue;
        }
        out[out_i] = inp[i];
        out_i += 1;
        i += 1;
    }

    if (!consumed_any) {
        state.allocator.free(out);
        return .{ .bytes = inp };
    }
    if (out_i == 0) {
        state.allocator.free(out);
        return .{ .bytes = &[_]u8{} };
    }

    const trimmed = state.allocator.alloc(u8, out_i) catch {
        state.allocator.free(out);
        return .{ .bytes = inp };
    };
    @memcpy(trimmed, out[0..out_i]);
    state.allocator.free(out);
    return .{ .bytes = trimmed, .owned = trimmed };
}
