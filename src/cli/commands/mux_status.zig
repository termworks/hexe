//! `hexe terminal status` — read or update a pane's lifecycle status
//! (`idle`, `working`, `blocked`, `done`), or list panes needing attention.

const std = @import("std");
const core = @import("core");
const com = @import("com.zig");
const api_cmd = @import("api.zig");
const shared = @import("shared.zig");
const cli_ui = core.cli_ui;

pub const StatusArgs = struct {
    target: shared.PaneTarget = .{},
    status: []const u8 = "",
    note: []const u8 = "",
    clear: bool = false,
    attention: bool = false,
    json: bool = false,
};

fn unwrapFirstResult(allocator: std.mem.Allocator, reply: []const u8) !std.json.Parsed(std.json.Value) {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, reply, .{});
    errdefer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidReply,
    };
    if (root.get("ok")) |ok_val| {
        if (ok_val == .bool and !ok_val.bool) {
            if (root.get("error")) |err_val| {
                if (err_val == .string) cli_ui.printErr("{s}", .{err_val.string});
            }
            return error.CallFailed;
        }
    }
    return parsed;
}

fn firstResultValue(parsed: *const std.json.Parsed(std.json.Value)) ?std.json.Value {
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const res = root.get("result") orelse return null;
    return switch (res) {
        .array => |a| if (a.items.len > 0) a.items[0] else null,
        else => res,
    };
}

fn jsonStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jsonIntField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |n| n,
        else => null,
    };
}

fn jsonBoolField(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

pub fn runStatus(allocator: std.mem.Allocator, args: StatusArgs) !void {
    const session_opt: ?[]const u8 = if (args.target.session.len > 0) args.target.session else null;

    if (args.attention) {
        const endpoint = api_cmd.resolveEndpoint(allocator, session_opt) catch std.process.exit(2);
        defer endpoint.deinit(allocator);

        const reply = api_cmd.request(allocator, endpoint.label, endpoint.path, "{\"call\":\"attention\"}", false) catch std.process.exit(2);
        defer allocator.free(reply);

        if (args.json) {
            var out_buf: [4096]u8 = undefined;
            var out = std.fs.File.stdout().writer(&out_buf);
            const parsed = unwrapFirstResult(allocator, reply) catch std.process.exit(2);
            defer parsed.deinit();
            const val = firstResultValue(&parsed) orelse {
                try out.interface.writeAll("[]\n");
                try out.interface.flush();
                return;
            };
            try std.json.Stringify.value(val, .{}, &out.interface);
            try out.interface.writeAll("\n");
            try out.interface.flush();
            return;
        }

        const parsed = unwrapFirstResult(allocator, reply) catch std.process.exit(2);
        defer parsed.deinit();
        const val = firstResultValue(&parsed) orelse return;
        const items = switch (val) {
            .array => |a| a.items,
            else => return,
        };

        var out = std.fs.File.stdout().deprecatedWriter();
        const p = cli_ui.Palette.forStdout();
        if (items.len == 0) {
            try out.print("{s}No panes need attention{s}\n", .{ p.muted, p.reset });
            return;
        }
        for (items) |entry| {
            const obj = switch (entry) {
                .object => |o| o,
                else => continue,
            };
            const st = jsonStringField(obj, "status") orelse "idle";
            const uuid = jsonStringField(obj, "uuid") orelse "";
            const name = jsonStringField(obj, "title") orelse jsonStringField(obj, "name") orelse if (uuid.len >= 8) uuid[0..8] else uuid;
            const note = jsonStringField(obj, "note");
            const is_float = jsonBoolField(obj, "is_float");
            const tab = jsonIntField(obj, "tab");

            const badge = if (std.mem.eql(u8, st, "blocked")) "blocked" else if (std.mem.eql(u8, st, "done")) "done" else "notice";
            const badge_color = if (std.mem.eql(u8, badge, "blocked")) p.warn else if (std.mem.eql(u8, badge, "done")) p.success else p.accent;
            try out.print("{s}{s:<7}{s}  {s:<16}", .{ badge_color, badge, p.reset, name });
            if (is_float) {
                if (tab) |t| {
                    try out.print("  {s}float tab:{d}{s}", .{ p.dim, t, p.reset });
                } else {
                    try out.print("  {s}float{s}", .{ p.dim, p.reset });
                }
            } else if (tab) |t| {
                try out.print("  {s}tab:{d}{s}", .{ p.dim, t, p.reset });
            }
            if (note) |n| {
                try out.print("  {s}", .{n});
            }
            try out.writeAll("\n");
        }
        return;
    }

    if (args.status.len > 0 and args.clear) {
        cli_ui.printErr("pass either a status value or --clear, not both", .{});
        std.process.exit(1);
    }

    var validated_status: ?core.pane_status.Status = null;
    if (args.status.len > 0) {
        validated_status = core.pane_status.Status.fromString(args.status) orelse {
            cli_ui.printErr("unknown status '{s}' (expected: idle, working, blocked, done, or clear)", .{args.status});
            std.process.exit(1);
        };
    }

    const resolved = com.resolvePaneTarget(allocator, args.target) catch |err| com.exitUnresolved(err, args.target);
    const endpoint = api_cmd.resolveEndpointForPane(allocator, session_opt, &resolved.uuid) catch std.process.exit(2);
    defer endpoint.deinit(allocator);

    var req_buf: std.ArrayList(u8) = .empty;
    defer req_buf.deinit(allocator);
    const w = req_buf.writer(allocator);
    try w.writeAll("{\"call\":\"status\",\"args\":[");
    try core.regions.writeJsonString(w, &resolved.uuid);
    if (args.clear) {
        try w.writeAll(",{\"clear\":true}");
    } else if (validated_status) |st| {
        try w.writeAll(",{\"status\":");
        try core.regions.writeJsonString(w, st.toString());
        if (args.note.len > 0) {
            try w.writeAll(",\"note\":");
            try core.regions.writeJsonString(w, args.note);
        }
        try w.writeAll("}");
    }
    try w.writeAll("]}");

    const reply = api_cmd.request(allocator, endpoint.label, endpoint.path, req_buf.items, false) catch std.process.exit(2);
    defer allocator.free(reply);

    const parsed = unwrapFirstResult(allocator, reply) catch std.process.exit(2);
    defer parsed.deinit();
    const val = firstResultValue(&parsed) orelse {
        cli_ui.printErr("pane not found in attached frontend", .{});
        std.process.exit(2);
    };
    if (val == .null) {
        cli_ui.printErr("pane not found in attached frontend", .{});
        std.process.exit(2);
    }

    if (args.json) {
        var out_buf: [4096]u8 = undefined;
        var out = std.fs.File.stdout().writer(&out_buf);
        try std.json.Stringify.value(val, .{}, &out.interface);
        try out.interface.writeAll("\n");
        try out.interface.flush();
        return;
    }

    var out = std.fs.File.stdout().deprecatedWriter();

    const obj = switch (val) {
        .object => |o| o,
        else => {
            try out.writeAll("idle\n");
            return;
        },
    };
    const st = jsonStringField(obj, "status") orelse "idle";
    const note = jsonStringField(obj, "note");
    if (note) |n| {
        try out.print("{s}: {s}\n", .{ st, n });
    } else {
        try out.print("{s}\n", .{st});
    }
}
