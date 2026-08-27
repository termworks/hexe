const std = @import("std");
const libfast = @import("libfast");

/// Minimal TLS/QUIC echo server
///
/// This demonstrates how to:
/// - Create a QUIC connection in TLS mode
/// - Use certificates for authentication
/// - Accept incoming streams
/// - Read and echo data back
///
/// Usage: zig build run-tls-server
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Starting TLS/QUIC echo server on 127.0.0.1:4434", .{});

    // Configure TLS mode (certificate and key would be loaded from files)
    const certificate = ""; // TODO: Load from file
    const private_key = ""; // TODO: Load from file

    const config = libfast.QuicConfig.tlsServer(certificate, private_key);

    // Create connection
    var conn = try libfast.QuicConnection.init(allocator, config);
    defer conn.deinit();

    std.log.info("Server ready, waiting for connections...", .{});
    std.log.info("Note: Full TLS handshake not yet implemented", .{});
    std.log.info("This example shows the intended API structure", .{});

    // Event loop (same as SSH mode)
    const running = true;
    while (running) {
        // Poll for events
        // const events = try conn.poll();
        // for (events) |event| {
        //     switch (event) {
        //         .stream_opened => |stream_id| {
        //             std.log.info("New stream: {}", .{stream_id});
        //         },
        //         .stream_readable => |stream_id| {
        //             try handleStream(&conn, stream_id);
        //         },
        //         .closing => {
        //             running = false;
        //         },
        //         else => {},
        //     }
        // }

        // For now, just exit
        break;
    }

    std.log.info("Server shutting down", .{});
}

fn handleStream(conn: *libfast.QuicConnection, stream_id: u64) !void {
    _ = conn;
    _ = stream_id;

    // Same stream handling as SSH mode
    // The crypto layer is abstracted, so stream I/O is identical
}
