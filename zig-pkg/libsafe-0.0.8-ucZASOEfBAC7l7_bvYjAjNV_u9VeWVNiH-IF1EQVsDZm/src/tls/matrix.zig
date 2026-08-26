const std = @import("std");
const tls_interop = @import("interop.zig");

pub const MatrixStats = struct {
    total: usize,
    success: usize,
    handshake_failed: usize,
    alpn_mismatch: usize,
    unsupported_cipher_suite: usize,
    invalid_state: usize,
    out_of_memory: usize,
};

pub const MatrixEntry = struct {
    name: []const u8,
    case: tls_interop.FullHandshakeCase,
    expected: tls_interop.CaseOutcome,
};

pub const MatrixResult = struct {
    stats: MatrixStats,
    mismatches: usize,
};

const BADSSL_LIKE_MISMATCH_ALPN = [_][]const u8{"h2"};
const BADSSL_LIKE_BAD_TP = [_]u8{ 0x03, 0x02, 0x44, 0xAF };

pub const BADSSL_LIKE_FULL_HANDSHAKE_MATRIX = [_]MatrixEntry{
    .{
        .name = "baseline-success",
        .case = .{},
        .expected = .success,
    },
    .{
        .name = "alpn-mismatch-like",
        .case = .{ .server_supported_alpn = &BADSSL_LIKE_MISMATCH_ALPN },
        .expected = .alpn_mismatch,
    },
    .{
        .name = "malformed-transport-params-like",
        .case = .{ .server_transport_params = &BADSSL_LIKE_BAD_TP },
        .expected = .handshake_failed,
    },
};

pub fn run_full_handshake_matrix(
    allocator: std.mem.Allocator,
    entries: []const MatrixEntry,
) !MatrixResult {
    var stats = MatrixStats{
        .total = entries.len,
        .success = 0,
        .handshake_failed = 0,
        .alpn_mismatch = 0,
        .unsupported_cipher_suite = 0,
        .invalid_state = 0,
        .out_of_memory = 0,
    };
    var mismatches: usize = 0;

    for (entries) |entry| {
        _ = entry.name;
        const outcome = try tls_interop.run_full_handshake_case(allocator, entry.case);
        increment_outcome_counter(&stats, outcome);
        if (outcome != entry.expected) mismatches += 1;
    }

    return .{
        .stats = stats,
        .mismatches = mismatches,
    };
}

fn increment_outcome_counter(stats: *MatrixStats, outcome: tls_interop.CaseOutcome) void {
    switch (outcome) {
        .success => stats.success += 1,
        .handshake_failed => stats.handshake_failed += 1,
        .alpn_mismatch => stats.alpn_mismatch += 1,
        .unsupported_cipher_suite => stats.unsupported_cipher_suite += 1,
        .invalid_state => stats.invalid_state += 1,
        .out_of_memory => stats.out_of_memory += 1,
    }
}

test "full handshake matrix aggregates outcomes and mismatches" {
    const allocator = std.testing.allocator;

    const mismatch_alpn = [_][]const u8{"h2"};
    const bad_tp = [_]u8{ 0x03, 0x02, 0x44, 0xAF };

    const entries = [_]MatrixEntry{
        .{
            .name = "success",
            .case = .{},
            .expected = .success,
        },
        .{
            .name = "alpn-mismatch",
            .case = .{ .server_supported_alpn = &mismatch_alpn },
            .expected = .alpn_mismatch,
        },
        .{
            .name = "bad-tp",
            .case = .{ .server_transport_params = &bad_tp },
            .expected = .handshake_failed,
        },
        .{
            .name = "intentional-mismatch",
            .case = .{},
            .expected = .unsupported_cipher_suite,
        },
    };

    const result = try run_full_handshake_matrix(allocator, &entries);
    try std.testing.expectEqual(@as(usize, entries.len), result.stats.total);
    try std.testing.expectEqual(@as(usize, 2), result.stats.success);
    try std.testing.expectEqual(@as(usize, 1), result.stats.alpn_mismatch);
    try std.testing.expectEqual(@as(usize, 1), result.stats.handshake_failed);
    try std.testing.expectEqual(@as(usize, 1), result.mismatches);
}

test "badssl-like matrix subset stays stable" {
    const allocator = std.testing.allocator;
    const result = try run_full_handshake_matrix(allocator, &BADSSL_LIKE_FULL_HANDSHAKE_MATRIX);

    try std.testing.expectEqual(@as(usize, BADSSL_LIKE_FULL_HANDSHAKE_MATRIX.len), result.stats.total);
    try std.testing.expectEqual(@as(usize, 1), result.stats.success);
    try std.testing.expectEqual(@as(usize, 1), result.stats.alpn_mismatch);
    try std.testing.expectEqual(@as(usize, 1), result.stats.handshake_failed);
    try std.testing.expectEqual(@as(usize, 0), result.mismatches);
}
