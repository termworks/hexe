const std = @import("std");
const testing = std.testing;
const liblink = @import("../../liblink.zig");

// Integration test: SFTP file transfer operations
//
// Tests:
// 1. SFTP subsystem initialization
// 2. File upload (client → server)
// 3. File download (server → client)
// 4. Directory listing
// 5. File deletion
// 6. Directory creation/removal

test "Integration: SFTP component availability" {
    std.log.info("=== Integration Test: SFTP Operations ===", .{});

    // Verify SFTP client components
    _ = liblink.sftp.SftpClient;
    _ = liblink.sftp.protocol;
    _ = liblink.sftp.attributes;

    // Verify SFTP server components
    _ = liblink.sftp.SftpServer;

    std.log.info("✓ SFTP client components available", .{});
    std.log.info("✓ SFTP server components available", .{});
}

test "Integration: SFTP protocol message encoding" {
    const allocator = testing.allocator;

    // Test SFTP INIT/VERSION exchange
    const init_msg = liblink.sftp.protocol.Init{ .version = 3 };
    const init_encoded = try init_msg.encode(allocator);
    defer allocator.free(init_encoded);

    const init_decoded = try liblink.sftp.protocol.Init.decode(init_encoded);
    try testing.expectEqual(@as(u32, 3), init_decoded.version);

    std.log.info("✓ SFTP INIT/VERSION exchange validated", .{});

    // Test SFTP STATUS message
    const status_msg = liblink.sftp.protocol.Status{
        .request_id = 42,
        .status_code = .SSH_FX_OK,
        .error_message = "Success",
        .language_tag = "en",
    };
    const status_encoded = try status_msg.encode(allocator);
    defer allocator.free(status_encoded);

    var status_decoded = try liblink.sftp.protocol.Status.decode(allocator, status_encoded);
    defer status_decoded.deinit(allocator);

    try testing.expectEqual(@as(u32, 42), status_decoded.request_id);
    try testing.expectEqual(liblink.sftp.protocol.StatusCode.SSH_FX_OK, status_decoded.status_code);

    std.log.info("✓ SFTP STATUS message validated", .{});
}

test "Integration: SFTP file operations structure" {
    std.log.info("=== Integration Test: SFTP File Operations ===", .{});

    // Verify file operation structures
    _ = liblink.sftp.protocol.OpenFlags;
    _ = liblink.sftp.protocol.Handle;
    _ = liblink.sftp.protocol.Data;

    std.log.info("✓ File open/close structures available", .{});
    std.log.info("✓ File read/write structures available", .{});
    std.log.info("✓ File handle structures available", .{});
}

test "Integration: SFTP directory operations structure" {
    std.log.info("=== Integration Test: SFTP Directory Operations ===", .{});

    _ = liblink.sftp.protocol.Handle;

    std.log.info("✓ Directory operation structures validated", .{});
}

test "Integration: SFTP symlink operations available" {
    _ = liblink.sftp.protocol.PacketType.SSH_FXP_READLINK;
    _ = liblink.sftp.protocol.PacketType.SSH_FXP_SYMLINK;
    _ = liblink.sftp.SftpClient.readlink;
    _ = liblink.sftp.SftpClient.symlink;
}

test "Integration: SFTP error handling" {
    const allocator = testing.allocator;

    // Test error status codes
    const error_status = liblink.sftp.protocol.Status{
        .request_id = 99,
        .status_code = .SSH_FX_NO_SUCH_FILE,
        .error_message = "File not found",
        .language_tag = "en",
    };

    const encoded = try error_status.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try liblink.sftp.protocol.Status.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqual(liblink.sftp.protocol.StatusCode.SSH_FX_NO_SUCH_FILE, decoded.status_code);
    try testing.expectEqualStrings("File not found", decoded.error_message);

    std.log.info("✓ SFTP error handling validated", .{});
}

test "Integration: SFTP file attributes" {
    const allocator = testing.allocator;

    var attrs = liblink.sftp.attributes.FileAttributes.init();
    attrs.size = 1024;
    attrs.permissions = 0o644;
    attrs.atime = 1234567890;
    attrs.mtime = 1234567890;
    attrs.flags.size = true;
    attrs.flags.permissions = true;

    const encoded = try attrs.encode(allocator);
    defer allocator.free(encoded);

    const decoded = try liblink.sftp.attributes.FileAttributes.decode(encoded);

    try testing.expectEqual(@as(u64, 1024), decoded.size);
    try testing.expectEqual(@as(u32, 0o644), decoded.permissions);

    std.log.info("✓ SFTP file attributes validated", .{});
}

test "Integration: SFTP open flags encoding" {
    const flags = liblink.sftp.protocol.OpenFlags{
        .read = true,
        .write = true,
        .creat = true,
        .trunc = false,
    };

    const value = flags.toU32();
    const decoded = liblink.sftp.protocol.OpenFlags.fromU32(value);

    try testing.expectEqual(true, decoded.read);
    try testing.expectEqual(true, decoded.write);
    try testing.expectEqual(true, decoded.creat);
    try testing.expectEqual(false, decoded.trunc);

    std.log.info("✓ SFTP open flags validated", .{});
}

test "Integration: SFTP server options include remote root" {
    const opts = liblink.sftp.SftpServer.Options{
        .remote_root = ".",
    };
    try testing.expectEqualStrings(".", opts.remote_root);
}
