const std = @import("std");
const varint = @import("../../utils/varint.zig");
const obfuscation = @import("libsafe").ssh_obfuscation;

pub const SSH_QUIC_CANCEL: u8 = 3;

pub const CancelError = error{
    InvalidFormat,
    BufferTooSmall,
    EncodingFailed,
    DecodingFailed,
    OutOfMemory,
} || varint.VarintError || obfuscation.ObfuscationError;

pub const ExtensionPair = struct {
    name: []const u8,
    data: []const u8,
};

pub const SshQuicCancel = struct {
    reason_phrase: []const u8,
    extensions: []const ExtensionPair,

    pub fn init(reason: []const u8) SshQuicCancel {
        return .{ .reason_phrase = reason, .extensions = &[_]ExtensionPair{} };
    }

    pub fn unsupportedVersion() SshQuicCancel {
        return init("Unsupported QUIC version");
    }

    pub fn unsupportedKex() SshQuicCancel {
        return init("No compatible key exchange algorithm");
    }

    pub fn unsupportedCipherSuite() SshQuicCancel {
        return init("No compatible cipher suite");
    }

    pub fn protocolError(reason: []const u8) SshQuicCancel {
        return init(reason);
    }

    pub fn encode(self: SshQuicCancel, buf: []u8) CancelError!usize {
        var pos: usize = 0;
        if (buf.len < 1) return error.BufferTooSmall;
        buf[pos] = SSH_QUIC_CANCEL;
        pos += 1;

        pos += try varint.encode(self.reason_phrase.len, buf[pos..]);
        if (pos + self.reason_phrase.len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[pos..][0..self.reason_phrase.len], self.reason_phrase);
        pos += self.reason_phrase.len;

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

        return pos;
    }

    pub fn encodeWithPadding(self: SshQuicCancel, buf: []u8, min_size: usize) CancelError!usize {
        const base_len = try self.encode(buf);
        if (base_len < min_size) {
            const padding_len = @min(min_size - base_len, buf.len - base_len);
            if (base_len + padding_len > buf.len) return error.BufferTooSmall;
            @memset(buf[base_len..][0..padding_len], 0xFF);
            return base_len + padding_len;
        }
        return base_len;
    }

    pub fn encodeEncrypted(self: SshQuicCancel, allocator: std.mem.Allocator, key: obfuscation.ObfuscationKey, output: []u8) CancelError!usize {
        var plaintext_buf = try allocator.alloc(u8, 1024);
        defer allocator.free(plaintext_buf);

        const plaintext_len = try self.encode(plaintext_buf);
        return obfuscation.ObfuscatedEnvelope.encrypt(plaintext_buf[0..plaintext_len], key, output);
    }

    pub fn decode(allocator: std.mem.Allocator, buf: []const u8) CancelError!SshQuicCancel {
        var pos: usize = 0;
        if (buf.len < 1) return error.BufferTooSmall;
        if (buf[pos] != SSH_QUIC_CANCEL) return error.InvalidFormat;
        pos += 1;

        const reason_result = try varint.decode(buf[pos..]);
        pos += reason_result.len;
        const reason_len = reason_result.value;
        if (pos + reason_len > buf.len) return error.BufferTooSmall;
        const reason_phrase = try allocator.dupe(u8, buf[pos..][0..reason_len]);
        pos += reason_len;

        if (pos >= buf.len) return error.BufferTooSmall;
        const nr_ext = buf[pos];
        pos += 1;

        var extensions = try allocator.alloc(ExtensionPair, nr_ext);
        errdefer allocator.free(extensions);

        for (0..nr_ext) |i| {
            if (pos >= buf.len) return error.BufferTooSmall;
            const name_len = buf[pos];
            pos += 1;

            if (name_len == 0) return error.InvalidFormat;
            if (pos + name_len > buf.len) return error.BufferTooSmall;
            const name = try allocator.dupe(u8, buf[pos..][0..name_len]);
            pos += name_len;

            const data_result = try varint.decode(buf[pos..]);
            pos += data_result.len;
            const data_len = data_result.value;

            if (pos + data_len > buf.len) return error.BufferTooSmall;
            const data = try allocator.dupe(u8, buf[pos..][0..data_len]);
            pos += data_len;

            extensions[i] = .{ .name = name, .data = data };
        }

        return .{ .reason_phrase = reason_phrase, .extensions = extensions };
    }

    pub fn deinit(self: *SshQuicCancel, allocator: std.mem.Allocator) void {
        allocator.free(self.reason_phrase);
        for (self.extensions) |ext| {
            allocator.free(ext.name);
            allocator.free(ext.data);
        }
        allocator.free(self.extensions);
    }
};

test "SSH_QUIC_CANCEL encode and decode" {
    const allocator = std.testing.allocator;
    const original = SshQuicCancel.init("Test cancellation");

    var buf: [512]u8 = undefined;
    const len = try original.encode(&buf);

    var decoded = try SshQuicCancel.decode(allocator, buf[0..len]);
    defer decoded.deinit(allocator);
    try std.testing.expectEqualStrings(original.reason_phrase, decoded.reason_phrase);
}
