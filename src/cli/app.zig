const std = @import("std");
const yazap = @import("yazap");
const core = @import("core");
const ipc = core.ipc;
const terminal = @import("terminal");
const ses = @import("ses");
const pod = @import("pod");
const shp = @import("shp");
const pop_handlers = @import("pop_handlers.zig");
const cli_cmds = @import("commands/com.zig");
const config_validate = @import("commands/config_validate.zig");
const ses_export = @import("commands/ses_export.zig");
const ses_stats = @import("commands/ses_stats.zig");

const c = @cImport({
    @cInclude("stdlib.h");
});

const App = yazap.App;
const Arg = yazap.Arg;
const print = std.debug.print;

const help_ansi = struct {
    pub const RESET = "\x1b[0m";
    pub const BOLD = "\x1b[1m";
    pub const DIM = "\x1b[2m";
    pub const TITLE = "\x1b[38;5;45m";
    pub const SECTION = "\x1b[38;5;81m";
    pub const CMD = "\x1b[38;5;220m";
    pub const ALIAS = "\x1b[38;5;171m";
};

fn setEnvVar(key: []const u8, value: []const u8) void {
    if (key.len == 0 or value.len == 0) return;
    const key_z = std.heap.c_allocator.dupeZ(u8, key) catch return;
    defer std.heap.c_allocator.free(key_z);
    const value_z = std.heap.c_allocator.dupeZ(u8, value) catch return;
    defer std.heap.c_allocator.free(value_z);
    _ = c.setenv(key_z.ptr, value_z.ptr, 1);
}

fn hasInstanceEnv() bool {
    if (std.posix.getenv("HEXE_INSTANCE")) |v| {
        return v.len > 0;
    }
    return false;
}

fn setInstanceFromCli(name: []const u8) void {
    if (name.len == 0) return;
    setEnvVar("HEXE_INSTANCE", name);
}

fn setTestOnlyEnv() void {
    setEnvVar("HEXE_TEST_ONLY", "1");
}

fn setGeneratedTestInstance() void {
    const uuid = ipc.generateUuid();
    var buf: [16]u8 = undefined;
    @memcpy(buf[0..5], "test-");
    @memcpy(buf[5..13], uuid[0..8]);
    setEnvVar("HEXE_INSTANCE", buf[0..13]);
    setTestOnlyEnv();
    print("test instance: {s}\n", .{buf[0..13]});
}

fn parseOptionalI64(value: ?[]const u8, field_name: []const u8) !i64 {
    if (value) |raw| {
        return std.fmt.parseInt(i64, raw, 10) catch {
            print("Error: invalid integer for --{s}: {s}\n", .{ field_name, raw });
            return error.InvalidArgument;
        };
    }
    return 0;
}

fn normalizeTopLevelCommand(command: []const u8) []const u8 {
    if (std.mem.eql(u8, command, "ses")) return "session";
    if (std.mem.eql(u8, command, "lay")) return "layout";
    if (std.mem.eql(u8, command, "mux")) return "multiplexer";
    if (std.mem.eql(u8, command, "shp")) return "shell";
    if (std.mem.eql(u8, command, "pop")) return "popup";
    if (std.mem.eql(u8, command, "cfg")) return "config";
    return command;
}

fn hasHelpFlag(args: []const [:0]u8) bool {
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;
    }
    return false;
}

fn firstCommandToken(args: []const [:0]u8) ?[]const u8 {
    for (args[1..]) |arg| {
        if (arg.len > 0 and arg[0] != '-') return arg;
    }
    return null;
}

fn printHelpRoot() void {
    print("{s}{s}Hexe CLI{s}\n", .{ help_ansi.BOLD, help_ansi.TITLE, help_ansi.RESET });
    print("{s}A terminal frontend where UI is disposable.{s}\n\n", .{ help_ansi.DIM, help_ansi.RESET });
    print("{s}Usage{s}: hexe <command> [subcommand] [options]\n\n", .{ help_ansi.SECTION, help_ansi.RESET });
    print("{s}Commands{s}:\n", .{ help_ansi.SECTION, help_ansi.RESET });
    print("  {s}session{s}      {s}(alias: ses){s}  Session daemon management\n", .{ help_ansi.CMD, help_ansi.RESET, help_ansi.ALIAS, help_ansi.RESET });
    print("  {s}layout{s}       {s}(alias: lay){s}  Saved session layouts (.lua)\n", .{ help_ansi.CMD, help_ansi.RESET, help_ansi.ALIAS, help_ansi.RESET });
    print("  {s}multiplexer{s}  {s}(alias: mux){s}  Terminal frontend\n", .{ help_ansi.CMD, help_ansi.RESET, help_ansi.ALIAS, help_ansi.RESET });
    print("  {s}pod{s}          {s}(alias: pod){s}  Per-pane PTY daemon\n", .{ help_ansi.CMD, help_ansi.RESET, help_ansi.ALIAS, help_ansi.RESET });
    print("  {s}shell{s}        {s}(alias: shp){s}  Shell prompt renderer\n", .{ help_ansi.CMD, help_ansi.RESET, help_ansi.ALIAS, help_ansi.RESET });
    print("  {s}popup{s}        {s}(alias: pop){s}  Popup overlays\n", .{ help_ansi.CMD, help_ansi.RESET, help_ansi.ALIAS, help_ansi.RESET });
    print("  {s}record{s}       Record lifecycle control\n", .{ help_ansi.CMD, help_ansi.RESET });
    print("  {s}config{s}       {s}(alias: cfg){s}  Configuration management\n\n", .{ help_ansi.CMD, help_ansi.RESET, help_ansi.ALIAS, help_ansi.RESET });
    print("Try {s}hexe session --help{s} or {s}hexe multiplexer --help{s}\n", .{ help_ansi.CMD, help_ansi.RESET, help_ansi.CMD, help_ansi.RESET });
}

fn printHelpCommand(command: []const u8) void {
    if (std.mem.eql(u8, command, "session")) {
        print("{s}{s}session{s} {s}(alias: ses){s}\n", .{ help_ansi.BOLD, help_ansi.CMD, help_ansi.RESET, help_ansi.ALIAS, help_ansi.RESET });
        print("Subcommands: daemon, status, list, kill, clear, export, stats\n", .{});
        return;
    }
    if (std.mem.eql(u8, command, "layout")) {
        print("{s}{s}layout{s} {s}(alias: lay){s}\n", .{ help_ansi.BOLD, help_ansi.CMD, help_ansi.RESET, help_ansi.ALIAS, help_ansi.RESET });
        print("Subcommands: list, open, save\n", .{});
        return;
    }
    if (std.mem.eql(u8, command, "multiplexer")) {
        print("{s}{s}multiplexer{s} {s}(alias: mux){s}\n", .{ help_ansi.BOLD, help_ansi.CMD, help_ansi.RESET, help_ansi.ALIAS, help_ansi.RESET });
        print("Subcommands: new, attach, record, float, notify, send, info, layout, focus\n", .{});
        return;
    }
    if (std.mem.eql(u8, command, "pod")) {
        print("{s}{s}pod{s} {s}(alias: pod){s}\n", .{ help_ansi.BOLD, help_ansi.CMD, help_ansi.RESET, help_ansi.ALIAS, help_ansi.RESET });
        print("Subcommands: daemon, list, new, send, attach, record, kill, gc\n", .{});
        return;
    }
    if (std.mem.eql(u8, command, "shell")) {
        print("{s}{s}shell{s} {s}(alias: shp){s}\n", .{ help_ansi.BOLD, help_ansi.CMD, help_ansi.RESET, help_ansi.ALIAS, help_ansi.RESET });
        print("Subcommands: prompt, init, exit-intent, shell-event, spinner\n", .{});
        return;
    }
    if (std.mem.eql(u8, command, "popup")) {
        print("{s}{s}popup{s} {s}(alias: pop){s}\n", .{ help_ansi.BOLD, help_ansi.CMD, help_ansi.RESET, help_ansi.ALIAS, help_ansi.RESET });
        print("Subcommands: notify, confirm, choose\n", .{});
        return;
    }
    if (std.mem.eql(u8, command, "config")) {
        print("{s}{s}config{s} {s}(alias: cfg){s}\n", .{ help_ansi.BOLD, help_ansi.CMD, help_ansi.RESET, help_ansi.ALIAS, help_ansi.RESET });
        print("Subcommands: validate\n", .{});
        return;
    }
    if (std.mem.eql(u8, command, "record")) {
        print("{s}{s}record{s}\n", .{ help_ansi.BOLD, help_ansi.CMD, help_ansi.RESET });
        print("Subcommands: start, stop, status, toggle\n", .{});
        return;
    }
    printHelpRoot();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = App.init(allocator, "hexe", "Hexe terminal frontend");
    defer app.deinit();

    var root = app.rootCommand();

    var ses_cmd = app.createCommand("session", "Session daemon management");
    ses_cmd.setProperty(.help_on_empty_args);

    var layout_cmd = app.createCommand("layout", "Saved session layouts (.lua)");
    layout_cmd.setProperty(.help_on_empty_args);

    var pod_cmd = app.createCommand("pod", "Per-pane PTY daemon");
    pod_cmd.setProperty(.help_on_empty_args);

    var mux_cmd = app.createCommand("multiplexer", "Terminal frontend");
    mux_cmd.setProperty(.help_on_empty_args);

    var shp_cmd = app.createCommand("shell", "Shell prompt renderer");
    shp_cmd.setProperty(.help_on_empty_args);

    var pop_cmd = app.createCommand("popup", "Popup overlays");
    pop_cmd.setProperty(.help_on_empty_args);

    var config_cmd = app.createCommand("config", "Configuration management");
    config_cmd.setProperty(.help_on_empty_args);

    var record_cmd = app.createCommand("record", "Recording lifecycle control");
    record_cmd.setProperty(.help_on_empty_args);

    // SES subcommands
    var ses_daemon = app.createCommand("daemon", "Start the session daemon");
    try ses_daemon.addArg(Arg.booleanOption("foreground", 'f', null));
    try ses_daemon.addArg(Arg.booleanOption("debug", 'd', null));
    try ses_daemon.addArg(Arg.singleValueOption("logfile", 'L', null));
    try ses_daemon.addArg(Arg.singleValueOption("instance", 'I', null));
    try ses_daemon.addArg(Arg.booleanOption("test-only", 'T', null));

    var ses_status_cmd = app.createCommand("status", "Show daemon info");
    try ses_status_cmd.addArg(Arg.singleValueOption("instance", 'I', null));

    var ses_list = app.createCommand("list", "List all sessions and panes");
    try ses_list.addArg(Arg.booleanOption("details", 'd', null));
    try ses_list.addArg(Arg.singleValueOption("instance", 'I', null));
    try ses_list.addArg(Arg.booleanOption("json", 'j', null));

    var ses_kill = app.createCommand("kill", "Kill a detached session");
    try ses_kill.addArg(Arg.positional("target", null, null));
    try ses_kill.addArg(Arg.singleValueOption("instance", 'I', null));

    var ses_clear = app.createCommand("clear", "Kill all detached sessions");
    try ses_clear.addArg(Arg.singleValueOption("instance", 'I', null));
    try ses_clear.addArg(Arg.booleanOption("force", 'f', null));

    var ses_export_cmd = app.createCommand("export", "Export detached session to JSON");
    try ses_export_cmd.addArg(Arg.positional("session", null, null));
    try ses_export_cmd.addArg(Arg.singleValueOption("output", 'o', null));
    try ses_export_cmd.addArg(Arg.singleValueOption("instance", 'I', null));

    var ses_stats_cmd = app.createCommand("stats", "Show resource usage statistics");
    try ses_stats_cmd.addArg(Arg.singleValueOption("instance", 'I', null));

    try ses_cmd.addSubcommands(&[_]yazap.Command{
        ses_daemon,
        ses_status_cmd,
        ses_list,
        ses_kill,
        ses_clear,
        ses_export_cmd,
        ses_stats_cmd,
    });

    var layout_list = app.createCommand("list", "List saved session layouts");
    try layout_list.addArg(Arg.booleanOption("json", 'j', null));

    var layout_open = app.createCommand("open", "Open a saved session layout");
    try layout_open.addArg(Arg.positional("target", null, null));
    try layout_open.addArg(Arg.booleanOption("debug", 'd', null));
    try layout_open.addArg(Arg.singleValueOption("logfile", 'L', null));
    try layout_open.addArg(Arg.singleValueOption("instance", 'I', null));

    var layout_save = app.createCommand("save", "Save current session as .hexe.lua");
    try layout_save.addArg(Arg.singleValueOption("instance", 'I', null));
    try layout_save.addArg(Arg.singleValueOption("scope", null, null));

    try layout_cmd.addSubcommands(&[_]yazap.Command{ layout_list, layout_open, layout_save });

    // POD subcommands
    var pod_daemon = app.createCommand("daemon", "Start a per-pane pod daemon");
    try pod_daemon.addArg(Arg.singleValueOption("uuid", 'u', null));
    try pod_daemon.addArg(Arg.singleValueOption("name", 'n', null));
    try pod_daemon.addArg(Arg.singleValueOption("socket", 's', null));
    try pod_daemon.addArg(Arg.singleValueOption("shell", 'S', null));
    try pod_daemon.addArg(Arg.singleValueOption("cwd", 'C', null));
    try pod_daemon.addArg(Arg.singleValueOption("labels", null, null));
    try pod_daemon.addArg(Arg.booleanOption("write-meta", null, null));
    try pod_daemon.addArg(Arg.booleanOption("no-write-meta", null, null));
    try pod_daemon.addArg(Arg.booleanOption("write-alias", null, null));
    try pod_daemon.addArg(Arg.booleanOption("foreground", 'f', null));
    try pod_daemon.addArg(Arg.booleanOption("debug", 'd', null));
    try pod_daemon.addArg(Arg.singleValueOption("logfile", 'L', null));
    try pod_daemon.addArg(Arg.singleValueOption("instance", 'I', null));
    try pod_daemon.addArg(Arg.booleanOption("test-only", 'T', null));

    var pod_list = app.createCommand("list", "List discoverable pods (from .meta)");
    try pod_list.addArg(Arg.singleValueOption("where", null, null));
    try pod_list.addArg(Arg.booleanOption("probe", null, null));
    try pod_list.addArg(Arg.booleanOption("alive", null, null));
    try pod_list.addArg(Arg.booleanOption("json", 'j', null));

    var pod_new = app.createCommand("new", "Create a standalone pod (spawns pod daemon)");
    try pod_new.addArg(Arg.singleValueOption("name", 'n', null));
    try pod_new.addArg(Arg.singleValueOption("shell", 'S', null));
    try pod_new.addArg(Arg.singleValueOption("cwd", 'C', null));
    try pod_new.addArg(Arg.singleValueOption("labels", null, null));
    try pod_new.addArg(Arg.booleanOption("alias", null, null));
    try pod_new.addArg(Arg.booleanOption("debug", 'd', null));
    try pod_new.addArg(Arg.singleValueOption("logfile", 'L', null));
    try pod_new.addArg(Arg.singleValueOption("instance", 'I', null));
    try pod_new.addArg(Arg.booleanOption("test-only", 'T', null));

    var pod_send = app.createCommand("send", "Send input to a pod (by uuid/name/socket)");
    try pod_send.addArg(Arg.singleValueOption("uuid", 'u', null));
    try pod_send.addArg(Arg.singleValueOption("name", 'n', null));
    try pod_send.addArg(Arg.singleValueOption("socket", 's', null));
    try pod_send.addArg(Arg.booleanOption("enter", 'e', null));
    try pod_send.addArg(Arg.singleValueOption("ctrl", 'C', null));
    try pod_send.addArg(Arg.positional("text", null, null));

    var pod_attach = app.createCommand("attach", "Attach to a pod (raw tty)");
    try pod_attach.addArg(Arg.singleValueOption("uuid", 'u', null));
    try pod_attach.addArg(Arg.singleValueOption("name", 'n', null));
    try pod_attach.addArg(Arg.singleValueOption("socket", 's', null));
    try pod_attach.addArg(Arg.singleValueOption("detach", null, null));
    try pod_attach.addArg(Arg.singleValueOption("record", null, null));
    try pod_attach.addArg(Arg.booleanOption("capture-input", null, null));

    var pod_record = app.createCommand("record", "Attach to a pod and record asciicast");
    try pod_record.addArg(Arg.singleValueOption("uuid", 'u', null));
    try pod_record.addArg(Arg.singleValueOption("name", 'n', null));
    try pod_record.addArg(Arg.singleValueOption("socket", 's', null));
    try pod_record.addArg(Arg.singleValueOption("out", 'o', null));
    try pod_record.addArg(Arg.booleanOption("capture-input", null, null));

    var pod_kill = app.createCommand("kill", "Kill a pod by uuid/name");
    try pod_kill.addArg(Arg.singleValueOption("uuid", 'u', null));
    try pod_kill.addArg(Arg.singleValueOption("name", 'n', null));
    try pod_kill.addArg(Arg.singleValueOption("signal", 's', null));
    try pod_kill.addArg(Arg.booleanOption("force", 'f', null));

    var pod_gc = app.createCommand("gc", "Garbage-collect stale pod metadata");
    try pod_gc.addArg(Arg.booleanOption("dry-run", 'n', null));

    try pod_cmd.addSubcommands(&[_]yazap.Command{ pod_daemon, pod_list, pod_new, pod_send, pod_attach, pod_record, pod_kill, pod_gc });

    // MUX subcommands
    var mux_new = app.createCommand("new", "Create new multiplexer session");
    try mux_new.addArg(Arg.singleValueOption("name", 'n', null));
    try mux_new.addArg(Arg.booleanOption("debug", 'd', null));
    try mux_new.addArg(Arg.singleValueOption("logfile", 'L', null));
    try mux_new.addArg(Arg.singleValueOption("ses-socket", null, null));
    try mux_new.addArg(Arg.booleanOption("no-autostart-ses", null, null));
    try mux_new.addArg(Arg.singleValueOption("instance", 'I', null));
    try mux_new.addArg(Arg.booleanOption("test-only", 'T', null));

    var mux_attach = app.createCommand("attach", "Attach to existing session");
    try mux_attach.addArg(Arg.positional("name", null, null));
    try mux_attach.addArg(Arg.booleanOption("debug", 'd', null));
    try mux_attach.addArg(Arg.singleValueOption("logfile", 'L', null));
    try mux_attach.addArg(Arg.singleValueOption("ses-socket", null, null));
    try mux_attach.addArg(Arg.booleanOption("no-autostart-ses", null, null));
    try mux_attach.addArg(Arg.singleValueOption("instance", 'I', null));

    var mux_record = app.createCommand("record", "Attach to mux and record asciicast");
    try mux_record.addArg(Arg.singleValueOption("out", 'o', null));
    try mux_record.addArg(Arg.booleanOption("capture-input", null, null));
    try mux_record.addArg(Arg.singleValueOption("instance", 'I', null));

    var mux_float = app.createCommand("float", "Spawn a transient float pane");
    try mux_float.addArg(Arg.singleValueOption("command", 'c', null));
    try mux_float.addArg(Arg.singleValueOption("title", null, null));
    try mux_float.addArg(Arg.singleValueOption("cwd", null, null));
    try mux_float.addArg(Arg.singleValueOption("result-file", null, null));
    try mux_float.addArg(Arg.booleanOption("pass-env", null, null));
    try mux_float.addArg(Arg.singleValueOption("extra-env", null, null));
    try mux_float.addArg(Arg.booleanOption("isolated", null, null));
    try mux_float.addArg(Arg.singleValueOption("isolation", null, null));
    try mux_float.addArg(Arg.singleValueOption("size", null, null));
    try mux_float.addArg(Arg.booleanOption("focus", null, null));
    try mux_float.addArg(Arg.singleValueOption("key", null, null));
    try mux_float.addArg(Arg.singleValueOption("instance", 'I', null));

    var mux_notify = app.createCommand("notify", "Send notification");
    try mux_notify.addArg(Arg.singleValueOption("uuid", 'u', null));
    try mux_notify.addArg(Arg.booleanOption("creator", 'c', null));
    try mux_notify.addArg(Arg.booleanOption("last", 'l', null));
    try mux_notify.addArg(Arg.booleanOption("broadcast", 'b', null));
    try mux_notify.addArg(Arg.positional("message", null, null));
    try mux_notify.addArg(Arg.singleValueOption("instance", 'I', null));

    var mux_send = app.createCommand("send", "Send keystrokes to pane");
    try mux_send.addArg(Arg.singleValueOption("uuid", 'u', null));
    try mux_send.addArg(Arg.booleanOption("creator", 'c', null));
    try mux_send.addArg(Arg.booleanOption("last", 'l', null));
    try mux_send.addArg(Arg.booleanOption("broadcast", 'b', null));
    try mux_send.addArg(Arg.booleanOption("enter", 'e', null));
    try mux_send.addArg(Arg.singleValueOption("ctrl", 'C', null));
    try mux_send.addArg(Arg.positional("text", null, null));
    try mux_send.addArg(Arg.singleValueOption("instance", 'I', null));

    var mux_info = app.createCommand("info", "Show information about a pane");
    try mux_info.addArg(Arg.singleValueOption("uuid", 'u', null));
    try mux_info.addArg(Arg.booleanOption("creator", 'c', null));
    try mux_info.addArg(Arg.booleanOption("last", 'l', null));
    try mux_info.addArg(Arg.singleValueOption("instance", 'I', null));

    var mux_layout = app.createCommand("layout", "Save and restore layouts");
    mux_layout.setProperty(.help_on_empty_args);

    var mux_layout_save = app.createCommand("save", "Save current layout");
    try mux_layout_save.addArg(Arg.positional("name", null, null));

    var mux_layout_load = app.createCommand("load", "Load a saved layout");
    try mux_layout_load.addArg(Arg.positional("name", null, null));

    const mux_layout_list = app.createCommand("list", "List saved layouts");

    try mux_layout.addSubcommands(&[_]yazap.Command{ mux_layout_save, mux_layout_load, mux_layout_list });

    var mux_focus = app.createCommand("focus", "Move focus to adjacent pane");
    try mux_focus.addArg(Arg.positional("dir", null, null));

    try mux_cmd.addSubcommands(&[_]yazap.Command{ mux_new, mux_attach, mux_record, mux_float, mux_notify, mux_send, mux_info, mux_layout, mux_focus });

    // SHP subcommands
    var shp_prompt = app.createCommand("prompt", "Render shell prompt");
    try shp_prompt.addArg(Arg.singleValueOption("status", 's', null));
    try shp_prompt.addArg(Arg.singleValueOption("duration", 'd', null));
    try shp_prompt.addArg(Arg.booleanOption("right", 'r', null));
    try shp_prompt.addArg(Arg.singleValueOption("shell", 'S', null));
    try shp_prompt.addArg(Arg.singleValueOption("jobs", 'j', null));

    var shp_init = app.createCommand("init", "Print shell initialization script");
    try shp_init.addArg(Arg.positional("shell", null, null));
    try shp_init.addArg(Arg.booleanOption("no-comms", null, null));

    const shp_exit_intent = app.createCommand("exit-intent", "Ask mux permission before shell exits");

    var shp_shell_event = app.createCommand("shell-event", "Send shell command metadata to the current mux");
    try shp_shell_event.addArg(Arg.singleValueOption("cmd", null, null));
    try shp_shell_event.addArg(Arg.singleValueOption("status", null, null));
    try shp_shell_event.addArg(Arg.singleValueOption("duration", null, null));
    try shp_shell_event.addArg(Arg.singleValueOption("cwd", null, null));
    try shp_shell_event.addArg(Arg.singleValueOption("jobs", null, null));
    try shp_shell_event.addArg(Arg.singleValueOption("phase", null, null));
    try shp_shell_event.addArg(Arg.booleanOption("running", null, null));
    try shp_shell_event.addArg(Arg.singleValueOption("started-at", null, null));

    var shp_spinner = app.createCommand("spinner", "Render a spinner/animation frame");
    try shp_spinner.addArg(Arg.positional("name", null, null));
    try shp_spinner.addArg(Arg.singleValueOption("width", 'w', null));
    try shp_spinner.addArg(Arg.singleValueOption("interval", 'i', null));
    try shp_spinner.addArg(Arg.singleValueOption("hold", 'H', null));
    try shp_spinner.addArg(Arg.booleanOption("loop", 'l', null));

    try shp_cmd.addSubcommands(&[_]yazap.Command{ shp_prompt, shp_init, shp_exit_intent, shp_shell_event, shp_spinner });

    // POP subcommands
    var pop_notify = app.createCommand("notify", "Show notification");
    try pop_notify.addArg(Arg.singleValueOption("uuid", 'u', null));
    try pop_notify.addArg(Arg.singleValueOption("timeout", 't', null));
    try pop_notify.addArg(Arg.positional("message", null, null));

    var pop_confirm = app.createCommand("confirm", "Yes/No dialog");
    try pop_confirm.addArg(Arg.singleValueOption("uuid", 'u', null));
    try pop_confirm.addArg(Arg.singleValueOption("timeout", 't', null));
    try pop_confirm.addArg(Arg.positional("message", null, null));

    var pop_choose = app.createCommand("choose", "Select from options");
    try pop_choose.addArg(Arg.singleValueOption("uuid", 'u', null));
    try pop_choose.addArg(Arg.singleValueOption("timeout", 't', null));
    try pop_choose.addArg(Arg.singleValueOption("items", 'i', null));
    try pop_choose.addArg(Arg.positional("message", null, null));

    try pop_cmd.addSubcommands(&[_]yazap.Command{ pop_notify, pop_confirm, pop_choose });

    // CONFIG subcommands
    const config_validate_cmd = app.createCommand("validate", "Validate configuration file");
    try config_cmd.addSubcommand(config_validate_cmd);

    var record_start = app.createCommand("start", "Start background recording");
    try record_start.addArg(Arg.singleValueOption("scope", null, null));
    try record_start.addArg(Arg.singleValueOption("uuid", 'u', null));
    try record_start.addArg(Arg.singleValueOption("name", 'n', null));
    try record_start.addArg(Arg.singleValueOption("socket", 's', null));
    try record_start.addArg(Arg.singleValueOption("out", 'o', null));
    try record_start.addArg(Arg.booleanOption("capture-input", null, null));

    var record_stop = app.createCommand("stop", "Stop background recording");
    try record_stop.addArg(Arg.singleValueOption("scope", null, null));

    var record_status = app.createCommand("status", "Show recording status");
    try record_status.addArg(Arg.singleValueOption("scope", null, null));
    try record_status.addArg(Arg.booleanOption("json", 'j', null));

    var record_toggle = app.createCommand("toggle", "Toggle background recording");
    try record_toggle.addArg(Arg.singleValueOption("scope", null, null));
    try record_toggle.addArg(Arg.singleValueOption("uuid", 'u', null));
    try record_toggle.addArg(Arg.singleValueOption("name", 'n', null));
    try record_toggle.addArg(Arg.singleValueOption("socket", 's', null));
    try record_toggle.addArg(Arg.singleValueOption("out", 'o', null));
    try record_toggle.addArg(Arg.booleanOption("capture-input", null, null));
    try record_cmd.addSubcommands(&[_]yazap.Command{ record_start, record_stop, record_status, record_toggle });

    try root.addSubcommands(&[_]yazap.Command{ ses_cmd, layout_cmd, pod_cmd, mux_cmd, shp_cmd, pop_cmd, record_cmd, config_cmd });

    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    var normalized_args: std.ArrayList([:0]const u8) = .empty;
    defer normalized_args.deinit(allocator);

    var owned_alias_args: std.ArrayList([:0]u8) = .empty;
    defer {
        for (owned_alias_args.items) |item| allocator.free(item);
        owned_alias_args.deinit(allocator);
    }

    if (hasHelpFlag(raw_args)) {
        const cmd = if (firstCommandToken(raw_args)) |token| normalizeTopLevelCommand(token) else null;
        if (cmd) |name| {
            printHelpCommand(name);
        } else {
            printHelpRoot();
        }
        return;
    }

    for (raw_args[1..], 0..) |arg, idx| {
        const mapped = if (idx == 0) normalizeTopLevelCommand(arg) else arg;
        if (!std.mem.eql(u8, mapped, arg)) {
            const duped = try allocator.dupeZ(u8, mapped);
            try owned_alias_args.append(allocator, duped);
            try normalized_args.append(allocator, duped);
        } else {
            try normalized_args.append(allocator, arg);
        }
    }

    const matches = try app.parseFrom(normalized_args.items);

    if (!matches.containsArgs()) {
        var has_local_layout = false;
        if (std.fs.cwd().access(".hexe.lua", .{})) |_| {
            has_local_layout = true;
        } else |_| {}
        if (has_local_layout and shouldLoadLocalLayoutPrompt()) {
            if (askUseLocalLayout()) {
                try cli_cmds.runSesOpen(allocator, ".", false, "", "");
                return;
            }
        }

        try runMuxNew("", false, "", "", false);
        return;
    }

    if (matches.subcommandMatches("session")) |ses_matches| {
        if (ses_matches.subcommandMatches("daemon")) |m| {
            const instance = m.getSingleValue("instance") orelse "";
            if (instance.len > 0) setInstanceFromCli(instance);
            if (m.containsArg("test-only")) {
                setTestOnlyEnv();
                if (!hasInstanceEnv()) {
                    print("Error: --test-only requires --instance or HEXE_INSTANCE\n", .{});
                    return;
                }
            }
            try runSesDaemon(m.containsArg("foreground"), m.containsArg("debug"), m.getSingleValue("logfile") orelse "");
            return;
        }
        if (ses_matches.subcommandMatches("status")) |m| {
            const instance = m.getSingleValue("instance") orelse "";
            if (instance.len > 0) setInstanceFromCli(instance);
            try runSesStatus(allocator);
            return;
        }
        if (ses_matches.subcommandMatches("list")) |m| {
            const instance = m.getSingleValue("instance") orelse "";
            if (instance.len > 0) setInstanceFromCli(instance);
            try cli_cmds.runList(allocator, m.containsArg("details"), m.containsArg("json"));
            return;
        }
        if (ses_matches.subcommandMatches("kill")) |m| {
            const instance = m.getSingleValue("instance") orelse "";
            if (instance.len > 0) setInstanceFromCli(instance);
            try cli_cmds.runSesKill(allocator, m.getSingleValue("target") orelse "");
            return;
        }
        if (ses_matches.subcommandMatches("clear")) |m| {
            const instance = m.getSingleValue("instance") orelse "";
            if (instance.len > 0) setInstanceFromCli(instance);
            try cli_cmds.runSesClear(allocator, m.containsArg("force"));
            return;
        }
        if (ses_matches.subcommandMatches("export")) |m| {
            const instance = m.getSingleValue("instance") orelse "";
            if (instance.len > 0) setInstanceFromCli(instance);
            try ses_export.run(allocator, m.getSingleValue("session") orelse "", m.getSingleValue("output") orelse "");
            return;
        }
        if (ses_matches.subcommandMatches("stats")) |m| {
            const instance = m.getSingleValue("instance") orelse "";
            if (instance.len > 0) setInstanceFromCli(instance);
            try ses_stats.run(allocator);
            return;
        }
    } else if (matches.subcommandMatches("layout")) |layout_matches| {
        if (layout_matches.subcommandMatches("list")) |m| {
            try cli_cmds.runSessionLayoutList(allocator, m.containsArg("json"));
            return;
        }
        if (layout_matches.subcommandMatches("open")) |m| {
            const instance = m.getSingleValue("instance") orelse "";
            if (instance.len > 0) setInstanceFromCli(instance);
            try cli_cmds.runSesOpen(
                allocator,
                m.getSingleValue("target") orelse ".",
                m.containsArg("debug"),
                m.getSingleValue("logfile") orelse "",
                instance,
            );
            return;
        }
        if (layout_matches.subcommandMatches("save")) |m| {
            const instance = m.getSingleValue("instance") orelse "";
            if (instance.len > 0) setInstanceFromCli(instance);
            const scope_raw = m.getSingleValue("scope") orelse "both";
            const scope = std.meta.stringToEnum(cli_cmds.LayoutSaveScope, scope_raw) orelse {
                print("Error: invalid --scope (use local|global|both)\n", .{});
                return;
            };
            try cli_cmds.runSesFreeze(allocator, scope);
            return;
        }
    } else if (matches.subcommandMatches("pod")) |pod_matches| {
        if (pod_matches.subcommandMatches("daemon")) |m| {
            const instance = m.getSingleValue("instance") orelse "";
            if (instance.len > 0) setInstanceFromCli(instance);
            if (m.containsArg("test-only")) {
                setTestOnlyEnv();
                if (!hasInstanceEnv()) {
                    print("Error: --test-only requires --instance or HEXE_INSTANCE\n", .{});
                    return;
                }
            }
            try runPodDaemon(
                m.containsArg("foreground"),
                m.getSingleValue("uuid") orelse "",
                m.getSingleValue("name") orelse "",
                m.getSingleValue("socket") orelse "",
                m.getSingleValue("shell") orelse "",
                m.getSingleValue("cwd") orelse "",
                m.getSingleValue("labels") orelse "",
                m.containsArg("write-meta"),
                m.containsArg("no-write-meta"),
                m.containsArg("write-alias"),
                m.containsArg("debug"),
                m.getSingleValue("logfile") orelse "",
            );
            return;
        }
        if (pod_matches.subcommandMatches("list")) |m| {
            const alive_only = m.containsArg("alive");
            const probe = m.containsArg("probe") or alive_only;
            try cli_cmds.runPodList(allocator, m.getSingleValue("where") orelse "", probe, alive_only, m.containsArg("json"));
            return;
        }
        if (pod_matches.subcommandMatches("new")) |m| {
            const instance = m.getSingleValue("instance") orelse "";
            if (instance.len > 0) setInstanceFromCli(instance);
            if (m.containsArg("test-only")) {
                setTestOnlyEnv();
                if (!hasInstanceEnv()) {
                    print("Error: --test-only requires --instance or HEXE_INSTANCE\n", .{});
                    return;
                }
            }
            try cli_cmds.runPodNew(
                allocator,
                m.getSingleValue("name") orelse "",
                m.getSingleValue("shell") orelse "",
                m.getSingleValue("cwd") orelse "",
                m.getSingleValue("labels") orelse "",
                m.containsArg("alias"),
                m.containsArg("debug"),
                m.getSingleValue("logfile") orelse "",
            );
            return;
        }
        if (pod_matches.subcommandMatches("send")) |m| {
            try cli_cmds.runPodSend(
                allocator,
                m.getSingleValue("uuid") orelse "",
                m.getSingleValue("name") orelse "",
                m.getSingleValue("socket") orelse "",
                m.containsArg("enter"),
                m.getSingleValue("ctrl") orelse "",
                m.getSingleValue("text") orelse "",
            );
            return;
        }
        if (pod_matches.subcommandMatches("attach")) |m| {
            try cli_cmds.runPodAttach(
                allocator,
                m.getSingleValue("uuid") orelse "",
                m.getSingleValue("name") orelse "",
                m.getSingleValue("socket") orelse "",
                m.getSingleValue("detach") orelse "",
                m.getSingleValue("record") orelse "",
                m.containsArg("capture-input"),
            );
            return;
        }
        if (pod_matches.subcommandMatches("record")) |m| {
            const out = m.getSingleValue("out") orelse "";
            if (out.len == 0) {
                print("Error: --out is required for pod record\n", .{});
                return;
            }
            try cli_cmds.runPodRecord(
                allocator,
                m.getSingleValue("uuid") orelse "",
                m.getSingleValue("name") orelse "",
                m.getSingleValue("socket") orelse "",
                out,
                m.containsArg("capture-input"),
            );
            return;
        }
        if (pod_matches.subcommandMatches("kill")) |m| {
            try cli_cmds.runPodKill(
                allocator,
                m.getSingleValue("uuid") orelse "",
                m.getSingleValue("name") orelse "",
                m.getSingleValue("signal") orelse "",
                m.containsArg("force"),
            );
            return;
        }
        if (pod_matches.subcommandMatches("gc")) |m| {
            try cli_cmds.runPodGc(allocator, m.containsArg("dry-run"));
            return;
        }
    } else if (matches.subcommandMatches("multiplexer")) |mux_matches| {
        if (mux_matches.subcommandMatches("new")) |m| {
            const instance = m.getSingleValue("instance") orelse "";
            if (instance.len > 0) {
                setInstanceFromCli(instance);
                if (m.containsArg("test-only")) setTestOnlyEnv();
            } else if (m.containsArg("test-only")) {
                setGeneratedTestInstance();
            }
            try runMuxNew(
                m.getSingleValue("name") orelse "",
                m.containsArg("debug"),
                m.getSingleValue("logfile") orelse "",
                m.getSingleValue("ses-socket") orelse "",
                m.containsArg("no-autostart-ses"),
            );
            return;
        }
        if (mux_matches.subcommandMatches("attach")) |m| {
            const instance = m.getSingleValue("instance") orelse "";
            if (instance.len > 0) setInstanceFromCli(instance);
            try runMuxAttach(
                m.getSingleValue("name") orelse "",
                m.containsArg("debug"),
                m.getSingleValue("logfile") orelse "",
                m.getSingleValue("ses-socket") orelse "",
                m.containsArg("no-autostart-ses"),
            );
            return;
        }
        if (mux_matches.subcommandMatches("record")) |m| {
            const instance = m.getSingleValue("instance") orelse "";
            if (instance.len > 0) setInstanceFromCli(instance);
            const out = m.getSingleValue("out") orelse "";
            if (out.len == 0) {
                print("Error: --out is required for mux record\n", .{});
                return;
            }
            try cli_cmds.runMuxRecord(out, m.containsArg("capture-input"));
            return;
        }
        if (mux_matches.subcommandMatches("float")) |m| {
            const instance = m.getSingleValue("instance") orelse "";
            if (instance.len > 0) setInstanceFromCli(instance);
            const exit_key = m.getSingleValue("key") orelse "Esc";
            try cli_cmds.runMuxFloat(
                allocator,
                m.getSingleValue("command") orelse "",
                m.getSingleValue("title") orelse "",
                m.getSingleValue("cwd") orelse "",
                m.getSingleValue("result-file") orelse "",
                m.containsArg("pass-env"),
                m.getSingleValue("extra-env") orelse "",
                m.containsArg("isolated"),
                m.getSingleValue("isolation") orelse "",
                m.getSingleValue("size") orelse "",
                m.containsArg("focus"),
                exit_key,
            );
            return;
        }
        if (mux_matches.subcommandMatches("notify")) |m| {
            const instance = m.getSingleValue("instance") orelse "";
            if (instance.len > 0) setInstanceFromCli(instance);
            try cli_cmds.runNotify(
                allocator,
                m.getSingleValue("uuid") orelse "",
                m.containsArg("creator"),
                m.containsArg("last"),
                m.containsArg("broadcast"),
                m.getSingleValue("message") orelse "",
            );
            return;
        }
        if (mux_matches.subcommandMatches("send")) |m| {
            const instance = m.getSingleValue("instance") orelse "";
            if (instance.len > 0) setInstanceFromCli(instance);
            try cli_cmds.runSend(
                allocator,
                m.getSingleValue("uuid") orelse "",
                m.containsArg("creator"),
                m.containsArg("last"),
                m.containsArg("broadcast"),
                m.containsArg("enter"),
                m.getSingleValue("ctrl") orelse "",
                m.getSingleValue("text") orelse "",
            );
            return;
        }
        if (mux_matches.subcommandMatches("layout")) |m| {
            if (m.subcommandMatches("save")) |save_matches| {
                try cli_cmds.runLayoutSave(allocator, save_matches.getSingleValue("name") orelse "");
                return;
            }
            if (m.subcommandMatches("load")) |load_matches| {
                try cli_cmds.runLayoutLoad(allocator, load_matches.getSingleValue("name") orelse "");
                return;
            }
            if (m.subcommandMatches("list")) |_| {
                try cli_cmds.runLayoutList(allocator);
                return;
            }
        }
        if (mux_matches.subcommandMatches("focus")) |m| {
            try cli_cmds.runFocusMove(allocator, m.getSingleValue("dir") orelse "");
            return;
        }
        if (mux_matches.subcommandMatches("info")) |m| {
            const instance = m.getSingleValue("instance") orelse "";
            if (instance.len > 0) setInstanceFromCli(instance);
            try cli_cmds.runInfo(allocator, m.getSingleValue("uuid") orelse "", m.containsArg("creator"), m.containsArg("last"));
            return;
        }
    } else if (matches.subcommandMatches("shell")) |shp_matches| {
        if (shp_matches.subcommandMatches("prompt")) |m| {
            const status = try parseOptionalI64(m.getSingleValue("status"), "status");
            const duration = try parseOptionalI64(m.getSingleValue("duration"), "duration");
            const jobs = try parseOptionalI64(m.getSingleValue("jobs"), "jobs");
            try runShpPrompt(status, duration, m.containsArg("right"), m.getSingleValue("shell") orelse "", jobs);
            return;
        }
        if (shp_matches.subcommandMatches("init")) |m| {
            try runShpInit(m.getSingleValue("shell") orelse "", m.containsArg("no-comms"));
            return;
        }
        if (shp_matches.subcommandMatches("exit-intent")) |_| {
            try cli_cmds.runExitIntent(allocator);
            return;
        }
        if (shp_matches.subcommandMatches("shell-event")) |m| {
            const status = try parseOptionalI64(m.getSingleValue("status"), "status");
            const duration = try parseOptionalI64(m.getSingleValue("duration"), "duration");
            const jobs = try parseOptionalI64(m.getSingleValue("jobs"), "jobs");
            const started_at = try parseOptionalI64(m.getSingleValue("started-at"), "started-at");
            try cli_cmds.runShellEvent(
                m.getSingleValue("cmd") orelse "",
                status,
                duration,
                m.getSingleValue("cwd") orelse "",
                jobs,
                m.getSingleValue("phase") orelse "",
                m.containsArg("running"),
                started_at,
            );
            return;
        }
        if (shp_matches.subcommandMatches("spinner")) |m| {
            const width = try parseOptionalI64(m.getSingleValue("width"), "width");
            const interval = try parseOptionalI64(m.getSingleValue("interval"), "interval");
            const hold = try parseOptionalI64(m.getSingleValue("hold"), "hold");
            try runShpSpinner(m.getSingleValue("name") orelse "", width, interval, hold, m.containsArg("loop"));
            return;
        }
    } else if (matches.subcommandMatches("popup")) |pop_matches| {
        if (pop_matches.subcommandMatches("notify")) |m| {
            const timeout = try parseOptionalI64(m.getSingleValue("timeout"), "timeout");
            try pop_handlers.runPopNotify(allocator, m.getSingleValue("uuid") orelse "", timeout, m.getSingleValue("message") orelse "");
            return;
        }
        if (pop_matches.subcommandMatches("confirm")) |m| {
            const timeout = try parseOptionalI64(m.getSingleValue("timeout"), "timeout");
            try pop_handlers.runPopConfirm(allocator, m.getSingleValue("uuid") orelse "", timeout, m.getSingleValue("message") orelse "");
            return;
        }
        if (pop_matches.subcommandMatches("choose")) |m| {
            const timeout = try parseOptionalI64(m.getSingleValue("timeout"), "timeout");
            try pop_handlers.runPopChoose(allocator, m.getSingleValue("uuid") orelse "", timeout, m.getSingleValue("items") orelse "", m.getSingleValue("message") orelse "");
            return;
        }
    } else if (matches.subcommandMatches("record")) |record_matches| {
        if (record_matches.subcommandMatches("start")) |m| {
            try cli_cmds.runRecordStart(
                allocator,
                m.getSingleValue("scope") orelse "pod",
                "",
                m.getSingleValue("uuid") orelse "",
                m.getSingleValue("name") orelse "",
                m.getSingleValue("socket") orelse "",
                m.getSingleValue("out") orelse "",
                m.containsArg("capture-input"),
            );
            return;
        }
        if (record_matches.subcommandMatches("stop")) |m| {
            try cli_cmds.runRecordStop(allocator, m.getSingleValue("scope") orelse "pod");
            return;
        }
        if (record_matches.subcommandMatches("status")) |m| {
            try cli_cmds.runRecordStatus(allocator, m.getSingleValue("scope") orelse "pod", m.containsArg("json"));
            return;
        }
        if (record_matches.subcommandMatches("toggle")) |m| {
            try cli_cmds.runRecordToggle(
                allocator,
                m.getSingleValue("scope") orelse "pod",
                "",
                m.getSingleValue("uuid") orelse "",
                m.getSingleValue("name") orelse "",
                m.getSingleValue("socket") orelse "",
                m.getSingleValue("out") orelse "",
                m.containsArg("capture-input"),
            );
            return;
        }
    } else if (matches.subcommandMatches("config")) |config_matches| {
        if (config_matches.subcommandMatches("validate")) |_| {
            try config_validate.run();
            return;
        }
    }
}

fn runSesDaemon(foreground: bool, debug: bool, log_file: []const u8) !void {
    const log: ?[]const u8 = if (log_file.len > 0) log_file else null;
    try ses.run(.{
        .daemon = !foreground,
        .debug = debug,
        .log_file = log,
    });
}

fn runSesStatus(allocator: std.mem.Allocator) !void {
    const socket_path = try ipc.getSesSocketPath(allocator);
    defer allocator.free(socket_path);

    var client = ipc.Client.connect(socket_path) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            print("ses daemon is not running\n", .{});
            return;
        }
        return err;
    };
    defer client.close();

    print("ses daemon running at: {s}\n", .{socket_path});
}

fn runPodDaemon(
    foreground: bool,
    uuid: []const u8,
    name: []const u8,
    socket_path: []const u8,
    shell: []const u8,
    cwd: []const u8,
    labels: []const u8,
    write_meta: bool,
    no_write_meta: bool,
    write_alias: bool,
    debug: bool,
    log_file: []const u8,
) !void {
    if (uuid.len == 0 or socket_path.len == 0) {
        print("Error: --uuid and --socket required\n", .{});
        return;
    }

    const effective_write_meta = if (no_write_meta) false else if (write_meta) true else true;

    try pod.run(.{
        .daemon = !foreground,
        .uuid = uuid,
        .name = if (name.len > 0) name else null,
        .socket_path = socket_path,
        .shell = if (shell.len > 0) shell else null,
        .cwd = if (cwd.len > 0) cwd else null,
        .labels = if (labels.len > 0) labels else null,
        .write_meta = effective_write_meta,
        .write_alias = write_alias,
        .debug = debug,
        .log_file = if (log_file.len > 0) log_file else null,
        .emit_ready = foreground,
    });
}

fn showNestedMuxConfirmation(pane_uuid: []const u8) !bool {
    const wire = core.wire;
    const posix = std.posix;

    var target_uuid: [32]u8 = undefined;
    @memcpy(&target_uuid, pane_uuid[0..32]);

    const allocator = std.heap.page_allocator;
    const fd = cli_cmds.connectSesCliChannel(allocator) orelse return false;

    const message = "Start nested mux session?";
    const timeout_ms: i32 = 0;

    const pc = wire.PopConfirm{
        .uuid = target_uuid,
        .timeout_ms = timeout_ms,
        .msg_len = @intCast(message.len),
    };

    wire.writeControlWithTrail(fd, .pop_confirm, std.mem.asBytes(&pc), message) catch {
        posix.close(fd);
        return false;
    };

    const hdr = wire.readControlHeader(fd) catch {
        posix.close(fd);
        return false;
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type != .pop_response or hdr.payload_len < @sizeOf(wire.PopResponse)) {
        posix.close(fd);
        return false;
    }
    const resp = wire.readStruct(wire.PopResponse, fd) catch {
        posix.close(fd);
        return false;
    };
    posix.close(fd);

    return resp.response_type == 1;
}

fn shouldLoadLocalLayoutPrompt() bool {
    if (std.posix.getenv("HEXE_SKIP_LOCAL_CONFIG")) |v| {
        return !std.mem.eql(u8, v, "1");
    }
    return true;
}

fn askUseLocalLayout() bool {
    const stdin_fd = std.posix.STDIN_FILENO;
    const stdout_fd = std.posix.STDOUT_FILENO;
    if (!std.posix.isatty(stdin_fd) or !std.posix.isatty(stdout_fd)) return true;

    const stdout = std.fs.File.stdout();
    stdout.writeAll("Local .hexe.lua found. Load local layout? [Y/n]: ") catch return true;

    var line_buf: [32]u8 = undefined;
    const n = std.posix.read(stdin_fd, line_buf[0..]) catch return true;
    if (n == 0) return true;
    const line = std.mem.trim(u8, line_buf[0..n], " \t\r\n");
    if (line.len == 0) return true;
    if (std.ascii.eqlIgnoreCase(line, "y") or std.ascii.eqlIgnoreCase(line, "yes")) return true;
    return false;
}

fn buildMuxTransport(socket_path: []const u8, no_autostart_ses: bool) core.FrontendTransport {
    return core.FrontendTransportHelpers.localIpcTransport(
        if (socket_path.len > 0) socket_path else null,
        !no_autostart_ses,
    );
}

fn runMuxNew(name: []const u8, debug: bool, log_file: []const u8, socket_path: []const u8, no_autostart_ses: bool) !void {
    if (std.posix.getenv("HEXE_PANE_UUID")) |pane_uuid| {
        if (pane_uuid.len >= 32) {
            if (!try showNestedMuxConfirmation(pane_uuid)) {
                return;
            }
        }
    }

    try terminal.run(.{
        .name = if (name.len > 0) name else null,
        .debug = debug,
        .log_file = if (log_file.len > 0) log_file else null,
        .transport = buildMuxTransport(socket_path, no_autostart_ses),
    });
}

fn runMuxAttach(name: []const u8, debug: bool, log_file: []const u8, socket_path: []const u8, no_autostart_ses: bool) !void {
    if (name.len > 0) {
        try terminal.run(.{
            .attach = name,
            .debug = debug,
            .log_file = if (log_file.len > 0) log_file else null,
            .transport = buildMuxTransport(socket_path, no_autostart_ses),
        });
    } else {
        print("Error: session name required\n", .{});
    }
}

fn runShpPrompt(status: i64, duration: i64, right: bool, shell: []const u8, jobs: i64) !void {
    try shp.run(.{
        .prompt = true,
        .status = status,
        .duration = duration,
        .right = right,
        .shell = if (shell.len > 0) shell else null,
        .jobs = jobs,
    });
}

fn runShpInit(shell: []const u8, no_comms: bool) !void {
    if (shell.len > 0) {
        try shp.run(.{ .init_shell = shell, .no_comms = no_comms });
    } else {
        print("Error: shell name required (bash, zsh, fish)\n", .{});
    }
}

fn runShpSpinner(name: []const u8, width_i: i64, interval_i: i64, hold_i: i64, loop: bool) !void {
    const stdout = std.fs.File.stdout();

    if (name.len == 0) {
        print("Error: spinner name required\n", .{});
        return;
    }

    const width: u8 = if (width_i > 0 and width_i <= 64) @intCast(width_i) else 8;
    const interval_ms: u64 = if (interval_i > 0 and interval_i <= 10_000) @intCast(interval_i) else 75;
    const hold_frames: u8 = if (hold_i >= 0 and hold_i <= 60) @intCast(hold_i) else 9;

    const start_ms: u64 = @intCast(std.time.milliTimestamp());

    if (!loop) {
        const now_ms: u64 = start_ms;
        const frame = shp.animations.renderAnsiWithOptions(name, now_ms, start_ms, width, interval_ms, hold_frames);
        try stdout.writeAll(frame);
        try stdout.writeAll("\n");
        return;
    }

    while (true) {
        const now_ms: u64 = @intCast(std.time.milliTimestamp());
        const frame = shp.animations.renderAnsiWithOptions(name, now_ms, start_ms, width, interval_ms, hold_frames);

        stdout.writeAll("\r") catch break;
        stdout.writeAll(frame) catch break;
        stdout.writeAll("\x1b[0K") catch break;
        std.Thread.sleep(interval_ms * std.time.ns_per_ms);
    }

    stdout.writeAll("\r\n") catch {};
}
