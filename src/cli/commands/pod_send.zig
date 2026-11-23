const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const wire = core.wire;
const pod_protocol = core.pod_protocol;
const shared = @import("shared.zig");
const cli_ui = core.cli_ui;

pub fn runPodSend(
    allocator: std.mem.Allocator,
    uuid: []const u8,
    name: []const u8,
    socket_path: []const u8,
    enter: bool,
    ctrl: []const u8,
    text: []const u8,
) !void {
    // Build bytes to send.
    var data_buf: [4096]u8 = undefined;
    var data_len: usize = 0;

    if (ctrl.len > 0) {
        if (ctrl.len == 1 and ((ctrl[0] >= 'a' and ctrl[0] <= 'z') or (ctrl[0] >= 'A' and ctrl[0] <= 'Z'))) {
            const cch: u8 = if (ctrl[0] >= 'a' and ctrl[0] <= 'z') ctrl[0] else (ctrl[0] - 'A' + 'a');
            data_buf[0] = cch - 'a' + 1;
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

    const target_socket = try resolveTargetSocket(allocator, uuid, name, socket_path);
    defer allocator.free(target_socket);

    var client = ipc.Client.connect(target_socket) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            cli_ui.printErr("pod is not running", .{});
            std.process.exit(1);
        }
        return err;
    };
    defer client.close();

    // Send versioned handshake for auxiliary input.
    wire.sendHandshake(client.fd, wire.POD_HANDSHAKE_AUX_INPUT) catch |err| {
        cli_ui.printErr("failed to handshake with pod: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    var conn = client.toConnection();
    try pod_protocol.writeFrame(&conn, .input, data_buf[0..data_len]);
}

fn resolveTargetSocket(allocator: std.mem.Allocator, uuid: []const u8, name: []const u8, socket_path: []const u8) ![]const u8 {
    return shared.resolvePodSocketTarget(allocator, uuid, name, socket_path) catch |err| {
        switch (err) {
            error.InvalidUuid => cli_ui.printErr("--uuid must be 32 hex chars", .{}),
            error.MissingTarget => cli_ui.printErr("must provide --socket, --uuid, or --name", .{}),
            // Pane names are unique per session, so one name can belong to
            // two panes in two sessions. Picking either could type into, or
            // signal, the wrong one.
            error.AmbiguousPodName => cli_ui.printErr("several pods are called that; use --uuid", .{}),
            else => {},
        }
        return err;
    };
}
