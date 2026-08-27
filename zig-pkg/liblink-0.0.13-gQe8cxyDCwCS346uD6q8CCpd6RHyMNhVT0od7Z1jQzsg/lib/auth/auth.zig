const std = @import("std");

/// SSH Authentication Layer
///
/// Provides both client and server authentication implementations
/// supporting public key authentication.

pub const AuthClient = @import("client.zig").AuthClient;
pub const AuthResult = @import("client.zig").AuthResult;
pub const AuthServer = @import("server.zig").AuthServer;
pub const AuthResponse = @import("server.zig").AuthResponse;

// System-level authentication (PUBLIC KEY ONLY - no passwords!)
pub const system = @import("system.zig");

test {
    std.testing.refAllDecls(@This());
}
