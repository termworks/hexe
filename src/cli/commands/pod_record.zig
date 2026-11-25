const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const wire = core.wire;
const pod_protocol = core.pod_protocol;
const AsciicastWriter = core.recording.asciicast.AsciicastWriter;
const shared = @import("shared.zig");
const cli_ui = core.cli_ui;

const RecordContext = struct {
    writer: *AsciicastWriter,
    capture_input: bool,
    password_mode: bool = false,
    failed: ?anyerror = null,
};

pub fn runPodRecord(
    allocator: std.mem.Allocator,
    uuid: []const u8,
    name: []const u8,
    socket_path: []const u8,
    out_path: []const u8,
    capture_input: bool,
) !void {
    if (out_path.len == 0) {
        cli_ui.printErr("--out is required", .{});
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

    wire.sendHandshake(client.fd, wire.POD_HANDSHAKE_AUX_OBSERVER) catch |err| {
        cli_ui.printErr("failed to handshake with pod: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    const conn = client.toConnection();

    const width = parseEnvU16("COLUMNS", 80);
    const height = parseEnvU16("LINES", 24);

    var writer = try AsciicastWriter.init(out_path, .{
        .width = width,
        .height = height,
        .title = "hexe pod record",
        .command = "hexe pod record",
    });
    defer {
        writer.flush() catch |err| {
            core.logging.logError("pod_record", "failed to flush recording", err);
        };
        writer.deinit();
    }

    var reader = try pod_protocol.Reader.init(allocator, pod_protocol.MAX_FRAME_LEN);
    defer reader.deinit(allocator);

    var ctx = RecordContext{ .writer = &writer, .capture_input = capture_input };

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(conn.fd, &buf) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) break;
        reader.feed(buf[0..n], @ptrCast(&ctx), podFrameCallback);
        if (ctx.failed) |err| return err;
    }
}

fn podFrameCallback(ctx_ptr: *anyopaque, frame: pod_protocol.Frame) void {
    const ctx: *RecordContext = @ptrCast(@alignCast(ctx_ptr));
    switch (frame.frame_type) {
        .output => {
            ctx.writer.writeOutput(frame.payload) catch |err| {
                ctx.failed = err;
            };
        },
        .input => {
            if (ctx.capture_input and !ctx.password_mode) {
                ctx.writer.writeInput(frame.payload) catch |err| {
                    ctx.failed = err;
                };
            }
        },
        .password_mode => {
            if (frame.payload.len >= 1) ctx.password_mode = frame.payload[0] != 0;
        },
        .refused => {
            const msg = if (frame.payload.len > 0) frame.payload else "pod refused observer connection";
            core.cli_ui.printErr("{s}", .{msg});
            ctx.failed = error.ConnectionRefused;
        },
        else => {},
    }
}

fn parseEnvU16(name: []const u8, default: u16) u16 {
    const s = std.posix.getenv(name) orelse return default;
    return std.fmt.parseInt(u16, s, 10) catch default;
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
