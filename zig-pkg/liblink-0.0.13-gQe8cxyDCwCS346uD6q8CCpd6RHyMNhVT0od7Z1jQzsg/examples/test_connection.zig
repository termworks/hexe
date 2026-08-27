const std = @import("std");
const liblink = @import("liblink");

/// Simple test to verify SSH/QUIC connection works
///
/// Usage:
///   zig build
///   ./zig-out/bin/test_connection
///
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== SSH/QUIC Connection Test ===\n\n", .{});

    // Initialize random number generator
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();

    // Test configuration
    const server_address = "127.0.0.1";
    const server_port: u16 = 2222;

    std.debug.print("Testing SSH/QUIC connection to {}:{}\n\n", .{ server_address, server_port });

    // Create connection config
    const config = liblink.connection.ConnectionConfig{
        .server_address = server_address,
        .server_port = server_port,
        .random = random,
    };

    // Attempt to connect
    std.debug.print("Step 1: Initiating SSH key exchange...\n", .{});
    var conn = liblink.connection.ClientConnection.connect(allocator, config) catch |err| {
        std.debug.print("✗ Connection failed: {}\n", .{err});
        std.debug.print("\nThis is expected if no server is running.\n", .{});
        std.debug.print("To test with a real server:\n", .{});
        std.debug.print("  1. Run a test server on port 2222\n", .{});
        std.debug.print("  2. Server must implement SSH/QUIC protocol\n", .{});
        return;
    };
    defer conn.deinit();

    std.debug.print("✓ SSH/QUIC connection established!\n\n", .{});
    std.debug.print("Step 2: Opening QUIC stream (SSH channel)...\n", .{});

    const channel_id = try conn.openChannel();
    std.debug.print("✓ Opened channel {}\n\n", .{channel_id});

    std.debug.print("Step 3: Sending test data...\n", .{});
    const test_data = "Hello from SSH/QUIC!";
    try conn.sendData(channel_id, test_data);
    std.debug.print("✓ Sent {} bytes\n\n", .{test_data.len});

    std.debug.print("Step 4: Closing channel...\n", .{});
    try conn.closeChannel(channel_id);
    std.debug.print("✓ Channel closed\n\n", .{});

    std.debug.print("=== Test Complete ===\n\n", .{});
    std.debug.print("SSH/QUIC transport layer is working!\n", .{});
    std.debug.print("Next steps:\n", .{});
    std.debug.print("  - Implement SSH authentication\n", .{});
    std.debug.print("  - Implement channel protocol\n", .{});
    std.debug.print("  - Implement SFTP\n", .{});
}
