const std = @import("std");
const core = @import("core");
const session_config = core.session_config;
const cli_ui = core.cli_ui;

/// Run `hexe layout open <target>` — launch a session from a .hexe.lua config.
pub fn runSesOpen(
    allocator: std.mem.Allocator,
    target: []const u8,
    log_level: ?core.logging.Level,
    log_file: []const u8,
    instance: []const u8,
) !void {
    _ = instance;

    if (target.len == 0) {
        cli_ui.printErr("target required (directory path, .lua file, or session name)", .{});
        cli_ui.printErrHint("Usage: hexe layout open <path-or-name>[:<tab>]", .{});
        std.process.exit(1);
    }

    // Resolve the config path
    const resolved = session_config.resolveConfigPath(allocator, target) catch |err| {
        cli_ui.printErr("resolving config path failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    } orelse {
        cli_ui.printErr("config not found for '{s}'", .{target});
        cli_ui.printErrHint("Looked for .hexe.lua in directory/path or registered layout name in sessions.json", .{});
        std.process.exit(1);
    };
    defer allocator.free(resolved.path);
    defer if (resolved.tab_filter) |tf| allocator.free(tf);

    // Parse the config
    var config = session_config.parseSessionLua(allocator, resolved.path) catch |err| {
        if (err == error.FileNotFound) {
            cli_ui.printErr("config file not found: {s}", .{resolved.path});
        } else {
            cli_ui.printErr("failed to parse config: {s}", .{@errorName(err)});
        }
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    // Apply tab filter
    const selected_tab_filter = resolved.tab_filter orelse config.filter_tab;

    // Resolve root directory
    var root_path: ?[]const u8 = null;
    defer if (root_path) |rp| allocator.free(rp);

    if (config.root) |root| {
        if (std.fs.path.isAbsolute(root)) {
            root_path = try allocator.dupe(u8, root);
        } else {
            // Relative to config file directory
            const config_dir = std.fs.path.dirname(resolved.path) orelse ".";
            root_path = try std.fs.path.resolve(allocator, &.{ config_dir, root });
        }
    } else {
        // Default root: directory containing the config file
        if (std.fs.path.dirname(resolved.path)) |dir| {
            root_path = try allocator.dupe(u8, dir);
        }
    }

    // Change to root directory before launching the terminal frontend
    if (root_path) |rp| {
        std.posix.chdir(rp) catch |err| {
            cli_ui.printErr("cannot chdir to root '{s}': {s}", .{ rp, @errorName(err) });
            std.process.exit(1);
        };
    }

    // Determine session name
    const session_name: ?[]const u8 = config.name;

    // Launch the terminal frontend with the session config
    const terminal = @import("terminal");
    try terminal.run(.{
        .name = session_name,
        .log_level = log_level,
        .log_file = if (log_file.len > 0) log_file else null,
        .session_config_path = resolved.path,
        .session_tab_filter = selected_tab_filter,
    });
}
