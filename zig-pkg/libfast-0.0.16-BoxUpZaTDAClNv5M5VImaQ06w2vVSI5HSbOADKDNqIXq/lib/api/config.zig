const std = @import("std");
const crypto_mod = @import("libsafe").crypto;
const types = @import("../core/types.zig");

/// QUIC configuration for connection setup

// Re-export QuicMode from core/types.zig to avoid duplication
pub const QuicMode = types.QuicMode;

/// SSH mode configuration
pub const SshConfig = struct {
    /// Obfuscation keyword (optional, empty string means no obfuscation)
    obfuscation_keyword: []const u8 = "",

    /// Server name indication (SNI)
    server_name: []const u8 = "",

    /// Trusted server host key fingerprints (for client)
    trusted_fingerprints: []const []const u8 = &[_][]const u8{},

    /// Key exchange algorithms (in preference order)
    kex_algorithms: []const []const u8 = &[_][]const u8{"curve25519-sha256"},

    /// Signature algorithms
    signature_algorithms: []const []const u8 = &[_][]const u8{"ssh-ed25519"},

    /// Cipher suites (in preference order)
    cipher_suites: []const []const u8 = &[_][]const u8{
        "TLS_AES_256_GCM_SHA384",
        "TLS_AES_128_GCM_SHA256",
    },
};

/// TLS mode configuration
pub const TlsConfig = struct {
    /// Server name indication (SNI)
    server_name: []const u8 = "",

    /// Certificate chain (PEM format, for server)
    certificate_chain: ?[]const u8 = null,

    /// Private key (PEM format, for server)
    private_key: ?[]const u8 = null,

    /// Cipher suites (in preference order)
    cipher_suites: []const []const u8 = &[_][]const u8{
        "TLS_AES_128_GCM_SHA256",
        "TLS_AES_256_GCM_SHA384",
        "TLS_CHACHA20_POLY1305_SHA256",
    },

    /// ALPN protocols
    alpn_protocols: []const []const u8 = &[_][]const u8{},

    /// Verify server certificate and hostname (client mode)
    verify_peer: bool = true,

    /// Skip certificate and hostname verification (unsafe)
    allow_insecure_skip_verify: bool = false,

    /// Optional PEM-encoded custom trust anchors for verification
    trusted_ca_pem: ?[]const u8 = null,
};

/// Connection endpoint role
pub const Role = enum {
    client,
    server,

    pub fn toString(self: Role) []const u8 {
        return switch (self) {
            .client => "Client",
            .server => "Server",
        };
    }

    pub fn isClient(self: Role) bool {
        return self == .client;
    }

    pub fn isServer(self: Role) bool {
        return self == .server;
    }
};

/// QUIC connection configuration
pub const QuicConfig = struct {
    /// Connection mode (TLS or SSH)
    mode: QuicMode,

    /// Endpoint role (client or server)
    role: Role,

    /// Mode-specific configuration
    ssh_config: ?SshConfig = null,
    tls_config: ?TlsConfig = null,

    /// Maximum concurrent bidirectional streams
    max_bidi_streams: u64 = 100,

    /// Maximum concurrent unidirectional streams
    max_uni_streams: u64 = 100,

    /// Initial maximum data (connection-level flow control)
    initial_max_data: u64 = 1024 * 1024, // 1 MB

    /// Initial maximum stream data (per-stream flow control)
    initial_max_stream_data_bidi_local: u64 = 256 * 1024,
    initial_max_stream_data_bidi_remote: u64 = 256 * 1024,
    initial_max_stream_data_uni: u64 = 256 * 1024,

    /// Idle timeout (milliseconds)
    max_idle_timeout: u64 = 30000, // 30 seconds

    /// Local connection ID
    local_connection_id: ?[]const u8 = null,

    /// Validate configuration
    pub fn validate(self: QuicConfig) !void {
        // Ensure mode-specific config is present
        switch (self.mode) {
            .ssh => {
                if (self.ssh_config == null) {
                    return error.MissingSshConfig;
                }
            },
            .tls => {
                if (self.tls_config == null) {
                    return error.MissingTlsConfig;
                }
                // Server must have certificate and private key
                if (self.role == .server) {
                    const tls = self.tls_config.?;
                    if (tls.certificate_chain == null or tls.private_key == null) {
                        return error.MissingServerCredentials;
                    }
                } else {
                    const tls = self.tls_config.?;
                    if (tls.verify_peer and tls.server_name.len == 0) {
                        return error.MissingServerName;
                    }
                    if (tls.verify_peer and tls.allow_insecure_skip_verify) {
                        return error.InvalidTlsVerificationConfig;
                    }
                }
            },
        }
    }

    /// Create default client config for SSH mode
    pub fn sshClient(server_name: []const u8, obfuscation_keyword: []const u8) QuicConfig {
        return QuicConfig{
            .mode = .ssh,
            .role = .client,
            .ssh_config = SshConfig{
                .server_name = server_name,
                .obfuscation_keyword = obfuscation_keyword,
            },
        };
    }

    /// Create default server config for SSH mode
    pub fn sshServer(obfuscation_keyword: []const u8) QuicConfig {
        return QuicConfig{
            .mode = .ssh,
            .role = .server,
            .ssh_config = SshConfig{
                .obfuscation_keyword = obfuscation_keyword,
            },
        };
    }

    /// Create default client config for TLS mode
    pub fn tlsClient(server_name: []const u8) QuicConfig {
        return QuicConfig{
            .mode = .tls,
            .role = .client,
            .tls_config = TlsConfig{
                .server_name = server_name,
            },
        };
    }

    /// Create default server config for TLS mode
    pub fn tlsServer(certificate: []const u8, private_key: []const u8) QuicConfig {
        return QuicConfig{
            .mode = .tls,
            .role = .server,
            .tls_config = TlsConfig{
                .certificate_chain = certificate,
                .private_key = private_key,
            },
        };
    }
};

// Tests

test "SSH client config" {
    const config = QuicConfig.sshClient("example.com", "my-secret");

    try std.testing.expectEqual(QuicMode.ssh, config.mode);
    try std.testing.expectEqual(Role.client, config.role);
    try std.testing.expect(config.ssh_config != null);
    try std.testing.expectEqualStrings("example.com", config.ssh_config.?.server_name);
    try std.testing.expectEqualStrings("my-secret", config.ssh_config.?.obfuscation_keyword);
}

test "SSH server config" {
    const config = QuicConfig.sshServer("my-secret");

    try std.testing.expectEqual(QuicMode.ssh, config.mode);
    try std.testing.expectEqual(Role.server, config.role);
    try std.testing.expect(config.ssh_config != null);
}

test "TLS client config" {
    const config = QuicConfig.tlsClient("example.com");

    try std.testing.expectEqual(QuicMode.tls, config.mode);
    try std.testing.expectEqual(Role.client, config.role);
    try std.testing.expect(config.tls_config != null);
    try std.testing.expectEqualStrings("example.com", config.tls_config.?.server_name);
}

test "TLS server config" {
    const cert = "-----BEGIN CERTIFICATE-----\n...";
    const key = "-----BEGIN PRIVATE KEY-----\n...";
    const config = QuicConfig.tlsServer(cert, key);

    try std.testing.expectEqual(QuicMode.tls, config.mode);
    try std.testing.expectEqual(Role.server, config.role);
    try std.testing.expect(config.tls_config != null);
    try std.testing.expect(config.tls_config.?.certificate_chain != null);
    try std.testing.expect(config.tls_config.?.private_key != null);
}

test "Config validation - SSH client valid" {
    const config = QuicConfig.sshClient("example.com", "secret");
    try config.validate();
}

test "Config validation - TLS server requires credentials" {
    const config = QuicConfig{
        .mode = .tls,
        .role = .server,
        .tls_config = TlsConfig{},
    };

    const result = config.validate();
    try std.testing.expectError(error.MissingServerCredentials, result);
}

test "Config validation - TLS client requires server name when verifying" {
    const config = QuicConfig{
        .mode = .tls,
        .role = .client,
        .tls_config = TlsConfig{
            .server_name = "",
            .verify_peer = true,
        },
    };

    const result = config.validate();
    try std.testing.expectError(error.MissingServerName, result);
}

test "Config validation - TLS verify_peer conflicts with insecure skip" {
    const config = QuicConfig{
        .mode = .tls,
        .role = .client,
        .tls_config = TlsConfig{
            .server_name = "example.com",
            .verify_peer = true,
            .allow_insecure_skip_verify = true,
        },
    };

    const result = config.validate();
    try std.testing.expectError(error.InvalidTlsVerificationConfig, result);
}

test "Role helper methods" {
    const client_role = Role.client;
    const server_role = Role.server;

    try std.testing.expect(client_role.isClient());
    try std.testing.expect(!client_role.isServer());
    try std.testing.expect(server_role.isServer());
    try std.testing.expect(!server_role.isClient());
}
