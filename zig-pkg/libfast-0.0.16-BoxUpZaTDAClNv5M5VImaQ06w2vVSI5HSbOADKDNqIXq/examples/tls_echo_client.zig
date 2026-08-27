const std = @import("std");
const libfast = @import("libfast");

/// Minimal TLS/QUIC echo client
///
/// This demonstrates how to:
/// - Create a QUIC connection in TLS mode
/// - Connect with TLS 1.3 handshake
/// - Open a stream
/// - Send and receive data
///
/// Usage: zig build run-tls-client
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("TLS/QUIC echo client", .{});

    // Configure TLS mode
    const server_name = "localhost";
    const config = libfast.QuicConfig.tlsClient(server_name);

    // Create connection
    var conn = try libfast.QuicConnection.init(allocator, config);
    defer conn.deinit();

    std.log.info("Connecting to {s}:4434...", .{server_name});
    std.log.info("Note: Full TLS handshake not yet implemented", .{});
    std.log.info("This example shows the intended API structure", .{});

    // Connect to server (TODO: implement connect)
    // try conn.connect("127.0.0.1:4434");

    // Open a stream (TODO: implement openStream)
    // var stream = try conn.openStream();

    // Send test message
    const message = "Hello, TLS/QUIC!";
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
