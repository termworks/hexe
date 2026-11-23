const std = @import("std");
const core = @import("core");
const wire = core.wire;
const cli_ui = core.cli_ui;

/// Show SES daemon resource statistics
pub fn run(allocator: std.mem.Allocator) !void {
    // Connect to SES
    const ses_path = try core.ipc.getSesSocketPath(allocator);
    defer allocator.free(ses_path);

    var client = core.ipc.Client.connect(ses_path) catch {
        cli_ui.printErr("could not connect to ses daemon", .{});
        cli_ui.printErrHint("Start a session with: hexe new  (or: hexe ses daemon)", .{});
        return error.SesNotRunning;
    };
    const fd = client.fd;

    // Send versioned CLI handshake
    try wire.sendCliHandshake(fd);

    // Request status
    try wire.writeControl(fd, .status, &.{});

    // Read response
    const hdr = try wire.readControlHeader(fd);
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type != .status) {
        cli_ui.printErr("failed to retrieve status", .{});
        return error.StatusFailed;
    }
    if (hdr.payload_len > wire.MAX_PAYLOAD_LEN) {
        cli_ui.printErr("status response too large", .{});
        return error.ResponseTooLarge;
    }

    const status_payload = try allocator.alloc(u8, hdr.payload_len);
    defer allocator.free(status_payload);
    try wire.readExact(fd, status_payload);

    // Second request, second connection: the CLI request channel serves one
    // message per accept, so reusing `fd` here read EOF and the command exited
    // non-zero with nothing printed.
    client.close();
    var list_client = core.ipc.Client.connect(ses_path) catch {
        cli_ui.printErr("could not reconnect to ses daemon", .{});
        return error.SesNotRunning;
    };
    defer list_client.close();
    const list_fd = list_client.fd;
    try wire.sendCliHandshake(list_fd);

    try wire.writeControl(list_fd, .list_sessions, &.{});
    const sessions_hdr = try wire.readControlHeader(list_fd);
    const sessions_msg_type: wire.MsgType = @enumFromInt(sessions_hdr.msg_type);

    if (sessions_msg_type != .sessions_list) {
        cli_ui.printErr("unexpected response", .{});
        return error.UnexpectedResponse;
    }
    if (sessions_hdr.payload_len > wire.MAX_PAYLOAD_LEN) {
        cli_ui.printErr("sessions list response too large", .{});
        return error.ResponseTooLarge;
    }

    const payload = try allocator.alloc(u8, sessions_hdr.payload_len);
    defer allocator.free(payload);
    try wire.readExact(list_fd, payload);

    if (payload.len < @sizeOf(wire.SessionsList)) {
        cli_ui.printErr("malformed sessions list response", .{});
        return error.MalformedResponse;
    }

    const list_hdr = std.mem.bytesToValue(wire.SessionsList, payload[0..@sizeOf(wire.SessionsList)]);

    // Count sessions
    var session_count: usize = 0;
    var total_panes: usize = 0;
    var off: usize = @sizeOf(wire.SessionsList);

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
        off = name_end;
        const base_root_end = off + entry.base_root_len;
        if (base_root_end > payload.len) {
            cli_ui.printErr("malformed session base root", .{});
            return error.MalformedResponse;
        }
        off = base_root_end;

        session_count += 1;
        total_panes += entry.pane_count;
    }

    var out = std.fs.File.stdout().deprecatedWriter();
    const p = core.cli_ui.Palette.forStdout();

    try out.print("{s}SES Daemon Statistics{s}\n\n", .{ p.bold, p.reset });

    try out.print("{s}Sessions{s}\n", .{ p.accent, p.reset });
    try out.print("  {s}Total sessions:{s}     {d}\n", .{ p.dim, p.reset, session_count });
    try out.print("  {s}Total panes:{s}        {d}\n\n", .{ p.dim, p.reset, total_panes });

    const limits = core.resource_limits.ResourceLimits.fromEnv();

    try out.print("{s}Resource Limits{s}\n", .{ p.accent, p.reset });
    try out.print("  {s}Max connections:{s}    {d}\n", .{ p.dim, p.reset, limits.max_connections });
    try out.print("  {s}Max sessions:{s}       {d}\n", .{ p.dim, p.reset, limits.max_sessions });
    try out.print("  {s}Max panes/session:{s}  {d}\n", .{ p.dim, p.reset, limits.max_panes_per_session });
    try out.print("  {s}Max memory/session:{s} {d} MB\n", .{ p.dim, p.reset, limits.max_memory_per_session_mb });
    try out.print("  {s}Max conn/minute:{s}    {d}\n\n", .{ p.dim, p.reset, limits.max_connections_per_minute });

    try out.print("{s}Environment overrides:{s} HEXE_MAX_CONNECTIONS, HEXE_MAX_SESSIONS, HEXE_MAX_PANES_PER_SESSION, HEXE_MAX_MEMORY_PER_SESSION_MB, HEXE_MAX_CONNECTIONS_PER_MINUTE\n", .{ p.dim, p.reset });
}
