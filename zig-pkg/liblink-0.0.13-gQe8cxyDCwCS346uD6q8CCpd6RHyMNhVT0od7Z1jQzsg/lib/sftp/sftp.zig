const std = @import("std");

/// SFTP (SSH File Transfer Protocol) subsystem
pub const protocol = @import("protocol.zig");
pub const attributes = @import("attributes.zig");
pub const client = @import("client.zig");
pub const server = @import("server.zig");
pub const channel_adapter = @import("channel_adapter.zig");
pub const workflow = @import("workflow.zig");

// Re-export commonly used types
pub const SftpClient = client.SftpClient;
pub const SftpServer = server.SftpServer;
pub const SftpChannel = channel_adapter.SftpChannel;
pub const openSftpChannel = channel_adapter.openSftpChannel;

test {
    std.testing.refAllDecls(@This());
}
