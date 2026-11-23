//! Styled, grouped CLI `--help` renderer for `hexe`.
//!
//! Inspects the `yazap.Command` tree directly before `app.parseFrom` so we
//! never modify vendored yazap sources (keeping flake FOD hashes intact), while
//! rendering grouped ANSI 16-color help on interactive TTYs and clean,
//! escape-free plain text when piped or when `NO_COLOR` is set.

const std = @import("std");
const yazap = @import("yazap");
const core = @import("core");
const cli_ui = core.cli_ui;

const AliasEntry = struct {
    canonical: []const u8,
    aliases: []const u8,
};

const TOP_LEVEL_ALIASES = [_]AliasEntry{
    .{ .canonical = "attach", .aliases = "a" },
    .{ .canonical = "detach", .aliases = "d" },
    .{ .canonical = "list", .aliases = "ls" },
    .{ .canonical = "terminal", .aliases = "mux" },
    .{ .canonical = "session", .aliases = "ses" },
    .{ .canonical = "layout", .aliases = "lay" },
    .{ .canonical = "profile", .aliases = "instance" },
    .{ .canonical = "shell", .aliases = "shp" },
    .{ .canonical = "popup", .aliases = "pop" },
    .{ .canonical = "config", .aliases = "cfg" },
};

const CommandGroup = struct {
    title: []const u8,
    names: []const []const u8,
};

const ROOT_GROUPS = [_]CommandGroup{
    .{
        .title = "Session Shortcuts",
        .names = &.{ "attach", "detach", "new", "list", "kill" },
    },
    .{
        .title = "Core Subsystems",
        .names = &.{ "terminal", "session", "layout", "pod", "profile" },
    },
    .{
        .title = "Tools & Integration",
        .names = &.{ "shell", "popup", "record", "palette", "config", "allow", "api", "plugin", "lua-api", "version" },
    },
    .{
        .title = "Adapters",
        .names = &.{ "web", "syslink" },
    },
};

fn aliasesFor(name: []const u8) ?[]const u8 {
    for (TOP_LEVEL_ALIASES) |entry| {
        if (std.mem.eql(u8, entry.canonical, name)) return entry.aliases;
    }
    return null;
}

fn isInRootGroups(name: []const u8) bool {
    for (ROOT_GROUPS) |group| {
        for (group.names) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
    }
    return false;
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

/// Inspect normalized CLI args and render styled help to stdout if `-h`/`--help`
/// was requested or a `.help_on_empty_args` subsystem was invoked with no args.
/// Returns `true` when help was rendered and the caller should exit 0.
pub fn tryHandleHelp(
    root: *const yazap.Command,
    normalized_args: []const [:0]const u8,
) !bool {
    var cmd: *const yazap.Command = root;
    var path_buf: [8][]const u8 = undefined;
    path_buf[0] = root.name;
    var path_len: usize = 1;

    var wants_help = false;
    var has_cmd_arg = false;

    var i: usize = 0;
    while (i < normalized_args.len) : (i += 1) {
        const arg: []const u8 = normalized_args[i];
        if (std.mem.eql(u8, arg, "--")) break;

        if (isHelpFlag(arg)) {
            wants_help = true;
            break;
        }

        if (arg.len > 0 and arg[0] == '-') {
            has_cmd_arg = true;
            // Skip option values so `-P work ses --help` still descends into `ses`.
            if (std.mem.startsWith(u8, arg, "--")) {
                if (std.mem.indexOfScalar(u8, arg, '=') == null) {
                    if (cmd.findLongOption(arg[2..])) |opt| {
                        if (opt.hasProperty(.takes_value) and i + 1 < normalized_args.len and !isHelpFlag(normalized_args[i + 1])) {
                            i += 1;
                        }
                    }
                }
            } else if (arg.len == 2) {
                if (cmd.findShortOption(arg[1])) |opt| {
                    if (opt.hasProperty(.takes_value) and i + 1 < normalized_args.len and !isHelpFlag(normalized_args[i + 1])) {
                        i += 1;
                    }
                }
            }
            continue;
        }

        if (cmd.findSubcommand(arg)) |sub| {
            cmd = sub;
            if (path_len < path_buf.len) {
                path_buf[path_len] = sub.name;
                path_len += 1;
            }
            has_cmd_arg = false;
        } else {
            has_cmd_arg = true;
        }
    }

    const empty_subsystem = (cmd != root and cmd.hasProperty(.help_on_empty_args) and !has_cmd_arg);
    if (!wants_help and !empty_subsystem) return false;

    const out = std.fs.File.stdout().deprecatedWriter();
    const p = cli_ui.Palette.forStdout();
    try renderHelp(out, root, cmd, path_buf[0..path_len], p);
    return true;
}

pub fn renderHelp(
    writer: anytype,
    root: *const yazap.Command,
    cmd: *const yazap.Command,
    path: []const []const u8,
    p: cli_ui.Palette,
) !void {
    if (cmd == root) {
        try renderRootHelp(writer, root, p);
    } else {
        try renderSubcommandHelp(writer, cmd, path, p);
    }
}

fn writeSpaces(writer: anytype, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try writer.writeByte(' ');
    }
}

fn optionVisualWidth(opt: *const yazap.Arg) usize {
    // Format: "  -s, --long=<VAL>" or "      --long=<VAL>"
    var w: usize = 4; // "-s, " or "    "
    if (opt.long_name) |l| {
        w += 2 + l.len;
    } else if (opt.short_name) |s| {
        if (s != 0) w = 2;
    }
    if (opt.hasProperty(.takes_value)) {
        const placeholder = opt.value_placeholder orelse opt.name;
        w += 3 + placeholder.len; // "=<placeholder>"
    }
    return w;
}

fn writeOptionRow(writer: anytype, opt: *const yazap.Arg, col_width: usize, p: cli_ui.Palette) !void {
    try writer.writeAll("  ");
    var vis: usize = 0;

    const short: ?u8 = if (opt.short_name) |s| (if (s != 0) s else null) else null;

    if (short) |s| {
        if (opt.long_name) |l| {
            try writer.print("{s}{s}-{c}{s}, {s}{s}--{s}{s}", .{
                p.bold, p.accent, s, p.reset,
                p.bold, p.accent, l, p.reset,
            });
            vis = 4 + 2 + l.len;
        } else {
            try writer.print("{s}{s}-{c}{s}", .{ p.bold, p.accent, s, p.reset });
            vis = 2;
        }
    } else if (opt.long_name) |l| {
        try writer.print("    {s}{s}--{s}{s}", .{ p.bold, p.accent, l, p.reset });
        vis = 4 + 2 + l.len;
    }

    if (opt.hasProperty(.takes_value)) {
        const placeholder = opt.value_placeholder orelse opt.name;
        try writer.print("{s}=<{s}>{s}", .{ p.dim, placeholder, p.reset });
        vis += 3 + placeholder.len;
    }

    const pad = if (col_width > vis) col_width - vis else 2;
    try writeSpaces(writer, pad);
    if (opt.description) |desc| {
        try writer.print("{s}", .{desc});
    }
    try writer.writeByte('\n');
}

fn writeOptionsSection(writer: anytype, cmd: *const yazap.Command, p: cli_ui.Palette) !void {
    const help_vis: usize = 10; // "-h, --help"
    var max_w: usize = help_vis;
    for (cmd.options.items) |*opt| {
        const w = optionVisualWidth(opt);
        if (w > max_w) max_w = w;
    }
    const col_width = @max(max_w + 2, 22);

    try writer.print("{s}{s}Options:{s}\n", .{ p.bold, p.warn, p.reset });
    for (cmd.options.items) |*opt| {
        try writeOptionRow(writer, opt, col_width, p);
    }

    // Synthetic -h, --help entry
    try writer.print("  {s}{s}-h{s}, {s}{s}--help{s}", .{
        p.bold, p.accent, p.reset,
        p.bold, p.accent, p.reset,
    });
    const pad = if (col_width > help_vis) col_width - help_vis else 2;
    try writeSpaces(writer, pad);
    try writer.writeAll("Print this help and exit\n");
}

fn rootCommandVisualWidth(name: []const u8) usize {
    if (aliasesFor(name)) |al| {
        return name.len + 3 + al.len; // "name (al)"
    }
    return name.len;
}

fn writeRootCommandRow(writer: anytype, sub: *const yazap.Command, col_width: usize, p: cli_ui.Palette) !void {
    try writer.writeAll("  ");
    var vis: usize = sub.name.len;
    try writer.print("{s}{s}{s}{s}", .{ p.bold, p.accent, sub.name, p.reset });
    if (aliasesFor(sub.name)) |al| {
        try writer.print(" {s}({s}){s}", .{ p.muted, al, p.reset });
        vis += 3 + al.len;
    }
    const pad = if (col_width > vis) col_width - vis else 2;
    try writeSpaces(writer, pad);
    if (sub.description) |desc| {
        try writer.print("{s}", .{desc});
    }
    try writer.writeByte('\n');
}

fn renderRootHelp(writer: anytype, root: *const yazap.Command, p: cli_ui.Palette) !void {
    try writer.print("{s}{s}hexe{s} {s}v{s}{s} {s}— Terminal multiplexer & session manager{s}\n\n", .{
        p.bold,  p.accent,                  p.reset,
        p.muted, core.build_options.version, p.reset,
        p.dim,   p.reset,
    });

    try writer.print("{s}{s}Usage:{s}\n", .{ p.bold, p.warn, p.reset });
    try writer.print("  {s}hexe{s} {s}[OPTIONS] [COMMAND]{s}\n\n", .{
        p.bold, p.reset, p.dim, p.reset,
    });

    // Compute a consistent column width across all root command groups.
    var max_cmd_w: usize = 0;
    for (root.subcommands.items) |*sub| {
        const w = rootCommandVisualWidth(sub.name);
        if (w > max_cmd_w) max_cmd_w = w;
    }
    const cmd_col = @max(max_cmd_w + 2, 22);

    for (ROOT_GROUPS) |group| {
        var any_in_group = false;
        for (group.names) |name| {
            if (root.findSubcommand(name) != null) {
                any_in_group = true;
                break;
            }
        }
        if (!any_in_group) continue;

        try writer.print("{s}{s}{s}:{s}\n", .{ p.bold, p.warn, group.title, p.reset });
        for (group.names) |name| {
            if (root.findSubcommand(name)) |sub| {
                try writeRootCommandRow(writer, sub, cmd_col, p);
            }
        }
        try writer.writeByte('\n');
    }

    // Safety net: show any ungrouped subcommands if new ones are added later.
    var printed_other = false;
    for (root.subcommands.items) |*sub| {
        if (!isInRootGroups(sub.name)) {
            if (!printed_other) {
                try writer.print("{s}{s}Commands:{s}\n", .{ p.bold, p.warn, p.reset });
                printed_other = true;
            }
            try writeRootCommandRow(writer, sub, cmd_col, p);
        }
    }
    if (printed_other) try writer.writeByte('\n');

    try writeOptionsSection(writer, root, p);

    try writer.print("\n{s}{s}Examples:{s}\n", .{ p.bold, p.warn, p.reset });
    try writer.print("  {s}hexe{s}                      {s}Start a session (or open startup chooser){s}\n", .{ p.accent, p.reset, p.dim, p.reset });
    try writer.print("  {s}hexe attach{s}               {s}Interactive session picker{s}\n", .{ p.accent, p.reset, p.dim, p.reset });
    try writer.print("  {s}hexe ls --details{s}         {s}Show sessions, tabs, splits, and floats{s}\n", .{ p.accent, p.reset, p.dim, p.reset });
    try writer.print("  {s}hexe <command> --help{s}     {s}Show help for a specific command{s}\n", .{ p.accent, p.reset, p.dim, p.reset });
}

fn writePath(writer: anytype, path: []const []const u8) !void {
    for (path, 0..) |seg, idx| {
        if (idx > 0) try writer.writeByte(' ');
        try writer.writeAll(seg);
    }
}

fn renderSubcommandHelp(
    writer: anytype,
    cmd: *const yazap.Command,
    path: []const []const u8,
    p: cli_ui.Palette,
) !void {
    try writer.print("{s}{s}", .{ p.bold, p.accent });
    try writePath(writer, path);
    try writer.print("{s}", .{p.reset});

    if (path.len == 2) {
        if (aliasesFor(cmd.name)) |al| {
            try writer.print(" {s}(alias: {s}){s}", .{ p.muted, al, p.reset });
        }
    }
    try writer.writeByte('\n');

    if (cmd.description) |desc| {
        try writer.print("{s}{s}{s}\n", .{ p.dim, desc, p.reset });
    }
    try writer.writeByte('\n');

    // Usage line
    try writer.print("{s}{s}Usage:{s}\n  {s}", .{ p.bold, p.warn, p.reset, p.bold });
    try writePath(writer, path);
    try writer.print("{s} {s}[OPTIONS]{s}", .{ p.reset, p.dim, p.reset });
    if (cmd.subcommands.items.len > 0) {
        try writer.print(" {s}<COMMAND>{s}", .{ p.accent, p.reset });
    }
    for (cmd.positional_args.items) |*arg| {
        const suffix: []const u8 = if (arg.hasProperty(.takes_multiple_values)) "..." else "";
        try writer.print(" {s}[<{s}>{s}]{s}", .{ p.accent, arg.name, suffix, p.reset });
    }
    try writer.writeAll("\n\n");

    // Positional args
    if (cmd.positional_args.items.len > 0) {
        var max_arg_w: usize = 0;
        for (cmd.positional_args.items) |*arg| {
            const w = arg.name.len + 2 + (if (arg.hasProperty(.takes_multiple_values)) @as(usize, 3) else 0);
            if (w > max_arg_w) max_arg_w = w;
        }
        const arg_col = @max(max_arg_w + 2, 18);

        try writer.print("{s}{s}Args:{s}\n", .{ p.bold, p.warn, p.reset });
        for (cmd.positional_args.items) |*arg| {
            const suffix: []const u8 = if (arg.hasProperty(.takes_multiple_values)) "..." else "";
            const vis = arg.name.len + 2 + suffix.len;
            try writer.print("  {s}<{s}>{s}{s}", .{ p.accent, arg.name, suffix, p.reset });
            const pad = if (arg_col > vis) arg_col - vis else 2;
            try writeSpaces(writer, pad);
            if (arg.description) |desc| {
                try writer.print("{s}", .{desc});
            }
            try writer.writeByte('\n');
        }
        try writer.writeByte('\n');
    }

    // Subcommands
    if (cmd.subcommands.items.len > 0) {
        var max_sub_w: usize = 0;
        for (cmd.subcommands.items) |*sub| {
            if (sub.name.len > max_sub_w) max_sub_w = sub.name.len;
        }
        const sub_col = @max(max_sub_w + 2, 18);

        try writer.print("{s}{s}Commands:{s}\n", .{ p.bold, p.warn, p.reset });
        for (cmd.subcommands.items) |*sub| {
            try writer.print("  {s}{s}{s}{s}", .{ p.bold, p.accent, sub.name, p.reset });
            const pad = if (sub_col > sub.name.len) sub_col - sub.name.len else 2;
            try writeSpaces(writer, pad);
            if (sub.description) |desc| {
                try writer.print("{s}", .{desc});
            }
            try writer.writeByte('\n');
        }
        try writer.writeByte('\n');
    }

    try writeOptionsSection(writer, cmd, p);

    if (cmd.subcommands.items.len > 0) {
        try writer.print("\n{s}Run '", .{p.dim});
        try writePath(writer, path);
        try writer.print(" <command> --help' for help on a subcommand.{s}\n", .{p.reset});
    }
}

test "renderHelp emits grouped sections with ANSI when enabled and clean plain text when disabled" {
    const allocator = std.testing.allocator;
    var app = yazap.App.init(allocator, "hexe", "Hexe terminal frontend");
    defer app.deinit();

    var root = app.rootCommand();
    try root.addArg(yazap.Arg.singleValueOption("profile", 'P', "Use a named profile"));
    try root.addArg(yazap.Arg.booleanOption("version", 'V', "Print the version and exit"));

    var attach = app.createCommand("attach", "Attach to a session");
    try attach.addArg(yazap.Arg.positional("name", "Session name or prefix", null));
    var ses = app.createCommand("session", "Session daemon management");
    ses.setProperty(.help_on_empty_args);
    const ses_list = app.createCommand("list", "List sessions");
    try ses.addSubcommand(ses_list);
    try root.addSubcommands(&.{ attach, ses });

    var plain_buf: std.ArrayList(u8) = .empty;
    defer plain_buf.deinit(allocator);
    try renderHelp(plain_buf.writer(allocator), root, root, &.{"hexe"}, cli_ui.Palette.styled(false));
    try std.testing.expect(std.mem.indexOf(u8, plain_buf.items, "\x1b[") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain_buf.items, "Session Shortcuts:") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain_buf.items, "Core Subsystems:") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain_buf.items, "attach (a)") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain_buf.items, "-P, --profile=<profile>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain_buf.items, "Print this help and exit") != null);

    var color_buf: std.ArrayList(u8) = .empty;
    defer color_buf.deinit(allocator);
    try renderHelp(color_buf.writer(allocator), root, root, &.{"hexe"}, cli_ui.Palette.styled(true));
    try std.testing.expect(std.mem.indexOf(u8, color_buf.items, "\x1b[36m") != null);
    try std.testing.expect(std.mem.indexOf(u8, color_buf.items, "\x1b[33m") != null);

    var sub_buf: std.ArrayList(u8) = .empty;
    defer sub_buf.deinit(allocator);
    const ses_ptr = root.findSubcommand("session").?;
    try renderHelp(sub_buf.writer(allocator), root, ses_ptr, &.{ "hexe", "session" }, cli_ui.Palette.styled(false));
    try std.testing.expect(std.mem.indexOf(u8, sub_buf.items, "hexe session (alias: ses)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sub_buf.items, "Commands:") != null);
    try std.testing.expect(std.mem.indexOf(u8, sub_buf.items, "list") != null);
}
