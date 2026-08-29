const std = @import("std");
const vaxis = @import("vaxis");
const palette_mod = @import("palette.zig");
const logging = @import("logging.zig");
const image_import = @import("image_import.zig");

// Re-export ghostty-vt - this IS our terminal emulation
pub const ghostty = @import("ghostty-vt");
pub const Terminal = ghostty.Terminal;

// Ghostty's `max_scrollback` is measured in BYTES (rounded up to its internal
// page size), not in lines.
//
// We set this to match the pod backlog size so the interactive in-mux
// scrollback feels consistent with detach/reattach behavior.
const DEFAULT_SCROLLBACK_BYTES: usize = 16 * 1024 * 1024;

/// Kitty image storage per pane.
///
/// ghostty defaults this to 320MB PER SCREEN, which is a sane number for a
/// terminal that is one window. A mux is not: hexe never lowered it, so twenty
/// panes carried a 6.4GB ceiling for image data alone, and nothing but the
/// programs' own restraint kept it down. 64MB still admits a full 4K RGBA
/// image (33MB) — the largest thing `icat` will hand over without downscaling
/// — and evicts oldest-first past that. It is a ceiling, not an allocation.
const KITTY_IMAGE_LIMIT_BYTES: usize = 64 * 1024 * 1024;

const ReadonlyStream = @TypeOf((@as(*Terminal, undefined)).vtStream());

/// The host terminal's cell size in pixels.
///
/// A Kitty placement with no explicit `r=`/`c=` is sized by dividing the
/// image's pixels by the cell's, so a terminal reporting nothing leaves ghostty
/// dividing by zero: the placement collapses to zero cells and the image
/// transmits but is never drawn. Most ptys report nothing -- hexe's own set
/// `ws_xpixel = 0` until `setCellPixels` is called -- so this starts at a
/// typical 8x16 cell and the frontend replaces it as soon as the host reports
/// a real size. One terminal, one cell size, hence one global.
///
/// `known` separates a measurement from that fallback, and the distinction
/// matters as soon as the figure leaves hexe. Placement arithmetic needs some
/// non-zero cell size or every image collapses to zero cells, so the default
/// stands in for one. A pane's pty is different: a program there divides the
/// pixel fields by the cell counts and believes the answer, so reporting the
/// fallback would be telling it the cell is 8x16 when hexe has no idea. Zero
/// means "unknown" in that protocol, and unknown is the honest answer.
pub var cell_px: struct { w: u16 = 8, h: u16 = 16, known: bool = false } = .{};

/// Record the host's cell size. Zero in either axis means the terminal reported
/// none, which leaves the fallback standing rather than reintroducing the
/// divide by zero.
///
/// Returns whether the value actually changed. A font size change moves the
/// cell size without moving the rows and columns, and the panes have to be
/// told: their pty geometry is derived from this.
pub fn setCellPixels(w: u16, h: u16) bool {
    if (w == 0 or h == 0) return false;
    if (cell_px.known and cell_px.w == w and cell_px.h == h) return false;
    cell_px = .{ .w = w, .h = h, .known = true };
    return true;
}

/// Thin wrapper around ghostty Terminal
pub const VT = struct {
    const KittyImageCache = struct {
        vaxis_id: u32,
        width: u32,
        height: u32,
        data_len: usize,
        data_hash: u64,
        /// Address of the payload we last uploaded. An unchanged image keeps
        /// its buffer, so this lets syncKittyImages skip re-hashing megabytes
        /// every frame; a retransmit reallocates and falls through to the hash.
        data_ptr: usize,
        format_tag: u8,
    };

    allocator: std.mem.Allocator = undefined,
    terminal: Terminal = undefined,
    stream: ReadonlyStream = undefined,
    render_state: ghostty.RenderState = .empty,
    kitty_image_cache: std.AutoHashMap(u32, KittyImageCache) = undefined,
    width: u16 = 0,
    height: u16 = 0,
    // RenderState cache validity. Every terminal mutation must mark this:
    // feed() and resize() do it internally; viewport movement without new
    // output (scrollViewport) happens only via the Pane scroll methods, which
    // call invalidateRenderState(). Without complete invalidation coverage a
    // cached snapshot makes panes appear frozen — the historical bug here.
    render_state_dirty: bool = true,

    /// Per-pane palette namespaces (PLAN.md M1). Slot 0 is the pane's ordinary
    /// palette and passes indices through untouched, so this is inert until a
    /// later milestone selects a namespace.
    ns_table: palette_mod.NamespaceTable = undefined,

    /// Images arriving in a protocol ghostty's VT does not speak: sixel, and
    /// iTerm2's inline images. It holds partial sequences across feeds, so it
    /// is per-pane state and lives for as long as the VT.
    images: image_import.Importer = .{},

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

        // The alternate screen inherits this when ghostty creates it, so the
        // primary is the only one to set.
        if (comptime @TypeOf(self.terminal.screens.active.kitty_images) != void) {
            const primary = self.terminal.screens.get(.primary).?;
            primary.kitty_images.setLimit(allocator, primary, KITTY_IMAGE_LIMIT_BYTES) catch |err| {
                logging.logError("vt", "failed to cap Kitty image storage", err);
            };
        }

        self.stream = self.terminal.vtStream();
        self.render_state = .empty;
        self.kitty_image_cache = std.AutoHashMap(u32, KittyImageCache).init(allocator);
        self.ns_table = palette_mod.NamespaceTable.init(allocator);
    }

    pub fn deinit(self: *VT) void {
        self.images.deinit(self.allocator);
        self.ns_table.deinit();
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
        self.render_state_dirty = true;
        // Not straight to the stream: sixel and iTerm2 inline images have to be
        // lifted out and decoded here, because ghostty's VT drops both. Output
        // carrying neither reaches the stream as the same slices it arrived in.
        try self.images.feed(self, data);
    }

    /// Mark the VT as needing a fresh render snapshot.
    pub fn invalidateRenderState(self: *VT) void {
        self.render_state_dirty = true;
    }

    /// Restate the pane's size in pixels, which is what Kitty placements are
    /// measured against. Cheap enough to call every frame, which is what the
    /// renderer does -- the host's cell size can change under us (a font size
    /// change) without the pane's cell dimensions moving at all.
    pub fn applyCellPixels(self: *VT) void {
        self.terminal.width_px = @as(u32, cell_px.w) * self.width;
        self.terminal.height_px = @as(u32, cell_px.h) * self.height;
    }

    /// Resize the virtual terminal
    pub fn resize(self: *VT, width: u16, height: u16) !void {
        if (width == self.width and height == self.height) return;
        self.render_state_dirty = true;
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

    /// Whether this pane has asked for its updates to be presented all at once.
    ///
    /// DEC private mode 2026, "synchronized output": a program brackets a whole frame with
    /// `CSI ? 2026 h` … `CSI ? 2026 l` and the terminal presents nothing in between. Without it a
    /// full-screen repaint can reach the screen half-finished — the top of the new frame above the
    /// bottom of the old — which is what tearing is, and on a list of rows it reads as lines
    /// flickering in and out.
    ///
    /// ghostty's parser has always tracked this mode; nothing here ever asked it. See
    /// `renderIfDue`, which is where the answer is used.
    pub fn outputSynchronized(self: *VT) bool {
        return self.terminal.modes.get(.synchronized_output);
    }

    /// Check if in alternate screen mode
    pub fn inAltScreen(self: *VT) bool {
        return self.terminal.screens.active_key == .alternate;
    }

    /// Stamp the pane's current namespace onto the cursor's style.
    ///
    /// From here on every cell the program writes records which namespace was
    /// selected when it was written, so recolouring one namespace repaints
    /// exactly its own cells and leaves the rest of the screen alone. The tag
    /// is opaque to the terminal engine (patches/ghostty-vt-ns.patch); it only
    /// keeps styles distinct.
    pub fn syncNamespaceStyle(self: *VT) void {
        const ns = self.ns_table.currentSlot();
        // Both screens, not just the active one. The selection is a property of
        // the pane; each screen keeps its own cursor, and entering or leaving
        // the alternate screen swaps which one is writing. Stamping only the
        // active one let a program select on the primary, switch, release, and
        // switch back to a cursor still carrying the released namespace.
        var it = self.terminal.screens.all.iterator();
        while (it.next()) |entry| {
            const screen = entry.value.*;
            if (screen.cursor.style.flags.ns == ns) continue;
            screen.cursor.style.flags.ns = @truncate(ns);
            screen.manualStyleUpdate() catch |err| {
                logging.logError("vt", "failed to apply palette namespace to cursor style", err);
            };
        }
    }

    /// The palette namespace the cursor sits in.
    ///
    /// The pane's current selection: hexe does not decide where a namespace
    /// applies, the program does, by selecting one and releasing it.
    pub fn cursorNamespace(self: *VT) u8 {
        return self.ns_table.currentSlot();
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
        // Reuse the previous snapshot while the terminal is unchanged; the
        // idle render loop redraws every pane at a fixed cadence and the
        // snapshot rebuild (full viewport duplication) dominates that cost.
        if (!self.render_state_dirty) return &self.render_state;

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
            // Return empty state to prevent rendering corruption.
            // Stay dirty so the next frame retries instead of caching the
            // empty fallback.
            self.render_state.deinit(self.allocator);
            self.render_state = .empty;
            return &self.render_state;
        }

        self.render_state_dirty = false;
        return &self.render_state;
    }
};
