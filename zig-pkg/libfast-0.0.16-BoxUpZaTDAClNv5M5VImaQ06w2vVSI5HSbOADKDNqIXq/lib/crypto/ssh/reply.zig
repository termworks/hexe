const std = @import("std");
const varint = @import("../../utils/varint.zig");
const obfuscation = @import("libsafe").ssh_obfuscation;
const transport_params = @import("../../core/transport_params.zig");

pub const SSH_QUIC_REPLY: u8 = 2;
pub const SSH_QUIC_ERROR_REPLY: u8 = 254;
pub const AMPLIFICATION_FACTOR: usize = 3;

pub const ReplyError = error{
    InvalidFormat,
    BufferTooSmall,
    EncodingFailed,
    DecodingFailed,
    AmplificationLimitExceeded,
    InvalidTransportParameters,
    OutOfMemory,
} || varint.VarintError || obfuscation.ObfuscationError;

pub const ServerKexAlgorithm = struct {
    name: []const u8,
    data: []const u8,

    pub fn isEmpty(self: ServerKexAlgorithm) bool {
        return self.data.len == 0;
    }
};

pub const ExtensionPair = struct {
    name: []const u8,
    data: []const u8,
};

pub const SshQuicReply = struct {
    server_connection_id: []const u8,
    server_quic_version: u32,
    transport_params: []const u8,
    signature_algorithms: []const []const u8,
    kex_algorithms: []const ServerKexAlgorithm,
    cipher_suite: []const u8,
    extensions: []const ExtensionPair,

    pub fn encode(self: SshQuicReply, buf: []u8, max_size: usize) ReplyError!usize {
        var pos: usize = 0;
        self.validateTransportParams() catch return error.InvalidTransportParameters;

        if (buf.len < 1) return error.BufferTooSmall;
        buf[pos] = SSH_QUIC_REPLY;
        pos += 1;

        if (self.server_connection_id.len > 255) return error.InvalidFormat;
        if (pos + 1 + self.server_connection_id.len > buf.len) return error.BufferTooSmall;
        buf[pos] = @intCast(self.server_connection_id.len);
        pos += 1;
        @memcpy(buf[pos..][0..self.server_connection_id.len], self.server_connection_id);
        pos += self.server_connection_id.len;

        if (pos + 4 > buf.len) return error.BufferTooSmall;
        std.mem.writeInt(u32, buf[pos..][0..4], self.server_quic_version, .big);
        pos += 4;

        pos += try varint.encode(self.transport_params.len, buf[pos..]);
        if (pos + self.transport_params.len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[pos..][0..self.transport_params.len], self.transport_params);
        pos += self.transport_params.len;

        if (self.signature_algorithms.len == 0 or self.signature_algorithms.len > 255) return error.InvalidFormat;
        if (pos + 1 > buf.len) return error.BufferTooSmall;
        buf[pos] = @intCast(self.signature_algorithms.len);
        pos += 1;
        for (self.signature_algorithms) |sig_alg| {
            pos += try varint.encode(sig_alg.len, buf[pos..]);
            if (pos + sig_alg.len > buf.len) return error.BufferTooSmall;
            @memcpy(buf[pos..][0..sig_alg.len], sig_alg);
            pos += sig_alg.len;
        }

        if (self.kex_algorithms.len == 0 or self.kex_algorithms.len > 255) return error.InvalidFormat;
        if (pos + 1 > buf.len) return error.BufferTooSmall;
        buf[pos] = @intCast(self.kex_algorithms.len);
        pos += 1;
        for (self.kex_algorithms) |kex| {
            if (kex.name.len == 0 or kex.name.len > 255) return error.InvalidFormat;
            if (pos + 1 + kex.name.len > buf.len) return error.BufferTooSmall;
            buf[pos] = @intCast(kex.name.len);
            pos += 1;
            @memcpy(buf[pos..][0..kex.name.len], kex.name);
            pos += kex.name.len;

            pos += try varint.encode(kex.data.len, buf[pos..]);
            if (pos + kex.data.len > buf.len) return error.BufferTooSmall;
            @memcpy(buf[pos..][0..kex.data.len], kex.data);
            pos += kex.data.len;
        }

        if (self.cipher_suite.len == 0 or self.cipher_suite.len > 255) return error.InvalidFormat;
        if (pos + 1 + self.cipher_suite.len > buf.len) return error.BufferTooSmall;
        buf[pos] = @intCast(self.cipher_suite.len);
        pos += 1;
        @memcpy(buf[pos..][0..self.cipher_suite.len], self.cipher_suite);
        pos += self.cipher_suite.len;

        if (self.extensions.len > 255) return error.InvalidFormat;
        if (pos + 1 > buf.len) return error.BufferTooSmall;
        buf[pos] = @intCast(self.extensions.len);
        pos += 1;
        for (self.extensions) |ext| {
            if (ext.name.len == 0 or ext.name.len > 255) return error.InvalidFormat;
            if (pos + 1 + ext.name.len > buf.len) return error.BufferTooSmall;
            buf[pos] = @intCast(ext.name.len);
            pos += 1;
            @memcpy(buf[pos..][0..ext.name.len], ext.name);
            pos += ext.name.len;

            pos += try varint.encode(ext.data.len, buf[pos..]);
            if (pos + ext.data.len > buf.len) return error.BufferTooSmall;
            @memcpy(buf[pos..][0..ext.data.len], ext.data);
            pos += ext.data.len;
        }

        if (pos > max_size) return error.AmplificationLimitExceeded;
        if (pos < max_size and pos < buf.len) {
            const padding_len = @min(max_size - pos, buf.len - pos);
            @memset(buf[pos..][0..padding_len], 0xFF);
            pos += padding_len;
        }

        return pos;
    }

    fn validateTransportParams(self: SshQuicReply) transport_params.TransportParamsError!void {
        _ = try transport_params.TransportParams.decode(std.heap.page_allocator, self.transport_params);
    }

    pub fn encodeEncrypted(self: SshQuicReply, allocator: std.mem.Allocator, key: obfuscation.ObfuscationKey, client_init_size: usize, output: []u8) ReplyError!usize {
        const max_payload_size = client_init_size * AMPLIFICATION_FACTOR;
        var plaintext_buf = try allocator.alloc(u8, max_payload_size + 1024);
        defer allocator.free(plaintext_buf);

        const plaintext_len = try self.encode(plaintext_buf, max_payload_size);
        return obfuscation.ObfuscatedEnvelope.encrypt(plaintext_buf[0..plaintext_len], key, output);
    }
};

pub const SshQuicErrorReply = struct {
    error_reason: []const u8,

    pub fn encode(self: SshQuicErrorReply, buf: []u8, max_size: usize) ReplyError!usize {
        var pos: usize = 0;
        if (buf.len < 1) return error.BufferTooSmall;
        buf[pos] = SSH_QUIC_ERROR_REPLY;
        pos += 1;

        if (pos + 1 > buf.len) return error.BufferTooSmall;
        buf[pos] = 0;
        pos += 1;

        if (pos + 4 > buf.len) return error.BufferTooSmall;
        std.mem.writeInt(u32, buf[pos..][0..4], 0, .big);
        pos += 4;

        pos += try varint.encode(self.error_reason.len, buf[pos..]);
        if (pos + self.error_reason.len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[pos..][0..self.error_reason.len], self.error_reason);
        pos += self.error_reason.len;

        if (pos > max_size) return error.AmplificationLimitExceeded;
        if (pos < max_size and pos < buf.len) {
            const padding_len = @min(max_size - pos, buf.len - pos);
            @memset(buf[pos..][0..padding_len], 0xFF);
            pos += padding_len;
        }

        return pos;
    }

    pub fn encodeEncrypted(self: SshQuicErrorReply, allocator: std.mem.Allocator, key: obfuscation.ObfuscationKey, client_init_size: usize, output: []u8) ReplyError!usize {
        const max_payload_size = client_init_size * AMPLIFICATION_FACTOR;
        var plaintext_buf = try allocator.alloc(u8, max_payload_size + 1024);
        defer allocator.free(plaintext_buf);

        const plaintext_len = try self.encode(plaintext_buf, max_payload_size);
        return obfuscation.ObfuscatedEnvelope.encrypt(plaintext_buf[0..plaintext_len], key, output);
    }
};

test "SSH_QUIC_REPLY encode basic" {
    const sig_algs = [_][]const u8{"ssh-ed25519"};
    const kex_algs = [_]ServerKexAlgorithm{.{ .name = "curve25519-sha256", .data = "server-key-data-here" }};

    const reply = SshQuicReply{
        .server_connection_id = &[_]u8{ 9, 10, 11, 12 },
        .server_quic_version = 0x00000001,
        .transport_params = &[_]u8{},
        .signature_algorithms = &sig_algs,
        .kex_algorithms = &kex_algs,
        .cipher_suite = "TLS_AES_256_GCM_SHA384",
        .extensions = &[_]ExtensionPair{},
    };

    var buf: [2048]u8 = undefined;
    const len = try reply.encode(&buf, 2048);
    try std.testing.expect(len > 0);
}
