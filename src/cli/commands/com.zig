const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const session_config = core.session_config;

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
pub const runPodGc = @import("pod_gc.zig").runPodGc;
pub const runRecordStart = @import("record_ctl.zig").runRecordStart;
pub const runRecordStop = @import("record_ctl.zig").runRecordStop;
pub const runRecordStatus = @import("record_ctl.zig").runRecordStatus;
pub const runRecordToggle = @import("record_ctl.zig").runRecordToggle;

const print = std.debug.print;

fn parseUuid32Hex(text: []const u8) ?[32]u8 {
    if (text.len != 32) return null;
    var out: [32]u8 = undefined;
    for (text, 0..) |ch, i| {
        if (!std.ascii.isHex(ch)) return null;
        out[i] = ch;
    }
    return out;
}

const ansi = struct {
    pub const RESET = "\x1b[0m";
    pub const DIM = "\x1b[2m";
    pub const BOLD = "\x1b[1m";

    pub const SYM = "\x1b[38;5;220m"; // yellow
    pub const MUX = "\x1b[38;5;45m"; // cyan
    pub const TAB = "\x1b[38;5;39m"; // blue
    pub const SPLIT = "\x1b[38;5;42m"; // green
    pub const FLOAT = "\x1b[38;5;171m"; // magenta
    pub const NAME = "\x1b[38;5;255m"; // bright white
    pub const UUID = "\x1b[38;5;244m"; // gray
};

fn printTreeNode(prefix: []const u8, symbol: []const u8, type_color: []const u8, type_str: []const u8, name: []const u8, uuid8: []const u8) void {
    // Format: [symbol][type][name][uuid]
    print(
        "{s}{s}{s}{s} {s}{s}{s} {s}{s}{s} [{s}{s}{s}]\n",
        .{
            prefix,
            ansi.SYM,
            symbol,
            ansi.RESET,
            type_color,
            type_str,
            ansi.RESET,
            ansi.NAME,
            name,
            ansi.RESET,
            ansi.UUID,
            uuid8,
            ansi.RESET,
        },
    );
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

    if (!json_output) {
        const inst = posix.getenv("HEXE_INSTANCE");
        if (inst) |name| {
            if (name.len > 0) {
                print("Instance: {s}\n", .{name});
            } else {
                print("Instance: default\n", .{});
            }
        } else {
            print("Instance: default\n", .{});
        }
        if (filter_abs) |f| print("Directory: {s}\n", .{f});
    }

    const fd = connectSesCliChannel(allocator) orelse return;
    defer posix.close(fd);

    // Send status request with full_mode flag. Full mode makes the daemon
    // include each session's canonical state JSON, which is where base_root
    // lives — required to filter by directory, so request it whenever a
    // filter is active even if the caller didn't ask for --details.
    const full_mode = details or (filter_abs != null);
    const flag: [1]u8 = .{if (full_mode) @as(u8, 1) else @as(u8, 0)};
    wire.writeControl(fd, .status, &flag) catch |err| {
        print("Error: failed to request session status: {s}\n", .{@errorName(err)});
        return;
    };

    // Read response
    const hdr = wire.readControlHeader(fd) catch |err| {
        print("Error: failed to read session status response: {s}\n", .{@errorName(err)});
        return;
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type != .status or hdr.payload_len < @sizeOf(wire.StatusResp)) {
        print("Invalid response from daemon\n", .{});
        return;
    }
    if (hdr.payload_len > wire.MAX_PAYLOAD_LEN) {
        print("Status response too large\n", .{});
        return;
    }

    // Read the entire payload into a buffer
    const payload = allocator.alloc(u8, hdr.payload_len) catch {
        print("Allocation failed\n", .{});
        return;
    };
    defer allocator.free(payload);
    wire.readExact(fd, payload) catch |err| {
        print("Error: failed to read session status payload: {s}\n", .{@errorName(err)});
        return;
    };

    var off: usize = 0;

    // Parse StatusResp header
    if (off + @sizeOf(wire.StatusResp) > payload.len) return;
    const status_hdr = std.mem.bytesToValue(wire.StatusResp, payload[off..][0..@sizeOf(wire.StatusResp)]);
    off += @sizeOf(wire.StatusResp);

    // JSON output mode - output raw structure
    if (json_output) {
        outputListJson(allocator, payload, off, status_hdr, filter_abs) catch |err| {
            print("Error: failed to write JSON status: {s}\n", .{@errorName(err)});
        };
        return;
    }

    const filtering = filter_abs != null;

    // Connected clients. With a directory filter the total count would be
    // misleading, so print the header lazily before the first match instead.
    if (!filtering and status_hdr.client_count > 0) {
        print("Connected muxes: {d}\n", .{status_hdr.client_count});
    }
    var shown_mux_header = false;

    var ci: u16 = 0;
    while (ci < status_hdr.client_count) : (ci += 1) {
        if (off + @sizeOf(wire.StatusClient) > payload.len) return;
        const sc = std.mem.bytesToValue(wire.StatusClient, payload[off..][0..@sizeOf(wire.StatusClient)]);
        off += @sizeOf(wire.StatusClient);

        // Read trailing: name, canonical session snapshot
        if (off + sc.name_len > payload.len) return;
        const name_str = if (sc.name_len > 0) payload[off .. off + sc.name_len] else "unknown";
        off += sc.name_len;

        if (off + sc.session_state_len > payload.len) return;
        const session_state = if (sc.session_state_len > 0) payload[off .. off + sc.session_state_len] else "";
        off += sc.session_state_len;

        const base_root_opt: ?[]u8 = if (filtering or details) sessionStateBaseRoot(allocator, session_state) else null;
        defer if (base_root_opt) |b| allocator.free(b);

        const show = !filtering or (base_root_opt != null and dirFilterMatches(allocator, filter_abs.?, base_root_opt.?));

        const is_last_client = (ci + 1 == status_hdr.client_count);
        const branch = if (is_last_client) "\xe2\x94\x94" else "\xe2\x94\x9c";
        const child_prefix = if (is_last_client) "   " else "\xe2\x94\x82  ";

        const sid8: []const u8 = if (sc.has_session_id != 0) sc.session_id[0..8] else "????????";

        if (show) {
            if (filtering and !shown_mux_header) {
                print("Connected muxes:\n", .{});
                shown_mux_header = true;
            }
            var mux_line: [256]u8 = undefined;
            const prefix = std.fmt.bufPrint(&mux_line, "{s}\xe2\x94\x80 ", .{branch}) catch "";
            printTreeNode(prefix, " ", ansi.MUX, "mux", name_str, sid8);
            if (details) {
                if (base_root_opt) |base_root| {
                    print("{s}root: {s}\n", .{ child_prefix, base_root });
                }
            }
        }

        // Read pane entries and build name map
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
            off += pe.sticky_pwd_len; // skip sticky_pwd

            if (pname.len > 0) {
                pane_names.put(pe.uuid, pname) catch |err| {
                    print("Error: failed to build pane name map: {s}\n", .{@errorName(err)});
                    return;
                };
            }
        }

        if (show and session_state.len > 0) {
            printSessionTree(allocator, session_state, child_prefix, &pane_names);
        }
    }

    // Detached sessions. Header printed lazily when filtering (see muxes).
    if (!filtering and status_hdr.detached_count > 0) {
        print("\nDetached sessions: {d}\n", .{status_hdr.detached_count});
    }
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

        // Include --instance flag if not in default instance
        const uuid_prefix = de.session_id[0..8];
        const instance = std.posix.getenv("HEXE_INSTANCE");

        if (filtering and !shown_detached_header) {
            print("\nDetached sessions:\n", .{});
            shown_detached_header = true;
        }

        // Show UUID prominently as primary identifier
        print("  [{s}] {s:<12} ({d} panes)\n", .{ uuid_prefix, name_str, de.pane_count });
        if (base_root_opt) |base_root| {
            print("    root: {s}\n", .{base_root});
        }

        if (instance) |instance_name| {
            if (instance_name.len > 0) {
                print("    → hexe terminal attach --instance {s} {s}\n", .{ instance_name, uuid_prefix });
            } else {
                print("    → hexe terminal attach {s}\n", .{uuid_prefix});
            }
        } else {
            print("    → hexe terminal attach {s}\n", .{uuid_prefix});
        }

        if (session_state.len > 0) {
            printSessionTree(allocator, session_state, "    ", null);
        }
    }

    // Orphaned and sticky panes are not directory-scoped sessions; with a
    // directory filter active, list only sticky panes whose pwd matches and
    // skip orphaned panes entirely.
    if (!filtering and status_hdr.orphaned_count > 0) {
        print("\nOrphaned panes: {d}\n", .{status_hdr.orphaned_count});
    }

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

        if (filtering) continue; // orphaned panes carry no directory

        if (pname.len > 0) {
            print("  [{s}] {s} pid={d}\n", .{ pe.uuid[0..8], pname, pe.pid });
        } else {
            print("  [{s}] pid={d}\n", .{ pe.uuid[0..8], pe.pid });
        }
    }

    // Sticky panes. Header printed lazily when filtering (matched by pwd).
    if (!filtering and status_hdr.sticky_count > 0) {
        print("\nSticky panes: {d}\n", .{status_hdr.sticky_count});
    }
    var shown_sticky_header = false;

    var si: u16 = 0;
    while (si < status_hdr.sticky_count) : (si += 1) {
        if (off + @sizeOf(wire.StickyPaneEntry) > payload.len) return;
        const se = std.mem.bytesToValue(wire.StickyPaneEntry, payload[off..][0..@sizeOf(wire.StickyPaneEntry)]);
        off += @sizeOf(wire.StickyPaneEntry);

        if (off + se.name_len > payload.len) return;
        off += se.name_len; // skip name (not displayed for sticky currently)

        if (off + se.pwd_len > payload.len) return;
        const pwd = if (se.pwd_len > 0) payload[off .. off + se.pwd_len] else "";
        off += se.pwd_len;

        if (filtering) {
            if (pwd.len == 0 or !dirFilterMatches(allocator, filter_abs.?, pwd)) continue;
            if (!shown_sticky_header) {
                print("\nSticky panes:\n", .{});
                shown_sticky_header = true;
            }
        }

        print("  [{s}] pid={d}", .{ se.uuid[0..8], se.pid });
        if (pwd.len > 0) {
            print(" pwd={s}", .{pwd});
        }
        if (se.key != 0) {
            print(" key={c}", .{se.key});
        }
        print("\n", .{});
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

    if (registry.entries.len == 0) {
        print("No layouts found\n", .{});
        return;
    }

    for (registry.entries) |entry| {
        print("{s}  {s}\n", .{ entry.name, entry.path });
        if (std.mem.eql(u8, cwd, entry.path)) {
            const config_path = std.fmt.allocPrint(allocator, "{s}/.hexe.lua", .{entry.path}) catch continue;
            defer allocator.free(config_path);
            if (session_config.parseSessionLua(allocator, config_path)) |cfg| {
                var owned_cfg = cfg;
                defer owned_cfg.deinit(allocator);
                if (owned_cfg.name) |n| print("  name: {s}\n", .{n});
                print("  tabs: {d}\n", .{owned_cfg.tabs.len});
                print("  floats: {d}\n", .{owned_cfg.floats.len});
                if (owned_cfg.root) |r| print("  root: {s}\n", .{r});
            } else |_| {}
        }
    }
}

pub fn runInfo(allocator: std.mem.Allocator, uuid_arg: []const u8, show_creator: bool, show_last: bool) !void {
    const wire = core.wire;
    const posix = std.posix;

    var target_uuid: [32]u8 = undefined;

    if (uuid_arg.len > 0) {
        target_uuid = parseUuid32Hex(uuid_arg) orelse {
            print("Invalid UUID\n", .{});
            return;
        };
    } else if (show_creator or show_last) {
        if (resolveRelatedPane(allocator, show_creator)) |resolved| {
            target_uuid = resolved;
        } else return;
    } else {
        const env_uuid = posix.getenv("HEXE_PANE_UUID") orelse {
            print("Not inside a hexe terminal session (use --uuid to query a specific pane)\n", .{});
            return;
        };
        target_uuid = parseUuid32Hex(env_uuid) orelse {
            print("Invalid HEXE_PANE_UUID\n", .{});
            return;
        };
    }

    // Query SES for pane info via binary protocol
    const fd = connectSesCliChannel(allocator) orelse return;
    defer posix.close(fd);

    var pu: wire.PaneUuid = undefined;
    pu.uuid = target_uuid;
    wire.writeControl(fd, .pane_info, std.mem.asBytes(&pu)) catch |err| {
        print("Error: failed to request pane info: {s}\n", .{@errorName(err)});
        return;
    };

    // Read response
    const hdr = wire.readControlHeader(fd) catch |err| {
        print("Error: failed to read pane info response: {s}\n", .{@errorName(err)});
        return;
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type == .pane_not_found) {
        print("Pane not found\n", .{});
        return;
    }
    if (msg_type != .pane_info or hdr.payload_len < @sizeOf(wire.PaneInfoResp)) {
        print("Invalid response from daemon\n", .{});
        return;
    }

    const resp = wire.readStruct(wire.PaneInfoResp, fd) catch |err| {
        print("Error: failed to read pane info payload: {s}\n", .{@errorName(err)});
        return;
    };

    // Read trailing data
    const trail_len = hdr.payload_len - @sizeOf(wire.PaneInfoResp);
    var trail_buf: [8192]u8 = undefined;
    if (trail_len > trail_buf.len) {
        print("Invalid response from daemon (pane_info payload too large)\n", .{});
        return;
    }
    if (trail_len > 0) {
        wire.readExact(fd, trail_buf[0..trail_len]) catch |err| {
            print("Error: failed to read pane info trail: {s}\n", .{@errorName(err)});
            return;
        };
    }

    // Parse trailing data in order: name, fg, cwd, tty, socket, session_name, layout, last_cmd, base_process, sticky_pwd
    var off: usize = 0;
    if (off + resp.name_len > trail_len) {
        print("Invalid response from daemon (malformed pane_info payload)\n", .{});
        return;
    }
    const name = trail_buf[off .. off + resp.name_len];
    off += resp.name_len;
    if (off + resp.fg_len > trail_len) {
        print("Invalid response from daemon (malformed pane_info payload)\n", .{});
        return;
    }
    const fg_process = trail_buf[off .. off + resp.fg_len];
    off += resp.fg_len;
    if (off + resp.cwd_len > trail_len) {
        print("Invalid response from daemon (malformed pane_info payload)\n", .{});
        return;
    }
    const cwd_str = trail_buf[off .. off + resp.cwd_len];
    off += resp.cwd_len;
    if (off + resp.tty_len > trail_len) {
        print("Invalid response from daemon (malformed pane_info payload)\n", .{});
        return;
    }
    const tty_str = trail_buf[off .. off + resp.tty_len];
    off += resp.tty_len;
    if (off + resp.socket_path_len > trail_len) {
        print("Invalid response from daemon (malformed pane_info payload)\n", .{});
        return;
    }
    const socket_path = trail_buf[off .. off + resp.socket_path_len];
    off += resp.socket_path_len;
    if (off + resp.session_name_len > trail_len) {
        print("Invalid response from daemon (malformed pane_info payload)\n", .{});
        return;
    }
    const session_name = trail_buf[off .. off + resp.session_name_len];
    off += resp.session_name_len;
    if (off + resp.layout_path_len > trail_len) {
        print("Invalid response from daemon (malformed pane_info payload)\n", .{});
        return;
    }
    const layout_path = trail_buf[off .. off + resp.layout_path_len];
    off += resp.layout_path_len;
    if (off + resp.last_cmd_len > trail_len) {
        print("Invalid response from daemon (malformed pane_info payload)\n", .{});
        return;
    }
    const last_cmd = trail_buf[off .. off + resp.last_cmd_len];
    off += resp.last_cmd_len;
    if (off + resp.base_process_len > trail_len) {
        print("Invalid response from daemon (malformed pane_info payload)\n", .{});
        return;
    }
    const base_process = trail_buf[off .. off + resp.base_process_len];
    off += resp.base_process_len;
    if (off + resp.sticky_pwd_len > trail_len) {
        print("Invalid response from daemon (malformed pane_info payload)\n", .{});
        return;
    }
    _ = trail_buf[off .. off + resp.sticky_pwd_len]; // sticky_pwd (not displayed currently)

    // Display
    print("Pane Info:\n", .{});
    print("  UUID: {s}\n", .{&target_uuid});
    print("  Shell PID: {d}\n", .{resp.pid});

    if (resp.base_process_len > 0) {
        print("  Base Process: {s} (pid={d})\n", .{ base_process, resp.base_pid });
    }
    if (resp.fg_len > 0) {
        print("  Active Process: {s} (pid={d})\n", .{ fg_process, resp.fg_pid });
    }
    if (resp.cwd_len > 0) {
        print("  CWD: {s}\n", .{cwd_str});
    }
    if (resp.name_len > 0) {
        print("  Name: {s}\n", .{name});
    }
    if (resp.tty_len > 0) {
        print("  TTY: {s}\n", .{tty_str});
    }
    if (resp.cols > 0 and resp.rows > 0) {
        print("  Window: {d}x{d}\n", .{ resp.cols, resp.rows });
    }
    if (resp.session_name_len > 0) {
        print("  Session: {s}\n", .{session_name});
    }
    if (resp.has_created_from != 0) {
        print("  Creator: {s}\n", .{resp.created_from[0..8]});
    }
    if (resp.has_focused_from != 0) {
        print("  Last: {s}\n", .{resp.focused_from[0..8]});
    }
    if (resp.layout_path_len > 0) {
        print("  Layout: {s}\n", .{layout_path});
    }
    if (resp.socket_path_len > 0) {
        print("  Socket: {s}\n", .{socket_path});
    }
    print("  Focused: {}\n", .{resp.is_focused != 0});
    const pane_type_str: []const u8 = if (resp.pane_type == 1) "float" else "split";
    print("  Type: {s}\n", .{pane_type_str});
    print("  Cursor: {d},{d}\n", .{ resp.cursor_x, resp.cursor_y });
    print("  Cursor Style: {d}\n", .{resp.cursor_style});
    print("  Cursor Visible: {}\n", .{resp.cursor_visible != 0});
    print("  Alt Screen: {}\n", .{resp.alt_screen != 0});

    if (resp.last_cmd_len > 0) {
        print("  Last Cmd: {s}\n", .{last_cmd});
    }
    if (resp.has_last_status != 0) {
        print("  Last Status: {d}\n", .{resp.last_status});
    }
    if (resp.has_last_duration != 0) {
        print("  Last Duration: {d}ms\n", .{resp.last_duration_ms});
    }
    if (resp.has_last_jobs != 0) {
        print("  Last Jobs: {d}\n", .{resp.last_jobs});
    }
}

pub fn runNotify(allocator: std.mem.Allocator, uuid: []const u8, creator: bool, last: bool, broadcast: bool, message: []const u8) !void {
    const wire = core.wire;
    const posix = std.posix;

    if (message.len == 0) {
        print("Error: message is required\n", .{});
        return;
    }

    var target_uuid: [32]u8 = undefined;
    var has_target = false;

    if (uuid.len > 0) {
        target_uuid = parseUuid32Hex(uuid) orelse {
            print("Error: --uuid must be 32 hex chars\n", .{});
            return;
        };
        has_target = true;
    } else if (creator or last) {
        if (resolveRelatedPane(allocator, creator)) |resolved| {
            target_uuid = resolved;
            has_target = true;
        } else return;
    } else if (!broadcast) {
        const env_uuid = std.posix.getenv("HEXE_PANE_UUID") orelse {
            print("Error: no target (use --uuid, --creator, --last, --broadcast, or run inside mux)\n", .{});
            return;
        };
        target_uuid = parseUuid32Hex(env_uuid) orelse {
            print("Error: invalid HEXE_PANE_UUID\n", .{});
            return;
        };
        has_target = true;
    }

    const fd = connectSesCliChannel(allocator) orelse return;
    defer posix.close(fd);

    if (has_target) {
        const tn = wire.TargetedNotify{
            .uuid = target_uuid,
            .timeout_ms = 0,
            .msg_len = @intCast(message.len),
        };
        wire.writeControlWithTrail(fd, .targeted_notify, std.mem.asBytes(&tn), message) catch |err| {
            print("Error: failed to send targeted notify: {s}\n", .{@errorName(err)});
        };
    } else {
        const n = wire.Notify{ .msg_len = @intCast(message.len) };
        wire.writeControlWithTrail(fd, .broadcast_notify, std.mem.asBytes(&n), message) catch |err| {
            print("Error: failed to send broadcast notify: {s}\n", .{@errorName(err)});
        };
    }
}

// ─── Binary CLI helpers ────────────────────────────────────────────────────

/// Connect to SES with CLI handshake byte. Returns fd on success.
pub fn connectSesCliChannel(allocator: std.mem.Allocator) ?std.posix.fd_t {
    const wire = core.wire;
    const socket_path = ipc.getSesSocketPath(allocator) catch |err| {
        print("Error: failed to resolve ses socket path: {s}\n", .{@errorName(err)});
        return null;
    };
    defer allocator.free(socket_path);
    var client = ipc.Client.connect(socket_path) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            print("ses daemon is not running\n", .{});
        }
        return null;
    };
    const fd = client.fd;

    // Guard against stale/wrong listeners on ses.sock (e.g. inherited fd bugs).
    // Without read/write timeouts, CLI commands can hang indefinitely.
    const timeout = std.posix.timeval{ .sec = 3, .usec = 0 };
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch |err| {
        print("Warning: failed to set ses CLI receive timeout: {s}\n", .{@errorName(err)});
    };
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch |err| {
        print("Warning: failed to set ses CLI send timeout: {s}\n", .{@errorName(err)});
    };

    wire.sendCliHandshake(fd) catch |err| {
        print("Error: failed to handshake with ses daemon: {s}\n", .{@errorName(err)});
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
        print("Error: --creator/--last requires running inside hexe terminal\n", .{});
        return null;
    };
    const parsed_current = parseUuid32Hex(current_uuid) orelse return null;

    const fd = connectSesCliChannel(allocator) orelse return null;
    defer posix.close(fd);

    var pu: wire.PaneUuid = undefined;
    pu.uuid = parsed_current;
    wire.writeControl(fd, .pane_info, std.mem.asBytes(&pu)) catch |err| {
        print("Error: failed to request current pane info: {s}\n", .{@errorName(err)});
        return null;
    };

    const hdr = wire.readControlHeader(fd) catch |err| {
        print("Error: failed to read current pane info response: {s}\n", .{@errorName(err)});
        return null;
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type == .pane_not_found) {
        print("Error: pane not found\n", .{});
        return null;
    }
    if (msg_type != .pane_info) {
        print("Error: invalid current pane info response\n", .{});
        return null;
    }
    if (hdr.payload_len < @sizeOf(wire.PaneInfoResp)) {
        print("Error: malformed current pane info response\n", .{});
        return null;
    }

    const resp = wire.readStruct(wire.PaneInfoResp, fd) catch |err| {
        print("Error: failed to read current pane info payload: {s}\n", .{@errorName(err)});
        return null;
    };
    if (want_creator) {
        if (resp.has_created_from != 0) return resp.created_from;
        print("Error: current pane has no creator\n", .{});
        return null;
    } else {
        if (resp.has_focused_from != 0) return resp.focused_from;
        print("Error: current pane has no previous focus\n", .{});
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

pub fn printSessionTree(allocator: std.mem.Allocator, json: []const u8, indent: []const u8, pane_name_map: ?*const std.AutoHashMap([32]u8, []const u8)) void {
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
        printTreeNode(prefix, marker, ansi.TAB, "tab", tab.name, tab.uuid[0..8]);

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
                    .split => printTreeNode(lp, sym, ansi.SPLIT, "split", pname, child.uuid[0..8]),
                    .float => printTreeNode(lp, sym, ansi.FLOAT, "float", pname, child.uuid[0..8]),
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
        printTreeNode(prefix, sym, ansi.FLOAT, "float", pname, float_state.pane_uuid[0..8]);

        top_index += 1;
    }
}

pub fn runSend(allocator: std.mem.Allocator, uuid: []const u8, creator: bool, last: bool, broadcast: bool, enter: bool, ctrl: []const u8, text: []const u8) !void {
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
            print("Error: --ctrl requires a single letter (a-z)\n", .{});
            return;
        }
    } else if (text.len > 0) {
        if (text.len > data_buf.len - 1) {
            print("Error: text too long\n", .{});
            return;
        }
        @memcpy(data_buf[0..text.len], text);
        data_len = text.len;
    }

    if (enter and data_len < data_buf.len) {
        data_buf[data_len] = '\n';
        data_len += 1;
    }

    if (data_len == 0) {
        print("Error: no data to send (use text argument, --ctrl, or --enter)\n", .{});
        return;
    }

    var target_uuid: [32]u8 = .{0} ** 32;

    if (uuid.len > 0) {
        target_uuid = parseUuid32Hex(uuid) orelse {
            print("Error: --uuid must be 32 hex chars\n", .{});
            return;
        };
    } else if (creator or last) {
        if (resolveRelatedPane(allocator, creator)) |resolved| {
            target_uuid = resolved;
        } else return;
    } else if (broadcast) {
        // All-zeros UUID = broadcast.
    } else {
        const env_uuid = std.posix.getenv("HEXE_PANE_UUID") orelse {
            print("Error: no target specified (use --uuid, --creator, --last, --broadcast, or run inside mux)\n", .{});
            return;
        };
        target_uuid = parseUuid32Hex(env_uuid) orelse {
            print("Error: invalid HEXE_PANE_UUID\n", .{});
            return;
        };
    }

    const fd = connectSesCliChannel(allocator) orelse return;
    defer posix.close(fd);

    const sk = wire.SendKeys{
        .uuid = target_uuid,
        .data_len = @intCast(data_len),
    };
    wire.writeControlWithTrail(fd, .send_keys, std.mem.asBytes(&sk), data_buf[0..data_len]) catch |err| {
        print("Error: failed to send keys: {s}\n", .{@errorName(err)});
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
        print("Error: invalid dir (use left/right/up/down)\n", .{});
        return;
    };

    const ses_path = ipc.getSesSocketPath(allocator) catch {
        print("Error: cannot determine ses socket path\n", .{});
        return;
    };
    defer allocator.free(ses_path);

    var client = ipc.Client.connect(ses_path) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            print("ses is not running\n", .{});
            return;
        }
        return err;
    };
    defer client.close();
    const fd = client.fd;

    const pane_uuid = std.posix.getenv("HEXE_PANE_UUID") orelse {
        print("Error: HEXE_PANE_UUID not set (not running inside mux?)\n", .{});
        return;
    };
    const pane_uuid_arr = parseUuid32Hex(pane_uuid) orelse {
        print("Error: HEXE_PANE_UUID invalid length\n", .{});
        return;
    };

    // Send versioned CLI handshake.
    wire.sendCliHandshake(fd) catch {
        print("Error: handshake failed\n", .{});
        return;
    };

    // Send focus_move message.
    var fm: wire.FocusMove = undefined;
    fm.uuid = pane_uuid_arr;
    fm.dir = dir_byte;
    wire.writeControl(fd, .focus_move, std.mem.asBytes(&fm)) catch {
        print("Error: failed to send focus_move\n", .{});
        return;
    };
}

/// Ask mux whether the current shell should be allowed to exit.
/// Intended to be called from shell keybindings (exit/Ctrl+D) so mux can
/// present a confirm dialog for the last split.
///
/// Exit codes: 0=allow, 1=deny
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

    // Wait for exit_intent_result (may block for popup confirm).
    const hdr = wire.readControlHeader(fd) catch {
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
        print("Error: status out of range for shell event\n", .{});
        return;
    }
    if (jobs < 0 or jobs > std.math.maxInt(u16)) {
        print("Error: jobs out of range for shell event\n", .{});
        return;
    }
    if (cmd.len > std.math.maxInt(u16) or cwd.len > std.math.maxInt(u16)) {
        print("Error: shell event payload too long\n", .{});
        return;
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
        print("Error: session name or UUID prefix required\n", .{});
        return;
    }

    const fd = connectSesCliChannel(allocator) orelse return;
    defer posix.close(fd);

    // Send kill_session request.
    const ks = wire.KillSession{ .id_len = @intCast(target.len) };
    wire.writeControlWithTrail(fd, .kill_session, std.mem.asBytes(&ks), target) catch {
        print("Error: failed to send request\n", .{});
        return;
    };

    // Read response.
    const hdr = wire.readControlHeader(fd) catch {
        print("Error: failed to read response\n", .{});
        return;
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type != .kill_session or hdr.payload_len < @sizeOf(wire.KillSessionResult)) {
        print("Error: unexpected response\n", .{});
        return;
    }

    const result = wire.readStruct(wire.KillSessionResult, fd) catch {
        print("Error: failed to read result\n", .{});
        return;
    };

    if (result.success != 0) {
        print("Killed session ({d} panes)\n", .{result.killed_panes});
    } else {
        // Read error message.
        if (result.error_len > 0) {
            var err_buf: [256]u8 = undefined;
            const err_len = @min(result.error_len, err_buf.len);
            wire.readExact(fd, err_buf[0..err_len]) catch {
                print("Error: session not found\n", .{});
                return;
            };
            print("Error: {s}\n", .{err_buf[0..err_len]});
        } else {
            print("Error: session not found\n", .{});
        }
    }
}

pub fn runSesClear(allocator: std.mem.Allocator, force: bool) !void {
    const wire = core.wire;
    const posix = std.posix;

    if (!force) {
        print("Warning: This will kill ALL detached sessions. Use -f to confirm.\n", .{});
        return;
    }

    const fd = connectSesCliChannel(allocator) orelse return;
    defer posix.close(fd);

    // Send clear_sessions request (no payload).
    wire.writeControl(fd, .clear_sessions, &.{}) catch {
        print("Error: failed to send request\n", .{});
        return;
    };

    // Read response.
    const hdr = wire.readControlHeader(fd) catch {
        print("Error: failed to read response\n", .{});
        return;
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type != .clear_sessions or hdr.payload_len < @sizeOf(wire.ClearSessionsResult)) {
        print("Error: unexpected response\n", .{});
        return;
    }

    const result = wire.readStruct(wire.ClearSessionsResult, fd) catch {
        print("Error: failed to read result\n", .{});
        return;
    };

    print("Killed {d} sessions ({d} panes)\n", .{ result.killed_sessions, result.killed_panes });
}

// ============================================================================
// Layout save/load/list
// ============================================================================

pub fn runLayoutSave(allocator: std.mem.Allocator, name: []const u8) !void {
    const wire = core.wire;
    const posix = std.posix;

    if (name.len == 0) {
        print("Error: layout name required\n", .{});
        return;
    }

    // Get current pane UUID.
    const uuid_str = posix.getenv("HEXE_PANE_UUID") orelse {
        print("Error: not inside a hexe terminal session (HEXE_PANE_UUID not set)\n", .{});
        return;
    };
    const uuid_arr = parseUuid32Hex(uuid_str) orelse {
        print("Error: invalid HEXE_PANE_UUID\n", .{});
        return;
    };

    // Connect to SES and request the current layout export.
    const fd = connectSesCliChannel(allocator) orelse return;
    defer posix.close(fd);

    var pu: wire.PaneUuid = .{ .uuid = undefined };
    pu.uuid = uuid_arr;
    wire.writeControl(fd, .get_layout, std.mem.asBytes(&pu)) catch {
        print("Error: failed to send request\n", .{});
        return;
    };

    // Read response.
    const hdr = wire.readControlHeader(fd) catch {
        print("Error: failed to read response\n", .{});
        return;
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type == .@"error") {
        if (hdr.payload_len > 0) {
            if (hdr.payload_len > wire.MAX_PAYLOAD_LEN) {
                print("Error response too large\n", .{});
                return;
            }
            const err_buf = allocator.alloc(u8, hdr.payload_len) catch {
                print("Error: server returned error\n", .{});
                return;
            };
            defer allocator.free(err_buf);
            wire.readExact(fd, err_buf) catch |err| {
                print("Error: failed to read server error response: {s}\n", .{@errorName(err)});
                return;
            };
            // Parse error struct to skip msg_len prefix.
            if (err_buf.len >= @sizeOf(wire.Error)) {
                const err_hdr = std.mem.bytesToValue(wire.Error, err_buf[0..@sizeOf(wire.Error)]);
                const msg_start = @sizeOf(wire.Error);
                const msg_end = msg_start + @min(@as(usize, err_hdr.msg_len), err_buf.len - msg_start);
                print("Error: {s}\n", .{err_buf[msg_start..msg_end]});
            } else {
                print("Error: server returned error\n", .{});
            }
        } else {
            print("Error: server returned error\n", .{});
        }
        return;
    }
    if (msg_type != .get_layout or hdr.payload_len == 0) {
        print("Error: unexpected response\n", .{});
        return;
    }
    if (hdr.payload_len > wire.MAX_PAYLOAD_LEN) {
        print("Error: layout response too large\n", .{});
        return;
    }

    // Read raw layout export JSON.
    const layout_export = allocator.alloc(u8, hdr.payload_len) catch {
        print("Error: allocation failed\n", .{});
        return;
    };
    defer allocator.free(layout_export);
    wire.readExact(fd, layout_export) catch {
        print("Error: failed to read layout export\n", .{});
        return;
    };

    // Parse the layout export, find the active tab, and extract tree + splits for CWD lookup.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, layout_export, .{}) catch {
        print("Error: failed to parse layout export\n", .{});
        return;
    };
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            print("Error: invalid layout export format\n", .{});
            return;
        },
    };

    // Find active tab.
    const active_tab_val = root_obj.get("active_tab") orelse {
        print("Error: no active_tab in layout export\n", .{});
        return;
    };
    const active_tab_idx: usize = switch (active_tab_val) {
        .integer => |i| @intCast(i),
        else => 0,
    };

    const tabs_val = root_obj.get("tabs") orelse {
        print("Error: no tabs in layout export\n", .{});
        return;
    };
    const tabs_arr = switch (tabs_val) {
        .array => |a| a,
        else => {
            print("Error: tabs is not array\n", .{});
            return;
        },
    };

    if (active_tab_idx >= tabs_arr.items.len) {
        print("Error: active tab index out of range\n", .{});
        return;
    }

    const tab = switch (tabs_arr.items[active_tab_idx]) {
        .object => |o| o,
        else => {
            print("Error: tab is not object\n", .{});
            return;
        },
    };

    const tree_val = tab.get("tree") orelse {
        print("Error: no tree in tab\n", .{});
        return;
    };

    // Build CWD map from splits array.
    var cwd_map = std.AutoHashMap(i64, []const u8).init(allocator);
    defer cwd_map.deinit();

    if (tab.get("splits")) |splits_val| {
        switch (splits_val) {
            .array => |splits_arr| {
                for (splits_arr.items) |split_item| {
                    switch (split_item) {
                        .object => |split_obj| {
                            const id_val = split_obj.get("id") orelse continue;
                            const id = switch (id_val) {
                                .integer => |i| i,
                                else => continue,
                            };
                            // Use uuid to look up CWD from split's pwd_dir field.
                            if (split_obj.get("pwd_dir")) |pwd_val| {
                                switch (pwd_val) {
                                    .string => |s| {
                                        cwd_map.put(id, s) catch |err| {
                                            print("Error: failed to build layout cwd map: {s}\n", .{@errorName(err)});
                                            return;
                                        };
                                    },
                                    else => {},
                                }
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    // Build layout template from tree, adding CWDs from map.
    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(allocator);
    const writer = out_buf.writer(allocator);

    writer.writeAll("{\n  \"version\": 1,\n  \"tree\": ") catch {
        print("Error: failed to build layout\n", .{});
        return;
    };
    writeLayoutTemplate(writer, tree_val, &cwd_map, 2) catch {
        print("Error: failed to build layout\n", .{});
        return;
    };
    writer.writeAll("\n}\n") catch {
        print("Error: failed to build layout\n", .{});
        return;
    };

    // Write to file.
    const layout_dir = ipc.getLayoutDir(allocator) catch {
        print("Error: cannot determine layout directory\n", .{});
        return;
    };
    defer allocator.free(layout_dir);

    // Create directory if needed.
    std.fs.cwd().makePath(layout_dir) catch {
        print("Error: cannot create layout directory: {s}\n", .{layout_dir});
        return;
    };

    const file_path = std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ layout_dir, name }) catch {
        print("Error: allocation failed\n", .{});
        return;
    };
    defer allocator.free(file_path);

    const file = std.fs.cwd().createFile(file_path, .{ .mode = 0o600 }) catch {
        print("Error: cannot create file: {s}\n", .{file_path});
        return;
    };
    defer file.close();
    file.writeAll(out_buf.items) catch {
        print("Error: failed to write file\n", .{});
        return;
    };

    print("Layout saved: {s}\n", .{file_path});
}

fn writeLayoutTemplate(writer: anytype, value: std.json.Value, cwd_map: *std.AutoHashMap(i64, []const u8), indent: usize) !void {
    const obj = switch (value) {
        .object => |o| o,
        else => {
            try writer.writeAll("null");
            return;
        },
    };

    const type_str = (obj.get("type") orelse {
        try writer.writeAll("null");
        return;
    }).string;

    if (std.mem.eql(u8, type_str, "pane")) {
        const id_val = obj.get("id") orelse {
            try writer.writeAll("{\"type\": \"pane\"}");
            return;
        };
        const id = switch (id_val) {
            .integer => |i| i,
            else => {
                try writer.writeAll("{\"type\": \"pane\"}");
                return;
            },
        };

        if (cwd_map.get(id)) |cwd| {
            try writer.writeAll("{\"type\": \"pane\", \"cwd\": \"");
            try writer.writeAll(cwd);
            try writer.writeAll("\"}");
        } else {
            try writer.writeAll("{\"type\": \"pane\"}");
        }
    } else if (std.mem.eql(u8, type_str, "split")) {
        const dir_str = (obj.get("dir") orelse return).string;
        const ratio_val = obj.get("ratio") orelse return;
        const first = obj.get("first") orelse return;
        const second = obj.get("second") orelse return;

        try writer.writeAll("{\"type\": \"split\", \"dir\": \"");
        try writer.writeAll(dir_str);
        try writer.writeAll("\", \"ratio\": ");

        switch (ratio_val) {
            .float => |f| try writer.print("{d:.6}", .{f}),
            .integer => |i| try writer.print("{d}.0", .{i}),
            else => try writer.writeAll("0.5"),
        }

        try writer.writeAll(",\n");
        // indent
        for (0..indent + 2) |_| try writer.writeAll(" ");
        try writer.writeAll("\"first\": ");
        try writeLayoutTemplate(writer, first, cwd_map, indent + 2);
        try writer.writeAll(",\n");
        for (0..indent + 2) |_| try writer.writeAll(" ");
        try writer.writeAll("\"second\": ");
        try writeLayoutTemplate(writer, second, cwd_map, indent + 2);
        try writer.writeAll("}");
    } else {
        try writer.writeAll("null");
    }
}

/// Recursively serialize a std.json.Value to a writer (compact JSON).
fn serializeJsonValue(val: std.json.Value, writer: anytype) !void {
    switch (val) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .string => |s| try writeJsonString(writer, s),
        .array => |a| {
            try writer.writeAll("[");
            for (a.items, 0..) |item, idx| {
                if (idx > 0) try writer.writeAll(",");
                try serializeJsonValue(item, writer);
            }
            try writer.writeAll("]");
        },
        .object => |o| {
            try writer.writeAll("{");
            var first = true;
            var it = o.iterator();
            while (it.next()) |entry| {
                if (!first) try writer.writeAll(",");
                first = false;
                try writeJsonString(writer, entry.key_ptr.*);
                try writer.writeAll(":");
                try serializeJsonValue(entry.value_ptr.*, writer);
            }
            try writer.writeAll("}");
        },
        .number_string => |s| try writer.writeAll(s),
    }
}

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeAll("\"");
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            else => {
                if (ch < 0x20) {
                    try writer.print("\\u00{X:0>2}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
    try writer.writeAll("\"");
}

pub fn runLayoutLoad(allocator: std.mem.Allocator, name: []const u8) !void {
    const wire = core.wire;
    const posix = std.posix;

    if (name.len == 0) {
        print("Error: layout name required\n", .{});
        return;
    }

    // Get current pane UUID.
    const uuid_str = posix.getenv("HEXE_PANE_UUID") orelse {
        print("Error: not inside a hexe terminal session (HEXE_PANE_UUID not set)\n", .{});
        return;
    };
    const uuid_arr = parseUuid32Hex(uuid_str) orelse {
        print("Error: invalid HEXE_PANE_UUID\n", .{});
        return;
    };

    // Read layout file.
    const layout_dir = ipc.getLayoutDir(allocator) catch {
        print("Error: cannot determine layout directory\n", .{});
        return;
    };
    defer allocator.free(layout_dir);

    const file_path = std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ layout_dir, name }) catch {
        print("Error: allocation failed\n", .{});
        return;
    };
    defer allocator.free(file_path);

    const file = std.fs.cwd().openFile(file_path, .{}) catch {
        print("Error: layout not found: {s}\n", .{file_path});
        return;
    };
    defer file.close();

    const file_contents = file.readToEndAlloc(allocator, 1024 * 1024) catch {
        print("Error: failed to read layout file\n", .{});
        return;
    };
    defer allocator.free(file_contents);

    // Parse and validate.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, file_contents, .{}) catch {
        print("Error: invalid layout JSON\n", .{});
        return;
    };
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            print("Error: layout file is not a JSON object\n", .{});
            return;
        },
    };

    const tree_val = root_obj.get("tree") orelse {
        print("Error: no 'tree' in layout file\n", .{});
        return;
    };

    // Re-serialize just the tree portion to send to MUX.
    var tree_buf: std.ArrayList(u8) = .empty;
    defer tree_buf.deinit(allocator);
    serializeJsonValue(tree_val, tree_buf.writer(allocator)) catch {
        print("Error: failed to serialize tree\n", .{});
        return;
    };

    // Connect to SES and send apply_layout.
    const fd = connectSesCliChannel(allocator) orelse return;
    defer posix.close(fd);

    var al: wire.ApplyLayout = .{
        .uuid = undefined,
        .tree_json_len = @intCast(tree_buf.items.len),
    };
    al.uuid = uuid_arr;

    wire.writeControlWithTrail(fd, .apply_layout, std.mem.asBytes(&al), tree_buf.items) catch {
        print("Error: failed to send layout\n", .{});
        return;
    };

    print("Layout applied: {s}\n", .{name});
}

pub fn runLayoutList(allocator: std.mem.Allocator) !void {
    const layout_dir = ipc.getLayoutDir(allocator) catch {
        print("Error: cannot determine layout directory\n", .{});
        return;
    };
    defer allocator.free(layout_dir);

    var dir = std.fs.cwd().openDir(layout_dir, .{ .iterate = true }) catch {
        // Directory doesn't exist = no layouts.
        print("No saved layouts\n", .{});
        return;
    };
    defer dir.close();

    var count: usize = 0;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".json")) {
            const base = entry.name[0 .. entry.name.len - 5];
            print("{s}\n", .{base});
            count += 1;
        }
    }

    if (count == 0) {
        print("No saved layouts\n", .{});
    }
}
