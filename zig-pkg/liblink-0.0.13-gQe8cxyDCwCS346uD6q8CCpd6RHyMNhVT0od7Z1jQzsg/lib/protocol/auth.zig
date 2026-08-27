const std = @import("std");
const Allocator = std.mem.Allocator;
const wire = @import("wire.zig");
const constants = @import("../common/constants.zig");

/// SSH User Authentication Protocol per RFC 4252
///
/// All authentication messages are sent on stream 0 (global stream) in SSH/QUIC.

/// Authentication method types
pub const AuthMethod = enum {
    none,
    password,
    publickey,
    hostbased,
    keyboard_interactive,

    pub fn toString(self: AuthMethod) []const u8 {
        return switch (self) {
            .none => "none",
            .password => "password",
            .publickey => "publickey",
            .hostbased => "hostbased",
            .keyboard_interactive => "keyboard-interactive",
        };
    }

    pub fn fromString(s: []const u8) ?AuthMethod {
        if (std.mem.eql(u8, s, "none")) return .none;
        if (std.mem.eql(u8, s, "password")) return .password;
        if (std.mem.eql(u8, s, "publickey")) return .publickey;
        if (std.mem.eql(u8, s, "hostbased")) return .hostbased;
        if (std.mem.eql(u8, s, "keyboard-interactive")) return .keyboard_interactive;
        return null;
    }
};

/// SSH_MSG_USERAUTH_REQUEST
///
/// Format:
///   byte      SSH_MSG_USERAUTH_REQUEST
///   string    user name (UTF-8)
///   string    service name
///   string    method name
///   ....      method specific fields
pub const UserauthRequest = struct {
    user_name: []const u8,
    service_name: []const u8,
    method_name: []const u8,
    method_specific_data: []const u8,

    /// Encode SSH_MSG_USERAUTH_REQUEST
    pub fn encode(self: *const UserauthRequest, allocator: Allocator) ![]u8 {
        const size = 1 + 4 + self.user_name.len + 4 + self.service_name.len + 4 + self.method_name.len + self.method_specific_data.len;
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };
        try writer.writeByte(constants.SSH_MSG.USERAUTH_REQUEST);
        try writer.writeString(self.user_name);
        try writer.writeString(self.service_name);
        try writer.writeString(self.method_name);
        @memcpy(buffer[buffer.len - self.method_specific_data.len ..], self.method_specific_data);

        return buffer;
    }

    /// Decode SSH_MSG_USERAUTH_REQUEST
    pub fn decode(allocator: Allocator, data: []const u8) !UserauthRequest {
        var reader = wire.Reader{ .buffer = data };

        const msg_type = try reader.readByte();
        if (msg_type != constants.SSH_MSG.USERAUTH_REQUEST) {
            return error.InvalidMessageType;
        }

        const user_name = try reader.readString(allocator);
        errdefer allocator.free(user_name);

        const service_name = try reader.readString(allocator);
        errdefer allocator.free(service_name);

        const method_name = try reader.readString(allocator);
        errdefer allocator.free(method_name);

        const remaining = data[reader.offset..];
        const method_specific_data = try allocator.dupe(u8, remaining);

        return UserauthRequest{
            .user_name = user_name,
            .service_name = service_name,
            .method_name = method_name,
            .method_specific_data = method_specific_data,
        };
    }

    /// Free allocated memory
    pub fn deinit(self: *UserauthRequest, allocator: Allocator) void {
        allocator.free(self.user_name);
        allocator.free(self.service_name);
        allocator.free(self.method_name);
        allocator.free(self.method_specific_data);
    }
};

/// SSH_MSG_USERAUTH_FAILURE
///
/// Format:
///   byte      SSH_MSG_USERAUTH_FAILURE
///   name-list authentications that can continue
///   boolean   partial success
pub const UserauthFailure = struct {
    authentications: []const []const u8,
    partial_success: bool,

    /// Encode SSH_MSG_USERAUTH_FAILURE
    pub fn encode(self: *const UserauthFailure, allocator: Allocator) ![]u8 {
        // Build comma-separated name-list
        var name_list_size: usize = 0;
        for (self.authentications, 0..) |auth, i| {
            name_list_size += auth.len;
            if (i < self.authentications.len - 1) {
                name_list_size += 1; // comma
            }
        }

        const name_list = try allocator.alloc(u8, name_list_size);
        defer allocator.free(name_list);

        var pos: usize = 0;
        for (self.authentications, 0..) |auth, i| {
            @memcpy(name_list[pos .. pos + auth.len], auth);
            pos += auth.len;
            if (i < self.authentications.len - 1) {
                name_list[pos] = ',';
                pos += 1;
            }
        }

        const size = 1 + 4 + name_list_size + 1;
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };
        try writer.writeByte(constants.SSH_MSG.USERAUTH_FAILURE);
        try writer.writeString(name_list);
        try writer.writeByte(if (self.partial_success) 1 else 0);

        return buffer;
    }

    /// Decode SSH_MSG_USERAUTH_FAILURE
    pub fn decode(allocator: Allocator, data: []const u8) !UserauthFailure {
        var reader = wire.Reader{ .buffer = data };

        const msg_type = try reader.readByte();
        if (msg_type != constants.SSH_MSG.USERAUTH_FAILURE) {
            return error.InvalidMessageType;
        }

        const name_list = try reader.readString(allocator);
        defer allocator.free(name_list);

        // Count comma-separated items first
        var count: usize = 0;
        var count_iter = std.mem.splitScalar(u8, name_list, ',');
        while (count_iter.next()) |auth| {
            const trimmed = std.mem.trim(u8, auth, " \t");
            if (trimmed.len > 0) count += 1;
        }

        // Allocate and fill array
        const authentications = try allocator.alloc([]u8, count);
        errdefer allocator.free(authentications);

        var i: usize = 0;
        errdefer {
            for (authentications[0..i]) |item| {
                allocator.free(item);
            }
        }

        var iter = std.mem.splitScalar(u8, name_list, ',');
        while (iter.next()) |auth| {
            const trimmed = std.mem.trim(u8, auth, " \t");
            if (trimmed.len > 0) {
                authentications[i] = try allocator.dupe(u8, trimmed);
                i += 1;
            }
        }

        const partial_success_byte = try reader.readByte();
        const partial_success = partial_success_byte != 0;

        return UserauthFailure{
            .authentications = authentications,
            .partial_success = partial_success,
        };
    }

    /// Free allocated memory
    pub fn deinit(self: *UserauthFailure, allocator: Allocator) void {
        for (self.authentications) |auth| {
            allocator.free(auth);
        }
        allocator.free(self.authentications);
    }
};

/// SSH_MSG_USERAUTH_SUCCESS
///
/// Format:
///   byte      SSH_MSG_USERAUTH_SUCCESS
pub const UserauthSuccess = struct {
    /// Encode SSH_MSG_USERAUTH_SUCCESS
    pub fn encode(allocator: Allocator) ![]u8 {
        const buffer = try allocator.alloc(u8, 1);
        buffer[0] = constants.SSH_MSG.USERAUTH_SUCCESS;
        return buffer;
    }

    /// Decode SSH_MSG_USERAUTH_SUCCESS
    pub fn decode(data: []const u8) !UserauthSuccess {
        if (data.len < 1) {
            return error.InsufficientData;
        }

        if (data[0] != constants.SSH_MSG.USERAUTH_SUCCESS) {
            return error.InvalidMessageType;
        }

        return UserauthSuccess{};
    }
};

/// SSH_MSG_USERAUTH_BANNER
///
/// Format:
///   byte      SSH_MSG_USERAUTH_BANNER
///   string    message (UTF-8)
///   string    language tag
pub const UserauthBanner = struct {
    message: []const u8,
    language_tag: []const u8,

    /// Encode SSH_MSG_USERAUTH_BANNER
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

    /// Decode SSH_MSG_USERAUTH_BANNER
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

    /// Free allocated memory
    pub fn deinit(self: *UserauthBanner, allocator: Allocator) void {
        allocator.free(self.message);
        allocator.free(self.language_tag);
    }
};

/// SSH_MSG_USERAUTH_INFO_REQUEST (keyboard-interactive)
///
/// Format:
///   byte      SSH_MSG_USERAUTH_INFO_REQUEST
///   string    name (UTF-8)
///   string    instruction (UTF-8)
///   string    language tag
///   uint32    num-prompts
///   repeat num-prompts times:
///     string    prompt (UTF-8)
///     boolean   echo
pub const UserauthInfoRequest = struct {
    pub const Prompt = struct {
        text: []const u8,
        echo: bool,
    };

    name: []const u8,
    instruction: []const u8,
    language_tag: []const u8,
    prompts: []const Prompt,

    /// Encode SSH_MSG_USERAUTH_INFO_REQUEST
    pub fn encode(self: *const UserauthInfoRequest, allocator: Allocator) ![]u8 {
        var size: usize = 1 + 4 + self.name.len + 4 + self.instruction.len + 4 + self.language_tag.len + 4;
        for (self.prompts) |prompt| {
            size += 4 + prompt.text.len + 1;
        }

        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };
        try writer.writeByte(constants.SSH_MSG.USERAUTH_INFO_REQUEST);
        try writer.writeString(self.name);
        try writer.writeString(self.instruction);
        try writer.writeString(self.language_tag);
        try writer.writeUint32(@intCast(self.prompts.len));

        for (self.prompts) |prompt| {
            try writer.writeString(prompt.text);
            try writer.writeByte(if (prompt.echo) 1 else 0);
        }

        return buffer;
    }

    /// Decode SSH_MSG_USERAUTH_INFO_REQUEST
    pub fn decode(allocator: Allocator, data: []const u8) !UserauthInfoRequest {
        var reader = wire.Reader{ .buffer = data };

        const msg_type = try reader.readByte();
        if (msg_type != constants.SSH_MSG.USERAUTH_INFO_REQUEST) {
            return error.InvalidMessageType;
        }

        const name = try reader.readString(allocator);
        errdefer allocator.free(name);

        const instruction = try reader.readString(allocator);
        errdefer allocator.free(instruction);

        const language_tag = try reader.readString(allocator);
        errdefer allocator.free(language_tag);

        const num_prompts = try reader.readUint32();
        const prompts = try allocator.alloc(Prompt, num_prompts);
        errdefer allocator.free(prompts);

        var i: usize = 0;
        errdefer {
            for (prompts[0..i]) |*prompt| {
                allocator.free(prompt.text);
            }
        }

        while (i < num_prompts) : (i += 1) {
            const text = try reader.readString(allocator);
            const echo_byte = try reader.readByte();
            prompts[i] = .{ .text = text, .echo = echo_byte != 0 };
        }

        return UserauthInfoRequest{
            .name = name,
            .instruction = instruction,
            .language_tag = language_tag,
            .prompts = prompts,
        };
    }

    /// Free allocated memory
    pub fn deinit(self: *UserauthInfoRequest, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.instruction);
        allocator.free(self.language_tag);
        for (self.prompts) |*prompt| {
            allocator.free(prompt.text);
        }
        allocator.free(self.prompts);
    }
};

/// SSH_MSG_USERAUTH_INFO_RESPONSE (keyboard-interactive)
///
/// Format:
///   byte      SSH_MSG_USERAUTH_INFO_RESPONSE
///   uint32    num-responses
///   repeat num-responses times:
///     string    response (UTF-8)
pub const UserauthInfoResponse = struct {
    responses: []const []const u8,

    /// Encode SSH_MSG_USERAUTH_INFO_RESPONSE
    pub fn encode(self: *const UserauthInfoResponse, allocator: Allocator) ![]u8 {
        var size: usize = 1 + 4;
        for (self.responses) |response| {
            size += 4 + response.len;
        }

        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };
        try writer.writeByte(constants.SSH_MSG.USERAUTH_INFO_RESPONSE);
        try writer.writeUint32(@intCast(self.responses.len));

        for (self.responses) |response| {
            try writer.writeString(response);
        }

        return buffer;
    }

    /// Decode SSH_MSG_USERAUTH_INFO_RESPONSE
    pub fn decode(allocator: Allocator, data: []const u8) !UserauthInfoResponse {
        var reader = wire.Reader{ .buffer = data };

        const msg_type = try reader.readByte();
        if (msg_type != constants.SSH_MSG.USERAUTH_INFO_RESPONSE) {
            return error.InvalidMessageType;
        }

        const num_responses = try reader.readUint32();
        const responses = try allocator.alloc([]u8, num_responses);
        errdefer allocator.free(responses);

        var i: usize = 0;
        errdefer {
            for (responses[0..i]) |response| {
                allocator.free(response);
            }
        }

        while (i < num_responses) : (i += 1) {
            responses[i] = try reader.readString(allocator);
        }

        return UserauthInfoResponse{
            .responses = responses,
        };
    }

    /// Free allocated memory
    pub fn deinit(self: *UserauthInfoResponse, allocator: Allocator) void {
        for (self.responses) |response| {
            allocator.free(response);
        }
        allocator.free(self.responses);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "AuthMethod - string conversion" {
    const testing = std.testing;

    try testing.expectEqualStrings("password", AuthMethod.password.toString());
    try testing.expectEqualStrings("publickey", AuthMethod.publickey.toString());

    try testing.expectEqual(AuthMethod.password, AuthMethod.fromString("password").?);
    try testing.expectEqual(AuthMethod.publickey, AuthMethod.fromString("publickey").?);
    try testing.expect(AuthMethod.fromString("invalid") == null);
}

test "UserauthRequest - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const msg = UserauthRequest{
        .user_name = "alice",
        .service_name = "ssh-connection",
        .method_name = "password",
        .method_specific_data = "test_data",
    };

    const encoded = try msg.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try UserauthRequest.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqualStrings(msg.user_name, decoded.user_name);
    try testing.expectEqualStrings(msg.service_name, decoded.service_name);
    try testing.expectEqualStrings(msg.method_name, decoded.method_name);
    try testing.expectEqualStrings(msg.method_specific_data, decoded.method_specific_data);
}

test "UserauthFailure - encode and decode single method" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const auths = [_][]const u8{"password"};
    const msg = UserauthFailure{
        .authentications = &auths,
        .partial_success = false,
    };

    const encoded = try msg.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try UserauthFailure.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), decoded.authentications.len);
    try testing.expectEqualStrings("password", decoded.authentications[0]);
    try testing.expectEqual(false, decoded.partial_success);
}

test "UserauthFailure - encode and decode multiple methods" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const auths = [_][]const u8{ "password", "publickey", "keyboard-interactive" };
    const msg = UserauthFailure{
        .authentications = &auths,
        .partial_success = true,
    };

    const encoded = try msg.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try UserauthFailure.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), decoded.authentications.len);
    try testing.expectEqualStrings("password", decoded.authentications[0]);
    try testing.expectEqualStrings("publickey", decoded.authentications[1]);
    try testing.expectEqualStrings("keyboard-interactive", decoded.authentications[2]);
    try testing.expectEqual(true, decoded.partial_success);
}

test "UserauthSuccess - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const encoded = try UserauthSuccess.encode(allocator);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 1), encoded.len);
    try testing.expectEqual(constants.SSH_MSG.USERAUTH_SUCCESS, encoded[0]);

    const decoded = try UserauthSuccess.decode(encoded);
    _ = decoded;
}

test "UserauthBanner - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const msg = UserauthBanner{
        .message = "Welcome to SSH/QUIC server!",
        .language_tag = "en",
    };

    const encoded = try msg.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try UserauthBanner.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqualStrings(msg.message, decoded.message);
    try testing.expectEqualStrings(msg.language_tag, decoded.language_tag);
}

test "UserauthInfoRequest - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const prompts = [_]UserauthInfoRequest.Prompt{
        .{ .text = "Password: ", .echo = false },
        .{ .text = "Confirm: ", .echo = false },
    };

    const msg = UserauthInfoRequest{
        .name = "SSH Authentication",
        .instruction = "Please enter your credentials",
        .language_tag = "en",
        .prompts = &prompts,
    };

    const encoded = try msg.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try UserauthInfoRequest.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqualStrings(msg.name, decoded.name);
    try testing.expectEqualStrings(msg.instruction, decoded.instruction);
    try testing.expectEqual(@as(usize, 2), decoded.prompts.len);
    try testing.expectEqualStrings("Password: ", decoded.prompts[0].text);
    try testing.expectEqual(false, decoded.prompts[0].echo);
}

test "UserauthInfoResponse - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const responses = [_][]const u8{ "secret_password", "secret_password" };
    const msg = UserauthInfoResponse{
        .responses = &responses,
    };

    const encoded = try msg.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try UserauthInfoResponse.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), decoded.responses.len);
    try testing.expectEqualStrings("secret_password", decoded.responses[0]);
    try testing.expectEqualStrings("secret_password", decoded.responses[1]);
}
