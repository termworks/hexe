const std = @import("std");
const posix = std.posix;
const core = @import("core");
const lua_runtime = core.lua_runtime;
const LuaRuntime = core.LuaRuntime;
const segment = core.segments;
const config_builder = core.config_builder;
const render_modules = @import("render_modules.zig");

const bash_init = @import("shell/bash.zig");
const zsh_init = @import("shell/zsh.zig");
const fish_init = @import("shell/fish.zig");

const ShpConfig = struct {
    left: []const core.Segment,
    right: []const core.Segment,
    has_config: bool,
    lua_runtime: ?*LuaRuntime = null,
};

/// Arguments for shp commands
pub const PopArgs = struct {
    init_shell: ?[]const u8 = null,
    no_comms: bool = false,
    prompt: bool = false,
    status: i64 = 0,
    duration: i64 = 0,
    right: bool = false,
    shell: ?[]const u8 = null,
    jobs: i64 = 0,

    // shell-event extended fields
    shell_phase: ?[]const u8 = null,
    shell_running: bool = false,
    shell_started_at: i64 = 0,
};

/// Entry point for shp - can be called directly from unified CLI
pub fn run(args: PopArgs) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    if (args.init_shell) |shell| {
        try printInit(shell, args.no_comms);
    } else if (args.prompt) {
        // Build args array for renderPrompt
        var prompt_args: [6][]const u8 = undefined;
        var argc: usize = 0;

        var status_buf: [32]u8 = undefined;
        var duration_buf: [32]u8 = undefined;
        var jobs_buf: [32]u8 = undefined;
        var shell_buf: [64]u8 = undefined;

        if (args.status != 0) {
            prompt_args[argc] = std.fmt.bufPrint(&status_buf, "--status={d}", .{args.status}) catch "--status=0";
            argc += 1;
        }
        if (args.duration != 0) {
            prompt_args[argc] = std.fmt.bufPrint(&duration_buf, "--duration={d}", .{args.duration}) catch "--duration=0";
            argc += 1;
        }
        if (args.right) {
            prompt_args[argc] = "--right";
            argc += 1;
        }
        if (args.shell) |shell| {
            prompt_args[argc] = std.fmt.bufPrint(&shell_buf, "--shell={s}", .{shell}) catch "--shell=bash";
            argc += 1;
        }
        if (args.jobs != 0) {
            prompt_args[argc] = std.fmt.bufPrint(&jobs_buf, "--jobs={d}", .{args.jobs}) catch "--jobs=0";
            argc += 1;
        }

        try renderPrompt(allocator, prompt_args[0..argc]);
    } else {
        try printUsage();
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "init")) {
        // shp init <shell>
        const shell = if (args.len > 2) args[2] else "bash";
        try run(.{ .init_shell = shell });
    } else if (std.mem.eql(u8, command, "prompt")) {
        // shp prompt [options]
        try renderPrompt(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage();
    } else {
        try printUsage();
    }
}

fn printUsage() !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(
        \\shp - Shell prompt
        \\
        \\Usage:
        \\  shp init <shell>     Print shell initialization script
        \\  shp prompt [opts]    Render the prompt
        \\  shp help             Show this help
        \\
        \\Shell init:
        \\  shp init bash        Bash initialization
        \\  shp init zsh         Zsh initialization
        \\  shp init fish        Fish initialization
        \\
        \\Prompt options:
        \\  --status=<n>         Exit status of last command
        \\  --duration=<ms>      Duration of last command in ms
        \\  --jobs=<n>           Number of background jobs
        \\  --right              Render right prompt
        \\
    );
}

fn printInit(shell: []const u8, no_comms: bool) !void {
    const stdout = std.fs.File.stdout();

    if (std.mem.eql(u8, shell, "bash")) {
        try bash_init.printInit(stdout, no_comms);
    } else if (std.mem.eql(u8, shell, "zsh")) {
        try zsh_init.printInit(stdout, no_comms);
    } else if (std.mem.eql(u8, shell, "fish")) {
        try fish_init.printInit(stdout, no_comms);
    } else {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unknown shell: {s}\nSupported shells: bash, zsh, fish\n", .{shell}) catch return;
        try stdout.writeAll(msg);
    }
}

fn renderPrompt(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var ctx = segment.Context.init(allocator);
    defer ctx.deinit();

    // Parse command line options
    var is_right = false;
    var shell: []const u8 = "bash";
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--right")) {
            is_right = true;
        } else if (std.mem.startsWith(u8, arg, "--status=")) {
            ctx.exit_status = std.fmt.parseInt(i32, arg[9..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--duration=")) {
            ctx.cmd_duration_ms = std.fmt.parseInt(u64, arg[11..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--jobs=")) {
            ctx.jobs = std.fmt.parseInt(u16, arg[7..], 10) catch 0;
        } else if (std.mem.startsWith(u8, arg, "--shell=")) {
            shell = arg[8..];
        }
    }

    // Get environment info
    ctx.cwd = std.posix.getenv("PWD") orelse "";
    ctx.home = std.posix.getenv("HOME");
    ctx.now_ms = @intCast(std.time.milliTimestamp());

    // Get terminal width from COLUMNS env var or default
    if (posix.getenv("COLUMNS")) |cols| {
        ctx.terminal_width = std.fmt.parseInt(u16, cols, 10) catch 80;
    }

    const stdout = std.fs.File.stdout();

    // Detect shell from environment if not specified
    if (std.mem.eql(u8, shell, "bash")) {
        // Try to auto-detect from $SHELL or $0
        if (posix.getenv("ZSH_VERSION")) |_| {
            shell = "zsh";
        } else if (posix.getenv("FISH_VERSION")) |_| {
            shell = "fish";
        }
    }

    const is_zsh = std.mem.eql(u8, shell, "zsh");

    // Try to load config
    var config = loadConfig(allocator);
    defer deinitShpConfig(&config, allocator);

    if (config.has_config) {
        const modules = if (is_right) config.right else config.left;
        if (modules.len > 0) {
            try render_modules.renderModulesSimple(allocator, config.lua_runtime, &ctx, modules, stdout, is_zsh);
            return;
        }
    }

    // Fallback to defaults if no config
    try renderDefaultPrompt(&ctx, is_right, stdout);
}

fn deinitShpConfig(config: *ShpConfig, allocator: std.mem.Allocator) void {
    if (config.has_config) {
        deinitModules(config.left, allocator);
        deinitModules(config.right, allocator);
        if (config.left.len > 0) allocator.free(config.left);
        if (config.right.len > 0) allocator.free(config.right);
    }
    if (config.lua_runtime) |rt| {
        rt.deinit();
        allocator.destroy(rt);
    }
    config.* = .{ .left = &[_]core.Segment{}, .right = &[_]core.Segment{}, .has_config = false, .lua_runtime = null };
}

fn deinitModules(mods: []const core.Segment, allocator: std.mem.Allocator) void {
    for (mods) |m| {
        allocator.free(m.name);
        if (m.command) |c| allocator.free(c);
        if (m.when) |w| {
            var ww = w;
            ww.deinit(allocator);
        }
        for (m.outputs) |o| {
            allocator.free(o.style);
            allocator.free(o.format);
        }
        if (m.outputs.len > 0) allocator.free(m.outputs);
    }
}

fn replacePromptModules(config: *ShpConfig, allocator: std.mem.Allocator, left: []const core.Segment, right: []const core.Segment) void {
    deinitModules(config.left, allocator);
    deinitModules(config.right, allocator);
    if (config.left.len > 0) allocator.free(config.left);
    if (config.right.len > 0) allocator.free(config.right);

    config.left = left;
    config.right = right;
    config.has_config = left.len > 0 or right.len > 0;
}

fn refreshPromptFromBuilder(config: *ShpConfig, runtime: *LuaRuntime, allocator: std.mem.Allocator) void {
    const builder = runtime.getBuilder() orelse return;
    const shp_builder = builder.shp orelse return;
    replacePromptModules(
        config,
        allocator,
        convertSegments(shp_builder.left_segments.items, allocator),
        convertSegments(shp_builder.right_segments.items, allocator),
    );
}

fn writeStderr(bytes: []const u8) void {
    std.fs.File.stderr().writeAll(bytes) catch |err| {
        core.logging.logError("shp", "failed to write stderr diagnostic", err);
    };
}

fn renderDefaultPrompt(ctx: *segment.Context, is_right: bool, stdout: std.fs.File) !void {
    const segment_names: []const []const u8 = if (is_right)
        &.{"time"}
    else
        &.{ "directory", "git_branch", "git_status", "character" };

    for (segment_names) |name| {
        if (ctx.renderSegment(name)) |segs| {
            for (segs) |seg| {
                // Just write text directly - no styling for now
                try stdout.writeAll(seg.text);
                try stdout.writeAll(" ");
            }
        }
    }
}

fn convertSegments(segments: []const config_builder.ShpConfigBuilder.SegmentDef, allocator: std.mem.Allocator) []const core.Segment {
    const modules = allocator.alloc(core.Segment, segments.len) catch return &[_]core.Segment{};
    var built_count: usize = 0;
    errdefer {
        for (modules[0..built_count]) |m| deinitModuleDefOwned(m, allocator);
        allocator.free(modules);
    }

    for (segments, 0..) |seg, i| {
        const name_copy = allocator.dupe(u8, seg.name) catch return &[_]core.Segment{};
        errdefer allocator.free(name_copy);

        const command_copy = if (seg.command) |cmd|
            allocator.dupe(u8, cmd) catch return &[_]core.Segment{}
        else
            null;
        errdefer if (command_copy) |cmd| allocator.free(cmd);

        const builtin_copy = if (seg.builtin) |b|
            allocator.dupe(u8, b) catch return &[_]core.Segment{}
        else
            null;
        errdefer if (builtin_copy) |b| allocator.free(b);

        const show_when_copy = if (seg.progress_show_when) |s|
            allocator.dupe(u8, s) catch return &[_]core.Segment{}
        else
            null;
        errdefer if (show_when_copy) |s| allocator.free(s);

        const outputs = if (seg.outputs.len == 0)
            &[_]core.OutputDef{}
        else blk: {
            const out_array = allocator.alloc(core.OutputDef, seg.outputs.len) catch return &[_]core.Segment{};
            var out_count: usize = 0;
            errdefer {
                for (out_array[0..out_count]) |o| {
                    allocator.free(o.style);
                    allocator.free(o.format);
                }
                allocator.free(out_array);
            }

            for (seg.outputs, 0..) |out, j| {
                const style_copy = allocator.dupe(u8, out.style) catch return &[_]core.Segment{};
                errdefer allocator.free(style_copy);

                const format_copy = allocator.dupe(u8, out.format) catch return &[_]core.Segment{};

                out_array[j] = .{
                    .style = style_copy,
                    .format = format_copy,
                };
                out_count += 1;
            }

            break :blk out_array;
        };

        modules[i] = .{
            .name = name_copy,
            .kind = seg.kind,
            .priority = @intCast(@max(@as(i64, 0), @min(seg.priority, 255))),
            .outputs = outputs,
            .command = command_copy,
            .builtin = builtin_copy,
            .progress_every_ms = seg.progress_every_ms,
            .progress_show_when = show_when_copy,
            .inverse_on_hover = seg.inverse_on_hover,
            .when = seg.when,
        };
        built_count += 1;
    }

    return modules;
}

fn deinitModuleDefOwned(m: core.Segment, allocator: std.mem.Allocator) void {
    allocator.free(m.name);
    if (m.command) |c| allocator.free(c);
    if (m.builtin) |b| allocator.free(b);
    if (m.progress_show_when) |s| allocator.free(s);
    for (m.outputs) |o| {
        allocator.free(o.style);
        allocator.free(o.format);
    }
    if (m.outputs.len > 0) allocator.free(m.outputs);
}

fn loadConfig(allocator: std.mem.Allocator) ShpConfig {
    var config = ShpConfig{
        .left = &[_]core.Segment{},
        .right = &[_]core.Segment{},
        .has_config = false,
    };

    const path = lua_runtime.getConfigPath(allocator, "init.lua") catch return config;
    defer allocator.free(path);

    const runtime_ptr = allocator.create(LuaRuntime) catch {
        writeStderr("shp: failed to allocate Lua runtime\n");
        return config;
    };
    runtime_ptr.* = LuaRuntime.init(allocator) catch {
        allocator.destroy(runtime_ptr);
        writeStderr("shp: failed to initialize Lua\n");
        return config;
    };
    const runtime = runtime_ptr;
    config.lua_runtime = runtime_ptr;

    // Load global config
    runtime.loadConfig(path) catch |err| {
        switch (err) {
            error.FileNotFound => {
                // Silent - missing config is fine
            },
            else => {
                writeStderr("shp: config error");
                if (runtime.last_error) |msg| {
                    writeStderr(": ");
                    writeStderr(msg);
                }
                writeStderr("\n");
            },
        }
        return config;
    };

    refreshPromptFromBuilder(&config, runtime, allocator);

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

    // Local config exists; canonical local config must use hexe.setup({ prompt = ... }).
    runtime.loadConfig(local_path) catch {
        // Failed to load local config, but global is already loaded
        return config;
    };

    refreshPromptFromBuilder(&config, runtime, allocator);

    // Pop local config table
    runtime.pop();

    return config;
}
