const std = @import("std");
const config = @import("config.zig");

/// ConfigBuilder accumulates configuration from Lua API calls
/// and builds the final Config structs for all sections (mux, ses, pop)
pub const ConfigBuilder = struct {
    allocator: std.mem.Allocator,

    // Section builders
    mux: ?*MuxConfigBuilder = null,
    ses: ?*SesConfigBuilder = null,
    pop: ?*PopConfigBuilder = null,

    pub fn init(allocator: std.mem.Allocator) !ConfigBuilder {
        return ConfigBuilder{
            .allocator = allocator,
            .mux = null,
            .ses = null,
            .pop = null,
        };
    }

    pub fn deinit(self: *ConfigBuilder) void {
        if (self.mux) |mux| {
            mux.deinit();
            self.allocator.destroy(mux);
        }
        if (self.ses) |ses| {
            ses.deinit();
            self.allocator.destroy(ses);
        }
        if (self.pop) |pop_builder| {
            pop_builder.deinit();
            self.allocator.destroy(pop_builder);
        }
    }

    // Note: there is no top-level `build()` because each section is consumed
    // independently — `MuxConfigBuilder.build()` by the mux config loader,
    // `SesConfigBuilder.build()` by the ses config loader, and the pop
    // builder is read field-by-field by its loader. Callers
    // that need a section's final config should reach through the specific
    // section builder.
};

/// MUX section builder - accumulates mux configuration
pub const MuxConfigBuilder = struct {
    allocator: std.mem.Allocator,

    // Options
    confirm_on_exit: ?bool = null,
    confirm_on_detach: ?bool = null,
    confirm_on_disown: ?bool = null,
    confirm_on_close: ?bool = null,
    selection_color: ?u8 = null,
    palette_namespaces: ?bool = null,
    palette_osc: ?u32 = null,

    // Name dictionaries. Owned here and handed to the built Config, which
    // outlives the builder.
    names_session: ?[][]const u8 = null,
    names_pane: ?[][]const u8 = null,
    names_order: ?config.names_mod.Order = null,
    names_suffix: ?[]const u8 = null,

    /// Helper programs the session starts alongside itself, in declared order.
    plugins: std.ArrayList(config.PluginDef) = .empty,

    // Decoration slots around every pane.
    decor: ?config.DecorConfig = null,
    mouse_selection_override_mods: ?u8 = null,

    // Keybindings
    binds: std.ArrayList(config.Config.Bind),

    // Floats
    float_defaults: ?FloatVisualConfig = null,
    float_adhoc: ?FloatVisualConfig = null,
    float_matches: std.ArrayList(FloatMatchRule),
    // Tabs
    tabs_config: TabsConfig,

    // Splits
    splits_config: SplitsConfig,

    pub const FloatVisualConfig = struct {
        width_percent: ?u8 = null,
        height_percent: ?u8 = null,
        padding_x: ?u8 = null,
        padding_y: ?u8 = null,
        color: ?config.BorderColor = null,
        style: ?config.FloatStyle = null,
        attributes: ?config.FloatAttributes = null,

        pub fn deinit(self: *FloatVisualConfig, allocator: std.mem.Allocator) void {
            if (self.style) |*style| {
                var copy = @constCast(style);
                copy.deinit(allocator);
            }
            self.* = .{};
        }
    };

    pub const FloatMatchRule = struct {
        pattern: []const u8,
        visual: FloatVisualConfig = .{},

        pub fn deinit(self: *FloatMatchRule, allocator: std.mem.Allocator) void {
            allocator.free(@constCast(self.pattern));
            self.visual.deinit(allocator);
            self.* = undefined;
        }
    };

    const TabsConfig = struct {
        status_enabled: ?bool = null,
        status_view: ?[]const u8 = null,
        status_zone_left: ?[]const u8 = null,
        status_zone_center: ?[]const u8 = null,
        status_zone_right: ?[]const u8 = null,
        status_shrink: ?[3]u8 = null,
        status_exec: ?[]const u8 = null,
        status_refresh_ms: ?u64 = null,
        status_stale_ms: ?u64 = null,
        status_float_title_view: ?[]const u8 = null,
        status_container_title_view: ?[]const u8 = null,
        status_sprite_view: ?[]const u8 = null,
    };

    const SplitsConfig = struct {
        color: ?config.BorderColor = null,
        separator_v: ?u21 = null,
        separator_h: ?u21 = null,
        style: ?config.SplitStyle = null,
    };

    pub fn init(allocator: std.mem.Allocator) !*MuxConfigBuilder {
        const self = try allocator.create(MuxConfigBuilder);
        self.* = .{
            .allocator = allocator,
            .binds = .{},
            .float_matches = .{},
            .tabs_config = .{},
            .splits_config = .{},
        };
        return self;
    }

    pub fn deinit(self: *MuxConfigBuilder) void {
        for (self.plugins.items) |*plugin| {
            var p = plugin.*;
            p.deinit(self.allocator);
        }
        self.plugins.deinit(self.allocator);
        if (self.float_defaults) |*defaults| defaults.deinit(self.allocator);
        if (self.float_adhoc) |*adhoc| adhoc.deinit(self.allocator);
        if (self.float_matches.items.len > 0) {
            for (self.float_matches.items) |*rule| {
                rule.deinit(self.allocator);
            }
        }
        self.float_matches.deinit(self.allocator);
        // A bind owns its callback reference strings -- `build()` deep-copies
        // them, so these are the builder's own and nothing else frees them.
        for (self.binds.items) |bind| {
            if (bind.when) |code| self.allocator.free(code);
            if (bind.action == .lua) self.allocator.free(bind.action.lua);
        }
        self.binds.deinit(self.allocator);
    }

    /// Helper: Deep copy a Bind to prevent use-after-free
    fn duplicateBind(bind: config.Config.Bind, allocator: std.mem.Allocator) !config.Config.Bind {
        var result = bind;

        // The condition is now just the callback reference string.
        if (bind.when) |code| {
            result.when = try allocator.dupe(u8, code);
        }
        // A Lua action carries an owned reference of the same kind.
        if (bind.action == .lua) {
            result.action = .{ .lua = try allocator.dupe(u8, bind.action.lua) };
        }

        return result;
    }

    /// Helper: Deep copy a FloatStyle. Nothing in it is heap-owned any more --
    /// the title's content comes from the painter -- so this is a plain copy.
    fn duplicateFloatStyle(style: config.FloatStyle, allocator: std.mem.Allocator) !config.FloatStyle {
        _ = allocator;
        return style;
    }

    /// Record one plugin. Strings are copied: the Lua values they came from are
    /// collected as soon as the config chunk is done with them.
    pub fn appendPluginWithAccess(
        self: *MuxConfigBuilder,
        name: []const u8,
        command: []const u8,
        access: config.access_mod.Set,
    ) !void {
        try self.appendPlugin(name, command);
        self.plugins.items[self.plugins.items.len - 1].access = access;
    }

    /// A plugin that came from an installed package, so it knows its own home.
    pub fn appendPackagePlugin(
        self: *MuxConfigBuilder,
        name: []const u8,
        command: []const u8,
        dir: []const u8,
        access: config.access_mod.Set,
    ) !void {
        try self.appendPluginWithAccess(name, command, access);
        self.plugins.items[self.plugins.items.len - 1].dir = try self.allocator.dupe(u8, dir);
    }

    pub fn appendPlugin(self: *MuxConfigBuilder, name: []const u8, command: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_cmd = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(owned_cmd);
        try self.plugins.append(self.allocator, .{ .name = owned_name, .command = owned_cmd });
    }

    pub fn build(self: *MuxConfigBuilder) !config.Config {
        var result = config.Config{};
        result._allocator = self.allocator;

        // Apply options
        if (self.confirm_on_exit) |v| result.confirm_on_exit = v;
        if (self.confirm_on_detach) |v| result.confirm_on_detach = v;
        if (self.confirm_on_disown) |v| result.confirm_on_disown = v;
        if (self.confirm_on_close) |v| result.confirm_on_close = v;
        if (self.selection_color) |v| result.selection_color = v;
        if (self.palette_namespaces) |v| result.palette_namespaces = v;
        if (self.palette_osc) |v| result.palette_osc = v;
        if (self.names_session) |v| result.names.session = v;
        if (self.names_pane) |v| result.names.pane = v;
        if (self.names_order) |v| result.names.order = v;
        if (self.names_suffix) |v| result.names.suffix = try self.allocator.dupe(u8, v);

        // Ownership moves to the Config, which frees them.
        if (self.plugins.items.len > 0) {
            result.plugins = try self.plugins.toOwnedSlice(self.allocator);
        }
        if (self.decor) |d| result.decor = d;
        if (self.mouse_selection_override_mods) |v| result.mouse.selection_override_mods = v;

        // Apply binds (deep copy to prevent use-after-free)
        if (self.binds.items.len > 0) {
            var binds = try self.allocator.alloc(config.Config.Bind, self.binds.items.len);
            for (self.binds.items, 0..) |bind, i| {
                binds[i] = try duplicateBind(bind, self.allocator);
            }
            result.input.binds = binds;
        }

        // Apply float defaults
        if (self.float_defaults) |defaults| {
            if (defaults.width_percent) |v| result.float_named_defaults.width_percent = v;
            if (defaults.height_percent) |v| result.float_named_defaults.height_percent = v;
            if (defaults.padding_x) |v| result.float_named_defaults.padding_x = v;
            if (defaults.padding_y) |v| result.float_named_defaults.padding_y = v;
            if (defaults.color) |v| result.float_named_defaults.color = v;
            if (defaults.style) |s| result.float_named_defaults.style = try duplicateFloatStyle(s, self.allocator);
            if (defaults.attributes) |v| result.float_default_attributes = v;
        }

        if (self.float_adhoc) |defaults| {
            if (defaults.width_percent) |v| result.float_adhoc_defaults.width_percent = v;
            if (defaults.height_percent) |v| result.float_adhoc_defaults.height_percent = v;
            if (defaults.padding_x) |v| result.float_adhoc_defaults.padding_x = v;
            if (defaults.padding_y) |v| result.float_adhoc_defaults.padding_y = v;
            if (defaults.color) |v| result.float_adhoc_defaults.color = v;
            if (defaults.style) |s| result.float_adhoc_defaults.style = try duplicateFloatStyle(s, self.allocator);
        }

        if (self.float_matches.items.len > 0) {
            const rules = try self.allocator.alloc(config.FloatMatchRule, self.float_matches.items.len);
            for (self.float_matches.items, 0..) |rule, i| {
                rules[i] = .{
                    .pattern = try self.allocator.dupe(u8, rule.pattern),
                    .visual = .{},
                };
                if (rule.visual.width_percent) |v| rules[i].visual.width_percent = v;
                if (rule.visual.height_percent) |v| rules[i].visual.height_percent = v;
                if (rule.visual.padding_x) |v| rules[i].visual.padding_x = v;
                if (rule.visual.padding_y) |v| rules[i].visual.padding_y = v;
                if (rule.visual.color) |v| rules[i].visual.color = v;
                if (rule.visual.style) |s| rules[i].visual.style = try duplicateFloatStyle(s, self.allocator);
            }
            result.float_match_rules = rules;
        }

        // Apply tabs config
        if (self.tabs_config.status_enabled) |v| result.tabs.status.enabled = v;
        if (self.tabs_config.status_view) |v| result.tabs.status.view = try self.allocator.dupe(u8, v);
        if (self.tabs_config.status_zone_left) |v| result.tabs.status.zone_left = try self.allocator.dupe(u8, v);
        if (self.tabs_config.status_zone_center) |v| result.tabs.status.zone_center = try self.allocator.dupe(u8, v);
        if (self.tabs_config.status_zone_right) |v| result.tabs.status.zone_right = try self.allocator.dupe(u8, v);
        if (self.tabs_config.status_shrink) |v| result.tabs.status.shrink = v;
        if (self.tabs_config.status_exec) |v| result.tabs.status.exec = try self.allocator.dupe(u8, v);
        if (self.tabs_config.status_refresh_ms) |v| result.tabs.status.refresh_ms = v;
        if (self.tabs_config.status_stale_ms) |v| result.tabs.status.stale_ms = v;
        if (self.tabs_config.status_float_title_view) |v| result.tabs.status.float_title_view = try self.allocator.dupe(u8, v);
        if (self.tabs_config.status_container_title_view) |v| result.tabs.status.container_title_view = try self.allocator.dupe(u8, v);
        if (self.tabs_config.status_sprite_view) |v| result.tabs.status.sprite_view = try self.allocator.dupe(u8, v);
        // Apply splits config
        if (self.splits_config.color) |v| result.splits.color = v;
        if (self.splits_config.separator_v) |v| result.splits.separator_v = v;
        if (self.splits_config.separator_h) |v| result.splits.separator_h = v;
        if (self.splits_config.style) |v| result.splits.style = v;

        return result;
    }
};

/// SES section builder - accumulates session/layout configuration
pub const SesConfigBuilder = struct {
    allocator: std.mem.Allocator,

    // Layouts
    layouts: std.ArrayList(config.LayoutDef),

    // Session config (for future use - not in current config.zig)
    auto_restore: ?bool = null,
    save_on_detach: ?bool = null,

    // Isolation config (libvoid)
    isolation_profile: ?[]const u8 = null,
    isolation_memory: ?[]const u8 = null,
    isolation_cpu: ?[]const u8 = null,
    isolation_pids: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) !*SesConfigBuilder {
        const self = try allocator.create(SesConfigBuilder);
        self.* = .{
            .allocator = allocator,
            .layouts = .{},
        };
        return self;
    }

    pub fn deinit(self: *SesConfigBuilder) void {
        // Clean up layouts
        for (self.layouts.items) |*layout| {
            var l = @constCast(layout);
            l.deinit(self.allocator);
        }
        self.layouts.deinit(self.allocator);

        // Clean up isolation strings
        if (self.isolation_profile) |p| self.allocator.free(p);
        if (self.isolation_memory) |m| self.allocator.free(m);
        if (self.isolation_cpu) |c| self.allocator.free(c);
        if (self.isolation_pids) |p| self.allocator.free(p);
    }

    pub fn build(self: *SesConfigBuilder) !config.SesConfig {
        var result = config.SesConfig{};

        // Transfer layouts
        if (self.layouts.items.len > 0) {
            result.layouts = try self.layouts.toOwnedSlice(self.allocator);
        }

        // Build isolation config
        result.isolation = .{
            .profile = if (self.isolation_profile) |p|
                try self.allocator.dupe(u8, p)
            else
                try self.allocator.dupe(u8, "default"),
            .memory = if (self.isolation_memory) |m| try self.allocator.dupe(u8, m) else null,
            .cpu = if (self.isolation_cpu) |c| try self.allocator.dupe(u8, c) else null,
            .pids = if (self.isolation_pids) |p| try self.allocator.dupe(u8, p) else null,
        };

        return result;
    }
};

/// POP section builder - accumulates popup/overlay configuration
pub const PopConfigBuilder = struct {
    allocator: std.mem.Allocator,

    // Notification styles (carrier = mux realm, pane = pane realm)
    carrier_notification: ?NotificationStyleDef = null,
    pane_notification: ?NotificationStyleDef = null,

    // Dialog styles
    carrier_confirm: ?ConfirmStyleDef = null,
    pane_confirm: ?ConfirmStyleDef = null,
    carrier_choose: ?ChooseStyleDef = null,
    pane_choose: ?ChooseStyleDef = null,

    // Widgets config
    widgets: WidgetsConfigDef,

    pub const NotificationStyleDef = struct {
        fg: ?u8 = null,
        bg: ?u8 = null,
        bold: ?bool = null,
        padding_x: ?u8 = null,
        padding_y: ?u8 = null,
        offset: ?u8 = null,
        alignment: ?[]const u8 = null,
        duration_ms: ?u32 = null,
    };

    pub const ConfirmStyleDef = struct {
        fg: ?u8 = null,
        bg: ?u8 = null,
        bold: ?bool = null,
        padding_x: ?u8 = null,
        padding_y: ?u8 = null,
        yes_label: ?[]const u8 = null,
        no_label: ?[]const u8 = null,
    };

    pub const ChooseStyleDef = struct {
        fg: ?u8 = null,
        bg: ?u8 = null,
        highlight_fg: ?u8 = null,
        highlight_bg: ?u8 = null,
        bold: ?bool = null,
        padding_x: ?u8 = null,
        padding_y: ?u8 = null,
        visible_count: ?u8 = null,
    };

    const WidgetsConfigDef = struct {
        pokemon_enabled: ?bool = null,
        pokemon_position: ?[]const u8 = null,
        pokemon_shiny_chance: ?f32 = null,

        keycast_enabled: ?bool = null,
        keycast_position: ?[]const u8 = null,
        keycast_duration_ms: ?i64 = null,
        keycast_max_entries: ?u8 = null,
        keycast_grouping_timeout_ms: ?i64 = null,

        digits_enabled: ?bool = null,
        digits_position: ?[]const u8 = null,
        digits_size: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator) !*PopConfigBuilder {
        const self = try allocator.create(PopConfigBuilder);
        self.* = .{
            .allocator = allocator,
            .widgets = .{},
        };
        return self;
    }

    pub fn deinit(self: *PopConfigBuilder) void {
        // Clean up allocated strings if any
        if (self.carrier_notification) |*notif| {
            if (notif.alignment) |a| self.allocator.free(a);
        }
        if (self.pane_notification) |*notif| {
            if (notif.alignment) |a| self.allocator.free(a);
        }
        if (self.carrier_confirm) |*conf| {
            if (conf.yes_label) |y| self.allocator.free(y);
            if (conf.no_label) |n| self.allocator.free(n);
        }
        if (self.pane_confirm) |*conf| {
            if (conf.yes_label) |y| self.allocator.free(y);
            if (conf.no_label) |n| self.allocator.free(n);
        }
        // Widget strings cleanup
        if (self.widgets.pokemon_position) |p| self.allocator.free(p);
        if (self.widgets.keycast_position) |p| self.allocator.free(p);
        if (self.widgets.digits_position) |p| self.allocator.free(p);
        if (self.widgets.digits_size) |s| self.allocator.free(s);
    }
};
