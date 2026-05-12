const std = @import("std");
const vaxis = @import("vaxis");

// Re-export ghostty-vt - this IS our terminal emulation
pub const ghostty = @import("ghostty-vt");
pub const Terminal = ghostty.Terminal;

// Ghostty's `max_scrollback` is measured in BYTES (rounded up to its internal
// page size), not in lines.
//
// We set this to match the pod backlog size so the interactive in-mux
// scrollback feels consistent with detach/reattach behavior.
const DEFAULT_SCROLLBACK_BYTES: usize = 16 * 1024 * 1024;

const ReadonlyStream = @TypeOf((@as(*Terminal, undefined)).vtStream());

/// Thin wrapper around ghostty Terminal
pub const VT = struct {
    const KittyImageCache = struct {
        vaxis_id: u32,
        width: u32,
        height: u32,
        data_len: usize,
        data_hash: u64,
        format_tag: u8,
    };

    allocator: std.mem.Allocator = undefined,
    terminal: Terminal = undefined,
    stream: ReadonlyStream = undefined,
    render_state: ghostty.RenderState = .empty,
    kitty_image_cache: std.AutoHashMap(u32, KittyImageCache) = undefined,
    width: u16 = 0,
    height: u16 = 0,
    // NOTE: Do NOT cache RenderState across calls.
    // Ghostty's "visible viewport" for main-screen scrollback can change due to
    // viewport movement even when no new output is fed. Caching at this layer can
    // cause panes to appear visually frozen while scrolling.

    /// Initialize the VT in-place.
    ///
    /// IMPORTANT: Ghostty terminal state must not be moved after initialization.
    /// This function initializes fields directly on `self` so the terminal lives
    /// at its final stable address.
    pub fn init(self: *VT, allocator: std.mem.Allocator, width: u16, height: u16) !void {
        self.* = .{ .allocator = allocator, .width = width, .height = height };

        self.terminal = try Terminal.init(allocator, .{
            .cols = width,
            .rows = height,
            .max_scrollback = DEFAULT_SCROLLBACK_BYTES,
        });
        errdefer self.terminal.deinit(allocator);
        // Ghostty's full Termio path defaults cursor blinking on from config.
        // Hexe uses the raw Terminal, so apply the same default here while
        // still allowing DECSCUSR steady-cursor sequences to disable it.
        self.terminal.modes.set(.cursor_blinking, true);

        self.stream = self.terminal.vtStream();
        self.render_state = .empty;
        self.kitty_image_cache = std.AutoHashMap(u32, KittyImageCache).init(allocator);
    }

    pub fn deinit(self: *VT) void {
        self.render_state.deinit(self.allocator);
        self.kitty_image_cache.deinit();
        self.stream.deinit();
        self.terminal.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn freeCachedKittyImages(self: *VT, vx: *vaxis.Vaxis, tty: anytype) void {
        var it = self.kitty_image_cache.iterator();
        while (it.next()) |entry| {
            vx.freeImage(tty, entry.value_ptr.vaxis_id);
        }
        self.kitty_image_cache.clearRetainingCapacity();
    }

    /// Process input data through the terminal emulator.
    ///
    /// We must reuse the same stream across calls so the parser can maintain
    /// state for sequences that arrive split across PTY reads.
    pub fn feed(self: *VT, data: []const u8) !void {
        try self.stream.nextSlice(data);
    }

    /// Mark the VT as needing a fresh render snapshot.
    ///
    /// Kept for API compatibility with callers, but RenderState is currently not
    /// cached so this is a no-op.
    pub fn invalidateRenderState(self: *VT) void {
        _ = self;
    }

    /// Resize the virtual terminal
    pub fn resize(self: *VT, width: u16, height: u16) !void {
        if (width == self.width and height == self.height) return;
        try self.terminal.resize(self.allocator, width, height);
        self.width = width;
        self.height = height;
    }

    /// Get cursor position
    pub fn getCursor(self: *VT) struct { x: u16, y: u16 } {
        const cursor = self.terminal.screens.active.cursor;
        return .{ .x = cursor.x, .y = cursor.y };
    }

    /// Get cursor style (returns DECSCUSR value: 0=default, 1=block blink, 2=block, 3=underline blink, 4=underline, 5=bar blink, 6=bar)
    pub fn getCursorStyle(self: *VT) u8 {
        const screen = self.terminal.screens.active;
        const cursor_style = screen.cursor.cursor_style;
        const blink = self.terminal.modes.get(.cursor_blinking);
        // Map ghostty cursor style to DECSCUSR values
        return switch (cursor_style) {
            .block, .block_hollow => if (blink) 1 else 2,
            .underline => if (blink) 3 else 4,
            .bar => if (blink) 5 else 6,
        };
    }

    /// Check if cursor is visible
    pub fn isCursorVisible(self: *VT) bool {
        return self.terminal.modes.get(.cursor_visible);
    }

    /// Check if in alternate screen mode
    pub fn inAltScreen(self: *VT) bool {
        return self.terminal.screens.active_key == .alternate;
    }

    /// Get current working directory (from OSC 7)
    pub fn getPwd(self: *VT) ?[]const u8 {
        if (self.terminal.pwd.items.len == 0) return null;
        return self.terminal.pwd.items;
    }

    /// Update and return a stable snapshot of the currently visible viewport.
    ///
    /// This uses ghostty's `RenderState` which duplicates any managed cell data
    /// required for rendering. Reading cells via `PageList` directly can be
    /// fragile when pins/pages are shifting due to scrollback or resize.
    ///
    /// SAFETY: When scrollback is very large, this can fail or return invalid data.
    /// Callers should check the returned RenderState's rows/cols are reasonable.
    pub fn getRenderState(self: *VT) !*const ghostty.RenderState {
        // Clear previous state before updating to free memory from previous large scrollback
        self.render_state.deinit(self.allocator);
        self.render_state = .empty;

        // Update render state - this allocates based on current VT dimensions
        try self.render_state.update(self.allocator, &self.terminal);

        // Validate the RenderState dimensions are reasonable
        // Large scrollback can cause rows to become extremely large
        const MAX_REASONABLE_ROWS: usize = 10000;
        const MAX_REASONABLE_COLS: usize = 1000;

        if (self.render_state.rows > MAX_REASONABLE_ROWS or
            self.render_state.cols > MAX_REASONABLE_COLS)
        {
            // RenderState has invalid dimensions - likely due to corrupted scrollback
            // Return empty state to prevent rendering corruption
            self.render_state.deinit(self.allocator);
            self.render_state = .empty;
        }

        return &self.render_state;
    }
};
