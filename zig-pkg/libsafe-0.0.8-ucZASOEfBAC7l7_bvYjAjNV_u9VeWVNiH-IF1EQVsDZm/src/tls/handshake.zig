const std = @import("std");

pub const HandshakeError = error{
    InvalidMessage,
    BufferTooSmall,
    UnsupportedVersion,
    UnsupportedCipherSuite,
    InvalidSignature,
    CertificateVerificationFailed,
    OutOfMemory,
};

pub const HandshakeType = enum(u8) {
    client_hello = 1,
    server_hello = 2,
    finished = 20,
};

pub const ExtensionType = enum(u16) {
    application_layer_protocol_negotiation = 16,
    quic_transport_parameters = 0x39,
    _,
};

pub const TLS_AES_128_GCM_SHA256: u16 = 0x1301;
pub const TLS_AES_256_GCM_SHA384: u16 = 0x1302;
pub const TLS_CHACHA20_POLY1305_SHA256: u16 = 0x1303;

pub const Extension = struct {
    extension_type: u16,
    extension_data: []const u8,
};

pub const ClientHello = struct {
    random: [32]u8,
    legacy_session_id: []const u8 = &[_]u8{},
    cipher_suites: []const u16,
    extensions: []const Extension,

    pub fn encode(self: ClientHello, allocator: std.mem.Allocator) HandshakeError![]u8 {
        var data: std.ArrayList(u8) = .{};
        errdefer data.deinit(allocator);

        try data.append(allocator, @intFromEnum(HandshakeType.client_hello));
        const length_pos = data.items.len;
        try data.appendNTimes(allocator, 0, 3);

        const content_start = data.items.len;
        try data.append(allocator, 0x03);
        try data.append(allocator, 0x03);
        try data.appendSlice(allocator, &self.random);

        try data.append(allocator, @intCast(self.legacy_session_id.len));
        try data.appendSlice(allocator, self.legacy_session_id);

        const cs_len: u16 = @intCast(self.cipher_suites.len * 2);
        try data.append(allocator, @intCast((cs_len >> 8) & 0xFF));
        try data.append(allocator, @intCast(cs_len & 0xFF));
        for (self.cipher_suites) |cs| {
            try data.append(allocator, @intCast((cs >> 8) & 0xFF));
            try data.append(allocator, @intCast(cs & 0xFF));
        }

        try data.append(allocator, 1);
        try data.append(allocator, 0);

        try encodeExtensions(&data, allocator, self.extensions);

        const content_len = data.items.len - content_start;
        data.items[length_pos] = @intCast((content_len >> 16) & 0xFF);
        data.items[length_pos + 1] = @intCast((content_len >> 8) & 0xFF);
        data.items[length_pos + 2] = @intCast(content_len & 0xFF);

        return data.toOwnedSlice(allocator);
    }
};

pub const ParsedClientHello = struct {
    random: [32]u8,
    cipher_suites: []const u8,
    extensions: []const u8,
};

pub fn parseClientHello(data: []const u8) HandshakeError!ParsedClientHello {
    if (data.len < 4) return error.InvalidMessage;
    if (data[0] != @intFromEnum(HandshakeType.client_hello)) return error.InvalidMessage;

    const msg_len: usize = (@as(usize, data[1]) << 16) | (@as(usize, data[2]) << 8) | data[3];
    if (data.len < 4 + msg_len) return error.InvalidMessage;

    var pos: usize = 4;
    if (pos + 2 > data.len) return error.InvalidMessage;
    const legacy_version: u16 = (@as(u16, data[pos]) << 8) | data[pos + 1];
    if (legacy_version != 0x0303) return error.UnsupportedVersion;
    pos += 2;

    if (pos + 32 > data.len) return error.InvalidMessage;
    var random: [32]u8 = undefined;
    @memcpy(&random, data[pos .. pos + 32]);
    pos += 32;

    if (pos + 1 > data.len) return error.InvalidMessage;
    const session_id_len = data[pos];
    pos += 1;
    if (pos + session_id_len > data.len) return error.InvalidMessage;
    pos += session_id_len;

    if (pos + 2 > data.len) return error.InvalidMessage;
    const cipher_suites_len: usize = (@as(usize, data[pos]) << 8) | data[pos + 1];
    pos += 2;
    if (cipher_suites_len == 0 or (cipher_suites_len & 1) != 0) return error.InvalidMessage;
    if (pos + cipher_suites_len > data.len) return error.InvalidMessage;
    const cipher_suites = data[pos .. pos + cipher_suites_len];
    pos += cipher_suites_len;

    if (pos + 1 > data.len) return error.InvalidMessage;
    const compression_methods_len = data[pos];
    pos += 1;
    if (compression_methods_len == 0) return error.InvalidMessage;
    if (pos + compression_methods_len > data.len) return error.InvalidMessage;
    pos += compression_methods_len;

    if (pos + 2 > data.len) return error.InvalidMessage;
    const ext_len: usize = (@as(usize, data[pos]) << 8) | data[pos + 1];
    pos += 2;
    if (pos + ext_len > data.len) return error.InvalidMessage;

    return .{ .random = random, .cipher_suites = cipher_suites, .extensions = data[pos .. pos + ext_len] };
}

pub const ServerHello = struct {
    random: [32]u8,
    cipher_suite: u16,
    extensions: []const Extension,

    pub fn encode(self: ServerHello, allocator: std.mem.Allocator) HandshakeError![]u8 {
        var data: std.ArrayList(u8) = .{};
        errdefer data.deinit(allocator);

        try data.append(allocator, @intFromEnum(HandshakeType.server_hello));
        const length_pos = data.items.len;
        try data.appendNTimes(allocator, 0, 3);

        const content_start = data.items.len;
        try data.append(allocator, 0x03);
        try data.append(allocator, 0x03);
        try data.appendSlice(allocator, &self.random);
        try data.append(allocator, 0);
        try data.append(allocator, @intCast((self.cipher_suite >> 8) & 0xFF));
        try data.append(allocator, @intCast(self.cipher_suite & 0xFF));
        try data.append(allocator, 0);

        try encodeExtensions(&data, allocator, self.extensions);

        const content_len = data.items.len - content_start;
        data.items[length_pos] = @intCast((content_len >> 16) & 0xFF);
        data.items[length_pos + 1] = @intCast((content_len >> 8) & 0xFF);
        data.items[length_pos + 2] = @intCast(content_len & 0xFF);

        return data.toOwnedSlice(allocator);
    }
};

pub const ParsedServerHello = struct {
    random: [32]u8,
    cipher_suite: u16,
    extensions: []const u8,
};

pub fn parseServerHello(data: []const u8) HandshakeError!ParsedServerHello {
    if (data.len < 4) return error.InvalidMessage;
    if (data[0] != @intFromEnum(HandshakeType.server_hello)) return error.InvalidMessage;

    const msg_len: usize = (@as(usize, data[1]) << 16) | (@as(usize, data[2]) << 8) | data[3];
    if (data.len < 4 + msg_len) return error.InvalidMessage;

    var pos: usize = 4;
    if (pos + 2 > data.len) return error.InvalidMessage;
    const legacy_version: u16 = (@as(u16, data[pos]) << 8) | data[pos + 1];
    if (legacy_version != 0x0303) return error.UnsupportedVersion;
    pos += 2;

    if (pos + 32 > data.len) return error.InvalidMessage;
    var random: [32]u8 = undefined;
    @memcpy(&random, data[pos .. pos + 32]);
    pos += 32;

    if (pos + 1 > data.len) return error.InvalidMessage;
    const session_id_len = data[pos];
    pos += 1;
    if (pos + session_id_len > data.len) return error.InvalidMessage;
    pos += session_id_len;

    if (pos + 2 > data.len) return error.InvalidMessage;
    const cipher_suite: u16 = (@as(u16, data[pos]) << 8) | data[pos + 1];
    pos += 2;

    if (pos + 1 > data.len) return error.InvalidMessage;
    pos += 1;

    if (pos + 2 > data.len) return error.InvalidMessage;
    const ext_len: usize = (@as(usize, data[pos]) << 8) | data[pos + 1];
    pos += 2;
    if (pos + ext_len > data.len) return error.InvalidMessage;

    return .{ .random = random, .cipher_suite = cipher_suite, .extensions = data[pos .. pos + ext_len] };
}

pub fn findUniqueExtension(extensions: []const u8, extension_type: u16) HandshakeError!?[]const u8 {
    var pos: usize = 0;
    var found: ?[]const u8 = null;

    while (pos < extensions.len) {
        if (pos + 4 > extensions.len) return error.InvalidMessage;
        const ext_type: u16 = (@as(u16, extensions[pos]) << 8) | extensions[pos + 1];
        pos += 2;

        const ext_len: usize = (@as(usize, extensions[pos]) << 8) | extensions[pos + 1];
        pos += 2;
        if (pos + ext_len > extensions.len) return error.InvalidMessage;

        const ext_data = extensions[pos .. pos + ext_len];
        pos += ext_len;

        if (ext_type == extension_type) {
            if (found != null) return error.InvalidMessage;
            found = ext_data;
        }
    }

    return found;
}

fn encodeExtensions(data: *std.ArrayList(u8), allocator: std.mem.Allocator, extensions: []const Extension) HandshakeError!void {
    const len_pos = data.items.len;
    try data.appendNTimes(allocator, 0, 2);

    const start = data.items.len;
    for (extensions) |ext| {
        if (ext.extension_data.len > std.math.maxInt(u16)) return error.InvalidMessage;
        try data.append(allocator, @intCast((ext.extension_type >> 8) & 0xFF));
        try data.append(allocator, @intCast(ext.extension_type & 0xFF));

        const ext_len: u16 = @intCast(ext.extension_data.len);
        try data.append(allocator, @intCast((ext_len >> 8) & 0xFF));
        try data.append(allocator, @intCast(ext_len & 0xFF));
        try data.appendSlice(allocator, ext.extension_data);
    }

    const total_len = data.items.len - start;
    if (total_len > std.math.maxInt(u16)) return error.InvalidMessage;
    data.items[len_pos] = @intCast((total_len >> 8) & 0xFF);
    data.items[len_pos + 1] = @intCast(total_len & 0xFF);
}

test "client and server hello encode parse" {
    const allocator = std.testing.allocator;
    const suites = [_]u16{TLS_AES_128_GCM_SHA256};
    const ch = ClientHello{ .random = [_]u8{0} ** 32, .cipher_suites = &suites, .extensions = &.{} };
    const ch_bytes = try ch.encode(allocator);
    defer allocator.free(ch_bytes);
    const parsed_ch = try parseClientHello(ch_bytes);
    try std.testing.expect(parsed_ch.cipher_suites.len == 2);

    const sh = ServerHello{ .random = [_]u8{1} ** 32, .cipher_suite = TLS_AES_128_GCM_SHA256, .extensions = &.{} };
    const sh_bytes = try sh.encode(allocator);
    defer allocator.free(sh_bytes);
    const parsed_sh = try parseServerHello(sh_bytes);
    try std.testing.expectEqual(TLS_AES_128_GCM_SHA256, parsed_sh.cipher_suite);
}

test "parse client hello rejects truncated message" {
    const allocator = std.testing.allocator;
    const suites = [_]u16{TLS_AES_128_GCM_SHA256};
    const ch = ClientHello{ .random = [_]u8{0x10} ** 32, .cipher_suites = &suites, .extensions = &.{} };
    const encoded = try ch.encode(allocator);
    defer allocator.free(encoded);

    try std.testing.expectError(error.InvalidMessage, parseClientHello(encoded[0 .. encoded.len - 1]));
}

test "parse client hello rejects invalid cipher suite list length" {
    const allocator = std.testing.allocator;
    const suites = [_]u16{TLS_AES_128_GCM_SHA256};
    const ch = ClientHello{ .random = [_]u8{0x20} ** 32, .cipher_suites = &suites, .extensions = &.{} };
    const encoded = try ch.encode(allocator);
    defer allocator.free(encoded);

    var mutated = try allocator.dupe(u8, encoded);
    defer allocator.free(mutated);

    const cipher_len_offset = 4 + 2 + 32 + 1;
    mutated[cipher_len_offset] = 0x00;
    mutated[cipher_len_offset + 1] = 0x03;

    try std.testing.expectError(error.InvalidMessage, parseClientHello(mutated));
}

test "parse server hello rejects truncated message" {
    const allocator = std.testing.allocator;
    const sh = ServerHello{ .random = [_]u8{0x30} ** 32, .cipher_suite = TLS_AES_128_GCM_SHA256, .extensions = &.{} };
    const encoded = try sh.encode(allocator);
    defer allocator.free(encoded);

    try std.testing.expectError(error.InvalidMessage, parseServerHello(encoded[0 .. encoded.len - 2]));
}

test "find unique extension rejects duplicate extension types" {
    const extensions = [_]u8{
        0x00, 0x10, 0x00, 0x01, 0x01,
        0x00, 0x10, 0x00, 0x01, 0x02,
    };
    try std.testing.expectError(
        error.InvalidMessage,
        findUniqueExtension(&extensions, @intFromEnum(ExtensionType.application_layer_protocol_negotiation)),
    );
}

test "find unique extension rejects truncated extension payload" {
    const extensions = [_]u8{
        0x00, 0x39, 0x00, 0x05, 0xAA, 0xBB,
    };
    try std.testing.expectError(
        error.InvalidMessage,
        findUniqueExtension(&extensions, @intFromEnum(ExtensionType.quic_transport_parameters)),
    );
}

test "find unique extension returns null when extension is absent" {
    const extensions = [_]u8{
        0x00, 0x2B, 0x00, 0x02, 0x03, 0x04,
    };
    const result = try findUniqueExtension(&extensions, @intFromEnum(ExtensionType.application_layer_protocol_negotiation));
    try std.testing.expect(result == null);
}

test "parse client hello rejects unsupported legacy version" {
    const allocator = std.testing.allocator;
    const suites = [_]u16{TLS_AES_128_GCM_SHA256};
    const ch = ClientHello{ .random = [_]u8{0x55} ** 32, .cipher_suites = &suites, .extensions = &.{} };
    const encoded = try ch.encode(allocator);
    defer allocator.free(encoded);

    var mutated = try allocator.dupe(u8, encoded);
    defer allocator.free(mutated);
    mutated[4] = 0x03;
    mutated[5] = 0x01;

    try std.testing.expectError(error.UnsupportedVersion, parseClientHello(mutated));
}

test "parse server hello rejects unsupported legacy version" {
    const allocator = std.testing.allocator;
    const sh = ServerHello{ .random = [_]u8{0x66} ** 32, .cipher_suite = TLS_AES_128_GCM_SHA256, .extensions = &.{} };
    const encoded = try sh.encode(allocator);
    defer allocator.free(encoded);

    var mutated = try allocator.dupe(u8, encoded);
    defer allocator.free(mutated);
    mutated[4] = 0x03;
    mutated[5] = 0x01;

    try std.testing.expectError(error.UnsupportedVersion, parseServerHello(mutated));
}

test "client hello encode rejects oversized extension data" {
    const allocator = std.testing.allocator;
    const suites = [_]u16{TLS_AES_128_GCM_SHA256};
    const oversized = try allocator.alloc(u8, std.math.maxInt(u16) + 1);
    defer allocator.free(oversized);
    @memset(oversized, 0xAB);

    const ext = [_]Extension{.{
        .extension_type = @intFromEnum(ExtensionType.quic_transport_parameters),
        .extension_data = oversized,
    }};
    const ch = ClientHello{ .random = [_]u8{0x77} ** 32, .cipher_suites = &suites, .extensions = &ext };

    try std.testing.expectError(error.InvalidMessage, ch.encode(allocator));
}

test "server hello encode rejects oversized extension data" {
    const allocator = std.testing.allocator;
    const oversized = try allocator.alloc(u8, std.math.maxInt(u16) + 1);
    defer allocator.free(oversized);
    @memset(oversized, 0xCD);

    const ext = [_]Extension{.{
        .extension_type = @intFromEnum(ExtensionType.application_layer_protocol_negotiation),
        .extension_data = oversized,
    }};
    const sh = ServerHello{ .random = [_]u8{0x88} ** 32, .cipher_suite = TLS_AES_128_GCM_SHA256, .extensions = &ext };

    try std.testing.expectError(error.InvalidMessage, sh.encode(allocator));
}

test "parse client hello rejects zero compression methods" {
    const allocator = std.testing.allocator;
    const suites = [_]u16{TLS_AES_128_GCM_SHA256};
    const ch = ClientHello{ .random = [_]u8{0x44} ** 32, .cipher_suites = &suites, .extensions = &.{} };
    const encoded = try ch.encode(allocator);
    defer allocator.free(encoded);

    var mutated = try allocator.dupe(u8, encoded);
    defer allocator.free(mutated);

    const compression_len_offset = 4 + 2 + 32 + 1 + 2 + 2;
    mutated[compression_len_offset] = 0;

    try std.testing.expectError(error.InvalidMessage, parseClientHello(mutated));
}
