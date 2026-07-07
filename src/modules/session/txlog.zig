const std = @import("std");
const posix = std.posix;

/// Transaction log for crash recovery during critical operations.
/// Writes append-only log entries to disk before modifying state.
/// On restart, incomplete transactions can be detected and rolled back/completed.
pub const TxType = enum(u8) {
    detach_start = 1,
    detach_commit = 2,
    reattach_start = 3,
    reattach_commit = 4,
    pane_state_change = 5,
};

pub const TxEntry = struct {
    tx_type: TxType,
    timestamp: i64,
    session_id: [16]u8,
    // Flexible payload for operation-specific data
    payload_len: u32,
};

pub const TxLog = struct {
    allocator: std.mem.Allocator,
    log_fd: ?posix.fd_t,
    log_path: []const u8,

    const FILE_HEADER = "HEXETX01";

    pub fn init(allocator: std.mem.Allocator, log_path: []const u8) TxLog {
        return TxLog{
            .allocator = allocator,
            .log_fd = null,
            .log_path = log_path,
        };
    }

    pub fn deinit(self: *TxLog) void {
        if (self.log_fd) |fd| {
            posix.close(fd);
        }
    }

    /// Open or create the transaction log file.
    pub fn open(self: *TxLog) !void {
        if (self.log_fd != null) return; // Already open

        const fd = try posix.open(
            self.log_path,
            .{ .ACCMODE = .RDWR, .CREAT = true, .APPEND = true },
            0o600,
        );
        errdefer posix.close(fd);

        try self.ensureCompatibleFile(fd);
        self.log_fd = fd;
    }

    fn ensureCompatibleFile(self: *TxLog, fd: posix.fd_t) !void {
        _ = self;
        try posix.lseek_SET(fd, 0);

        var header: [FILE_HEADER.len]u8 = undefined;
        var off: usize = 0;
        while (off < header.len) {
            const n = try posix.read(fd, header[off..]);
            if (n == 0) break;
            off += n;
        }

        if (off == header.len and std.mem.eql(u8, header[0..], FILE_HEADER)) {
            try posix.lseek_END(fd, 0);
            return;
        }

        // Old dev builds wrote raw TxEntry records with no file magic/version.
        // They are intentionally not replayed into a newer daemon.
        try posix.ftruncate(fd, 0);
        try posix.lseek_SET(fd, 0);
        try writeAll(fd, FILE_HEADER[0..]);
        try posix.fsync(fd);
    }

    /// Write a transaction entry to the log (fsync for durability).
    pub fn write(self: *TxLog, tx_type: TxType, session_id: [16]u8, payload: []const u8) !void {
        if (self.log_fd == null) try self.open();

        const entry = TxEntry{
            .tx_type = tx_type,
            .timestamp = std.time.timestamp(),
            .session_id = session_id,
            .payload_len = @intCast(payload.len),
        };

        const fd = self.log_fd.?;

        try posix.lseek_END(fd, 0);
        const header_bytes = std.mem.asBytes(&entry);
        try writeAll(fd, header_bytes);
        try writeAll(fd, payload);

        // Ensure durability (critical for crash recovery)
        try posix.fsync(fd);
    }

    /// Maximum total bytes accepted across all entries during replay. A log
    /// larger than this is likely corrupt or adversarial; truncate the tail.
    const MAX_REPLAY_BYTES: usize = 10 * 1024 * 1024;

    /// Read all transaction entries from the log.
    pub fn readAll(self: *TxLog, allocator: std.mem.Allocator) !std.ArrayList(TxLogEntry) {
        if (self.log_fd == null) try self.open();

        const fd = self.log_fd.?;
        try posix.lseek_SET(fd, 0); // Rewind to start

        var file_header: [FILE_HEADER.len]u8 = undefined;
        var file_header_off: usize = 0;
        while (file_header_off < file_header.len) {
            const n = try posix.read(fd, file_header[file_header_off..]);
            if (n == 0) break;
            file_header_off += n;
        }
        if (file_header_off != file_header.len or !std.mem.eql(u8, file_header[0..], FILE_HEADER)) {
            try self.truncate();
            return .empty;
        }

        var entries: std.ArrayList(TxLogEntry) = .empty;
        errdefer {
            for (entries.items) |*e| {
                allocator.free(e.payload);
            }
            entries.deinit(allocator);
        }

        var total_bytes: usize = 0;

        while (true) {
            var header: TxEntry = undefined;
            const header_bytes = std.mem.asBytes(&header);

            // Read header with loop to handle partial reads
            var h_off: usize = 0;
            while (h_off < header_bytes.len) {
                const n = posix.read(fd, header_bytes[h_off..]) catch |e| {
                    if (e == error.WouldBlock) break;
                    return e;
                };
                if (n == 0) break; // EOF
                h_off += n;
            }
            if (h_off == 0) break; // EOF at start
            if (h_off < header_bytes.len) break; // Incomplete header (corrupted)

            // Validate the enum tag before it is ever switched on: a corrupt
            // byte here would otherwise be safety-checked illegal behavior
            // during recovery, crash-looping the daemon at startup.
            const tx_type = std.meta.intToEnum(
                TxType,
                header_bytes[@offsetOf(TxEntry, "tx_type")],
            ) catch break; // Corrupt record: stop replay at the bad tail.

            // Read payload with loop to handle partial reads
            var payload: []u8 = &.{};
            if (header.payload_len > 0) {
                // Sanity check: prevent excessive allocations from corrupted data
                if (header.payload_len > 1024 * 1024) break; // Max 1MB payload

                payload = try allocator.alloc(u8, header.payload_len);
                errdefer allocator.free(payload);

                var p_off: usize = 0;
                while (p_off < header.payload_len) {
                    const n = try posix.read(fd, payload[p_off..]);
                    if (n == 0) break; // EOF
                    p_off += n;
                }
                if (p_off < header.payload_len) {
                    allocator.free(payload);
                    break; // Incomplete payload
                }
            }

            try entries.append(allocator, .{
                .tx_type = tx_type,
                .timestamp = header.timestamp,
                .session_id = header.session_id,
                .payload = payload,
            });

            total_bytes += header_bytes.len + payload.len;
            if (total_bytes > MAX_REPLAY_BYTES) break;
        }

        return entries;
    }

    /// Truncate the log (after successful recovery or cleanup).
    pub fn truncate(self: *TxLog) !void {
        if (self.log_fd) |fd| {
            posix.close(fd);
            self.log_fd = null;
        }

        // Reopen with TRUNC
        const fd = try posix.open(
            self.log_path,
            .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true },
            0o600,
        );
        try writeAll(fd, FILE_HEADER[0..]);
        posix.close(fd);
    }
};

fn writeAll(fd: posix.fd_t, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const written = try posix.write(fd, data[off..]);
        if (written == 0) return error.WriteZero;
        off += written;
    }
}

pub const TxLogEntry = struct {
    tx_type: TxType,
    timestamp: i64,
    session_id: [16]u8,
    payload: []const u8,
};

pub const IncompleteTransaction = struct {
    session_id: [16]u8,
    tx_type: TxType,
};

/// Analyze transaction log entries to detect incomplete operations and preserve
/// the operation type for recovery handling.
pub fn findIncompleteOperations(entries: []const TxLogEntry) !std.ArrayList(IncompleteTransaction) {
    var incomplete: std.ArrayList(IncompleteTransaction) = .empty;

    const alloc = std.heap.page_allocator;
    var pending_ops = std.AutoHashMap([16]u8, TxType).init(alloc);
    defer pending_ops.deinit();

    for (entries) |entry| {
        switch (entry.tx_type) {
            .detach_start, .reattach_start => {
                try pending_ops.put(entry.session_id, entry.tx_type);
            },
            .detach_commit => {
                _ = pending_ops.remove(entry.session_id);
            },
            .reattach_commit => {
                _ = pending_ops.remove(entry.session_id);
            },
            .pane_state_change => {},
        }
    }

    var it = pending_ops.iterator();
    while (it.next()) |kv| {
        try incomplete.append(alloc, .{
            .session_id = kv.key_ptr.*,
            .tx_type = kv.value_ptr.*,
        });
    }

    return incomplete;
}

/// Analyze transaction log entries to detect incomplete operations.
/// Returns sessions that need rollback/recovery.
pub fn findIncompleteTransactions(entries: []const TxLogEntry) !std.ArrayList([16]u8) {
    var incomplete_ops = try findIncompleteOperations(entries);
    defer incomplete_ops.deinit(std.heap.page_allocator);

    var incomplete: std.ArrayList([16]u8) = .empty;
    for (incomplete_ops.items) |entry| {
        try incomplete.append(std.heap.page_allocator, entry.session_id);
    }
    return incomplete;
}
