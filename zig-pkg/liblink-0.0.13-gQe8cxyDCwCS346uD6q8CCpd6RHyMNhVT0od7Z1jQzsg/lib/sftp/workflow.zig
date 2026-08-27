const std = @import("std");
const sftp = @import("sftp.zig");

pub fn listDirectory(
    client: *sftp.SftpClient,
    path: []const u8,
) ![]sftp.client.DirEntry {
    const handle = try client.opendir(path);
    defer client.close(handle) catch {};
    return client.readdir(handle);
}

pub fn downloadFileToLocal(
    allocator: std.mem.Allocator,
    client: *sftp.SftpClient,
    remote_path: []const u8,
    local_path: []const u8,
) !u64 {
    const attrs = sftp.attributes.FileAttributes.init();
    const handle = try client.open(remote_path, .{ .read = true }, attrs);
    defer client.close(handle) catch {};

    const local_file = try std.fs.cwd().createFile(local_path, .{});
    defer local_file.close();

    var offset: u64 = 0;
    var total_bytes: u64 = 0;

    while (true) {
        const data = client.read(handle, offset, 32768) catch |err| {
            if (err == error.Eof) break;
            return err;
        };
        defer allocator.free(data);

        if (data.len == 0) break;
        try local_file.writeAll(data);
        offset += data.len;
        total_bytes += data.len;
    }

    return total_bytes;
}

pub fn uploadFileFromLocal(
    client: *sftp.SftpClient,
    local_path: []const u8,
    remote_path: []const u8,
) !u64 {
    const local_file = try std.fs.cwd().openFile(local_path, .{});
    defer local_file.close();

    const attrs = sftp.attributes.FileAttributes.init();
    const handle = try client.open(remote_path, .{ .write = true, .creat = true, .trunc = true }, attrs);
    defer client.close(handle) catch {};

    var buffer: [32768]u8 = undefined;
    var offset: u64 = 0;
    var total_bytes: u64 = 0;

    while (true) {
        const bytes_read = try local_file.read(&buffer);
        if (bytes_read == 0) break;

        try client.write(handle, offset, buffer[0..bytes_read]);
        offset += bytes_read;
        total_bytes += bytes_read;
    }

    return total_bytes;
}

pub fn makeDirectory(client: *sftp.SftpClient, path: []const u8) !void {
    const attrs = sftp.attributes.FileAttributes.init();
    try client.mkdir(path, attrs);
}

pub fn removeFile(client: *sftp.SftpClient, path: []const u8) !void {
    try client.remove(path);
}
