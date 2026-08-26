const std = @import("std");
const Allocator = std.mem.Allocator;
const userauth = @import("../protocol/userauth.zig");
const libfast = @import("libfast");

/// SSH Authentication Client
///
/// Handles client-side authentication after key exchange is complete.
pub const AuthClient = struct {
    allocator: Allocator,
    username: []const u8,
    service_name: []const u8, // Usually "ssh-connection"

    const Self = @This();

    pub fn init(allocator: Allocator, username: []const u8) Self {
        return Self{
            .allocator = allocator,
            .username = username,
            .service_name = "ssh-connection",
        };
    }

    /// Authenticate using public key
    ///
    /// This first queries the server if the key is acceptable (signature = null),
    /// then if accepted, sends the actual signature.
    pub fn authenticatePublicKey(
        self: *Self,
        algorithm_name: []const u8,
        public_key_blob: []const u8,
        private_key: ?*const [64]u8, // Ed25519 private key
        exchange_hash: []const u8,
    ) ![]u8 {
        // If private_key is provided, create signature
        const signature = if (private_key) |priv_key| blk: {
            // Create signature data per RFC 4252 Section 7
            // signature = sign(session_identifier || SSH_MSG_USERAUTH_REQUEST || username || service || "publickey" || algorithm || public_key_blob)

            // Calculate signature data size
            var sig_data_size: usize = 0;
            sig_data_size += 4 + exchange_hash.len; // string(session_identifier)
            sig_data_size += 1; // byte(SSH_MSG_USERAUTH_REQUEST)
            sig_data_size += 4 + self.username.len; // string(username)
            sig_data_size += 4 + self.service_name.len; // string(service)
            sig_data_size += 4 + 9; // string("publickey")
            sig_data_size += 1; // boolean TRUE (signature included)
            sig_data_size += 4 + algorithm_name.len; // string(algorithm)
            sig_data_size += 4 + public_key_blob.len; // string(public_key_blob)

            const sig_data = try self.allocator.alloc(u8, sig_data_size);
            defer self.allocator.free(sig_data);

            // Build signature data
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
            std.mem.writeInt(u32, sig_data[offset..][0..4], @intCast(self.username.len), .big);
            offset += 4;
            @memcpy(sig_data[offset .. offset + self.username.len], self.username);
            offset += self.username.len;

            // string(service)
            std.mem.writeInt(u32, sig_data[offset..][0..4], @intCast(self.service_name.len), .big);
            offset += 4;
            @memcpy(sig_data[offset .. offset + self.service_name.len], self.service_name);
            offset += self.service_name.len;

            // string("publickey")
            const publickey_str = "publickey";
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

            // Sign the data
            const raw_signature = try libfast.ssh_signature.sign(sig_data, priv_key);

            // Encode signature as SSH signature blob
            // Format: string(algorithm_name) || string(raw_signature)
            const sig_blob_size = 4 + algorithm_name.len + 4 + raw_signature.len;
            const sig_blob = try self.allocator.alloc(u8, sig_blob_size);
            errdefer self.allocator.free(sig_blob);

            var sig_offset: usize = 0;
            std.mem.writeInt(u32, sig_blob[sig_offset..][0..4], @intCast(algorithm_name.len), .big);
            sig_offset += 4;
            @memcpy(sig_blob[sig_offset .. sig_offset + algorithm_name.len], algorithm_name);
            sig_offset += algorithm_name.len;

            std.mem.writeInt(u32, sig_blob[sig_offset..][0..4], @intCast(raw_signature.len), .big);
            sig_offset += 4;
            @memcpy(sig_blob[sig_offset .. sig_offset + raw_signature.len], &raw_signature);

            break :blk sig_blob;
        } else null;

        defer if (signature) |sig| self.allocator.free(sig);

        const request = userauth.UserauthRequest{
            .username = self.username,
            .service_name = self.service_name,
            .method_name = "publickey",
            .method_data = .{ .publickey = .{
                .algorithm_name = algorithm_name,
                .public_key_blob = public_key_blob,
                .signature = signature,
            } },
        };

        return try request.encode(self.allocator);
    }

    /// Authenticate with "none" method (used to query available methods)
    pub fn authenticateNone(self: *Self) ![]u8 {
        const request = userauth.UserauthRequest{
            .username = self.username,
            .service_name = self.service_name,
            .method_name = "none",
            .method_data = .{ .none = {} },
        };

        return try request.encode(self.allocator);
    }

    /// Process authentication response
    pub fn processResponse(self: *Self, response_data: []const u8) !AuthResult {
        if (response_data.len < 1) {
            return error.InvalidResponse;
        }

        const msg_type = response_data[0];

        return switch (msg_type) {
            52 => AuthResult{ .success = {} }, // SSH_MSG_USERAUTH_SUCCESS
            51 => blk: { // SSH_MSG_USERAUTH_FAILURE
                const failure = try userauth.UserauthFailure.decode(self.allocator, response_data);
                break :blk AuthResult{
                    .failure = .{
                        .methods = failure.authentications_continue,
                        .partial_success = failure.partial_success,
                    },
                };
            },
            60 => blk: { // SSH_MSG_USERAUTH_PK_OK
                var pk_ok = try userauth.UserauthPkOk.decode(self.allocator, response_data);
                defer pk_ok.deinit(self.allocator);
                break :blk AuthResult{ .pk_ok = {} };
            },
            53 => blk: { // SSH_MSG_USERAUTH_BANNER
                const banner = try userauth.UserauthBanner.decode(self.allocator, response_data);
                break :blk AuthResult{
                    .banner = .{
                        .message = banner.message,
                        .language_tag = banner.language_tag,
                    },
                };
            },
            else => error.UnknownMessageType,
        };
    }
};

/// Authentication result
pub const AuthResult = union(enum) {
    success: void,
    failure: struct {
        methods: []const []const u8,
        partial_success: bool,
    },
    pk_ok: void,
    banner: struct {
        message: []const u8,
        language_tag: []const u8,
    },

    pub fn deinit(self: *AuthResult, allocator: Allocator) void {
        switch (self.*) {
            .success => {},
            .failure => |f| {
                for (f.methods) |method| {
                    allocator.free(method);
                }
                allocator.free(f.methods);
            },
            .pk_ok => {},
            .banner => |b| {
                allocator.free(b.message);
                allocator.free(b.language_tag);
            },
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "AuthClient - none authentication" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var client = AuthClient.init(allocator, "testuser");

    const request = try client.authenticateNone();
    defer allocator.free(request);

    try testing.expectEqual(@as(u8, 50), request[0]);
}

test "AuthClient - process success response" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var client = AuthClient.init(allocator, "testuser");

    const success_msg = try userauth.UserauthSuccess.encode(allocator);
    defer allocator.free(success_msg);

    var result = try client.processResponse(success_msg);
    defer result.deinit(allocator);

    try testing.expect(result == .success);
}
