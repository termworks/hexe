//! Standalone vaxis popup runner for CLI commands that do not own a mux session
//! (e.g., `hexe pod attach`, `hexe detach`, `hexe session clear`).
//!
//! Reuses `pop.Picker`, `pop.Confirm`, `popup_render.zig`, `Renderer`, and
//! `input.zig` so every interactive CLI picker looks and behaves identically to
//! hexe's in-mux popups without starting a SES session.

const std = @import("std");
const posix = std.posix;
const core = @import("core");
const pop = @import("pop");
const vaxis = @import("vaxis");

const terminal = @import("terminal.zig");
const Renderer = @import("render_core.zig").Renderer;
const render_vx = @import("render_vx.zig");
const popup_render = @import("popup_render.zig");
const input = @import("input.zig");

/// Show a blocking vaxis Picker in the current terminal and return the chosen
/// original index, or null if cancelled or if stdin/stdout is not a TTY.
pub fn runPicker(
    allocator: std.mem.Allocator,
    items: []const []const u8,
    opts: pop.PickerOptions,
) !?usize {
    if (!posix.isatty(posix.STDIN_FILENO) or !posix.isatty(posix.STDOUT_FILENO)) {
        return null;
    }
    if (items.len == 0) return null;

    var pop_cfg = pop.PopConfig.load(allocator);
    defer pop_cfg.deinit();

    var popups = pop.PopupManager.init(allocator);
    defer popups.deinit();
    try popups.showPickerOwned(items, opts);

    try runPopupLoop(allocator, &popups, &pop_cfg);
    if (popups.wasPickerCancelled()) return null;
    return popups.getPickerResult();
}

/// Show a blocking vaxis Confirm dialog in the current terminal and return
/// true for Yes, false for No/Cancel. Returns null if not a TTY.
pub fn runConfirm(
    allocator: std.mem.Allocator,
    message: []const u8,
    opts: pop.ConfirmOptions,
) !?bool {
    if (!posix.isatty(posix.STDIN_FILENO) or !posix.isatty(posix.STDOUT_FILENO)) {
        return null;
    }

    var pop_cfg = pop.PopConfig.load(allocator);
    defer pop_cfg.deinit();

    var popups = pop.PopupManager.init(allocator);
    defer popups.deinit();
    try popups.showConfirmOwned(message, opts);

    try runPopupLoop(allocator, &popups, &pop_cfg);
    return popups.getConfirmResult() orelse false;
}

fn runPopupLoop(allocator: std.mem.Allocator, popups: *pop.PopupManager, pop_cfg: *const pop.PopConfig) !void {
    const orig_termios = try terminal.enableRawMode(posix.STDIN_FILENO);
    defer terminal.disableRawMode(posix.STDIN_FILENO, orig_termios) catch {};

    var size = terminal.getTermSize();
    var renderer = try Renderer.init(allocator, size.cols, size.rows);
    defer renderer.deinit();

    const stdout = std.fs.File.stdout();
    {
        var init_buf: [512]u8 = undefined;
        var w = stdout.writer(&init_buf);
        try renderer.vx.enterAltScreen(&w.interface);
        try w.interface.flush();
    }
    defer {
        var restore_buf: [512]u8 = undefined;
        var w = stdout.writer(&restore_buf);
        renderer.vx.resetState(&w.interface) catch {};
        w.interface.flush() catch {};
    }

    var parser: vaxis.Parser = .{};
    var in_buf: [256]u8 = undefined;
    var needs_render = true;
    var force_full = true;

    while (popups.isBlocked()) {
        // Check for terminal resize
        const new_size = terminal.getTermSize();
        if (new_size.cols != size.cols or new_size.rows != size.rows) {
            size = new_size;
            renderer.resize(size.cols, size.rows) catch {};
            needs_render = true;
            force_full = true;
        }

        if (needs_render) {
            renderer.vx.screen.clear();
            if (popups.getActivePopup()) |popup| {
                popup_render.draw(&renderer, popup, &pop_cfg.carrier, size.cols, size.rows);
            }
            render_vx.renderFrame(&renderer.vx, stdout, .{}, force_full) catch break;
            needs_render = false;
            force_full = false;
        }

        var pfds = [_]posix.pollfd{.{
            .fd = posix.STDIN_FILENO,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = posix.poll(&pfds, 50) catch break;
        if (ready == 0) {
            if (popups.update()) needs_render = true;
            continue;
        }
        if ((pfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) break;

        const n = posix.read(posix.STDIN_FILENO, &in_buf) catch break;
        if (n == 0) break;

        var pos: usize = 0;
        while (pos < n and popups.isBlocked()) {
            const parsed = input.parseEvent(&parser, in_buf[pos..n], allocator) catch {
                pos += 1;
                continue;
            };
            if (parsed.n == 0) {
                // Lone Escape byte at end of read — wait briefly to distinguish Esc vs CSI sequence.
                if (in_buf[pos] == 0x1b and pos + 1 == n) {
                    _ = popups.handleKey(.escape);
                    needs_render = true;
                }
                break;
            }
            pos += parsed.n;
            if (parsed.event) |ev| {
                defer switch (ev) {
                    .paste => |txt| allocator.free(txt),
                    else => {},
                };
                _ = input.handlePopupEvent(popups, ev);
                needs_render = true;
            }
        }
    }
}
