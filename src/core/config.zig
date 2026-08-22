const std = @import("std");
pub const names_mod = @import("names.zig");
const posix = std.posix;
const lua_runtime = @import("lua_runtime.zig");
const LuaRuntime = lua_runtime.LuaRuntime;

const log = std.log.scoped(.config);

fn shouldLoadLocalConfig() bool {
    if (std.posix.getenv("HEXE_SKIP_LOCAL_CONFIG")) |v| {
        return !std.mem.eql(u8, v, "1");
    }
    return true;
}

threadlocal var PARSE_ERROR: ?[]const u8 = null;

fn setParseError(allocator: std.mem.Allocator, msg: []const u8) void {
    if (PARSE_ERROR != null) return;
    PARSE_ERROR = allocator.dupe(u8, msg) catch |err| {
        log.warn("failed to allocate config parse error message: {}", .{err});
        return;
    };
}

fn dupeStatusMessage(allocator: std.mem.Allocator, msg: []const u8) ?[]const u8 {
    return allocator.dupe(u8, msg) catch |err| {
        log.warn("failed to allocate config status message: {}", .{err});
        return null;
    };
}

fn dupeConfigString(allocator: std.mem.Allocator, value: []const u8, comptime context: []const u8) ?[]u8 {
    return allocator.dupe(u8, value) catch |err| {
        log.warn(context ++ ": {}", .{err});
        return null;
    };
}

fn dupeTrimmedConfigString(allocator: std.mem.Allocator, value: []const u8, comptime context: []const u8) ?[]u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    return dupeConfigString(allocator, trimmed, context);
}

/// Output definition for status modules (style + format pair)
/// Free a slice unless it is EMPTY. Config fields default to empty literals
/// (`&.{}` / `""`) which live in rodata, not on the heap — and the terminal
/// frontend allocates with page_allocator, which panics ("incorrect
/// alignment") when handed such a pointer. Any config section the user leaves
/// empty (or a session with no user config at all) therefore crashed at exit.
fn freeSlice(a: std.mem.Allocator, slice: anytype) void {
    if (slice.len == 0) return;
    a.free(slice);
}

/// Free a string field ONLY if it is heap-owned. Config structs default their
/// string fields to comptime LITERALS (rodata). Freeing one of those is
/// undefined behavior — with the terminal frontend's page_allocator it panics
/// ("incorrect alignment") during teardown, so any session whose config left
/// such a field at its default crashed on exit. A pointer-identity check
/// against the default is exact and cheap.
fn freeOwnedStr(a: std.mem.Allocator, slice: []const u8, comptime default: []const u8) void {
    if (slice.len == 0) return;
    if (slice.ptr == default.ptr) return; // still the comptime default: not ours
    a.free(@constCast(slice));
}

/// A helper program the session runs alongside itself.
///
/// The painter is started this way already, by `status.command`, but that hook
/// belongs to the bar. A plugin is the general form: something that wants the
/// session's data -- a recorder, a web gateway streaming panes to a browser --
/// and needs to be running for it to be there.
///
/// hexe starts it once and does not supervise it. Restarting a helper that
/// exits on purpose is a fork loop with a delay, and a helper that wants to
/// survive its own crashes knows better than hexe does how to.
pub const PluginDef = struct {
    /// Only so a message can say which one failed.
    name: []const u8,
    /// Run through `/bin/sh -c`, detached, with stdio closed.
    command: []const u8,

    pub fn deinit(self: *PluginDef, allocator: std.mem.Allocator) void {
        freeSlice(allocator, @constCast(self.name));
        freeSlice(allocator, @constCast(self.command));
    }
};

/// Status bar config
pub const StatusBarConfig = struct {
    enabled: bool = true,
    /// Painter view drawn across the bar.
    view: []const u8 = "status",
    /// Painter socket; null uses $HEXE_PAINTER_SOCKET, then
    /// $XDG_RUNTIME_DIR/hexe/painter.sock.
    socket: ?[]const u8 = null,
    /// Optional command that starts the painter when nothing is listening.
    command: ?[]const u8 = null,
    refresh_ms: u64 = 250,
    stale_ms: u64 = 10_000,
    /// Views for pane and float chrome, also painted externally.
    float_title_view: []const u8 = "float.title",
    sprite_view: []const u8 = "overlay.sprite",
    container_title_view: []const u8 = "container.title",

    /// Independently addressed bar zones. When any is set the bar is composed
    /// from three placements instead of one full-width `view`.
    zone_left: ?[]const u8 = null,
    zone_center: ?[]const u8 = null,
    zone_right: ?[]const u8 = null,
    /// Order in which zones give up width when the bar is too narrow, as zone
    /// indices: 0 left, 1 center, 2 right. The last entry is kept longest.
    shrink: [3]u8 = .{ 1, 2, 0 },

    pub fn zonesEnabled(self: *const StatusBarConfig) bool {
        return self.zone_left != null or self.zone_center != null or self.zone_right != null;
    }
};

pub const FloatStylePosition = enum {
    topleft,
    topcenter,
    topright,
    bottomleft,
    bottomcenter,
    bottomright,
};

pub const FloatStyle = struct {
    // Border appearance
    top_left: u21 = 0x256D, // ╭
    top_right: u21 = 0x256E, // ╮
    bottom_left: u21 = 0x2570, // ╰
    bottom_right: u21 = 0x256F, // ╯
    horizontal: u21 = 0x2500, // ─
    vertical: u21 = 0x2502, // │
    // Optional junction characters (not currently used by float border renderer,
    // but supported in config for future flexibility)
    cross: u21 = 0x253C, // ┼
    top_t: u21 = 0x252C, // ┬
    bottom_t: u21 = 0x2534, // ┴
    left_t: u21 = 0x251C, // ├
    right_t: u21 = 0x2524, // ┤

    // Optional drop shadow (palette index). If null, no shadow.
    shadow_color: ?u8 = null,
    // Where the painter-drawn title sits on the border.
    position: ?FloatStylePosition = null,

    /// Nothing here is heap-owned: the title's content comes from the painter,
    /// so a FloatStyle is plain data.
    pub fn deinit(self: *FloatStyle, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.* = .{};
    }
};

/// Border color config (active/passive)
pub const BorderColor = struct {
    active: u8 = 1,
    passive: u8 = 237,
};

pub const FloatVisualPreset = struct {
    width_percent: u8 = 60,
    height_percent: u8 = 60,
    padding_x: u8 = 1,
    padding_y: u8 = 0,
    color: BorderColor = .{},
    style: ?FloatStyle = null,

    pub fn deinit(self: *FloatVisualPreset, allocator: std.mem.Allocator) void {
        if (self.style) |*style| {
            var copy = @constCast(style);
            copy.deinit(allocator);
        }
        self.* = .{};
    }
};

pub const FloatVisualRule = struct {
    width_percent: ?u8 = null,
    height_percent: ?u8 = null,
    padding_x: ?u8 = null,
    padding_y: ?u8 = null,
    color: ?BorderColor = null,
    style: ?FloatStyle = null,

    pub fn deinit(self: *FloatVisualRule, allocator: std.mem.Allocator) void {
        if (self.style) |*style| {
            var copy = @constCast(style);
            copy.deinit(allocator);
        }
        self.* = .{};
    }
};

pub const FloatMatchRule = struct {
    pattern: []const u8,
    visual: FloatVisualRule = .{},

    pub fn deinit(self: *FloatMatchRule, allocator: std.mem.Allocator) void {
        freeSlice(allocator, @constCast(self.pattern));
        self.visual.deinit(allocator);
        self.* = undefined;
    }
};

pub const FloatAttributes = struct {
    /// Hide all other floats on the current tab when this float is shown.
    /// Note: this is one-way today (we don't auto-restore hidden floats).
    exclusive: bool = false,
    /// Create one instance per current working directory.
    /// A per-cwd float is always treated as "global" (not tab-bound).
    per_cwd: bool = false,
    /// Preserve by ses daemon across mux restarts.
    sticky: bool = false,
    /// If true, the float is global (not tab-bound).
    /// If false, it is tab-bound and will be cleaned up when closing that tab.
    global: bool = false,
    /// Kill the float process when hiding it.
    /// Ignored for per-cwd (and typically meaningless for global floats).
    destroy: bool = false,
    /// Run the float command in an isolated pod child (filesystem sandbox + best-effort cgroup limits).
    isolated: bool = false,
    /// If true, directional navigation (left/right/up/down) works like splits.
    /// If false (default), left/right switches tabs directly.
    navigatable: bool = false,
    /// Inherit environment variables from the parent pane's shell process.
    inherit_env: bool = false,
};

pub const FloatDef = struct {
    key: u8,
    command: ?[]const u8,
    /// Optional border title text (rendered by mux)
    title: ?[]const u8 = null,
    attributes: FloatAttributes = .{},
    // Per-float overrides (null = use default)
    width_percent: ?u8 = null,
    height_percent: ?u8 = null,
    pos_x: ?u8 = null, // position as percent (0=left, 50=center, 100=right)
    pos_y: ?u8 = null, // position as percent (0=top, 50=center, 100=bottom)
    padding_x: ?u8 = null,
    padding_y: ?u8 = null,
    // Border color (per-float override)
    color: ?BorderColor = null,
    // Border style and optional module
    style: ?FloatStyle = null,
    // Per-float isolation config (null = use global isolation)
    isolation: ?IsolationConfig = null,
};

/// Split border style with junction characters
pub const SplitStyle = struct {
    vertical: u21 = 0x2502, // │
    horizontal: u21 = 0x2500, // ─
    cross: u21 = 0x253C, // ┼
    top_t: u21 = 0x252C, // ┬
    bottom_t: u21 = 0x2534, // ┴
    left_t: u21 = 0x251C, // ├
    right_t: u21 = 0x2524, // ┤
};

/// Splits configuration
pub const SplitsConfig = struct {
    // Border color
    color: BorderColor = .{},
    // Simple separator (when no style)
    separator_v: u21 = 0x2502, // │
    separator_h: u21 = 0x2500, // ─
    // Full border style (if set, uses junctions)
    style: ?SplitStyle = null,
};

/// Tabs configuration (includes status bar)
pub const TabsConfig = struct {
    status: StatusBarConfig = .{},
};

/// Single notification style configuration
pub const NotificationStyleConfig = struct {
    fg: u8 = 0, // foreground color (palette index)
    bg: u8 = 3, // background color (palette index)
    bold: bool = true,
    padding_x: u8 = 1, // horizontal padding inside box
    padding_y: u8 = 0, // vertical padding inside box
    offset: u8 = 1, // vertical offset (MUX: down from top, PANE: up from bottom)
    alignment: []const u8 = "center", // horizontal alignment: left, center, right
    duration_ms: u32 = 3000,
};

/// Dual-realm notification configuration
pub const NotificationConfig = struct {
    // MUX realm - always at TOP of screen
    mux: NotificationStyleConfig = .{
        .offset = 1,
    },
    // PANE realm - always at BOTTOM of each pane
    pane: NotificationStyleConfig = .{
        .offset = 0,
    },
};

// ===== Layout definitions for ses section =====

/// Single pane in a layout
pub const LayoutPaneDef = struct {
    cwd: ?[]const u8 = null,
    command: ?[]const u8 = null,

    pub fn deinit(self: *LayoutPaneDef, allocator: std.mem.Allocator) void {
        if (self.cwd) |c| freeSlice(allocator, @constCast(c));
        if (self.command) |c| freeSlice(allocator, @constCast(c));
    }
};

/// Split or pane (recursive definition)
pub const LayoutSplitDef = union(enum) {
    pane: LayoutPaneDef,
    split: struct {
        dir: []const u8, // "h" or "v"
        ratio: f32 = 0.5,
        first: *LayoutSplitDef,
        second: *LayoutSplitDef,
    },

    pub fn deinit(self: *LayoutSplitDef, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .pane => |*p| {
                var pane = @constCast(p);
                pane.deinit(allocator);
            },
            .split => |*s| {
                freeSlice(allocator, @constCast(s.dir));
                s.first.deinit(allocator);
                allocator.destroy(s.first);
                s.second.deinit(allocator);
                allocator.destroy(s.second);
            },
        }
    }
};

/// Tab in a layout
pub const LayoutTabDef = struct {
    name: []const u8,
    enabled: bool = true,
    root: ?LayoutSplitDef = null,

    pub fn deinit(self: *LayoutTabDef, allocator: std.mem.Allocator) void {
        freeSlice(allocator, @constCast(self.name));
        if (self.root) |*r| {
            var root = @constCast(r);
            root.deinit(allocator);
        }
    }
};

/// Float in a layout (includes all FloatDef fields + enabled)
pub const LayoutFloatDef = struct {
    enabled: bool = true,
    key: u8,
    /// The name the config gave this float. Validated by the config API and
    /// carried through so a script can address a float by the name it wrote,
    /// rather than by the character code its key happens to have.
    name: ?[]const u8 = null,
    command: ?[]const u8 = null,
    title: ?[]const u8 = null,
    attributes: FloatAttributes = .{},
    has_custom_attributes: bool = false, // true if float has its own attributes table
    width_percent: ?u8 = null,
    height_percent: ?u8 = null,
    pos_x: ?u8 = null,
    pos_y: ?u8 = null,
    isolation: ?IsolationConfig = null,
    /// Extra environment entries ("KEY=VALUE") for the float's process, from
    /// `add_env`. These overlay (and override) whatever the process would
    /// otherwise inherit.
    env: []const []const u8 = &.{},
    /// Directories prepended to PATH for the float's process, from `add_path`.
    path_add: []const []const u8 = &.{},

    pub fn deinit(self: *LayoutFloatDef, allocator: std.mem.Allocator) void {
        if (self.name) |n| freeSlice(allocator, @constCast(n));
        if (self.command) |c| freeSlice(allocator, @constCast(c));
        if (self.title) |t| freeSlice(allocator, @constCast(t));
        if (self.isolation) |*iso| {
            var isolation = @constCast(iso);
            isolation.deinit(allocator);
        }
        for (self.env) |e| freeSlice(allocator, @constCast(e));
        if (self.env.len > 0) freeSlice(allocator, @constCast(self.env));
        for (self.path_add) |p| freeSlice(allocator, @constCast(p));
        if (self.path_add.len > 0) freeSlice(allocator, @constCast(self.path_add));
    }
};

/// Full layout definition
pub const LayoutDef = struct {
    name: []const u8,
    enabled: bool = false,
    tabs: []LayoutTabDef = &[_]LayoutTabDef{},
    floats: []LayoutFloatDef = &[_]LayoutFloatDef{},
    /// Shell hooks from the config. The legacy SessionConfig parser always
    /// carried these; the canonical hexe.setup path silently dropped them,
    /// so the same .hexe.lua ran its hooks or not depending on which parser
    /// happened to win.
    on_start: [][]const u8 = &.{},
    on_stop: [][]const u8 = &.{},
    /// Absolute path of the project file this layout came from, for the
    /// trust-ledger gate on the hooks above. Null for layouts from the
    /// user's own hexe config (implicitly trusted).
    source_path: ?[]const u8 = null,

    pub fn deinit(self: *LayoutDef, allocator: std.mem.Allocator) void {
        freeSlice(allocator, @constCast(self.name));
        for (self.on_start) |cmd| freeSlice(allocator, cmd);
        if (self.on_start.len > 0) freeSlice(allocator, self.on_start);
        for (self.on_stop) |cmd| freeSlice(allocator, cmd);
        if (self.on_stop.len > 0) freeSlice(allocator, self.on_stop);
        if (self.source_path) |sp| freeSlice(allocator, sp);
        for (self.tabs) |*tab| {
            var t = @constCast(tab);
            t.deinit(allocator);
        }
        if (self.tabs.len > 0) {
            freeSlice(allocator, self.tabs);
        }
        for (self.floats) |*float| {
            var f = @constCast(float);
            f.deinit(allocator);
        }
        if (self.floats.len > 0) {
            freeSlice(allocator, self.floats);
        }
    }
};

/// Ses configuration
/// POD isolation configuration (libvoid settings)
pub const IsolationConfig = struct {
    /// Isolation profile: none, minimal, default, balanced, full
    profile: []const u8 = "default",
    /// Memory limit (e.g., "1G", "512M")
    memory: ?[]const u8 = null,
    /// CPU quota (e.g., "50000 100000")
    cpu: ?[]const u8 = null,
    /// Maximum PIDs
    pids: ?[]const u8 = null,

    pub fn deinit(self: *IsolationConfig, allocator: std.mem.Allocator) void {
        freeOwnedStr(allocator, self.profile, "default");
        if (self.memory) |m| freeSlice(allocator, @constCast(m));
        if (self.cpu) |c| freeSlice(allocator, @constCast(c));
        if (self.pids) |p| freeSlice(allocator, @constCast(p));
    }
};

pub const SesConfig = struct {
    layouts: []LayoutDef = &[_]LayoutDef{},
    isolation: IsolationConfig = .{},

    pub fn deinit(self: *SesConfig, allocator: std.mem.Allocator) void {
        self.isolation.deinit(allocator);
        for (self.layouts) |*layout| {
            var l = @constCast(layout);
            l.deinit(allocator);
        }
        if (self.layouts.len > 0) {
            freeSlice(allocator, self.layouts);
        }
    }

    pub fn load(allocator: std.mem.Allocator) SesConfig {
        var config = SesConfig{};

        var runtime = LuaRuntime.init(allocator) catch |err| {
            log.warn("failed to initialize ses config Lua runtime: {s}", .{@errorName(err)});
            return config;
        };
        defer runtime.deinit();

        // Load global config
        const config_path = lua_runtime.getActiveConfigPath(allocator) catch |err| {
            log.warn("failed to resolve ses config path: {s}", .{@errorName(err)});
            return config;
        };
        defer freeSlice(allocator, config_path);

        runtime.loadConfig(config_path) catch |err| {
            log.warn("failed to load ses config {s}: {s}", .{ config_path, @errorName(err) });
            return config;
        };

        if (!shouldLoadLocalConfig()) {
            if (runtime.getBuilder()) |builder| {
                if (builder.ses) |ses_builder| {
                    config = ses_builder.build() catch config;
                }
            }
            // Pop global config return value (if any) from stack
            runtime.pop();
            return config;
        }

        // Try to load local .hexe.lua from current directory
        const local_path = allocator.dupe(u8, ".hexe.lua") catch |err| {
            log.warn("failed to allocate local ses config path: {s}", .{@errorName(err)});
            return config;
        };
        defer freeSlice(allocator, local_path);

        // Check if local config exists
        std.fs.cwd().access(local_path, .{}) catch {
            // No local config, use global only
            if (runtime.getBuilder()) |builder| {
                if (builder.ses) |ses_builder| {
                    config = ses_builder.build() catch config;
                }
            }
            // Pop global config return value (if any) from stack
            runtime.pop();
            return config;
        };

        // Local config exists, load it and merge/overwrite
        runtime.loadProjectConfig(local_path) catch {
            // Failed to load local config, but global is already loaded
            if (runtime.getBuilder()) |builder| {
                if (builder.ses) |ses_builder| {
                    config = ses_builder.build() catch config;
                }
            }
            // Pop global config return value (if any) from stack
            runtime.pop();
            return config;
        };

        // Build once after both global and local config have run. Building the
        // SES builder eagerly consumes layout definitions, so a second build
        // after loading local config would otherwise wipe the global layouts.
        if (runtime.getBuilder()) |builder| {
            if (builder.ses) |ses_builder| {
                config = ses_builder.build() catch config;
            }
        }

        // Pop config return value (if any) from stack
        runtime.pop();

        return config;
    }
};

pub const NamesConfig = struct {
    /// Null means "use the built-in pool for this surface".
    session: ?[]const []const u8 = null,
    pane: ?[]const []const u8 = null,
    order: names_mod.Order = .random,
    /// Appended, with `%d` substituted, once every entry is taken.
    suffix: []const u8 = "-%d",
};

/// One edge of a pane's decoration, in three slots.
///
/// `start`/`end` rather than left/right or top/bottom: the same shape describes
/// a horizontal edge (start = left) and a vertical one (start = top), so the
/// four edges share one type and one placement routine.
pub const DecorEdge = struct {
    start: ?[]const u8 = null,
    center: ?[]const u8 = null,
    end: ?[]const u8 = null,

    pub fn any(self: *const DecorEdge) bool {
        return self.start != null or self.center != null or self.end != null;
    }
};

/// Decoration around every pane, painted externally like everything else.
///
/// One scheme for all panes. Top and bottom sit on the border row and cost
/// nothing; the side panels reserve columns and therefore SHRINK the pane,
/// which resizes the program inside.
pub const DecorConfig = struct {
    top: DecorEdge = .{},
    bottom: DecorEdge = .{},
    left: DecorEdge = .{},
    right: DecorEdge = .{},

    /// Columns each side panel reserves. Config-driven on purpose: a
    /// painter-chosen width would resize the pane on every frame the painter
    /// changed its mind, and every full-screen program inside would redraw.
    left_width: u16 = 0,
    right_width: u16 = 0,

    /// Total columns taken from a pane's content by the side panels.
    pub fn sideInset(self: *const DecorConfig) u16 {
        return self.leftInset() + self.rightInset();
    }

    pub fn leftInset(self: *const DecorConfig) u16 {
        return if (self.left.any()) self.left_width else 0;
    }

    pub fn rightInset(self: *const DecorConfig) u16 {
        return if (self.right.any()) self.right_width else 0;
    }

    /// Whether any slot is configured at all, so the render path can leave
    /// immediately on the default install.
    pub fn any(self: *const DecorConfig) bool {
        return self.top.any() or self.bottom.any() or self.left.any() or self.right.any();
    }
};

pub const Config = struct {
    pub const KeyMod = enum {
        alt,
        ctrl,
        shift,
        super,
    };

    pub const BindWhen = enum {
        press,
        release,
        repeat,
        hold,
    };

    /// Controls what happens when a keybinding matches.
    pub const BindMode = enum {
        /// Execute action and consume the key (default).
        act_and_consume,
        /// Execute action and also pass the key to the pane.
        act_and_passthrough,
        /// Don't execute action, just pass key to pane.
        /// Useful for explicitly consuming a key combo without action,
        /// or for conditional passthrough (e.g., when fg=nvim).
        passthrough_only,
    };

    pub const BindKeyKind = enum {
        char,
        up,
        down,
        left,
        right,
        space,
    };

    pub const BindKey = union(BindKeyKind) {
        char: u8,
        up,
        down,
        left,
        right,
        space,
    };

    pub const BindActionTag = enum {
        mux_quit,
        mux_detach,
        pane_disown,
        pane_adopt,
        pane_close,
        pane_select_mode,
        clipboard_copy,
        clipboard_request,
        system_notify,
        keycast_toggle,
        sprite_toggle,
        split_h,
        split_v,
        split_resize,
        tab_new,
        tab_next,
        tab_prev,
        tab_close,
        float_toggle,
        float_show,
        float_hide,
        float_nudge,
        focus_move,
        layout_save,
        layout_load,
        sync_toggle,
        tab_rename,
        pane_zoom,
        config_reload,
        copy_enter,
        search_enter,
        prompt_previous,
        prompt_next,
        prompt_copy_output,
        /// Run a Lua function. The escape hatch that makes the action side as
        /// open as the condition side: anything the query API can see, the
        /// callback can act on.
        lua,
    };

    pub const BindAction = union(BindActionTag) {
        mux_quit,
        mux_detach,
        pane_disown,
        pane_adopt,
        pane_close, // close current float or split pane (never closes tab)
        pane_select_mode, // enter pane select mode (focus or swap)
        clipboard_copy, // copy current mux selection via vaxis OSC52
        clipboard_request, // request system clipboard via OSC52 through vaxis
        system_notify, // send desktop notification via terminal OSC
        keycast_toggle, // toggle keycast overlay
        sprite_toggle, // toggle pokemon sprite overlay
        split_h,
        split_v,
        split_resize: BindKeyKind, // up/down/left/right (resize divider)
        tab_new,
        tab_next,
        tab_prev,
        tab_close,
        float_toggle: u8, // float key (matches FloatDef.key)
        // Idempotent counterparts to the toggle: "make sure it is showing" and
        // "make sure it is not". A script that reads visibility and then
        // toggles acts on what it saw, not on what is true when it runs.
        float_show: u8,
        float_hide: u8,
        float_nudge: BindKeyKind, // up/down/left/right
        focus_move: BindKeyKind, // up/down/left/right
        layout_save,
        layout_load,
        sync_toggle, // toggle broadcasting input to all panes in the tab
        tab_rename, // inline-rename the active tab
        pane_zoom, // toggle zoom/maximize of the focused tiled pane
        config_reload, // re-read the Lua config and hot-swap it
        copy_enter, // enter keyboard copy-mode
        search_enter, // enter scrollback text search
        prompt_previous,
        prompt_next,
        prompt_copy_output,
        /// Callback-registry reference (`__hexe_cb_ref:<id>`) for the function
        /// to run. Owned by Config; freed with the bind.
        lua: []const u8,
    };

    pub const Bind = struct {
        on: BindWhen = .press,
        mods: u8 = 0, // bitmask of KeyMod
        key: BindKey,
        action: BindAction,
        /// Registry reference for the Lua predicate guarding this bind
        /// (`__hexe_cb_ref:<id>`). A bind fires only when the callback returns
        /// a truthy value; null means unconditional.
        when: ?[]const u8 = null,
        /// Controls whether to consume the key or pass it through.
        mode: BindMode = .act_and_consume,

        // Timing (used by hold)
        hold_ms: ?i64 = null,
    };

    pub fn modsMaskFromStrings(mods: ?[]const []const u8) u8 {
        var mods_mask: u8 = 0;
        if (mods) |items| {
            for (items) |m| {
                if (std.mem.eql(u8, m, "alt")) mods_mask |= 1;
                if (std.mem.eql(u8, m, "ctrl")) mods_mask |= 2;
                if (std.mem.eql(u8, m, "shift")) mods_mask |= 4;
                if (std.mem.eql(u8, m, "super")) mods_mask |= 8;
            }
        }
        return mods_mask;
    }

    pub const InputConfig = struct {
        binds: []const Bind = &[_]Bind{},

        // Two thresholds define three modes:
        // < tap_ms = REPEAT (no action)
        // tap_ms to hold_ms = TAP (fires action)
        // > hold_ms = HOLD (fires hold action if defined)
        tap_ms: i64 = 200,
        hold_ms: i64 = 600,
    };

    pub const MouseConfig = struct {
        /// Modifier chord required to override the default mouse routing.
        ///
        /// When this chord is held during mouse drag, the mux will perform
        /// pane-local selection even when the target pane is in alt-screen.
        ///
        /// Bitmask uses hexe.mod values (alt=1, ctrl=2, shift=4, super=8).
        selection_override_mods: u8 = 1 | 2, // default: Ctrl+Alt
    };

    // Config status for notifications
    status: lua_runtime.ConfigStatus = .loaded,
    status_message: ?[]const u8 = null,

    input: InputConfig = .{},

    mouse: MouseConfig = .{},

    // Confirmation popups
    confirm_on_exit: bool = false, // When Alt+q or last shell exits
    confirm_on_detach: bool = false,
    confirm_on_disown: bool = false, // When Alt+z disowns a pane
    confirm_on_close: bool = false, // When Alt+x closes a float/tab

    // Floating pane defaults
    float_named_defaults: FloatVisualPreset = .{},
    float_adhoc_defaults: FloatVisualPreset = .{},
    float_match_rules: []FloatMatchRule = &[_]FloatMatchRule{},
    // Default float attributes (from mux.float.attributes)
    float_default_attributes: FloatAttributes = .{},

    // Palette namespaces (PLAN.md M7). On by default: a namespace resolves
    // nothing until something patches an entry, so this is inert until a
    // palette is actually set, and the render path measured inside the M0
    // baseline with it enabled.
    palette_namespaces: bool = true,
    palette_osc: u32 = 1330,

    /// Where names come from. Absent dictionaries mean the built-in pools:
    /// Greek for sessions, NATO for panes. Anything richer is produced by a
    /// command at config load, by whoever can also draw it.
    names: NamesConfig = .{},

    /// Decoration slots around every pane (docs/decor.md).
    decor: DecorConfig = .{},

    // Selection color (palette index, default 240)
    selection_color: u8 = 240,

    // Splits
    splits: SplitsConfig = .{},

    // Tabs (includes status)
    tabs: TabsConfig = .{},

    // Notifications
    notifications: NotificationConfig = .{},

    // Helper programs hexe starts for you.
    plugins: []const PluginDef = &.{},

    // Internal
    _allocator: ?std.mem.Allocator = null,
    _lua_runtime: ?*LuaRuntime = null,

    pub fn load(allocator: std.mem.Allocator) Config {
        var config = Config{};
        config._allocator = allocator;

        PARSE_ERROR = null;

        const path = lua_runtime.getActiveConfigPath(allocator) catch {
            return config;
        };
        defer freeSlice(allocator, path);

        const runtime_ptr = allocator.create(LuaRuntime) catch {
            config.status = .@"error";
            config.status_message = dupeStatusMessage(allocator, "failed to allocate Lua runtime");
            return config;
        };
        runtime_ptr.* = LuaRuntime.init(allocator) catch {
            allocator.destroy(runtime_ptr);
            config.status = .@"error";
            config.status_message = dupeStatusMessage(allocator, "failed to initialize Lua");
            return config;
        };
        var runtime = runtime_ptr;
        config._lua_runtime = runtime_ptr;

        // Load global config
        runtime.loadConfig(path) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    config.status = .missing;
                },
                else => {
                    config.status = .@"error";
                    if (runtime.last_error) |msg| {
                        config.status_message = dupeStatusMessage(allocator, msg);
                    }
                },
            }
            return config;
        };

        // Pop config return value (if any) from stack
        runtime.pop();

        if (!shouldLoadLocalConfig()) {
            applyBuilderConfig(runtime, &config, allocator);
            if (config.status != .@"error") {
                if (PARSE_ERROR) |msg| {
                    config.status = .@"error";
                    config.status_message = msg;
                    PARSE_ERROR = null;
                }
            }
            return config;
        }

        // Try to load local .hexe.lua from current directory
        const local_path = allocator.dupe(u8, ".hexe.lua") catch |err| {
            log.warn("failed to allocate local terminal config path: {s}", .{@errorName(err)});
            return config;
        };
        defer freeSlice(allocator, local_path);

        log.debug("checking for local config: {s}", .{local_path});

        // Check if local config exists
        std.fs.cwd().access(local_path, .{}) catch {
            // No local config, use global only
            log.debug("no local config found", .{});
            applyBuilderConfig(runtime, &config, allocator);
            if (config.status != .@"error") {
                if (PARSE_ERROR) |msg| {
                    config.status = .@"error";
                    config.status_message = msg;
                    PARSE_ERROR = null;
                }
            }
            return config;
        };

        log.info("loading local config from: {s}", .{local_path});

        // Local config exists, load it and merge/overwrite
        runtime.loadProjectConfig(local_path) catch |err| {
            // Failed to load local config, but global is already loaded
            log.warn("failed to load local config: {}", .{err});
            applyBuilderConfig(runtime, &config, allocator);
            if (config.status != .@"error") {
                if (PARSE_ERROR) |msg| {
                    config.status = .@"error";
                    config.status_message = msg;
                    PARSE_ERROR = null;
                }
            }
            return config;
        };

        // Rebuild from ConfigBuilder after local config load so canonical
        // hexe.setup({ mux = ..., keys = ... }) values are applied.
        applyBuilderConfig(runtime, &config, allocator);

        // Pop local config table
        runtime.pop();

        if (config.status != .@"error") {
            if (PARSE_ERROR) |msg| {
                config.status = .@"error";
                config.status_message = msg;
                PARSE_ERROR = null;
            }
        }

        return config;
    }

    fn applyBuilderConfig(runtime: *LuaRuntime, config: *Config, allocator: std.mem.Allocator) void {
        if (runtime.getBuilder()) |builder| {
            if (builder.mux) |mux_builder| {
                log.debug("building mux config from ConfigBuilder", .{});
                const keep_runtime = config._lua_runtime;
                config.* = mux_builder.build() catch config.*;
                config._allocator = allocator;
                config._lua_runtime = keep_runtime;
            }
        }
    }

    /// Parse config from an already-loaded Lua runtime.
    /// Useful for validation where you want to handle Lua errors separately.
    /// The runtime should have the config file already loaded via doFile().
    /// local_only: if true, only parse from top-level table (not from "mux" section)
    pub fn deinit(self: *Config) void {
        if (self._allocator) |alloc| {
            if (self.status_message) |msg| {
                freeSlice(alloc, msg);
            }
            if (self.input.binds.len > 0) {
                for (self.input.binds) |b| {
                    if (b.when) |code| freeSlice(alloc, @constCast(code));
                    if (b.action == .lua) freeSlice(alloc, @constCast(b.action.lua));
                }
                freeSlice(alloc, self.input.binds);
            }

            if (self._lua_runtime) |rt| {
                rt.deinit();
                alloc.destroy(rt);
                self._lua_runtime = null;
            }

            self.float_named_defaults.deinit(alloc);
            self.float_adhoc_defaults.deinit(alloc);
            if (self.float_match_rules.len > 0) {
                for (self.float_match_rules) |*rule| {
                    var mutable_rule = @constCast(rule);
                    mutable_rule.deinit(alloc);
                }
                freeSlice(alloc, self.float_match_rules);
            }
        }
    }
};

// ===== Lua config parsing =====

/// Parse a key string into a BindKey.
/// Supports: single chars (a-z, 0-9), "space", "up", "down", "left", "right", etc.
fn parseKeyString(key_str: []const u8) ?Config.BindKey {
    if (key_str.len == 1) return .{ .char = key_str[0] };
    if (std.mem.eql(u8, key_str, "space")) return .space;
    if (std.mem.eql(u8, key_str, "up")) return .up;
    if (std.mem.eql(u8, key_str, "down")) return .down;
    if (std.mem.eql(u8, key_str, "left")) return .left;
    if (std.mem.eql(u8, key_str, "right")) return .right;
    return null;
}

fn parseAction(runtime: *LuaRuntime, action_type: []const u8) ?Config.BindAction {
    if (std.mem.eql(u8, action_type, "mux.quit")) return .mux_quit;
    if (std.mem.eql(u8, action_type, "mux.detach")) return .mux_detach;
    if (std.mem.eql(u8, action_type, "pane.disown")) return .pane_disown;
    if (std.mem.eql(u8, action_type, "pane.adopt")) return .pane_adopt;
    if (std.mem.eql(u8, action_type, "pane.close")) return .pane_close;
    if (std.mem.eql(u8, action_type, "pane.sync_toggle")) return .sync_toggle;
    if (std.mem.eql(u8, action_type, "tab.rename")) return .tab_rename;
    if (std.mem.eql(u8, action_type, "pane.zoom")) return .pane_zoom;
    if (std.mem.eql(u8, action_type, "config.reload")) return .config_reload;
    if (std.mem.eql(u8, action_type, "copy.enter")) return .copy_enter;
    if (std.mem.eql(u8, action_type, "search.enter")) return .search_enter;
    if (std.mem.eql(u8, action_type, "prompt.previous")) return .prompt_previous;
    if (std.mem.eql(u8, action_type, "prompt.next")) return .prompt_next;
    if (std.mem.eql(u8, action_type, "prompt.copy_output")) return .prompt_copy_output;
    if (std.mem.eql(u8, action_type, "pane.select_mode")) return .pane_select_mode;
    if (std.mem.eql(u8, action_type, "clipboard.copy")) return .clipboard_copy;
    if (std.mem.eql(u8, action_type, "clipboard.request")) return .clipboard_request;
    if (std.mem.eql(u8, action_type, "system.notify")) return .system_notify;
    if (std.mem.eql(u8, action_type, "overlay.keycast_toggle")) return .keycast_toggle;
    if (std.mem.eql(u8, action_type, "overlay.sprite_toggle")) return .sprite_toggle;
    if (std.mem.eql(u8, action_type, "split.h")) return .split_h;
    if (std.mem.eql(u8, action_type, "split.v")) return .split_v;
    if (std.mem.eql(u8, action_type, "tab.new")) return .tab_new;
    if (std.mem.eql(u8, action_type, "tab.next")) return .tab_next;
    if (std.mem.eql(u8, action_type, "tab.prev")) return .tab_prev;
    if (std.mem.eql(u8, action_type, "tab.close")) return .tab_close;
    if (std.mem.eql(u8, action_type, "layout.save")) return .layout_save;
    if (std.mem.eql(u8, action_type, "layout.load")) return .layout_load;

    if (std.mem.eql(u8, action_type, "split.resize")) {
        const dir = runtime.getString(-1, "dir") orelse return null;
        const d = std.meta.stringToEnum(Config.BindKeyKind, dir) orelse return null;
        if (d != .up and d != .down and d != .left and d != .right) return null;
        return .{ .split_resize = d };
    }
    if (std.mem.eql(u8, action_type, "float.toggle")) {
        const fk = runtime.getString(-1, "float") orelse return null;
        if (fk.len != 1) return null;
        return .{ .float_toggle = fk[0] };
    }
    if (std.mem.eql(u8, action_type, "float.show")) {
        const fk = runtime.getString(-1, "float") orelse return null;
        if (fk.len != 1) return null;
        return .{ .float_show = fk[0] };
    }
    if (std.mem.eql(u8, action_type, "float.hide")) {
        const fk = runtime.getString(-1, "float") orelse return null;
        if (fk.len != 1) return null;
        return .{ .float_hide = fk[0] };
    }
    if (std.mem.eql(u8, action_type, "float.nudge")) {
        const dir = runtime.getString(-1, "dir") orelse return null;
        const d = std.meta.stringToEnum(Config.BindKeyKind, dir) orelse return null;
        if (d != .up and d != .down and d != .left and d != .right) return null;
        return .{ .float_nudge = d };
    }
    if (std.mem.eql(u8, action_type, "focus.move")) {
        const dir = runtime.getString(-1, "dir") orelse return null;
        const d = std.meta.stringToEnum(Config.BindKeyKind, dir) orelse return null;
        if (d != .up and d != .down and d != .left and d != .right) return null;
        return .{ .focus_move = d };
    }

    return null;
}

fn parseSimpleAction(action: []const u8) ?Config.BindAction {
    if (std.mem.eql(u8, action, "mux.quit")) return .mux_quit;
    if (std.mem.eql(u8, action, "mux.detach")) return .mux_detach;
    if (std.mem.eql(u8, action, "pane.disown")) return .pane_disown;
    if (std.mem.eql(u8, action, "pane.adopt")) return .pane_adopt;
    if (std.mem.eql(u8, action, "pane.close")) return .pane_close;
    if (std.mem.eql(u8, action, "pane.sync_toggle")) return .sync_toggle;
    if (std.mem.eql(u8, action, "tab.rename")) return .tab_rename;
    if (std.mem.eql(u8, action, "pane.zoom")) return .pane_zoom;
    if (std.mem.eql(u8, action, "config.reload")) return .config_reload;
    if (std.mem.eql(u8, action, "copy.enter")) return .copy_enter;
    if (std.mem.eql(u8, action, "search.enter")) return .search_enter;
    if (std.mem.eql(u8, action, "prompt.previous")) return .prompt_previous;
    if (std.mem.eql(u8, action, "prompt.next")) return .prompt_next;
    if (std.mem.eql(u8, action, "prompt.copy_output")) return .prompt_copy_output;
    if (std.mem.eql(u8, action, "pane.select_mode")) return .pane_select_mode;
    if (std.mem.eql(u8, action, "clipboard.copy")) return .clipboard_copy;
    if (std.mem.eql(u8, action, "clipboard.request")) return .clipboard_request;
    if (std.mem.eql(u8, action, "system.notify")) return .system_notify;
    if (std.mem.eql(u8, action, "overlay.keycast_toggle")) return .keycast_toggle;
    if (std.mem.eql(u8, action, "overlay.sprite_toggle")) return .sprite_toggle;
    if (std.mem.eql(u8, action, "split.h")) return .split_h;
    if (std.mem.eql(u8, action, "split.v")) return .split_v;
    if (std.mem.eql(u8, action, "tab.new")) return .tab_new;
    if (std.mem.eql(u8, action, "tab.next")) return .tab_next;
    if (std.mem.eql(u8, action, "tab.prev")) return .tab_prev;
    if (std.mem.eql(u8, action, "tab.close")) return .tab_close;
    if (std.mem.eql(u8, action, "layout.save")) return .layout_save;
    if (std.mem.eql(u8, action, "layout.load")) return .layout_load;
    return null;
}

test "simple prompt actions parse" {
    try std.testing.expectEqual(Config.BindAction.prompt_previous, parseSimpleAction("prompt.previous").?);
    try std.testing.expectEqual(Config.BindAction.prompt_next, parseSimpleAction("prompt.next").?);
    try std.testing.expectEqual(Config.BindAction.prompt_copy_output, parseSimpleAction("prompt.copy_output").?);
}

fn constrainPercent(val: u8, min: u8, max: u8) u8 {
    if (val < min) return min;
    if (val > max) return max;
    return val;
}
