const std = @import("std");
const libfast = @import("libfast");

/// Minimal SSH/QUIC echo client
///
/// This demonstrates how to:
/// - Create a QUIC connection in SSH mode
/// - Connect to a server
/// - Open a stream
/// - Send and receive data
///
/// Usage: zig build run-ssh-client
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("SSH/QUIC echo client", .{});

    // Configure SSH mode with obfuscation keyword
    const server_name = "localhost";
    const obfuscation_keyword = "test-obfuscation-keyword";

    const config = libfast.QuicConfig.sshClient(server_name, obfuscation_keyword);

    // Create connection
    var conn = try libfast.QuicConnection.init(allocator, config);
    defer conn.deinit();

    std.log.info("Connecting to {s}:4433...", .{server_name});

    // Connect to server (TODO: implement connect)
    // For now, this is a stub showing the intended API
    // try conn.connect("127.0.0.1:4433");

    std.log.info("Note: Full connection handling not yet implemented", .{});
    std.log.info("This example shows the intended API structure", .{});

    // Open a stream (TODO: implement openStream)
    // var stream = try conn.openStream();

    // Send test message
    const message = "Hello, QUIC!";
    std.log.info("Would send: {s}", .{message});

    // const n = try stream.write(message);
    // std.log.info("Sent {} bytes", .{n});

    // Read echo response
    // var buf: [4096]u8 = undefined;
    // const received = try stream.read(&buf);
    // std.log.info("Received: {s}", .{buf[0..received]});

    // Close stream
    // try stream.close();

    std.log.info("Client finished", .{});
}
