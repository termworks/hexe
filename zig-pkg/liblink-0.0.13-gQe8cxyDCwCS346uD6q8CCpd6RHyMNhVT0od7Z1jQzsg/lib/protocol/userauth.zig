const std = @import("std");
const Allocator = std.mem.Allocator;
const wire = @import("wire.zig");
const constants = @import("../common/constants.zig");

/// SSH User Authentication Protocol (RFC 4252)
///
/// Handles authentication after key exchange is complete.
/// Supports password and public key authentication methods.
/// SSH_MSG_USERAUTH_REQUEST - Client authentication request
pub const UserauthRequest = struct {
    username: []const u8,
    service_name: []const u8, // Usually "ssh-connection"
    method_name: []const u8, // "password", "publickey", "none"
    method_data: MethodData,

    /// Public key authentication data
    pub const PublicKeyData = struct {
        algorithm_name: []const u8,
        public_key_blob: []const u8,
        signature: ?[]const u8, // null for query, populated for actual auth
    };

    pub const MethodData = union(enum) {
        none: void,
        password: []const u8,
        publickey: PublicKeyData,
    };

    /// Encode SSH_MSG_USERAUTH_REQUEST
    pub fn encode(self: *const UserauthRequest, allocator: Allocator) ![]u8 {
        // Calculate size
        var size: usize = 1; // message type
        size += 4 + self.username.len;
        size += 4 + self.service_name.len;
        size += 4 + self.method_name.len;

        // Add method-specific data size
        switch (self.method_data) {
            .none => {},
            .password => |pass| {
                size += 1; // boolean for "change password"
                size += 4 + pass.len;
            },
            .publickey => |pk| {
                size += 1; // boolean for "has signature"
                size += 4 + pk.algorithm_name.len;
                size += 4 + pk.public_key_blob.len;
                if (pk.signature) |sig| {
                    size += 4 + sig.len;
                }
            },
        }

        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };

        try writer.writeByte(constants.SSH_MSG.USERAUTH_REQUEST);
        try writer.writeString(self.username);
        try writer.writeString(self.service_name);
        try writer.writeString(self.method_name);

        switch (self.method_data) {
            .none => {},
            .password => |pass| {
                try writer.writeBool(false); // not changing password
                try writer.writeString(pass);
            },
            .publickey => |pk| {
                const has_signature = pk.signature != null;
                try writer.writeBool(has_signature);
                try writer.writeString(pk.algorithm_name);
                try writer.writeString(pk.public_key_blob);
                if (pk.signature) |sig| {
                    try writer.writeString(sig);
                }
            },
        }

        return buffer;
    }

    /// Decode SSH_MSG_USERAUTH_REQUEST
    pub fn decode(allocator: Allocator, data: []const u8) !UserauthRequest {
        var reader = wire.Reader{ .buffer = data };

        const msg_type = try reader.readByte();
        if (msg_type != constants.SSH_MSG.USERAUTH_REQUEST) {
            return error.InvalidMessageType;
        }

        const username = try reader.readString(allocator);
        errdefer allocator.free(username);

        const service_name = try reader.readString(allocator);
        errdefer allocator.free(service_name);

        const method_name = try reader.readString(allocator);
        errdefer allocator.free(method_name);

        // Parse method-specific data
        const method_data = if (std.mem.eql(u8, method_name, "none"))
            MethodData{ .none = {} }
        else if (std.mem.eql(u8, method_name, "password")) blk: {
            _ = try reader.readBool(); // change password flag (ignored)
            const password = try reader.readString(allocator);
            break :blk MethodData{ .password = password };
        } else if (std.mem.eql(u8, method_name, "publickey")) blk: {
            const has_signature = try reader.readBool();
            const algorithm_name = try reader.readString(allocator);
            errdefer allocator.free(algorithm_name);

            const public_key_blob = try reader.readString(allocator);
            errdefer allocator.free(public_key_blob);

            const signature = if (has_signature)
                try reader.readString(allocator)
            else
                null;

            break :blk MethodData{ .publickey = .{
                .algorithm_name = algorithm_name,
                .public_key_blob = public_key_blob,
                .signature = signature,
            } };
        } else {
            return error.UnknownAuthMethod;
        };

        return UserauthRequest{
            .username = username,
            .service_name = service_name,
            .method_name = method_name,
            .method_data = method_data,
        };
    }

    pub fn deinit(self: *UserauthRequest, allocator: Allocator) void {
        allocator.free(self.username);
        allocator.free(self.service_name);
        allocator.free(self.method_name);

        switch (self.method_data) {
            .none => {},
            .password => |pass| allocator.free(pass),
            .publickey => |pk| {
                allocator.free(pk.algorithm_name);
                allocator.free(pk.public_key_blob);
                if (pk.signature) |sig| {
                    allocator.free(sig);
                }
            },
        }
    }
};

/// SSH_MSG_USERAUTH_FAILURE - Server authentication failure
pub const UserauthFailure = struct {
    authentications_continue: []const []const u8, // List of auth methods that can continue
    partial_success: bool,

    pub fn encode(self: *const UserauthFailure, allocator: Allocator) ![]u8 {
        // Calculate size
        var size: usize = 1; // message type
        size += 4; // name-list length

        var name_list_len: usize = 0;
        for (self.authentications_continue, 0..) |method, i| {
            name_list_len += method.len;
            if (i < self.authentications_continue.len - 1) {
                name_list_len += 1; // comma separator
            }
        }
        size += name_list_len;
        size += 1; // partial success boolean

        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };

        try writer.writeByte(constants.SSH_MSG.USERAUTH_FAILURE);

        // Write name-list
        var name_list = try allocator.alloc(u8, name_list_len);
        defer allocator.free(name_list);

        var offset: usize = 0;
        for (self.authentications_continue, 0..) |method, i| {
            @memcpy(name_list[offset .. offset + method.len], method);
            offset += method.len;
            if (i < self.authentications_continue.len - 1) {
                name_list[offset] = ',';
                offset += 1;
            }
        }

        try writer.writeString(name_list);
        try writer.writeBool(self.partial_success);

        return buffer;
    }

    pub fn decode(allocator: Allocator, data: []const u8) !UserauthFailure {
        var reader = wire.Reader{ .buffer = data };

        const msg_type = try reader.readByte();
        if (msg_type != constants.SSH_MSG.USERAUTH_FAILURE) {
            return error.InvalidMessageType;
        }

        const name_list = try reader.readString(allocator);
        defer allocator.free(name_list);

        // Parse comma-separated list
        var methods = std.ArrayListUnmanaged([]const u8){};
        errdefer {
            for (methods.items) |method| {
                allocator.free(method);
            }
            methods.deinit(allocator);
        }

        var iter = std.mem.splitScalar(u8, name_list, ',');
        while (iter.next()) |method| {
            const method_copy = try allocator.dupe(u8, method);
            try methods.append(allocator, method_copy);
        }

        const partial_success = try reader.readBool();

        return UserauthFailure{
            .authentications_continue = try methods.toOwnedSlice(allocator),
            .partial_success = partial_success,
        };
    }

    pub fn deinit(self: *UserauthFailure, allocator: Allocator) void {
        for (self.authentications_continue) |method| {
            allocator.free(method);
        }
        allocator.free(self.authentications_continue);
    }
};

/// SSH_MSG_USERAUTH_SUCCESS - Authentication succeeded
pub const UserauthSuccess = struct {
    pub fn encode(allocator: Allocator) ![]u8 {
        const buffer = try allocator.alloc(u8, 1);
        buffer[0] = constants.SSH_MSG.USERAUTH_SUCCESS;
        return buffer;
    }

    pub fn decode(data: []const u8) !UserauthSuccess {
        if (data.len < 1 or data[0] != constants.SSH_MSG.USERAUTH_SUCCESS) {
            return error.InvalidMessageType;
        }
        return UserauthSuccess{};
    }
};

/// SSH_MSG_USERAUTH_BANNER - Optional server banner message
pub const UserauthBanner = struct {
    message: []const u8,
    language_tag: []const u8,

    pub fn encode(self: *const UserauthBanner, allocator: Allocator) ![]u8 {
        const size = 1 + 4 + self.message.len + 4 + self.language_tag.len;
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };
        try writer.writeByte(constants.SSH_MSG.USERAUTH_BANNER);
        try writer.writeString(self.message);
        try writer.writeString(self.language_tag);

        return buffer;
    }

    pub fn decode(allocator: Allocator, data: []const u8) !UserauthBanner {
        var reader = wire.Reader{ .buffer = data };

        const msg_type = try reader.readByte();
        if (msg_type != constants.SSH_MSG.USERAUTH_BANNER) {
            return error.InvalidMessageType;
        }

        const message = try reader.readString(allocator);
        errdefer allocator.free(message);

        const language_tag = try reader.readString(allocator);

        return UserauthBanner{
            .message = message,
            .language_tag = language_tag,
        };
    }

    pub fn deinit(self: *UserauthBanner, allocator: Allocator) void {
        allocator.free(self.message);
        allocator.free(self.language_tag);
    }
};

/// SSH_MSG_USERAUTH_PK_OK - public key is acceptable, send signed request next
pub const UserauthPkOk = struct {
    algorithm_name: []const u8,
    public_key_blob: []const u8,

    pub fn encode(self: *const UserauthPkOk, allocator: Allocator) ![]u8 {
        const size = 1 + 4 + self.algorithm_name.len + 4 + self.public_key_blob.len;
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };
        try writer.writeByte(constants.SSH_MSG.USERAUTH_PK_OK);
        try writer.writeString(self.algorithm_name);
        try writer.writeString(self.public_key_blob);
        return buffer;
    }

    pub fn decode(allocator: Allocator, data: []const u8) !UserauthPkOk {
        var reader = wire.Reader{ .buffer = data };

        const msg_type = try reader.readByte();
        if (msg_type != constants.SSH_MSG.USERAUTH_PK_OK) {
            return error.InvalidMessageType;
        }

        const algorithm_name = try reader.readString(allocator);
        errdefer allocator.free(algorithm_name);
        const public_key_blob = try reader.readString(allocator);

        return .{
            .algorithm_name = algorithm_name,
            .public_key_blob = public_key_blob,
        };
    }

    pub fn deinit(self: *UserauthPkOk, allocator: Allocator) void {
        allocator.free(self.algorithm_name);
        allocator.free(self.public_key_blob);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "UserauthRequest - password" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var request = UserauthRequest{
        .username = "testuser",
        .service_name = "ssh-connection",
        .method_name = "password",
        .method_data = .{ .password = "testpass" },
    };

    const encoded = try request.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try UserauthRequest.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqualStrings("testuser", decoded.username);
    try testing.expectEqualStrings("password", decoded.method_name);
    try testing.expectEqualStrings("testpass", decoded.method_data.password);
}

test "UserauthFailure - encode/decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const methods = [_][]const u8{ "password", "publickey" };
    var methods_owned = try allocator.alloc([]const u8, methods.len);
    defer {
        for (methods_owned) |method| {
            allocator.free(method);
        }
        allocator.free(methods_owned);
    }

    for (methods, 0..) |method, i| {
        methods_owned[i] = try allocator.dupe(u8, method);
    }

    var failure = UserauthFailure{
        .authentications_continue = methods_owned,
        .partial_success = false,
    };

    const encoded = try failure.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try UserauthFailure.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), decoded.authentications_continue.len);
    try testing.expect(!decoded.partial_success);
}

test "UserauthSuccess - encode/decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const encoded = try UserauthSuccess.encode(allocator);
    defer allocator.free(encoded);

    const decoded = try UserauthSuccess.decode(encoded);
    _ = decoded;
}

test "UserauthPkOk - encode/decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pk_ok = UserauthPkOk{
        .algorithm_name = "ssh-ed25519",
        .public_key_blob = "dummy-key-blob",
    };

    const encoded = try pk_ok.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try UserauthPkOk.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqualStrings("ssh-ed25519", decoded.algorithm_name);
    try testing.expectEqualStrings("dummy-key-blob", decoded.public_key_blob);
}
