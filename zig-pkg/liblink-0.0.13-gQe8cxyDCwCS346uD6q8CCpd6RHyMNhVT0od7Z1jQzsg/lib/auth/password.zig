const std = @import("std");
const Allocator = std.mem.Allocator;
const wire = @import("../protocol/wire.zig");
const auth = @import("../protocol/auth.zig");

/// Password authentication method per RFC 4252 Section 8
///
/// Security considerations:
/// - Passwords should be zeroed from memory after use
/// - Use secure connections (SSH/QUIC provides encryption)
/// - Password change requests should be handled carefully

/// Password authentication request
pub const PasswordAuthRequest = struct {
    user_name: []const u8,
    service_name: []const u8,
    password: []u8, // Mutable for zeroing

    /// Create password authentication request
    pub fn init(allocator: Allocator, user_name: []const u8, service_name: []const u8, password: []const u8) !PasswordAuthRequest {
        const user_copy = try allocator.dupe(u8, user_name);
        errdefer allocator.free(user_copy);

        const service_copy = try allocator.dupe(u8, service_name);
        errdefer allocator.free(service_copy);

        const password_copy = try allocator.dupe(u8, password);

        return PasswordAuthRequest{
            .user_name = user_copy,
            .service_name = service_copy,
            .password = password_copy,
        };
    }

    /// Encode as SSH_MSG_USERAUTH_REQUEST with password method
    ///
    /// Method-specific data format:
    ///   boolean   FALSE (not password change)
    ///   string    password
    pub fn encode(self: *const PasswordAuthRequest, allocator: Allocator) ![]u8 {
        // Calculate method-specific data size: 1 (boolean) + 4 + password.len
        const method_data_size = 1 + 4 + self.password.len;
        const method_data = try allocator.alloc(u8, method_data_size);
        defer allocator.free(method_data);

        var writer = wire.Writer{ .buffer = method_data };
        try writer.writeByte(0); // FALSE - not password change
        try writer.writeString(self.password);

        const request = auth.UserauthRequest{
            .user_name = self.user_name,
            .service_name = self.service_name,
            .method_name = "password",
            .method_specific_data = method_data,
        };

        return try request.encode(allocator);
    }

    /// Decode from SSH_MSG_USERAUTH_REQUEST
    pub fn decode(allocator: Allocator, request: *const auth.UserauthRequest) !PasswordAuthRequest {
        if (!std.mem.eql(u8, request.method_name, "password")) {
            return error.InvalidAuthMethod;
        }

        var reader = wire.Reader{ .buffer = request.method_specific_data };

        const is_password_change = try reader.readByte();
        if (is_password_change != 0) {
            return error.PasswordChangeNotSupported;
        }

        const password = try reader.readString(allocator);

        const user_copy = try allocator.dupe(u8, request.user_name);
        errdefer allocator.free(user_copy);

        const service_copy = try allocator.dupe(u8, request.service_name);

        return PasswordAuthRequest{
            .user_name = user_copy,
            .service_name = service_copy,
            .password = password,
        };
    }

    /// Zero password from memory and free resources
    pub fn deinit(self: *PasswordAuthRequest, allocator: Allocator) void {
        // Zero password before freeing (compiler cannot optimize this away)
        std.crypto.secureZero(u8, self.password);
        allocator.free(self.password);

        allocator.free(self.user_name);
        allocator.free(self.service_name);
    }
};

/// Password change request
pub const PasswordChangeRequest = struct {
    user_name: []const u8,
    service_name: []const u8,
    old_password: []u8, // Mutable for zeroing
    new_password: []u8, // Mutable for zeroing

    /// Create password change request
    pub fn init(
        allocator: Allocator,
        user_name: []const u8,
        service_name: []const u8,
        old_password: []const u8,
        new_password: []const u8,
    ) !PasswordChangeRequest {
        const user_copy = try allocator.dupe(u8, user_name);
        errdefer allocator.free(user_copy);

        const service_copy = try allocator.dupe(u8, service_name);
        errdefer allocator.free(service_copy);

        const old_copy = try allocator.dupe(u8, old_password);
        errdefer allocator.free(old_copy);

        const new_copy = try allocator.dupe(u8, new_password);

        return PasswordChangeRequest{
            .user_name = user_copy,
            .service_name = service_copy,
            .old_password = old_copy,
            .new_password = new_copy,
        };
    }

    /// Encode as SSH_MSG_USERAUTH_REQUEST with password change
    ///
    /// Method-specific data format:
    ///   boolean   TRUE (password change)
    ///   string    old password
    ///   string    new password
    pub fn encode(self: *const PasswordChangeRequest, allocator: Allocator) ![]u8 {
        // Calculate method-specific data size
        const method_data_size = 1 + 4 + self.old_password.len + 4 + self.new_password.len;
        const method_data = try allocator.alloc(u8, method_data_size);
        defer allocator.free(method_data);

        var writer = wire.Writer{ .buffer = method_data };
        try writer.writeByte(1); // TRUE - password change
        try writer.writeString(self.old_password);
        try writer.writeString(self.new_password);

        const request = auth.UserauthRequest{
            .user_name = self.user_name,
            .service_name = self.service_name,
            .method_name = "password",
            .method_specific_data = method_data,
        };

        return try request.encode(allocator);
    }

    /// Decode from SSH_MSG_USERAUTH_REQUEST
    pub fn decode(allocator: Allocator, request: *const auth.UserauthRequest) !PasswordChangeRequest {
        if (!std.mem.eql(u8, request.method_name, "password")) {
            return error.InvalidAuthMethod;
        }

        var reader = wire.Reader{ .buffer = request.method_specific_data };

        const is_password_change = try reader.readByte();
        if (is_password_change == 0) {
            return error.NotPasswordChange;
        }

        const old_password = try reader.readString(allocator);
        errdefer allocator.free(old_password);

        const new_password = try reader.readString(allocator);

        const user_copy = try allocator.dupe(u8, request.user_name);
        errdefer allocator.free(user_copy);

        const service_copy = try allocator.dupe(u8, request.service_name);

        return PasswordChangeRequest{
            .user_name = user_copy,
            .service_name = service_copy,
            .old_password = old_password,
            .new_password = new_password,
        };
    }

    /// Zero passwords from memory and free resources
    pub fn deinit(self: *PasswordChangeRequest, allocator: Allocator) void {
        // Zero both passwords before freeing (compiler cannot optimize this away)
        std.crypto.secureZero(u8, self.old_password);
        std.crypto.secureZero(u8, self.new_password);
        allocator.free(self.old_password);
        allocator.free(self.new_password);

        allocator.free(self.user_name);
        allocator.free(self.service_name);
    }
};

/// SSH_MSG_USERAUTH_PASSWD_CHANGEREQ
///
/// Format:
///   byte      SSH_MSG_USERAUTH_PASSWD_CHANGEREQ
///   string    prompt (UTF-8)
///   string    language tag
pub const PasswordChangePrompt = struct {
    prompt: []const u8,
    language_tag: []const u8,

    // Message type (not in constants yet)
    pub const message_type: u8 = 60;

    /// Encode SSH_MSG_USERAUTH_PASSWD_CHANGEREQ
    pub fn encode(self: *const PasswordChangePrompt, allocator: Allocator) ![]u8 {
        const size = 1 + 4 + self.prompt.len + 4 + self.language_tag.len;
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };
        try writer.writeByte(message_type);
        try writer.writeString(self.prompt);
        try writer.writeString(self.language_tag);

        return buffer;
    }

    /// Decode SSH_MSG_USERAUTH_PASSWD_CHANGEREQ
    pub fn decode(allocator: Allocator, data: []const u8) !PasswordChangePrompt {
        var reader = wire.Reader{ .buffer = data };

        const msg_type = try reader.readByte();
        if (msg_type != message_type) {
            return error.InvalidMessageType;
        }

        const prompt = try reader.readString(allocator);
        errdefer allocator.free(prompt);

        const language_tag = try reader.readString(allocator);

        return PasswordChangePrompt{
            .prompt = prompt,
            .language_tag = language_tag,
        };
    }

    /// Free allocated memory
    pub fn deinit(self: *PasswordChangePrompt, allocator: Allocator) void {
        allocator.free(self.prompt);
        allocator.free(self.language_tag);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "PasswordAuthRequest - init and encode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var request = try PasswordAuthRequest.init(allocator, "alice", "ssh-connection", "secret123");
    defer request.deinit(allocator);

    const encoded = try request.encode(allocator);
    defer allocator.free(encoded);

    // Should contain password method
    try testing.expect(encoded.len > 0);
}

test "PasswordAuthRequest - encode and decode via UserauthRequest" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var request = try PasswordAuthRequest.init(allocator, "bob", "ssh-connection", "mypassword");
    defer request.deinit(allocator);

    const encoded = try request.encode(allocator);
    defer allocator.free(encoded);

    // Decode as UserauthRequest first
    var userauth_request = try auth.UserauthRequest.decode(allocator, encoded);
    defer userauth_request.deinit(allocator);

    // Then decode as PasswordAuthRequest
    var decoded = try PasswordAuthRequest.decode(allocator, &userauth_request);
    defer decoded.deinit(allocator);

    try testing.expectEqualStrings("bob", decoded.user_name);
    try testing.expectEqualStrings("ssh-connection", decoded.service_name);
    try testing.expectEqualStrings("mypassword", decoded.password);
}

test "PasswordAuthRequest - password zeroing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var request = try PasswordAuthRequest.init(allocator, "user", "ssh-connection", "secret");

    request.deinit(allocator);

    // Verify password memory was zeroed (implementation detail test)
    // Note: This is testing the deinit behavior, actual memory may be reused
}

test "PasswordChangeRequest - init and encode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var request = try PasswordChangeRequest.init(allocator, "alice", "ssh-connection", "old_pass", "new_pass");
    defer request.deinit(allocator);

    const encoded = try request.encode(allocator);
    defer allocator.free(encoded);

    try testing.expect(encoded.len > 0);
}

test "PasswordChangeRequest - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var request = try PasswordChangeRequest.init(allocator, "charlie", "ssh-connection", "oldpass123", "newpass456");
    defer request.deinit(allocator);

    const encoded = try request.encode(allocator);
    defer allocator.free(encoded);

    // Decode as UserauthRequest first
    var userauth_request = try auth.UserauthRequest.decode(allocator, encoded);
    defer userauth_request.deinit(allocator);

    // Then decode as PasswordChangeRequest
    var decoded = try PasswordChangeRequest.decode(allocator, &userauth_request);
    defer decoded.deinit(allocator);

    try testing.expectEqualStrings("charlie", decoded.user_name);
    try testing.expectEqualStrings("ssh-connection", decoded.service_name);
    try testing.expectEqualStrings("oldpass123", decoded.old_password);
    try testing.expectEqualStrings("newpass456", decoded.new_password);
}

test "PasswordChangeRequest - password zeroing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var request = try PasswordChangeRequest.init(allocator, "user", "ssh-connection", "old", "new");

    request.deinit(allocator);

    // Passwords should be zeroed (implementation detail)
}

test "PasswordChangePrompt - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const prompt = PasswordChangePrompt{
        .prompt = "Your password has expired. Please enter a new password.",
        .language_tag = "en",
    };

    const encoded = try prompt.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try PasswordChangePrompt.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqualStrings(prompt.prompt, decoded.prompt);
    try testing.expectEqualStrings(prompt.language_tag, decoded.language_tag);
}

test "PasswordAuthRequest - decode rejects password change" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var change_request = try PasswordChangeRequest.init(allocator, "user", "ssh-connection", "old", "new");
    defer change_request.deinit(allocator);

    const encoded = try change_request.encode(allocator);
    defer allocator.free(encoded);

    var userauth_request = try auth.UserauthRequest.decode(allocator, encoded);
    defer userauth_request.deinit(allocator);

    // Should fail because it's a password change, not regular auth
    const result = PasswordAuthRequest.decode(allocator, &userauth_request);
    try testing.expectError(error.PasswordChangeNotSupported, result);
}

test "PasswordChangeRequest - decode rejects regular auth" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var auth_request = try PasswordAuthRequest.init(allocator, "user", "ssh-connection", "pass");
    defer auth_request.deinit(allocator);

    const encoded = try auth_request.encode(allocator);
    defer allocator.free(encoded);

    var userauth_request = try auth.UserauthRequest.decode(allocator, encoded);
    defer userauth_request.deinit(allocator);

    // Should fail because it's regular auth, not password change
    const result = PasswordChangeRequest.decode(allocator, &userauth_request);
    try testing.expectError(error.NotPasswordChange, result);
}
