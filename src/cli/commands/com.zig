const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const session_config = core.session_config;
const shared = @import("shared.zig");
const api_cmd = @import("api.zig");
const terminal = @import("terminal");

pub const runMuxFloat = @import("mux_float.zig").runMuxFloat;
pub const runMuxRecord = @import("mux_record.zig").runMuxRecord;
pub const runSesOpen = @import("ses_open.zig").runSesOpen;
pub const runSesFreeze = @import("ses_freeze.zig").runSesFreeze;
pub const LayoutSaveScope = @import("ses_freeze.zig").LayoutSaveScope;
pub const runPodList = @import("pod_list.zig").runPodList;
pub const runPodSend = @import("pod_send.zig").runPodSend;
pub const runPodNew = @import("pod_new.zig").runPodNew;
pub const runPodAttach = @import("pod_attach.zig").runPodAttach;
pub const runPodRecord = @import("pod_record.zig").runPodRecord;
pub const runPodKill = @import("pod_kill.zig").runPodKill;
pub const runPodShare = @import("pod_share.zig").runPodShare;
pub const runPluginList = @import("plugin.zig").runList;
pub const runLuaApi = @import("lua_api.zig").runLuaApi;
pub const runPodGc = @import("pod_gc.zig").runPodGc;
pub const runRecordStart = @import("record_ctl.zig").runRecordStart;
pub const runRecordStop = @import("record_ctl.zig").runRecordStop;
pub const runRecordStatus = @import("record_ctl.zig").runRecordStatus;
pub const runRecordToggle = @import("record_ctl.zig").runRecordToggle;
pub const runLayoutSave = @import("com_layout.zig").runLayoutSave;
pub const runLayoutLoad = @import("com_layout.zig").runLayoutLoad;
pub const runLayoutList = @import("com_layout.zig").runLayoutList;

const print = std.debug.print;
const cli_ui = core.cli_ui;

pub fn parseUuid32Hex(text: []const u8) ?[32]u8 {
    if (text.len != 32) return null;
    var out: [32]u8 = undefined;
    for (text, 0..) |ch, i| {
        if (!std.ascii.isHex(ch)) return null;
        out[i] = ch;
    }
    return out;
}

fn printTreeNode(
    out: anytype,
    p: core.cli_ui.Palette,
    prefix: []const u8,
    symbol: []const u8,
    type_color: []const u8,
    type_str: []const u8,
    name: []const u8,
    uuid8: []const u8,
) void {
    out.print(
        "{s}{s}{s}{s} {s}{s}{s} {s}{s}{s} {s}[{s}]{s}\n",
        .{
            prefix,
            p.warn,
            symbol,
            p.reset,
            type_color,
            type_str,
            p.reset,
            p.bold,
            name,
            p.reset,
            p.muted,
            uuid8,
            p.reset,
        },
    ) catch {};
}

fn sessionStateBaseRoot(allocator: std.mem.Allocator, session_state: []const u8) ?[]u8 {
    if (session_state.len == 0) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, session_state, .{}) catch return null;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return null,
    };
    const value = root.get("base_root") orelse return null;
    const str = switch (value) {
        .string => |s| s,
        else => return null,
    };
    if (str.len == 0) return null;
    return allocator.dupe(u8, str) catch null;
}

/// Resolve a user-supplied directory filter (e.g. ".", "..", "src", an
/// absolute path) to a canonical absolute path. Returns null (no filter) for
/// an empty argument. Falls back to the raw argument when the path can't be
/// canonicalized (e.g. it no longer exists) so a stale directory can still be
/// matched by string.
fn resolveDirFilter(allocator: std.mem.Allocator, arg: []const u8) ?[]u8 {
    if (arg.len == 0) return null;
    if (std.fs.cwd().realpathAlloc(allocator, arg)) |abs| {
        return abs;
    } else |_| {
        return allocator.dupe(u8, arg) catch null;
    }
}

/// Whether a session's base_root matches the directory filter. Compares the
/// canonical form of both sides so "." , a relative path, and the stored
/// absolute base_root all line up; falls back to a raw string compare when a
/// path can't be canonicalized.
fn dirFilterMatches(allocator: std.mem.Allocator, filter_abs: []const u8, base_root: []const u8) bool {
    if (base_root.len == 0) return false;
    if (std.mem.eql(u8, filter_abs, base_root)) return true;
    if (std.fs.cwd().realpathAlloc(allocator, base_root)) |abs| {
        defer allocator.free(abs);
        return std.mem.eql(u8, filter_abs, abs);
    } else |_| {
        return false;
    }
}

pub fn runList(allocator: std.mem.Allocator, details: bool, json_output: bool, dir_filter: []const u8) !void {
    const wire = core.wire;
    const posix = std.posix;

    // Optional directory filter: when set, only sessions whose base_root is
    // this directory are listed. `.` and relative paths resolve against cwd.
    const filter_abs: ?[]u8 = resolveDirFilter(allocator, dir_filter);
    defer if (filter_abs) |f| allocator.free(f);

    const fd = connectSesCliChannel(allocator) orelse std.process.exit(1);
    defer posix.close(fd);

    // Always request full mode when listing for humans too, so attached and
    // detached sessions both show their root directory consistently.
    const full_mode = !json_output or details or (filter_abs != null);
    const flag: [1]u8 = .{if (full_mode) @as(u8, 1) else @as(u8, 0)};
    wire.writeControl(fd, .status, &flag) catch |err| {
        cli_ui.printErr("failed to request session status: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    const hdr = wire.readControlHeader(fd) catch |err| {
        cli_ui.printErr("failed to read session status response: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type != .status or hdr.payload_len < @sizeOf(wire.StatusResp)) {
        cli_ui.printErr("invalid response from daemon", .{});
        std.process.exit(1);
    }
    if (hdr.payload_len > wire.MAX_PAYLOAD_LEN) {
        cli_ui.printErr("status response too large", .{});
        std.process.exit(1);
    }

    const payload = allocator.alloc(u8, hdr.payload_len) catch {
        cli_ui.printErr("allocation failed", .{});
        std.process.exit(1);
    };
    defer allocator.free(payload);
    wire.readExact(fd, payload) catch |err| {
        cli_ui.printErr("failed to read session status payload: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    var off: usize = 0;
    if (off + @sizeOf(wire.StatusResp) > payload.len) return;
    const status_hdr = std.mem.bytesToValue(wire.StatusResp, payload[off..][0..@sizeOf(wire.StatusResp)]);
    off += @sizeOf(wire.StatusResp);

    if (json_output) {
        outputListJson(allocator, payload, off, status_hdr, filter_abs) catch |err| {
            cli_ui.printErr("failed to write JSON status: {s}", .{@errorName(err)});
        };
        return;
    }

    var out = std.fs.File.stdout().deprecatedWriter();
    const p = core.cli_ui.Palette.forStdout();
    const is_tty = posix.isatty(posix.STDOUT_FILENO);
    const filtering = filter_abs != null;

    // Header: profile + optional directory filter
    const inst = posix.getenv("HEXE_INSTANCE");
    const inst_name: []const u8 = if (inst) |n| (if (n.len > 0) n else "default") else "default";
    try out.print("{s}Profile:{s} {s}{s}{s}", .{ p.dim, p.reset, p.bold, inst_name, p.reset });
    if (filter_abs) |f| {
        var f_buf: [256]u8 = undefined;
        const f_disp = core.cli_ui.compactHome(f, &f_buf);
        try out.print("  {s}Directory:{s} {s}{s}{s}", .{ p.dim, p.reset, p.accent, f_disp, p.reset });
    }
    try out.writeAll("\n");

    var shown_attached: usize = 0;
    var shown_detached: usize = 0;
    var shown_orphaned: usize = 0;
    var shown_sticky: usize = 0;

    // Connected / attached sessions
    var shown_mux_header = false;
    var ci: u16 = 0;
    while (ci < status_hdr.client_count) : (ci += 1) {
        if (off + @sizeOf(wire.StatusClient) > payload.len) return;
        const sc = std.mem.bytesToValue(wire.StatusClient, payload[off..][0..@sizeOf(wire.StatusClient)]);
        off += @sizeOf(wire.StatusClient);

        if (off + sc.name_len > payload.len) return;
        const name_str = if (sc.name_len > 0) payload[off .. off + sc.name_len] else "unknown";
        off += sc.name_len;

        if (off + sc.session_state_len > payload.len) return;
        const session_state = if (sc.session_state_len > 0) payload[off .. off + sc.session_state_len] else "";
        off += sc.session_state_len;

        const base_root_opt: ?[]u8 = sessionStateBaseRoot(allocator, session_state);
        defer if (base_root_opt) |b| allocator.free(b);

        const show = !filtering or (base_root_opt != null and dirFilterMatches(allocator, filter_abs.?, base_root_opt.?));

        var pane_names = std.AutoHashMap([32]u8, []const u8).init(allocator);
        defer pane_names.deinit();

        var pi: u16 = 0;
        while (pi < sc.pane_count) : (pi += 1) {
            if (off + @sizeOf(wire.StatusPaneEntry) > payload.len) return;
            const pe = std.mem.bytesToValue(wire.StatusPaneEntry, payload[off..][0..@sizeOf(wire.StatusPaneEntry)]);
            off += @sizeOf(wire.StatusPaneEntry);

            if (off + pe.name_len > payload.len) return;
            const pname = if (pe.name_len > 0) payload[off .. off + pe.name_len] else "";
            off += pe.name_len;
            if (off + pe.sticky_pwd_len > payload.len) return;
            off += pe.sticky_pwd_len;

            if (pname.len > 0) {
                pane_names.put(pe.uuid, pname) catch |err| {
                    print("Error: failed to build pane name map: {s}\n", .{@errorName(err)});
                    std.process.exit(1);
                };
            }
        }

        if (!show) continue;
        shown_attached += 1;

        if (!shown_mux_header) {
            if (!filtering) {
                try out.print("\n{s}Attached sessions ({d}){s}\n", .{ p.bold, status_hdr.client_count, p.reset });
            } else {
                try out.print("\n{s}Attached sessions{s}\n", .{ p.bold, p.reset });
            }
            shown_mux_header = true;
        }

        const sid8: []const u8 = if (sc.has_session_id != 0) sc.session_id[0..8] else "????????";
        const pane_word: []const u8 = if (sc.pane_count == 1) "pane" else "panes";
        var root_buf: [256]u8 = undefined;
        const root_disp: []const u8 = if (base_root_opt) |br| core.cli_ui.compactHome(br, &root_buf) else "";

        try out.print("  {s}●{s} {s}{s:<14}{s} {s}[{s}]{s}  {d} {s}", .{
            p.success, p.reset,
            p.bold,    name_str, p.reset,
            p.muted,   sid8,     p.reset,
            sc.pane_count, pane_word,
        });
        if (root_disp.len > 0) {
            try out.print("  {s}{s}{s}", .{ p.dim, root_disp, p.reset });
        }
        try out.writeAll("\n");

        if (details and session_state.len > 0) {
            printSessionTree(allocator, out, p, session_state, "    ", &pane_names);
        }
    }

    // Detached sessions
    var shown_detached_header = false;
    var di: u16 = 0;
    while (di < status_hdr.detached_count) : (di += 1) {
        if (off + @sizeOf(wire.DetachedSessionEntry) > payload.len) return;
        const de = std.mem.bytesToValue(wire.DetachedSessionEntry, payload[off..][0..@sizeOf(wire.DetachedSessionEntry)]);
        off += @sizeOf(wire.DetachedSessionEntry);

        if (off + de.name_len > payload.len) return;
        const name_str = if (de.name_len > 0) payload[off .. off + de.name_len] else "unknown";
        off += de.name_len;

        if (off + de.session_state_len > payload.len) return;
        const session_state = if (de.session_state_len > 0) payload[off .. off + de.session_state_len] else "";
        off += de.session_state_len;

        const base_root_opt: ?[]u8 = sessionStateBaseRoot(allocator, session_state);
        defer if (base_root_opt) |b| allocator.free(b);

        if (filtering) {
            const matches = base_root_opt != null and dirFilterMatches(allocator, filter_abs.?, base_root_opt.?);
            if (!matches) continue;
        }
        shown_detached += 1;

        if (!shown_detached_header) {
            if (!filtering) {
                try out.print("\n{s}Detached sessions ({d}){s}\n", .{ p.bold, status_hdr.detached_count, p.reset });
            } else {
                try out.print("\n{s}Detached sessions{s}\n", .{ p.bold, p.reset });
            }
            shown_detached_header = true;
        }

        const uuid_prefix = de.session_id[0..8];
        const pane_word: []const u8 = if (de.pane_count == 1) "pane" else "panes";
        var root_buf: [256]u8 = undefined;
        const root_disp: []const u8 = if (base_root_opt) |br| core.cli_ui.compactHome(br, &root_buf) else "";

        try out.print("  {s}○{s} {s}{s:<14}{s} {s}[{s}]{s}  {d} {s}", .{
            p.warn,  p.reset,
            p.bold,  name_str, p.reset,
            p.muted, uuid_prefix, p.reset,
            de.pane_count, pane_word,
        });
        if (root_disp.len > 0) {
            try out.print("  {s}{s}{s}", .{ p.dim, root_disp, p.reset });
        }
        try out.writeAll("\n");

        if (details and session_state.len > 0) {
            printSessionTree(allocator, out, p, session_state, "    ", null);
        }
    }

    // Orphaned panes
    var shown_orphaned_header = false;
    var oi: u16 = 0;
    while (oi < status_hdr.orphaned_count) : (oi += 1) {
        if (off + @sizeOf(wire.StatusPaneEntry) > payload.len) return;
        const pe = std.mem.bytesToValue(wire.StatusPaneEntry, payload[off..][0..@sizeOf(wire.StatusPaneEntry)]);
        off += @sizeOf(wire.StatusPaneEntry);

        if (off + pe.name_len > payload.len) return;
        const pname = if (pe.name_len > 0) payload[off .. off + pe.name_len] else "";
        off += pe.name_len;
        if (off + pe.sticky_pwd_len > payload.len) return;
        off += pe.sticky_pwd_len;

        if (filtering) continue;
        shown_orphaned += 1;
        if (!shown_orphaned_header) {
            try out.print("\n{s}Orphaned panes ({d}){s}\n", .{ p.bold, status_hdr.orphaned_count, p.reset });
            shown_orphaned_header = true;
        }
        const disp_name: []const u8 = if (pname.len > 0) pname else "-";
        try out.print("  {s}◌{s} {s}{s:<14}{s} {s}[{s}]{s}  {s}pid={d}{s}\n", .{
            p.muted, p.reset, p.bold, disp_name, p.reset, p.muted, pe.uuid[0..8], p.reset, p.dim, pe.pid, p.reset,
        });
    }

    // Sticky panes
    var shown_sticky_header = false;
    var si: u16 = 0;
    while (si < status_hdr.sticky_count) : (si += 1) {
        if (off + @sizeOf(wire.StickyPaneEntry) > payload.len) return;
        const se = std.mem.bytesToValue(wire.StickyPaneEntry, payload[off..][0..@sizeOf(wire.StickyPaneEntry)]);
        off += @sizeOf(wire.StickyPaneEntry);

        if (off + se.name_len > payload.len) return;
        const sname = if (se.name_len > 0) payload[off .. off + se.name_len] else "";
        off += se.name_len;

        if (off + se.pwd_len > payload.len) return;
        const pwd = if (se.pwd_len > 0) payload[off .. off + se.pwd_len] else "";
        off += se.pwd_len;

        if (filtering) {
            if (pwd.len == 0 or !dirFilterMatches(allocator, filter_abs.?, pwd)) continue;
        }
        shown_sticky += 1;
        if (!shown_sticky_header) {
            if (!filtering) {
                try out.print("\n{s}Sticky panes ({d}){s}\n", .{ p.bold, status_hdr.sticky_count, p.reset });
            } else {
                try out.print("\n{s}Sticky panes{s}\n", .{ p.bold, p.reset });
            }
            shown_sticky_header = true;
        }

        var pwd_buf: [256]u8 = undefined;
        const pwd_disp = if (pwd.len > 0) core.cli_ui.compactHome(pwd, &pwd_buf) else "";
        const disp_name: []const u8 = if (sname.len > 0) sname else "sticky";
        try out.print("  {s}◆{s} {s}{s:<14}{s} {s}[{s}]{s}  {s}pid={d}{s}", .{
            p.accent, p.reset, p.bold, disp_name, p.reset, p.muted, se.uuid[0..8], p.reset, p.dim, se.pid, p.reset,
        });
        if (se.key != 0) try out.print("  {s}key={c}{s}", .{ p.special, se.key, p.reset });
        if (pwd_disp.len > 0) try out.print("  {s}{s}{s}", .{ p.dim, pwd_disp, p.reset });
        try out.writeAll("\n");
    }

    if (shown_attached == 0 and shown_detached == 0 and shown_orphaned == 0 and shown_sticky == 0) {
        if (filtering) {
            try out.print("\n{s}No sessions rooted in this directory.{s}\n", .{ p.dim, p.reset });
        } else {
            try out.print("\n{s}No active sessions.{s}", .{ p.dim, p.reset });
            if (is_tty) try out.print(" Start one with {s}hexe new{s}", .{ p.accent, p.reset });
            try out.writeAll("\n");
        }
    } else if (is_tty and (shown_attached > 0 or shown_detached > 0)) {
        var attach_buf: [128]u8 = undefined;
        const attach_hint = core.cli_ui.formatAttachCmd(&attach_buf, "<name|id>", inst);
        try out.print("\n{s}Attach:{s} {s}{s}{s}  {s}·{s}  {s}Interactive picker:{s} {s}hexe attach{s}\n", .{
            p.dim, p.reset, p.accent, attach_hint, p.reset, p.dim, p.reset, p.dim, p.reset, p.accent, p.reset,
        });
    }
}

pub fn runSessionLayoutList(allocator: std.mem.Allocator, json_output: bool) !void {
    var registry = try session_config.loadLayoutRegistry(allocator);
    defer session_config.deinitLayoutRegistry(allocator, &registry);

    std.mem.sort(session_config.LayoutRegistryEntry, registry.entries, {}, struct {
        fn lessThan(_: void, a: session_config.LayoutRegistryEntry, b: session_config.LayoutRegistryEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch "";

    if (json_output) {
        const stdout = std.fs.File.stdout();
        try stdout.writeAll("[");
        for (registry.entries, 0..) |entry, i| {
            if (i > 0) try stdout.writeAll(",");
            try stdout.writeAll("\n  {\"name\":\"");
            try writeJsonStr(stdout, entry.name);
            try stdout.writeAll("\",\"path\":\"");
            try writeJsonStr(stdout, entry.path);
            try stdout.writeAll("\"");

            if (std.mem.eql(u8, cwd, entry.path)) {
                const config_path = try std.fmt.allocPrint(allocator, "{s}/.hexe.lua", .{entry.path});
                defer allocator.free(config_path);
                if (session_config.parseSessionLua(allocator, config_path)) |cfg| {
                    var owned_cfg = cfg;
                    defer owned_cfg.deinit(allocator);
                    try stdout.writeAll(",\"details\":{");
                    if (owned_cfg.name) |n| {
                        try stdout.writeAll("\"name\":\"");
                        try writeJsonStr(stdout, n);
                        try stdout.writeAll("\",");
                    }
                    try stdout.writeAll("\"tabs\":");
                    var b1: [32]u8 = undefined;
                    const tabs_s = std.fmt.bufPrint(&b1, "{d}", .{owned_cfg.tabs.len}) catch "0";
                    try stdout.writeAll(tabs_s);
                    try stdout.writeAll(",\"floats\":");
                    var b2: [32]u8 = undefined;
                    const floats_s = std.fmt.bufPrint(&b2, "{d}", .{owned_cfg.floats.len}) catch "0";
                    try stdout.writeAll(floats_s);
                    try stdout.writeAll("}");
                } else |_| {}
            }
            try stdout.writeAll("}");
        }
        try stdout.writeAll("\n]\n");
        return;
    }

    var out = std.fs.File.stdout().deprecatedWriter();
    const p = core.cli_ui.Palette.forStdout();

    if (registry.entries.len == 0) {
        try out.print("{s}No saved layouts found.{s}\n", .{ p.dim, p.reset });
        return;
    }

    for (registry.entries) |entry| {
        var path_buf: [256]u8 = undefined;
        const path_disp = core.cli_ui.compactHome(entry.path, &path_buf);
        const is_cwd = std.mem.eql(u8, cwd, entry.path);
        const mark: []const u8 = if (is_cwd) "●" else "○";
        const mark_col: []const u8 = if (is_cwd) p.success else p.muted;
        try out.print("  {s}{s}{s} {s}{s:<16}{s}  {s}{s}{s}\n", .{
            mark_col, mark, p.reset, p.bold, entry.name, p.reset, p.dim, path_disp, p.reset,
        });
        if (is_cwd) {
            const config_path = std.fmt.allocPrint(allocator, "{s}/.hexe.lua", .{entry.path}) catch continue;
            defer allocator.free(config_path);
            if (session_config.parseSessionLua(allocator, config_path)) |cfg| {
                var owned_cfg = cfg;
                defer owned_cfg.deinit(allocator);
                try out.print("      {s}tabs={d}  floats={d}", .{ p.dim, owned_cfg.tabs.len, owned_cfg.floats.len });
                if (owned_cfg.root) |r| try out.print("  root={s}", .{r});
                try out.print("{s}\n", .{p.reset});
            } else |_| {}
        }
    }
}

pub fn runInfo(allocator: std.mem.Allocator, target: shared.PaneTarget) !void {
    const wire = core.wire;
    const posix = std.posix;

    const resolved = resolvePaneTarget(allocator, target) catch |err| exitUnresolved(err, target);
    const target_uuid = resolved.uuid;

    // Query SES for pane info via binary protocol
    const fd = connectSesCliChannel(allocator) orelse std.process.exit(1);
    defer posix.close(fd);

    var pu: wire.PaneUuid = undefined;
    pu.uuid = target_uuid;
    wire.writeControl(fd, .pane_info, std.mem.asBytes(&pu)) catch |err| {
        cli_ui.printErr("failed to request pane info: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    // Read response
    const hdr = wire.readControlHeader(fd) catch |err| {
        cli_ui.printErr("failed to read pane info response: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type == .pane_not_found) {
        cli_ui.printErr("pane not found", .{});
        std.process.exit(1);
    }
    if (msg_type != .pane_info or hdr.payload_len < @sizeOf(wire.PaneInfoResp)) {
        cli_ui.printErr("invalid response from daemon", .{});
        std.process.exit(1);
    }

    const resp = wire.readStruct(wire.PaneInfoResp, fd) catch |err| {
        cli_ui.printErr("failed to read pane info payload: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    // Read trailing data
    const trail_len = hdr.payload_len - @sizeOf(wire.PaneInfoResp);
    var trail_buf: [8192]u8 = undefined;
    if (trail_len > trail_buf.len) {
        cli_ui.printErr("invalid response from daemon (pane_info payload too large)", .{});
        std.process.exit(1);
    }
    if (trail_len > 0) {
        wire.readExact(fd, trail_buf[0..trail_len]) catch |err| {
            cli_ui.printErr("failed to read pane info trail: {s}", .{@errorName(err)});
            std.process.exit(1);
        };
    }

    // Parse trailing data in order: name, fg, cwd, tty, socket, session_name, layout, last_cmd, base_process, sticky_pwd
    var off: usize = 0;
    if (off + resp.name_len > trail_len) {
        print("Invalid response from daemon (malformed pane_info payload)\n", .{});
        std.process.exit(1);
    }
    const name = trail_buf[off .. off + resp.name_len];
    off += resp.name_len;
    if (off + resp.fg_len > trail_len) {
        print("Invalid response from daemon (malformed pane_info payload)\n", .{});
        std.process.exit(1);
    }
    const fg_process = trail_buf[off .. off + resp.fg_len];
    off += resp.fg_len;
    if (off + resp.cwd_len > trail_len) {
        print("Invalid response from daemon (malformed pane_info payload)\n", .{});
        std.process.exit(1);
    }
    const cwd_str = trail_buf[off .. off + resp.cwd_len];
    off += resp.cwd_len;
    if (off + resp.tty_len > trail_len) {
        print("Invalid response from daemon (malformed pane_info payload)\n", .{});
        std.process.exit(1);
    }
    const tty_str = trail_buf[off .. off + resp.tty_len];
    off += resp.tty_len;
    if (off + resp.socket_path_len > trail_len) {
        print("Invalid response from daemon (malformed pane_info payload)\n", .{});
        std.process.exit(1);
    }
    const socket_path = trail_buf[off .. off + resp.socket_path_len];
    off += resp.socket_path_len;
    if (off + resp.session_name_len > trail_len) {
        print("Invalid response from daemon (malformed pane_info payload)\n", .{});
        std.process.exit(1);
    }
    const session_name = trail_buf[off .. off + resp.session_name_len];
    off += resp.session_name_len;
    if (off + resp.layout_path_len > trail_len) {
        print("Invalid response from daemon (malformed pane_info payload)\n", .{});
        std.process.exit(1);
    }
    const layout_path = trail_buf[off .. off + resp.layout_path_len];
    off += resp.layout_path_len;
    if (off + resp.last_cmd_len > trail_len) {
        print("Invalid response from daemon (malformed pane_info payload)\n", .{});
        std.process.exit(1);
    }
    const last_cmd = trail_buf[off .. off + resp.last_cmd_len];
    off += resp.last_cmd_len;
    if (off + resp.base_process_len > trail_len) {
        print("Invalid response from daemon (malformed pane_info payload)\n", .{});
        std.process.exit(1);
    }
    const base_process = trail_buf[off .. off + resp.base_process_len];
    off += resp.base_process_len;
    if (off + resp.sticky_pwd_len > trail_len) {
        print("Invalid response from daemon (malformed pane_info payload)\n", .{});
        std.process.exit(1);
    }
    _ = trail_buf[off .. off + resp.sticky_pwd_len]; // sticky_pwd (not displayed currently)

    // The report goes to stdout: `hexe terminal info | grep Name` is a
    // reasonable thing to do, and the errors above are on stderr because
    // they are not the answer.
    var out = std.fs.File.stdout().deprecatedWriter();
    const p = cli_ui.Palette.forStdout();
    const is_tty = posix.isatty(posix.STDOUT_FILENO);

    try out.print("{s}Pane Info:{s}\n", .{ p.bold, p.reset });
    try out.print("  {s}UUID:{s} {s}{s}{s}\n", .{ p.dim, p.reset, p.muted, &target_uuid, p.reset });
    try out.print("  {s}Shell PID:{s} {d}\n", .{ p.dim, p.reset, resp.pid });

    if (resp.base_process_len > 0) {
        try out.print("  {s}Base Process:{s} {s}{s}{s} {s}(pid={d}){s}\n", .{ p.dim, p.reset, p.bold, base_process, p.reset, p.dim, resp.base_pid, p.reset });
    }
    if (resp.fg_len > 0) {
        try out.print("  {s}Active Process:{s} {s}{s}{s} {s}(pid={d}){s}\n", .{ p.dim, p.reset, p.accent, fg_process, p.reset, p.dim, resp.fg_pid, p.reset });
    }
    if (resp.cwd_len > 0) {
        var cwd_buf: [512]u8 = undefined;
        const cwd_disp = if (is_tty) cli_ui.compactHome(cwd_str, &cwd_buf) else cwd_str;
        try out.print("  {s}CWD:{s} {s}{s}{s}\n", .{ p.dim, p.reset, p.accent, cwd_disp, p.reset });
    }
    if (resp.name_len > 0) {
        try out.print("  {s}Name:{s} {s}{s}{s}\n", .{ p.dim, p.reset, p.bold, name, p.reset });
    }
    if (resp.tty_len > 0) {
        try out.print("  {s}TTY:{s} {s}{s}{s}\n", .{ p.dim, p.reset, p.muted, tty_str, p.reset });
    }
    if (resp.cols > 0 and resp.rows > 0) {
        try out.print("  {s}Window:{s} {d}x{d}\n", .{ p.dim, p.reset, resp.cols, resp.rows });
    }
    if (resp.session_name_len > 0) {
        try out.print("  {s}Session:{s} {s}{s}{s}\n", .{ p.dim, p.reset, p.bold, session_name, p.reset });
    }
    if (resp.has_created_from != 0) {
        try out.print("  {s}Creator:{s} {s}{s}{s}\n", .{ p.dim, p.reset, p.muted, resp.created_from[0..8], p.reset });
    }
    if (resp.has_focused_from != 0) {
        try out.print("  {s}Last:{s} {s}{s}{s}\n", .{ p.dim, p.reset, p.muted, resp.focused_from[0..8], p.reset });
    }
    if (resp.layout_path_len > 0) {
        try out.print("  {s}Layout:{s} {s}{s}{s}\n", .{ p.dim, p.reset, p.dim, layout_path, p.reset });
    }
    if (resp.socket_path_len > 0) {
        try out.print("  {s}Socket:{s} {s}{s}{s}\n", .{ p.dim, p.reset, p.dim, socket_path, p.reset });
    }
    const focused = resp.is_focused != 0;
    try out.print("  {s}Focused:{s} {s}{}{s}\n", .{ p.dim, p.reset, if (focused) p.success else p.muted, focused, p.reset });
    const is_float = resp.pane_type == 1;
    const pane_type_str: []const u8 = if (is_float) "float" else "split";
    try out.print("  {s}Type:{s} {s}{s}{s}\n", .{ p.dim, p.reset, if (is_float) p.special else p.success, pane_type_str, p.reset });
    try out.print("  {s}Cursor:{s} {d},{d}\n", .{ p.dim, p.reset, resp.cursor_x, resp.cursor_y });
    try out.print("  {s}Cursor Style:{s} {d}\n", .{ p.dim, p.reset, resp.cursor_style });
    const cur_vis = resp.cursor_visible != 0;
    try out.print("  {s}Cursor Visible:{s} {s}{}{s}\n", .{ p.dim, p.reset, if (cur_vis) p.success else p.muted, cur_vis, p.reset });
    const alt_scr = resp.alt_screen != 0;
    try out.print("  {s}Alt Screen:{s} {s}{}{s}\n", .{ p.dim, p.reset, if (alt_scr) p.warn else p.muted, alt_scr, p.reset });

    if (resp.last_cmd_len > 0) {
        try out.print("  {s}Last Cmd:{s} {s}{s}{s}\n", .{ p.dim, p.reset, p.bold, last_cmd, p.reset });
    }
    if (resp.has_last_status != 0) {
        const status_col: []const u8 = if (resp.last_status == 0) p.success else p.err;
        try out.print("  {s}Last Status:{s} {s}{d}{s}\n", .{ p.dim, p.reset, status_col, resp.last_status, p.reset });
    }
    if (resp.has_last_duration != 0) {
        try out.print("  {s}Last Duration:{s} {d}ms\n", .{ p.dim, p.reset, resp.last_duration_ms });
    }
    if (resp.has_last_jobs != 0) {
        try out.print("  {s}Last Jobs:{s} {d}\n", .{ p.dim, p.reset, resp.last_jobs });
    }
}

pub fn runNotify(allocator: std.mem.Allocator, target: shared.PaneTarget, broadcast: bool, message: []const u8) !void {
    const wire = core.wire;
    const posix = std.posix;

    if (message.len == 0) {
        // A bare `return` exits 0, so a script could not tell that the notify
        // never went anywhere.
        cli_ui.printErr("message is required", .{});
        std.process.exit(1);
    }

    var target_uuid: [32]u8 = undefined;
    var has_target = false;
    if (!broadcast) {
        const resolved = resolvePaneTarget(allocator, target) catch |err| exitUnresolved(err, target);
        target_uuid = resolved.uuid;
        has_target = true;
    }

    const fd = connectSesCliChannel(allocator) orelse std.process.exit(1);
    defer posix.close(fd);

    if (has_target) {
        const tn = wire.TargetedNotify{
            .uuid = target_uuid,
            .timeout_ms = 0,
            .msg_len = @intCast(message.len),
        };
        wire.writeControlWithTrail(fd, .targeted_notify, std.mem.asBytes(&tn), message) catch |err| {
            cli_ui.printErr("failed to send targeted notify: {s}", .{@errorName(err)});
        };
    } else {
        const n = wire.Notify{ .msg_len = @intCast(message.len) };
        wire.writeControlWithTrail(fd, .broadcast_notify, std.mem.asBytes(&n), message) catch |err| {
            cli_ui.printErr("failed to send broadcast notify: {s}", .{@errorName(err)});
        };
    }
}

// ─── Pane addressing ───────────────────────────────────────────────────────

/// One pane, from however the command line named it.
///
/// The address is session → pane, and this is the only place it is interpreted.
/// It used to be a ladder hand-copied into `runSend`, `runNotify` and `runInfo`,
/// each with its own wording and none of them accepting a pane name — so the
/// name a person actually knows was the one thing you could not type.
///
/// Resolution of a name or uuid prefix happens on the daemon
/// (`resolve_pane_target`), because only the daemon sees every session: a
/// session's control socket exists only while a frontend is attached, while its
/// panes keep running. Ambiguity comes back as an error, never as a pick.
pub fn resolvePaneTarget(
    allocator: std.mem.Allocator,
    target: shared.PaneTarget,
) shared.ResolveError!shared.ResolvedPane {
    // `--creator`/`--last` are about the pane this command runs in, so they are
    // answered the old way: by asking SES about our own pane's lineage.
    if (target.creator or target.last) {
        const resolved = resolveRelatedPane(allocator, target.creator) orelse return shared.ResolveError.NoSuchPane;
        return .{ .uuid = resolved, .attached = true };
    }

    // `--chip` is relative to a family, so it is resolved before the selectors
    // that name a pane outright: `--uuid` beside it names which family, not
    // which pane.
    if (target.chip) |chip| {
        var resolved_buf: [32]u8 = undefined;
        const base: []const u8 = if (target.uuid.len == 32)
            target.uuid
        else if (target.uuid.len > 0) blk: {
            const hit = askSesToResolve(allocator, target.session, target.uuid, true) catch |err| return err;
            resolved_buf = hit.uuid;
            break :blk resolved_buf[0..];
        } else if (target.pane.len > 0) blk: {
            const hit = askSesToResolve(allocator, target.session, target.pane, false) catch |err| return err;
            resolved_buf = hit.uuid;
            break :blk resolved_buf[0..];
        } else std.posix.getenv("HEXE_PANE_UUID") orelse {
            cli_ui.printErr("--chip addresses this float's family, so it needs a pane", .{});
            cli_ui.printErrHint("Run it inside a float, or name the family with --uuid or --pane.", .{});
            return shared.ResolveError.NoTarget;
        };
        if (base.len != 32) return shared.ResolveError.NoTarget;

        const session: ?[]const u8 = if (target.session.len > 0) target.session else null;
        const found = api_cmd.resolveFamilyChip(allocator, session, base, chip) catch {
            return shared.ResolveError.Unreachable;
        };
        const member = found orelse {
            cli_ui.printErr("this float's family has no chip {d}", .{chip});
            cli_ui.printErrHint("`hexe api floats` lists the family and its chip numbers.", .{});
            return shared.ResolveError.NoSuchPane;
        };
        return askSesToResolve(allocator, target.session, &member, true);
    }

    // Even a full uuid is resolved rather than trusted: "that pane does not
    // exist" has to be one answer with one exit code, and skipping the lookup
    // here made a uuid nobody holds fail later, differently, further in.
    if (target.uuid.len > 0) {
        return askSesToResolve(allocator, target.session, target.uuid, true);
    }
    if (target.pane.len > 0) {
        // A short pane name made of hex digits is also a plausible uuid prefix.
        // Try it as a name first -- that is what the flag said -- and only fall
        // back to a prefix when no pane answers to the name.
        if (askSesToResolve(allocator, target.session, target.pane, false)) |hit| {
            return hit;
        } else |err| {
            if (err != shared.ResolveError.NoSuchPane) return err;
            if (!shared.looksLikeUuidPrefix(target.pane)) return err;
            return askSesToResolve(allocator, target.session, target.pane, true);
        }
    }

    // Inside a pane, the pane itself is the default target.
    const env_uuid = std.posix.getenv("HEXE_PANE_UUID") orelse return shared.ResolveError.NoTarget;
    const u = parseUuid32Hex(env_uuid) orelse return shared.ResolveError.NoTarget;
    return .{ .uuid = u, .attached = true };
}

fn askSesToResolve(
    allocator: std.mem.Allocator,
    session: []const u8,
    pane: []const u8,
    pane_is_uuid: bool,
) shared.ResolveError!shared.ResolvedPane {
    const wire = core.wire;
    const posix = std.posix;

    const fd = connectSesCliChannel(allocator) orelse return shared.ResolveError.Unreachable;
    defer posix.close(fd);

    const req = wire.ResolvePaneTarget{
        .session_len = @intCast(session.len),
        .pane_len = @intCast(pane.len),
        .pane_is_uuid = @intFromBool(pane_is_uuid),
    };
    // One trail, session then pane, matching the order the handler reads them.
    var trail: std.ArrayList(u8) = .empty;
    defer trail.deinit(allocator);
    trail.appendSlice(allocator, session) catch return shared.ResolveError.Unreachable;
    trail.appendSlice(allocator, pane) catch return shared.ResolveError.Unreachable;

    wire.writeControlWithTrail(fd, .resolve_pane_target, std.mem.asBytes(&req), trail.items) catch {
        return shared.ResolveError.Unreachable;
    };

    const hdr = wire.readControlHeader(fd) catch return shared.ResolveError.Unreachable;
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type != .resolve_pane_target or hdr.payload_len < @sizeOf(wire.ResolvePaneTargetResult)) {
        return shared.ResolveError.Unreachable;
    }
    const result = wire.readStruct(wire.ResolvePaneTargetResult, fd) catch {
        return shared.ResolveError.Unreachable;
    };

    var err_buf: [256]u8 = undefined;
    var err_msg: []const u8 = "";
    if (result.error_len > 0) {
        const n = @min(result.error_len, err_buf.len);
        if (wire.readExact(fd, err_buf[0..n])) |_| {
            err_msg = err_buf[0..n];
        } else |_| {}
    }

    const outcome: wire.ResolvePaneOutcome = @enumFromInt(result.outcome);
    switch (outcome) {
        .ok => return .{ .uuid = result.uuid, .attached = result.attached != 0 },
        .no_such_session => {
            cli_ui.printErr("no session matches '{s}'", .{session});
            return shared.ResolveError.NoSuchSession;
        },
        .ambiguous_session => {
            cli_ui.printErr("'{s}' matches several sessions", .{session});
            return shared.ResolveError.Ambiguous;
        },
        .ambiguous_pane => {
            cli_ui.printErr("{s}", .{if (err_msg.len > 0) err_msg else "several panes match"});
            return shared.ResolveError.Ambiguous;
        },
        .no_such_pane => return shared.ResolveError.NoSuchPane,
    }
}

/// `hexe terminal read` — a pane's text, on stdout.
///
/// Addressed and reached exactly like `send`: resolved through SES, answered by
/// the pod. So it reads a pane in a detached session too, which is where
/// reading back what a long job printed matters most.
///
/// Which text, in the order the flags are considered:
///
///   `-n <lines>`      the last N rows that have anything on them
///   `-c <commands>`   the output of the last N commands (needs OSC 133)
///   neither           the last command's output, if the pane has marks
///
/// With neither flag and no marks there is nothing sensible to return: the
/// screen cannot say where a command began. That is an error naming `-n`
/// rather than a screenful passed off as a command's output.
pub fn runRead(
    allocator: std.mem.Allocator,
    target: shared.PaneTarget,
    lines: u32,
    commands: u32,
) !void {
    if (lines > 0 and commands > 0) {
        cli_ui.printErr("give -n or -c, not both", .{});
        std.process.exit(1);
    }

    const resolved = resolvePaneTarget(allocator, target) catch |err| exitUnresolved(err, target);

    const mode: core.wire.PodReadMode = if (lines > 0) .lines else .commands;
    const count: u32 = if (lines > 0) lines else if (commands > 0) commands else 1;

    const got = shared.readPod(allocator, resolved.uuid, mode, count) catch |err| {
        switch (err) {
            error.PodNotRunning => {
                cli_ui.printErr("that pane's pod is not running", .{});
                std.process.exit(2);
            },
            error.NoPromptMarks => {
                cli_ui.printErr("this pane has no \"last command\" (no finished OSC 133 prompt marks)", .{});
                cli_ui.printErrHint("Read a fixed number of lines with -n <lines> instead.", .{});
                cli_ui.printErrHint("-c needs a shell that emits OSC 133 (oslo does; bash/zsh emit none by default).", .{});
                std.process.exit(3);
            },
            error.PaneUnreadable => {
                cli_ui.printErr("could not read that pane's screen", .{});
                std.process.exit(2);
            },
            else => {
                cli_ui.printErr("read failed: {s}", .{@errorName(err)});
                std.process.exit(2);
            },
        }
    };
    defer allocator.free(got.text);

    // stdout, so `hexe terminal read … | grep` is the point of the command.
    var out = std.fs.File.stdout().deprecatedWriter();
    try out.writeAll(got.text);
    if (got.text.len > 0 and got.text[got.text.len - 1] != '\n') try out.writeAll("\n");

    // On stderr so it cannot corrupt what a pipeline is reading, but is still
    // seen by a person: an answer that silently began mid-history would be
    // taken for the whole of it.
    if (got.truncated) {
        cli_ui.printErrHint("note: the pane's history ring had wrapped; this may start mid-history", .{});
    }
}

/// Report a failed resolve and exit with the status that names the reason.
pub fn exitUnresolved(err: shared.ResolveError, target: shared.PaneTarget) noreturn {
    switch (err) {
        shared.ResolveError.NoTarget => cli_ui.printErr(
            "no target (use --pane <name>, --uuid, --creator, --last, --broadcast, or run inside hexe)",
            .{},
        ),
        shared.ResolveError.NoSuchPane => {
            const named = if (target.pane.len > 0) target.pane else target.uuid;
            cli_ui.printErr("no pane matches '{s}'", .{named});
            cli_ui.printErrHint("List sessions and panes with: hexe ls --details", .{});
        },
        shared.ResolveError.Unreachable => cli_ui.printErr("cannot reach the ses daemon", .{}),
        // Already reported, with the candidates, by the resolver.
        shared.ResolveError.NoSuchSession, shared.ResolveError.Ambiguous => {},
    }
    std.process.exit(shared.resolveExitCode(err));
}

// ─── Binary CLI helpers ────────────────────────────────────────────────────

/// Connect to SES with CLI handshake byte. Returns fd on success.
pub fn connectSesCliChannel(allocator: std.mem.Allocator) ?std.posix.fd_t {
    const wire = core.wire;
    const socket_path = ipc.getSesSocketPath(allocator) catch |err| {
        cli_ui.printErr("failed to resolve ses socket path: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(socket_path);
    var client = ipc.Client.connect(socket_path) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            const p = cli_ui.Palette.forStderr();
            print("{s}○{s} ses daemon is not running\n", .{ p.muted, p.reset });
            if (p.enabled) {
                cli_ui.printErrHint("Start a session with: hexe new", .{});
            }
        } else {
            // Anything else (PermissionDenied on the socket, ENOENT on a stale
            // runtime dir, timeout) used to return null with nothing printed,
            // so the command died mute.
            cli_ui.printErr("cannot connect to ses daemon: {s}", .{@errorName(err)});
        }
        return null;
    };
    const fd = client.fd;

    // Guard against stale/wrong listeners on ses.sock (e.g. inherited fd bugs).
    // Without read/write timeouts, CLI commands can hang indefinitely.
    const timeout = std.posix.timeval{ .sec = 3, .usec = 0 };
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch |err| {
        cli_ui.printWarn("failed to set ses CLI receive timeout: {s}", .{@errorName(err)});
    };
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch |err| {
        cli_ui.printWarn("failed to set ses CLI send timeout: {s}", .{@errorName(err)});
    };

    wire.sendCliHandshake(fd) catch |err| {
        switch (err) {
            // The daemon rate-limits connections it did not open itself, and
            // refuses with an error frame rather than a hello. Said plainly:
            // reported as a handshake failure it reads as "wrong binary", and
            // the fix looks like rebuilding rather than slowing down.
            error.ServerRefusedConnection => {
                cli_ui.printErr("the ses daemon refused the connection (rate-limiting)", .{});
                cli_ui.printErrHint("Too many commands at once — retry, or batch the work.", .{});
            },
            error.RuntimeEpochMismatch => {
                cli_ui.printErr("this hexe speaks a different protocol than the running daemon", .{});
                cli_ui.printErrHint("Restart it: hexe kill <session>, or restart the daemon.", .{});
            },
            else => cli_ui.printErr("failed to handshake with ses daemon: {s}", .{@errorName(err)}),
        }
        client.close();
        return null;
    };
    return fd;
}

/// Query SES for a pane's created_from or focused_from UUID.
/// If `want_creator` is true, returns created_from; otherwise focused_from.
fn resolveRelatedPane(allocator: std.mem.Allocator, want_creator: bool) ?[32]u8 {
    const wire = core.wire;
    const posix = std.posix;

    const current_uuid = std.posix.getenv("HEXE_PANE_UUID") orelse {
        cli_ui.printErr("--creator/--last requires running inside hexe terminal", .{});
        return null;
    };
    const parsed_current = parseUuid32Hex(current_uuid) orelse return null;

    const fd = connectSesCliChannel(allocator) orelse return null;
    defer posix.close(fd);

    var pu: wire.PaneUuid = undefined;
    pu.uuid = parsed_current;
    wire.writeControl(fd, .pane_info, std.mem.asBytes(&pu)) catch |err| {
        cli_ui.printErr("failed to request current pane info: {s}", .{@errorName(err)});
        return null;
    };

    const hdr = wire.readControlHeader(fd) catch |err| {
        cli_ui.printErr("failed to read current pane info response: {s}", .{@errorName(err)});
        return null;
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type == .pane_not_found) {
        cli_ui.printErr("pane not found", .{});
        return null;
    }
    if (msg_type != .pane_info) {
        cli_ui.printErr("invalid current pane info response", .{});
        return null;
    }
    if (hdr.payload_len < @sizeOf(wire.PaneInfoResp)) {
        cli_ui.printErr("malformed current pane info response", .{});
        return null;
    }

    const resp = wire.readStruct(wire.PaneInfoResp, fd) catch |err| {
        cli_ui.printErr("failed to read current pane info payload: {s}", .{@errorName(err)});
        return null;
    };
    if (want_creator) {
        if (resp.has_created_from != 0) return resp.created_from;
        cli_ui.printErr("current pane has no creator", .{});
        return null;
    } else {
        if (resp.has_focused_from != 0) return resp.focused_from;
        cli_ui.printErr("current pane has no previous focus", .{});
        return null;
    }
}

// ─── End binary CLI helpers ────────────────────────────────────────────────

fn appendSessionLayoutPanes(
    allocator: std.mem.Allocator,
    node: ?*const core.session_model.SessionLayoutNode,
    out: *std.ArrayList([32]u8),
) !void {
    const root = node orelse return;
    switch (root.*) {
        .pane => |uuid| try out.append(allocator, uuid),
        .split => |split| {
            try appendSessionLayoutPanes(allocator, split.first, out);
            try appendSessionLayoutPanes(allocator, split.second, out);
        },
    }
}

pub fn printSessionTree(
    allocator: std.mem.Allocator,
    out: anytype,
    p: core.cli_ui.Palette,
    json: []const u8,
    indent: []const u8,
    pane_name_map: ?*const std.AutoHashMap([32]u8, []const u8),
) void {
    var snapshot = core.session_model.SessionSnapshot.fromJson(allocator, json) catch |err| {
        print("Error: failed to parse session tree snapshot: {s}\n", .{@errorName(err)});
        return;
    };
    defer snapshot.deinit();

    var global_floats: std.ArrayList(usize) = .empty;
    defer global_floats.deinit(allocator);
    for (snapshot.floats.items, 0..) |float_state, fi| {
        if (float_state.parent_tab == null) {
            global_floats.append(allocator, fi) catch |err| {
                print("Error: failed to collect global floats: {s}\n", .{@errorName(err)});
                return;
            };
        }
    }

    const top_count: usize = snapshot.tabs.items.len + global_floats.items.len;
    var top_index: usize = 0;

    for (snapshot.tabs.items, 0..) |tab, ti| {
        const marker = if (ti == snapshot.active_tab) "*" else " ";

        const is_last_top = (top_index + 1 == top_count);
        const branch = if (is_last_top) "└" else "├";

        var prefix_buf: [256]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{s}{s}─ ", .{ indent, branch }) catch indent;
        printTreeNode(out, p, prefix, marker, p.info, "tab", tab.name, tab.uuid[0..8]);

        var split_uuids: std.ArrayList([32]u8) = .empty;
        defer split_uuids.deinit(allocator);
        appendSessionLayoutPanes(allocator, tab.root, &split_uuids) catch |err| {
            print("Error: failed to collect panes for tab '{s}': {s}\n", .{ tab.name, @errorName(err) });
            return;
        };

        var children: std.ArrayList(struct {
            kind: enum { split, float },
            uuid: [32]u8,
        }) = .empty;
        defer children.deinit(allocator);

        for (split_uuids.items) |uuid| {
            children.append(allocator, .{ .kind = .split, .uuid = uuid }) catch |err| {
                print("Error: failed to render tab '{s}' split list: {s}\n", .{ tab.name, @errorName(err) });
                return;
            };
        }

        for (snapshot.floats.items) |float_state| {
            if (float_state.parent_tab) |parent_tab| {
                if (parent_tab == ti) {
                    children.append(allocator, .{ .kind = .float, .uuid = float_state.pane_uuid }) catch |err| {
                        print("Error: failed to render tab '{s}' float list: {s}\n", .{ tab.name, @errorName(err) });
                        return;
                    };
                }
            }
        }

        if (children.items.len > 0) {
            const next_indent = if (is_last_top) "   " else "│  ";
            var child_indent_buf: [256]u8 = undefined;
            const child_indent = std.fmt.bufPrint(&child_indent_buf, "{s}{s}", .{ indent, next_indent }) catch indent;

            for (children.items, 0..) |child, ci| {
                const is_last_child = (ci + 1 == children.items.len);
                const cbranch = if (is_last_child) "└" else "├";
                var lp_buf: [256]u8 = undefined;
                const lp = std.fmt.bufPrint(&lp_buf, "{s}{s}─ ", .{ child_indent, cbranch }) catch child_indent;

                const sym = switch (child.kind) {
                    .split => if (tab.focused_pane_uuid) |focused_uuid|
                        if (std.mem.eql(u8, &focused_uuid, &child.uuid)) ">" else " "
                    else
                        " ",
                    .float => if (snapshot.active_float_uuid) |focused_uuid|
                        if (std.mem.eql(u8, &focused_uuid, &child.uuid)) ">" else " "
                    else
                        " ",
                };
                const pname = if (pane_name_map) |m| (m.get(child.uuid) orelse "-") else "-";

                switch (child.kind) {
                    .split => printTreeNode(out, p, lp, sym, p.success, "split", pname, child.uuid[0..8]),
                    .float => printTreeNode(out, p, lp, sym, p.special, "float", pname, child.uuid[0..8]),
                }
            }
        }

        top_index += 1;
    }

    for (global_floats.items) |fi| {
        const float_state = snapshot.floats.items[fi];
        const sym = if (snapshot.active_float_uuid) |focused_uuid|
            if (std.mem.eql(u8, &focused_uuid, &float_state.pane_uuid)) ">" else " "
        else
            " ";
        const pname = if (pane_name_map) |m| (m.get(float_state.pane_uuid) orelse "-") else "-";

        const is_last_top = (top_index + 1 == top_count);
        const branch = if (is_last_top) "└" else "├";
        var prefix_buf: [256]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{s}{s}─ ", .{ indent, branch }) catch indent;
        printTreeNode(out, p, prefix, sym, p.special, "float", pname, float_state.pane_uuid[0..8]);

        top_index += 1;
    }
}

pub fn runSend(allocator: std.mem.Allocator, target: shared.PaneTarget, broadcast: bool, enter: bool, ctrl: []const u8, text: []const u8) !void {
    const wire = core.wire;
    const posix = std.posix;

    // Build the data to send.
    var data_buf: [4096]u8 = undefined;
    var data_len: usize = 0;

    if (ctrl.len > 0) {
        if (ctrl.len == 1 and ctrl[0] >= 'a' and ctrl[0] <= 'z') {
            data_buf[0] = ctrl[0] - 'a' + 1;
            data_len = 1;
        } else if (ctrl.len == 1 and ctrl[0] >= 'A' and ctrl[0] <= 'Z') {
            data_buf[0] = ctrl[0] - 'A' + 1;
            data_len = 1;
        } else {
            cli_ui.printErr("--ctrl requires a single letter (a-z)", .{});
            std.process.exit(1);
        }
    } else if (text.len > 0) {
        if (text.len > data_buf.len - 1) {
            cli_ui.printErr("text too long", .{});
            std.process.exit(1);
        }
        @memcpy(data_buf[0..text.len], text);
        data_len = text.len;
    }

    if (enter and data_len < data_buf.len) {
        data_buf[data_len] = '\n';
        data_len += 1;
    }

    if (data_len == 0) {
        cli_ui.printErr("no data to send (use text argument, --ctrl, or --enter)", .{});
        std.process.exit(1);
    }

    // One pane goes straight to its pod, which owns the pty and outlives the
    // frontend, so typing reaches a detached session too. Broadcast still goes
    // through SES: only SES knows which panes a session has.
    if (!broadcast) {
        const resolved = resolvePaneTarget(allocator, target) catch |err| exitUnresolved(err, target);
        shared.writePodInput(allocator, resolved.uuid, data_buf[0..data_len]) catch |err| {
            if (err == error.PodNotRunning) {
                cli_ui.printErr("that pane's pod is not running", .{});
                std.process.exit(2);
            }
            cli_ui.printErr("failed to send keys: {s}", .{@errorName(err)});
            std.process.exit(2);
        };
        return;
    }

    const fd = connectSesCliChannel(allocator) orelse std.process.exit(1);
    defer posix.close(fd);

    const sk = wire.SendKeys{
        .uuid = .{0} ** 32,
        .data_len = @intCast(data_len),
    };
    wire.writeControlWithTrail(fd, .send_keys, std.mem.asBytes(&sk), data_buf[0..data_len]) catch |err| {
        cli_ui.printErr("failed to send keys: {s}", .{@errorName(err)});
    };
}

/// Ask the current mux to move focus in the given direction.
///
/// Intended for editor integration: Neovim tries wincmd first, and if it
/// cannot move, it calls this.
pub fn runFocusMove(allocator: std.mem.Allocator, dir: []const u8) !void {
    const wire = core.wire;

    const dir_norm = std.mem.trim(u8, dir, " \t\n\r");
    const dir_byte: u8 = if (std.mem.eql(u8, dir_norm, "left"))
        0
    else if (std.mem.eql(u8, dir_norm, "right"))
        1
    else if (std.mem.eql(u8, dir_norm, "up"))
        2
    else if (std.mem.eql(u8, dir_norm, "down"))
        3
    else {
        cli_ui.printErr("invalid dir (use left/right/up/down)", .{});
        std.process.exit(1);
    };

    const ses_path = ipc.getSesSocketPath(allocator) catch {
        cli_ui.printErr("cannot determine ses socket path", .{});
        std.process.exit(1);
    };
    defer allocator.free(ses_path);

    var client = ipc.Client.connect(ses_path) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            cli_ui.printErr("ses daemon is not running", .{});
            std.process.exit(1);
        }
        return err;
    };
    defer client.close();
    const fd = client.fd;

    const pane_uuid = std.posix.getenv("HEXE_PANE_UUID") orelse {
        cli_ui.printErr("HEXE_PANE_UUID not set (not running inside mux?)", .{});
        std.process.exit(1);
    };
    const pane_uuid_arr = parseUuid32Hex(pane_uuid) orelse {
        cli_ui.printErr("HEXE_PANE_UUID invalid length", .{});
        std.process.exit(1);
    };

    // Send versioned CLI handshake.
    wire.sendCliHandshake(fd) catch {
        cli_ui.printErr("handshake failed", .{});
        std.process.exit(1);
    };

    // Send focus_move message.
    var fm: wire.FocusMove = undefined;
    fm.uuid = pane_uuid_arr;
    fm.dir = dir_byte;
    wire.writeControl(fd, .focus_move, std.mem.asBytes(&fm)) catch {
        cli_ui.printErr("failed to send focus_move", .{});
        std.process.exit(1);
    };
}

/// Ask mux whether the current shell should be allowed to exit.
/// Intended to be called from shell keybindings (exit/Ctrl+D) so mux can
/// present a confirm dialog for the last split.
///
/// Exit codes: 0=allow, 1=deny
// libc's environment, the same symbol `pty.zig` reads. This process was forked
// by the shell, so this IS the shell's exported environment.
extern var environ: [*:null]?[*:0]u8;

/// `hexe shell env-save` — publish this shell's environment to the pane's file.
///
/// The environment cannot be fetched on demand: a shell running a foreground
/// command is blocked in `waitpid`, and that is exactly when a float gets
/// opened. So the shell pushes, at every prompt, and SES reads whenever it
/// likes.
///
/// This process's own environment IS the shell's exported environment, which is
/// what makes the helper trivial and shell-agnostic — the same one line in all
/// four integrations, replacing four different spellings of `env -0 >`.
pub fn runEnvSave() !void {
    const text = std.posix.getenv("HEXE_ENV_FD") orelse return;
    const fd = std.fmt.parseInt(i32, text, 10) catch return;
    if (fd < 3) return;

    // Rewritten in place from the start, not appended: this file is the current
    // environment, not a log of every prompt.
    std.posix.ftruncate(fd, 0) catch |err| {
        core.logging.logError("shell", "failed to truncate pane env descriptor", err);
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.page_allocator);

    var i: usize = 0;
    while (environ[i]) |entry| : (i += 1) {
        const line = std.mem.span(entry);
        buf.appendSlice(std.heap.page_allocator, line) catch return;
        buf.append(std.heap.page_allocator, 0) catch return;
    }

    var off: usize = 0;
    while (off < buf.items.len) {
        // pwrite, so the offset is ours: the descriptor is shared with SES and
        // with every other `env-save` this shell has run, and a shared file
        // offset would have them writing over each other.
        const n = std.posix.pwrite(fd, buf.items[off..], off) catch |err| {
            core.logging.logError("shell", "failed to write pane environment", err);
            return;
        };
        if (n == 0) break;
        off += n;
    }
}

pub fn runExitIntent(allocator: std.mem.Allocator) !void {
    const wire = core.wire;

    const pane_uuid = std.posix.getenv("HEXE_PANE_UUID") orelse {
        std.process.exit(0);
    };
    const pane_uuid_arr = parseUuid32Hex(pane_uuid) orelse {
        std.process.exit(0);
    };

    const ses_path = ipc.getSesSocketPath(allocator) catch {
        std.process.exit(0);
    };
    defer allocator.free(ses_path);

    var client = ipc.Client.connect(ses_path) catch {
        // If ses is unreachable, don't trap the shell.
        std.process.exit(0);
    };
    defer client.close();
    const fd = client.fd;

    // Send versioned CLI handshake.
    wire.sendCliHandshake(fd) catch {
        std.process.exit(0);
    };

    // Send exit_intent message.
    var ei: wire.ExitIntent = undefined;
    ei.uuid = pane_uuid_arr;
    wire.writeControl(fd, .exit_intent, std.mem.asBytes(&ei)) catch {
        std.process.exit(0);
    };

    // Wait for exit_intent_result — this may block on an interactive close-
    // confirm popup for as long as the user takes, so wait UNBOUNDED (the 10s
    // wire default aborted the confirm after 10s).
    const hdr = wire.readControlHeaderBlocking(fd) catch {
        std.process.exit(0);
    };
    if (@as(wire.MsgType, @enumFromInt(hdr.msg_type)) != .exit_intent_result) {
        std.process.exit(0);
    }
    const result = wire.readStruct(wire.ExitIntentResult, fd) catch {
        std.process.exit(0);
    };

    if (result.allow != 0) {
        std.process.exit(0);
    }
    std.process.exit(1);
}

pub fn runShellEvent(
    cmd: []const u8,
    status: i64,
    duration_ms: i64,
    cwd: []const u8,
    jobs: i64,
    phase: []const u8,
    running: bool,
    started_at_ms: i64,
) !void {
    const pod_socket = std.posix.getenv("HEXE_POD_SOCKET") orelse return;

    if (status < std.math.minInt(i32) or status > std.math.maxInt(i32)) {
        cli_ui.printErr("status out of range for shell event", .{});
        std.process.exit(1);
    }
    if (jobs < 0 or jobs > std.math.maxInt(u16)) {
        cli_ui.printErr("jobs out of range for shell event", .{});
        std.process.exit(1);
    }
    if (cmd.len > std.math.maxInt(u16) or cwd.len > std.math.maxInt(u16)) {
        cli_ui.printErr("shell event payload too long", .{});
        std.process.exit(1);
    }

    const wire = core.wire;

    var client = ipc.Client.connect(pod_socket) catch |err| {
        core.logging.logError("shp", "failed to connect shell event socket", err);
        return;
    };
    defer client.close();
    const fd = client.fd;

    // Send versioned SHP handshake.
    wire.sendHandshake(fd, wire.POD_HANDSHAKE_SHP_CTL) catch |err| {
        core.logging.logError("shp", "failed to send shell event handshake", err);
        return;
    };

    // Build ShpShellEvent struct.
    const phase_byte: u8 = if (std.mem.eql(u8, phase, "start")) 1 else 0;
    const evt = wire.ShpShellEvent{
        .phase = phase_byte,
        .status = @intCast(status),
        .duration_ms = duration_ms,
        .started_at = started_at_ms,
        .jobs = @intCast(jobs),
        .running = @intFromBool(running),
        .cmd_len = @intCast(cmd.len),
        .cwd_len = @intCast(cwd.len),
    };

    // Send as binary control message with trailing cmd + cwd.
    wire.writeControlMsg(fd, .shp_shell_event, std.mem.asBytes(&evt), &.{ cmd, cwd }) catch |err| {
        core.logging.logError("shp", "failed to send shell event", err);
    };
}

fn outputListJson(allocator: std.mem.Allocator, payload: []const u8, start_off: usize, status_hdr: core.wire.StatusResp, filter_abs: ?[]const u8) !void {
    const wire = core.wire;
    const stdout = std.fs.File.stdout();
    var off = start_off;
    var buf: [256]u8 = undefined;
    const filtering = filter_abs != null;

    try stdout.writeAll("{");

    // Instance
    const inst = std.posix.getenv("HEXE_INSTANCE");
    try stdout.writeAll("\"instance\":\"");
    if (inst) |name| {
        if (name.len > 0) try writeJsonStr(stdout, name) else try stdout.writeAll("default");
    } else try stdout.writeAll("default");
    try stdout.writeAll("\",");

    // Connected muxes. When filtering, emit only entries whose base_root
    // matches; a `first` flag keeps the comma separators valid across skips.
    try stdout.writeAll("\"connected\":[");
    var conn_first = true;
    var ci: u16 = 0;
    while (ci < status_hdr.client_count) : (ci += 1) {
        if (off + @sizeOf(wire.StatusClient) > payload.len) break;
        const sc = std.mem.bytesToValue(wire.StatusClient, payload[off..][0..@sizeOf(wire.StatusClient)]);
        off += @sizeOf(wire.StatusClient);

        if (off + sc.name_len > payload.len) break;
        const name_str = if (sc.name_len > 0) payload[off .. off + sc.name_len] else "";
        off += sc.name_len;

        if (off + sc.session_state_len > payload.len) break;
        const session_state = if (sc.session_state_len > 0) payload[off .. off + sc.session_state_len] else "{}";
        off += sc.session_state_len;

        // Advance past pane entries regardless of whether we emit this mux.
        var pi: u16 = 0;
        while (pi < sc.pane_count) : (pi += 1) {
            if (off + @sizeOf(wire.StatusPaneEntry) > payload.len) break;
            const pe = std.mem.bytesToValue(wire.StatusPaneEntry, payload[off..][0..@sizeOf(wire.StatusPaneEntry)]);
            off += @sizeOf(wire.StatusPaneEntry);
            off += pe.name_len;
            off += pe.sticky_pwd_len;
        }

        const base_root_opt: ?[]u8 = sessionStateBaseRoot(allocator, session_state);
        defer if (base_root_opt) |b| allocator.free(b);
        if (filtering and !(base_root_opt != null and dirFilterMatches(allocator, filter_abs.?, base_root_opt.?))) continue;

        if (!conn_first) try stdout.writeAll(",");
        conn_first = false;
        try stdout.writeAll("{\"name\":\"");
        try writeJsonStr(stdout, name_str);
        try stdout.writeAll("\",\"session_id\":\"");
        if (sc.has_session_id != 0) try stdout.writeAll(sc.session_id[0..]);
        try stdout.writeAll("\",\"pane_count\":");
        const pane_str = std.fmt.bufPrint(&buf, "{d}", .{sc.pane_count}) catch continue;
        try stdout.writeAll(pane_str);
        if (base_root_opt) |base_root| {
            try stdout.writeAll(",\"base_root\":\"");
            try writeJsonStr(stdout, base_root);
            try stdout.writeAll("\"");
        }
        try stdout.writeAll(",\"state\":");
        try stdout.writeAll(session_state);
        try stdout.writeAll("}");
    }
    try stdout.writeAll("],");

    // Detached sessions
    try stdout.writeAll("\"detached\":[");
    var det_first = true;
    var di: u16 = 0;
    while (di < status_hdr.detached_count) : (di += 1) {
        if (off + @sizeOf(wire.DetachedSessionEntry) > payload.len) break;
        const de = std.mem.bytesToValue(wire.DetachedSessionEntry, payload[off..][0..@sizeOf(wire.DetachedSessionEntry)]);
        off += @sizeOf(wire.DetachedSessionEntry);

        if (off + de.name_len > payload.len) break;
        const name_str = if (de.name_len > 0) payload[off .. off + de.name_len] else "";
        off += de.name_len;

        if (off + de.session_state_len > payload.len) break;
        const session_state = if (de.session_state_len > 0) payload[off .. off + de.session_state_len] else "{}";
        off += de.session_state_len;

        const base_root_opt: ?[]u8 = sessionStateBaseRoot(allocator, session_state);
        defer if (base_root_opt) |b| allocator.free(b);
        if (filtering and !(base_root_opt != null and dirFilterMatches(allocator, filter_abs.?, base_root_opt.?))) continue;

        if (!det_first) try stdout.writeAll(",");
        det_first = false;
        try stdout.writeAll("{\"name\":\"");
        try writeJsonStr(stdout, name_str);
        try stdout.writeAll("\",\"session_id\":\"");
        try stdout.writeAll(de.session_id[0..]);
        try stdout.writeAll("\",\"pane_count\":");
        const pane_str = std.fmt.bufPrint(&buf, "{d}", .{de.pane_count}) catch continue;
        try stdout.writeAll(pane_str);
        if (base_root_opt) |base_root| {
            try stdout.writeAll(",\"base_root\":\"");
            try writeJsonStr(stdout, base_root);
            try stdout.writeAll("\"");
        }
        try stdout.writeAll(",\"state\":");
        try stdout.writeAll(session_state);
        try stdout.writeAll("}");
    }
    try stdout.writeAll("],");

    // Orphaned panes (carry no directory: omitted entirely when filtering).
    try stdout.writeAll("\"orphaned\":[");
    var orph_first = true;
    var oi: u16 = 0;
    while (oi < status_hdr.orphaned_count) : (oi += 1) {
        if (off + @sizeOf(wire.StatusPaneEntry) > payload.len) break;
        const pe = std.mem.bytesToValue(wire.StatusPaneEntry, payload[off..][0..@sizeOf(wire.StatusPaneEntry)]);
        off += @sizeOf(wire.StatusPaneEntry);

        if (off + pe.name_len > payload.len) break;
        const pname = if (pe.name_len > 0) payload[off .. off + pe.name_len] else "";
        off += pe.name_len;
        off += pe.sticky_pwd_len;

        if (filtering) continue;
        if (!orph_first) try stdout.writeAll(",");
        orph_first = false;
        try stdout.writeAll("{\"uuid\":\"");
        try stdout.writeAll(pe.uuid[0..]);
        try stdout.writeAll("\",\"name\":\"");
        try writeJsonStr(stdout, pname);
        try stdout.writeAll("\",\"pid\":");
        const pid_str = std.fmt.bufPrint(&buf, "{d}", .{pe.pid}) catch continue;
        try stdout.writeAll(pid_str);
        try stdout.writeAll("}");
    }
    try stdout.writeAll("],");

    // Sticky panes (matched by pwd when filtering).
    try stdout.writeAll("\"sticky\":[");
    var sticky_first = true;
    var si: u16 = 0;
    while (si < status_hdr.sticky_count) : (si += 1) {
        if (off + @sizeOf(wire.StickyPaneEntry) > payload.len) break;
        const se = std.mem.bytesToValue(wire.StickyPaneEntry, payload[off..][0..@sizeOf(wire.StickyPaneEntry)]);
        off += @sizeOf(wire.StickyPaneEntry);

        off += se.name_len;
        if (off + se.pwd_len > payload.len) break;
        const pwd = if (se.pwd_len > 0) payload[off .. off + se.pwd_len] else "";
        off += se.pwd_len;

        if (filtering and !(pwd.len > 0 and dirFilterMatches(allocator, filter_abs.?, pwd))) continue;
        if (!sticky_first) try stdout.writeAll(",");
        sticky_first = false;
        try stdout.writeAll("{\"uuid\":\"");
        try stdout.writeAll(se.uuid[0..]);
        try stdout.writeAll("\",\"pid\":");
        const pid_str = std.fmt.bufPrint(&buf, "{d}", .{se.pid}) catch continue;
        try stdout.writeAll(pid_str);
        try stdout.writeAll(",\"pwd\":\"");
        try writeJsonStr(stdout, pwd);
        try stdout.writeAll("\"");
        if (se.key != 0) {
            try stdout.writeAll(",\"key\":\"");
            const key_buf = [1]u8{se.key};
            try stdout.writeAll(&key_buf);
            try stdout.writeAll("\"");
        }
        try stdout.writeAll("}");
    }
    try stdout.writeAll("]");

    try stdout.writeAll("}\n");
}

fn writeJsonStr(stdout: std.fs.File, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try stdout.writeAll("\\\""),
            '\\' => try stdout.writeAll("\\\\"),
            '\n' => try stdout.writeAll("\\n"),
            '\r' => try stdout.writeAll("\\r"),
            '\t' => try stdout.writeAll("\\t"),
            else => {
                const buf = [1]u8{c};
                try stdout.writeAll(&buf);
            },
        }
    }
}

pub fn runSesKill(allocator: std.mem.Allocator, target: []const u8) !void {
    const wire = core.wire;
    const posix = std.posix;

    if (target.len == 0) {
        cli_ui.printErr("session name or UUID prefix required", .{});
        std.process.exit(1);
    }

    const fd = connectSesCliChannel(allocator) orelse std.process.exit(1);
    defer posix.close(fd);

    // Send kill_session request.
    const ks = wire.KillSession{ .id_len = @intCast(target.len) };
    wire.writeControlWithTrail(fd, .kill_session, std.mem.asBytes(&ks), target) catch {
        cli_ui.printErr("failed to send request", .{});
        std.process.exit(1);
    };

    // Read response.
    const hdr = wire.readControlHeader(fd) catch {
        cli_ui.printErr("failed to read response", .{});
        std.process.exit(1);
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type != .kill_session or hdr.payload_len < @sizeOf(wire.KillSessionResult)) {
        cli_ui.printErr("unexpected response", .{});
        std.process.exit(1);
    }

    const result = wire.readStruct(wire.KillSessionResult, fd) catch {
        cli_ui.printErr("failed to read result", .{});
        std.process.exit(1);
    };

    if (result.success != 0) {
        var out = std.fs.File.stdout().deprecatedWriter();
        const p = core.cli_ui.Palette.forStdout();
        try out.print("{s}✓{s} Killed session ({d} panes)\n", .{ p.success, p.reset, result.killed_panes });
    } else {
        // Read error message.
        if (result.error_len > 0) {
            var err_buf: [256]u8 = undefined;
            const err_len = @min(result.error_len, err_buf.len);
            wire.readExact(fd, err_buf[0..err_len]) catch {
                cli_ui.printErr("session not found", .{});
                std.process.exit(1);
            };
            cli_ui.printErr("{s}", .{err_buf[0..err_len]});
            std.process.exit(1);
        } else {
            cli_ui.printErr("session not found", .{});
            std.process.exit(1);
        }
    }
}

pub fn runSesClear(allocator: std.mem.Allocator, force: bool) !void {
    const wire = core.wire;
    const posix = std.posix;

    if (!force) {
        if (posix.isatty(posix.STDIN_FILENO) and posix.isatty(posix.STDOUT_FILENO)) {
            const confirmed = (try terminal.runStandaloneConfirm(allocator, "Kill ALL detached sessions?", .{
                .default = .no,
                .yes_label = "Kill all",
                .no_label = "Cancel",
                .subtitle = "All shells inside detached sessions will be terminated",
            })) orelse false;
            if (!confirmed) return;
        } else {
            cli_ui.printWarn("This will kill ALL detached sessions. Use -f to confirm.", .{});
            std.process.exit(1);
        }
    }

    const fd = connectSesCliChannel(allocator) orelse std.process.exit(1);
    defer posix.close(fd);

    // Send clear_sessions request (no payload).
    wire.writeControl(fd, .clear_sessions, &.{}) catch {
        cli_ui.printErr("failed to send request", .{});
        std.process.exit(1);
    };

    // Read response.
    const hdr = wire.readControlHeader(fd) catch {
        cli_ui.printErr("failed to read response", .{});
        std.process.exit(1);
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type != .clear_sessions or hdr.payload_len < @sizeOf(wire.ClearSessionsResult)) {
        cli_ui.printErr("unexpected response", .{});
        std.process.exit(1);
    }

    const result = wire.readStruct(wire.ClearSessionsResult, fd) catch {
        cli_ui.printErr("failed to read result", .{});
        std.process.exit(1);
    };

    var out = std.fs.File.stdout().deprecatedWriter();
    const p = core.cli_ui.Palette.forStdout();
    try out.print("{s}✓{s} Killed {d} sessions ({d} panes)\n", .{ p.success, p.reset, result.killed_sessions, result.killed_panes });
}

/// `hexe ses clear --orphans -f`: kill orphaned and sticky panes that outlived
/// their session.
pub fn runSesClearOrphans(allocator: std.mem.Allocator, force: bool) !void {
    const wire = core.wire;
    const posix = std.posix;

    if (!force) {
        if (posix.isatty(posix.STDIN_FILENO) and posix.isatty(posix.STDOUT_FILENO)) {
            const confirmed = (try terminal.runStandaloneConfirm(allocator, "Kill ALL orphaned and sticky panes?", .{
                .default = .no,
                .yes_label = "Kill all",
                .no_label = "Cancel",
                .subtitle = "Orphaned and sticky shells will be terminated",
            })) orelse false;
            if (!confirmed) return;
        } else {
            cli_ui.printWarn("This will kill ALL orphaned and sticky panes. Use -f to confirm.", .{});
            std.process.exit(1);
        }
    }

    const fd = connectSesCliChannel(allocator) orelse std.process.exit(1);
    defer posix.close(fd);

    wire.writeControl(fd, .clear_orphaned_panes, &.{}) catch {
        cli_ui.printErr("failed to send request", .{});
        std.process.exit(1);
    };

    const hdr = wire.readControlHeader(fd) catch {
        cli_ui.printErr("failed to read response", .{});
        std.process.exit(1);
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type != .clear_orphaned_panes or hdr.payload_len < @sizeOf(wire.ClearOrphanedPanesResult)) {
        cli_ui.printErr("unexpected response", .{});
        std.process.exit(1);
    }

    const result = wire.readStruct(wire.ClearOrphanedPanesResult, fd) catch {
        cli_ui.printErr("failed to read result", .{});
        std.process.exit(1);
    };

    var out = std.fs.File.stdout().deprecatedWriter();
    const p = core.cli_ui.Palette.forStdout();
    try out.print("{s}✓{s} Killed {d} orphaned panes\n", .{ p.success, p.reset, result.killed_panes });
}

/// `hexe detach [target]` / `hexe terminal detach [target]`: cleanly detach
/// an attached session from the CLI.
///
/// Target resolution:
/// 1. Explicit `<target>` (session name, name prefix, or UUID prefix)
/// 2. `$HEXE_SESSION` when running inside a hexe pane
/// 3. Interactive vaxis picker on TTY if >1 attached session exists, else sole attached session
pub fn runDetach(allocator: std.mem.Allocator, target_arg: []const u8) !void {
    const wire = core.wire;
    const posix = std.posix;

    var owned_target: ?[]u8 = null;
    defer if (owned_target) |t| allocator.free(t);

    var target: []const u8 = target_arg;
    if (target.len == 0) {
        if (posix.getenv("HEXE_SESSION")) |env_sid| {
            if (env_sid.len >= 8) target = env_sid;
        }
    }

    if (target.len == 0 and posix.isatty(posix.STDIN_FILENO) and posix.isatty(posix.STDOUT_FILENO)) {
        if (try pickAttachedSessionToDetach(allocator)) |picked| {
            owned_target = picked;
            target = picked;
        } else {
            // Cancelled or no attached sessions (already reported)
            return;
        }
    }

    const fd = connectSesCliChannel(allocator) orelse std.process.exit(1);
    defer posix.close(fd);

    const req = wire.DetachSession{ .id_len = @intCast(target.len) };
    wire.writeControlWithTrail(fd, .detach_session, std.mem.asBytes(&req), target) catch {
        cli_ui.printErr("failed to send detach request", .{});
        std.process.exit(1);
    };

    const hdr = wire.readControlHeader(fd) catch {
        cli_ui.printErr("failed to read detach response", .{});
        std.process.exit(1);
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type != .detach_session or hdr.payload_len < @sizeOf(wire.DetachSessionResult)) {
        cli_ui.printErr("unexpected response from ses daemon", .{});
        std.process.exit(1);
    }
    const result = wire.readStruct(wire.DetachSessionResult, fd) catch {
        cli_ui.printErr("failed to read detach result", .{});
        std.process.exit(1);
    };

    var name_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    const nlen = @min(result.name_len, name_buf.len);
    if (nlen > 0) wire.readExact(fd, name_buf[0..nlen]) catch {};
    const elen = @min(result.error_len, err_buf.len);
    if (elen > 0) wire.readExact(fd, err_buf[0..elen]) catch {};

    if (result.success != 0) {
        const color = core.cli_ui.useColor(posix.STDOUT_FILENO);
        const profile = posix.getenv("HEXE_INSTANCE");
        const banner = try core.cli_ui.formatDetachBanner(
            allocator,
            color,
            name_buf[0..nlen],
            result.session_id[0..8],
            result.pane_count,
            profile,
        );
        defer allocator.free(banner);
        try std.fs.File.stdout().writeAll(banner);
    } else {
        cli_ui.printErr("{s}", .{if (elen > 0) err_buf[0..elen] else "detach failed"});
        std.process.exit(1);
    }
}

fn pickAttachedSessionToDetach(allocator: std.mem.Allocator) !?[]u8 {
    const wire = core.wire;
    const posix = std.posix;

    const fd = connectSesCliChannel(allocator) orelse return null;
    defer posix.close(fd);

    wire.writeControl(fd, .list_sessions, &.{}) catch return null;
    const hdr = wire.readControlHeader(fd) catch return null;
    if (@as(wire.MsgType, @enumFromInt(hdr.msg_type)) != .sessions_list or hdr.payload_len < @sizeOf(wire.SessionsList) or hdr.payload_len > wire.MAX_PAYLOAD_LEN) {
        return null;
    }
    const payload = try allocator.alloc(u8, hdr.payload_len);
    defer allocator.free(payload);
    wire.readExact(fd, payload) catch return null;

    const list_hdr = std.mem.bytesToValue(wire.SessionsList, payload[0..@sizeOf(wire.SessionsList)]);
    var off: usize = @sizeOf(wire.SessionsList);

    const AttachedItem = struct {
        id: [8]u8,
        name: []const u8,
        root: []const u8,
        panes: u16,
    };
    var attached: std.ArrayList(AttachedItem) = .empty;
    defer attached.deinit(allocator);

    var i: u16 = 0;
    while (i < list_hdr.session_count) : (i += 1) {
        if (off + @sizeOf(wire.SessionEntry) > payload.len) break;
        const e = std.mem.bytesToValue(wire.SessionEntry, payload[off..][0..@sizeOf(wire.SessionEntry)]);
        off += @sizeOf(wire.SessionEntry);
        if (off + e.name_len + e.base_root_len > payload.len) break;
        const name = payload[off .. off + e.name_len];
        off += e.name_len;
        const root = payload[off .. off + e.base_root_len];
        off += e.base_root_len;
        if (e.attached != 0) {
            try attached.append(allocator, .{
                .id = e.session_id[0..8].*,
                .name = name,
                .root = root,
                .panes = e.pane_count,
            });
        }
    }

    if (attached.items.len == 0) {
        const p = core.cli_ui.Palette.forStderr();
        print("{s}○{s} No attached sessions to detach\n", .{ p.warn, p.reset });
        return null;
    }
    if (attached.items.len == 1) {
        return try allocator.dupe(u8, &attached.items[0].id);
    }

    var labels = try allocator.alloc([]const u8, attached.items.len);
    var labels_built: usize = 0;
    defer {
        for (labels[0..labels_built]) |l| allocator.free(l);
        allocator.free(labels);
    }
    var details = try allocator.alloc([]const u8, attached.items.len);
    var details_built: usize = 0;
    defer {
        for (details[0..details_built]) |d| allocator.free(d);
        allocator.free(details);
    }

    for (attached.items, 0..) |item, idx| {
        const disp_name = if (item.name.len > 0) item.name else item.id[0..];
        labels[idx] = try std.fmt.allocPrint(allocator, "{s:<14} [{s}]", .{ disp_name, item.id });
        labels_built = idx + 1;
        var hb: [256]u8 = undefined;
        const rdisp = if (item.root.len > 0) core.cli_ui.compactHome(item.root, &hb) else "-";
        const pw: []const u8 = if (item.panes == 1) "pane" else "panes";
        details[idx] = try std.fmt.allocPrint(allocator, "root: {s} · {d} {s}", .{ rdisp, item.panes, pw });
        details_built = idx + 1;
    }

    const picked = try terminal.runStandalonePicker(allocator, labels, .{
        .title = "Detach session",
        .details = details,
        .hint = "↑↓/jk move · / filter · Enter detach · Esc cancel",
    });
    const idx = picked orelse return null;
    return try allocator.dupe(u8, &attached.items[idx].id);
}

/// `hexe terminal kill|close <id>`: kill a whole session (detached or
/// attached) or a single pane/float, by name or uuid prefix.
pub fn runTerminalKill(allocator: std.mem.Allocator, target: []const u8) !void {
    const wire = core.wire;
    const posix = std.posix;

    if (target.len == 0) {
        cli_ui.printErr("session name, pane uuid, or uuid prefix required", .{});
        cli_ui.printErrHint("List sessions and panes with: hexe ls --details", .{});
        std.process.exit(1);
    }

    const fd = connectSesCliChannel(allocator) orelse std.process.exit(1);
    defer posix.close(fd);

    const kt = wire.KillTarget{ .id_len = @intCast(target.len) };
    wire.writeControlWithTrail(fd, .kill_target, std.mem.asBytes(&kt), target) catch {
        cli_ui.printErr("failed to send request", .{});
        std.process.exit(1);
    };

    const hdr = wire.readControlHeader(fd) catch {
        cli_ui.printErr("failed to read response", .{});
        std.process.exit(1);
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type != .kill_target or hdr.payload_len < @sizeOf(wire.KillTargetResult)) {
        cli_ui.printErr("unexpected response", .{});
        std.process.exit(1);
    }

    const result = wire.readStruct(wire.KillTargetResult, fd) catch {
        cli_ui.printErr("failed to read result", .{});
        std.process.exit(1);
    };

    if (result.success != 0) {
        var out = std.fs.File.stdout().deprecatedWriter();
        const p = core.cli_ui.Palette.forStdout();
        const kind: wire.KillTargetKind = @enumFromInt(result.kind);
        switch (kind) {
            .detached_session => try out.print("{s}✓{s} Killed detached session ({d} panes)\n", .{ p.success, p.reset, result.killed_panes }),
            .attached_session => try out.print("{s}✓{s} Killed attached session ({d} panes)\n", .{ p.success, p.reset, result.killed_panes }),
            .pane => try out.print("{s}✓{s} Killed pane\n", .{ p.success, p.reset }),
            .none => try out.print("{s}✓{s} Killed\n", .{ p.success, p.reset }),
        }
    } else if (result.error_len > 0) {
        var err_buf: [256]u8 = undefined;
        const err_len = @min(result.error_len, err_buf.len);
        wire.readExact(fd, err_buf[0..err_len]) catch {
            cli_ui.printErr("target not found", .{});
            std.process.exit(1);
        };
        cli_ui.printErr("{s}", .{err_buf[0..err_len]});
        std.process.exit(1);
    } else {
        cli_ui.printErr("target not found", .{});
        std.process.exit(1);
    }
}
