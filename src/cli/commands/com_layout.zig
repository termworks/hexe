//! Layout CLI commands: save/load/list session layout templates. Split from
//! `com.zig` (PLAN.md 2.3 spirit — same command-per-file pattern the module
//! already uses for pod/record/mux commands), re-exported there so dispatch is
//! unchanged. Bodies are moved verbatim; shared CLI helpers are aliased from
//! `com.zig` (circular import is fine in Zig).

const std = @import("std");
const core = @import("core");
const com = @import("com.zig");

const print = std.debug.print;
const ipc = core.ipc;
const connectSesCliChannel = com.connectSesCliChannel;
const parseUuid32Hex = com.parseUuid32Hex;

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
