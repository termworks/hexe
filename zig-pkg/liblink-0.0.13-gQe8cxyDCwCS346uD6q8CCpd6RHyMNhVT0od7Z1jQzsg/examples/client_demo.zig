const std = @import("std");
const liblink = @import("liblink");

/// Complete SSH/QUIC Client Demo
///
/// Demonstrates the full stack:
/// 1. Connection establishment (UDP key exchange + QUIC)
/// 2. Authentication (public key)
/// 3. Shell session
/// 4. Command execution
/// 5. SFTP file operations

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== SSH/QUIC Client Demo ===\n\n", .{});

    // Initialize random number generator
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    // Demo configuration
    const server_host = "127.0.0.1";
    const server_port: u16 = 2222;
    const username = "testuser";
    const identity_path = "~/.ssh/id_ed25519";

    std.debug.print("Target: {s}:{d}\n", .{ server_host, server_port });
    std.debug.print("Username: {s}\n\n", .{username});

    // === Phase 1: Connection ===
    std.debug.print("Phase 1: Establishing connection...\n", .{});

    var connection = liblink.connection.connectClient(
        allocator,
        server_host,
        server_port,
        random,
    ) catch |err| {
        std.debug.print("✗ Connection failed: {}\n", .{err});
        std.debug.print("\nNote: This demo requires a running SSH/QUIC server.\n", .{});
        std.debug.print("To run a test server, see examples/server_demo.zig\n", .{});
        return err;
    };
    defer connection.deinit();

    std.debug.print("✓ Connection established\n", .{});
    std.debug.print("  • UDP key exchange: ✓\n", .{});
    std.debug.print("  • QUIC handshake: ✓\n", .{});
    std.debug.print("  • SSH/QUIC ready: ✓\n\n", .{});

    // === Phase 2: Authentication ===
    std.debug.print("Phase 2: Authenticating...\n", .{});

    const auth_success = try liblink.auth.workflow.authenticateClient(allocator, &connection, username, .{
        .identity_path = identity_path,
    });

    if (!auth_success) {
        std.debug.print("✗ Authentication failed\n", .{});
        return error.AuthenticationFailed;
    }

    std.debug.print("✓ Authenticated successfully\n", .{});
    std.debug.print("  • Public key auth: ✓\n\n", .{});

    // === Phase 3: Command Execution ===
    std.debug.print("Phase 3: Executing remote command...\n", .{});

    try demoExec(allocator, &connection);

    // === Phase 4: Shell Session ===
    std.debug.print("\nPhase 4: Shell session...\n", .{});

    try demoShell(allocator, &connection);

    // === Phase 5: SFTP Operations ===
    std.debug.print("\nPhase 5: SFTP file operations...\n", .{});

    try demoSftp(allocator, &connection);

    std.debug.print("\n=== Demo Complete ===\n", .{});
    std.debug.print("\nAll phases successful:\n", .{});
    std.debug.print("  ✓ Connection (SSH/QUIC)\n", .{});
    std.debug.print("  ✓ Authentication\n", .{});
    std.debug.print("  ✓ Command execution\n", .{});
    std.debug.print("  ✓ Shell session\n", .{});
    std.debug.print("  ✓ SFTP subsystem\n", .{});
}

fn demoExec(allocator: std.mem.Allocator, connection: *liblink.connection.ClientConnection) !void {
    const command = "echo 'Hello from SSH/QUIC!'";

    std.debug.print("  Executing: {s}\n", .{command});

    var session = connection.requestExec(command) catch |err| {
        std.debug.print("  ✗ Exec failed: {}\n", .{err});
        return err;
    };
    defer session.close() catch {};

    std.debug.print("  ✓ Command sent\n", .{});

    // Read output
    const output = session.receiveData() catch |err| {
        std.debug.print("  ✗ Failed to read output: {}\n", .{err});
        return err;
    };
    defer allocator.free(output);

    std.debug.print("  Output: {s}\n", .{output});
    std.debug.print("  ✓ Command executed successfully\n", .{});
}

fn demoShell(allocator: std.mem.Allocator, connection: *liblink.connection.ClientConnection) !void {
    _ = allocator;

    std.debug.print("  Opening shell channel...\n", .{});

    var session = connection.requestShell(80, 24) catch |err| {
        std.debug.print("  ✗ Shell request failed: {}\n", .{err});
        return err;
    };
    defer session.close() catch {};

    std.debug.print("  ✓ Shell session opened\n", .{});
    std.debug.print("  Note: Interactive I/O not implemented in demo\n", .{});
    std.debug.print("  ✓ Shell channel ready for terminal I/O\n", .{});
}

fn demoSftp(allocator: std.mem.Allocator, connection: *liblink.connection.ClientConnection) !void {
    std.debug.print("  Opening SFTP subsystem...\n", .{});

    var sftp_channel = connection.openSftp() catch |err| {
        std.debug.print("  ✗ SFTP open failed: {}\n", .{err});
        return err;
    };
    defer sftp_channel.deinit();

    std.debug.print("  ✓ SFTP channel opened\n", .{});

    // Initialize SFTP client
    var sftp_client = liblink.sftp.SftpClient.init(allocator, sftp_channel) catch |err| {
        std.debug.print("  ✗ SFTP init failed: {}\n", .{err});
        return err;
    };
    defer sftp_client.deinit();

    std.debug.print("  ✓ SFTP protocol negotiated (version {})\n", .{sftp_client.version});

    // Demonstrate SFTP operations
    std.debug.print("  Available operations:\n", .{});
    std.debug.print("    • open/close files\n", .{});
    std.debug.print("    • read/write data\n", .{});
    std.debug.print("    • list directories\n", .{});
    std.debug.print("    • stat/setstat\n", .{});
    std.debug.print("    • mkdir/rmdir\n", .{});
    std.debug.print("    • rename/remove\n", .{});

    // Example: List directory (would work with real server)
    std.debug.print("  Example: sftp_client.opendir(\"/home/user\")\n", .{});
    std.debug.print("  ✓ SFTP subsystem operational\n", .{});
}
