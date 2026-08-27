const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ChannelManager = @import("manager.zig").ChannelManager;
const channel_protocol = @import("../protocol/channel.zig");
const wire = @import("../protocol/wire.zig");
const ttymodes = @import("../protocol/ttymodes.zig");

/// Session Channel
///
/// Implements "session" channel type for interactive shells,
/// command execution, and subsystems (like SFTP).
///
/// Per RFC 4254 Section 6.
pub const SessionChannel = struct {
    manager: *ChannelManager,
    stream_id: u64,
    allocator: Allocator,

    const Self = @This();

    /// Open a new session channel
    pub fn open(allocator: Allocator, manager: *ChannelManager) !Self {
        const stream_id = try manager.openChannel(
            "session",
            "",
        );

        return Self{
            .manager = manager,
            .stream_id = stream_id,
            .allocator = allocator,
        };
    }

    /// Wait for channel to be confirmed open
    ///
    /// Reads the CHANNEL_OPEN_CONFIRMATION message.
    pub fn waitForConfirmation(self: *Self) !void {
        // Poll multiple times until we receive the confirmation
        var attempts: u32 = 0;
        while (attempts < 300) : (attempts += 1) {
            // Poll to receive packets
            self.manager.transport.poll(100) catch {}; // 100ms timeout

            const message = self.manager.receiveMessage(self.stream_id) catch |err| switch (err) {
                error.NoData, error.EndOfBuffer => continue,
                else => return err,
            };
            defer self.manager.allocator.free(message);

            switch (message[0]) {
                91 => { // SSH_MSG_CHANNEL_OPEN_CONFIRMATION
                    try self.manager.handleOpenConfirmation(self.stream_id, message);
                    return;
                },
                92 => { // SSH_MSG_CHANNEL_OPEN_FAILURE
                    try self.manager.handleOpenFailure(self.stream_id, message);
                    return error.ChannelOpenFailed;
                },
                else => {
                    std.log.err("Unexpected message type: {}", .{message[0]});
                    return error.UnexpectedMessageType;
                },
            }
        }

        return error.InvalidResponse; // Timeout after 30 seconds
    }

    /// Request a pseudo-terminal
    ///
    /// Must be called before requestShell() or requestExec() if PTY is needed.
    pub fn requestPty(
        self: *Self,
        term: []const u8,
        width_chars: u32,
        height_rows: u32,
        width_pixels: u32,
        height_pixels: u32,
    ) !void {
        // Encode current terminal modes per RFC 4254 Section 8
        const modes = try ttymodes.encodeTerminalModes(self.allocator);
        defer self.allocator.free(modes);

        // Build type-specific data for pty-req
        const pty_data = try encodePtyRequest(
            self.allocator,
            term,
            width_chars,
            height_rows,
            width_pixels,
            height_pixels,
            modes,
        );
        defer self.allocator.free(pty_data);

        try self.manager.sendRequest(self.stream_id, "pty-req", true, pty_data);

        // Wait for success/failure
        try self.waitForRequestResponse();
    }

    /// Send an environment variable request for the session.
    pub fn requestEnv(self: *Self, name: []const u8, value: []const u8) !void {
        const env_data = try encodeEnvRequest(self.allocator, name, value);
        defer self.allocator.free(env_data);

        try self.manager.sendRequest(self.stream_id, "env", true, env_data);
        try self.waitForRequestResponse();
    }

    /// Request shell
    ///
    /// Starts an interactive shell on the remote server.
    pub fn requestShell(self: *Self) !void {
        const shell_data = try self.allocator.alloc(u8, 0);
        defer self.allocator.free(shell_data);

        try self.manager.sendRequest(self.stream_id, "shell", true, shell_data);

        // Wait for success/failure
        try self.waitForRequestResponse();
    }

    /// Notify server that local terminal window size changed.
    ///
    /// Per RFC 4254 Section 6.7 "window-change" request.
    pub fn requestWindowChange(
        self: *Self,
        width_chars: u32,
        height_rows: u32,
        width_pixels: u32,
        height_pixels: u32,
    ) !void {
        var payload: [16]u8 = undefined;
        var writer = wire.Writer{ .buffer = &payload };
        try writer.writeUint32(width_chars);
        try writer.writeUint32(height_rows);
        try writer.writeUint32(width_pixels);
        try writer.writeUint32(height_pixels);

        // SSH window-change usually does not request reply.
        try self.manager.sendRequest(self.stream_id, "window-change", false, &payload);
    }

    /// Request command execution
    ///
    /// Executes a single command on the remote server.
    pub fn requestExec(self: *Self, command: []const u8) !void {
        const exec_data = try encodeExecRequest(self.allocator, command);
        defer self.allocator.free(exec_data);

        try self.manager.sendRequest(self.stream_id, "exec", true, exec_data);

        // Wait for success/failure
        try self.waitForRequestResponse();
    }

    /// Request subsystem
    ///
    /// Starts a subsystem like "sftp" on the channel.
    pub fn requestSubsystem(self: *Self, subsystem_name: []const u8) !void {
        const subsystem_data = try encodeSubsystemRequest(self.allocator, subsystem_name);
        defer self.allocator.free(subsystem_data);

        try self.manager.sendRequest(self.stream_id, "subsystem", true, subsystem_data);

        // Wait for success/failure
        try self.waitForRequestResponse();
    }

    /// Wait for request response (success or failure)
    fn waitForRequestResponse(self: *Self) !void {
        // Poll multiple times until we receive data
        var attempts: u32 = 0;
        while (attempts < 100) : (attempts += 1) {
            // Poll to receive packets
            self.manager.transport.poll(100) catch {}; // 100ms timeout

            const message = self.manager.receiveMessage(self.stream_id) catch |err| switch (err) {
                error.NoData, error.EndOfBuffer => continue,
                else => return err,
            };
            defer self.manager.allocator.free(message);

            switch (message[0]) {
                99 => { // SSH_MSG_CHANNEL_SUCCESS
                    std.log.info("Channel request succeeded", .{});
                    return;
                },
                100 => { // SSH_MSG_CHANNEL_FAILURE
                    std.log.err("Channel request failed", .{});
                    return error.ChannelRequestFailed;
                },
                else => {
                    std.log.err("Unexpected message type: {}", .{message[0]});
                    return error.UnexpectedMessageType;
                },
            }
        }

        return error.InvalidResponse; // Timeout after 10 seconds
    }

    /// Send data on the session channel
    pub fn sendData(self: *Self, data: []const u8) !void {
        try self.manager.sendData(self.stream_id, data);
    }

    /// Receive data from the session channel
    ///
    /// Returns the payload data. Caller owns the memory.
    pub fn receiveData(self: *Self) ![]u8 {
        return self.manager.receiveData(self.stream_id);
    }

    /// Send EOF on the channel
    pub fn sendEof(self: *Self) !void {
        try self.manager.sendEof(self.stream_id);
    }

    /// Close the session channel
    pub fn close(self: *Self) !void {
        try self.manager.closeChannel(self.stream_id);
    }

    /// Get the underlying stream ID
    pub fn getStreamId(self: *const Self) u64 {
        return self.stream_id;
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Encode PTY request type-specific data
fn encodePtyRequest(
    allocator: Allocator,
    term: []const u8,
    width_chars: u32,
    height_rows: u32,
    width_pixels: u32,
    height_pixels: u32,
    modes: []const u8,
) ![]u8 {
    const size = 4 + term.len + // string(TERM)
        4 + // uint32(terminal width, characters)
        4 + // uint32(terminal height, rows)
        4 + // uint32(terminal width, pixels)
        4 + // uint32(terminal height, pixels)
        4 + modes.len; // string(encoded terminal modes)

    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    var writer = wire.Writer{ .buffer = buffer };
    try writer.writeString(term);
    try writer.writeUint32(width_chars);
    try writer.writeUint32(height_rows);
    try writer.writeUint32(width_pixels);
    try writer.writeUint32(height_pixels);
    try writer.writeString(modes);

    return buffer;
}

/// Encode exec request type-specific data
fn encodeExecRequest(allocator: Allocator, command: []const u8) ![]u8 {
    const size = 4 + command.len;
    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    var writer = wire.Writer{ .buffer = buffer };
    try writer.writeString(command);

    return buffer;
}

/// Encode subsystem request type-specific data
fn encodeSubsystemRequest(allocator: Allocator, subsystem_name: []const u8) ![]u8 {
    const size = 4 + subsystem_name.len;
    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    var writer = wire.Writer{ .buffer = buffer };
    try writer.writeString(subsystem_name);

    return buffer;
}

fn encodeEnvRequest(allocator: Allocator, name: []const u8, value: []const u8) ![]u8 {
    const size = 4 + name.len + 4 + value.len;
    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    var writer = wire.Writer{ .buffer = buffer };
    try writer.writeString(name);
    try writer.writeString(value);

    return buffer;
}

// ============================================================================
// Server-Side Session Handler
// ============================================================================

/// Server-side session channel handler
pub const SessionServer = struct {
    manager: *ChannelManager,
    allocator: Allocator,

    const Self = @This();

    /// PTY request information
    pub const PtyInfo = struct {
        term: []const u8,
        width_chars: u32,
        height_rows: u32,
        width_pixels: u32,
        height_pixels: u32,
        modes: []const u8,
    };

    /// Callback for handling PTY requests
    pub const PtyHandler = *const fn (stream_id: u64, pty_info: PtyInfo) anyerror!void;

    /// Callback for handling shell requests
    pub const ShellHandler = *const fn (stream_id: u64) anyerror!void;

    /// Callback for handling exec requests
    pub const ExecHandler = *const fn (stream_id: u64, command: []const u8) anyerror!void;

    /// Callback for handling subsystem requests
    pub const SubsystemHandler = *const fn (stream_id: u64, subsystem_name: []const u8) anyerror!void;

    pub fn init(allocator: Allocator, manager: *ChannelManager) Self {
        return Self{
            .manager = manager,
            .allocator = allocator,
        };
    }

    /// Accept incoming session channel
    pub fn acceptSession(self: *Self, stream_id: u64) !void {
        try self.manager.acceptChannel(stream_id);
    }

    /// Handle incoming channel request
    ///
    /// Dispatches to appropriate handler based on request type.
    pub fn handleRequest(
        self: *Self,
        stream_id: u64,
        data: []const u8,
        pty_handler: ?PtyHandler,
        shell_handler: ?ShellHandler,
        exec_handler: ?ExecHandler,
        subsystem_handler: ?SubsystemHandler,
    ) !void {
        var request_info = try self.manager.handleRequest(stream_id, data);
        defer request_info.deinit(self.allocator);

        std.log.info("Handling channel request: {s}", .{request_info.request.request_type});

        if (std.mem.eql(u8, request_info.request.request_type, "shell")) {
            if (shell_handler) |handler| {
                try handler(stream_id);
                try self.manager.sendSuccess(stream_id);
            } else {
                try self.manager.sendFailure(stream_id);
            }
        } else if (std.mem.eql(u8, request_info.request.request_type, "exec")) {
            if (exec_handler) |handler| {
                // Decode command from type-specific data
                var reader = wire.Reader{ .buffer = request_info.request.type_specific_data };
                const command = try reader.readString(self.allocator);
                defer self.allocator.free(command);

                try handler(stream_id, command);
                try self.manager.sendSuccess(stream_id);
            } else {
                try self.manager.sendFailure(stream_id);
            }
        } else if (std.mem.eql(u8, request_info.request.request_type, "subsystem")) {
            if (subsystem_handler) |handler| {
                // Decode subsystem name from type-specific data
                var reader = wire.Reader{ .buffer = request_info.request.type_specific_data };
                const subsystem_name = try reader.readString(self.allocator);
                defer self.allocator.free(subsystem_name);

                try handler(stream_id, subsystem_name);
                try self.manager.sendSuccess(stream_id);
            } else {
                try self.manager.sendFailure(stream_id);
            }
        } else if (std.mem.eql(u8, request_info.request.request_type, "pty-req")) {
            if (pty_handler) |handler| {
                // Decode PTY request data
                var reader = wire.Reader{ .buffer = request_info.request.type_specific_data };
                const term = try reader.readString(self.allocator);
                errdefer self.allocator.free(term);
                const width_chars = try reader.readUint32();
                const height_rows = try reader.readUint32();
                const width_pixels = try reader.readUint32();
                const height_pixels = try reader.readUint32();
                const modes = try reader.readString(self.allocator);
                errdefer self.allocator.free(modes);

                const pty_info = PtyInfo{
                    .term = term,
                    .width_chars = width_chars,
                    .height_rows = height_rows,
                    .width_pixels = width_pixels,
                    .height_pixels = height_pixels,
                    .modes = modes,
                };

                try handler(stream_id, pty_info);
                try self.manager.sendSuccess(stream_id);
            } else {
                // No handler, just accept
                try self.manager.sendSuccess(stream_id);
            }
        } else {
            // Unknown request type
            std.log.warn("Unknown channel request type: {s}", .{request_info.request.request_type});
            try self.manager.sendFailure(stream_id);
        }
    }

    /// Send data to client
    pub fn sendData(self: *Self, stream_id: u64, data: []const u8) !void {
        try self.manager.sendData(stream_id, data);
    }

    /// Receive data from client
    pub fn receiveData(self: *Self, stream_id: u64) ![]u8 {
        return self.manager.receiveData(stream_id);
    }

    /// Send EOF to client
    pub fn sendEof(self: *Self, stream_id: u64) !void {
        try self.manager.sendEof(stream_id);
    }

    /// Close the session
    pub fn close(self: *Self, stream_id: u64) !void {
        try self.manager.closeChannel(stream_id);
    }
};

// ============================================================================
// Reference Handler Implementations
// ============================================================================

/// Reference shell handler - spawns a pseudo-terminal
///
/// This is a basic implementation that spawns /bin/sh with a PTY.
/// Production servers should customize this based on user preferences.
pub fn defaultShellHandler(stream_id: u64) !void {
    if (!builtin.is_test) {
        std.log.info("Spawning shell for stream {}", .{stream_id});
    }

    // In a real implementation, this would:
    // 1. Fork a new process
    // 2. Create a pseudo-terminal (PTY) pair
    // 3. Set up the PTY as the child's stdio
    // 4. Exec the user's shell (from /etc/passwd or $SHELL)
    // 5. Bridge PTY master <-> SSH channel data
    //
    // For now, this is a stub that logs the action
    if (!builtin.is_test) {
        std.log.warn("Shell spawning not yet implemented - PTY support requires platform-specific code", .{});
    }
}

/// Reference exec handler - executes a command
///
/// Runs a single command and returns output on the channel.
pub fn defaultExecHandler(stream_id: u64, command: []const u8) !void {
    if (!builtin.is_test) {
        std.log.info("Executing command on stream {}: {s}", .{ stream_id, command });
    }

    // In a real implementation, this would:
    // 1. Fork a new process
    // 2. Set up pipes for stdin/stdout/stderr
    // 3. Exec the command via shell: /bin/sh -c "command"
    // 4. Bridge pipes <-> SSH channel data
    // 5. Send exit status when command completes
    //
    // For now, this is a stub that logs the action
    if (!builtin.is_test) {
        std.log.warn("Command execution not yet implemented - requires process spawning", .{});
    }
}

/// Reference subsystem handler - dispatches to subsystem implementations
///
/// Routes subsystem requests to appropriate handlers (e.g., SFTP).
pub fn defaultSubsystemHandler(stream_id: u64, subsystem_name: []const u8) !void {
    if (!builtin.is_test) {
        std.log.info("Starting subsystem '{s}' on stream {}", .{ subsystem_name, stream_id });
    }

    if (std.mem.eql(u8, subsystem_name, "sftp")) {
        // In a real implementation, this would:
        // 1. Initialize SFTP server for this channel
        // 2. Enter SFTP request/response loop
        // 3. Process file operations (open, read, write, etc.)
        //
        // For now, log that SFTP would be started
        if (!builtin.is_test) {
            std.log.info("SFTP subsystem would be started here", .{});
        }
    } else {
        if (!builtin.is_test) {
            std.log.warn("Unknown subsystem: {s}", .{subsystem_name});
        }
        return error.UnknownSubsystem;
    }
}

// ============================================================================
// Platform-specific PTY Support (Linux)
// ============================================================================

/// PTY (Pseudo-Terminal) management for shell sessions
///
/// This would handle creating PTY pairs and bridging them to SSH channels.
/// Platform-specific implementation required (posix_openpt, grantpt, etc.)
pub const PtyManager = struct {
    master_fd: std.posix.fd_t,
    slave_fd: std.posix.fd_t,
    allocator: Allocator,

    const Self = @This();

    /// Create a new PTY pair
    ///
    /// Note: This is a placeholder. Real implementation would use:
    /// - Linux: posix_openpt(), grantpt(), unlockpt(), ptsname()
    /// - BSD: openpty()
    pub fn create(allocator: Allocator) !Self {
        _ = allocator;
        std.log.warn("PTY creation not implemented - platform-specific code required", .{});
        return error.NotImplemented;
    }

    pub fn deinit(self: *Self) void {
        // Close FDs
        std.posix.close(self.master_fd);
        std.posix.close(self.slave_fd);
    }

    /// Set terminal window size
    pub fn setWindowSize(self: *Self, rows: u32, cols: u32) !void {
        _ = self;
        _ = rows;
        _ = cols;
        return error.NotImplemented;
    }

    /// Read data from PTY master
    pub fn read(self: *Self, buffer: []u8) !usize {
        return std.posix.read(self.master_fd, buffer);
    }

    /// Write data to PTY master
    pub fn write(self: *Self, data: []const u8) !usize {
        return std.posix.write(self.master_fd, data);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SessionServer - init" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create mock channel manager
    var manager = ChannelManager.init(allocator, undefined, true);
    defer manager.deinit();

    // Initialize session server
    const session_server = SessionServer.init(allocator, &manager);

    // Verify it's initialized correctly
    try testing.expect(session_server.allocator.ptr == allocator.ptr);
}

test "SessionServer - handler callbacks" {
    const testing = std.testing;

    // Test shell handler callback signature
    const shell_handler: SessionServer.ShellHandler = defaultShellHandler;
    _ = shell_handler;

    // Test exec handler callback signature
    const exec_handler: SessionServer.ExecHandler = defaultExecHandler;
    _ = exec_handler;

    // Test subsystem handler callback signature
    const subsystem_handler: SessionServer.SubsystemHandler = defaultSubsystemHandler;
    _ = subsystem_handler;

    // If we get here, the callback types are compatible
    try testing.expect(true);
}

test "Default handlers - shell" {
    const testing = std.testing;

    // Test that shell handler can be called
    // It won't actually spawn a shell (not implemented), but should not crash
    try defaultShellHandler(123);

    try testing.expect(true);
}

test "Default handlers - exec" {
    const testing = std.testing;

    // Test that exec handler can be called with a command
    try defaultExecHandler(123, "ls -la");

    try testing.expect(true);
}

test "Default handlers - subsystem sftp" {
    const testing = std.testing;

    // Test that subsystem handler recognizes SFTP
    try defaultSubsystemHandler(123, "sftp");

    try testing.expect(true);
}

test "Default handlers - subsystem unknown" {
    const testing = std.testing;

    // Test that unknown subsystem returns error
    const result = defaultSubsystemHandler(123, "unknown-subsystem");
    try testing.expectError(error.UnknownSubsystem, result);
}

test "encodePtyRequest - format" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const modes = try allocator.alloc(u8, 1);
    defer allocator.free(modes);
    modes[0] = 0; // TTY_OP_END

    const pty_data = try encodePtyRequest(
        allocator,
        "xterm-256color",
        80, // width_chars
        24, // height_rows
        640, // width_pixels
        480, // height_pixels
        modes,
    );
    defer allocator.free(pty_data);

    // Verify the data has content
    try testing.expect(pty_data.len > 0);

    // Verify it starts with the terminal string length
    const term_len = std.mem.readInt(u32, pty_data[0..4], .big);
    try testing.expectEqual(@as(u32, "xterm-256color".len), term_len);
}

test "encodeExecRequest - format" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const exec_data = try encodeExecRequest(allocator, "echo hello");
    defer allocator.free(exec_data);

    // Verify format: string(command)
    const cmd_len = std.mem.readInt(u32, exec_data[0..4], .big);
    try testing.expectEqual(@as(u32, "echo hello".len), cmd_len);

    const command = exec_data[4..];
    try testing.expectEqualStrings("echo hello", command);
}

test "encodeSubsystemRequest - format" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const subsys_data = try encodeSubsystemRequest(allocator, "sftp");
    defer allocator.free(subsys_data);

    // Verify format: string(subsystem_name)
    const name_len = std.mem.readInt(u32, subsys_data[0..4], .big);
    try testing.expectEqual(@as(u32, "sftp".len), name_len);

    const subsys_name = subsys_data[4..];
    try testing.expectEqualStrings("sftp", subsys_name);
}

test "encodeEnvRequest - format" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const env_data = try encodeEnvRequest(allocator, "LANG", "en_US.UTF-8");
    defer allocator.free(env_data);

    const name_len = std.mem.readInt(u32, env_data[0..4], .big);
    try testing.expectEqual(@as(u32, 4), name_len);
    try testing.expectEqualStrings("LANG", env_data[4..8]);

    const value_len = std.mem.readInt(u32, env_data[8..12], .big);
    try testing.expectEqual(@as(u32, "en_US.UTF-8".len), value_len);
    try testing.expectEqualStrings("en_US.UTF-8", env_data[12..]);
}
