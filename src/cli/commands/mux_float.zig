const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const wire = core.wire;

const print = std.debug.print;

pub fn runMuxFloat(
    allocator: std.mem.Allocator,
    command: []const u8,
    title: []const u8,
    cwd: []const u8,
    result_file: []const u8,
    pass_env: bool,
    extra_env: []const u8,
    isolated: bool,
    isolation_profile: []const u8,
    size: []const u8,
    exit_key: []const u8,
) !void {
    if (command.len == 0) {
        print("Error: --command is required\n", .{});
        return;
    }

    if (isolation_profile.len > 0) {
        const valid = std.mem.eql(u8, isolation_profile, "none") or
            std.mem.eql(u8, isolation_profile, "minimal") or
            std.mem.eql(u8, isolation_profile, "default") or
            std.mem.eql(u8, isolation_profile, "balanced") or
            std.mem.eql(u8, isolation_profile, "sandbox") or
            std.mem.eql(u8, isolation_profile, "full");
        if (!valid) {
            print("Error: invalid --isolation profile '{s}' (use: none|minimal|default|balanced|sandbox|full)\n", .{isolation_profile});
            return;
        }
    }

    const posix = std.posix;

    // Parse size parameter (format: width,height,shift_x,shift_y)
    var size_width: u16 = 0;
    var size_height: u16 = 0;
    var shift_x: i16 = 0;
    var shift_y: i16 = 0;

    if (size.len > 0) {
        var it = std.mem.splitScalar(u8, size, ',');
        var idx: usize = 0;
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " ");
            if (trimmed.len == 0) {
                idx += 1;
                continue;
            }
            switch (idx) {
                0 => size_width = std.fmt.parseInt(u16, trimmed, 10) catch 0,
                1 => size_height = std.fmt.parseInt(u16, trimmed, 10) catch 0,
                2 => shift_x = std.fmt.parseInt(i16, trimmed, 10) catch 0,
                3 => shift_y = std.fmt.parseInt(i16, trimmed, 10) catch 0,
                else => break,
            }
            idx += 1;
        }
    }

    // Collect env entries.
    var env_list: std.ArrayList([]const u8) = .empty;
    defer env_list.deinit(allocator);

    if (pass_env) {
        var env_map = std.process.getEnvMap(allocator) catch std.process.EnvMap.init(allocator);
        defer env_map.deinit();
        var it = env_map.iterator();
        while (it.next()) |entry| {
            const line = std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* }) catch continue;
            env_list.append(allocator, line) catch {
                allocator.free(line);
                continue;
            };
        }
    }

    // Parse extra_env (comma-separated KEY=VALUE pairs).
    if (extra_env.len > 0) {
        var it = std.mem.splitScalar(u8, extra_env, ',');
        while (it.next()) |item| {
            const trimmed = std.mem.trim(u8, item, " ");
            if (trimmed.len == 0) continue;
            env_list.append(allocator, trimmed) catch continue;
        }
    }

    // Connect to SES.
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

    // Send versioned CLI handshake.
    wire.sendCliHandshake(fd) catch |err| {
        print("Error: failed to handshake with ses: {s}\n", .{@errorName(err)});
        return;
    };

    // Determine result path for wait_for_exit.
    var owned_result_path: ?[]u8 = null;
    defer if (owned_result_path) |p| allocator.free(p);
    const actual_result_path: []const u8 = if (result_file.len > 0)
        result_file
    else blk: {
        const tmp_uuid = ipc.generateUuid();
        const socket_dir = ipc.getSocketDir(allocator) catch break :blk "";
        defer allocator.free(socket_dir);
        owned_result_path = std.fmt.allocPrint(allocator, "{s}/float-{s}.result", .{ socket_dir, tmp_uuid }) catch break :blk "";
        break :blk owned_result_path.?;
    };

    // Get source session ID from environment (if running inside a mux pane).
    var source_session_id: [32]u8 = .{0} ** 32;
    if (std.posix.getenv("HEXE_SESSION")) |sid| {
        if (sid.len == 32) {
            @memcpy(&source_session_id, sid);
        }
    }

    // Build FloatRequest.
    const flags: u8 = 1 | // wait_for_exit always true for CLI
        (if (isolated) @as(u8, 2) else 0);
    const req = wire.FloatRequest{
        .flags = flags,
        .cmd_len = @intCast(command.len),
        .title_len = @intCast(title.len),
        .cwd_len = @intCast(cwd.len),
        .result_path_len = @intCast(actual_result_path.len),
        .exit_key_len = @intCast(@min(exit_key.len, 255)),
        .isolation_profile_len = @intCast(@min(isolation_profile.len, 255)),
        .env_count = @intCast(env_list.items.len),
        .size_width = size_width,
        .size_height = size_height,
        .shift_x = shift_x,
        .shift_y = shift_y,
        .source_session_id = source_session_id,
    };

    // Build trailing data: cmd + title + cwd + result_path + exit_key + isolation_profile + env entries (each: u16 len + bytes).
    var trail: std.ArrayList(u8) = .empty;
    defer trail.deinit(allocator);
    var tw = trail.writer(allocator);
    try tw.writeAll(command);
    try tw.writeAll(title);
    try tw.writeAll(cwd);
    try tw.writeAll(actual_result_path);
    try tw.writeAll(exit_key);
    try tw.writeAll(isolation_profile);
    for (env_list.items) |entry| {
        const entry_len: u16 = @intCast(entry.len);
        try tw.writeAll(std.mem.asBytes(&entry_len));
        try tw.writeAll(entry);
    }

    // Send the float_request message.
    wire.writeControlWithTrail(fd, .float_request, std.mem.asBytes(&req), trail.items) catch |err| {
        print("Error: failed to send float request: {s}\n", .{@errorName(err)});
        return;
    };

    // Wait for response (FloatCreated for immediate, FloatResult for wait).
    const hdr = wire.readControlHeader(fd) catch {
        print("No response from ses\n", .{});
        return;
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);

    switch (msg_type) {
        .float_result => {
            const result = wire.readStruct(wire.FloatResult, fd) catch {
                print("Error reading float result\n", .{});
                return;
            };
            const exit_code: u8 = if (result.exit_code >= 0) @intCast(@min(result.exit_code, 255)) else 1;
            // Read output if any (but skip output if exit key was pressed - code 130)
            if (result.output_len > 0) {
                const output = allocator.alloc(u8, result.output_len) catch {
                    print("Error allocating output buffer\n", .{});
                    return;
                };
                defer allocator.free(output);
                wire.readExact(fd, output) catch {
                    print("Error reading output\n", .{});
                    return;
                };
                // Only output if not cancelled via exit key (130 = exit key pressed)
                if (output.len > 0 and exit_code != 130) {
                    _ = posix.write(posix.STDOUT_FILENO, output) catch |err| {
                        core.logging.logError("mux_float", "failed to write float output", err);
                    };
                    _ = posix.write(posix.STDOUT_FILENO, "\n") catch |err| {
                        core.logging.logError("mux_float", "failed to write float output newline", err);
                    };
                }
            }
            std.process.exit(exit_code);
        },
        .@"error" => {
            // Read error message.
            if (hdr.payload_len > 0 and hdr.payload_len <= 1024) {
                var err_buf: [1024]u8 = undefined;
                wire.readExact(fd, err_buf[0..hdr.payload_len]) catch |err| {
                    print("Error reading float error response: {s}\n", .{@errorName(err)});
                    return;
                };
                print("Error: {s}\n", .{err_buf[0..hdr.payload_len]});
            } else {
                print("Error from ses\n", .{});
            }
            return;
        },
        else => {
            print("Unexpected response from ses\n", .{});
            return;
        },
    }
}
