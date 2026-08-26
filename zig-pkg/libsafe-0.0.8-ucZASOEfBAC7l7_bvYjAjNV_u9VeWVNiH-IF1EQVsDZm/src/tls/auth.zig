const std = @import("std");

pub const CertificateError = error{
    EmptyCertificateChain,
    InvalidValidityWindow,
    CertificateNotYetValid,
    CertificateExpired,
    HostnameMismatch,
    InvalidHostname,
    InvalidDnsNamePattern,
    ClientCertificateRequired,
};

pub const ValidityWindow = struct {
    not_before_unix: i64,
    not_after_unix: i64,

    pub fn validate(self: ValidityWindow, now_unix: i64) CertificateError!void {
        if (self.not_after_unix < self.not_before_unix) return error.InvalidValidityWindow;
        if (now_unix < self.not_before_unix) return error.CertificateNotYetValid;
        if (now_unix > self.not_after_unix) return error.CertificateExpired;
    }
};

pub const CertificateIdentity = struct {
    dns_names: []const []const u8 = &[_][]const u8{},
    common_name: ?[]const u8 = null,
};

pub const CertificateMetadata = struct {
    validity: ?ValidityWindow = null,
    identity: CertificateIdentity = .{},
};

pub fn verify_server_certificate(
    chain: []const CertificateMetadata,
    hostname: []const u8,
    now_unix: i64,
) CertificateError!void {
    if (chain.len == 0) return error.EmptyCertificateChain;
    try validate_certificate_chain_time(chain, now_unix);
    try verify_hostname(hostname, chain[0].identity);
}

pub fn verify_client_certificate(
    chain: []const CertificateMetadata,
    now_unix: i64,
    required: bool,
) CertificateError!void {
    if (required and chain.len == 0) return error.ClientCertificateRequired;
    if (chain.len == 0) return;
    try validate_certificate_chain_time(chain, now_unix);
}

pub fn verify_hostname(hostname: []const u8, identity: CertificateIdentity) CertificateError!void {
    if (!is_valid_hostname(hostname)) return error.InvalidHostname;

    if (identity.dns_names.len > 0) {
        for (identity.dns_names) |pattern| {
            if (try dns_name_matches(pattern, hostname)) return;
        }
        return error.HostnameMismatch;
    }

    if (identity.common_name) |common_name| {
        if (try dns_name_matches(common_name, hostname)) return;
    }

    return error.HostnameMismatch;
}

fn validate_certificate_chain_time(chain: []const CertificateMetadata, now_unix: i64) CertificateError!void {
    for (chain) |cert| {
        if (cert.validity) |window| {
            try window.validate(now_unix);
        }
    }
}

fn dns_name_matches(pattern: []const u8, hostname: []const u8) CertificateError!bool {
    if (!is_valid_dns_pattern(pattern)) return error.InvalidDnsNamePattern;

    if (std.mem.eql(u8, pattern, hostname)) return true;
    if (!std.mem.startsWith(u8, pattern, "*.")) return false;

    const suffix = pattern[1..];
    if (!std.mem.endsWith(u8, hostname, suffix)) return false;

    const prefix_len = hostname.len - suffix.len;
    if (prefix_len == 0) return false;

    const prefix = hostname[0..prefix_len];
    if (std.mem.indexOfScalar(u8, prefix, '.')) |_| return false;
    return true;
}

fn is_valid_hostname(hostname: []const u8) bool {
    if (hostname.len == 0 or hostname.len > 253) return false;
    if (hostname[0] == '.' or hostname[hostname.len - 1] == '.') return false;

    var label_len: usize = 0;
    for (hostname) |c| {
        if (c == '.') {
            if (label_len == 0 or label_len > 63) return false;
            label_len = 0;
            continue;
        }

        if (!is_dns_char(c)) return false;
        label_len += 1;
    }

    return label_len > 0 and label_len <= 63;
}

fn is_valid_dns_pattern(pattern: []const u8) bool {
    if (std.mem.startsWith(u8, pattern, "*.")) {
        if (pattern.len <= 2) return false;
        const suffix = pattern[2..];
        if (!is_valid_hostname(suffix)) return false;
        if (std.mem.indexOfScalar(u8, suffix, '.')) |_| {
            return true;
        }
        return false;
    }

    return is_valid_hostname(pattern);
}

fn is_dns_char(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '-';
}

test "verify server certificate checks validity and SAN hostname" {
    const chain = [_]CertificateMetadata{.{
        .validity = .{ .not_before_unix = 100, .not_after_unix = 200 },
        .identity = .{ .dns_names = &[_][]const u8{"api.example.com"} },
    }};
    try verify_server_certificate(&chain, "api.example.com", 150);
}

test "verify server certificate rejects hostname mismatch" {
    const chain = [_]CertificateMetadata{.{
        .identity = .{ .dns_names = &[_][]const u8{"api.example.com"} },
    }};
    try std.testing.expectError(error.HostnameMismatch, verify_server_certificate(&chain, "web.example.com", 0));
}

test "verify server certificate accepts wildcard only one label" {
    const identity = CertificateIdentity{ .dns_names = &[_][]const u8{"*.example.com"} };
    try verify_hostname("api.example.com", identity);
    try std.testing.expectError(error.HostnameMismatch, verify_hostname("a.b.example.com", identity));
}

test "verify server certificate rejects empty chain" {
    try std.testing.expectError(error.EmptyCertificateChain, verify_server_certificate(&[_]CertificateMetadata{}, "example.com", 0));
}

test "verify client certificate required" {
    try std.testing.expectError(error.ClientCertificateRequired, verify_client_certificate(&[_]CertificateMetadata{}, 0, true));
}

test "verify client certificate validates time window" {
    const chain = [_]CertificateMetadata{.{
        .validity = .{ .not_before_unix = 10, .not_after_unix = 20 },
    }};
    try std.testing.expectError(error.CertificateNotYetValid, verify_client_certificate(&chain, 9, true));
    try std.testing.expectError(error.CertificateExpired, verify_client_certificate(&chain, 21, true));
    try verify_client_certificate(&chain, 15, true);
}

test "verify hostname falls back to common name" {
    const identity = CertificateIdentity{ .common_name = "host.example.com" };
    try verify_hostname("host.example.com", identity);
}

test "verify hostname rejects invalid hostnames and patterns" {
    const bad_identity = CertificateIdentity{ .dns_names = &[_][]const u8{"*example.com"} };
    try std.testing.expectError(error.InvalidDnsNamePattern, verify_hostname("api.example.com", bad_identity));

    const identity = CertificateIdentity{ .dns_names = &[_][]const u8{"api.example.com"} };
    try std.testing.expectError(error.InvalidHostname, verify_hostname("bad..host", identity));
}
