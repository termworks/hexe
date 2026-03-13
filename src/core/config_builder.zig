const std = @import("std");
const config = @import("config.zig");

/// ConfigBuilder accumulates configuration from Lua API calls
/// and builds the final Config structs for all sections (mux, ses, shp, pop)
pub const ConfigBuilder = struct {
    allocator: std.mem.Allocator,

    // Section builders
    mux: ?*MuxConfigBuilder = null,
    ses: ?*SesConfigBuilder = null,
    shp: ?*ShpConfigBuilder = null,
    pop: ?*PopConfigBuilder = null,

    pub fn init(allocator: std.mem.Allocator) !ConfigBuilder {
        return ConfigBuilder{
            .allocator = allocator,
            .mux = null,
            .ses = null,
            .shp = null,
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
        if (self.shp) |shp| {
            shp.deinit();
            self.allocator.destroy(shp);
        }
        if (self.pop) |pop_builder| {
            pop_builder.deinit();
            self.allocator.destroy(pop_builder);
        }
    }

    /// Build final Config from accumulated state
    pub fn build(self: *ConfigBuilder) !config.Config {
        var result = config.Config{};
        result._allocator = self.allocator;

        // TODO: Build config from section builders

        return result;
    }
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
    mouse_selection_override_mods: ?u8 = null,

    // Keybindings
    binds: std.ArrayList(config.Config.Bind),

    // Floats
    float_defaults: ?FloatVisualConfig = null,
    float_adhoc: ?FloatVisualConfig = null,
    float_matches: std.ArrayList(FloatMatchRule),
    floats: std.ArrayList(config.FloatDef),

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
        segments_left: std.ArrayList(config.Segment),
        segments_center: std.ArrayList(config.Segment),
        segments_right: std.ArrayList(config.Segment),
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
            .floats = .{},
            .tabs_config = .{
                .segments_left = .{},
                .segments_center = .{},
                .segments_right = .{},
            },
            .splits_config = .{},
        };
        return self;
    }

    pub fn deinit(self: *MuxConfigBuilder) void {
        if (self.float_defaults) |*defaults| defaults.deinit(self.allocator);
        if (self.float_adhoc) |*adhoc| adhoc.deinit(self.allocator);
        if (self.float_matches.items.len > 0) {
            for (self.float_matches.items) |*rule| {
                rule.deinit(self.allocator);
            }
        }
        self.float_matches.deinit(self.allocator);
        self.binds.deinit(self.allocator);
        self.floats.deinit(self.allocator);
        self.tabs_config.segments_left.deinit(self.allocator);
        self.tabs_config.segments_center.deinit(self.allocator);
        self.tabs_config.segments_right.deinit(self.allocator);
    }

    /// Helper: Deep copy a Bind to prevent use-after-free
    fn duplicateBind(bind: config.Config.Bind, allocator: std.mem.Allocator) !config.Config.Bind {
        var result = bind;

        // Deep copy when condition if present
        if (bind.when) |w| {
            result.when = try duplicateWhenDef(w, allocator);
        }

        return result;
    }

    /// Helper: Deep copy a FloatStyle to prevent use-after-free
    fn duplicateFloatStyle(style: config.FloatStyle, allocator: std.mem.Allocator) !config.FloatStyle {
        var result = style;

        // Deep copy module segment if present
        if (style.module) |mod| {
            result.module = try duplicateSegment(mod, allocator);
        }

        if (style.title_segments.len > 0) {
            const title_segments = try allocator.alloc(config.Segment, style.title_segments.len);
            for (style.title_segments, 0..) |seg, i| {
                title_segments[i] = try duplicateSegment(seg, allocator);
            }
            result.title_segments = title_segments;
        }

        return result;
    }

    /// Helper: Deep copy a WhenDef to prevent use-after-free
    fn duplicateWhenDef(when: config.WhenDef, allocator: std.mem.Allocator) !config.WhenDef {
        var result: config.WhenDef = .{};

        // Duplicate bash/lua/env strings
        if (when.bash) |s| result.bash = try allocator.dupe(u8, s);
        if (when.lua) |s| result.lua = try allocator.dupe(u8, s);
        if (when.env) |s| result.env = try allocator.dupe(u8, s);
        if (when.env_not) |s| result.env_not = try allocator.dupe(u8, s);

        // Duplicate 'all' array of strings
        if (when.all) |all_arr| {
            var new_all = try allocator.alloc([]const u8, all_arr.len);
            for (all_arr, 0..) |s, i| {
                new_all[i] = try allocator.dupe(u8, s);
            }
            result.all = new_all;
        }

        // Duplicate 'any' array of WhenDef (recursive)
        if (when.any) |any_arr| {
            var new_any = try allocator.alloc(config.WhenDef, any_arr.len);
            for (any_arr, 0..) |w, i| {
                new_any[i] = try duplicateWhenDef(w, allocator);
            }
            result.any = new_any;
        }

        return result;
    }

    /// Helper: Deep copy a SpinnerDef to prevent use-after-free
    fn duplicateSpinnerDef(spinner: config.SpinnerDef, allocator: std.mem.Allocator) !config.SpinnerDef {
        var result = spinner;

        // Duplicate kind string
        result.kind = try allocator.dupe(u8, spinner.kind);

        // Duplicate colors array
        if (spinner.colors.len > 0) {
            result.colors = try allocator.dupe(u8, spinner.colors);
        }

        return result;
    }

    /// Helper: Duplicate a segment's strings to prevent use-after-free
    fn duplicateSegment(segment: config.Segment, allocator: std.mem.Allocator) !config.Segment {
        var result = segment;

        // Duplicate string fields
        result.name = try allocator.dupe(u8, segment.name);
        if (segment.command) |cmd| {
            result.command = try allocator.dupe(u8, cmd);
        }
        if (segment.on_click) |cmd| {
            result.on_click = try allocator.dupe(u8, cmd);
        }
        if (segment.on_right_click) |cmd| {
            result.on_right_click = try allocator.dupe(u8, cmd);
        }
        if (segment.on_middle_click) |cmd| {
            result.on_middle_click = try allocator.dupe(u8, cmd);
        }
        if (segment.button_active_bash) |cmd| {
            result.button_active_bash = try allocator.dupe(u8, cmd);
        }
        if (segment.button_left_style) |s| {
            result.button_left_style = try allocator.dupe(u8, s);
        }
        if (segment.button_middle_style) |s| {
            result.button_middle_style = try allocator.dupe(u8, s);
        }
        if (segment.button_right_style) |s| {
            result.button_right_style = try allocator.dupe(u8, s);
        }
        result.active_style = try allocator.dupe(u8, segment.active_style);
        result.inactive_style = try allocator.dupe(u8, segment.inactive_style);
        result.separator = try allocator.dupe(u8, segment.separator);
        result.separator_style = try allocator.dupe(u8, segment.separator_style);
        result.tab_title = try allocator.dupe(u8, segment.tab_title);
        result.left_arrow = try allocator.dupe(u8, segment.left_arrow);
        result.right_arrow = try allocator.dupe(u8, segment.right_arrow);

        // Duplicate outputs array
        if (segment.outputs.len > 0) {
            var outputs = try allocator.alloc(config.OutputDef, segment.outputs.len);
            for (segment.outputs, 0..) |out, i| {
                outputs[i] = .{
                    .style = try allocator.dupe(u8, out.style),
                    .format = try allocator.dupe(u8, out.format),
                };
            }
            result.outputs = outputs;
        }

        // Deep copy when condition
        if (segment.when) |w| {
            result.when = try duplicateWhenDef(w, allocator);
        }

        // Deep copy spinner
        if (segment.spinner) |s| {
            result.spinner = try duplicateSpinnerDef(s, allocator);
        }

        return result;
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

        // Apply tabs config - duplicate segments to prevent use-after-free
        if (self.tabs_config.status_enabled) |v| result.tabs.status.enabled = v;
        if (self.tabs_config.segments_left.items.len > 0) {
            var left = try self.allocator.alloc(config.Segment, self.tabs_config.segments_left.items.len);
            for (self.tabs_config.segments_left.items, 0..) |seg, i| {
                left[i] = try duplicateSegment(seg, self.allocator);
            }
            result.tabs.status.left = left;
        }
        if (self.tabs_config.segments_center.items.len > 0) {
            var center = try self.allocator.alloc(config.Segment, self.tabs_config.segments_center.items.len);
            for (self.tabs_config.segments_center.items, 0..) |seg, i| {
                center[i] = try duplicateSegment(seg, self.allocator);
            }
            result.tabs.status.center = center;
        }
        if (self.tabs_config.segments_right.items.len > 0) {
            var right = try self.allocator.alloc(config.Segment, self.tabs_config.segments_right.items.len);
            for (self.tabs_config.segments_right.items, 0..) |seg, i| {
                right[i] = try duplicateSegment(seg, self.allocator);
            }
            result.tabs.status.right = right;
        }

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

/// SHP section builder - accumulates shell prompt configuration
pub const ShpConfigBuilder = struct {
    allocator: std.mem.Allocator,

    // Prompt segments
    left_segments: std.ArrayList(SegmentDef),
    right_segments: std.ArrayList(SegmentDef),

    // Temporary struct for prompt segments (similar to config.Segment but for SHP)
    pub const SegmentDef = struct {
        name: []const u8,
        kind: config.SegmentKind = .value,
        priority: i64,
        outputs: []const OutputDef,
        command: ?[]const u8,
        builtin: ?[]const u8 = null,
        progress_every_ms: u64 = 1000,
        progress_show_when: ?[]const u8 = null,
        inverse_on_hover: bool = true,
        when: ?config.WhenDef,
    };

    pub const OutputDef = struct {
        style: []const u8,
        format: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) !*ShpConfigBuilder {
        const self = try allocator.create(ShpConfigBuilder);
        self.* = .{
            .allocator = allocator,
            .left_segments = .{},
            .right_segments = .{},
        };
        return self;
    }

    pub fn deinit(self: *ShpConfigBuilder) void {
        // Clean up segments
        for (self.left_segments.items) |seg| {
            self.allocator.free(seg.name);
            if (seg.command) |cmd| self.allocator.free(cmd);
            if (seg.builtin) |b| self.allocator.free(b);
            if (seg.progress_show_when) |s| self.allocator.free(s);
            for (seg.outputs) |out| {
                self.allocator.free(out.style);
                self.allocator.free(out.format);
            }
            self.allocator.free(seg.outputs);
        }
        for (self.right_segments.items) |seg| {
            self.allocator.free(seg.name);
            if (seg.command) |cmd| self.allocator.free(cmd);
            if (seg.builtin) |b| self.allocator.free(b);
            if (seg.progress_show_when) |s| self.allocator.free(s);
            for (seg.outputs) |out| {
                self.allocator.free(out.style);
                self.allocator.free(out.format);
            }
            self.allocator.free(seg.outputs);
        }
        self.left_segments.deinit(self.allocator);
        self.right_segments.deinit(self.allocator);
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
