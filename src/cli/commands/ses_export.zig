const std = @import("std");
const core = @import("core");
const wire = core.wire;
const cli_ui = core.cli_ui;

/// Export a detached session to JSON
pub fn run(allocator: std.mem.Allocator, session_id: []const u8, output_path: []const u8) !void {
    // Connect to SES
    const ses_path = try core.ipc.getSesSocketPath(allocator);
    defer allocator.free(ses_path);

    var client = core.ipc.Client.connect(ses_path) catch {
        cli_ui.printErr("could not connect to ses daemon", .{});
        cli_ui.printErrHint("Start a session with: hexe new  (or: hexe ses daemon)", .{});
        return error.SesNotRunning;
    };
    defer client.close();

    const fd = client.fd;

    // Send versioned CLI handshake
    try wire.sendCliHandshake(fd);

    // Request list of detached sessions
    try wire.writeControl(fd, .list_sessions, &.{});

    // Read response
    const hdr = try wire.readControlHeader(fd);
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type != .sessions_list) {
        cli_ui.printErr("unexpected response from ses daemon", .{});
        return error.UnexpectedResponse;
    }
    if (hdr.payload_len > wire.MAX_PAYLOAD_LEN) {
        cli_ui.printErr("sessions list response too large", .{});
        return error.ResponseTooLarge;
    }

    const payload = try allocator.alloc(u8, hdr.payload_len);
    defer allocator.free(payload);
    try wire.readExact(fd, payload);

    // Parse detached sessions list
    var off: usize = 0;
    var found = false;
    var target_session_id: [32]u8 = undefined;

    if (payload.len < @sizeOf(wire.SessionsList)) {
        cli_ui.printErr("malformed sessions list response", .{});
        return error.MalformedResponse;
    }

    const list_hdr = std.mem.bytesToValue(wire.SessionsList, payload[0..@sizeOf(wire.SessionsList)]);
    off = @sizeOf(wire.SessionsList);

    var i: u16 = 0;
    while (i < list_hdr.session_count) : (i += 1) {
        if (off + @sizeOf(wire.SessionEntry) > payload.len) {
            cli_ui.printErr("malformed sessions list entry", .{});
            return error.MalformedResponse;
        }

        const entry_bytes = payload[off..][0..@sizeOf(wire.SessionEntry)];
        const entry = std.mem.bytesToValue(wire.SessionEntry, entry_bytes);
        off += @sizeOf(wire.SessionEntry);

        const name_end = off + entry.name_len;
        if (name_end > payload.len) {
            cli_ui.printErr("malformed session name", .{});
            return error.MalformedResponse;
        }
        const name = payload[off..name_end];
        off = name_end;
        const base_root_end = off + entry.base_root_len;
        if (base_root_end > payload.len) {
            cli_ui.printErr("malformed session base root", .{});
            return error.MalformedResponse;
        }
        off = base_root_end;

        // Check if this matches the requested session (by name or ID prefix)
        if (std.mem.eql(u8, name, session_id) or
            std.mem.startsWith(u8, entry.session_id[0..], session_id) or
            std.ascii.eqlIgnoreCase(name, session_id))
        {
            target_session_id = entry.session_id;
            found = true;
            break;
        }
    }

    if (!found) {
        cli_ui.printErr("session '{s}' not found", .{session_id});
        cli_ui.printErrHint("List sessions with: hexe ls", .{});
        return error.SessionNotFound;
    }

    // Request full session state
    try wire.writeControl(fd, .get_session_state, std.mem.asBytes(&target_session_id));

    // Read session state response
    const state_hdr = try wire.readControlHeader(fd);
    const state_msg_type: wire.MsgType = @enumFromInt(state_hdr.msg_type);
    if (state_msg_type != .session_state) {
        cli_ui.printErr("failed to retrieve session state", .{});
        return error.StateRetrievalFailed;
    }
    if (state_hdr.payload_len > wire.MAX_PAYLOAD_LEN) {
        cli_ui.printErr("session state response too large", .{});
        return error.ResponseTooLarge;
    }

    const state_payload = try allocator.alloc(u8, state_hdr.payload_len);
    defer allocator.free(state_payload);
    try wire.readExact(fd, state_payload);

    // Write to file or stdout
    if (output_path.len > 0) {
        const file = try std.fs.cwd().createFile(output_path, .{ .mode = 0o600 });
        defer file.close();
        try file.writeAll(state_payload);
        var out = std.fs.File.stdout().deprecatedWriter();
        const p = cli_ui.Palette.forStdout();
        try out.print("{s}✓{s} Session exported to: {s}{s}{s}\n", .{ p.success, p.reset, p.bold, output_path, p.reset });
    } else {
        const stdout = std.fs.File.stdout();
        try stdout.writeAll(state_payload);
    }
}
