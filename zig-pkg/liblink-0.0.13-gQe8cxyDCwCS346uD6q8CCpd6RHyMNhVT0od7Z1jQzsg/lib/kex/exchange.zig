const std = @import("std");
const Allocator = std.mem.Allocator;

// Import protocol components
const kex_init = @import("../protocol/kex_init.zig");
const kex_reply = @import("../protocol/kex_reply.zig");
const kex_curve25519 = @import("../protocol/kex_curve25519.zig");
const shared_secrets = @import("shared_secrets.zig");
const constants = @import("../common/constants.zig");
const libfast = @import("libfast");

pub const ClientKexResult = struct {
    client_secret: [32]u8,
    server_secret: [32]u8,
    client_connection_id: []const u8,
    server_connection_id: []const u8,
};

pub const ServerKexResult = struct {
    reply_data: []u8,
    client_secret: [32]u8,
    server_secret: [32]u8,
    client_connection_id: []const u8,
    server_connection_id: []const u8,
};

/// Client key exchange state machine
pub const ClientKeyExchange = struct {
    allocator: Allocator,
    random: std.Random,
    ephemeral_key: kex_curve25519.ClientEphemeralKey,
    init_message: ?kex_init.SshQuicInit,
    init_message_encoded: ?[]u8, // Save original encoded bytes for exchange hash
    reply_message: ?kex_reply.SshQuicReply,
    server_host_key_fingerprint: ?[]u8,
    shared_secret: ?[32]u8,
    exchange_hash: ?[]u8,

    const Self = @This();

    /// Initialize client key exchange
    pub fn init(allocator: Allocator, random: std.Random) !Self {
        const ephemeral_key = try kex_curve25519.ClientEphemeralKey.generate(random);

        return Self{
            .allocator = allocator,
            .random = random,
            .ephemeral_key = ephemeral_key,
            .init_message = null,
            .init_message_encoded = null,
            .reply_message = null,
            .server_host_key_fingerprint = null,
            .shared_secret = null,
            .exchange_hash = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.shared_secret) |*secret| {
            std.crypto.secureZero(u8, secret);
        }
        std.crypto.secureZero(u8, &self.ephemeral_key.private_key);
        if (self.init_message) |*msg| {
            msg.deinit(self.allocator);
        }
        if (self.init_message_encoded) |encoded| {
            self.allocator.free(encoded);
        }
        if (self.reply_message) |*msg| {
            msg.deinit(self.allocator);
        }
        if (self.server_host_key_fingerprint) |fp| {
            self.allocator.free(fp);
        }
        if (self.exchange_hash) |hash| {
            self.allocator.free(hash);
        }
    }

    /// Create SSH_QUIC_INIT message
    ///
    /// Parameters:
    /// - server_name: Optional server name indication (SNI)
    /// - quic_versions: List of supported QUIC versions
    /// - quic_params: QUIC transport parameters
    pub fn createInit(
        self: *Self,
        server_name: []const u8,
        quic_versions: []const u32,
        quic_params: []const u8,
        trusted_fingerprints: []const []const u8,
    ) ![]u8 {
        // Encode client ephemeral key data
        const client_kex_data = try self.ephemeral_key.encodeClientData(self.allocator);
        defer self.allocator.free(client_kex_data);

        // Generate client connection ID (QUIC requires both sides have one)
        const client_conn_id = try generateConnectionId(self.random, self.allocator);
        defer self.allocator.free(client_conn_id);

        // Create SSH_QUIC_INIT message
        const init_msg = kex_init.SshQuicInit{
            .client_connection_id = client_conn_id,
            .server_name_indication = server_name,
            .client_quic_versions = quic_versions,
            .client_quic_trnsp_params = quic_params,
            .client_sig_algs = constants.DEFAULT_SIG_ALGS,
            .trusted_fingerprints = trusted_fingerprints,
            .client_kex_algs = &[_]kex_init.KexAlgorithm{
                .{
                    .name = constants.KEX_CURVE25519_SHA256,
                    .data = client_kex_data,
                },
            },
            .quic_tls_cipher_suites = &[_][]const u8{constants.DEFAULT_CIPHER_SUITE},
            .ext_pairs = &[_]kex_init.ExtensionPair{},
        };

        // Encode the message
        const encoded = try init_msg.encode(self.allocator);

        // Save both the struct and the encoded bytes for exchange hash calculation
        self.init_message = try duplicateInit(&init_msg, self.allocator);
        self.init_message_encoded = try self.allocator.dupe(u8, encoded);

        return encoded;
    }

    /// Process SSH_QUIC_REPLY message
    ///
    /// Returns: (client_secret, server_secret) for QUIC initialization
    pub fn processReply(
        self: *Self,
        reply_data: []const u8,
    ) !ClientKexResult {
        // Decode SSH_QUIC_REPLY
        var reply = try kex_reply.SshQuicReply.decode(self.allocator, reply_data);
        errdefer reply.deinit(self.allocator);

        // Check for error reply
        if (reply.isErrorReply()) {
            const reason = reply.getDiscReason() orelse 0;
            const desc = reply.getErrorDesc() orelse "Unknown error";
            std.log.err("Server rejected key exchange: code={}, desc={s}", .{ reason, desc });
            return error.ServerRejectedKeyExchange;
        }

        // Decode server ephemeral key data
        const server_data = try kex_curve25519.ServerEphemeralKey.decodeServerData(
            self.allocator,
            reply.server_kex_alg_data,
        );
        defer {
            self.allocator.free(server_data.host_key);
            self.allocator.free(server_data.signature);
        }

        // Calculate shared secret K
        const shared_secret = try kex_curve25519.calculateSharedSecret(
            &self.ephemeral_key.private_key,
            &server_data.public_key,
        );

        // Use the original encoded init message (don't re-encode!)
        const init_encoded = self.init_message_encoded.?;

        // Encode reply content without kex data for hash calculation
        const reply_without_kex = try encodeReplyWithoutKex(&reply, self.allocator);
        defer self.allocator.free(reply_without_kex);

        // Calculate exchange hash H
        const exchange_hash = try kex_curve25519.calculateExchangeHash(
            self.allocator,
            init_encoded,
            reply_without_kex,
            server_data.host_key,
            &self.ephemeral_key.public_key,
            &server_data.public_key,
            &shared_secret,
        );
        errdefer self.allocator.free(exchange_hash);

        // Verify server signature over exchange hash
        try verifyServerSignature(
            exchange_hash,
            server_data.signature,
            server_data.host_key,
        );

        const host_fingerprint = try computeHostKeyFingerprint(self.allocator, server_data.host_key);
        errdefer self.allocator.free(host_fingerprint);

        // Verify server host key against trusted fingerprint set (if configured)
        try verifyTrustedHostKey(
            self.allocator,
            server_data.host_key,
            self.init_message.?.trusted_fingerprints,
        );

        // Derive QUIC secrets
        const quic_secrets = try shared_secrets.deriveQuicSecrets(
            &shared_secret,
            exchange_hash,
            self.allocator,
        );

        // Save state
        self.shared_secret = shared_secret;
        self.exchange_hash = exchange_hash;
        self.reply_message = reply;
        self.server_host_key_fingerprint = host_fingerprint;

        return .{
            .client_secret = quic_secrets.client_secret,
            .server_secret = quic_secrets.server_secret,
            .client_connection_id = reply.client_connection_id,
            .server_connection_id = reply.server_connection_id,
        };
    }

    /// Get exchange hash (session identifier for authentication)
    ///
    /// Must be called after processReply() has completed successfully.
    pub fn getExchangeHash(self: *const Self) []const u8 {
        return self.exchange_hash orelse &[_]u8{};
    }

    pub fn getServerHostKeyFingerprint(self: *const Self) []const u8 {
        return self.server_host_key_fingerprint orelse &[_]u8{};
    }
};

/// Server key exchange state machine
pub const ServerKeyExchange = struct {
    allocator: Allocator,
    random: std.Random,
    ephemeral_key: ?kex_curve25519.ServerEphemeralKey,
    init_message: ?kex_init.SshQuicInit,
    server_connection_id: ?[]u8,
    shared_secret: ?[32]u8,
    exchange_hash: ?[]u8,

    const Self = @This();

    pub fn init(allocator: Allocator, random: std.Random) Self {
        return Self{
            .allocator = allocator,
            .random = random,
            .ephemeral_key = null,
            .init_message = null,
            .server_connection_id = null,
            .shared_secret = null,
            .exchange_hash = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.shared_secret) |*secret| {
            std.crypto.secureZero(u8, secret);
        }
        if (self.ephemeral_key) |*ek| {
            std.crypto.secureZero(u8, &ek.private_key);
        }
        if (self.init_message) |*msg| {
            msg.deinit(self.allocator);
        }
        if (self.server_connection_id) |conn_id| {
            self.allocator.free(conn_id);
        }
        if (self.exchange_hash) |hash| {
            self.allocator.free(hash);
        }
    }

    /// Process SSH_QUIC_INIT and create SSH_QUIC_REPLY
    ///
    /// Parameters:
    /// - init_data: Encoded SSH_QUIC_INIT message
    /// - quic_versions: Supported QUIC versions
    /// - quic_params: Server QUIC transport parameters
    /// - host_key: Server host key (Ed25519 public key)
    /// - host_private_key: Server host private key (for signing)
    ///
    /// Returns: (reply_data, client_secret, server_secret)
    pub fn processInitAndCreateReply(
        self: *Self,
        init_data: []const u8,
        quic_versions: []const u32,
        quic_params: []const u8,
        host_key: []const u8,
        host_private_key: *const [64]u8,
    ) !ServerKexResult {
        // Decode SSH_QUIC_INIT
        var init_msg = try kex_init.SshQuicInit.decode(self.allocator, init_data);
        errdefer init_msg.deinit(self.allocator);

        // Validate init message
        if (init_msg.client_kex_algs.len == 0) {
            return error.NoKeyExchangeAlgorithms;
        }

        // Find curve25519-sha256 in client's kex algorithms
        var client_kex_data: ?[]const u8 = null;
        for (init_msg.client_kex_algs) |kex| {
            if (std.mem.eql(u8, kex.name, constants.KEX_CURVE25519_SHA256)) {
                client_kex_data = kex.data;
                break;
            }
        }

        if (client_kex_data == null) {
            return error.UnsupportedKeyExchangeAlgorithm;
        }

        // Decode client ephemeral key
        const client_ephemeral = try kex_curve25519.ClientEphemeralKey.decodeClientData(
            self.allocator,
            client_kex_data.?,
        );

        // Generate server ephemeral key
        const server_ephemeral = try kex_curve25519.ServerEphemeralKey.generate(self.random);

        // Calculate shared secret K
        const shared_secret = try kex_curve25519.calculateSharedSecret(
            &server_ephemeral.private_key,
            &client_ephemeral.public_key,
        );

        // Generate server connection ID (needed for exchange hash)
        const server_conn_id = try generateConnectionId(self.random, self.allocator);

        // Encode reply content without kex data for hash calculation
        const reply_without_kex = try encodeReplyWithoutKexFromParams(
            self.allocator,
            &init_msg,
            server_conn_id,
            quic_versions,
            quic_params,
        );
        defer self.allocator.free(reply_without_kex);

        // Calculate exchange hash H
        const exchange_hash = try kex_curve25519.calculateExchangeHash(
            self.allocator,
            init_data,
            reply_without_kex,
            host_key,
            &client_ephemeral.public_key,
            &server_ephemeral.public_key,
            &shared_secret,
        );
        errdefer self.allocator.free(exchange_hash);

        // Sign exchange hash with server host key
        const signature = try signExchangeHash(exchange_hash, host_private_key, self.allocator);
        defer self.allocator.free(signature);

        // Encode server kex data
        const server_kex_data = try server_ephemeral.encodeServerData(
            self.allocator,
            host_key,
            signature,
        );
        defer self.allocator.free(server_kex_data);

        // Create SSH_QUIC_REPLY
        const reply = kex_reply.SshQuicReply{
            .client_connection_id = init_msg.client_connection_id,
            .server_connection_id = server_conn_id,
            .server_quic_versions = quic_versions,
            .server_quic_trnsp_params = quic_params,
            .server_sig_algs = constants.DEFAULT_SIG_ALGS,
            .server_kex_algs = constants.KEX_CURVE25519_SHA256,
            .quic_tls_cipher_suites = &[_][]const u8{constants.DEFAULT_CIPHER_SUITE},
            .ext_pairs = &[_]kex_reply.ExtensionPair{},
            .server_kex_alg_data = server_kex_data,
        };

        // Encode reply
        const reply_data = try reply.encode(self.allocator);

        // Derive QUIC secrets
        const quic_secrets = try shared_secrets.deriveQuicSecrets(
            &shared_secret,
            exchange_hash,
            self.allocator,
        );

        // Save state
        self.ephemeral_key = server_ephemeral;
        self.init_message = init_msg;
        self.server_connection_id = server_conn_id;
        self.shared_secret = shared_secret;
        self.exchange_hash = exchange_hash;

        return .{
            .reply_data = reply_data,
            .client_secret = quic_secrets.client_secret,
            .server_secret = quic_secrets.server_secret,
            .client_connection_id = self.init_message.?.client_connection_id,
            .server_connection_id = server_conn_id,
        };
    }

    /// Get exchange hash (session identifier for authentication)
    ///
    /// Must be called after processInitAndCreateReply() has completed successfully.
    pub fn getExchangeHash(self: *const Self) []const u8 {
        return self.exchange_hash orelse &[_]u8{};
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Generate cryptographically random connection ID
///
/// QUIC connection IDs must be 4-20 bytes. We use 8 bytes for good balance
/// between uniqueness and overhead.
fn generateConnectionId(random: std.Random, allocator: Allocator) ![]u8 {
    const conn_id_len = 8; // 8 bytes = 64 bits of randomness
    const conn_id = try allocator.alloc(u8, conn_id_len);
    random.bytes(conn_id);
    return conn_id;
}

/// Duplicate SSH_QUIC_INIT for storage
fn duplicateInit(init: *const kex_init.SshQuicInit, allocator: Allocator) !kex_init.SshQuicInit {
    const client_conn_id = try allocator.dupe(u8, init.client_connection_id);
    errdefer allocator.free(client_conn_id);

    const server_name = try allocator.dupe(u8, init.server_name_indication);
    errdefer allocator.free(server_name);

    const quic_versions = try allocator.dupe(u32, init.client_quic_versions);
    errdefer allocator.free(quic_versions);

    const quic_params = try allocator.dupe(u8, init.client_quic_trnsp_params);
    errdefer allocator.free(quic_params);

    const sig_algs = try allocator.dupe(u8, init.client_sig_algs);
    errdefer allocator.free(sig_algs);

    // Copy trusted fingerprints
    const fingerprints = try allocator.alloc([]const u8, init.trusted_fingerprints.len);
    errdefer allocator.free(fingerprints);

    for (init.trusted_fingerprints, 0..) |fp, i| {
        fingerprints[i] = try allocator.dupe(u8, fp);
    }

    // Copy kex algorithms
    const kex_algs = try allocator.alloc(kex_init.KexAlgorithm, init.client_kex_algs.len);
    errdefer allocator.free(kex_algs);

    for (init.client_kex_algs, 0..) |kex, i| {
        kex_algs[i] = .{
            .name = try allocator.dupe(u8, kex.name),
            .data = try allocator.dupe(u8, kex.data),
        };
    }

    // Copy cipher suites
    const cipher_suites = try allocator.alloc([]const u8, init.quic_tls_cipher_suites.len);
    errdefer allocator.free(cipher_suites);

    for (init.quic_tls_cipher_suites, 0..) |suite, i| {
        cipher_suites[i] = try allocator.dupe(u8, suite);
    }

    // Copy extension pairs
    const ext_pairs = try allocator.alloc(kex_init.ExtensionPair, init.ext_pairs.len);
    errdefer allocator.free(ext_pairs);

    for (init.ext_pairs, 0..) |ext, i| {
        ext_pairs[i] = .{
            .name = try allocator.dupe(u8, ext.name),
            .data = try allocator.dupe(u8, ext.data),
        };
    }

    return kex_init.SshQuicInit{
        .client_connection_id = client_conn_id,
        .server_name_indication = server_name,
        .client_quic_versions = quic_versions,
        .client_quic_trnsp_params = quic_params,
        .client_sig_algs = sig_algs,
        .trusted_fingerprints = fingerprints,
        .client_kex_algs = kex_algs,
        .quic_tls_cipher_suites = cipher_suites,
        .ext_pairs = ext_pairs,
    };
}

/// Encode SSH_QUIC_REPLY without server_kex_alg_data (for exchange hash)
fn encodeReplyWithoutKex(reply: *const kex_reply.SshQuicReply, allocator: Allocator) ![]u8 {
    const modified = kex_reply.SshQuicReply{
        .client_connection_id = reply.client_connection_id,
        .server_connection_id = reply.server_connection_id,
        .server_quic_versions = reply.server_quic_versions,
        .server_quic_trnsp_params = reply.server_quic_trnsp_params,
        .server_sig_algs = reply.server_sig_algs,
        .server_kex_algs = reply.server_kex_algs,
        .quic_tls_cipher_suites = reply.quic_tls_cipher_suites,
        .ext_pairs = reply.ext_pairs,
        .server_kex_alg_data = "", // Empty for exchange hash
    };

    return modified.encode(allocator);
}

/// Encode SSH_QUIC_REPLY from parameters (server side, before creating full reply)
fn encodeReplyWithoutKexFromParams(
    allocator: Allocator,
    init: *const kex_init.SshQuicInit,
    server_connection_id: []const u8,
    quic_versions: []const u32,
    quic_params: []const u8,
) ![]u8 {
    const reply = kex_reply.SshQuicReply{
        .client_connection_id = init.client_connection_id,
        .server_connection_id = server_connection_id,
        .server_quic_versions = quic_versions,
        .server_quic_trnsp_params = quic_params,
        .server_sig_algs = constants.DEFAULT_SIG_ALGS,
        .server_kex_algs = constants.KEX_CURVE25519_SHA256,
        .quic_tls_cipher_suites = &[_][]const u8{constants.DEFAULT_CIPHER_SUITE},
        .ext_pairs = &[_]kex_reply.ExtensionPair{},
        .server_kex_alg_data = "",
    };

    return reply.encode(allocator);
}

/// Sign exchange hash with Ed25519
/// Sign exchange hash with Ed25519 host key
///
/// Returns SSH signature blob format: string(algorithm) || string(signature)
fn signExchangeHash(
    exchange_hash: []const u8,
    private_key: *const [64]u8,
    allocator: Allocator,
) ![]u8 {
    const raw_signature = try libfast.ssh_signature.sign(exchange_hash, private_key);
    return libfast.ssh_hostkey.encode_ed25519_signature_blob(allocator, &raw_signature);
}

/// Verify server signature over exchange hash
///
/// Validates the server's Ed25519 signature on the exchange hash using
/// the server's host key.
fn verifyServerSignature(
    exchange_hash: []const u8,
    signature_blob: []const u8,
    host_key_blob: []const u8,
) !void {
    const raw_signature = try decodeSshSignatureBlob(signature_blob);
    const public_key = try decodeSshHostKeyBlob(host_key_blob);

    if (!libfast.ssh_signature.verifyEd25519(exchange_hash, &raw_signature, &public_key)) {
        std.log.err("Server signature verification failed - hash_len={} sig_len={} pubkey_len={}", .{
            exchange_hash.len,
            raw_signature.len,
            public_key.len,
        });
        return error.InvalidSignature;
    }
}

fn verifyTrustedHostKey(
    allocator: Allocator,
    host_key_blob: []const u8,
    trusted_fingerprints: []const []const u8,
) !void {
    if (trusted_fingerprints.len == 0) return;

    const fingerprint = try computeHostKeyFingerprint(allocator, host_key_blob);
    defer allocator.free(fingerprint);

    for (trusted_fingerprints) |trusted| {
        if (std.mem.eql(u8, trusted, fingerprint)) return;
    }

    std.log.warn("Untrusted server host key fingerprint: {s}", .{fingerprint});
    return error.UntrustedHostKey;
}

fn computeHostKeyFingerprint(allocator: Allocator, host_key_blob: []const u8) ![]u8 {
    return libfast.ssh_hostkey.fingerprint_sha256(allocator, host_key_blob);
}

/// Decode SSH signature blob
///
/// Format: string("ssh-ed25519") || string(64-byte signature)
fn decodeSshSignatureBlob(blob: []const u8) ![64]u8 {
    return libfast.ssh_hostkey.decode_ed25519_signature_blob(blob);
}

/// Decode SSH host key blob
///
/// Format: string("ssh-ed25519") || string(32-byte public key)
fn decodeSshHostKeyBlob(blob: []const u8) ![32]u8 {
    return libfast.ssh_hostkey.decode_ed25519_host_key_blob(blob);
}

/// Encode Ed25519 public key as SSH host key blob
///
/// Format: string("ssh-ed25519") || string(32-byte public key)
fn encodeSshHostKey(allocator: Allocator, public_key: *const [32]u8) ![]u8 {
    return libfast.ssh_hostkey.encode_ed25519_host_key_blob(allocator, public_key);
}

// ============================================================================
// Tests
// ============================================================================

test "Ed25519 signature round-trip" {
    const testing = std.testing;

    // Generate a valid Ed25519 keypair
    const Ed25519 = std.crypto.sign.Ed25519;
    const ed_keypair = Ed25519.KeyPair.generate();

    // Convert to our format
    var private_key: [64]u8 = undefined;
    @memcpy(&private_key, &ed_keypair.secret_key.bytes);

    var public_key: [32]u8 = undefined;
    @memcpy(&public_key, &ed_keypair.public_key.bytes);

    // Test data
    const test_data = "Hello, Ed25519!";

    // Sign
    const signature = try libfast.ssh_signature.sign(test_data, &private_key);

    // Verify
    const valid = libfast.ssh_signature.verifyEd25519(test_data, &signature, &public_key);
    try testing.expect(valid);

    // Verify with wrong data should fail
    const wrong_valid = libfast.ssh_signature.verifyEd25519("Wrong data", &signature, &public_key);
    try testing.expect(!wrong_valid);
}

test "ClientKeyExchange - create init" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    var client = try ClientKeyExchange.init(allocator, random);
    defer client.deinit();

    const quic_versions = [_]u32{1};
    const init_data = try client.createInit("example.com", &quic_versions, "", &[_][]const u8{});
    defer allocator.free(init_data);

    // Should be at least minimum size (1200 bytes)
    try testing.expect(init_data.len >= kex_init.min_payload_size);
}

test "Full key exchange - client and server" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(54321);
    const random = prng.random();

    // Client side
    var client = try ClientKeyExchange.init(allocator, random);
    defer client.deinit();

    const quic_versions = [_]u32{1};
    const init_data = try client.createInit("localhost", &quic_versions, "client_params", &[_][]const u8{});
    defer allocator.free(init_data);

    // Server side
    var server = ServerKeyExchange.init(allocator, random);
    defer server.deinit();

    // Generate a valid Ed25519 keypair
    const Ed25519 = std.crypto.sign.Ed25519;
    const ed_keypair = Ed25519.KeyPair.generate();

    // Convert to our format - Ed25519 secret key includes public key in bytes[32..64]
    var host_private_key: [64]u8 = undefined;
    @memcpy(&host_private_key, &ed_keypair.secret_key.bytes);

    // The public key should match what's in secret_key.bytes[32..64]
    var host_public_key: [32]u8 = undefined;
    @memcpy(&host_public_key, &ed_keypair.public_key.bytes);

    // Encode host key as SSH blob: string("ssh-ed25519") || string(public_key)
    const host_key = try encodeSshHostKey(allocator, &host_public_key);
    defer allocator.free(host_key);

    const server_result = try server.processInitAndCreateReply(
        init_data,
        &quic_versions,
        "server_params",
        host_key,
        &host_private_key,
    );
    defer allocator.free(server_result.reply_data);

    // Client processes reply
    const client_result = try client.processReply(server_result.reply_data);

    // Secrets should match
    try testing.expectEqualSlices(u8, &client_result.client_secret, &server_result.client_secret);
    try testing.expectEqualSlices(u8, &client_result.server_secret, &server_result.server_secret);

    // Exchange hashes should match
    try testing.expectEqualSlices(u8, client.exchange_hash.?, server.exchange_hash.?);
}

test "Full key exchange - trusted host fingerprint enforcement" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(98765);
    const random = prng.random();

    const quic_versions = [_]u32{1};

    // Generate server host keypair
    const Ed25519 = std.crypto.sign.Ed25519;
    const ed_keypair = Ed25519.KeyPair.generate();

    var host_private_key: [64]u8 = undefined;
    @memcpy(&host_private_key, &ed_keypair.secret_key.bytes);

    var host_public_key: [32]u8 = undefined;
    @memcpy(&host_public_key, &ed_keypair.public_key.bytes);

    const host_key = try encodeSshHostKey(allocator, &host_public_key);
    defer allocator.free(host_key);

    const trusted_fp = try computeHostKeyFingerprint(allocator, host_key);
    defer allocator.free(trusted_fp);

    // Happy path with trusted fingerprint
    {
        var client_ok = try ClientKeyExchange.init(allocator, random);
        defer client_ok.deinit();

        const init_data = try client_ok.createInit("localhost", &quic_versions, "client_params", &[_][]const u8{trusted_fp});
        defer allocator.free(init_data);

        var server_ok = ServerKeyExchange.init(allocator, random);
        defer server_ok.deinit();

        const server_result = try server_ok.processInitAndCreateReply(
            init_data,
            &quic_versions,
            "server_params",
            host_key,
            &host_private_key,
        );
        defer allocator.free(server_result.reply_data);

        _ = try client_ok.processReply(server_result.reply_data);
    }

    // Failure path with mismatched trusted fingerprint
    {
        var client_bad = try ClientKeyExchange.init(allocator, random);
        defer client_bad.deinit();

        const bad_fp = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        const init_data = try client_bad.createInit("localhost", &quic_versions, "client_params", &[_][]const u8{bad_fp});
        defer allocator.free(init_data);

        var server_bad = ServerKeyExchange.init(allocator, random);
        defer server_bad.deinit();

        const server_result = try server_bad.processInitAndCreateReply(
            init_data,
            &quic_versions,
            "server_params",
            host_key,
            &host_private_key,
        );
        defer allocator.free(server_result.reply_data);

        const result = client_bad.processReply(server_result.reply_data);
        try testing.expectError(error.UntrustedHostKey, result);
    }
}
