const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const session_config = core.session_config;
const com = @import("com.zig");
const cli_ui = core.cli_ui;

pub const LayoutSaveScope = enum {
    local,
    global,
    both,
};

/// Save the current terminal layout to .hexe.lua in CWD and register in sessions.json.
pub fn runSesFreeze(allocator: std.mem.Allocator, scope: LayoutSaveScope, name_override: []const u8) !void {
    const wire = core.wire;
    const posix = std.posix;

    // Get current pane UUID from environment
    const uuid_str = posix.getenv("HEXE_PANE_UUID") orelse {
        cli_ui.printErr("not inside a hexe terminal session (HEXE_PANE_UUID not set)", .{});
        std.process.exit(1);
    };
    if (uuid_str.len < 32) {
        cli_ui.printErr("invalid HEXE_PANE_UUID", .{});
        std.process.exit(1);
    }
    var uuid_arr: [32]u8 = undefined;
    @memcpy(&uuid_arr, uuid_str[0..32]);

    // Connect to SES and request the current layout export.
    const fd = com.connectSesCliChannel(allocator) orelse std.process.exit(1);
    defer posix.close(fd);

    var pu: wire.PaneUuid = .{ .uuid = undefined };
    pu.uuid = uuid_arr;
    wire.writeControl(fd, .get_layout, std.mem.asBytes(&pu)) catch {
        cli_ui.printErr("failed to send request", .{});
        std.process.exit(1);
    };

    // Read response
    const hdr = wire.readControlHeader(fd) catch {
        cli_ui.printErr("failed to read response", .{});
        std.process.exit(1);
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type == .@"error") {
        cli_ui.printErr("server returned error", .{});
        std.process.exit(1);
    }
    if (msg_type != .get_layout or hdr.payload_len == 0) {
        cli_ui.printErr("unexpected response", .{});
        std.process.exit(1);
    }
    if (hdr.payload_len > wire.MAX_PAYLOAD_LEN) {
        cli_ui.printErr("layout response too large", .{});
        std.process.exit(1);
    }

    // Read raw layout export JSON.
    const layout_export = allocator.alloc(u8, hdr.payload_len) catch {
        cli_ui.printErr("allocation failed", .{});
        std.process.exit(1);
    };
    defer allocator.free(layout_export);
    wire.readExact(fd, layout_export) catch {
        cli_ui.printErr("failed to read layout export", .{});
        std.process.exit(1);
    };

    // Parse the layout export JSON.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, layout_export, .{}) catch {
        cli_ui.printErr("failed to parse layout export", .{});
        std.process.exit(1);
    };
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            cli_ui.printErr("invalid layout export format", .{});
            std.process.exit(1);
        },
    };

    // Get current working directory as root and registry path
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch "/tmp";

    const used_names = try collectUsedLayoutNames(allocator);
    defer {
        for (used_names) |n| allocator.free(n);
        if (used_names.len > 0) allocator.free(used_names);
    }
    const default_name = std.fs.path.basename(cwd);
    const layout_name = if (name_override.len > 0)
        try validateLayoutName(allocator, name_override)
    else
        try promptLayoutName(allocator, used_names, default_name);
    defer allocator.free(layout_name);

    const freeze_scope: core.session_freeze.SaveScope = switch (scope) {
        .local => .local,
        .global => .global,
        .both => .both,
    };

    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(allocator);
    const out_writer = out_buf.writer(allocator);

    try out_writer.writeAll("local hexe = require(\"hexe\")\n\n");
    try writeLuaStringBuf(out_writer, "hexe.layout(\"", layout_name, "\", {\n");
    try writeLuaStringBuf(out_writer, "  root = \"", cwd, "\",\n");

    // Tabs
    const tabs_val = root_obj.get("tabs") orelse {
        try out_writer.writeAll("})\n");
        try finalizeSave(allocator, freeze_scope, layout_name, cwd, out_buf.items);
        return;
    };
    const tabs_arr = switch (tabs_val) {
        .array => |a| a,
        else => {
            try out_writer.writeAll("})\n");
            try finalizeSave(allocator, freeze_scope, layout_name, cwd, out_buf.items);
            return;
        },
    };

    // Build a CWD map for all panes across all tabs
    try out_writer.writeAll("  tabs = {\n");

    for (tabs_arr.items, 0..) |tab_val, ti| {
        const tab = switch (tab_val) {
            .object => |o| o,
            else => continue,
        };

        const tab_name = if (tab.get("name")) |n|
            switch (n) {
                .string => |s| s,
                else => "tab",
            }
        else
            "tab";

        // Build CWD map from splits array for this tab
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
                                if (split_obj.get("pwd_dir")) |pwd_val| {
                                    switch (pwd_val) {
                                        .string => |s| try cwd_map.put(id, s),
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

        try writeLuaStringBuf(out_writer, "    hexe.tab(\"", tab_name, "\", {\n");
        var wrote_root = false;

        // Check if there's a tree (split structure)
        if (tab.get("tree")) |tree_val| {
            const tree_obj = switch (tree_val) {
                .object => |o| o,
                else => null,
            };
            if (tree_obj) |tree| {
                const type_str = if (tree.get("type")) |t|
                    switch (t) {
                        .string => |s| s,
                        else => null,
                    }
                else
                    null;

                if (type_str) |ts| {
                    if (std.mem.eql(u8, ts, "split")) {
                        try out_writer.writeAll("      root = ");
                        try writeLuaSplitTree(out_writer, tree, &cwd_map, cwd, 3);
                        try out_writer.writeAll(",\n");
                        wrote_root = true;
                    } else if (std.mem.eql(u8, ts, "pane")) {
                        // Single pane — check for cmd/cwd
                        const pane_id = if (tree.get("id")) |id_val|
                            switch (id_val) {
                                .integer => |i| i,
                                else => null,
                            }
                        else
                            null;
                        if (pane_id) |pid| {
                            if (cwd_map.get(pid)) |pane_cwd| {
                                if (!std.mem.eql(u8, pane_cwd, cwd)) {
                                    try writeLuaStringBuf(out_writer, "      root = hexe.pane({ cwd = \"", pane_cwd, "\" }),\n");
                                    wrote_root = true;
                                }
                            }
                        }
                    }
                }
            }
        }

        if (!wrote_root) try out_writer.writeAll("      root = hexe.pane(),\n");
        try out_writer.writeAll("    })");
        if (ti + 1 < tabs_arr.items.len) try out_writer.writeAll(",");
        try out_writer.writeAll("\n");
    }

    try out_writer.writeAll("  },\n");

    // Floats (top-level roots only; skip transient sub-float children)
    const floats_val = root_obj.get("floats");
    if (floats_val) |fv| {
        switch (fv) {
            .array => |floats_arr| {
                var emitted: usize = 0;
                for (floats_arr.items) |float_val| {
                    const float = switch (float_val) {
                        .object => |o| o,
                        else => continue,
                    };
                    if (float.get("parent_float") != null) continue;

                    if (emitted == 0) try out_writer.writeAll("  floats = {\n");
                    if (emitted > 0) try out_writer.writeAll(",\n");
                    emitted += 1;

                    try out_writer.print("    hexe.float(\"float-{d}\", {{", .{emitted});

                    if (float.get("float_key")) |key_val| {
                        switch (key_val) {
                            .integer => |k| {
                                if (k >= 32 and k < 127) {
                                    const key_char: u8 = @intCast(k);
                                    const key_slice = [_]u8{key_char};
                                    try writeLuaStringBuf(out_writer, " key = \"", &key_slice, "\",");
                                }
                            },
                            else => {},
                        }
                    }

                    const width_pct: ?i64 = if (float.get("float_width_pct")) |wv| switch (wv) {
                        .integer => |v| v,
                        else => null,
                    } else null;
                    const height_pct: ?i64 = if (float.get("float_height_pct")) |hv| switch (hv) {
                        .integer => |v| v,
                        else => null,
                    } else null;
                    if (width_pct != null or height_pct != null) {
                        try out_writer.writeAll(" size = {");
                        if (width_pct) |v| try out_writer.print(" width = {d},", .{v});
                        if (height_pct) |v| try out_writer.print(" height = {d},", .{v});
                        try out_writer.writeAll(" },");
                    }

                    const pos_x: i64 = if (float.get("float_pos_x_pct")) |xv| switch (xv) {
                        .integer => |v| v,
                        else => 50,
                    } else 50;
                    const pos_y: i64 = if (float.get("float_pos_y_pct")) |yv| switch (yv) {
                        .integer => |v| v,
                        else => 50,
                    } else 50;
                    if (pos_x != 50 or pos_y != 50) {
                        try out_writer.print(" position = {{ x = {d}, y = {d} }},", .{ pos_x, pos_y });
                    }

                    const is_pwd = if (float.get("is_pwd")) |v| (v == .bool and v.bool) else false;
                    const sticky = if (float.get("sticky")) |v| (v == .bool and v.bool) else false;
                    const is_global = float.get("parent_tab") == null and !is_pwd;
                    if (is_pwd or sticky or is_global) {
                        try out_writer.writeAll(" attrs = {");
                        if (is_pwd) try out_writer.writeAll(" per_cwd = true,");
                        if (is_global) try out_writer.writeAll(" global = true,");
                        if (sticky) try out_writer.writeAll(" sticky = true,");
                        try out_writer.writeAll(" },");
                    }

                    try out_writer.writeAll(" })");
                }
                if (emitted > 0) try out_writer.writeAll("\n  },\n");
            },
            else => {},
        }
    }

    try out_writer.writeAll("})\n");
    try finalizeSave(allocator, freeze_scope, layout_name, cwd, out_buf.items);
}

fn validateLayoutName(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    for (raw) |ch| {
        if (ch == '/' or ch == '\\') {
            cli_ui.printErr("layout name cannot contain '/' or '\\'", .{});
            std.process.exit(1);
        }
    }
    return allocator.dupe(u8, raw);
}

fn promptLayoutName(allocator: std.mem.Allocator, used_names: []const []const u8, default_name: []const u8) ![]u8 {
    const stdout = std.fs.File.stdout();
    const stdin_fd = std.posix.STDIN_FILENO;

    var default_available = default_name.len > 0;
    if (default_available) {
        for (used_names) |used| {
            if (std.ascii.eqlIgnoreCase(used, default_name)) {
                default_available = false;
                break;
            }
        }
    }

    var buf: [256]u8 = undefined;
    while (true) {
        if (default_available) {
            var pbuf: [256]u8 = undefined;
            const prompt = std.fmt.bufPrint(&pbuf, "Layout name [{s}]: ", .{default_name}) catch "Layout name: ";
            try stdout.writeAll(prompt);
        } else {
            try stdout.writeAll("Layout name: ");
        }
        const n = std.posix.read(stdin_fd, buf[0..]) catch return error.EndOfStream;
        if (n == 0) return error.EndOfStream;

        const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
        const raw = if (trimmed.len == 0 and default_available) default_name else trimmed;
        if (raw.len == 0) {
            try stdout.writeAll("Name is required\n");
            continue;
        }

        var has_path_sep = false;
        for (raw) |ch| {
            if (ch == '/' or ch == '\\') {
                has_path_sep = true;
                break;
            }
        }
        if (has_path_sep) {
            try stdout.writeAll("Name cannot contain '/' or '\\\'\n");
            continue;
        }

        for (used_names) |used| {
            if (std.ascii.eqlIgnoreCase(used, raw)) {
                try stdout.writeAll("Name already in use (mux/saved). Choose another\n");
                has_path_sep = true;
                break;
            }
        }
        if (has_path_sep) continue;

        return try allocator.dupe(u8, raw);
    }
}

fn collectUsedLayoutNames(allocator: std.mem.Allocator) ![][]u8 {
    var names = std.ArrayList([]u8).empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    // names from sessions.json
    var registry = try session_config.loadLayoutRegistry(allocator);
    defer session_config.deinitLayoutRegistry(allocator, &registry);
    for (registry.entries) |entry| {
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    // names from running/detached mux sessions in SES
    const wire = core.wire;
    const posix = std.posix;
    const fd = com.connectSesCliChannel(allocator) orelse return names.toOwnedSlice(allocator);
    defer posix.close(fd);

    const flag: [1]u8 = .{0};
    wire.writeControl(fd, .status, &flag) catch return names.toOwnedSlice(allocator);

    const hdr = wire.readControlHeader(fd) catch return names.toOwnedSlice(allocator);
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type != .status or hdr.payload_len < @sizeOf(wire.StatusResp)) return names.toOwnedSlice(allocator);
    if (hdr.payload_len > wire.MAX_PAYLOAD_LEN) return names.toOwnedSlice(allocator);

    const payload = allocator.alloc(u8, hdr.payload_len) catch return names.toOwnedSlice(allocator);
    defer allocator.free(payload);
    wire.readExact(fd, payload) catch return names.toOwnedSlice(allocator);

    var off: usize = 0;
    const status_hdr = std.mem.bytesToValue(wire.StatusResp, payload[off..][0..@sizeOf(wire.StatusResp)]);
    off += @sizeOf(wire.StatusResp);

    var ci: u16 = 0;
    while (ci < status_hdr.client_count) : (ci += 1) {
        if (off + @sizeOf(wire.StatusClient) > payload.len) break;
        const sc = std.mem.bytesToValue(wire.StatusClient, payload[off..][0..@sizeOf(wire.StatusClient)]);
        off += @sizeOf(wire.StatusClient);

        if (off + sc.name_len > payload.len) break;
        const name = payload[off .. off + sc.name_len];
        off += sc.name_len;
        if (name.len > 0) try names.append(allocator, try allocator.dupe(u8, name));

        if (off + sc.session_state_len > payload.len) break;
        off += sc.session_state_len;

        var pi: u16 = 0;
        while (pi < sc.pane_count) : (pi += 1) {
            if (off + @sizeOf(wire.StatusPaneEntry) > payload.len) break;
            const pe = std.mem.bytesToValue(wire.StatusPaneEntry, payload[off..][0..@sizeOf(wire.StatusPaneEntry)]);
            off += @sizeOf(wire.StatusPaneEntry);
            if (off + pe.name_len + pe.sticky_pwd_len > payload.len) break;
            off += pe.name_len + pe.sticky_pwd_len;
        }
    }

    var di: u16 = 0;
    while (di < status_hdr.detached_count) : (di += 1) {
        if (off + @sizeOf(wire.DetachedSessionEntry) > payload.len) break;
        const de = std.mem.bytesToValue(wire.DetachedSessionEntry, payload[off..][0..@sizeOf(wire.DetachedSessionEntry)]);
        off += @sizeOf(wire.DetachedSessionEntry);
        if (off + de.name_len > payload.len) break;
        const name = payload[off .. off + de.name_len];
        off += de.name_len;
        if (name.len > 0) try names.append(allocator, try allocator.dupe(u8, name));
        if (off + de.session_state_len > payload.len) break;
        off += de.session_state_len;
    }

    return names.toOwnedSlice(allocator);
}

fn finalizeSave(
    allocator: std.mem.Allocator,
    scope: core.session_freeze.SaveScope,
    layout_name: []const u8,
    cwd: []const u8,
    lua_content: []const u8,
) !void {
    var saved = core.session_freeze.saveSessionLayout(allocator, scope, layout_name, cwd, lua_content) catch |err| {
        cli_ui.printErr("failed to save layout: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer saved.deinit(allocator);

    var out = std.fs.File.stdout().deprecatedWriter();
    const p = cli_ui.Palette.forStdout();
    var path_buf: [512]u8 = undefined;
    const path_disp = cli_ui.compactHome(saved.written_path, &path_buf);
    switch (scope) {
        .local => try out.print("{s}✓{s} Saved local layout: {s}{s}{s}\n", .{ p.success, p.reset, p.bold, path_disp, p.reset }),
        .global => try out.print("{s}✓{s} Saved global layout: {s}{s}{s} {s}→ {s}{s}\n", .{ p.success, p.reset, p.bold, layout_name, p.reset, p.dim, path_disp, p.reset }),
        .both => try out.print("{s}✓{s} Saved layout {s}{s}{s} {s}({s}){s}\n", .{ p.success, p.reset, p.bold, layout_name, p.reset, p.dim, path_disp, p.reset }),
    }
}

fn writeLuaSplitTree(writer: anytype, obj: std.json.ObjectMap, cwd_map: *std.AutoHashMap(i64, []const u8), root_cwd: []const u8, indent: usize) anyerror!void {
    try writeLuaSplitTreeSized(writer, obj, cwd_map, root_cwd, indent, null);
}

fn writeLuaSplitTreeSized(writer: anytype, obj: std.json.ObjectMap, cwd_map: *std.AutoHashMap(i64, []const u8), root_cwd: []const u8, indent: usize, size: ?u8) anyerror!void {
    const type_str = if (obj.get("type")) |t|
        switch (t) {
            .string => |s| s,
            else => return,
        }
    else
        return;

    if (std.mem.eql(u8, type_str, "pane")) {
        try writer.writeAll("hexe.pane({");
        if (size) |s| try writer.print(" size = {d},", .{s});

        const pane_id = if (obj.get("id")) |id_val|
            switch (id_val) {
                .integer => |i| i,
                else => null,
            }
        else
            null;

        if (pane_id) |pid| {
            if (cwd_map.get(pid)) |pane_cwd| {
                if (!std.mem.eql(u8, pane_cwd, root_cwd)) {
                    try writeLuaStringBuf(writer, " cwd = \"", pane_cwd, "\",");
                }
            }
        }
        try writer.writeAll(" })");
    } else if (std.mem.eql(u8, type_str, "split")) {
        const dir_str = if (obj.get("dir")) |d|
            switch (d) {
                .string => |s| s,
                else => "horizontal",
            }
        else
            "horizontal";
        try writer.print("hexe.split(\"{s}\", {{\n", .{dir_str});

        // Ratio — calculate sizes from it
        const ratio: f64 = if (obj.get("ratio")) |r|
            switch (r) {
                .float => r.float,
                .integer => @floatFromInt(r.integer),
                else => 0.5,
            }
        else
            0.5;

        const size_first: u8 = @intFromFloat(@round(std.math.clamp(ratio, 0.05, 0.95) * 100.0));
        const size_second: u8 = 100 - size_first;

        // Emit first child with size
        if (obj.get("first")) |f_val| {
            switch (f_val) {
                .object => |f| {
                    try writeIndent(writer, indent + 1);
                    try writeLuaSplitChildWithSize(writer, f, cwd_map, root_cwd, size_first, indent + 1);
                    try writer.writeAll(",\n");
                },
                else => {},
            }
        }

        // Emit second child with size
        if (obj.get("second")) |s_val| {
            switch (s_val) {
                .object => |s| {
                    try writeIndent(writer, indent + 1);
                    try writeLuaSplitChildWithSize(writer, s, cwd_map, root_cwd, size_second, indent + 1);
                    try writer.writeAll(",\n");
                },
                else => {},
            }
        }

        try writeIndent(writer, indent);
        if (size) |s| {
            try writer.print("}}, {{ size = {d} }})", .{s});
        } else {
            try writer.writeAll("})");
        }
    }
}

fn writeLuaSplitChildWithSize(writer: anytype, obj: std.json.ObjectMap, cwd_map: *std.AutoHashMap(i64, []const u8), root_cwd: []const u8, size: u8, indent: usize) anyerror!void {
    const type_str = if (obj.get("type")) |t|
        switch (t) {
            .string => |s| s,
            else => return,
        }
    else
        return;

    if (std.mem.eql(u8, type_str, "pane")) {
        try writer.print("hexe.pane({{ size = {d},", .{size});

        const pane_id = if (obj.get("id")) |id_val|
            switch (id_val) {
                .integer => |i| i,
                else => null,
            }
        else
            null;

        if (pane_id) |pid| {
            if (cwd_map.get(pid)) |pane_cwd| {
                if (!std.mem.eql(u8, pane_cwd, root_cwd)) {
                    try writeLuaStringBuf(writer, " cwd = \"", pane_cwd, "\",");
                }
            }
        }
        try writer.writeAll(" })");
    } else if (std.mem.eql(u8, type_str, "split")) {
        try writeLuaSplitTreeSized(writer, obj, cwd_map, root_cwd, indent, size);
    }
}

fn writeIndent(writer: anytype, level: usize) !void {
    var i: usize = 0;
    while (i < level) : (i += 1) {
        try writer.writeAll("  ");
    }
}

fn writeLuaStringBuf(writer: anytype, prefix: []const u8, value: []const u8, suffix: []const u8) !void {
    try writer.writeAll(prefix);
    for (value) |ch| {
        switch (ch) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(ch),
        }
    }
    try writer.writeAll(suffix);
}
