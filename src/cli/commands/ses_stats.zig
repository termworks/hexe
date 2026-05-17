const std = @import("std");
const core = @import("core");
const wire = core.wire;

const print = std.debug.print;

/// Show SES daemon resource statistics
pub fn run(allocator: std.mem.Allocator) !void {
    // Connect to SES
    const ses_path = try core.ipc.getSesSocketPath(allocator);
    defer allocator.free(ses_path);

    var client = core.ipc.Client.connect(ses_path) catch {
        print("Error: Could not connect to ses daemon\n", .{});
        print("Make sure the daemon is running with: hexe ses daemon\n", .{});
        return error.SesNotRunning;
    };
    defer client.close();

    const fd = client.fd;

    // Send versioned CLI handshake
    try wire.sendCliHandshake(fd);

    // Request status
    try wire.writeControl(fd, .status, &.{});

    // Read response
    const hdr = try wire.readControlHeader(fd);
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type != .status) {
        print("Error: Failed to retrieve status\n", .{});
        return error.StatusFailed;
    }
    if (hdr.payload_len > wire.MAX_PAYLOAD_LEN) {
        print("Error: status response too large\n", .{});
        return error.ResponseTooLarge;
    }

    const status_payload = try allocator.alloc(u8, hdr.payload_len);
    defer allocator.free(status_payload);
    try wire.readExact(fd, status_payload);

    // For now, show basic info from list operations
    // Request sessions list to count
    try wire.writeControl(fd, .list_sessions, &.{});
    const sessions_hdr = try wire.readControlHeader(fd);
    const sessions_msg_type: wire.MsgType = @enumFromInt(sessions_hdr.msg_type);

    if (sessions_msg_type != .sessions_list) {
        print("Error: Unexpected response\n", .{});
        return error.UnexpectedResponse;
    }
    if (sessions_hdr.payload_len > wire.MAX_PAYLOAD_LEN) {
        print("Error: sessions list response too large\n", .{});
        return error.ResponseTooLarge;
    }

    const payload = try allocator.alloc(u8, sessions_hdr.payload_len);
    defer allocator.free(payload);
    try wire.readExact(fd, payload);

    if (payload.len < @sizeOf(wire.SessionsList)) {
        print("Error: malformed sessions list response\n", .{});
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
            print("Error: malformed sessions list entry\n", .{});
            return error.MalformedResponse;
        }

        const entry_bytes = payload[off..][0..@sizeOf(wire.SessionEntry)];
        const entry = std.mem.bytesToValue(wire.SessionEntry, entry_bytes);
        off += @sizeOf(wire.SessionEntry);

        const name_end = off + entry.name_len;
        if (name_end > payload.len) {
            print("Error: malformed session name\n", .{});
            return error.MalformedResponse;
        }
        off = name_end;
        const base_root_end = off + entry.base_root_len;
        if (base_root_end > payload.len) {
            print("Error: malformed session base root\n", .{});
            return error.MalformedResponse;
        }
        off = base_root_end;

        session_count += 1;
        total_panes += entry.pane_count;
    }

    // Display resource statistics
    print("\n━━━ SES Daemon Resource Statistics ━━━\n\n", .{});

    print("📊 Sessions\n", .{});
    print("  Detached sessions:  {d}\n", .{session_count});
    print("  Total panes:        {d}\n\n", .{total_panes});

    // Load resource limits from env
    const limits = core.resource_limits.ResourceLimits.fromEnv();

    print("⚙️  Resource Limits\n", .{});
    print("  Max connections:    {d}\n", .{limits.max_connections});
    print("  Max sessions:       {d}\n", .{limits.max_sessions});
    print("  Max panes/session:  {d}\n", .{limits.max_panes_per_session});
    print("  Max memory/session: {d} MB\n", .{limits.max_memory_per_session_mb});
    print("  Max conn/minute:    {d}\n\n", .{limits.max_connections_per_minute});

    print("💡 Configuration\n", .{});
    print("  Set limits via environment variables:\n", .{});
    print("    HEXE_MAX_CONNECTIONS\n", .{});
    print("    HEXE_MAX_SESSIONS\n", .{});
    print("    HEXE_MAX_PANES_PER_SESSION\n", .{});
    print("    HEXE_MAX_MEMORY_PER_SESSION_MB\n", .{});
    print("    HEXE_MAX_CONNECTIONS_PER_MINUTE\n\n", .{});
}
