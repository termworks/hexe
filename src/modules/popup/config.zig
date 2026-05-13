const std = @import("std");
const core = @import("core");
const lua_runtime = core.lua_runtime;
const LuaRuntime = core.LuaRuntime;
const ConfigStatus = core.ConfigStatus;
const widgets = @import("widgets/mod.zig");

/// Notification style configuration
pub const NotificationStyle = struct {
    fg: u8 = 0, // foreground color (palette index)
    bg: u8 = 3, // background color (palette index)
    bold: bool = true,
    padding_x: u8 = 1, // horizontal padding inside box
    padding_y: u8 = 0, // vertical padding inside box
    offset: u8 = 1, // offset from edge
    alignment: []const u8 = "center", // horizontal alignment: left, center, right
    duration_ms: u32 = 3000,
};

/// Confirm dialog style configuration
pub const ConfirmStyle = struct {
    fg: u8 = 0,
    bg: u8 = 4, // blue
    bold: bool = true,
    padding_x: u8 = 2,
    padding_y: u8 = 1,
    yes_label: []const u8 = "Yes",
    no_label: []const u8 = "No",
};

/// Choose/Picker dialog style configuration
pub const ChooseStyle = struct {
    fg: u8 = 7,
    bg: u8 = 0, // black
    highlight_fg: u8 = 0,
    highlight_bg: u8 = 7,
    bold: bool = false,
    padding_x: u8 = 1,
    padding_y: u8 = 0,
    visible_count: u8 = 10,
};

/// Carrier scope settings (MUX + TAB - same settings)
pub const CarrierConfig = struct {
    notification: NotificationStyle = .{
        .offset = 1,
    },
    confirm: ConfirmStyle = .{},
    choose: ChooseStyle = .{},
};

/// Pane scope settings
pub const PaneConfig = struct {
    notification: NotificationStyle = .{
        .offset = 0,
    },
    confirm: ConfirmStyle = .{},
    choose: ChooseStyle = .{},
};

/// Pop configuration - loaded from ~/.config/hexe/pop.lua
pub const PopConfig = struct {
    carrier: CarrierConfig = .{},
    pane: PaneConfig = .{},
    widgets: widgets.WidgetsConfig = .{},
    status: ConfigStatus = .loaded,
    status_message: ?[]const u8 = null,

    _allocator: ?std.mem.Allocator = null,
    _owned_status_message: ?[]u8 = null,
    _owned_carrier_notification_alignment: ?[]u8 = null,
    _owned_pane_notification_alignment: ?[]u8 = null,
    _owned_carrier_confirm_yes_label: ?[]u8 = null,
    _owned_carrier_confirm_no_label: ?[]u8 = null,
    _owned_pane_confirm_yes_label: ?[]u8 = null,
    _owned_pane_confirm_no_label: ?[]u8 = null,

    pub fn load(allocator: std.mem.Allocator) PopConfig {
        var config = PopConfig{};
        config._allocator = allocator;

        const path = lua_runtime.getConfigPath(allocator, "init.lua") catch return config;
        defer allocator.free(path);

        var runtime = LuaRuntime.init(allocator) catch {
            config.status = .@"error";
            config.setStatusMessage("failed to initialize Lua");
            return config;
        };
        defer runtime.deinit();

        // Load global config
        runtime.loadConfig(path) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    config.status = .missing;
                },
                else => {
                    config.status = .@"error";
                    if (runtime.last_error) |msg| {
                        config.setStatusMessage(msg);
                    }
                },
            }
            return config;
        };

        // Use ConfigBuilder API approach
        if (runtime.getBuilder()) |builder| {
            if (builder.pop) |pop_builder| {
                config.applyBuilder(pop_builder);
            }
        }

        // Pop config return value (if any) from stack
        runtime.pop();

        if (std.posix.getenv("HEXE_SKIP_LOCAL_CONFIG")) |v| {
            if (std.mem.eql(u8, v, "1")) return config;
        }

        // Try to load local .hexe.lua from current directory
        const local_path = allocator.dupe(u8, ".hexe.lua") catch return config;
        defer allocator.free(local_path);

        // Check if local config exists
        std.fs.cwd().access(local_path, .{}) catch {
            // No local config, use global only
            return config;
        };

        // Local config exists, load it and merge/overwrite
        runtime.loadConfig(local_path) catch {
            // Failed to load local config, but global is already loaded
            return config;
        };

        // Use ConfigBuilder API approach for local config (merge/overwrite)
        if (runtime.getBuilder()) |builder| {
            if (builder.pop) |pop_builder| {
                config.applyBuilder(pop_builder);
            }
        }

        // Pop config return value (if any) from stack
        runtime.pop();

        return config;
    }

    pub fn deinit(self: *PopConfig) void {
        const allocator = self._allocator orelse return;

        if (self._owned_status_message) |v| allocator.free(v);
        if (self._owned_carrier_notification_alignment) |v| allocator.free(v);
        if (self._owned_pane_notification_alignment) |v| allocator.free(v);
        if (self._owned_carrier_confirm_yes_label) |v| allocator.free(v);
        if (self._owned_carrier_confirm_no_label) |v| allocator.free(v);
        if (self._owned_pane_confirm_yes_label) |v| allocator.free(v);
        if (self._owned_pane_confirm_no_label) |v| allocator.free(v);

        self._owned_status_message = null;
        self._owned_carrier_notification_alignment = null;
        self._owned_pane_notification_alignment = null;
        self._owned_carrier_confirm_yes_label = null;
        self._owned_carrier_confirm_no_label = null;
        self._owned_pane_confirm_yes_label = null;
        self._owned_pane_confirm_no_label = null;
        self.status_message = null;
    }

    fn applyBuilder(self: *PopConfig, pop_builder: anytype) void {
        // Build carrier notification config
        if (pop_builder.carrier_notification) |notif| {
            if (notif.fg) |v| self.carrier.notification.fg = v;
            if (notif.bg) |v| self.carrier.notification.bg = v;
            if (notif.bold) |v| self.carrier.notification.bold = v;
            if (notif.padding_x) |v| self.carrier.notification.padding_x = v;
            if (notif.padding_y) |v| self.carrier.notification.padding_y = v;
            if (notif.offset) |v| self.carrier.notification.offset = v;
            if (notif.duration_ms) |v| self.carrier.notification.duration_ms = v;
            if (notif.alignment) |a| self.setOwnedStringField(
                &self.carrier.notification.alignment,
                &self._owned_carrier_notification_alignment,
                a,
            );
        }

        // Build pane notification config
        if (pop_builder.pane_notification) |notif| {
            if (notif.fg) |v| self.pane.notification.fg = v;
            if (notif.bg) |v| self.pane.notification.bg = v;
            if (notif.bold) |v| self.pane.notification.bold = v;
            if (notif.padding_x) |v| self.pane.notification.padding_x = v;
            if (notif.padding_y) |v| self.pane.notification.padding_y = v;
            if (notif.offset) |v| self.pane.notification.offset = v;
            if (notif.duration_ms) |v| self.pane.notification.duration_ms = v;
            if (notif.alignment) |a| self.setOwnedStringField(
                &self.pane.notification.alignment,
                &self._owned_pane_notification_alignment,
                a,
            );
        }

        // Build carrier confirm config
        if (pop_builder.carrier_confirm) |conf| {
            if (conf.fg) |v| self.carrier.confirm.fg = v;
            if (conf.bg) |v| self.carrier.confirm.bg = v;
            if (conf.bold) |v| self.carrier.confirm.bold = v;
            if (conf.padding_x) |v| self.carrier.confirm.padding_x = v;
            if (conf.padding_y) |v| self.carrier.confirm.padding_y = v;
            if (conf.yes_label) |y| self.setOwnedStringField(
                &self.carrier.confirm.yes_label,
                &self._owned_carrier_confirm_yes_label,
                y,
            );
            if (conf.no_label) |n| self.setOwnedStringField(
                &self.carrier.confirm.no_label,
                &self._owned_carrier_confirm_no_label,
                n,
            );
        }

        // Build pane confirm config
        if (pop_builder.pane_confirm) |conf| {
            if (conf.fg) |v| self.pane.confirm.fg = v;
            if (conf.bg) |v| self.pane.confirm.bg = v;
            if (conf.bold) |v| self.pane.confirm.bold = v;
            if (conf.padding_x) |v| self.pane.confirm.padding_x = v;
            if (conf.padding_y) |v| self.pane.confirm.padding_y = v;
            if (conf.yes_label) |y| self.setOwnedStringField(
                &self.pane.confirm.yes_label,
                &self._owned_pane_confirm_yes_label,
                y,
            );
            if (conf.no_label) |n| self.setOwnedStringField(
                &self.pane.confirm.no_label,
                &self._owned_pane_confirm_no_label,
                n,
            );
        }

        // Build carrier choose config
        if (pop_builder.carrier_choose) |ch| {
            if (ch.fg) |v| self.carrier.choose.fg = v;
            if (ch.bg) |v| self.carrier.choose.bg = v;
            if (ch.highlight_fg) |v| self.carrier.choose.highlight_fg = v;
            if (ch.highlight_bg) |v| self.carrier.choose.highlight_bg = v;
            if (ch.bold) |v| self.carrier.choose.bold = v;
            if (ch.padding_x) |v| self.carrier.choose.padding_x = v;
            if (ch.padding_y) |v| self.carrier.choose.padding_y = v;
            if (ch.visible_count) |v| self.carrier.choose.visible_count = v;
        }

        // Build pane choose config
        if (pop_builder.pane_choose) |ch| {
            if (ch.fg) |v| self.pane.choose.fg = v;
            if (ch.bg) |v| self.pane.choose.bg = v;
            if (ch.highlight_fg) |v| self.pane.choose.highlight_fg = v;
            if (ch.highlight_bg) |v| self.pane.choose.highlight_bg = v;
            if (ch.bold) |v| self.pane.choose.bold = v;
            if (ch.padding_x) |v| self.pane.choose.padding_x = v;
            if (ch.padding_y) |v| self.pane.choose.padding_y = v;
            if (ch.visible_count) |v| self.pane.choose.visible_count = v;
        }

        // Build widgets config
        if (pop_builder.widgets.pokemon_enabled) |v| self.widgets.pokemon.enabled = v;
        if (pop_builder.widgets.pokemon_position) |p| self.widgets.pokemon.position = parsePosition(p);
        if (pop_builder.widgets.pokemon_shiny_chance) |f| self.widgets.pokemon.shiny_chance = f;
        if (pop_builder.widgets.keycast_enabled) |v| self.widgets.keycast.enabled = v;
        if (pop_builder.widgets.keycast_position) |p| self.widgets.keycast.position = parsePosition(p);
        if (pop_builder.widgets.keycast_duration_ms) |t| self.widgets.keycast.duration_ms = t;
        if (pop_builder.widgets.keycast_max_entries) |m| self.widgets.keycast.max_entries = m;
        if (pop_builder.widgets.keycast_grouping_timeout_ms) |g| self.widgets.keycast.grouping_timeout_ms = g;
        if (pop_builder.widgets.digits_enabled) |v| self.widgets.digits.enabled = v;
        if (pop_builder.widgets.digits_position) |p| self.widgets.digits.position = parsePosition(p);
        if (pop_builder.widgets.digits_size) |s| self.widgets.digits.size = parseDigitSize(s);
    }

    fn setStatusMessage(self: *PopConfig, msg: []const u8) void {
        self.setOwnedOptionalStringField(&self.status_message, &self._owned_status_message, msg);
    }

    fn setOwnedStringField(self: *PopConfig, field: *[]const u8, owned_field: *?[]u8, value: []const u8) void {
        const allocator = self._allocator orelse return;
        const copy = allocator.dupe(u8, value) catch return;

        if (owned_field.*) |prev| allocator.free(prev);
        owned_field.* = copy;
        field.* = copy;
    }

    fn setOwnedOptionalStringField(self: *PopConfig, field: *?[]const u8, owned_field: *?[]u8, value: []const u8) void {
        const allocator = self._allocator orelse return;
        const copy = allocator.dupe(u8, value) catch return;

        if (owned_field.*) |prev| allocator.free(prev);
        owned_field.* = copy;
        field.* = copy;
    }
};

fn parsePosition(pos_str: []const u8) widgets.Position {
    if (std.mem.eql(u8, pos_str, "topleft")) return .topleft;
    if (std.mem.eql(u8, pos_str, "topright")) return .topright;
    if (std.mem.eql(u8, pos_str, "bottomleft")) return .bottomleft;
    if (std.mem.eql(u8, pos_str, "bottomright")) return .bottomright;
    if (std.mem.eql(u8, pos_str, "center")) return .center;
    return .topright; // default
}

fn parseDigitSize(size_str: []const u8) widgets.digits.Size {
    if (std.mem.eql(u8, size_str, "small")) return .small;
    if (std.mem.eql(u8, size_str, "medium")) return .medium;
    if (std.mem.eql(u8, size_str, "large")) return .large;
    return .small; // default
}
