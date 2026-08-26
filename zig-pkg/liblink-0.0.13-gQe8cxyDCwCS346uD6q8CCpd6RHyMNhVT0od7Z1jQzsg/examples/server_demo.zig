const std = @import("std");
const liblink = @import("liblink");

/// Complete SSH/QUIC Server Demo
///
/// Demonstrates the full server stack:
/// 1. Server initialization and listening
/// 2. Client connection acceptance
/// 3. Authentication handling
/// 4. Channel management
/// 5. Session request handling (shell, exec, subsystem)

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== SSH/QUIC Server Demo ===\n\n", .{});

    // Initialize random number generator
    var prng = std.Random.DefaultPrng.init(54321);
    const random = prng.random();

    // Generate host key pair
    std.debug.print("Generating server host key...\n", .{});
    var host_private_key: [64]u8 = undefined;
    var host_public_key: [32]u8 = undefined;
    random.bytes(&host_private_key);
    random.bytes(&host_public_key); // Simplified - normally derive from private
    std.debug.print("✓ Host key generated\n\n", .{});

    // Server configuration
    const listen_addr = "0.0.0.0";
    const listen_port: u16 = 2222;

    std.debug.print("Server configuration:\n", .{});
    std.debug.print("  Address: {s}:{d}\n", .{ listen_addr, listen_port });
    std.debug.print("  Protocol: SSH/QUIC\n", .{});
    std.debug.print("  Auth methods: publickey\n\n", .{});

    // Start server listener
    std.debug.print("Starting server listener...\n", .{});

    const host_key_str = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5..."; // Placeholder
    var listener = liblink.connection.startServer(
        allocator,
        listen_addr,
        listen_port,
        host_key_str,
        &host_private_key,
        random,
    ) catch |err| {
        std.debug.print("✗ Failed to start server: {}\n", .{err});
        std.debug.print("\nPossible issues:\n", .{});
        std.debug.print("  • Port {d} already in use\n", .{listen_port});
        std.debug.print("  • Insufficient permissions\n", .{});
        std.debug.print("  • Network interface not available\n", .{});
        return err;
    };
    defer listener.deinit();

    std.debug.print("✓ Server listening on {s}:{d}\n\n", .{ listen_addr, listen_port });
    std.debug.print("Waiting for client connections...\n", .{});
    std.debug.print("(Press Ctrl+C to stop)\n\n", .{});

    // Setup graceful shutdown (Ctrl+C handler would go here in production)
    // For demo purposes, we'll just show the pattern

    // Accept client connections in a loop
    var client_count: usize = 0;
    while (listener.running) {
        client_count += 1;

        std.debug.print("--- Client #{d} ---\n", .{client_count});
        std.debug.print("Active connections: {}\n", .{listener.getActiveConnectionCount()});

        // Accept connection (returns pointer to tracked connection)
        const server_conn = listener.acceptConnection() catch |err| {
            if (err == error.ServerShutdown) {
                std.debug.print("Server shutting down, no longer accepting connections\n", .{});
                break;
            }
            std.debug.print("✗ Failed to accept connection: {}\n\n", .{err});
            continue;
        };

        std.debug.print("✓ Client connected\n", .{});
        std.debug.print("  • UDP key exchange: ✓\n", .{});
        std.debug.print("  • QUIC handshake: ✓\n\n", .{});

        // In production, spawn a thread/task to handle this client concurrently:
        // const thread = try std.Thread.spawn(.{}, handleClient, .{allocator, server_conn, &listener});
        // thread.detach();
        //
        // For demo, handle synchronously:
        handleClient(allocator, server_conn, &listener) catch |err| {
            std.debug.print("✗ Client handler error: {}\n\n", .{err});
            // Connection will be cleaned up by removeConnection
            continue;
        };

        std.debug.print("✓ Client session completed\n\n", .{});
    }

    std.debug.print("\nServer stopped. Active connections: {}\n", .{listener.getActiveConnectionCount()});
    std.debug.print("Cleaning up remaining connections...\n", .{});
}

fn handleClient(
    allocator: std.mem.Allocator,
    connection: *liblink.connection.ServerConnection,
    listener: *liblink.connection.ConnectionListener,
) !void {
    // Ensure connection is cleaned up when this function returns
    defer listener.removeConnection(connection);
    // === Authentication ===
    std.debug.print("Waiting for authentication...\n", .{});

    const auth_success = connection.handleAuthentication(
        validatePublicKey,
    ) catch |err| {
        std.debug.print("✗ Authentication error: {}\n", .{err});
        return err;
    };

    if (!auth_success) {
        std.debug.print("✗ Authentication failed\n", .{});
        return error.AuthenticationFailed;
    }

    std.debug.print("✓ Client authenticated\n\n", .{});

    // === Session Management ===
    std.debug.print("Waiting for session requests...\n", .{});

    // Create session server
    var session_server = connection.createSessionServer();

    // Accept session channel on stream 4 (first client stream)
    const stream_id: u64 = 4;
    session_server.acceptSession(stream_id) catch |err| {
        std.debug.print("✗ Failed to accept session: {}\n", .{err});
        return err;
    };

    std.debug.print("✓ Session channel opened (stream {})\n", .{stream_id});

    // Wait for channel request
    const len = connection.receiveSessionData(stream_id) catch |err| {
        std.debug.print("✗ Failed to receive request: {}\n", .{err});
        return err;
    };
    defer allocator.free(len);

    // Handle the request
    session_server.handleRequest(
        stream_id,
        len,
        null, // pty_handler
        handleShellRequest,
        handleExecRequest,
        handleSubsystemRequest,
    ) catch |err| {
        std.debug.print("✗ Request handler error: {}\n", .{err});
        return err;
    };

    std.debug.print("✓ Request handled\n", .{});

    // Keep session alive for demonstration
    std.debug.print("Session active. Demo server will close after this.\n", .{});
}

// === Authentication Validators ===

fn validatePublicKey(username: []const u8, algorithm: []const u8, public_key_blob: []const u8) bool {
    std.debug.print("  Public key auth: user={s}, algo={s}\n", .{ username, algorithm });

    // Demo: Accept any Ed25519 key for testuser
    if (std.mem.eql(u8, username, "testuser") and std.mem.eql(u8, algorithm, "ssh-ed25519")) {
        if (public_key_blob.len > 0) {
            std.debug.print("  ✓ Public key accepted\n", .{});
            return true;
        }
    }

    std.debug.print("  ✗ Public key rejected\n", .{});
    return false;
}

// === Session Request Handlers ===

fn handleShellRequest(stream_id: u64) !void {
    std.debug.print("  Shell requested on stream {}\n", .{stream_id});
    std.debug.print("  ✓ Shell handler called\n", .{});
    std.debug.print("  Note: Full shell spawning not implemented in demo\n", .{});

    // In production:
    // 1. Fork/spawn shell process (e.g., /bin/bash)
    // 2. Create PTY if pty-req was sent
    // 3. Wire up stdin/stdout/stderr to channel
    // 4. Handle window change requests
    // 5. Send exit status on close
}

fn handleExecRequest(stream_id: u64, command: []const u8) !void {
    std.debug.print("  Exec requested on stream {}\n", .{stream_id});
    std.debug.print("  Command: {s}\n", .{command});
    std.debug.print("  ✓ Exec handler called\n", .{});
    std.debug.print("  Note: Command execution not implemented in demo\n", .{});

    // In production:
    // 1. Parse and validate command
    // 2. Spawn process with command
    // 3. Capture stdout/stderr
    // 4. Send output to channel
    // 5. Send exit status
}

fn handleSubsystemRequest(stream_id: u64, subsystem_name: []const u8) !void {
    std.debug.print("  Subsystem requested on stream {}\n", .{stream_id});
    std.debug.print("  Subsystem: {s}\n", .{subsystem_name});

    if (std.mem.eql(u8, subsystem_name, "sftp")) {
        std.debug.print("  ✓ SFTP subsystem handler called\n", .{});
        std.debug.print("  Note: SFTP server can be started here\n", .{});
        std.debug.print("  Example:\n", .{});
        std.debug.print("    var sftp_server = try liblink.sftp.SftpServer.init(allocator, sftp_channel);\n", .{});
        std.debug.print("    defer sftp_server.deinit();\n", .{});
        std.debug.print("    try sftp_server.run(); // Process SFTP requests\n", .{});
    } else {
        std.debug.print("  ✗ Unknown subsystem: {s}\n", .{subsystem_name});
        return error.UnsupportedSubsystem;
    }
}
