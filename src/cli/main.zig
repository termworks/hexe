const std = @import("std");
const argonaut = @import("argonaut");
const core = @import("core");
const ipc = core.ipc;
const terminal = @import("terminal");
const ses = @import("ses");
const pod = @import("pod");
const shp = @import("shp");
const cli_cmds = @import("commands/com.zig");
const config_validate = @import("commands/config_validate.zig");
const ses_export = @import("commands/ses_export.zig");
const ses_stats = @import("commands/ses_stats.zig");

const c = @cImport({
    @cInclude("stdlib.h");
});

const print = std.debug.print;

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Create main parser
    const parser = try argonaut.newParser(allocator, "hexe", "Hexe terminal frontend");
    defer parser.deinit();

    // Top-level subcommands only
    const ses_cmd = try parser.newCommand("ses", "Session daemon management");
    const pod_cmd = try parser.newCommand("pod", "Per-pane PTY daemon");
    const mux_cmd = try parser.newCommand("mux", "Terminal frontend");
    const shp_cmd = try parser.newCommand("shp", "Shell prompt renderer");
    const pop_cmd = try parser.newCommand("pop", "Popup overlays");
    const config_cmd = try parser.newCommand("config", "Configuration management");

    // SES subcommands
    const ses_daemon = try ses_cmd.newCommand("daemon", "Start the session daemon");
    const ses_daemon_fg = try ses_daemon.flag("f", "foreground", null);
    const ses_daemon_dbg = try ses_daemon.flag("d", "debug", null);
    const ses_daemon_log = try ses_daemon.string("L", "logfile", null);
    const ses_daemon_instance = try ses_daemon.string("I", "instance", null);
    const ses_daemon_test_only = try ses_daemon.flag("T", "test-only", null);

    const ses_status = try ses_cmd.newCommand("status", "Show daemon info");
    const ses_status_instance = try ses_status.string("I", "instance", null);

    const ses_list = try ses_cmd.newCommand("list", "List all sessions and panes");
    const ses_list_details = try ses_list.flag("d", "details", null);
    const ses_list_instance = try ses_list.string("I", "instance", null);
    const ses_list_json = try ses_list.flag("j", "json", null);

    const ses_kill = try ses_cmd.newCommand("kill", "Kill a detached session");
    const ses_kill_target = try ses_kill.stringPositional(null);
    const ses_kill_instance = try ses_kill.string("I", "instance", null);

    const ses_clear = try ses_cmd.newCommand("clear", "Kill all detached sessions");
    const ses_clear_instance = try ses_clear.string("I", "instance", null);
    const ses_clear_force = try ses_clear.flag("f", "force", null);

    const ses_export_cmd = try ses_cmd.newCommand("export", "Export detached session to JSON");
    const ses_export_session = try ses_export_cmd.stringPositional(null);
    const ses_export_output = try ses_export_cmd.string("o", "output", null);
    const ses_export_instance = try ses_export_cmd.string("I", "instance", null);

    const ses_stats_cmd = try ses_cmd.newCommand("stats", "Show resource usage statistics");
    const ses_stats_instance = try ses_stats_cmd.string("I", "instance", null);

    // POD subcommands (mostly for ses-internal use)
    const pod_daemon = try pod_cmd.newCommand("daemon", "Start a per-pane pod daemon");
    const pod_daemon_uuid = try pod_daemon.string("u", "uuid", null);
    const pod_daemon_name = try pod_daemon.string("n", "name", null);
    const pod_daemon_socket = try pod_daemon.string("s", "socket", null);
    const pod_daemon_shell = try pod_daemon.string("S", "shell", null);
    const pod_daemon_cwd = try pod_daemon.string("C", "cwd", null);
    const pod_daemon_labels = try pod_daemon.string("", "labels", null);
    const pod_daemon_write_meta = try pod_daemon.flag("", "write-meta", null);
    const pod_daemon_no_write_meta = try pod_daemon.flag("", "no-write-meta", null);
    const pod_daemon_write_alias = try pod_daemon.flag("", "write-alias", null);
    const pod_daemon_fg = try pod_daemon.flag("f", "foreground", null);
    const pod_daemon_dbg = try pod_daemon.flag("d", "debug", null);
    const pod_daemon_log = try pod_daemon.string("L", "logfile", null);
    const pod_daemon_instance = try pod_daemon.string("I", "instance", null);
    const pod_daemon_test_only = try pod_daemon.flag("T", "test-only", null);

    const pod_list = try pod_cmd.newCommand("list", "List discoverable pods (from .meta)");
    const pod_list_where = try pod_list.string("", "where", null);
    const pod_list_probe = try pod_list.flag("", "probe", null);
    const pod_list_alive = try pod_list.flag("", "alive", null);
    const pod_list_json = try pod_list.flag("j", "json", null);

    const pod_new = try pod_cmd.newCommand("new", "Create a standalone pod (spawns pod daemon)");
    const pod_new_name = try pod_new.string("n", "name", null);
    const pod_new_shell = try pod_new.string("S", "shell", null);
    const pod_new_cwd = try pod_new.string("C", "cwd", null);
    const pod_new_labels = try pod_new.string("", "labels", null);
    const pod_new_alias = try pod_new.flag("", "alias", null);
    const pod_new_dbg = try pod_new.flag("d", "debug", null);
    const pod_new_log = try pod_new.string("L", "logfile", null);
    const pod_new_instance = try pod_new.string("I", "instance", null);
    const pod_new_test_only = try pod_new.flag("T", "test-only", null);

    const pod_send = try pod_cmd.newCommand("send", "Send input to a pod (by uuid/name/socket)");
    const pod_send_uuid = try pod_send.string("u", "uuid", null);
    const pod_send_name = try pod_send.string("n", "name", null);
    const pod_send_socket = try pod_send.string("s", "socket", null);
    const pod_send_enter = try pod_send.flag("e", "enter", null);
    const pod_send_ctrl = try pod_send.string("C", "ctrl", null);
    const pod_send_text = try pod_send.stringPositional(null);

    const pod_attach = try pod_cmd.newCommand("attach", "Attach to a pod (raw tty)");
    const pod_attach_uuid = try pod_attach.string("u", "uuid", null);
    const pod_attach_name = try pod_attach.string("n", "name", null);
    const pod_attach_socket = try pod_attach.string("s", "socket", null);
    const pod_attach_detach = try pod_attach.string("", "detach", null);
    const pod_attach_record = try pod_attach.string("", "record", null);
    const pod_attach_capture_input = try pod_attach.flag("", "capture-input", null);

    const pod_record = try pod_cmd.newCommand("record", "Attach to a pod and record asciicast");
    const pod_record_uuid = try pod_record.string("u", "uuid", null);
    const pod_record_name = try pod_record.string("n", "name", null);
    const pod_record_socket = try pod_record.string("s", "socket", null);
    const pod_record_out = try pod_record.string("o", "out", null);
    const pod_record_capture_input = try pod_record.flag("", "capture-input", null);

    const pod_kill = try pod_cmd.newCommand("kill", "Kill a pod by uuid/name");
    const pod_kill_uuid = try pod_kill.string("u", "uuid", null);
    const pod_kill_name = try pod_kill.string("n", "name", null);
    const pod_kill_signal = try pod_kill.string("s", "signal", null);
    const pod_kill_force = try pod_kill.flag("f", "force", null);

    const pod_gc = try pod_cmd.newCommand("gc", "Garbage-collect stale pod metadata");
    const pod_gc_dry = try pod_gc.flag("n", "dry-run", null);

    // MUX subcommands
    const mux_new = try mux_cmd.newCommand("new", "Create new multiplexer session");
    const mux_new_name = try mux_new.string("n", "name", null);
    const mux_new_dbg = try mux_new.flag("d", "debug", null);
    const mux_new_log = try mux_new.string("L", "logfile", null);
    const mux_new_ses_socket = try mux_new.string("", "ses-socket", null);
    const mux_new_no_autostart = try mux_new.flag("", "no-autostart-ses", null);
    const mux_new_instance = try mux_new.string("I", "instance", null);
    const mux_new_test_only = try mux_new.flag("T", "test-only", null);

    const mux_attach = try mux_cmd.newCommand("attach", "Attach to existing session");
    const mux_attach_name = try mux_attach.stringPositional(null);
    const mux_attach_dbg = try mux_attach.flag("d", "debug", null);
    const mux_attach_log = try mux_attach.string("L", "logfile", null);
    const mux_attach_ses_socket = try mux_attach.string("", "ses-socket", null);
    const mux_attach_no_autostart = try mux_attach.flag("", "no-autostart-ses", null);
    const mux_attach_instance = try mux_attach.string("I", "instance", null);

    const mux_float = try mux_cmd.newCommand("float", "Spawn a transient float pane");
    const mux_float_command = try mux_float.string("c", "command", null);
    const mux_float_title = try mux_float.string("", "title", null);
    const mux_float_cwd = try mux_float.string("", "cwd", null);
    const mux_float_result_file = try mux_float.string("", "result-file", null);
    const mux_float_pass_env = try mux_float.flag("", "pass-env", null);
    const mux_float_extra_env = try mux_float.string("", "extra-env", null);
    const mux_float_isolated = try mux_float.flag("", "isolated", null);
    const mux_float_isolation = try mux_float.string("", "isolation", null);
    const mux_float_size = try mux_float.string("", "size", null);
    const mux_float_focus = try mux_float.flag("", "focus", null);
    const mux_float_exit_key = try mux_float.string("", "key", null);
    const mux_float_instance = try mux_float.string("I", "instance", null);

    const mux_notify = try mux_cmd.newCommand("notify", "Send notification");
    const mux_notify_uuid = try mux_notify.string("u", "uuid", null);
    const mux_notify_creator = try mux_notify.flag("c", "creator", null);
    const mux_notify_last = try mux_notify.flag("l", "last", null);
    const mux_notify_broadcast = try mux_notify.flag("b", "broadcast", null);
    const mux_notify_msg = try mux_notify.stringPositional(null);
    const mux_notify_instance = try mux_notify.string("I", "instance", null);

    const mux_send = try mux_cmd.newCommand("send", "Send keystrokes to pane");
    const mux_send_uuid = try mux_send.string("u", "uuid", null);
    const mux_send_creator = try mux_send.flag("c", "creator", null);
    const mux_send_last = try mux_send.flag("l", "last", null);
    const mux_send_broadcast = try mux_send.flag("b", "broadcast", null);
    const mux_send_enter = try mux_send.flag("e", "enter", null);
    const mux_send_ctrl = try mux_send.string("C", "ctrl", null);
    const mux_send_text = try mux_send.stringPositional(null);
    const mux_send_instance = try mux_send.string("I", "instance", null);

    const mux_info = try mux_cmd.newCommand("info", "Show information about a pane");
    const mux_info_uuid = try mux_info.string("u", "uuid", null);
    const mux_info_creator = try mux_info.flag("c", "creator", null);
    const mux_info_last = try mux_info.flag("l", "last", null);
    const mux_info_instance = try mux_info.string("I", "instance", null);

    const mux_layout = try mux_cmd.newCommand("layout", "Save and restore layouts");
    const mux_layout_save = try mux_layout.newCommand("save", "Save current layout");
    const mux_layout_save_name = try mux_layout_save.stringPositional(null);
    const mux_layout_load = try mux_layout.newCommand("load", "Load a saved layout");
    const mux_layout_load_name = try mux_layout_load.stringPositional(null);
    const mux_layout_list = try mux_layout.newCommand("list", "List saved layouts");

    const mux_focus = try mux_cmd.newCommand("focus", "Move focus to adjacent pane");
    const mux_focus_dir = try mux_focus.stringPositional(null);

    // POP subcommands
    const shp_prompt = try shp_cmd.newCommand("prompt", "Render shell prompt");
    const shp_prompt_status = try shp_prompt.int("s", "status", null);
    const shp_prompt_duration = try shp_prompt.int("d", "duration", null);
    const shp_prompt_right = try shp_prompt.flag("r", "right", null);
    const shp_prompt_shell = try shp_prompt.string("S", "shell", null);
    const shp_prompt_jobs = try shp_prompt.int("j", "jobs", null);

    const shp_init = try shp_cmd.newCommand("init", "Print shell initialization script");
    const shp_init_shell = try shp_init.stringPositional(null);
    const shp_init_no_comms = try shp_init.flag("", "no-comms", null);

    const shp_exit_intent = try shp_cmd.newCommand("exit-intent", "Ask mux permission before shell exits");

    const shp_shell_event = try shp_cmd.newCommand("shell-event", "Send shell command metadata to the current mux");
    const shp_shell_event_cmd = try shp_shell_event.string("", "cmd", null);
    const shp_shell_event_status = try shp_shell_event.int("", "status", null);
    const shp_shell_event_duration = try shp_shell_event.int("", "duration", null);
    const shp_shell_event_cwd = try shp_shell_event.string("", "cwd", null);
    const shp_shell_event_jobs = try shp_shell_event.int("", "jobs", null);
    const shp_shell_event_phase = try shp_shell_event.string("", "phase", null);
    const shp_shell_event_running = try shp_shell_event.flag("", "running", null);
    const shp_shell_event_started_at = try shp_shell_event.int("", "started-at", null);

    const shp_spinner = try shp_cmd.newCommand("spinner", "Render a spinner/animation frame");
    const shp_spinner_name = try shp_spinner.stringPositional(null);
    const shp_spinner_width = try shp_spinner.int("w", "width", null);
    const shp_spinner_interval = try shp_spinner.int("i", "interval", null);
    const shp_spinner_hold = try shp_spinner.int("H", "hold", null);
    const shp_spinner_loop = try shp_spinner.flag("l", "loop", null);

    // POP subcommands
    const pop_notify = try pop_cmd.newCommand("notify", "Show notification");
    const pop_notify_uuid = try pop_notify.string("u", "uuid", null);
    const pop_notify_timeout = try pop_notify.int("t", "timeout", null);
    const pop_notify_msg = try pop_notify.stringPositional(null);

    const pop_confirm = try pop_cmd.newCommand("confirm", "Yes/No dialog");
    const pop_confirm_uuid = try pop_confirm.string("u", "uuid", null);
    const pop_confirm_timeout = try pop_confirm.int("t", "timeout", null);
    const pop_confirm_msg = try pop_confirm.stringPositional(null);

    const pop_choose = try pop_cmd.newCommand("choose", "Select from options");
    const pop_choose_uuid = try pop_choose.string("u", "uuid", null);
    const pop_choose_timeout = try pop_choose.int("t", "timeout", null);
    const pop_choose_items = try pop_choose.string("i", "items", null);
    const pop_choose_msg = try pop_choose.stringPositional(null);

    // CONFIG subcommands
    const config_validate_cmd = try config_cmd.newCommand("validate", "Validate configuration file");

    // Check for help flag manually to avoid argonaut segfault
    var has_help = false;
    var found_ses = false;
    var found_pod = false;
    var found_mux = false;
    var found_shp = false;
    var found_list = false;
    var found_notify = false;
    var found_daemon = false;
    var found_info = false;
    var found_status = false;
    var found_new = false;
    var found_attach = false;
    var found_kill = false;
    var found_clear = false;
    var found_gc = false;
    var found_float = false;
    var found_prompt = false;
    var found_init = false;
    var found_pop = false;
    var found_confirm = false;
    var found_choose = false;
    var found_send = false;
    var found_focus = false;
    var found_layout = false;
    var found_save = false;
    var found_load = false;
    var found_exit_intent = false;
    var found_shell_event = false;
    var found_spinner = false;
    var found_config = false;
    var found_validate = false;
    var found_export = false;
    var found_stats = false;
    var found_record = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) has_help = true;
        if (std.mem.eql(u8, arg, "ses")) found_ses = true;
        if (std.mem.eql(u8, arg, "pod")) found_pod = true;
        if (std.mem.eql(u8, arg, "mux")) found_mux = true;
        if (std.mem.eql(u8, arg, "shp")) found_shp = true;
        if (std.mem.eql(u8, arg, "list")) found_list = true;
        if (std.mem.eql(u8, arg, "info")) found_info = true;
        if (std.mem.eql(u8, arg, "status")) found_status = true;
        if (std.mem.eql(u8, arg, "notify")) found_notify = true;
        if (std.mem.eql(u8, arg, "daemon")) found_daemon = true;
        if (std.mem.eql(u8, arg, "new")) found_new = true;
        if (std.mem.eql(u8, arg, "attach")) found_attach = true;
        if (std.mem.eql(u8, arg, "kill")) found_kill = true;
        if (std.mem.eql(u8, arg, "clear")) found_clear = true;
        if (std.mem.eql(u8, arg, "gc")) found_gc = true;
        if (std.mem.eql(u8, arg, "float")) found_float = true;
        if (std.mem.eql(u8, arg, "prompt")) found_prompt = true;
        if (std.mem.eql(u8, arg, "init")) found_init = true;
        if (std.mem.eql(u8, arg, "pop")) found_pop = true;
        if (std.mem.eql(u8, arg, "confirm")) found_confirm = true;
        if (std.mem.eql(u8, arg, "choose")) found_choose = true;
        if (std.mem.eql(u8, arg, "send")) found_send = true;
        if (std.mem.eql(u8, arg, "focus")) found_focus = true;
        if (std.mem.eql(u8, arg, "layout")) found_layout = true;
        if (std.mem.eql(u8, arg, "save")) found_save = true;
        if (std.mem.eql(u8, arg, "load")) found_load = true;
        if (std.mem.eql(u8, arg, "exit-intent")) found_exit_intent = true;
        if (std.mem.eql(u8, arg, "shell-event")) found_shell_event = true;
        if (std.mem.eql(u8, arg, "spinner")) found_spinner = true;
        if (std.mem.eql(u8, arg, "config")) found_config = true;
        if (std.mem.eql(u8, arg, "validate")) found_validate = true;
        if (std.mem.eql(u8, arg, "export")) found_export = true;
        if (std.mem.eql(u8, arg, "stats")) found_stats = true;
        if (std.mem.eql(u8, arg, "record")) found_record = true;
    }

    if (has_help) {
        // Show help for the most specific command found (manual strings to avoid argonaut crash)
        if (found_mux and found_layout and found_save) {
            print("Usage: hexe mux layout save <name>\n\nSave the current tab's layout to disk.\n\nLayouts are stored in ~/.config/hexe/layouts/<name>.json\n", .{});
        } else if (found_mux and found_layout and found_load) {
            print("Usage: hexe mux layout load <name>\n\nApply a saved layout to the current tab.\n\nExisting panes are closed and new ones created to match the layout.\n", .{});
        } else if (found_mux and found_layout) {
            print("Usage: hexe mux layout <command>\n\nSave and restore layouts\n\nCommands:\n  save <name>  Save current tab's layout\n  load <name>  Apply a saved layout\n  list         List saved layouts\n", .{});
        } else if (found_mux and found_focus) {
            print(
                "Usage: hexe mux focus <dir>\n\nMove focus to adjacent pane in the mux. Intended for editor integration (nvim).\n\nDirs: left, right, up, down\n\nRequires running inside mux (HEXE_PANE_UUID)\n",
                .{},
            );
        } else if (found_mux and found_send) {
            print("Usage: hexe mux send [OPTIONS] [text]\n\nSend keystrokes to pane (defaults to current pane if inside mux)\n\nOptions:\n  -u, --uuid <UUID>        Target specific pane\n  -c, --creator            Send to pane that created current pane\n  -l, --last               Send to previously focused pane\n  -b, --broadcast          Broadcast to all attached panes\n  -e, --enter              Append Enter key after text\n  -C, --ctrl <char>        Send Ctrl+<char> (e.g., -C c for Ctrl+C)\n  -I, --instance <NAME>    Target a specific instance\n", .{});
        } else if (found_mux and found_notify) {
            print("Usage: hexe mux notify [OPTIONS] <message>\n\nSend notification (defaults to current pane if inside mux)\n\nOptions:\n  -u, --uuid <UUID>        Target specific mux or pane\n  -c, --creator            Send to pane that created current pane\n  -l, --last               Send to previously focused pane\n  -b, --broadcast          Broadcast to all muxes\n  -I, --instance <NAME>    Target a specific instance\n", .{});
        } else if (found_mux and found_info) {
            print("Usage: hexe mux info [OPTIONS]\n\nShow information about a pane\n\nOptions:\n  -u, --uuid <UUID>        Query specific pane by UUID (works from anywhere)\n  -c, --creator            Print only the creator pane UUID\n  -l, --last               Print only the last focused pane UUID\n  -I, --instance <NAME>    Target a specific instance\n\nWithout --uuid, queries current pane (requires running inside mux)\n", .{});
        } else if (found_pod and found_list) {
            print("Usage: hexe pod list [OPTIONS]\n\nList discoverable pods by scanning pod-*.meta in the hexe socket dir.\n\nOptions:\n      --where <LUA>   Lua predicate (return boolean). Variable: pod\n      --probe         Probe sockets (best-effort)\n      --alive         Only show pods whose socket is connectable (implies --probe)\n  -j, --json          Output as JSON array\n", .{});
        } else if (found_pod and found_new) {
            print("Usage: hexe pod new [OPTIONS]\n\nCreate a standalone pod and print a JSON line once ready.\n\nOptions:\n  -n, --name <NAME>         Pod name (also used for ps/alias)\n  -S, --shell <CMD>         Shell/command to run (default: $SHELL)\n  -C, --cwd <DIR>           Working directory\n      --labels <a,b,c>      Comma-separated labels\n      --alias               Create pod@<name>.sock alias symlink\n  -d, --debug               Enable debug output\n  -L, --logfile <PATH>      Log debug output to PATH\n  -I, --instance <NAME>     Run under instance namespace\n  -T, --test-only           Mark as test-only (requires instance)\n", .{});
        } else if (found_ses and found_list) {
            print("Usage: hexe ses list [OPTIONS]\n\nList all sessions and panes\n\nOptions:\n  -d, --details           Show extra details\n  -j, --json              Output as JSON\n  -I, --instance <NAME>   Target a specific instance\n", .{});
        } else if (found_ses and found_kill) {
            print("Usage: hexe ses kill <name|uuid-prefix>\n\nKill a detached session by name or UUID prefix\n\nOptions:\n  -I, --instance <NAME>   Target a specific instance\n", .{});
        } else if (found_ses and found_clear) {
            print("Usage: hexe ses clear [OPTIONS]\n\nKill all detached sessions\n\nOptions:\n  -f, --force             Skip confirmation\n  -I, --instance <NAME>   Target a specific instance\n", .{});
        } else if (found_ses and found_export) {
            print("Usage: hexe ses export <name|uuid-prefix> [OPTIONS]\n\nExport a detached session to JSON\n\nOptions:\n  -o, --output <PATH>     Write to file (default: stdout)\n  -I, --instance <NAME>   Target a specific instance\n\nThe exported JSON contains the complete session state including\nall panes, their layout, and metadata. This can be used for backup\nor migration purposes.\n", .{});
        } else if (found_ses and found_status) {
            print("Usage: hexe ses status [OPTIONS]\n\nShow daemon status and socket path\n\nOptions:\n  -I, --instance <NAME>   Target a specific instance\n", .{});
        } else if (found_shp and found_exit_intent) {
            print("Usage: hexe shp exit-intent\n\nAsk the current mux session whether the shell should be allowed to exit.\nIntended for shell keybindings (exit/Ctrl+D) to avoid last-pane death.\n\nExit codes: 0=allow, 1=deny\n", .{});
        } else if (found_shp and found_shell_event) {
            print(
                "Usage: hexe shp shell-event [--cmd <TEXT>] [--cwd <PATH>] [--jobs <N>] [--phase <start|end>] [--running] [--started-at <MS>] [--status <N>] [--duration <MS>]\n\nSend shell command metadata to the current mux session.\nUsed by shell integration to power statusbar + `hexe mux info`.\n\nNotes:\n  - No-op outside a mux session\n  - If mux is unreachable, exits 0\n",
                .{},
            );
        } else if (found_ses and found_daemon) {
            print("Usage: hexe ses daemon [OPTIONS]\n\nStart the session daemon\n\nOptions:\n  -f, --foreground        Run in foreground (don't daemonize)\n  -d, --debug             Enable debug output\n  -L, --logfile <PATH>    Log debug output to PATH\n  -I, --instance <NAME>   Run under instance namespace\n  -T, --test-only         Mark as test-only (requires instance)\n", .{});
        } else if (found_pod and found_daemon) {
            print("Usage: hexe pod daemon [OPTIONS]\n\nStart a per-pane pod daemon (normally launched by ses)\n\nOptions:\n  -u, --uuid <UUID>            Pane UUID (32 hex chars)\n  -n, --name <NAME>            Human-friendly pane name (for `ps`)\n  -s, --socket <PATH>          Pod unix socket path\n  -S, --shell <CMD>            Shell/command to run\n  -C, --cwd <DIR>              Working directory\n      --labels <a,b,c>         Comma-separated labels for discovery\n      --write-meta              Enable writing pod-<uuid>.meta (default)\n      --no-write-meta           Disable writing pod-<uuid>.meta\n      --write-alias             Create pod@<name>.sock alias symlink\n  -f, --foreground             Run in foreground (prints pod_ready JSON)\n  -d, --debug                  Enable debug output\n  -L, --logfile <PATH>         Log debug output to PATH\n  -I, --instance <NAME>        Run under instance namespace\n  -T, --test-only              Mark as test-only (requires instance)\n", .{});
        } else if (found_pod and found_send) {
            print("Usage: hexe pod send [OPTIONS] [text]\n\nSend input to a pod without ses/mux.\n\nOptions:\n  -u, --uuid <UUID>        Target pod by UUID (32 hex chars)\n  -n, --name <NAME>        Target pod by name (via pod-*.meta scan)\n  -s, --socket <PATH>      Target pod by explicit socket path\n  -e, --enter              Append Enter key\n  -C, --ctrl <char>        Send Ctrl+<char> (e.g., -C c for Ctrl+C)\n", .{});
        } else if (found_pod and found_attach) {
            print("Usage: hexe pod attach [OPTIONS]\n\nInteractive attach to a pod socket (raw tty).\n\nOptions:\n  -u, --uuid <UUID>        Target pod by UUID (32 hex chars)\n  -n, --name <NAME>        Target pod by name (via pod-*.meta scan)\n  -s, --socket <PATH>      Target pod by explicit socket path\n      --detach <key>       Detach prefix Ctrl+<key> (default: b), then press 'd'\n      --record <PATH>      Write asciicast recording (.cast)\n      --capture-input      Include typed input events in recording\n", .{});
        } else if (found_pod and found_record) {
            print("Usage: hexe pod record [OPTIONS]\n\nObserve a pod and write an asciicast recording (non-intrusive).\n\nOptions:\n  -u, --uuid <UUID>        Target pod by UUID (32 hex chars)\n  -n, --name <NAME>        Target pod by name (via pod-*.meta scan)\n  -s, --socket <PATH>      Target pod by explicit socket path\n  -o, --out <PATH>         Output cast file path (required)\n      --capture-input      Include input frames when available\n", .{});
        } else if (found_pod and found_kill) {
            print("Usage: hexe pod kill [OPTIONS]\n\nKill a pod process (reads pid from pod-*.meta).\n\nOptions:\n  -u, --uuid <UUID>        Target pod by UUID\n  -n, --name <NAME>        Target pod by name (newest created_at wins)\n  -s, --signal <SIG>       Signal name or number (default: TERM)\n                           Names: TERM, KILL, INT, HUP, QUIT, STOP, CONT, TSTP, USR1, USR2\n  -f, --force              Follow with SIGKILL\n", .{});
        } else if (found_pod and found_gc) {
            print("Usage: hexe pod gc [--dry-run]\n\nDelete stale pod-*.meta and broken pod@*.sock aliases.\n\nOptions:\n  -n, --dry-run            Only print what would be deleted\n", .{});
        } else if (found_mux and found_new) {
            print("Usage: hexe mux new [OPTIONS]\n\nCreate new multiplexer session\n\nOptions:\n  -n, --name <NAME>        Session name\n  -d, --debug              Enable debug output\n  -L, --logfile <PATH>     Log debug output to PATH\n      --ses-socket <PATH>  Connect to an explicit ses socket\n      --no-autostart-ses   Fail instead of starting ses automatically\n  -I, --instance <NAME>    Use instance namespace\n  -T, --test-only          Create an isolated test instance\n", .{});
        } else if (found_mux and found_attach) {
            print("Usage: hexe mux attach [OPTIONS] <name>\n\nAttach to existing session by name or UUID prefix\n\nOptions:\n  -d, --debug              Enable debug output\n  -L, --logfile <PATH>     Log debug output to PATH\n      --ses-socket <PATH>  Connect to an explicit ses socket\n      --no-autostart-ses   Fail instead of starting ses automatically\n  -I, --instance <NAME>    Target a specific instance\n", .{});
        } else if (found_mux and found_float) {
            print("Usage: hexe mux float [OPTIONS]\n\nSpawn a transient float pane (blocking)\n\nOptions:\n  -c, --command <COMMAND>       Command to run in the float\n      --title <TEXT>            Border title for the float\n      --cwd <PATH>              Working directory for the float\n      --result-file <PATH>      Read selection from PATH after exit\n      --pass-env                Send current environment to the pod\n      --extra-env <KEY=VAL,..>   Extra environment variables (comma-separated)\n      --isolated                Run command with filesystem/cgroup isolation (deprecated, use --isolation)\n      --isolation <PROFILE>     Isolation profile: none, minimal, default, balanced, sandbox, full\n      --size <W,H,X,Y>          Size and position: width%,height%,shift_x,shift_y\n      --focus                   Dim background to focus on the float\n      --key <KEY>               Exit key to close float (default: Esc)\n                                Format: Esc, C-q (Ctrl+Q), A-q (Alt+Q), C-A-q\n  -I, --instance <NAME>         Target a specific instance\n", .{});
        } else if (found_shp and found_prompt) {
            print("Usage: hexe shp prompt [OPTIONS]\n\nRender shell prompt\n\nOptions:\n  -s, --status <N>    Exit status of last command\n  -d, --duration <N>  Duration of last command in ms\n  -r, --right         Render right prompt\n  -S, --shell <SHELL> Shell type (bash, zsh, fish)\n  -j, --jobs <N>      Number of background jobs\n", .{});
        } else if (found_shp and found_init) {
            print("Usage: hexe shp init <shell> [--no-comms]\n\nPrint shell initialization script\n\nSupported shells: bash, zsh, fish\n\nOptions:\n      --no-comms  Disable shell->mux communication hooks\n", .{});
        } else if (found_shp and found_spinner) {
            print(
                "Usage: hexe shp spinner <name> [OPTIONS]\n\nRender a spinner frame (or animate it in-place).\n\nOptions:\n  -w, --width <N>       Frame width (default: 8)\n  -i, --interval <MS>   Frame step in ms (default: 75)\n  -H, --hold <N>        Hold frames at each end (default: 9)\n  -l, --loop            Animate continuously until Ctrl+C\n\nAvailable spinners:\n  knight_rider\n",
                .{},
            );
        } else if (found_pop and found_notify) {
            print("Usage: hexe pop notify [OPTIONS] <message>\n\nShow notification\n\nOptions:\n  -u, --uuid <UUID>     Target mux/tab/pane UUID\n  -t, --timeout <MS>    Duration in milliseconds (default: 3000)\n", .{});
        } else if (found_pop and found_confirm) {
            print("Usage: hexe pop confirm [OPTIONS] <message>\n\nYes/No dialog (blocking)\n\nOptions:\n  -u, --uuid <UUID>     Target mux/tab/pane UUID\n  -t, --timeout <MS>    Auto-cancel after milliseconds (returns false)\n\nExit codes: 0=confirmed, 1=cancelled/timeout\n", .{});
        } else if (found_pop and found_choose) {
            print("Usage: hexe pop choose [OPTIONS] <message>\n\nSelect from options (blocking)\n\nOptions:\n  -u, --uuid <UUID>      Target mux/tab/pane UUID\n  -t, --timeout <MS>     Auto-cancel after milliseconds\n  -i, --items <ITEMS>    Comma-separated list of options\n\nExit codes: 0=selected (index on stdout), 1=cancelled/timeout\n", .{});
        } else if (found_pop) {
            print("Usage: hexe pop <command>\n\nPopup overlays\n\nCommands:\n  notify   Show notification\n  confirm  Yes/No dialog\n  choose   Select from options\n", .{});
        } else if (found_ses) {
            print("Usage: hexe ses <command>\n\nSession daemon management\n\nCommands:\n  daemon  Start the session daemon\n  status  Show daemon info\n  list    List sessions and panes\n  kill    Kill a detached session\n  clear   Kill all detached sessions\n  export  Export detached session to JSON\n  stats   Show resource usage statistics\n", .{});
        } else if (found_pod) {
            print("Usage: hexe pod <command>\n\nPer-pane PTY daemon\n\nCommands:\n  daemon  Start a per-pane pod daemon\n  new     Create a standalone pod\n  list    List discoverable pods\n  send    Send input to a pod\n  attach  Attach to a pod\n  record  Attach and record asciicast\n  kill    Kill a pod\n  gc      Clean stale pod metadata\n", .{});
        } else if (found_mux) {
            print("Usage: hexe mux <command>\n\nTerminal frontend\n\nCommands:\n  new      Create new multiplexer session\n  attach   Attach to existing session\n  float    Spawn a transient float pane\n  notify   Send notification\n  send     Send keystrokes to pane\n  info     Show pane info\n  layout   Save and restore layouts\n", .{});
        } else if (found_shp) {
            print("Usage: hexe shp <command>\n\nShell prompt renderer\n\nCommands:\n  prompt       Render shell prompt\n  init         Print shell initialization script\n  exit-intent  Ask mux permission before shell exits\n  shell-event  Send shell metadata to mux\n  spinner      Render/animate a spinner\n", .{});
        } else if (found_config and found_validate) {
            print("Usage: hexe config validate\n\nValidate the Hexe configuration file.\n\nChecks:\n  - Lua syntax correctness\n  - Configuration structure\n  - Color format validity\n  - Keybinding syntax\n  - Type correctness\n\nExpected location: ~/.config/hexe/init.lua\n", .{});
        } else if (found_config) {
            print("Usage: hexe config <command>\n\nConfiguration management\n\nCommands:\n  validate  Validate configuration file syntax and structure\n", .{});
        } else {
            print("Usage: hexe <command>\n\nHexe terminal frontend\n\nCommands:\n  ses      Session daemon management\n  pod      Per-pane PTY daemon (internal)\n  mux      Terminal frontend\n  shp      Shell prompt renderer\n  pop      Popup overlays\n  config   Configuration management\n", .{});
        }
        return;
    }

    // Parse
    parser.parse(args) catch |err| {
        if (err == error.HelpRequested) return;
        if (err == error.SubCommandRequired) {
            // Default to 'hexe mux new' if no arguments given
            if (args.len == 1) {
                try runMuxNew("", false, "", "", false);
                return;
            }
            // Show help for the deepest command that happened
            if (pop_cmd.happened) {
                const help = try pop_cmd.usage(null);
                print("{s}\n", .{help});
            } else if (shp_cmd.happened) {
                const help = try shp_cmd.usage(null);
                print("{s}\n", .{help});
            } else if (mux_cmd.happened) {
                const help = try mux_cmd.usage(null);
                print("{s}\n", .{help});
            } else if (ses_cmd.happened) {
                const help = try ses_cmd.usage(null);
                print("{s}\n", .{help});
            } else {
                const help = try parser.usage(null);
                print("{s}\n", .{help});
            }
            return;
        }
        return err;
    };

    // Route to handlers
    if (ses_cmd.happened) {
        if (ses_daemon.happened) {
            if (ses_daemon_instance.*.len > 0) setInstanceFromCli(ses_daemon_instance.*);
            if (ses_daemon_test_only.*) {
                setTestOnlyEnv();
                if (!hasInstanceEnv()) {
                    print("Error: --test-only requires --instance or HEXE_INSTANCE\n", .{});
                    return;
                }
            }
            try runSesDaemon(ses_daemon_fg.*, ses_daemon_dbg.*, ses_daemon_log.*);
        } else if (ses_status.happened) {
            if (ses_status_instance.*.len > 0) setInstanceFromCli(ses_status_instance.*);
            try runSesStatus(allocator);
        } else if (ses_list.happened) {
            if (ses_list_instance.*.len > 0) setInstanceFromCli(ses_list_instance.*);
            try cli_cmds.runList(allocator, ses_list_details.*, ses_list_json.*);
        } else if (ses_kill.happened) {
            if (ses_kill_instance.*.len > 0) setInstanceFromCli(ses_kill_instance.*);
            try cli_cmds.runSesKill(allocator, ses_kill_target.*);
        } else if (ses_clear.happened) {
            if (ses_clear_instance.*.len > 0) setInstanceFromCli(ses_clear_instance.*);
            try cli_cmds.runSesClear(allocator, ses_clear_force.*);
        } else if (ses_export_cmd.happened) {
            if (ses_export_instance.*.len > 0) setInstanceFromCli(ses_export_instance.*);
            try ses_export.run(allocator, ses_export_session.*, ses_export_output.*);
        } else if (ses_stats_cmd.happened) {
            if (ses_stats_instance.*.len > 0) setInstanceFromCli(ses_stats_instance.*);
            try ses_stats.run(allocator);
        }
    } else if (pod_cmd.happened) {
        if (pod_daemon.happened) {
            if (pod_daemon_instance.*.len > 0) setInstanceFromCli(pod_daemon_instance.*);
            if (pod_daemon_test_only.*) {
                setTestOnlyEnv();
                if (!hasInstanceEnv()) {
                    print("Error: --test-only requires --instance or HEXE_INSTANCE\n", .{});
                    return;
                }
            }
            try runPodDaemon(
                pod_daemon_fg.*,
                pod_daemon_uuid.*,
                pod_daemon_name.*,
                pod_daemon_socket.*,
                pod_daemon_shell.*,
                pod_daemon_cwd.*,
                pod_daemon_labels.*,
                pod_daemon_write_meta.*,
                pod_daemon_no_write_meta.*,
                pod_daemon_write_alias.*,
                pod_daemon_dbg.*,
                pod_daemon_log.*,
            );
        } else if (pod_list.happened) {
            // No ses dependency; uses ipc.getSocketDir() + .meta files.
            const alive_only = pod_list_alive.*;
            const probe = pod_list_probe.* or alive_only;
            try cli_cmds.runPodList(allocator, pod_list_where.*, probe, alive_only, pod_list_json.*);
        } else if (pod_new.happened) {
            if (pod_new_instance.*.len > 0) setInstanceFromCli(pod_new_instance.*);
            if (pod_new_test_only.*) {
                setTestOnlyEnv();
                if (!hasInstanceEnv()) {
                    print("Error: --test-only requires --instance or HEXE_INSTANCE\n", .{});
                    return;
                }
            }
            try cli_cmds.runPodNew(
                allocator,
                pod_new_name.*,
                pod_new_shell.*,
                pod_new_cwd.*,
                pod_new_labels.*,
                pod_new_alias.*,
                pod_new_dbg.*,
                pod_new_log.*,
            );
        } else if (pod_send.happened) {
            try cli_cmds.runPodSend(
                allocator,
                pod_send_uuid.*,
                pod_send_name.*,
                pod_send_socket.*,
                pod_send_enter.*,
                pod_send_ctrl.*,
                pod_send_text.*,
            );
        } else if (pod_attach.happened) {
            try cli_cmds.runPodAttach(
                allocator,
                pod_attach_uuid.*,
                pod_attach_name.*,
                pod_attach_socket.*,
                pod_attach_detach.*,
                pod_attach_record.*,
                pod_attach_capture_input.*,
            );
        } else if (pod_record.happened) {
            if (pod_record_out.*.len == 0) {
                print("Error: --out is required for pod record\n", .{});
                return;
            }
            try cli_cmds.runPodRecord(
                allocator,
                pod_record_uuid.*,
                pod_record_name.*,
                pod_record_socket.*,
                pod_record_out.*,
                pod_record_capture_input.*,
            );
        } else if (pod_kill.happened) {
            try cli_cmds.runPodKill(
                allocator,
                pod_kill_uuid.*,
                pod_kill_name.*,
                pod_kill_signal.*,
                pod_kill_force.*,
            );
        } else if (pod_gc.happened) {
            try cli_cmds.runPodGc(allocator, pod_gc_dry.*);
        }
        return;
    } else if (mux_cmd.happened) {
        if (mux_new.happened) {
            if (mux_new_instance.*.len > 0) {
                setInstanceFromCli(mux_new_instance.*);
                if (mux_new_test_only.*) setTestOnlyEnv();
            } else if (mux_new_test_only.*) {
                // Always isolate test sessions, even if HEXE_INSTANCE is set in the environment.
                setGeneratedTestInstance();
            }
            try runMuxNew(mux_new_name.*, mux_new_dbg.*, mux_new_log.*, mux_new_ses_socket.*, mux_new_no_autostart.*);
        } else if (mux_attach.happened) {
            if (mux_attach_instance.*.len > 0) setInstanceFromCli(mux_attach_instance.*);
            try runMuxAttach(mux_attach_name.*, mux_attach_dbg.*, mux_attach_log.*, mux_attach_ses_socket.*, mux_attach_no_autostart.*);
        } else if (mux_float.happened) {
            if (mux_float_instance.*.len > 0) setInstanceFromCli(mux_float_instance.*);
            const exit_key = if (mux_float_exit_key.*.len > 0) mux_float_exit_key.* else "Esc";
            try cli_cmds.runMuxFloat(
                allocator,
                mux_float_command.*,
                mux_float_title.*,
                mux_float_cwd.*,
                mux_float_result_file.*,
                mux_float_pass_env.*,
                mux_float_extra_env.*,
                mux_float_isolated.*,
                mux_float_isolation.*,
                mux_float_size.*,
                mux_float_focus.*,
                exit_key,
            );
        } else if (mux_notify.happened) {
            if (mux_notify_instance.*.len > 0) setInstanceFromCli(mux_notify_instance.*);
            try cli_cmds.runNotify(
                allocator,
                mux_notify_uuid.*,
                mux_notify_creator.*,
                mux_notify_last.*,
                mux_notify_broadcast.*,
                mux_notify_msg.*,
            );
        } else if (mux_send.happened) {
            if (mux_send_instance.*.len > 0) setInstanceFromCli(mux_send_instance.*);
            try cli_cmds.runSend(
                allocator,
                mux_send_uuid.*,
                mux_send_creator.*,
                mux_send_last.*,
                mux_send_broadcast.*,
                mux_send_enter.*,
                mux_send_ctrl.*,
                mux_send_text.*,
            );
        } else if (mux_layout.happened) {
            if (mux_layout_save.happened) {
                try cli_cmds.runLayoutSave(allocator, mux_layout_save_name.*);
            } else if (mux_layout_load.happened) {
                try cli_cmds.runLayoutLoad(allocator, mux_layout_load_name.*);
            } else if (mux_layout_list.happened) {
                try cli_cmds.runLayoutList(allocator);
            }
        } else if (mux_focus.happened) {
            try cli_cmds.runFocusMove(allocator, mux_focus_dir.*);
        } else if (mux_info.happened) {
            if (mux_info_instance.*.len > 0) setInstanceFromCli(mux_info_instance.*);
            try cli_cmds.runInfo(allocator, mux_info_uuid.*, mux_info_creator.*, mux_info_last.*);
        }
    } else if (shp_cmd.happened) {
        if (shp_prompt.happened) {
            try runShpPrompt(shp_prompt_status.*, shp_prompt_duration.*, shp_prompt_right.*, shp_prompt_shell.*, shp_prompt_jobs.*);
        } else if (shp_init.happened) {
            try runShpInit(shp_init_shell.*, shp_init_no_comms.*);
        } else if (shp_exit_intent.happened) {
            try cli_cmds.runExitIntent(allocator);
        } else if (shp_shell_event.happened) {
            try cli_cmds.runShellEvent(
                shp_shell_event_cmd.*,
                shp_shell_event_status.*,
                shp_shell_event_duration.*,
                shp_shell_event_cwd.*,
                shp_shell_event_jobs.*,
                shp_shell_event_phase.*,
                shp_shell_event_running.*,
                shp_shell_event_started_at.*,
            );
        } else if (shp_spinner.happened) {
            try runShpSpinner(shp_spinner_name.*, shp_spinner_width.*, shp_spinner_interval.*, shp_spinner_hold.*, shp_spinner_loop.*);
        }
    } else if (pop_cmd.happened) {
        if (pop_notify.happened) {
            try runPopNotify(allocator, pop_notify_uuid.*, pop_notify_timeout.*, pop_notify_msg.*);
        } else if (pop_confirm.happened) {
            try runPopConfirm(allocator, pop_confirm_uuid.*, pop_confirm_timeout.*, pop_confirm_msg.*);
        } else if (pop_choose.happened) {
            try runPopChoose(allocator, pop_choose_uuid.*, pop_choose_timeout.*, pop_choose_items.*, pop_choose_msg.*);
        }
    } else if (config_cmd.happened) {
        if (config_validate_cmd.happened) {
            try config_validate.run();
        }
    }
}

// ============================================================================
// SES handlers
// ============================================================================

fn runSesDaemon(foreground: bool, debug: bool, log_file: []const u8) !void {
    // Call ses run() - daemon mode unless foreground flag is set
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

// ============================================================================
// POD handlers
// ============================================================================

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

// ============================================================================
// MUX handlers
// ============================================================================

fn showNestedMuxConfirmation(pane_uuid: []const u8) !bool {
    const wire = core.wire;
    const posix = std.posix;

    var target_uuid: [32]u8 = undefined;
    @memcpy(&target_uuid, pane_uuid[0..32]);

    const allocator = std.heap.page_allocator;
    const fd = cli_cmds.connectSesCliChannel(allocator) orelse return false;

    const message = "Start nested mux session?";
    const timeout_ms: i32 = 0; // No timeout

    const pc = wire.PopConfirm{
        .uuid = target_uuid,
        .timeout_ms = timeout_ms,
        .msg_len = @intCast(message.len),
    };

    wire.writeControlWithTrail(fd, .pop_confirm, std.mem.asBytes(&pc), message) catch {
        posix.close(fd);
        return false;
    };

    // Wait for binary PopResponse
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

    // Return true if confirmed (response_type == 1), false otherwise
    return resp.response_type == 1;
}

fn buildMuxTransport(socket_path: []const u8, no_autostart_ses: bool) core.FrontendTransport {
    return core.FrontendTransportHelpers.localIpcTransport(
        if (socket_path.len > 0) socket_path else null,
        !no_autostart_ses,
    );
}

fn runMuxNew(name: []const u8, debug: bool, log_file: []const u8, socket_path: []const u8, no_autostart_ses: bool) !void {
    // Check if we're already inside a mux (nested session)
    if (std.posix.getenv("HEXE_PANE_UUID")) |pane_uuid| {
        if (pane_uuid.len >= 32) {
            // We're inside a mux - show confirmation popup
            if (!try showNestedMuxConfirmation(pane_uuid)) {
                // User cancelled or timeout
                return;
            }
        }
    }

    // Call mux run() directly
    try terminal.run(.{
        .name = if (name.len > 0) name else null,
        .debug = debug,
        .log_file = if (log_file.len > 0) log_file else null,
        .transport = buildMuxTransport(socket_path, no_autostart_ses),
    });
}

fn runMuxAttach(name: []const u8, debug: bool, log_file: []const u8, socket_path: []const u8, no_autostart_ses: bool) !void {
    if (name.len > 0) {
        // Call mux run() directly with attach option
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

// ============================================================================
// SHP handlers
// ============================================================================

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

        // NOTE: frame includes ANSI escapes; do not truncate/pad by bytes.
        // Use EL (erase to end of line) so variable-length frames don't leave artifacts.
        stdout.writeAll("\r") catch break;
        stdout.writeAll(frame) catch break;
        stdout.writeAll("\x1b[0K") catch break;
        std.Thread.sleep(interval_ms * std.time.ns_per_ms);
    }

    // Clear line on exit.
    stdout.writeAll("\r\n") catch {};
}

// ============================================================================
// POP handlers
// ============================================================================

fn parseUuid32Hex(text: []const u8) ?[32]u8 {
    if (text.len != 32) return null;
    var out: [32]u8 = undefined;
    for (text, 0..) |ch, i| {
        if (!std.ascii.isHex(ch)) return null;
        out[i] = ch;
    }
    return out;
}

fn runPopNotify(allocator: std.mem.Allocator, uuid: []const u8, timeout: i64, message: []const u8) !void {
    const wire = core.wire;
    const posix = std.posix;

    if (message.len == 0) {
        print("Error: message is required\n", .{});
        return;
    }

    var target_uuid: [32]u8 = undefined;
    if (uuid.len > 0) {
        target_uuid = parseUuid32Hex(uuid) orelse {
            print("Error: --uuid must be 32 hex chars\n", .{});
            return;
        };
    } else {
        const env_uuid = std.posix.getenv("HEXE_PANE_UUID") orelse {
            print("Error: --uuid required (or run inside hexe mux)\n", .{});
            return;
        };
        target_uuid = parseUuid32Hex(env_uuid) orelse {
            print("Error: invalid HEXE_PANE_UUID\n", .{});
            return;
        };
    }

    const fd = cli_cmds.connectSesCliChannel(allocator) orelse return;
    defer posix.close(fd);

    const timeout_ms: i32 = if (timeout > 0) @intCast(timeout) else 3000;
    const tn = wire.TargetedNotify{
        .uuid = target_uuid,
        .timeout_ms = timeout_ms,
        .msg_len = @intCast(message.len),
    };
    wire.writeControlWithTrail(fd, .targeted_notify, std.mem.asBytes(&tn), message) catch {};
}

fn runPopConfirm(allocator: std.mem.Allocator, uuid: []const u8, timeout: i64, message: []const u8) !void {
    const wire = core.wire;
    const posix = std.posix;

    if (message.len == 0) {
        print("Error: message is required\n", .{});
        return;
    }

    var target_uuid: [32]u8 = undefined;
    if (uuid.len > 0) {
        target_uuid = parseUuid32Hex(uuid) orelse {
            print("Error: --uuid must be 32 hex chars\n", .{});
            std.process.exit(1);
        };
    } else {
        const env_uuid = std.posix.getenv("HEXE_PANE_UUID") orelse {
            print("Error: --uuid required (or run inside hexe mux)\n", .{});
            return;
        };
        target_uuid = parseUuid32Hex(env_uuid) orelse {
            print("Error: invalid HEXE_PANE_UUID\n", .{});
            std.process.exit(1);
        };
    }

    const fd = cli_cmds.connectSesCliChannel(allocator) orelse std.process.exit(1);
    // Don't close fd — we need to read the response.

    const timeout_ms: i32 = if (timeout > 0) @intCast(timeout) else 0;
    const pc = wire.PopConfirm{
        .uuid = target_uuid,
        .timeout_ms = timeout_ms,
        .msg_len = @intCast(message.len),
    };
    wire.writeControlWithTrail(fd, .pop_confirm, std.mem.asBytes(&pc), message) catch {
        posix.close(fd);
        std.process.exit(1);
    };

    // Wait for binary PopResponse.
    const hdr = wire.readControlHeader(fd) catch {
        posix.close(fd);
        std.process.exit(1);
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type != .pop_response or hdr.payload_len < @sizeOf(wire.PopResponse)) {
        posix.close(fd);
        std.process.exit(1);
    }
    const resp = wire.readStruct(wire.PopResponse, fd) catch {
        posix.close(fd);
        std.process.exit(1);
    };
    posix.close(fd);

    if (resp.response_type == 1) {
        std.process.exit(0); // Confirmed
    }
    std.process.exit(1); // Cancelled or timeout
}

fn runPopChoose(allocator: std.mem.Allocator, uuid: []const u8, timeout: i64, items: []const u8, message: []const u8) !void {
    const wire = core.wire;
    const posix = std.posix;

    if (items.len == 0) {
        print("Error: --items is required\n", .{});
        return;
    }

    var target_uuid: [32]u8 = undefined;
    if (uuid.len > 0) {
        target_uuid = parseUuid32Hex(uuid) orelse {
            print("Error: --uuid must be 32 hex chars\n", .{});
            std.process.exit(1);
        };
    } else {
        const env_uuid = std.posix.getenv("HEXE_PANE_UUID") orelse {
            print("Error: --uuid required (or run inside hexe mux)\n", .{});
            return;
        };
        target_uuid = parseUuid32Hex(env_uuid) orelse {
            print("Error: invalid HEXE_PANE_UUID\n", .{});
            std.process.exit(1);
        };
    }

    // Build trailing data: title + length-prefixed items.
    var trail: std.ArrayList(u8) = .empty;
    defer trail.deinit(allocator);

    const title = if (message.len > 0) message else "Select option";
    try trail.appendSlice(allocator, title);

    // Count and encode items.
    var item_count: u16 = 0;
    var it = std.mem.splitScalar(u8, items, ',');
    while (it.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " ");
        if (trimmed.len > 0) {
            const len: u16 = @intCast(trimmed.len);
            try trail.appendSlice(allocator, std.mem.asBytes(&len));
            try trail.appendSlice(allocator, trimmed);
            item_count += 1;
        }
    }

    if (item_count == 0) {
        print("Error: no valid items provided\n", .{});
        return;
    }

    const fd = cli_cmds.connectSesCliChannel(allocator) orelse std.process.exit(1);

    const timeout_ms: i32 = if (timeout > 0) @intCast(timeout) else 0;
    const pc = wire.PopChoose{
        .uuid = target_uuid,
        .timeout_ms = timeout_ms,
        .title_len = @intCast(title.len),
        .item_count = item_count,
    };
    wire.writeControlWithTrail(fd, .pop_choose, std.mem.asBytes(&pc), trail.items) catch {
        posix.close(fd);
        std.process.exit(1);
    };

    // Wait for binary PopResponse.
    const hdr = wire.readControlHeader(fd) catch {
        posix.close(fd);
        std.process.exit(1);
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type != .pop_response or hdr.payload_len < @sizeOf(wire.PopResponse)) {
        posix.close(fd);
        std.process.exit(1);
    }
    const resp = wire.readStruct(wire.PopResponse, fd) catch {
        posix.close(fd);
        std.process.exit(1);
    };
    posix.close(fd);

    if (resp.response_type == 2) {
        print("{d}\n", .{resp.selected_idx});
        std.process.exit(0);
    }
    std.process.exit(1); // Cancelled or timeout
}
