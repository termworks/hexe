/// libfast - QUIC transport library
/// Supports both TLS and SSH key exchange modes
const std = @import("std");

// ============================================================================
// Public API - Main interface for applications
// ============================================================================

pub const QuicConnection = @import("api/connection.zig").QuicConnection;
pub const QuicStream = @import("api/stream.zig").QuicStream;
pub const StreamBuilder = @import("api/stream.zig").StreamBuilder;
pub const QuicConfig = @import("api/config.zig").QuicConfig;
pub const SshConfig = @import("api/config.zig").SshConfig;
pub const TlsConfig = @import("api/config.zig").TlsConfig;
pub const QuicMode = @import("api/config.zig").QuicMode;
pub const Role = @import("api/config.zig").Role;

// Public types
pub const ConnectionState = @import("api/types.zig").ConnectionState;
pub const StreamState = @import("api/types.zig").StreamState;
pub const StreamId = @import("api/types.zig").StreamId;
pub const QuicError = @import("api/types.zig").QuicError;
pub const ConnectionStats = @import("api/types.zig").ConnectionStats;
pub const StreamInfo = @import("api/types.zig").StreamInfo;
pub const ConnectionEvent = @import("api/types.zig").ConnectionEvent;
pub const StreamFinish = @import("api/types.zig").StreamFinish;

// ============================================================================
// Internal modules (for advanced users and library development)
// ============================================================================

// Core QUIC protocol
pub const types = @import("core/types.zig");
pub const packet = @import("core/packet.zig");
pub const frame = @import("core/frame.zig");
pub const stream = @import("core/stream.zig");
pub const connection = @import("core/connection.zig");
pub const transport_params = @import("core/transport_params.zig");
pub const flow_control = @import("core/flow_control.zig");
pub const loss_detection = @import("core/loss_detection.zig");
pub const congestion = @import("core/congestion.zig");
pub const varint = @import("utils/varint.zig");
pub const buffer = @import("utils/buffer.zig");
pub const time = @import("utils/time.zig");

// Crypto - SSH/QUIC
pub const ssh_obfuscation = @import("libsafe").ssh_obfuscation;
pub const ssh_init = @import("crypto/ssh/init.zig");
pub const ssh_reply = @import("crypto/ssh/reply.zig");
pub const ssh_cancel = @import("crypto/ssh/cancel.zig");
pub const ssh_kex = @import("libsafe").ssh_kex;
pub const ssh_secrets = @import("libsafe").ssh_secrets;
pub const ssh_ecdh = @import("libsafe").ssh_ecdh;
pub const ssh_signature = @import("libsafe").ssh_signature;
pub const ssh_hostkey = @import("libsafe").ssh_hostkey;

// Crypto - Common
pub const crypto = @import("libsafe").crypto;
pub const aead = @import("libsafe").aead;
pub const keys = @import("libsafe").keys;
pub const header_protection = @import("libsafe").header_protection;

// Crypto - TLS
pub const tls_handshake = @import("libsafe").tls_handshake;
pub const tls_key_schedule = @import("libsafe").tls_key_schedule;
pub const tls_context = @import("libsafe").tls_context;

// Transport
pub const udp = @import("transport/udp.zig");

// Re-export internal types for advanced use
pub const ConnectionId = types.ConnectionId;
pub const PacketNumber = types.PacketNumber;
pub const ErrorCode = types.ErrorCode;

// Version information
pub const version = "0.2.0"; // Incremented for public API
pub const QUIC_VERSION_1 = types.QUIC_VERSION_1;

// ============================================================================
// Convenience functions
// ============================================================================

/// Create a new SSH/QUIC client connection
pub fn newSshClient(
    allocator: std.mem.Allocator,
    server_name: []const u8,
    obfuscation_keyword: []const u8,
) QuicError!QuicConnection {
    const config = QuicConfig.sshClient(server_name, obfuscation_keyword);
    return QuicConnection.init(allocator, config);
}

/// Create a new SSH/QUIC server connection
pub fn newSshServer(
    allocator: std.mem.Allocator,
    obfuscation_keyword: []const u8,
) QuicError!QuicConnection {
    const config = QuicConfig.sshServer(obfuscation_keyword);
    return QuicConnection.init(allocator, config);
}

/// Create a new TLS/QUIC client connection
pub fn newTlsClient(
    allocator: std.mem.Allocator,
    server_name: []const u8,
) QuicError!QuicConnection {
    const config = QuicConfig.tlsClient(server_name);
    return QuicConnection.init(allocator, config);
}

/// Create a new TLS/QUIC server connection
pub fn newTlsServer(
    allocator: std.mem.Allocator,
    certificate: []const u8,
    private_key: []const u8,
) QuicError!QuicConnection {
    const config = QuicConfig.tlsServer(certificate, private_key);
    return QuicConnection.init(allocator, config);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("integration_test.zig");
    _ = @import("interop_lsquic_vector_test.zig");
    _ = @import("api/config.zig");
    _ = @import("api/types.zig");
    _ = @import("api/connection.zig");
    _ = @import("api/connection_frame_legality_test.zig");
    _ = @import("api/connection_cid_reset_test.zig");
    _ = @import("api/connection_retry_vn_test.zig");
    _ = @import("api/stream.zig");
}
