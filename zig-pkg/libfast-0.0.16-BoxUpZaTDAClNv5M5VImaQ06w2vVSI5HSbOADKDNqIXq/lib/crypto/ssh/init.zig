const std = @import("std");
const varint = @import("../../utils/varint.zig");
const obfuscation = @import("libsafe").ssh_obfuscation;
const transport_params = @import("../../core/transport_params.zig");

pub const SSH_QUIC_INIT: u8 = 1;
pub const MIN_PAYLOAD_SIZE: usize = 1200;

pub const InitError = error{
    InvalidFormat,
    BufferTooSmall,
    EncodingFailed,
    DecodingFailed,
    PayloadTooSmall,
    InvalidTransportParameters,
    OutOfMemory,
} || varint.VarintError || obfuscation.ObfuscationError;

pub const KexAlgorithm = struct {
    name: []const u8,
    data: []const u8,

    pub fn isEmpty(self: KexAlgorithm) bool {
        return self.data.len == 0;
    }
};

pub const ExtensionPair = struct {
    name: []const u8,
    data: []const u8,
};

pub const SshQuicInit = struct {
    client_connection_id: []const u8,
    server_name_indication: []const u8,
    quic_versions: []const u32,
    transport_params: []const u8,
    signature_algorithms: []const u8,
    trusted_fingerprints: []const []const u8,
    kex_algorithms: []const KexAlgorithm,
    cipher_suites: []const []const u8,
    extensions: []const ExtensionPair,

    pub fn encode(self: SshQuicInit, buf: []u8) InitError!usize {
        var pos: usize = 0;

        self.validateTransportParams() catch return error.InvalidTransportParameters;

        if (buf.len < 1) return error.BufferTooSmall;
        buf[pos] = SSH_QUIC_INIT;
        pos += 1;

        if (self.client_connection_id.len > 255) return error.InvalidFormat;
        if (pos + 1 + self.client_connection_id.len > buf.len) return error.BufferTooSmall;
        buf[pos] = @intCast(self.client_connection_id.len);
        pos += 1;
        @memcpy(buf[pos..][0..self.client_connection_id.len], self.client_connection_id);
        pos += self.client_connection_id.len;

        if (self.server_name_indication.len > 255) return error.InvalidFormat;
        if (pos + 1 + self.server_name_indication.len > buf.len) return error.BufferTooSmall;
        buf[pos] = @intCast(self.server_name_indication.len);
        pos += 1;
        @memcpy(buf[pos..][0..self.server_name_indication.len], self.server_name_indication);
        pos += self.server_name_indication.len;

        if (self.quic_versions.len == 0 or self.quic_versions.len > 255) return error.InvalidFormat;
        if (pos + 1 > buf.len) return error.BufferTooSmall;
        buf[pos] = @intCast(self.quic_versions.len);
        pos += 1;
        for (self.quic_versions) |version| {
            if (pos + 4 > buf.len) return error.BufferTooSmall;
            std.mem.writeInt(u32, buf[pos..][0..4], version, .big);
            pos += 4;
        }

        pos += try varint.encode(self.transport_params.len, buf[pos..]);
        if (pos + self.transport_params.len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[pos..][0..self.transport_params.len], self.transport_params);
        pos += self.transport_params.len;

        if (self.signature_algorithms.len == 0) return error.InvalidFormat;
        pos += try varint.encode(self.signature_algorithms.len, buf[pos..]);
        if (pos + self.signature_algorithms.len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[pos..][0..self.signature_algorithms.len], self.signature_algorithms);
        pos += self.signature_algorithms.len;

        if (self.trusted_fingerprints.len > 255) return error.InvalidFormat;
        if (pos + 1 > buf.len) return error.BufferTooSmall;
        buf[pos] = @intCast(self.trusted_fingerprints.len);
        pos += 1;
        for (self.trusted_fingerprints) |fp| {
            if (fp.len == 0 or fp.len > 255) return error.InvalidFormat;
            if (pos + 1 + fp.len > buf.len) return error.BufferTooSmall;
            buf[pos] = @intCast(fp.len);
            pos += 1;
            @memcpy(buf[pos..][0..fp.len], fp);
            pos += fp.len;
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

        if (self.cipher_suites.len == 0 or self.cipher_suites.len > 255) return error.InvalidFormat;
        if (pos + 1 > buf.len) return error.BufferTooSmall;
        buf[pos] = @intCast(self.cipher_suites.len);
        pos += 1;
        for (self.cipher_suites) |suite| {
            if (suite.len > 255) return error.InvalidFormat;
            if (pos + 1 + suite.len > buf.len) return error.BufferTooSmall;
            buf[pos] = @intCast(suite.len);
            pos += 1;
            @memcpy(buf[pos..][0..suite.len], suite);
            pos += suite.len;
        }

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

        if (pos < MIN_PAYLOAD_SIZE) {
            const padding_len = MIN_PAYLOAD_SIZE - pos;
            if (pos + padding_len > buf.len) return error.BufferTooSmall;
            @memset(buf[pos..][0..padding_len], 0xFF);
            pos += padding_len;
        }

        return pos;
    }

    fn validateTransportParams(self: SshQuicInit) transport_params.TransportParamsError!void {
        _ = try transport_params.TransportParams.decode(std.heap.page_allocator, self.transport_params);
    }

    pub fn encodeEncrypted(self: SshQuicInit, allocator: std.mem.Allocator, key: obfuscation.ObfuscationKey, output: []u8) InitError!usize {
        var plaintext_buf = try allocator.alloc(u8, MIN_PAYLOAD_SIZE + 1024);
        defer allocator.free(plaintext_buf);

        const plaintext_len = try self.encode(plaintext_buf);
        return obfuscation.ObfuscatedEnvelope.encrypt(plaintext_buf[0..plaintext_len], key, output);
    }
};

test "SSH_QUIC_INIT encode basic" {
    const versions = [_]u32{0x00000001};
    const kex_algs = [_]KexAlgorithm{.{ .name = "curve25519-sha256", .data = "test-kex-data" }};
    const cipher_suites = [_][]const u8{"TLS_AES_256_GCM_SHA384"};

    const init_packet = SshQuicInit{
        .client_connection_id = &[_]u8{ 1, 2, 3, 4 },
        .server_name_indication = "example.com",
        .quic_versions = &versions,
        .transport_params = &[_]u8{},
        .signature_algorithms = "ssh-ed25519",
        .trusted_fingerprints = &[_][]const u8{},
        .kex_algorithms = &kex_algs,
        .cipher_suites = &cipher_suites,
        .extensions = &[_]ExtensionPair{},
    };

    var buf: [2048]u8 = undefined;
    const len = try init_packet.encode(&buf);
    try std.testing.expect(len >= MIN_PAYLOAD_SIZE);
}
