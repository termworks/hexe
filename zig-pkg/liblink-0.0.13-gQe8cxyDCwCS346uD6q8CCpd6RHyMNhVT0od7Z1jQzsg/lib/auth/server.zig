const std = @import("std");
const Allocator = std.mem.Allocator;
const userauth = @import("../protocol/userauth.zig");
const libfast = @import("libfast");

/// SSH Authentication Server
///
/// Handles server-side authentication after key exchange is complete.
/// Validates credentials and manages authentication state.
pub const AuthServer = struct {
    allocator: Allocator,
    service_name: []const u8,
    publickey_validator: ?PublicKeyValidator,
    failed_attempts: u32 = 0,
    max_auth_attempts: u32 = 6,

    const Self = @This();

    /// Public key validation callback
    /// Returns true if the public key is authorized for this user
    pub const PublicKeyValidator = *const fn (username: []const u8, algorithm: []const u8, public_key_blob: []const u8) bool;

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .service_name = "ssh-connection",
            .publickey_validator = null,
        };
    }

    /// Set public key validator callback
    pub fn setPublicKeyValidator(self: *Self, validator: PublicKeyValidator) void {
        self.publickey_validator = validator;
    }

    /// Process authentication request from client
    pub fn processRequest(
        self: *Self,
        request_data: []const u8,
        exchange_hash: []const u8,
    ) !AuthResponse {
        if (self.failed_attempts >= self.max_auth_attempts) {
            return error.TooManyAuthAttempts;
        }

        var request = try userauth.UserauthRequest.decode(self.allocator, request_data);
        defer request.deinit(self.allocator);

        // Verify service name
        if (!std.mem.eql(u8, request.service_name, self.service_name)) {
            self.failed_attempts += 1;
            return self.createFailure(&[_][]const u8{}, false);
        }

        // Handle authentication methods
        if (std.mem.eql(u8, request.method_name, "none")) {
            // "none" method - return available methods
            return self.createFailure(&[_][]const u8{"publickey"}, false);
        } else if (std.mem.eql(u8, request.method_name, "publickey")) {
            const response = try self.handlePublicKeyAuth(
                request.username,
                request.method_data.publickey,
                exchange_hash,
                request_data,
            );
            if (!response.success and response.data.len > 0 and response.data[0] != 60) {
                // Count failures (but not PK_OK queries which have type 60)
                self.failed_attempts += 1;
            }
            return response;
        } else {
            // Unknown method
            self.failed_attempts += 1;
            return self.createFailure(&[_][]const u8{"publickey"}, false);
        }
    }

    /// Handle public key authentication
    fn handlePublicKeyAuth(
        self: *Self,
        username: []const u8,
        pk_data: userauth.UserauthRequest.PublicKeyData,
        exchange_hash: []const u8,
        _: []const u8, // original_request - not needed
    ) !AuthResponse {
        // Check if public key is authorized
        const is_authorized = if (self.publickey_validator) |validator|
            validator(username, pk_data.algorithm_name, pk_data.public_key_blob)
        else
            false;

        if (!is_authorized) {
            return self.createFailure(&[_][]const u8{"publickey"}, false);
        }

        // If no signature provided, this is a query - respond with success indicator
        // (client will retry with signature)
        if (pk_data.signature == null) {
            return self.createPkOk(pk_data.algorithm_name, pk_data.public_key_blob);
        }

        // Verify signature
        const signature = pk_data.signature.?;

        // Decode signature blob (string(algorithm) || string(signature))
        var sig_reader = @import("../protocol/wire.zig").Reader{ .buffer = signature };
        const sig_algorithm = try sig_reader.readString(self.allocator);
        defer self.allocator.free(sig_algorithm);

        const raw_signature_bytes = try sig_reader.readString(self.allocator);
        defer self.allocator.free(raw_signature_bytes);

        // Verify algorithm matches
        if (!std.mem.eql(u8, sig_algorithm, pk_data.algorithm_name)) {
            return self.createFailure(&[_][]const u8{"publickey"}, false);
        }

        // Build signature data to verify
        // Per RFC 4252 Section 7:
        // signature = sign(session_identifier || SSH_MSG_USERAUTH_REQUEST || ...)
        const sig_data = try self.buildSignatureData(
            exchange_hash,
            username,
            pk_data.algorithm_name,
            pk_data.public_key_blob,
        );
        defer self.allocator.free(sig_data);

        // Extract public key from blob
        // Format: string(algorithm) || string(public_key_bytes)
        var pk_reader = @import("../protocol/wire.zig").Reader{ .buffer = pk_data.public_key_blob };
        const pk_algorithm = try pk_reader.readString(self.allocator);
        defer self.allocator.free(pk_algorithm);

        const pk_bytes = try pk_reader.readString(self.allocator);
        defer self.allocator.free(pk_bytes);

        if (pk_bytes.len != 32) {
            return error.InvalidPublicKeyLength;
        }

        // Copy to fixed-size array
        var public_key: [32]u8 = undefined;
        @memcpy(&public_key, pk_bytes);

        // Verify Ed25519 signature requires 64-byte signature
        if (raw_signature_bytes.len != 64) {
            return error.InvalidSignatureLength;
        }

        var signature_bytes: [64]u8 = undefined;
        @memcpy(&signature_bytes, raw_signature_bytes);

        // Verify signature
        const valid = libfast.ssh_signature.verifyEd25519(sig_data, &signature_bytes, &public_key);

        if (valid) {
            return self.createSuccess(username);
        } else {
            return self.createFailure(&[_][]const u8{"publickey"}, false);
        }
    }

    /// Build signature data for verification
    /// Matches the format used in client.zig
    fn buildSignatureData(
        self: *Self,
        exchange_hash: []const u8,
        username: []const u8,
        algorithm_name: []const u8,
        public_key_blob: []const u8,
    ) ![]u8 {
        const publickey_str = "publickey";

        // Calculate size
        var size: usize = 0;
        size += 4 + exchange_hash.len; // string(session_identifier)
        size += 1; // byte(SSH_MSG_USERAUTH_REQUEST) = 50
        size += 4 + username.len; // string(username)
        size += 4 + self.service_name.len; // string(service)
        size += 4 + publickey_str.len; // string("publickey")
        size += 1; // boolean TRUE (signature included)
        size += 4 + algorithm_name.len; // string(algorithm)
        size += 4 + public_key_blob.len; // string(public_key_blob)

        const sig_data = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(sig_data);

        var offset: usize = 0;

        // string(session_identifier)
        std.mem.writeInt(u32, sig_data[offset..][0..4], @intCast(exchange_hash.len), .big);
        offset += 4;
        @memcpy(sig_data[offset .. offset + exchange_hash.len], exchange_hash);
        offset += exchange_hash.len;

        // byte(SSH_MSG_USERAUTH_REQUEST) = 50
        sig_data[offset] = 50;
        offset += 1;

        // string(username)
        std.mem.writeInt(u32, sig_data[offset..][0..4], @intCast(username.len), .big);
        offset += 4;
        @memcpy(sig_data[offset .. offset + username.len], username);
        offset += username.len;

        // string(service)
        std.mem.writeInt(u32, sig_data[offset..][0..4], @intCast(self.service_name.len), .big);
        offset += 4;
        @memcpy(sig_data[offset .. offset + self.service_name.len], self.service_name);
        offset += self.service_name.len;

        // string("publickey")
        std.mem.writeInt(u32, sig_data[offset..][0..4], @intCast(publickey_str.len), .big);
        offset += 4;
        @memcpy(sig_data[offset .. offset + publickey_str.len], publickey_str);
        offset += publickey_str.len;

        // boolean TRUE (signature included)
        sig_data[offset] = 1;
        offset += 1;

        // string(algorithm)
        std.mem.writeInt(u32, sig_data[offset..][0..4], @intCast(algorithm_name.len), .big);
        offset += 4;
        @memcpy(sig_data[offset .. offset + algorithm_name.len], algorithm_name);
        offset += algorithm_name.len;

        // string(public_key_blob)
        std.mem.writeInt(u32, sig_data[offset..][0..4], @intCast(public_key_blob.len), .big);
        offset += 4;
        @memcpy(sig_data[offset .. offset + public_key_blob.len], public_key_blob);

        return sig_data;
    }

    /// Create success response
    fn createSuccess(self: *Self, username: []const u8) !AuthResponse {
        const data = try userauth.UserauthSuccess.encode(self.allocator);
        const user_copy = try self.allocator.dupe(u8, username);
        errdefer self.allocator.free(user_copy);
        return AuthResponse{
            .success = true,
            .data = data,
            .authenticated_username = user_copy,
        };
    }

    /// Create failure response
    fn createFailure(self: *Self, methods: []const []const u8, partial: bool) !AuthResponse {
        // Duplicate method strings for ownership
        const methods_owned = try self.allocator.alloc([]const u8, methods.len);
        errdefer self.allocator.free(methods_owned);

        for (methods, 0..) |method, i| {
            methods_owned[i] = try self.allocator.dupe(u8, method);
        }

        const failure = userauth.UserauthFailure{
            .authentications_continue = methods_owned,
            .partial_success = partial,
        };

        const data = try failure.encode(self.allocator);

        // Clean up the owned copies
        for (methods_owned) |method| {
            self.allocator.free(method);
        }
        self.allocator.free(methods_owned);

        return AuthResponse{
            .success = false,
            .data = data,
            .authenticated_username = null,
        };
    }

    fn createPkOk(self: *Self, algorithm_name: []const u8, public_key_blob: []const u8) !AuthResponse {
        const pk_ok = userauth.UserauthPkOk{
            .algorithm_name = algorithm_name,
            .public_key_blob = public_key_blob,
        };
        const data = try pk_ok.encode(self.allocator);

        return AuthResponse{
            .success = false,
            .data = data,
            .authenticated_username = null,
        };
    }

    /// Send optional banner message to client
    pub fn sendBanner(self: *Self, message: []const u8, language_tag: []const u8) ![]u8 {
        const banner = userauth.UserauthBanner{
            .message = message,
            .language_tag = language_tag,
        };

        return try banner.encode(self.allocator);
    }
};

/// Authentication response
pub const AuthResponse = struct {
    success: bool,
    data: []u8, // Encoded message to send to client
    authenticated_username: ?[]u8,

    pub fn deinit(self: *AuthResponse, allocator: Allocator) void {
        allocator.free(self.data);
        if (self.authenticated_username) |user| {
            allocator.free(user);
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

fn testPublicKeyValidator(username: []const u8, algorithm: []const u8, public_key_blob: []const u8) bool {
    _ = public_key_blob;
    return std.mem.eql(u8, username, "testuser") and std.mem.eql(u8, algorithm, "ssh-ed25519");
}

test "AuthServer - none method returns available methods" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var server = AuthServer.init(allocator);

    var request = userauth.UserauthRequest{
        .username = "testuser",
        .service_name = "ssh-connection",
        .method_name = "none",
        .method_data = .{ .none = {} },
    };

    const request_data = try request.encode(allocator);
    defer allocator.free(request_data);

    const exchange_hash = "dummy_hash";

    var response = try server.processRequest(request_data, exchange_hash);
    defer response.deinit(allocator);

    try testing.expect(!response.success);

    // Decode failure to check methods
    var failure = try userauth.UserauthFailure.decode(allocator, response.data);
    defer failure.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), failure.authentications_continue.len);
}

test "AuthServer - public key query returns pk_ok" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var server = AuthServer.init(allocator);
    server.setPublicKeyValidator(testPublicKeyValidator);

    const fake_public_key_blob = "ssh-ed25519-key-blob";
    var request = userauth.UserauthRequest{
        .username = "testuser",
        .service_name = "ssh-connection",
        .method_name = "publickey",
        .method_data = .{ .publickey = .{
            .algorithm_name = "ssh-ed25519",
            .public_key_blob = fake_public_key_blob,
            .signature = null,
        } },
    };

    const request_data = try request.encode(allocator);
    defer allocator.free(request_data);

    var response = try server.processRequest(request_data, "dummy_hash");
    defer response.deinit(allocator);

    try testing.expect(!response.success);
    try testing.expectEqual(@as(u8, 60), response.data[0]); // SSH_MSG_USERAUTH_PK_OK

    var pk_ok = try userauth.UserauthPkOk.decode(allocator, response.data);
    defer pk_ok.deinit(allocator);
    try testing.expectEqualStrings("ssh-ed25519", pk_ok.algorithm_name);
    try testing.expectEqualStrings(fake_public_key_blob, pk_ok.public_key_blob);
}

test "AuthServer - banner message" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var server = AuthServer.init(allocator);

    const banner_data = try server.sendBanner("Welcome to SSH server", "en");
    defer allocator.free(banner_data);

    try testing.expect(banner_data.len > 0);
    try testing.expectEqual(@as(u8, 53), banner_data[0]); // SSH_MSG_USERAUTH_BANNER
}
