//! Surface-mode region compositing.
//!
//! A surface region is a pane without a pty: the painter's ANSI goes into a
//! headless `core.VT` sized to the region's rect, and the resulting cell grid is
//! blitted through the same `vt_bridge.drawRenderState` that draws every pane.
//!
//! Because the bytes land in a VT sized to the region, a painter cannot address
//! a cell outside its own rectangle no matter what it emits.

const std = @import("std");
const core = @import("core");
const vaxis = @import("vaxis");
const vt_bridge = @import("vt_bridge.zig");
const Renderer = @import("render_core.zig").Renderer;

const Entry = struct {
    vt: core.VT,
    width: u16,
    height: u16,
    /// Identifies the last content fed, so an unchanged frame is not re-fed.
    stamp: u64,
    initialized: bool,
};

/// The frontend's surface cache, published for the render path the same way
/// `core.regions.active` is.
pub var active: ?*SurfaceCache = null;

/// Painter socket for callers that do not carry the status config (popups).
pub var socket_path: ?[]const u8 = null;

pub fn setActive(cache: *SurfaceCache, socket: ?[]const u8) void {
    active = cache;
    socket_path = socket;
}

/// Per-region headless terminals, keyed by region identity.
pub const SurfaceCache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(*Entry),

    pub fn init(allocator: std.mem.Allocator) SurfaceCache {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(*Entry).init(allocator),
        };
    }

    pub fn deinit(self: *SurfaceCache) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            const e = kv.value_ptr.*;
            if (e.initialized) e.vt.deinit();
            self.allocator.destroy(e);
            self.allocator.free(kv.key_ptr.*);
        }
        self.entries.deinit();
    }

    fn get(self: *SurfaceCache, key: []const u8, width: u16, height: u16) ?*Entry {
        if (self.entries.get(key)) |e| {
            if (e.width != width or e.height != height) {
                e.vt.resize(width, height) catch return null;
                e.width = width;
                e.height = height;
                e.stamp = 0;
            }
            return e;
        }

        const e = self.allocator.create(Entry) catch return null;
        e.* = .{ .vt = undefined, .width = width, .height = height, .stamp = 0, .initialized = false };
        e.vt.init(self.allocator, width, height) catch {
            self.allocator.destroy(e);
            return null;
        };
        e.initialized = true;

        const key_owned = self.allocator.dupe(u8, key) catch {
            e.vt.deinit();
            self.allocator.destroy(e);
            return null;
        };
        self.entries.put(key_owned, e) catch {
            self.allocator.free(key_owned);
            e.vt.deinit();
            self.allocator.destroy(e);
            return null;
        };
        return e;
    }
};

fn contentStamp(bytes: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(bytes);
    const digest = h.final();
    // 0 marks "nothing fed yet", so never hand it back as a real stamp.
    return if (digest == 0) 1 else digest;
}

/// Draw a painter's surface into `w`x`h` cells at (`x`, `y`). Returns false when
/// there is nothing to draw, leaving the caller's own fallback in place.
pub fn drawSurface(
    renderer: *Renderer,
    cache: *SurfaceCache,
    key: []const u8,
    ansi: []const u8,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    stdout: std.fs.File,
) bool {
    if (w == 0 or h == 0 or ansi.len == 0) return false;

    const entry = cache.get(key, w, h) orelse return false;

    const stamp = contentStamp(ansi);
    if (stamp != entry.stamp) {
        // Home the cursor and clear before each new frame: the VT is reused
        // across frames, so leftover cells would show through a shorter one.
        entry.vt.feed("\x1b[H\x1b[2J") catch return false;
        entry.vt.feed(ansi) catch return false;
        entry.stamp = stamp;
    }

    const state = entry.vt.getRenderState() catch return false;
    const win = renderer.vx.window().child(.{
        .x_off = @intCast(x),
        .y_off = @intCast(y),
        .width = w,
        .height = h,
    });
    vt_bridge.drawRenderState(win, state, w, h, renderer.frame_arena.allocator(), &entry.vt, &renderer.vx, stdout);
    return true;
}

test "content stamp changes with content and is never zero" {
    try std.testing.expect(contentStamp("a") != contentStamp("b"));
    try std.testing.expect(contentStamp("") != 0);
    try std.testing.expectEqual(contentStamp("same"), contentStamp("same"));
}

/// Draw a pane's sprite overlay. The artwork, palette, placement inside the
/// rect and animation all belong to the painter; hexe supplies the pane's name
/// and the rectangle it may use.
pub fn drawPaneSprite(
    renderer: *Renderer,
    cache: *SurfaceCache,
    cfg: *const core.config.StatusBarConfig,
    name: []const u8,
    shiny: bool,
    position: []const u8,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    stdout: std.fs.File,
) void {
    const registry = core.regions.active orelse return;
    if (w == 0 or h == 0) return;

    var extra_buf: [256]u8 = undefined;
    const extra = std.fmt.bufPrint(
        &extra_buf,
        "\"sprite_name\":\"{s}\",\"sprite_shiny\":{s},\"sprite_position\":\"{s}\"",
        .{ name, if (shiny) "true" else "false", position },
    ) catch return;

    const snap = registry.snapshot(.{
        .selector = cfg.sprite_view,
        .mode = .surface,
        .width = w,
        .height = h,
        .socket_path = cfg.socket,
        .refresh_ms = @intCast(cfg.refresh_ms),
        .stale_ms = @intCast(cfg.stale_ms),
        .key_suffix = name,
        .command = cfg.command,
    }, .{
        .now_ms = @intCast(std.time.milliTimestamp()),
        .home = std.posix.getenv("HOME"),
        .extra_json = extra,
    });
    if (!snap.done or snap.ansi.len == 0) return;

    _ = drawSurface(renderer, cache, name, snap.ansi, x, y, w, h, stdout);
}
