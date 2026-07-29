const std = @import("std");
const core = @import("core");
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

/// On-disk transaction record.
///
/// MUST stay `extern`: this is written to a persistent file with
/// `std.mem.asBytes`. As a plain struct its layout was compiler-chosen, so the
/// on-disk format depended on field-ordering decisions -- a toolchain change
/// would silently reinterpret existing logs as garbage rather than reject them
/// -- and `asBytes` copied the struct's PADDING, i.e. uninitialized stack
/// memory, straight into the file. `readAll`'s habit of reading the type tag at
/// `@offsetOf(...)` rather than from the parsed struct only worked because of
/// that same layout assumption.
pub const TxEntry = extern struct {
    tx_type: TxType align(1),
    timestamp: i64 align(1),
    session_id: [16]u8 align(1),
    // Flexible payload for operation-specific data
    payload_len: u32 align(1),
};

pub const TxLog = struct {
    allocator: std.mem.Allocator,
    log_fd: ?posix.fd_t,
    log_path: []const u8,
    /// Set by `readAll` when it stopped at MAX_REPLAY_BYTES.
    read_truncated: bool = false,
    /// Transactions started but not yet committed. The log is only safe to
    /// compact when this is zero.
    open_transactions: u32 = 0,

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
            .{ .ACCMODE = .RDWR, .CREAT = true, .APPEND = true, .CLOEXEC = true },
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

        // Zero-initialise so no uninitialised bytes can reach the file even if
        // the layout ever gains padding again.
        var entry = std.mem.zeroes(TxEntry);
        entry = .{
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

        switch (tx_type) {
            .detach_start, .reattach_start => self.open_transactions +|= 1,
            .detach_commit, .reattach_commit => {
                if (self.open_transactions > 0) self.open_transactions -= 1;
                // Nothing is in flight, so every record in the log describes a
                // settled transaction and none of it is needed for recovery.
                // Compacting here is what stops the log from growing past
                // MAX_REPLAY_BYTES and poisoning the next restart's replay.
                if (self.open_transactions == 0) {
                    const size: u64 = blk: {
                        const st = posix.fstat(fd) catch break :blk 0;
                        break :blk @intCast(st.size);
                    };
                    if (size > COMPACT_THRESHOLD_BYTES) {
                        self.truncate() catch |err| {
                            core.logging.logError("ses", "failed to compact settled txlog", err);
                        };
                    }
                }
            },
            else => {},
        }
    }

    /// Maximum total bytes accepted across all entries during replay. A log
    /// larger than this is likely corrupt or adversarial; truncate the tail.
    const MAX_REPLAY_BYTES: usize = 10 * 1024 * 1024;

    /// Size past which a fully-settled log is truncated on the next commit.
    ///
    /// `truncate()` was only ever called at daemon startup, so a long-lived
    /// daemon's log grew monotonically -- every detach writes start+commit,
    /// every reattach likewise. Once it passed MAX_REPLAY_BYTES the next
    /// restart replayed only the OLDEST 10MB and reported every `detach_start`
    /// whose commit lay past the cutoff as incomplete, which recovery then
    /// "rolled back" by deleting fully-committed detached sessions and
    /// orphaning their panes.
    const COMPACT_THRESHOLD_BYTES: u64 = 1024 * 1024;

    /// Whether the last `readAll` stopped early at MAX_REPLAY_BYTES.
    ///
    /// A truncated replay CANNOT distinguish "start with no commit" from "start
    /// whose commit we did not read", so recovery must roll nothing back.
    pub fn lastReadWasTruncated(self: *const TxLog) bool {
        return self.read_truncated;
    }

    /// Read all transaction entries from the log.
    pub fn readAll(self: *TxLog, allocator: std.mem.Allocator) !std.ArrayList(TxLogEntry) {
        self.read_truncated = false;
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
            if (total_bytes > MAX_REPLAY_BYTES) {
                self.read_truncated = true;
                break;
            }
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
            .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
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
///
/// Takes the allocator explicitly: it used to allocate the returned list with
/// `page_allocator` while its caller released it with `ses_state.allocator`.
/// That only worked because everything happened to BE page_allocator; the
/// moment the daemon uses a real allocator it is a cross-allocator free.
pub fn findIncompleteOperations(alloc: std.mem.Allocator, entries: []const TxLogEntry) !std.ArrayList(IncompleteTransaction) {
    var incomplete: std.ArrayList(IncompleteTransaction) = .empty;

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
pub fn findIncompleteTransactions(alloc: std.mem.Allocator, entries: []const TxLogEntry) !std.ArrayList([16]u8) {
    var incomplete_ops = try findIncompleteOperations(alloc, entries);
    defer incomplete_ops.deinit(alloc);

    var incomplete: std.ArrayList([16]u8) = .empty;
    for (incomplete_ops.items) |entry| {
        try incomplete.append(alloc, entry.session_id);
    }
    return incomplete;
}

test "TxEntry has a stable, padding-free on-disk layout" {
    const testing = std.testing;
    // Written to a persistent file with asBytes, so its size must be exactly
    // the sum of its fields: any padding would be uninitialised stack memory
    // landing in the log, and a compiler-chosen layout would make existing
    // logs unreadable after a toolchain change.
    const expected = @sizeOf(TxType) + @sizeOf(i64) + 16 + @sizeOf(u32);
    try testing.expectEqual(expected, @sizeOf(TxEntry));

    // Field order is part of the format.
    try testing.expectEqual(@as(usize, 0), @offsetOf(TxEntry, "tx_type"));
    try testing.expectEqual(@as(usize, 1), @offsetOf(TxEntry, "timestamp"));
    try testing.expectEqual(@as(usize, 9), @offsetOf(TxEntry, "session_id"));
    try testing.expectEqual(@as(usize, 25), @offsetOf(TxEntry, "payload_len"));
}

test "txlog compacts a settled log instead of growing past the replay cap" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [512]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &path_buf);
    const log_path = try std.fmt.allocPrint(testing.allocator, "{s}/tx", .{dir});
    defer testing.allocator.free(log_path);

    var log = TxLog{ .allocator = testing.allocator, .log_fd = null, .log_path = log_path };
    defer if (log.log_fd) |fd| posix.close(fd);

    const sid = [_]u8{'s'} ** 16;
    // A payload big enough that a handful of settled transactions crosses the
    // compaction threshold. Before this, truncate() only ran at startup, so the
    // log grew without bound until a restart replayed a partial prefix and
    // "rolled back" transactions whose commits it had simply not read.
    const payload = try testing.allocator.alloc(u8, 256 * 1024);
    defer testing.allocator.free(payload);
    @memset(payload, 'p');

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try log.write(.detach_start, sid, payload);
        try log.write(.detach_commit, sid, payload);
    }

    // Stat the PATH, not log_fd: truncate() deliberately leaves the fd null so
    // the next write reopens lazily.
    const stat = try std.fs.cwd().statFile(log_path);
    // Settled after every commit, so the log should have been compacted rather
    // than accumulating ~4MB.
    try testing.expect(stat.size < TxLog.COMPACT_THRESHOLD_BYTES);
}

test "txlog does not compact while a transaction is still open" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [512]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &path_buf);
    const log_path = try std.fmt.allocPrint(testing.allocator, "{s}/tx2", .{dir});
    defer testing.allocator.free(log_path);

    var log = TxLog{ .allocator = testing.allocator, .log_fd = null, .log_path = log_path };
    defer if (log.log_fd) |fd| posix.close(fd);

    const sid_a = [_]u8{'a'} ** 16;
    const sid_b = [_]u8{'b'} ** 16;
    const payload = try testing.allocator.alloc(u8, 256 * 1024);
    defer testing.allocator.free(payload);
    @memset(payload, 'q');

    // B stays open across A's commits: compacting here would discard the
    // record that B was ever started, losing the ability to roll it back.
    try log.write(.detach_start, sid_b, payload);
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        try log.write(.detach_start, sid_a, payload);
        try log.write(.detach_commit, sid_a, payload);
    }

    var entries = try log.readAll(testing.allocator);
    defer {
        for (entries.items) |*e| testing.allocator.free(e.payload);
        entries.deinit(testing.allocator);
    }
    var saw_open_start = false;
    for (entries.items) |e| {
        if (e.tx_type == .detach_start and std.mem.eql(u8, &e.session_id, &sid_b)) saw_open_start = true;
    }
    try testing.expect(saw_open_start);
}
