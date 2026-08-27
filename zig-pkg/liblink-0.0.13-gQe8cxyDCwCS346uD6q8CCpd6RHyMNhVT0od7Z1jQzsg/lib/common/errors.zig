const std = @import("std");

/// Protocol-level errors for SSH/QUIC operations
pub const ProtocolError = error{
    /// Invalid packet format or encoding
    InvalidPacketFormat,
    /// Packet size exceeds maximum allowed
    PacketTooLarge,
    /// Packet size below minimum required
    PacketTooSmall,
    /// Invalid SSH message type
    InvalidMessageType,
    /// Unsupported SSH protocol version
    UnsupportedVersion,
    /// No common QUIC version between client and server
    NoCommonQuicVersion,
    /// No common key exchange algorithm
    NoCommonKexAlgorithm,
    /// No common signature algorithm
    NoCommonSignatureAlgorithm,
    /// No common cipher suite
    NoCommonCipherSuite,
    /// Invalid obfuscated envelope (bad tag)
    InvalidObfuscatedEnvelope,
    /// Invalid extension pair
    InvalidExtension,
    /// Server sent error reply during key exchange
    KeyExchangeError,
    /// Connection was cancelled
    ConnectionCancelled,
};

/// Cryptographic operation errors
pub const CryptoError = error{
    /// Key generation failed
    KeyGenerationFailed,
    /// Invalid key format or size
    InvalidKey,
    /// Signature verification failed
    SignatureVerificationFailed,
    /// Signature generation failed
    SignatureGenerationFailed,
    /// AEAD encryption failed
    EncryptionFailed,
    /// AEAD decryption failed
    DecryptionFailed,
    /// Authentication tag mismatch
    AuthenticationFailed,
    /// Invalid nonce
    InvalidNonce,
    /// Hash computation failed
    HashFailed,
    /// Key derivation failed
    KeyDerivationFailed,
    /// ECDH key exchange failed
    KeyExchangeFailed,
    /// Random number generation failed
    RandomGenerationFailed,
};

/// Connection-level errors
pub const ConnectionError = error{
    /// Connection to remote host failed
    ConnectionFailed,
    /// Connection timeout
    ConnectionTimeout,
    /// Connection was closed by peer
    ConnectionClosed,
    /// Connection reset
    ConnectionReset,
    /// Invalid connection state for operation
    InvalidState,
    /// Remote host is unreachable
    HostUnreachable,
    /// Network error occurred
    NetworkError,
    /// QUIC stream error
    StreamError,
    /// QUIC connection error
    QuicError,
};

/// Authentication errors
pub const AuthenticationError = error{
    /// Authentication failed
    AuthenticationFailed,
    /// Invalid credentials provided
    InvalidCredentials,
    /// Unsupported authentication method
    UnsupportedAuthMethod,
    /// Too many authentication attempts
    TooManyAttempts,
    /// Host key verification failed
    HostKeyVerificationFailed,
    /// Host key not found in known_hosts
    HostKeyNotFound,
    /// Host key mismatch (different from known_hosts)
    HostKeyMismatch,
    /// Invalid host key format
    InvalidHostKey,
    /// Private key file not found
    PrivateKeyNotFound,
    /// Invalid private key format
    InvalidPrivateKey,
    /// Private key is encrypted and no passphrase provided
    PrivateKeyEncrypted,
};

/// SFTP protocol errors
pub const SftpError = error{
    /// SFTP initialization failed
    InitializationFailed,
    /// Unsupported SFTP version
    UnsupportedVersion,
    /// File not found on remote
    FileNotFound,
    /// Permission denied
    PermissionDenied,
    /// Invalid file handle
    InvalidHandle,
    /// End of file reached
    EndOfFile,
    /// Remote path does not exist
    NoSuchPath,
    /// Path already exists
    PathAlreadyExists,
    /// Operation not supported
    OperationNotSupported,
    /// Invalid SFTP packet
    InvalidPacket,
    /// SFTP request failed
    RequestFailed,
    /// Directory not empty
    DirectoryNotEmpty,
    /// Not a directory
    NotADirectory,
    /// Is a directory (when file expected)
    IsADirectory,
};

/// Channel errors
pub const ChannelError = error{
    /// Channel open failed
    OpenFailed,
    /// Channel request failed
    RequestFailed,
    /// Channel is closed
    ChannelClosed,
    /// Invalid channel type
    InvalidChannelType,
    /// Channel not found
    ChannelNotFound,
    /// Maximum packet size exceeded
    PacketSizeExceeded,
    /// EOF received on channel
    EndOfFile,
};

/// Wire encoding/decoding errors
pub const WireError = error{
    /// Buffer too small for encoding
    BufferTooSmall,
    /// End of buffer reached during decoding
    EndOfBuffer,
    /// Invalid wire encoding format
    InvalidEncoding,
    /// Invalid string (bad UTF-8 or length)
    InvalidString,
    /// Invalid mpint (multi-precision integer) format
    InvalidMpint,
    /// Value out of valid range
    OutOfRange,
};

/// Combined error set for all SSH/QUIC operations
pub const Error = ProtocolError ||
    CryptoError ||
    ConnectionError ||
    AuthenticationError ||
    SftpError ||
    ChannelError ||
    WireError ||
    std.mem.Allocator.Error;

/// Convert error to human-readable description
pub fn errorDescription(err: Error) []const u8 {
    return switch (err) {
        // Protocol errors
        error.InvalidPacketFormat => "Invalid packet format or encoding",
        error.PacketTooLarge => "Packet size exceeds maximum allowed",
        error.PacketTooSmall => "Packet size below minimum required",
        error.InvalidMessageType => "Invalid SSH message type",
        error.UnsupportedVersion => "Unsupported SSH protocol version",
        error.NoCommonQuicVersion => "No common QUIC version with peer",
        error.NoCommonKexAlgorithm => "No common key exchange algorithm",
        error.NoCommonSignatureAlgorithm => "No common signature algorithm",
        error.NoCommonCipherSuite => "No common cipher suite",
        error.InvalidObfuscatedEnvelope => "Invalid obfuscated envelope",
        error.InvalidExtension => "Invalid extension pair",
        error.KeyExchangeError => "Key exchange failed",
        error.ConnectionCancelled => "Connection was cancelled",

        // Crypto errors
        error.KeyGenerationFailed => "Cryptographic key generation failed",
        error.InvalidKey => "Invalid cryptographic key",
        error.SignatureVerificationFailed => "Signature verification failed",
        error.SignatureGenerationFailed => "Signature generation failed",
        error.EncryptionFailed => "Encryption operation failed",
        error.DecryptionFailed => "Decryption operation failed",
        error.AuthenticationFailed => "Authentication tag verification failed",
        error.InvalidNonce => "Invalid nonce value",
        error.HashFailed => "Hash computation failed",
        error.KeyDerivationFailed => "Key derivation failed",
        error.KeyExchangeFailed => "Key exchange operation failed",
        error.RandomGenerationFailed => "Random number generation failed",

        // Connection errors
        error.ConnectionFailed => "Failed to establish connection",
        error.ConnectionTimeout => "Connection attempt timed out",
        error.ConnectionClosed => "Connection closed by peer",
        error.ConnectionReset => "Connection was reset",
        error.InvalidState => "Invalid connection state for this operation",
        error.HostUnreachable => "Remote host is unreachable",
        error.NetworkError => "Network error occurred",
        error.StreamError => "QUIC stream error",
        error.QuicError => "QUIC connection error",

        // Authentication errors
        error.InvalidCredentials => "Invalid authentication credentials",
        error.UnsupportedAuthMethod => "Authentication method not supported",
        error.TooManyAttempts => "Too many authentication attempts",
        error.HostKeyVerificationFailed => "Host key verification failed",
        error.HostKeyNotFound => "Host key not found in known_hosts",
        error.HostKeyMismatch => "Host key does not match known_hosts",
        error.InvalidHostKey => "Invalid host key format",
        error.PrivateKeyNotFound => "Private key file not found",
        error.InvalidPrivateKey => "Invalid private key format",
        error.PrivateKeyEncrypted => "Private key is encrypted",

        // SFTP errors
        error.InitializationFailed => "SFTP initialization failed",
        error.FileNotFound => "File not found",
        error.PermissionDenied => "Permission denied",
        error.InvalidHandle => "Invalid file handle",
        error.EndOfFile => "End of file reached",
        error.NoSuchPath => "Path does not exist",
        error.PathAlreadyExists => "Path already exists",
        error.OperationNotSupported => "Operation not supported",
        error.InvalidPacket => "Invalid SFTP packet",
        error.RequestFailed => "SFTP request failed",
        error.DirectoryNotEmpty => "Directory is not empty",
        error.NotADirectory => "Not a directory",
        error.IsADirectory => "Is a directory",

        // Channel errors
        error.OpenFailed => "Channel open failed",
        error.ChannelClosed => "Channel is closed",
        error.InvalidChannelType => "Invalid channel type",
        error.ChannelNotFound => "Channel not found",
        error.PacketSizeExceeded => "Packet size exceeded maximum",

        // Wire errors
        error.BufferTooSmall => "Buffer too small for encoding",
        error.EndOfBuffer => "End of buffer reached",
        error.InvalidEncoding => "Invalid wire encoding format",
        error.InvalidString => "Invalid string encoding",
        error.InvalidMpint => "Invalid multi-precision integer",
        error.OutOfRange => "Value out of valid range",

        // Memory errors
        error.OutOfMemory => "Out of memory",
    };
}

test "error descriptions" {
    const testing = std.testing;

    // Test a few error descriptions
    try testing.expectEqualStrings(
        "Invalid packet format or encoding",
        errorDescription(error.InvalidPacketFormat)
    );

    try testing.expectEqualStrings(
        "No common QUIC version with peer",
        errorDescription(error.NoCommonQuicVersion)
    );

    try testing.expectEqualStrings(
        "File not found",
        errorDescription(error.FileNotFound)
    );
}
