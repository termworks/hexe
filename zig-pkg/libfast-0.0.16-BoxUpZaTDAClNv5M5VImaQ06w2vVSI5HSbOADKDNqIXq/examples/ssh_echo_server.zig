const std = @import("std");
const libfast = @import("libfast");

/// Minimal SSH/QUIC echo server
///
/// This demonstrates how to:
/// - Create a QUIC connection in SSH mode
/// - Accept incoming streams
/// - Read and echo data back
/// - Handle connection lifecycle
///
/// Usage: zig build run-ssh-server
/// Then connect with: zig build run-ssh-client
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Starting SSH/QUIC echo server on 127.0.0.1:4433", .{});

    // Configure SSH mode with obfuscation keyword
    const config = libfast.QuicConfig.sshServer("test-obfuscation-keyword");

    // Create connection
    var conn = try libfast.QuicConnection.init(allocator, config);
    defer conn.deinit();

    std.log.info("Server ready, waiting for connections...", .{});

    // Accept connection (TODO: implement accept)
    // For now, this is a stub showing the intended API
    std.log.info("Note: Full connection handling not yet implemented", .{});
    std.log.info("This example shows the intended API structure", .{});

    // Event loop (TODO: implement poll)
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

    // TODO: Implement stream handling
    // Example intended API:
    //
    // var stream = try conn.getStream(stream_id);
    // var buf: [4096]u8 = undefined;
    //
    // // Read data
    // const n = try stream.read(&buf);
    // if (n == 0) {
    //     try stream.close();
    //     return;
    // }
    //
    // // Echo it back
    // try stream.write(buf[0..n]);
}
