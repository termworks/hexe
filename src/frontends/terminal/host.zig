const std = @import("std");
const posix = std.posix;
const core = @import("core");
const frontend_core = @import("frontend_core");
const xev = @import("xev").Dynamic;

const State = @import("state.zig").State;
const loop_core = @import("loop_core.zig");
const loop_watchers = @import("loop_watchers.zig");
const loop_input = @import("loop_input.zig");
const loop_mouse = @import("loop_mouse.zig");
const loop_render = @import("loop_render.zig");
const terminal = @import("terminal.zig");
const terminal_main = @import("main.zig");

const TERMINAL_QUERY_TIMEOUT_MS: i64 = 1200;

fn setCellMouseMode(state: *State, tty: anytype) !void {
    // Hexe hit-tests mouse events in terminal cells. Kitty supports SGR-pixel
    // mouse mode (1016), and vaxis enables it when caps.sgr_pixels is true,
    // but this frontend does not keep vaxis' pixel screen size populated.
    // Force normal SGR cell mouse mode until the renderer owns real pixel
    // dimensions end-to-end.
    state.renderer.vx.state.mouse = true;
    state.renderer.vx.state.pixel_mouse = false;
    try tty.writeAll("\x1b[?1016l\x1b[?1002;1003;1004;1006h");
}

fn connectionLost(state: *State) void {
    state.runtime.requestFrontendDisconnectStop();
}

fn handleInput(state: *State, bytes: []const u8) void {
    loop_input.handleInput(state, bytes);
}

fn handleStopRequest(state: *State, request: frontend_core.StopRequest) void {
    if (request.user_message) |msg| {
        state.notifications.showFor(msg, 3500);
    }
}

fn applyPostQueryFeatureModes(state: *State) void {
    const stdout = std.fs.File.stdout();
    var tty_buf: [1024]u8 = undefined;
    var tty = stdout.writer(&tty_buf);

    // Prefer Unicode width handling when explicit-width modifiers are supported.
    // This lets render output use richer grapheme width semantics without relying
    // on Mode 2027 being active.
    if (state.renderer.vx.caps.explicit_width or state.renderer.vx.caps.unicode == .unicode) {
        state.renderer.vx.screen.width_method = .unicode;
    }

    // Re-apply mouse mode after capability discovery, but keep cell
    // coordinates. See setCellMouseMode above: Kitty pixel mouse breaks Hexe
    // pane hit-testing unless pixel dimensions are tracked consistently.
    setCellMouseMode(state, &tty.interface) catch |err| {
        core.logging.logError("terminal", "failed to set mouse mode after capability query", err);
    };

    // Enable runtime color-scheme updates only when detected.
    if (state.renderer.vx.caps.color_scheme_updates) {
        state.renderer.vx.subscribeToColorSchemeUpdates(&tty.interface) catch |err| {
            core.logging.logError("terminal", "failed to subscribe to color-scheme updates", err);
        };
    }

    tty.interface.flush() catch |err| {
        core.logging.logError("terminal", "failed to flush post-query feature modes", err);
    };
}

fn logTerminalCapabilities(state: *State, timed_out: bool) void {
    const caps = state.renderer.vx.caps;
    core.logging.debug(
        "terminal",
        "terminal caps: kitty_keyboard={} kitty_graphics={} rgb={} unicode={s} sgr_pixels={} color_updates={} multi_cursor={} explicit_width={} scaled_text={} timeout={}",
        .{
            caps.kitty_keyboard,
            caps.kitty_graphics,
            caps.rgb,
            @tagName(caps.unicode),
            caps.sgr_pixels,
            caps.color_scheme_updates,
            caps.multi_cursor,
            caps.explicit_width,
            caps.scaled_text,
            timed_out,
        },
    );

    if (timed_out) {
        core.logging.debug("terminal", "terminal capability query timed out; using best-effort feature set", .{});
    }
}

fn finalizeCapabilities(state: *State, now_ms: i64) void {
    if (!state.terminal_query_in_flight) return;

    const query_done = state.renderer.vx.queries_done.load(.unordered);
    const timed_out = now_ms >= state.terminal_query_deadline_ms;
    if (!query_done and !timed_out) return;

    const stdout = std.fs.File.stdout();
    var tty_buf: [1024]u8 = undefined;
    var tty = stdout.writer(&tty_buf);
    state.renderer.vx.enableDetectedFeatures(&tty.interface) catch |err| {
        core.logging.logError("terminal", "failed to enable detected terminal features", err);
    };
    applyPostQueryFeatureModes(state);
    tty.interface.flush() catch |err| {
        core.logging.logError("terminal", "failed to flush terminal feature enablement", err);
    };

    state.renderer.vx.queries_done.store(true, .unordered);
    state.terminal_query_in_flight = false;
    state.terminal_query_deadline_ms = 0;
    state.terminal_caps_ready = true;
    state.terminal_query_timed_out = timed_out;
    logTerminalCapabilities(state, timed_out);
}

/// Backstop cadence for the resize check. SIGWINCH is the primary trigger; this
/// bounds the damage if one is ever missed, since a terminal stuck at the wrong
/// size is far worse than one ioctl every few seconds.
const RESIZE_BACKSTOP_MS: i64 = 2_000;
var last_resize_check_ms: i64 = 0;

fn pollResize(state: *State) void {
    // Only ask the kernel when SIGWINCH says the size may have changed. This
    // used to run an unconditional TIOCGWINSZ ioctl on every pass of the main
    // loop, which pane output and the 100ms ticker spin thousands of times a
    // second. The flag starts set so the initial size is still read once.
    const signalled = terminal_main.winch_pending.swap(false, .acquire);
    if (!signalled) {
        const now = std.time.milliTimestamp();
        if (now - last_resize_check_ms < RESIZE_BACKSTOP_MS) return;
        last_resize_check_ms = now;
    } else {
        last_resize_check_ms = std.time.milliTimestamp();
    }
    const new_size = terminal.getTermSize();
    if (new_size.cols != state.term_width or new_size.rows != state.term_height) {
        state.applyTerminalResize(new_size.cols, new_size.rows);
    }
}

fn readInput(fd: posix.fd_t, buffer: []u8) !usize {
    return posix.read(fd, buffer);
}

fn render(state: *State) !void {
    const stdout = std.fs.File.stdout();
    try loop_render.renderTo(state, stdout);
}

/// How long a pane may hold the screen with DEC 2026 before it is presented regardless.
///
/// **A program that dies between the begin and the end must not freeze the terminal.** Every real
/// implementation caps the wait for that reason; 150ms is the usual figure and is far longer than
/// any honest frame.
const SYNC_HOLD_MS: i64 = 150;

/// Whether any visible pane is mid-frame under synchronized output (DEC private mode 2026).
///
/// Asked of every pane rather than only the focused one, because they share one screen: presenting
/// while any of them is half-drawn tears that pane, whichever one holds the cursor.
fn outputHeld(state: *State) bool {
    if (state.view.tab_views.items.len > 0) {
        var split_it = state.currentLayout().splitIterator();
        while (split_it.next()) |pane| {
            if (pane.*.vt.outputSynchronized()) return true;
        }
    }
    for (state.view.float_views.items) |pane| {
        if (pane.vt.outputSynchronized()) return true;
    }
    return false;
}

fn renderIfDue(state: *State, last_render_ms: *i64) void {
    if (!state.needs_render) return;

    const render_now = std.time.milliTimestamp();
    if (render_now - last_render_ms.* < 16) return; // ~60fps

    // **Hold the frame while a pane is still building one.** Otherwise a full-screen repaint
    // reaches the screen half-finished — the top of the new frame above the bottom of the old —
    // which is what tearing is, and is the whole reason DEC 2026 exists.
    //
    // Bounded, so a program killed between `?2026h` and `?2026l` costs one late frame rather than
    // a terminal that has stopped drawing. `needs_render` is deliberately left set: the next pass
    // through the loop tries again and nothing is dropped.
    if (outputHeld(state) and render_now - last_render_ms.* < SYNC_HOLD_MS) return;

    render(state) catch |err| {
        core.logging.logError("terminal", "terminal render failed", err);
    };
    state.needs_render = false;
    state.force_full_render = false;
    last_render_ms.* = render_now;
}

/// Terminal host adapter entrypoint.
///
/// `loop_core` still owns most xev watcher dispatch for now, but this adapter
/// owns terminal-host lifecycle: raw mode, alternate screen setup, terminal
/// capability query startup, and terminal cleanup on exit.
pub const TerminalHost = struct {
    state: *State,

    pub fn init(state: *State) TerminalHost {
        return .{ .state = state };
    }

    pub fn capabilities() frontend_core.HostCapabilities {
        return frontend_core.defaultCapabilities(.terminal);
    }

    pub fn run(self: *TerminalHost) !void {
        const orig_termios = try terminal.enableRawMode(posix.STDIN_FILENO);
        defer terminal.disableRawMode(posix.STDIN_FILENO, orig_termios) catch |err| {
            core.logging.logError("terminal", "failed to restore terminal raw mode", err);
        };

        try self.enterTerminalScreen();
        defer self.restoreTerminalScreen();

        try xev.detect();
        var loop = try xev.Loop.init(.{});
        defer loop.deinit();
        var loop_timer = try xev.Timer.init();
        defer loop_timer.deinit();
        var loop_resources: loop_watchers.LoopResources = undefined;
        loop_resources.init(&loop);

        try loop_core.runMainLoop(self.state, .{
            .connectionLost = connectionLost,
            .finalizeCapabilities = finalizeCapabilities,
            .handleInput = handleInput,
            .handleStopRequest = handleStopRequest,
            .pollResize = pollResize,
            .readInput = readInput,
            .renderIfDue = renderIfDue,
            .stdin_fd = posix.STDIN_FILENO,
        }, &loop, &loop_timer, &loop_resources);
    }

    fn enterTerminalScreen(self: *TerminalHost) !void {
        const stdout = std.fs.File.stdout();
        var tty_init_buf: [1024]u8 = undefined;
        var tty_init = stdout.writer(&tty_init_buf);
        try self.state.renderer.vx.enterAltScreen(&tty_init.interface);
        try self.state.renderer.vx.setBracketedPaste(&tty_init.interface, true);
        try self.state.renderer.vx.setMouseMode(&tty_init.interface, true);

        // Keep kitty keyboard available as baseline while capability probing runs.
        self.state.renderer.vx.caps.kitty_keyboard = true;
        self.state.renderer.vx.queryTerminalSend(&tty_init.interface) catch {
            try self.state.renderer.vx.enableDetectedFeatures(&tty_init.interface);
            applyPostQueryFeatureModes(self.state);
            self.state.renderer.vx.queries_done.store(true, .unordered);
            self.state.terminal_query_in_flight = false;
            self.state.terminal_query_deadline_ms = 0;
            self.state.terminal_caps_ready = true;
            self.state.terminal_query_timed_out = true;
            logTerminalCapabilities(self.state, true);
        };
        if (!self.state.renderer.vx.queries_done.load(.unordered)) {
            self.state.terminal_query_in_flight = true;
            self.state.terminal_query_deadline_ms = std.time.milliTimestamp() + TERMINAL_QUERY_TIMEOUT_MS;
        }
        try tty_init.interface.flush();
    }

    fn restoreTerminalScreen(self: *TerminalHost) void {
        const stdout = std.fs.File.stdout();
        var tty_restore_buf: [512]u8 = undefined;
        var tty_restore = stdout.writer(&tty_restore_buf);
        if (self.state.view.tab_views.items.len > 0) {
            var split_it = self.state.currentLayout().splitIterator();
            while (split_it.next()) |pane| {
                pane.*.vt.freeCachedKittyImages(&self.state.renderer.vx, &tty_restore.interface);
            }
        }
        for (self.state.view.float_views.items) |pane| {
            pane.vt.freeCachedKittyImages(&self.state.renderer.vx, &tty_restore.interface);
        }
        // Ensure in-band resize mode is reset even if vaxis internal state
        // tracking missed setting it during capability query setup.
        tty_restore.interface.writeAll("\x1b[?2048l") catch |err| {
            core.logging.logError("terminal", "failed to disable in-band resize mode on restore", err);
        };
        loop_mouse.resetShape(self.state);
        self.state.renderer.vx.resetState(&tty_restore.interface) catch |err| {
            core.logging.logError("terminal", "failed to reset terminal renderer state", err);
        };
        tty_restore.interface.flush() catch |err| {
            core.logging.logError("terminal", "failed to flush terminal restore state", err);
        };
    }
};

pub fn run(state: *State) !void {
    var terminal_host = TerminalHost.init(state);
    try terminal_host.run();
}
