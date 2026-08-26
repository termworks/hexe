const std = @import("std");

// Integration Test Suite Runner
//
// This module aggregates all integration tests for the SSH/QUIC implementation.
// Integration tests validate end-to-end functionality across multiple components.

// Import all integration test modules
pub const connection = @import("connection_test.zig");
pub const sftp = @import("sftp_test.zig");
pub const sftp_e2e = @import("sftp_e2e_test.zig");
pub const network_auth_e2e = @import("network_auth_e2e_test.zig");
pub const network_sftp_e2e = @import("network_sftp_e2e_test.zig");
pub const network_exec_e2e = @import("network_exec_e2e_test.zig");
pub const server_lifecycle = @import("server_lifecycle_test.zig");

test {
    std.testing.refAllDecls(@This());
}
