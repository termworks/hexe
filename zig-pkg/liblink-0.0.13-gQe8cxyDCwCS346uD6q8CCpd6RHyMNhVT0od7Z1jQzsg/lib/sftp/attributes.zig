const std = @import("std");
const Allocator = std.mem.Allocator;
const wire = @import("../protocol/wire.zig");

/// SFTP file attributes per SFTP v3

/// Attribute flags
pub const AttrFlags = packed struct(u32) {
    size: bool = false,
    uidgid: bool = false,
    permissions: bool = false,
    acmodtime: bool = false,
    _padding: u28 = 0,

    pub const SSH_FILEXFER_ATTR_SIZE: u32 = 0x00000001;
    pub const SSH_FILEXFER_ATTR_UIDGID: u32 = 0x00000002;
    pub const SSH_FILEXFER_ATTR_PERMISSIONS: u32 = 0x00000004;
    pub const SSH_FILEXFER_ATTR_ACMODTIME: u32 = 0x00000008;

    pub fn toU32(self: AttrFlags) u32 {
        return @bitCast(self);
    }

    pub fn fromU32(value: u32) AttrFlags {
        return @bitCast(value);
    }
};

/// File type from permission bits
pub const FileType = enum(u4) {
    regular = 0,
    directory = 1,
    symlink = 2,
    special = 3,
    unknown = 15,

    pub fn fromPermissions(perms: u32) FileType {
        const S_IFMT: u32 = 0o170000;
        const S_IFREG: u32 = 0o100000;
        const S_IFDIR: u32 = 0o040000;
        const S_IFLNK: u32 = 0o120000;

        const file_type = perms & S_IFMT;
        if (file_type == S_IFREG) return .regular;
        if (file_type == S_IFDIR) return .directory;
        if (file_type == S_IFLNK) return .symlink;
        if (file_type != 0) return .special;
        return .unknown;
    }
};

/// File attributes
pub const FileAttributes = struct {
    flags: AttrFlags,
    size: ?u64 = null,
    uid: ?u32 = null,
    gid: ?u32 = null,
    permissions: ?u32 = null,
    atime: ?u32 = null,
    mtime: ?u32 = null,

    /// Create attributes with only specific fields
    pub fn init() FileAttributes {
        return .{
            .flags = AttrFlags{},
        };
    }

    /// Set file size
    pub fn withSize(self: *FileAttributes, size: u64) *FileAttributes {
        self.size = size;
        self.flags.size = true;
        return self;
    }

    /// Set uid/gid
    pub fn withUidGid(self: *FileAttributes, uid: u32, gid: u32) *FileAttributes {
        self.uid = uid;
        self.gid = gid;
        self.flags.uidgid = true;
        return self;
    }

    /// Set permissions
    pub fn withPermissions(self: *FileAttributes, permissions: u32) *FileAttributes {
        self.permissions = permissions;
        self.flags.permissions = true;
        return self;
    }

    /// Set access and modification times
    pub fn withTimes(self: *FileAttributes, atime: u32, mtime: u32) *FileAttributes {
        self.atime = atime;
        self.mtime = mtime;
        self.flags.acmodtime = true;
        return self;
    }

    /// Get file type from permissions
    pub fn getFileType(self: *const FileAttributes) FileType {
        if (self.permissions) |perms| {
            return FileType.fromPermissions(perms);
        }
        return .unknown;
    }

    /// Check if this is a directory
    pub fn isDirectory(self: *const FileAttributes) bool {
        return self.getFileType() == .directory;
    }

    /// Check if this is a regular file
    pub fn isRegularFile(self: *const FileAttributes) bool {
        return self.getFileType() == .regular;
    }

    /// Encode attributes to wire format
    pub fn encode(self: *const FileAttributes, allocator: Allocator) ![]u8 {
        var size: usize = 4; // flags

        if (self.flags.size) size += 8;
        if (self.flags.uidgid) size += 8;
        if (self.flags.permissions) size += 4;
        if (self.flags.acmodtime) size += 8;

        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };
        try writer.writeUint32(self.flags.toU32());

        if (self.flags.size) {
            try writer.writeUint64(self.size.?);
        }
        if (self.flags.uidgid) {
            try writer.writeUint32(self.uid.?);
            try writer.writeUint32(self.gid.?);
        }
        if (self.flags.permissions) {
            try writer.writeUint32(self.permissions.?);
        }
        if (self.flags.acmodtime) {
            try writer.writeUint32(self.atime.?);
            try writer.writeUint32(self.mtime.?);
        }

        return buffer;
    }

    /// Decode attributes from wire format
    pub fn decode(data: []const u8) !FileAttributes {
        var reader = wire.Reader{ .buffer = data };

        const flags_val = try reader.readUint32();
        const flags = AttrFlags.fromU32(flags_val);

        var attrs = FileAttributes{ .flags = flags };

        if (flags.size) {
            attrs.size = try reader.readUint64();
        }
        if (flags.uidgid) {
            attrs.uid = try reader.readUint32();
            attrs.gid = try reader.readUint32();
        }
        if (flags.permissions) {
            attrs.permissions = try reader.readUint32();
        }
        if (flags.acmodtime) {
            attrs.atime = try reader.readUint32();
            attrs.mtime = try reader.readUint32();
        }

        return attrs;
    }
};

/// Standard Unix permission bits
pub const Permissions = struct {
    pub const S_IRUSR: u32 = 0o0400; // Owner read
    pub const S_IWUSR: u32 = 0o0200; // Owner write
    pub const S_IXUSR: u32 = 0o0100; // Owner execute
    pub const S_IRGRP: u32 = 0o0040; // Group read
    pub const S_IWGRP: u32 = 0o0020; // Group write
    pub const S_IXGRP: u32 = 0o0010; // Group execute
    pub const S_IROTH: u32 = 0o0004; // Others read
    pub const S_IWOTH: u32 = 0o0002; // Others write
    pub const S_IXOTH: u32 = 0o0001; // Others execute

    pub const S_IRWXU: u32 = S_IRUSR | S_IWUSR | S_IXUSR; // Owner rwx
    pub const S_IRWXG: u32 = S_IRGRP | S_IWGRP | S_IXGRP; // Group rwx
    pub const S_IRWXO: u32 = S_IROTH | S_IWOTH | S_IXOTH; // Others rwx

    /// Standard file permissions (0644)
    pub const FILE_DEFAULT: u32 = 0o100644;

    /// Standard directory permissions (0755)
    pub const DIR_DEFAULT: u32 = 0o040755;

    /// Create file permissions from octal mode
    pub fn file(mode: u32) u32 {
        return 0o100000 | mode;
    }

    /// Create directory permissions from octal mode
    pub fn dir(mode: u32) u32 {
        return 0o040000 | mode;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "AttrFlags - encode and decode" {
    const testing = std.testing;

    var flags = AttrFlags{
        .size = true,
        .permissions = true,
    };

    const value = flags.toU32();
    try testing.expect((value & AttrFlags.SSH_FILEXFER_ATTR_SIZE) != 0);
    try testing.expect((value & AttrFlags.SSH_FILEXFER_ATTR_PERMISSIONS) != 0);
    try testing.expect((value & AttrFlags.SSH_FILEXFER_ATTR_UIDGID) == 0);

    const decoded = AttrFlags.fromU32(value);
    try testing.expectEqual(true, decoded.size);
    try testing.expectEqual(true, decoded.permissions);
    try testing.expectEqual(false, decoded.uidgid);
}

test "FileType - fromPermissions" {
    const testing = std.testing;

    try testing.expectEqual(FileType.regular, FileType.fromPermissions(0o100644));
    try testing.expectEqual(FileType.directory, FileType.fromPermissions(0o040755));
    try testing.expectEqual(FileType.symlink, FileType.fromPermissions(0o120777));
}

test "FileAttributes - init and builder pattern" {
    const testing = std.testing;

    var attrs = FileAttributes.init();
    _ = attrs.withSize(1024);
    _ = attrs.withPermissions(0o100644);
    _ = attrs.withUidGid(1000, 1000);
    _ = attrs.withTimes(1234567890, 1234567890);

    try testing.expectEqual(@as(u64, 1024), attrs.size.?);
    try testing.expectEqual(@as(u32, 0o100644), attrs.permissions.?);
    try testing.expectEqual(@as(u32, 1000), attrs.uid.?);
    try testing.expectEqual(@as(u32, 1000), attrs.gid.?);
    try testing.expectEqual(@as(u32, 1234567890), attrs.atime.?);
    try testing.expectEqual(@as(u32, 1234567890), attrs.mtime.?);

    try testing.expect(attrs.flags.size);
    try testing.expect(attrs.flags.permissions);
    try testing.expect(attrs.flags.uidgid);
    try testing.expect(attrs.flags.acmodtime);
}

test "FileAttributes - encode and decode empty" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const attrs = FileAttributes.init();

    const encoded = try attrs.encode(allocator);
    defer allocator.free(encoded);

    const decoded = try FileAttributes.decode(encoded);

    try testing.expectEqual(false, decoded.flags.size);
    try testing.expectEqual(false, decoded.flags.uidgid);
    try testing.expectEqual(@as(?u64, null), decoded.size);
}

test "FileAttributes - encode and decode with all fields" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var attrs = FileAttributes.init();
    _ = attrs.withSize(4096);
    _ = attrs.withUidGid(500, 500);
    _ = attrs.withPermissions(0o100755);
    _ = attrs.withTimes(1111111111, 2222222222);

    const encoded = try attrs.encode(allocator);
    defer allocator.free(encoded);

    const decoded = try FileAttributes.decode(encoded);

    try testing.expectEqual(@as(u64, 4096), decoded.size.?);
    try testing.expectEqual(@as(u32, 500), decoded.uid.?);
    try testing.expectEqual(@as(u32, 500), decoded.gid.?);
    try testing.expectEqual(@as(u32, 0o100755), decoded.permissions.?);
    try testing.expectEqual(@as(u32, 1111111111), decoded.atime.?);
    try testing.expectEqual(@as(u32, 2222222222), decoded.mtime.?);
}

test "FileAttributes - getFileType" {
    const testing = std.testing;

    var attrs = FileAttributes.init();
    _ = attrs.withPermissions(0o100644);

    try testing.expectEqual(FileType.regular, attrs.getFileType());
    try testing.expect(attrs.isRegularFile());
    try testing.expect(!attrs.isDirectory());

    attrs.permissions = 0o040755;
    try testing.expectEqual(FileType.directory, attrs.getFileType());
    try testing.expect(attrs.isDirectory());
    try testing.expect(!attrs.isRegularFile());
}

test "Permissions - standard values" {
    const testing = std.testing;

    try testing.expectEqual(@as(u32, 0o100644), Permissions.FILE_DEFAULT);
    try testing.expectEqual(@as(u32, 0o040755), Permissions.DIR_DEFAULT);

    try testing.expectEqual(@as(u32, 0o100644), Permissions.file(0o644));
    try testing.expectEqual(@as(u32, 0o040755), Permissions.dir(0o755));
}
