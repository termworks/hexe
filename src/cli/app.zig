const std = @import("std");
const yazap = @import("yazap");
const core = @import("core");
const frontend_core = @import("frontend_core");
const ipc = core.ipc;
const terminal = @import("terminal");
const web_frontend = @import("web");
const syslink_frontend = @import("syslink");
const ses = @import("ses");
const pod = @import("pod");
const shp = @import("shp");
const pop_handlers = @import("pop_handlers.zig");
const cli_cmds = @import("commands/com.zig");
const config_validate = @import("commands/config_validate.zig");
const ses_export = @import("commands/ses_export.zig");
const ses_pipe = @import("commands/ses_pipe.zig");
const ses_stats = @import("commands/ses_stats.zig");

const c = @cImport({
    @cInclude("stdlib.h");
});

const App = yazap.App;
const Arg = yazap.Arg;
const print = std.debug.print;

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = core.logging.stdLogFn,
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

fn parseCliLogLevel(value: ?[]const u8) !?core.logging.Level {
    if (value) |raw| {
        const level = core.logging.parseLevel(raw) orelse {
            print("Error: invalid --log level '{s}' (use trace|debug|info)\n", .{raw});
            return error.InvalidArgument;
        };
        if (level != .trace and level != .debug and level != .info) {
            print("Error: invalid --log level '{s}' (use trace|debug|info)\n", .{raw});
            return error.InvalidArgument;
        }
        return level;
    }
    return null;
}

fn printFrontendViewSummary(kind: []const u8, view: *const frontend_core.SessionView) void {
    print("{s} frontend snapshot\n", .{kind});
    print("  session: {s} name={s}\n", .{ view.session_uuid[0..8], view.session_name });
    if (view.base_root) |root| {
        print("  base_root: {s}\n", .{root});
    } else {
        print("  base_root: -\n", .{});
    }
    print("  active_tab: {d}\n", .{view.active_tab});
    print("  tabs: {d}\n", .{view.tabs.items.len});
    print("  panes: {d}\n", .{view.panes.items.len});
    print("  floats: {d}\n", .{view.floats.items.len});
    for (view.tabs.items, 0..) |tab, idx| {
        print("    tab[{d}]: {s} name={s} layout={}\n", .{ idx, tab.uuid[0..8], tab.name, tab.hasLayout() });
    }
    for (view.panes.items, 0..) |pane, idx| {
        print("    pane[{d}]: {s} kind={s} parent_tab={?d} sticky={} pwd={} key={d}\n", .{
            idx,
            pane.uuid[0..8],
            @tagName(pane.kind),
            pane.parent_tab,
            pane.sticky,
            pane.is_pwd,
            pane.float_key,
        });
    }
}

fn runWebInspectSnapshot(allocator: std.mem.Allocator, snapshot_path: []const u8) !void {
    if (snapshot_path.len == 0) {
        print("Error: snapshot path is required\n", .{});
        return error.InvalidArgument;
    }
    const json = try std.fs.cwd().readFileAlloc(allocator, snapshot_path, 16 * 1024 * 1024);
    defer allocator.free(json);

    var host = web_frontend.WebHost.init(allocator);
    defer host.deinit();
    try host.applySessionStateJson(json);
    printFrontendViewSummary("web", &host.current_view.?);
}

fn printFrontendProbeSummary(kind: []const u8, caps: frontend_core.HostCapabilities, runtime: *core.FrontendRuntime) void {
    print("{s} frontend probe\n", .{kind});
    print("  session: {s} name={s}\n", .{ runtime.sessionUuid()[0..8], runtime.sessionName() });
    print("  base_root: {s}\n", .{runtime.baseRoot()});
    print("  capabilities:\n", .{});
    print("    cell_render: {}\n", .{caps.cell_render});
    print("    pixel_render: {}\n", .{caps.pixel_render});
    print("    mouse: {}\n", .{caps.mouse});
    print("    clipboard: {}\n", .{caps.clipboard});
    print("    reconnect: {}\n", .{caps.reconnect});
    print("    remote_transport: {}\n", .{caps.remote_transport});
}

fn runFrontendServe(
    allocator: std.mem.Allocator,
    kind: []const u8,
    frontend_kind: core.FrontendKind,
    caps: frontend_core.HostCapabilities,
    socket_path: []const u8,
    no_autostart_ses: bool,
) !void {
    var session = try frontend_core.FrontendHostSession.create(
        allocator,
        core.ipc.generateUuid(),
        kind,
        frontend_kind,
        core.FrontendTransportHelpers.resolveTransport(.{
            .socket_path = if (socket_path.len > 0) socket_path else null,
            .autostart_ses = !no_autostart_ses,
        }),
    );
    defer session.deinit();

    var startup_attach = try session.attach();
    defer startup_attach.deinit(allocator);

    print("{s} frontend serve ready\n", .{kind});
    printFrontendProbeSummary(kind, caps, session.runtime);
    if (session.view) |*view| printFrontendViewSummary(kind, view);
    print("{s} host protocol: tick | render | resize <cols> <rows> | close | disconnect | exit\n", .{kind});

    var in_buf: [4096]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(&in_buf);
    while (true) {
        const line = stdin.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const action = frontend_core.parseHostProtocolLine(line) catch |err| {
            print("{s} protocol error: {s}\n", .{ kind, @errorName(err) });
            continue;
        };
        switch (action) {
            .host_event => |event| {
                try session.applyHostEvent(event);
                if (session.takeStopRequest()) |stop| {
                    print("{s} stop: {s} detach={}\n", .{ kind, @tagName(stop.kind), stop.detach });
                    break;
                }
            },
            .render => {
                try session.refreshViewFromRuntime();
                if (session.view) |*view| printFrontendViewSummary(kind, view);
            },
            .exit => break,
        }
    }
}

fn runWebProbe(allocator: std.mem.Allocator, socket_path: []const u8, no_autostart_ses: bool) !void {
    var host = web_frontend.WebHost.init(allocator);
    defer host.deinit();

    var session = try frontend_core.FrontendHostSession.create(
        allocator,
        core.ipc.generateUuid(),
        "web",
        .web,
        core.FrontendTransportHelpers.resolveTransport(.{
            .socket_path = if (socket_path.len > 0) socket_path else null,
            .autostart_ses = !no_autostart_ses,
        }),
    );
    defer session.deinit();

    var startup_attach = try session.attach();
    defer startup_attach.deinit(allocator);
    if (session.view) |*view| {
        host.current_view = try frontend_core.SessionView.fromRuntime(allocator, session.runtime);
        _ = view;
    }
    printFrontendProbeSummary("web", web_frontend.WebHost.capabilities(), session.runtime);
    if (host.current_view) |*view| printFrontendViewSummary("web", view);
}

fn runWebServe(allocator: std.mem.Allocator, socket_path: []const u8, no_autostart_ses: bool) !void {
    try runFrontendServe(
        allocator,
        "web",
        .web,
        web_frontend.WebHost.capabilities(),
        socket_path,
        no_autostart_ses,
    );
}

fn runSyslinkInspectSnapshot(allocator: std.mem.Allocator, snapshot_path: []const u8) !void {
    if (snapshot_path.len == 0) {
        print("Error: snapshot path is required\n", .{});
        return error.InvalidArgument;
    }
    const json = try std.fs.cwd().readFileAlloc(allocator, snapshot_path, 16 * 1024 * 1024);
    defer allocator.free(json);

    var host = syslink_frontend.SyslinkHost.init(allocator);
    defer host.deinit();
    try host.applySessionStateJson(json);
    printFrontendViewSummary("syslink", &host.current_view.?);
}

fn runSyslinkProbe(allocator: std.mem.Allocator, socket_path: []const u8, no_autostart_ses: bool) !void {
    var host = syslink_frontend.SyslinkHost.init(allocator);
    defer host.deinit();

    var session = try frontend_core.FrontendHostSession.create(
        allocator,
        core.ipc.generateUuid(),
        "syslink",
        .desktop,
        core.FrontendTransportHelpers.resolveTransport(.{
            .socket_path = if (socket_path.len > 0) socket_path else null,
            .autostart_ses = !no_autostart_ses,
        }),
    );
    defer session.deinit();

    var startup_attach = try session.attach();
    defer startup_attach.deinit(allocator);
    if (session.view) |*view| {
        host.current_view = try frontend_core.SessionView.fromRuntime(allocator, session.runtime);
        _ = view;
    }
    printFrontendProbeSummary("syslink", syslink_frontend.SyslinkHost.capabilities(), session.runtime);
    if (host.current_view) |*view| printFrontendViewSummary("syslink", view);
}

fn runSyslinkServe(allocator: std.mem.Allocator, socket_path: []const u8, no_autostart_ses: bool) !void {
    try runFrontendServe(
        allocator,
        "syslink",
        .desktop,
        syslink_frontend.SyslinkHost.capabilities(),
        socket_path,
        no_autostart_ses,
    );
}

fn normalizeTopLevelCommand(command: []const u8) []const u8 {
    if (std.mem.eql(u8, command, "ses")) return "session";
    if (std.mem.eql(u8, command, "lay")) return "layout";
    if (std.mem.eql(u8, command, "mux")) return "terminal";
    if (std.mem.eql(u8, command, "multiplexer")) return "terminal";
    if (std.mem.eql(u8, command, "shp")) return "shell";
    if (std.mem.eql(u8, command, "pop")) return "popup";
    if (std.mem.eql(u8, command, "cfg")) return "config";
    return command;
}

fn ensureArgDescriptions(command: *yazap.Command) void {
    for (command.options.items) |*option| {
        if (option.description == null) {
            option.description = option.name;
        }
    }
    for (command.positional_args.items) |*arg| {
        if (arg.description == null) {
            arg.description = arg.name;
        }
    }
    for (command.subcommands.items) |*subcommand| {
        ensureArgDescriptions(subcommand);
    }
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

    var terminal_cmd = app.createCommand("terminal", "Terminal frontend");
    terminal_cmd.setProperty(.help_on_empty_args);

    var web_cmd = app.createCommand("web", "Web frontend adapter");
    web_cmd.setProperty(.help_on_empty_args);

    var syslink_cmd = app.createCommand("syslink", "Syslink remote frontend adapter");
    syslink_cmd.setProperty(.help_on_empty_args);

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
    try ses_daemon.addArg(Arg.singleValueOption("log", null, null));
    try ses_daemon.addArg(Arg.singleValueOption("logfile", 'L', null));
    try ses_daemon.addArg(Arg.singleValueOption("instance", 'I', null));
    try ses_daemon.addArg(Arg.booleanOption("test-only", 'T', null));

    var ses_status_cmd = app.createCommand("status", "Show daemon info");
    try ses_status_cmd.addArg(Arg.singleValueOption("instance", 'I', null));

    var ses_list = app.createCommand("list", "List sessions and panes (optionally filtered to a directory)");
    try ses_list.addArg(Arg.positional("dir", null, null));
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

    var ses_pipe_cmd = app.createCommand("pipe", "Internal SES byte-stream bridge");
    try ses_pipe_cmd.addArg(Arg.singleValueOption("ses-socket", null, null));

    try ses_cmd.addSubcommands(&[_]yazap.Command{
        ses_daemon,
        ses_status_cmd,
        ses_list,
        ses_kill,
        ses_clear,
        ses_export_cmd,
        ses_stats_cmd,
        ses_pipe_cmd,
    });

    var layout_list = app.createCommand("list", "List saved session layouts");
    try layout_list.addArg(Arg.booleanOption("json", 'j', null));

    var layout_open = app.createCommand("open", "Open a saved session layout");
    try layout_open.addArg(Arg.positional("target", null, null));
    try layout_open.addArg(Arg.singleValueOption("log", null, null));
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
    try pod_daemon.addArg(Arg.singleValueOption("log", null, null));
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
    try pod_new.addArg(Arg.singleValueOption("log", null, null));
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
    var mux_new = app.createCommand("new", "Create new terminal session");
    try mux_new.addArg(Arg.singleValueOption("name", 'n', null));
    try mux_new.addArg(Arg.singleValueOption("log", null, null));
    try mux_new.addArg(Arg.singleValueOption("logfile", 'L', null));
    try mux_new.addArg(Arg.singleValueOption("ses-socket", null, null));
    try mux_new.addArg(Arg.booleanOption("no-autostart-ses", null, null));
    try mux_new.addArg(Arg.singleValueOption("instance", 'I', null));
    try mux_new.addArg(Arg.booleanOption("test-only", 'T', null));
    try mux_new.addArg(Arg.singleValueOption("remote", null, null));
    try mux_new.addArg(Arg.singleValueOption("user", 'u', null));
    try mux_new.addArg(Arg.singleValueOption("identity", 'i', null));

    var mux_attach = app.createCommand("attach", "Attach to existing session");
    try mux_attach.addArg(Arg.positional("name", null, null));
    try mux_attach.addArg(Arg.singleValueOption("log", null, null));
    try mux_attach.addArg(Arg.singleValueOption("logfile", 'L', null));
    try mux_attach.addArg(Arg.singleValueOption("ses-socket", null, null));
    try mux_attach.addArg(Arg.booleanOption("no-autostart-ses", null, null));
    try mux_attach.addArg(Arg.singleValueOption("instance", 'I', null));
    try mux_attach.addArg(Arg.singleValueOption("remote", null, null));
    try mux_attach.addArg(Arg.singleValueOption("user", 'u', null));
    try mux_attach.addArg(Arg.singleValueOption("identity", 'i', null));

    var mux_kill = app.createCommand("kill", "Kill a session (attached or detached) or a single pane/float by name or uuid prefix");
    try mux_kill.addArg(Arg.positional("id", null, null));
    try mux_kill.addArg(Arg.singleValueOption("instance", 'I', null));

    var mux_close = app.createCommand("close", "Alias of kill");
    try mux_close.addArg(Arg.positional("id", null, null));
    try mux_close.addArg(Arg.singleValueOption("instance", 'I', null));

    var mux_record = app.createCommand("record", "Attach to terminal frontend and record asciicast");
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

    try terminal_cmd.addSubcommands(&[_]yazap.Command{ mux_new, mux_attach, mux_kill, mux_close, mux_record, mux_float, mux_notify, mux_send, mux_info, mux_layout, mux_focus });

    var web_inspect = app.createCommand("inspect-snapshot", "Load a session snapshot through the web adapter");
    try web_inspect.addArg(Arg.positional("snapshot", null, null));
    var web_probe = app.createCommand("probe", "Start the web adapter against SES and print frontend state");
    try web_probe.addArg(Arg.singleValueOption("ses-socket", 0, "Path to SES socket"));
    try web_probe.addArg(Arg.booleanOption("no-autostart-ses", 0, "Do not start SES automatically"));
    var web_serve = app.createCommand("serve", "Run the web adapter host-protocol serving loop");
    try web_serve.addArg(Arg.singleValueOption("ses-socket", 0, "Path to SES socket"));
    try web_serve.addArg(Arg.booleanOption("no-autostart-ses", 0, "Do not start SES automatically"));
    try web_cmd.addSubcommands(&[_]yazap.Command{ web_inspect, web_probe, web_serve });

    var syslink_inspect = app.createCommand("inspect-snapshot", "Load a session snapshot through the syslink adapter");
    try syslink_inspect.addArg(Arg.positional("snapshot", null, null));
    var syslink_probe = app.createCommand("probe", "Start the syslink adapter against SES and print frontend state");
    try syslink_probe.addArg(Arg.singleValueOption("ses-socket", 0, "Path to SES socket"));
    try syslink_probe.addArg(Arg.booleanOption("no-autostart-ses", 0, "Do not start SES automatically"));
    var syslink_serve = app.createCommand("serve", "Run the syslink adapter host-protocol serving loop");
    try syslink_serve.addArg(Arg.singleValueOption("ses-socket", 0, "Path to SES socket"));
    try syslink_serve.addArg(Arg.booleanOption("no-autostart-ses", 0, "Do not start SES automatically"));
    try syslink_cmd.addSubcommands(&[_]yazap.Command{ syslink_inspect, syslink_probe, syslink_serve });

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
    const config_check_cmd = app.createCommand("check", "Check configuration file");
    const config_dump_cmd = app.createCommand("dump", "Dump normalized configuration");
    const config_paths_cmd = app.createCommand("paths", "Show configuration search paths");
    try config_cmd.addSubcommands(&[_]yazap.Command{ config_validate_cmd, config_check_cmd, config_dump_cmd, config_paths_cmd });

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

    var allow_cmd = app.createCommand("allow", "Trust a project .hexe.lua so its on_start/on_stop hooks may run");
    try allow_cmd.addArg(Arg.positional("path", null, null));

    try root.addSubcommands(&[_]yazap.Command{ ses_cmd, layout_cmd, pod_cmd, terminal_cmd, web_cmd, syslink_cmd, shp_cmd, pop_cmd, record_cmd, config_cmd, allow_cmd });
    ensureArgDescriptions(root);

    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    var normalized_args: std.ArrayList([:0]const u8) = .empty;
    defer normalized_args.deinit(allocator);

    var owned_alias_args: std.ArrayList([:0]u8) = .empty;
    defer {
        for (owned_alias_args.items) |item| allocator.free(item);
        owned_alias_args.deinit(allocator);
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
        // Bare `hexe`: the frontend asks — in a popup, once it owns the screen —
        // whether to attach to a session already rooted here, then whether to
        // load .hexe.lua. HEXE_SKIP_LOCAL_CONFIG=1 keeps the unattended
        // straight-to-new-session behaviour for scripts.
        try runTerminalNew("", null, "", "", false, .{}, shouldPromptOnStartup());
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
            const log_level = parseCliLogLevel(m.getSingleValue("log")) catch return;
            try runSesDaemon(m.containsArg("foreground"), log_level, m.getSingleValue("logfile") orelse "");
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
            try cli_cmds.runList(allocator, m.containsArg("details"), m.containsArg("json"), m.getSingleValue("dir") orelse "");
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
        if (ses_matches.subcommandMatches("pipe")) |m| {
            try ses_pipe.run(allocator, m.getSingleValue("ses-socket") orelse "");
            return;
        }
    } else if (matches.subcommandMatches("allow")) |m| {
        try runAllow(allocator, m.getSingleValue("path") orelse "");
    } else if (matches.subcommandMatches("layout")) |layout_matches| {
        if (layout_matches.subcommandMatches("list")) |m| {
            try cli_cmds.runSessionLayoutList(allocator, m.containsArg("json"));
            return;
        }
        if (layout_matches.subcommandMatches("open")) |m| {
            const instance = m.getSingleValue("instance") orelse "";
            if (instance.len > 0) setInstanceFromCli(instance);
            const log_level = parseCliLogLevel(m.getSingleValue("log")) catch return;
            try cli_cmds.runSesOpen(
                allocator,
                m.getSingleValue("target") orelse ".",
                log_level,
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
            const log_level = parseCliLogLevel(m.getSingleValue("log")) catch return;
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
                log_level,
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
            const log_level = parseCliLogLevel(m.getSingleValue("log")) catch return;
            try cli_cmds.runPodNew(
                allocator,
                m.getSingleValue("name") orelse "",
                m.getSingleValue("shell") orelse "",
                m.getSingleValue("cwd") orelse "",
                m.getSingleValue("labels") orelse "",
                m.containsArg("alias"),
                log_level,
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
    } else if (matches.subcommandMatches("terminal")) |mux_matches| {
        if (mux_matches.subcommandMatches("new")) |m| {
            const instance = m.getSingleValue("instance") orelse "";
            if (instance.len > 0) {
                setInstanceFromCli(instance);
                if (m.containsArg("test-only")) setTestOnlyEnv();
            } else if (m.containsArg("test-only")) {
                setGeneratedTestInstance();
            }
            const log_level = parseCliLogLevel(m.getSingleValue("log")) catch return;
            try runTerminalNew(
                m.getSingleValue("name") orelse "",
                log_level,
                m.getSingleValue("logfile") orelse "",
                m.getSingleValue("ses-socket") orelse "",
                m.containsArg("no-autostart-ses"),
                .{
                    .remote = m.getSingleValue("remote") orelse "",
                    .user = m.getSingleValue("user") orelse "",
                    .identity = m.getSingleValue("identity") orelse "",
                },
                // `hexe mux new` is always an explicit "give me a new one".
                false,
            );
            return;
        }
        if (mux_matches.subcommandMatches("kill")) |m| {
            const instance = m.getSingleValue("instance") orelse "";
            if (instance.len > 0) setInstanceFromCli(instance);
            try cli_cmds.runTerminalKill(allocator, m.getSingleValue("id") orelse "");
            return;
        }
        if (mux_matches.subcommandMatches("close")) |m| {
            const instance = m.getSingleValue("instance") orelse "";
            if (instance.len > 0) setInstanceFromCli(instance);
            try cli_cmds.runTerminalKill(allocator, m.getSingleValue("id") orelse "");
            return;
        }
        if (mux_matches.subcommandMatches("attach")) |m| {
            const instance = m.getSingleValue("instance") orelse "";
            if (instance.len > 0) setInstanceFromCli(instance);
            const log_level = parseCliLogLevel(m.getSingleValue("log")) catch return;
            try runTerminalAttach(
                m.getSingleValue("name") orelse "",
                log_level,
                m.getSingleValue("logfile") orelse "",
                m.getSingleValue("ses-socket") orelse "",
                m.containsArg("no-autostart-ses"),
                .{
                    .remote = m.getSingleValue("remote") orelse "",
                    .user = m.getSingleValue("user") orelse "",
                    .identity = m.getSingleValue("identity") orelse "",
                },
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
    } else if (matches.subcommandMatches("web")) |web_matches| {
        if (web_matches.subcommandMatches("inspect-snapshot")) |m| {
            try runWebInspectSnapshot(allocator, m.getSingleValue("snapshot") orelse "");
            return;
        }
        if (web_matches.subcommandMatches("probe")) |m| {
            try runWebProbe(
                allocator,
                m.getSingleValue("ses-socket") orelse "",
                m.containsArg("no-autostart-ses"),
            );
            return;
        }
        if (web_matches.subcommandMatches("serve")) |m| {
            try runWebServe(
                allocator,
                m.getSingleValue("ses-socket") orelse "",
                m.containsArg("no-autostart-ses"),
            );
            return;
        }
    } else if (matches.subcommandMatches("syslink")) |syslink_matches| {
        if (syslink_matches.subcommandMatches("inspect-snapshot")) |m| {
            try runSyslinkInspectSnapshot(allocator, m.getSingleValue("snapshot") orelse "");
            return;
        }
        if (syslink_matches.subcommandMatches("probe")) |m| {
            try runSyslinkProbe(
                allocator,
                m.getSingleValue("ses-socket") orelse "",
                m.containsArg("no-autostart-ses"),
            );
            return;
        }
        if (syslink_matches.subcommandMatches("serve")) |m| {
            try runSyslinkServe(
                allocator,
                m.getSingleValue("ses-socket") orelse "",
                m.containsArg("no-autostart-ses"),
            );
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
        } else if (config_matches.subcommandMatches("check")) |_| {
            try config_validate.runCheck();
            return;
        } else if (config_matches.subcommandMatches("dump")) |_| {
            try config_validate.runDump();
            return;
        } else if (config_matches.subcommandMatches("paths")) |_| {
            try config_validate.runPaths();
            return;
        }
    }
}

fn runSesDaemon(foreground: bool, log_level: ?core.logging.Level, log_file: []const u8) !void {
    const log: ?[]const u8 = if (log_file.len > 0) log_file else null;
    try ses.run(.{
        .daemon = !foreground,
        .log_level = log_level,
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
    log_level: ?core.logging.Level,
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
        .log_level = log_level,
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

    // Block UNBOUNDED: this confirm has timeout_ms=0 (waits for the user forever);
    // the 10s wire default aborted the prompt after 10s.
    const hdr = wire.readControlHeaderBlocking(fd) catch {
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

/// Whether bare `hexe` may ask anything at startup (attach / .hexe.lua).
/// HEXE_SKIP_LOCAL_CONFIG=1 opts scripted runs out of both questions.
fn shouldPromptOnStartup() bool {
    if (!std.posix.isatty(std.posix.STDIN_FILENO)) return false;
    if (std.posix.getenv("HEXE_SKIP_LOCAL_CONFIG")) |v| {
        return !std.mem.eql(u8, v, "1");
    }
    return true;
}

/// Raw `--remote`/`--user`/`--identity` CLI values (empty = unset).
const RemoteConnectArgs = struct {
    remote: []const u8 = "",
    user: []const u8 = "",
    identity: []const u8 = "",
};

// Stable storage for the defaulted identity path (process-lifetime; the CLI
// runs a single session).
var remote_identity_buf: [std.fs.max_path_bytes]u8 = undefined;

/// `hexe allow [path]` — record a project `.hexe.lua`'s content hash in the
/// trust ledger so its on_start/on_stop hooks may run (PLAN 1.9). `path` may be
/// a `.hexe.lua` file or a directory containing one; defaults to `./.hexe.lua`.
fn runAllow(allocator: std.mem.Allocator, arg_path: []const u8) !void {
    const path = if (arg_path.len == 0)
        try allocator.dupe(u8, ".hexe.lua")
    else if (std.mem.endsWith(u8, arg_path, ".lua"))
        try allocator.dupe(u8, arg_path)
    else
        try std.fmt.allocPrint(allocator, "{s}/.hexe.lua", .{arg_path});
    defer allocator.free(path);

    core.trust.allow(allocator, path) catch |err| {
        switch (err) {
            error.FileNotFound => print("No .hexe.lua found at {s}\n", .{path}),
            else => print("Failed to trust {s}: {s}\n", .{ path, @errorName(err) }),
        }
        return;
    };

    const abs = std.fs.cwd().realpathAlloc(allocator, path) catch null;
    defer if (abs) |a| allocator.free(a);
    print("Trusted {s} — its on_start/on_stop hooks will now run.\n", .{abs orelse path});
}

fn buildTerminalConnectOptions(socket_path: []const u8, no_autostart_ses: bool, remote: RemoteConnectArgs) core.FrontendConnectOptions {
    var opts: core.FrontendConnectOptions = .{
        .socket_path = if (socket_path.len > 0) socket_path else null,
        .autostart_ses = !no_autostart_ses,
    };
    if (remote.remote.len > 0) {
        // Parse host[:port].
        if (std.mem.lastIndexOfScalar(u8, remote.remote, ':')) |ci| {
            opts.remote_host = remote.remote[0..ci];
            opts.remote_port = std.fmt.parseInt(u16, remote.remote[ci + 1 ..], 10) catch 0;
        } else {
            opts.remote_host = remote.remote;
        }
        // user: flag, else $USER (env slices persist for the process).
        opts.remote_user = if (remote.user.len > 0) remote.user else std.posix.getenv("USER");
        // identity: flag, else ~/.ssh/id_ed25519 built into stable storage.
        if (remote.identity.len > 0) {
            opts.remote_identity = remote.identity;
        } else if (std.posix.getenv("HOME")) |home| {
            opts.remote_identity = std.fmt.bufPrint(&remote_identity_buf, "{s}/.ssh/id_ed25519", .{home}) catch null;
        }
    }
    return opts;
}

fn runTerminalNew(name: []const u8, log_level: ?core.logging.Level, log_file: []const u8, socket_path: []const u8, no_autostart_ses: bool, remote: RemoteConnectArgs, startup_chooser: bool) !void {
    if (std.posix.getenv("HEXE_PANE_UUID")) |pane_uuid| {
        if (pane_uuid.len >= 32) {
            if (!try showNestedMuxConfirmation(pane_uuid)) {
                return;
            }
        }
    }

    try terminal.run(.{
        .name = if (name.len > 0) name else null,
        .log_level = log_level,
        .log_file = if (log_file.len > 0) log_file else null,
        .startup_chooser = startup_chooser,
        .connect_options = buildTerminalConnectOptions(socket_path, no_autostart_ses, remote),
    });
}

fn runTerminalAttach(name: []const u8, log_level: ?core.logging.Level, log_file: []const u8, socket_path: []const u8, no_autostart_ses: bool, remote: RemoteConnectArgs) !void {
    if (name.len > 0) {
        try terminal.run(.{
            .attach = name,
            .log_level = log_level,
            .log_file = if (log_file.len > 0) log_file else null,
            .connect_options = buildTerminalConnectOptions(socket_path, no_autostart_ses, remote),
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

    stdout.writeAll("\r\n") catch |err| {
        core.logging.logError("cli", "failed to finish animation line", err);
    };
}
