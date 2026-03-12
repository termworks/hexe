const std = @import("std");
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
    PARSE_ERROR = allocator.dupe(u8, msg) catch null;
}

/// Output definition for status modules (style + format pair)
pub const OutputDef = struct {
    style: []const u8 = "",
    format: []const u8 = "$output",
};

/// Spinner definition for mux statusbar modules.
pub const SpinnerDef = struct {
    kind: []const u8 = "knight_rider",
    width: u8 = 8,
    step_ms: u64 = 75,
    hold_frames: u8 = 9,
    trail_len: u8 = 6,
    colors: []const u8 = &[_]u8{},
    bg_color: ?u8 = null,
    placeholder_color: ?u8 = null,

    // Filled at render time by the statusbar module.
    started_at_ms: u64 = 0,

    pub fn deinit(self: *SpinnerDef, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        if (self.colors.len > 0) allocator.free(self.colors);
        self.* = .{};
    }
};

/// Unified condition for keybindings, segments, and prompts.
///
/// Syntax:
///   when = "token"                              -- single token
///   when = { all = { "a", "b" } }               -- AND
///   when = { any = { "a", "b" } }               -- OR
///   when = { any = { { all = { "a", "b" } }, "c" } }  -- OR of ANDs
///   when = { bash = "..." }                     -- bash script
///   when = { lua = function(ctx) return ... end } -- lua callback
pub const WhenDef = struct {
    /// AND of tokens (flat list, no namespaces needed)
    all: ?[][]const u8 = null,
    /// OR of conditions
    any: ?[]const WhenDef = null,
    /// Bash script condition
    bash: ?[]const u8 = null,
    /// Lua script condition
    lua: ?[]const u8 = null,
    /// Fast env var check (true if set and non-empty)
    env: ?[]const u8 = null,
    /// Fast env var check (true if NOT set or empty)
    env_not: ?[]const u8 = null,

    pub fn deinit(self: *WhenDef, allocator: std.mem.Allocator) void {
        if (self.all) |items| {
            for (items) |s| allocator.free(@constCast(s));
            allocator.free(items);
        }
        if (self.any) |items| {
            for (items) |*w| {
                var mw = @constCast(w);
                mw.deinit(allocator);
            }
            allocator.free(items);
        }
        if (self.bash) |s| allocator.free(@constCast(s));
        if (self.lua) |s| allocator.free(@constCast(s));
        if (self.env) |s| allocator.free(@constCast(s));
        if (self.env_not) |s| allocator.free(@constCast(s));
        self.* = .{};
    }
};

/// Segment definition for statusbar and prompt.
/// Both statusbar modules and shell prompt segments use this unified type.
pub const SegmentKind = enum {
    value,
    builtin,
    button,
    progress,
};

pub const Segment = struct {
    name: []const u8,
    kind: SegmentKind = .value,
    // Priority for width-based hiding (lower = higher priority, stays longer)
    priority: u8 = 50,
    // Array of outputs (each with style + format)
    outputs: []const OutputDef = &[_]OutputDef{},
    // Optional for custom modules
    command: ?[]const u8 = null,
    // Optional explicit builtin source name
    builtin: ?[]const u8 = null,
    // Progress behavior tuning
    progress_every_ms: u64 = 1000,
    progress_show_when: ?[]const u8 = null,
    // Optional statusbar click actions (shell commands)
    on_click: ?[]const u8 = null,
    on_right_click: ?[]const u8 = null,
    on_middle_click: ?[]const u8 = null,
    // Optional statusbar button active-state condition (bash, exit 0 = active)
    button_active_bash: ?[]const u8 = null,
    // Optional per-button active style overrides for clicked state.
    button_left_style: ?[]const u8 = null,
    button_middle_style: ?[]const u8 = null,
    button_right_style: ?[]const u8 = null,
    // If true, invert button style when hovered.
    inverse_on_hover: bool = true,
    when: ?WhenDef = null,

    // Optional spinner configuration
    spinner: ?SpinnerDef = null,
    // For tabs segment
    active_style: []const u8 = "bg:1 fg:0",
    inactive_style: []const u8 = "bg:237 fg:250",
    separator: []const u8 = " | ",
    separator_style: []const u8 = "fg:7",
    // For tabs segment: what to show as tab title ("name" or "basename")
    tab_title: []const u8 = "basename",
    // For tabs segment: arrow decorations (empty string = no arrows)
    left_arrow: []const u8 = "",
    right_arrow: []const u8 = "",
};

/// Status bar config
pub const StatusBarConfig = struct {
    enabled: bool = true,
    left: []const Segment = &[_]Segment{},
    center: []const Segment = &[_]Segment{},
    right: []const Segment = &[_]Segment{},
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
    // Optional module in border
    position: ?FloatStylePosition = null,
    module: ?Segment = null,
    title_segments: []const Segment = &[_]Segment{},
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

/// Border color config (active/passive)
pub const BorderColor = struct {
    active: u8 = 1,
    passive: u8 = 237,
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
    // Keys
    key_split_h: u8 = 'h',
    key_split_v: u8 = 'v',
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
    // Keys
    key_new: u8 = 't',
    key_next: u8 = 'n',
    key_prev: u8 = 'p',
    key_close: u8 = 'x',
    key_detach: u8 = 'd',
    // Status bar
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

/// Panes configuration (placeholder for future use)
pub const PanesConfig = struct {};

// ===== Layout definitions for ses section =====

/// Single pane in a layout
pub const LayoutPaneDef = struct {
    cwd: ?[]const u8 = null,
    command: ?[]const u8 = null,

    pub fn deinit(self: *LayoutPaneDef, allocator: std.mem.Allocator) void {
        if (self.cwd) |c| allocator.free(@constCast(c));
        if (self.command) |c| allocator.free(@constCast(c));
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
                allocator.free(@constCast(s.dir));
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
        allocator.free(@constCast(self.name));
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
    command: ?[]const u8 = null,
    title: ?[]const u8 = null,
    attributes: FloatAttributes = .{},
    has_custom_attributes: bool = false, // true if float has its own attributes table
    width_percent: ?u8 = null,
    height_percent: ?u8 = null,
    pos_x: ?u8 = null,
    pos_y: ?u8 = null,
    padding_x: ?u8 = null,
    padding_y: ?u8 = null,
    color: ?BorderColor = null,
    style: ?FloatStyle = null,
    isolation: ?IsolationConfig = null,

    pub fn deinit(self: *LayoutFloatDef, allocator: std.mem.Allocator) void {
        if (self.command) |c| allocator.free(@constCast(c));
        if (self.title) |t| allocator.free(@constCast(t));
        if (self.style) |*style_ptr| {
            const freeSegment = struct {
                fn call(seg: *Segment, a: std.mem.Allocator) void {
                    a.free(@constCast(seg.name));
                    if (seg.outputs.len > 0) {
                        for (seg.outputs) |*out| {
                            a.free(@constCast(out.style));
                            a.free(@constCast(out.format));
                        }
                        a.free(seg.outputs);
                    }
                    if (seg.command) |cmd| a.free(@constCast(cmd));
                    if (seg.builtin) |b| a.free(@constCast(b));
                    if (seg.progress_show_when) |s| a.free(@constCast(s));
                    if (seg.on_click) |cmd| a.free(@constCast(cmd));
                    if (seg.on_right_click) |cmd| a.free(@constCast(cmd));
                    if (seg.on_middle_click) |cmd| a.free(@constCast(cmd));
                    if (seg.button_active_bash) |cmd| a.free(@constCast(cmd));
                    if (seg.button_left_style) |s| a.free(@constCast(s));
                    if (seg.button_middle_style) |s| a.free(@constCast(s));
                    if (seg.button_right_style) |s| a.free(@constCast(s));
                    if (seg.when) |*w| {
                        var when = @constCast(w);
                        when.deinit(a);
                    }
                    if (seg.spinner) |*sp| {
                        var spinner = @constCast(sp);
                        spinner.deinit(a);
                    }
                    a.free(@constCast(seg.active_style));
                    a.free(@constCast(seg.inactive_style));
                    a.free(@constCast(seg.separator));
                    a.free(@constCast(seg.separator_style));
                    a.free(@constCast(seg.tab_title));
                    a.free(@constCast(seg.left_arrow));
                    a.free(@constCast(seg.right_arrow));
                }
            }.call;

            if (style_ptr.module) |*mod| {
                freeSegment(@constCast(mod), allocator);
            }
            if (style_ptr.title_segments.len > 0) {
                for (style_ptr.title_segments) |*seg_ptr| {
                    freeSegment(@constCast(seg_ptr), allocator);
                }
                allocator.free(style_ptr.title_segments);
            }
        }
        if (self.isolation) |*iso| {
            var isolation = @constCast(iso);
            isolation.deinit(allocator);
        }
    }
};

/// Full layout definition
pub const LayoutDef = struct {
    name: []const u8,
    enabled: bool = false,
    tabs: []LayoutTabDef = &[_]LayoutTabDef{},
    floats: []LayoutFloatDef = &[_]LayoutFloatDef{},

    pub fn deinit(self: *LayoutDef, allocator: std.mem.Allocator) void {
        allocator.free(@constCast(self.name));
        for (self.tabs) |*tab| {
            var t = @constCast(tab);
            t.deinit(allocator);
        }
        if (self.tabs.len > 0) {
            allocator.free(self.tabs);
        }
        for (self.floats) |*float| {
            var f = @constCast(float);
            f.deinit(allocator);
        }
        if (self.floats.len > 0) {
            allocator.free(self.floats);
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
        allocator.free(self.profile);
        if (self.memory) |m| allocator.free(@constCast(m));
        if (self.cpu) |c| allocator.free(@constCast(c));
        if (self.pids) |p| allocator.free(@constCast(p));
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
            allocator.free(self.layouts);
        }
    }

    pub fn load(allocator: std.mem.Allocator) SesConfig {
        var config = SesConfig{};

        var runtime = LuaRuntime.init(allocator) catch return config;
        defer runtime.deinit();

        // Set section to "ses"
        runtime.setHexeSection("ses");

        // Load global config
        const config_path = lua_runtime.getConfigPath(allocator, "init.lua") catch return config;
        defer allocator.free(config_path);

        runtime.loadConfig(config_path) catch return config;

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
        const local_path = allocator.dupe(u8, ".hexe.lua") catch return config;
        defer allocator.free(local_path);

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
        runtime.loadConfig(local_path) catch {
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
        float_nudge,
        focus_move,
        layout_save,
        layout_load,
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
        float_nudge: BindKeyKind, // up/down/left/right
        focus_move: BindKeyKind, // up/down/left/right
        layout_save,
        layout_load,
    };

    pub const Bind = struct {
        on: BindWhen = .press,
        mods: u8 = 0, // bitmask of KeyMod
        key: BindKey,
        action: BindAction,
        /// Condition for when this bind is active.
        when: ?WhenDef = null,
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
        /// Bitmask uses hx.mod values (alt=1, ctrl=2, shift=4, super=8).
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
    float_width_percent: u8 = 60,
    float_height_percent: u8 = 60,
    float_padding_x: u8 = 1, // left/right padding inside border
    float_padding_y: u8 = 0, // top/bottom padding inside border
    // Float borders default to active=1, passive=237.
    float_color: BorderColor = .{},
    float_style_default: ?FloatStyle = null,
    // Default float attributes (from mux.float.attributes)
    float_default_attributes: FloatAttributes = .{},

    // Selection color (palette index, default 240)
    selection_color: u8 = 240,

    // Splits
    splits: SplitsConfig = .{},

    // Tabs (includes status)
    tabs: TabsConfig = .{},

    // Notifications
    notifications: NotificationConfig = .{},

    // Internal
    _allocator: ?std.mem.Allocator = null,
    _lua_runtime: ?*LuaRuntime = null,

    pub fn load(allocator: std.mem.Allocator) Config {
        var config = Config{};
        config._allocator = allocator;

        PARSE_ERROR = null;

        const path = lua_runtime.getConfigPath(allocator, "init.lua") catch {
            return config;
        };
        defer allocator.free(path);

        const runtime_ptr = allocator.create(LuaRuntime) catch {
            config.status = .@"error";
            config.status_message = allocator.dupe(u8, "failed to allocate Lua runtime") catch null;
            return config;
        };
        runtime_ptr.* = LuaRuntime.init(allocator) catch {
            allocator.destroy(runtime_ptr);
            config.status = .@"error";
            config.status_message = allocator.dupe(u8, "failed to initialize Lua") catch null;
            return config;
        };
        var runtime = runtime_ptr;
        config._lua_runtime = runtime_ptr;

        // Let a single config file avoid building other sections.
        runtime.setHexeSection("mux");

        // Load global config
        runtime.loadConfig(path) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    config.status = .missing;
                },
                else => {
                    config.status = .@"error";
                    if (runtime.last_error) |msg| {
                        config.status_message = allocator.dupe(u8, msg) catch null;
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
        const local_path = allocator.dupe(u8, ".hexe.lua") catch return config;
        defer allocator.free(local_path);

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
        runtime.loadConfig(local_path) catch |err| {
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

        // Rebuild from ConfigBuilder after local config load so local builder calls
        // (hexe.mux.* API) are applied consistently with global config loading.
        applyBuilderConfig(runtime, &config, allocator);

        // Access the "mux" section of the local config table and merge
        if (runtime.pushTable(-1, "mux")) {
            log.info("parsing mux section from local config", .{});
            parseConfig(runtime, &config, allocator);
            runtime.pop();
        } else {
            log.warn("no mux section in local config", .{});
        }

        // Optional top-level layout keybindings from .hexe.lua
        // Format: return { keybingings = { ... }, layout = { ... } }
        if (runtime.pushTable(-1, "keybingings")) {
            const old_count = config.input.binds.len;
            config.input.binds = parseBinds(runtime, allocator, config.input.binds);
            log.info("parsed {} local layout keybindings (was {})", .{ config.input.binds.len, old_count });
            runtime.pop();
        }

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
    pub fn parseFromLua(runtime: *LuaRuntime, local_only: bool) !Config {
        var config = Config{};
        config._allocator = runtime.allocator;

        PARSE_ERROR = null;

        // If not local_only, access the "mux" section
        if (!local_only) {
            runtime.setHexeSection("mux");
            if (runtime.pushTable(-1, "mux")) {
                parseConfig(runtime, &config, runtime.allocator);
                runtime.pop();
            } else {
                config.status = .@"error";
                config.status_message = runtime.allocator.dupe(u8, "no 'mux' section in config") catch null;
                return config;
            }
            runtime.pop(); // Pop global config table
        } else {
            // Parse directly from top-level table (for standalone config files)
            parseConfig(runtime, &config, runtime.allocator);
        }

        if (config.status != .@"error") {
            if (PARSE_ERROR) |msg| {
                config.status = .@"error";
                config.status_message = msg;
                PARSE_ERROR = null;
                return error.ConfigError;
            }
        }

        if (config.status == .@"error") {
            return error.ConfigError;
        }

        return config;
    }

    pub fn deinit(self: *Config) void {
        if (self._allocator) |alloc| {
            if (self.status_message) |msg| {
                alloc.free(msg);
            }
            if (self.input.binds.len > 0) {
                for (self.input.binds) |b| {
                    if (b.when) |w| {
                        var mw = w;
                        mw.deinit(alloc);
                    }
                }
                alloc.free(self.input.binds);
            }

            if (self._lua_runtime) |rt| {
                rt.deinit();
                alloc.destroy(rt);
                self._lua_runtime = null;
            }
        }
    }
};

// ===== Lua config parsing =====

fn parseConfig(runtime: *LuaRuntime, config: *Config, allocator: std.mem.Allocator) void {
    // Parse input section
    if (runtime.pushTable(-1, "input")) {
        parseInputConfig(runtime, config, allocator);
        runtime.pop();
    }

    // Parse mouse section
    if (runtime.pushTable(-1, "mouse")) {
        parseMouseConfig(runtime, config);
        runtime.pop();
    }

    // Confirmation settings
    if (runtime.getBool(-1, "confirm_on_exit")) |v| config.confirm_on_exit = v;
    if (runtime.getBool(-1, "confirm_on_detach")) |v| config.confirm_on_detach = v;
    if (runtime.getBool(-1, "confirm_on_disown")) |v| config.confirm_on_disown = v;
    if (runtime.getBool(-1, "confirm_on_close")) |v| config.confirm_on_close = v;

    // Selection color
    if (runtime.getInt(u8, -1, "selection_color")) |v| config.selection_color = v;

    // Parse float defaults
    if (runtime.pushTable(-1, "float")) {
        parseFloat(runtime, config, allocator);
        runtime.pop();
    }

    // Parse splits
    if (runtime.pushTable(-1, "splits")) {
        parseSplits(runtime, config);
        runtime.pop();
    }

    // Parse tabs
    if (runtime.pushTable(-1, "tabs")) {
        parseTabs(runtime, config, allocator);
        runtime.pop();
    }

    // Parse notifications
    if (runtime.pushTable(-1, "notifications")) {
        parseNotifications(runtime, config, allocator);
        runtime.pop();
    }
}

fn parseMouseConfig(runtime: *LuaRuntime, config: *Config) void {
    // Accept either:
    // - selection_override_mods = <number>
    // - selection_override_mods = { hx.mod.ctrl, hx.mod.alt }
    if (runtime.pushTable(-1, "selection_override_mods")) {
        defer runtime.pop();
        var mask: u8 = 0;
        const len = runtime.getArrayLen(-1);
        for (1..len + 1) |i| {
            if (runtime.pushArrayElement(-1, i)) {
                if (runtime.toIntAt(u8, -1)) |m| {
                    mask |= m;
                }
                runtime.pop();
            }
        }
        config.mouse.selection_override_mods = mask;
        return;
    }

    if (runtime.getInt(u8, -1, "selection_override_mods")) |m| {
        config.mouse.selection_override_mods = m;
    }
}

fn parseInputConfig(runtime: *LuaRuntime, config: *Config, allocator: std.mem.Allocator) void {
    log.debug("parsing input config", .{});

    // Parse timing
    if (runtime.pushTable(-1, "timing")) {
        if (runtime.getInt(i64, -1, "tap_ms")) |v| config.input.tap_ms = v;
        if (runtime.getInt(i64, -1, "hold_ms")) |v| config.input.hold_ms = v;
        runtime.pop();
    }

    // Parse binds array
    if (runtime.pushTable(-1, "binds")) {
        const old_count = config.input.binds.len;
        config.input.binds = parseBinds(runtime, allocator, config.input.binds);
        log.info("parsed {} keybindings (was {})", .{ config.input.binds.len, old_count });
        runtime.pop();
    }
}

fn parseBinds(runtime: *LuaRuntime, allocator: std.mem.Allocator, existing: []const Config.Bind) []const Config.Bind {
    var list = std.ArrayList(Config.Bind).empty;

    // Add existing binds first
    log.debug("parseBinds: starting with {} existing binds", .{existing.len});
    for (existing) |bind| {
        list.append(allocator, bind) catch {};
    }

    const len = runtime.getArrayLen(-1);
    log.debug("parseBinds: found {} new binds to parse", .{len});

    for (1..len + 1) |i| {
        if (runtime.pushArrayElement(-1, i)) {
            if (parseBind(runtime, allocator)) |bind| {
                log.debug("parseBinds: successfully parsed bind #{}", .{i});
                list.append(allocator, bind) catch {};
            } else {
                log.warn("parseBinds: failed to parse bind #{}", .{i});
            }
            runtime.pop();
        }
    }

    const final_count = list.items.len;
    log.debug("parseBinds: returning {} total binds", .{final_count});
    return list.toOwnedSlice(allocator) catch &[_]Config.Bind{};
}

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

fn parseBind(runtime: *LuaRuntime, allocator: std.mem.Allocator) ?Config.Bind {
    // Parse key - supports two formats:
    // 1. New unified: key = { hx.key.alt, hx.key.right } (array of strings)
    // 2. Old format: mods = { hx.mod.alt }, key = "right" (separate fields)

    var mods: u8 = 0;
    var key: Config.BindKey = undefined;
    var key_found = false;

    // Try new unified format first: key = { ... } as array
    if (runtime.pushTable(-1, "key")) {
        const len = runtime.getArrayLen(-1);
        if (len > 0) {
            // It's an array - parse each element
            for (1..len + 1) |i| {
                if (runtime.pushArrayElement(-1, i)) {
                    if (runtime.toStringAt(-1)) |elem| {
                        // Check if it's a modifier (prefixed with "mod:")
                        if (std.mem.startsWith(u8, elem, "mod:")) {
                            const mod_name = elem[4..];
                            if (std.mem.eql(u8, mod_name, "ctrl")) {
                                mods |= 2;
                            } else if (std.mem.eql(u8, mod_name, "alt")) {
                                mods |= 1;
                            } else if (std.mem.eql(u8, mod_name, "shift")) {
                                mods |= 4;
                            } else if (std.mem.eql(u8, mod_name, "super")) {
                                mods |= 8;
                            }
                        } else {
                            // It's a key
                            if (parseKeyString(elem)) |k| {
                                key = k;
                                key_found = true;
                            }
                        }
                    }
                    runtime.pop();
                }
            }
            runtime.pop();
        } else {
            runtime.pop();
        }
    }

    // Fall back to old format if unified format didn't find a key
    if (!key_found) {
        const key_str = runtime.getString(-1, "key") orelse {
            log.warn("parseBind: no 'key' field found", .{});
            return null;
        };
        log.debug("parseBind: parsing bind with key='{s}'", .{key_str});

        key = parseKeyString(key_str) orelse {
            log.warn("parseBind: invalid key '{s}'", .{key_str});
            return null;
        };
        key_found = true;

        // Parse mods from separate field (old format)
        if (runtime.pushTable(-1, "mods")) {
            const len = runtime.getArrayLen(-1);
            for (1..len + 1) |i| {
                if (runtime.pushArrayElement(-1, i)) {
                    if (runtime.toIntAt(u8, -1)) |m| {
                        mods |= m;
                    }
                    runtime.pop();
                }
            }
            runtime.pop();
        } else if (runtime.getInt(u8, -1, "mods")) |m| {
            mods = m;
        }
    }

    if (!key_found) {
        log.warn("parseBind: no valid key found", .{});
        return null;
    }

    // Parse action (required unless mode is passthrough_only)
    var action: Config.BindAction = .mux_quit; // default placeholder
    var action_found = false;

    if (runtime.typeOf(-1) == .table) {
        if (runtime.pushTable(-1, "action")) {
            defer runtime.pop();
            if (runtime.getString(-1, "type")) |action_type| {
                log.debug("parseBind: parsing action type '{s}'", .{action_type});
                if (parseAction(runtime, action_type)) |a| {
                    action = a;
                    action_found = true;
                } else {
                    log.warn("parseBind: failed to parse action type '{s}'", .{action_type});
                }
            } else {
                log.debug("parseBind: action table has no 'type' field", .{});
            }
        }
    }

    // Try direct action string if table didn't work
    if (!action_found) {
        if (runtime.getString(-1, "action")) |action_str| {
            if (parseSimpleAction(action_str)) |a| {
                action = a;
                action_found = true;
            } else {
                log.warn("parseBind: failed to parse simple action '{s}'", .{action_str});
            }
        }
    }

    // Parse mode first to check if action is required
    const mode: Config.BindMode = if (runtime.getString(-1, "mode")) |m|
        std.meta.stringToEnum(Config.BindMode, m) orelse .act_and_consume
    else
        .act_and_consume;

    // Action is only required if mode is not passthrough_only
    if (!action_found and mode != .passthrough_only) {
        log.warn("parseBind: no 'action' field found and mode is not passthrough_only", .{});
        return null;
    }

    // Parse on (press/release/repeat/hold)
    const on: Config.BindWhen = if (runtime.getString(-1, "on")) |o|
        std.meta.stringToEnum(Config.BindWhen, o) orelse .press
    else
        .press;

    // Parse when (condition)
    const when = parseWhenTable(runtime, allocator, true);

    return Config.Bind{
        .on = on,
        .mods = mods,
        .key = key,
        .action = action,
        .when = when,
        .mode = mode,
        .hold_ms = runtime.getInt(i64, -1, "hold_ms"),
    };
}

fn parseStringList(runtime: *LuaRuntime, allocator: std.mem.Allocator, key: [:0]const u8) ?[][]u8 {
    // Accept either: key = {"a","b"} or key = "a"
    if (runtime.pushTable(-1, key)) {
        defer runtime.pop();
        var out = std.ArrayList([]u8).empty;
        const len = runtime.getArrayLen(-1);
        for (1..len + 1) |i| {
            if (runtime.pushArrayElement(-1, i)) {
                if (runtime.toStringAt(-1)) |s| {
                    const dup = allocator.dupe(u8, s) catch null;
                    if (dup) |d| {
                        out.append(allocator, d) catch allocator.free(d);
                    }
                }
                runtime.pop();
            }
        }
        return out.toOwnedSlice(allocator) catch null;
    }

    if (runtime.getString(-1, key)) |s| {
        const one = allocator.dupe(u8, s) catch return null;
        const slice = allocator.alloc([]u8, 1) catch {
            allocator.free(one);
            return null;
        };
        slice[0] = one;
        return slice;
    }

    return null;
}

fn parseAction(runtime: *LuaRuntime, action_type: []const u8) ?Config.BindAction {
    if (std.mem.eql(u8, action_type, "mux.quit")) return .mux_quit;
    if (std.mem.eql(u8, action_type, "mux.detach")) return .mux_detach;
    if (std.mem.eql(u8, action_type, "pane.disown")) return .pane_disown;
    if (std.mem.eql(u8, action_type, "pane.adopt")) return .pane_adopt;
    if (std.mem.eql(u8, action_type, "pane.close")) return .pane_close;
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

fn parseFloat(runtime: *LuaRuntime, config: *Config, allocator: std.mem.Allocator) void {
    // Parse default float settings from float = {} table
    var width: ?u8 = null;
    var height: ?u8 = null;
    var pad_x: ?u8 = null;
    var pad_y: ?u8 = null;
    var color: ?BorderColor = null;
    var style: ?FloatStyle = null;

    if (runtime.pushTable(-1, "size")) {
        if (runtime.getInt(u8, -1, "width")) |v| width = constrainPercent(v, 10, 100);
        if (runtime.getInt(u8, -1, "height")) |v| height = constrainPercent(v, 10, 100);
        runtime.pop();
    }

    if (runtime.pushTable(-1, "padding")) {
        if (runtime.getInt(u8, -1, "x")) |v| pad_x = constrainPercent(v, 0, 10);
        if (runtime.getInt(u8, -1, "y")) |v| pad_y = constrainPercent(v, 0, 10);
        runtime.pop();
    }

    if (runtime.pushTable(-1, "color")) {
        var c = BorderColor{};
        if (runtime.getInt(u8, -1, "active")) |v| c.active = v;
        if (runtime.getInt(u8, -1, "passive")) |v| c.passive = v;
        color = c;
        runtime.pop();
    }

    if (runtime.pushTable(-1, "style")) {
        style = parseFloatStyle(runtime, allocator);
        runtime.pop();
    }

    // Parse default attributes
    if (runtime.pushTable(-1, "attributes")) {
        if (runtime.getBool(-1, "exclusive")) |v| config.float_default_attributes.exclusive = v;
        if (runtime.getBool(-1, "per_cwd")) |v| config.float_default_attributes.per_cwd = v;
        if (runtime.getBool(-1, "sticky")) |v| config.float_default_attributes.sticky = v;
        if (runtime.getBool(-1, "global")) |v| config.float_default_attributes.global = v;
        if (runtime.getBool(-1, "destroy")) |v| config.float_default_attributes.destroy = v;
        if (runtime.getBool(-1, "isolated")) |v| config.float_default_attributes.isolated = v;
        if (runtime.getBool(-1, "inherit_env")) |v| config.float_default_attributes.inherit_env = v;
        runtime.pop();
    }

    // Apply to config defaults
    if (width) |w| config.float_width_percent = w;
    if (height) |h| config.float_height_percent = h;
    if (pad_x) |p| config.float_padding_x = p;
    if (pad_y) |p| config.float_padding_y = p;
    if (color) |c| config.float_color = c;
    if (style) |s| config.float_style_default = s;
}

fn parseFloatStyle(runtime: *LuaRuntime, allocator: std.mem.Allocator) FloatStyle {
    var result = FloatStyle{};

    // Border characters
    if (runtime.pushTable(-1, "border")) {
        if (runtime.pushTable(-1, "chars")) {
            result.top_left = lua_runtime.parseUnicodeChar(runtime, -1, "top_left", 0x256D);
            result.top_right = lua_runtime.parseUnicodeChar(runtime, -1, "top_right", 0x256E);
            result.bottom_left = lua_runtime.parseUnicodeChar(runtime, -1, "bottom_left", 0x2570);
            result.bottom_right = lua_runtime.parseUnicodeChar(runtime, -1, "bottom_right", 0x256F);
            result.horizontal = lua_runtime.parseUnicodeChar(runtime, -1, "horizontal", 0x2500);
            result.vertical = lua_runtime.parseUnicodeChar(runtime, -1, "vertical", 0x2502);
            result.cross = lua_runtime.parseUnicodeChar(runtime, -1, "cross", 0x253C);
            result.top_t = lua_runtime.parseUnicodeChar(runtime, -1, "top_t", 0x252C);
            result.bottom_t = lua_runtime.parseUnicodeChar(runtime, -1, "bottom_t", 0x2534);
            result.left_t = lua_runtime.parseUnicodeChar(runtime, -1, "left_t", 0x251C);
            result.right_t = lua_runtime.parseUnicodeChar(runtime, -1, "right_t", 0x2524);
            runtime.pop();
        }
        runtime.pop();
    }

    // Legacy flat border chars
    result.top_left = lua_runtime.parseUnicodeChar(runtime, -1, "top_left", result.top_left);
    result.top_right = lua_runtime.parseUnicodeChar(runtime, -1, "top_right", result.top_right);
    result.bottom_left = lua_runtime.parseUnicodeChar(runtime, -1, "bottom_left", result.bottom_left);
    result.bottom_right = lua_runtime.parseUnicodeChar(runtime, -1, "bottom_right", result.bottom_right);
    result.horizontal = lua_runtime.parseUnicodeChar(runtime, -1, "horizontal", result.horizontal);
    result.vertical = lua_runtime.parseUnicodeChar(runtime, -1, "vertical", result.vertical);

    // Shadow
    if (runtime.pushTable(-1, "shadow")) {
        if (runtime.getInt(u8, -1, "color")) |c| result.shadow_color = c;
        runtime.pop();
    }

    // Title
    if (runtime.pushTable(-1, "title")) {
        if (runtime.getString(-1, "position")) |pos_str| {
            result.position = std.meta.stringToEnum(FloatStylePosition, pos_str);
        }

        if (runtime.pushTable(-1, "segments")) {
            defer runtime.pop();
            const len = runtime.getArrayLen(-1);
            if (len > 0) {
                const segs = allocator.alloc(Segment, len) catch null;
                if (segs) |arr| {
                    var count: usize = 0;
                    for (1..len + 1) |i| {
                        if (!runtime.pushArrayElement(-1, i)) continue;
                        const seg = parseSegmentWithDefaultName(runtime, allocator, "title") orelse {
                            runtime.pop();
                            continue;
                        };
                        runtime.pop();
                        arr[count] = seg;
                        count += 1;
                    }
                    result.title_segments = arr[0..count];
                }
            }
        }

        if (result.title_segments.len == 0) {
            // For float titles we allow omitting `name` and default to "title".
            // The module outputs define styling for the title text.
            result.module = parseSegmentWithDefaultName(runtime, allocator, "title");
        }
        runtime.pop();
    }

    // Legacy flat position
    if (runtime.getString(-1, "position")) |pos_str| {
        result.position = std.meta.stringToEnum(FloatStylePosition, pos_str);
    }

    return result;
}

fn parseSegmentWithDefaultName(runtime: *LuaRuntime, allocator: std.mem.Allocator, default_name: ?[]const u8) ?Segment {
    const name = runtime.getStringAlloc(-1, "name") orelse blk: {
        if (default_name) |dn| {
            break :blk allocator.dupe(u8, dn) catch return null;
        }
        return null;
    };

    var value_code: ?[]const u8 = blk: {
        if (runtime.getString(-1, "value")) |v| {
            const trimmed = std.mem.trim(u8, v, " \t\r\n");
            if (trimmed.len == 0) break :blk null;
            break :blk allocator.dupe(u8, trimmed) catch null;
        }
        if (runtime.pushTable(-1, "value")) {
            defer runtime.pop();
            if (runtime.getString(-1, "lua")) |v| {
                const trimmed = std.mem.trim(u8, v, " \t\r\n");
                if (trimmed.len > 0) break :blk allocator.dupe(u8, trimmed) catch null;
            }
            if (runtime.getString(-1, "fn")) |v| {
                const trimmed = std.mem.trim(u8, v, " \t\r\n");
                if (trimmed.len > 0) break :blk allocator.dupe(u8, trimmed) catch null;
            }
        }
        break :blk null;
    };

    var source_builtin: ?[]const u8 = null;
    var source_value: ?[]const u8 = null;
    if (runtime.pushTable(-1, "source")) {
        defer runtime.pop();
        source_builtin = runtime.getStringAlloc(-1, "builtin") orelse runtime.getStringAlloc(-1, "name") orelse runtime.getStringAlloc(-1, "segment");
        if (runtime.getString(-1, "value")) |v| {
            const trimmed = std.mem.trim(u8, v, " \t\r\n");
            if (trimmed.len > 0) source_value = allocator.dupe(u8, trimmed) catch null;
        }
    }

    var builtin_name: ?[]const u8 = runtime.getStringAlloc(-1, "builtin");
    if (builtin_name == null and runtime.pushTable(-1, "builtin")) {
        defer runtime.pop();
        builtin_name = runtime.getStringAlloc(-1, "name") orelse runtime.getStringAlloc(-1, "segment");
    }
    if (builtin_name == null) {
        builtin_name = source_builtin;
    } else if (source_builtin) |b| {
        allocator.free(b);
    }
    if (value_code == null) {
        value_code = source_value;
    } else if (source_value) |v| {
        allocator.free(v);
    }
    var show_when_code: ?[]const u8 = blk: {
        if (runtime.getString(-1, "show_when")) |v| {
            const trimmed = std.mem.trim(u8, v, " \t\r\n");
            if (trimmed.len == 0) break :blk null;
            break :blk allocator.dupe(u8, trimmed) catch null;
        }
        break :blk null;
    };

    if (runtime.pushTable(-1, "progress")) {
        defer runtime.pop();
        if (runtime.getInt(u64, -1, "every_ms")) |v| {
            _ = v;
        }
        if (show_when_code == null) {
            if (runtime.getString(-1, "show_when")) |v| {
                const trimmed = std.mem.trim(u8, v, " \t\r\n");
                if (trimmed.len > 0) show_when_code = allocator.dupe(u8, trimmed) catch null;
            }
        }
        if (builtin_name == null) {
            builtin_name = runtime.getStringAlloc(-1, "builtin");
        }
        if (builtin_name == null and runtime.pushTable(-1, "source")) {
            defer runtime.pop();
            builtin_name = runtime.getStringAlloc(-1, "builtin") orelse runtime.getStringAlloc(-1, "name") orelse runtime.getStringAlloc(-1, "segment");
        }
        if (value_code == null) {
            if (runtime.getString(-1, "value")) |v| {
                const trimmed = std.mem.trim(u8, v, " \t\r\n");
                if (trimmed.len > 0) value_code = allocator.dupe(u8, trimmed) catch null;
            }
            if (value_code == null and runtime.pushTable(-1, "source")) {
                defer runtime.pop();
                if (runtime.getString(-1, "value")) |v| {
                    const trimmed = std.mem.trim(u8, v, " \t\r\n");
                    if (trimmed.len > 0) value_code = allocator.dupe(u8, trimmed) catch null;
                }
            }
        }
    }

    const has_button = runtime.fieldType(-1, "button") == .table or
        runtime.fieldType(-1, "on_click") == .string or
        runtime.fieldType(-1, "on_left_click") == .string or
        runtime.fieldType(-1, "on_right_click") == .string or
        runtime.fieldType(-1, "on_middle_click") == .string;
    const has_progress = runtime.fieldType(-1, "progress") == .table or show_when_code != null or runtime.fieldType(-1, "every_ms") != .nil;
    const progress_every_ms: u64 = blk: {
        if (runtime.getInt(u64, -1, "every_ms")) |v| break :blk v;
        if (runtime.pushTable(-1, "progress")) {
            defer runtime.pop();
            if (runtime.getInt(u64, -1, "every_ms")) |v| break :blk v;
        }
        break :blk 1000;
    };

    var on_click = runtime.getStringAlloc(-1, "on_click") orelse runtime.getStringAlloc(-1, "on_left_click");
    var on_right_click = runtime.getStringAlloc(-1, "on_right_click") orelse runtime.getStringAlloc(-1, "right_click");
    var on_middle_click = runtime.getStringAlloc(-1, "on_middle_click") orelse runtime.getStringAlloc(-1, "middle_click");
    var button_active_bash = runtime.getStringAlloc(-1, "button_active_bash");
    var button_left_style = runtime.getStringAlloc(-1, "button_left_style") orelse runtime.getStringAlloc(-1, "left_click_style") orelse runtime.getStringAlloc(-1, "on_left_click_style");
    var button_middle_style = runtime.getStringAlloc(-1, "button_middle_style") orelse runtime.getStringAlloc(-1, "middle_click_style") orelse runtime.getStringAlloc(-1, "on_middle_click_style");
    var button_right_style = runtime.getStringAlloc(-1, "button_right_style") orelse runtime.getStringAlloc(-1, "right_click_style") orelse runtime.getStringAlloc(-1, "on_right_click_style");
    var inverse_on_hover = runtime.getBool(-1, "inverse_on_hover") orelse true;
    if (runtime.pushTable(-1, "button")) {
        defer runtime.pop();
        if (on_click == null) on_click = runtime.getStringAlloc(-1, "on_click") orelse runtime.getStringAlloc(-1, "on_left_click");
        if (on_right_click == null) on_right_click = runtime.getStringAlloc(-1, "on_right_click") orelse runtime.getStringAlloc(-1, "right_click");
        if (on_middle_click == null) on_middle_click = runtime.getStringAlloc(-1, "on_middle_click") orelse runtime.getStringAlloc(-1, "middle_click");
        if (button_active_bash == null) button_active_bash = runtime.getStringAlloc(-1, "active_when");
        if (button_left_style == null) button_left_style = runtime.getStringAlloc(-1, "left_style") orelse runtime.getStringAlloc(-1, "left_click_style") orelse runtime.getStringAlloc(-1, "on_left_click_style");
        if (button_middle_style == null) button_middle_style = runtime.getStringAlloc(-1, "middle_style") orelse runtime.getStringAlloc(-1, "middle_click_style") orelse runtime.getStringAlloc(-1, "on_middle_click_style");
        if (button_right_style == null) button_right_style = runtime.getStringAlloc(-1, "right_style") orelse runtime.getStringAlloc(-1, "right_click_style") orelse runtime.getStringAlloc(-1, "on_right_click_style");
        if (runtime.getBool(-1, "inverse_on_hover")) |v| inverse_on_hover = v;
        if (builtin_name == null) builtin_name = runtime.getStringAlloc(-1, "builtin");
        if (builtin_name == null and runtime.pushTable(-1, "source")) {
            defer runtime.pop();
            builtin_name = runtime.getStringAlloc(-1, "builtin") orelse runtime.getStringAlloc(-1, "name") orelse runtime.getStringAlloc(-1, "segment");
        }
        if (value_code == null) {
            if (runtime.getString(-1, "value")) |v| {
                const trimmed = std.mem.trim(u8, v, " \t\r\n");
                if (trimmed.len > 0) value_code = allocator.dupe(u8, trimmed) catch null;
            }
            if (value_code == null and runtime.pushTable(-1, "source")) {
                defer runtime.pop();
                if (runtime.getString(-1, "value")) |v| {
                    const trimmed = std.mem.trim(u8, v, " \t\r\n");
                    if (trimmed.len > 0) value_code = allocator.dupe(u8, trimmed) catch null;
                }
            }
        }
    }
    const kind: SegmentKind = if (has_progress)
        .progress
    else if (has_button)
        .button
    else if (builtin_name != null and value_code == null)
        .builtin
    else
        .value;

    const command: ?[]const u8 = switch (kind) {
        .value => value_code,
        .builtin => null,
        .button, .progress => value_code,
    };

    if (runtime.fieldType(-1, "outputs") != .nil) {
        setParseError(allocator, "config: segment field 'outputs' is removed; return styled blocks from 'value'");
        allocator.free(name);
        if (value_code) |vc| allocator.free(vc);
        return null;
    }

    const has_source = command != null or builtin_name != null;
    if (!has_source) {
        const err_msg = switch (kind) {
            .builtin => "config: builtin segment requires non-empty 'builtin'",
            .value => "config: value segment requires a non-empty 'value'",
            .button => "config: button segment requires 'value' or 'builtin'",
            .progress => "config: progress segment requires 'value' or 'builtin'",
        };
        setParseError(allocator, err_msg);
        allocator.free(name);
        if (builtin_name) |b| allocator.free(@constCast(b));
        if (show_when_code) |s| allocator.free(@constCast(s));
        return null;
    }

    return Segment{
        .name = name,
        .kind = kind,
        .priority = lua_runtime.parseConstrainedInt(runtime, u8, -1, "priority", 1, 255, 50),
        .outputs = parseOutputs(runtime, allocator),
        .command = command,
        .builtin = builtin_name,
        .progress_every_ms = progress_every_ms,
        .progress_show_when = show_when_code,
        .on_click = on_click,
        .on_right_click = on_right_click,
        .on_middle_click = on_middle_click,
        .button_active_bash = button_active_bash,
        .button_left_style = button_left_style,
        .button_middle_style = button_middle_style,
        .button_right_style = button_right_style,
        .inverse_on_hover = inverse_on_hover,
        .when = null,
        .spinner = parseSpinner(runtime, allocator),
        .active_style = runtime.getStringAlloc(-1, "active_style") orelse "bg:1 fg:0",
        .inactive_style = runtime.getStringAlloc(-1, "inactive_style") orelse "bg:237 fg:250",
        .separator = runtime.getStringAlloc(-1, "separator") orelse " | ",
        .separator_style = runtime.getStringAlloc(-1, "separator_style") orelse "fg:7",
        .tab_title = runtime.getStringAlloc(-1, "tab_title") orelse "basename",
        .left_arrow = runtime.getStringAlloc(-1, "left_arrow") orelse "",
        .right_arrow = runtime.getStringAlloc(-1, "right_arrow") orelse "",
    };
}

fn parseSplits(runtime: *LuaRuntime, config: *Config) void {
    if (runtime.pushTable(-1, "color")) {
        if (runtime.getInt(u8, -1, "active")) |v| config.splits.color.active = v;
        if (runtime.getInt(u8, -1, "passive")) |v| config.splits.color.passive = v;
        runtime.pop();
    }

    config.splits.separator_v = lua_runtime.parseUnicodeChar(runtime, -1, "separator_v", config.splits.separator_v);
    config.splits.separator_h = lua_runtime.parseUnicodeChar(runtime, -1, "separator_h", config.splits.separator_h);

    if (runtime.pushTable(-1, "style")) {
        var style = SplitStyle{};
        style.vertical = lua_runtime.parseUnicodeChar(runtime, -1, "vertical", 0x2502);
        style.horizontal = lua_runtime.parseUnicodeChar(runtime, -1, "horizontal", 0x2500);
        style.cross = lua_runtime.parseUnicodeChar(runtime, -1, "cross", 0x253C);
        style.top_t = lua_runtime.parseUnicodeChar(runtime, -1, "top_t", 0x252C);
        style.bottom_t = lua_runtime.parseUnicodeChar(runtime, -1, "bottom_t", 0x2534);
        style.left_t = lua_runtime.parseUnicodeChar(runtime, -1, "left_t", 0x251C);
        style.right_t = lua_runtime.parseUnicodeChar(runtime, -1, "right_t", 0x2524);
        config.splits.style = style;
        runtime.pop();
    }
}

fn parseTabs(runtime: *LuaRuntime, config: *Config, allocator: std.mem.Allocator) void {
    if (runtime.pushTable(-1, "status")) {
        if (runtime.getBool(-1, "enabled")) |v| config.tabs.status.enabled = v;

        if (runtime.pushTable(-1, "left")) {
            config.tabs.status.left = parseSegments(runtime, allocator);
            runtime.pop();
        }
        if (runtime.pushTable(-1, "center")) {
            config.tabs.status.center = parseSegments(runtime, allocator);
            runtime.pop();
        }
        if (runtime.pushTable(-1, "right")) {
            config.tabs.status.right = parseSegments(runtime, allocator);
            runtime.pop();
        }
        runtime.pop();
    }
}

fn parseSegments(runtime: *LuaRuntime, allocator: std.mem.Allocator) []const Segment {
    var list = std.ArrayList(Segment).empty;

    const len = runtime.getArrayLen(-1);
    for (1..len + 1) |i| {
        if (runtime.pushArrayElement(-1, i)) {
            if (parseSegment(runtime, allocator)) |mod| {
                list.append(allocator, mod) catch {};
            }
            runtime.pop();
        }
    }

    return list.toOwnedSlice(allocator) catch &[_]Segment{};
}

fn parseSegment(runtime: *LuaRuntime, allocator: std.mem.Allocator) ?Segment {
    return parseSegmentWithDefaultName(runtime, allocator, null);
}

fn parseSpinner(runtime: *LuaRuntime, allocator: std.mem.Allocator) ?SpinnerDef {
    const ty = runtime.fieldType(-1, "spinner");
    if (ty == .nil) return null;
    if (ty != .table) {
        setParseError(allocator, "config: spinner must be a table");
        return null;
    }
    if (!runtime.pushTable(-1, "spinner")) return null;
    defer runtime.pop();

    var s = SpinnerDef{};
    // Always allocate kind so deinit is safe.
    const kind = runtime.getString(-1, "kind") orelse "knight_rider";
    s.kind = allocator.dupe(u8, kind) catch return null;

    if (runtime.getInt(u8, -1, "width")) |v| s.width = v;
    if (runtime.getInt(u64, -1, "step")) |v| s.step_ms = v;
    if (runtime.getInt(u8, -1, "hold")) |v| s.hold_frames = v;
    if (runtime.getInt(u8, -1, "trail")) |v| s.trail_len = v;
    if (runtime.getInt(u8, -1, "bg")) |v| s.bg_color = v;
    if (runtime.getInt(u8, -1, "placeholder")) |v| s.placeholder_color = v;

    if (runtime.pushTable(-1, "colors")) {
        defer runtime.pop();
        var list = std.ArrayList(u8).empty;
        const len = runtime.getArrayLen(-1);
        for (1..len + 1) |i| {
            if (runtime.pushArrayElement(-1, i)) {
                if (runtime.toIntAt(u8, -1)) |cv| {
                    list.append(allocator, cv) catch {};
                }
                runtime.pop();
            }
        }
        if (list.items.len >= 2) {
            s.colors = list.toOwnedSlice(allocator) catch s.colors;
        }
    }

    return s;
}

/// Parse a 'when' condition using the unified Option C syntax.
///
/// Supported forms:
/// - when = "token"                                   -- single token (implicit all)
/// - when = { all = { "a", "b" } }                    -- AND of tokens
/// - when = { any = { "a", "b" } }                    -- OR of tokens (each as single-token all)
/// - when = { any = { { all = {"a","b"} }, "c" } }    -- OR of conditions
/// - when = { bash = "..." }                          -- bash script
/// - when = { lua = function(ctx) return ... end }     -- lua callback
fn parseWhenTable(runtime: *LuaRuntime, allocator: std.mem.Allocator, allow_hexe: bool) ?WhenDef {
    _ = allow_hexe; // No longer used; tokens are namespace-agnostic
    const ty = runtime.fieldType(-1, "when");
    if (ty == .nil) return null;

    // String shorthand: when = "token" → { all = { "token" } }
    if (ty == .string) {
        if (runtime.getStringAlloc(-1, "when")) |s| {
            const arr = allocator.alloc([]const u8, 1) catch {
                allocator.free(s);
                return null;
            };
            arr[0] = s;
            return .{ .all = arr };
        }
        return null;
    }

    if (ty != .table) {
        setParseError(allocator, "config: 'when' must be a string or table");
        return null;
    }

    if (!runtime.pushTable(-1, "when")) return null;
    defer runtime.pop();

    return parseWhenExpr(runtime, allocator);
}

/// Parse a when expression (the table is already on the stack).
fn parseWhenExpr(runtime: *LuaRuntime, allocator: std.mem.Allocator) ?WhenDef {
    var when: WhenDef = .{};

    // Check for bash/lua script conditions
    when.bash = runtime.getStringAlloc(-1, "bash");
    when.lua = runtime.getStringAlloc(-1, "lua");

    // Check for 'all' key: array of tokens (AND)
    if (runtime.pushTable(-1, "all")) {
        defer runtime.pop();
        when.all = parseTokenArray(runtime, allocator);
    }

    // Check for 'any' key: array of expressions (OR)
    if (runtime.pushTable(-1, "any")) {
        defer runtime.pop();
        when.any = parseAnyArray(runtime, allocator);
    }

    // If nothing was set, return null
    if (when.all == null and when.any == null and when.bash == null and when.lua == null) {
        return null;
    }

    return when;
}

/// Parse an array of string tokens for 'all' clause.
fn parseTokenArray(runtime: *LuaRuntime, allocator: std.mem.Allocator) ?[][]const u8 {
    const len = runtime.getArrayLen(-1);
    if (len == 0) return null;

    var list = std.ArrayList([]const u8).empty;
    for (1..len + 1) |i| {
        if (runtime.pushArrayElement(-1, i)) {
            if (runtime.toStringAt(-1)) |s| {
                const dup = allocator.dupe(u8, s) catch null;
                if (dup) |d| {
                    list.append(allocator, d) catch allocator.free(d);
                }
            }
            runtime.pop();
        }
    }

    if (list.items.len == 0) return null;
    return list.toOwnedSlice(allocator) catch null;
}

/// Parse an array of expressions for 'any' clause.
/// Each element can be:
/// - A string: treated as single-token condition
/// - A table: parsed recursively as WhenDef
fn parseAnyArray(runtime: *LuaRuntime, allocator: std.mem.Allocator) ?[]const WhenDef {
    const len = runtime.getArrayLen(-1);
    if (len == 0) return null;

    var list = std.ArrayList(WhenDef).empty;
    for (1..len + 1) |i| {
        if (!runtime.pushArrayElement(-1, i)) continue;
        defer runtime.pop();

        const elem_ty = runtime.typeOf(-1);
        if (elem_ty == .string) {
            // String element: wrap in single-token all
            if (runtime.toStringAt(-1)) |s| {
                const dup = allocator.dupe(u8, s) catch continue;
                const arr = allocator.alloc([]const u8, 1) catch {
                    allocator.free(dup);
                    continue;
                };
                arr[0] = dup;
                list.append(allocator, .{ .all = arr }) catch {
                    allocator.free(dup);
                    allocator.free(arr);
                };
            }
        } else if (elem_ty == .table) {
            // Table element: parse recursively
            if (parseWhenExpr(runtime, allocator)) |w| {
                list.append(allocator, w) catch {
                    var mw = w;
                    @constCast(&mw).deinit(allocator);
                };
            }
        }
    }

    if (list.items.len == 0) return null;
    return list.toOwnedSlice(allocator) catch null;
}

fn parseOutputs(runtime: *LuaRuntime, allocator: std.mem.Allocator) []const OutputDef {
    if (!runtime.pushTable(-1, "outputs")) {
        return &[_]OutputDef{};
    }
    defer runtime.pop();

    var list = std.ArrayList(OutputDef).empty;

    const len = runtime.getArrayLen(-1);
    for (1..len + 1) |i| {
        if (runtime.pushArrayElement(-1, i)) {
            list.append(allocator, .{
                .style = runtime.getStringAlloc(-1, "style") orelse "",
                .format = runtime.getStringAlloc(-1, "format") orelse "$output",
            }) catch {};
            runtime.pop();
        }
    }

    return list.toOwnedSlice(allocator) catch &[_]OutputDef{};
}

fn parseNotifications(runtime: *LuaRuntime, config: *Config, allocator: std.mem.Allocator) void {
    if (runtime.pushTable(-1, "mux")) {
        parseNotificationStyle(runtime, &config.notifications.mux, allocator);
        runtime.pop();
    }
    if (runtime.pushTable(-1, "pane")) {
        parseNotificationStyle(runtime, &config.notifications.pane, allocator);
        runtime.pop();
    }
}

fn parseNotificationStyle(runtime: *LuaRuntime, style: *NotificationStyleConfig, allocator: std.mem.Allocator) void {
    style.fg = lua_runtime.parseConstrainedInt(runtime, u8, -1, "fg", 0, 255, style.fg);
    style.bg = lua_runtime.parseConstrainedInt(runtime, u8, -1, "bg", 0, 255, style.bg);
    if (runtime.getBool(-1, "bold")) |v| style.bold = v;
    style.padding_x = lua_runtime.parseConstrainedInt(runtime, u8, -1, "padding_x", 0, 10, style.padding_x);
    style.padding_y = lua_runtime.parseConstrainedInt(runtime, u8, -1, "padding_y", 0, 10, style.padding_y);
    style.offset = lua_runtime.parseConstrainedInt(runtime, u8, -1, "offset", 0, 20, style.offset);
    style.duration_ms = lua_runtime.parseConstrainedInt(runtime, u32, -1, "duration_ms", 100, 60000, style.duration_ms);
    if (runtime.getStringAlloc(-1, "alignment")) |v| style.alignment = v else _ = allocator;
}

fn constrainPercent(val: u8, min: u8, max: u8) u8 {
    if (val < min) return min;
    if (val > max) return max;
    return val;
}
