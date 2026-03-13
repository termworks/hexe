const std = @import("std");
const core = @import("core");
const cli_cmds = @import("commands/com.zig");

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

pub fn runPopNotify(allocator: std.mem.Allocator, uuid: []const u8, timeout: i64, message: []const u8) !void {
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
            print("Error: --uuid required (or run inside hexe terminal)\n", .{});
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

pub fn runPopConfirm(allocator: std.mem.Allocator, uuid: []const u8, timeout: i64, message: []const u8) !void {
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
            print("Error: --uuid required (or run inside hexe terminal)\n", .{});
            return;
        };
        target_uuid = parseUuid32Hex(env_uuid) orelse {
            print("Error: invalid HEXE_PANE_UUID\n", .{});
            std.process.exit(1);
        };
    }

    const fd = cli_cmds.connectSesCliChannel(allocator) orelse std.process.exit(1);

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
        std.process.exit(0);
    }
    std.process.exit(1);
}

pub fn runPopChoose(allocator: std.mem.Allocator, uuid: []const u8, timeout: i64, items: []const u8, message: []const u8) !void {
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
            print("Error: --uuid required (or run inside hexe terminal)\n", .{});
            return;
        };
        target_uuid = parseUuid32Hex(env_uuid) orelse {
            print("Error: invalid HEXE_PANE_UUID\n", .{});
            std.process.exit(1);
        };
    }

    var trail: std.ArrayList(u8) = .empty;
    defer trail.deinit(allocator);

    const title = if (message.len > 0) message else "Select option";
    try trail.appendSlice(allocator, title);

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
    std.process.exit(1);
}
