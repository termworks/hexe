const std = @import("std");
const Allocator = std.mem.Allocator;
const wire = @import("wire.zig");
const constants = @import("../common/constants.zig");

/// SSH_MSG_EXT_INFO implementation per RFC 8308
///
/// Extension info mechanism allows SSH implementations to send information
/// about supported extensions after SSH_MSG_NEWKEYS or during user authentication.
///
/// For SSH/QUIC, the "ssh-version" extension is required to indicate SSH/QUIC support.

/// Extension name-value pair
pub const Extension = struct {
    name: []const u8,
    value: []const u8,

    /// Free allocated memory
    pub fn deinit(self: *Extension, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

/// SSH_MSG_EXT_INFO message
///
/// Format:
///   byte      SSH_MSG_EXT_INFO
///   uint32    nr-extensions
///   repeat nr-extensions times:
///     string    extension-name
///     string    extension-value
pub const ExtInfo = struct {
    extensions: []const Extension,

    /// Create ExtInfo with extensions
    pub fn init(allocator: Allocator, extensions: []const Extension) !ExtInfo {
        const ext_copy = try allocator.alloc(Extension, extensions.len);
        for (extensions, 0..) |ext, i| {
            const name = try allocator.dupe(u8, ext.name);
            errdefer allocator.free(name);
            const value = try allocator.dupe(u8, ext.value);
            ext_copy[i] = .{ .name = name, .value = value };
        }
        return ExtInfo{ .extensions = ext_copy };
    }

    /// Free allocated memory
    pub fn deinit(self: *ExtInfo, allocator: Allocator) void {
        for (self.extensions) |*ext| {
            allocator.free(ext.name);
            allocator.free(ext.value);
        }
        allocator.free(self.extensions);
    }

    /// Encode SSH_MSG_EXT_INFO
    pub fn encode(self: *const ExtInfo, allocator: Allocator) ![]u8 {
        // Calculate total size
        var size: usize = 1 + 4; // msg type + nr-extensions
        for (self.extensions) |ext| {
            size += 4 + ext.name.len; // string(name)
            size += 4 + ext.value.len; // string(value)
        }

        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };
        try writer.writeByte(constants.SSH_MSG.EXT_INFO);
        try writer.writeUint32(@intCast(self.extensions.len));

        for (self.extensions) |ext| {
            try writer.writeString(ext.name);
            try writer.writeString(ext.value);
        }

        return buffer;
    }

    /// Decode SSH_MSG_EXT_INFO
    pub fn decode(allocator: Allocator, data: []const u8) !ExtInfo {
        var reader = wire.Reader{ .buffer = data };

        const msg_type = try reader.readByte();
        if (msg_type != constants.SSH_MSG.EXT_INFO) {
            return error.InvalidMessageType;
        }

        const nr_extensions = try reader.readUint32();
        const extensions = try allocator.alloc(Extension, nr_extensions);
        errdefer allocator.free(extensions);

        var i: usize = 0;
        errdefer {
            // Clean up any successfully read extensions
            for (extensions[0..i]) |*ext| {
                allocator.free(ext.name);
                allocator.free(ext.value);
            }
        }

        while (i < nr_extensions) : (i += 1) {
            const name = try reader.readString(allocator);
            errdefer allocator.free(name);

            const value = try reader.readString(allocator);

            extensions[i] = .{ .name = name, .value = value };
        }

        return ExtInfo{ .extensions = extensions };
    }

    /// Get extension value by name
    pub fn getExtension(self: *const ExtInfo, name: []const u8) ?[]const u8 {
        for (self.extensions) |ext| {
            if (std.mem.eql(u8, ext.name, name)) {
                return ext.value;
            }
        }
        return null;
    }

    /// Check if extension exists
    pub fn hasExtension(self: *const ExtInfo, name: []const u8) bool {
        return self.getExtension(name) != null;
    }
};

// SSH/QUIC specific extension names
pub const ssh_version_ext = "ssh-version";
pub const server_sig_algs_ext = "server-sig-algs";
pub const delay_compression_ext = "delay-compression";
pub const no_flow_control_ext = "no-flow-control";
pub const elevation_ext = "elevation";

/// Create ExtInfo with ssh-version extension for SSH/QUIC
pub fn createSshQuicExtInfo(allocator: Allocator, version: []const u8) !ExtInfo {
    const extensions = try allocator.alloc(Extension, 1);
    errdefer allocator.free(extensions);

    const name = try allocator.dupe(u8, ssh_version_ext);
    errdefer allocator.free(name);

    const value = try allocator.dupe(u8, version);

    extensions[0] = .{ .name = name, .value = value };

    return ExtInfo{ .extensions = extensions };
}

// ============================================================================
// Tests
// ============================================================================

test "Extension - basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const name = try allocator.dupe(u8, "test-extension");
    const value = try allocator.dupe(u8, "test-value");

    var ext = Extension{ .name = name, .value = value };
    defer ext.deinit(allocator);

    try testing.expectEqualStrings("test-extension", ext.name);
    try testing.expectEqualStrings("test-value", ext.value);
}

test "ExtInfo - encode and decode empty" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const empty_extensions: []const Extension = &.{};
    var ext_info = try ExtInfo.init(allocator, empty_extensions);
    defer ext_info.deinit(allocator);

    const encoded = try ext_info.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try ExtInfo.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), decoded.extensions.len);
}

test "ExtInfo - encode and decode single extension" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const name1 = try allocator.dupe(u8, "server-sig-algs");
    const value1 = try allocator.dupe(u8, "ssh-ed25519,ssh-rsa");

    const extensions = [_]Extension{
        .{ .name = name1, .value = value1 },
    };

    var ext_info = try ExtInfo.init(allocator, &extensions);
    defer ext_info.deinit(allocator);

    // Free the original allocations since init() makes copies
    allocator.free(name1);
    allocator.free(value1);

    const encoded = try ext_info.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try ExtInfo.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), decoded.extensions.len);
    try testing.expectEqualStrings("server-sig-algs", decoded.extensions[0].name);
    try testing.expectEqualStrings("ssh-ed25519,ssh-rsa", decoded.extensions[0].value);
}

test "ExtInfo - encode and decode multiple extensions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const name1 = try allocator.dupe(u8, "ssh-version");
    const value1 = try allocator.dupe(u8, "SSH-QUIC-00");

    const name2 = try allocator.dupe(u8, "server-sig-algs");
    const value2 = try allocator.dupe(u8, "ssh-ed25519");

    const name3 = try allocator.dupe(u8, "delay-compression");
    const value3 = try allocator.dupe(u8, "zlib@openssh.com");

    const extensions = [_]Extension{
        .{ .name = name1, .value = value1 },
        .{ .name = name2, .value = value2 },
        .{ .name = name3, .value = value3 },
    };

    var ext_info = try ExtInfo.init(allocator, &extensions);
    defer ext_info.deinit(allocator);

    // Free originals
    allocator.free(name1);
    allocator.free(value1);
    allocator.free(name2);
    allocator.free(value2);
    allocator.free(name3);
    allocator.free(value3);

    const encoded = try ext_info.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try ExtInfo.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), decoded.extensions.len);
    try testing.expectEqualStrings("ssh-version", decoded.extensions[0].name);
    try testing.expectEqualStrings("SSH-QUIC-00", decoded.extensions[0].value);
    try testing.expectEqualStrings("server-sig-algs", decoded.extensions[1].name);
    try testing.expectEqualStrings("ssh-ed25519", decoded.extensions[1].value);
}

test "ExtInfo - getExtension" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const name1 = try allocator.dupe(u8, "ssh-version");
    const value1 = try allocator.dupe(u8, "SSH-QUIC-00");

    const name2 = try allocator.dupe(u8, "test-ext");
    const value2 = try allocator.dupe(u8, "test-value");

    const extensions = [_]Extension{
        .{ .name = name1, .value = value1 },
        .{ .name = name2, .value = value2 },
    };

    var ext_info = try ExtInfo.init(allocator, &extensions);
    defer ext_info.deinit(allocator);

    allocator.free(name1);
    allocator.free(value1);
    allocator.free(name2);
    allocator.free(value2);

    // Get existing extension
    const ssh_ver = ext_info.getExtension("ssh-version");
    try testing.expect(ssh_ver != null);
    try testing.expectEqualStrings("SSH-QUIC-00", ssh_ver.?);

    // Get non-existent extension
    const missing = ext_info.getExtension("non-existent");
    try testing.expect(missing == null);
}

test "ExtInfo - hasExtension" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const name1 = try allocator.dupe(u8, "ssh-version");
    const value1 = try allocator.dupe(u8, "SSH-QUIC-00");

    const extensions = [_]Extension{
        .{ .name = name1, .value = value1 },
    };

    var ext_info = try ExtInfo.init(allocator, &extensions);
    defer ext_info.deinit(allocator);

    allocator.free(name1);
    allocator.free(value1);

    try testing.expect(ext_info.hasExtension("ssh-version"));
    try testing.expect(!ext_info.hasExtension("missing-ext"));
}

test "createSshQuicExtInfo - basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ext_info = try createSshQuicExtInfo(allocator, "SSH-QUIC-00");
    defer ext_info.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), ext_info.extensions.len);
    try testing.expectEqualStrings("ssh-version", ext_info.extensions[0].name);
    try testing.expectEqualStrings("SSH-QUIC-00", ext_info.extensions[0].value);

    // Verify it can be encoded/decoded
    const encoded = try ext_info.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try ExtInfo.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    const ssh_ver = decoded.getExtension("ssh-version");
    try testing.expect(ssh_ver != null);
    try testing.expectEqualStrings("SSH-QUIC-00", ssh_ver.?);
}

test "ExtInfo - message type validation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create invalid message (wrong type)
    var buffer: [5]u8 = undefined;
    buffer[0] = 99; // Wrong message type
    std.mem.writeInt(u32, buffer[1..5], 0, .big);

    const result = ExtInfo.decode(allocator, &buffer);
    try testing.expectError(error.InvalidMessageType, result);
}

test "ExtInfo - encode structure" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const name = try allocator.dupe(u8, "test");
    const value = try allocator.dupe(u8, "value");

    const extensions = [_]Extension{
        .{ .name = name, .value = value },
    };

    var ext_info = try ExtInfo.init(allocator, &extensions);
    defer ext_info.deinit(allocator);

    allocator.free(name);
    allocator.free(value);

    const encoded = try ext_info.encode(allocator);
    defer allocator.free(encoded);

    // Verify message type
    try testing.expectEqual(constants.SSH_MSG.EXT_INFO, encoded[0]);

    // Verify nr-extensions
    const nr_ext = std.mem.readInt(u32, encoded[1..5], .big);
    try testing.expectEqual(@as(u32, 1), nr_ext);
}
