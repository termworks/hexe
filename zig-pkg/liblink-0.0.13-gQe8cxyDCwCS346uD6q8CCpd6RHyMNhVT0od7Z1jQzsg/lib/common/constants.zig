const std = @import("std");

/// SSH/QUIC packet type identifiers
pub const PacketType = enum(u8) {
    /// SSH_QUIC_INIT - Client initiates key exchange
    ssh_quic_init = 1,
    /// SSH_QUIC_REPLY - Server responds to key exchange
    ssh_quic_reply = 2,
    /// SSH_QUIC_CANCEL - Client cancels connection
    ssh_quic_cancel = 3,
};

/// SSH Message Type Constants (RFC 4250, 4251, 4252, 4254)
pub const SSH_MSG = struct {
    // Transport layer generic (1-19)
    pub const DISCONNECT = 1;
    pub const IGNORE = 2;
    pub const UNIMPLEMENTED = 3;
    pub const DEBUG = 4;
    pub const SERVICE_REQUEST = 5;
    pub const SERVICE_ACCEPT = 6;
    pub const EXT_INFO = 7; // RFC 8308

    // Algorithm negotiation (20-29) - NOT USED in SSH/QUIC
    pub const KEXINIT = 20; // Prohibited in SSH/QUIC
    pub const NEWKEYS = 21; // Prohibited in SSH/QUIC

    // Key exchange method specific (30-49)
    pub const KEX_ECDH_INIT = 30;
    pub const KEX_ECDH_REPLY = 31;
    pub const KEXDH_INIT = 30; // Same as ECDH_INIT
    pub const KEXDH_REPLY = 31; // Same as ECDH_REPLY

    // User authentication generic (50-59)
    pub const USERAUTH_REQUEST = 50;
    pub const USERAUTH_FAILURE = 51;
    pub const USERAUTH_SUCCESS = 52;
    pub const USERAUTH_BANNER = 53;

    // User authentication method specific (60-79)
    pub const USERAUTH_INFO_REQUEST = 60; // keyboard-interactive
    pub const USERAUTH_INFO_RESPONSE = 61;
    pub const USERAUTH_PK_OK = 60; // public key (same value as INFO_REQUEST)

    // Connection protocol global (80-89)
    pub const GLOBAL_REQUEST = 80;
    pub const REQUEST_SUCCESS = 81;
    pub const REQUEST_FAILURE = 82;

    // Channel related messages (90-127)
    pub const CHANNEL_OPEN = 90;
    pub const CHANNEL_OPEN_CONFIRMATION = 91;
    pub const CHANNEL_OPEN_FAILURE = 92;
    pub const CHANNEL_WINDOW_ADJUST = 93; // Prohibited in SSH/QUIC
    pub const CHANNEL_DATA = 94;
    pub const CHANNEL_EXTENDED_DATA = 95;
    pub const CHANNEL_EOF = 96;
    pub const CHANNEL_CLOSE = 97; // Prohibited in SSH/QUIC
    pub const CHANNEL_REQUEST = 98;
    pub const CHANNEL_SUCCESS = 99;
    pub const CHANNEL_FAILURE = 100;
};

/// SSH Disconnect Reason Codes (RFC 4253 Section 11.1)
pub const SSH_DISCONNECT = struct {
    pub const HOST_NOT_ALLOWED_TO_CONNECT = 1;
    pub const PROTOCOL_ERROR = 2;
    pub const KEY_EXCHANGE_FAILED = 3;
    pub const RESERVED = 4;
    pub const MAC_ERROR = 5;
    pub const COMPRESSION_ERROR = 6;
    pub const SERVICE_NOT_AVAILABLE = 7;
    pub const PROTOCOL_VERSION_NOT_SUPPORTED = 8;
    pub const HOST_KEY_NOT_VERIFIABLE = 9;
    pub const CONNECTION_LOST = 10;
    pub const BY_APPLICATION = 11;
    pub const TOO_MANY_CONNECTIONS = 12;
    pub const AUTH_CANCELLED_BY_USER = 13;
    pub const NO_MORE_AUTH_METHODS_AVAILABLE = 14;
    pub const ILLEGAL_USER_NAME = 15;
};

/// SSH Channel Open Failure Reason Codes (RFC 4254 Section 5.1)
pub const SSH_OPEN = struct {
    pub const ADMINISTRATIVELY_PROHIBITED = 1;
    pub const CONNECT_FAILED = 2;
    pub const UNKNOWN_CHANNEL_TYPE = 3;
    pub const RESOURCE_SHORTAGE = 4;
};

/// SFTP Protocol Version
pub const SFTP_VERSION = 3;

/// SFTP Message Types (draft-ietf-secsh-filexfer-02)
pub const SSH_FXP = struct {
    pub const INIT = 1;
    pub const VERSION = 2;
    pub const OPEN = 3;
    pub const CLOSE = 4;
    pub const READ = 5;
    pub const WRITE = 6;
    pub const LSTAT = 7;
    pub const FSTAT = 8;
    pub const SETSTAT = 9;
    pub const FSETSTAT = 10;
    pub const OPENDIR = 11;
    pub const READDIR = 12;
    pub const REMOVE = 13;
    pub const MKDIR = 14;
    pub const RMDIR = 15;
    pub const REALPATH = 16;
    pub const STAT = 17;
    pub const RENAME = 18;
    pub const READLINK = 19;
    pub const SYMLINK = 20;
    pub const STATUS = 101;
    pub const HANDLE = 102;
    pub const DATA = 103;
    pub const NAME = 104;
    pub const ATTRS = 105;
    pub const EXTENDED = 200;
    pub const EXTENDED_REPLY = 201;
};

/// SFTP Status Codes
pub const SSH_FX = struct {
    pub const OK = 0;
    pub const EOF = 1;
    pub const NO_SUCH_FILE = 2;
    pub const PERMISSION_DENIED = 3;
    pub const FAILURE = 4;
    pub const BAD_MESSAGE = 5;
    pub const NO_CONNECTION = 6;
    pub const CONNECTION_LOST = 7;
    pub const OP_UNSUPPORTED = 8;
};

/// SFTP File Open Flags (bitmask)
pub const SSH_FXF = struct {
    pub const READ = 0x00000001;
    pub const WRITE = 0x00000002;
    pub const APPEND = 0x00000004;
    pub const CREAT = 0x00000008;
    pub const TRUNC = 0x00000010;
    pub const EXCL = 0x00000020;
};

/// SFTP File Attribute Flags (bitmask)
pub const SSH_FILEXFER_ATTR = struct {
    pub const SIZE = 0x00000001;
    pub const UIDGID = 0x00000002;
    pub const PERMISSIONS = 0x00000004;
    pub const ACMODTIME = 0x00000008;
    pub const EXTENDED = 0x80000000;
};

/// Protocol limits
pub const Limits = struct {
    /// Minimum size for SSH_QUIC_INIT unencrypted payload (DDoS protection)
    pub const min_init_packet_size = 1200;

    /// Maximum SSH packet size we accept (32 KB per spec)
    pub const max_packet_size = 32768;

    /// Obfuscated envelope nonce size (AES-256-GCM)
    pub const obfs_nonce_size = 16;

    /// Obfuscated envelope tag size (GCM authentication tag)
    pub const obfs_tag_size = 16;

    /// Minimum obfuscated envelope size (nonce + tag)
    pub const min_obfs_envelope_size = obfs_nonce_size + obfs_tag_size;

    /// QUIC connection ID maximum size
    pub const max_connection_id_size = 20;

    /// Maximum Random Name length
    pub const max_random_name_length = 64;

    /// Minimum Random Name length (Assigned form with full character set)
    pub const min_random_name_assigned = 20;

    /// Minimum Random Name length (Anonymous form)
    pub const min_random_name_anonymous = 35;

    /// Maximum short-str size (byte length prefix)
    pub const max_short_str_size = 255;

    /// SFTP maximum packet size (practical limit)
    pub const max_sftp_packet_size = 32768;

    /// SFTP default read size
    pub const sftp_default_read_size = 32768;

    /// SFTP default write size
    pub const sftp_default_write_size = 32768;
};

/// Default constants for key exchange
pub const KEX_CURVE25519_SHA256 = "curve25519-sha256";
pub const DEFAULT_SIG_ALGS = "ssh-ed25519,rsa-sha2-256,rsa-sha2-512";
pub const DEFAULT_CIPHER_SUITE = "TLS_AES_256_GCM_SHA384";

/// Key exchange algorithm names
pub const KexAlgorithm = enum {
    curve25519_sha256,

    pub fn toString(self: KexAlgorithm) []const u8 {
        return switch (self) {
            .curve25519_sha256 => "curve25519-sha256",
        };
    }

    pub fn fromString(s: []const u8) ?KexAlgorithm {
        if (std.mem.eql(u8, s, "curve25519-sha256")) return .curve25519_sha256;
        return null;
    }
};

/// Signature algorithm names
pub const SignatureAlgorithm = enum {
    ssh_ed25519,
    rsa_sha2_256,
    rsa_sha2_512,

    pub fn toString(self: SignatureAlgorithm) []const u8 {
        return switch (self) {
            .ssh_ed25519 => "ssh-ed25519",
            .rsa_sha2_256 => "rsa-sha2-256",
            .rsa_sha2_512 => "rsa-sha2-512",
        };
    }

    pub fn fromString(s: []const u8) ?SignatureAlgorithm {
        if (std.mem.eql(u8, s, "ssh-ed25519")) return .ssh_ed25519;
        if (std.mem.eql(u8, s, "rsa-sha2-256")) return .rsa_sha2_256;
        if (std.mem.eql(u8, s, "rsa-sha2-512")) return .rsa_sha2_512;
        return null;
    }
};

/// TLS cipher suites for QUIC
pub const CipherSuite = enum {
    tls_aes_128_gcm_sha256,
    tls_aes_256_gcm_sha384,

    pub fn toString(self: CipherSuite) []const u8 {
        return switch (self) {
            .tls_aes_128_gcm_sha256 => "TLS_AES_128_GCM_SHA256",
            .tls_aes_256_gcm_sha384 => "TLS_AES_256_GCM_SHA384",
        };
    }

    pub fn fromString(s: []const u8) ?CipherSuite {
        if (std.mem.eql(u8, s, "TLS_AES_128_GCM_SHA256")) return .tls_aes_128_gcm_sha256;
        if (std.mem.eql(u8, s, "TLS_AES_256_GCM_SHA384")) return .tls_aes_256_gcm_sha384;
        return null;
    }
};

/// QUIC stream ID helpers
pub const QuicStream = struct {
    /// Stream 0 is used for SSH global messages and authentication
    pub const global = 0;

    /// Check if stream ID is bidirectional (last 2 bits are 00 or 01)
    pub fn isBidirectional(stream_id: u64) bool {
        return (stream_id & 0x02) == 0;
    }

    /// Check if stream was initiated by client (second-to-last bit is 0)
    pub fn isClientInitiated(stream_id: u64) bool {
        return (stream_id & 0x01) == 0;
    }

    /// Check if stream was initiated by server (second-to-last bit is 1)
    pub fn isServerInitiated(stream_id: u64) bool {
        return (stream_id & 0x01) == 1;
    }

    /// Get next client-initiated bidirectional stream ID
    pub fn nextClientBidi(current: u64) u64 {
        if (current == 0) return 4;
        return current + 4;
    }

    /// Get next server-initiated bidirectional stream ID
    pub fn nextServerBidi(current: u64) u64 {
        if (current == 0) return 5;
        return current + 4;
    }
};

test "SSH message constants" {
    const testing = std.testing;

    // Verify some key constants
    try testing.expectEqual(@as(u8, 1), SSH_MSG.DISCONNECT);
    try testing.expectEqual(@as(u8, 7), SSH_MSG.EXT_INFO);
    try testing.expectEqual(@as(u8, 50), SSH_MSG.USERAUTH_REQUEST);
    try testing.expectEqual(@as(u8, 90), SSH_MSG.CHANNEL_OPEN);
}

test "QUIC stream helpers" {
    const testing = std.testing;

    // Stream 0 is bidirectional and client-initiated
    try testing.expect(QuicStream.isBidirectional(0));
    try testing.expect(QuicStream.isClientInitiated(0));
    try testing.expect(!QuicStream.isServerInitiated(0));

    // Stream 4 is bidirectional and client-initiated
    try testing.expect(QuicStream.isBidirectional(4));
    try testing.expect(QuicStream.isClientInitiated(4));

    // Stream 5 is bidirectional and server-initiated
    try testing.expect(QuicStream.isBidirectional(5));
    try testing.expect(QuicStream.isServerInitiated(5));

    // Next client bidi streams
    try testing.expectEqual(@as(u64, 4), QuicStream.nextClientBidi(0));
    try testing.expectEqual(@as(u64, 8), QuicStream.nextClientBidi(4));
    try testing.expectEqual(@as(u64, 12), QuicStream.nextClientBidi(8));

    // Next server bidi streams
    try testing.expectEqual(@as(u64, 5), QuicStream.nextServerBidi(0));
    try testing.expectEqual(@as(u64, 9), QuicStream.nextServerBidi(5));
}

test "algorithm name conversions" {
    const testing = std.testing;

    // Kex algorithm
    const kex = KexAlgorithm.curve25519_sha256;
    try testing.expectEqualStrings("curve25519-sha256", kex.toString());
    try testing.expectEqual(KexAlgorithm.curve25519_sha256, KexAlgorithm.fromString("curve25519-sha256").?);
    try testing.expectEqual(@as(?KexAlgorithm, null), KexAlgorithm.fromString("invalid"));

    // Signature algorithm
    const sig = SignatureAlgorithm.ssh_ed25519;
    try testing.expectEqualStrings("ssh-ed25519", sig.toString());
    try testing.expectEqual(SignatureAlgorithm.ssh_ed25519, SignatureAlgorithm.fromString("ssh-ed25519").?);
}
