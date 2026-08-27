const std = @import("std");
const Allocator = std.mem.Allocator;
const wire = @import("../protocol/wire.zig");

/// SFTP Protocol v3 (draft-ietf-secsh-filexfer-02)
///
/// SFTP runs over an SSH channel (subsystem "sftp").
/// All packets have: uint32(length) || byte(type) || type-specific-data

/// SFTP protocol version
pub const SFTP_VERSION = 3;

/// SFTP packet types
pub const PacketType = enum(u8) {
    SSH_FXP_INIT = 1,
    SSH_FXP_VERSION = 2,
    SSH_FXP_OPEN = 3,
    SSH_FXP_CLOSE = 4,
    SSH_FXP_READ = 5,
    SSH_FXP_WRITE = 6,
    SSH_FXP_LSTAT = 7,
    SSH_FXP_FSTAT = 8,
    SSH_FXP_SETSTAT = 9,
    SSH_FXP_FSETSTAT = 10,
    SSH_FXP_OPENDIR = 11,
    SSH_FXP_READDIR = 12,
    SSH_FXP_REMOVE = 13,
    SSH_FXP_MKDIR = 14,
    SSH_FXP_RMDIR = 15,
    SSH_FXP_REALPATH = 16,
    SSH_FXP_STAT = 17,
    SSH_FXP_RENAME = 18,
    SSH_FXP_READLINK = 19,
    SSH_FXP_SYMLINK = 20,
    SSH_FXP_STATUS = 101,
    SSH_FXP_HANDLE = 102,
    SSH_FXP_DATA = 103,
    SSH_FXP_NAME = 104,
    SSH_FXP_ATTRS = 105,
    SSH_FXP_EXTENDED = 200,
    SSH_FXP_EXTENDED_REPLY = 201,
};

/// SFTP status codes
pub const StatusCode = enum(u32) {
    SSH_FX_OK = 0,
    SSH_FX_EOF = 1,
    SSH_FX_NO_SUCH_FILE = 2,
    SSH_FX_PERMISSION_DENIED = 3,
    SSH_FX_FAILURE = 4,
    SSH_FX_BAD_MESSAGE = 5,
    SSH_FX_NO_CONNECTION = 6,
    SSH_FX_CONNECTION_LOST = 7,
    SSH_FX_OP_UNSUPPORTED = 8,
};

/// File open flags
pub const OpenFlags = packed struct(u32) {
    read: bool = false,
    write: bool = false,
    append: bool = false,
    creat: bool = false,
    trunc: bool = false,
    excl: bool = false,
    _padding: u26 = 0,

    pub const SSH_FXF_READ: u32 = 0x00000001;
    pub const SSH_FXF_WRITE: u32 = 0x00000002;
    pub const SSH_FXF_APPEND: u32 = 0x00000004;
    pub const SSH_FXF_CREAT: u32 = 0x00000008;
    pub const SSH_FXF_TRUNC: u32 = 0x00000010;
    pub const SSH_FXF_EXCL: u32 = 0x00000020;

    pub fn toU32(self: OpenFlags) u32 {
        return @bitCast(self);
    }

    pub fn fromU32(value: u32) OpenFlags {
        return @bitCast(value);
    }
};

/// SSH_FXP_INIT
pub const Init = struct {
    version: u32,

    pub fn encode(self: *const Init, allocator: Allocator) ![]u8 {
        const size = 4 + 1 + 4; // length + type + version
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };
        try writer.writeUint32(1 + 4); // packet length (type + version)
        try writer.writeByte(@intFromEnum(PacketType.SSH_FXP_INIT));
        try writer.writeUint32(self.version);

        return buffer;
    }

    pub fn decode(data: []const u8) !Init {
        var reader = wire.Reader{ .buffer = data };

        const length = try reader.readUint32();
        _ = length;

        const packet_type = try reader.readByte();
        if (packet_type != @intFromEnum(PacketType.SSH_FXP_INIT)) {
            return error.InvalidPacketType;
        }

        const version = try reader.readUint32();

        return Init{ .version = version };
    }
};

/// SSH_FXP_VERSION
pub const Version = struct {
    version: u32,
    extensions: []const []const u8, // name-value pairs

    pub fn encode(self: *const Version, allocator: Allocator) ![]u8 {
        var ext_size: usize = 0;
        for (self.extensions) |ext| {
            ext_size += 4 + ext.len;
        }

        const size = 4 + 1 + 4 + ext_size;
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };
        try writer.writeUint32(@intCast(1 + 4 + ext_size));
        try writer.writeByte(@intFromEnum(PacketType.SSH_FXP_VERSION));
        try writer.writeUint32(self.version);

        for (self.extensions) |ext| {
            try writer.writeString(ext);
        }

        return buffer;
    }

    pub fn decode(allocator: Allocator, data: []const u8) !Version {
        var reader = wire.Reader{ .buffer = data };

        const length = try reader.readUint32();
        const packet_type = try reader.readByte();
        if (packet_type != @intFromEnum(PacketType.SSH_FXP_VERSION)) {
            return error.InvalidPacketType;
        }

        const version = try reader.readUint32();

        // Read extensions (name-value pairs)
        const ext_start = reader.offset;
        const ext_end = 4 + length; // 4 for length field itself
        var ext_count: usize = 0;

        // Count extensions
        while (reader.offset < ext_end) {
            _ = try reader.readString(allocator);
            ext_count += 1;
        }

        // Reset and read extensions
        reader.offset = ext_start;
        const extensions = try allocator.alloc([]u8, ext_count);
        errdefer allocator.free(extensions);

        var i: usize = 0;
        errdefer {
            for (extensions[0..i]) |ext| {
                allocator.free(ext);
            }
        }

        while (i < ext_count) : (i += 1) {
            extensions[i] = try reader.readString(allocator);
        }

        return Version{
            .version = version,
            .extensions = extensions,
        };
    }

    pub fn deinit(self: *Version, allocator: Allocator) void {
        for (self.extensions) |ext| {
            allocator.free(ext);
        }
        allocator.free(self.extensions);
    }
};

/// SSH_FXP_STATUS
pub const Status = struct {
    request_id: u32,
    status_code: StatusCode,
    error_message: []const u8,
    language_tag: []const u8,

    pub fn encode(self: *const Status, allocator: Allocator) ![]u8 {
        const size = 4 + 1 + 4 + 4 + 4 + self.error_message.len + 4 + self.language_tag.len;
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };
        try writer.writeUint32(@intCast(size - 4));
        try writer.writeByte(@intFromEnum(PacketType.SSH_FXP_STATUS));
        try writer.writeUint32(self.request_id);
        try writer.writeUint32(@intFromEnum(self.status_code));
        try writer.writeString(self.error_message);
        try writer.writeString(self.language_tag);

        return buffer;
    }

    pub fn decode(allocator: Allocator, data: []const u8) !Status {
        var reader = wire.Reader{ .buffer = data };

        _ = try reader.readUint32(); // length
        const packet_type = try reader.readByte();
        if (packet_type != @intFromEnum(PacketType.SSH_FXP_STATUS)) {
            return error.InvalidPacketType;
        }

        const request_id = try reader.readUint32();
        const status_code_val = try reader.readUint32();
        const status_code: StatusCode = @enumFromInt(status_code_val);

        const error_message = try reader.readString(allocator);
        errdefer allocator.free(error_message);

        const language_tag = try reader.readString(allocator);

        return Status{
            .request_id = request_id,
            .status_code = status_code,
            .error_message = error_message,
            .language_tag = language_tag,
        };
    }

    pub fn deinit(self: *Status, allocator: Allocator) void {
        allocator.free(self.error_message);
        allocator.free(self.language_tag);
    }
};

/// SSH_FXP_HANDLE
pub const Handle = struct {
    request_id: u32,
    handle: []const u8,

    pub fn encode(self: *const Handle, allocator: Allocator) ![]u8 {
        const size = 4 + 1 + 4 + 4 + self.handle.len;
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };
        try writer.writeUint32(@intCast(size - 4));
        try writer.writeByte(@intFromEnum(PacketType.SSH_FXP_HANDLE));
        try writer.writeUint32(self.request_id);
        try writer.writeString(self.handle);

        return buffer;
    }

    pub fn decode(allocator: Allocator, data: []const u8) !Handle {
        var reader = wire.Reader{ .buffer = data };

        _ = try reader.readUint32(); // length
        const packet_type = try reader.readByte();
        if (packet_type != @intFromEnum(PacketType.SSH_FXP_HANDLE)) {
            return error.InvalidPacketType;
        }

        const request_id = try reader.readUint32();
        const handle = try reader.readString(allocator);

        return Handle{
            .request_id = request_id,
            .handle = handle,
        };
    }

    pub fn deinit(self: *Handle, allocator: Allocator) void {
        allocator.free(self.handle);
    }
};

/// SSH_FXP_DATA
pub const Data = struct {
    request_id: u32,
    data: []const u8,

    pub fn encode(self: *const Data, allocator: Allocator) ![]u8 {
        const size = 4 + 1 + 4 + 4 + self.data.len;
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };
        try writer.writeUint32(@intCast(size - 4));
        try writer.writeByte(@intFromEnum(PacketType.SSH_FXP_DATA));
        try writer.writeUint32(self.request_id);
        try writer.writeString(self.data);

        return buffer;
    }

    pub fn decode(allocator: Allocator, data: []const u8) !Data {
        var reader = wire.Reader{ .buffer = data };

        _ = try reader.readUint32(); // length
        const packet_type = try reader.readByte();
        if (packet_type != @intFromEnum(PacketType.SSH_FXP_DATA)) {
            return error.InvalidPacketType;
        }

        const request_id = try reader.readUint32();
        const payload = try reader.readString(allocator);

        return Data{
            .request_id = request_id,
            .data = payload,
        };
    }

    pub fn deinit(self: *Data, allocator: Allocator) void {
        allocator.free(self.data);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "OpenFlags - encode and decode" {
    const testing = std.testing;

    var flags = OpenFlags{
        .read = true,
        .write = true,
        .creat = true,
    };

    const value = flags.toU32();
    try testing.expect((value & OpenFlags.SSH_FXF_READ) != 0);
    try testing.expect((value & OpenFlags.SSH_FXF_WRITE) != 0);
    try testing.expect((value & OpenFlags.SSH_FXF_CREAT) != 0);

    const decoded = OpenFlags.fromU32(value);
    try testing.expectEqual(true, decoded.read);
    try testing.expectEqual(true, decoded.write);
    try testing.expectEqual(true, decoded.creat);
}

test "Init - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const init = Init{ .version = SFTP_VERSION };

    const encoded = try init.encode(allocator);
    defer allocator.free(encoded);

    const decoded = try Init.decode(encoded);
    try testing.expectEqual(SFTP_VERSION, decoded.version);
}

test "Version - encode and decode without extensions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const extensions: []const []const u8 = &.{};
    var version = Version{
        .version = SFTP_VERSION,
        .extensions = extensions,
    };

    const encoded = try version.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try Version.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqual(SFTP_VERSION, decoded.version);
    try testing.expectEqual(@as(usize, 0), decoded.extensions.len);
}

test "Status - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const status = Status{
        .request_id = 42,
        .status_code = .SSH_FX_OK,
        .error_message = "Success",
        .language_tag = "en",
    };

    const encoded = try status.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try Status.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqual(@as(u32, 42), decoded.request_id);
    try testing.expectEqual(StatusCode.SSH_FX_OK, decoded.status_code);
    try testing.expectEqualStrings("Success", decoded.error_message);
    try testing.expectEqualStrings("en", decoded.language_tag);
}

test "Handle - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const handle_data = "test_handle_12345";
    const handle = Handle{
        .request_id = 99,
        .handle = handle_data,
    };

    const encoded = try handle.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try Handle.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqual(@as(u32, 99), decoded.request_id);
    try testing.expectEqualStrings(handle_data, decoded.handle);
}

test "Data - encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const file_data = "Hello, SFTP world!";
    const data = Data{
        .request_id = 123,
        .data = file_data,
    };

    const encoded = try data.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try Data.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expectEqual(@as(u32, 123), decoded.request_id);
    try testing.expectEqualStrings(file_data, decoded.data);
}
