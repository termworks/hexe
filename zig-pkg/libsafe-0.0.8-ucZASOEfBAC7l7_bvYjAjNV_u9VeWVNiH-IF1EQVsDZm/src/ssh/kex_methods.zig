const std = @import("std");
const crypto = std.crypto;

pub const KexError = error{
    InvalidPublicKey,
    InvalidPrivateKey,
    InvalidSignature,
    UnsupportedMethod,
    DowngradeSuspected,
    KeyExchangeFailed,
    OutOfMemory,
};

pub const ExchangeHashTranscriptInput = struct {
    client_id_string: []const u8,
    server_id_string: []const u8,
    client_init_packet: []const u8,
    server_reply_packet: []const u8,
    host_key: []const u8,
    client_public_key: []const u8,
    server_public_key: []const u8,
};

pub const KexMethod = enum {
    curve25519_sha256,
    diffie_hellman_group14_sha256,

    pub fn fromName(method_name: []const u8) ?KexMethod {
        if (std.mem.eql(u8, method_name, "curve25519-sha256")) {
            return .curve25519_sha256;
        } else if (std.mem.eql(u8, method_name, "diffie-hellman-group14-sha256")) {
            return .diffie_hellman_group14_sha256;
        }
        return null;
    }

    pub fn name(self: KexMethod) []const u8 {
        return switch (self) {
            .curve25519_sha256 => "curve25519-sha256",
            .diffie_hellman_group14_sha256 => "diffie-hellman-group14-sha256",
        };
    }

    pub fn hashAlgorithm(self: KexMethod) HashAlgorithm {
        return switch (self) {
            .curve25519_sha256 => .sha256,
            .diffie_hellman_group14_sha256 => .sha256,
        };
    }
};

pub const HashAlgorithm = enum {
    sha256,
    sha384,
    sha512,

    pub fn digestLength(self: HashAlgorithm) usize {
        return switch (self) {
            .sha256 => 32,
            .sha384 => 48,
            .sha512 => 64,
        };
    }
};

pub const KexResult = struct {
    shared_secret: []const u8,
    exchange_hash: []const u8,
    hash_algorithm: HashAlgorithm,

    pub fn deinit(self: *KexResult, allocator: std.mem.Allocator) void {
        allocator.free(self.shared_secret);
        allocator.free(self.exchange_hash);
    }
};

pub const KexState = struct {
    method: KexMethod,
    is_client: bool,
    curve25519_private: ?[32]u8 = null,
    curve25519_public: ?[32]u8 = null,
    peer_public_key: ?[]const u8 = null,
    client_id_string: []const u8,
    server_id_string: []const u8,
    client_init_packet: []const u8,
    server_reply_packet: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        method: KexMethod,
        is_client: bool,
        client_id: []const u8,
        server_id: []const u8,
        client_init: []const u8,
        server_reply: []const u8,
    ) KexState {
        return .{
            .method = method,
            .is_client = is_client,
            .allocator = allocator,
            .client_id_string = client_id,
            .server_id_string = server_id,
            .client_init_packet = client_init,
            .server_reply_packet = server_reply,
        };
    }

    pub fn generateKeyPair(self: *KexState) KexError![]const u8 {
        switch (self.method) {
            .curve25519_sha256 => {
                var private: [32]u8 = undefined;
                crypto.random.bytes(&private);
                const public = crypto.dh.X25519.recoverPublicKey(private) catch return error.KeyExchangeFailed;
                self.curve25519_private = private;
                self.curve25519_public = public;
                return self.allocator.dupe(u8, &public);
            },
            .diffie_hellman_group14_sha256 => return error.UnsupportedMethod,
        }
    }

    pub fn setPeerPublicKey(self: *KexState, peer_key: []const u8) KexError!void {
        if (peer_key.len != 32 and self.method == .curve25519_sha256) return error.InvalidPublicKey;
        self.peer_public_key = try self.allocator.dupe(u8, peer_key);
    }

    pub fn computeSharedSecret(self: *KexState) KexError![]const u8 {
        switch (self.method) {
            .curve25519_sha256 => {
                if (self.curve25519_private == null) return error.InvalidPrivateKey;
                if (self.peer_public_key == null or self.peer_public_key.?.len != 32) return error.InvalidPublicKey;

                const peer_key: [32]u8 = self.peer_public_key.?[0..32].*;
                const shared_secret = crypto.dh.X25519.scalarmult(self.curve25519_private.?, peer_key) catch return error.KeyExchangeFailed;
                return self.allocator.dupe(u8, &shared_secret);
            },
            .diffie_hellman_group14_sha256 => return error.UnsupportedMethod,
        }
    }

    pub fn computeExchangeHash(self: *KexState, host_key: []const u8) KexError![]const u8 {
        const hash_alg = self.method.hashAlgorithm();
        const maybe_client_public_key: ?[]const u8 = if (self.is_client)
            if (self.curve25519_public) |pub_key| &pub_key else null
        else
            self.peer_public_key;

        const maybe_server_public_key: ?[]const u8 = if (self.is_client)
            self.peer_public_key
        else if (self.curve25519_public) |pub_key| &pub_key else null;

        if (maybe_client_public_key == null or maybe_server_public_key == null) {
            return error.InvalidPublicKey;
        }

        const transcript = try assemble_exchange_hash_transcript(self.allocator, .{
            .client_id_string = self.client_id_string,
            .server_id_string = self.server_id_string,
            .client_init_packet = self.client_init_packet,
            .server_reply_packet = self.server_reply_packet,
            .host_key = host_key,
            .client_public_key = maybe_client_public_key.?,
            .server_public_key = maybe_server_public_key.?,
        });
        defer self.allocator.free(transcript);

        const digest_len = hash_alg.digestLength();
        const digest = try self.allocator.alloc(u8, digest_len);

        switch (hash_alg) {
            .sha256 => crypto.hash.sha2.Sha256.hash(transcript, digest[0..32], .{}),
            .sha384 => crypto.hash.sha2.Sha384.hash(transcript, digest[0..48], .{}),
            .sha512 => crypto.hash.sha2.Sha512.hash(transcript, digest[0..64], .{}),
        }

        return digest;
    }

    pub fn performKeyExchange(self: *KexState, host_key: []const u8) KexError!KexResult {
        const shared_secret = try self.computeSharedSecret();
        errdefer self.allocator.free(shared_secret);

        const exchange_hash = try self.computeExchangeHash(host_key);
        errdefer self.allocator.free(exchange_hash);

        return .{
            .shared_secret = shared_secret,
            .exchange_hash = exchange_hash,
            .hash_algorithm = self.method.hashAlgorithm(),
        };
    }

    pub fn deinit(self: *KexState) void {
        if (self.peer_public_key) |key| self.allocator.free(key);
        if (self.curve25519_private) |*priv| @memset(priv, 0);
    }
};

pub fn assemble_exchange_hash_transcript(
    allocator: std.mem.Allocator,
    input: ExchangeHashTranscriptInput,
) KexError![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);

    try out.appendSlice(allocator, input.client_id_string);
    try out.appendSlice(allocator, input.server_id_string);
    try out.appendSlice(allocator, input.client_init_packet);
    try out.appendSlice(allocator, input.server_reply_packet);
    try out.appendSlice(allocator, input.host_key);
    try out.appendSlice(allocator, input.client_public_key);
    try out.appendSlice(allocator, input.server_public_key);

    return out.toOwnedSlice(allocator);
}

pub fn negotiate_kex_method(
    client_proposed_methods: []const []const u8,
    server_supported_methods: []const []const u8,
) KexError!KexMethod {
    for (client_proposed_methods) |name| {
        const method = KexMethod.fromName(name) orelse continue;
        if (contains_method_name(server_supported_methods, name)) {
            return method;
        }
    }
    return error.UnsupportedMethod;
}

pub fn validate_negotiated_kex_method(
    client_proposed_methods: []const []const u8,
    server_supported_methods: []const []const u8,
    selected_method_name: []const u8,
) KexError!KexMethod {
    const selected_method = KexMethod.fromName(selected_method_name) orelse return error.UnsupportedMethod;
    if (!contains_method_name(client_proposed_methods, selected_method_name)) return error.UnsupportedMethod;
    if (!contains_method_name(server_supported_methods, selected_method_name)) return error.UnsupportedMethod;

    const expected_method = try negotiate_kex_method(client_proposed_methods, server_supported_methods);
    if (selected_method != expected_method) return error.DowngradeSuspected;
    return selected_method;
}

fn contains_method_name(methods: []const []const u8, method_name: []const u8) bool {
    for (methods) |candidate| {
        if (std.mem.eql(u8, candidate, method_name)) return true;
    }
    return false;
}

test "Curve25519 shared secret computation" {
    const allocator = std.testing.allocator;

    var client_state = KexState.init(allocator, .curve25519_sha256, true, "client-id", "server-id", "init", "reply");
    defer client_state.deinit();
    const client_public = try client_state.generateKeyPair();
    defer allocator.free(client_public);

    var server_state = KexState.init(allocator, .curve25519_sha256, false, "client-id", "server-id", "init", "reply");
    defer server_state.deinit();
    const server_public = try server_state.generateKeyPair();
    defer allocator.free(server_public);

    try client_state.setPeerPublicKey(server_public);
    try server_state.setPeerPublicKey(client_public);

    const client_secret = try client_state.computeSharedSecret();
    defer allocator.free(client_secret);
    const server_secret = try server_state.computeSharedSecret();
    defer allocator.free(server_secret);

    try std.testing.expectEqualSlices(u8, client_secret, server_secret);
}

test "assemble exchange hash transcript is deterministic" {
    const allocator = std.testing.allocator;
    const input = ExchangeHashTranscriptInput{
        .client_id_string = "SSH-2.0-client",
        .server_id_string = "SSH-2.0-server",
        .client_init_packet = "kexinit-client",
        .server_reply_packet = "kexinit-server",
        .host_key = "host-key",
        .client_public_key = "client-ephemeral",
        .server_public_key = "server-ephemeral",
    };

    const a = try assemble_exchange_hash_transcript(allocator, input);
    defer allocator.free(a);
    const b = try assemble_exchange_hash_transcript(allocator, input);
    defer allocator.free(b);

    try std.testing.expectEqualSlices(u8, a, b);
}

test "negotiate kex method selects first common client preference" {
    const client_methods = [_][]const u8{ "curve25519-sha256", "diffie-hellman-group14-sha256" };
    const server_methods = [_][]const u8{ "diffie-hellman-group14-sha256", "curve25519-sha256" };
    const selected = try negotiate_kex_method(&client_methods, &server_methods);
    try std.testing.expectEqual(KexMethod.curve25519_sha256, selected);
}

test "validate negotiated kex method rejects downgrade" {
    const client_methods = [_][]const u8{ "curve25519-sha256", "diffie-hellman-group14-sha256" };
    const server_methods = [_][]const u8{ "curve25519-sha256", "diffie-hellman-group14-sha256" };
    try std.testing.expectError(
        error.DowngradeSuspected,
        validate_negotiated_kex_method(&client_methods, &server_methods, "diffie-hellman-group14-sha256"),
    );
}

test "validate negotiated kex method rejects unsupported selection" {
    const client_methods = [_][]const u8{"curve25519-sha256"};
    const server_methods = [_][]const u8{"curve25519-sha256"};
    try std.testing.expectError(
        error.UnsupportedMethod,
        validate_negotiated_kex_method(&client_methods, &server_methods, "sntrup761x25519-sha512"),
    );
}

test "negotiate kex method rejects when no common supported method" {
    const client_methods = [_][]const u8{ "unknown-kex", "weird-kex" };
    const server_methods = [_][]const u8{"curve25519-sha256"};
    try std.testing.expectError(error.UnsupportedMethod, negotiate_kex_method(&client_methods, &server_methods));
}

test "validate negotiated kex method accepts expected selection" {
    const client_methods = [_][]const u8{ "curve25519-sha256", "diffie-hellman-group14-sha256" };
    const server_methods = [_][]const u8{"curve25519-sha256"};
    const selected = try validate_negotiated_kex_method(&client_methods, &server_methods, "curve25519-sha256");
    try std.testing.expectEqual(KexMethod.curve25519_sha256, selected);
}

test "compute exchange hash requires both ephemeral public keys" {
    const allocator = std.testing.allocator;

    var state = KexState.init(allocator, .curve25519_sha256, true, "client-id", "server-id", "init", "reply");
    defer state.deinit();

    const pub_key = try state.generateKeyPair();
    defer allocator.free(pub_key);
    try std.testing.expectError(error.InvalidPublicKey, state.computeExchangeHash("host-key"));
}
