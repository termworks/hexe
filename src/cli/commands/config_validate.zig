const std = @import("std");
const core = @import("core");

const print = std.debug.print;

const LoadedConfig = struct {
    path: []const u8,
    config: core.config.Config,
};

fn loadConfig(allocator: std.mem.Allocator) !LoadedConfig {
    const config_path = try core.lua_runtime.getActiveConfigPath(allocator);
    errdefer allocator.free(config_path);

    std.fs.accessAbsolute(config_path, .{}) catch {
        print("No config file found; expected location: {s}\n", .{config_path});
        return error.FileNotFound;
    };

    var config = core.config.Config.load(allocator);
    if (config.status == .@"error") {
        if (config.status_message) |msg| core.cli_ui.printErr("Config error: {s}", .{msg});
        config.deinit();
        return error.ConfigError;
    }

    return .{
        .path = config_path,
        .config = config,
    };
}

fn unloadConfig(allocator: std.mem.Allocator, loaded: *LoadedConfig) void {
    allocator.free(loaded.path);
    loaded.config.deinit();
}

/// Validate the Hexe configuration file
pub fn run() !void {
    const allocator = std.heap.page_allocator;
    var out = std.fs.File.stdout().deprecatedWriter();
    const p = core.cli_ui.Palette.forStdout();

    var loaded = loadConfig(allocator) catch |err| {
        if (err == error.FileNotFound) {
            const config_path = try core.lua_runtime.getActiveConfigPath(allocator);
            defer allocator.free(config_path);
            try out.print("{s}✓{s} No config file found (using defaults)\n", .{ p.success, p.reset });
            try out.print("  {s}Expected location:{s} {s}\n", .{ p.dim, p.reset, config_path });
            return;
        }
        return err;
    };
    defer unloadConfig(allocator, &loaded);
    const config = loaded.config;

    // Schema check against config_v2: catches wrong types and out-of-range
    // values with the path that caused them, which loading alone cannot.
    if (schemaError(allocator, loaded.path)) |problem| {
        const pe = core.cli_ui.Palette.forStderr();
        print("{s}✗{s} Config invalid: {s}\n", .{ pe.err, pe.reset, loaded.path });
        if (problem.path.len > 0) {
            print("  {s}: {s}\n", .{ problem.path, problem.message });
        } else {
            print("  {s}\n", .{problem.message});
        }
        return error.InvalidConfig;
    }

    // Success!
    const sb_on = config.tabs.status.enabled;
    const notif_on = config.notifications.mux.duration_ms > 0;
    try out.print("{s}✓{s} Config valid: {s}{s}{s}\n", .{ p.success, p.reset, p.bold, loaded.path, p.reset });
    try out.print("  {s}Status bar:{s}    {s}{}{s}\n", .{ p.dim, p.reset, if (sb_on) p.success else p.muted, sb_on, p.reset });
    try out.print("  {s}Keybindings:{s}   {s}{}{s} defined\n", .{ p.dim, p.reset, p.accent, config.input.binds.len, p.reset });
    try out.print("  {s}Notifications:{s} {s}{}{s}\n", .{ p.dim, p.reset, if (notif_on) p.success else p.muted, notif_on, p.reset });
}

/// Strict validation alias used by the new Lua config plan.
pub fn runCheck() !void {
    try run();
}

fn jsonBool(value: bool) []const u8 {
    return if (value) "true" else "false";
}

const SchemaProblem = struct {
    path: []const u8,
    message: []const u8,
};

/// Run the declared schema over the config Lua actually produced.
/// Drop Lua's `[string "..."]:3: ` chunk prefix from an error message.
///
/// The chunk is hexe's own bootstrap, so the location is always the same and
/// tells the user nothing; what follows it is the sentence they need. Left in,
/// it pushed the actual complaint past the width of a terminal.
fn stripChunkPrefix(message: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, message, "[string \"")) return message;
    const close = std.mem.indexOf(u8, message, "\"]:") orelse return message;
    var i = close + 3;
    while (i < message.len and std.ascii.isDigit(message[i])) i += 1;
    if (i + 2 <= message.len and std.mem.startsWith(u8, message[i..], ": ")) return message[i + 2 ..];
    return message;
}

fn schemaError(allocator: std.mem.Allocator, path: []const u8) ?SchemaProblem {
    var runtime = core.LuaRuntime.init(allocator) catch return null;
    defer runtime.deinit();

    runtime.loadConfig(path) catch return null;
    defer runtime.pop();

    var ctx = core.config_v2.ValidationContext{};
    core.config_v2.validateLoaded(&runtime, &ctx) catch {
        // `ctx` owns its own buffer, but it dies with this frame, so copy out.
        // The message too: it used to be a literal in every case, but a
        // `__finish` raise reports Lua's own error text, which the runtime
        // frees on the deferred deinit above -- printing it borrowed showed
        // nothing at all.
        const p = allocator.dupe(u8, ctx.path) catch "";
        const m = allocator.dupe(u8, stripChunkPrefix(ctx.message)) catch "config is invalid";
        return .{ .path = p, .message = m };
    };
    return null;
}

fn summarizeLuaConfig(allocator: std.mem.Allocator, path: []const u8) core.config_v2.LuaShapeSummary {
    var runtime = core.LuaRuntime.init(allocator) catch return .{};
    defer runtime.deinit();

    runtime.loadConfig(path) catch return .{};
    defer runtime.pop();

    return core.config_v2.LuaShapeSummary.fromLoadedRuntime(&runtime);
}

/// Print the normalized config after Lua has run.
pub fn runDump() !void {
    const allocator = std.heap.page_allocator;
    var loaded = try loadConfig(allocator);
    defer unloadConfig(allocator, &loaded);
    var ses = core.SesConfig.load(allocator);
    defer ses.deinit(allocator);

    var out = std.fs.File.stdout().deprecatedWriter();
    const cfg = loaded.config;
    const lua_summary = summarizeLuaConfig(allocator, loaded.path);
    try out.print(
        "{{\n" ++
            "  \"config_path\": \"{s}\",\n" ++
            "  \"lua\": {{\n" ++
            "    \"type\": \"{s}\",\n" ++
            "    \"sections\": {{ \"theme\": {s}, \"keys\": {s}, \"mux\": {s}, \"status\": {s}, \"pop\": {s}, \"ses\": {s} }},\n" ++
            "    \"keys\": {{ \"count\": {} }},\n" ++
            "    \"status\": {{ \"view\": {s} }},\n" ++
            "    \"ses\": {{ \"layouts\": {{ \"count\": {}, \"source\": \"global\" }} }}\n" ++
            "  }},\n" ++
            "  \"theme\": {{ \"present\": {s}, \"colors\": {{ \"count\": {} }}, \"styles\": {{ \"count\": {} }}, \"chars\": {{ \"count\": {} }} }},\n",
        .{
            loaded.path,
            if (lua_summary.is_config) "config" else "unknown",
            jsonBool(lua_summary.has_theme),
            jsonBool(lua_summary.has_keys),
            jsonBool(lua_summary.has_mux),
            jsonBool(lua_summary.has_status),
            jsonBool(lua_summary.has_pop),
            jsonBool(lua_summary.has_ses),
            lua_summary.keys,
            jsonBool(lua_summary.status_view),
            lua_summary.ses_layouts,
            jsonBool(lua_summary.has_theme),
            lua_summary.theme_colors,
            lua_summary.theme_styles,
            lua_summary.theme_chars,
        },
    );
    try out.print(
        "  \"mux\": {{\n" ++
            "    \"confirm\": {{ \"exit\": {s}, \"detach\": {s}, \"disown\": {s}, \"close\": {s} }},\n" ++
            "    \"selection_color\": {},\n" ++
            "    \"mouse\": {{ \"selection_override_mods\": {} }},\n" ++
            "    \"keybindings\": {{ \"count\": {} }},\n" ++
            "    \"floats\": {{ \"match_rules\": {}, \"default_global\": {s}, \"default_sticky\": {s}, \"adhoc_width_percent\": {}, \"adhoc_height_percent\": {} }},\n" ++
            "    \"splits\": {{ \"active_color\": {}, \"passive_color\": {} }},\n" ++
            "    \"status\": {{\n" ++
            "      \"enabled\": {s},\n",
        .{
            jsonBool(cfg.confirm_on_exit),
            jsonBool(cfg.confirm_on_detach),
            jsonBool(cfg.confirm_on_disown),
            jsonBool(cfg.confirm_on_close),
            cfg.selection_color,
            cfg.mouse.selection_override_mods,
            cfg.input.binds.len,
            cfg.float_match_rules.len,
            jsonBool(cfg.float_default_attributes.global),
            jsonBool(cfg.float_default_attributes.sticky),
            cfg.float_adhoc_defaults.width_percent,
            cfg.float_adhoc_defaults.height_percent,
            cfg.splits.color.active,
            cfg.splits.color.passive,
            jsonBool(cfg.tabs.status.enabled),
        },
    );
    try out.print("      \"view\": \"{s}\",\n", .{cfg.tabs.status.view});
    try out.print("      \"refresh_ms\": {}\n", .{cfg.tabs.status.refresh_ms});
    try out.print(
        "    }}\n" ++
            "  }},\n" ++
            "  \"pop\": {{\n" ++
            "    \"notify\": {{ \"mux_duration_ms\": {}, \"pane_duration_ms\": {} }}\n" ++
            "  }},\n" ++
            "  \"ses\": {{ \"layouts\": {{ \"count\": {}, \"source\": \"global+local\" }} }}\n" ++
            "}}\n",
        .{ cfg.notifications.mux.duration_ms, cfg.notifications.pane.duration_ms, ses.layouts.len },
    );
}

/// Print config and Lua module search paths.
pub fn runPaths() !void {
    const allocator = std.heap.page_allocator;
    const config_dir = try core.lua_runtime.getConfigDir(allocator);
    defer allocator.free(config_dir);
    const config_path = try core.lua_runtime.getActiveConfigPath(allocator);
    defer allocator.free(config_path);
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    var out = std.fs.File.stdout().deprecatedWriter();
    const p = core.cli_ui.Palette.forStdout();
    try out.print("{s}config_dir:{s}  {s}\n", .{ p.dim, p.reset, config_dir });
    try out.print("{s}config_file:{s} {s}\n", .{ p.dim, p.reset, config_path });
    try out.print("{s}lua_module_paths:{s}\n", .{ p.dim, p.reset });
    try out.print("  - {s}/lua/?.lua\n", .{config_dir});
    try out.print("  - {s}/lua/?/init.lua\n", .{config_dir});
    try out.print("  - {s}/.hexe/lua/?.lua\n", .{cwd});
    try out.print("  - {s}/.hexe/lua/?/init.lua\n", .{cwd});
}
