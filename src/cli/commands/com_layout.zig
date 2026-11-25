//! Layout CLI commands: save/load/list session layout templates. Split from
//! `com.zig` (PLAN.md 2.3 spirit — same command-per-file pattern the module
//! already uses for pod/record/mux commands), re-exported there so dispatch is
//! unchanged. Bodies are moved verbatim; shared CLI helpers are aliased from
//! `com.zig` (circular import is fine in Zig).

const std = @import("std");
const core = @import("core");
const com = @import("com.zig");
const shared = @import("shared.zig");
const terminal = @import("terminal");

const cli_ui = core.cli_ui;
const ipc = core.ipc;
const connectSesCliChannel = com.connectSesCliChannel;
const parseUuid32Hex = com.parseUuid32Hex;

pub fn runLayoutSave(allocator: std.mem.Allocator, name: []const u8) !void {
    const wire = core.wire;
    const posix = std.posix;

    if (name.len == 0) {
        cli_ui.printErr("layout name required", .{});
        cli_ui.printErrHint("Usage: hexe terminal layout save <name>", .{});
        std.process.exit(1);
    }

    // Get current pane UUID.
    const uuid_str = posix.getenv("HEXE_PANE_UUID") orelse {
        cli_ui.printErr("not inside a hexe terminal session (HEXE_PANE_UUID not set)", .{});
        std.process.exit(1);
    };
    const uuid_arr = parseUuid32Hex(uuid_str) orelse {
        cli_ui.printErr("invalid HEXE_PANE_UUID", .{});
        std.process.exit(1);
    };

    // Connect to SES and request the current layout export.
    const fd = connectSesCliChannel(allocator) orelse std.process.exit(1);
    defer posix.close(fd);

    var pu: wire.PaneUuid = .{ .uuid = undefined };
    pu.uuid = uuid_arr;
    wire.writeControl(fd, .get_layout, std.mem.asBytes(&pu)) catch {
        cli_ui.printErr("failed to send request", .{});
        std.process.exit(1);
    };

    // Read response.
    const hdr = wire.readControlHeader(fd) catch {
        cli_ui.printErr("failed to read response", .{});
        std.process.exit(1);
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type == .@"error") {
        if (hdr.payload_len > 0) {
            if (hdr.payload_len > wire.MAX_PAYLOAD_LEN) {
                cli_ui.printErr("error response too large", .{});
                std.process.exit(1);
            }
            const err_buf = allocator.alloc(u8, hdr.payload_len) catch {
                cli_ui.printErr("server returned error", .{});
                std.process.exit(1);
            };
            defer allocator.free(err_buf);
            wire.readExact(fd, err_buf) catch |err| {
                cli_ui.printErr("failed to read server error response: {s}", .{@errorName(err)});
                std.process.exit(1);
            };
            // Parse error struct to skip msg_len prefix.
            if (err_buf.len >= @sizeOf(wire.Error)) {
                const err_hdr = std.mem.bytesToValue(wire.Error, err_buf[0..@sizeOf(wire.Error)]);
                const msg_start = @sizeOf(wire.Error);
                const msg_end = msg_start + @min(@as(usize, err_hdr.msg_len), err_buf.len - msg_start);
                cli_ui.printErr("{s}", .{err_buf[msg_start..msg_end]});
            } else {
                cli_ui.printErr("server returned error", .{});
            }
        } else {
            cli_ui.printErr("server returned error", .{});
        }
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

    // Parse the layout export, find the active tab, and extract tree + splits for CWD lookup.
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

    // Find active tab.
    const active_tab_val = root_obj.get("active_tab") orelse {
        cli_ui.printErr("no active_tab in layout export", .{});
        std.process.exit(1);
    };
    const active_tab_idx: usize = switch (active_tab_val) {
        .integer => |i| @intCast(i),
        else => 0,
    };

    const tabs_val = root_obj.get("tabs") orelse {
        cli_ui.printErr("no tabs in layout export", .{});
        std.process.exit(1);
    };
    const tabs_arr = switch (tabs_val) {
        .array => |a| a,
        else => {
            cli_ui.printErr("tabs is not array", .{});
            std.process.exit(1);
        },
    };

    if (active_tab_idx >= tabs_arr.items.len) {
        cli_ui.printErr("active tab index out of range", .{});
        std.process.exit(1);
    }

    const tab = switch (tabs_arr.items[active_tab_idx]) {
        .object => |o| o,
        else => {
            cli_ui.printErr("tab is not object", .{});
            std.process.exit(1);
        },
    };

    const tree_val = tab.get("tree") orelse {
        cli_ui.printErr("no tree in tab", .{});
        std.process.exit(1);
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
                                            cli_ui.printErr("failed to build layout cwd map: {s}", .{@errorName(err)});
                                            std.process.exit(1);
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
        cli_ui.printErr("failed to build layout", .{});
        std.process.exit(1);
    };
    writeLayoutTemplate(writer, tree_val, &cwd_map, 2) catch {
        cli_ui.printErr("failed to build layout", .{});
        std.process.exit(1);
    };
    writer.writeAll("\n}\n") catch {
        cli_ui.printErr("failed to build layout", .{});
        std.process.exit(1);
    };

    // Write to file.
    const layout_dir = ipc.getLayoutDir(allocator) catch {
        cli_ui.printErr("cannot determine layout directory", .{});
        std.process.exit(1);
    };
    defer allocator.free(layout_dir);

    // Create directory if needed.
    std.fs.cwd().makePath(layout_dir) catch {
        cli_ui.printErr("cannot create layout directory: {s}", .{layout_dir});
        std.process.exit(1);
    };

    const file_path = std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ layout_dir, name }) catch {
        cli_ui.printErr("allocation failed", .{});
        std.process.exit(1);
    };
    defer allocator.free(file_path);

    const file = std.fs.cwd().createFile(file_path, .{ .mode = 0o600 }) catch {
        cli_ui.printErr("cannot create file: {s}", .{file_path});
        std.process.exit(1);
    };
    defer file.close();
    file.writeAll(out_buf.items) catch {
        cli_ui.printErr("failed to write file", .{});
        std.process.exit(1);
    };

    var out = std.fs.File.stdout().deprecatedWriter();
    const p = cli_ui.Palette.forStdout();
    var path_buf: [512]u8 = undefined;
    const disp_path = cli_ui.compactHome(file_path, &path_buf);
    try out.print("{s}✓{s} Layout saved: {s}{s}{s} {s}({s}){s}\n", .{
        p.success, p.reset, p.bold, name, p.reset, p.dim, disp_path, p.reset,
    });
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
            try writer.writeAll("{\"type\": \"pane\", \"cwd\": ");
            try writeJsonString(writer, cwd);
            try writer.writeAll("}");
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

pub fn runLayoutLoad(allocator: std.mem.Allocator, name_arg: []const u8) !void {
    const wire = core.wire;
    const posix = std.posix;

    const layout_dir = ipc.getLayoutDir(allocator) catch {
        cli_ui.printErr("cannot determine layout directory", .{});
        std.process.exit(1);
    };
    defer allocator.free(layout_dir);

    var owned_name: ?[]u8 = null;
    defer if (owned_name) |n| allocator.free(n);
    var name: []const u8 = name_arg;

    if (name.len == 0) {
        if (posix.isatty(posix.STDIN_FILENO) and posix.isatty(posix.STDOUT_FILENO)) {
            owned_name = try pickLayoutName(allocator, layout_dir);
            if (owned_name) |picked| {
                name = picked;
            } else {
                return;
            }
        } else {
            cli_ui.printErr("layout name required", .{});
            cli_ui.printErrHint("List saved layouts with: hexe terminal layout list", .{});
            std.process.exit(1);
        }
    }

    // Get current pane UUID.
    const uuid_str = posix.getenv("HEXE_PANE_UUID") orelse {
        cli_ui.printErr("not inside a hexe terminal session (HEXE_PANE_UUID not set)", .{});
        std.process.exit(1);
    };
    const uuid_arr = parseUuid32Hex(uuid_str) orelse {
        cli_ui.printErr("invalid HEXE_PANE_UUID", .{});
        std.process.exit(1);
    };

    const file_path = std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ layout_dir, name }) catch {
        cli_ui.printErr("allocation failed", .{});
        std.process.exit(1);
    };
    defer allocator.free(file_path);

    const file = std.fs.cwd().openFile(file_path, .{}) catch {
        cli_ui.printErr("layout not found: {s}", .{file_path});
        cli_ui.printErrHint("List saved layouts with: hexe terminal layout list", .{});
        std.process.exit(1);
    };
    defer file.close();

    const file_contents = file.readToEndAlloc(allocator, 1024 * 1024) catch {
        cli_ui.printErr("failed to read layout file", .{});
        std.process.exit(1);
    };
    defer allocator.free(file_contents);

    // Parse and validate.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, file_contents, .{}) catch {
        cli_ui.printErr("invalid layout JSON", .{});
        std.process.exit(1);
    };
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            cli_ui.printErr("layout file is not a JSON object", .{});
            std.process.exit(1);
        },
    };

    const tree_val = root_obj.get("tree") orelse {
        cli_ui.printErr("no 'tree' in layout file", .{});
        std.process.exit(1);
    };

    // Re-serialize just the tree portion to send to MUX.
    var tree_buf: std.ArrayList(u8) = .empty;
    defer tree_buf.deinit(allocator);
    serializeJsonValue(tree_val, tree_buf.writer(allocator)) catch {
        cli_ui.printErr("failed to serialize tree", .{});
        std.process.exit(1);
    };

    // Connect to SES and send apply_layout.
    const fd = connectSesCliChannel(allocator) orelse std.process.exit(1);
    defer posix.close(fd);

    var al: wire.ApplyLayout = .{
        .uuid = undefined,
        .tree_json_len = @intCast(tree_buf.items.len),
    };
    al.uuid = uuid_arr;

    wire.writeControlWithTrail(fd, .apply_layout, std.mem.asBytes(&al), tree_buf.items) catch {
        cli_ui.printErr("failed to send layout", .{});
        std.process.exit(1);
    };

    if (!shared.readOkOrError(allocator, fd)) std.process.exit(1);

    var out = std.fs.File.stdout().deprecatedWriter();
    const p = cli_ui.Palette.forStdout();
    try out.print("{s}✓{s} Layout applied: {s}{s}{s}\n", .{ p.success, p.reset, p.bold, name, p.reset });
}

fn pickLayoutName(allocator: std.mem.Allocator, layout_dir: []const u8) !?[]u8 {
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var dir = std.fs.cwd().openDir(layout_dir, .{ .iterate = true }) catch {
        const p = cli_ui.Palette.forStderr();
        std.debug.print("{s}○{s} No saved layouts found\n", .{ p.warn, p.reset });
        return null;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".json")) {
            const base = entry.name[0 .. entry.name.len - 5];
            try names.append(allocator, try allocator.dupe(u8, base));
        }
    }

    if (names.items.len == 0) {
        const p = cli_ui.Palette.forStderr();
        std.debug.print("{s}○{s} No saved layouts found\n", .{ p.warn, p.reset });
        return null;
    }

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    const chosen = try terminal.runStandalonePicker(allocator, names.items, .{
        .title = "Load layout",
        .hint = "↑↓/jk move · / filter · Enter apply · Esc cancel",
        .filterable = true,
    });
    const idx = chosen orelse return null;
    return try allocator.dupe(u8, names.items[idx]);
}

pub fn runLayoutList(allocator: std.mem.Allocator) !void {
    const layout_dir = ipc.getLayoutDir(allocator) catch {
        cli_ui.printErr("cannot determine layout directory", .{});
        std.process.exit(1);
    };
    defer allocator.free(layout_dir);

    var out = std.fs.File.stdout().deprecatedWriter();
    const p = cli_ui.Palette.forStdout();
    const is_tty = std.posix.isatty(std.posix.STDOUT_FILENO);

    var dir = std.fs.cwd().openDir(layout_dir, .{ .iterate = true }) catch {
        try out.print("{s}No saved layouts{s}\n", .{ p.dim, p.reset });
        return;
    };
    defer dir.close();

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".json")) {
            const base = entry.name[0 .. entry.name.len - 5];
            try names.append(allocator, try allocator.dupe(u8, base));
        }
    }

    if (names.items.len == 0) {
        try out.print("{s}No saved layouts{s}\n", .{ p.dim, p.reset });
        return;
    }

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    if (is_tty) {
        var dir_buf: [512]u8 = undefined;
        const dir_disp = cli_ui.compactHome(layout_dir, &dir_buf);
        try out.print("{s}Saved layouts{s} {s}({s}){s}\n", .{ p.bold, p.reset, p.dim, dir_disp, p.reset });
        for (names.items) |n| {
            try out.print("  {s}•{s} {s}{s}{s}\n", .{ p.accent, p.reset, p.bold, n, p.reset });
        }
    } else {
        for (names.items) |n| {
            try out.print("{s}\n", .{n});
        }
    }
}
