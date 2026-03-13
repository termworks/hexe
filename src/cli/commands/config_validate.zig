const std = @import("std");
const core = @import("core");

const print = std.debug.print;

/// Validate the Hexe configuration file
pub fn run() !void {
    const allocator = std.heap.page_allocator;

    // Get config path (same resolver used by runtime config loading).
    const config_path = try core.lua_runtime.getConfigPath(allocator, "init.lua");
    defer allocator.free(config_path);

    // Check if config file exists
    std.fs.accessAbsolute(config_path, .{}) catch {
        print("✓ No config file found (using defaults)\n", .{});
        print("  Expected location: {s}\n", .{config_path});
        return;
    };

    // Try to load the config
    var runtime = core.LuaRuntime.init(allocator) catch {
        print("✗ Failed to initialize Lua runtime\n", .{});
        return error.LuaInitFailed;
    };
    defer runtime.deinit();

    // Load the config file
    runtime.loadConfig(config_path) catch |err| {
        print("✗ Config validation failed: {s}\n", .{config_path});
        print("\nSyntax error in Lua config file.\n", .{});
        print("Check for:\n", .{});
        print("  - Missing commas between table entries\n", .{});
        print("  - Unclosed brackets or braces\n", .{});
        print("  - Invalid Lua syntax\n", .{});
        print("  - Typos in configuration keys\n", .{});
        print("\nError details: {}\n", .{err});
        if (runtime.last_error) |msg| {
            print("Lua error: {s}\n", .{msg});
        }
        return err;
    };

    // Parse the config table
    const config = core.config.Config.parseFromLua(&runtime, false) catch |err| {
        print("✗ Config validation failed: {s}\n", .{config_path});
        print("\nConfiguration structure error.\n", .{});
        print("Common issues:\n", .{});
        print("  - Invalid color format (use hex like '#rrggbb')\n", .{});
        print("  - Invalid keybinding syntax\n", .{});
        print("  - Missing required fields\n", .{});
        print("  - Type mismatches (string vs number)\n", .{});
        print("\nRun with 'hexe terminal' to see the actual config being used.\n", .{});
        return err;
    };
    var mutable_config = config;
    defer mutable_config.deinit();

    // Success!
    print("✓ Config valid: {s}\n", .{config_path});
    print("\nConfiguration loaded successfully:\n", .{});

    // Show some config highlights
    print("  - Status bar enabled: {}\n", .{config.tabs.status.enabled});
    print("  - Keybindings: {} defined\n", .{config.input.binds.len});
    print("  - Notifications enabled: {}\n", .{config.notifications.mux.duration_ms > 0});

    print("\n✓ All checks passed\n", .{});
}
