const std = @import("std");
const core = @import("core");

const print = std.debug.print;

const LoadedConfig = struct {
    path: []const u8,
    config: core.config.Config,
};

fn loadConfig(allocator: std.mem.Allocator) !LoadedConfig {
    const config_path = try core.lua_runtime.getConfigPath(allocator, "init.lua");
    errdefer allocator.free(config_path);

    std.fs.accessAbsolute(config_path, .{}) catch {
        print("No config file found; expected location: {s}\n", .{config_path});
        return error.FileNotFound;
    };

    var config = core.config.Config.load(allocator);
    if (config.status == .@"error") {
        if (config.status_message) |msg| print("Config error: {s}\n", .{msg});
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
    var loaded = loadConfig(allocator) catch |err| {
        if (err == error.FileNotFound) {
            const config_path = try core.lua_runtime.getConfigPath(allocator, "init.lua");
            defer allocator.free(config_path);
            print("✓ No config file found (using defaults)\n", .{});
            print("  Expected location: {s}\n", .{config_path});
            return;
        }
        return err;
    };
    defer unloadConfig(allocator, &loaded);
    const config = loaded.config;

    // Success!
    print("✓ Config valid: {s}\n", .{loaded.path});
    print("\nConfiguration loaded successfully:\n", .{});

    // Show some config highlights
    print("  - Status bar enabled: {}\n", .{config.tabs.status.enabled});
    print("  - Keybindings: {} defined\n", .{config.input.binds.len});
    print("  - Notifications enabled: {}\n", .{config.notifications.mux.duration_ms > 0});

    print("\n✓ All checks passed\n", .{});
}

/// Strict validation alias used by the new Lua config plan.
pub fn runCheck() !void {
    try run();
}

fn jsonBool(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn dumpSegmentList(name: []const u8, len: usize, trailing_comma: bool) void {
    print("      \"{s}\": {{ \"count\": {} }}{s}\n", .{ name, len, if (trailing_comma) "," else "" });
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

    const cfg = loaded.config;
    const lua_summary = summarizeLuaConfig(allocator, loaded.path);
    print(
        "{{\n" ++
            "  \"config_path\": \"{s}\",\n" ++
            "  \"lua\": {{\n" ++
            "    \"type\": \"{s}\",\n" ++
            "    \"sections\": {{ \"theme\": {s}, \"keys\": {s}, \"mux\": {s}, \"status\": {s}, \"prompt\": {s}, \"pop\": {s}, \"ses\": {s} }},\n" ++
            "    \"keys\": {{ \"count\": {} }},\n" ++
            "    \"status\": {{ \"left\": {{ \"count\": {} }}, \"center\": {{ \"count\": {} }}, \"right\": {{ \"count\": {} }} }},\n" ++
            "    \"prompt\": {{ \"left\": {{ \"count\": {} }}, \"right\": {{ \"count\": {} }} }},\n" ++
            "    \"ses\": {{ \"layouts\": {{ \"count\": {}, \"source\": \"global\" }} }}\n" ++
            "  }},\n" ++
            "  \"theme\": {{ \"present\": {s}, \"colors\": {{ \"count\": {} }}, \"styles\": {{ \"count\": {} }}, \"chars\": {{ \"count\": {} }} }},\n" ++
            "  \"prompt\": {{ \"present\": {s}, \"left\": {{ \"count\": {} }}, \"right\": {{ \"count\": {} }} }},\n",
        .{
            loaded.path,
            if (lua_summary.is_config) "config" else "unknown",
            jsonBool(lua_summary.has_theme),
            jsonBool(lua_summary.has_keys),
            jsonBool(lua_summary.has_mux),
            jsonBool(lua_summary.has_status),
            jsonBool(lua_summary.has_prompt),
            jsonBool(lua_summary.has_pop),
            jsonBool(lua_summary.has_ses),
            lua_summary.keys,
            lua_summary.status_left,
            lua_summary.status_center,
            lua_summary.status_right,
            lua_summary.prompt_left,
            lua_summary.prompt_right,
            lua_summary.ses_layouts,
            jsonBool(lua_summary.has_theme),
            lua_summary.theme_colors,
            lua_summary.theme_styles,
            lua_summary.theme_chars,
            jsonBool(lua_summary.has_prompt),
            lua_summary.prompt_left,
            lua_summary.prompt_right,
        },
    );
    print(
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
    dumpSegmentList("left", cfg.tabs.status.left.len, true);
    dumpSegmentList("center", cfg.tabs.status.center.len, true);
    dumpSegmentList("right", cfg.tabs.status.right.len, false);
    print(
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
    const config_path = try core.lua_runtime.getConfigPath(allocator, "init.lua");
    defer allocator.free(config_path);
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    print("config_dir: {s}\n", .{config_dir});
    print("config_file: {s}\n", .{config_path});
    print("lua_module_paths:\n", .{});
    print("  - {s}/lua/?.lua\n", .{config_dir});
    print("  - {s}/lua/?/init.lua\n", .{config_dir});
    print("  - {s}/.hexe/lua/?.lua\n", .{cwd});
    print("  - {s}/.hexe/lua/?/init.lua\n", .{cwd});
}
