const std = @import("std");

pub const SshAlgorithmError = error{
    UnsupportedAlgorithm,
};

pub const HostKeyAlgorithm = enum {
    ssh_ed25519,
    rsa_sha2_256,
    rsa_sha2_512,
    ecdsa_sha2_nistp256,

    pub fn name(self: HostKeyAlgorithm) []const u8 {
        return switch (self) {
            .ssh_ed25519 => "ssh-ed25519",
            .rsa_sha2_256 => "rsa-sha2-256",
            .rsa_sha2_512 => "rsa-sha2-512",
            .ecdsa_sha2_nistp256 => "ecdsa-sha2-nistp256",
        };
    }

    pub fn from_name(algorithm_name: []const u8) ?HostKeyAlgorithm {
        if (std.mem.eql(u8, algorithm_name, "ssh-ed25519")) return .ssh_ed25519;
        if (std.mem.eql(u8, algorithm_name, "rsa-sha2-256")) return .rsa_sha2_256;
        if (std.mem.eql(u8, algorithm_name, "rsa-sha2-512")) return .rsa_sha2_512;
        if (std.mem.eql(u8, algorithm_name, "ecdsa-sha2-nistp256")) return .ecdsa_sha2_nistp256;
        return null;
    }
};

pub const SignatureAlgorithm = enum {
    ssh_ed25519,
    rsa_sha2_256,
    rsa_sha2_512,
    ecdsa_sha2_nistp256,

    pub fn name(self: SignatureAlgorithm) []const u8 {
        return switch (self) {
            .ssh_ed25519 => "ssh-ed25519",
            .rsa_sha2_256 => "rsa-sha2-256",
            .rsa_sha2_512 => "rsa-sha2-512",
            .ecdsa_sha2_nistp256 => "ecdsa-sha2-nistp256",
        };
    }

    pub fn from_name(algorithm_name: []const u8) ?SignatureAlgorithm {
        if (std.mem.eql(u8, algorithm_name, "ssh-ed25519")) return .ssh_ed25519;
        if (std.mem.eql(u8, algorithm_name, "rsa-sha2-256")) return .rsa_sha2_256;
        if (std.mem.eql(u8, algorithm_name, "rsa-sha2-512")) return .rsa_sha2_512;
        if (std.mem.eql(u8, algorithm_name, "ecdsa-sha2-nistp256")) return .ecdsa_sha2_nistp256;
        return null;
    }
};

pub const AlgorithmSupport = struct {
    pub const enable_ssh_ed25519 = true;
    pub const enable_rsa_sha2_256 = false;
    pub const enable_rsa_sha2_512 = false;
    pub const enable_ecdsa_sha2_nistp256 = false;
};

pub fn is_host_key_algorithm_enabled(algorithm: HostKeyAlgorithm) bool {
    return switch (algorithm) {
        .ssh_ed25519 => AlgorithmSupport.enable_ssh_ed25519,
        .rsa_sha2_256 => AlgorithmSupport.enable_rsa_sha2_256,
        .rsa_sha2_512 => AlgorithmSupport.enable_rsa_sha2_512,
        .ecdsa_sha2_nistp256 => AlgorithmSupport.enable_ecdsa_sha2_nistp256,
    };
}

pub fn is_signature_algorithm_enabled(algorithm: SignatureAlgorithm) bool {
    return switch (algorithm) {
        .ssh_ed25519 => AlgorithmSupport.enable_ssh_ed25519,
        .rsa_sha2_256 => AlgorithmSupport.enable_rsa_sha2_256,
        .rsa_sha2_512 => AlgorithmSupport.enable_rsa_sha2_512,
        .ecdsa_sha2_nistp256 => AlgorithmSupport.enable_ecdsa_sha2_nistp256,
    };
}

pub fn select_preferred_host_key_algorithm(
    client_algorithms: []const []const u8,
    server_algorithms: []const []const u8,
) SshAlgorithmError!HostKeyAlgorithm {
    for (client_algorithms) |candidate_name| {
        const candidate = HostKeyAlgorithm.from_name(candidate_name) orelse continue;
        if (!is_host_key_algorithm_enabled(candidate)) continue;
        if (contains_name(server_algorithms, candidate_name)) return candidate;
    }
    return error.UnsupportedAlgorithm;
}

pub fn select_preferred_signature_algorithm(
    client_algorithms: []const []const u8,
    server_algorithms: []const []const u8,
) SshAlgorithmError!SignatureAlgorithm {
    for (client_algorithms) |candidate_name| {
        const candidate = SignatureAlgorithm.from_name(candidate_name) orelse continue;
        if (!is_signature_algorithm_enabled(candidate)) continue;
        if (contains_name(server_algorithms, candidate_name)) return candidate;
    }
    return error.UnsupportedAlgorithm;
}

fn contains_name(list: []const []const u8, needle: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

test "algorithm parser handles known and unknown names" {
    try std.testing.expectEqual(HostKeyAlgorithm.ssh_ed25519, HostKeyAlgorithm.from_name("ssh-ed25519").?);
    try std.testing.expect(HostKeyAlgorithm.from_name("unknown") == null);
    try std.testing.expectEqual(SignatureAlgorithm.ssh_ed25519, SignatureAlgorithm.from_name("ssh-ed25519").?);
    try std.testing.expect(SignatureAlgorithm.from_name("unknown") == null);
}

test "algorithm support exposes only ed25519 by default" {
    try std.testing.expect(is_host_key_algorithm_enabled(.ssh_ed25519));
    try std.testing.expect(!is_host_key_algorithm_enabled(.rsa_sha2_256));
    try std.testing.expect(is_signature_algorithm_enabled(.ssh_ed25519));
    try std.testing.expect(!is_signature_algorithm_enabled(.ecdsa_sha2_nistp256));
}

test "preferred selection ignores disabled algorithms" {
    const client = [_][]const u8{ "rsa-sha2-256", "ssh-ed25519" };
    const server = [_][]const u8{ "rsa-sha2-256", "ssh-ed25519" };
    const selected_host = try select_preferred_host_key_algorithm(&client, &server);
    try std.testing.expectEqual(HostKeyAlgorithm.ssh_ed25519, selected_host);

    const selected_sig = try select_preferred_signature_algorithm(&client, &server);
    try std.testing.expectEqual(SignatureAlgorithm.ssh_ed25519, selected_sig);
}

test "preferred selection rejects when only disabled overlap exists" {
    const client = [_][]const u8{ "rsa-sha2-256", "rsa-sha2-512" };
    const server = [_][]const u8{ "rsa-sha2-512", "rsa-sha2-256" };

    try std.testing.expectError(
        error.UnsupportedAlgorithm,
        select_preferred_host_key_algorithm(&client, &server),
    );
    try std.testing.expectError(
        error.UnsupportedAlgorithm,
        select_preferred_signature_algorithm(&client, &server),
    );
}

test "preferred selection skips unknown names and keeps deterministic order" {
    const client = [_][]const u8{ "unknown-a", "ssh-ed25519", "unknown-b" };
    const server = [_][]const u8{ "unknown-b", "ssh-ed25519" };

    const selected_host = try select_preferred_host_key_algorithm(&client, &server);
    const selected_sig = try select_preferred_signature_algorithm(&client, &server);

    try std.testing.expectEqual(HostKeyAlgorithm.ssh_ed25519, selected_host);
    try std.testing.expectEqual(SignatureAlgorithm.ssh_ed25519, selected_sig);
}
